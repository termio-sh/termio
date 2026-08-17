import Combine
import Foundation
import GhosttyTheme

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
        case .block: return localized("Block")
        case .bar: return localized("Bar")
        case .underline: return localized("Underline")
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
        case .system: return localized("System")
        case .light: return localized("Light")
        case .dark: return localized("Dark")
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
        case .recentActivity: return localized("Recent Activity")
        case .name: return localized("Name")
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
    /// State and consent live here: the recent-project list, the last agent a
    /// chat used, whether the session-control prompt has been answered, and the
    /// Usage tab's per-agent authorizations. None of it is a preference a user
    /// would hand-edit or carry to another machine.
    private let defaults: UserDefaults
    /// Preferences live here, in `settings.json`. See `SettingsStore` for why the
    /// file holds only what the user actually chose.
    private let store: SettingsStore

    /// The keys `settings.json` owns — everything in `Key` except the state and
    /// consent above, plus `themeName`, which exists only to migrate pre-split
    /// installs into the light/dark pair.
    private static let fileManagedKeys: Set<String> = [
        Key.fontFamily, Key.fontSize, Key.fontThicken, Key.codeLineHeight,
        Key.appearanceMode, Key.lightThemeName, Key.darkThemeName,
        Key.cursorStyle, Key.cursorBlink, Key.windowPadding,
        Key.backgroundOpacity, Key.backgroundBlur,
        Key.scrollbackMegabytes, Key.copyOnSelect,
        Key.interfaceFontFamily, Key.interfaceFontSize, Key.interfaceRowPadding,
        Key.agentCommands, Key.bypassPermissionAgents, Key.disabledAgents,
        Key.addedAgents, Key.agentOrder, Key.agentHooksEnabled,
        Key.sessionControlEnabled, Key.githubIntegrationEnabled,
        Key.notifyTaskCompletion, Key.notificationSound,
        Key.projectSortOrder, Key.defaultChatAgent,
    ]

    private enum Key {
        static let fontFamily = "appearance.fontFamily"
        static let fontSize = "appearance.fontSize"
        static let fontThicken = "appearance.fontThicken"
        static let codeLineHeight = "appearance.codeLineHeight"
        static let appearanceMode = "appearance.mode"
        static let lightThemeName = "appearance.lightThemeName"
        static let darkThemeName = "appearance.darkThemeName"
        /// Legacy single-theme key, read once to migrate older installs into the
        /// split light/dark keys above.
        static let themeName = "appearance.themeName"
        /// Set once the two theme slots have been materialized into the Themes
        /// folder, so the upgrade pass runs exactly once (see
        /// `materializeSelectedThemes`).
        static let themesMaterialized = "appearance.themesMaterialized"
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
        static let githubIntegrationEnabled = "github.integrationEnabled"
        static let notifyTaskCompletion = "notifications.taskCompletion"
        static let notificationSound = "notifications.sound"
        static let projectSortOrder = "sidebar.projectSortOrder"
        static let recentProjects = "welcome.recentProjects"
        static let lastChatAgent = "chats.lastAgent"
        static let defaultChatAgent = "chats.defaultAgent"
        static let currentDevice = "devices.current"
    }

    // MARK: Appearance

    /// Extra `font-family` entries from the user's Ghostty config (everything after the primary
    /// face) — passed to the terminal as a fallback chain, so glyphs the chosen font lacks (CJK
    /// above all) resolve the same way they do in Ghostty itself. Empty without a Ghostty config.
    let ghosttyFontFallbacks: [String]
    /// True when a Ghostty config contributed defaults this launch — surfaces one hint line in
    /// Appearance so inherited values aren't a mystery.
    let inheritsGhosttyDefaults: Bool

    /// Terminal font family. Defaults to "SF Mono" (the Apple system monospace,
    /// as used by Xcode/Terminal). Empty means "let libghostty pick its default
    /// monospace", so we never force a face the user doesn't have installed.
    @Published var fontFamily: String {
        didSet { store.set(fontFamily, forKey: Key.fontFamily) }
    }

    @Published var fontSize: Double {
        didSet { store.set(fontSize, forKey: Key.fontSize) }
    }

    /// Synthesizes a heavier weight by drawing glyphs slightly thicker — a small
    /// readability win on long agent transcripts.
    @Published var fontThicken: Bool {
        didSet { store.set(fontThicken, forKey: Key.fontThicken) }
    }

    /// Line height for the file editor and diffs, as a multiple of the font size
    /// (VS Code's model). The terminal grid is ghostty's own and is unaffected.
    @Published var codeLineHeight: Double {
        didSet { store.set(codeLineHeight, forKey: Key.codeLineHeight) }
    }

    /// Whether termio follows the system appearance or pins itself to light or
    /// dark. `App` applies this as an `NSAppearance`; the terminal's light/dark
    /// theme pair then follows the resulting effective appearance.
    @Published var appearanceMode: AppearanceMode {
        didSet { store.set(appearanceMode.rawValue, forKey: Key.appearanceMode) }
    }

    /// How the sidebar orders projects (pinned always first; see `ProjectSortOrder`).
    /// Driven by the sort menu in the sidebar's toolbar.
    @Published var projectSortOrder: ProjectSortOrder {
        didSet { store.set(projectSortOrder.rawValue, forKey: Key.projectSortOrder) }
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
        didSet { store.set(defaultChatAgentID, forKey: Key.defaultChatAgent) }
    }

    /// The device new terminals open on, held as the `~/.ssh/config` alias that
    /// reaches it — `nil` for this Mac. It is a route, not an identity: the stable
    /// one is the daemon's `host_id`, and only a handshake knows it, while this has
    /// to answer the instant a menu is built.
    ///
    /// State rather than a preference (it is a place, not a taste), so it lives in
    /// `defaults` and never reaches `settings.json`. An alias that no longer
    /// matches a known machine resolves back to this Mac — see `DeviceRoster`.
    @Published var currentDeviceAlias: String? {
        didSet { defaults.set(currentDeviceAlias, forKey: Key.currentDevice) }
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
        didSet { store.set(lightThemeName, forKey: Key.lightThemeName) }
    }

    /// Name of the Ghostty bundled theme used while macOS is in dark mode, or empty
    /// for termio's default dark canvas. Counterpart to `lightThemeName`.
    @Published var darkThemeName: String {
        didSet { store.set(darkThemeName, forKey: Key.darkThemeName) }
    }

    /// Cursor shape. The app-side `CursorStyle` keeps this type free of
    /// terminal-core types while staying type-safe end to end; it persists as its
    /// raw token and `TermioStore` maps it to libghostty.
    @Published var cursorStyle: CursorStyle {
        didSet { store.set(cursorStyle.rawValue, forKey: Key.cursorStyle) }
    }

    @Published var cursorBlink: Bool {
        didSet { store.set(cursorBlink, forKey: Key.cursorBlink) }
    }

    /// Inset (points) between the terminal grid and the window edge, applied on
    /// both axes. Comfort spacing so agent output doesn't run into the chrome.
    @Published var windowPadding: Int {
        didSet { store.set(windowPadding, forKey: Key.windowPadding) }
    }

    /// Terminal background alpha (0.2–1.0). Below 1.0 the window goes non-opaque
    /// so the desktop shows through; 1.0 keeps the normal solid look.
    @Published var backgroundOpacity: Double {
        didSet { store.set(backgroundOpacity, forKey: Key.backgroundOpacity) }
    }

    /// Blur radius applied behind a translucent background (0 = off). Only visible
    /// when `backgroundOpacity` is below 1.0.
    @Published var backgroundBlur: Int {
        didSet { store.set(backgroundBlur, forKey: Key.backgroundBlur) }
    }

    // MARK: Terminal

    /// Scrollback buffer size in megabytes. Agents emit a lot of output, so the
    /// default history is generous; capped to keep memory bounded.
    @Published var scrollbackMegabytes: Int {
        didSet { store.set(scrollbackMegabytes, forKey: Key.scrollbackMegabytes) }
    }

    /// When on, selecting text copies it straight to the system clipboard.
    @Published var copyOnSelect: Bool {
        didSet { store.set(copyOnSelect, forKey: Key.copyOnSelect) }
    }

    // MARK: Interface

    /// Font family for the app's own chrome (the project/session sidebar). Empty
    /// means the system UI font. Unlike the terminal font this need not be
    /// monospaced.
    @Published var interfaceFontFamily: String {
        didSet { store.set(interfaceFontFamily, forKey: Key.interfaceFontFamily) }
    }

    @Published var interfaceFontSize: Double {
        didSet { store.set(interfaceFontSize, forKey: Key.interfaceFontSize) }
    }

    /// Vertical padding (points) on each sidebar row — the VSCode-style density
    /// control, from compact to roomy.
    @Published var interfaceRowPadding: Double {
        didSet { store.set(interfaceRowPadding, forKey: Key.interfaceRowPadding) }
    }

    // MARK: Agents

    /// Per-agent command overrides keyed by `AgentPreset.rawValue`. An entry lets
    /// the user run, say, `claude --dangerously-skip-permissions` instead of the
    /// built-in default. An empty/whitespace value is treated as "no override".
    @Published var agentCommandOverrides: [String: String] {
        didSet { store.set(agentCommandOverrides, forKey: Key.agentCommands) }
    }

    /// Agents whose permission/approval prompts should be bypassed, by `rawValue`.
    /// The per-agent switch appends `AgentPreset.permissionBypassFlag` to the
    /// resolved command (see `command(for:)`). Opt-in and stored as the on-set so
    /// the default (nothing stored) means every agent keeps its prompts.
    @Published var bypassPermissionAgents: Set<String> {
        didSet { store.set(Array(bypassPermissionAgents), forKey: Key.bypassPermissionAgents) }
    }

    /// Agent presets hidden from the sidebar quick-add row, by `rawValue`. Stored
    /// as the disabled set so the default (nothing stored) means "all enabled".
    @Published var disabledAgents: Set<String> {
        didSet { store.set(Array(disabledAgents), forKey: Key.disabledAgents) }
    }

    /// Agents pinned to the Agents settings list even while switched off, by
    /// `rawValue`. A row on that list means added-or-enabled (`isAgentListed`); the
    /// rest wait behind its "Add Agent" menu. `setAgent` keeps any agent the user
    /// flips in here, so switching one off leaves its row in place — only
    /// `removeAgent` drops a row back into the menu.
    @Published var addedAgents: Set<String> {
        didSet { store.set(Array(addedAgents), forKey: Key.addedAgents) }
    }

    /// The user's own agent arrangement, as an ordered list of `rawValue`s — the
    /// runtime layer that overrides each manifest's default `order` (the VSCode
    /// model: shipped defaults, user settings on top). Empty until the user drags a
    /// row in Settings, in which case `orderedAgents` falls straight through to the
    /// catalog's default order. Ids absent from the list keep catalog order and sort
    /// after ranked ones; Terminal is always pinned first regardless (see
    /// `orderedAgents`).
    @Published var agentOrder: [String] {
        didSet { store.set(agentOrder, forKey: Key.agentOrder) }
    }

    /// When on, termio installs Claude Code hooks (into `~/.claude/settings.json`)
    /// that report each turn's lifecycle, so a running agent reads as `.working`
    /// and a tool-in-use can be named — precision the zero-config bell/OSC signals
    /// can't give. Opt-in, since it edits a file termio does not own; turning it
    /// off removes termio's entries again. The `TermioStore` watches this and
    /// installs/uninstalls to match.
    @Published var agentHooksEnabled: Bool {
        didSet { store.set(agentHooksEnabled, forKey: Key.agentHooksEnabled) }
    }

    /// When on, termio runs a local control socket the `termio sessions` CLI talks
    /// to, letting one agent see and drive its sibling sessions in the same project
    /// (list / send a prompt / answer a menu / start / stop). Opt-in, since it lets
    /// an agent act on other sessions and writes a small awareness note into the
    /// user-level agent instruction files; turning it off removes that note. The
    /// `TermioStore` watches this and installs/uninstalls to match.
    @Published var sessionControlEnabled: Bool {
        didSet { store.set(sessionControlEnabled, forKey: Key.sessionControlEnabled) }
    }

    /// Whether the one-time "let your agents coordinate?" prompt has been shown, so
    /// it's offered exactly once per install and never nags. Not `@Published` — it's
    /// only read and set at launch, never bound to UI.
    var sessionControlPrompted: Bool {
        get { defaults.bool(forKey: Key.sessionControlPrompted) }
        set { defaults.set(newValue, forKey: Key.sessionControlPrompted) }
    }

    /// Gates the GitHub side of the app — today the inspector's Issues pane. The
    /// pane additionally only appears for projects whose origin remote points at
    /// github.com, so this switch is for opting out of GitHub entirely.
    @Published var githubIntegrationEnabled: Bool {
        didSet { store.set(githubIntegrationEnabled, forKey: Key.githubIntegrationEnabled) }
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


    // MARK: Notifications

    /// Whether a settled agent turn — finished, or blocked waiting on your input —
    /// in a session you aren't looking at posts a native macOS notification.
    /// Clicking the notification focuses that session. The first notification is
    /// what triggers the standard macOS permission prompt (see
    /// `TaskNotificationCenter`).
    @Published var notifyOnTaskCompletion: Bool {
        didSet { store.set(notifyOnTaskCompletion, forKey: Key.notifyTaskCompletion) }
    }

    /// Whether those notifications also play the system alert sound.
    @Published var notificationSoundEnabled: Bool {
        didSet { store.set(notificationSoundEnabled, forKey: Key.notificationSound) }
    }

    /// Resolves a Ghostty theme name against the bundled catalog, tolerating the naming drift
    /// between Ghostty's theme list and the catalog's iTerm2-Color-Schemes names
    /// ("catppuccin-latte" vs "Catppuccin Latte", "Tokyo Night" vs "tokyonight"): exact match
    /// first, then a case/separator-insensitive one. (termio's custom user themes are
    /// deliberately not consulted — a Ghostty config can only mean Ghostty's own theme names.)
    private static func resolveGhosttyTheme(_ name: String) -> GhosttyThemeDefinition? {
        if let exact = GhosttyThemeCatalog.theme(named: name) { return exact }
        let normalized = normalizeThemeName(name)
        return GhosttyThemeCatalog.allThemes.first { normalizeThemeName($0.name) == normalized }
    }

    private static func normalizeThemeName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The Ghostty config's contribution to the registration defaults — the middle layer of
    /// termio setting > Ghostty config > built-in default. Only names the bundled catalog
    /// resolves inherit; Ghostty also accepts custom theme files termio has no way to render.
    private static func ghosttyRegistrationOverrides(from ghostty: GhosttyUserConfig) -> [String: Any] {
        var overrides: [String: Any] = [:]
        if let family = ghostty.fontFamilies.first { overrides[Key.fontFamily] = family }
        if let size = ghostty.fontSize { overrides[Key.fontSize] = size }
        switch ghostty.themeSetting {
        case .bare(let name):
            // Ghostty applies a bare `theme = X` in both appearances, but termio wraps the
            // terminal in light/dark *chrome* — a dark theme inherited into the light slot
            // makes a half-dark window (light sidebar, dark canvas). A bare theme lands only
            // in the appearance it belongs to; the other slot keeps termio's own canvas.
            if let definition = resolveGhosttyTheme(name) {
                materializeInheritedTheme(definition)
                overrides[definition.isDark ? Key.darkThemeName : Key.lightThemeName] = definition.name
            }
        case .split(let light, let dark):
            if let light, let definition = resolveGhosttyTheme(light) {
                materializeInheritedTheme(definition)
                overrides[Key.lightThemeName] = definition.name
            }
            if let dark, let definition = resolveGhosttyTheme(dark) {
                materializeInheritedTheme(definition)
                overrides[Key.darkThemeName] = definition.name
            }
        case nil:
            break
        }
        return overrides
    }

    /// Gives an inherited Ghostty theme a file in termio's `Themes` folder before
    /// it is written into a slot. A slot resolves against the library only, so an
    /// inherited name that stayed a catalog lookup would paint nothing — and it
    /// re-runs whenever the user's Ghostty config names a theme they haven't got,
    /// which the one-time upgrade pass below cannot do.
    private static func materializeInheritedTheme(_ definition: GhosttyThemeDefinition) {
        do {
            try ThemeLibrary.materializeFromCatalog(named: definition.name)
        } catch {
            Log.app.error("could not materialize inherited theme \(definition.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-time upgrade: an installed termio picked its themes from a catalog that
    /// the library no longer consults, so each occupied slot gets its file written
    /// once. Two files at most — never the catalog — and existing selections keep
    /// painting because they become library entries.
    private func materializeSelectedThemes() {
        guard !defaults.bool(forKey: Key.themesMaterialized) else { return }
        for name in [lightThemeName, darkThemeName] {
            do {
                try ThemeLibrary.materializeFromCatalog(named: name)
            } catch {
                Log.app.error("could not materialize selected theme \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        defaults.set(true, forKey: Key.themesMaterialized)
    }

    init(defaults: UserDefaults = .standard, settingsStore: SettingsStore? = nil) {
        self.defaults = defaults
        self.store = settingsStore ?? SettingsStore(defaults: defaults)

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

        // Carry an existing install's own choices into `settings.json` before
        // anything below writes a shipped default into the same domain. The
        // persistent domain is exactly what the user picked, so a fresh install
        // has nothing to carry and gets no file until it changes something.
        self.store.migrateIfNeeded(managing: Self.fileManagedKeys)

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

        var registered: [String: Any] = [
            Key.fontFamily: "SF Mono",
            Key.fontSize: 13.0,
            Key.fontThicken: false,
            Key.codeLineHeight: 1.5,
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
            // On by default: the pane is read-only and only appears for projects
            // with a GitHub remote, so there is nothing to opt into until then.
            Key.githubIntegrationEnabled: true,
            Key.projectSortOrder: "name",
            // Notifications ship on (macOS's own permission prompt is the real
            // gate); the sound stays opt-in so a finishing agent is never noisy
            // by default.
            Key.notifyTaskCompletion: true,
            Key.notificationSound: false,
        ]

        // Ghostty inheritance: a user's own Ghostty config upgrades the *defaults* only —
        // anything set in termio lives in the persistent domain and still wins, and without a
        // Ghostty install the built-ins above stand. Resolution order is therefore
        // termio setting > Ghostty config > built-in default, courtesy of UserDefaults'
        // registration-domain layering. Read once per launch.
        let ghostty = GhosttyUserConfig.load()
        inheritsGhosttyDefaults = !ghostty.isEmpty
        ghosttyFontFallbacks = Array(ghostty.fontFamilies.dropFirst())
        registered.merge(Self.ghosttyRegistrationOverrides(from: ghostty)) { _, ghosttyValue in
            ghosttyValue
        }

        defaults.register(defaults: registered)

        fontFamily = store.string(Key.fontFamily) ?? ""
        fontSize = store.double(Key.fontSize)
        fontThicken = store.bool(Key.fontThicken)
        codeLineHeight = store.double(Key.codeLineHeight)
        appearanceMode = store.string(Key.appearanceMode).flatMap(AppearanceMode.init) ?? .system
        lightThemeName = store.string(Key.lightThemeName) ?? ""
        darkThemeName = store.string(Key.darkThemeName) ?? ""
        cursorStyle = store.string(Key.cursorStyle).flatMap(CursorStyle.init) ?? .block
        cursorBlink = store.bool(Key.cursorBlink)
        windowPadding = store.integer(Key.windowPadding)
        backgroundOpacity = store.double(Key.backgroundOpacity)
        backgroundBlur = store.integer(Key.backgroundBlur)
        scrollbackMegabytes = store.integer(Key.scrollbackMegabytes)
        copyOnSelect = store.bool(Key.copyOnSelect)
        interfaceFontFamily = store.string(Key.interfaceFontFamily) ?? ""
        interfaceFontSize = store.double(Key.interfaceFontSize)
        interfaceRowPadding = store.double(Key.interfaceRowPadding)
        agentCommandOverrides = store.stringDictionary(Key.agentCommands) ?? [:]
        bypassPermissionAgents = Set(store.stringArray(Key.bypassPermissionAgents) ?? [])
        disabledAgents = Set(store.stringArray(Key.disabledAgents) ?? [])
        addedAgents = Set(store.stringArray(Key.addedAgents) ?? [])
        agentOrder = store.stringArray(Key.agentOrder) ?? []
        agentHooksEnabled = store.bool(Key.agentHooksEnabled)
        sessionControlEnabled = store.bool(Key.sessionControlEnabled)
        githubIntegrationEnabled = store.bool(Key.githubIntegrationEnabled)
        usageAuthorizedAgents = Set(defaults.stringArray(forKey: Key.usageAuthorizedAgents) ?? [])
        claudeKeychainDeclined = defaults.bool(forKey: Key.claudeKeychainDeclined)
        notifyOnTaskCompletion = store.bool(Key.notifyTaskCompletion)
        notificationSoundEnabled = store.bool(Key.notificationSound)
        projectSortOrder = store.string(Key.projectSortOrder).flatMap(ProjectSortOrder.init) ?? .name
        recentProjects = defaults.data(forKey: Key.recentProjects)
            .flatMap { try? JSONDecoder().decode([RecentProject].self, from: $0) } ?? []
        lastChatAgentID = defaults.string(forKey: Key.lastChatAgent)
        defaultChatAgentID = store.string(Key.defaultChatAgent)
        currentDeviceAlias = defaults.string(forKey: Key.currentDevice)

        materializeSelectedThemes()
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
