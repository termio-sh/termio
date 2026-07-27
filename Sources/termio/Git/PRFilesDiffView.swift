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
    /// Only used to resolve each file's language for syntax coloring.
    let repoRoot: String
    @ObservedObject var settings: AppSettings
    /// Esc closes the whole PR detail (there's no per-file overlay to pop back to).
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: String?

    /// The list rail's width — the changed-files column, a touch wider than the sidebar
    /// since PR paths run deep.
    private static let listWidth: CGFloat = 260

    var body: some View {
        HStack(spacing: 0) {
            fileList
                .frame(width: Self.listWidth)
                .background(Color(nsColor: settings.terminalBackgroundColor).opacity(0.4))
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        .onExitCommand(perform: onClose)
        // Select the first file on open (and if the set changes under us).
        .onAppear { if selection == nil { selection = files.first?.path } }
    }

    // MARK: List rail

    private var fileList: some View {
        List(files, selection: $selection) { change in
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
                repoRoot: repoRoot,
                settings: settings,
                onClose: onClose,
                onWalk: walk
            )
            // Rebuild for each file so the diff, syntax colors, and scroll reset cleanly.
            .id(change.path)
        } else {
            ContentUnavailableView(
                "No File Selected",
                huge: .fileDoc,
                description: Text("Pick a file on the left to see its changes.")
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
    let repoRoot: String
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void
    let onWalk: (Int) -> Bool

    @Environment(\.colorScheme) private var colorScheme

    @State private var rows: [DiffRow] = []
    @State private var document: DiffDocument?
    @State private var styledLines: [Int: NSAttributedString] = [:]
    @State private var expanded: Set<Int> = []
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
                backgroundColor: settings.terminalBackgroundColor,
                numberColor: settings.gutterInk(for: colorScheme),
                onExpand: { id in
                    expanded.insert(id)
                    self.document = DiffDocument.build(
                        rows: rows, expanded: expanded,
                        codeFont: settings.resolvedTerminalFont())
                },
                onWalk: onWalk,
                onClose: onClose
            )
        } else {
            ContentUnavailableView(
                change.isBinary ? "Binary File" : "No Diff",
                huge: .fileDoc,
                description: Text(change.isBinary
                    ? "This file is binary — open it on GitHub to view."
                    : "This diff is too large to show here — open the file on GitHub.")
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
        document = parsed.isEmpty
            ? nil
            : DiffDocument.build(rows: parsed, expanded: expanded,
                                 codeFont: settings.resolvedTerminalFont())
        isLoading = false
        await buildStyledLines(parsed)
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
        styledLines = styled
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
        .background(OutlineSelectionStyleStripper())
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
