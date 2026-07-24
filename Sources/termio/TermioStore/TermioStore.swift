import AppKit
import Combine
import Foundation
import GhosttyTerminal

/// App-wide state: the project/session tree plus a cache of live terminal
/// surfaces. The cache ("SurfaceCache" in unpeel's terms) keeps one
/// `TerminalViewState` alive per session so switching sessions in the sidebar
/// does not tear down the running shell.
@MainActor
final class TermioStore: ObservableObject {
    @Published var projects: [Project] {
        // Any structural change to the tree (sessions added/closed, projects
        // edited) is written back to disk so the sidebar survives app restarts,
        // and the set of folders whose branch we track live is re-synced.
        didSet {
            persist()
            syncWatchedFolders()
            syncRuntimes()
        }
    }
    @Published var selectedSessionID: Session.ID? {
        // Selecting a session means the user is now looking at it, so any pending
        // "needs attention" (or unseen "done") is, by definition, answered.
        didSet {
            guard oldValue != selectedSessionID else { return }
            if let id = selectedSessionID {
                // A mid-turn `.working` keeps its spinner; only the resting
                // "your turn" states are answered by looking.
                markSeen(id)
                // Switching to a session counts as activity for its project, so the
                // "Recent Activity" sort floats a project the moment you focus it —
                // forced past the coalesce window since it's a deliberate user action.
                if let pid = project(for: id)?.id { noteProjectActivity(pid, force: true) }
            }
            persist()
        }
    }

    /// The split groups: each tree binds two or more sessions that share the
    /// screen whenever any of them is selected (VS Code's *terminal group*, not
    /// its editor group — selecting a session outside the visible group switches
    /// the whole terminal area to that session's own group, or its lone pane,
    /// rather than pulling the session into the current layout). A session
    /// belongs to at most one group; a user who never splits carries no extra
    /// state. Ratio drags write here at gesture rate, so persistence is
    /// debounced rather than inline.
    @Published var splitGroups: [SplitNode] = [] {
        didSet {
            guard oldValue != splitGroups else { return }
            persistDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.persist() }
            }
            persistDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// The split layout on screen: the group the selected session belongs to,
    /// or `nil` when it is ungrouped — then the selected session fills the
    /// terminal area as a single pane. Derived, so switching the selection is
    /// what swaps layouts; nothing ever edits a tree to follow the sidebar.
    var splitRoot: SplitNode? {
        guard let selected = selectedSessionID else { return nil }
        return splitGroups.first { $0.contains(selected) }
    }

    /// Which palette panel is up, or `nil` for none: ⌘⇧O Open Quickly (jump to
    /// a session) vs ⌘⇧P Command Palette (run an action). Transient UI state
    /// (not persisted), toggled by the View menu and cleared by the palette.
    @Published var paletteMode: PaletteMode?

    /// Whether the focused pane is zoomed to fill the terminal area (⌘⇧↩,
    /// tmux/iTerm2 style). Transient and not persisted; the zoom always targets
    /// the *selected* pane, so navigating focus while zoomed moves the full-size
    /// pane. `TerminalPane` honours it only while a split is on screen.
    @Published var isPaneZoomed = false

    /// The session currently being drag-reordered in the sidebar, recorded when a row
    /// drag begins so a hovered row can ask `canReorder` whether it's a legal drop
    /// target (same project + worktree bucket) and light its background only then.
    /// Transient drag bookkeeping — deliberately *not* `@Published`, since it's read
    /// on drop-hover events, never rendered.
    var draggingSessionID: Session.ID?

    /// When each project was last active — the moment one of its agents last reported
    /// work, or the user last switched to one of its sessions. Drives the sidebar's
    /// "Recent Activity" sort (see `orderedProjects`). In-memory and `@Published` so a
    /// change re-sorts the list live; it deliberately does not persist (a fresh launch
    /// falls back to the stored project order until activity resumes), which keeps the
    /// high-frequency working-event updates off the disk-writing `projects` array.
    @Published var liveActivity: [Project.ID: Date] = [:]

    /// The file currently open in the editor overlay, or `nil` when the terminal is showing.
    /// Transient UI state: clicking a text file in the inspector sets it, and the terminal
    /// pane covers itself with the editor while it is non-nil (see `TerminalPane` / `FileEditorView`).
    /// Opening a file dismisses any open diff — the two overlays are mutually exclusive.
    @Published var openFileURL: URL? {
        didSet {
            if openFileURL != nil { openDiff = nil; openTrace = nil }
            // Closing always returns to the editable default; a read-only open re-asserts the flag
            // immediately before setting the URL (see `openTerminalLink`). The jump line clears too,
            // so a later plain open of the same file doesn't scroll to a stale hit.
            else {
                openFileReadOnly = false
                openFileLine = nil
            }
        }
    }

    /// The 1-based line the editor should reveal when it opens `openFileURL` — set by a
    /// content-search hit (see `FileSearchView`); `nil` for a plain open (top of file).
    @Published var openFileLine: Int?

    /// Whether the open file should be shown read-only (no editing, no auto-save). Set when the file
    /// was opened by cmd-clicking a link in the terminal — a peek at the source, not an invitation to
    /// edit it by mistake. The inspector's own file opens stay editable (`openFileInEditor`).
    @Published var openFileReadOnly = false

    /// The changed file currently shown in the diff overlay, or `nil` when none is. The git
    /// counterpart of `openFileURL`: clicking a row in the Changes pane sets it, and the terminal
    /// pane covers itself with `GitDiffView` while it is non-nil. Opening a diff dismisses any open
    /// file editor.
    @Published var openDiff: GitDiffRequest? {
        didSet { if openDiff != nil { openFileURL = nil; openTrace = nil } }
    }

    /// The agent trace currently shown over the terminal, or `nil` when none is. The
    /// third content overlay alongside `openFileURL` and `openDiff`: the Info pane's
    /// "View Trace" sets it, and `TerminalPane` covers itself with `TraceView` while
    /// it is non-nil. Mutually exclusive with the other two.
    @Published var openTrace: TraceRequest? {
        didSet { if openTrace != nil { openFileURL = nil; openDiff = nil } }
    }

    /// Which pane the trailing inspector shows — the file tree or git changes. Set by the toolbar's
    /// segmented switch and read by `FileBrowserView`. (The inspector's open/closed state is owned by
    /// the app delegate's `NSSplitViewItem`, not mirrored here, so the two cannot desync.)
    @Published var inspectorTab: InspectorTab = .files

    /// The repo's dirty-file count, surfaced from the Changes pane so callers can reflect "has
    /// changes" without the inspector being open.
    @Published var gitChangeCount = 0

    /// Whether the trailing inspector panel is expanded. Mirrored from the AppKit
    /// split item — the owner of collapse state — via KVO in `App.swift`, so hosted
    /// panes can stand down while hidden: a collapsed item keeps its view hierarchy
    /// (and any `@StateObject` in it) alive, which left the git pane's auto-refresh
    /// spawning `git status` for a pane nobody could see.
    @Published var inspectorVisible = false

    /// Per-session high-frequency live state (status, running tool, live title, cwd),
    /// each held in its own `@Observable` `SessionRuntime` so a change re-renders only
    /// the owning sidebar row rather than the whole tree. Deliberately **not**
    /// `@Published`: the map's identity is stable (an entry is created when a session
    /// enters the tree — see `syncRuntimes` — and dropped when it leaves), and the
    /// reactive signal lives on each `SessionRuntime`, not on the store. Read through
    /// the accessors (`status(for:)`, `displayTitle(for:)`, …) so callers never couple
    /// to the storage; mutate through the private setters below, which guard against
    /// no-op writes and ping `sessionRuntimeDidChange` for the non-SwiftUI observers.
    private(set) var runtimes: [Session.ID: SessionRuntime] = [:]

    /// A coarse "some session's runtime changed" ping for observers that can't
    /// subscribe to a per-session `@Observable` — the menu-bar tray and the window
    /// title bar (both plain AppKit). The sidebar deliberately ignores this: its rows
    /// track their own `SessionRuntime`, so this signal never rebuilds the tree. The
    /// companion server doesn't need it either (it polls the store once a second).
    let sessionRuntimeDidChange = PassthroughSubject<Void, Never>()

    /// The runtime for a session, created on first touch. Callers that mutate state go
    /// through this; read-only paths use `runtimes[id]?` so a bare read never allocates.
    func runtime(for id: Session.ID) -> SessionRuntime {
        if let existing = runtimes[id] { return existing }
        let created = SessionRuntime()
        runtimes[id] = created
        return created
    }

    /// Drops a closed session's runtime. Called from the session/project teardown
    /// paths; `syncRuntimes` would also reap it on the next `projects` change, but the
    /// teardown sites clear the rest of a session's caches inline, so this keeps them
    /// in one place. (A dedicated method because `runtimes` is `private(set)`, so its
    /// setter is unreachable from the store's other-file extensions.)
    func removeRuntime(for id: Session.ID) {
        runtimes.removeValue(forKey: id)
    }

    /// Reconciles the runtime map with the live session set: creates a runtime for any
    /// session that lacks one (so its row has a stable object to observe from its very
    /// first render — an on-demand create during view update would both miss the
    /// dependency and warn about mutating state mid-render) and drops runtimes for
    /// sessions that have closed. Called from `projects.didSet` and once after load, so
    /// every add/remove/restore keeps the map in step without per-site bookkeeping.
    func syncRuntimes() {
        let live = Set(projects.flatMap(\.sessions).map(\.id))
        for id in live where runtimes[id] == nil { runtimes[id] = SessionRuntime() }
        for id in runtimes.keys where !live.contains(id) { runtimes.removeValue(forKey: id) }
    }

    /// Sets a session's status, no-op-guarded so a redundant same-value write (the hook
    /// path re-asserts `.working` on every tool event) neither re-renders the row nor
    /// pings the tray. Returns whether it actually changed, for callers that gate
    /// follow-on work on a real transition.
    @discardableResult
    func setStatus(_ status: SessionStatus, for id: Session.ID) -> Bool {
        let runtime = runtime(for: id)
        guard runtime.status != status else { return false }
        let previous = runtime.status
        runtime.status = status
        // Stall detection (§4.7) keys off continuous time spent `.working`, so the
        // window opens on the genuine transition in — this method is the single
        // status choke point — and closes on the way out: a session that stopped
        // working can no longer be stalled.
        if status == .working {
            beginStallWatch(for: id)
        } else if previous == .working {
            stallProbes[id] = nil
        }
        // The tray and window title present status, so a real change pings them.
        sessionRuntimeDidChange.send()
        // Push the genuine transition to any `termio sessions watch` clients scoped
        // to this session's project. The hub does the socket writes off the main
        // thread, so a watcher never slows the agent tick that produced the event.
        if let session = session(id), let project = project(for: id) {
            var event = SessionWatchEvent(
                projectID: project.id,
                handle: sessionHandle(for: session),
                status: Self.statusToken(status),
                title: displayTitle(for: session),
                cwd: runtimes[id]?.workingDirectory ?? "")
            // A `needs-you` event carries the on-screen question, a `done` event the
            // transcript cursor — what a supervisor needs to act on the transition
            // without a second round-trip (design doc §4.3).
            attachActionablePayload(to: &event, for: id)
            SessionWatchHub.shared.broadcast(event)
        }
        // A session *entering* `.working` is the "this project is active" signal that
        // floats its project up the Recent-Activity sort. Bumping here, on the genuine
        // transition, means one write per turn instead of one per hook/screen tick — the
        // callers no longer poke activity themselves (they used to fire it every tick).
        if status == .working, let pid = project(for: id)?.id { noteProjectActivity(pid) }
        return true
    }

    /// Sets the running tool for a session (`nil` clears it), guarded like `setStatus`.
    /// No runtime ping: the tool shows only in the sidebar row's own tooltip, which
    /// tracks its session's runtime directly — no AppKit observer reads it.
    func setCurrentTool(_ tool: String?, for id: Session.ID) {
        let runtime = runtime(for: id)
        guard runtime.currentTool != tool else { return }
        runtime.currentTool = tool
    }

    /// Sets a session's live `OSC 0/2` title (`nil` clears it), guarded like `setStatus`.
    /// Pings: the title feeds the tray roster label and the selected row, so a change
    /// must reach the AppKit tray.
    func setLiveTitle(_ title: String?, for id: Session.ID) {
        let runtime = runtime(for: id)
        guard runtime.liveTitle != title else { return }
        runtime.liveTitle = title
        sessionRuntimeDidChange.send()
    }

    /// Sets a session's live working directory (shell `OSC 7`), guarded like `setStatus`.
    /// No runtime ping: the cwd shows only in SwiftUI (the loose-terminal row label and
    /// the cwd-following inspector), which track the runtime directly.
    func setWorkingDirectory(_ path: String?, for id: Session.ID) {
        let runtime = runtime(for: id)
        guard runtime.workingDirectory != path else { return }
        runtime.workingDirectory = path
    }

    /// Window within which repeated activity pokes for the same project coalesce into a
    /// single `liveActivity` write. A working agent re-pokes its project several times a
    /// second (every hook tool event, every screen tick); each poke used to write a
    /// fresh `Date`, and because `liveActivity` is `@Published` that re-sorted and
    /// rebuilt the entire sidebar at agent-tick frequency — a second churn source
    /// alongside the status dictionaries. The "Recent Activity" order only needs coarse
    /// freshness, so collapsing pokes to one write every few seconds ends the churn
    /// while still floating a newly-active project up promptly.
    private let activityCoalesceWindow: TimeInterval = 4

    /// Floats a project up the "Recent Activity" sort (see `orderedProjects`).
    ///
    /// Background agent activity is coalesced — a project bumped within
    /// `activityCoalesceWindow` is left alone, so a working agent that flaps
    /// working→idle→working doesn't re-sort the sidebar every tick. Deliberate user
    /// actions (focusing a session, attaching from the phone) pass `force: true` to
    /// bypass the window: selecting a session must float it *now*, even if a background
    /// tick bumped the same project a moment ago — otherwise a just-selected project can
    /// sit below a more-recently-active one, contradicting "float the moment you focus it".
    func noteProjectActivity(_ pid: Project.ID, force: Bool = false) {
        let now = Date()
        if !force, let last = liveActivity[pid],
           now.timeIntervalSince(last) < activityCoalesceWindow { return }
        liveActivity[pid] = now
    }

    /// User preferences (appearance, agent commands, worktree behaviour). Held so
    /// surfaces can be configured on creation and re-styled live when settings
    /// change; also handed to the settings UI and sidebar.
    let settings: AppSettings

    /// Live current-branch per folder (project checkouts and session worktrees). The
    /// sidebar's worktree nodes and the terminal title bar read their branch label
    /// from here, so a `git checkout` inside a session updates the UI on its own.
    let branchModel = BranchModel()

    var surfaces: [Session.ID: TerminalViewState] = [:]
    var monitors: [Session.ID: [AnyCancellable]] = [:]
    /// The termio-owned PTY behind each host-managed session — the byte stream
    /// the surface renders and the companion server taps for a phone.
    var ptyProcesses: [Session.ID: PTYProcess] = [:]

    /// App-quit teardown: without this, session children outlive the app — the
    /// closing PTY's SIGHUP is swallowed by agent TUIs, and they pile up as
    /// launchd orphans across restarts. Graceful signals first, a short
    /// synchronous grace so plain shells exit cleanly, then SIGKILL whatever
    /// remains — the quit path can't rely on `terminate()`'s dispatched
    /// escalation timer, because the process dies before it fires.
    func terminateAllSessions() {
        let ptys = Array(ptyProcesses.values)
        guard !ptys.isEmpty else { return }
        for pty in ptys { pty.terminate() }
        usleep(300_000)
        for pty in ptys { pty.forceKillIfAlive() }
    }

    /// The most recent host-owned terminal grid, persisted across launches. A
    /// PTY is created *before* its surface lays out, so without a good initial
    /// size the shell prints its first prompt at a placeholder 80×24 and the
    /// window's real width then reflows it — and zsh's `PROMPT_SP` filler line
    /// mangles under that reflow (a stray `%` with the prompt shoved to the
    /// right edge). Seeding new PTYs with the last real grid makes the first
    /// resize a no-op in the common case (the window is the size it was last
    /// run), so the first prompt is drawn at the right width and never reflows.
    private static let hostGridColumnsKey = "termio.lastHostGridColumns"
    private static let hostGridRowsKey = "termio.lastHostGridRows"
    private(set) var lastHostGridColumns: Int
    private(set) var lastHostGridRows: Int
    private var settingsObserver: AnyCancellable?
    private var branchObserver: AnyCancellable?
    private var linkObserver: AnyCancellable?
    private var appActiveObserver: AnyCancellable?
    /// Debounces the worktree re-scan so a burst of git-dir events (a rebase, a fetch)
    /// coalesces into one `git worktree list`.
    private var worktreeReconcileWork: DispatchWorkItem?
    /// The folders whose git state changed since the last reconcile pass, plus whether
    /// a full pass (app activation) was requested meanwhile. One `.git` change used to
    /// re-scan *every* folder project — N git spawns for one repo's event; scoping the
    /// pass to the projects that own the changed folder removes that amplification.
    private var pendingReconcileFolders: Set<String> = []
    private var reconcileAllPending = false
    private var linkClickMonitor: Any?
    private let stateFile = StateFile()
    /// Coalesces the ratio-drag flood of `splitGroups` writes into one save.
    private var persistDebounce: DispatchWorkItem?

    /// The socket Claude Code's hooks report into. Runs for the app's lifetime; the
    /// `~/.claude/settings.json` side is what the setting toggles on and off.
    var hookListener: HookListener?
    /// The hooks-enabled value last written to disk, so a settings change only
    /// rewrites the hooks file when this specific setting flips — not on every
    /// unrelated appearance change that also fires `objectWillChange`.
    var installedHooksEnabled: Bool?

    /// The control socket the `termio sessions` CLI drives sibling sessions through.
    /// Runs for the app's lifetime (harmless when the feature is off — the handler
    /// refuses with "disabled"); only the awareness note installed into the agent
    /// instruction files is toggled, mirroring how `hookListener` works.
    var sessionControl: SessionControlListener?
    var installedSessionControlEnabled: Bool?

    /// The agent's own conversation log per session, learned from the hook stream
    /// (Claude Code's `transcript_path`). This is the address `sessions send` hands
    /// back so a caller can read the raw Q&A — and the response — from the agent's
    /// structured log instead of scraping the terminal.
    @Published var transcriptPaths: [Session.ID: String] = [:]

    /// When each session's agent process was spawned in *this* app run — unlike the
    /// persisted `Session.launchedAt` (stamped once, at the session's first launch
    /// ever), this bounds turn-boundary re-discovery to store records the current
    /// process could actually have created (see `rediscoverConversation`).
    var processSpawnedAt: [Session.ID: Date] = [:]

    /// When each currently-working session last reported activity, used to recover
    /// a session whose turn ended without a `done` hook (see `sweepStaleWorking`).
    /// Refreshed both by working hooks and by a *changed* rendered screen
    /// (`noteOutputActivity`).
    var lastWorkingAt: [Session.ID: Date] = [:]
    /// Loop-level stall-detection state per continuously-working session (design
    /// doc §4.7): when it entered `.working`, the current no-progress window, the
    /// output-rate ticks, and the repo/transcript baseline the sweep compares
    /// against. Created on the transition into `.working`, dropped on the way out
    /// (both in `setStatus`); probed by `sweepStalledSessions` in
    /// `TermioStore+AgentStatus`.
    var stallProbes: [Session.ID: StallProbe] = [:]
    /// The last activity a screen-scrape-configured agent's viewport was classified
    /// into (see `AgentStatusRules` / `applyScreenDetectedActivity`), so status is only
    /// re-driven on a transition — not re-emitted every tick the screen sits idle.
    var lastScreenActivity: [Session.ID: AgentStatusRules.Activity] = [:]
    /// The last activity an agent's live OSC title was classified into (see
    /// `applyTitleActivity`), so title-driven status also moves only on
    /// transitions — a spinner frame change re-classifies as the same `working`
    /// and is dropped here.
    var lastTitleActivity: [Session.ID: AgentStatusRules.Activity] = [:]
    var staleWorkingSweep: Timer?
    /// How long a `.working` session may go with *no screen change and no working
    /// hook* before the sweep flips it back to idle. A working agent's TUI repaints
    /// changing content sub-second (`noteOutputActivity` keeps refreshing the
    /// timestamp while the viewport keeps changing), so this only elapses once the
    /// screen has genuinely gone static — recovering the many turns that end
    /// without a `Stop` hook (a cancelled `/resume` or `/compact`, an esc-interrupt,
    /// or a hook that never correlated) instead of spinning forever.
    let staleWorkingTimeout: TimeInterval = 12

    /// When a session's hooks last applied any state, so the screen-driven
    /// promotion in `noteOutputActivity` can defer to live hooks: a session whose
    /// hooks just spoke doesn't need the screen to guess for them.
    var lastHookReportAt: [Session.ID: Date] = [:]
    /// When the user last typed (or scrolled) into a session's terminal. Keystroke
    /// echo repaints the screen exactly like streaming output does, so promotion
    /// stays quiet for a beat after any input.
    var lastUserInputAt: [Session.ID: Date] = [:]
    /// Consecutive changed-screen ticks observed for a non-working session — the
    /// debounce counter behind promotion (see `noteOutputActivity`).
    var promotionStreak: [Session.ID: Int] = [:]
    /// Hooks are trusted for this long after their last report before the screen
    /// may promote a session to working on its own. Just above
    /// `staleWorkingTimeout`, so a live turn the sweep mistakenly cleared becomes
    /// recoverable the moment it repaints, while the repaint burst right after a
    /// `Stop` hook (the final answer rendering) can never re-light the spinner.
    let hookQuietWindow: TimeInterval = 15
    /// How long after user input the screen must settle before promotion; typing a
    /// long prompt repaints the input box every keystroke.
    let userInputQuietWindow: TimeInterval = 3
    /// No promotion this soon after launch: an agent's banner and first prompt
    /// paint across several ticks while it is simply starting up.
    let launchGraceWindow: TimeInterval = 10
    /// PTY bytes per throttle tick that read as genuine streaming for the
    /// *sustain* path in `noteOutputActivity` — enough to keep a working session
    /// alive while the user has scrolled its viewport away from the live tail
    /// (a frozen viewport stops the screen-change signal), yet above the trickle
    /// an idle prompt emits (a cursor-park sequence, a redraw) so a finished turn
    /// still goes static and gets swept.
    let streamingByteFloor = 512

    /// Records the host surface's live grid so the next session's PTY is spawned
    /// at a size that matches the window, avoiding the first-prompt reflow. Only
    /// meaningful sizes are kept, and only when they change, so this is cheap to
    /// call from every resize.
    func rememberHostGrid(columns: Int, rows: Int) {
        guard columns > 0, rows > 0,
              columns != lastHostGridColumns || rows != lastHostGridRows else { return }
        lastHostGridColumns = columns
        lastHostGridRows = rows
        UserDefaults.standard.set(columns, forKey: Self.hostGridColumnsKey)
        UserDefaults.standard.set(rows, forKey: Self.hostGridRowsKey)
    }

    init(projects: [Project], settings: AppSettings) {
        self.settings = settings
        self.projects = projects
        self.selectedSessionID = projects.first?.sessions.first?.id
        let storedColumns = UserDefaults.standard.integer(forKey: Self.hostGridColumnsKey)
        let storedRows = UserDefaults.standard.integer(forKey: Self.hostGridRowsKey)
        self.lastHostGridColumns = storedColumns > 0 ? storedColumns : 80
        self.lastHostGridRows = storedRows > 0 ? storedRows : 24
        // The initial `projects` assignment above runs before `didSet` is armed, so
        // seed the runtime map for the restored tree explicitly (later add/remove goes
        // through `projects.didSet`).
        syncRuntimes()

        // Re-style already-open terminals whenever appearance settings change.
        // `objectWillChange` fires *before* the new value lands, so we hop to the
        // next main-loop tick to read the updated values (same deferral the
        // menu-bar controller uses).
        settingsObserver = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyAppearanceToOpenSurfaces()
                self?.syncHooksInstallationIfNeeded()
                self?.syncSessionControlInstallationIfNeeded()
            }

        // A branch label changing is not a change to the persisted tree, so the
        // BranchModel owns its own published state; forward its updates into ours so
        // views observing the store (sidebar, terminal title bar) re-render.
        branchObserver = branchModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }

        // Cmd-clicking a link in any terminal surface republishes here (see `TerminalLinkOpening`):
        // route local files into the read-only preview overlay and hand web links to the system.
        linkObserver = NotificationCenter.default.publisher(for: .termioTerminalOpenURL)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self,
                      let url = note.userInfo?[TerminalLinkKey.url] as? String else { return }
                let cwd = (note.object as? TerminalViewState)?.workingDirectory
                self.openTerminalLink(url, surfaceWorkingDirectory: cwd)
            }

        // Open the hovered hyperlink on cmd-click ourselves. ghostty's own `open_url` doesn't reach
        // us in practice — a mouse-capturing TUI (Claude Code) never lets ghostty handle the click,
        // and even a plain shell's click is consumed here first — but the hover delegate always
        // reports the URL under the mouse (`TerminalLinkState.hoveredURL`), so a cmd+left-click opens
        // that link in *both* shells and agent TUIs. Returning nil consumes the event so the click
        // isn't also delivered to the terminal/app underneath.
        linkClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  let url = TerminalLinkState.hoveredURL else { return event }
            self.openTerminalLink(url, surfaceWorkingDirectory: nil)
            return nil
        }
        syncWatchedFolders()

        // Keep the worktree list honest against git, so worktrees made on the CLI show up
        // and ones removed drop out. Re-scan the affected project when a watched folder's
        // git *state* changes (covers a `git worktree add` run inside termio), and
        // everything when the app regains focus (covers one run in another terminal
        // while termio was in the background). See `reconcileWorktrees`.
        branchModel.onGitStateChange = { [weak self] folder in
            self?.scheduleWorktreeReconcile(for: folder)
        }
        appActiveObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleWorktreeReconcile() }
        reconcileWorktrees()

        startHookMonitoring()
        startSessionControl()
    }

    /// The live branch label for a folder (a project checkout or a session
    /// worktree), or `nil` when it is not a git repo — in which case the UI hides
    /// the branch chip rather than showing an empty token.
    func branch(forFolder folder: String) -> String? {
        branchModel.branch(for: folder)
    }

    func isDetachedHead(forFolder folder: String) -> Bool {
        branchModel.isDetached(folder)
    }

    /// Tells the BranchModel which folders to keep a live branch for: every project's
    /// own directory, every stored worktree (including empty ones), and legacy
    /// session-only worktree paths. Called once at init and after tree changes.
    private func syncWatchedFolders() {
        var folders = Set<String>()
        for project in projects {
            folders.insert(project.path)
            for worktree in project.worktrees { folders.insert(worktree.path) }
            for session in project.sessions {
                if let worktree = session.worktreePath { folders.insert(worktree) }
            }
        }
        branchModel.setWatched(folders)
    }

    /// Coalesces a burst of git-state events into a single re-scan a beat later,
    /// remembering *which* folders moved so the pass stays scoped. No folder means
    /// "everything" (app activation).
    private func scheduleWorktreeReconcile(for folder: String? = nil) {
        if let folder {
            pendingReconcileFolders.insert(folder)
        } else {
            reconcileAllPending = true
        }
        worktreeReconcileWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let folders = self.reconcileAllPending ? nil : self.pendingReconcileFolders
            self.reconcileAllPending = false
            self.pendingReconcileFolders = []
            self.reconcileWorktrees(limitedTo: folders)
        }
        worktreeReconcileWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Reconciles folder projects' `worktrees` with what git actually reports:
    /// worktrees created outside termio (`git worktree add` on the CLI) get added, ones
    /// removed on the CLI drop out, and termio's own keep their id/metadata. Git is the
    /// source of truth — the sidebar mirrors the repo rather than a private list.
    /// `limitedTo` scopes the pass to the projects owning those folders (a project
    /// path or one of its worktree paths); `nil` re-scans every folder project.
    func reconcileWorktrees(limitedTo folders: Set<String>? = nil) {
        for project in projects where project.kind == .folder {
            if let folders, !projectOwns(project, anyOf: folders) { continue }
            let id = project.id
            let path = project.path
            Task { [weak self] in
                // `nil` means git errored (not a repo, transient) → leave the list untouched.
                guard let discovered = await WorktreeService.linkedWorktrees(in: path) else { return }
                await MainActor.run { self?.applyDiscoveredWorktrees(discovered, to: id) }
            }
        }
    }

    /// Whether any of `folders` (standardized paths from the branch watcher) is this
    /// project's checkout or one of its worktrees — i.e. whether a git change there
    /// can alter this project's worktree list.
    private func projectOwns(_ project: Project, anyOf folders: Set<String>) -> Bool {
        if folders.contains(Self.standardizedPath(project.path)) { return true }
        for worktree in project.worktrees
        where folders.contains(Self.standardizedPath(worktree.path)) { return true }
        for session in project.sessions {
            if let path = session.worktreePath,
               folders.contains(Self.standardizedPath(path)) { return true }
        }
        return false
    }

    /// Merges git's linked-worktree paths into one project's `worktrees`, in git's order.
    /// A path git no longer reports is pruned — unless a live session still points at it,
    /// so an in-use worktree never vanishes from under its sessions. Only writes back when
    /// something actually changed, so a stable repo doesn't churn the persisted tree.
    private func applyDiscoveredWorktrees(_ discovered: [String], to projectID: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let discoveredSet = Set(discovered)
        let existing = projects[index].worktrees
        let byPath = Dictionary(existing.map { (Self.standardizedPath($0.path), $0) },
                                uniquingKeysWith: { first, _ in first })
        let sessionAnchored = Set(projects[index].sessions.compactMap { $0.worktreePath }
            .map(Self.standardizedPath))

        // Discovered worktrees first (reusing existing entries to preserve id/createdAt)…
        var rebuilt = discovered.map { byPath[$0] ?? Worktree(path: $0) }
        // …then any git-absent entry that still has a session, so it isn't yanked away.
        for worktree in existing {
            let std = Self.standardizedPath(worktree.path)
            if !discoveredSet.contains(std), sessionAnchored.contains(std) { rebuilt.append(worktree) }
        }

        if projects[index].worktrees != rebuilt { projects[index].worktrees = rebuilt }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Builds a store from the persisted session tree, falling back to the seed
    /// projects on first launch (or if the saved state is missing/unreadable).
    /// Live terminal surfaces are not persisted — each session's shell restarts
    /// fresh in its project directory the first time it is opened again.
    static func restored(settings: AppSettings) -> TermioStore {
        guard let snapshot = StateFile().load(), !snapshot.projects.isEmpty else {
            return TermioStore(projects: Project.firstRunProjects(), settings: settings)
        }

        let store = TermioStore(
            projects: migratingScratchProject(migratingHomeProject(normalizingAgentTitles(snapshot.projects))),
            settings: settings
        )
        if let id = snapshot.selectedSessionID, store.session(id) != nil {
            store.selectedSessionID = id
        }
        // Restore the split groups, keeping only those whose panes all still
        // resolve to live sessions (a stale group is dropped whole rather than
        // patched — the user just re-splits). State files from before groups
        // existed persisted a single `splitRoot` layout; it migrates as one group.
        let savedGroups = snapshot.splitGroups ?? snapshot.splitRoot.map { [$0] } ?? []
        store.splitGroups = savedGroups.filter { group in
            group.leafIDs.count >= 2 && group.leafIDs.allSatisfy { store.session($0) != nil }
        }
        return store
    }

    /// Earlier builds saved agent sessions with a lowercased label (`claude code`)
    /// and plain terminals as `session N`. We now keep the agent's real name
    /// (`Claude Code`, `Terminal N`), so upgrade any session whose title is still
    /// one of those old auto-generated forms. A title the user changed to anything
    /// else is left untouched.
    private static func normalizingAgentTitles(_ projects: [Project]) -> [Project] {
        projects.map { project in
            var project = project
            project.sessions = project.sessions.map { session in
                var session = session
                if session.agent == .terminal {
                    let suffix = session.title.dropFirst("session ".count)
                    if session.title.hasPrefix("session "), !suffix.isEmpty,
                       suffix.allSatisfy(\.isNumber) {
                        session.title = "Terminal \(suffix)"
                    }
                } else if session.title == session.agent.displayName.lowercased() {
                    session.title = session.agent.displayName
                }
                return session
            }
            return project
        }
    }

    /// State files from before the loose-terminals entity existed (see
    /// docs/design/loose-terminal-entity.md) modeled scratch terminals as a plain
    /// project rooted at `$HOME`. Re-tag that container as `.terminals` (with the
    /// fixed section name) so it renders as the Terminals section rather than a
    /// fake home project. Idempotent — an already-tagged container passes through
    /// unchanged. The pre-entity seed also called its one shell "shell", which
    /// isn't an auto `Terminal N` name and would block the cwd-basename label, so
    /// it is re-numbered here.
    private static func migratingHomeProject(_ projects: [Project]) -> [Project] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return projects.map { project in
            var project = project
            guard project.kind == .terminals
                || (project.path as NSString).standardizingPath == home else { return project }
            project.kind = .terminals
            project.name = "Terminals"
            project.sessions = project.sessions.enumerated().map { index, session in
                var session = session
                if session.title == "shell" { session.title = "Terminal \(index + 1)" }
                return session
            }
            return project
        }
    }

    /// State files from before the Chats funnel existed modeled scratch **agent**
    /// sessions as a plain `.folder` project named "default" at `~/.termio/default`.
    /// Re-tag that container as `.chats` (the fixed section name and the new
    /// `~/.termio/chats` root) so it renders as the Chats section rather than a fake
    /// "default" project folder. Matched by its old scratch path; idempotent — an
    /// already-tagged `.chats` container, and any real project, pass through unchanged.
    /// Sessions restart fresh on relaunch anyway, so repointing the spawn path is free.
    private static func migratingScratchProject(_ projects: [Project]) -> [Project] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let oldPath = home.appendingPathComponent(".termio/default").standardizedFileURL.path
        let newPath = home.appendingPathComponent(".termio/chats").standardizedFileURL.path
        return projects.map { project in
            guard project.kind == .folder,
                  (project.path as NSString).standardizingPath == oldPath else { return project }
            var project = project
            project.kind = .chats
            project.name = "Chats"
            project.path = newPath
            return project
        }
    }

    private func persist() {
        stateFile.save(.init(
            projects: projects,
            selectedSessionID: selectedSessionID,
            splitGroups: splitGroups
        ))
    }

    func status(for sessionID: Session.ID) -> SessionStatus {
        runtimes[sessionID]?.status ?? .idle
    }

    /// The live working directory a session last reported (shell `OSC 7`), or `nil`.
    /// A thin accessor over the runtime so the inspector / file browser read the same
    /// place the sidebar label does, without touching the storage directly.
    func workingDirectory(for sessionID: Session.ID) -> String? {
        runtimes[sessionID]?.workingDirectory
    }

    /// Acknowledge a resting "your turn" cue: a finished (`.done`) or blocked
    /// (`.needsAttention`) session the user has now engaged with drops back to
    /// `.idle`, clearing its sidebar/tray dot. A mid-turn `.working` is left
    /// alone — its spinner isn't a cue to dismiss. Idempotent, and unlike the
    /// `selectedSessionID` didSet it doesn't require the selection to *change*, so
    /// re-clicking the session you're already on still clears the dot.
    func markSeen(_ id: Session.ID) {
        let current = status(for: id)
        if current == .done || current == .needsAttention {
            setStatus(.idle, for: id)
        }
    }

    /// The agent a session *presents* as. Since identity became persistent this is
    /// simply the declared agent: a hand-started `claude` *reclassifies* its shell
    /// session outright (see `noteForegroundAgent`), and an agent that quits back
    /// to the shell demotes it — the session is always exactly what its pane runs.
    /// Kept as the shared read point so call sites don't couple to that invariant.
    func effectiveAgent(for session: Session) -> AgentDefinition {
        session.agent
    }

    /// The label to show for a session. Centralized so the sidebar and the
    /// menu-bar tray always agree on what a session is called.
    ///
    /// Agent sessions adopt the running program's live terminal title (`OSC 0/2`)
    /// once it reports something meaningful — that is how a `Claude Code` row
    /// becomes `Explore e2b.dev infra`, keeping two sessions of the same agent
    /// distinguishable. A name the user set themselves (one that differs from the
    /// agent's default display name) wins over the live title.
    ///
    /// Plain terminals never adopt a live title (their shell would just report
    /// `user@host`/cwd noise); instead the auto-named ones (`Terminal N`) all show
    /// a bare `Terminal` label. The stored title is left untouched (it seeds the
    /// worktree branch slug, which must stay stable and unique); only the displayed
    /// value is derived here.
    func displayTitle(for session: Session) -> String {
        if session.agent != .terminal {
            if session.title != session.agent.displayName {
                return session.title
            }
            return runtimes[session.id]?.liveTitle ?? session.liveTitle ?? session.title
        }
        guard Self.isAutoTerminalName(session.title) else {
            return session.title
        }
        // A loose terminal is labeled by its live cwd's basename (`~` at home):
        // the session owns its path, so `cd ~/code/foo` renames the row to `foo`
        // (see docs/design/loose-terminal-entity.md). Falls back to the cwd
        // persisted from the last run, then to a bare `Terminal` before the
        // shell's first OSC 7 report. Project terminals keep the plain label —
        // their place is the project, not wherever they've wandered.
        if project(for: session.id)?.kind == .terminals,
           let cwd = runtimes[session.id]?.workingDirectory ?? session.lastWorkingDirectory {
            return Self.terminalLabel(forPath: cwd)
        }
        return "Terminal"
    }

    /// A loose terminal's display label for a working directory: `~` at the home
    /// directory, otherwise the folder's basename.
    private static func terminalLabel(forPath path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return "~"
        }
        let name = (standardized as NSString).lastPathComponent
        return name.isEmpty ? standardized : name
    }

    /// Whether `title` is an auto-generated `Terminal N` label (as opposed to a
    /// name the user chose), which is what makes it eligible for live re-indexing.
    static func isAutoTerminalName(_ title: String) -> Bool {
        let suffix = title.dropFirst("Terminal ".count)
        return title.hasPrefix("Terminal ") && !suffix.isEmpty
            && suffix.allSatisfy(\.isNumber)
    }

    /// The single state the menu-bar pulse renders: any session waiting on the
    /// user wins, then any working session, then any just-finished one, else calm.
    var aggregateStatus: SessionStatus {
        let all = projects.flatMap(\.sessions).map { status(for: $0.id) }
        if all.contains(.needsAttention) { return .needsAttention }
        if all.contains(.working) { return .working }
        if all.contains(.done) { return .done }
        return .idle
    }

    func session(_ id: Session.ID) -> Session? {
        for project in projects {
            if let session = project.sessions.first(where: { $0.id == id }) {
                return session
            }
        }
        return nil
    }

    func project(for sessionID: Session.ID) -> Project? {
        projects.first { $0.sessions.contains { $0.id == sessionID } }
    }

    /// Opens a file in the editor overlay in its normal **editable** mode — the inspector's own
    /// file-tree click path. Pairs with `openTerminalLink`, which opens read-only; routing through
    /// these two methods (rather than assigning `openFileURL` directly) keeps the read-only flag and
    /// the URL in step.
    func openFileInEditor(_ url: URL, at line: Int? = nil) {
        openFileReadOnly = false
        openFileLine = line
        openFileURL = url
    }

    /// Routes a link the user cmd-clicked in a terminal surface. A local file (a `file://` URL, or a
    /// bare path resolved against the surface's working directory) covers the terminal with a
    /// **read-only** preview — the source, not an editable buffer, so a stray click can't change it.
    /// A web/mail link is handed to the system's default handler instead. Anything that resolves to
    /// neither (a dead path, a directory, an unknown scheme) is ignored.
    func openTerminalLink(_ raw: String, surfaceWorkingDirectory: String?) {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }

        if let url = URL(string: link), let scheme = url.scheme?.lowercased() {
            if url.isFileURL {
                presentFilePreview(url)
            } else if ["http", "https", "mailto", "ftp", "ftps"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        // No scheme: treat as a filesystem path, absolute or relative to where the surface is `cd`'d.
        let base = surfaceWorkingDirectory ?? selectedSessionWorkspace
        let url: URL = (link as NSString).isAbsolutePath || base == nil
            ? URL(fileURLWithPath: link)
            : URL(fileURLWithPath: link, relativeTo: URL(fileURLWithPath: base!, isDirectory: true))
        presentFilePreview(url.standardizedFileURL)
    }

    /// Covers the terminal with a read-only preview of `url`, but only if it points at an existing
    /// regular file — a missing path or a directory is silently dropped rather than opening an empty
    /// overlay.
    private func presentFilePreview(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        openFileReadOnly = true
        openFileURL = url
    }

    /// The working directory of the selected session (its worktree, else the project root), used as
    /// the fall-back base for resolving a relative path when the surface hasn't reported an OSC 7 cwd.
    private var selectedSessionWorkspace: String? {
        guard let id = selectedSessionID, let session = session(id), let project = project(for: id)
        else { return nil }
        return session.worktreePath ?? project.path
    }
}
