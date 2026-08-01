import AppKit
import GhosttyTerminal

/// A ⌘⌥⇧ pane drag in flight: the lifted pane, plus the pane and drop zone
/// under the pointer right now. `PaneDragRearrange` writes it, `TerminalPane`
/// draws it — the store's published copy is what keeps the two in step.
struct PaneDragState: Equatable {
    /// The pane being dragged.
    var source: Session.ID
    /// The visible pane under the pointer — `nil` over a divider, outside the
    /// terminal area, or off the window. The source pane itself is a valid
    /// hover but never a valid drop.
    var target: Session.ID?
    var zone: PaneDropZone?
}

/// iTerm2-style direct-manipulation rearrange (issue #183): while ⌘⌥⇧ is held,
/// the whole pane body is its drag handle — press anywhere on a pane, drag to
/// a drop zone on another pane, release to re-split (edge halves) or swap
/// (center). The chord *is* the handle because termio's panes are chromeless
/// libghostty surfaces with no title bar to grab; it also disambiguates
/// "rearrange" from terminal input, letting the app consume the events before
/// the surface (or a mouse-reporting TUI) ever sees them.
///
/// The wrapper instantiates its own view class, so — like `TerminalContextMenu`
/// — this hooks in one level up: local event monitors held for the app's
/// lifetime. The drag itself is plain geometry against the visible panes; the
/// release is one `dropPane` call into the store, which owns the tree mutation.
@MainActor
final class PaneDragRearrange {
    private weak var store: TermioStore?
    // Held for the app's lifetime; never removed.
    private var monitors: [Any] = []
    /// True from the chorded press to the release. Esc cancels the drag but
    /// leaves this set, so the tail of the gesture (the remaining dragged/up
    /// events) is still swallowed instead of leaking into the terminal.
    private var dragging = false
    private var cancelled = false
    private var cursorPushed = false

    /// The full rearrange chord. Only the modifiers that mean something here
    /// are compared: ⌘⌥⇧ must all be down and ⌃ must not be, while Caps Lock
    /// (routinely latched by CJK users to switch input sources) and fn are
    /// ignored — an exact-mask match would let them silently defeat the
    /// gesture.
    static func isRearrangeChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .option, .shift, .control]) == [.command, .option, .shift]
    }

    init(store: TermioStore) {
        self.store = store
        // Local event monitors are always called on the main thread; the
        // annotation just can't say so (see `TerminalContextMenu`).
        func monitor(_ mask: NSEvent.EventTypeMask,
                     _ handler: @escaping @MainActor (NSEvent) -> Bool) {
            let installed = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { handler(event) }
                return consumed ? nil : event
            }
            if let installed { monitors.append(installed) }
        }
        monitor(.leftMouseDown) { [weak self] in self?.began($0) ?? false }
        monitor(.leftMouseDragged) { [weak self] in self?.moved($0) ?? false }
        monitor(.leftMouseUp) { [weak self] in self?.ended($0) ?? false }
        monitor(.keyDown) { [weak self] in self?.pressedKey($0) ?? false }
    }

    /// Starts a drag on a chorded press over a visible pane. Only meaningful
    /// with a split on screen: a lone pane has nowhere to go, and a zoomed
    /// pane hides the layout the drop zones would preview.
    private func began(_ event: NSEvent) -> Bool {
        guard let store, !dragging,
              Self.isRearrangeChord(event.modifierFlags),
              store.splitRoot != nil, !store.isPaneZoomed,
              !(store.isDetailPresented && store.inspectorMaximized),
              let window = event.window,
              window.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName,
              let contentView = window.contentView,
              let (id, _) = pane(at: event.locationInWindow, in: contentView, window: window)
        else { return false }
        dragging = true
        cancelled = false
        store.paneDrag = PaneDragState(source: id)
        NSCursor.closedHand.push()
        cursorPushed = true
        return true
    }

    /// Tracks the pointer across panes. Once a drag has begun the modifiers no
    /// longer matter — releasing the chord mid-drag doesn't drop the pane on
    /// the floor, the mouse button does.
    private func moved(_ event: NSEvent) -> Bool {
        guard dragging else { return false }
        guard !cancelled, let store, var drag = store.paneDrag,
              let window = event.window, let contentView = window.contentView
        else { return true }
        let hit = pane(at: event.locationInWindow, in: contentView, window: window)
        drag.target = hit?.0
        drag.zone = hit?.1
        store.paneDrag = drag
        return true
    }

    private func ended(_ event: NSEvent) -> Bool {
        guard dragging else { return false }
        defer { finish() }
        guard !cancelled, let store, let drag = store.paneDrag,
              let target = drag.target, let zone = drag.zone,
              target != drag.source else { return true }
        store.dropPane(drag.source, onto: target, zone: zone)
        return true
    }

    /// Esc abandons the drag. The mouse is still down, so `dragging` stays set
    /// and the gesture's tail is swallowed until the release.
    private func pressedKey(_ event: NSEvent) -> Bool {
        guard dragging, !cancelled, event.keyCode == 53 else { return false }
        cancelled = true
        store?.paneDrag = nil
        popCursorIfNeeded()
        return true
    }

    private func finish() {
        dragging = false
        cancelled = false
        store?.paneDrag = nil
        popCursorIfNeeded()
    }

    private func popCursorIfNeeded() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }

    /// The visible pane under a window point, and the drop zone within it.
    /// Resolved by geometry rather than `hitTest` for the same reason as
    /// `TerminalContextMenu`: invisible siblings stay mounted at full pane
    /// size, so AppKit's topmost hit may be a hidden view. Visible panes tile
    /// without overlapping, so "contains the point and is visible" is
    /// unambiguous.
    private func pane(at point: NSPoint, in contentView: NSView,
                      window: NSWindow) -> (Session.ID, PaneDropZone)? {
        guard let store else { return nil }
        for view in terminalViews(in: contentView) {
            guard view.window === window,
                  view.convert(view.bounds, to: nil).contains(point),
                  let id = sessionID(for: view),
                  store.visiblePaneIDs.contains(id) else { continue }
            let local = view.convert(point, from: nil)
            // Zone space is top-left-origin; flip out of AppKit's default.
            let normalized = CGPoint(x: local.x,
                                     y: view.isFlipped ? local.y : view.bounds.height - local.y)
            return (id, PaneDropZone.zone(at: normalized, in: view.bounds.size))
        }
        return nil
    }

    // The two resolution helpers below mirror `TerminalContextMenu`'s private
    // copies — small enough that sharing them isn't worth coupling the two
    // interceptors.

    /// All terminal surface views under `root`, in tree order.
    private func terminalViews(in root: NSView) -> [TerminalView] {
        var found: [TerminalView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let terminal = view as? TerminalView { found.append(terminal) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Maps a surface view back to its session through the store's surface
    /// cache — the view and its cached `TerminalViewState` share a controller.
    private func sessionID(for view: TerminalView) -> Session.ID? {
        store?.surfaces.first { $0.value.controller === view.controller }?.key
    }
}
