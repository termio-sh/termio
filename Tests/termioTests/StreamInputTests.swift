import AppKit
import Carbon.HIToolbox
import GhosttyVt
import TermioShared
import XCTest
@testable import TermioStream
@testable import termio

/// Input on the `vt_stream` plane: the client turns keystrokes into events
/// that termiod encodes against its own VT (termiod's `input` tests cover the
/// bytes), draws the input method's text, and keeps Ghostty's editing keys.
@MainActor
final class StreamInputTests: XCTestCase {
    private func terminal(_ setup: String = "") throws -> TermiodStreamTerminal {
        var raw: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &raw, 40, 10), GHOSTTY_SUCCESS)
        let source = try XCTUnwrap(raw)
        defer { ghostty_terminal_free(source) }
        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertEqual(ghostty_snapshot_encode_alloc(source, nil, &encoded, &length), GHOSTTY_SUCCESS)
        let pointer = try XCTUnwrap(encoded)
        defer { ghostty_free(nil, pointer, length) }
        let terminal = try TermiodStreamTerminal(nativeSnapshot: Data(bytes: pointer, count: length))
        terminal.write(Data(setup.utf8))
        return terminal
    }

    private func string(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private func event(_ keycode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags = [],
                       ignoring: String? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
            isARepeat: false, keyCode: UInt16(keycode)
        ))
    }

    func testAKeystrokeBecomesThePhysicalKeyAndTheTextItTyped() throws {
        let a = try event(kVK_ANSI_A, "a")
        XCTAssertEqual(TermiodStreamKeyboard.key(forKeycode: a.keyCode), "a")
        XCTAssertEqual(TermiodStreamKeyboard.typedText(of: a), "a")
        // Control turns c into ETX; the encoder wants the c.
        let controlC = try event(kVK_ANSI_C, "\u{03}", .control, ignoring: "c")
        XCTAssertEqual(TermiodStreamKeyboard.typedText(of: controlC), "c")
        // AppKit spells the arrows as private-use characters, which are no text.
        let up = try event(kVK_UpArrow, "\u{F700}")
        XCTAssertNil(TermiodStreamKeyboard.typedText(of: up))
        XCTAssertEqual(TermiodStreamKeyboard.key(forKeycode: up.keyCode), "arrow_up")
        let input = TermiodStreamKeyboard.input(for: controlC, action: .press, text: "c")
        XCTAssertEqual(input.mods & TermiodStreamKeyboard.control, TermiodStreamKeyboard.control)
        XCTAssertEqual(input.consumedMods & TermiodStreamKeyboard.control, 0, "Control stays the key's own")
        XCTAssertEqual(input.unshifted, 0x63)
    }

    /// Ghostty's editing defaults send legacy bytes even under Kitty's
    /// protocol, as the embedded surface does.
    func testTheEditingKeysSendWhatGhosttyBindsThemTo() throws {
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_LeftArrow, "\u{F702}", .command)),
                       Data([0x01]))
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_RightArrow, "\u{F703}", .command)),
                       Data([0x05]))
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_Delete, "\u{7f}", .command)),
                       Data([0x15]))
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_LeftArrow, "\u{F702}", .option)),
                       Data("\u{1b}b".utf8))
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_RightArrow, "\u{F703}", .option)),
                       Data("\u{1b}f".utf8))
        XCTAssertNil(TermiodStreamKeyboard.naturalEditing(try event(kVK_LeftArrow, "\u{F702}")))
        XCTAssertNil(TermiodStreamKeyboard.naturalEditing(try event(kVK_LeftArrow, "\u{F702}", [.command, .shift])))
    }

    /// `sessions send --key up` on a stream pane is a press and a release of
    /// the named key; termiod picks the bytes.
    func testANamedKeyFromTheCommandLineIsAPressAndARelease() throws {
        let press = try XCTUnwrap(SessionKeyPress.parse("ctrl-c"))
        let events = TermiodStreamKeyboard.inputs(for: press)
        XCTAssertEqual(events.map(\.key), ["c", "c"])
        XCTAssertEqual(events.map(\.action), [.press, .release])
        XCTAssertEqual(events[0].mods, TermiodStreamKeyboard.control)
        XCTAssertEqual(events[0].unshifted, 0x63)
    }

    /// The wire shape termiod's `Event::Answers` decodes.
    func testHostAnswersCarryTheFieldsTermiodReads() throws {
        let answers = Termiod.HostAnswers(
            xtversion: "ghostty 1.3.1", foreground: "dddddd", background: "112233", cursor: nil,
            palette: Array(repeating: "000000", count: 256), dark: true)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try answers.payload()) as? [String: Any])
        XCTAssertEqual(json["ev"] as? String, "answers")
        XCTAssertEqual(json["xtversion"] as? String, "ghostty 1.3.1")
        XCTAssertEqual(json["foreground"] as? String, "dddddd")
        XCTAssertEqual(json["background"] as? String, "112233")
        XCTAssertNil(json["cursor"] as? String)
        XCTAssertEqual((json["palette"] as? [String])?.count, 256)
        XCTAssertEqual(json["dark"] as? Bool, true)
    }

    /// The wire shape termiod's `Event::Key`, `Mouse` and `Focus` decode.
    func testInputEventsCarryTheFieldsTermiodReads() throws {
        func json(_ event: Termiod.InputEvent) throws -> [String: Any] {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: try event.payload()) as? [String: Any])
        }
        let key = try json(.key(.init(action: .repeat, key: "arrow_up", mods: 2, text: nil)))
        XCTAssertEqual(key["ev"] as? String, "key")
        XCTAssertEqual(key["action"] as? String, "repeat")
        XCTAssertEqual(key["key"] as? String, "arrow_up")
        XCTAssertEqual(key["consumed_mods"] as? Int, 0)
        let mouse = try json(.mouse(.init(action: .press, button: 1, mods: 0,
                                          at: .init(x: 5, y: 10, cellWidth: 16, cellHeight: 32), buttonsHeld: true)))
        XCTAssertEqual(mouse["ev"] as? String, "mouse")
        XCTAssertEqual(mouse["cell_width"] as? Int, 16)
        XCTAssertEqual(mouse["buttons_held"] as? Bool, true)
        XCTAssertEqual(try json(.focus(false))["focused"] as? Bool, false)
        XCTAssertEqual(try json(.paste("hi"))["text"] as? String, "hi")
    }

    /// A paste past one frame's room goes as pieces, each but the last marked
    /// `more`, split between characters, never inside one.
    func testALargePasteGoesInPiecesTermiodJoins() throws {
        let text = String(repeating: "中", count: Termiod.InputEvent.pastePieceBytes / 3 + 10)
        let pieces = Termiod.InputEvent.pastePieces(text)
        XCTAssertEqual(pieces.count, 2)
        var joined = ""
        for (index, piece) in pieces.enumerated() {
            guard case .paste(let part, let more) = piece else { return XCTFail("not a paste") }
            XCTAssertLessThanOrEqual(part.utf8.count, Termiod.InputEvent.pastePieceBytes)
            XCTAssertEqual(more, index == 0)
            joined += part
        }
        XCTAssertEqual(joined, text)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: try pieces[0].payload()) as? [String: Any])
        XCTAssertEqual(first["more"] as? Bool, true)
        XCTAssertEqual(Termiod.InputEvent.pastePieces("short"), [.paste("short")])

        // One character larger than a piece: `a` and half a million combining
        // accents. It is still split, so every piece fits.
        let huge = "a" + String(repeating: "\u{0301}", count: 524_288)
        XCTAssertEqual(huge.count, 1)
        let hugePieces = Termiod.InputEvent.pastePieces(huge)
        XCTAssertGreaterThan(hugePieces.count, 1)
        var rejoined = ""
        for piece in hugePieces {
            guard case .paste(let part, _) = piece else { return XCTFail("not a paste") }
            XCTAssertLessThanOrEqual(part.utf8.count, Termiod.InputEvent.pastePieceBytes)
            rejoined += part
        }
        XCTAssertEqual(rejoined.utf8.count, huge.utf8.count)
    }

    /// Only typing takes the write token: a modifier pressed on the way to a
    /// shortcut, a release, a composing key, motion and focus send no byte.
    func testOnlyTypingClaimsTheWriteToken() {
        XCTAssertTrue(Termiod.InputEvent.key(.init(key: "a", text: "a")).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.key(.init(key: "meta_left")).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.key(.init(action: .release, key: "a")).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.key(.init(key: "a", composing: true)).claimsWriter)
        XCTAssertTrue(Termiod.InputEvent.paste("x").claimsWriter)
        let at = Termiod.InputEvent.Pointer(x: 0, y: 0, cellWidth: 8, cellHeight: 16)
        XCTAssertTrue(Termiod.InputEvent.mouse(.init(action: .press, button: 1, mods: 0, at: at, buttonsHeld: true)).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.mouse(.init(action: .motion, button: nil, mods: 0, at: at, buttonsHeld: false)).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.focus(true).claimsWriter)
    }

    /// Back and forward are buttons eight and nine, as Ghostty numbers them.
    func testExtraMouseButtonsKeepTheirNumbers() throws {
        func other(_ number: Int) throws -> UInt8? {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .otherMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            // `buttonNumber` is not settable on a synthesized event; go through CGEvent.
            let cg = try XCTUnwrap(event.cgEvent)
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
            return TermiodStreamView.otherButton(try XCTUnwrap(NSEvent(cgEvent: cg)))
        }
        XCTAssertEqual(try other(2), 3, "middle")
        XCTAssertEqual(try other(3), 8, "back")
        XCTAssertEqual(try other(4), 9, "forward")
        XCTAssertEqual(try other(5), 6)
        XCTAssertEqual(try other(7), 4)
        XCTAssertEqual(try other(10), 11)
        XCTAssertNil(try other(11))
    }

    func testTheWheelIsTheProgramsOnlyWhenGhosttyWouldSendIt() throws {
        XCTAssertFalse(try terminal().wheelGoesToProgram, "scrollback")
        XCTAssertTrue(try terminal("\u{1b}[?1049h\u{1b}[?1007h").wheelGoesToProgram, "alternate scroll")
        XCTAssertFalse(try terminal("\u{1b}[?1049h\u{1b}[?1007l").wheelGoesToProgram)
        XCTAssertTrue(try terminal("\u{1b}[?1000h").wheelGoesToProgram, "mouse tracking")
    }

    /// What the program tells the terminal that the app acts on, as the
    /// embedded surface publishes it, and what a snapshot already carries.
    func testTheTerminalReportsTitleDirectoryBellNotificationsAndCopies() throws {
        var raw: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &raw, 40, 10), GHOSTTY_SUCCESS)
        let source = try XCTUnwrap(raw)
        defer { ghostty_terminal_free(source) }
        let setup = Array("\u{1b}]0;agent at work\u{07}\u{1b}]7;file://localhost/tmp/work\u{07}".utf8)
        ghostty_terminal_vt_write(source, setup, setup.count)
        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertEqual(ghostty_snapshot_encode_alloc(source, nil, &encoded, &length), GHOSTTY_SUCCESS)
        let pointer = try XCTUnwrap(encoded)
        defer { ghostty_free(nil, pointer, length) }
        var signals: [TermiodStreamTerminal.Signal] = []
        let terminal = try TermiodStreamTerminal(
            nativeSnapshot: Data(bytes: pointer, count: length), onSignal: { signals.append($0) }
        )
        XCTAssertEqual(signals, [.workingDirectory("/tmp/work")], "the snapshot's directory, not its title")

        signals = []
        terminal.write(Data("\u{1b}]2;thinking\u{07}".utf8))
        terminal.write(Data("\u{1b}]7;file://localhost/home/me/project%20one\u{07}".utf8))
        terminal.write(Data("\u{07}".utf8))
        terminal.write(Data("\u{1b}]9;build finished\u{07}".utf8))
        terminal.write(Data("\u{1b}]777;notify;Claude;needs you\u{07}".utf8))
        terminal.write(Data("\u{1b}]52;c;aGVsbG8=\u{07}".utf8))
        XCTAssertEqual(signals, [
            .title("thinking"),
            .workingDirectory("/home/me/project one"),
            .bell,
            .notification(title: "", body: "build finished"),
            .notification(title: "Claude", body: "needs you"),
            .clipboard("hello"),
        ])
    }

    /// Ghostty's OSC 7 rule: a `file` or `kitty-shell-cwd` URL naming this
    /// machine. A path from a box reached with ssh does not exist here.
    func testAWorkingDirectoryMustNameThisMachine() {
        let read = { TermiodStreamTerminal.workingDirectory(fromOSC7: $0, localHost: "mac") }
        XCTAssertEqual(read("file://mac/Users/me/a%20b"), "/Users/me/a b")
        XCTAssertEqual(read("file://localhost/tmp"), "/tmp")
        XCTAssertEqual(read("kitty-shell-cwd://mac/raw/%20path"), "/raw/%20path", "kitty sends the path as is")
        XCTAssertNil(read("file://prod/home/deploy"), "another machine")
        XCTAssertNil(read("file:///tmp"), "no host")
        XCTAssertNil(read("https://mac/tmp"), "another scheme")
        XCTAssertNil(read("/tmp"), "not a URL")
    }

    /// A program reading the clipboard is answered through the reply path,
    /// which only the writer sends on.
    func testAClipboardReadIsAnsweredThroughTheReplyPath() throws {
        var raw: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &raw, 40, 10), GHOSTTY_SUCCESS)
        let source = try XCTUnwrap(raw)
        defer { ghostty_terminal_free(source) }
        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertEqual(ghostty_snapshot_encode_alloc(source, nil, &encoded, &length), GHOSTTY_SUCCESS)
        let pointer = try XCTUnwrap(encoded)
        defer { ghostty_free(nil, pointer, length) }
        var replies = Data()
        let terminal = try TermiodStreamTerminal(
            nativeSnapshot: Data(bytes: pointer, count: length),
            onReply: { replies.append($0) }, readClipboard: { "hello" }
        )
        terminal.write(Data("\u{1b}]52;c;?\u{07}".utf8))
        let reply = String(decoding: replies, as: UTF8.self)
        XCTAssertTrue(reply.contains("52;c;aGVsbG8="), reply.debugDescription)
    }

    /// Ghostty counts half cells: a selection starts at a cell pressed in its
    /// left half and takes in a cell dragged past its middle, so presses sit
    /// at 2 of 10 pixels and drags at 8.
    private func point(_ column: UInt16, _ row: UInt16, at offset: Double = 2) -> TermiodStreamTerminal.SelectionPoint {
        .init(column: column, row: row, x: Double(column) * 10 + offset, y: Double(row) * 20 + 10)
    }

    /// Ghostty's mouse selection, on the stream pane's own terminal: a drag
    /// selects cells, a double click a word, and copying joins soft wraps.
    func testTheMouseSelectsAsGhosttyDoes() throws {
        let terminal = try terminal("hello world\r\nsecond line")
        let geometry = TermiodStreamTerminal.SelectionGeometry(cellWidth: 10, paddingLeft: 0, screenHeight: 200)
        XCTAssertNil(terminal.selectedText)

        terminal.pressSelection(at: point(0, 0), time: 1_000, interval: 500_000_000, distance: 10)
        terminal.dragSelection(to: point(4, 0, at: 8), geometry: geometry, rectangle: false)
        terminal.releaseSelection(at: point(4, 0, at: 8))
        XCTAssertEqual(terminal.selectedText, "hello")

        // Two presses within the interval: the word under the pointer.
        terminal.pressSelection(at: point(7, 0), time: 2_000_000_000, interval: 500_000_000, distance: 10)
        terminal.releaseSelection(at: point(7, 0))
        terminal.pressSelection(at: point(7, 0), time: 2_100_000_000, interval: 500_000_000, distance: 10)
        terminal.releaseSelection(at: point(7, 0))
        XCTAssertEqual(terminal.selectedText, "world")

        // A second click a few pixels off is still a double click.
        terminal.pressSelection(at: point(1, 1), time: 4_000_000_000, interval: 500_000_000, distance: 10)
        terminal.releaseSelection(at: point(1, 1))
        terminal.pressSelection(at: point(1, 1, at: 7), time: 4_100_000_000, interval: 500_000_000, distance: 10)
        terminal.releaseSelection(at: point(1, 1, at: 7))
        XCTAssertEqual(terminal.selectedText, "second")

        // A single click later clears it.
        terminal.pressSelection(at: point(1, 1), time: 9_000_000_000, interval: 500_000_000, distance: 10)
        terminal.releaseSelection(at: point(1, 1))
        XCTAssertFalse(terminal.hasSelection)

        terminal.selectAll()
        XCTAssertEqual(terminal.selectedText, "hello world\nsecond line")
        terminal.clearSelection()
        XCTAssertNil(terminal.selectedText)
    }

    /// Ghostty's scrolling bindings move this pane's view through history.
    func testTheViewMovesThroughScrollback() throws {
        let terminal = try terminal((1...40).map { "line \($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(terminal.followsLiveScreen)
        terminal.moveViewport(.top)
        XCTAssertFalse(terminal.followsLiveScreen)
        terminal.moveViewport(.pageDown)
        terminal.moveViewport(.pageDown)
        terminal.moveViewport(.pageDown)
        XCTAssertTrue(terminal.followsLiveScreen, "three pages of ten rows reach the 40 lines' end")
        terminal.moveViewport(.pageUp)
        XCTAssertFalse(terminal.followsLiveScreen)
        terminal.moveViewport(.bottom)
        XCTAssertTrue(terminal.followsLiveScreen)
    }

    /// Every selected cell is drawn alike, inverse or not: the theme's
    /// selection colors, or the default foreground behind the default
    /// background, as Ghostty's renderer does.
    func testSelectedCellsTakeTheSelectionColors() throws {
        let terminal = try terminal("a\u{1b}[7mb\u{1b}[0mc")
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 1, g: 1, b: 1), count: 256)
        palette[0] = GhosttyColorRgb(r: 0, g: 0, b: 0)
        var theme = TermiodStreamTerminal.Theme(
            foreground: GhosttyColorRgb(r: 200, g: 200, b: 200), background: GhosttyColorRgb(r: 10, g: 10, b: 10),
            cursor: nil, palette: palette, cursorStyle: GHOSTTY_CURSOR_STYLE_BAR, cursorBlink: false
        )
        try terminal.setTheme(theme)
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13, paddingX: 0, paddingY: 0, backgroundOpacity: 1
        )
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        func colors() throws -> [[UInt8]] {
            builder.invalidate()
            _ = try terminal.withFrame { state, theme in
                try builder.build(from: state, atlas: renderer.atlas, focused: false, theme: theme)
            }
            var rectangles: [TermiodStreamRectangle] = []
            var glyphs: [TermiodStreamGlyph] = []
            builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
            return (0 ..< 3).map { column in
                glyphs.first { $0.cellX == column && $0.cellY == 0 }.map { [$0.r, $0.g, $0.b] } ?? []
            }
        }
        terminal.selectAll()
        XCTAssertEqual(try colors(), Array(repeating: [10, 10, 10], count: 3), "the inverse b too")
        theme.selectionForeground = GhosttyColorRgb(r: 50, g: 60, b: 70)
        try terminal.setTheme(theme)
        XCTAssertEqual(try colors(), Array(repeating: [50, 60, 70], count: 3), "the theme's selection color")
    }

    /// A selected cell is drawn with its colors swapped.
    func testASelectionIsDrawnWithTheColorsSwapped() throws {
        let terminal = try terminal("abc")
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13, paddingX: 0, paddingY: 0, backgroundOpacity: 1
        )
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        func glyph(at column: UInt16) throws -> TermiodStreamGlyph {
            builder.invalidate()
            _ = try terminal.withFrame { state, theme in
                try builder.build(from: state, atlas: renderer.atlas, focused: false, theme: theme)
            }
            var rectangles: [TermiodStreamRectangle] = []
            var glyphs: [TermiodStreamGlyph] = []
            builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
            return try XCTUnwrap(glyphs.first { $0.cellX == column && $0.cellY == 0 })
        }
        let plain = try glyph(at: 1)
        terminal.pressSelection(at: point(0, 0), time: 1, interval: 1, distance: 10)
        terminal.dragSelection(
            to: point(1, 0, at: 8), geometry: .init(cellWidth: 10, paddingLeft: 0, screenHeight: 200), rectangle: false
        )
        let selected = try glyph(at: 1)
        XCTAssertNotEqual([plain.r, plain.g, plain.b], [selected.r, selected.g, selected.b],
                          "the selected b is drawn in the background color")
        XCTAssertEqual([try glyph(at: 2).r], [plain.r], "c is outside the selection")
    }

    /// Ghostty's own cases for its link pattern (`src/config/url.zig`): the
    /// first match in each input, and inputs with no match at all.
    func testTheLinkPatternMatchesGhosttysCases() throws {
        func first(_ input: String) -> String? {
            TermiodStreamTerminal.linkRanges(in: input).first.map { (input as NSString).substring(with: $0) }
        }
        let cases: [(String, String)] = [
            ("hello https://example.com world", "https://example.com"),
            ("https://example.com/foo(bar) more", "https://example.com/foo(bar)"),
            ("https://example.com/foo(bar)baz more", "https://example.com/foo(bar)baz"),
            ("Link inside (https://example.com) parens", "https://example.com"),
            ("Link period https://example.com. More text.", "https://example.com"),
            ("Link trailing comma https://example.com, more text.", "https://example.com"),
            ("Link in double quotes \"https://example.com\" and more", "https://example.com"),
            ("Link in single quotes 'https://example.com' and more", "https://example.com"),
            ("some file with https://google.com https://duckduckgo.com links.", "https://google.com"),
            ("and links in it. links https://yahoo.com mailto:test@example.com ssh://1.2.3.4", "https://yahoo.com"),
            ("also match http://example.com non-secure links", "http://example.com"),
            ("match tel://+12123456789 phone numbers", "tel://+12123456789"),
            ("match with query url https://example.com?query=1&other=2 and more text.", "https://example.com?query=1&other=2"),
            ("url with dashes [mode 2027](https://github.com/contour-terminal/terminal-unicode-core) for better unicode support", "https://github.com/contour-terminal/terminal-unicode-core"),
            ("dot.http://example.com", "http://example.com"),
            ("weird characters https://example.com/~user/?query=1&other=2#hash and more", "https://example.com/~user/?query=1&other=2#hash"),
            ("square brackets https://example.com/[foo] and more", "https://example.com/[foo]"),
            ("[13]:TooManyStatements: TempFile#assign_temp_file_to_entity has approx 7 statements [https://example.com/docs/Too-Many-Statements.md]", "https://example.com/docs/Too-Many-Statements.md"),
            ("match ftp://example.com ftp links", "ftp://example.com"),
            ("match file://example.com file links", "file://example.com"),
            ("match ssh://example.com ssh links", "ssh://example.com"),
            ("match git://example.com git links", "git://example.com"),
            ("/tmp/test.txt http://www.google.com", "/tmp/test.txt"),
            ("match tel:+18005551234 tel links", "tel:+18005551234"),
            ("match magnet:?xt=urn:btih:1234567890 magnet links", "magnet:?xt=urn:btih:1234567890"),
            ("match ipfs://QmSomeHashValue ipfs links", "ipfs://QmSomeHashValue"),
            ("match ipns://QmSomeHashValue ipns links", "ipns://QmSomeHashValue"),
            ("match gemini://example.com gemini links", "gemini://example.com"),
            ("match gopher://example.com gopher links", "gopher://example.com"),
            ("match news:comp.infosystems.www.servers.unix news links", "news:comp.infosystems.www.servers.unix"),
            ("/Users/ghostty.user/code/example.py", "/Users/ghostty.user/code/example.py"),
            ("/Users/ghostty.user/code/../example.py", "/Users/ghostty.user/code/../example.py"),
            ("/Users/ghostty.user/code/../example.py hello world", "/Users/ghostty.user/code/../example.py"),
            ("../example.py", "../example.py"),
            ("../example.py ", "../example.py"),
            ("first time ../example.py contributor ", "../example.py"),
            ("[link](/home/user/ghostty.user/example)", "/home/user/ghostty.user/example"),
            ("Serving HTTP on :: port 8000 (http://[::]:8000/)", "http://[::]:8000/"),
            ("IPv6 address https://[2001:db8::1]:8080/path", "https://[2001:db8::1]:8080/path"),
            ("IPv6 localhost http://[::1]:3000", "http://[::1]:3000"),
            ("Complex IPv6 https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/", "https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/"),
            ("IPv6 with path https://[2001:db8::1]/path/to/resource", "https://[2001:db8::1]/path/to/resource"),
            ("IPv6 with query https://[2001:db8::1]:8080/api?param=value&other=123", "https://[2001:db8::1]:8080/api?param=value&other=123"),
            ("IPv6 compressed http://[2001:db8::]:80/", "http://[2001:db8::]:80/"),
            ("IPv6 multiple zeros http://[2001:0:0:0:0:0:0:1]", "http://[2001:0:0:0:0:0:0:1]"),
            ("IPv6 link-local https://[fe80::1234:5678:9abc]", "https://[fe80::1234:5678:9abc]"),
            ("IPv6 multicast http://[ff02::1]/stream", "http://[ff02::1]/stream"),
            ("IPv6 in markdown [link](http://[2001:db8::1]/docs)", "http://[2001:db8::1]/docs"),
            ("./spaces-end.   ", "./spaces-end."),
            ("./space middle", "./space middle"),
            ("../test folder/file.txt", "../test folder/file.txt"),
            ("/tmp/test folder/file.txt", "/tmp/test folder/file.txt"),
            ("/tmp/test  folder/file.txt", "/tmp/test"),
            ("diff --git a/src/font/shaper/harfbuzz.zig b/src/font/shaper/harfbuzz.zig", "a/src/font/shaper/harfbuzz.zig"),
            ("/tmp/foo /tmp/bar", "/tmp/foo"),
            ("/tmp/foo.txt /tmp/bar.txt", "/tmp/foo.txt"),
            ("src/config/url.zig", "src/config/url.zig"),
            ("app/folder/file.rb:1", "app/folder/file.rb:1"),
            ("modified:   src/config/url.zig", "src/config/url.zig"),
            ("lib/ghostty/terminal.zig:42:10", "lib/ghostty/terminal.zig:42:10"),
            ("some-pkg/src/file.txt more text", "some-pkg/src/file.txt"),
            ("src/foo.c,baz.txt", "src/foo.c"),
            ("~/foo/bar.txt", "~/foo/bar.txt"),
            ("open ~/Documents/notes.md please", "~/Documents/notes.md"),
            ("~/.config/ghostty/config", "~/.config/ghostty/config"),
            ("directory: ~/src/ghostty-org/ghostty", "~/src/ghostty-org/ghostty"),
            ("$HOME/src/config/url.zig", "$HOME/src/config/url.zig"),
            ("project dir: $PWD/src/ghostty/main.zig", "$PWD/src/ghostty/main.zig"),
            ("foo/$BAR/baz", "foo/$BAR/baz"),
            (".foo/bar/$VAR", ".foo/bar/$VAR"),
            (".config/ghostty/config", ".config/ghostty/config"),
            ("loaded from .local/share/ghostty/state.db now", ".local/share/ghostty/state.db"),
            ("../some/where", "../some/where"),
            ("  - shared/src/foo/SomeItem.m:12, shared/src/", "shared/src/foo/SomeItem.m:12"),
            ("foo.local/share", "foo.local/share"),
            ("2024/report.txt", "2024/report.txt"),
            ("./foo bar,baz", "./foo bar"),
            ("/tmp/foo bar,baz", "/tmp/foo bar"),
            ("./.config/ghostty: Needs upstream (main)", "./.config/ghostty"),
            ("./Downloads: Operation not permitted", "./Downloads"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(first(input), expected, input)
        }
        for input in ["input/output", "foo/bar", "$10/bar", "$10/$20", "$10/bar.txt", "foo/bar,baz.txt",
                      "foo$BAR/baz.txt", "foo~/bar.txt", "// foo bar", "//foo"] {
            XCTAssertNil(first(input), input)
        }
    }

    /// Text that made Ghostty's pattern, run by ICU, backtrack for seconds
    /// finds its links at once.
    func testHostileTextIsMatchedInLinearTime() {
        let base64 = String(repeating: "QUJDRA", count: 1700)
        let hostile = [
            "https://a" + String(repeating: ".,", count: 2000),
            "https://[2001:0db8:85a3:0000:0000:0000:0000:0000:0000",
            base64,
            String(repeating: "a/", count: 3000),
            String(repeating: "ab-cd.", count: 400),
            String(repeating: "GET https://api.x.io/v1/items?id=42 200 ", count: 60) + "token=" + base64,
        ]
        for text in hostile {
            let started = ContinuousClock.now
            _ = TermiodStreamTerminal.linkRanges(in: text, around: (text as NSString).length / 2)
            // Backtracking took seconds; a busy shared runner takes a few
            // hundred milliseconds to do linear work, so the bound sits between.
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), String(text.prefix(20)))
        }
        XCTAssertEqual(
            TermiodStreamTerminal.linkRanges(in: "https://a" + String(repeating: ".,", count: 20)).first?.length,
            9, "the trailing dots and commas are not the URL"
        )
    }

    /// A URL longer than the path window is the same whole URL from wherever
    /// the pointer is on it, never a piece of it read as a path.
    func testALongURLIsWholeFromEveryPointOnIt() {
        let query = (0 ..< 60).map { "k\($0)=v\($0)" }.joined(separator: "&")
        let url = "https://bucket.s3.amazonaws.com/dir/file.tar.gz?" + query
            + "&X-Amz-Credential=AKIA/20261025/us-east-1/s3/aws4_request&sig=abc.def"
        let text = "see " + url + " end"
        let length = (url as NSString).length
        for index in stride(from: 4, to: 4 + length, by: 37) {
            let found = TermiodStreamTerminal.linkRanges(in: text, around: index).first { NSLocationInRange(index, $0) }
            XCTAssertEqual(found.map { (text as NSString).substring(with: $0) }, url, "pointer at \(index)")
        }
    }

    /// A path that starts further back than the window is not offered as
    /// the piece of it the window holds.
    func testALongPathIsNeverOfferedAsAPieceOfIt() {
        let path = "/Users/me/" + String(repeating: "my-dir/", count: 60) + "file.txt"
        XCTAssertEqual(TermiodStreamTerminal.linkRanges(in: path).first, NSRange(location: 0, length: (path as NSString).length))
        XCTAssertEqual(TermiodStreamTerminal.linkRanges(in: path, around: 430), [])
        let spaced = "/Users/me/Library/" + String(repeating: "x-dir/", count: 45) + "Mobile Documents/file.txt"
        XCTAssertEqual(TermiodStreamTerminal.linkRanges(in: spaced).first?.length, (spaced as NSString).length)
        XCTAssertEqual(TermiodStreamTerminal.linkRanges(in: spaced, around: 305), [], "not Documents/file.txt")
    }

    /// Ghostty's scheme branch: a suffix is a matched `(word)` or `[word]`
    /// after URL characters, and a word may be outside the BMP.
    func testTheSchemeScanFollowsGhosttysSuffixRules() {
        func first(_ input: String) -> String? {
            TermiodStreamTerminal.linkRanges(in: input).first.map { (input as NSString).substring(with: $0) }
        }
        XCTAssertEqual(first("https://x.com/a(b] c"), "https://x.com/a")
        XCTAssertEqual(first("https://x.com/a(b)(c) d"), "https://x.com/a(b)")
        XCTAssertEqual(first("https://[::1](x) y"), "https://[::1]")
        XCTAssertEqual(first("https://x.com/\u{20000}b c"), "https://x.com/\u{20000}b")
    }

    /// The link under the pointer: an OSC 8 hyperlink first, then a detected
    /// URL or path, with the cells it covers.
    func testTheLinkUnderThePointer() throws {
        let terminal = try terminal(
            "see https://example.com/a. ok\r\n\u{1b}]8;;https://termio.sh\u{07}docs\u{1b}]8;;\u{07} and src/main.swift"
        )
        XCTAssertEqual(terminal.link(at: point(6, 0)), .init(url: "https://example.com/a", segments: [.init(row: 0, columns: 4 ... 24)]))
        XCTAssertNil(terminal.link(at: point(1, 0)), "plain text")
        XCTAssertEqual(terminal.link(at: point(2, 1)), .init(url: "https://termio.sh", segments: [.init(row: 1, columns: 0 ... 3)]))
        XCTAssertEqual(terminal.link(at: point(12, 1)), .init(url: "src/main.swift", segments: [.init(row: 1, columns: 9 ... 22)]))
    }

    /// A URL longer than the row is one link across the wrap, as Ghostty
    /// matches the whole soft-wrapped line; and a host in brackets with no
    /// closing one costs no time.
    func testALinkWrapsAndAnUnclosedBracketIsCheap() throws {
        let url = "https://github.com/termio-sh/termio/pull/785"
        let terminal = try terminal("x " + url)
        // 40 columns: the URL starts at 2 and wraps after 38 of its 44 characters.
        let expected = TermiodStreamTerminal.Link(
            url: url, segments: [.init(row: 0, columns: 2 ... 39), .init(row: 1, columns: 0 ... 5)]
        )
        XCTAssertEqual(terminal.link(at: point(10, 0)), expected)
        XCTAssertEqual(terminal.link(at: point(3, 1)), expected, "from the second row too")

        let hostile = try self.terminal("https://[2001:0db8:85a3:0000:0000:0000:0000:0000:0000")
        let started = ContinuousClock.now
        _ = hostile.link(at: point(12, 0))
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(200))
    }

    /// A wrapped URL whose start has scrolled out of the view is still the
    /// whole URL, underlined only where it is on screen.
    func testALinkIsFollowedIntoScrollback() throws {
        let url = "https://github.com/termio-sh/termio/pull/785"
        // 40 columns and 10 rows: 9 more lines push the URL's first row off the top.
        let terminal = try terminal("x " + url + String(repeating: "\r\n", count: 9))
        XCTAssertEqual(
            terminal.link(at: point(3, 0)),
            .init(url: url, segments: [.init(row: 0, columns: 0 ... 5)])
        )
    }

    /// The hovered link is underlined across the cells it covers.
    func testAHoveredLinkIsUnderlined() throws {
        let terminal = try terminal("go https://x.io now")
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13, paddingX: 0, paddingY: 0, backgroundOpacity: 1
        )
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        let link = try XCTUnwrap(terminal.link(at: point(5, 0)))
        func underlines(_ link: TermiodStreamTerminal.Link?) throws -> [TermiodStreamRectangle] {
            _ = try terminal.withFrame { state, theme in
                // Focused, so the cursor is a block under the text, not an
                // outline among the over-text rectangles.
                try builder.build(from: state, atlas: renderer.atlas, focused: true, theme: theme, link: link)
            }
            var rectangles: [TermiodStreamRectangle] = []
            var glyphs: [TermiodStreamGlyph] = []
            builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
            return rectangles.filter { $0.overText && $0.cellY == 0 }
        }
        let shown = try underlines(link)
        XCTAssertEqual(shown.map(\.cellX), [3])
        XCTAssertEqual(Int(shown.first?.width ?? 0), renderer.atlas.metrics.width * 12, "https://x.io is 12 cells")
        XCTAssertTrue(try underlines(nil).isEmpty, "gone when ⌘ is let go")
    }

    /// A Kitty image is drawn over the cells the terminal placed it on, at
    /// the renderer's cell size, and goes when the program deletes it.
    func testAKittyImageIsDrawnOnItsCells() throws {
        let terminal = try terminal()
        // termiod's cell size, which image placement needs.
        try terminal.resize(rows: 10, cols: 40, reflow: true)
        let red = Data(Array(repeating: [UInt8]([0xFF, 0x00, 0x00, 0xFF]), count: 16 * 32).flatMap { $0 })
        // 16 by 32 pixels: two cells by two rows of 8 by 16, from the first cell.
        terminal.write(Data("\u{1b}_Ga=T,f=32,s=16,v=32,q=2;\(red.base64EncodedString())\u{1b}\\".utf8))
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13, paddingX: 0, paddingY: 0, backgroundOpacity: 1
        )
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let cell = renderer.atlas.metrics
        func pixel(_ x: Int, _ y: Int) throws -> [UInt8] {
            let image = try renderer.image(of: terminal, width: cell.width * 40, height: cell.height * 10, focused: false)
            let data = try XCTUnwrap(image.dataProvider?.data as Data?)
            let offset = y * image.bytesPerRow + x * 4
            // BGRA, premultiplied.
            return [data[offset + 2], data[offset + 1], data[offset]]
        }
        XCTAssertEqual(try pixel(cell.width + cell.width / 2, cell.height + cell.height / 2), [0xFF, 0, 0], "the image's last cell")
        XCTAssertNotEqual(try pixel(cell.width * 2 + cell.width / 2, cell.height / 2), [0xFF, 0, 0], "past its two columns")
        terminal.write(Data("\u{1b}_Ga=d,d=A,q=2\u{1b}\\".utf8))
        XCTAssertNotEqual(try pixel(cell.width / 2, cell.height / 2), [0xFF, 0, 0], "deleted")
    }

    /// A fast animation shows a frame on every draw: the list and the
    /// storage name the same frame, so no draw finds its texture missing.
    func testAFastAnimationIsNeverBlank() throws {
        let terminal = try terminal()
        try terminal.resize(rows: 10, cols: 40, reflow: true)
        func solid(_ pixel: [UInt8]) -> String {
            Data(Array(repeating: pixel, count: 16 * 32).flatMap { $0 }).base64EncodedString()
        }
        for command in [
            "a=T,f=32,s=16,v=32,i=7,q=2;" + solid([0xFF, 0, 0, 0xFF]),
            "a=f,i=7,f=32,s=16,v=32,z=10,q=2;" + solid([0, 0xFF, 0, 0xFF]),
            "a=a,i=7,r=1,z=10,q=2",
            "a=a,i=7,s=3,v=1,q=2",
        ] {
            terminal.write(Data("\u{1b}_G\(command)\u{1b}\\".utf8))
        }
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13, paddingX: 0, paddingY: 0, backgroundOpacity: 1
        )
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let cell = renderer.atlas.metrics
        var shown: Set<[UInt8]> = []
        for _ in 0 ..< 30 {
            let image = try renderer.image(of: terminal, width: cell.width * 40, height: cell.height * 10, focused: false)
            let data = try XCTUnwrap(image.dataProvider?.data as Data?)
            let offset = (cell.height / 2) * image.bytesPerRow + (cell.width / 2) * 4
            let pixel = [data[offset + 2], data[offset + 1], data[offset]]
            XCTAssertTrue(pixel == [0xFF, 0, 0] || pixel == [0, 0xFF, 0], "a blank frame: \(pixel)")
            shown.insert(pixel)
            usleep(16_000)
        }
        XCTAssertEqual(shown.count, 2, "both frames played")
    }

    /// What `termio session read` reports for a stream pane.
    func testTheActiveScreenReadsAsText() throws {
        let terminal = try terminal("hello\r\nworld")
        let lines = try terminal.activeText().components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(2)), ["hello", "world"])
    }

    /// Ghostty's preedit: composed text from the cursor on, in the foreground
    /// color and underlined, over the cells it covers, with no cursor drawn.
    func testComposedTextIsDrawnAtTheCursorInPlaceOfTheCells() throws {
        let terminal = try terminal("abcdef\r")
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13, paddingX: 0, paddingY: 0, backgroundOpacity: 1
        )
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        func frame(_ preedit: String?) throws -> ([TermiodStreamRectangle], [TermiodStreamGlyph]) {
            _ = try terminal.withFrame { state, theme in
                try builder.build(from: state, atlas: renderer.atlas, focused: true, theme: theme, preedit: preedit)
            }
            var rectangles: [TermiodStreamRectangle] = []
            var glyphs: [TermiodStreamGlyph] = []
            builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
            return (rectangles, glyphs)
        }
        let plain = try frame(nil)
        XCTAssertEqual(plain.1.count, 6)
        XCTAssertTrue(plain.0.contains { $0.cellX == 0 && $0.cellY == 0 && $0.y == 0 }, "the block cursor")

        let composing = try frame("中文")
        let row = composing.1.filter { $0.cellY == 0 }
        XCTAssertEqual(row.map(\.cellX), [4, 5, 0, 2], "a b c d e f under 中 and 文 give way to them")
        XCTAssertFalse(composing.0.contains { $0.cellX == 0 && $0.y == 0 && $0.height > 4 }, "no cursor")
        let underlines = composing.0.filter { $0.overText && $0.cellY == 0 }
        XCTAssertEqual(underlines.map(\.cellX), [0, 2])

        XCTAssertEqual(try frame(nil).1.count, 6, "committing or cancelling gives the cells back")
    }
}
