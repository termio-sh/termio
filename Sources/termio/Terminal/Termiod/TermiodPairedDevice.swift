import Foundation
import Network
import Security
import TermioShared

/// Another Mac this one is paired with: the address its Pairing section handed
/// out and the token that address demands. Reached over the WebSocket that Mac's
/// app splices onto its own daemon, so no SSH is involved and the far Mac needs
/// no Remote Login.
struct PairedDevice: Codable, Hashable, Identifiable {
    /// The far daemon's `host_id`, which is also the route's identity.
    let hostID: String
    var name: String
    /// The invite's reachable base, `http://100.74.228.124:8795`.
    let url: String
    let token: String

    var id: String { hostID }

    /// The invite's base rendered as the socket URL: same host and port, the
    /// ws(s) twin of its scheme, and the listener's `/ws` mount under whatever
    /// path the base carries. The same rule the phone applies to the same link.
    var websocketURL: URL? {
        guard var dial = URLComponents(string: url) else { return nil }
        switch dial.scheme?.lowercased() {
        case "https", "wss": dial.scheme = "wss"
        case "http", "ws": dial.scheme = "ws"
        default: return nil
        }
        dial.query = nil
        dial.fragment = nil
        let prefix = dial.path.hasSuffix("/") ? String(dial.path.dropLast()) : dial.path
        dial.path = prefix + "/ws"
        return dial.url
    }

    /// `scheme://host[:port]` of the invite's base, as the web spells it. A box's
    /// own listener (`wss.rs`) refuses a dial without an `Origin` that matches
    /// it, the browser CSRF defence, and a native client sends none on its own.
    /// The token stays what authenticates the pipe.
    var origin: String? {
        // `encodedHost`: the wire form, punycode and IPv6 brackets kept, which is
        // what a listener's pinned origin is written in.
        guard let base = URLComponents(string: url),
              let scheme = base.scheme?.lowercased(), let host = base.encodedHost else { return nil }
        let webScheme = scheme == "wss" ? "https" : (scheme == "ws" ? "http" : scheme)
        let port = base.port.map { ":\($0)" } ?? ""
        return "\(webScheme)://\(host)\(port)"
    }

    /// The `termio://device?url=…&token=…&host_id=…` link a Pairing section
    /// shows, as pasted. nil for anything else, including a link missing a part
    /// the dial needs.
    init?(link raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "termio",
              components.host?.lowercased() == "device"
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let url = value("url"), let token = value("token"),
              let hostID = value("host_id"),
              let host = URLComponents(string: url)?.host, !host.isEmpty
        else { return nil }
        self.init(hostID: hostID, name: value("name") ?? host, url: url, token: token)
        guard websocketURL != nil else { return nil }
    }

    init(hostID: String, name: String, url: String, token: String) {
        self.hostID = hostID
        self.name = name
        self.url = url
        self.token = token
    }
}

/// The paired Macs, kept in the login keychain: each record holds a token that
/// opens a shell on another machine, which is not something a defaults plist
/// should carry.
enum PairedDeviceStore {
    /// Per-channel, so a dev build pairs separately from the release app.
    static var service: String { "sh.termio.paired-device" + AppChannel.suffix }

    /// Posted after a Mac is paired or unpaired, on the main queue.
    static let didChange = Notification.Name("sh.termio.pairedDevicesDidChange")
    /// In `didChange`'s user info when the change was an unpair.
    static let unpairedHostIDKey = "unpairedHostID"

    /// The keychain read once per launch and kept in step by every write here:
    /// device names are drawn in menus and sidebar rows, which must not each
    /// cost a keychain query.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: PairedDevice]?

    private static func cached() -> [String: PairedDevice] {
        lock.withLock { loadedLocked() }
    }

    /// The cache, read from the keychain the first time. Callers hold `lock`,
    /// and so does every write: a keychain change and its cache update are one
    /// step, or a save finishing after an unpair would bring the record back.
    private static func loadedLocked() -> [String: PairedDevice] {
        if let cache { return cache }
        let (devices, complete) = readAll()
        let loaded = Dictionary(devices.map { ($0.hostID, $0) }) { first, _ in first }
        // A locked keychain or a declined prompt is not "nothing is paired".
        // Only a full read is kept, so the next call asks again.
        if complete { cache = loaded }
        return loaded
    }

    static func save(_ device: PairedDevice) throws {
        let data = try JSONEncoder().encode(device)
        try lock.withLock {
            _ = loadedLocked()
            try write(data, for: device)
            cache?[device.hostID] = device
        }
    }

    private static func write(_ data: Data, for device: PairedDevice) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: device.hostID,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "termio: \(device.name)",
        ]
        var status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(match.merging(update) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PairedDeviceError.keychain(status) }
    }

    static func device(hostID: String) -> PairedDevice? {
        cached()[hostID]
    }

    private enum Read {
        case found(PairedDevice)
        case missing
        case failed
    }

    static func all() -> [PairedDevice] {
        cached().values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func read(hostID: String) -> Read {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data else {
            Log.termiod.error("paired device \(hostID, privacy: .public) unreadable: \(status, privacy: .public)")
            return .failed
        }
        do {
            return .found(try JSONDecoder().decode(PairedDevice.self, from: data))
        } catch {
            // A record this build cannot decode will not decode on retry either.
            Log.termiod.error("paired device \(hostID, privacy: .public) undecodable: \(error.localizedDescription, privacy: .public)")
            return .missing
        }
    }

    /// Every paired Mac. Reads each record's data, which for an item this app
    /// wrote does not prompt.
    private static func readAll() -> (devices: [PairedDevice], complete: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return ([], true) }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            Log.termiod.error("paired devices unreadable: \(status, privacy: .public)")
            return ([], false)
        }
        var devices: [PairedDevice] = []
        var complete = true
        for hostID in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            switch read(hostID: hostID) {
            case .found(let device): devices.append(device)
            case .missing: break
            case .failed: complete = false
            }
        }
        return (devices, complete)
    }

    /// What to call the machine a host key names: a paired Mac's name, else the
    /// SSH alias itself, which is the name the user gave it.
    static func displayName(hostKey: String) -> String {
        if case .paired(let hostID) = TermiodRoute(hostKey: hostKey) {
            return device(hostID: hostID)?.name ?? localized("Paired Mac")
        }
        return hostKey
    }

    @discardableResult
    static func remove(hostID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID,
        ]
        return lock.withLock {
            _ = loadedLocked()
            let status = SecItemDelete(query as CFDictionary)
            let removed = status == errSecSuccess || status == errSecItemNotFound
            if removed { cache?[hostID] = nil }
            return removed
        }
    }
}

enum PairedDeviceError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
            return localized("Couldn’t save the pairing to the keychain: \(reason)")
        }
    }
}

/// One WebSocket to a paired Mac, presented to the rest of the client as a
/// file descriptor.
///
/// Every other route is a descriptor (a Unix socket, an ssh pipe), and the frame
/// reader, the attach loop and the control pool all read and write descriptors.
/// So this opens a socketpair, hands one end out, and copies bytes between the
/// other end and the WebSocket. It reads no frame: a WebSocket message is not a
/// protocol frame, and the far splice cuts the stream the same way.
final class WebSocketBridge: @unchecked Sendable {
    /// The descriptor the transport reads and writes. Closing it ends the
    /// WebSocket.
    let descriptor: Int32

    private let pumpDescriptor: Int32
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "sh.termio.termiod.websocket")
    private let lock = NSLock()
    private var finished = false
    /// When the far side last proved it is there. Touched only on `queue`.
    private var lastPong = ProcessInfo.processInfo.systemUptime

    /// A link that drops packets without closing reads as idle forever: the
    /// attach reader stays blocked and nothing reconnects. So the client pings
    /// and gives the link up when no pong comes back, the rule the phone's
    /// link uses too. Monotonic, so a Mac that slept is not counted as silent.
    static let pingInterval: TimeInterval = 15
    static let silenceLimit: TimeInterval = 50

    /// A dial that has not opened in this long is a Mac that is asleep, off the
    /// tailnet, or not serving, and the caller is better told so.
    static let openTimeout: TimeInterval = 10

    /// Every open bridge, by the paired Mac it reaches, so Unpair can end them
    /// all at once: a pooled channel or an attach must not outlive the pairing.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var openBridges: [String: [ObjectIdentifier: WebSocketBridge]] = [:]

    /// Ends every bridge to `hostID`. Their transports read the close as a lost
    /// connection and redial, which fails while the Mac is unpaired and succeeds
    /// once it is paired again.
    static func closeAll(hostID: String) {
        let closing = registryLock.withLock { openBridges.removeValue(forKey: hostID) ?? [:] }
        for bridge in closing.values { bridge.finish() }
    }

    private let hostID: String

    /// Opens the WebSocket and returns once it is up, or throws why not.
    ///
    /// `requiresPairing` is false only for the pairing sheet's dial, which is
    /// what decides whether there will be a pairing.
    static func open(_ device: PairedDevice, requiresPairing: Bool = true) throws -> WebSocketBridge {
        guard let url = device.websocketURL else {
            throw TermiodClientError.daemonUnreachable(device.url)
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw TermiodClientError.daemonUnreachable(device.url)
        }
        let bridge = WebSocketBridge(
            url: url, token: device.token, origin: device.origin, hostID: device.hostID,
            descriptors: pair)
        do {
            try bridge.waitUntilOpen(name: device.name)
        } catch {
            // No transport ever owned the outward end, so nobody else closes it,
            // and a reconnect loop against a Mac that is asleep would leak one
            // per attempt.
            Darwin.close(bridge.descriptor)
            throw error
        }
        // Checked and registered under one lock, so an Unpair that lands while
        // this dial was opening either sees the bridge or makes this check fail.
        let admitted = registryLock.withLock { () -> Bool in
            if requiresPairing, PairedDeviceStore.device(hostID: device.hostID)?.token != device.token {
                return false
            }
            openBridges[device.hostID, default: [:]][ObjectIdentifier(bridge)] = bridge
            return true
        }
        guard admitted else {
            bridge.finish()
            Darwin.close(bridge.descriptor)
            throw TermiodClientError.remoteFailed(localized(
                "This Mac is no longer paired. Pair it again from Settings ▸ Remote Hosts."))
        }
        bridge.startPumping()
        return bridge
    }

    private init(url: URL, token: String, origin: String?, hostID: String, descriptors: [Int32]) {
        self.hostID = hostID
        descriptor = descriptors[0]
        pumpDescriptor = descriptors[1]
        // A write into an end the transport has closed returns EPIPE rather
        // than raising SIGPIPE, whose default disposition ends the app.
        var on: Int32 = 1
        _ = setsockopt(pumpDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &on,
                       socklen_t(MemoryLayout<Int32>.size))
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = Termiod.maximumFrameSize
        // The token rides the subprotocol, as the phone sends it: a query string
        // on the Upgrade line would leak it into any proxy's log.
        websocket.setSubprotocols(["termiod.\(token)"])
        // Network.framework writes `Host` without the port, and a box's listener
        // compares host and port against `Origin` when no origin is pinned. So
        // both are stated here, from the same URL.
        var headers: [(name: String, value: String)] = []
        if let origin { headers.append(("Origin", origin)) }
        // The wire form, as for `Origin`: `URL.host` drops an IPv6 literal's
        // brackets, and `::1:8795` would read as a host named `:` on port 1.
        if let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost {
            headers.append(("Host", url.port.map { "\(host):\($0)" } ?? host))
        }
        websocket.setAdditionalHeaders(headers)
        let parameters = url.scheme == "wss" ? NWParameters.tls : NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    private func waitUntilOpen(name: String) throws {
        let opened = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                outcome.set(nil)
                opened.signal()
            case .waiting(let error):
                outcome.set(error)
                // A refused Upgrade arrives as an abort after TCP connected: the
                // splice turned the token down, and waiting will not change that.
                // Anything else is a host that does not answer, which
                // Network.framework waits on and the timeout below ends.
                if case .posix(.ECONNABORTED) = error { opened.signal() }
            case .failed(let error):
                outcome.set(error)
                opened.signal()
                self?.finish()
            case .cancelled:
                opened.signal()
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard opened.wait(timeout: .now() + Self.openTimeout) == .success,
              connection.state == .ready
        else {
            let error = outcome.error
            finish()
            if case .posix(.ECONNABORTED) = error {
                throw TermiodClientError.remoteFailed(localized(
                    "\(name) turned this Mac’s pairing down. Its token was rotated, or Direct Attach is off. Copy a new link from its Pairing sheet and pair again."))
            }
            throw TermiodClientError.remoteFailed(
                Self.diagnosis(name: name, error: error?.localizedDescription))
        }
    }

    /// Why a dial to a paired Mac failed, in the words that lead to the fix.
    private static func diagnosis(name: String, error: String?) -> String {
        let check = localized("Check that Termio is open there with Allow Paired Devices and Direct Attach on, and that both Macs are on the same network or tailnet.")
        guard let error else { return localized("Couldn’t reach \(name).") + " " + check }
        return localized("Couldn’t reach \(name): \(error).") + " " + check
    }

    private func startPumping() {
        // WebSocket → descriptor, on the connection's queue.
        receiveNext()
        queue.async { [self] in
            lastPong = ProcessInfo.processInfo.systemUptime
            schedulePing()
        }
        // Descriptor → WebSocket, on a thread of its own: the read blocks, and a
        // blocked read on the connection's queue would stall the other direction.
        let thread = Thread { [self] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(pumpDescriptor, &chunk, chunk.count)
                if count > 0 {
                    if !send(Data(chunk[0 ..< count])) { break }
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            finish()
        }
        thread.name = "sh.termio.termiod.websocket.out"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// Sends one binary message and waits for the stack to take it, which is
    /// what keeps a fast writer from queueing without bound behind a slow link.
    private func send(_ data: Data) -> Bool {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "termiod", metadata: [metadata])
        let sent = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { error in
            if let error {
                Log.termiod.notice("websocket send failed: \(error.localizedDescription, privacy: .public)")
                outcome.set(error)
            }
            sent.signal()
        })
        sent.wait()
        return outcome.error == nil
    }

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + Self.pingInterval) { [weak self] in
            guard let self, !self.isFinished else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastPong > Self.silenceLimit {
                Log.termiod.notice("paired Mac stopped answering pings; closing the link")
                self.finish()
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            metadata.setPongHandler(self.queue) { [weak self] error in
                guard error == nil else { return }
                self?.lastPong = ProcessInfo.processInfo.systemUptime
            }
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
            self.connection.send(content: Data(), contentContext: context, isComplete: true,
                                 completion: .contentProcessed { _ in })
            self.schedulePing()
        }
    }

    private var isFinished: Bool { lock.withLock { finished } }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                Log.termiod.notice("websocket receive ended: \(error.localizedDescription, privacy: .public)")
                self.finish()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                self.finish()
                return
            }
            // Only binary messages carry the stream. The splice's text heartbeat
            // and any ping arrive here too, and a byte of either in the frame
            // stream would tear the next frame apart.
            if metadata?.opcode == .binary, let data, !data.isEmpty, !self.writeAll(data) {
                self.finish()
                return
            }
            self.receiveNext()
        }
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard var cursor = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(pumpDescriptor, cursor, remaining)
                if written > 0 {
                    cursor += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Ends both directions once. Shutting the pump end down is what the
    /// transport's reader sees as the connection closing.
    private func finish() {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        Self.registryLock.withLock { _ = Self.openBridges[hostID]?.removeValue(forKey: ObjectIdentifier(self)) }
        connection.cancel()
        shutdown(pumpDescriptor, SHUT_RDWR)
        // Closed after the reader thread has had its EOF: closing a descriptor
        // another thread is blocked reading is undefined, shutting it down is not.
        queue.asyncAfter(deadline: .now() + 1) { [pumpDescriptor] in
            Darwin.close(pumpDescriptor)
        }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: NWError?
        var error: NWError? { lock.withLock { stored } }
        func set(_ error: NWError?) { lock.withLock { stored = error } }
    }
}

/// Cancel for the pairing sheet's dial. Shutting the socket down ends a read
/// that is waiting on the far daemon. The descriptor is held under the lock and
/// released before it is closed, so a late Cancel never reaches a descriptor
/// the system has since handed to something else.
final class PairingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let descriptor { shutdown(descriptor, SHUT_RDWR) }
        }
    }

    func watch(_ descriptor: Int32) {
        lock.withLock {
            self.descriptor = descriptor
            if cancelled { shutdown(descriptor, SHUT_RDWR) }
        }
    }

    func unwatch() {
        lock.withLock { descriptor = nil }
    }
}
