import Darwin
import Foundation
import TermioShared

/// The environment for **every** app-side `git` subprocess. `GIT_OPTIONAL_LOCKS=0`
/// stops read-only git — notably `git status` — from taking the index lock and
/// rewriting `.git/index` to refresh its stat/untracked cache. That write fires an
/// FSEvent under `.git`, which the git pane's watcher treats as a change and
/// re-reads: a `status → index-write → status` loop that never settles while the
/// working tree keeps changing (a live dev server, a busy agent) and pegged a
/// long-running app at ~20% CPU, starving the main actor until `sessions list`
/// timed out.
///
/// It is applied at *every* git spawn site (GitService, BranchModel,
/// WorktreeService, CommandPalette, CompanionServer), not just the pane's, so no
/// path can reintroduce the loop — the same reason VS Code's git extension sets it
/// globally rather than per-command. Safe for writes too: `--no-optional-locks`
/// only skips *optional* locks, never the ones a real mutation needs. The inherited
/// environment is preserved (git still finds config/credentials), and it is scoped
/// to the app's own subprocesses — terminal sessions are never touched.
enum GitEnvironment {
    static let optionalLocksDisabled: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }()
}

// MARK: - Git

/// Thin wrapper over the `git` CLI for the changes list and diff overlay. Every call
/// runs off the main thread (via `offMain`) and degrades to empty on any failure —
/// the same no-trap stance as `BranchModel`.
enum GitService {
    /// Changed files for a repo root, with their `+`/`−` counts filled in. Empty when
    /// the folder is not a git work tree.
    static func changes(
        in repoRoot: String,
        onUntrackedScan: (@Sendable () -> Void)? = nil
    ) async -> [GitChange] {
        await offMain { loadChanges(repoRoot, onUntrackedScan: onUntrackedScan) }
    }

    /// The unified-diff rows for one changed file (staged + unstaged vs `HEAD`, or the
    /// whole file for an untracked one). With `commit` set, the file's diff *at that
    /// commit* instead — the History tab's per-file view.
    ///
    /// Rows are fetched with *full* context (`-U999999`) so the whole file is present
    /// and the overlay can collapse unchanged runs into expandable bands client-side;
    /// a pathological row count falls back to git's default 3-line context (the view
    /// then shows the inter-hunk gaps as fixed, non-expandable bands).
    static func diffRows(
        for change: GitChange, in repoRoot: String, commit: String? = nil, range: String? = nil
    ) async -> [DiffRow] {
        await offMain {
            let full = loadDiffText(change, repoRoot, commit: commit, range: range, context: 999_999)
            // ~20k lines of average code ≈ 1.5 MB. Beyond that, re-fetch at git's
            // default 3-line context rather than parse (and render) a whole huge file.
            let text = full.count <= 1_500_000
                ? full : loadDiffText(change, repoRoot, commit: commit, range: range)
            return DiffParser.lines(from: text)
        }
    }

    /// The raw unified-diff text for one changed file — what "Copy Diff" puts on the
    /// pasteboard, so it round-trips cleanly into `git apply` or an agent prompt.
    static func diffText(for change: GitChange, in repoRoot: String) async -> String {
        await offMain { loadDiffText(change, repoRoot) }
    }

    /// Parses ready-made unified-diff text (GitHub's inline PR `patch`) into rows off the
    /// main thread — the same parser the local `git diff` path uses, so a PR file diffed
    /// from the API renders identically without a subprocess or a checkout.
    static func parseDiffText(_ text: String) async -> [DiffRow] {
        await offMain { DiffParser.lines(from: text) }
    }

    /// Discards a whole selection in one confirmed action — the multi-select's
    /// "Discard N Files…". Sequential and best-effort per file, like the single form.
    static func discard(_ changes: [GitChange], in repoRoot: String) async {
        await offMain { for change in changes { _ = discardChanges(change, repoRoot) } }
    }

    /// The directories whose file-system events invalidate the git pane: the worktree
    /// itself, plus the resolved git dir(s). For a linked worktree the metadata lives
    /// *outside* the checkout (`.git` there is a pointer file; commits write into the
    /// primary checkout's `.git/worktrees/<name>` and `refs`), so watching the tree
    /// alone would miss commits made in the terminal. `gitDirs` is empty for a non-repo.
    static func watchPaths(for repoRoot: String) async -> (worktree: String, gitDirs: [String]) {
        await offMain {
            var dirs: [String] = []
            for args in [["rev-parse", "--absolute-git-dir"], ["rev-parse", "--git-common-dir"]] {
                guard let out = run(args, in: repoRoot)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else { continue }
                let absolute = out.hasPrefix("/")
                    ? out : (repoRoot as NSString).appendingPathComponent(out)
                let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
                if !dirs.contains(standardized) { dirs.append(standardized) }
            }
            return (repoRoot, dirs)
        }
    }

    // MARK: History

    /// The most recent commits on the current branch (newest first), for the History tab.
    static func log(in repoRoot: String, limit: Int = 100) async -> [GitCommit] {
        await offMain { loadLog(repoRoot, limit) }
    }

    /// The files touched by one commit, with their status letters — the rows shown when a
    /// history entry is expanded. Each carries the file's per-commit add/delete counts.
    static func commitChanges(_ sha: String, in repoRoot: String) async -> [GitChange] {
        await offMain { loadCommitChanges(sha, repoRoot) }
    }

    /// Parses `git log` into commit rows. Fields are joined by US (`\u{1f}`) and records
    /// by RS (`\u{1e}`), so subjects with spaces/tabs survive intact. `%D` carries the
    /// commit's decorations, from which only tags are kept (branch refs would restate
    /// what the pane's scope and the sidebar already say).
    ///
    /// `range` narrows the log to a revision range (`base..HEAD` for the branch compare);
    /// without one it walks back from `HEAD`.
    private static func loadLog(_ repoRoot: String, _ limit: Int, range: String? = nil) -> [GitCommit] {
        // Commits the upstream doesn't have yet. `run` returns nil on a non-zero exit,
        // so a branch with no upstream yields an empty set — no rows marked.
        let unpushed = Set(
            (run(["rev-list", "@{upstream}..HEAD"], in: repoRoot) ?? "")
                .split(separator: "\n").map(String.init)
        )
        let format = ["%H", "%h", "%s", "%an", "%ae", "%ad", "%D"].joined(separator: "\u{1f}") + "\u{1e}"
        guard let out = run(
            ["log", "-n", String(limit), "--date=relative", "--pretty=format:\(format)"]
                + (range.map { [$0] } ?? []),
            in: repoRoot
        ) else { return [] }
        return out.components(separatedBy: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\u{1f}")
            guard fields.count == 7, !fields[0].isEmpty else { return nil }
            let tags = fields[6].components(separatedBy: ", ")
                .filter { $0.hasPrefix("tag: ") }
                .map { String($0.dropFirst("tag: ".count)) }
            return GitCommit(sha: fields[0], shortSHA: fields[1], subject: fields[2],
                             author: fields[3], authorEmail: fields[4], relativeDate: fields[5],
                             tags: tags, isUnpushed: unpushed.contains(fields[0]))
        }
    }

    /// The changed files of a single commit. `--name-status` gives the status letter and
    /// path; `--numstat` gives the counts — merged by path. `--format=` drops the commit
    /// header so only the file lines remain. `--first-parent` makes a merge diff against
    /// its first parent (the branch that was merged into) — without it `git show` emits a
    /// combined diff, which is empty for a clean merge, so every PR merge in the history
    /// read as "No file changes". The root commit diffs against the empty tree as before.
    private static func loadCommitChanges(_ sha: String, _ repoRoot: String) -> [GitChange] {
        var order: [String] = []
        var status: [String: GitFileStatus] = [:]
        if let out = run(["show", "--name-status", "--format=", "-M", "--first-parent", sha], in: repoRoot) {
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard let code = parts.first?.first, parts.count >= 2 else { continue }
                let path = String(parts.last!)   // for renames the new path is last
                if status[path] == nil { order.append(path) }
                status[path] = GitFileStatus(code: code)
            }
        }
        var counts: [String: (Int, Int)] = [:]
        if let out = run(["show", "--numstat", "--format=", "--first-parent", sha], in: repoRoot) {
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                counts[String(parts[2])] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
            }
        }
        return order.map { path in
            let c = counts[path] ?? (0, 0)
            return GitChange(path: path, status: status[path] ?? .modified, isUntracked: false,
                             additions: c.0, deletions: c.1)
        }
    }

    // MARK: Branch compare

    /// What the Compare tab's base picker needs about a checkout: the branch it is on, the
    /// refs it can be compared against, and the base to start on. Gathered in one hop —
    /// a menu that spawned a `git` per field would fork four processes every time it opened.
    struct CompareContext: Sendable {
        /// `nil` on a detached HEAD, where "the branch this pull request comes from" has
        /// no answer, so the pane offers no comparison.
        let branch: String?
        /// Remote-tracking refs (`origin/main`), the honest bases: a stale local `main`
        /// would silently overstate the diff. The branch's own upstream stays in the list —
        /// `origin/main` from a checkout of `main` answers "what haven't I pushed", which is
        /// a comparison worth making, and dropping it left a trunk checkout with no base to
        /// pick at all.
        let remoteBranches: [String]
        /// Local branches other than the checkout's own.
        let localBranches: [String]
        /// The base to preselect, and the ref the picker lifts to the top of its section:
        /// the remote's recorded default branch, else the first conventional trunk name
        /// that exists. `nil` only when neither is there to pick.
        let suggestedBase: String?
    }

    /// A branch measured against the base it would be merged into.
    struct BranchCompare: Sendable {
        let base: String
        /// The files the merge would touch, three-dot (from the merge base) — the change
        /// the pull request itself introduces, matching what the forge will show. Committed
        /// work only: uncommitted edits stay the Changes tab's business.
        let files: [GitChange]
        /// The commits the merge would bring over, newest first.
        let commits: [GitCommit]
        /// Commits on the base this branch doesn't have. Not an error — the base moved on —
        /// but it dates the comparison, and it is measured against the last *fetched* state
        /// of a remote base, never a fresh network fetch.
        let behind: Int
    }

    /// Why a comparison couldn't be made — stated, never folded into an empty file list,
    /// which would read as "this branch changes nothing".
    enum CompareProblem: Sendable {
        /// The picked base no longer resolves: its branch was deleted since it was chosen.
        case missingBase
        /// Nothing connects the two — unrelated histories, or a shallow clone whose graft
        /// point sits above where the branches diverged. There is no merge base to diff
        /// from, so any file list here would be the whole tree rather than a change.
        case noCommonHistory
    }

    enum CompareOutcome: Sendable {
        case ready(BranchCompare)
        case problem(CompareProblem)
    }

    static func compareContext(in repoRoot: String) async -> CompareContext {
        await offMain { loadCompareContext(repoRoot) }
    }

    /// The branch's diff and commits against `base`.
    static func branchCompare(base: String, in repoRoot: String, limit: Int = 200) async -> CompareOutcome {
        await offMain { loadBranchCompare(base, repoRoot, limit) }
    }

    private static func loadCompareContext(_ repoRoot: String) -> CompareContext {
        let head = run(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (head == "HEAD" || head?.isEmpty == true) ? nil : head
        var locals: [String] = []
        var remotes: [String] = []
        // Full refnames, not `%(refname:short)`: a local `feat/x` and a remote `origin/main`
        // are indistinguishable once shortened, and the two lists mean different things.
        for ref in (run(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"], in: repoRoot) ?? "")
            .split(separator: "\n").map(String.init) {
            if ref.hasPrefix("refs/heads/") {
                // The checkout's own branch is the only ref that can't be a base: a branch
                // compared with itself is always empty.
                let short = String(ref.dropFirst("refs/heads/".count))
                if short != branch { locals.append(short) }
            } else if ref.hasPrefix("refs/remotes/") {
                let short = String(ref.dropFirst("refs/remotes/".count))
                // `origin/HEAD` is a symbolic pointer at the default branch, not a branch.
                if !short.hasSuffix("/HEAD") { remotes.append(short) }
            }
        }
        let originHead = run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CompareContext(
            branch: branch, remoteBranches: remotes, localBranches: locals,
            suggestedBase: suggestedCompareBase(
                branch: branch, originHead: originHead,
                remoteBranches: remotes, localBranches: locals))
    }

    /// Branch names a repository conventionally merges into, in the order they are tried.
    private static let trunkBranchNames = ["main", "master", "dev", "develop", "trunk"]

    /// Picks the base to compare a branch against: the remote's recorded default first
    /// (`origin/HEAD`, what the forge will default the pull request's base to), then the
    /// conventional trunk names — preferring `origin/main` over a local `main`, which in a
    /// long-lived clone is usually months stale and would invent changes the branch never made.
    ///
    /// A checkout of the trunk gets `origin/main` rather than nothing: the comparison then
    /// reads "what haven't I pushed", which is worth showing, and the tab used to open on a
    /// dead end — telling the user to pick a base while the trunk was filtered out of the
    /// menu. Only a local branch is skipped when it *is* the checkout (a branch compared
    /// with itself is always empty), and a detached HEAD has no branch to compare at all.
    static func suggestedCompareBase(
        branch: String?, originHead: String?,
        remoteBranches: [String], localBranches: [String]
    ) -> String? {
        guard let branch else { return nil }
        if let originHead, remoteBranches.contains(originHead) { return originHead }
        for name in trunkBranchNames {
            if let remote = remoteBranches.first(where: { remoteBranchName($0) == name }) { return remote }
            if name != branch, localBranches.contains(name) { return name }
        }
        return nil
    }

    /// `origin/feat/x` → `feat/x`. Only ever applied to a remote-tracking ref, where the
    /// first component is the remote's name.
    private static func remoteBranchName(_ ref: String) -> String {
        ref.split(separator: "/").dropFirst().joined(separator: "/")
    }

    private static func loadBranchCompare(_ base: String, _ repoRoot: String, _ limit: Int) -> CompareOutcome {
        guard run(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repoRoot) != nil
        else { return .problem(.missingBase) }
        // Without a merge base the three-dot diff below exits non-zero and would degrade to
        // an empty file list — while `base..HEAD` still lists commits, so the tab would show
        // "no files, 40 commits". Ask git first and say what is actually wrong.
        guard run(["merge-base", base, "HEAD"], in: repoRoot) != nil
        else { return .problem(.noCommonHistory) }
        // Three dots: diff from the merge base, so commits that landed on the base since
        // this branch started don't show up inverted as changes the branch never made.
        let range = "\(base)...HEAD"
        let files = rangeChanges(
            numstat: run(["diff", "--numstat", "-z", "-M", range], in: repoRoot) ?? "",
            nameStatus: run(["diff", "--name-status", "-z", "-M", range], in: repoRoot) ?? "")
        // Two dots for the counts — "how far apart are the tips", not "what would merge".
        let behind = Int((run(["rev-list", "--count", "HEAD..\(base)"], in: repoRoot) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return .ready(BranchCompare(
            base: base, files: files,
            commits: loadLog(repoRoot, limit, range: "\(base)..HEAD"), behind: behind))
    }

    /// Merges `git diff --numstat -z` (counts) with `--name-status -z` (the status letter)
    /// into the pane's change rows, keyed by the new path.
    ///
    /// `-z` rather than the default: without it git quotes any path holding a space or a
    /// non-ASCII byte (`"src/\303\251.swift"`), and the quoted form doesn't match the path
    /// the rest of the pane — the diff overlay, the file tree — addresses the file by.
    static func rangeChanges(numstat: String, nameStatus: String) -> [GitChange] {
        let statuses = parseNameStatus(nameStatus)
        return parseNumstat(numstat)
            .map { entry in
                GitChange(
                    path: entry.path,
                    status: statuses[entry.path] ?? (entry.originalPath == nil ? .modified : .renamed),
                    isUntracked: false,
                    additions: entry.additions ?? 0, deletions: entry.deletions ?? 0,
                    originalPath: entry.originalPath,
                    isBinary: entry.additions == nil || entry.deletions == nil)
            }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private struct NumstatEntry {
        let path: String
        let originalPath: String?
        /// `nil` when git reported `-`, which it does for a binary file — `+`/`−` counts
        /// would be a lie there, so the row shows none.
        let additions: Int?
        let deletions: Int?
    }

    /// One `--numstat -z` record is `"<adds>\t<dels>\t<path>"`. A rename or copy leaves the
    /// path field empty and follows with the old and new paths as their own two records.
    private static func parseNumstat(_ raw: String) -> [NumstatEntry] {
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var entries: [NumstatEntry] = []
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard !record.isEmpty else { continue }
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let additions = Int(parts[0])
            let deletions = Int(parts[1])
            var path = String(parts[2])
            var originalPath: String?
            if path.isEmpty {
                guard index + 1 < fields.count else { break }
                originalPath = fields[index]
                path = fields[index + 1]
                index += 2
            }
            entries.append(NumstatEntry(path: path, originalPath: originalPath,
                                        additions: additions, deletions: deletions))
        }
        return entries
    }

    /// `--name-status -z` alternates a status record with its path — two paths for a rename
    /// or copy, whose letter carries a similarity score (`R100`).
    private static func parseNameStatus(_ raw: String) -> [String: GitFileStatus] {
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var statuses: [String: GitFileStatus] = [:]
        var index = 0
        while index < fields.count {
            let code = fields[index]
            index += 1
            guard let letter = code.first else { continue }
            let isPair = letter == "R" || letter == "C"
            guard index + (isPair ? 1 : 0) < fields.count else { break }
            statuses[fields[index + (isPair ? 1 : 0)]] = GitFileStatus(code: letter)
            index += isPair ? 2 : 1
        }
        return statuses
    }

    // MARK: Loading

    private static func loadChanges(
        _ repoRoot: String,
        onUntrackedScan: (@Sendable () -> Void)?
    ) -> [GitChange] {
        guard run(["rev-parse", "--is-inside-work-tree"], in: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true",
            let raw = run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: repoRoot)
        else { return [] }

        var changes = parseStatus(raw)
        applyCounts(&changes, repoRoot: repoRoot, onUntrackedScan: onUntrackedScan)
        // Conflicts float to the top — they are the one status that *must* be acted
        // on. Everything else sorts by full path, so siblings cluster the way the
        // file tree shows them rather than in git's emit order.
        changes.sort { a, b in
            if (a.status == .conflicted) != (b.status == .conflicted) { return a.status == .conflicted }
            return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
        }
        return changes
    }

    /// Parses `git status --porcelain=v2 -z`. Records are NUL-separated; the path is
    /// always the *current* path, so renames (type `2`) carry the original path in the
    /// following NUL field, kept for the row's `old → new` tooltip.
    private static func parseStatus(_ raw: String) -> [GitChange] {
        let tokens = raw.components(separatedBy: "\0").filter { !$0.isEmpty }
        var result: [GitChange] = []
        var i = 0
        while i < tokens.count {
            let rec = tokens[i]
            i += 1
            guard let kind = rec.first else { continue }
            switch kind {
            case "1":
                let f = rec.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard f.count == 9 else { continue }
                result.append(make(xy: Array(f[1]), path: String(f[8]), untracked: false))
            case "2":
                let f = rec.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard f.count == 10 else { continue }
                var change = make(xy: Array(f[1]), path: String(f[9]), untracked: false)
                if i < tokens.count { change.originalPath = tokens[i]; i += 1 }
                result.append(change)
            case "u":
                let f = rec.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard f.count == 11 else { continue }
                result.append(GitChange(path: String(f[10]), status: .conflicted, isUntracked: false))
            case "?":
                result.append(GitChange(path: String(rec.dropFirst(2)), status: .untracked, isUntracked: true))
            default:
                continue // "!" ignored entries
            }
        }
        return result
    }

    /// Builds a change from a porcelain-v2 `XY` field, where `.` means unmodified — the
    /// worktree side (`Y`) wins, falling back to the index side (`X`).
    private static func make(xy: [Character], path: String, untracked: Bool) -> GitChange {
        let x = xy.first ?? "."
        let y = xy.count > 1 ? xy[1] : "."
        let primary: Character = (y != ".") ? y : x
        var change = GitChange(path: path, status: GitFileStatus(code: primary), isUntracked: untracked)
        change.isStaged = x != "." && y == "."
        return change
    }

    /// Above this many untracked files the per-file line counts are skipped wholesale — the
    /// flood case, almost always a missing `.gitignore` over a build directory. Decorating a
    /// broken list is not worth thousands of file reads; VS Code degrades the same way at its
    /// `git.statusLimit`. Rows still show their `U` status, the footer still counts files.
    static let untrackedCountLimit = 500
    /// An untracked file bigger than this is never line-counted — nobody reviews a
    /// multi-megabyte file by its `+N` badge.
    private static let untrackedSizeLimit = 4_000_000

    /// Fills each change's add/delete counts: `git diff --numstat` (unstaged) merged
    /// with `--cached` (staged) for tracked files, and a line count for untracked ones.
    private static func applyCounts(
        _ changes: inout [GitChange],
        repoRoot: String,
        onUntrackedScan: (@Sendable () -> Void)?
    ) {
        var counts: [String: (Int, Int)] = [:]
        var binaries: Set<String> = []
        for args in [["diff", "--numstat"], ["diff", "--numstat", "--cached"]] {
            guard let out = run(args, in: repoRoot) else { continue }
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let path = String(parts[2])
                if parts[0] == "-" { binaries.insert(path); continue }
                let adds = Int(parts[0]) ?? 0
                let dels = Int(parts[1]) ?? 0
                let existing = counts[path] ?? (0, 0)
                counts[path] = (existing.0 + adds, existing.1 + dels)
            }
        }
        let untrackedFlood = changes.lazy.filter(\.isUntracked).count > untrackedCountLimit
        for idx in changes.indices {
            if changes[idx].isUntracked {
                guard !untrackedFlood else { continue }
                let abs = (repoRoot as NSString).appendingPathComponent(changes[idx].path)
                onUntrackedScan?()
                switch untrackedLineCount(abs) {
                case .lines(let count): changes[idx].additions = count
                case .binary: changes[idx].isBinary = true
                case .skip: break
                }
            } else {
                if let c = counts[changes[idx].path] {
                    changes[idx].additions = c.0
                    changes[idx].deletions = c.1
                }
                changes[idx].isBinary = binaries.contains(changes[idx].path)
            }
        }
    }

    private enum UntrackedCount { case lines(Int), binary, skip }

    /// The `+N` for one untracked file, cheaply: bounded chunked reads scanning bytes for
    /// newlines — never a full UTF-8 decode (the old path read whole `.o` files into a `String`
    /// just to fail the decode), and deliberately **not** mmap: a build truncating the file
    /// mid-scan would turn a mapped read into SIGBUS, which no `try?` catches. A NUL in the
    /// first chunk marks a binary (git's own sniff); crossing the size cap bails.
    private static func untrackedLineCount(_ path: String) -> UntrackedCount {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .skip }
        defer { try? handle.close() }
        var lines = 0
        var total = 0
        var lastByte: UInt8 = 0x0A
        var isFirstChunk = true
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 262_144), !chunk.isEmpty else { break }
                if isFirstChunk {
                    if chunk.prefix(min(8000, chunk.count)).contains(0) { return .binary }
                    isFirstChunk = false
                }
                total += chunk.count
                if total > untrackedSizeLimit { return .skip }
                for byte in chunk where byte == 0x0A { lines += 1 }
                lastByte = chunk.last ?? lastByte
            } catch {
                return .skip
            }
        }
        if isFirstChunk { return .skip } // empty (or vanished mid-read): no badge
        if lastByte != 0x0A { lines += 1 }
        return .lines(lines)
    }

    /// A repo-relative path encoded as a literal `.gitignore` pattern: glob metacharacters
    /// backslash-escaped, trailing spaces escaped (git strips them bare), rooted with a
    /// leading `/` (which also disarms leading `#`/`!`). `nil` for the unrepresentable
    /// case of a line break in the name.
    static func gitignorePattern(for path: String) -> String? {
        guard !path.contains("\n"), !path.contains("\r") else { return nil }
        var escaped = ""
        for character in path {
            if "\\*?[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        let trailingSpaces = escaped.reversed().prefix(while: { $0 == " " }).count
        escaped = String(escaped.dropLast(trailingSpaces))
            + String(repeating: "\\ ", count: trailingSpaces)
        return "/" + escaped
    }

    /// Appends patterns to the repo root's `.gitignore` (created if absent), skipping lines
    /// already present. The descriptor is opened with `O_APPEND` so a concurrent creator can
    /// never be truncated; `flock` serializes termio's own simultaneous menu actions. Existing
    /// bytes are compared and preserved without decoding, so even a non-UTF8 ignore file is safe.
    /// The pane's file-system watch sees the write and refreshes on its own.
    @discardableResult
    static func appendToGitignore(_ patterns: [String], in repoRoot: String) async -> Bool {
        await offMain { appendPatternsToGitignore(patterns, repoRoot: repoRoot) }
    }

    private static func appendPatternsToGitignore(_ patterns: [String], repoRoot: String) -> Bool {
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(".gitignore")
        let permissions = mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH)
        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC,
            permissions
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { _ = flock(descriptor, LOCK_UN) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.seek(toOffset: 0)
            let existing = try handle.readToEnd() ?? Data()
            let existingBytes = Array(existing)
            let existingLines = Set(existingBytes.split(separator: 0x0A).map { Data($0) })
            let additions = patterns.filter { !existingLines.contains(Data($0.utf8)) }
            guard !additions.isEmpty else { return true }
            let needsLeadingNewline = !existing.isEmpty && existing.last != 0x0A
            let payload = (needsLeadingNewline ? "\n" : "")
                + additions.joined(separator: "\n") + "\n"
            try handle.write(contentsOf: Data(payload.utf8))
            return true
        } catch {
            return false
        }
    }

    /// Reverts one file to clean. Untracked and freshly-added files are deleted from
    /// disk (the added one is unstaged first so git forgets it); everything else is
    /// reset to its `HEAD` blob across both the index and the working tree via
    /// `git restore`. Renames restore the current path only — a rare, best-effort case.
    private static func discardChanges(_ change: GitChange, _ repoRoot: String) -> Bool {
        let abs = (repoRoot as NSString).appendingPathComponent(change.path)
        switch change.status {
        case .untracked:
            return (try? FileManager.default.removeItem(atPath: abs)) != nil
        case .added:
            _ = run(["restore", "--staged", "--", change.path], in: repoRoot, ignoreStatus: true)
            return (try? FileManager.default.removeItem(atPath: abs)) != nil
        default:
            return run(["restore", "--staged", "--worktree", "--source=HEAD", "--", change.path],
                       in: repoRoot, ignoreStatus: true) != nil
        }
    }

    private static func loadDiffText(_ change: GitChange, _ repoRoot: String,
                                     commit: String? = nil, range: String? = nil,
                                     context: Int? = nil) -> String {
        let contextArguments = context.map { ["-U\($0)"] } ?? []
        // PR file row: the file's change across a `base...head` range (three-dot, so
        // git diffs from the merge base — the change the PR itself introduces).
        //
        // A rename is limited to *both* paths: git applies the path limit before rename
        // detection, so asking only for the destination turns a pure rename into the whole
        // file arriving as additions — contradicting the row's own `R` and its zero counts.
        if let range {
            let paths = [change.path] + (change.originalPath.map { [$0] } ?? [])
            return run(["diff", "-M"] + contextArguments + [range, "--"] + paths,
                       in: repoRoot, ignoreStatus: true) ?? ""
        }
        // History file row: the file's change within one commit. `--format=` strips the
        // commit header so the parser sees only the unified diff; `--first-parent` keeps
        // a merge commit's file diff non-empty, matching the file list above.
        if let commit {
            return run(["show", "--format=", "-M", "--first-parent"] + contextArguments + [commit, "--", change.path],
                       in: repoRoot, ignoreStatus: true) ?? ""
        }
        if change.isUntracked {
            // `--no-index` exits non-zero when the files differ, which is the normal
            // case here, so the status is ignored.
            return run(["diff", "--no-index"] + contextArguments + ["--", "/dev/null", change.path],
                       in: repoRoot, ignoreStatus: true) ?? ""
        }
        // `diff HEAD` shows staged and unstaged together. Fall back to the split views
        // for a repo with no commit yet, or a fully-staged change.
        if let d = run(["diff"] + contextArguments + ["HEAD", "--", change.path], in: repoRoot),
           !d.isEmpty { return d }
        let unstaged = run(["diff"] + contextArguments + ["--", change.path], in: repoRoot) ?? ""
        if !unstaged.isEmpty { return unstaged }
        return run(["diff"] + contextArguments + ["--cached", "--", change.path], in: repoRoot) ?? ""
    }


    /// A recognized code-hosting forge, detected from the origin remote's hostname.
    /// Each forge shapes its branch-tree URL differently, so a "view remote" link
    /// must know which one it's talking to.
    enum Forge {
        case github, gitlab, bitbucket, gitea

        var name: String {
            switch self {
            case .github: return "GitHub"
            case .gitlab: return "GitLab"
            case .bitbucket: return "Bitbucket"
            case .gitea: return "Gitea"
            }
        }

        /// The path that shows `branch`'s file tree, relative to the repo's web URL.
        fileprivate func branchPath(_ branch: String) -> String {
            switch self {
            case .github: return "tree/\(branch)"
            case .gitlab: return "-/tree/\(branch)"
            case .bitbucket: return "src/\(branch)"
            case .gitea: return "src/branch/\(branch)"
            }
        }

        /// The path that opens a pull/merge request from `branch`, relative to the
        /// repo's web URL. GitHub/GitLab/Bitbucket default the base branch on
        /// their own; Gitea's compare route wants it explicit, so the caller
        /// passes one (only consulted there).
        fileprivate func newPullRequestPath(branch: String, base: String) -> String {
            switch self {
            case .github: return "compare/\(branch)?expand=1"
            case .gitlab: return "-/merge_requests/new?merge_request%5Bsource_branch%5D=\(branch)"
            case .bitbucket: return "pull-requests/new?source=\(branch)"
            case .gitea: return "compare/\(base)...\(branch)"
            }
        }

        /// Hostname → forge. Exact hosts cover the public instances; the substring
        /// checks cover the self-hosted convention (`gitlab.company.com`, `gitea.…`).
        fileprivate init?(host: String) {
            switch true {
            case host == "github.com" || host == "www.github.com": self = .github
            case host == "bitbucket.org" || host.contains("bitbucket"): self = .bitbucket
            case host.contains("gitlab"): self = .gitlab
            case host == "codeberg.org" || host.contains("gitea") || host.contains("forgejo"): self = .gitea
            default: return nil
            }
        }
    }

    struct RemotePage {
        let forge: Forge
        let url: URL
    }

    /// The forge web page for `dir`'s checkout — the current branch's tree when the
    /// branch exists on the remote, else the repository root (an unpushed branch would
    /// 404). `nil` when there is no repository or the origin remote isn't a forge we
    /// can shape a URL for.
    static func remotePage(in dir: String) async -> RemotePage? {
        await offMain { resolveRemotePage(dir) }
    }

    private static func resolveRemotePage(_ dir: String) -> RemotePage? {
        guard let remote = run(["remote", "get-url", "origin"], in: dir)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let parsed = parseRemote(remote),
            let forge = Forge(host: parsed.host),
            let repo = URL(string: "https://\(parsed.host)/\(parsed.path)") else { return nil }
        guard run(["rev-parse", "--abbrev-ref", "@{upstream}"], in: dir) != nil,
              let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty, branch != "HEAD",
              let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return RemotePage(forge: forge, url: repo) }
        let branchURL = URL(string: "\(repo.absoluteString)/\(forge.branchPath(escaped))") ?? repo
        return RemotePage(forge: forge, url: branchURL)
    }

    /// The forge page for opening a pull request from `dir`'s current branch —
    /// GitHub Desktop's Branch ▸ New Pull Request jump, verbatim: a browser
    /// hand-off, so the PR itself is still authored on the forge, never in
    /// termio. `nil` when the origin remote isn't a forge we can shape a URL
    /// for, the checkout is detached, or the branch has no upstream yet (the
    /// forge would 404 on a branch it has never seen — the caller tells the
    /// user to push first).
    static func newPullRequestPage(in dir: String) async -> URL? {
        await offMain { resolveNewPullRequestPage(dir) }
    }

    private static func resolveNewPullRequestPage(_ dir: String) -> URL? {
        guard let remote = run(["remote", "get-url", "origin"], in: dir)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let parsed = parseRemote(remote),
            let forge = Forge(host: parsed.host),
            let repo = URL(string: "https://\(parsed.host)/\(parsed.path)"),
            run(["rev-parse", "--abbrev-ref", "@{upstream}"], in: dir) != nil,
            let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !branch.isEmpty, branch != "HEAD",
            let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        // Gitea's compare route is the only one needing an explicit base branch.
        // `origin/HEAD` is the local record of the remote's default (unset in
        // some clones — then "main" is the best guess).
        var base = "main"
        if forge == .gitea,
           let head = run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: dir)?
               .trimmingCharacters(in: .whitespacesAndNewlines) {
            // "origin/main" → "main" (keeping any slashes inside the branch name).
            let short = head.split(separator: "/").dropFirst().joined(separator: "/")
            if !short.isEmpty { base = short }
        }
        let path = forge.newPullRequestPath(branch: escaped, base: base)
        return URL(string: "\(repo.absoluteString)/\(path)")
    }

    /// The `owner/repo` slug when the origin remote points at github.com — the
    /// Issues pane's zero-config binding (docs/design/20260726-issue-tracker-integration.md).
    /// `nil` for non-GitHub remotes or a repo with no origin.
    static func gitHubRepoSlug(in dir: String) async -> String? {
        await offMain {
            guard let remote = run(["remote", "get-url", "origin"], in: dir)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let parsed = parseRemote(remote)
            else { return nil }
            // A literal github.com host binds directly, whatever the transport.
            if isGitHubHostName(parsed.host) { return parsed.path }
            // Otherwise it may be an SSH `~/.ssh/config` alias (`Host github-work`
            // → `HostName github.com`, the standard trick for juggling accounts).
            // `sshTarget` is non-nil only for SSH remotes, so an HTTPS host never
            // triggers `ssh -G` — which would be pointless and could fire a
            // `Match exec` or falsely bind an unrelated repo to public GitHub.
            guard let target = parsed.sshTarget,
                  let resolved = resolveSSHHostName(target),
                  isGitHubHostName(resolved)
            else { return nil }
            return parsed.path
        }
    }

    /// What "Clone to <device>…" needs to know about a checkout: the `origin`
    /// URL to hand `git clone` on the remote, a repo name derived from it (the
    /// clone's directory), and how many local commits are ahead of the upstream
    /// (they live only on this Mac and won't travel with a fresh clone — the
    /// action warns before proceeding). `nil` when the folder has no `origin`
    /// remote, so the menu item can disable itself with a clear reason.
    struct CloneInfo: Sendable {
        let originURL: String
        let repositoryName: String
        /// Commits on the current branch not yet on its upstream; `nil` when the
        /// branch has no upstream (nothing to compare, so no warning).
        let unpushedCommits: Int?
    }

    static func cloneInfo(in dir: String) async -> CloneInfo? {
        await offMain { () -> CloneInfo? in
            guard let origin = run(["remote", "get-url", "origin"], in: dir)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !origin.isEmpty
            else { return nil }
            let name = repositoryName(fromRemote: origin)
            // `@{upstream}` fails (nil) when the branch tracks nothing — treat that
            // as "unknown", not "0 unpushed", so the warning only fires when we
            // actually measured commits that would be left behind.
            let unpushed: Int? = run(
                ["rev-list", "--count", "@{upstream}..HEAD"], in: dir
            ).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return CloneInfo(originURL: origin, repositoryName: name, unpushedCommits: unpushed)
        }
    }

    /// The clone directory name `git clone <url>` would pick: the last path
    /// component with any trailing `.git` and slashes stripped (matching git's own
    /// `guess_dir_name`). Falls back to "repo" if the URL has no usable component.
    static func repositoryName(fromRemote remote: String) -> String {
        var trimmed = remote.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        // Both `/` (https, scp-less) and `:` (scp-style `host:owner/repo`) can
        // precede the final component.
        let component = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last
        let name = component.map(String.init) ?? ""
        return name.isEmpty ? "repo" : name
    }

    private static func isGitHubHostName(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "github.com" || lower == "www.github.com"
    }

    private nonisolated(unsafe) static var sshHostNameCache: [String: String] = [:]
    private static let sshHostNameLock = NSLock()

    /// The real hostname `ssh` resolves `target` (`[user@]host`) to, after alias /
    /// Include / Match expansion — mirrors how `gh` (go-gh's SSH translator)
    /// resolves the same case. `nil` when ssh can't be run or reports nothing; an
    /// empty string is cached for "no answer" so a missing ssh isn't retried per
    /// repo. The cache key keeps the target's case (OpenSSH matching is
    /// case-sensitive), so `github-work` and `GitHub-Work` stay distinct.
    private static func resolveSSHHostName(_ target: String) -> String? {
        // The subprocess runs *outside* the lock (never hold a lock across a fork);
        // a rare duplicate lookup just recomputes the same value.
        if let cached = sshHostNameLock.withLock({ sshHostNameCache[target] }) {
            return cached.isEmpty ? nil : cached
        }
        // `ssh -G <target>` prints the fully-resolved effective config; its
        // `hostname <value>` line is the destination the alias points at.
        let value = output(of: "/usr/bin/ssh", ["-G", target])?
            .split(separator: "\n")
            .first { $0.lowercased().hasPrefix("hostname ") }
            .map { String($0.dropFirst("hostname ".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        sshHostNameLock.withLock { sshHostNameCache[target] = value }
        return value.isEmpty ? nil : value
    }

    /// A git remote split into its web-addressable host + repo path, plus the
    /// `[user@]host` to hand `ssh -G` when git reaches it over SSH.
    private struct ParsedRemote {
        let host: String
        let path: String
        /// Present only for SSH remotes (scp-like or `ssh://`); `nil` for HTTPS /
        /// git://. Case and userinfo are preserved so `Host` patterns and
        /// `Match user` / `%r` rules resolve as git's own ssh would.
        let sshTarget: String?
    }

    /// Splits a remote from either the scp-like form (`git@host:owner/repo.git`) or a
    /// real URL (`https://…`, `ssh://…`). Ports and userinfo are dropped from `host` /
    /// `path` — the web UI lives on plain https — but kept in `sshTarget`.
    private static func parseRemote(_ remote: String) -> ParsedRemote? {
        let host: String
        var path: String
        var sshTarget: String?
        if !remote.contains("://"), remote.contains("@"), let colon = remote.firstIndex(of: ":") {
            let hostPart = String(remote[..<colon])   // user@host, original case
            host = hostPart.components(separatedBy: "@").last ?? hostPart
            path = String(remote[remote.index(after: colon)...])
            sshTarget = hostPart
        } else if let url = URL(string: remote), let urlHost = url.host {
            host = urlHost
            path = url.path
            if url.scheme == "ssh" {
                sshTarget = url.user.map { "\($0)@\(urlHost)" } ?? urlHost
            }
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return ParsedRemote(host: host, path: path, sshTarget: sshTarget)
    }

    // MARK: Stall detection

    /// A cheap identity of a working tree for the stall detector (sessions-cli-v2
    /// §4.7 probe 2): the HEAD commit plus a digest of the porcelain status, so
    /// both a new commit and any tree change move it. The digest is process-local
    /// (`hashValue` is seeded per launch), which is all the detector compares
    /// across. Synchronous and blocking — callers must run it off the main thread
    /// (the BranchModel main-thread-git freeze). A non-repo directory fingerprints
    /// as a stable empty value, which still compares correctly across a window.
    static func stallFingerprint(in repoRoot: String) -> String {
        let head = run(["rev-parse", "HEAD"], in: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = run(["status", "--porcelain"], in: repoRoot) ?? ""
        return "\(head)#\(status.hashValue)"
    }

    // MARK: Process

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Runs `git -C <dir> <args>` and returns stdout, or `nil` on launch failure or a
    /// non-zero exit (unless `ignoreStatus`).
    private static func run(_ args: [String], in dir: String, ignoreStatus: Bool = false) -> String? {
        output(of: "/usr/bin/git", ["-C", dir] + args, ignoreStatus: ignoreStatus)
    }

    /// Runs an executable and returns stdout, or `nil` on launch failure or a non-zero
    /// exit (unless `ignoreStatus`). stdout is drained *before* `waitUntilExit` because
    /// output can exceed the 64 KB pipe buffer and otherwise deadlock the child; stderr
    /// is sent to the null device so it can never fill either. The environment is
    /// inherited, so ssh finds `~/.ssh/config`.
    private static func output(of executable: String, _ args: [String], ignoreStatus: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // See `GitEnvironment`: keeps `git status` from rewriting `.git/index` and
        // re-triggering the pane watcher. `ssh` (the other caller) ignores it.
        if executable.hasSuffix("/git") {
            process.environment = GitEnvironment.optionalLocksDisabled
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !ignoreStatus, process.terminationStatus != 0 { return nil }
        return String(data: data, encoding: .utf8)
    }
}
