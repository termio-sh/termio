import Foundation
import TermioShared

/// A folder the user has opened as a project, remembered for the welcome page's
/// "Recent" column so it survives the fully-empty state (every project closed).
/// Persisted in `AppSettings.recentProjects`; keyed by `path` so the same folder
/// never appears twice.
struct RecentProject: Identifiable, Hashable, Codable {
    var name: String
    var path: String
    var id: String { path }
}

/// What a sidebar section *is*. The kinds have differing ownership arrows
/// (see docs/design/loose-terminal-entity.md): a `.folder` project's path is its
/// identity and owns its sessions; the `.terminals` container is presentation
/// only — each loose terminal session owns its *own* mutable path (the live cwd),
/// and the container's `path` is just the spawn fallback (`$HOME`). The `.chats`
/// container is the agent-side twin of `.terminals`: loose agent sessions that
/// aren't tied to a real project, gathered under one section rooted at the scoped
/// scratch workspace (`~/.termio/chats`) — agents can't be turned loose in `$HOME`,
/// which is exactly why they get their own funnel rather than joining `.terminals`.
enum ProjectKind: String, Codable {
    case folder
    case terminals
    case chats
}

/// A linked git checkout owned by a project. Sessions remain flat on the parent
/// project and point at this folder through `Session.worktreePath`.
struct Worktree: Identifiable, Hashable, Codable {
    var id = UUID()
    var path: String
    var createdAt = Date()
    /// Whether the user has pinned this worktree into the sidebar's top "Pinned"
    /// working set. Persisted; survives git reconciliation because
    /// `applyDiscoveredWorktrees` reuses the existing entry by path rather than
    /// rebuilding it, so the flag rides along. A freshly discovered worktree is unpinned.
    var pinned = false
}

extension Worktree {
    private enum CodingKeys: String, CodingKey { case id, path, createdAt, pinned }

    /// Custom decoding so state files written before `pinned` existed still load (it
    /// defaults to unpinned). In an extension so the synthesized memberwise init used
    /// at call sites (`Worktree(path:)`) survives; encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// A project is a working directory (typically a git repo) that groups one or
/// more agent/terminal sessions, mirroring the sidebar grouping in unpeel.
struct Project: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    /// Absolute path used as the working directory for the project's sessions.
    var path: String
    /// Current git branch, shown in each session's top bar (display only for now).
    var branch: String
    var sessions: [Session]
    /// Linked checkout folders shown as nested session containers. Their sessions
    /// stay in `sessions` so the control plane keeps one flat project roster.
    var worktrees: [Worktree] = []

    /// Whether the user has pinned this project to the top of the sidebar. Pinned
    /// projects always sort ahead of the rest, regardless of the chosen sort order
    /// (see `TermioStore.orderedProjects`).
    var pinned: Bool = false

    /// `.folder` for an opened directory, `.terminals` for the loose-terminals
    /// container (at most one exists; it always sorts first in the sidebar).
    var kind: ProjectKind = .folder
}

extension Project {
    private enum CodingKeys: String, CodingKey {
        case id, name, path, branch, sessions, worktrees, pinned, kind
    }

    /// Missing collection and flag keys take their pre-feature defaults so older
    /// state files remain readable. Kept in an extension so the synthesized
    /// memberwise initializer survives for call sites that build projects directly;
    /// encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        branch = try container.decode(String.self, forKey: .branch)
        sessions = try container.decode([Session].self, forKey: .sessions)
        worktrees = try container.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .folder
    }
}

/// The agent model — `AgentDefinition` (aliased `AgentPreset`) plus the built-in
/// roster and the user-agent catalog — lives in `AgentDefinition.swift`.

/// The closed set of ways termio renders an agent icon. Agent identities stay out
/// of this enum: adding a raster-backed agent supplies a resource/path URL, while
/// only the two vector marks remain a closed rendering primitive.
enum AgentIcon: Hashable {
    case image(URL)
    case vector(BrandLogo)
    case symbol(String)
    case terminalGlyph
    /// A Hugeicons stroke glyph, for feature rows that share the app's own icon
    /// language rather than an agent identity.
    case huge(HugeIcon)
}

/// The Hugeicons glyph set now lives in `TermioShared` (single source shared
/// with iOS); these aliases keep the app's unqualified references compiling.
typealias HugeIcon = TermioShared.HugeIcon
typealias HugeIconView = TermioShared.HugeIconView
typealias HugeIconShape = TermioShared.HugeIconShape

/// A vendor brand mark, stored as its official SVG path so it renders crisp at any
/// size without shipping binary image assets. Rendered in the vendor's brand color
/// by `BrandLogoShape`; see `BrandLogo.tint`. Pi and OpenCode are not here — their
/// marks ship as image files selected by resource name or user path.
enum BrandLogo: Hashable {
    case claude
    case codex
    case grok

    /// Side length of the source SVG's square viewBox (the marks use 24).
    var viewBox: CGFloat { 24 }

    /// Whether the mark's holes are cut with the even-odd fill rule. Codex's mark
    /// (from lobehub) and Grok's slashed ring declare `fill-rule="evenodd"` to
    /// carve their glyphs out of the blob; Claude's single outline needs nonzero.
    var usesEvenOddFill: Bool {
        switch self {
        case .codex, .grok: return true
        case .claude: return false
        }
    }

    var pathData: String {
        switch self {
        case .claude:
            return "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
        case .codex:
            // OpenAI Codex mark (lobehub.com): a rounded blob with `</` and `_`
            // glyphs cut out via even-odd fill. Source viewBox 24, `currentColor`.
            return "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"
        case .grok:
            // xAI Grok mark (x.ai): a slashed ring, two subpaths cut with even-odd
            // fill. Source viewBox 24, `currentColor` (monochrome).
            return "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"
        }
    }
}

/// A session's live activity, shown as a dot in the sidebar and aggregated into
/// the menu-bar pulse. Driven by two layers: the zero-config libghostty surface
/// signals the `TerminalViewState` publishes (bell / desktop notification), and,
/// when enabled, the per-agent hooks reported into `HookListener`.
///
/// The four states follow the cleanest model among the reference tools
/// (open-vibe-island): a finished turn is `done`, *not* "needs you" —
/// `needsAttention` is reserved for an agent actually blocked on the user (a
/// permission prompt or a desktop notification / bell). This keeps "the agent is
/// ready for you" (calm) distinct from "the agent is waiting on you" (urgent).
enum SessionStatus: Hashable {
    /// Nothing pending, or the user is already looking at the session.
    case idle
    /// The agent is actively processing a turn (shown as the spinning icon).
    case working
    /// The agent finished its turn while the user was elsewhere — a calm
    /// "ready for you" cue, not a demand.
    case done
    /// The agent is blocked waiting on the user (permission prompt, or a bell /
    /// desktop notification it raised). The one state that demands attention.
    case needsAttention
}

/// A single terminal session within a project. Each session owns one live
/// libghostty terminal surface (see `TermioStore.surface(for:in:)`).
struct Session: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    /// Which agent (or plain shell) this session runs.
    var agent: AgentPreset
    var createdAt: Date

    /// Absolute path of a git worktree this session runs in, or `nil` (the common
    /// case) to run directly in the project's directory. The parent project's
    /// `worktrees` array owns the folder node; this path is the flat join key that
    /// keeps session lookup and the control plane unchanged.
    var worktreePath: String?

    /// The stable id termio hands the agent so a relaunch resumes *this exact*
    /// conversation rather than starting a new one. Assigned on first launch for
    /// agents that can pin their session id (Claude Code, Grok, Pi — see
    /// `AgentPreset.usesPinnedResumeID`) and `nil` otherwise; Codex/OpenCode resume the
    /// most recent session in the directory and never need one. Persisted, so it
    /// survives the app quitting.
    var resumeID: String?

    /// Whether this session's agent has been launched at least once (in this or a
    /// prior run). Persisted so that on the next launch the agent is resumed instead of
    /// started fresh.
    var launched = false

    /// Whether the user has pinned this session into the sidebar's top "Pinned" working
    /// set. Persisted. The session still shows in its normal tree spot (the pin adds a
    /// shortcut up top, it doesn't move the row).
    var pinned = false

    /// When set, this session is an **SSH terminal** — instead of a local login
    /// shell it launches `ssh <host>` in the PTY, dropping the user straight onto a
    /// remote host. The value is the connection target: a `~/.ssh/config` alias
    /// (`myserver`) or a bare `user@host`. Everything else about the session — the
    /// PTY, the surface, the sidebar row, reconnect — is identical to a loose
    /// terminal; only the launched program differs (see `TermioStore.surface`). The
    /// project's local inspector panes (git, files, search) still read the *local*
    /// filesystem, so an SSH terminal is a terminal, not a remote project.
    var sshHost: String?

    var isSSH: Bool { sshHost != nil }

    /// The last working directory the shell reported over OSC 7, persisted for
    /// sessions in the loose-terminals container only: a loose terminal's identity
    /// is the session, its path is this mutable property — so a relaunched shell
    /// respawns where the user last `cd`'d, not back at `$HOME`. Sessions of a
    /// real (`.folder`) project never set it; their anchor is the project path.
    var lastWorkingDirectory: String?

    /// The last meaningful terminal title (`OSC 0/2`) the session's agent reported,
    /// e.g. Claude Code's conversation topic. Persisted so the sidebar keeps the
    /// adopted label across app restarts — the agent only re-emits a title once it
    /// is actively conversing again, which used to leave every row back at the
    /// default agent name after a relaunch. Display-only; `title` stays untouched.
    var liveTitle: String?

    /// When the agent was first launched, used to correlate Codex/OpenCode's own
    /// session record (matched by working directory) back to *this* session — their
    /// CLIs won't accept an id up front, so the id is discovered afterward from the
    /// record created at this moment (see `AgentSessionStore.discover`). `nil` until
    /// first launch, and unused by the pinned-id agents (Claude Code, Pi).
    var launchedAt: Date?

    init(title: String, agent: AgentPreset = .terminal, createdAt: Date = Date()) {
        self.title = title
        self.agent = agent
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, agent, createdAt, worktreePath, resumeID, launched, launchedAt,
             liveTitle, lastWorkingDirectory, sshHost, pinned
    }

    /// Custom decoding so state files written before the resume fields existed still
    /// load: the new keys default to "no id, never launched", which makes an upgraded
    /// session start fresh once and then be resumable from then on. (Encoding stays
    /// synthesized.)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        agent = try container.decode(AgentPreset.self, forKey: .agent)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        resumeID = try container.decodeIfPresent(String.self, forKey: .resumeID)
        launched = try container.decodeIfPresent(Bool.self, forKey: .launched) ?? false
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        launchedAt = try container.decodeIfPresent(Date.self, forKey: .launchedAt)
        liveTitle = try container.decodeIfPresent(String.self, forKey: .liveTitle)
        lastWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .lastWorkingDirectory)
        sshHost = try container.decodeIfPresent(String.self, forKey: .sshHost)
    }
}

extension Project {
    /// First-run state for a fresh install: the loose-terminals container with one
    /// shell session, so a new user lands in a working terminal instead of
    /// dev-machine placeholders. The shell starts at `$HOME` (its `path`), but the
    /// section is presented as "Terminals", not as a home *project* — the terminal
    /// is the entity, its cwd just a property (see docs/design/loose-terminal-entity.md).
    ///
    /// The working directory must be the home directory — never
    /// `currentDirectoryPath`, which is `/` when the app is launched from Finder
    /// (that is what left the shell sitting at `/ %` on first launch).
    static func firstRunProjects() -> [Project] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        return [
            Project(
                name: "Terminals",
                path: home,
                branch: "—",
                sessions: [
                    Session(title: "Terminal 1"),
                ],
                kind: .terminals
            ),
        ]
    }
}
