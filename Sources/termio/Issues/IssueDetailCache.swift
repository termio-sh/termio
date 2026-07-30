import Foundation

// MARK: - Issue detail cache

/// App-level cache of fetched issue / pull-request detail, keyed by *remote* identity
/// (`owner/repo` container + number) rather than the local checkout path. Held on
/// `TermioStore`, so a fetched conversation and PR files survive everything that tears an
/// `IssuesPanelModel` down: the inspector switching tab, collapsing, remounting on a session
/// switch, or a *second worktree of the same repo* opening the same issue. Detail is a
/// property of the remote item, not the local clone — so two worktrees share one cached copy.
///
/// This is the "flat cache" pattern (Khanlou; GitHawk's `FlatCache`): the data lives *above*
/// the view, keyed by object id, so the view is a pure projection that reads on mount instead
/// of re-fetching. Detail opens become stale-while-revalidate — see
/// `IssuesPanelModel.loadDetail`.
@MainActor
final class IssueDetailCache {
    struct Key: Hashable {
        let container: IssueContainer
        let number: Int
    }

    /// One fetched item: the conversation plus (for PRs) the changed files, their inline
    /// patches, and branch facts — everything `loadDetail` populates in one shot, so a warm
    /// read restores the whole detail with no further network or git work. `fetchedAt` drives
    /// the revalidation dedupe window.
    struct Entry {
        var detail: IssueDetail
        var prFiles: [GitChange]
        var prFilePatches: [String: String]
        var prInfo: PullRequestGitInfo?
        /// The conversation is cached the instant it lands — *before* a PR's heavy `/files`
        /// response — so even opening a PR and immediately switching away warms the cache. This
        /// marks whether that file list has since folded in: `false` means "files still pending",
        /// so a warm read fetches them (rather than mistaking it for a PR that changes no files).
        /// Always `true` for an issue (no files) and for a fully fetched PR.
        var filesLoaded: Bool
        var fetchedAt: Date

        /// Whether another entry carries the same remotely fetched content (ignoring
        /// `fetchedAt`), so a revalidation that finds nothing changed can skip republishing
        /// and never flickers the open detail.
        func sameContent(as other: Entry) -> Bool {
            detail == other.detail
                && prFiles == other.prFiles
                && prFilePatches == other.prFilePatches
                && prInfo == other.prInfo
        }
    }

    private var entries: [Key: Entry] = [:]

    func entry(_ container: IssueContainer, _ number: Int) -> Entry? {
        entries[Key(container: container, number: number)]
    }

    func store(_ entry: Entry, _ container: IssueContainer, _ number: Int) {
        entries[Key(container: container, number: number)] = entry
    }

    /// Drops everything — called when the GitHub token is removed (`IssuesPanelModel.disconnect`),
    /// since a signed-out or re-authed-as-someone-else session must not read a prior account's
    /// cached private-repo detail.
    func clear() {
        entries.removeAll()
    }
}
