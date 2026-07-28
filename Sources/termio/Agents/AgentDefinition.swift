import AppKit
import SwiftUI
import TermioShared

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
    /// Default catalog position — the manifest's `order` field, replacing the old
    /// filename number prefix. Lower sorts first (Terminal is 0). A user's runtime
    /// drag-reorder layers on top of this via `AppSettings.orderedAgents`; a manifest
    /// that omits `order` (most user agents) defaults high and lands at the end.
    let order: Int
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
    let resumeSpec: ResumeSpec
    let icon: AgentIcon
    /// Portable form sent to the companion. Bundled assets stay name references;
    /// user image paths are rasterized once at catalog load into inline PNG bytes.
    let iconRef: TermioShared.IconRef
    /// The agent's representative color, used to tint the "working" spinner so a
    /// busy session pulses in its own brand color. Marks without a single brand
    /// color (and the plain terminal) fall back to adaptive ink.
    let tint: Color
    /// Portable six-digit sRGB tint. `nil` means adaptive monochrome ink.
    let tintHex: String?
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
    /// Rules over the agent's live `OSC 0/2` *title* — the in-band state broadcast
    /// some agents ship (Claude prefixes a braille spinner while working, Codex and
    /// Grok flip to "Action Required" when blocked). Unlike `statusRules` this
    /// coexists with hooks rather than replacing them: the title is the agent's own
    /// deliberate signal on a channel that cannot break (no hook file, no external
    /// script, no socket), so it corrects a missed or late hook the instant the
    /// title flips. See `TermioStore.applyTitleActivity` for the arbitration.
    let titleRules: AgentStatusRules?
    /// Whether this agent reports its busy/idle state as ConEmu-style `OSC 9;4`
    /// progress in the PTY byte stream (Grok natively; Claude Code once
    /// `terminalProgressBarEnabled` is set). When true, termio scans the raw stream
    /// for it and drives status the same way the title does — a correction channel
    /// that coexists with hooks, never a competing authority. See `OSCProgressScanner`
    /// and `TermioStore.applyProgressActivity`. Off for agents (and the plain shell)
    /// that don't, so an unrelated tool's progress bar can't move an agent's dot.
    let emitsProgressStatus: Bool
    /// A manifest's declarative hook integration: the destination owned by the agent,
    /// a closed installer/dialect, and its event→state mapping.
    /// When present it is installed by `AgentStatusHooks` and becomes the session's
    /// status authority — so `statusRules` is left `nil` and screen-scrape is skipped,
    /// keeping one source of truth per pane. See `AgentHookSpec`.
    let hookSpec: AgentHookSpec?

    /// All fields after `wireName` are optional so the built-in roster and the
    /// fallback don't each have to spell them out.
    init(
        id: String, order: Int = Self.unorderedRank, displayName: String, command: String?,
        permissionBypassFlag: String?,
        resumeSpec: ResumeSpec, icon: AgentIcon,
        iconRef: TermioShared.IconRef, tint: Color, tintHex: String?, installURL: URL?, wireName: String,
        statusRules: AgentStatusRules? = nil, titleRules: AgentStatusRules? = nil,
        emitsProgressStatus: Bool = false,
        hookSpec: AgentHookSpec? = nil
    ) {
        self.id = id
        self.order = order
        self.displayName = displayName
        self.command = command
        self.permissionBypassFlag = permissionBypassFlag
        self.resumeSpec = resumeSpec
        self.icon = icon
        self.iconRef = iconRef
        self.tint = tint
        self.tintHex = tintHex
        self.installURL = installURL
        self.wireName = wireName
        self.statusRules = statusRules
        self.titleRules = titleRules
        self.emitsProgressStatus = emitsProgressStatus
        self.hookSpec = hookSpec
    }

    /// The default `order` for a manifest that declares none — high, so unspecified
    /// agents (typically user-dropped ones) sort after every ranked built-in.
    static let unorderedRank = 1_000_000

    /// Catalog sort: by default `order`, then `id` for a stable tie-break so the
    /// merged roster is deterministic regardless of file-enumeration order.
    static func byCatalogOrder(_ a: AgentDefinition, _ b: AgentDefinition) -> Bool {
        (a.order, a.id) < (b.order, b.id)
    }

    /// Compatibility shim for the many call sites and settings dictionaries that
    /// still address an agent by its old string `rawValue` — which is just `id`.
    var rawValue: String { id }

    /// The spinner/badge tint. Named `tintColor` for the call sites that predate
    /// the value-type migration (notably `WorkingIndicator`).
    var tintColor: Color { tint }

    /// Whether this agent lets termio pin its conversation id up front so a relaunch
    /// resumes the exact prior session (Claude Code, Grok, Pi).
    var usesPinnedResumeID: Bool { resumeSpec.pinsID }

    /// Whether this agent's id can't be set up front but *can* be discovered from its
    /// own session store afterward and resumed by id (Codex, OpenCode).
    var usesDiscoveredResumeID: Bool { resumeSpec.discoversID }

    /// How a relaunch continues (or doesn't) this agent's prior conversation, parsed
    /// straight from the manifest's `resume` object. Everything here is data — argument
    /// templates with an `{id}` placeholder plus descriptions of the agent's on-disk
    /// session store — so a new agent needs no Swift at all. Strategies describe
    /// *mechanisms* (file formats, field paths), never agent identities. See
    /// docs/design/agent-resume-identity.md.
    struct ResumeSpec: Hashable, Sendable {
        /// Launch template for a fresh, termio-pinned id (e.g. `--session-id {id}`). Its
        /// presence means the id is pinned up front; its absence means the id is
        /// discovered after launch, or the agent doesn't resume.
        var create: String?
        /// Template to continue a known conversation id (e.g. `--resume {id}`).
        var resume: String?
        /// The agent's on-disk session store. Lets termio tell an already-saved
        /// conversation (→ `resume`) from a brand-new one (→ `create`), since a create
        /// flag errors on a duplicate id; also backs the Info-pane transcript fallback
        /// and `/clear` id-rotation for file-per-conversation stores.
        var store: Store?
        /// How to read the id out of the agent's own session records after launch, for
        /// agents that mint the id themselves. Set iff `create` is nil.
        var discover: Discover?
        /// Names the built-in mechanism that pre-creates the session file so a pinned id
        /// resolves silently on first launch (`session-file`).
        var seed: String?

        /// A declarative description of where an agent keeps its conversations on disk.
        struct Store: Hashable, Sendable {
            /// Tilde-expandable root, e.g. `~/.grok/sessions`.
            var root: String
            /// Whether a conversation is a directory (Grok) or a file (Claude, Pi).
            var isDirectory: Bool
            /// The entry name with `{id}` substituted — `{id}` (dir), `{id}.jsonl`, or
            /// `*_{id}.jsonl` (a `*` globs). Sessions bucket per working directory under
            /// `root`; termio searches across the buckets rather than reconstruct each
            /// agent's private cwd encoding.
            var name: String
            /// For a directory-based store: the filename of the transcript inside the
            /// session directory, e.g. `"chat_history.jsonl"`. When set,
            /// `resolveTranscriptPath` looks for this exact file and returns `nil` if
            /// it is absent (no sole-jsonl guess — multi-file session dirs would pin
            /// the wrong sibling). `nil` (the default) falls back to scanning for a
            /// single `.jsonl` file in the directory. Only meaningful when
            /// `isDirectory` is true.
            var transcriptName: String? = nil
        }

        /// A declarative description of how to recover an agent-minted session id from
        /// the agent's own records: where they live, how a record is read, and which
        /// fields carry the id and the working directory. All mechanism, no agent names —
        /// `AgentSessionStore` interprets this generically.
        struct Discover: Hashable, Sendable {
            /// Tilde-expandable root the records live under, e.g. `~/.codex/sessions`.
            var root: String
            /// How a record file is read.
            var format: Format
            /// Dot-separated key path to the session id, e.g. `payload.id`.
            var id: String
            /// Dot-separated key path to the recorded working directory, e.g. `payload.cwd`.
            var cwd: String

            enum Format: String, Hashable, Sendable {
                /// A `.jsonl` log whose first line is a JSON header — the log itself is
                /// the conversation transcript.
                case jsonl
                /// A standalone `.json` metadata record (not a transcript).
                case json

                var fileExtension: String { rawValue }
            }
        }

        static let none = ResumeSpec()

        var pinsID: Bool { create != nil }
        var discoversID: Bool { discover != nil }

        /// The argument fragment to append to the base command so this session continues
        /// its prior conversation on relaunch, or `nil` to launch fresh.
        func arguments(_ context: ResumeContext) -> String? {
            func fill(_ template: String?) -> String? {
                template?.replacingOccurrences(of: "{id}", with: context.resumeID)
            }
            if pinsID {
                // The create flag errors if the id already exists and the resume flag
                // errors if it doesn't, so create until the agent has saved a
                // conversation and resume once it has. (When both templates are equal —
                // Pi — the branch is a no-op either way.)
                return context.pinnedConversationExists ? fill(resume) : fill(create)
            }
            if discoversID {
                // Resume the exact session once its id has been discovered and saved
                // (`Session.resumeID`); until then launch fresh — no approximate
                // "continue whatever is most recent" fallback.
                return context.resumeID.isEmpty ? nil : fill(resume)
            }
            return nil
        }

        /// The conversation id encoded in a transcript *path*, for a file-per-conversation
        /// store whose filename carries the id. termio uses this to advance a session's
        /// pinned `resumeID` after the agent rotates its conversation mid-session (Claude
        /// Code's `/clear` mints a new id and transcript and orphans the old file, which
        /// the once-pinned id would otherwise keep resuming). Nil for directory stores,
        /// discovered-id agents (the id lives inside the file), or no declared store.
        func conversationID(fromTranscriptPath path: String) -> String? {
            guard let store, !store.isDirectory else { return nil }
            return SessionStore.id(fromEntryName: (path as NSString).lastPathComponent,
                                   pattern: store.name)
        }
    }

    /// Inputs the resume decision needs that only `TermioStore` can supply.
    struct ResumeContext {
        /// The stable id termio pinned for this session (meaningful only when
        /// `usesPinnedResumeID`).
        var resumeID: String
        /// Whether the agent already has a saved conversation under `resumeID`. Resuming
        /// one that doesn't exist errors, so a pinned-but-never-used session is
        /// (re)created with the `create` flag instead.
        var pinnedConversationExists: Bool
    }

    /// The argument fragment to append to the resolved base command so this session
    /// continues its prior conversation on relaunch, or `nil` to launch fresh.
    func resumeArguments(_ context: ResumeContext) -> String? {
        resumeSpec.arguments(context)
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
            resumeSpec: .none,
            icon: .symbol("questionmark.app"),
            iconRef: TermioShared.IconRef(symbol: "questionmark.app"),
            tint: .monochromeInk, tintHex: nil,
            installURL: nil, wireName: id)
    }
}

// MARK: - Compatibility statics (leading-dot & enum-shaped call sites)

extension AgentDefinition {
    /// Every known agent: the built-ins plus any the user has installed. Replaces the
    /// old `AgentPreset.allCases`; the pickers, the roster, and name resolution all
    /// read from here, so user agents appear everywhere built-ins do.
    static var allCases: [AgentDefinition] { AgentCatalog.shared.all }

    /// The plain login shell rather than a coding-agent CLI. It's configured on the
    /// Terminal settings tab and is always available in the New-session menu, so it's
    /// deliberately excluded from the manageable agent roster — the Agents settings
    /// tab and the chat pickers list `codingAgents` only, never the shell.
    var isShell: Bool { id == "terminal" }

    /// Every agent the user actually manages: the roster minus the plain shell.
    static var codingAgents: [AgentDefinition] { allCases.filter { !$0.isShell } }

    // Compatibility conveniences for enum-shaped call sites. These are catalog
    // lookups, not definitions: every fact still comes from the corresponding JSON
    // manifest, and a newly added agent needs no Swift member.
    static var terminal: AgentDefinition { AgentCatalog.shared.definition(for: "terminal") }
    static var claudeCode: AgentDefinition { AgentCatalog.shared.definition(for: "claudeCode") }
    static var codex: AgentDefinition { AgentCatalog.shared.definition(for: "codex") }
    static var opencode: AgentDefinition { AgentCatalog.shared.definition(for: "opencode") }

    /// Resolves a free-text agent name from the CLI (`termio sessions send --agent claude`)
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
    /// Where the hook host exposes the live conversation id, so reports can carry
    /// it and termio can follow an in-process `/new` rotation. Dialect-interpreted:
    /// a stdin JSON field name for shell hooks (`session_id`, `sessionId`), a dot
    /// key path in the event object for the OpenCode plugin, or the named
    /// `context` mechanism for the Pi plugin. `nil` for identity-blind hooks.
    let conversation: String?
    /// The stdin JSON field naming the tool a hook event fires for (Claude
    /// `tool_name`), so reports can distinguish real work from a prose-only turn.
    /// `nil` when the agent's hooks expose no tool identity.
    let tool: String?
    let events: [AgentHookEvent]
}

// MARK: - Catalog (bundled + user manifests)

/// Owns the merged set of agent definitions. Both sources decode through
/// `AgentManifest`; only their directory layout differs until Cut 4 migrates the
/// legacy user folders. Each instance is immutable; `reload()` swaps in a fresh
/// one after Settings writes or deletes a user manifest.
final class AgentCatalog {
    private static let sharedLock = NSLock()
    private static var _shared = AgentCatalog()

    static var shared: AgentCatalog {
        sharedLock.withLock { _shared }
    }

    /// Re-reads bundled + user manifests. Readers pick up the fresh instance on
    /// their next `shared` access; definitions already handed out keep their old
    /// values (equality is by id, so live sessions are unaffected).
    static func reload() {
        let fresh = AgentCatalog()
        sharedLock.withLock { _shared = fresh }
    }

    let all: [AgentDefinition]
    /// Retained so a user override that removes or redirects a shipped hook can
    /// clean the old managed entry before installing its replacement.
    let bundled: [AgentDefinition]
    private let commandIndex: [String: AgentDefinition]

    private init() {
        // The plain shell is a session kind rather than a manageable agent, so it
        // loads from its own manifest at the bundle root — kept out of the coding-agent
        // directory. It still joins the roster (every terminal session resolves to it)
        // and, at `order: 0`, sorts first.
        let bundled = (Self.loadBundledShell().map { [$0] } ?? []) + Self.loadBundledAgents()
        Self.migrateLegacyUserAgents()
        // A failed/colliding migration remains readable in its old location; flat
        // config wins when both sources intentionally carry the same id.
        let legacy = Self.loadLegacyUserAgents()
        let user = Self.merge(legacy, overriddenBy: Self.loadUserAgents())
        // Final roster order is the manifest `order` field, not file-enumeration or
        // merge-insertion order — so a user override that changes `order` moves the
        // agent, and the roster is deterministic. A user's runtime drag-reorder then
        // layers on top of this default via `AppSettings.orderedAgents`.
        let all = Self.merge(bundled, overriddenBy: user).sorted(by: AgentDefinition.byCatalogOrder)
        self.bundled = bundled.sorted(by: AgentDefinition.byCatalogOrder)
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

    /// Whether this id came from a user manifest rather than the bundle — i.e. the
    /// Settings editor may rewrite or delete its file. A user *override* of a
    /// bundled id is deliberately excluded: deleting it would resurrect the
    /// bundled agent, which "Delete" does not promise.
    func isUserDefined(_ id: String) -> Bool {
        find(id: id) != nil && !bundled.contains { $0.id == id }
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
    /// Internal so the Settings custom-agent editor writes to the same place the
    /// catalog reads from.
    static var userAgentsDirectory: URL {
        AppChannel.homeConfigDirectory
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
    }

    /// The plain login shell, loaded from its own manifest at the bundle root rather
    /// than the coding-agent directory. `nil` only if the file is missing or unparseable
    /// (the roster then degrades to the id-only fallback for terminal sessions).
    private static func loadBundledShell() -> AgentDefinition? {
        guard let resourceURL = Bundle.termioResources.resourceURL else {
            log("bundled resource directory is unavailable")
            return nil
        }
        let url = resourceURL.appendingPathComponent("terminal.json")
        return decode(manifest: url, resolvingRelativeTo: resourceURL)
    }

    /// The coding agents only — the `agents/` directory deliberately excludes the plain
    /// shell (see `loadBundledShell`), so this enumerates the manageable roster.
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
    /// Default catalog position. Bundled manifests declare it (Terminal 0, Claude 10,
    /// …); a user manifest may set its own slot, and one that omits it defaults high
    /// so new user agents land at the end. Replaces the old filename number prefix.
    var order: Int?
    var wire: String?
    var command: String?
    var permissionBypassFlag: String?
    var resume: ResumeConfig?
    var install: String?
    /// Accepted while Cut 4 migrates manifests written against the earlier RFC.
    var installURL: String?
    var icon: IconSpec?
    var status: StatusSpec?
    /// Same regex shape as `status`, matched against the agent's live OSC 0/2
    /// title instead of the rendered screen. Coexists with `hooks` (the title is a
    /// correction channel, not a competing authority), so it is not gated the way
    /// `status` is.
    var titleStatus: StatusSpec?
    /// Opt-in to reading this agent's ConEmu-style `OSC 9;4` progress out of the PTY
    /// byte stream as a busy/idle signal (`OSCProgressScanner`). Off by default so a
    /// plain shell's `wget`/`npm` progress bar can never move an agent's status dot.
    var progressStatus: Bool?
    var hooks: HookSpec?

    struct IconSpec: Decodable {
        var vector: String?
        var asset: String?
        var symbol: String?
        var tint: String?
        var path: String?
    }

    /// The manifest's `resume`. The flat object is the interface; a bare string is
    /// accepted only as backward-compatibility for manifests written against the older
    /// preset names (`"claude"`, `"codex"`, `"pi"`, `"opencode"`, `"none"`).
    enum ResumeConfig: Decodable {
        case legacyPreset(String)
        case spec(Fields)

        struct Fields: Decodable {
            var create: String?
            var resume: String?
            /// Tilde-expandable root of the agent's on-disk session store.
            var storeRoot: String?
            /// `dir:<pattern>` or `file:<pattern>`, where `<pattern>` contains `{id}` and
            /// may contain a `*` glob (e.g. `dir:{id}`, `file:{id}.jsonl`, `file:*_{id}.jsonl`).
            var storeMatch: String?
            /// For a directory-based store: the name of the transcript file inside the
            /// session directory, e.g. `"chat_history.jsonl"`. When present, path
            /// resolution is exact-name only (no sole-jsonl fallback).
            var transcriptName: String?
            var discover: DiscoverFields?
            var seed: String?

            /// Mechanism description for recovering an agent-minted id — a record
            /// location plus field paths, never an agent name.
            struct DiscoverFields: Decodable {
                var root: String
                /// `jsonl` (first line of a `.jsonl` log is the record; the log is the
                /// transcript) or `json` (a standalone `.json` metadata record).
                var format: String
                var id: String
                var cwd: String
            }
        }

        init(from decoder: Decoder) throws {
            if let preset = try? decoder.singleValueContainer().decode(String.self) {
                self = .legacyPreset(preset)
            } else {
                self = .spec(try Fields(from: decoder))
            }
        }
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
        /// Dialect-interpreted locator of the live conversation id (see
        /// `AgentHookSpec.conversation`).
        var conversation: String?
        /// Stdin JSON field naming the running tool (see `AgentHookSpec.tool`).
        var tool: String?
        var events: [Event]
        struct Event: Decodable {
            var on: String?
            /// Accepted for manifests written against the earlier user-agent RFC.
            var event: String?
            var state: String
            var matcher: String?
        }
    }

    /// Turns the manifest's `resume` into the runtime `ResumeSpec`, validating the store
    /// descriptor and the named strategies. The legacy preset strings map onto the same
    /// objects the bundled manifests now declare, so old user manifests keep working.
    private func resolvedResumeSpec() throws -> AgentDefinition.ResumeSpec {
        guard let resume else { return .none }
        switch resume {
        case .legacyPreset(let preset):
            switch preset.lowercased() {
            case "none": return .none
            case "claude":
                return .init(create: "--session-id {id}", resume: "--resume {id}",
                             store: .init(root: "~/.claude/projects", isDirectory: false,
                                          name: "{id}.jsonl"))
            case "pi":
                return .init(create: "--session-id {id}", resume: "--session-id {id}",
                             store: .init(root: "~/.pi/agent/sessions", isDirectory: false,
                                          name: "*_{id}.jsonl"), seed: "session-file")
            case "codex":
                return .init(resume: "resume {id}",
                             discover: .init(root: "~/.codex/sessions", format: .jsonl,
                                             id: "payload.id", cwd: "payload.cwd"))
            case "opencode":
                return .init(resume: "--session {id}",
                             discover: .init(root: "~/.local/share/opencode/storage/session",
                                             format: .json, id: "id", cwd: "directory"))
            case let other:
                throw ManifestError.invalid("\(id): unknown resume preset '\(other)'")
            }
        case .spec(let fields):
            var store: AgentDefinition.ResumeSpec.Store?
            switch (fields.storeRoot, fields.storeMatch) {
            case (nil, nil):
                store = nil
            case let (root?, match?):
                let parts = match.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[1].isEmpty else {
                    throw ManifestError.invalid(
                        "\(id): storeMatch must be 'dir:<pattern>' or 'file:<pattern>'")
                }
                let isDirectory: Bool
                switch parts[0] {
                case "dir": isDirectory = true
                case "file": isDirectory = false
                default:
                    throw ManifestError.invalid(
                        "\(id): storeMatch must start with 'dir:' or 'file:'")
                }
                guard parts[1].contains("{id}") else {
                    throw ManifestError.invalid("\(id): storeMatch pattern must contain '{id}'")
                }
                store = .init(root: root, isDirectory: isDirectory, name: String(parts[1]),
                              transcriptName: fields.transcriptName)
            default:
                throw ManifestError.invalid("\(id): storeRoot and storeMatch must be set together")
            }
            var discover: AgentDefinition.ResumeSpec.Discover?
            if let fields = fields.discover {
                guard let format = AgentDefinition.ResumeSpec.Discover.Format(
                    rawValue: fields.format.lowercased()) else {
                    throw ManifestError.invalid(
                        "\(id): discover format must be 'jsonl' or 'json', not '\(fields.format)'")
                }
                guard !fields.root.isEmpty, !fields.id.isEmpty, !fields.cwd.isEmpty else {
                    throw ManifestError.invalid("\(id): discover requires root, format, id, cwd")
                }
                discover = .init(root: fields.root, format: format, id: fields.id, cwd: fields.cwd)
            }
            if let seed = fields.seed, seed != "session-file" {
                throw ManifestError.invalid("\(id): unknown resume seed mechanism '\(seed)'")
            }
            if fields.create != nil, discover != nil {
                throw ManifestError.invalid(
                    "\(id): resume 'create' (pinned id) and 'discover' (found id) are mutually exclusive")
            }
            return .init(
                create: fields.create, resume: fields.resume,
                store: store, discover: discover, seed: fields.seed)
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

        // Locators are embedded in generated hook commands and plugin source, so
        // each must be a bare token: a JSON field name for shell hooks, a dot path
        // of JS identifiers for the OpenCode plugin, or the one named mechanism
        // (`context`) for the Pi plugin. Anything else is a manifest error, never
        // rendered.
        func isIdentifier(_ value: Substring) -> Bool {
            guard let first = value.first, first.isLetter || first == "_" else { return false }
            return value.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }

        var conversation: String?
        if let raw = hooks.conversation?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            switch dialect {
            case .claudeNested, .cursorFlat:
                guard isIdentifier(raw[...]) else {
                    throw ManifestError.invalid(
                        "\(id): hook conversation must name a stdin JSON field, not '\(raw)'")
                }
            case .openCodePlugin:
                let components = raw.split(separator: ".", omittingEmptySubsequences: false)
                guard !components.isEmpty, components.allSatisfy(isIdentifier) else {
                    throw ManifestError.invalid(
                        "\(id): hook conversation must be a dot key path, not '\(raw)'")
                }
            case .piPlugin:
                guard raw == "context" else {
                    throw ManifestError.invalid(
                        "\(id): hook conversation for this dialect must be 'context', not '\(raw)'")
                }
            case .kimiTOML, .ampPlugin:
                throw ManifestError.invalid(
                    "\(id): hook conversation is not supported for this dialect")
            }
            conversation = raw
        }

        // The tool locator names the stdin JSON field carrying the running tool's
        // name (Claude `tool_name`), so shell-hook reports can identify real work.
        // Only meaningful for the stdin-fed shell-hook dialects.
        var tool: String?
        if let raw = hooks.tool?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            switch dialect {
            case .claudeNested, .cursorFlat:
                guard isIdentifier(raw[...]) else {
                    throw ManifestError.invalid(
                        "\(id): hook tool must name a stdin JSON field, not '\(raw)'")
                }
            default:
                throw ManifestError.invalid(
                    "\(id): hook tool is not supported for this dialect")
            }
            tool = raw
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
            conversation: conversation,
            tool: tool,
            events: events)
    }

    func definition(directory: URL, resourceBundle: Bundle) throws -> AgentDefinition {
        guard !id.isEmpty else { throw ManifestError.invalid("agent id is empty") }
        guard !name.isEmpty else { throw ManifestError.invalid("\(id): name is empty") }

        let resolvedIcon: AgentIcon
        let resolvedIconRef: TermioShared.IconRef
        if let vector = icon?.vector, !vector.isEmpty {
            switch vector.lowercased() {
            case "claude":
                resolvedIcon = .vector(.claude)
                resolvedIconRef = TermioShared.IconRef(vector: "claude")
            case "codex":
                resolvedIcon = .vector(.codex)
                resolvedIconRef = TermioShared.IconRef(vector: "codex")
            case "grok":
                resolvedIcon = .vector(.grok)
                resolvedIconRef = TermioShared.IconRef(vector: "grok")
            default: throw ManifestError.invalid("\(id): unknown icon vector '\(vector)'")
            }
        } else if let asset = icon?.asset, !asset.isEmpty {
            guard let url = Self.bundledAsset(named: asset, in: resourceBundle) else {
                throw ManifestError.invalid("\(id): bundled icon asset '\(asset)' is missing")
            }
            resolvedIcon = .image(url)
            resolvedIconRef = TermioShared.IconRef(asset: asset)
        } else if let path = icon?.path, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : directory.appendingPathComponent(path)
            resolvedIcon = .image(url.standardizedFileURL)
            resolvedIconRef = Self.inlineImageReference(at: url.standardizedFileURL)
        } else if let symbol = icon?.symbol, !symbol.isEmpty {
            resolvedIcon = .symbol(symbol)
            resolvedIconRef = TermioShared.IconRef(symbol: symbol)
        } else {
            resolvedIcon = .terminalGlyph
            resolvedIconRef = TermioShared.IconRef()
        }

        let defaultTint: Color
        if case .vector(let logo) = resolvedIcon {
            defaultTint = logo.tint
        } else {
            defaultTint = .monochromeInk
        }
        let explicitTint = icon?.tint.flatMap { raw in Color(hex: raw).map { (raw, $0) } }
        let resolvedTint = explicitTint?.1 ?? defaultTint
        let resolvedTintHex: String?
        if let raw = explicitTint?.0 {
            let value = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
            resolvedTintHex = "#" + value.uppercased()
        } else if case .vector(.claude) = resolvedIcon {
            resolvedTintHex = "#D97757"
        } else {
            resolvedTintHex = nil
        }
        let hookSpec = try resolvedHookSpec()
        let statusRules = hookSpec == nil
            ? AgentStatusRules.from(working: status?.working, attention: status?.attention, label: id)
            : nil
        let titleRules = AgentStatusRules.from(
            working: titleStatus?.working, attention: titleStatus?.attention,
            label: "\(id).title")

        let resumeSpec = try resolvedResumeSpec()

        return AgentDefinition(
            id: id, order: order ?? AgentDefinition.unorderedRank,
            displayName: name, command: command,
            permissionBypassFlag: permissionBypassFlag,
            resumeSpec: resumeSpec, icon: resolvedIcon, iconRef: resolvedIconRef,
            tint: resolvedTint, tintHex: resolvedTintHex,
            installURL: (install ?? installURL).flatMap(URL.init(string:)), wireName: wire ?? id,
            statusRules: statusRules, titleRules: titleRules,
            emitsProgressStatus: progressStatus ?? false, hookSpec: hookSpec)
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

    /// UIKit cannot decode arbitrary SVG paths from the Mac, so user image files
    /// cross the wire as real PNG bytes regardless of their source format. Failure
    /// degrades to the same visible question-mark fallback as a missing local icon.
    private static func inlineImageReference(at url: URL) -> TermioShared.IconRef {
        guard let image = NSImage(contentsOf: url), let png = image.pngData()
        else { return TermioShared.IconRef(symbol: "questionmark.app") }
        return TermioShared.IconRef(png: png.base64EncodedString())
    }
}
