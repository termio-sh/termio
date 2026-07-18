import Foundation

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

/// How an agent's glyph is drawn: a built-in SF Symbol, a Hugeicons stroke mark,
/// a vector brand logo, or a vendor's real favicon image. SF Symbols ships no
/// Claude/OpenAI mark, so those are carried as vector path data and rendered by
/// `BrandLogoShape`; the Hugeicons marks are stroked by `HugeIconShape`. Pi and
/// OpenCode use their actual favicon files (see `BrandImageAsset`) because their
/// marks carry detail — Pi's adaptive monochrome glyph, OpenCode's two-tone box —
/// that a single-fill vector path can't reproduce.
enum AgentIcon: Hashable {
    case systemSymbol(String)
    case hugeIcon(HugeIcon)
    case brand(BrandLogo)
    case brandImage(BrandImageAsset)
    /// A user agent's own icon file (PNG/SVG) on disk, from its `agent.json`. Loaded
    /// by `AgentIconView` as an `NSImage`; a missing file degrades to blank space.
    case imageFile(URL)
}

/// A vendor brand mark carried as its real favicon image, bundled under
/// `Resources` and rendered by `BrandImageView`. Downloaded from each vendor's
/// site: Pi from `pi.dev/favicon.svg`, OpenCode from `opencode.ai`'s favicon,
/// Cursor from `cursor.com/favicon.svg`, Amp from its WorkOS-hosted brand icon,
/// Kimi from `kimi.com/favicon.ico`. Pi, Cursor, OpenCode, and Kimi are opaque
/// dark app-icon tiles; Amp's mark is its red chevrons on a transparent field, so
/// the rounded-tile clip simply leaves the corners bare.
enum BrandImageAsset: Hashable {
    case pi
    case openCode
    case amp
    case cursor
    case kimi
    case antigravity
    case hermes

    /// Base name of the bundled resource file (without extension).
    var resourceName: String {
        switch self {
        case .pi: return "pi-favicon"
        case .openCode: return "opencode-favicon"
        case .amp: return "amp-favicon"
        case .cursor: return "cursor-favicon"
        case .kimi: return "kimi-favicon"
        case .antigravity: return "antigravity-favicon"
        case .hermes: return "hermes-favicon"
        }
    }

    /// File extension of the bundled resource: Pi and Cursor ship as vector SVGs,
    /// OpenCode, Amp, and Kimi only publish raster favicons.
    var fileExtension: String {
        switch self {
        case .pi, .cursor: return "svg"
        case .openCode, .amp, .kimi, .antigravity, .hermes: return "png"
        }
    }
}

/// A Hugeicons stroke glyph, stored as its source SVG path data on a 24×24
/// viewBox. Unlike `BrandLogo` (filled vendor marks), these are drawn as a
/// rounded *stroke* by `HugeIconShape`, matching Hugeicons' 1.5px line style.
/// Multiple `<path>` elements from the source are concatenated into one data
/// string — each starts with `M`, so the parser treats them as separate subpaths.
enum HugeIcon: Hashable {
    case terminal
    case folder
    case folderOpen
    case chevronRight
    case file
    case documentCode
    case settings
    case image
    case database
    case archive
    case audio
    case video

    /// Side length of the source SVG's square viewBox (Hugeicons uses 24).
    var viewBox: CGFloat { 24 }

    var pathData: String {
        switch self {
        case .terminal:
            return "M7.5 7.5L8.72654 8.55719C9.24218 9.00163 9.5 9.22386 9.5 9.5C9.5 9.77614 9.24218 9.99836 8.72654 10.4428L7.5 11.5 M11.5 12.5H15.5 M12 21C15.7497 21 17.6246 21 18.9389 20.0451C19.3634 19.7367 19.7367 19.3634 20.0451 18.9389C21 17.6246 21 15.7497 21 12C21 8.25027 21 6.3754 20.0451 5.06107C19.7367 4.6366 19.3634 4.26331 18.9389 3.95491C17.6246 3 15.7497 3 12 3C8.25027 3 6.3754 3 5.06107 3.95491C4.6366 4.26331 4.26331 4.6366 3.95491 5.06107C3 6.3754 3 8.25027 3 12C3 15.7497 3 17.6246 3.95491 18.9389C4.26331 19.3634 4.6366 19.7367 5.06107 20.0451C6.3754 21 8.25027 21 12 21Z"
        case .folder:
            return "M8 7H16.75C18.8567 7 19.91 7 20.6667 7.50559C20.9943 7.72447 21.2755 8.00572 21.4944 8.33329C22 9.08996 22 10.1433 22 12.25C22 15.7612 22 17.5167 21.1573 18.7779C20.7926 19.3238 20.3238 19.7926 19.7779 20.1573C18.5167 21 16.7612 21 13.25 21H12C7.28595 21 4.92893 21 3.46447 19.5355C2 18.0711 2 15.714 2 11V7.94427C2 6.1278 2 5.21956 2.38032 4.53806C2.65142 4.05227 3.05227 3.65142 3.53806 3.38032C4.21956 3 5.1278 3 6.94427 3C8.10802 3 8.6899 3 9.19926 3.19101C10.3622 3.62712 10.8418 4.68358 11.3666 5.73313L12 7"
        case .folderOpen:
            // Hugeicons "folder-03": a single smooth rounded tray (the open body)
            // plus a simple tabbed back flap. Chosen over "folder-open" — whose two
            // stacked, flared trapezoids turn muddy at the sidebar's small size —
            // because the one rounded body reads cleanly there and still pairs with
            // folder-01's angled tab for the closed state.
            return "M2.36064 15.1788C1.98502 13.2956 1.79721 12.354 2.33084 11.7159C2.36642 11.6734 2.40405 11.6323 2.44361 11.5927C3.03686 11 4.08674 11 6.1865 11H17.8135C19.9133 11 20.9631 11 21.5564 11.5927C21.5959 11.6323 21.6336 11.6734 21.6692 11.7159C22.2028 12.354 22.015 13.2956 21.6394 15.1788C21.0993 17.8865 20.8292 19.2404 19.8109 20.0721C19.7414 20.1288 19.6698 20.1833 19.5961 20.2354C18.5163 21 17.0068 21 13.9876 21H10.0124C6.99323 21 5.48367 21 4.40387 20.2354C4.33022 20.1833 4.2586 20.1288 4.18914 20.0721C3.17075 19.2404 2.90072 17.8865 2.36064 15.1788Z M4 11V5.5C4 4.11929 5.11929 3 6.5 3H8.92963C9.59834 3 10.2228 3.3342 10.5937 3.8906L12 6M12 6H8.5M12 6H17.5C18.8807 6 20 7.11929 20 8.5V11"
        case .chevronRight:
            // A plain two-segment chevron (not the bulged Hugeicons arrow) — round
            // linejoin softens the tip. The section disclosure arrow: points right when
            // collapsed, rotated a quarter-turn down when open.
            return "M10 6L16 12L10 18"
        // File glyphs from Hugeicons (MIT), normalized by `HugeIconShape` to
        // the same optical width as the sidebar's folder and terminal icons.
        case .file:
            return "M8 7L16 7 M8 11L12 11 M13 21.5V21C13 18.1716 13 16.7574 13.8787 15.8787C14.7574 15 16.1716 15 19 15H19.5M20 13.3431V10C20 6.22876 20 4.34315 18.8284 3.17157C17.6569 2 15.7712 2 12 2C8.22877 2 6.34315 2 5.17157 3.17157C4 4.34314 4 6.22876 4 10L4 14.5442C4 17.7892 4 19.4117 4.88607 20.5107C5.06508 20.7327 5.26731 20.9349 5.48933 21.1139C6.58831 22 8.21082 22 11.4558 22C12.1614 22 12.5141 22 12.8372 21.886C12.9044 21.8623 12.9702 21.835 13.0345 21.8043C13.3436 21.6564 13.593 21.407 14.0919 20.9081L18.8284 16.1716C19.4065 15.5935 19.6955 15.3045 19.8478 14.9369C20 14.5694 20 14.1606 20 13.3431Z"
        case .documentCode:
            return "M18 16L19.8398 17.5858C20.6133 18.2525 21 18.5858 21 19C21 19.4142 20.6133 19.7475 19.8398 20.4142L18 22 M14 16L12.1602 17.5858C11.3867 18.2525 11 18.5858 11 19C11 19.4142 11.3867 19.7475 12.1602 20.4142L14 22 M20 13.0032L20 7.8199C20 6.12616 20 5.27929 19.732 4.60291C19.3013 3.51555 18.3902 2.65784 17.2352 2.25228C16.5168 2 15.6173 2 13.8182 2C10.6698 2 9.09563 2 7.83836 2.44148C5.81714 3.15122 4.22281 4.6522 3.46894 6.55509C3 7.73875 3 9.22077 3 12.1848L3 14.731C3 17.8013 3 19.3364 3.8477 20.4025C4.09058 20.708 4.37862 20.9792 4.70307 21.2078C5.61506 21.8506 6.85019 21.9757 9 22 M3 12C3 10.159 4.49238 8.66667 6.33333 8.66667C6.99912 8.66667 7.78404 8.78333 8.43137 8.60988C9.00652 8.45576 9.45576 8.00652 9.60988 7.43136C9.78333 6.78404 9.66667 5.99912 9.66667 5.33333C9.66667 3.49238 11.1591 2 13 2"
        case .settings:
            return "M15.5 12C15.5 13.933 13.933 15.5 12 15.5C10.067 15.5 8.5 13.933 8.5 12C8.5 10.067 10.067 8.5 12 8.5C13.933 8.5 15.5 10.067 15.5 12Z M21.011 14.0965C21.5329 13.9558 21.7939 13.8854 21.8969 13.7508C22 13.6163 22 13.3998 22 12.9669V11.0332C22 10.6003 22 10.3838 21.8969 10.2493C21.7938 10.1147 21.5329 10.0443 21.011 9.90358C19.0606 9.37759 17.8399 7.33851 18.3433 5.40087C18.4817 4.86799 18.5509 4.60156 18.4848 4.44529C18.4187 4.28902 18.2291 4.18134 17.8497 3.96596L16.125 2.98673C15.7528 2.77539 15.5667 2.66972 15.3997 2.69222C15.2326 2.71472 15.0442 2.90273 14.6672 3.27873C13.208 4.73448 10.7936 4.73442 9.33434 3.27864C8.95743 2.90263 8.76898 2.71463 8.60193 2.69212C8.43489 2.66962 8.24877 2.77529 7.87653 2.98663L6.15184 3.96587C5.77253 4.18123 5.58287 4.28891 5.51678 4.44515C5.45068 4.6014 5.51987 4.86787 5.65825 5.4008C6.16137 7.3385 4.93972 9.37763 2.98902 9.9036C2.46712 10.0443 2.20617 10.1147 2.10308 10.2492C2 10.3838 2 10.6003 2 11.0332V12.9669C2 13.3998 2 13.6163 2.10308 13.7508C2.20615 13.8854 2.46711 13.9558 2.98902 14.0965C4.9394 14.6225 6.16008 16.6616 5.65672 18.5992C5.51829 19.1321 5.44907 19.3985 5.51516 19.5548C5.58126 19.7111 5.77092 19.8188 6.15025 20.0341L7.87495 21.0134C8.24721 21.2247 8.43334 21.3304 8.6004 21.3079C8.76746 21.2854 8.95588 21.0973 9.33271 20.7213C10.7927 19.2644 13.2088 19.2643 14.6689 20.7212C15.0457 21.0973 15.2341 21.2853 15.4012 21.3078C15.5682 21.3303 15.7544 21.2246 16.1266 21.0133L17.8513 20.034C18.2307 19.8187 18.4204 19.711 18.4864 19.5547C18.5525 19.3984 18.4833 19.132 18.3448 18.5991C17.8412 16.6616 19.0609 14.6226 21.011 14.0965Z"
        case .image:
            return "M7.5 6A1.5 1.5 0 1 0 7.5 9A1.5 1.5 0 0 0 7.5 6 M2.5 12C2.5 7.52166 2.5 5.28249 3.89124 3.89124C5.28249 2.5 7.52166 2.5 12 2.5C16.4783 2.5 18.7175 2.5 20.1088 3.89124C21.5 5.28249 21.5 7.52166 21.5 12C21.5 16.4783 21.5 18.7175 20.1088 20.1088C18.7175 21.5 16.4783 21.5 12 21.5C7.52166 21.5 5.28249 21.5 3.89124 20.1088C2.5 18.7175 2.5 16.4783 2.5 12Z M5 21C9.37246 15.775 14.2741 8.88406 21.4975 13.5424"
        case .database:
            return "M2.5 12C2.5 7.52166 2.5 5.28249 3.89124 3.89124C5.28249 2.5 7.52166 2.5 12 2.5C16.4783 2.5 18.7175 2.5 20.1088 3.89124C21.5 5.28249 21.5 7.52166 21.5 12C21.5 16.4783 21.5 18.7175 20.1088 20.1088C18.7175 21.5 16.4783 21.5 12 21.5C7.52166 21.5 5.28249 21.5 3.89124 20.1088C2.5 18.7175 2.5 16.4783 2.5 12Z M2.5 12H21.5 M13 7L17 7 M8.25 5.75A1.25 1.25 0 1 0 8.25 8.25A1.25 1.25 0 0 0 8.25 5.75 M8.25 15.75A1.25 1.25 0 1 0 8.25 18.25A1.25 1.25 0 0 0 8.25 15.75 M13 17L17 17"
        case .archive:
            return "M4 22V9.45584C4 6.21082 4 4.58831 4.88607 3.48933C5.06508 3.26731 5.26731 3.06508 5.48933 2.88607C6.58831 2 8.21082 2 11.4558 2C12.1614 2 12.5141 2 12.8372 2.11401C12.9044 2.13772 12.9702 2.165 13.0345 2.19575C13.3436 2.34355 13.593 2.593 14.0919 3.09188L18.8284 7.82843C19.4065 8.40649 19.6955 8.69552 19.8478 9.06306C20 9.4306 20 9.83935 20 10.6569V14C20 17.7712 20 19.6569 18.8284 20.8284C17.8971 21.7598 16.5144 21.9508 14.0919 21.9899M13 2.5V3C13 5.82843 13 7.24264 13.8787 8.12132C14.7574 9 16.1716 9 19 9H19.5 M7.5 5.5H7M10 7.5H9.5M7.5 9.5H7M10 11.5226H9.5M7.5 13.5H7 M11 22.0001V19C11 17.8954 10.1046 17 9 17C7.89543 17 7 17.8954 7 19V22.0001H11Z"
        case .audio:
            return "M20 11C20 11 20 9.4306 19.8478 9.06306C19.6955 8.69552 19.4065 8.40649 18.8284 7.82843L14.0919 3.09188C13.593 2.593 13.3436 2.34355 13.0345 2.19575C12.9702 2.165 12.9044 2.13772 12.8372 2.11401C12.5141 2 12.1614 2 11.4558 2C8.21082 2 6.58831 2 5.48933 2.88607C5.26731 3.06508 5.06508 3.26731 4.88607 3.48933C4 4.58831 4 6.21082 4 9.45584V14C4 17.7712 4 19.6569 5.17157 20.8284C6.34315 22 8.22876 22 12 22M13 2.5V3C13 5.82843 13 7.24264 13.8787 8.12132C14.7574 9 16.1716 9 19 9H19.5 M19.9998 19.4068V16.5932C19.9998 15.0206 19.9998 14.2343 19.46 14.0386C18.9201 13.843 18.2848 14.399 17.0141 15.511L16.5 16H15.0039C14.0611 16 13.5897 16 13.2968 16.2929C13.0039 16.5858 13.0039 17.0572 13.0039 18C13.0039 18.9428 13.0039 19.4142 13.2968 19.7071C13.5897 20 14.0611 20 15.0039 20H16.5L17.0141 20.489C18.2848 21.601 18.9201 22.157 19.46 21.9614C19.9998 21.7657 19.9998 20.9794 19.9998 19.4068Z"
        case .video:
            return "M19 14.0052V10.6606C19 9.84276 19 9.43383 18.8478 9.06613C18.6955 8.69843 18.4065 8.40927 17.8284 7.83096L13.0919 3.09236C12.593 2.59325 12.3436 2.3437 12.0345 2.19583C11.9702 2.16508 11.9044 2.13778 11.8372 2.11406C11.5141 2 11.1614 2 10.4558 2C7.21082 2 5.58831 2 4.48933 2.88646C4.26731 3.06554 4.06508 3.26787 3.88607 3.48998C3 4.58943 3 6.21265 3 9.45908V14.0052C3 17.7781 3 19.6645 4.17157 20.8366C5.11466 21.7801 6.52043 21.9641 9 22M12 2.50022V3.00043C12 5.83009 12 7.24492 12.8787 8.12398C13.7574 9.00304 15.1716 9.00304 18 9.00304H18.5 M18 19.5L19.4453 20.4635C20.1297 20.9198 20.4719 21.1479 20.7359 21.0066C21 20.8653 21 20.454 21 19.6315V18.3685C21 17.546 21 17.1347 20.7359 16.9934C20.4719 16.8521 20.1297 17.0802 19.4453 17.5365L18 18.5M18 19.5V18.5M18 19.5C18 20.4346 18 20.9019 17.799 21.25C17.6674 21.478 17.478 21.6674 17.25 21.799C16.9019 22 16.4346 22 15.5 22H15C13.5858 22 12.8787 22 12.4393 21.5607C12 21.1213 12 20.4142 12 19C12 17.5858 12 16.8787 12.4393 16.4393C12.8787 16 13.5858 16 15 16H15.5C16.4346 16 16.9019 16 17.25 16.201C17.478 16.3326 17.6674 16.522 17.799 16.75C18 17.0981 18 17.5654 18 18.5"
        }
    }
}

/// A vendor brand mark, stored as its official SVG path so it renders crisp at any
/// size without shipping binary image assets. Rendered in the vendor's brand color
/// by `BrandLogoShape`; see `BrandLogo.tint`. Pi and OpenCode are not here — their
/// marks ship as real favicon images via `BrandImageAsset`.
enum BrandLogo: Hashable {
    case claude
    case codex

    /// Side length of the source SVG's square viewBox (both marks use 24).
    var viewBox: CGFloat { 24 }

    /// Whether the mark's holes are cut with the even-odd fill rule. Codex's mark
    /// (from lobehub) declares `fill-rule="evenodd"` to carve the `</` and `_`
    /// glyphs out of the rounded blob; Claude's single outline needs nonzero.
    var usesEvenOddFill: Bool {
        switch self {
        case .codex: return true
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

    /// SF Symbol drawn as the status dot in the sidebar and the per-session row
    /// in the menu-bar roster.
    var symbolName: String {
        switch self {
        case .idle: return "circle.fill"
        case .working: return "circle.dotted"
        case .done: return "circle.fill"
        case .needsAttention: return "exclamationmark.circle.fill"
        }
    }
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
    /// agents that can pin their session id (Claude Code, Pi — see
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

    /// When set, this session is a **browser pane** — a WKWebView split beside the
    /// terminals (see `BrowserPaneView`) — not a terminal: no shell is spawned and
    /// no libghostty surface is created for it. Holds the pane's last URL, kept
    /// current on navigation, so a persisted browser pane restores by reloading
    /// (which is more than a shell session can say). A browser leaf stays a
    /// `Session` on purpose: the split tree, focus arrows, sidebar grouping, and
    /// close paths all key on `Session.ID`, so an orthogonal field costs nothing
    /// while a second leaf type would fork all of them.
    var browserURL: String?

    var isBrowser: Bool { browserURL != nil }

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

    /// Program passed to libghostty's `command` config; derived from `agent`.
    /// User overrides and the resume arguments are resolved in `TermioStore` via
    /// `AppSettings.command(for:)` and `AgentPreset.resumeArguments(_:)`.
    var command: String? { agent.command }

    init(title: String, agent: AgentPreset = .terminal, createdAt: Date = Date()) {
        self.title = title
        self.agent = agent
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, agent, createdAt, worktreePath, resumeID, launched, launchedAt,
             liveTitle, browserURL, lastWorkingDirectory, sshHost, pinned
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
        browserURL = try container.decodeIfPresent(String.self, forKey: .browserURL)
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
