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
    /// The project+agent of an in-flight `start`, so the `.started` reply
    /// knows what to open.
    private var pendingStart: (project: MockProject, agent: RosterAgent)?
    private var pairingObserver: NSObjectProtocol?

    /// Every session currently blocked on the user, across all projects, in
    /// roster order — the root page's "Needs You" strip.
    var attentionSessions: [MockSession] {
        projects.flatMap(\.sessions).filter { $0.status == .needsAttention }
    }

    /// The live project for a stable key (path, falling back to name — see
    /// `MockProject.stableKey`), or nil once the Mac closes it.
    func project(forKey key: String) -> MockProject? {
        projects.first { $0.stableKey == key }
    }

    func start() {
        connectIfConfigured()
        // The Connectivity settings page edits the pairing; the socket's
        // owner follows it.
        pairingObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.pairingDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let url = CompanionLink.savedURL {
                    self.client?.stop()
                    self.client = nil
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
        let saved = CompanionLink.savedURL?.absoluteString
        guard let urlString = arg ?? saved, let url = URL(string: urlString) else { return }
        connect(to: url)
    }

    /// Open (or replace) the app's single Mac link: one socket, whole roster.
    private func connect(to url: URL) {
        companionURL = url
        CompanionLink.state = .connecting
        let client = CompanionClient(url: url)
        client.onConnected = { connected in
            CompanionLink.state = connected ? .connected : .connecting
        }
        client.onRoster = { [weak self] roster in
            guard let self else { return }
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
        client.onStarted = { [weak self] sessionID in
            self?.openStartedSession(sessionID)
        }
        client.onError = { [weak self] reason in
            guard let self, pendingStart != nil else { return }
            pendingStart = nil
            onStartError?(reason)
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
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The Mac created the session; open it attached, like tapping its row.
    private func openStartedSession(_ sessionID: String) {
        guard let pending = pendingStart else { return }
        pendingStart = nil
        let session = MockSession(
            title: pending.agent.name,
            project: pending.project.name,
            agent: pending.agent,
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
