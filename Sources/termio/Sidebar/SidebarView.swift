import SwiftUI
import AppKit
import TermioShared

extension AppSettings {
    /// The sidebar text font built from the interface preferences. An empty family
    /// falls back to the system UI font at the chosen size, so a font the user
    /// doesn't have installed is never forced.
    var interfaceFont: Font {
        interfaceFontFamily.isEmpty
            ? .system(size: interfaceFontSize)
            : .custom(interfaceFontFamily, size: interfaceFontSize)
    }
}

/// SwiftUI's `.sidebar` list style hands every row an inset the column can't set: the list's own
/// leading margin plus the 16pt strip `NSTableView.sourceList` reserves for a disclosure column a
/// flat list never uses. Left alone it lands the first glyph's ink at 24.5pt — five and a half
/// points right of the close button's leading edge, which AppKit puts at 19pt. Every row and
/// section label pulls back by this much so the column starts on the traffic lights' line: the
/// window's own left margin (`WindowChrome.trafficLightsLeading`). The hover chip stays outside that line rather than on it — a highlight whose edge
/// touches the glyph it lifts reads as a crop, so it keeps the 6pt gutter Finder's own selection
/// pill carries around its items.
private let sidebarLeadingTrim: CGFloat = 7.5


/// Left column: projects, each a section containing its sessions. Hovering a
/// project header reveals VSCode-style quick-add buttons (one per agent preset).
/// One pinned worktree lifted into the sidebar's top working set, paired with its
/// parent project for the origin breadcrumb. `id` is the worktree's so the mini-block
/// keeps its identity across renders.
private struct PinnedWorktreeEntry: Identifiable {
    let project: Project
    let worktree: Worktree
    var id: Worktree.ID { worktree.id }
}

/// One pinned session lifted into the sidebar's top working set, paired with its parent
/// project for the origin breadcrumb. A loose session has no project, so it carries none.
private struct PinnedSessionEntry: Identifiable {
    let project: Project?
    let session: Session
    var id: Session.ID { session.id }
}

/// One session blocked on the user in a workspace the sidebar is not showing,
/// lifted into the working set with the name of the scope it lives in.
private struct WaitingElsewhereEntry: Identifiable {
    let workspaceName: String
    let session: Session
    var id: Session.ID { session.id }
}

/// A muted top-level *section* header — the tier above project folders. Used for the
/// two special groupings, Terminals and Pinned: a small leading SF Symbol in the same
/// icon column as the rows below, plus an uppercase, tracked, grey label. Collapsible
/// (tap the row), with an optional right-click menu (Terminals' New/Close actions).
/// Deliberately distinct from `ProjectHeader` so a section never reads as a folder.
private struct SidebarSectionHeader: View {
    @EnvironmentObject var settings: AppSettings
    let title: String
    let chrome: ChromeTheme?
    var isCollapsed: Bool = false
    /// The first section has no group above it to separate from, so it drops the
    /// separator padding and pins its label to the very top of the scroll content —
    /// otherwise the column reads as starting late, below where the scroller begins.
    var isFirstSection: Bool = false
    var toggleCollapsed: () -> Void = {}
    var menuItems: [SidebarMenuItem] = []
    @State private var isMenuOpen = false

    var body: some View {
        HStack(spacing: 5) {
            // No leading glyph: the rows below already carry a column of icons, so a
            // section icon on top of that just reads as clutter. The label alone — same
            // interface font as the rows (size + family), set apart only by uppercase +
            // tracking + a heavier semibold weight — is the section marker.
            Text(title)
                .font(settings.interfaceFont)
                .fontWeight(.semibold)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            // Disclosure arrow right after the label: a Hugeicons chevron pointing right
            // when the section is folded, rotated a quarter-turn down when it's open.
            HugeIconView(icon: .chevronRight, size: 7.5, color: .secondary, lineWidthOverride: 1.75)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .animation(.easeInOut(duration: 0.18), value: isCollapsed)
            Spacer(minLength: 4)
        }
        // Generous top padding is the separator between sections — whitespace, not a
        // rule — so each group reads as its own block without a hairline. It lives in
        // the row, not in the list's `contentMargins`: a scroll-content inset is
        // recomputed whenever the split view relayouts the sidebar, so toggling the
        // inspector dropped it for a frame and the rows jumped. Padding inside a row
        // cannot be recomputed.
        .padding(.top, isFirstSection ? 0 : 12)
        .padding(.bottom, 2)
        // Dropping the padding alone doesn't lift the first label: a `.sidebar` list
        // floors every row at 32pt, and a header's content is barely half that, so the
        // row keeps its height and just re-centers the label inside it. The two lines
        // below take that reclaimed space instead of leaving it above the text —
        // top-alignment pins the label to the row's top edge, and zeroed row insets
        // drop the 4pt SwiftUI reserves there. Horizontal insets come from the table's
        // own cell indent, not from here, so zeroing these keeps the left baseline the
        // rows share.
        .frame(maxHeight: isFirstSection ? .infinity : nil, alignment: .top)
        .listRowInsets(isFirstSection ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0) : nil)
        // No `listRowInsets` override — the header keeps the rows' default inset so both
        // share one left baseline, and the same trim as a top-level row (`leadingIndent`
        // 0) puts the label's left edge on the folder/terminal glyph's. A 15pt glyph in
        // its 16pt slot leaves no inset to compensate for, so any extra leading here
        // pushes the section labels off the column the rows below them establish.
        .padding(.leading, -sidebarLeadingTrim)
        .contentShape(Rectangle())
        .onTapGesture { toggleCollapsed() }
        .background {
            // Only sections that offer actions (Terminals) get a right-click menu; the
            // Pinned label has none, so it stays a passive divider.
            if !menuItems.isEmpty {
                SidebarRowContextMenu(items: { menuItems }) { isMenuOpen = $0 }
            }
        }
        .background(OutlineViewFixups())
        .listRowBackground(
            SidebarRowHighlight(isSelected: false, isHovering: isMenuOpen, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isMenuOpen)
        )
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    /// A row drag's state, on its own object so that a drag redraws the sidebar and only
    /// the sidebar (`TermioStore.sidebarDrag`).
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    // The terminal theme is split light/dark and libghostty tracks the system
    // appearance; the chrome borrows whichever side is currently showing.
    @Environment(\.colorScheme) private var colorScheme
    // Which projects are folded shut. Held here, not in ProjectHeader, because the
    // header and the session rows are siblings — only the parent can both toggle the
    // fold and omit the collapsed project's rows.
    @State private var collapsedProjects: Set<Project.ID> = []
    @State private var collapsedWorktrees: Set<Worktree.ID> = []
    @State private var pinnedCollapsed = false
    @State private var projectsCollapsed = false
    @State private var terminalsCollapsed = false
    @State private var chatsCollapsed = false

    // Chrome colors borrowed from the selected terminal theme; `nil` keeps the
    // default system look untouched.
    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        // Selection is driven by a *simultaneous* tap on each session row (see
        // `SessionRow`), never by List's `selection:` binding: with `.onDrag` mounted
        // on the rows, NSTableView's native click-to-select doesn't commit until
        // seconds later (the drag machinery swallows the mouseDown) — that shipped as
        // v0.19.0's dead sidebar clicks. The store stays the single source of
        // selection truth and `SidebarRowHighlight` its only visual cue.
        // A flat list rather than `Section`s: the sidebar's section spacing leaves
        // a big empty band between a collapsed project's header and the next, and
        // macOS has no `listSectionSpacing`. So the pinned grouping is hand-rolled
        // too — our own quiet "Pinned" label + a hairline — keeping folded rows tight.
        //
        // Row order: the "Pinned" working set first (above everything — the curated,
        // deliberately-elevated items); then the loose Terminals and Chats sections; then
        // the rest. A project's membership in the pinned group is itself the pin cue, so
        // pinned rows carry no per-row badge. Both groups keep the user's chosen sort
        // (already applied by `orderedProjects`, which we only partition here — never reorder).
        //
        // The sidebar shows one WORKSPACE, and `store.currentWorkspace` says which.
        // A workspace spans machines: a project row's session that runs on a VPS
        // draws here, beside its siblings, wearing that machine's mark — the device
        // is a property of the row now, not a filter over the column.
        let workspace = store.currentWorkspace
        let ordered = store.orderedProjects
        let pinnedProjects = ordered.filter(\.pinned)
        let others = ordered.filter { !$0.pinned }
        // Pinned worktrees are gathered only from *unpinned* projects: a pinned project
        // already renders the worktree inside its own block, so listing it again in the
        // working set would double it.
        let pinnedWorktrees: [PinnedWorktreeEntry] = others.flatMap { project in
            project.worktrees.filter(\.pinned).map { PinnedWorktreeEntry(project: project, worktree: $0) }
        }
        let pinnedWorktreePaths = Set(pinnedWorktrees.map { $0.worktree.path })
        // Pinned sessions, minus any already shown inside a pinned ancestor (their
        // project — excluded above by iterating `others` — or a pinned worktree of it),
        // so the working set never shows the same session twice.
        var pinnedSessions: [PinnedSessionEntry] = others.flatMap { project in
            project.sessions.filter { session in
                guard session.pinned else { return false }
                if let wp = session.worktreePath, pinnedWorktreePaths.contains(wp) { return false }
                return true
            }.map { PinnedSessionEntry(project: project, session: $0) }
        }
        pinnedSessions += (workspace.terminals + workspace.chats)
            .filter(\.pinned)
            .map { PinnedSessionEntry(project: nil, session: $0) }
        // Agents blocked on the user in *other* workspaces, lifted into the working
        // set. The scope bounds the panes — terminal, files, git, issues — and never
        // the needs-you surface: an agent waiting on an answer that the user cannot
        // see because they are in a different workspace is the one failure this
        // feature must not introduce. They carry their workspace's name as the
        // breadcrumb, so the row says where clicking will take you.
        let waitingElsewhere = elsewhereNeedingYou(currentWorkspace: workspace.id)
        // Whether any row in this column wears a machine mark. Suppressed only
        // where the band above the column already answers it: a workspace Termio
        // named after a box repeats that one fact down every row. A workspace the
        // *user* named keeps its marks however remote it is — "Ship auth" names no
        // machine, so the rows are the only thing that can. Decided here, once,
        // and handed to the rows.
        let bandNamesTheMachine = workspace.isAutoCreated == true && !workspace.device.isThisMac
        let marksDevice = !bandNamesTheMachine
        let hasPinned = !pinnedProjects.isEmpty || !pinnedWorktrees.isEmpty
            || !pinnedSessions.isEmpty || !waitingElsewhere.isEmpty
        let hasTerminals = !workspace.terminals.isEmpty
        let hasChats = !workspace.chats.isEmpty
        return List {
            // Nudge when agents are running but the status hooks are off — without them
            // the sidebar spinner stays dark. One tap enables (and reinstalls) them.
            if !settings.agentHooksEnabled && store.isRunningAnyAgent {
                AgentHooksOffBanner { settings.agentHooksEnabled = true }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            // The top "Pinned" working set, under its own section header: pinned projects
            // as full blocks, then pinned worktrees as mini-blocks (header + their
            // sessions), then pinned sessions as shortcut rows — each nested entry tagged
            // with its origin breadcrumb. Nested items stay in the tree below too; only
            // whole projects move up here. This curated working set sits at the very top —
            // above the ephemeral Terminals/Chats sections — because it's the items the user
            // deliberately elevated (mirroring the iOS "Needs You" strip at the home top).
            if hasPinned {
                SidebarSectionHeader(
                    title: localized("Pinned"),
                    chrome: chrome,
                    isCollapsed: pinnedCollapsed,
                    isFirstSection: true,
                    toggleCollapsed: {
                        withAnimation(.easeInOut(duration: 0.18)) { pinnedCollapsed.toggle() }
                    }
                )
                if !pinnedCollapsed {
                    ForEach(waitingElsewhere) { entry in
                        SessionRow(session: entry.session, chrome: chrome, leadingIndent: 16,
                                   breadcrumb: entry.workspaceName, marksDevice: marksDevice)
                    }
                    ForEach(pinnedProjects) { projectBlock($0, marksDevice: marksDevice) }
                    ForEach(pinnedWorktrees) { entry in
                        pinnedWorktreeBlock(project: entry.project, worktree: entry.worktree,
                                            marksDevice: marksDevice)
                    }
                    ForEach(pinnedSessions) { entry in
                        SessionRow(session: entry.session, chrome: chrome, leadingIndent: 16,
                                   breadcrumb: entry.project.map { breadcrumb(for: entry.session, in: $0) },
                                   marksDevice: marksDevice)
                    }
                }
            }
            // The workspace's loose shells, as a section (not a project folder): its
            // header carries the New/Close actions; its sessions render below. Hidden
            // entirely while it holds no terminals — an empty section label is just
            // noise (a new loose terminal reappears the section, via the + / File menu).
            if hasTerminals {
                SidebarSectionHeader(
                    title: localized("Terminals"),
                    chrome: chrome,
                    isCollapsed: terminalsCollapsed,
                    isFirstSection: !hasPinned,
                    toggleCollapsed: {
                        withAnimation(.easeInOut(duration: 0.18)) { terminalsCollapsed.toggle() }
                    },
                    menuItems: terminalsMenuItems(store: store, workspace: workspace.id)
                )
                if !terminalsCollapsed {
                    let terminals = store.sidebarOrder(workspace.terminals)
                    let marks = splitLinkMarks(for: terminals)
                    ForEach(terminals) { session in
                        SessionRow(session: session, chrome: chrome, splitLink: marks[session.id],
                                   marksDevice: marksDevice)
                    }
                }
            }
            // The workspace's loose agent sessions — the agent-side twin of Terminals,
            // paired directly above Projects (the "Chats vs Projects" split: one-off
            // agent sessions vs. real folder-scoped work). They spawn in the scoped
            // scratch directory (`~/.termio/chats`); the header offers a single "New
            // Chat" (the default agent — see `addDefaultChat`) plus a Close All,
            // mirroring the Terminals header's "New Terminal". Hidden while empty.
            if hasChats {
                SidebarSectionHeader(
                    title: localized("Chats"),
                    chrome: chrome,
                    isCollapsed: chatsCollapsed,
                    isFirstSection: !hasPinned && !hasTerminals,
                    toggleCollapsed: {
                        withAnimation(.easeInOut(duration: 0.18)) { chatsCollapsed.toggle() }
                    },
                    menuItems: chatsMenuItems(store: store, workspace: workspace.id)
                )
                if !chatsCollapsed {
                    let chats = store.sidebarOrder(workspace.chats)
                    let marks = splitLinkMarks(for: chats)
                    ForEach(chats) { session in
                        SessionRow(session: session, chrome: chrome, splitLink: marks[session.id],
                                   marksDevice: marksDevice)
                    }
                }
            }
            // The user's opened projects, under their own section header — the same
            // section treatment as Terminals and Pinned, one tier above the folder rows.
            if !others.isEmpty {
                SidebarSectionHeader(
                    title: localized("Projects"),
                    chrome: chrome,
                    isCollapsed: projectsCollapsed,
                    isFirstSection: !hasPinned && !hasTerminals && !hasChats,
                    toggleCollapsed: {
                        withAnimation(.easeInOut(duration: 0.18)) { projectsCollapsed.toggle() }
                    }
                )
                if !projectsCollapsed {
                    ForEach(others) { projectBlock($0, marksDevice: marksDevice) }
                }
            }
            // A session the device reports that no row accounts for gets a row
            // of its own automatically (`reconcileExternalSessions`) — there is
            // no second list to learn. The "Also Running" section that used to
            // sit here is gone with #528.

            // The breathing room under the last row, as a row rather than the list's
            // `contentMargins`. SwiftUI re-applies scroll-content margins to the
            // NSScrollView on every list update, and each `setContentInsets` re-tiles
            // the scroll view, which clamps the clip view back into range: at either
            // end the rubber band was yanked back thirty times a second, and the
            // column shook with the rows drawn at two offsets.
            Color.clear
                .frame(height: 12)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityHidden(true)
        }
        // The `.sidebar` source list's rows and insets, over the material the column paints
        // (`SidebarMaterialController`), so the list draws no background of its own.
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .overlay { SidebarDragOverlay() }
        // Under the rows' own drop targets: a session dragged over blank space, a header or
        // the gap between projects still lands in the gap the rows opened, instead of being
        // refused and sliding back.
        .onDrop(of: [.text], delegate: SidebarListDropDelegate(store: store))
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    }

    /// Agents blocked on the user outside the workspace on screen. Sorted by the
    /// order they appear in the tree so the list is stable between renders.
    private func elsewhereNeedingYou(currentWorkspace: Workspace.ID) -> [WaitingElsewhereEntry] {
        store.workspaces.filter { $0.id != currentWorkspace }.flatMap { workspace in
            let loose = workspace.looseSessions
            let filed = store.projects
                .filter { $0.workspaceID == workspace.id }
                .flatMap(\.sessions)
            return (loose + filed)
                .filter { store.status(for: $0.id) == .needsAttention }
                .map { WaitingElsewhereEntry(workspaceName: workspace.name, session: $0) }
        }
    }

    /// One project's rows: its header, then (unless folded) its primary-checkout
    /// sessions and each worktree's nested header + sessions. Factored out of `body`
    /// so the pinned and unpinned groups render identical project blocks.
    @ViewBuilder
    private func projectBlock(_ project: Project, marksDevice: Bool) -> some View {
        ProjectHeader(
            project: project,
            isCollapsed: collapsedProjects.contains(project.id),
            toggleCollapsed: { toggleCollapsed(project.id) },
            chrome: chrome
        )
        if !collapsedProjects.contains(project.id) {
            let primarySessions = store.sidebarOrder(primarySessions(for: project))
            let primarySplitMarks = splitLinkMarks(for: primarySessions)
            ForEach(primarySessions) { session in
                SessionRow(session: session, chrome: chrome,
                           splitLink: primarySplitMarks[session.id], marksDevice: marksDevice)
            }
            ForEach(project.worktrees) { worktree in
                ProjectHeader(
                    project: project,
                    worktree: worktree,
                    isCollapsed: collapsedWorktrees.contains(worktree.id),
                    toggleCollapsed: { toggleWorktreeCollapsed(worktree.id) },
                    chrome: chrome,
                    leadingIndent: 16
                )
                if !collapsedWorktrees.contains(worktree.id) {
                    let sessions = store.sidebarOrder(project.sessions.filter {
                        $0.worktreePath == worktree.path && store.isOnCurrentDevice($0)
                    })
                    let splitMarks = splitLinkMarks(for: sessions)
                    ForEach(sessions) { session in
                        SessionRow(
                            session: session,
                            chrome: chrome,
                            leadingIndent: 32,
                            splitLink: splitMarks[session.id],
                            marksDevice: marksDevice
                        )
                    }
                }
            }
        }
    }

    /// A pinned worktree lifted into the top working set: its header (tagged with the
    /// parent project's name) plus, unless folded, its own sessions. Sits at the base
    /// indent since it's a top-level working-set entry, not nested under a project row.
    @ViewBuilder
    private func pinnedWorktreeBlock(project: Project, worktree: Worktree,
                                     marksDevice: Bool) -> some View {
        ProjectHeader(
            project: project,
            worktree: worktree,
            isCollapsed: collapsedWorktrees.contains(worktree.id),
            toggleCollapsed: { toggleWorktreeCollapsed(worktree.id) },
            chrome: chrome,
            leadingIndent: 0,
            breadcrumb: project.name
        )
        if !collapsedWorktrees.contains(worktree.id) {
            let sessions = store.sidebarOrder(project.sessions.filter { $0.worktreePath == worktree.path })
            let splitMarks = splitLinkMarks(for: sessions)
            ForEach(sessions) { session in
                SessionRow(session: session, chrome: chrome, leadingIndent: 16,
                           splitLink: splitMarks[session.id], marksDevice: marksDevice)
            }
        }
    }

    /// The origin trail for a pinned session shortcut: the project name, or
    /// "project/branch" when the session lives in one of the project's worktrees.
    private func breadcrumb(for session: Session, in project: Project) -> String {
        if let wp = session.worktreePath, wp != project.path,
           let worktree = project.worktrees.first(where: { $0.path == wp }) {
            let branch = store.branch(forFolder: worktree.path)
                ?? (worktree.path as NSString).lastPathComponent
            return "\(project.name)/\(branch)"
        }
        return project.name
    }

    private func toggleCollapsed(_ id: Project.ID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if collapsedProjects.contains(id) {
                collapsedProjects.remove(id)
            } else {
                collapsedProjects.insert(id)
            }
        }
    }

    private func toggleWorktreeCollapsed(_ id: Worktree.ID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if collapsedWorktrees.contains(id) {
                collapsedWorktrees.remove(id)
            } else {
                collapsedWorktrees.insert(id)
            }
        }
    }

    /// With no stored worktree containers the existing flat session list is kept
    /// verbatim. Once the folder layer exists, only sessions anchored to the primary
    /// checkout remain shallow.
    private func primarySessions(for project: Project) -> [Session] {
        // Every session the project owns, whichever machine it runs on. A session
        // opened from this row with "New Terminal ▸ <device>" belongs to the row
        // that opened it; the device mark on the row is what says it is elsewhere.
        let sessions = project.sessions
        guard !project.worktrees.isEmpty else { return sessions }
        return sessions.filter {
            $0.worktreePath == nil || $0.worktreePath == project.path
        }
    }

    /// Which sessions of `project` get a split-group bracket, and which segment of
    /// it (VS Code's ┌/├/└ decoration on grouped terminal tabs). Every split group
    /// gets its bracket — visible on screen or not — because groups are persistent:
    /// the bracket is what tells you which sessions will come up together when you
    /// select one of them. A bracket joins a *run* of adjacent same-group rows —
    /// `splitSelectedPane` inserts its companion right below the session it splits,
    /// so groups always start out as such runs. A member whose row sits alone
    /// (its group mates live in another project) gets no bracket: a floating
    /// corner with nothing to connect to would just be noise.
    private func splitLinkMarks(for sessions: [Session]) -> [Session.ID: SplitLinkMark] {
        let joining = store.draggingSessionID.flatMap { moved in
            sidebarDrag.groupTarget.map { (moved: moved, target: $0) }
        }
        guard !store.splitGroups.isEmpty || joining != nil else { return [:] }
        var groupOf: [Session.ID: Int] = [:]
        for (index, group) in store.splitGroups.enumerated() {
            for id in group.leafIDs { groupOf[id] = index }
        }
        // A held drag that armed draws the bracket it will make, joining the gap under the
        // target to the target's group, or to a new one.
        if let joining {
            let group = groupOf[joining.target] ?? store.splitGroups.count
            groupOf[joining.target] = group
            groupOf[joining.moved] = group
        }
        var marks: [Session.ID: SplitLinkMark] = [:]
        var run: [Session.ID] = []
        var runGroup: Int?
        func closeRun() {
            if run.count > 1, let first = run.first, let last = run.last {
                marks[first] = .top
                for id in run.dropFirst().dropLast() { marks[id] = .middle }
                marks[last] = .bottom
            }
            run.removeAll()
        }
        for session in sessions {
            let group = groupOf[session.id]
            // Two different groups' rows may touch; the bracket must not fuse them.
            if group != runGroup { closeRun() }
            runGroup = group
            if group != nil { run.append(session.id) }
        }
        closeRun()
        return marks
    }
}

/// A session row's segment of the split-group bracket: the corner opening the
/// group, a tee continuing it, or the corner closing it.
enum SplitLinkMark {
    case top, middle, bottom
}

/// The bracket segment itself, drawn as a hairline path down the row's leading
/// gutter — a vertical spine toward the neighbouring group members plus a short
/// tick pointing at this row's icon. Drawn (not the ┌ text glyph VS Code uses)
/// so consecutive rows meet the row boundary exactly and the spine reads as one
/// continuous bracket.
private struct SplitLinkGlyph: View {
    let mark: SplitLinkMark
    let chrome: ChromeTheme?
    /// Brightened while a member of this group is being dragged.
    var isMarked: Bool = false

    private static let cornerRadius: CGFloat = 3.5

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let x = geo.size.width * 0.5
                let midY = geo.size.height / 2
                let top = CGPoint(x: x, y: 0)
                let mid = CGPoint(x: x, y: midY)
                let bottom = CGPoint(x: x, y: geo.size.height)
                let tick = CGPoint(x: x + 5, y: midY)
                // The bracket's ends turn into their ticks on a small radius, the way the
                // corners of a macOS outline's disclosure lines and grouped-row insets
                // round, rather than meeting at a right angle.
                switch mark {
                case .top:
                    path.move(to: tick)
                    path.addArc(tangent1End: mid, tangent2End: bottom, radius: Self.cornerRadius)
                    path.addLine(to: bottom)
                case .middle:
                    path.move(to: top); path.addLine(to: bottom)
                    path.move(to: mid); path.addLine(to: tick)
                case .bottom:
                    path.move(to: top)
                    path.addArc(tangent1End: mid, tangent2End: tick, radius: Self.cornerRadius)
                    path.addLine(to: tick)
                }
            }
            .stroke(lineWidth: 1)
            .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground.opacity(isMarked ? 0.9 : 0.35)) }
                ?? AnyShapeStyle(isMarked ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
            .animation(.easeInOut(duration: 0.12), value: isMarked)
        }
    }
}


/// The shared folder-container header for a project or one of its worktrees. The
/// target path changes, but its collapse gesture, quick-add cluster, hover treatment,
/// and context-menu plumbing stay one component.
private struct ProjectHeader: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    let project: Project
    var worktree: Worktree? = nil
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    let chrome: ChromeTheme?
    var leadingIndent: CGFloat = 0
    /// When shown as a pinned worktree mini-block in the top "Pinned" working set, the
    /// muted origin trail (the parent project's name). `nil` in the normal tree spot.
    var breadcrumb: String? = nil
    @State private var isHovering = false
    /// True while this header's right-click menu is open, so the row paints a light
    /// lift marking it as the menu's target.
    @State private var isMenuOpen = false

    private var targetPath: String {
        worktree?.path ?? project.path
    }

    private var headerLabel: String {
        guard let worktree else { return project.name }
        let fallback = (worktree.path as NSString).lastPathComponent
        guard !store.isDetachedHead(forFolder: worktree.path) else { return fallback }
        return store.branch(forFolder: worktree.path) ?? fallback
    }

    private var headerHelp: String {
        guard let worktree,
              store.isDetachedHead(forFolder: worktree.path),
              let commit = store.branch(forFolder: worktree.path)
        else { return targetPath }
        return localized("Detached at \(commit)")
    }

    /// Every folder container — project or worktree — swaps closed/open folders as its
    /// collapse cue; the Terminals section keeps its own terminal glyph. A worktree's
    /// git-linkage is marked by a trailing branch glyph on the row (below), not a
    /// distinct folder icon: a git node baked into the folder glyph was illegible at
    /// sidebar size, and a plain folder keeps the two header kinds visually one family.
    private var headerIcon: HugeIcon {
        isCollapsed ? .folder : .folderOpen
    }

    /// The machine this project's checkout lives on, when that is not this Mac.
    /// It is the machine of the workspace the project is filed under — a checkout
    /// records none of its own. `nil` in a workspace Termio named after a box, for
    /// the same reason a session row's mark is: the name in the band above the
    /// column already says it.
    private var remoteDevice: KnownDevice? {
        guard let workspace = store.workspace(owning: project),
              workspace.isAutoCreated != true
        else { return nil }
        return workspace.knownDevice
    }

    /// Adding a session to a project on another machine means adding it *there* —
    /// `TermioStore.addSession` routes to the remote path itself, so this row's
    /// verbs read the same wherever the checkout lives.
    private func addSession(_ preset: AgentPreset) {
        store.addSession(to: project.id, agent: preset, worktreePath: worktree?.path)
    }

    /// Whether this row has somewhere to start a session. A worktree git still
    /// registers but whose checkout is gone has not: the path would reach the
    /// daemon as a working directory that does not exist, and the session would
    /// open somewhere nobody asked for. The row itself stays, because removing it
    /// is what the user still needs to reach.
    private var canStartSession: Bool {
        worktree?.missing != true
    }

    /// What the hover cluster and the agents submenu offer — the same presets
    /// wherever the project lives, since the far daemon launches agents too.
    private var headerPresets: [AgentPreset] {
        headerSessionPresets(settings)
    }

    /// Width the trailing quick-add icons occupy (button frame 22 + 3 spacing each), so
    /// the hovered label can fade out exactly under them rather than guessing.
    private var quickAddClusterWidth: CGFloat {
        let count = headerPresets.count
        guard count > 0 else { return 0 }
        return CGFloat(count) * 22 + CGFloat(count - 1) * 3
    }

    private var menuItems: [SidebarMenuItem] {
        projectMenuItems(store: store, settings: settings, project: project, worktree: worktree)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Same 16-wide icon slot and spacing as SessionRow, so the container mark
            // and child icons share a column. A project and a worktree are both folder
            // containers, so they carry the same folder glyph (closed/open on collapse);
            // a worktree's git-linkage is marked by the trailing branch glyph, not a
            // different folder. Terminals keeps its own terminal glyph.
            HugeIconView(
                // Match the session row's icon size: with `HugeIconShape` normalizing
                // every mark to one ink width, an equal `size` makes the folder header
                // and the child terminal icons render at the same width down the shared
                // 16-wide column.
                icon: headerIcon,
                size: 15,
                color: chrome?.foreground ?? .primary
            )
            .frame(width: 16)
            // A folder container header, at the standard text color and the same size
            // and regular weight as its child session rows (both track the interface
            // font, so they scale together). The container reads as the parent of its
            // rows through the folder glyph and indent, not by weight or size. Both
            // header kinds show their name verbatim, no uppercasing — load-bearing for
            // worktrees, whose label is a live *branch name*: git refs are case-sensitive,
            // lowercase by convention, and copy-pasteable into `git checkout`, so
            // uppercasing would display a name the user can't type.
            Text(headerLabel)
                .font(settings.interfaceFont)
                .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary))
                .help(headerHelp)
            // The origin trail on a pinned worktree's mini-block in the top working set,
            // so the lifted worktree still says which project it belongs to. Muted.
            if let breadcrumb {
                Text("· \(breadcrumb)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            // A worktree's git-linkage marker, pinned to the row's right edge — its
            // folder glyph now matches a plain project's, so this branch symbol is what
            // marks the row as a git worktree (and echoes that its label is a live branch
            // name). A project's pinned state carries no per-row badge: sitting under the
            // "Pinned" group label is the cue. Muted, so it reads as quiet metadata; on
            // hover it falls under the quick-add cluster (masked out with the label tail).
            if worktree != nil {
                HugeIconView(icon: .gitBranch, size: 10, color: .secondary)
                    .help(localized("Git worktree"))
            }
            // The machine the checkout lives on, when that is not this Mac — the
            // same mark a session row carries, because it says the same thing
            // about the same machine. A local project carries nothing: being on
            // your own Mac is the absence of a mark.
            if let device = remoteDevice {
                DeviceMarkView(
                    mark: DeviceMark.mark(
                        for: device, current: store.currentDevice, state: store.deviceSessions),
                    name: device.name)
            }
        }
        // On hover the trailing icons would otherwise sit on top of a long project
        // name (the label takes the whole row at rest), so the name's tail reads as a
        // muddle behind the half-transparent glyphs. Fade the label out exactly under
        // the icon cluster instead — a short gradient dissolves the text into the
        // buttons, with no collision and no seam. The sidebar is a translucent Liquid
        // Glass material, so masking the label (not painting an opaque plate) is the
        // only scrim that matches the background. Mask sits on the HStack only; the
        // icon overlay below is added afterwards, so the icons stay fully opaque. The
        // clear/gradient widths collapse to zero off-hover, so the row is untouched at
        // rest.
        .mask(
            HStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: isHovering ? 18 : 0)
                Color.clear.frame(width: isHovering ? quickAddClusterWidth + 6 : 0)
            }
        )
        // The hover actions sit in an overlay, not the HStack above, so they reserve
        // no width while hidden — the label keeps the whole row at rest. One brand
        // icon per enabled session kind (including Terminal). The container's rarer
        // lifecycle actions live in the right-click menu rather than inline.
        .overlay(alignment: .trailing) {
            HStack(spacing: 3) {
                ForEach(canStartSession ? headerPresets : []) { preset in
                    AgentQuickAddButton(preset: preset, chrome: chrome) {
                        addSession(preset)
                    }
                }
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .padding(.vertical, 3)
        .padding(.leading, leadingIndent - sidebarLeadingTrim)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { toggleCollapsed() }
        // Right-click mirrors the hover controls, so every action is reachable both
        // ways. Built as an `NSMenu` (see `SidebarRowContextMenu`) rather than
        // SwiftUI's `.contextMenu`, which paints an un-styleable blue accent ring
        // around the targeted row. While the menu is up the row lifts to the hover
        // level (a step below session selection) so the target reads clearly.
        .background(SidebarRowContextMenu(items: { menuItems }) { isMenuOpen = $0 })
        // Strip the source list's native blue accent (the ring/fill AppKit paints on a
        // right-clicked or selected row) at the NSOutlineView layer, so our own
        // highlights are the only selection cue — same treatment the file tree uses.
        .background(OutlineViewFixups())
        .listRowBackground(
            SidebarRowHighlight(isSelected: false, isHovering: isMenuOpen, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isMenuOpen)
        )
        // Hover snaps (see the session row): the quick-add cluster and the label
        // mask appear and go on the frame the pointer arrives and leaves.
        .animation(nil, value: isHovering)
        .animation(.easeInOut(duration: 0.18), value: isCollapsed)
    }
}

@MainActor
func enabledAgentPresets(_ settings: AppSettings) -> [AgentPreset] {
    settings.orderedAgents(AgentPreset.allCases.filter(settings.isAgentEnabled))
}

/// A project-like header always offers a shell, followed by each coding agent the
/// user has left enabled. Terminal is infrastructure rather than a disable-able
/// agent choice here.
@MainActor
func headerSessionPresets(_ settings: AppSettings) -> [AgentPreset] {
    [.terminal] + enabledAgentPresets(settings).filter { $0 != .terminal }
}

/// The Terminals section's right-click menu, wherever the section is listed.
@MainActor
func terminalsMenuItems(store: TermioStore, workspace: Workspace.ID) -> [SidebarMenuItem] {
    [
        newTerminalMenuItem(store: store) { store.addScratchSession(agent: .terminal) },
        .separator,
        .action(localized("Close All Terminals")) {
            store.closeLooseSessions(inWorkspace: workspace, chats: false)
        },
    ]
}

/// The Chats section's right-click menu, wherever the section is listed.
@MainActor
func chatsMenuItems(store: TermioStore, workspace: Workspace.ID) -> [SidebarMenuItem] {
    [
        .action(localized("New Chat")) { store.addDefaultChat() },
        .separator,
        .action(localized("Close All Chats")) {
            store.closeLooseSessions(inWorkspace: workspace, chats: true)
        },
    ]
}

/// The right-click menu of a project, or of one of its worktrees: New Terminal, a
/// "New Agent Session ▸" submenu with one row per enabled agent (the same row shape
/// as File ▸ New Chat), then the project's own actions. Mirrors the header's hover
/// controls so both routes stay in sync. The Terminals section is not a folder
/// project — agents don't belong in `$HOME` (they get a real project or the scoped
/// scratch workspace), and worktree / Finder actions are about a project's
/// directory — so its menu is `terminalsMenuItems`.
@MainActor
func projectMenuItems(store: TermioStore, settings: AppSettings, project: Project,
                      worktree: Worktree? = nil) -> [SidebarMenuItem] {
    // `TermioStore.addSession` routes a project on another machine to the remote
    // path itself, so the verbs read the same wherever the checkout lives.
    let addSession: (AgentPreset) -> Void = { preset in
        store.addSession(to: project.id, agent: preset, worktreePath: worktree?.path)
    }
    // A project on another machine has one place its sessions can run, so the
    // verb names it outright instead of offering a device submenu whose rows
    // would all be wrong but one. Every verb that reads this Mac's disk is absent
    // rather than disabled — New Worktree, Clone to (the folder to clone from
    // isn't here), Reveal in Finder — because there is nothing on this Mac for
    // them to act on. Filing and removal are bookkeeping about the row, so they stay.
    if store.isOnAnotherDevice(project) {
        var items: [SidebarMenuItem] = [
            .action(localized("New Terminal")) { addSession(.terminal) },
            .submenu(localized("New Agent Session"), enabledAgentPresets(settings)
                .filter { $0 != .terminal }
                .map { preset in .agent(preset) { addSession(preset) } }),
            .separator,
            .action(project.pinned ? localized("Unpin") : localized("Pin to Top")) {
                store.togglePinned(project.id)
            },
        ]
        if let move = moveToWorkspaceMenuItem(store: store, project: project) {
            items.append(move)
        }
        items.append(.action(localized("Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        })
        items.append(.separator)
        items.append(.action(localized("Remove Project")) { store.removeProject(project.id) })
        return items
    }
    // A worktree git still registers but whose checkout is gone has nowhere to
    // start a session: the path would reach the daemon as a working directory
    // that does not exist. Removing it is what the user still needs to reach.
    var items: [SidebarMenuItem] = worktree?.missing != true
        ? [
            newTerminalMenuItem(store: store, project: project) { addSession(.terminal) },
            .submenu(localized("New Agent Session"), enabledAgentPresets(settings)
                .filter { $0 != .terminal }
                .map { preset in .agent(preset) { addSession(preset) } }),
        ]
        : []
    if let worktree {
        // A separator only ever divides, so nothing adds one while the list is
        // still empty: a row with no session verbs would otherwise open its
        // menu on a rule with nothing above it.
        func divide() {
            if !items.isEmpty { items.append(.separator) }
        }
        if let cloneTo = cloneToDeviceMenuItem(
            store: store, folder: worktree.path, project: project.id) {
            divide()
            items.append(cloneTo)
        }
        divide()
        items.append(.action(worktree.pinned ? localized("Unpin") : localized("Pin")) {
            store.toggleWorktreePinned(worktree.id)
        })
        items.append(.action(localized("Reveal in Finder")) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
        })
        items.append(.separator)
        items.append(.action(localized("Remove Worktree")) {
            store.removeWorktree(worktree.id, from: project.id)
        })
        return items
    }
    // Create a fresh detached checkout nested under this project; the new
    // container's own quick-add controls fill it with sessions on demand.
    // Only for git repositories (a worktree needs one; "—" marks a non-repo folder).
    if project.branch != "—" {
        items.append(.action(localized("New Worktree")) { store.addWorktree(from: project.id) })
        if let cloneTo = cloneToDeviceMenuItem(
            store: store, folder: project.path, project: project.id) {
            items.append(cloneTo)
        }
    }
    items.append(.separator)
    items.append(.action(project.pinned ? localized("Unpin") : localized("Pin to Top")) {
        store.togglePinned(project.id)
    })
    // Filing is what a workspace is for, so a project can be moved into
    // another one. Absent with a single workspace — there is nowhere to move to.
    if let move = moveToWorkspaceMenuItem(store: store, project: project) {
        items.append(move)
    }
    items.append(.action(localized("Reveal in Finder")) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
    })
    items.append(.separator)
    items.append(.action(localized("Remove Project")) { store.removeProject(project.id) })
    return items
}

/// A session's right-click menu, on its sidebar row or on its tab.
@MainActor
func sessionMenuItems(store: TermioStore, session: Session) -> [SidebarMenuItem] {
    var items: [SidebarMenuItem] = [
        .action(localized("Open in New Window")) {
            (NSApp.delegate as? AppDelegate)?.openWindow(selecting: session.id)
        },
        .separator,
        .action(localized("Rename…")) { store.renameSession(session.id) },
        .action(localized("Copy Session Link")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(store.sessionLink(for: session), forType: .string)
        },
    ]
    let targets = store.groupableTargets(for: session.id)
    if store.isInSplitGroup(session.id) || !targets.isEmpty { items.append(.separator) }
    if store.isInSplitGroup(session.id) {
        items.append(.action(localized("Ungroup")) { store.detachFromSplit(session.id) })
    }
    if !targets.isEmpty {
        items.append(.submenu(localized("Group with"), targets.map { target in
            .action(store.displayTitle(for: target)) {
                store.groupSession(session.id, with: target.id)
            }
        }))
    }
    items.append(contentsOf: [
        .separator,
        .action(session.pinned ? localized("Unpin") : localized("Pin")) { store.toggleSessionPinned(session.id) },
        .separator,
        .action(localized("Close Session")) { store.requestCloseSession(session.id) },
    ])
    return items
}

/// Builds an `NSMenu` from a sidebar menu spec, recursing for submenus. Each item
/// carries its own closure, so the menu needs no target kept alive beside it.
@MainActor
func sidebarMenu(_ items: [SidebarMenuItem]) -> NSMenu {
    let menu = NSMenu()
    for item in items {
        switch item {
        case .separator:
            menu.addItem(.separator())
        case let .disabled(title):
            // A nil action leaves the item greyed out and un-clickable.
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = false
            menu.addItem(menuItem)
        case let .action(title, handler):
            menu.addItem(ClosureMenuItem(title: title, handler: handler))
        case let .agent(preset, handler):
            let menuItem = ClosureMenuItem(title: preset.displayName, handler: handler)
            menuItem.image = agentMenuImage(for: preset)
            menu.addItem(menuItem)
        case let .submenu(title, children):
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            // An empty submenu (e.g. nothing to group with) reads as a
            // disabled, un-openable parent rather than a dead-end click.
            menuItem.isEnabled = !children.isEmpty
            menuItem.submenu = children.isEmpty ? nil : sidebarMenu(children)
            menu.addItem(menuItem)
        }
    }
    return menu
}

/// One entry in a sidebar row's right-click menu — a titled action, an agent row
/// (display name plus brand icon, the File ▸ New Chat row shape), a titled
/// submenu of further entries, or a separator.
enum SidebarMenuItem {
    case action(String, @MainActor () -> Void)
    case agent(AgentPreset, @MainActor () -> Void)
    indirect case submenu(String, [SidebarMenuItem])
    /// A greyed-out, non-actionable row — used to explain an empty submenu inline
    /// (e.g. "No SSH hosts in ~/.ssh/config") rather than leaving a dead click.
    case disabled(String)
    case separator
}

/// A sidebar row's right-click menu, built as an AppKit `NSMenu` rather than
/// SwiftUI's `.contextMenu` — the latter rings the targeted row with an
/// un-styleable accent highlight (the blue border). A secondary-click recognizer on
/// the row's own view pops the menu, so nothing emphasizes the row. Mirrors the file
/// browser's `RowContextMenu`.
struct SidebarRowContextMenu: NSViewRepresentable {
    /// The menu's contents, built when it pops rather than when the row renders.
    /// A session row's menu asks the store real questions — which sessions this
    /// one could be grouped with, and what each of those is called — and a
    /// right-click is rare where a render is not, so the spec stays a closure the
    /// coordinator calls on demand.
    let items: () -> [SidebarMenuItem]
    /// Reports the menu opening (`true`) and closing (`false`) so the row can paint a
    /// light lift while its menu is up — the feedback the blue ring used to give,
    /// minus the ring.
    var onMenuState: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.owner = view
        context.coordinator.items = items
        context.coordinator.onMenuState = onMenuState
        context.coordinator.attach()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.items = items
        context.coordinator.onMenuState = onMenuState
        context.coordinator.attach()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        weak var owner: NSView?
        var items: () -> [SidebarMenuItem] = { [] }
        var onMenuState: (Bool) -> Void = { _ in }
        private weak var hostView: NSView?
        private var recognizer: NSClickGestureRecognizer?

        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner else { return }
                guard let host = Self.rowView(above: owner) else { return }
                if hostView === host, recognizer != nil { return }
                detach()
                let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.showMenu(_:)))
                recognizer.buttonMask = 0x2 // secondary (right) mouse button
                host.addGestureRecognizer(recognizer)
                self.recognizer = recognizer
                self.hostView = host
            }
        }

        func detach() {
            if let recognizer, let hostView { hostView.removeGestureRecognizer(recognizer) }
            recognizer = nil
            hostView = nil
        }

        @objc private func showMenu(_ recognizer: NSClickGestureRecognizer) {
            guard let hostView else { return }
            let menu = sidebarMenu(items())
            menu.delegate = self
            menu.popUp(positioning: nil, at: recognizer.location(in: hostView), in: hostView)
        }

        // NSMenuDelegate — surface the open/close so the row lifts while its menu is up.
        func menuWillOpen(_ menu: NSMenu) { onMenuState(true) }
        func menuDidClose(_ menu: NSMenu) { onMenuState(false) }

        private static func rowView(above view: NSView) -> NSView? {
            var ancestor = view.superview
            while let current = ancestor {
                if current is NSTableRowView { return current }
                ancestor = current.superview
            }
            return nil
        }
    }
}

/// One agent quick-add button in a project header. It carries its own hover state
/// so only the button under the cursor lifts a rounded background — the same
/// per-control feedback VSCode/Finder give their inline header actions. A single
/// click immediately creates a session of that agent type.
private struct AgentQuickAddButton: View {
    let preset: AgentPreset
    let chrome: ChromeTheme?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // The same glass tile as the session rows below, so a kind you can start looks like
            // the sessions it makes. Hover lights the tile's face, painted the frame the pointer
            // arrives.
            AgentIconView(agent: preset, size: 12)
                .frame(width: 20, height: 20)
                .background {
                    GlassTile()
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill((chrome?.foreground ?? .primary).opacity(isHovering ? 0.14 : 0)))
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressShrinkStyle())
        .onHover { isHovering = $0 }
        .help(localized("New \(preset.displayName) session"))
    }
}

/// The inline close action on a session row: a plain ✕ in the row's ink that lifts a faint disc
/// under the pointer (`CloseHoverDisc`), and shrinks a step on a press so the click registers.
private struct SessionRowCloseButton: View {
    let help: String
    let chrome: ChromeTheme?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HugeIconView(icon: .close, size: ChromeGlyph.size(for: .close),
                         color: chrome?.foreground ?? .secondary,
                         lineWidthOverride: ChromeGlyph.lineWidth())
                .frame(width: 22, height: 22)
                .background(CloseHoverDisc(isHovering: isHovering, ink: chrome?.foreground ?? .primary))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressShrinkStyle())
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct PressShrinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A session row. Hovering reveals a close button on the trailing edge (same
/// opacity-reveal pattern as the project header).
private struct SessionRow: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject private var window: WindowContext
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    let session: Session
    let chrome: ChromeTheme?
    /// Leading inset for the row's content. Sessions sit at 16 under a project, or a
    /// step deeper (32) when nested under a worktree folder node.
    var leadingIndent: CGFloat = 16
    /// This row's segment of the split-group bracket, or `nil` when the session
    /// isn't part of an adjacent run of on-screen panes (see `splitLinkMarks`).
    var splitLink: SplitLinkMark?
    /// When shown as a pinned shortcut in the top "Pinned" working set, the muted
    /// origin trail (e.g. "web-app" or "web-app/feat") that says where the real row
    /// lives. `nil` for a row in its normal tree spot.
    var breadcrumb: String? = nil
    /// Whether rows in this column carry a device mark at all. Answered once per
    /// render by the list (a machine's own workspace marks nothing), because the
    /// question is about the workspace on screen, not about this row — asking it
    /// per row scanned the workspaces once per row.
    var marksDevice: Bool = true
    @State private var isHovering = false

    /// How far the close button reaches past the row's content into the highlight's end.
    private static let closeButtonOutset: CGFloat = 6
    /// The room the title leaves for the close button on hover: the button, less the part
    /// past the content's edge, with the spacer's 4 points as the gap before it.
    private static let closeButtonReserve: CGFloat = 22 - closeButtonOutset

    /// Held over long enough that a release groups with it: drawn in the selected
    /// row's glass, the same material as the row in your hand.
    private var isDropTarget: Bool { sidebarDrag.groupTarget == session.id }
    /// In your hand, or easing into its slot: the slot stays as the gap the rows make
    /// room around, and the sidebar's floating copy draws the row.
    private var isLiftedOut: Bool {
        store.draggingSessionID == session.id || sidebarDrag.settling == session.id
    }
    private var isArming: Bool { sidebarDrag.arming == session.id }
    /// The full row's height and the content's, measured: the bracket spans the difference too.
    @State private var rowHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    /// A group the in-flight session belongs to reads brighter for the length of
    /// the drag, so the group a release would pull it out of is visible before you
    /// let go. Without it the only trace is the bracket moving afterwards.
    private var marksSourceGroup: Bool {
        guard let dragged = store.draggingSessionID,
              let group = store.splitGroups.first(where: { $0.contains(dragged) })
        else { return false }
        return group.contains(session.id)
    }

    private var isSelected: Bool { window.selectedSessionID == session.id }

    /// The machine this row runs on, or `nil` when it runs here — or when the
    /// workspace *is* that machine, since its name is already in the toolbar band.
    /// Marking every row of a machine's own workspace repeats one fact down the
    /// whole column, which is noise, not a cue.
    private var remoteDevice: KnownDevice? {
        guard marksDevice else { return nil }
        return .running(session)
    }

    /// The row's right-click menu. Rename/Pin/Close Session are always present; the two
    /// split "type switch" items appear conditionally — "Ungroup" only when the
    /// session is already in a group (联合 → 独立), and "Group with ▸" only when
    /// there is a sibling to combine it with (独立 → 联合).
    private var menuItems: [SidebarMenuItem] {
        sessionMenuItems(store: store, session: session)
    }

    var body: some View {
        // A session whose process the device buried reads as what it is — a spent
        // row with the reason it ended — in its own place in the tree, rather than
        // being moved to a separate list. The tombstone is a fact about the row.
        // Asked with the session in hand, not its id: the id form would look the
        // session back up to reach the daemon name this row already carries.
        if let tombstone = store.termiodEndReason(for: session) {
            EndedSessionRow(session: session, tombstone: tombstone, chrome: chrome,
                            leadingIndent: leadingIndent)
        } else {
            liveBody
        }
    }

    private var liveBody: some View {
        // Read once: the glyph, the ring and the tooltip all present the same
        // status, and reading it three times is three lookups for one fact.
        let status = store.status(for: session.id)
        return HStack(spacing: 6) {
            // While the agent is working, the leading mark becomes a small rotating
            // nine-dot grid — the row's own "thinking" spinner — and reverts to the
            // brand mark when the turn ends. No ambient tint on the brand mark: it
            // must keep its own vendor color (the same full-strength logo the
            // settings page shows), and the plain terminal symbol carries its own
            // muted grey from AgentIconView.
            Group {
                if session.isSSH, status != .working {
                    // An SSH terminal is a machine, so it carries the same server
                    // glyph as its host row in Settings ▸ Devices (a globe reads as
                    // "web", not "that box") — except while a detected remote
                    // agent is working, when it falls through to the spinner below.
                    // Size 15 like the folder and agent marks sharing this
                    // 16-wide column — HugeIconShape normalizes ink width, so
                    // equal size is what makes the glyphs read as one family.
                    HugeIconView(icon: .serverStack, size: 12, color: .secondary)
                } else if status == .working {
                    // The spinner carries no status color — its motion already
                    // says "working", so color stays reserved for the states
                    // that need the user (the green done / orange attention
                    // dots, whose only channel is color), and per-agent brand
                    // tints read as noise. It draws in the same primary ink as
                    // the sidebar's folder and terminal glyphs; the comet's own
                    // opacity ramp provides all the fade, so the head reads at
                    // full icon strength instead of a double-discounted grey.
                    WorkingIndicator(tint: .sidebarWorkingInk)
                        .frame(width: 12, height: 12)
                } else {
                    AgentIconView(agent: store.effectiveAgent(for: session), size: 12)
                }
            }
            .frame(width: 20, height: 20)
            // The same glass tile the horizontal tab strip draws behind each session's mark.
            .background(GlassTile())
            // The resting "your turn" status now rides the leading mark itself — a green dot when
            // the agent just finished, orange when it's blocked on you — so all of a row's status
            // (spinner = working, corner dot = your turn, nothing = idle) reads from one place on the
            // left instead of at the row's end. An overlay, so the dot never shifts the row's layout,
            // and it sits on the tile's corner so the vendor color stays intact.
            .overlay { StatusDot(status: status) }
            .help(store.statusDescription(for: session.id))
            VStack(alignment: .leading, spacing: 0) {
                Text(store.displayTitle(for: session))
                    .font(settings.interfaceFont)
                    .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The agent left but its wrapped shell survives ("Claude Code
                // exited — shell"): the row says what happened in its own place
                // instead of changing identity (#528). A link that is down
                // outranks it — while that is true the pane is not showing the
                // session at all.
                if let notice = store.connectionNotice(for: session.id)
                    ?? store.agentExitNotice(for: session.id) {
                    Text(notice)
                        .font(settings.interfaceFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // The origin trail on a pinned shortcut row, so a session lifted to the top
            // working set still says which project/branch it belongs to. Muted and
            // shrink-last so the title keeps priority when the row is tight.
            if let breadcrumb {
                Text("· \(breadcrumb)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            // At rest nothing trails the title in the flow, so it spans the full row.
            // On hover the close button in the trailing overlay takes room, and the
            // title truncates before it instead of running under it, as a Safari tab's does.
            Spacer(minLength: 4)
            if isHovering {
                Color.clear.frame(width: Self.closeButtonReserve)
            }
            // The machine the row runs on, when that is not this Mac. Almost
            // always the workspace's own machine — everything filed under a
            // workspace is on it — but not always: a remote terminal opened from
            // a project row is filed under that row wherever it runs. So the
            // device stays a property of the row, and the mark arrives before the
            // mistake rather than after it. Local rows carry nothing.
            if let device = remoteDevice {
                DeviceMarkView(
                    mark: DeviceMark.mark(
                        for: device, current: store.currentDevice, state: store.deviceSessions),
                    name: device.name)
            }
        }
        // VSCode-style trailing edge: the close button appears here on hover only, with room
        // reserved in the flow only while it shows. Status no longer trails the title — it moved to the leading mark's ring (above)
        // — so at rest the trailing edge is empty and the title spans the full row. Reordering is a
        // drag of the whole row (no separate handle), and creating a worktree is a folder-level
        // action (the project header's "New worktree" button), so the cluster carries only the close.
        .overlay(alignment: .trailing) {
            ZStack(alignment: .trailing) {
                SessionRowCloseButton(help: localized("Close session"), chrome: chrome) {
                    store.requestCloseSession(session.id)
                }
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
            // Out past the content's trailing inset into the highlight's rounded end, where a
            // tab's close button sits in its pill.
            .padding(.trailing, -Self.closeButtonOutset)
        }
        .padding(.vertical, settings.interfaceRowPadding)
        // Indent the session content under its project header (or its worktree
        // folder node) so the rows read as a child group rather than a flat sibling
        // list. The selection highlight (listRowBackground) stays full-width — the
        // standard macOS source-list look where children inset but the lift spans
        // the row.
        .padding(.leading, leadingIndent - sidebarLeadingTrim)
        // The row in your hand leaves its slot empty, but not its bracket: the slot is
        // where it lands, and the bracket there is the group a release makes.
        .opacity(isLiftedOut ? 0 : 1)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            if contentHeight != height { contentHeight = height }
        }
        // Keep the bracket in the final 16-point gutter immediately before the child
        // icon. At worktree depth this avoids laying its spine over the branch node's
        // own column while preserving the existing primary-session geometry. It reaches
        // past the content through the list's own row inset to the row's edge, so one
        // row's segment meets the next instead of breaking between them.
        .overlay(alignment: .leading) {
            if let splitLink {
                SplitLinkGlyph(mark: splitLink, chrome: chrome, isMarked: marksSourceGroup)
                    .frame(width: 16)
                    .padding(.vertical, -max(0, rowHeight - contentHeight) / 2)
                    .padding(.leading, max(0, leadingIndent - 16) - sidebarLeadingTrim)
            }
        }
        .modifier(SessionRowDragAndDrop(session: session,
                                         leading: leadingIndent - sidebarLeadingTrim))
        .onHover { isHovering = $0 }
        // Click-to-select rides a *simultaneous* tap, not `.onTapGesture`: an
        // exclusive tap gesture preempts the row drag (it never starts), while a
        // simultaneous one fires only when the mouse goes down and up in place, so
        // click-select and drag-reorder coexist. List's native `selection:` binding
        // can't carry the click instead — with `.onDrag` mounted, NSTableView's
        // click-to-select doesn't commit for seconds (the drag machinery swallows
        // the mouseDown), which shipped as v0.19.0's dead sidebar clicks.
        .simultaneousGesture(TapGesture().onEnded {
            // Re-tapping the row you're already on returns to its terminal, closing its
            // open file editor. Tapping a *different* session must NOT clear here: the
            // selection didSet captures the outgoing session's inspector layout first
            // (issue #160), so clearing pre-capture would drop its open file.
            if window.selectedSessionID == session.id {
                store.openFileURL = nil
            }
            store.selectedSessionID = session.id
            // Re-tapping the row you're already on still clears a resting
            // done/attention dot (the selection didSet only reacts to a change).
            store.markSeen(session.id)
        })
        // NSMenu rather than SwiftUI's `.contextMenu` so right-click leaves no blue
        // accent ring on the row (see `SidebarRowContextMenu`).
        .background(SidebarRowContextMenu(items: { menuItems }))
        // The group target takes the selection's glass rather than a cue of its own:
        // selected, in your hand and "into this" are one material.
        .listRowBackground(
            SidebarRowHighlight(isSelected: (isSelected && !isLiftedOut) || isDropTarget,
                                isHovering: isHovering && !isLiftedOut,
                                chrome: chrome, isGlass: true, isArming: isArming)
                // The row background spans the whole row, inset included: what the
                // bracket has to reach.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    if rowHeight != height { rowHeight = height }
                }
                // Selection snaps too. A new session inserts a row and moves the old
                // selection in the same frame; List froze the 120ms fade-out mid-way on
                // the moved row, leaving a second, half-lit lift under the new one.
                .animation(nil, value: isSelected)
                .animation(nil, value: isHovering)
                // No animation on the drop cue: it must snap off the instant the drag
                // leaves or commits (VS Code's `Over` feedback is instant), otherwise
                // the lift lingers on the row while it's already moving.
                .animation(nil, value: isDropTarget)
        )
        // No animation on hover, here or on the highlight above: a fade is latency
        // on a cue whose job is to track the pointer, the same call as the file
        // tree (#466). Scrolling moves rows under a still pointer, so a 120ms fade
        // left a trail of half-lit rows behind the scroll.
        .animation(nil, value: isHovering)
    }
}

/// A row whose session the device buried. The reason is the host's word
/// (`exited` · `killed` · `daemon_stopped` · `daemon_lost`) turned into something
/// a person reads — the host describes state and never decides presentation.
///
/// It stays clickable: opening it spawns the session again under the same name,
/// which is what the user means by clicking a row that used to work.
private struct EndedSessionRow: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject private var window: WindowContext
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    let session: Session
    let tombstone: Termiod.SessionTombstone
    let chrome: ChromeTheme?
    var leadingIndent: CGFloat = 16
    @State private var isHovering = false

    private var isSelected: Bool { window.selectedSessionID == session.id }

    /// The same group target and gap the live row draws.
    private var isDropTarget: Bool { sidebarDrag.groupTarget == session.id }
    private var isLiftedOut: Bool {
        store.draggingSessionID == session.id || sidebarDrag.settling == session.id
    }
    private var isArming: Bool { sidebarDrag.arming == session.id }

    private var reason: String {
        switch tombstone.reason {
        case "exited":
            guard let status = tombstone.exitStatus else { return localized("Ended") }
            return status == 0 ? localized("Ended") : localized("Ended — exit \(status)")
        case "killed": return localized("Closed")
        case "daemon_lost": return localized("The session host went away")
        case "daemon_stopped": return localized("The session host stopped")
        // A reason a newer daemon added and this build has no words for. The
        // fallback is the plainest true thing, never the wire word: the daemon's
        // vocabulary is protocol, and printing it puts `daemon_stopped` on screen.
        default: return localized("Ended")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            AgentIconView(agent: store.effectiveAgent(for: session), size: 15)
                .frame(width: 16)
                .opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.displayTitle(for: session))
                    .font(settings.interfaceFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reason)
                    .font(settings.interfaceFont)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, settings.interfaceRowPadding)
        .padding(.leading, leadingIndent - sidebarLeadingTrim)
        .opacity(isLiftedOut ? 0 : 1)
        .modifier(SessionRowDragAndDrop(session: session,
                                         leading: leadingIndent - sidebarLeadingTrim))
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { store.selectedSessionID = session.id })
        .background(SidebarRowContextMenu(items: {
            [.action(localized("Close Session")) { store.requestCloseSession(session.id) }]
        }))
        .listRowBackground(
            SidebarRowHighlight(isSelected: (isSelected && !isLiftedOut) || isDropTarget,
                                isHovering: isHovering && !isLiftedOut, chrome: chrome, isGlass: true,
                                isArming: isArming)
                .animation(nil, value: isHovering)
                // No animation on the drop cue: it must snap off the instant the
                // drag leaves or commits, as on the live row.
                .animation(nil, value: isDropTarget))
    }
}

/// The frosted-grey lift behind a session row. Selection reads as a translucent
/// "liquid glass" material (frosted, not a saturated accent fill) so the row text
/// stays primary and the eye lands on content; hover is a fainter grey, clearly
/// lighter than selection so the two states never blur together. Shared with the
/// file browser's folder drag highlight (see `FileRow`) so both side panels lift
/// rows identically.
struct SidebarRowHighlight: View {
    let isSelected: Bool
    let isHovering: Bool
    let chrome: ChromeTheme?
    /// `nil` draws the session sidebar's capsule. A radius draws a rounded rectangle instead, for
    /// the file tree's and the issue list's wide rows, where a capsule's ends read as a text field.
    var cornerRadius: CGFloat? = nil
    /// Selection in the selected tab's glass, with a neutral hover under it, rather than a fill or
    /// the theme's accent: the session sidebar's rows and the tabs above the cards are the same
    /// sessions, so selecting one reads the same in either layout.
    var isGlass = false
    /// A held drag arming to group with this row: the glass fills in over the hold, so the
    /// wait reads as progress. Snaps off when the hold ends; when it arms, `isSelected` takes over.
    var isArming = false

    var body: some View {
        if let cornerRadius {
            lift(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            lift(Capsule(style: .continuous))
        }
    }

    @ViewBuilder
    private func lift<S: InsettableShape>(_ shape: S) -> some View {
        if isGlass {
            glass(shape)
        } else if let chrome {
            themed(chrome, shape)
        } else {
            system(shape)
        }
    }

    /// The default grey lift: selection a clear step above hover. A plain ink fill,
    /// never a material — inside a table row a material follows the row's emphasis,
    /// so it drew accent-tinted while the list had keyboard focus and grey once a
    /// click on the terminal took it, changing colour under a selection that had
    /// not moved. Fill only — no border, so the row reads as a soft highlight
    /// rather than an outlined chip.
    private func system<S: InsettableShape>(_ shape: S) -> some View {
        shape
            .fill(Color.primary.opacity(fillOpacity))
            .overlay { if isSelected { GlassRim(shape: shape) } }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    /// The themed lift: a translucent wash of the theme's accent so the active
    /// session reads as accent-tinted (VSCode's active list item), with hover a
    /// fainter step below selection. Fill only — no border.
    private func themed<S: InsettableShape>(_ chrome: ChromeTheme, _ shape: S) -> some View {
        shape
            .fill(chrome.accent.opacity(accentOpacity))
            .overlay { if isSelected { GlassRim(shape: shape) } }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    @ViewBuilder
    private func glass<S: InsettableShape>(_ shape: S) -> some View {
        Group {
            if isSelected {
                SelectionGlass(shape: shape)
            } else {
                shape.fill(Color.primary.opacity(isHovering ? 0.045 : 0))
                    .overlay {
                        SelectionGlass(shape: shape)
                            .opacity(isArming ? 1 : 0)
                            .animation(isArming ? .linear(duration: TermioStore.groupDwell) : nil,
                                       value: isArming)
                    }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
    }

    private var fillOpacity: Double {
        if isSelected { return 0.12 }
        if isHovering { return 0.045 }
        return 0
    }

    private var accentOpacity: Double {
        if isSelected { return 0.22 }
        if isHovering { return 0.10 }
        return 0
    }
}

/// The resting "your turn" status, drawn as a badge dot on the leading mark's top-trailing corner:
/// green when the agent just finished, orange when it's blocked on you. Working is the leading
/// spinner and idle is nothing, so only those two states show the dot. An overlay sized to the
/// mark's frame, so it never shifts the row; the dark rim cuts it out of the tile underneath.
struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .padding(1.5)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            .offset(x: 3, y: -3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .opacity(status == .done || status == .needsAttention ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var color: Color {
        status == .needsAttention ? .orange : .green
    }
}

extension Color {
    /// Pure ink for the sidebar's working spinner: `labelColor` keeps ~15%
    /// transparency and the sidebar's vibrancy lightens it again, which left even
    /// the comet's full-opacity head reading grey. Appearance-adaptive
    /// black/white punches through both. The shared `WorkingIndicator` takes its
    /// tint from the caller so iOS can pass an agent brand color instead.
    static let sidebarWorkingInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    })
}

/// Sidebar nudge shown when agents run with the status hooks disabled. Low-alarm by
/// design — a neutral card, not an accent banner. "Enable" turns the hooks back on.
private struct AgentHooksOffBanner: View {
    let enable: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(localized("Live agent status is off"))
                    .font(.callout.weight(.medium))
                Text(localized("Agents won’t show as working."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(localized("Enable"), action: enable)
                .buttonStyle(.borderless)
                .font(.callout.weight(.medium))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.vertical, 4)
    }
}
