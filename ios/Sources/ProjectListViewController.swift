import SwiftUI
import TermioShared
import UIKit

/// The root screen: the project list, with a "Needs You" strip pinned above
/// it. GitHub-mobile shape — the backbone is "what do I have open" (one row
/// per project, with a status summary so nothing needs opening to check on),
/// while the strip keeps the phone's highest-frequency question ("which agent
/// is waiting on me?") answerable at a glance and one tap from its terminal.
/// Tapping a project pushes its page (sessions + new-session). Lives at the
/// root of the home navigation stack inside RootContainerViewController.
final class ProjectListViewController: UIViewController {
    private let store: RosterStore

    private enum Section { case needsYou, projects }
    /// The sections currently on screen, rebuilt on every roster change.
    private var sections: [Section] = []
    /// Cross-project attention sessions (the strip's rows).
    private var attention: [MockSession] = []
    /// The store's projects in the chosen order — what the table shows.
    /// Chats-kind containers are excluded: they have their own tab.
    private var visible: [MockProject] = []

    /// Mirrors the Mac sidebar's sort pull-down. The roster arrives in the
    /// Mac's recent-activity order, so "Recent Activity" means "as pushed";
    /// "Name" re-sorts locally A→Z.
    private var sortByName = UserDefaults.standard.string(forKey: "sessions.sortOrder") == "name"

    private let filterButton = UIButton(type: .system)
    private let newSessionButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    /// The Telegram/iMessage-style zero state shown when there are no projects
    /// to list — never fake rows. Its copy tracks `CompanionLink.state`.
    private let emptyState = ListEmptyStateView()
    /// Set once a `.connecting` state has lingered past the grace window, so the
    /// zero state escalates from "Connecting…" to "Can't reach your Mac".
    private var reconnectStalled = false
    private var connectingGraceTimer: Timer?
    private var rosterObserver: NSObjectProtocol?
    private var linkStateObserver: NSObjectProtocol?

    init(store: RosterStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A full page, not a drawer: plain system background, like the
        // Messages inbox.
        view.backgroundColor = .systemBackground
        let topBar = configureTopBar()
        configureTable(below: topBar)
        configureEmptyState(below: topBar)
        // Added last so it floats over the list, opposite the home tab pill.
        configureNewSessionButton()
        refilter()
        rosterObserver = NotificationCenter.default.addObserver(
            forName: RosterStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refilter() }
        }
        // The zero-state copy ("No Mac connected" → "Connecting…" → the empty
        // roster) follows the live link state, not just roster pushes.
        linkStateObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateEmptyState() }
        }
    }

    deinit {
        if let rosterObserver {
            NotificationCenter.default.removeObserver(rosterObserver)
        }
        if let linkStateObserver {
            NotificationCenter.default.removeObserver(linkStateObserver)
        }
        connectingGraceTimer?.invalidate()
    }

    func refresh() {
        tableView.reloadData()
    }

    // MARK: - Top bar (large title + sort)

    private func configureTopBar() -> UIView {
        let pageTitle = UILabel()
        pageTitle.text = "Projects"
        pageTitle.font = .systemFont(ofSize: 34, weight: .bold)
        pageTitle.textColor = .label

        // The Mac sidebar's sort pull-down, translated to iMessage chrome:
        // a glass circle riding the large title, menu as primary action.
        filterButton.applyGlassSymbol("line.3.horizontal.decrease")
        filterButton.tintColor = .label
        filterButton.accessibilityLabel = "Sort"
        filterButton.showsMenuAsPrimaryAction = true
        filterButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.sortMenuItems() ?? [])
            },
        ])

        let spacer = UIView()
        let bar = UIStackView(arrangedSubviews: [pageTitle, spacer, filterButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            // Telegram's nav-bar glass buttons are 40pt circles.
            filterButton.widthAnchor.constraint(equalToConstant: 40),
            filterButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        return bar
    }

    /// The same two orders as the Mac's sort menu, checkmarked like it too.
    private func sortMenuItems() -> [UIMenuElement] {
        [
            UIAction(title: "Recent Activity", state: sortByName ? .off : .on) { [weak self] _ in
                self?.setSortByName(false)
            },
            UIAction(title: "Name", state: sortByName ? .on : .off) { [weak self] _ in
                self?.setSortByName(true)
            },
        ]
    }

    private func setSortByName(_ byName: Bool) {
        sortByName = byName
        UserDefaults.standard.set(byName ? "name" : "recentActivity", forKey: "sessions.sortOrder")
        refilter()
    }

    // MARK: - New-session button (the floating ＋)

    /// ＋ floats bottom-right like Slack's compose button — the same corner as
    /// the Chats tab's ＋, so "start something new" always lives in one place.
    /// A project must be picked first, so the menu is one submenu per project
    /// with the agents inside (the long-press menu, made discoverable);
    /// deferred so it always reflects the live roster, hidden while unpaired.
    private func configureNewSessionButton() {
        newSessionButton.applyGlassSymbol("plus", pointSize: 22)
        newSessionButton.tintColor = .label
        newSessionButton.accessibilityLabel = "New Session"
        newSessionButton.showsMenuAsPrimaryAction = true
        newSessionButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                completion(visible.filter { $0.rosterID != nil }.map { project in
                    UIMenu(
                        title: project.name,
                        image: UIImage(systemName: "folder"),
                        children: self.store.newSessionActions(in: project)
                    )
                })
            },
        ])
        newSessionButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newSessionButton)
        NSLayoutConstraint.activate([
            newSessionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            // The tab pill's own scale (64pt, 8pt above the safe area), so the
            // two ends of the bottom edge read as one balanced bar.
            newSessionButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            newSessionButton.widthAnchor.constraint(equalToConstant: 64),
            newSessionButton.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    private func presentSettings() {
        // The sheet inherits the window's app-wide Appearance override, same
        // as every other screen.
        present(UINavigationController(rootViewController: SettingsViewController()), animated: true)
    }

    // MARK: - Table

    private func configureTable(below topBar: UIView) {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        // Hairlines between rows are drawn inside the rows (RowSeparator):
        // grouped tables render their own separators full-width at section
        // edges, which fights the whitespace-gap grouping.
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        // Groups are split by whitespace, not a line: a fixed footer gap under
        // each group. Zeroing the *estimates* keeps the table from adding its
        // own phantom footer height on top of ours.
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.register(
            SectionCapView.self,
            forHeaderFooterViewReuseIdentifier: SectionCapView.reuseID
        )
        tableView.translatesAutoresizingMaskIntoConstraints = false
        // The floating tab pill sits over the list; reserve room so the last
        // rows scroll clear of it (64pt pill + margins).
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

    /// Rebuild the section list from the store: the attention strip (only when
    /// non-empty), then the projects in the chosen order. Chats-kind containers
    /// belong to the Chats tab — their attention sessions still surface in the
    /// strip here, the cross-cutting shortcut.
    private func refilter() {
        attention = store.attentionSessions
        let ordered = sortByName
            ? store.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            : store.projects
        visible = ordered.filter { $0.kind != "chats" }
        sections = (attention.isEmpty ? [] : [.needsYou]) + [.projects]
        newSessionButton.isHidden = store.companionURL == nil
            || !visible.contains { $0.rosterID != nil }
        tableView.reloadData()
        updateEmptyState()
    }

    // MARK: - Empty state

    private func configureEmptyState(below topBar: UIView) {
        emptyState.isHidden = true
        // The button's job depends on the state: unpaired → go pair a Mac in
        // Settings; stalled reconnect → kick the socket now ("Try Again").
        emptyState.onAction = { [weak self] in self?.emptyStateAction() }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Show the zero state only when there are genuinely no rows, and phrase it
    /// for where the link is: unpaired (onboard), connecting (reassure) →
    /// stalled (the Mac isn't answering — offer Try Again), or connected-but-idle
    /// (nudge toward opening a project on the Mac).
    private func updateEmptyState() {
        emptyState.isHidden = !visible.isEmpty || !attention.isEmpty
        guard !emptyState.isHidden else {
            stopConnectingGraceTimer()
            return
        }
        switch CompanionLink.state {
        case .unpaired:
            stopConnectingGraceTimer()
            reconnectStalled = false
            emptyState.configure(
                symbol: "macbook.and.iphone",
                title: "No Mac connected",
                message: "Open termio on your Mac, then pair this phone to see and drive your projects from here.",
                actionTitle: "Connect a Mac",
                busy: false
            )
        case .connecting where reconnectStalled:
            // The socket has been down long enough that the Mac is probably
            // asleep or off-network. Say so, and let the user force a retry —
            // the link keeps trying on its slow heartbeat regardless.
            emptyState.configure(
                symbol: "wifi.exclamationmark",
                title: "Can't reach your Mac",
                message: "It may be asleep or off your network. termio keeps trying — reopen the lid, or tap to retry now.",
                actionTitle: "Try Again",
                busy: false
            )
        case .connecting:
            startConnectingGraceTimer()
            emptyState.configure(
                symbol: nil,
                title: "Connecting…",
                message: "Reaching your Mac over the companion link.",
                actionTitle: nil,
                busy: true
            )
        case .connected:
            stopConnectingGraceTimer()
            reconnectStalled = false
            emptyState.configure(
                symbol: "folder",
                title: "No projects open",
                message: "Open a project in termio on your Mac and it'll show up here.",
                actionTitle: nil,
                busy: false
            )
        }
    }

    /// After ~15s of unbroken "Connecting…", assume the Mac isn't coming right
    /// back and escalate the copy. Foreground/path events that reconnect will
    /// flip the state to `.connected` and cancel this.
    private func startConnectingGraceTimer() {
        guard connectingGraceTimer == nil, !reconnectStalled else { return }
        connectingGraceTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connectingGraceTimer = nil
                self.reconnectStalled = true
                self.updateEmptyState()
            }
        }
    }

    private func stopConnectingGraceTimer() {
        connectingGraceTimer?.invalidate()
        connectingGraceTimer = nil
    }

    /// The zero-state button. Unpaired → open pairing; stalled → force an
    /// immediate reconnect and drop back to the "Connecting…" copy.
    private func emptyStateAction() {
        if case .unpaired = CompanionLink.state {
            presentSettings()
            return
        }
        reconnectStalled = false
        updateEmptyState()
        store.reconnectNow()
    }
}

// MARK: - Table data source / delegate

extension ProjectListViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .needsYou: attention.count
        case .projects: visible.count
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        // Headers only when the strip splits the page in two; a plain project
        // list under the "Projects" page title needs no second label.
        guard sections.count > 1 else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: SectionCapView.reuseID
        ) as! SectionCapView
        header.configure(title: sections[section] == .needsYou ? "Needs You" : "Projects")
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections.count > 1 ? 28 : 0
    }

    /// A whitespace gap below each group — the divider-free separator,
    /// matching the macOS sidebar's spacing-based grouping.
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
        switch sections[indexPath.section] {
        case .needsYou:
            let session = attention[indexPath.row]
            cell.contentConfiguration = UIHostingConfiguration {
                SessionRow(
                    session: session,
                    isCurrent: session.key == store.currentSessionKey,
                    showsProject: true,
                    showsSeparator: indexPath.row < attention.count - 1
                )
            }
            .margins(.horizontal, 12)
            .margins(.vertical, 0)
        case .projects:
            cell.contentConfiguration = UIHostingConfiguration {
                ProjectRow(
                    project: visible[indexPath.row],
                    showsSeparator: indexPath.row < visible.count - 1
                )
            }
            .margins(.horizontal, 12)
            .margins(.vertical, 0)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch sections[indexPath.section] {
        case .needsYou:
            // Straight to the terminal — the strip exists so the blocked
            // session is one tap away, never behind its project page.
            store.openSession(attention[indexPath.row])
        case .projects:
            navigationController?.pushViewController(
                ProjectDetailViewController(store: store, project: visible[indexPath.row]),
                animated: true
            )
        }
    }

    /// Trailing swipe on a strip row: the Mac session menu's "Close Session".
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard sections[indexPath.section] == .needsYou,
              store.companionURL != nil,
              let sessionID = attention[indexPath.row].rosterID
        else { return nil }
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            self?.store.stopSession(sessionID)
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }

    /// Long-press a project: the new-session menu, so starting an agent does
    /// not require drilling in first.
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard sections[indexPath.section] == .projects else { return nil }
        let project = visible[indexPath.row]
        guard store.companionURL != nil, project.rosterID != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: project.name, children: self?.store.newSessionActions(in: project) ?? [])
        }
    }
}

// MARK: - Project row

/// One project: the folder mark, the name over the branch (repos only — the
/// row collapses to one line otherwise), and a status summary trailing — the
/// most urgent state wins (attention count in orange, else a working spinner,
/// else the done dot), so a glance down the list covers every project without
/// opening one.
private struct ProjectRow: View {
    let project: MockProject
    var showsSeparator = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HugeIconShape(icon: .folder)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let branch = project.branch {
                    Text(branch)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            summary
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        // Fill the hosting cell (see SessionRow): centers the content and
        // pins the separator to the real cell bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Inset past the folder mark (10 padding + 18 icon + 10 spacing).
        .overlay(alignment: .bottom) {
            if showsSeparator { RowSeparator(leadingInset: 38) }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let attention = project.sessions.count { $0.status == .needsAttention }
        let working = project.sessions.count { $0.status == .working }
        let done = project.sessions.count { $0.status == .done }
        if attention > 0 {
            HStack(spacing: 4) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text("\(attention)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        } else if working > 0 {
            WorkingIndicator(tint: .secondary)
        } else if done > 0 {
            Circle().fill(.green).frame(width: 7, height: 7)
        }
    }
}

// MARK: - Section header

/// A small gray caps label capping a group — only used when the attention
/// strip splits the root page into two groups.
private final class SectionCapView: UITableViewHeaderFooterView {
    static let reuseID = "sectionCap"

    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.text = title.uppercased()
    }
}
