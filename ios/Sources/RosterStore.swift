import TermioShared
import UIKit

/// The app's single source of truth for the Mac roster: owns the companion
/// socket, the decoded project list, and the enabled-agent list, and fans
/// changes out to every screen that renders them (the Projects root, a pushed
/// project page). Extracted from the old inbox controller when the home
/// screen split into Projects → project, so both levels read one live model
/// instead of one screen owning the socket.
@MainActor
final class RosterStore {
    /// Posted after every roster change (a push, a disconnect, a demo load).
    /// Screens reload their tables on it; no payload — read the store.
    static let didChange = Notification.Name("RosterStoreDidChange")

    /// Live roster from the Mac when a companion URL is configured. Empty when
    /// unpaired/connecting — zero states fill the screens instead of fake
    /// rows. The bundled mock only appears under `-demo` (screenshots / tests).
    private(set) var projects: [MockProject] = []
    /// The agents the Mac has enabled in Settings ▸ Agents, pushed on the
    /// roster. New-session menus mirror this so the phone never offers an
    /// agent the desktop has turned off.
    private(set) var enabledAgents: [RosterAgent] = []
    /// The Mac's `~/.ssh/config` host aliases, requested on connect. The
    /// Terminals ＋ → New SSH menu is a read-only pick from these — the phone
    /// never types a host, it only chooses one the Mac already knows (the SSH
    /// twin of Projects ＋ reopening a known folder). Empty until the Mac
    /// answers, or when the config has no hosts.
    private(set) var sshHosts: [WireSSHHost] = []
    private(set) var companionURL: URL?
    /// `MockSession.key` of the session filling the screen — its row gets the
    /// current-chat pill wherever session rows render.
    var currentSessionKey: String?

    /// Open a session's terminal; `companionURL` is non-nil when it's live.
    /// Fired for row taps (via `openSession`) and for `.started` replies.
    var onOpenSession: ((MockSession, URL?) -> Void)?
    /// A `start` failed on the Mac; the shell presents the alert.
    var onStartError: ((String) -> Void)?

    private var client: CompanionClient?
    /// True when the current connection came from the paired-Mac list (not a
    /// `-roster-url` dev launch arg) — only then may a roster's identity be
    /// adopted into that list.
    private var connectionIsPersisted = false
    /// The project+agent of an in-flight `start`, so the `.started` reply
    /// knows what to open. `agent` is nil for a bare New Chat — the Mac picks
    /// one and echoes it back in `.started`.
    private var pendingStart: (project: MockProject, agent: RosterAgent?)?
    private var pairingObserver: NSObjectProtocol?

    /// Every session currently blocked on the user, across all projects, in
    /// roster order — the root page's "Needs You" strip.
    var attentionSessions: [MockSession] {
        projects.flatMap(\.sessions).filter { $0.status == .needsAttention }
    }

    /// The Mac's loose-agent-sessions container — the Chats tab's backing
    /// project (and the target a phone-started chat lands in). nil when
    /// paired to an older Mac that doesn't send project kinds.
    var chatsProject: MockProject? {
        projects.first { $0.kind == "chats" }
    }

    /// The Chats tab's rows, flat and in roster order.
    var chatSessions: [MockSession] {
        projects.filter { $0.kind == "chats" }.flatMap(\.sessions)
    }

    /// The Mac's loose-terminals container — the Terminals tab's backing
    /// project (and the target a phone-started terminal lands in). The shell
    /// twin of `chatsProject`; nil until the Mac has opened a loose shell.
    var terminalsProject: MockProject? {
        projects.first { $0.kind == "terminals" }
    }

    /// The Terminals tab's rows, flat and in roster order.
    var terminalSessions: [MockSession] {
        projects.filter { $0.kind == "terminals" }.flatMap(\.sessions)
    }

    /// The live project for a stable key (path, falling back to name — see
    /// `MockProject.stableKey`), or nil once the Mac closes it.
    func project(forKey key: String) -> MockProject? {
        projects.first { $0.stableKey == key }
    }

    func start() {
        connectIfConfigured()
        // The Devices settings page edits the pairing; the socket's
        // owner follows it.
        pairingObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.pairingDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let url = CompanionLink.savedURL {
                    self.client?.stop()
                    self.client = nil
                    // Switching Macs must not leave the old Mac's projects on
                    // screen while the new socket dials.
                    self.projects = []
                    self.enabledAgents = []
                    self.sshHosts = []
                    NotificationCenter.default.post(name: Self.didChange, object: nil)
                    self.connect(to: url)
                } else {
                    self.disconnect()
                }
            }
        }
    }

    /// Row tap on any screen: open the session over whatever link we have.
    func openSession(_ session: MockSession) {
        onOpenSession?(session, companionURL)
    }

    /// Force an immediate reconnect (the zero state's "Try Again").
    func reconnectNow() {
        if let client {
            client.reconnectNow()
        } else if let url = CompanionLink.savedURL {
            connect(to: url)
        }
    }

    // MARK: - New / close session

    /// The "new session" actions for a project, one per agent the Mac has left
    /// enabled — driving the ＋ menus. Falls back to a built-in list until the
    /// roster's agent list arrives (or when paired to an older Mac).
    func newSessionActions(in project: MockProject) -> [UIAction] {
        let agents = enabledAgents.isEmpty ? RosterAgent.legacyDefaults : enabledAgents
        return agents.map { agent in
            UIAction(
                title: agent.name,
                image: agent.iconRef.menuIcon()
            ) { [weak self] _ in
                self?.startSession(agent: agent, in: project)
            }
        }
    }

    func startSession(agent: RosterAgent, in project: MockProject) {
        guard let projectID = project.rosterID else { return }
        pendingStart = (project, agent)
        client?.send(.start(projectID: projectID, agent: agent.id))
    }

    /// The Terminals tab's ＋: open a plain login shell at `~` in the loose
    /// `.terminals` funnel. The wire agent token `"terminal"` maps to the Mac's
    /// The Terminals tab's ＋ → "New Terminal": a plain login shell in the Mac's
    /// loose `.terminals` funnel. Project-less on the wire (`.startTerminal`), so
    /// — unlike the old `.start` path — it can seed the very first terminal too,
    /// no container need pre-exist. Opens attached on the `.started` echo, so a
    /// placeholder stands in until the roster push carries the real container.
    func startNewTerminal() {
        pendingStart = (terminalsProject ?? .terminalsPlaceholder, nil)
        client?.send(.startTerminal)
    }

    /// The Terminals tab's ＋ → "New SSH": an `ssh <host>` terminal in that same
    /// funnel. `host` is always a `~/.ssh/config` alias the Mac handed us (see
    /// `sshHosts`) — the phone only picks a host the Mac already knows, it never
    /// authors one. Lands project-less like New Terminal.
    func startSSH(host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        pendingStart = (terminalsProject ?? .terminalsPlaceholder, nil)
        client?.send(.startSSH(host: host))
    }

    /// Close on the Mac; the next roster push drops the row everywhere.
    func stopSession(_ sessionID: String) {
        client?.send(.stop(sessionID: sessionID))
    }

    // MARK: - Socket

    /// A companion roster URL comes from a launch arg (`-roster-url ws://…`) or
    /// UserDefaults; when present the store carries the Mac's live roster.
    private func connectIfConfigured() {
        // Demo modes (UI tests, screenshots) are hermetic: they show the
        // bundled mock roster, not whatever Mac this device paired with last.
        // This is the ONLY path that surfaces the sample sessions.
        guard !ProcessInfo.processInfo.arguments.contains("-demo") else {
            projects = MockProject.samples
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        }
        let arg = ProcessInfo.processInfo.arguments
            .firstIndex(of: "-roster-url")
            .flatMap { idx -> String? in
                let next = idx + 1
                return ProcessInfo.processInfo.arguments.indices.contains(next)
                    ? ProcessInfo.processInfo.arguments[next] : nil
            }
        if let arg, let url = URL(string: arg) {
            connect(to: url, persisted: false)
            return
        }
        guard let url = CompanionLink.savedURL else { return }
        connect(to: url)
    }

    /// Open (or replace) the link to the active Mac: one socket, whole roster.
    private func connect(to url: URL, persisted: Bool = true) {
        connectionIsPersisted = persisted
        companionURL = url
        CompanionLink.state = .connecting
        let client = CompanionClient(url: url)
        client.onConnected = { [weak self] connected in
            CompanionLink.state = connected ? .connected : .connecting
            // Refresh the SSH host list on every (re)connect so New SSH reflects
            // the Mac's current ~/.ssh/config without a manual pull.
            if connected { self?.client?.send(.sshConfigHosts) }
        }
        client.onSSHConfig = { [weak self] hosts in
            guard let self else { return }
            sshHosts = hosts
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        client.onRoster = { [weak self] roster in
            guard let self else { return }
            // The roster names its Mac; key the pairing list by that identity
            // (first roster after a fresh pairing, or a rename on the Mac).
            if connectionIsPersisted, let macID = roster.macID {
                CompanionLink.adoptIdentity(macID: macID, name: roster.macName)
            }
            enabledAgents = roster.agents
            let agentsByID = Dictionary(
                roster.agents.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest })
            projects = roster.projects.map {
                MockProject(roster: $0, agentsByID: agentsByID)
            }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            // Open terminals track their session's live status from here —
            // the roster socket is the app's only status feed.
            let statuses = Dictionary(
                roster.projects.flatMap { project in
                    project.sessions.map { ($0.id, SessionStatus(wire: $0.status)) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            NotificationCenter.default.post(
                name: .sessionStatusesDidChange, object: nil,
                userInfo: ["statuses": statuses]
            )
        }
        client.onStarted = { [weak self] sessionID, agentID in
            self?.openStartedSession(sessionID, agentID: agentID)
        }
        client.onError = { [weak self] reason in
            guard let self, pendingStart != nil else { return }
            pendingStart = nil
            onStartError?(reason)
        }
        client.onConnectionFailure = { [weak self] reason in
            guard let self else { return }
            // A refusal closes the socket immediately; stop the reconnect loop
            // so its next optimistic open cannot erase the reason from the UI.
            self.client?.stop()
            projects = []
            enabledAgents = []
            sshHosts = []
            CompanionLink.state = .failed(reason)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        client.start()
        self.client = client
    }

    /// Forget-Mac teardown: no roster, so the unpaired zero state takes over.
    private func disconnect() {
        client?.stop()
        client = nil
        companionURL = nil
        CompanionLink.state = .unpaired
        projects = []
        enabledAgents = []
        sshHosts = []
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The Mac created the session; open it attached, like tapping its row.
    /// `agentID` is the `.started` echo of what the Mac launched — it wins
    /// over the agent we asked for (for a bare New Chat we asked for none),
    /// falling back to the request's agent against an older Mac that doesn't
    /// echo. The synthesized row is a placeholder for the terminal header
    /// only; the next roster push carries the real one.
    private func openStartedSession(_ sessionID: String, agentID: String?) {
        guard let pending = pendingStart else { return }
        pendingStart = nil
        let agent = agentID.map { id in
            enabledAgents.first { $0.id == id } ?? RosterAgent.fallback(wire: id)
        } ?? pending.agent ?? .terminal
        let session = MockSession(
            title: agent.name,
            project: pending.project.name,
            agent: agent,
            status: .idle,
            subtitle: "", time: "",
            rosterID: sessionID,
            projectRosterID: pending.project.rosterID,
            projectPath: pending.project.path,
            branch: pending.project.branch
        )
        onOpenSession?(session, companionURL)
    }
}

extension MockProject {
    /// Stable identity across roster pushes (the Mac's `rosterID` churns on
    /// rebuild): path, with name as the fallback for the path-less mock.
    var stableKey: String { path.isEmpty ? name : path }
}
