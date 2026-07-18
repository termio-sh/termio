import Foundation
import Network
import Security
import TermioShared

/// The shared secret a phone must present before the companion server serves
/// it anything. It rides the pairing QR as a `t` query param, so possession
/// means "was shown the Mac's screen" — which holds up whether the socket is
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
    private let ptyForSession: (String) -> PTYProcess?
    private let startSession: (String, String) -> String?
    private let stopSession: (String) -> Bool
    /// Resolves a session's transcript path and display title for a `trace`
    /// request, or nil when the session has no readable transcript yet.
    private let traceProvider: (String) -> (path: String, title: String)?
    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private var connectionByID: [ObjectIdentifier: NWConnection] = [:]
    /// Connections that have presented the pairing token. Everyone else gets
    /// silence and a short clock: the roster names every project on this Mac
    /// and an attach is keystroke access to a shell.
    private var authed: Set<ObjectIdentifier> = []
    private var bridges: [ObjectIdentifier: PTYBridge] = [:]
    private var lastRoster: CompanionRoster?
    private var pollTimer: Timer?
    private var ticks = 0

    /// The one port everything agrees on: the app serves here, dev-run.sh
    /// points the phone here, and the Settings ▸ Mobile QR encodes it. A dev-channel
    /// build serves on 8788 (see `AppChannel`) so it can run beside a release build.
    nonisolated static var defaultPort: UInt16 { AppChannel.companionPort }

    init(
        port: UInt16 = CompanionServer.defaultPort,
        rosterProvider: @escaping () -> CompanionRoster,
        ptyForSession: @escaping (String) -> PTYProcess?,
        startSession: @escaping (String, String) -> String?,
        stopSession: @escaping (String) -> Bool,
        traceProvider: @escaping (String) -> (path: String, title: String)?
    ) {
        self.port = port
        self.rosterProvider = rosterProvider
        self.ptyForSession = ptyForSession
        self.startSession = startSession
        self.stopSession = stopSession
        self.traceProvider = traceProvider
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

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            Log.companion.error("failed to bind port \(self.port, privacy: .public)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.companion.notice("listening on ws://localhost:\(self.port, privacy: .public)")
            case .failed(let error):
                Log.companion.error("listener failed: \(error.localizedDescription, privacy: .public)")
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
        // proxy mappings warm and surfaces half-dead links within ~20s.
        if ticks % 20 == 0 {
            let meta = NWProtocolWebSocket.Metadata(opcode: .ping)
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [meta])
            for connection in connectionByID.values {
                connection.send(content: Data("hb".utf8), contentContext: context, completion: .idempotent)
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        listener?.cancel()
        for bridge in bridges.values {
            bridge.stop()
            bridge.pty.claimHostOwnership()
        }
        bridges.removeAll()
        for connection in connectionByID.values { connection.cancel() }
        connectionByID.removeAll()
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections.insert(id)
        connectionByID[id] = connection
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
                guard let self, self.connections.contains(id), !self.authed.contains(id) else { return }
                self.refuse(connection, message: "unauthorized — scan the QR code in Settings ▸ Mobile")
            }
        }
        // Keep the receive pump alive so pings/close are handled.
        receive(on: connection)
    }

    private func drop(_ id: ObjectIdentifier) {
        if let bridge = bridges[id] {
            bridge.stop()
            bridges[id] = nil
            // The last phone detached: hand the winsize back to the Mac.
            if !bridges.values.contains(where: { $0.pty === bridge.pty }) {
                bridge.pty.claimHostOwnership()
            }
        }
        connectionByID[id]?.cancel()
        connectionByID[id] = nil
        connections.remove(id)
        authed.remove(id)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            if error != nil {
                Task { @MainActor in self?.drop(ObjectIdentifier(connection)) }
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if let meta, let content, !content.isEmpty {
                switch meta.opcode {
                case .binary:
                    // Keystrokes from the phone into the session's PTY.
                    // Typing from the phone is active use — the size follows it.
                    Task { @MainActor in
                        guard let bridge = self?.bridges[ObjectIdentifier(connection)] else { return }
                        bridge.pty.claimCompanionOwnership()
                        bridge.pty.write(content)
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
            self?.receive(on: connection)
        }
    }

    private func handle(_ control: CompanionControl, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        if case .auth(let token) = control {
            guard token == PairingToken.current else {
                refuse(connection, message: "unauthorized — re-scan the QR code on your Mac")
                return
            }
            authed.insert(id)
            send(rosterProvider(), to: connection)
            return
        }
        guard authed.contains(id) else {
            refuse(connection, message: "unauthorized — scan the QR code in Settings ▸ Mobile")
            return
        }
        switch control {
        case .attach(let sessionID):
            guard let pty = ptyForSession(sessionID) else {
                sendControl(.error(message: "unknown session — pull the list to refresh"), to: connection)
                return
            }
            bridges[id]?.stop()
            let bridge = PTYBridge(pty: pty, connection: connection)
            bridges[id] = bridge
            bridge.start()
            pty.addExitObserver { [weak self, weak connection] code in
                guard let connection else { return }
                Task { @MainActor in
                    self?.sendControl(.exit(code: code), to: connection)
                    self?.drop(ObjectIdentifier(connection))
                }
            }
        case .start(let projectID, let agent):
            // The phone's sidebar-equivalent "new session" — same store action
            // the CLI's `sessions start` uses; the roster push announces it to
            // every other client, the reply lets this one attach immediately.
            if let sessionID = startSession(projectID, agent) {
                sendControl(.started(sessionID: sessionID), to: connection)
            } else {
                sendControl(.error(message: "could not start a session there"), to: connection)
            }
        case .stop(let sessionID):
            // Close on the Mac; the roster push drops the row on every phone.
            if !stopSession(sessionID) {
                sendControl(.error(message: "unknown session — pull the list to refresh"), to: connection)
            }
        case .resize(let cols, let rows):
            // The phone reports its grid on attach, foreground, and layout —
            // each report claims the size (tmux's newest-client rule; one PTY
            // has one winsize, per-client grids don't exist at this layer).
            bridges[id]?.applyClientResize(cols: cols, rows: rows)
        case .listFiles(let projectID, let path):
            handleListFiles(projectID: projectID, path: path, on: connection)
        case .readFile(let projectID, let path):
            handleReadFile(projectID: projectID, path: path, on: connection)
        case .writeFile(let projectID, let path, let base64, let baseMtime):
            handleWriteFile(
                projectID: projectID, path: path, base64: base64,
                baseMtime: baseMtime, on: connection
            )
        case .upload(let projectID, let name, let base64):
            handleUpload(projectID: projectID, name: name, base64: base64, on: connection)
        case .searchFiles(let projectID, let query):
            handleSearchFiles(projectID: projectID, query: query, on: connection)
        case .trace(let sessionID, let dark):
            handleTrace(sessionID: sessionID, dark: dark, on: connection)
        case .sshConfigHosts:
            sendControl(.sshConfigList(hosts: Self.parseSSHConfigHosts()), to: connection)
        case .auth, .exit, .error, .started, .fileList, .file, .written, .uploaded,
             .searchResults, .traceHTML, .sshConfigList:
            break
        }
    }

    /// Read the Mac user's `~/.ssh/config` and flatten its concrete `Host`
    /// blocks for the phone's SSH import. Wildcard patterns (`Host *`, globs)
    /// are skipped — they're defaults, not connectable destinations. Keys
    /// (`IdentityFile`) are deliberately not forwarded: they live on the Mac,
    /// and a phone→server SSH authenticates with a phone-side key or password.
    nonisolated static func parseSSHConfigHosts() -> [WireSSHHost] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }

        var hosts: [WireSSHHost] = []
        var aliases: [String] = []
        var hostName = "", user = "", port = 22

        func flush() {
            for alias in aliases where !alias.contains("*") && !alias.contains("?") {
                hosts.append(WireSSHHost(
                    alias: alias, hostName: hostName.isEmpty ? alias : hostName,
                    user: user, port: port
                ))
            }
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // `Keyword value…` — the keyword match is case-insensitive per ssh_config(5).
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                .map(String.init).filter { !$0.isEmpty }
            guard let keyword = parts.first?.lowercased() else { continue }
            let values = Array(parts.dropFirst())
            switch keyword {
            case "host":
                flush()
                aliases = values
                hostName = ""; user = ""; port = 22
            case "hostname": hostName = values.first ?? ""
            case "user": user = values.first ?? ""
            case "port": port = values.first.flatMap(Int.init) ?? 22
            default: break
            }
        }
        flush()
        return hosts
    }

    /// Render a session's agent transcript to the same HTML trace the desktop
    /// Info pane shows, and hand it back over the socket. The heavy lifting is
    /// `SessionTraceRenderer` (shared with the Mac UI); the phone supplies only
    /// its light/dark trait so the page matches its appearance.
    ///
    /// Failures ride back as a `traceHTML` placeholder page, never a `.error`
    /// frame: this connection is also the session's PTY bridge, and the phone
    /// treats any `.error` there as a fatal drop of the live terminal.
    private func handleTrace(sessionID: String, dark: Bool, on connection: NWConnection) {
        let theme = TraceTheme.builtin(dark: dark)
        let html: String
        if let (path, title) = traceProvider(sessionID),
           let rendered = try? SessionTraceRenderer.html(jsonlPath: path, title: title, theme: theme) {
            html = rendered
        } else {
            html = SessionTraceRenderer.placeholder(
                message: "No transcript yet for this session.", theme: theme
            )
        }
        sendControl(.traceHTML(sessionID: sessionID, html: html), to: connection)
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

    private func handleReadFile(projectID: String, path: String, on connection: NWConnection) {
        guard let root = projectRoot(for: projectID),
              let url = Self.resolve(path, under: root) else {
            sendControl(.error(message: "unknown project or path"), to: connection)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let reply: CompanionControl
            if let file = Self.readFilePayload(at: url, path: path) {
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

    nonisolated private static let maxFileBytes = 1 << 20 // 1 MB — plenty for "peek at a source file"

    nonisolated private static func readFilePayload(at url: URL, path: String) -> WireFile? {
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
            mtime: mtimeMillis(url)
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
        where bridges[id] == nil && authed.contains(id) {
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

// MARK: - PTY bridge

/// One phone ↔ one session PTY. Output is tapped via a PTYProcess sink on a
/// private serial queue, so a slow phone can never stall the Mac's terminal;
/// if the socket falls more than `highWater` behind, frames are dropped and a
/// resize jiggle repaints the screen once the pipe drains (catch-up snapshot,
/// not a minutes-long fast-forward).
private final class PTYBridge: @unchecked Sendable {
    let pty: PTYProcess
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "termio.companion.bridge")
    private var sinkToken: UUID?
    private var resizeToken: UUID?
    private let lock = NSLock()
    private var pendingBytes = 0
    private var behind = false
    private var clientCols = 0
    private var clientRows = 0
    /// The PTY is currently sized for some other device's grid, so this
    /// client's screen holds wrong-width layout that the next repaint must
    /// not draw over.
    private var ptyIsForeignSized = false
    private static let highWater = 1 << 20   // start dropping above 1 MB in flight
    private static let lowWater = 128 << 10  // recovered once under 128 KB
    /// Cap on the plain-shell replay sent to a phone on attach — a few
    /// screenfuls, enough to paint the current screen without reflowing the
    /// whole ring at the phone's narrow grid (the allocator-panic trigger).
    private static let phoneReplayCap = 128 << 10  // 128 KB
    /// Clears glyphs and scrollback but not modes — alt-screen and mouse
    /// reporting survive, where a full RIS would knock the TUI out of them.
    private static let wipe = Data("\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8)

    init(pty: PTYProcess, connection: NWConnection) {
        self.pty = pty
        self.connection = connection
    }

    func start() {
        // A full-screen TUI (Claude Code, vim) repaints its whole screen on the
        // next SIGWINCH, and its ring buffer was laid out for whatever grid the
        // Mac had — replaying those bytes at the phone's narrower grid lands the
        // cursor motions wrong, so the stale frame survives as a ghost under the
        // live one (and the reflow spike can tip the phone's allocator over). So
        // for an alt-screen session skip the replay entirely: re-assert just the
        // current modes below, wipe, and let the client's resize claim force a
        // clean full repaint. A plain shell has no such repaint, so it still
        // replays — its history is the screen.
        let altScreen = pty.isAlternateScreenActive
        // The panic-hunt datapoint: which attach path ran. An alt-screen TUI
        // skips the byte replay (no reflow spike); a plain shell replays up to
        // `phoneReplayCap`. Filter with:
        //   log stream --predicate 'category == "companion"' --info
        Log.companion.notice("attach altScreen=\(altScreen, privacy: .public) replayCapBytes=\(altScreen ? 0 : Self.phoneReplayCap, privacy: .public)")
        sinkToken = pty.addSink(
            on: queue,
            replayingBuffer: !altScreen,
            // The phone is a viewer, not the scrollback of record — the Mac keeps
            // full history. Replaying the whole 1 MB ring reflows at the phone's
            // narrow grid all at once and can tip libghostty's allocator into its
            // panic screen on the cold attach. A few screenfuls is all a viewer
            // needs to paint "where you are"; the rest is the Mac's to hold.
            replayCap: Self.phoneReplayCap
        ) { [weak self] data in
            self?.send(data)
        }
        // When the replay is skipped nothing carries the mode switches, so the
        // phone must be put into the alternate screen and mouse modes explicitly.
        // Then wipe the glyphs — 2J/3J/home rather than a full RIS, so those modes
        // survive. The repaint comes from the client's resize claim, which follows
        // the attach on the same socket. The bridge queue is serial, so this lands
        // after any replay and before that repaint.
        queue.async { [weak self] in
            guard let self else { return }
            if altScreen {
                let preamble = pty.modeResyncPreamble()
                if !preamble.isEmpty { send(preamble) }
            }
            send(Self.wipe)
        }
        // Any winsize change this client didn't ask for (the Mac typing and
        // reclaiming the size) makes the repaint that follows land wrong on
        // this grid — wipe first so it can't draw over the current frame,
        // and once more when the size comes back home.
        resizeToken = pty.addResizeObserver { [weak self] cols, rows in
            guard let self else { return }
            lock.lock()
            let foreign = cols != clientCols || rows != clientRows
            let needsWipe = foreign || ptyIsForeignSized
            ptyIsForeignSized = foreign
            lock.unlock()
            if needsWipe {
                queue.async { self.send(Self.wipe) }
            }
        }
    }

    /// A resize control from this client: record its grid and claim the size
    /// for it. When the winsize actually changes, the SIGWINCH makes the child
    /// redraw (and the resize observer wipes any wrong-width layout). When it
    /// does *not* change — a cold attach at the same size, or a re-entry that
    /// reasserts the grid to reclaim ownership from the Mac — no SIGWINCH fires,
    /// so jiggle to force the redraw ourselves. The current prompt is then
    /// reprinted cleanly over any `PROMPT_SP` line the phone had rendered
    /// reflowed at the Mac's width; scrollback is left intact (no wipe).
    func applyClientResize(cols: Int, rows: Int) {
        lock.lock()
        clientCols = cols
        clientRows = rows
        lock.unlock()
        if !pty.resizeFromCompanion(cols: cols, rows: rows) {
            pty.jiggleResize()
        }
    }

    func stop() {
        if let token = sinkToken { pty.removeSink(token) }
        sinkToken = nil
        if let token = resizeToken { pty.removeResizeObserver(token) }
        resizeToken = nil
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
                    // The dropped frames tore escape sequences mid-stream;
                    // clean the slate so remnants can't survive the forced
                    // repaint as ghosts.
                    queue.async { [weak self] in self?.send(Self.wipe) }
                    pty.jiggleResize()
                }
            }
        )
    }
}

// MARK: - Store → PTY attach

extension TermioStore {
    /// The PTY backing a session for a phone attach. If the session was never
    /// shown on the Mac (surfaces are made lazily on first render), create it
    /// now — that spawns the agent with its recorded resume arguments, so the
    /// phone wakes the same conversation instead of being told "no terminal".
    /// `wireID` is a full session UUID or the CLI's 8-char prefix.
    func companionPTY(for wireID: String) -> PTYProcess? {
        guard let (project, session) = findCompanionSession(wireID) else { return nil }
        // Attaching from the phone is the mobile equivalent of selecting the
        // session in the desktop sidebar: the user is now looking at the prompt,
        // so a resting "needs you" / unseen "done" marker has been acknowledged.
        // Without this, permission prompts answered through the raw PTY can stay
        // orange forever because menu keystrokes don't necessarily produce a new
        // agent hook event to overwrite the old attention state.
        if statuses[session.id] == .needsAttention || statuses[session.id] == .done {
            statuses[session.id] = .idle
        }
        liveActivity[project.id] = Date()
        if let pty = ptyProcesses[session.id] { return pty }
        _ = surface(for: session, in: project)
        return ptyProcesses[session.id]
    }

    /// Create a session in a project for a phone `start` request — the same
    /// `addSession` the sidebar buttons and the CLI use. Returns the new
    /// session's wire id, nil if the project is unknown.
    func companionStartSession(projectID wireID: String, agent wireAgent: String) -> String? {
        let prefix = wireID.lowercased()
        guard !prefix.isEmpty,
              let project = projects.first(where: {
                  $0.id.uuidString.lowercased().hasPrefix(prefix)
              })
        else { return nil }
        // Reverse of `wireAgent`: resolve the phone's token back to a definition by
        // its wire name (so user agents, whose wire name is their id, resolve too);
        // an unknown token falls back to a plain terminal.
        let preset = AgentPreset.allCases.first { $0.wireName == wireAgent } ?? .terminal
        addSession(to: project.id, agent: preset)
        return selectedSessionID?.uuidString
    }

    /// Close a session for a phone `stop` request — the same `closeSession`
    /// the sidebar and CLI use. Returns false if the id matches nothing.
    func companionStopSession(sessionID wireID: String) -> Bool {
        guard let (_, session) = findCompanionSession(wireID) else { return false }
        closeSession(session.id)
        return true
    }

    /// Resolve a session's transcript path and display title for a phone
    /// `trace` request. Learns the path from disk when no hook has delivered it
    /// yet — the same fallback the desktop Info pane uses — so the phone can
    /// render a trace even for a session the Mac never opened. nil when the
    /// session is unknown or has no readable transcript.
    func companionTrace(for wireID: String) -> (path: String, title: String)? {
        guard let (_, session) = findCompanionSession(wireID) else { return nil }
        guard let path = transcriptPaths[session.id] ?? resolveTranscriptPath(for: session.id)
        else { return nil }
        transcriptPaths[session.id] = path
        return (path, displayTitle(for: session))
    }

    private func findCompanionSession(_ wireID: String) -> (Project, Session)? {
        let prefix = wireID.lowercased()
        guard !prefix.isEmpty else { return nil }
        for project in projects {
            // Browser panes are invisible to the phone (they're not in the roster
            // either): a PTY attach against one would spawn a shell the session
            // was never meant to have.
            for session in project.sessions
            where !session.isBrowser && session.id.uuidString.lowercased().hasPrefix(prefix) {
                return (project, session)
            }
        }
        return nil
    }
}

// MARK: - Store → roster

extension TermioStore {
    /// Snapshot the current projects/sessions as a wire roster, mirroring what
    /// the sidebar renders (display titles, live agent status).
    func companionRoster() -> CompanionRoster {
        let projects = self.projects.map { project in
            RosterProject(
                id: project.id.uuidString,
                name: project.name,
                path: project.path,
                branch: branchModel.branch(for: project.path) ?? project.branch,
                // Browser panes stay Mac-only: the phone renders terminals over
                // the PTY wire, and a browser session has no PTY to attach.
                sessions: project.sessions.filter { !$0.isBrowser }.map { session in
                    // The sidebar tooltip's activity line doubles as the
                    // phone's row preview; empty means "nothing to say".
                    let activity = statusDescription(for: session.id)
                    return RosterSession(
                        id: session.id.uuidString,
                        title: displayTitle(for: session),
                        agent: Self.wireAgent(session.agent),
                        status: Self.wireStatus(status(for: session.id)),
                        subtitle: activity.isEmpty ? nil : activity
                    )
                }
            )
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
        return CompanionRoster(projects: projects, agents: agents)
    }

    private static func wireAgent(_ agent: AgentPreset) -> String {
        agent.wireName
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
