import AppKit
import Quartz
import SwiftUI

/// The trailing inspector's content: a native disclosure tree of the selected
/// session's project, rooted at the project (or worktree) directory. Selecting a
/// file and pressing space opens it in Quick Look (Finder's gesture); dragging
/// files from the Finder onto the panel copies them into the project root.
struct FileBrowserView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var browserState: FileBrowserState
    /// Toggles the shared Quick Look panel — supplied by the hosting controller,
    /// which is the responder that drives `QLPreviewPanel`.
    let onQuickLook: () -> Void
    /// Double-clicking a file activates it: the hosting controller routes a previewable
    /// file (image, PDF, HTML) to Quick Look and everything else to the code editor.
    let onActivate: (URL) -> Void

    @State private var root: FileNode?
    /// Bumped to collapse the whole tree: it is the file list's `.id`, so changing it
    /// rebuilds the list fresh — and a fresh `List(children:)` starts fully collapsed.
    @State private var treeGeneration = 0
    /// Bumped after `applyTreeChanges` mutates realized directories in place, so the
    /// list runs an update pass and the mutation reaches the rows (the `root`
    /// reference itself never changes on an incremental reload).
    @State private var treeRevision = 0
    /// Bumped per `refresh()` call; an off-main root read that finishes after a newer
    /// refresh (or after the project moved) compares stale and discards its result,
    /// so roots can never land out of order.
    @State private var refreshGeneration = 0
    /// Reload targets accumulated while a reload is already in flight, keyed by URL
    /// so repeat events for one directory coalesce. Unioned rather than replaced —
    /// a newer batch must never orphan an older disjoint one, or those directories
    /// would stay stale until their next event. Drained by `runPendingReloads`.
    @State private var pendingReloads: [URL: FileNode] = [:]
    /// True while `runPendingReloads`'s serial loop is draining; batches arriving
    /// meanwhile just extend `pendingReloads` and become the next lap.
    @State private var reloadInFlight = false
    /// Watches the project root on disk and bumps its `changeToken` when anything under
    /// it changes, so the tree stays live with an agent's edits (see `onChange` below).
    @StateObject private var watcher = FileTreeWatcher()
    /// A watcher bump that arrived while the inspector was collapsed. The view stays in
    /// the hierarchy when the pane is hidden, so without parking, every disk change under
    /// the project root would rebuild the tree (a full outline re-diff plus a `git status`)
    /// that nobody can see — on a busy root that is a continuous main-thread drain. Same
    /// parking pattern as `GitPanelModel`; replayed once when the pane is next visible.
    @State private var pendingWatcherRefresh = false

    /// The host of the selected session when it is an SSH session. Non-nil means the
    /// local disk isn't this session's disk: `inspectorProjectPath` resolves to nil,
    /// so the watcher, the root read, and the drop target all stand down on their own.
    private var sshHost: String? {
        store.selectedSessionID.flatMap(store.session)?.sshHost
    }

    /// The directory the tree is rooted at — see `TermioStore.inspectorProjectPath`.
    private var projectPath: String? { store.inspectorProjectPath }

    var body: some View {
        ZStack {
            // The Files pane is ALWAYS mounted; a tab switch merely covers it. A
            // fresh `List(children:)` re-realizes every row of the outline, which
            // on a huge root (a home directory) costs whole seconds per switch —
            // and loses the tree's disclosure state besides (#207). Same
            // always-mounted-under-an-opaque-overlay shape as `InspectorRoot`.
            Group {
                if let host = sshHost {
                    // Fresh identity per host, so tree state never leaks between hosts.
                    RemoteFileTreeView(host: host)
                        .id(host)
                } else {
                    VStack(spacing: 0) {
                        if let root { header(root: root) }
                        content
                    }
                }
            }
            .allowsHitTesting(store.inspectorTab == .files)
            .accessibilityHidden(store.inspectorTab != .files)
            if store.inspectorTab != .files {
                activePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Opaque terminal background so the live tree never shows through.
                    .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
            }
        }
        // The file column lives on the terminal side, so it takes the terminal's own background
        // (rather than a sidebar material) — it reads as an extension of the content area. Fills
        // the whole column behind the transparent list, ignoring the safe area so it runs
        // full-height. Tracks the terminal theme live via `settings`.
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        // A single full-height hairline on the leading edge as the border with the terminal. A
        // slightly-bright line (rather than the dim system separator) reads as a clean luminous
        // edge on its own, echoing the leading sidebar's glowing border — no soft bloom gradient.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 1)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        // A drop on empty space targets the project root: a file already in the tree
        // is *moved* there, a file dragged in from the Finder is *copied* in. Folder
        // rows install their own, more specific drop targets (see `FileTreeList`), so
        // this only catches drops that miss every row. No panel-wide target ring —
        // dragging a row out is itself a `URL` drag, so a whole-panel highlight would
        // be a false positive; the folder rows light up individually instead.
        .dropDestination(for: URL.self) { urls, _ in
            guard let projectPath else { return false }
            return receive(urls, into: URL(fileURLWithPath: projectPath))
        }
        .onAppear { refresh(); seedChangeCount(); watcher.watch(projectPath) }
        .onDisappear { watcher.watch(nil) }
        .onChange(of: projectPath) {
            refresh()
            seedChangeCount()
            watcher.watch(projectPath)
        }
        // Files changed under the root (an agent wrote, renamed, or removed some):
        // reload just the realized directories that were touched. Never fires for
        // version-control metadata (see `FileTreeWatcher`). Keep the Changes badge
        // fresh too — edits move the dirty count — unless the Changes pane is open;
        // it owns the count live while visible. A hidden pane parks one full refresh
        // instead (see `pendingWatcherRefresh`).
        .onChange(of: watcher.treeToken) {
            guard store.inspectorVisible else {
                pendingWatcherRefresh = true
                return
            }
            applyTreeChanges()
            if store.inspectorTab != .changes { seedChangeCount() }
        }
        // Git metadata moved meaningfully (a stage, commit, or checkout): the tree
        // shows none of it, so only the Changes badge needs a re-count.
        .onChange(of: watcher.gitToken) {
            guard store.inspectorVisible else {
                pendingWatcherRefresh = true
                return
            }
            if store.inspectorTab != .changes { seedChangeCount() }
        }
        .onChange(of: store.inspectorVisible) { _, visible in
            guard visible, pendingWatcherRefresh else { return }
            pendingWatcherRefresh = false
            refresh()
            if store.inspectorTab != .changes { seedChangeCount() }
        }
        // Covering or uncovering the always-mounted tree resets its scroll view's
        // wheel increment (SwiftUI re-configures the scroll view on the overlay
        // flip, and no row update follows to heal it — see `OutlineViewFixups`);
        // reassert once the switch's update pass has settled.
        .onChange(of: store.inspectorTab) {
            let outline = browserState.outlineView
            DispatchQueue.main.async { OutlineViewFixups.assertWheelIncrement(on: outline) }
        }
        .onChange(of: browserState.selection) {
            // The table fires native selection on a clean click — reliably, unlike a
            // click recognizer, which `NSOutlineView`'s own primary-button tracking
            // swallows. So selection IS the click handler: a file opens, a folder opens
            // (expands). Collapse stays on the disclosure triangle.
            if let url = browserState.selection {
                if isDirectory(url) {
                    toggleSelectedFolder()
                } else {
                    onActivate(url)
                }
            }
            // Keep an open Quick Look panel in step as the selection moves.
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }
    }

    /// Toggle (expand/collapse) the folder whose row was just selected, on the native
    /// outline view — the click that selected it is the only signal we get (the outline
    /// view swallows primary-click recognizers), so clicking a folder row IS "open/close
    /// it". Afterward we clear the selection: an unchanged selection wouldn't re-fire
    /// this handler, so a second click on the *same* folder (to collapse it) would go
    /// unseen — resetting to nil makes every click on a folder register. Folders thus
    /// don't hold a persistent highlight; files (which stay selected/open) are untouched.
    private func toggleSelectedFolder(attempt: Int = 0) {
        guard let outline = browserState.outlineView else { return }
        let row = outline.selectedRow
        // The AppKit selection normally already reflects the click that drove this
        // change; if it hasn't caught up yet, retry a couple of runloop turns.
        guard row >= 0, let item = outline.item(atRow: row) else {
            if attempt < 3 {
                DispatchQueue.main.async { toggleSelectedFolder(attempt: attempt + 1) }
            }
            return
        }
        guard outline.isExpandable(item) else { return }
        if outline.isItemExpanded(item) {
            outline.animator().collapseItem(item)
        } else {
            outline.animator().expandItem(item)
        }
        browserState.selection = nil
    }

    /// Whether `url` points at a directory — used to open only files on selection.
    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The non-Files pane covering the always-mounted tree (see `body`).
    @ViewBuilder
    private var activePane: some View {
        switch store.inspectorTab {
        case .files:
            EmptyView()
        case .search:
            if sshHost != nil {
                remoteUnavailable(pane: localized("Search"))
            } else if let root {
                FileSearchView(
                    rootURL: root.url,
                    onDismiss: { store.inspectorTab = .files },
                    onOpen: { url, line in store.openFileInEditor(url, at: line) }
                )
                // Fresh identity per project, so a stale query/result set
                // doesn't carry over when the root moves.
                .id(root.url)
            } else {
                noProject
            }
        case .changes:
            if sshHost != nil {
                remoteUnavailable(pane: localized("Changes"))
            } else if let repoRoot = projectPath {
                // Fresh identity per repo, so the panel model (selection, draft message,
                // PR status) resets cleanly when the selected project moves.
                // The visibility closure reads the store live (weakly — the model may
                // outlive a closing window), so a collapsed inspector parks the pane's
                // auto-refresh even while this view stays in the hierarchy.
                GitChangesView(
                    repoRoot: repoRoot,
                    changeCount: $store.gitChangeCount,
                    isPaneVisible: { [weak store] in store?.inspectorVisible ?? true }
                )
                .id(repoRoot)
            } else {
                noProject
            }
        case .issues:
            if sshHost != nil {
                remoteUnavailable(pane: localized("Issues"))
            } else if let repoRoot = projectPath {
                // Fresh identity per repo, like Changes: the panel model (connection
                // phase, binding, list, pushed-in detail) resets when the project moves.
                IssuesView(repoRoot: repoRoot)
                    .id(repoRoot)
            } else {
                noProject
            }
        case .info:
            SessionInfoView()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let root {
            FileTreeList(
                nodes: root.children ?? [],
                revision: treeRevision,
                selection: $browserState.selection,
                font: settings.interfaceFont,
                onDrop: { sources, destination in receive(sources, into: destination) },
                rootURL: root.url,
                actions: treeActions,
                captureOutline: { browserState.outlineView = $0 }
            )
            .onKeyPress(.space) {
                guard browserState.selection != nil else { return .ignored }
                onQuickLook()
                return .handled
            }
            // Collapse All rebuilds the list by changing its identity (see `treeGeneration`).
            .id(treeGeneration)
        } else if projectPath != nil {
            // The off-main root read is still in flight; hold the pane blank rather
            // than flashing the no-project copy for the moment a huge root takes.
            Color.clear
        } else {
            noProject
        }
    }

    /// What a pane that only reads local disk shows for an SSH session. Honest about
    /// the gap rather than showing the Mac's own files under a remote session.
    private func remoteUnavailable(pane: String) -> some View {
        PaneEmptyState(
            localized("Remote session"),
            icon: .serverStack,
            message: localized("\(pane) isn’t available for SSH sessions yet.")
        )
    }

    /// The empty state the Files and Search panes share when no session is selected.
    private var noProject: some View {
        PaneEmptyState(
            localized("No Project"),
            icon: .folder,
            message: localized("Select a session to browse its files.")
        )
    }

    /// The VS Code-style explorer header: the root folder's name, and trailing action
    /// buttons — New File / New Folder (created at the project root), Refresh (re-read
    /// from disk), and Collapse All.
    private func header(root: FileNode) -> some View {
        HStack(spacing: 2) {
            Text(root.name)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            TreeHeaderButton(codicon: .newFile, help: localized("New File")) {
                createFile(in: root.url)
            }
            TreeHeaderButton(codicon: .newFolder, help: localized("New Folder")) {
                createFolder(in: root.url)
            }
            TreeHeaderButton(codicon: .refresh, help: localized("Refresh")) {
                refresh()
            }
            TreeHeaderButton(codicon: .collapseAll, help: localized("Collapse All")) {
                treeGeneration += 1
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }

    /// Seeds the switcher's Changes badge with the repo's dirty-file count, so it is
    /// right before the user ever opens the Changes pane (which then keeps it fresh).
    private func seedChangeCount() {
        guard let repoRoot = projectPath else {
            if store.gitChangeCount != 0 { store.gitChangeCount = 0 }
            return
        }
        Task {
            let count = await GitService.changes(in: repoRoot).count
            // The project may have moved while git ran; a stale repo's count must
            // not land on the new project's badge.
            guard projectPath == repoRoot else { return }
            // Only publish a real change: this reruns on every settled watcher batch,
            // and an unconditional write would invalidate every store observer (the
            // whole window re-evaluates, and the file list's coordinator re-walks its
            // rows) even when the badge didn't move — on a non-repo root that means
            // re-publishing `0` several times a second, forever.
            if store.gitChangeCount != count { store.gitChangeCount = count }
        }
    }

    /// Rebuilds the tree from the current project path. Called on appear, whenever
    /// the selected session moves to a different project, and after a drop. Watcher
    /// batches accumulated so far are superseded by the full rebuild, so drop them.
    ///
    /// The disk reads run off the main thread and the assembled root lands back on
    /// main pre-realized, so the swap's first render reads nothing. Realizing a huge
    /// root (a home directory) synchronously was ~100 ms of main-thread I/O, re-paid
    /// on every full rescan — which a high-churn root produces constantly — and it
    /// landed as the inspector's tab-switch stutter (#207). The outgoing tree keeps
    /// showing until the new root is ready; on an ordinary project the gap is a few
    /// milliseconds.
    private func refresh() {
        _ = watcher.drainTreeBatch()
        pendingReloads.removeAll()
        refreshGeneration &+= 1
        guard let projectPath else {
            root = nil
            return
        }
        let generation = refreshGeneration
        let rootURL = URL(fileURLWithPath: projectPath)
        // What the outgoing tree had realized — re-listed off main so the swap
        // keeps the outline's expanded subtree without a main-thread read.
        let realized = root?.url == rootURL ? (root?.realizedDirectoryURLs() ?? []) : []
        Task {
            let listings = await Task.detached(priority: .userInitiated) {
                FileNode.listingsForRefresh(of: rootURL, realized: realized)
            }.value
            // The project moved, or a newer refresh superseded this one, while we read.
            guard generation == refreshGeneration else { return }
            root = FileNode.preloaded(url: rootURL, isDirectory: true, listings: listings)
        }
    }

    /// Reloads just the realized directories a settled watcher batch touched — the
    /// Zed/VS Code shape, instead of rebuilding the whole tree per change. Events in
    /// directories nobody ever expanded are dropped outright (nothing on screen can
    /// be stale), which is what makes a high-churn root — a home directory, an
    /// `npm install` — cost nothing beyond this walk. The disk reads run off the
    /// main thread; the merge lands back on main, keeps surviving nodes (and so the
    /// outline's expansion state), and nudges `treeRevision` so the list re-diffs.
    private func applyTreeChanges() {
        let batch = watcher.drainTreeBatch()
        // FSEvents overflowed (or the root moved): the paths no longer enumerate
        // what changed, so incremental updating would go silently stale.
        if batch.needsFullRescan {
            refresh()
            return
        }
        guard let root else { return }
        var found = false
        for path in batch.paths {
            guard let node = root.loadedNode(for: path),
                  node.isDirectory, node.isLoaded else { continue }
            pendingReloads[node.url] = node
            found = true
        }
        guard found, !reloadInFlight else { return }
        runPendingReloads()
    }

    /// Drains `pendingReloads` serially: one disk pass in flight at a time, so
    /// merges can never land out of order, and batches arriving mid-read simply
    /// extend the queue and become the next lap.
    private func runPendingReloads() {
        reloadInFlight = true
        Task {
            while !pendingReloads.isEmpty {
                guard let rootNow = root else { break }
                let laps = pendingReloads
                pendingReloads = [:]
                let urls = Array(laps.keys)
                let listings = await Task.detached(priority: .utility) {
                    urls.map { FileNode.listContents(of: $0) }
                }.value
                // The project moved while we read: these nodes are orphans now.
                // `refresh` already cleared the queue; the fresh root re-reads
                // its directories as the outline realizes them.
                guard root === rootNow else { break }
                var changedAny = false
                for (url, listing) in zip(urls, listings) where laps[url]?.applyReloaded(listing) == true {
                    changedAny = true
                }
                // Only a changed row set is worth an outline update pass — churn
                // inside files (the common case on a busy root) adopts every node
                // and would re-walk the whole realized tree for nothing.
                if changedAny { treeRevision &+= 1 }
            }
            reloadInFlight = false
        }
    }

    /// Places each dropped file into `destination` (a folder inside the tree, or the
    /// project root). A file that already lives in the project is *moved* — the VS
    /// Code tree gesture; a file dragged in from the Finder is *copied*. A clash with
    /// an existing name gets a numbered suffix rather than clobbering it. No-op drops
    /// (a file onto its own folder) and incoherent ones (a folder onto itself or its
    /// own descendant) are skipped. Refreshes the tree and reports whether anything
    /// changed.
    private func receive(_ sources: [URL], into destination: URL) -> Bool {
        guard let projectPath else { return false }
        let rootPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let destinationDir = destination.standardizedFileURL
        let manager = FileManager.default
        var changedAny = false
        for source in sources {
            let src = source.standardizedFileURL
            // Already in this folder, or a folder dropped onto itself / a descendant.
            if src.deletingLastPathComponent() == destinationDir { continue }
            if destinationDir.path == src.path || destinationDir.path.hasPrefix(src.path + "/") { continue }

            let isInProject = src.path == rootPath || src.path.hasPrefix(rootPath + "/")
            let target = uniqueDestination(for: src.lastPathComponent, in: destinationDir, manager: manager)
            do {
                if isInProject {
                    try manager.moveItem(at: src, to: target)
                } else {
                    try manager.copyItem(at: src, to: target)
                }
                changedAny = true
            } catch {
                Log.files.error("failed to place \(src.path, privacy: .public) into \(destinationDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if changedAny { refresh() }
        return changedAny
    }

    /// A non-colliding URL for `name` in `directory`: the plain name if free, else
    /// `name 2.ext`, `name 3.ext`, … so a drop never clobbers an existing file.
    private func uniqueDestination(for name: String, in directory: URL, manager: FileManager) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard manager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let suffixed = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = directory.appendingPathComponent(suffixed)
            if !manager.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    /// The create/delete actions the row context menu invokes, plus single-click open
    /// (`onActivate`). Bundled so a row carries one value instead of four closures.
    private var treeActions: FileTreeActions {
        FileTreeActions(
            newFile: { createFile(in: $0) },
            newFolder: { createFolder(in: $0) },
            rename: { rename($0) },
            delete: { delete($0) },
            addToChat: { _ = store.addPathToSelectedSessionPrompt($0) },
            canAddToChat: { store.selectedSessionRunsAgent }
        )
    }

    /// Prompts for a name, creates an empty file in `directory`, then selects and
    /// opens it — VS Code's "New File". A name clash gets a numbered suffix.
    private func createFile(in directory: URL) {
        guard let name = promptForName(title: localized("New File"), defaultName: "untitled.txt") else { return }
        let target = uniqueDestination(for: name, in: directory, manager: .default)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            Log.files.error("failed to create file at \(target.path, privacy: .public)")
            return
        }
        refresh()
        browserState.selection = target
        onActivate(target)
    }

    /// Prompts for a name and creates a folder in `directory`, then selects it.
    private func createFolder(in directory: URL) {
        guard let name = promptForName(title: localized("New Folder"), defaultName: "untitled folder") else { return }
        let target = uniqueDestination(for: name, in: directory, manager: .default)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            refresh()
            browserState.selection = target
        } catch {
            Log.files.error("failed to create folder at \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Prompts for a new name (pre-filled with the current one) and renames `url` in
    /// place. If the renamed file was selected — and so open in the editor — the
    /// selection moves to the new URL and it is re-activated, so the editor follows
    /// the rename instead of holding (and auto-saving back) the old path.
    private func rename(_ url: URL) {
        guard let name = promptForName(title: localized("Rename “\(url.lastPathComponent)”"), defaultName: url.lastPathComponent, buttonTitle: localized("Rename")),
              name != url.lastPathComponent
        else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            let alert = NSAlert()
            alert.messageText = localized("“\(name)” already exists.")
            alert.informativeText = localized("Choose a different name.")
            alert.runModal()
            return
        }
        do {
            let wasSelected = browserState.selection == url
            try FileManager.default.moveItem(at: url, to: target)
            refresh()
            if wasSelected {
                browserState.selection = target
                if !isDirectory(target) { onActivate(target) }
            }
        } catch {
            Log.files.error("failed to rename \(url.path, privacy: .public) to \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Moves `url` to the Trash after a confirm — recoverable, not an unlink — clears
    /// it from the selection, and refreshes.
    private func delete(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = localized("Move “\(url.lastPathComponent)” to the Trash?")
        alert.informativeText = localized("You can restore it from the Trash.")
        alert.addButton(withTitle: localized("Move to Trash"))
        alert.addButton(withTitle: localized("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if browserState.selection == url { browserState.selection = nil }
            refresh()
        } catch {
            Log.files.error("failed to trash \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A modal name prompt — one text field in an `NSAlert`, pre-filled with
    /// `defaultName`. Returns the trimmed entry, or `nil` if cancelled or emptied.
    private func promptForName(title: String, defaultName: String, buttonTitle: String = localized("Create")) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: localized("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
