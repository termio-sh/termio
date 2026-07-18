import SwiftUI

/// What a new session launches: a plain login shell, or a coding agent CLI.
/// Formerly a closed `enum AgentPreset`; now a value type so bundled manifests and
/// any the user drops into `~/.termio/config/agents/` flow through the same shape and
/// decode path. `AgentCatalog` resolves both sources once at launch. Equality and persistence
/// are by `id` alone — the same stable slug the old enum used as its `rawValue`
/// (`claudeCode` / `codex` / …), so existing `state.json` files deserialize with
/// no migration.
struct AgentDefinition: Identifiable {
    /// Stable slug, aligned with the old `AgentPreset.rawValue`. The persistence
    /// key, the settings-dictionary key, and the identity used for equality.
    let id: String
    let displayName: String
    /// Program launched in the session, or `nil` for the user's login shell. The
    /// CLIs are expected on `PATH`; if missing, the terminal shows the shell's
    /// "command not found", which is the right place to surface it.
    let command: String?
    /// The flag that makes this agent bypass its own permission prompts — the
    /// "YOLO" switch, spelled differently by each CLI. `nil` when there's no flag
    /// stable enough to wire to a one-click toggle (the free-text command override
    /// still accepts any flag). Composed on by `AppSettings.command(for:)`.
    let permissionBypassFlag: String?
    /// How (and whether) a relaunch resumes this agent's prior conversation.
    let resumeStyle: ResumeStyle
    let icon: AgentIcon
    /// The agent's representative color, used to tint the "working" spinner so a
    /// busy session pulses in its own brand color. Marks without a single brand
    /// color (and the plain terminal) fall back to adaptive ink.
    let tint: Color
    /// The vendor's install page, opened from the Settings row when the binary
    /// isn't found on `PATH`. `nil` for the plain shell and user agents.
    let installURL: URL?
    /// The token this agent is named by on the companion (phone) wire protocol.
    /// Kept stable and distinct from `id` only where the two historically differ
    /// (`claudeCode` → `claude`); everything else, including user agents, is `id`.
    let wireName: String
    /// Screen-scrape rules that classify this agent's rendered viewport into
    /// working / needs-attention, for agents that ship no hook system. `nil` for the
    /// built-ins (they use the precise hook layer) and for user agents that declared
    /// no `status` block (or that declared `hooks`, which take authority). See
    /// `AgentStatusRules`.
    let statusRules: AgentStatusRules?
    /// A manifest's declarative hook integration: the destination owned by the agent,
    /// a closed installer/dialect, and its event→state mapping.
    /// When present it is installed by `AgentStatusHooks` and becomes the session's
    /// status authority — so `statusRules` is left `nil` and screen-scrape is skipped,
    /// keeping one source of truth per pane. See `AgentHookSpec`.
    let hookSpec: AgentHookSpec?

    /// All fields after `wireName` are optional so the built-in roster and the
    /// fallback don't each have to spell them out.
    init(
        id: String, displayName: String, command: String?, permissionBypassFlag: String?,
        resumeStyle: ResumeStyle, icon: AgentIcon,
        tint: Color, installURL: URL?, wireName: String,
        statusRules: AgentStatusRules? = nil, hookSpec: AgentHookSpec? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.command = command
        self.permissionBypassFlag = permissionBypassFlag
        self.resumeStyle = resumeStyle
        self.icon = icon
        self.tint = tint
        self.installURL = installURL
        self.wireName = wireName
        self.statusRules = statusRules
        self.hookSpec = hookSpec
    }

    /// Compatibility shim for the many call sites and settings dictionaries that
    /// still address an agent by its old string `rawValue` — which is just `id`.
    var rawValue: String { id }

    /// The spinner/badge tint. Named `tintColor` for the call sites that predate
    /// the value-type migration (notably `WorkingIndicator`).
    var tintColor: Color { tint }

    /// Whether this agent lets termio pin its conversation id up front so a relaunch
    /// resumes the exact prior session (Claude Code, Pi).
    var usesPinnedResumeID: Bool { resumeStyle == .claudeStyle || resumeStyle == .piStyle }

    /// Whether this agent's id can't be set up front but *can* be discovered from its
    /// own session store afterward and resumed by id (Codex, OpenCode).
    var usesDiscoveredResumeID: Bool { resumeStyle == .codexStyle || resumeStyle == .openCodeStyle }

    /// How a relaunch continues (or doesn't) this agent's prior conversation.
    enum ResumeStyle: Hashable {
        case none
        case claudeStyle
        case piStyle
        case codexStyle
        case openCodeStyle

        /// The agent's conversation id read from its live transcript *path*, for
        /// styles whose filename encodes the id. termio uses this to advance a
        /// session's pinned `resumeID` after the agent rotates its conversation
        /// mid-session — Claude Code's `/clear` mints a new id and transcript and
        /// orphans the old file, which the once-pinned id would otherwise keep
        /// resuming. Returns nil when the id is not in the filename (Codex/OpenCode
        /// carry it *inside* the file, so advancing those is re-discovery's job, not
        /// path parsing) or the style does not resume. See
        /// docs/design/agent-resume-identity.md.
        func conversationID(fromTranscriptPath path: String) -> String? {
            switch self {
            case .claudeStyle:
                // Claude names the transcript exactly `<conversation-id>.jsonl`; strip
                // the suffix directly rather than via `deletingPathExtension`, which
                // mishandles a leading-dot name (a stray `.jsonl` would survive as an id).
                let file = (path as NSString).lastPathComponent
                guard file.hasSuffix(".jsonl") else { return nil }
                let id = String(file.dropLast(".jsonl".count))
                return id.isEmpty ? nil : id
            case .piStyle, .codexStyle, .openCodeStyle, .none:
                // Pi encodes the id in the filename too (`<timestamp>_<id>.jsonl`),
                // but its transcript discovery isn't wired yet; Codex/OpenCode keep
                // the id inside the file. All advance via re-discovery (Phase 3),
                // not here — see the design doc.
                return nil
            }
        }
    }

    /// Inputs the resume decision needs that only `TermioStore` can supply.
    struct ResumeContext {
        /// The stable id termio pinned for this session (meaningful only when
        /// `usesPinnedResumeID`).
        var resumeID: String
        /// Whether this session's agent has been launched in a prior app run.
        var launchedBefore: Bool
        /// Whether Claude Code already has a saved conversation under `resumeID`.
        /// Resuming one that doesn't exist errors, so a pinned-but-never-used session
        /// is (re)created with `--session-id` instead.
        var pinnedConversationExists: Bool
    }

    /// The argument fragment to append to the resolved base command so this session
    /// continues its prior conversation on relaunch, or `nil` to launch fresh.
    func resumeArguments(_ context: ResumeContext) -> String? {
        switch resumeStyle {
        case .none:
            return nil
        case .claudeStyle:
            // `--session-id` creates a session with our id (and errors if it already
            // exists); `--resume` resumes it (and errors if it doesn't). So create
            // until a conversation has been saved, and resume once one exists.
            return context.pinnedConversationExists
                ? "--resume \(context.resumeID)"
                : "--session-id \(context.resumeID)"
        case .piStyle:
            // Pi's `--session-id` creates the session when missing and resumes it
            // otherwise, so the same flag is correct on every launch.
            return "--session-id \(context.resumeID)"
        case .codexStyle:
            // Resume the exact session once its id has been discovered; until then
            // continue the most recent recorded session in this directory.
            if !context.resumeID.isEmpty { return "resume \(context.resumeID)" }
            return context.launchedBefore ? "resume --last" : nil
        case .openCodeStyle:
            if !context.resumeID.isEmpty { return "--session \(context.resumeID)" }
            return context.launchedBefore ? "--continue" : nil
        }
    }
}

/// Identity, equality, and persistence are all by `id`, so an agent value compares
/// equal to its `.claudeCode` (etc.) constant, works as a dictionary key, and
/// round-trips through `state.json` as the bare id string the old enum wrote.
extension AgentDefinition: Hashable {
    static func == (lhs: AgentDefinition, rhs: AgentDefinition) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension AgentDefinition: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(String.self)
        self = AgentCatalog.shared.definition(for: id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

// MARK: - Fallback

extension AgentDefinition {
    /// A stand-in for a session that references an agent id no longer present (a user
    /// agent whose folder was deleted). It degrades to a plain shell but keeps the id
    /// and shows it as the title, so the session survives rather than being dropped —
    /// per the project's "surface failures rather than crashing" rule.
    static func fallback(id: String) -> AgentDefinition {
        AgentDefinition(
            id: id, displayName: id, command: nil, permissionBypassFlag: nil,
            resumeStyle: .none,
            icon: .symbol("questionmark.app"), tint: .monochromeInk,
            installURL: nil, wireName: id)
    }
}

// MARK: - Compatibility statics (leading-dot & enum-shaped call sites)

extension AgentDefinition {
    /// Every known agent: the built-ins plus any the user has installed. Replaces the
    /// old `AgentPreset.allCases`; the pickers, the roster, and name resolution all
    /// read from here, so user agents appear everywhere built-ins do.
    static var allCases: [AgentDefinition] { AgentCatalog.shared.all }

    // Compatibility conveniences for enum-shaped call sites. These are catalog
    // lookups, not definitions: every fact still comes from the corresponding JSON
    // manifest, and a newly added agent needs no Swift member.
    static var terminal: AgentDefinition { AgentCatalog.shared.definition(for: "terminal") }
    static var claudeCode: AgentDefinition { AgentCatalog.shared.definition(for: "claudeCode") }
    static var codex: AgentDefinition { AgentCatalog.shared.definition(for: "codex") }
    static var opencode: AgentDefinition { AgentCatalog.shared.definition(for: "opencode") }
    static var pi: AgentDefinition { AgentCatalog.shared.definition(for: "pi") }
    static var amp: AgentDefinition { AgentCatalog.shared.definition(for: "amp") }
    static var cursor: AgentDefinition { AgentCatalog.shared.definition(for: "cursor") }
    static var kimi: AgentDefinition { AgentCatalog.shared.definition(for: "kimi") }
    static var antigravity: AgentDefinition { AgentCatalog.shared.definition(for: "antigravity") }
    static var hermes: AgentDefinition { AgentCatalog.shared.definition(for: "hermes") }
    static var grok: AgentDefinition { AgentCatalog.shared.definition(for: "grok") }

    init?(rawValue: String) {
        guard let definition = AgentCatalog.shared.find(id: rawValue) else { return nil }
        self = definition
    }

    /// Resolves a free-text agent name from the CLI (`termio sessions start claude`)
    /// to a definition, accepting the id, the display name, and common aliases.
    static func resolve(_ raw: String?) -> AgentDefinition? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return nil
        }
        for definition in allCases
        where definition.id.lowercased() == raw || definition.displayName.lowercased() == raw {
            return definition
        }
        switch raw {
        case "claude", "claude-code", "claudecode", "cc": return .claudeCode
        case "oc": return .opencode
        case "shell", "term": return .terminal
        default: return nil
        }
    }
}

/// The name the old closed enum carried. Kept as an alias so the type name at the
/// hundreds of existing call sites keeps compiling unchanged.
typealias AgentPreset = AgentDefinition

// MARK: - Screen-scrape status rules

/// Classifies an agent's rendered viewport into an activity state, for agents that
/// have no hook system (the long tail of CLIs, and every user agent in this cut).
/// This is the herdr approach — the screen is the source of truth — kept deliberately
/// small: two regex lists, whole-viewport match, precedence `attention > working >
/// idle`. No regions / priorities / remote manifests. The same viewport read that
/// drives the stale-working sweep is fed here, so it costs one extra regex pass a
/// second while a rule-carrying session is open.
struct AgentStatusRules {
    /// Patterns that mean "the agent is mid-turn" (its ticking spinner, a "thinking"
    /// line). Any match → working.
    let working: [NSRegularExpression]
    /// Patterns that mean "the agent is blocked on the user" — a permission prompt, a
    /// yes/no question, a "waiting for input" line. Any match → needs-attention, and
    /// it wins over `working` because a prompt can sit under a still-spinning header.
    let attention: [NSRegularExpression]

    enum Activity: Hashable {
        case working
        case attention
        case idle
    }

    func classify(_ screen: String) -> Activity { explain(screen).activity }

    /// Like `classify`, but also returns the source pattern that decided the state
    /// (or `nil` when nothing matched → idle). Feeds the `TERMIO_STATUS_TRACE`
    /// diagnostic so a user tuning their `status` regex can see exactly which rule
    /// fired on the live screen — the analogue of `herdr agent explain`.
    func explain(_ screen: String) -> (activity: Activity, matched: String?) {
        let range = NSRange(screen.startIndex..., in: screen)
        if let hit = attention.first(where: { $0.firstMatch(in: screen, range: range) != nil }) {
            return (.attention, hit.pattern)
        }
        if let hit = working.first(where: { $0.firstMatch(in: screen, range: range) != nil }) {
            return (.working, hit.pattern)
        }
        return (.idle, nil)
    }

    /// Appends one classification line to `/tmp/termio-status.log` when
    /// `TERMIO_STATUS_TRACE` is set — mirroring the hook layer's `TERMIO_HOOK_TRACE`.
    /// Costs nothing in normal runs (the caller checks the env once and skips this).
    static func trace(agent: String, session: Session.ID, activity: Activity, matched: String?) {
        let rule = matched.map { "/\($0)/" } ?? "(no match → idle)"
        let line = "[\(session.uuidString.prefix(8))] \(agent) → \(activity) \(rule)\n"
        let url = URL(fileURLWithPath: "/tmp/termio-status.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Builds rules from a user's raw pattern lists, compiling case-insensitively and
    /// dropping (with a log) any pattern that isn't valid regex, so one typo can't sink
    /// the agent. Returns `nil` when nothing usable is declared, which leaves the agent
    /// on the zero-config bell/OSC signal instead.
    static func from(working: [String]?, attention: [String]?, label: String) -> AgentStatusRules? {
        let compiledWorking = compile(working, label: label)
        let compiledAttention = compile(attention, label: label)
        guard !compiledWorking.isEmpty || !compiledAttention.isEmpty else { return nil }
        return AgentStatusRules(working: compiledWorking, attention: compiledAttention)
    }

    private static func compile(_ patterns: [String]?, label: String) -> [NSRegularExpression] {
        (patterns ?? []).compactMap { pattern in
            do {
                return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            } catch {
                AgentCatalog.log("\(label): ignoring invalid status pattern /\(pattern)/: \(error)")
                return nil
            }
        }
    }
}

// MARK: - Hook integration (config-driven, no agent-provided code)

/// The closed installer shape a manifest may select. Config describes where and
/// when to invoke termio's report contract; it never supplies executable contents.
enum AgentHookType: String, Hashable {
    case json
    case toml
    case plugin
}

struct AgentHookEvent: Hashable {
    let name: String
    let state: String
    let matcher: String?
}

struct AgentHookSpec: Hashable {
    let type: AgentHookType
    /// Exact destination for JSON/TOML, e.g. `~/.claude/settings.json`.
    let file: String?
    /// Plugin directory for dialect-owned shipped templates. The dialect chooses
    /// the fixed filename and source shape; the manifest cannot inject code.
    let directory: String?
    let dialect: HookDialect
    let capturesTranscript: Bool
    let events: [AgentHookEvent]
}

// MARK: - Catalog (bundled + user manifests)

/// Owns the merged set of agent definitions. Both sources decode through
/// `AgentManifest`; only their directory layout differs until Cut 4 migrates the
/// legacy user folders. Loaded once, with no hot reload.
final class AgentCatalog {
    static let shared = AgentCatalog()

    let all: [AgentDefinition]
    /// Retained so a user override that removes or redirects a shipped hook can
    /// clean the old managed entry before installing its replacement.
    let bundled: [AgentDefinition]
    private let commandIndex: [String: AgentDefinition]

    private init() {
        let bundled = Self.loadBundledAgents()
        Self.migrateLegacyUserAgents()
        // A failed/colliding migration remains readable in its old location; flat
        // config wins when both sources intentionally carry the same id.
        let legacy = Self.loadLegacyUserAgents()
        let user = Self.merge(legacy, overriddenBy: Self.loadUserAgents())
        let all = Self.merge(bundled, overriddenBy: user)
        self.bundled = bundled
        self.all = all
        var index: [String: AgentDefinition] = [:]
        for definition in all {
            guard let command = definition.command else { continue }
            let firstToken = command.split(separator: " ").first.map(String.init) ?? command
            index[Self.leafName(firstToken)] = definition
        }
        commandIndex = index
    }

    func find(id: String) -> AgentDefinition? {
        all.first { $0.id == id }
    }

    /// Language runtimes an agent's CLI may be executed through, so a `node …/cli.js`
    /// or `bun …/index.ts` invocation still resolves to the agent, not the runtime.
    private static let runtimeCommands: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "npx", "env",
        "sh", "bash", "zsh", "dash", "fish", "tsx", "ts-node",
    ]

    /// The characters that separate the meaningful components of a script path or
    /// npm package spec (`…/@anthropic-ai/claude-code/cli.js` → claude), used to
    /// recognize a wrapped agent by a directory in its path.
    private static let pathSeparators = CharacterSet(charactersIn: "/@ .-_")

    /// Resolves the argv of a terminal's foreground process to a known agent, or
    /// `nil` for a plain shell / anything unrecognized. The mechanism herdr uses:
    /// match the running program's own name first, and when that name is a language
    /// runtime, identify the agent from the script it runs (by the script's own name,
    /// then by a directory in its path — npm nests the CLI under `…/claude-code/cli.js`).
    /// This is what lets a hand-started `claude` in a plain terminal become a
    /// first-class agent row without termio having launched it.
    func agent(forForegroundArguments arguments: [String]) -> AgentDefinition? {
        let tokens = arguments.filter { !$0.isEmpty }
        guard let first = tokens.first else { return nil }

        // Direct invocation: the foreground process *is* the agent binary. (A login
        // shell arrives as `-zsh`, whose leaf `zsh` simply isn't in the index.)
        if let match = commandIndex[Self.leafName(first)] { return match }

        // Runtime wrapper: identify the agent from the first non-flag argument (the
        // script being run) — first by its own name, then by a path component.
        guard Self.runtimeCommands.contains(Self.leafName(first)),
              let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") })
        else { return nil }
        if let match = commandIndex[Self.scriptName(script)] { return match }
        for component in script.lowercased().components(separatedBy: Self.pathSeparators)
        where !component.isEmpty {
            if let match = commandIndex[component] { return match }
        }
        return nil
    }

    /// A program's invocation name: its last path component, lowercased, with a login
    /// shell's leading `-` dropped (`/bin/zsh` and `-zsh` both → `zsh`).
    private static func leafName(_ argument: String) -> String {
        var name = (argument as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    /// A script's name for matching: its leaf with a JS/TS extension stripped, so
    /// `…/claude` and `…/claude.js` both key as `claude`.
    private static func scriptName(_ argument: String) -> String {
        var name = leafName(argument)
        for ext in [".js", ".mjs", ".cjs", ".ts"] where name.hasSuffix(ext) {
            name.removeLast(ext.count)
            break
        }
        return name
    }

    /// The definition for an id, or a surviving fallback when nothing matches (an
    /// orphaned session whose user agent was removed).
    func definition(for id: String) -> AgentDefinition {
        find(id: id) ?? AgentDefinition.fallback(id: id)
    }

    /// Bundled hook specs removed or redirected by full user overrides.
    var staleBundledHookSpecs: [AgentHookSpec] {
        bundled.compactMap { definition in
            guard let bundledSpec = definition.hookSpec,
                  find(id: definition.id)?.hookSpec != bundledSpec else { return nil }
            return bundledSpec
        }
    }

    private static var legacyAgentsDirectory: URL {
        AppChannel.homeConfigDirectory.appendingPathComponent("agents", isDirectory: true)
    }

    /// The channel-scoped flat manifest directory (`~/.termio[-dev]/config/agents`).
    private static var userAgentsDirectory: URL {
        AppChannel.homeConfigDirectory
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
    }

    private static func loadBundledAgents() -> [AgentDefinition] {
        guard let resourceURL = Bundle.termioResources.resourceURL else {
            log("bundled resource directory is unavailable")
            return []
        }
        let directory = resourceURL.appendingPathComponent("agents", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else {
            log("bundled agents directory is unavailable: \(directory.path)")
            return []
        }
        let manifests = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return load(manifests: manifests, resolvingRelativeTo: directory)
    }

    private static func loadUserAgents() -> [AgentDefinition] {
        let directory = userAgentsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let manifests = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return load(manifests: manifests, resolvingRelativeTo: directory)
    }

    /// Cut 3 deliberately keeps reading the folder-per-agent layout. Cut 4 moves
    /// and migrates it; JSON decoding and resolution are already shared.
    private static func loadLegacyUserAgents() -> [AgentDefinition] {
        let directory = legacyAgentsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        let manifests = entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.appendingPathComponent("agent.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return manifests.compactMap { manifestURL in
            decode(manifest: manifestURL, resolvingRelativeTo: manifestURL.deletingLastPathComponent())
        }
    }

    /// Flattens an earlier RFC's `agents/<folder>/agent.json` into
    /// `config/agents/<id>.json`. A relative icon is copied to `<id>.<ext>` and the
    /// copied JSON is updated to that sibling name. Destination collisions never
    /// overwrite; sources are removed only after both destination files are durable.
    private static func migrateLegacyUserAgents() {
        let sourceRoot = legacyAgentsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sourceRoot, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let sourceManifest = entry.appendingPathComponent("agent.json")
            guard FileManager.default.fileExists(atPath: sourceManifest.path) else { continue }
            migrateLegacyAgent(manifest: sourceManifest, directory: entry)
        }
    }

    private static func migrateLegacyAgent(manifest sourceManifest: URL, directory: URL) {
        do {
            let originalData = try Data(contentsOf: sourceManifest)
            let manifest = try JSONDecoder().decode(AgentManifest.self, from: originalData)
            guard isSafeFilename(manifest.id) else {
                log("not migrating \(sourceManifest.path): id '\(manifest.id)' is not a safe filename")
                return
            }

            let destinationDirectory = userAgentsDirectory
            let destinationManifest = destinationDirectory.appendingPathComponent("\(manifest.id).json")
            guard !FileManager.default.fileExists(atPath: destinationManifest.path) else {
                log("not overwriting existing \(destinationManifest.path) during migration")
                return
            }

            var migratedData = originalData
            var sourceIcon: URL?
            var destinationIcon: URL?
            var shouldCopyIcon = false
            if let relativePath = manifest.icon?.path,
               !relativePath.isEmpty,
               !(relativePath as NSString).expandingTildeInPath.hasPrefix("/") {
                let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL
                let sourcePrefix = directory.standardizedFileURL.path + "/"
                guard candidate.path.hasPrefix(sourcePrefix) else {
                    log("not migrating \(sourceManifest.path): relative icon escapes its agent folder")
                    return
                }
                if FileManager.default.fileExists(atPath: candidate.path) {
                    let pathExtension = candidate.pathExtension
                    let filename = pathExtension.isEmpty
                        ? "\(manifest.id)-icon"
                        : "\(manifest.id).\(pathExtension)"
                    let destination = destinationDirectory.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        // Resume safely after an interruption that copied the icon but
                        // had not yet published the manifest. A different file is a
                        // real collision and remains untouched.
                        guard try Data(contentsOf: candidate) == Data(contentsOf: destination) else {
                            log("not overwriting existing \(destination.path) during migration")
                            return
                        }
                    } else {
                        shouldCopyIcon = true
                    }
                    sourceIcon = candidate
                    destinationIcon = destination
                    migratedData = try replacingIconPath(in: originalData, with: filename)
                }
            }

            try FileManager.default.createDirectory(
                at: destinationDirectory, withIntermediateDirectories: true)
            if shouldCopyIcon, let sourceIcon, let destinationIcon {
                try FileManager.default.copyItem(at: sourceIcon, to: destinationIcon)
            }
            do {
                // `Data.write` traps (rather than throws) when `.atomic` and
                // `.withoutOverwriting` are combined. The explicit collision guard
                // above protects user files; keep the actual publication atomic.
                try migratedData.write(to: destinationManifest, options: .atomic)
            } catch {
                if shouldCopyIcon, let destinationIcon {
                    try? FileManager.default.removeItem(at: destinationIcon)
                }
                throw error
            }

            // The flat copy is complete. Remove only the source files we copied;
            // unknown files in the old folder remain for the user to inspect.
            try FileManager.default.removeItem(at: sourceManifest)
            if let sourceIcon { try FileManager.default.removeItem(at: sourceIcon) }
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try FileManager.default.removeItem(at: directory)
            }
            log("migrated \(manifest.id) to \(destinationManifest.path)")
        } catch {
            log("could not migrate \(sourceManifest.path): \(error)")
        }
    }

    private static func replacingIconPath(in data: Data, with filename: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var icon = object["icon"] as? [String: Any]
        else { return data }
        icon["path"] = filename
        object["icon"] = icon
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func isSafeFilename(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func load(manifests: [URL], resolvingRelativeTo directory: URL) -> [AgentDefinition] {
        manifests.compactMap { decode(manifest: $0, resolvingRelativeTo: directory) }
    }

    private static func decode(manifest url: URL, resolvingRelativeTo directory: URL) -> AgentDefinition? {
        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)
            return try manifest.definition(directory: directory, resourceBundle: Bundle.termioResources)
        } catch {
            log("ignoring unparseable \(url.path): \(error)")
            return nil
        }
    }

    /// Preserve a bundled picker's position when it is overridden, then append new
    /// user ids. Source iteration is filename-sorted, so duplicate overrides are
    /// deterministic and last-one-wins.
    private static func merge(
        _ base: [AgentDefinition], overriddenBy user: [AgentDefinition]
    ) -> [AgentDefinition] {
        var merged: [AgentDefinition] = []
        var positions: [String: Int] = [:]
        for definition in base {
            if let position = positions[definition.id] {
                log("duplicate base id '\(definition.id)'; later manifest wins")
                merged[position] = definition
            } else {
                positions[definition.id] = merged.count
                merged.append(definition)
            }
        }
        for definition in user {
            if let position = positions[definition.id] {
                merged[position] = definition
            } else {
                positions[definition.id] = merged.count
                merged.append(definition)
            }
        }
        return merged
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: agent catalog \(message)\n".utf8))
    }
}

/// The single on-disk shape for both bundled and user agents. It is deliberately a
/// DTO, separate from `AgentDefinition`'s id-only persistence Codable: manifests are
/// data that select closed termio behaviors, never code termio executes.
struct AgentManifest: Decodable {
    let id: String
    let name: String
    var wire: String?
    var command: String?
    var permissionBypassFlag: String?
    var resume: String?
    var install: String?
    /// Accepted while Cut 4 migrates manifests written against the earlier RFC.
    var installURL: String?
    var icon: IconSpec?
    var status: StatusSpec?
    var hooks: HookSpec?

    struct IconSpec: Decodable {
        var vector: String?
        var asset: String?
        var symbol: String?
        var tint: String?
        var path: String?
    }

    /// Regex lists that classify the agent's rendered screen. `working` → the spinner
    /// pulses; `attention` → the sidebar flags "needs you". Both optional; whatever the
    /// screen matches neither means the agent is at rest (idle / done). Case-insensitive.
    struct StatusSpec: Decodable {
        var working: [String]?
        var attention: [String]?
    }

    struct HookSpec: Decodable {
        var type: String?
        var file: String?
        var dir: String?
        var dialect: String?
        var capturesTranscript: Bool?
        var events: [Event]
        struct Event: Decodable {
            var on: String?
            /// Accepted for manifests written against the earlier user-agent RFC.
            var event: String?
            var state: String
            var matcher: String?
        }
    }

    private enum ManifestError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            }
        }
    }

    private func resolvedHookSpec() throws -> AgentHookSpec? {
        guard let hooks else { return nil }
        let typeName = hooks.type?.lowercased() ?? "json"
        guard let type = AgentHookType(rawValue: typeName) else {
            throw ManifestError.invalid("\(id): unknown hook type '\(typeName)'")
        }
        let dialectName = hooks.dialect?.lowercased()
        let dialect: HookDialect
        switch (type, dialectName) {
        case (.json, nil), (.json, "claude"), (.json, "codex"), (.json, "grok"):
            dialect = .claudeNested
        case (.json, "cursor"):
            dialect = .cursorFlat
        case (.toml, nil), (.toml, "kimi"):
            dialect = .kimiTOML
        case (.plugin, "opencode"):
            dialect = .openCodePlugin
        case (.plugin, "pi"):
            dialect = .piPlugin
        case (.plugin, "amp"):
            dialect = .ampPlugin
        default:
            throw ManifestError.invalid(
                "\(id): hook dialect '\(dialectName ?? "")' does not match type '\(typeName)'")
        }

        if type == .plugin, hooks.dir?.isEmpty != false {
            throw ManifestError.invalid("\(id): plugin hooks require 'dir'")
        }
        if type != .plugin, hooks.file?.isEmpty != false {
            throw ManifestError.invalid("\(id): \(typeName) hooks require 'file'")
        }

        let validStates: Set<String> = ["working", "attention", "done", "idle"]
        let events = try hooks.events.map { event -> AgentHookEvent in
            guard let name = event.on ?? event.event, !name.isEmpty else {
                throw ManifestError.invalid("\(id): hook event is missing 'on'")
            }
            guard validStates.contains(event.state) else {
                throw ManifestError.invalid("\(id): invalid hook state '\(event.state)'")
            }
            return AgentHookEvent(name: name, state: event.state, matcher: event.matcher)
        }
        return AgentHookSpec(
            type: type,
            file: hooks.file,
            directory: hooks.dir,
            dialect: dialect,
            capturesTranscript: hooks.capturesTranscript ?? false,
            events: events)
    }

    func definition(directory: URL, resourceBundle: Bundle) throws -> AgentDefinition {
        guard !id.isEmpty else { throw ManifestError.invalid("agent id is empty") }
        guard !name.isEmpty else { throw ManifestError.invalid("\(id): name is empty") }

        let resolvedIcon: AgentIcon
        if let vector = icon?.vector, !vector.isEmpty {
            switch vector.lowercased() {
            case "claude": resolvedIcon = .vector(.claude)
            case "codex": resolvedIcon = .vector(.codex)
            default: throw ManifestError.invalid("\(id): unknown icon vector '\(vector)'")
            }
        } else if let asset = icon?.asset, !asset.isEmpty {
            guard let url = Self.bundledAsset(named: asset, in: resourceBundle) else {
                throw ManifestError.invalid("\(id): bundled icon asset '\(asset)' is missing")
            }
            resolvedIcon = .image(url)
        } else if let path = icon?.path, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : directory.appendingPathComponent(path)
            resolvedIcon = .image(url.standardizedFileURL)
        } else if let symbol = icon?.symbol, !symbol.isEmpty {
            resolvedIcon = .symbol(symbol)
        } else {
            resolvedIcon = .terminalGlyph
        }

        let defaultTint: Color
        if case .vector(let logo) = resolvedIcon {
            defaultTint = logo.tint
        } else {
            defaultTint = .monochromeInk
        }
        let resolvedTint = icon?.tint.flatMap(Color.init(hex:)) ?? defaultTint
        let hookSpec = try resolvedHookSpec()
        let statusRules = hookSpec == nil
            ? AgentStatusRules.from(working: status?.working, attention: status?.attention, label: id)
            : nil

        let resumeStyle: AgentDefinition.ResumeStyle
        switch resume?.lowercased() ?? "none" {
        case "none": resumeStyle = .none
        case "claude": resumeStyle = .claudeStyle
        case "codex": resumeStyle = .codexStyle
        case "opencode": resumeStyle = .openCodeStyle
        case "pi": resumeStyle = .piStyle
        case let value: throw ManifestError.invalid("\(id): unknown resume strategy '\(value)'")
        }

        return AgentDefinition(
            id: id, displayName: name, command: command,
            permissionBypassFlag: permissionBypassFlag,
            resumeStyle: resumeStyle, icon: resolvedIcon, tint: resolvedTint,
            installURL: (install ?? installURL).flatMap(URL.init(string:)), wireName: wire ?? id,
            statusRules: statusRules, hookSpec: hookSpec)
    }

    private static func bundledAsset(named name: String, in bundle: Bundle) -> URL? {
        let pathExtension = (name as NSString).pathExtension
        if !pathExtension.isEmpty {
            return bundle.url(
                forResource: (name as NSString).deletingPathExtension,
                withExtension: pathExtension)
        }
        for pathExtension in ["png", "svg"] {
            if let url = bundle.url(forResource: name, withExtension: pathExtension) { return url }
        }
        return nil
    }
}
