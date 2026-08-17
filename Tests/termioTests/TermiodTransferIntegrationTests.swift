import XCTest
@testable import termio

/// The transfer client against a real daemon, end to end.
///
/// Opt-in: point `TERMIO_TERMIOD_TEST_BIN` at a built `termiod` and it runs;
/// without one it skips, so `swift test` never grows a cargo dependency. It is
/// here rather than in a scratch script because the thing worth pinning is
/// *this client's* half of the contract — the ack loop, the resume offset, the
/// `U` frame on a control channel — and none of that is provable without a
/// daemon on the other end.
final class TermiodTransferIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?
    private let session = "transfer-test-\(ProcessInfo.processInfo.processIdentifier)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        binary = configured

        // Its own daemon on its own socket, started and stopped here, so the
        // test never adopts (or disturbs) the one the developer is using.
        // Short name on purpose: a Unix socket path is capped at 104 bytes and
        // the per-user temp directory already spends half of it, so a full UUID
        // here makes `bind` fail with nothing to read but a dead socket.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tdx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)

        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["TERMIOD_SOCK": socket]) { _, new in new }
        serve.standardOutput = FileHandle.nullDevice
        serve.standardError = FileHandle.nullDevice
        try serve.run()
        daemon = serve

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            usleep(50_000)
        }
        XCTAssertEqual(run([binary, "create", "--name", session, "--", "cat"]).code, 0,
                       "the daemon must come up and hold a session to paste into")
    }

    override func tearDownWithError() throws {
        if !binary.isEmpty { _ = run([binary, "kill", session]) }
        daemon?.terminate()
        daemon?.waitUntilExit()
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        unsetenv("TERMIOD_SOCK")
        try super.tearDownWithError()
    }

    /// Several chunks, so the credit-of-one loop is genuinely exercised rather
    /// than short-circuited by a payload that fits in one frame.
    func testAnImageCrossesToTheSessionsScratchDirectory() throws {
        var bytes = Data("\u{89}PNG\r\n\u{1A}\n".utf8)
        bytes.append(Data((0 ..< 200_000).map { UInt8($0 % 251) }))

        let path = try Termiod.uploadToSessionScratch(
            route: .local, session: session, name: "paste-1.png", data: bytes)

        XCTAssertTrue(path.hasPrefix("/"), "the path is the device's, and absolute")
        XCTAssertTrue(path.contains("session-"), "a temp: transfer lands in the session's scratch")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)

        // What the session owns dies with it — a pasted screenshot must not
        // outlive the conversation it belonged to.
        _ = run([binary, "kill", session])
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: path), Date() < deadline {
            usleep(100_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "killing the session reaps what was pasted into it")
    }

    /// The daemon refuses a `temp:` transfer it cannot attribute, and the
    /// client surfaces that message instead of hanging on a reply that will
    /// never come.
    func testATransferAtAnUnknownSessionFailsWithTheDaemonsReason() {
        XCTAssertThrowsError(try Termiod.uploadToSessionScratch(
            route: .local, session: "no-such-session", name: "paste-1.png",
            data: Data("x".utf8))) { error in
            XCTAssertTrue("\(error)".contains("no such session"), "got: \(error)")
        }
    }

    @discardableResult
    private func run(_ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
