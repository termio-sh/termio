import AppKit
import PDFKit
import SwiftUI

/// One entry of a document's table of contents, flattened out of PDFKit's `PDFOutline`
/// tree so SwiftUI can render it. The destination is kept as the page index plus the
/// point on that page, rather than the `PDFDestination` object, so a node is a value.
struct PDFOutlineNode: Identifiable {
    let id = UUID()
    let label: String
    /// Zero-based page the entry points at; `nil` for a grouping row with no destination.
    let page: Int?
    /// Where on the page, in page space. `nil` means the top of the page.
    let point: CGPoint?
    let children: [PDFOutlineNode]

    /// This node and every descendant, in reading order — what "which section am I in?"
    /// scans and what the sidebar's auto-reveal walks.
    var flattened: [PDFOutlineNode] { [self] + children.flatMap(\.flattened) }

    /// Every entry's parent, keyed by child id — what "reveal where I am" walks upward.
    static func parents(in nodes: [PDFOutlineNode]) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        func walk(_ nodes: [PDFOutlineNode]) {
            for node in nodes {
                for child in node.children { map[child.id] = node.id }
                walk(node.children)
            }
        }
        walk(nodes)
        return map
    }

    static func tree(from root: PDFOutline?, in document: PDFDocument) -> [PDFOutlineNode] {
        guard let root else { return [] }
        return (0..<root.numberOfChildren).compactMap { index in
            guard let child = root.child(at: index) else { return nil }
            return node(from: child, in: document)
        }
    }

    private static func node(from outline: PDFOutline, in document: PDFDocument) -> PDFOutlineNode {
        // An entry's target is either a destination or a "go to" action carrying one.
        let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        let page = destination?.page.flatMap { page -> Int? in
            let index = document.index(for: page)
            return index == NSNotFound ? nil : index
        }
        let children = (0..<outline.numberOfChildren).compactMap { index in
            outline.child(at: index).map { node(from: $0, in: document) }
        }
        return PDFOutlineNode(
            label: outline.label ?? "",
            page: page,
            point: destination?.point,
            children: children
        )
    }
}

/// The state behind the PDF reader: the document, its table of contents, the page you are
/// on, and the marks you have made. It owns the single `PDFView` instance so the sidebar
/// (contents, thumbnails, highlights) can drive the same view the reader is scrolling —
/// one document, one renderer.
@MainActor
final class PDFReaderModel: ObservableObject {
    enum Sidebar: Hashable, CaseIterable { case contents, thumbnails, highlights }

    let url: URL
    let pdfView = ContextMenuPDFView()

    @Published private(set) var outline: [PDFOutlineNode] = []
    @Published private(set) var highlights: [PDFHighlight] = []
    @Published private(set) var pageCount = 0
    @Published private(set) var currentPage = 0
    @Published private(set) var opened = false
    @Published var sidebar: Sidebar = .contents
    /// Whether the rail is open. Closed to begin with — a book opens on the book, and the
    /// three segments in the header are how you ask for the rail — but the choice is
    /// remembered, so a reader who wants the contents beside them keeps them.
    @Published var showsSidebar = UserDefaults.standard.bool(forKey: PDFReaderModel.sidebarVisibleKey) {
        didSet { UserDefaults.standard.set(showsSidebar, forKey: PDFReaderModel.sidebarVisibleKey) }
    }

    private static let sidebarVisibleKey = "pdfReaderSidebarVisible"

    /// Whether there is somewhere to go back or forward to. Following a link, picking a
    /// section and landing on a search result each leave the place you came from behind you.
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    /// The search in progress: how many places the words turn up, and which one you are on.
    @Published private(set) var findMatchCount = 0
    @Published private(set) var findIndex = 0
    /// True until the document has been read to its end. A long book takes seconds the
    /// first time, and "no results" while it is still looking would be a lie.
    @Published private(set) var isFinding = false
    private var findMatches: [PDFSelection] = []
    private(set) var findQuery = ""
    private var findCaseSensitive = false
    /// The page the search started from: the first result shown is the next one from
    /// there, not the first in the book.
    private var findOrigin = 0
    private var findHasFocusedMatch = false
    private static let findMatchColor = NSColor.findHighlightColor.withAlphaComponent(0.45)
    private static let findCurrentMatchColor = NSColor.systemOrange.withAlphaComponent(0.75)
    private var findMarkedOrigin = false

    /// Set once the saved reading position has been applied. Until then the view sits on
    /// page one, and remembering *that* would overwrite the place it is about to return to.
    private var restoredPosition = false

    /// Which entries are open. Collapsed by default — a book's outline is a map, and a
    /// map that shows every street name at once is unreadable.
    @Published private(set) var expandedEntries: Set<UUID> = []

    /// The sidecar's key: the document's content hash, computed once on open. Marks are
    /// saved against it so a highlight never re-reads the file.
    /// Where this document's marks are filed — its repo's `.termio/pdf`, or the app's own
    /// storage when the document belongs to no repo. Resolved once on open.
    private var markStore: PDFHighlightStore.Store?
    /// How this document identifies itself to its sidecar — path, content hash, page
    /// count. Taken once on open: the hash reads the whole file.
    private var markIdentity: PDFHighlightStore.Identity?
    /// The marks the file carried when it opened, by placement. Everything else in
    /// `highlights` is the unsaved layer, and that is exactly what the sidecar holds.
    private var savedMarks: Set<PDFHighlight.Placement> = []
    /// Marks the file carries that the reader has removed. The annotation is off the page
    /// already; this is what keeps it off across a close and reopen, and what tells a save
    /// to delete it from the book. Without it, removing an embedded mark lasted until the
    /// document was next opened.
    private var removedFromDocument: Set<PDFHighlight.Placement> = []
    /// Marks the file carries whose colour the reader changed, by placement.
    private var recolouredInDocument: [PDFHighlight.Placement: PDFHighlightColor] = [:]
    /// Bumped by every edit. A save records the value it started from, so a change made
    /// while the write was in flight is not reported as already saved.
    private var editGeneration = 0

    private var thumbnails: [Int: NSImage] = [:]
    private var flattenedOutline: [PDFOutlineNode] = []
    /// Each entry's parent, so the rail can open the chain down to the section you are in.
    private var outlineParents: [UUID: UUID] = [:]
    /// Held in a box because `deinit` is nonisolated and may not touch main-actor state;
    /// the box drops the token when the model goes away.
    private let observers = ObserverBox()

    private final class ObserverBox: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    init(url: URL, addToChat: ((String?) -> Void)?, canAddToChat: (() -> Bool)?) {
        self.url = url
        configureView()
        wireMenu(addToChat: addToChat, canAddToChat: canAddToChat)
        open()
    }

    // MARK: - Document

    private func configureView() {
        // Continuous vertical scroll, scaled to fit the pane: the reading posture, not the
        // slide-deck one. The background stays clear so the overlay's terminal-colored fill
        // shows through around the paper.
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displayBox = .cropBox
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .clear
    }

    private func open() {
        guard let document = PDFDocument(url: url) else { return }
        pdfView.document = document
        pageCount = document.pageCount
        outline = PDFOutlineNode.tree(from: document.outlineRoot, in: document)
        flattenedOutline = outline.flatMap(\.flattened)
        outlineParents = PDFOutlineNode.parents(in: outline)
        // A document with no table of contents opens on pages instead of an empty list.
        if outline.isEmpty { sidebar = .thumbnails }
        markStore = PDFHighlightStore.store(for: url)
        markIdentity = PDFHighlightStore.Identity.of(url, pageCount: document.pageCount)
        // What the book itself carries — including marks made in Preview or Books — then
        // the ones termio is holding that aren't in the file yet.
        var inDocument = PDFHighlightStore.marksInDocument(document)
        savedMarks = Set(inDocument.map(\.placement))
        // Edits to the book's own marks that haven't been written back yet.
        let pending = markIdentity.map { PDFHighlightStore.pendingEdits(from: $0, store: markStore) }
            ?? (removed: [], recoloured: [:])
        removedFromDocument = Set(pending.removed)
        recolouredInDocument = pending.recoloured
        inDocument.removeAll { mark in
            guard removedFromDocument.contains(mark.placement) else { return false }
            if let page = document.page(at: mark.page) {
                for annotation in PDFHighlightStore.highlights(on: page, covering: mark.placement) {
                    page.removeAnnotation(annotation)
                }
            }
            return true
        }
        for index in inDocument.indices {
            guard let colour = recolouredInDocument[inDocument[index].placement] else { continue }
            inDocument[index].color = colour
            if let page = document.page(at: inDocument[index].page) {
                for annotation in PDFHighlightStore.highlights(
                    on: page, covering: inDocument[index].placement) {
                    annotation.color = colour.annotationColor
                }
            }
        }
        let unsaved = (markIdentity.flatMap { identity in
            markStore.map { PDFHighlightStore.load(from: $0, identity: identity) }
        } ?? []).filter { !savedMarks.contains($0.placement) }
        // The rectangles are the fast anchor, the quote is the durable one: a document
        // re-exported from its source comes back with the same words in different places.
        // Each miss reads up to 21 pages of text, so the searching is capped — a book whose
        // every mark has come loose must not hold the first page hostage while it looks.
        var searches = 0
        let anchored = unsaved.map { mark -> PDFHighlight in
            guard searches < Self.reanchorBudget else { return mark }
            let (result, searched) = reanchored(mark, in: document)
            if searched { searches += 1 }
            return result
        }
        highlights = inDocument + anchored
        for highlight in anchored { annotate(highlight) }
        sortHighlights()
        if anchored.map(\.placement) != unsaved.map(\.placement) { persist() }
        observers.tokens.append(NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readCurrentPage() }
        })
        // Quitting removes no view from its window, so the place within the page would
        // otherwise be the one saved at the last page turn.
        observers.tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        })
        observers.tokens.append(NotificationCenter.default.addObserver(
            forName: .PDFViewChangedHistory, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readHistory() }
        })
        observers.tokens.append(NotificationCenter.default.addObserver(
            forName: .PDFDocumentDidFindMatch, object: document, queue: .main
        ) { [weak self] note in
            // The notification is delivered on the main queue; the selection is read inside
            // the isolated block so it never crosses an isolation boundary.
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let self,
                      let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
                else { return }
                self.foundMatch(selection)
            }
        })
        observers.tokens.append(NotificationCenter.default.addObserver(
            forName: .PDFDocumentDidEndFind, object: document, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishedFinding() }
        })
        opened = true
    }

    private func readCurrentPage() {
        guard let page = pdfView.currentPage, let document = pdfView.document else { return }
        let index = document.index(for: page)
        guard index != NSNotFound, index != currentPage else { return }
        currentPage = index
        if let section = currentSectionID { revealEntry(section) }
        rememberPosition()
    }

    // MARK: - History

    func goBack() {
        guard pdfView.canGoBack else { return }
        // Going back spends the place a search filed; the next result stepped to files
        // the new one, so there is always a way back from a result.
        findMarkedOrigin = false
        pdfView.goBack(nil)
    }

    func goForward() {
        guard pdfView.canGoForward else { return }
        findMarkedOrigin = false
        pdfView.goForward(nil)
    }

    private func readHistory() {
        canGoBack = pdfView.canGoBack
        canGoForward = pdfView.canGoForward
    }

    // MARK: - Reading position

    /// Saves where the view is. Called as pages turn and when the reader goes away, so a
    /// crash costs at most the scroll within a page.
    func rememberPosition() {
        guard restoredPosition, let document = pdfView.document,
              let destination = pdfView.currentDestination, let page = destination.page else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        PDFReadingPosition.remember(.init(page: index, y: destination.point.y), for: url)
    }

    /// Returns to where this document was last read. Runs once, after the view has a size —
    /// before that there is no scroll position to set.
    private func restorePosition() {
        guard !restoredPosition else { return }
        restoredPosition = true
        // The file at this path may have been replaced by a shorter one since, and asking
        // PDFKit for a page past the end raises instead of returning nil.
        guard let place = PDFReadingPosition.place(for: url), let document = pdfView.document,
              place.page < document.pageCount, let page = document.page(at: place.page),
              place.page > 0 || place.y < page.bounds(for: .cropBox).maxY - 1 else { return }
        scrollQuietly(to: CGRect(x: 0, y: place.y, width: 1, height: 0), on: page, centered: false)
    }

    /// Moves the view without `go(to:)`, which files every move in the history: reopening
    /// a book must not light the Back button, and stepping through forty search results
    /// must not bury the place you started from under forty entries.
    private func scrollQuietly(to rect: CGRect, on page: PDFPage, centered: Bool) {
        guard let documentView = pdfView.documentView else { return }
        let target = documentView.convert(pdfView.convert(rect, from: page), from: pdfView)
        let visible = documentView.visibleRect
        var y: CGFloat
        if centered {
            y = target.midY - visible.height / 2
        } else {
            y = documentView.isFlipped ? target.minY : target.maxY - visible.height
        }
        let bounds = documentView.bounds
        y = max(bounds.minY, min(y, bounds.maxY - visible.height))
        documentView.scroll(CGPoint(x: visible.minX, y: y))
        // PDFKit works out which page it is on from the scroll view's live-scroll
        // notification, not from the scroll itself; without this the page field and the
        // contents rail stay on the page the view just left.
        if let scrollView = documentView.enclosingScrollView {
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        }
    }

    // MARK: - Find

    /// Starts looking for `query` through the whole document. Results arrive as PDFKit
    /// reads pages, so the first one is on screen long before a long book is finished.
    func find(_ query: String, caseSensitive: Bool) {
        guard let document = pdfView.document else { return }
        // Cancelling reports the old search as ended before it returns. The search is marked
        // over first, so that report is ignored: a half-finished search has no "first
        // result" worth jumping to.
        isFinding = false
        document.cancelFindString()
        resetFind()
        findQuery = query
        findCaseSensitive = caseSensitive
        guard !query.isEmpty else { return }
        findOrigin = currentPage
        isFinding = true
        document.beginFindString(query, withOptions: caseSensitive ? [] : [.caseInsensitive])
    }

    /// Whether the search on screen is already the one for these words.
    func isShowingFind(_ query: String, caseSensitive: Bool) -> Bool {
        query == findQuery && caseSensitive == findCaseSensitive
    }

    func stepFind(by offset: Int) {
        let count = findMatches.count
        guard count > 0 else { return }
        focusMatch(((findIndex + offset) % count + count) % count)
    }

    func endFind() {
        isFinding = false
        pdfView.document?.cancelFindString()
        resetFind()
        findQuery = ""
        findMarkedOrigin = false
    }

    private func resetFind() {
        findMatches = []
        findMatchCount = 0
        findIndex = 0
        isFinding = false
        // The result the last search stopped on is a selection too; left behind, Copy and
        // Add to Chat would still act on a passage the bar no longer shows.
        if findHasFocusedMatch { pdfView.clearSelection() }
        findHasFocusedMatch = false
        pdfView.highlightedSelections = nil
    }

    private func foundMatch(_ selection: PDFSelection) {
        guard isFinding else { return }
        selection.color = Self.findMatchColor
        findMatches.append(selection)
        // The count is published in steps: a common word turns up thousands of times, and
        // a redraw of the bar for each one is the search's whole cost.
        if findMatches.count <= 20 || findMatches.count % 50 == 0 { findMatchCount = findMatches.count }
        guard !findHasFocusedMatch, let page = selection.pages.first, let document = pdfView.document,
              document.index(for: page) >= findOrigin else { return }
        focusMatch(findMatches.count - 1)
    }

    private func finishedFinding() {
        guard isFinding, pdfView.document?.isFinding == false else { return }
        isFinding = false
        findMatchCount = findMatches.count
        // Nothing from the starting page onward: wrap to the first one in the book.
        if !findHasFocusedMatch, !findMatches.isEmpty { focusMatch(0) }
        pdfView.highlightedSelections = findMatches.isEmpty ? nil : findMatches
    }

    private func focusMatch(_ index: Int) {
        guard findMatches.indices.contains(index) else { return }
        let selection = findMatches[index]
        // The result you are on is inked apart from the rest; among a page of yellow
        // nothing else says which of them "9 of 130" is.
        if findMatches.indices.contains(findIndex) { findMatches[findIndex].color = Self.findMatchColor }
        selection.color = Self.findCurrentMatchColor
        // The count is published in steps while a search runs; it must never trail the
        // result being shown, or the bar reads "21 of 20".
        if findMatchCount <= index { findMatchCount = findMatches.count }
        findIndex = index
        if !isFinding { pdfView.highlightedSelections = findMatches }
        pdfView.setCurrentSelection(selection, animate: true)
        findHasFocusedMatch = true
        // A "go" to where the view already is files that place in the history without
        // moving. Once per run of results: Back then returns to where the stepping began,
        // however many queries and results came after.
        if !findMarkedOrigin, let here = pdfView.currentDestination {
            findMarkedOrigin = true
            pdfView.go(to: here)
        }
        if let page = selection.pages.first {
            scrollQuietly(to: selection.bounds(for: page), on: page, centered: true)
        }
    }

    // MARK: - Navigation

    func go(toPage index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY)))
        currentPage = index
    }

    func go(to node: PDFOutlineNode) {
        guard let index = node.page, let page = pdfView.document?.page(at: index) else { return }
        let top = node.point ?? CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY)
        pdfView.go(to: PDFDestination(page: page, at: top))
        currentPage = index
    }

    func go(to highlight: PDFHighlight) {
        guard let page = pdfView.document?.page(at: highlight.page),
              let first = highlight.rects.first else { return }
        pdfView.go(to: first.cgRect.insetBy(dx: 0, dy: -80), on: page)
        currentPage = highlight.page
    }

    func node(withID id: UUID) -> PDFOutlineNode? {
        flattenedOutline.first { $0.id == id }
    }

    // MARK: - Contents rail

    /// The rows the contents rail draws: the tree flattened to what is currently open,
    /// each with its depth so the row can indent itself.
    struct OutlineRow: Identifiable {
        let node: PDFOutlineNode
        let depth: Int
        var id: UUID { node.id }
    }

    var outlineRows: [OutlineRow] {
        var rows: [OutlineRow] = []
        func walk(_ nodes: [PDFOutlineNode], depth: Int) {
            for node in nodes {
                rows.append(OutlineRow(node: node, depth: depth))
                guard expandedEntries.contains(node.id) else { continue }
                walk(node.children, depth: depth + 1)
            }
        }
        walk(outline, depth: 0)
        return rows
    }

    func toggleEntry(_ id: UUID) {
        if expandedEntries.contains(id) {
            // Closing a chapter closes what it holds, so reopening it starts clean.
            expandedEntries.subtract(descendants(of: id))
            expandedEntries.remove(id)
        } else {
            expandedEntries.insert(id)
        }
    }

    /// Opens the chain down to an entry, so navigating to a section reveals it in the rail
    /// rather than leaving it hidden inside a closed chapter.
    func revealEntry(_ id: UUID) {
        var walker = outlineParents[id]
        while let current = walker {
            expandedEntries.insert(current)
            walker = outlineParents[current]
        }
    }

    private func descendants(of id: UUID) -> Set<UUID> {
        guard let node = node(withID: id) else { return [] }
        return Set(node.flattened.map(\.id)).subtracting([id])
    }

    /// The deepest entry whose page you have already reached — what the contents list
    /// keeps selected as you scroll, so the sidebar always answers "where am I".
    var currentSectionID: UUID? {
        flattenedOutline.last { ($0.page ?? .max) <= currentPage }?.id
    }

    // MARK: - Thumbnails

    /// Rendered on demand and kept, so scrolling the strip back up is free. Drawn on the
    /// main actor with the same document the view is using: PDFKit page rendering is not
    /// safe to run beside the renderer from another thread.
    func thumbnail(forPage index: Int, height: CGFloat) -> NSImage? {
        if let cached = thumbnails[index] { return cached }
        guard let page = pdfView.document?.page(at: index) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let scale = height / max(bounds.height, 1)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: height), for: .cropBox)
        thumbnails[index] = image
        return image
    }

    // MARK: - Highlights

    /// Marks the current selection. One `PDFHighlight` per page the selection touches,
    /// carrying one rect per typeset line — a selection that wraps mid-line then paints
    /// the words it covers, not the whole column.
    func highlightSelection(color: PDFHighlightColor = .yellow) {
        guard let selection = pdfView.currentSelection, let document = pdfView.document else { return }
        var rects: [Int: [CGRect]] = [:]
        var lines: [Int: [String]] = [:]
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let index = document.index(for: page)
            guard index != NSNotFound else { continue }
            let bounds = line.bounds(for: page)
            guard bounds.width > 1, bounds.height > 1 else { continue }
            rects[index, default: []].append(bounds)
            if let string = line.string { lines[index, default: []].append(string) }
        }
        guard !rects.isEmpty else { return }
        for index in rects.keys.sorted() {
            let text = PDFSelectionText.unwrapped((lines[index] ?? []).joined(separator: "\n"))
            let highlight = PDFHighlight(
                page: index,
                rects: (rects[index] ?? []).map(PDFHighlight.Rect.init),
                text: text,
                color: color
            )
            highlights.append(highlight)
            annotate(highlight)
        }
        sortHighlights()
        persist()
        // Clearing the selection is what makes the mark visible: a live selection sits on
        // top of the annotation it just created.
        pdfView.clearSelection()
    }

    func remove(_ id: UUID) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        let highlight = highlights.remove(at: index)
        editGeneration += 1
        if savedMarks.contains(highlight.placement) {
            removedFromDocument.insert(highlight.placement)
            recolouredInDocument[highlight.placement] = nil
        }
        if let page = pdfView.document?.page(at: highlight.page) {
            for annotation in annotations(for: highlight, on: page) {
                page.removeAnnotation(annotation)
            }
        }
        persist()
    }

    /// Re-inks an existing mark: the annotations on the page are recolored in place, so a
    /// second thought about yellow doesn't mean removing and re-selecting the passage.
    func recolor(_ id: UUID, to color: PDFHighlightColor) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        highlights[index].color = color
        editGeneration += 1
        if savedMarks.contains(highlights[index].placement) {
            recolouredInDocument[highlights[index].placement] = color
        }
        if let page = pdfView.document?.page(at: highlights[index].page) {
            for annotation in annotations(for: highlights[index], on: page) {
                annotation.color = color.annotationColor
            }
        }
        persist()
    }

    func highlight(withID id: UUID) -> PDFHighlight? {
        highlights.first { $0.id == id }
    }

    /// A mark, moved back onto its own words if they are no longer where it left them.
    ///
    /// Geometry alone is what Preview stores, and it is why a highlight in a re-typeset
    /// paper ends up over the wrong line. So the rectangles are checked against the quote
    /// the mark carries: if the words underneath still match, nothing happens — the common
    /// case, and it costs one text extraction. If they don't, the quote is searched for,
    /// nearest pages first, and the mark takes the rectangles of whatever it finds.
    ///
    /// A quote that can't be found leaves the mark exactly as it was. Losing the passage is
    /// worse than showing it where it used to be, and the sidebar still quotes it.
    /// How many marks may go looking for their words when a document opens. A search reads
    /// up to 21 pages of text; the marks past the budget keep their rectangles and are
    /// checked again the next time the document is opened.
    private static let reanchorBudget = 12

    private func reanchored(_ mark: PDFHighlight, in document: PDFDocument)
        -> (mark: PDFHighlight, searched: Bool) {
        let quote = PDFSelectionText.squashed(mark.text)
        guard !quote.isEmpty else { return (mark, false) }
        if let page = document.page(at: mark.page), covers(quote, on: page, rects: mark.rects) {
            return (mark, false)
        }
        guard let found = search(quote: mark.text, from: mark.page, in: document) else {
            return (mark, true)
        }
        var moved = mark
        moved.page = found.page
        moved.rects = found.rects
        return (moved, true)
    }

    /// Whether the words under a mark's rectangles are still the words it quotes.
    ///
    /// Containment either way, because extraction at a rectangle's edge picks up a character
    /// more or less than the selection did — but with a floor. Any substring counted as a
    /// match before, so a rectangle left covering the single word "alpha" vouched for the
    /// whole of "alpha beta gamma" and the search that would have recovered the rest never
    /// ran. Four fifths keeps the edge cases and rejects a stale fragment.
    private func covers(_ quote: String, on page: PDFPage, rects: [PDFHighlight.Rect]) -> Bool {
        let under = rects.compactMap { page.selection(for: $0.cgRect)?.string }.joined(separator: " ")
        let found = PDFSelectionText.squashed(under)
        guard !found.isEmpty else { return false }
        guard found.contains(quote) || quote.contains(found) else { return false }
        return Double(min(found.count, quote.count)) >= 0.8 * Double(max(found.count, quote.count))
    }

    /// The mark's quote, looked for on its own page first and then outwards — a document
    /// re-exported from the same source shifts text by a page or two, it doesn't scatter it.
    ///
    /// The search is `PDFSelectionText.locate`, not `findString`: PDF text breaks lines and
    /// hyphenates words wherever the typesetter chose, and a literal search matches across
    /// neither. Locating the squashed quote also recovers the *whole* passage rather than
    /// the fragment that happened to fit on one line.
    private func search(quote: String, from page: Int, in document: PDFDocument)
        -> (page: Int, rects: [PDFHighlight.Rect])? {
        for index in pagesOutward(from: page, count: document.pageCount, reach: 10) {
            guard let candidate = document.page(at: index), let text = candidate.string,
                  let range = PDFSelectionText.locate(quote, in: text),
                  let selection = document.selection(
                      from: candidate, atCharacterIndex: range.location,
                      to: candidate, atCharacterIndex: range.location + range.length - 1)
            else { continue }
            var rects: [PDFHighlight.Rect] = []
            for line in selection.selectionsByLine() {
                guard let linePage = line.pages.first,
                      document.index(for: linePage) == index else { continue }
                let bounds = line.bounds(for: linePage)
                guard bounds.width > 1, bounds.height > 1 else { continue }
                rects.append(PDFHighlight.Rect(bounds))
            }
            guard !rects.isEmpty else { continue }
            return (index, rects)
        }
        return nil
    }

    /// Page indices spiralling out from where the mark used to be: n, n+1, n-1, n+2 …
    private func pagesOutward(from page: Int, count: Int, reach: Int) -> [Int] {
        var order: [Int] = []
        for distance in 0...reach {
            for index in distance == 0 ? [page] : [page + distance, page - distance]
            where index >= 0 && index < count {
                order.append(index)
            }
        }
        return order
    }

    /// A mark's own annotations on a page.
    ///
    /// By id when termio wrote them, and only otherwise by where they sit — a mark made in
    /// another app carries no id. Bounds matching is deliberately the fallback and is
    /// limited to highlights: a link or a stamp can share a passage's bounds, and removing a
    /// mark used to take those with it.
    private func annotations(for highlight: PDFHighlight, on page: PDFPage) -> [PDFAnnotation] {
        let own = page.annotations.filter {
            $0.type == "Highlight" && $0.userName == highlight.id.uuidString
        }
        guard own.isEmpty else { return own }
        return PDFHighlightStore.highlights(on: page, covering: highlight.placement)
    }

    private func annotate(_ highlight: PDFHighlight) {
        guard let page = pdfView.document?.page(at: highlight.page) else { return }
        // A mark saved into the document itself is already on the page; drawing the sidecar's
        // copy on top of it would double the ink and leave two annotations to remove.
        guard !page.annotations.contains(where: { $0.userName == highlight.id.uuidString }) else { return }
        for rect in highlight.rects {
            let annotation = PDFAnnotation(bounds: rect.cgRect, forType: .highlight, withProperties: nil)
            annotation.color = highlight.ink.annotationColor
            // The mark's own id, so removal finds every rect of this highlight — and only
            // termio's marks, never an annotation the document shipped with.
            annotation.userName = highlight.id.uuidString
            page.addAnnotation(annotation)
        }
    }

    private func sortHighlights() {
        // Document order: by page, then down the page (PDF y grows upward).
        highlights.sort {
            $0.page != $1.page ? $0.page < $1.page
                : ($0.rects.first?.y ?? 0) > ($1.rects.first?.y ?? 0)
        }
    }

    /// Only the unsaved layer goes to the sidecar: a mark that is already an annotation in
    /// the book is the book's, and writing it down twice is how two sources of truth start.
    /// The sidecar holds everything the book doesn't: marks not written into it, marks it
    /// carries that were removed, and colours it carries that were changed. A mark already
    /// in the file is the file's, and writing it down twice is how two sources of truth
    /// start.
    private func persist() {
        guard let markStore, let markIdentity else { return }
        let unsaved = highlights.filter { !savedMarks.contains($0.placement) }
        let recoloured = recolouredInDocument.map {
            PDFHighlightStore.RecolouredMark(placement: $0.key, color: $0.value)
        }
        PDFHighlightStore.save(unsaved, to: markStore, identity: markIdentity,
                               removed: Array(removedFromDocument), recoloured: recoloured)
    }

    // MARK: - Writing marks into the book

    /// Whether saving would change the file: a mark termio is holding that the book does
    /// not have, or a saved mark removed or re-inked on screen.
    var hasUnsavedHighlights: Bool { !edits.isEmpty }

    /// What a save would do to the book: the marks it doesn't have, the ones it has that
    /// the reader removed, and the ones whose colour changed.
    private var edits: PDFHighlightStore.Edits {
        PDFHighlightStore.Edits(
            added: highlights.filter { !savedMarks.contains($0.placement) },
            removed: Array(removedFromDocument),
            recoloured: highlights.filter { recolouredInDocument[$0.placement] != nil })
    }

    @Published private(set) var savingHighlights = false

    /// Writes the marks into the PDF as real annotations, so Preview, Books and the next
    /// reader see them too.
    ///
    /// This rewrites the file, which is why it is a deliberate verb rather than what every
    /// highlight does: the sidecar is the default precisely so marking up a paper checked
    /// into a repo leaves the repo clean. The work runs on a copy of the document opened on
    /// a background thread — PDFKit cannot be driven from two threads at once, and the one
    /// on screen belongs to the view.
    func saveHighlightsIntoDocument() {
        guard !savingHighlights else { return }
        let edits = self.edits
        guard !edits.isEmpty else { return }
        savingHighlights = true
        let url = self.url
        let generation = editGeneration
        Task.detached(priority: .userInitiated) {
            let result = PDFHighlightStore.apply(edits, to: url)
            await MainActor.run { [weak self] in
                self?.finishSaving(edits, result: result, generation: generation)
            }
        }
    }

    /// Books the outcome of a save against what the reader has done since it started.
    ///
    /// Only the edits that actually reached the file are retired, and only if nothing was
    /// edited while the write was in flight — otherwise a mark removed mid-save would come
    /// back as "already saved" and the removal would be lost. Marks the file refused (a page
    /// that no longer exists) stay in the sidecar rather than being reported as written.
    private func finishSaving(_ edits: PDFHighlightStore.Edits,
                              result: PDFHighlightStore.SaveResult,
                              generation: Int) {
        savingHighlights = false
        guard result.written else { return }
        let refused = Set(result.unapplied.map(\.placement))
        if generation == editGeneration {
            savedMarks.formUnion(edits.added.map(\.placement).filter { !refused.contains($0) })
            savedMarks.subtract(edits.removed)
            removedFromDocument.subtract(edits.removed)
            for mark in edits.recoloured where !refused.contains(mark.placement) {
                recolouredInDocument[mark.placement] = nil
            }
        }
        // The write changed the file's bytes: its identifier, and — for a document outside a
        // repo — the key its sidecar is filed under, both move with it.
        markIdentity = PDFHighlightStore.Identity.of(url, pageCount: pageCount)
        if case .support = markStore { markStore = PDFHighlightStore.store(for: url) }
        persist()
    }

    // MARK: - Context menu

    private func wireMenu(addToChat: ((String?) -> Void)?, canAddToChat: (() -> Bool)?) {
        pdfView.fileURL = url
        pdfView.onGoBack = { [weak self] in self?.goBack() }
        pdfView.onGoForward = { [weak self] in self?.goForward() }
        pdfView.onFirstLayout = { [weak self] in self?.restorePosition() }
        pdfView.onLeaveWindow = { [weak self] in self?.rememberPosition() }
        pdfView.addToChat = addToChat
        pdfView.canAddToChat = canAddToChat
        pdfView.selectionText = { [weak self] in
            guard let text = self?.pdfView.currentSelection?.string, !text.isEmpty else { return nil }
            return PDFSelectionText.unwrapped(text)
        }
        pdfView.markedHighlight = { [weak self] point in
            guard let self, let page = pdfView.page(for: point, nearest: false) else { return nil }
            let onPage = pdfView.convert(point, to: page)
            guard let annotation = page.annotation(at: onPage),
                  let name = annotation.userName, let id = UUID(uuidString: name),
                  highlight(withID: id) != nil
            else { return nil }
            return id
        }
        pdfView.onHighlight = { [weak self] in self?.highlightSelection() }
        pdfView.onPickColor = { [weak self] color, marked in
            guard let self else { return }
            if let marked {
                recolor(marked, to: color)
            } else {
                highlightSelection(color: color)
            }
        }
        pdfView.canSaveHighlights = { [weak self] in self?.hasUnsavedHighlights ?? false }
        pdfView.onSaveHighlights = { [weak self] in self?.saveHighlightsIntoDocument() }
        pdfView.onRemoveHighlight = { [weak self] id in self?.remove(id) }
        pdfView.highlightText = { [weak self] id in self?.highlight(withID: id)?.text }
    }
}

/// A `PDFView` whose right-click menu is termio's, not PDFKit's — the same move the
/// Markdown reader makes for WebKit's. PDFKit's own menu is a viewer's (auto-size, page
/// display modes); a document open beside an agent wants the reader's verbs instead:
/// copy, mark, and hand the passage to the agent.
final class ContextMenuPDFView: PDFView {
    /// The document on disk, for Reveal in Finder.
    var fileURL: URL?
    /// The selection as prose, or `nil` when nothing is selected.
    var selectionText: (() -> String?)?
    /// The termio highlight under a point in view space, if the click landed on one.
    var markedHighlight: ((CGPoint) -> UUID?)?
    var highlightText: ((UUID) -> String?)?
    var onHighlight: (() -> Void)?
    var onRemoveHighlight: ((UUID) -> Void)?
    /// "Add to Chat": a passage goes over as the snippet, `nil` means the owner should
    /// insert the document's path instead. The gate is read when the menu opens, so a
    /// plain-shell session simply shows no item.
    var addToChat: ((String?) -> Void)?
    var canAddToChat: (() -> Bool)?

    /// Whether the document has marks that aren't in the file yet, and the verb that puts
    /// them there.
    var canSaveHighlights: (() -> Bool)?
    var onSaveHighlights: (() -> Void)?
    /// Picking a marker color: for a selection it lays down a new mark, for a mark under
    /// the pointer it re-inks that one.
    var onPickColor: ((PDFHighlightColor, UUID?) -> Void)?

    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?
    /// Called once, the first time the view is laid out with a size inside a window.
    var onFirstLayout: (() -> Void)?
    var onLeaveWindow: (() -> Void)?
    private var hasLaidOut = false

    // MARK: Link preview

    private var hoveredLink: PDFAnnotation?
    private var pendingPreview: DispatchWorkItem?
    private var previewPopover: NSPopover?
    private var scrollObserver: NSObjectProtocol?
    /// Long enough that sweeping the pointer across a page of citations opens nothing.
    private static let previewDelay: TimeInterval = 0.3

    override func layout() {
        super.layout()
        guard !hasLaidOut, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        hasLaidOut = true
        // One turn later, so PDFKit has placed its pages at this size first.
        DispatchQueue.main.async { [weak self] in self?.onFirstLayout?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            dismissPreview()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
            onLeaveWindow?()
            return
        }
        // Clicks and wheel events go to PDFKit's inner views, not to this one, so a scroll
        // is the one signal that covers both "followed the link" and "moved on".
        guard scrollObserver == nil, let clip = documentView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPreview() }
        }
    }

    // No tracking area of its own: PDFKit already tracks the pointer over this view to
    // choose its cursor, and delivers the moves here. A second area doubles every move,
    // entry and exit it sees, and the cursor flickers between the arrow and the hand.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return hover(nil) }
        hover(PDFLinkPreview.link(at: convert(point, to: page), on: page))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // The popover opening beside the pointer can report an exit the pointer never made.
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { return }
        hover(nil)
    }

    private func hover(_ link: PDFAnnotation?) {
        guard link !== hoveredLink else { return }
        dismissPreview()
        hoveredLink = link
        guard let link else { return }
        let work = DispatchWorkItem { [weak self] in self?.showPreview(for: link) }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDelay, execute: work)
    }

    private func showPreview(for link: PDFAnnotation) {
        guard link === hoveredLink, window != nil, let page = link.page,
              let destination = PDFLinkPreview.destination(of: link),
              let image = PDFLinkPreview.image(
                of: destination, size: PDFLinkPreview.size(fitting: bounds.width - 48))
        else { return }
        let popover = PDFLinkPreview.popover(showing: image)
        previewPopover = popover
        // Below the link, where the eye is already heading; AppKit flips it when there is no room.
        popover.show(relativeTo: convert(link.bounds, from: page), of: self, preferredEdge: .minY)
    }

    private func dismissPreview() {
        pendingPreview?.cancel()
        pendingPreview = nil
        previewPopover?.close()
        previewPopover = nil
        hoveredLink = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        dismissPreview()
        let point = convert(event.locationInWindow, from: nil)
        let selection = selectionText?()
        let marked = selection == nil ? markedHighlight?(point) : nil
        // Right-clicking a mark acts on the mark; otherwise on the selection, and with
        // neither, on the document itself.
        let passage = selection ?? marked.flatMap { highlightText?($0) }

        let menu = NSMenu()
        // The markers lead, the way they do in Books: picking a color IS the common verb
        // here, and burying it under a "Highlight" item makes a two-step of one gesture.
        if selection != nil || marked != nil {
            let swatches = NSMenuItem()
            // A view item draws itself; the empty title keeps it out of menu search and
            // out of the accessibility reading of the menu's verbs.
            swatches.title = ""
            let target = marked
            swatches.view = PDFHighlightSwatchRow { [weak self, weak menu] color in
                menu?.cancelTracking()
                self?.onPickColor?(color, target)
            }
            menu.addItem(swatches)
            menu.addItem(.separator())
        }
        if let marked {
            menu.addPlainItem(localized("Remove Highlight"), target: self,
                              action: #selector(removeHighlightAction(_:)),
                              representedObject: marked.uuidString)
        }
        if let passage {
            menu.addPlainItem(localized("Copy"), target: self, action: #selector(copyPassage(_:)),
                              representedObject: passage)
        }
        if canAddToChat?() == true {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addPlainItem(localized("Add to Chat"), target: self,
                              action: #selector(addToChatAction(_:)), representedObject: passage)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        if canSaveHighlights?() == true {
            menu.addPlainItem(localized("Save Highlights into PDF"), target: self,
                              action: #selector(saveHighlightsAction))
        }
        if fileURL != nil {
            menu.addPlainItem(localized("Reveal in Finder"), target: self, action: #selector(revealInFinder))
        }
        menu.addPlainItem(localized("Close"), target: self, action: #selector(closeOverlay))
        return menu
    }

    @objc private func copyPassage(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⇧⌘H marks the selection in the default color without a trip through the menu — the
    /// shortcut a reader reaches for after the second highlight. Handled here rather than in
    /// the main menu: the key belongs to the document that has focus, not to the app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "h",
           currentSelection?.string?.isEmpty == false {
            onHighlight?()
            return true
        }
        // ⌘[ and ⌘]: back and forward, the browser's keys for the same idea. Only while the
        // document has the keyboard — key equivalents are offered to every view in the
        // window, and these two must not be taken from a terminal beside the reader.
        if modifiers == [.command], holdsKeyboard, let key = event.charactersIgnoringModifiers {
            if key == "[", canGoBack {
                onGoBack?()
                return true
            }
            if key == "]", canGoForward {
                onGoForward?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private var holdsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    @objc private func removeHighlightAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        onRemoveHighlight?(id)
    }

    /// A passage goes over as the snippet; nothing selected sends `nil`, and the owner
    /// types the document's path instead.
    @objc private func addToChatAction(_ sender: NSMenuItem) {
        addToChat?(sender.representedObject as? String)
    }

    @objc private func saveHighlightsAction() { onSaveHighlights?() }

    @objc private func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func closeOverlay() {
        NotificationCenter.default.post(name: .termioCloseContentOverlay, object: nil)
    }
}


/// The marker row at the top of the reader's context menu — Books' palette, drawn as a
/// menu item's own view.
///
/// Hand-drawn AppKit rather than a hosted SwiftUI view: a menu item's view lives inside
/// the menu's own tracking loop, where hosted SwiftUI gets no reliable hover or click, and
/// five discs are less code than fighting that.
final class PDFHighlightSwatchRow: NSView {
    private let pick: (PDFHighlightColor) -> Void
    private let colors = PDFHighlightColor.allCases
    private var hovered: Int?

    private static let diameter: CGFloat = 19
    private static let gap: CGFloat = 11
    private static let inset = NSEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)

    init(pick: @escaping (PDFHighlightColor) -> Void) {
        self.pick = pick
        let width = Self.inset.left + Self.inset.right
            + CGFloat(colors.count) * Self.diameter + CGFloat(colors.count - 1) * Self.gap
        super.init(frame: NSRect(x: 0, y: 0, width: width,
                                 height: Self.inset.top + Self.diameter + Self.inset.bottom))
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func rect(at index: Int) -> NSRect {
        NSRect(x: Self.inset.left + CGFloat(index) * (Self.diameter + Self.gap),
               y: Self.inset.bottom, width: Self.diameter, height: Self.diameter)
    }

    private func index(at point: NSPoint) -> Int? {
        colors.indices.first { rect(at: $0).insetBy(dx: -4, dy: -4).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, color) in colors.enumerated() {
            let disc = NSBezierPath(ovalIn: rect(at: index))
            color.annotationColor.setFill()
            disc.fill()
            guard hovered == index else { continue }
            // The ring is the app's ink, not a system accent: the swatch is already the
            // color, so the pointer cue must not add a second one.
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            let ring = NSBezierPath(ovalIn: rect(at: index).insetBy(dx: -2.5, dy: -2.5))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = index(at: point)
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        pick(colors[index])
    }
}
