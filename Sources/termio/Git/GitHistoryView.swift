import SwiftUI
import TermioShared

// MARK: - History tab

/// The git pane's **History** tab: the branch's recent commits, newest first. Tapping a
/// commit expands its file list inline (GitHub Desktop's commit → files → diff drill-down,
/// folded into one narrow column); tapping a file opens that commit's diff over the
/// terminal via the shared `store.openDiff` overlay. Read-only — history is for reading,
/// not editing.
struct GitHistoryView: View {
    @ObservedObject var model: GitPanelModel

    let repoRoot: String
    let chrome: ChromeTheme?
    let font: Font

    var body: some View {
        Group {
            if model.isLoadingHistory && model.commits.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.commits.isEmpty {
                PaneEmptyState(
                    localized("No History"),
                    icon: .clock,
                    message: localized("This branch has no commits yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    CommitList(commits: model.commits, repoRoot: repoRoot, chrome: chrome, font: font)
                        .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Compare tab

/// The git pane's **Compare** tab: this branch measured against the branch it would be
/// merged into — the pull request you are about to open, before you open it. The files come
/// from a three-dot diff, so the list matches what the forge will show, and each row opens
/// that file's diff over the terminal. The commits below are the ones the merge would bring.
///
/// A tab of its own rather than a mode hidden inside History: preparing a pull request is
/// what you do at the end of a branch, and it should not be reachable only by knowing that
/// History has a picker in it.
struct GitCompareView: View {
    @EnvironmentObject var store: TermioStore
    @ObservedObject var model: GitPanelModel

    let repoRoot: String
    let chrome: ChromeTheme?
    let font: Font

    /// The last file diff opened from this list — its row keeps the selected grey after the
    /// overlay closes (the Issues list's rule), so coming back from a full-screen diff still
    /// shows which file it was.
    @State private var lastOpenedPath: String?
    /// Whether the file list is unfolded. Open by default: with a base picked, the files
    /// *are* what you came to read.
    @State private var filesExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            CompareBar(model: model, chrome: chrome, onPick: pick)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // ← / → walk the open overlay across the files; the last-opened memory chases the
        // shown file so the grey lands on the right row on close.
        .onChange(of: store.openDiff) { _, request in
            if let request, request.range != nil { lastOpenedPath = request.change.path }
        }
        .task {
            if model.compareContext == nil { await model.loadCompareContext() }
            await restoreBase()
        }
        // A checkout in the terminal moves the branch under the pane, and the base is
        // remembered per branch — so the comparison follows the checkout instead of
        // measuring the new branch against the old branch's base.
        .onChange(of: model.compareContext?.branch) { _, _ in
            dropOpenRangeDiff()
            Task { await restoreBase() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let context = model.compareContext, context.remoteBranches.isEmpty, context.localBranches.isEmpty {
            PaneEmptyState(
                localized("Nothing to Compare"),
                icon: .gitBranch,
                message: localized("This checkout has no other branch to compare with.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let problem = model.compareProblem {
            switch problem {
            case .missingBase:
                PaneEmptyState(
                    localized("Base Branch Missing"),
                    icon: .gitBranch,
                    message: localized("Choose another branch to compare with.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noCommonHistory:
                PaneEmptyState(
                    localized("No Common History"),
                    icon: .gitBranch,
                    message: localized("This branch and the base branch share no commits.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if model.compareContext != nil, model.compareBase == nil {
            PaneEmptyState(
                localized("No Base Branch"),
                icon: .gitBranch,
                message: localized("Pick the branch this one would merge into.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let compare = model.compare {
            if compare.files.isEmpty, compare.commits.isEmpty {
                // True whether the two are even or this branch is simply behind — saying
                // "even" would contradict the Behind chip in the bar right above.
                PaneEmptyState(
                    localized("No Changes"),
                    icon: .gitBranch,
                    message: localized("This branch has nothing the base branch doesn’t already have.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    // No separators: fixed-height rows + the hover/selection wash do the
                    // separating, like a modern SwiftUI List (hairlines between every row
                    // read as legacy chrome in a narrow pane).
                    LazyVStack(alignment: .leading, spacing: 0) {
                        compareFiles(compare)
                        SectionLabel(title: localized("Commits"), count: compare.commits.count)
                        CommitList(commits: compare.commits, repoRoot: repoRoot, chrome: chrome, font: font)
                    }
                    // No top inset: the summary row is the file list's header and butts
                    // against the compare bar's hairline. Inset it and the gap reads as a
                    // stray empty band above a highlighted row.
                    .padding(.bottom, 6)
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Drops a diff opened from an earlier comparison. Its request carries the old
    /// `base...HEAD` range, so leaving it up would show one base's diff beside another
    /// base's file list.
    private func dropOpenRangeDiff() {
        if store.openDiff?.range != nil { store.openDiff = nil }
        lastOpenedPath = nil
    }

    /// Applies the base remembered for the current branch, falling back to the suggested
    /// one the first time a branch is seen — so a feature branch opens already compared
    /// against the trunk it would merge into.
    private func restoreBase() async {
        guard let context = model.compareContext else { return }
        let remembered = store.gitCompareBases[
            TermioStore.compareBaseKey(repoRoot: repoRoot, branch: context.branch)]
        // An empty remembered value is the user having turned the comparison off.
        let base: String? = remembered.map { $0.isEmpty ? nil : $0 } ?? context.suggestedBase
        await model.setCompareBase(base)
    }

    private func pick(_ base: String?) {
        guard let context = model.compareContext else { return }
        store.gitCompareBases[
            TermioStore.compareBaseKey(repoRoot: repoRoot, branch: context.branch)] = base ?? ""
        filesExpanded = true
        dropOpenRangeDiff()
        Task { await model.setCompareBase(base) }
    }

    /// The comparison's changed files: a foldable summary row over the same file rows the
    /// commit drill-down uses, each opening the file's three-dot diff across the range —
    /// the same diff the forge will show on the pull request.
    @ViewBuilder
    private func compareFiles(_ compare: GitService.BranchCompare) -> some View {
        let range = "\(compare.base)...HEAD"
        CompareSummaryRow(
            files: compare.files, isExpanded: filesExpanded, chrome: chrome, font: font
        ) {
            filesExpanded.toggle()
        }
        if filesExpanded {
            ForEach(compare.files) { file in
                CommitFileRow(
                    change: file,
                    font: font,
                    chrome: chrome,
                    isSelected: (store.openDiff?.range == range
                        && store.openDiff?.change.path == file.path)
                        || (store.openDiff == nil && lastOpenedPath == file.path)
                ) {
                    lastOpenedPath = file.path
                    store.openDiff = GitDiffRequest(repoRoot: repoRoot, change: file,
                                                    range: range, siblings: compare.files)
                }
            }
        }
    }
}

// MARK: - Commit list

/// The commit rows shared by History (the branch's own commits) and Compare (the commits a
/// merge would bring over): one expandable row per commit, its files underneath.
private struct CommitList: View {
    @EnvironmentObject var store: TermioStore

    let commits: [GitCommit]
    let repoRoot: String
    let chrome: ChromeTheme?
    let font: Font

    /// The single expanded commit (one at a time keeps the narrow column legible).
    @State private var expanded: String?
    /// Files per commit, fetched lazily on first expand and kept for the session.
    @State private var filesByCommit: [String: [GitChange]] = [:]
    /// The last file diff opened from this list, so its row keeps the selected grey after
    /// the overlay closes.
    @State private var lastOpenedFile: (sha: String, path: String)?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(commits) { commit in
                CommitRow(commit: commit, isExpanded: expanded == commit.sha, chrome: chrome, font: font) {
                    toggle(commit)
                }
                if expanded == commit.sha {
                    commitFiles(commit)
                }
            }
        }
        // ← / → walk the open overlay across the commit's files; the last-opened
        // memory chases the shown file so the grey lands on the right row on close.
        .onChange(of: store.openDiff) { _, request in
            if let request, let sha = request.commit {
                lastOpenedFile = (sha, request.change.path)
            }
        }
    }

    /// The changed-file rows shown under an expanded commit — a loading placeholder until
    /// the fetch lands, then one clickable row per file.
    @ViewBuilder
    private func commitFiles(_ commit: GitCommit) -> some View {
        if let files = filesByCommit[commit.sha] {
            if files.isEmpty {
                Text(localized("No file changes"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 24)
                    .padding(.vertical, 4)
            } else {
                ForEach(files) { file in
                    CommitFileRow(
                        change: file,
                        font: font,
                        chrome: chrome,
                        isSelected: (store.openDiff?.commit == commit.sha
                            && store.openDiff?.change.path == file.path)
                            || (store.openDiff == nil
                                && lastOpenedFile?.sha == commit.sha
                                && lastOpenedFile?.path == file.path)
                    ) {
                        lastOpenedFile = (commit.sha, file.path)
                        store.openDiff = GitDiffRequest(repoRoot: repoRoot, change: file,
                                                        commit: commit.sha, siblings: files)
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.leading, 24)
                .padding(.vertical, 4)
        }
    }

    private func toggle(_ commit: GitCommit) {
        if expanded == commit.sha {
            expanded = nil
            return
        }
        expanded = commit.sha
        if filesByCommit[commit.sha] == nil {
            Task {
                let files = await GitService.commitChanges(commit.sha, in: repoRoot)
                filesByCommit[commit.sha] = files
            }
        }
    }
}

// MARK: - Compare bar

/// The base-branch picker above the file list, GitHub Desktop's "Compare to branch": which
/// branch this one would be merged into. Bases are listed remote-first — a stale local
/// `main` in a long-lived clone would overstate the diff — and the trailing chip says when
/// the base has moved on since the last fetch, since nothing here fetches on its own.
///
/// No hairline under it: the mode switch above draws none either, and over an empty state
/// a rule with nothing beneath it reads as a stray line rather than a boundary.
private struct CompareBar: View {
    @ObservedObject var model: GitPanelModel
    let chrome: ChromeTheme?
    let onPick: (String?) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                if model.compareBase != nil {
                    Button(localized("Don’t Compare")) { onPick(nil) }
                    Divider()
                }
                if let context = model.compareContext {
                    // Already filtered of the checkout's own branch and its upstream.
                    let remotes = pinned(context.remoteBranches, first: context.suggestedBase)
                    let locals = pinned(context.localBranches, first: context.suggestedBase)
                    if !remotes.isEmpty {
                        Section(localized("Remote")) {
                            ForEach(remotes, id: \.self) { branch in
                                Button(branch) { onPick(branch) }
                            }
                        }
                    }
                    if !locals.isEmpty {
                        Section(localized("Local")) {
                            ForEach(locals, id: \.self) { branch in
                                Button(branch) { onPick(branch) }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    HugeIconView(icon: .gitBranch, size: 10, color: .secondary)
                    Text(model.compareBase ?? localized("Compare to branch"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.compareBase == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .frame(height: 21)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .help(localized("Compare this branch with the branch it would merge into."))

            Spacer(minLength: 4)

            if let compare = model.compare, compare.behind > 0 {
                Text(verbatim: "\(localized("Behind")) (\(compare.behind))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                    .help(localized("The base branch has commits this branch doesn’t have, as of the last fetch."))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    /// Lifts the branch this checkout would actually merge into to the top of its section.
    /// The rest stay in `for-each-ref`'s alphabetical order, where a repo with a hundred
    /// remote branches buries `origin/main` under every `origin/agent/…` ever pushed.
    private func pinned(_ branches: [String], first: String?) -> [String] {
        guard let first, let index = branches.firstIndex(of: first) else { return branches }
        var rest = branches
        rest.remove(at: index)
        return [first] + rest
    }
}

/// The comparison's header row: how many files the merge would touch and the totals, over
/// the file list it folds open. Shaped like a commit row so the two read as one list, but
/// it only lifts on hover — a permanent selection wash would compete with the real
/// selection on the file rows underneath.
private struct CompareSummaryRow: View {
    let files: [GitChange]
    let isExpanded: Bool
    let chrome: ChromeTheme?
    let font: Font
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(localized("Files changed"))
                    .font(font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: "\(files.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                // Binary files report no counts, so the totals are of what git measured.
                let additions = files.reduce(0) { $0 + $1.additions }
                let deletions = files.reduce(0) { $0 + $1.deletions }
                if additions > 0 { Text(verbatim: "+\(additions)").foregroundStyle(.green) }
                if deletions > 0 { Text(verbatim: "−\(deletions)").foregroundStyle(.red) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A quiet divider label between the comparison's files and its commits.
private struct SectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Text(verbatim: "\(count)")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One commit, GitHub Desktop-style: the subject on a single truncated line (every row
/// the same height — a big leading avatar and wrapping subjects made the list ragged),
/// with a small avatar + `author · when · sha` muted underneath. The sha is tertiary,
/// not accent: accent is reserved for selection so the list stays quiet. A chevron
/// fades in on hover and turns down when expanded. Hover / expanded lift use the app's
/// shared `SidebarRowHighlight` (the same accent wash as the sidebar and file tree).
private struct CommitRow: View {
    let commit: GitCommit
    let isExpanded: Bool
    let chrome: ChromeTheme?
    let font: Font
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(commit.subject)
                            .font(font)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // Tag chips mark release boundaries (termio releases by tagging
                        // main); rare enough that they may squeeze the subject.
                        ForEach(commit.tags, id: \.self) { tag in
                            TagChip(name: tag)
                                .layoutPriority(1)
                        }
                    }
                    HStack(spacing: 5) {
                        CommitAvatar(author: commit.author, email: commit.authorEmail, chrome: chrome)
                        Text(commit.author)
                            .lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                        Text(commit.relativeDate)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text("·").foregroundStyle(.tertiary)
                        Text(commit.shortSHA)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .layoutPriority(1)
                        if commit.isUnpushed {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .layoutPriority(1)
                                .help(localized("Not pushed to upstream"))
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(isHovering || isExpanded ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(SidebarRowHighlight(isSelected: isExpanded, isHovering: isHovering, chrome: chrome))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(commit.subject)
    }
}

/// A quiet outlined capsule naming a tag that points at the commit — a release
/// boundary in the history, since termio cuts releases by tagging main.
private struct TagChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
    }
}

/// A small circular avatar riding in the metadata line (GitHub Desktop's placement —
/// a 24pt leading avatar column read as a loud repeated stripe when one author
/// dominates). The author's real GitHub avatar when `CommitAvatarStore` resolves one
/// from the commit email; otherwise an initials circle filled in the chrome accent so
/// it derives from the terminal theme like the rest of termio's chrome (one source of
/// color truth) rather than a per-author rainbow hue.
private struct CommitAvatar: View {
    let author: String
    let email: String
    let chrome: ChromeTheme?

    @State private var avatar: NSImage?

    var body: some View {
        Group {
            if let avatar {
                Image(nsImage: avatar)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 15, height: 15)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill((chrome?.accent ?? .accentColor).gradient)
                    .frame(width: 15, height: 15)
                    .overlay(
                        Text(initials)
                            .font(.system(size: 6.5, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .help(author)
        .task(id: email) {
            guard avatar == nil,
                  let data = await CommitAvatarStore.shared.imageData(for: email) else { return }
            avatar = NSImage(data: data)
        }
    }

    private var initials: String {
        let words = author.split { !$0.isLetter }
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// One file inside an expanded commit: indented under the commit, status letter + name +
/// `+/−` counts, opening the commit-scoped diff when clicked.
private struct CommitFileRow: View {
    let change: GitChange
    let font: Font
    let chrome: ChromeTheme?
    let isSelected: Bool
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Text(change.status.letter)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(change.status.tint)
                    .frame(width: 12)
                Text(change.name)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(change.status == .deleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer(minLength: 6)
                if change.additions > 0 { Text("+\(change.additions)").foregroundStyle(.green) }
                if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(.red) }
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .padding(.leading, 24)
            .padding(.trailing, 14)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering, chrome: chrome)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(change.path)
    }
}
