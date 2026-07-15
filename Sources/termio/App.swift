import AppKit
import Combine
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
    private var window: NSWindow!
    private let settings = AppSettings()
    private lazy var store = TermioStore.restored(settings: settings)
    private lazy var usageMonitor = UsageMonitor(settings: settings)
    private var menuBar: MenuBarController?
    private var companionServer: CompanionServer?
    private var settingsWindow: NSWindow?
    private var settingsObserver: AnyCancellable?
    /// Starts/stops the companion server + tunnel as the Mobile Access toggle flips.
    private var mobileAccessObserver: AnyCancellable?
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
    // Shows/hides the toolbar's overlay-close button as a file editor / diff / preview opens and
    // closes (see `setCloseOverlayVisible`).
    private var overlayObserver: AnyCancellable?
    // Whether the close button is currently in the toolbar, so the observer only mutates the
    // toolbar on an actual open↔closed transition rather than on every store change.
    private var closeOverlayShown = false
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sweep up session processes a previous instance stranded (crash,
        // force-quit, dev rebuild's kill -9) before this run adds its own.
        PTYProcess.reapStrayOrphans()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Termio"
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
        installToolbar()
        // Empty the sidebar's toolbar region (sort + new-terminal) whenever the navigator collapses
        // and restore it when it reopens — the sidebar's own buttons ride with the sidebar, the way
        // Finder/Xcode drop theirs. KVO catches every collapse path (toolbar toggle, View menu,
        // divider drag). No `.initial`: the launch-time sync below runs after the autosave restore.
        sidebarCollapseObserver = sidebarSplitItem?.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated { self?.setNavigatorItemsVisible(!item.isCollapsed) }
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
        titleObserver = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.updateWindowTitle() }
            }

        // Surface the overlay-close button in the toolbar while a file editor, diff, or preview
        // covers the terminal. `objectWillChange` fires before the value lands, so read the settled
        // state on the next runloop tick (the title observer's pattern).
        overlayObserver = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setCloseOverlayVisible(self.store.openFileURL != nil || self.store.openDiff != nil || self.store.openTrace != nil)
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

        terminalContextMenu = TerminalContextMenu(store: store)

        menuBar = MenuBarController(store: store) { [weak self] id in
            self?.store.selectedSessionID = id
            NSApp.activate(ignoringOtherApps: true)
            self?.window.makeKeyAndOrderFront(nil)
        }

        // Serve the iOS companion app: the live roster, plus PTY bridging for
        // any session the phone attaches to. Bound to localhost; a tunnel
        // fronts it for remote use.
        let companion = CompanionServer(
            rosterProvider: { [weak store] in
                store?.companionRoster() ?? CompanionRoster(projects: [])
            },
            ptyForSession: { [weak store] id in
                store?.companionPTY(for: id)
            },
            startSession: { [weak store] projectID, agent in
                store?.companionStartSession(projectID: projectID, agent: agent)
            },
            stopSession: { [weak store] sessionID in
                store?.companionStopSession(sessionID: sessionID) ?? false
            },
            traceProvider: { [weak store] sessionID in
                store?.companionTrace(for: sessionID)
            }
        )
        companionServer = companion
        // Mobile Access is the master switch: only serve (and resume the public
        // tunnel) when it's on. The token gate in the server is what makes
        // fronting it with a tunnel safe.
        if MobileAccess.shared.isEnabled {
            companion.start()
            TunnelManager.shared.startIfEnabled()
        }
        // React to the Settings toggle. `dropFirst` skips the value already
        // handled by the launch branch above, so we never double-start.
        mobileAccessObserver = MobileAccess.shared.$isEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let companion = self?.companionServer else { return }
                if enabled {
                    companion.start()
                    TunnelManager.shared.startIfEnabled()
                } else {
                    // Fully dark: drop live phones and kill the public URL.
                    companion.stop()
                    TunnelManager.shared.suspend()
                }
            }

        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            openProjects(at: urls)
        }

        maybePromptForSessionControl()
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
            alert.messageText = "Let your agents coordinate?"
            alert.informativeText = """
                termio can teach the agents you run (Claude Code, Codex, …) a `termio \
                sessions` command so they can see, drive, and read each other's sessions \
                in a project.

                Enabling adds a short note to your ~/.claude/CLAUDE.md and installs \
                status hooks. You can turn it off anytime in Settings ▸ Agents.
                """
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Not Now")
            settings.sessionControlPrompted = true
            if alert.runModal() == .alertFirstButtonReturn {
                settings.sessionControlEnabled = true
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Closing the app closes its sessions' processes. Without this there is
    /// no teardown path at all on quit — the PTYs die with the process and
    /// agent children that ignore the resulting SIGHUP live on as orphans.
    func applicationWillTerminate(_ notification: Notification) {
        store.terminateAllSessions()
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
        inspectorItem.minimumThickness = 220
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
        guard let id = store.selectedSessionID, let project = store.project(for: id) else {
            window.title = "Termio"
            window.subtitle = ""
            return
        }
        let folder = store.session(id)?.worktreePath ?? project.path
        window.title = abbreviatingHome(folder)
        window.subtitle = ""
    }

    /// Home-abbreviates an absolute path to `~`, matching how a shell prompt shows it.
    private func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Entry point for the `termio` CLI: macOS delivers the folder passed to
    /// `open -b sh.termio.app <dir>` here. Because termio is single-instance, an
    /// already-running app receives this in place, so the project opens in the
    /// existing window rather than spawning a second one.
    func application(_ application: NSApplication, open urls: [URL]) {
        openProjects(at: urls)
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
        let translucent = settings.backgroundOpacity < 1.0 || settings.backgroundBlur > 0
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
    }

    /// Re-assert the terminal-colored chrome when crossing the fullscreen boundary. macOS rebuilds
    /// the title-bar host on each transition, so the window background/appearance are re-applied to
    /// keep the fullscreen title band matching the terminal. (On enter, transparency was already
    /// dropped in `windowWillEnterFullScreen`; this confirms the rest of the chrome.)
    func windowDidEnterFullScreen(_ notification: Notification) {
        applyChromeAppearance()
        applyWindowTransparency()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        applyChromeAppearance()
        applyWindowTransparency()
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
    @objc func showSettings(_ sender: Any?) {
        openSettings(initialTab: .appearance)
    }

    /// Opens (or refocuses) the preferences window on a specific tab. The content
    /// view is rebuilt each call so the requested tab takes effect even when the
    /// window is reused — harmless because every control binds straight to
    /// `AppSettings`, so there is no transient UI state to preserve.
    func openSettings(initialTab: SettingsTab) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            // Drop the hairline under the title bar so the icon-tab strip reads as
            // one continuous surface with the title bar, Dia-style. A transparent
            // titlebar is what actually removes the separator when there is no
            // toolbar; `.none` alone leaves a faint line.
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(
            settings: settings,
            usage: usageMonitor,
            initialTab: initialTab
        ))
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// File ▸ Open Project… — presents the folder picker that opens a directory as a new
    /// project. Reached via the responder chain (the menu item targets `nil`),
    /// the same nil-target routing the Settings item uses.
    @objc func openProject(_ sender: Any?) {
        store.presentOpenProjectPanel()
    }

    /// The toolbar's `+` button — opens a fresh scratch terminal at the user's home
    /// directory (like a new iTerm2 window), grouped under a home-rooted section in the
    /// sidebar. Reached via the responder chain (the toolbar item targets `nil`), like
    /// the other app actions.
    @objc func newScratchTerminal(_ sender: Any?) {
        store.addScratchTerminal()
    }

    /// View ▸ Show Project Files (and the toolbar's trailing inspector button) —
    /// collapses or expands the file-tree inspector. Reached via the responder chain
    /// (the menu item and toolbar item both target `nil`), like the other app actions.
    @objc func toggleFilesInspector(_ sender: Any?) {
        guard let item = filesInspectorItem else { return }
        let willOpen = item.isCollapsed
        item.animator().isCollapsed = !willOpen
        setInspectorSwitchVisible(willOpen)
    }

    /// Matches the toolbar's pane switch to the inspector's *actual* collapse state — called once at
    /// launch, after the split view has restored from its autosave, so a restored-open inspector
    /// shows the switch and a restored-closed one does not (no stale mirror state to desync).
    func syncInspectorSwitch() {
        guard let item = filesInspectorItem else { return }
        setInspectorSwitchVisible(!item.isCollapsed)
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

    /// Matches the sidebar's toolbar region to the navigator's *actual* collapse state — called once
    /// at launch after the split view has restored from autosave, the navigator twin of
    /// `syncInspectorSwitch` (so a restored-collapsed sidebar shows no sort/new buttons, a
    /// restored-open one shows them, with no stale mirror state to desync).
    func syncNavigatorItems() {
        guard let item = sidebarSplitItem else { return }
        setNavigatorItemsVisible(!item.isCollapsed)
    }

    /// Inserts or removes the sidebar's grouped toolbar actions as the navigator opens/closes, so
    /// the sidebar's toolbar region empties
    /// when the sidebar is collapsed — matching Finder/Xcode, which drop their sidebar buttons with
    /// the sidebar, and freeing the horizontal room that otherwise forces NSToolbar's `»` overflow.
    /// The paired flexible space (which right-aligns the group against the sidebar divider) is inserted
    /// and removed *with* it. When open the region reads `toggleNavigator, flex, sortProjects
    /// | sidebarTrackingSeparator`. Mirrors `setInspectorSwitchVisible`.
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
            guard index(of: .sortProjects) == nil, let sep = index(of: .sidebarTrackingSeparator) else { return }
            // Reuse the sort identifier so existing toolbar configurations migrate to the group.
            toolbar.insertItem(withItemIdentifier: .sortProjects, at: sep)
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: sep)
        } else {
            // Only clean up when the group is actually present (nothing to remove at launch with
            // the sidebar already collapsed). Re-find each id after every removal — indices shift.
            guard let actionsIdx = index(of: .sortProjects) else { return }
            toolbar.removeItem(at: actionsIdx)
            // Discard the pre-group `+` item if an existing saved toolbar layout still has it.
            if let legacyNewIdx = index(of: .newTerminal) { toolbar.removeItem(at: legacyNewIdx) }
            // Drop the flexible space that right-aligned them (the one just before the sidebar separator).
            if let sep = index(of: .sidebarTrackingSeparator), sep > 0,
               toolbar.items[sep - 1].itemIdentifier == .flexibleSpace {
                toolbar.removeItem(at: sep - 1)
            }
        }
    }

    /// The toolbar's overlay-close button — dismisses whichever content overlay (file editor, diff,
    /// or preview) covers the terminal. Routed through a notification so `TerminalPane` runs the
    /// same teardown (clear the store, return focus to the terminal) the overlays' own Esc / close
    /// buttons use, keeping the two close paths identical. Reached via the responder chain (the
    /// toolbar item targets `nil`), like the other app actions.
    @objc func closeContentOverlay(_ sender: Any?) {
        NotificationCenter.default.post(name: .termioCloseContentOverlay, object: nil)
    }

    /// Inserts or removes the overlay-close button as a file editor / diff / preview opens and
    /// closes, so it is shown only while there is an overlay to close. It rides the terminal
    /// column's trailing edge: anchored just before the inspector switch's tracking separator when
    /// the inspector is open (hugging the terminal|inspector divider, directly above the overlay's
    /// own close edge), else before the inspector toggle at the window's trailing edge. The flexible
    /// space already ahead of the toggle pushes the button right against that anchor. The button is
    /// built bordered, so it inherits the same Liquid Glass treatment and size as the navigator and
    /// inspector toggles for free.
    private func setCloseOverlayVisible(_ visible: Bool) {
        guard let toolbar = window?.toolbar, visible != closeOverlayShown else { return }
        closeOverlayShown = visible
        func index(of id: NSToolbarItem.Identifier) -> Int? {
            toolbar.items.firstIndex { $0.itemIdentifier == id }
        }
        // Mutate with animation off, matching the inspector switch: the button simply presents for
        // the overlay's fade rather than running NSToolbar's own pop on an independent clock.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }
        if visible {
            guard index(of: .closeOverlay) == nil,
                  let anchor = index(of: .inspectorTrackingSeparator) ?? index(of: .toggleInspector)
            else { return }
            toolbar.insertItem(withItemIdentifier: .closeOverlay, at: anchor)
        } else if let i = index(of: .closeOverlay) {
            toolbar.removeItem(at: i)
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

    /// View ▸ Split Down (⌘⇧D) — splits the focused pane stacked.
    @objc func splitPaneDown(_ sender: Any?) {
        store.splitSelectedPane(.vertical)
    }

    /// View ▸ Close Pane (⌥⌘W) — collapses the focused pane out of the layout.
    /// The session itself stays alive in the sidebar; killing it remains the
    /// sidebar's explicit close.
    @objc func closeSplitPane(_ sender: Any?) {
        store.closeSelectedPane()
    }

    @objc func focusPaneLeft(_ sender: Any?) { store.focusPane(.left) }
    @objc func focusPaneRight(_ sender: Any?) { store.focusPane(.right) }
    @objc func focusPaneUp(_ sender: Any?) { store.focusPane(.up) }
    @objc func focusPaneDown(_ sender: Any?) { store.focusPane(.down) }
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
    private var navigatorActionsState: NavigatorToolbarActionsState?
    private var navigatorActionsHandler: NavigatorToolbarActionHandler?
    private var branchPickerWidthConstraint: NSLayoutConstraint?
    private var terminalPaneFrameObserver: NSObjectProtocol?

    init(store: TermioStore, settings: AppSettings, splitViewController: NSSplitViewController?) {
        self.store = store
        self.settings = settings
        self.splitViewController = splitViewController
    }

    deinit {
        if let terminalPaneFrameObserver {
            NotificationCenter.default.removeObserver(terminalPaneFrameObserver)
        }
    }

    /// Lets the title use the room its toolbar section actually has, up to a generous ceiling.
    /// Keep a trailing reserve for the flexible space and transient overlay-close button. At the
    /// terminal pane's 280pt minimum this yields a safe 200pt title; wider panes can show much more.
    private var terminalPaneView: NSView? {
        guard let items = splitViewController?.splitViewItems, items.count > 1 else { return nil }
        return items[1].viewController.view
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
        if let terminalPaneFrameObserver {
            NotificationCenter.default.removeObserver(terminalPaneFrameObserver)
        }
        terminalPaneFrameObserver = NotificationCenter.default.addObserver(
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

    /// Builds the sidebar grouping pull-down for the `.sortProjects` toolbar item. Its
    /// neutral choice leaves the stored project order alone; the other choices activate
    /// a visible grouping rule.
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
        updateNavigatorActionsSelection()
    }

    private func showProjectSortMenu(from anchor: NSView) {
        popUpToolbarMenu(makeProjectSortMenu(), from: anchor)
    }

    private func showNewSessionMenu(from anchor: NSView) {
        popUpToolbarMenu(makeNewSessionMenu(), from: anchor)
    }

    private func popUpToolbarMenu(_ menu: NSMenu, from anchor: NSView) {
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: anchor.bounds.height), in: anchor)
        updateNavigatorActionsSelection()
    }

    private func updateNavigatorActionsSelection() {
        navigatorActionsState?.groupingIsActive = settings.projectSortOrder != .none
    }

    /// Builds the `+` pull-down for the `.newTerminal` toolbar item: exactly the
    /// two ways something new enters the sidebar — a loose terminal (the Terminals
    /// section) or a folder opened as a project. Agents are deliberately not here:
    /// they're started *inside* a project (header buttons / context menu), and the
    /// welcome page's chips already cover the scratch case.
    func makeNewSessionMenu() -> NSMenu {
        let menu = NSMenu()
        let terminal = NSMenuItem(title: "New Terminal", action: #selector(newTerminal(_:)), keyEquivalent: "")
        terminal.target = self
        menu.addItem(terminal)
        let folder = NSMenuItem(title: "Open Project…", action: #selector(openFolder(_:)), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        return menu
    }

    @objc private func newTerminal(_ sender: Any?) { store.addScratchTerminal() }
    @objc private func openFolder(_ sender: Any?) { store.presentOpenProjectPanel() }

    /// The `.inspectorTabs` item's menu form, shown in the toolbar's `»` overflow menu when the
    /// inspector section is too narrow to hold the glass cluster — the panes stay switchable
    /// while the cluster itself is hidden.
    func makeInspectorTabsMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "Inspector Pane", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Inspector Pane")
        menu.delegate = self
        let panes: [(tab: InspectorTab, title: String)] = [
            (.files, "Project Files"), (.search, "Search Files"), (.changes, "Changes"), (.info, "Info"),
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
    // Collapsed default: just the navigator toggle, branch title, and inspector toggle. The pane
    // switch AND its tracking separator are inserted by the app delegate only while the inspector is
    // open (see `setInspectorSwitchVisible`) — keeping the separator in the default set would draw a
    // stray divider line in the toolbar while the panel is collapsed.
    // Sidebar-collapsed baseline: just the navigator toggle, the branch title, and the inspector
    // toggle. The sidebar's grouped actions and their right-aligning
    // flexible space are inserted by the app delegate only while the navigator is open (see
    // `setNavigatorItemsVisible`) — keeping them in the default set is what over-packed the row and
    // forced NSToolbar's `»` overflow when the sidebar was collapsed.
    private let defaultIdentifiers: [NSToolbarItem.Identifier] = [
        .toggleNavigator, .sidebarTrackingSeparator, .branchPicker, .flexibleSpace, .toggleInspector,
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultIdentifiers + [.sortProjects, .newTerminal, .inspectorTrackingSeparator, .inspectorTabs, .closeOverlay]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleNavigator:
            let item = NSToolbarItem(itemIdentifier: .toggleNavigator)
            item.label = "Navigator"
            item.toolTip = "Hide or show the navigator"
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Navigator")
            item.isBordered = true
            // `NSSplitViewController.toggleSidebar(_:)` collapses the first (sidebar) item with
            // the system animation. `nil` target routes up the responder chain to the split
            // controller (the window's content view controller), so no custom action is needed.
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            return item
        case .sortProjects:
            let item = NSToolbarItem(itemIdentifier: .sortProjects)
            item.label = "Navigator Actions"
            item.toolTip = "Sort projects or create a terminal"
            let state = NavigatorToolbarActionsState()
            let handler = NavigatorToolbarActionHandler()
            let actions = NSHostingView(rootView: NavigatorActionsToolbar(
                state: state,
                actionHandler: handler
            ))
            handler.anchorView = actions
            handler.showSortMenu = { [weak self] anchor in self?.showProjectSortMenu(from: anchor) }
            handler.showNewMenu = { [weak self] anchor in self?.showNewSessionMenu(from: anchor) }
            actions.sizingOptions = [.intrinsicContentSize]
            item.view = actions
            item.isBordered = false
            navigatorActionsState = state
            navigatorActionsHandler = handler
            updateNavigatorActionsSelection()
            return item
        case .inspectorTabs:
            // The native segmented switch (Files / Changes), pinned to the inspector's left edge by
            // the tracking separator that precedes it in the item order.
            let item = NSToolbarItem(itemIdentifier: .inspectorTabs)
            item.label = "Inspector"
            item.toolTip = "Switch between project files and changes"
            let host = NSHostingView(rootView: InspectorTabsToolbar().environmentObject(store))
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            item.isBordered = false
            // First to overflow: the glass cluster is incompressible, so when its section (the
            // inspector pane) gets too narrow it must yield to the `»` menu rather than slide
            // over the divider onto the pane's content. The menu form keeps the panes switchable
            // from the overflow menu while the cluster is hidden.
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
            // Native bordered button, built exactly like the navigator toggle so the two are the
            // same size; the trailing-sidebar glyph mirrors the leading one.
            let item = NSToolbarItem(itemIdentifier: .toggleInspector)
            item.label = "Inspector"
            item.toolTip = "Hide or show the inspector"
            item.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Inspector")
            item.isBordered = true
            item.action = #selector(AppDelegate.toggleFilesInspector(_:))
            return item
        case .closeOverlay:
            // Native bordered button (free Liquid Glass on macOS 26, same size as the toggles),
            // shown only while a file editor / diff / preview covers the terminal — inserted and
            // removed by `setCloseOverlayVisible`, so it is never in the default set.
            let item = NSToolbarItem(itemIdentifier: .closeOverlay)
            item.label = "Close"
            item.toolTip = "Close (Esc)"
            item.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
            item.isBordered = true
            item.action = #selector(AppDelegate.closeContentOverlay(_:))
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
    static let closeOverlay = NSToolbarItem.Identifier("TermioCloseOverlay")
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

    /// The selected session's working directory: its worktree if it has one, else its project
    /// folder. `nil` when nothing is selected.
    private var folder: String? {
        guard let id = store.selectedSessionID, let project = store.project(for: id) else { return nil }
        return store.session(id)?.worktreePath ?? project.path
    }

    private var title: String {
        guard let folder else { return "Termio" }
        return URL(fileURLWithPath: folder).lastPathComponent
    }

    private var branch: String? {
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
        // toolbar item's trailing edge. Default centering preserves the existing short-title position.
        .frame(minWidth: Self.titleWidthFloor, maxWidth: Self.titleWidthCeiling)
    }
}

@MainActor
private func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: "Check for Updates…",
        action: #selector(AppDelegate.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "Settings…",
        action: #selector(AppDelegate.showSettings(_:)),
        keyEquivalent: ","
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "Quit Termio",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appItem.submenu = appMenu

    let fileItem = NSMenuItem()
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    // Keeps the `+` new-terminal action reachable when the navigator is collapsed and its toolbar
    // button is hidden (see `setNavigatorItemsVisible`). ⌘T is safe: TUI programs drive off Ctrl,
    // never Cmd, so it can't shadow a key a terminal app wants.
    fileMenu.addItem(
        withTitle: "New Terminal",
        action: #selector(AppDelegate.newScratchTerminal(_:)),
        keyEquivalent: "t"
    )
    fileMenu.addItem(.separator())
    fileMenu.addItem(
        withTitle: "Open Project…",
        action: #selector(AppDelegate.openProject(_:)),
        keyEquivalent: "o"
    )
    fileItem.submenu = fileMenu

    // Standard Edit menu so copy/paste/select-all responder actions work.
    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu

    let viewItem = NSMenuItem()
    mainMenu.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    // otty/Xcode's split: ⌘⇧O Open Quickly jumps to things (sessions), ⌘⇧P
    // Command Palette runs verbs (actions). ⌘⇧P is the VS Code convention; not
    // ⌘K: ghostty binds super+k to clear_screen and performs it inside the
    // surface, so the key never reaches the menu. Both shortcuts are
    // additionally unbound in the surface config (see `applyAppearance`) so
    // they can't be swallowed either.
    let openQuickly = viewMenu.addItem(
        withTitle: "Open Quickly…",
        action: #selector(AppDelegate.toggleOpenQuickly(_:)),
        keyEquivalent: "o"
    )
    openQuickly.keyEquivalentModifierMask = [.command, .shift]
    let palette = viewMenu.addItem(
        withTitle: "Command Palette…",
        action: #selector(AppDelegate.toggleCommandPalette(_:)),
        keyEquivalent: "p"
    )
    palette.keyEquivalentModifierMask = [.command, .shift]
    viewMenu.addItem(.separator())
    // iTerm2's split shortcuts: ⌘D right, ⌘⇧D down. The new pane opens a plain
    // terminal in the focused session's project (see `splitSelectedPane`).
    viewMenu.addItem(
        withTitle: "Split Right",
        action: #selector(AppDelegate.splitPaneRight(_:)),
        keyEquivalent: "d"
    )
    let splitDown = viewMenu.addItem(
        withTitle: "Split Down",
        action: #selector(AppDelegate.splitPaneDown(_:)),
        keyEquivalent: "d"
    )
    splitDown.keyEquivalentModifierMask = [.command, .shift]
    // ⌥⌘W: closes the *pane* (the layout slot), not the session — ⌘W stays
    // unbound so the window's own close keeps its meaning.
    let closePane = viewMenu.addItem(
        withTitle: "Close Pane",
        action: #selector(AppDelegate.closeSplitPane(_:)),
        keyEquivalent: "w"
    )
    closePane.keyEquivalentModifierMask = [.command, .option]
    viewMenu.addItem(.separator())
    // ⌥⌘ arrows move focus between panes, scored on the split geometry.
    for (title, action, key) in [
        ("Focus Pane Left", #selector(AppDelegate.focusPaneLeft(_:)), NSLeftArrowFunctionKey),
        ("Focus Pane Right", #selector(AppDelegate.focusPaneRight(_:)), NSRightArrowFunctionKey),
        ("Focus Pane Up", #selector(AppDelegate.focusPaneUp(_:)), NSUpArrowFunctionKey),
        ("Focus Pane Down", #selector(AppDelegate.focusPaneDown(_:)), NSDownArrowFunctionKey),
    ] {
        let item = viewMenu.addItem(
            withTitle: title,
            action: action,
            keyEquivalent: String(UnicodeScalar(UInt16(key))!)
        )
        item.keyEquivalentModifierMask = [.command, .option]
    }
    viewMenu.addItem(.separator())
    // Mirrors Xcode's inspector shortcut (⌥⌘0) for the trailing file-tree panel.
    let toggleFiles = viewMenu.addItem(
        withTitle: "Show Project Files",
        action: #selector(AppDelegate.toggleFilesInspector(_:)),
        keyEquivalent: "0"
    )
    toggleFiles.keyEquivalentModifierMask = [.command, .option]
    viewItem.submenu = viewMenu

    return mainMenu
}
