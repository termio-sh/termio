import XCTest
import TermioShared
@testable import termio

/// Two attachments on one session, against a real daemon: the PTY is the
/// viewport of the screen a person is in front of, and nothing else moves it.
///
/// Both halves have been wrong, in opposite directions
/// (`docs/design/20260901-pty-size-is-not-the-write-token.md`). The size first
/// followed the write token, which gaining it re-asserted, so one byte misread
/// as typing was a full-speed resize loop. Then it followed the smallest viewer,
/// and a phone that had opened a session once held a 200-column pane at 47 for
/// as long as it stayed open — collapsing the pane's sidebar moved nothing at
/// all, which is the report this file ends with.
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
    ///
    /// Every grid, not just the last one: a wrong resize that something else
    /// corrects a round trip later leaves no trace in the current value, and a
    /// resize the user did not ask for is the whole subject of this file.
    private final class GridWatcher {
        var grid: TerminalGrid?
        private(set) var seen: [TerminalGrid] = []

        func note(_ grid: TerminalGrid) {
            self.grid = grid
            seen.append(grid)
        }
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

    func testTheSessionIsTheScreenBeingUsed() throws {
        let name = "size-policy-\(UUID().uuidString.prefix(8))"
        let wide = TerminalGrid(rows: 50, cols: 200)
        let narrow = TerminalGrid(rows: 42, cols: 47)
        let widened = TerminalGrid(rows: 50, cols: 240)

        let mac = link(name, rows: Int(wide.rows), cols: Int(wide.cols))
        let macGrid = GridWatcher()
        mac.onSharedGrid = { macGrid.note($0) }
        mac.start()
        defer { mac.detach() }
        waitForGrid(macGrid, wide, "one viewer, its own grid")

        // A phone opens the same session on a much smaller screen. Opening it
        // there is using it, so the session goes to the phone and the Mac
        // letterboxes.
        let phone = link(name, rows: Int(narrow.rows), cols: Int(narrow.cols))
        let phoneGrid = GridWatcher()
        phone.onSharedGrid = { phoneGrid.note($0) }
        phone.start()
        defer { phone.detach() }
        waitForGrid(phoneGrid, narrow, "the phone was just opened, so the session is its size")
        waitForGrid(macGrid, narrow, "and the Mac is told, so it can letterbox")

        // Typing is the plainest statement of which screen someone is at.
        mac.send(Data("echo\n".utf8))
        waitForGrid(macGrid, wide, "typing on the Mac brings the session back to it")
        assertGridHolds(
            phoneGrid, wide, "a phone that is merely attached must not pull it back")

        phone.send(Data("echo\n".utf8))
        waitForGrid(phoneGrid, narrow, "and typing on the phone hands it over again")

        // The report that produced this policy: with a second viewer attached,
        // collapsing the pane's sidebar has to resize the session. Under
        // smallest-wins the Mac's new width lost to the phone's every time.
        mac.setViewport(rows: Int(widened.rows), cols: Int(widened.cols))
        waitForGrid(macGrid, widened, "resizing a pane is using it")

        // Putting the session away on the phone leaves the Mac the only screen
        // anyone is in front of.
        phone.send(Data("echo\n".utf8))
        waitForGrid(macGrid, narrow, "the phone takes it back")
        phone.setRendering(false)
        waitForGrid(macGrid, widened, "a viewer that stopped rendering stops counting")

        phone.setRendering(true)
        waitForGrid(macGrid, narrow, "and opening it again is using the phone")
    }

    /// What a resize's keyframe does to the screen, end to end against the real
    /// barrier.
    ///
    /// The daemon opens its snapshot barrier before it emits `E resized`, and
    /// defers events behind an open barrier, so `S` reaches a client *ahead* of
    /// the message that tells it what size to become. The client used to paint
    /// it there — onto a surface still laid out at the old grid — and then ask
    /// for a second keyframe once the surface caught up: two visible paints per
    /// resize, and a drag crosses several cell boundaries. Both halves are
    /// asserted here, because neither is visible in a screenshot.
    func testAResizeKeyframeWaitsForTheSurfaceAndPaintsOnce() throws {
        let name = "size-keyframe-\(UUID().uuidString.prefix(8))"
        let before = TerminalGrid(rows: 24, cols: 80)
        let after = TerminalGrid(rows: 24, cols: 100)

        let mac = link(name, rows: Int(before.rows), cols: Int(before.cols))
        let keyframes = KeyframeCounter()
        mac.onOutput = { keyframes.count($0) }
        let macGrid = GridWatcher()
        mac.onSharedGrid = { macGrid.note($0) }
        mac.start()
        defer { mac.detach() }
        waitForGrid(macGrid, before, "one viewer, its own grid")
        mac.noteSurfaceGrid(rows: Int(before.rows), cols: Int(before.cols))
        // The attach bootstrap's own keyframe is not what this test is about.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        keyframes.reset()

        mac.setViewport(rows: Int(after.rows), cols: Int(after.cols))
        waitForGrid(macGrid, after, "the daemon answers the declaration")
        // `E resized` is delivered behind the barrier's `S`, so the keyframe is
        // already on this client — and must not have been painted, because the
        // surface is still laid out at the old grid.
        XCTAssertEqual(
            keyframes.painted, 0,
            "the barrier's keyframe painted before the surface reached its grid")

        mac.noteSurfaceGrid(rows: Int(after.rows), cols: Int(after.cols))
        let deadline = Date().addingTimeInterval(5)
        while keyframes.painted == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(keyframes.painted, 1, "the surface arrived, so the keyframe paints")

        // The resync the old ordering needed would land here, as a second full
        // repaint a round trip after the first.
        let settle = Date().addingTimeInterval(1.5)
        while Date() < settle {
            XCTAssertEqual(keyframes.painted, 1, "a resize must cost exactly one repaint")
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Counts full repaints in the delivered byte stream. Every keyframe opens
    /// with erase-and-home, whether the host formatted it or this client
    /// synthesised it from packed cells (`SNAPSHOT_PROLOGUE` in `vt/src/lib.rs`,
    /// `TermiodSnapshot.render`), and nothing a program echoes carries it.
    private final class KeyframeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = 0

        var painted: Int {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func reset() {
            lock.lock()
            seen = 0
            lock.unlock()
        }

        func count(_ data: Data) {
            let prologue = Data("\u{1b}[2J".utf8)
            var found = 0
            var searchRange = data.startIndex..<data.endIndex
            while let hit = data.range(of: prologue, in: searchRange) {
                found += 1
                searchRange = hit.upperBound..<data.endIndex
            }
            guard found > 0 else { return }
            lock.lock()
            seen += found
            lock.unlock()
        }
    }

    /// A surface made for a pane that is not on screen must not take the size.
    ///
    /// The Mac makes one whenever something other than a pane asks for a
    /// session — a phone opening one this Mac never showed, `termio sessions
    /// send` addressing a background session. That attachment arrived declaring
    /// the *window's* grid and the daemon counted every arrival as rendering, so
    /// it was instantly the newest-used candidate: the PTY moved to a width no
    /// screen was showing, and the phone's first `resize` pulled it straight
    /// back. One wrong resize per open, which is what tears an agent TUI's
    /// composer box.
    func testAnAttachmentThatIsNotRenderingNeverTakesTheSize() throws {
        let name = "size-offscreen-\(UUID().uuidString.prefix(8))"
        let shown = TerminalGrid(rows: 42, cols: 47)
        let window = TerminalGrid(rows: 50, cols: 200)

        let phone = link(name, rows: Int(shown.rows), cols: Int(shown.cols))
        let phoneGrid = GridWatcher()
        phone.onSharedGrid = { phoneGrid.note($0) }
        phone.start()
        defer { phone.detach() }
        waitForGrid(phoneGrid, shown, "one viewer, its own grid")

        // The forced surface: a pane that exists without a screen in front of
        // it, and says so on the attach rather than a round trip later.
        let offscreen = link(name, rows: Int(window.rows), cols: Int(window.cols))
        offscreen.setRendering(false)
        let offscreenGrid = GridWatcher()
        offscreen.onSharedGrid = { offscreenGrid.note($0) }
        offscreen.start()
        defer { offscreen.detach() }
        waitForGrid(
            offscreenGrid, shown,
            "the attach is answered with the size the session already had")
        assertGridHolds(
            phoneGrid, shown, "a pane nobody is looking at must not resize the session")
        // Where it settles is not the assertion — a wrong resize that something
        // corrects a round trip later settles back here too. The session must
        // never have been at the window's grid at all.
        XCTAssertFalse(
            phoneGrid.seen.contains(window),
            "the attach moved the session to a grid no screen was showing")

        // And it is not muted for good: putting that pane on screen is using it.
        offscreen.setRendering(true)
        waitForGrid(phoneGrid, window, "showing the pane hands the session to it")
    }

    /// The other half: a viewer that leaves altogether releases the session too,
    /// and the size it left behind survives until somebody is rendering again.
    /// A departure is the one size change nobody asked for, so it is the one
    /// that has to fall back rather than hold.
    func testDetachingHandsTheWidthBack() throws {
        let name = "size-detach-\(UUID().uuidString.prefix(8))"
        let wide = TerminalGrid(rows: 50, cols: 200)
        let narrow = TerminalGrid(rows: 42, cols: 47)

        let mac = link(name, rows: Int(wide.rows), cols: Int(wide.cols))
        let macGrid = GridWatcher()
        mac.onSharedGrid = { macGrid.note($0) }
        mac.start()
        defer { mac.detach() }
        waitForGrid(macGrid, wide, "one viewer, its own grid")

        let phone = link(name, rows: Int(narrow.rows), cols: Int(narrow.cols))
        phone.start()
        waitForGrid(macGrid, narrow, "opening it on the phone takes the session there")

        phone.detach()
        waitForGrid(macGrid, wide, "and hands it back on the way out")
    }
}
