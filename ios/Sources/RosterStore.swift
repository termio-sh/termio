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
    private(set) var sshHosts: [DeviceSSHHost] = []
    private(set) var companionURL: URL?
    /// `MockSession.key` of the session filling the screen — its row gets the
    /// current-chat pill wherever session rows render.
    var currentSessionKey: String?
    /// The workspace the phone is working in: the one holding the session last
    /// opened, or the one picked in the ＋ menu. See `destinationWorkspace`,
    /// which resolves it against the live roster.
    private var destinationWorkspaceID: String?

    /// Open a session's terminal; `companionURL` is non-nil when it's live.
    /// Fired for row taps (via `openSession`) and for `.started` replies.
    var onOpenSession: ((MockSession, URL?) -> Void)?
    /// A `start` failed on the Mac; the shell presents the alert.
    var onStartError: ((String) -> Void)?

    private var client: DeviceClient?
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

    /// The Chats tab's sections: one per workspace that has loose agent
    /// sessions, in the Mac's push order. Grouped rather than flattened for the
    /// same reason the Projects list is — two paired machines' loose sessions
    /// are otherwise one undifferentiated list.
    var chatGroups: [WorkspaceGroup] {
        WorkspaceGroup.grouped(projects.filter { $0.kind == "chats" })
    }

    /// The Terminals tab's sections, the shell twin of `chatGroups`.
    var terminalGroups: [WorkspaceGroup] {
        WorkspaceGroup.grouped(projects.filter { $0.kind == "terminals" })
    }

    /// Every workspace on the roster, in the Mac's push order — what the ＋
    /// destination is picked from.
    var workspaceGroups: [WorkspaceGroup] {
        WorkspaceGroup.grouped(projects)
    }

    /// The workspace the phone is working in: the one holding the session last
    /// opened, or the one picked in the ＋. The Mac resolves the loose funnels
    /// per workspace, so without an answer here every phone-started session
    /// would land wherever the Mac's own window is pointed — a choice made on a
    /// screen the phone user cannot see.
    var currentWorkspace: WorkspaceGroup? {
        let groups = workspaceGroups
        return groups.first { $0.id == destinationWorkspaceID } ?? groups.first
    }

    /// Where a session the phone starts *here* lands — a plain shell or a chat,
    /// both of which run on the Mac. Only a workspace on the Mac itself
    /// qualifies: one on a box would be claiming a machine the process isn't on,
    /// and the Mac files it locally regardless, so offering one would promise
    /// what it will not do. nil when the roster has no local workspace yet,
    /// which leaves the choice to the Mac.
    var destinationWorkspace: WorkspaceGroup? {
        let local = localWorkspaces
        return local.first { $0.id == currentWorkspace?.id } ?? local.first
    }

    /// The workspaces on the paired Mac itself — what ＋ can offer as a
    /// destination (see `destinationWorkspace`).
    var localWorkspaces: [WorkspaceGroup] {
        workspaceGroups.filter { $0.deviceAlias == nil }
    }

    /// The Mac's loose-agent-sessions container in the destination workspace —
    /// the target a phone-started chat lands in. A workspace with no chats yet
    /// gets a stand-in addressed by `Wire.looseSectionID`, so the phone can seed
    /// the first chat there the way `.startTerminal` seeds the first terminal;
    /// the Mac finds-or-creates the section behind that id. nil only when no
    /// local workspace exists to land in.
    var chatsProject: MockProject? {
        guard let workspace = destinationWorkspace else { return nil }
        if let existing = workspace.projects.first(where: { $0.kind == "chats" }) { return existing }
        return MockProject(
            name: localized("Chats"),
            path: "",
            rosterID: Wire.looseSectionID(workspaceID: workspace.id, chats: true),
            kind: "chats",
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            sessions: []
        )
    }

    /// The Mac's loose-terminals container in the destination workspace, the
    /// shell twin of `chatsProject`. Only ever the optimistic row's stand-in:
    /// `.startTerminal` names the workspace itself and needs no container.
    private var terminalsProject: MockProject? {
        guard let workspace = destinationWorkspace else { return nil }
        return workspace.projects.first { $0.kind == "terminals" }
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
    /// Opening one is also how the phone says which workspace it is working in,
    /// so the next ＋ starts alongside what the user was just looking at.
    func openSession(_ session: MockSession) {
        if let workspaceID = workspaceID(of: session) { destinationWorkspaceID = workspaceID }
        onOpenSession?(session, companionURL)
    }

    /// Point the ＋ at another workspace (its "Start in" pick).
    func chooseDestinationWorkspace(_ id: String) {
        destinationWorkspaceID = id
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The workspace a session is filed under, via the container it belongs to.
    /// A session carries its container's wire id, and the container names the
    /// workspace — the roster's own chain, so nothing is inferred here.
    private func workspaceID(of session: MockSession) -> String? {
        guard let projectRosterID = session.projectRosterID else { return nil }
        return projects.first { $0.rosterID == projectRosterID }?.workspaceID
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

    /// The ＋'s "Start in" section: one entry per workspace a phone-started
    /// session can land in, checkmarked on the destination. An inline section
    /// rather than a sheet — changing where the next session goes is one tap,
    /// and never a picker standing in front of the thing the user asked for.
    /// nil when there is one workspace, which is not a choice.
    func destinationPickerMenu() -> UIMenu? {
        let workspaces = localWorkspaces
        guard workspaces.count > 1 else { return nil }
        let destination = destinationWorkspace?.id
        return UIMenu(
            title: localized("Start in"),
            options: .displayInline,
            children: workspaces.map { workspace in
                UIAction(
                    title: workspace.name,
                    state: workspace.id == destination ? .on : .off
                ) { [weak self] _ in self?.chooseDestinationWorkspace(workspace.id) }
            }
        )
    }

    func startSession(agent: RosterAgent, in project: MockProject) {
        guard let projectID = project.rosterID else { return }
        pendingStart = (project, agent)
        client?.startSession(projectID: projectID, agentID: agent.id)
    }

    /// The Terminals tab's ＋ → "New Terminal": a plain login shell in the Mac's
    /// loose `.terminals` funnel. Project-less on the wire (`.startTerminal`), so
    /// — unlike the old `.start` path — it can seed the very first terminal too,
    /// no container need pre-exist. It carries the destination workspace instead,
    /// because there is one funnel per workspace. Opens attached on the
    /// `.started` echo, so a placeholder stands in until the roster push carries
    /// the real container.
    func startNewTerminal() {
        pendingStart = (terminalsProject ?? .terminalsPlaceholder, nil)
        client?.startTerminal(workspaceID: destinationWorkspace?.id)
    }

    /// The Terminals tab's ＋ → "New SSH": an `ssh <host>` terminal in that same
    /// funnel. `host` is always a `~/.ssh/config` alias the Mac handed us (see
    /// `sshHosts`) — the phone only picks a host the Mac already knows, it never
    /// authors one. Lands project-less like New Terminal.
    func startSSH(host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        pendingStart = (terminalsProject ?? .terminalsPlaceholder, nil)
        // The raw current workspace, not the local destination: an `ssh` shell
        // is filed on the box it reaches, so the workspace worth naming is the
        // one the user is looking at even when that one is over there.
        client?.startSSH(host: host, workspaceID: currentWorkspace?.id)
    }

    /// Close on the Mac; the next roster push drops the row everywhere.
    func stopSession(_ sessionID: String) {
        client?.stopSession(id: sessionID)
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
        let client = CompanionBackend(url: url)
        client.onConnected = { [weak self] connected in
            CompanionLink.state = connected ? .connected : .connecting
            // Refresh the SSH host list on every (re)connect so New SSH reflects
            // the Mac's current ~/.ssh/config without a manual pull.
            if connected { self?.client?.requestSSHHosts() }
        }
        client.onSSHHosts = { [weak self] hosts in
            guard let self else { return }
            sshHosts = hosts
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        client.onRoster = { [weak self] roster in
            guard let self else { return }
            // The roster names its Mac; key the pairing list by that identity
            // (first roster after a fresh pairing, or a rename on the Mac).
            if connectionIsPersisted, let deviceID = roster.deviceID {
                CompanionLink.adoptIdentity(macID: deviceID, name: roster.deviceName)
            }
            enabledAgents = roster.agents
            projects = roster.projects
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            // Open terminals track their session's live status from here —
            // the roster socket is the app's only status feed.
            let statuses = Dictionary(
                roster.projects.flatMap { project in
                    project.sessions.compactMap { session in
                        session.rosterID.map { ($0, session.status) }
                    }
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
