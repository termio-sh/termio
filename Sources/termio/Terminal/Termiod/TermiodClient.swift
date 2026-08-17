import CryptoKit
import Darwin
import Foundation

/// Attach client for the local `termiod` session host (Session Protocol v0.1,
/// see termiod/src/protocol.rs). Behind the opt-in `TERMIO_TERMIOD=1` flag the
/// app stops owning PTYs itself: every session lives inside the daemon, the app
/// merely attaches over the Unix socket, and quitting detaches instead of
/// killing — which is what lets sessions survive an app quit or self-update.
///
/// Framing is `[kind: u8][length: u32 big-endian][payload]`. Control payloads
/// are JSON; `D` (data) is raw PTY bytes and `R` (resize) is rows/cols as two
/// big-endian u16.
enum Termiod {
    /// What this client offers on an **attach** channel, and — the part that
    /// matters — who consumes each. A capability is a promise to handle the
    /// frames it unlocks: offering one with nothing behind it is worse than not
    /// offering it, because the daemon then spends bandwidth on frames that are
    /// dropped on the floor. The daemon's full set is `HOST_CAPABILITIES` in
    /// termiod/src/protocol.rs; the stance on every one of them:
    ///
    /// | Capability   | Offered | Consumer |
    /// | ------------ | ------- | -------- |
    /// | `snapshot`   | yes     | `S` → `TermiodSnapshot.render` → the surface's repaint |
    /// | `events`     | yes     | `E` → `TermiodSessionLink.onStatus` (agent status), `applyWriter` (write gating), `applyAuthoritativeGrid` (§C.5 dimensions) |
    /// | `scrollback` | no      | `H` carries packed cells to inject *above* the viewport; a byte-stream surface has nowhere to put them |
    /// | `grid_diff`  | no      | `G` would make the host resolve every cell's colour, which overrides the viewer's theme — the §A/§H regression this client exists not to repeat |
    /// | `send_wait`  | no      | `send`/`wait` are control-channel verbs; the app injects through its own attach channel |
    /// | `resources`  | no      | `subscribe_resource` — the file tree and git panes are the consumers, on their own channel |
    /// | `fs_watch`   | no      | ditto |
    /// | `files`      | no      | ditto |
    /// | `upload`     | no      | remote paste; rides a control channel, not an attachment |
    /// | `git`        | no      | ditto |
    ///
    /// A later plane opens its own channel and passes its own `caps` to
    /// `withControlChannel` — capabilities are per-connection, so nothing here
    /// has to grow for the file tree or git to land.
    static let attachCapabilities = ["snapshot", "events"]

    /// What a plain control channel (`list`, `kill`) offers: nothing. Both verbs
    /// are unconditional, and tombstones ride the `sessions` reply un-gated.
    static let controlCapabilities: [String] = []

    /// Checked once — the flag flips the app's session backend wholesale, so a
    /// mid-run change could not be honored anyway.
    static let isEnabled = ProcessInfo.processInfo.environment["TERMIO_TERMIOD"] == "1"

    static let protocolVersion: UInt32 = 1

    /// Mirrors termiod/src/paths.rs exactly — both sides must derive the same
    /// socket or the app talks to a different daemon than the CLI:
    /// `TERMIOD_SOCK` override, else `$XDG_RUNTIME_DIR/termiod/`, else a
    /// uid-scoped directory under the temp dir (`$TMPDIR`, else `/tmp` — the
    /// same fallback order as Rust's `std::env::temp_dir()`).
    static func socketPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["TERMIOD_SOCK"], !explicit.isEmpty {
            return explicit
        }
        if let runtimeDirectory = environment["XDG_RUNTIME_DIR"], !runtimeDirectory.isEmpty {
            return runtimeDirectory + "/termiod/termiod.sock"
        }
        let temporaryDirectory = environment["TMPDIR"] ?? "/tmp"
        let base = temporaryDirectory.hasSuffix("/")
            ? String(temporaryDirectory.dropLast())
            : temporaryDirectory
        return "\(base)/termiod-\(getuid())/termiod.sock"
    }

    /// The daemon's name inside the bundle. Unlike the `termio` CLI it is not
    /// renamed per channel: the CLI is symlinked onto PATH, where a dev copy
    /// would clobber the release one, while the daemon is only ever executed by
    /// absolute path out of the bundle that ships it. (Keeping the two channels'
    /// *sessions* apart is `TERMIOD_SOCK`, a separate axis.)
    static let daemonBinaryName = "termiod"

    /// The daemon binary used for autostart. One resolution point so autostart
    /// and diagnostics can never disagree, in this order:
    ///
    /// 1. `TERMIO_TERMIOD_BIN` — the development override, unchanged.
    /// 2. `Contents/Resources/termiod` in the running `.app` — what a shipped
    ///    build uses. `Bundle.main`, never `Bundle.module`: SwiftPM bakes the
    ///    latter with the build machine's path and it does not survive into a
    ///    shipped bundle.
    /// 3. `termiod/target/{release,debug}/termiod` in the checkout the running
    ///    binary lives in, so a bare `swift build` binary — which has no bundle
    ///    at all, the case `CommandLineTool.bundledURL` answers `nil` for —
    ///    still finds the daemon a developer just built.
    ///
    /// The checkout fallback is anchored at the *binary*, not at
    /// `currentDirectoryPath`. A Finder-launched app has cwd `/`, which is how
    /// the previous fallback resolved `/termiod/target/debug/termiod` and why no
    /// released build could ever start a daemon.
    static func daemonBinaryPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["TERMIO_TERMIOD_BIN"], !explicit.isEmpty {
            return explicit
        }
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forResource: daemonBinaryName, withExtension: nil) {
            candidates.append(bundled.path)
        }
        let executableDirectory = (Bundle.main.executableURL ?? Bundle.main.bundleURL)
            .deletingLastPathComponent()
        candidates += developmentDaemonCandidates(near: executableDirectory)
        let fileManager = FileManager.default
        if let usable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return usable
        }
        // Nothing exists yet: name the bundle location a shipped build should
        // have had, so `daemonBinaryMissing` reports the path worth fixing.
        return candidates.first
            ?? Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/\(daemonBinaryName)").path
    }

    /// `termiod` builds inside the checkout the running binary sits in, nearest
    /// first, release before debug. The search walks up from `directory` looking
    /// for the marker that identifies the repo root — `termiod/Cargo.toml` —
    /// which places it correctly for both `.build/<triple>/debug/termio` and an
    /// `.app` assembled at the repo root. Empty when there is no checkout above
    /// the binary, which is the shipped case.
    ///
    /// Separate from `daemonBinaryPath()` so it can be tested without a bundle.
    static func developmentDaemonCandidates(near directory: URL) -> [String] {
        let fileManager = FileManager.default
        var current = directory.standardizedFileURL
        // Deep enough for `.build/<triple>/debug/` and for an `.app`'s
        // `Contents/MacOS/`, shallow enough never to walk to `/`.
        for _ in 0 ..< 8 {
            let root = current.appendingPathComponent("termiod")
            if fileManager.isReadableFile(atPath: root.appendingPathComponent("Cargo.toml").path) {
                return ["release", "debug"].map {
                    root.appendingPathComponent("target/\($0)/\(daemonBinaryName)").path
                }
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return []
    }

    // MARK: - Socket

    /// One blocking connect attempt against the daemon socket.
    private static func openSocket() -> Int32? {
        let path = socketPath()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard pathBytes.count <= capacity else {
            close(descriptor)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(descriptor, rebound, length)
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Connect, auto-starting `termiod serve` when no daemon answers — the
    /// same detached-spawn-and-poll the Rust CLI performs, so whichever side
    /// touches the socket first brings the daemon up for both.
    static func connectWithAutostart() throws -> Int32 {
        if let descriptor = openSocket() { return descriptor }
        try spawnDaemon()
        for _ in 0 ..< 50 {
            usleep(40_000)
            if let descriptor = openSocket() { return descriptor }
        }
        throw TermiodClientError.daemonUnreachable(socketPath())
    }

    /// The remote `termiod` path invoked over SSH. Matches the CLI's deploy
    /// target (`termiod remote deploy` installs to `~/.local/bin/termiod`);
    /// overridable so a non-standard install still works.
    static func remoteBinary() -> String {
        ProcessInfo.processInfo.environment["TERMIOD_REMOTE_BIN"]
            ?? "$HOME/.local/bin/termiod"
    }

    /// Options that make the SSH connection a resource this app holds rather
    /// than one it re-establishes per session. Without a master, every session
    /// and every reconnect pays a full TCP handshake plus SSH key exchange —
    /// measured at 230–300 ms against a VPS, against 26–33 ms once a master
    /// exists.
    ///
    /// Nothing is injected when the user's own config already configures
    /// multiplexing for this host. A command-line `-o` outranks
    /// `~/.ssh/config`, so injecting unconditionally would override a
    /// deliberate `ControlMaster no`, and the config is authoritative for how
    /// to reach a host. Answers are cached per host because `ssh -G` forks and
    /// this sits on the path that opens a session.
    static func multiplexingArguments(host: String) -> [String] {
        if let cached = multiplexingLock.withLock({ multiplexingCache[host] }) {
            return cached
        }
        // The probe runs outside the lock (never hold a lock across a fork); a
        // rare duplicate lookup just recomputes the same answer.
        let resolved = resolveMultiplexingArguments(host: host)
        multiplexingLock.withLock { multiplexingCache[host] = resolved }
        return resolved
    }

    private static let multiplexingLock = NSLock()
    /// `nonisolated(unsafe)` because every access goes through
    /// `multiplexingLock` above — the lock, not the actor, is what makes this
    /// safe, and the compiler cannot see that.
    nonisolated(unsafe) private static var multiplexingCache: [String: [String]] = [:]

    private static func resolveMultiplexingArguments(host: String) -> [String] {
        guard userLeavesMultiplexingToUs(host: host),
              let directory = controlSocketDirectory() else { return [] }
        let path = directory.appendingPathComponent(controlSocketName(for: host)).path
        // A Unix socket path is capped at 104 bytes, and an over-long
        // ControlPath makes ssh fail outright rather than degrade. An unusually
        // long temporary directory must cost multiplexing, never the session.
        guard path.utf8.count < 100 else { return [] }
        return ["-o", "ControlMaster=auto",
                "-o", "ControlPath=\(path)",
                "-o", "ControlPersist=10m"]
    }

    /// `ssh -G <host>` prints the fully-resolved effective config. Multiplexing
    /// is ours to set only when the user has configured neither half of it;
    /// `false` and `none` are what OpenSSH prints for those defaults. A failed
    /// probe answers "no", so a broken probe can never smuggle options past a
    /// config it could not read.
    private static func userLeavesMultiplexingToUs(host: String) -> Bool {
        guard let config = effectiveSSHConfig(host: host) else { return false }
        var master: String?
        var path: String?
        for line in config.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let value = fields[1].trimmingCharacters(in: .whitespaces).lowercased()
            switch fields[0].lowercased() {
            case "controlmaster": master = value
            case "controlpath": path = value
            default: continue
            }
        }
        // A missing `controlmaster` line means an OpenSSH too old to be read
        // this way, so leave its config alone.
        guard let master, ["false", "no", "none"].contains(master) else { return false }
        // OpenSSH omits `controlpath` entirely when it is unset (confirmed on
        // 10.2p1) where older versions print `none`; both mean the user has
        // chosen no path. Requiring the line to be present made this whole
        // function answer "no" on a current macOS, which is a silent no-op —
        // the exact failure this is meant to end.
        return path == nil || path == "none"
    }

    private static func effectiveSSHConfig(host: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", host]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain before waiting: a full pipe would deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Masters live under the per-user temporary directory rather than
    /// `~/.ssh`: they are runtime state, and the user's ssh directory is not
    /// ours to write into. 0700 because a control socket is a live
    /// authenticated connection to the host — anyone who can open it is on the
    /// far machine without presenting a key.
    private static func controlSocketDirectory() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-ssh" + AppChannel.suffix, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        return directory
    }

    /// A short, stable name per host: stable so a master survives an app
    /// restart, short so the socket path stays inside the 104-byte cap. This is
    /// what OpenSSH's own `%C` token does, computed here so the length is ours
    /// to control rather than a property of whichever OpenSSH is installed.
    private static func controlSocketName(for host: String) -> String {
        SHA256.hash(data: Data(host.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// A bidirectional byte channel to a daemon. Local is one Unix-socket fd
    /// used for both directions; SSH is a pipe pair around an `ssh <host>
    /// termiod stdio` child — the exact same framed protocol either way, which
    /// is the whole point of the stdio bridge. The frame helpers read from
    /// `readDescriptor` and write to `writeDescriptor`.
    final class Transport {
        let readDescriptor: Int32
        let writeDescriptor: Int32
        /// Which road this pipe took. Carried on the transport rather than passed
        /// alongside it so `performHello` cannot record a `host_id` against the
        /// wrong route — the pipe knows where it went.
        let route: TermiodRoute
        private let sshPid: pid_t?

        private init(readDescriptor: Int32, writeDescriptor: Int32,
                     route: TermiodRoute, sshPid: pid_t?) {
            self.readDescriptor = readDescriptor
            self.writeDescriptor = writeDescriptor
            self.route = route
            self.sshPid = sshPid
        }

        /// Local Unix socket; the same fd serves both directions.
        static func local() throws -> Transport {
            let descriptor = try connectWithAutostart()
            return Transport(readDescriptor: descriptor, writeDescriptor: descriptor,
                             route: .local, sshPid: nil)
        }

        /// Opens whichever kind of pipe the route names — the one place local and
        /// SSH differ, so no caller above this line has to branch on it.
        static func open(_ route: TermiodRoute) throws -> Transport {
            switch route {
            case .local: return try local()
            case .ssh(let alias): return try ssh(host: alias)
            }
        }

        /// `ssh <host> termiod stdio`: the framed protocol rides the SSH pipe,
        /// so the remote daemon (auto-starting on first contact) is reached
        /// with the identical messages. System OpenSSH is the trust plane; no
        /// keys or crypto live in termio.
        static func ssh(host: String) throws -> Transport {
            var toChild = [Int32](repeating: -1, count: 2) // app writes [1] → child stdin [0]
            var fromChild = [Int32](repeating: -1, count: 2) // child stdout [1] → app reads [0]
            guard pipe(&toChild) == 0 else {
                throw TermiodClientError.daemonUnreachable("ssh:\(host)")
            }
            // Close the first pair before bailing, or a second-pipe failure (most
            // likely under fd exhaustion — exactly when it happens) leaks two fds.
            guard pipe(&fromChild) == 0 else {
                Darwin.close(toChild[0])
                Darwin.close(toChild[1])
                throw TermiodClientError.daemonUnreachable("ssh:\(host)")
            }

            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            posix_spawn_file_actions_adddup2(&fileActions, toChild[0], 0)
            posix_spawn_file_actions_adddup2(&fileActions, fromChild[1], 1)
            // Child inherits stderr for SSH diagnostics; close the pipe ends it
            // must not keep open.
            posix_spawn_file_actions_addclose(&fileActions, toChild[1])
            posix_spawn_file_actions_addclose(&fileActions, fromChild[0])

            let command = "\(remoteBinary()) stdio"
            let arguments = ["ssh", "-o", "ServerAliveInterval=15"]
                + multiplexingArguments(host: host)
                + [host, command]
            let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }

            var pid: pid_t = 0
            let status = posix_spawnp(&pid, "ssh", &fileActions, nil, argv, environ)
            Darwin.close(toChild[0])
            Darwin.close(fromChild[1])
            guard status == 0 else {
                Darwin.close(toChild[1])
                Darwin.close(fromChild[0])
                throw TermiodClientError.daemonSpawnFailed(status)
            }
            return Transport(readDescriptor: fromChild[0], writeDescriptor: toChild[1],
                             route: .ssh(host), sshPid: pid)
        }

        /// Detach: closing the pipe/socket ends the attach without killing the
        /// session, and reaps the SSH child so it can't linger. Closing the fds
        /// is synchronous (it wakes the blocked reader); reaping the SSH child is
        /// dispatched off the caller's thread so a wedged connection can never
        /// beachball the app — `detach()` runs on the main actor at quit, once
        /// per session, and a blocking `waitpid` on a network-stalled ssh would
        /// hang Cmd-Q.
        func close() {
            Darwin.close(writeDescriptor)
            if readDescriptor != writeDescriptor {
                Darwin.close(readDescriptor)
            }
            guard let sshPid else { return }
            DispatchQueue.global(qos: .utility).async {
                kill(sshPid, SIGTERM)
                // Bounded, non-blocking reap: SIGTERM then poll briefly, escalate
                // to SIGKILL, and never block indefinitely. If it still lingers,
                // it is reparented to launchd, which reaps it.
                for _ in 0 ..< 20 {
                    var ignored: Int32 = 0
                    if waitpid(sshPid, &ignored, WNOHANG) != 0 { return }
                    usleep(50_000)
                }
                kill(sshPid, SIGKILL)
                var ignored: Int32 = 0
                _ = waitpid(sshPid, &ignored, WNOHANG)
            }
        }
    }

    /// Spawns `termiod serve` in its own session (`POSIX_SPAWN_SETSID`) with
    /// stdio on /dev/null, so the daemon survives the app — and, under
    /// `swift run`, a terminal Ctrl-C aimed at the app's process group.
    private static func spawnDaemon() throws {
        let binary = daemonBinaryPath()
        Log.termiod.info("starting daemon binary=\(binary, privacy: .public)")
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw TermiodClientError.daemonBinaryMissing(binary)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT matters as much as SETSID: without it the daemon
        // inherits every open descriptor of the app — including its listening
        // control sockets, which then stay half-alive after the app quits and
        // wedge the next binding (observed: `termio sessions` hanging against
        // a socket the long-lived daemon still held open).
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // The daemon derives its socket path from its own environment, so it
        // must inherit ours (TMPDIR above all) or the two sides rendezvous at
        // different sockets.
        let argumentStrings = [binary, "serve"]
        let argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, binary, &fileActions, &attributes, argv, envp)
        guard status == 0 else {
            throw TermiodClientError.daemonSpawnFailed(status)
        }
    }

    // MARK: - Framing

    enum FrameKind: UInt8 {
        case control = 0x43 // 'C'
        case data = 0x44 // 'D'
        case resize = 0x52 // 'R'
        case event = 0x45 // 'E'
        case snapshot = 0x53 // 'S'
        case history = 0x48 // 'H'
        case grid = 0x47 // 'G'
        case file = 0x46 // 'F'
        case upload = 0x55 // 'U'
    }

    static let maximumFrameSize = 16 * 1024 * 1024
    /// The daemon chunks its own data frames at this size; mirror it upstream
    /// so a huge paste can't produce an oversized frame.
    static let maximumDataFrameSize = 64 * 1024

    static func writeFully(_ descriptor: Int32, _ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw TermiodClientError.connectionClosed
                }
            }
        }
    }

    static func writeFrame(_ descriptor: Int32, kind: FrameKind, payload: Data) throws {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(kind.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try writeFully(descriptor, frame)
    }

    private static func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else {
                throw TermiodClientError.connectionClosed
            }
            while offset < count {
                let readCount = read(descriptor, base + offset, count - offset)
                if readCount > 0 {
                    offset += readCount
                } else if readCount < 0, errno == EINTR {
                    continue
                } else {
                    throw TermiodClientError.connectionClosed
                }
            }
        }
        return buffer
    }

    /// Blocking read of one whole frame. Unknown kinds are a protocol error —
    /// the kind byte is the one non-additive part of the framing.
    static func readFrame(_ descriptor: Int32) throws -> (kind: FrameKind, payload: Data) {
        let header = try readExactly(descriptor, count: 5)
        let length = header.subdata(in: 1 ..< 5).withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
        guard let kind = FrameKind(rawValue: header[0]), Int(length) <= maximumFrameSize else {
            throw TermiodClientError.malformedFrame
        }
        let payload = length == 0 ? Data() : try readExactly(descriptor, count: Int(length))
        return (kind, payload)
    }

    // MARK: - Control payloads

    /// Spawn parameters for `attach` with `create_if_missing`. The daemon
    /// fills `name` from the attach target, so it is not repeated here.
    struct CreateSpecification: Encodable {
        let cwd: String
        let argv: [String]
        /// Wire shape of Rust's `Vec<(String, String)>` — an array of pairs.
        let env: [[String]]
        let rows: UInt16
        let cols: UInt16
    }

    private struct HelloOperation: Encodable {
        let op = "hello"
        let proto: UInt32
        let minProto: UInt32
        let role: String
        let caps: [String]
        let client: String
    }

    private struct AttachOperation: Encodable {
        let op = "attach"
        let target: String
        let createIfMissing: CreateSpecification?
        let rows: UInt16
        let cols: UInt16
        let mode = "interact"
        let seq: UInt64
    }

    private struct ListOperation: Encodable {
        let op = "list"
        let seq: UInt64
    }

    private struct KillOperation: Encodable {
        let op = "kill"
        let id: String
        let seq: UInt64
    }

    private struct DetachOperation: Encodable {
        let op = "detach"
    }

    /// Opens a transfer into a session's scratch directory on the device
    /// (§C.12 `temp:` dest). `session` is the termiod session name — the app's
    /// session UUID — and the daemon reaps whatever lands there when that
    /// session dies, so a pasted screenshot never outlives the conversation it
    /// belonged to.
    struct UploadOpenOperation: Encodable {
        let op = "upload_open"
        let dest: String
        let session: String
        let size: UInt64
        let sha256: String
        let seq: UInt64
    }

    struct UploadCommitOperation: Encodable {
        let op = "upload_commit"
        let uploadId: String
        let seq: UInt64
    }

    struct UploadAbortOperation: Encodable {
        let op = "upload_abort"
        let uploadId: String
        let seq: UInt64
    }

    /// Only the `op` tag — the second decode pass picks the payload shape.
    private struct ControlTag: Decodable {
        let op: String
    }

    /// The daemon's answer to `hello`, and the only place a device's identity
    /// comes from: `hostId` is the machine, `host` is the daemon's version and
    /// platform banner (`termiod/0.1.0 macos-aarch64` — not a hostname), and
    /// `clientId` names this connection (per-connection, never load-bearing).
    struct HelloOkPayload: Decodable {
        let hostId: String
        let host: String
        let clientId: String
        /// Capabilities the daemon accepted. Absent on an older daemon, so it
        /// defaults rather than failing the handshake — negotiate, never lockstep.
        let caps: [String]

        private enum CodingKeys: String, CodingKey {
            case hostId, host, clientId, caps
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hostId = try container.decode(String.self, forKey: .hostId)
            host = try container.decode(String.self, forKey: .host)
            clientId = try container.decode(String.self, forKey: .clientId)
            caps = try container.decodeIfPresent([String].self, forKey: .caps) ?? []
        }
    }

    struct AttachedPayload: Decodable {
        let sessionId: String
        let writer: Bool
        let rows: UInt16
        let cols: UInt16
    }

    struct ExitedPayload: Decodable {
        let id: String
        let status: Int32
    }

    struct ErrorPayload: Decodable {
        let code: String?
        let message: String
    }

    struct SessionsPayload: Decodable, Sendable {
        let sessions: [SessionInformation]
        /// Sessions that have died, newest first. Absent on a daemon too old to
        /// bury them, which is why it decodes to an empty list rather than
        /// failing the reply.
        let tombstones: [SessionTombstone]

        private enum CodingKeys: String, CodingKey {
            case sessions, tombstones
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try container.decode([SessionInformation].self, forKey: .sessions)
            tombstones = try container.decodeIfPresent(
                [SessionTombstone].self, forKey: .tombstones) ?? []
        }
    }

    /// One row of `termiod list` — a session as the **device** describes it.
    ///
    /// This carries enough to draw a row without consulting anything on this Mac,
    /// which is the point: a session the app never opened (started from the CLI,
    /// or by another client) still has a name, a directory, a command, and an
    /// agent status, and all four come from the machine it runs on. Unknown
    /// fields are ignored and every field the daemon added after v0 decodes
    /// optionally, so an older host degrades to blanks instead of a decode error.
    struct SessionInformation: Decodable, Sendable, Hashable {
        let id: String
        let name: String
        let pid: Int32
        let alive: Bool
        /// The directory the process runs in, **on the device**. Never a path on
        /// this Mac, which is why it is only ever shown, never opened.
        let cwd: String
        let command: String
        /// The workstream status the session last reported — `working · idle ·
        /// needs_you · done · failed · unknown` (§4). The host names the state;
        /// which dot it becomes is the client's call.
        let status: String
        let agentID: String?
        /// The title the agent reported, when it reported one.
        let title: String?
        let createdUnix: UInt64
        /// How many clients are attached right now. A non-zero count on a session
        /// this app has no row for means someone else is watching it.
        let attachedClients: Int

        private enum CodingKeys: String, CodingKey {
            case id, name, pid, alive, cwd, command, status, title, createdUnix
            case agentID = "agentId"
            case attachedClients
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            pid = try container.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
            alive = try container.decodeIfPresent(Bool.self, forKey: .alive) ?? true
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
            command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
            agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            createdUnix = try container.decodeIfPresent(UInt64.self, forKey: .createdUnix) ?? 0
            attachedClients = try container.decodeIfPresent(Int.self, forKey: .attachedClients) ?? 0
        }
    }

    /// A dead session, as the daemon buried it (termiod/src/tombstone.rs). This
    /// is the only answer to "where did my session go?": a daemon that died
    /// takes every PTY with it, and without a tombstone the roster just comes
    /// back empty, which reads as "nothing was running".
    ///
    /// `reason` stays a string, not an enum, so a later daemon can bury a
    /// session for a reason this build has never heard of without the reply
    /// failing to decode. The host names the cause; the words shown to a person
    /// are the client's to choose (see `TermioStore.termiodEndReason(for:)`).
    struct SessionTombstone: Decodable, Sendable, Hashable {
        let id: String
        /// The termiod session name — which, for sessions this app created, is
        /// the app `Session.ID` uuid string. That is what ties a tombstone back
        /// to a row in the sidebar.
        let name: String
        let cwd: String
        let command: String
        /// `exited` · `killed` · `daemon_lost`, or whatever a newer daemon adds.
        let reason: String
        /// The process's exit code. Absent for `daemon_lost` — the daemon that
        /// would have reaped the child died first, so there is no honest answer.
        let exitStatus: Int32?
        let createdUnix: UInt64
        let endedUnix: UInt64
        let agentID: String?
        let title: String?
        /// The workstream status the session last reported. A session that died
        /// while `needs_you` is a different story from one that died `idle`.
        let status: String

        private enum CodingKeys: String, CodingKey {
            case id, name, cwd, command, reason, exitStatus, createdUnix, endedUnix
            case agentID = "agentId"
            case title, status
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
            command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
            reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "unknown"
            exitStatus = try container.decodeIfPresent(Int32.self, forKey: .exitStatus)
            createdUnix = try container.decodeIfPresent(UInt64.self, forKey: .createdUnix) ?? 0
            endedUnix = try container.decodeIfPresent(UInt64.self, forKey: .endedUnix) ?? 0
            agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        }
    }

    /// Who owns the write token now. `writer` is a daemon-scoped client id, so
    /// the only client that can tell whether it is the writer is the one that
    /// remembers its own `client_id` from `hello_ok`.
    struct WriterChangedPayload: Decodable, Sendable {
        let session: String
        let writer: String?
    }

    /// The authoritative PTY grid after a resize. Every client is required to
    /// parse at these dimensions (§C.5) — an observer whose window is a
    /// different size wraps the same bytes differently and diverges.
    struct ResizedPayload: Decodable, Sendable {
        let session: String
        let rows: UInt16
        let cols: UInt16
    }

    /// A workstream status delta — `working · idle · needs_you · done · failed ·
    /// unknown` (§4). The host reports the *state*; which dot, which words, and
    /// whether it fires a notification are entirely the client's call.
    struct StatusPayload: Decodable, Sendable {
        let session: String
        let status: String
        let title: String?
    }

    struct SessionExitedPayload: Decodable, Sendable {
        let session: String
        let status: Int32
    }

    /// Decoded `E` frames. Unknown events become `.unknown` and are ignored,
    /// matching the protocol's additive-evolution rule.
    enum IncomingEvent {
        case ready(String)
        case status(StatusPayload)
        case writerChanged(WriterChangedPayload)
        case resized(ResizedPayload)
        case sessionExited(SessionExitedPayload)
        case unknown(String)
    }

    private struct EventTag: Decodable {
        let ev: String
    }

    /// Every event names its session and nothing else is required — enough to
    /// decode `ready`, and the shape any future session-scoped event shares.
    private struct SessionScopedPayload: Decodable {
        let session: String
    }

    /// Reply to `upload_open`. `offset` is where the next chunk starts: 0 for a
    /// fresh transfer, and the bytes the daemon already holds when this open
    /// resumed one a dropped connection left behind. Absent on a daemon that
    /// predates resume, which reads as "start over" — the same thing it does.
    struct UploadOpenedPayload: Decodable {
        let uploadId: String
        let offset: UInt64

        private enum CodingKeys: String, CodingKey {
            case uploadId, offset
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uploadId = try container.decode(String.self, forKey: .uploadId)
            offset = try container.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        }
    }

    /// The credit-of-one grant: `offset` is the total the daemon has received,
    /// which is where the next chunk goes. Holding the next chunk until this
    /// arrives is what bounds a keystroke's wait on a shared pipe to one chunk.
    struct UploadAckPayload: Decodable {
        let uploadId: String
        let offset: UInt64
    }

    /// Where the verified bytes landed on the device — an absolute path on
    /// *that* machine, which is the whole point of the transfer.
    struct UploadCommittedPayload: Decodable {
        let path: String
    }

    /// Decoded control frames the client reacts to. Anything else — unknown
    /// ops, responses this slice doesn't consume — becomes `.unknown` and is
    /// ignored, matching the protocol's additive-evolution rule.
    enum IncomingControl {
        case helloOk(HelloOkPayload)
        case helloError(String)
        case attached(AttachedPayload)
        case exited(ExitedPayload)
        case sessions(SessionsPayload)
        case uploadOpened(UploadOpenedPayload)
        case uploadAck(UploadAckPayload)
        case uploadCommitted(UploadCommittedPayload)
        /// The addressed half of `writer_changed`: sent to one client to tell it
        /// who owns size now (§C.5). Same payload shape, so it feeds the same
        /// handler — a client that only listened to the broadcast would still be
        /// correct, and one that only listened to this would not.
        case resizeClaim(WriterChangedPayload)
        case error(ErrorPayload)
        case unknown(String)
    }

    static func encodeControl(_ operation: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(operation)
    }

    static func decodeControl(_ payload: Data) throws -> IncomingControl {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let tag = try decoder.decode(ControlTag.self, from: payload)
        switch tag.op {
        case "hello_ok":
            return .helloOk(try decoder.decode(HelloOkPayload.self, from: payload))
        case "hello_err":
            return .helloError("protocol negotiation failed")
        case "attached":
            return .attached(try decoder.decode(AttachedPayload.self, from: payload))
        case "exited":
            return .exited(try decoder.decode(ExitedPayload.self, from: payload))
        case "sessions":
            return .sessions(try decoder.decode(SessionsPayload.self, from: payload))
        case "upload_opened":
            return .uploadOpened(try decoder.decode(UploadOpenedPayload.self, from: payload))
        case "upload_ack":
            return .uploadAck(try decoder.decode(UploadAckPayload.self, from: payload))
        case "upload_committed":
            return .uploadCommitted(try decoder.decode(UploadCommittedPayload.self, from: payload))
        case "resize_claim":
            return .resizeClaim(try decoder.decode(WriterChangedPayload.self, from: payload))
        case "error":
            return .error(try decoder.decode(ErrorPayload.self, from: payload))
        default:
            return .unknown(tag.op)
        }
    }

    /// Decodes an `E` frame. Same additive contract as `decodeControl`: an event
    /// this build has never heard of is `.unknown`, never a decode failure.
    static func decodeEvent(_ payload: Data) throws -> IncomingEvent {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let tag = try decoder.decode(EventTag.self, from: payload)
        switch tag.ev {
        case "ready":
            return .ready(try decoder.decode(SessionScopedPayload.self, from: payload).session)
        case "status":
            return .status(try decoder.decode(StatusPayload.self, from: payload))
        case "writer_changed":
            return .writerChanged(try decoder.decode(WriterChangedPayload.self, from: payload))
        case "resized":
            return .resized(try decoder.decode(ResizedPayload.self, from: payload))
        case "session_exited":
            return .sessionExited(try decoder.decode(SessionExitedPayload.self, from: payload))
        default:
            return .unknown(tag.ev)
        }
    }

    // MARK: - Handshake and control channel

    /// Everything one handshake settles. A connection is not just a pipe to a
    /// machine: it is a pipe with an identity (`clientID`) and a contract
    /// (`capabilities`), and both are needed to act correctly afterwards —
    /// `writer_changed` names a client id, so a client that forgot its own
    /// cannot tell whether the token is its.
    struct Handshake: Sendable {
        let device: TermiodDevice
        /// This connection's daemon-assigned id. Per-connection: it changes on
        /// every reattach and must never be persisted.
        let clientID: String
        /// What the daemon actually granted — always a subset of what was
        /// offered, and empty on a daemon too old to answer. Check it before
        /// waiting on a frame the host may never send.
        let capabilities: Set<String>
    }

    /// Sends `hello` and waits for `hello_ok`. Callers pass the capabilities
    /// they have consumers for — `attachCapabilities` for a session channel,
    /// and whatever a later plane needs for its own (see that table).
    ///
    /// The handshake is also the only moment a route's destination is knowable:
    /// it is what turns `ssh vps-wan` from a string into a machine, and
    /// recording it here means every path that reaches a daemon — attach, list,
    /// kill — teaches the registry for free.
    @discardableResult
    static func performHello(_ transport: Transport, role: String,
                             caps: [String] = []) throws -> Handshake {
        let hello = HelloOperation(
            proto: protocolVersion,
            minProto: protocolVersion,
            role: role,
            caps: caps,
            client: "termio-mac/dev"
        )
        try writeFrame(transport.writeDescriptor, kind: .control, payload: encodeControl(hello))
        let reply = try readFrame(transport.readDescriptor)
        guard reply.kind == .control else { throw TermiodClientError.malformedFrame }
        switch try decodeControl(reply.payload) {
        case .helloOk(let payload):
            let device = TermiodDeviceRegistry.shared.record(
                hostID: payload.hostId, daemonVersion: payload.host, route: transport.route)
            // An offer the daemon dropped is not an error — negotiate, never
            // lockstep — but it does change what this connection can expect, so
            // it is worth saying out loud once per channel.
            let refused = Set(caps).subtracting(payload.caps)
            if !refused.isEmpty {
                Log.termiod.info("""
                \(role, privacy: .public) channel to \(device.id, privacy: .public) \
                declined capabilities: \(refused.sorted().joined(separator: ", "), privacy: .public)
                """)
            }
            return Handshake(
                device: device, clientID: payload.clientId, capabilities: Set(payload.caps))
        case .helloError(let message):
            throw TermiodClientError.handshakeRejected(message)
        case .error(let payload):
            throw TermiodClientError.handshakeRejected(payload.message)
        default:
            throw TermiodClientError.handshakeRejected("unexpected reply to hello")
        }
    }

    /// One-shot control request: connect, hello as `control`, run `body`,
    /// close. Used for `list` at startup and `kill` on Close Session.
    ///
    /// `caps` is the seam for the planes that come next: a file tree opens this
    /// with `["resources", "files"]`, a git pane adds `"git"`, and neither has
    /// to touch the attach path to do it. `body` receives the handshake so it
    /// can check what was actually granted before it asks for anything.
    @discardableResult
    static func withControlChannel<Result>(
        route: TermiodRoute = .local,
        caps: [String] = controlCapabilities,
        _ body: (Transport, Handshake) throws -> Result
    ) throws -> Result {
        let transport = try Transport.open(route)
        defer { transport.close() }
        let handshake = try performHello(transport, role: "control", caps: caps)
        return try body(transport, handshake)
    }

    /// Connect, shake hands, hang up: the cheapest question you can ask a route,
    /// and the only way to learn which device is behind it. Measured at 0.2 ms
    /// locally, so it is affordable to ask before trusting a stale mapping.
    @discardableResult
    static func probeDevice(route: TermiodRoute) throws -> TermiodDevice {
        let transport = try Transport.open(route)
        defer { transport.close() }
        return try performHello(transport, role: "control").device
    }

    /// The daemon's answer to "what is running?" — which, to be honest, has to
    /// include what *was* running: a daemon that died takes every session with
    /// it, and a live list alone would report that as "nothing". The tombstones
    /// ride the same reply, so there is no second round trip and no window where
    /// the two disagree.
    static func roster(route: TermiodRoute = .local) throws -> SessionsPayload {
        try withControlChannel(route: route) { transport, _ in
            try writeFrame(transport.writeDescriptor, kind: .control,
                           payload: encodeControl(ListOperation(seq: 1)))
            while true {
                let frame = try readFrame(transport.readDescriptor)
                guard frame.kind == .control else { continue }
                switch try decodeControl(frame.payload) {
                case .sessions(let payload):
                    return payload
                case .error(let payload):
                    throw TermiodClientError.requestFailed(payload.message)
                default:
                    continue
                }
            }
        }
    }

    /// Ends a session for real — the explicit user-facing destroy verb, never
    /// part of quit/detach. The target may be a termiod id or name (the app
    /// uses the session UUID it named the session with).
    static func killSession(target: String, route: TermiodRoute = .local) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try withControlChannel(route: route) { transport, _ in
                    try writeFrame(transport.writeDescriptor, kind: .control,
                                   payload: encodeControl(KillOperation(id: target, seq: 1)))
                    // One reply either way; "no such session" just means the
                    // process already exited, which is fine for a destroy.
                    _ = try readFrame(transport.readDescriptor)
                }
            } catch {
                Log.termiod.error("""
                kill \(target, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    static func attachPayload(
        target: String,
        specification: CreateSpecification?,
        rows: UInt16,
        cols: UInt16
    ) throws -> Data {
        try encodeControl(AttachOperation(
            target: target,
            createIfMissing: specification,
            rows: rows,
            cols: cols,
            seq: 1
        ))
    }

    static func detachPayload() throws -> Data {
        try encodeControl(DetachOperation())
    }
}

enum TermiodClientError: LocalizedError {
    case daemonUnreachable(String)
    case daemonBinaryMissing(String)
    case daemonSpawnFailed(Int32)
    case connectionClosed
    case malformedFrame
    case handshakeRejected(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .daemonUnreachable(let socket):
            return "could not reach termiod at \(socket)"
        case .daemonBinaryMissing(let binary):
            return "termiod binary not found at \(binary)"
        case .daemonSpawnFailed(let status):
            return "posix_spawn of termiod failed with status \(status)"
        case .connectionClosed:
            return "the termiod connection closed"
        case .malformedFrame:
            return "malformed termiod frame"
        case .handshakeRejected(let message):
            return "termiod hello rejected: \(message)"
        case .requestFailed(let message):
            return message
        }
    }
}

/// A terminal grid. A named pair rather than a tuple so "is the PTY already
/// this size?" is one comparison the compiler checks, on a path where getting
/// it wrong costs every viewer a repaint.
struct TerminalGrid: Equatable, Sendable {
    let rows: UInt16
    let cols: UInt16
}

/// One session's attach channel: the termiod-backed stand-in for what
/// `PTYProcess` is on the in-process path. Owns the socket, forwards surface
/// input as `D` frames and grid changes as `R` frames, and delivers the
/// daemon's output/exit back to the surface. Closing the socket is a detach —
/// the daemon keeps the session running; only `killAndClose` destroys it.
final class TermiodSessionLink: @unchecked Sendable {
    /// All connection state is confined to this serial queue: the handshake
    /// runs on it, sends hop onto it, and the reader thread only touches state
    /// through it — so no lock is needed.
    private let workQueue = DispatchQueue(label: "sh.termio.termiod.link", qos: .userInitiated)

    /// The name this channel attached under — the app session's uuid, or the
    /// name a session already had on the device when it was adopted. Readable
    /// because the store keys its tombstones by it.
    let sessionName: String
    private let specification: Termiod.CreateSpecification
    /// The road to the device this session lives on — `.local` for this Mac's
    /// daemon, `.ssh(alias)` for another box. The framed protocol and every other
    /// field are identical either way; only how the pipe is opened differs.
    let route: TermiodRoute
    private let startedAt = Date()

    private var transport: Termiod.Transport?
    private var attached = false
    private var isWriter = false
    /// This connection's daemon-assigned id, from `hello_ok`. Without it a
    /// `writer_changed` naming `c_41` is unreadable — the whole point of the
    /// event is telling *this* client whether the token is still its.
    private var clientID: String?
    /// Keystrokes typed during the connect/attach window — flushed, in order,
    /// the moment the channel is writable so nothing the user typed is lost.
    private var pendingInput = Data()
    /// The grid this client wants the PTY to be, updated by every `resize`
    /// whether or not it can be sent yet.
    private var desiredGrid: TerminalGrid
    /// The last grid actually written as an `R` frame, so a redundant resize
    /// isn't re-sent while the daemon is still applying the first one.
    private var sentGrid: TerminalGrid?
    /// The PTY's real size, from `attached` and then every `E resized`. This is
    /// the authority — §C.5: a client that parses at its own window size instead
    /// of this one wraps the same bytes differently and diverges from the host.
    private var authoritativeGrid: TerminalGrid?
    /// Set on any deliberate teardown so the reader's EOF is not misread as a
    /// daemon crash.
    private var closed = false
    private var exitDelivered = false

    /// Raw PTY bytes from the daemon — fed to the surface exactly where
    /// `PTYProcess`'s read pump delivers on the in-process path. Called on the
    /// reader thread; the consumer (`InMemoryTerminalSession.receive`) is
    /// thread-safe.
    var onOutput: ((Data) -> Void)?
    /// Fired on the main queue once the handshake reveals which device this
    /// session actually runs on. A session knows its *route* from the start but
    /// cannot know its *device* until something answers — this is that moment.
    var onDevice: ((TermiodDevice) -> Void)?
    /// Fired once on the main queue with the exit status and elapsed
    /// milliseconds since this link started (the daemon does not report the
    /// child's true runtime; elapsed-since-attach serves ghostty's
    /// abnormal-exit heuristic the same way).
    var onExit: ((Int32, UInt64) -> Void)?
    /// The session's workstream status as the host reports it (`working`,
    /// `needs_you`, …) with the workstream title when one rides along. Fired on
    /// the main queue for every `E status`.
    ///
    /// This is the only status channel a *remote* agent has: hooks on a VPS
    /// cannot reach this Mac's control socket, so they report to the daemon that
    /// owns the session and it fans the event down every attachment. The host
    /// names the state and nothing more — which dot, which words, and whether a
    /// notification fires stay entirely on this side.
    var onStatus: ((Termiod.StatusPayload) -> Void)?
    /// Whether this client currently holds the write token, on the main queue,
    /// on every genuine change. The link already gates its own `R` frames on
    /// this; the callback is for the UI that has to say "read-only" out loud.
    var onWriter: ((Bool) -> Void)?

    init(sessionName: String,
         specification: Termiod.CreateSpecification,
         route: TermiodRoute = .local,
         rows: Int,
         cols: Int) {
        self.sessionName = sessionName
        self.specification = specification
        self.route = route
        desiredGrid = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: cols))
    }

    /// Kicks off connect → hello → attach in the background. The caller wires
    /// `onOutput`/`onExit` first; input arriving meanwhile is buffered.
    func start() {
        workQueue.async { [self] in
            do {
                let channel = try Termiod.Transport.open(route)
                transport = channel
                let handshake = try Termiod.performHello(
                    channel, role: "attach", caps: Termiod.attachCapabilities)
                clientID = handshake.clientID
                let device = handshake.device
                DispatchQueue.main.async { [self] in onDevice?(device) }
                let requested = desiredGrid
                let payload = try Termiod.attachPayload(
                    target: sessionName,
                    specification: specification,
                    rows: requested.rows,
                    cols: requested.cols
                )
                try Termiod.writeFrame(channel.writeDescriptor, kind: .control, payload: payload)
                let reply = try Termiod.readFrame(channel.readDescriptor)
                guard reply.kind == .control,
                      case .attached(let attachedPayload) = try Termiod.decodeControl(reply.payload)
                else {
                    throw TermiodClientError.handshakeRejected("attach was not acknowledged")
                }
                attached = true
                isWriter = attachedPayload.writer
                // `attached` reports the session's size *before* this attach is
                // applied; the daemon then resizes to what a writer asked for and
                // announces it as `E resized`. Seeding from the reply means an
                // observer — which never triggers that resize — still knows the
                // grid its bytes are wrapped at.
                authoritativeGrid = TerminalGrid(
                    rows: attachedPayload.rows, cols: attachedPayload.cols)
                if isWriter { sentGrid = requested }
                Log.termiod.info("""
                attached session=\(self.sessionName, privacy: .public) \
                device=\(device.id, privacy: .public) \
                route=\(self.route.description, privacy: .public) \
                writer=\(attachedPayload.writer, privacy: .public) \
                caps=\(handshake.capabilities.sorted().joined(separator: ","), privacy: .public) \
                \(attachedPayload.rows, privacy: .public)x\(attachedPayload.cols, privacy: .public)
                """)
                // Only a writer may inject the keystrokes buffered during connect;
                // an observer's input would be rejected frame-by-frame by the
                // daemon. (This client always attaches `interact` today, so it is
                // normally the writer — this keeps it correct if observe is used.)
                if isWriter, !pendingInput.isEmpty {
                    try sendDataLocked(pendingInput)
                }
                pendingInput.removeAll(keepingCapacity: false)
                startReader(channel.readDescriptor)
            } catch {
                Log.termiod.error("""
                attach session=\(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
                teardownLocked()
                deliverExitLocked(status: 1)
            }
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        workQueue.async { [self] in
            guard !closed else { return }
            guard attached else {
                pendingInput.append(data)
                return
            }
            do {
                try sendDataLocked(data)
            } catch {
                Log.termiod.error("""
                input write to \(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    func resize(rows: Int, cols: Int) {
        let size = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: cols))
        workQueue.async { [self] in
            guard !closed else { return }
            desiredGrid = size
            guard attached else { return }
            // Observers must not resize the shared PTY out from under the
            // writer; the daemon would reject the frame anyway.
            guard isWriter else { return }
            do {
                try sendResizeLocked(size)
            } catch {
                Log.termiod.error("""
                resize of \(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    /// Writes one `R` frame, unless the PTY is already that size and nothing
    /// else is in flight. The skip is not a micro-optimisation: a resize is a
    /// **barrier** host-side (§C.5) — the session quiesces, resizes, and emits a
    /// fresh `S` keyframe to every attachment — so re-asserting a size the PTY
    /// already has costs a full repaint for every viewer.
    ///
    /// Must run on `workQueue`.
    private func sendResizeLocked(_ size: TerminalGrid) throws {
        guard let transport else { return }
        // Confirmed at this size, and nothing else on the wire that would move
        // it away: the frame would be a pure no-op with a repaint attached.
        if authoritativeGrid == size, sentGrid == nil || sentGrid == size { return }
        sentGrid = size
        try Termiod.writeFrame(transport.writeDescriptor, kind: .resize,
                               payload: Self.resizePayload(size.rows, size.cols))
    }

    /// Leaves the stream but keeps the session alive in the daemon — the
    /// app-quit and surface-teardown path. Synchronous so `applicationWillTerminate`
    /// can rely on the detach frame being out before the process dies.
    func detach() {
        workQueue.sync { [self] in
            guard !closed, let transport else {
                closed = true
                return
            }
            if let payload = try? Termiod.detachPayload() {
                try? Termiod.writeFrame(transport.writeDescriptor, kind: .control, payload: payload)
            }
            teardownLocked()
        }
    }

    /// The destroy verb: asks the daemon to kill the session, then closes.
    func killAndClose() {
        Termiod.killSession(target: sessionName, route: route)
        workQueue.async { [self] in
            teardownLocked()
        }
    }

    private func sendDataLocked(_ data: Data) throws {
        guard let transport else { return }
        var offset = 0
        while offset < data.count {
            let end = min(offset + Termiod.maximumDataFrameSize, data.count)
            try Termiod.writeFrame(transport.writeDescriptor, kind: .data,
                                   payload: data.subdata(in: offset ..< end))
            offset = end
        }
    }

    private static func resizePayload(_ rows: UInt16, _ cols: UInt16) -> Data {
        var payload = Data(capacity: 4)
        var bigEndianRows = rows.bigEndian
        var bigEndianCols = cols.bigEndian
        withUnsafeBytes(of: &bigEndianRows) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bigEndianCols) { payload.append(contentsOf: $0) }
        return payload
    }

    private func teardownLocked() {
        closed = true
        transport?.close()
        transport = nil
    }

    /// Must run on `workQueue` — `exitDelivered` is queue-confined state.
    private func deliverExitLocked(status: Int32) {
        guard !exitDelivered else { return }
        exitDelivered = true
        let runtimeMilliseconds = UInt64(max(0, Date().timeIntervalSince(startedAt) * 1000))
        DispatchQueue.main.async { [self] in
            onExit?(status, runtimeMilliseconds)
        }
    }

    /// Dedicated blocking-read thread (the frame stream has no natural
    /// dispatch-source shape once payloads span multiple reads). Ends on EOF,
    /// error, or the session's exit notice.
    private func startReader(_ socket: Int32) {
        let thread = Thread { [weak self] in
            // A frame kind this client never negotiated is a host bug, not
            // traffic — logged once per kind so a misbehaving daemon is visible
            // without a stream of identical lines.
            var reportedUnexpected = Set<Termiod.FrameKind>()
            while true {
                let frame: (kind: Termiod.FrameKind, payload: Data)
                do {
                    frame = try Termiod.readFrame(socket)
                } catch {
                    self?.handleStreamEnd()
                    return
                }
                guard let self else { return }
                switch frame.kind {
                case .data:
                    self.onOutput?(frame.payload)
                case .snapshot:
                    // The daemon guarantees `S` before any post-attach `D`, and
                    // this reader is a single serial thread: synthesising the
                    // repaint and emitting it here — before the next `readFrame`
                    // pulls the first live `D` — preserves S-before-D through
                    // the same `onOutput` seam, with no hold-back buffer needed.
                    // A mid-session `S` (the resize barrier's fresh keyframe)
                    // takes the same path and repaints idempotently.
                    if let repaint = TermiodSnapshot.decode(frame.payload)
                        .map(TermiodSnapshot.render) {
                        self.onOutput?(repaint)
                    } else {
                        Log.termiod.error("""
                        undecodable snapshot frame on \(self.sessionName, privacy: .public)
                        """)
                    }
                case .control:
                    if self.handleControl(frame.payload) { return }
                case .event:
                    if self.handleEvent(frame.payload) { return }
                case .file, .upload:
                    // `F`/`U` never ride an attach channel at all — transfers use
                    // their own control channel, so the hot path stays raw.
                    break
                case .resize, .history, .grid:
                    // `R` is client-to-host only, and `H`/`G` require the
                    // `scrollback`/`grid_diff` capabilities this client
                    // deliberately does not offer (see `attachCapabilities`).
                    // Receiving one means the host sent a frame nobody asked
                    // for — say so instead of dropping it silently.
                    if reportedUnexpected.insert(frame.kind).inserted {
                        Log.termiod.error("""
                        unnegotiated \(String(UnicodeScalar(frame.kind.rawValue)), privacy: .public) \
                        frame on \(self.sessionName, privacy: .public) — ignored
                        """)
                    }
                }
            }
        }
        thread.name = "termiod-read-\(sessionName.prefix(8))"
        thread.start()
    }

    /// Returns true when the reader should stop (the session is over).
    private func handleControl(_ payload: Data) -> Bool {
        let control: Termiod.IncomingControl
        do {
            control = try Termiod.decodeControl(payload)
        } catch {
            Log.termiod.error("""
            undecodable control frame on \(self.sessionName, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
            return false
        }
        switch control {
        case .exited(let exit):
            workQueue.async { [self] in
                teardownLocked()
                deliverExitLocked(status: exit.status)
            }
            return true
        case .resizeClaim(let claim):
            applyWriter(claim.writer)
            return false
        case .error(let failure):
            Log.termiod.error("""
            daemon error on \(self.sessionName, privacy: .public): \
            \(failure.message, privacy: .public)
            """)
            return false
        default:
            return false
        }
    }

    /// Routes one `E` frame. Returns true when the reader should stop.
    ///
    /// Unlocked by the `events` capability, and each arm is why it is offered:
    /// `status` is the product's core signal (an agent on a VPS has no other way
    /// to reach this Mac), `writer_changed` keeps write gating honest as the
    /// token moves, and `resized` carries the authoritative dimensions §C.5
    /// requires every client to know.
    private func handleEvent(_ payload: Data) -> Bool {
        let event: Termiod.IncomingEvent
        do {
            event = try Termiod.decodeEvent(payload)
        } catch {
            Log.termiod.error("""
            undecodable event frame on \(self.sessionName, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
            return false
        }
        switch event {
        case .status(let status):
            DispatchQueue.main.async { [self] in onStatus?(status) }
        case .writerChanged(let change):
            applyWriter(change.writer)
        case .resized(let size):
            applyAuthoritativeGrid(TerminalGrid(rows: size.rows, cols: size.cols))
        case .sessionExited(let exit):
            // The `exited` control frame says the same thing and normally lands
            // first; both funnel into the same idempotent delivery, so whichever
            // arrives is enough and neither can double-report.
            workQueue.async { [self] in
                teardownLocked()
                deliverExitLocked(status: exit.status)
            }
            return true
        case .ready:
            // Snapshot-complete. No action: this reader is serial, so `S` has
            // already been rendered by the time this frame is read.
            break
        case .unknown(let name):
            Log.termiod.debug("""
            ignoring \(name, privacy: .public) event on \(self.sessionName, privacy: .public)
            """)
        }
        return false
    }

    /// Applies a writer-token change. The daemon names the writer by client id,
    /// so this is the one comparison that tells this connection whether its `D`
    /// and `R` frames will be honoured or answered with `not_writer`.
    ///
    /// Promotion re-asserts the grid: a client that was demoted stopped sending
    /// resizes, so the PTY can be any size by the time the token comes back.
    private func applyWriter(_ writer: String?) {
        workQueue.async { [self] in
            guard !closed else { return }
            let mine = writer != nil && writer == clientID
            guard mine != isWriter else { return }
            isWriter = mine
            Log.termiod.info("""
            write token on \(self.sessionName, privacy: .public) \
            \(mine ? "claimed" : "lost", privacy: .public)
            """)
            if mine {
                do {
                    try sendResizeLocked(desiredGrid)
                } catch {
                    Log.termiod.error("""
                    reclaiming size on \(self.sessionName, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                }
            }
            DispatchQueue.main.async { [self] in onWriter?(mine) }
        }
    }

    /// Records the PTY's real size. Two things read it: `sendResizeLocked`, so a
    /// size the PTY already has never costs a barrier repaint, and the check
    /// below — the PTY only diverges from what this client asked for when
    /// another client owns the token, and that is the §C.5 case where this
    /// window is wrapping bytes at the wrong width. Letterboxing the viewport
    /// against it is the client-side step this foundation leaves open.
    private func applyAuthoritativeGrid(_ grid: TerminalGrid) {
        workQueue.async { [self] in
            guard authoritativeGrid != grid else { return }
            authoritativeGrid = grid
            guard grid != desiredGrid else { return }
            Log.termiod.info("""
            \(self.sessionName, privacy: .public) PTY is now \
            \(grid.rows, privacy: .public)x\(grid.cols, privacy: .public); \
            this client renders \
            \(self.desiredGrid.rows, privacy: .public)x\(self.desiredGrid.cols, privacy: .public)
            """)
        }
    }

    /// EOF or read error. After a deliberate detach/kill this is expected and
    /// silent; otherwise the daemon went away, and the session is marked
    /// exited so the pane doesn't sit live-looking but dead.
    private func handleStreamEnd() {
        workQueue.async { [self] in
            let wasDeliberate = closed
            teardownLocked()
            guard !wasDeliberate else { return }
            Log.termiod.error("connection to \(self.sessionName, privacy: .public) ended unexpectedly")
            deliverExitLocked(status: 1)
        }
    }
}
