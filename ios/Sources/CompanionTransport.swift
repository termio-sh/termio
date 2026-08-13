import Foundation
import TermioShared
import UIKit

/// v1 companion transport: a WebSocket to the Mac companion server (directly on
/// LAN, or via a tunnel URL). Binary frames are raw PTY bytes; text frames are
/// `CompanionControl` JSON. `TerminalViewController` bridges it to an
/// `InMemoryTerminalSession`.
///
/// The link self-heals: any socket drop (Mac app rebuild, phone sleep, network
/// blip) schedules a backoff reconnect and re-attaches, and the server replays
/// its ring buffer on attach so the screen repaints. Only a server-sent `exit`
/// (the session ended) or `error` (the session no longer exists — e.g. the Mac
/// app restarted) ends the loop.
///
/// E2E encryption (CryptoKit) wraps the payloads in the next pass; the PoC
/// proves the transport + PTY bridge first.
final class CompanionTransport: NSObject {
    enum State {
        case connecting
        case connected
        /// The socket dropped; a reconnect is scheduled. Not fatal.
        case reconnecting
        /// The server rejected us (e.g. the session died with a Mac restart). Fatal.
        case failed(String)
        /// The session exited on the Mac. Fatal.
        case closed
    }

    private let url: URL
    /// Roster session id to bridge; sent as an `attach` control the moment the
    /// socket opens. nil connects to a server that streams without attach
    /// (the standalone companion PoC).
    private let attachSessionID: String?
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    // Reconnect state, all touched on the main queue.
    private var stopped = true
    private var isConnected = false
    private var policy = ReconnectPolicy()
    private var foregroundObserver: NSObjectProtocol?
    /// Only touched on the delegate queue (see `didOpen`).
    private var everConnected = false
    /// Last grid the terminal reported, re-sent on every (re)connect and on
    /// foreground: the first resize often fires before the socket exists and
    /// would be silently lost, a reconnect never re-fires it (the view's size
    /// didn't change), and each report claims the PTY's winsize for this
    /// device (the Mac may have taken it back while the app was away).
    private var gridCols = 0
    private var gridRows = 0
    private let gridLock = NSLock()
    /// Guards send order: `auth` must be the first frame on the socket. The
    /// terminal view calls `resize` (→ `sendGrid`) as it lays out, which can land
    /// after `task.resume()` but before `didOpen` — URLSession then flushes that
    /// queued `resize` *ahead* of the `auth` `didOpen` sends. The server refuses
    /// any non-`auth` control on an unauthenticated connection, so that stray
    /// `resize` trips "unauthorized" before `auth` is ever read (the roster socket
    /// never sends anything but `auth`, which is why the list works and the
    /// terminal didn't). So grid and keystroke frames stay suppressed until
    /// `didOpen` has queued the auth preamble and set this true. Guarded by `gridLock`.
    private var authSent = false
    /// Raw PTY input stays closed until the Mac acknowledges auth with its
    /// roster. Control messages remain optimistic because their version-0
    /// meanings are stable. Guarded by `gridLock`.
    private var authAccepted = false
    /// Whether this connection has claimed the session's PTY. Guarded by
    /// `gridLock`; re-read on every connect, so the claim survives a reconnect
    /// exactly like the event subscription does.
    private var attachRequested: Bool
    /// Prompts written before the socket was usable, sent in order once it is.
    /// Guarded by `gridLock`.
    private var pendingPrompts: [Data] = []
    /// Whether a prompt is being held for the agent's TUI to finish painting.
    /// Guarded by `gridLock`, like the rest of the send-order state.
    private enum PromptGate {
        case open
        case waiting(deadline: Date)

        var isWaiting: Bool { if case .waiting = self { true } else { false } }

        /// Settled once the screen has been quiet for `quietFor` — or once the
        /// deadline passes, because a prompt held forever is the same bug as a
        /// prompt thrown away.
        func isSettled(quietFor: TimeInterval, at now: Date, lastOutput: Date) -> Bool {
            guard case .waiting(let deadline) = self else { return false }
            if now >= deadline { return true }
            return now.timeIntervalSince(lastOutput) >= quietFor
        }
    }
    private var promptGate = PromptGate.open
    /// How long the screen must be still before a prompt is typed into it.
    private static let quietWindow: TimeInterval = 0.7
    /// When the last PTY frame arrived. Written on the URLSession queue, read
    /// under `gridLock` by the gate check.
    private var lastOutputAt = Date.distantPast
    /// The content-plane cursor, or nil when nothing is watching this session's
    /// conversation. Advanced from arriving batches so a reconnect asks for the
    /// gap rather than the whole transcript. Guarded by `gridLock`.
    private var eventsCursor: Int?

    /// Remote PTY bytes for the terminal. Fired on a URLSession queue.
    var onOutput: ((Data) -> Void)?
    /// The link's current state. A view that adopts a socket someone else
    /// already opened has missed every transition it made, so the state is kept
    /// and replayed to a newly assigned observer — otherwise a terminal joining
    /// a live connection shows "Connecting…" until the next drop.
    private(set) var state: State = .connecting
    /// State transitions, delivered on the main queue.
    var onState: ((State) -> Void)? {
        didSet {
            guard let onState else { return }
            let current = state
            DispatchQueue.main.async { onState(current) }
        }
    }
    /// A rendered trace document arrived (reply to `requestTrace`). Delivered
    /// on the main queue.
    var onTrace: ((String) -> Void)?
    /// A batch of content-plane events arrived — either the backlog replayed
    /// after `subscribeEvents`, or a live update. Delivered on the main queue.
    var onAgentEvents: (([AgentEvent]) -> Void)?

    /// `attachesOnConnect: false` opens the session's socket without claiming
    /// its PTY. Reading a conversation must not start a shell: the Mac creates
    /// a session's process on first attach, so a chat opened on a finished
    /// session would otherwise bring it back to life just by being read. The
    /// terminal calls `attachPTY()` when it actually needs bytes.
    init(url: URL, attachSessionID: String? = nil, attachesOnConnect: Bool = true) {
        self.url = url
        self.attachSessionID = attachSessionID
        attachRequested = attachesOnConnect
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        stopped = false
        policy.reset()
        notify(.connecting)
        connect()
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, !stopped else { return }
                if isConnected {
                    // The link survived the background trip; coming back to
                    // the app is still a claim — the Mac may have taken the
                    // winsize while we were away.
                    reassertGrid()
                } else {
                    // Skip any pending backoff — the user is looking at the
                    // screen now.
                    policy.reset()
                    connect()
                }
            }
        }
    }

    func send(_ data: Data) {
        gridLock.lock()
        let ready = authAccepted
        gridLock.unlock()
        guard ready else { return }
        // Binary frames are raw PTY bytes permanently. Compression, encryption,
        // or multiplexing needs a separately negotiated mechanism and Wire gate
        // so a stale Mac can never interpret framing as keystrokes.
        task?.send(.data(data)) { _ in }
    }

    /// Submit a prompt to the agent: the text as one bracketed paste, then a
    /// carriage return.
    ///
    /// The framing is what keeps a multi-line message from submitting itself
    /// line by line — every agent TUI enables mode 2004 — and the bytes ride the
    /// binary channel, which reaches the PTY verbatim. (The Mac's own snippet
    /// path carries a warning about this: routed through a terminal surface's
    /// text encoder instead, the ESC becomes a key press and the TUI shows a
    /// literal `[200~`.)
    ///
    /// Typing at a session is the one act that legitimately starts it, so this
    /// claims the PTY if the connection had not already.
    func sendPrompt(_ text: String) {
        let started = attachPTY()
        var payload = Data(("\u{1B}[200~" + text + "\u{1B}[201~").utf8)
        payload.append(contentsOf: Data("\r".utf8))

        gridLock.lock()
        let ready = authAccepted
        // A session the phone just woke has no agent behind it yet: the Mac
        // spawns the process, the CLI boots, and only when its TUI has painted
        // is there an input line to type into. Bytes written before that are
        // read by whatever holds the PTY at the time and are simply gone — the
        // message disappears, no turn starts, and nothing ever streams back, so
        // the lens looks broken in both directions at once. A prompt that
        // started the session therefore waits for the screen to settle.
        // Not just a cold attach: the container opens the terminal first, so by
        // the time you switch to the lens and type, the session was attached
        // seconds ago and the agent is still booting. A screen that is actively
        // painting is one with nothing ready to read input, whoever attached it.
        let painting = Date().timeIntervalSince(lastOutputAt) < Self.quietWindow
        if started || painting { promptGate = .waiting(deadline: Date().addingTimeInterval(12)) }
        // A message typed before the socket finished authenticating, or while
        // it is down, waits rather than disappearing — the one thing a chat may
        // never do with something you wrote. Keystrokes are not queued: a key
        // replayed late lands in whatever the TUI is showing by then.
        let promptGateArmed = promptGate.isWaiting
        let holding = !ready || promptGateArmed
        if holding { pendingPrompts.append(payload) }
        gridLock.unlock()
        guard !holding else {
            if promptGateArmed { scheduleGateCheck() }
            return
        }
        task?.send(.data(payload)) { _ in }
    }

    /// Polls for the agent's TUI to finish painting, then releases the prompt
    /// held in `sendPrompt`. Quiet output is the readiness signal available to a
    /// client: the Mac knows a process exists, but only the bytes say the CLI is
    /// done drawing and is sitting at its prompt.
    private func scheduleGateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !stopped else { return }
            gridLock.lock()
            let settled = promptGate.isSettled(
                quietFor: Self.quietWindow, at: Date(), lastOutput: lastOutputAt)
            if settled { promptGate = .open }
            let stillWaiting = promptGate.isWaiting
            gridLock.unlock()
            if settled {
                flushPendingPrompts()
            } else if stillWaiting {
                scheduleGateCheck()
            }
        }
    }

    /// Flush prompts written while the link was down, oldest first.
    private func flushPendingPrompts() {
        gridLock.lock()
        // Auth landing is not the same as the agent being ready: a prompt that
        // woke a session stays held until the gate opens, whichever finishes
        // first.
        guard !promptGate.isWaiting else {
            gridLock.unlock()
            return
        }
        let queued = pendingPrompts
        pendingPrompts.removeAll()
        gridLock.unlock()
        for payload in queued {
            task?.send(.data(payload)) { _ in }
        }
    }

    func resize(cols: Int, rows: Int) {
        gridLock.lock()
        gridCols = cols
        gridRows = rows
        gridLock.unlock()
        sendGrid()
    }

    /// Re-claims the PTY's winsize for this device — called when the user
    /// comes back to this screen (re-opening a parked session).
    func reassertGrid() {
        sendGrid()
    }

    /// Claim the session's PTY on this socket. Idempotent, and safe to call
    /// before the socket is open — the claim is remembered and sent with the
    /// auth preamble, the same way the event subscription is.
    ///
    /// Returns whether *this* call made the claim, which is the only moment a
    /// dormant session can start a process — and so the only moment a prompt
    /// has to wait for one (see `sendPrompt`).
    @discardableResult
    func attachPTY() -> Bool {
        gridLock.lock()
        let alreadyAttached = attachRequested
        attachRequested = true
        let ready = authSent
        gridLock.unlock()
        guard !alreadyAttached else { return false }
        guard ready, let attachSessionID else { return true }
        task?.send(.string(CompanionControl.attach(sessionID: attachSessionID).encoded())) { _ in }
        sendGrid()
        return true
    }

    /// Ask the Mac to render this session's agent transcript as an HTML trace;
    /// the reply arrives on `onTrace`. `dark` is the phone's own light/dark
    /// trait so the page matches. No-op until the socket is authed.
    func requestTrace(dark: Bool) {
        gridLock.lock()
        let ready = authSent
        gridLock.unlock()
        guard ready, let attachSessionID else { return }
        let control = CompanionControl.trace(sessionID: attachSessionID, dark: dark).encoded()
        task?.send(.string(control)) { _ in }
    }

    /// Subscribe to this session's conversation events. `since` is the highest
    /// `seq` already held, so a reconnect asks only for the gap — the same
    /// cursor the PTY ring buffer uses, which is why re-attaching after a tunnel
    /// blip does not re-download the whole conversation.
    ///
    /// The subscription is *remembered*, not fired once. A lens opened before
    /// the socket finished authenticating, and a socket that dropped and came
    /// back, both have to end up subscribed — the first was a race that left the
    /// view permanently empty, and the second is the normal life of a phone.
    func subscribeEvents(since: Int) {
        gridLock.lock()
        eventsCursor = max(eventsCursor ?? 0, since)
        let cursor = eventsCursor ?? 0
        let ready = authSent
        gridLock.unlock()
        guard ready, let attachSessionID else { return }
        let control = CompanionControl.subscribeEvents(sessionID: attachSessionID, since: cursor)
        task?.send(.string(control.encoded())) { _ in }
    }

    /// Stop wanting events — the lens was dismissed. The Mac's pump retires with
    /// the connection, so this only stops *this* end from re-subscribing on
    /// every reconnect while nobody is looking.
    func stopEvents() {
        gridLock.lock()
        eventsCursor = nil
        gridLock.unlock()
        onAgentEvents = nil
    }

    /// Re-issues a remembered subscription on a fresh socket. Called from
    /// `didOpen` after the attach so the two planes come back in the same order
    /// they were established.
    private func resubscribeEvents() {
        gridLock.lock()
        let cursor = eventsCursor
        gridLock.unlock()
        guard let cursor, let attachSessionID else { return }
        let control = CompanionControl.subscribeEvents(sessionID: attachSessionID, since: cursor)
        task?.send(.string(control.encoded())) { _ in }
    }

    private func sendGrid() {
        gridLock.lock()
        let cols = gridCols
        let rows = gridRows
        let ready = authSent
        gridLock.unlock()
        guard ready, cols > 0, rows > 0 else { return }
        let control = CompanionControl.resize(cols: cols, rows: rows).encoded()
        task?.send(.string(control)) { _ in }
    }

    func stop() {
        stopped = true
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        task?.cancel(with: .goingAway, reason: nil)
        let task = session.webSocketTask(with: url)
        // The server replays the session's ring buffer (up to 1 MB) as a single
        // binary frame on attach; the 1 MB default cap would kill the socket
        // mid-replay and loop the link in "Reconnecting…" forever.
        task.maximumMessageSize = 8 << 20
        self.task = task
        // A fresh socket has not sent its auth preamble yet — suppress grid and
        // keystroke frames until `didOpen` does, so nothing precedes `auth`.
        gridLock.lock()
        authSent = false
        authAccepted = false
        gridLock.unlock()
        task.resume()
        receive(on: task)
    }

    /// The socket died mid-session. Keep trying — the usual cause is the Mac
    /// app rebuilding, and re-attach is idempotent (the server replays the
    /// session's ring buffer to a fresh attach).
    private func dropped(_ task: URLSessionWebSocketTask) {
        DispatchQueue.main.async { [weak self] in
            // A superseded task's death is not a drop of the current link.
            guard let self, task === self.task, !stopped else { return }
            isConnected = false
            notify(.reconnecting)
            // Fast burst then a slow heartbeat (see ReconnectPolicy): re-attach
            // is idempotent, so quick when the Mac's rebuilding, light when the
            // laptop's closed.
            let delay = policy.nextDelay()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !stopped, !isConnected else { return }
                connect()
            }
        }
    }

    /// A fatal control arrived — the session itself is over, stop reconnecting.
    private func finish(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !stopped else { return }
            stopped = true
            isConnected = false
            notify(state)
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    // The screen painting is the only readiness signal a client
                    // has for the agent behind the PTY; `sendPrompt` waits on it.
                    gridLock.lock()
                    lastOutputAt = Date()
                    gridLock.unlock()
                    onOutput?(data)
                case .string(let text):
                    if let roster = CompanionRoster.decode(text) {
                        if roster.wire < Wire.minimumServer {
                            task.cancel(with: .policyViolation, reason: nil)
                            finish(.failed(localized("Update Termio on your Mac to connect this phone.")))
                        } else {
                            gridLock.lock()
                            authAccepted = true
                            gridLock.unlock()
                            flushPendingPrompts()
                        }
                    } else {
                        switch CompanionControl.decode(text) {
                        case .exit:
                            finish(.closed)
                        case .error(let message):
                            finish(.failed(message))
                        case .traceHTML(_, let html):
                            DispatchQueue.main.async { [onTrace] in onTrace?(html) }
                        case .agentEvents(_, let events):
                            // The cursor lives here rather than in the view so a
                            // reconnect can ask for the gap even if the lens is
                            // mid-teardown when the socket dies.
                            if let highest = events.map(\.seq).max() {
                                gridLock.lock()
                                if let cursor = eventsCursor { eventsCursor = max(cursor, highest) }
                                gridLock.unlock()
                            }
                            DispatchQueue.main.async { [onAgentEvents] in onAgentEvents?(events) }
                        default:
                            break
                        }
                    }
                @unknown default:
                    break
                }
                receive(on: task)
            case .failure:
                dropped(task)
            }
        }
    }

    private func notify(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            self?.state = state
            self?.onState?(state)
        }
    }
}

extension CompanionTransport: URLSessionWebSocketDelegate {
    func urlSession(_: URLSession, webSocketTask task: URLSessionWebSocketTask,
                    didOpenWithProtocol _: String?) {
        // On a REconnect the terminal still shows the dead link's screen; a
        // full reset (RIS) ahead of the server's ring-buffer replay keeps the
        // two byte streams from interleaving into garbage. Emitted here on the
        // serial delegate queue so it precedes the replayed bytes.
        if everConnected {
            onOutput?(Data("\u{1B}c".utf8))
        }
        everConnected = true
        // Auth precedes the attach on the same socket — the server refuses
        // the bridge (and everything else) until the token lands.
        if let token = CompanionLink.token(of: url) {
            task.send(
                .string(CompanionControl.auth(token: token, wire: Wire.current).encoded())
            ) { _ in }
        } else {
            // No `?t=` on the URL: the Mac drops this socket after its ~10s
            // auth grace window, so the session just churns "Reconnecting…"
            // with no visible cause. Say so.
            Log.companion.error("session URL has no pairing token (?t=…) — the Mac will refuse this socket after ~10s. Re-pair via Settings ▸ Mobile.")
        }
        // Auth is now queued ahead of everything else, so grid/keystroke frames
        // may flow. `URLSessionWebSocketTask` preserves send-call order, so the
        // attach and grid below land after auth; and any external `resize` that
        // fired during the connect stayed suppressed until this moment.
        gridLock.lock()
        authSent = true
        let claimsPTY = attachRequested
        gridLock.unlock()
        if claimsPTY, let attachSessionID {
            let attach = CompanionControl.attach(sessionID: attachSessionID).encoded()
            task.send(.string(attach)) { _ in }
        }
        // The grid must follow the attach on every connect — the server's
        // repaint of the freshly wiped screen is driven by this claim.
        sendGrid()
        // Both planes re-establish on the same socket, in the same order, from
        // one `didOpen`: that is the whole point of carrying them together.
        resubscribeEvents()
        DispatchQueue.main.async { [weak self] in
            guard let self, task === self.task, !stopped else { return }
            isConnected = true
            policy.reset()
            notify(.connected)
        }
    }

    func urlSession(_: URLSession, webSocketTask task: URLSessionWebSocketTask,
                    didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        dropped(task)
    }
}
