import AppKit
import SwiftUI
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

    /// Ghostty's handle dimensions (`SurfaceGrabHandle`), centered in the card's
    /// header, so a press on it never reaches the terminal.
    static let handleSize = CGSize(width: 80, height: 12)

    /// The handle's rect in a card of `size`, top-left origin — the space both
    /// this hit test and `TerminalPane`'s overlay work in. Centred, but only in the header's
    /// free run between the leading close and the trailing buttons: on a narrow card, or one
    /// notched for the window's controls, a full-width handle would sit under a control and
    /// take its press. It narrows to fit, and a run too short for a grip has none.
    static func handleRect(in size: CGSize, notchWidth: CGFloat, controlsMinX: CGFloat?) -> CGRect? {
        let start = PaneCard.closeSlotEnd(notchWidth: notchWidth)
        let end = controlsMinX ?? size.width
        let width = min(handleSize.width, end - start)
        guard width >= minimumHandleWidth else { return nil }
        let x = min(max((size.width - width) / 2, start), end - width)
        return CGRect(x: x, y: (PaneCard.headerHeight - handleSize.height) / 2,
                      width: width, height: handleSize.height)
    }

    private static let minimumHandleWidth: CGFloat = 24

    private func isOnHandle(_ hit: PaneHit) -> Bool {
        let geometry = PaneCardGeometry.shared
        return Self.handleRect(in: hit.size, notchWidth: geometry.notchWidth(hit.id),
                               controlsMinX: geometry.controlsMinX(hit.id))?.contains(hit.point) ?? false
    }

    /// The header reveals the handle.
    private static func isInHoverRegion(_ point: CGPoint, in size: CGSize) -> Bool {
        point.y >= 0 && point.y <= min(size.height, PaneCard.headerHeight)
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
            self?.clearStrandedDropCue()
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
        setHover(PaneHandleHover(pane: hit.id, overHandle: isOnHandle(hit)))
    }

    /// Takes down a sidebar-drag cue that outlived its drag.
    ///
    /// The panes' drop delegate clears the cue on exit and on drop, but SwiftUI
    /// gives a `DropDelegate` no "the session ended" hook, so a drag ending where
    /// neither fires would strand the highlight. Mouse-moved events resume the
    /// moment a drag session lets go of the pointer, and a drag cannot be in flight
    /// with the button up — making this the first thing to run after any drag,
    /// however it ended, for the cost of a comparison the rest of the time.
    private func clearStrandedDropCue() {
        guard let store, NSEvent.pressedMouseButtons & 1 == 0,
              store.sessionDropTarget != nil || store.sessionRowDrop != nil
                  || store.sessionRowGroupTarget != nil || store.draggingSessionID != nil
        else { return }
        store.sessionDropTarget = nil
        // The rows drawn out of order for a drop that never came slide back.
        withAnimation(TermioStore.rowReflow) { store.endSessionRowDrag() }
    }

    /// Republishing on every mouse-moved event would redraw the pane tree at
    /// pointer rate; only a change is worth a render.
    private func setHover(_ hover: PaneHandleHover?) {
        guard let store, store.paneHandleHover != hover else { return }
        store.paneHandleHover = hover
    }

    // MARK: - Drag

    /// Starts a drag from a press on a pane's grab handle. Any press in a card also focuses it.
    private func began(_ event: NSEvent) -> Bool {
        guard let store, !dragging,
              let hit = rearrangeablePane(under: event)
        else { return false }
        // A press anywhere in a card makes it the focused one — the bright border, the
        // header's buttons, the panel. The surface becoming first responder was the only
        // path, and a click could move the keyboard to a terminal without that report
        // arriving, leaving the border on the card the user had just left. Not consumed:
        // the press still reaches the terminal.
        if store.selectedSessionID != hit.id { store.selectedSessionID = hit.id }
        guard isOnHandle(hit),
              let contentView = event.window?.contentView
        else { return false }
        dragging = true
        cancelled = false
        // Snapshot before anything moves, the way ghostty builds its drag image.
        // A surface that won't cache leaves this nil and the drag runs without a
        // preview rather than showing a blank card.
        store.paneDragPreview = surface(for: hit.id, in: contentView)?.paneSnapshot
        store.paneDrag = PaneDragState(source: hit.id,
                                       pointer: PanePointer(pane: hit.id, local: hit.point))
        // The overlay washes translucently over live surfaces, which have to
        // keep producing frames for the length of the gesture.
        store.beginPaneDragRepaint()
        // The hand closes on the press, over the open hand of the handle's cursor rect.
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
              MainWindowController.isMain(window),
              let contentView = window.contentView
        else { return nil }
        return paneGeometry(at: event.locationInWindow, in: contentView, window: window)
    }

    /// A visible pane, the pointer in its card's top-left-origin space, and the
    /// card's size — what the handle hit test and the drop-zone lookup are both
    /// expressed in, and the frames `TerminalPane` lays the cards out at.
    private typealias PaneHit = (id: Session.ID, point: CGPoint, size: CGSize)

    /// Resolved by geometry rather than `hitTest` for the same reason as
    /// `TerminalContextMenu`: invisible siblings stay mounted and laid out, so
    /// AppKit's topmost hit may be a hidden view. Visible panes tile without
    /// overlapping, so "contains the point and is visible" is unambiguous.
    private func paneGeometry(at point: NSPoint, in contentView: NSView,
                              window: NSWindow) -> PaneHit? {
        guard let store else { return nil }
        // A press on a panel laid over a card's terminal is the panel's, not the pane's.
        if InspectorPanelHost.shared.contains(point, in: window, store: store) { return nil }
        let geometry = PaneCardGeometry.shared
        for (view, id) in surfaces(in: contentView) {
            guard view.window === window,
                  store.visiblePaneIDs.contains(id) else { continue }
            // The surface sits inside its card: under the header, inside the border, and before
            // any panel beside it. Window space is bottom-left-origin, so the header is above `maxY`.
            let surface = view.convert(view.bounds, to: nil)
            let border = PaneCard.borderWidth
            let card = geometry.cardFrame(for: id, in: window)
                ?? CGRect(x: surface.minX - border, y: surface.minY - border,
                          width: surface.width + 2 * border,
                          height: surface.height + PaneCard.headerHeight + border)
            guard card.contains(point) else { continue }
            // A panel over the terminal — the picture an unfocused card's panel left included —
            // takes the presses on it; the header above it is still the card's.
            if geometry.panelCovers(id), point.y < card.maxY - PaneCard.headerHeight { return nil }
            let local = CGPoint(x: point.x - card.minX, y: card.maxY - point.y)
            return (id, local, card.size)
        }
        return nil
    }

    private func surface(for id: Session.ID, in root: NSView) -> NSView? {
        surfaces(in: root).first { $0.id == id }?.view
    }

    /// Every pane surface under `root` with its session, in tree order: the embedded
    /// Ghostty surface, and the stream pane that termiod sessions draw in by default.
    /// Looking for the embedded kind alone left a stream pane with no handle to drag.
    private func surfaces(in root: NSView) -> [(view: NSView, id: Session.ID)] {
        var found: [(view: NSView, id: Session.ID)] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let stream = view as? TermiodStreamView, let id = stream.sessionID {
                found.append((stream, id))
            } else if let terminal = view as? TerminalView, let id = sessionID(for: terminal) {
                found.append((terminal, id))
            }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Maps a surface view back to its session through the store's surface
    /// cache — the view and its cached `TerminalViewState` share a controller.
    /// Mirrors `TerminalContextMenu`'s private copy.
    private func sessionID(for view: TerminalView) -> Session.ID? {
        store?.surfaces.first { $0.value.controller === view.controller }?.key
    }
}

private extension NSView {
    /// A still of the view, the way ghostty builds its drag image
    /// (`SurfaceView.asImage`). Nil for an empty or uncacheable view, so callers
    /// degrade to no preview.
    var paneSnapshot: NSImage? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        // A stream pane draws into a Metal layer, which `cacheDisplay` cannot read.
        if let stream = self as? TermiodStreamView {
            return stream.screenImage().map { NSImage(cgImage: $0, size: bounds.size) }
        }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
