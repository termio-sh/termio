import AppKit
import Combine
import SwiftUI
import WebKit

/// The Files pane's tree: @pierre/trees (`PierreTrees/README.md`) drawn in a web
/// view, fed from `DeviceFileTreeModel`.
///
/// The split is one rule. The model owns the data — it lists folders on the
/// device and grafts the answers — and the page owns the interaction: selection,
/// keyboard, expansion, a drag inside the tree. What crosses between them is a
/// path, relative to the checkout root (`file-tree.js` holds the page's half).
///
/// The write verbs (the row menu, a drag, a drop) move bytes through
/// `FileManager`, so they exist only with a `FileTreeWrites`, which only a
/// checkout on this Mac has. A checkout on another device gets a tree you can
/// browse and open from, and nothing that would refuse.
struct FileTreeWebView: NSViewRepresentable {
    let model: DeviceFileTreeModel
    let writes: FileTreeWrites?
    let dimIgnored: Bool
    /// CSS custom properties for the tree's host element: font, ink, highlight.
    let style: [String: String]
    let browserState: FileBrowserState
    /// A row became the selection, by click or by keyboard, or nil when the
    /// selection went away with its row.
    let onSelect: (DeviceFileNode?) -> Void
    /// A file row was clicked or walked onto.
    let onOpen: (DeviceFileNode) -> Void
    let onQuickLook: () -> Void

    func makeCoordinator() -> FileTreeBridge { FileTreeBridge(model: model) }

    func makeNSView(context: Context) -> FileTreeWKWebView {
        context.coordinator.update(from: self)
        browserState.tree = context.coordinator
        return context.coordinator.makeWebView()
    }

    func updateNSView(_ view: FileTreeWKWebView, context: Context) {
        context.coordinator.update(from: self)
        browserState.tree = context.coordinator
    }

    static func dismantleNSView(_ view: FileTreeWKWebView, coordinator: FileTreeBridge) {
        coordinator.tearDown()
    }

    /// An `rgba()` for `color` as it draws in `appearance`. Dynamic system colors
    /// resolve differently per appearance, so they are read under the one the
    /// tree is drawn in.
    static func css(_ color: NSColor, in appearance: NSAppearance?) -> String {
        var resolved = color
        let read = { resolved = color.usingColorSpace(.sRGB) ?? color }
        if let appearance { appearance.performAsCurrentDrawingAppearance(read) } else { read() }
        let red = Int((resolved.redComponent * 255).rounded())
        let green = Int((resolved.greenComponent * 255).rounded())
        let blue = Int((resolved.blueComponent * 255).rounded())
        return "rgba(\(red), \(green), \(blue), \(resolved.alphaComponent))"
    }
}

/// Talks to the page: sends the model's rows, answers its messages.
@MainActor
final class FileTreeBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let model: DeviceFileTreeModel
    private weak var webView: FileTreeWKWebView?
    private var writes: FileTreeWrites?
    private var dimIgnored = false
    private var style: [String: String] = [:]
    private var onSelect: (DeviceFileNode?) -> Void = { _ in }
    private var onOpen: (DeviceFileNode) -> Void = { _ in }
    private var onQuickLook: () -> Void = {}

    /// The page has loaded both scripts. Nothing can be sent before.
    private var isReady = false
    private var sentRevision: Int?
    private var sentDimIgnored = false
    private var sentStyle: [String: String]?
    private var revisionWatch: AnyCancellable?
    /// The folder under a drag from outside the page, as the page last reported it.
    private var dropDirectory: String

    private static let messageName = "fileTree"

    init(model: DeviceFileTreeModel) {
        self.model = model
        self.dropDirectory = model.root
        super.init()
        // A graft publishes `revision` before the run loop turn ends; the rows are
        // read on the next turn, when the whole graft has landed.
        revisionWatch = model.$revision.sink { [weak self] _ in
            Task { @MainActor in self?.push() }
        }
    }

    func update(from view: FileTreeWebView) {
        writes = view.writes
        dimIgnored = view.dimIgnored
        style = view.style
        onSelect = view.onSelect
        onOpen = view.onOpen
        onQuickLook = view.onQuickLook
        sendStyle()
        push()
    }

    func makeWebView() -> FileTreeWKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        for name in ["pierre-trees.min", "file-tree"] {
            guard let url = Bundle.termioResources.url(forResource: name, withExtension: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8)
            else {
                Log.files.error("file tree: \(name, privacy: .public).js is missing from the bundle")
                continue
            }
            controller.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.add(self, name: Self.messageName)
        let view = FileTreeWKWebView(frame: .zero, configuration: configuration)
        view.bridge = self
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.page, baseURL: nil)
        webView = view
        return view
    }

    func tearDown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        revisionWatch = nil
    }

    private static let page = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
          #tree { height: 100%; }
        </style>
        </head><body><div id="tree"></div></body></html>
        """

    // MARK: Swift → page

    func collapseAll() { call("termioTree.collapseAll()") }

    /// Expands the tree down to `path` and selects its row, leaving the file as the
    /// caller opened it. Each folder on the way is listed first, since the page can
    /// only expand a row it has; each step gives up after `stepTimeout`.
    func reveal(_ path: String) async -> Bool {
        guard await waitUntil({ self.isReady }),
              let relative = relativePath(path), !relative.isEmpty
        else { return false }
        let components = relative.split(separator: "/").map(String.init)
        for depth in 1..<max(components.count, 1) {
            let folder = base + components.prefix(depth).joined(separator: "/")
            guard await waitUntil({ self.model.node(at: folder) != nil }) else { return false }
            model.expand(folder)
            guard await waitUntil({ self.model.node(at: folder)?.children != nil }) else { return false }
            push()
            call("termioTree.expand(path)", ["path": components.prefix(depth).joined(separator: "/")])
        }
        guard await waitUntil({ self.model.node(at: path) != nil }) else { return false }
        push()
        guard let webView else { return false }
        do {
            let found = try await webView.callAsyncJavaScript(
                "return termioTree.reveal(path)", arguments: ["path": relative], contentWorld: .page)
            return found as? Bool ?? false
        } catch {
            Log.files.error("file tree reveal: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static let stepTimeout: Duration = .seconds(3)

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + Self.stepTimeout
        while !condition() {
            guard ContinuousClock.now < deadline,
                  (try? await Task.sleep(for: .milliseconds(30))) != nil
            else { return false }
        }
        return true
    }

    /// Sends every row the model holds, when they changed since the last send.
    /// The page diffs them against what it shows, so a listing landing keeps
    /// expansion, selection and scroll.
    private func push() {
        guard isReady, sentRevision != model.revision || sentDimIgnored != dimIgnored else { return }
        sentRevision = model.revision
        sentDimIgnored = dimIgnored
        call("termioTree.apply({ rows })", ["rows": rows()])
    }

    private func sendStyle() {
        guard isReady, sentStyle != style else { return }
        sentStyle = style
        call("termioTree.setStyle(variables)", ["variables": style])
    }

    private func call(_ body: String, _ arguments: [String: Any] = [:]) {
        guard isReady, let webView else { return }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                Log.files.error("file tree script: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// One dictionary per row, parents before their children. The keys are the
    /// page's: `p` path, `d` folder, `o` listed, `i` ignored, `l` loading,
    /// `s` symlink tooltip, `x` why the row can't open, `n`/`c` the note and
    /// item count of a listing that stopped short.
    private func rows() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        func visit(_ nodes: [DeviceFileNode], parent: Int?) {
            let listed = nodes.filter { $0.notice == nil }.count
            for node in nodes {
                // The note is not a file: it rides on the folder it describes.
                if let notice = node.notice {
                    if let parent {
                        rows[parent]["n"] = notice
                        rows[parent]["c"] = listed
                    }
                    continue
                }
                guard let path = relativePath(node.path) else { continue }
                var row: [String: Any] = ["p": path, "d": node.isDirectory]
                if node.isDirectory, node.children != nil { row["o"] = true }
                if dimIgnored, node.isIgnored { row["i"] = true }
                if node.isLoading { row["l"] = true }
                if let target = node.symbolicLinkTarget { row["s"] = localized("Alias → \(target)") }
                if !(node.isDirectory || node.canPreview || node.localURL != nil) {
                    row["x"] = localized("Special files can’t be previewed")
                }
                rows.append(row)
                if let children = node.children { visit(children, parent: rows.count - 1) }
            }
        }
        visit(model.rootNodes, parent: nil)
        return rows
    }

    private var base: String { model.root.hasSuffix("/") ? model.root : model.root + "/" }

    private func relativePath(_ path: String) -> String? {
        path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    private func absolutePath(_ relative: String) -> String {
        relative.isEmpty ? model.root : base + relative
    }

    // MARK: Page → Swift

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        call("termioTree.configure(options)", ["options": ["root": model.root, "writable": writes != nil]])
        sendStyle()
        push()
    }

    /// The page is a string this process wrote; nothing in it may take the view
    /// somewhere else.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let node = (body["path"] as? String).flatMap { model.node(at: absolutePath($0)) }
        switch type {
        case "select":
            if let node { onSelect(node) } else if body["path"] is NSNull { onSelect(nil) }
        case "open":
            if let node, !node.isDirectory { onOpen(node) }
        case "expand":
            if let node { model.expand(node.path) }
        case "menu":
            let point = CGPoint(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0)
            showMenu(at: point, for: node)
        case "quickLook":
            onQuickLook()
        case "move":
            move(paths: body["paths"] as? [String] ?? [], into: body["directory"] as? String ?? "")
        case "dropTarget":
            dropDirectory = absolutePath(body["directory"] as? String ?? "")
        case "dragStart":
            draggedPaths = (body["paths"] as? [String] ?? []).map(absolutePath)
        default:
            Log.files.error("file tree: unknown message \(type, privacy: .public)")
        }
    }

    /// A drag inside the tree landed. The page has already moved the rows, so a
    /// move the disk refused is followed by a re-list that puts them back.
    private func move(paths: [String], into directory: String) {
        guard let writes, !paths.isEmpty else { return }
        let sources = paths.map { URL(fileURLWithPath: absolutePath($0)) }
        let destination = URL(fileURLWithPath: absolutePath(directory))
        if !writes.onDrop(sources, destination) { model.refresh() }
    }

    // MARK: Drags out of the page

    /// The rows the page said a drag started with, until their URLs are on the
    /// pasteboard.
    private var draggedPaths: [String] = []

    /// Adds the dragged rows' file URLs to the drag, one pasteboard item each.
    /// WebKit writes only what the page set, and a page may not write a file
    /// URL; the terminal and the Finder take nothing else. WebKit's own item is
    /// kept as the first, so a drop inside the page still reads it.
    func stampDrag(on pasteboard: NSPasteboard) {
        guard !draggedPaths.isEmpty else { return }
        let urls = draggedPaths.map { URL(fileURLWithPath: $0).absoluteString }
        draggedPaths = []
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url, forType: .fileURL)
            item.setString(url, forType: .URL)
            return item
        }
        if let webKitItem = pasteboard.pasteboardItems?.first {
            for type in webKitItem.types where type != .fileURL && type != .URL {
                if let data = webKitItem.data(forType: type) { items[0].setData(data, forType: type) }
            }
        }
        pasteboard.clearContents()
        if !pasteboard.writeObjects(items) {
            Log.files.error("file tree: the drag's file URLs could not be written")
        }
    }

    // MARK: Drops from outside the page

    var acceptsDrops: Bool { writes != nil }

    func dropExternal(_ urls: [URL]) -> Bool {
        defer { endDrop() }
        guard let writes, !urls.isEmpty else { return false }
        return writes.onDrop(urls, URL(fileURLWithPath: dropDirectory))
    }

    func endDrop() {
        dropDirectory = model.root
        call("termioTree.endDrop()")
    }

    // MARK: Row menu

    /// Every item on it moves or reveals a file through this process, so a row
    /// on another device gets no menu rather than one where each item refuses.
    /// The empty area below the rows creates at the root.
    private func showMenu(at point: CGPoint, for node: DeviceFileNode?) {
        guard let writes, let webView else { return }
        let location = webView.isFlipped ? point : CGPoint(x: point.x, y: webView.bounds.height - point.y)
        let menu = NSMenu()
        guard let node, let url = node.localURL else {
            menu.addItem(item(localized("New File")) { writes.actions.newFile(writes.rootURL) })
            menu.addItem(item(localized("New Folder")) { writes.actions.newFolder(writes.rootURL) })
            menu.popUp(positioning: nil, at: location, in: webView)
            return
        }
        // Cursor's explorer verb, leading the menu: the row lands in the agent's
        // prompt as a shell-quoted path. A plain shell has no chat to add to.
        if writes.actions.canAddToChat() {
            menu.addItem(item(localized("Add to Chat")) { writes.actions.addToChat(url) })
            menu.addItem(.separator())
        }
        if node.isDirectory {
            menu.addItem(item(localized("New File")) { writes.actions.newFile(url) })
            menu.addItem(item(localized("New Folder")) { writes.actions.newFolder(url) })
            menu.addItem(.separator())
        }
        // The Finder's own verb for an alias, directly above Reveal in Finder so the
        // pair reads as "the original" versus "this link".
        if let original = node.resolvedSymbolicLinkTarget {
            menu.addItem(item(localized("Show Original")) {
                NSWorkspace.shared.activateFileViewerSelecting([original])
            })
        }
        menu.addItem(item(localized("Reveal in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        menu.addItem(.separator())
        menu.addItem(item(localized("Copy Path")) { Self.copy(url.path) })
        menu.addItem(item(localized("Copy Relative Path")) {
            Self.copy(Self.relative(url, to: writes.rootURL))
        })
        menu.addItem(.separator())
        menu.addItem(item(localized("Rename…")) { writes.actions.rename(url) })
        menu.addItem(item(localized("Delete")) { writes.actions.delete(url) })
        menu.popUp(positioning: nil, at: location, in: webView)
    }

    private func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        item.target = action
        // The item holds its action; `target` alone is weak.
        item.representedObject = action
        return item
    }

    /// The path relative to the project root — the form agents and build tools
    /// take; the absolute path for anything outside the root.
    private static func relative(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    private static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func invoke() { run() }
}

/// The tree's web view, with one addition: files dragged in from outside the page.
///
/// The page can't read a dropped file's path, so the drop is taken here, from the
/// pasteboard, into the folder the page reported under the pointer. A drag that
/// started inside the page — a row moved between folders — is WebKit's own and
/// goes through untouched.
final class FileTreeWKWebView: WKWebView {
    weak var bridge: FileTreeBridge?

    private func isExternalFileDrag(_ info: NSDraggingInfo) -> Bool {
        if let source = info.draggingSource as? NSView, source === self || source.isDescendant(of: self) {
            return false
        }
        return info.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        guard isExternalFileDrag(sender) else { return operation }
        return bridge?.acceptsDrops == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        guard isExternalFileDrag(sender) else { return operation }
        return bridge?.acceptsDrops == true ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        bridge?.endDrop()
    }

    /// The library starts every row drag as move-only, and the terminal takes a
    /// copy, so the drop was refused. A move stays allowed inside the app, where
    /// the tree moves rows; outside it the Finder gets a copy, never the original.
    /// WebKit's own answer is private, so this replaces it by selector.
    @objc(draggingSession:sourceOperationMaskForDraggingContext:)
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        bridge?.stampDrag(on: session.draggingPasteboard)
        return context == .outsideApplication ? .copy : [.copy, .move, .generic]
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isExternalFileDrag(sender) else { return super.performDragOperation(sender) }
        // WebKit saw this drag enter; tell it the drag left, so the page never
        // gets a drop of files it could only navigate to.
        super.draggingExited(sender)
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return bridge?.dropExternal(urls) ?? false
    }
}
