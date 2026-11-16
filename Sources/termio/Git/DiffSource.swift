import TermioShared
import Foundation

/// Where a diff comes from — this Mac's `git`, or the device the checkout lives
/// on. The one place in the pane that decides which machine runs the command.
///
/// It is a *provider swap and nothing more*: both roads produce unified-diff
/// **text**, and the diff page (`DiffWebView`) consumes text, so a device diff
/// renders through the identical stack — same bands, same intraline word diff,
/// same syntax pass. That was the whole bet in `docs/rfcs/remote-git-plane.md`
/// §2 and it holds.
enum DiffSource {
    /// One changed file's diff, as `git` prints it. `device` nil means this Mac.
    ///
    /// `fullContext` asks for the whole file as context (`-U999999`), which is how
    /// the page gets the lines a reader expands. A device answers that for the
    /// working tree only: its commit and compare verbs take no context, so those
    /// return nothing and their bands stay shut.
    static func patch(
        for change: GitChange,
        in repoRoot: String,
        device: TermiodRoute?,
        commit: String? = nil,
        range: String? = nil,
        fullContext: Bool = false
    ) async -> String {
        let context = fullContext ? 999_999 : nil
        guard let device else {
            return await GitService.diffText(
                for: change, in: repoRoot, commit: commit, range: range, context: context)
        }
        // Three shapes, three verbs on the box: a commit's file is `git.show`,
        // a compare row is `git.compare`, and the working tree is `git.diff` —
        // inventing a local answer for a remote path would diff the wrong
        // machine's file.
        if let commit {
            guard !fullContext else { return "" }
            return (try? await Termiod.gitShowDiff(
                route: device, root: repoRoot, commit: commit, path: change.path)) ?? ""
        }
        if let range {
            guard !fullContext, let base = compareBase(of: range) else { return "" }
            return (try? await Termiod.gitCompareDiff(
                route: device, root: repoRoot, base: base, path: change.path)) ?? ""
        }
        return await text(for: change, in: repoRoot, device: device, context: context)
    }

    /// Both sides of one changed file in full, for expanding the context its diff
    /// left out. Nil when the file is too large to carry whole, or the source has
    /// no way to ask for it.
    static func fullText(
        for change: GitChange,
        in repoRoot: String,
        device: TermiodRoute?,
        commit: String? = nil,
        range: String? = nil
    ) async -> DiffFullText? {
        let text = await patch(
            for: change, in: repoRoot, device: device,
            commit: commit, range: range, fullContext: true)
        // ~20k lines of average code ≈ 1.5 MB. Past that the bands stay shut
        // rather than hand the page a whole huge file twice.
        guard !text.isEmpty, text.utf8.count <= 1_500_000 else { return nil }
        return await Task.detached { DiffFullText(fullContextPatch: text) }.value
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
