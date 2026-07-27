import AppKit
import SwiftUI

/// Which palette is up. otty/VS Code's split: Open Quickly (⌘⇧O) jumps to
/// *things* — sessions, recent projects, files — while the Command Palette
/// (⌘⇧P) runs *verbs* — app actions. One panel, two modes; mixing both in a
/// single list buries the actions under a wall of same-named sessions and
/// muddles the mental model.
enum PaletteMode {
    case openQuickly
    case commands
    /// Live theme browsing (opened from the "Change Theme…" command). Edits only
    /// the slot matching the current appearance, previews on highlight, commits on
    /// Return, and reverts on Esc — the terminal is the preview surface.
    case themes
}

/// The shared palette panel behind ⌘⇧O (Open Quickly) and ⌘⇧P (Command
/// Palette). One searchable list, fuzzy-matched (otty-style subsequence
/// scoring — word-boundary and consecutive hits win; no learned ranking).
///
/// Open Quickly sections: every session, recently-closed projects, and — once
/// a query is typed — the current project's files (`git ls-files`, so ignore
/// rules apply). The Command Palette lists every app action with its shortcut;
/// ⌘↩ runs one and keeps the palette open for chaining (otty's behaviour).
///
/// Presented in its own floating `NSPanel` (see `AppDelegate`), Xcode
/// Open-Quickly style, NOT as a SwiftUI overlay: the terminal surfaces are
/// NSViews, and AppKit draws child NSViews above the hosting view's SwiftUI
/// canvas — an in-tree overlay renders *underneath* the terminals no matter
/// its ZStack order. A panel also gets keyboard focus for free (it becomes the
/// key window), and floats with no backdrop dimming.
///
/// Keyboard: a *local* keyDown monitor consumes ↑/↓/Return/Esc before the
/// responder chain can hand them to the search field, and the search field
/// claims focus with a short retry loop.
struct CommandPaletteView: View {
    @EnvironmentObject var store: TermioStore
    let onClose: () -> Void

    /// The panel's fixed size — stable like VS Code's palette, whatever the
    /// result count; the list scrolls inside.
    static let panelSize = CGSize(width: 560, height: 400)

    /// File-listing cap: enough for any sane repo, a guardrail for monorepos.
    private static let fileLimit = 5000
    /// How many file matches show per query — files are the long tail, and
    /// past this the user should just keep typing.
    private static let fileMatchLimit = 20

    @State private var query = ""
    @State private var highlighted = 0
    @State private var keyMonitor: Any?
    @State private var projectFiles: [ProjectFile] = []
    /// The slot theme in use when theme browsing began, restored on Esc/dismiss so
    /// arrow-key preview is no-risk. `nil` whenever the palette isn't browsing themes.
    @State private var themeSnapshot: String?
    /// Set once the user commits a theme (Return/click) so leaving the mode keeps it
    /// instead of reverting to the snapshot.
    @State private var themeCommitted = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            itemList
        }
        // No background here: SwiftUI materials only sample within their own
        // window, and this panel contains nothing but the palette — they'd
        // collapse to an opaque grey. The glass backdrop lives on the panel's
        // AppKit contentView (see `AppDelegate.paletteBackdrop`).
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .onAppear {
            installKeyMonitor()
            claimSearchFocus(attempt: 0)
            loadProjectFiles()
        }
        .onDisappear {
            removeKeyMonitor()
            // A live preview the panel is torn down mid-browse (dismissed by
            // clicking away) still needs reverting.
            endThemeBrowsing(commit: themeCommitted)
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        // Pressing the other shortcut while open switches modes in place —
        // stale search text from the previous mode would just show "No matches".
        .onChange(of: store.paletteMode) { old, new in
            // Leaving themes without committing restores the snapshot.
            if old == .themes, new != .themes { endThemeBrowsing(commit: themeCommitted) }
            query = ""
            highlighted = 0
            if new == .themes { beginThemeBrowsing() }
            loadProjectFiles()
        }
        // Live-preview the highlighted theme on the open terminals as the user
        // arrows/hovers through the list (same recolor path as Settings).
        .onChange(of: highlighted) { _, index in
            guard mode == .themes, themeSnapshot != nil else { return }
            let items = filtered
            guard items.indices.contains(index),
                  case .theme(let name) = items[index].kind else { return }
            setCurrentSlotTheme(name)
        }
    }

    /// The presented mode. The store owns it so the View-menu shortcuts can
    /// flip modes while the panel stays up; `.commands` covers the nil gap
    /// during dismissal.
    private var mode: PaletteMode { store.paletteMode ?? .commands }

    private var placeholder: String {
        switch mode {
        case .openQuickly: return "Jump to session, project, or file…"
        case .commands: return "Run a command…"
        case .themes: return "Search themes…"
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 20))
            .focused($searchFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    let items = filtered
                    // Headers only when the list actually spans sections —
                    // a lone "Sessions" banner over everything is noise.
                    let sectioned = Set(items.map(\.section)).count > 1
                    if items.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if sectioned, index == 0 || items[index - 1].section != item.section,
                           let title = item.section.title {
                            sectionHeader(title)
                        }
                        // Identity must stay the item's id: an .id(index)
                        // override makes row 0 "the same view" across queries,
                        // and LazyVStack then reuses its cached content — the
                        // list freezes on stale rows while filtering.
                        PaletteRow(item: item, isHighlighted: index == highlighted)
                            .id(item.id)
                            .onTapGesture { run(item) }
                            .onHover { inside in if inside { highlighted = index } }
                    }
                }
                .padding(6)
            }
            .onChange(of: highlighted) { _, index in
                let items = filtered
                if items.indices.contains(index) {
                    proxy.scrollTo(items[index].id, anchor: nil)
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    // MARK: - Items

    private var allItems: [PaletteItem] {
        switch mode {
        case .openQuickly: return openQuicklyItems
        case .commands: return commandItems
        case .themes: return themeItems
        }
    }

    private var openQuicklyItems: [PaletteItem] {
        var items: [PaletteItem] = []
        for project in store.orderedProjects {
            for session in project.sessions {
                items.append(.init(
                    id: "session-\(session.id.uuidString)",
                    kind: .session(session),
                    section: .sessions,
                    title: store.displayTitle(for: session),
                    subtitle: project.name
                ))
            }
        }
        // Only folders that aren't already open — the open ones are reachable
        // through their sessions above.
        let openPaths = Set(store.projects.map(\.path))
        for recent in store.settings.recentProjects where !openPaths.contains(recent.path) {
            items.append(.init(
                id: "recent-\(recent.path)",
                kind: .recentProject(recent),
                section: .recentProjects,
                title: recent.name,
                subtitle: (recent.path as NSString).abbreviatingWithTildeInPath
            ))
        }
        for file in projectFiles {
            items.append(.init(
                id: "file-\(file.relative)",
                kind: .file(file),
                section: .files,
                title: file.url.lastPathComponent,
                subtitle: file.relative,
                searchKey: file.relative
            ))
        }
        return items
    }

    private var commandItems: [PaletteItem] {
        availableActions.map { action in
            .init(id: "action-\(action.id)", kind: .action(action),
                  section: .commands, title: action.title, subtitle: nil,
                  shortcut: action.shortcut)
        }
    }

    /// Every app action, minus the ones that could only no-op right now (the
    /// pane verbs need a pane), so the list never advertises dead rows.
    private var availableActions: [PaletteAction] {
        var actions: [PaletteAction] = []
        let keys = KeybindingStore.shared
        if store.selectedSessionID != nil {
            actions.append(.init(id: "split-right", title: "Split Right",
                                 icon: .layoutColumns, shortcut: keys.display(for: .splitRight)) {
                $0.splitSelectedPane(.horizontal)
            })
            actions.append(.init(id: "split-down", title: "Split Down",
                                 icon: .layoutRows, shortcut: keys.display(for: .splitDown)) {
                $0.splitSelectedPane(.vertical)
            })
        }
        if store.splitRoot != nil {
            actions.append(.init(id: "zoom-split", title: "Zoom Split",
                                 icon: .expand,
                                 shortcut: keys.display(for: .splitZoom)) {
                $0.toggleSelectedPaneZoom()
            })
            actions.append(.init(id: "ungroup", title: "Ungroup",
                                 icon: .square, shortcut: keys.display(for: .ungroup)) {
                $0.ungroupSelectedPane()
            })
            for (id, command, selector) in [
                ("focus-left", KeyCommandID.focusPaneLeft, #selector(AppDelegate.focusPaneLeft(_:))),
                ("focus-right", .focusPaneRight, #selector(AppDelegate.focusPaneRight(_:))),
                ("focus-up", .focusPaneUp, #selector(AppDelegate.focusPaneUp(_:))),
                ("focus-down", .focusPaneDown, #selector(AppDelegate.focusPaneDown(_:))),
            ] {
                actions.append(.init(id: id, title: KeyCommandCatalog.info(command).title,
                                     icon: .arrowsLeftRight,
                                     shortcut: keys.display(for: command)) { _ in
                    NSApp.sendAction(selector, to: nil, from: nil)
                })
            }
        }
        actions.append(.init(id: "new-terminal", title: "New Terminal",
                             icon: .plusSquare, shortcut: keys.display(for: .newTerminal)) {
            $0.addScratchTerminal()
        })
        // The single "New Chat" verb (default agent, always the scratch Chats
        // funnel), carrying its ⌘N shortcut — the palette twin of File ▸ New Chat.
        if store.defaultChatAgent() != nil {
            actions.append(.init(id: "new-chat", title: "New Chat",
                                 icon: .bubbleChatAdd, shortcut: keys.display(for: .newChat)) {
                $0.addDefaultChat()
            })
        }
        // One "New … Session" verb per enabled agent — in the selected
        // project when there is one, else the scratch workspace (the welcome
        // page's behaviour).
        for agent in enabledAgentPresets(store.settings) where agent != .terminal {
            actions.append(.init(id: "new-session-\(agent.id)",
                                 title: "New \(agent.displayName) Session",
                                 icon: nil, agent: agent, shortcut: nil) { store in
                if let sid = store.selectedSessionID, let project = store.project(for: sid) {
                    store.addSession(to: project.id, agent: agent)
                } else {
                    store.addScratchSession(agent: agent)
                }
            })
        }
        actions.append(.init(id: "new-ssh", title: "New SSH Connection…",
                             icon: .network, shortcut: nil) {
            $0.presentSSHConnectPanel()
        })
        actions.append(.init(id: "open-project", title: "Open Project…",
                             icon: .folder, shortcut: keys.display(for: .openProject)) {
            $0.presentOpenProjectPanel()
        })
        // One shared "Aa" glyph for the font-size trio: Hugeicons has no
        // larger/smaller/reset variants, so the titles carry the distinction.
        for (id, title, command, selector) in [
            ("font-increase", "Increase Font Size",
             KeyCommandID.increaseFontSize, #selector(AppDelegate.increaseFontSize(_:))),
            ("font-decrease", "Decrease Font Size",
             .decreaseFontSize, #selector(AppDelegate.decreaseFontSize(_:))),
            ("font-reset", "Reset Font Size",
             .resetFontSize, #selector(AppDelegate.resetFontSize(_:))),
        ] {
            actions.append(.init(id: id, title: title, icon: .textFont,
                                 shortcut: keys.display(for: command)) { _ in
                NSApp.sendAction(selector, to: nil, from: nil)
            })
        }
        actions.append(.init(id: "toggle-sidebar", title: "Toggle Sidebar",
                             icon: .sidebarLeft, shortcut: nil) { _ in
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        })
        actions.append(.init(id: "toggle-files", title: "Toggle Project Files",
                             icon: .sidebarRight, shortcut: keys.display(for: .toggleProjectFiles)) { _ in
            NSApp.sendAction(#selector(AppDelegate.toggleFilesInspector(_:)), to: nil, from: nil)
        })
        actions.append(.init(id: "change-theme", title: "Change Theme…",
                             icon: nil, symbol: "paintpalette", shortcut: nil,
                             switchesMode: .themes) { _ in })
        actions.append(.init(id: "settings", title: "Settings…",
                             icon: .settings, shortcut: "⌘,") { _ in
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
        })
        actions.append(.init(id: "check-updates", title: "Check for Updates…",
                             icon: .refresh, shortcut: nil) { _ in
            NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)
        })
        if AppChannel.isDev {
            // Faithful fault injector for the hollow-cursor race. Once this panel has
            // closed, TerminalPane finds the selected terminal's real AppKit view,
            // makes it first responder, then resigns it while the main window stays
            // key. Fix ON → focus is reasserted on the next runloop; fix OFF → the
            // cursor stays hollow. Watch the `focus` log category for both events.
            actions.append(.init(id: "debug-orphan-focus", title: "Debug: Orphan Terminal Focus",
                                 icon: .cursorDisabled, shortcut: nil) { _ in
                Log.focus.info("fault injector: invoked, posting first-responder orphan in 0.35s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .termioDebugOrphanFocus, object: nil)
                }
            })
        }
        return actions
    }

    // MARK: - Themes

    /// The theme selector's rows: a "Terminal default" reset, the user's own
    /// same-brightness custom themes, then the bundled catalog with the popular
    /// picks pulled to the front. Only themes matching the slot's brightness show,
    /// so the palette can never apply one that renders the wrong way.
    private var themeItems: [PaletteItem] {
        let dark = slotIsDark
        let popular = dark ? ThemeLibrary.popularDarkThemeNames : ThemeLibrary.popularLightThemeNames
        let bundled = dark ? ThemeLibrary.darkBundledThemeNames : ThemeLibrary.lightBundledThemeNames
        let custom = ThemeLibrary.userThemeNames.filter { ThemeLibrary.theme(named: $0)?.isDark == dark }

        var items: [PaletteItem] = custom.map { themeItem(name: $0, section: .customThemes) }
        // Return-to-default sits atop the main group; popular first, then the
        // alphabetical remainder with popular removed so nothing repeats. The
        // label names the slot being edited so "default" isn't ambiguous.
        items.append(themeItem(name: "", title: dark ? "Default Dark Theme" : "Default Light Theme"))
        items += popular.map { themeItem(name: $0) }
        let popularSet = Set(popular)
        items += bundled.filter { !popularSet.contains($0) }.map { themeItem(name: $0) }
        return items
    }

    private func themeItem(name: String, title: String? = nil,
                           section: PaletteSection = .themes) -> PaletteItem {
        .init(id: "theme-\(name.isEmpty ? "__default__" : name)",
              kind: .theme(name: name), section: section,
              title: title ?? name, subtitle: nil)
    }

    /// Which slot the palette edits — the one the terminals render right now, so
    /// changing "the theme" changes what's on screen. Mirrors how the surfaces pick
    /// a slot: pinned modes are fixed, System follows the effective appearance.
    private var slotIsDark: Bool {
        switch store.settings.appearanceMode {
        case .light: return false
        case .dark: return true
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    private var currentSlotThemeName: String {
        slotIsDark ? store.settings.darkThemeName : store.settings.lightThemeName
    }

    /// Writes the current slot's theme, which fires `AppSettings.objectWillChange`
    /// and recolors every open surface (see `applyAppearanceToOpenSurfaces`).
    private func setCurrentSlotTheme(_ name: String) {
        if slotIsDark {
            store.settings.darkThemeName = name
        } else {
            store.settings.lightThemeName = name
        }
    }

    private func beginThemeBrowsing() {
        themeSnapshot = currentSlotThemeName
        themeCommitted = false
        // Land the highlight on the theme already in use so browsing starts from the
        // current look and the seed-preview is a no-op.
        let current = currentSlotThemeName
        highlighted = themeItems.firstIndex {
            if case .theme(let name) = $0.kind { return name == current }
            return false
        } ?? 0
    }

    private func endThemeBrowsing(commit: Bool) {
        if !commit, let snapshot = themeSnapshot { setCurrentSlotTheme(snapshot) }
        themeSnapshot = nil
        themeCommitted = false
    }

    /// Fuzzy filter + rank. Empty query shows the browsable sets (sessions,
    /// recents, every command) but no files — 5000 unranked paths is a wall,
    /// and files only mean anything once the user starts describing one.
    private var filtered: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return allItems.filter { $0.section != .files }
        }
        var fileCount = 0
        return allItems
            .enumerated()
            .compactMap { index, item -> (item: PaletteItem, index: Int, score: Int)? in
                guard let score = FuzzySearch.score(trimmed, in: item.searchKey) else { return nil }
                return (item, index, score)
            }
            // Section first (things before the file long-tail), then score;
            // the original index keeps the sort stable.
            .sorted {
                ($0.item.section.rawValue, -$0.score, $0.index)
                    < ($1.item.section.rawValue, -$1.score, $1.index)
            }
            .filter { entry in
                guard entry.item.section == .files else { return true }
                fileCount += 1
                return fileCount <= Self.fileMatchLimit
            }
            .map(\.item)
    }

    private func run(_ item: PaletteItem, keepOpen: Bool = false) {
        // Mode-switch commands (Change Theme…) re-drive the open panel into a new
        // mode rather than closing it.
        if case .action(let action) = item.kind, let target = action.switchesMode {
            store.paletteMode = target
            return
        }
        // Commit a theme before dismissing, so leaving the mode keeps it instead
        // of reverting to the snapshot.
        if case .theme(let name) = item.kind {
            setCurrentSlotTheme(name)
            themeCommitted = true
        }
        if !keepOpen { onClose() }
        switch item.kind {
        case .session(let session):
            store.selectedSessionID = session.id
        case .recentProject(let recent):
            // Reopens a closed folder or selects an already-open one — the
            // welcome page's one-click semantics.
            store.addProject(at: URL(fileURLWithPath: recent.path))
        case .file(let file):
            store.openFileInEditor(file.url)
        case .action(let action):
            action.perform(store)
        case .theme:
            break // already applied above
        }
    }

    // MARK: - Project files

    /// The project whose files ⌘⇧O searches: the selected session's, falling
    /// back to the most recently active one when nothing is selected.
    private var currentProject: Project? {
        if let sid = store.selectedSessionID, let project = store.project(for: sid) {
            return project
        }
        return store.orderedProjects.first
    }

    /// Lists the current project's files off the main thread. Loaded once per
    /// palette presentation — the working tree won't meaningfully change in
    /// the seconds a palette is up.
    private func loadProjectFiles() {
        guard mode == .openQuickly, projectFiles.isEmpty,
              let root = currentProject.map({ URL(fileURLWithPath: $0.path) }) else { return }
        let limit = Self.fileLimit
        Task.detached(priority: .userInitiated) {
            let files = FuzzySearch.listFiles(under: root, limit: limit)
            await MainActor.run { projectFiles = files }
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Esc
                onClose()
                return nil
            case 125: // ↓
                highlighted = min(highlighted + 1, max(filtered.count - 1, 0))
                return nil
            case 126: // ↑
                highlighted = max(highlighted - 1, 0)
                return nil
            case 36, 76: // Return / keypad Enter; ⌘↩ chains (palette stays up)
                let items = filtered
                if items.indices.contains(highlighted) {
                    run(items[highlighted], keepOpen: event.modifierFlags.contains(.command))
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The terminal surface fights for first responder; keep asking for a few
    /// ticks until the field actually has it (muxy's focus-retry gotcha).
    private func claimSearchFocus(attempt: Int) {
        guard attempt < 8 else { return }
        searchFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(attempt + 1)) {
            if !searchFocused { claimSearchFocus(attempt: attempt + 1) }
        }
    }
}

// MARK: - Model

/// Open Quickly's display groups, in rank order; `.commands` is the palette's
/// single (headerless) group.
private enum PaletteSection: Int, Hashable {
    case sessions, recentProjects, files, commands, customThemes, themes

    var title: String? {
        switch self {
        case .sessions: return "Sessions"
        case .recentProjects: return "Recent"
        case .files: return "Files"
        case .commands: return nil
        case .customThemes: return "Custom"
        // No header when custom themes are absent (the common case) — a lone
        // "Themes" banner over the whole list is noise (see `sectioned`).
        case .themes: return "Themes"
        }
    }
}

private struct PaletteItem: Identifiable {
    enum Kind {
        case session(Session)
        case recentProject(RecentProject)
        case file(ProjectFile)
        case action(PaletteAction)
        /// A terminal theme name (empty = "Terminal default").
        case theme(name: String)
    }

    let id: String
    let kind: Kind
    let section: PaletteSection
    let title: String
    let subtitle: String?
    var shortcut: String?
    /// What the fuzzy matcher sees — defaults to title + subtitle; files
    /// override it with the relative path so directory names match too.
    var searchKey: String

    init(id: String, kind: Kind, section: PaletteSection, title: String,
         subtitle: String?, shortcut: String? = nil, searchKey: String? = nil) {
        self.id = id
        self.kind = kind
        self.section = section
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.searchKey = searchKey ?? [title, subtitle ?? ""].joined(separator: " ")
    }
}

/// One runnable app action. A plain struct (not an enum) so the list can be
/// assembled dynamically — the "New … Session" verbs come from the enabled
/// agent roster, not a fixed case list. Store-backed actions call the store;
/// window-level ones (settings, inspector, updates) route through the
/// responder chain to `AppDelegate`, exactly as their menu items do.
private struct PaletteAction: Identifiable {
    let id: String
    let title: String
    /// Hugeicons glyph, or nil when `agent` supplies a brand icon instead.
    let icon: HugeIcon?
    /// An SF Symbol name, used in place of `icon` when a system glyph reads better
    /// than any Hugeicon (e.g. `paintpalette` for Change Theme…, matching the
    /// Appearance settings). Takes precedence over `icon` when set.
    var symbol: String?
    var agent: AgentPreset?
    let shortcut: String?
    /// Set when the command switches the palette into another mode in place (e.g.
    /// Change Theme…) rather than running and dismissing; `perform` is then unused.
    var switchesMode: PaletteMode?
    let perform: @MainActor (TermioStore) -> Void

    init(id: String, title: String, icon: HugeIcon?, symbol: String? = nil,
         agent: AgentPreset? = nil, shortcut: String?, switchesMode: PaletteMode? = nil,
         perform: @escaping @MainActor (TermioStore) -> Void) {
        self.id = id
        self.title = title
        self.icon = icon
        self.symbol = symbol
        self.agent = agent
        self.shortcut = shortcut
        self.switchesMode = switchesMode
        self.perform = perform
    }
}

// MARK: - Row

private struct PaletteRow: View {
    @EnvironmentObject var store: TermioStore
    let item: PaletteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18)
            Text(item.title)
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            trailing
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        if case .session(let session) = item.kind, store.selectedSessionID == session.id {
            Text("current")
                .font(.system(size: 10))
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
        } else if let shortcut = item.shortcut {
            Text(shortcut)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .session(let session):
            AgentIconView(agent: session.agent, size: 14)
        case .recentProject:
            hugeIcon(.clock)
        case .file:
            hugeIcon(.fileDoc)
        case .action(let action):
            if let agent = action.agent {
                AgentIconView(agent: agent, size: 14)
            } else if let symbol = action.symbol {
                symbolIcon(symbol)
            } else {
                hugeIcon(action.icon ?? .terminal)
            }
        case .theme(let name):
            // The theme's own colors are its icon — Warp-style, so the list reads
            // as swatches. The default row (no definition) shows the palette glyph.
            if let definition = ThemeLibrary.theme(named: name) {
                ThemeSwatch(definition: definition, compact: true)
            } else {
                symbolIcon("paintpalette")
            }
        }
    }

    private func symbolIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
    }

    private func hugeIcon(_ icon: HugeIcon) -> some View {
        HugeIconView(icon: icon, size: 13, color: isHighlighted ? .white : .secondary)
    }
}
