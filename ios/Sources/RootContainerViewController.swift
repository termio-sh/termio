import TermioShared
import UIKit

/// The shell: the home is two tabs — Projects (the strip + project list, with
/// its pushed project pages) and Chats (the Mac's loose agent sessions),
/// mirroring the desktop sidebar's Chats/Projects pairing as the two top-level
/// destinations. The switcher is a compact Telegram-scale glass pill floating
/// bottom-LEFT (`HomeTabPill` — see there for why the system tab bar doesn't
/// fit), leaving the bottom-right corner to each screen's own ＋ (the Slack
/// compose corner) at the pill's own 64pt scale, so the bottom edge reads as
/// one balanced bar on every home screen — pushed project pages included.
/// Tapping a session anywhere slides its terminal in full-screen over the
/// whole thing, and "back" slides it away to reveal the tabs wherever they
/// were. Screens draw their own chrome (large titles, glass buttons, the
/// terminal its compact header), so the navigation bars stay hidden.
///
/// **Why containment instead of a UINavigationController.** Destroying a
/// libghostty surface races the engine's render/IO threads — the source of the
/// iOS `drawFrame` / `os_unfair_lock` crashes. The wrapper frees the surface
/// the instant its view leaves the window (`UITerminalView.didMoveToWindow`),
/// and rebuilds it on re-attach, so a plain push/pop tore down and recreated a
/// surface on every back-and-reopen — racing the engine every time. Here a
/// switched-away terminal is only *hidden*: its view stays installed in the
/// window, so the surface is never freed and never rebuilt. It is torn down
/// only on eviction/close, detached and idle, with no in-flight frames to race.
/// Keyed by `MockSession.key`; a small LRU bounds live surfaces.
final class RootContainerViewController: UIViewController {
    /// The one live roster model, shared by every home screen.
    let store = RosterStore()
    /// The Projects tab's stack: the root list, plus a pushed project page.
    /// Plain UIKit views only — terminals never enter this stack (see the
    /// containment note above), so a real navigation controller is safe here.
    private lazy var projectsNav = HomeNavigationController(
        rootViewController: ProjectListViewController(store: store)
    )
    /// The Chats tab's stack: the flat chat list (nothing pushes onto it yet;
    /// a nav keeps both tabs the same shape).
    private lazy var chatsNav = HomeNavigationController(
        rootViewController: ChatListViewController(store: store)
    )
    /// The Terminals tab's stack: the flat loose-shell list, the shell twin of
    /// Chats. Same shape (a nav for consistency; nothing pushes onto it yet).
    private lazy var terminalsNav = HomeNavigationController(
        rootViewController: TerminalListViewController(store: store)
    )
    /// The Settings tab, Telegram's placement: the same page the unpaired
    /// zero state presents modally, minus the modal ✕. A stock nav (bar
    /// visible) — settings uses system chrome, unlike the home lists.
    private lazy var settingsNav: UINavigationController = {
        let settings = SettingsViewController()
        settings.showsCloseButton = false
        let nav = UINavigationController(rootViewController: settings)
        // Keep the table's last rows clear of the floating pill.
        nav.additionalSafeAreaInsets.bottom = 76
        return nav
    }()
    /// The bottom-left floating switcher between the three.
    private let tabPill = HomeTabPill(items: [
        (title: "Projects", icon: .folder),
        (title: "Chats", icon: .bubbleChat),
        (title: "Terminals", icon: .terminal),
        (title: "Settings", icon: .settings),
    ])

    /// Every parked terminal is a live libghostty surface (scrollback + render
    /// buffers + a streaming socket) whose view stays in the window. On the
    /// phone those add up fast, and libghostty answers memory exhaustion by
    /// replacing the surface with its own "non-functional" panic screen — so
    /// keep the cache small.
    private var recentTerminals: [String: UIViewController] = [:]
    private var recentKeys: [String] = []
    private let maxRecentTerminals = 2

    /// The terminal currently slid in over the list, or nil when the list is
    /// the top screen. Tracked directly (not via the key) so keyless demo
    /// runs are handled too.
    private weak var activeScreen: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // All tab stacks are permanent base layers: added once, always behind
        // any terminal, only ever toggled hidden — so each tab keeps its
        // scroll position and pushed pages across switches.
        let tabStacks: [UIViewController] = [projectsNav, chatsNav, terminalsNav, settingsNav]
        for nav in tabStacks {
            addChild(nav)
            nav.view.frame = view.bounds
            nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(nav.view)
            nav.didMove(toParent: self)
            nav.view.isHidden = nav !== projectsNav
        }

        // The switcher floats over all of them; terminals slide in above it.
        tabPill.onSelect = { [weak self] index in
            guard let self else { return }
            for (i, nav) in tabStacks.enumerated() {
                nav.view.isHidden = i != index
            }
        }
        tabPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabPill)
        NSLayoutConstraint.activate([
            tabPill.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabPill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        store.onOpenSession = { [weak self] session, companionURL in
            guard let self else { return }
            // Coming back to a parked session reuses its screen: same surface,
            // scrollback and connection intact — no surface teardown/rebuild.
            // Every session is the terminal itself (the iSH pattern): the
            // agent's TUI is already the conversation UI, keys go straight in.
            let screen: UIViewController
            if let parked = recentTerminals[session.key] {
                screen = parked
            } else if let companionURL, session.rosterID != nil {
                screen = TerminalViewController(companionURL: companionURL, session: session)
            } else {
                screen = TerminalViewController(session: session)
            }
            open(screen, sessionKey: session.key)
        }
        store.onStartError = { [weak self] reason in
            let alert = UIAlertController(
                title: "Couldn't start session", message: reason, preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        }
        store.start()
    }

    /// Under memory pressure, shed every parked terminal except the one on
    /// screen: each is a live libghostty surface, and the alternative is the
    /// engine hitting its allocator ceiling and painting the "out of memory /
    /// non-functional" panic. The visible screen is kept; parked screens tear
    /// down detached and idle.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        let survivor = recentTerminals.first { $0.value === activeScreen }?.key
        for key in recentKeys where key != survivor {
            if let screen = recentTerminals.removeValue(forKey: key) {
                evict(screen)
            }
        }
        recentKeys = survivor.map { [$0] } ?? []
    }

    // MARK: - Content

    /// Slide a session screen in over the list. `sessionKey` marks the list row
    /// as current (nil for demo runs) and parks the screen in the keep-alive
    /// cache. One conversation at a time, like Messages.
    func open(_ screen: UIViewController, sessionKey: String? = nil, animated: Bool = true) {
        loadViewIfNeeded()
        guard activeScreen !== screen else { return }

        if let sessionKey {
            recentTerminals[sessionKey] = screen
            recentKeys.removeAll { $0 == sessionKey }
            recentKeys.append(sessionKey)
            // Evict the coldest parked screen (never the incoming one). It
            // tears down detached and idle — no in-flight frames to race.
            while recentKeys.count > maxRecentTerminals {
                let coldest = recentKeys.removeFirst()
                if let cold = recentTerminals.removeValue(forKey: coldest), cold !== screen {
                    evict(cold)
                }
            }
        }
        if let terminal = screen as? TerminalViewController {
            terminal.onRequestBack = { [weak self] in self?.goHome() }
            terminal.onBackBegan = { [weak self] in self?.beginInteractiveBack() }
            terminal.onBackChanged = { [weak self] tx in self?.updateInteractiveBack(translationX: tx) }
            terminal.onBackEnded = { [weak self] vx, commit in
                self?.finishInteractiveBack(velocityX: vx, commit: commit)
            }
            terminal.onClose = { [weak self, weak screen] in
                guard let screen else { return }
                self?.close(screen)
            }
        }

        // A parked screen is only hidden, never removed, so `viewDidAppear`
        // won't fire on its way back — re-run the per-return work explicitly.
        // A brand-new screen gets `viewDidAppear` for free from containment.
        let isReopen = screen.parent === self
        installIfNeeded(screen)
        if isReopen {
            (screen as? TerminalViewController)?.prepareForReappearance()
        }
        store.currentSessionKey = sessionKey
        refreshHomeLists()

        // Start off the right edge, on top, and slide to fill.
        let offscreen = view.bounds.offsetBy(dx: view.bounds.width, dy: 0)
        screen.view.frame = offscreen
        screen.view.isHidden = false
        view.bringSubviewToFront(screen.view)
        activeScreen = screen

        let settle = { screen.view.frame = self.view.bounds }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0,
                           usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                           options: .curveEaseOut, animations: settle)
        } else {
            settle()
        }
    }

    /// Back to the list: slide the active terminal off to the right. It stays
    /// parked (view installed, surface alive) if it is still in the cache;
    /// otherwise it is torn down.
    private func goHome(animated: Bool = true) {
        guard let screen = activeScreen else { return }
        activeScreen = nil
        store.currentSessionKey = nil
        refreshHomeLists()

        let parked = recentTerminals.contains { $0.value === screen }
        let offscreen = view.bounds.offsetBy(dx: view.bounds.width, dy: 0)
        let finish = {
            if parked {
                screen.view.isHidden = true // stays in the window: surface alive
            } else {
                self.evict(screen)
            }
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0,
                           options: .curveEaseOut,
                           animations: { screen.view.frame = offscreen },
                           completion: { _ in finish() })
        } else {
            screen.view.frame = offscreen
            finish()
        }
    }

    // MARK: - Interactive back (finger-tracked right-swipe)

    /// The screen currently being dragged back to the list. Held so update/finish
    /// keep driving the same view even if `activeScreen` is cleared on commit.
    private var interactiveBackScreen: UIViewController?

    private func beginInteractiveBack() {
        interactiveBackScreen = activeScreen
    }

    /// Follow the finger: slide the active screen right by `translationX`
    /// (already clamped to >= 0 by the caller), revealing the list underneath.
    private func updateInteractiveBack(translationX: CGFloat) {
        guard let screen = interactiveBackScreen else { return }
        screen.view.frame = view.bounds.offsetBy(dx: translationX, dy: 0)
    }

    /// Release: either complete the pop (carrying the fling velocity, then the
    /// SAME park-or-evict teardown as `goHome`) or spring back to full screen.
    private func finishInteractiveBack(velocityX: CGFloat, commit: Bool) {
        guard let screen = interactiveBackScreen else { return }
        interactiveBackScreen = nil
        let width = view.bounds.width
        let currentX = screen.view.frame.origin.x

        if commit {
            // Teardown deferred from goHome to here (only once the drag commits).
            if activeScreen === screen { activeScreen = nil }
            store.currentSessionKey = nil
            refreshHomeLists()
            let parked = recentTerminals.contains { $0.value === screen }
            let offscreen = view.bounds.offsetBy(dx: width, dy: 0)
            let remaining = max(1, width - currentX)
            let v = min(max(velocityX / remaining, 0), 30)
            UIView.animate(withDuration: 0.3, delay: 0,
                           usingSpringWithDamping: 0.9, initialSpringVelocity: v,
                           options: .curveEaseOut,
                           animations: { screen.view.frame = offscreen },
                           completion: { _ in
                if parked {
                    screen.view.isHidden = true // stays in the window: surface alive
                } else {
                    self.evict(screen)
                }
            })
        } else {
            // Cancel: settle back to x = 0. A leftward flick (negative vx) is
            // toward the target, so negate; away-from-target starts from rest.
            let remaining = max(1, currentX)
            let v = min(max(-velocityX / remaining, 0), 30)
            UIView.animate(withDuration: 0.3, delay: 0,
                           usingSpringWithDamping: 0.9, initialSpringVelocity: v,
                           options: .curveEaseOut,
                           animations: { screen.view.frame = self.view.bounds })
        }
    }

    /// The session ended (or its connection died) — different from navigating
    /// back, which parks the screen: drop it from the cache and, if it owned the
    /// screen, reveal the list.
    private func close(_ screen: UIViewController) {
        if let key = recentTerminals.first(where: { $0.value === screen })?.key {
            recentTerminals.removeValue(forKey: key)
            recentKeys.removeAll { $0 == key }
        }
        if activeScreen === screen {
            goHome() // screen is no longer cached, so goHome evicts it
        } else {
            evict(screen)
        }
    }

    /// `-demo project`: push the first mock project's page on launch, so
    /// simctl runs can screenshot the second home level without tapping.
    func openFirstProjectPage() {
        loadViewIfNeeded()
        guard let first = store.projects.first else { return }
        projectsNav.pushViewController(
            ProjectDetailViewController(store: store, project: first),
            animated: false
        )
    }

    /// `-open-project <name>`: same, but for a live roster project once it
    /// arrives. Returns false while the project isn't in the roster yet.
    func openProjectPage(named name: String) -> Bool {
        loadViewIfNeeded()
        guard let project = store.projects.first(where: { $0.name == name }) else { return false }
        projectsNav.pushViewController(
            ProjectDetailViewController(store: store, project: project),
            animated: false
        )
        return true
    }

    /// Repaint the current-session pill on whichever home screens are up.
    private func refreshHomeLists() {
        for screen in projectsNav.viewControllers {
            (screen as? ProjectListViewController)?.refresh()
            (screen as? ProjectDetailViewController)?.refresh()
        }
        for screen in chatsNav.viewControllers {
            (screen as? ChatListViewController)?.refresh()
        }
        for screen in terminalsNav.viewControllers {
            (screen as? TerminalListViewController)?.refresh()
        }
    }

    // MARK: - Child lifecycle

    private func installIfNeeded(_ screen: UIViewController) {
        guard screen.parent !== self else { return }
        addChild(screen)
        screen.view.frame = view.bounds
        screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen.view)
        screen.didMove(toParent: self)
    }

    /// The one place a surface is torn down — always detached and idle.
    private func evict(_ screen: UIViewController) {
        guard screen.parent === self else { return }
        screen.willMove(toParent: nil)
        // Leaving the window frees the libghostty surface, but leaves its
        // CAMetalLayer (with a dangling delegate) in the tree; drop it before
        // the next CoreAnimation commit can fault on it. See TerminalVC.
        screen.view.removeFromSuperview()
        (screen as? TerminalViewController)?.releaseOrphanedSurfaceLayers()
        screen.removeFromParent()
    }
}

/// The home stack's navigation controller: bar hidden (screens draw their own
/// chrome), but the edge swipe-back kept alive — hiding the bar normally
/// disables `interactivePopGestureRecognizer`, so it gets a delegate that
/// re-arms it whenever there is somewhere to pop to.
private final class HomeNavigationController: UINavigationController, UIGestureRecognizerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        isNavigationBarHidden = true
        interactivePopGestureRecognizer?.delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
