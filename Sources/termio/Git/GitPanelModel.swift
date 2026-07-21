import AppKit
import Combine
import SwiftUI

// MARK: - Git-pane state

/// Owns the mutable state of the git pane: the working-tree change list, the commit
/// history, and which of the two the pane is showing. termio's git pane is a *reading*
/// surface — you review working-tree diffs and read history; committing, pushing, and
/// pull requests all live in the terminal (`git commit` / `git push` / `gh`), where the
/// user already works. Discarding a file is the one working-tree edit it offers.
///
/// One instance lives per repo root (the view is given a fresh identity via `.id(repoRoot)`
/// when the selected project changes), so `repoRoot` is fixed for the model's lifetime.
@MainActor
final class GitPanelModel: ObservableObject {
    let repoRoot: String

    @Published var changes: [GitChange] = []
    @Published var isLoading = true

    /// The commit history, loaded lazily the first time the History tab is shown.
    @Published var commits: [GitCommit] = []
    @Published var isLoadingHistory = false
    private var didLoadHistory = false

    private var watcher: FolderEventStream?
    private var appActiveObserver: AnyCancellable?
    private var refreshDebounce: Task<Void, Never>?

    init(repoRoot: String) {
        self.repoRoot = repoRoot
        // Re-activation catches whatever happened while termio was in the background
        // (a rebase in another app, a pull on another machine's shared folder…).
        appActiveObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleRefresh(includeHistory: true) }
    }

    deinit { refreshDebounce?.cancel() }

    // MARK: Loading

    /// Reloads the working-tree change list. The first successful pass also arms the
    /// file-system watch, so from then on the pane refreshes itself.
    func load() async {
        changes = await GitService.changes(in: repoRoot)
        isLoading = false
        if watcher == nil { await armWatcher() }
    }

    /// Loads the commit history on demand (first time the History tab opens); re-run
    /// with `force` when the git dir reports a change.
    func loadHistory(force: Bool = false) async {
        guard force || !didLoadHistory else { return }
        didLoadHistory = true
        isLoadingHistory = commits.isEmpty
        commits = await GitService.log(in: repoRoot)
        isLoadingHistory = false
    }

    // MARK: Auto-refresh

    /// The pane has no refresh button for the same reason IDEs don't: an invalidation
    /// chain keeps it fresh instead. Any write under the worktree re-reads the changes
    /// list; a write under the git dir (the terminal committing, the agent staging,
    /// a branch flip) also re-reads history; app re-activation is the catch-all. The
    /// git dirs are watched separately because a linked worktree's metadata lives
    /// outside the checkout — see `GitService.watchPaths`.
    private func armWatcher() async {
        let (tree, gitDirs) = await GitService.watchPaths(for: repoRoot)
        guard watcher == nil, !gitDirs.isEmpty else { return }
        // The primary checkout's `.git` sits inside the tree and needs no second watch.
        var paths = [tree]
        paths += gitDirs.filter { !$0.hasPrefix(tree + "/") }
        watcher = FolderEventStream(
            paths: paths, latency: 0.4,
            queue: DispatchQueue(label: "sh.termio.gitpane.fsevents", qos: .utility)
        ) { [weak self] eventPaths in
            let touchesGitDir = eventPaths.contains { path in
                gitDirs.contains { path.hasPrefix($0) } || path.contains("/.git/") || path.hasSuffix("/.git")
            }
            Task { @MainActor [weak self] in
                self?.scheduleRefresh(includeHistory: touchesGitDir)
            }
        }
    }

    /// Coalesces a burst of events (FSEvents latency already batches most) into one
    /// reload a beat later. `git status` itself may refresh the index once, which
    /// echoes back as a git-dir event — the second pass reads clean and the chain ends.
    private func scheduleRefresh(includeHistory: Bool) {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.load()
            if includeHistory, self.didLoadHistory { await self.loadHistory(force: true) }
        }
    }
}
