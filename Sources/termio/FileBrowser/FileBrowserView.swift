import AppKit
import Quartz
import SwiftUI

/// The trailing inspector's content: a disclosure tree of the selected session's
/// project (`FileTreeWebView`), rooted at the project (or worktree) directory. Selecting a
/// file and pressing space opens it in Quick Look (Finder's gesture); dragging
/// files from the Finder onto the panel copies them into the project root.
///
/// **The tree reads one way, on every machine.** Its rows come from
/// `DeviceFileTreeModel`, which asks the checkout's own device for
/// `fs.list` — this Mac over its unix socket exactly as a VPS is asked over
/// `ssh` — and keeps them live off that device's `fs:` subscription. Nothing
/// here branches on where a checkout is to *read* it.
///
/// What still divides is what may be *written*: New File, New Folder, Rename,
/// Delete, drag and drop all move bytes through `FileManager` on paths this
/// process can open, and the device file plane is read-only by design (mutation
/// is `20260819-unify-server-plane.md` Stage 11). So those controls are absent
/// on a checkout that lives somewhere else, rather than present and refusing.
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

    /// Where the selected session's files live, and on which machine — see
    /// `TermioStore.inspectorCheckout`. Nothing in this pane may ask the session
    /// how it was opened instead: that question named the road rather than the
    /// machine, and answered "local" for a session running on another box.
    private var checkout: Checkout? { store.inspectorCheckout }

    /// The checkout when it is on another machine. The tree reads it the same
    /// way it reads this Mac's; what this gates is the panes that still only
    /// know how to read local disk, and the write verbs.
    private var deviceCheckout: Checkout? {
        checkout.flatMap { $0.isOnAnotherDevice ? $0 : nil }
    }

    /// The directory the tree is rooted at *on this Mac*, and `nil` for a session on
    /// any other machine — so the git badge, the drop target, and every
    /// create/rename/delete all stand down together.
    private var projectPath: String? { checkout?.localRoot }

    /// The realized tree for the selected checkout, held by the store so moving
    /// between sessions is a handoff rather than a rebuild (see `FileTreeCache`).
    /// Read unobserved here — the list observes it — so this side can drive it
    /// without re-rendering the whole pane on every graft.
    private var tree: DeviceFileTreeModel? {
        guard let checkout, let root = checkout.root else { return nil }
        return store.fileTrees.model(for: checkout, root: root)
    }

    var body: some View {
        ZStack {
            // The Files pane is ALWAYS mounted; a tab switch merely covers it. A
            // fresh tree reloads its page and loses its disclosure state (#207).
            // Same always-mounted-under-an-opaque-overlay shape as `InspectorRoot`.
            filesPane
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
        // A drop on the header or an empty state targets the project root: a file
        // already in the tree is *moved* there, a file dragged in from the Finder is
        // *copied* in. The tree takes its own drops, into the folder under the
        // pointer (see `FileTreeWKWebView`).
        // A checkout on another device has no local root, so the drop is refused:
        // the alternative is landing a file on this Mac under a session that runs
        // somewhere else, which is the whole defect this pane's checkout fixes.
        .dropDestination(for: URL.self) { urls, _ in
            guard let projectPath else { return false }
            return receive(urls, into: URL(fileURLWithPath: projectPath))
        }
        .onAppear {
            start()
            seedChangeCount()
        }
        .onDisappear { stop() }
        .onChange(of: checkout) { previous, _ in
            stop(previous)
            // A path from the checkout that just left addresses nothing in the
            // one arriving — and Quick Look would still be holding the old file.
            browserState.selection = nil
            browserState.selectedLocalURL = nil
            start()
            seedChangeCount()
        }
        .onChange(of: store.inspectorVisible) { _, visible in
            if visible {
                start()
                // The rows may predate this pane being on screen; the watch was
                // retired while it was hidden.
                tree?.refresh()
                if store.inspectorTab != .changes { seedChangeCount() }
            } else {
                // A hidden pane is not worth a connection to somebody's VPS — nor
                // a recursive watch on any box, this one included — and the
                // download behind a click nobody can see is not worth finishing.
                stop()
                store.cancelRemoteFileOpen()
            }
        }
        // The app-focus reload, only when nothing is watching. A live subscription
        // kept running while the window was in the back, so coming back to the
        // front is not news — and re-listing every open directory on it was this
        // tree's largest recurring cost against a box where an agent is writing
        // files. But a daemon too old to grant `resources` never gets a
        // subscription at all, and dropping this unconditionally would leave those
        // trees with nothing but the refresh button.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard store.inspectorVisible else { return }
            if tree?.isLive != true { tree?.refresh() }
            if store.inspectorTab != .changes { seedChangeCount() }
        }
        .onChange(of: store.pendingFileReveal, initial: true) { _, path in
            guard let path else { return }
            Task { await reveal(path) }
        }
    }

    /// Arms the tree for the selected checkout: the device's channel stays warm
    /// and its `fs:` watch runs for as long as this pane is on screen.
    private func start() {
        guard store.inspectorVisible, let tree else { return }
        // Weak, and holding no view state: the model outlives this pane in the
        // cache, so anything strongly captured here would outlive a window.
        tree.onCheckoutChanged = { [weak store] in
            guard let store, store.inspectorTab != .changes else { return }
            Self.seedChangeCount(into: store)
        }
        tree.startWarming()
        tree.refresh()
    }

    private func stop(_ previous: Checkout? = nil) {
        let model = previous.flatMap { checkout -> DeviceFileTreeModel? in
            guard let root = checkout.root else { return nil }
            return store.fileTrees.existing(for: checkout, root: root)
        } ?? tree
        model?.onCheckoutChanged = nil
        model?.stopWarming()
    }

    /// A row became the selection, by click or by keyboard, or the selected row
    /// went away. Quick Look follows it, and an open panel moves with it.
    private func select(_ node: DeviceFileNode?) {
        browserState.selection = node?.path
        browserState.selectedLocalURL = node?.localURL
        followSelectionInQuickLook()
    }

    /// A file row was clicked or walked onto. A click on the row already selected
    /// re-opens its file: closing the detail leaves the row selected, as it does in
    /// VS Code and Zed, the highlight marking where you are rather than what is
    /// open. A click on the file that is still open does nothing.
    private func activate(_ node: DeviceFileNode) {
        followSelectionInQuickLook()
        if let url = node.localURL, store.openFileURL == url { return }
        open(node)
    }

    private func followSelectionInQuickLook() {
        InspectorPanelHost.shared.quickLookFollowsTreeSelection()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    /// Opens one row. A file on this Mac goes to the inspector's editor or
    /// preview; a file on another device is staged and shown read-only, which is
    /// the only honest thing to offer for bytes this app cannot save back
    /// through the same path. A row that is neither does nothing.
    private func open(_ node: DeviceFileNode) {
        if let url = node.localURL {
            onActivate(url)
            return
        }
        guard node.canPreview, let tree else { return }
        store.openRemoteFile(
            path: node.path, name: node.name, provider: tree.files, host: tree.host)
    }

    /// Expands the tree down to `path` and selects its row, leaving the file as the
    /// caller opened it. The tree may not exist yet — the pane can still be
    /// connecting — so this waits for it as long as one reveal step would.
    private func reveal(_ path: String) async {
        defer { if store.pendingFileReveal == path { store.pendingFileReveal = nil } }
        let deadline = ContinuousClock.now + .seconds(3)
        while browserState.tree == nil {
            guard ContinuousClock.now < deadline,
                  (try? await Task.sleep(for: .milliseconds(30))) != nil
            else { return }
        }
        guard let tree = browserState.tree else { return }
        if await tree.reveal(path) {
            // The page reports no selection for a reveal, so Quick Look is moved here.
            browserState.selection = path
            browserState.selectedLocalURL = self.tree?.node(at: path)?.localURL
            followSelectionInQuickLook()
        } else {
            Log.files.error("reveal stopped: no row for \(path, privacy: .public)")
        }
    }

    /// The Files pane itself: one tree for every machine, and the two honest
    /// empty states — a device whose root this app does not know, and no session
    /// selected at all.
    @ViewBuilder
    private var filesPane: some View {
        if let checkout, let root = checkout.root, let tree {
            VStack(spacing: 0) {
                header(tree)
                FileTreeContent(
                    model: tree,
                    host: tree.host,
                    writes: writes,
                    browserState: browserState,
                    onSelect: { select($0) },
                    onOpen: { activate($0) },
                    // Quick Look previews a file on this Mac. A row on another
                    // device has nothing local to hand the panel, so the key
                    // does nothing rather than opening an empty preview.
                    onQuickLook: {
                        guard writes != nil, browserState.selection != nil else { return }
                        onQuickLook()
                    }
                )
            }
            // Fresh identity per checkout, so view state never leaks between
            // machines or between roots on one machine.
            .id(checkout.deviceIdentity + "\u{1f}" + root)
        } else if let deviceCheckout {
            unavailable(pane: localized("Files"), on: deviceCheckout)
        } else {
            noProject
        }
    }

    /// The write verbs, and only for a checkout on this Mac. `nil` is what hides
    /// the row menu, the drag, the drop targets and the header's create buttons
    /// on a checkout that lives somewhere else.
    private var writes: FileTreeWrites? {
        guard let projectPath else { return nil }
        return FileTreeWrites(
            rootURL: URL(fileURLWithPath: projectPath),
            actions: treeActions,
            onDrop: { sources, destination in receive(sources, into: destination) })
    }

    @ViewBuilder
    private var activePane: some View {
        switch store.inspectorTab {
        case .files:
            EmptyView()
        case .search:
            if let deviceCheckout, let deviceRoot = deviceCheckout.root {
                // The device's own `fs.search`, rooted where its tree is rooted.
                FileSearchView(
                    scope: .device(
                        DeviceFileProvider(
                            route: deviceCheckout.device.route, root: deviceRoot),
                        host: deviceCheckout.device.name,
                        root: deviceRoot),
                    onDismiss: { store.inspectorTab = .files }
                )
                .id(deviceCheckout.deviceIdentity + "\u{1f}" + deviceRoot)
            } else if let deviceCheckout {
                unavailable(pane: localized("Search"), on: deviceCheckout)
            } else if let projectPath {
                // This Mac's own daemon, over the Unix socket — the same
                // `fs.search` a device answers with, and the same plane the tree's
                // listings already ride. Local stopped being a second engine here.
                FileSearchView(
                    scope: .thisMac(
                        DeviceFileProvider(route: .local, root: projectPath),
                        URL(fileURLWithPath: projectPath)),
                    onDismiss: { store.inspectorTab = .files }
                )
                // Fresh identity per project, so a stale query/result set
                // doesn't carry over when the root moves.
                .id(projectPath)
            } else {
                noProject
            }
        case .changes:
            if let deviceCheckout, let root = deviceCheckout.root {
                // The device runs git on its own checkout with its own config and
                // credentials, and publishes status as it moves; this pane
                // subscribes. Fresh identity per (machine, root) so no state
                // leaks between boxes.
                GitChangesView(
                    repoRoot: root,
                    device: deviceCheckout.device.route,
                    changeCount: $store.gitChangeCount,
                    isPaneVisible: { [weak store] in store?.inspectorVisible ?? true }
                )
                .id(deviceCheckout.deviceIdentity + "\u{1f}" + root)
            } else if let deviceCheckout {
                unavailable(pane: localized("Changes"), on: deviceCheckout)
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
            if let deviceCheckout {
                unavailable(pane: localized("Issues"), on: deviceCheckout)
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
        case .simulator:
            SimulatorPane()
        }
    }

    /// What a pane that only reads local disk shows for a checkout on another
    /// machine: the machine, named. Naming it is the whole point — the alternative
    /// this replaces was the Mac's own files, git status, and search results shown
    /// under a session running somewhere else, with nothing saying so. An empty
    /// pane is allowed here; a wrong one is not.
    private func unavailable(pane: String, on checkout: Checkout) -> some View {
        // `host:/path` is how the same pair is written everywhere else a developer
        // meets it (`scp`, `rsync`), so the root rides along when it is known.
        let device = checkout.device.name
        let title = checkout.root.map { "\(device):\($0)" } ?? device
        return PaneEmptyState(
            title,
            icon: .serverStack,
            message: localized("\(pane) isn’t available on this machine yet.")
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

    /// The VS Code-style explorer header: the root folder's name, and trailing
    /// action buttons — Refresh (re-read from the device) and Collapse All on
    /// every checkout, New File / New Folder only where this Mac can create.
    private func header(_ tree: DeviceFileTreeModel) -> some View {
        HStack(spacing: 2) {
            Text(tree.rootName)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let projectPath {
                let root = URL(fileURLWithPath: projectPath)
                TreeHeaderButton(codicon: .newFile, help: localized("New File")) {
                    createFile(in: root)
                }
                TreeHeaderButton(codicon: .newFolder, help: localized("New Folder")) {
                    createFolder(in: root)
                }
            }
            TreeHeaderButton(codicon: .refresh, help: localized("Refresh")) {
                tree.refresh()
            }
            TreeHeaderButton(codicon: .collapseAll, help: localized("Collapse All")) {
                browserState.tree?.collapseAll()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }

    private func seedChangeCount() { Self.seedChangeCount(into: store) }

    /// Seeds the switcher's Changes badge with the repo's dirty-file count, so it is
    /// right before the user ever opens the Changes pane (which then keeps it fresh).
    ///
    /// Static, and reading the checkout back off the store, because the device's
    /// `fs:` batches call it from a closure the tree holds — and the tree outlives
    /// this pane in the cache, so a closure holding the view would hold a window.
    private static func seedChangeCount(into store: TermioStore) {
        guard let repoRoot = store.inspectorCheckout?.localRoot else {
            if store.gitChangeCount != 0 { store.gitChangeCount = 0 }
            return
        }
        Task { @MainActor in
            let count = await GitService.changes(in: repoRoot).count
            // The project may have moved while git ran; a stale repo's count must
            // not land on the new project's badge.
            guard store.inspectorCheckout?.localRoot == repoRoot else { return }
            // Only publish a real change: this reruns on every settled `fs:` batch,
            // and an unconditional write would invalidate every store observer (the
            // whole window re-evaluates, and the file list's coordinator re-walks its
            // rows) even when the badge didn't move — on a non-repo root that means
            // re-publishing `0` several times a second, forever.
            if store.gitChangeCount != count { store.gitChangeCount = count }
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
        if changedAny { tree?.refresh() }
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
        tree?.refresh()
        browserState.selection = target.path
        browserState.selectedLocalURL = target
        store.pendingFileReveal = target.path
        onActivate(target)
    }

    /// Prompts for a name and creates a folder in `directory`, then selects it.
    private func createFolder(in directory: URL) {
        guard let name = promptForName(title: localized("New Folder"), defaultName: "untitled folder") else { return }
        let target = uniqueDestination(for: name, in: directory, manager: .default)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            tree?.refresh()
            browserState.selection = target.path
            browserState.selectedLocalURL = target
            store.pendingFileReveal = target.path
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
            let wasSelected = browserState.selection == url.path
            let wasDirectory = tree?.node(at: url.path)?.isDirectory ?? false
            try FileManager.default.moveItem(at: url, to: target)
            tree?.refresh()
            if wasSelected {
                browserState.selection = target.path
                browserState.selectedLocalURL = target
                store.pendingFileReveal = target.path
                if !wasDirectory { onActivate(target) }
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
            if browserState.selection == url.path {
                browserState.selection = nil
                browserState.selectedLocalURL = nil
                followSelectionInQuickLook()
            }
            tree?.refresh()
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

/// The write verbs a tree row may offer, and the root they resolve against.
///
/// Bundled and optional so one value carries the whole answer to "may this
/// checkout be written from here": present for a checkout on this Mac, absent
/// for one on any other device, where the file plane is read-only by design.
struct FileTreeWrites {
    let rootURL: URL
    let actions: FileTreeActions
    let onDrop: (_ sources: [URL], _ destination: URL) -> Bool
}

/// The tree's three states, observing the model that fills them.
///
/// Split out of `FileBrowserView` so the tree re-renders on a graft without
/// re-evaluating the whole pane — the header, the drop target and the other
/// inspector tabs have no stake in a folder that just landed.
private struct FileTreeContent: View {
    @ObservedObject var model: DeviceFileTreeModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    /// The machine, for the failure state — which is the one place a tree has
    /// to name where it was reading.
    let host: String
    let writes: FileTreeWrites?
    let browserState: FileBrowserState
    let onSelect: (DeviceFileNode?) -> Void
    let onOpen: (DeviceFileNode) -> Void
    let onQuickLook: () -> Void

    var body: some View {
        switch model.phase {
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            PaneEmptyState(
                localized("Can’t browse \(host)"),
                icon: .serverStack,
                message: message
            )
        case .ready:
            VStack(spacing: 0) {
                FileTreeWebView(
                    model: model,
                    writes: writes,
                    dimIgnored: settings.dimIgnoredFiles,
                    style: style,
                    browserState: browserState,
                    onSelect: onSelect,
                    onOpen: onOpen,
                    onQuickLook: onQuickLook
                )
                // A root listing that stopped short has no folder row to carry its
                // note, and the rows above it look complete.
                if let notice = model.rootNodes.lazy.compactMap(\.notice).first {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The tree in the window's own terms: the interface font, the theme's ink,
    /// and the same grey lift the sidebar rows wear — selection a clear step
    /// above hover, never a hue.
    private var style: [String: String] {
        let dark = colorScheme == .dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let foreground = settings.chromeTheme(for: colorScheme).map { NSColor($0.foreground) } ?? .labelColor
        func css(_ color: NSColor) -> String { FileTreeWebView.css(color, in: appearance) }
        func ink(_ alpha: CGFloat) -> String { css(ChromeTheme.overlayInk(onDark: dark, alpha: alpha)) }
        let family = settings.interfaceFontFamily
        return [
            "color-scheme": dark ? "dark" : "light",
            "--trees-font-family-override": family.isEmpty
                ? "-apple-system, sans-serif" : "\"\(family)\", -apple-system, sans-serif",
            "--trees-font-size-override": "\(settings.interfaceFontSize)px",
            "--trees-fg-override": css(foreground),
            "--trees-fg-muted-override": css(foreground.withAlphaComponent(0.6)),
            "--trees-bg-override": "transparent",
            "--trees-selected-bg-override": ink(0.10),
            "--trees-selected-fg-override": css(foreground),
            "--trees-theme-list-hover-bg": ink(0.045),
            "--trees-focus-ring-color-override": ink(0.22),
            "--trees-selected-focused-border-color-override": "transparent",
            "--trees-git-ignored-color-override": dark ? "rgb(140, 140, 140)" : "rgb(142, 142, 144)",
            "--trees-border-radius-override": "7px",
        ]
    }
}
