import AppKit
import PDFKit
import SwiftUI

/// PDF reader with a Preview.app-style highlight toolbar and find-in-document field.
struct PDFReaderView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container {
        let pdfView = PDFReaderPDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.backgroundColor = .clear
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.contextMenuProvider = { [weak coordinator = context.coordinator] point in
            coordinator?.contextMenu(at: point, in: pdfView)
        }

        context.coordinator.attach(pdfView: pdfView, url: url)

        let toolbar = NSHostingView(rootView: makeToolbar(coordinator: context.coordinator))
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let container = Container(toolbar: toolbar, pdfView: pdfView)
        container.addSubview(toolbar)
        container.addSubview(pdfView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ view: Container, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.attach(pdfView: view.pdfView, url: url)
        // The hosted SwiftUI toolbar caches its @State (query, armed) across reconciliations,
        // so refresh the root view whenever the URL changes to reset those to a clean start.
        view.toolbar.rootView = makeToolbar(coordinator: context.coordinator)
    }

    private func makeToolbar(coordinator: Coordinator) -> PDFReaderToolbar {
        PDFReaderToolbar(
            title: url.lastPathComponent,
            hasSelection: { [weak coordinator] in coordinator?.hasSelection ?? false },
            armToggle: { [weak coordinator] subtype, color in
                coordinator?.setArmed(subtype: subtype, color: color)
            },
            disarm: { [weak coordinator] in coordinator?.setArmed(subtype: nil, color: nil) },
            applyOnce: { [weak coordinator] subtype, color in
                coordinator?.applyOnce(subtype: subtype, color: color)
            },
            search: { [weak coordinator] in coordinator?.search(query: $0) },
            gotoNext: { [weak coordinator] in coordinator?.gotoMatch(offset: 1) },
            gotoPrevious: { [weak coordinator] in coordinator?.gotoMatch(offset: -1) },
            matchCount: { [weak coordinator] in coordinator?.matchCount ?? 0 },
            currentMatchIndex: { [weak coordinator] in coordinator?.currentMatchIndex ?? 0 }
        )
    }

    final class Container: NSView {
        let toolbar: NSHostingView<PDFReaderToolbar>
        let pdfView: PDFReaderPDFView
        init(toolbar: NSHostingView<PDFReaderToolbar>, pdfView: PDFReaderPDFView) {
            self.toolbar = toolbar
            self.pdfView = pdfView
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
    }

    final class Coordinator: NSObject {
        weak var pdfView: PDFReaderPDFView?
        private(set) var url: URL?
        private var documentHash: String?
        private var findMatches: [PDFSelection] = []
        private var findCursor: Int = 0
        private var armedMark: (subtype: PDFAnnotationSubtype, color: NSColor)?
        private var selectionObserver: NSObjectProtocol?
        private var mouseUpMonitor: Any?
        // The last non-empty selection observed on the PDFView. Toolbar buttons can steal
        // first-responder focus and drop the live selection between the click and the coordinator
        // callback, so the mark actions fall back to this cache when the live one is empty.
        private var lastSelection: PDFSelection?
        // Set while `setCurrentSelection` navigates search hits, so the armed listener doesn't
        // annotate a search jump.
        private var suppressAutoMark = false

        var matchCount: Int { findMatches.count }
        var currentMatchIndex: Int { findMatches.isEmpty ? 0 : findCursor + 1 }
        var hasSelection: Bool {
            if let sel = pdfView?.currentSelection, !sel.pages.isEmpty { return true }
            return lastSelection.map { !$0.pages.isEmpty } ?? false
        }

        deinit {
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        }

        func attach(pdfView: PDFReaderPDFView, url: URL) {
            self.pdfView = pdfView
            self.url = url
            documentHash = nil
            findMatches.removeAll()
            findCursor = 0
            armedMark = nil
            lastSelection = nil

            let document = PDFDocument(url: url)
            pdfView.document = document
            if let document, let hash = PDFAnnotationStore.hash(for: url) {
                documentHash = hash
                PDFAnnotationStore.load(into: document, hash: hash)
            }

            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in self?.selectionChanged() }

            if mouseUpMonitor == nil {
                // `.PDFViewSelectionChanged` fires continuously during a drag, so armed annotation
                // needs to wait for the drag to end. The local monitor fires exactly once per
                // mouse-up and never sees synthetic selections from search navigation.
                mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                    self?.mouseUp(event)
                    return event
                }
            }

            fitToWidthWhenLaidOut(pdfView: pdfView)
        }

        /// Interaction B: mark the current (or last cached) selection once.
        func applyOnce(subtype: PDFAnnotationSubtype, color: NSColor) {
            guard let pdfView, let selection = liveOrCachedSelection() else { return }
            markSelection(selection, subtype: subtype, color: color)
            pdfView.clearSelection()
            lastSelection = nil
        }

        /// Interaction A: arm (subtype+color non-nil) or disarm (both nil).
        func setArmed(subtype: PDFAnnotationSubtype?, color: NSColor?) {
            if let subtype, let color { armedMark = (subtype, color) }
            else { armedMark = nil }
        }

        func search(query: String) {
            guard let pdfView, let document = pdfView.document else { return }
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                pdfView.highlightedSelections = nil
                pdfView.clearSelection()
                findMatches.removeAll()
                findCursor = 0
                return
            }
            let matches = document.findString(trimmed, withOptions: [.caseInsensitive])
            // `highlightedSelections` requires each selection to carry an explicit color; the
            // default alpha is 0, so matches render invisible without this.
            for match in matches { match.color = .systemYellow.withAlphaComponent(0.55) }
            findMatches = matches
            findCursor = 0
            pdfView.highlightedSelections = matches
            if let first = matches.first { goto(first) }
        }

        func gotoMatch(offset: Int) {
            guard !findMatches.isEmpty else { return }
            let count = findMatches.count
            findCursor = ((findCursor + offset) % count + count) % count
            goto(findMatches[findCursor])
        }

        func contextMenu(at point: NSPoint, in pdfView: PDFReaderPDFView) -> NSMenu? {
            guard let page = pdfView.page(for: point, nearest: false) else { return nil }
            let pagePoint = pdfView.convert(point, to: page)
            guard let annotation = page.annotation(at: pagePoint),
                  annotation.userName == PDFAnnotationStore.userName else { return nil }
            let menu = NSMenu()
            let item = NSMenuItem(title: "Delete Annotation",
                                  action: #selector(deleteAnnotation), keyEquivalent: "")
            item.target = self
            item.representedObject = AnnotationRef(annotation: annotation, page: page)
            menu.addItem(item)
            return menu
        }

        @objc private func deleteAnnotation(_ sender: NSMenuItem) {
            guard let ref = sender.representedObject as? AnnotationRef else { return }
            ref.page.removeAnnotation(ref.annotation)
            persist()
        }

        private func mouseUp(_ event: NSEvent) {
            guard let pdfView, event.window === pdfView.window,
                  armedMark != nil, !suppressAutoMark else { return }
            let locationInPDFView = pdfView.convert(event.locationInWindow, from: nil)
            guard pdfView.bounds.contains(locationInPDFView) else { return }
            guard let armed = armedMark,
                  let selection = pdfView.currentSelection, !selection.pages.isEmpty else { return }
            markSelection(selection, subtype: armed.subtype, color: armed.color)
            pdfView.clearSelection()
            lastSelection = nil
        }

        private func selectionChanged() {
            guard let pdfView else { return }
            if let sel = pdfView.currentSelection, !sel.pages.isEmpty { lastSelection = sel }
        }

        private func liveOrCachedSelection() -> PDFSelection? {
            if let sel = pdfView?.currentSelection, !sel.pages.isEmpty { return sel }
            return lastSelection.flatMap { $0.pages.isEmpty ? nil : $0 }
        }

        private func markSelection(_ selection: PDFSelection, subtype: PDFAnnotationSubtype, color: NSColor) {
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let annotation = PDFAnnotation(bounds: line.bounds(for: page),
                                                   forType: subtype, withProperties: nil)
                    annotation.color = color
                    annotation.userName = PDFAnnotationStore.userName
                    page.addAnnotation(annotation)
                }
            }
            persist()
        }

        private func goto(_ selection: PDFSelection) {
            guard let pdfView else { return }
            suppressAutoMark = true
            pdfView.setCurrentSelection(selection, animate: false)
            pdfView.scrollSelectionToVisible(nil)
            DispatchQueue.main.async { [weak self] in self?.suppressAutoMark = false }
        }

        private func persist() {
            guard let document = pdfView?.document, let hash = documentHash else { return }
            do { try PDFAnnotationStore.save(document, hash: hash) }
            catch { NSLog("PDFReaderView: failed to persist annotations: \(error)") }
        }

        /// `autoScales` leaves the initial scale at 1.0 until the container has a non-zero frame,
        /// so a fresh PDF paints at native size (tiny). Retry the fit computation for a few
        /// runloop ticks until the frame settles.
        private func fitToWidthWhenLaidOut(pdfView: PDFView, attempt: Int = 0) {
            DispatchQueue.main.async { [weak pdfView] in
                guard let pdfView else { return }
                let fit = pdfView.scaleFactorForSizeToFit
                if fit > 0 {
                    pdfView.scaleFactor = fit
                    pdfView.minScaleFactor = fit * 0.25
                    pdfView.maxScaleFactor = fit * 4.0
                    return
                }
                if attempt < 8 {
                    self.fitToWidthWhenLaidOut(pdfView: pdfView, attempt: attempt + 1)
                }
            }
        }

        // NSMenuItem.representedObject must be a class, so box the pair.
        private final class AnnotationRef {
            let annotation: PDFAnnotation
            let page: PDFPage
            init(annotation: PDFAnnotation, page: PDFPage) {
                self.annotation = annotation
                self.page = page
            }
        }
    }
}

/// PDFView subclass that lets a caller supply the context menu instead of hard-replacing the
/// `menu` property, which would strip PDFKit's own copy/lookup/selection actions.
final class PDFReaderPDFView: PDFView {
    var contextMenuProvider: ((NSPoint) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let custom = contextMenuProvider?(point) { return custom }
        return super.menu(for: event)
    }
}

struct PDFReaderToolbar: View {
    let title: String
    let hasSelection: () -> Bool
    let armToggle: (PDFAnnotationSubtype, NSColor) -> Void
    let disarm: () -> Void
    let applyOnce: (PDFAnnotationSubtype, NSColor) -> Void
    let search: (String) -> Void
    let gotoNext: () -> Void
    let gotoPrevious: () -> Void
    let matchCount: () -> Int
    let currentMatchIndex: () -> Int

    @State private var currentColor: HighlightColor = .yellow
    @State private var currentSubtype: MarkSubtype = .highlight
    @State private var armed: Bool = false
    @State private var showPopover: Bool = false
    @State private var query: String = ""
    @State private var lastQuery: String = ""
    @State private var lastMatchCount: Int = 0
    @State private var lastMatchIndex: Int = 0

    var body: some View {
        HStack(spacing: 10) {
            titleLabel
            Spacer(minLength: 8)
            markSplitButton
            searchField
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    private var titleLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var markSplitButton: some View {
        HStack(spacing: 0) {
            Button(action: pencilTapped) {
                Image(systemName: currentSubtype.iconName)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(currentColor.swatch, .primary)
                    .font(.system(size: 15))
                    .frame(width: 26, height: 22)
                    .background(
                        armed ? currentColor.swatch.opacity(0.28) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            .buttonStyle(.borderless)
            .help(armed ? "Cancel Highlighting" : "Highlight")

            Button { showPopover.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 22)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                popoverBody
                    .padding(.vertical, 6)
                    .frame(width: 180)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// Pencil click: mark the current selection once (B) if present, otherwise toggle armed (A).
    private func pencilTapped() {
        let color = currentColor.nsColor
        let subtype = currentSubtype.pdfSubtype
        if hasSelection() {
            applyOnce(subtype, color)
        } else if armed {
            armed = false
            disarm()
        } else {
            armed = true
            armToggle(subtype, color)
        }
    }

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(HighlightColor.allCases) { color in
                popoverRow(
                    selected: color == currentColor && currentSubtype == .highlight,
                    leading: Circle().fill(color.swatch).frame(width: 12, height: 12)
                ) {
                    Text(color.name)
                } onTap: {
                    currentColor = color
                    currentSubtype = .highlight
                    pickedStyle(subtype: .highlight, color: color.nsColor)
                }
            }
            Divider().padding(.vertical, 4)
            popoverRow(
                selected: currentSubtype == .underline,
                leading: Text("U").font(.system(size: 12, weight: .semibold)).underline().frame(width: 14)
            ) {
                Text("Underline")
            } onTap: {
                currentSubtype = .underline
                pickedStyle(subtype: .underline, color: currentColor.nsColor)
            }
            popoverRow(
                selected: currentSubtype == .strikethrough,
                leading: Text("S").font(.system(size: 12, weight: .semibold)).strikethrough().frame(width: 14)
            ) {
                Text("Strikethrough")
            } onTap: {
                currentSubtype = .strikethrough
                pickedStyle(subtype: .strikeOut, color: currentColor.nsColor)
            }
        }
    }

    private func pickedStyle(subtype: PDFAnnotationSubtype, color: NSColor) {
        if hasSelection() {
            applyOnce(subtype, color)
            if armed { armed = false; disarm() }
        } else {
            armed = true
            armToggle(subtype, color)
        }
        showPopover = false
    }

    @ViewBuilder
    private func popoverRow<Leading: View, Label: View>(
        selected: Bool,
        leading: Leading,
        @ViewBuilder label: () -> Label,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 12)
                .opacity(selected ? 1 : 0)
            leading
            label()
                .font(.system(size: 12.5))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(runSearch)
                .onChange(of: query) { _, newValue in
                    if newValue.isEmpty { clearSearch() }
                }
                .frame(minWidth: 120, maxWidth: 220)
            if !query.isEmpty {
                Text(lastMatchCount == 0 ? "no matches" : "\(lastMatchIndex) of \(lastMatchCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button { gotoPrevious(); lastMatchIndex = currentMatchIndex() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(lastMatchCount == 0)
                Button { gotoNext(); lastMatchIndex = currentMatchIndex() } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(lastMatchCount == 0)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// Return re-runs a fresh query, or advances to the next hit when the query is unchanged —
    /// matches Preview.app and Safari.
    private func runSearch() {
        if query == lastQuery, lastMatchCount > 0 {
            gotoNext()
            lastMatchIndex = currentMatchIndex()
        } else {
            search(query)
            lastQuery = query
            lastMatchCount = matchCount()
            lastMatchIndex = currentMatchIndex()
        }
    }

    private func clearSearch() {
        search("")
        lastQuery = ""
        lastMatchCount = 0
        lastMatchIndex = 0
    }
}

private enum MarkSubtype: Hashable {
    case highlight, underline, strikethrough

    var pdfSubtype: PDFAnnotationSubtype {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikethrough: return .strikeOut
        }
    }

    var iconName: String {
        switch self {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        }
    }
}

enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var nsColor: NSColor {
        let base: NSColor
        switch self {
        case .yellow: base = .systemYellow
        case .green:  base = .systemGreen
        case .blue:   base = .systemBlue
        case .pink:   base = .systemPink
        case .purple: base = .systemPurple
        }
        return base.withAlphaComponent(0.35)
    }

    var swatch: Color {
        switch self {
        case .yellow: .yellow
        case .green:  .green
        case .blue:   .blue
        case .pink:   .pink
        case .purple: .purple
        }
    }
}
