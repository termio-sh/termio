import AppKit
import Combine
import Foundation
import GhosttyTerminal
import TermioShared

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
            // First, before anything else reads the tree: `syncRuntimes` below and
            // every observer this change wakes resolve sessions through the index,
            // and a slot still describing the pre-mutation array is a wrong answer
            // — the callers remove and insert at it — not merely a stale one.
            rebuildSessionSlots()
            persist()
            syncWatchedFolders()
            syncRuntimes()
        }
    }

    /// The scopes the sidebar shows, and the loose sessions each one owns. There
    /// is always at least one; a user who never makes a second never sees the
    /// switcher.
    @Published var workspaces: [Workspace] {
        didSet {
            rebuildSessionSlots()
            persist()
            syncRuntimes()
        }
    }

    /// Where every session sits, so `locate(_:)` costs a dictionary read. Rebuilt
    /// as the first act of both `didSet`s above and once in `init` (which assigns
    /// the arrays before the observers are armed) — those three sites are the only
    /// places the tree can change, so nothing else has to keep it honest.
    private(set) var sessionSlots = SessionSlotIndex()

    private func rebuildSessionSlots() {
        sessionSlots = SessionSlotIndex(workspaces: workspaces, projects: projects)
    }

    /// Counts arrivals in a workspace, so the work a switch defers can tell
    /// whether it is still wanted. A user stepping through scopes passes through
    /// ones they never stop on; only the last arrival settles (see
    /// `finishArriving`).
    var workspaceArrival: UInt64 = 0

    /// Which workspace the sidebar is showing. Live state, like the selection —
    /// `AppSettings` keeps a copy only so the next launch starts where this one
    /// ended. Written through `switchToWorkspace(_:)`, which moves the selection
    /// with it.
    @Published var currentWorkspaceID: Workspace.ID
    @Published var selectedSessionID: Session.ID? {
        // Selecting a session means the user is now looking at it, so any pending
        // "needs attention" (or unseen "done") is, by definition, answered.
        didSet {
            guard oldValue != selectedSessionID else { return }
            // Half of what a workspace switch costs is here: the switch moves the
            // selection, and everything below rides on that.
            let span = Trace.workspace.begin("selection change")
            defer { Trace.workspace.end(span) }
            // Save the inspector layout of the session we're leaving and restore the one
            // we're arriving at, so each terminal tab keeps its own right-side context
            // (issue #160). This replaces the blanket overlay-clear that used to live in
            // `TerminalPane` — and, because we no longer tear the maximize host down to
            // nothing on every switch, it also removes the fullscreen blank-screen race.
            // Suppressed during launch restore: `restored()` seeds every session's layout
            // and applies the selected one by hand, so capturing here would overwrite a
            // just-seeded layout with the still-default live inspector.
            if !isRestoringInspector {
                if let old = oldValue { inspectorStates[old] = captureInspectorState() }
                applyInspectorState(selectedSessionID.flatMap { inspectorStates[$0] } ?? InspectorState())
            }
            if let id = selectedSessionID {
                // Looking at a session is being in its workspace. A global verb —
                // a deep link, the palette, a notification, an SSH shell filed
                // under a machine's fallback — can put the selection anywhere, and
                // a window showing one scope while the terminal belongs to another
                // is the same confusion the device context exists to prevent.
                enterWorkspace(of: id)
                // Every selection is also the answer to "where was I in this
                // scope", so the workspace it belongs to remembers it (see
                // `workspaceSelections`). Filed under the session's *own*
                // workspace rather than the current one, so a deep link that
                // jumps scopes records the arrival where it landed.
                if let owner = workspace(for: id)?.id { workspaceSelections[owner] = id }
                // Looking at a session is being on its machine. Every path that
                // moves the selection — a deep link, the palette, a notification,
                // a split, a freshly opened remote terminal — lands here, so this
                // is the one place the context has to follow, and the window can
                // never name one device while showing another's terminal.
                enterDevice(of: id)
                // A mid-turn `.working` keeps its spinner; only the resting
                // "your turn" states are answered by looking.
                markSeen(id)
                // Switching to a session counts as activity for its project, so the
                // "Recent Activity" sort floats a project the moment you focus it —
                // forced past the coalesce window since it's a deliberate user action.
                if let pid = project(for: id)?.id { noteProjectActivity(pid, force: true) }
            }
            // Debounced, not inline: moving the selection is the most frequent
            // edit in the app — every row click, every ⌘⇧], every workspace
            // switch — and a synchronous encode-and-write of the whole tree on
            // each one is a hitch the user feels as the switch being slow. The
            // quit path flushes whatever is still pending.
            persistSoon()
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

    /// The in-flight pane drag (issue #183): written by `PaneDragRearrange`
    /// as the pointer moves, read by `TerminalPane` to draw the drop-zone
    /// highlight. Transient gesture state, never persisted.
    @Published var paneDrag: PaneDragState?

    /// The pane whose grab handle is revealed right now — the pointer is on its
    /// top edge. Also written by `PaneDragRearrange`; nil means no handle is
    /// showing.
    @Published var paneHandleHover: PaneHandleHover?

    /// A still of the pane picked up by the current drag, drawn scaled under the
    /// pointer. Nil when no drag is in flight, or when the surface could not be
    /// captured — the drag then simply has no preview.
    @Published var paneDragPreview: NSImage?

    /// Drives the visible surfaces while a pane drag is in flight (see
    /// `beginPaneDragRepaint`). Not published: nothing renders from it.
    var paneDragRepaintTimer: Timer?

    /// Activation *requests* for sessions that are neither selected nor in the
    /// visible group: a background spawn's fresh pane, a `send` target never
    /// shown. `TerminalPane` folds these into its own `activated` list — the
    /// actual mounted set — so the pane mounts invisibly at the size its layout
    /// gives it, which is what attaches the libghostty surface: the queued
    /// prompt can then be delivered without yanking the user's selection over
    /// to the new pane.
    /// Transient and not persisted — on relaunch the pane mounts the normal way.
    @Published private(set) var backgroundActivationIDs: [Session.ID] = []

    /// Requests an invisible mount for `id` (see `backgroundActivationIDs`).
    func activateInBackground(_ id: Session.ID) {
        guard !backgroundActivationIDs.contains(id) else { return }
        backgroundActivationIDs.append(id)
    }

    /// The session currently being dragged out of the sidebar, recorded when the row
    /// drag begins so a hovered row can ask `canReorder` whether it's a legal drop
    /// target (same project + worktree bucket) and light its background only then.
    ///
    /// `@Published` because the terminal area draws from it too: the pane you are
    /// carrying is washed for the length of the drag, which is the only thing that
    /// distinguishes "this pane is the session in your hand" from a drop that
    /// silently did nothing.
    @Published var draggingSessionID: Session.ID?

    /// Where a sidebar row dragged over the terminal area would land: the pane
    /// under the pointer and the half it would take. Written by the panes' drop
    /// delegate, drawn by `TerminalPane` — the sidebar-drag twin of `paneDrag`,
    /// and `@Published` for the same reason: the highlight is on screen, so it
    /// has to redraw as the pointer crosses zones.
    @Published var sessionDropTarget: SessionDropTarget?

    /// What a release over a sidebar row would do: land in the gap above or below
    /// it, or group the dragged session with it. Held here rather than in each
    /// row's `@State` so one writer owns it — a per-row flag can only be cleared by
    /// the row that set it, and a drag that ends without SwiftUI calling that row
    /// back leaves the cue on screen (see `PaneDragRearrange.clearStrandedDropCue`).
    @Published var sessionRowDrop: SessionRowDrop?

    /// A pending drop on a sidebar row: which row, and which gap it would land in —
    /// `nil` meaning the middle of the row, which groups the two sessions instead.
    struct SessionRowDrop: Equatable {
        var row: Session.ID
        var insert: RowInsertion?
    }

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
            if oldValue != openFileURL {
                filePresentationGeneration &+= 1
                if remotePreviewLease?.fileURL != openFileURL {
                    remotePreviewLease = nil
                    openFileDisplayName = nil
                }
                openFileDirty = false
            }
            // Whatever put a file on screen — or took one off it — settles the
            // question the placeholder was asking, and ends the download behind
            // it. The generation guard already stops a late reply from
            // presenting itself; this stops it from crossing the network at all.
            // Cancelling the task that is *doing* the presenting is harmless:
            // the download is over by then, and the cache was written first.
            if oldValue != openFileURL { cancelRemoteFileOpen() }
            if openFileURL != nil { openDiff = nil; openIssueDetail = nil; noteDetailOpened() }
            // Closing always returns to the editable default; a read-only open re-asserts the flag
            // immediately before setting the URL (see `openTerminalLink`). The jump line clears too,
            // so a later plain open of the same file doesn't scroll to a stale hit.
            else {
                openFileReadOnly = false
                openFileLine = nil
                openFileAllowsActiveWebContent = true
            }
            refreshDetailPresentation()
        }
    }

    /// The 1-based line the editor should reveal when it opens `openFileURL` — set by a
    /// content-search hit (see `FileSearchView`); `nil` for a plain open (top of file).
    @Published var openFileLine: Int?

    /// Where the open file lives when it lives on another machine: the staged
    /// copy on this Mac is what the editor reads and writes, and this is what a
    /// save needs to put those bytes back. `nil` for a file on this Mac, which
    /// is every case where the editor's own write *is* the save.
    ///
    /// Re-versioned after each successful save (`RemoteDocument.read(at:)`), so
    /// a second save claims the version the first one produced rather than the
    /// one the file was opened at.
    @Published var openFileRemote: RemoteDocument?

    /// Whether the open file should be shown read-only (no editing, no auto-save). Set when the file
    /// was opened by cmd-clicking a link in the terminal — a peek at the source, not an invitation to
    /// edit it by mistake. The inspector's own file opens stay editable (`openFileInEditor`).
    @Published var openFileReadOnly = false

    /// False for files staged from an SSH host. HTML/SVG must then open as
    /// read-only source rather than executing in the local web preview.
    @Published var openFileAllowsActiveWebContent = true

    /// The file on another machine that a click has asked for and whose bytes
    /// have not landed yet, or `nil` when nothing is on its way.
    ///
    /// A remote open is a round trip, and until this existed the click spent it
    /// showing whatever was already on screen: no chrome, no name, no sign the
    /// app had heard the click at all. The overlay now goes up on the click and
    /// the content fills in, which is what makes a device's tree feel like the
    /// local one — the wire is the same speed either way.
    @Published private(set) var openingRemoteFile: RemoteFileOpening? {
        didSet {
            if openingRemoteFile != nil { openDiff = nil; openIssueDetail = nil; noteDetailOpened() }
            refreshDetailPresentation()
        }
    }

    /// Whether the open file has edits the editor has not written yet, reported
    /// by `FileEditorView`. Read by the remote open path, which must never
    /// replace a buffer somebody is typing into (see `openRemoteFile`).
    @Published var openFileDirty = false

    /// The in-flight remote read. Held so the next open — or the close — ends it
    /// rather than leaving a download running for a file nobody will see.
    private var remoteOpenTask: Task<Void, Never>?

    /// A monotonically increasing guard for asynchronous remote downloads. Any
    /// local open/close/replacement invalidates a pending remote presentation.
    private(set) var filePresentationGeneration: UInt64 = 0

    /// Retaining the lease retains the staged file. Replacing or closing the
    /// overlay releases it and deletes only its private directory.
    private var remotePreviewLease: RemotePreviewLease?
    private(set) var openFileDisplayName: String?

    /// The changed file currently shown in the diff overlay, or `nil` when none is. The git
    /// counterpart of `openFileURL`: clicking a row in the Changes pane sets it, and the terminal
    /// pane covers itself with `GitDiffView` while it is non-nil. Opening a diff dismisses any open
    /// file editor.
    @Published var openDiff: GitDiffRequest? {
        didSet { if openDiff != nil { openFileURL = nil; noteDetailOpened() }; refreshDetailPresentation() }
    }

    /// The GitHub issue / pull request whose detail is shown, or `nil` when none is. The
    /// third inspector detail: clicking a row in the Issues pane sets it, and the inspector
    /// shows the conversation / PR files in place of its list (see `InspectorDetailHost`).
    /// Unlike the others it deliberately COEXISTS with `openDiff`: a PR's file diff stacks on
    /// top of the detail, so closing the diff returns to the PR rather than the list.
    @Published var openIssueDetail: IssueSummary? {
        didSet { if openIssueDetail != nil { openFileURL = nil; openDiff = nil; noteDetailOpened() }; refreshDetailPresentation() }
    }

    /// True while any inspector detail (file, diff, PR/issue) is open. A render
    /// predicate — "is there content to show" — read by the inspector, the terminal context
    /// menu and the pane drag, and by the app delegate to mount or tear down the full-window
    /// maximize host. It is deliberately *not* what reveals the inspector; see `detailDidOpen`.
    /// `private(set)` — only the detail setters above flip it, via `refreshDetailPresentation`.
    @Published private(set) var isDetailPresented = false

    /// Fires when a detail opens because the *user* opened one — a file or diff clicked in the
    /// inspector, a PR row, a cmd-clicked path in the terminal. The app delegate
    /// un-collapses the inspector on it, and nothing else does. Deliberately silent while a
    /// detail is merely re-stated (see `isRestatingDetail`): what the inspector shows is
    /// per-session, but whether the panel is open is global, so a session switch (or a launch
    /// restore) must never flip it back open (issue #272). An event rather than an edge
    /// detected on `isDetailPresented`, which cannot tell a user's open from a restore.
    let detailDidOpen = PassthroughSubject<Void, Never>()

    /// Raised by each detail setter when it is handed a detail to show, so *every* user open
    /// reveals a collapsed inspector — not just the first. Keying this off `isDetailPresented`
    /// going false → true would miss opening a second file (or a diff over a file) while the
    /// inspector is collapsed, which is precisely the state a collapse-with-a-detail-open
    /// leaves behind: the aggregate never dips, so the new detail would open unseen.
    private func noteDetailOpened() {
        guard !isRestatingDetail else { return }
        detailDidOpen.send()
    }

    /// Re-points the open working-tree diff at a freshened sibling list — the set ← / → walks
    /// and the header's "n of m" — without counting as a user open. The Changes pane calls this
    /// when its change list reloads under a diff that is already on screen; re-stating the same
    /// target must leave a collapsed inspector collapsed (issue #272).
    func refreshOpenDiffSiblings(_ siblings: [GitChange]) {
        guard var request = openDiff, request.commit == nil, request.siblings != siblings else { return }
        request.siblings = siblings
        isRestatingDetail = true
        defer { isRestatingDetail = false }
        openDiff = request
    }

    /// Whether the active inspector detail is blown up to fill the whole window. The inspector
    /// hosts the detail beside the terminal by default; the detail's maximize button flips this
    /// to cover everything (see the app delegate's full-window host), and it resets to `false`
    /// automatically whenever the last detail closes.
    @Published var inspectorMaximized = false {
        didSet {
            guard inspectorMaximized != oldValue else { return }
            inspectorMaximizedDidChange.send(inspectorMaximized)
        }
    }

    /// Fires once `inspectorMaximized` has actually landed, which `objectWillChange` cannot do.
    /// The two halves of the maximize handoff live in different frameworks — SwiftUI drops the
    /// docked detail, the app delegate mounts the full-window host — and a delegate driven off
    /// `objectWillChange` has to defer a runloop to read the settled value, by which time SwiftUI
    /// has already uncovered the inspector's file tree. Publishing from `didSet` lets the host go
    /// up in the same turn the flag flips, so the swap never shows what is underneath.
    let inspectorMaximizedDidChange = PassthroughSubject<Bool, Never>()

    /// Whether the list column is collapsed so the detail fills the whole inspector (terminal still
    /// visible), one step short of `inspectorMaximized`. Flipped by the detail chrome's list toggle;
    /// resets to `false` when the last detail closes, so the list is back for the next browse.
    @Published var inspectorListCollapsed = false

    /// Recomputes `isDetailPresented` from the three detail properties and drops the maximize
    /// state once nothing is left to show. Called from each detail setter's `didSet`.
    private func refreshDetailPresentation() {
        let presented = openFileURL != nil || openingRemoteFile != nil
            || openDiff != nil || openIssueDetail != nil
        if isDetailPresented != presented { isDetailPresented = presented }
        if !presented {
            if inspectorMaximized { inspectorMaximized = false }
            if inspectorListCollapsed { inspectorListCollapsed = false }
        }
        // Every detail change (and, via the tab's own clears, every tab switch) funnels
        // through here, so it's the one place to schedule the durable-layout save.
        persistInspectorSoon()
    }

    /// The Issues pane's models, cached by repo root, held here (beyond the inspector view
    /// that owns each) so an open PR/issue detail keeps its data — conversation, PR files,
    /// checkout — even when the inspector switches tab / collapses and `IssuesView` is torn
    /// down. `IssuesView` registers its model on appear; the detail overlay reads
    /// `issuesModel`, which resolves to the *selected session's* repo. That pairing is what
    /// makes per-session issue restore (issue #160) safe: returning to a session can never
    /// render its saved issue against another repo's model.
    @Published private(set) var issuesModels: [String: IssuesPanelModel] = [:]

    /// Fetched issue / PR list + detail, keyed by *remote* identity so it outlives the per-repo
    /// `IssuesPanelModel` instances above — the fix for the pane re-fetching (spinner) on every
    /// session switch. See `IssueCache`.
    let issueCache = IssueCache()

    /// Registers (or refreshes) the Issues model for its repo root, wiring it to the shared
    /// cache so a fresh model (a remount, or a different worktree of the same repo) reads the
    /// previously fetched list + detail instead of hitting GitHub again. Called by `IssuesView`.
    func registerIssuesModel(_ model: IssuesPanelModel) {
        model.attachCache(issueCache)
        // The list DATA survives a remount through the cache, but the query — the
        // Issues/Pull Requests kind, the filters — lives on the model instance. Hand it
        // to the successor, or every remount (session switch, tab switch) snaps the pane
        // back to the default Issues kind under whatever detail is open.
        if let outgoing = issuesModels[model.repoRoot], outgoing !== model {
            model.query = outgoing.query
            // And the last-opened item: its row keeps the selected grey after the
            // detail closes, a memory that must survive the same remounts.
            model.openItem = outgoing.openItem
        }
        issuesModels[model.repoRoot] = model
    }

    /// The Issues model for the currently selected session's repo, or `nil` when none has
    /// loaded yet — the detail overlay then falls back to the list rather than fetching an
    /// issue against the wrong repo. Keyed on the checkout's local root, the exact
    /// string `IssuesView` is created with (see `FileBrowserView`) — a checkout on
    /// another device has none, and so has no model, because the pane never runs.
    var issuesModel: IssuesPanelModel? {
        inspectorCheckout?.localRoot.flatMap { issuesModels[$0] }
    }

    /// The git pane's inner mode (Changes / History) per repo root — the same continuity
    /// the Issues pane's kind gets through its model registry: an inspector tab flip or
    /// session switch remounts `GitChangesView` with its `@State` mode back at Changes,
    /// so the pane resumes from here instead. In-memory only, like the registry.
    var gitPaneModes: [String: GitPaneMode] = [:]

    /// The base branch the git pane's History tab compares against, per repo *and branch*
    /// (`compareBaseKey`). Per branch, not per repo: the base is a property of the branch —
    /// a feature branch cut from `main` and a stacked one cut from that feature branch
    /// merge into different places, and one shared slot would mislabel every second
    /// checkout. An empty value means the user turned the comparison off for that branch,
    /// which must outlast a remount too. In-memory only, like `gitPaneModes`.
    var gitCompareBases: [String: String] = [:]

    static func compareBaseKey(repoRoot: String, branch: String?) -> String {
        "\(repoRoot)\u{1f}\(branch ?? "")"
    }

    /// Whether the selected session is running a coding agent (not a plain shell) —
    /// gates the file tree's "Add to Chat" row action.
    var selectedSessionRunsAgent: Bool {
        guard let id = selectedSessionID, let session = session(id) else { return false }
        return !session.agent.isShell
    }

    /// Types a file's shell-quoted path (plus a trailing space) into the selected
    /// session's terminal — the file tree's "Add to Chat", the menu twin of dropping
    /// the row on the terminal (`TerminalPane.sendPaths`, which shares these tokens).
    @discardableResult
    func addPathToSelectedSessionPrompt(_ url: URL) -> Bool {
        guard let id = selectedSessionID, let session = session(id) else { return false }
        return surface(for: session).send(Self.promptToken(for: url) + " ")
    }

    /// Pastes selected text into the selected session's prompt, wrapped in bracketed
    /// paste so its newlines land as one pasted block instead of submitting line by
    /// line. Unconditional wrapping is safe here because every caller is gated on the
    /// session running a coding agent, and agent TUIs all enable mode 2004 — the same
    /// convention the iOS upload path relies on.
    ///
    /// The bytes go RAW into the PTY (the backend session's input), NOT through
    /// `state.send`: that routes into `ghostty_surface_text`, whose input encoder
    /// re-encodes the ESC of a hand-written `\e[200~` as an escape KEYPRESS (CSI 27u
    /// under the kitty keyboard protocol agents enable) — the TUI then shows a
    /// literal `[200~`. Bracketed-paste framing only means anything as verbatim
    /// PTY input.
    @discardableResult
    func addSnippetToSelectedSessionPrompt(_ text: String) -> Bool {
        guard let id = selectedSessionID, let session = session(id) else { return false }
        let state = surface(for: session)
        guard case let .inMemory(backend) = state.configuration.backend else { return false }
        backend.sendInput(Data(("\u{1B}[200~" + text + "\u{1B}[201~").utf8))
        return true
    }

    /// The shell-quoted token to insert at a prompt for a URL. A `file://` URL becomes
    /// its local path (the file-tree/Finder case, so the prompt gets a usable path);
    /// any other scheme — an https GitHub issue/PR dragged from the Issues pane —
    /// keeps its full `absoluteString`, since stripping to `.path` would drop the
    /// scheme and host and leave a meaningless `/owner/repo/issues/123` fragment.
    static func promptToken(for url: URL) -> String {
        shellQuoted(url.isFileURL ? url.path : url.absoluteString)
    }

    /// Which pane the trailing inspector shows — the file tree or git changes. Set by the toolbar's
    /// segmented switch and read by `FileBrowserView`. (The inspector's open/closed state is owned by
    /// the app delegate's `NSSplitViewItem`, not mirrored here, so the two cannot desync.)
    /// Switching tabs closes any open detail: a detail belongs to the item you picked in *this* tab,
    /// so the new tab starts on a clean list rather than showing the old tab's file/issue/diff.
    @Published var inspectorTab: InspectorTab = .files {
        didSet {
            guard inspectorTab != oldValue else { return }
            openFileURL = nil
            openDiff = nil
            openIssueDetail = nil
        }
    }

    /// The repo's dirty-file count, surfaced from the Changes pane so callers can reflect "has
    /// changes" without the inspector being open.
    @Published var gitChangeCount = 0

    /// What the inspector panes read: the selected session's checkout — a root and
    /// the device that root lives on. Derived here, once, so no pane has to ask a
    /// session which road it was opened by (see `Checkout`).
    ///
    /// The machine is `termiodRemoteHost ?? sshHost`, the pair `DeviceContext`
    /// already trusts. A durable termiod session names its box directly; a plain
    /// `ssh` terminal runs its PTY here but exists to put the user on that box, so
    /// it belongs to the same place.
    ///
    /// The candidate local root comes from the slot: a project session takes its
    /// worktree if it has one and the project folder otherwise, a loose terminal
    /// takes its *live* cwd (falling back to the cwd persisted from the last run,
    /// then `$HOME`) so the tree, search, and changes panes follow a `cd`, and a
    /// loose chat takes the scoped scratch directory. Whether that candidate is
    /// this Mac's to read is the checkout's answer, not the slot's.
    var inspectorCheckout: Checkout? {
        guard let id = selectedSessionID, let slot = locate(id) else { return nil }
        let session = self[slot]
        let project: Project?
        let localRoot: String?
        /// Whether this slot's root is wherever the shell wandered, rather than a
        /// container's fixed path. The same question for both machines: a loose
        /// terminal follows its `cd` here and on a device, and a project session
        /// stays at its checkout on both.
        let followsWorkingDirectory: Bool
        switch slot {
        case .project(let index, _):
            project = projects[index]
            localRoot = session.worktreePath ?? projects[index].path
            followsWorkingDirectory = false
        case .terminals:
            project = nil
            localRoot = workingDirectory(for: id)
                ?? session.lastWorkingDirectory
                ?? Self.looseTerminalRoot
            followsWorkingDirectory = true
        case .chats:
            project = nil
            localRoot = Self.looseChatRoot
            followsWorkingDirectory = false
        }
        let alias = session.termiodRemoteHost ?? session.sshHost
        return Self.checkout(
            for: session,
            in: project,
            localRoot: localRoot,
            liveWorkingDirectory: followsWorkingDirectory ? workingDirectory(for: id) : nil,
            // The route's device, for a session that has never attached and so
            // carries none of its own.
            routeDeviceID: alias.flatMap {
                TermiodDeviceRegistry.shared.deviceID(for: TermiodRoute(sshAlias: $0))
            })
    }

    /// The checkout derivation itself, free of the store so the case that started
    /// this — a session on another machine filed under a local project — can be
    /// tested without a window.
    ///
    /// `localRoot` is the candidate the tree would have used, and is dropped whole
    /// for a session on another box: a local path that merely shares a name with
    /// the remote one is worse than showing nothing.
    ///
    /// `liveWorkingDirectory` is the cwd the session last reported, passed only by
    /// a slot whose root follows it. It is the same rung the local candidate takes
    /// first, offered to the other machine too so a `cd` moves the panes wherever
    /// the shell runs.
    static func checkout(for session: Session, in project: Project?,
                         localRoot: String?, liveWorkingDirectory: String? = nil,
                         routeDeviceID: String?) -> Checkout {
        guard let alias = session.termiodRemoteHost ?? session.sshHost else {
            return Checkout(device: .thisMac, root: localRoot)
        }
        // Identity first, route second: a session that has attached knows the
        // `host_id` it reached, and the alias only stands in until it has.
        let device = KnownDevice(alias: alias, deviceID: session.deviceID ?? routeDeviceID)
        return Checkout(
            device: device,
            root: remoteRoot(for: session, in: project, on: device,
                             liveWorkingDirectory: liveWorkingDirectory))
    }

    /// Where a session on another device is rooted: the directory it is working in
    /// now, else the one it was spawned in, else the checkout recorded for that
    /// device when the session sits under a project.
    ///
    /// The live cwd is taken only for a **termiod** session, whose PTY runs on the
    /// device — that report is a path on the machine the panes read. A plain `ssh`
    /// terminal runs its PTY here, so what the host samples is this Mac's `ssh`
    /// process sitting in some local directory; feeding that back as a path over
    /// there is the wrong-machine mixup this whole type exists to prevent.
    private static func remoteRoot(for session: Session, in project: Project?,
                                   on device: KnownDevice,
                                   liveWorkingDirectory: String?) -> String? {
        if session.termiodRemoteHost != nil, let cwd = liveWorkingDirectory, !cwd.isEmpty {
            return cwd
        }
        if let cwd = session.termiodRemoteCwd { return cwd }
        guard let alias = device.alias, let project else { return nil }
        return project.remoteCheckout(device: device.deviceID, alias: alias)
    }

    /// Whether the trailing inspector panel is expanded. Mirrored from the AppKit
    /// split item — the owner of collapse state — via KVO in `App.swift`, so hosted
    /// panes can stand down while hidden: a collapsed item keeps its view hierarchy
    /// (and any `@StateObject` in it) alive, which left the git pane's auto-refresh
    /// spawning `git status` for a pane nobody could see.
    @Published var inspectorVisible = false

    /// Whether the leading project sidebar is expanded. Mirrored from its AppKit split item the
    /// same way `inspectorVisible` is. A maximized detail reads it to know whether the traffic
    /// lights land on its own header (sidebar collapsed) or on the sidebar (sidebar open).
    @Published var sidebarVisible = true

    /// Whether the window is in native macOS fullscreen. Mirrored from the window's own
    /// enter/exit transitions. Fullscreen hides the traffic lights until the pointer summons the
    /// titlebar, so a maximized detail stops reserving room for them there.
    @Published var windowIsFullScreen = false

    /// A per-session snapshot of the inspector's *content* — which tab is showing, which
    /// detail (file / diff / PR-issue) is open, and how that detail splits the
    /// panel between its list and itself. Switching terminal tabs restores each session's
    /// own right-side context instead of clearing it (issue #160): one session left on a
    /// file, another on a PR, another on the changes list.
    ///
    /// Chrome that covers something the arriving session did not ask to hide is deliberately
    /// absent. The inspector's *width* and *open/closed* state belong to the AppKit split
    /// item, and the full-window maximize is not carried either: re-mounting that host on a
    /// session switch buries the terminal without the user asking (the same defect as #272,
    /// which is why the reveal is an event now). A returning session shows its detail docked;
    /// the user re-maximizes if they want it back.
    struct InspectorState {
        var tab: InspectorTab = .files
        var openFileURL: URL?
        var openFileLine: Int?
        var openFileReadOnly = false
        var openDiff: GitDiffRequest?
        var openIssueDetail: IssueSummary?
        var listCollapsed = false
    }

    /// Each session's saved inspector layout, written when the selection leaves a
    /// session and read back when it returns (see `selectedSessionID`'s didSet). Seeded
    /// from `state.json` on launch for the tab + open-file subset; the live diff / PR
    /// details are in-memory only — they're snapshots of data that gets re-fetched,
    /// so they don't survive a quit (matching VS Code's hot exit, which restores open
    /// files but not transient views). Keyed by session, so a dead session's entry is
    /// pruned alongside its runtime in `syncRuntimes`.
    var inspectorStates: [Session.ID: InspectorState] = [:]

    /// The session each workspace was last left on, so switching back lands where the
    /// user was rather than on whichever row sorts first. Written on every selection
    /// change and read by `finishArriving`.
    ///
    /// Held here rather than on `Workspace` for the same reason `inspectorStates` is:
    /// this is written on every row click, and `workspaces` is `@Published` — a write
    /// there would rebuild the sidebar to record something the sidebar already shows.
    /// Persisted, so the scope you return to after a relaunch is the scope you left.
    /// Entries for closed sessions are pruned alongside their runtimes in `syncRuntimes`.
    var workspaceSelections: [Workspace.ID: Session.ID] = [:]

    /// True only while `restored()` seeds the saved layouts and hand-applies the selected
    /// one — it suppresses the capture/restore in `selectedSessionID`'s didSet so a
    /// programmatic selection during launch can't overwrite a just-seeded layout.
    private var isRestoringInspector = false

    /// True while a detail is being *re-stated* rather than opened: `applyInspectorState`
    /// re-hydrating a session's saved layout (the session switch and the launch restore both
    /// route through it), or `refreshOpenDiffSiblings` freshening the walk order under a diff
    /// already on screen. The detail setters run normally — only `detailDidOpen` is withheld,
    /// so putting content back can never re-expand an inspector the user collapsed.
    private var isRestatingDetail = false

    /// Debounced whole-state save for durable inspector edits (opening a file, switching
    /// the tab). Unlike a session switch, these don't move `selectedSessionID`, so nothing
    /// else persists them — without this, opening a file and quitting without switching
    /// would lose it. Debounced so a burst of clicks writes once. Skipped during restore.
    private func persistInspectorSoon() {
        guard !isRestoringInspector else { return }
        persistSoon()
    }

    /// Coalesces a burst of tree edits into one write a beat later. Every caller
    /// that fires on a gesture or a click routes through here; only the paths
    /// that must survive an immediate crash (`persistNow`) write inline.
    func persistSoon() {
        guard !isRestoringInspector else { return }
        persistDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.persist() } }
        persistDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes any pending debounced save immediately. Called on quit, so a
    /// selection or layout change made in the last beat before ⌘Q is not lost.
    func persistNow() {
        persistDebounce?.cancel()
        persistDebounce = nil
        persist()
    }

    /// Snapshots the inspector's current content into an `InspectorState`.
    private func captureInspectorState() -> InspectorState {
        InspectorState(
            tab: inspectorTab,
            openFileURL: openFileURL,
            openFileLine: openFileLine,
            openFileReadOnly: openFileReadOnly,
            openDiff: openDiff,
            openIssueDetail: openIssueDetail,
            listCollapsed: inspectorListCollapsed
        )
    }

    /// Restores a session's saved inspector layout (or the default when it has none).
    /// Order is load-bearing: `inspectorTab`'s didSet clears the details, so the tab is
    /// set first; the issue is set before the diff because a PR file diff deliberately
    /// stacks on top of an open issue (see `openIssueDetail`); and the read-only flag /
    /// jump line precede the file URL (see `openFileURL`).
    private func applyInspectorState(_ state: InspectorState) {
        isRestatingDetail = true
        defer { isRestatingDetail = false }
        inspectorTab = state.tab
        openFileURL = nil; openDiff = nil; openIssueDetail = nil
        openIssueDetail = state.openIssueDetail
        openFileReadOnly = state.openFileReadOnly
        openFileLine = state.openFileLine
        openFileURL = state.openFileURL
        openDiff = state.openDiff
        // Always docked, never carried: see `InspectorState`. A session left maximized
        // must not blow its detail back up over the arriving terminal, and the departing
        // session's maximize must not follow the selection either.
        inspectorMaximized = false
        inspectorListCollapsed = state.listCollapsed
    }

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

    /// A coarse "some session’s runtime changed" ping for observers that can't
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
    /// Reads the live set off `sessionSlots`, so it must run after
    /// `rebuildSessionSlots` — and off the index rather than `allSessions`, which
    /// would copy every session to answer a question about ids.
    func syncRuntimes() {
        let live = Set(sessionSlots.sessionIDs)
        for id in live where runtimes[id] == nil { runtimes[id] = SessionRuntime() }
        for id in runtimes.keys where !live.contains(id) { runtimes.removeValue(forKey: id) }
        // A closed session's saved inspector layout goes with it, and so does its
        // claim on being the row a workspace comes back to.
        for id in inspectorStates.keys where !live.contains(id) { inspectorStates.removeValue(forKey: id) }
        for (workspace, id) in workspaceSelections where !live.contains(id) {
            workspaceSelections.removeValue(forKey: workspace)
        }
    }

    /// Sets a session's status, no-op-guarded so a redundant same-value write (the hook
    /// path re-asserts `.working` on every tool event) neither re-renders the row nor
    /// pings the tray. Returns whether it actually changed, for callers that gate
    /// follow-on work on a real transition.
    @discardableResult
    func setStatus(_ status: SessionStatus, for id: Session.ID) -> Bool {
        let runtime = runtime(for: id)
        guard runtime.status != status else { return false }
        runtime.status = status
        // A blocked session's dot survives a click (see `markSeen`); any genuine
        // transition off `.needsAttention` — the agent proceeded, or the condition
        // otherwise cleared — retires the "still blocking" flag that kept it lit.
        if status != .needsAttention { blockingAttention.remove(id) }
        // The tray and window title present status, so a real change pings them.
        sessionRuntimeDidChange.send()
        // Push the genuine transition to any `termio sessions watch` clients scoped
        // to this session's project. The hub does the socket writes off the main
        // thread, so a watcher never slows the agent tick that produced the event.
        if let session = session(id), let project = project(for: id) {
            var event = SessionWatchEvent(
                projectID: project.id,
                link: sessionLink(for: session),
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
        // Settling on a "your turn" state is the one transition worth a desktop
        // notification. Firing from the choke point (no-op writes never reach here)
        // is what keeps one completion to one notification; the notifier applies
        // its own gates (setting off, plain terminal, app frontmost, short turn).
        // The working transition starts the turn clock those gates measure against.
        if status == .working {
            TaskNotificationCenter.shared.sessionDidStartWorking(id)
        } else if status == .done || status == .needsAttention {
            TaskNotificationCenter.shared.sessionDidSettle(id, status: status)
        }
        return true
    }

    /// Sets the running tool for a session (`nil` clears it), guarded like `setStatus`.
    /// No runtime ping: the tool shows only in the sidebar row's own tooltip, which
    /// tracks its session's runtime directly — no AppKit observer reads it.
    func setCurrentTool(_ tool: String?, for id: Session.ID) {
        // A named tool is the "this turn did real work" signal the notifier's
        // task-vs-chat gate keys on. Recorded at this choke point — before the
        // no-op guard, since the gate cares about the turn, not the value change —
        // so any future tool source feeds the gate without extra wiring.
        if tool != nil { TaskNotificationCenter.shared.sessionDidUseTool(id) }
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

    /// Realized file trees per root directory, so returning to a checkout hands the
    /// outline its tree back instead of rebuilding it. Lives here, beside the
    /// surface cache, for the same reason that one does: the model has to outlive
    /// the view that shows it. See `FileTreeCache`.
    let fileTrees = FileTreeCache()

    var surfaces: [Session.ID: TerminalViewState] = [:]
    var monitors: [Session.ID: [AnyCancellable]] = [:]
    /// Spawned sessions whose prompt was written but never appeared on screen —
    /// almost always an agent still on a startup gate, which consumes typed text
    /// as an answer to its own question. Reported by `sessions list` because the
    /// caller already has its reply by the time this is known.
    var undeliveredPrompts: Set<Session.ID> = []
    /// The daemon attachment behind each session: each
    /// session's attach channel into the local termiod daemon, which owns the
    /// PTY so the session outlives this app instance.
    var termiodLinks: [Session.ID: TermiodSessionLink] = [:]
    /// Why a termiod session died, keyed by the daemon's session name — which,
    /// for sessions this app created, is the `Session.ID` uuid string. Learned
    /// from the roster reply (`Termiod.roster`), which carries the daemon's
    /// graveyard alongside the live list.
    ///
    /// A session that is simply *missing* is indistinguishable from one that
    /// never existed; a tombstone is the difference between "gone" and "the
    /// daemon died under it while your agent was mid-turn". Read it with
    /// `termiodEndReason(for:)`.
    var termiodTombstones: [String: Termiod.SessionTombstone] = [:]

    /// Daemon sessions this app has destroyed, remembered by daemon name — the
    /// closed-session journal (RFC 20260830). Written **before** every
    /// name-addressed kill so a close survives an unreachable route or a crash:
    /// the roster sweep (`reconcileExternalSessions`) kills a journaled name on
    /// sight and drops a record once its name stops appearing. Bounded by
    /// `journalClosedSession`; persisted through `StateFile`.
    var closedSessionJournal: [ClosedDaemonSession] = []

    /// Per-session evidence that a declared agent's wrapped shell has outlived
    /// it (RFC 20260830 §D2), fed by the daemon's foreground sampler. Cleared
    /// with the rest of the activity trackers.
    var agentExitStreaks: [Session.ID: AgentExitStreak] = [:]

    /// Which device the app is looking at, as the alias that reaches it (`nil` is
    /// this Mac). **The** context: the sidebar, the window chrome, and every panel
    /// added later read `currentDevice` rather than deciding for themselves.
    ///
    /// It lives here and not in `AppSettings` because it is live state with
    /// consequences, not a preference — settings keeps a copy purely so the next
    /// launch starts where this one ended. Written only through
    /// `switchToDevice(_:)`, which moves the selection and the roster with it.
    @Published var currentDeviceAlias: String?

    /// What the current device last said is running on it. `unavailable` until a
    /// device has been asked, which is also the resting state with the daemon
    /// backend off.
    @Published var deviceSessions: DeviceSessionsState = .unavailable

    /// Guards against a slow reply from a device the user has already left: every
    /// request stamps this counter and a reply that no longer matches is dropped.
    /// Without it, switching away during an SSH round trip repaints the sidebar
    /// with the previous machine's sessions.
    var deviceSessionsGeneration = 0

    /// Which route the published `deviceSessions` describes. A roster is only
    /// reusable for the machine it came from, so every decision to skip a fetch
    /// or a publish has to check this first — without it, coalescing two
    /// requests would leave one machine's sessions on screen under another
    /// machine's name.
    var deviceSessionsRoute: String?

    /// What the roster path knows about one route between requests. Keyed by
    /// `TermiodRoute.description` in `rosterFetches`.
    struct RosterFetch {
        /// A request is out and its reply is still coming.
        var inFlight = false
        /// When the last reply landed, so a repeat ask inside the coalescing
        /// window can be answered with what is already on screen.
        var settledAt: ContinuousClock.Instant?
        /// What this route last answered, so an identical answer can be
        /// recognised as one. Compared against the route's own last reply
        /// rather than against what is published: after a switch away and back
        /// the published answer belongs to a different machine, and comparing
        /// with that would call every reply new.
        var answer: DeviceSessions?
    }

    var rosterFetches: [String: RosterFetch] = [:]

    /// Routes whose daemon this app has asked to stop and is waiting to see come
    /// back (`ensureRemoteReady`). A roster that fails meanwhile is the restart
    /// in progress, not a dead machine — without this the two are the same red
    /// row. Keyed by `TermiodRoute.description`.
    var upgradingRoutes: Set<String> = []

    /// App-quit teardown, from the era when the app owned the PTYs: it had to
    /// signal every child, because the closing PTY's SIGHUP is swallowed by agent
    /// TUIs and they piled up as orphans. The daemon owns them now and outlives
    /// the app, so the teardown is the opposite verb.
    func detachAllSessions() {
        // Surviving the quit is the whole point, so the channel detaches and
        // the daemon keeps the process. Ending a session is reserved for the
        // explicit Close Session verb.
        for link in termiodLinks.values { link.detach() }
        termiodLinks.removeAll()
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
    /// The hooks-enabled value last written to disk, so a settings change only
    /// rewrites the hooks file when this specific setting flips — not on every
    /// unrelated appearance change that also fires `objectWillChange`.
    var installedHooksEnabled: Bool?

    /// The socket the `termio` CLI drives the app through. Runs for the app's
    /// lifetime (harmless when the feature is off — the handler refuses with
    /// "disabled"); only the awareness note installed into the agent instruction
    /// files is toggled.
    var appSocket: AppSocketListener?
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

    /// When each currently-working session last reported activity. The device
    /// decides when a turn has gone quiet — this is what a client keeps so it
    /// can say how long ago, not a sweep of its own.
    var lastWorkingAt: [Session.ID: Date] = [:]
    /// Sessions whose `.needsAttention` dot came from a genuine, *observable*
    /// blocking condition — a hook / screen / title "attention" signal, all of which
    /// have a matching "resolved" transition (the agent proceeds → working/idle/done).
    /// `markSeen` keeps such a dot lit through a click, because looking at a
    /// permission prompt isn't answering it; only the real resolving transition
    /// clears it (dropped here in `setStatus` on any move off `.needsAttention`). A
    /// one-shot bell/notification attention — which has no "resolved" event to wait
    /// for — is deliberately *not* recorded here, so it still dismisses on view.
    var blockingAttention: Set<Session.ID> = []
    /// When a session's hooks last applied any state, so the screen-driven
    /// device's screen channels can defer to live hooks: a session whose hooks
    /// just spoke doesn't need the screen to guess for them. The rule runs on
    /// the device now; the timestamp stays because the Info pane reads it.
    var lastHookReportAt: [Session.ID: Date] = [:]
    /// Hooks are trusted for a window after their last report before the
    /// device's screen channels may promote a session on their own — a rule the
    /// daemon now enforces (`termiod/src/session/status.rs`). The app keeps the
    /// timestamp because the Info pane says when the agent last spoke.
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

    init(workspaces: [Workspace], projects: [Project] = [], settings: AppSettings) {
        self.settings = settings
        let reconciled = WorkspaceMigration.reconcile(workspaces: workspaces, projects: projects)
        // The scope the app opens in: the one the last run ended in, or the first
        // workspace when that id no longer names anything.
        let opening = reconciled.workspaces.first { $0.id == settings.currentWorkspaceID }
            ?? reconciled.workspaces.first
            ?? Workspace(name: Workspace.defaultName)
        self.workspaces = reconciled.workspaces.isEmpty ? [opening] : reconciled.workspaces
        self.projects = reconciled.projects
        self.currentWorkspaceID = opening.id
        let openingSessions = opening.looseSessions
            + reconciled.projects.filter { $0.workspaceID == opening.id }.flatMap(\.sessions)
        let firstShown = openingSessions.first
        self.selectedSessionID = firstShown?.id
        // The machine the app opens on: the one the session it is about to show
        // runs on, and the device the last run ended on when it shows nothing.
        //
        // The session outranks the stored alias because it is a fact about
        // something running, while the alias is only where the user last was, and
        // the two can disagree — a state file older than the alias beside it, a
        // device dropped from `~/.ssh/config` since. A window that opens naming
        // one machine while showing another's terminal is the confusion the
        // device badge exists to prevent. (A later selection realigns the context
        // through the selection's `didSet`; this covers the first one, which is
        // assigned before that `didSet` is armed.)
        self.currentDeviceAlias = firstShown.map { $0.termiodRemoteHost ?? $0.sshHost }
            // A machine's fallback workspace *is* that machine, so opening in one
            // is being on it even before a session is picked.
            ?? opening.deviceAlias
            ?? settings.currentDeviceAlias
        let storedColumns = UserDefaults.standard.integer(forKey: Self.hostGridColumnsKey)
        let storedRows = UserDefaults.standard.integer(forKey: Self.hostGridRowsKey)
        self.lastHostGridColumns = storedColumns > 0 ? storedColumns : 80
        self.lastHostGridRows = storedRows > 0 ? storedRows : 24
        // The initial `projects` assignment above runs before `didSet` is armed, so
        // seed the slot index and the runtime map for the restored tree explicitly
        // (later add/remove goes through `projects.didSet`). Index first —
        // `syncRuntimes` reads it.
        rebuildSessionSlots()
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
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleWorktreeReconcile()
                // Re-assert agent hooks on refocus: a third-party tool can overwrite the
                // shared hooks file while termio is backgrounded, wiping ours. Re-installing
                // restores them (and drops the conflicting entries); skipped when the file
                // is already byte-identical.
                if self.settings.agentHooksEnabled { self.syncAgentIntegration() }
            }
        reconcileWorktrees()

        // The support copy exists to version-update with the app, but the
        // hook-sync paths refresh it only when a toggle changes or on refocus
        // with hooks on. Refresh unconditionally here: hooks and the PATH
        // symlink exec this copy directly, and after an app update it must
        // carry the new build's client.
        CommandLineTool.refreshSupportCopy()

        startHookMonitoring()
        startAppSocket()
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
        for project in projects {
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
        guard let snapshot = StateFile().load(),
              !(snapshot.workspaces ?? []).isEmpty || !snapshot.projects.isEmpty
        else {
            return TermioStore(workspaces: Workspace.firstRun(), settings: settings)
        }

        // A file written before workspaces existed is upgraded here, once: every
        // container it holds becomes a workspace or a project, and nothing it
        // holds is dropped. A file that already has workspaces skips the upgrade.
        let store: TermioStore
        if let workspaces = snapshot.workspaces, !workspaces.isEmpty {
            if let stored = snapshot.currentWorkspaceID { settings.currentWorkspaceID = stored }
            store = TermioStore(
                workspaces: workspaces, projects: snapshot.projects, settings: settings)
        } else {
            let migrated = WorkspaceMigration.migrate(snapshot.legacyProjects ?? [])
            store = TermioStore(
                workspaces: migrated.workspaces, projects: migrated.projects, settings: settings)
        }
        // Seed each session's saved inspector layout (tab + open file). The file is
        // validated for existence — a file deleted, or a worktree removed, while the app
        // was closed silently falls back to no detail rather than an error overlay.
        if let layouts = snapshot.inspectorLayouts {
            let live = Set(store.allSessions.map(\.id))
            for (key, layout) in layouts {
                guard let id = UUID(uuidString: key), live.contains(id) else { continue }
                var state = InspectorState(tab: layout.tab)
                if let path = layout.filePath, FileManager.default.fileExists(atPath: path) {
                    state.openFileURL = URL(fileURLWithPath: path)
                    state.openFileLine = layout.fileLine
                    state.openFileReadOnly = layout.fileReadOnly ?? false
                }
                store.inspectorStates[id] = state
            }
        }
        // Seed where each workspace was left. Validated against the live tree, since a
        // session recorded before the quit may not have come back — a workspace whose
        // row is gone falls back to its first session the way it always did.
        if let selections = snapshot.workspaceSelections {
            let live = Set(store.allSessions.map(\.id))
            for (key, id) in selections {
                guard let workspace = UUID(uuidString: key), live.contains(id) else { continue }
                store.workspaceSelections[workspace] = id
            }
        }
        // Guard the selection change so its didSet neither captures the (still-default)
        // live inspector over a just-seeded layout nor schedules a startup save.
        store.isRestoringInspector = true
        if let id = snapshot.selectedSessionID, store.session(id) != nil {
            store.selectedSessionID = id
        }
        // The designated init set the selection without firing its didSet, and re-setting
        // it to the same id above is a no-op, so apply the selected session's restored
        // layout to the live inspector props explicitly.
        if let id = store.selectedSessionID, let state = store.inspectorStates[id] {
            store.applyInspectorState(state)
        }
        store.isRestoringInspector = false
        // Restore the split groups, keeping only those whose panes all still
        // resolve to live sessions (a stale group is dropped whole rather than
        // patched — the user just re-splits). State files from before groups
        // existed persisted a single `splitRoot` layout; it migrates as one group.
        let savedGroups = snapshot.splitGroups ?? snapshot.splitRoot.map { [$0] } ?? []
        store.splitGroups = savedGroups.filter { group in
            group.leafIDs.count >= 2 && group.leafIDs.allSatisfy { store.session($0) != nil }
        }
        // State files written before the runs were kept adjacent can hold a group
        // whose rows a since-ungrouped session still sits between; heal it on load
        // rather than waiting for the next group edit.
        store.gatherSplitRuns()
        // Closes made while a route was offline (or right before a crash) come
        // back as pending kills; the first roster refresh per route settles them.
        store.closedSessionJournal = snapshot.closedDaemonSessions ?? []
        return store
    }

    private func persist() {
        let span = Trace.workspace.begin("persist")
        defer { Trace.workspace.end(span) }
        // Fold the current selection's live inspector layout in — it isn't copied into
        // `inspectorStates` until the selection leaves it.
        var states = inspectorStates
        if let id = selectedSessionID { states[id] = captureInspectorState() }
        var layouts: [String: StateFile.InspectorLayout] = [:]
        for (id, state) in states {
            // Skip the plain default (Files tab, nothing open) to keep the file lean.
            guard state.tab != .files || state.openFileURL != nil else { continue }
            layouts[id.uuidString] = StateFile.InspectorLayout(
                tab: state.tab,
                filePath: state.openFileURL?.path,
                fileLine: state.openFileLine,
                fileReadOnly: state.openFileReadOnly
            )
        }
        var selections: [String: Session.ID] = [:]
        for (workspace, id) in workspaceSelections { selections[workspace.uuidString] = id }
        stateFile.save(.init(
            workspaces: workspaces,
            currentWorkspaceID: currentWorkspaceID,
            projects: projects,
            selectedSessionID: selectedSessionID,
            splitGroups: splitGroups,
            inspectorLayouts: layouts.isEmpty ? nil : layouts,
            workspaceSelections: selections.isEmpty ? nil : selections,
            closedDaemonSessions: closedSessionJournal.isEmpty ? nil : closedSessionJournal
        ))
    }

    func status(for sessionID: Session.ID) -> SessionStatus {
        runtimes[sessionID]?.status ?? .idle
    }

    /// Why a declared agent row is idle over a live shell ("Claude Code exited —
    /// shell"), or `nil` while the agent runs. See `noteDeclaredAgentForeground`.
    func agentExitNotice(for sessionID: Session.ID) -> String? {
        runtimes[sessionID]?.agentExitNotice
    }

    /// The live working directory a session last reported (shell `OSC 7`), or `nil`.
    /// A thin accessor over the runtime so the inspector / file browser read the same
    /// place the sidebar label does, without touching the storage directly.
    func workingDirectory(for sessionID: Session.ID) -> String? {
        runtimes[sessionID]?.workingDirectory
    }

    /// The folder the window chrome names for a session: a project session's worktree
    /// if it has one, else its project folder. A loose terminal belongs to no project
    /// but owns its path, so it names its live cwd — the same place the sidebar row and
    /// the inspector already follow (see `inspectorCheckout`). `nil` for a loose chat,
    /// whose scoped scratch directory is not a place worth naming, and for an unknown id.
    ///
    /// The loose ladder walks down to `$HOME` rather than stopping at the reported cwd:
    /// a shell reports nothing until its first prompt, so a fresh terminal would
    /// otherwise show the app's own name for a beat and then swap to a path. These are
    /// the rungs `surface(for:in:)` spawns the shell down, so the title names where the
    /// shell is about to land, not where it has confirmed it is.
    func titleFolder(for sessionID: Session.ID) -> String? {
        guard let session = session(sessionID) else { return nil }
        if let project = project(for: sessionID) {
            return session.worktreePath ?? project.path
        }
        guard isLooseTerminal(sessionID) else { return nil }
        return workingDirectory(for: sessionID)
            ?? session.lastWorkingDirectory
            ?? session.spawnDirectory
            ?? Self.looseTerminalRoot
    }

    /// Whether the user is plausibly looking at this session right now: termio is
    /// the active app and the session is selected. The status paths use it to pick
    /// between a quiet in-place settle and a "your turn" cue — with termio in the
    /// background, even the selected session isn't being watched, and the cue is
    /// what lets the desktop notification fire (it only hears real transitions).
    func isViewing(_ id: Session.ID) -> Bool {
        NSApp.isActive && selectedSessionID == id
    }

    /// Acknowledge a resting "your turn" cue: a finished (`.done`) or blocked
    /// (`.needsAttention`) session the user has now engaged with drops back to
    /// `.idle`, clearing its sidebar/tray dot. A mid-turn `.working` is left
    /// alone — its spinner isn't a cue to dismiss. Idempotent, and unlike the
    /// `selectedSessionID` didSet it doesn't require the selection to *change*, so
    /// re-clicking the session you're already on still clears the dot.
    func markSeen(_ id: Session.ID) {
        // Engaging with the session makes any delivered banner stale too.
        TaskNotificationCenter.shared.withdraw(for: id)
        switch status(for: id) {
        case .done:
            // A finished cue is dismissed by engaging with the row — seeing "ready
            // for you" is enough.
            setStatus(.idle, for: id)
        case .needsAttention where !blockingAttention.contains(id):
            // A blocked cue is NOT dismissed by looking: reading a permission prompt
            // isn't answering it, so a dot from a real blocking condition stays lit
            // until the agent actually proceeds (the resolving transition clears it).
            // Only a one-shot bell/notification attention — untracked, with no
            // "resolved" event to wait for — is dismissed on view, as it always was.
            setStatus(.idle, for: id)
        default:
            break
        }
    }

    /// Selects a session in the sidebar and brings termio to the front — the
    /// "come look at this" verb shared by `termio sessions focus` and a
    /// task-notification click (which may find the window miniaturized).
    func revealSession(_ id: Session.ID) {
        guard session(id) != nil else { return }
        selectedSessionID = id
        // Explicit, because the didSet above skips a same-value write: revealing
        // a session that was already selected (app in background) must still
        // acknowledge its "your turn" dot and withdraw its banner.
        markSeen(id)
        NSApp.activate(ignoringOtherApps: true)
        if let window = AppDelegate.mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
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
    /// distinguishable. Agents whose OSC title names only the project can instead
    /// fall back to a compact first-prompt title supplied by their hook. A
    /// `givenTitle` wins over both, then a meaningful native title, then the
    /// prompt-derived fallback, then the composed placeholder.
    ///
    /// Plain terminals never adopt a live title (their shell would just report
    /// `user@host`/cwd noise); instead the ones Termio named itself all show a bare
    /// `Terminal` label. `title` is left untouched throughout — only the displayed
    /// value is derived here.
    ///
    /// The name a row was given is a field (`Session.givenTitle`), never a string
    /// test over `title`: a session running on another machine is born with a label
    /// Termio composed for it, and reading that label as chosen is what used to
    /// freeze a remote row at `<project> · <host>` for the rest of its life.
    func displayTitle(for session: Session) -> String {
        if let given = session.givenTitle { return given }
        if session.agent != .terminal {
            return AgentSessionTitle.automatic(
                native: runtimes[session.id]?.liveTitle ?? session.liveTitle,
                promptFallback: session.promptTitle,
                placeholder: session.title)
        }
        // A loose terminal is labeled by its live cwd's basename (`~` at home):
        // the session owns its path, so `cd ~/code/foo` renames the row to `foo`
        // (see docs/design/20260713-loose-terminal-entity.md). Falls back to the cwd
        // persisted from the last run, then to a bare `Terminal` before the
        // shell's first OSC 7 report. Project terminals keep the plain label —
        // their place is the project, not wherever they've wandered.
        if isLooseTerminal(session.id),
           let cwd = runtimes[session.id]?.workingDirectory ?? session.lastWorkingDirectory {
            return Self.terminalLabel(forPath: cwd)
        }
        return "Terminal"
    }

    /// A loose terminal's display label for a working directory: `~` at the home
    /// directory, otherwise the folder's basename. Shared with the toolbar title so
    /// the row and the chrome above it name the same place the same way.
    static func terminalLabel(forPath path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return "~"
        }
        let name = (standardized as NSString).lastPathComponent
        return name.isEmpty ? standardized : name
    }

    /// Whether `title` is an auto-generated `Terminal N` label (as opposed to a
    /// name the user chose), which is what makes it eligible for live re-indexing.
    /// A pure test over the string, so `Session` can reach it while decoding off
    /// the main actor.
    nonisolated static func isAutoTerminalName(_ title: String) -> Bool {
        let suffix = title.dropFirst("Terminal ".count)
        return title.hasPrefix("Terminal ") && !suffix.isEmpty
            && suffix.allSatisfy(\.isNumber)
    }

    /// The single state the menu-bar pulse renders: any session waiting on the
    /// user wins, then any working session, then any just-finished one, else calm.
    var aggregateStatus: SessionStatus {
        // Every session on the machine, never the current workspace's: a scope
        // narrows which panes you see, never which agents are waiting on you.
        let all = allSessions.map { status(for: $0.id) }
        if all.contains(.needsAttention) { return .needsAttention }
        if all.contains(.working) { return .working }
        if all.contains(.done) { return .done }
        return .idle
    }

    func session(_ id: Session.ID) -> Session? {
        locate(id).map { self[$0] }
    }

    /// The project a session belongs to, or `nil` for a loose one — a workspace's
    /// terminals and chats answer to no folder, which is what makes them loose.
    func project(for sessionID: Session.ID) -> Project? {
        guard case .project(let index, _)? = locate(sessionID) else { return nil }
        return projects[index]
    }

    /// Opens a file in the editor overlay in its normal **editable** mode — the inspector's own
    /// file-tree click path. Pairs with `openTerminalLink`, which opens read-only; routing through
    /// these two methods (rather than assigning `openFileURL` directly) keeps the read-only flag and
    /// the URL in step.
    func openFileInEditor(_ url: URL, at line: Int? = nil) {
        filePresentationGeneration &+= 1
        remotePreviewLease = nil
        openFileRemote = nil
        openFileDisplayName = nil
        openFileReadOnly = false
        openFileAllowsActiveWebContent = true
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
        let base = surfaceWorkingDirectory ?? selectedSessionRoot
        let url: URL = (link as NSString).isAbsolutePath || base == nil
            ? URL(fileURLWithPath: link)
            : URL(fileURLWithPath: link, relativeTo: URL(fileURLWithPath: base!, isDirectory: true))
        presentFilePreview(url.standardizedFileURL)
    }

    /// Covers the terminal with a read-only preview of a local `url`, but only
    /// if it points at an existing regular file.
    private func presentFilePreview(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        filePresentationGeneration &+= 1
        remotePreviewLease = nil
        openFileRemote = nil
        openFileDisplayName = nil
        openFileReadOnly = true
        openFileAllowsActiveWebContent = true
        openFileURL = url
    }

    /// Adopts a staged remote file only if no newer presentation won while its
    /// bytes were downloading. The lease owns cleanup and the remote display
    /// name stays separate from the randomized local leaf.
    ///
    /// `line` is the 1-based line to scroll to — a search hit's, since the pane
    /// that opened it knows which line matched. `nil` for the tree, which opens a
    /// file at its top.
    @discardableResult
    func presentRemoteFilePreview(
        _ lease: RemotePreviewLease,
        expectedGeneration: UInt64,
        at line: Int? = nil,
        origin: RemoteDocument? = nil
    ) -> Bool {
        guard expectedGeneration == filePresentationGeneration,
              FileManager.default.fileExists(atPath: lease.fileURL.path)
        else { return false }

        filePresentationGeneration &+= 1
        remotePreviewLease = lease
        openFileDisplayName = lease.displayName
        // Editable when the device said where these bytes came from: the editor
        // writes the staged copy as always, and `openFileRemote` is what carries
        // it the rest of the way back. Without an origin the bytes are just a
        // copy on this Mac, and editing them would be a change that goes nowhere.
        openFileRemote = origin
        openFileReadOnly = origin == nil
        openFileAllowsActiveWebContent = false
        openFileLine = line
        openFileURL = lease.fileURL
        return true
    }

    /// Opens a file that lives on another machine: the overlay goes up on the
    /// click, and the bytes fill it in when they land.
    ///
    /// The single path both the device's file tree and its content search open
    /// through, because the interesting part is the same for both and easy to
    /// get subtly different twice. Three things happen in order:
    ///
    /// 1. **The click is answered immediately.** `openingRemoteFile` puts the
    ///    file's own chrome on screen for the whole round trip. This is the whole
    ///    difference between a device tree that feels local and one that looks
    ///    broken: the wire was never the slow part, the silence was.
    /// 2. **A cached copy is shown at once** when this file has been read before,
    ///    so going back to a file you just closed costs nothing.
    /// 3. **The device is asked anyway.** A cache that answered on its own would
    ///    be wrong the moment an agent touched the file, which here is constantly.
    ///    The reply replaces what is on screen only when it actually differs and
    ///    nobody has started typing into it.
    func openRemoteFile(
        path: String, name: String, provider: DeviceFileProvider, host: String,
        at line: Int? = nil
    ) {
        let key = RemoteFileContentCache.Key(
            route: provider.route, root: provider.root, path: path)
        // Explicitly, not through `openFileURL`'s `didSet`: a second click while
        // the first file is still on its way never changes that URL, and the
        // first download would otherwise run on.
        cancelRemoteFileOpen()
        openFileURL = nil
        openingRemoteFile = RemoteFileOpening(name: name, host: host)

        let cached = RemoteFileContentCache.entry(for: key)
        if let cached {
            _ = presentRemoteFile(
                cached.data, mtime: cached.mtime, name: name, path: path,
                provider: provider, host: host, at: line)
        }
        // After the cached present, which bumps the generation itself.
        let generation = filePresentationGeneration
        remoteOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let file = try await provider.read(
                    path, limit: Termiod.filePreviewByteLimit)
                try Task.checkCancellation()
                // Before presenting, so the cache is written even for the open
                // that gets cancelled by the presentation it is performing.
                RemoteFileContentCache.store(
                    .init(data: file.data, mtime: file.mtime), for: key)
                guard generation == self.filePresentationGeneration else { return }
                if let cached {
                    // The device agrees with what is already on screen, or the
                    // person has started typing into it. Either way, rebuilding
                    // the editor under them would be the wrong answer.
                    guard file.data != cached.data, !self.openFileDirty else { return }
                }
                _ = self.presentRemoteFile(
                    file.data, mtime: file.mtime, name: name, path: path,
                    provider: provider, host: host, at: line)
            } catch is CancellationError {
                return
            } catch {
                Log.files.error("""
                device read \(host, privacy: .public):\(path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
                // A failed revalidation of bytes already on screen is not the
                // user's problem — what they are reading is still what the
                // device last said.
                guard cached == nil, generation == self.filePresentationGeneration else { return }
                self.openingRemoteFile = RemoteFileOpening(
                    name: name, host: host,
                    failure: RemoteFileFailure.message(for: error))
            }
        }
    }

    /// Stages one device file locally and puts it on screen. Shared by the first
    /// present and the revalidation that may replace it.
    private func presentRemoteFile(
        _ data: Data, mtime: UInt64, name: String, path: String,
        provider: DeviceFileProvider, host: String, at line: Int?
    ) -> Bool {
        do {
            let lease = try RemotePreviewStorage.stage(data, named: name)
            return presentRemoteFilePreview(
                lease, expectedGeneration: filePresentationGeneration, at: line,
                origin: RemoteDocument(
                    route: provider.route, root: provider.root, path: path,
                    mtime: mtime, host: host))
        } catch {
            Log.files.error("""
            staging \(host, privacy: .public):\(path, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
            // Only when this open has nothing on screen yet. A revalidation that
            // failed to stage its replacement leaves the copy already being read
            // alone rather than covering it with an error about bytes the reader
            // never asked for.
            if openFileURL == nil {
                openingRemoteFile = RemoteFileOpening(
                    name: name, host: host, failure: RemoteFileFailure.message(for: error))
            }
            return false
        }
    }

    /// Ends a remote open in flight and takes its placeholder down.
    func cancelRemoteFileOpen() {
        remoteOpenTask?.cancel()
        remoteOpenTask = nil
        if openingRemoteFile != nil { openingRemoteFile = nil }
    }

    /// The working directory of the selected session (its worktree, else the project root), used as
    /// the fall-back base for resolving a relative path when the surface hasn't reported an OSC 7 cwd.
    private var selectedSessionRoot: String? {
        guard let id = selectedSessionID, let session = session(id) else { return nil }
        return session.worktreePath ?? project(for: id)?.path
    }
}

/// The order the sidebar names an agent session in, kept out of `TermioStore` so a
/// test can pin the precedence without standing up a window.
enum AgentSessionTitle {
    /// What an agent row calls itself when nobody has named it: the agent's own
    /// native title speaks first, the first prompt stands in when it says nothing,
    /// and the composed placeholder shows only when neither has anything to say.
    static func automatic(
        native: String?, promptFallback: String?, placeholder: String
    ) -> String {
        native ?? promptFallback ?? placeholder
    }
}
