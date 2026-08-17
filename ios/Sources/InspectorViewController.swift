import TermioShared
import UIKit

/// The right-side drawer: Changes / Files, mirroring the desktop inspector's segmented
/// layout — with the phone's priority reversed. On a phone the question is "what did the
/// agent just touch", not "show me the tree", so **Changes leads**: the working diff,
/// straight from the Mac's git, and a tap opens the full-screen reader. Files is one tap
/// away and drills in one directory per screen (see `FileListViewController`).
///
/// On a live companion session both panes are the Mac's real project. Offline (mock
/// sessions) they fall back to the bundled sample tree and sample diff, which run
/// through exactly the same UI.
final class InspectorViewController: UIViewController {
    private enum Pane: Int { case changes = 0, files = 1 }

    private let session: MockSession
    private let companionURL: URL?
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let segment = UISegmentedControl(items: [localized("Changes"), localized("Files")])
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let searchBar = UISearchBar()
    private let refreshControl = UIRefreshControl()

    /// Bracketed-paste text into this session's terminal — the diff reader's "Send to
    /// Agent". Set by the terminal that owns this drawer; nil for a plain shell.
    var onSendToAgent: ((String) -> Void)?

    /// The project root's entries. Deeper directories live on pushed screens.
    private var rootEntries: [WireFileEntry] = []
    /// The working-tree changes, newest listing wins.
    private var changes: [WireChange] = []
    private var changesLoaded = false

    private var client: CompanionClient?
    /// Directory listings in flight, keyed by path — a pushed screen's reply must reach
    /// that screen, not whichever list asked last. A path can have more than one waiter
    /// (pull-to-refresh while the first load is still out), and dropping the earlier one
    /// would leave its screen spinning forever.
    private var listingHandlers: [String: [([WireFileEntry]) -> Void]] = [:]
    /// The file path awaiting a `.file` reply, so late/errored replies don't open stale
    /// viewers.
    private var pendingRead: String?
    /// The presented viewers, kept weak so replies route to whichever is up.
    private weak var activeViewer: FileViewerController?
    private weak var activeDiff: DiffViewController?
    private var pane: Pane = .changes

    /// Filename search. Live sessions search the *whole* repo on the Mac
    /// (`searchFiles`), since the on-device listing is one directory deep; results come
    /// back as repo-relative paths. Offline mocks filter the sample tree.
    private var isSearching = false
    private var searchQuery = ""
    private var searchResults: [String] = []
    private var searchTruncated = false
    private var searchDebounce: DispatchWorkItem?

    /// The file and changes planes need a companion link and a project to scope to.
    private var isLive: Bool { companionURL != nil && session.projectRosterID != nil }

    init(session: MockSession, companionURL: URL? = nil) {
        self.session = session
        self.companionURL = companionURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        client?.stop()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        segment.selectedSegmentIndex = Pane.changes.rawValue
        segment.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            pane = Pane(rawValue: segment.selectedSegmentIndex) ?? .changes
            // Search only applies to Files; leaving the pane drops out of it.
            if isSearching { endSearch() }
            updateRightBarButton()
            tableView.reloadData()
        }, for: .valueChanged)
        navigationItem.titleView = segment

        searchBar.delegate = self
        searchBar.placeholder = localized("Search files")
        searchBar.showsCancelButton = true
        searchBar.sizeToFit()

        tableView.dataSource = self
        tableView.delegate = self
        // Self-sizing rows: a fixed 44pt height left only ~2pt of slack over the
        // subheadline line height plus the content margins, so glyph descenders
        // (p, g, j) clipped at the bottom. Let each cell's content configuration drive
        // the height instead — it always reserves room for descenders, and the two-line
        // Changes rows breathe too.
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)

        // The spinner rides the nav bar only while a request is in flight. On iOS 26 a
        // bar button item is wrapped in a glass capsule, so leaving an idle (zero-size)
        // spinner attached leaves an empty glass circle crowding the segment — attach it
        // lazily instead.
        spinner.hidesWhenStopped = true

        if isLive {
            connectFilePlane()
        } else {
            rootEntries = FileNode.sampleEntries(at: "")
            changes = MockChanges.samples
            changesLoaded = true
            updateRightBarButton()
        }
    }

    /// Pull to refresh: re-ask for whatever the visible pane shows. Both lists are
    /// snapshots of a repo an agent is actively writing to, so a manual re-read is the
    /// honest affordance.
    private func refresh() {
        guard isLive, let projectID = session.projectRosterID else {
            refreshControl.endRefreshing()
            return
        }
        switch pane {
        case .changes:
            client?.send(.listChanges(projectID: projectID))
        case .files:
            listEntries(at: "") { [weak self] entries in
                self?.rootEntries = entries
                self?.tableView.reloadData()
            }
        }
    }

    /// Show/hide the nav-bar spinner, attaching its bar button only while busy so no
    /// empty glass capsule lingers in the header when idle.
    private func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        updateRightBarButton()
    }

    /// The right slot shows the search affordance when idle in the Files pane; the
    /// loading spinner and active search both claim it while they're up.
    private func updateRightBarButton() {
        guard pane == .files, !isSearching, !spinner.isAnimating else {
            navigationItem.rightBarButtonItem = spinner.isAnimating
                ? UIBarButtonItem(customView: spinner) : nil
            return
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            primaryAction: UIAction { [weak self] _ in self?.beginSearch() }
        )
    }

    // MARK: - Search

    private func beginSearch() {
        isSearching = true
        searchQuery = ""
        searchBar.text = ""
        searchResults = []
        searchTruncated = false
        tableView.tableHeaderView = searchBar
        updateRightBarButton()
        tableView.reloadData()
        searchBar.becomeFirstResponder()
    }

    private func endSearch() {
        searchDebounce?.cancel()
        isSearching = false
        searchQuery = ""
        searchBar.text = ""
        searchBar.resignFirstResponder()
        tableView.tableHeaderView = nil
        searchResults = []
        searchTruncated = false
        updateRightBarButton()
        tableView.reloadData()
    }

    /// Live search runs on the Mac; debounce so each keystroke doesn't fire a whole-repo
    /// walk. The reply echoes its query so a stale batch is dropped.
    private func scheduleRemoteSearch() {
        searchDebounce?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            searchTruncated = false
            tableView.reloadData()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let projectID = session.projectRosterID else { return }
            setLoading(true)
            client?.send(.searchFiles(projectID: projectID, query: query))
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func receiveSearchResults(query: String, paths: [String], truncated: Bool) {
        guard isSearching, query == searchQuery.trimmingCharacters(in: .whitespaces) else { return }
        setLoading(false)
        searchResults = paths
        searchTruncated = truncated
        tableView.reloadData()
    }

    private func rebuildOfflineResults() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        searchResults = query.isEmpty ? [] : FileNode.flattened()
            .filter { ($0 as NSString).lastPathComponent.lowercased().contains(query) }
    }

    // MARK: - Live planes (companion file + changes)

    /// A dedicated control connection for browsing — the terminal's own socket is a raw
    /// PTY byte stream once attached, so it can't carry these.
    private func connectFilePlane() {
        guard let companionURL, let projectID = session.projectRosterID else { return }
        setLoading(true)
        let client = CompanionClient(url: companionURL)
        client.onConnected = { [weak self] connected in
            guard let self, connected else { return }
            client.send(.listChanges(projectID: projectID))
            if rootEntries.isEmpty {
                listEntries(at: "") { [weak self] entries in
                    self?.rootEntries = entries
                    if self?.pane == .files { self?.tableView.reloadData() }
                }
            }
        }
        client.onFileList = { [weak self] path, entries in
            self?.receiveListing(path: path, entries: entries)
        }
        client.onChanges = { [weak self] files in
            self?.receiveChanges(files)
        }
        client.onDiff = { [weak self] diff in
            self?.activeDiff?.receive(diff)
        }
        client.onFile = { [weak self] file in
            self?.receiveFile(file)
        }
        client.onSearchResults = { [weak self] query, paths, truncated in
            self?.receiveSearchResults(query: query, paths: paths, truncated: truncated)
        }
        client.onWritten = { [weak self] _, mtime in
            self?.activeViewer?.didSave(mtime: mtime)
        }
        client.onError = { [weak self] message in
            self?.receiveError(message)
        }
        client.start()
        self.client = client
    }

    /// The wire's `.error` carries no request id, so the failure is attributed to
    /// whatever this drawer has outstanding, newest concern first.
    private func receiveError(_ message: String) {
        setLoading(false)
        refreshControl.endRefreshing()
        // Whatever the failure was, a Changes pane that never loaded has to stop saying
        // it is loading — the wire's `.error` carries no request id to tell us it was
        // ours, and "Loading changes…" forever is the worst of the readings.
        changesLoaded = true
        // A diff on screen owns any failure while it is waiting for one.
        if let activeDiff, activeDiff.isAwaitingDiff {
            activeDiff.failed(message)
            return
        }
        if pendingRead == nil {
            // A directory that never lands would leave its screen spinning forever —
            // answer the waiters with nothing so they settle on their empty state.
            if !listingHandlers.isEmpty {
                let waiting = listingHandlers.values.flatMap { $0 }
                listingHandlers = [:]
                for handler in waiting { handler([]) }
                return
            }
            // Nothing else was in flight, so the failed request was the viewer's write.
            activeViewer?.saveFailed(message)
            return
        }
        pendingRead = nil
        let alert = UIAlertController(title: localized("Couldn't open file"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: localized("OK"), style: .default))
        present(alert, animated: true)
    }

    private func receiveChanges(_ files: [WireChange]) {
        setLoading(false)
        refreshControl.endRefreshing()
        changes = files
        changesLoaded = true
        if pane == .changes { tableView.reloadData() }
    }

    private func receiveListing(path: String, entries: [WireFileEntry]) {
        setLoading(false)
        refreshControl.endRefreshing()
        guard let waiting = listingHandlers.removeValue(forKey: path) else { return }
        for handler in waiting { handler(entries) }
    }

    private func receiveFile(_ file: WireFile) {
        guard file.path == pendingRead else { return }
        pendingRead = nil
        setLoading(false)
        if file.binary {
            guard let quickLook = FileViewerController.quickLook(for: file) else { return }
            present(quickLook, animated: true)
            return
        }
        let viewer = FileViewerController(file: file)
        viewer.onSave = { [weak self] data, baseMtime in
            guard let self, let projectID = session.projectRosterID else { return }
            client?.send(.writeFile(
                projectID: projectID, path: file.path,
                base64: data.base64EncodedString(), baseMtime: baseMtime
            ))
        }
        viewer.onReload = { [weak self] in
            self?.openFile(at: file.path)
        }
        activeViewer = viewer
        present(viewer, animated: true)
    }

    /// The full-screen diff reader for the change at `index`, wired to this drawer's
    /// socket for its file walk. Offline it renders the sample diff through the same
    /// reader.
    private func openDiff(at index: Int) {
        let viewer = DiffViewController(files: changes, index: index)
        // `viewer` weakly: this closure is stored *on* the viewer, so capturing it
        // strongly would keep every diff ever opened — text storage and all — alive for
        // the app's lifetime.
        viewer.onRequestDiff = { [weak self, weak viewer] path, status in
            guard let self else { return }
            guard isLive, let projectID = session.projectRosterID else {
                viewer?.receive(WireDiff(path: path, text: MockChanges.sampleDiff))
                return
            }
            client?.send(.readDiff(projectID: projectID, path: path, status: status))
        }
        // A plain shell has no prompt to paste into; only an agent session gets the action.
        if session.agent.id != RosterAgent.terminal.id, let onSendToAgent {
            viewer.onSendToAgent = onSendToAgent
        }
        activeDiff = viewer
        present(viewer, animated: true)
    }
}

// MARK: - File browsing

extension InspectorViewController: RemoteFileBrowsing {
    func listEntries(at path: String, then: @escaping ([WireFileEntry]) -> Void) {
        guard isLive, let projectID = session.projectRosterID else {
            then(FileNode.sampleEntries(at: path))
            return
        }
        listingHandlers[path, default: []].append(then)
        setLoading(true)
        client?.send(.listFiles(projectID: projectID, path: path))
    }

    func openFile(at path: String) {
        guard isLive, let projectID = session.projectRosterID else { return }
        pendingRead = path
        setLoading(true)
        client?.send(.readFile(
            projectID: projectID, path: path,
            // For the Mac-rendered Markdown preview — same trait contract as `.trace`,
            // so the page matches this screen's appearance.
            dark: traitCollection.userInterfaceStyle == .dark
        ))
    }

    /// Join a project-relative path onto the Mac's absolute project root, so "Copy Path"
    /// yields a full path ready to paste into an agent prompt.
    func absolutePath(for relPath: String) -> String {
        guard let root = session.projectPath, !root.isEmpty else { return relPath }
        return relPath.isEmpty ? root : "\(root)/\(relPath)"
    }
}

// MARK: - Table

extension InspectorViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch pane {
        case .files where isSearching: searchResults.count
        case .files: rootEntries.count
        case .changes: changes.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard pane == .changes, !changes.isEmpty else { return nil }
        let totals = changes.reduce(into: (added: 0, deleted: 0)) {
            $0.added += $1.additions
            $0.deleted += $1.deletions
        }
        let files = changes.count == 1 ? localized("1 changed file") : localized("\(changes.count) changed files")
        return localized("\(files)  +\(totals.added) −\(totals.deleted)")
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if isSearching, pane == .files, searchTruncated {
            return localized("Too many matches — showing the first batch. Refine to narrow.")
        }
        if pane == .changes, changes.isEmpty {
            return changesLoaded
                ? localized("No changes in this project's working tree.")
                : localized("Loading changes…")
        }
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "cell")
        switch pane {
        case .files where isSearching:
            guard indexPath.row < searchResults.count else { break }
            let path = searchResults[indexPath.row]
            let parent = (path as NSString).deletingLastPathComponent
            FileRow.configure(
                cell,
                entry: WireFileEntry(name: (path as NSString).lastPathComponent, isDir: false),
                subtitle: parent.isEmpty ? nil : parent
            )
        case .files:
            guard indexPath.row < rootEntries.count else { break }
            FileRow.configure(cell, entry: rootEntries[indexPath.row])
        case .changes:
            guard indexPath.row < changes.count else { break }
            let change = changes[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = change.name
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            config.secondaryText = change.caption
            config.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            config.secondaryTextProperties.color = .secondaryLabel
            config.secondaryTextProperties.lineBreakMode = .byTruncatingHead
            config.image = Self.statusBadge(for: change.status)
            config.imageProperties.tintColor = Self.statusTint(for: change.status)
            config.imageProperties.maximumSize = CGSize(width: 17, height: 17)
            config.imageProperties.reservedLayoutSize = CGSize(width: 17, height: 17)
            cell.contentConfiguration = config
            cell.accessoryView = nil
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if isSearching, pane == .files {
            // Results are files only; offline mocks have no content to open.
            guard indexPath.row < searchResults.count else { return }
            openFile(at: searchResults[indexPath.row])
            return
        }
        switch pane {
        case .files:
            guard indexPath.row < rootEntries.count else { return }
            let entry = rootEntries[indexPath.row]
            if entry.isDir {
                navigationController?.pushViewController(
                    FileListViewController(path: entry.name, browser: self), animated: true
                )
            } else {
                openFile(at: entry.name)
            }
        case .changes:
            guard indexPath.row < changes.count else { return }
            openDiff(at: indexPath.row)
        }
    }

    /// Long-press a file/folder row for its per-item actions — the iOS-native tree menu
    /// (Apple Files, and the session rows use the same). Only live rows carry a real Mac
    /// path, so the mock tree gets no menu.
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard isLive else { return nil }
        switch pane {
        case .files where isSearching:
            guard indexPath.row < searchResults.count else { return nil }
            let path = searchResults[indexPath.row]
            let entry = WireFileEntry(name: (path as NSString).lastPathComponent, isDir: false)
            return FileRow.menu(for: entry, in: (path as NSString).deletingLastPathComponent, browser: self)
        case .files:
            guard indexPath.row < rootEntries.count else { return nil }
            return FileRow.menu(for: rootEntries[indexPath.row], in: "", browser: self)
        case .changes:
            guard indexPath.row < changes.count else { return nil }
            let change = changes[indexPath.row]
            return FileRow.menu(
                for: WireFileEntry(name: change.name, isDir: false),
                in: (change.path as NSString).deletingLastPathComponent, browser: self
            )
        }
    }

    /// git's status letter as its own glyph — the desktop's single-letter badge, in the
    /// shape iOS already draws for lettered markers.
    private static func statusBadge(for status: String) -> UIImage? {
        let name = status.lowercased()
        guard let first = name.first, first.isLetter else {
            return UIImage(systemName: "exclamationmark.square")
        }
        return UIImage(systemName: "\(first).square")
    }

    private static func statusTint(for status: String) -> UIColor {
        switch status {
        case "A", "U": return .systemGreen
        case "D": return .systemRed
        case "R", "C": return .systemOrange
        case "!": return .systemYellow
        default: return .systemBlue
        }
    }
}

extension InspectorViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchQuery = searchText
        if isLive {
            scheduleRemoteSearch()
        } else {
            rebuildOfflineResults()
            tableView.reloadData()
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        endSearch()
    }
}
