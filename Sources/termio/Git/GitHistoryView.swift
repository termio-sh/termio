import SwiftUI

// MARK: - History tab

/// The git pane's **History** tab: the branch's recent commits, newest first. Tapping a
/// commit expands its file list inline (GitHub Desktop's commit → files → diff drill-down,
/// folded into one narrow column); tapping a file opens that commit's diff over the
/// terminal via the shared `store.openDiff` overlay. Read-only — history is for reading,
/// not editing.
struct GitHistoryView: View {
    @EnvironmentObject var store: TermioStore
    @ObservedObject var model: GitPanelModel

    let repoRoot: String
    let chrome: ChromeTheme?
    let font: Font

    /// The single expanded commit (one at a time keeps the narrow column legible).
    @State private var expanded: String?
    /// Files per commit, fetched lazily on first expand and kept for the session.
    @State private var filesByCommit: [String: [GitChange]] = [:]

    var body: some View {
        Group {
            if model.isLoadingHistory && model.commits.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.commits.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock",
                    description: Text("This branch has no commits yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    // No separators: fixed-height rows + the hover/selection wash do the
                    // separating, like a modern SwiftUI List (hairlines between every row
                    // read as legacy chrome in a narrow pane).
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.commits) { commit in
                            CommitRow(commit: commit, isExpanded: expanded == commit.sha, chrome: chrome, font: font) {
                                toggle(commit)
                            }
                            if expanded == commit.sha {
                                commitFiles(commit)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The changed-file rows shown under an expanded commit — a loading placeholder until
    /// the fetch lands, then one clickable row per file.
    @ViewBuilder
    private func commitFiles(_ commit: GitCommit) -> some View {
        if let files = filesByCommit[commit.sha] {
            if files.isEmpty {
                Text("No file changes")
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
                        isSelected: store.openDiff?.commit == commit.sha && store.openDiff?.change.path == file.path
                    ) {
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
                    Text(commit.subject)
                        .font(font)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        CommitAvatar(author: commit.author, chrome: chrome)
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

/// A small circular initials avatar riding in the metadata line (GitHub Desktop's
/// placement — a 24pt leading avatar column read as a loud repeated stripe when one
/// author dominates). Filled in the chrome accent so it derives from the terminal theme
/// like the rest of termio's chrome (one source of color truth) rather than a per-author
/// rainbow hue.
private struct CommitAvatar: View {
    let author: String
    let chrome: ChromeTheme?

    var body: some View {
        Circle()
            .fill((chrome?.accent ?? .accentColor).gradient)
            .frame(width: 15, height: 15)
            .overlay(
                Text(initials)
                    .font(.system(size: 6.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .help(author)
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
