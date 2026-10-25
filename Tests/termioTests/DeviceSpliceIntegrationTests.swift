import Darwin
import Foundation
import XCTest
@testable import termio

/// The splice, end to end, against a stand-in daemon: the handshake gate, and
/// bytes crossing in both directions.
///
/// The unit tests next door cover what the token comparison accepts. They say
/// nothing about the part a phone actually depends on — that the listener
/// answers 101 for a real token, refuses one it does not know, and then copies
/// a stream whose message boundaries mean nothing. That is three moving pieces
/// (a `NWListener`, a WebSocket handshake handler, two chained pumps) and none
/// of them fails at compile time.
///
/// No `termiod` is involved: the server is handed a `DaemonSocket` naming a
/// Unix socket this test serves itself, so nothing here reaches the real
/// daemon, writes a pairing token into its state directory, or starts one.
@MainActor
final class DeviceSpliceIntegrationTests: XCTestCase {
    private let token = "test-token-0123456789"
    private var directory: URL?
    private var daemon: StandInDaemon?
    private var server: DeviceSpliceServer?
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short directory name: `sun_path` is capped at 104 bytes and the
        // per-user temp directory already spends half of it.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory

        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")

        let daemon = StandInDaemon(path: socket)
        try daemon.start()
        self.daemon = daemon

        port = try Self.freePort()
        // The far end is handed over rather than derived, so nothing else in
        // this process shares it. Pointing `TERMIOD_SOCK` at the stand-in did
        // share it — app code from other suites dialled it and closed its
        // listener mid-test.
        let server = DeviceSpliceServer(
            port: port,
            daemon: DaemonSocket(path: { socket }, token: { [token] in token }, autostart: nil))
        server.start()
        self.server = server
    }

    override func tearDown() {
        server?.stop()
        server = nil
        daemon?.stop()
        daemon = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    func testPairedPhoneReachesTheDaemonThroughTheSplice() async throws {
        let task = webSocket(subprotocol: "termiod.\(token)")
        task.resume()

        // Whatever the phone sends is the daemon's to read, byte for byte.
        let frame = Data([0x43, 0, 0, 0, 2, 0x68, 0x69])
        let arrived = expectation(description: "the stand-in daemon read the phone's bytes")
        daemon?.onBytes = { bytes in
            if bytes == frame { arrived.fulfill() }
        }
        try await task.send(.data(frame))
        await fulfillment(of: [arrived], timeout: 5)

        // And what the daemon says comes back the same way. Sent as two writes
        // to make the point the framing rests on: the phone's `FrameReader`
        // cuts frames out of a stream, so nothing in between has to preserve
        // where one write ended.
        let answered = expectation(description: "the phone read the daemon's bytes")
        Task.detached {
            var received = Data()
            while received != Data("hello_ok".utf8) {
                guard case .data(let data) = try await task.receive() else { continue }
                received.append(data)
            }
            answered.fulfill()
        }
        daemon?.send(Data("hello".utf8))
        daemon?.send(Data("_ok".utf8))
        await fulfillment(of: [answered], timeout: 5)
        task.cancel(with: .goingAway, reason: nil)
    }

    func testUnpairedPhoneNeverReachesTheSocket() async throws {
        let task = webSocket(subprotocol: "termiod.not-the-token")
        task.resume()

        do {
            _ = try await task.receive()
            XCTFail("a connection with the wrong token was served")
        } catch {
            // The handshake was refused, which is the whole assertion.
        }
        XCTAssertEqual(daemon?.connectionCount, 0, "the daemon must never be dialled for it")
    }

    // MARK: - Another Mac, through the bridge

    func testPairedMacReachesTheDaemonThroughTheBridge() async throws {
        let device = PairedDevice(
            hostID: "h_test", name: "mini", url: "http://127.0.0.1:\(port)", token: token)
        let bridge = try await Task.detached { try WebSocketBridge.open(device, requiresPairing: false) }.value
        defer { close(bridge.descriptor) }

        // The client writes frames to a descriptor, as on every other route, and
        // the daemon reads them byte for byte.
        let frame = Data([0x43, 0, 0, 0, 2, 0x68, 0x69])
        let arrived = expectation(description: "the stand-in daemon read the Mac's bytes")
        daemon?.onBytes = { bytes in
            if bytes == frame { arrived.fulfill() }
        }
        let written = frame.withUnsafeBytes { write(bridge.descriptor, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, frame.count)
        await fulfillment(of: [arrived], timeout: 5)

        // What the daemon writes in two pieces reads back as one stream.
        daemon?.send(Data("hello".utf8))
        daemon?.send(Data("_ok".utf8))
        let descriptor = bridge.descriptor
        let received = await Task.detached { () -> Data in
            var received = Data()
            var chunk = [UInt8](repeating: 0, count: 64)
            while received.count < 8 {
                let count = read(descriptor, &chunk, chunk.count)
                guard count > 0 else { break }
                received.append(contentsOf: chunk[0 ..< count])
            }
            return received
        }.value
        XCTAssertEqual(received, Data("hello_ok".utf8))
    }

    func testPairedMacWithAStaleTokenIsRefusedBeforeTheDaemon() async throws {
        let device = PairedDevice(
            hostID: "h_test", name: "mini", url: "http://127.0.0.1:\(port)", token: "revoked")
        do {
            let bridge = try await Task.detached { try WebSocketBridge.open(device, requiresPairing: false) }.value
            close(bridge.descriptor)
            XCTFail("a bridge with the wrong token was opened")
        } catch {
            // Refused at the handshake, which is the assertion.
        }
        XCTAssertEqual(daemon?.connectionCount, 0, "the daemon must never be dialled for it")
    }

    // MARK: - Helpers

    private func webSocket(subprotocol: String) -> URLSessionWebSocketTask {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/ws") else {
            fatalError("the test's own URL must parse")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        return URLSession(configuration: configuration)
            .webSocketTask(with: url, protocols: [subprotocol])
    }

    /// A port the kernel just handed out and nothing is holding. Racy in
    /// principle; in a test process that binds it microseconds later, it is the
    /// least flaky option available without exposing the listener's own port.
    private static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        address.sin_port = 0
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(descriptor, rebound, length)
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var assigned = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(descriptor, rebound, &size)
            }
        }
        guard read == 0 else { throw POSIXError(.EADDRINUSE) }
        return UInt16(bigEndian: assigned.sin_port)
    }
}

/// A Unix socket that accepts one client and lets the test read and write it —
/// everything the splice needs on the far side, and nothing a daemon does.
private final class StandInDaemon: @unchecked Sendable {
    /// Fires on the accept thread with every chunk read.
    var onBytes: ((Data) -> Void)?

    private let path: String
    private let lock = NSLock()
    private var listening: Int32 = -1
    private var accepted: Int32 = -1
    private var accepts = 0
    private var stopped = false

    init(path: String) {
        self.path = path
    }

    /// How many clients have reached it. The refusal test asserts this stays
    /// zero: a listener that dialled the daemon and *then* refused would pass a
    /// check that only watched the WebSocket.
    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepts
    }

    func start() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) - 1 else {
            close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(descriptor, rebound, length)
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        lock.lock()
        listening = descriptor
        lock.unlock()

        Thread { [weak self] in self?.acceptLoop(descriptor) }.start()
    }

    func send(_ data: Data) {
        lock.lock()
        let descriptor = accepted
        lock.unlock()
        guard descriptor >= 0 else { return }
        _ = data.withUnsafeBytes { raw in
            raw.baseAddress.map { write(descriptor, $0, raw.count) }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let (listening, accepted) = (self.listening, self.accepted)
        self.listening = -1
        self.accepted = -1
        lock.unlock()
        if accepted >= 0 { shutdown(accepted, SHUT_RDWR); close(accepted) }
        if listening >= 0 { close(listening) }
        unlink(path)
    }

    private func acceptLoop(_ listening: Int32) {
        while true {
            let client = accept(listening, nil, nil)
            guard client >= 0 else { return }
            // Writing to a peer that has gone away must fail this write, not
            // kill the test process.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            let stopped = self.stopped
            if !stopped {
                accepted = client
                accepts += 1
            }
            lock.unlock()
            guard !stopped else {
                close(client)
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                onBytes?(Data(buffer[0 ..< count]))
            }
            // One client ending is not the socket ending: a real daemon keeps
            // listening, and so does this.
            lock.lock()
            if accepted == client { accepted = -1 }
            lock.unlock()
            close(client)
        }
    }
}
