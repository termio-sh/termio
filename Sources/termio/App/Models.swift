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

/// The machine a workspace belongs to, said outright.
///
/// `Workspace.deviceAlias` is one optional carrying two different claims: `nil`
/// means both "this Mac" and "a workspace the user made", and code that tests
/// `deviceAlias != nil` gets an answer to whichever question it happened to be
/// asking. Naming the machine on its own separates them — this says only which
/// device owns the scope, and says it for every workspace, including the ones
/// nobody ever named a device for.
///
/// Derived, never stored: `deviceAlias` remains the persisted field and `nil` on
/// disk still decodes to this Mac, so no state file changes shape. A snapshot
/// that fails to decode is swallowed into a fresh first-run tree (`StateFile`),
/// which would replace the user's whole sidebar — the invariant is therefore
/// established at load time by `WorkspaceMigration.reconcile`, never by a stricter
/// decoder.
///
/// Distinct from `KnownDevice`, which pairs the alias with the `host_id` a
/// handshake revealed. This is the filing key: what the workspace *claims*, known
/// before anything has connected.
enum WorkspaceDevice: Hashable {
    case thisMac
    case ssh(alias: String)

    init(alias: String?) {
        self = alias.map(WorkspaceDevice.ssh) ?? .thisMac
    }

    /// The `~/.ssh/config` alias this machine is reached by, `nil` for this Mac —
    /// the shape the stored fields and every existing call site already speak.
    var alias: String? {
        switch self {
        case .thisMac: nil
        case .ssh(let alias): alias
        }
    }

    var isThisMac: Bool { alias == nil }

    /// What a workspace named after this machine is called. This Mac has no alias
    /// to show and the host never supplies a display name, so the client picks one
    /// (the same name `KnownDevice` shows in every device menu).
    var displayName: String { alias ?? localized("This Mac") }
}

/// The scope the sidebar shows: one Pinned working set, one Terminals section,
/// one Chats section, and the projects filed under it. Everything the sidebar
/// drew before is here; what changed is that a workspace bounds it, where a
/// machine used to.
///
/// A workspace owns its loose sessions outright. They used to be modeled as
/// projects with a `kind` — `.terminals`, `.chats`, `.host` — which is a funnel
/// wearing a folder's clothes: a project's path is its identity and it owns its
/// sessions, while a loose terminal owns its *own* mutable path (the live cwd)
/// and the container's path was only the spawn fallback. Two arrays here say the
/// same thing without the disguise, and a project is a folder again.
///
/// The two collections stay separate rather than being one array split by agent:
/// a plain shell that a user turns into an agent by typing its command
/// (`noteForegroundAgent`) must not jump sections underneath them.
struct Workspace: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String

    /// Loose shells — sessions that answer to no folder. They spawn at `$HOME`
    /// and each one carries its own cwd from there
    /// (see docs/design/20260713-loose-terminal-entity.md).
    var terminals: [Session] = []

    /// Loose agent sessions, the agent-side twin of `terminals`. They spawn in
    /// the scoped scratch directory (`~/.termio/chats`) rather than `$HOME`: an
    /// autonomous agent turned loose in a home directory can read and write
    /// `~/.ssh` and everything beside it.
    var chats: [Session] = []

    /// The machine this workspace belongs to — the `~/.ssh/config` alias it is
    /// reached by — or `nil` for one on this Mac.
    ///
    /// Every workspace has a machine, and everything filed under it is on that
    /// machine: its projects' checkouts and the loose sessions that the `termiod`
    /// CLI or a phone started with nowhere else to be. This is the alias, the
    /// *bootstrap* identity: it exists before anything has connected, which is when
    /// the workspace has to exist (device architecture §9.5).
    var deviceAlias: String?

    /// The `host_id` the alias turned out to reach, filled in by the first
    /// `hello_ok` and `nil` until then. Two workspaces sharing one of these are
    /// two names for the same machine.
    var deviceID: String?

    /// The machine this workspace belongs to. Every workspace has one, and
    /// `WorkspaceMigration.reconcile` guarantees it agrees with the projects filed
    /// under it — so a caller asks the workspace which machine it is on instead of
    /// re-deriving that from whichever field is nearest.
    var device: WorkspaceDevice { WorkspaceDevice(alias: deviceAlias) }

    /// Whether Termio created this workspace on the user's behalf, rather than the
    /// user asking for it. Only these may be swept when they empty out.
    ///
    /// Declared at creation, never inferred. It used to be read off `deviceAlias`
    /// — "named after a machine" standing in for "made automatically" — and the
    /// device stamping in `WorkspaceMigration.reconcile` broke that proxy: a
    /// workspace the user named and filled with checkouts on one box now carries
    /// that box's alias too, and would have become sweepable. A workspace someone
    /// named is theirs whichever machine it turned out to be on.
    ///
    /// Optional on purpose: **absent** means "written before this field existed,
    /// so it is not yet known", and `false` means "asked and answered — this one
    /// is the user's". Collapsing the two to `false` is what made an earlier
    /// version of this wrong: `reconcile` recovers the answer for absent values,
    /// so a stored `false` that decoded as absent would be re-derived on every
    /// launch, and a workspace the user named after the box its checkouts sit on
    /// would be claimed the second time the app opened. Recovery runs once and
    /// then records what it decided.
    ///
    /// A missing value is never swept — `isAutoCreated == true` is the test, so
    /// unknown stays safe.
    var isAutoCreated: Bool?

    /// Every session the workspace owns directly. Its projects' sessions are not
    /// here — they belong to the project.
    var looseSessions: [Session] { terminals + chats }

    /// The same machine as `device`, in the form the menus and row marks name it —
    /// the alias paired with the `host_id` a handshake revealed — and `nil` for
    /// this Mac, which is the machine nothing needs to be told about.
    var knownDevice: KnownDevice? {
        deviceAlias.map { KnownDevice(alias: $0, deviceID: deviceID) }
    }

    /// Whether `alias` reaches this workspace's machine.
    ///
    /// Matched by device identity once both ends know it, so a box reached by a
    /// LAN name and a tailnet name is still one machine, and by alias until the
    /// first handshake resolves one — the bootstrap/stable split `KnownDevice`
    /// carries. This Mac matches no alias: it is not reached by one.
    func isOn(alias: String, device deviceID: String?) -> Bool {
        guard let mine = deviceAlias else { return false }
        if let deviceID, let known = self.deviceID { return deviceID == known }
        return mine == alias
    }
}

extension Workspace {
    private enum CodingKeys: String, CodingKey {
        case id, name, terminals, chats, deviceAlias, deviceID, isAutoCreated
    }

    /// Missing collections take their empty defaults so a workspace written by an
    /// older build still loads. In an extension so the memberwise initializer
    /// survives for the call sites that build workspaces directly; encoding stays
    /// synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        terminals = try c.decodeIfPresent([Session].self, forKey: .terminals) ?? []
        chats = try c.decodeIfPresent([Session].self, forKey: .chats) ?? []
        deviceAlias = try c.decodeIfPresent(String.self, forKey: .deviceAlias)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        isAutoCreated = try c.decodeIfPresent(Bool.self, forKey: .isAutoCreated)
    }

    /// First-run state for a fresh install: one workspace holding one shell, so a
    /// new user lands in a working terminal rather than an empty column. The
    /// switcher stays out of sight until they make a second workspace.
    static func firstRun() -> [Workspace] {
        [Workspace(name: defaultName, terminals: [Session(title: "Terminal 1")])]
    }

    /// What the one workspace every user starts with is called. It is the only
    /// workspace most people will ever have, so it is named for what it holds
    /// rather than for the feature.
    static let defaultName = "Sessions"

    /// The owner a project decodes to when the state file predates workspaces —
    /// "nobody has said yet". `WorkspaceMigration` replaces every one of these; a
    /// project still carrying it after that is filed under the first workspace
    /// rather than disappearing.
    static let unfiledID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
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
    /// The workspace this project is filed under — the scope the sidebar shows.
    var workspaceID: Workspace.ID
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

    /// Where this project lives on each **device** it has been cloned to, keyed
    /// by that device's `host_id` → absolute remote path.
    ///
    /// This is what makes "New Terminal ▸ <device>" from a *project* row mean "this
    /// repo, over there" rather than "a shell in that device's `$HOME`". The local
    /// `path` is meaningless on the other box, so the correspondence has to be
    /// recorded when `Clone to <device>…` establishes it.
    ///
    /// Keyed by device rather than by SSH alias because one machine commonly
    /// answers to several aliases (`vps-lan`, `vps-wan`, a tailnet name): keyed by
    /// alias, the day the user changes networks the same clone becomes invisible
    /// and the repo looks un-cloned. State files written before this carry alias
    /// keys; `remoteCheckout(device:alias:)` still answers from them, and
    /// `TermioStore.adoptDevice` promotes each one the first time its alias
    /// resolves to a device.
    var remoteCheckouts: [String: String] = [:]

    /// The machine a state file written **before** the hierarchy recorded on the
    /// checkout itself, and `nil` on every project this build writes.
    ///
    /// A checkout inherits its machine from the workspace that owns it — a
    /// workspace belongs to exactly one — so the app asks the store
    /// (`TermioStore.device(of:)`) and this field is not part of that answer.
    /// It survives for `WorkspaceMigration`, the one place the two shapes meet:
    /// a workspace whose checkouts turn out to span machines can only be
    /// recognised from what the old file recorded per checkout.
    ///
    /// Decoded, never encoded. Writing it back would make every later load read
    /// the tree as the old shape again, and a project that records no machine
    /// would go on meaning "this Mac" instead of "whichever machine my workspace
    /// is on" — which is a remote checkout torn off its workspace on next launch.
    var legacyDevice: KnownDevice?
}

extension Project {
    private enum CodingKeys: String, CodingKey {
        case id, workspaceID, name, path, branch, sessions, worktrees, pinned, remoteCheckouts
        case deviceAlias, deviceID
    }

    /// Missing collection and flag keys take their pre-feature defaults so older
    /// state files remain readable. Kept in an extension so the synthesized
    /// memberwise initializer survives for call sites that build projects directly;
    /// encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // A project written before workspaces existed carries no owner. It is
        // given one by `WorkspaceMigration`, which runs over the whole snapshot
        // and knows which workspace every project lands in; the sentinel here is
        // simply the value that migration overwrites.
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
            ?? Workspace.unfiledID
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        branch = try container.decode(String.self, forKey: .branch)
        sessions = try container.decode([Session].self, forKey: .sessions)
        worktrees = try container.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        remoteCheckouts =
            try container.decodeIfPresent([String: String].self, forKey: .remoteCheckouts) ?? [:]
        // Kept in the decoder after the live fields went: a file written before
        // the hierarchy is the only thing that still says which machine each
        // checkout is on, and dropping the keys here would lose the split that
        // `WorkspaceMigration` needs them for.
        let recordedAlias = try container.decodeIfPresent(String.self, forKey: .deviceAlias)
        let recordedDeviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        legacyDevice = recordedAlias.map { KnownDevice(alias: $0, deviceID: recordedDeviceID) }
    }

    /// Written out by hand so `legacyDevice` does not round-trip — see the field.
    /// Every other property is listed here, so a new one has to be added to this
    /// and to `CodingKeys` to be persisted.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(branch, forKey: .branch)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(worktrees, forKey: .worktrees)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(remoteCheckouts, forKey: .remoteCheckouts)
    }

    /// The recorded checkout for one machine, addressed by device where the app
    /// knows which device an alias leads to.
    ///
    /// `deviceID` is `nil` until something has connected — nothing can resolve a
    /// route to a machine without a handshake — and a sidebar menu is built
    /// synchronously, with no connection to spend. Falling back to the legacy
    /// alias key there is better than reporting a repo as un-cloned because the
    /// app has not yet been told which box the alias reaches.
    func remoteCheckout(device deviceID: String?, alias: String) -> String? {
        if let deviceID, let path = remoteCheckouts[deviceID] { return path }
        return remoteCheckouts[alias]
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

/// GitHub's Octicons for issue/PR state, shared with iOS from `TermioShared`.
typealias StateOcticon = TermioShared.StateOcticon
typealias OcticonView = TermioShared.OcticonView

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
/// when enabled, the per-agent hooks that call `termio agent report`.
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

    /// The name this session was *given* — by the user renaming it, by a person on
    /// the far box (`termiod new -n build`), or by Termio naming the row for what it
    /// is with nothing better behind it (`SSH Shell`). It wins over every label the
    /// app can derive, and `nil` (the common case) means nobody has named this row.
    ///
    /// It is a field of its own rather than a flag beside `title` because the two
    /// have different owners. `title` is the placeholder the app composes and freely
    /// rewrites — `Terminal 3`, `Claude Code`, a migration renumbering an old state
    /// file — while this is set only by the act of naming. Keeping them apart is
    /// what makes them impossible to contradict: a flag has to be updated at every
    /// site that touches `title`, and the sites that forget leave a row insisting on
    /// a name nobody gave it.
    ///
    /// The distinction used to be recovered by pattern-matching `title` — anything
    /// that wasn't `Terminal N` or the agent's own name was read as the user's. That
    /// is why a remote row stayed frozen at `boxlit · ukvps` while its local twin
    /// followed the agent's topic: the label Termio composed for it was
    /// indistinguishable from one the user typed.
    var givenTitle: String?

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

    /// The public key this session is installing on `sshHost` with `ssh-copy-id`,
    /// set only by Settings ▸ Devices' Set Up Key action. It rides in the PTY
    /// precisely because the far side will ask for a password: the user types it
    /// once, into a real terminal, and termio neither sees nor stores it.
    ///
    /// Deliberately outside `CodingKeys`, so it never survives a relaunch. The
    /// command is a one-shot; restoring it would re-run an install the user
    /// already completed and ask for that password again. A restored session
    /// opens the plain `ssh` shell its `sshHost` describes.
    var sshKeyToInstall: String?

    var isSSH: Bool { sshHost != nil }

    /// When set, this session runs **inside a `termiod` daemon on an SSH host**
    /// rather than locally: the Mac attaches over `ssh <host> termiod stdio` and
    /// the shell/agent lives on the remote box (see `TermioStore.addRemoteTerminal`).
    /// Unlike `sshHost` — which launches a plain `ssh <host>` in a *local* PTY —
    /// this is the durable termiod path, so detach-not-kill and snapshot repaint
    /// carry across the network. The value is a `~/.ssh/config` alias; nil keeps
    /// the session on this Mac's own daemon. Persisted so a relaunch reattaches
    /// to the same remote daemon session by name.
    var termiodRemoteHost: String?

    /// The **device** this session was last found to be running on — the `host_id`
    /// its daemon reported at handshake, recorded because a session belongs to a
    /// machine, not to the road taken to reach it. `termiodRemoteHost` says which
    /// road was tried; this says where it arrived, and the two disagree the moment
    /// the user reaches the same box by a different alias.
    ///
    /// `nil` until the session has attached at least once — a route cannot be
    /// resolved to a device without connecting.
    var deviceID: String?

    /// The remote working directory a `termiodRemoteHost` session spawns its shell
    /// in — set by "Clone to <device>…" to the freshly cloned directory (`~/<repo>`)
    /// so the terminal opens straight inside it. `nil` (the common case) lets the
    /// remote login shell start at its own `$HOME`. Ignored when `termiodRemoteHost`
    /// is nil.
    var termiodRemoteCwd: String?

    /// The name this session answers to **inside its device's daemon**, when that
    /// is not this session's own uuid.
    ///
    /// Sessions Termio opens are named with their uuid, which is what makes
    /// reattach-after-relaunch work: `attach` resolves the name first, so the row
    /// finds the same process. A session Termio did **not** open already had a
    /// name before this app ever saw it — started from the `termiod` CLI, or by a
    /// phone — and adopting it means keeping that name, because the name is how
    /// the daemon is asked for that exact PTY. Renaming it to a fresh uuid would
    /// spawn a second session beside the one the user was pointing at.
    ///
    /// `nil` for every session this app created, which is nearly all of them.
    var termiodSessionName: String?

    /// The daemon's own id for the running session behind this row — minted
    /// fresh per creation, so a reused *name* never reuses the id. Learned from
    /// the first roster row or information event that answers for this session,
    /// and written into the closed-session journal on destroy, where it is what
    /// tells this app's orphan from a new session someone recreated under the
    /// same name. `nil` until a daemon has answered for the row.
    var termiodDaemonID: String?

    /// Adopt another session's machine — both halves of it.
    ///
    /// A device has two identities during its life (device architecture §9.5):
    /// the SSH alias it was *authored* against, known before anything connects,
    /// and the `deviceID` the first `hello_ok` reveals. A session derived from
    /// another — a split, and every future "open beside this" verb — has to
    /// carry both, or it lands on this Mac while sitting in a pane that reads
    /// as the same machine.
    ///
    /// This helper exists so the copying happens in one place rather than at
    /// each call site: **when sessions stop naming a host and take their device
    /// from the container that owns them, this method is the only thing to
    /// delete.** Spreading `termiodRemoteHost = …` across call sites is what
    /// makes that migration expensive, and it is the fork the RFC removes.
    mutating func inheritDevice(from origin: Session?) {
        guard let origin else { return }
        deviceID = origin.deviceID
        termiodRemoteHost = origin.termiodRemoteHost
        termiodRemoteCwd = origin.termiodRemoteCwd
    }

    /// The last working directory the shell reported over OSC 7, persisted for a
    /// workspace's loose terminals only: a loose terminal's identity is the
    /// session, its path is this mutable property — so a relaunched shell respawns
    /// where the user last `cd`'d, not back at `$HOME`. A project's sessions never
    /// set it; their anchor is the project path.
    var lastWorkingDirectory: String?

    /// Where this session was opened, when that isn't its project's own anchor: ⌘T
    /// and every split record the directory the pane they came from was sitting in,
    /// so the new shell starts *there* rather than at the project root. Persisted, so
    /// a relaunch reopens it in the same place. `lastWorkingDirectory` outranks it for
    /// a loose terminal — a shell that reported its own cwd knows better than the seed
    /// it was given.
    var spawnDirectory: String?

    /// The last meaningful terminal title (`OSC 0/2`) the session's agent reported,
    /// e.g. Claude Code's conversation topic. Persisted so the sidebar keeps the
    /// adopted label across app restarts — the agent only re-emits a title once it
    /// is actively conversing again, which used to leave every row back at the
    /// default agent name after a relaunch. Display-only; `title` stays untouched.
    var liveTitle: String?

    /// A compact label derived from the first user prompt in the current conversation.
    /// This is a fallback for agents such as Codex whose default OSC title names only
    /// the project. A meaningful native title still wins, and a title the user sets in
    /// Termio wins over both. Cleared when the agent rotates to a new conversation.
    var promptTitle: String?

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
             liveTitle, promptTitle, lastWorkingDirectory, spawnDirectory, sshHost, pinned,
             termiodRemoteHost, termiodRemoteCwd, deviceID, termiodSessionName,
             termiodDaemonID, givenTitle
    }

    /// The name to recover from a state file written before `givenTitle` existed,
    /// back when `title` held both kinds of label. The old code told them apart by
    /// pattern-matching, so this has to as well: anything that wasn't one of the
    /// labels Termio composed was, by the only definition that existed then, a name
    /// someone gave.
    ///
    /// `<name> · <host>` and a bare host are named here because they are the
    /// composed labels that test got wrong — `addRemoteTerminal` wrote them into
    /// `title`, and every gate downstream then read them as chosen. A session the
    /// user really did rename to something ending in its own host's alias reads as
    /// composed and starts following its agent; renaming it again settles it.
    static func recoveredGivenTitle(
        _ title: String, agent: AgentPreset, remoteHost: String?
    ) -> String? {
        if TermioStore.isAutoTerminalName(title) { return nil }
        if title == agent.displayName { return nil }
        if let remoteHost, title == remoteHost || title.hasSuffix(" · \(remoteHost)") {
            return nil
        }
        return title
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
        promptTitle = try container.decodeIfPresent(String.self, forKey: .promptTitle)
        lastWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .lastWorkingDirectory)
        spawnDirectory = try container.decodeIfPresent(String.self, forKey: .spawnDirectory)
        sshHost = try container.decodeIfPresent(String.self, forKey: .sshHost)
        termiodRemoteHost = try container.decodeIfPresent(String.self, forKey: .termiodRemoteHost)
        termiodRemoteCwd = try container.decodeIfPresent(String.self, forKey: .termiodRemoteCwd)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        termiodSessionName = try container.decodeIfPresent(
            String.self, forKey: .termiodSessionName)
        termiodDaemonID = try container.decodeIfPresent(String.self, forKey: .termiodDaemonID)
        givenTitle = try container.decodeIfPresent(String.self, forKey: .givenTitle)
            ?? Self.recoveredGivenTitle(title, agent: agent, remoteHost: termiodRemoteHost)
    }
}

