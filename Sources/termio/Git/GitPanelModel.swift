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
    /// Monotonic ticket for `load()` — only the newest pass may publish.
    private var loadGeneration = 0
    /// One `git status` in flight at a time: `load()` sets `loading` while it runs,
    /// and any call that lands mid-pass (the FSEvents debounce *or* a direct
    /// `model.load()` from the view) sets `loadReentered` to request a single
    /// replay instead of spawning an overlapping, expensive status — the way VS
    /// Code serializes its own status.
    private var loading = false
    private var loadReentered = false

    /// Whether the pane is actually on screen, read live at refresh time. A collapsed
    /// inspector keeps this model alive (the hosting view stays in the hierarchy), and
    /// before this gate the file-system watch kept re-running `git status` — four git
    /// spawns a burst — for a pane nobody could see. `nil` when the caller has no
    /// visibility signal; treated as visible.
    private let isPaneVisible: (() -> Bool)?
    /// A refresh that arrived while hidden, replayed on the next `flushDeferredRefresh`.
    /// Deferred, not dropped — the pane must be correct the moment it shows.
    private var deferredRefreshIncludesHistory: Bool?

    /// Directory names whose events can't change what the pane shows: build products
    /// and package caches that are gitignored in practice. An agent's `swift build`
    /// writes thousands of files under `.build`, and every burst was a full change-list
    /// pass; dropping these keeps the watch quiet through builds. Only components
    /// *below a watched root* count — a repo that itself lives under a directory
    /// named like a build product must not go deaf to every event. A repo that
    /// actually tracks one of these still stays honest — any event outside the list,
    /// and app re-activation, reload from git, the source of truth.
    private static let ignoredEventComponents: Set<String> = [
        ".build", "node_modules", "DerivedData", ".venv", ".gradle", ".turbo", ".next",
    ]

    /// Whether an event path sits under a build-product directory *inside* one of the
    /// watched roots. The roots' own ancestry is deliberately not inspected.
    private static func isBuildProductEvent(_ path: String, underAny roots: [String]) -> Bool {
        for root in roots where path == root || path.hasPrefix(root + "/") {
            return path.dropFirst(root.count).split(separator: "/")
                .contains { ignoredEventComponents.contains(String($0)) }
        }
        // An event outside every watched root (FSEvents shouldn't produce one)
        // stays relevant rather than being silently swallowed.
        return false
    }

    init(repoRoot: String, isPaneVisible: (() -> Bool)? = nil) {
        self.repoRoot = repoRoot
        self.isPaneVisible = isPaneVisible
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
    ///
    /// Serialized: only one `git status` runs at a time. Every refresh path funnels
    /// through here — the watcher and the view's direct `model.load()` calls alike —
    /// so a call that arrives mid-pass flags a replay rather than spawning an
    /// overlapping status. (Runs on the main actor, so the flags need no lock.)
    ///
    /// Immediate replays are capped at one. The first pass is suppressed if a reentry
    /// superseded it (its snapshot predates whatever change triggered the reentry —
    /// a discard, ignore, checkout); the single replay always publishes best-effort.
    /// If events *still* arrive through that replay — a continuously churning tree —
    /// we publish anyway and hand off to a debounced refresh instead of looping here,
    /// so the pane can never livelock (spinning `git status`, `isLoading` stuck on).
    func load() async {
        if loading {
            loadReentered = true
            loadGeneration += 1   // supersede the in-flight pass's stale snapshot
            return
        }
        loading = true
        defer { loading = false }
        for attempt in 0...1 {
            loadReentered = false
            loadGeneration += 1
            let generation = loadGeneration
            let loaded = await GitService.changes(in: repoRoot)
            if generation == loadGeneration || attempt == 1 {
                changes = loaded
                isLoading = false
            }
            if watcher == nil { await armWatcher() }
            if !loadReentered { break }
        }
        if loadReentered {
            loadReentered = false
            scheduleRefresh(includeHistory: false)   // still churning: catch up off-stack
        }
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

    /// Replays a refresh that was deferred while the pane was hidden. Called by the
    /// view when the pane (re)appears, so the shown list is never stale.
    func flushDeferredRefresh() {
        guard let includeHistory = deferredRefreshIncludesHistory else { return }
        deferredRefreshIncludesHistory = nil
        scheduleRefresh(includeHistory: includeHistory)
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
            // Build-product churn can't change the pane; don't let it spawn git.
            let relevant = eventPaths.filter { path in
                !Self.isBuildProductEvent(path, underAny: paths)
            }
            guard !relevant.isEmpty else { return }
            let touchesGitDir = relevant.contains { path in
                gitDirs.contains { path.hasPrefix($0) } || path.contains("/.git/") || path.hasSuffix("/.git")
            }
            Task { @MainActor [weak self] in
                self?.scheduleRefresh(includeHistory: touchesGitDir)
            }
        }
    }

    /// Coalesces a burst of events (FSEvents latency already batches most) into one
    /// reload a beat later. `git status` no longer echoes back as a git-dir event —
    /// `GIT_OPTIONAL_LOCKS=0` keeps it from writing the index — so the chain ends
    /// after one pass. While the pane is hidden the reload is parked instead (see
    /// `flushDeferredRefresh`).
    private func scheduleRefresh(includeHistory: Bool) {
        if let isPaneVisible, !isPaneVisible() {
            deferredRefreshIncludesHistory = (deferredRefreshIncludesHistory ?? false) || includeHistory
            return
        }
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.load()
            if includeHistory, self.didLoadHistory { await self.loadHistory(force: true) }
        }
    }
}
