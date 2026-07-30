import SwiftUI
import TermioShared
import UIKit

/// The Chats tab: the Mac's loose agent sessions (the `chats`-kind container),
/// listed flat — the phone twin of the desktop sidebar's Chats section. The
/// sessions ARE the content: no project page in between, a row goes straight
/// to its terminal, like the ChatGPT chat list. ＋ starts a new chat in one
/// tap from the title bar — the Mac picks the agent, the same default ⌘N
/// launches — with the per-agent menu kept behind a long-press.
final class ChatListViewController: UIViewController {
    private let store: RosterStore

    private var chats: [MockSession] = []

    private let newChatButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let emptyState = ListEmptyStateView()
    private var rosterObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    init(store: RosterStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        themeObserver = installThemeBackdrop()
        configureNewChatButton()
        let topBar = configureTopBar()
        configureTable(below: topBar)
        configureEmptyState(below: topBar)
        refilter()
        rosterObserver = NotificationCenter.default.addObserver(
            forName: RosterStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refilter() }
        }
    }

    deinit {
        if let rosterObserver {
            NotificationCenter.default.removeObserver(rosterObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    func refresh() {
        tableView.reloadData()
    }

    // MARK: - Top bar (large title)

    private func configureTopBar() -> UIView {
        let pageTitle = UILabel()
        pageTitle.text = "Chats"
        pageTitle.font = .systemFont(ofSize: 34, weight: .bold)
        pageTitle.textColor = .label

        let spacer = UIView()
        let bar = UIStackView(arrangedSubviews: [pageTitle, spacer, newChatButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bar.heightAnchor.constraint(equalToConstant: 40),
            newChatButton.widthAnchor.constraint(equalToConstant: 40),
            newChatButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        return bar
    }

    /// The page-local ＋ lives beside "Chats", while the bottom edge belongs to
    /// navigation. A tap presents the agent picker directly: choosing which
    /// agent to start is the primary action. Deferred so it always reflects the
    /// roster's current enabled agents (and the button hides while unpaired).
    private func configureNewChatButton() {
        newChatButton.applyGlassIcon(.add, boxSize: 22)
        newChatButton.tintColor = .label
        newChatButton.accessibilityLabel = "New Chat"
        newChatButton.showsMenuAsPrimaryAction = true
        newChatButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self, let chatsProject = store.chatsProject else {
                    completion([])
                    return
                }
                completion(store.newSessionActions(in: chatsProject))
            },
        ])
    }

    // MARK: - Table

    private func configureTable(below topBar: UIView) {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        // The floating pill sits over the list; reserve room so the last rows
        // scroll clear of it (64pt pill + margins).
        tableView.contentInset.bottom = 80
        tableView.verticalScrollIndicatorInsets.bottom = 80
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func refilter() {
        chats = store.chatSessions
        newChatButton.isHidden = store.chatsProject?.rosterID == nil
        tableView.reloadData()
        updateEmptyState()
    }

    // MARK: - Empty state

    private func configureEmptyState(below topBar: UIView) {
        emptyState.isHidden = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Link-state nuance lives on the Projects tab (the pairing home); this
    /// zero state only answers "no chats yet". The ＋ above is the next step,
    /// so no pill button repeats it.
    private func updateEmptyState() {
        emptyState.isHidden = !chats.isEmpty
        guard !emptyState.isHidden else { return }
        emptyState.configure(
            icon: .bubbleChat,
            title: "No chats yet",
            message: "Chats are agent sessions that aren't tied to a project. Start one with ＋, or on your Mac.",
            actionTitle: nil,
            busy: false
        )
    }
}

// MARK: - Table data source / delegate

extension ChatListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        chats.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let session = chats[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            SessionRow(
                session: session,
                isCurrent: session.key == store.currentSessionKey,
                showsProject: false,
                showsSeparator: indexPath.row < chats.count - 1
            )
        }
        .margins(.horizontal, 12)
        .margins(.vertical, 0)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // The row IS the session — straight to its terminal.
        store.openSession(chats[indexPath.row])
    }

    /// Trailing swipe: the Mac session menu's "Close Session".
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard store.companionURL != nil,
              let sessionID = chats[indexPath.row].rosterID
        else { return nil }
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            self?.store.stopSession(sessionID)
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }
}
