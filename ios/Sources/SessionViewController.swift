import TermioShared
import UIKit

/// What the container slides in over the session list. Both the conversation
/// and the terminal are views *of a session*, so the container speaks this
/// instead of naming one of them.
@MainActor
protocol SessionScreen: UIViewController {
    var onClose: (() -> Void)? { get set }
    var onRequestBack: (() -> Void)? { get set }
    var onBackBegan: (() -> Void)? { get set }
    var onBackChanged: ((CGFloat) -> Void)? { get set }
    var onBackEnded: ((_ velocityX: CGFloat, _ commit: Bool) -> Void)? { get set }
    /// A parked screen comes back without `viewDidAppear`, so the per-return
    /// work runs from here.
    func prepareForReappearance()
    func releaseOrphanedSurfaceLayers()
}

extension TerminalViewController: SessionScreen {}

/// One agent session and its two views: the terminal, and the conversation.
///
/// **The terminal opens first.** That is the product's position rather than a
/// default nobody thought about — the terminal *is* the interface, and the
/// chat is a second way to look at the same session for the things an
/// 80-column grid on a phone cannot do (read a finished conversation, show a
/// diff as a diff, put a plan in a checklist). Settings ▸ Appearance flips
/// which one a session lands on; either way the other is one tap from the
/// header.
///
/// Two consequences that are the point rather than side effects:
///
/// - **Opening a session does not start anything.** The Mac creates a session's
///   shell on first attach, so a chat that attached on open would resurrect
///   every finished session the moment it was read. The socket connects, the
///   content plane subscribes, and the PTY is claimed only when the terminal is
///   shown.
/// - **One socket, two views.** The container owns the connection; the terminal
///   borrows it. Switching views costs no second connection, and a flaky link
///   cannot leave one plane up and the other down.
final class SessionViewController: UIViewController, SessionScreen {
    var onClose: (() -> Void)?
    var onRequestBack: (() -> Void)?
    var onBackBegan: (() -> Void)?
    var onBackChanged: ((CGFloat) -> Void)?
    var onBackEnded: ((_ velocityX: CGFloat, _ commit: Bool) -> Void)?

    private let session: MockSession
    private let companionURL: URL
    private let transport: CompanionTransport
    private let chat = ChatLensViewController()
    /// Built the first time the terminal is asked for, then kept: its surface
    /// is a live libghostty instance with scrollback, and rebuilding it on
    /// every switch would throw away the screen the agent painted.
    private var terminal: TerminalViewController?

    init(companionURL: URL, session: MockSession) {
        self.session = session
        self.companionURL = companionURL
        transport = CompanionTransport(
            url: companionURL, attachSessionID: session.rosterID, attachesOnConnect: false)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        transport.stop()
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    /// The agent's live status, from the roster socket — the app's only status
    /// feed, and the same one the session list reads. The chat shows it where a
    /// messenger shows "typing…", which is the honest translation: it means the
    /// same thing to the person waiting.
    private var statusObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        chat.title = session.title
        chat.context = [session.project, session.worktreeBranch ?? session.branch]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        chat.onRequestBack = { [weak self] in self?.onRequestBack?() }
        chat.onRequestTerminal = { [weak self] in self?.showTerminal() }
        chat.onNeedEvents = { [weak self] since in self?.transport.subscribeEvents(since: since) }
        chat.onSend = { [weak self] text in self?.transport.sendPrompt(text) }
        transport.onAgentEvents = { [weak chat] events in chat?.apply(events) }

        // The chat is built either way — it subscribes to the content plane on
        // load, so switching to it later is instant instead of a cold replay —
        // but the terminal is what is on top unless the setting says otherwise.
        chat.activity = session.status
        statusObserver = NotificationCenter.default.addObserver(
            forName: .sessionStatusesDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let rosterID = session.rosterID,
                let statuses = note.userInfo?["statuses"] as? [String: SessionStatus],
                let status = statuses[rosterID]
            else { return }
            MainActor.assumeIsolated { self.chat.activity = status }
        }

        install(chat)
        if !MobileSettings.shared.opensInChat { showTerminal() }
        transport.start()
    }

    // MARK: - Views of the session

    private func showTerminal() {
        let screen = terminal ?? makeTerminal()
        terminal = screen
        install(screen)
        // Installing it is what makes it appear, which is what claims the PTY —
        // see `TerminalViewController.viewDidAppear`.
        view.bringSubviewToFront(screen.view)
        setNeedsStatusBarAppearanceUpdate()
    }

    private func showChat() {
        install(chat)
        view.bringSubviewToFront(chat.view)
        // The terminal stays a child with its surface alive, hidden behind the
        // chat, so switching back is instant and the scrollback survives.
        terminal?.view.isHidden = true
        terminal?.dropKeyboard()
    }

    private func makeTerminal() -> TerminalViewController {
        let screen = TerminalViewController(
            companionURL: companionURL, session: session, transport: transport)
        screen.onRequestChat = { [weak self] in self?.showChat() }
        // Back leaves the session entirely. The chat is not "behind" the
        // terminal — they are peers, reached by the header's switch — so a
        // back gesture that landed on the chat instead of the list would make
        // leaving a session a two-step affair.
        screen.onRequestBack = { [weak self] in self?.onRequestBack?() }
        screen.onBackBegan = { [weak self] in self?.onBackBegan?() }
        screen.onBackChanged = { [weak self] offset in self?.onBackChanged?(offset) }
        screen.onBackEnded = { [weak self] velocity, commit in
            self?.onBackEnded?(velocity, commit)
        }
        screen.onClose = { [weak self] in self?.onClose?() }
        return screen
    }

    private func install(_ child: UIViewController) {
        if child.parent !== self {
            addChild(child)
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(child.view)
            child.didMove(toParent: self)
        }
        child.view.isHidden = false
    }

    // MARK: - SessionScreen

    func prepareForReappearance() {
        if terminal?.view.isHidden == false { terminal?.prepareForReappearance() }
    }

    func releaseOrphanedSurfaceLayers() {
        terminal?.releaseOrphanedSurfaceLayers()
    }
}
