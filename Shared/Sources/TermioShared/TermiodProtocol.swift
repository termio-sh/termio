import Darwin
import Foundation

/// The termiod Session Protocol codec (v0.1, see termiod/src/protocol.rs) —
/// framing, control payloads, and the encode/decode tables, with nothing that
/// knows how the bytes get to a daemon.
///
/// It lives beside `WireProtocol.swift` for the same reason that one does: the
/// Mac reaches a daemon over a Unix socket or an `ssh … termiod stdio` pipe, the
/// phone will reach one over a WebSocket, and a second Swift copy of this format
/// would drift from the first without anything failing to build. Everything a
/// route needs — sockets, `ssh -G`, spawning the daemon — stays in the app's
/// `TermiodClient.swift`, which extends this same namespace.
///
/// Framing is `[kind: u8][length: u32 big-endian][payload]`. Control payloads
/// are JSON; `D` (data) is raw PTY bytes and `R` (resize) is rows/cols as two
/// big-endian u16.
public enum Termiod {
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
    /// | `resources`  | no      | `subscribe_resource` — the live file tree (`Termiod.ResourceWatch`), on the same pooled control channel the listings ride, never an attachment |
    /// | `fs_watch`   | no      | ditto |
    /// | `files`      | no      | `fs.list`/`fs.read` — the Files pane's consumer, on the device's pooled control channel (`TermiodFiles.swift`), never an attachment |
    /// | `upload`     | no      | remote paste; rides a control channel, not an attachment |
    /// | `git`        | no      | ditto |
    ///
    /// A later plane opens its own channel and passes its own `caps` to
    /// `withControlChannel` — capabilities are per-connection, so nothing here
    /// has to grow for the file tree or git to land.
    /// `viewport` is the one that changed what `R` means: the host sizes the
    /// session from every rendering attachment at once instead of from whoever
    /// holds the write token, and understands an `R` that says "not rendering".
    /// A host that does not offer it gets v0's four bytes and v0's meaning.
    public static let attachCapabilities = ["snapshot", "events", viewportCapability]

    /// The host computes the PTY size as a policy over the attachments that are
    /// rendering (`docs/design/20260901-pty-size-is-not-the-write-token.md`).
    /// Gate the five-byte `R` on it: an older host reads a payload of any other
    /// length as a malformed frame and drops the connection.
    public static let viewportCapability = "viewport"

    /// What a plain control channel (`list`, `kill`) offers: nothing. Both verbs
    /// are unconditional, and tombstones ride the `sessions` reply un-gated.
    public static let controlCapabilities: [String] = []

    /// What a client that *renders a whole device* asks for on its control
    /// channel: a pushed session list, the Files pane, and a save or a paste
    /// crossing over. `git` is absent because nothing on this side decodes its
    /// replies yet, and a capability with nothing behind it is worse than none.
    /// `resources` is here for the `status:` subscription and not for `fs:`:
    /// agent status is the one thing a phone must be able to resume a cursor
    /// into, because it is the one thing that keeps changing while the screen
    /// is locked.
    public static let deviceCapabilities = ["events", "files", "upload", "resources"]

    public static let protocolVersion: UInt32 = 1

    // MARK: - Framing

    public enum FrameKind: UInt8, Sendable {
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

    public static let maximumFrameSize = 16 * 1024 * 1024
    /// The daemon chunks its own data frames at this size; mirror it upstream
    /// so a huge paste can't produce an oversized frame.
    public static let maximumDataFrameSize = 64 * 1024

    public static func writeFully(_ descriptor: Int32, _ data: Data) throws {
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

    /// One framed message, ready for whatever carries it — a pipe, or a
    /// WebSocket that has no file descriptor to write to.
    public static func frame(kind: FrameKind, payload: Data) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(kind.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public static func writeFrame(_ descriptor: Int32, kind: FrameKind, payload: Data) throws {
        try writeFully(descriptor, frame(kind: kind, payload: payload))
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
    public static func readFrame(_ descriptor: Int32) throws -> (kind: FrameKind, payload: Data) {
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

    /// Reassembles frames from a transport whose own message boundaries mean
    /// nothing to this protocol. `readFrame` above pulls exactly what a header
    /// asks for, which a blocking descriptor can do and a WebSocket cannot — one
    /// message may carry three frames, or a third of one.
    ///
    /// Not thread-safe: its owner feeds it from one queue.
    public struct FrameReader {
        private var buffer = Data()

        public init() {}

        /// Every frame that `chunk` completed, in order; a partial one stays
        /// buffered. Throws on an over-long length or an undefined kind byte,
        /// which both mean the stream has lost alignment and every later frame
        /// would be read at a garbage offset.
        public mutating func append(
            _ chunk: Data
        ) throws -> [(kind: FrameKind, payload: Data)] {
            buffer.append(chunk)
            var frames: [(kind: FrameKind, payload: Data)] = []
            while buffer.count >= 5 {
                let header = buffer.prefix(5)
                let length = Int(header.dropFirst().withUnsafeBytes { raw in
                    UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
                })
                guard let kind = FrameKind(rawValue: header[header.startIndex]),
                      length <= maximumFrameSize
                else { throw TermiodClientError.malformedFrame }
                guard buffer.count >= 5 + length else { break }
                let start = buffer.index(buffer.startIndex, offsetBy: 5)
                let end = buffer.index(start, offsetBy: length)
                frames.append((kind, Data(buffer[start ..< end])))
                buffer = Data(buffer[end...])
            }
            return frames
        }

        /// Drop whatever a dead socket left half-written, so the next connect
        /// starts on a frame boundary.
        public mutating func reset() {
            buffer = Data()
        }
    }

    /// Blocks until `descriptor` has a frame's first byte to read, or `seconds`
    /// pass with nothing arriving.
    ///
    /// Every other read here is unbounded, and correctly so: a session's pipe is
    /// *meant* to sit quiet until the program writes. A request is the opposite —
    /// it was asked, so an answer is owed. The host does not owe one it has never
    /// heard of, though: unknown ops are dropped on the floor rather than refused
    /// (termiod/src/daemon.rs), so a client asking a daemon that predates an op
    /// waits forever on a reply nobody will send, holding the thread, the
    /// connection, and on the SSH road a child process with it. This is the bound
    /// that turns that into an error a pane can show.
    ///
    /// Only the first byte is guarded. A host that starts a frame and then stalls
    /// mid-payload still blocks, which is the same exposure every other read here
    /// already carries and not what this exists to fix.
    public static func waitForReadable(
        _ descriptor: Int32, seconds: Int, operation: String
    ) throws {
        // Monotonic: a wall clock that steps — NTP, a laptop waking, the user
        // changing the date — would cut a live request short or stretch it past
        // the bound this exists to impose.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while true {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw TermiodClientError.timedOut(operation) }
            // Whole milliseconds *and* the sub-second remainder: dropping the
            // remainder would poll for 1 ms on the last stretch and call that a
            // timeout. Clamped before the conversion, not after — the seconds
            // come from a caller, and a large one must saturate rather than
            // overflow on the way to `Int32`.
            let components = remaining.components
            let whole = min(components.seconds, Int64(Int32.max) / 1000) * 1000
            let fraction = components.attoseconds / 1_000_000_000_000_000
            var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptors, 1, Int32(clamping: whole + fraction + 1))
            if ready > 0 { return }
            if ready == 0 { throw TermiodClientError.timedOut(operation) }
            // Interrupted before anything arrived — the deadline above is what
            // decides whether to keep waiting, not the signal.
            guard errno == EINTR else { throw TermiodClientError.connectionClosed }
        }
    }

    /// `R` payload: rows then cols, each a big-endian u16, and — only when this
    /// attachment has stopped rendering — a fifth flags byte.
    ///
    /// `R` declares *this attachment's viewport*, never the PTY's size. Zero in
    /// either dimension is a window that has not laid out yet and is counted by
    /// nobody. A rendering attachment writes v0's exact four bytes, so the only
    /// payload an old host cannot read is the one it has no policy for anyway.
    public static func viewportPayload(
        rows: UInt16, cols: UInt16, rendering: Bool = true
    ) -> Data {
        var payload = Data(capacity: 5)
        var bigEndianRows = rows.bigEndian
        var bigEndianCols = cols.bigEndian
        withUnsafeBytes(of: &bigEndianRows) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bigEndianCols) { payload.append(contentsOf: $0) }
        if !rendering { payload.append(0) }
        return payload
    }

    /// `F` payload: re u64be, offset u64be, last u8, then the bytes —
    /// termiod/src/protocol.rs `encode_file_chunk`. Public so a test can hold
    /// it to that layout; there is no partial credit on a wire format.
    public static func decodeFileChunk(
        _ payload: Data
    ) throws -> (request: UInt64, offset: UInt64, last: Bool, data: Data) {
        let headerSize = 17
        guard payload.count >= headerSize else { throw TermiodClientError.malformedFrame }
        let bytes = [UInt8](payload)
        var request: UInt64 = 0
        for index in 0 ..< 8 { request = request << 8 | UInt64(bytes[index]) }
        var offset: UInt64 = 0
        for index in 8 ..< 16 { offset = offset << 8 | UInt64(bytes[index]) }
        let last: Bool
        switch bytes[16] {
        case 0: last = false
        case 1: last = true
        default: throw TermiodClientError.malformedFrame
        }
        return (request, offset, last, payload.dropFirst(headerSize))
    }

    /// The `re` a reply is addressed to, read without decoding the reply itself.
    ///
    /// Every response the daemon sends echoes the `seq` of the request that
    /// caused it (termiod/src/protocol.rs — `re` on `FsListed`, `FsFile`,
    /// `FsSearched`, `error`, and the rest). On a channel carrying one request
    /// at a time that field is redundant, which is why nothing read it until
    /// now; on a channel carrying several it is the only thing that says whose
    /// answer just arrived. Split out from `decodeControl` so demultiplexing
    /// costs one small decode and no call site has to change shape.
    ///
    /// `nil` for a frame that answers nobody — `hello_ok`, a broadcast event,
    /// or a daemon too old to stamp its replies.
    public static func responseID(of payload: Data) -> UInt64? {
        struct ResponseTag: Decodable { let re: UInt64? }
        return try? JSONDecoder().decode(ResponseTag.self, from: payload).re
    }

    /// `U` payload: id_len u8, upload id, offset u64 big-endian, then bytes —
    /// termiod/src/protocol.rs `decode_upload_chunk`. Public so a test can
    /// hold it to that layout: the daemon rejects the whole frame on a byte of
    /// drift, and there is no partial credit on a wire format.
    public static func uploadChunkPayload(
        uploadID: String, offset: UInt64, data: Data
    ) -> Data {
        let id = Data(uploadID.utf8)
        var payload = Data(capacity: 1 + id.count + 8 + data.count)
        payload.append(UInt8(clamping: id.count))
        payload.append(id)
        var bigEndianOffset = offset.bigEndian
        withUnsafeBytes(of: &bigEndianOffset) { payload.append(contentsOf: $0) }
        payload.append(data)
        return payload
    }

    // MARK: - Control payloads

    /// What a session is *for*, recorded on the device so every client that
    /// lists it — including one that never opened it — can say which agent is
    /// running and which checkout it belongs to.
    public struct WorkstreamSpecification: Encodable, Sendable {
        public let agentId: String
        public let project: String
        public let worktree: String?

        public init(agentId: String, project: String, worktree: String? = nil) {
            self.agentId = agentId
            self.project = project
            self.worktree = worktree
        }
    }

    /// Spawn parameters for `attach` with `create_if_missing`. The daemon
    /// fills `name` from the attach target, so it is not repeated here.
    public struct CreateSpecification: Encodable, Sendable {
        public let cwd: String
        public let argv: [String]
        /// Wire shape of Rust's `Vec<(String, String)>` — an array of pairs.
        public let env: [[String]]
        public let rows: UInt16
        public let cols: UInt16
        public let workstream: WorkstreamSpecification?

        public init(cwd: String, argv: [String], env: [[String]], rows: UInt16, cols: UInt16,
                    workstream: WorkstreamSpecification? = nil) {
            self.cwd = cwd
            self.argv = argv
            self.env = env
            self.rows = rows
            self.cols = cols
            self.workstream = workstream
        }
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

    private struct ClaimWriterOperation: Encodable {
        let op = "claim_writer"
    }

    private struct RequestSnapshotOperation: Encodable {
        let op = "request_snapshot"
    }

    /// Opens a transfer into a session's scratch directory on the device
    /// (§C.12 `temp:` dest). `session` is the termiod session name — the app's
    /// session UUID — and the daemon reaps whatever lands there when that
    /// session dies, so a pasted screenshot never outlives the conversation it
    /// belonged to.
    /// `dest` is either `temp:<name>` with `session` naming whose scratch
    /// directory receives it — a paste crossing to the device — or a path with
    /// `root` naming the checkout it must stay inside, which is a **save**. The
    /// two are the same transfer; only where it lands differs, so they are one
    /// operation rather than two verbs that would drift apart.
    public struct UploadOpenOperation: Encodable, Sendable {
        public let op = "upload_open"
        public let dest: String
        public let session: String?
        public let root: String?
        public let size: UInt64
        public let sha256: String
        public let seq: UInt64

        public init(dest: String, session: String? = nil, root: String? = nil,
                    size: UInt64, sha256: String, seq: UInt64) {
            self.dest = dest
            self.session = session
            self.root = root
            self.size = size
            self.sha256 = sha256
            self.seq = seq
        }
    }

    /// `ifUnmodifiedSince` is the version the writer read (`fs_file`'s `mtime`).
    /// The host refuses the commit when the destination has moved on since,
    /// which is what stops a save from silently overwriting whoever else is
    /// working in that checkout. Omitted when the transfer replaces nothing.
    public struct UploadCommitOperation: Encodable, Sendable {
        public let op = "upload_commit"
        public let uploadId: String
        public let ifUnmodifiedSince: UInt64?
        public let seq: UInt64

        public init(uploadId: String, ifUnmodifiedSince: UInt64? = nil, seq: UInt64) {
            self.uploadId = uploadId
            self.ifUnmodifiedSince = ifUnmodifiedSince
            self.seq = seq
        }
    }

    public struct UploadAbortOperation: Encodable, Sendable {
        public let op = "upload_abort"
        public let uploadId: String
        public let seq: UInt64

        public init(uploadId: String, seq: UInt64) {
            self.uploadId = uploadId
            self.seq = seq
        }
    }

    public struct FsListOperation: Encodable, Sendable {
        public let op = "fs_list"
        public let root: String
        public let paths: [String]
        /// Resume each directory at the entry *after* this name — the keyset
        /// cursor `PathListingPayload.nextAfter` hands back. Omitted asks from
        /// the start. Not an offset: a directory written while it is read
        /// shifts every offset behind the cursor, and the reply would repeat
        /// one entry and drop another without saying so.
        public let after: String?
        public let seq: UInt64

        public init(root: String, paths: [String], after: String? = nil, seq: UInt64) {
            self.root = root
            self.paths = paths
            self.after = after
            self.seq = seq
        }
    }

    /// Resumable subscription to a durable host resource (§C.10). `since` is
    /// the highest `seq` already applied; omitted on a first subscribe, which
    /// asks for the cursor rather than a replay. Requires the `resources`
    /// capability — a daemon that did not grant it answers `error`, and the
    /// caller falls back to re-listing.
    public struct SubscribeResourceOperation: Encodable, Sendable {
        public let op = "subscribe_resource"
        public let resource: String
        public let since: UInt64?
        public let seq: UInt64

        public init(resource: String, since: UInt64?, seq: UInt64) {
            self.resource = resource
            self.since = since
            self.seq = seq
        }
    }

    public struct UnsubscribeResourceOperation: Encodable, Sendable {
        public let op = "unsubscribe_resource"
        public let resource: String
        public let seq: UInt64

        public init(resource: String, seq: UInt64) {
            self.resource = resource
            self.seq = seq
        }
    }

    /// No `offset`/`length`: an unranged read is what makes `size` and
    /// `truncated` mean "the whole file" rather than "the window you asked for".
    public struct FsReadOperation: Encodable, Sendable {
        public let op = "fs_read"
        public let path: String
        public let seq: UInt64

        public init(path: String, seq: UInt64) {
            self.path = path
            self.seq = seq
        }
    }

    /// Stops an in-flight cancellable request on the same channel, naming it by
    /// the `seq` it was sent with (§C.12 — `Control::Cancel` in
    /// termiod/src/protocol.rs). Idempotent: cancelling something that already
    /// finished is `ok`, not an error.
    ///
    /// Only a multiplexed channel can send this. On a channel carrying one
    /// request at a time the caller is blocked reading the very descriptor it
    /// would have to write to, so the only way to stop a search was to hang up —
    /// which is what the host's `out.closed()` arm exists to notice. A pooled
    /// channel does not hang up, so it has to say so out loud instead.
    public struct CancelOperation: Encodable, Sendable {
        public let op = "cancel"
        public let request: UInt64
        public let seq: UInt64

        public init(request: UInt64, seq: UInt64) {
            self.request = request
            self.seq = seq
        }
    }

    /// `limit` is a total across all files, which is what bounds a one-letter
    /// query in a monorepo — the host stops streaming there and says so.
    public struct FsSearchOperation: Encodable, Sendable {
        public let op = "fs_search"
        public let root: String
        public let query: String
        public let limit: UInt64
        public let seq: UInt64

        public init(root: String, query: String, limit: UInt64, seq: UInt64) {
            self.root = root
            self.query = query
            self.limit = limit
            self.seq = seq
        }
    }

    /// Filename search, which is a different question from `fs_search`'s content
    /// search: this matches *names* in an index the host keeps, so the reply
    /// carries how much of the tree that index has covered.
    public struct FsMatchOperation: Encodable, Sendable {
        public let op = "fs_match"
        public let root: String
        public let query: String
        public let limit: UInt64
        public let seq: UInt64

        public init(root: String, query: String, limit: UInt64, seq: UInt64) {
            self.root = root
            self.query = query
            self.limit = limit
            self.seq = seq
        }
    }

    /// Reply to `fs_match`: root-relative paths, best first. `coverage` is the
    /// fraction of the tree the index has walked (0–1) — no paths at coverage 0
    /// means *not indexed*, and must never be shown as "no matches".
    public struct FsMatchedPayload: Decodable, Sendable {
        public let paths: [String]
        public let coverage: Double

        private enum CodingKeys: String, CodingKey {
            case paths, coverage
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
            coverage = try container.decodeIfPresent(Double.self, forKey: .coverage) ?? 0
        }

        /// The host has nothing indexed for this root, so it answered without
        /// looking. Distinct from a genuine miss, which has full coverage.
        public var indexIsMissing: Bool { paths.isEmpty && coverage <= 0 }
    }

    /// Only the `op` tag — the second decode pass picks the payload shape.
    private struct ControlTag: Decodable {
        let op: String
    }

    /// The daemon's answer to `hello`, and the only place a device's identity
    /// comes from: `hostId` is the machine, `host` is the daemon's version and
    /// platform banner (`termiod/0.1.0 macos-aarch64` — not a hostname), and
    /// `clientId` names this connection (per-connection, never load-bearing).
    public struct HelloOkPayload: Decodable, Sendable {
        public let hostId: String
        public let host: String
        public let clientId: String
        /// The protocol version the handshake settled on — the highest the two
        /// ranges share (§C.3). Decoded tolerantly for replayed captures, but
        /// every real daemon sends it.
        public let proto: Int?
        /// Capabilities the daemon accepted. Absent on an older daemon, so it
        /// defaults rather than failing the handshake — negotiate, never lockstep.
        public let caps: [String]
        /// The account's home directory over there, for the pickers that have to
        /// name a path on that machine. Empty on a daemon too old to send it, and
        /// on one that could not read `HOME`; read it through `homeDirectory`.
        public let home: String
        /// The daemon's build, `<app version>+<build>` — the version of the app
        /// that shipped it. `nil` on a daemon that predates the field, which
        /// every reader treats as older than anything that reports one.
        public let version: String?

        /// `home`, or `/` when the daemon did not answer with an absolute path.
        /// Never empty, so a picker always has somewhere to start — and one rule,
        /// so a second client cannot pick a different fallback.
        public var homeDirectory: String { home.hasPrefix("/") ? home : "/" }

        private enum CodingKeys: String, CodingKey {
            case hostId, host, clientId, proto, caps, home, version
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hostId = try container.decode(String.self, forKey: .hostId)
            host = try container.decode(String.self, forKey: .host)
            clientId = try container.decode(String.self, forKey: .clientId)
            proto = try container.decodeIfPresent(Int.self, forKey: .proto)
            caps = try container.decodeIfPresent([String].self, forKey: .caps) ?? []
            home = try container.decodeIfPresent(String.self, forKey: .home) ?? ""
            version = try container.decodeIfPresent(String.self, forKey: .version)
        }
    }

    /// One row of an `fs_listed` page (§C.12). `kind` is left as the daemon's
    /// own word rather than an enum: a kind this build has never heard of must
    /// decode and sort as "not a directory", not fail the whole listing.
    public struct DirEntryPayload: Decodable, Sendable {
        public let name: String
        public let kind: String
        /// Where a `symlink` points, verbatim — the one fact about a link an
        /// icon cannot carry, and what the row's tooltip shows.
        public let symlinkTarget: String?
        /// What a `symlink` resolves to, and only when the target stays inside
        /// the workspace root (`files.rs` `confined_target_kind`). Absent for
        /// everything else, for a dangling link, for one pointing out of the
        /// root — which the host would refuse to list — and from a host too old
        /// to say.
        public let targetKind: String?

        private enum CodingKeys: String, CodingKey {
            case name, kind, symlinkTarget, targetKind
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            kind = try container.decode(String.self, forKey: .kind)
            symlinkTarget = try container.decodeIfPresent(String.self, forKey: .symlinkTarget)
            targetKind = try container.decodeIfPresent(String.self, forKey: .targetKind)
        }

        public init(name: String, kind: String, symlinkTarget: String? = nil, targetKind: String? = nil) {
            self.name = name
            self.kind = kind
            self.symlinkTarget = symlinkTarget
            self.targetKind = targetKind
        }

        /// Whether this entry can be descended into, resolved *through* a
        /// symlink the way the Finder and the VS Code explorer both do.
        /// `unloaded_dir` counts — it is a directory the host declines to
        /// *walk* (VCS internals), not one it refuses to list when asked
        /// directly. Compared against the daemon's snake_case wire value:
        /// `convertFromSnakeCase` rewrites keys, never values.
        public var isDirectory: Bool {
            Self.isDirectoryKind(kind) || Self.isDirectoryKind(targetKind)
        }

        private static func isDirectoryKind(_ kind: String?) -> Bool {
            kind == "dir" || kind == "unloaded_dir"
        }
    }

    /// One requested path's listing. A path that vanished or escaped the root
    /// carries `error` and fails alone, so a batch never sinks whole.
    public struct PathListingPayload: Decodable, Sendable {
        public let path: String
        public let entries: [DirEntryPayload]
        /// The last name served, when this directory has more entries than one
        /// page holds (`files.rs` `LIST_PAGE_SIZE`) — pass it back as `after`.
        /// Absent when the listing is complete, which is every ordinary
        /// directory, **and** from a host too old to continue one: a client
        /// that never sees it must say the listing is short rather than pass a
        /// single page off as the whole directory.
        public let nextAfter: String?
        /// The offset-paged predecessor of `nextAfter`, from a host that has
        /// not learned the keyset cursor yet.
        ///
        /// Decoded and never followed. Offset pages are the reason the cursor
        /// changed — a directory written while it is read shifts every offset
        /// behind them — so continuing by page would trade a truncated listing
        /// for a wrong one. What this field is for is telling **"that was the
        /// whole directory"** from **"that was its first two thousand entries"**,
        /// which are otherwise the same reply. A client that dropped it could
        /// only truncate in silence.
        public let nextPage: UInt64?
        public let error: String?

        /// Whether the host has more of this directory but no cursor to
        /// continue from — an old host, and a listing that stops short.
        public var isTruncatedByAnOldHost: Bool { nextAfter == nil && nextPage != nil }

        private enum CodingKeys: String, CodingKey {
            case path, entries, nextAfter, nextPage, error
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            entries = try container.decodeIfPresent([DirEntryPayload].self, forKey: .entries) ?? []
            nextAfter = try container.decodeIfPresent(String.self, forKey: .nextAfter)
            nextPage = try container.decodeIfPresent(UInt64.self, forKey: .nextPage)
            error = try container.decodeIfPresent(String.self, forKey: .error)
        }
    }

    public struct FsListedPayload: Decodable, Sendable {
        public let listings: [PathListingPayload]
        /// The `fs:` resource's cursor at listing time — the freshness proof
        /// that lets a subscriber know which batches this listing already
        /// includes, so a batch that arrived while the listing was in flight is
        /// applied and one it already reflects is dropped. Zero from a daemon
        /// running no watch, which reads as "nothing will invalidate this".
        public let seq: UInt64

        private enum CodingKeys: String, CodingKey {
            case listings, seq
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            listings = try container.decodeIfPresent([PathListingPayload].self, forKey: .listings) ?? []
            seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        }
    }

    /// Reply to `subscribe_resource`. `seq` is the cursor the subscription
    /// starts from; `gap` means the host could not replay from the `since` that
    /// was asked for — the ring aged out, or this is a first subscribe — so the
    /// subscriber must re-read what it holds rather than trust its cache.
    public struct SubscribedPayload: Decodable, Sendable {
        public let resource: String
        public let seq: UInt64
        public let gap: Bool

        private enum CodingKeys: String, CodingKey {
            case resource, seq, gap
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resource = try container.decode(String.self, forKey: .resource)
            seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
            gap = try container.decodeIfPresent(Bool.self, forKey: .gap) ?? false
        }
    }

    /// One watcher batch for an `fs:` resource (§C.10). `paths` names the
    /// directories whose contents changed, absolute on the device. `fullRescan`
    /// means the path set is not authoritative and a subscriber must re-walk
    /// what it has realized — the wire equivalent of FSEvents' `MustScanSubDirs`.
    /// `gitMeta` means index/HEAD/refs moved; object-store churn is dropped
    /// host-side and never arrives here.
    public struct FsChangedPayload: Decodable, Sendable {
        public let resource: String
        public let seq: UInt64
        public let paths: [String]
        public let fullRescan: Bool
        public let gitMeta: Bool

        private enum CodingKeys: String, CodingKey {
            case resource, seq, paths, fullRescan, gitMeta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resource = try container.decode(String.self, forKey: .resource)
            seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
            paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
            fullRescan = try container.decodeIfPresent(Bool.self, forKey: .fullRescan) ?? false
            gitMeta = try container.decodeIfPresent(Bool.self, forKey: .gitMeta) ?? false
        }
    }

    /// One batch of `fs.search` hits, addressed to the connection that asked.
    /// `request` echoes the `fs_search` seq — the only routing a streamed reply
    /// has, since a batch of hits names no session and a pooled channel may be
    /// carrying a listing and a read alongside the grep.
    public struct SearchResultsPayload: Decodable, Sendable {
        public let request: UInt64
        public let matches: [SearchMatchPayload]
    }

    public struct SearchMatchPayload: Decodable, Sendable {
        public let path: String
        public let line: UInt64
        /// The matching line, or a window of it when the line is long.
        public let text: String
        /// Byte offset of `text` inside the real line — non-zero when the host
        /// windowed a long line around its first hit.
        public let textOffset: UInt64
        /// Byte ranges inside `text` where the query hit, from the host's own
        /// matcher. Empty from a host too old to report them, which a client
        /// must read as "unknown", never as "no matches on this line".
        public let spans: [[UInt32]]
        public let before: [String]
        public let after: [String]

        private enum CodingKeys: String, CodingKey {
            case path, line, text, textOffset, spans, before, after
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            line = try container.decode(UInt64.self, forKey: .line)
            text = try container.decode(String.self, forKey: .text)
            textOffset = try container.decodeIfPresent(UInt64.self, forKey: .textOffset) ?? 0
            spans = try container.decodeIfPresent([[UInt32]].self, forKey: .spans) ?? []
            before = try container.decodeIfPresent([String].self, forKey: .before) ?? []
            after = try container.decodeIfPresent([String].self, forKey: .after) ?? []
        }
    }

    /// The terminal reply to `fs_search`: how many hits streamed, and why the
    /// stream ended.
    public struct FsSearchedPayload: Decodable, Sendable {
        public let matches: UInt64
        public let limitHit: Bool
        public let canceled: Bool

        private enum CodingKeys: String, CodingKey {
            case matches, limitHit, canceled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            matches = try container.decodeIfPresent(UInt64.self, forKey: .matches) ?? 0
            limitHit = try container.decodeIfPresent(Bool.self, forKey: .limitHit) ?? false
            canceled = try container.decodeIfPresent(Bool.self, forKey: .canceled) ?? false
        }
    }

    /// The reply header for `fs_read`: `length` bytes from `offset` follow as
    /// `F` chunks, and `truncated` means the window stopped short of what was
    /// asked.
    public struct FsFilePayload: Decodable, Sendable {
        public let size: UInt64
        public let offset: UInt64
        public let length: UInt64
        public let truncated: Bool
        /// The file's modification time in whole seconds — the version this read
        /// holds, handed back on save as `ifUnmodifiedSince`. Zero on a host too
        /// old to report one, which means "no version" and so no check.
        public let mtime: UInt64

        private enum CodingKeys: String, CodingKey {
            case size, offset, length, truncated, mtime
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            size = try container.decode(UInt64.self, forKey: .size)
            offset = try container.decode(UInt64.self, forKey: .offset)
            length = try container.decode(UInt64.self, forKey: .length)
            truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
            mtime = try container.decodeIfPresent(UInt64.self, forKey: .mtime) ?? 0
        }
    }

    public struct AttachedPayload: Decodable, Sendable {
        public let sessionId: String
        public let writer: Bool
        public let rows: UInt16
        public let cols: UInt16
    }

    public struct ExitedPayload: Decodable, Sendable {
        public let id: String
        public let status: Int32
    }

    public struct ErrorPayload: Decodable, Sendable {
        public let code: String?
        public let message: String
    }

    public struct SessionsPayload: Decodable, Sendable {
        public let sessions: [Termiod.SessionInformation]
        /// Sessions that have died, newest first. Absent on a daemon too old to
        /// bury them, which is why it decodes to an empty list rather than
        /// failing the reply.
        public let tombstones: [SessionTombstone]

        private enum CodingKeys: String, CodingKey {
            case sessions, tombstones
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try container.decode([SessionInformation].self, forKey: .sessions)
            tombstones = try container.decodeIfPresent(
                [SessionTombstone].self, forKey: .tombstones) ?? []
        }
    }

    /// One row of `termiod list` — a session as the **device** describes it.
    ///
    /// This carries enough to draw a row without consulting anything on the
    /// viewer, which is the point: a session the app never opened (started from
    /// the CLI, or by another client) still has a name, a directory, a command,
    /// and an agent status, and all four come from the machine it runs on.
    /// Unknown fields are ignored and every field the daemon added after v0
    /// decodes optionally, so an older host degrades to blanks instead of a
    /// decode error.
    public struct SessionInformation: Decodable, Sendable, Hashable {
        public let id: String
        public let name: String
        public let pid: Int32
        public let alive: Bool
        /// The directory the process runs in, **on the device**. Never a path on
        /// the viewer's machine, which is why it is only ever shown, never opened.
        public let cwd: String
        public let command: String
        /// The workstream status the session last reported — `working · idle ·
        /// needs_you · done · failed · unknown` (§4). The host names the state;
        /// which dot it becomes is the client's call.
        public let status: String
        public let agentID: String?
        /// The workstream's project root, **on the device**. A client attached
        /// straight to the host has no second source for it, so this is the only
        /// thing that groups a flat session list into projects. `nil` for a
        /// session with no workstream, and from a daemon too old to report one.
        public let project: String?
        /// The title the agent reported, when it reported one.
        public let title: String?
        public let createdUnix: UInt64
        /// How many clients are attached right now. A non-zero count on a session
        /// this app has no row for means someone else is watching it.
        public let attachedClients: Int

        /// The process the **device** picked to answer for the group holding the
        /// tty's foreground — a pid, never the group id. Which member answers is
        /// the host's call: it skips a leader already reaped, as in `foo | bar`
        /// once `foo` exits and only `bar` still holds the terminal.
        ///
        /// `nil` on a daemon too old to sample, and on one that found nobody.
        public let foregroundPid: Int32?
        /// That process's argv. The host reports it; the **client** decides which
        /// agent it is, because the mapping needs the user's own manifests, which
        /// live on the client — so a box that never heard of a user-defined agent
        /// still reports enough for it to be recognised.
        ///
        /// `nil` means *not answered*, never "nothing is running": an old daemon
        /// and an unreadable process look the same from here, and neither may
        /// demote the row.
        public let foregroundArgv: [String]?
        /// Whether something other than the session's own child holds the
        /// foreground — a command is running rather than a shell idling at its
        /// prompt.
        ///
        /// Omitted when false, so `nil` conflates "idle" with "never sampled".
        /// Harmless: both must read as today's no-confirm behaviour, never as
        /// "unknown, so confirm" (`20260814-remote-to-device.decisions.md` §2).
        public let foregroundJob: Bool?
        /// The child's *current* directory — what `cd` moves, as opposed to `cwd`,
        /// which is where the session was created. A path on the **device**.
        public let childCwd: String?
        /// The binary the child is running, as the device's kernel resolved it.
        public let childExecutable: String?
        /// Whether that binary has been replaced on disk since the session pinned
        /// it — an agent that updated itself and quit, told apart from one that
        /// just quit. Omitted when false, so `nil` reads as "not replaced".
        public let childExecutableReplaced: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, name, pid, alive, cwd, command, status, project, title, createdUnix
            case agentID = "agentId"
            case attachedClients
            case foregroundPid, foregroundArgv, foregroundJob
            case childCwd, childExecutable, childExecutableReplaced
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            pid = try container.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
            alive = try container.decodeIfPresent(Bool.self, forKey: .alive) ?? true
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
            command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
            agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
            project = try container.decodeIfPresent(String.self, forKey: .project)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            createdUnix = try container.decodeIfPresent(UInt64.self, forKey: .createdUnix) ?? 0
            attachedClients = try container.decodeIfPresent(Int.self, forKey: .attachedClients) ?? 0
            // Every one of these stays optional rather than defaulting: a default
            // would erase the difference between "the device says no" and "the
            // device did not say", and each consumer below stands down on the
            // second. This is the skew rule the whole additive contract rests on.
            foregroundPid = try container.decodeIfPresent(Int32.self, forKey: .foregroundPid)
            foregroundArgv = try container.decodeIfPresent([String].self, forKey: .foregroundArgv)
            foregroundJob = try container.decodeIfPresent(Bool.self, forKey: .foregroundJob)
            childCwd = try container.decodeIfPresent(String.self, forKey: .childCwd)
            childExecutable = try container.decodeIfPresent(String.self, forKey: .childExecutable)
            childExecutableReplaced = try container.decodeIfPresent(
                Bool.self, forKey: .childExecutableReplaced)
        }

        /// What to call this session on screen. The name is the daemon's handle,
        /// not a label: a session Termio created is named with the app's session
        /// uuid, so a roster row for one this app has no record of would read as
        /// a line of hex. In order of how much it tells a person: the reported
        /// title, the agent, the program actually running, and — only when the
        /// command says nothing — the name itself.
        /// The rungs of `displayLabel` that are a *name* rather than a guess at one:
        /// a title typed on the box, the daemon's own session name, the program the
        /// session is running. A viewer keeps these — they are the only thing naming
        /// the row over there.
        ///
        /// `nil` when the label is only the agent's id, which the client's own
        /// promotion improves on: that row becomes `Claude Code`, and then whatever
        /// the agent's live title says it is working on.
        public var givenName: String? {
            if let title, !title.isEmpty { return title }
            if let agentID, !agentID.isEmpty { return nil }
            return displayLabel
        }

        public var displayLabel: String {
            if let title, !title.isEmpty { return title }
            if let agentID, !agentID.isEmpty { return agentID }
            // What the device's kernel says is actually running, before the
            // string rules that guess at it. A roster-only row — a session this
            // app has never attached to — has no surface to read a title off,
            // so this is the only place its label can come from that is not a
            // guess. `nil` means the daemon did not answer, which is why the
            // guess stays as the fallback rather than being replaced.
            if let program = Self.programName(inArgv: foregroundArgv) { return program }
            return Self.programName(in: command) ?? name
        }

        /// The foreground program the device reported, named the way a person
        /// would name it: the last path component of `argv[0]`, minus the login
        /// marker.
        ///
        /// That marker is not an edge case — it is the *idle* row. A login shell
        /// is spawned with `argv[0] = "-zsh"` (`termiod/src/pty.rs`, and every
        /// terminal before it), and a session sitting at its prompt reports its
        /// own shell as the foreground, so passing the dash through would label
        /// the most common roster row `-zsh`.
        private static func programName(inArgv argv: [String]?) -> String? {
            guard let argv, let executable = argv.first, !executable.isEmpty else { return nil }
            let name = URL(fileURLWithPath: executable).lastPathComponent
            let program = name.hasPrefix("-") ? String(name.dropFirst()) : name
            return program.isEmpty ? nil : program
        }

        /// The program behind the login-shell wrapper Termio spawns through
        /// (`/bin/zsh -ilc exec claude …`): the shell, its flags and `exec` are
        /// scaffolding, and the first word after them is the thing running. A
        /// bare `/bin/zsh -il` has nothing behind the scaffolding because the
        /// shell *is* the session, so it names itself.
        private static func programName(in command: String) -> String? {
            var words = command.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let executable = words.first, !executable.isEmpty else { return nil }
            let shell = URL(fileURLWithPath: executable).lastPathComponent
            guard shell.hasSuffix("sh") else { return shell }
            words.removeFirst()
            while let flag = words.first, flag.hasPrefix("-") { words.removeFirst() }
            if words.first == "exec" { words.removeFirst() }
            guard let program = words.first, !program.isEmpty else { return shell }
            return URL(fileURLWithPath: program).lastPathComponent
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
    public struct SessionTombstone: Decodable, Sendable, Hashable {
        public let id: String
        /// The termiod session name — which, for sessions this app created, is
        /// the app `Session.ID` uuid string. That is what ties a tombstone back
        /// to a row in the sidebar.
        public let name: String
        public let cwd: String
        public let command: String
        /// `exited` · `killed` · `daemon_lost`, or whatever a newer daemon adds.
        public let reason: String
        /// The process's exit code. Absent for `daemon_lost` — the daemon that
        /// would have reaped the child died first, so there is no honest answer.
        public let exitStatus: Int32?
        public let createdUnix: UInt64
        public let endedUnix: UInt64
        public let agentID: String?
        public let title: String?
        /// The workstream status the session last reported. A session that died
        /// while `needs_you` is a different story from one that died `idle`.
        public let status: String
        /// Whether the session's binary was replaced on disk while it ran — an
        /// agent that updated itself and quit, told apart from one that just
        /// quit. The exit *event* carries this too, but only to clients that
        /// were attached when it happened; for anyone who reconnects afterwards
        /// the tombstone is the only route.
        ///
        /// Absent on a `daemon_lost` grave and on a daemon too old to record
        /// it — in both cases nobody measured, which is not the same as
        /// measuring "not replaced", so it must never be shown as a self-update.
        public let childExecutableReplaced: Bool

        private enum CodingKeys: String, CodingKey {
            case id, name, cwd, command, reason, exitStatus, createdUnix, endedUnix
            case agentID = "agentId"
            case title, status, childExecutableReplaced
        }

        public init(from decoder: Decoder) throws {
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
            childExecutableReplaced = try container.decodeIfPresent(
                Bool.self, forKey: .childExecutableReplaced) ?? false
        }
    }

    /// Who owns the write token now. `writer` is a daemon-scoped client id, so
    /// the only client that can tell whether it is the writer is the one that
    /// remembers its own `client_id` from `hello_ok`.
    public struct WriterChangedPayload: Decodable, Sendable {
        public let session: String
        public let writer: String?
    }

    /// The authoritative PTY grid after a resize. Every client is required to
    /// parse at these dimensions (§C.5) — an observer whose window is a
    /// different size wraps the same bytes differently and diverges.
    public struct ResizedPayload: Decodable, Sendable {
        public let session: String
        public let rows: UInt16
        public let cols: UInt16
    }

    /// A workstream status delta — `working · idle · needs_you · done · failed ·
    /// unknown`. The host reports the *state*; which dot, which words, and
    /// whether it fires a notification are the client's call.
    ///
    /// Everything past `title` used to exist only on the Mac, carried by a hook
    /// writing the app's own socket; the `set_status` op made local and remote
    /// the same message. It rides the session's own FIFO, so it cannot overtake
    /// bytes the daemon has already read and is right to apply on arrival.
    public struct StatusPayload: Decodable, Sendable {
        public let session: String
        public let status: String
        public let title: String?
        /// Which channel on the device produced this status — `hook`, `title`,
        /// `progress`, `screen`, `streak` — or nil from a daemon that predates
        /// the status engine moving there, which a client reads as `hook`
        /// because that is the only channel such a daemon had.
        ///
        /// Exactly one decision needs it: a `done` the agent itself reported is
        /// `done` on every client, while a turn the device concluded on its own
        /// is judged against *this* viewer's selection. That call is the
        /// viewer's — see `20260831-companion-second-protocol-retires.md` §3.3.
        public let source: String?
        /// This status ends a turn the device derived rather than was told
        /// about. The one bit needed to apply the rule above.
        public let turnEnded: Bool
        /// The session is blocked on a person, from a condition with a matching
        /// resolved transition — not a one-shot bell. The dot survives a
        /// selection change, because reading a permission prompt is not
        /// answering it.
        ///
        /// nil from a daemon that predates the field, and every `needs_you`
        /// such a daemon sent was blocking — so absent reads as `true` and the
        /// field can only narrow the claim.
        public let blocking: Bool?
        /// The agent's own conversation log for this session, so the Info pane
        /// can address the raw Q&A instead of scraping the screen.
        public let transcriptPath: String?
        /// The agent's own id for the conversation it is writing now — the
        /// signal that follows an in-process `/new` rotation.
        public let conversationID: String?
        /// The tool a tool-scoped event fired for, which is how real work is
        /// told from a prose-only turn.
        public let tool: String?
        /// A raw first-prompt title candidate, normalized and bounded here.
        public let promptTitle: String?

        // The decoder converts from snake_case, so these are the *converted*
        // names. Only `conversationID` needs spelling out: `conversation_id`
        // converts to `conversationId`, and Swift's own capitalisation of an
        // initialism does not match it.
        private enum CodingKeys: String, CodingKey {
            case session, status, title, source, turnEnded, blocking
            case transcriptPath, tool, promptTitle
            case conversationID = "conversationId"
        }

        public init(
            session: String, status: String, title: String?,
            source: String? = nil, turnEnded: Bool = false, blocking: Bool? = nil,
            transcriptPath: String? = nil, conversationID: String? = nil,
            tool: String? = nil, promptTitle: String? = nil
        ) {
            self.session = session
            self.status = status
            self.title = title
            self.source = source
            self.turnEnded = turnEnded
            self.blocking = blocking
            self.transcriptPath = transcriptPath
            self.conversationID = conversationID
            self.tool = tool
            self.promptTitle = promptTitle
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            session = try container.decode(String.self, forKey: .session)
            status = try container.decode(String.self, forKey: .status)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            turnEnded = try container.decodeIfPresent(Bool.self, forKey: .turnEnded) ?? false
            blocking = try container.decodeIfPresent(Bool.self, forKey: .blocking)
            transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
            conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
            tool = try container.decodeIfPresent(String.self, forKey: .tool)
            promptTitle = try container.decodeIfPresent(String.self, forKey: .promptTitle)
        }

        /// Whether this status is the device's own conclusion rather than the
        /// agent's word. A daemon too old to say reports nothing, and everything
        /// it reported was a hook.
        public var isDerived: Bool { source != nil && source != "hook" }
    }

    /// One batch of the `status:` resource (§C.10) — a session's status, with
    /// the cursor a subscriber resumes from. The same facts `StatusPayload`
    /// carries on an attached session's own channel, plus `seq`: a client
    /// watching a whole roster gets one subscription and one cursor, and a
    /// phone that locked mid-turn resumes where it left off instead of
    /// rescanning.
    public struct StatusChangedPayload: Decodable, Sendable {
        public let resource: String
        public let seq: UInt64
        public let session: String
        public let status: String
        public let source: String?
        public let turnEnded: Bool
        public let blocking: Bool?
        public let title: String?
        /// Present only on the one `stalled` signal per quiet window. It rides
        /// this resource rather than its own, so a client that wants agent state
        /// does not have to subscribe twice.
        public let stalledWorkingSeconds: UInt64?
        public let stalledTranscriptLinesGrown: UInt64?

        private enum CodingKeys: String, CodingKey {
            case resource, seq, session, status, source, turnEnded, blocking, title
            case stalledWorkingSeconds, stalledTranscriptLinesGrown
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            resource = try c.decode(String.self, forKey: .resource)
            seq = try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
            session = try c.decode(String.self, forKey: .session)
            status = try c.decode(String.self, forKey: .status)
            source = try c.decodeIfPresent(String.self, forKey: .source)
            turnEnded = try c.decodeIfPresent(Bool.self, forKey: .turnEnded) ?? false
            blocking = try c.decodeIfPresent(Bool.self, forKey: .blocking)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            stalledWorkingSeconds =
                try c.decodeIfPresent(UInt64.self, forKey: .stalledWorkingSeconds)
            stalledTranscriptLinesGrown =
                try c.decodeIfPresent(UInt64.self, forKey: .stalledTranscriptLinesGrown)
        }

        /// The same shape the session-channel event has, so a client applies one
        /// interpretation to both rather than two that can drift.
        public var report: StatusPayload {
            StatusPayload(
                session: session, status: status, title: title,
                source: source, turnEnded: turnEnded, blocking: blocking)
        }
    }

    /// A session has been working a full window with no sign of progress
    /// (device architecture §4.7). Watch-plane only: the session's status stays
    /// `working`, because from outside an agent a quiet long build and a wedged
    /// loop are indistinguishable — which is why this plane signals and never
    /// kills. Edge-triggered: one per quiet window, re-armed by progress.
    public struct StalledPayload: Decodable, Sendable {
        public let session: String
        public let workingSeconds: UInt64
        public let transcriptLinesGrown: UInt64
    }

    /// The device revising what it knows about a session — pushed on change, on
    /// its own slow timer, never from the byte path (§A). `action` stays a string
    /// so a newer one does not fail the decode; `info` is the whole row, so a
    /// client never merges deltas, and is absent on a delta that only announces
    /// an arrival or departure.
    public struct RosterPayload: Decodable, Sendable {
        public let session: String
        public let action: String
        public let info: SessionInformation?
    }

    /// A session's process is gone. `info` is the device's final word on it, and
    /// the reason the exit carries a row at all: `childExecutableReplaced` is
    /// computed on the exit path, so a binary swapped in the seconds before the
    /// agent quit — the self-update case — is answered here and nowhere else.
    /// Absent on a daemon that predates it.
    public struct SessionExitedPayload: Decodable, Sendable {
        public let session: String
        public let status: Int32
        public let info: SessionInformation?
    }

    /// Decoded `E` frames. Unknown events become `.unknown` and are ignored,
    /// matching the protocol's additive-evolution rule.
    public enum IncomingEvent: Sendable {
        case ready(String)
        case status(StatusPayload)
        case statusChanged(StatusChangedPayload)
        case stalled(StalledPayload)
        case writerChanged(WriterChangedPayload)
        case resized(ResizedPayload)
        case roster(RosterPayload)
        case sessionExited(SessionExitedPayload)
        /// One batch of `fs.search` hits, streamed to the connection that asked
        /// (`TermiodFiles.swift`). The only event addressed to a request rather
        /// than to a session, which is why it carries no `session`.
        case searchResults(SearchResultsPayload)
        /// One filesystem batch for a subscribed `fs:` resource. Like
        /// `searchResults` it names no session — but unlike it, it is addressed
        /// to no request either: it is the first event on this plane that
        /// belongs to the *channel*, which is why the pool grew an observer for
        /// frames answering nobody (`TermiodControlPool.swift`).
        case fsChanged(FsChangedPayload)
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
    public struct UploadOpenedPayload: Decodable, Sendable {
        public let uploadId: String
        public let offset: UInt64

        private enum CodingKeys: String, CodingKey {
            case uploadId, offset
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uploadId = try container.decode(String.self, forKey: .uploadId)
            offset = try container.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        }
    }

    /// The credit-of-one grant: `offset` is the total the daemon has received,
    /// which is where the next chunk goes. Holding the next chunk until this
    /// arrives is what bounds a keystroke's wait on a shared pipe to one chunk.
    public struct UploadAckPayload: Decodable, Sendable {
        public let uploadId: String
        public let offset: UInt64
    }

    /// Where the verified bytes landed on the device — an absolute path on
    /// *that* machine, which is the whole point of the transfer.
    public struct UploadCommittedPayload: Decodable, Sendable {
        public let path: String
        /// The version the write produced. Sent back as `ifUnmodifiedSince` by a
        /// second save of the same file, which would otherwise claim the version
        /// the file was opened at and be refused by its own first write. Zero on
        /// a host too old to report it.
        public let mtime: UInt64

        private enum CodingKeys: String, CodingKey {
            case path, mtime
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            mtime = try container.decodeIfPresent(UInt64.self, forKey: .mtime) ?? 0
        }
    }

    // MARK: - The agent plane

    /// One row of an install: what was attempted, where it landed, and whether
    /// it took. Every agent the request selected appears, refusals included —
    /// a silent no-op is what "no hooks on the VPS" looked like.
    public struct AgentInstallResult: Decodable, Sendable, Hashable {
        /// The agent's id, so a client can key its own roster off the reply.
        public let id: String
        /// The agent's display name, for the sentence a Settings row shows.
        public let name: String
        /// `hooks` or `skill`.
        public let kind: String
        /// Where it landed on the daemon's box, resolved — the answer the client
        /// could not work out for itself.
        public let path: String
        /// `installed`, `failed`, or `skipped`.
        public let status: String
        /// Why, when it is not `installed`.
        public let detail: String?

        public var isInstalled: Bool { status == "installed" }

        public init(id: String, name: String, kind: String, path: String,
                    status: String, detail: String?) {
            self.id = id
            self.name = name
            self.kind = kind
            self.path = path
            self.status = status
            self.detail = detail
        }
    }

    public struct AgentsInstalledPayload: Decodable, Sendable {
        public let results: [AgentInstallResult]
    }

    /// Whether one agent's CLI is on the daemon's box.
    public struct AgentPresence: Decodable, Sendable, Hashable {
        public let id: String
        public let command: String?
        /// `true` also when the probe could not look — a machine that cannot
        /// answer must not read as a machine with nothing installed.
        public let present: Bool
    }

    public struct AgentsProbedPayload: Decodable, Sendable {
        public let agents: [AgentPresence]
    }

    /// What to do with one half of the integration — hooks, or the skill.
    ///
    /// Per half, not one flag for both, because the two Integration switches are
    /// independent, and the device pane's "Reinstall hooks" must not touch the
    /// skill. One message still covers the whole roster when they disagree.
    public enum AgentHalfAction: String, Encodable, Sendable {
        case install
        case remove
        /// Not this caller's business; leave whatever is there.
        case leave
    }

    /// Which machine the integration is for. Every hook reports to the daemon
    /// that owns its PTY, so the daemon resolves the command itself; what
    /// still differs is the skill payload — a Mac has a `termio` binary to
    /// teach and a box does not. Spelled exactly as the daemon's `Reporter`
    /// (`termiod/src/agent/install.rs`): `this_mac`, `device`.
    public enum AgentHookReporter: String, Sendable {
        /// This Mac, where the app is running.
        case thisMac = "this_mac"
        /// A box reached over the protocol.
        case device
    }

    /// Decoded control frames the client reacts to. Anything else — unknown
    /// ops, responses this slice doesn't consume — becomes `.unknown` and is
    /// ignored, matching the protocol's additive-evolution rule.
    public enum IncomingControl: Sendable {
        case helloOk(HelloOkPayload)
        case helloError(String)
        case attached(AttachedPayload)
        case exited(ExitedPayload)
        case sessions(SessionsPayload)
        case uploadOpened(UploadOpenedPayload)
        case uploadAck(UploadAckPayload)
        case uploadCommitted(UploadCommittedPayload)
        case fsListed(FsListedPayload)
        /// The reply to `subscribe_resource` (§C.10) — the cursor a live tree
        /// starts counting batches from.
        case subscribed(SubscribedPayload)
        /// The read half of the files plane (`TermiodFiles.swift`). `fs_listed`
        /// above answers both the path picker and the tree; this one only the
        /// tree. It rides the same decode table as everything else, so an
        /// unexpected reply on any channel is ignored rather than fatal.
        case fsFile(FsFilePayload)
        /// The terminal reply to `fs_search`, closing a stream whose hits
        /// arrived as `search_results` events.
        case fsSearched(FsSearchedPayload)
        /// The reply to `fs_match` — filename hits, whole, in one frame.
        case fsMatched(FsMatchedPayload)
        /// The addressed half of `writer_changed`: sent to one client to tell it
        /// who owns size now (§C.5). Same payload shape, so it feeds the same
        /// handler — a client that only listened to the broadcast would still be
        /// correct, and one that only listened to this would not.
        case resizeClaim(WriterChangedPayload)
        /// The agent plane's two replies. The daemon owns the agent config files
        /// on its own box, so the client asks and renders rather than writing.
        case agentsInstalled(AgentsInstalledPayload)
        case agentsProbed(AgentsProbedPayload)
        case error(ErrorPayload)
        case unknown(String)
    }

    public static func encodeControl(_ operation: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(operation)
    }

    public static func decodeControl(_ payload: Data) throws -> IncomingControl {
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
        case "fs_listed":
            return .fsListed(try decoder.decode(FsListedPayload.self, from: payload))
        case "subscribed":
            return .subscribed(try decoder.decode(SubscribedPayload.self, from: payload))
        case "fs_file":
            return .fsFile(try decoder.decode(FsFilePayload.self, from: payload))
        case "fs_searched":
            return .fsSearched(try decoder.decode(FsSearchedPayload.self, from: payload))
        case "fs_matched":
            return .fsMatched(try decoder.decode(FsMatchedPayload.self, from: payload))
        case "resize_claim":
            return .resizeClaim(try decoder.decode(WriterChangedPayload.self, from: payload))
        case "agents_installed":
            return .agentsInstalled(try decoder.decode(AgentsInstalledPayload.self, from: payload))
        case "agents_probed":
            return .agentsProbed(try decoder.decode(AgentsProbedPayload.self, from: payload))
        case "error":
            return .error(try decoder.decode(ErrorPayload.self, from: payload))
        default:
            return .unknown(tag.op)
        }
    }

    /// Decodes an `E` frame. Same additive contract as `decodeControl`: an event
    /// this build has never heard of is `.unknown`, never a decode failure.
    public static func decodeEvent(_ payload: Data) throws -> IncomingEvent {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let tag = try decoder.decode(EventTag.self, from: payload)
        switch tag.ev {
        case "ready":
            return .ready(try decoder.decode(SessionScopedPayload.self, from: payload).session)
        case "status":
            return .status(try decoder.decode(StatusPayload.self, from: payload))
        case "status_changed":
            return .statusChanged(try decoder.decode(StatusChangedPayload.self, from: payload))
        case "stalled":
            return .stalled(try decoder.decode(StalledPayload.self, from: payload))
        case "writer_changed":
            return .writerChanged(try decoder.decode(WriterChangedPayload.self, from: payload))
        case "resized":
            return .resized(try decoder.decode(ResizedPayload.self, from: payload))
        case "roster":
            return .roster(try decoder.decode(RosterPayload.self, from: payload))
        case "session_exited":
            return .sessionExited(try decoder.decode(SessionExitedPayload.self, from: payload))
        case "fs_changed":
            return .fsChanged(try decoder.decode(FsChangedPayload.self, from: payload))
        case "search_results":
            return .searchResults(try decoder.decode(SearchResultsPayload.self, from: payload))
        default:
            return .unknown(tag.ev)
        }
    }

    // MARK: - Request payloads

    /// The `hello` a channel opens with. `client` is the caller's own banner —
    /// `termio-mac/dev`, and whatever the phone calls itself — because the one
    /// thing a shared codec must not do is claim to be a particular client.
    public static func helloPayload(role: String, caps: [String], client: String) throws -> Data {
        try encodeControl(HelloOperation(
            proto: protocolVersion,
            minProto: protocolVersion,
            role: role,
            caps: caps,
            client: client
        ))
    }

    /// Install (or remove) termio's agent integration on the daemon's box.
    ///
    /// One message for the whole roster. The client states preferences — which
    /// agents are on the user's list, whether each switch is on, what a hook
    /// should invoke — and the daemon works out where every agent keeps its
    /// config, whether its CLI is even there, and what to merge.
    public static func installAgentsPayload(
        agents: [String]?,
        hooks: AgentHalfAction,
        skills: AgentHalfAction,
        reporter: AgentHookReporter,
        hookVersion: String
    ) throws -> Data {
        try encodeControl(InstallAgentsOperation(
            op: "install_agents",
            agents: agents,
            hooks: hooks,
            skills: skills,
            reporter: InstallAgentsOperation.Reporter(reporter),
            hookVersion: hookVersion,
            seq: 1
        ))
    }

    public static func probeAgentsPayload(agents: [String]?) throws -> Data {
        try encodeControl(ProbeAgentsOperation(op: "probe_agents", agents: agents, seq: 1))
    }

    private struct InstallAgentsOperation: Encodable {
        let op: String
        let agents: [String]?
        let hooks: AgentHalfAction
        let skills: AgentHalfAction
        let reporter: Reporter
        let hookVersion: String
        let seq: Int

        /// Internally tagged the way the daemon spells it: `{"kind": …}`.
        struct Reporter: Encodable {
            let kind: String

            init(_ reporter: AgentHookReporter) {
                kind = reporter.rawValue
            }
        }
    }

    private struct ProbeAgentsOperation: Encodable {
        let op: String
        let agents: [String]?
        let seq: Int
    }

    public static func attachPayload(
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

    public static func listPayload(seq: UInt64 = 1) throws -> Data {
        try encodeControl(ListOperation(seq: seq))
    }

    public static func killPayload(target: String, seq: UInt64 = 1) throws -> Data {
        try encodeControl(KillOperation(id: target, seq: seq))
    }

    public static func detachPayload() throws -> Data {
        try encodeControl(DetachOperation())
    }

    public static func claimWriterPayload() throws -> Data {
        try encodeControl(ClaimWriterOperation())
    }

    public static func requestSnapshotPayload() throws -> Data {
        try encodeControl(RequestSnapshotOperation())
    }

    private struct SubscribeOperation: Encodable {
        let op = "subscribe"
        let events: [String]
        let seq: UInt64
    }

    /// Asks for the session-scoped events a roster is kept current by. Requires
    /// the `events` capability; `roster` also carries `writer_changed` and
    /// `session_exited`, which is why one name covers three.
    /// `subscribe_resource`, for a client that has no control pool to route it
    /// through — the phone opens one control channel and speaks it directly.
    /// The device-wide agent-status resource. One per device, not one per
    /// session: a client watching a roster wants every row, and one
    /// subscription is one cursor to resume from.
    public static let statusResource = "status:"

    public static func subscribeResourcePayload(
        resource: String, since: UInt64?, seq: UInt64
    ) throws -> Data {
        try encodeControl(SubscribeResourceOperation(resource: resource, since: since, seq: seq))
    }

    public static func subscribePayload(events: [String], seq: UInt64 = 1) throws -> Data {
        try encodeControl(SubscribeOperation(events: events, seq: seq))
    }
}

/// Turns `list`'s flat `[SessionInformation]` into the Workspace → container →
/// Session tree a viewer draws. The daemon has no notion of a project, so the
/// grouping is the client's — and it lives here so a phone and a browser looking
/// at the same box cannot draw two different trees out of one list.
///
/// | Condition | Container |
/// | --- | --- |
/// | `project` is set | that folder project — agent or not |
/// | no project, an agent | the workspace's **Chats** |
/// | no project, no agent | the workspace's **Terminals** |
///
/// `cwd` is never consulted: a loose session's cwd is wherever the user walked
/// it, and filing by it would invent folder projects nobody opened. See
/// `docs/design/20260713-loose-terminal-entity.md`.
public enum TermiodRoster {
    /// The companion wire's own `kind` vocabulary, so the screens that switch on
    /// it need no second spelling.
    public enum Kind: String, Sendable {
        case folder
        case terminals
        case chats
    }

    /// `id` is derived from what the container *is*, never from a position in a
    /// list, so a row keeps its identity while the roster churns underneath it.
    public struct Project: Equatable, Sendable {
        public let id: String
        /// The absolute path on the device: a checkout for a folder, and the
        /// spawn root for a loose container.
        public let path: String
        public let name: String
        public let kind: Kind
        public let sessions: [Termiod.SessionInformation]
    }

    /// Named rather than derived so a client can also *address* one when
    /// starting a session into it.
    public static let terminalsProjectID = "termiod:terminals"
    public static let chatsProjectID = "termiod:chats"

    /// A new terminal window drops you at `~`, and so does this.
    public static func looseTerminalRoot(homeDirectory: String) -> String { homeDirectory }

    /// A scoped scratch directory, never `$HOME`: an autonomous agent turned
    /// loose in a home directory can read and write `~/.ssh` and everything
    /// beside it. The desktop's `TermioStore.looseChatRoot`, on the device.
    public static func looseChatRoot(homeDirectory: String) -> String {
        (homeDirectory as NSString).appendingPathComponent(".termio/chats")
    }

    /// A project id for a checkout on the device. Prefixed so it can never
    /// collide with a container id, and so the path can be read back out.
    public static func projectID(forRoot root: String) -> String { "termiod:root:\(root)" }

    /// The checkout a project id addresses, or nil for the loose containers —
    /// whose roots depend on the device's home directory and so are resolved by
    /// the client that knows it.
    public static func root(ofProjectID id: String) -> String? {
        let prefix = "termiod:root:"
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    /// Terminals, then Chats, then folders — the desktop's own emission order,
    /// with a loose container appearing only when it holds something. Folders
    /// sort by path because the daemon answers `list` by walking a hash map, and
    /// a list that reshuffles between two identical pushes is worse than one
    /// sorted oddly.
    public static func projects(
        from sessions: [Termiod.SessionInformation], homeDirectory: String
    ) -> [Project] {
        var terminals: [Termiod.SessionInformation] = []
        var chats: [Termiod.SessionInformation] = []
        var byRoot: [String: [Termiod.SessionInformation]] = [:]
        for session in sessions {
            // An empty string is how the wire spells "no project" for a
            // workstream that has to carry one, so it means loose too.
            if let root = session.project, !root.isEmpty {
                byRoot[root, default: []].append(session)
            } else if let agent = session.agentID, !agent.isEmpty {
                chats.append(session)
            } else {
                terminals.append(session)
            }
        }

        var containers: [Project] = []
        if !terminals.isEmpty {
            containers.append(Project(
                id: terminalsProjectID,
                path: looseTerminalRoot(homeDirectory: homeDirectory),
                name: "Terminals",
                kind: .terminals,
                sessions: ordered(terminals)
            ))
        }
        if !chats.isEmpty {
            containers.append(Project(
                id: chatsProjectID,
                path: looseChatRoot(homeDirectory: homeDirectory),
                name: "Chats",
                kind: .chats,
                sessions: ordered(chats)
            ))
        }
        return containers + byRoot.keys.sorted().map { root in
            Project(
                id: projectID(forRoot: root),
                path: root,
                name: URL(fileURLWithPath: root).lastPathComponent,
                kind: .folder,
                sessions: ordered(byRoot[root] ?? [])
            )
        }
    }

    /// Oldest first, with a tie-break that keeps two sessions created in the
    /// same second from swapping between pushes.
    private static func ordered(
        _ sessions: [Termiod.SessionInformation]
    ) -> [Termiod.SessionInformation] {
        sessions.sorted { left, right in
            left.createdUnix == right.createdUnix
                ? left.id < right.id
                : left.createdUnix < right.createdUnix
        }
    }
}

public enum TermiodClientError: LocalizedError {
    case daemonUnreachable(String)
    case daemonBinaryMissing(String)
    case daemonSpawnFailed(Int32)
    case connectionClosed
    case malformedFrame
    case handshakeRejected(String)
    case requestFailed(String)
    /// The device accepted the request and then said nothing for long enough
    /// that waiting further is worse than answering. Distinct from a closed
    /// connection: the pipe is open, the host is simply not replying — which is
    /// exactly what a daemon too old for the op does, since unknown ops are
    /// dropped rather than refused (`daemon.rs`, the `Control::Unknown` arm).
    case timedOut(String)
    /// The pipe to the device closed before the protocol got a word in, and
    /// `ssh`'s stderr says why. Carries that line verbatim: "Permission denied
    /// (publickey,password)" names the problem in the words the user can search
    /// for, and every paraphrase of it is worse than the line itself.
    case remoteFailed(String)
    /// The daemon's handshake did not grant a capability the request needs —
    /// too old, or built without it. Terminal by construction: a fresh
    /// connection to the same binary would negotiate the same set, so a caller
    /// stands its feature down rather than retrying.
    case unsupportedCapability(String)

    public var errorDescription: String? {
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
        case .timedOut(let operation):
            return "the device stopped answering \(operation)"
        case .remoteFailed(let reason):
            return reason
        case .unsupportedCapability(let capability):
            return "the device does not serve \(capability)"
        }
    }
}

extension Termiod {
    /// The one line of an `ssh` child's stderr worth showing when its pipe
    /// closed without a handshake, or `nil` when nothing there explains it.
    ///
    /// A connection that dies before `hello_ok` collapses every real cause —
    /// `BatchMode=yes` refusing to prompt for a password, `termiod` missing on
    /// the box, a host key mismatch — into the same EOF, and the only witness
    /// is what ssh or the remote shell printed. The last line is the verdict
    /// (OpenSSH prints its failure last); lines that narrate rather than
    /// explain — known-hosts warnings, the "Connection closed" echo of the EOF
    /// itself — are skipped so they cannot shadow it.
    ///
    /// A missing `termiod` is the one cause worth translating: the remote
    /// shell's "No such file or directory" names a path, not the fix, and the
    /// fix is this app's to know (opening a terminal on the machine deploys
    /// the daemon).
    public static func remoteFailureDiagnosis(stderr: String) -> String? {
        let verdicts = stderr.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("Warning:") }
            .filter { !($0.hasPrefix("Connection to ") && $0.hasSuffix("closed.")) }
        guard let line = verdicts.last else { return nil }
        // The remote shell failing to exec the daemon's own path — "/…/termiod:
        // No such file or directory" (bash, path first) or "…: /…/termiod"
        // (zsh, path last). The path check keeps the daemon complaining about
        // some *other* missing file out of this arm.
        let missing = line.localizedCaseInsensitiveContains("no such file or directory")
            || line.localizedCaseInsensitiveContains("not found")
        if missing, (line.contains("/termiod: ") || line.hasSuffix("/termiod")) {
            return "termiod isn't installed on this machine yet — a new terminal on it sets it up"
        }
        return line
    }
}

/// A terminal grid. A named pair rather than a tuple so "is the PTY already
/// this size?" is one comparison the compiler checks, on a path where getting
/// it wrong costs every viewer a repaint.
public struct TerminalGrid: Equatable, Sendable {
    public let rows: UInt16
    public let cols: UInt16

    public init(rows: UInt16, cols: UInt16) {
        self.rows = rows
        self.cols = cols
    }
}
