import TermioShared
import Foundation

/// Where a diff comes from — this Mac's `git`, or the device the checkout lives
/// on. The one place in the pane that decides which machine runs the command.
///
/// It is a *provider swap and nothing more*: both roads produce unified-diff
/// **text**, and `DiffParser` / `DiffDocument` / `DiffTextView` already consume
/// text, so a device diff renders through the identical stack — same fold, same
/// intraline word diff, same syntax pass. That was the whole bet in
/// `docs/rfcs/remote-git-plane.md` §2 and it holds.
enum DiffSource {
    /// Rendered rows for one changed file. `device` nil means this Mac.
    static func rows(
        for change: GitChange,
        in repoRoot: String,
        device: TermiodRoute?,
        commit: String? = nil,
        range: String? = nil
    ) async -> [DiffRow] {
        guard let device else {
            return await GitService.diffRows(
                for: change, in: repoRoot, commit: commit, range: range)
        }
        // Three shapes, three verbs on the box: a commit's file is `git.show`,
        // a compare row is `git.compare`, and the working tree is `git.diff` —
        // inventing a local answer for a remote path would diff the wrong
        // machine's file.
        if let commit {
            let text = (try? await Termiod.gitShowDiff(
                route: device, root: repoRoot, commit: commit, path: change.path)) ?? ""
            return await GitService.parseDiffText(text)
        }
        if let range {
            guard let base = compareBase(of: range) else { return [] }
            let text = (try? await Termiod.gitCompareDiff(
                route: device, root: repoRoot, base: base, path: change.path)) ?? ""
            return await GitService.parseDiffText(text)
        }
        // Full context, exactly as the local path asks for it: the overlay holds
        // the whole file and collapses the unchanged runs into bands the reader
        // can expand. `GitService.diffRows` falls back to git's default context
        // when the row count is pathological; the device caps at 1 MiB instead,
        // and says so.
        let text = await text(
            for: change, in: repoRoot, device: device, context: 999_999)
        return await GitService.parseDiffText(text)
    }

    /// The base a compare row's range names. Every range this pane builds is
    /// `<base>...HEAD` (`GitHistoryView`, `GitService.loadBranchCompare`);
    /// `git.compare` takes the base because the device re-derives the range —
    /// and the behind count — from it.
    static func compareBase(of range: String) -> String? {
        guard range.hasSuffix("...HEAD") else { return nil }
        let base = String(range.dropLast("...HEAD".count))
        return base.isEmpty ? nil : base
    }

    /// The raw unified-diff text — what "Copy Diff" puts on the pasteboard.
    static func text(
        for change: GitChange, in repoRoot: String, device: TermiodRoute?,
        context: Int? = nil
    ) async -> String {
        guard let device else {
            return await GitService.diffText(for: change, in: repoRoot)
        }
        do {
            // A fully staged change has nothing in the worktree to diff, so the
            // index is what the row is about — the same choice the local path
            // makes by diffing against `HEAD`.
            let diff = try await Termiod.gitDiff(
                route: device, root: repoRoot, path: change.path,
                staged: change.isStaged, context: context)
            return diff.text
        } catch {
            Log.termiod.error("""
            device diff for \(change.path, privacy: .public) failed: \
            \(String(describing: error), privacy: .public)
            """)
            return ""
        }
    }
}
