import AppKit
import Combine
import GhosttyTerminal
import Sparkle
import SwiftUI
import TermioShared

/// AppKit bootstrap. We drive `NSApplication` directly (rather than the SwiftUI
/// `App` lifecycle) so a plain SwiftPM executable launches as a real foreground
/// app — `.regular` activation policy plus an explicit activate — and hosts the
/// SwiftUI tree in a window. This keeps key/focus handling reliable for the
/// terminal surface without needing an Xcode app bundle.
@main
enum Termio {
    @MainActor
    static func main() {
        // First line of Swift in the process: stamps the launch timeline, whose
        // zero is `exec` (see `LaunchTrace`).
        LaunchTrace.mark("main")
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.mainMenu = buildMainMenu()
        application.activate(ignoringOtherApps: true)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// The main window's frame-autosave name, doubling as its identity for observers
    /// elsewhere in the app (`TerminalPane` filters key-window notifications with it,
    /// so the settings window never triggers the terminal refocus rescue).
    static let mainWindowFrameAutosaveName = "TermioMainWindow"
    /// The main window, resolved by that autosave name — for code that can't hold
    /// the delegate's own reference (the store's reveal verb, pane focus rescue).
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == mainWindowFrameAutosaveName }
    }
    private var window: NSWindow!
    private let settings = AppSettings()
    private lazy var store = TermioStore.restored(settings: settings)
    private lazy var usageMonitor = UsageMonitor(settings: settings)
    private var menuBar: MenuBarController?
    /// Rebuilds the main menu when the user rebinds a shortcut in Settings.
    private var keybindingsObserver: NSObjectProtocol?
    private var companionServer: CompanionServer?
    /// The other half of what this Mac serves a phone: the session protocol,
    /// spliced onto the daemon. Exactly one of the two ever runs — see
    /// `MobileAccess.attachesDirectly`.
    private var deviceSpliceServer: DeviceSpliceServer?
    private var settingsWindow: NSWindow?
    private var settingsObserver: AnyCancellable?
    /// Starts/stops the companion server + tunnel as the Mobile Access toggle flips.
    private var mobileAccessObserver: AnyCancellable?
    private var unpairObserver: AnyCancellable?
    private var attachModeObserver: AnyCancellable?
    // Drives in-app auto-update. Started only in release builds — a debug build has
    // no Developer-ID signature for Sparkle to validate the appcast's EdDSA against,
    // and we don't want dev runs phoning the update feed. The feed URL and public
    // key live in packaging/Info.plist (SUFeedURL / SUPublicEDKey).
    #if DEBUG
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    #else
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    // Folders handed to us by the `termio` CLI (via `open -b sh.termio.app <dir>`)
    // before the window exists, replayed once it does. macOS may deliver the open
    // event during a cold launch, ahead of `applicationDidFinishLaunching`.
    private var pendingOpenURLs: [URL] = []
    // The split controller (sidebar + terminal + inspector) — a weak handle on the window's
    // content view controller.
    private weak var splitViewController: NSSplitViewController?
    // The inspector, owned here and mounted in the focused card's panel (see `InspectorPanelHost`).
    private var inspectorController: FileBrowserHostingController?
    // The leading sidebar item, retained so a maximized detail can put it away and bring it back.
    private weak var sidebarSplitItem: NSSplitViewItem?
    // KVO on the sidebar's collapse state, mirrored onto `store.sidebarVisible` so the sidebar's
    // controls can move into the top-left card while it is collapsed. Catches every collapse path
    // (the toggle, the View menu, a divider drag).
    private var sidebarCollapseObserver: NSKeyValueObservation?
    // The sidebar's slide container (see `SidebarSlideController`), and whether the toggle's own
    // animation is running — while it is, the toggle owns `store.sidebarVisible`'s timing.
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
    // Manages the maximize host as a detail opens/closes (see the `store.objectWillChange`
    // sink in `applicationDidFinishLaunching`).
    private var overlayObserver: AnyCancellable?
    // Drives the same host straight off the maximize flag, synchronously (see
    // `store.inspectorMaximizedDidChange`), so the handoff to and from the full-window
    // position lands in the frame the flag flips in.
    private var maximizeObserver: AnyCancellable?
    // Un-collapses the inspector when the user opens a detail (see `store.detailDidOpen`).
    private var detailOpenObserver: AnyCancellable?
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
    // The floating panel shared by ⌘⇧O Open Quickly and ⌘⇧P Command Palette.
    // Presented as a child window (Xcode Open-Quickly style) because the
    // terminal surfaces are NSViews that draw above any SwiftUI overlay in the
    // hosting view — an in-tree palette is covered by the very terminals it
    // commands. `store.paletteMode` stays the single source of truth; this
    // observer materializes it.
    private var palettePanel: NSPanel?
    private var paletteObserver: AnyCancellable?
    private var paletteResignObserver: NSObjectProtocol?
    // The ghostty-style right-click menu over the terminal surfaces (Copy/Paste + splits);
    // owns the rightMouseDown monitor for the app's lifetime.
    private var terminalContextMenu: TerminalContextMenu?
    private var pasteInterceptor: TermiodPasteInterceptor?
    // The pane drag-to-rearrange gesture (issue #183); owns its
    // mouse monitors for the app's lifetime.
    private var paneDragRearrange: PaneDragRearrange?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("delegate ready")
        // Dev-only: `TERMIO_TERMINAL_DEBUG=1` turns on the GhosttyTerminal
        // wrapper's own lifecycle + metrics diagnostics, printed to stdout.
        if AppChannel.isDev,
           ProcessInfo.processInfo.environment["TERMIO_TERMINAL_DEBUG"] != nil {
            TerminalDebugLog.isEnabled = true
            TerminalDebugLog.categories = [.lifecycle, .metrics]
        }
        // Dev-only: focus-independent window snapshot for automated UI debugging
        // (see DebugWindowSnapshot).
        if AppChannel.isDev { DebugWindowSnapshot.installTrigger() }
        // Sweep up session processes a previous instance stranded (crash,
        // force-quit, dev rebuild's kill -9) before this run adds its own.
        StraySessionReaper.reapStrayOrphans()
        // The daemon on this Mac outlives the app, so an update leaves the old
        // process running until something asks it to take on the new binary.
        // Here — before the first control channel opens and long before a pane
        // attaches — is the only moment that costs nobody their session. The
        // probe can block behind a wedged daemon, so it must never delay making
        // the first window.
        DispatchQueue.global(qos: .utility).async {
            TermioStore.reconcileLocalDaemon()
        }
        store.refreshDeviceSessions()
        LaunchTrace.mark("store restored")
        // Task-completion notifications: the delegate must be installed before a
        // notification click can arrive, so wire it before any session runs.
        TaskNotificationCenter.shared.activate(store: store)
        // Count this install as active today, and keep counting across midnight
        // for a Mac that is left running (see `Analytics`).
        Analytics.start(settings: settings)
        // Menu items cache their key equivalents at build time, so rebuild the
        // whole main menu whenever a user rebinds a shortcut in Settings.
        keybindingsObserver = NotificationCenter.default.addObserver(
            forName: .termioKeybindingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                NSApp.mainMenu = buildMainMenu()
                // Open surfaces carry the old unbind set, so a shortcut moved onto
                // a ghostty-bound key would be swallowed until relaunch.
                self?.store.applyAppearanceToOpenSurfaces()
            }
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Termio"
        // Closing the window no longer quits (see `applicationShouldTerminate-
        // AfterLastWindowClosed`), so the window object has to survive its own close:
        // the terminal surfaces live in its view tree, and a Dock reopen re-shows this
        // very window rather than rebuilding one. The default `true` would also
        // over-release it out from under the strong reference held here.
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
        window.contentViewController = makeContentSplitViewController()
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
        window.center()
        window.setFrameAutosaveName(Self.mainWindowFrameAutosaveName)
        window.makeKeyAndOrderFront(nil)
        trafficLights = TrafficLights(window: window)
        navigatorToggle?.follow(window, store: store)
        LaunchTrace.mark("window front")
        applyWindowTransparency()
        applyChromeAppearance()
        // The autosaved frame can restore straight into fullscreen, so seed the mirror rather
        // than waiting for a transition that already happened.
        store.windowIsFullScreen = window.styleMask.contains(.fullScreen)
        // No `.initial`: the launch-time sync below runs after the autosave restore.
        sidebarCollapseObserver = sidebarSplitItem?.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            MainActor.assumeIsolated {
                // The toggle's animation sets this on its own clock (`toggleNavigator`); every
                // other path — a divider dragged shut, a maximized detail — lands here.
                guard let self, !self.navigatorAnimating else { return }
                self.store.sidebarVisible = !collapsed
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
        appearanceObserver = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyWindowTransparency() }
        }
        // After the split view has restored its autosaved collapse state.
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.sidebarSplitItem else { return }
            self.store.sidebarVisible = !item.isCollapsed
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

        // The user opening a detail (a file, a diff, a PR row) is the only thing that
        // un-collapses the inspector — the store raises it as an event rather than the delegate
        // inferring it from `isDetailPresented`, which also goes true when a session switch or a
        // launch restore puts a saved detail back and must not move the panel (issue #272).
        // Delivered on the next runloop so the split geometry the separator binds to is settled.
        detailOpenObserver = store.detailDidOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.revealInspectorForDetail() }
            }

        // The maximize button itself: applied synchronously, in the same turn the flag flips, so
        // the full-window host is already up when SwiftUI drops the inspector's docked copy. Going
        // through `objectWillChange` below instead would land a runloop late, and the inspector's
        // always-mounted file tree — normally covered by the detail — showed through the gap.
        maximizeObserver = store.inspectorMaximizedDidChange
            .sink { [weak self] maximized in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyDetailMaximized(maximized && self.store.isDetailPresented)
                }
            }

        // A detail (file editor, diff, PR/issue) opens in the right inspector, beside the
        // terminal. Its own window controls (hide list / maximize / close) live *in* the detail's
        // header now (see `InspectorDetailChromeButtons`) — so this observer only
        // moves the shared host and drops it once nothing is open. It catches the presentation half
        // of the state (a detail closing out from under a maximized host); the flag's own half is
        // the synchronous observer above.
        // `objectWillChange` fires before the value lands, so read the settled state next runloop.
        overlayObserver = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyDetailMaximized(self.store.inspectorMaximized && self.store.isDetailPresented)
                    // Nothing left to render: let the host go rather than keep a document's editor
                    // (and its web view) alive behind a closed inspector.
                    if !self.store.isDetailPresented { DetailHost.shared.discard() }
                }
            }

        // Background opacity/blur only show through a non-opaque window, and the
        // window's light/dark appearance follows the selected theme, so both track
        // the settings. `objectWillChange` fires before the value lands, hence the
        // next-tick hop (mirrors the store's re-style observer).
        settingsObserver = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyWindowTransparency()
                self?.applyChromeAppearance()
            }

        // Materialize the palette mode as a floating panel. Mapping to shown/
        // hidden lets a mode *switch* (⌘⇧O while the ⌘⇧P palette is up) reuse
        // the live panel — the SwiftUI view tracks `paletteMode` itself; the
        // dedupe keeps the dismiss-path (panel close → nil → sink) from
        // re-entering.
        paletteObserver = store.$paletteMode
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] shown in
                MainActor.assumeIsolated {
                    if shown { self?.presentCommandPalette() } else { self?.dismissCommandPalette() }
                }
            }

        // Installed before the context menu so the menu can hand its Paste to
        // the same interceptor rather than growing a second copy of the rule.
        pasteInterceptor = TermiodPasteInterceptor(store: store)
        terminalContextMenu = TerminalContextMenu(store: store, pasteInterceptor: pasteInterceptor)
        paneDragRearrange = PaneDragRearrange(store: store)

        menuBar = MenuBarController(store: store) { [weak self] id in
            // The tray's "come look at this" — same verb as a notification click
            // and `termio sessions focus` (select + acknowledge + raise).
            self?.store.revealSession(id)
        }

        // Serve the iOS companion app: the live roster, plus PTY bridging for
        // any session the phone attaches to. Bound to localhost; a tunnel
        // fronts it for remote use.
        let companion = CompanionServer(
            rosterProvider: { [weak store] in
                store?.companionRoster() ?? CompanionRoster(projects: [])
            },
            attachSession: { [weak store] id in
                store?.companionAttachment(for: id)
            },
            startSession: { [weak store] projectID, agent in
                store?.companionStartSession(projectID: projectID, agent: agent)
            },
            stopSession: { [weak store] sessionID in
                store?.companionStopSession(sessionID: sessionID) ?? false
            },
            startScratchTerminal: { [weak store] workspaceID in
                store?.companionStartScratchTerminal(workspaceID: workspaceID)
            },
            startSSHSession: { [weak store] host, workspaceID in
                store?.companionStartSSHSession(host: host, workspaceID: workspaceID)
            }
        )
        companionServer = companion
        // Serving and publishing are one decision, so they fail as one: a
        // second instance that loses the race for the port must not leave a
        // public URL pointing at it.
        companion.onListenerFailed = {
            Log.companion.error("not serving — taking the public tunnel down")
            TunnelManager.shared.suspend()
        }
        // Mobile Access is the master switch: only serve (and resume the public
        // tunnel) when it's on. The token gate in the server is what makes
        // fronting it with a tunnel safe.
        let splice = DeviceSpliceServer()
        deviceSpliceServer = splice
        splice.onListenerFailed = {
            Log.companion.error("device splice not serving — taking the public tunnel down")
            TunnelManager.shared.suspend()
        }

        if MobileAccess.shared.isEnabled {
            startServing()
            TunnelManager.shared.startIfEnabled()
        }
        // React to the Settings toggle. `dropFirst` skips the value already
        // handled by the launch branch above, so we never double-start.
        // Unpair is decided in Settings, which holds no store; the live links it
        // must end are here.
        unpairObserver = NotificationCenter.default.publisher(for: PairedDeviceStore.didChange)
            .compactMap { $0.userInfo?[PairedDeviceStore.unpairedHostIDKey] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hostID in self?.store.disconnectPaired(hostID: hostID) }
        mobileAccessObserver = MobileAccess.shared.$isEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled {
                    self?.startServing()
                    TunnelManager.shared.startIfEnabled()
                } else {
                    // Fully dark: drop live phones and kill the public URL.
                    self?.stopServing()
                    TunnelManager.shared.suspend()
                }
            }
        // Which server answers is one decision with two consequences — the port
        // the phone dials and the port the tunnel fronts — so the swap and the
        // tunnel restart happen together or the published URL points at a port
        // nothing answers on.
        attachModeObserver = MobileAccess.shared.$attachesDirectly
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard MobileAccess.shared.isEnabled else { return }
                self?.stopServing()
                self?.startServing()
                TunnelManager.shared.restartIfRunning()
            }

        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            openProjects(at: urls)
        }

        maybePromptForSessionControl()
        LaunchTrace.mark("launched")
        LaunchTrace.whenLaunchSettles {}
    }

    /// Start whichever server the Mobile pane's Direct Attach switch selects.
    /// Exactly one: a Mac answering on both ports would be telling a phone two
    /// different stories about where its sessions live.
    private func startServing() {
        if MobileAccess.shared.attachesDirectly {
            deviceSpliceServer?.start()
        } else {
            companionServer?.start()
        }
    }

    /// Stop both, unconditionally. The switch may already have moved by the time
    /// this runs, and stopping only the server the *current* value names would
    /// leave the other one holding its port.
    private func stopServing() {
        companionServer?.stop()
        deviceSpliceServer?.stop()
    }

    /// A one-time, first-run offer to let agents coordinate. Enabling session control
    /// edits the user's global agent config (a `CLAUDE.md` note + status hooks), so we
    /// ask once rather than turn it on silently. Deferred a beat so it sheets onto a
    /// settled window. Shown only when never asked and not already on; either choice
    /// records that we've asked, so it never nags again.
    private func maybePromptForSessionControl() {
        guard !settings.sessionControlPrompted, !settings.sessionControlEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = localized("Let your agents coordinate?")
            alert.informativeText = localized("""
                termio can teach the agents you run (Claude Code, Codex, …) a `termio \
                sessions` command so they can see, drive, and read each other's sessions \
                in a project.

                Enabling adds a short note to your ~/.claude/CLAUDE.md and installs \
                status hooks. You can turn it off anytime in Settings ▸ Agents.
                """)
            alert.addButton(withTitle: localized("Enable"))
            alert.addButton(withTitle: localized("Not Now"))
            settings.sessionControlPrompted = true
            if alert.runModal() == .alertFirstButtonReturn {
                settings.sessionControlEnabled = true
            }
        }
    }

    /// termio is single-window, so terminating with the last window would make ⌘W a
    /// quit. Quitting no longer ends anything — the daemon owns the PTYs and keeps
    /// them (see `applicationWillTerminate`) — but it does tear down the mounted
    /// surfaces and stop the banners, so the app stays running with its window closed
    /// and the Dock icon brings it back (see `applicationShouldHandleReopen`). ⌘W ends
    /// the session it is aimed at, which is still the only verb that ends one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Coming back to the app is the retry a failed roster never had. A machine
    /// that refused while the user was away — asleep laptop, network change, an
    /// ssh problem they just went and fixed — stayed refused on screen until
    /// something else happened to re-ask (issue #498: the only manual path was
    /// switching devices). Scoped to the failed state on another machine, so
    /// ordinary app switching never spawns an ssh.
    func applicationDidBecomeActive(_ notification: Notification) {
        if case .failed = store.deviceSessions, !store.currentDevice.isLocal {
            store.refreshDeviceSessions()
        }
    }

    /// Dock click (or `open -b sh.termio.app`) with the window closed. The window
    /// survived its close, so it is re-shown rather than rebuilt — the sessions kept
    /// running in its view tree the whole time.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    /// Brings the main window back and repaints the terminal it reveals: a surface that
    /// spent time off-screen stops ticking and comes back unpainted until the next
    /// keystroke (the same rescue `windowDidDeminiaturize` applies).
    private func showMainWindow() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        store.repaintSelectedSurface()
    }

    /// Quitting detaches; it does not end a session. The daemon owns every PTY and
    /// outlives the app (`TermiodClient.spawnDaemon` gives it its own session), so a
    /// working agent keeps working and the next launch reattaches to it. What has to
    /// happen here is the bookkeeping only the running app holds.
    /// Only a real quit reaches here; closing the window does not.
    func applicationWillTerminate(_ notification: Notification) {
        // A delivered banner taps back into a window that is going away.
        TaskNotificationCenter.shared.withdrawAll()
        // Tree edits are debounced (see `persistSoon`), so flush before the
        // process goes away or the last selection change is lost.
        store.persistNow()
        store.detachAllSessions()
        RemotePreviewStorage.cleanup()
    }

    /// Builds the window's content: an `NSSplitViewController` with the sidebar, the terminal pane
    /// and the inspector, each hosting its SwiftUI view. `toggleNavigator(_:)` collapses the
    /// sidebar item.
    private func makeContentSplitViewController() -> NSSplitViewController {
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
        // No inspector column: each card opens the inspector in its own panel. One controller
        // serves them all, mounted in whichever card has focus.
        let inspector = FileBrowserHostingController(store: store, settings: settings)
        inspectorController = inspector
        InspectorPanelHost.shared.controller = inspector
        // A new name: the old one saved three columns' dividers, and replaying them onto two
        // would size the sidebar from the inspector's divider.
        splitViewController.splitView.autosaveName = "TermioContentSplit.cards"
        // After the items, never before: reading `view` loads the controller, and a split
        // controller loaded with no items set up an empty split view and threw from AppKit's
        // constraint pass — a crash at launch.
        backdrop = WindowBackdrop.install(under: splitViewController.view)
        navigatorToggle = NavigatorToggleOverlay(over: splitViewController.view, store: store)
        self.splitViewController = splitViewController
        return splitViewController
    }

    /// Keeps the native window title in step with the selected session's working directory.
    /// The title is hidden (`titleVisibility = .hidden`), and each pane's card
    /// header names its own folder and branch, so this only feeds the Window menu and Mission
    /// Control. The path is the
    /// session's real working directory, so a worktree session shows where it actually runs.
    private func updateWindowTitle() {
        guard let window else { return }
        guard let id = store.selectedSessionID,
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

    /// Entry point for the `termio` CLI and for session deep links: macOS
    /// delivers both the folder passed to `open -b sh.termio.app <dir>` and any
    /// clicked `termio://` link here. Because termio is single-instance, an
    /// already-running app receives this in place, so the project opens in the
    /// existing window rather than spawning a second one.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == AppChannel.urlScheme {
            store.openSessionLink(url)
        }
        let directories = urls.filter { $0.scheme != AppChannel.urlScheme }
        if !directories.isEmpty { openProjects(at: directories) }
    }

    /// Adds each directory as a project in the one shared store and brings the
    /// window forward. Called before the window exists buffers into `pendingOpenURLs`.
    private func openProjects(at urls: [URL]) {
        guard window != nil else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        let directories = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !directories.isEmpty else { return }
        for url in directories {
            store.addProject(at: url)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Makes the window non-opaque (so a translucent terminal background reveals
    /// the desktop and Ghostty's blur can take effect) only when the user has
    /// actually dialed opacity below full; at full opacity the window takes the
    /// terminal's own background so the transparent title bar sits flush with the
    /// terminal instead of showing the system window grey. Re-run on every settings
    /// change, so the title bar tracks the terminal theme live.
    private func applyWindowTransparency() {
        guard let window else { return }
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
        case .system: appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
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
        window?.titlebarAppearsTransparent = false
        // Flip before the animation, so a maximized detail's header drops its traffic-light gap
        // as the window grows rather than snapping inward once it lands.
        store.windowIsFullScreen = true
    }

    /// The twin of `windowWillEnterFullScreen` for the maximized detail's header: the buttons come
    /// back with the window, so the gap that clears them is restored before the animation ends.
    func windowWillExitFullScreen(_ notification: Notification) {
        store.windowIsFullScreen = false
    }

    /// Re-assert the terminal-colored chrome when crossing the fullscreen boundary. macOS rebuilds
    /// the title-bar host on each transition, so the window background/appearance are re-applied to
    /// keep the fullscreen title band matching the terminal. (On enter, transparency was already
    /// dropped in `windowWillEnterFullScreen`; this confirms the rest of the chrome.)
    func windowDidEnterFullScreen(_ notification: Notification) {
        applyChromeAppearance()
        applyWindowTransparency()
        store.windowIsFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        applyChromeAppearance()
        applyWindowTransparency()
        store.windowIsFullScreen = false
        trafficLights?.place()
    }

    /// View ▸ Toggle Full Screen (⌃⌘F).
    ///
    /// macOS moved its own full-screen shortcut to globe-F in Monterey and pins
    /// that onto the Enter/Exit Full Screen item AppKit inserts — so ⌃⌘F, what a
    /// decade of Mac apps taught and what ghostty binds, reaches nothing. This is
    /// ghostty's own answer, verbatim: an item AppKit will not take over, which
    /// means neither the reserved titles nor `NSWindow.toggleFullScreen(_:)`
    /// (ghostty ships "Toggle Full Screen" on `toggleGhosttyFullScreen:`).
    /// Ghostty's binding on the same key is unbound inside the surface (see
    /// `applyAppearance`), or the terminal would swallow it first.
    @objc func toggleFullScreenCommand(_ sender: Any?) {
        (window ?? Self.mainWindow)?.toggleFullScreen(nil)
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
        guard let window else { return }
        let minFrameHeight = window.frameRect(forContentRect:
            NSRect(origin: .zero, size: window.contentMinSize)).height
        if window.frame.height < minFrameHeight {
            var frame = window.frame
            frame.origin.y -= (minFrameHeight - frame.height)   // grow from the top, keep it fixed
            frame.size.height = minFrameHeight
            window.setFrame(frame, display: true)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        store.repaintSelectedSurface()
    }

    /// Applies the user's appearance mode. `.system` leaves every surface tracking
    /// the OS (termio keeps a separate terminal theme per appearance, and libghostty
    /// switches between them in step); `.light`/`.dark` pin a fixed `NSAppearance`
    /// app-wide, which the title bar, traffic lights, scrollbars, and the terminal's
    /// effective appearance (hence its light/dark theme) all follow together.
    private func applyChromeAppearance() {
        let appearance: NSAppearance?
        switch settings.appearanceMode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
        window?.appearance = appearance
        settingsWindow?.appearance = appearance
    }

    /// Opens (or refocuses) the preferences window. Reached via the responder
    /// chain from the menu item, which targets `nil`. The window is kept alive
    /// (not released on close) so reopening preserves nothing-to-rebuild state.
    /// ⌘, lands on whatever tab the user last had open (the platform convention
    /// — Safari, Xcode), falling back to the first tab on a fresh install;
    /// deep-linked opens (`openSettings(initialTab:)`) still pick their own.
    @objc func showSettings(_ sender: Any?) {
        // "mobile" was a tab of its own; its controls now live in Server.
        let remembered = UserDefaults.standard.string(forKey: SettingsTab.lastOpenKey)
            .flatMap { $0 == "mobile" ? .server : SettingsTab(rawValue: $0) }
        openSettings(initialTab: remembered ?? .general)
    }

    /// Opens the pairing QR (RFC §D9) from the menu bar or the command palette.
    /// The QR is a sheet over this Mac's Pairing section, so the request waits
    /// for that section to come on screen and open it.
    @objc func pairPhone(_ sender: Any?) {
        PairingModel.shared.showsSheet = true
        openSettings(initialTab: .server)
    }

    /// Opens (or refocuses) the preferences window on a specific tab. The content
    /// view is rebuilt each call so the requested tab takes effect even when the
    /// window is reused — harmless because every control binds straight to
    /// `AppSettings`, so there is no transient UI state to preserve.
    func openSettings(initialTab: SettingsTab) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = localized("Settings")
            // System Settings–style chrome: a unified toolbar carries the sidebar
            // separator and the detail pane's title/subtitle. The window is
            // resizable so short panes don't force a fixed slab of empty space.
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false

            let minSize = NSSize(width: 640, height: 480)
            window.minSize = minSize
            window.contentMinSize = minSize

            // Remember the user's size/position across launches. The restore path
            // uses setFrame:, which ignores minSize, so clamp any stale tiny frame.
            let restored = window.setFrameAutosaveName("TermioSettingsWindow")
            let frame = window.frame
            if frame.width < minSize.width || frame.height < minSize.height {
                var clamped = frame
                clamped.size.width = max(frame.width, minSize.width)
                clamped.size.height = max(frame.height, minSize.height)
                window.setFrame(clamped, display: false)
            }
            if !restored { window.center() }
            settingsWindow = window
        }
        // `.frame(minWidth:minHeight:)` on the root: NSHostingView forwards the
        // SwiftUI tree's small intrinsic minimum up into contentMinSize, which
        // would otherwise let the window shrink below the size set above.
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(
            settings: settings,
            usage: usageMonitor,
            store: store,
            initialTab: initialTab,
            onSSHConnect: { [weak self] host in
                guard let self else { return }
                // A paired Mac has no ssh to open a shell over; its Connect opens
                // a durable session through its daemon instead.
                if TermiodRoute.isPaired(hostKey: host) {
                    self.store.addRemoteTerminal(host: host)
                } else {
                    self.store.addSSHSession(host: host)
                }
                // The new session is selected in the store; surface the main
                // window over Settings so the connection is immediately visible.
                self.window.makeKeyAndOrderFront(nil)
            },
            onSetUpKey: { [weak self] host, publicKey in
                guard let self else { return }
                self.store.addKeyInstallSession(host: host, publicKey: publicKey)
                // Same reason as above, and more so: this session opens on a
                // password prompt waiting to be answered.
                self.window.makeKeyAndOrderFront(nil)
            },
            onSignIn: { [weak self] title, command in
                guard let self else { return }
                self.store.addOneShotSession(title: title, command: command)
                // The login waits on the user in that terminal; Settings keeps
                // its sheet open and notices the new sign-in on its own.
                self.window.makeKeyAndOrderFront(nil)
            }
        ).frame(minWidth: 640, minHeight: 480))
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// File ▸ Open Project… — opens a project on the machine the current workspace
    /// belongs to: the folder picker here, a path on that box in a workspace that
    /// is a box's (see `presentOpenProjectPanel`). Reached via the responder chain
    /// (the menu item targets `nil`), the same nil-target routing the Settings
    /// item uses.
    @objc func openProject(_ sender: Any?) {
        store.presentOpenProjectPanel()
    }

    /// File ▸ New Terminal (⌘T) — a shell in the focused session's directory, beside
    /// that session (see `addTerminalHere`). Reached via the responder chain (the menu
    /// item targets `nil`), like the other app actions.
    @objc func newTerminalHere(_ sender: Any?) {
        store.addTerminalHere()
    }

    /// New Terminal at Home — the same verb in the File menu and the sidebar's `+`,
    /// always starting at `~` the way a new iTerm2 window does.
    @objc func newScratchTerminal(_ sender: Any?) {
        store.addScratchTerminal()
    }

    /// A row of the New Chat agents submenu (File menu and the sidebar `+` share it —
    /// see `menuNeedsUpdate`) — starts one scratch chat with the picked agent, carried
    /// in `representedObject` by id. The row for the resolved default also holds the
    /// ⌘N binding, so the shortcut keeps opening your last-used agent.
    @objc func newChatAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let agent = enabledAgentPresets(settings).first(where: { $0.id == id })
        else { return }
        store.addScratchSession(agent: agent)
    }

    /// A host row of the New SSH Connection submenu (File menu and the sidebar `+`
    /// share it — see `menuNeedsUpdate`) — opens a terminal running `ssh` to the
    /// picked alias, carried in `representedObject`, grouped under the same
    /// Terminals section as loose shells.
    @objc func newSSHHost(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        store.addSSHSession(host: alias)
    }

    /// A row of the Workspace submenu — the scope the sidebar shows and the panes
    /// follow.
    @objc func switchToWorkspace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw)
        else { return }
        store.switchToWorkspace(id)
    }

    /// "New Workspace…" wherever it stands as a plain verb — the Workspace
    /// submenu's row, the sidebar `+`'s last row — and the This Mac row of the
    /// device submenu those grow on a second machine.
    @objc func newWorkspace(_ sender: Any?) {
        store.presentNewWorkspacePanel(on: .thisMac)
    }

    /// A device row of the New Workspace submenu (File ▸ Workspace and the toolbar
    /// `+` share it — see `refreshNewWorkspaceItem`). Nothing is reached here: a
    /// workspace is a filing scope, so it exists on that machine before anything
    /// has connected to it.
    @objc func newWorkspaceOnDevice(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        store.presentNewWorkspacePanel(on: .ssh(alias: alias))
    }

    /// "Workspace Settings…", from File ▸ Workspace and the sidebar switcher — the
    /// one pane that shows every workspace at once, which is where renaming and
    /// removing one live.
    @objc func openWorkspaceSettings(_ sender: Any?) {
        openSettings(initialTab: .workspaces)
    }

    /// A row of the Connect to… submenu — first contact with a machine from
    /// `~/.ssh/config`. Opening a terminal on it is the connection: `termiod` is
    /// installed there if missing, the handshake records which device the alias
    /// reaches, and the machine becomes the current device, because reaching for a
    /// box is also saying that is where you are about to work.
    @objc func connectToDevice(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        store.switchToWorkspace(store.deviceWorkspace(for: alias))
        store.addRemoteTerminal(host: alias)
    }

    /// The submenu's trailing "Add Host…" row — the same Add Host form Settings ▸
    /// SSH carries, presented as a sheet over the main window, then connecting to
    /// the host it just appended to `~/.ssh/config` (from this menu the point of
    /// adding a machine is to open it). One-off connections that shouldn't touch
    /// the config stay available as the command palette's New SSH Connection.
    @objc func addSSHHost(_ sender: Any?) {
        guard let presenter = window?.contentViewController else { return }
        let hostVC = NSHostingController(rootView: AddSSHHostSheet(
            existingAliases: Set(SSHConfigFile.hosts().map(\.alias))
        ))
        hostVC.rootView.completion = { [weak self, weak presenter, weak hostVC] alias in
            guard let hostVC else { return }
            presenter?.dismiss(hostVC)
            if let alias { self?.store.addSSHSession(host: alias) }
        }
        presenter.presentAsSheet(hostVC)
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
            store.sidebarVisible = !collapsing
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
                self.store.sidebarVisible = self.sidebarSplitItem?.isCollapsed == false
                // The column has landed, so the terminals' new width is one the user chose. Declare it
                // now: left to the 400ms debounce that keeps layout animations from declaring
                // passing sizes, the shell repainted at the new width ~650ms after the click.
                // Next turn, once SwiftUI has laid the panes out at their final width.
                DispatchQueue.main.async { self.store.flushViewports() }
            }
        })
    }

    /// View ▸ Show Project Files (and the card's panel menu) — opens or closes the focused
    /// card's panel. Reached via the responder chain (the menu item and the panel menu both
    /// target `nil`), like the other app actions.
    @objc func toggleFilesInspector(_ sender: Any?) {
        store.inspectorVisible.toggle()
    }

    /// Edit ▸ Paste. File URLs copied in Finder become absolute paths at the
    /// focused terminal; everything else goes down the responder chain as a
    /// normal `paste:`. A distinct selector so forwarding `paste:` cannot
    /// re-enter this method.
    @objc func pasteFromEditMenu(_ sender: Any?) {
        if pasteInterceptor?.pasteIntoFocusedTerminal() == true { return }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    /// ⌘F: broadcast so any on-screen file editor opens its find bar.
    @objc func showEditorFindBar(_ sender: Any?) {
        NotificationCenter.default.post(name: .termioShowFindBar, object: nil)
    }

    /// ⌘G / ⇧⌘G: step the open find bar through its matches. Broadcast the way ⌘F is, so they
    /// work with the keyboard in the find field or in the document.
    @objc func findNextMatch(_ sender: Any?) {
        NotificationCenter.default.post(name: .termioFindNext, object: nil)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        NotificationCenter.default.post(name: .termioFindPrevious, object: nil)
    }

    /// ⌘E: the editor's selection becomes the find query.
    @objc func useSelectionForFind(_ sender: Any?) {
        NotificationCenter.default.post(name: .termioUseSelectionForFind, object: nil)
    }

    /// Opens the focused card's panel for a freshly opened detail, at the width it last had.
    private func revealInspectorForDetail() {
        if !store.inspectorVisible { store.inspectorVisible = true }
    }

    /// Brings the window into or out of the maximized-detail mode. Idempotent, and reached from two
    /// clocks: synchronously as the maximize flag flips (so the host swaps with the docked detail in
    /// one frame) and from the deferred store observer (which catches the detail closing out from
    /// under a host that is already up).
    private func applyDetailMaximized(_ maximized: Bool) {
        setDetailMaximized(maximized)
    }

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
    private func setDetailMaximized(_ on: Bool) {
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

    /// Termio ▸ Check for Updates… — hands off to Sparkle's standard update flow.
    /// Reached via the responder chain (the menu item targets `nil`), the same
    /// nil-target routing the other app-menu items use.
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    // MARK: - Split panes & palettes (View menu / ⌘⇧O / ⌘⇧P)

    /// View ▸ Open Quickly… (⌘⇧O) — the *things* palette: jump to any session.
    /// Pressing it while the Command Palette is up switches modes in place.
    @objc func toggleOpenQuickly(_ sender: Any?) {
        store.paletteMode = store.paletteMode == .openQuickly ? nil : .openQuickly
    }

    /// View ▸ Command Palette… (⌘⇧P) — the *verbs* palette: run an app action
    /// (see `presentCommandPalette`).
    @objc func toggleCommandPalette(_ sender: Any?) {
        store.paletteMode = store.paletteMode == .commands ? nil : .commands
    }

    /// Floats the palette as a borderless key panel, top-centered over the main
    /// window and attached as a child so it rides window moves. No backdrop —
    /// the panel just floats, Spotlight-style. Clicking anywhere else (the
    /// panel resigning key) dismisses it.
    private func presentCommandPalette() {
        guard palettePanel == nil, let window else { return }
        let size = CommandPaletteView.panelSize
        let panel = KeyBorderlessPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        let hosting = NSHostingView(rootView: CommandPaletteView(onClose: { [weak self] in
            self?.store.paletteMode = nil
        }).environmentObject(store))
        panel.contentView = Self.paletteBackdrop(around: hosting)

        let frame = window.frame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - 140 - size.height
        ))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        // The shadow shape is computed before the masked backdrop renders,
        // leaving a square shadow slab poking out at the corners; recompute
        // it after the first frame.
        DispatchQueue.main.async { panel.invalidateShadow() }
        palettePanel = panel

        // Click-away/⌘-tab dismissal: losing key closes the palette. The store
        // flag is the source of truth, so route through it (the observer then
        // calls `dismissCommandPalette` exactly once).
        paletteResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.paletteMode = nil }
        }
    }

    /// The palette's translucent backdrop. It must live here in AppKit:
    /// SwiftUI materials only sample content *within their own window*, and
    /// the palette panel contains nothing but the palette, so they render as
    /// an opaque grey slab.
    ///
    /// Liquid Glass on macOS 26: `cornerRadius` alone only rounds the glass
    /// "lens" — the window-server backdrop stays a square slab poking out at
    /// the corners; `clipsToBounds = true` is what actually clips it.
    /// Pre-26 fallback: `NSVisualEffectView`, where `maskImage` (not layer
    /// corner rounding) is the one mechanism that clips the backdrop region
    /// and the window shadow to the rounded shape.
    private static func paletteBackdrop(around hosting: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.clipsToBounds = true
            glass.contentView = hosting
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedRectMask(cornerRadius: 18)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// A stretchable rounded-rect alpha mask for `NSVisualEffectView.maskImage`.
    /// Cap insets keep the corners pixel-exact at any panel size.
    private static func roundedRectMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }

    private func dismissCommandPalette() {
        guard let panel = palettePanel else { return }
        if let observer = paletteResignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        paletteResignObserver = nil
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        palettePanel = nil
        // Hand key back to the main window — but not when the palette closed
        // because the whole app deactivated (a ⌘-tab away must not be undone).
        if NSApp.isActive { window?.makeKeyAndOrderFront(nil) }
    }

    /// View ▸ Split Right (⌘D) — splits the focused pane side-by-side, opening a
    /// fresh terminal in the same project.
    @objc func splitPaneRight(_ sender: Any?) {
        store.splitSelectedPane(.horizontal)
    }

    /// View ▸ Split Left — side-by-side, with the new terminal on the leading side.
    @objc func splitPaneLeft(_ sender: Any?) {
        store.splitSelectedPane(.horizontal, slot: .first)
    }

    /// View ▸ Split Down (⌘⇧D) — splits the focused pane stacked.
    @objc func splitPaneDown(_ sender: Any?) {
        store.splitSelectedPane(.vertical)
    }

    /// View ▸ Split Up — stacked, with the new terminal above.
    @objc func splitPaneUp(_ sender: Any?) {
        store.splitSelectedPane(.vertical, slot: .first)
    }

    /// View ▸ Ungroup — collapses the focused pane out of the layout. The session
    /// itself stays alive in the sidebar; ending it is ⌘W. Ships unbound, so this
    /// only runs from the menu or a key the user assigned.
    @objc func ungroupPane(_ sender: Any?) {
        let frontmost = CloseCommand.frontmost(mainWindow: window, palettePanel: palettePanel)
        guard CloseCommand.actsOnTerminal(frontmost) else { return }
        store.ungroupSelectedPane()
    }

    /// File ▸ Close Session (⌘W) — Chrome's Close Tab: it ends the focused session,
    /// collapsing its pane if it held one. With no session on screen it falls
    /// through to closing the window, the way Chrome's last tab does; that close is
    /// just a close, with the app and every remaining session still running (#242).
    @objc func closeSelectedSession(_ sender: Any?) {
        performClose(sender, closingSession: store.selectedSessionID != nil)
    }

    /// File ▸ Close Window (⌘⇧W) — closes the frontmost window regardless of what
    /// is selected, so it dismisses Settings when Settings is what's in front.
    @objc func closeMainWindow(_ sender: Any?) {
        performClose(sender, closingSession: false)
    }

    /// Shared body of the two close keys. Menu actions hang off the app delegate
    /// rather than a window, so the target is resolved here (see `CloseCommand`):
    /// without it, ⌘W pressed in Settings reaches past it and ends a session in
    /// the terminal behind.
    private func performClose(_ sender: Any?, closingSession: Bool) {
        let frontmost = CloseCommand.frontmost(mainWindow: window, palettePanel: palettePanel)
        switch CloseCommand.action(for: frontmost, closingSession: closingSession) {
        case .nothing:
            break
        case .dismissPalette:
            // The store flag owns the palette's presentation; the observer tears
            // the panel down (see `presentCommandPalette`).
            store.paletteMode = nil
        case .closeKeyWindow:
            NSApp.keyWindow?.performClose(sender)
        case .closeSession:
            guard let id = store.selectedSessionID else { break }
            store.requestCloseSession(id)
        case .closeMainWindow:
            window?.performClose(sender)
        }
    }

    /// View ▸ Zoom Split (⌘⇧↩) — maximise the focused pane, or restore the split.
    @objc func toggleSplitZoom(_ sender: Any?) {
        store.toggleSelectedPaneZoom()
    }

    // Font size drives the persisted `fontSize` setting, so a bump survives
    // relaunch and re-styles every open surface at once (the store's settings
    // observer reapplies appearance). Clamped to the Appearance stepper's range.
    @objc func increaseFontSize(_ sender: Any?) {
        settings.fontSize = min(32, (settings.fontSize + 1).rounded())
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        settings.fontSize = max(8, (settings.fontSize - 1).rounded())
    }

    @objc func resetFontSize(_ sender: Any?) {
        settings.fontSize = 13
    }

    @objc func focusPaneLeft(_ sender: Any?) { store.focusPane(.left) }
    @objc func focusPaneRight(_ sender: Any?) { store.focusPane(.right) }
    @objc func focusPaneUp(_ sender: Any?) { store.focusPane(.up) }
    @objc func focusPaneDown(_ sender: Any?) { store.focusPane(.down) }

    // Session ▸ Next/Previous — cycles the sidebar selection in its visual
    // order, wrapping at the ends (see `selectAdjacentSession`).
    @objc func nextSession(_ sender: Any?) { store.selectAdjacentSession(1) }
    @objc func previousSession(_ sender: Any?) { store.selectAdjacentSession(-1) }

    /// The Session menu rows currently marked working, so the comet timer can
    /// advance them while the menu is open (see `menuWillOpen`). Rebuilt on
    /// every `fillSessionMenu`.
    private var sessionMenuWorkingItems: [NSMenuItem] = []
    private var sessionMenuCometTimer: Timer?
    private var sessionMenuCometPhase: Double = 0

    /// A row of the Session menu's jump list (see `fillSessionMenu`).
    @objc func revealSessionFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        store.revealSession(id)
    }

    /// The selected session's project when it's a real git folder — the target
    /// of the Branch menu's verbs, GitHub Desktop's "current repository". A loose
    /// session (no project) and a non-repo folder ("—" branch) don't qualify, so
    /// the Branch menu dims for them.
    private var currentBranchProject: Project? {
        guard let id = store.selectedSessionID,
              let project = store.project(for: id),
              project.branch != "—" else { return nil }
        return project
    }

    /// File ▸ New Worktree… — the sidebar context menu's verb promoted to the
    /// menu bar (and a shortcut), so the agent-per-worktree loop doesn't need a
    /// right-click. Acts on the selected session's project.
    @objc func newWorktree(_ sender: Any?) {
        guard let project = currentBranchProject else { return }
        store.addWorktree(from: project.id)
    }

    /// File ▸ New Pull Request — GitHub Desktop's browser hand-off, verbatim:
    /// opens the forge's compare page for the current branch (the session's
    /// worktree branch when it lives in one). termio never authors the PR —
    /// committing and pushing stay in the terminal — so an unpushed branch gets
    /// an explainer, not a push.
    @objc func newPullRequest(_ sender: Any?) {
        guard let project = currentBranchProject,
              let sessionID = store.selectedSessionID else { return }
        let dir = store.session(sessionID)?.worktreePath ?? project.path
        Task { @MainActor in
            if let url = await GitService.newPullRequestPage(in: dir) {
                NSWorkspace.shared.open(url)
            } else {
                let alert = NSAlert()
                alert.messageText = localized("Couldn’t open a pull request page")
                alert.informativeText = localized("Push the current branch to the repository’s remote first, then try again. (The remote also needs to be a forge Termio recognizes: GitHub, GitLab, Bitbucket, or Gitea.)")
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

/// The "New Chat ▸" parent item shared by the File menu and the sidebar `+`
/// pull-down. Its submenu starts empty: the AppDelegate (as its delegate) fills it
/// with the user's enabled agents on every open and on every key-equivalent search,
/// so roster edits and the migrating ⌘N default never need change-notification
/// plumbing.
@MainActor
private func makeNewChatItem() -> NSMenuItem {
    let item = NSMenuItem(title: localized("New Chat"), action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: localized("New Chat"))
    submenu.delegate = NSApp.delegate as? AppDelegate
    item.submenu = submenu
    return item
}

/// Items whose shape depends on how many devices exist are found by tag when
/// their menu opens: the File menu and the sidebar `+` each own one, and
/// everything around it has to survive the refresh, so the item is reconfigured
/// in place rather than the menu rebuilt.
enum DeviceMenuTag {
    static let newTerminal = 7301
    static let newTerminalAtHome = 7302
    static let connectTo = 7303
    static let newWorkspace = 7306
}

/// The "Workspace ▸" item — the scopes, with the current one checked, and where the
/// switch gets a keyboard chord. The sidebar's switcher is the same menu in the chrome;
/// this one exists because a key equivalent only fires from the main menu, and because
/// a chord nobody can find is a chord nobody presses.
///
/// Always shown, including with a single workspace: the sidebar's switcher collapses
/// then — with one scope there is nothing to switch — so this is where creating,
/// renaming and removing a workspace has to stay reachable.
@MainActor
private func makeWorkspaceItem() -> NSMenuItem {
    let item = NSMenuItem(title: localized("Workspace"), action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: localized("Workspace"))
    submenu.delegate = NSApp.delegate as? AppDelegate
    item.submenu = submenu
    return item
}

/// The "Connect to… ▸" parent item — the verb that reaches a machine used before,
/// filled the same lazy way as the others with the `~/.ssh/config` aliases no
/// device answers to yet. Hidden while there are none (see `refreshDeviceItems`):
/// a row listing nothing is the dead end this replaces.
@MainActor
private func makeConnectToItem() -> NSMenuItem {
    let item = NSMenuItem(title: localized("Connect to…"), action: nil, keyEquivalent: "")
    item.tag = DeviceMenuTag.connectTo
    let submenu = NSMenu(title: localized("Connect to…"))
    submenu.delegate = NSApp.delegate as? AppDelegate
    item.submenu = submenu
    return item
}

/// The "New SSH Connection ▸" parent item, shared the same way as `makeNewChatItem`.
/// Its submenu lists the connectable `Host` aliases from `~/.ssh/config`, filled on
/// every open, so a config edit shows up without any change-notification plumbing.
@MainActor
private func makeNewSSHItem() -> NSMenuItem {
    let item = NSMenuItem(title: localized("New SSH Connection"), action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: localized("New SSH Connection"))
    submenu.delegate = NSApp.delegate as? AppDelegate
    item.submenu = submenu
    return item
}

extension AppDelegate: NSMenuDelegate {
    /// Serves every menu this delegate is attached to, told apart by title. Most
    /// are filled from scratch on each open — the Session menu, New Chat, New SSH
    /// Connection, Connect to…. The File menu and the sidebar `+` instead hold a
    /// few device-aware items among items this delegate does not own, so they are
    /// refreshed in place.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The two device-aware menus are refreshed in place: they hold items this
        // delegate doesn't own, so emptying them would take the rest of the menu
        // with it.
        switch menu.title {
        case localized("File"), localized("New Session"):
            refreshDeviceItems(in: menu)
            return
        default:
            break
        }
        menu.removeAllItems()
        switch menu.title {
        case localized("Session"):
            fillSessionMenu(menu)
        case localized("New SSH Connection"):
            fillNewSSHMenu(menu)
        case localized("Connect to…"):
            fillConnectToMenu(menu)
        case localized("New Workspace"):
            fillNewWorkspaceMenu(menu)
        case localized("Workspace"):
            fillWorkspaceMenu(menu)
        default:
            fillNewChatMenu(menu)
        }
    }

    /// Reshapes every device-aware item this menu carries, each time it opens, so
    /// a machine that came or went since the last look is reflected without any
    /// change-notification plumbing.
    private func refreshDeviceItems(in menu: NSMenu) {
        // AppKit runs this during its key-equivalent sweep as well as on open, so
        // the roster is read once per pass rather than once per item — reading
        // `~/.ssh/config` for "Connect to…" is the expensive half.
        let known = DeviceRoster.known(in: store)
        // The other machines are read once per pass for the same reason: the New
        // Workspace row collapses on this list, and building it parses
        // `~/.ssh/config`.
        let others = otherDevices(known: known)
        for item in menu.items {
            switch item.tag {
            case DeviceMenuTag.newTerminal:
                refreshNewTerminalItem(item, atHome: false, command: .newTerminal)
            case DeviceMenuTag.newTerminalAtHome:
                refreshNewTerminalItem(item, atHome: true, command: nil)
            case DeviceMenuTag.connectTo:
                item.isHidden = DeviceRoster.unusedAliases(known: known).isEmpty
            case DeviceMenuTag.newWorkspace:
                refreshNewWorkspaceItem(item, others: others)
            default:
                continue
            }
        }
    }

    /// Points one "new terminal" item at the current device. Always a plain verb,
    /// however many machines are known: New Terminal opens on the device you are
    /// looking at — the switcher already made that choice, and asking again turns
    /// one decision into two. It also kept the count of known machines visible in a
    /// menu that is about starting a shell, not about picking a computer.
    private func refreshNewTerminalItem(
        _ item: NSMenuItem,
        atHome: Bool,
        command: KeyCommandID?
    ) {
        item.submenu = nil
        item.action = atHome
            ? #selector(newScratchTerminal(_:))
            : #selector(newTerminalHere(_:))
        item.target = self
        if let command { item.applyShortcut(for: command) }
    }

    /// The machines other than this Mac something can be put on: one worked on
    /// before, plus one from `~/.ssh/config` never reached. Putting a workspace on
    /// a box is itself a first contact — `ensureRemoteReady` installs termiod on
    /// the way — so the list is the same one `Clone to <device>…` offers.
    ///
    /// Empty is the single-machine install, which is what the New Workspace submenu
    /// collapses on.
    private func otherDevices(known: [KnownDevice]) -> [KnownDevice] {
        known.filter { !$0.isLocal }
            + DeviceRoster.unusedAliases(known: known).map { KnownDevice(alias: $0, deviceID: nil) }
    }

    /// The same single-device collapse applied to "New Workspace…": a plain verb
    /// while this Mac is the only machine, a device submenu once there is a second
    /// box to put a workspace on.
    ///
    /// A workspace belongs to exactly one machine, so the choice has to be made
    /// somewhere. Making it here rather than in the name panel is what keeps the
    /// device level invisible to someone who owns one machine — a pop-up inside the
    /// panel would show every local-only user a one-item menu reading "This Mac",
    /// which is a control for a decision they never took.
    ///
    /// No key equivalent travels with the shape: creating a workspace has no
    /// shortcut, so unlike ⌘O there is nothing to move onto the This Mac row.
    private func refreshNewWorkspaceItem(_ item: NSMenuItem, others: [KnownDevice]) {
        guard !others.isEmpty else {
            item.title = localized("New Workspace…")
            item.submenu = nil
            item.action = #selector(newWorkspace(_:))
            item.target = self
            return
        }
        // The ellipsis moves to the rows: each of those opens the name panel, and a
        // parent that only reveals a submenu never carries one.
        item.title = localized("New Workspace")
        // Attached once and filled by the delegate on open — the File menu's copy is
        // rebuilt per open, and so is the sidebar `+`'s.
        //
        // Everything below runs on the *first* reshape only. Once a submenu is
        // attached AppKit owns both the action and the target — it installs its own
        // `submenuAction:` aimed at the menu — and re-clearing them on a later pass
        // strips that and leaves a submenu parent with no action, which dims the row
        // permanently. This menu is refreshed on every open, so "later pass" means
        // the second time the user pulls it down.
        guard item.submenu?.title != localized("New Workspace") else { return }
        item.action = nil
        item.target = nil
        let submenu = NSMenu(title: localized("New Workspace"))
        submenu.delegate = self
        item.submenu = submenu
    }

    private func fillNewWorkspaceMenu(_ menu: NSMenu) {
        let local = menu.addItem(
            withTitle: localized("This Mac…"), action: #selector(newWorkspace(_:)), keyEquivalent: "")
        local.target = self
        menu.addItem(.separator())
        for device in otherDevices(known: DeviceRoster.known(in: store)) {
            // The machine's own name, so nothing here is translated — it is the
            // alias out of the user's `~/.ssh/config`.
            let row = menu.addItem(
                withTitle: "\(device.name)…",
                action: #selector(newWorkspaceOnDevice(_:)),
                keyEquivalent: "")
            row.target = self
            row.representedObject = device.alias
        }
    }

    /// Fills the Session menu: the cycling and close verbs, then a live jump
    /// list — one submenu per project holding its session rows, mirroring the
    /// sidebar's hierarchy (the user's choice over Chrome's flat tab list).
    /// Rows keep the tray roster's vocabulary (brand mark or working comet,
    /// trailing green/amber dot, checkmark on the selected session); since a
    /// submenu hides its dots until hovered, each project row rolls up its most
    /// urgent resting cue (amber outranks green) and wears the checkmark for a
    /// selection it contains. Rebuilt on every open so the list, the dots, and
    /// the rebindable shortcuts are always current. Flattened order matches
    /// `selectAdjacentSession`'s cycling exactly.
    private func fillSessionMenu(_ menu: NSMenu) {
        sessionMenuWorkingItems.removeAll()
        menu.addItem(
            withTitle: localized("Next Session"),
            action: #selector(nextSession(_:)),
            command: .nextSession
        )
        menu.addItem(
            withTitle: localized("Previous Session"),
            action: #selector(previousSession(_:)),
            command: .previousSession
        )

        let groups = store.sidebarSessionGroups
        // Once there is more than one workspace a bare "Terminals" says nothing
        // about which scope it belongs to, so each header carries its own.
        let manyWorkspaces = store.hasMultipleWorkspaces
        var previousTier: SessionGroup.Tier?
        for group in groups {
            let sessions = group.sessions
            // The loose Terminals/Chats sections and the real projects are
            // different tiers, as in the sidebar — a divider at each tier change
            // keeps them read apart (and the first one separates the whole list
            // from the verbs above).
            if group.tier != previousTier { menu.addItem(.separator()) }
            previousTier = group.tier
            let header = manyWorkspaces ? "\(group.workspace) — \(group.name)" : group.name
            let projectItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: header)
            for session in sessions {
                let status = store.status(for: session.id)
                let title = store.displayTitle(for: session)
                let item = NSMenuItem(
                    title: title,
                    action: #selector(revealSessionFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id.uuidString
                // A working row swaps the brand mark for the sidebar's comet;
                // the timer started in `menuWillOpen` spins it while the menu
                // is open, exactly as the tray's roster does.
                if status == .working {
                    item.image = sessionCometImage(phase: sessionMenuCometPhase)
                    sessionMenuWorkingItems.append(item)
                } else {
                    item.image = agentMenuImage(for: session.agent)
                }
                item.attributedTitle = sessionMenuRowTitle(title, status: status)
                if session.id == store.selectedSessionID { item.state = .on }
                submenu.addItem(item)
            }
            projectItem.submenu = submenu
            let statuses = sessions.map { store.status(for: $0.id) }
            let rollup: SessionStatus = statuses.contains(.needsAttention) ? .needsAttention
                : statuses.contains(.done) ? .done
                : .idle
            projectItem.attributedTitle = sessionMenuRowTitle(header, status: rollup)
            if sessions.contains(where: { $0.id == store.selectedSessionID }) {
                projectItem.state = .on
            }
            menu.addItem(projectItem)
        }
    }

    /// While a menu is open its modal event-tracking loop stops SwiftUI's
    /// `TimelineView` clock, so the Session menu spins its working comets the
    /// way the tray does: a timer registered for the tracking run-loop mode
    /// advances one shared frame across every working row (submenu rows
    /// included — their items are live while the parent menu tracks). Started
    /// unconditionally: `menuWillOpen` can precede the `menuNeedsUpdate` fill,
    /// so the working rows may not exist yet when the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu.title == localized("Session") else { return }
        sessionMenuCometTimer?.invalidate()
        let interval = 1.0 / 15.0
        let period = 1.1  // matches the sidebar's WorkingIndicator
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.sessionMenuWorkingItems.isEmpty else { return }
                self.sessionMenuCometPhase += interval / period
                if self.sessionMenuCometPhase >= 1 { self.sessionMenuCometPhase -= 1 }
                let frame = sessionCometImage(phase: self.sessionMenuCometPhase)
                for item in self.sessionMenuWorkingItems { item.image = frame }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        sessionMenuCometTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu.title == localized("Session") else { return }
        sessionMenuCometTimer?.invalidate()
        sessionMenuCometTimer = nil
    }

    /// Fills a New Chat submenu with one row per enabled agent — the user's own
    /// roster (built-ins plus any manifest in `~/.termio/config/agents/`), in
    /// Settings order. The resolved default (pinned, else last-used, else first)
    /// carries the ⌘N binding, so the menu always names what the shortcut opens
    /// and the binding follows the default as it migrates.
    private func fillNewChatMenu(_ menu: NSMenu) {
        let agents = enabledAgentPresets(settings).filter { $0 != .terminal }
        guard !agents.isEmpty else {
            menu.addItem(withTitle: localized("No Agents Enabled"), action: nil, keyEquivalent: "")
            return
        }
        let defaultID = store.defaultChatAgent()?.id
        for agent in agents {
            let item = menu.addItem(
                withTitle: agent.displayName,
                action: #selector(newChatAgent(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = agent.id
            item.image = agentMenuImage(for: agent)
            if agent.id == defaultID { item.applyShortcut(for: .newChat) }
        }
    }

    /// Fills a New SSH Connection submenu with one row per `~/.ssh/config` host —
    /// the same aliases Settings ▸ Devices lists — each connecting directly, plus a
    /// trailing "Add Host…" opening the same form as Settings' Add Host button
    /// and connecting to the machine it adds (see `addSSHHost`). With an empty
    /// config only "Add Host…" remains — the first-run path.
    private func fillNewSSHMenu(_ menu: NSMenu) {
        let hosts = SSHConfigFile.hosts()
        for host in hosts {
            let item = menu.addItem(
                withTitle: host.alias,
                action: #selector(newSSHHost(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = host.alias
        }
        if !hosts.isEmpty { menu.addItem(.separator()) }
        let add = menu.addItem(
            withTitle: localized("Add Host…"),
            action: #selector(addSSHHost(_:)),
            keyEquivalent: ""
        )
        add.target = self
    }

    /// One row per `~/.ssh/config` alias no device answers to yet. Connecting
    /// opens a terminal there, which installs `termiod` on the way
    /// (`ensureRemoteReady`) and teaches the app which machine the alias reaches —
    /// after which it is a device and moves out of this menu.
    /// The Workspace submenu: one row per workspace, the current one checked, the
    /// first nine on ⌘1…9. This is the copy that *binds* those keys — the sidebar
    /// switcher draws the same rows from `WorkspaceMenu.rows`, but AppKit resolves
    /// a key equivalent against the main menu, so only this one claims them.
    private func fillWorkspaceMenu(_ menu: NSMenu) {
        for row in WorkspaceMenu.rows(in: store, target: self, action: #selector(switchToWorkspace(_:))) {
            menu.addItem(row)
        }
        menu.addItem(.separator())
        // The same row the sidebar `+` carries: a plain verb on one machine, a
        // device submenu on two (`refreshNewWorkspaceItem`). This menu is rebuilt on
        // every open rather than refreshed in place, so the row is shaped here
        // instead of by tag.
        let new = menu.addItem(withTitle: localized("New Workspace…"),
                               action: #selector(newWorkspace(_:)), keyEquivalent: "")
        new.target = self
        refreshNewWorkspaceItem(new, others: otherDevices(known: DeviceRoster.known(in: store)))
        menu.addItem(.separator())
        // Renaming and removing are in Settings ▸ Workspaces rather than here.
        // Both act on a workspace the user has to pick, and a menu that shows the
        // list one checked row at a time can only offer them for the current one —
        // which is why they read as "Rename Workspace" with no name in them.
        let settingsItem = menu.addItem(withTitle: localized("Workspace Settings…"),
                                        action: #selector(openWorkspaceSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
    }

    private func fillConnectToMenu(_ menu: NSMenu) {
        let known = DeviceRoster.known(in: store)
        for alias in DeviceRoster.unusedAliases(known: known) {
            let item = menu.addItem(
                withTitle: alias,
                action: #selector(connectToDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = alias
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Auto-enablement for menu items targeting the delegate: the Session
    /// cycling verbs need sessions to cycle, the branch verbs a selected
    /// session inside a real git project, and Edit ▸ Paste the same
    /// enablement `paste:` would have had. Every other action stays enabled,
    /// matching the pre-validation behavior.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(nextSession(_:)), #selector(previousSession(_:)):
            return !store.sidebarSessionGroups.isEmpty
        case #selector(newWorktree(_:)), #selector(newPullRequest(_:)):
            return currentBranchProject != nil
        case #selector(pasteFromEditMenu(_:)):
            return validateOrdinaryPaste(menuItem)
        default:
            return true
        }
    }

    /// Same enablement `paste:` would have had: a text field still dims when
    /// the pasteboard is empty, a terminal stays enabled, and nothing that
    /// doesn't implement `paste:` lights up just because this item is ours.
    private func validateOrdinaryPaste(_ menuItem: NSMenuItem) -> Bool {
        guard let target = NSApp.target(
            forAction: #selector(NSText.paste(_:)), to: nil, from: menuItem)
        else { return false }
        let probe = NSMenuItem(
            title: menuItem.title,
            action: #selector(NSText.paste(_:)),
            keyEquivalent: menuItem.keyEquivalent)
        if let validator = target as? NSMenuItemValidation {
            return validator.validateMenuItem(probe)
        }
        if let validator = target as? NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(probe)
        }
        return true
    }
}

/// A borderless window can't become key by default, but the palette's search
/// field needs key status to type into — hence the one-line subclass.
private final class KeyBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Builds the sidebar's `+` pull-down: the ways something
/// new enters the sidebar without opening a folder — a loose terminal (Terminals
/// section), a loose agent chat (Chats section), an SSH terminal, or a folder opened
/// as a project. "New Chat" opens the user's agent roster and "New SSH Connection"
/// the config's hosts as submenus (the same ones the File menu carries — see
/// `makeNewChatItem` / `makeNewSSHItem`).
///
/// Every entry here is context-free: nothing reads the selection, so the terminal
/// entry is the `$HOME` one. The `+` lives in the sidebar's control row, where "here"
/// has no referent — the directory-following New Terminal is ⌘T, pressed with the
/// terminal in front of you.
@MainActor
func makeNewSessionMenu() -> NSMenu {
    // Titled and delegated so the AppDelegate can reshape the terminal item on
    // open: one machine keeps it a plain verb, a second grows it into a device
    // submenu (see `refreshNewTerminalItem`). Its rows target the AppDelegate,
    // which is where both the local and the per-device actions live.
    let menu = NSMenu(title: localized("New Session"))
    menu.delegate = NSApp.delegate as? AppDelegate
    let terminal = NSMenuItem(title: localized("New Terminal at Home"),
                              action: #selector(AppDelegate.newScratchTerminal(_:)),
                              keyEquivalent: "")
    terminal.target = NSApp.delegate as? AppDelegate
    terminal.tag = DeviceMenuTag.newTerminalAtHome
    menu.addItem(terminal)
    menu.addItem(makeNewChatItem())
    menu.addItem(makeNewSSHItem())
    // A plain verb on every install, like the terminal row above: a project
    // takes its machine from the workspace it is filed in, so the scope on
    // screen has already made that choice (see `presentOpenProjectPanel`).
    let folder = NSMenuItem(title: localized("Open Project…"),
                            action: #selector(AppDelegate.openProject(_:)),
                            keyEquivalent: "")
    folder.target = NSApp.delegate as? AppDelegate
    menu.addItem(folder)
    // The one container verb that belongs in a context-free menu: a new
    // workspace reads no selection and no focus. It sits last, after a
    // separator, because starting a scope is rarer than starting a session —
    // and it is reshaped into a device submenu on open like the rows above
    // (`refreshNewWorkspaceItem`), since a workspace is on one machine.
    menu.addItem(.separator())
    let workspace = NSMenuItem(title: localized("New Workspace…"),
                               action: #selector(AppDelegate.newWorkspace(_:)),
                               keyEquivalent: "")
    workspace.target = NSApp.delegate as? AppDelegate
    workspace.tag = DeviceMenuTag.newWorkspace
    menu.addItem(workspace)
    return menu
}


@MainActor
private func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: localized("Check for Updates…"),
        action: #selector(AppDelegate.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: localized("Settings…"),
        action: #selector(AppDelegate.showSettings(_:)),
        keyEquivalent: ","
    )
    appMenu.addItem(.separator())
    // The standard Hide block every Mac app carries and termio didn't, which is
    // why ⌘H did nothing (#612) — the Window menu's ⌘M had the same history.
    // The surface's performKeyEquivalent passes unbound ⌘-chords through, so
    // these fire from the menu with no extra key plumbing.
    appMenu.addItem(
        withTitle: localized("Hide Termio"),
        action: #selector(NSApplication.hide(_:)),
        keyEquivalent: "h"
    )
    let hideOthersItem = appMenu.addItem(
        withTitle: localized("Hide Others"),
        action: #selector(NSApplication.hideOtherApplications(_:)),
        keyEquivalent: "h"
    )
    hideOthersItem.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(
        withTitle: localized("Show All"),
        action: #selector(NSApplication.unhideAllApplications(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: localized("Quit Termio"),
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appItem.submenu = appMenu

    let fileItem = NSMenuItem()
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: localized("File"))
    // Device-aware items are reshaped on open (see `refreshDeviceItems`) — that's
    // what collapses New Terminal to a plain verb on a one-machine install and
    // grows it into a device submenu once there is a second.
    fileMenu.delegate = NSApp.delegate as? AppDelegate
    // Keeps a new-terminal action reachable when the navigator, and the `+` in its control row,
    // are collapsed. ⌘T is safe: TUI programs drive off Ctrl,
    // never Cmd, so it can't shadow a key a terminal app wants.
    fileMenu.addItem(
        withTitle: localized("New Terminal"),
        action: #selector(AppDelegate.newTerminalHere(_:)),
        command: .newTerminal
    ).tag = DeviceMenuTag.newTerminal
    // The always-`$HOME` terminal, kept as its own verb now that ⌘T follows the
    // focused session's directory.
    fileMenu.addItem(
        withTitle: "New Terminal at Home",
        action: #selector(AppDelegate.newScratchTerminal(_:)),
        command: .newTerminalAtHome
    )
    // New Chat ▸ one row per enabled agent (the user's roster, filled on open by the
    // AppDelegate — see `makeNewChatItem`). ⌘N (rebindable in Settings ▸ Keyboard)
    // sits on the resolved default's row, so the shortcut stays one-press and the
    // menu names the agent it will open.
    fileMenu.addItem(makeNewChatItem())
    // New SSH Connection ▸ one row per `~/.ssh/config` host, plus Add Host… for
    // machines not in it yet (filled on open by the AppDelegate — see `makeNewSSHItem`).
    fileMenu.addItem(makeNewSSHItem())
    // Connect to… ▸ the machines in `~/.ssh/config` termio hasn't worked on yet.
    // Finder's own split: reaching a machine is a verb in a menu, while what termio
    // knows *about* a machine belongs in Settings. Hidden while there is nothing
    // left to reach.
    fileMenu.addItem(makeConnectToItem())
    fileMenu.addItem(.separator())
    // Workspace ▸ the scopes, with ⌃⌥⌘1…9 on the first nine rows. It sits with the
    // other place verbs rather than in View, because which workspace you are in
    // decides what the sidebar lists and which repo the panes read.
    fileMenu.addItem(makeWorkspaceItem())
    fileMenu.addItem(.separator())
    // ⌘O opens a project on the machine the current workspace is on, so it stays a
    // plain verb however many machines are known (see `presentOpenProjectPanel`).
    fileMenu.addItem(
        withTitle: localized("Open Project…"),
        action: #selector(AppDelegate.openProject(_:)),
        command: .openProject
    )
    fileMenu.addItem(.separator())
    // The two branch verbs that fit termio's read-only git surface, with
    // GitHub Desktop's Branch-menu bindings: creating a worktree (termio's
    // branch-creation verb, the sidebar context menu's action promoted) and
    // the New Pull Request browser hand-off. Both act on the selected
    // session's project and dim without one (see `validateMenuItem`) — too few
    // to carry a top-level Branch menu, so they live with the project verbs.
    fileMenu.addItem(
        withTitle: localized("New Worktree…"),
        action: #selector(AppDelegate.newWorktree(_:)),
        command: .newWorktree
    )
    fileMenu.addItem(
        withTitle: localized("New Pull Request"),
        action: #selector(AppDelegate.newPullRequest(_:)),
        command: .newPullRequest
    )
    fileMenu.addItem(.separator())
    // Chrome's pair, on Chrome's keys: ⌘W closes the focused session (and the
    // window once none is left), ⌘⇧W closes the whole window. Close Session stays
    // enabled with no session selected so ⌘W still reaches the fallthrough
    // instead of being swallowed by a dimmed menu item.
    fileMenu.addItem(
        withTitle: localized("Close Session"),
        action: #selector(AppDelegate.closeSelectedSession(_:)),
        command: .closeSession
    )
    fileMenu.addItem(
        withTitle: localized("Close Window"),
        action: #selector(AppDelegate.closeMainWindow(_:)),
        command: .closeWindow
    )
    fileItem.submenu = fileMenu

    // Standard Edit menu so copy/paste/select-all responder actions work.
    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: localized("Edit"))
    editMenu.addItem(withTitle: localized("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: localized("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    // Distinct from `paste:` so a file-URL intercept can run first, then
    // forward the ordinary selector without re-entering this item.
    editMenu.addItem(
        withTitle: localized("Paste"),
        action: #selector(AppDelegate.pasteFromEditMenu(_:)),
        keyEquivalent: "v")
    editMenu.addItem(withTitle: localized("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenu.addItem(.separator())
    // Edit ▸ Find, where every Mac app keeps it, on the keys people already have in their
    // fingers: ⌘F opens the current file's in-editor find bar, ⌘G / ⇧⌘G step through the
    // matches, ⌘E makes the selection the query. All four broadcast via notification so they
    // work regardless of first-responder — the terminal receives no find behaviour.
    //
    // They stay hardwired here rather than joining `KeyCommandCatalog`, which is the table of
    // rebindable *app* verbs — window, session, pane — every one of which acts whatever is on
    // screen. These four only mean anything while an editor overlay is open, they are macOS
    // standard keys nobody rebinds, and ⌘F has always lived here; splitting the family so one
    // of them is rebindable and three are not would be worse than either.
    let findItem = NSMenuItem(title: localized("Find"), action: nil, keyEquivalent: "")
    let findMenu = NSMenu(title: localized("Find"))
    findMenu.addItem(withTitle: localized("Find…"),
                     action: #selector(AppDelegate.showEditorFindBar(_:)),
                     keyEquivalent: "f")
    findMenu.addItem(withTitle: localized("Find Next"),
                     action: #selector(AppDelegate.findNextMatch(_:)),
                     keyEquivalent: "g")
    let findPreviousItem = findMenu.addItem(
        withTitle: localized("Find Previous"),
        action: #selector(AppDelegate.findPreviousMatch(_:)),
        keyEquivalent: "g")
    findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
    findMenu.addItem(withTitle: localized("Use Selection for Find"),
                     action: #selector(AppDelegate.useSelectionForFind(_:)),
                     keyEquivalent: "e")
    // Target left nil before the submenu is attached: AppKit installs its own `submenuAction:`
    // and only adopts the submenu as the target when there isn't one already (see
    // `SubmenuParentEnablementTests`).
    findItem.submenu = findMenu
    editMenu.addItem(findItem)
    editItem.submenu = editMenu

    let viewItem = NSMenuItem()
    mainMenu.addItem(viewItem)
    let viewMenu = NSMenu(title: localized("View"))
    // otty/Xcode's split: ⌘⇧O Open Quickly jumps to things (sessions), ⌘⇧P
    // Command Palette runs verbs (actions). ⌘⇧P is the VS Code convention; not
    // ⌘K: ghostty binds super+k to clear_screen and performs it inside the
    // surface, so the key never reaches the menu. Both shortcuts are
    // additionally unbound in the surface config (see `applyAppearance`) so
    // they can't be swallowed either.
    viewMenu.addItem(
        withTitle: localized("Open Quickly…"),
        action: #selector(AppDelegate.toggleOpenQuickly(_:)),
        command: .openQuickly
    )
    viewMenu.addItem(
        withTitle: localized("Command Palette…"),
        action: #selector(AppDelegate.toggleCommandPalette(_:)),
        command: .commandPalette
    )
    viewMenu.addItem(.separator())
    // iTerm2's split shortcuts: ⌘D right, ⌘⇧D down. The new pane opens a plain
    // terminal in the focused session's project (see `splitSelectedPane`).
    viewMenu.addItem(
        withTitle: localized("Split Right"),
        action: #selector(AppDelegate.splitPaneRight(_:)),
        command: .splitRight
    )
    viewMenu.addItem(
        withTitle: localized("Split Left"),
        action: #selector(AppDelegate.splitPaneLeft(_:)),
        command: .splitLeft
    )
    viewMenu.addItem(
        withTitle: localized("Split Down"),
        action: #selector(AppDelegate.splitPaneDown(_:)),
        command: .splitDown
    )
    viewMenu.addItem(
        withTitle: localized("Split Up"),
        action: #selector(AppDelegate.splitPaneUp(_:)),
        command: .splitUp
    )
    // ⌘⇧↩ maximises the focused pane (tmux/iTerm2 zoom), toggling back to the split.
    viewMenu.addItem(
        withTitle: localized("Zoom Split"),
        action: #selector(AppDelegate.toggleSplitZoom(_:)),
        command: .splitZoom
    )
    // Ungroup peels the focused *pane* out of the layout — the session survives
    // in the sidebar. Ending the session is ⌘W (File ▸ Close Session), and the
    // whole window is ⌘⇧W (File ▸ Close Window).
    viewMenu.addItem(
        withTitle: localized("Ungroup"),
        action: #selector(AppDelegate.ungroupPane(_:)),
        command: .ungroup
    )
    viewMenu.addItem(.separator())
    // ⌥⌘ arrows move focus between panes, scored on the split geometry.
    for (command, action) in [
        (KeyCommandID.focusPaneLeft, #selector(AppDelegate.focusPaneLeft(_:))),
        (.focusPaneRight, #selector(AppDelegate.focusPaneRight(_:))),
        (.focusPaneUp, #selector(AppDelegate.focusPaneUp(_:))),
        (.focusPaneDown, #selector(AppDelegate.focusPaneDown(_:))),
    ] {
        viewMenu.addItem(
            withTitle: KeyCommandCatalog.info(command).title,
            action: action,
            command: command
        )
    }
    viewMenu.addItem(.separator())
    // Mirrors Xcode's inspector shortcut (⌥⌘0) for the trailing file-tree panel.
    viewMenu.addItem(
        withTitle: localized("Show Project Files"),
        action: #selector(AppDelegate.toggleFilesInspector(_:)),
        command: .toggleProjectFiles
    )
    viewMenu.addItem(.separator())
    // Safari-style terminal font size: ⌘= bigger, ⌘- smaller, ⌘0 default. Drives
    // the persisted Appearance font size (ghostty's own binds are unbound in the
    // surface — see `applyAppearance`) so it survives relaunch and all panes match.
    viewMenu.addItem(
        withTitle: localized("Increase Font Size"),
        action: #selector(AppDelegate.increaseFontSize(_:)),
        command: .increaseFontSize
    )
    viewMenu.addItem(
        withTitle: localized("Decrease Font Size"),
        action: #selector(AppDelegate.decreaseFontSize(_:)),
        command: .decreaseFontSize
    )
    viewMenu.addItem(
        withTitle: localized("Reset Font Size"),
        action: #selector(AppDelegate.resetFontSize(_:)),
        command: .resetFontSize
    )
    viewMenu.addItem(.separator())
    // "Toggle Full Screen", not "Enter/Exit Full Screen": AppKit manages an item
    // carrying either reserved title (or `NSWindow.toggleFullScreen(_:)`) and
    // rewrites its key equivalent to the system shortcut. See
    // `toggleFullScreenCommand`.
    let fullScreenItem = viewMenu.addItem(
        withTitle: localized("Toggle Full Screen"),
        action: #selector(AppDelegate.toggleFullScreenCommand(_:)),
        keyEquivalent: "f"
    )
    fullScreenItem.keyEquivalentModifierMask = [.control, .command]
    viewItem.submenu = viewMenu

    // Session menu — Chrome's Tab menu for termio's own navigation unit: the
    // cycling verbs up top, then a live jump list of every open session grouped
    // by project. Filled on open by the AppDelegate (see `fillSessionMenu`);
    // an empty delegate-filled menu still resolves ⌘⇧]/⌘⇧[, because AppKit
    // runs `menuNeedsUpdate` during its key-equivalent sweep too.
    let sessionItem = NSMenuItem()
    mainMenu.addItem(sessionItem)
    let sessionMenu = NSMenu(title: localized("Session"))
    sessionMenu.delegate = NSApp.delegate as? AppDelegate
    sessionItem.submenu = sessionMenu

    // Window menu — the standard one every Mac app has and termio didn't, which is
    // why ⌘M did nothing. These actions travel the responder chain to whichever
    // window is key (Settings included), so they need no delegate plumbing.
    // Handing the menu to `NSApp.windowsMenu` lets AppKit keep its window list in it.
    let windowItem = NSMenuItem()
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: localized("Window"))
    windowMenu.addItem(
        withTitle: localized("Minimize"),
        action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"
    )
    windowMenu.addItem(
        withTitle: localized("Zoom"),
        action: #selector(NSWindow.performZoom(_:)),
        keyEquivalent: ""
    )
    windowMenu.addItem(.separator())
    windowMenu.addItem(
        withTitle: localized("Bring All to Front"),
        action: #selector(NSApplication.arrangeInFront(_:)),
        keyEquivalent: ""
    )
    windowItem.submenu = windowMenu
    NSApp.windowsMenu = windowMenu

    return mainMenu
}

