import TermioShared
import AppKit
import SwiftUI

// MARK: - PR files (master-detail)

/// GitHub Desktop's "Files changed": a file list on the left, the selected file's diff
/// on the right. Diffs come from the GitHub API's inline `patch` (no checkout, no git),
/// rendered by the single-file diff renderer (`DiffDocument` / `DiffTextPane`), so the
/// list stays put while you review and you always see where you are in the PR.
struct PRFilesSplitView: View {
    let files: [GitChange]
    /// Each file's inline unified-diff `patch` from the GitHub API, keyed by path.
    let patches: [String: String]
    /// Reads a file at the PR head, for expanding a hunk boundary the patch left out.
    let fileText: (String) async -> String?
    /// Only used to resolve each file's language for syntax coloring.
    let repoRoot: String
    @ObservedObject var settings: AppSettings
    /// Esc closes the whole PR detail (there's no per-file overlay to pop back to).
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var selection: String?

    /// The changed-files rail width for a given pane width — a third of the pane, clamped so neither
    /// the list (deep PR paths) nor the diff starves as the right section resizes. Fixed-width rails
    /// force an all-or-nothing breakpoint; scaling it lets side-by-side engage far sooner.
    private static func railWidth(for paneWidth: CGFloat) -> CGFloat {
        min(280, max(190, paneWidth * 0.32))
    }
    /// Below this the file list and a usable diff can't both fit, so the view collapses to a single
    /// navigable column (list → tap → diff → back) — the same master→detail idiom the issue/PR detail
    /// (and the whole inspector) already uses. Driven purely by the *right section's* own width, so
    /// widening the inspector — or maximizing — brings the list back beside the diff.
    private static let sideBySideMinWidth: CGFloat = 500

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width >= Self.sideBySideMinWidth {
                    sideBySide(railWidth: Self.railWidth(for: geo.size.width))
                } else {
                    narrow
                }
            }
            .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        }
        .onExitCommand(perform: onClose)
        // Select the first file on open (and if the set changes under us). Assigned directly — not
        // through the list's selection binding — so this initial pick isn't treated as a drill-in and
        // narrow mode still opens on the list.
        .onAppear { if selection == nil { selection = files.first?.path } }
    }

    // MARK: Layouts

    /// Wide: GitHub Desktop's side-by-side — the file list rail beside the selected file's diff.
    private func sideBySide(railWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            fileList(onSelect: { _ in })
                .frame(width: railWidth)
                .background(Color(nsColor: settings.terminalBackgroundColor).opacity(0.4))
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Narrow: no room for a list rail beside a readable diff, so every file's diff stacks in one
    /// continuous scroll (github.com "Files changed"), the files separated by full-width headers —
    /// you see *all* the files, not one at a time, and selection / ⌘F run across the whole set.
    private var narrow: some View {
        StackedDiffBody(
            files: files, patches: patches, fileText: fileText, repoRoot: repoRoot,
            settings: settings, onClose: onClose
        )
    }

    // MARK: List rail

    private func fileList(onSelect: @escaping (String) -> Void) -> some View {
        // A custom binding so a user's row tap (which flows through `set`) can drive narrow-mode
        // navigation, while the programmatic initial pick and the arrow `walk` assign `selection`
        // directly and don't — and without a row tap gesture, which would break List selection.
        let selectionBinding = Binding<String?>(
            get: { selection },
            set: { newValue in
                selection = newValue
                if let newValue { onSelect(newValue) }
            }
        )
        return List(files, selection: selectionBinding) { change in
            PRFileRow(
                change: change,
                font: settings.interfaceFont,
                chrome: settings.chromeTheme(for: colorScheme),
                isSelected: selection == change.path
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, let change = files.first(where: { $0.path == selection }) {
            PRFileDiffBody(
                change: change,
                patch: patches[change.path],
                fileText: fileText,
                repoRoot: repoRoot,
                settings: settings,
                onClose: onClose,
                onWalk: walk
            )
            // Rebuild for each file so the diff, syntax colors, and scroll reset cleanly.
            .id(change.path)
        } else {
            PaneEmptyState(
                localized("No File Selected"),
                icon: .fileDoc,
                message: localized("Pick a file on the left to see its changes.")
            )
        }
    }

    /// Left/right arrow (from the diff) steps the selected file — Quick Look's walk.
    private func walk(_ delta: Int) -> Bool {
        guard let current = selection,
              let index = files.firstIndex(where: { $0.path == current }) else {
            return false
        }
        let next = index + delta
        guard next >= 0, next < files.count else { return false }
        selection = files[next].path
        return true
    }
}

// MARK: - One file's diff (from an API patch)

/// The right pane: one file's diff, parsed from the GitHub API `patch` (no git) and
/// rendered by the shared `DiffTextPane`. A compact header names the file; a binary or
/// oversized file (no patch) shows a note instead.
private struct PRFileDiffBody: View {
    let change: GitChange
    let patch: String?
    /// Reads the file at the PR head. GitHub's patch carries three lines of context, so a
    /// hunk boundary can only be opened from the file itself; until this lands the bands
    /// draw inert, the way GitHub Desktop draws a gap it cannot expand.
    let fileText: (String) async -> String?
    let repoRoot: String
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void
    let onWalk: (Int) -> Bool

    @Environment(\.colorScheme) private var colorScheme

    @State private var rows: [DiffRow] = []
    @State private var gapText: DiffGapText = .unavailable
    @State private var document: DiffDocument?
    @State private var styledLines: [Int: NSAttributedString] = [:]
    @State private var expansion = DiffExpansion()
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(nsColor: settings.terminalBackgroundColor))
        // The diff view owns the keys once mounted; these cover the loading / note states.
        .focusable()
        .focusEffectDisabled()
        .onExitCommand(perform: onClose)
        .onKeyPress(.leftArrow) { onWalk(-1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { onWalk(+1) ? .handled : .ignored }
        .task(id: change.path) { await load() }
        .task(id: colorScheme) {
            guard !rows.isEmpty else { return }
            rebuildDocument()
            await buildStyledLines(rows)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(change.status.letter)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(change.status.tint)
                .frame(width: 16)
            Text(change.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if !change.directory.isEmpty {
                Text(change.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                if change.additions > 0 { Text("+\(change.additions)").foregroundStyle(.green) }
                if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(.red) }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: GitChangesView.topBarHeight)
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document {
            DiffTextPane(
                document: document,
                styled: styledLines,
                font: settings.resolvedTerminalFont(),
                thickenGlyphs: settings.fontThicken,
                backgroundColor: settings.terminalBackgroundColor,
                numberColor: settings.gutterInk(for: colorScheme),
                onExpand: { anchor, direction in
                    expansion.reveal(anchor, direction)
                    rebuildDocument()
                },
                onWalk: onWalk,
                onClose: onClose
            )
        } else {
            PaneEmptyState(
                change.isBinary ? localized("Binary File") : localized("No Diff"),
                icon: .fileDoc,
                message: change.isBinary
                    ? localized("This file is binary — open it on GitHub to view.")
                    : localized("This diff is too large to show here — open the file on GitHub.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        guard let patch, !patch.isEmpty else {
            rows = []
            document = nil
            isLoading = false
            return
        }
        let parsed = await GitService.parseDiffText(patch)
        rows = parsed
        rebuildDocument()
        isLoading = false
        await loadGapText()
        await buildStyledLines(parsed)
    }

    /// The palette is baked into the document (opaque tints, mixed against the terminal
    /// background), so an appearance flip needs a rebuild rather than re-resolving itself.
    private func rebuildDocument() {
        document = rows.isEmpty
            ? nil
            : DiffDocument.build(rows: rows, expansion: expansion,
                                 palette: settings.diffPalette(for: colorScheme),
                                 codeFont: settings.resolvedTerminalFont(),
                                 lineSpacing: settings.codeLineSpacing(for: settings.resolvedTerminalFont()),
                                 gapText: gapText)
    }


    /// One read per opened file, behind the diff so the patch renders immediately. A file
    /// that comes back empty (binary, too large, no access) leaves `gapText` unavailable.
    private func loadGapText() async {
        guard gapText.isEmpty, let text = await fileText(change.path) else { return }
        gapText = DiffGapText(fileLines: text.components(separatedBy: "\n"))
        rebuildDocument()
    }

    private func buildStyledLines(_ rows: [DiffRow]) async {
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(change.path)
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
        styledLines = styled.byRow
    }
}

// MARK: - Stacked multi-file diff (narrow mode)

/// Narrow mode's right section: GitHub's "Files changed" — each changed file is its own collapsible
/// card, stacked in one outer scroll. The card's header is real SwiftUI (so the path sits flush-left
/// and the header visually owns the diff beneath it, as one bordered unit); the diff body reuses the
/// shared `DiffTextPane` in embedded, content-sized mode, so the outer list — not each pane — scrolls.
private struct StackedDiffBody: View {
    let files: [GitChange]
    let patches: [String: String]
    /// Reads a file at the PR head, for expanding a hunk boundary the patch left out.
    let fileText: (String) async -> String?
    let repoRoot: String
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void

    /// Paths of the files folded shut.
    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(files, id: \.path) { change in
                    FileDiffCard(
                        change: change,
                        patch: patches[change.path],
                        fileText: fileText,
                        repoRoot: repoRoot,
                        settings: settings,
                        collapsed: collapsed.contains(change.path),
                        onToggle: {
                            if collapsed.contains(change.path) { collapsed.remove(change.path) }
                            else { collapsed.insert(change.path) }
                        },
                        onClose: onClose
                    )
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .onExitCommand(perform: onClose)
    }
}

/// One file as a collapsible card: a flush-left header bar (chevron, status letter, path, `+/−`) over
/// the file's diff. Collapsed shows only the header; expanded lazily parses the patch and renders it
/// in an embedded `DiffTextPane` sized to its content, so the outer list owns the scroll.
private struct FileDiffCard: View {
    let change: GitChange
    let patch: String?
    let fileText: (String) async -> String?
    let repoRoot: String
    @ObservedObject var settings: AppSettings
    let collapsed: Bool
    let onToggle: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var rows: [DiffRow] = []
    @State private var gapText: DiffGapText = .unavailable
    @State private var document: DiffDocument?
    @State private var styledLines: [Int: NSAttributedString] = [:]
    @State private var expansion = DiffExpansion()
    @State private var contentHeight: CGFloat = 0
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                diffBody
            }
        }
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        // Parse lazily — only when the card is (or becomes) expanded.
        .task(id: collapsed) {
            if !collapsed, !loaded { await load() }
        }
        .task(id: colorScheme) {
            guard !rows.isEmpty else { return }
            rebuildDocument()
            await buildStyled(rows)
        }
    }

    /// The title bar — the whole row toggles the fold; the disclosure chevron mirrors the state.
    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 11)
                Text(change.status.letter)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(change.status.tint)
                Text(change.path)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    if change.additions > 0 { Text("+\(change.additions)").foregroundStyle(.green) }
                    if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(.red) }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.05))
        }
        .buttonStyle(.plain)
        .help(change.path)
    }

    @ViewBuilder
    private var diffBody: some View {
        if let document {
            DiffTextPane(
                document: document,
                styled: styledLines,
                font: settings.resolvedTerminalFont(),
                thickenGlyphs: settings.fontThicken,
                backgroundColor: settings.terminalBackgroundColor,
                numberColor: settings.gutterInk(for: colorScheme),
                onExpand: { anchor, direction in
                    expansion.reveal(anchor, direction)
                    rebuildDocument()
                },
                onWalk: { _ in false },
                onClose: onClose,
                embedded: true,
                onContentHeight: { contentHeight = $0 }
            )
            .frame(height: max(contentHeight, 24))
        } else if !loaded {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity).frame(height: 44)
        } else {
            Text(change.isBinary
                 ? localized("Binary file — open it on GitHub to view.")
                 : localized("This diff is too large to show here — open the file on GitHub."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    private func load() async {
        loaded = true
        guard let patch, !patch.isEmpty else { rows = []; document = nil; return }
        let parsed = await GitService.parseDiffText(patch)
        rows = parsed
        document = parsed.isEmpty
            ? nil
            : DiffDocument.build(rows: parsed, expansion: expansion,
                                 palette: settings.diffPalette(for: colorScheme),
                                 codeFont: settings.resolvedTerminalFont(),
                                 lineSpacing: settings.codeLineSpacing(for: settings.resolvedTerminalFont()),
                                 gapText: gapText)
        await loadGapText()
        await buildStyled(parsed)
    }

    private func rebuildDocument() {
        document = DiffDocument.build(rows: rows, expansion: expansion, palette: settings.diffPalette(for: colorScheme),
                                      codeFont: settings.resolvedTerminalFont(),
                                      lineSpacing: settings.codeLineSpacing(for: settings.resolvedTerminalFont()),
                                      gapText: gapText)
    }

    /// One read per opened card, behind the diff so the patch renders immediately.
    private func loadGapText() async {
        guard gapText.isEmpty, let text = await fileText(change.path) else { return }
        gapText = DiffGapText(fileLines: text.components(separatedBy: "\n"))
        rebuildDocument()
    }

    private func buildStyled(_ parsed: [DiffRow]) async {
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(change.path)
        guard let language = FileEditorView.highlightLanguage(for: url) else { return }
        let code = parsed.filter { $0.kind != .hunk }
        guard code.count <= 8000, code.reduce(0, { $0 + $1.text.count }) <= 600_000 else { return }
        let styled = await DiffHighlighter.shared.styledLines(
            newSide: code.filter { $0.kind == .context || $0.kind == .addition },
            oldSide: code.filter { $0.kind == .context || $0.kind == .deletion },
            language: language,
            theme: colorScheme == .dark ? "xcode-dark" : "xcode",
            font: settings.resolvedTerminalFont()
        )
        guard !Task.isCancelled else { return }
        styledLines = styled.byRow
    }
}

// MARK: - File row

/// A PR file row: the Changes list's visual language (status letter, name, dimmed
/// directory, `+A −D`) without the working-tree affordances — the files aren't local.
private struct PRFileRow: View {
    let change: GitChange
    let font: Font
    let chrome: ChromeTheme?
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(change.status.letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(change.status.tint)
                .frame(width: 14)
            Text(change.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !change.directory.isEmpty {
                Text(change.directory)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                if change.additions > 0 { Text("+\(change.additions)").foregroundStyle(.green) }
                if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(.red) }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .opacity(0.85)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(OutlineViewFixups())
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(
            SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isSelected)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
    }
}
