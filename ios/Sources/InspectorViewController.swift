import TermioShared
import UIKit

/// The right-side drawer: Files (expandable tree) / Changes (diff list),
/// mirroring the desktop inspector's segmented layout. On a live companion
/// session the tree is the Mac project's real filesystem — directories load
/// lazily over the wire, tapping a file opens the full-screen read-only
/// viewer. Offline (mock sessions) it falls back to the bundled sample tree.
final class InspectorViewController: UIViewController {
    private enum Pane: Int { case files = 0, changes = 1 }

    private let session: MockSession
    private let companionURL: URL?
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let segment = UISegmentedControl(items: ["Files", "Changes"])
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let searchBar = UISearchBar()

    /// Offline sample tree (mock sessions, PoC streams).
    private var fileRows: [(node: FileNode, depth: Int)] = []
    /// Live tree mirrored from the Mac, built lazily one directory at a time.
    private var remoteRoots: [RemoteNode] = []
    private var remoteRows: [(node: RemoteNode, depth: Int)] = []
    private var client: CompanionClient?
    /// The file path awaiting a `.file` reply, so late/errored replies don't
    /// open stale viewers.
    private var pendingRead: String?
    /// The presented viewer, kept weak so save acks/conflicts route to it.
    private weak var activeViewer: FileViewerController?
    private var pane: Pane = .files

    /// Filename search. Live sessions search the *whole* repo on the Mac
    /// (`searchFiles`), since the on-device tree is only lazily loaded; results
    /// come back as repo-relative paths. Offline mocks filter the sample tree.
    private var isSearching = false
    private var searchQuery = ""
    private var remoteResults: [String] = []
    private var searchTruncated = false
    private var searchDebounce: DispatchWorkItem?
    private var fileResults: [FileNode] = []

    /// The file plane needs a companion link and a project to scope it to.
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
        segment.selectedSegmentIndex = 0
        segment.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            pane = Pane(rawValue: segment.selectedSegmentIndex) ?? .files
            // Search only applies to Files; leaving the pane drops out of it.
            if isSearching { endSearch() }
            updateRightBarButton()
            tableView.reloadData()
        }, for: .valueChanged)
        navigationItem.titleView = segment

        searchBar.delegate = self
        searchBar.placeholder = "Search files"
        searchBar.showsCancelButton = true
        searchBar.sizeToFit()

        tableView.dataSource = self
        tableView.delegate = self
        // Self-sizing rows: a fixed 44pt height left only ~2pt of slack over the
        // subheadline line height plus the content margins, so glyph descenders
        // (p, g, j) clipped at the bottom. Let each cell's content configuration
        // drive the height instead — it always reserves room for descenders, and
        // the two-line Changes rows breathe too.
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)

        // The spinner rides the nav bar only while a request is in flight. On
        // iOS 26 a bar button item is wrapped in a glass capsule, so leaving an
        // idle (zero-size) spinner attached leaves an empty glass circle
        // crowding the segment — attach it lazily instead.
        spinner.hidesWhenStopped = true

        if isLive {
            connectFilePlane()
        } else {
            reloadFileRows()
            updateRightBarButton()
        }
    }

    private func reloadFileRows() {
        fileRows = FileNode.visibleRows(from: FileNode.sampleRoot)
    }

    /// Show/hide the nav-bar spinner, attaching its bar button only while busy
    /// so no empty glass capsule lingers in the header when idle.
    private func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        } else {
            spinner.stopAnimating()
            updateRightBarButton()
        }
    }

    /// The right slot shows the search affordance when idle in the Files pane;
    /// the loading spinner and active search both claim it while they're up.
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

    private func beginSearch() {
        isSearching = true
        searchQuery = ""
        searchBar.text = ""
        remoteResults = []
        fileResults = []
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
        remoteResults = []
        fileResults = []
        searchTruncated = false
        updateRightBarButton()
        tableView.reloadData()
    }

    /// Live search runs on the Mac; debounce so each keystroke doesn't fire a
    /// whole-repo walk. The reply echoes its query so a stale batch is dropped.
    private func scheduleRemoteSearch() {
        searchDebounce?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            remoteResults = []
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
        remoteResults = paths
        searchTruncated = truncated
        tableView.reloadData()
    }

    private func rebuildOfflineResults() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        fileResults = query.isEmpty ? [] : Self.flatten(FileNode.sampleRoot)
            .filter { !$0.isDirectory && $0.name.lowercased().contains(query) }
    }

    private static func flatten(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    // MARK: - Live tree (companion file plane)

    /// A dedicated control connection for file browsing — the terminal's own
    /// socket is a raw PTY byte stream once attached, so it can't carry these.
    private func connectFilePlane() {
        guard let companionURL, let projectID = session.projectRosterID else { return }
        setLoading(true)
        let client = CompanionClient(url: companionURL)
        client.onConnected = { [weak self] connected in
            guard let self, connected, remoteRoots.isEmpty else { return }
            client.send(.listFiles(projectID: projectID, path: ""))
        }
        client.onFileList = { [weak self] path, entries in
            self?.receiveListing(path: path, entries: entries)
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
            guard let self else { return }
            // With no read in flight, the failed request was the viewer's write.
            if pendingRead == nil {
                activeViewer?.saveFailed(message)
                return
            }
            pendingRead = nil
            setLoading(false)
            let alert = UIAlertController(title: "Couldn't open file", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        client.start()
        self.client = client
    }

    private func receiveListing(path: String, entries: [WireFileEntry]) {
        setLoading(false)
        let nodes = entries.map { RemoteNode(entry: $0, parentPath: path) }
        if path.isEmpty {
            remoteRoots = nodes
        } else if let dir = findRemoteNode(path, in: remoteRoots) {
            dir.children = nodes
            dir.isExpanded = true
        }
        rebuildRemoteRows()
        if pane == .files { tableView.reloadData() }
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
            self?.requestFile(file.path)
        }
        activeViewer = viewer
        present(viewer, animated: true)
    }

    private func requestFile(_ path: String) {
        guard let projectID = session.projectRosterID else { return }
        pendingRead = path
        setLoading(true)
        client?.send(.readFile(
            projectID: projectID, path: path,
            // For the Mac-rendered Markdown preview — same trait contract as
            // `.trace`, so the page matches this screen's appearance.
            dark: traitCollection.userInterfaceStyle == .dark
        ))
    }

    private func findRemoteNode(_ path: String, in nodes: [RemoteNode]) -> RemoteNode? {
        for node in nodes {
            if node.relPath == path { return node }
            // Only walk ancestors of the target path.
            if node.isDir, path.hasPrefix(node.relPath + "/"),
               let children = node.children,
               let found = findRemoteNode(path, in: children) {
                return found
            }
        }
        return nil
    }

    private func rebuildRemoteRows(from nodes: [RemoteNode]? = nil, depth: Int = 0) {
        if depth == 0 { remoteRows = [] }
        for node in nodes ?? remoteRoots {
            remoteRows.append((node, depth))
            if node.isDir, node.isExpanded, let children = node.children {
                rebuildRemoteRows(from: children, depth: depth + 1)
            }
        }
    }

    /// The row's node as (name, project-relative path, isDir), resolving which
    /// backing list feeds this index (live vs mock, search vs tree). nil for
    /// non-file panes or a stale index.
    private func fileNode(at indexPath: IndexPath) -> (name: String, relPath: String, isDir: Bool)? {
        guard pane == .files else { return nil }
        if isSearching {
            if isLive {
                guard indexPath.row < remoteResults.count else { return nil }
                let path = remoteResults[indexPath.row]
                return ((path as NSString).lastPathComponent, path, false)
            }
            guard indexPath.row < fileResults.count else { return nil }
            return (fileResults[indexPath.row].name, "", fileResults[indexPath.row].isDirectory)
        }
        if isLive {
            guard indexPath.row < remoteRows.count else { return nil }
            let node = remoteRows[indexPath.row].node
            return (node.name, node.relPath, node.isDir)
        }
        guard indexPath.row < fileRows.count else { return nil }
        let node = fileRows[indexPath.row].node
        return (node.name, "", node.isDirectory)
    }

    /// Join a project-relative path onto the Mac's absolute project root, so
    /// "Copy Path" yields a full path ready to paste into an agent prompt.
    private func absolutePath(for relPath: String) -> String {
        guard let root = session.projectPath, !root.isEmpty else { return relPath }
        return relPath.isEmpty ? root : "\(root)/\(relPath)"
    }

    private static func changedDot() -> UIView {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 4
        return dot
    }
}

extension InspectorViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch pane {
        case .files where isSearching: isLive ? remoteResults.count : fileResults.count
        case .files: isLive ? remoteRows.count : fileRows.count
        case .changes: MockChange.samples.count
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard isSearching, pane == .files, searchTruncated else { return nil }
        return "Too many matches — showing the first batch. Refine to narrow."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "cell")
        switch pane {
        case .files where isSearching:
            guard let info = fileNode(at: indexPath) else { break }
            var config = cell.defaultContentConfiguration()
            config.text = info.name
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            let parent = (info.relPath as NSString).deletingLastPathComponent
            config.secondaryText = parent.isEmpty ? nil : parent
            config.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            config.secondaryTextProperties.color = .secondaryLabel
            let icon = FileIcons.icon(forFileName: info.name)
            config.image = icon.image
            config.imageProperties.tintColor = icon.tint
            config.imageProperties.maximumSize = CGSize(width: 16, height: 16)
            config.imageProperties.reservedLayoutSize = CGSize(width: 16, height: 16)
            cell.contentConfiguration = config
            cell.accessoryView = nil
            cell.accessoryType = .none
        case .files:
            let name: String, isDir: Bool, expanded: Bool, changed: Bool, depth: Int
            if isLive {
                let (node, d) = remoteRows[indexPath.row]
                (name, isDir, expanded, changed, depth) =
                    (node.name, node.isDir, node.isExpanded, node.changed, d)
            } else {
                let (node, d) = fileRows[indexPath.row]
                (name, isDir, expanded, changed, depth) =
                    (node.name, node.isDirectory, node.isExpanded, node.changed, d)
            }
            var config = cell.defaultContentConfiguration()
            config.text = name
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            if isDir {
                config.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
                config.imageProperties.tintColor = .secondaryLabel
                config.imageProperties.maximumSize = CGSize(width: 14, height: 14)
            } else {
                let icon = FileIcons.icon(forFileName: name)
                config.image = icon.image
                config.imageProperties.tintColor = icon.tint
                config.imageProperties.maximumSize = CGSize(width: 16, height: 16)
            }
            // Icons vary in width (chevron vs logo vs symbol); a fixed layout
            // box keeps every label at the same leading edge per depth.
            config.imageProperties.reservedLayoutSize = CGSize(width: 16, height: 16)
            config.directionalLayoutMargins.leading = CGFloat(depth) * 18 + 12
            cell.contentConfiguration = config
            cell.accessoryView = changed ? Self.changedDot() : nil
            cell.accessoryType = .none
        case .changes:
            let change = MockChange.samples[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = (change.path as NSString).lastPathComponent
            config.secondaryText = "\(change.kind)  +\(change.additions) −\(change.deletions)"
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            config.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            config.secondaryTextProperties.color = change.kind == "A" ? .systemGreen : .systemOrange
            cell.contentConfiguration = config
            cell.accessoryView = nil
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if isSearching, pane == .files {
            // Results are files only; offline mocks have no path to open.
            if isLive, let info = fileNode(at: indexPath) { requestFile(info.relPath) }
            return
        }
        switch pane {
        case .files where isLive:
            let (node, _) = remoteRows[indexPath.row]
            if node.isDir {
                if node.children != nil {
                    node.isExpanded.toggle()
                    rebuildRemoteRows()
                    tableView.reloadData()
                } else if let projectID = session.projectRosterID {
                    // First expand: fetch, then `receiveListing` opens it.
                    setLoading(true)
                    client?.send(.listFiles(projectID: projectID, path: node.relPath))
                }
            } else {
                requestFile(node.relPath)
            }
        case .files:
            let (node, _) = fileRows[indexPath.row]
            if node.isDirectory {
                node.isExpanded.toggle()
                reloadFileRows()
                tableView.reloadData()
            }
        case .changes:
            let change = MockChange.samples[indexPath.row]
            navigationController?.pushViewController(DiffViewController(change: change), animated: true)
        }
    }

    /// Long-press a file/folder row for its per-item actions — the iOS-native
    /// tree menu (Apple Files, and the session rows use the same). Only live
    /// rows carry a real Mac path, so the mock tree gets no menu.
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard isLive, let node = fileNode(at: indexPath) else { return nil }
        let absolute = absolutePath(for: node.relPath)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            if !node.isDir {
                actions.append(UIAction(
                    title: "Open", image: UIImage(systemName: "doc.text")
                ) { [weak self] _ in self?.requestFile(node.relPath) })
            }
            actions.append(UIAction(
                title: "Copy Path", image: UIImage(systemName: "doc.on.doc")
            ) { _ in UIPasteboard.general.string = absolute })
            return UIMenu(title: node.name, children: actions)
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

// MARK: - Remote tree node

/// One node of the live tree. `children == nil` means "not fetched yet" —
/// the first expand requests the listing and the reply fills it in.
private final class RemoteNode {
    let name: String
    let relPath: String
    let isDir: Bool
    let changed: Bool
    var children: [RemoteNode]?
    var isExpanded = false

    init(entry: WireFileEntry, parentPath: String) {
        name = entry.name
        relPath = parentPath.isEmpty ? entry.name : "\(parentPath)/\(entry.name)"
        isDir = entry.isDir
        changed = entry.changed
    }
}
