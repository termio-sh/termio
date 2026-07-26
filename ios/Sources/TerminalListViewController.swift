import SwiftUI
import TermioShared
import UIKit

/// The Terminals tab: the Mac's loose shell sessions (the `terminals`-kind
/// container), listed flat — the phone twin of the desktop sidebar's Terminals
/// section, and the exact mirror of the Chats tab for shells instead of agents.
/// Loose terminals used to fall through as a project *folder* you had to tap
/// into; promoting them to their own tab keeps a live shell one tap away, the
/// same shape Chats already got. A row goes straight to its terminal. ＋ opens a
/// new plain shell at `~` — no agent to pick, so (unlike Chats) it carries no
/// per-agent menu.
final class TerminalListViewController: UIViewController {
    private let store: RosterStore

    private var terminals: [MockSession] = []

    private let newTerminalButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let emptyState = ListEmptyStateView()
    private var rosterObserver: NSObjectProtocol?

    init(store: RosterStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let topBar = configureTopBar()
        configureTable(below: topBar)
        configureEmptyState(below: topBar)
        // Added last so it floats over the list, opposite the home tab pill.
        configureNewTerminalButton()
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
    }

    func refresh() {
        tableView.reloadData()
    }

    // MARK: - Top bar (large title)

    private func configureTopBar() -> UIView {
        let pageTitle = UILabel()
        pageTitle.text = "Terminals"
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

    /// ＋ floats bottom-right, opposite the home tab pill — the compose corner.
    /// A TAP is one new terminal: a plain login shell at `~`, which the Mac
    /// gathers into the loose `.terminals` funnel. There is no agent to choose,
    /// so — unlike the Chats ＋ — no long-press menu. Hidden until the Mac has a
    /// terminals container to land in (mirrors the Chats ＋), and while unpaired.
    private func configureNewTerminalButton() {
        newTerminalButton.applyGlassIcon(.add, boxSize: 26)
        newTerminalButton.tintColor = .label
        newTerminalButton.accessibilityLabel = "New Terminal"
        newTerminalButton.addAction(
            UIAction { [weak self] _ in self?.store.startDefaultTerminal() },
            for: .touchUpInside
        )
        newTerminalButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newTerminalButton)
        NSLayoutConstraint.activate([
            newTerminalButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            // The tab pill's own scale (64pt, 8pt above the safe area), so the
            // two ends of the bottom edge read as one balanced bar.
            newTerminalButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            newTerminalButton.widthAnchor.constraint(equalToConstant: 64),
            newTerminalButton.heightAnchor.constraint(equalToConstant: 64),
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
        // The floating pill/＋ sit over the list; reserve room so the last
        // rows scroll clear of them (64pt pill + margins).
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
        terminals = store.terminalSessions
        newTerminalButton.isHidden = store.terminalsProject?.rosterID == nil
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
    /// zero state only answers "no terminals yet". When the ＋ is visible it is
    /// the next step; when it's hidden (no container yet) the message points at
    /// the Mac, since the phone can't seed the first one over the wire.
    private func updateEmptyState() {
        emptyState.isHidden = !terminals.isEmpty
        guard !emptyState.isHidden else { return }
        let canStart = store.terminalsProject?.rosterID != nil
        emptyState.configure(
            icon: .terminal,
            title: "No terminals yet",
            message: canStart
                ? "Terminals are plain shells that aren't tied to a project. Start one with ＋, or on your Mac."
                : "Terminals are plain shells that aren't tied to a project. Start one on your Mac and it appears here.",
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
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            self?.store.stopSession(sessionID)
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }
}
