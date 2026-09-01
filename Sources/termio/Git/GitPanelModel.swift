import TermioShared
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
    /// The machine `repoRoot` lives on, when it is not this Mac. A device
    /// checkout is driven the other way round from a local one: the box already
    /// watches its own workspace and publishes status deltas, so the pane
    /// subscribes and applies them instead of running `git status` on a timer.
    /// This is the shape Zed pushes as `UpdateRepository` and VS Code gets by
    /// running the git extension on the remote — nobody polls a remote checkout.
    let device: TermiodRoute?

    @Published var changes: [GitChange] = []
    @Published var isLoading = true

    /// Whether `repoRoot` is a git work tree. A loose terminal's cwd follows the shell,
    /// so the pane is regularly pointed at a folder git knows nothing about; without
    /// this the empty change list would render as "the working tree is clean". Starts
    /// `true` so the first pass shows the spinner rather than flashing the non-repo
    /// state, and is only ever lowered by a completed probe.
    @Published private(set) var isRepository = true

    /// The commit history, loaded lazily the first time the History tab is shown.
    @Published var commits: [GitCommit] = []
    @Published var isLoadingHistory = false
    private var didLoadHistory = false

    /// The branch and the refs it can be compared against, for the Compare tab's base
    /// picker. Nil until that tab is first opened; re-read whenever the git dir changes,
    /// so a checkout in the terminal moves the picker with it.
    @Published var compareContext: GitService.CompareContext?
    /// The base the Compare tab is measuring the branch against.
    @Published private(set) var compareBase: String?
    /// `nil` while a comparison is loading — the Compare tab shows a spinner then, so no
    /// separate loading flag is needed.
    @Published private(set) var compare: GitService.BranchCompare?
    /// Why the comparison couldn't be made, when it couldn't. Held as its own state so the
    /// pane can say so — an empty file list would read as "nothing to review".
    @Published private(set) var compareProblem: GitService.CompareProblem?

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
    private nonisolated static let ignoredEventComponents: Set<String> = [
        ".build", "node_modules", "DerivedData", ".venv", ".gradle", ".turbo", ".next",
    ]

    /// Whether an event path sits under a build-product directory *inside* one of the
    /// watched roots. The roots' own ancestry is deliberately not inspected.
    /// `nonisolated` because the FSEvents handler calls it on the watcher's own queue —
    /// it is pure string work over its arguments and touches no actor state.
    private nonisolated static func isBuildProductEvent(_ path: String, underAny roots: [String]) -> Bool {
        for root in roots where path == root || path.hasPrefix(root + "/") {
            return path.dropFirst(root.count).split(separator: "/")
                .contains { ignoredEventComponents.contains(String($0)) }
        }
        // An event outside every watched root (FSEvents shouldn't produce one)
        // stays relevant rather than being silently swallowed.
        return false
    }

    init(repoRoot: String, device: TermiodRoute? = nil, isPaneVisible: (() -> Bool)? = nil) {
        self.repoRoot = repoRoot
        self.device = device
        self.isPaneVisible = isPaneVisible
        // Re-activation catches whatever happened while termio was in the background
        // (a rebase in another app, a pull on another machine's shared folder…).
        // A device checkout needs no such catch-all: its watch runs on the box
        // and kept publishing while this app was not even in front.
        guard device == nil else { return }
        appActiveObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleRefresh(includeHistory: true) }
    }

    deinit { refreshDebounce?.cancel() }

    // MARK: The device's own status

    /// The subscription to `git:<root>` on the device, and the cursor into its
    /// batches — so a dropped channel resumes from the replay ring rather than
    /// re-reading a whole status.
    private var gitWatch: Termiod.ResourceSubscription?
    /// Where a resubscribe resumes from. Never the ack's `seq` — see
    /// `ResourceCursor`, which is the rule and the reason.
    private var gitCursor = ResourceCursor()
    /// A gap subscriber's first batch is the device's synthesized *full* state
    /// at its current seq, not a delta (`resource.rs` `subscribe_git`). There is
    /// nothing before it to be missing, so the cursor adopts it outright — which
    /// is also what keeps a reconnect from re-snapshotting forever.
    private var awaitingFullBaseline = false
    private var resubscribing = false
    /// Orders the pieces of a subscribe handshake that reach the main actor on
    /// different paths — see `DeviceWatchLedger`.
    private var watchLedger = DeviceWatchLedger<Termiod.GitChangedPayload>()
    /// The status the device has published so far, keyed by path. The batches
    /// are **deltas**, so the pane holds the baseline they apply to.
    private var deviceStatuses: [String: GitChange] = [:]
    /// What the device says the checkout's branch is, for a pane that wants to
    /// name it. Absent until the first batch lands.
    @Published private(set) var deviceBranch: String?
    /// How many paths the device's checkout really has changed, when it cut
    /// the list below that. The rows shown are real; the list is not all of
    /// them, and the pane says how many are missing rather than let a
    /// head-of-list read as the working tree.
    @Published private(set) var deviceListTotal: Int?

    /// Starts (or resumes) the device subscription. Idempotent: the pane calls
    /// it on appear and whenever it becomes visible again.
    func startDeviceWatch() {
        guard let device, gitWatch == nil else { return }
        guard !resubscribing else {
            // A stop followed immediately by an appear can land while the old
            // subscribe still awaits its acknowledgement. Supersede that
            // handshake and have its cleanup begin the new one.
            watchLedger.requestRestart()
            return
        }
        resubscribing = true
        let generation = watchLedger.begin()
        // The replay this attempt is about to get arrives in order from the
        // cursor, so nothing before it counts as stale any more.
        gitCursor.beginAttempt()
        Task { [repoRoot] in
            defer {
                resubscribing = false
                if watchLedger.consumeRestartRequest() {
                    startDeviceWatch()
                }
            }
            do {
                let (subscription, gap, seq) = try await Termiod.watchGit(
                    route: device,
                    root: repoRoot,
                    since: gitCursor.resumeFrom,
                    onBatch: { [weak self] batch in
                        Task { @MainActor in self?.receive(batch, generation: generation) }
                    },
                    onInterrupted: { [weak self] in
                        Task { @MainActor in
                            self?.deviceWatchInterrupted(generation: generation)
                        }
                    })
                guard watchLedger.settle(generation: generation) else {
                    // The pane stopped (or restarted) the watch while this
                    // handshake was in flight; the subscription must not
                    // outlive the interest that asked for it.
                    subscription.cancel()
                    return
                }
                gitWatch = subscription
                // A gap means the ring could not replay from this cursor, so the
                // baseline is not trustworthy: drop it and let the device's
                // synthesized full batch rebuild it. The reset lands *before*
                // any batch applies — batches that raced the ack sat in the
                // ledger and apply below, so the full batch can never be erased
                // by its own gap reset.
                if gap {
                    deviceStatuses = [:]
                    deviceListTotal = nil
                    gitCursor.reset()
                    // `seq == 0` means the device has published nothing, so no
                    // full batch is coming and there is no baseline to wait for.
                    awaitingFullBaseline = seq > 0
                }
                // A clean resume deliberately leaves the cursor alone: it moves
                // in `apply`, for batches that actually applied.
                // Drained one at a time rather than as an array: a batch that
                // arrives during this loop queues behind what is left of it
                // instead of overtaking it (`DeviceWatchLedger.releaseNext`).
                while let batch = watchLedger.releaseNext(generation: generation) {
                    apply(batch)
                }
                // The ack only says the device accepted the subscription; the
                // baseline follows a beat later (measured at 2 ms behind it).
                // Waiting for it is what keeps a repo with changes from flashing
                // "No Changes" — but a checkout that has nothing to say sends no
                // batch at all, and a spinner that never stops would be the
                // pane's answer to a clean tree. So: wait briefly, then settle.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.watchLedger.generation == generation else { return }
                    self.isLoading = false
                }
            } catch {
                guard watchLedger.generation == generation else { return }
                isLoading = false
                deviceProblem = Self.message(for: error)
            }
        }
    }

    func stopDeviceWatch() {
        watchLedger.stop()
        awaitingFullBaseline = false
        gitCursor.reset()
        gitWatch?.cancel()
        gitWatch = nil
    }

    /// Routes one arriving batch through the ledger: applied when the watch is
    /// settled, held when the handshake's baseline decision is still in
    /// flight, dropped when it belongs to a watch that was stopped.
    private func receive(_ batch: Termiod.GitChangedPayload, generation: Int) {
        guard let ready = watchLedger.admit(batch, generation: generation) else { return }
        apply(ready)
    }

    /// Why the device's git pane is empty, when it is empty for a reason. Held
    /// apart from the list so "no changes" and "not a git repository" cannot
    /// read as the same thing.
    @Published private(set) var deviceProblem: String?

    private func deviceWatchInterrupted(generation: Int) {
        guard watchLedger.generation == generation else { return }
        gitWatch = nil
        guard !resubscribing else { return }
        Task {
            // Let the drop settle before the next request reopens the channel.
            try? await Task.sleep(for: .seconds(1))
            guard watchLedger.isCurrent(generation) else { return }
            startDeviceWatch()
        }
    }

    /// Applies one `git_changed` delta to the baseline the pane holds.
    private func apply(_ batch: Termiod.GitChangedPayload) {
        if awaitingFullBaseline {
            awaitingFullBaseline = false
            gitCursor.adoptBaseline(batch.seq)
        } else if gitCursor.admit(seq: batch.seq) == .drop {
            // A delta already folded into the baseline this pane holds.
            // Re-applying it would resurrect a path that has since been
            // cleaned, or bury one that has since changed.
            return
        }
        for path in batch.removedPaths {
            deviceStatuses.removeValue(forKey: path)
        }
        for entry in batch.updatedStatuses {
            if let change = GitChange(device: entry) {
                deviceStatuses[entry.path] = change
            } else {
                // Ignored, or a status this build cannot draw: not a row.
                deviceStatuses.removeValue(forKey: entry.path)
            }
        }
        deviceBranch = batch.branch
        deviceListTotal = batch.total
        deviceProblem = nil
        changes = Self.sorted(Array(deviceStatuses.values))
        isLoading = false
        refreshDeviceReads(head: batch.head)
    }

    /// The head this pane last read History and Compare at. A batch whose head
    /// moved means a commit, a checkout, or a fetch happened on the box — the
    /// same signals the local pane's git-dir watch reloads on.
    private var deviceReadHead: String?

    /// Re-reads whatever device History and Compare state has already been
    /// loaded, when the checkout moved under it. Nothing is fetched that a tab
    /// has not asked for: an unopened History tab stays unloaded.
    private func refreshDeviceReads(head: String?) {
        guard let head, head != deviceReadHead else { return }
        let firstReading = deviceReadHead == nil
        deviceReadHead = head
        // The first batch only establishes the head; the tabs load themselves.
        guard !firstReading else { return }
        Task {
            if didLoadHistory { await loadHistory(force: true) }
            if compareContext != nil {
                await loadCompareContext()
                await loadCompare()
            }
        }
    }

    /// Conflicts first — the one status that must be acted on — then by path, so
    /// siblings cluster the way the file tree shows them. The same order
    /// `GitService.loadChanges` puts a local list in.
    private static func sorted(_ changes: [GitChange]) -> [GitChange] {
        changes.sorted { first, second in
            if (first.status == .conflicted) != (second.status == .conflicted) {
                return first.status == .conflicted
            }
            return first.path.localizedCaseInsensitiveCompare(second.path) == .orderedAscending
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case DeviceGitError.unsupported:
            return localized("This device’s termiod is too old to read git.")
        case TermiodClientError.requestFailed(let detail) where !detail.isEmpty:
            return detail
        default:
            return localized("The device couldn’t read this checkout.")
        }
    }

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
        // A device checkout is not loaded, it is subscribed to: running `git` here
        // against a path on another machine would either fail or — worse — answer
        // about a same-named directory on this one.
        if device != nil {
            startDeviceWatch()
            return
        }
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
            // A non-empty list is itself proof of a work tree, so the extra `rev-parse`
            // only runs for the ambiguous case — a clean repo or a plain folder.
            let repository = loaded.isEmpty ? await GitService.isWorkTree(at: repoRoot) : true
            if generation == loadGeneration || attempt == 1 {
                changes = loaded
                isRepository = repository
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

    /// Monotonic tickets for the three read loaders below: only the newest
    /// pass may publish. Two refreshes can overlap — a burst of device head
    /// changes, a git-dir event landing during a forced reload — and without
    /// the ticket the slower, older read wins and the pane shows a checkout
    /// the repository has already left.
    private var historyGeneration = 0
    private var compareContextGeneration = 0
    private var compareGeneration = 0

    /// Loads the commit history on demand (first time the History tab opens); re-run
    /// with `force` when the git dir reports a change.
    func loadHistory(force: Bool = false) async {
        guard force || !didLoadHistory else { return }
        didLoadHistory = true
        historyGeneration += 1
        let generation = historyGeneration
        isLoadingHistory = commits.isEmpty
        let loaded: [GitCommit]
        if let device {
            // A failed read degrades to an empty list, exactly as the local
            // path does when `git log` exits non-zero.
            loaded = (try? await Termiod.gitLog(route: device, root: repoRoot).commits) ?? []
        } else {
            loaded = await GitService.log(in: repoRoot)
        }
        guard generation == historyGeneration else { return }
        commits = loaded
        isLoadingHistory = false
    }

    // MARK: Branch compare

    /// Re-reads the branch and the bases it can be compared against. Cheap enough to run
    /// on every history refresh: three `git` reads of refs, no diff.
    func loadCompareContext() async {
        compareContextGeneration += 1
        let generation = compareContextGeneration
        let loaded: GitService.CompareContext?
        if let device {
            loaded = try? await Termiod.gitBranches(route: device, root: repoRoot)
        } else {
            loaded = await GitService.compareContext(in: repoRoot)
        }
        guard generation == compareContextGeneration else { return }
        compareContext = loaded
    }

    /// Points the Compare tab at a base branch (or `nil` for none) and loads the
    /// comparison. The base itself is remembered by the view, per branch.
    func setCompareBase(_ base: String?) async {
        guard base != compareBase else { return }
        compareBase = base
        compare = nil
        compareProblem = nil
        await loadCompare()
    }

    /// Loads the diff and commits between the branch and its base. A base picked while a
    /// load is in flight wins: the stale result is dropped rather than published under the
    /// new base's label.
    func loadCompare() async {
        guard let base = compareBase else {
            compare = nil
            compareProblem = nil
            return
        }
        compareGeneration += 1
        let generation = compareGeneration
        let outcome: GitService.CompareOutcome
        if let device {
            outcome = await Self.deviceBranchCompare(route: device, root: repoRoot, base: base)
        } else {
            outcome = await GitService.branchCompare(base: base, in: repoRoot)
        }
        // The base check catches a re-pick; the generation catches a same-base
        // refresh overtaken by a newer one.
        guard compareBase == base, generation == compareGeneration else { return }
        switch outcome {
        case .ready(let loaded):
            compare = loaded
            compareProblem = nil
        case .problem(let problem):
            compare = nil
            compareProblem = problem
        }
    }

    /// The device's comparison: one `git.compare` reply carrying files,
    /// commits, and behind — all walked from the one head the device pinned,
    /// so the three can never describe different checkouts.
    private static func deviceBranchCompare(
        route: TermiodRoute, root: String, base: String
    ) async -> GitService.CompareOutcome {
        do {
            let compared = try await Termiod.gitCompare(route: route, root: root, base: base)
            if let problem = compared.problem { return .problem(problem) }
            return .ready(GitService.BranchCompare(
                base: base, files: compared.files,
                commits: compared.commits, behind: compared.behind))
        } catch {
            Log.termiod.error("""
            device compare against \(base, privacy: .public) failed: \
            \(String(describing: error), privacy: .public)
            """)
            // Stated, never folded into an empty list — an empty comparison
            // reads as "this branch changes nothing".
            return .problem(.unreadable)
        }
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
        guard device == nil else { return }
        let (tree, gitDirs) = await GitService.watchPaths(for: repoRoot)
        guard watcher == nil, !gitDirs.isEmpty else { return }
        // The primary checkout's `.git` sits inside the tree and needs no second watch.
        // Immutable, because the handler below runs off the main actor and captures it.
        let paths = [tree] + gitDirs.filter { !$0.hasPrefix(tree + "/") }
        watcher = FolderEventStream(
            paths: paths, latency: 0.4,
            queue: DispatchQueue(label: "sh.termio.gitpane.fsevents", qos: .utility)
        ) { [weak self] eventPaths, _ in
            // Runs on the FSEvents queue: everything up to the hop below must stay
            // off the main actor. Build-product churn can't change the pane; don't
            // let it spawn git.
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
            // A commit, a checkout, or a fetch all land as git-dir events, and each one
            // moves the comparison: new commits ahead, a different branch, a base that
            // just gained commits. Gated on the Compare tab having been opened at least
            // once (which is what fills `compareContext`), like the log above — a
            // Changes-only session must not pay four `git` spawns an event.
            if includeHistory, self.compareContext != nil {
                await self.loadCompareContext()
                await self.loadCompare()
            }
        }
    }
}
