import SwiftUI
import TermioShared
import UIKit

/// One project's page: its sessions as a plain list, with the ＋ (new session
/// per enabled agent) floating bottom-right — the compose corner, same as the
/// Chats tab. Pushed from the Projects root; tapping a session slides its
/// terminal in over everything, so coming back lands here. Tracks the live
/// roster by the project's stable key and pops itself if the Mac closes the
/// project.
final class ProjectDetailViewController: UIViewController {
    private let store: RosterStore
    private let projectKey: String
    /// The latest roster snapshot of this project, replaced on every push
    /// while the project is alive. When the link merely drops, the store
    /// keeps its last roster, so this page shows the stale snapshot too —
    /// same as the root list.
    private var project: MockProject

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let addButton = UIButton(type: .system)
    private let emptyState = ListEmptyStateView()
    private var rosterObserver: NSObjectProtocol?

    /// `project` is the caller's row — the live roster entry at push time.
    init(store: RosterStore, project: MockProject) {
        self.store = store
        self.projectKey = project.stableKey
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let topBar = configureTopBar()
        configureTable(below: topBar)
        configureEmptyState(below: topBar)
        // Added last so it floats over the list.
        configureAddButton()
        reload()
        rosterObserver = NotificationCenter.default.addObserver(
            forName: RosterStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
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

    /// Re-read this project from the store. Missing means it's really gone —
    /// closed on the Mac, or the pairing was forgotten (a dropped link keeps
    /// the store's last roster, so it doesn't land here) — and a page with no
    /// subject pops back to the root.
    private func reload() {
        guard let live = store.project(forKey: projectKey) else {
            navigationController?.popToRootViewController(animated: true)
            return
        }
        project = live
        addButton.isHidden = store.companionURL == nil || project.rosterID == nil
        tableView.reloadData()
        updateEmptyState()
    }

    // MARK: - Top bar (back + title)

    private func configureTopBar() -> UIView {
        let back = UIButton(type: .system)
        back.applyGlassSymbol("chevron.backward")
        back.tintColor = .label
        back.accessibilityLabel = "Back"
        back.accessibilityIdentifier = "project.back"
        back.addAction(UIAction { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        }, for: .touchUpInside)

        let pageTitle = UILabel()
        pageTitle.text = project.name
        pageTitle.font = .systemFont(ofSize: 28, weight: .bold)
        pageTitle.textColor = .label
        pageTitle.lineBreakMode = .byTruncatingTail
        pageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = UIStackView(arrangedSubviews: [back, pageTitle])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        // The branch (or the path, for non-repos) under the title — the same
        // line the project row previews, kept here so the page says where the
        // sessions run.
        let context = UILabel()
        context.text = project.branch ?? abbreviatedPath
        context.font = .systemFont(ofSize: 13)
        context.textColor = .secondaryLabel
        context.lineBreakMode = .byTruncatingMiddle
        context.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(context)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            back.widthAnchor.constraint(equalToConstant: 40),
            back.heightAnchor.constraint(equalToConstant: 40),
            // Indented to the title's left edge (past the back chevron).
            context.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 62),
            context.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            context.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 0),
        ])

        // The table hangs below the deeper of the two lines.
        let anchor = UIView()
        anchor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(anchor)
        NSLayoutConstraint.activate([
            anchor.topAnchor.constraint(equalTo: context.bottomAnchor),
            anchor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            anchor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            anchor.heightAnchor.constraint(equalToConstant: 0),
        ])
        return anchor
    }

    // MARK: - Add button (the floating ＋)

    /// The Mac project menu's "New … Session" actions — ＋ floats bottom-right
    /// like Slack's compose button, the same corner every home screen uses,
    /// balancing the tab pill bottom-left. Live rosters only; the bundled mock
    /// can't start anything.
    private func configureAddButton() {
        addButton.applyGlassIcon(.add, boxSize: 26)
        addButton.tintColor = .label
        addButton.accessibilityLabel = "New session in \(project.name)"
        addButton.showsMenuAsPrimaryAction = true
        addButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                completion(store.newSessionActions(in: project))
            },
        ])
        addButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            // The tab pill's own scale (64pt, 8pt above the safe area), so the
            // two ends of the bottom edge read as one balanced bar.
            addButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            addButton.widthAnchor.constraint(equalToConstant: 64),
            addButton.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    /// "~/Documents/GitHub/termio" — home-relative, like the Mac's chrome.
    private var abbreviatedPath: String {
        let path = project.path
        guard !path.isEmpty else { return "" }
        let home = "/Users/"
        guard path.hasPrefix(home), let slash = path.dropFirst(home.count).firstIndex(of: "/")
        else { return path }
        return "~" + path[slash...]
    }

    // MARK: - Table

    private func configureTable(below topBar: UIView) {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        // Hairlines between rows are drawn inside the rows (RowSeparator),
        // matching the root page.
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "session")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        // The floating ＋ sits over the list; reserve room so the last rows
        // scroll clear of it.
        tableView.contentInset.bottom = 80
        tableView.verticalScrollIndicatorInsets.bottom = 80
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Empty state

    private func configureEmptyState(below topBar: UIView) {
        emptyState.isHidden = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func updateEmptyState() {
        emptyState.isHidden = !project.sessions.isEmpty
        guard !emptyState.isHidden else { return }
        emptyState.configure(
            icon: .inbox,
            title: "No sessions",
            message: addButton.isHidden
                ? "Start a session on your Mac and it'll show up here."
                : "Tap ＋ to start an agent in this project.",
            actionTitle: nil,
            busy: false
        )
    }
}

// MARK: - Table data source / delegate

extension ProjectDetailViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        project.sessions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "session", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let session = project.sessions[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            SessionRow(
                session: session,
                isCurrent: session.key == store.currentSessionKey,
                showsSeparator: indexPath.row < project.sessions.count - 1
            )
        }
        .margins(.horizontal, 12)
        .margins(.vertical, 0)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        store.openSession(project.sessions[indexPath.row])
    }

    /// Trailing swipe: the Mac session menu's "Close Session".
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard store.companionURL != nil,
              let sessionID = project.sessions[indexPath.row].rosterID
        else { return nil }
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            self?.store.stopSession(sessionID)
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard store.companionURL != nil,
              let sessionID = project.sessions[indexPath.row].rosterID
        else { return nil }
        let title = project.sessions[indexPath.row].title
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: title, children: [
                UIAction(
                    title: "Close Session",
                    image: UIImage(systemName: "xmark.circle"),
                    attributes: .destructive
                ) { _ in
                    self?.store.stopSession(sessionID)
                },
            ])
        }
    }
}
