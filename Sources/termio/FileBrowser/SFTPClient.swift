import Darwin
import Foundation

/// The SFTP version 3 wire format — the subset a read-only file tree needs.
///
/// Version 3 is `draft-ietf-secsh-filexfer-02`, an expired IETF draft that every
/// mainstream server implements and none has replaced; versions 4-6 were drafted
/// and never adopted. OpenSSH speaks v3 plus named extensions, so a client that
/// implements v3 and ignores the extension list talks to everything.
enum SFTP {
    static let clientVersion: UInt32 = 3
    /// OpenSSH's server refuses frames past 256 KB. A longer one means the stream
    /// has desynchronised, so the channel fails instead of allocating on demand.
    static let maximumPacketBytes = 262_144
    /// Payload per READ. `limits@openssh.com` can raise it; not asking keeps this
    /// client correct against every v3 server.
    static let readChunkBytes = 32_768
    /// READs in flight at once. A preview is fetched in rounds of this many, so a
    /// high-latency link pays a fraction of the round trips a serial read would.
    static let concurrentReads = 8

    enum PacketType {
        static let initialize: UInt8 = 1
        static let version: UInt8 = 2
        static let open: UInt8 = 3
        static let close: UInt8 = 4
        static let read: UInt8 = 5
        static let lstat: UInt8 = 7
        static let fstat: UInt8 = 8
        static let openDirectory: UInt8 = 11
        static let readDirectory: UInt8 = 12
        static let realPath: UInt8 = 16
        static let status: UInt8 = 101
        static let handle: UInt8 = 102
        static let data: UInt8 = 103
        static let name: UInt8 = 104
        static let attributes: UInt8 = 105
    }

    enum StatusCode: UInt32 {
        case ok = 0
        case endOfFile = 1
        case noSuchFile = 2
        case permissionDenied = 3
        case failure = 4
        case badMessage = 5
        case noConnection = 6
        case connectionLost = 7
        case operationUnsupported = 8
    }

    /// `SSH_FXF_READ` — the only open flag a viewer needs.
    static let openForReading: UInt32 = 0x0000_0001

    static func frame(type: UInt8, payload: Data) -> Data {
        var frame = Data(capacity: payload.count + 5)
        append(UInt32(payload.count + 1), to: &frame)
        frame.append(type)
        frame.append(payload)
        return frame
    }

    static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    static func append(_ value: UInt64, to data: inout Data) {
        append(UInt32(truncatingIfNeeded: value >> 32), to: &data)
        append(UInt32(truncatingIfNeeded: value), to: &data)
    }

    /// A protocol string: a length-prefixed byte run. v3 fixes no encoding, so
    /// filenames stay `Data` until something needs to display them.
    static func append(bytes value: Data, to data: inout Data) {
        append(UInt32(value.count), to: &data)
        data.append(value)
    }

    static func append(string value: String, to data: inout Data) {
        append(bytes: Data(value.utf8), to: &data)
    }
}

/// One decoded frame: the type byte and everything after it.
struct SFTPPacket: Sendable {
    let type: UInt8
    let payload: Data
}

/// A cursor over a packet payload. Every read is bounds-checked, so a truncated
/// or hostile frame surfaces as a protocol error instead of a trap.
struct SFTPReader {
    private let data: Data
    private var cursor: Data.Index

    init(_ data: Data) {
        self.data = data
        self.cursor = data.startIndex
    }

    var isAtEnd: Bool { cursor >= data.endIndex }

    mutating func readUInt32() throws -> UInt32 {
        guard data.distance(from: cursor, to: data.endIndex) >= 4 else {
            throw SSHProviderError.protocolError("truncated 32-bit field")
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(data[cursor])
            cursor = data.index(after: cursor)
        }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let high = try readUInt32()
        let low = try readUInt32()
        return (UInt64(high) << 32) | UInt64(low)
    }

    mutating func readBytes() throws -> Data {
        let length = Int(try readUInt32())
        guard length >= 0, data.distance(from: cursor, to: data.endIndex) >= length else {
            throw SSHProviderError.protocolError("truncated string field")
        }
        let end = data.index(cursor, offsetBy: length)
        defer { cursor = end }
        return Data(data[cursor..<end])
    }

    /// v3 `ATTRS`. Only the fields a tree renders are kept; the rest is skipped so
    /// the cursor stays aligned for whatever follows.
    mutating func readAttributes() throws -> SFTPAttributes {
        let flags = try readUInt32()
        var attributes = SFTPAttributes()
        if flags & 0x0000_0001 != 0 {
            attributes.size = try readUInt64()
        }
        if flags & 0x0000_0002 != 0 {
            _ = try readUInt32() // uid
            _ = try readUInt32() // gid
        }
        if flags & 0x0000_0004 != 0 {
            attributes.permissions = try readUInt32()
        }
        if flags & 0x0000_0008 != 0 {
            _ = try readUInt32() // atime
            attributes.modified = Date(timeIntervalSince1970: TimeInterval(try readUInt32()))
        }
        if flags & 0x8000_0000 != 0 {
            let count = try readUInt32()
            for _ in 0..<count {
                _ = try readBytes() // extension type
                _ = try readBytes() // extension data
            }
        }
        return attributes
    }
}

/// The file attributes the tree uses. Everything else v3 can carry is dropped at
/// parse time rather than modelled.
struct SFTPAttributes: Sendable {
    var size: UInt64?
    var permissions: UInt32?
    var modified: Date?

    /// The entry kind, read from `S_IFMT`. A server that omits permissions leaves
    /// the kind unknown, and unknown fails closed to `.other`: the row still
    /// appears, but nothing offers to open it.
    var kind: FileEntry.Kind {
        guard let permissions else { return .other }
        switch mode_t(permissions & UInt32(S_IFMT)) {
        case mode_t(S_IFREG): return .file
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFLNK): return .symlink
        default: return .other
        }
    }

    var isRegularFile: Bool { kind == .file }
}

/// An SFTP conversation over one subprocess's stdio.
///
/// The transport is deliberately not ours: the caller passes `ssh -s <host> sftp`,
/// so `~/.ssh/config` — aliases, `ProxyJump`, keys, agent — resolves once, in the
/// process the user already authenticated. This is the same shape sshfs, rclone's
/// `--sftp-ssh`, and OpenSSH's own `sftp(1)` use.
///
/// One channel serves many requests: replies are matched by request id, so reads
/// can be pipelined and a directory expansion costs one round trip rather than a
/// process launch.
final class SFTPChannel: @unchecked Sendable {
    private struct PendingRequest {
        let continuation: CheckedContinuation<SFTPPacket, Error>
        let timeout: DispatchWorkItem
    }

    private let transport: SFTPTransport
    private let requestTimeout: TimeInterval
    private let lock = NSLock()
    private var pending: [UInt32: PendingRequest] = [:]
    private var handshake: PendingRequest?
    private var nextRequestID: UInt32 = 1
    private var failure: Error?

    var isOpen: Bool { lock.withLock { failure == nil } }

    private init(transport: SFTPTransport, requestTimeout: TimeInterval) {
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    /// Launches `argv` and completes the `INIT`/`VERSION` handshake. Throws
    /// `.disconnected` if the process dies first — which is what a dead
    /// ControlMaster looks like from here.
    static func connect(
        argv: [String],
        requestTimeout: TimeInterval,
        connectTimeout: TimeInterval
    ) async throws -> SFTPChannel {
        let transport = try SFTPTransport(argv: argv)
        let channel = SFTPChannel(transport: transport, requestTimeout: requestTimeout)
        transport.start(
            onPacket: { [weak channel] packet in channel?.deliver(packet) },
            onClose: { [weak channel] error in channel?.fail(with: error) })

        var payload = Data()
        SFTP.append(SFTP.clientVersion, to: &payload)
        let reply = try await channel.send(
            type: SFTP.PacketType.initialize,
            payload: payload,
            isHandshake: true,
            timeout: connectTimeout)
        guard reply.type == SFTP.PacketType.version else {
            channel.close()
            throw SSHProviderError.protocolError("expected VERSION, got type \(reply.type)")
        }
        var reader = SFTPReader(reply.payload)
        let serverVersion = try reader.readUInt32()
        guard serverVersion >= SFTP.clientVersion else {
            channel.close()
            throw SSHProviderError.protocolError("server speaks SFTP v\(serverVersion)")
        }
        return channel
    }

    func close() {
        fail(with: SSHProviderError.disconnected)
        transport.shutdown()
    }

    // MARK: Operations

    /// The start directory, which OpenSSH resolves to the login home.
    func resolveRoot() async throws -> String {
        var payload = Data()
        SFTP.append(string: ".", to: &payload)
        let reply = try await request(type: SFTP.PacketType.realPath, payload: payload)
        let names = try Self.parseNames(reply)
        guard let first = names.first,
              let path = String(data: first.filename, encoding: .utf8),
              path.hasPrefix("/")
        else {
            throw SSHProviderError.protocolError("REALPATH returned no absolute path")
        }
        return path
    }

    /// One directory's entries, in the tree's shared order.
    ///
    /// Names arrive as raw bytes with no declared encoding. A name that isn't
    /// UTF-8, or that carries a path separator, is skipped rather than shown: it
    /// can't be rendered or safely appended to a parent path, and dropping one row
    /// beats failing the whole directory.
    func entries(at path: String, limit: Int) async throws -> [FileEntry] {
        let handle = try await openDirectory(path)
        do {
            var entries: [FileEntry] = []
            while let batch = try await readDirectory(handle) {
                for name in batch {
                    guard let text = String(data: name.filename, encoding: .utf8),
                          Self.isSafeEntryName(text)
                    else { continue }
                    entries.append(FileEntry(
                        name: text,
                        kind: name.attributes.kind,
                        size: name.attributes.size.map { Int64(clamping: $0) },
                        modified: name.attributes.modified))
                }
                guard entries.count <= limit else {
                    throw SSHProviderError.listingTooLarge
                }
            }
            try await close(handle)
            return entries.sortedForTree()
        } catch {
            try? await close(handle)
            throw error
        }
    }

    /// Up to `limit` bytes of one regular file.
    ///
    /// The type is checked twice, and the second check is on the open handle
    /// rather than the path — `FSTAT` describes the inode the reads will come
    /// from, so a file swapped between the check and the open can't be read
    /// through. That race is open in any check-then-read over a shell.
    func fileContents(at path: String, limit: Int) async throws -> Data {
        guard try await lstat(path).isRegularFile else {
            throw SSHProviderError.notRegularFile
        }
        let handle = try await openFile(path)
        do {
            let attributes = try await fstat(handle)
            guard attributes.isRegularFile else { throw SSHProviderError.notRegularFile }
            if let size = attributes.size, size > UInt64(limit) {
                throw SSHProviderError.tooLarge
            }
            let data = try await readAll(handle, limit: limit)
            try await close(handle)
            return data
        } catch {
            try? await close(handle)
            throw error
        }
    }

    // MARK: Protocol operations

    private func openDirectory(_ path: String) async throws -> Data {
        var payload = Data()
        SFTP.append(string: path, to: &payload)
        let reply = try await request(type: SFTP.PacketType.openDirectory, payload: payload)
        return try Self.parseHandle(reply)
    }

    private func openFile(_ path: String) async throws -> Data {
        var payload = Data()
        SFTP.append(string: path, to: &payload)
        SFTP.append(SFTP.openForReading, to: &payload)
        SFTP.append(UInt32(0), to: &payload) // no attributes
        let reply = try await request(type: SFTP.PacketType.open, payload: payload)
        return try Self.parseHandle(reply)
    }

    /// One `READDIR` batch, or nil once the server reports end of file.
    private func readDirectory(_ handle: Data) async throws -> [SFTPName]? {
        var payload = Data()
        SFTP.append(bytes: handle, to: &payload)
        do {
            let reply = try await request(type: SFTP.PacketType.readDirectory, payload: payload)
            return try Self.parseNames(reply)
        } catch SSHProviderError.endOfFile {
            return nil
        }
    }

    private func lstat(_ path: String) async throws -> SFTPAttributes {
        var payload = Data()
        SFTP.append(string: path, to: &payload)
        let reply = try await request(type: SFTP.PacketType.lstat, payload: payload)
        return try Self.parseAttributes(reply)
    }

    private func fstat(_ handle: Data) async throws -> SFTPAttributes {
        var payload = Data()
        SFTP.append(bytes: handle, to: &payload)
        let reply = try await request(type: SFTP.PacketType.fstat, payload: payload)
        return try Self.parseAttributes(reply)
    }

    private func close(_ handle: Data) async throws {
        var payload = Data()
        SFTP.append(bytes: handle, to: &payload)
        _ = try await request(type: SFTP.PacketType.close, payload: payload)
    }

    /// Reads in rounds of `SFTP.concurrentReads` requests. A short read ends the
    /// round and the next one resumes from the last contiguous byte, so a server
    /// that answers with less than it was asked for costs a round trip rather than
    /// leaving a hole.
    private func readAll(_ handle: Data, limit: Int) async throws -> Data {
        var contents = Data()
        contents.reserveCapacity(min(limit, 1 << 20))
        var offset: UInt64 = 0

        while contents.count < limit {
            let remaining = limit - contents.count
            let rounds = min(
                SFTP.concurrentReads,
                (remaining + SFTP.readChunkBytes - 1) / SFTP.readChunkBytes)
            let requests: [(offset: UInt64, length: Int)] = (0..<rounds).map { index in
                let start = index * SFTP.readChunkBytes
                return (offset + UInt64(start), min(SFTP.readChunkBytes, remaining - start))
            }

            let chunks = try await withThrowingTaskGroup(
                of: (Int, Data?).self, returning: [Int: Data?].self
            ) { group in
                for (index, request) in requests.enumerated() {
                    group.addTask {
                        (index, try await self.readChunk(
                            handle, offset: request.offset, length: request.length))
                    }
                }
                var collected: [Int: Data?] = [:]
                for try await (index, chunk) in group { collected[index] = chunk }
                return collected
            }

            var advanced = false
            var reachedEnd = false
            for index in requests.indices {
                guard let chunk = chunks[index] ?? nil else {
                    reachedEnd = true
                    break
                }
                contents.append(chunk)
                offset += UInt64(chunk.count)
                advanced = true
                if chunk.count < requests[index].length { break }
            }
            if reachedEnd || !advanced { break }
        }
        return contents
    }

    /// One `READ`, or nil at end of file.
    private func readChunk(_ handle: Data, offset: UInt64, length: Int) async throws -> Data? {
        var payload = Data()
        SFTP.append(bytes: handle, to: &payload)
        SFTP.append(offset, to: &payload)
        SFTP.append(UInt32(length), to: &payload)
        do {
            let reply = try await request(type: SFTP.PacketType.read, payload: payload)
            guard reply.type == SFTP.PacketType.data else {
                throw SSHProviderError.protocolError("expected DATA, got type \(reply.type)")
            }
            var reader = SFTPReader(reply.payload)
            _ = try reader.readUInt32() // request id
            return try reader.readBytes()
        } catch SSHProviderError.endOfFile {
            return nil
        }
    }

    // MARK: Reply parsing

    private static func parseHandle(_ packet: SFTPPacket) throws -> Data {
        guard packet.type == SFTP.PacketType.handle else {
            throw SSHProviderError.protocolError("expected HANDLE, got type \(packet.type)")
        }
        var reader = SFTPReader(packet.payload)
        _ = try reader.readUInt32() // request id
        return try reader.readBytes()
    }

    private static func parseAttributes(_ packet: SFTPPacket) throws -> SFTPAttributes {
        guard packet.type == SFTP.PacketType.attributes else {
            throw SSHProviderError.protocolError("expected ATTRS, got type \(packet.type)")
        }
        var reader = SFTPReader(packet.payload)
        _ = try reader.readUInt32() // request id
        return try reader.readAttributes()
    }

    static func parseNames(_ packet: SFTPPacket) throws -> [SFTPName] {
        guard packet.type == SFTP.PacketType.name else {
            throw SSHProviderError.protocolError("expected NAME, got type \(packet.type)")
        }
        var reader = SFTPReader(packet.payload)
        _ = try reader.readUInt32() // request id
        let count = try reader.readUInt32()
        guard count <= UInt32(SFTP.maximumPacketBytes) else {
            throw SSHProviderError.protocolError("implausible NAME count")
        }
        var names: [SFTPName] = []
        names.reserveCapacity(Int(count))
        for _ in 0..<count {
            let filename = try reader.readBytes()
            _ = try reader.readBytes() // longname, a human-facing `ls -l` line
            names.append(SFTPName(filename: filename, attributes: try reader.readAttributes()))
        }
        return names
    }

    /// `.` and `..` are a listing convention, not entries; a name carrying a
    /// separator or a NUL is a server the tree refuses to build paths from.
    static func isSafeEntryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    // MARK: Request plumbing

    private func request(type: UInt8, payload: Data) async throws -> SFTPPacket {
        try await send(
            type: type, payload: payload, isHandshake: false, timeout: requestTimeout)
    }

    /// Registers a reply slot, writes the frame, and arms a deadline. The slot is
    /// resolved exactly once — by the reader, the deadline, cancellation, or the
    /// channel failing — because every path removes it under the lock first.
    private func send(
        type: UInt8,
        payload: Data,
        isHandshake: Bool,
        timeout: TimeInterval
    ) async throws -> SFTPPacket {
        var body = payload
        let requestID: UInt32
        if isHandshake {
            requestID = 0
        } else {
            requestID = nextID()
            var identified = Data(capacity: payload.count + 4)
            SFTP.append(requestID, to: &identified)
            identified.append(payload)
            body = identified
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The handler can fire before this closure runs, and it can only
                // resolve a slot that exists — so an already-cancelled task must
                // answer here instead of waiting for its own deadline.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let deadline = DispatchWorkItem { [weak self] in
                    self?.resolve(requestID, isHandshake: isHandshake, with: .failure(
                        SSHProviderError.timedOut))
                }
                let request = PendingRequest(continuation: continuation, timeout: deadline)

                let existingFailure: Error? = lock.withLock {
                    if let failure { return failure }
                    if isHandshake { handshake = request } else { pending[requestID] = request }
                    return nil
                }
                if let existingFailure {
                    deadline.cancel()
                    continuation.resume(throwing: existingFailure)
                    return
                }

                DispatchQueue.global(qos: .userInitiated)
                    .asyncAfter(deadline: .now() + timeout, execute: deadline)
                do {
                    try transport.send(SFTP.frame(type: type, payload: body))
                } catch {
                    resolve(requestID, isHandshake: isHandshake, with: .failure(error))
                }
            }
        } onCancel: {
            resolve(requestID, isHandshake: isHandshake, with: .failure(CancellationError()))
        }
    }

    private func nextID() -> UInt32 {
        lock.withLock {
            let id = nextRequestID
            nextRequestID = nextRequestID == UInt32.max ? 1 : nextRequestID + 1
            return id
        }
    }

    /// Routes one decoded frame. A reply whose slot is already gone — cancelled,
    /// timed out — is dropped; the protocol has no way to withdraw a request, so
    /// the late answer is simply not wanted.
    private func deliver(_ packet: SFTPPacket) {
        if packet.type == SFTP.PacketType.version {
            resolve(0, isHandshake: true, with: .success(packet))
            return
        }
        var reader = SFTPReader(packet.payload)
        guard let requestID = try? reader.readUInt32() else { return }
        if packet.type == SFTP.PacketType.status {
            resolve(requestID, isHandshake: false, with: Self.outcome(for: packet))
            return
        }
        resolve(requestID, isHandshake: false, with: .success(packet))
    }

    /// A `STATUS` reply is success only for operations with nothing to return.
    /// `EOF` is surfaced as its own error so the read and readdir loops can end on
    /// it without treating it as a failure.
    private static func outcome(for packet: SFTPPacket) -> Result<SFTPPacket, Error> {
        var reader = SFTPReader(packet.payload)
        guard let _ = try? reader.readUInt32(), let raw = try? reader.readUInt32() else {
            return .failure(SSHProviderError.protocolError("malformed STATUS"))
        }
        let message = (try? reader.readBytes())
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch SFTP.StatusCode(rawValue: raw) {
        case .ok:
            return .success(packet)
        case .endOfFile:
            return .failure(SSHProviderError.endOfFile)
        case .noConnection, .connectionLost:
            return .failure(SSHProviderError.disconnected)
        case .operationUnsupported:
            return .failure(SSHProviderError.commandFailed(
                message.isEmpty ? "The host doesn't support this operation." : message))
        default:
            return .failure(SSHProviderError.commandFailed(
                message.isEmpty ? "The remote operation failed." : message))
        }
    }

    private func resolve(
        _ requestID: UInt32,
        isHandshake: Bool,
        with outcome: Result<SFTPPacket, Error>
    ) {
        let request: PendingRequest? = lock.withLock {
            if isHandshake {
                defer { handshake = nil }
                return handshake
            }
            return pending.removeValue(forKey: requestID)
        }
        guard let request else { return }
        request.timeout.cancel()
        request.continuation.resume(with: outcome)
    }

    /// The subprocess ended. Every waiting request fails with the same reason, and
    /// the channel stays failed — the provider opens a new one rather than
    /// resurrecting this.
    private func fail(with error: Error) {
        let orphaned: [PendingRequest] = lock.withLock {
            if failure == nil { failure = error }
            var all = Array(pending.values)
            pending.removeAll()
            if let handshake {
                all.append(handshake)
                self.handshake = nil
            }
            return all
        }
        for request in orphaned {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}

/// One `SSH_FXP_NAME` record.
struct SFTPName: Sendable {
    /// Raw bytes: v3 declares no filename encoding.
    let filename: Data
    let attributes: SFTPAttributes
}

/// The subprocess carrying one SFTP conversation: stdin takes frames, stdout is
/// drained by a reader thread that emits whole packets, stderr is captured so a
/// launch failure can be reported in the words `ssh` used.
private final class SFTPTransport: @unchecked Sendable {
    private let processID: pid_t
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let errorDescriptor: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var inputClosed = false
    private var stoppedProcess = false
    private let capturedError = PipeCapture()

    private static let terminationGrace: TimeInterval = 0.25
    private static let errorCaptureLimit = 8192

    init(argv: [String]) throws {
        guard let executable = argv.first else {
            throw SSHProviderError.commandFailed("missing executable")
        }
        guard !argv.contains(where: { $0.contains("\0") }) else {
            throw SSHProviderError.commandFailed("invalid NUL in process argument")
        }

        var input = [Int32](repeating: -1, count: 2)
        var output = [Int32](repeating: -1, count: 2)
        var error = [Int32](repeating: -1, count: 2)
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&error) == 0 else {
            for descriptor in input + output + error where descriptor >= 0 {
                close(descriptor)
            }
            throw SSHProviderError.commandFailed("could not create process pipes")
        }
        // The ends this process keeps must not survive into an unrelated fork —
        // a PTY child inheriting them would hold the channel open forever.
        for descriptor in [input[1], output[0], error[0]] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        // Writing to a helper that has already exited must fail this channel, not
        // the app. Without this the default SIGPIPE disposition turns a dead
        // ControlMaster into a termination.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, error[1], STDERR_FILENO)
        for descriptor in input + output + error {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var spawned: pid_t = 0
        let pointers = argv.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var terminated = pointers + [nil]
        let status = terminated.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &spawned, executable, &actions, &attributes, buffer.baseAddress, environ)
        }
        close(input[0])
        close(output[1])
        close(error[1])
        guard status == 0 else {
            close(input[1])
            close(output[0])
            close(error[0])
            throw SSHProviderError.commandFailed(String(cString: strerror(status)))
        }

        self.processID = spawned
        self.inputDescriptor = input[1]
        self.outputDescriptor = output[0]
        self.errorDescriptor = error[0]
    }

    deinit {
        shutdown()
    }

    /// Starts draining stdout and stderr. The reader owns its descriptor for the
    /// life of the loop and closes it on the way out, so nothing else can close a
    /// descriptor another thread is blocked on.
    func start(
        onPacket: @escaping @Sendable (SFTPPacket) -> Void,
        onClose: @escaping @Sendable (Error) -> Void
    ) {
        let output = outputDescriptor
        let error = errorDescriptor
        let capture = capturedError

        DispatchQueue.global(qos: .utility).async {
            let handle = FileHandle(fileDescriptor: error, closeOnDealloc: true)
            capture.drain(handle, limit: Self.errorCaptureLimit)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            var frame = [UInt8](repeating: 0, count: 65_536)
            var protocolFailure: Error?

            loop: while true {
                let count = frame.withUnsafeMutableBytes { pointer -> Int in
                    guard let base = pointer.baseAddress else { return -1 }
                    return read(output, base, pointer.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if count == 0 { break }
                buffer.append(contentsOf: frame[0..<count])

                // Packets are consumed by advancing a cursor and the buffer is
                // compacted once per read, so a burst of pipelined replies isn't
                // recopied per packet.
                var consumed = buffer.startIndex
                while buffer.distance(from: consumed, to: buffer.endIndex) >= 4 {
                    var reader = SFTPReader(buffer[consumed...])
                    guard let length = try? reader.readUInt32() else { break }
                    guard length >= 1, Int(length) <= SFTP.maximumPacketBytes else {
                        protocolFailure = SSHProviderError.protocolError(
                            "frame of \(length) bytes")
                        break loop
                    }
                    guard buffer.distance(from: consumed, to: buffer.endIndex)
                        >= Int(length) + 4 else { break }
                    let start = buffer.index(consumed, offsetBy: 4)
                    let end = buffer.index(start, offsetBy: Int(length))
                    onPacket(SFTPPacket(
                        type: buffer[start],
                        payload: Data(buffer[buffer.index(after: start)..<end])))
                    consumed = end
                }
                if consumed > buffer.startIndex {
                    buffer = Data(buffer[consumed...])
                }
            }

            close(output)
            let message = String(decoding: capture.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onClose(protocolFailure ?? Self.closureReason(message))
        }
    }

    /// A channel that ends on its own is a lost connection, not a protocol fault —
    /// the terminal's master went away, or `ssh` refused to reuse it. The pane
    /// reports it as disconnected and waits for the user to reconnect.
    private static func closureReason(_ message: String) -> Error {
        message.isEmpty
            ? SSHProviderError.disconnected
            : SSHProviderError.commandFailed(message)
    }

    func send(_ frame: Data) throws {
        try writeLock.withLock {
            guard !stateLock.withLock({ inputClosed }) else {
                throw SSHProviderError.disconnected
            }
            try frame.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = write(inputDescriptor, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw SSHProviderError.disconnected
                    }
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                }
            }
        }
    }

    /// Closing stdin is the polite end: the subsystem sees EOF and exits, which
    /// ends `ssh`. The signal escalation is only for a process that ignores it.
    func shutdown() {
        let shouldStop: Bool = stateLock.withLock {
            if stoppedProcess { return false }
            stoppedProcess = true
            if !inputClosed {
                inputClosed = true
                close(inputDescriptor)
            }
            return true
        }
        guard shouldStop else { return }

        let processID = self.processID
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<25 {
                if waitpid(processID, &status, WNOHANG) == processID { return }
                usleep(10_000)
            }
            kill(-processID, SIGTERM)
            for _ in 0..<Int(Self.terminationGrace * 100) + 25 {
                if waitpid(processID, &status, WNOHANG) == processID { return }
                usleep(10_000)
            }
            kill(-processID, SIGKILL)
            _ = waitpid(processID, &status, 0)
        }
    }
}
