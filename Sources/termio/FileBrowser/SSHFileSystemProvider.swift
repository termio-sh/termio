import Darwin
import Foundation

/// The OpenSSH ControlMaster socket termio-spawned `ssh` sessions share with the
/// inspector's remote file tree. The terminal session is the master: the user
/// authenticates once there, and pane operations reuse that exact connection.
enum SSHMux {
    /// macOS exposes a 104-byte `sun_path`, including the trailing NUL.
    static let maximumSocketPathBytes = 103
    static let controlHashBytes = 40
    private static let staleDirectoryAge: TimeInterval = 120

    /// One short, private directory per app process. `mkdtemp` creates it
    /// atomically as 0700, avoiding both long/network home paths and predictable
    /// `/tmp` directory ownership races. A restored session starts a new master
    /// with the new process's path, so cross-launch stability is unnecessary.
    static let directory: URL? = {
        let parent = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let prefix = "termio-ssh-\(getuid())\(AppChannel.suffix)-"
        removeStaleDirectories(in: parent, prefix: prefix)

        let pid = getpid()
        var template = Array(
            parent.appendingPathComponent("\(prefix)\(pid)-XXXXXX").path.utf8CString)
        let path: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path else { return nil }
        guard isControlPathSafe(directoryPath: path) else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static func isControlPathSafe(directoryPath: String) -> Bool {
        directoryPath.utf8.count + 1 + controlHashBytes <= maximumSocketPathBytes
    }

    /// Remove only same-user directories from dead app processes, and only
    /// after ControlPersist's 60-second window has safely elapsed.
    private static func removeStaleDirectories(in parent: URL, prefix: String) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return }

        let now = Date()
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            let remainder = url.lastPathComponent.dropFirst(prefix.count)
            guard let separator = remainder.firstIndex(of: "-"),
                  let pid = pid_t(remainder[..<separator]),
                  pid > 0,
                  kill(pid, 0) == -1,
                  errno == ESRCH,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  now.timeIntervalSince(values.contentModificationDate ?? now) >= staleDirectoryAge,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The `ControlPath` value both sides pass — `%C` is expanded by ssh itself.
    static var controlPathTemplate: String? {
        directory?.appendingPathComponent("%C").path
    }

    /// Appended to the interactive terminal's `ssh <host>` command. If the
    /// private runtime directory could not be created, the terminal still opens
    /// normally; only the optional remote browser is unavailable.
    static var masterShellOptions: String? {
        guard let controlPathTemplate else { return nil }
        return "-o ControlMaster=auto -o ControlPath=\(shellQuoted(controlPathTemplate)) -o ControlPersist=60"
    }

    /// Pane-side helper options: reuse the session socket, never own a
    /// connection, and never raise an authentication prompt.
    ///
    /// `RemoteCommand` and `RequestTTY` are pinned because a host that sets
    /// either in `~/.ssh/config` would otherwise break the helper channel —
    /// `RemoteCommand` makes `ssh -s` refuse to start, and a forced tty puts
    /// terminal processing in front of a binary protocol. Nothing else about the
    /// user's configuration is overridden.
    static var clientOptions: [String]? {
        guard let controlPathTemplate else { return nil }
        return [
            "-o", "ControlPath=\(controlPathTemplate)",
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
            "-o", "RemoteCommand=none",
            "-o", "RequestTTY=no",
        ]
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Removes this process's private mux directory after every hosted SSH
    /// session has been torn down on a clean app quit.
    static func cleanup() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Why a remote operation failed, split so the pane can react honestly.
enum SSHProviderError: Error, Equatable {
    case disconnected
    case muxUnavailable
    case commandFailed(String)
    /// A name the tree refuses to build a path from.
    case unsafeName
    case listingTooLarge
    case notRegularFile
    case tooLarge
    case timedOut
    case protocolError(String)
    /// The server's `SSH_FX_EOF`. An expected end to a read or a listing loop,
    /// carried as an error only because that is the shape a reply has.
    case endOfFile
}

/// Browses an SSH host over the terminal session's existing ControlMaster.
///
/// The transport is OpenSSH's own SFTP subsystem, spoken over `ssh -s <host>
/// sftp` on the shared control socket: typed replies, no remote shell, and no
/// quoting — a filename that contains a newline, a quote, or a leading dash is
/// just a length-prefixed byte run. `~/.ssh/config` is honoured because the
/// resolution is done by the `ssh` binary the user already authenticated with.
///
/// One channel is kept open for the pane's lifetime, so expanding a folder costs
/// a round trip rather than a process launch.
actor SSHFileSystemProvider {
    let host: String

    /// Entries per directory. A tree can't render more than this usefully, and a
    /// pathological directory shouldn't be able to grow the pane without bound.
    static let directoryEntryLimit = 50_000
    private static let connectTimeout: TimeInterval = 15
    private static let requestTimeout: TimeInterval = 30
    private static let checkTimeout: TimeInterval = 3

    private var channel: SFTPChannel?
    /// Folders expand concurrently, so several operations can find no channel at
    /// once. They share one launch rather than racing to start their own helper.
    private var connecting: Task<SFTPChannel, Error>?

    init(host: String) {
        self.host = host
    }

    func root() async throws -> String {
        try await perform { try await $0.resolveRoot() }
    }

    func list(_ path: String) async throws -> [FileEntry] {
        try await perform { try await $0.entries(at: path, limit: Self.directoryEntryLimit) }
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        guard limit >= 0, limit < Int.max else { throw SSHProviderError.tooLarge }
        return try await perform { try await $0.fileContents(at: path, limit: limit) }
    }

    /// Ends the conversation. The pane calls this when it goes away; the terminal
    /// session's own connection is untouched.
    func disconnect() {
        connecting?.cancel()
        connecting = nil
        channel?.close()
        channel = nil
    }

    // MARK: Connection

    /// Runs one operation, reconnecting once if the channel we had was already
    /// dead. ControlPersist expiry and a reconnected terminal both present as a
    /// closed channel, and neither should surface as an error the user has to
    /// dismiss — but a *fresh* channel failing is real, and is reported.
    private func perform<T: Sendable>(
        _ body: (SFTPChannel) async throws -> T
    ) async throws -> T {
        if let existing = channel, existing.isOpen {
            do {
                return try await body(existing)
            } catch SSHProviderError.disconnected {
                existing.close()
                channel = nil
            }
        } else if let stale = channel {
            stale.close()
            channel = nil
        }

        try Task.checkCancellation()
        let opened = try await openChannel()
        return try await body(opened)
    }

    /// One launch at a time. A second caller arriving mid-connect awaits the same
    /// task instead of starting a second helper.
    private func openChannel() async throws -> SFTPChannel {
        if let connecting {
            let shared = try await connecting.value
            if shared.isOpen { return shared }
        }
        let task = Task { try await connect() }
        connecting = task
        defer { connecting = nil }
        let opened = try await task.value
        channel = opened
        return opened
    }

    /// `-O check` before launching is what keeps this from ever dialling: with a
    /// dead master, `ssh` would fall back to opening its own connection, which is
    /// exactly the second handshake the design forbids.
    private func connect() async throws -> SFTPChannel {
        guard let clientOptions = SSHMux.clientOptions else {
            throw SSHProviderError.muxUnavailable
        }
        let check = await SSHProcessRunner.run(
            Self.checkArgv(host: host, clientOptions: clientOptions),
            timeout: Self.checkTimeout)
        if check.wasCancelled { throw CancellationError() }
        guard !check.timedOut, check.status == 0 else {
            throw SSHProviderError.disconnected
        }
        return try await SFTPChannel.connect(
            argv: Self.sftpArgv(host: host, clientOptions: clientOptions),
            requestTimeout: Self.requestTimeout,
            connectTimeout: Self.connectTimeout)
    }

    static func checkArgv(host: String, clientOptions: [String]) -> [String] {
        ["/usr/bin/ssh"] + clientOptions + ["-O", "check", "--", host]
    }

    /// `-s … sftp` requests the subsystem rather than running a command, so no
    /// remote shell is involved and no startup file can print into the stream.
    static func sftpArgv(host: String, clientOptions: [String]) -> [String] {
        ["/usr/bin/ssh"] + clientOptions + ["-s", "--", host, "sftp"]
    }
}

// MARK: - Bounded subprocess runner

struct SSHProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
    let wasCancelled: Bool
}

/// Runs `ssh -O check`, the one thing the pane needs a whole subprocess for.
///
/// `Process` is callback-based and does not inherit Swift task cancellation, so
/// this bridge drains both pipes concurrently, bounds what it keeps, and owns
/// timeout and cancellation termination — no hidden `ssh` can outlive the call
/// that started it.
enum SSHProcessRunner {
    static let stderrCaptureLimit = 65_536
    /// `-O check` answers in one line; anything past this is a host that has lost
    /// the plot, and reading it forever would be the only way to be hurt by it.
    static let stdoutCaptureLimit = 65_536
    fileprivate static let terminationGrace: TimeInterval = 0.25
    private static let readerDrainGrace: TimeInterval = 0.5

    static func run(
        _ argv: [String],
        timeout: TimeInterval = 30
    ) async -> SSHProcessResult {
        let execution = SSHProcessExecution()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runSync(
                        argv, timeout: timeout, execution: execution))
                }
            }
        }, onCancel: {
            execution.cancel()
        })
    }

    private static func runSync(
        _ argv: [String],
        timeout: TimeInterval,
        execution: SSHProcessExecution
    ) -> SSHProcessResult {
        guard let executable = argv.first else {
            return SSHProcessResult(
                status: 127, stdout: Data(), stderr: "missing executable",
                timedOut: false, wasCancelled: execution.isCancelled,)
        }
        if execution.isCancelled {
            return SSHProcessResult(
                status: SIGTERM, stdout: Data(), stderr: "",
                timedOut: false, wasCancelled: true,)
        }

        guard !argv.contains(where: { $0.contains("\0") }) else {
            return SSHProcessResult(
                status: 127, stdout: Data(), stderr: "invalid NUL in process argument",
                timedOut: false, wasCancelled: execution.isCancelled,)
        }

        var stdoutFDs = [Int32](repeating: -1, count: 2)
        var stderrFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutFDs) == 0, pipe(&stderrFDs) == 0 else {
            for descriptor in stdoutFDs + stderrFDs where descriptor >= 0 {
                close(descriptor)
            }
            return SSHProcessResult(
                status: 127, stdout: Data(), stderr: "could not create process pipes",
                timedOut: false, wasCancelled: execution.isCancelled,)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_addopen(
            &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], STDERR_FILENO)
        for descriptor in stdoutFDs + stderrFDs {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var processID: pid_t = 0
        let spawnStatus = withCStringArray(argv) { cArguments in
            posix_spawn(
                &processID, executable, &actions, &attributes,
                cArguments, environ)
        }
        close(stdoutFDs[1])
        close(stderrFDs[1])
        guard spawnStatus == 0 else {
            close(stdoutFDs[0])
            close(stderrFDs[0])
            return SSHProcessResult(
                status: 127,
                stdout: Data(),
                stderr: String(cString: strerror(spawnStatus)),
                timedOut: false,
                wasCancelled: execution.isCancelled,)
        }
        execution.register(processID)

        let stdoutHandle = FileHandle(
            fileDescriptor: stdoutFDs[0], closeOnDealloc: true)
        let stderrHandle = FileHandle(
            fileDescriptor: stderrFDs[0], closeOnDealloc: true)

        let readers = DispatchGroup()
        let stdoutCapture = PipeCapture()
        let stderrCapture = PipeCapture()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutCapture.drain(stdoutHandle, limit: stdoutCaptureLimit)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCapture.drain(
                stderrHandle,
                limit: stderrCaptureLimit)
            readers.leave()
        }

        var timedOut = false
        var exitStatus: Int32 = -1
        var didExit = waitForExit(
            processID,
            until: Date().addingTimeInterval(max(timeout, 0.01)),
            status: &exitStatus)
        if !didExit {
            timedOut = true
            execution.terminate(after: terminationGrace)
            didExit = waitForExit(
                processID,
                until: Date().addingTimeInterval(terminationGrace + 1),
                status: &exitStatus)
            if !didExit {
                kill(-processID, SIGKILL)
                didExit = waitForExit(
                    processID,
                    until: Date().addingTimeInterval(1),
                    status: &exitStatus)
            }
        }

        if readers.wait(timeout: .now() + readerDrainGrace) == .timedOut {
            // A subprocess can leave a child holding the pipe descriptors.
            // Closing our read ends lets this operation return without waiting
            // on a process it does not own.
            try? stdoutHandle.close()
            try? stderrHandle.close()
            _ = readers.wait(timeout: .now() + readerDrainGrace)
        }
        execution.clear(processID)
        return SSHProcessResult(
            status: didExit ? exitStatus : -1,
            stdout: stdoutCapture.data,
            stderr: String(decoding: stderrCapture.data, as: UTF8.self),
            timedOut: timedOut,
            wasCancelled: execution.isCancelled,)
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var terminated = pointers + [nil]
        return terminated.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func waitForExit(
        _ processID: pid_t,
        until deadline: Date,
        status: inout Int32
    ) -> Bool {
        var waitStatus: Int32 = 0
        repeat {
            let result = waitpid(processID, &waitStatus, WNOHANG)
            if result == processID {
                let signal = waitStatus & 0x7f
                status = signal == 0 ? (waitStatus >> 8) & 0xff : signal
                return true
            }
            if result == -1, errno != EINTR {
                status = 127
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }
}

private final class SSHProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func register(_ processID: pid_t) {
        let shouldTerminate = lock.withLock {
            self.processID = processID
            return cancelled
        }
        if shouldTerminate {
            terminate(processID, after: SSHProcessRunner.terminationGrace)
        }
    }

    func clear(_ processID: pid_t) {
        lock.withLock {
            if self.processID == processID { self.processID = nil }
        }
    }

    func cancel() {
        let processID = lock.withLock {
            cancelled = true
            return self.processID
        }
        if let processID {
            terminate(processID, after: SSHProcessRunner.terminationGrace)
        }
    }

    func terminate(after grace: TimeInterval) {
        let processID = lock.withLock { self.processID }
        if let processID { terminate(processID, after: grace) }
    }

    private func terminate(_ processID: pid_t, after grace: TimeInterval) {
        kill(-processID, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) { [weak self] in
            let shouldKill = self?.lock.withLock {
                guard self?.processID == processID else { return false }
                return kill(processID, 0) == 0 || errno == EPERM
            } ?? false
            if shouldKill { kill(-processID, SIGKILL) }
        }
    }
}

/// A bounded drain of one pipe. Shared with `SFTPTransport`, which needs the same
/// guarantee: a subprocess must never be able to block on a full pipe we stopped
/// reading, and must never be able to grow our memory without limit.
final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = Data()

    var data: Data { lock.withLock { captured } }

    func drain(_ handle: FileHandle, limit: Int) {
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            lock.withLock {
                guard captured.count < limit else { return }
                captured.append(chunk.prefix(limit - captured.count))
            }
        }
    }
}
