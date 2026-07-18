import SwiftUI
import TermioShared
import UIKit

struct MockSession: Identifiable {
    let id = UUID()
    let title: String
    let project: String
    let agent: AgentKind
    let status: SessionStatus
    let subtitle: String
    let time: String
    /// The Mac session's wire id when this row came from the live roster —
    /// what `attach` sends to bridge the real PTY. nil for bundled mock rows.
    var rosterID: String?
    /// The Mac project's wire id — what the file plane (`listFiles`/`readFile`)
    /// scopes requests to. nil for bundled mock rows.
    var projectRosterID: String?
    /// The project's absolute path on the Mac — the root the file tree's
    /// relative paths hang off, so "Copy Path" can hand back a full path.
    var projectPath: String?
    /// The project's current git branch (nil for non-repos / mock rows).
    var branch: String?

    static let samples: [MockSession] = [
        .init(title: "fix-sidebar", project: "termio", agent: .claude,
              status: .needsAttention, subtitle: "Allow running npm install?", time: "2m"),
        .init(title: "landing-hero", project: "termio", agent: .claude,
              status: .working, subtitle: "Editing hero.tsx…", time: "5m"),
        .init(title: "info-pane", project: "termio", agent: .codex,
              status: .done, subtitle: "Done · 3 files changed", time: "1h"),
        .init(title: "kanban-drag", project: "vibewizard", agent: .claude,
              status: .working, subtitle: "Running swift build…", time: "12m"),
        .init(title: "release-notes", project: "termio", agent: .opencode,
              status: .idle, subtitle: "Waiting for input", time: "3h"),
    ]
}

/// A project (an opened folder), the first-level page — mirroring the desktop
/// sidebar's project → session hierarchy as list → sub-list.
struct MockProject: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    /// The Mac project's wire id when this came from the live roster — what
    /// `start` sends to create a session there. nil for bundled mock data.
    var rosterID: String?
    /// Current git branch of the checkout (nil for non-repos / mock data).
    var branch: String?
    let sessions: [MockSession]

    /// Projects keep their order; within a project, attention floats up.
    static let samples: [MockProject] = {
        var order: [String] = []
        var byProject: [String: [MockSession]] = [:]
        for session in MockSession.samples {
            if byProject[session.project] == nil { order.append(session.project) }
            byProject[session.project, default: []].append(session)
        }
        return order.map { name in
            MockProject(
                name: name,
                path: "~/Documents/GitHub/\(name)",
                sessions: byProject[name]!.sorted { $0.status.rank < $1.status.rank }
            )
        }
    }()
}

extension MockSession {
    /// Stable identity across roster refreshes (the `id` UUID is rebuilt on
    /// every push) — what the sidebar uses to highlight the open session.
    var key: String { rosterID ?? "\(project)/\(title)" }
}

// MARK: - Roster → model mapping

extension AgentKind {
    /// Map a wire agent string (`RosterSession.agent`) to an icon kind.
    init(wire: String) {
        switch wire {
        case "claude": self = .claude
        case "codex": self = .codex
        case "opencode": self = .opencode
        case "pi": self = .pi
        case "amp": self = .amp
        case "cursor": self = .cursor
        case "kimi": self = .kimi
        case "antigravity": self = .antigravity
        case "hermes": self = .hermes
        case "grok": self = .grok
        default: self = .terminal
        }
    }
}

extension IconRef {
    /// The agent's real brand mark as a `UIImage`, for UIKit spots (UIMenu
    /// rows) that can't host the SwiftUI `AgentIconView` the session rows use —
    /// so the menus show the same marks as the macOS sidebar, not SF Symbol
    /// stand-ins. Claude's orange and the favicon tiles keep their own colors
    /// via `.alwaysOriginal`; the monochrome vector marks render as templates
    /// so the menu tints them with the current label color.
    @MainActor
    func menuIcon(pointSize: CGFloat = 18) -> UIImage? {
        let isTemplate = asset == nil && png == nil && vector?.lowercased() != "claude"
        let mark = AgentIconView(ref: self, size: pointSize, tint: .black)
        let renderer = ImageRenderer(content: mark.frame(width: pointSize, height: pointSize))
        renderer.scale = 3
        guard let image = renderer.uiImage else { return nil }
        return image.withRenderingMode(isTemplate ? .alwaysTemplate : .alwaysOriginal)
    }
}

extension SessionStatus {
    /// Map a wire status string (`RosterSession.status`) to a status.
    init(wire: String) {
        switch wire {
        case "working": self = .working
        case "done": self = .done
        case "needsAttention": self = .needsAttention
        default: self = .idle
        }
    }
}

extension MockSession {
    init(roster: RosterSession, project: RosterProject) {
        // "—" is the desktop's placeholder for "no branch"; drop it here.
        let branch = project.branch.flatMap { $0 == "—" || $0.isEmpty ? nil : $0 }
        self.init(
            title: roster.title,
            project: project.name,
            agent: AgentKind(wire: roster.agent),
            status: SessionStatus(wire: roster.status),
            subtitle: roster.subtitle ?? "",
            time: "",
            rosterID: roster.id,
            projectRosterID: project.id,
            projectPath: project.path,
            branch: branch
        )
    }
}

extension MockProject {
    init(roster: RosterProject) {
        self.init(
            name: roster.name,
            path: roster.path,
            rosterID: roster.id,
            branch: roster.branch.flatMap { $0 == "—" || $0.isEmpty ? nil : $0 },
            sessions: roster.sessions.map { MockSession(roster: $0, project: roster) }
        )
    }
}

// MARK: - Mock file tree

final class FileNode {
    let name: String
    let children: [FileNode]?
    let changed: Bool
    var isExpanded: Bool

    var isDirectory: Bool { children != nil }

    init(_ name: String, changed: Bool = false, expanded: Bool = false, children: [FileNode]? = nil) {
        self.name = name
        self.changed = changed
        self.children = children
        isExpanded = expanded
    }

    static let sampleRoot: [FileNode] = [
        FileNode("Sources", expanded: true, children: [
            FileNode("termio", expanded: true, children: [
                FileNode("App.swift", changed: true),
                FileNode("Models.swift"),
                FileNode("SessionInfoView.swift", changed: true),
                FileNode("TermioStore", children: [
                    FileNode("TermioStore.swift"),
                    FileNode("TermioStore+TerminalSurface.swift", changed: true),
                    FileNode("TermioStore+AgentStatus.swift"),
                ]),
            ]),
        ]),
        FileNode("web", children: [
            FileNode("landing", children: [
                FileNode("src", children: [
                    FileNode("app", children: [FileNode("page.tsx")]),
                ]),
            ]),
        ]),
        FileNode("Package.swift"),
        FileNode("README.md"),
    ]

    /// Flattens the tree into visible rows (respecting collapsed dirs).
    static func visibleRows(from roots: [FileNode], depth: Int = 0) -> [(node: FileNode, depth: Int)] {
        var rows: [(FileNode, Int)] = []
        for node in roots {
            rows.append((node, depth))
            if node.isDirectory, node.isExpanded, let children = node.children {
                rows.append(contentsOf: visibleRows(from: children, depth: depth + 1))
            }
        }
        return rows
    }
}

// MARK: - Mock changes

struct MockChange {
    let kind: String // "M" / "A" / "D"
    let path: String
    let additions: Int
    let deletions: Int

    static let samples: [MockChange] = [
        .init(kind: "M", path: "Sources/termio/App.swift", additions: 40, deletions: 12),
        .init(kind: "M", path: "Sources/termio/SessionInfoView.swift", additions: 18, deletions: 3),
        .init(kind: "M", path: "Sources/termio/TermioStore/TermioStore+TerminalSurface.swift", additions: 62, deletions: 41),
        .init(kind: "A", path: "Sources/termio/SessionHost.swift", additions: 120, deletions: 0),
    ]

    static let sampleDiff = """
    @@ -41,7 +41,9 @@ func makeContentSplitViewController() {
         let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarVC)
         sidebar.minimumThickness = 220
    -    window.styleMask.insert(.fullSizeContentView)
    +    sidebar.titlebarSeparatorStyle = .automatic
    +    window.titlebarAppearsTransparent = true
    +    window.styleMask.insert(.fullSizeContentView)
         splitViewController.addSplitViewItem(sidebar)

    @@ -88,6 +90,12 @@ func applyTheme(_ theme: TerminalTheme) {
         controller.setTheme(theme)
    +    // Resolve the dynamic color statically: fullscreen windows on
    +    // macOS 26 do not re-evaluate NSColor appearance providers.
    +    let resolved = theme.background.resolvedColor(for: window)
    +    window.backgroundColor = resolved
         inspector.refresh()
     }
    """
}

// MARK: - Cross-screen notifications

extension Notification.Name {
    /// Posted by the sidebar on every roster push. `userInfo["statuses"]` is
    /// `[String: SessionStatus]` keyed by roster session id — how an open
    /// terminal tracks its session's live status without owning the socket.
    static let sessionStatusesDidChange = Notification.Name("SessionStatusesDidChange")
}

// MARK: - Companion link state

/// The app-wide view of the single Mac roster link. The sidebar owns the
/// socket and keeps `state` current; other screens (the Connectivity settings
/// page, the sidebar's presence dot) observe `stateDidChange` and read it.
enum CompanionLink {
    enum State {
        /// No Mac address saved.
        case unpaired
        /// Paired, but the socket is down — connecting or in backoff retry.
        case connecting
        case connected
    }

    static var state: State = .unpaired {
        didSet {
            guard state != oldValue else { return }
            NotificationCenter.default.post(name: stateDidChange, object: nil)
        }
    }

    static let stateDidChange = Notification.Name("CompanionLinkStateDidChange")
    /// Posted when a screen other than the sidebar changes the pairing (the
    /// Connectivity page's connect/forget); the sidebar reacts by reconnecting
    /// to `savedURL` or tearing the link down.
    static let pairingDidChange = Notification.Name("CompanionPairingDidChange")

    static let defaultsKey = "companion.rosterURL"

    static var savedURL: URL? {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(URL.init(string:))
    }

    /// Bare-host shorthand: "studio.local" → ws://studio.local:8787. Tunnel
    /// addresses often get pasted with their http(s) scheme; the socket wants
    /// ws(s), same host, same everything else.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var full = trimmed.contains("://") ? trimmed : "ws://\(trimmed):8787"
        if full.hasPrefix("https://") {
            full = "wss://" + full.dropFirst("https://".count)
        } else if full.hasPrefix("http://") {
            full = "ws://" + full.dropFirst("http://".count)
        }
        return URL(string: full)
    }

    /// The pairing token riding the paired URL's `t` query param — sent as
    /// the first frame on every companion socket; the Mac serves nothing
    /// without it.
    static func token(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "t" }?.value
    }
}
