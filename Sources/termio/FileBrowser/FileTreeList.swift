import AppKit
import SwiftUI

/// The disclosure tree itself, split out of `FileBrowserView` so the generic
/// `List(_:children:selection:)` expression type-checks on its own rather than as
/// one giant expression alongside the drop target and Quick Look wiring.
///
/// One list for every machine. The rows come from `DeviceFileTreeModel`, which
/// reads `fs.list` on whichever device the checkout lives on — this Mac over its
/// unix socket like any other. What differs is not how the tree is *read* but
/// what may be *done* to it: the write verbs below (drag, drop, the row menu,
/// New File / New Folder) run on this Mac's own filesystem, so a checkout on
/// another device gets none of them. They are hidden rather than disabled — a
/// menu of items that all refuse is worse than no menu.
struct FileTreeList: View {
    let nodes: [DeviceFileNode]
    /// Bumped by `DeviceFileTreeModel` after it grafts a listing onto realized
    /// nodes in place; the changed input is what makes SwiftUI run an update
    /// pass over the outline, since `nodes` itself — same root node references —
    /// compares unchanged after an incremental re-list.
    let revision: Int
    @Binding var selection: String?
    let font: Font
    /// Moves/copies `sources` into a folder `destination`; returns whether the tree
    /// changed. Supplied by `FileBrowserView`, which owns the project path.
    let onDrop: (_ sources: [URL], _ destination: URL) -> Bool
    /// The checkout root on this Mac — the directory the empty-area menu creates
    /// in, and the base "Copy Relative Path" resolves against. `nil` for a
    /// checkout on another device, where nothing here may write.
    let rootURL: URL?
    /// Open / create / delete actions, forwarded to each row. `nil` alongside a
    /// `nil` `rootURL`, for the same reason.
    let actions: FileTreeActions?
    /// Hands the hosting `NSOutlineView` up to `FileBrowserView` so it can expand a
    /// folder programmatically when its row is selected — a click can't be observed
    /// any other way (the outline view swallows primary-click recognizers).
    let captureOutline: (NSOutlineView?) -> Void

    var body: some View {
        tree.equatable()
    }

    private var tree: EquatableTree {
        EquatableTree(
            nodes: nodes, revision: revision, selection: $selection,
            selectionValue: selection, font: font,
            onDrop: onDrop, rootURL: rootURL, actions: actions, captureOutline: captureOutline
        )
    }
}

/// The `List` itself behind an `Equatable` gate. The parent re-evaluates on every
/// model publish, and a `List(children:)` update is never free — SwiftUI's outline
/// coordinator re-walks every realized row even when nothing changed, which on a
/// high-churn root (a home directory) burned the main thread continuously. Closure
/// properties would make the plain view compare unequal every time, so equality is
/// spelled out over the values that actually affect the rows; the closures are
/// stable for the life of the pane and skipped.
private struct EquatableTree: View, @MainActor Equatable {
    let nodes: [DeviceFileNode]
    let revision: Int
    @Binding var selection: String?
    /// The selection as a plain value. The binding can't serve equality — both
    /// sides of `==` read the live storage and always agree — so the parent
    /// snapshots the value at evaluation time; rows also render from this, keeping
    /// what they show and what the gate compares the same thing.
    let selectionValue: String?
    let font: Font
    let onDrop: (_ sources: [URL], _ destination: URL) -> Bool
    let rootURL: URL?
    let actions: FileTreeActions?
    let captureOutline: (NSOutlineView?) -> Void

    static func == (lhs: EquatableTree, rhs: EquatableTree) -> Bool {
        lhs.revision == rhs.revision
            && lhs.selectionValue == rhs.selectionValue
            && lhs.font == rhs.font
            && lhs.rootURL == rhs.rootURL
            && lhs.nodes.count == rhs.nodes.count
            && zip(lhs.nodes, rhs.nodes).allSatisfy { $0 === $1 }
    }

    var body: some View {
        // Keep List's native `selection:` binding — it drives selection at the AppKit
        // layer, which coexists cleanly with `.draggable` (a SwiftUI tap gesture does
        // not, and makes the drag sticky/unreliable). The only downside of the native
        // selection — its edge-to-edge blue accent fill — is removed by setting the
        // outline view's `selectionHighlightStyle = .none` (see `FileRow`), leaving our
        // own `SidebarRowHighlight` as the sole, left-sidebar-matching selection cue.
        List(nodes, children: \.children, selection: $selection) { node in
            FileRow(node: node, font: font, isSelected: selectionValue == node.path, onDrop: onDrop, rootURL: rootURL, actions: actions, captureOutline: captureOutline)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .padding(.leading, 12)
        // Drop the list's own backing so the terminal-colored background behind it (see
        // `FileBrowserView.body`) shows through — the file column lives in a plain split item, not
        // a panel item, so it carries no system vibrant background of its own.
        .scrollContentBackground(.hidden)
        // Let each row size to its own content (icon/text + the row's vertical padding)
        // rather than forcing a tall minimum — a large min height paints an empty
        // highlight band above/below the label on hover/selection.
        .environment(\.defaultMinListRowHeight, 1)
        // A right-click in the empty area below the rows offers New File / New Folder
        // at the project root — the rows' own menus take the clicks that land on them.
        // Only where there is a root on this Mac to create in.
        .background(emptyAreaMenu)
    }

    @ViewBuilder
    private var emptyAreaMenu: some View {
        if let rootURL, let actions {
            EmptyAreaContextMenu(rootDirectory: rootURL, actions: actions)
        }
    }
}

/// A single tree row. A view of its own (rather than an inline builder) so each
/// row can hold the `isHovering`/`isTargeted` state that drives its highlight.
private struct FileRow: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let node: DeviceFileNode
    let font: Font
    let isSelected: Bool
    let onDrop: (_ sources: [URL], _ destination: URL) -> Bool
    /// The project root — the base "Copy Relative Path" resolves against, and
    /// `nil` for a checkout on another device.
    let rootURL: URL?
    let actions: FileTreeActions?
    /// Reports the hosting outline view up to `FileBrowserView` (see `FileTreeList`).
    let captureOutline: (NSOutlineView?) -> Void

    @State private var isHovering = false
    /// True while a drag hovers this folder, lighting its background the way the VS
    /// Code explorer marks the folder a drop would land in.
    @State private var isTargeted = false

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    /// The file this row addresses on this Mac, or `nil` for a checkout on
    /// another device. Every write-shaped affordance below hangs off it.
    private var localURL: URL? { node.localURL }

    /// Whether clicking this row does anything. A folder expands; a file on this
    /// Mac opens in the editor whatever it is; a file on another device opens
    /// only if the host will serve it as bytes. Everything left — a socket, a
    /// device node, a link the host will not follow — reads as unavailable
    /// rather than as an ordinary row that does nothing when clicked.
    private var isActivatable: Bool {
        node.isDirectory || node.canPreview || localURL != nil
    }

    var body: some View {
        if let notice = node.notice {
            // Not a file: no icon column, no highlight, no affordance. A quiet
            // line in the folder it belongs to, which is where a listing that
            // stopped short has to say so — the rows above it look complete.
            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.vertical, 2)
                .padding(.leading, -6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OutlineViewFixups())
                .background(OutlineViewCapture(onFound: captureOutline))
                .listRowBackground(Color.clear)
        } else {
            row
        }
    }

    @ViewBuilder
    private var row: some View {
        // One explicit HStack for both kinds (not `Label`, whose internal insets shift
        // the title): a folder leads with the same folder glyph the left sidebar's
        // project headers use; a file leads with its type icon. Because both occupy
        // the same 16-wide leading column, names line up down the tree.
        let label = HStack(spacing: 5) {
            if node.isDirectory {
                // Static — the disclosure chevron already carries open/closed state
                // (Finder/Xcode's pattern), so the glyph doesn't need to swap and the
                // row needs no expansion tracking of its own.
                // A symlinked folder gets its own glyph rather than the folder plus a
                // badge — the folder mark carries nothing but "folder", so swapping it
                // for "symlinked folder" costs no information, and one line glyph stays
                // legible at 15pt where a composited badge does not.
                HugeIconView(
                    icon: node.isSymbolicLink ? .folderSymlink : .folder,
                    size: 15,
                    color: chrome?.foreground ?? .primary
                )
                .frame(width: 16, alignment: .leading)
            } else {
                // The file's real language/tool logo (a Devicon mark) when bundled,
                // else a tinted SF Symbol — see `FileIconView`. Boxed below the folder's
                // nominal 15: Devicon marks fill their box edge-to-edge while HugeIcons
                // ink only ~75% of theirs (the left sidebar's shared-column rule), so an
                // equal nominal size made every file icon read a step LARGER than the
                // folder and sidebar family — 12 brings their ink widths level.
                // A symlinked *file* keeps its plain language logo — that mark says more
                // than its link-ness, and the Finder's badge doesn't survive the trade:
                // an arrow small enough to sit in the corner of a 12pt glyph collides
                // with its outline and reads as damage, not as a mark. The tooltip and
                // the row menu's Show Original carry it instead.
                // Only the last component is read, so the synthetic form a device
                // path takes is enough.
                FileIconView(url: node.url, size: 12, symbolSize: 11, ink: chrome?.foreground ?? .primary)
                    .frame(width: 16, alignment: .leading)
            }
            Text(node.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
            // A folder waiting on its listing draws as an empty folder, which is
            // the one thing it is not. Only while there is nothing to show: a
            // folder opened from a prefetch has its rows and says nothing.
            if node.isLoading {
                // No `scaleEffect`: a continuously animating layer under a
                // transform re-rasterizes every frame, which is how the working
                // indicator beachballed the sidebar once already.
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 2)
            }
        }
        // A denser tree than the system default, but with enough vertical breathing
        // room that rows aren't cramped (paired with `defaultMinListRowHeight` below).
        .padding(.vertical, 2)
        // Pull the row left toward the disclosure chevron — SwiftUI's default
        // chevron-to-content gap is wider than VS Code / Xcode, which sit the label
        // tight to the arrow. Applied to both kinds so folder names and file icons
        // share one column.
        .padding(.leading, -6)
        // Fill the row so the tap target — and any folder drop target — spans its
        // full width, not just the label's footprint.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Where a symlink points — the one fact about a link no badge can carry, and the
        // reason the Finder puts it in Get Info rather than on the icon. Applied only to
        // links: an empty `help` string still arms an (empty) AppKit tooltip.
        .modifier(SymbolicLinkTooltip(target: node.symbolicLinkTarget))
        .opacity(isActivatable ? 1 : 0.55)
        .help(isActivatable ? "" : localized("Special files can’t be previewed"))
        .onHover { isHovering = $0 }
        // Strip the source list's blue selection fill and restore the mouse-wheel
        // scroll increment at the AppKit layer (see `OutlineViewFixups`). Lives in a
        // row so it can walk up to the enclosing outline view.
        .background(OutlineViewFixups())
        // Capture that same outline view (a row is the one place the walk-up reaches
        // it) so `FileBrowserView` can expand this folder on the click that selected it.
        .background(OutlineViewCapture(onFound: captureOutline))

        dropTarget(menu(highlight(drag(label))))
    }

    /// Drag a row out as its file URL. The terminal pane catches the drop and
    /// inserts the shell-quoted path at the prompt (see `TerminalPane.sendPaths`);
    /// a folder row catches it to move the file into that folder. Selection is the
    /// List's own `selection:` binding (set up in `FileTreeList`), which coexists
    /// with `.draggable` — so the drag stays immediate.
    ///
    /// A row on another device has no URL this Mac could hand over, so it does
    /// not drag at all rather than dragging a path that resolves to nothing here.
    @ViewBuilder
    private func drag(_ row: some View) -> some View {
        if let localURL {
            row.draggable(localURL)
        } else {
            row
        }
    }

    /// The same lift the left sidebar paints for its rows: selection (or a drag
    /// hovering a folder) reads as the frosted/accent selected look, hover a
    /// fainter step below — so both side panels' rows highlight identically.
    private func highlight(_ row: some View) -> some View {
        row.listRowBackground(
            SidebarRowHighlight(
                isSelected: isSelected || isTargeted,
                isHovering: isHovering,
                chrome: chrome
            )
            // Cancel the highlight's own 6pt leading inset so its frosted lift reaches
            // the row's leading edge, clearing the disclosure chevron. The `.plain`
            // list style (unlike the sidebar's `.sidebar`) hugs the chevron to the
            // row edge, so the default inset would crowd the chevron against the
            // highlight's left rounded corner. Trailing inset is untouched.
            .padding(.leading, -6)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
            .animation(.easeInOut(duration: 0.12), value: isTargeted)
            // No animation on hover: a fade is latency on a cue whose job is to track
            // the cursor. At 120ms over a 0.10-alpha wash the highlight only landed
            // once the pointer had already left the row.
            .animation(nil, value: isHovering)
        )
    }

    /// Right-click menu via an AppKit `NSMenu`, NOT SwiftUI's `.contextMenu` —
    /// the latter paints an accent highlight ring around the targeted row that
    /// can't be styled off. New File / New Folder appear only for a folder (they
    /// create inside it); every row gets Reveal in Finder, Copy Path, Rename,
    /// Delete. The empty area below the rows has its own root menu (see
    /// `EmptyAreaContextMenu`).
    ///
    /// Every item on it moves or reveals a file through this process, so a row
    /// on another device carries no menu rather than one where each item
    /// refuses.
    @ViewBuilder
    private func menu(_ row: some View) -> some View {
        if let localURL, let rootURL, let actions {
            row.background(RowContextMenu(
                isDirectory: node.isDirectory,
                symbolicLinkTarget: node.resolvedSymbolicLinkTarget,
                target: localURL,
                rootURL: rootURL,
                actions: actions
            ))
        } else {
            row
        }
    }

    /// Only folders are drop targets — dropping a file onto a folder moves it in,
    /// the VS Code tree gesture. Files are not targets (no "drop onto a file").
    /// A single click opens a file via the List's native selection (see
    /// `FileBrowserView.activateSelection`), so no per-row open handler here.
    @ViewBuilder
    private func dropTarget(_ row: some View) -> some View {
        if node.isDirectory, let localURL {
            row.dropDestination(for: URL.self) { urls, _ in
                onDrop(urls, localURL)
            } isTargeted: { isTargeted = $0 }
        } else {
            row
        }
    }
}

/// Hover text naming a symlink's target, applied only when there is one — `.help("")`
/// still arms an AppKit tooltip, which would flash an empty bubble over every ordinary
/// row in the tree.
private struct SymbolicLinkTooltip: ViewModifier {
    let target: String?

    func body(content: Content) -> some View {
        if let target {
            content.help(localized("Alias → \(target)"))
        } else {
            content
        }
    }
}

/// The per-row right-click menu, via AppKit `NSMenu` rather than SwiftUI's
/// `.contextMenu` — the latter rings the targeted row with an un-styleable accent
/// highlight. A secondary-click recognizer on the row's own view pops the menu up,
/// so nothing emphasizes the row. New File / New Folder appear only for a folder
/// (created inside it); every row gets Reveal in Finder, Copy Path / Copy Relative
/// Path, Rename, and Delete.
private struct RowContextMenu: NSViewRepresentable {
    let isDirectory: Bool
    /// Where this row's symlink lands, or nil when the row isn't a link — gates Show
    /// Original.
    let symbolicLinkTarget: URL?
    let target: URL
    let rootURL: URL
    let actions: FileTreeActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.owner = view
        context.coordinator.configure(
            isDirectory: isDirectory,
            symbolicLinkTarget: symbolicLinkTarget,
            target: target,
            rootURL: rootURL,
            actions: actions
        )
        context.coordinator.attach()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configure(
            isDirectory: isDirectory,
            symbolicLinkTarget: symbolicLinkTarget,
            target: target,
            rootURL: rootURL,
            actions: actions
        )
        context.coordinator.attach()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var owner: NSView?
        private var isDirectory = false
        private var symbolicLinkTarget: URL?
        private var target = URL(fileURLWithPath: "/")
        private var rootURL = URL(fileURLWithPath: "/")
        private var actions: FileTreeActions?
        private weak var hostView: NSView?
        private var recognizer: NSClickGestureRecognizer?

        func configure(
            isDirectory: Bool,
            symbolicLinkTarget: URL?,
            target: URL,
            rootURL: URL,
            actions: FileTreeActions
        ) {
            self.isDirectory = isDirectory
            self.symbolicLinkTarget = symbolicLinkTarget
            self.target = target
            self.rootURL = rootURL
            self.actions = actions
        }

        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner else { return }
                guard let host = Self.rowView(above: owner) else { return }
                if hostView === host, recognizer != nil { return }
                detach()
                let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.showMenu(_:)))
                recognizer.buttonMask = 0x2 // secondary (right) mouse button
                host.addGestureRecognizer(recognizer)
                self.recognizer = recognizer
                self.hostView = host
            }
        }

        func detach() {
            if let recognizer, let hostView { hostView.removeGestureRecognizer(recognizer) }
            recognizer = nil
            hostView = nil
        }

        @objc private func showMenu(_ recognizer: NSClickGestureRecognizer) {
            guard let hostView else { return }
            let menu = NSMenu()
            // Cursor's explorer verb, leading the menu: the row lands in the agent's
            // prompt as a shell-quoted path — the same token a drag onto the terminal
            // inserts. Gated live at open time; a plain shell has no chat to add to.
            if actions?.canAddToChat() == true {
                let add = menuItem(localized("Add to Chat"), #selector(addToChat))
                menu.addItem(add)
                menu.addItem(.separator())
            }
            if isDirectory {
                menu.addItem(menuItem(localized("New File"), #selector(newFile)))
                menu.addItem(menuItem(localized("New Folder"), #selector(newFolder)))
                menu.addItem(.separator())
            }
            // The Finder's own verb for an alias, and directly above Reveal in Finder so
            // the pair reads as "the original" versus "this link". Absent on a row that
            // isn't a link, and on one whose target is gone.
            if symbolicLinkTarget != nil {
                menu.addItem(menuItem(localized("Show Original"), #selector(showOriginal)))
            }
            menu.addItem(menuItem(localized("Reveal in Finder"), #selector(revealInFinder)))
            menu.addItem(.separator())
            menu.addItem(menuItem(localized("Copy Path"), #selector(copyPath)))
            menu.addItem(menuItem(localized("Copy Relative Path"), #selector(copyRelativePath)))
            menu.addItem(.separator())
            menu.addItem(menuItem(localized("Rename…"), #selector(rename)))
            menu.addItem(menuItem(localized("Delete"), #selector(deleteItem)))
            menu.popUp(positioning: nil, at: recognizer.location(in: hostView), in: hostView)
        }

        @objc private func addToChat() { actions?.addToChat(target) }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func newFile() { actions?.newFile(target) }
        @objc private func newFolder() { actions?.newFolder(target) }
        @objc private func rename() { actions?.rename(target) }
        @objc private func deleteItem() { actions?.delete(target) }
        @objc private func revealInFinder() {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }

        /// Reveals what the link points at, not the link — the Finder selects the target
        /// in its own folder, which is where "where does this actually live" gets
        /// answered.
        @objc private func showOriginal() {
            guard let symbolicLinkTarget else { return }
            NSWorkspace.shared.activateFileViewerSelecting([symbolicLinkTarget])
        }

        @objc private func copyPath() {
            setPasteboard(target.path)
        }

        /// The path relative to the project root — the form agents and build tools
        /// take; falls back to the absolute path for anything outside the root.
        @objc private func copyRelativePath() {
            let rootPath = rootURL.standardizedFileURL.path
            let path = target.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") {
                setPasteboard(String(path.dropFirst(rootPath.count + 1)))
            } else {
                setPasteboard(path)
            }
        }

        private func setPasteboard(_ string: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        }

        private static func rowView(above view: NSView) -> NSView? {
            var ancestor = view.superview
            while let current = ancestor {
                if current is NSTableRowView { return current }
                ancestor = current.superview
            }
            return nil
        }
    }
}

/// The right-click menu for the empty area below the rows: New File / New Folder at
/// the project root. One recognizer on the outline view, guarded to fire only where
/// no row sits (a row's own `RowContextMenu` handles clicks that land on it).
private struct EmptyAreaContextMenu: NSViewRepresentable {
    let rootDirectory: URL
    let actions: FileTreeActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.owner = view
        context.coordinator.configure(rootDirectory: rootDirectory, actions: actions)
        context.coordinator.attach()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configure(rootDirectory: rootDirectory, actions: actions)
        context.coordinator.attach()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var owner: NSView?
        private var rootDirectory = URL(fileURLWithPath: "/")
        private var actions: FileTreeActions?
        private weak var table: NSTableView?
        private var recognizer: NSClickGestureRecognizer?

        func configure(rootDirectory: URL, actions: FileTreeActions) {
            self.rootDirectory = rootDirectory
            self.actions = actions
        }

        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner else { return }
                guard let table = Self.outlineView(near: owner) else { return }
                if self.table === table, recognizer != nil { return }
                detach()
                let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.showMenu(_:)))
                recognizer.buttonMask = 0x2 // secondary (right) mouse button
                table.addGestureRecognizer(recognizer)
                self.recognizer = recognizer
                self.table = table
            }
        }

        func detach() {
            if let recognizer, let table { table.removeGestureRecognizer(recognizer) }
            recognizer = nil
            table = nil
        }

        @objc private func showMenu(_ recognizer: NSClickGestureRecognizer) {
            guard let table else { return }
            let point = recognizer.location(in: table)
            // Only the empty area — a click on a real row is handled by its own menu.
            guard table.row(at: point) == -1 else { return }
            let menu = NSMenu()
            menu.addItem(menuItem(localized("New File"), #selector(newFile)))
            menu.addItem(menuItem(localized("New Folder"), #selector(newFolder)))
            menu.popUp(positioning: nil, at: point, in: table)
        }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func newFile() { actions?.newFile(rootDirectory) }
        @objc private func newFolder() { actions?.newFolder(rootDirectory) }

        /// Walk up to the enclosing scroll view, then find the outline/table view in it.
        private static func outlineView(near view: NSView) -> NSTableView? {
            var ancestor: NSView? = view
            while let current = ancestor {
                if let scroll = current as? NSScrollView, let table = findTable(in: scroll) {
                    return table
                }
                ancestor = current.superview
            }
            return nil
        }

        private static func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = findTable(in: subview) { return table }
            }
            return nil
        }
    }
}

/// Finds the `NSOutlineView` backing the file tree and hands it to `onFound`, so
/// `FileBrowserView` can expand a folder programmatically when its row is selected —
/// the click that selects a row is the only reliable signal (the outline view swallows
/// primary-click recognizers in its own mouse tracking). Mounted *inside a row* (like
/// `OutlineViewFixups`), so the outline view is a real ancestor on its
/// superview chain — a `.background` on the List sits in a sibling subtree and can't
/// reach it. Shared with the remote tree (`RemoteFileRow`), which needs the same
/// capture for the same click-to-expand gesture.
struct OutlineViewCapture: NSViewRepresentable {
    let onFound: (NSOutlineView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onFound(Self.outlineView(above: view)) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onFound(Self.outlineView(above: nsView)) }
    }

    /// Walk up to the enclosing outline view (an `NSTableView` subclass).
    private static func outlineView(above view: NSView) -> NSOutlineView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let outline = current as? NSOutlineView { return outline }
            ancestor = current.superview
        }
        return nil
    }
}

/// A zero-size helper that finds the `NSTableView`/`NSOutlineView` backing a List
/// (by walking up from its own placement inside a row) and corrects two AppKit-layer
/// details SwiftUI gets wrong for our lists. Re-applied on every update because each
/// row mounts one, so any list rebuild reasserts both. Shared by the left sidebar,
/// this file tree, and the Issues / PR-files / git-changes lists.
///
/// - `selectionHighlightStyle = .none` strips the source list's blue accent fill
///   while leaving selection itself intact — the List keeps native, drag-friendly
///   selection and `SidebarRowHighlight` is the only thing that paints it.
/// - `verticalLineScroll = 24` restores mouse-wheel scrolling. These lists all set
///   `defaultMinListRowHeight` to 1 so rows self-size, but SwiftUI writes that
///   minimum into `NSTableView.rowHeight`, and AppKit mirrors `rowHeight` into the
///   enclosing scroll view's `verticalLineScroll` — the per-line increment every
///   non-precise (physical wheel) scroll event is multiplied by. At 1pt a wheel
///   notch barely moves the list; 24 is what a default-height List gets, so wheels
///   feel like every other Mac list. Trackpads send precise pixel deltas and never
///   consult it.
struct OutlineViewFixups: NSViewRepresentable {
    /// Overrides the table's style. Left `nil` everywhere the source list's own
    /// metrics are wanted; the settings sidebar passes `.fullWidth` because
    /// `.sourceList` reserves a leading strip for a disclosure column that a flat
    /// list never uses, and that strip is not reachable from `listRowInsets` —
    /// it lands *outside* them, so the rows can only ever start further right
    /// than the traffic lights they should line up under.
    var style: NSTableView.Style?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(from: view, style: style) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(from: nsView, style: style) }
    }

    /// Reasserts the wheel increment on an outline captured earlier (see
    /// `OutlineViewCapture`) — for callers that know a specific update just reset
    /// it, like the inspector's tab switch covering the always-mounted file tree.
    static func assertWheelIncrement(on outline: NSOutlineView?) {
        guard let scroll = outline?.enclosingScrollView, scroll.verticalLineScroll != 24 else { return }
        scroll.verticalLineScroll = 24
    }

    private static func apply(from view: NSView, style: NSTableView.Style?) {
        var ancestor = view.superview
        while let current = ancestor {
            // NSOutlineView is an NSTableView subclass, so this catches the tree.
            if let table = current as? NSTableView {
                if table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
                if let style, table.style != style {
                    table.style = style
                    // The other half of the same strip: an outline indents every
                    // row by one level's worth even when nothing is nested.
                    (table as? NSOutlineView)?.indentationPerLevel = 0
                }
                if let scroll = table.enclosingScrollView {
                    if scroll.verticalLineScroll != 24 {
                        scroll.verticalLineScroll = 24
                    }
                    enforce(scroll)
                }
                return
            }
            ancestor = current.superview
        }
    }

    /// SwiftUI re-configures the List's scroll view on some structural updates
    /// (covering the pane with another tab's overlay is one), resetting
    /// `verticalLineScroll` back to the 1pt it mirrors from `rowHeight` — and a
    /// property-less representable gets no `updateNSView` afterward to re-run
    /// `apply`, so a one-shot write stays clobbered on an always-mounted list.
    /// This observer watches the clip view's bounds (they change on every scroll)
    /// and re-asserts the increment the moment a reset scroll view first moves, so
    /// a wheel is never slow for more than its first notch. One observer per
    /// scroll view; the token dies with the scroll view it's associated to.
    private static func enforce(_ scroll: NSScrollView) {
        guard objc_getAssociatedObject(scroll, &enforcementKey) == nil else { return }
        scroll.contentView.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: nil
        ) { [weak scroll] _ in
            // `queue: nil` delivers on the posting thread, and AppKit posts a clip
            // view's bounds change on main — the isolation the scroll view's own
            // properties require.
            MainActor.assumeIsolated {
                guard let scroll, scroll.verticalLineScroll != 24 else { return }
                scroll.verticalLineScroll = 24
            }
        }
        objc_setAssociatedObject(scroll, &enforcementKey, token, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// Unique address keying the enforcement token onto its scroll view. Only its
/// address is ever taken; the value itself is never read or written.
nonisolated(unsafe) private var enforcementKey: UInt8 = 0
