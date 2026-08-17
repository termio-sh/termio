import Darwin
import XCTest
@testable import termio

/// Guards the control socket's partial-I/O handling. `sessions list --json` in a
/// project with ~45 sessions is larger than a Unix stream socket's 8 KiB send
/// buffer, and the accepted descriptors are non-blocking, so the reply is written
/// across several `write` calls with `EAGAIN` in between. A `writeAll` that read
/// `EAGAIN` as failure truncated the reply at exactly 8192 bytes, mid-token —
/// invalid JSON, delivered with a success exit code.
///
/// The listener itself cannot be tested here: `start()` binds this channel's real
/// control socket, which under the test runner (no bundle identifier) is the
/// *release* channel's — the running app's. So these tests drive the primitives
/// over a `socketpair` with the same non-blocking, small-buffer setup the accepted
/// connections have.
final class SessionControlSocketIOTests: XCTestCase {
    private var pair: [Int32] = [-1, -1]

    override func tearDown() {
        for descriptor in pair where descriptor >= 0 { close(descriptor) }
        pair = [-1, -1]
        super.tearDown()
    }

    /// A non-blocking pair whose sender holds far less than the payload under test,
    /// mirroring an accepted control connection.
    private func makePair(sendBuffer: Int32 = 8192) throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try XCTSkipUnless(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0,
                          "socketpair unavailable")
        pair = descriptors
        var size = sendBuffer
        setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var on: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(pair[0], F_SETFL, fcntl(pair[0], F_GETFL, 0) | O_NONBLOCK)
    }

    func testWriteAllDeliversAPayloadLargerThanTheSendBuffer() throws {
        try makePair()
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        let reader = pair[1]
        let received = expectation(description: "reader drained the payload")
        var drained = Data()
        // A deliberately slow reader, so the writer meets EAGAIN many times over.
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while drained.count < payload.count {
                let count = read(reader, &buffer, buffer.count)
                if count > 0 {
                    drained.append(contentsOf: buffer[0..<count])
                    usleep(2000)
                } else if count == 0 || errno != EINTR {
                    break
                }
            }
            received.fulfill()
        }

        XCTAssertTrue(SocketIO.writeAll(pair[0], payload, timeout: 10),
                      "a full send buffer is a retry, not a failed write")
        wait(for: [received], timeout: 10)
        XCTAssertEqual(drained.count, payload.count,
                       "the reply must arrive whole, not clipped at the send buffer")
        XCTAssertEqual(drained, payload)
    }

    /// The other half of the contract: retrying on EAGAIN must not turn a genuinely
    /// dead peer into a spin. A closed reader still ends the write, promptly.
    func testWriteAllReportsAReaderThatWentAway() throws {
        try makePair()
        close(pair[1])
        pair[1] = -1
        let started = Date()
        XCTAssertFalse(SocketIO.writeAll(pair[0], Data(repeating: 0x7a, count: 256 * 1024),
                                         timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "a hung-up peer must end the write immediately, not burn the timeout")
    }

    /// The read side's building block: `accept` returns before the client's request
    /// lands, so an empty socket means "not yet", and only the deadline means "no".
    func testWaitReadableTellsAnEmptySocketFromAnArrivedRequest() throws {
        try makePair()
        let started = Date()
        XCTAssertFalse(SocketIO.waitReadable(pair[0], until: Date().addingTimeInterval(0.2)),
                       "nothing arrived, so the deadline is what ends the wait")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15,
                                    "the wait must actually wait, not read EAGAIN and give up")

        let request = Data(#"{"op":"list"}"#.utf8)
        request.withUnsafeBytes { _ = write(pair[1], $0.baseAddress, $0.count) }
        XCTAssertTrue(SocketIO.waitReadable(pair[0], until: Date().addingTimeInterval(2)))
    }
}
