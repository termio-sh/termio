import GhosttyVt
import TermioShared
import XCTest
@testable import TermioStream
@testable import termio

/// The `vt_stream` contract, across languages: the client terminal, built from
/// termiod's native snapshot and fed the same bytes and resize markers, holds
/// the screen termiod's own VT held after every step.
///
/// `Fixtures/vt-stream-resize.txt` is written by termiod's
/// `the_client_resize_fixture_matches_the_daemon`, which also fails when the
/// file no longer matches the daemon. It attaches inside an OSC sequence, and
/// its resizes cover a shell prompt being blanked before the reflow, one
/// blanked from a continuation row, a truncating resize, and the alternate
/// screen. Screens compare as VT, so styles and modes count, and pixel sizes
/// are compared too.
final class StreamTerminalTests: XCTestCase {
    func testTheClientTerminalTracksTheDaemonThroughEveryResize() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "vt-stream-resize", withExtension: "txt", subdirectory: "Fixtures"),
            "the fixture is missing from the test bundle")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var terminal: TermiodStreamTerminal?
        var screens = 0
        for (number, line) in lines.enumerated() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            switch fields[0] {
            case "attach":
                terminal = try TermiodStreamTerminal(nativeSnapshot: try Self.hex(fields[1]))
                // As a pane does (the Scrollback setting). Left at the limit
                // the snapshot carries, a terminal on 4 KB pages (Intel)
                // prunes rows termiod's own VT, on 16 KB pages, kept.
                try terminal?.setScrollbackLimit(bytes: 10_000_000)
            case "bytes":
                try XCTUnwrap(terminal).write(try Self.hex(fields[1]))
            case "resize":
                try XCTUnwrap(terminal).resize(
                    rows: try XCTUnwrap(UInt16(fields[1])),
                    cols: try XCTUnwrap(UInt16(fields[2])),
                    reflow: fields[3] == "1"
                )
            case "screen":
                let expected = TermiodStreamTerminal.Screen(
                    rows: try XCTUnwrap(UInt16(fields[1])),
                    cols: try XCTUnwrap(UInt16(fields[2])),
                    widthPixels: try XCTUnwrap(UInt32(fields[3])),
                    heightPixels: try XCTUnwrap(UInt32(fields[4])),
                    cursorX: try XCTUnwrap(UInt16(fields[5])),
                    cursorY: try XCTUnwrap(UInt16(fields[6])),
                    alternate: fields[7] == "1",
                    vt: try Self.hex(fields[8])
                )
                let actual = try XCTUnwrap(terminal).screen()
                XCTAssertEqual(
                    actual, expected,
                    """
                    diverged at fixture line \(number + 1):
                    client \(String(decoding: actual.vt, as: UTF8.self).debugDescription)
                    daemon \(String(decoding: expected.vt, as: UTF8.self).debugDescription)
                    """
                )
                screens += 1
            default:
                XCTFail("unknown fixture line \(number + 1): \(fields[0])")
            }
        }
        XCTAssertGreaterThan(screens, 10)
    }

    /// An `S` frame of format 4 carries the native snapshot whole, and only
    /// in `native`: the replay path, which would paint `vt`, gets nothing.
    func testANativeSnapshotFrameDecodesIntoAClientTerminal() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "vt-stream-resize", withExtension: "txt", subdirectory: "Fixtures"))
        let attach = try XCTUnwrap(
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("attach ") })
        let native = try Self.hex(String(attach.dropFirst("attach ".count)))
        let title = Data("stream".utf8)
        var payload = Data([TermiodSnapshot.nativeFormatVersion, 0, 6, 0, 20, 0, 0, 0, 0, 0])
        payload += [UInt8(title.count >> 8), UInt8(title.count & 0xff)]
        payload += title
        payload += withUnsafeBytes(of: UInt32(native.count).bigEndian) { Data($0) }
        payload += native

        let frame = try XCTUnwrap(TermiodSnapshot.decode(payload))
        XCTAssertEqual(frame.native, native)
        XCTAssertNil(frame.vt)
        XCTAssertEqual(frame.title, "stream")
        XCTAssertEqual(TermiodSnapshot.render(frame), Data())
        let screen = try TermiodStreamTerminal(nativeSnapshot: native).screen()
        XCTAssertEqual(screen.rows, 6)
        XCTAssertEqual(screen.cols, 20)
    }

    private struct BadHex: Error {}

    /// A program sees the terminal the embedded surface is: Ghostty's device
    /// attributes and XTVERSION, size reports, and the color scheme of the
    /// appearance the theme was picked for.
    func testThePaneAnswersQueriesAsTheEmbeddedSurfaceDoes() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "vt-stream-resize", withExtension: "txt", subdirectory: "Fixtures"))
        let attach = try XCTUnwrap(
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("attach ") })
        let snapshot = try Self.hex(String(attach.dropFirst("attach ".count)))
        func theme(background: UInt8, dark: Bool) -> TermiodStreamTerminal.Theme {
            TermiodStreamTerminal.Theme(
                foreground: GhosttyColorRgb(r: 128, g: 128, b: 128),
                background: GhosttyColorRgb(r: background, g: background, b: background),
                cursor: nil, palette: [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 0, g: 0, b: 0), count: 256),
                cursorStyle: GHOSTTY_CURSOR_STYLE_BLOCK, cursorBlink: false, dark: dark)
        }
        func answer(_ query: String, theme: TermiodStreamTerminal.Theme? = nil) throws -> String {
            var replies = ""
            let terminal = try TermiodStreamTerminal(
                nativeSnapshot: snapshot, xtversion: "ghostty \(embeddedGhosttyVersion())",
                onReply: { replies += String(decoding: $0, as: UTF8.self) })
            if let theme { try terminal.setTheme(theme) }
            // The fixture attaches inside an OSC sequence; BEL ends it.
            terminal.write(Data(("\u{7}" + query).utf8))
            return replies
        }
        XCTAssertEqual(try answer("\u{1b}[c"), "\u{1b}[?62;22;52c")
        XCTAssertEqual(try answer("\u{1b}[>c"), "\u{1b}[>1;10;0c")
        XCTAssertFalse(embeddedGhosttyVersion().isEmpty)
        XCTAssertEqual(try answer("\u{1b}[>q"), "\u{1b}P>|ghostty \(embeddedGhosttyVersion())\u{1b}\\")
        XCTAssertEqual(try answer("\u{1b}[18t"), "\u{1b}[8;6;20t")
        XCTAssertEqual(try answer("\u{1b}[16t"), "\u{1b}[6;16;8t")
        XCTAssertEqual(try answer("\u{1b}[14t"), "\u{1b}[4;96;160t")
        XCTAssertEqual(try answer("\u{1b}[?996n", theme: theme(background: 20, dark: true)), "\u{1b}[?997;1n")
        XCTAssertEqual(try answer("\u{1b}[?996n", theme: theme(background: 250, dark: false)), "\u{1b}[?997;2n")
        // A dark theme picked for the light appearance answers light, as the
        // embedded surface answers from the window's appearance.
        XCTAssertEqual(try answer("\u{1b}[?996n", theme: theme(background: 20, dark: false)), "\u{1b}[?997;2n")

        // With mode 2031 on, the program is told when the appearance changes.
        var reports = ""
        let terminal = try TermiodStreamTerminal(
            nativeSnapshot: snapshot, onReply: { reports += String(decoding: $0, as: UTF8.self) })
        terminal.write(Data("\u{7}".utf8))
        try terminal.setTheme(theme(background: 250, dark: false))
        try terminal.setTheme(theme(background: 20, dark: true))
        XCTAssertEqual(reports, "", "reported a change to a program that did not ask")
        try terminal.setTheme(theme(background: 250, dark: false))
        terminal.write(Data("\u{1b}[?2031h".utf8))
        // The first theme is no change, even to a program that asked.
        var first = ""
        let fresh = try TermiodStreamTerminal(
            nativeSnapshot: snapshot, onReply: { first += String(decoding: $0, as: UTF8.self) })
        fresh.write(Data("\u{7}\u{1b}[?2031h".utf8))
        try fresh.setTheme(theme(background: 20, dark: true))
        XCTAssertEqual(first, "", "reported the first theme as a change")
        // A reattached pane says once where it stands now.
        reports = ""
        terminal.reportColorSchemeIfSubscribed()
        XCTAssertEqual(reports, "\u{1b}[?997;2n")
        reports = ""
        try terminal.setTheme(theme(background: 20, dark: true))
        XCTAssertEqual(reports, "\u{1b}[?997;1n")
        reports = ""
        try terminal.setTheme(theme(background: 30, dark: true))
        XCTAssertEqual(reports, "", "reported a scheme that did not change")
    }

    /// A decoded snapshot carries termiod's limit of about a thousand lines;
    /// the pane keeps what the Scrollback setting allows instead.
    func testThePaneKeepsTheScrollbackSettingNotTheDaemonsLimit() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "vt-stream-resize", withExtension: "txt", subdirectory: "Fixtures"))
        let attach = try XCTUnwrap(
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("attach ") })
        let snapshot = try Self.hex(String(attach.dropFirst("attach ".count)))
        // The fixture attaches inside an OSC sequence; BEL ends it.
        let lines = Data(("\u{7}" + (0 ..< 5000).map { "line \($0)\r\n" }.joined()).utf8)

        let daemonLimit = try TermiodStreamTerminal(nativeSnapshot: snapshot)
        daemonLimit.write(lines)
        let setting = try TermiodStreamTerminal(nativeSnapshot: snapshot)
        try setting.setScrollbackLimit(bytes: 10_000_000)
        setting.write(lines)

        XCTAssertGreaterThan(try daemonLimit.scrollbackRows(), 0)
        XCTAssertLessThan(try daemonLimit.scrollbackRows(), 2000)
        XCTAssertGreaterThan(try setting.scrollbackRows(), 4900)
    }

    private static func hex(_ text: String) throws -> Data {
        var bytes = Data(capacity: text.utf8.count / 2)
        var high: UInt8?
        for character in text.utf8 {
            guard let nibble = UInt8(String(UnicodeScalar(character)), radix: 16) else { throw BadHex() }
            if let first = high {
                bytes.append(first << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard high == nil else { throw BadHex() }
        return bytes
    }
}
