import Foundation
import Network
import TermioShared
import UIKit

/// Receives the live project/session roster from the Mac companion server over
/// a WebSocket, so the home tree shows the same list the desktop sidebar does.
/// The link self-heals: any drop (Mac app restart, phone sleep, network blip)
/// schedules a jittered backoff reconnect; returning to the foreground or the
/// network path coming back retries at once; and a periodic ping catches
/// half-open sockets that would otherwise never fail `receive`. A fresh
/// connect repaints immediately because the server pushes the full roster on
/// accept.
final class CompanionClient: NSObject {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    // Main-queue delegate so all state and callbacks stay on one queue.
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var stopped = true
    private var isConnected = false
    private var policy = ReconnectPolicy()
    private var foregroundObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var pingTimer: Timer?
    /// `refuse()` sends one final `.error` and immediately cancels the socket,
    /// while request errors leave it open. Keep the last reason briefly so the
    /// close path can distinguish those two cases without expanding the wire.
    private var lastServerError: (message: String, uptime: TimeInterval)?
    private static let refusalCloseWindow: TimeInterval = 1

    /// Latest roster, delivered on the main queue.
    var onRoster: ((CompanionRoster) -> Void)?
    /// `true` once connected, `false` on drop — delivered on the main queue.
    var onConnected: ((Bool) -> Void)?
    /// A `start` we sent succeeded; the new session id is ready to attach.
    /// The second value is the agent the Mac actually launched (nil from an
    /// older Mac) — the only source of truth for an agent-less New Chat.
    var onStarted: ((String, String?) -> Void)?
    /// A directory listing arrived (reply to `.listFiles`).
    var onFileList: ((String, [WireFileEntry]) -> Void)?
    /// File contents arrived (reply to `.readFile`).
    var onFile: ((WireFile) -> Void)?
    /// A write we sent landed (reply to `.writeFile`): path + new mtime (ms).
    var onWritten: ((String, Int) -> Void)?
    /// An upload we sent landed (reply to `.upload`): absolute Mac path.
    var onUploaded: ((String) -> Void)?
    /// Filename-search matches (reply to `.searchFiles`): the echoed query,
    /// repo-relative paths, and whether the batch was capped.
    var onSearchResults: ((String, [String], Bool) -> Void)?
    /// The project's working-tree changes (reply to `.listChanges`).
    var onChanges: (([WireChange]) -> Void)?
    /// One file's unified diff (reply to `.readDiff`).
    var onDiff: ((WireDiff) -> Void)?
    /// The server rejected a request (e.g. a failed `start`).
    var onError: ((String) -> Void)?
    /// The server sent an error and immediately dropped the connection.
    var onConnectionFailure: ((String) -> Void)?
    /// The Mac's parsed `~/.ssh/config` host blocks, answering a
    /// `.sshConfigHosts` request — the read-only menu the Terminals ＋ → New SSH
    /// picks from (the phone never authors a host, only chooses a known alias).
    var onSSHConfig: (([WireSSHHost]) -> Void)?

    /// Controls sent before the socket is open wait here — auth must ride
    /// the wire first on every connect, so a `.upload` fired right after
    /// `start()` would otherwise reach the server ahead of the auth frame
    /// and be refused as unauthorized.
    private var pendingControls: [CompanionControl] = []

    /// Send a control message (e.g. `.start`) over the roster link. Queued
    /// until the connect + auth handshake if the link isn't up yet.
    func send(_ control: CompanionControl) {
        guard isConnected else {
            pendingControls.append(control)
            return
        }
        task?.send(.string(control.encoded())) { _ in }
    }

    init(url: URL) {
        self.url = url
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        stopped = false
        policy.reset()
        connect()
        startPathMonitor()
        startPingTimer()
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Skip any pending backoff — the socket rarely survives a trip
                // to the background, and the user is looking at the list now.
                guard let self, !stopped, !isConnected else { return }
                policy.reset()
                connect()
            }
        }
    }

    func stop() {
        stopped = true
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathStatus = nil
        lastServerError = nil
        pingTimer?.invalidate()
        pingTimer = nil
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        lastServerError = nil
        task?.cancel(with: .goingAway, reason: nil)
        let task = session.webSocketTask(with: url)
        // A `file` reply for a 1 MB source is ~1.4 MB of base64 JSON — past
        // the 1 MB default cap, which would kill the socket mid-read.
        task.maximumMessageSize = 8 << 20
        self.task = task
        task.resume()
        receive(on: task)
    }

    /// Force an immediate reconnect, dropping any pending backoff — the "Try
    /// Again" affordance on the stalled zero state.
    func reconnectNow() {
        guard !stopped, !isConnected else { return }
        policy.reset()
        connect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        // Fast burst then a slow heartbeat (see ReconnectPolicy): quick to
        // notice a rebuilt Mac, easy on the radio when the laptop's just closed.
        let delay = policy.nextDelay()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !stopped, !isConnected else { return }
            connect()
        }
    }

    private func takeErrorForImmediateDrop() -> String? {
        defer { lastServerError = nil }
        guard let lastServerError,
              ProcessInfo.processInfo.systemUptime - lastServerError.uptime
                <= Self.refusalCloseWindow else { return nil }
        return lastServerError.message
    }

    /// Reconnect the instant the network path comes back (Wi-Fi rejoin, VPN
    /// toggle) instead of sitting out a scheduled backoff.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, !stopped else { return }
            let cameUp = path.status == .satisfied
                && lastPathStatus != nil && lastPathStatus != .satisfied
            lastPathStatus = path.status
            guard cameUp, !isConnected else { return }
            policy.reset()
            connect()
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// A half-open socket (Mac slept, network switched under us) never fails
    /// `receive`; a periodic ping is what notices, and its failure forces the
    /// reconnect loop.
    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, !stopped, isConnected, let task else { return }
            task.sendPing { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !stopped, task === self.task, isConnected else { return }
                    isConnected = false
                    onConnected?(false)
                    policy.reset()
                    connect()
                }
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    if let roster = CompanionRoster.decode(text) {
                        lastServerError = nil
                        if roster.wire < Wire.minimumServer {
                            onConnectionFailure?(localized("Update Termio on your Mac to connect this phone."))
                            stop()
                        } else {
                            onRoster?(roster)
                        }
                    } else {
                        lastServerError = nil
                        switch CompanionControl.decode(text) {
                        case .started(let sessionID, let agent): onStarted?(sessionID, agent)
                        case .fileList(let path, let entries): onFileList?(path, entries)
                        case .file(let file): onFile?(file)
                        case .written(let path, let mtime): onWritten?(path, mtime)
                        case .uploaded(let path): onUploaded?(path)
                        case .searchResults(let query, let paths, let truncated):
                            onSearchResults?(query, paths, truncated)
                        case .changes(let files): onChanges?(files)
                        case .diff(let diff): onDiff?(diff)
                        case .error(let reason):
                            lastServerError = (
                                message: reason,
                                uptime: ProcessInfo.processInfo.systemUptime
                            )
                            onError?(reason)
                        case .sshConfigList(let hosts): onSSHConfig?(hosts)
                        default: break
                        }
                    }
                }
                receive(on: task)
            case .failure(let error):
                // A superseded task's death is not a drop of the current link.
                guard task === self.task else { return }
                Log.companion.notice("roster link dropped: \(error.localizedDescription, privacy: .public)")
                let connectionFailure = takeErrorForImmediateDrop()
                isConnected = false
                onConnected?(false)
                if let connectionFailure { onConnectionFailure?(connectionFailure) }
                scheduleReconnect()
            }
        }
    }
}

extension CompanionClient: URLSessionWebSocketDelegate {
    func urlSession(_: URLSession, webSocketTask task: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        guard task === self.task else { return }
        Log.companion.notice("roster link connected to \(self.url.host ?? "?", privacy: .public)")
        // Auth rides first on every connect; the roster is the server's reply.
        if let token = CompanionLink.token(of: url) {
            task.send(
                .string(CompanionControl.auth(token: token, wire: Wire.current).encoded())
            ) { _ in }
        } else {
            // No `?t=` on the paired URL: the socket opens, but the Mac refuses
            // it after its ~10s auth grace window, so the link loops
            // connect→unauthorized→reconnect with no visible cause. Say so.
            Log.companion.error("roster URL has no pairing token (?t=…) — the Mac will refuse this socket after ~10s. Re-pair via Settings ▸ Mobile.")
        }
        isConnected = true
        policy.reset()
        // Auth is on the wire; anything queued behind it follows in order.
        let queued = pendingControls
        pendingControls = []
        for control in queued {
            task.send(.string(control.encoded())) { _ in }
        }
        onConnected?(true)
    }

    func urlSession(_: URLSession, webSocketTask task: URLSessionWebSocketTask,
                    didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        guard task === self.task else { return }
        let connectionFailure = takeErrorForImmediateDrop()
        isConnected = false
        onConnected?(false)
        if let connectionFailure { onConnectionFailure?(connectionFailure) }
    }
}
