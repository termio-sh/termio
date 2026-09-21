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
        Key.agentCommands, Key.devices,
        Key.bypassPermissionAgents, Key.agentArguments, Key.disabledAgents,
        Key.addedAgents, Key.agentOrder, Key.agentHooksEnabled, Key.keepDisplayAwakeWhileWorking,
        Key.sessionControlEnabled, Key.githubIntegrationEnabled,
        Key.notifyTaskCompletion, Key.notificationSound,
        Key.analyticsEnabled,
        Key.projectSortOrder, Key.defaultChatAgent, Key.dimIgnoredFiles,
        Key.diffSplitView,
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
        /// Set once the Themes folder has been swept of the file copies the old
        /// theme store installed, so the upgrade pass runs exactly once (see
        /// `pruneRedundantThemeCopies`).
        static let catalogCopiesPruned = "appearance.catalogCopiesPruned"
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
        /// Legacy per-app command overrides, read once to migrate an existing
        /// install into `devices` — where a command path has the machine
        /// dimension it always needed.
        static let agentCommands = "agents.commandOverrides"
        /// The per-machine section. Nested rather than flat because its keys are
        /// machine identities, which are discovered, not enumerable up front.
        static let devices = "devices"
        static let bypassPermissionAgents = "agents.bypassPermissions"
        /// Extra arguments the user wants every session of an agent to start
        /// with, by `rawValue`. Flat rather than nested under `devices` because
        /// they describe the agent, not the box it runs on.
        static let agentArguments = "agents.arguments"
        static let disabledAgents = "agents.disabled"
        static let addedAgents = "agents.added"
        static let agentOrder = "agents.order"
        static let keepDisplayAwakeWhileWorking = "agents.keepDisplayAwakeWhileWorking"
        static let agentHooksEnabled = "agents.hooksEnabled"
        static let sessionControlEnabled = "agents.sessionControlEnabled"
        static let sessionControlPrompted = "agents.sessionControlPrompted"
        static let usageAuthorizedAgents = "usage.authorizedAgents"
        static let claudeKeychainDeclined = "usage.claudeKeychainDeclined"
        static let githubIntegrationEnabled = "github.integrationEnabled"
        static let notifyTaskCompletion = "notifications.taskCompletion"
        static let notificationSound = "notifications.sound"
        static let analyticsEnabled = "privacy.analyticsEnabled"
        static let dimIgnoredFiles = "files.dimIgnoredFiles"
        static let diffSplitView = "diff.splitView"
        static let projectSortOrder = "sidebar.projectSortOrder"
        static let recentProjects = "welcome.recentProjects"
        static let lastChatAgent = "chats.lastAgent"
        static let defaultChatAgent = "chats.defaultAgent"
        static let currentDevice = "devices.current"
        static let currentWorkspace = "workspaces.current"
    }

    // MARK: Appearance

    /// Extra `font-family` entries from the user's Ghostty config (everything after the primary
    /// face) — passed to the terminal as a fallback chain, so glyphs the chosen font lacks (CJK
    /// above all) resolve the same way they do in Ghostty itself. Empty without a Ghostty config.
    let ghosttyFontFallbacks: [String]
    /// True when a Ghostty config contributed defaults this launch — surfaces one hint line in
    /// Appearance so inherited values aren't a mystery.
    let inheritsGhosttyDefaults: Bool

    @Published var dimIgnoredFiles: Bool {
        didSet { store.set(dimIgnoredFiles, forKey: Key.dimIgnoredFiles) }
    }

    /// Whether a maximized diff shows its two columns side by side. A preference rather than
    /// per-diff state: the shape a reader wants a diff in is a habit, so it follows them from
    /// file to file and across launches. Only a maximized diff can honor it — a diff docked in
    /// the inspector has no width to split.
    @Published var diffSplitView: Bool {
        didSet { store.set(diffSplitView, forKey: Key.diffSplitView) }
    }

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
    /// Deliberately NOT `@Published`: nothing renders from it (the store holds the
    /// live copy), and every publish here wakes the store's settings observer,
    /// which restyles every open terminal surface and re-checks the agent hook
    /// files on disk. Paying that to write one string is what made moving between
    /// machines hitch.
    var currentDeviceAlias: String? {
        didSet { defaults.set(currentDeviceAlias, forKey: Key.currentDevice) }
    }

    /// The workspace the sidebar was showing when the app last closed. State, not
    /// a preference — the same reason `currentDeviceAlias` lives here. The state
    /// file carries the authoritative copy; this one covers the launch before the
    /// store has been built.
    /// Not `@Published`, for the reason `currentDeviceAlias` above is not.
    var currentWorkspaceID: UUID? {
        didSet { defaults.set(currentWorkspaceID?.uuidString, forKey: Key.currentWorkspace) }
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

    /// Whether the window and the surfaces in it must stay see-through. Opacity is the
    /// only input: blur softens what shows through a transparent background, so reading
    /// it here left a stored blur value holding the window transparent after opacity
    /// went back to full — with the Blur stepper disabled at that point, unfixable.
    var isBackgroundTranslucent: Bool { backgroundOpacity < 1.0 }

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

    /// Authored per-machine values, by machine (`KnownDevice.settingsKey`).
    ///
    /// A command path is a fact about one box — `/opt/homebrew/bin/claude` names
    /// nothing on a Linux VPS — so it is keyed by machine rather than held once
    /// for the app, which is what the flat `agents.commandOverrides` this replaces
    /// got wrong. Edited only from a machine's pane (RFC D1: location in the UI is
    /// the scope).
    @Published var deviceSettings: DeviceSettingsSection {
        didSet { store.set(deviceSettings.jsonObject, forKey: Key.devices) }
    }

    /// Agents whose permission/approval prompts should be bypassed, by `rawValue`.
    /// The per-agent switch appends `AgentPreset.permissionBypassFlag` to the
    /// resolved command (see `command(for:)`). Opt-in and stored as the on-set so
    /// the default (nothing stored) means every agent keeps its prompts.
    @Published var bypassPermissionAgents: Set<String> {
        didSet { store.set(Array(bypassPermissionAgents), forKey: Key.bypassPermissionAgents) }
    }

    /// Extra arguments appended to an agent's command on every launch, by
    /// `rawValue` — `--model opus`, a project flag, the agent's own bypass flag
    /// when it has one termio does not know about. Held once for the app rather
    /// than per machine for the same reason the bypass switch is: how you want an
    /// agent to run is a standing decision about that agent, while a command path
    /// is a fact about a box (RFC §The model).
    @Published var agentArguments: [String: String] {
        didSet { store.set(agentArguments.isEmpty ? nil : agentArguments, forKey: Key.agentArguments) }
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

    @Published var keepDisplayAwakeWhileWorking: Bool {
        didSet { store.set(keepDisplayAwakeWhileWorking, forKey: Key.keepDisplayAwakeWhileWorking) }
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

    // MARK: Privacy

    /// Whether termio reports one anonymous "active today" event per day, so the
    /// project can see how many installs are in use. `Analytics` is the whole of
    /// what that sends and when.
    @Published var analyticsEnabled: Bool {
        didSet { store.set(analyticsEnabled, forKey: Key.analyticsEnabled) }
    }

    /// The Ghostty config's contribution to the registration defaults — the middle layer of
    /// termio setting > Ghostty config > built-in default. Only names the bundled catalog
    /// resolves inherit; see `ThemeLibrary.catalogTheme(matching:)` for which those are.
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
            if let definition = ThemeLibrary.catalogTheme(matching: name) {
                overrides[definition.isDark ? Key.darkThemeName : Key.lightThemeName] = definition.name
            }
        case .split(let light, let dark):
            if let definition = ThemeLibrary.catalogTheme(matching: light) {
                overrides[Key.lightThemeName] = definition.name
            }
            if let definition = ThemeLibrary.catalogTheme(matching: dark) {
                overrides[Key.darkThemeName] = definition.name
            }
        case nil:
            break
        }
        return overrides
    }

    /// One-time upgrade: the old theme store installed a scheme by copying its file
    /// into the `Themes` folder. The library resolves those schemes without a file
    /// now, so an untouched copy is dead weight that would also freeze that theme
    /// at whatever palette it shipped with the day it was installed. Files the user
    /// has edited are left alone — see `removeRedundantCatalogCopies`.
    private func pruneRedundantThemeCopies() {
        guard !defaults.bool(forKey: Key.catalogCopiesPruned) else { return }
        let removed = ThemeLibrary.removeRedundantCatalogCopies()
        if removed > 0 {
            Log.app.info("removed \(removed, privacy: .public) redundant theme copies")
        }
        defaults.set(true, forKey: Key.catalogCopiesPruned)
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
            Key.dimIgnoredFiles: true,
            Key.diffSplitView: false,
            Key.copyOnSelect: false,
            Key.interfaceFontFamily: "",
            Key.interfaceFontSize: 13.0,
            Key.interfaceRowPadding: 2.0,
            Key.agentHooksEnabled: false,
            Key.keepDisplayAwakeWhileWorking: false,
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
            // On by default. It is one event a day carrying no path, no content
            // and no identity, and the toggle beside it says exactly that — a
            // count nobody can opt into is a count that measures the wrong people.
            Key.analyticsEnabled: true,
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

        dimIgnoredFiles = store.bool(Key.dimIgnoredFiles)
        diffSplitView = store.bool(Key.diffSplitView)
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
        deviceSettings = DeviceSettingsSection(jsonObject: store.object(Key.devices))
        bypassPermissionAgents = Set(store.stringArray(Key.bypassPermissionAgents) ?? [])
        agentArguments = store.stringDictionary(Key.agentArguments) ?? [:]
        disabledAgents = Set(store.stringArray(Key.disabledAgents) ?? [])
        addedAgents = Set(store.stringArray(Key.addedAgents) ?? [])
        agentOrder = store.stringArray(Key.agentOrder) ?? []
        agentHooksEnabled = store.bool(Key.agentHooksEnabled)
        keepDisplayAwakeWhileWorking = store.bool(Key.keepDisplayAwakeWhileWorking)
        sessionControlEnabled = store.bool(Key.sessionControlEnabled)
        githubIntegrationEnabled = store.bool(Key.githubIntegrationEnabled)
        usageAuthorizedAgents = Set(defaults.stringArray(forKey: Key.usageAuthorizedAgents) ?? [])
        claudeKeychainDeclined = defaults.bool(forKey: Key.claudeKeychainDeclined)
        notifyOnTaskCompletion = store.bool(Key.notifyTaskCompletion)
        notificationSoundEnabled = store.bool(Key.notificationSound)
        analyticsEnabled = store.bool(Key.analyticsEnabled)
        projectSortOrder = store.string(Key.projectSortOrder).flatMap(ProjectSortOrder.init) ?? .name
        recentProjects = defaults.data(forKey: Key.recentProjects)
            .flatMap { try? JSONDecoder().decode([RecentProject].self, from: $0) } ?? []
        lastChatAgentID = defaults.string(forKey: Key.lastChatAgent)
        defaultChatAgentID = store.string(Key.defaultChatAgent)
        currentDeviceAlias = defaults.string(forKey: Key.currentDevice)
        currentWorkspaceID = defaults.string(forKey: Key.currentWorkspace).flatMap(UUID.init)

        pruneRedundantThemeCopies()
        migrateCommandOverridesToThisMac()
    }

    /// Moves an existing install's per-app command overrides onto **this Mac**,
    /// which is the only machine they could ever have described: they were typed
    /// while Settings meant this one, and the paths in them (`/opt/homebrew/…`)
    /// name this filesystem. Runs once — the legacy key is cleared as it is read,
    /// so a later Mac-side edit is never re-migrated over.
    private func migrateCommandOverridesToThisMac() {
        guard let legacy = store.stringDictionary(Key.agentCommands), !legacy.isEmpty else { return }
        var thisMac = deviceSettings[KnownDevice.thisMac.settingsKey]
        // Anything already authored per-machine wins: the user set it in the new
        // world, and a stale flat value must not overwrite it.
        thisMac.agentCommands = legacy.merging(thisMac.agentCommands ?? [:]) { _, authored in authored }
        deviceSettings[KnownDevice.thisMac.settingsKey] = thisMac
        store.set(nil, forKey: Key.agentCommands)
    }

    /// Effective command for an agent **on a machine**: the path authored for that
    /// machine if it's non-empty, otherwise the preset's built-in default (`nil`
    /// for a plain login shell), then the user's own arguments, then the
    /// permission-bypass flag when that switch is on. The flag is only added if it
    /// isn't already present anywhere in the line, so a user who typed it into the
    /// path or the arguments by hand doesn't get it twice.
    ///
    /// The path is per-machine and the other two are not: where a CLI lives is a
    /// fact about a box, while how you want the agent to run is a standing
    /// decision about that agent (RFC §The model).
    func command(for agent: AgentPreset, on device: KnownDevice = .thisMac) -> String? {
        let authored = commandPath(for: agent, on: device)
        let base = (authored?.isEmpty == false ? authored : agent.command)
        guard let base else { return nil }
        var command = base
        if let extra = arguments(for: agent) {
            command += " \(extra)"
        }
        guard bypassesPermissions(agent), let flag = agent.permissionBypassFlag,
              !command.contains(flag) else { return command }
        return "\(command) \(flag)"
    }

    /// What each listed agent launches with on `device`, by id: the path the
    /// user authored where they authored one, the manifest's default otherwise.
    ///
    /// Sent with every install and probe, because the daemon has to judge
    /// presence against the binary a session would really run. Settings lets a
    /// path be anywhere — an agent deliberately kept off `PATH` is the whole
    /// reason to type one — and judging it by the manifest's bare command
    /// answers "not here" for a CLI the app has just reported available.
    /// The **whole catalog**, not the user's list: the probe asks about every
    /// agent because coverage is a fact about the machine, and the daemon
    /// installs against its own catalog. Handing the install a smaller map than
    /// the probe used is how an unlisted agent with an authored path got probed
    /// as present and then skipped by the install that was told to cover it.
    func authoredCommands(on device: KnownDevice = .thisMac) -> [String: String] {
        var commands: [String: String] = [:]
        for agent in AgentPreset.codingAgents {
            guard let command = command(for: agent, on: device) else { continue }
            commands[agent.rawValue] = command
        }
        return commands
    }

    /// The arguments the user authored for this agent, or `nil` when they never
    /// set any — the same empty-means-unset rule the command path follows, which
    /// is what keeps a cleared field out of `settings.json`.
    func arguments(for agent: AgentPreset) -> String? {
        let authored = agentArguments[agent.rawValue]?.trimmingCharacters(in: .whitespaces)
        return authored?.isEmpty == false ? authored : nil
    }

    func setArguments(_ arguments: String?, for agent: AgentPreset) {
        let trimmed = arguments?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty {
            agentArguments[agent.rawValue] = trimmed
        } else {
            agentArguments.removeValue(forKey: agent.rawValue)
        }
    }

    /// The command path the user authored for this agent on this machine, before
    /// any bypass flag — what the machine's pane edits. `nil` when they never set
    /// one, which is how the field shows the built-in default as its placeholder
    /// rather than pinning today's value as a choice.
    func commandPath(for agent: AgentPreset, on device: KnownDevice) -> String? {
        deviceSettings[device.settingsKey].agentCommands?[agent.rawValue]?
            .trimmingCharacters(in: .whitespaces)
    }

    func setCommandPath(_ path: String?, for agent: AgentPreset, on device: KnownDevice) {
        var machine = deviceSettings[device.settingsKey]
        var commands = machine.agentCommands ?? [:]
        let trimmed = path?.trimmingCharacters(in: .whitespaces)
        // An emptied field hands the agent back to its built-in default instead of
        // storing "" — the same rule `SettingsStore.set(nil:)` follows for a
        // cleared preference.
        if let trimmed, !trimmed.isEmpty {
            commands[agent.rawValue] = trimmed
        } else {
            commands.removeValue(forKey: agent.rawValue)
        }
        machine.agentCommands = commands.isEmpty ? nil : commands
        deviceSettings[device.settingsKey] = machine
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
