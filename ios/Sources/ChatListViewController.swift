import SwiftUI
import TermioShared
import UIKit

/// The Chats tab: the Mac's loose agent sessions (the `chats`-kind container) —
/// the phone twin of the desktop sidebar's Chats section. The sessions ARE the
/// content: no project page in between, a row goes straight to its terminal,
/// like the ChatGPT chat list. ＋ starts a new chat in one tap — the Mac picks
/// the agent, the same default ⌘N launches.
///
/// Sectioned by workspace, like the Projects list and the Terminals tab: there
/// is one loose funnel per workspace, so with two machines paired a flat list
/// would show both boxes' chats as one column with nothing saying which is which.
final class ChatListViewController: UIViewController {
    private let store: RosterStore

    /// The store's loose chat containers, grouped by workspace in roster order —
    /// one section each.
    private var groups: [WorkspaceGroup] = []

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
        configureFab()
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
        pageTitle.text = localized("Chats")
        pageTitle.font = .systemFont(ofSize: 34, weight: .bold)
        pageTitle.textColor = .label

        let spacer = UIView()
        let bar = UIStackView(arrangedSubviews: [pageTitle, spacer])
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
        ])
        return bar
    }

    /// The compose ＋ floats in the bottom-right corner as a glass FAB, above the
    /// native tab bar — thumb-reachable and clear of the large title. Added
    /// after the table so it sits above the rows.
    private func configureFab() {
        newChatButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newChatButton)
        NSLayoutConstraint.activate([
            newChatButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            newChatButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            newChatButton.widthAnchor.constraint(equalToConstant: 52),
            newChatButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    /// The compose menu: a tap presents the agent picker directly — choosing
    /// which agent to start is the primary action. Deferred so it always
    /// reflects the roster's current enabled agents (and the button hides while
    /// unpaired). The agents sit under a header naming the workspace the chat
    /// will land in, so the destination is stated where the choice is made.
    private func configureNewChatButton() {
        newChatButton.applyGlassIcon(.add, boxSize: 24)
        newChatButton.tintColor = .label
        newChatButton.accessibilityLabel = localized("New Chat")
        newChatButton.showsMenuAsPrimaryAction = true
        newChatButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.composeMenuItems() ?? [])
            },
        ])
    }

    private func composeMenuItems() -> [UIMenuElement] {
        guard let chatsProject = store.chatsProject else { return [] }
        var items: [UIMenuElement] = [
            UIMenu(
                title: destinationTitle,
                options: .displayInline,
                children: store.newSessionActions(in: chatsProject)
            ),
        ]
        if let destinations = store.destinationPickerMenu() { items.append(destinations) }
        return items
    }

    /// "New Chat in Alpha" — the destination stated over the agent list. Empty
    /// when there is only one workspace to land in: naming a choice nobody has
    /// is noise, and an empty title draws no header.
    private var destinationTitle: String {
        guard store.localWorkspaces.count > 1,
              let name = store.destinationWorkspace?.name, !name.isEmpty
        else { return "" }
        return localized("New Chat in \(name)")
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
        tableView.register(
            WorkspaceSectionHeaderView.self,
            forHeaderFooterViewReuseIdentifier: WorkspaceSectionHeaderView.reuseID
        )
        tableView.translatesAutoresizingMaskIntoConstraints = false
        // The native tab controller contributes the correct safe-area and
        // adjusted scroll insets for both the classic and Liquid Glass bars.
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func refilter() {
        groups = store.chatGroups
        newChatButton.isHidden = store.chatsProject?.rosterID == nil
        tableView.reloadData()
        updateEmptyState()
    }

    /// Every chat on screen, in section order.
    private var visible: [MockSession] { groups.flatMap(\.sessions) }

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
        emptyState.isHidden = !visible.isEmpty
        guard !emptyState.isHidden else { return }
        emptyState.configure(
            icon: .bubbleChat,
            title: localized("No chats yet"),
            message: localized("Chats are agent sessions that aren't tied to a project. Start one with ＋, or on your Mac."),
            actionTitle: nil,
            busy: false
        )
    }
}

// MARK: - Table data source / delegate

extension ChatListViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        groups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        groups[section].sessions.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard groups.namesWorkspaces else { return nil }
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: WorkspaceSectionHeaderView.reuseID
        ) as? WorkspaceSectionHeaderView else { return nil }
        let group = groups[section]
        header.configure(title: group.name, detail: group.machineLabel)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        groups.namesWorkspaces ? WorkspaceSectionHeaderView.height : 0
    }

    /// A whitespace gap below each group — the divider-free separator, matching
    /// the macOS sidebar's spacing-based grouping.
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        12
    }

    /// An empty (transparent) footer view, so the gap above is just whitespace.
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        UIView()
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let sessions = groups[indexPath.section].sessions
        let session = sessions[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            SessionRow(
                session: session,
                isCurrent: session.key == store.currentSessionKey,
                showsProject: false,
                showsSeparator: indexPath.row < sessions.count - 1
            )
        }
        .margins(.horizontal, 12)
        .margins(.vertical, 0)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // The row IS the session — straight to its terminal.
        store.openSession(groups[indexPath.section].sessions[indexPath.row])
    }

    /// Trailing swipe: the Mac session menu's "Close Session".
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard store.companionURL != nil,
              let sessionID = groups[indexPath.section].sessions[indexPath.row].rosterID
        else { return nil }
        let close = UIContextualAction(style: .destructive, title: localized("Close")) { [weak self] _, _, done in
            self?.store.stopSession(sessionID)
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }
}
