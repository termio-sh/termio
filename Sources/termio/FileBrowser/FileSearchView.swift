import AppKit
import SwiftUI

/// The inspector's Search pane — a sibling of Files / Changes / Info on the
/// toolbar switch, searching file *contents* (VS Code's ⇧⌘F; the filename jump
/// lives in Open Quickly, ⌘⇧O). Queries run debounced through `ContentSearch`
/// (`git grep`, ignore rules for free), results group under their file with the
/// matched substring tinted accent, and clicking a hit opens the editor
/// scrolled to that line.
struct FileSearchView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    /// The project (or worktree) root the search runs under.
    let rootURL: URL
    let font: Font
    /// Leaves the pane (back to the Files tab) — Esc in an empty field.
    let onDismiss: () -> Void
    /// Opens a hit in the editor at its 1-based line.
    let onOpen: (_ url: URL, _ line: Int) -> Void

    /// Total hits kept per query — past this the footer says so and the user
    /// should sharpen the query rather than scroll.
    private static let matchLimit = 400
    /// Typing pause before a grep actually runs (Warp uses 50ms for in-memory
    /// matching; a subprocess earns a slightly longer breath).
    private static let debounce: Duration = .milliseconds(250)

    @State private var query = ""
    @State private var matches: [ContentMatch] = []
    @State private var isSearching = false
    /// The in-flight debounce+grep, cancelled by the next keystroke.
    @State private var searchTask: Task<Void, Never>?
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

    // MARK: - Pieces

    private var searchField: some View {
        VStack(spacing: 0) {
            NativeSearchField(
                text: $query,
                isFocused: $fieldFocused,
                focusRequest: focusRequest,
                placeholder: "Search Project",
                onSubmit: {
                    if let first = matches.first { onOpen(first.url, first.line) }
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
            .frame(height: 24)
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, trimmedQuery.isEmpty ? 7 : 4)

            if !trimmedQuery.isEmpty {
                HStack(spacing: 5) {
                    if isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(isSearching ? "Searching…" : summary(fileCount: groups.count))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
            }
        }
    }

    @ViewBuilder
    private var resultList: some View {
        let grouped = groups
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(grouped, id: \.relative) { group in
                    let isExpanded = !collapsedFiles.contains(group.relative)
                    FileHeaderRow(
                        url: group.url,
                        relative: group.relative,
                        count: group.items.count,
                        isExpanded: isExpanded,
                        chrome: chrome,
                        toggleExpanded: {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                if isExpanded {
                                    collapsedFiles.insert(group.relative)
                                } else {
                                    collapsedFiles.remove(group.relative)
                                }
                            }
                        },
                        open: { onOpen(group.url, group.items[0].line) }
                    )
                    if isExpanded {
                        ForEach(group.items, id: \.line) { match in
                            MatchRow(
                                match: match,
                                query: trimmedQuery,
                                chrome: chrome,
                                open: { onOpen(match.url, match.line) }
                            )
                        }
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
                    Text("No Matches")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Try another search term.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func summary(fileCount: Int) -> String {
        let capped = matches.count >= Self.matchLimit
        return "\(matches.count)\(capped ? "+" : "") matches in \(fileCount) files"
    }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Hits folded under their file, in grep's own order (file-grouped already —
    /// consecutive runs are enough, no re-sort).
    private var groups: [(relative: String, url: URL, items: [ContentMatch])] {
        var out: [(relative: String, url: URL, items: [ContentMatch])] = []
        for match in matches {
            if out.last?.relative == match.relative {
                out[out.count - 1].items.append(match)
            } else {
                out.append((match.relative, match.url, [match]))
            }
        }
        return out
    }

    // MARK: - Search

    /// Debounce + cancel-on-keystroke (Warp's abort pattern): each edit kills
    /// the in-flight task; only a typing pause reaches the actual grep, which
    /// runs detached so the field never hitches.
    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            matches = []
            isSearching = false
            return
        }
        let root = rootURL
        let limit = Self.matchLimit
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = await Task.detached(priority: .userInitiated) {
                ContentSearch.search(trimmed, under: root, limit: limit)
            }.value
            guard !Task.isCancelled else { return }
            matches = found
            isSearching = false
        }
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
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        field.focusRingType = .none
        guard let window = field.window,
              window.firstResponder === field || window.firstResponder === field.currentEditor()
        else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        window.makeFirstResponder(nil)
        NSAnimationContext.endGrouping()
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
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

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        var lastFocusRequest = -1

        init(parent: NativeSearchField) {
            self.parent = parent
        }

        func submit(_ sender: NSSearchField) {
            updateText(from: sender)
            parent.onSubmit()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
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
                guard let field = control as? NSSearchField else { return false }
                submit(field)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onExit()
                return true
            default:
                return false
            }
        }

        private func updateText(from field: NSSearchField) {
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
            .help(isExpanded ? "Collapse Results" : "Expand Results")

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
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 18, alignment: .trailing)
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
        .draggable(url)
    }
}

/// One hit line: the dimmed line number in a fixed gutter, then the line's text
/// with the matched substring tinted accent — enough context to pick the right
/// hit without opening anything.
private struct MatchRow: View {
    let match: ContentMatch
    let query: String
    let chrome: ChromeTheme?
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(match.line)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            Text(highlightedText())
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.leading, 27)
        .padding(.trailing, 8)
        .frame(minHeight: 21)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
    }

    /// The line trimmed for display, windowed so the hit is visible even when
    /// it sits deep in a long line (leading context replaced by an ellipsis),
    /// with the query's first occurrence tinted accent + bold.
    private func highlightedText() -> AttributedString {
        var display = match.text.trimmingCharacters(in: .whitespaces)
        if let range = display.range(of: query, options: .caseInsensitive) {
            let offset = display.distance(from: display.startIndex, to: range.lowerBound)
            if offset > 40 {
                let start = display.index(range.lowerBound, offsetBy: -20)
                display = "…" + display[start...]
            }
        }
        var attributed = AttributedString(display)
        if let range = attributed.range(of: query, options: .caseInsensitive) {
            attributed[range].foregroundColor = .accentColor
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
