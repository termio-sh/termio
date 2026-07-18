import SwiftUI

/// What a new session launches: a plain login shell, or a coding agent CLI.
/// Formerly a closed `enum AgentPreset`; now a value type so the built-in agents
/// and any the user drops into `~/.termio/agents/` flow through the same shape.
/// Built-ins are the static array below (keeping their real vector brand marks);
/// user agents are loaded and merged by `AgentCatalog`. Equality and persistence
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
    /// A user agent's declarative JSON-hook-file integration (Claude/Codex/Cursor
    /// shape): the path to the agent's own hook file plus its event→state mapping.
    /// When present it is installed by `AgentStatusHooks` and becomes the session's
    /// status authority — so `statusRules` is left `nil` and screen-scrape is skipped,
    /// keeping one source of truth per pane. `nil` for built-ins (installed in code)
    /// and for user agents that declared no `hooks` block. See `AgentHookSpec`.
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

// MARK: - Built-ins

extension AgentDefinition {
    /// Resolves a shipped image by resource name without encoding the agent in an
    /// enum. A packaging mistake degrades to the same visible fallback as a bad user
    /// icon and is logged; it never traps the catalog during launch.
    private static func bundledIcon(
        named resourceName: String, fileExtension: String
    ) -> AgentIcon {
        guard let url = Bundle.termioResources.url(
            forResource: resourceName, withExtension: fileExtension
        ) else {
            AgentCatalog.log("missing bundled icon \(resourceName).\(fileExtension)")
            return .symbol("questionmark.app")
        }
        return .image(url)
    }

    static let terminal = AgentDefinition(
        id: "terminal", displayName: "Terminal", command: nil,
        permissionBypassFlag: nil, resumeStyle: .none,
        icon: .terminalGlyph, tint: .monochromeInk, installURL: nil, wireName: "terminal")

    static let claudeCode = AgentDefinition(
        id: "claudeCode", displayName: "Claude Code", command: "claude",
        permissionBypassFlag: "--dangerously-skip-permissions",
        resumeStyle: .claudeStyle, icon: .vector(.claude), tint: BrandLogo.claude.tint,
        installURL: URL(string: "https://claude.com/claude-code"), wireName: "claude")

    static let codex = AgentDefinition(
        id: "codex", displayName: "Codex", command: "codex",
        permissionBypassFlag: "--dangerously-bypass-approvals-and-sandbox",
        resumeStyle: .codexStyle, icon: .vector(.codex), tint: BrandLogo.codex.tint,
        installURL: URL(string: "https://developers.openai.com/codex/cli"), wireName: "codex")

    static let opencode = AgentDefinition(
        id: "opencode", displayName: "OpenCode", command: "opencode",
        permissionBypassFlag: nil, resumeStyle: .openCodeStyle,
        icon: bundledIcon(named: "opencode-favicon", fileExtension: "png"), tint: .monochromeInk,
        installURL: URL(string: "https://opencode.ai"), wireName: "opencode")

    static let pi = AgentDefinition(
        id: "pi", displayName: "Pi", command: "pi",
        permissionBypassFlag: nil, resumeStyle: .piStyle,
        icon: bundledIcon(named: "pi-favicon", fileExtension: "svg"), tint: .monochromeInk,
        installURL: URL(string: "https://pi.dev"), wireName: "pi")

    static let amp = AgentDefinition(
        id: "amp", displayName: "Amp", command: "amp",
        permissionBypassFlag: nil, resumeStyle: .none,
        icon: bundledIcon(named: "amp-favicon", fileExtension: "png"), tint: .monochromeInk,
        installURL: URL(string: "https://ampcode.com/manual"), wireName: "amp")

    static let cursor = AgentDefinition(
        // Cursor's headless CLI binary is `cursor-agent`, distinct from the `cursor`
        // GUI launcher, so name it explicitly.
        id: "cursor", displayName: "Cursor", command: "cursor-agent",
        permissionBypassFlag: nil, resumeStyle: .none,
        icon: bundledIcon(named: "cursor-favicon", fileExtension: "svg"), tint: .monochromeInk,
        installURL: URL(string: "https://cursor.com/docs/cli"), wireName: "cursor")

    static let kimi = AgentDefinition(
        id: "kimi", displayName: "Kimi", command: "kimi",
        permissionBypassFlag: nil, resumeStyle: .none,
        icon: bundledIcon(named: "kimi-favicon", fileExtension: "png"), tint: .monochromeInk,
        installURL: URL(string: "https://moonshotai.github.io/kimi-code"), wireName: "kimi")

    static let antigravity = AgentDefinition(
        id: "antigravity", displayName: "Antigravity", command: "agy",
        permissionBypassFlag: nil, resumeStyle: .none,
        icon: bundledIcon(named: "antigravity-favicon", fileExtension: "png"), tint: .monochromeInk,
        installURL: URL(string: "https://antigravity.google/product/antigravity-cli"), wireName: "antigravity")

    static let hermes = AgentDefinition(
        id: "hermes", displayName: "Hermes", command: "hermes",
        permissionBypassFlag: nil, resumeStyle: .none,
        icon: bundledIcon(named: "hermes-favicon", fileExtension: "png"), tint: .monochromeInk,
        installURL: URL(string: "https://hermes-agent.nousresearch.com/#downloads"), wireName: "hermes")

    static let grok = AgentDefinition(
        // xAI's Grok Build. The binary builds as `xai-grok-pager` but installs as `grok`.
        // Resume is Claude-shaped: `--session-id <uuid>` creates a session with our id and
        // `--resume <id>` reloads it, so `.claudeStyle` fits verbatim. `--yolo` is the
        // documented auto-approve flag.
        id: "grok", displayName: "Grok", command: "grok",
        permissionBypassFlag: "--yolo",
        resumeStyle: .claudeStyle,
        icon: bundledIcon(named: "grok-favicon", fileExtension: "png"), tint: .monochromeInk,
        installURL: URL(string: "https://x.ai/cli"), wireName: "grok")

    /// The agents termio ships, in the order they appear in the picker. User agents
    /// are appended after these by `AgentCatalog`.
    static let builtins: [AgentDefinition] = [
        terminal, claudeCode, codex, opencode, pi, amp, cursor, kimi, antigravity, hermes, grok,
    ]

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

// MARK: - JSON-hook-file integration (config-driven, no plugin code)

/// A user agent's declarative hook integration for the Claude/Codex/Cursor family:
/// agents whose status hooks are just a JSON file mapping lifecycle events to shell
/// commands. termio writes the report commands itself (`AgentStatusHooks.reportCommand`),
/// so the user supplies only *data* — the file path and which event means what — never
/// any code. Installed/removed by `AgentStatusHooks` alongside the built-ins. Agents
/// with a different (plugin-API) hook mechanism can't be expressed here; they either
/// post to the socket from their own plugin or fall back to screen-scrape `status`.
struct AgentHookSpec {
    /// The agent's own hook file, e.g. `~/.myagent/settings.json`. `~` is expanded.
    let file: String
    /// The file's structural shape — `.claudeNested` (Claude/Codex) or `.cursorFlat`
    /// (Cursor's flat, stdout-as-reply dialect). See `HookDialect`.
    let dialect: HookDialect
    /// `(event name, normalized state, optional matcher)`, in the agent's own event
    /// vocabulary. State is `working` / `attention` / `done` / `idle`.
    let events: [(name: String, state: String, matcher: String?)]
}

// MARK: - Catalog (built-ins + user agents from disk)

/// Owns the merged set of agent definitions for the running app: the built-ins plus
/// any the user dropped into `~/.termio/agents/<id>/agent.json`. Loaded once, lazily,
/// on first access — which happens the moment the first session's agent is decoded,
/// so user agents are always resolvable by the time `state.json` loads. Read-only
/// after construction; agents are picked up on the next launch, not hot-reloaded.
final class AgentCatalog {
    static let shared = AgentCatalog()

    let all: [AgentDefinition]
    /// Leaf command name → definition, e.g. `claude`, `codex`, `cursor-agent`.
    /// Built once from the catalog so user agents participate too; the plain
    /// terminal (no `command`) is absent, so a bare shell is never "detected".
    /// A stored `let` (not `lazy`): `agent(forForegroundArguments:)` reads it from a
    /// background poll, so it must be race-free the moment the singleton exists.
    private let commandIndex: [String: AgentDefinition]

    private init() {
        let all = AgentDefinition.builtins + AgentCatalog.loadUserAgents()
        self.all = all
        var index: [String: AgentDefinition] = [:]
        for definition in all {
            guard let command = definition.command else { continue }
            let firstToken = command.split(separator: " ").first.map(String.init) ?? command
            index[AgentCatalog.leafName(firstToken)] = definition
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

    /// Where users drop agents: one folder per agent under `~/.termio/agents/`, each
    /// holding an `agent.json`. Mirrors the home-dir `~/.termio/worktrees` layout so
    /// the whole termio-owned tree is discoverable in one place.
    private static var agentsDirectory: URL {
        AppChannel.homeConfigDirectory.appendingPathComponent("agents", isDirectory: true)
    }

    /// Scans the agents directory and returns the user definitions, skipping any that
    /// collide with a built-in id (built-ins win, to protect the shipped brands) and
    /// logging — rather than failing — an unparseable `agent.json` so one bad folder
    /// can't take down the rest.
    private static func loadUserAgents() -> [AgentDefinition] {
        let directory = agentsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        let builtinIDs = Set(AgentDefinition.builtins.map(\.id))
        var loaded: [AgentDefinition] = []
        var seen = builtinIDs
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = entry.appendingPathComponent("agent.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            do {
                let manifest = try JSONDecoder().decode(UserAgentManifest.self, from: manifestURL, data: data)
                guard !seen.contains(manifest.id) else {
                    log("skipping \(manifestURL.path): id '\(manifest.id)' already exists")
                    continue
                }
                seen.insert(manifest.id)
                loaded.append(manifest.definition(directory: entry))
            } catch {
                log("ignoring unparseable \(manifestURL.path): \(error)")
            }
        }
        return loaded
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: agent catalog \(message)\n".utf8))
    }
}

/// The on-disk `agent.json` shape a user writes to add an agent. A separate, fully
/// declarative DTO — distinct from `AgentDefinition`'s id-only session Codable — so
/// the file is plain data (VSCode-theme-shaped: data, not code). A user agent has no
/// hook installer; live status comes from the optional `status` screen-scrape rules
/// (or degrades to the zero-config bell/OSC "done" signal when none are given).
struct UserAgentManifest: Decodable {
    let id: String
    let name: String
    var command: String?
    var permissionBypassFlag: String?
    var installURL: String?
    var icon: IconSpec?
    var status: StatusSpec?
    var hooks: HookSpec?

    /// Either an SF Symbol (with an optional tint hex) or a path to an image file on
    /// disk (PNG/SVG, absolute or relative to the agent's folder).
    struct IconSpec: Decodable {
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

    /// A JSON-hook-file integration (Claude/Codex/Cursor shape) — the precise,
    /// no-code alternative to `status` screen-scrape for agents that ship such a file.
    /// When present it wins: it becomes the status authority and `status` is ignored.
    struct HookSpec: Decodable {
        var file: String
        var dialect: String?
        var events: [Event]
        struct Event: Decodable {
            var event: String
            var state: String
            var matcher: String?
        }
    }

    private func resolvedHookSpec() -> AgentHookSpec? {
        guard let hooks else { return nil }
        let dialect: HookDialect = hooks.dialect?.lowercased() == "cursor" ? .cursorFlat : .claudeNested
        let events = hooks.events.map { (name: $0.event, state: $0.state, matcher: $0.matcher) }
        return AgentHookSpec(file: hooks.file, dialect: dialect, events: events)
    }

    func definition(directory: URL) -> AgentDefinition {
        let resolvedTint = icon?.tint.flatMap(Color.init(hex:)) ?? .monochromeInk
        let resolvedIcon: AgentIcon
        if let path = icon?.path, !path.isEmpty {
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                : directory.appendingPathComponent(path)
            resolvedIcon = .image(url)
        } else {
            resolvedIcon = .symbol(icon?.symbol ?? "terminal")
        }
        // Hooks are the status authority when declared: skip screen-scrape so a pane
        // never has two competing sources of truth (herdr's "one authority per pane").
        let hookSpec = resolvedHookSpec()
        let statusRules = hookSpec == nil
            ? AgentStatusRules.from(working: status?.working, attention: status?.attention, label: id)
            : nil
        return AgentDefinition(
            id: id, displayName: name, command: command,
            permissionBypassFlag: permissionBypassFlag,
            resumeStyle: .none, icon: resolvedIcon, tint: resolvedTint,
            installURL: installURL.flatMap(URL.init(string:)), wireName: id,
            statusRules: statusRules, hookSpec: hookSpec)
    }
}

private extension JSONDecoder {
    /// Decodes from data already read, threading the file's own bytes through — a
    /// tiny convenience so the caller reads the file once and reports errors with the
    /// path already in hand.
    func decode<T: Decodable>(_ type: T.Type, from _: URL, data: Data) throws -> T {
        try decode(type, from: data)
    }
}
