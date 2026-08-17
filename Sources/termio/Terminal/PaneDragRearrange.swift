import AppKit
import GhosttyTerminal

/// Which pane is showing its grab handle, and whether the pointer is on the
/// handle itself rather than in the band that reveals it — ghostty dims the
/// glyph in the band and brightens it under the pointer.
struct PaneHandleHover: Equatable {
    var pane: Session.ID
    var overHandle: Bool
}

/// A point inside a pane, in that pane's top-left-origin space.
struct PanePointer: Equatable {
    var pane: Session.ID
    var local: CGPoint
}

/// A pane drag in flight: the lifted pane, plus the pane and drop zone under the
/// pointer right now. `PaneDragRearrange` writes it, `TerminalPane` draws it —
/// the store's published copy keeps the two in step.
struct PaneDragState: Equatable {
    var source: Session.ID
    /// The visible pane under the pointer — nil over a divider, outside the
    /// terminal area, or off the window. The source pane is a valid hover but
    /// never a valid drop.
    var target: Session.ID?
    var zone: PaneDropZone?
    /// Where the pointer is, in the form the hit test already produces — enough
    /// for the overlay to place the drag preview without a second coordinate
    /// bridge.
    var pointer: PanePointer?
}

/// Direct-manipulation rearrange (issue #183) through ghostty's grab handle: a
/// strip at the top of each pane, revealed as the pointer reaches it, that drags
/// the pane onto a drop zone on another — release to re-split (edge halves) or
/// swap (center).
///
/// The gesture used to be a ⌘⌥⇧ chord over the pane body, which worked and
/// nobody could find. Ghostty's answer to the same problem — chromeless surfaces
/// with no title bar to grab — is a visible handle (`SurfaceGrabHandle`), and a
/// handle explains itself.
///
/// Like `TerminalContextMenu`, this hooks in one level above the wrapper's own
/// view class: local event monitors held for the app's lifetime. Hit-testing the
/// handle here rather than mounting a view over the surface is what keeps the
/// press from ever reaching a mouse-reporting TUI. The drag is plain geometry
/// against the visible panes; the release is one `dropPane` call into the store,
/// which owns the tree mutation.
@MainActor
final class PaneDragRearrange {
    private weak var store: TermioStore?
    // Held for the app's lifetime; never removed.
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// True from the press to the release. Esc cancels the drag but leaves this
    /// set, so the tail of the gesture is still swallowed rather than leaking
    /// into the terminal.
    private var dragging = false
    private var cancelled = false
    private var cursorPushed = false
    private var hoverCursorPushed = false

    /// Ghostty's handle dimensions (`SurfaceGrabHandle`), centered on the pane's
    /// top edge. Small on purpose — it is the only place a plain click is taken
    /// from the terminal.
    static let handleSize = CGSize(width: 80, height: 12)

    /// The band that reveals the handle. Ghostty uses the pane's top *fifth*,
    /// which on a tall pane is deep enough to park a pointer in — and since
    /// mouse-moved events only arrive while the mouse moves, a parked pointer
    /// leaves the handle up until the next move. A header-sized strip is still a
    /// wide target for a 12pt handle.
    private static let hoverBandHeight: CGFloat = 28

    /// The handle's rect in a pane of `size`, top-left origin — the space both
    /// this hit test and `TerminalPane`'s overlay work in.
    static func handleRect(in size: CGSize) -> CGRect {
        CGRect(x: (size.width - handleSize.width) / 2, y: 0,
               width: handleSize.width, height: handleSize.height)
    }

    private static func isInHoverRegion(_ point: CGPoint, in size: CGSize) -> Bool {
        point.y >= 0 && point.y <= min(size.height, hoverBandHeight)
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
        monitor(.leftMouseUp) { [weak self] _ in self?.ended() ?? false }
        monitor(.keyDown) { [weak self] in self?.pressedKey($0) ?? false }
        // Never consumed: the reveal only reads the pointer, so it can't
        // interfere with a TUI's own mouse reporting.
        monitor(.mouseMoved) { [weak self] in
            self?.hovered($0)
            return false
        }
        // A pointer that leaves for another app sends no further mouse-moved
        // events, so the last reveal would hang on screen until it came back.
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setHover(nil) }
            }
            observers.append(token)
        }
    }

    // MARK: - Hover

    private func hovered(_ event: NSEvent) {
        guard !dragging, let hit = rearrangeablePane(under: event),
              Self.isInHoverRegion(hit.point, in: hit.size)
        else { return setHover(nil) }
        setHover(PaneHandleHover(pane: hit.id,
                                 overHandle: Self.handleRect(in: hit.size).contains(hit.point)))
    }

    /// Republishing on every mouse-moved event would redraw the pane tree at
    /// pointer rate; only a change is worth a render.
    private func setHover(_ hover: PaneHandleHover?) {
        guard let store, store.paneHandleHover != hover else { return }
        store.paneHandleHover = hover
        setHoverCursor(hover?.overHandle == true)
    }

    /// The open hand over the handle, mirroring ghostty's cursor rects. A drawn
    /// handle has no view to hang a rect on, and a plain `set()` loses the race:
    /// this monitor runs before the event reaches the surface, which then puts
    /// the I-beam back on its own cursor update. A pushed cursor outranks that.
    private func setHoverCursor(_ overHandle: Bool) {
        guard overHandle != hoverCursorPushed else { return }
        if overHandle { NSCursor.openHand.push() } else { NSCursor.pop() }
        hoverCursorPushed = overHandle
    }

    // MARK: - Drag

    /// Starts a drag from a press on a pane's grab handle.
    private func began(_ event: NSEvent) -> Bool {
        guard let store, !dragging,
              let hit = rearrangeablePane(under: event),
              Self.handleRect(in: hit.size).contains(hit.point),
              let contentView = event.window?.contentView
        else { return false }
        dragging = true
        cancelled = false
        // Snapshot before anything moves, the way ghostty builds its drag image.
        // A surface that won't cache leaves this nil and the drag runs without a
        // preview rather than showing a blank card.
        store.paneDragPreview = terminalView(for: hit.id, in: contentView)?.paneSnapshot
        store.paneDrag = PaneDragState(source: hit.id,
                                       pointer: PanePointer(pane: hit.id, local: hit.point))
        // The overlay washes translucently over live surfaces, which have to
        // keep producing frames for the length of the gesture.
        store.beginPaneDragRepaint()
        // The hand closes on the press; drop the hover cursor so the two can't
        // stack up.
        setHoverCursor(false)
        NSCursor.closedHand.push()
        cursorPushed = true
        return true
    }

    /// Tracks the pointer across panes. Once a drag has begun only the mouse
    /// button ends it.
    private func moved(_ event: NSEvent) -> Bool {
        guard dragging else { return false }
        guard !cancelled, let store, var drag = store.paneDrag,
              let window = event.window, let contentView = window.contentView
        else { return true }
        let hit = paneGeometry(at: event.locationInWindow, in: contentView, window: window)
        drag.target = hit?.id
        drag.zone = hit.map { PaneDropZone.zone(at: $0.point, in: $0.size) }
        // Off every pane (a divider, the sidebar) the preview holds its last
        // position rather than snapping to a corner.
        if let hit { drag.pointer = PanePointer(pane: hit.id, local: hit.point) }
        store.paneDrag = drag
        return true
    }

    private func ended() -> Bool {
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
        clearDrag()
        popCursorIfNeeded()
        return true
    }

    private func finish() {
        dragging = false
        cancelled = false
        clearDrag()
        // The drop rebuilt the layout under the pointer, so whichever pane was
        // showing a handle may not be there any more; the next move decides.
        setHover(nil)
        popCursorIfNeeded()
    }

    /// Drops the overlay and stops the drag pump — whose parting repaint is what
    /// clears the wash back off the panes.
    private func clearDrag() {
        store?.paneDrag = nil
        store?.paneDragPreview = nil
        store?.endPaneDragRepaint()
    }

    private func popCursorIfNeeded() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }

    // MARK: - Geometry

    /// The pane under the pointer, once everything that makes a rearrange
    /// meaningful holds: a split on screen, not zoomed, no full-window inspector
    /// over it, and the pointer in the key main window.
    private func rearrangeablePane(under event: NSEvent) -> PaneHit? {
        guard let store, store.splitRoot != nil, !store.isPaneZoomed,
              !(store.isDetailPresented && store.inspectorMaximized),
              let window = event.window, window.isKeyWindow,
              window.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName,
              let contentView = window.contentView
        else { return nil }
        return paneGeometry(at: event.locationInWindow, in: contentView, window: window)
    }

    /// A visible pane, the pointer in its top-left-origin space, and its size —
    /// what the handle hit test and the drop-zone lookup are both expressed in.
    private typealias PaneHit = (id: Session.ID, point: CGPoint, size: CGSize)

    /// Resolved by geometry rather than `hitTest` for the same reason as
    /// `TerminalContextMenu`: invisible siblings stay mounted and laid out, so
    /// AppKit's topmost hit may be a hidden view. Visible panes tile without
    /// overlapping, so "contains the point and is visible" is unambiguous.
    private func paneGeometry(at point: NSPoint, in contentView: NSView,
                              window: NSWindow) -> PaneHit? {
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
            return (id, normalized, view.bounds.size)
        }
        return nil
    }

    private func terminalView(for id: Session.ID, in root: NSView) -> TerminalView? {
        terminalViews(in: root).first { sessionID(for: $0) == id }
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

private extension NSView {
    /// A still of the view, the way ghostty builds its drag image
    /// (`SurfaceView.asImage`). Nil for an empty or uncacheable view, so callers
    /// degrade to no preview.
    var paneSnapshot: NSImage? {
        guard bounds.width > 1, bounds.height > 1,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
