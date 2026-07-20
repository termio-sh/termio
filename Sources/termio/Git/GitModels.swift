import Foundation
import SwiftUI

// MARK: - Models

/// Which inspector pane the trailing column is showing — the file tree, the file
/// search, the git changes list, or the session Info pane. Drives the segmented
/// switch at the top of `FileBrowserView`.
enum InspectorTab: Hashable, Sendable {
    case files, search, changes, info
}

/// The git pane's own inner switch: the working-tree changes, or the commit
/// history — GitHub Desktop's Changes / History split. Committing lives in the
/// terminal; the GUI is for staging, reviewing diffs, and reading history.
enum GitPaneMode: Hashable, Sendable {
    case changes, history
}

/// One changed file in the working tree, as reported by `git status`. `path` is
/// POSIX, relative to the repo root (so it may contain `/`); `name` is just the
/// last component for the row label and `directory` the dimmed remainder.
struct GitChange: Identifiable, Hashable, Sendable {
    let path: String
    let status: GitFileStatus
    let isUntracked: Bool
    var additions: Int = 0
    var deletions: Int = 0
    /// For a rename, the path the file moved *from* — surfaced in the row tooltip.
    var originalPath: String? = nil
    /// The change sits entirely in the index (nothing further in the worktree) —
    /// what `git commit` in the terminal would take right now.
    var isStaged: Bool = false
    /// `--numstat` reported `-` for the line counts, so `+`/`−` would be a lie.
    var isBinary: Bool = false

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// One commit in the branch's history, parsed from `git log`. Shown as a row in
/// the git pane's History tab; selecting it lists the files it touched, each of
/// which opens that commit's diff over the terminal.
struct GitCommit: Identifiable, Hashable, Sendable {
    /// Full 40-char SHA — used to fetch the commit's files and per-file diff.
    let sha: String
    /// Abbreviated SHA for the row label.
    let shortSHA: String
    let subject: String
    let author: String
    /// Human "3 hours ago" string straight from `git log --date=relative`.
    let relativeDate: String

    var id: String { sha }
}

/// The change kind shown as a single-letter badge, colored after GitHub Desktop /
/// swifty-diff: modified blue, added green, deleted red, renamed/copied orange,
/// untracked grey, conflicted yellow.
enum GitFileStatus: Hashable, Sendable {
    case modified, added, deleted, renamed, copied, untracked, conflicted

    init(code: Character) {
        switch code {
        case "M", "T": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "U": self = .conflicted
        case "?": self = .untracked
        default: self = .modified
        }
    }

    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .conflicted: return "!"
        case .untracked: return "U"
        }
    }

    var tint: Color {
        switch self {
        case .added: return .green
        case .deleted: return .red
        case .renamed, .copied: return .orange
        case .conflicted: return .yellow
        // An untracked file is a brand-new file, so it reads as additive — green,
        // like its `+` line count and the way VS Code marks a `U` in the explorer —
        // rather than a noisy grey `?` that looks like an error down the whole list.
        case .untracked: return .green
        case .modified: return .blue
        }
    }
}

/// A request to show the diff of one changed file over the terminal — the git
/// counterpart of `TermioStore.openFileURL`. Carries the repo root so the overlay
/// can run `git diff` for the file without re-deriving it.
struct GitDiffRequest: Hashable, Sendable {
    let repoRoot: String
    let change: GitChange
    /// When set, the overlay shows the file's diff *as of that commit*
    /// (`git show <sha>`) rather than the working-tree diff — the History tab's
    /// file rows carry the commit they belong to.
    var commit: String? = nil
    /// The ordered set the overlay walks with ← / → — the whole Changes list, or
    /// the files of the commit being read. Also feeds the header's "n of m".
    var siblings: [GitChange] = []

    var name: String { change.name }
}

/// One rendered line of a unified diff: an added/removed/context line (with its old
/// and/or new line number), or a hunk header (`@@ … @@`). The file-header lines of
/// the raw diff are dropped during parsing — the overlay shows the filename itself.
struct DiffRow: Identifiable, Sendable {
    enum Kind: Sendable { case addition, deletion, context, hunk }
    let id: Int
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
    /// The changed span within a paired deletion/addition line, in `Character`
    /// offsets — rendered with a stronger background so a one-word edit in a long
    /// line reads at a glance. `nil` when the line has no counterpart or the two
    /// sides share too little for a span to mean anything.
    var emphasis: Range<Int>? = nil
}
