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
    // The split controller (sidebar + terminal + inspector). The navigator toggle reaches its
    // `toggleSidebar(_:)` through the responder chain, so this is just a weak handle on the
    // window's content view controller.
    private weak var splitViewController: NSSplitViewController?
    // The trailing file-browser inspector item, retained so the toolbar button and the
    // View menu can collapse/expand it. Starts collapsed (see `makeContentSplitViewController`).
    private var filesInspectorItem: NSSplitViewItem?
    // The leading sidebar item, retained so the sidebar's own toolbar actions (sort + new-terminal)
    // can ride with it — inserted when the navigator opens, stripped when it collapses.
    private weak var sidebarSplitItem: NSSplitViewItem?
    // KVO on the sidebar's collapse state, so every collapse path (toolbar toggle, View menu,
    // divider drag) empties/refills the sidebar's toolbar region (see `setNavigatorItemsVisible`).
    private var sidebarCollapseObserver: NSKeyValueObservation?
    // KVO on the inspector's collapse state, mirrored onto `store.inspectorVisible` so
    // hosted panes (the git pane's auto-refresh) can stand down while hidden.
    private var inspectorCollapseObserver: NSKeyValueObservation?
    // KVO on the window's effective appearance, so a *system-driven* light↔dark flip (macOS auto
    // day/night, Control Center) re-resolves the window background. In `.system` appearance mode
    // nothing else re-runs `applyWindowTransparency` on an OS flip — the settings never change —
    // so the statically-resolved `window.backgroundColor` would stay frozen at the old side while
    // the translucent sidebar material (which blends over it) shows the stale color and libghostty
    // repaints the terminal to the new side. That mismatch is the light-sidebar-over-dark-terminal
    // glitch. Re-applying here keeps the window background tracking the OS.
    private var appearanceObserver: NSKeyValueObservation?
    // The window's real toolbar delegate (must be retained); it carries the native
    // sidebar toggle (see `installToolbar`).
    private var toolbarDelegate: MainToolbarDelegate?
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
    // Previous maximize state, so the observer re-binds the tracking separator on the restore
    // transition (handing the host back relayouts the inspector) and not every tick.
    private var detailWasMaximized = false
    // Whether `DetailHost.shared` is currently parented here, covering the content area, rather
    // than docked in the inspector's slot.
    private var detailMaximized = false
    // The full-window pins, held so they can be dropped when the host goes back to the inspector.
    private var maximizedDetailConstraints: [NSLayoutConstraint] = []
    // Whether maximizing is what collapsed the navigator, so restoring re-opens only a sidebar
    // this mode closed — never one the user had already put away.
    private var sidebarCollapsedForMaximize = false
    // Coalesces the per-frame `windowDidResize` stream into a single settle so the inspector's
    // max thickness (and the tracking-separator re-bind it forces) is recomputed once the drag
    // stops, not on every intermediate frame.
    private var inspectorResizeSettle: DispatchWorkItem?
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
    private var termiodImagePaste: TermiodImagePaste?
    // The pane drag-to-rearrange gesture (issue #183); owns its
    // mouse monitors for the app's lifetime.
    private var paneDragRearrange: PaneDragRearrange?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        // Ask the device the last run ended on what is running on it, before any
        // pane mounts — the sidebar draws that answer, and a session that did not
        // survive is a tombstone rather than a silently missing row.
        store.refreshDeviceSessions()
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
        // Stock window chrome, NetNewsWire-style: a normal system toolbar with the native
        // title + subtitle (showing the session's path and git branch), the native sidebar
        // toggle, and `.fullSizeContentView` letting the sidebar's vibrant material run up
        // behind the traffic lights. No custom title-bar painting. `.automatic` toolbar style
        // splits the bar at the sidebar divider rather than painting one flat unified band.
        // Hide the native title. CodeEdit's recipe renders the folder name + git branch as a
        // custom borderless toolbar item (the branch picker, see `MainToolbarDelegate`) rather
        // than the system title/subtitle, so the toolbar band takes the terminal background
        // cleanly with no mismatched grey title strip. `window.title` is still kept current (for
        // the Window menu and Mission Control) but is not drawn while a toolbar is shown.
        window.titleVisibility = .hidden
        // Let the per-split-item separator styles decide where a hairline shows (CodeEdit's
        // approach: sidebar defers to the system default, terminal `.line`). The window-level
        // `.automatic` defers to those, so the sidebar stays seamless while the terminal gets a
        // clean bounding line — and the tracking separator no longer glares as a black bar in
        // fullscreen. The toolbar style itself is set in `installToolbar` (version-branched).
        window.titlebarSeparatorStyle = .automatic
        // Drive the split with a real AppKit `NSSplitViewController` whose first item
        // has `.sidebar` behavior — NetNewsWire's architecture. This is the *only* way to
        // get the native full-height sidebar (vibrant material running up behind the
        // traffic lights, the toggle, the title-bar tracking separator). A SwiftUI
        // `NavigationSplitView` only gets that treatment as the root of a `WindowGroup`
        // scene; hosted inside a manual `NSWindow` it renders as an embedded
        // representable with no connection to the title bar, so the sidebar can never
        // reach behind the traffic lights. SwiftUI still renders each pane's contents.
        window.contentViewController = makeContentSplitViewController()
        window.delegate = self
        window.center()
        window.setFrameAutosaveName(Self.mainWindowFrameAutosaveName)
        window.makeKeyAndOrderFront(nil)
        applyWindowTransparency()
        applyChromeAppearance()
        updateInspectorMaxThickness()
        // The autosaved frame can restore straight into fullscreen, so seed the mirror rather
        // than waiting for a transition that already happened.
        store.windowIsFullScreen = window.styleMask.contains(.fullScreen)
        installToolbar()
        // Empty the sidebar's toolbar region (sort + new-terminal) whenever the navigator collapses
        // and restore it when it reopens — the sidebar's own buttons ride with the sidebar, the way
        // Finder/Xcode drop theirs. KVO catches every collapse path (toolbar toggle, View menu,
        // divider drag). No `.initial`: the launch-time sync below runs after the autosave restore.
        sidebarCollapseObserver = sidebarSplitItem?.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            MainActor.assumeIsolated {
                self?.setNavigatorItemsVisible(!collapsed)
                // A maximized detail reaches the window's leading edge only while the sidebar is
                // collapsed; that's when its header has to clear the traffic lights — and when the
                // toolbar has nothing left to carry.
                self?.store.sidebarVisible = !collapsed
                self?.syncMaximizedChrome()
            }
        }
        // Mirror the inspector's live collapse state onto the store, so panes it hosts
        // can idle while hidden (a collapsed item keeps its view hierarchy alive — the
        // git pane's watcher would otherwise keep spawning `git status` unseen). KVO
        // catches every collapse path; `.initial` seeds the restored autosave state.
        inspectorCollapseObserver = filesInspectorItem?.observe(
            \.isCollapsed, options: [.initial, .new]
        ) { [weak self] item, _ in
            let visible = !item.isCollapsed
            MainActor.assumeIsolated {
                guard let store = self?.store, store.inspectorVisible != visible else { return }
                store.inspectorVisible = visible
            }
        }
        // Re-resolve the window background whenever the OS flips light↔dark under `.system` mode
        // (see `appearanceObserver`). Pinned Light/Dark modes never see the effective appearance
        // change out from under them, so this is a no-op there; re-applying is idempotent and
        // can't loop (it changes no appearance-affecting property).
        appearanceObserver = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyWindowTransparency() }
        }
        // After the split view has restored its autosaved collapse state, match the toolbar pane
        // switch to whether the inspector actually came up open or closed, and the sidebar region to
        // whether the navigator came up open or collapsed.
        DispatchQueue.main.async { [weak self] in
            self?.syncInspectorSwitch()
            self?.syncNavigatorItems()
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
                MainActor.assumeIsolated {
                    self?.revealInspectorForDetail()
                    // Revealing relayouts around divider 1, which can leave the tracking separator
                    // inert (the centered-tabs / missing-divider glitch). Re-bind once it settles.
                    DispatchQueue.main.async { [weak self] in self?.reassertInspectorSeparator() }
                }
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
        // header now (see `InspectorDetailChromeButtons`), not the toolbar — so this observer only
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
        termiodImagePaste = TermiodImagePaste(store: store)
        terminalContextMenu = TerminalContextMenu(store: store, imagePaste: termiodImagePaste)
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

    /// Builds the window's content: an `NSSplitViewController` with a native sidebar item
    /// and a detail item, each hosting its SwiftUI view. `sidebarWithViewController` is what
    /// gives the leading column the full-height vibrant `.sidebar` material behind the traffic
    /// lights and the title-bar tracking separator. The panes no longer bridge their toolbars —
    /// the window owns a real `NSToolbar` (see `installToolbar`) so it can carry the native
    /// `.toggleSidebar` item. The standard `toggleSidebar(_:)` responder action collapses the item.
    private func makeContentSplitViewController() -> NSSplitViewController {
        let sidebar = NSHostingController(rootView: SidebarView()
            .environmentObject(store)
            .environmentObject(settings))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // The sidebar's toolbar region must hold the traffic lights, the navigator toggle, and
        // (while open) the sort pull-down + new-terminal button; below ~240 the trailing `+`
        // falls out of the section and floats over the content.
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        self.sidebarSplitItem = sidebarItem
        // CodeEdit's recipe: the divider hairline under the toolbar is owned per split item,
        // not by the window. Pre-macOS 26, the sidebar needs `.none` to stop the sidebar
        // tracking separator from rendering its line as a black bar in fullscreen; on macOS 26
        // the system default already draws seamlessly, so (like CodeEdit's `makeNavigator`) we
        // leave it untouched there.
        if #unavailable(macOS 26) {
            sidebarItem.titlebarSeparatorStyle = .none
        }

        let detail = NSHostingController(rootView: TerminalPane()
            .environmentObject(store)
            .environmentObject(settings))
        // Fill the split pane; don't size the window to the SwiftUI content. `NSHostingController`
        // defaults `sizingOptions` to `.preferredContentSize`, which publishes the tree's *ideal*
        // size as `preferredContentSize`; `NSSplitViewController` propagates that to the window. So
        // with no session the compact `ContentUnavailableView` empty state pinned the window height
        // (width stayed free because the sidebar/split governs it). Clearing the options lets the
        // pane stretch and leaves the window frame to `contentMinSize` — same fix as
        // `FileBrowserHostingController`.
        detail.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detail)
        // The toolbar is sectioned by tracking separators, so each pane must stay at least as
        // wide as its toolbar items — the content section carries the branch-picker title.
        // Without a floor here the terminal pane absorbs every squeeze and the title slides
        // across the separators, floating over the neighbouring panes' content (the titlebar is
        // transparent full-size-content, so overflow is painted straight onto content pixels).
        // With a floor, shrinking the window past the sum of minimums collapses the collapsible
        // side panes instead, the native Xcode behaviour.
        detailItem.minimumThickness = 280
        // `.line` only over the terminal: a clean hairline that starts at the sidebar divider
        // and bounds the title strip like Xcode, without bleeding across the sidebar.
        detailItem.titlebarSeparatorStyle = .line

        // The trailing file-tree column is a PLAIN content item (like the terminal), not a
        // `.sidebar`/`.inspector` panel item. macOS 26 gives panel items a Liquid Glass inset in
        // fullscreen (a border/margin on the top, right and bottom); a plain item sits fully flush
        // to the window edges, with only the split divider on its leading edge as a border. The
        // panel items' vibrant material is reproduced by hand inside `FileBrowserHostingController`
        // (a `.sidebar` effect view behind a transparent list), so it still matches the leading
        // sidebar. It starts collapsed — the tree is summoned via the toolbar toggle.
        let inspector = FileBrowserHostingController(store: store, settings: settings)
        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 260
        // Max width tracks the window: the inspector can grow to the golden ratio of the
        // content width (`updateInspectorMaxThickness`), never below the 420pt floor. A fixed
        // cap felt cramped on wide windows when reading a diff or a wide file in the inspector.
        inspectorItem.maximumThickness = 420
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true
        self.filesInspectorItem = inspectorItem

        let splitViewController = NSSplitViewController()
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)
        splitViewController.addSplitViewItem(inspectorItem)
        splitViewController.splitView.autosaveName = "TermioContentSplit"
        self.splitViewController = splitViewController
        return splitViewController
    }

    /// Keeps the native window title in step with the selected session's working directory.
    /// The title is hidden in the toolbar (`titleVisibility = .hidden`) — the folder name and
    /// git branch are drawn by the custom branch-picker toolbar item instead (CodeEdit's
    /// pattern) — so this only feeds the Window menu and Mission Control. The path is the
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
        // Make the titlebar transparent so the window background (the terminal color, set
        // just above) shows straight through the title-bar band instead of AppKit's stock
        // grey chrome material — the seam that otherwise leaves the title/subtitle sitting
        // on a mismatched lighter band. The sidebar's vibrant material still wins on the
        // leading column; this only affects the detail (terminal) side.
        //
        // EXCEPT in fullscreen: on macOS 26 the fullscreen title-bar host doesn't honor a
        // transparent titlebar — it composites a light Liquid Glass material, which read as a
        // white band over a dark terminal. Turning transparency off in fullscreen lets the
        // toolbar fall back to the window's own (dark) titlebar material, which tracks the
        // appearance and matches the terminal far better. Windowed keeps the seamless look.
        window.titlebarAppearsTransparent = !window.styleMask.contains(.fullScreen)
    }

    /// The terminal background color flattened to a static color for the window's current
    /// effective appearance. `AppSettings.terminalBackgroundColor` is a dynamic color that picks
    /// light/dark per drawing context; the window (and especially its fullscreen title-bar
    /// overlay) needs a fixed color so it can't resolve to the wrong side.
    private func resolvedTerminalBackground() -> NSColor {
        let dynamic = settings.terminalBackgroundColor
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
        updateInspectorMaxThickness()
        store.windowIsFullScreen = false
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
        // `windowDidResize` fires every frame of a live drag. Re-setting `maximumThickness` (and the
        // separator re-bind it triggers) on each frame both wastes layout and repeatedly disturbs the
        // tracking separator mid-drag. Coalesce to a single update once the drag settles.
        inspectorResizeSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.updateInspectorMaxThickness() }
        }
        inspectorResizeSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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

    /// Lets the right inspector grow with the window: its max width is the golden ratio (0.618)
    /// of the current content width, floored at 420pt so it never shrinks below the old fixed cap
    /// on narrow windows. A static `maximumThickness` capped the inspector at 420pt regardless of
    /// window size, which felt small when the inspector held a diff or a wide file on a large display.
    private func updateInspectorMaxThickness() {
        guard let item = filesInspectorItem, let window else { return }
        let contentWidth = window.contentLayoutRect.width
        let newMax = max(420, (contentWidth * 0.618).rounded(.down))
        guard item.maximumThickness != newMax else { return }
        item.maximumThickness = newMax
        // Changing the max can pull divider 1 in (when the inspector was pinned at the old cap),
        // which leaves `.inspectorTrackingSeparator` inert — so the tab switch drifts to center. Only
        // an issue while the inspector is open; the reassert no-ops otherwise. Deferred so it runs
        // against the settled geometry.
        DispatchQueue.main.async { [weak self] in self?.reassertInspectorSeparator() }
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

    /// Installs a real `NSToolbar` carrying CodeEdit's chrome: a leading navigator toggle, the
    /// system sidebar tracking separator, the custom branch-picker title, an inner tracking
    /// separator aligned to the inspector divider, and a trailing inspector toggle. The delegate
    /// holds the split controller (to bind the inner separator to divider 1) and the store +
    /// settings (to host the branch picker). Toolbar style is version-branched the way CodeEdit
    /// does it: `.automatic` on macOS 26, `.unifiedCompact` before. The baseline separator is
    /// dropped so only the per-split-item separators decide where a hairline shows.
    private func installToolbar() {
        guard let window else { return }
        let delegate = MainToolbarDelegate(store: store, settings: settings, splitViewController: splitViewController)
        toolbarDelegate = delegate
        let toolbar = NSToolbar(identifier: "TermioMainToolbar")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        // The chrome is fixed, so the right-click menu had nothing to offer but a
        // labelled variant of icons the window is laid out around.
        if #available(macOS 15, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        if #available(macOS 26, *) {
            window.toolbarStyle = .automatic
        } else {
            window.toolbarStyle = .unifiedCompact
        }
        window.toolbar = toolbar
    }

    /// Opens (or refocuses) the preferences window. Reached via the responder
    /// chain from the menu item, which targets `nil`. The window is kept alive
    /// (not released on close) so reopening preserves nothing-to-rebuild state.
    /// ⌘, lands on whatever tab the user last had open (the platform convention
    /// — Safari, Xcode), falling back to the first tab on a fresh install;
    /// deep-linked opens (`openSettings(initialTab:)`) still pick their own.
    @objc func showSettings(_ sender: Any?) {
        let remembered = UserDefaults.standard.string(forKey: SettingsTab.lastOpenKey)
            .flatMap(SettingsTab.init(rawValue:))
        openSettings(initialTab: remembered ?? .general)
    }

    /// Opens this Mac's Serving section, where the pairing QR lives (RFC §D9).
    ///
    /// The QR moved off a top-level tab and onto the machine that serves it,
    /// which is correct and two clicks deeper. §D9 says the discoverability is
    /// paid back here rather than by a duplicate settings entry: **pairing is an
    /// action**, so it belongs in the command palette, not in the sidebar.
    @objc func pairPhone(_ sender: Any?) {
        openSettings(initialTab: .devices, initialDevice: KnownDevice.thisMac.settingsKey)
    }

    /// Opens (or refocuses) the preferences window on a specific tab. The content
    /// view is rebuilt each call so the requested tab takes effect even when the
    /// window is reused — harmless because every control binds straight to
    /// `AppSettings`, so there is no transient UI state to preserve.
    func openSettings(initialTab: SettingsTab, initialDevice: String? = nil) {
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
            initialDevice: initialDevice,
            onSSHConnect: { [weak self] host in
                guard let self else { return }
                self.store.addSSHSession(host: host)
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

    /// A row of the New Chat agents submenu (File menu and the toolbar `+` share it —
    /// see `menuNeedsUpdate`) — starts one scratch chat with the picked agent, carried
    /// in `representedObject` by id. The row for the resolved default also holds the
    /// ⌘N binding, so the shortcut keeps opening your last-used agent.
    @objc func newChatAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let agent = enabledAgentPresets(settings).first(where: { $0.id == id })
        else { return }
        store.addScratchSession(agent: agent)
    }

    /// A host row of the New SSH Connection submenu (File menu and the toolbar `+`
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
    /// submenu's row, the toolbar `+`'s last row — and the This Mac row of the
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

    /// View ▸ Show Project Files (and the toolbar's trailing inspector button) —
    /// collapses or expands the file-tree inspector. Reached via the responder chain
    /// (the menu item and toolbar item both target `nil`), like the other app actions.
    @objc func toggleFilesInspector(_ sender: Any?) {
        guard let item = filesInspectorItem else { return }
        let willOpen = item.isCollapsed
        item.animator().isCollapsed = !willOpen
        setInspectorSwitchVisible(willOpen)
        // On expand the switch + separator are inserted while the divider is still mid-slide, so the
        // separator binds against unsettled geometry and can land inert (tabs drift to center). Re-bind
        // once the collapse animation finishes. Nothing to align on collapse (the switch is gone).
        if willOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.reassertInspectorSeparator()
            }
        }
    }

    /// Matches the toolbar's pane switch to the inspector's *actual* collapse state — called once at
    /// launch, after the split view has restored from its autosave, so a restored-open inspector
    /// shows the switch and a restored-closed one does not (no stale mirror state to desync).
    func syncInspectorSwitch() {
        guard let item = filesInspectorItem else { return }
        setInspectorSwitchVisible(!item.isCollapsed)
    }

    /// Drives the pane switch's visibility from its two masters at once: the inspector must be open
    /// *and* not maximized. A maximized detail covers the list column the switch re-aims, so the tabs
    /// would act on something off-screen — pull them while maximized, restore them on the way back
    /// down. Idempotent (`setInspectorSwitchVisible` no-ops when already in the target state), so the
    /// overlay observer can call it on every store change.
    func syncInspectorTabsVisibility(maximized: Bool) {
        guard let item = filesInspectorItem else { return }
        setInspectorSwitchVisible(!item.isCollapsed && !maximized)
    }

    /// Inserts or removes the inspector pane switch as the panel opens/closes, so it is shown only
    /// while there is something to switch between. The tracking separator (which pins the switch to
    /// the inspector's left edge) is inserted and removed *with* the switch — otherwise it draws a
    /// stray vertical divider line in the toolbar while the inspector is collapsed. When open the
    /// order is `… branchPicker, flex, [separator, switch, flex], toggle`.
    private func setInspectorSwitchVisible(_ visible: Bool) {
        guard let toolbar = window?.toolbar else { return }
        func index(of id: NSToolbarItem.Identifier) -> Int? {
            toolbar.items.firstIndex { $0.itemIdentifier == id }
        }
        // Mutate the toolbar with animation OFF. `insertItem`/`removeItem` otherwise run NSToolbar's
        // own fade/scale "pop" on a clock that is independent of the split view's `animator()` slide
        // — so the Files/Changes pills popped in on a different curve and speed than the inspector
        // pane (and its File/Diff list) slid. Suppressing the toolbar animation makes the switch
        // simply *present* for the whole slide (Xcode's inspector-control behaviour), leaving the
        // pane slide as the single, coherent motion.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }
        if visible {
            guard index(of: .inspectorTabs) == nil, let toggle = index(of: .toggleInspector) else { return }
            // Insert in reverse at the toggle's index so the final order is separator, switch, flex.
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: toggle)
            toolbar.insertItem(withItemIdentifier: .inspectorTabs, at: toggle)
            toolbar.insertItem(withItemIdentifier: .inspectorTrackingSeparator, at: toggle)
        } else {
            // Only clean up when the switch is actually present — otherwise (e.g. at launch with the
            // inspector already collapsed) there is nothing paired to remove, and stripping the
            // default trailing flexible space would yank the collapse button off the right edge.
            guard let tabsIdx = index(of: .inspectorTabs) else { return }
            toolbar.removeItem(at: tabsIdx)
            if let i = index(of: .inspectorTrackingSeparator) { toolbar.removeItem(at: i) }
            // Drop the flexible space that was paired with the switch (the one just before the toggle).
            if let toggle = index(of: .toggleInspector), toggle > 0,
               toolbar.items[toggle - 1].itemIdentifier == .flexibleSpace {
                toolbar.removeItem(at: toggle - 1)
            }
        }
    }

    /// Removes and re-inserts the inspector's tracking separator so it re-binds to divider 1 against
    /// the *current, settled* geometry. `NSTrackingSeparatorToolbarItem` is flaky under termio's
    /// translucent, `titlebarAppearsTransparent` titlebar — mutating the toolbar or moving the divider
    /// (as opening a detail does) can leave it inert, so it stops splitting the toolbar into
    /// terminal/inspector regions and the tab switcher drifts to center with no divider line. A fresh
    /// item built when geometry is stable re-binds cleanly — the same cure as a manual inspector
    /// toggle, which is why toggling fixed the glitch. Deferred by the caller to a settled runloop.
    private func reassertInspectorSeparator() {
        guard let toolbar = window?.toolbar else { return }
        func index(of id: NSToolbarItem.Identifier) -> Int? {
            toolbar.items.firstIndex { $0.itemIdentifier == id }
        }
        // Only meaningful while the switch is present (inspector open); nothing to align otherwise.
        guard index(of: .inspectorTabs) != nil else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }
        if let sep = index(of: .inspectorTrackingSeparator) { toolbar.removeItem(at: sep) }
        // Re-find the tabs (index shifted after the removal) and slot the separator just before them.
        if let tabs = index(of: .inspectorTabs) {
            toolbar.insertItem(withItemIdentifier: .inspectorTrackingSeparator, at: tabs)
        }
    }

    /// Matches the sidebar's toolbar region to the navigator's *actual* collapse state — called once
    /// at launch after the split view has restored from autosave, the navigator twin of
    /// `syncInspectorSwitch` (so a restored-collapsed sidebar shows no sort/new buttons, a
    /// restored-open one shows them, with no stale mirror state to desync).
    func syncNavigatorItems() {
        guard let item = sidebarSplitItem else { return }
        setNavigatorItemsVisible(!item.isCollapsed)
        store.sidebarVisible = !item.isCollapsed
    }

    /// Inserts or removes the sidebar's own toolbar actions (the sort pull-down and the `+`
    /// new-terminal button) as the navigator opens/closes, so the sidebar's toolbar region empties
    /// when the sidebar is collapsed — matching Finder/Xcode, which drop their sidebar buttons with
    /// the sidebar, and freeing the horizontal room that otherwise forces NSToolbar's `»` overflow.
    /// The paired flexible space (which right-aligns the two against the sidebar divider) is inserted
    /// and removed *with* them. When open the region reads `toggleNavigator, flex, sortProjects,
    /// newTerminal | sidebarTrackingSeparator`. Mirrors `setInspectorSwitchVisible`.
    ///
    /// The workspace name leaves with the sidebar it labels, but it is not managed here — it rides
    /// inside the `toggleNavigator` item and hides itself on `store.sidebarVisible` (see
    /// `NavigatorToggleToolbarView`). It used to move across the tracking separator instead, on the
    /// argument that a bare terminal looks the same in every scope and the switcher is the only thing
    /// naming the current one. In practice it reads as a stray word beside the window title — the
    /// sidebar's region empties with the sidebar, the way Finder's and Xcode's do, and the workspace
    /// is still one click away through the sidebar or the Workspace menu.
    private func setNavigatorItemsVisible(_ visible: Bool) {
        guard let toolbar = window?.toolbar else { return }
        func index(of id: NSToolbarItem.Identifier) -> Int? {
            toolbar.items.firstIndex { $0.itemIdentifier == id }
        }
        // Mutate with animation off, matching the inspector switch: the buttons simply present for
        // the sidebar's slide rather than running NSToolbar's own pop on an independent clock.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }
        if visible {
            guard index(of: .sortProjects) == nil else { return }
            guard let sep = index(of: .sidebarTrackingSeparator) else { return }
            // Insert in reverse at that one index so the final order is flex, sortProjects,
            // newTerminal. Re-reading the separator's index between inserts would walk it past the
            // items just added and land the space against the `+` instead.
            toolbar.insertItem(withItemIdentifier: .newTerminal, at: sep)
            toolbar.insertItem(withItemIdentifier: .sortProjects, at: sep)
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: sep)
        } else {
            // Only clean up when the buttons are actually present (nothing to remove at launch with
            // the sidebar already collapsed). Re-find each id after every removal — indices shift.
            guard let sortIdx = index(of: .sortProjects) else { return }
            toolbar.removeItem(at: sortIdx)
            if let i = index(of: .newTerminal) { toolbar.removeItem(at: i) }
            // Drop the flexible space that right-aligned them (the one just before the sidebar separator).
            if let sep = index(of: .sidebarTrackingSeparator), sep > 0,
               toolbar.items[sep - 1].itemIdentifier == .flexibleSpace {
                toolbar.removeItem(at: sep - 1)
            }
        }
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

    /// Reveals the inspector for a freshly opened detail: un-collapses it if hidden, and otherwise
    /// leaves its width alone. It comes back at whatever the split last had (the user's own width,
    /// restored from the autosave), and the responsive `InspectorRoot` — two-column when there's
    /// room, detail-only when narrow, draggable seam either way — takes it from there.
    ///
    /// It used to *grow* the inspector to ~half the window on every open. That shrank the terminal
    /// unbidden and, because the growth was a mid-layout `minimumThickness` bump, left the terminal a
    /// blank strip where the surface hadn't reflowed. Respect the user's width; let layout be
    /// responsive instead of forcing it.
    private func revealInspectorForDetail() {
        guard let item = filesInspectorItem else { return }
        // Un-collapse *synchronously* (not via `animator()`) so the split geometry — and the divider
        // the tracking separator binds to — is settled before the toolbar switch is (re)inserted.
        if item.isCollapsed {
            item.isCollapsed = false
            setInspectorSwitchVisible(true)
        }
    }

    /// Brings the window into or out of the maximized-detail mode. Idempotent, and reached from two
    /// clocks: synchronously as the maximize flag flips (so the host swaps with the docked detail in
    /// one frame) and from the deferred store observer (which catches the detail closing out from
    /// under a host that is already up).
    private func applyDetailMaximized(_ maximized: Bool) {
        let restored = detailWasMaximized && !maximized
        detailWasMaximized = maximized
        setDetailMaximized(maximized)
        // The pane switch (Files/Search/Changes/Issues/Info) re-aims the inspector's list column,
        // which the full-window detail now covers — so while maximized the tabs would act on
        // something off-screen. Pull them from the toolbar for the duration and restore them on the
        // way back down (the inspector is still open behind the host).
        syncInspectorTabsVisibility(maximized: maximized)
        // Tearing down the maximize host relayouts around divider 1, which can leave the tracking
        // separator inert (the centered-tabs / missing-divider glitch). Re-bind once layout settles.
        if restored {
            DispatchQueue.main.async { [weak self] in self?.reassertInspectorSeparator() }
        }
    }

    /// Moves the shared detail host between the inspector's slot and the whole content area — an
    /// in-window maximize, *not* native macOS fullscreen: the window stays put in its Space and the
    /// menu bar stays visible. The navigator collapses with it, so "fill the window" means the
    /// window rather than the window minus a column of chrome; re-open it (View menu) and the host
    /// slides with it, since its leading edge tracks the split. The toolbar goes with the sidebar
    /// (see `syncMaximizedChrome`); restore and close ride the detail's own header, and Esc still
    /// closes.
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
            // "Fill the window" means the whole window: the navigator steps aside with the toolbar
            // and comes back on restore. Leaving it up would keep a column of chrome beside a
            // detail the user just asked to blow up — and its own controls (workspace, sort, `+`)
            // live in the toolbar band that maximizing takes away.
            if sidebarSplitItem?.isCollapsed == false {
                sidebarCollapsedForMaximize = true
                sidebarSplitItem?.isCollapsed = true
            }
            syncMaximizedChrome()
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
            syncMaximizedChrome()
            // Uncovering the content area re-exposes the terminal, but a tickless surface won't
            // repaint itself — nudge it so a switch out of a maximized detail can't leave a blank.
            store.repaintSelectedSurface()
        }
    }

    /// Drops the toolbar only when a maximized detail owns the *whole* window — which is to say
    /// while the navigator is collapsed. Then the band carries nothing but the branch title and the
    /// inspector toggle, both meaningless over a full-window detail, and the detail's own header
    /// (name, Edit/Preview, restore, close) reads as a second bar under an empty one; hiding it
    /// leaves the bare titlebar strip the traffic lights live in, and the detail's header becomes
    /// the window's top bar. With the sidebar up the band is not spare chrome: the sidebar's own
    /// workspace / sort / `+` controls live in its region, and taking the toolbar would strip the
    /// sidebar of them for a mode that has nothing to do with it.
    ///
    /// Called on both the maximize transition and every sidebar collapse, so toggling the navigator
    /// under a maximized detail lands in the right state. Idempotent — it returns when the toolbar
    /// already matches, because re-asserting visibility churns the tracking separators.
    private func syncMaximizedChrome() {
        guard let window, let toolbar = window.toolbar else { return }
        let hidesToolbar = detailMaximized && sidebarSplitItem?.isCollapsed == true
        guard toolbar.isVisible == hidesToolbar else { return }
        toolbar.isVisible = !hidesToolbar
        // A hidden toolbar stops laying out, so its custom views come back measured against stale
        // bounds — the branch picker's two-line project/branch title drew clipped at the top.
        if !hidesToolbar {
            DispatchQueue.main.async { [weak self] in self?.toolbarDelegate?.relayoutBranchPicker() }
        }
        // Without the toolbar the detail's header occupies the strip the window was dragged by, and
        // a SwiftUI view swallows the mouse-down a titlebar drag needs. Dragging the background
        // restores it: only views that *don't* handle the event start the drag, so the header's
        // empty run moves the window while the document's own text keeps its selection drags.
        window.isMovableByWindowBackground = hidesToolbar
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

/// The "New Chat ▸" parent item shared by the File menu and the toolbar `+`
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
/// their menu opens: the File menu and the toolbar `+` each own one, and
/// everything around it has to survive the refresh, so the item is reconfigured
/// in place rather than the menu rebuilt.
enum DeviceMenuTag {
    static let newTerminal = 7301
    static let newTerminalAtHome = 7302
    static let connectTo = 7303
    static let newWorkspace = 7306
}

/// The "Workspace ▸" item — the scopes, with the current one checked, and where the
/// switch gets a keyboard chord. The toolbar switcher is the same menu in the chrome;
/// this one exists because a key equivalent only fires from the main menu, and because
/// a chord nobody can find is a chord nobody presses.
///
/// Always shown, including with a single workspace: the toolbar switcher collapses
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
    /// Connection, Connect to…. The File menu and the toolbar `+` instead hold a
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
        // rebuilt per open, but the toolbar `+` keeps its item across refreshes.
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
        // The same row the toolbar `+` carries: a plain verb on one machine, a
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
    /// cycling verbs need sessions to cycle, and the branch verbs a selected
    /// session inside a real git project. Every other action stays enabled,
    /// matching the pre-validation behavior.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(nextSession(_:)), #selector(previousSession(_:)):
            return !store.sidebarSessionGroups.isEmpty
        case #selector(newWorktree(_:)), #selector(newPullRequest(_:)):
            return currentBranchProject != nil
        default:
            return true
        }
    }
}

/// A borderless window can't become key by default, but the palette's search
/// field needs key status to type into — hence the one-line subclass.
private final class KeyBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Delegate for the window's real toolbar, mirroring CodeEdit's chrome. It declares a leading
/// navigator toggle, the AppKit-provided sidebar tracking separator (bound to the sidebar
/// divider), the custom branch-picker title item, and a trailing inspector toggle. The store and
/// settings drive the branch picker.
@MainActor
private final class MainToolbarDelegate: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private let store: TermioStore
    private let settings: AppSettings
    /// Used to build the inspector tracking separator, which pins the pane switch to the
    /// inspector's left edge (divider 1, between the terminal and the file column).
    private weak var splitViewController: NSSplitViewController?
    private weak var branchPickerHostingView: NSView?
    private var branchPickerWidthConstraint: NSLayoutConstraint?

    /// Holds the pane-frame observation token. Its removal lives in this bag's
    /// own deinit: the delegate's deinit is nonisolated in Swift 6 and cannot
    /// read main-actor state, but dropping the delegate drops the bag, which
    /// still unhooks the observer.
    private final class FrameObserverBag: @unchecked Sendable {
        var token: NSObjectProtocol?
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    private let frameObserver = FrameObserverBag()

    init(store: TermioStore, settings: AppSettings, splitViewController: NSSplitViewController?) {
        self.store = store
        self.settings = settings
        self.splitViewController = splitViewController
    }

    /// Lets the title use the room its toolbar section actually has, up to a generous ceiling.
    /// Keep a trailing reserve for the flexible space and transient overlay-close button. At the
    /// terminal pane's 280pt minimum this yields a safe 200pt title; wider panes can show much more.
    private var terminalPaneView: NSView? {
        guard let items = splitViewController?.splitViewItems, items.count > 1 else { return nil }
        return items[1].viewController.view
    }

    /// Re-measures the branch picker's custom view. A hidden toolbar stops laying out, so the
    /// hosting view's intrinsic size is stale when the band comes back (restoring from a maximized
    /// detail) and the two-line project/branch title draws against the wrong height — clipped at the
    /// top. Same three calls the pane-width observer makes; only the trigger differs.
    func relayoutBranchPicker() {
        branchPickerWidthConstraint?.constant = branchPickerWidthLimit()
        branchPickerHostingView?.invalidateIntrinsicContentSize()
        branchPickerHostingView?.superview?.needsLayout = true
    }

    private func branchPickerWidthLimit() -> CGFloat {
        guard let terminalView = terminalPaneView else {
            return BranchPickerToolbarView.titleWidthCeiling
        }
        return min(
            BranchPickerToolbarView.titleWidthCeiling,
            max(BranchPickerToolbarView.titleWidthFloor, terminalView.bounds.width - 80)
        )
    }

    private func observeTerminalPaneWidth() {
        guard let terminalView = terminalPaneView else { return }
        terminalView.postsFrameChangedNotifications = true
        if let token = frameObserver.token {
            NotificationCenter.default.removeObserver(token)
        }
        frameObserver.token = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: terminalView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.branchPickerWidthConstraint?.constant = self.branchPickerWidthLimit()
                self.branchPickerHostingView?.invalidateIntrinsicContentSize()
                self.branchPickerHostingView?.superview?.needsLayout = true
            }
        }
    }

    /// Builds the project-sort pull-down for the `.sortProjects` toolbar item: one
    /// entry per `ProjectSortOrder`, each setting `AppSettings.projectSortOrder`. The
    /// checkmark on the active order is refreshed on open via `menuNeedsUpdate`.
    func makeProjectSortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for order in ProjectSortOrder.allCases {
            let item = NSMenuItem(title: order.displayName, action: #selector(setProjectSortOrder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func setProjectSortOrder(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let order = ProjectSortOrder(rawValue: raw) else { return }
        settings.projectSortOrder = order
    }

    /// Builds the `+` pull-down for the `.newTerminal` toolbar item: the ways something
    /// new enters the sidebar without opening a folder — a loose terminal (Terminals
    /// section), a loose agent chat (Chats section), an SSH terminal, or a folder opened
    /// as a project. "New Chat" opens the user's agent roster and "New SSH Connection"
    /// the config's hosts as submenus (the same ones the File menu carries — see
    /// `makeNewChatItem` / `makeNewSSHItem`).
    ///
    /// Every entry here is context-free: nothing reads the selection, so the terminal
    /// entry is the `$HOME` one. The `+` lives in the sidebar's toolbar, where "here"
    /// has no referent — the directory-following New Terminal is ⌘T, pressed with the
    /// terminal in front of you.
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

    /// The `.inspectorTabs` item's menu form, shown in the toolbar's `»` overflow menu when the
    /// inspector section is too narrow to hold the glass cluster — the panes stay switchable
    /// while the cluster itself is hidden.
    func makeInspectorTabsMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: localized("Inspector Pane"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: localized("Inspector Pane"))
        menu.delegate = self
        let panes: [(tab: InspectorTab, title: String)] = [
            (.files, localized("Project Files")), (.search, localized("Search Files")),
            (.changes, localized("Changes")), (.info, localized("Info")),
        ]
        for pane in panes {
            let item = NSMenuItem(title: pane.title, action: #selector(setInspectorTab(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pane.tab
            menu.addItem(item)
        }
        menuItem.submenu = menu
        return menuItem
    }

    @objc private func setInspectorTab(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? InspectorTab else { return }
        store.inspectorTab = tab
    }

    // NSMenuDelegate — check the active entry each time a pull-down opens. Serves both menus:
    // sort items carry a `ProjectSortOrder` raw string, pane items an `InspectorTab`.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if let raw = item.representedObject as? String {
                item.state = raw == settings.projectSortOrder.rawValue ? .on : .off
            } else if let tab = item.representedObject as? InspectorTab {
                item.state = tab == store.inspectorTab ? .on : .off
            }
        }
    }

    // `.sidebarTrackingSeparator` is AppKit-provided simply by naming the system identifier;
    // AppKit builds it and binds it to the sidebar divider. The navigator/inspector toggles use
    // CodeEdit's symmetric `sidebar.leading`/`sidebar.trailing` glyphs, and the branch picker
    // sits in the content region right after the sidebar separator, so the title reads over the
    // terminal background. (CodeEdit also adds a second hand-built tracking separator over the
    // inspector divider; termio's inspector is a simple summoned file tree, and that item renders
    // as a filled block in this window setup, so it's left out — the toggle alone is enough.)
    // The baseline is everything-collapsed: navigator toggle, branch title, inspector toggle. Each
    // panel's own items are inserted by the app delegate only while that panel is open, because
    // carrying them in the default set has a visible cost either way — the inspector's pane switch
    // and tracking separator (`setInspectorSwitchVisible`) would draw a stray divider line over a
    // collapsed panel, and the sidebar's actions plus their flexible space
    // (`setNavigatorItemsVisible`) over-packed the row into NSToolbar's `»` overflow.
    private let defaultIdentifiers: [NSToolbarItem.Identifier] = [
        .toggleNavigator, .sidebarTrackingSeparator, .branchPicker, .flexibleSpace, .toggleInspector,
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultIdentifiers + [
            .sortProjects, .newTerminal, .inspectorTrackingSeparator, .inspectorTabs,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleNavigator:
            // Hand-drawn for the same reason as the inspector toggle it now mirrors (see
            // `NavigatorToggleToolbarView`): a native `isBordered` item wears its capsule in both
            // states, so the pill said nothing on this end of the toolbar while the trailing one
            // used it to mean "the pane is open".
            let item = NSToolbarItem(itemIdentifier: .toggleNavigator)
            item.label = localized("Navigator")
            item.toolTip = localized("Hide or show the navigator")
            let host = NSHostingView(rootView: NavigatorToggleToolbarView()
                .environmentObject(store)
                .environmentObject(settings))
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            item.isBordered = false
            // The view takes the click; the action is what AppKit reads to synthesize this
            // item's row in the `»` overflow menu and to validate it. A view-based item with
            // neither an action nor a `menuFormRepresentation` overflows into a dead row.
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            return item
        case .sortProjects:
            // A pull-down that sets how the sidebar orders projects (Recent Activity /
            // Name). Sits just left of the `+`, at the trailing edge of the sidebar's
            // toolbar region. Native `NSMenuToolbarItem` so it carries the standard
            // menu chevron and free Liquid Glass bordered look. It keeps that border
            // unconditionally where the pane toggles don't: this opens a menu, and a
            // menu is always available — their capsule says whether a pane is open.
            let item = NSMenuToolbarItem(itemIdentifier: .sortProjects)
            item.label = localized("Sort")
            item.toolTip = localized("Choose how projects are ordered")
            item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Sort projects")
            item.isBordered = true
            item.showsIndicator = true
            item.menu = makeProjectSortMenu()
            return item
        case .newTerminal:
            // Pinned to the trailing edge of the sidebar's toolbar region (just before the
            // tracking separator), so it reads as the navigator's own "new" action — like the
            // `+` at the foot of Finder's sidebar: a plain `+` that pops a menu on click. It
            // still carries a pull-down (the two ways something new enters the sidebar — a loose
            // terminal or a project), but with `showsIndicator = false` it keeps the exact width
            // of the single-action `+` it replaced, so the sidebar's `minimumThickness` (240)
            // stays valid and the button never grows the chevron that would push it toward the
            // NSToolbar `»` overflow. Finder's sidebar `+` shows no chevron either — a `+` reads
            // as "add" on its own, unlike the sort item, whose glyph does keep its indicator.
            let item = NSMenuToolbarItem(itemIdentifier: .newTerminal)
            item.label = localized("New")
            item.toolTip = localized("New terminal or project")
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New")
            item.isBordered = true
            item.showsIndicator = false
            item.menu = makeNewSessionMenu()
            return item
        case .inspectorTabs:
            // The inspector pane switch (Files / Search / Changes / Info), pinned to the inspector's
            // left edge by the tracking separator that precedes it in the item order. It's a
            // hand-drawn SwiftUI Liquid Glass segmented control (see `InspectorTabsToolbar`) rather
            // than a native `NSToolbarItemGroup`: over termio's transparent-over-terminal toolbar the
            // native control loses its track and reads as detached, selection-less glyphs, so we draw
            // our own track + sliding pill.
            let item = NSToolbarItem(itemIdentifier: .inspectorTabs)
            item.label = localized("Inspector")
            item.toolTip = localized("Switch between project files, search, changes, and info")
            // The switch's host also carries the terminal ‖ inspector seam, which the opaque
            // fullscreen title bar would otherwise cover (see `InspectorTabsItemView`). It rides
            // this item because this item is the one the tracking separator pins to the divider,
            // and because a seam item of its own would push the switch off that divider.
            item.view = InspectorTabsItemView(
                content: AnyView(InspectorTabsToolbar()
                    .environmentObject(store)
                    .environmentObject(store.settings)),
                splitView: splitViewController?.splitView)
            item.isBordered = false
            // First to overflow: the switch is incompressible, so when its section (the inspector
            // pane) gets too narrow it must yield to the `»` menu rather than slide over the divider
            // onto the pane's content. The menu form keeps the panes switchable while it's hidden.
            item.visibilityPriority = .low
            item.menuFormRepresentation = makeInspectorTabsMenuItem()
            return item
        case .inspectorTrackingSeparator:
            // Align a tracking separator to divider 1 (terminal | inspector) so the items after it
            // ride the inspector's left edge. AppKit needs the live split view to bind it.
            guard let splitView = splitViewController?.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: .inspectorTrackingSeparator,
                splitView: splitView,
                dividerIndex: 1
            )
        case .toggleInspector:
            // Hand-drawn (see `InspectorToggleToolbarView`) because this one button has to look
            // the same with and without its capsule; the trailing-sidebar glyph mirrors the
            // navigator toggle's leading one.
            let item = NSToolbarItem(itemIdentifier: .toggleInspector)
            item.label = localized("Inspector")
            item.toolTip = localized("Hide or show the inspector")
            let host = NSHostingView(rootView: InspectorToggleToolbarView().environmentObject(store))
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            item.isBordered = false
            // Kept for the overflow menu and validation, as on the navigator toggle above.
            item.action = #selector(AppDelegate.toggleFilesInspector(_:))
            return item
        case .branchPicker:
            let item = NSToolbarItem(itemIdentifier: .branchPicker)
            let hosting = NSHostingView(rootView: BranchPickerToolbarView()
                .environmentObject(store)
                .environmentObject(settings))
            // Give AppKit an explicit bound for its custom toolbar view. The constant follows the
            // terminal pane, so wide windows can use the generous ceiling while a narrow pane retains
            // enough trailing room for the rest of its toolbar section.
            hosting.translatesAutoresizingMaskIntoConstraints = false
            let widthConstraint = hosting.widthAnchor.constraint(lessThanOrEqualToConstant: branchPickerWidthLimit())
            widthConstraint.isActive = true
            branchPickerHostingView = hosting
            branchPickerWidthConstraint = widthConstraint
            observeTerminalPaneWidth()
            // A toolbar item does not clip its custom view for us. Keep the title inside this item's
            // measured bounds even if a future SwiftUI layout regression proposes an oversized glyph
            // run; the Text views still receive the bounded width and perform the visible ellipsis.
            hosting.clipsToBounds = true
            item.view = hosting
            item.isBordered = false
            return item
        default:
            // `.sidebarTrackingSeparator` and the spaces are provided and styled by AppKit.
            return nil
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let toggleNavigator = NSToolbarItem.Identifier("TermioToggleNavigator")
    static let sortProjects = NSToolbarItem.Identifier("TermioSortProjects")
    static let newTerminal = NSToolbarItem.Identifier("TermioNewTerminal")
    static let inspectorTabs = NSToolbarItem.Identifier("TermioInspectorTabs")
    static let toggleInspector = NSToolbarItem.Identifier("TermioToggleInspector")
    static let inspectorTrackingSeparator = NSToolbarItem.Identifier("TermioInspectorTrackingSeparator")
    static let branchPicker = NSToolbarItem.Identifier("TermioBranchPicker")
}

/// The inspector pane switch, plus the terminal ‖ inspector seam that an opaque title bar covers.
///
/// Windowed, nothing draws that seam: `.fullSizeContentView` runs the split view — dividers
/// included — up behind the chrome, and `titlebarAppearsTransparent` lets divider 1 read straight
/// through the toolbar band, so the line the user sees there *is* the content's own divider.
/// Fullscreen drops that transparency (macOS 26's fullscreen title-bar host composites a light
/// Liquid Glass band over a dark terminal otherwise — see `applyWindowTransparency`), and the
/// opaque band it falls back to paints over the divider: the seam stops at the toolbar's floor
/// while the content below still shows it.
///
/// A toolbar item is the only thing drawing *above* that band, so the hairline is hosted here
/// rather than added as an item of its own — a separate item would push the switch off the
/// divider by its own width plus the toolbar's inter-item spacing. It is a plain sublayer,
/// positioned from the split view's live geometry, so it can sit outside this view's bounds and
/// land on divider 1 at the band's full height. Auto Layout never sees it.
private final class InspectorTabsItemView: NSView {
    private let hosting: NSHostingView<AnyView>
    private let seam = CALayer()
    private weak var splitView: NSSplitView?

    init(content: AnyView, splitView: NSSplitView?) {
        self.hosting = NSHostingView(rootView: content)
        self.splitView = splitView
        super.init(frame: .zero)
        wantsLayer = true
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        // Pin on all four edges so the switch's own intrinsic width still drives the item's size —
        // the Issues segment comes and goes, and the toolbar has to re-measure when it does.
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layer?.addSublayer(seam)
        seam.isHidden = true
        // The window resizes on both fullscreen transitions, which relayouts this view — but the
        // title bar's opacity is what the seam keys off, and that is flipped separately (before the
        // enter animation, after the exit one). Re-place the line once each transition settles.
        // Target/selector rather than a block: the center keeps a zeroing weak reference to an
        // observer registered this way, so there is no token to tear down from a nonisolated deinit.
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(titleBarChromeDidChange), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func titleBarChromeDidChange() {
        needsLayout = true
    }

    /// A divider drag, a window resize and a fullscreen transition all reach this view as a frame
    /// change, and `layout()` alone only follows the size half of that.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        positionSeam()
    }

    /// Places the hairline on divider 1, spanning the title-bar band, in this view's coordinates —
    /// which puts it outside its own bounds, on the leading side, over the tracking separator's
    /// empty slot.
    private func positionSeam() {
        // No implicit fade as the line moves with the divider or blinks out on collapse.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let seamRect = seamRectInContentView(), let contentView = window?.contentView else {
            seam.isHidden = true
            return
        }
        seam.frame = convert(seamRect, from: contentView)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            seam.backgroundColor = NSColor.separatorColor.cgColor
        }
        seam.isHidden = false
    }

    /// The seam's rectangle in the content view's coordinates, or nil when there is nothing to
    /// draw: no inspector beside the terminal, or a title bar the divider already reads through.
    private func seamRectInContentView() -> NSRect? {
        guard let splitView, let window, let contentView = window.contentView,
              splitView.arrangedSubviews.count > 2 else { return nil }
        // Exactly when the band is opaque. Keying off transparency rather than off fullscreen keeps
        // this in step with `applyWindowTransparency`, and stops the line doubling the divider that
        // already shows through a transparent bar.
        guard !window.titlebarAppearsTransparent else { return nil }
        let inspector = splitView.arrangedSubviews[2]
        guard !inspector.isHidden, inspector.frame.width > 0 else { return nil }
        // The band is whatever `.fullSizeContentView` leaves above the layout rect. Zero means the
        // chrome is hidden (a fullscreen toolbar the pointer hasn't summoned), and the divider is
        // already visible for its whole height.
        let bandBottom = window.contentLayoutRect.maxY
        let bandHeight = contentView.bounds.maxY - bandBottom
        guard bandHeight > 0 else { return nil }
        let thickness = max(1, splitView.dividerThickness)
        let dividerX = splitView.convert(
            NSPoint(x: inspector.frame.minX - thickness, y: 0), to: contentView
        ).x
        return NSRect(x: dividerX, y: bandBottom, width: thickness, height: bandHeight)
    }
}

/// The custom title item: the selected session's folder name over its live git branch, drawn as
/// a borderless toolbar view in place of the native title (CodeEdit's `ToolbarBranchPicker`). It
/// observes the store directly, so it tracks the selection and branch without a separate
/// observer. A non-git folder shows just the folder name with a settings-folder glyph.
private struct BranchPickerToolbarView: View {
    @EnvironmentObject var store: TermioStore
    @Environment(\.controlActiveState) private var controlActive

    /// The title grows naturally with its contents, up to 460pt in a wide terminal pane. AppKit
    /// lowers the live limit when the pane narrows (see the `.branchPicker` toolbar item), at which
    /// point both lines use their middle ellipsis and retain the full strings in their tooltips.
    static let titleWidthFloor: CGFloat = 80
    static let titleWidthCeiling: CGFloat = 460

    /// The selected session's working directory: its worktree, its project folder, or — for a
    /// loose terminal, which owns its path — its live cwd. `nil` when nothing is selected.
    private var folder: String? {
        store.selectedSessionID.flatMap(store.titleFolder)
    }

    private var title: String {
        // An SSH terminal is titled by its host, not the local cwd it happens to have
        // launched from ($HOME) — matching how the sidebar labels the same row.
        if let host = store.selectedSessionID.flatMap(store.session)?.sshHost { return host }
        // Only a session with nowhere to name — a loose chat in its scratch directory —
        // falls back to the app's own name.
        guard let folder else { return "Termio" }
        return TermioStore.terminalLabel(forPath: folder)
    }

    private var branch: String? {
        // No local branch for a remote SSH session — its $HOME launch dir isn't the repo.
        guard store.selectedSessionID.flatMap(store.session)?.sshHost == nil else { return nil }
        guard let folder, let branch = store.branch(forFolder: folder), !branch.isEmpty else { return nil }
        return branch
    }

    private var primaryColor: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
    }

    private var secondaryColor: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title)
                if let branch {
                    Text(branch)
                        .font(.subheadline)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(branch)
                }
            }
        }
        // Keep short names at the established 80pt toolbar width and propose the same hard ceiling
        // that AppKit applies to the hosting view. Do not use negative padding here: it shrinks the
        // measured view without shrinking or moving the Text glyphs, allowing them to paint past the
        // toolbar item's trailing edge. Leading, not centered: a name shorter than the 80pt floor
        // would otherwise be centered inside it and a longer one drawn flush left, so the title's
        // left edge moved with every session switch. Pinned, it starts where the terminal text
        // below it does and only ever grows to the right.
        .frame(minWidth: Self.titleWidthFloor, maxWidth: Self.titleWidthCeiling, alignment: .leading)
    }
}

/// Both pane toggles — the navigator at the leading end of the toolbar, the inspector at the
/// trailing end — drawn by one view so the two ends can never disagree.
///
/// Hand-drawn rather than a native `isBordered` toolbar item because AppKit renders the two
/// states through different paths — bordered goes through `NSButton` (symbol scaled to the
/// capsule, `.labelColor`), unbordered through the plain toolbar-image path (the toolbar's own
/// image size and tint) — so flipping the border also changed the glyph's size and shade, and the
/// two buttons stopped matching. Owning the glyph pins it and leaves the capsule as the only
/// thing that changes.
///
/// Whether a capsule is drawn at all is the caller's to say, because the two sit on different
/// backdrops: the trailing button is over plain window chrome, where the capsule is what marks
/// the inspector as open; the leading one is over the sidebar's own vibrant material, where a
/// glass pill reads as a lump on the column rather than as state. It takes
/// `InspectorTabsToolbar`'s height and its `.regular` glass, which is already the pane switch's
/// answer to matching the native buttons.
private struct PaneToggleToolbarView: View {
    let symbol: String
    let showsCapsule: Bool
    /// Outer width. Defaults to the shared control height, which makes a capsuled button a circle.
    /// A button that never draws a capsule has nothing to fill that square with, and the slack
    /// only pushes whatever follows it further away — so the navigator toggle asks for less.
    var width: CGFloat = InspectorTabsToolbar.controlHeight
    let help: String
    let label: String
    let toggle: () -> Void

    @Environment(\.controlActiveState) private var controlActive
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol)
                // Sized by measurement, not by guess: at 15pt this drew a 17.5×13.5pt glyph
                // against the native bordered item it replaced (19.5×15.5), and the pair read
                // uneven across the toolbar. 17 matches it.
                .font(.system(size: 17))
                .foregroundStyle(controlActive == .inactive
                                 ? Color(nsColor: .disabledControlTextColor) : .primary)
                .frame(width: width, height: InspectorTabsToolbar.controlHeight)
                .background { if showsCapsule { capsuleBackground } }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var capsuleBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .capsule)
        } else {
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white)
        }
    }
}

/// Reports its own leading edge in the window, so a toolbar item can tell whether the toolbar has
/// already opened that edge past the traffic lights or has laid it flush.
///
/// AppKit moves the item without anything inside it changing, so there is nothing for SwiftUI's own
/// geometry to react to. Every ancestor's frame notification is watched instead — one of them is
/// the item the toolbar repositions.
private struct ToolbarItemLeadingReader: NSViewRepresentable {
    let report: (CGFloat) -> Void

    func makeNSView(context: Context) -> LeadingReaderView { LeadingReaderView(report: report) }

    func updateNSView(_ view: LeadingReaderView, context: Context) { view.report = report }

    final class LeadingReaderView: NSView {
        var report: (CGFloat) -> Void
        private var reported: CGFloat?

        init(report: @escaping (CGFloat) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watchAncestors()
            readLeadingEdge()
        }

        override func layout() {
            super.layout()
            readLeadingEdge()
        }

        private func watchAncestors() {
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
            var view: NSView? = self
            while let current = view {
                center.addObserver(
                    self,
                    selector: #selector(ancestorFrameChanged),
                    name: NSView.frameDidChangeNotification,
                    object: current
                )
                view = current.superview
            }
        }

        @objc private func ancestorFrameChanged(_ notification: Notification) {
            readLeadingEdge()
        }

        private func readLeadingEdge() {
            guard window != nil else { return }
            let leading = convert(bounds, to: nil).minX
            guard reported != leading else { return }
            reported = leading
            // The caller's state drives the layout this is being read from, so hand it back after
            // the pass rather than inside it.
            DispatchQueue.main.async { [report] in report(leading) }
        }
    }
}

/// The navigator toggle and, while the navigator is open, the name of the workspace the column
/// below is scoped to.
///
/// One toolbar item carrying both, rather than the two adjacent items this used to be: NSToolbar
/// spaces neighbouring items on its own terms, and between a button and the word naming the column
/// under it that spacing read as a gap neither control asked for — the name looked detached from
/// the button it sits beside. Hosted together, the distance is this view's to set.
///
/// The name draws only while the sidebar is open (it labels a column that has to be on screen) and
/// only while there is more than one workspace to be in — `WorkspaceSwitcherToolbarView` owns that
/// second rule, along with the menu the name pops.
private struct NavigatorToggleToolbarView: View {
    @EnvironmentObject var store: TermioStore

    /// Close enough to read as one control band with the button, still clear of the glyph. The
    /// toggle's own frame contributes a little more (it is wider than the symbol it draws), so the
    /// gap on screen is a few points past this.
    private static let nameSpacing: CGFloat = 6

    /// With nothing holding the toolbar's leading edge open the item lands flush against the window
    /// edge, several points left of everything in the column below. This inset puts the glyph's
    /// leading edge on the same line the section labels and rows start on (`sidebarLeadingTrim`
    /// pulls that column back to meet it), so the sidebar has one left margin rather than two.
    private static let flushLeadingInset: CGFloat = 10.5

    /// Past this, the traffic lights are on screen and the toolbar has already opened its leading
    /// edge past them — they end around 80pt in, where flush is around 10. Fullscreen has the item
    /// in both places (the buttons are hidden until the titlebar is summoned), so the inset can't
    /// key off `windowIsFullScreen`: adding it on top of the toolbar's own offset leaves a hole
    /// between the last button and the glyph.
    private static let trafficLightsClearance: CGFloat = 40

    /// The item's own leading edge in window coordinates, read from AppKit rather than assumed.
    /// `nil` until the first layout pass has been through.
    @State private var itemLeading: CGFloat?

    private var leadingInset: CGFloat {
        // Before the first reading, fall back to what the window can say for itself: windowed, the
        // buttons are always up.
        guard let itemLeading else { return store.windowIsFullScreen ? Self.flushLeadingInset : 0 }
        return itemLeading < Self.trafficLightsClearance ? Self.flushLeadingInset : 0
    }

    var body: some View {
        HStack(spacing: Self.nameSpacing) {
            toggle
            if store.sidebarVisible {
                WorkspaceSwitcherToolbarView()
            }
        }
        .padding(.leading, leadingInset)
        // After the padding, so the reader sits on the edge the toolbar gave the item rather than
        // on the one this view just moved.
        .background(alignment: .leading) {
            ToolbarItemLeadingReader { itemLeading = $0 }
        }
    }

    private var toggle: some View {
        PaneToggleToolbarView(
            // Never capsuled, open or collapsed. This button lives in the sidebar's own toolbar
            // region, over the vibrant `.sidebar` material and beside the traffic lights — a
            // glass pill there sits on the column instead of on the chrome. Hand-drawn all the
            // same, rather than an unbordered native item, because that path takes the toolbar's
            // own image size and tint and would stop matching the trailing button's glyph.
            symbol: "sidebar.leading",
            showsCapsule: false,
            // Tight to the glyph (19.5pt at this weight) rather than the capsuled button's square.
            // With the navigator collapsed the title lands right after this item, and the square's
            // trailing half was reading as a hole between the button and the name it belongs to.
            width: 26,
            help: localized("Hide or show the navigator"),
            label: localized("Navigator")
        ) {
            // `NSSplitViewController.toggleSidebar(_:)` collapses the first (sidebar) item with
            // the system animation. A `nil` target routes up the responder chain to the split
            // controller (the window's content view controller), so there is no action to write.
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
    }
}

/// The trailing inspector toggle: the same glyph in both states, wearing the glass capsule only
/// while the inspector is open. Closed, the button stands alone over the terminal, where a capsule
/// reads as a chip of chrome floating on the content; open, it is the right end of the row the
/// pane switch draws, and the shared capsule is what makes them one group.
private struct InspectorToggleToolbarView: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        PaneToggleToolbarView(
            symbol: "sidebar.trailing",
            showsCapsule: store.inspectorVisible,
            help: localized("Hide or show the inspector"),
            label: localized("Inspector")
        ) {
            NSApp.sendAction(#selector(AppDelegate.toggleFilesInspector(_:)), to: nil, from: nil)
        }
    }
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
    // Keeps the `+` new-terminal action reachable when the navigator is collapsed and its toolbar
    // button is hidden (see `setNavigatorItemsVisible`). ⌘T is safe: TUI programs drive off Ctrl,
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
    editMenu.addItem(withTitle: localized("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
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
