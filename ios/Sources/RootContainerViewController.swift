import TermioShared
import UIKit

/// The shell: four native tabs — Projects (including its pushed project pages),
/// Chats, Terminals, and Settings — mirror the desktop app's main destinations.
/// A child `UITabBarController` owns those four home stacks, giving the app the
/// system Liquid Glass tab bar while this outer container continues to own the
/// live terminal overlays and their lifecycle.
/// Screen-specific actions stay beside their page title, leaving the bottom
/// edge to one stable navigation surface on every home screen, pushed project
/// pages included.
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
    /// Which workspace the home screens are showing. Lives here rather than on a
    /// screen because the rail that sets it is the shell's, and the lists that
    /// read it are in different tabs.
    let workspaceScope = WorkspaceScope()
    /// The Projects tab's root list.
    private lazy var projectList: ProjectListViewController = {
        let list = ProjectListViewController(store: store, scope: workspaceScope)
        list.onOpenWorkspaceRail = { [weak self] in self?.setWorkspaceRail(open: true) }
        return list
    }()
    /// The Projects tab's stack: the root list, plus a pushed project page.
    /// Plain UIKit views only — terminals never enter this stack (see the
    /// containment note above), so a real navigation controller is safe here.
    private lazy var projectsNav = HomeNavigationController(rootViewController: projectList)
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
        return UINavigationController(rootViewController: settings)
    }()
    /// UIKit owns the home destination switcher so iOS 26 can supply its full
    /// Liquid Glass material, selection lens, press response, safe-area
    /// behavior, and future platform updates. Keeping it as a child of this
    /// outer container leaves terminal screens as siblings above it, so parked
    /// libghostty surfaces stay installed in the window exactly as before.
    private lazy var homeTabs: UITabBarController = {
        let controller = UITabBarController()
        // The identifier carries its own English key rather than the title, so
        // the UI tests keep addressing `home.tab.projects` in every language.
        let destinations: [(nav: UIViewController, key: String, title: String, icon: HugeIcon)] = [
            (projectsNav, "projects", localized("Projects"), .folder),
            (chatsNav, "chats", localized("Chats"), .bubbleChat),
            (terminalsNav, "terminals", localized("Terminals"), .terminal),
            (settingsNav, "settings", localized("Settings"), .settings),
        ]
        for (index, destination) in destinations.enumerated() {
            let item = UITabBarItem(
                title: destination.title,
                image: destination.icon.strokeImage(boxSize: 24, strokeWeight: 1.7),
                tag: index
            )
            // A selected tab fills its symbol in, the way every system tab bar
            // does; the outline stays for the unselected ones.
            item.selectedImage = destination.icon.solidImage(boxSize: 24)
            item.accessibilityIdentifier = "home.tab.\(destination.key)"
            destination.nav.tabBarItem = item
        }
        controller.setViewControllers(destinations.map(\.nav), animated: false)
        controller.tabBar.tintColor = .label
        controller.tabBar.unselectedItemTintColor = .secondaryLabel
        return controller
    }()

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

    private var themeObserver: NSObjectProtocol?
    private var pairingObserver: NSObjectProtocol?
    private var rosterObserver: NSObjectProtocol?

    deinit {
        for observer in [themeObserver, pairingObserver, rosterObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        themeObserver = installThemeBackdrop()

        // Registered before the tabs load their views, so the first roster has
        // already named the workspace in scope — and a roster that closes it has
        // already moved on — by the time the lists re-filter on the same push.
        rosterObserver = NotificationCenter.default.addObserver(
            forName: RosterStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.workspaceScope.reconcile(against: self.store.projects)
            }
        }
        configureWorkspaceRailGesture()

        // The native tab controller is the permanent base layer. Its selected
        // navigation stack can change without affecting terminal overlays,
        // which remain children of this outer root and slide in above it.
        addChild(homeTabs)
        homeTabs.view.frame = view.bounds
        homeTabs.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(homeTabs.view)
        homeTabs.didMove(toParent: self)

        store.onOpenSession = { [weak self] session, endpoint in
            guard let self else { return }
            // Coming back to a parked session reuses its screen: same surface,
            // scrollback and connection intact — no surface teardown/rebuild.
            // Every session is the terminal itself (the iSH pattern): the
            // agent's TUI is already the conversation UI, keys go straight in.
            let screen: UIViewController
            if let parked = recentTerminals[session.key] {
                screen = parked
            } else if let endpoint, session.rosterID != nil {
                screen = TerminalViewController(endpoint: endpoint, session: session)
            } else {
                screen = TerminalViewController(session: session)
            }
            open(screen, sessionKey: session.key)
        }
        store.onStartError = { [weak self] reason in
            let alert = UIAlertController(
                title: localized("Couldn't start session"), message: reason, preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: localized("OK"), style: .default))
            self?.present(alert, animated: true)
        }
        store.start()

        // Switching (or forgetting) a Mac orphans every terminal screen: each
        // one's socket and session ids belong to the previous link. Drop them
        // all; the new roster repopulates the lists.
        pairingObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.pairingDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropTerminalsForPairingChange() }
        }
    }

    private func dropTerminalsForPairingChange() {
        let parked = recentTerminals.values
        recentTerminals.removeAll()
        recentKeys.removeAll()
        for screen in parked where screen !== activeScreen {
            evict(screen)
        }
        // No longer in the cache, so goHome tears the active one down too.
        if activeScreen != nil { goHome() }
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
        dismissWorkspaceRailImmediately()

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
        // Back on screen: this phone's viewport rejoins the size min.
        (screen as? TerminalViewController)?.setRendering(true)
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
                // Alive but not looked at: the viewport leaves the session's
                // size min so this phone stops constraining the other viewers.
                (screen as? TerminalViewController)?.setRendering(false)
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

    // MARK: - Workspace rail

    /// The rail's content; the panel's motion and gestures stay here so one
    /// place owns its frames and a drag can always take it back mid-flight.
    private lazy var workspaceRail: WorkspaceRailViewController = {
        let rail = WorkspaceRailViewController(store: store, scope: workspaceScope)
        rail.onSelect = { [weak self] in self?.setWorkspaceRail(open: false) }
        return rail
    }()
    /// Holds the dimming and the panel together, so one `isHidden` keeps the
    /// closed rail from intercepting a single touch.
    private let railContainer = UIView()
    private let railDim = UIControl()
    /// Carries the panel's shadow. The rounding has to clip, and a clipping layer
    /// clips its own shadow away, so the two live one level apart.
    private let railPanel = UIView()
    /// Slack's drawer: only the edge that stands over the page is rounded; the
    /// three the panel shares with the screen stay square.
    private let railCornerRadius: CGFloat = 24
    /// 0 closed, 1 open. The *model* position: during a settle it already holds
    /// the target, which is why an interrupt reads the layer instead.
    private var railProgress: CGFloat = 0
    private var railAnimator: UIViewPropertyAnimator?
    /// Where the rail stood when the current drag started, so a drag that begins
    /// mid-settle continues from there instead of snapping to the finger.
    private var railDragStart: CGFloat = 0
    private var railInstalled = false

    private var railWidth: CGFloat { min(view.bounds.width * 0.78, 320) }

    /// The rail is offered on a tab-bar home root and nowhere else. On a pushed
    /// page the left edge is the system back gesture, and inside a terminal the
    /// surface's own pan already means leftward-drawer / rightward-back — a
    /// second recognizer on either would be two gestures fighting for one edge.
    /// A single workspace is no choice at all, so there is nothing to reveal.
    private var canPresentWorkspaceRail: Bool {
        guard activeScreen == nil else { return false }
        guard RailMachine.roster(from: store.projects).workspaceCount > 1 else { return false }
        guard let nav = homeTabs.selectedViewController as? UINavigationController,
              nav.viewControllers.count == 1,
              nav.viewControllers.first is WorkspaceScoped
        else { return false }
        return true
    }

    private func configureWorkspaceRailGesture() {
        let edge = UIScreenEdgePanGestureRecognizer(
            target: self, action: #selector(handleRailEdgePan(_:))
        )
        edge.edges = .left
        edge.delegate = self
        view.addGestureRecognizer(edge)
    }

    /// The opener beside the page title, and the rail's own dismissals. An edge
    /// gesture on its own is undiscoverable, so the tap is not a convenience.
    func setWorkspaceRail(open: Bool) {
        guard open ? canPresentWorkspaceRail : railInstalled else { return }
        installWorkspaceRailIfNeeded()
        if open { presentRailContainer() }
        settleRail(open: open, velocityX: 0)
    }

    private func installWorkspaceRailIfNeeded() {
        guard !railInstalled else { return }
        railInstalled = true

        railContainer.frame = view.bounds
        railContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        railContainer.isHidden = true
        view.addSubview(railContainer)

        railDim.backgroundColor = .black
        railDim.alpha = 0
        railDim.frame = railContainer.bounds
        railDim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        railDim.addAction(UIAction { [weak self] _ in
            self?.setWorkspaceRail(open: false)
        }, for: .touchUpInside)
        railContainer.addSubview(railDim)

        railPanel.layer.shadowColor = UIColor.black.cgColor
        railPanel.layer.shadowOpacity = 0.3
        railPanel.layer.shadowRadius = 12
        railPanel.layer.shadowOffset = CGSize(width: 4, height: 0)
        railContainer.addSubview(railPanel)

        addChild(workspaceRail)
        railPanel.addSubview(workspaceRail.view)
        workspaceRail.didMove(toParent: self)
        workspaceRail.view.layer.cornerRadius = railCornerRadius
        workspaceRail.view.layer.cornerCurve = .continuous
        workspaceRail.view.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        workspaceRail.view.clipsToBounds = true

        // Swiping the open rail leftwards puts it away — the terminal drawer's
        // close pan, mirrored.
        let closePan = UIPanGestureRecognizer(target: self, action: #selector(handleRailClosePan(_:)))
        closePan.delegate = self
        railPanel.addGestureRecognizer(closePan)

        layoutRail(progress: 0)
    }

    /// Bring the rail up as the top layer and give it fresh contents. Called on
    /// every open, including the first frame of a drag, so a roster push while
    /// it was away can never be shown stale.
    private func presentRailContainer() {
        workspaceRail.reload()
        railContainer.isHidden = false
        view.bringSubviewToFront(railContainer)
    }

    /// Frames only — no `isHidden`, no hit-testing. This runs inside the settle
    /// animation, where flipping visibility would hide the panel on the first
    /// frame of a close instead of the last.
    private func layoutRail(progress: CGFloat) {
        railProgress = progress
        let width = railWidth
        let size = CGSize(width: width, height: view.bounds.height)
        // Only when the panel is resized, never per drag frame: an implicit
        // shadowPath animation inside the settle would lag the panel's own edge.
        if railPanel.bounds.size != size {
            railPanel.layer.shadowPath = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size),
                byRoundingCorners: [.topRight, .bottomRight],
                cornerRadii: CGSize(width: railCornerRadius, height: railCornerRadius)
            ).cgPath
        }
        railPanel.frame = CGRect(origin: CGPoint(x: -width + width * progress, y: 0), size: size)
        workspaceRail.view.frame = railPanel.bounds
        // Enough grey that the page reads as a layer parked underneath, not as
        // content still in play beside the panel.
        railDim.alpha = 0.3 * progress
    }

    /// Take an in-flight settle back at exactly where it is on screen. Reading
    /// the presentation layer rather than `railProgress` is the whole point: the
    /// model position is already at the target the moment the animator starts.
    private func interruptRailAnimation() {
        guard let animator = railAnimator else { return }
        railAnimator = nil
        guard animator.isRunning else { return }
        let presented = railPanel.layer.presentation()?.frame.origin.x
        animator.stopAnimation(true)
        guard let presented else { return }
        layoutRail(progress: max(0, min(1, (presented + railWidth) / railWidth)))
    }

    /// Release: run to open or closed with the fling carried into the spring.
    /// The velocity is normalized to fractions of the *remaining* travel per
    /// second toward the committed target, so a flick keeps its speed and a
    /// reversal or a gentle release starts from rest.
    private func settleRail(open: Bool, velocityX: CGFloat) {
        interruptRailAnimation()
        railDim.isUserInteractionEnabled = open
        let width = railWidth
        let remaining = width * (open ? 1 - railProgress : railProgress)
        let towardTarget = open ? velocityX : -velocityX
        let initial = remaining > 1 ? min(max(towardTarget / remaining, 0), 30) : 0
        let timing = UISpringTimingParameters(
            dampingRatio: 0.9, initialVelocity: CGVector(dx: initial, dy: 0)
        )
        let animator = UIViewPropertyAnimator(duration: 0.35, timingParameters: timing)
        animator.isInterruptible = true
        animator.addAnimations { self.layoutRail(progress: open ? 1 : 0) }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            railAnimator = nil
            if !open { railContainer.isHidden = true }
        }
        railAnimator = animator
        animator.startAnimation()
    }

    /// The reveal: drag right from the left edge of a home screen. Tracks the
    /// finger from the first `.changed`, never waiting for `.ended`.
    @objc private func handleRailEdgePan(_ pan: UIScreenEdgePanGestureRecognizer) {
        switch pan.state {
        case .began:
            installWorkspaceRailIfNeeded()
            interruptRailAnimation()
            presentRailContainer()
            railDim.isUserInteractionEnabled = true
            railDragStart = railProgress
        case .changed:
            let progress = railDragStart + pan.translation(in: view).x / railWidth
            layoutRail(progress: max(0, min(1, progress)))
        case .ended, .cancelled:
            let velocityX = pan.velocity(in: view).x
            // A decisive flick wins over position in either direction; position
            // only decides a gentle release. Otherwise a hard flick back still
            // committed the way the finger had already travelled.
            let open = pan.state == .ended
                && (abs(velocityX) > 300 ? velocityX > 0 : railProgress > 0.4)
            settleRail(open: open, velocityX: velocityX)
        default:
            break
        }
    }

    /// The dismissal: drag the open rail back off the left edge.
    @objc private func handleRailClosePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            interruptRailAnimation()
            railDragStart = railProgress
        case .changed:
            let progress = railDragStart + pan.translation(in: view).x / railWidth
            layoutRail(progress: max(0, min(1, progress)))
        case .ended, .cancelled:
            let velocityX = pan.velocity(in: view).x
            let open = pan.state != .ended
                || (abs(velocityX) > 300 ? velocityX > 0 : railProgress > 0.6)
            settleRail(open: open, velocityX: velocityX)
        default:
            break
        }
    }

    /// A terminal is about to cover the shell — the rail has no business over
    /// it, and the surface owns every pan from here.
    private func dismissWorkspaceRailImmediately() {
        guard railInstalled, railProgress > 0 || railAnimator != nil else { return }
        interruptRailAnimation()
        railDim.isUserInteractionEnabled = false
        layoutRail(progress: 0)
        railContainer.isHidden = true
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

    /// `-open-session <title>`: open a live session's terminal once the roster
    /// carries it, through the same call a row tap makes. Returns false while
    /// the session isn't in the roster yet.
    func openSessionScreen(titled title: String) -> Bool {
        loadViewIfNeeded()
        guard let session = store.projects.flatMap(\.sessions).first(where: { $0.title == title })
        else { return false }
        store.openSession(session)
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

// MARK: - Rail gesture gating

extension RootContainerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture is UIScreenEdgePanGestureRecognizer {
            return canPresentWorkspaceRail
        }
        // The close pan rides the rail's own view, over a vertically scrolling
        // table: only a clearly horizontal drag is the rail's.
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y)
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
