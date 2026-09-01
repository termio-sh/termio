import XCTest
import TermioShared
@testable import termio

/// Two attachments on one session, against a real daemon: the PTY is the
/// smallest viewport being rendered, and the write token does not move it.
///
/// Every assertion here was false before
/// `docs/design/20260901-pty-size-is-not-the-write-token.md`. The size followed
/// the token — gaining it re-asserted the winner's grid — so two devices trading
/// the token traded the PTY with it, and one byte misread as typing was a
/// full-speed resize loop. This is the test that says it does not.
///
/// Opt-in on the same terms as the other daemon suites: set
/// `TERMIO_TERMIOD_TEST_BIN` to run it.
final class TermiodSizePolicyIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        binary = configured

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("size-\(UUID().uuidString.prefix(8))")
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "daemon never bound")
    }

    override func tearDownWithError() throws {
        daemon?.terminate()
        daemon?.waitUntilExit()
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        unsetenv("TERMIOD_SOCK")
        try super.tearDownWithError()
    }

    /// `onSharedGrid` fires on the main queue; the tests read it from there too.
    private final class GridWatcher {
        var grid: TerminalGrid?
    }

    private func link(_ name: String, rows: Int, cols: Int) -> TermiodSessionLink {
        TermiodSessionLink(
            sessionName: name,
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/cat"],
                env: [], rows: UInt16(rows), cols: UInt16(cols)),
            rows: rows, cols: cols)
    }

    private func waitForGrid(
        _ watcher: GridWatcher, _ expected: TerminalGrid, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // Generous: the first `S` after a barrier is a full repaint, and the
        // first run on a cold machine has a linker in front of it.
        let deadline = Date().addingTimeInterval(10)
        while watcher.grid != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(watcher.grid, expected, what, file: file, line: line)
    }

    /// Asserts a size *holds* through a settling window. A wait cannot express
    /// "nothing happened": it is satisfied by the state the watcher already
    /// starts in, so it returns before the event that would contradict it has
    /// had time to arrive — which is exactly the event this file is about.
    private func assertGridHolds(
        _ watcher: GridWatcher, _ expected: TerminalGrid, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            XCTAssertEqual(watcher.grid, expected, what, file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testTheSessionIsTheSmallestViewportAndTheTokenDoesNotMoveIt() throws {
        let name = "size-policy-\(UUID().uuidString.prefix(8))"
        let wide = TerminalGrid(rows: 50, cols: 200)
        let narrow = TerminalGrid(rows: 42, cols: 47)

        let mac = link(name, rows: Int(wide.rows), cols: Int(wide.cols))
        let macGrid = GridWatcher()
        mac.onSharedGrid = { macGrid.grid = $0 }
        mac.start()
        defer { mac.detach() }
        waitForGrid(macGrid, wide, "one viewer, its own grid")

        // A phone opens the same session on a much smaller screen.
        let phone = link(name, rows: Int(narrow.rows), cols: Int(narrow.cols))
        let phoneGrid = GridWatcher()
        phone.onSharedGrid = { phoneGrid.grid = $0 }
        phone.start()
        defer { phone.detach() }
        waitForGrid(phoneGrid, narrow, "the phone is smaller, so the session is")
        waitForGrid(macGrid, narrow, "and the Mac is told, so it can letterbox")

        // Typing takes the write token. It used to take the grid with it.
        mac.send(Data("echo\n".utf8))
        assertGridHolds(macGrid, narrow, "typing on the Mac must not resize the session")
        phone.send(Data("echo\n".utf8))
        assertGridHolds(phoneGrid, narrow, "nor typing on the phone")

        // Putting the session away on the phone is what gives the width back.
        phone.setRendering(false)
        waitForGrid(macGrid, wide, "a viewer that stopped rendering stops counting")

        phone.setRendering(true)
        waitForGrid(macGrid, narrow, "and counts again when it comes back")
    }

    /// The other half: a viewer that leaves altogether releases the session too,
    /// and the size it left behind survives until somebody is rendering again.
    func testDetachingHandsTheWidthBack() throws {
        let name = "size-detach-\(UUID().uuidString.prefix(8))"
        let wide = TerminalGrid(rows: 50, cols: 200)
        let narrow = TerminalGrid(rows: 42, cols: 47)

        let mac = link(name, rows: Int(wide.rows), cols: Int(wide.cols))
        let macGrid = GridWatcher()
        mac.onSharedGrid = { macGrid.grid = $0 }
        mac.start()
        defer { mac.detach() }
        waitForGrid(macGrid, wide, "one viewer, its own grid")

        let phone = link(name, rows: Int(narrow.rows), cols: Int(narrow.cols))
        phone.start()
        waitForGrid(macGrid, narrow, "the phone squeezes it")

        phone.detach()
        waitForGrid(macGrid, wide, "and hands it back on the way out")
    }
}
