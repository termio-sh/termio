import SwiftUI
import AppKit

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

    // Chrome colors borrowed from the selected terminal theme; `nil` keeps the
    // default system look untouched.
    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        // Selection is driven by row taps rather than List's `selection:` binding
        // so we can paint our own frosted-grey highlight. The system selection
        // forces an edge-to-edge accent fill (and white text) that can't be
        // restyled without also draining the row's other accent-tinted controls.
        // A flat list rather than `Section`s: the sidebar's section spacing leaves
        // a big empty band between a collapsed project's header and the next, and
        // macOS has no `listSectionSpacing`. The header carries its own grouping
        // weight (small-caps label + folder mark), so folded projects stack tight.
        List {
            // A flat list rather than SwiftUI Sections, with small injected labels when
            // a grouping rule is active. This keeps the sidebar rhythm tight while making
            // the chosen grouping visible instead of silently applying only a sort order.
            ForEach(projectGroups) { group in
                if let title = group.title {
                    ProjectGroupLabel(title: title, chrome: chrome)
                }
                ForEach(group.projects) { project in
                    ProjectHeader(
                        project: project,
                        isCollapsed: collapsedProjects.contains(project.id),
                        toggleCollapsed: { toggleCollapsed(project.id) },
                        chrome: chrome
                    )
                    if !collapsedProjects.contains(project.id) {
                        let splitMarks = splitLinkMarks(for: project)
                        ForEach(project.sessions) { session in
                            SessionRow(session: session, chrome: chrome,
                                       splitLink: splitMarks[session.id])
                        }
                    }
                }
            }
        }
        // The native macOS `.sidebar` source list — its own Liquid Glass material, full-height
        // behind the traffic lights. (We previously painted the column ourselves to dodge a macOS 26
        // full-screen round-trip bug, but per the design call we're back to the stock sidebar.)
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 1)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        // One sheet for the whole sidebar, driven by the store rather than per-row state,
        // so opening it from any project's context menu (or its Sandbox pill) presents the
        // same panel over the window.
        .sheet(isPresented: Binding(
            get: { store.editingSecurityProjectID != nil },
            set: { if !$0 { store.editingSecurityProjectID = nil } }
        )) {
            if let id = store.editingSecurityProjectID {
                SecuritySheet(projectID: id)
                    .environmentObject(store)
                    .environmentObject(settings)
            }
        }
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

    private struct ProjectGroup: Identifiable {
        let id: String
        let title: String?
        let projects: [Project]
    }

    private var projectGroups: [ProjectGroup] {
        let ordered = store.orderedProjects
        let terminals = ordered.filter { $0.kind == .terminals }
        let folders = ordered.filter { $0.kind != .terminals }
        var groups: [ProjectGroup] = []

        // The Terminals section already carries its own recognisable header, so it
        // remains above any user-selected project grouping.
        if !terminals.isEmpty {
            groups.append(ProjectGroup(id: "terminals", title: nil, projects: terminals))
        }

        switch settings.projectSortOrder {
        case .none:
            if !folders.isEmpty {
                groups.append(ProjectGroup(id: "projects", title: nil, projects: folders))
            }
        case .name:
            groups.append(contentsOf: groupedFolders(folders) { project in
                let initial = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased().first
                return initial.map(String.init) ?? "#"
            })
        case .recentActivity:
            groups.append(contentsOf: activityGroups(folders))
        }
        return groups
    }

    private func groupedFolders(
        _ folders: [Project],
        key: (Project) -> String
    ) -> [ProjectGroup] {
        var result: [ProjectGroup] = []
        for (pinned, prefix) in [(true, "PINNED · "), (false, "")] {
            let projects = folders.filter { $0.pinned == pinned }
            var buckets: [String: [Project]] = [:]
            var order: [String] = []
            for project in projects {
                let groupKey = key(project)
                if buckets[groupKey] == nil { order.append(groupKey) }
                buckets[groupKey, default: []].append(project)
            }
            for groupKey in order {
                guard let projects = buckets[groupKey] else { continue }
                result.append(ProjectGroup(
                    id: "\(pinned ? "pinned" : "projects")-\(groupKey)",
                    title: prefix + groupKey,
                    projects: projects
                ))
            }
        }
        return result
    }

    private func activityGroups(_ folders: [Project]) -> [ProjectGroup] {
        let titles = ["ACTIVE NOW", "RECENT ACTIVITY", "OTHER PROJECTS"]
        func activityTitle(for project: Project) -> String {
            if project.sessions.contains(where: { store.statuses[$0.id] == .working }) {
                return titles[0]
            }
            return store.liveActivity[project.id] == nil ? titles[2] : titles[1]
        }

        var result: [ProjectGroup] = []
        for (pinned, prefix) in [(true, "PINNED · "), (false, "")] {
            let projects = folders.filter { $0.pinned == pinned }
            for title in titles {
                let bucket = projects.filter { activityTitle(for: $0) == title }
                guard !bucket.isEmpty else { continue }
                result.append(ProjectGroup(
                    id: "\(pinned ? "pinned" : "projects")-\(title)",
                    title: prefix + title,
                    projects: bucket
                ))
            }
        }
        return result
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
    private func splitLinkMarks(for project: Project) -> [Session.ID: SplitLinkMark] {
        guard !store.splitGroups.isEmpty else { return [:] }
        var groupOf: [Session.ID: Int] = [:]
        for (index, group) in store.splitGroups.enumerated() {
            for id in group.leafIDs { groupOf[id] = index }
        }
        var marks: [Session.ID: SplitLinkMark] = [:]
        var run: [Session.ID] = []
        var runGroup: Int?
        func closeRun() {
            if run.count > 1 {
                marks[run.first!] = .top
                for id in run.dropFirst().dropLast() { marks[id] = .middle }
                marks[run.last!] = .bottom
            }
            run.removeAll()
        }
        for session in project.sessions {
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

/// A small in-list label makes active project grouping scannable without bringing
/// back List section spacing or a full-width card treatment.
private struct ProjectGroupLabel: View {
    let title: String
    let chrome: ChromeTheme?

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground.opacity(0.55)) }
                ?? AnyShapeStyle(.secondary))
            .padding(.top, 8)
            .padding(.bottom, 2)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 8))
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


/// A project's section header. The agent quick-add buttons float in a trailing
/// overlay rather than the row's flow, so at rest the label gets the full row width
/// (no premature truncation) and the buttons only paint over the trailing edge on
/// hover — like VSCode's explorer header actions. Each button immediately creates a
/// session of that agent type.
private struct ProjectHeader: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    let project: Project
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    let chrome: ChromeTheme?
    @State private var isHovering = false
    /// True while this header's right-click menu is open, so the row paints a light
    /// lift marking it as the menu's target.
    @State private var isMenuOpen = false

    /// Width the trailing agent icons occupy (button frame 22 + 3 spacing each), so
    /// the hovered label can fade out exactly under them rather than guessing.
    /// Zero for the Terminals section, which offers no agent quick-add.
    private var agentIconClusterWidth: CGFloat {
        guard project.kind != .terminals else { return 0 }
        let count = enabledAgentPresets(settings).count
        guard count > 0 else { return 0 }
        return CGFloat(count) * 22 + CGFloat(count - 1) * 3
    }

    /// The right-click menu: a "New … Session" entry per enabled agent, then the
    /// project's own actions. Mirrors the hover controls so both routes stay in sync.
    /// The Terminals section is not a folder project — agents don't belong in `$HOME`
    /// (they get a real project or the scoped scratch workspace), and worktree /
    /// sandbox / Finder actions are about a project's directory — so its menu is
    /// just the terminal action and Close All Terminals.
    private var projectMenuItems: [SidebarMenuItem] {
        if project.kind == .terminals {
            return [
                .action("New Terminal") { store.addSession(to: project.id, agent: .terminal) },
                .separator,
                .action("Close All Terminals") { store.removeProject(project.id) },
            ]
        }
        var items: [SidebarMenuItem] = enabledAgentPresets(settings).map { preset in
            .action("New \(preset.displayName) Session") {
                store.addSession(to: project.id, agent: preset)
            }
        }
        // Create a fresh detached git worktree of this repo and add it to the sidebar
        // as its own top-level entry — no session is started; you add those yourself.
        // Only for git repositories (a worktree needs one; "—" marks a non-repo folder).
        if project.branch != "—" {
            items.append(.action("New Worktree") { store.addWorktree(from: project.id) })
        }
        items.append(.separator)
        items.append(.action(project.pinned ? "Unpin" : "Pin to Top") {
            store.togglePinned(project.id)
        })
        items.append(.action("Security…") { store.editingSecurityProjectID = project.id })
        items.append(.action("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
        })
        items.append(.separator)
        items.append(.action("Remove Project") { store.removeProject(project.id) })
        return items
    }

    var body: some View {
        HStack(spacing: 6) {
            // Same 16-wide icon slot and spacing as SessionRow, so the folder mark
            // and the session icons below it share one vertical column (and the
            // header label lines up with the session titles). The folder itself is
            // the open/closed affordance — an open folder when the project's sessions
            // are showing, a closed one when folded — so no separate chevron is
            // needed (clicking the header still toggles it). The Terminals section
            // is not a folder, so it carries the terminal glyph in both states.
            HugeIconView(
                icon: project.kind == .terminals ? .terminal
                    : (isCollapsed ? .folder : .folderOpen),
                size: 15,
                color: chrome?.foreground ?? .primary
            )
            .frame(width: 16)
            // A section header, but kept at the standard text color (not the muted
            // grey VSCode uses) so the project name reads clearly; the smaller,
            // uppercase, letter-spaced styling still sets it apart from session rows.
            Text(project.name)
                .font(.system(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary))
            // A small pin mark when the project is pinned to the top, so the reason it
            // floats above the sort order reads at a glance (toggled from the row's
            // right-click menu). Muted so it sits quietly next to the name.
            if project.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Pinned to top")
            }
            // A quiet "Sandbox" tag when this project runs under a Seatbelt profile —
            // borrows the same soft quaternary capsule as the title-bar chips. Clicking it
            // opens the Security panel (the same sheet the right-click menu offers), so the
            // pill doubles as the at-rest entry point. Shown once on the header.
            if project.sandbox != nil {
                Button {
                    store.editingSecurityProjectID = project.id
                } label: {
                    Text("Sandbox")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(.quaternary))
                }
                .buttonStyle(.plain)
                .help("Sandbox settings")
            }
            Spacer(minLength: 4)
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
                Color.clear.frame(width: isHovering ? agentIconClusterWidth + 6 : 0)
            }
        )
        // The hover actions sit in an overlay, not the HStack above, so they reserve
        // no width while hidden — the label keeps the whole row at rest. One brand
        // icon per enabled agent (a single click opens that agent, instantly
        // recognizable — the agents are few and visually distinct, so direct icons
        // beat a dropdown). The project's own rarer actions (Reveal in Finder, Remove
        // Project) live in the right-click context menu below rather than an inline
        // button, keeping the hover row to just the agent icons.
        .overlay(alignment: .trailing) {
            // The Terminals section gets no agent cluster — an agent loose in `$HOME`
            // is exactly what the scoped scratch workspace exists to prevent.
            if project.kind != .terminals {
                HStack(spacing: 3) {
                    ForEach(enabledAgentPresets(settings)) { preset in
                        AgentQuickAddButton(preset: preset, chrome: chrome) {
                            store.addSession(to: project.id, agent: preset)
                        }
                    }
                }
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { toggleCollapsed() }
        // Right-click mirrors the hover controls, so every action is reachable both
        // ways. Built as an `NSMenu` (see `SidebarRowContextMenu`) rather than
        // SwiftUI's `.contextMenu`, which paints an un-styleable blue accent ring
        // around the targeted row. While the menu is up the row lifts to the hover
        // level (a step below session selection) so the target reads clearly.
        .background(SidebarRowContextMenu(items: projectMenuItems) { isMenuOpen = $0 })
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

/// The agents a project header offers as new sessions: every preset the user has
/// left enabled, in preset order.
@MainActor
func enabledAgentPresets(_ settings: AppSettings) -> [AgentPreset] {
    AgentPreset.allCases.filter(settings.isAgentEnabled)
}

/// One entry in a sidebar row's right-click menu — a titled action or a separator.
enum SidebarMenuItem {
    case action(String, () -> Void)
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
            let menu = NSMenu()
            menu.delegate = self
            for item in items {
                switch item {
                case .separator:
                    menu.addItem(.separator())
                case let .action(title, handler):
                    let menuItem = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
                    menuItem.target = self
                    menuItem.representedObject = Handler(handler)
                    menu.addItem(menuItem)
                }
            }
            menu.popUp(positioning: nil, at: recognizer.location(in: hostView), in: hostView)
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
    @State private var isHovering = false

    private var isSelected: Bool { store.selectedSessionID == session.id }

    var body: some View {
        HStack(spacing: 6) {
            // While the agent is working, the leading mark becomes a small rotating
            // nine-dot grid — the row's own "thinking" spinner — and reverts to the
            // brand mark when the turn ends. No ambient tint on the brand mark: it
            // must keep its own vendor color (the same full-strength logo the
            // settings page shows), and the plain terminal symbol carries its own
            // muted grey from AgentIconView.
            Group {
                if session.isBrowser {
                    // A browser pane has no agent to badge (and never "works"),
                    // so it carries a plain globe in the terminal glyph's grey.
                    Image(systemName: "globe")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if store.status(for: session.id) == .working {
                    WorkingIndicator(tint: session.agent.tintColor)
                } else {
                    AgentIconView(agent: session.agent, size: 13)
                }
            }
            .frame(width: 16)
            .help(store.statusDescription(for: session.id))
            Text(store.displayTitle(for: session))
                .font(settings.interfaceFont)
                .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // At rest a status dot trails the title only when the session needs the
            // user (working is shown by the leading spinner instead), so the title
            // keeps nearly the whole row width. The hover actions live in the overlay
            // below and reserve no flow width of their own.
            StatusDot(status: store.status(for: session.id))
                .frame(width: 16)
                .opacity(isHovering ? 0 : 1)
                .help(store.statusDescription(for: session.id))
        }
        // VSCode-style trailing actions: hovering paints them over the trailing edge
        // (where the status dot was), reserving no resting width. Creating a worktree
        // is a folder-level action now (the project header's "New worktree" button),
        // so a session row carries only its close button.
        .overlay(alignment: .trailing) {
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
        .padding(.vertical, settings.interfaceRowPadding)
        // Indent the session content under its project header (or its worktree
        // folder node) so the rows read as a child group rather than a flat sibling
        // list. The selection highlight (listRowBackground) stays full-width — the
        // standard macOS source-list look where children inset but the lift spans
        // the row.
        .padding(.leading, leadingIndent)
        // The split-group bracket lives in the indent gutter the padding above just
        // opened, so it marks grouped rows without shifting any row content.
        .overlay(alignment: .leading) {
            if let splitLink {
                SplitLinkGlyph(mark: splitLink, chrome: chrome)
                    .frame(width: leadingIndent)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            // Tapping a session in the sidebar always returns to its terminal — close the file
            // editor even when this row is already selected (no selection change to react to).
            store.openFileURL = nil
            store.selectedSessionID = session.id
        }
        // NSMenu rather than SwiftUI's `.contextMenu` so right-click leaves no blue
        // accent ring on the row (see `SidebarRowContextMenu`).
        .background(SidebarRowContextMenu(items: [
            .action("Rename Session…") { store.renameSession(session.id) },
            .separator,
            .action("Close Session") { store.closeSession(session.id) }
        ]))
        .listRowBackground(
            SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isSelected)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
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
private struct WorkingIndicator: View {
    var tint: Color = .secondary

    /// The eight perimeter cells of the 3×3 grid in clockwise order, as
    /// `(column, row)` with the center at `(1, 1)`. The comet travels this ring.
    private static let ring: [(Int, Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]
    private let dotSize: CGFloat = 2.3
    private let spacing: CGFloat = 3.6
    private let period: Double = 1.1

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            ZStack {
                // A faint steady center anchors the spinning ring.
                dot(opacity: 0.45)
                ForEach(Array(Self.ring.enumerated()), id: \.offset) { index, cell in
                    dot(opacity: opacity(at: index, phase: phase))
                        .offset(
                            x: CGFloat(cell.0 - 1) * spacing,
                            y: CGFloat(cell.1 - 1) * spacing
                        )
                }
            }
            .frame(width: 13, height: 13)
        }
    }

    private func dot(opacity: Double) -> some View {
        Circle()
            .fill(tint)
            .frame(width: dotSize, height: dotSize)
            .opacity(opacity)
    }

    /// Brightness of a perimeter cell: peaks at the comet's head and fades over the
    /// next few cells, measured as the shorter way around the ring so the tail wraps.
    private func opacity(at index: Int, phase: Double) -> Double {
        let count = Double(Self.ring.count)
        let head = phase * count
        let raw = abs(Double(index) - head)
        let distance = min(raw, count - raw)
        return max(0.4, 1 - distance / 3)
    }
}

/// Per-project sandbox configuration, opened from a project's right-click "Security…"
/// item or its "Sandbox" pill. A direct view over the project's `SandboxProfile` (edited
/// through `TermioStore.updateSandbox`) — there is no separate model. Edits apply to
/// sessions opened after the change, matching how the sandbox toggle has always behaved.
struct SecuritySheet: View {
    @EnvironmentObject var store: TermioStore
    let projectID: Project.ID

    private var project: Project? { store.projects.first { $0.id == projectID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(20) }
                .frame(maxHeight: 460)
            Divider()
            HStack {
                Spacer()
                Button("Done") { store.editingSecurityProjectID = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 470)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Security").font(.headline)
            if let project {
                Text(project.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder private var content: some View {
        Toggle(isOn: sandboxOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run this project's sessions in a sandbox").font(.system(size: 13, weight: .medium))
                Text("Confines the agent to the project folder. Your SSH keys, the login Keychain, and the rest of your home stay invisible.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)

        if sandboxOn.wrappedValue {
            sandboxSettings
        } else {
            Label {
                Text("This project's agents run with full access to your Mac — they can read your keys, credentials, and any file your account can.")
                    .font(.system(size: 11))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .padding(.top, 14)
        }
    }

    @ViewBuilder private var sandboxSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Filesystem") {
                Toggle("Let the agent edit the project files", isOn: bindInverse(\.workspaceReadOnly))
                caption("Off makes the workspace read-only — the agent can look but not touch.")
            }
            section("Secrets") {
                Toggle("Hide .env files from the agent", isOn: bind(\.blockDotEnv, true))
                caption("Blocks reading .env / .env.* even inside the project. May stop commands that load them (e.g. a dev server) from starting.")
                Toggle("Allow SSH keys (~/.ssh)", isOn: bind(\.allowSSH, false))
                Toggle("Allow reading your entire home folder", isOn: bind(\.allowFullHomeRead, false))
                    .tint(.orange)
            }
            section("Network") {
                Picker("Network access", selection: bind(\.network, .full)) {
                    Text("Full").tag(SandboxProfile.Network.full)
                    Text("Off").tag(SandboxProfile.Network.off)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                caption("Off blocks all network — most agents need Full to reach their model API.")
            }
        }
        .padding(.top, 16)
    }

    private func section(_ title: String, @ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
            rows()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: bindings into the project's profile (valid only while sandboxed)

    private var sandboxOn: Binding<Bool> {
        Binding(
            get: { store.sandboxProfile(for: projectID) != nil },
            set: { store.setSandbox($0, for: projectID) }
        )
    }

    private func bind<T>(_ keyPath: WritableKeyPath<SandboxProfile, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { store.sandboxProfile(for: projectID)?[keyPath: keyPath] ?? fallback },
            set: { value in store.updateSandbox(for: projectID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func bindInverse(_ keyPath: WritableKeyPath<SandboxProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { !(store.sandboxProfile(for: projectID)?[keyPath: keyPath] ?? false) },
            set: { value in store.updateSandbox(for: projectID) { $0[keyPath: keyPath] = !value } }
        )
    }
}
