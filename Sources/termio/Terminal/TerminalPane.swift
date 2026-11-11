import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GhosttyTerminal
import TermioShared
import TermioStream

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
    @EnvironmentObject var geometry: NavigatorGeometry
    @EnvironmentObject var window: WindowContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var focusDriver = TerminalFocusDriver()
    @State private var activated: [Session.ID] = []
    @State private var lastLivePanelFrame: CGRect = .zero

    /// The active window draws the store's selection with everything live; any other
    /// window draws its own selection read-only until a click makes it active.
    var body: some View {
        if window.isActive {
            activeBody
        } else {
            InactiveWindowPane()
        }
    }

    private var activeBody: some View {
        GeometryReader { geo in
            // The terminal group fills the whole pane. File editors, diffs and PR/issue details
            // now open in the right inspector (see `InspectorDetailHost`) rather than covering
            // the terminal, so this pane is only ever terminal surfaces + split dividers.
            // No leading margin while the sidebar is open: the window's split divider is the gap
            // on that side, as wide as every other (`SeamlessSplitView`). Collapsed, the divider
            // goes with it and the cards keep their own margin. Read from where the pane is, so
            // the margin grows exactly as the divider leaves and the cards never step.
            let leading = max(0, PaneCard.spacing - geometry.paneMinX)
            // The horizontal layout's tab strip takes the top row; the cards start under it.
            let top = PaneCard.spacing + (showsTabStrip ? WindowChrome.rowHeight + PaneCard.spacing : 0)
            let bounds = CGRect(x: leading, y: top,
                                width: max(0, geo.size.width - leading - PaneCard.spacing),
                                height: max(0, geo.size.height - top - PaneCard.spacing))
            let layout = store.splitRoot?.layout(in: bounds, dividerThickness: PaneCard.spacing)
            let zoomed = store.isPaneZoomed && layout != nil
            ZStack(alignment: .topLeading) {
                terminalGroup(bounds: bounds, layout: layout, zoomed: zoomed)
                    .frame(width: geo.size.width, height: geo.size.height)
                if showsTabStrip {
                    SessionTabStrip()
                        .padding(.leading, leading + stripClearance(leading: leading))
                        .padding(.trailing, PaneCard.spacing)
                        .padding(.top, PaneCard.spacing)
                }
            }
                .coordinateSpace(name: Self.splitCoordinateSpace)
        }
        // Up into the titlebar strip: the window has no toolbar, so the top row of cards puts
        // its headers on the traffic lights' line (see `WindowChrome`).
        .ignoresSafeArea(.container, edges: .top)
        // The ⌘⇧O/⌘⇧P palette lives in its own floating NSPanel (owned by
        // the app delegate — a SwiftUI overlay would render *under* the NSView
        // terminal surfaces); this only hands focus back to the terminal when
        // it closes.
        .onChange(of: store.paletteMode) { _, mode in
            if mode == nil { requestSelectedTerminalFocus(reason: .paletteClosed) }
        }
        // Closing the panel takes its editor off screen, so the typing goes back to the terminal.
        // A maximized detail stays on screen with its panel closed, so it keeps the keyboard.
        .onChange(of: store.inspectorVisible) { _, visible in
            guard !visible, !(store.inspectorMaximized && store.isDetailPresented) else { return }
            requestSelectedTerminalFocus(reason: .overlayClosed)
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
                  MainWindowController.isMain(window)
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
        let paneFrames = SplitNode.paneFrames(of: store.splitGroups, in: bounds,
                                              dividerThickness: PaneCard.spacing)
        let slidePanels = panelsThroughSlide(bounds: bounds, zoomed: zoomed)
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
                let card = zoomed && isSelected ? bounds : (paneFrames[id] ?? bounds)
                let panel = PaneCard.panelLayout(in: card, isOpen: store.openPanels.contains(id),
                                                 width: panelWidth(for: id),
                                                 covers: slidePanels.covering.contains(id),
                                                 heldWidth: slidePanels.widths[id])
                let rect = panel.terminal
                let context = store.surface(for: item.session)
                let notch = cardNotch(card, in: bounds)
                PaneCardChrome(session: item.session, isSelected: isSelected,
                               background: paneBackground, notch: notch,
                               panelEdgeX: panel.frame.flatMap { panel.covers ? nil : $0.minX - card.minX })
                    .frame(width: card.width, height: card.height)
                    // Before `position`, so the probe is the card's size rather than the pane's.
                    .background(PaneCardProbeView(sessionID: id,
                                                  panelCovers: panel.frame != nil && panel.covers,
                                                  notchWidth: notch?.width ?? 0))
                    .position(x: card.midX, y: card.midY)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                if let link = store.runtime(for: id).streamLink {
                    // Stays mounted while the view comes and goes, so the link
                    // hears a hidden pane stop counting toward the session's size.
                    StreamLinkReport(isVisible: isVisible, colors: store.streamTheme(dark: colorScheme == .dark),
                                     scrollbackBytes: store.streamScrollbackBytes,
                                     link: link) { store.reportRendering($0, for: id, viewer: ObjectIdentifier(window)) }
                        .id(ObjectIdentifier(link))
                    // Unlike the embedded surface, which owns its terminal and so
                    // stays mounted at zero opacity, the stream view is mounted
                    // only on screen: the terminal lives in the link, and a new
                    // view at the same size declares a grid the link already holds.
                    if isVisible {
                        // The stream view never letterboxes: it draws the session's
                        // grid anchored top-left and declares what the pane holds.
                        TermiodStreamPane(
                            link: link,
                            sessionID: id,
                            appearance: store.streamAppearance(),
                            takesKeyboard: Self.terminalMayTakeKeyboard(id, store: store),
                            copyOnSelect: settings.copyOnSelect,
                            onViewport: { grid in store.reportViewport(grid, for: id) },
                            onFocused: { selectFocusedSurface(id) },
                            onBackgroundColor: { color in store.runtime(for: id).streamBackgroundColor = color }
                        )
                        // One view per link: a relaunch attaches a new one.
                        .id(ObjectIdentifier(link))
                        .frame(width: rect.width, height: rect.height)
                        .background(paneBackground)
                        .clipShape(PaneCard.bodyClip(leading: true, trailing: panel.frame == nil,
                                                     topLeading: notch != nil))
                        .position(x: rect.midX, y: rect.midY)
                    }
                } else {
                SharedGridLetterbox(
                    runtime: store.runtime(for: id),
                    sessionName: id.uuidString,
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
                        onVisibility: { store.reportRendering($0, for: id, viewer: ObjectIdentifier(window)) },
                        requestFocus: { reason in
                            requestTerminalFocus(for: id, reason: reason)
                        }
                    )
                }
                .frame(width: rect.width, height: rect.height)
                // The card's corners are round and the surface is not: clip the corners it
                // reaches, or its background shows past the card's border onto the window's.
                .clipShape(PaneCard.bodyClip(leading: true, trailing: panel.frame == nil,
                                             topLeading: notch != nil))
                .position(x: rect.midX, y: rect.midY)
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                }
                // An open panel on a card without focus: the picture it left, which a
                // click turns back into the live panel by focusing the card.
                if let frame = panel.frame, !isSelected, isVisible {
                    PanelSnapshot(image: store.panelSnapshots[id], background: paneBackground)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(PaneCard.panelClip(covers: panel.covers, notched: notch != nil))
                        .position(x: frame.midX, y: frame.midY)
                        .onTapGesture { store.selectedSessionID = id }
                    let edge = PaneCard.panelEdgeFrame(frame, covers: panel.covers)
                    PanelEdge(covers: panel.covers, notched: notch != nil)
                        .frame(width: edge.width, height: edge.height)
                        .position(x: edge.midX, y: edge.midY)
                }
                if let frame = panel.frame, isVisible, !panel.covers {
                    // Above the live panel, which comes later in this stack: the grip lights
                    // over the panel's own edge, and under the panel only its header run showed.
                    PanelDividerHandle(panelFrame: frame, card: card)
                        .zIndex(1)
                }
                // Over the surface, not behind it: the surface is square-cornered, so
                // a border drawn underneath would lose its rounded bottom corners.
                PaneCardBorder(isFocused: isSelected && store.splitRoot != nil,
                               notch: notch)
                    .frame(width: card.width, height: card.height)
                    .position(x: card.midX, y: card.midY)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // The live inspector, in the focused card's panel. One view, moved to whichever
            // card has focus; kept mounted (at its last frame) while no panel shows it, so the
            // file tree keeps its expanded folders and scroll.
            let livePanel = livePanelLayout(bounds: bounds, paneFrames: paneFrames, zoomed: zoomed)
            let live = livePanel?.frame
            let liveFrame = live ?? lastLivePanelFrame
            InspectorPanelView(isShown: live != nil)
                .frame(width: max(1, liveFrame.width), height: max(1, liveFrame.height))
                .clipShape(PaneCard.panelClip(covers: livePanel?.covers ?? false,
                                              notched: livePanel?.notched ?? false))
                .position(x: liveFrame.midX, y: liveFrame.midY)
                .opacity(live == nil ? 0 : 1)
                .allowsHitTesting(live != nil)
                .onChange(of: live) { _, frame in
                    if let frame { lastLivePanelFrame = frame }
                }
            if let livePanel {
                let edge = PaneCard.panelEdgeFrame(livePanel.frame, covers: livePanel.covers)
                PanelEdge(covers: livePanel.covers, notched: livePanel.notched)
                    .frame(width: edge.width, height: edge.height)
                    .position(x: edge.midX, y: edge.midY)
            }
            if let layout, !zoomed {
                ForEach(layout.dividers) { divider in
                    SplitDividerHandle(
                        spec: divider,
                        onRatioChange: { ratio in
                            store.updateSplitRatio(branchID: divider.id, ratio: ratio)
                        },
                        onDragEnded: { store.flushViewports() })
                }
            }
            // The open hand over each visible card's handle, as a cursor rect on a real view.
            // A cursor pushed from the event monitor lost to the header's own views, which set
            // theirs on the next pointer move, so the hand came and went. The press itself is
            // still taken by the monitor.
            if let layout, !zoomed, store.paneDrag == nil {
                ForEach(Array(layout.frames.keys).filter { store.visiblePaneIDs.contains($0) }, id: \.self) { id in
                    if let frame = layout.frames[id],
                       let handle = PaneDragRearrange.handleRect(in: frame.size,
                                                                 notchWidth: cardNotch(frame, in: bounds)?.width ?? 0,
                                                                 controlsMinX: PaneCardGeometry.shared.controlsMinX(id)) {
                        CursorArea(cursor: .openHand)
                            .frame(width: handle.width, height: handle.height)
                            .position(x: frame.minX + handle.midX, y: frame.minY + handle.midY)
                    }
                }
            }
            // The handle that starts a rearrange, on the pane the pointer is
            // near (see `PaneDragRearrange`). Never hit-testable: the press is
            // taken by the event monitor, so this is purely the affordance.
            if let layout, !zoomed, store.paneDrag == nil,
               let hovered = store.paneHandleHover, let frame = layout.frames[hovered.pane] {
                PaneGrabHandle(paneFrame: frame, isOverHandle: hovered.overHandle,
                               notchWidth: cardNotch(frame, in: bounds)?.width ?? 0,
                               controlsMinX: PaneCardGeometry.shared.controlsMinX(hovered.pane))
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
        // One destination for the whole group, never one per pane. A pane's own
        // destination cannot be taken out of the running when the pane is hidden:
        // `.allowsHitTesting(false)` does not suppress a drop destination, an empty
        // type list still claims the region, and a destination that refuses does not
        // hand the drag to the pane beneath it — so whichever pane was mounted last,
        // visible or not, swallowed every drop (issue #610). The pointer resolves the
        // pane here instead, against the same frames the layout already computed.
        .onDrop(of: [.url, .fileURL, .text], delegate: GroupDropDelegate(
            bounds: bounds,
            frames: paneFrames,
            visible: store.visiblePaneIDs,
            zoomed: zoomed,
            selected: store.selectedSessionID,
            store: store,
            send: { urls, id in sendPaths(urls, to: id) }
        ))
        // Ghostty's own timing (`SurfaceDragSource`): the handle fades in and
        // brightens rather than blinking. The drag overlay animates its own
        // pieces — the highlight slides, the preview must not.
        .animation(.easeInOut(duration: 0.15), value: store.paneHandleHover)
        // At the slide's first frame, while the bounds are still the ones it starts from.
        .onChange(of: geometry.slide.map { [$0.from, $0.to] }) { previous, _ in
            capPanelWidthsWhenHiding(bounds: bounds, paneFrames: paneFrames, zoomed: zoomed)
            // An expand that has landed: every card is back at the width its caps were taken at.
            if let previous, previous[1] > previous[0], geometry.slide == nil { store.panelWidthCaps = [:] }
        }
        // The sidebar back by any other path (a divider dragged open, a maximized detail put back).
        .onChange(of: store.sidebarVisible) { _, visible in
            if visible, geometry.slide == nil, !store.panelWidthCaps.isEmpty { store.panelWidthCaps = [:] }
        }
    }

    /// The focused card's panel, when its panel is open and the card is on screen.
    private func livePanelLayout(bounds: CGRect, paneFrames: [Session.ID: CGRect],
                                 zoomed: Bool) -> (frame: CGRect, covers: Bool, notched: Bool)? {
        guard let id = store.selectedSessionID, store.openPanels.contains(id),
              store.visiblePaneIDs.contains(id) || zoomed else { return nil }
        let card = zoomed ? bounds : (paneFrames[id] ?? bounds)
        let slidePanels = panelsThroughSlide(bounds: bounds, zoomed: zoomed)
        let layout = PaneCard.panelLayout(in: card, isOpen: true, width: panelWidth(for: id),
                                          covers: slidePanels.covering.contains(id),
                                          heldWidth: slidePanels.widths[id])
        let notched = cardNotch(card, in: bounds) != nil
        return layout.frame.map { ($0, layout.covers, notched) }
    }

    /// How the open panels hold still while the sidebar slides: the slide moves boxes, and what is
    /// in them is laid out again once, when it lands. The terminal waits for its new size until
    /// then; the panel waits with it.
    ///
    /// `covering`: the panels that lay over their terminal at either end of the slide. Those cover
    /// it for the whole slide, so a panel changes between beside and over only when the slide
    /// starts or lands, never mid-flight as the card's width crosses `panelFits`.
    /// `widths`: every other panel keeps its width, and the terminal beside it takes the travel.
    /// Hiding the sidebar never widens a panel (see `capPanelWidthsWhenHiding`), so the room goes
    /// to the terminal. Showing it moves each panel, in step with the slide, to the width it will
    /// rest at — narrower where the card can no longer hold it — so landing changes nothing.
    ///
    /// Both empty at rest.
    private func panelsThroughSlide(bounds: CGRect, zoomed: Bool)
        -> (covering: Set<Session.ID>, widths: [Session.ID: CGFloat]) {
        guard let slide = geometry.slide, !store.openPanels.isEmpty else { return ([], [:]) }
        // The pane runs to the window's trailing edge, so its width at any leading edge follows
        // from this one.
        let windowWidth = geometry.paneMinX + bounds.maxX + PaneCard.spacing
        var covering = Set<Session.ID>()
        var room: [CGFloat: [Session.ID: CGFloat]] = [:]
        for paneMinX in [slide.from, slide.to] {
            let leading = max(0, PaneCard.spacing - paneMinX)
            let end = CGRect(x: leading, y: bounds.minY,
                             width: max(0, windowWidth - paneMinX - leading - PaneCard.spacing),
                             height: bounds.height)
            let frames = SplitNode.paneFrames(of: store.splitGroups, in: end, dividerThickness: PaneCard.spacing)
            for id in store.openPanels {
                let card = zoomed && id == store.selectedSessionID ? end : (frames[id] ?? end)
                if PaneCard.panelFits(in: card) {
                    room[paneMinX, default: [:]][id] = PaneCard.widestPanel(in: card)
                } else {
                    covering.insert(id)
                }
            }
        }
        let travel = slide.to - slide.from
        let progress = travel == 0 ? 1 : min(1, max(0, (geometry.paneMinX - slide.from) / travel))
        var widths: [Session.ID: CGFloat] = [:]
        for (id, startRoom) in room[slide.from] ?? [:] where !covering.contains(id) {
            let start = min(panelWidth(for: id), startRoom)
            // Hiding holds the width it starts at; showing heads for the width the panel rests at
            // once its cap is cleared on landing, which a window resized while the sidebar was
            // hidden can put above the cap.
            let end = slide.to > slide.from
                ? min(store.panelWidth, room[slide.to]?[id] ?? startRoom)
                : start
            widths[id] = start + (end - start) * progress
        }
        return (covering, widths)
    }

    /// The width `id`'s panel asks for: the shared one, under its cap while the sidebar is hidden.
    private func panelWidth(for id: Session.ID) -> CGFloat {
        min(store.panelWidth, store.panelWidthCaps[id] ?? .infinity)
    }

    /// Hiding the sidebar hands its room to the terminals, never to the panels: each open panel
    /// is capped at the width it shows now (`TermioStore.panelWidthCaps`). Fitted to the wider card
    /// instead, a panel narrowed by the sidebar grew back as the slide landed and narrowed again on
    /// the next show — the toggle resizing a column it does not own, every time.
    private func capPanelWidthsWhenHiding(bounds: CGRect, paneFrames: [Session.ID: CGRect], zoomed: Bool) {
        guard let slide = geometry.slide, slide.to < slide.from else { return }
        var caps = store.panelWidthCaps
        for id in store.openPanels {
            let card = zoomed && id == store.selectedSessionID ? bounds : (paneFrames[id] ?? bounds)
            let layout = PaneCard.panelLayout(in: card, isOpen: true, width: panelWidth(for: id))
            guard !layout.covers, let shown = layout.frame?.width else { continue }
            caps[id] = shown
        }
        if caps != store.panelWidthCaps { store.panelWidthCaps = caps }
    }

    /// The corner `card` leaves out for the window's controls (`PaneCard.notch`), if it is the
    /// card that runs under them. In the horizontal layout the tab strip holds the top row.
    private func cardNotch(_ card: CGRect, in bounds: CGRect) -> CGSize? {
        PaneCard.notch(isTopLeading: PaneCard.isTopLeading(card, in: bounds) && settings.tabLayout == .vertical,
                       isFullScreen: store.windowIsFullScreen, cardWindowMinX: geometry.paneMinX + card.minX)
    }

    /// How far the tab strip starts past its own edge to keep clear of the window's controls.
    private func stripClearance(leading: CGFloat) -> CGFloat {
        let stripMinX = geometry.paneMinX + leading
        return max(0, WindowChrome.controlsEnd(isFullScreen: store.windowIsFullScreen) + 4 - stripMinX)
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
        // A stream pane has no embedded view for the driver to find, and would
        // be retried forever; its own view is focused directly instead.
        if store.runtimes[id]?.streamLink != nil {
            focusStreamPane(id, reason: reason)
            return
        }
        let state = store.surface(for: session)
        focusDriver.moveFocus(
            to: state,
            sessionID: id,
            reason: reason,
            canFocus: { [weak store] in
                guard let store else { return false }
                // A session that turned into a stream pane after this request
                // has no embedded view left to find; stop retrying.
                return store.runtimes[id]?.streamLink == nil
                    && Self.terminalMayTakeKeyboard(id, store: store)
            }
        )
    }

    /// The driver's rule for a stream pane: a repair takes the keyboard only from
    /// nothing or the window itself, never from a field; the other reasons
    /// replace whatever holds it. A pane not mounted yet takes it when its view
    /// enters the window.
    private func focusStreamPane(_ id: Session.ID, reason: TerminalFocusReason) {
        guard Self.terminalMayTakeKeyboard(id, store: store),
              let root = AppDelegate.mainWindow?.contentView,
              let view = streamView(for: id, under: root),
              let window = view.window
        else { return }
        let current = window.firstResponder
        guard current !== view else { return }
        if !reason.replacesCurrentResponder, current != nil, current !== window { return }
        window.makeFirstResponder(view)
    }

    /// Whether the session's terminal may take the keyboard now: the embedded
    /// surface's focus driver and the stream view ask the same question.
    static func terminalMayTakeKeyboard(_ id: Session.ID, store: TermioStore) -> Bool {
        // An open detail keeps the keyboard while it is on screen: in its panel, or
        // maximized over the window, which shows it whether the panel is open or not.
        let hasDetail = store.openFileURL != nil || store.openingRemoteFile != nil || store.openDiff != nil
        let detailShown = hasDetail && (store.inspectorVisible || store.inspectorMaximized)
        return store.selectedSessionID == id
            && store.visiblePaneIDs.contains(id)
            && !detailShown
            && store.paletteMode == nil
    }

    private func injectTerminalFocusOrphan() {
        // The injector drives the embedded surface's view; a stream pane has none.
        guard AppChannel.isDev,
              let id = store.selectedSessionID,
              store.runtimes[id]?.streamLink == nil,
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
        if store.typeAtPrompt(text, in: session) { return true }

        // The shell may not be attached yet (a freshly opened session whose surface
        // hasn't mounted). Selecting it above mounts the surface; retry a moment later, once.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !store.typeAtPrompt(text, in: session) {
                Log.pty.error("dropped path could not be sent — \(session.title, privacy: .public) has no live terminal")
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = localized("Couldn’t add the dropped item")
                alert.informativeText = localized("This session has no running terminal.")
                alert.runModal()
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

    /// The horizontal layout's tabs, while there is a session to show them for.
    private var showsTabStrip: Bool {
        settings.tabLayout == .horizontal && store.selectedSessionID != nil
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
/// daemon sizes the session to the screen a person is in front of, so while
/// somebody is working on the phone those bytes are wrapped for the phone's
/// grid — and a surface stretched across this pane would re-wrap them at its own
/// width, the §C.5 divergence: every line that wrapped on the phone lands
/// somewhere else here, and a TUI that repaints incrementally never repairs it.
/// So a pane larger than the session normally shows it at exactly the shared
/// grid, anchored top-left with the terminal background around it — the same
/// picture the phone has, at the Mac's font. A local outward resize is the safe
/// exception: widening can rejoin rows but cannot split them at an invented
/// width, so the surface grows with the pane until the daemon answers.
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
    /// Only for the trace: four links log into one stream, and before the name
    /// was on every line their interleaved bursts read as a loop.
    let sessionName: String
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
        // Always anchored, never centred. A centred island moves as the pane
        // grows, so a window drag slid the text around inside it before
        // snapping — the shake. Anchoring is also what every multiplexer does
        // with the space it cannot fill: tmux pads to the right and bottom,
        // screen leaves it blank. The text stays exactly where it is and only
        // the empty area changes.
        ZStack(alignment: .topLeading) {
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
            // The inputs behind the declaration, which the wire trace cannot
            // show: `declare 46x47` answered by `surface-at 45x47` never named
            // the rectangle and cell the two disagreed about, and the gap was
            // guessed at as a points-vs-pixels off-by-one in
            // `TerminalGrid.fitting` for a day. It was not: the pane really did
            // change height. Whatever the next disagreement is, it takes
            // numbers, not argument.
            Log.termiod.info("""
            resize-trace \(self.sessionName.prefix(8), privacy: .public) measure \
            pane=\(self.paneSize.width, privacy: .public)x\(self.paneSize.height, privacy: .public) \
            cell=\(self.cellSize?.width ?? -1, privacy: .public)x\(self.cellSize?.height ?? -1, privacy: .public) \
            scale=\(self.displayScale, privacy: .public) \
            padX=\(self.paddingX, privacy: .public) \
            grid=\(grid?.rows ?? 0, privacy: .public)x\(grid?.cols ?? 0, privacy: .public)
            """)
        }
    }

    /// How much this pane could show. `TerminalGrid.fitting` is libghostty's own
    /// floor, shared with the phone so both clients answer the question the same
    /// way — the session moves between them.
    private var paneGrid: TerminalGrid? {
        guard let cell = cellSize else { return nil }
        return TerminalGrid.fitting(
            paneSize, cell: cell, paddingX: paddingX,
            paddingY: CGFloat(TermioStore.terminalWindowPaddingY))
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
    ///
    /// Growing used to be exempt: a widening pane let its surface run ahead of
    /// the daemon, on the reasoning that widening only rejoins rows and cannot
    /// split one at a width the child never drew. That is true of the content
    /// already on screen and says nothing about the bytes still arriving. While
    /// the lead was open the app's VT was at the new width and the daemon's was
    /// at the old one, so every byte the child wrote in that window — computed
    /// for the old width, because that is the winsize it had — was parsed here
    /// at the new one. A TUI redrawing its own borders is exactly that, which is
    /// why widening a window showed two box borders at two widths and narrowing
    /// it never did.
    ///
    /// Ghostty cannot have that bug: one terminal behind one mutex, so there is
    /// only ever one width and nothing to lead (`renderer/State.zig` holds a
    /// *pointer* to the live terminal, and `termio/Termio.zig`'s resize reflows
    /// it inside the renderer lock). Termio cannot share the object — the
    /// session outlives the client — but it can hold the same invariant: at any
    /// instant one width is authoritative and no parser is anywhere else. The
    /// lead was the only place that broke it, and it bought a cosmetic gain,
    /// filling the pane one round trip sooner. That trip is 19ms at the median
    /// and 55ms at p90 over the local socket.
    private var letterboxSize: CGSize? {
        // A pane already the session's size fills the pane exactly, with none of
        // the half-cell slack a letterbox needs, so the common case looks the
        // way it always did.
        guard runtime.sizesByPolicy,
              let grid = runtime.sharedGrid, grid != paneGrid, let cell = cellSize
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

/// Keeps a stream pane's link told whether the pane is on screen and which
/// colors to use, from a view that stays mounted while the pane's own view is
/// mounted only when it shows: a hidden pane's terminal still answers color
/// queries from a program running in it.
/// A window that is not active: its own selection, drawn read-only. A session the active
/// window shows live, or one on the embedded surface — a view that can be in one window
/// only — shows a placeholder card. Rex's `DetachedTabPlaceholder`, except that a click
/// anywhere makes this window active, and the terminal comes here.
private struct InactiveWindowPane: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var geometry: NavigatorGeometry
    @EnvironmentObject var window: WindowContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let leading = max(0, PaneCard.spacing - geometry.paneMinX)
            let bounds = CGRect(x: leading, y: PaneCard.spacing,
                                width: max(0, geo.size.width - leading - PaneCard.spacing),
                                height: max(0, geo.size.height - 2 * PaneCard.spacing))
            ZStack(alignment: .topLeading) {
                if !window.isOpen {
                    EmptyView()
                } else if let selection {
                    let frames = paneFrames(for: selection, in: bounds)
                    let shownLive = Set(store.visiblePaneIDs)
                    ForEach(Array(frames.keys), id: \.self) { id in
                        if let session = store.session(id), let card = frames[id] {
                            cardView(session, frame: card, bounds: bounds, shownLive: shownLive.contains(id))
                        }
                    }
                } else {
                    WelcomeView()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    /// This window's selection, while its session still exists.
    private var selection: Session.ID? {
        window.selectedSessionID.flatMap { store.session($0) == nil ? nil : $0 }
    }

    /// The cards of the selection's split group, or the selection alone filling the pane.
    private func paneFrames(for selection: Session.ID, in bounds: CGRect) -> [Session.ID: CGRect] {
        guard let root = store.splitGroups.first(where: { $0.contains(selection) }) else {
            return [selection: bounds]
        }
        return root.layout(in: bounds, dividerThickness: PaneCard.spacing).frames
    }

    @ViewBuilder
    private func cardView(_ session: Session, frame card: CGRect, bounds: CGRect, shownLive: Bool) -> some View {
        let id = session.id
        let notch = PaneCard.notch(
            isTopLeading: PaneCard.isTopLeading(card, in: bounds) && settings.tabLayout == .vertical,
            isFullScreen: window.isFullScreen, cardWindowMinX: geometry.paneMinX + card.minX)
        let rect = PaneCard.panelLayout(in: card, isOpen: false, width: 0).terminal
        PaneCardChrome(session: session, isSelected: id == window.selectedSessionID,
                       background: paneBackground, notch: notch, publishesGeometry: false)
            .frame(width: card.width, height: card.height)
            .position(x: card.midX, y: card.midY)
        Group {
            let elsewhere = shownLive || drawnByEarlierWindow(id)
            if !elsewhere, let link = store.runtime(for: id).streamLink {
                TermiodStreamPane(
                    link: link,
                    sessionID: id,
                    appearance: store.streamAppearance(),
                    takesKeyboard: false,
                    copyOnSelect: settings.copyOnSelect,
                    readOnly: true,
                    // Read-only: a window the user left never sizes the session. Its layout
                    // drops the panel, tabs and zoom, and two such windows would fight.
                    onViewport: { _ in },
                    onFocused: {},
                    onBackgroundColor: { color in store.runtime(for: id).streamBackgroundColor = color }
                )
                .id(ObjectIdentifier(link))
                .onAppear { store.reportRendering(true, for: id, viewer: viewer) }
                .onDisappear { store.reportRendering(false, for: id, viewer: viewer) }
            } else {
                Text(elsewhere ? localized("Showing in another window") : localized("Click to show it here"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .background(paneBackground)
        .clipShape(PaneCard.bodyClip(leading: true, trailing: true, topLeading: notch != nil))
        .position(x: rect.midX, y: rect.midY)
        PaneCardBorder(isFocused: false, notch: notch)
            .frame(width: card.width, height: card.height)
            .position(x: card.midX, y: card.midY)
            .allowsHitTesting(false)
    }

    /// Whether an older inactive window already draws `id`. Two views of one stream
    /// terminal share its dirty rows, so the second would miss changes; the way Rex
    /// keeps a tab in one window, the oldest one draws it and the rest say where it is.
    private func drawnByEarlierWindow(_ id: Session.ID) -> Bool {
        for controller in MainWindowController.all {
            let other = controller.context
            if other === window { return false }
            guard other.isOpen, !other.isActive,
                  let selection = other.selectedSessionID, store.session(selection) != nil else { continue }
            let group = store.splitGroups.first { $0.contains(selection) }
            if selection == id || group?.contains(id) == true { return true }
        }
        return false
    }

    /// Reported apart from this window's active pane area, so the two never cancel out
    /// while the window changes between them.
    private var viewer: AnyHashable { "inactive-\(ObjectIdentifier(window).debugDescription)" }

    private var paneBackground: Color {
        settings.isBackgroundTranslucent ? .clear : Color(nsColor: settings.terminalBackgroundColor)
    }
}

private struct StreamLinkReport: View {
    let isVisible: Bool
    let colors: TermiodStreamTerminal.Theme?
    let scrollbackBytes: Int
    let link: TermiodSessionLink
    let report: (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: isVisible, initial: true) { _, visible in report(visible) }
            // The window went inactive or closed: it shows nothing any more.
            .onDisappear { report(false) }
            .onChange(of: colors, initial: true) { _, colors in
                if let colors { link.setStreamTheme(colors) }
            }
            .onChange(of: scrollbackBytes, initial: true) { _, bytes in
                link.setStreamScrollback(bytes: bytes)
            }
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
            .onDisappear { onVisibility(false) }
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

/// The stream view mounted for a session, if its pane is on screen.
@MainActor
private func streamView(for id: Session.ID, under root: NSView) -> TermiodStreamView? {
    if let view = root as? TermiodStreamView, view.sessionID == id { return view }
    for child in root.subviews {
        if let match = streamView(for: id, under: child) { return match }
    }
    return nil
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
    let notchWidth: CGFloat
    let controlsMinX: CGFloat?

    var body: some View {
        if let rect = PaneDragRearrange.handleRect(in: paneFrame.size, notchWidth: notchWidth,
                                                   controlsMinX: controlsMinX) {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(isOverHandle ? 0.8 : 0.3))
                .frame(width: rect.width, height: rect.height)
                .position(x: paneFrame.minX + rect.midX, y: paneFrame.minY + rect.midY)
                .transition(.opacity)
        }
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

/// One drop destination for the whole terminal group, resolving the pane under the
/// pointer itself.
///
/// A file, a folder or an issue link is inserted at that pane's prompt. A session
/// dragged out of the sidebar means one thing only — group it in beside the pane it
/// was released over, on the side it was released on — so every part of a pane is a
/// live edge, and a pane it cannot join declines the drag instead of doing something
/// else with it.
///
/// One destination for the group rather than one per pane, because a pane's own
/// destination cannot be withdrawn when the pane is hidden: SwiftUI consults a
/// hidden pane's delegate anyway, and its refusal ends the drag rather than passing
/// it to the pane beneath (issue #610). Only the visible panes are candidates here,
/// so a hidden one can never take a drop meant for the pane on screen.
private struct GroupDropDelegate: DropDelegate {
    let bounds: CGRect
    let frames: [Session.ID: CGRect]
    let visible: [Session.ID]
    let zoomed: Bool
    let selected: Session.ID?
    let store: TermioStore
    let send: ([URL], Session.ID) -> Bool

    /// The visible pane under `point`, with the rect it occupies. A zoomed pane owns
    /// the whole group; an ungrouped one has no split frame and fills it.
    private func pane(at point: CGPoint) -> (id: Session.ID, rect: CGRect)? {
        if zoomed {
            guard let selected, visible.contains(selected) else { return nil }
            return (selected, bounds)
        }
        for id in visible {
            let rect = frames[id] ?? bounds
            if rect.contains(point) { return (id, rect) }
        }
        return nil
    }

    /// A session drag is refused by every pane it cannot join — its own pane, another
    /// project, another worktree — so the pointer shows the no-drop cursor rather than
    /// accepting a release that would do nothing. Anything that is not one of our rows
    /// is a payload for the prompt, and always lands.
    func validateDrop(info: DropInfo) -> Bool {
        guard let target = pane(at: info.location) else { return false }
        guard let moved = store.resolveDraggedSession() else { return true }
        return store.canGroup(moved, with: target.id)
    }

    func dropEntered(info: DropInfo) {
        store.resolveDraggedSession()
        track(info)
    }

    /// The pane under the pointer changes without any enter/exit now that one
    /// destination spans the group, so the cue is recomputed on every move.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        guard let target = pane(at: info.location) else { return DropProposal(operation: .forbidden) }
        if let moved = store.draggingSessionID, !store.canGroup(moved, with: target.id) {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        guard store.sessionDropTarget != nil else { return }
        store.sessionDropTarget = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let moved = store.resolveDraggedSession()
        store.sessionDropTarget = nil
        // Everything the sidebar drew for the drag goes with it: the gap, a group it armed.
        store.endSessionRowDrag()
        guard let target = pane(at: info.location) else { return false }
        guard let moved else { return insert(info, into: target.id) }
        guard store.canGroup(moved, with: target.id) else { return false }
        let local = CGPoint(x: info.location.x - target.rect.minX,
                            y: info.location.y - target.rect.minY)
        store.dropSession(moved, onto: target.id,
                          zone: PaneDropZone.edge(at: local, in: target.rect.size))
        return true
    }

    /// Lights what the release would commit: the half a pane would give up to a
    /// session being grouped in, or the whole pane for a payload being typed.
    ///
    /// Published only when it changes. `dropUpdated` fires at pointer rate, and a
    /// write to any `@Published` on the store invalidates every view observing it —
    /// the whole sidebar list and the pane tree — so republishing the zone the cue
    /// is already showing redraws the app for nothing.
    private func track(_ info: DropInfo) {
        guard let target = pane(at: info.location) else {
            if store.sessionDropTarget != nil { store.sessionDropTarget = nil }
            return
        }
        let local = CGPoint(x: info.location.x - target.rect.minX,
                            y: info.location.y - target.rect.minY)
        let zone = store.draggingSessionID == nil
            ? .center : PaneDropZone.edge(at: local, in: target.rect.size)
        let next = SessionDropTarget(pane: target.id, zone: zone)
        guard store.sessionDropTarget != next else { return }
        store.sessionDropTarget = next
    }

    /// Everything that ends up at the prompt: files and folders from the Finder or
    /// the file tree, an issue's link from the Issues list.
    private func insert(_ info: DropInfo, into pane: Session.ID) -> Bool {
        let providers = info.itemProviders(for: [.url])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var dropped: [URL] = []
            for provider in providers {
                if let url = await provider.droppedURL() { dropped.append(url) }
            }
            _ = send(dropped, pane)
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

/// The draggable divider between two split panes: the gap between their cards,
/// with a slightly wider invisible hit area. Nothing is drawn — the two borders
/// already mark the seam. Dragging writes
/// the branch ratio through `onRatioChange`; the anchor is captured on the
/// first tick so the delta is always relative to where the drag began, not to
/// the live (already-moved) ratio.
private struct SplitDividerHandle: View {
    let spec: SplitNode.DividerSpec
    let onRatioChange: (Double) -> Void
    let onDragEnded: () -> Void
    @State private var anchorRatio: Double?
    @State private var isHovering = false

    /// Whether the divider line runs vertically (panes side by side).
    private var verticalLine: Bool { spec.direction == .horizontal }
    private static let hitThickness: CGFloat = 9

    var body: some View {
        SashGrip(axis: verticalLine ? .vertical : .horizontal,
                 isActive: isHovering || anchorRatio != nil)
            .overlay {
                SashHandle(
                    axis: verticalLine ? .vertical : .horizontal,
                    onHover: { isHovering = $0 },
                    onBegin: {
                        anchorRatio = spec.ratio
                        // AppKit never sees this as a split-view drag, so without this the
                        // panes it resizes declare on the 400ms animation debounce and the
                        // session only reflows after release.
                        GeometryDragTracker.shared.beginDrag()
                    },
                    onChange: { delta in
                        guard let start = anchorRatio, spec.span > 0 else { return }
                        onRatioChange(start + Double(delta / spec.span))
                    },
                    onEnd: {
                        guard anchorRatio != nil else { return }
                        anchorRatio = nil
                        GeometryDragTracker.shared.endDrag()
                        // The release's own layout pass is still ahead of us; flush after it
                        // so the settling size goes out at once instead of waiting out the
                        // stream's window.
                        DispatchQueue.main.async { onDragEnded() }
                    })
            }
            .frame(width: verticalLine ? Self.hitThickness : spec.frame.width,
                   height: verticalLine ? spec.frame.height : Self.hitThickness)
            .position(x: spec.frame.midX, y: spec.frame.midY)
            .onDisappear {
                // A handle torn down mid-drag never delivers its release.
                guard anchorRatio != nil else { return }
                anchorRatio = nil
                GeometryDragTracker.shared.endDrag()
            }
    }
}

// MARK: - Pane cards

/// Every pane is a card: a bordered, rounded rect with a one-line header naming
/// where its session runs, and the terminal below. The header's height is fixed
/// and always present — hover only reveals its buttons, never the header itself —
/// because a header that came and went would resize the surface under it, and a
/// resize is a SIGWINCH the shell answers by repainting.
enum PaneCard {
    /// The margin around the pane area, and the gap between two cards. The gap is
    /// the split divider's own strip, so dragging it still resizes the split.
    static let spacing: CGFloat = WindowChrome.inset
    /// With `spacing`, centres the top row's headers on the control rows' line.
    static let headerHeight: CGFloat = WindowChrome.rowHeight
    static let cornerRadius: CGFloat = 10

    /// The room between the navigator toggle and the notch's edge.
    static let notchGap: CGFloat = 4

    /// Where a header's leading close ends, from the card's edge: past the notch, the header's
    /// 10pt inset, and the 18pt button centred in the 14pt icon slot. A narrow card's grab handle
    /// can reach this far, and the press there belongs to the close.
    static func closeSlotEnd(notchWidth: CGFloat) -> CGFloat { notchWidth + 10 + 16 }

    /// The card's own coordinate space, top-left origin: where its header measures its
    /// trailing buttons for the grab handle to keep clear of.
    static let coordinateSpace = "termio.paneCard"

    /// The corner the top-leading card leaves out where it runs under the traffic lights and the
    /// navigator toggle: window controls, not the card's, so they sit on the window's ground and
    /// the card's edge curves around them. It grows from nothing as the card slides under them
    /// and shrinks as it leaves, so the card's edge and title are never under a control. `nil`
    /// for every other card, and for this one while it is clear of them.
    @MainActor static func notch(isTopLeading: Bool, isFullScreen: Bool, cardWindowMinX: CGFloat) -> CGSize? {
        guard isTopLeading else { return nil }
        let width = WindowChrome.controlsEnd(isFullScreen: isFullScreen) + notchGap - cardWindowMinX
        guard width > 0 else { return nil }
        return CGSize(width: width, height: headerHeight)
    }
    static let borderWidth: CGFloat = 1

    /// Whether a card holds the pane area's top-left corner. That card carries the navigator
    /// toggle while the sidebar is collapsed, beside the traffic lights.
    static func isTopLeading(_ card: CGRect, in bounds: CGRect) -> Bool {
        card.minY <= bounds.minY + 0.5 && card.minX <= bounds.minX + 0.5
    }

    /// The narrowest a terminal may get beside an open panel. A card that cannot spare the
    /// panel's width beside this lays the panel over its terminal instead, and the terminal
    /// keeps its size.
    static let minimumTerminalWidth: CGFloat = 360

    /// Where a card's terminal and panel sit. The panel takes the card's trailing side: the
    /// terminal's text is anchored to its leading edge, so opening the panel narrows the
    /// terminal without moving a character of it.
    /// `covers`: the person laid the panel over the terminal (the header's hide-terminal button).
    /// Passing `covers` lays the panel over the terminal even where it would fit beside it, and
    /// `heldWidth` keeps the panel at that width whatever the card can spare.
    static func panelLayout(in card: CGRect, isOpen: Bool, width: CGFloat, covers: Bool = false,
                            heldWidth: CGFloat? = nil)
        -> (terminal: CGRect, frame: CGRect?, covers: Bool) {
        let body = terminalRect(in: card)
        guard isOpen else { return (body, nil, false) }
        guard !covers, panelFits(in: card) else { return (body, body, true) }
        // The shared width, narrowed to what this card can spare: a width set in a wide card
        // narrows the panel here rather than hiding this card's terminal.
        let fitted = heldWidth ?? min(width, widestPanel(in: card))
        let terminal = CGRect(x: body.minX, y: body.minY,
                              width: max(0, body.width - fitted - panelDivider), height: body.height)
        let panel = CGRect(x: body.maxX - fitted, y: body.minY, width: fitted, height: body.height)
        return (terminal, panel, false)
    }

    /// The strip between a card's terminal and its panel: a 1pt line in the middle, and the
    /// whole strip a handle for dragging the panel's width.
    static let panelDivider: CGFloat = 7
    static let minimumPanelWidth: CGFloat = 240

    /// The panel's shape inside its card: its own rounded top-leading corner where it meets the
    /// terminal, the card's corner at the bottom-trailing one, and — laid over the whole body —
    /// the card's bottom-leading corner too.
    ///
    /// `notched`: a panel covering the card that leaves its top-leading corner out meets the
    /// card's rounded shoulder there, so it rounds that corner too.
    /// A panel beside the terminal is square on its leading side, where its edge runs straight
    /// from the card's top border to its bottom border.
    static func panelClip(covers: Bool, notched: Bool = false) -> UnevenRoundedRectangle {
        let inner = cornerRadius - borderWidth
        return UnevenRoundedRectangle(topLeadingRadius: covers && notched ? inner : 0,
                                      bottomLeadingRadius: covers ? inner : 0,
                                      bottomTrailingRadius: inner,
                                      style: .continuous)
    }

    /// Where a panel's edge is drawn. Beside the terminal it runs the card's full height, from
    /// the top border through the header to the bottom border, so the header's strip over the
    /// panel is the panel's too; a panel covering the terminal keeps its own rect.
    static func panelEdgeFrame(_ panel: CGRect, covers: Bool) -> CGRect {
        guard !covers else { return panel }
        return CGRect(x: panel.minX, y: panel.minY - headerHeight,
                      width: panel.width, height: panel.height + headerHeight + borderWidth)
    }

    /// Clips the body's bottom corners — the ones it shares with the card — to the card's
    /// radius, inside its border.
    /// `topLeading` for the card that leaves its top-leading corner out (`notch`): the terminal
    /// starts right under the notch, where the card's edge rounds the shoulder.
    static func bodyClip(leading: Bool, trailing: Bool, topLeading: Bool = false) -> UnevenRoundedRectangle {
        let radius = cornerRadius - borderWidth
        return UnevenRoundedRectangle(topLeadingRadius: topLeading ? radius : 0,
                                      bottomLeadingRadius: leading ? radius : 0,
                                      bottomTrailingRadius: trailing ? radius : 0,
                                      style: .continuous)
    }

    /// The widest panel `card` can hold beside a terminal of `minimumTerminalWidth`.
    static func widestPanel(in card: CGRect) -> CGFloat {
        terminalRect(in: card).width - panelDivider - minimumTerminalWidth
    }

    /// Whether even the narrowest panel fits beside the terminal in `card`. Without that the
    /// panel covers the terminal.
    static func panelFits(in card: CGRect) -> Bool {
        widestPanel(in: card) >= minimumPanelWidth
    }

    /// Where the terminal sits inside a card: under the header, inside the border.
    static func terminalRect(in card: CGRect) -> CGRect {
        CGRect(x: card.minX + borderWidth,
               y: card.minY + headerHeight,
               width: max(0, card.width - 2 * borderWidth),
               height: max(0, card.height - headerHeight - borderWidth))
    }
}

/// The card's background and header. Drawn behind the surface; the border is a
/// separate view above it (`PaneCardBorder`).
private struct PaneCardChrome: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    let session: Session
    let isSelected: Bool
    let background: Color
    /// The corner left out for the window's controls (`PaneCard.notch`).
    let notch: CGSize?
    /// Where the panel's edge crosses the header, from the card's leading edge, while a panel
    /// sits beside the terminal. The edge runs the card's full height (`PanelEdge`), so the
    /// title stops short of it and the buttons past it sit in the panel.
    var panelEdgeX: CGFloat?
    /// Whether the header's measurements feed the shared pane-drag geometry. Only the active
    /// window's cards do: the geometry is keyed by session, and an inactive window drawing the
    /// same group at another width would move the active window's drag boundary.
    var publishesGeometry = true

    /// The header starts past the notch, so the title waits beside the toggle while the card
    /// slides under it.
    private var leadingPadding: CGFloat {
        (notch?.width ?? 0) + 10
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .environment(\.colorScheme, headerScheme ?? colorScheme)
            Spacer(minLength: 0)
        }
        .background(cardBackground, in: PaneCardShape(notch: notch))
        .coordinateSpace(.named(PaneCard.coordinateSpace))
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHeaderHovering = false
    @State private var isOverClose = false

    /// A stream pane's default background, which a program may set with
    /// OSC 11, carried into the pane's chrome. Never the top row's color: that
    /// changes whenever a colored line scrolls past the top. A translucent
    /// card stays clear.
    private var programColor: NSColor? {
        guard !settings.isBackgroundTranslucent else { return nil }
        let runtime = store.runtime(for: session.id)
        guard runtime.streamLink != nil else { return nil }
        return runtime.streamBackgroundColor
    }

    private var cardBackground: Color {
        programColor.map { Color(nsColor: $0) } ?? background
    }

    /// The header's text and icons follow the program's color, so a light
    /// program in dark mode keeps a readable title.
    private var headerScheme: ColorScheme? {
        guard let color = programColor?.usingColorSpace(.sRGB) else { return nil }
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance > 0.5 ? .light : .dark
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Group {
                    // Close swaps in for the icon under the pointer, as on a Safari tab: at the
                    // leading edge, where macOS closes things, and away from the trailing buttons,
                    // which sit over the panel when one is open and would read as closing it.
                    // Swapping costs the title no width, so a narrow card's buttons stay clear
                    // of the grab handle.
                    if isHeaderHovering {
                        Button { store.requestCloseSession(session.id) } label: {
                            HugeIconView(icon: .close, size: 10, color: .secondary)
                                .frame(width: 18, height: 18)
                                .background(CloseHoverDisc(isHovering: isOverClose, diameter: 18))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { isOverClose = $0 }
                        .help(localized("Close Session"))
                    } else if session.isSSH {
                        HugeIconView(icon: .serverStack, size: 13, color: .secondary)
                    } else {
                        AgentIconView(agent: store.effectiveAgent(for: session), size: 13)
                    }
                }
                .frame(width: 14)
                Text(location)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(location)
                    .layoutPriority(1)
                if let branch {
                    HStack(spacing: 3) {
                        HugeIconView(icon: .gitBranch, size: 11, color: .secondary)
                        Text(branch)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(branch)
                }
            }
            .frame(maxWidth: panelEdgeX.map { max(0, $0 - leadingPadding - 8) } ?? .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                // Always laid out, only hidden: showing them must not reflow the title.
                // Only the focused card's: the buttons act on the card you are in, and a row of
                // them on every card — or on whichever one the pointer crosses — is noise.
                buttons.opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                // The inspector reads the focused session, so only the focused card opens it.
                if isSelected {
                    // Pulled in so its glyph sits as far from the zoom glyph as the split glyphs sit
                    // from each other: the menu pads its glyph by 6 where an icon button's 24pt frame
                    // leaves 4.5, and the header's 6pt spacing is wider than the buttons' 2.
                    InspectorPaneMenu()
                        .padding(.leading, -5.5)
                }
            }
            // Measured, not summed: the panel menu grows a label while a panel is open.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(PaneCard.coordinateSpace)).minX } action: {
                if publishesGeometry { PaneCardGeometry.shared.setControlsMinX($0, for: session.id) }
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 4)
        .frame(height: PaneCard.headerHeight)
        // The header's empty run moves the window, as a titlebar would. A press here also
        // focuses the card (`PaneDragRearrange`), so the header needs no tap of its own.
        .background(WindowDragArea(onHover: { isHeaderHovering = $0 }))
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            ChromeIconButton(icon: .layoutColumns, help: localized("Split Right")) {
                splitting(.horizontal)
            }
            ChromeIconButton(icon: .layoutRows, help: localized("Split Down")) {
                splitting(.vertical)
            }
            // Zoom only means something inside a split, as in the palette and ⌘⇧↩.
            if store.splitRoot != nil {
                ChromeIconButton(icon: store.isPaneZoomed ? .collapse : .expand,
                                 help: localized("Zoom Split"), isOn: store.isPaneZoomed) {
                    store.selectedSessionID = session.id
                    store.toggleSelectedPaneZoom()
                }
            }
        }
    }

    /// The store splits the focused pane, so the pane whose button was pressed
    /// takes focus first.
    private func splitting(_ direction: SplitDirection) {
        store.selectedSessionID = session.id
        store.splitSelectedPane(direction)
    }

    /// Where the session runs: the box for a plain SSH terminal, `box:path` for a
    /// session on another machine, and the home-abbreviated folder here.
    private var location: String {
        let folder = store.titleFolder(for: session.id)
        if let remote = session.termiodRemoteHost ?? session.sshHost {
            guard session.termiodRemoteHost != nil, let folder else { return remote }
            return "\(remote):\(folder)"
        }
        guard let folder else { return store.displayTitle(for: session) }
        return Self.abbreviatingHome(folder)
    }

    /// The live branch, or nil to hide it. A checkout on another machine only has
    /// one while it is selected: the device watches a single checkout, and a local
    /// path that merely spells the same as the remote one would name the wrong repo.
    private var branch: String? {
        if session.termiodRemoteHost != nil || session.sshHost != nil {
            guard isSelected, let checkout = store.inspectorCheckout, checkout.isOnAnotherDevice
            else { return nil }
            return store.deviceBranch(forCheckout: checkout)
        }
        guard let folder = store.titleFolder(for: session.id),
              let branch = store.branch(forFolder: folder), !branch.isEmpty else { return nil }
        return branch
    }

    private static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// A region that shows `cursor` while the pointer is over it, by cursor rect. Takes no clicks of
/// its own: a press goes to whatever the window's event monitors decide.
private struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> AreaView {
        let view = AreaView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ view: AreaView, context: Context) {
        guard view.cursor != cursor else { return }
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class AreaView: NSView {
        var cursor: NSCursor = .arrow
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        // A cursor rect needs no hit test, and one here would take the press of any header
        // button the handle reaches on a narrow card.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// What the window's event monitors (`PaneDragRearrange`, `TerminalContextMenu`) need about each
/// card that its terminal view cannot tell them: they find a card by its terminal, and a panel
/// beside the terminal (or a letterboxed grid) makes the card a different size, and a panel over
/// it takes its clicks. Each card carries a `PaneCardProbe` sized to it, so the answer is read
/// off the card's own view when asked, never a stored copy; a closed card's probe leaves with it.
@MainActor @Observable
final class PaneCardGeometry {
    static let shared = PaneCardGeometry()

    @ObservationIgnored private var probes: [Session.ID: PaneCardProbe] = [:]

    fileprivate func register(_ probe: PaneCardProbe, for id: Session.ID) { probes[id] = probe }

    fileprivate func unregister(_ probe: PaneCardProbe) {
        guard let id = probe.sessionID, probes[id] === probe else { return }
        probes.removeValue(forKey: id)
    }

    /// The card's frame in `window`'s coordinates, or nil when it is not in that window.
    func cardFrame(for id: Session.ID, in window: NSWindow) -> CGRect? {
        guard let probe = probes[id], probe.window === window else { return nil }
        return probe.convert(probe.bounds, to: nil)
    }

    /// Whether the card's panel — live, or the picture an unfocused card's panel left — lies
    /// over its terminal.
    func panelCovers(_ id: Session.ID) -> Bool {
        probes[id]?.panelCovers ?? false
    }

    /// How far the card's corner is left out for the window's controls (`PaneCard.notch`).
    func notchWidth(_ id: Session.ID) -> CGFloat {
        probes[id]?.notchWidth ?? 0
    }

    /// Where each header's trailing buttons begin, from the card's leading edge. Kept here
    /// rather than on the probe, which the header may report before it is registered, and
    /// observed: the drawn handle and its cursor rect follow it as a panel label grows.
    private var controlsMinXs: [Session.ID: CGFloat] = [:]

    /// Nil until the header has been measured.
    func controlsMinX(_ id: Session.ID) -> CGFloat? {
        controlsMinXs[id]
    }

    func setControlsMinX(_ x: CGFloat, for id: Session.ID) {
        guard controlsMinXs[id] != x else { return }
        controlsMinXs[id] = x
    }
}

final class PaneCardProbe: NSView {
    var sessionID: Session.ID?
    var panelCovers = false
    var notchWidth: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PaneCardProbeView: NSViewRepresentable {
    let sessionID: Session.ID
    let panelCovers: Bool
    let notchWidth: CGFloat

    func makeNSView(context: Context) -> PaneCardProbe {
        let probe = PaneCardProbe()
        probe.sessionID = sessionID
        PaneCardGeometry.shared.register(probe, for: sessionID)
        return probe
    }

    func updateNSView(_ probe: PaneCardProbe, context: Context) {
        probe.panelCovers = panelCovers
        probe.notchWidth = notchWidth
        if probe.sessionID != sessionID {
            PaneCardGeometry.shared.unregister(probe)
            probe.sessionID = sessionID
            PaneCardGeometry.shared.register(probe, for: sessionID)
        }
    }

    static func dismantleNSView(_ probe: PaneCardProbe, coordinator: ()) {
        MainActor.assumeIsolated { PaneCardGeometry.shared.unregister(probe) }
    }
}

/// A card's outline: a rounded rectangle, or with `notch` one whose top-leading corner is left
/// out. Every corner rounds at the card's radius, the notch's inner one the other way, so the
/// edge curves around what sits in it rather than turning a square corner.
struct PaneCardShape: InsettableShape {
    var notch: CGSize?
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard box.width > 0, box.height > 0 else { return Path() }
        let radius = max(0, PaneCard.cornerRadius - insetAmount)
        var corners: [CGPoint] = [
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
        ]
        if let notch, notch.width + 2 * radius < box.width, notch.height + 2 * radius < box.height {
            let inner = CGPoint(x: rect.minX + notch.width + insetAmount, y: rect.minY + notch.height + insetAmount)
            corners += [CGPoint(x: box.minX, y: inner.y), inner, CGPoint(x: inner.x, y: box.minY)]
        } else {
            corners.append(CGPoint(x: box.minX, y: box.minY))
        }
        // Start midway along the closing edge, so every corner, the first included, is rounded.
        guard let last = corners.last, let first = corners.first else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for index in corners.indices {
            let previous = corners[(index + corners.count - 1) % corners.count]
            let corner = corners[index]
            let next = corners[(index + 1) % corners.count]
            // A notch grows from zero width as the card slides under the window's controls; a
            // corner never rounds wider than half its shorter edge, so a thin notch stays a notch.
            let fit = min(hypot(corner.x - previous.x, corner.y - previous.y),
                          hypot(next.x - corner.x, next.y - corner.y)) / 2
            path.addArc(tangent1End: corner, tangent2End: next, radius: min(radius, fit))
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> PaneCardShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// The card's outline, drawn over the surface as a lit rim in the manner of Liquid Glass's
/// specular edge: light from the top leading corner catches the top edge and fades down the
/// sides, brightest at the leading end and fainter at the trailing one, and a weaker reflection
/// lights the bottom trailing corner, over a hairline that keeps the other edges defined. Only the focused card is lit — the one cue for where typing
/// goes; the others keep the hairline.
private struct PaneCardBorder: View {
    let isFocused: Bool
    let notch: CGSize?

    var body: some View {
        let shape = PaneCardShape(notch: notch)
        let peak = 0.6
        ZStack {
            shape.strokeBorder(Color.primary.opacity(isFocused ? 0.12 : 0.08), lineWidth: PaneCard.borderWidth)
            if isFocused {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .primary.opacity(peak), location: 0),
                            .init(color: .primary.opacity(peak * 0.35), location: 0.18),
                            .init(color: .primary.opacity(0), location: 0.5),
                        ],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: PaneCard.borderWidth)
                    .mask(LinearGradient(colors: [.white, .white.opacity(0.4)],
                                         startPoint: .leading, endPoint: .trailing))
                // The weaker reflection: light that crossed the glass catching its far edge.
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .primary.opacity(0), location: 0.6),
                            .init(color: .primary.opacity(peak * 0.35), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: PaneCard.borderWidth)
                    .mask(LinearGradient(colors: [.clear, .white],
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
    }
}

/// An open panel on a card without focus: the picture the live panel left when the card lost it.
private struct PanelSnapshot: View {
    let image: NSImage?
    let background: Color

    /// At the size it was taken, pinned top-leading and cut at the panel's edges. The card can
    /// change width after the picture is taken (the sidebar sliding, a window resize); filled to
    /// the new frame instead, the picture outgrew it and was centred, cutting every file name's
    /// start off.
    var body: some View {
        background
            .overlay(alignment: .topLeading) {
                if let image { Image(nsImage: image) }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

/// The strip between a card's terminal and its panel: a hairline, and a handle that drags the
/// panel's width. One width serves every card (`TermioStore.panelWidth`), so the drag is
/// clamped by the card it happens in: the terminal keeps `minimumTerminalWidth`.
private struct PanelDividerHandle: View {
    @EnvironmentObject var store: TermioStore
    let panelFrame: CGRect
    let card: CGRect
    @State private var anchorWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        // The grip lights over the seam itself (`PanelEdge`), at its full height through the
        // header: centred in the gap, it stood beside the seam and stopped short under the header.
        let edge = PaneCard.panelEdgeFrame(panelFrame, covers: false)
        ZStack {
            SashGrip(axis: .vertical, isActive: isHovering || anchorWidth != nil)
                .frame(width: SashGrip.lineWidth, height: edge.height)
                .position(x: panelFrame.minX + PaneCard.borderWidth / 2, y: edge.midY)
            SashHandle(
                axis: .vertical,
                onHover: { isHovering = $0 },
                onBegin: {
                    // The width on screen, which a narrow card may have fitted down from the
                    // shared one: starting from that keeps the panel under the pointer.
                    anchorWidth = panelFrame.width
                    // Stream the resize at drag cadence, as the split dividers do.
                    GeometryDragTracker.shared.beginDrag()
                },
                onChange: { delta in
                    guard let start = anchorWidth else { return }
                    if !store.panelWidthCaps.isEmpty { store.panelWidthCaps = [:] }
                    store.panelWidth = min(max(start - delta, PaneCard.minimumPanelWidth),
                                           max(PaneCard.minimumPanelWidth, PaneCard.widestPanel(in: card)))
                },
                onEnd: {
                    guard anchorWidth != nil else { return }
                    anchorWidth = nil
                    GeometryDragTracker.shared.endDrag()
                    DispatchQueue.main.async { store.flushViewports() }
                })
            // The gap and the seam: the line the grip draws is part of what grabs. Below the
            // header only: the header is the pane's to drag, and its centred handle can sit on
            // the seam, where the rearrange monitor takes the press first.
            .frame(width: PaneCard.panelDivider + PaneCard.borderWidth, height: panelFrame.height)
            .position(x: panelFrame.minX + (PaneCard.borderWidth - PaneCard.panelDivider) / 2,
                      y: panelFrame.midY)
        }
        .onDisappear {
            guard anchorWidth != nil else { return }
            anchorWidth = nil
            GeometryDragTracker.shared.endDrag()
        }
    }
}

/// The panel's own frame inside its card: a top edge and, beside a terminal, a leading edge,
/// joined by a rounded corner — so the panel reads as one sheet laid in the card rather than a
/// column split off it. Its other two edges are the card's border, and are not drawn twice.
private struct PanelEdge: View {
    let covers: Bool
    /// The card leaves its top-leading corner out, whose rounded shoulder the card's own border
    /// draws: a covering panel's top line starts past it rather than running straight through.
    var notched = false

    var body: some View {
        PanelEdgeShape(leading: !covers,
                       startInset: covers && notched ? PaneCard.cornerRadius : 0)
            .stroke(Color.primary.opacity(0.1), lineWidth: PaneCard.borderWidth)
            .allowsHitTesting(false)
    }
}

private struct PanelEdgeShape: Shape {
    let leading: Bool
    var startInset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // Half a line in, so the stroke lands inside the panel's rect.
        let edge = rect.insetBy(dx: PaneCard.borderWidth / 2, dy: PaneCard.borderWidth / 2)
        var path = Path()
        if leading {
            // Straight from the card's top border to its bottom border, meeting each square.
            path.move(to: CGPoint(x: edge.minX, y: edge.maxY))
            path.addLine(to: CGPoint(x: edge.minX, y: edge.minY))
            return path
        }
        path.move(to: CGPoint(x: rect.minX + startInset, y: edge.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: edge.minY))
        return path
    }
}
