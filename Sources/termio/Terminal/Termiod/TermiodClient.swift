import CryptoKit
import Darwin
import Foundation
import TermioShared

/// Attach client for the local `termiod` session host (Session Protocol v0.1,
/// see termiod/src/protocol.rs). The
/// app stops owning PTYs itself: every session lives inside the daemon, the app
/// merely attaches over the Unix socket, and quitting detaches instead of
/// killing — which is what lets sessions survive an app quit or self-update.
///
/// This is the Mac's half: where a daemon lives, how to reach it, and what to
/// do with what it says. The framing, the payload types and the encode/decode
/// tables are the protocol itself and live in `TermioShared`
/// (`Termiod.swift`), so the phone attaches over the same codec instead
/// of a second copy of it.
extension Termiod {
    /// The client banner this app puts in every `hello`.
    static let clientBanner = "termio-mac/dev"

    /// Mirrors termiod/src/paths.rs exactly — both sides must derive the same
    /// socket or the app talks to a different daemon than the CLI:
    /// `TERMIOD_SOCK` override, else `$XDG_RUNTIME_DIR/termiod[-channel]/`, else
    /// a uid-scoped directory under the temp dir (`$TMPDIR`, else `/tmp` — the
    /// same fallback order as Rust's `std::env::temp_dir()`).
    ///
    /// Scoped by channel as well as by uid. The daemon's whole session table
    /// hangs off this one path — `state_dir()` in Rust is the socket's own
    /// directory — so an unscoped socket makes a dev build and the release app
    /// **one device**: they share `host.id`, each is handed the other's roster,
    /// and each can kill what the other is running. The release channel's
    /// suffix is empty, so its path is unchanged and its sessions survive this.
    static func socketPath() -> String {
        socketPath(channelSuffix: AppChannel.suffix,
                   environment: ProcessInfo.processInfo.environment)
    }

    /// Separate from the caller above so the derivation can be tested without a
    /// bundle and for a channel this process is not running on. The mirror to
    /// `termiod/src/paths.rs` is exactly the kind of agreement that drifts
    /// silently: nothing fails to build when the two sides disagree, the app
    /// just starts talking to a daemon nobody else can see.
    static func socketPath(channelSuffix: String, environment: [String: String]) -> String {
        if let explicit = environment["TERMIOD_SOCK"], !explicit.isEmpty {
            return explicit
        }
        if let runtimeDirectory = environment["XDG_RUNTIME_DIR"], !runtimeDirectory.isEmpty {
            return runtimeDirectory + "/termiod\(channelSuffix)/termiod.sock"
        }
        let temporaryDirectory = environment["TMPDIR"] ?? "/tmp"
        let base = temporaryDirectory.hasSuffix("/")
            ? String(temporaryDirectory.dropLast())
            : temporaryDirectory
        return "\(base)/termiod-\(getuid())\(channelSuffix)/termiod.sock"
    }

    /// The directory the daemon keeps everything that belongs to *one host* in
    /// — `host.id`, the pairing token, the durable wss settings. Mirrors
    /// `durable_state_dir()` in termiod/src/paths.rs: on macOS that is
    /// `~/Library/Application Support/termio<suffix>`, deliberately not the
    /// socket's temp directory, which the OS may clear and a reboot forgets.
    /// A `TERMIOD_SOCK` override keeps it beside the socket — the same
    /// isolation rule the Rust side follows for a daemon pointed at its own
    /// socket.
    static func durableStateDirectory() -> String {
        durableStateDirectory(channelSuffix: AppChannel.suffix,
                              environment: ProcessInfo.processInfo.environment,
                              home: NSHomeDirectory())
    }

    /// Separate from the caller above for the same reason as `socketPath`:
    /// the mirror to termiod/src/paths.rs drifts silently, so it has to be
    /// testable without a bundle.
    static func durableStateDirectory(channelSuffix: String,
                                      environment: [String: String],
                                      home: String) -> String {
        if let explicit = environment["TERMIOD_SOCK"], !explicit.isEmpty {
            return (explicit as NSString).deletingLastPathComponent
        }
        return home + "/Library/Application Support/termio" + channelSuffix
    }

    /// The pairing secret that authenticates a WebSocket pipe to this daemon —
    /// never the session write token that arbitrates who may type.
    ///
    /// Read from disk on every call rather than cached, the way `wss.rs` reads
    /// it per handshake: `termiod pair --rotate` has to sign paired phones out
    /// on their next dial, and a cached copy would keep letting them in until
    /// the app was relaunched. nil means nothing has ever paired with this
    /// daemon.
    /// The socket-side path is a fallback, not a second home: a daemon from
    /// before the durable split keeps its token beside the socket until its
    /// next start adopts it, and pairing must keep working across that window.
    static func pairToken() -> String? {
        if let token = readToken(at: durableStateDirectory() + "/pair.token") {
            return token
        }
        return readToken(at: (socketPath() as NSString).deletingLastPathComponent + "/pair.token")
    }

    private static func readToken(at path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// What to hand the daemon as `TERMIO_CHANNEL` so it derives the same socket
    /// this app just did. Spelled out even for the release channel: the daemon
    /// may be spawned from a process that already has the variable set to
    /// something else, and inheriting that would send it elsewhere.
    static var channelName: String {
        AppChannel.suffix.isEmpty ? "release" : String(AppChannel.suffix.dropFirst())
    }

    /// The daemon's name inside the bundle. Unlike the `termio` CLI it is not
    /// renamed per channel: the CLI is symlinked onto PATH, where a dev copy
    /// would clobber the release one, while the daemon is only ever executed by
    /// absolute path out of the bundle that ships it. (Keeping the two channels'
    /// *sessions* apart is the channel-scoped socket `socketPath()` derives, a
    /// separate axis from the binary's name.)
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

    /// Every `-o` this app puts on its own `ssh`, resolved once per host. Two
    /// concerns share one resolution because the `ssh -G` probe behind it forks
    /// and this sits on the path that opens a session.
    ///
    /// **Multiplexing** makes the connection a resource this app holds rather
    /// than one it re-establishes per session. Without a master, every session
    /// and every reconnect pays a full TCP handshake plus SSH key exchange —
    /// measured at 230–300 ms against a VPS, against 26–33 ms once a master
    /// exists.
    ///
    /// **`BatchMode` and `ConnectTimeout`** are what every other ssh call site
    /// in the app already sets and this one did not. Nobody can answer a prompt
    /// on this channel: the child's stdin is the framed protocol pipe, and ssh
    /// asks for a key passphrase on `/dev/tty` — which is whatever terminal
    /// launched the app and is not watching it, or nothing at all under Finder.
    /// A passphrase-protected key with no agent loaded therefore either blocked
    /// on that read with no timeout (still hung past 20 s on OpenSSH 10.2p1) or
    /// failed for a reason the attach never saw. `BatchMode=yes` makes it exit
    /// 255 with "Permission denied" in about a second, and `ConnectTimeout`
    /// bounds the separate case of a host that swallows the connect and never
    /// answers.
    ///
    /// A command-line `-o` outranks `~/.ssh/config`, so nothing is injected
    /// where the user already answered the question: not multiplexing when they
    /// configured either half of it, and not a timeout when they chose one for a
    /// slow link. `BatchMode` is the exception and goes on unconditionally —
    /// there is no reading of it under which a pipe nobody can type into should
    /// wait for someone to.
    static func sshArguments(host: String) -> [String] {
        if let cached = sshArgumentsLock.withLock({ sshArgumentsCache[host] }) {
            return cached
        }
        // The probe runs outside the lock (never hold a lock across a fork); a
        // rare duplicate lookup just recomputes the same answer.
        let options = effectiveSSHConfig(host: host).map(EffectiveSSHOptions.init(dump:))
        let resolved = sshArguments(options: options, controlPath: controlPath(for: host))
        sshArgumentsLock.withLock { sshArgumentsCache[host] = resolved }
        return resolved
    }

    private static let sshArgumentsLock = NSLock()
    /// `nonisolated(unsafe)` because every access goes through
    /// `sshArgumentsLock` above — the lock, not the actor, is what makes this
    /// safe, and the compiler cannot see that.
    nonisolated(unsafe) private static var sshArgumentsCache: [String: [String]] = [:]

    /// Matches the daemon's own ssh (`termiod/src/remote.rs`), so both roads
    /// to a host give up on the same clock.
    static let connectTimeoutSeconds = 10

    /// The argument list itself, taking what the probe found rather than
    /// running it, so the decisions above are checkable without an ssh on the
    /// machine. `options` is `nil` when `ssh -G` could not be read: only
    /// `BatchMode` survives that, because the rest would be overriding a config
    /// this process failed to read.
    static func sshArguments(options: EffectiveSSHOptions?, controlPath: String?) -> [String] {
        var arguments = ["-o", "BatchMode=yes"]
        guard let options else { return arguments }
        if !options.setsConnectTimeout {
            arguments += ["-o", "ConnectTimeout=\(connectTimeoutSeconds)"]
        }
        if options.leavesMultiplexingToUs, let controlPath {
            arguments += ["-o", "ControlMaster=auto",
                          "-o", "ControlPath=\(controlPath)",
                          "-o", "ControlPersist=10m"]
        }
        return arguments
    }

    /// `nil` when multiplexing has to be skipped for this host. A Unix socket
    /// path is capped at 104 bytes, and an over-long `ControlPath` makes ssh
    /// fail outright rather than degrade. An unusually long temporary directory
    /// must cost multiplexing, never the session.
    private static func controlPath(for host: String) -> String? {
        guard let directory = controlSocketDirectory() else { return nil }
        let path = directory.appendingPathComponent(controlSocketName(for: host)).path
        guard path.utf8.count < 100 else { return nil }
        return path
    }

    /// The three lines of `ssh -G <host>`'s fully-resolved config that decide
    /// whether an option is ours to set. Parsing is separate from the fork that
    /// produces the dump so it can be tested against real OpenSSH output.
    struct EffectiveSSHOptions {
        /// The user configured neither half of multiplexing. `false` and `none`
        /// are what OpenSSH prints for those defaults.
        let leavesMultiplexingToUs: Bool
        /// The user chose a connect timeout, whatever it is; OpenSSH prints
        /// `connecttimeout none` when nobody has.
        let setsConnectTimeout: Bool

        init(dump: String) {
            var master: String?
            var path: String?
            var timeout: String?
            for line in dump.split(separator: "\n") {
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2 else { continue }
                let value = fields[1].trimmingCharacters(in: .whitespaces).lowercased()
                switch fields[0].lowercased() {
                case "controlmaster": master = value
                case "controlpath": path = value
                case "connecttimeout": timeout = value
                default: continue
                }
            }
            // A missing `controlmaster` line means an OpenSSH too old to be read
            // this way, so leave its config alone. `connecttimeout` reads the
            // same way: absent means unreadable, and unreadable keeps the
            // decision with the config.
            let masterIsOurs = master.map { ["false", "no", "none"].contains($0) } ?? false
            // OpenSSH omits `controlpath` entirely when it is unset (confirmed on
            // 10.2p1) where older versions print `none`; both mean the user has
            // chosen no path. Requiring the line to be present made this whole
            // check answer "no" on a current macOS, which is a silent no-op —
            // the exact failure this is meant to end.
            let pathIsOurs = path == nil || path == "none"
            leavesMultiplexingToUs = masterIsOurs && pathIsOurs
            setsConnectTimeout = timeout != "none"
        }
    }

    /// `ssh -G <host>` prints the config every option resolves to for that host.
    /// `nil` when it could not be run or exited non-zero, which is what stops a
    /// broken probe from smuggling options past a config it could not read.
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
        /// What the ssh child said on stderr, for the moment its stdout closes
        /// without explanation. `nil` on the local socket, which has no child
        /// and no stderr to keep.
        private let stderrTail: StderrTail?

        private init(readDescriptor: Int32, writeDescriptor: Int32,
                     route: TermiodRoute, sshPid: pid_t?,
                     stderrTail: StderrTail? = nil) {
            self.readDescriptor = readDescriptor
            self.writeDescriptor = writeDescriptor
            self.route = route
            self.sshPid = sshPid
            self.stderrTail = stderrTail
            Transport.suppressSignalOnBrokenPipe(writeDescriptor)
        }

        /// The same failure, explained when it can be. A connection that closed
        /// or lost frame alignment on the SSH road usually means the child
        /// exited with its reason on stderr — "Permission denied", "No such
        /// file or directory" — and the generic error is what issue #498 looks
        /// like from the outside: "my ssh works, Termio says the connection
        /// closed". Every other error already names its cause and passes
        /// through untouched.
        ///
        /// For a closed connection the child has (all but) exited, so this
        /// waits briefly for its stderr to finish; a torn frame leaves the
        /// child alive, so only what has already arrived is consulted.
        func explained(_ error: TermiodClientError) -> TermiodClientError {
            guard let stderrTail else { return error }
            let words: String
            switch error {
            case .connectionClosed:
                words = stderrTail.contents(waitingUpTo: .milliseconds(500))
            case .malformedFrame:
                words = stderrTail.contents(waitingUpTo: .zero)
            default:
                return error
            }
            guard let reason = Termiod.remoteFailureDiagnosis(stderr: words) else {
                return error
            }
            return .remoteFailed(reason)
        }

        /// Makes a write to a hung-up peer return `EPIPE` instead of raising
        /// `SIGPIPE`, whose default disposition kills the process.
        ///
        /// A channel opened for one request could barely hit this — the pipe was
        /// seconds old. A pooled one is held across a laptop sleeping, a VPS
        /// rebooting and `ControlPersist` reaping the master, so discovering the
        /// far end is gone *on the way out* is an ordinary Tuesday. The control
        /// socket in `SessionControl.swift` already learned this; the transport
        /// had not needed to.
        ///
        /// Two calls because the two roads produce different objects: `.local` is
        /// a socket, where `SO_NOSIGPIPE` is the switch, and `.ssh` is a pipe,
        /// where it is the `F_SETNOSIGPIPE` descriptor flag. Each is a no-op on
        /// the other, so both go on unconditionally.
        private static func suppressSignalOnBrokenPipe(_ descriptor: Int32) {
            var on: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on,
                           socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
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
            var errorPipe = [Int32](repeating: -1, count: 2) // child stderr [1] → tail reads [0]
            guard pipe(&toChild) == 0 else {
                throw TermiodClientError.daemonUnreachable("ssh:\(host)")
            }
            // Close the earlier pairs before bailing, or a later-pipe failure
            // (most likely under fd exhaustion — exactly when it happens) leaks
            // their fds.
            guard pipe(&fromChild) == 0 else {
                Darwin.close(toChild[0])
                Darwin.close(toChild[1])
                throw TermiodClientError.daemonUnreachable("ssh:\(host)")
            }
            guard pipe(&errorPipe) == 0 else {
                Darwin.close(toChild[0])
                Darwin.close(toChild[1])
                Darwin.close(fromChild[0])
                Darwin.close(fromChild[1])
                throw TermiodClientError.daemonUnreachable("ssh:\(host)")
            }

            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            posix_spawn_file_actions_adddup2(&fileActions, toChild[0], 0)
            posix_spawn_file_actions_adddup2(&fileActions, fromChild[1], 1)
            // stderr is captured, not inherited: it is the only witness when
            // ssh dies before the handshake, and inherited it went to a console
            // nobody reads while the UI showed a generic "connection closed".
            posix_spawn_file_actions_adddup2(&fileActions, errorPipe[1], 2)
            // Close the pipe ends the child must not keep open.
            posix_spawn_file_actions_addclose(&fileActions, toChild[1])
            posix_spawn_file_actions_addclose(&fileActions, fromChild[0])
            posix_spawn_file_actions_addclose(&fileActions, errorPipe[0])

            let command = "\(remoteBinary()) stdio"
            let arguments = ["ssh", "-o", "ServerAliveInterval=15"]
                + sshArguments(host: host)
                + [host, command]
            let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }

            var pid: pid_t = 0
            let status = posix_spawnp(&pid, "ssh", &fileActions, nil, argv, environ)
            Darwin.close(toChild[0])
            Darwin.close(fromChild[1])
            Darwin.close(errorPipe[1])
            guard status == 0 else {
                Darwin.close(toChild[1])
                Darwin.close(fromChild[0])
                Darwin.close(errorPipe[0])
                throw TermiodClientError.daemonSpawnFailed(status)
            }
            return Transport(readDescriptor: fromChild[0], writeDescriptor: toChild[1],
                             route: .ssh(host), sshPid: pid,
                             stderrTail: StderrTail(descriptor: errorPipe[0]))
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

    /// The last of what an ssh child wrote to stderr, kept so a pipe that
    /// closes without a handshake can say why.
    ///
    /// A dedicated reader thread drains the pipe for the child's whole life —
    /// draining is not optional, since a child blocked on a full stderr pipe
    /// would wedge the connection it narrates — but only the newest 4KB are
    /// kept: the diagnosis is the last line, not the transcript.
    ///
    /// `@unchecked Sendable` because every access to the buffer goes through
    /// `condition`; the lock, not the type system, is what makes this safe.
    final class StderrTail: @unchecked Sendable {
        private let condition = NSCondition()
        private var buffer = Data()
        private var finished = false

        private static let keep = 4096

        init(descriptor: Int32) {
            let thread = Thread {
                var chunk = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = read(descriptor, &chunk, chunk.count)
                    if count > 0 {
                        self.condition.lock()
                        self.buffer.append(contentsOf: chunk[0 ..< count])
                        if self.buffer.count > Self.keep {
                            self.buffer.removeFirst(self.buffer.count - Self.keep)
                        }
                        self.condition.unlock()
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                Darwin.close(descriptor)
                self.condition.lock()
                self.finished = true
                self.condition.broadcast()
                self.condition.unlock()
            }
            thread.name = "sh.termio.termiod.stderr"
            thread.stackSize = 128 * 1024
            thread.start()
        }

        /// Everything kept so far, after giving the child up to `patience` to
        /// finish saying it. The wait matters on the closed-connection path:
        /// stdout's EOF and stderr's last line race out of a dying ssh, and
        /// asking at the instant of the EOF would routinely read an empty pipe
        /// that is one scheduler tick from holding the answer.
        func contents(waitingUpTo patience: Duration) -> String {
            condition.lock()
            defer { condition.unlock() }
            if !finished, patience > .zero {
                let deadline = Date().addingTimeInterval(
                    Double(patience.components.seconds)
                        + Double(patience.components.attoseconds) / 1e18)
                while !finished, condition.wait(until: deadline) {}
            }
            return String(decoding: buffer, as: UTF8.self)
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
        //
        // The channel is the one part it cannot inherit: this app reads its own
        // off its bundle identifier, and a spawned binary has no way to see
        // that. Passing it explicitly is what keeps a dev build's daemon off the
        // release channel's socket — without it both apps land on the same
        // session table and each is handed the other's sessions to draw and to
        // kill. Set even for the release channel, so a stale `TERMIO_CHANNEL`
        // inherited from whatever launched the app cannot redirect the daemon.
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["TERMIO_CHANNEL"] = channelName
        let argumentStrings = [binary, "serve"]
        let argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            childEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, binary, &fileActions, &attributes, argv, envp)
        guard status == 0 else {
            throw TermiodClientError.daemonSpawnFailed(status)
        }
        reapWhenItExits(pid)
    }

    /// Collect the daemon's exit status whenever it comes.
    ///
    /// `POSIX_SPAWN_SETSID` detaches the session, not the parentage: the daemon
    /// stays this app's child, and a child nobody waits on becomes a zombie the
    /// moment it exits — one whose pid `kill(pid, 0)` keeps answering for. That
    /// is what `termiod stop` used to read as a daemon refusing to leave (#571),
    /// and it lasted as long as the app did. The daemon this waits on outlives
    /// most launches, so the wait cannot be a parked thread.
    private static func reapWhenItExits(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            var ignored: Int32 = 0
            _ = waitpid(pid, &ignored, WNOHANG)
            source.cancel()
        }
        source.resume()
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
        /// The account's home directory on that machine, or `/` when the daemon
        /// did not say — old enough not to send it, or unable to read `HOME`.
        /// Never empty, so a picker always has somewhere to start.
        let home: String
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
        let hello = try helloPayload(role: role, caps: caps, client: clientBanner)
        try writeFrame(transport.writeDescriptor, kind: .control, payload: hello)
        let reply = try readFrame(transport.readDescriptor)
        guard reply.kind == .control else { throw TermiodClientError.malformedFrame }
        switch try decodeControl(reply.payload) {
        case .helloOk(let payload):
            // The build stamp when the daemon has one; the banner it has always
            // sent (`termiod/0.1.0 linux-aarch64`) for one that predates it.
            let device = TermiodDeviceRegistry.shared.record(
                hostID: payload.hostId, daemonVersion: payload.version ?? payload.host,
                negotiatedProtocol: payload.proto, route: transport.route)
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
                device: device, clientID: payload.clientId, capabilities: Set(payload.caps),
                home: payload.homeDirectory)
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
        do {
            let handshake = try performHello(transport, role: "control", caps: caps)
            return try body(transport, handshake)
        } catch let error as TermiodClientError {
            throw transport.explained(error)
        }
    }

    /// Connect, shake hands, hang up: the cheapest question you can ask a route,
    /// and the only way to learn which device is behind it. Measured at 0.2 ms
    /// locally, so it is affordable to ask before trusting a stale mapping.
    @discardableResult
    static func probeDevice(route: TermiodRoute) throws -> TermiodDevice {
        let transport = try Transport.open(route)
        defer { transport.close() }
        do {
            return try performHello(transport, role: "control").device
        } catch let error as TermiodClientError {
            throw transport.explained(error)
        }
    }

    /// The capability the agent plane rides on. A daemon that predates it
    /// cannot install, and says so at the handshake rather than at the write —
    /// which is what turns version skew into a sentence instead of a no-op.
    static let agentCapability = "agents"

    /// Install (or remove) termio's agent integration on the machine this route
    /// reaches. One round trip for the whole roster.
    static func installAgents(
        route: TermiodRoute,
        agents: [String]?,
        hooks: Termiod.AgentHalfAction,
        skills: Termiod.AgentHalfAction,
        reporter: Termiod.AgentHookReporter,
        hookVersion: String
    ) throws -> [Termiod.AgentInstallResult] {
        try withControlChannel(route: route, caps: [agentCapability]) { transport, handshake in
            guard handshake.capabilities.contains(agentCapability) else {
                throw TermiodClientError.requestFailed(
                    localized("This device’s termiod is too old to install agent integration."))
            }
            try writeFrame(
                transport.writeDescriptor, kind: .control,
                payload: installAgentsPayload(
                    agents: agents, hooks: hooks, skills: skills,
                    reporter: reporter, hookVersion: hookVersion))
            while true {
                let frame = try readFrame(transport.readDescriptor)
                guard frame.kind == .control else { continue }
                switch try decodeControl(frame.payload) {
                case .agentsInstalled(let payload):
                    return payload.results
                case .error(let payload):
                    throw TermiodClientError.requestFailed(payload.message)
                default:
                    continue
                }
            }
        }
    }

    /// Which of these agents' CLIs are on that machine. One round trip for the
    /// whole roster, where the SSH arm paid one per agent.
    static func probeAgents(
        route: TermiodRoute, agents: [String]?
    ) throws -> [Termiod.AgentPresence] {
        try withControlChannel(route: route, caps: [agentCapability]) { transport, handshake in
            guard handshake.capabilities.contains(agentCapability) else {
                throw TermiodClientError.requestFailed(
                    localized("This device’s termiod is too old to report its agents."))
            }
            try writeFrame(
                transport.writeDescriptor, kind: .control,
                payload: probeAgentsPayload(agents: agents))
            while true {
                let frame = try readFrame(transport.readDescriptor)
                guard frame.kind == .control else { continue }
                switch try decodeControl(frame.payload) {
                case .agentsProbed(let payload):
                    return payload.agents
                case .error(let payload):
                    throw TermiodClientError.requestFailed(payload.message)
                default:
                    continue
                }
            }
        }
    }

    /// What `termiod deploy --json` left a machine as — the lifecycle loop's
    /// report (`termiod/src/lifecycle.rs`), read rather than reconstructed.
    /// The daemon runs the loop; this side only says what the state means.
    struct LifecycleReport: Decodable, Sendable {
        enum State: String, Decodable, Sendable {
            case current, staged, unhealthy, unreachable, failed
        }
        struct BusySession: Decodable, Sendable {
            let name: String
            let command: String
            let title: String?
            let status: String
            let running: Bool?

            /// What to call the session on a pane. The app names daemon
            /// sessions by its own UUIDs, which say nothing to a person; the
            /// agent's title does, and the command is the fallback.
            var label: String {
                if let title, !title.isEmpty { return title }
                return UUID(uuidString: name) == nil ? "\(name) — \(command)" : command
            }
        }
        let state: State
        let node: String
        let desired: String
        let version: String?
        let hostId: String?
        let newer: Bool?
        let daemon: String?
        let busy: [BusySession]?
        let message: String?
        let rolledBack: Bool?

        static func decode(_ data: Data) throws -> LifecycleReport {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(LifecycleReport.self, from: data)
        }
    }

    /// The daemon's answer to "what is running?" — which, to be honest, has to
    /// include what *was* running: a daemon that died takes every session with
    /// it, and a live list alone would report that as "nothing". The tombstones
    /// ride the same reply, so there is no second round trip and no window where
    /// the two disagree.
    static func roster(route: TermiodRoute = .local) throws -> SessionsPayload {
        try withControlChannel(route: route) { transport, _ in
            try writeFrame(transport.writeDescriptor, kind: .control, payload: listPayload())
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
    ///
    /// `completion` runs on the main queue once the daemon has answered, however
    /// it answered. A caller that shows the device's own roster needs it: asking
    /// for the roster before the kill lands would put the row straight back.
    static func killSession(
        target: String,
        route: TermiodRoute = .local,
        completion: (@Sendable @MainActor () -> Void)? = nil
    ) {
        DispatchQueue.global(qos: .utility).async {
            defer {
                if let completion {
                    DispatchQueue.main.async { MainActor.assumeIsolated(completion) }
                }
            }
            do {
                try withControlChannel(route: route) { transport, _ in
                    try writeFrame(transport.writeDescriptor, kind: .control,
                                   payload: killPayload(target: target))
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
    /// A `claim_writer` is outstanding, so further input must not send another.
    private var claimingWriter = false
    /// This connection's daemon-assigned id, from `hello_ok`. Without it a
    /// `writer_changed` naming `c_41` is unreadable — the whole point of the
    /// event is telling *this* client whether the token is still its.
    private var clientID: String?
    /// Keystrokes typed during the connect/attach window — flushed, in order,
    /// the moment the channel is writable so nothing the user typed is lost.
    private var pendingInput = Data()
    /// This attachment's viewport: how much of a session this pane could show,
    /// measured from the pane's own geometry rather than read back off the
    /// surface. The two are not the same thing once the surface is laid out at a
    /// smaller shared grid — a surface that reports the grid it was shrunk to is
    /// a pane that can never say it has room for more, and the session would
    /// never grow back.
    private var viewportGrid: TerminalGrid
    /// Whether this pane is on screen. A hidden pane keeps its viewport and
    /// stops counting toward the session's size, so a window left open on
    /// another workspace does not hold every session it has a pane for down to
    /// its own width.
    private var rendering = true
    /// The last viewport actually written as an `R` frame, so an unchanged
    /// declaration isn't re-sent while the daemon is still applying the first.
    private var sentViewport: (grid: TerminalGrid, rendering: Bool)?
    /// Bumped by every viewport change; only the newest scheduled send may write
    /// its frame. See `scheduleViewportLocked`.
    private var viewportGeneration: UInt64 = 0
    /// The grid libghostty says this surface is actually laid out at. Read only
    /// by the repaint arming below — it is never what goes on the wire.
    private var surfaceGrid: TerminalGrid
    /// Whether the daemon said it sizes sessions by policy. Without it this is
    /// an older host that reads `R` as "set the PTY size", and the five-byte
    /// form it has never seen would drop the connection.
    private var hostSizesByPolicy = false
    /// The PTY's real size, from `attached` and then every `E resized`. This is
    /// the authority — §C.5: a client that parses at its own window size instead
    /// of this one wraps the same bytes differently and diverges from the host.
    private var authoritativeGrid: TerminalGrid?
    /// A surface not yet laid out at the shared grid. The keyframe that
    /// announced the grid was parsed at the old one, and the surface is re-laid
    /// out only after `onSharedGrid` reaches the UI — so the first surface
    /// report that lands *on* the shared grid asks the daemon for a fresh
    /// keyframe, and that one paints right.
    ///
    /// Not gated on the write token any more. Under a size policy the writer's
    /// own surface is letterboxed too whenever somebody smaller is looking, and
    /// it needs the same repaint the observer always did.
    private var repaintPending = false
    /// Set on any deliberate teardown so the reader's EOF is not misread as a
    /// daemon crash.
    private var closed = false
    private var exitDelivered = false
    private var connectionLostDelivered = false
    private var startRefusedDelivered = false

    /// The last instant something was written toward the session's stdin. Its own
    /// lock, not the work queue, so the status tap can read it from the reader
    /// thread without a hop.
    private let inputLock = NSLock()
    private var lastInputAtLocked = Date.distantPast
    var lastInputAt: Date {
        inputLock.lock()
        defer { inputLock.unlock() }
        return lastInputAtLocked
    }

    /// The device's description of this session while it is **running**, from the
    /// last roster push — a cache of a push, so no fresher than the daemon's
    /// sampling cadence (`closeConfirmationReason` holds why that is acceptable).
    /// Its own lock rather than the work queue because the one caller that cannot
    /// wait — the close confirmation, asked on the main thread the instant the
    /// user clicks — must read it without a hop.
    private let informationLock = NSLock()
    private var latestInformationLocked: Termiod.SessionInformation?
    /// The device's final word, from the exit event. Kept **apart** from the live
    /// cache rather than overwriting it: it is recorded on the reader thread while
    /// the link is still registered, so merging the two would put a dead session's
    /// blank sample in front of a close confirmation about a running one.
    private var finalInformationLocked: Termiod.SessionInformation?

    /// What the device last said about this session while it was running. `nil`
    /// once nothing has pushed a roster row — never the exit row.
    var latestInformation: Termiod.SessionInformation? {
        informationLock.lock()
        defer { informationLock.unlock() }
        return latestInformationLocked
    }

    /// Raw PTY bytes from the daemon — fed to the surface exactly where
    /// `PTYProcess`'s read pump delivers on the in-process path. Called on the
    /// reader thread; the consumer (`InMemoryTerminalSession.receive`) is
    /// thread-safe.
    var onOutput: ((Data) -> Void)?
    /// Fired on the main queue once the handshake reveals which device this
    /// session actually runs on. A session knows its *route* from the start but
    /// cannot know its *device* until something answers — this is that moment.
    var onDevice: ((TermiodDevice) -> Void)?
    /// Fired on the main queue with the daemon's own id for the session this
    /// attach resolved to — minted fresh per creation, never reused. Captured
    /// off the attach reply so a respawn learns its new identity the moment the
    /// attach lands, not a roster refresh later: the closed-session journal
    /// records this id on destroy, and the window in which a close would
    /// journal a stale or missing one should be as small as the protocol allows.
    var onDaemonSessionID: ((String) -> Void)?
    /// Fired once on the main queue when the daemon **answered and refused** —
    /// a cwd that does not exist, a rejected handshake, a spawn it would not
    /// perform. Distinct from `onConnectionLost` because the daemon is right
    /// there and there is no session: telling the user their work is "still
    /// running" would be a different lie from the one this file set out to fix.
    /// Carries the daemon's own words, which name the cause.
    var onStartRefused: ((String) -> Void)?
    /// Fired once on the main queue when the *connection* ends without the
    /// session having ended: the daemon went away, the SSH pipe broke, the
    /// network dropped. Deliberately not `onExit` — the child is almost
    /// certainly still running, which is the entire point of it living in a
    /// daemon, and reporting an exit for it invents a status the process never
    /// produced and parks the pane over an error that does not exist.
    var onConnectionLost: (() -> Void)?
    /// Fired once on the main queue with the exit status, elapsed milliseconds
    /// since this link started (the daemon does not report the child's true
    /// runtime; elapsed-since-attach serves ghostty's abnormal-exit heuristic the
    /// same way), and the device's final word on the session when it sent one.
    var onExit: ((Int32, UInt64, Termiod.SessionInformation?) -> Void)?
    /// The device's revised description of this session, on the main queue, every
    /// time the daemon pushes one: foreground argv, the child's cwd, whether a job
    /// is running. Facts only — what they mean is decided on this side.
    var onInformation: ((Termiod.SessionInformation) -> Void)?
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
    /// The device's one `stalled` signal for this session. Watch-plane only —
    /// the status stays `working`, and the sidebar and menu bar are untouched.
    var onStalled: ((Termiod.StalledPayload) -> Void)?
    /// Whether this client currently holds the write token, on the main queue,
    /// on every genuine change. The link already gates its own `R` frames on
    /// this; the callback is for the UI that has to say "read-only" out loud.
    var onWriter: ((Bool) -> Void)?
    /// The PTY's actual grid, on the main queue: once from `attached` and then
    /// on every `E resized`. While another client holds the token this is the
    /// grid the bytes are wrapped for, and the surface that shows them has to
    /// be laid out at it — see `SessionRuntime.sharedGrid`.
    var onSharedGrid: ((TerminalGrid) -> Void)?

    init(sessionName: String,
         specification: Termiod.CreateSpecification,
         route: TermiodRoute = .local,
         rows: Int,
         cols: Int) {
        self.sessionName = sessionName
        self.specification = specification
        self.route = route
        let grid = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: cols))
        viewportGrid = grid
        surfaceGrid = grid
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
                hostSizesByPolicy = handshake.capabilities.contains(Termiod.viewportCapability)
                let device = handshake.device
                DispatchQueue.main.async { [self] in onDevice?(device) }
                let requested = viewportGrid
                let payload = try Termiod.attachPayload(
                    target: sessionName,
                    specification: specification,
                    rows: requested.rows,
                    cols: requested.cols
                )
                try Termiod.writeFrame(channel.writeDescriptor, kind: .control, payload: payload)
                let reply = try Termiod.readFrame(channel.readDescriptor)
                guard reply.kind == .control else {
                    throw TermiodClientError.handshakeRejected("attach was not acknowledged")
                }
                let acknowledgement = try Termiod.decodeControl(reply.payload)
                // A refusal names its own cause — the directory that is not
                // there, the spawn it would not perform. Carrying that message
                // instead of a generic one is the whole reason the refusal is
                // told apart from a lost connection: the pane can say *why*
                // rather than only that something failed.
                if case .error(let refusal) = acknowledgement {
                    throw TermiodClientError.requestFailed(refusal.message)
                }
                guard case .attached(let attachedPayload) = acknowledgement else {
                    throw TermiodClientError.handshakeRejected("attach was not acknowledged")
                }
                attached = true
                isWriter = attachedPayload.writer
                DispatchQueue.main.async { [self] in
                    onDaemonSessionID?(attachedPayload.sessionId)
                }
                // The initial state has to be announced too, not just later
                // changes: a client that attaches as an observer, or that opens
                // a session a phone is already holding, is read-only from its
                // first frame and has to be able to say so. `applyWriter` only
                // ever fires on a transition, so nothing else covers this.
                DispatchQueue.main.async { [self] in onWriter?(attachedPayload.writer) }
                // `attached` reports the size the session settled at once this
                // attachment's viewport was counted — the daemon applies the
                // policy before it answers — so this is the grid the bytes
                // arriving on this channel are already wrapped for.
                let sharedGrid = TerminalGrid(
                    rows: attachedPayload.rows, cols: attachedPayload.cols)
                authoritativeGrid = sharedGrid
                DispatchQueue.main.async { [self] in onSharedGrid?(sharedGrid) }
                // The attach control carried this viewport, so the daemon has
                // already counted it; re-sending it would be a barrier for
                // nothing.
                sentViewport = (requested, true)
                // A pane that went to a background tab before its attach landed
                // has to say so: the daemon counts every arrival as rendering.
                if !rendering { scheduleViewportLocked() }
                repaintPending = sharedGrid != surfaceGrid
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
                // Three outcomes, not two. Widening this arm to "lost
                // connection" was too coarse: it also catches a daemon that is
                // perfectly reachable and said no, and reporting that as a
                // session still running elsewhere is its own lie.
                switch error {
                case TermiodClientError.handshakeRejected(let message),
                     TermiodClientError.requestFailed(let message):
                    deliverStartRefusedLocked(message)
                default:
                    // Could not reach it, or it stopped talking mid-handshake.
                    // Same class as losing it mid-session; neither carries an
                    // exit status.
                    deliverConnectionLostLocked()
                }
            }
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        // Stamped here rather than on the work queue: this is the choke point every
        // input path crosses (Mac keystrokes, the phone bridge, `sessions send`),
        // and the status tap reads it to tell input echo apart from agent-driven
        // output. Same contract as `PTYProcess.lastInputAt`.
        inputLock.lock()
        lastInputAtLocked = Date()
        inputLock.unlock()
        workQueue.async { [self] in
            guard !closed else { return }
            guard attached else {
                pendingInput.append(data)
                return
            }
            do {
                // Typing is what claims the token, the same rule
                // `PTYProcess.claimHostOwnership` follows on the in-process
                // path: the size and the write follow the device whose user is
                // actually at the keyboard. Typing is the *only* thing that
                // moves the token — attaching does not, or a phone merely
                // looking at this session would mute this window and pull the
                // PTY down to its own width.
                //
                // Ordering is safe: frames on one connection are processed in
                // order, so the claim is resolved before the input behind it is
                // tested against it.
                if !isWriter { try claimWriterLocked() }
                try sendDataLocked(data)
            } catch {
                Log.termiod.error("""
                input write to \(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    /// Takes the write token for this attachment because its user is now here.
    ///
    /// Typing claims it implicitly (`send`), which covers the Mac: a window is
    /// attached to every session it has a pane for, so nothing short of the
    /// keyboard distinguishes the session being *used* from the fifteen sitting
    /// behind it. A phone is the other shape — it attaches to the one session
    /// its user just opened — and needs to say so out loud, because until it
    /// holds the token its screen is painted for somebody else's grid.
    ///
    /// The grant arrives as `writer_changed`. Nothing else rides it: the token
    /// carries no size, so there is nothing to send here beyond the claim.
    func claimWriter() {
        workQueue.async { [self] in
            guard !closed, attached, !isWriter else { return }
            do {
                try claimWriterLocked()
            } catch {
                Log.termiod.error("""
                claiming the write token on \(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    /// A reply this client's libghostty generated to a host query (DA, DSR,
    /// XTVERSION, a colour query). It goes through only while this client is
    /// the writer, and it never claims: the host asked its terminal one
    /// question, and the writer's surface is that terminal. An observer's
    /// answer would arrive as a late duplicate in the agent's input line — and,
    /// through `send`, would take the token and drag the PTY back to this
    /// window's grid every time the agent probed. That silent tug-of-war was
    /// the resize storm two devices watching one session used to produce.
    func sendDeviceReport(_ data: Data) {
        guard !data.isEmpty else { return }
        workQueue.async { [self] in
            guard !closed, attached, isWriter else { return }
            do {
                try sendDataLocked(data)
            } catch {
                Log.termiod.error("""
                device report to \(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    /// Declares how much of a session this pane could show.
    ///
    /// Measured from the pane, not read back off the surface, and sent whether
    /// or not this client holds the write token. The daemon sizes the session to
    /// the smallest viewport being rendered; who may type is a separate question
    /// and asking it here is what used to turn a stray byte into a resize loop
    /// (`docs/design/20260901-pty-size-is-not-the-write-token.md`).
    func setViewport(rows: Int, cols: Int) {
        let size = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: cols))
        workQueue.async { [self] in
            guard !closed, viewportGrid != size else { return }
            viewportGrid = size
            guard attached else { return }
            scheduleViewportLocked()
        }
    }

    /// Whether this pane is on screen. A hidden pane is not rendering and stops
    /// counting toward the session's size; showing it again puts its viewport
    /// back in the running.
    func setRendering(_ showing: Bool) {
        workQueue.async { [self] in
            guard !closed, rendering != showing else { return }
            rendering = showing
            guard attached else { return }
            scheduleViewportLocked()
        }
    }

    /// The grid libghostty laid this surface out at, which under a size policy
    /// is the *shared* grid rather than the pane's — the pane is letterboxed
    /// around it. Never sent: it would tell the daemon this pane has room for
    /// only what it was already shrunk to, and the session could never grow.
    ///
    /// Arriving at the shared grid is the one moment a letterboxed surface needs
    /// something from the daemon: a keyframe it can finally paint. Leaving it —
    /// a font change reports the old frame at new cell metrics before the
    /// letterbox puts it back — arms the next arrival, so the bytes parsed in
    /// between are repainted too.
    func noteSurfaceGrid(rows: Int, cols: Int) {
        let size = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: cols))
        workQueue.async { [self] in
            guard !closed else { return }
            surfaceGrid = size
            guard attached else { return }
            if authoritativeGrid != size {
                repaintPending = true
            } else if repaintPending {
                repaintPending = false
                requestResyncLocked()
            }
        }
    }

    /// How long the viewport must hold still before it goes to the daemon.
    /// The same 50ms `PTYProcess.resizeFromHost` coalesces on, and for a
    /// sharper reason here: on the in-process path an intermediate size costs a
    /// SIGWINCH, while on this one a viewport that moves the session is a
    /// host-side **barrier** — the session quiesces, resizes, and pushes a fresh
    /// keyframe to every attachment. A live drag or a settling split emits a
    /// burst of them, and each keyframe is a full repaint racing the child's own
    /// redraw.
    private static let viewportCoalescingInterval = DispatchTimeInterval.milliseconds(50)

    /// Sends the viewport once the pane stops moving. Generation-stamped rather
    /// than debounced with a cancellable work item because the size is re-read
    /// at fire time: the last scheduled send is the only one that writes, and it
    /// writes whatever the pane settled at.
    ///
    /// Must run on `workQueue`.
    private func scheduleViewportLocked() {
        viewportGeneration &+= 1
        let generation = viewportGeneration
        workQueue.asyncAfter(deadline: .now() + Self.viewportCoalescingInterval) { [self] in
            guard !closed, attached, generation == viewportGeneration else { return }
            do {
                try sendViewportLocked()
            } catch {
                Log.termiod.error("""
                viewport of \(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    /// Writes one `R` frame, unless the daemon already has this exact
    /// declaration. The skip is not a micro-optimisation: a viewport that moves
    /// the session is a **barrier** host-side (§C.5), so re-declaring what the
    /// daemon already knows can cost every viewer a full repaint.
    ///
    /// An older daemon reads `R` as "set the PTY size" and refuses it from
    /// anyone but the writer, so on one of those this stays gated the way it
    /// always was — and never sends the five-byte form, which such a daemon
    /// reads as a malformed frame and hangs up on.
    ///
    /// Must run on `workQueue`.
    private func sendViewportLocked() throws {
        guard let transport else { return }
        guard hostSizesByPolicy || isWriter else { return }
        let showing = hostSizesByPolicy ? rendering : true
        if let sent = sentViewport, sent.grid == viewportGrid, sent.rendering == showing { return }
        sentViewport = (viewportGrid, showing)
        try Termiod.writeFrame(
            transport.writeDescriptor, kind: .resize,
            payload: Termiod.viewportPayload(
                rows: viewportGrid.rows, cols: viewportGrid.cols, rendering: showing))
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

    /// Asks the daemon to repaint this attachment.
    ///
    /// For a relay that lost bytes on its *own* downstream socket — the phone
    /// bridge dropping frames a slow link could not take — the daemon has no
    /// way to know the screen is wrong, so it has to be told. The repaint
    /// arrives as an ordinary snapshot on the reader.
    func requestResync() {
        workQueue.async { [self] in requestResyncLocked() }
    }

    /// Must run on `workQueue`.
    private func requestResyncLocked() {
        guard !closed, attached, let transport else { return }
        do {
            try Termiod.writeFrame(transport.writeDescriptor, kind: .control,
                                   payload: Termiod.requestSnapshotPayload())
        } catch {
            Log.termiod.error("""
            resync request on \(self.sessionName, privacy: .public) failed: \
            \(error.localizedDescription, privacy: .public)
            """)
        }
    }

    /// Asks the daemon for the write token. The grant arrives as a
    /// `writer_changed` event rather than as this call's reply, because every
    /// other attachment has to learn about it too — `applyWriter` is what flips
    /// `isWriter` and re-asserts this client's size.
    ///
    /// Sent at most once per lost token: `claimingWriter` clears when the
    /// answer lands either way, so a burst of keystrokes on a muted attachment
    /// does not become a burst of claims.
    private func claimWriterLocked() throws {
        guard let transport, !claimingWriter else { return }
        claimingWriter = true
        try Termiod.writeFrame(transport.writeDescriptor, kind: .control,
                               payload: Termiod.claimWriterPayload())
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

    private func teardownLocked() {
        closed = true
        transport?.close()
        transport = nil
    }

    /// Must run on `workQueue` — `exitDelivered` is queue-confined state.
    ///
    /// The final row is read from its own field rather than passed in, so both
    /// arrivals answer the same thing: the daemon emits `E session_exited` before
    /// the `exited` control frame and this reader is serial, so the row is already
    /// recorded by the time either lands. The live roster cache is deliberately
    /// *not* a fallback — a row sampled seconds before the exit answers a
    /// different question — so `nil` here means the daemon never sent one.
    private func deliverExitLocked(status: Int32) {
        guard !exitDelivered else { return }
        exitDelivered = true
        let runtimeMilliseconds = UInt64(max(0, Date().timeIntervalSince(startedAt) * 1000))
        informationLock.lock()
        let information = finalInformationLocked
        informationLock.unlock()
        DispatchQueue.main.async { [self] in
            onExit?(status, runtimeMilliseconds, information)
        }
    }

    /// Records a roster push — the device revising what it knows about a session
    /// that is still running — and publishes it. Called from the reader thread.
    private func recordRosterInformation(_ information: Termiod.SessionInformation) {
        informationLock.lock()
        latestInformationLocked = information
        informationLock.unlock()
        DispatchQueue.main.async { [self] in onInformation?(information) }
    }

    /// Records the row riding the exit. `onExit` is its only reader: it describes
    /// a session that has *ended*, so letting it reach the live consumers would
    /// answer "is a command running in here" with a dead process's blank sample,
    /// and demote an agent row a beat before the exit path decides what the pane
    /// becomes.
    private func recordFinalInformation(_ information: Termiod.SessionInformation) {
        informationLock.lock()
        finalInformationLocked = information
        informationLock.unlock()
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
                    //
                    // Painted even when it describes a grid this surface is not
                    // laid out at yet, which it briefly is: the barrier's `S`
                    // arrives ahead of the `E resized` the letterbox reacts to.
                    // Dropping it instead used to be safe only for the writer,
                    // whose own resize guaranteed another keyframe behind it —
                    // and no client can make that promise now that the size is a
                    // policy nobody client-side controls. `repaintPending` is
                    // what repairs the one mangled frame, on the far side of the
                    // layout pass.
                    guard let keyframe = TermiodSnapshot.decode(frame.payload) else {
                        Log.termiod.error("""
                        undecodable snapshot frame on \(self.sessionName, privacy: .public)
                        """)
                        break
                    }
                    self.onOutput?(TermiodSnapshot.render(keyframe))
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
            // A refused claim answers here rather than with `writer_changed`,
            // and the flag has to clear either way: left set, one refusal would
            // mute this attachment for the rest of its life.
            workQueue.async { [self] in claimingWriter = false }
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
    /// token moves, `resized` carries the authoritative dimensions §C.5 requires
    /// every client to know, and `roster` is what the device says the process is.
    ///
    /// Not private so the routing can be driven with real frames — which of the
    /// two information caches an arriving frame lands in is the kind of thing
    /// that goes wrong silently.
    func handleEvent(_ payload: Data) -> Bool {
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
        case .stalled(let stall):
            DispatchQueue.main.async { [self] in onStalled?(stall) }
        case .writerChanged(let change):
            applyWriter(change.writer)
        case .resized(let size):
            applyAuthoritativeGrid(TerminalGrid(rows: size.rows, cols: size.cols))
        case .roster(let update):
            // Not filtered by name: events are fanned per session, so everything
            // arriving on this channel is about the session it was opened for.
            // A delta with no row is an arrival/departure notice with nothing to
            // update — the roster fetch is what answers those.
            if let information = update.info { recordRosterInformation(information) }
        case .sessionExited(let exit):
            // Recorded before the exit is delivered, and *before* the `exited`
            // control frame the daemon sends next: this is the device's last word
            // on the process, and the exit policy reads it.
            if let information = exit.info { recordFinalInformation(information) }
            // The `exited` control frame says the same thing and normally lands
            // right after; both funnel into the same idempotent delivery, so
            // whichever arrives is enough and neither can double-report.
            workQueue.async { [self] in
                teardownLocked()
                deliverExitLocked(status: exit.status)
            }
            return true
        case .ready:
            // Snapshot-complete. No action: this reader is serial, so `S` has
            // already been rendered by the time this frame is read.
            break
        case .searchResults:
            // Addressed to a request, not to a session: the files channel that
            // asked reads its own hits (`Termiod.searchContents`). Nothing on a
            // session's channel can have asked, so there is nobody to give it to.
            break
        case .fsChanged, .statusChanged:
            // Addressed to a *channel*, not to a session: only a channel
            // carrying a resource subscription can have asked, and a session's
            // link never does (`Termiod.ResourceWatch`). This link hears about
            // its own session's status through `E status` on this very channel,
            // which is what that event is for.
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
    /// frames will be honoured or answered with `not_writer`.
    ///
    /// The token no longer carries the grid with it. It used to: gaining it
    /// re-asserted this client's size, which made every misclassified byte a
    /// resize, and two devices trading the token a resize loop. The size is the
    /// daemon's policy over what is being rendered and does not move when the
    /// token does.
    private func applyWriter(_ writer: String?) {
        workQueue.async { [self] in
            guard !closed else { return }
            let mine = writer != nil && writer == clientID
            claimingWriter = false
            guard mine != isWriter else { return }
            isWriter = mine
            Log.termiod.info("""
            write token on \(self.sessionName, privacy: .public) \
            \(mine ? "claimed" : "lost", privacy: .public)
            """)
            // An older daemon still reads `R` as "set the PTY size" and refuses
            // it from anyone but the writer, so on one of those the token is
            // still the only moment this pane may state its size. Nothing here
            // runs against a daemon that sizes by policy.
            if mine, !hostSizesByPolicy {
                do {
                    try sendViewportLocked()
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

    /// Records the PTY's real size — the smallest viewport currently rendering
    /// this session, which is what every attachment's bytes are wrapped for.
    ///
    /// Only noted, never answered. A writer used to answer a divergence by
    /// putting its own size back, which is how two devices watching one session
    /// sawed the PTY between their two grids. The pane's answer is on the other
    /// side of `onSharedGrid`: it lays the surface out at the shared grid and
    /// leaves the rest of the pane blank (`SharedGridLetterbox`), the way tmux
    /// pads and screen leaves space.
    private func applyAuthoritativeGrid(_ grid: TerminalGrid) {
        workQueue.async { [self] in
            guard authoritativeGrid != grid else { return }
            authoritativeGrid = grid
            DispatchQueue.main.async { [self] in onSharedGrid?(grid) }
            repaintPending = grid != surfaceGrid
            guard grid != viewportGrid else { return }
            Log.termiod.info("""
            \(self.sessionName, privacy: .public) PTY is now \
            \(grid.rows, privacy: .public)x\(grid.cols, privacy: .public); \
            this pane has room for \
            \(self.viewportGrid.rows, privacy: .public)x\(self.viewportGrid.cols, privacy: .public)
            """)
        }
    }

    /// EOF or read error. After a deliberate detach/kill this is expected and
    /// silent; otherwise the transport died under a session that is very
    /// probably still running.
    ///
    /// This used to deliver `exit 1`. A transport failure and a process exit
    /// are different events and only one of them carries a status: the child
    /// never produced that 1, and the exit policy would park the pane over an
    /// error with no error output behind it. A session surviving the loss of
    /// its viewer is what the daemon is for, so the pane says the connection
    /// went, not that the work did.
    private func handleStreamEnd() {
        workQueue.async { [self] in
            let wasDeliberate = closed
            teardownLocked()
            guard !wasDeliberate, !exitDelivered else { return }
            Log.termiod.error("connection to \(self.sessionName, privacy: .public) ended unexpectedly")
            deliverConnectionLostLocked()
        }
    }

    /// Announces the transport's death exactly once, and only when no exit has
    /// already been delivered — a session that ended normally closes its stream
    /// straight afterwards, and that EOF must not be reported a second time as
    /// a disconnection.
    private func deliverStartRefusedLocked(_ message: String) {
        guard !exitDelivered, !connectionLostDelivered, !startRefusedDelivered else { return }
        startRefusedDelivered = true
        DispatchQueue.main.async { [self] in onStartRefused?(message) }
    }

    private func deliverConnectionLostLocked() {
        // All three outcomes are mutually exclusive and each is final. The
        // refusal arm cannot reach here today — a refusal happens inside
        // `start()`, before `startReader` exists, so no EOF follows it — but the
        // guard states the invariant rather than relying on that ordering: if a
        // reader ever starts earlier, one failure must still be one report, and
        // the second would arrive as "still running there", the exact sentence a
        // refusal must never produce.
        guard !exitDelivered, !connectionLostDelivered, !startRefusedDelivered else { return }
        connectionLostDelivered = true
        DispatchQueue.main.async { [self] in onConnectionLost?() }
    }
}
