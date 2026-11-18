import XCTest
import TermioShared
@testable import termio

/// A link on the `vt_stream` plane against a real daemon: the native snapshot
/// becomes the client terminal, bytes reach it, and a viewport change comes
/// back as a `vt_resize` that resizes it — no keyframe, no surface.
///
/// Opt-in on the same terms as the other daemon suites: set
/// `TERMIO_TERMIOD_TEST_BIN` to a termiod built with `vt_stream`.
final class StreamLinkIntegrationTests: XCTestCase {
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let binary = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(binary.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stream-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)
        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["TERMIOD_SOCK": socket, "TERMIOD_KEEP_AWAKE": "off"]) { _, new in new }
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

    private func wait(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                      until condition: () throws -> Bool) rethrows {
        let deadline = Date().addingTimeInterval(10)
        while try !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(try condition(), what, file: file, line: line)
    }

    private func text(_ link: TermiodSessionLink) throws -> String {
        guard let screen = try link.streamTerminal?.screen() else { return "" }
        return String(decoding: screen.vt, as: UTF8.self)
    }

    func testAStreamLinkFollowsTheSessionThroughAResize() throws {
        let link = TermiodSessionLink(
            sessionName: "stream-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/sh", "-c", "printf 'hello stream\\n'; exec /bin/cat"],
                env: [], rows: 20, cols: 60),
            rows: 20, cols: 60, offersStream: true)
        var streaming: [Bool] = []
        link.onStreaming = { streaming.append($0) }
        link.start()
        defer { link.detach() }

        wait("the link negotiated vt_stream") { link.isStreaming && link.streamTerminal != nil }
        XCTAssertEqual(streaming, [true])
        try wait("the shell's output reached the client terminal") {
            try text(link).contains("hello stream")
        }
        let first = try XCTUnwrap(link.streamTerminal)

        link.setViewport(rows: 12, cols: 50)
        try wait("the vt_resize marker resized the client terminal") {
            let screen = try link.streamTerminal?.screen()
            return screen?.rows == 12 && screen?.cols == 50
        }
        XCTAssertTrue(link.streamTerminal === first, "a resize keeps the terminal; only an attach replaces it")

        link.send(Data("typed after\n".utf8))
        try wait("input echoed back through the stream") { try text(link).contains("typed after") }
    }

    /// A dropped connection comes back where it left off (`vt_resume`): the
    /// output written while it was gone arrives from termiod's ring, into the
    /// same terminal, with no snapshot to replace it.
    func testAReattachResumesTheStreamInTheSameTerminal() throws {
        // The program prints `two` only once the gate exists, which the test
        // makes right after the drop: the reconnect waits at least 0.4 s, so
        // `two` is written while the link is away and has to come from the ring.
        let gate = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gate-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: gate) }
        let link = TermiodSessionLink(
            sessionName: "resume-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/sh", "-c", "printf 'one\\n'; while [ ! -e '\(gate)' ]; do sleep 0.02; done; printf 'two\\n'; exec /bin/cat"],
                env: [], rows: 20, cols: 60),
            rows: 20, cols: 60, offersStream: true)
        var reattached = false
        link.onReattached = { reattached = true }
        link.start()
        defer { link.detach() }

        try wait("the first output reached the client terminal") {
            try link.isStreaming && text(link).contains("one")
        }
        let first = try XCTUnwrap(link.streamTerminal)
        link.dropConnection()
        FileManager.default.createFile(atPath: gate, contents: nil)
        XCTAssertFalse(reattached, "the reconnect came before the gap it was meant to cover")
        wait("the link reattached") { reattached }
        try wait("what was written while it was gone arrived") { try text(link).contains("two") }
        XCTAssertTrue(link.streamTerminal === first, "the reattach decoded a snapshot instead of resuming")

        link.send(Data("after resume\n".utf8))
        try wait("the resumed stream carries live output") { try text(link).contains("after resume") }
    }

    /// A key reaches the program in the form its modes ask for: the program
    /// turned on application cursor keys after the attach, termiod encoded the
    /// key event against its own VT, and `cat -v` shows the bytes that arrived.
    func testAKeyIsEncodedWithTheModesTheProgramSetAfterTheAttach() throws {
        let link = TermiodSessionLink(
            sessionName: "keys-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/sh", "-c", "stty -echo; printf 'ready\\033[?1h\\n'; exec /bin/cat -v"],
                env: [], rows: 20, cols: 60),
            rows: 20, cols: 60, offersStream: true)
        link.start()
        defer { link.detach() }
        try wait("the program set its modes") { try text(link).contains("ready") }
        let press = try XCTUnwrap(SessionKeyPress.parse("up"))
        for input in TermiodStreamKeyboard.inputs(for: press) + TermiodStreamKeyboard.inputs(for: .return) {
            link.sendInput(.key(input))
        }
        try wait("cat -v echoed the application-mode arrow") { try text(link).contains("^[OA") }
    }

    /// A start the daemon refuses never takes the pane to the stream view:
    /// the refusal is shown where the embedded surface shows it.
    func testARefusedStartNeverStreams() throws {
        let link = TermiodSessionLink(
            sessionName: "refused-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: "/nonexistent-\(UUID().uuidString)", argv: ["/bin/cat"], env: [], rows: 20, cols: 60),
            rows: 20, cols: 60, offersStream: true)
        var refusal: String?
        var streaming: [Bool] = []
        link.onStartRefused = { refusal = $0 }
        link.onStreaming = { streaming.append($0) }
        link.start()
        defer { link.detach() }
        wait("the daemon refused the missing directory") { refusal != nil }
        XCTAssertEqual(streaming, [], "the stream view was never selected")
        XCTAssertFalse(link.isStreaming)
    }

    /// With `vt_answers`, termiod answers the program and the pane stays
    /// silent, so each query is answered once, with the name the pane gave.
    func testTheHostAnswersOnceForAStreamPaneThatWrites() throws {
        XCTAssertEqual(try answers(offersAnswers: true), "\u{1b}P>|ghostty test-name\u{1b}\\\u{1b}[?62;22;52c")
    }

    /// A link that does not offer it, as the phone's bridge does not, answers
    /// for itself, and termiod stays silent: still one answer each.
    func testALinkWithoutAnswersAnswersForItselfOnce() throws {
        XCTAssertEqual(
            try answers(offersAnswers: false),
            "\u{1b}P>|ghostty \(embeddedGhosttyVersion())\u{1b}\\\u{1b}[?62;22;52c")
    }

    /// Every query class either side answers, answered once while termiod
    /// answers: the ones it makes, and the ones it leaves to the pane.
    func testEachQueryIsAnsweredOnceWhileTheHostAnswers() throws {
        let cases: [(query: String, reply: String)] = [
            ("\\033P+q636F6C6F7273\\033\\\\", "+r636F6C6F7273"),
            ("\\033]21;foreground=?\\033\\\\", "]21;foreground="),
            ("\\033[?6n", "R"),
            ("\\033P$qm\\033\\\\", "$r"),
            ("\\033[18t", "[8;"),
        ]
        for (query, reply) in cases {
            let read = try answers(offersAnswers: true, query: query)
            XCTAssertEqual(read.components(separatedBy: reply).count - 1, 1, "\(query): \(read.debugDescription)")
        }
        // The kitty clipboard is the pane's to answer; termiod's VT can only refuse.
        let clipboard = try answers(offersAnswers: true, query: "\\033]5522;type=read:status=DATA\\033\\\\")
        XCTAssertFalse(clipboard.contains("EPERM"), clipboard.debugDescription)
    }

    /// termiod answers the program status query on its read path, so its VT's or a
    /// pane's own answer would be a second one: Grok typed it into its prompt (#831).
    func testTheProgramStatusQueryIsAnsweredOnceWhoeverElseAnswers() throws {
        for offersAnswers in [true, false] {
            let read = try answers(offersAnswers: offersAnswers, query: "\\033]7501;?\\033\\\\")
            XCTAssertEqual(read.components(separatedBy: "]7501;?").count - 1, 1, read.debugDescription)
            XCTAssertTrue(read.contains("]7501;?:states="), read.debugDescription)
        }
    }

    /// What a program that asks `query` and then DA1 after its first key
    /// reads, collected until two quiet seconds pass.
    private func answers(offersAnswers: Bool, query: String = "\\033[>q") throws -> String {
        let file = NSTemporaryDirectory() + "answers-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: file) }
        let script = "stty raw -echo; dd bs=1 count=1 of=/dev/null 2>/dev/null; "
            + "printf '\(query)\\033[c'; stty min 0 time 20; cat > \(file); exec cat"
        let link = TermiodSessionLink(
            sessionName: "answers-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", script], env: [], rows: 20, cols: 60),
            rows: 20, cols: 60, offersStream: true, offersAnswers: offersAnswers)
        link.setHostAnswers(Termiod.HostAnswers(
            xtversion: "ghostty test-name", foreground: "dddddd", background: "111111", cursor: nil,
            palette: [], dark: true))
        link.start()
        defer { link.detach() }

        wait("the link negotiated vt_stream") { link.isStreaming && link.streamTerminal != nil }
        link.send(Data("x".utf8))
        wait("the program collected its answers") {
            ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").contains("c")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        return try String(contentsOfFile: file, encoding: .utf8)
    }

    /// Without the capability the link stays on keyframes and has no terminal.
    func testALinkThatDoesNotOfferTheStreamStaysOnKeyframes() throws {
        let link = TermiodSessionLink(
            sessionName: "keyframe-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: ["/bin/cat"], env: [], rows: 20, cols: 60),
            rows: 20, cols: 60)
        // Delivered on the reader thread.
        let lock = NSLock()
        var received = false
        link.onOutput = { _ in lock.withLock { received = true } }
        link.start()
        defer { link.detach() }
        wait("the keyframe plane delivered the attach repaint") { lock.withLock { received } }
        XCTAssertFalse(link.isStreaming)
        XCTAssertNil(link.streamTerminal)
    }
}
