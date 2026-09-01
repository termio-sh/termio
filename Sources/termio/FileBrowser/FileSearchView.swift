import AppKit
import SwiftUI
import TermioShared

/// One grep hit: a line of a file that contains the query, with the lines around
/// it and — the part that matters — where the query actually hit.
///
/// The spans come from the matcher that found the line — always the daemon's,
/// on whichever box holds the checkout. Nothing downstream re-searches the text.
/// A results row that finds its own highlights is running a second matcher
/// beside the first, and two matchers disagree in exactly the cases that look
/// like bugs: an uppercase query painting lowercase text, a line whose match sat
/// past the length cap and so lit up nothing at all.
struct ContentMatch: Sendable {
    /// Path relative to the searched root — the grouping key and header label.
    let relative: String
    let url: URL
    /// 1-based line number, as the daemon reports it.
    let line: Int
    /// The matched line, or a window of it when the line is long enough that
    /// sending the whole thing is pointless. Untrimmed — the row trims.
    let text: String
    /// Where the query hit inside `text`. Empty only against a host too old to
    /// report spans, where the row falls back to painting nothing rather than
    /// guessing.
    let spans: [Range<String.Index>]
    /// True when `text` is a window cut out of a longer line, so the row can say
    /// so rather than implying the line begins there.
    let isWindowed: Bool
    /// The lines immediately before and after, for the excerpt. Empty when the
    /// hit is at the top or bottom of its file, or from a host too old to send
    /// context.
    let before: [String]
    let after: [String]

    /// The line numbers `before` and `after` occupy, which the excerpt gutter
    /// needs and which are pure arithmetic off `line`.
    var firstLine: Int { line - before.count }

    /// A byte range measured by a host, as a range of `text`'s characters.
    /// `nil` when the bytes do not land on character boundaries — a host and a
    /// client disagreeing about where a character starts is a highlight in the
    /// wrong place, and none is better than wrong.
    static func range(_ text: String, bytes: Range<Int>) -> Range<String.Index>? {
        let utf8 = text.utf8
        guard bytes.lowerBound >= 0, bytes.upperBound <= utf8.count else { return nil }
        let start = utf8.index(utf8.startIndex, offsetBy: bytes.lowerBound)
        let end = utf8.index(utf8.startIndex, offsetBy: bytes.upperBound)
        guard let lower = start.samePosition(in: text),
              let upper = end.samePosition(in: text), lower <= upper else { return nil }
        return lower ..< upper
    }
}

/// Which machine the Search pane searches, and therefore what a hit opens. The
/// pane is one pane either way — a field, hits grouped under their file, click to
/// open — so the two roads differ only here.
enum SearchScope {
    /// This Mac: the local daemon's own `fs.search` over the Unix socket, and a
    /// hit opens the editor at its line. The provider is what makes local an
    /// ordinary device here — the pane runs no matcher of its own.
    case thisMac(DeviceFileProvider, URL)
    /// Another machine: that device's own `fs.search`, and a hit opens the
    /// read-only preview the device's file tree already uses. `root` is a path on
    /// **that** box, so it is carried as a string; the `URL`s the rows build from
    /// it are synthetic (names and icons only), exactly like `DeviceFileNode`.
    case device(DeviceFileProvider, host: String, root: String)
}

extension SearchScope {
    /// The daemon this pane asks. Local is not a special case: it is the device
    /// whose route is a Unix socket, so both roads reach one search engine and a
    /// query cannot mean two things depending on which box holds the checkout.
    var provider: DeviceFileProvider {
        switch self {
        case .thisMac(let provider, _): return provider
        case .device(let provider, _, _): return provider
        }
    }

    /// What a hit's relative path is resolved against. Real for this Mac; for a
    /// device the `URL` is synthetic, exactly as `DeviceFileNode` builds them.
    var base: URL {
        switch self {
        case .thisMac(_, let root): return root
        case .device(_, _, let root): return URL(fileURLWithPath: root, isDirectory: true)
        }
    }

    /// Which machine a failed search is logged against.
    var machine: String {
        switch self {
        case .thisMac(_, let root): return root.path
        case .device(_, let host, let root): return host + ":" + root
        }
    }

    /// Whether the checkout is on this Mac. The engine no longer asks — only the
    /// sentences do, since a failure worded for a machine across a network reads
    /// wrong on the one the window is open on.
    var isLocal: Bool {
        if case .thisMac = self { return true }
        return false
    }
}

/// The inspector's Search pane — a sibling of Files / Changes / Info on the
/// toolbar switch, searching file *contents* (VS Code's ⇧⌘F; the filename jump
/// lives in Open Quickly, ⌘⇧O). Queries run debounced through `fs.search`, on
/// whichever daemon owns the checkout — this Mac's over its socket, a device's
/// over its pipe — results group under their file with the matched substring
/// tinted accent, and clicking a hit opens the file scrolled to that line.
struct FileSearchView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    /// The root the search runs under, and the machine it lives on.
    let scope: SearchScope
    /// Leaves the pane (back to the Files tab) — Esc in an empty field.
    let onDismiss: () -> Void

    /// Total hits kept per query — past this the footer says so and the user
    /// should sharpen the query rather than scroll.
    private static let matchLimit = 400
    /// Typing pause before a grep actually runs (Warp uses 50ms for in-memory
    /// matching; a subprocess earns a slightly longer breath).
    private static let debounce: Duration = .milliseconds(250)

    @State private var query = ""
    @State private var matches: [ContentMatch] = []
    @State private var isSearching = false
    /// What the device said when it refused to search — shown in place of the
    /// no-matches state, since "nothing here" and "the search never ran" are
    /// different answers and only one of them is about the query.
    @State private var failure: String?
    /// The in-flight debounce+grep, cancelled by the next keystroke.
    @State private var searchTask: Task<Void, Never>?
    /// The in-flight download of a hit's file, for a device checkout.
    @State private var fieldFocused = false
    @State private var focusRequest = 0
    @State private var isVisible = false
    @State private var collapsedFiles: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            searchField
            resultList
        }
        .onAppear {
            isVisible = true
            claimFocus(attempt: 0)
        }
        .onChange(of: query) { scheduleSearch() }
        .onDisappear {
            isVisible = false
            searchTask?.cancel()
        }
    }

    /// Whether a hit is a file this Mac can hand to the Finder. A device's is
    /// not: the row's URL names a path over there, so a drag would produce a
    /// promise nothing can keep.
    private var allowsDrag: Bool {
        if case .thisMac = scope { return true }
        return false
    }

    // MARK: - Pieces

    private var searchField: some View {
        VStack(spacing: 0) {
            // The magnifier and clear button are drawn here, not by AppKit: the field
            // is a bare `NSTextField` (see `NativeSearchField`) because a bezel-less
            // `NSSearchField` misplaces its built-in icons.
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                NativeSearchField(
                    text: $query,
                    isFocused: $fieldFocused,
                    focusRequest: focusRequest,
                    placeholder: placeholder,
                    onSubmit: {
                        if let first = matches.first { open(first) }
                    },
                    // Esc clears a live query first; a second Esc (empty field)
                    // leaves the pane.
                    onExit: {
                        if query.isEmpty {
                            onDismiss()
                        } else {
                            query = ""
                        }
                    }
                )
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localized("Clear"))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background { fieldChrome }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, trimmedQuery.isEmpty ? 7 : 4)

            if !trimmedQuery.isEmpty {
                HStack(spacing: 5) {
                    if isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(isSearching ? localized("Searching…") : summary(fileCount: groups.count))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
            }
        }
    }

    /// What the field invites: the project locally, the machine by name for a
    /// checkout on a device — the same "say which box" rule the empty states use.
    private var placeholder: String {
        switch scope {
        case .thisMac: return localized("Search Project")
        case .device(_, let host, _): return localized("Search \(host)")
        }
    }

    /// The field's own chrome, replacing the `NSSearchField` bezel (stripped in
    /// `makeNSView`): a Liquid Glass capsule on macOS 26 — same material recipe as
    /// the toolbar's `InspectorTabsToolbar` track — and a flat capsule fill below.
    @ViewBuilder
    private var fieldChrome: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(Color.white.opacity(0.12)), in: .capsule)
        } else {
            Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
        }
    }

    /// One flat row of the results list, with a globally unique, stable id.
    ///
    /// Flat rather than nested `ForEach`es: a per-file loop nesting a per-hit
    /// loop keyed by bare line number mis-diffed inside `LazyVStack` when typing
    /// replaced the whole match set — line-number ids collide across files, so
    /// SwiftUI stitched rows from different files under one header. Ids that
    /// carry their file make the diff unambiguous.
    private enum ResultRow: Identifiable {
        case header(relative: String, url: URL, count: Int, isExpanded: Bool)
        case excerpt(relative: String, url: URL, excerpt: SearchExcerpt)
        /// The break between two runs of lines from the same file.
        case gap(id: String)

        var id: String {
            switch self {
            case .header(let relative, _, _, _): return "h\u{1f}" + relative
            case .excerpt(let relative, _, let excerpt):
                return "e\u{1f}\(relative)\u{1f}\(excerpt.firstLine)"
            case .gap(let id): return id
            }
        }
    }

    private var rows: [ResultRow] {
        var out: [ResultRow] = []
        for group in groups {
            let isExpanded = !collapsedFiles.contains(group.relative)
            out.append(.header(relative: group.relative, url: group.url,
                               count: group.matchCount, isExpanded: isExpanded))
            guard isExpanded else { continue }
            let excerpts = SearchExcerpt.compose(group.items)
            for (index, excerpt) in excerpts.enumerated() {
                if index > 0 {
                    out.append(.gap(id: "g\u{1f}\(group.relative)\u{1f}\(excerpt.firstLine)"))
                }
                out.append(.excerpt(relative: group.relative, url: group.url, excerpt: excerpt))
            }
        }
        return out
    }

    @ViewBuilder
    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(rows) { row in
                    switch row {
                    case .header(let relative, let url, let count, let isExpanded):
                        FileHeaderRow(
                            url: url,
                            relative: relative,
                            count: count,
                            isExpanded: isExpanded,
                            chrome: chrome,
                            toggleExpanded: {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    if isExpanded {
                                        collapsedFiles.insert(relative)
                                    } else {
                                        collapsedFiles.remove(relative)
                                    }
                                }
                            },
                            allowsDrag: allowsDrag,
                            open: { openFirstHit(inFile: relative) }
                        )
                    case .excerpt(_, let url, let excerpt):
                        ExcerptView(
                            excerpt: excerpt,
                            url: url,
                            settings: settings,
                            colorScheme: colorScheme,
                            chrome: chrome,
                            open: { line in openLine(line, inFile: url) }
                        )
                    case .gap:
                        ExcerptGap()
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if !trimmedQuery.isEmpty, matches.isEmpty, !isSearching {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundStyle(.quaternary)
                    Text(failure == nil ? localized("No Matches") : localized("Can’t Search"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    // The device's own words when it refused: it named the cause,
                    // and "no matches" would be a different — and wrong — answer.
                    Text(failure ?? localized("Try another search term."))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    private func summary(fileCount: Int) -> String {
        let capped = matches.count >= Self.matchLimit
        return localized("\(matchCount)\(capped ? "+" : "") matches in \(fileCount) files")
    }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Hits folded under their file, in grep's own order (file-grouped already —
    /// consecutive runs are enough, no re-sort).
    private var groups: [(relative: String, url: URL, items: [ContentMatch], matchCount: Int)] {
        var out: [(relative: String, url: URL, items: [ContentMatch], matchCount: Int)] = []
        for match in matches {
            // The badge counts *matches*, not rows: one line holding the query
            // three times is three hits, and a badge saying "1" beside three
            // painted spans is the pane disagreeing with itself.
            let hits = max(match.spans.count, 1)
            if out.last?.relative == match.relative {
                out[out.count - 1].items.append(match)
                out[out.count - 1].matchCount += hits
            } else {
                out.append((match.relative, match.url, [match], hits))
            }
        }
        return out
    }

    /// Total hits across every file, for the summary line.
    private var matchCount: Int {
        matches.reduce(0) { $0 + max($1.spans.count, 1) }
    }

    // MARK: - Search

    /// Debounce + cancel-on-keystroke (Warp's abort pattern): each edit kills
    /// the in-flight task, and the cancellation reaches all the way down — the
    /// abandoned call cancels its `fs.search` by request id, and the daemon drops
    /// the walk — so a stale search stops consuming the box instead of racing the
    /// fresh one. Deliberately NOT `Task.detached`: a detached task sits outside
    /// this task tree, which is exactly what would strand the search beyond
    /// cancellation's reach.
    private func scheduleSearch() {
        searchTask?.cancel()
        // Cleared here rather than inside the task: the message belongs to the
        // query that produced it, and the debounce would otherwise leave it
        // sitting under a quarter second of a different one.
        failure = nil
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            matches = []
            isSearching = false
            return
        }
        let limit = Self.matchLimit
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = await find(trimmed, limit: limit)
            guard !Task.isCancelled else { return }
            matches = found
            isSearching = false
        }
    }

    /// Runs one query against the daemon that owns the root — the local one over
    /// a Unix socket, a device's over its pipe. One engine answers both, so the
    /// same query in the same pane cannot return two different hit sets
    /// depending on which machine the checkout sits on. A search is a round trip
    /// either way, so its failures are shown rather than swallowed: a root that
    /// no longer resolves, a daemon too old for `fs.search`, a box that stopped
    /// answering.
    private func find(_ query: String, limit: Int) async -> [ContentMatch] {
        let base = scope.base
        do {
            let result = try await scope.provider.search(query, limit: limit)
            return result.hits.map { hit in
                ContentMatch(
                    relative: hit.path,
                    url: base.appendingPathComponent(hit.path),
                    line: hit.line,
                    text: hit.text,
                    // The host measured these in bytes of its own line; the
                    // row paints characters. A range that does not land on a
                    // character boundary is dropped rather than nudged —
                    // a highlight one byte off is worse than none.
                    spans: hit.spans.compactMap { ContentMatch.range(hit.text, bytes: $0) },
                    isWindowed: hit.isWindowed,
                    before: hit.before,
                    after: hit.after)
            }
        } catch {
            guard !Task.isCancelled else { return [] }
            Log.files.error("""
            search \(scope.machine, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
            failure = Self.message(for: error, on: scope,
                                   fallback: localized("The search failed."))
            return []
        }
    }

    /// The daemon described what went wrong; wording it is this client's job, and
    /// only for the cases the client decides itself — a daemon that named a cause
    /// is quoted verbatim. `fallback` says which of the two round trips failed,
    /// since an error with no message of its own tells the user nothing else.
    ///
    /// The two roads need different sentences even though they now run one
    /// engine. A device that stopped answering is a network story; the daemon on
    /// this Mac is not reached over a network, and telling someone searching
    /// their own laptop that "this device didn’t answer" points them at a machine
    /// that is not the problem.
    private static func message(for error: Error, on scope: SearchScope,
                                fallback: String) -> String {
        // Silence, not a refusal — and the likeliest cause is a host that has
        // never heard of the op, so the sentence names that. The rest is the
        // shared table every device pane words its failures from.
        if case TermiodClientError.timedOut = error {
            return scope.isLocal
                ? localized("termiod on this Mac didn’t answer.")
                : localized("This device didn’t answer. Its termiod may be too old to search.")
        }
        if case DeviceFileError.unsupported = error, scope.isLocal {
            return localized("termiod on this Mac is too old to search.")
        }
        return RemoteFileFailure.message(for: error, fallback: fallback)
    }

    // MARK: - Opening a hit

    private func openFirstHit(inFile relative: String) {
        guard let match = matches.first(where: { $0.relative == relative }) else { return }
        open(match)
    }

    /// A click anywhere in an excerpt — a hit line or a context line — opens the
    /// file there. Context is real text from the file, so it is as clickable as
    /// the hit; treating it as decoration would make half the pane inert.
    private func openLine(_ line: Int, inFile url: URL) {
        guard let match = matches.first(where: { $0.url == url }) else { return }
        open(match, at: line)
    }

    /// Opens a hit at its line: the editor for a local file, and for a device the
    /// same read-only preview its file tree opens — the bytes are downloaded,
    /// never edited in place.
    private func open(_ match: ContentMatch, at line: Int? = nil) {
        let target = line ?? match.line
        guard case .device(let provider, let host, _) = scope else {
            store.openFileInEditor(match.url, at: target)
            return
        }
        // The same open the device's file tree uses: the overlay goes up on the
        // click, a file read before is shown from the cache while the device is
        // asked again, and a failure is reported in the overlay rather than in a
        // modal the click has to be dismissed out of.
        store.openRemoteFile(
            path: match.url.path, name: match.url.lastPathComponent,
            provider: provider, host: host, at: target)
    }

    /// The terminal surface fights for first responder; keep asking for a few
    /// ticks until the field actually has it (the palette's focus-retry gotcha).
    private func claimFocus(attempt: Int) {
        guard isVisible, attempt < 8 else { return }
        focusRequest += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attempt + 1)) {
            if !fieldFocused { claimFocus(attempt: attempt + 1) }
        }
    }
}

// MARK: - Native search field

/// AppKit owns the search field chrome and editing behavior. Rebuilding this
/// control from a plain SwiftUI text field misses the native bezel, focus ring,
/// cancel button, and field-editor behavior that make it feel at home on macOS.
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusRequest: Int
    let placeholder: String
    let onSubmit: () -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Switching away from the Search pane tears this field down by removing it from the view
    /// tree. If it's still first responder at that moment, AppKit plays its ~0.4s focus-ring
    /// fade-out — the blue outline you saw hanging over the next pane. Resign first responder
    /// with animations disabled (and drop the ring type) so the outline goes the instant the tab
    /// changes, matching the now-instant content swap.
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.focusRingType = .none
        guard let window = field.window,
              window.firstResponder === field || window.firstResponder === field.currentEditor()
        else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        window.makeFirstResponder(nil)
        NSAnimationContext.endGrouping()
    }

    func makeNSView(context: Context) -> NSTextField {
        // A plain text field, not `NSSearchField`: the SwiftUI wrapper draws the
        // chrome (glass capsule, magnifier, clear button — see `searchField`), and
        // a bezel-less `NSSearchField` misplaces its built-in icons. Bare text is
        // also what sidesteps the field's appearance animations (the focus-ring
        // bloom and the centered-placeholder slide) that replayed on every
        // auto-focused appearance of the pane.
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.focusRingType = .none
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self

        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }

        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        // The hosting view can enter the window one run-loop turn after SwiftUI
        // asks for focus, so wait until AppKit has attached the search field.
        DispatchQueue.main.async { [weak field] in
            guard let field, field.window != nil, field.currentEditor() == nil else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSearchField
        var lastFocusRequest = -1

        init(parent: NativeSearchField) {
            self.parent = parent
        }

        func submit(_ sender: NSTextField) {
            updateText(from: sender)
            parent.onSubmit()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            updateText(from: field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                guard let field = control as? NSTextField else { return false }
                submit(field)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onExit()
                return true
            default:
                return false
            }
        }

        private func updateText(from field: NSTextField) {
            guard parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }
    }
}

// MARK: - Rows

/// A file's group header: icon, name, dimmed directory, and its hit count on
/// the trailing edge — VS Code's search-tree file row. Clicking it opens the
/// file at its first hit.
private struct FileHeaderRow: View {
    let url: URL
    let relative: String
    let count: Int
    let isExpanded: Bool
    let chrome: ChromeTheme?
    let toggleExpanded: () -> Void
    /// Whether the row's file exists on this Mac. A device's does not, so it is
    /// not draggable — the URL names a path over there.
    let allowsDrag: Bool
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggleExpanded) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? localized("Collapse Results") : localized("Expand Results"))

            HStack(spacing: 5) {
                FileIconView(url: url, size: 15, symbolSize: 13)
                    .frame(width: 16, alignment: .leading)
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                let directory = (relative as NSString).deletingLastPathComponent
                if !directory.isEmpty {
                    Text(directory)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                // Count as a capsule badge (VS Code's count badge), so the number
                // reads as metadata rather than trailing content.
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 15)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .draggableFile(url, when: allowsDrag)
    }
}

/// A run of consecutive lines from one file — what one excerpt draws.
///
/// Zed's project search shows results as real text with the lines around them
/// rather than as a list of isolated strings, because a hit is only legible
/// where it sits: `items` means nothing, `repeated Widget items;` means
/// something. Two hits close together belong in one run, not two — reading the
/// same context twice with a divider through it is worse than reading it once.
struct SearchExcerpt: Identifiable {
    let lines: [ExcerptLine]
    var firstLine: Int { lines.first?.number ?? 0 }
    var id: Int { firstLine }

    /// Folds a file's matches into runs. Matches arrive in line order with their
    /// own context, so runs that touch or overlap merge, and each line is kept
    /// once — the trailing context of one hit is the leading context of the next.
    static func compose(_ matches: [ContentMatch]) -> [SearchExcerpt] {
        var runs: [[ExcerptLine]] = []
        for match in matches {
            for line in match.excerptLines() {
                if var current = runs.last, let last = current.last {
                    if line.number <= last.number {
                        // Already drawn — but a context line seen again as a hit
                        // has to *become* the hit, or the match goes unpainted.
                        if line.isMatch, let index = current.firstIndex(where: {
                            $0.number == line.number
                        }), !current[index].isMatch {
                            current[index] = line
                            runs[runs.count - 1] = current
                        }
                        continue
                    }
                    if line.number == last.number + 1 {
                        runs[runs.count - 1].append(line)
                        continue
                    }
                }
                runs.append([line])
            }
        }
        return runs.map { SearchExcerpt(lines: $0) }
    }
}

/// One line inside an excerpt: its number, its text, and — for a hit — where the
/// query landed, as the matcher measured it.
struct ExcerptLine: Identifiable {
    let number: Int
    let text: String
    let spans: [Range<String.Index>]
    let isMatch: Bool
    /// Whether the text is a window cut out of a longer line, so the row can
    /// say so instead of implying the line starts here.
    let isWindowed: Bool

    var id: Int { number }
}

extension ContentMatch {
    /// The match as excerpt lines: its context above, the hit, its context below.
    func excerptLines() -> [ExcerptLine] {
        var lines: [ExcerptLine] = []
        for (offset, text) in before.enumerated() {
            lines.append(ExcerptLine(
                number: firstLine + offset, text: text, spans: [],
                isMatch: false, isWindowed: false))
        }
        lines.append(ExcerptLine(
            number: line, text: text, spans: spans, isMatch: true,
            isWindowed: isWindowed))
        for (offset, text) in after.enumerated() {
            lines.append(ExcerptLine(
                number: line + 1 + offset, text: text, spans: [],
                isMatch: false, isWindowed: false))
        }
        return lines
    }
}

/// One excerpt: a gutter of line numbers beside the file's own text, syntax
/// colored, with the matched ranges washed.
///
/// The wash is deliberately not the accent color. On macOS a blue fill means
/// *selected*, and the row already has hover and selection layers of its own —
/// painting matches in the same vocabulary made a hit read as "this row is
/// picked". VS Code and Zed both keep find-highlight in a separate, warmer
/// register for the same reason.
private struct ExcerptView: View {
    let excerpt: SearchExcerpt
    let url: URL
    @ObservedObject var settings: AppSettings
    let colorScheme: ColorScheme
    let chrome: ChromeTheme?
    let open: (Int) -> Void

    @State private var styled: [Int: NSAttributedString] = [:]
    @State private var hoveredLine: Int?

    private var font: NSFont { settings.resolvedTerminalFont() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(excerpt.lines) { line in
                row(line)
            }
        }
        .padding(.vertical, 3)
        // Colored per excerpt, and lazily: `LazyVStack` only builds what is on
        // screen, so a thousand-hit search highlights the dozen runs in view
        // rather than all of them.
        .task(id: taskKey) { await colorize() }
    }

    private func row(_ line: ExcerptLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(line.number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            Text(attributed(line))
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(
            SidebarRowHighlight(isSelected: false, isHovering: hoveredLine == line.number,
                                chrome: chrome)
        )
        .onHover { hoveredLine = $0 ? line.number : nil }
        .onTapGesture { open(line.number) }
    }

    /// The line as it draws: syntax colors underneath, the match wash on top.
    /// Built from the spans the matcher reported — this view never searches the
    /// text itself, which is what keeps highlight and result the same answer.
    private func attributed(_ line: ExcerptLine) -> AttributedString {
        let base = styled[line.number]
            ?? NSAttributedString(string: line.text, attributes: [
                .foregroundColor: chrome.map { NSColor($0.foreground) } ?? NSColor.labelColor,
            ])
        let painted = NSMutableAttributedString(attributedString: base)
        painted.addAttribute(.font, value: font,
                             range: NSRange(location: 0, length: painted.length))
        for span in line.spans {
            let range = NSRange(span, in: line.text)
            guard range.location != NSNotFound,
                  range.location + range.length <= painted.length else { continue }
            painted.addAttribute(.backgroundColor, value: Self.wash(colorScheme), range: range)
            painted.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        var result = (try? AttributedString(painted, including: \.appKit)) ?? AttributedString(line.text)
        if line.isWindowed {
            // The line did not start here; say so rather than letting the window
            // pass for the whole line.
            result = AttributedString("…") + result
        }
        return result
    }

    /// The find-highlight, in both schemes. Warm rather than accent-blue so it
    /// cannot be read as selection.
    private static func wash(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.99, green: 0.76, blue: 0.29, alpha: 0.30)
            : NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.11, alpha: 0.42)
    }

    private var taskKey: String {
        "\(url.path)\u{1f}\(excerpt.firstLine)\u{1f}\(colorScheme)"
    }

    private func colorize() async {
        guard let language = FileEditorView.highlightLanguage(for: url) else { return }
        let requests = excerpt.lines.map { StyledLineRequest(id: $0.number, text: $0.text) }
        let result = await DiffHighlighter.shared.styledLines(
            requests, language: language,
            theme: colorScheme == .dark ? "xcode-dark" : "xcode", font: font)
        guard !Task.isCancelled else { return }
        styled = result.byRow
    }
}

/// The break between two runs of lines from the same file — Zed's "there is
/// more of this file between these" mark, quiet enough not to read as a divider
/// between files.
private struct ExcerptGap: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("⋯")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 34, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 12)
    }
}

private extension View {
    /// Drags the row out as its file, but only when the file is on this Mac. A
    /// device's row carries a path on that box, and a drag promising the Finder
    /// a local file at that path would be a promise nothing can keep.
    @ViewBuilder
    func draggableFile(_ url: URL, when allowed: Bool) -> some View {
        if allowed {
            draggable(url)
        } else {
            self
        }
    }
}

