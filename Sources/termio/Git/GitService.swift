import Foundation

// MARK: - Git

/// Thin wrapper over the `git` CLI for the changes list and diff overlay. Every call
/// runs off the main thread (via `offMain`) and degrades to empty on any failure —
/// the same no-trap stance as `BranchModel`.
enum GitService {
    /// Changed files for a repo root, with their `+`/`−` counts filled in. Empty when
    /// the folder is not a git work tree.
    static func changes(in repoRoot: String) async -> [GitChange] {
        await offMain { loadChanges(repoRoot) }
    }

    /// The unified-diff rows for one changed file (staged + unstaged vs `HEAD`, or the
    /// whole file for an untracked one). With `commit` set, the file's diff *at that
    /// commit* instead — the History tab's per-file view.
    static func diffRows(for change: GitChange, in repoRoot: String, commit: String? = nil) async -> [DiffRow] {
        await offMain { parseDiff(loadDiffText(change, repoRoot, commit: commit)) }
    }

    /// The raw unified-diff text for one changed file — what "Copy Diff" puts on the
    /// pasteboard, so it round-trips cleanly into `git apply` or an agent prompt.
    static func diffText(for change: GitChange, in repoRoot: String) async -> String {
        await offMain { loadDiffText(change, repoRoot) }
    }

    /// Throws away every change to a single file, restoring it to its clean state:
    /// modified/deleted files reset to `HEAD` (index *and* worktree), a newly-added file
    /// is unstaged and removed, and an untracked file is deleted from disk. Best-effort —
    /// the caller reloads the changes list afterwards regardless of the return.
    @discardableResult
    static func discard(_ change: GitChange, in repoRoot: String) async -> Bool {
        await offMain { discardChanges(change, repoRoot) }
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
    /// by RS (`\u{1e}`), so subjects with spaces/tabs survive intact.
    private static func loadLog(_ repoRoot: String, _ limit: Int) -> [GitCommit] {
        let format = ["%H", "%h", "%s", "%an", "%ad"].joined(separator: "\u{1f}") + "\u{1e}"
        guard let out = run(
            ["log", "-n", String(limit), "--date=relative", "--pretty=format:\(format)"],
            in: repoRoot
        ) else { return [] }
        return out.components(separatedBy: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\u{1f}")
            guard fields.count == 5, !fields[0].isEmpty else { return nil }
            return GitCommit(sha: fields[0], shortSHA: fields[1], subject: fields[2],
                             author: fields[3], relativeDate: fields[4])
        }
    }

    /// The changed files of a single commit. `--name-status` gives the status letter and
    /// path; `--numstat` gives the counts — merged by path. `--format=` drops the commit
    /// header so only the file lines remain. The first-parent diff (`<sha>^!`) is used so
    /// a merge shows a sensible file set; the root commit falls back to the empty tree.
    private static func loadCommitChanges(_ sha: String, _ repoRoot: String) -> [GitChange] {
        var order: [String] = []
        var status: [String: GitFileStatus] = [:]
        if let out = run(["show", "--name-status", "--format=", "-M", sha], in: repoRoot) {
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard let code = parts.first?.first, parts.count >= 2 else { continue }
                let path = String(parts.last!)   // for renames the new path is last
                if status[path] == nil { order.append(path) }
                status[path] = GitFileStatus(code: code)
            }
        }
        var counts: [String: (Int, Int)] = [:]
        if let out = run(["show", "--numstat", "--format=", sha], in: repoRoot) {
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

    // MARK: Loading

    private static func loadChanges(_ repoRoot: String) -> [GitChange] {
        guard run(["rev-parse", "--is-inside-work-tree"], in: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true",
            let raw = run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: repoRoot)
        else { return [] }

        var changes = parseStatus(raw)
        applyCounts(&changes, repoRoot: repoRoot)
        return changes
    }

    /// Parses `git status --porcelain=v2 -z`. Records are NUL-separated; the path is
    /// always the *current* path, so renames (type `2`) carry the original path in the
    /// following NUL field, which is consumed and ignored.
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
                if i < tokens.count { i += 1 } // skip the original path
                result.append(make(xy: Array(f[1]), path: String(f[9]), untracked: false))
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
        return GitChange(path: path, status: GitFileStatus(code: primary), isUntracked: untracked)
    }

    /// Fills each change's add/delete counts: `git diff --numstat` (unstaged) merged
    /// with `--cached` (staged) for tracked files, and a line count for untracked ones.
    private static func applyCounts(_ changes: inout [GitChange], repoRoot: String) {
        var counts: [String: (Int, Int)] = [:]
        for args in [["diff", "--numstat"], ["diff", "--numstat", "--cached"]] {
            guard let out = run(args, in: repoRoot) else { continue }
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let adds = Int(parts[0]) ?? 0   // "-" for binary → 0
                let dels = Int(parts[1]) ?? 0
                let path = String(parts[2])
                let existing = counts[path] ?? (0, 0)
                counts[path] = (existing.0 + adds, existing.1 + dels)
            }
        }
        for idx in changes.indices {
            if changes[idx].isUntracked {
                let abs = (repoRoot as NSString).appendingPathComponent(changes[idx].path)
                if let content = try? String(contentsOfFile: abs, encoding: .utf8), !content.isEmpty {
                    changes[idx].additions = content.split(separator: "\n", omittingEmptySubsequences: false).count
                }
            } else if let c = counts[changes[idx].path] {
                changes[idx].additions = c.0
                changes[idx].deletions = c.1
            }
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

    private static func loadDiffText(_ change: GitChange, _ repoRoot: String, commit: String? = nil) -> String {
        // History file row: the file's change within one commit. `--format=` strips the
        // commit header so parseDiff sees only the unified diff.
        if let commit {
            return run(["show", "--format=", "-M", commit, "--", change.path],
                       in: repoRoot, ignoreStatus: true) ?? ""
        }
        if change.isUntracked {
            // `--no-index` exits non-zero when the files differ, which is the normal
            // case here, so the status is ignored.
            return run(["diff", "--no-index", "--", "/dev/null", change.path],
                       in: repoRoot, ignoreStatus: true) ?? ""
        }
        // `diff HEAD` shows staged and unstaged together. Fall back to the split views
        // for a repo with no commit yet, or a fully-staged change.
        if let d = run(["diff", "HEAD", "--", change.path], in: repoRoot), !d.isEmpty { return d }
        let unstaged = run(["diff", "--", change.path], in: repoRoot) ?? ""
        if !unstaged.isEmpty { return unstaged }
        return run(["diff", "--cached", "--", change.path], in: repoRoot) ?? ""
    }

    /// Parses unified-diff text into rows, tracking old/new line numbers from each
    /// hunk header and dropping the file-header lines (`diff --git`, `+++`, …).
    private static func parseDiff(_ text: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var id = 0
        var oldNo = 0
        var newNo = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) { oldNo = o; newNo = n }
                rows.append(DiffRow(id: id, kind: .hunk, text: line, oldLine: nil, newLine: nil)); id += 1
                continue
            }
            if isFileHeader(line) { continue }
            guard let first = line.first else { continue }
            let body = String(line.dropFirst())
            switch first {
            case "+":
                rows.append(DiffRow(id: id, kind: .addition, text: body, oldLine: nil, newLine: newNo)); id += 1; newNo += 1
            case "-":
                rows.append(DiffRow(id: id, kind: .deletion, text: body, oldLine: oldNo, newLine: nil)); id += 1; oldNo += 1
            case " ":
                rows.append(DiffRow(id: id, kind: .context, text: body, oldLine: oldNo, newLine: newNo)); id += 1; oldNo += 1; newNo += 1
            default:
                continue
            }
        }
        return rows
    }

    private static func isFileHeader(_ line: String) -> Bool {
        for prefix in ["diff ", "index ", "--- ", "+++ ", "new file", "deleted file",
                       "old mode", "new mode", "similarity ", "dissimilarity ",
                       "rename ", "copy ", "\\ "] where line.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Pulls the starting old and new line numbers out of `@@ -a,b +c,d @@`.
    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        func start(_ s: Substring) -> Int? {
            Int(s.dropFirst().split(separator: ",").first ?? s.dropFirst())
        }
        guard let o = start(parts[1]), let n = start(parts[2]) else { return nil }
        return (o, n)
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
            let (host, path) = parseRemote(remote),
            let forge = Forge(host: host),
            let repo = URL(string: "https://\(host)/\(path)") else { return nil }
        guard run(["rev-parse", "--abbrev-ref", "@{upstream}"], in: dir) != nil,
              let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty, branch != "HEAD",
              let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return RemotePage(forge: forge, url: repo) }
        let branchURL = URL(string: "\(repo.absoluteString)/\(forge.branchPath(escaped))") ?? repo
        return RemotePage(forge: forge, url: branchURL)
    }

    /// Splits a remote into web-addressable host + repo path, from either the scp-like
    /// form (`git@host:owner/repo.git`) or a real URL (`https://…`, `ssh://…`). Ports
    /// and userinfo are dropped — the web UI lives on plain https.
    private static func parseRemote(_ remote: String) -> (host: String, path: String)? {
        var host: String
        var path: String
        if !remote.contains("://"), remote.contains("@"), let colon = remote.firstIndex(of: ":") {
            let hostPart = String(remote[..<colon])
            host = hostPart.components(separatedBy: "@").last ?? hostPart
            path = String(remote[remote.index(after: colon)...])
        } else if let url = URL(string: remote), let urlHost = url.host {
            host = urlHost
            path = url.path
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return (host, path)
    }

    // MARK: Process

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Runs `git -C <dir> <args>` and returns stdout, or `nil` on launch failure (or a
    /// non-zero exit unless `ignoreStatus`). stdout is drained *before* `waitUntilExit`
    /// because a diff can exceed the 64 KB pipe buffer and otherwise deadlock the child;
    /// stderr is sent to the null device so it can never fill either.
    private static func run(_ args: [String], in dir: String, ignoreStatus: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
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
