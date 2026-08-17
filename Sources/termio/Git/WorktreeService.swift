import Foundation

// MARK: - Worktree discovery

/// Discovers a repo's linked git worktrees so the sidebar reflects them no matter who
/// created them — termio's own "New Worktree" *or* a plain `git worktree add` on the CLI.
/// Git is the source of truth; `TermioStore` reconciles `Project.worktrees` against this
/// (the one piece of git state termio used to mirror instead of read). Runs off-main.
enum WorktreeService {
    /// The linked worktree paths for `repoRoot`, primary checkout excluded and paths
    /// standardized. `nil` when `git worktree list` fails (not a work tree, or a git
    /// error) — the caller treats `nil` as "leave the current list alone" and `[]` as
    /// "git genuinely reports no linked worktrees" (safe to prune).
    static func linkedWorktrees(in repoRoot: String) async -> [String]? {
        await offMain {
            guard let out = run(["worktree", "list", "--porcelain"], in: repoRoot) else { return nil }
            return parse(out)
        }
    }

    /// Parses `git worktree list --porcelain`: blank-line-separated records, each opening
    /// with `worktree <path>`. The first record is the primary checkout (dropped); `bare`
    /// entries are skipped; what remains are the linked worktrees, in git's order.
    ///
    /// A `prunable` worktree — its directory deleted out from under git — is skipped, as is
    /// any path that no longer exists on disk. Without this, a stale worktree would show in
    /// the sidebar and a session started there would launch with a missing cwd, so the shell
    /// silently falls back to `/` (the bug this guards against).
    private static func parse(_ text: String) -> [String] {
        var result: [String] = []
        for (index, record) in text.components(separatedBy: "\n\n").enumerated() {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let worktreeLine = lines.first(where: { $0.hasPrefix("worktree ") }) else { continue }
            if index == 0 { continue }                                  // primary checkout
            if lines.contains(where: { $0 == "bare" }) { continue }
            if lines.contains(where: { $0.hasPrefix("prunable") }) { continue }
            let path = String(worktreeLine.dropFirst("worktree ".count))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            result.append(URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        return result
    }

    // MARK: Process

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// `git -C <dir> <args>` → trimmed stdout, or `nil` on launch failure / non-zero exit —
    /// the same degrade-to-nothing stance as `GitService`/`BranchModel`.
    private static func run(_ args: [String], in dir: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        process.environment = GitEnvironment.optionalLocksDisabled
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
