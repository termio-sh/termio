import AppKit
import SwiftUI

// MARK: - Diff overlay

/// A read-only unified diff that covers the terminal pane — the git counterpart of
/// `FilePreviewView`/`FileEditorView`, driven by `store.openDiff`. Native SwiftUI rows
/// in a `List` (NSTableView underneath, for stable variable-height scrolling), styled
/// after the current generation of diff readers: code keeps its syntax colors (the
/// editor's Highlightr pipeline) with the add/delete tint as a wash underneath, raw
/// `@@` plumbing never appears — unchanged runs collapse into expandable "n lines"
/// bands — and the gutter chrome recedes. Escape or the close button dismisses it.
struct GitDiffView: View {
    let request: GitDiffRequest
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void
    /// Replaces the overlay's request in place — ← / → walk through `request.siblings`
    /// without dropping back to the list (Quick Look's arrow-key walk; ↑ ↓ stay with
    /// scrolling, and the same keys in the focused Changes list walk via selection).
    var onNavigate: ((GitDiffRequest) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    @State private var rows: [DiffRow] = []
    @State private var isLoading = true
    /// The spinner waits 0.15 s before appearing, so a fast file-to-file walk swaps
    /// content with no intermediate flash; only a genuinely slow diff shows it.
    @State private var showsSpinner = false
    /// Syntax-colored line content per row id (emphasis merged in), filled by a
    /// background pass after the rows land; rows render plain until then.
    @State private var styledLines: [Int: AttributedString] = [:]
    /// Ids (first hidden row) of the collapsed bands the user has expanded.
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { walk(-1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { walk(+1) ? .handled : .ignored }
        .onExitCommand(perform: onClose)
        .task(id: request) { await load() }
    }

    // MARK: Walking

    private var walkIndex: Int? {
        request.siblings.firstIndex { $0.path == request.change.path }
    }

    /// Steps to the previous/next diffable sibling. Returns false at either end so
    /// the key press falls through instead of pretending to act.
    private func walk(_ delta: Int) -> Bool {
        guard let onNavigate, let next = request.neighbor(delta) else { return false }
        onNavigate(next)
        return true
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(request.change.status.letter)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(request.change.status.tint)
                .frame(width: 16)
            Text(request.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            let directory = (request.change.path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                Text(directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            // "n of m" (Mail's message-walk wording) whenever there is a set to walk.
            if request.siblings.count > 1, let index = walkIndex {
                Text("\(index + 1) of \(request.siblings.count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
            }
            // For a history diff, tag the header with the commit it belongs to.
            if let commit = request.commit {
                Text("@ \(commit.prefix(7))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
            }
            HStack(spacing: 5) {
                if request.change.additions > 0 {
                    Text("+\(request.change.additions)").foregroundStyle(.green)
                }
                if request.change.deletions > 0 {
                    Text("−\(request.change.deletions)").foregroundStyle(.red)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .fixedSize()
            // Close lives in the toolbar (a bordered button hugging the terminal|inspector
            // divider) — see `setCloseOverlayVisible` in App.swift.
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: settings.terminalBackgroundColor))
    }

    // MARK: Content

    /// One renderable element: a code line, or a collapsed band standing in for a run
    /// of unchanged lines. A band with rows expands in place when clicked; a band with
    /// none (the default-context fallback, where the hidden lines were never fetched)
    /// is a fixed marker sized from the hunk-boundary arithmetic.
    private enum DisplayItem: Identifiable {
        case line(DiffRow)
        case band(id: Int, count: Int, expandable: Bool)

        var id: Int {
            switch self {
            case .line(let row): return row.id
            case .band(let id, _, _): return -id - 1
            }
        }
    }

    /// Folds the raw rows into the display list: hunk plumbing disappears (its gap
    /// becomes a band), and unchanged runs longer than a handful of lines collapse to
    /// a band keeping 3 lines of context on the side(s) that face a change.
    private var displayItems: [DisplayItem] {
        var items: [DisplayItem] = []
        var run: [DiffRow] = []
        var sawChange = false
        var lastNewLine = 0

        func flush(isLast: Bool) {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let head = sawChange ? 3 : 0
            let tail = isLast ? 0 : 3
            let hidden = run.count - head - tail
            guard hidden >= 10 else {
                items += run.map(DisplayItem.line)
                return
            }
            items += run.prefix(head).map(DisplayItem.line)
            let hiddenRows = Array(run.dropFirst(head).dropLast(tail))
            if expanded.contains(hiddenRows[0].id) {
                items += hiddenRows.map(DisplayItem.line)
            } else {
                items.append(.band(id: hiddenRows[0].id, count: hiddenRows.count, expandable: true))
            }
            items += run.suffix(tail).map(DisplayItem.line)
        }

        for row in rows {
            switch row.kind {
            case .hunk:
                flush(isLast: false)
                if let start = row.newLine, start > lastNewLine + 1 {
                    items.append(.band(id: row.id, count: start - lastNewLine - 1, expandable: false))
                }
            case .context:
                run.append(row)
                lastNewLine = row.newLine ?? lastNewLine
            case .addition:
                flush(isLast: false)
                sawChange = true
                items.append(.line(row))
                lastNewLine = row.newLine ?? lastNewLine
            case .deletion:
                flush(isLast: false)
                sawChange = true
                items.append(.line(row))
            }
        }
        flush(isLast: true)
        return items
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(showsSpinner ? 1 : 0)
                .task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    showsSpinner = true
                }
        } else if rows.isEmpty {
            ContentUnavailableView(
                "No Diff",
                systemImage: "doc",
                description: Text("No textual changes to show.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // A `List` (NSTableView underneath), not a `ScrollView`+`LazyVStack`: the rows
            // soft-wrap, so their heights vary, and LazyVStack only *estimates* heights for
            // off-screen content — scrolling fights the estimates (visible jitter) and rows
            // laid out at an old width keep their stale wrap after the inspector resizes.
            List(displayItems) { item in
                Group {
                    switch item {
                    case .line(let row):
                        DiffLineRow(row: row, styled: styledLines[row.id],
                                    font: diffFont, gutterFont: gutterFont,
                                    showOldGutter: hasOldLines, showNewGutter: hasNewLines)
                    case .band(let id, let count, let expandable):
                        CollapsedBand(count: count, expandable: expandable) {
                            expanded.insert(id)
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // A realistic per-line estimate, NOT 1: the table uses this to size its
            // viewport, and a 1 pt estimate on a full-context diff (thousands of rows)
            // makes it materialize them all at once — a seconds-long main-thread stall.
            .environment(\.defaultMinListRowHeight, lineHeightEstimate)
        }
    }

    /// Approximate single-line row height (font line box + the row's 1 pt paddings).
    private var lineHeightEstimate: CGFloat {
        let font = settings.resolvedTerminalFont()
        return (font.ascender - font.descender + font.leading).rounded(.up) + 2
    }

    /// Whether any code row carries an old/new line number (hunk rows don't count —
    /// they hold start offsets). A pure-addition file has no old numbers, so that
    /// empty gutter collapses rather than showing a blank band; likewise a pure
    /// deletion collapses the new gutter.
    private var hasOldLines: Bool { rows.contains { $0.kind != .hunk && $0.oldLine != nil } }
    private var hasNewLines: Bool { rows.contains { $0.kind != .hunk && $0.newLine != nil } }

    /// The terminal font, so the diff reads in the same face as the agent's output
    /// and the file editor.
    private var diffFont: Font {
        Font(settings.resolvedTerminalFont())
    }

    /// Line numbers step down from the code the same way the editor's gutter does.
    private var gutterFont: Font {
        let size = max(9, settings.resolvedTerminalFont().pointSize - 1.5)
        return Font(NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular))
    }

    // MARK: Loading + syntax colors

    private func load() async {
        let parsed = await GitService.diffRows(for: request.change, in: request.repoRoot, commit: request.commit)
        rows = parsed
        isLoading = false
        await buildStyledLines(parsed)
    }

    /// Colors the code through `DiffHighlighter` (the editor's Highlightr pipeline
    /// behind a shared actor). Oversized diffs skip coloring rather than stall; a
    /// result that lands after the user has walked on is dropped, not applied.
    private func buildStyledLines(_ rows: [DiffRow]) async {
        let url = URL(fileURLWithPath: request.repoRoot).appendingPathComponent(request.change.path)
        guard let language = FileEditorView.highlightLanguage(for: url) else { return }
        let code = rows.filter { $0.kind != .hunk }
        guard code.count <= 8000, code.reduce(0, { $0 + $1.text.count }) <= 600_000 else { return }

        let styled = await DiffHighlighter.shared.styledLines(
            newSide: code.filter { $0.kind == .context || $0.kind == .addition },
            oldSide: code.filter { $0.kind == .context || $0.kind == .deletion },
            language: language,
            theme: colorScheme == .dark ? "xcode-dark" : "xcode",
            font: settings.resolvedTerminalFont()
        )
        guard !Task.isCancelled else { return }
        styledLines = styled
    }
}

extension GitDiffRequest {
    /// The nearest sibling in `delta`'s direction that has a textual diff —
    /// image/PDF siblings belong to the preview overlay and are skipped. The one
    /// walking rule, shared by the overlay's own ← / → and the Changes list's.
    func neighbor(_ delta: Int) -> GitDiffRequest? {
        guard let index = siblings.firstIndex(where: { $0.path == change.path }) else { return nil }
        var next = index + delta
        while next >= 0, next < siblings.count {
            let candidate = siblings[next]
            let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(candidate.path)
            if !FileActivation.previewsRatherThanDiff(url) {
                return GitDiffRequest(repoRoot: repoRoot, change: candidate,
                                      commit: commit, siblings: siblings)
            }
            next += delta
        }
        return nil
    }
}

// MARK: - Rows

/// One code line of the diff: old/new line-number gutter (quiet, quaternary ink), a
/// `+`/`−`/space sign, and the code — syntax-colored when the styled pass has landed,
/// plain until then — over a green/red/clear wash. Long lines soft-wrap (the panel is
/// fixed-width), which keeps each line's background spanning the full width.
private struct DiffLineRow: View {
    let row: DiffRow
    let styled: AttributedString?
    let font: Font
    let gutterFont: Font
    var showOldGutter = true
    var showNewGutter = true

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showOldGutter { gutter(row.oldLine) }
            if showNewGutter { gutter(row.newLine) }
            Text(sign)
                .font(font)
                .foregroundStyle(signColor)
                .frame(width: 14)
            codeText
                .font(font)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var codeText: Text {
        if let styled, !styled.characters.isEmpty { return Text(styled) }
        guard !row.text.isEmpty else { return Text(" ") }
        var attributed = AttributedString(row.text)
        attributed.applyDiffEmphasis(row.emphasis, kind: row.kind)
        return Text(attributed)
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(gutterFont)
            .foregroundStyle(.quaternary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var sign: String {
        switch row.kind {
        case .addition: return "+"
        case .deletion: return "-"
        default: return " "
        }
    }

    private var signColor: Color {
        switch row.kind {
        case .addition: return .green
        case .deletion: return .red
        default: return .secondary
        }
    }

    private var background: Color {
        switch row.kind {
        case .addition: return Color.green.opacity(0.13)
        case .deletion: return Color.red.opacity(0.13)
        default: return .clear
        }
    }
}

/// The stand-in for a run of unchanged lines — the raw `@@` hunk header never appears.
/// Expandable bands (full-context loads) splice their lines back in on click; fixed
/// bands (the oversized-diff fallback) just mark the gap. Meta information, so it
/// speaks in the UI font, not the code font.
private struct CollapsedBand: View {
    let count: Int
    let expandable: Bool
    let onExpand: () -> Void

    @State private var isHovering = false

    var body: some View {
        Group {
            if expandable {
                Button(action: onExpand) { label }
                    .buttonStyle(.plain)
                    .onHover { isHovering = $0 }
            } else {
                label
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(isHovering ? 0.07 : 0.04))
        .contentShape(Rectangle())
    }

    private var label: some View {
        HStack(spacing: 6) {
            if expandable {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
            }
            Text("\(count) unchanged \(count == 1 ? "line" : "lines")")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(isHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .frame(maxWidth: .infinity)
    }
}
