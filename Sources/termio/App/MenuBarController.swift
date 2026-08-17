import AppKit
import Combine
import SwiftUI
import TermioShared

/// The menu-bar (tray) presence, modelled on Tailscale's status item: termio's
/// own 3×3 grid brand mark stays constant as a flat monochrome glyph that sits
/// cleanly in the menu bar and adapts to light/dark and the click-highlight.
/// Rather than swapping to unrelated symbols, state is conveyed *over* the mark —
/// it breathes while an agent works, and wears a small coloured status badge when
/// a session is done (green) or waiting on you (amber). Clicking it drops a
/// roster of the active-and-your-turn sessions — working agents (shown with the
/// sidebar's orbiting comet), plus the resting states that want you: done
/// (green) or blocked on input (amber) — grouped by project. Only idle agents
/// (running fine on their own) and plain terminals stay out of the list. Picking
/// one focuses that session and brings the window forward.
///
/// We manage a raw `NSStatusItem` (not SwiftUI's `MenuBarExtra`) because termio
/// drives an explicit `NSApplication` rather than the SwiftUI app lifecycle.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: TermioStore
    private let onSelect: (Session.ID) -> Void
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    /// The roster rows for working sessions, so the comet timer can advance them
    /// while the menu is open. Rebuilt each `buildMenu()`.
    private var workingItems: [NSMenuItem] = []
    private var cometTimer: Timer?
    private var cometPhase: Double = 0
    private var isMenuOpen = false

    init(store: TermioStore, onSelect: @escaping (Session.ID) -> Void) {
        self.store = store
        self.onSelect = onSelect
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Drawing the mark as the button's own image lets `variableLength` size the
        // item to fit it (a manually-added subview was getting clipped); the layer
        // backs the working-state pulse animation.
        statusItem.button?.wantsLayer = true

        // Structural changes (a session opened/closed, a rename) come over the store's
        // own `objectWillChange`.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        // Per-session status/title churn no longer rides `objectWillChange` (it moved to
        // per-session `SessionRuntime`s so the sidebar stops rebuilding on every tick),
        // so the tray subscribes to the dedicated runtime ping instead. Throttled: the
        // menu only needs to catch up a few times a second, not on every hook event.
        store.sessionRuntimeDidChange
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    private func refresh() {
        applyIcon(for: store.aggregateStatus)
        // Rebuilding the menu while it's open swaps out the very items the comet timer
        // animates (and can dismiss the menu), so defer the rebuild until it closes;
        // `menuDidClose` calls back here to catch up on anything that changed.
        guard !isMenuOpen else { return }
        statusItem.menu = buildMenu()
    }

    private func applyIcon(for status: SessionStatus) {
        guard let button = statusItem.button else { return }
        button.layer?.removeAnimation(forKey: workingPulseKey)
        switch status {
        case .idle:
            button.image = Self.gridIcon(badge: nil)
        case .working:
            button.image = Self.gridIcon(badge: nil)
            addWorkingPulse(to: button)
        case .done:
            button.image = Self.gridIcon(badge: .done)
        case .needsAttention:
            button.image = Self.gridIcon(badge: .attention)
        }
    }

    /// A status dot worn over the brand mark, like an app badge.
    private enum Badge {
        case done, attention
        var color: NSColor {
            switch self {
            case .done: return .systemGreen
            case .attention: return .systemOrange
            }
        }
    }

    /// Draws termio's 3×3 rounded-square brand mark — the same motif as the app
    /// icon — as a flat menu-bar glyph. With no badge it is a template image, so
    /// the system tints it for the current appearance and inverts it on highlight,
    /// the way Tailscale's mark behaves. A status badge forces a coloured
    /// composite (templates are single-colour), so the grid is then painted in the
    /// adaptive label colour and the dot is tucked into the top-right with a thin
    /// transparent moat so it reads as separate from the mark.
    private static func gridIcon(badge: Badge?) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let inset: CGFloat = 2
            let usable = side - inset * 2
            let gapRatio: CGFloat = 0.34
            let cell = usable / (3 + 2 * gapRatio)
            let gap = cell * gapRatio
            let radius = cell * 0.3

            let ink = badge == nil ? NSColor.black : NSColor.labelColor
            ink.setFill()
            for row in 0..<3 {
                for column in 0..<3 {
                    let origin = NSPoint(
                        x: inset + CGFloat(column) * (cell + gap),
                        y: inset + CGFloat(row) * (cell + gap)
                    )
                    let rect = NSRect(origin: origin, size: NSSize(width: cell, height: cell))
                    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                }
            }

            if let badge {
                let diameter: CGFloat = 7
                let dot = NSRect(
                    x: side - diameter - inset, y: side - diameter - inset,
                    width: diameter, height: diameter
                )
                let context = NSGraphicsContext.current
                context?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                context?.compositingOperation = .sourceOver
                badge.color.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = badge == nil
        return image
    }

    private let workingPulseKey = "working"

    /// Breathes the mark's opacity while an agent works. The custom grid image is
    /// not an SF Symbol, so symbol effects don't apply — a layer animation is the
    /// reliable way to animate a status button's image (a known AppKit gotcha).
    private func addWorkingPulse(to button: NSStatusBarButton) {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(pulse, forKey: workingPulseKey)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        workingItems.removeAll()

        // The roster is an "active + your turn" queue: working agents (shown with the
        // sidebar's orbiting-comet mark) plus the two resting states that want you —
        // done (green) or blocked on input (amber). Idle agents are getting on fine
        // on their own and plain terminals live in the window, so both stay out.
        for project in store.projects {
            let agentSessions = project.sessions
                .filter { $0.agent != .terminal && shouldList(store.status(for: $0.id)) }
                // The states that want the user rise to the top of each project's
                // rows — blocked first, then just-finished, then still working — so a
                // glance lands on what's actionable before what's merely in progress.
                .sorted {
                    rosterPriority(store.status(for: $0.id))
                        < rosterPriority(store.status(for: $1.id))
                }
            guard !agentSessions.isEmpty else { continue }

            let header = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for session in agentSessions {
                let status = store.status(for: session.id)
                let item = NSMenuItem(
                    title: store.displayTitle(for: session),
                    action: #selector(didPickSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id.uuidString
                // A working row swaps the brand mark for the comet, exactly as the
                // sidebar does, and the timer spins it while the menu is open; other
                // rows lead with the agent's real brand mark and trail a status dot.
                if status == .working {
                    item.image = sessionCometImage(phase: cometPhase)
                    workingItems.append(item)
                } else {
                    item.image = agentMenuImage(for: session.agent)
                }
                item.attributedTitle = sessionMenuRowTitle(store.displayTitle(for: session), status: status)
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        if menu.items.isEmpty {
            let empty = NSMenuItem(title: localized("All caught up"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: localized("Quit Termio"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    /// Whether a session belongs on the roster: anything not at rest. Working
    /// agents show progress and done/blocked agents want you; only idle agents
    /// (and plain terminals, filtered separately) stay off the list.
    private func shouldList(_ status: SessionStatus) -> Bool {
        status != .idle
    }

    /// Roster ordering weight: the resting "your turn" states outrank work in
    /// progress, so the menu reads top-down as a to-do list — blocked (amber)
    /// first, then just-finished (green), then still working. Idle never reaches
    /// here (see `shouldList`).
    private func rosterPriority(_ status: SessionStatus) -> Int {
        switch status {
        case .needsAttention: return 0
        case .done: return 1
        case .working: return 2
        case .idle: return 3
        }
    }

    /// While the menu is open its modal event-tracking loop stops SwiftUI's
    /// `TimelineView` clock, so we spin the comet ourselves: a timer added in
    /// `.common` mode (which fires during tracking) advances the phase and re-renders
    /// every working row. All working rows share one frame, so it renders once a tick.
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        guard !workingItems.isEmpty else { return }
        cometTimer?.invalidate()
        // This timer bypasses the SwiftUI environment, so Reduce Motion has to be
        // honored by hand (the sidebar's indicator handles it via `@Environment`):
        // hold the frame the rows already carry instead of spinning.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let interval = 1.0 / 15.0
        let period = 1.1  // matches the sidebar's WorkingIndicator
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cometPhase += interval / period
                if self.cometPhase >= 1 { self.cometPhase -= 1 }
                let frame = sessionCometImage(phase: self.cometPhase)
                for item in self.workingItems { item.image = frame }
            }
        }
        // An open menu runs its own event-tracking loop; register the timer in that
        // mode explicitly (`.common` doesn't reliably include it) so it keeps firing.
        RunLoop.main.add(timer, forMode: .eventTracking)
        cometTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        cometTimer?.invalidate()
        cometTimer = nil
        // Catch up on any store changes deferred while the menu was open.
        refresh()
    }

    @objc private func didPickSession(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw)
        else { return }
        onSelect(id)
    }
}
