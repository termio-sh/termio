import AppKit
import Combine
import SwiftUI

/// The menu-bar (tray) presence, modelled on Tailscale's status item: termio's
/// own 3×3 grid brand mark stays constant as a flat monochrome glyph that sits
/// cleanly in the menu bar and adapts to light/dark and the click-highlight.
/// Rather than swapping to unrelated symbols, state is conveyed *over* the mark —
/// it breathes while an agent works, and wears a small coloured status badge when
/// a session is done (green) or waiting on you (amber). Clicking it drops a
/// roster of just the sessions that want you — done (green) or blocked on input
/// (amber) — grouped by project; working and idle agents are running fine on
/// their own and stay out of the list. Picking one focuses that session and
/// brings the window forward.
///
/// We manage a raw `NSStatusItem` (not SwiftUI's `MenuBarExtra`) because termio
/// drives an explicit `NSApplication` rather than the SwiftUI app lifecycle.
@MainActor
final class MenuBarController {
    private let store: TermioStore
    private let onSelect: (Session.ID) -> Void
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(store: TermioStore, onSelect: @escaping (Session.ID) -> Void) {
        self.store = store
        self.onSelect = onSelect
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Drawing the mark as the button's own image lets `variableLength` size the
        // item to fit it (a manually-added subview was getting clipped); the layer
        // backs the working-state pulse animation.
        statusItem.button?.wantsLayer = true

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    private func refresh() {
        applyIcon(for: store.aggregateStatus)
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

        // The roster is a "what needs me right now" queue, so it lists only agent
        // sessions that want the user — done (green) or blocked on input (amber).
        // Plain terminals are managed in the window, and working/idle agents are
        // running fine on their own; both stay out of the menu.
        for project in store.projects {
            let agentSessions = project.sessions.filter {
                $0.agent != .terminal && needsYou(store.status(for: $0.id))
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
                // The row leads with the agent's real brand mark so each session is
                // recognisable at a glance; a busy/done/blocked session also carries
                // a small trailing colour dot, while idle rows stay clean.
                item.image = agentImage(for: session.agent)
                item.attributedTitle = rowTitle(store.displayTitle(for: session), status: status)
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "Nothing needs you", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Termio",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    /// Renders an agent's brand mark for a roster row by reusing the sidebar's
    /// `AgentIconView`, so the menu shows the exact same glyphs. Rasterized lazily
    /// in a drawing-handler image: AppKit re-invokes the handler under the menu's
    /// own appearance at display time, so the monochrome marks (Codex, Grok)
    /// resolve to the right ink. Resolving eagerly against the status button's
    /// appearance is wrong — the menu bar tints from the wallpaper and can be
    /// dark while the dropdown menu (system theme) is light, which baked those
    /// marks in as invisible white-on-white.
    private func agentImage(for agent: AgentPreset) -> NSImage? {
        let side: CGFloat = 15
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let appearance = NSAppearance.currentDrawing()
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let renderer = ImageRenderer(
                content: AgentIconView(agent: agent, size: 13)
                    .frame(width: side, height: side)
                    .environment(\.colorScheme, isDark ? .dark : .light)
            )
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            guard let rendered = renderer.nsImage else { return false }
            rendered.draw(in: rect)
            return true
        }
    }

    /// The row title with a trailing status dot for any session that is busy, done,
    /// or blocked — idle sessions get a plain title so the roster stays calm.
    private func rowTitle(_ title: String, status: SessionStatus) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        guard let color = statusColor(for: status) else { return result }
        result.append(NSAttributedString(
            string: "  ●",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 8)]
        ))
        return result
    }

    /// Whether a session's status warrants pulling the user in: done (green,
    /// waiting to be looked at) or blocked on input (amber). Working and idle
    /// agents are getting on fine without you, so they stay off the roster.
    private func needsYou(_ status: SessionStatus) -> Bool {
        switch status {
        case .done, .needsAttention: return true
        case .idle, .working: return false
        }
    }

    /// The accent colour for a non-idle status, or `nil` for idle (no dot).
    private func statusColor(for status: SessionStatus) -> NSColor? {
        switch status {
        case .idle: return nil
        case .working: return .systemBlue
        case .done: return .systemGreen
        case .needsAttention: return .systemOrange
        }
    }

    @objc private func didPickSession(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw)
        else { return }
        onSelect(id)
    }
}
