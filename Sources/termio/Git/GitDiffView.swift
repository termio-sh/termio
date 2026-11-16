import TermioShared
import AppKit
import SwiftUI

// MARK: - Diff overlay

/// A read-only diff that covers the terminal pane — the git counterpart of
/// `FilePreviewView`/`FileEditorView`, driven by `store.openDiff`. The lines are drawn by
/// @pierre/diffs in a web view (`DiffWebView`), the same page the pull request's Files view
/// uses: syntax colors, the word diff inside a changed line, the bands that expand hidden
/// context, and the two-column layout are the library's. This view owns the header, the
/// walk between files, and ⌘F, which opens the same `FileFindBar` the code editor uses.
/// Escape or the close button dismisses it.
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

    /// The file's diff as `git` printed it, and the file it belongs to. They change together,
    /// so the page never draws one file's lines under another file's name.
    @State private var loaded: (change: GitChange, patch: String)?
    @State private var isLoading = true
    /// The spinner waits 0.15 s before appearing, so a fast file-to-file walk swaps
    /// content with no intermediate flash; only a genuinely slow diff shows it.
    @State private var showsSpinner = false

    /// The docked inspector is too narrow for two columns.
    private var isSplitView: Bool { settings.diffSplitView && store.inspectorMaximized }

    // Find bar — the same `FileFindBar` the code editor uses. The page does the search.
    @State private var findBarVisible = false
    @State private var findQuery = ""
    @State private var findOptions = FindOptions()
    @State private var findFocusedIndex = 0
    @State private var findCount = 0
    /// Bumped on every step through the matches (see `DiffWebFind.step`).
    @State private var findStep = 0
    /// The query at the last Return press; a second Return on the same query advances.
    @State private var findLastSubmittedQuery = ""
    /// Bumped on every ⌘F so the field re-focuses even when the bar is already open.
    @State private var findFocusTrigger = 0
    /// Bumped when the bar closes so the diff reclaims first responder.
    @State private var findReclaim = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        // The diff's web view owns the keys once mounted; these cover the loading
        // and empty states, where there is no web view to hold first responder.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { walk(-1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { walk(+1) ? .handled : .ignored }
        .onExitCommand(perform: onClose)
        .task(id: request) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .termioShowFindBar)) { _ in
            openFindBar()
        }
        // ⌘G / ⇧⌘G reach the diff's find bar too — it is the same bar, over the same engine.
        // ⌘E is not wired here: the buffer is read-only, and the verb belongs to the editor
        // whose text view holds the keyboard.
        .onReceive(NotificationCenter.default.publisher(for: .termioFindNext)) { _ in
            guard findBarVisible else { return }
            advanceFind(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .termioFindPrevious)) { _ in
            guard findBarVisible else { return }
            advanceFind(by: -1)
        }
    }

    // MARK: Find

    /// ⌘F: reveal the find bar (only over a loaded diff — nothing to search otherwise).
    private func openFindBar() {
        guard hasContent else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findBarVisible = true }
        // The diff holds first responder; drop it so the find field can take the keyboard.
        NSApp.keyWindow?.makeFirstResponder(nil)
        findFocusTrigger &+= 1
    }

    private func closeFindBar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { findBarVisible = false }
        findQuery = ""
        findLastSubmittedQuery = ""
        findFocusedIndex = 0
        findCount = 0
        findOptions = FindOptions()
        findReclaim &+= 1
    }

    /// Return: fresh query → match 1; same query → next match.
    private func submitFind() {
        guard !findQuery.isEmpty else { return }
        if findQuery == findLastSubmittedQuery, findCount > 0 {
            advanceFind(by: 1)
        } else {
            findLastSubmittedQuery = findQuery
            findFocusedIndex = 0
        }
    }

    private func advanceFind(by offset: Int) {
        guard findCount > 0 else { return }
        findFocusedIndex = ((findFocusedIndex + offset) % findCount + findCount) % findCount
        findStep &+= 1
    }

    private func noteFindCount(_ count: Int, _ index: Int?) {
        findCount = count
        if let index { findFocusedIndex = index } else if findFocusedIndex >= count { findFocusedIndex = 0 }
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

    private var fileIdentity: some View {
        let directory = request.change.directory
        let name = Text(request.name).font(.system(size: 12.5, weight: .medium))
        return directory.isEmpty
            ? name
            : name + Text("  \(directory)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
    }

    private var header: some View {
        HStack(spacing: 8) {
            DetailListColumnToggle()
            Text(request.change.status.letter)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(request.change.status.tint)
                .frame(width: 16)
            // Name and directory as one text run with a single truncation point: as two
            // flexible texts a narrow pane split the width between them and truncated
            // both into noise. Tail truncation keeps the name (the head) readable longest.
            //
            if request.walkableSiblings.count > 1 {
                DiffFileMenuLabel(request: request) { change in
                    onNavigate?(request.aimed(at: change))
                } content: {
                    fileIdentity
                }
            } else {
                fileIdentity
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            // "n of m" (Mail's message-walk wording) whenever there is a set to walk.
            if request.siblings.count > 1, let index = walkIndex {
                Text(localized("\(index + 1) of \(request.siblings.count)"))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.trailing, 2)
            }
            // For a history diff, tag the header with the commit it belongs to.
            // `fixedSize` (as on the ± counts) keeps the tag on one line in a narrow
            // pane — the flexible path is the only element that gives up width.
            if let commit = request.commit {
                Text("@ \(commit.prefix(7))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
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
            // Inline or side by side. Only a diff with the whole window to spend gets the
            // choice: docked, the pane is a column of the inspector and has no room for two.
            if store.inspectorMaximized {
                DetailChromeButton(
                    icon: isSplitView ? .layoutRows : .layoutColumns,
                    help: isSplitView ? localized("Show one column (inline diff)")
                                      : localized("Show two columns (side-by-side diff)")
                ) { settings.diffSplitView.toggle() }
            }
            // The content-area window controls (hide list / maximize / close) ride the header's
            // trailing edge, after the diff's own stats.
            InspectorDetailChromeButtons()
        }
        .padding(.horizontal, 12)
        // Fixed height + inset hairline shared with the git pane's mode switch, so this
        // bar and the inspector's `Changes | History` bar line up across the split.
        .frame(height: GitChangesView.topBarHeight)
        .modifier(DetailHeaderTitlebarInset())
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: Content

    /// A diff with no hunk has no lines to draw: a pure rename, a mode change, a binary file.
    private var hasContent: Bool {
        guard let patch = loaded?.patch else { return false }
        return patch.hasPrefix("@@") || patch.contains("\n@@")
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showsSpinner ? 1 : 0)
                    .task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        showsSpinner = true
                    }
            } else if hasContent, let loaded {
                diff(loaded.change, patch: loaded.patch)
            } else {
                PaneEmptyState(
                    localized("No Diff"),
                    icon: .fileDoc,
                    message: localized("No textual changes to show.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if findBarVisible, hasContent { findBar }
        }
    }

    private func diff(_ change: GitChange, patch: String) -> some View {
        DiffWebView(
            files: [change],
            patches: [change.path: patch],
            fileText: { _ in await fullText(of: change, shownAs: patch) },
            look: DiffLook(settings: settings, colorScheme: colorScheme),
            onClose: onClose,
            single: DiffWebSingle(
                isSplit: isSplitView,
                find: findBarVisible
                    ? DiffWebFind(query: findQuery, options: findOptions,
                                  index: findFocusedIndex, step: findStep)
                    : nil,
                onFindCount: noteFindCount,
                // Escape closes the find bar first, then the overlay.
                onEscape: { if findBarVisible { closeFindBar() } else { onClose() } },
                onStale: { Task { await load() } },
                onWalk: { walk($0) },
                // Cursor's split, like the editor: a selection goes over as the pasted
                // snippet; no selection means the diffed file, which lands as its path.
                addToChat: { selection in
                    if let selection {
                        _ = store.addSnippetToSelectedSessionPrompt(selection)
                    } else {
                        let url = URL(fileURLWithPath: request.repoRoot)
                            .appendingPathComponent(change.path)
                        _ = store.addPathToSelectedSessionPrompt(url)
                    }
                },
                canAddToChat: { store.selectedSessionRunsAgent },
                reclaimFocus: findReclaim
            )
        )
    }

    private var findBar: some View {
        FileFindBar(
            query: $findQuery,
            options: $findOptions,
            currentMatch: findCount == 0 ? 0 : findFocusedIndex + 1,
            totalMatches: findCount,
            onSubmit: submitFind,
            onNext: { advanceFind(by: 1) },
            onPrevious: { advanceFind(by: -1) },
            onClose: closeFindBar,
            focusTrigger: findFocusTrigger
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    // MARK: Loading

    /// The whole file, for the page to expand a band from. The diff is read again beside it:
    /// when the file has changed since `patch` was drawn, its lines no longer sit under the
    /// hunks on screen, so the overlay loads the new diff and expands nothing.
    private func fullText(of change: GitChange, shownAs patch: String) async -> DiffFullText? {
        let text = await DiffSource.fullText(
            for: change, in: request.repoRoot, device: request.device,
            commit: request.commit, range: request.range)
        let current = await DiffSource.patch(
            for: change, in: request.repoRoot, device: request.device,
            commit: request.commit, range: request.range)
        guard current == patch else {
            await load()
            return nil
        }
        return text
    }

    private func load() async {
        let change = request.change
        let patch = await DiffSource.patch(
            for: change, in: request.repoRoot, device: request.device,
            commit: request.commit, range: request.range)
        guard !Task.isCancelled else { return }
        findFocusedIndex = 0
        loaded = (change, patch)
        isLoading = false
    }
}

extension GitDiffRequest {
    func aimed(at change: GitChange) -> GitDiffRequest {
        GitDiffRequest(repoRoot: repoRoot, device: device, change: change,
                       commit: commit, range: range, siblings: siblings)
    }

    /// Preview-only images and PDFs are excluded from both the menu and keyboard navigation.
    var walkableSiblings: [GitChange] {
        siblings.filter { candidate in
            !FileActivation.previewsRatherThanDiff(
                URL(fileURLWithPath: repoRoot).appendingPathComponent(candidate.path))
        }
    }

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
                return aimed(at: candidate)
            }
            next += delta
        }
        return nil
    }
}
