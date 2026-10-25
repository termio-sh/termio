import AppKit

/// One directory on another machine, as `NSBrowser` holds it.
///
/// A reference type because the browser keeps the items it is handed and asks
/// about them again later by identity, and because the machine's answer for a
/// directory arrives after the column that asked for it has already been drawn —
/// the node is where that answer lands.
private final class RemoteFolderNode {
    let path: String
    let name: String
    /// The column this node's children are drawn in. The root's children are
    /// column 0, so every child sits one deeper than its parent.
    let childColumn: Int
    /// `nil` until the machine has answered for this directory. Empty is a
    /// different thing and a real one — it answered, and there is nothing inside —
    /// which is why this is not simply an array that starts out empty.
    var children: [RemoteFolderNode]?
    var isLoading = false

    init(path: String, name: String, childColumn: Int) {
        self.path = path
        self.name = name
        self.childColumn = childColumn
    }
}

/// Picks a folder on another machine — the panel `NSOpenPanel` cannot be, because
/// the directory being chosen is not on a file system this Mac can mount, and no
/// amount of configuring the system panel makes it ask a daemon over SSH.
///
/// Columns rather than a path field, which is what stood here before: a field
/// completes what you type, so it helps only once you already know the name you
/// are reaching for. Seeing what is on the machine is the whole difference, and it
/// is the reason this is worth its own panel.
///
/// It costs what the completion cost. Every column is one `fs_list` round trip on
/// a control channel held open for the life of the panel (§C.12, capability
/// `files`) — nothing walks a tree, so a machine holding a huge checkout answers
/// as fast as an empty one, and a column nobody opens is never asked for.
///
/// Directories only. A project root is a directory, and drawing the files beside
/// it would fill every column with rows that cannot be chosen.
@MainActor
final class RemoteFolderPicker: NSObject {
    /// What the panel was dismissed with. `clone` is the third button: cloning a
    /// repository onto the machine names a folder that does not exist yet, so it
    /// cannot be browsed to and is a different panel rather than a mode of this one.
    enum Choice {
        case folder(String)
        case clone
        case cancelled
    }

    private let alias: String
    private let lister: TermiodDirectoryLister
    private let browser = NSBrowser()
    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private var window: NSWindow?
    private var completion: ((Choice) -> Void)?
    /// The picker holds itself while the sheet is up — see `present(over:)`.
    private var retained: RemoteFolderPicker?

    private let root = RemoteFolderNode(path: "/", name: "/", childColumn: 0)
    /// Every node made so far, by path. The listing reply carries a path rather
    /// than the node it belongs to — a node cannot cross to the lister's queue and
    /// back — so this is what turns the answer back into the row that asked.
    private var nodes: [String: RemoteFolderNode] = [:]

    /// Where the machine says this account lives. `/` until the handshake answers,
    /// so a typed path is usable before the connection is.
    private var home = "/"
    /// The components of the directory to reveal once its ancestors have loaded,
    /// consumed one column at a time. Opening on `/` and making the user walk down
    /// to their own home is a panel that starts in the wrong place.
    private var pendingSelection: [String] = []

    /// The last directory listed for the *field*, and what was in it. One entry,
    /// not a cache of many: a path field only ever completes inside the directory
    /// the cursor is in, and holding older ones would serve stale names.
    private var listedDirectory: String?
    private var listedNames: [String] = []
    /// Guards the re-entrant `controlTextDidChange` that accepting a completion
    /// fires, which would otherwise ask for completions of the text just inserted.
    private var isCompleting = false

    init(alias: String) {
        self.alias = alias
        lister = TermiodDirectoryLister(route: TermiodRoute(hostKey: alias))
        super.init()
        nodes[root.path] = root
    }

    /// Presents the picker as a sheet on `parent` and reports what the user chose.
    ///
    /// A sheet, not an alert: an alert leads with the app icon, stacks its buttons
    /// down the middle once there are three, and means "something happened".
    /// Choosing a folder is a document verb, and `NSOpenPanel` is a sheet — this is
    /// the panel it would have been if the folder were on this Mac.
    ///
    /// The listing channel is the panel's, so it closes with it — including on
    /// Cancel, which would otherwise leak an SSH connection per dismissal.
    func present(over parent: NSWindow?, completion: @escaping (Choice) -> Void) {
        self.completion = completion
        // Nothing else holds the picker once this returns: the window's target is
        // unowned and the caller is done. Released in `finish`.
        retained = self
        let window = buildWindow()
        self.window = window
        connect()
        guard let parent else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            return
        }
        parent.beginSheet(window)
    }

    private func buildWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        window.contentView = buildContent()
        window.initialFirstResponder = browser
        // The sheet can also end without either button: the window it hangs on
        // closes, or the app quits. Without this the picker holds itself and its
        // SSH channel forever, and the caller is never told anything happened.
        window.delegate = self
        // Below this the columns are too narrow to read a folder name in and the
        // buttons start to crowd; a picker that can be dragged into uselessness is
        // worse than one that stops.
        window.minSize = NSSize(width: 520, height: 400)
        return window
    }

    private func buildContent() -> NSView {
        let content = NSView()

        // One plain line, the way the system's own Open panel opens — not a bold
        // headline over secondary text, which is an *alert's* grammar and says
        // "something happened" about a panel that is only asking where to look.
        let message = NSTextField(labelWithString: localized(
            "Choose a project folder on \(alias)."))
        message.lineBreakMode = .byTruncatingTail

        browser.delegate = self
        browser.pathSeparator = "/"
        browser.allowsMultipleSelection = false
        browser.allowsEmptySelection = true
        browser.hasHorizontalScroller = true
        browser.isTitled = false
        browser.minColumnWidth = 170
        // Sized to the icon rather than left at the default, which spaced bare text
        // out far enough that a column read as a list of unrelated words.
        browser.rowHeight = 20
        // Copied per row, which is what puts the folder icon on every one of them.
        browser.cellPrototype = RemoteFolderCell(textCell: "")
        // The content band, a shade back from the panel's own chrome — the same
        // separation the system panel draws between its columns and its toolbar.
        browser.backgroundColor = .textBackgroundColor
        browser.target = self
        browser.action = #selector(browserClicked)
        browser.doubleAction = #selector(browserDoubleClicked)

        field.delegate = self
        field.placeholderString = "/srv/api"

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail

        let open = NSButton(
            title: localized("Open"), target: self, action: #selector(openClicked))
        open.keyEquivalent = "\r"
        let cancel = NSButton(
            title: localized("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        // Bottom-leading, where the Save panel keeps New Folder: an auxiliary verb
        // that leaves for another panel rather than answering this one's question.
        let clone = NSButton(
            title: localized("Clone a Repository…"), target: self, action: #selector(cloneClicked))
        for button in [open, cancel, clone] { button.bezelStyle = .rounded }

        // The columns are bounded top and bottom by a hairline, the way the system
        // panel bounds its own: with a recessed background between them, the panel
        // reads as header · content · footer instead of as one loose stack, and the
        // column separators land on a band that is plainly the content.
        let topDivider = NSBox()
        topDivider.boxType = .separator
        let bottomDivider = NSBox()
        bottomDivider.boxType = .separator

        let views =
            [message, field, topDivider, browser, bottomDivider, status, open, cancel, clone]
            as [NSView]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            message.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            // Above the columns, where the system panel keeps its location control.
            // It says where you are and is how you get somewhere the columns would
            // take a dozen clicks to reach; below them it read as a form field.
            field.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            topDivider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 14),
            topDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            // Edge to edge. The system's columns run into the panel's sides, and
            // that is most of what makes them read as a browser rather than as a
            // control sitting inside a form.
            browser.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            bottomDivider.topAnchor.constraint(equalTo: browser.bottomAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -16),

            open.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            open.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
            open.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),

            cancel.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -12),
            cancel.firstBaselineAnchor.constraint(equalTo: open.firstBaselineAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),

            clone.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            clone.firstBaselineAnchor.constraint(equalTo: open.firstBaselineAnchor),

            // In the footer's empty middle, which is free until something goes
            // wrong — a reserved line under the field would leave a permanent gap
            // for a message that is almost never there.
            status.leadingAnchor.constraint(equalTo: clone.trailingAnchor, constant: 12),
            status.trailingAnchor.constraint(
                lessThanOrEqualTo: cancel.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: open.centerYAnchor),
        ])
        // The browser is the only thing that should grow when the sheet is
        // resized; everything else keeps the height it asks for.
        browser.setContentHuggingPriority(.defaultLow, for: .vertical)
        for view in [message, field, status] {
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        }
        return content
    }

    @objc private func openClicked() {
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = RemotePathEntry.expandingTilde(typed, home: home)
        finish(path.isEmpty ? .cancelled : .folder(path))
    }

    @objc private func cancelClicked() { finish(.cancelled) }

    @objc private func cloneClicked() { finish(.clone) }

    private func finish(_ choice: Choice) {
        // Re-entrant by design: closing the window is one of the ways this is
        // reached, and closing it again from in here would be the second.
        guard completion != nil else { return }
        if let window {
            if let parent = window.sheetParent {
                parent.endSheet(window)
            } else {
                window.close()
            }
        }
        window = nil
        let completion = self.completion
        self.completion = nil
        retained = nil
        completion?(choice)
    }

    /// Opens the listing channel in the background. The panel is already up by
    /// then — a modal that blocked on an SSH handshake before showing anything
    /// would read as a hang on exactly the machine that is slowest to reach.
    private func connect() {
        lister.connect { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let home):
                    self.home = home
                    if self.field.stringValue.isEmpty { self.field.stringValue = home }
                    self.pendingSelection = home.split(separator: "/").map(String.init)
                    self.load(self.root.path)
                case .failure(let error):
                    // Named rather than left as an empty browser: an empty column
                    // and an unreachable machine look identical, and only one of
                    // them is worth waiting through.
                    self.status.stringValue = self.message(for: error)
                }
            }
        }
    }

    /// Asks the machine for one directory, once. A column already answered for is
    /// never re-asked; nothing here refreshes, because the panel is modal and a
    /// directory does not change under a user who is looking at it.
    private func load(_ path: String) {
        guard let node = nodes[path], node.children == nil, !node.isLoading else { return }
        node.isLoading = true
        lister.list(path) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, let node = self.nodes[path] else { return }
                node.isLoading = false
                switch result {
                case .success(let entries):
                    node.children = entries.map { entry in
                        let child = RemoteFolderNode(
                            path: Self.joining(path, entry.name),
                            name: entry.name,
                            childColumn: node.childColumn + 1)
                        self.nodes[child.path] = child
                        return child
                    }
                    if node.childColumn <= self.browser.lastColumn {
                        self.browser.reloadColumn(node.childColumn)
                    }
                    self.revealPendingSelection()
                case .failure(let error):
                    // Answered, and the answer is "you may not look in here" —
                    // recorded as an empty directory so the column stops asking.
                    node.children = []
                    self.status.stringValue = self.message(for: error)
                }
            }
        }
    }

    /// Walks down the machine's home directory as its columns arrive, selecting one
    /// component per pass. Selecting a row is what makes the browser ask for the
    /// next column, so this is a chain rather than a loop over a tree nobody has.
    private func revealPendingSelection() {
        guard !pendingSelection.isEmpty else { return }
        var node = root
        for component in pendingSelection {
            guard let children = node.children else {
                load(node.path)
                return
            }
            guard let row = children.firstIndex(where: { $0.name == component }) else {
                // The home the machine reported has a component this account cannot
                // list. Stop where the walk got to rather than starting over at `/`.
                pendingSelection = []
                return
            }
            browser.selectRow(row, inColumn: node.childColumn)
            node = children[row]
        }
        pendingSelection = []
        // The home directory itself is now selected, so its own contents are the
        // last column to fill.
        load(node.path)
    }

    private static func joining(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// The machine's own words where it has any: a refused listing carries the
    /// daemon's message verbatim, and everything else is a `LocalizedError` that
    /// already describes itself.
    private func message(for error: Error) -> String {
        if case TermiodDirectoryLister.Failure.refused(let message) = error { return message }
        return error.localizedDescription
    }

    private func selectedNode() -> RemoteFolderNode? {
        let column = browser.selectedColumn
        guard column >= 0 else { return nil }
        let row = browser.selectedRow(inColumn: column)
        guard row >= 0 else { return nil }
        return browser.item(atRow: row, inColumn: column) as? RemoteFolderNode
    }

    /// The browser writes into the field, and never the other way round: the field
    /// is what Open reads, so a typed path always wins over what the columns
    /// happen to be showing. Someone who knows the path types it; someone who does
    /// not clicks to it and watches the field fill in.
    @objc private func browserClicked() {
        guard let node = selectedNode() else { return }
        field.stringValue = node.path
        status.stringValue = ""
    }

    @objc private func browserDoubleClicked() {
        browserClicked()
        openClicked()
    }
}

extension RemoteFolderPicker: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish(.cancelled)
    }
}

extension RemoteFolderPicker: NSBrowserDelegate {
    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? RemoteFolderNode) ?? root
        guard let children = node.children else {
            // The column is drawn empty and filled when the machine answers. There
            // is nothing else honest to return: the delegate is synchronous and the
            // directory is on the far end of an SSH connection.
            load(node.path)
            return 0
        }
        return children.count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? RemoteFolderNode) ?? root
        guard let children = node.children, children.indices.contains(index) else { return root }
        return children[index]
    }

    /// Nothing is a leaf: every row is a directory, so every row can be descended
    /// into — including an empty one, which draws an empty column exactly as the
    /// Finder does.
    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool { false }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        (item as? RemoteFolderNode)?.name
    }

}

/// The browser's row, carrying the folder icon every row shares.
///
/// Through the prototype rather than `browser(_:willDisplayCell:atRow:column:)`,
/// which the item-based API never sends — it belongs to the older matrix-based
/// delegate, so an image assigned there is set on nothing and never appears.
///
/// The icon is what makes a column read as folders instead of as a list of words,
/// and it is the one thing a browser over another machine has to supply itself:
/// the system resolves an icon from a URL, and none of these paths exist here.
/// Every row is a directory, so every row wears the same one — it is the system's
/// own folder, so the panel matches the local picker rather than approximating it.
private final class RemoteFolderCell: NSBrowserCell {
    static let folderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    override init(textCell string: String) {
        super.init(textCell: string)
        apply()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        apply()
    }

    private func apply() {
        image = Self.folderIcon
        font = .systemFont(ofSize: NSFont.systemFontSize)
    }
}

extension RemoteFolderPicker: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard !isCompleting else { return }
        refreshCompletions()
    }

    /// Splits what is typed at the last `/` into the directory to list and the
    /// partial name to match inside it, then lists that directory if it is not the
    /// one already held. Typing further into the same directory re-filters what is
    /// in hand and never touches the network.
    private func refreshCompletions() {
        let typed = RemotePathEntry.expandingTilde(
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
        let (directory, _) = RemotePathEntry.split(typed)
        guard directory != listedDirectory else {
            showCompletions()
            return
        }
        lister.list(directory) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The user may have typed on while this was in flight; a reply for
                // a directory they have already left is dropped rather than shown
                // against the wrong path.
                let current = RemotePathEntry.expandingTilde(
                    self.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    home: self.home)
                guard RemotePathEntry.split(current).directory == directory else { return }
                self.listedDirectory = directory
                // An unreadable or missing directory completes to nothing. It is not
                // an error to report: the user is mid-path, and a half-typed
                // directory name is unreadable by definition.
                self.listedNames = (try? result.get())?.map(\.name) ?? []
                self.showCompletions()
            }
        }
    }

    private func showCompletions() {
        guard !listedNames.isEmpty, let editor = field.currentEditor() as? NSTextView else { return }
        isCompleting = true
        editor.complete(nil)
        isCompleting = false
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let typed = RemotePathEntry.expandingTilde(
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
        let (_, partial) = RemotePathEntry.split(typed)
        guard !partial.isEmpty else { return listedNames }
        return listedNames.filter {
            $0.range(of: partial, options: [.caseInsensitive, .anchored]) != nil
        }
    }
}
