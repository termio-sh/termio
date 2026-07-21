import Combine
import Foundation

/// Terminal cursor shape. Raw values are deliberately the exact Ghostty config
/// tokens, so persistence, the settings picker, and the `TermioStore` mapping all
/// share one type without any string literals drifting apart.
enum CursorStyle: String, CaseIterable, Identifiable {
    case block
    case bar
    case underline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .block: return "Block"
        case .bar: return "Bar"
        case .underline: return "Underline"
        }
    }
}

/// How termio resolves its light/dark appearance: follow the system, or pin to
/// one. Raw values persist; `App` maps these to an `NSAppearance`, and the
/// terminal's light/dark theme pair follows the resulting effective appearance.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How the sidebar orders its projects. Raw values persist. Pinned projects always
/// sort ahead of the rest (see `TermioStore.orderedProjects`); this decides the order
/// within each group.
enum ProjectSortOrder: String, CaseIterable, Identifiable {
    /// Most recently active project first — a project rises whenever one of its
    /// agents reports work (or the user switches to one of its sessions).
    case recentActivity
    /// Stable A→Z by project name.
    case name

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentActivity: return "Recent Activity"
        case .name: return "Name"
        }
    }
}

/// App-wide, persisted preferences. Plain values only — the translation into
/// libghostty configuration lives in `TermioStore`, so this type stays free of
/// terminal-core types and is trivial to read, test, and persist.
///
/// Backed by `UserDefaults`: every property writes through on change (`didSet`),
/// and `registerDefaults()` seeds the fallbacks so a fresh install reads sensible
/// values without special-casing "unset" everywhere. `objectWillChange` (from
/// `@Published`) is what `TermioStore` listens to in order to re-apply appearance
/// to already-open terminals.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let fontFamily = "appearance.fontFamily"
        static let fontSize = "appearance.fontSize"
        static let fontThicken = "appearance.fontThicken"
        static let appearanceMode = "appearance.mode"
        static let lightThemeName = "appearance.lightThemeName"
        static let darkThemeName = "appearance.darkThemeName"
        /// Legacy single-theme key, read once to migrate older installs into the
        /// split light/dark keys above.
        static let themeName = "appearance.themeName"
        static let cursorStyle = "appearance.cursorStyle"
        static let cursorBlink = "appearance.cursorBlink"
        static let windowPadding = "appearance.windowPadding"
        static let backgroundOpacity = "appearance.backgroundOpacity"
        static let backgroundBlur = "appearance.backgroundBlur"
        static let scrollbackMegabytes = "terminal.scrollbackMegabytes"
        static let copyOnSelect = "terminal.copyOnSelect"
        static let interfaceFontFamily = "interface.fontFamily"
        static let interfaceFontSize = "interface.fontSize"
        static let interfaceRowPadding = "interface.rowPadding"
        static let agentCommands = "agents.commandOverrides"
        static let bypassPermissionAgents = "agents.bypassPermissions"
        static let disabledAgents = "agents.disabled"
        static let addedAgents = "agents.added"
        static let agentOrder = "agents.order"
        static let agentHooksEnabled = "agents.hooksEnabled"
        static let sessionControlEnabled = "agents.sessionControlEnabled"
        static let sessionControlPrompted = "agents.sessionControlPrompted"
        static let usageAuthorizedAgents = "usage.authorizedAgents"
        static let claudeKeychainDeclined = "usage.claudeKeychainDeclined"
        static let projectSortOrder = "sidebar.projectSortOrder"
        static let recentProjects = "welcome.recentProjects"
        static let lastChatAgent = "chats.lastAgent"
        static let defaultChatAgent = "chats.defaultAgent"
    }

    // MARK: Appearance

    /// Terminal font family. Defaults to "SF Mono" (the Apple system monospace,
    /// as used by Xcode/Terminal). Empty means "let libghostty pick its default
    /// monospace", so we never force a face the user doesn't have installed.
    @Published var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Key.fontFamily) }
    }

    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    /// Synthesizes a heavier weight by drawing glyphs slightly thicker — a small
    /// readability win on long agent transcripts.
    @Published var fontThicken: Bool {
        didSet { defaults.set(fontThicken, forKey: Key.fontThicken) }
    }

    /// Whether termio follows the system appearance or pins itself to light or
    /// dark. `App` applies this as an `NSAppearance`; the terminal's light/dark
    /// theme pair then follows the resulting effective appearance.
    @Published var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode) }
    }

    /// How the sidebar orders projects (pinned always first; see `ProjectSortOrder`).
    /// Driven by the sort menu in the sidebar's toolbar.
    @Published var projectSortOrder: ProjectSortOrder {
        didSet { defaults.set(projectSortOrder.rawValue, forKey: Key.projectSortOrder) }
    }

    /// Folders the user has opened, most-recent first, so the welcome page's
    /// "Recent" column reopens with one click. Persisted as JSON so it survives the
    /// fully-empty state (every project closed), which is precisely when the welcome
    /// page needs it. Maintained by `noteRecentProject(name:path:)`, which dedups by
    /// path and caps the list; the store calls it whenever a project is opened.
    @Published var recentProjects: [RecentProject] {
        didSet {
            defaults.set(try? JSONEncoder().encode(recentProjects), forKey: Key.recentProjects)
        }
    }

    /// The coding agent the last scratch **chat** was started with, so a bare
    /// "New Chat" (the single File-menu / `+` action) relaunches the agent you
    /// actually use rather than a fixed one. Stored by id; `nil` until the first
    /// chat is started, and ignored if that agent is later disabled — both fall
    /// back to the first enabled agent (see `TermioStore.defaultChatAgent`).
    @Published var lastChatAgentID: String? {
        didSet { defaults.set(lastChatAgentID, forKey: Key.lastChatAgent) }
    }

    /// Which agent "New Chat" launches, chosen in Settings ▸ Agents. `nil` = the
    /// adaptive "Last used" mode (see `lastChatAgentID`); a specific agent id pins
    /// it so ⌘N always starts that one. Resolved by `TermioStore.defaultChatAgent`,
    /// which also falls back gracefully when the pinned agent is later disabled.
    @Published var defaultChatAgentID: String? {
        didSet { defaults.set(defaultChatAgentID, forKey: Key.defaultChatAgent) }
    }

    /// The most a project can be opened is capped so the Recent column stays a
    /// short, scannable list rather than an ever-growing log.
    private static let recentProjectsLimit = 8

    /// Records `path` as the most recently opened project, moving it to the front
    /// (deduped by path) and trimming to `recentProjectsLimit`. A no-op mutation is
    /// avoided so an already-front project doesn't churn `UserDefaults`.
    func noteRecentProject(name: String, path: String) {
        var updated = recentProjects.filter { $0.path != path }
        updated.insert(RecentProject(name: name, path: path), at: 0)
        if updated.count > Self.recentProjectsLimit {
            updated.removeLast(updated.count - Self.recentProjectsLimit)
        }
        if updated != recentProjects { recentProjects = updated }
    }

    /// Name of the Ghostty bundled theme used while macOS is in light mode, or
    /// empty for termio's default light canvas. The terminal switches between this
    /// and `darkThemeName` automatically as the system appearance changes. Resolved
    /// against `GhosttyThemeCatalog` in `TermioStore`.
    @Published var lightThemeName: String {
        didSet { defaults.set(lightThemeName, forKey: Key.lightThemeName) }
    }

    /// Name of the Ghostty bundled theme used while macOS is in dark mode, or empty
    /// for termio's default dark canvas. Counterpart to `lightThemeName`.
    @Published var darkThemeName: String {
        didSet { defaults.set(darkThemeName, forKey: Key.darkThemeName) }
    }

    /// Cursor shape. The app-side `CursorStyle` keeps this type free of
    /// terminal-core types while staying type-safe end to end; it persists as its
    /// raw token and `TermioStore` maps it to libghostty.
    @Published var cursorStyle: CursorStyle {
        didSet { defaults.set(cursorStyle.rawValue, forKey: Key.cursorStyle) }
    }

    @Published var cursorBlink: Bool {
        didSet { defaults.set(cursorBlink, forKey: Key.cursorBlink) }
    }

    /// Inset (points) between the terminal grid and the window edge, applied on
    /// both axes. Comfort spacing so agent output doesn't run into the chrome.
    @Published var windowPadding: Int {
        didSet { defaults.set(windowPadding, forKey: Key.windowPadding) }
    }

    /// Terminal background alpha (0.2–1.0). Below 1.0 the window goes non-opaque
    /// so the desktop shows through; 1.0 keeps the normal solid look.
    @Published var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: Key.backgroundOpacity) }
    }

    /// Blur radius applied behind a translucent background (0 = off). Only visible
    /// when `backgroundOpacity` is below 1.0.
    @Published var backgroundBlur: Int {
        didSet { defaults.set(backgroundBlur, forKey: Key.backgroundBlur) }
    }

    // MARK: Terminal

    /// Scrollback buffer size in megabytes. Agents emit a lot of output, so the
    /// default history is generous; capped to keep memory bounded.
    @Published var scrollbackMegabytes: Int {
        didSet { defaults.set(scrollbackMegabytes, forKey: Key.scrollbackMegabytes) }
    }

    /// When on, selecting text copies it straight to the system clipboard.
    @Published var copyOnSelect: Bool {
        didSet { defaults.set(copyOnSelect, forKey: Key.copyOnSelect) }
    }

    // MARK: Interface

    /// Font family for the app's own chrome (the project/session sidebar). Empty
    /// means the system UI font. Unlike the terminal font this need not be
    /// monospaced.
    @Published var interfaceFontFamily: String {
        didSet { defaults.set(interfaceFontFamily, forKey: Key.interfaceFontFamily) }
    }

    @Published var interfaceFontSize: Double {
        didSet { defaults.set(interfaceFontSize, forKey: Key.interfaceFontSize) }
    }

    /// Vertical padding (points) on each sidebar row — the VSCode-style density
    /// control, from compact to roomy.
    @Published var interfaceRowPadding: Double {
        didSet { defaults.set(interfaceRowPadding, forKey: Key.interfaceRowPadding) }
    }

    // MARK: Agents

    /// Per-agent command overrides keyed by `AgentPreset.rawValue`. An entry lets
    /// the user run, say, `claude --dangerously-skip-permissions` instead of the
    /// built-in default. An empty/whitespace value is treated as "no override".
    @Published var agentCommandOverrides: [String: String] {
        didSet { defaults.set(agentCommandOverrides, forKey: Key.agentCommands) }
    }

    /// Agents whose permission/approval prompts should be bypassed, by `rawValue`.
    /// The per-agent switch appends `AgentPreset.permissionBypassFlag` to the
    /// resolved command (see `command(for:)`). Opt-in and stored as the on-set so
    /// the default (nothing stored) means every agent keeps its prompts.
    @Published var bypassPermissionAgents: Set<String> {
        didSet { defaults.set(Array(bypassPermissionAgents), forKey: Key.bypassPermissionAgents) }
    }

    /// Agent presets hidden from the sidebar quick-add row, by `rawValue`. Stored
    /// as the disabled set so the default (nothing stored) means "all enabled".
    @Published var disabledAgents: Set<String> {
        didSet { defaults.set(Array(disabledAgents), forKey: Key.disabledAgents) }
    }

    /// Agents pinned to the Agents settings list even while switched off, by
    /// `rawValue`. A row on that list means added-or-enabled (`isAgentListed`); the
    /// rest wait behind its "Add Agent" menu. `setAgent` keeps any agent the user
    /// flips in here, so switching one off leaves its row in place — only
    /// `removeAgent` drops a row back into the menu.
    @Published var addedAgents: Set<String> {
        didSet { defaults.set(Array(addedAgents), forKey: Key.addedAgents) }
    }

    /// The user's own agent arrangement, as an ordered list of `rawValue`s — the
    /// runtime layer that overrides each manifest's default `order` (the VSCode
    /// model: shipped defaults, user settings on top). Empty until the user drags a
    /// row in Settings, in which case `orderedAgents` falls straight through to the
    /// catalog's default order. Ids absent from the list keep catalog order and sort
    /// after ranked ones; Terminal is always pinned first regardless (see
    /// `orderedAgents`).
    @Published var agentOrder: [String] {
        didSet { defaults.set(agentOrder, forKey: Key.agentOrder) }
    }

    /// When on, termio installs Claude Code hooks (into `~/.claude/settings.json`)
    /// that report each turn's lifecycle, so a running agent reads as `.working`
    /// and a tool-in-use can be named — precision the zero-config bell/OSC signals
    /// can't give. Opt-in, since it edits a file termio does not own; turning it
    /// off removes termio's entries again. The `TermioStore` watches this and
    /// installs/uninstalls to match.
    @Published var agentHooksEnabled: Bool {
        didSet { defaults.set(agentHooksEnabled, forKey: Key.agentHooksEnabled) }
    }

    /// When on, termio runs a local control socket the `termio sessions` CLI talks
    /// to, letting one agent see and drive its sibling sessions in the same project
    /// (list / send a prompt / answer a menu / start / stop). Opt-in, since it lets
    /// an agent act on other sessions and writes a small awareness note into the
    /// user-level agent instruction files; turning it off removes that note. The
    /// `TermioStore` watches this and installs/uninstalls to match.
    @Published var sessionControlEnabled: Bool {
        didSet { defaults.set(sessionControlEnabled, forKey: Key.sessionControlEnabled) }
    }

    /// Whether the one-time "let your agents coordinate?" prompt has been shown, so
    /// it's offered exactly once per install and never nags. Not `@Published` — it's
    /// only read and set at launch, never bound to UI.
    var sessionControlPrompted: Bool {
        get { defaults.bool(forKey: Key.sessionControlPrompted) }
        set { defaults.set(newValue, forKey: Key.sessionControlPrompted) }
    }

    /// Agents whose usage data the user has allowed termio to read, by `rawValue`.
    /// The Usage tab is opt-in per agent: until the user clicks Allow there, none
    /// of that agent's data is touched — not its local session logs and not its
    /// OAuth sign-in. Stored as the granted set, so the default (nothing stored)
    /// means "read nothing".
    @Published var usageAuthorizedAgents: Set<String> {
        didSet { defaults.set(Array(usageAuthorizedAgents), forKey: Key.usageAuthorizedAgents) }
    }

    /// A remembered "Deny" from the macOS Keychain prompt for Claude Code's
    /// credential item. Once set, termio never retries the Keychain on its own —
    /// only an explicit "try again" click in the Usage tab clears it, so a user
    /// who said no is never nagged on a timer.
    @Published var claudeKeychainDeclined: Bool {
        didSet { defaults.set(claudeKeychainDeclined, forKey: Key.claudeKeychainDeclined) }
    }


    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // One-time migration: older installs persisted a single `themeName` that
        // applied to both appearances. Seed the new split keys from it before the
        // registered "" defaults below mask whether they were ever set. Done as a
        // real write so the legacy value survives and later reads see it.
        if defaults.object(forKey: Key.lightThemeName) == nil,
           defaults.object(forKey: Key.darkThemeName) == nil,
           let legacyTheme = defaults.string(forKey: Key.themeName), !legacyTheme.isEmpty {
            defaults.set(legacyTheme, forKey: Key.lightThemeName)
            defaults.set(legacyTheme, forKey: Key.darkThemeName)
        }

        // First-run default: ship focused. Only Claude Code and Codex (plus the plain
        // Terminal) are enabled out of the box; the long tail of agents is hidden from
        // the new-session picker until the user opts in from Settings. Keyed on the
        // setting never having been written, so it's a one-time default that never
        // overrides a returning user's own choices.
        if defaults.object(forKey: Key.disabledAgents) == nil {
            let enabledByDefault: Set<String> = ["terminal", "claudeCode", "codex"]
            let hidden = AgentCatalog.shared.bundled.map(\.id).filter { !enabledByDefault.contains($0) }
            defaults.set(hidden, forKey: Key.disabledAgents)
        }

        defaults.register(defaults: [
            Key.fontFamily: "SF Mono",
            Key.fontSize: 13.0,
            Key.fontThicken: false,
            Key.appearanceMode: "system",
            Key.lightThemeName: "",
            Key.darkThemeName: "",
            Key.cursorStyle: "block",
            Key.cursorBlink: true,
            Key.windowPadding: 8,
            Key.backgroundOpacity: 1.0,
            Key.backgroundBlur: 0,
            Key.scrollbackMegabytes: 10,
            Key.copyOnSelect: false,
            Key.interfaceFontFamily: "",
            Key.interfaceFontSize: 13.0,
            Key.interfaceRowPadding: 2.0,
            Key.agentHooksEnabled: false,
            Key.sessionControlEnabled: false,
            Key.projectSortOrder: "name",
        ])

        fontFamily = defaults.string(forKey: Key.fontFamily) ?? ""
        fontSize = defaults.double(forKey: Key.fontSize)
        fontThicken = defaults.bool(forKey: Key.fontThicken)
        appearanceMode = defaults.string(forKey: Key.appearanceMode).flatMap(AppearanceMode.init) ?? .system
        lightThemeName = defaults.string(forKey: Key.lightThemeName) ?? ""
        darkThemeName = defaults.string(forKey: Key.darkThemeName) ?? ""
        cursorStyle = defaults.string(forKey: Key.cursorStyle).flatMap(CursorStyle.init) ?? .block
        cursorBlink = defaults.bool(forKey: Key.cursorBlink)
        windowPadding = defaults.integer(forKey: Key.windowPadding)
        backgroundOpacity = defaults.double(forKey: Key.backgroundOpacity)
        backgroundBlur = defaults.integer(forKey: Key.backgroundBlur)
        scrollbackMegabytes = defaults.integer(forKey: Key.scrollbackMegabytes)
        copyOnSelect = defaults.bool(forKey: Key.copyOnSelect)
        interfaceFontFamily = defaults.string(forKey: Key.interfaceFontFamily) ?? ""
        interfaceFontSize = defaults.double(forKey: Key.interfaceFontSize)
        interfaceRowPadding = defaults.double(forKey: Key.interfaceRowPadding)
        agentCommandOverrides = defaults.dictionary(forKey: Key.agentCommands) as? [String: String] ?? [:]
        bypassPermissionAgents = Set(defaults.stringArray(forKey: Key.bypassPermissionAgents) ?? [])
        disabledAgents = Set(defaults.stringArray(forKey: Key.disabledAgents) ?? [])
        addedAgents = Set(defaults.stringArray(forKey: Key.addedAgents) ?? [])
        agentOrder = defaults.stringArray(forKey: Key.agentOrder) ?? []
        agentHooksEnabled = defaults.bool(forKey: Key.agentHooksEnabled)
        sessionControlEnabled = defaults.bool(forKey: Key.sessionControlEnabled)
        usageAuthorizedAgents = Set(defaults.stringArray(forKey: Key.usageAuthorizedAgents) ?? [])
        claudeKeychainDeclined = defaults.bool(forKey: Key.claudeKeychainDeclined)
        projectSortOrder = defaults.string(forKey: Key.projectSortOrder).flatMap(ProjectSortOrder.init) ?? .name
        recentProjects = defaults.data(forKey: Key.recentProjects)
            .flatMap { try? JSONDecoder().decode([RecentProject].self, from: $0) } ?? []
        lastChatAgentID = defaults.string(forKey: Key.lastChatAgent)
        defaultChatAgentID = defaults.string(forKey: Key.defaultChatAgent)
    }

    /// Effective command for an agent: the user's override if it's non-empty,
    /// otherwise the preset's built-in default (`nil` for a plain login shell),
    /// with the permission-bypass flag appended when that switch is on. The flag
    /// is only added if it isn't already present, so a user who typed it into the
    /// override by hand doesn't get it twice.
    func command(for agent: AgentPreset) -> String? {
        let override = agentCommandOverrides[agent.rawValue]?.trimmingCharacters(in: .whitespaces)
        let base = (override?.isEmpty == false ? override : agent.command)
        guard let base else { return nil }
        guard bypassesPermissions(agent), let flag = agent.permissionBypassFlag,
              !base.contains(flag) else { return base }
        return "\(base) \(flag)"
    }

    func bypassesPermissions(_ agent: AgentPreset) -> Bool {
        bypassPermissionAgents.contains(agent.rawValue)
    }

    func setBypassPermissions(_ agent: AgentPreset, enabled: Bool) {
        if enabled {
            bypassPermissionAgents.insert(agent.rawValue)
        } else {
            bypassPermissionAgents.remove(agent.rawValue)
        }
    }

    func isAgentEnabled(_ agent: AgentPreset) -> Bool {
        !disabledAgents.contains(agent.rawValue)
    }

    func isUsageAuthorized(_ agent: AgentPreset) -> Bool {
        usageAuthorizedAgents.contains(agent.rawValue)
    }

    func setUsageAuthorized(_ agent: AgentPreset, enabled: Bool) {
        if enabled {
            usageAuthorizedAgents.insert(agent.rawValue)
        } else {
            usageAuthorizedAgents.remove(agent.rawValue)
        }
    }

    func setAgent(_ agent: AgentPreset, enabled: Bool) {
        // Either flip pins the row: enabling implies one, and disabling must not
        // silently drop one — only `removeAgent` does that. Also catches agents
        // that were never explicitly added (enabled by default or by manifest).
        addedAgents.insert(agent.rawValue)
        if enabled {
            disabledAgents.remove(agent.rawValue)
        } else {
            disabledAgents.insert(agent.rawValue)
        }
    }

    /// Whether the agent occupies a row on the Agents settings tab: explicitly
    /// added, or enabled (a default-enabled agent has a row without ever being
    /// added, so enabled ⊆ listed holds by construction).
    func isAgentListed(_ agent: AgentPreset) -> Bool {
        addedAgents.contains(agent.rawValue) || isAgentEnabled(agent)
    }

    /// Puts the agent's row on the Agents settings list without enabling it —
    /// enabling is a separate, availability-gated step (see `AgentSettingsTab`).
    func addAgent(_ agent: AgentPreset) {
        addedAgents.insert(agent.rawValue)
    }

    /// Drops the agent's row from the settings list back into the "Add Agent"
    /// menu. Also disables it: an unlisted agent must not linger in the session
    /// pickers. Written directly (not via `setAgent`), which would re-pin the row.
    func removeAgent(_ agent: AgentPreset) {
        addedAgents.remove(agent.rawValue)
        disabledAgents.insert(agent.rawValue)
    }

    /// Applies the user's `agentOrder` on top of the catalog's default order. The
    /// single chokepoint every ordered surface goes through (the sidebar quick-add
    /// row, the command palette, the New-chat picker, the Settings list), so a drag
    /// in Settings moves the agent everywhere. Terminal is pinned first; ranked ids
    /// follow in the user's arrangement; anything the user hasn't placed keeps its
    /// incoming (catalog) order and sorts after the ranked block.
    func orderedAgents(_ agents: [AgentPreset]) -> [AgentPreset] {
        let rank = Dictionary(
            agentOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        func key(_ item: (offset: Int, element: AgentPreset)) -> (Int, Int) {
            if item.element.id == AgentPreset.terminal.id { return (-1, item.offset) }
            return (rank[item.element.id] ?? Int.max, item.offset)
        }
        return agents.enumerated().sorted { key($0) < key($1) }.map(\.element)
    }

    /// Records a new arrangement of the enabled (non-Terminal) agents after a drag.
    /// Every other id keeps its current relative order behind the enabled block, so
    /// the full ranking stays well-defined and a later enable slots in predictably.
    func setEnabledOrder(_ enabledIDs: [String]) {
        let rest = AgentPreset.allCases.map(\.id).filter { !enabledIDs.contains($0) }
        agentOrder = enabledIDs + rest
    }
}
