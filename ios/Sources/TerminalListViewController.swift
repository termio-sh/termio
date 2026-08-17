import SwiftUI
import TermioShared
import UIKit

/// The Terminals tab: the Mac's loose shell sessions (the `terminals`-kind
/// container), listed flat — the phone twin of the desktop sidebar's Terminals
/// section, and the exact mirror of the Chats tab for shells instead of agents.
/// Loose terminals used to fall through as a project *folder* you had to tap
/// into; promoting them to their own tab keeps a live shell one tap away, the
/// same shape Chats already got. A row goes straight to its terminal. The
/// title-bar ＋ opens a new plain shell at `~` — no agent to pick, so (unlike
/// Chats) it carries no per-agent menu.
final class TerminalListViewController: UIViewController {
    private let store: RosterStore

    private var terminals: [MockSession] = []

    private let newTerminalButton = UIButton(type: .system)
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
        configureNewTerminalButton()
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
        pageTitle.text = localized("Terminals")
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
        newTerminalButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newTerminalButton)
        NSLayoutConstraint.activate([
            newTerminalButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            newTerminalButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            newTerminalButton.widthAnchor.constraint(equalToConstant: 52),
            newTerminalButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    /// The compose menu: New Terminal (a plain login shell the Mac gathers into
    /// the loose `.terminals` funnel) and New SSH. New SSH is a read-only pick
    /// from the Mac's `~/.ssh/config` aliases — the phone never types a host —
    /// so it's deferred to reflect the current config.
    private func configureNewTerminalButton() {
        newTerminalButton.applyGlassIcon(.add, boxSize: 24)
        newTerminalButton.tintColor = .label
        newTerminalButton.accessibilityLabel = localized("New Terminal")
        newTerminalButton.showsMenuAsPrimaryAction = true
        newTerminalButton.menu = UIMenu(children: [
            UIAction(
                title: localized("New Terminal"),
                image: HugeIcon.terminal.strokeImage(boxSize: 22)
            ) { [weak self] _ in self?.store.startNewTerminal() },
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion([self?.sshMenu() ?? UIMenu()])
            },
        ])
    }

    /// The "New SSH" submenu: one entry per `~/.ssh/config` host the Mac knows.
    /// Read-only by design — the phone chooses a known alias, it never authors a
    /// host. An empty config shows a disabled hint pointing back to the Mac, so
    /// the item never dead-ends on a tap.
    private func sshMenu() -> UIMenu {
        let icon = HugeIcon.network.strokeImage(boxSize: 22)
        let hosts = store.sshHosts
        guard !hosts.isEmpty else {
            let hint = UIAction(title: localized("Add hosts in ~/.ssh/config on your Mac")) { _ in }
            hint.attributes = .disabled
            return UIMenu(title: localized("New SSH"), image: icon, children: [hint])
        }
        let items = hosts.map { host in
            UIAction(
                title: host.alias,
                subtitle: host.user.isEmpty ? host.hostName : "\(host.user)@\(host.hostName)"
            ) { [weak self] _ in self?.store.startSSH(host: host.alias) }
        }
        return UIMenu(title: localized("New SSH"), image: icon, children: items)
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
        terminals = store.terminalSessions
        // Shown whenever paired: New Terminal is project-less, so it no longer
        // needs an existing terminals container to land in (it seeds the first).
        newTerminalButton.isHidden = store.companionURL == nil
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
    /// zero state only answers "no terminals yet". Whenever paired the ＋ can
    /// seed the first terminal, so it's the next step; only while unpaired (＋
    /// hidden) does the message fall back to pointing at the Mac.
    private func updateEmptyState() {
        emptyState.isHidden = !terminals.isEmpty
        guard !emptyState.isHidden else { return }
        let canStart = store.companionURL != nil
        emptyState.configure(
            icon: .terminal,
            title: localized("No terminals yet"),
            message: canStart
                ? localized("Terminals are plain shells that aren't tied to a project. Start one with ＋, or on your Mac.")
                : localized("Terminals are plain shells that aren't tied to a project. Start one on your Mac and it appears here."),
            actionTitle: nil,
            busy: false
        )
    }
}

// MARK: - Table data source / delegate

extension TerminalListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        terminals.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let session = terminals[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            SessionRow(
                session: session,
                isCurrent: session.key == store.currentSessionKey,
                showsProject: false,
                showsSeparator: indexPath.row < terminals.count - 1
            )
        }
        .margins(.horizontal, 12)
        .margins(.vertical, 0)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // The row IS the session — straight to its terminal.
        store.openSession(terminals[indexPath.row])
    }

    /// Trailing swipe: the Mac session menu's "Close Session".
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard store.companionURL != nil,
              let sessionID = terminals[indexPath.row].rosterID
        else { return nil }
        let close = UIContextualAction(style: .destructive, title: localized("Close")) { [weak self] _, _, done in
            self?.store.stopSession(sessionID)
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }
}
