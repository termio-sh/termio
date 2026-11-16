import TermioShared
import Foundation
import SwiftUI

// MARK: - Models

/// Which inspector pane the trailing column is showing — the file tree, the file
/// search, the git changes list, the issue tracker, the session Info pane, or the
/// live iOS Simulator. Drives the segmented switch at the top of `FileBrowserView`.
enum InspectorTab: String, Hashable, Sendable, Codable {
    case files, search, changes, issues, info, simulator
}

/// The git pane's own inner switch, in scope order: what isn't committed yet, what
/// this branch would merge into another (the pull request about to be opened), and
/// the commit history — GitHub Desktop's Changes / History split with its branch
/// comparison promoted beside them. Committing lives in the terminal; the GUI is for
/// staging, reviewing diffs, and reading history.
enum GitPaneMode: Hashable, Sendable {
    case changes, compare, history
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

/// Reading a device's status into the pane's own row type. An extension, not a
/// member, so `GitChange` keeps its memberwise initializer.
extension GitChange {
    /// One row of a device's `git_changed` batch, in the pane's own vocabulary.
    ///
    /// `nil` for a status the row cannot draw: an ignored file, which the local
    /// parser drops for the same reason, and a status this build does not know.
    /// The two-axis form is what decides `isStaged` — the worktree axis wins
    /// when it moved, exactly as `GitService.make(xy:path:untracked:)` reads
    /// porcelain v2 on this Mac, so a row means the same thing on either road.
    init?(device entry: Termiod.GitStatusEntryPayload) {
        let status: GitFileStatus
        var staged = false
        switch entry.status {
        case .untracked:
            status = .untracked
        case .unmerged:
            status = .conflicted
        case .ignored, .unknown:
            return nil
        case .tracked(let index, let worktree):
            let primary = worktree == "unmodified" ? index : worktree
            status = GitFileStatus(code: Self.letter(for: primary))
            staged = index != "unmodified" && worktree == "unmodified"
        }
        self.init(
            path: entry.path,
            status: status,
            isUntracked: status == .untracked,
            additions: entry.additions,
            deletions: entry.deletions,
            originalPath: entry.originalPath,
            isStaged: staged,
            isBinary: entry.binary)
    }

    /// `git.rs`'s `GitStatusCode`, back to the porcelain letter `GitFileStatus`
    /// already reads. Going through the letter rather than adding a second
    /// mapping keeps one definition of what a status means.
    private static func letter(for code: String) -> Character {
        switch code {
        case "modified": return "M"
        case "type_changed": return "T"
        case "added": return "A"
        case "deleted": return "D"
        case "renamed": return "R"
        case "copied": return "C"
        default: return "M"
        }
    }
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
    /// Author email, the key `CommitAvatarStore` resolves to a GitHub avatar.
    let authorEmail: String
    /// Human "3 hours ago" string straight from `git log --date=relative`.
    let relativeDate: String
    /// Tags pointing at this commit — release boundaries in termio's tag-is-the-release
    /// flow, shown as chips on the row.
    let tags: [String]
    /// True when the commit hasn't reached the branch's upstream (`@{u}..HEAD`).
    /// False everywhere when the branch has no upstream, so a purely local branch
    /// doesn't mark every row.
    let isUnpushed: Bool

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
    /// The machine `repoRoot` is a path on, when it is not this one. The overlay
    /// asks that device for the diff instead of running `git` here — a path from
    /// another box means nothing to this one's filesystem.
    var device: TermiodRoute? = nil
    let change: GitChange
    /// When set, the overlay shows the file's diff *as of that commit*
    /// (`git show <sha>`) rather than the working-tree diff — the History tab's
    /// file rows carry the commit they belong to.
    var commit: String? = nil
    /// When set, a `base...head` range: the overlay shows the file's three-dot
    /// (merge-base) diff across it — the Issues pane's PR file rows, diffed over
    /// fetched refs without a checkout.
    var range: String? = nil
    /// The ordered set the overlay walks with ← / → — the whole Changes list, or
    /// the files of the commit being read. Also feeds the header's "n of m".
    var siblings: [GitChange] = []

    var name: String { change.name }
}

/// One rendered line of a unified diff. The parse, the fold, and the intraline word diff
/// all live in `TermioShared` so the Mac and the phone read a diff the same way; this is
/// the desktop's name for the shared type.
typealias DiffRow = DiffLine
