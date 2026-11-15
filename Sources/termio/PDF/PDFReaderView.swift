import AppKit
import PDFKit
import SwiftUI

/// The PDF face of `FilePreviewView`: a reading view for documents opened beside an agent.
///
/// A PDF is the one previewable file you *read* rather than glance at, so it gets a
/// reader's chrome instead of a bare `PDFView` — a sidebar carrying the document's own
/// table of contents, page thumbnails and your highlights, a page indicator, and a
/// right-click menu whose verbs are copy, mark, and hand the passage to the agent running
/// in the terminal underneath.
struct PDFReaderView: View {
    let url: URL
    @ObservedObject var settings: AppSettings
    let displayName: String?
    /// "Add to Chat", same contract as the editor and the Markdown reader: a passage goes
    /// over as a snippet, `nil` means send the document's path.
    let addToChat: ((String?) -> Void)?
    let canAddToChat: (() -> Bool)?
    let onClose: () -> Void

    @StateObject private var model: PDFReaderModel

    /// The rail's width, persisted so a reader who widens it for a book with long chapter
    /// titles finds it that way next time. Shared by every PDF, like the inspector's own
    /// list column.
    @AppStorage("pdfReaderSidebarWidth") private var sidebarWidth: Double = 216

    // Find — the bar the editor and the diff use, over PDFKit's own search.
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findOptions = FindOptions()
    /// Bumped on every ⌘F so the field takes the keyboard even when the bar is already open.
    @State private var findFocusTrigger = 0

    init(
        url: URL,
        settings: AppSettings,
        displayName: String? = nil,
        addToChat: ((String?) -> Void)? = nil,
        canAddToChat: (() -> Bool)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.url = url
        self.settings = settings
        self.displayName = displayName
        self.addToChat = addToChat
        self.canAddToChat = canAddToChat
        self.onClose = onClose
        _model = StateObject(wrappedValue: PDFReaderModel(
            url: url, addToChat: addToChat, canAddToChat: canAddToChat))
    }

    private var fileName: String { displayName ?? url.lastPathComponent }

    /// Drag bounds for the rail: narrow enough to leave the page room, wide enough that a
    /// nested section title still reads.
    private static let minSidebarWidth: CGFloat = 170
    private static let maxSidebarWidth: CGFloat = 420
    /// What a double-click on the seam snaps back to.
    private static let defaultSidebarWidth: CGFloat = 216
    /// The rail's leading edge is this space's origin, so the pointer's x *is* the width.
    private static let dragSpace = "pdfSidebar"

    /// Room at both ends of the header for the rail switch on one side and the page field
    /// plus window controls on the other, so a centered title clears the wider of the two.
    private static let titleClearance: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.opened {
                GeometryReader { geo in
                    // Never let the rail eat the page on a narrow window.
                    let ceiling = max(Self.minSidebarWidth,
                                      min(Self.maxSidebarWidth, geo.size.width - 260))
                    let width = max(Self.minSidebarWidth, min(CGFloat(sidebarWidth), ceiling))
                    HStack(spacing: 0) {
                        if model.showsSidebar {
                            PDFReaderSidebar(model: model, addToChat: addToChat,
                                             canAddToChat: canAddToChat)
                                .frame(width: width)
                            railDivider(ceiling: ceiling)
                        }
                        PDFDocumentView(model: model)
                            .overlay(alignment: .topTrailing) {
                                if findVisible { findBar }
                            }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .coordinateSpace(.named(Self.dragSpace))
                }
            } else {
                PaneEmptyState(
                    localized("Can’t open"),
                    icon: .fileQuestion,
                    message: localized("“\(fileName)” isn’t a readable PDF.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        // Esc puts away the innermost thing first: the search, then the reader.
        .onExitCommand { if findVisible { closeFind() } else { onClose() } }
        .onReceive(NotificationCenter.default.publisher(for: .termioShowFindBar)) { _ in
            guard model.opened else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findVisible = true }
            findFocusTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .termioFindNext)) { _ in
            if findVisible { model.stepFind(by: 1) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .termioFindPrevious)) { _ in
            if findVisible { model.stepFind(by: -1) }
        }
        // Searches as you type, a beat behind the keys: each search reads the whole book.
        .task(id: FindRequest(query: findQuery, caseSensitive: findOptions.caseSensitive, visible: findVisible)) {
            guard findVisible else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            startFind()
        }
    }

    private struct FindRequest: Hashable {
        let query: String
        let caseSensitive: Bool
        let visible: Bool
    }

    private var findBar: some View {
        FileFindBar(
            query: $findQuery,
            options: $findOptions,
            currentMatch: model.findMatchCount == 0 ? 0 : model.findIndex + 1,
            totalMatches: model.findMatchCount,
            onSubmit: {
                // Return on the search already showing steps to its next result.
                if model.isShowingFind(findQuery, caseSensitive: findOptions.caseSensitive) {
                    model.stepFind(by: 1)
                } else {
                    startFind()
                }
            },
            onNext: { model.stepFind(by: 1) },
            onPrevious: { model.stepFind(by: -1) },
            onClose: closeFind,
            focusTrigger: findFocusTrigger,
            supportsWordAndRegex: false,
            searching: model.isFinding
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func startFind() {
        guard !model.isShowingFind(findQuery, caseSensitive: findOptions.caseSensitive) else { return }
        model.find(findQuery, caseSensitive: findOptions.caseSensitive)
    }

    private func closeFind() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findVisible = false }
        findQuery = ""
        findOptions = FindOptions()
        model.endFind()
        // Hand the keyboard back to the document, so space and the arrows scroll again.
        model.pdfView.window?.makeFirstResponder(model.pdfView)
    }

    /// The seam between the rail and the page, built the way the inspector's list column
    /// is: a hairline under a wider invisible grab strip, the resize cursor on hover, and a
    /// double-click back to the default. One resize gesture across the app.
    private func railDivider(ceiling: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .named(Self.dragSpace))
                            .onChanged { value in
                                sidebarWidth = Double(
                                    max(Self.minSidebarWidth, min(value.location.x, ceiling)))
                            }
                    )
                    .onTapGesture(count: 2) { sidebarWidth = Double(Self.defaultSidebarWidth) }
            }
    }

    // MARK: - Chrome

    private var header: some View {
        ZStack {
            // The document's name sits in the middle of the bar, the way a window title
            // does — the controls at either end are tools, and the title is what the bar
            // is about. Clearance keeps it from ever running under them; past that it
            // truncates in the middle, so the extension stays readable.
            Text(fileName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Self.titleClearance)
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                DetailListColumnToggle()
                PDFSidebarSwitch(model: model)
                PDFHistoryButtons(model: model)
                Spacer(minLength: 8)
                if model.pageCount > 0 {
                    PDFPageField(model: model)
                }
                InspectorDetailChromeButtons()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: GitChangesView.topBarHeight)
        .modifier(DetailHeaderTitlebarInset())
        .background(Color(nsColor: settings.terminalBackgroundColor))
    }
}

/// Which rail the sidebar shows — and whether it shows at all. It sits in the header
/// rather than over the rail: picking a rail and opening the panel are one decision, so
/// tapping the segment you are already on closes the panel, and tapping another opens it.
struct PDFSidebarSwitch: View {
    @ObservedObject var model: PDFReaderModel

    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 0) {
            segment(.contents, icon: .listBullet, help: localized("Contents"))
            segment(.thumbnails, icon: .image, help: localized("Pages"))
            segment(.highlights, icon: .textFont, help: localized("Highlights"))
        }
        .background { pill }
        .padding(2)
        .background { Capsule(style: .continuous).fill(Color.primary.opacity(0.06)) }
        .animation(.snappy(duration: 0.25), value: model.sidebar)
        .animation(.snappy(duration: 0.25), value: model.showsSidebar)
    }

    private func segment(_ tab: PDFReaderModel.Sidebar, icon: HugeIcon, help: String) -> some View {
        let selected = model.showsSidebar && model.sidebar == tab
        // Sized against the chrome buttons at the other end of the header, not against the
        // rail it opens: a header symbol that out-weighs the title reads as a toolbar.
        return HugeIconView(icon: icon, size: 11, color: selected ? .primary : .secondary,
                            lineWidthOverride: 1.2)
            .frame(width: 24, height: 17)
            .matchedGeometryEffect(id: tab, in: pillNamespace)
            .contentShape(.capsule)
            .onTapGesture {
                if model.showsSidebar, model.sidebar == tab {
                    model.showsSidebar = false
                } else {
                    model.sidebar = tab
                    model.showsSidebar = true
                }
            }
            .help(help)
    }

    @ViewBuilder
    private var pill: some View {
        if model.showsSidebar {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.14))
                .matchedGeometryEffect(id: model.sidebar, in: pillNamespace, isSource: false)
        }
    }
}

/// Back and forward through the places you have jumped from. A link, a section in the
/// rail and a search result all take you somewhere else; these are the way home.
struct PDFHistoryButtons: View {
    @ObservedObject var model: PDFReaderModel

    var body: some View {
        HStack(spacing: 2) {
            DetailChromeButton(icon: .chevronLeft, help: localized("Back (⌘[)"), action: model.goBack)
                .disabled(!model.canGoBack)
                .opacity(model.canGoBack ? 1 : 0.35)
            DetailChromeButton(icon: .chevronRight, help: localized("Forward (⌘])"), action: model.goForward)
                .disabled(!model.canGoForward)
                .opacity(model.canGoForward ? 1 : 0.35)
        }
    }
}

/// The page indicator, which is also how you go to a page: click the number, type one,
/// press return. Preview's own move, and the only navigation an 800-page book still needs
/// once the rail is open.
struct PDFPageField: View {
    @ObservedObject var model: PDFReaderModel

    @State private var typed = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 3) {
            TextField("", text: $typed)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 11).monospacedDigit())
                .focused($editing)
                .frame(width: fieldWidth)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(editing ? 0.10 : 0.04))
                }
                .onSubmit(go)
                .onExitCommand { editing = false }
            Text(verbatim: "/ \(model.pageCount)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .onAppear { typed = "\(model.currentPage + 1)" }
        // While you are typing the field is yours; the rest of the time it follows the page.
        .onChange(of: model.currentPage) { _, page in
            guard !editing else { return }
            typed = "\(page + 1)"
        }
        .onChange(of: editing) { _, active in
            if !active { typed = "\(model.currentPage + 1)" }
        }
    }

    /// Wide enough for the document's own page numbers, so the field doesn't resize as you read.
    private var fieldWidth: CGFloat {
        CGFloat(max(2, String(model.pageCount).count)) * 7 + 6
    }

    private func go() {
        guard let page = Int(typed.trimmingCharacters(in: .whitespaces)), model.pageCount > 0 else {
            typed = "\(model.currentPage + 1)"
            return
        }
        model.go(toPage: min(max(page, 1), model.pageCount) - 1)
        editing = false
    }
}

/// The reader's rails: the document's own table of contents, a page strip, and the
/// passages you have marked. Its own view so each rail can be built (and looked at) on
/// its own, and so flipping between them never touches the document beside it.
struct PDFReaderSidebar: View {
    @ObservedObject var model: PDFReaderModel
    let addToChat: ((String?) -> Void)?
    let canAddToChat: (() -> Bool)?

    var body: some View {
        Group {
            switch model.sidebar {
            case .contents: contents
            case .thumbnails: thumbnails
            case .highlights: highlightList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Contents

    /// The navigation pane every reader knows: a disclosure chevron, one indent per level,
    /// and the row you are in filled behind. The fill is ink rather than the system accent —
    /// a document rail marks position, and a blue slab over a book's own headings reads as a
    /// control, not a place.
    @ViewBuilder
    private var contents: some View {
        if model.outline.isEmpty {
            PaneEmptyState(
                localized("No contents"),
                icon: .listBullet,
                message: localized("This PDF carries no table of contents.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.outlineRows) { row in
                            PDFOutlineRow(
                                node: row.node,
                                depth: row.depth,
                                expanded: model.expandedEntries.contains(row.node.id),
                                current: model.currentSectionID == row.node.id,
                                toggle: { model.toggleEntry(row.node.id) },
                                activate: {
                                    model.revealEntry(row.node.id)
                                    model.go(to: row.node)
                                }
                            )
                            .id(row.node.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                // Reading on carries the rail with you: the entry you are inside scrolls
                // into view as the pages turn.
                .onChange(of: model.currentSectionID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    // MARK: - Pages

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        PDFThumbnailCell(model: model, index: index, current: index == model.currentPage)
                            .id(index)
                            .onTapGesture { model.go(toPage: index) }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            // The strip follows the document, so the page you are reading is the page you
            // see in the rail.
            .onChange(of: model.currentPage) { _, page in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(page, anchor: .center) }
            }
        }
    }

    // MARK: - Highlights

    @ViewBuilder
    private var highlightList: some View {
        if model.highlights.isEmpty {
            PaneEmptyState(
                localized("No highlights"),
                icon: .textFont,
                message: localized("Select text in the document, then choose Highlight.")
            )
        } else {
            List(model.highlights) { highlight in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        // The marker you used, so the rail reads like the margin of the book.
                        Circle()
                            .fill(highlight.ink.swatchColor)
                            .frame(width: 7, height: 7)
                        Text(verbatim: localized("Page \(highlight.page + 1)"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(highlight.text)
                        .font(.system(size: 11.5))
                        .lineLimit(4)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { model.go(to: highlight) }
                .contextMenu {
                    Button(localized("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(highlight.text, forType: .string)
                    }
                    if canAddToChat?() == true {
                        Button(localized("Add to Chat")) { addToChat?(highlight.text) }
                    }
                    Divider()
                    Button(localized("Remove Highlight")) { model.remove(highlight.id) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}

/// One entry in the contents rail. Leaves keep the chevron's gutter so their labels line
/// up with their siblings' — a ragged left edge is what makes a deep outline unreadable.
private struct PDFOutlineRow: View {
    let node: PDFOutlineNode
    let depth: Int
    let expanded: Bool
    let current: Bool
    let toggle: () -> Void
    let activate: () -> Void

    @State private var hovering = false

    /// One indent step. Narrow on purpose: a book nests three or four levels deep, and a
    /// wide step pushes the deepest labels off the rail.
    private static let step: CGFloat = 13

    var body: some View {
        HStack(spacing: 3) {
            chevron
            Text(node.label)
                .font(.system(size: 11.5))
                .foregroundStyle(current ? .primary : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if let page = node.page {
                Text(verbatim: "\(page + 1)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * Self.step)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Ink, not the sidebar's `SidebarRowHighlight`: that lift goes accent-tinted under a
        // chrome theme, and an accent slab over a book's own headings reads as a control
        // rather than as your place in the document.
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(current ? Color.primary.opacity(0.11)
                              : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        }
        .onTapGesture(perform: activate)
        .onHover { hovering = $0 }
    }

    /// The file tree's disclosure chevron, at its size and weight: one disclosure symbol
    /// across the app rather than a second one invented for this rail.
    @ViewBuilder
    private var chevron: some View {
        if node.children.isEmpty {
            Color.clear.frame(width: 12, height: 18)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12, height: 18)
                .contentShape(Rectangle())
                // The chevron opens and closes; it never navigates — the file tree's rule too.
                .onTapGesture(perform: toggle)
        }
    }
}

/// One page of the thumbnail rail. The image is rendered on first appearance and kept by
/// the model, so scrolling a long document back and forth costs nothing after the first
/// pass. The current page is marked with ink, not a tint.
private struct PDFThumbnailCell: View {
    @ObservedObject var model: PDFReaderModel
    let index: Int
    let current: Bool

    @State private var image: NSImage?

    private static let height: CGFloat = 132

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle().fill(Color.primary.opacity(0.06))
                        .frame(width: Self.height * 0.72)
                }
            }
            .frame(height: Self.height)
            .overlay {
                Rectangle()
                    .strokeBorder(Color.primary.opacity(current ? 0.7 : 0.15), lineWidth: current ? 2 : 1)
            }
            Text(verbatim: "\(index + 1)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(current ? .primary : .secondary)
        }
        .onAppear {
            guard image == nil else { return }
            // Rendered at 2× the display size so the rail is crisp on Retina.
            image = model.thumbnail(forPage: index, height: Self.height * 2)
        }
    }
}

/// The document itself. The `PDFView` instance belongs to the model, not to this
/// representable, so the sidebar drives the same view the reader scrolls — and so
/// flipping the sidebar in and out never rebuilds the renderer or loses your place.
private struct PDFDocumentView: NSViewRepresentable {
    let model: PDFReaderModel

    func makeNSView(context: Context) -> PDFView {
        let view = model.pdfView
        // Takes first responder off the terminal surface beneath the overlay, so space,
        // the arrow keys and ⌘C act on the document (the Markdown reader's move).
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
