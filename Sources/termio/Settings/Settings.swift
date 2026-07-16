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
        static let agentHooksEnabled = "agents.hooksEnabled"
        static let sessionControlEnabled = "agents.sessionControlEnabled"
        static let sessionControlPrompted = "agents.sessionControlPrompted"
        static let usageAuthorizedAgents = "usage.authorizedAgents"
        static let claudeKeychainDeclined = "usage.claudeKeychainDeclined"
        static let projectSortOrder = "sidebar.projectSortOrder"
        static let recentProjects = "welcome.recentProjects"
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

    // MARK: Config file

    /// True while values read from the config file are being applied, so the property
    /// `didSet`s that fire don't turn around and rewrite the file we just read (which
    /// would fight a hand-edit, and could loop). See `applyConfig` / `scheduleConfigWrite`.
    var isApplyingConfig = false
    /// The exact text termio last wrote to (or read from) the config file. The writer
    /// skips a no-op disk write when the render matches this, and the watcher ignores a
    /// change whose contents match it — that's how a GUI edit's own write-back doesn't
    /// read back as an external edit. See `writeConfigFile` / `reloadConfigFromDisk`.
    var lastConfigContents: String?
    /// Debounced file writer, so dragging a slider coalesces into a single write.
    var configWriteItem: DispatchWorkItem?
    var configWatcher: ConfigFileWatcher?
    private var configCancellable: AnyCancellable?

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
            let hidden = AgentDefinition.builtins.map(\.id).filter { !enabledByDefault.contains($0) }
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
            Key.projectSortOrder: "recentActivity",
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
        agentHooksEnabled = defaults.bool(forKey: Key.agentHooksEnabled)
        sessionControlEnabled = defaults.bool(forKey: Key.sessionControlEnabled)
        usageAuthorizedAgents = Set(defaults.stringArray(forKey: Key.usageAuthorizedAgents) ?? [])
        claudeKeychainDeclined = defaults.bool(forKey: Key.claudeKeychainDeclined)
        projectSortOrder = defaults.string(forKey: Key.projectSortOrder).flatMap(ProjectSortOrder.init) ?? .recentActivity
        recentProjects = defaults.data(forKey: Key.recentProjects)
            .flatMap { try? JSONDecoder().decode([RecentProject].self, from: $0) } ?? []

        // The config file is the canonical store: adopt it if present (a hand edit wins
        // over the UserDefaults cache read above), otherwise seed a documented file from
        // these values so a fresh install has something to edit. Then watch it, and
        // mirror later GUI edits back into it. Subscribed *after* the reads above so
        // seeding these properties isn't mistaken for a user edit.
        bootstrapConfigFile()
        configCancellable = objectWillChange.sink { [weak self] in self?.scheduleConfigWrite() }
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
        if enabled {
            disabledAgents.remove(agent.rawValue)
        } else {
            disabledAgents.insert(agent.rawValue)
        }
    }
}

// MARK: - Config file mapping

extension AppSettings {
    /// One editable key in the config file: its Ghostty-style name, the section and
    /// one-line doc used when seeding a fresh file, and the get/set that bridge the text
    /// value to the typed setting. `set` is defensive — an unparseable or out-of-range
    /// value is ignored, so a typo in the file can't crash or blank a setting.
    fileprivate struct ConfigEntry {
        let key: String
        let section: String
        let doc: String
        let get: (AppSettings) -> String
        let set: (AppSettings, String) -> Void
    }

    /// The managed keys, in file order. Scalars only: appearance, terminal, and
    /// interface options plus the two agent toggles. Collection-valued agent settings
    /// (per-agent command overrides, the disabled/bypass sets) and pure app state
    /// (recent projects, usage/keychain consent) are intentionally excluded.
    fileprivate static let configEntries: [ConfigEntry] = [
        ConfigEntry(key: "appearance", section: "Appearance",
                    doc: "Light/dark: system, light, or dark.",
                    get: { $0.appearanceMode.rawValue },
                    set: { s, v in if let m = AppearanceMode(rawValue: v) { s.appearanceMode = m } }),
        ConfigEntry(key: "theme", section: "Appearance",
                    doc: "Terminal theme. One name, or light:Name,dark:Name. Empty = termio's own canvas.",
                    get: { $0.renderThemeValue() },
                    set: { s, v in s.applyThemeValue(v) }),

        ConfigEntry(key: "font-family", section: "Font",
                    doc: "Terminal font. Empty = system monospace.",
                    get: { $0.fontFamily },
                    set: { s, v in s.fontFamily = v }),
        ConfigEntry(key: "font-size", section: "Font",
                    doc: "Terminal font size, in points (8–32).",
                    get: { AppSettings.number($0.fontSize) },
                    set: { s, v in if let d = Double(v), (8...32).contains(d) { s.fontSize = d } }),
        ConfigEntry(key: "font-thicken", section: "Font",
                    doc: "Synthesize a slightly heavier weight (true/false).",
                    get: { AppSettings.boolString($0.fontThicken) },
                    set: { s, v in s.fontThicken = AppSettings.parseBool(v) }),

        ConfigEntry(key: "cursor-style", section: "Cursor",
                    doc: "Cursor shape: block, bar, or underline.",
                    get: { $0.cursorStyle.rawValue },
                    set: { s, v in if let c = CursorStyle(rawValue: v) { s.cursorStyle = c } }),
        ConfigEntry(key: "cursor-style-blink", section: "Cursor",
                    doc: "Blink the cursor (true/false).",
                    get: { AppSettings.boolString($0.cursorBlink) },
                    set: { s, v in s.cursorBlink = AppSettings.parseBool(v) }),

        ConfigEntry(key: "window-padding", section: "Window",
                    doc: "Inset between the terminal grid and the window edge, in points (0–40).",
                    get: { String($0.windowPadding) },
                    set: { s, v in if let i = Int(v), (0...40).contains(i) { s.windowPadding = i } }),
        ConfigEntry(key: "background-opacity", section: "Window",
                    doc: "Terminal background alpha, 0.2–1.0. Below 1.0 the desktop shows through.",
                    get: { AppSettings.number($0.backgroundOpacity) },
                    set: { s, v in if let d = Double(v), (0.2...1.0).contains(d) { s.backgroundOpacity = d } }),
        ConfigEntry(key: "background-blur", section: "Window",
                    doc: "Blur radius behind a translucent background, 0–60. Only visible below full opacity.",
                    get: { String($0.backgroundBlur) },
                    set: { s, v in if let i = Int(v), (0...60).contains(i) { s.backgroundBlur = i } }),

        ConfigEntry(key: "scrollback-megabytes", section: "Terminal",
                    doc: "Scrollback buffer size, in megabytes.",
                    get: { String($0.scrollbackMegabytes) },
                    set: { s, v in if let i = Int(v), i > 0 { s.scrollbackMegabytes = i } }),
        ConfigEntry(key: "copy-on-select", section: "Terminal",
                    doc: "Copy selected text to the clipboard automatically (true/false).",
                    get: { AppSettings.boolString($0.copyOnSelect) },
                    set: { s, v in s.copyOnSelect = AppSettings.parseBool(v) }),

        ConfigEntry(key: "interface-font-family", section: "Interface",
                    doc: "Sidebar/chrome font. Empty = system UI font.",
                    get: { $0.interfaceFontFamily },
                    set: { s, v in s.interfaceFontFamily = v }),
        ConfigEntry(key: "interface-font-size", section: "Interface",
                    doc: "Sidebar/chrome font size, in points (8–24).",
                    get: { AppSettings.number($0.interfaceFontSize) },
                    set: { s, v in if let d = Double(v), (8...24).contains(d) { s.interfaceFontSize = d } }),
        ConfigEntry(key: "interface-row-padding", section: "Interface",
                    doc: "Extra vertical padding on each sidebar row, in points (0–12).",
                    get: { AppSettings.number($0.interfaceRowPadding) },
                    set: { s, v in if let d = Double(v), (0...12).contains(d) { s.interfaceRowPadding = d } }),
        ConfigEntry(key: "project-sort-order", section: "Interface",
                    doc: "Sidebar project order: recentActivity or name.",
                    get: { $0.projectSortOrder.rawValue },
                    set: { s, v in if let o = ProjectSortOrder(rawValue: v) { s.projectSortOrder = o } }),

        ConfigEntry(key: "agent-hooks", section: "Agents",
                    doc: "Install Claude Code lifecycle hooks for precise agent status (true/false).",
                    get: { AppSettings.boolString($0.agentHooksEnabled) },
                    set: { s, v in s.agentHooksEnabled = AppSettings.parseBool(v) }),
        ConfigEntry(key: "session-control", section: "Agents",
                    doc: "Run the local control socket so agents can drive their siblings (true/false).",
                    get: { AppSettings.boolString($0.sessionControlEnabled) },
                    set: { s, v in s.sessionControlEnabled = AppSettings.parseBool(v) }),
    ]

    fileprivate static var orderedConfigKeys: [String] { configEntries.map(\.key) }

    /// Current value of every managed key, for seeding and write-back.
    fileprivate func currentConfigValues() -> [String: String] {
        var values: [String: String] = [:]
        for entry in Self.configEntries { values[entry.key] = entry.get(self) }
        return values
    }

    /// Applies parsed `key = value` pairs to the matching settings. Unknown keys are
    /// ignored (so the file may carry keys a different termio version doesn't manage),
    /// and each `set` ignores an unparseable value.
    fileprivate func applyConfig(_ values: [String: String]) {
        for entry in Self.configEntries where values[entry.key] != nil {
            entry.set(self, values[entry.key]!)
        }
    }

    // MARK: Theme <-> `theme` key

    /// Renders the light/dark theme pair as a `theme` value: one name when both slots
    /// match (the common case), otherwise `light:Name,dark:Name`.
    fileprivate func renderThemeValue() -> String {
        lightThemeName == darkThemeName ? lightThemeName : "light:\(lightThemeName),dark:\(darkThemeName)"
    }

    /// Parses a `theme` value into the light/dark slots. A bare name sets both; the
    /// `light:…,dark:…` form sets each (a missing side clears to the default canvas).
    fileprivate func applyThemeValue(_ value: String) {
        guard value.contains("light:") || value.contains("dark:") else {
            lightThemeName = value
            darkThemeName = value
            return
        }
        var light = "", dark = ""
        for part in value.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("light:") {
                light = String(piece.dropFirst("light:".count)).trimmingCharacters(in: .whitespaces)
            } else if piece.hasPrefix("dark:") {
                dark = String(piece.dropFirst("dark:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        lightThemeName = light
        darkThemeName = dark
    }

    // MARK: Load / seed / write / watch

    /// Adopts the config file if it exists (it wins over the UserDefaults cache),
    /// otherwise seeds a documented file from the current values, then starts watching.
    func bootstrapConfigFile() {
        if let text = try? String(contentsOf: ConfigFile.url, encoding: .utf8) {
            isApplyingConfig = true
            applyConfig(ConfigFile.parse(text))
            isApplyingConfig = false
            lastConfigContents = text
        } else {
            writeConfigFile(seeding: true)
        }
        let watcher = ConfigFileWatcher { [weak self] in self?.reloadConfigFromDisk() }
        watcher.start(directory: ConfigFile.directory)
        configWatcher = watcher
    }

    /// Re-reads the file after an external edit and applies it. Skips termio's own
    /// write-back (contents equal to what it last wrote) so a GUI edit doesn't loop.
    private func reloadConfigFromDisk() {
        guard let text = try? String(contentsOf: ConfigFile.url, encoding: .utf8),
              text != lastConfigContents else { return }
        isApplyingConfig = true
        applyConfig(ConfigFile.parse(text))
        isApplyingConfig = false
        lastConfigContents = text
    }

    /// Debounced write-back, invoked from `objectWillChange`. A no-op while applying a
    /// file read (that would fight the edit being read).
    fileprivate func scheduleConfigWrite() {
        guard !isApplyingConfig else { return }
        configWriteItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeConfigFile() }
        configWriteItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Renders the managed keys into the file and writes it if changed. When `seeding`,
    /// starts from a documented template; otherwise it surgically updates the existing
    /// file, preserving its comments, unknown keys, and layout. The disk write hops off
    /// the main actor.
    func writeConfigFile(seeding: Bool = false) {
        let base = seeding
            ? Self.seedTemplate()
            : ((try? String(contentsOf: ConfigFile.url, encoding: .utf8)) ?? Self.seedTemplate())
        let text = ConfigFile.rewrite(base, values: currentConfigValues(), order: Self.orderedConfigKeys)
        guard text != lastConfigContents else { return }
        lastConfigContents = text
        let url = ConfigFile.url
        let directory = ConfigFile.directory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A documented, empty-valued template (values are filled in by `rewrite`). Grouped
    /// by section with a one-line doc above each key, so a freshly seeded file reads as
    /// its own reference.
    fileprivate static func seedTemplate() -> String {
        var lines = [
            "# termio configuration",
            "#",
            "# Edit this file and termio applies changes live — no relaunch. The Settings",
            "# window edits the common options here; every option below can also be set by",
            "# hand, and hand edits win. Format: key = value. Lines starting with # are",
            "# comments and are preserved across edits.",
            "",
        ]
        var section = ""
        for entry in configEntries {
            if entry.section != section {
                if !section.isEmpty { lines.append("") }
                lines.append("# ── \(entry.section) ──")
                section = entry.section
            }
            lines.append("# \(entry.doc)")
            lines.append("\(entry.key) =")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: Value formatting

    /// Formats a Double without a trailing `.0`, so `13.0` writes as `13` while `0.95`
    /// stays `0.95`.
    fileprivate static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    fileprivate static func boolString(_ value: Bool) -> String { value ? "true" : "false" }

    fileprivate static func parseBool(_ value: String) -> Bool {
        ["true", "1", "yes", "on"].contains(value.lowercased())
    }
}
