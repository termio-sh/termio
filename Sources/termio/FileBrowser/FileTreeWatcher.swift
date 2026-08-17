import Foundation

/// A recursive filesystem watch over the file tree's root, so the explorer picks up
/// files an agent (or any outside tool) creates, renames, or deletes without waiting
/// for the manual Refresh button. Owns one `FolderEventStream` at a time, restarting
/// it when the root moves.
///
/// Events are split the way VS Code and Zed both split them:
/// - Version-control metadata (a `.git`/`.svn`/`.hg` path component) never reaches
///   the tree — the explorer doesn't show it, yet an agent running git churns it
///   constantly (every status/commit/fetch writes index, objects, refs). Object-store
///   churn (`.git/objects`, packs) is dropped outright — VS Code's default
///   `files.watcherExclude` excludes exactly that; what remains (index, HEAD, refs)
///   bumps only `gitToken`, so the Changes badge can re-count without a tree pass.
/// - Everything else accumulates in `pendingTreePaths` (the changed directories, as
///   FSEvents reports them) and bumps `treeToken`; the view then refreshes just the
///   realized directories that were touched rather than rebuilding the whole tree.
@MainActor
final class FileTreeWatcher: ObservableObject {
    /// Bumped once per settled batch of non-VCS changes; `drainTreePaths()` hands
    /// over the directories affected.
    @Published private(set) var treeToken = 0
    /// Bumped once per settled batch of meaningful git-metadata changes (index,
    /// HEAD, refs — a stage, commit, or checkout).
    @Published private(set) var gitToken = 0

    /// A settled batch of tree-relevant changes. `needsFullRescan` is set when
    /// FSEvents reported an overflow (`MustScanSubDirs`) or a root move — the paths
    /// no longer enumerate everything that changed, so the only safe response is a
    /// full rebuild.
    struct TreeBatch {
        let paths: Set<String>
        let needsFullRescan: Bool
    }

    private var stream: FolderEventStream?
    private var watchedPath: String?
    private var treeDebounce: DispatchWorkItem?
    private var gitDebounce: DispatchWorkItem?
    private var pendingTreePaths: Set<String> = []
    private var pendingFullRescan = false

    /// (Re)starts the recursive watch on `path`, tearing down any prior watch. A nil
    /// path (nothing selected) just stops watching. A no-op when the path is unchanged,
    /// so the every-render `onChange`/`onAppear` calls don't churn the stream.
    func watch(_ path: String?) {
        guard path != watchedPath else { return }
        watchedPath = path
        treeDebounce?.cancel()
        gitDebounce?.cancel()
        pendingTreePaths.removeAll()
        pendingFullRescan = false
        stream = nil
        guard let path else { return }
        // Deliver on the main queue so `ingest` can safely touch this main-actor
        // object; FSEvents' own latency window gives a first coalescing pass.
        stream = FolderEventStream(paths: [path], latency: 0.3, queue: .main) { [weak self] paths, flags in
            MainActor.assumeIsolated { self?.ingest(paths, flags) }
        }
    }

    /// Hands over (and clears) everything accumulated since the last drain.
    func drainTreeBatch() -> TreeBatch {
        defer {
            pendingTreePaths.removeAll()
            pendingFullRescan = false
        }
        return TreeBatch(paths: pendingTreePaths, needsFullRescan: pendingFullRescan)
    }

    private func ingest(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        var treeChanged = false
        var gitChanged = false
        for (raw, flag) in zip(paths, flags) {
            // The kernel/user-space queue overflowed or the root itself moved: the
            // batch no longer enumerates what changed, so incremental updating would
            // go silently stale — escalate to a full rebuild.
            let rescan = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            if flag & rescan != 0 {
                pendingFullRescan = true
                treeChanged = true
                continue
            }
            // FSEvents reports the changed *directories*, usually with a trailing slash.
            let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if Self.isGitMetadata(path) {
                if !Self.isGitNoise(path) { gitChanged = true }
            } else if Self.isOtherVCSMetadata(path) {
                // Shown by no pane at all — not even the Changes badge cares.
                continue
            } else {
                pendingTreePaths.insert(path)
                treeChanged = true
            }
        }
        if treeChanged { scheduleTreeTick() }
        if gitChanged { scheduleGitTick() }
    }

    /// True when `path` sits inside git metadata. Matched per component (not just
    /// under the root's own `.git`) so nested repositories' metadata is equally
    /// invisible — the tree never shows any of it (see `FileNode.ignoredNames`).
    private static func isGitMetadata(_ path: String) -> Bool {
        path.hasSuffix("/.git") || path.contains("/.git/")
    }

    /// Git churn that means nothing even to the Changes badge: the object store fills
    /// on every commit/fetch/gc without saying anything about working-tree state.
    /// Index/HEAD/refs changes stay meaningful (they move the badge and branch UI).
    private static func isGitNoise(_ path: String) -> Bool {
        path.contains("/.git/objects") || path.contains("/.git/subtree-cache")
    }

    /// Other VCS metadata the tree hides (`FileNode.ignoredNames`) and no badge reads.
    private static func isOtherVCSMetadata(_ path: String) -> Bool {
        for marker in ["/.svn", "/.hg"] where path.hasSuffix(marker) || path.contains(marker + "/") {
            return true
        }
        return false
    }

    /// A second, short coalescing step beyond FSEvents' latency, so a storm of
    /// callbacks (a git checkout, an npm install) collapses into one refresh shortly
    /// after the disk settles rather than one per callback.
    private func scheduleTreeTick() {
        treeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.treeToken += 1 }
        treeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func scheduleGitTick() {
        gitDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.gitToken += 1 }
        gitDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
