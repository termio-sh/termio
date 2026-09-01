import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GhosttyTerminal
import TermioShared

extension Notification.Name {
    /// Posted by the toolbar's close button to dismiss whichever content overlay (file editor,
    /// diff, or preview) covers the terminal. `TerminalPane` handles it, running the same teardown
    /// — clear the store, hand focus back to the terminal — the overlays' own Esc / close use, so
    /// the toolbar and in-overlay close paths stay identical.
    static let termioCloseContentOverlay = Notification.Name("termio.closeContentOverlay")

    /// Dev-only fault injector for the hollow-cursor focus race. The selected terminal is
    /// made first responder, then deliberately resigned while the main window stays key.
    /// Fired from the command palette's "Debug: Orphan Terminal Focus".
    static let termioDebugOrphanFocus = Notification.Name("termio.debugOrphanFocus")

    /// Dev-only: log the selected terminal's CALayer tree, to tell a doubled or
    /// stale render layer from a presentation-timing artifact while a glitch is
    /// on screen. Fired from the command palette's "Debug: Dump Terminal Layers".
    static let termioDebugDumpLayers = Notification.Name("termio.debugDumpLayers")
}

/// Right column. Every session that has been opened stays *mounted* here for the
/// app's lifetime; switching sessions only flips opacity and keyboard focus.
///
/// The earlier design swapped the visible terminal with `.id(session.id)`, which
/// made SwiftUI destroy the old surface view and build a fresh one on every
/// switch. A fresh `TerminalView` lays out from a zero frame, so libghostty calls
/// `ghostty_surface_set_size` — a SIGWINCH the shell answers by repainting its
/// prompt. That resize-on-every-switch was the visible flicker. Keeping each
/// surface mounted and only toggling visibility means the view is never
/// reparented or resized, so the shell never repaints and switching is instant.
///
/// A split group has to obey the same rule, so a pane's frame comes from its
/// *own* group's layout (`SplitNode.paneFrames`), computed for every group
/// rather than only the selected one. A group that is off screen therefore keeps
/// the frames it had, and only a genuine geometry change — window resize,
/// inspector toggle, ratio drag, group/ungroup, zoom — ever resizes a surface.
struct TerminalPane: View {
    /// The pane area's named coordinate space — the fixed frame the split
    /// dividers' drags are measured in (see the ZStack's `coordinateSpace`).
    static let splitCoordinateSpace = "termio.splitPane"
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @State private var focusDriver = TerminalFocusDriver()
    @State private var activated: [Session.ID] = []

    var body: some View {
        GeometryReader { geo in
            // The terminal group fills the whole pane. File editors, diffs and PR/issue details
            // now open in the right inspector (see `InspectorDetailHost`) rather than covering
            // the terminal, so this pane is only ever terminal surfaces + split dividers.
            let bounds = CGRect(origin: .zero, size: geo.size)
            let layout = store.splitRoot?.layout(in: bounds)
            let zoomed = store.isPaneZoomed && layout != nil
            terminalGroup(bounds: bounds, layout: layout, zoomed: zoomed)
                .frame(width: geo.size.width, height: geo.size.height)
                .coordinateSpace(name: Self.splitCoordinateSpace)
        }
        // Paint the terminal's own background behind the pane, extending up under the toolbar so
        // the system toolbar material picks up a terminal tint instead of a flat grey band.
        .background(paneBackground.ignoresSafeArea(.container, edges: .top))
        // The ⌘⇧O/⌘⇧P palette lives in its own floating NSPanel (owned by
        // the app delegate — a SwiftUI overlay would render *under* the NSView
        // terminal surfaces); this only hands focus back to the terminal when
        // it closes.
        .onChange(of: store.paletteMode) { _, mode in
            if mode == nil { requestSelectedTerminalFocus(reason: .paletteClosed) }
        }
        // Every visible pane must be mounted — with splits that is all the
        // tree's leaves, not just the selection.
        .onChange(of: store.visiblePaneIDs, initial: true) { _, ids in
            for id in ids where !activated.contains(id) {
                activated.append(id)
            }
        }
        // A background-driven session (a sibling spawn, a `send` to a pane never
        // shown) mounts invisibly so its surface attaches without the selection
        // moving; the focus paths all gate on visibility, so it stays silent.
        .onChange(of: store.backgroundActivationIDs, initial: true) { _, ids in
            for id in ids where !activated.contains(id) {
                activated.append(id)
            }
        }
        .onChange(of: store.selectedSessionID, initial: true) { _, id in
            if let id, !activated.contains(id) {
                activated.append(id)
            }
            // The inspector layout now follows the session: `TermioStore.selectedSessionID`
            // saves the outgoing session's open detail and restores the incoming one's
            // (issue #160), so we no longer clear the overlays here. The editor overlay's
            // `.onDisappear` still flushes any pending auto-save when a restore replaces it.
            requestSelectedTerminalFocus(reason: .selectionChanged)
        }
        // The toolbar's close button posts this; tear the overlay down the same way the overlay's
        // own Esc / close does (clear the store, return focus to the selected session's terminal).
        .onReceive(NotificationCenter.default.publisher(for: .termioCloseContentOverlay)) { _ in
            // Tear down top-down: a stacked PR file diff closes first, revealing the detail;
            // a second press then closes the detail (matching the overlay's own Esc handling).
            if store.openDiff != nil {
                store.openDiff = nil
            } else {
                store.openFileURL = nil
                store.cancelRemoteFileOpen()
                store.openIssueDetail = nil
            }
            requestSelectedTerminalFocus(reason: .overlayClosed)
        }
        // Dev-only: perform the real AppKit failure while the main window stays key.
        // The driver focuses the selected TerminalView, resigns it to nil on the next
        // runloop, then uses the same orphan repair as a sibling-driven surface update.
        .onReceive(NotificationCenter.default.publisher(for: .termioDebugOrphanFocus)) { _ in
            injectTerminalFocusOrphan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .termioDebugDumpLayers)) { _ in
            dumpSelectedTerminalLayers()
        }
        // Window-key status is separate from surface focus, matching Ghostty. Becoming
        // key asks the driver to repair an orphan; it does not mutate a FocusState.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName
            else { return }
            requestSelectedTerminalFocus(reason: .windowBecameKey)
        }
    }

    /// The terminal-side ZStack: the flat mount for every terminal surface plus the split-tree
    /// dividers. Extracted from `body` so it can be sized independently when a file preview
    /// occupies the right column.
    @ViewBuilder
    private func terminalGroup(bounds: CGRect, layout: SplitNode.PaneLayout?, zoomed: Bool) -> some View {
        // Geometry for *every* group, not just the one on screen. Visibility is
        // decided separately, below: hiding a group must not move or resize its
        // panes, because a frame change is a SIGWINCH the shell answers by
        // repainting — the flash on the way back in (issue #245).
        let paneFrames = SplitNode.paneFrames(of: store.splitGroups, in: bounds)
        let visibleIDs = Set(store.visiblePaneIDs)
        ZStack {
            if mounted.isEmpty {
                WelcomeView()
            }
            ForEach(mounted, id: \.session.id) { item in
                let id = item.session.id
                let isSelected = store.selectedSessionID == id
                let isVisible = zoomed ? isSelected : visibleIDs.contains(id)
                // Zoom is a real geometry change, so the zoomed pane does take the
                // full bounds; its hidden siblings keep their laid-out frames. An
                // ungrouped session has no split geometry and fills the pane.
                let rect = zoomed && isSelected ? bounds : (paneFrames[id] ?? bounds)
                let context = store.surface(for: item.session)
                SharedGridLetterbox(
                    runtime: store.runtime(for: id),
                    context: context,
                    paneSize: rect.size,
                    paddingX: CGFloat(settings.windowPadding),
                    background: paneBackground,
                    onViewport: { grid in store.reportViewport(grid, for: id) }
                ) {
                    ManagedTerminalSurface(
                        context: context,
                        isSelected: isSelected,
                        isVisible: isVisible,
                        onFocused: { selectFocusedSurface(id) },
                        onVisibility: { store.reportRendering($0, for: id) },
                        requestFocus: { reason in
                            requestTerminalFocus(for: id, reason: reason)
                        }
                    )
                }
                .frame(width: rect.width, height: rect.height)
                // Dropping a file (dragged from the file-tree inspector, the Issues list or
                // the Finder) inserts its shell-quoted path at the prompt — the prebuilt
                // libghostty surface does not register for file drops itself, so each pane
                // catches them and feeds the path to *its own* session. No trailing return,
                // so the path is inserted for the user (or the agent) to act on rather than run.
                //
                // This must sit above `.position`, which grows the modified view to fill the
                // whole terminal group: a drop destination applied after it would accept the
                // drag anywhere, and the topmost pane in the stack would swallow every drop.
                // One destination per pane, for every kind of drop. Two destinations over
                // the same pane cannot be made to agree: whichever one loses the drop is
                // never told the drag left, and its highlight stays on screen forever.
                .onDrop(of: [.url, .fileURL, .text], delegate: PaneDropDelegate(
                    pane: id,
                    size: rect.size,
                    isVisible: isVisible,
                    store: store,
                    send: { sendPaths($0, to: id) }
                ))
                .position(x: rect.midX, y: rect.midY)
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
            }
            if let layout, !zoomed {
                ForEach(layout.dividers) { divider in
                    SplitDividerHandle(spec: divider) { ratio in
                        store.updateSplitRatio(branchID: divider.id, ratio: ratio)
                    }
                }
            }
            // The handle that starts a rearrange, on the pane the pointer is
            // near (see `PaneDragRearrange`). Never hit-testable: the press is
            // taken by the event monitor, so this is purely the affordance.
            if let layout, !zoomed, store.paneDrag == nil,
               let hovered = store.paneHandleHover, let frame = layout.frames[hovered.pane] {
                PaneGrabHandle(paneFrame: frame, isOverHandle: hovered.overHandle)
                    .allowsHitTesting(false)
            }
            // The drag's preview (issue #183): the drop-zone highlight is what
            // resolves the ambiguity a drag-rearrange otherwise has — you see
            // the half (or the swap) the release would commit.
            if let drag = store.paneDrag, let layout, !zoomed {
                PaneDragOverlay(drag: drag, layout: layout, preview: store.paneDragPreview)
            }
            // Under the wash, so the pane you are carrying can still show a target
            // on it — the two say different things and have to be able to coexist.
            SessionDragLift(rect: draggedPaneRect(bounds: bounds, paneFrames: paneFrames, zoomed: zoomed))
            // Dragging a file, an issue or a session in reads the same as dragging a
            // pane around: the identical wash over what the release would land in,
            // sliding as the pointer moves rather than blinking. A whole pane means
            // the payload is typed at its prompt; a half means the layout changes.
            PaneDropWash(rect: dropWashRect(bounds: bounds, paneFrames: paneFrames, zoomed: zoomed))
        }
        // Ghostty's own timing (`SurfaceDragSource`): the handle fades in and
        // brightens rather than blinking. The drag overlay animates its own
        // pieces — the highlight slides, the preview must not.
        .animation(.easeInOut(duration: 0.15), value: store.paneHandleHover)
    }

    /// What the in-flight drop would land on. A `.center` target highlights the
    /// whole pane (the payload is typed at its prompt), an edge the half the layout
    /// would give up — one piece of state for both cues, so they cannot disagree.
    ///
    /// The mouse-button test is what keeps the cue from being stranded. SwiftUI
    /// gives a `DropDelegate` no "the session ended" callback, so a drag that ends
    /// where neither `dropExited` nor `performDrop` fires would leave its highlight
    /// on screen for good. A drag cannot exist with the button up.
    private func dropWashRect(bounds: CGRect, paneFrames: [Session.ID: CGRect],
                              zoomed: Bool) -> CGRect {
        guard let target = store.sessionDropTarget, NSEvent.pressedMouseButtons & 1 != 0
        else { return .zero }
        let frame = zoomed && store.selectedSessionID == target.pane
            ? bounds : (paneFrames[target.pane] ?? bounds)
        return target.zone.highlightRect(in: frame)
    }

    /// The on-screen pane of the session being dragged out of the sidebar, or
    /// `.zero` when it has none — the usual case, since you drag a session
    /// precisely because it is not the one you are looking at. Guarded on the mouse
    /// button for the same reason as the wash.
    private func draggedPaneRect(bounds: CGRect, paneFrames: [Session.ID: CGRect],
                                 zoomed: Bool) -> CGRect {
        guard let dragged = store.draggingSessionID, NSEvent.pressedMouseButtons & 1 != 0,
              store.visiblePaneIDs.contains(dragged) else { return .zero }
        return zoomed && store.selectedSessionID == dragged
            ? bounds : (paneFrames[dragged] ?? bounds)
    }

    /// A surface becoming first responder is the source of truth for split selection.
    /// Each mounted surface owns an independent Boolean FocusState, so one surface
    /// resigning can no longer clear the focus intent of every sibling.
    private func selectFocusedSurface(_ id: Session.ID) {
        guard id != store.selectedSessionID,
              store.visiblePaneIDs.contains(id) else { return }
        store.selectedSessionID = id
    }

    private func requestSelectedTerminalFocus(reason: TerminalFocusReason) {
        guard let id = store.selectedSessionID else { return }
        requestTerminalFocus(for: id, reason: reason)
    }

    /// Mirrors Ghostty's `moveFocus`: resolve the selected AppTerminalView by its
    /// TerminalViewState delegate, retry with capped exponential backoff until it is
    /// windowed, and explicitly resign the previously focused surface before moving.
    private func requestTerminalFocus(for id: Session.ID, reason: TerminalFocusReason) {
        guard let session = store.session(id) else { return }
        let state = store.surface(for: session)
        focusDriver.moveFocus(
            to: state,
            sessionID: id,
            reason: reason,
            canFocus: { [weak store] in
                guard let store else { return false }
                return store.selectedSessionID == id
                    && store.visiblePaneIDs.contains(id)
                    && store.openFileURL == nil
                    && store.openingRemoteFile == nil
                    && store.openDiff == nil
                    && store.paletteMode == nil
            }
        )
    }

    private func injectTerminalFocusOrphan() {
        guard AppChannel.isDev,
              let id = store.selectedSessionID,
              let session = store.session(id) else { return }
        let state = store.surface(for: session)
        focusDriver.injectOrphan(
            in: state,
            sessionID: id,
            canFocus: { [weak store] in
                guard let store else { return false }
                return store.selectedSessionID == id
                    && store.visiblePaneIDs.contains(id)
                    && store.openFileURL == nil
                    && store.openingRemoteFile == nil
                    && store.openDiff == nil
                    && store.paletteMode == nil
            },
            repair: { requestTerminalFocus(for: id, reason: .faultInjector) }
        )
    }

    /// Inserts the dropped files' paths into the dropped-on pane's terminal,
    /// space-separated and each shell-quoted so spaces and other special characters
    /// survive. Focuses the session first (VSCode's focus-on-drop), and if its shell
    /// isn't attached yet, activates the session so its surface mounts and retries
    /// once it has come up. Returns whether a drop was accepted at all.
    private func sendPaths(_ urls: [URL], to id: Session.ID) -> Bool {
        guard !urls.isEmpty,
              let session = store.session(id) else { return false }
        // The drop is also a selection: the path lands where the pointer released, so
        // that pane takes the write token before focus moves (`requestTerminalFocus`
        // only focuses the selected session).
        store.selectedSessionID = id
        requestTerminalFocus(for: id, reason: .fileDrop)
        let text = urls.map { TermioStore.promptToken(for: $0) }.joined(separator: " ") + " "
        if store.surface(for: session).send(text) { return true }

        // The shell may not be attached yet (a freshly opened session whose surface
        // hasn't mounted). Selecting it above mounts the surface; retry a moment later, once.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !store.surface(for: session).send(text) {
                Log.pty.error("dropped path could not be sent — \(session.title, privacy: .public) has no live terminal")
            }
        }
        return true
    }

    private func dumpSelectedTerminalLayers() {
        guard AppChannel.isDev,
              let id = store.selectedSessionID,
              let session = store.session(id) else { return }
        let state = store.surface(for: session)
        focusDriver.dumpLayers(of: state, sessionID: id)
    }

    private struct MountedSession {
        let session: Session
    }

    /// The sessions to keep on screen: every activated id that still resolves to a
    /// live session (closed sessions drop out, which unmounts their surface).
    private var mounted: [MountedSession] {
        activated.compactMap { id in
            guard let session = store.session(id) else { return nil }
            return MountedSession(session: session)
        }
    }

    /// The terminal background fill, or clear when translucent — then the surface and
    /// window stay see-through.
    private var paneBackground: Color {
        settings.isBackgroundTranslucent ? .clear : Color(nsColor: settings.terminalBackgroundColor)
    }
}

// MARK: - Terminal focus

/// Why a focus request is being made. Explicit navigation may replace another
/// responder; background reconciliation and window activation may only repair the
/// narrow orphan shape (the main window itself, or nil, is first responder).
private enum TerminalFocusReason {
    case surfaceMounted
    case selectionChanged
    case surfaceUpdated
    case windowBecameKey
    case paletteClosed
    case overlayClosed
    case fileDrop
    case faultInjector

    var replacesCurrentResponder: Bool {
        switch self {
        case .surfaceMounted, .selectionChanged, .paletteClosed, .overlayClosed, .fileDrop:
            true
        case .surfaceUpdated, .windowBecameKey, .faultInjector:
            false
        }
    }

    var label: String {
        switch self {
        case .surfaceMounted: "surface-mounted"
        case .selectionChanged: "selection-changed"
        case .surfaceUpdated: "surface-updated"
        case .windowBecameKey: "window-became-key"
        case .paletteClosed: "palette-closed"
        case .overlayClosed: "overlay-closed"
        case .fileDrop: "file-drop"
        case .faultInjector: "fault-injector"
        }
    }
}

/// Lays a surface out at the grid another device is sizing the session to.
///
/// One PTY has one winsize, and every attachment parses the same bytes. The
/// daemon sizes the session to the smallest viewport being rendered, so while a
/// phone is watching, those bytes are wrapped for the phone's grid — and a
/// surface stretched across this pane would re-wrap them at its own width, the
/// §C.5 divergence: every line that wrapped on the phone lands somewhere else
/// here, and a TUI that repaints incrementally never repairs it. So a pane
/// larger than the session shows it at exactly the shared grid, centred, with
/// the terminal background around it — the same picture the phone has, at the
/// Mac's font. The phone leaves, the session springs back, and the surface
/// returns to the pane.
///
/// This is also where the pane states its *viewport* — how much it could show,
/// measured from its own geometry. The surface cannot answer that question once
/// it is letterboxed: it reports the grid it was shrunk to, so a pane that
/// declared what its surface reports could never say it had room for more, and
/// the session could never grow back. Not conditioned on the write token, which
/// no longer has anything to do with size.
///
/// The surface is sized to the grid plus half a cell: libghostty floors
/// `(size − padding) / cell` to get its column count, and an exact multiple can
/// round to one column short. A shared grid the pane cannot hold is still laid
/// out at that grid, anchored top-left and clipped: a surface at any other
/// width wraps the bytes wrong, and a correct screen with its edge cut off
/// beats a complete one that is scrambled. It also keeps the promise the
/// resync depends on — the surface *reaches* the shared grid, so the link can
/// ask for the keyframe that paints it (`observerRepaintPending`).
private struct SharedGridLetterbox<Content: View>: View {
    let runtime: SessionRuntime
    @ObservedObject var context: TerminalViewState
    let paneSize: CGSize
    let paddingX: CGFloat
    let background: Color
    let onViewport: (TerminalGrid) -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // One structure whether letterboxed or not: a branch here would give
        // the surface a new identity each time the session's size moved and
        // remount its NSView, which is the repaint this file exists to avoid. A
        // nil frame dimension is "no constraint", so the surface fills the pane.
        let size = letterboxSize
        let fits = size.map { $0.width <= paneSize.width && $0.height <= paneSize.height } ?? true
        ZStack(alignment: fits ? .center : .topLeading) {
            background
            content()
                .frame(width: size?.width, height: size?.height)
        }
        .frame(width: paneSize.width, height: paneSize.height, alignment: .topLeading)
        .clipped()
        // Outside the body's own evaluation, so declaring a viewport never
        // mutates state mid-render.
        .onChange(of: paneGrid, initial: true) { _, grid in
            if let grid { onViewport(grid) }
        }
    }

    /// How much this pane could show: libghostty's own floor of the space left
    /// after padding, so the number matches what the surface would report if it
    /// were filling the pane rather than sitting at the shared grid.
    private var paneGrid: TerminalGrid? {
        guard let cell = cellSize else { return nil }
        let paddingY = CGFloat(TermioStore.terminalWindowPaddingY)
        let cols = ((paneSize.width - 2 * paddingX) / cell.width).rounded(.down)
        let rows = ((paneSize.height - 2 * paddingY) / cell.height).rounded(.down)
        // A pane mid-teardown reports zero, and a NaN cell size would otherwise
        // trap on the way to `UInt16`.
        guard cols.isFinite, rows.isFinite, cols >= 1, rows >= 1 else { return nil }
        return TerminalGrid(
            rows: UInt16(clamping: Int(min(rows, 10_000))),
            cols: UInt16(clamping: Int(min(cols, 10_000))))
    }

    /// The size a surface at the shared grid takes, or nil to fill the pane.
    ///
    /// Half a cell of slack on each axis: libghostty floors
    /// `(size − padding) / cell` to get its column count, and an exact multiple
    /// can round to one column short. A shared grid the pane cannot hold is
    /// still laid out at that grid, anchored top-left and clipped: a surface at
    /// any other width wraps the bytes wrong, and a correct screen with its edge
    /// cut off beats a complete one that is scrambled. It also keeps the promise
    /// the resync depends on — the surface *reaches* the shared grid, so the
    /// link can ask for the keyframe that paints it (`repaintPending`).
    private var letterboxSize: CGSize? {
        // A pane already the session's size fills the pane exactly, with none of
        // the half-cell slack a letterbox needs, so the common case looks the
        // way it always did.
        guard let grid = runtime.sharedGrid, grid != paneGrid, let cell = cellSize
        else { return nil }
        let paddingY = CGFloat(TermioStore.terminalWindowPaddingY)
        let width = CGFloat(grid.cols) * cell.width + 2 * paddingX + cell.width / 2
        let height = CGFloat(grid.rows) * cell.height + 2 * paddingY + cell.height / 2
        return CGSize(width: width, height: height)
    }

    private var cellSize: CGSize? {
        guard let metrics = context.surfaceSize,
              metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0
        else { return nil }
        return CGSize(
            width: CGFloat(metrics.cellWidthPixels) / displayScale,
            height: CGFloat(metrics.cellHeightPixels) / displayScale)
    }
}

/// One focus state per terminal, matching Ghostty's SurfaceView model. The Boolean
/// binding is retained only to report a clicked split pane back to the store; moving
/// focus is handled from AppKit by TerminalFocusDriver, never by waiting for this value
/// to transition through nil.
private struct ManagedTerminalSurface: View {
    let context: TerminalViewState
    let isSelected: Bool
    let isVisible: Bool
    let onFocused: () -> Void
    /// The same fact `setSurfaceVisible` acts on, told to the daemon: a pane
    /// that is not showing is not rendering, and stops holding the session down
    /// to its width.
    let onVisibility: (Bool) -> Void
    let requestFocus: (TerminalFocusReason) -> Void

    @FocusState private var surfaceFocus: Bool

    var body: some View {
        TerminalSurfaceView(context: context)
            .terminalFocused($surfaceFocus)
            .background {
                // NSViewRepresentable.updateNSView runs after a parent/store-driven
                // reconciliation. Re-check first responder on the following runloop,
                // after any transient detach/resign has settled.
                TerminalFocusRepairProbe {
                    guard isSelected, isVisible else { return }
                    requestFocus(.surfaceUpdated)
                }
            }
            .onAppear {
                guard isSelected else { return }
                surfaceFocus = true
                requestFocus(.surfaceMounted)
            }
            .onChange(of: isSelected, initial: true) { _, selected in
                surfaceFocus = selected
                if selected { requestFocus(.selectionChanged) }
            }
            .onChange(of: surfaceFocus) { _, focused in
                if focused { onFocused() }
            }
            // Mounted is not the same as on screen, and only this view knows the
            // difference. The representable's NSView is not in the hierarchy yet on
            // the first pass, so the mount-time answer is repeated a runloop turn
            // later — the same shape, and the same reason, as the focus probe above.
            .onChange(of: isVisible, initial: true) { _, visible in
                applySurfaceVisibility(visible, for: context)
                DispatchQueue.main.async { applySurfaceVisibility(visible, for: context) }
                onVisibility(visible)
            }
            // A relaunched session gets a fresh TerminalViewState (see
            // `relaunchSession`); keying the mounted view on the state's identity
            // remounts the NSView for the new surface. Without this the
            // representable would only *update* — and its update path deliberately
            // keeps the first-mounted delegate, which is the old, dead state.
            .id(ObjectIdentifier(context))
    }
}

/// Tells ghostty whether a mounted surface is actually on screen.
///
/// A pane that is not showing stays mounted on purpose — that is this file's whole
/// premise — so it keeps its frame and is drawn at zero opacity. AppKit is happy to
/// lay that out, and ghostty, told nothing, is happy to keep rendering it: every
/// byte a background agent writes costs a frame nobody sees, on a renderer thread
/// nobody is watching.
///
/// The switch for that lives on the *view*, not the surface. `setSurfaceVisible`
/// composes with the app-active state the surface coordinator already tracks, stops
/// the display link, gates the *render* half of a PTY-output wakeup, and asks for an
/// immediate frame on the way back in. The wakeup's `ghostty_app_tick` is never
/// gated: it drains the app mailbox that ghostty's stream handler blocks on when
/// full, and withholding it froze every hidden pane's byte stream — viewport, status
/// tap and daemon events with it — seconds into a turn (issues #545/#546). Setting
/// ghostty's occlusion flag directly does none of those, and is overwritten the next
/// time the coordinator re-asserts its own answer.
@MainActor
private func applySurfaceVisibility(_ visible: Bool, for state: TerminalViewState) {
    guard let root = AppDelegate.mainWindow?.contentView,
          let view = terminalView(matching: state, under: root)
    else { return }
    view.setSurfaceVisible(visible)
}

/// The AppKit terminal view a `TerminalViewState` is mounted in. SwiftUI hands the
/// representable's NSView to nobody, so both callers that need it — focus, which
/// must reach the first responder, and visibility, which must reach the surface
/// coordinator — find it by matching the delegate the state installed.
@MainActor
private func terminalView(
    matching state: TerminalViewState,
    under root: NSView
) -> TerminalView? {
    if let terminal = root as? TerminalView,
       let delegate = terminal.delegate as AnyObject?,
       delegate === state {
        return terminal
    }
    for child in root.subviews {
        if let match = terminalView(matching: state, under: child) {
            return match
        }
    }
    return nil
}

private struct TerminalFocusRepairProbe: NSViewRepresentable {
    let repair: () -> Void

    func makeNSView(context _: Context) -> TerminalFocusProbeView {
        let view = TerminalFocusProbeView(frame: .zero)
        DispatchQueue.main.async { repair() }
        return view
    }

    func updateNSView(_: TerminalFocusProbeView, context _: Context) {
        DispatchQueue.main.async { repair() }
    }
}

private final class TerminalFocusProbeView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// App-side equivalent of Ghostty's `moveFocus`. It addresses both wrapper gaps:
/// a focus request is retried until the selected TerminalView is in a window, and
/// the previous terminal is explicitly resigned before the new one is focused.
@MainActor
private final class TerminalFocusDriver {
    private enum Strength {
        case replaceResponder
        case repairOrphan
    }

    private weak var lastFocusedSurface: TerminalView?
    private var replaceGeneration = 0
    private var repairGeneration = 0
    private var injectionGeneration = 0

    func moveFocus(
        to state: TerminalViewState,
        sessionID: Session.ID,
        reason: TerminalFocusReason,
        canFocus: @escaping () -> Bool
    ) {
        let strength: Strength = reason.replacesCurrentResponder
            ? .replaceResponder
            : .repairOrphan
        let generation: Int
        switch strength {
        case .replaceResponder:
            replaceGeneration += 1
            generation = replaceGeneration
        case .repairOrphan:
            repairGeneration += 1
            generation = repairGeneration
        }
        scheduleMove(
            to: state,
            sessionID: sessionID,
            reason: reason,
            strength: strength,
            generation: generation,
            delay: 0,
            canFocus: canFocus
        )
    }

    private func scheduleMove(
        to state: TerminalViewState,
        sessionID: Session.ID,
        reason: TerminalFocusReason,
        strength: Strength,
        generation: Int,
        delay: TimeInterval,
        canFocus: @escaping () -> Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak state] in
            guard let self, let state,
                  isCurrent(strength, generation: generation),
                  canFocus() else { return }

            guard let window = mainWindow() else {
                retryMove(to: state, sessionID: sessionID, reason: reason,
                          strength: strength, generation: generation,
                          after: delay, canFocus: canFocus)
                return
            }
            // Key-window status is deliberately not focus state. Do not move focus
            // in the background; didBecomeKey will issue a fresh repair request.
            guard window.isKeyWindow else { return }
            guard let root = window.contentView,
                  let target = terminalView(matching: state, under: root),
                  target.window === window else {
                retryMove(to: state, sessionID: sessionID, reason: reason,
                          strength: strength, generation: generation,
                          after: delay, canFocus: canFocus)
                return
            }

            let current = window.firstResponder
            if current === target {
                lastFocusedSurface = target
                return
            }
            if strength == .repairOrphan,
               current != nil, current !== window {
                // A field, browser, overlay, or newly-clicked sibling owns focus.
                // A render-driven repair must never steal from a real responder.
                return
            }

            resignPreviousSurface(current: current, target: target)
            if window.makeFirstResponder(target), window.firstResponder === target {
                lastFocusedSurface = target
                if AppChannel.isDev {
                    if current == nil || current === window {
                        Log.focus.info("recovered terminal focus [\(reason.label, privacy: .public)] → \(sessionID.uuidString.prefix(8), privacy: .public)")
                    } else {
                        Log.focus.info("moved terminal focus [\(reason.label, privacy: .public)] → \(sessionID.uuidString.prefix(8), privacy: .public)")
                    }
                }
            } else {
                retryMove(to: state, sessionID: sessionID, reason: reason,
                          strength: strength, generation: generation,
                          after: delay, canFocus: canFocus)
            }
        }
    }

    private func retryMove(
        to state: TerminalViewState,
        sessionID: Session.ID,
        reason: TerminalFocusReason,
        strength: Strength,
        generation: Int,
        after delay: TimeInterval,
        canFocus: @escaping () -> Bool
    ) {
        let nextDelay = delay == 0 ? 0.05 : min(delay * 2, 0.5)
        scheduleMove(to: state, sessionID: sessionID, reason: reason,
                     strength: strength, generation: generation,
                     delay: nextDelay, canFocus: canFocus)
    }

    /// Deterministically reproduce the production failure against the real terminal
    /// responder. This intentionally does not mutate SwiftUI focus state directly.
    func injectOrphan(
        in state: TerminalViewState,
        sessionID: Session.ID,
        canFocus: @escaping () -> Bool,
        repair: @escaping () -> Void
    ) {
        injectionGeneration += 1
        scheduleInjection(in: state, sessionID: sessionID,
                          generation: injectionGeneration, delay: 0,
                          canFocus: canFocus, repair: repair)
    }

    private func scheduleInjection(
        in state: TerminalViewState,
        sessionID: Session.ID,
        generation: Int,
        delay: TimeInterval,
        canFocus: @escaping () -> Bool,
        repair: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak state] in
            guard let self, let state,
                  generation == injectionGeneration, canFocus() else { return }
            guard let window = mainWindow(), window.isKeyWindow,
                  let root = window.contentView,
                  let target = terminalView(matching: state, under: root),
                  target.window === window else {
                let nextDelay = delay == 0 ? 0.05 : min(delay * 2, 0.5)
                scheduleInjection(in: state, sessionID: sessionID,
                                  generation: generation, delay: nextDelay,
                                  canFocus: canFocus, repair: repair)
                return
            }

            if window.firstResponder !== target {
                resignPreviousSurface(current: window.firstResponder, target: target)
                guard window.makeFirstResponder(target),
                      window.firstResponder === target else {
                    let nextDelay = delay == 0 ? 0.05 : min(delay * 2, 0.5)
                    scheduleInjection(in: state, sessionID: sessionID,
                                      generation: generation, delay: nextDelay,
                                      canFocus: canFocus, repair: repair)
                    return
                }
            }
            lastFocusedSurface = target

            DispatchQueue.main.async { [weak self, weak window, weak target] in
                guard let self, let window, let target,
                      generation == injectionGeneration,
                      canFocus(), window.isKeyWindow,
                      window.firstResponder === target else { return }
                _ = window.makeFirstResponder(nil)
                guard window.firstResponder !== target else { return }
                Log.focus.info("fault injector: dropped terminal first responder while key=true session=\(sessionID.uuidString.prefix(8), privacy: .public)")
                repair()
            }
        }
    }

    /// Dev-only: log the resolved terminal view's layer tree. Emitted through
    /// `print` as well as os_log so a dev app launched with `open --stdout`
    /// lands the dump in the same file as the wrapper's own diagnostics.
    func dumpLayers(of state: TerminalViewState, sessionID: Session.ID) {
        func emit(_ message: String) {
            print("[termio][layer dump] \(message)")
            Log.app.notice("layer dump: \(message, privacy: .public)")
        }
        guard let window = mainWindow(), let root = window.contentView,
              let target = terminalView(matching: state, under: root) else {
            emit("no terminal view resolved for \(sessionID.uuidString.prefix(8))")
            return
        }
        emit("session=\(sessionID.uuidString.prefix(8)) viewFrame=\(NSStringFromRect(target.frame)) bounds=\(NSStringFromRect(target.bounds))")
        guard let rootLayer = target.layer else {
            emit("view has no backing layer")
            return
        }
        func describe(_ layer: CALayer, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let cls = String(describing: type(of: layer))
            emit("\(indent)\(cls) frame=\(NSStringFromRect(layer.frame)) scale=\(layer.contentsScale) hidden=\(layer.isHidden) opacity=\(layer.opacity) hasContents=\(layer.contents != nil)")
            layer.sublayers?.forEach { describe($0, depth: depth + 1) }
        }
        describe(rootLayer, depth: 0)
    }

    private func isCurrent(_ strength: Strength, generation: Int) -> Bool {
        switch strength {
        case .replaceResponder: generation == replaceGeneration
        case .repairOrphan: generation == repairGeneration
        }
    }

    private func mainWindow() -> NSWindow? {
        AppDelegate.mainWindow
    }

    private func resignPreviousSurface(current: NSResponder?, target: TerminalView) {
        let previous = (current as? TerminalView) ?? lastFocusedSurface
        if let previous, previous !== target {
            // Ghostty does this explicitly too: in practice the normal focus callback
            // is occasionally skipped during SwiftUI/AppKit reconciliation.
            _ = previous.resignFirstResponder()
        }
    }
}

/// The pane's drag affordance: ghostty's ellipsis strip on the top edge, drawn
/// while the pointer is on it. Drawing only — the press that starts the drag is
/// hit-tested in `PaneDragRearrange`, so this never stands between the pointer
/// and the terminal.
private struct PaneGrabHandle: View {
    let paneFrame: CGRect
    /// True once the pointer is on the handle itself rather than in the band
    /// that reveals it: ghostty's two strengths, present then ready.
    let isOverHandle: Bool

    var body: some View {
        let rect = PaneDragRearrange.handleRect(in: paneFrame.size)
        Image(systemName: "ellipsis")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary.opacity(isOverHandle ? 0.8 : 0.3))
            .frame(width: rect.width, height: rect.height)
            .position(x: paneFrame.minX + rect.midX, y: paneFrame.minY + rect.midY)
            .transition(.opacity)
    }
}

/// The visual half of the pane drag (issue #183): a wash over the lifted source
/// pane, a highlight over the region the release would commit — the half of the
/// target the pane would occupy, or the whole target for a swap — and a scaled
/// still of the pane riding under the pointer. Geometry comes straight from the
/// tree's `layout`, so the preview and the drop can never disagree. The tint
/// family is the file-drop wash's desaturated blue-grey, not accent blue.
/// Where a release would land: a fill in the split tint over one pane (or one half of
/// it), no border — the rect's own edge already draws the boundary, a stroke would say
/// it twice. Shared by the pane-rearrange drag and by dragging a file or an issue in,
/// so both drags speak with the same highlight.
///
/// Always mounted and hidden by opacity, because a view that survives every target
/// change is what lets SwiftUI interpolate the rect — the wash then slides from pane to
/// pane instead of blinking out and back in somewhere else. Leaving every target keeps
/// the last rect and only fades it; animating the frame to nothing reads as the wash
/// shrinking away rather than releasing.
private struct PaneDropWash: View {
    /// `.zero` when the pointer is over nothing droppable.
    let rect: CGRect
    @Environment(\.colorScheme) private var colorScheme
    @State private var lastRect: CGRect = .zero

    static func tint(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 0.62, green: 0.70, blue: 0.82, opacity: 1)
            : Color(.sRGB, red: 0.40, green: 0.52, blue: 0.68, opacity: 1)
    }

    var body: some View {
        let drawn = rect == .zero ? lastRect : rect
        return Rectangle()
            .fill(Self.tint(for: colorScheme).opacity(colorScheme == .dark ? 0.20 : 0.17))
            .frame(width: drawn.width, height: drawn.height)
            .position(x: drawn.midX, y: drawn.midY)
            .opacity(rect == .zero ? 0 : 1)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.15), value: drawn)
            .animation(.easeInOut(duration: 0.15), value: rect == .zero)
            .onChange(of: rect) { _, new in
                if new != .zero { lastRect = new }
            }
    }
}

/// Where a session dragged out of the sidebar would land: the pane under the
/// pointer and the half it would take. The sidebar-drag twin of `PaneDragState`.
struct SessionDropTarget: Equatable {
    var pane: Session.ID
    var zone: PaneDropZone
}

/// One drop destination per pane, for every kind of drop.
///
/// A file, a folder or an issue link is inserted at that pane's prompt. A session
/// dragged out of the sidebar means one thing only — group it in beside this pane,
/// on the side you released over — so every part of the pane is a live edge, and a
/// pane it cannot join declines the drag instead of doing something else with it.
///
/// One destination covering every type, never a second layered over the first:
/// SwiftUI's `URL` transferable imports from plain text, so both would see a
/// session drag, only one would perform the drop, and the loser is never told the
/// drag left — its highlight then stays on screen for good.
///
/// A `DropDelegate` rather than a `dropDestination` because only `dropUpdated`
/// carries the pointer; `isTargeted:` is a Bool, which is all a whole-pane wash
/// ever needed.
private struct PaneDropDelegate: DropDelegate {
    let pane: Session.ID
    /// The pane's own size — the space `PaneDropZone` reads `info.location` in.
    let size: CGSize
    let isVisible: Bool
    let store: TermioStore
    let send: ([URL]) -> Bool

    /// A session drag is refused by every pane it cannot join — its own pane,
    /// another project, another worktree — so the pointer shows the no-drop cursor
    /// rather than accepting a release that would do nothing. Anything that is not
    /// one of our rows is a payload for the prompt, and always lands.
    func validateDrop(info: DropInfo) -> Bool {
        guard isVisible else { return false }
        guard let moved = store.resolveDraggedSession() else { return true }
        return store.canGroup(moved, with: pane)
    }

    func dropEntered(info: DropInfo) {
        store.resolveDraggedSession()
        track(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        return DropProposal(operation: .copy)
    }

    /// Cleared unconditionally rather than only when the cue is this pane's.
    /// Moving between panes can report the new pane's entry before the old pane's
    /// exit, so this can wipe a cue that was just set — but the new pane's next
    /// `dropUpdated` puts it straight back, a frame later at worst. A cue that
    /// heals itself while the pointer moves beats one that can be left behind.
    func dropExited(info: DropInfo) {
        guard store.sessionDropTarget != nil else { return }
        store.sessionDropTarget = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let moved = store.resolveDraggedSession()
        store.sessionDropTarget = nil
        store.draggingSessionID = nil
        guard let moved else { return insert(info) }
        guard store.canGroup(moved, with: pane) else { return false }
        store.dropSession(moved, onto: pane, zone: PaneDropZone.edge(at: info.location, in: size))
        return true
    }

    /// Lights what the release would commit: the half this pane would give up to a
    /// session being grouped in, or the whole pane for a payload being typed.
    ///
    /// Published only when it changes. `dropUpdated` fires at pointer rate, and a
    /// write to any `@Published` on the store invalidates every view observing it —
    /// the whole sidebar list and the pane tree — so republishing the zone the cue
    /// is already showing redraws the app for nothing. Same rule, and the same
    /// reason, as `PaneDragRearrange.setHover`.
    private func track(_ info: DropInfo) {
        guard isVisible else { return }
        let zone = store.draggingSessionID == nil
            ? .center : PaneDropZone.edge(at: info.location, in: size)
        let target = SessionDropTarget(pane: pane, zone: zone)
        guard store.sessionDropTarget != target else { return }
        store.sessionDropTarget = target
    }

    /// Everything that ends up at the prompt: files and folders from the Finder or
    /// the file tree, an issue's link from the Issues list.
    private func insert(_ info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.url])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var dropped: [URL] = []
            for provider in providers {
                if let url = await provider.droppedURL() { dropped.append(url) }
            }
            _ = send(dropped)
        }
        return true
    }
}

/// Main-actor bound because the providers come off a `DropInfo` and never leave
/// the drop: only the continuation crosses to whichever queue the load answers on.
@MainActor
private extension NSItemProvider {
    /// The item as a URL, or nil when it carries none.
    func droppedURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

/// The pane whose session is being dragged out of the sidebar, dimmed to say it is
/// out of play: a session cannot be grouped with itself, so this is the one pane
/// the release cannot land on. Without it, that refusal is indistinguishable from
/// the drag being broken.
///
/// A neutral scrim rather than `PaneDropWash`'s blue-grey. The tint is what carries
/// "a drop lands here", so spending it on the one pane that refuses the drop reads
/// as the opposite of the truth — the pane lights up and the drag looks like it is
/// offering a single, wrong option. Dimming says "not this one" in the vocabulary
/// disabled controls already use.
private struct SessionDragLift: View {
    /// `.zero` when the dragged session has no pane on screen.
    let rect: CGRect
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .opacity(rect == .zero ? 0 : 1)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.15), value: rect == .zero)
    }
}

private struct PaneDragOverlay: View {
    /// Ghostty's own drag-image scale (`SurfaceDragSource.previewScale`).
    private static let previewScale: CGFloat = 0.2

    let drag: PaneDragState
    let layout: SplitNode.PaneLayout
    /// The pane as it looked when picked up, or nil when the surface could not
    /// be captured — the drag then runs without a preview rather than showing an
    /// empty card.
    let preview: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    /// The pointer in the pane area's coordinate space, rebuilt from the pane it
    /// is over plus the local point the hit test already resolved.
    private var pointerCenter: CGPoint? {
        guard let pointer = drag.pointer, let frame = layout.frames[pointer.pane] else { return nil }
        return CGPoint(x: frame.minX + pointer.local.x, y: frame.minY + pointer.local.y)
    }

    private var tint: Color { PaneDropWash.tint(for: colorScheme) }

    /// The half (or whole pane) the release would fill, or `.zero` when the
    /// pointer is over nothing droppable.
    private var highlightRect: CGRect {
        guard let target = drag.target, target != drag.source,
              let zone = drag.zone, let frame = layout.frames[target]
        else { return .zero }
        return zone.highlightRect(in: frame)
    }

    var body: some View {
        ZStack {
            liftedSource
            PaneDropWash(rect: highlightRect)
            draggedPreview
        }
        .allowsHitTesting(false)
    }

    /// The pane you picked up, faintly washed so it reads as lifted.
    @ViewBuilder private var liftedSource: some View {
        if let source = layout.frames[drag.source] {
            Rectangle()
                .fill(tint.opacity(colorScheme == .dark ? 0.08 : 0.07))
                .frame(width: source.width, height: source.height)
                .position(x: source.midX, y: source.midY)
        }
    }

    /// A still of the dragged pane under the pointer, at ghostty's drag-image
    /// scale and translucent like the image a real dragging session carries — an
    /// opaque card reads as a second window dropped on the layout. Never
    /// animated: an interpolated position is a preview that lags the mouse.
    @ViewBuilder private var draggedPreview: some View {
        if let preview, let center = pointerCenter {
            Image(nsImage: preview)
                .resizable()
                .interpolation(.medium)
                .frame(width: preview.size.width * Self.previewScale,
                       height: preview.size.height * Self.previewScale)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .opacity(0.8)
                .position(center)
                .animation(nil, value: drag)
        }
    }
}

/// The draggable divider between two split panes: a hairline with a wider
/// invisible hit area (muxy's 1pt-line / ~10pt-grab pattern). Dragging writes
/// the branch ratio through `onRatioChange`; the anchor is captured on the
/// first tick so the delta is always relative to where the drag began, not to
/// the live (already-moved) ratio.
private struct SplitDividerHandle: View {
    let spec: SplitNode.DividerSpec
    let onRatioChange: (Double) -> Void
    @State private var anchorRatio: Double?

    /// Whether the divider line runs vertically (panes side by side).
    private var verticalLine: Bool { spec.direction == .horizontal }
    private static let hitThickness: CGFloat = 9

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: verticalLine ? spec.frame.width : nil,
                   height: verticalLine ? nil : spec.frame.height)
            .frame(width: verticalLine ? Self.hitThickness : spec.frame.width,
                   height: verticalLine ? spec.frame.height : Self.hitThickness)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (verticalLine ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0,
                            coordinateSpace: .named(TerminalPane.splitCoordinateSpace))
                    .onChanged { value in
                        let start = anchorRatio ?? spec.ratio
                        if anchorRatio == nil { anchorRatio = start }
                        guard spec.span > 0 else { return }
                        let delta = verticalLine ? value.translation.width : value.translation.height
                        onRatioChange(start + Double(delta / spec.span))
                    }
                    .onEnded { _ in anchorRatio = nil }
            )
            .position(x: spec.frame.midX, y: spec.frame.midY)
    }
}

