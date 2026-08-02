import AppKit
import SwiftUI

// MARK: - Diff overlay

/// A read-only unified diff that covers the terminal pane — the git counterpart of
/// `FilePreviewView`/`FileEditorView`, driven by `store.openDiff`. The content is one
/// TextKit view holding the whole diff (`DiffTextPane`): code keeps its syntax colors
/// (the editor's Highlightr pipeline) with the add/delete tint painted as a full-width
/// wash underneath, raw `@@` plumbing never appears — unchanged runs collapse into
/// expandable "n lines" bands — selection runs continuously across lines, and ⌘F opens the
/// same `FileFindBar` the code editor uses. Escape or the close button dismisses it.
struct GitDiffView: View {
    let request: GitDiffRequest
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void
    /// Replaces the overlay's request in place — ← / → walk through `request.siblings`
    /// without dropping back to the list (Quick Look's arrow-key walk; ↑ ↓ stay with
    /// scrolling, and the same keys in the focused Changes list walk via selection).
    var onNavigate: ((GitDiffRequest) -> Void)? = nil

    /// For the right-click "Add to Chat": the gate and the prompt insertion live
    /// on the store.
    @EnvironmentObject private var store: TermioStore

    @Environment(\.colorScheme) private var colorScheme

    @State private var rows: [DiffRow] = []
    @State private var document: DiffDocument?
    @State private var isLoading = true
    /// The spinner waits 0.15 s before appearing, so a fast file-to-file walk swaps
    /// content with no intermediate flash; only a genuinely slow diff shows it.
    @State private var showsSpinner = false
    /// Syntax-colored line content per row id, filled by a background pass after the
    /// rows land; the document renders plain until then.
    @State private var styledLines: [Int: NSAttributedString] = [:]
    /// Ids (first hidden row) of the collapsed bands the user has expanded.
    @State private var expanded: Set<Int> = []

    // Find bar — the same `FileFindBar` the code editor uses, over the diff's read-only text.
    @State private var findBarVisible = false
    @State private var findQuery = ""
    @State private var findOptions = FindOptions()
    @State private var findFocusedIndex = 0
    @State private var findMatchCount = 0
    /// The query at the last Return press; a second Return on the same query advances.
    @State private var findLastSubmittedQuery = ""
    /// Bumped on every ⌘F so the field re-focuses even when the bar is already open.
    @State private var findFocusTrigger = 0
    /// Bumped when the bar closes so the text view reclaims first responder.
    @State private var findReclaim = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        // The pane's text view owns the keys once mounted; these cover the loading
        // and empty states, where there is no text view to hold first responder.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { walk(-1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { walk(+1) ? .handled : .ignored }
        .onExitCommand(perform: onClose)
        .task(id: request) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .termioShowFindBar)) { _ in
            openFindBar()
        }
    }

    // MARK: Find

    /// ⌘F: reveal the find bar (only over a loaded diff — nothing to search otherwise).
    private func openFindBar() {
        guard document != nil else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findBarVisible = true }
        // The text view holds first responder; drop it so the find field can take the keyboard.
        NSApp.keyWindow?.makeFirstResponder(nil)
        findFocusTrigger &+= 1
    }

    private func closeFindBar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findBarVisible = false }
        findQuery = ""
        findLastSubmittedQuery = ""
        findMatchCount = 0
        findFocusedIndex = 0
        findOptions = FindOptions()
        findReclaim &+= 1
    }

    /// Return: fresh query → match 1; same query → next match.
    private func submitFind() {
        guard !findQuery.isEmpty else { return }
        if findQuery == findLastSubmittedQuery, findMatchCount > 0 {
            advanceFind(by: 1)
        } else {
            findLastSubmittedQuery = findQuery
            findFocusedIndex = 0
        }
    }

    private func advanceFind(by offset: Int) {
        guard findMatchCount > 0 else { return }
        findFocusedIndex = ((findFocusedIndex + offset) % findMatchCount + findMatchCount) % findMatchCount
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
            // The content-area window controls (hide list / maximize / close) ride the header's
            // trailing edge, after the diff's own stats.
            InspectorDetailChromeButtons()
        }
        .padding(.horizontal, 12)
        // Fixed height + inset hairline shared with the git pane's mode switch, so this
        // bar and the inspector's `Changes | History` bar line up across the split.
        .frame(height: GitChangesView.topBarHeight)
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: Content

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
        } else if let document {
            DiffTextPane(
                document: document,
                styled: styledLines,
                font: settings.resolvedTerminalFont(),
                backgroundColor: settings.terminalBackgroundColor,
                numberColor: settings.gutterInk(for: colorScheme),
                onExpand: { id in
                    expanded.insert(id)
                    self.document = DiffDocument.build(
                        rows: rows, expanded: expanded,
                        codeFont: settings.resolvedTerminalFont(),
                                 lineSpacing: settings.codeLineSpacing(for: settings.resolvedTerminalFont()))
                },
                onWalk: { walk($0) },
                onClose: onClose,
                findQuery: findBarVisible ? findQuery : "",
                findOptions: findOptions,
                findFocusedIndex: findFocusedIndex,
                onMatchesChanged: { count in
                    findMatchCount = count
                    if count > 0, findFocusedIndex >= count { findFocusedIndex = 0 }
                },
                reclaimFocus: findReclaim,
                // Cursor's split, like the editor: a selection goes over as the pasted
                // snippet; no selection means the diffed file, which lands as its path.
                addToChat: { selection in
                    if let selection {
                        _ = store.addSnippetToSelectedSessionPrompt(selection)
                    } else {
                        let url = URL(fileURLWithPath: request.repoRoot)
                            .appendingPathComponent(request.change.path)
                        _ = store.addPathToSelectedSessionPrompt(url)
                    }
                },
                canAddToChat: { store.selectedSessionRunsAgent }
            )
            .overlay(alignment: .topTrailing) {
                if findBarVisible {
                    FileFindBar(
                        query: $findQuery,
                        options: $findOptions,
                        currentMatch: findMatchCount == 0 ? 0 : findFocusedIndex + 1,
                        totalMatches: findMatchCount,
                        onSubmit: submitFind,
                        onNext: { advanceFind(by: 1) },
                        onPrevious: { advanceFind(by: -1) },
                        onClose: closeFindBar,
                        focusTrigger: findFocusTrigger
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        } else {
            ContentUnavailableView(
                "No Diff",
                huge: .fileDoc,
                description: Text("No textual changes to show.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Loading + syntax colors

    private func load() async {
        let parsed = await GitService.diffRows(
            for: request.change, in: request.repoRoot, commit: request.commit, range: request.range)
        rows = parsed
        document = parsed.isEmpty
            ? nil
            : DiffDocument.build(rows: parsed, expanded: expanded,
                                 codeFont: settings.resolvedTerminalFont(),
                                 lineSpacing: settings.codeLineSpacing(for: settings.resolvedTerminalFont()))
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
                                      commit: commit, range: range, siblings: siblings)
            }
            next += delta
        }
        return nil
    }
}
