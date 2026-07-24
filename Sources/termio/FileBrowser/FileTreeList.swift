import AppKit
import SwiftUI

/// The disclosure tree itself, split out of `FileBrowserView` so the generic
/// `List(_:children:selection:)` expression type-checks on its own rather than as
/// one giant expression alongside the drop target and Quick Look wiring.
struct FileTreeList: View {
    let nodes: [FileNode]
    @Binding var selection: URL?
    let font: Font
    /// Moves/copies `sources` into a folder `destination`; returns whether the tree
    /// changed. Supplied by `FileBrowserView`, which owns the project path.
    let onDrop: (_ sources: [URL], _ destination: URL) -> Bool
    /// The project (or worktree) root — the directory the empty-area menu creates in.
    let rootURL: URL
    /// Open / create / delete actions, forwarded to each row.
    let actions: FileTreeActions
    /// Registers each row's private outline item with its URL and exposes the hosting
    /// outline view to `FileBrowserView` for programmatic folder toggles.
    let captureOutline: (NSOutlineView?, NSObject?, URL) -> Void
    /// URLs of currently expanded folders, so `FileRow` can use the sidebar's
    /// closed/open Hugeicons folder pair.
    let expandedFolderURLs: Set<URL>

    var body: some View {
        // Keep List's native `selection:` binding — it drives selection at the AppKit
        // layer, which coexists cleanly with `.draggable` (a SwiftUI tap gesture does
        // not, and makes the drag sticky/unreliable). The only downside of the native
        // selection — its edge-to-edge blue accent fill — is removed by setting the
        // outline view's `selectionHighlightStyle = .none` (see `FileRow`), leaving our
        // own `SidebarRowHighlight` as the sole, left-sidebar-matching selection cue.
        List(nodes, children: \.children, selection: $selection) { node in
            FileRow(node: node, font: font, isSelected: selection == node.url, onDrop: onDrop, actions: actions, captureOutline: captureOutline, expandedFolderURLs: expandedFolderURLs)
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
        .background(EmptyAreaContextMenu(rootDirectory: rootURL, actions: actions))
    }
}

/// A single tree row. A view of its own (rather than an inline builder) so each
/// row can hold the `isHovering`/`isTargeted` state that drives its highlight.
private struct FileRow: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let node: FileNode
    let font: Font
    let isSelected: Bool
    let onDrop: (_ sources: [URL], _ destination: URL) -> Bool
    let actions: FileTreeActions
    /// Registers this row's private outline item with `FileBrowserState`.
    let captureOutline: (NSOutlineView?, NSObject?, URL) -> Void
    /// URLs of currently expanded folders — a folder is "open" when its URL is in
    /// this set, driving the sidebar's `.folder` → `.folderOpen` icon toggle.
    let expandedFolderURLs: Set<URL>

    @State private var isHovering = false
    /// True while a drag hovers this folder, lighting its background the way the VS
    /// Code explorer marks the folder a drop would land in.
    @State private var isTargeted = false

    /// Computed from the shared expansion set — a folder is "open" exactly when its
    /// URL is in the set.
    private var isExpanded: Bool { expandedFolderURLs.contains(node.url) }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        // One explicit HStack for both kinds (not `Label`, whose internal insets shift
        // the title): a folder uses the exact closed/open Hugeicons pair from the left
        // sidebar; a file leads with its type icon. Because both start at the HStack's
        // leading edge, a folder's icon lines up in the same column as file icons.
        let row = HStack(spacing: 5) {
            if node.isDirectory {
                HugeIconView(
                    icon: isExpanded ? .folderOpen : .folder,
                    size: 15,
                    color: chrome?.foreground ?? .primary
                )
                    .frame(width: 16, alignment: .leading)
            } else {
                FileIconView(url: node.url, size: 15)
                    .frame(width: 16, alignment: .leading)
            }
            Text(node.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
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
        .onHover { isHovering = $0 }
        // Strip the source list's blue selection fill at the AppKit layer, so the only
        // selection cue is our `SidebarRowHighlight` below. Lives in a row so it can
        // walk up to the enclosing outline view.
        .background(OutlineSelectionStyleStripper())

        // Drag a row out as its file URL. The terminal pane catches the drop and
        // inserts the shell-quoted path at the prompt (see `TerminalPane.sendPaths`);
        // a folder row catches it to move the file into that folder. Selection is the
        // List's own `selection:` binding (set up in `FileTreeList`), which coexists
        // with `.draggable` — so the drag stays immediate.
        .draggable(node.url)
        // The same lift the left sidebar paints for its rows: selection (or a drag
        // hovering a folder) reads as the frosted/accent selected look, hover a
        // fainter step below — so both side panels' rows highlight identically.
        .listRowBackground(
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
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        // Right-click menu via an AppKit `NSMenu`, NOT SwiftUI's `.contextMenu` —
        // the latter paints an accent highlight ring around the targeted row that
        // can't be styled off. New File / New Folder appear only for a folder (they
        // create inside it); a file gets just Delete. The empty area below the rows
        // has its own root menu (see `EmptyAreaContextMenu`).
        .background(RowContextMenu(
            isDirectory: node.isDirectory,
            target: node.url,
            actions: actions
        ))

        // Only folders are drop targets — dropping a file onto a folder moves it in,
        // the VS Code tree gesture. Files are not targets (no "drop onto a file").
        // A single click opens a file via the List's native selection (see
        // `FileBrowserView.onChange(of: selection)`), so no per-row open handler here.
        if node.isDirectory {
            row
                // A row is the one place the walk-up reaches the outline view. Only
                // folders need it: they are the expandable items whose icon state is
                // tracked, and the only rows `FileBrowserView` toggles programmatically.
                .background(OutlineViewCapture(nodeURL: node.url, onFound: captureOutline))
                .dropDestination(for: URL.self) { urls, _ in
                    onDrop(urls, node.url)
                } isTargeted: { isTargeted = $0 }
        } else {
            row
        }
    }
}

/// Finds the table row containing a representable mounted inside a list row.
private func tableRowView(above view: NSView) -> NSTableRowView? {
    var ancestor = view.superview
    while let current = ancestor {
        if let row = current as? NSTableRowView { return row }
        ancestor = current.superview
    }
    return nil
}

/// The per-row right-click menu, via AppKit `NSMenu` rather than SwiftUI's
/// `.contextMenu` — the latter rings the targeted row with an un-styleable accent
/// highlight. A secondary-click recognizer on the row's own view pops the menu up,
/// so nothing emphasizes the row. New File / New Folder appear only for a folder
/// (created inside it); a file gets just Delete.
private struct RowContextMenu: NSViewRepresentable {
    let isDirectory: Bool
    let target: URL
    let actions: FileTreeActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.owner = view
        context.coordinator.configure(isDirectory: isDirectory, target: target, actions: actions)
        context.coordinator.attach()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configure(isDirectory: isDirectory, target: target, actions: actions)
        context.coordinator.attach()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var owner: NSView?
        private var isDirectory = false
        private var target = URL(fileURLWithPath: "/")
        private var actions: FileTreeActions?
        private weak var hostView: NSView?
        private var recognizer: NSClickGestureRecognizer?

        func configure(isDirectory: Bool, target: URL, actions: FileTreeActions) {
            self.isDirectory = isDirectory
            self.target = target
            self.actions = actions
        }

        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner else { return }
                guard let host = tableRowView(above: owner) else { return }
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
            if isDirectory {
                menu.addItem(menuItem("New File", #selector(newFile)))
                menu.addItem(menuItem("New Folder", #selector(newFolder)))
                menu.addItem(.separator())
            }
            menu.addItem(menuItem("Delete", #selector(deleteItem)))
            menu.popUp(positioning: nil, at: recognizer.location(in: hostView), in: hostView)
        }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func newFile() { actions?.newFile(target) }
        @objc private func newFolder() { actions?.newFolder(target) }
        @objc private func deleteItem() { actions?.delete(target) }


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
            menu.addItem(menuItem("New File", #selector(newFile)))
            menu.addItem(menuItem("New Folder", #selector(newFolder)))
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
/// `OutlineSelectionStyleStripper`), so the outline view is a real ancestor on its
/// superview chain — a `.background` on the List sits in a sibling subtree and can't
/// reach it.
private struct OutlineViewCapture: NSViewRepresentable {
    let nodeURL: URL
    let onFound: (NSOutlineView?, NSObject?, URL) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { report(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { report(from: nsView) }
    }

    private func report(from view: NSView) {
        guard let outline = Self.outlineView(above: view) else {
            onFound(nil, nil, nodeURL)
            return
        }
        let item: NSObject?
        if let rowView = tableRowView(above: view) {
            let row = outline.row(for: rowView)
            item = row >= 0 ? outline.item(atRow: row) as? NSObject : nil
        } else {
            item = nil
        }
        onFound(outline, item, nodeURL)
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

/// A zero-size helper that finds the `NSOutlineView` hosting the file tree (by
/// walking up from its own placement inside a row) and sets its
/// `selectionHighlightStyle` to `.none`. That strips the source list's blue accent
/// fill while leaving selection itself intact — so the List keeps native, drag-
/// friendly selection and `SidebarRowHighlight` is the only thing that paints it.
/// Re-applied on every update because each row mounts one, so any list rebuild
/// reasserts the style. Shared with the left sidebar (`SidebarView`), which is the
/// same `.sidebar`-style source list and needs the identical strip.
struct OutlineSelectionStyleStripper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.strip(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.strip(from: nsView) }
    }

    private static func strip(from view: NSView) {
        var ancestor = view.superview
        while let current = ancestor {
            // NSOutlineView is an NSTableView subclass, so this catches the tree.
            if let table = current as? NSTableView {
                if table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
                return
            }
            ancestor = current.superview
        }
    }
}
