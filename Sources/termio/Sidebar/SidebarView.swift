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
/// project for the origin breadcrumb.
private struct PinnedSessionEntry: Identifiable {
    let project: Project
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
    /// The first section in the list sits right under the toolbar, so its top
    /// padding is dead space rather than a separator — it gets a tight inset.
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
        // rule — so each group reads as its own block without a hairline. The first
        // section has no group above it to separate from, so it stays tight.
        .padding(.top, isFirstSection ? 2 : 12)
        .padding(.bottom, 2)
        // No `listRowInsets` override — the header keeps the rows' default inset so both
        // share one left baseline. The small leading then lands the label's left edge on
        // the folder/terminal glyph's own inset in its 16pt slot, so they read aligned.
        .padding(.leading, 2.5)
        .contentShape(Rectangle())
        .onTapGesture { toggleCollapsed() }
        .background {
            // Only sections that offer actions (Terminals) get a right-click menu; the
            // Pinned label has none, so it stays a passive divider.
            if !menuItems.isEmpty {
                SidebarRowContextMenu(items: menuItems) { isMenuOpen = $0 }
            }
        }
        .background(OutlineSelectionStyleStripper())
        .listRowBackground(
            SidebarRowHighlight(isSelected: false, isHovering: isMenuOpen, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isMenuOpen)
        )
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    // The terminal theme is split light/dark and libghostty tracks the system
    // appearance; the chrome borrows whichever side is currently showing.
    @Environment(\.colorScheme) private var colorScheme
    // Which projects are folded shut. Held here, not in ProjectHeader, because the
    // header and the session rows are siblings — only the parent can both toggle the
    // fold and omit the collapsed project's rows.
    @State private var collapsedProjects: Set<Project.ID> = []
    @State private var collapsedWorktrees: Set<Worktree.ID> = []
    /// Whether the top "Pinned" working-set section is folded shut.
    @State private var pinnedCollapsed = false
    /// Whether the "Projects" section is folded shut.
    @State private var projectsCollapsed = false

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
        // deliberately-elevated items); then the loose Terminals and Chats funnels; then
        // the rest. A project's membership in the pinned group is itself the pin cue, so
        // pinned rows carry no per-row badge. Both groups keep the user's chosen sort
        // (already applied by `orderedProjects`, which we only partition here — never reorder).
        let ordered = store.orderedProjects
        let terminals = ordered.filter { $0.kind == .terminals }
        let chats = ordered.filter { $0.kind == .chats }
        // Only real `.folder` projects populate the Pinned working set and the Projects
        // list; the two loose funnels (Terminals, Chats) render as their own sections.
        let pinnedProjects = ordered.filter { $0.kind == .folder && $0.pinned }
        let others = ordered.filter { $0.kind == .folder && !$0.pinned }
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
        let pinnedSessions: [PinnedSessionEntry] = others.flatMap { project in
            project.sessions.filter { session in
                guard session.pinned else { return false }
                if let wp = session.worktreePath, pinnedWorktreePaths.contains(wp) { return false }
                return true
            }.map { PinnedSessionEntry(project: project, session: $0) }
        }
        let hasPinned = !pinnedProjects.isEmpty || !pinnedWorktrees.isEmpty || !pinnedSessions.isEmpty
        let hasTerminals = terminals.contains { !$0.sessions.isEmpty }
        let hasChats = chats.contains { !$0.sessions.isEmpty }
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
            // above the ephemeral Terminals/Chats funnels — because it's the items the user
            // deliberately elevated (mirroring the iOS "Needs You" strip at the home top).
            if hasPinned {
                SidebarSectionHeader(
                    title: "Pinned",
                    chrome: chrome,
                    isCollapsed: pinnedCollapsed,
                    isFirstSection: true,
                    toggleCollapsed: {
                        withAnimation(.easeInOut(duration: 0.18)) { pinnedCollapsed.toggle() }
                    }
                )
                if !pinnedCollapsed {
                    ForEach(pinnedProjects) { projectBlock($0) }
                    ForEach(pinnedWorktrees) { entry in
                        pinnedWorktreeBlock(project: entry.project, worktree: entry.worktree)
                    }
                    ForEach(pinnedSessions) { entry in
                        SessionRow(session: entry.session, chrome: chrome, leadingIndent: 16,
                                   breadcrumb: breadcrumb(for: entry.session, in: entry.project))
                    }
                }
            }
            // The loose-terminals funnel, as a section (not a project folder): its
            // header carries the New/Close actions; its sessions render below. Hidden
            // entirely while it holds no terminals — an empty section label is just
            // noise (a new loose terminal reappears the section, via the + / File menu).
            ForEach(terminals.filter { !$0.sessions.isEmpty }) { term in
                SidebarSectionHeader(
                    title: "Terminals",
                    chrome: chrome,
                    isCollapsed: collapsedProjects.contains(term.id),
                    isFirstSection: !hasPinned,
                    toggleCollapsed: { toggleCollapsed(term.id) },
                    menuItems: [
                        .action("New Terminal") { store.addSession(to: term.id, agent: .terminal) },
                        .separator,
                        .action("Close All Terminals") { store.removeProject(term.id) },
                    ]
                )
                if !collapsedProjects.contains(term.id) {
                    let sessions = primarySessions(for: term)
                    let marks = splitLinkMarks(for: sessions)
                    ForEach(sessions) { session in
                        SessionRow(session: session, chrome: chrome, splitLink: marks[session.id])
                    }
                }
            }
            // The loose-agents funnel — the agent-side twin of Terminals, paired
            // directly above Projects (the "Chats vs Projects" split: one-off agent
            // sessions vs. real folder-scoped work). Every scratch agent shares one
            // `.chats` container rooted at `~/.termio/chats`; its header offers a single
            // "New Chat" (the default agent — see `addDefaultChat`) plus a Close All,
            // mirroring the Terminals header's "New Terminal". Hidden while empty.
            ForEach(chats.filter { !$0.sessions.isEmpty }) { chat in
                SidebarSectionHeader(
                    title: "Chats",
                    chrome: chrome,
                    isCollapsed: collapsedProjects.contains(chat.id),
                    isFirstSection: !hasPinned && !hasTerminals,
                    toggleCollapsed: { toggleCollapsed(chat.id) },
                    menuItems: [
                        .action("New Chat") { store.addDefaultChat() },
                        .separator,
                        .action("Close All Chats") { store.removeProject(chat.id) },
                    ]
                )
                if !collapsedProjects.contains(chat.id) {
                    let sessions = primarySessions(for: chat)
                    let marks = splitLinkMarks(for: sessions)
                    ForEach(sessions) { session in
                        SessionRow(session: session, chrome: chrome, splitLink: marks[session.id])
                    }
                }
            }
            // The user's opened projects, under their own section header — the same
            // section treatment as Terminals and Pinned, one tier above the folder rows.
            if !others.isEmpty {
                SidebarSectionHeader(
                    title: "Projects",
                    chrome: chrome,
                    isCollapsed: projectsCollapsed,
                    isFirstSection: !hasPinned && !hasTerminals && !hasChats,
                    toggleCollapsed: {
                        withAnimation(.easeInOut(duration: 0.18)) { projectsCollapsed.toggle() }
                    }
                )
                if !projectsCollapsed {
                    ForEach(others) { projectBlock($0) }
                }
            }
        }
        // The native macOS `.sidebar` source list — its own Liquid Glass material, full-height
        // behind the traffic lights. (We previously painted the column ourselves to dodge a macOS 26
        // full-screen round-trip bug, but per the design call we're back to the stock sidebar.)
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 1)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    }

    /// One project's rows: its header, then (unless folded) its primary-checkout
    /// sessions and each worktree's nested header + sessions. Factored out of `body`
    /// so the pinned and unpinned groups render identical project blocks.
    @ViewBuilder
    private func projectBlock(_ project: Project) -> some View {
        ProjectHeader(
            project: project,
            isCollapsed: collapsedProjects.contains(project.id),
            toggleCollapsed: { toggleCollapsed(project.id) },
            chrome: chrome
        )
        if !collapsedProjects.contains(project.id) {
            let primarySessions = primarySessions(for: project)
            let primarySplitMarks = splitLinkMarks(for: primarySessions)
            ForEach(primarySessions) { session in
                SessionRow(session: session, chrome: chrome,
                           splitLink: primarySplitMarks[session.id])
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
                    let sessions = project.sessions.filter {
                        $0.worktreePath == worktree.path
                    }
                    let splitMarks = splitLinkMarks(for: sessions)
                    ForEach(sessions) { session in
                        SessionRow(
                            session: session,
                            chrome: chrome,
                            leadingIndent: 32,
                            splitLink: splitMarks[session.id]
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
    private func pinnedWorktreeBlock(project: Project, worktree: Worktree) -> some View {
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
            let sessions = project.sessions.filter { $0.worktreePath == worktree.path }
            let splitMarks = splitLinkMarks(for: sessions)
            ForEach(sessions) { session in
                SessionRow(session: session, chrome: chrome, leadingIndent: 16,
                           splitLink: splitMarks[session.id])
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
        guard !project.worktrees.isEmpty else { return project.sessions }
        return project.sessions.filter {
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
        guard !store.splitGroups.isEmpty else { return [:] }
        var groupOf: [Session.ID: Int] = [:]
        for (index, group) in store.splitGroups.enumerated() {
            for id in group.leafIDs { groupOf[id] = index }
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

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let x = geo.size.width * 0.5
                let midY = geo.size.height / 2
                let top = CGPoint(x: x, y: 0)
                let mid = CGPoint(x: x, y: midY)
                let bottom = CGPoint(x: x, y: geo.size.height)
                switch mark {
                case .top: path.move(to: mid); path.addLine(to: bottom)
                case .middle: path.move(to: top); path.addLine(to: bottom)
                case .bottom: path.move(to: top); path.addLine(to: mid)
                }
                path.move(to: mid)
                path.addLine(to: CGPoint(x: x + 5, y: midY))
            }
            .stroke(lineWidth: 1)
            .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground.opacity(0.35)) }
                ?? AnyShapeStyle(.tertiary))
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

    private var isTerminalsHeader: Bool {
        worktree == nil && project.kind == .terminals
    }

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
        return "Detached at \(commit)"
    }

    /// Every folder container — project or worktree — swaps closed/open folders as its
    /// collapse cue; the Terminals section keeps its own terminal glyph. A worktree's
    /// git-linkage is marked by a trailing branch glyph on the row (below), not a
    /// distinct folder icon: a git node baked into the folder glyph was illegible at
    /// sidebar size, and a plain folder keeps the two header kinds visually one family.
    private var headerIcon: HugeIcon {
        if isTerminalsHeader { return .terminal }
        return isCollapsed ? .folder : .folderOpen
    }

    private func addSession(_ preset: AgentPreset) {
        store.addSession(to: project.id, agent: preset, worktreePath: worktree?.path)
    }

    /// Width the trailing quick-add icons occupy (button frame 22 + 3 spacing each), so
    /// the hovered label can fade out exactly under them rather than guessing.
    /// Zero for the Terminals section, which offers no agent quick-add cluster.
    private var quickAddClusterWidth: CGFloat {
        guard !isTerminalsHeader else { return 0 }
        let count = headerSessionPresets(settings).count
        guard count > 0 else { return 0 }
        return CGFloat(count) * 22 + CGFloat(count - 1) * 3
    }

    /// The right-click menu: New Terminal, a "New Agent Session ▸" submenu with one
    /// row per enabled agent (the same row shape as File ▸ New Chat), then the
    /// project's own actions. Mirrors the hover controls so both routes stay in sync.
    /// The Terminals section is not a folder project — agents don't belong in `$HOME`
    /// (they get a real project or the scoped scratch workspace), and worktree /
    /// Finder actions are about a project's directory — so its menu is
    /// just the terminal action and Close All Terminals.
    private var menuItems: [SidebarMenuItem] {
        if isTerminalsHeader {
            return [
                .action("New Terminal") { store.addSession(to: project.id, agent: .terminal) },
                .separator,
                .action("Close All Terminals") { store.removeProject(project.id) },
            ]
        }
        var items: [SidebarMenuItem] = [
            .action("New Terminal") { addSession(.terminal) },
            .submenu("New Agent Session", enabledAgentPresets(settings)
                .filter { $0 != .terminal }
                .map { preset in .agent(preset) { addSession(preset) } }),
        ]
        if let worktree {
            items.append(.separator)
            items.append(.action(worktree.pinned ? "Unpin" : "Pin") {
                store.toggleWorktreePinned(worktree.id)
            })
            items.append(.action("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
            })
            items.append(.separator)
            items.append(.action("Remove Worktree") {
                store.removeWorktree(worktree.id, from: project.id)
            })
            return items
        }
        // Create a fresh detached checkout nested under this project; the new
        // container's own quick-add controls fill it with sessions on demand.
        // Only for git repositories (a worktree needs one; "—" marks a non-repo folder).
        if project.branch != "—" {
            items.append(.action("New Worktree") { store.addWorktree(from: project.id) })
        }
        items.append(.separator)
        items.append(.action(project.pinned ? "Unpin" : "Pin to Top") {
            store.togglePinned(project.id)
        })
        items.append(.action("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
        })
        items.append(.separator)
        items.append(.action("Remove Project") { store.removeProject(project.id) })
        return items
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
                    .help("Git worktree")
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
        // rest and the reveal animates with the same 0.12s hover easing.
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
            // The Terminals section gets no agent cluster — an agent loose in `$HOME`
            // is exactly what the scoped scratch workspace exists to prevent.
            if !isTerminalsHeader {
                HStack(spacing: 3) {
                    ForEach(headerSessionPresets(settings)) { preset in
                        AgentQuickAddButton(preset: preset, chrome: chrome) {
                            addSession(preset)
                        }
                    }
                }
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, leadingIndent)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { toggleCollapsed() }
        // Right-click mirrors the hover controls, so every action is reachable both
        // ways. Built as an `NSMenu` (see `SidebarRowContextMenu`) rather than
        // SwiftUI's `.contextMenu`, which paints an un-styleable blue accent ring
        // around the targeted row. While the menu is up the row lifts to the hover
        // level (a step below session selection) so the target reads clearly.
        .background(SidebarRowContextMenu(items: menuItems) { isMenuOpen = $0 })
        // Strip the source list's native blue accent (the ring/fill AppKit paints on a
        // right-clicked or selected row) at the NSOutlineView layer, so our own
        // highlights are the only selection cue — same treatment the file tree uses.
        .background(OutlineSelectionStyleStripper())
        .listRowBackground(
            SidebarRowHighlight(isSelected: false, isHovering: isMenuOpen, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isMenuOpen)
        )
        .animation(.easeInOut(duration: 0.12), value: isHovering)
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

/// One entry in a sidebar row's right-click menu — a titled action, an agent row
/// (display name plus brand icon, the File ▸ New Chat row shape), a titled
/// submenu of further entries, or a separator.
enum SidebarMenuItem {
    case action(String, () -> Void)
    case agent(AgentPreset, () -> Void)
    indirect case submenu(String, [SidebarMenuItem])
    case separator
}

/// A sidebar row's right-click menu, built as an AppKit `NSMenu` rather than
/// SwiftUI's `.contextMenu` — the latter rings the targeted row with an
/// un-styleable accent highlight (the blue border). A secondary-click recognizer on
/// the row's own view pops the menu, so nothing emphasizes the row. Mirrors the file
/// browser's `RowContextMenu`.
private struct SidebarRowContextMenu: NSViewRepresentable {
    let items: [SidebarMenuItem]
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
        var items: [SidebarMenuItem] = []
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
            let menu = build(items)
            menu.delegate = self
            menu.popUp(positioning: nil, at: recognizer.location(in: hostView), in: hostView)
        }

        /// Builds an `NSMenu` from the spec, recursing for submenus.
        private func build(_ items: [SidebarMenuItem]) -> NSMenu {
            let menu = NSMenu()
            for item in items {
                switch item {
                case .separator:
                    menu.addItem(.separator())
                case let .action(title, handler):
                    let menuItem = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
                    menuItem.target = self
                    menuItem.representedObject = Handler(handler)
                    menu.addItem(menuItem)
                case let .agent(preset, handler):
                    let menuItem = NSMenuItem(title: preset.displayName, action: #selector(invoke(_:)), keyEquivalent: "")
                    menuItem.target = self
                    menuItem.representedObject = Handler(handler)
                    menuItem.image = agentMenuImage(for: preset)
                    menu.addItem(menuItem)
                case let .submenu(title, children):
                    let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    // An empty submenu (e.g. nothing to group with) reads as a
                    // disabled, un-openable parent rather than a dead-end click.
                    menuItem.isEnabled = !children.isEmpty
                    menuItem.submenu = children.isEmpty ? nil : build(children)
                    menu.addItem(menuItem)
                }
            }
            return menu
        }

        @objc private func invoke(_ sender: NSMenuItem) {
            (sender.representedObject as? Handler)?.run()
        }

        // NSMenuDelegate — surface the open/close so the row lifts while its menu is up.
        func menuWillOpen(_ menu: NSMenu) { onMenuState(true) }
        func menuDidClose(_ menu: NSMenu) { onMenuState(false) }

        /// Boxes a menu-item closure so it can ride along on `NSMenuItem.representedObject`.
        private final class Handler {
            let run: () -> Void
            init(_ run: @escaping () -> Void) { self.run = run }
        }

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
            AgentIconView(agent: preset, size: 15)
                .frame(width: 22, height: 20)
                .background(hoverBackground(chrome, isHovering: isHovering))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .help("New \(preset.displayName) session")
    }
}

/// The rounded hover lift shared by the header's inline action controls: a faint
/// fill of the theme foreground (or the system primary) under the cursor only.
private func hoverBackground(_ chrome: ChromeTheme?, isHovering: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill((chrome?.foreground ?? .primary).opacity(isHovering ? 0.12 : 0))
}

/// The inline close action on a session row. Like `AgentQuickAddButton`, it owns
/// its hover state so the control lifts a rounded background under the cursor — the
/// per-action highlight VSCode gives the kill button on a terminal tab.
private struct SessionRowActionButton: View {
    let systemImage: String
    let help: String
    /// The colour the glyph turns under the cursor. Destructive actions announce
    /// themselves in red; benign ones (isolate) lift to the accent.
    var hoverTint: Color = .red
    var pointSize: CGFloat = 17
    let chrome: ChromeTheme?
    var isEnabled: Bool = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // At rest the glyph borrows the row's foreground; on hover it lifts to its
            // tint so the action announces itself before the click (red for the
            // destructive close, accent for the benign isolate).
            Image(systemName: systemImage)
                .font(.system(size: pointSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isHovering ? AnyShapeStyle(hoverTint) : (chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.secondary)))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .help(help)
        .disabled(!isEnabled)
    }
}

/// A session row. Hovering reveals a close button on the trailing edge (same
/// opacity-reveal pattern as the project header).
private struct SessionRow: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
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
    @State private var isHovering = false
    /// A same-bucket session is being dragged over this row: light its whole-row
    /// background (the hover lift) as the reorder drop target. Only set when the
    /// in-flight session could legally land here (`store.canReorder`).
    @State private var isDropTarget = false

    /// Namespace prefix for the drag payload, so the row's drop accepts only a
    /// session drag (a session id) and never arbitrary dropped text.
    private static let dragPrefix = "termio-session:"

    private var isSelected: Bool { store.selectedSessionID == session.id }

    /// The row's right-click menu. Rename/Pin/Close Session are always present; the two
    /// split "type switch" items appear conditionally — "Ungroup" only when the
    /// session is already in a group (联合 → 独立), and "Group with ▸" only when
    /// there is a sibling to combine it with (独立 → 联合).
    private var menuItems: [SidebarMenuItem] {
        var items: [SidebarMenuItem] = [
            .action("Rename…") { store.renameSession(session.id) }
        ]
        let targets = store.groupableTargets(for: session.id)
        if store.isInSplitGroup(session.id) || !targets.isEmpty { items.append(.separator) }
        if store.isInSplitGroup(session.id) {
            items.append(.action("Ungroup") { store.detachFromSplit(session.id) })
        }
        if !targets.isEmpty {
            items.append(.submenu("Group with", targets.map { target in
                .action(store.displayTitle(for: target)) {
                    store.groupSession(session.id, with: target.id)
                }
            }))
        }
        items.append(contentsOf: [
            .separator,
            .action(session.pinned ? "Unpin" : "Pin") { store.toggleSessionPinned(session.id) },
            .separator,
            .action("Close Session") { store.closeSession(session.id) },
        ])
        return items
    }

    var body: some View {
        HStack(spacing: 6) {
            // While the agent is working, the leading mark becomes a small rotating
            // nine-dot grid — the row's own "thinking" spinner — and reverts to the
            // brand mark when the turn ends. No ambient tint on the brand mark: it
            // must keep its own vendor color (the same full-strength logo the
            // settings page shows), and the plain terminal symbol carries its own
            // muted grey from AgentIconView.
            Group {
                if session.isSSH, store.status(for: session.id) != .working {
                    // An SSH terminal is a machine, so it carries the same server
                    // glyph as its host row in Settings ▸ SSH (a globe reads as
                    // "web", not "that box") — except while a detected remote
                    // agent is working, when it falls through to the spinner below.
                    // Size 15 like the folder and agent marks sharing this
                    // 16-wide column — HugeIconShape normalizes ink width, so
                    // equal size is what makes the glyphs read as one family.
                    HugeIconView(icon: .serverStack, size: 15, color: .secondary)
                } else if store.status(for: session.id) == .working {
                    // The spinner carries no status color — its motion already
                    // says "working", so color stays reserved for the states
                    // that need the user (the green done / orange attention
                    // dots, whose only channel is color), and per-agent brand
                    // tints read as noise. It draws in the same primary ink as
                    // the sidebar's folder and terminal glyphs; the comet's own
                    // opacity ramp provides all the fade, so the head reads at
                    // full icon strength instead of a double-discounted grey.
                    WorkingIndicator(tint: .sidebarWorkingInk)
                } else {
                    AgentIconView(agent: store.effectiveAgent(for: session), size: 15)
                }
            }
            .frame(width: 16)
            .help(store.statusDescription(for: session.id))
            Text(store.displayTitle(for: session))
                .font(settings.interfaceFont)
                .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
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
            // Nothing trails the title in the flow: the resting status dot and the
            // hover close button both live in the trailing overlay below (zero
            // layout width), so the title always spans the full row and truncates
            // only at the true trailing edge. The spacer just left-aligns the title.
            Spacer(minLength: 4)
        }
        // VSCode-style trailing edge, shared and reserving zero flow width: at rest
        // the "your turn" status dot (done=green / needsAttention=orange) floats over
        // the title's tail; on hover it yields to the close button. Because neither
        // sits in the row's HStack, the title always spans the full width and only
        // the two are painted on top of its trailing end. Creating a worktree is a
        // folder-level action now (the project header's "New worktree" button), so a
        // session row's trailing cluster carries only the close button.
        .overlay(alignment: .trailing) {
            ZStack(alignment: .trailing) {
                // StatusDot self-hides for idle/working, so at rest this shows a dot
                // only for the two resting "your turn" states; on hover it fades out.
                StatusDot(status: store.status(for: session.id))
                    .frame(width: 16)
                    .opacity(isHovering ? 0 : 1)
                    .help(store.statusDescription(for: session.id))
                // Reordering is a drag of the whole row (no separate handle), so the
                // trailing hover cluster carries only the close.
                SessionRowActionButton(
                    systemImage: "xmark.circle.fill",
                    help: "Close session",
                    chrome: chrome
                ) {
                    store.closeSession(session.id)
                }
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
        }
        .padding(.vertical, settings.interfaceRowPadding)
        // Indent the session content under its project header (or its worktree
        // folder node) so the rows read as a child group rather than a flat sibling
        // list. The selection highlight (listRowBackground) stays full-width — the
        // standard macOS source-list look where children inset but the lift spans
        // the row.
        .padding(.leading, leadingIndent)
        // Keep the bracket in the final 16-point gutter immediately before the child
        // icon. At worktree depth this avoids laying its spine over the branch node's
        // own column while preserving the existing primary-session geometry.
        .overlay(alignment: .leading) {
            if let splitLink {
                SplitLinkGlyph(mark: splitLink, chrome: chrome)
                    .frame(width: 16)
                    .padding(.leading, max(0, leadingIndent - 16))
            }
        }
        .contentShape(Rectangle())
        // Drag the whole row to reorder it within its bucket (no handle). Uses
        // `.onDrag` (AppKit's drag session) rather than `.draggable` (SwiftUI's): a
        // SwiftUI drag settles its preview over ~0.3s on release, while an AppKit drag
        // image just vanishes on a successful drop — so the row moves crisply. The
        // drag only carries the session id; nothing reorders until the drop commits
        // it (see the drop below). It starts at all only because selection rides a
        // *simultaneous* tap (below) — an exclusive `.onTapGesture` kills the drag.
        .onDrag {
            store.draggingSessionID = session.id
            return NSItemProvider(object: (Self.dragPrefix + session.id.uuidString) as NSString)
        } preview: {
            // The drag preview is just the row's identity (icon + title), so the
            // floating chip never carries the hover-only close button. `.fixedSize`
            // keeps the label at its natural width — the preview proposes a tight size
            // that would otherwise squeeze the flexible Text away, leaving only the
            // fixed-width icon — and the material plate makes the chip legible.
            HStack(spacing: 6) {
                AgentIconView(agent: store.effectiveAgent(for: session), size: 15)
                    .frame(width: 16)
                Text(store.displayTitle(for: session))
                    .font(settings.interfaceFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
            )
        }
        // Reorder on drop: the prefix filter rejects non-session text, a self-drop is
        // ignored, and a cross-bucket drop is a no-op in the store.
        .dropDestination(for: String.self) { payloads, _ in
            store.draggingSessionID = nil
            // Clear the drop lift the instant we commit so it can't linger on this row
            // (or ghost onto its new neighbour) as the list settles the move.
            isDropTarget = false
            guard let payload = payloads.first(where: { $0.hasPrefix(Self.dragPrefix) }),
                  let moved = UUID(uuidString: String(payload.dropFirst(Self.dragPrefix.count))),
                  moved != session.id
            else { return false }
            store.reorderSession(moved, relativeTo: session.id)
            return true
        } isTargeted: { targeted in
            // Light the background only when the in-flight session could actually land
            // here — same project + worktree bucket — so a cross-section hover stays inert.
            isDropTarget = targeted
                && (store.draggingSessionID.map { store.canReorder($0, relativeTo: session.id) } ?? false)
        }
        .onHover { isHovering = $0 }
        // Click-to-select rides a *simultaneous* tap, not `.onTapGesture`: an
        // exclusive tap gesture preempts the row drag (it never starts), while a
        // simultaneous one fires only when the mouse goes down and up in place, so
        // click-select and drag-reorder coexist. List's native `selection:` binding
        // can't carry the click instead — with `.onDrag` mounted, NSTableView's
        // click-to-select doesn't commit for seconds (the drag machinery swallows
        // the mouseDown), which shipped as v0.19.0's dead sidebar clicks.
        .simultaneousGesture(TapGesture().onEnded {
            // Tapping a session always returns to its terminal — close the file
            // editor even when this row is already selected (no change to react to).
            store.openFileURL = nil
            store.selectedSessionID = session.id
            // Re-tapping the row you're already on still clears a resting
            // done/attention dot (the selection didSet only reacts to a change).
            store.markSeen(session.id)
        })
        // NSMenu rather than SwiftUI's `.contextMenu` so right-click leaves no blue
        // accent ring on the row (see `SidebarRowContextMenu`).
        .background(SidebarRowContextMenu(items: menuItems))
        // The reorder drop target (VS Code's `Over` effect) reuses the *hover* lift
        // verbatim — same frosted-grey fill, same row-sized region and insets — so the
        // drop cue never introduces a second background shape; it reads as a hover.
        .listRowBackground(
            SidebarRowHighlight(isSelected: isSelected,
                                isHovering: isHovering || isDropTarget,
                                chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isSelected)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
                // No animation on the drop cue: it must snap off the instant the drag
                // leaves or commits (VS Code's `Over` feedback is instant), otherwise
                // the lift lingers on the row while it's already moving.
                .animation(nil, value: isDropTarget)
        )
        .animation(.easeInOut(duration: 0.12), value: isHovering)
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

    var body: some View {
        if let chrome {
            themed(chrome)
        } else {
            system
        }
    }

    /// The default frosted-grey lift. The material reads only faintly over the
    /// already-blurred sidebar, so a grey tint carries most of the lift; selection
    /// sits a clear step above hover. Fill only — no border, so the row reads as a
    /// soft highlight rather than an outlined chip.
    private var system: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(isSelected ? 1 : 0)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    /// The themed lift: a translucent wash of the theme's accent so the active
    /// session reads as accent-tinted (VSCode's active list item), with hover a
    /// fainter step below selection. Fill only — no border.
    private func themed(_ chrome: ChromeTheme) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(chrome.accent.opacity(accentOpacity))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    private var fillOpacity: Double {
        if isSelected { return 0.09 }
        if isHovering { return 0.045 }
        return 0
    }

    private var accentOpacity: Double {
        if isSelected { return 0.22 }
        if isHovering { return 0.10 }
        return 0
    }
}

/// A small coloured dot mirroring the menu-bar pulse: hidden when idle, amber
/// when the session wants attention, blue while working.
private struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            // Working is shown by the leading spinner and idle shows nothing, so
            // only the two resting "your turn" states trail the title as a dot:
            // green when the agent just finished, orange when it's blocked on you.
            .opacity(status == .done || status == .needsAttention ? 1 : 0)
    }

    private var color: Color {
        status == .needsAttention ? .orange : .green
    }
}

/// The "agent is working" mark: a 3×3 grid of dots with a bright comet that orbits
/// the eight perimeter cells, so the small nine-square grid reads as rotating. Sits
/// in place of the session's brand icon while a turn is in flight (see `SessionRow`).
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
                Text("Live agent status is off")
                    .font(.callout.weight(.medium))
                Text("Agents won't show as working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Enable", action: enable)
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
