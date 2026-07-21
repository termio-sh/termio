import AppKit
import SwiftUI

// MARK: - Git pane

/// The git pane, split into two tabs after GitHub Desktop: **Changes** (the working
/// tree's files; clicking a row opens its diff over the terminal) and **History** (past
/// commits and their diffs). Committing and pushing are deliberately left to the
/// terminal — the GUI is for reviewing and reading, not authoring commits. The mode
/// tabs sit at the top (they answer "what am I looking at"); the bottom bar carries the
/// list's totals and refresh (it answers "how much"). The list rows match the file tree
/// (same interface font and `SidebarRowHighlight`). All state lives in `GitPanelModel`.
struct GitChangesView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let repoRoot: String
    /// Lifted up to `FileBrowserView` so the switcher's Changes badge stays in step.
    @Binding var changeCount: Int

    @StateObject private var model: GitPanelModel

    /// Which of the two tabs is showing.
    @State private var mode: GitPaneMode = .changes

    /// Slides the mode switch's selection pill from the old segment to the new one.
    @Namespace private var pillNamespace

    /// Fixed height of the pane's top bar, shared with the diff overlay's file header
    /// (`GitDiffView`) so the two bars — and their bottom hairlines — line up across
    /// the terminal | inspector split.
    static let topBarHeight: CGFloat = 34

    /// The files a "Discard Changes…" action is waiting to confirm — non-nil while the
    /// destructive alert is up, so the actual `git restore`/delete only fires on "OK".
    @State private var pendingDiscard: [GitChange]?

    /// The list's selected rows, by path. Exactly one selected row opens its diff;
    /// several become the targets of the batch context-menu actions.
    @State private var selection = Set<String>()

    init(repoRoot: String, changeCount: Binding<Int>) {
        self.repoRoot = repoRoot
        self._changeCount = changeCount
        self._model = StateObject(wrappedValue: GitPanelModel(repoRoot: repoRoot))
    }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            switch mode {
            case .changes: changesBody
            case .history: GitHistoryView(model: model, repoRoot: repoRoot, chrome: chrome, font: settings.interfaceFont)
            }
            // Only Changes has a real total to report ("N files +A −D"). History's
            // count would just echo the fetch limit — meaningless, so no bar.
            if mode == .changes { bottomBar }
        }
        .task(id: repoRoot) { await model.load() }
        .task(id: mode) { if mode == .history { await model.loadHistory() } }
        .onChange(of: model.changes.count) { _, count in changeCount = count }
        .onChange(of: selection) { _, selected in
            if selected.count == 1, let change = model.changes.first(where: { $0.path == selected.first }) {
                open(change)
            } else if selected.count > 1, store.openDiff != nil {
                // A multi-selection has no single diff to show — drop the overlay.
                store.openDiff = nil
            }
        }
        // Follow the overlay both ways: ← / → walks inside it, so the list's selection
        // chases the shown file; on close, re-read (the user may have just acted on it)
        // and release a lone selection so clicking the same row reopens its diff. The
        // `openFileURL` guards keep a diff↔preview hand-off from reading as a close.
        .onChange(of: store.openDiff) { _, request in
            if let request, request.commit == nil, selection != [request.change.path] {
                selection = [request.change.path]
            }
            if request == nil, store.openFileURL == nil {
                Task { await model.load() }
                if selection.count == 1 { selection.removeAll() }
            }
        }
        .onChange(of: store.openFileURL) { _, url in
            if url == nil, store.openDiff == nil, selection.count == 1 { selection.removeAll() }
        }
        .alert("Discard Changes?", isPresented: discardAlertPresented, presenting: pendingDiscard) { changes in
            Button("Discard Changes", role: .destructive) { performDiscard(changes) }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { changes in
            Text(discardMessage(changes))
        }
    }

    // MARK: Chrome

    /// The pane's mode switch, pinned at the top over a hairline — GitHub Desktop's tab
    /// placement, drawn as a miniature of `InspectorTabsToolbar`'s segmented track (our
    /// own capsule track + a sliding Liquid Glass selection pill) so both switches in
    /// the inspector share one design language.
    private var topBar: some View {
        HStack(spacing: 0) {
            modeSwitch
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.topBarHeight)
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            segment("Changes", .changes)
            segment("History", .history)
        }
        // The selection pill rides behind the active segment and slides across on switch.
        .background { selectionPill }
        .padding(2.5)
        .background { trackBackground }
        // Scope the slide to this control so switching modes doesn't animate the pane
        // content swap below (same reasoning as `InspectorTabsToolbar`).
        .animation(.snappy(duration: 0.28), value: mode)
    }

    private func segment(_ title: String, _ value: GitPaneMode) -> some View {
        let active = mode == value
        // Constant weight: a semibold-on-select would re-measure the segment and make
        // the track jitter as the pill lands. Selection reads via .primary + the pill.
        return Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(height: 21)
            .matchedGeometryEffect(id: value, in: pillNamespace)
            .contentShape(.capsule)
            .onTapGesture { mode = value }
    }

    @ViewBuilder
    private var selectionPill: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .capsule)
                .matchedGeometryEffect(id: mode, in: pillNamespace, isSource: false)
        } else {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlColor))
                .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                .matchedGeometryEffect(id: mode, in: pillNamespace, isSource: false)
        }
    }

    @ViewBuilder
    private var trackBackground: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(Color.white.opacity(0.12)), in: .capsule)
        } else {
            Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
        }
    }

    /// Status strip under the content: what the visible list adds up to. There is no
    /// refresh control — the model watches the worktree and git dir and re-reads on
    /// its own (see `GitPanelModel.armWatcher`), the same invariant that lets IDEs
    /// ship without one.
    private var bottomBar: some View {
        HStack(spacing: 5) {
            summary
            Spacer(minLength: 8)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if !model.changes.isEmpty {
            let additions = model.changes.reduce(0) { $0 + $1.additions }
            let deletions = model.changes.reduce(0) { $0 + $1.deletions }
            Text("\(model.changes.count) \(model.changes.count == 1 ? "file" : "files")")
                .foregroundStyle(.secondary)
            if additions > 0 { Text("+\(additions)").foregroundStyle(.green) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(.red) }
        }
    }

    // MARK: Changes tab

    @ViewBuilder
    private var changesBody: some View {
        if model.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.changes.isEmpty {
            // Fill the pane (like the loading state) rather than sizing to the compact empty
            // view — otherwise the enclosing `VStack` shrinks to content height and the host
            // centers the whole pane instead of pinning the header to the top.
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("The working tree is clean.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            changeList
        }
    }

    private var changeList: some View {
        // A native `List` with a `selection:` binding — the same shape as the file tree
        // (`FileTreeList`). Selection drives "open the diff", which is what lets each row
        // be `.draggable` at the same time: a SwiftUI tap gesture would strangle the drag,
        // but List's AppKit-level selection coexists with it. The Set binding gives ⌘- and
        // ⇧-click multi-selection for free.
        List(model.changes, selection: $selection) { change in
            GitChangeRow(
                change: change,
                fileURL: fileURL(for: change),
                font: settings.interfaceFont,
                chrome: chrome,
                isSelected: selection.contains(change.path),
                onDiscard: { pendingDiscard = [change] }
            )
            .contextMenu { contextMenu(for: change) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        // ← / → walk the open diff from here too — the list usually holds focus
        // (↑ ↓ walk via selection), so the overlay's own keys alone wouldn't fire.
        .onKeyPress(.leftArrow) { walkOverlay(-1) }
        .onKeyPress(.rightArrow) { walkOverlay(+1) }
    }

    private func walkOverlay(_ delta: Int) -> KeyPress.Result {
        guard let next = store.openDiff?.neighbor(delta) else { return .ignored }
        store.openDiff = next
        return .handled
    }

    /// The row's menu acts on the whole selection when the clicked row is part of it,
    /// and on just that row otherwise — GitHub Desktop's rule.
    @ViewBuilder
    private func contextMenu(for change: GitChange) -> some View {
        let targets = targets(for: change)
        if targets.count == 1 {
            Button("Open in Editor") { openInEditor(change) }
            Button("Reveal in Finder") { revealInFinder(change) }
            Divider()
            Button("Copy Path") { copyPath(change) }
            Button("Copy Relative Path") { copyToPasteboard(change.path) }
            Button("Copy Diff") { copyDiff(targets) }
            Divider()
            Button("Discard Changes…", role: .destructive) { pendingDiscard = targets }
        } else {
            Button("Copy Paths") {
                copyToPasteboard(targets.map { fileURL(for: $0).path }.joined(separator: "\n"))
            }
            Button("Copy Relative Paths") {
                copyToPasteboard(targets.map(\.path).joined(separator: "\n"))
            }
            Button("Copy Diff") { copyDiff(targets) }
            Divider()
            Button("Discard \(targets.count) Files…", role: .destructive) { pendingDiscard = targets }
        }
    }

    private func targets(for change: GitChange) -> [GitChange] {
        guard selection.contains(change.path), selection.count > 1 else { return [change] }
        return model.changes.filter { selection.contains($0.path) }
    }

    private func open(_ change: GitChange) {
        // An image/SVG/PDF has no meaningful text diff, so show the file itself in the preview
        // overlay. A deleted file is gone from disk, so fall back to the diff (its empty result
        // is the honest one). The store's overlay didSets keep the two mutually exclusive.
        let url = fileURL(for: change)
        if FileActivation.previewsRatherThanDiff(url), FileManager.default.fileExists(atPath: url.path) {
            store.openFileInEditor(url)
        } else {
            store.openDiff = GitDiffRequest(repoRoot: repoRoot, change: change, siblings: model.changes)
        }
    }

    // MARK: Row actions

    /// Opens the file's editable buffer over the terminal (distinct from clicking the
    /// row, which shows its read-only diff).
    private func openInEditor(_ change: GitChange) {
        store.openFileInEditor(fileURL(for: change))
    }

    private func revealInFinder(_ change: GitChange) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: change)])
    }

    private func copyPath(_ change: GitChange) {
        copyToPasteboard(fileURL(for: change).path)
    }

    /// Puts the raw unified diff of every target on the pasteboard — ready to paste into
    /// an agent prompt ("fix this") or `git apply`. Order matches the list.
    private func copyDiff(_ changes: [GitChange]) {
        Task {
            var parts: [String] = []
            for change in changes {
                parts.append(await GitService.diffText(for: change, in: repoRoot))
            }
            copyToPasteboard(parts.joined())
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Runs the confirmed discard off the main thread, closes the diff overlay if it was
    /// showing one of the discarded files, then reloads so the rows drop out of the list.
    private func performDiscard(_ changes: [GitChange]) {
        pendingDiscard = nil
        Task {
            await GitService.discard(changes, in: repoRoot)
            if let open = store.openDiff, changes.contains(where: { $0.path == open.change.path }) {
                store.openDiff = nil
            }
            selection.removeAll()
            await model.load()
        }
    }

    /// The alert body: one file is named outright; a batch is enumerated up to ten
    /// names before collapsing to a count (GitHub Desktop's cap).
    private func discardMessage(_ changes: [GitChange]) -> String {
        if changes.count == 1, let only = changes.first {
            return "All changes to “\(only.name)” will be lost. This cannot be undone."
        }
        let listed = changes.prefix(10).map(\.name).joined(separator: "\n")
        let more = changes.count > 10 ? "\n…and \(changes.count - 10) more" : ""
        return "All changes to these \(changes.count) files will be lost. This cannot be undone.\n\n\(listed)\(more)"
    }

    private var discardAlertPresented: Binding<Bool> {
        Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } })
    }

    /// The absolute on-disk URL for a change — `git status` paths are repo-relative.
    private func fileURL(for change: GitChange) -> URL {
        URL(fileURLWithPath: repoRoot).appendingPathComponent(change.path)
    }
}

/// A single row in the changes list: a colored status letter, the file name with its
/// directory dimmed beside it (the path shrinks first; the name survives narrow widths),
/// and right-aligned `+adds −dels` — or a `binary` tag when line counts would lie — plus
/// a small dot when the change is fully staged. `.draggable` out as the file's URL.
/// Opening is the List's own `selection:` binding, not a tap gesture, which is what keeps
/// the drag immediate; the discard control is a `Button`, so it acts without triggering
/// the row's open-diff selection.
private struct GitChangeRow: View {
    let change: GitChange
    let fileURL: URL
    let font: Font
    let chrome: ChromeTheme?
    let isSelected: Bool
    /// Fires the discard confirmation for this row (owned by `GitChangesView`).
    let onDiscard: () -> Void

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
                .foregroundStyle(change.status == .deleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if !change.directory.isEmpty {
                Text(change.directory)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            // On hover the trailing counts give way to a single discard button — the
            // one destructive action worth a one-click affordance (everything else lives
            // in the right-click menu). The counts return when the pointer leaves.
            if isHovering {
                Button(action: onDiscard) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Discard Changes…")
            } else {
                HStack(spacing: 5) {
                    if change.isBinary {
                        Text("binary").foregroundStyle(.secondary)
                    } else {
                        if change.additions > 0 { Text("+\(change.additions)").foregroundStyle(.green) }
                        if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(.red) }
                    }
                    if change.isStaged {
                        Circle()
                            .fill(.green)
                            .frame(width: 5, height: 5)
                            .help("Staged — the next git commit takes this file")
                    }
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .opacity(0.85)
                // Counts never wrap or compress — when the row runs out of width the
                // dimmed directory is the one flexible element that gives way.
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(OutlineSelectionStyleStripper())
        .draggable(fileURL)
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
