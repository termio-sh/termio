import Foundation

// MARK: - Issue cache

/// App-level cache of fetched issue / pull-request data, keyed by *remote* identity (the
/// `owner/repo` container) rather than the local checkout path. Held on `TermioStore`, so both the
/// list and any open detail survive everything that tears an `IssuesPanelModel` down — the inspector
/// switching tab, collapsing, remounting on a session switch, or a *second worktree of the same
/// repo* opening the same pane. Issues and PRs are a property of the remote repo, not the local
/// clone, so two worktrees share one cached copy.
///
/// This is the "flat cache" pattern (Khanlou; GitHawk's `FlatCache`): the data lives *above* the
/// view, keyed by object id, so the view is a pure projection that reads on mount instead of
/// re-fetching. Reads are stale-while-revalidate — see `IssuesPanelModel.loadList` / `loadDetail`.
@MainActor
final class IssueCache {

    // MARK: Detail

    struct DetailKey: Hashable {
        let container: IssueContainer
        let number: Int
    }

    /// One fetched item: the conversation plus (for PRs) the changed files and their inline
    /// patches — everything `loadDetail` populates in one shot, so a warm read restores the
    /// whole detail with no further network or git work. `fetchedAt` drives the revalidation dedupe
    /// window.
    struct Entry {
        var detail: IssueDetail
        var prFiles: [GitChange]
        var prFilePatches: [String: String]
        /// Each file's `contents_url` at the PR head, so a reopened-from-cache Files tab can
        /// still read the file to expand a hunk boundary.
        var prFileContentURLs: [String: URL]
        /// The conversation is cached the instant it lands — *before* a PR's heavy `/files`
        /// response — so even opening a PR and immediately switching away warms the cache. This
        /// marks whether that file list has since folded in: `false` means "files still pending",
        /// so a warm read fetches them (rather than mistaking it for a PR that changes no files).
        /// Always `true` for an issue (no files) and for a fully fetched PR.
        var filesLoaded: Bool
        var fetchedAt: Date

        /// Whether another entry carries the same remotely fetched content (ignoring `filesLoaded`
        /// and `fetchedAt`), so a revalidation that finds nothing changed can skip republishing and
        /// never flickers the open detail.
        func sameContent(as other: Entry) -> Bool {
            detail == other.detail
                && prFiles == other.prFiles
                && prFilePatches == other.prFilePatches
                && prFileContentURLs == other.prFileContentURLs
        }
    }

    private var details: [DetailKey: Entry] = [:]

    func entry(_ container: IssueContainer, _ number: Int) -> Entry? {
        details[DetailKey(container: container, number: number)]
    }

    func store(_ entry: Entry, _ container: IssueContainer, _ number: Int) {
        details[DetailKey(container: container, number: number)] = entry
    }

    // MARK: List

    /// A list is a property of both the repo *and* the query (kind, filters), so switching the
    /// Issues / Pull Requests segment or a label filter is its own cached slot.
    struct ListKey: Hashable {
        let container: IssueContainer
        let query: IssueQuery
    }

    struct ListEntry {
        var items: [IssueSummary]
        var fetchedAt: Date
    }

    private var lists: [ListKey: ListEntry] = [:]

    func list(_ container: IssueContainer, _ query: IssueQuery) -> ListEntry? {
        lists[ListKey(container: container, query: query)]
    }

    func storeList(_ items: [IssueSummary], _ container: IssueContainer, _ query: IssueQuery) {
        lists[ListKey(container: container, query: query)] = ListEntry(items: items, fetchedAt: Date())
    }

    // MARK: Lifecycle

    /// Drops everything — called when the GitHub token is removed (`IssuesPanelModel.disconnect`),
    /// since a signed-out or re-authed-as-someone-else session must not read a prior account's
    /// cached private-repo data.
    func clear() {
        details.removeAll()
        lists.removeAll()
    }
}
