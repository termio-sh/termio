import Foundation
import Network
import Security
import SystemConfiguration
import TermioShared

/// The shared secret a phone must present before the companion server serves
/// it anything. It rides the pairing QR as a `t` query param, so possession
/// means "was shown the Mac’s screen" — which holds up whether the socket is
/// reached over the LAN or through a public tunnel URL.
///
/// Stored in UserDefaults rather than the Keychain on purpose: the trust
/// boundary is the local user account either way (anyone who can read the
/// prefs can also screenshot the QR), and plain defaults keep `dev-run.sh`
/// able to read the token for the phone's launch argument.
enum PairingToken {
    static let defaultsKey = "companion.pairingToken"

    static var current: String {
        if let token = UserDefaults.standard.string(forKey: defaultsKey), !token.isEmpty {
            return token
        }
        return regenerate()
    }

    /// Mints a fresh token, revoking every previously paired phone.
    @discardableResult
    static func regenerate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // base64url so the token travels inside a URL query untouched.
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(token, forKey: defaultsKey)
        return token
    }
}

/// This Mac's identity on the phone's paired-Mac list: a UUID minted once and
/// kept for the install's lifetime, plus the user-facing computer name. The
/// phone keys its pairings by the UUID, so re-scanning a QR after a tunnel
/// restart updates the existing entry instead of duplicating it — the URL is
/// the one thing about a Mac that doesn't hold still.
enum MacIdentity {
    static let defaultsKey = "companion.macID"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString
        UserDefaults.standard.set(minted, forKey: defaultsKey)
        return minted
    }

    /// The computer name from Sharing settings ("Jiwei's MacBook Pro"),
    /// falling back to the DNS hostname stripped of its ".local" suffix.
    static var displayName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host
    }
}

/// The master on/off for phone access. Off is a true stop — the companion
/// server stops listening and the tunnel is torn down (nothing public remains),
/// and any live phone drops. The pairing token is left untouched, so flipping
/// it back on reconnects an already-paired phone with no new QR scan; that is
/// what separates this "disconnect for now" from `PairingToken.regenerate()`'s
/// permanent "sign every phone out". Defaults on, so existing installs are
/// unchanged. AppDelegate owns the wiring (start/stop the server + tunnel); this
/// is just the observable, persisted state the Settings toggle drives.
@MainActor
final class MobileAccess: ObservableObject {
    static let shared = MobileAccess()
    private static let defaultsKey = "companion.mobileEnabled"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
        }
    }

    private init() {
        // Absent key → on, so upgrading users keep today's always-serving behavior.
        isEnabled = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }
}

/// Which companion links are still answering, by the only signal that crosses
/// the whole path: the pong to the server's own ping.
///
/// A phone that leaves coverage or sleeps mid-session never sends a FIN, so its
/// socket stays on the books for minutes — and that is not a harmless ghost,
/// because the bridge on it still owns the PTY's winsize, leaving the Mac's own
/// window sized to a phone that is gone. Nothing underneath reports this in
/// time: TCP keepalive only proves the *next hop* answers, which over a tunnel
/// is a daemon on this very machine.
///
/// A pure value with an injected clock, because this arithmetic is the whole
/// decision to tear down a live session's bridge and deserves to be tested
/// without a socket.
struct LinkLiveness {
    /// Two and a half missed pings. Under this a phone on a slow cellular hop
    /// gets reaped mid-session; far over it, a dead phone keeps the winsize.
    static let silenceLimit: TimeInterval = 50
    /// A sweep this far behind the previous one means nobody was *reading*
    /// pongs for the gap: the receive handlers hop through the main queue, so a
    /// block there leaves proof of life sitting in a backlog rather than
    /// missing. The silence is ours, not the phones'.
    ///
    /// Measured sweep-to-sweep, which makes `silentLinks` a per-tick call by
    /// contract — sweep it on a cadence slower than this and every round looks
    /// like a stall, so nothing is ever reaped.
    static let stallGrace: TimeInterval = 5

    private var lastHeard: [ObjectIdentifier: TimeInterval] = [:]
    private var sweptAt: TimeInterval?

    /// Any frame is proof of life, and a pong counts: an attached phone that is
    /// only reading sends nothing else for minutes at a stretch.
    mutating func heard(_ id: ObjectIdentifier, at now: TimeInterval) {
        lastHeard[id] = now
    }

    mutating func forget(_ id: ObjectIdentifier) {
        lastHeard[id] = nil
    }

    mutating func forgetAll() {
        lastHeard.removeAll()
        sweptAt = nil
    }

    /// The links that have answered nothing for `silenceLimit`, and how long
    /// each has been silent. Uses a monotonic clock (`systemUptime`), so a
    /// clock change can never reap a healthy phone.
    mutating func silentLinks(at now: TimeInterval) -> [(id: ObjectIdentifier, silence: TimeInterval)] {
        defer { sweptAt = now }
        // A late sweep — the main runloop was blocked — means the pongs went
        // unheard rather than unanswered. Forgive the gap and restart every
        // clock, or one beachball reaps every phone at once.
        if let sweptAt, now - sweptAt > Self.stallGrace {
            for id in lastHeard.keys { lastHeard[id] = now }
            return []
        }
        return lastHeard.compactMap { id, heard in
            now - heard > Self.silenceLimit ? (id, now - heard) : nil
        }
    }
}

/// Serves the iOS companion app over WebSockets on one port: every connection
/// starts as a roster subscriber (the same project/session tree the sidebar
/// shows, pushed on connect and on change); a connection that sends an
/// `attach` control message becomes a PTY bridge for that session — binary
/// frames carry raw PTY bytes both ways, text frames carry `CompanionControl`.
///
/// Bound to localhost for the PoC; production fronts it with a tunnel
/// (`tunelo port <n>`), so the socket itself never listens on the public net.
@MainActor
final class CompanionServer {
    private let port: UInt16
    private let rosterProvider: () -> CompanionRoster
    /// Opens this server's *own* attachment to a session on its daemon, so a
    /// phone is a second client of the session rather than a tap on the Mac's
    /// copy of it. Nil when the session is unknown or could not be reached.
    private let attachSession: (String) -> TermiodSessionLink?
    /// Creates a session for a `start` request. A nil agent is the phone's
    /// bare New Chat — the store resolves it through the same default-agent
    /// policy as ⌘N. Returns the new session's wire id plus the agent wire id
    /// actually launched (echoed in `.started` so the phone can label the
    /// session before the next roster push), or nil when the start failed.
    /// Records a phone keystroke against the session it was typed into. The
    /// phone holds its own attachment, so nothing on the Mac's link sees this
    /// input — and the keystroke-echo guard has to, or composing on the phone
    /// reads as the agent producing output and promotes an idle row.
    private let noteInput: (String) -> Void
    private let startSession: (String, String?) -> (sessionID: String, agentID: String)?
    private let stopSession: (String) -> Bool
    /// Opens a plain shell in the loose terminals funnel for the phone's
    /// Terminals ＋ (`.startTerminal`); returns the `.started` echo, or nil on
    /// failure. Project-less: the funnel is found-or-created on the Mac, in the
    /// workspace the phone named (nil = whichever the Mac is showing).
    private let startScratchTerminal: (String?) -> (sessionID: String, agentID: String)?
    /// Opens an `ssh <host>` terminal for the phone's Terminals ＋ → SSH
    /// (`.startSSH`); returns the `.started` echo, or nil on failure.
    private let startSSHSession: (String, String?) -> (sessionID: String, agentID: String)?
    /// Called when this server will not be serving after all — the port is
    /// held by someone else, or the listener died. Set by whoever owns the
    /// wiring (`AppDelegate`), because the thing that has to be undone is the
    /// *tunnel*, and a server that cannot bind must not leave a public URL
    /// pointing at a port it does not answer on.
    var onListenerFailed: (() -> Void)?
    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private var connectionByID: [ObjectIdentifier: NWConnection] = [:]
    /// Connections that have presented the pairing token. Everyone else gets
    /// silence and a short clock: the roster names every project on this Mac
    /// and an attach is keystroke access to a shell.
    private var authenticatedWireByConnection: [ObjectIdentifier: Int] = [:]
    private var bridges: [ObjectIdentifier: SessionBridge] = [:]
    private var lastRoster: CompanionRoster?
    private var pollTimer: Timer?
    private var ticks = 0
    private var liveness = LinkLiveness()

    /// The one port everything agrees on: the app serves here, dev-run.sh
    /// points the phone here, and the Settings ▸ Mobile QR encodes it. A dev-channel
    /// build serves on 8788 (see `AppChannel`) so it can run beside a release build.
    nonisolated static var defaultPort: UInt16 { AppChannel.companionPort }

    init(
        port: UInt16 = CompanionServer.defaultPort,
        rosterProvider: @escaping () -> CompanionRoster,
        attachSession: @escaping (String) -> TermiodSessionLink?,
        noteInput: @escaping (String) -> Void,
        startSession: @escaping (String, String?) -> (sessionID: String, agentID: String)?,
        stopSession: @escaping (String) -> Bool,
        startScratchTerminal: @escaping (String?) -> (sessionID: String, agentID: String)?,
        startSSHSession: @escaping (String, String?) -> (sessionID: String, agentID: String)?
    ) {
        self.port = port
        self.rosterProvider = rosterProvider
        self.attachSession = attachSession
        self.noteInput = noteInput
        self.startSession = startSession
        self.stopSession = stopSession
        self.startScratchTerminal = startScratchTerminal
        self.startSSHSession = startSSHSession
    }

    func start() {
        let params = NWParameters.tcp
        // A dev relaunch rebinds while the old instance's sockets sit in
        // TIME_WAIT; without reuse the new listener dies silently.
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // Phone uploads (photos for prompts) arrive as one base64 text frame;
        // the default cap is too small for them.
        ws.maximumMessageSize = 16 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        guard let endpoint = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: endpoint)
        else {
            Log.companion.error("failed to bind port \(self.port, privacy: .public)")
            onListenerFailed?()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.companion.notice("listening on ws://localhost:\(self.port, privacy: .public)")
            case .failed(let error):
                // Terminal, not transient: an NWListener does not recover from
                // `.failed`, and the common cause is a second instance already
                // holding the port. Say so and take the public URL down with
                // it — the alternative is what the log caught, a tunnel
                // announcing a fresh address every few seconds for a port this
                // process never answered on.
                Log.companion.error("listener failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in self.onListenerFailed?() }
            case .waiting(let error):
                Log.companion.notice("listener waiting: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener

        // Poll the store on a light cadence and broadcast only on change; simpler
        // and race-free next to hooking every @Published property, and roster
        // churn is low. The same timer paces the keepalive pings.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tick() {
        broadcastIfChanged()
        ticks += 1
        // Active pings (autoReplyPing only answers the peer's): keeps NAT /
        // proxy mappings warm, and the pong that answers is the proof of life
        // the sweep below reads.
        if ticks % 20 == 0 {
            let meta = NWProtocolWebSocket.Metadata(opcode: .ping)
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [meta])
            for connection in connectionByID.values {
                connection.send(content: Data("hb".utf8), contentContext: context, completion: .idempotent)
            }
        }
        for (id, silence) in liveness.silentLinks(at: ProcessInfo.processInfo.systemUptime) {
            Log.companion.notice("reaping silent phone link after \(Int(silence), privacy: .public)s")
            drop(id)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        listener?.cancel()
        for bridge in bridges.values { bridge.stop() }
        bridges.removeAll()
        for connection in connectionByID.values { connection.cancel() }
        connectionByID.removeAll()
        connections.removeAll()
        authenticatedWireByConnection.removeAll()
        liveness.forgetAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections.insert(id)
        connectionByID[id] = connection
        liveness.heard(id, at: ProcessInfo.processInfo.systemUptime)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { @MainActor in self?.drop(id) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        // Nothing is sent until the client authenticates; the roster follows
        // a valid `auth` (the phone sends it the moment the socket opens, so
        // the paint is just as immediate). Unauthenticated sockets don't get
        // to linger either.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { @MainActor in
                guard let self, self.connections.contains(id),
                      self.authenticatedWireByConnection[id] == nil else { return }
                self.refuse(connection, message: "unauthorized — scan the QR code in Settings ▸ Mobile")
            }
        }
        // Keep the receive pump alive so pings/close are handled.
        receive(on: connection)
    }

    private func drop(_ id: ObjectIdentifier) {
        if let bridge = bridges[id] {
            // Detaching is the whole teardown: the size follows whichever
            // device types next, and the session belongs to the daemon.
            bridge.stop()
            bridges[id] = nil
        }
        connectionByID[id]?.cancel()
        connectionByID[id] = nil
        connections.remove(id)
        authenticatedWireByConnection[id] = nil
        liveness.forget(id)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            if error != nil {
                Task { @MainActor in self?.drop(ObjectIdentifier(connection)) }
                return
            }
            let heardAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                self?.liveness.heard(ObjectIdentifier(connection), at: heardAt)
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if let meta, let content, !content.isEmpty {
                switch meta.opcode {
                case .binary:
                    // Binary frames are raw PTY bytes permanently. Compression,
                    // encryption, or multiplexing needs a separately negotiated
                    // mechanism and Wire gate so framing can never become keystrokes.
                    // Keystrokes from the phone into the session's PTY.
                    // Typing from the phone is active use — the size follows it.
                    Task { @MainActor in
                        guard let bridge = self?.bridges[ObjectIdentifier(connection)] else { return }
                        bridge.write(content)
                    }
                case .text:
                    if let text = String(data: content, encoding: .utf8),
                       let control = CompanionControl.decode(text) {
                        Task { @MainActor in self?.handle(control, on: connection) }
                    }
                default:
                    break
                }
            }
            // Re-arm on the main actor like every other branch above: the callback
            // itself runs on the network queue, and `receive` reads main-actor state.
            Task { @MainActor in self?.receive(on: connection) }
        }
    }

    private func handle(_ control: CompanionControl, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        if case .auth(let token, let wire) = control {
            guard token == PairingToken.current else {
                refuse(connection, message: "unauthorized — re-scan the QR code on your Mac")
                return
            }
            Log.companion.notice("phone declared wire version \(wire, privacy: .public)")
            guard wire >= Wire.minimumClient else {
                refuse(connection, message: "Update Termio on your phone to connect to this Mac.")
                return
            }
            authenticatedWireByConnection[id] = wire
            send(rosterProvider(), to: connection)
            return
        }
        guard authenticatedWireByConnection[id] != nil else {
            refuse(connection, message: "unauthorized — scan the QR code in Settings ▸ Mobile")
            return
        }
        switch control {
        case .attach(let sessionID):
            guard let link = attachSession(sessionID) else {
                sendControl(.error(message: "unknown session — pull the list to refresh"), to: connection)
                return
            }
            bridges[id]?.stop()
            let bridge = SessionBridge(link: link, connection: connection)
            bridges[id] = bridge
            // The bridge owns the attachment, so replacing it retires the exit
            // handler with it: a phone that re-attaches to another session must
            // not still hear THIS session's exit — a spurious exit banner and a
            // dropped connection while it views a session that is fine.
            bridge.onInput = { [weak self] in self?.noteInput(sessionID) }
            bridge.onExit = { [weak self, weak connection] code in
                guard let connection else { return }
                Task { @MainActor in
                    self?.sendControl(.exit(code: code), to: connection)
                    self?.drop(ObjectIdentifier(connection))
                }
            }
            bridge.start()
        case .start(let projectID, let agent):
            // The phone's sidebar-equivalent "new session" — same store action
            // the CLI's spawn-on-`send` uses; the roster push announces it to
            // every other client, the reply lets this one attach immediately.
            if let started = startSession(projectID, agent) {
                sendControl(
                    .started(sessionID: started.sessionID, agent: started.agentID),
                    to: connection
                )
            } else {
                sendControl(.error(message: "could not start a session there"), to: connection)
            }
        case .startTerminal(let workspaceID):
            // "New Terminal": a plain shell in the loose terminals funnel of the
            // workspace the phone is showing, seeded on the Mac even if the
            // phone has never seen one there yet.
            if let started = startScratchTerminal(workspaceID) {
                sendControl(
                    .started(sessionID: started.sessionID, agent: started.agentID),
                    to: connection
                )
            } else {
                sendControl(.error(message: "could not open a terminal"), to: connection)
            }
        case .startSSH(let host, let workspaceID):
            // "New SSH": a terminal running `ssh <host>` in that same funnel.
            if let started = startSSHSession(host, workspaceID) {
                sendControl(
                    .started(sessionID: started.sessionID, agent: started.agentID),
                    to: connection
                )
            } else {
                sendControl(.error(message: "could not open an SSH session"), to: connection)
            }
        case .stop(let sessionID):
            // Close on the Mac; the roster push drops the row on every phone.
            if !stopSession(sessionID) {
                sendControl(.error(message: "unknown session — pull the list to refresh"), to: connection)
            }
        case .resize(let cols, let rows):
            // The phone reports its grid on attach, foreground, and layout —
            // each report claims the write token and with it the size (tmux's
            // newest-client rule; one PTY has one winsize, per-client grids
            // don't exist at this layer).
            bridges[id]?.applyClientResize(cols: cols, rows: rows)
        case .listFiles(let projectID, let path):
            handleListFiles(projectID: projectID, path: path, on: connection)
        case .readFile(let projectID, let path, let dark):
            handleReadFile(projectID: projectID, path: path, dark: dark, on: connection)
        case .writeFile(let projectID, let path, let base64, let baseMtime):
            handleWriteFile(
                projectID: projectID, path: path, base64: base64,
                baseMtime: baseMtime, on: connection
            )
        case .upload(let projectID, let name, let base64):
            handleUpload(projectID: projectID, name: name, base64: base64, on: connection)
        case .searchFiles(let projectID, let query):
            handleSearchFiles(projectID: projectID, query: query, on: connection)
        case .listChanges(let projectID):
            handleListChanges(projectID: projectID, on: connection)
        case .readDiff(let projectID, let path, let status):
            handleReadDiff(projectID: projectID, path: path, status: status, on: connection)
        case .sshConfigHosts:
            sendControl(.sshConfigList(hosts: Self.parseSSHConfigHosts()), to: connection)
        case .unsupported(let type):
            // Usually the phone speaks a newer vocabulary than this Mac, and
            // this line is the only trace of why its button did nothing. But
            // the tag is remote input — a paired phone chooses it — so it is
            // sanitized before it reaches a `.public` log field, and the line
            // states what happened rather than guessing which end is older.
            Log.companion.notice(
                "ignoring unsupported control \(Self.loggableTag(type), privacy: .public)"
            )
        case .auth, .exit, .error, .started, .fileList, .file, .written, .uploaded,
             .searchResults, .sshConfigList, .changes, .diff:
            break
        }
    }

    /// A wire tag reduced to something safe to write into a `.public` log field.
    ///
    /// The tag arrives from the phone, so it can carry newlines that forge extra
    /// log lines, or a payload long enough to bury the surrounding entries. Only
    /// the shape a real tag has survives — letters, digits, and the separators
    /// the vocabulary already uses — and only the first 40 characters of it.
    nonisolated static func loggableTag(_ tag: String) -> String {
        let kept = tag.prefix(40).map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                || character == "_" ? character : "?"
        }
        return kept.isEmpty ? "(empty)" : String(kept)
    }

    /// The Mac user's connectable `~/.ssh/config` hosts (see `SSHConfigFile`),
    /// flattened for the phone's SSH import. Keys (`IdentityFile`) are
    /// deliberately not forwarded: they live on the Mac, and a phone→server SSH
    /// authenticates with a phone-side key or password.
    nonisolated static func parseSSHConfigHosts() -> [WireSSHHost] {
        SSHConfigFile.hosts().map {
            WireSSHHost(alias: $0.alias, hostName: $0.hostName, user: $0.user, port: $0.port)
        }
    }

    // MARK: - File plane (read-only)

    /// The project root for a wire project id, straight from the roster —
    /// the same source of truth the phone's tree came from.
    private func projectRoot(for wireID: String) -> String? {
        let prefix = wireID.lowercased()
        guard !prefix.isEmpty else { return nil }
        return rosterProvider().projects
            .first { $0.id.lowercased().hasPrefix(prefix) }?.path
    }

    private func handleListFiles(projectID: String, path: String, on connection: NWConnection) {
        guard let root = projectRoot(for: projectID),
              let dir = Self.resolve(path, under: root) else {
            sendControl(.error(message: "unknown project or path"), to: connection)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = Self.listEntries(in: dir, listedPath: path, projectRoot: root)
            await MainActor.run {
                self?.sendControl(.fileList(path: path, entries: entries), to: connection)
            }
        }
    }

    private func handleSearchFiles(projectID: String, query: String, on connection: NWConnection) {
        guard let root = projectRoot(for: projectID) else {
            sendControl(.error(message: "unknown project"), to: connection)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let (paths, truncated) = Self.searchFilenames(root: root, query: query)
            await MainActor.run {
                self?.sendControl(
                    .searchResults(query: query, paths: paths, truncated: truncated),
                    to: connection
                )
            }
        }
    }

    nonisolated private static let maxSearchResults = 200

    /// Repo-wide filename search: enumerate the project once, then substring-
    /// match by name. The enumeration prefers git's index (`ls-files` — it
    /// respects `.gitignore` and includes new files for free) and falls back
    /// to a pruned filesystem walk for non-git projects.
    nonisolated private static func searchFilenames(root: String, query: String) -> (paths: [String], truncated: Bool) {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return ([], false) }
        let all = gitTrackedPaths(root: root) ?? walkedPaths(root: root)
        var matches: [String] = []
        for path in all where (path as NSString).lastPathComponent.lowercased().contains(needle) {
            matches.append(path)
            if matches.count >= maxSearchResults { return (matches, true) }
        }
        return (matches, false)
    }

    /// Every file git knows about that isn't ignored — tracked plus untracked-
    /// but-not-ignored, so brand-new files still surface. `nil` when this isn't
    /// a git repo (git exits non-zero), signalling the caller to walk instead.
    nonisolated private static func gitTrackedPaths(root: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        process.environment = GitEnvironment.optionalLocksDisabled
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return raw.split(separator: "\0").map(String.init)
    }

    /// Build/vendor directories a bare filesystem walk must skip so a non-git
    /// project's search doesn't drown in generated artifacts.
    nonisolated private static let searchPruneDirs: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData",
        ".next", "dist", "Pods", ".venv", "venv", "__pycache__", ".swiftpm",
    ]

    /// Filesystem fallback for non-git projects: a recursive walk yielding repo-
    /// relative file paths, pruning the heavy directories above and bounded so a
    /// pathological tree can't stall the connection.
    nonisolated private static func walkedPaths(root: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            if searchPruneDirs.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            let full = url.standardizedFileURL.path
            if full.hasPrefix(root + "/") {
                paths.append(String(full.dropFirst(root.count + 1)))
            }
            if paths.count > 20_000 { break }
        }
        return paths
    }

    private func handleReadFile(projectID: String, path: String, dark: Bool, on connection: NWConnection) {
        guard let root = projectRoot(for: projectID),
              let url = Self.resolve(path, under: root) else {
            sendControl(.error(message: "unknown project or path"), to: connection)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let reply: CompanionControl
            if let file = Self.readFilePayload(at: url, path: path, dark: dark) {
                reply = .file(file)
            } else {
                reply = .error(message: "could not read \(path)")
            }
            await MainActor.run { self?.sendControl(reply, to: connection) }
        }
    }

    private func handleWriteFile(
        projectID: String, path: String, base64: String, baseMtime: Int,
        on connection: NWConnection
    ) {
        guard let root = projectRoot(for: projectID),
              let url = Self.resolve(path, under: root) else {
            sendControl(.error(message: "unknown project or path"), to: connection)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let reply = Self.performWrite(at: url, path: path, base64: base64, baseMtime: baseMtime)
            await MainActor.run { self?.sendControl(reply, to: connection) }
        }
    }

    /// Lands a phone attachment under `<project>/.termio/uploads/` and
    /// replies with the absolute path, ready to paste into a prompt. The
    /// timestamp prefix keeps repeated picks of the same photo distinct.
    private func handleUpload(
        projectID: String, name: String, base64: String, on connection: NWConnection
    ) {
        guard let root = projectRoot(for: projectID) else {
            sendControl(.error(message: "unknown project"), to: connection)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let reply: CompanionControl
            if let data = Data(base64Encoded: base64), !data.isEmpty {
                let safeName = (name as NSString).lastPathComponent
                    .replacingOccurrences(of: " ", with: "-")
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let dir = URL(fileURLWithPath: root)
                    .appendingPathComponent(".termio/uploads", isDirectory: true)
                let url = dir.appendingPathComponent(
                    "\(formatter.string(from: Date()))-\(safeName)"
                )
                do {
                    try FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true
                    )
                    try data.write(to: url, options: .atomic)
                    reply = .uploaded(path: url.path)
                } catch {
                    reply = .error(message: "upload failed: \(error.localizedDescription)")
                }
            } else {
                reply = .error(message: "bad upload payload")
            }
            await MainActor.run { self?.sendControl(reply, to: connection) }
        }
    }

    /// Writes edited bytes back — to existing regular files only (editing,
    /// never creating), atomically, and only if the file hasn't moved on
    /// since the client read it. The agent may write the same file mid-edit;
    /// the mtime check turns that race into an explicit conflict instead of
    /// a silent clobber.
    nonisolated private static func performWrite(
        at url: URL, path: String, base64: String, baseMtime: Int
    ) -> CompanionControl {
        guard let data = Data(base64Encoded: base64) else {
            return .error(message: "bad write payload for \(path)")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return .error(message: "no such file — \(path)")
        }
        if baseMtime != 0, mtimeMillis(url) != baseMtime {
            return .error(message: "conflict: \(path) changed on the Mac")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .error(message: "write failed: \(error.localizedDescription)")
        }
        return .written(path: path, mtime: mtimeMillis(url))
    }

    nonisolated private static func mtimeMillis(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = attributes?[.modificationDate] as? Date
        return Int((date?.timeIntervalSince1970 ?? 0) * 1000)
    }

    /// Resolves a relative wire path against a project root, refusing anything
    /// that escapes it (absolute paths, `..`, symlinks out of the tree). Both
    /// sides are realpath'd — project roots often sit behind `/private`.
    nonisolated private static func resolve(_ relative: String, under root: String) -> URL? {
        guard !relative.hasPrefix("/") else { return nil }
        let rootReal = URL(fileURLWithPath: root).standardizedFileURL
            .resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: rootReal)
            .appendingPathComponent(relative).standardizedFileURL
            .resolvingSymlinksInPath().path
        guard candidate == rootReal || candidate.hasPrefix(rootReal + "/") else { return nil }
        return URL(fileURLWithPath: candidate)
    }

    /// One directory's entries: directories first, then names; `.git` hidden;
    /// `changed` marks files the working diff touches (and the directories
    /// containing them), so the phone's tree shows the same dots the desktop's.
    nonisolated private static func listEntries(in dir: URL, listedPath: String, projectRoot: String) -> [WireFileEntry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let changedPaths = gitChangedPaths(root: projectRoot)
        return contents
            .compactMap { url -> WireFileEntry? in
                let name = url.lastPathComponent
                guard name != ".git" else { return nil }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let relative = listedPath.isEmpty ? name : "\(listedPath)/\(name)"
                let changed = isDir
                    ? changedPaths.contains { $0.hasPrefix(relative + "/") }
                    : changedPaths.contains(relative)
                return WireFileEntry(name: name, isDir: isDir, changed: changed)
            }
            .sorted {
                if $0.isDir != $1.isDir { return $0.isDir }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Repo-relative paths of files the working tree touches. `--no-renames`
    /// keeps every record a plain `XY path`, so parsing stays trivial.
    nonisolated private static func gitChangedPaths(root: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain", "--no-renames", "-z", "--untracked-files=all"]
        process.environment = GitEnvironment.optionalLocksDisabled
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8) else { return [] }
        return Set(raw.split(separator: "\0").compactMap { record in
            record.count > 3 ? String(record.dropFirst(3)) : nil
        })
    }

    // MARK: - Changes plane (git working tree)

    /// The project's working-tree changes, straight from the same `GitService` the
    /// desktop git pane reads — the phone never shells out to git itself, so the two
    /// lists can't disagree about what "changed" means.
    private func handleListChanges(projectID: String, on connection: NWConnection) {
        guard let root = projectRoot(for: projectID) else {
            sendControl(.error(message: "unknown project"), to: connection)
            return
        }
        // Detached like every other handler here: `CompanionServer` is main-actor, and a
        // repo-wide status walk has no business on the UI thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            let files = await GitService.changes(in: root).map {
                WireChange(
                    path: $0.path, status: $0.status.letter,
                    additions: $0.additions, deletions: $0.deletions,
                    isBinary: $0.isBinary, isStaged: $0.isStaged
                )
            }
            await MainActor.run { self?.sendControl(.changes(files: files), to: connection) }
        }
    }

    /// One changed file's diff. The request carries the status the phone read off the
    /// listing, so this costs one git invocation rather than a second whole-repo scan
    /// per tap — and per step of the reader's file walker.
    ///
    /// Rows come back with *full* file context so the phone can fold unchanged runs into
    /// bands the reader expands; past the byte cap the reassembled text would be a
    /// multi-megabyte frame, so that case degrades to git's default 3-line context.
    private func handleReadDiff(
        projectID: String, path: String, status: String, on connection: NWConnection
    ) {
        guard let root = projectRoot(for: projectID) else {
            sendControl(.error(message: "unknown project"), to: connection)
            return
        }
        let change = GitChange(
            path: path,
            status: GitFileStatus(code: status.first ?? "M"),
            isUntracked: status == "U"
        )
        Task.detached(priority: .userInitiated) { [weak self] in
            let full = Self.unifiedText(await GitService.diffRows(for: change, in: root))
            let text = full.utf8.count <= Self.maxDiffBytes
                ? full : await GitService.diffText(for: change, in: root)
            // git answers a binary file with its own one-line note rather than a diff;
            // the reader says so instead of rendering that note as code.
            let binary = text.contains("Binary files ")
            let reply = CompanionControl.diff(
                WireDiff(path: path, text: binary ? "" : text, binary: binary)
            )
            await MainActor.run { self?.sendControl(reply, to: connection) }
        }
    }

    /// 2 MB of diff text — ~50k lines of source, well inside the socket's 8 MB frame
    /// cap and past anything a phone reader can usefully scroll.
    nonisolated private static let maxDiffBytes = 2 << 20

    /// Reassembles parsed rows into unified-diff text for the wire. The phone re-parses
    /// with the same rules (`DiffParser`), so the round trip is lossless for everything
    /// it renders; only the file-header plumbing the parser already drops is gone.
    /// (Once `GitService` exposes its full-context text directly — it is private today,
    /// and that file belongs to another change in flight — this detour goes away.)
    nonisolated static func unifiedText(_ rows: [DiffRow]) -> String {
        rows.map { row in
            switch row.kind {
            case .hunk: return row.text
            case .addition: return "+" + row.text
            case .deletion: return "-" + row.text
            case .context: return " " + row.text
            }
        }.joined(separator: "\n")
    }

    nonisolated private static let maxFileBytes = 1 << 20 // 1 MB — plenty for "peek at a source file"

    nonisolated private static func readFilePayload(at url: URL, path: String, dark: Bool = false) -> WireFile? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard var data = try? handle.read(upToCount: maxFileBytes) ?? Data() else { return nil }
        let size = max(attributes?[.size] as? Int ?? 0, data.count)
        let truncated = size > data.count
        // NUL in the head or undecodable UTF-8 → treat as binary (Quick Look).
        var binary = data.prefix(8192).contains(0)
        if !binary, truncated {
            // A cap cut can split a UTF-8 sequence; trim the partial tail
            // before judging decodability.
            while let last = data.last, last & 0b1100_0000 == 0b1000_0000 {
                data.removeLast()
            }
        }
        if !binary, String(data: data, encoding: .utf8) == nil {
            binary = true
        }
        return WireFile(
            path: path,
            base64: data.base64EncodedString(),
            size: size,
            binary: binary,
            truncated: truncated,
            mtime: mtimeMillis(url),
            html: markdownPreviewHTML(for: data, path: path, binary: binary, truncated: truncated, dark: dark)
        )
    }

    /// The phone's Markdown preview, rendered Mac-side with the same reader
    /// pipeline as the desktop editor's Preview pane (one
    /// renderer, the phone only supplies its light/dark trait). Fonts are not
    /// embedded — the phone falls through to its system stack instead of
    /// paying ~230KB of woff2 CSS per file read. nil for anything that is not
    /// a complete, decodable Markdown document.
    nonisolated private static func markdownPreviewHTML(
        for data: Data, path: String, binary: Bool, truncated: Bool, dark: Bool
    ) -> String? {
        guard !binary, !truncated,
              ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()),
              let source = String(data: data, encoding: .utf8)
        else { return nil }
        return MarkdownReaderRenderer.document(
            source, theme: DocumentTheme.builtin(dark: dark), fontFamily: "", embedFonts: false
        )
    }

    /// Sends a last control frame, then drops the connection only after the
    /// frame has been handed to the transport — a plain send-then-cancel
    /// loses that race and the phone sees a dead socket instead of the reason.
    private func refuse(_ connection: NWConnection, message: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "control", metadata: [meta])
        connection.send(
            content: Data(CompanionControl.error(message: message).encoded().utf8),
            contentContext: context,
            completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in self?.drop(ObjectIdentifier(connection)) }
            }
        )
    }

    private func sendControl(_ control: CompanionControl, to connection: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "control", metadata: [meta])
        connection.send(
            content: Data(control.encoded().utf8),
            contentContext: context,
            completion: .idempotent
        )
    }

    private func broadcastIfChanged() {
        guard !connectionByID.isEmpty else { return }
        let roster = rosterProvider()
        guard roster != lastRoster else { return }
        lastRoster = roster
        // Bridged connections are a byte stream now; roster frames would only
        // interleave with PTY traffic for no benefit. Unauthenticated ones
        // get nothing at all.
        for (id, connection) in connectionByID
        where bridges[id] == nil && authenticatedWireByConnection[id] != nil {
            send(roster, to: connection)
        }
    }

    private func send(_ roster: CompanionRoster, to connection: NWConnection) {
        lastRoster = roster
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "roster", metadata: [meta])
        connection.send(
            content: Data(roster.encodedJSON().utf8),
            contentContext: context,
            completion: .idempotent
        )
    }
}
// MARK: - Session bridge

/// One phone ↔ one attachment on the session's daemon.
///
/// The phone is a second client of the same session, not a tap on the Mac's
/// copy of it: the daemon fans bytes out to every attachment, so nothing here
/// has to reach into the Mac's terminal. That is what lets a slow phone fall
/// behind without stalling the Mac — if the socket is more than `highWater`
/// behind, frames are dropped and the daemon's own resync repaints once the
/// pipe drains.
///
/// Three things this used to do by hand are now the attach itself. The daemon
/// renders its snapshot at *this client's* grid, so there is no replay of the
/// Mac-width ring to cap, no reflow spike to dodge, and no mode preamble to
/// re-assert — a snapshot carries modes, charsets and the scrolling region.
/// Not private: `write` is the one path by which a phone's keystrokes reach the
/// session's input clock, and a test that cannot construct a bridge can only
/// check that the store's own method works — which proves nothing about whether
/// anything calls it.
final class SessionBridge: @unchecked Sendable {
    let link: TermiodSessionLink
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "termio.companion.bridge")
    private let lock = NSLock()
    private var pendingBytes = 0
    private var behind = false
    private static let highWater = 1 << 20   // start dropping above 1 MB in flight
    private static let lowWater = 128 << 10  // recovered once under 128 KB

    /// Called when the session ends, so the server can tell the phone and drop
    /// the connection. Set by the attach handler, which owns the server.
    var onExit: ((Int32) -> Void)?
    /// Called for every keystroke this phone sends, so the store can stamp the
    /// session. Set by the attach handler alongside `onExit`.
    var onInput: (() -> Void)?

    init(link: TermiodSessionLink, connection: NWConnection) {
        self.link = link
        self.connection = connection
    }

    func start() {
        link.onOutput = { [weak self] data in
            self?.queue.async { self?.send(data) }
        }
        link.onExit = { [weak self] status, _, _ in
            self?.onExit?(status)
        }
        link.start()
    }

    /// Keystrokes from the phone. The link claims the write token on the way
    /// through, so a phone typing takes the session back from the Mac the same
    /// way the Mac takes it back by typing.
    func write(_ data: Data) {
        link.send(data)
        onInput?()
    }

    /// A resize control from this client. Sizing is the writer's to set, and on
    /// this path the grid report *is* the claim: the phone sends one when it
    /// opens a session, comes back to that screen, or rotates — every one of
    /// them the user arriving at this session on this device. Attaching used to
    /// take the token by itself, which read the same for a phone opening one
    /// session and for a Mac window quietly holding fifteen, and let the phone
    /// pull the shared PTY down to its width behind the Mac's back.
    ///
    /// The claim lands first and the grid follows it: `resize` records the size
    /// whether or not this attachment can send it yet, and the grant re-asserts
    /// it. So the daemon adopts this grid and answers with a keyframe rendered
    /// for it — but only once the user has actually shown up here.
    func applyClientResize(cols: Int, rows: Int) {
        link.claimWriter()
        link.resize(rows: rows, cols: cols)
    }

    func stop() {
        link.onOutput = nil
        link.onExit = nil
        onExit = nil
        onInput = nil
        // Detach, never kill: the session belongs to the daemon and outlives
        // every viewer of it, which is the whole point of it living there.
        link.detach()
    }

    private func send(_ data: Data) {
        lock.lock()
        if pendingBytes > Self.highWater {
            behind = true
            lock.unlock()
            return
        }
        pendingBytes += data.count
        lock.unlock()
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "pty", metadata: [meta])
        connection.send(
            content: data,
            contentContext: context,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                lock.lock()
                pendingBytes -= data.count
                let recovered = behind && pendingBytes < Self.lowWater
                if recovered { behind = false }
                lock.unlock()
                if recovered {
                    // The dropped frames tore escape sequences mid-stream. Ask
                    // the daemon for a fresh screen rather than wiping and
                    // hoping: it holds the authoritative grid and can redraw
                    // this client's exact viewport.
                    link.requestResync()
                }
            }
        )
    }
}

// MARK: - Store → PTY attach

extension TermioStore {
    /// Stamps a phone keystroke against the session it was typed into. The
    /// phone attaches separately from the Mac, so this is the only route by
    /// which its input reaches the keystroke-echo guard.
    func noteCompanionInput(_ wireID: String) {
        guard let session = findCompanionSession(wireID) else { return }
        noteUserInput(session.id, at: Date())
    }

    /// A phone's own attachment to a session on its daemon. If the session was
    /// never shown on the Mac (surfaces are made lazily on first render),
    /// surface it first — that spawns the agent with its recorded resume
    /// arguments, so the phone wakes the same conversation instead of being
    /// told "no terminal". `wireID` is a full session UUID or the CLI's
    /// 8-char prefix.
    ///
    /// The link returned is the phone's alone. The daemon fans the session's
    /// bytes out to every attachment, so a viewer on the phone costs one more
    /// client rather than a tap on the Mac's own stream — and the two can hold
    /// different grids, with the write token following whoever types.
    func companionAttachment(for wireID: String) -> TermiodSessionLink? {
        guard let session = findCompanionSession(wireID) else { return nil }
        // Attaching from the phone is the mobile equivalent of selecting the
        // session in the desktop sidebar: the user is now looking at the prompt,
        // so a resting "needs you" / unseen "done" marker has been acknowledged.
        // Without this, permission prompts answered through the raw PTY can stay
        // orange forever because menu keystrokes don't necessarily produce a new
        // agent hook event to overwrite the old attention state. Routed through
        // `markSeen` so the Mac's delivered task banner is withdrawn too.
        markSeen(session.id)
        // A deliberate attach from the phone, like desktop selection — float it now.
        if let project = project(for: session.id) { noteProjectActivity(project.id, force: true) }
        // Surfacing is what guarantees the session exists on the daemon; the
        // attach below then resolves it by name rather than creating a second.
        _ = surface(for: session)
        // The Mac's own link existing is what proves the session is on the
        // daemon. The spec below is therefore never used to create anything —
        // `attach` resolves the name first — so it carries nothing.
        guard termiodLinks[session.id] != nil else { return nil }
        return makeTermiodLink(for: session, argv: [], cwd: "", env: [:])
    }

    /// Create a session in a project for a phone `start` request — the same
    /// `addSession` the sidebar buttons and the CLI use. Returns the new
    /// session's wire id plus the launched agent's wire id (the `.started`
    /// echo), nil if the project is unknown or no agent could be resolved.
    func companionStartSession(
        projectID wireID: String, agent wireAgent: String?
    ) -> (sessionID: String, agentID: String)? {
        // An agent-less start is the phone's bare New Chat (the Chats tab's ＋
        // tap). The default-agent habit lives on the Mac only: resolve exactly
        // the way ⌘N does (pinned → last used → first enabled, see
        // `defaultChatAgent`), and land in the scratch chats container —
        // `addScratchSession` finds or creates it by kind, so the phone's
        // projectID (its view of that container) is deliberately not needed.
        // Going through `addScratchSession` also feeds `lastChatAgentID`, so
        // the phone and ⌘N keep sharing one habit. nil when every agent is
        // disabled — the caller answers with the standard start error.
        guard let wireAgent else {
            guard let preset = defaultChatAgent() else { return nil }
            addScratchSession(agent: preset)
            guard let sessionID = selectedSessionID?.uuidString else { return nil }
            return (sessionID, preset.wireName)
        }
        let prefix = wireID.lowercased()
        guard !prefix.isEmpty else { return nil }
        // Reverse of `wireAgent`: resolve the phone's token back to a definition by
        // its wire name (so user agents, whose wire name is their id, resolve too);
        // an unknown token falls back to a plain terminal.
        let preset = AgentPreset.allCases.first { $0.wireName == wireAgent } ?? .terminal
        if let project = projects.first(where: { $0.id.uuidString.lowercased().hasPrefix(prefix) }) {
            addSession(to: project.id, agent: preset)
        } else if let workspace = workspaces.first(where: {
            // A loose section's wire id is its workspace's uuid plus a suffix, and
            // which of the two sections the row lands in follows from the agent —
            // so only the workspace half has to match.
            prefix.hasPrefix($0.id.uuidString.lowercased())
        }) {
            // A loose section, not a folder: the phone's ＋ on the Terminals or
            // Chats card. Move into that workspace first so the row lands where
            // the phone is looking rather than wherever the Mac was left.
            switchToWorkspace(workspace.id)
            addScratchSession(agent: preset)
        } else {
            return nil
        }
        guard let sessionID = selectedSessionID?.uuidString else { return nil }
        return (sessionID, preset.wireName)
    }

    /// Open a plain login shell in the loose `.terminals` funnel for the phone's
    /// Terminals-tab ＋ → "New Terminal" (`.startTerminal`). Unlike `.start` this
    /// carries no project: `addScratchSession` finds-or-creates the funnel by
    /// kind, so the phone can seed the very first terminal too. Returns the new
    /// session's wire id and the `"terminal"` echo.
    ///
    /// `workspaceID` is the workspace the phone user is looking at. There is one
    /// funnel per workspace, so without it the destination would be whichever
    /// workspace this Mac happens to be showing — a decision taken on a screen
    /// the phone user cannot see. An older phone sends none and keeps that
    /// behaviour.
    func companionStartScratchTerminal(
        workspaceID: String?
    ) -> (sessionID: String, agentID: String)? {
        // Switching, not filing directly: `addScratchSession` files against the
        // current workspace, so moving there first is what makes the row land
        // where the phone said — the same move `companionStartSession` makes for
        // a loose-section start. A shell that runs here still cannot be filed
        // under a workspace on a box, and `addScratchSession` keeps that rule.
        if let workspace = companionWorkspace(workspaceID) {
            switchToWorkspace(workspace.id)
        }
        addScratchSession(agent: .terminal)
        guard let sessionID = selectedSessionID?.uuidString else { return nil }
        return (sessionID, AgentPreset.terminal.wireName)
    }

    /// Open an SSH terminal to `host` for the phone's Terminals-tab ＋ → "New
    /// SSH" (`.startSSH`) — the same `addSSHSession` the desktop's SSH picker
    /// uses. It lands in the `.terminals` funnel too, so it needs no project.
    /// Returns the new session's wire id and the `"terminal"` echo.
    ///
    /// `workspaceID` is a preference here rather than a destination: an `ssh`
    /// shell has to be filed under a workspace on the box it reaches, or that
    /// workspace claims a machine it isn't on. It settles which of that box's
    /// workspaces when there is more than one, and is ignored otherwise.
    func companionStartSSHSession(
        host: String, workspaceID: String?
    ) -> (sessionID: String, agentID: String)? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let preferred = companionWorkspace(workspaceID)
            .flatMap { $0.isOn(alias: host, device: nil) ? $0.id : nil }
        addSSHSession(host: host, preferring: preferred)
        guard let sessionID = selectedSessionID?.uuidString else { return nil }
        return (sessionID, AgentPreset.terminal.wireName)
    }

    /// The workspace a phone request names, by the uuid the roster gave it. nil
    /// for an absent id (an older phone), and for one naming a workspace that is
    /// gone — both mean "this Mac decides", the behaviour that predates the field.
    private func companionWorkspace(_ wireID: String?) -> Workspace? {
        guard let wireID else { return nil }
        return workspaces.first { $0.id.uuidString.caseInsensitiveCompare(wireID) == .orderedSame }
    }

    /// Close a session for a phone `stop` request — the same `closeSession`
    /// the sidebar and CLI use. Returns false if the id matches nothing.
    func companionStopSession(sessionID wireID: String) -> Bool {
        guard let session = findCompanionSession(wireID) else { return false }
        closeSession(session.id)
        return true
    }

    private func findCompanionSession(_ wireID: String) -> Session? {
        let prefix = wireID.lowercased()
        guard !prefix.isEmpty else { return nil }
        return allSessions.first { $0.id.uuidString.lowercased().hasPrefix(prefix) }
    }
}

// MARK: - Store → roster

extension TermioStore {
    /// One session on the wire, as the sidebar shows it: the display title, the
    /// live agent status, and the tooltip's activity line — which doubles as the
    /// phone's row preview, empty meaning "nothing to say".
    private func rosterSession(_ session: Session) -> RosterSession {
        let activity = statusDescription(for: session.id)
        return RosterSession(
            id: session.id.uuidString,
            title: displayTitle(for: session),
            agent: Self.wireAgent(session.agent),
            status: Self.wireStatus(status(for: session.id)),
            subtitle: activity.isEmpty ? nil : activity,
            // Worktree sessions ride the project's flat roster, so the checkout's
            // branch is the phone's only clue that a row lives off the main one.
            branch: session.worktreePath.flatMap { branch(forFolder: $0) }
        )
    }

    /// The wire id for a workspace's loose section. The format is the protocol's
    /// (`Wire.looseSectionID`), because the phone builds the same id to address a
    /// section this Mac has not created yet.
    static func looseWireID(workspace: Workspace, chats: Bool) -> String {
        Wire.looseSectionID(workspaceID: workspace.id.uuidString, chats: chats)
    }

    /// Snapshot the current projects/sessions as a wire roster, mirroring what
    /// the sidebar renders (display titles, live agent status).
    func companionRoster() -> CompanionRoster {
        // The roster stays one flat list of containers, but each one names the
        // workspace it belongs to and the machine that workspace is on, so the
        // phone can group by workspace instead of pouring every machine's
        // checkouts into a single column. Containers are emitted workspace by
        // workspace, in sidebar order, so the pushed order is already the
        // grouping order.
        var projects: [RosterProject] = []
        for workspace in workspaces {
            let alias = workspace.deviceAlias
            if !workspace.terminals.isEmpty {
                projects.append(RosterProject(
                    id: Self.looseWireID(workspace: workspace, chats: false),
                    name: "Terminals",
                    path: Self.looseTerminalRoot,
                    workspaceID: workspace.id.uuidString,
                    workspaceName: workspace.name,
                    deviceAlias: alias,
                    kind: "terminals",
                    sessions: workspace.terminals.map(rosterSession)))
            }
            if !workspace.chats.isEmpty {
                projects.append(RosterProject(
                    id: Self.looseWireID(workspace: workspace, chats: true),
                    name: "Chats",
                    path: Self.looseChatRoot,
                    workspaceID: workspace.id.uuidString,
                    workspaceName: workspace.name,
                    deviceAlias: alias,
                    kind: "chats",
                    sessions: workspace.chats.map(rosterSession)))
            }
            projects += self.projects(inWorkspace: workspace.id).map { project in
                RosterProject(
                    id: project.id.uuidString,
                    name: project.name,
                    path: project.path,
                    workspaceID: workspace.id.uuidString,
                    workspaceName: workspace.name,
                    deviceAlias: alias,
                    // "—" is the desktop's own no-branch placeholder; the wire
                    // says empty so the phone has one thing to test.
                    branch: Self.wireBranch(branchModel.branch(for: project.path) ?? project.branch),
                    kind: "folder",
                    sessions: project.sessions.map(rosterSession)
                )
            }
        }
        // The phone's new-session menu mirrors the desktop's enabled agents,
        // in preset order — the same filter the sidebar's quick-add row uses.
        let agents = AgentPreset.allCases
            .filter(settings.isAgentEnabled)
            .map {
                RosterAgent(
                    id: Self.wireAgent($0),
                    name: $0.displayName,
                    tintHex: $0.tintHex,
                    icon: $0.iconRef)
            }
        return CompanionRoster(
            projects: projects, agents: agents,
            macID: MacIdentity.id, macName: MacIdentity.displayName
        )
    }

    private static func wireAgent(_ agent: AgentPreset) -> String {
        agent.wireName
    }

    /// A checkout's branch as the wire says it: the name, or empty for a folder
    /// that is not a repo. "—" is a glyph the sidebar draws in an empty column,
    /// not a branch, and it has no business crossing to another app.
    private static func wireBranch(_ branch: String) -> String {
        branch == "—" ? "" : branch
    }

    private static func wireStatus(_ status: SessionStatus) -> String {
        switch status {
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .needsAttention: "needsAttention"
        }
    }
}
