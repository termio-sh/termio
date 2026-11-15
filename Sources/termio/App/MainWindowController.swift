import AppKit
import Combine
import SwiftUI

/// What one main window shows, for the views inside it. The store's selection is the
/// active window's: menu commands, the palette, the CLI and notification clicks act on it,
/// Rex's `commandModel`. Every other window keeps its own selection here and draws it
/// read-only until a click makes it active (see `MainWindowController.activate`).
@MainActor
final class WindowContext: ObservableObject {
    @Published var selectedSessionID: Session.ID?
    /// Whether this is the window the store's selection belongs to.
    @Published fileprivate(set) var isActive = false
    /// Whether this window's sidebar is expanded, mirrored from its split item.
    @Published var sidebarVisible = true
    /// Whether this window is in native macOS fullscreen.
    @Published var isFullScreen = false
    /// False while the window is closed. The first window survives its close for a Dock
    /// reopen, and a closed window must not keep showing, or sizing, a session.
    @Published fileprivate(set) var isOpen = true

    init(selectedSessionID: Session.ID?) {
        self.selectedSessionID = selectedSessionID
    }
}

/// One main window: the sidebar, the terminal cards and the chrome around them. termio
/// opens as many as the user asks for; the app delegate keeps the shared store, the
/// inspector, the palette and the servers.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    /// Marks a main window, for code that tells it apart from Settings, sheets and panels.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("termio.main")
    /// The first window's frame-autosave name. Later windows cascade from it and are not
    /// saved: a second window remembering its own frame would open on top of the first.
    static let frameAutosaveName = "TermioMainWindow"

    /// Every open main window, oldest first. This list owns them.
    private(set) static var all: [MainWindowController] = []
    /// The window the store's selection belongs to: the last main window that was key.
    private(set) static weak var active: MainWindowController?

    static func isMain(_ window: NSWindow?) -> Bool {
        window?.identifier == windowIdentifier
    }

    let window: NSWindow
    let context: WindowContext
    private let store: TermioStore
    private let settings: AppSettings

    private weak var splitViewController: NSSplitViewController?
    private weak var sidebarSplitItem: NSSplitViewItem?
    private var sidebarCollapseObserver: NSKeyValueObservation?
    private var sidebarSlide: SidebarSlideController?
    private var navigatorAnimating = false
    private var navigatorToggle: NavigatorToggleOverlay?
    private let navigatorGeometry = NavigatorGeometry()
    private static let navigatorDuration: TimeInterval = 0.25
    // Ease-out, not ease-in-out: the column answers the click on the first frame and settles at
    // the end. Ease-in-out held still for its first frames, which read as a slow, late toggle.
    private static let navigatorCurve = (x1: 0.23, y1: 1.0, x2: 0.32, y2: 1.0)
    // KVO on the window's effective appearance, so a *system-driven* light↔dark flip (macOS auto
    // day/night, Control Center) re-resolves the window background. In `.system` appearance mode
    // nothing else re-runs `applyWindowTransparency` on an OS flip — the settings never change —
    // so the statically-resolved `window.backgroundColor` would stay frozen at the old side while
    // the translucent sidebar material (which blends over it) shows the stale color and libghostty
    // repaints the terminal to the new side. That mismatch is the light-sidebar-over-dark-terminal
    // glitch. Re-applying here keeps the window background tracking the OS.
    private var appearanceObserver: NSKeyValueObservation?
    private var trafficLights: TrafficLights?
    private var backdrop: WindowBackdrop?
    // Keeps the native window title (path) and subtitle (git branch) in step with the
    // selected session — NetNewsWire's approach, no custom title-bar views.
    private var titleObserver: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    private var selectionObserver: AnyCancellable?
    // Whether `DetailHost.shared` is currently parented here, covering the content area, rather
    // than docked in the inspector's slot.
    private var detailMaximized = false
    // The full-window pins, held so they can be dropped when the host goes back to the inspector.
    private var maximizedDetailConstraints: [NSLayoutConstraint] = []
    // Whether maximizing is what collapsed the navigator, so restoring re-opens only a sidebar
    // this mode closed — never one the user had already put away.
    private var sidebarCollapsedForMaximize = false
    // Tells the viewport scheduler when a divider drag is resizing the panes (see
    // `noteSplitViewResize`).
    private var splitResizeObserver: NSObjectProtocol?
    private var detailFrameObserver: NSObjectProtocol?
    private var paneOriginObserver: NSObjectProtocol?
    private weak var terminalContainerView: NSView?
    /// Whether the split view's dividers are under the pointer right now. See
    /// `noteSplitViewResize`.
    private var splitDividerDragActive = false
    private var splitDividerDragSettle: DispatchWorkItem?

    init(store: TermioStore, settings: AppSettings, selecting selection: Session.ID?, cascadingFrom parent: NSWindow?) {
        self.store = store
        self.settings = settings
        context = WindowContext(selectedSessionID: selection)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.identifier = Self.windowIdentifier
        window.title = "Termio"
        // Closing the window no longer quits (see `applicationShouldTerminate-
        // AfterLastWindowClosed`). The first window survives its own close, so a Dock
        // reopen re-shows it rather than rebuilding one; a later window is dropped when it
        // closes (see `windowWillClose`). The default `true` would also over-release it
        // out from under the strong reference held here.
        window.isReleasedWhenClosed = false
        // Mouse-moved events are off by default; the pane grab handle reveals on
        // hover, so it needs them (see `PaneDragRearrange`).
        window.acceptsMouseMovedEvents = true
        // Floor the window size so it can't be dragged down to an unusable sliver: the
        // sidebar alone wants ~220pt, leaving room for a workable terminal beside it.
        window.contentMinSize = NSSize(width: 640, height: 420)
        // No toolbar. The traffic lights float over `.fullSizeContentView` content: the sidebar
        // carries its own controls in a row beside them, and each pane card names its own folder
        // and branch. A toolbar band would sit over the cards' headers and take their clicks, and
        // in fullscreen macOS 26 paints it as an opaque light band. `window.title` is still kept
        // current (for the Window menu and Mission Control) but is never drawn.
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // With no titlebar band left to grab, the window moves from the chrome that stands in for
        // one — a card header's empty run, the sidebar's control row (see `WindowDragArea`).
        // Deliberately not `isMovableByWindowBackground`: that also claimed presses on the
        // SwiftUI dividers and moved the window instead of resizing.
        // Drive the split with a real AppKit `NSSplitViewController` whose first item
        // has `.sidebar` behavior — NetNewsWire's architecture. This is the *only* way to
        // get the native full-height sidebar (vibrant material running up behind the
        // traffic lights, the toggle, the title-bar tracking separator). A SwiftUI
        // `NavigationSplitView` only gets that treatment as the root of a `WindowGroup`
        // scene; hosted inside a manual `NSWindow` it renders as an embedded
        // representable with no connection to the title bar, so the sidebar can never
        // reach behind the traffic lights. SwiftUI still renders each pane's contents.
        window.contentViewController = makeContentSplitViewController(savesLayout: parent == nil)
        LaunchTrace.mark("content installed")
        // The height every pane is about to measure itself against. If a future
        // change moves chrome back after this point, the panes declare a
        // viewport for a window that never existed and the trace says so here.
        Log.termiod.info("""
        resize-trace WINDOW content-height-final \
        layout=\(self.window.contentLayoutRect.width, privacy: .public)x\
        \(self.window.contentLayoutRect.height, privacy: .public)
        """)
        window.delegate = self
        if let parent {
            window.setFrame(parent.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: parent.frame.minX, y: parent.frame.maxY)))
        } else {
            window.center()
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }
        // A later window saves no divider, so the split would size the sidebar from its
        // content and land under its minimum, clipping the control row. Start at the
        // parent window's width instead.
        let parentSidebarWidth = parent.flatMap { parent in
            Self.all.first { $0.window === parent }?.sidebarSplitItem?.viewController.view.frame.width
        }
        Self.all.append(self)
        trafficLights = TrafficLights(window: window)
        navigatorToggle?.follow(window, context: context)
        applyWindowTransparency()
        window.appearance = NSApp.appearance
        // The autosaved frame can restore straight into fullscreen, so seed the mirror rather
        // than waiting for a transition that already happened.
        setFullScreen(window.styleMask.contains(.fullScreen))
        // No `.initial`: the launch-time sync below runs after the autosave restore.
        sidebarCollapseObserver = sidebarSplitItem?.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            MainActor.assumeIsolated {
                // The toggle's animation sets this on its own clock (`toggleNavigator`); every
                // other path — a divider dragged shut, a maximized detail — lands here.
                guard let self, !self.navigatorAnimating else { return }
                self.setSidebarVisible(!collapsed)
            }
        }
        splitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitViewController?.splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteSplitViewResize() }
        }
        // Re-resolve the window background whenever the OS flips light↔dark under `.system` mode
        // (see `appearanceObserver`). Pinned Light/Dark modes never see the effective appearance
        // change out from under them, so this is a no-op there; re-applying is idempotent and
        // can't loop (it changes no appearance-affecting property).
        appearanceObserver = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.applyWindowTransparency()
                self?.store.refreshHostAnswers(windowAppearance: window.effectiveAppearance)
            }
        }
        // After the split view has restored its autosaved collapse state.
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.sidebarSplitItem else { return }
            if let parentSidebarWidth, !item.isCollapsed {
                let width = min(max(parentSidebarWidth, item.minimumThickness), item.maximumThickness)
                self.splitViewController?.splitView.setPosition(width, ofDividerAt: 0)
            }
            self.setSidebarVisible(!item.isCollapsed)
        }
        updateWindowTitle()
        // Keep the native title/subtitle in step with the selected session and its live branch.
        // The title reads only the selected session's working-directory/project path (see
        // `updateWindowTitle`). A loose terminal's cwd also reaches the structural store —
        // `noteWorkingDirectory` persists it on the session — so plain `objectWillChange`
        // covers every source, and no per-session runtime ping is needed here.
        titleObserver = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.updateWindowTitle() }
            }
        settingsObserver = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.applyWindowTransparency() }
            }
        // While this window is active the store's selection is its own: every path that
        // moves it — a row click, a deep link, ⌘⇧] — lands in this window.
        selectionObserver = store.$selectedSessionID
            .sink { [weak self] id in
                MainActor.assumeIsolated {
                    guard let self, self.context.isActive, self.context.selectedSessionID != id else { return }
                    self.context.selectedSessionID = id
                }
            }
    }

    // MARK: - Active window

    /// Makes this the window the store's selection belongs to, handing the store this
    /// window's own selection and chrome state. The window that was active keeps the
    /// selection it had, and draws it read-only from then on.
    func activate() {
        guard Self.active !== self else { return }
        if let previous = Self.active {
            previous.context.isActive = false
            previous.setDetailMaximized(false)
        }
        Self.active = self
        context.isActive = true
        // Inactive windows decide from every window's state which of them draws a
        // session (`drawnByEarlierWindow`), and they observe only the store.
        store.objectWillChange.send()
        store.sidebarVisible = context.sidebarVisible
        store.windowIsFullScreen = context.isFullScreen
        let selection = context.selectedSessionID.flatMap { store.session($0) == nil ? nil : $0 }
        if store.selectedSessionID != selection {
            store.selectedSessionID = selection
        }
        context.selectedSessionID = store.selectedSessionID
        setDetailMaximized(store.inspectorMaximized && store.isDetailPresented)
        store.repaintSelectedSurface()
    }

    /// Shows the window and makes it key, which makes it active.
    func show() {
        context.isOpen = true
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activate()
        window.contentView?.layoutSubtreeIfNeeded()
        store.repaintSelectedSurface()
    }

    private func setSidebarVisible(_ visible: Bool) {
        if context.sidebarVisible != visible { context.sidebarVisible = visible }
        if context.isActive, store.sidebarVisible != visible { store.sidebarVisible = visible }
    }

    private func setFullScreen(_ fullScreen: Bool) {
        if context.isFullScreen != fullScreen { context.isFullScreen = fullScreen }
        if context.isActive, store.windowIsFullScreen != fullScreen { store.windowIsFullScreen = fullScreen }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        activate()
    }

    func windowWillClose(_ notification: Notification) {
        // The first window is kept for a Dock reopen; any other is gone for good.
        let kept = Self.all.first === self
        context.isOpen = false
        if !kept { Self.all.removeAll { $0 === self } }
        if Self.active === self,
           let next = Self.all.last(where: { $0 !== self && $0.window.isVisible }) {
            next.activate()
        }
        // Inactive windows re-decide which of them draws a session this one held.
        store.objectWillChange.send()
        // A divider drag still settling would never end: its timer holds this window weakly.
        splitDividerDragSettle?.cancel()
        splitDividerDragSettle = nil
        if splitDividerDragActive {
            splitDividerDragActive = false
            GeometryDragTracker.shared.endDrag()
        }
        guard !kept else { return }
        trafficLights?.stop()
        for observer in [splitResizeObserver, detailFrameObserver, paneOriginObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        splitResizeObserver = nil
        detailFrameObserver = nil
        paneOriginObserver = nil
        // Tear the content down now, so its panes report they stopped showing their
        // sessions rather than waiting on the window's deallocation.
        window.delegate = nil
        window.contentViewController = nil
    }

    /// Builds the window's content: an `NSSplitViewController` with the sidebar, the terminal pane
    /// and the inspector, each hosting its SwiftUI view. `toggleNavigator(_:)` collapses the
    /// sidebar item.
    private func makeContentSplitViewController(savesLayout: Bool) -> NSSplitViewController {
        // The control row takes the titlebar strip beside the traffic lights; the list starts
        // under it.
        let sidebarContent = NSHostingController(rootView: VStack(spacing: 0) {
                SidebarControlRow()
                SidebarColumn()
            }
            .ignoresSafeArea(.container, edges: .top)
            .environmentObject(store)
            .environmentObject(store.sidebarDrag)
            .environmentObject(navigatorGeometry)
            .environmentObject(context)
            .environmentObject(settings))
        // Same reason as the detail pane below: the default `.preferredContentSize`
        // publishes the tree's ideal size on every view update, so a 30Hz working
        // indicator re-negotiated the split layout 30 times a second. The split
        // item's min/max thickness governs the column; the content never should.
        sidebarContent.sizingOptions = []
        // A plain item, not `sidebarWithViewController`. Without a toolbar, macOS 26 floats the
        // stock sidebar as a glass panel that starts below the titlebar strip, so its controls
        // could never share a row with the traffic lights. A plain item runs the full height of
        // the window, flush to its edges, and paints nothing: it sits on the window's one backdrop
        // (see `WindowBackdrop`), the same one the cards float on.
        let geometry = navigatorGeometry
        let sidebarSlide = SidebarSlideController(content: sidebarContent) { travel in
            if geometry.sidebarTravel != travel { geometry.sidebarTravel = travel }
        }
        self.sidebarSlide = sidebarSlide
        let sidebarItem = NSSplitViewItem(viewController: sidebarSlide)
        // The stock sidebar's own holding priority, so a window resize is absorbed by the
        // terminal rather than split between the columns.
        sidebarItem.holdingPriority = .init(260)
        // The sidebar's control row must hold the traffic lights, the navigator toggle, the
        // workspace name, the sort pull-down and the `+`.
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        self.sidebarSplitItem = sidebarItem
        sidebarItem.titlebarSeparatorStyle = .none

        let detail = NSHostingController(rootView: TerminalPane()
            .environmentObject(store)
            .environmentObject(navigatorGeometry)
            .environmentObject(context)
            .environmentObject(settings))
        // Fill the split pane; don't size the window to the SwiftUI content. `NSHostingController`
        // defaults `sizingOptions` to `.preferredContentSize`, which publishes the tree's *ideal*
        // size as `preferredContentSize`; `NSSplitViewController` propagates that to the window. So
        // with no session the compact `ContentUnavailableView` empty state pinned the window height
        // (width stayed free because the sidebar/split governs it). Clearing the options lets the
        // pane stretch and leaves the window frame to `contentMinSize` — same fix as
        // `FileBrowserHostingController`.
        detail.sizingOptions = []
        // Diagnostic only, and deliberately not a second source of truth.
        //
        // Every pane's size descends from one `GeometryReader` over this
        // controller's view (`TerminalPane`'s body); the panes themselves are
        // then explicitly framed from it, so an AppKit probe placed *inside* a
        // pane would inherit the very number it was meant to check. This is the
        // one place the two can disagree: AppKit's own frame for the container,
        // against what SwiftUI proposed for it. A window change that moves this
        // and never reaches a `measure` line is the missed-resize bug; if they
        // never disagree there is nothing to fix here, and the traffic light is
        // macOS declining to un-fill an already-filled window.
        detail.view.postsFrameChangedNotifications = true
        terminalContainerView = detail.view
        detailFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: detail.view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.logTerminalContainerBounds() }
        }
        // No queue: delivered inside the layout pass that moved the pane, so the cards' margin and
        // notch land in the same frame as the slide instead of one behind it.
        paneOriginObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: detail.view, queue: nil
        ) { [weak self, weak pane = detail.view] _ in
            MainActor.assumeIsolated {
                guard let self, let pane, pane.window != nil else { return }
                let minX = pane.convert(pane.bounds, to: nil).minX
                if self.navigatorGeometry.paneMinX != minX { self.navigatorGeometry.paneMinX = minX }
            }
        }
        let detailItem = NSSplitViewItem(viewController: detail)
        // Without a floor here the terminal pane absorbs every squeeze. With a floor, shrinking the window past the sum of minimums collapses the collapsible
        // side panes instead, the native Xcode behaviour.
        detailItem.minimumThickness = 280
        detailItem.titlebarSeparatorStyle = .none

        let splitViewController = CardsSplitViewController()
        splitViewController.splitView = SeamlessSplitView()
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)
        // A new name: the old one saved three columns' dividers, and replaying them onto two
        // would size the sidebar from the inspector's divider. Only the first window saves it,
        // the same as its frame.
        if savesLayout { splitViewController.splitView.autosaveName = "TermioContentSplit.cards" }
        // After the items, never before: reading `view` loads the controller, and a split
        // controller loaded with no items set up an empty split view and threw from AppKit's
        // constraint pass — a crash at launch.
        backdrop = WindowBackdrop.install(under: splitViewController.view)
        navigatorToggle = NavigatorToggleOverlay(over: splitViewController.view, store: store, context: context)
        self.splitViewController = splitViewController
        return splitViewController
    }

    /// Keeps the native window title in step with the selected session's working directory.
    /// The title is hidden (`titleVisibility = .hidden`), and each pane's card
    /// header names its own folder and branch, so this only feeds the Window menu and Mission
    /// Control. The path is the
    /// session's real working directory, so a worktree session shows where it actually runs.
    private func updateWindowTitle() {
        guard let id = context.selectedSessionID,
              let folder = store.titleFolder(for: id) else {
            window.title = "Termio"
            window.subtitle = ""
            return
        }
        window.title = abbreviatingHome(folder)
        // Deliberately no machine here. `subtitle` renders beside the title in
        // the titlebar, so naming the device put it in two places at once — the
        // sidebar already says which machine you are on, and repeating it above
        // the terminal read as clutter rather than as reassurance.
        window.subtitle = ""
    }

    /// Home-abbreviates an absolute path to `~`, matching how a shell prompt shows it.
    private func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }


    /// Makes the window non-opaque (so a translucent terminal background reveals
    /// the desktop and Ghostty's blur can take effect) only when the user has
    /// actually dialed opacity below full; at full opacity the window takes the
    /// terminal's own background so the transparent title bar sits flush with the
    /// terminal instead of showing the system window grey. Re-run on every settings
    /// change, so the title bar tracks the terminal theme live.
    private func applyWindowTransparency() {
        let translucent = settings.isBackgroundTranslucent
        window.isOpaque = !translucent
        // Resolve the terminal background to a *static* color for the window's current
        // appearance, rather than handing the window the dynamic (appearance-resolving) color.
        // In fullscreen the title-bar overlay draws in a light appearance context that does not
        // inherit the window's dark appearance, so the dynamic color resolved to white there —
        // the white title band over the terminal. A statically-resolved color can't flip, so the
        // fullscreen title band matches the terminal. Re-run on every appearance change below.
        window.backgroundColor = translucent ? .clear : resolvedTerminalBackground()
        // The ground the cards sit on, as translucent as the terminal when that is.
        let panel = resolved(settings.panelBackgroundColor)
        backdrop?.paint(translucent ? panel.withAlphaComponent(CGFloat(settings.backgroundOpacity)) : panel)
        // Make the titlebar transparent so the window background (the terminal color, set
        // just above) shows straight through the title-bar band instead of AppKit's stock
        // grey chrome material — the seam that otherwise leaves the title/subtitle sitting
        // on a mismatched lighter band. The sidebar's vibrant material still wins on the
        // leading column; this only affects the detail (terminal) side.
        //
        // EXCEPT in fullscreen: on macOS 26 the fullscreen title-bar host doesn't honor a
        // transparent titlebar — it composites a light Liquid Glass material, which read as a
        // white band over a dark terminal. Turning transparency off in fullscreen lets the
        // titlebar the pointer summons fall back to the window's own (dark) titlebar material, which tracks the
        // appearance and matches the terminal far better. Windowed keeps the seamless look.
        window.titlebarAppearsTransparent = !window.styleMask.contains(.fullScreen)
    }

    /// The terminal background color flattened to a static color for the window's current
    /// effective appearance. `AppSettings.terminalBackgroundColor` is a dynamic color that picks
    /// light/dark per drawing context; the window (and especially its fullscreen title-bar
    /// overlay) needs a fixed color so it can't resolve to the wrong side.
    private func resolvedTerminalBackground() -> NSColor {
        resolved(settings.terminalBackgroundColor)
    }

    /// `dynamic` flattened to a static color for the appearance the window is pinned to.
    private func resolved(_ dynamic: NSColor) -> NSColor {
        // Resolve against the appearance the window is pinned to (not its current
        // `effectiveAppearance`, which can lag `applyChromeAppearance` depending on call order).
        let appearance: NSAppearance
        switch settings.appearanceMode {
        case .light: appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        case .dark: appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        case .system: appearance = window.effectiveAppearance
        }
        var resolved = dynamic
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: dynamic.cgColor) ?? dynamic
        }
        return resolved
    }

    /// Drop titlebar transparency *before* the enter-fullscreen animation begins. `applyWindow-
    /// Transparency` keys off `styleMask.contains(.fullScreen)`, which isn't set yet at this point,
    /// so it's set directly here. Without this, the still-transparent titlebar flashes the macOS 26
    /// light fullscreen material (a white band) for the duration of the animation until
    /// `windowDidEnterFullScreen` corrects it.
    func windowWillEnterFullScreen(_ notification: Notification) {
        window.titlebarAppearsTransparent = false
        // Flip before the animation, so a maximized detail's header drops its traffic-light gap
        // as the window grows rather than snapping inward once it lands.
        setFullScreen(true)
    }

    /// The twin of `windowWillEnterFullScreen` for the maximized detail's header: the buttons come
    /// back with the window, so the gap that clears them is restored before the animation ends.
    func windowWillExitFullScreen(_ notification: Notification) {
        setFullScreen(false)
    }

    /// Re-assert the terminal-colored chrome when crossing the fullscreen boundary. macOS rebuilds
    /// the title-bar host on each transition, so the window background/appearance are re-applied to
    /// keep the fullscreen title band matching the terminal. (On enter, transparency was already
    /// dropped in `windowWillEnterFullScreen`; this confirms the rest of the chrome.)
    func windowDidEnterFullScreen(_ notification: Notification) {
        window.appearance = NSApp.appearance
        applyWindowTransparency()
        setFullScreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window.appearance = NSApp.appearance
        applyWindowTransparency()
        setFullScreen(false)
        trafficLights?.place()
    }

    func windowDidResize(_ notification: Notification) {
        trafficLights?.place()
    }

    /// The AppKit half of the container trace installed in
    /// `makeContentSplitViewController`.
    private func logTerminalContainerBounds() {
        guard let size = terminalContainerView?.bounds.size else { return }
        Log.termiod.info("resize-trace container appkit=\(size.width, privacy: .public)x\(size.height, privacy: .public)")
    }

    /// Tells the viewport scheduler that this relayout is a person dragging the
    /// sidebar or inspector divider, so the sessions it resizes stream at the
    /// drag cadence instead of waiting out the 400ms animation debounce — the
    /// "the terminal only reflows after I let go" report.
    ///
    /// The classification is the pointer, not `NSSplitViewDividerIndex`. That
    /// key looks like the right answer and is not: `NSSplitView.h` records that
    /// since macOS 12 AppKit ships the user-info dictionary "during resize and
    /// layout events as well", so its presence stopped meaning a drag. Nor is
    /// a pressed mouse button enough on its own — clicking the sidebar toggle
    /// starts exactly the layout animation the debounce exists to protect,
    /// with the button still down. Button *and* pointer-on-a-divider is the
    /// pair that separates them.
    ///
    /// Ended by a settle timer rather than a mouse-up: `NSSplitView` tracks a
    /// divider drag in its own event loop, which may swallow the release before
    /// a monitor sees it. No further notification is the reliable end signal.
    private func noteSplitViewResize() {
        guard let splitView = splitViewController?.splitView,
              isPointerOnDivider(of: splitView) else { return }
        if !splitDividerDragActive {
            splitDividerDragActive = true
            GeometryDragTracker.shared.beginDrag()
        }
        splitDividerDragSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.splitDividerDragActive else { return }
                self.splitDividerDragActive = false
                GeometryDragTracker.shared.endDrag()
                // The stream leads, so the last size of the drag is still on a
                // timer when the hand comes off. Send it now.
                self.store.flushViewports()
            }
        }
        splitDividerDragSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Whether the primary button is down with the pointer over one of this
    /// split view's dividers. The slop matches AppKit's own divider hit area,
    /// which is wider than the drawn line.
    private func isPointerOnDivider(of splitView: NSSplitView) -> Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0, let window = splitView.window else {
            return false
        }
        let panes = splitView.arrangedSubviews
        guard panes.count > 1 else { return false }
        let local = splitView.convert(
            window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let slop: CGFloat = 4
        let thickness = splitView.dividerThickness + 2 * slop
        for index in 0..<(panes.count - 1) {
            let leading = panes[index].frame
            let rect = splitView.isVertical
                ? NSRect(x: leading.maxX - slop, y: splitView.bounds.minY,
                         width: thickness, height: splitView.bounds.height)
                : NSRect(x: splitView.bounds.minX, y: leading.maxY - slop,
                         width: splitView.bounds.width, height: thickness)
            if rect.contains(local) { return true }
        }
        return false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        // Restoring from the Dock can bring the window back under its content minimum, and leaves a
        // tickless terminal surface (and a mid-load WKWebView in the Issues pane) unpainted — the
        // "minimize while a GitHub issue loads → tiny + black" report. Clamp a shrunken frame back
        // up (setFrame ignores contentMinSize), force a relayout, and nudge the surface to repaint.
        let minFrameHeight = window.frameRect(forContentRect:
            NSRect(origin: .zero, size: window.contentMinSize)).height
        if window.frame.height < minFrameHeight {
            var frame = window.frame
            frame.origin.y -= (minFrameHeight - frame.height)   // grow from the top, keep it fixed
            frame.size.height = minFrameHeight
            window.setFrame(frame, display: true)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if context.isActive { store.repaintSelectedSurface() }
    }

    /// Hides or shows the sidebar. Its own action rather than `NSSplitViewController.toggleSidebar(_:)`,
    /// which only acts on an item with the `.sidebar` behaviour.
    ///
    /// One motion on one clock. The column slides (its content held at full width, so it moves
    /// rather than squeezes), and the card's title and margin ease over on the same curve. The
    /// toggle itself never moves: it floats over both rows (`NavigatorToggleOverlay`).
    @objc func toggleNavigator(_ sender: Any?) {
        guard let item = sidebarSplitItem, !navigatorAnimating else { return }
        let collapsing = !item.isCollapsed
        let duration = Self.navigatorDuration
        navigatorAnimating = true
        sidebarSlide?.holdsWidth = true
        let openPaneMinX = max(sidebarSlide?.restingWidth ?? 0, item.minimumThickness)
            + (splitViewController?.splitView.dividerThickness ?? 0)
        navigatorGeometry.slide = .init(from: navigatorGeometry.paneMinX, to: collapsing ? 0 : openPaneMinX)
        // Both ways on the slide's own clock, not after it: the content's leading inset clears
        // the traffic lights while the sidebar leaves, so nothing slides in under them.
        let curve = Self.navigatorCurve
        withAnimation(.timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: duration)) {
            setSidebarVisible(!collapsing)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1),
                                                           Float(curve.x2), Float(curve.y2))
            item.animator().isCollapsed = collapsing
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.navigatorAnimating = false
                self.sidebarSlide?.holdsWidth = false
                self.navigatorGeometry.slide = nil
                self.setSidebarVisible(self.sidebarSplitItem?.isCollapsed == false)
                // The column has landed, so the terminals' new width is one the user chose. Declare it
                // now: left to the 400ms debounce that keeps layout animations from declaring
                // passing sizes, the shell repainted at the new width ~650ms after the click.
                // Next turn, once SwiftUI has laid the panes out at their final width.
                DispatchQueue.main.async { self.store.flushViewports() }
            }
        })
    }

    /// Brings the window into or out of the maximized-detail mode. Idempotent, and reached from two
    /// clocks: synchronously as the maximize flag flips (so the host swaps with the docked detail in
    /// one frame) and from the deferred store observer (which catches the detail closing out from
    /// under a host that is already up).
    ///
    /// Moves the shared detail host between the inspector's slot and the whole content area — an
    /// in-window maximize, *not* native macOS fullscreen: the window stays put in its Space and the
    /// menu bar stays visible. The navigator collapses with it, so "fill the window" means the
    /// window rather than the window minus a column of chrome; re-open it (View menu) and the host
    /// slides with it, since its leading edge tracks the split. Restore and close ride the detail's
    /// own header, and Esc still closes.
    ///
    /// The host is *moved*, never rebuilt (see `DetailHost`): each direction is one `addSubview`
    /// that re-parents it inside the same window, so the open document crosses the transition
    /// untouched. No geometry animation, deliberately — the terminal cannot be resized to make
    /// room (a maximized detail covers it so the panes never take a SIGWINCH, see `TerminalPane`),
    /// so this is the same rect change that reads as a zoom for a split pane.
    func setDetailMaximized(_ on: Bool) {
        guard let container = splitViewController?.view, on != detailMaximized else { return }
        detailMaximized = on
        if on {
            let host = DetailHost.shared.view(store: store, settings: settings, window: window)
            NSLayoutConstraint.deactivate(maximizedDetailConstraints)
            host.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host, positioned: .above, relativeTo: nil)
            // Pin the leading edge to the *content* area (the terminal/inspector region), not the
            // whole window — so the maximized detail sits beside the project sidebar rather than
            // swallowing it. Item 1 is the terminal (0 is the sidebar, 2 the inspector); its leading
            // tracks the split, so toggling the sidebar slides the maximized detail with it (it
            // extends left when the sidebar collapses).
            let items = splitViewController?.splitViewItems ?? []
            let contentLeading = items.count > 1
                ? items[1].viewController.view.leadingAnchor
                : container.leadingAnchor
            maximizedDetailConstraints = [
                host.leadingAnchor.constraint(equalTo: contentLeading),
                host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.topAnchor.constraint(equalTo: container.topAnchor),
                host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ]
            NSLayoutConstraint.activate(maximizedDetailConstraints)
            // "Fill the window" means the whole window: the navigator steps aside and comes back on
            // restore. Leaving it up would keep a column of chrome beside a detail the user just
            // asked to blow up.
            if sidebarSplitItem?.isCollapsed == false {
                sidebarCollapsedForMaximize = true
                sidebarSplitItem?.isCollapsed = true
            }
        } else {
            // Retire them here rather than trusting the re-parent to reap them: `removeFromSuperview`
            // only drops constraints the old ancestor held, and the host does not always leave
            // through that door — a detail closed while maximized is discarded where it stands. A
            // set left active outlives the cycle that made it, and the next maximize activates a
            // second one against the same host: auto layout then breaks whichever it likes, and a
            // broken trailing edge is a detail that stops at the terminal instead of filling the
            // window.
            NSLayoutConstraint.deactivate(maximizedDetailConstraints)
            maximizedDetailConstraints = []
            // Straight back into the inspector's slot, which stayed mounted for exactly this.
            // Without one — the detail closed while maximized — there is nowhere to go and the
            // host is on its way out anyway (see the `isDetailPresented` half of the observer).
            if let slot = DetailHost.shared.dockedSlot {
                DetailHost.shared.dock(in: slot)
            } else {
                DetailHost.shared.view?.removeFromSuperview()
            }
            // Only re-open what maximizing closed. A sidebar the user collapsed themselves — before
            // maximizing, or while the detail was up — stays collapsed.
            if sidebarCollapsedForMaximize {
                sidebarCollapsedForMaximize = false
                sidebarSplitItem?.isCollapsed = false
            }
            // Uncovering the content area re-exposes the terminal, but a tickless surface won't
            // repaint itself — nudge it so a switch out of a maximized detail can't leave a blank.
            store.repaintSelectedSurface()
        }
    }
}
