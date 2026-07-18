import TermioShared
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var settingsObserver: (any NSObjectProtocol)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        // iMessage-style shell: the session list is the root page; a tapped
        // session pushes its terminal.
        let root = RootContainerViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window

        // The Appearance setting is app-wide, same as the Mac pinning
        // NSAppearance on NSApp: the window override cascades to every
        // screen — shell, sidebar, sheets, and the terminal's theme slot.
        window.overrideUserInterfaceStyle = MobileSettings.shared.appearanceMode.uiStyle
        settingsObserver = NotificationCenter.default.addObserver(
            forName: MobileSettings.didChange, object: nil, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                window?.overrideUserInterfaceStyle = MobileSettings.shared.appearanceMode.uiStyle
            }
        }

        // Screenshot-driven verification: `-demo sessions|terminal|drawer`
        // walks the sidebar → session → terminal states so simctl runs can
        // capture states that gestures can't reach from the CLI.
        let args = ProcessInfo.processInfo.arguments

        // Automated companion test drive: `-companion-url ws://localhost:8787`
        // streams the PoC server; add `-companion-session <roster-id>` to
        // attach straight to a real Mac session's PTY.
        if let urlString = Self.argument("-companion-url", in: args),
           let url = URL(string: urlString) {
            let session = Self.argument("-companion-session", in: args).map { rosterID in
                MockSession(
                    title: url.host ?? "companion",
                    project: Self.argument("-companion-project", in: args) ?? "",
                    agent: Self.argument("-companion-agent", in: args)
                        .map(RosterAgent.fallback(wire:)) ?? .terminal,
                    status: .idle,
                    subtitle: "", time: "", rosterID: rosterID,
                    projectRosterID: Self.argument("-companion-projectid", in: args),
                    branch: Self.argument("-companion-branch", in: args)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let terminal = TerminalViewController(companionURL: url, session: session)
                root.open(terminal, sessionKey: session?.key, animated: false)
                // `-open-inspector` slides the file drawer out once attached,
                // so simctl runs can screenshot the live tree.
                if args.contains("-open-inspector") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        terminal.setDrawer(open: true, animated: false)
                    }
                }
            }
            return true
        }

        // `-open-project <name>`: push a live project's page once the roster
        // delivers it — the live-data counterpart of `-demo project`, so
        // simctl runs can screenshot the second home level against the real
        // companion server.
        if let name = Self.argument("-open-project", in: args) {
            var ticks = 0
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                MainActor.assumeIsolated {
                    ticks += 1
                    if root.openProjectPage(named: name) || ticks > 20 { timer.invalidate() }
                }
            }
        }

        if let flagIndex = args.firstIndex(of: "-demo"), args.indices.contains(flagIndex + 1) {
            let mode = args[flagIndex + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // "list"/"sessions" is the launch state: the Projects root.
                guard mode != "list", mode != "sessions" else { return }
                // "project" pushes the first project's page (the second home
                // level) for screenshot runs.
                if mode == "project" {
                    root.openFirstProjectPage()
                    return
                }
                let session = MockProject.samples[0].sessions[0]
                let terminal = TerminalViewController(session: session)
                root.open(terminal, sessionKey: session.key, animated: false)
                if mode == "drawer" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        terminal.setDrawer(open: true, animated: false)
                    }
                }
                // The read-only file viewer with a bundled sample, so simctl
                // runs can verify highlight + chrome without a Mac link.
                if mode == "file" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let sample = Self.sampleFile()
                        root.present(FileViewerController(file: sample), animated: false)
                    }
                }
            }
        }
        return true
    }

    private static func argument(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    /// A `WireFile` for `-demo file`: real Swift source (this file's header),
    /// enough lines to exercise highlighting, scrolling, and the footer.
    private static func sampleFile() -> WireFile {
        let code = """
        import UIKit

        /// ChatGPT-style shell: the terminal owns the whole screen and the
        /// session list lives in a left slide-over drawer.
        final class RootContainerViewController: UIViewController {
            let sidebar = SidebarViewController()
            private var content: TerminalViewController?
            private var sidebarOpen = false
            private var sidebarWidth: CGFloat { min(view.bounds.width * 0.85, 360) }

            func setSidebar(open: Bool, animated: Bool) {
                sidebarOpen = open
                let animations = { self.layoutSidebar() }
                if animated {
                    UIView.animate(withDuration: 0.35, delay: 0,
                                   usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                                   animations: animations)
                } else {
                    animations()
                }
            }
        }
        """
        return WireFile(
            path: "ios/Sources/RootContainerViewController.swift",
            base64: Data(code.utf8).base64EncodedString(),
            size: code.utf8.count,
            binary: false,
            truncated: false
        )
    }
}
