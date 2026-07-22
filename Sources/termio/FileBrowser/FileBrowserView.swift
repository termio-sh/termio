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
    /// Watches the project root on disk and bumps its `changeToken` when anything under
    /// it changes, so the tree stays live with an agent's edits (see `onChange` below).
    @StateObject private var watcher = FileTreeWatcher()

    /// The directory the tree is rooted at: the selected session's worktree if it
    /// has one, otherwise its project folder. `nil` when nothing is selected.
    /// A loose terminal roots at its *live* cwd instead (falling back to the cwd
    /// persisted from the last run, then `$HOME`) — the session owns its path, so
    /// the tree, search, and changes panes all follow a `cd`. Real projects keep
    /// their stable root; the anchor is the point of a project.
    private var projectPath: String? {
        guard let id = store.selectedSessionID, let project = store.project(for: id) else { return nil }
        if project.kind == .terminals {
            return store.workingDirectories[id]
                ?? store.session(id)?.lastWorkingDirectory
                ?? project.path
        }
        return store.session(id)?.worktreePath ?? project.path
    }

    var body: some View {
        VStack(spacing: 0) {
            switch store.inspectorTab {
            case .files:
                if let root { header(root: root) }
                content
            case .search:
                if let root {
                    FileSearchView(
                        rootURL: root.url,
                        font: settings.interfaceFont,
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
                if let repoRoot = projectPath {
                    // Fresh identity per repo, so the panel model (selection, draft message,
                    // PR status) resets cleanly when the selected project moves.
                    GitChangesView(repoRoot: repoRoot, changeCount: $store.gitChangeCount)
                        .id(repoRoot)
                } else {
                    content
                }
            case .info:
                SessionInfoView()
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
        // The project root changed on disk (an agent wrote, renamed, or removed a
        // file): rebuild the tree from disk. Keep the Changes badge fresh too, unless
        // the Changes pane is open — it owns the count live while visible.
        .onChange(of: watcher.changeToken) {
            refresh()
            if store.inspectorTab != .changes { seedChangeCount() }
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

    @ViewBuilder
    private var content: some View {
        if let root {
            FileTreeList(
                nodes: root.children ?? [],
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
        } else {
            noProject
        }
    }

    /// The empty state the Files and Search panes share when no session is selected.
    private var noProject: some View {
        ContentUnavailableView(
            "No Project",
            systemImage: "folder",
            description: Text("Select a session to browse its files.")
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
            TreeHeaderButton(codicon: .newFile, help: "New File") {
                createFile(in: root.url)
            }
            TreeHeaderButton(codicon: .newFolder, help: "New Folder") {
                createFolder(in: root.url)
            }
            TreeHeaderButton(codicon: .refresh, help: "Refresh") {
                refresh()
            }
            TreeHeaderButton(codicon: .collapseAll, help: "Collapse All") {
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
            store.gitChangeCount = 0
            return
        }
        Task { store.gitChangeCount = await GitService.changes(in: repoRoot).count }
    }

    /// Rebuilds the tree from the current project path. Called on appear, whenever
    /// the selected session moves to a different project, and after a drop.
    private func refresh() {
        guard let projectPath else {
            root = nil
            return
        }
        root = FileNode(url: URL(fileURLWithPath: projectPath), isDirectory: true)
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
            delete: { delete($0) }
        )
    }

    /// Prompts for a name, creates an empty file in `directory`, then selects and
    /// opens it — VS Code's "New File". A name clash gets a numbered suffix.
    private func createFile(in directory: URL) {
        guard let name = promptForName(title: "New File", defaultName: "untitled.txt") else { return }
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
        guard let name = promptForName(title: "New Folder", defaultName: "untitled folder") else { return }
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
        guard let name = promptForName(title: "Rename “\(url.lastPathComponent)”", defaultName: url.lastPathComponent, buttonTitle: "Rename"),
              name != url.lastPathComponent
        else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            let alert = NSAlert()
            alert.messageText = "“\(name)” already exists."
            alert.informativeText = "Choose a different name."
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
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "You can restore it from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
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
    private func promptForName(title: String, defaultName: String, buttonTitle: String = "Create") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
