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

    /// Remote PTY bytes for the terminal. Fired on a URLSession queue.
    var onOutput: ((Data) -> Void)?
    /// State transitions, delivered on the main queue.
    var onState: ((State) -> Void)?
    /// A rendered trace document arrived (reply to `requestTrace`). Delivered
    /// on the main queue.
    var onTrace: ((String) -> Void)?

    init(url: URL, attachSessionID: String? = nil) {
        self.url = url
        self.attachSessionID = attachSessionID
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
                        }
                    } else {
                        switch CompanionControl.decode(text) {
                        case .exit:
                            finish(.closed)
                        case .error(let message):
                            finish(.failed(message))
                        case .traceHTML(_, let html):
                            DispatchQueue.main.async { [onTrace] in onTrace?(html) }
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
        DispatchQueue.main.async { [onState] in onState?(state) }
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
        gridLock.unlock()
        if let attachSessionID {
            let attach = CompanionControl.attach(sessionID: attachSessionID).encoded()
            task.send(.string(attach)) { _ in }
        }
        // The grid must follow the attach on every connect — the server's
        // repaint of the freshly wiped screen is driven by this claim.
        sendGrid()
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
