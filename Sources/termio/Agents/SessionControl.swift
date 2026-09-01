import Darwin
import Foundation

/// The bind-time defenses every local socket termio serves needs, in one place.
/// Both listeners in this folder answer on an `AF_UNIX` path under the channel's
/// Application Support directory, and both fail the same way without these: an
/// unconditional `unlink` before `bind` lets a second instance take the *name*
/// from a healthy first one, which then keeps listening on an inode nothing can
/// address and never finds out. The usual thief is a bare SwiftPM binary — no
/// bundle id means `AppChannel.suffix` is empty, so `swift run` during
/// development lands on the *release* channel.
enum LocalSocket {
    /// Fills a `sockaddr_un` for `path`, or nil when the path doesn't fit
    /// `sun_path`. Shared by the listeners and the liveness probe so all of them
    /// agree on exactly which address they mean.
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = byte }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    /// True when something is already accepting connections at `path`. A refused
    /// connection — or no file at all — means the socket is stale and safe to
    /// replace; a connect that lands means a live owner we must not evict.
    static func isLive(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              var address = address(for: path)
        else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, size) }
        } == 0
    }

    /// The inode behind `path`, or nil when nothing is there — the identity check
    /// that tells "still our socket" from "someone rebound this name".
    static func inode(of path: String) -> UInt64? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return UInt64(status.st_ino)
    }

    /// How often a listener that stood down re-probes the path it gave up.
    static let reclaimInterval: TimeInterval = 30

    /// Calls `onFree` once nothing answers at `path` any more. This is the other
    /// half of standing down: the instance that took the path can exit *without*
    /// unlinking, which leaves a file that refuses every connection and an inode
    /// that never changes — so the replacement watch cannot see it and the socket
    /// stays dead until someone relaunches the app. Only a periodic probe
    /// distinguishes "still serving" from "gone, and its leftovers are in the way".
    ///
    /// Returns the resumed timer to retain; cancel it once the path is bound.
    static func retryWhenFree(
        path: String, on queue: DispatchQueue, onFree: @escaping () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + reclaimInterval, repeating: reclaimInterval)
        timer.setEventHandler {
            guard !isLive(path) else { return }
            onFree()
        }
        timer.resume()
        return timer
    }

    /// Watches for another instance's `unlink` taking a bound socket file away and
    /// calls `onReplaced` when it happens. Without this, losing the path is
    /// permanent and silent: the listener stays bound to an inode with no name,
    /// every client gets ECONNREFUSED, and only a relaunch recovers. The caller's
    /// handler re-runs its bind, which probes again — so a live replacement makes
    /// it stand down, a bare `rm` gets the path back.
    ///
    /// The socket file itself can't be the watch target: `open(2)` on an AF_UNIX
    /// socket fails with ENXIO, so a file-level vnode source never arms. We watch
    /// the enclosing directory and re-check the entry when it changes.
    ///
    /// Returns the resumed source to retain, or nil when the watch can't be armed.
    static func watchForReplacement(
        of path: String, on queue: DispatchQueue, onReplaced: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let directory = (path as NSString).deletingLastPathComponent
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0, let bound = inode(of: path) else {
            if descriptor >= 0 { close(descriptor) }
            return nil
        }
        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue)
        watch.setEventHandler {
            // Every write anywhere in the support directory lands here (state.json
            // above all), so the cheap identity check comes first: only a vanished
            // entry or a different inode means the socket was replaced.
            guard inode(of: path) != bound else { return }
            onReplaced()
        }
        watch.setCancelHandler { close(descriptor) }
        watch.resume()
        return watch
    }
}

/// One request from the `termio sessions …` CLI, sent as a single JSON object
/// over `AppSocketListener`'s local socket. Where an agent's hook *reports* ("this
/// session is now working", via `termio agent report`), a request here *acts on* a
/// sibling session — listing them, sending a prompt, answering a menu, closing or
/// focusing one.
///
/// - `op` — `list` / `read` / `send` / `answer` / `close` / `focus`.
/// - `format` — `text` (human-readable lines, the default) or `json`.
/// - `callerSession` / `callerCwd` — who is asking, used to scope every operation
///   to the caller's own project. `callerSession` is the `TERMIO_SESSION` the PTY
///   carries; `callerCwd` (`$PWD`) is the fallback for a shell that isn't a termio
///   session but sits inside an open project's directory.
/// - `target` — the session to act on: a `termio://session/<uuid>` link from
///   `list`, or a bare id / id prefix / title. Empty for `send` means "start a
///   fresh session".
/// - `text` — the prompt (`send`) or menu answer (`answer`).
/// - `agent` — the agent for a fresh session (`send` with no target).
/// - `snapshot` — `watch` only: `false` skips the initial per-session status
///   snapshot (absent means snapshot on).
/// - `wait` / `timeoutMs` — `send`/`spawn` only: block until the turn the prompt
///   kicked off settles (or the timeout elapses) and report the outcome, instead
///   of replying the instant the keystrokes are delivered.
struct ControlRequest: Decodable {
    let op: String
    let format: String?
    let callerSession: String?
    let callerCwd: String?
    let target: String?
    let text: String?
    let lines: Int?
    let agent: String?
    let snapshot: Bool?
    let wait: Bool?
    /// The `--wait` cap in milliseconds; clamped server-side. Nil uses the default.
    let timeoutMs: Int?
    /// Optional banner title for the `notify` op; defaults to the calling agent's
    /// name when absent.
    let title: String?
    /// `send`/`answer`: whether to submit the text with a Return. `--no-enter`
    /// sends false — the payload is itself the keypress a prompt is waiting on
    /// (a bare `t` at a trust gate), not a line to submit. Absent means submit.
    let enter: Bool?
    /// `send`: named keys to press after the text, in order — `--key escape`,
    /// `--key ctrl-c`. A key is not text: its bytes depend on the mode the program
    /// negotiated (`ESC [ A` vs `ESC O A` for Up), so only Ghostty's key encoder can
    /// produce them, and hand-writing them into `text` is right by luck at best.
    /// See `SessionKeyPress`.
    let keys: [String]?
    /// `spawn`/`run` placement: where the new pane lands relative to the
    /// caller's — `right` or `down` (herdr's split vocabulary). Absent means
    /// the automatic opposite-stack rule.
    let direction: String?
    /// `spawn`/`run` placement: the new pane's fraction of the split. Stating
    /// one pins the divider so later spawns don't redistribute it away.
    let ratio: Double?

    private enum CodingKeys: String, CodingKey {
        case op, format, target, text, lines, agent, snapshot, wait, title, enter, keys
        case direction, ratio
        case callerSession = "caller_session"
        case callerCwd = "caller_cwd"
        case timeoutMs = "timeout_ms"
    }

    var wantsJSON: Bool { format == "json" }
    var wantsWait: Bool { wait == true }
    /// Naming a key suppresses the implicit Return as surely as `--no-enter` does:
    /// the caller is being explicit about which keys to press, and appending one
    /// they did not ask for would submit a menu they meant to escape.
    var wantsEnter: Bool { enter != false && namedKeys.isEmpty }
    var namedKeys: [String] { keys ?? [] }
}

/// Deadline-bounded reads and writes for the control connections.
///
/// Every one of these descriptors is non-blocking: on Darwin `accept(2)` hands
/// back a copy of the listening socket's `O_NONBLOCK`, which `bindAndListen` sets.
/// So `read` and `write` here answer -1/`EAGAIN` the moment the kernel has nothing
/// to give or nowhere left to put it — and a Unix stream socket's send buffer is
/// only 8 KiB. Both are *retry* answers, as is `EINTR`; only EOF, a hard errno, or
/// a blown deadline actually ends a transfer. Mistaking a retry for a failure is
/// what truncated every reply past 8192 bytes mid-token and what answered
/// "malformed request" to a well-formed request whose bytes had not landed yet.
///
/// Internal rather than file-private so the tests can drive it over a `socketpair`
/// with a deliberately small send buffer: the listener itself can only be exercised
/// by binding this channel's real control socket.
enum SocketIO {
    /// Writes all of `data`, waiting out a reader that has not drained the send
    /// buffer yet. False means the peer is gone, the socket errored, or `timeout`
    /// elapsed — never "the kernel was momentarily full".
    static func writeAll(_ descriptor: Int32, _ data: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let written = write(descriptor, base + offset, data.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 { return false }
                switch errno {
                case EINTR: continue
                case EAGAIN, EWOULDBLOCK:
                    guard wait(descriptor, for: Int16(POLLOUT), until: deadline) else { return false }
                default: return false
                }
            }
            return true
        }
    }

    /// Blocks until the socket has something to read (or hangs up, which the next
    /// `read` reports as EOF). False means the deadline passed or the socket
    /// errored — the cases that really do end the exchange.
    static func waitReadable(_ descriptor: Int32, until deadline: Date) -> Bool {
        wait(descriptor, for: Int16(POLLIN), until: deadline)
    }

    /// One `poll` against `deadline`, retried across `EINTR`. A ready descriptor
    /// returns true even when the readiness is an error condition: the following
    /// `read`/`write` reports the real errno, so there is exactly one place that
    /// decides what an errno means.
    private static func wait(_ descriptor: Int32, for events: Int16, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var descriptors = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&descriptors, 1, Int32((remaining * 1000).rounded(.up)))
            if ready > 0 { return true }
            if ready == 0 { return false }
            guard errno == EINTR else { return false }
        }
    }
}

/// A local Unix-domain socket the `termio` CLI connects to. Request/response: it
/// decodes one `ControlRequest`, runs the handler on the main actor, and writes the
/// handler's reply back down the same connection before closing — so the CLI can
/// print it.
///
/// This type owns only the transport. Resolving the caller's project, enforcing
/// project scope, and acting on sessions all live in `TermioStore` (the handler).
// @unchecked: the handler closures are immutable @MainActor values, and every
// mutable property is confined to `queue`; the queue is the synchronization the
// compiler cannot see.
final class AppSocketListener: @unchecked Sendable {
    /// Named for the process that binds it, the way `termiod.sock` is: the daemon
    /// answers there, the app answers here. Not named for the session verbs it
    /// carries today — those are migrating to the daemon's framed protocol one at a
    /// time (unify-server-plane Stage 10), and what is left behind is the work only
    /// a window can do: focusing a pane, posting a notification, placing a split.
    static var socketURL: URL {
        AppChannel.supportDirectory.appendingPathComponent("app.sock")
    }

    // Deliberately the only path bound. Answering on the pre-rename name too would
    // mean a second listener with its own defer-and-reclaim state, and `bindAndListen`
    // yields a path to whoever already holds it — so an app could hold one name while
    // an older instance held the other, and which app a request reached would depend
    // on which name the client resolved. One path, one owner. A client older than the
    // rename gets a connection error naming a socket nobody binds, which is a
    // diagnosable failure rather than a silently misrouted command.

    private let onRequest: @MainActor (ControlRequest) async -> Data
    /// Resolves a `watch` subscription: returns the caller's project id to scope the
    /// stream to (plus the initial status snapshot to emit on attach), or an error
    /// payload to write back and hang up. Split from `onRequest` because a watch is
    /// not one-shot — the connection stays open and is handed to `SessionWatchHub`
    /// instead of being answered and closed.
    private let onWatch: @MainActor (ControlRequest) -> (UUID?, Data?, [SessionWatchEvent])
    private let queue = DispatchQueue(label: "sh.termio.app-socket")
    private var source: DispatchSourceRead?
    private var listenDescriptor: Int32 = -1
    /// Watches the socket *file* we bound, so an instance that loses the path to
    /// someone else's `unlink` finds out (see `watchForReplacement`).
    private var pathWatch: DispatchSourceFileSystemObject?
    /// Runs only while another instance holds the path, and takes it back when
    /// that one goes away (see `LocalSocket.retryWhenFree`).
    private var reclaim: DispatchSourceTimer?

    init(onRequest: @escaping @MainActor (ControlRequest) async -> Data,
         onWatch: @escaping @MainActor (ControlRequest) -> (UUID?, Data?, [SessionWatchEvent])) {
        self.onRequest = onRequest
        self.onWatch = onWatch
    }

    func start() {
        queue.async { [weak self] in self?.bindAndListen() }
    }

    private func bindAndListen() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        // A socket file left behind by a previous run makes bind() fail with
        // EADDRINUSE, so it has to go — but only once we know nobody is behind it.
        // An unconditional unlink lets a second instance steal the path from a
        // *healthy* app, which then keeps listening on an inode no client can
        // reach and never learns it went deaf: every `termio sessions` call dies
        // with ECONNREFUSED while the app looks perfectly fine. The usual thief is
        // a bare SwiftPM binary — no bundle id means `AppChannel.suffix` is empty,
        // so `swift run` during development lands on the *release* channel.
        if LocalSocket.isLive(path) {
            // Name `dev`, not `<name>`: a placeholder reads as "any name works",
            // and the reader's next move is usually TERMIO_CHANNEL=<name>
            // ./scripts/build-app.sh — which builds no such channel.
            Self.log("""
                another termio already answers at \(path) — leaving the app socket \
                to it (relaunch this process with TERMIO_CHANNEL=dev for a channel of \
                its own; that steers this run, not how a bundle was built)
                """)
            // The instance we defer to is usually a short-lived `swift run`, and it
            // can exit without unlinking — a dead file the replacement watch cannot
            // see, because its inode never changes. Probing is the only way back.
            if reclaim == nil {
                reclaim = LocalSocket.retryWhenFree(path: path, on: queue) { [weak self] in
                    self?.bindAndListen()
                }
            }
            return
        }
        reclaim?.cancel()
        reclaim = nil
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { Self.log("socket() failed: \(errno)"); return }

        guard var address = LocalSocket.address(for: path) else {
            Self.log("socket path too long: \(path)")
            close(descriptor)
            return
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { Self.log("bind() failed: \(errno)"); close(descriptor); return }
        guard listen(descriptor, 16) == 0 else {
            Self.log("listen() failed: \(errno)"); close(descriptor); return
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(descriptor) }
        listenDescriptor = descriptor
        self.source = source
        source.resume()
        watchForReplacement(path)
    }

    private func watchForReplacement(_ path: String) {
        pathWatch = LocalSocket.watchForReplacement(of: path, on: queue) { [weak self] in
            guard let self else { return }
            Self.log("app socket was replaced — rebinding")
            self.pathWatch?.cancel()
            self.pathWatch = nil
            self.source?.cancel()
            self.source = nil
            self.listenDescriptor = -1
            self.bindAndListen()
        }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenDescriptor, nil, nil)
            if client < 0 {
                // EINTR is a signal, not an empty queue: retry rather than leaving a
                // pending connection unaccepted until the next source event.
                if errno == EINTR { continue }
                break
            }
            // A client connection must not leak into spawned PTY children: forkpty
            // duplicates every open descriptor, and an inherited copy keeps the
            // socket alive after our close — the CLI then never sees EOF and hangs
            // until its own timeout. CLOEXEC closes the copies at the child's exec.
            // (Measured: a spawn burst held every in-flight reply open for the
            // CLI's full 15s timeout; see sessions-cli-v2.md §4.2 verification.)
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            // A reply written to a client that hung up must not signal the whole app:
            // the write now retries past a full send buffer, so it can outlive a CLI
            // that Ctrl-C'd mid-transfer and would otherwise raise SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            handle(client)
        }
    }

    /// How long a client has to finish sending its request. Enforced with `poll`,
    /// not `SO_RCVTIMEO`: these descriptors are non-blocking (see `SocketIO`), so a
    /// receive timeout would never arm — `read` answers EAGAIN long before it.
    private static let requestTimeout: TimeInterval = 3
    /// How long a reply may take to drain into a client that is reading slowly.
    /// Comfortably under the CLI's own 15s bound, so a wedged transfer surfaces as
    /// this side hanging up rather than as the client timing out.
    private static let replyTimeout: TimeInterval = 10

    private func handle(_ descriptor: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var request: ControlRequest?
        let deadline = Date().addingTimeInterval(Self.requestTimeout)
        readLoop: while data.count < 256 * 1024 {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                if let decoded = Self.decode(data) { request = decoded; break }
                continue
            }
            // Zero is the one answer that really means "no more is coming": the peer
            // closed its write side. Everything else needs the errno to tell a
            // finished request from an unfinished one.
            if count == 0 { break }
            switch errno {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK:
                // Nothing has arrived *yet*. `accept` returns the instant the connect
                // lands — routinely before the client's write does — so this is the
                // normal state of the very first read, not an empty request. Treating
                // it as EOF is what answered "malformed request" to perfectly good
                // requests whenever the app was busy enough to win that race.
                guard SocketIO.waitReadable(descriptor, until: deadline) else { break readLoop }
            default: break readLoop
            }
        }
        let decoded = request ?? Self.decode(data)
        guard let decoded else {
            // The request never decoded, so its `format` is unknowable — reply in the
            // documented JSON error shape, which the text-mode CLI also recognizes
            // (it matches on `"ok":false`). Only hand-rolled clients ever hit this.
            Self.writeAll(descriptor, Data(
                "{\"ok\":false,\"error\":\"bad_request\",\"message\":\"malformed request\",\"schema_version\":1}\n".utf8))
            close(descriptor)
            return
        }
        // `watch` is the one streaming op: the connection is not answered and closed
        // but handed to `SessionWatchHub`, which pushes a line per status transition
        // until the client disconnects. Everything else is one-shot request/response.
        if decoded.op == "watch" {
            let resolve = onWatch
            Task { @MainActor in
                let (projectID, errorData, snapshot) = resolve(decoded)
                self.queue.async {
                    if let errorData {
                        Self.writeAll(descriptor, errorData)
                        close(descriptor)
                        return
                    }
                    guard let projectID else { close(descriptor); return }
                    SessionWatchHub.shared.subscribe(
                        descriptor: descriptor, projectID: projectID,
                        states: Self.watchStates(decoded.text), wantsJSON: decoded.wantsJSON,
                        snapshot: snapshot)
                }
            }
            return
        }
        // The handler touches `TermioStore`, so it must run on the main actor; the
        // reply is written back on this private queue so the socket work stays off
        // the main thread.
        let handler = onRequest
        Task { @MainActor in
            let response = await handler(decoded)
            self.queue.async {
                Self.writeAll(descriptor, response)
                close(descriptor)
            }
        }
    }

    /// The status filter a `watch` client asked for, carried in the request's `text`
    /// field as a comma-separated list. Empty means the two states a supervisor acts
    /// on — a session finishing (`done`) or stopping to ask (`needs-you`).
    private static func watchStates(_ text: String?) -> Set<String> {
        let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return ["done", "needs-you"] }
        return Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    @discardableResult
    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        SocketIO.writeAll(descriptor, data, timeout: replyTimeout)
    }

    private static func decode(_ data: Data) -> ControlRequest? {
        try? JSONDecoder().decode(ControlRequest.self, from: data)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: app socket \(message)\n".utf8))
    }
}

/// One status transition, pushed to every `termio sessions watch` client scoped to
/// the session's project and interested in the new state. Built on the main actor
/// (where `setStatus` lives) and handed to `SessionWatchHub`, which does the socket
/// writes off the main thread.
struct SessionWatchEvent {
    let projectID: UUID
    /// Canonical deep link (`termio://session/<uuid>`) — the address that
    /// survives promotion (docs/design/20260801-session-deep-link.md).
    let link: String
    /// Wire status token (`working` / `idle` / `done` / `needs-you`), or the
    /// watch-plane `stalled` — a supervision judgment broadcast without ever
    /// becoming the session's real status.
    let status: String
    let title: String
    let cwd: String
    /// Marks the initial current-status lines emitted on subscribe, so a JSON
    /// consumer can tell "already was" from a live transition.
    var snapshot = false
    /// `needs-you` only: the on-screen question excerpt, so a supervisor can act
    /// without a round-trip to scrape the viewport (design doc §4.3).
    var prompt: String? = nil
    /// `done` only: the transcript address plus its line count now, so the reply
    /// is readable without another `list --json` round-trip.
    var transcript: String? = nil
    var cursorEnd: Int? = nil
    /// `stalled` only: the stall detector's reasoning ("working 42m, no repo
    /// change, transcript +3 lines"). `stalled` is a watch-plane signal, never a
    /// session's real status — see the loop-level stall detection in
    /// `TermioStore+AgentStatus` (design doc §4.7).
    var evidence: String? = nil
}

/// Holds the open `watch` connections and fans status transitions out to them. A
/// `watch` is the one long-lived control connection: unlike request/response, the
/// socket stays open and this hub pushes a line whenever a scoped session changes
/// state, until the client goes away.
///
/// Everything runs on a private serial queue so a slow or dead reader never blocks
/// the agent tick that produced the event. A dead client is detected lazily — on the
/// next write that fails — rather than by watching the socket for EOF: a piped CLI
/// client (`… | nc -U`) half-closes its write side as soon as it has sent the
/// request, which would look like a disconnect while the client is very much still
/// reading. `SO_NOSIGPIPE` keeps that failing write from signalling the whole app.
// @unchecked: every mutable property is confined to `queue`, per the isolation
// story above; the queue is the synchronization the compiler cannot see.
final class SessionWatchHub: @unchecked Sendable {
    static let shared = SessionWatchHub()

    private struct Subscriber {
        let projectID: UUID
        let states: Set<String>
        let wantsJSON: Bool
        /// When the hub last successfully wrote to this client — the silence the
        /// 30s heartbeat measures.
        var lastWrite: Date
    }

    private let queue = DispatchQueue(label: "com.termio.session-watch")
    private var subscribers: [Int32: Subscriber] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    private static let heartbeatInterval: TimeInterval = 30

    /// Adopt a client descriptor as a watcher. Ownership of the fd transfers here —
    /// the hub closes it when the client disconnects. `snapshot` is written first:
    /// one line per scoped session with its *current* status, so a supervisor
    /// attaching late still learns a session is already `needs-you` (no
    /// `list`-then-`watch` race). The snapshot ignores the state filter — it is a
    /// roster, not a transition.
    func subscribe(
        descriptor: Int32, projectID: UUID, states: Set<String>, wantsJSON: Bool,
        snapshot: [SessionWatchEvent]
    ) {
        queue.async {
            var on: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on,
                       socklen_t(MemoryLayout<Int32>.size))
            for var event in snapshot {
                event.fillCursorIfNeeded()
                guard Self.write(descriptor, wantsJSON ? event.jsonLine : event.wireLine) else {
                    close(descriptor)
                    return
                }
            }
            self.subscribers[descriptor] = Subscriber(
                projectID: projectID, states: states, wantsJSON: wantsJSON, lastWrite: Date())
            self.startHeartbeatIfNeeded()
        }
    }

    /// Push an event to every matching subscriber. Called from the main actor via
    /// `TermioStore.setStatus`; the work hops onto the hub's queue immediately.
    func broadcast(_ event: SessionWatchEvent) {
        queue.async {
            guard !self.subscribers.isEmpty else { return }
            var event = event
            event.fillCursorIfNeeded()
            let line = event.wireLine
            let jsonLine = event.jsonLine
            for (fd, sub) in self.subscribers {
                guard sub.projectID == event.projectID, sub.states.contains(event.status)
                else { continue }
                if Self.write(fd, sub.wantsJSON ? jsonLine : line) {
                    self.subscribers[fd]?.lastWrite = Date()
                } else {
                    self.subscribers.removeValue(forKey: fd)
                    close(fd)
                }
            }
        }
    }

    /// A `{"heartbeat":true}` line after 30s of silence, JSON subscribers only —
    /// heartbeats are for programs; a human watching text mode just sees quiet.
    /// Doubles as proactive dead-reader reaping: a failed heartbeat write reaps the
    /// subscriber now instead of on the next (possibly far-off) transition.
    private func startHeartbeatIfNeeded() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval,
            leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.sendHeartbeats() }
        heartbeatTimer = timer
        timer.resume()
    }

    private func sendHeartbeats() {
        if subscribers.isEmpty {
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            return
        }
        let line = Data("{\"heartbeat\":true}\n".utf8)
        let now = Date()
        for (fd, sub) in subscribers {
            guard sub.wantsJSON,
                  now.timeIntervalSince(sub.lastWrite) >= Self.heartbeatInterval else { continue }
            if Self.write(fd, line) {
                subscribers[fd]?.lastWrite = now
            } else {
                subscribers.removeValue(forKey: fd)
                close(fd)
            }
        }
    }

    /// How long a watcher may leave a pushed line undrained before the hub gives up
    /// on it. Shorter than the request/response bound: a live `watch` client reads
    /// continuously, so silence this long is a client that stopped consuming.
    private static let writeTimeout: TimeInterval = 5

    /// Full write; returns false when the reader is gone or has stopped draining
    /// for `writeTimeout` (so the caller reaps the subscriber). A momentarily full
    /// send buffer is neither: the snapshot a large project emits on attach runs
    /// past 8 KiB, and treating that as a dead reader dropped the subscriber
    /// mid-roster.
    private static func write(_ fd: Int32, _ data: Data) -> Bool {
        SocketIO.writeAll(fd, data, timeout: writeTimeout)
    }
}

private extension SessionWatchEvent {
    /// Fills `cursorEnd` for a `done` event from its transcript's current line
    /// count. Called on `SessionWatchHub`'s serial queue, off the main thread —
    /// the count is an O(file) read the main actor must not do (see
    /// `TermioStore.lineCount`). Idempotent: only a `done` event carrying a
    /// transcript path but no cursor yet reads the file.
    mutating func fillCursorIfNeeded() {
        guard status == "done", cursorEnd == nil, let transcript else { return }
        cursorEnd = TermioStore.lineCount(of: transcript)
    }

    var wireLine: Data {
        let suffix = title.isEmpty ? "" : "  \(title)"
        let detail = evidence.map { "  — \($0)" } ?? ""
        return Data("\(link)  [\(status)]\(suffix)\(detail)\n".utf8)
    }
    var jsonLine: Data {
        var object: [String: Any] = [
            "schema_version": 1, "link": link, "status": status, "title": title,
        ]
        // Omitted, not "": the runtime simply hasn't seen an OSC 7 yet, and an
        // empty string reads like a real (broken) path to a JSON consumer.
        if !cwd.isEmpty { object["cwd"] = cwd }
        if snapshot { object["snapshot"] = true }
        if let prompt { object["prompt"] = prompt }
        if let transcript { object["transcript"] = transcript }
        if let cursorEnd { object["cursor_end"] = cursorEnd }
        if let evidence { object["evidence"] = evidence }
        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }
}

/// Installs and audits the `termio` command-line tool — the bundled script the
/// app symlinks onto the user's PATH so any shell (and any agent's shell tool)
/// can run `termio sessions …` and `termio .`. Modeled on VS Code's `code` tool,
/// with one twist: the symlink (and every agent hook) points at a channel-stable
/// *copy* under Application Support, not into the bundle, because the bundle's
/// location is transient — a dev build launched from a since-deleted git worktree
/// once took every hook that referenced its path down with it. The copy's path
/// never changes; each launch refreshes its content from the running bundle.
enum CommandLineTool {
    /// The tool's name on PATH and inside the bundle: `termio` for a release build,
    /// `termio-dev` for the side-by-side dev channel, so the dev app links its own
    /// CLI instead of clobbering the release one.
    static var toolName: String { "termio" + AppChannel.suffix }

    /// Where the tool is linked onto PATH. `/usr/local/bin` is on the default PATH
    /// and is user-writable on Homebrew Macs; otherwise install falls back to a
    /// one-time admin prompt.
    static var installURL: URL { URL(fileURLWithPath: "/usr/local/bin/\(toolName)") }

    enum Status: Equatable {
        /// Linked to this channel's stable tool copy — nothing to do.
        case installed
        /// Linked to an old-style bundle path, or the copy behind the link is
        /// missing; offer to update the install.
        case stale(String)
        /// Nothing occupies the PATH location yet.
        case notInstalled
        /// A file that termio did not create sits at the location; never clobber it.
        case conflict
        /// No bundled tool and no previously installed copy (a bare `swift run`
        /// binary on a fresh machine), so there is nothing to link.
        case unavailable
    }

    /// The bundled tool inside the running `.app`, or `nil` when running as a bare
    /// SwiftPM binary (`swift run`) where there is no Resources directory.
    static var bundledURL: URL? {
        Bundle.main.url(forResource: toolName, withExtension: nil)
    }

    /// The channel-stable copy of the tool (`…/Application Support/termio[-dev]/bin/`)
    /// — the only path hook files and the PATH symlink ever reference.
    static var supportCopyURL: URL {
        AppChannel.supportDirectory.appendingPathComponent("bin/\(toolName)")
    }

    /// Aligns the support copy's content with the bundled tool. A bare `swift run`
    /// binary has no bundle to copy from, so an existing copy (from the last real
    /// app build) is left serving. Returns whether a usable copy exists afterwards.
    @discardableResult
    static func refreshSupportCopy() -> Bool {
        let fileManager = FileManager.default
        let copy = supportCopyURL
        guard let bundled = bundledURL, let content = try? Data(contentsOf: bundled) else {
            return fileManager.isExecutableFile(atPath: copy.path)
        }
        if (try? Data(contentsOf: copy)) != content {
            do {
                try fileManager.createDirectory(
                    at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: copy, options: .atomic)
            } catch {
                FileHandle.standardError.write(
                    Data("termio: command-line tool copy failed: \(error)\n".utf8))
                return fileManager.isExecutableFile(atPath: copy.path)
            }
        }
        // An atomic write lands with default (non-executable) permissions, and hooks
        // exec the copy directly, so re-assert the mode even on the unchanged path.
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        return true
    }

    static func audit() -> Status {
        let fileManager = FileManager.default
        let copyUsable = fileManager.isExecutableFile(atPath: supportCopyURL.path)
        guard copyUsable || bundledURL != nil else { return .unavailable }
        let path = installURL.path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return fileManager.fileExists(atPath: path) ? .conflict : .notInstalled
        }
        // A real file (not our symlink) means someone else's `termio` — leave it.
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
            return .conflict
        }
        let resolved = URL(fileURLWithPath: destination).standardizedFileURL.path
        if resolved == supportCopyURL.standardizedFileURL.path {
            return copyUsable ? .installed : .stale(resolved)
        }
        // A link into any app bundle is a pre-copy install (or a moved app); update it.
        if resolved.hasSuffix("/Contents/Resources/\(toolName)") { return .stale(resolved) }
        return .conflict
    }

    /// Links the stable tool copy onto PATH and returns the fresh audit. Replaces
    /// our own stale link; refuses to overwrite a file we did not create.
    @discardableResult
    static func install() -> Status {
        guard refreshSupportCopy() else { return .unavailable }
        if case .conflict = audit() { return .conflict }
        let target = installURL.path
        if linkWithoutPrivileges(from: supportCopyURL.path, to: target) { return audit() }
        let directory = (target as NSString).deletingLastPathComponent
        runWithAdminPrompt(
            "mkdir -p \(shellQuote(directory)) && ln -sf \(shellQuote(supportCopyURL.path)) \(shellQuote(target))",
            label: "install")
        return audit()
    }

    /// Removes our PATH symlink and returns the fresh audit. Only ever deletes a
    /// link the audit attributes to termio (installed or stale); a conflicting
    /// file someone else created is left alone.
    @discardableResult
    static func uninstall() -> Status {
        let current = audit()
        switch current {
        case .installed, .stale:
            let target = installURL.path
            if removeWithoutPrivileges(at: target) { return audit() }
            runWithAdminPrompt("rm \(shellQuote(target))", label: "uninstall")
            return audit()
        case .notInstalled, .conflict, .unavailable:
            return current
        }
    }

    private static func removeWithoutPrivileges(at target: String) -> Bool {
        let directory = (target as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: directory) else { return false }
        do {
            try FileManager.default.removeItem(atPath: target)
            return true
        } catch {
            return false
        }
    }

    private static func linkWithoutPrivileges(from source: String, to target: String) -> Bool {
        let fileManager = FileManager.default
        let directory = (target as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard fileManager.isWritableFile(atPath: directory) else { return false }
        // Replace our own previous link (createSymbolicLink fails if a file exists).
        try? fileManager.removeItem(atPath: target)
        do {
            try fileManager.createSymbolicLink(atPath: target, withDestinationPath: source)
            return true
        } catch {
            return false
        }
    }

    /// One authorization prompt runs the command as admin, for the case where
    /// `/usr/local/bin` is root-owned. The user can cancel, in which case the
    /// follow-up audit simply reports the state unchanged.
    private static func runWithAdminPrompt(_ command: String, label: String) {
        let script = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            FileHandle.standardError.write(
                Data("termio: command-line tool \(label) declined or failed: \(error)\n".utf8))
        }
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

