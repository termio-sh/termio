import AppKit
import GhosttyVt
import XCTest
@testable import TermioStream
@testable import termio

/// The stream renderer, drawn offscreen: no window, so it runs anywhere Metal
/// does. Pixels are read back at cells whose color the screen fixes, and
/// `TERMIO_RENDER_OUT=<file.png>` saves the frame to look at by eye.
@MainActor
final class StreamRendererTests: XCTestCase {
    private let appearance = TermiodStreamRenderer.Appearance(
        fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13,
        paddingX: 8, paddingY: 2, backgroundOpacity: 1
    )

    /// Glyphs with different fractional bounds keep one baseline and one left edge:
    /// the origin in the bitmap is whole, and the bitmap holds the whole glyph.
    func testGlyphOriginIsAWholePixel() {
        let boxes = [
            CGRect(x: 0.4, y: -2.63, width: 23.2, height: 23.79),
            CGRect(x: -1.7, y: -2.0, width: 23.2, height: 23.32),
            CGRect(x: 2, y: 3, width: 5, height: 7),
        ]
        for box in boxes {
            let placement = GlyphPlacement(bounds: box, padding: 1)
            XCTAssertEqual(placement.origin.x, placement.origin.x.rounded())
            XCTAssertEqual(placement.origin.y, placement.origin.y.rounded())
            // The baseline, measured from the bitmap's top edge, is where `ascent` says.
            XCTAssertEqual(placement.height - Int(placement.origin.y), placement.ascent)
            XCTAssertEqual(placement.left + Int(placement.origin.x), 0)
            XCTAssertGreaterThanOrEqual(placement.origin.y + box.minY, 1)
            XCTAssertLessThanOrEqual(placement.origin.y + box.maxY, CGFloat(placement.height - 1))
            XCTAssertLessThanOrEqual(placement.origin.x + box.maxX, CGFloat(placement.width - 1))
        }
    }

    /// A Nerd Fonts icon resolves to the bundled face through the cascade.
    func testSymbolsFontAnswersANerdFontIcon() {
        let cascade = [CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: TermioStore.symbolsFontFamily] as CFDictionary)]
        let font = CTFontCreateCopyWithAttributes(
            CTFontCreateWithName("Menlo" as CFString, 13, nil), 13, nil,
            CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: cascade] as CFDictionary))
        let used = CTFontCreateForString(font, "\u{F015}" as CFString, CFRange(location: 0, length: 1))
        XCTAssertEqual(CTFontCopyFamilyName(used) as String, "Symbols Nerd Font")
    }

    private func terminal() throws -> TermiodStreamTerminal {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "vt-stream-resize", withExtension: "txt", subdirectory: "Fixtures"))
        let attach = try XCTUnwrap(
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("attach ") })
        var native = Data()
        var high: UInt8?
        for character in attach.dropFirst("attach ".count).utf8 {
            let nibble = try XCTUnwrap(UInt8(String(UnicodeScalar(character)), radix: 16))
            if let first = high { native.append(first << 4 | nibble); high = nil } else { high = nibble }
        }
        let terminal = try TermiodStreamTerminal(nativeSnapshot: native)
        // Finish the OSC the snapshot was taken inside, then start clean.
        terminal.write(Data("\u{7}\u{1b}[2J\u{1b}[H".utf8))
        try terminal.resize(rows: 10, cols: 40, reflow: true)
        return terminal
    }

    private func colors() -> TermiodStreamTerminal.Theme {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 128, g: 128, b: 128), count: 256)
        palette[1] = GhosttyColorRgb(r: 220, g: 40, b: 40)
        palette[4] = GhosttyColorRgb(r: 40, g: 80, b: 220)
        return TermiodStreamTerminal.Theme(
            foreground: GhosttyColorRgb(r: 230, g: 230, b: 230),
            background: GhosttyColorRgb(r: 20, g: 20, b: 20),
            cursor: nil, palette: palette, cursorStyle: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK,
            cursorBlink: false
        )
    }

    func testAFrameDrawsTheThemeTheCellsAndTheText() throws {
        let terminal = try terminal()
        try terminal.setTheme(colors())
        let screen = [
            "\u{1b}[41m  red  \u{1b}[0m \u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[2mfaint\u{1b}[0m",
            "\u{1b}[4msingle\u{1b}[0m \u{1b}[4:2mdouble\u{1b}[0m \u{1b}[4:3mcurly\u{1b}[0m \u{1b}[9mstrike\u{1b}[0m",
            "\u{1b}[38;2;255;160;0mtrue colour\u{1b}[0m \u{1b}[44;97m blue \u{1b}[0m \u{1b}[7minverse\u{1b}[0m",
            "你好，世界 ┌──┐ 🚀✨ e\u{301}",
            "$ ",
        ].joined(separator: "\r\n")
        terminal.write(Data(screen.utf8))

        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let metrics = renderer.atlas.metrics
        let width = Int(2 * appearance.paddingX) + metrics.width * 40
        let height = Int(2 * appearance.paddingY * 2) + metrics.height * 10
        let image = try renderer.image(of: terminal, width: width, height: height)
        if let path = ProcessInfo.processInfo.environment["TERMIO_RENDER_OUT"] {
            let representation = NSBitmapImageRep(cgImage: image)
            try representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        // The texture's own bytes, BGRA: reading through NSColor would color-manage them.
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        func color(column: Int, row: Int, dx: Int = 1, dy: Int = 1) -> (Int, Int, Int) {
            let x = Int(appearance.paddingX * 2) + column * metrics.width + dx
            let y = Int(appearance.paddingY * 2) + row * metrics.height + dy
            let offset = y * image.bytesPerRow + x * 4
            return (Int(pixels[offset + 2]), Int(pixels[offset + 1]), Int(pixels[offset]))
        }
        // The cell corner, where no glyph reaches: only the background shows.
        XCTAssertEqual(color(column: 0, row: 0).0, 220, accuracy: 2, "red background cell")
        XCTAssertEqual(color(column: 30, row: 6).2, 20, accuracy: 2, "theme background below the text")
        // ` blue ` starts at column 12 of row 2.
        XCTAssertEqual(color(column: 13, row: 2).2, 220, accuracy: 2, "palette blue background")
        // The block cursor sits after `$ ` on row 4, drawn in the foreground.
        XCTAssertEqual(color(column: 2, row: 4).0, 230, accuracy: 2, "block cursor")
    }

    private func builtFrame(
        _ terminal: TermiodStreamTerminal, _ builder: TermiodStreamFrameBuilder, _ atlas: TermiodGlyphAtlas
    ) throws -> (changed: Bool, rectangles: [TermiodStreamRectangle], glyphs: [TermiodStreamGlyph]) {
        let changed = try terminal.withFrame { state, theme in
            try builder.build(from: state, atlas: atlas, focused: true, theme: theme)
        }
        var rectangles: [TermiodStreamRectangle] = []
        var glyphs: [TermiodStreamGlyph] = []
        builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
        return (changed, rectangles, glyphs)
    }

    /// A font with programming ligatures draws `=>` from the glyphs its
    /// neighbours select, as Ghostty's run shaper does; a font without them,
    /// and a lone `=`, draw as before.
    func testAPunctuationRunIsShapedAsOne() throws {
        let ligatured = TermiodStreamRenderer.Appearance(
            fontFamily: "JetBrains Mono", fallbackFamilies: [], fontSize: 13,
            paddingX: 8, paddingY: 2, backgroundOpacity: 1
        )
        let installed = CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: "JetBrains Mono"] as CFDictionary), 13, nil)
        try XCTSkipUnless((CTFontCopyFamilyName(installed) as String) == "JetBrains Mono", "JetBrains Mono is not installed")
        let renderer = try TermiodStreamRenderer(appearance: ligatured, scale: 2)
        let atlas = renderer.atlas
        XCTAssertNotNil(atlas.ligatures(Array("=>".utf16), bold: false, italic: false))
        XCTAssertNil(try TermiodGlyphAtlas(device: renderer.device, appearance: appearance, scale: 2)
            .ligatures(Array("=>".utf16), bold: false, italic: false), "Menlo has no ligatures")

        let terminal = try terminal()
        terminal.write(Data("a => b = c".utf8))
        let (_, _, glyphs) = try builtFrame(terminal, TermiodStreamFrameBuilder(), atlas)
        let alone = try XCTUnwrap(atlas.slot(graphemes: [0x3D], bold: false, italic: false, cells: 1))
        func origin(at column: UInt16) -> SIMD2<UInt16>? {
            glyphs.first { $0.cellX == column && $0.cellY == 0 }.map { SIMD2($0.atlasX, $0.atlasY) }
        }
        XCTAssertNotEqual(origin(at: 2), alone.origin, "the = of => drew as a lone =")
        XCTAssertEqual(origin(at: 7), alone.origin, "a lone = changed")

        // A run in a font without ligatures shapes as its characters, however
        // long: the pen is measured from the run's own advances, not the grid.
        let menlo = try TermiodGlyphAtlas(device: renderer.device, appearance: appearance, scale: 2)
        XCTAssertNil(menlo.ligatures(Array("----------".utf16), bold: false, italic: false))
        XCTAssertNil(menlo.ligatures(Array(String(repeating: "=", count: 40).utf16), bold: false, italic: false))
        let berkeley = TermiodStreamRenderer.Appearance(
            fontFamily: "Berkeley Mono", fallbackFamilies: [], fontSize: 13, paddingX: 8, paddingY: 2, backgroundOpacity: 1)
        if let berkeleyAtlas = try? TermiodGlyphAtlas(device: renderer.device, appearance: berkeley, scale: 1) {
            XCTAssertNil(berkeleyAtlas.ligatures(Array(String(repeating: "=", count: 40).utf16), bold: false, italic: false))
        }
        for scale in [1, 2] as [CGFloat] {
            let shaped = try TermiodGlyphAtlas(device: renderer.device, appearance: ligatured, scale: scale)
                .ligatures(Array(String(repeating: "=", count: 40).utf16), bold: false, italic: false) ?? []
            for case let .glyph(_, shift) in shaped {
                XCTAssertEqual(shift, 0, "a glyph walked off its cell at scale \(scale)")
            }
        }
    }

    /// A ligature is one glyph across its cells, so it is drawn only where
    /// they look alike, as Ghostty breaks its runs: two colors, or the
    /// cursor on one of them, draw the characters apart.
    func testARunBreaksWhereItsCellsAreDrawnDifferently() throws {
        let ligatured = TermiodStreamRenderer.Appearance(
            fontFamily: "JetBrains Mono", fallbackFamilies: [], fontSize: 13,
            paddingX: 8, paddingY: 2, backgroundOpacity: 1
        )
        let installed = CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: "JetBrains Mono"] as CFDictionary), 13, nil)
        try XCTSkipUnless((CTFontCopyFamilyName(installed) as String) == "JetBrains Mono", "JetBrains Mono is not installed")
        let renderer = try TermiodStreamRenderer(appearance: ligatured, scale: 2)
        let atlas = renderer.atlas
        let equals = try XCTUnwrap(atlas.slot(graphemes: [0x3D], bold: false, italic: false, cells: 1))
        func equalsOrigin(_ text: String, column: UInt16) throws -> SIMD2<UInt16>? {
            let terminal = try terminal()
            terminal.write(Data(text.utf8))
            let (_, _, glyphs) = try builtFrame(terminal, TermiodStreamFrameBuilder(), atlas)
            return glyphs.first { $0.cellX == column && $0.cellY == 0 }.map { SIMD2($0.atlasX, $0.atlasY) }
        }
        XCTAssertNotEqual(try equalsOrigin("a => b", column: 2), equals.origin, "one color still joins")
        XCTAssertEqual(try equalsOrigin("a \u{1b}[31m=\u{1b}[34m>\u{1b}[0m b", column: 2), equals.origin, "two colors joined")
        // The cursor left on the `>`: its cell stands alone.
        XCTAssertEqual(try equalsOrigin("a => b\u{1b}[1;4H", column: 2), equals.origin, "a run joined across the cursor")
    }

    /// Moving the cursor dirties no cell, and a frame must still follow it;
    /// hiding a block cursor gives the character under it its own color back.
    func testTheCursorRedrawsOnItsOwnAndLeavesNoTrace() throws {
        let terminal = try terminal()
        try terminal.setTheme(colors())
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        terminal.write(Data("X".utf8))
        XCTAssertTrue(try builtFrame(terminal, builder, renderer.atlas).changed)
        XCTAssertFalse(try builtFrame(terminal, builder, renderer.atlas).changed, "nothing changed")

        terminal.write(Data("\u{1b}[D".utf8))
        let onX = try builtFrame(terminal, builder, renderer.atlas)
        XCTAssertTrue(onX.changed, "a cursor move alone is a new frame")
        let covered = try XCTUnwrap(onX.glyphs.first { $0.cellX == 0 && $0.cellY == 0 })
        XCTAssertEqual(covered.r, 20, "text under the block cursor takes the background color")

        terminal.write(Data("\u{1b}[?25l".utf8))
        let hidden = try builtFrame(terminal, builder, renderer.atlas)
        XCTAssertTrue(hidden.changed)
        let shown = try XCTUnwrap(hidden.glyphs.first { $0.cellX == 0 && $0.cellY == 0 })
        XCTAssertEqual(shown.r, 230, "with the cursor hidden the character is drawn in the foreground")
    }

    /// Mode 2026: the frame on screen is the one the program finished when its
    /// hold began, so a program redrawing hold after hold shows each finished
    /// frame in turn and never a half-drawn one; a hold past the limit ends.
    func testSynchronizedOutputShowsOnlyFinishedFrames() throws {
        let terminal = try terminal()
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        func text() throws -> Int { try builtFrame(terminal, builder, renderer.atlas).glyphs.count }
        XCTAssertEqual(try text(), 0)
        terminal.write(Data("\u{1b}[?2026hAB".utf8))
        XCTAssertEqual(try text(), 0, "AB is half of a frame still being drawn")
        terminal.write(Data("\u{1b}[?2026l\u{1b}[?2026hCD".utf8))
        XCTAssertEqual(try text(), 2, "AB finished when the next hold began; CD has not")
        terminal.write(Data("\u{1b}[?2026l".utf8))
        XCTAssertEqual(try text(), 4, "released by the program")

        terminal.write(Data("\u{1b}[?2026hEF".utf8))
        XCTAssertEqual(try text(), 4)
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertEqual(try text(), 6, "a hold past the limit is ended")
    }

    /// A full atlas starts over instead of drawing nothing new.
    func testAFullAtlasMakesRoomForNewGlyphs() throws {
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let atlas = try TermiodGlyphAtlas(device: renderer.device, appearance: appearance, scale: 2, size: 128)
        for codepoint in UInt32(0x4E00)..<UInt32(0x4E00 + 200) {
            XCTAssertNotNil(atlas.slot(graphemes: [codepoint], bold: false, italic: false, cells: 2),
                            "U+\(String(codepoint, radix: 16)) was not drawn")
        }
        XCTAssertGreaterThan(atlas.generation, 0, "the atlas filled and was emptied")
    }

    /// Panes with the same font draw from one atlas on one device; another
    /// font size gets its own.
    func testPanesShareOneAtlasPerFont() throws {
        let first = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let second = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        XCTAssertTrue(first.atlas === second.atlas)
        XCTAssertTrue(first.device === second.device)
        var larger = appearance
        larger.fontSize = 15
        let third = try TermiodStreamRenderer(appearance: larger, scale: 2)
        XCTAssertFalse(first.atlas === third.atlas)
        XCTAssertFalse(first.atlas === (try TermiodStreamRenderer(appearance: appearance, scale: 1)).atlas)
    }

    /// Another pane can empty the shared atlas between two of this pane's
    /// frames; rows built before that name sprites that moved.
    func testRowsAreRebuiltAfterAnotherPaneEmptiesTheAtlas() throws {
        let terminal = try terminal()
        try terminal.setTheme(colors())
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let atlas = try TermiodGlyphAtlas(device: renderer.device, appearance: appearance, scale: 2, size: 128)
        let builder = try TermiodStreamFrameBuilder()
        terminal.write(Data("abc".utf8))
        XCTAssertTrue(try builtFrame(terminal, builder, atlas).changed)
        XCTAssertFalse(try builtFrame(terminal, builder, atlas).changed, "nothing changed")

        let generation = atlas.generation
        for codepoint in UInt32(0x4E00)..<UInt32(0x4E00 + 200) {
            _ = atlas.slot(graphemes: [codepoint], bold: false, italic: false, cells: 2)
        }
        XCTAssertGreaterThan(atlas.generation, generation, "the other pane filled the atlas and emptied it")

        let frame = try builtFrame(terminal, builder, atlas)
        XCTAssertTrue(frame.changed, "the screen is rebuilt against the emptied atlas")
        XCTAssertEqual(frame.glyphs.count, 3)
        let slot = try XCTUnwrap(atlas.slot(graphemes: [0x61], bold: false, italic: false, cells: 1))
        let first = try XCTUnwrap(frame.glyphs.first { $0.cellX == 0 && $0.cellY == 0 })
        XCTAssertEqual(SIMD2(first.atlasX, first.atlasY), slot.origin, "the glyph names the sprite's new place")
    }

    /// Composed text drawn after the rows can be what fills the atlas; the
    /// frame it lands in must not draw rows from the emptied one.
    func testComposedTextThatEmptiesTheAtlasRebuildsTheRows() throws {
        let terminal = try terminal()
        try terminal.setTheme(colors())
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let atlas = try TermiodGlyphAtlas(device: renderer.device, appearance: appearance, scale: 2, size: 128)
        let builder = try TermiodStreamFrameBuilder()
        terminal.write(Data("abc".utf8))
        XCTAssertTrue(try builtFrame(terminal, builder, atlas).changed)
        // Fill it to the brim without emptying it, the way earlier frames would.
        atlas.mayEmpty = false
        var codepoint = UInt32(0x4E00)
        while atlas.slot(graphemes: [codepoint], bold: false, italic: false, cells: 2) != nil { codepoint += 1 }
        atlas.mayEmpty = true
        let generation = atlas.generation

        _ = try terminal.withFrame { state, theme in
            try builder.build(from: state, atlas: atlas, focused: true, theme: theme, preedit: "龘")
        }
        var rectangles: [TermiodStreamRectangle] = []
        var glyphs: [TermiodStreamGlyph] = []
        builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
        XCTAssertGreaterThan(atlas.generation, generation, "the composed text emptied the atlas")
        let slot = try XCTUnwrap(atlas.slot(graphemes: [0x61], bold: false, italic: false, cells: 1))
        let first = try XCTUnwrap(glyphs.first { $0.cellX == 0 && $0.cellY == 0 })
        XCTAssertEqual(SIMD2(first.atlasX, first.atlasY), slot.origin, "the row names the sprite's place in this atlas")
    }

    private func cursorWidth(_ frame: (changed: Bool, rectangles: [TermiodStreamRectangle], glyphs: [TermiodStreamGlyph]),
                             at x: UInt16) -> UInt16? {
        // The cursor is the last rectangle laid at its cell with the foreground color.
        frame.rectangles.last { $0.cellX == x && $0.cellY == 0 && $0.r == 230 }?.width
    }

    /// The setting is the cursor's default, and a program's own DECSCUSR wins
    /// over it, block included.
    func testTheCursorSettingIsTheDefaultAProgramCanOverride() throws {
        let terminal = try terminal()
        var theme = colors()
        theme.cursorStyle = GHOSTTY_TERMINAL_CURSOR_STYLE_BAR
        try terminal.setTheme(theme)
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        let cell = UInt16(renderer.atlas.metrics.width)
        XCTAssertLessThan(try XCTUnwrap(cursorWidth(builtFrame(terminal, builder, renderer.atlas), at: 0)), cell,
                          "no program style: the bar setting")
        terminal.write(Data("\u{1b}[2 q".utf8))
        XCTAssertEqual(cursorWidth(try builtFrame(terminal, builder, renderer.atlas), at: 0), cell,
                       "the program asked for a block")
    }

    /// A block cursor on a wide character covers both of its cells.
    func testABlockCursorCoversAWideCharacter() throws {
        let terminal = try terminal()
        try terminal.setTheme(colors())
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        terminal.write(Data("中\r".utf8))
        let frame = try builtFrame(terminal, builder, renderer.atlas)
        XCTAssertEqual(cursorWidth(frame, at: 0), UInt16(2 * renderer.atlas.metrics.width))
        XCTAssertEqual(frame.glyphs.first { $0.cellX == 0 }?.r, 20, "the character reads through the cursor")
    }

    /// A snapshot taken during a hold restores mode 2026 without a callback;
    /// the client starts held, on the frame it decoded.
    func testAnAttachInsideAHoldStartsHeld() throws {
        var raw: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &raw, 40, 10), GHOSTTY_SUCCESS)
        let source = try XCTUnwrap(raw)
        defer { ghostty_terminal_free(source) }
        let bytes = Array("AB\u{1b}[?2026hCD".utf8)
        ghostty_terminal_vt_write(source, bytes, bytes.count)
        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertEqual(ghostty_snapshot_encode_alloc(source, nil, &encoded, &length), GHOSTTY_SUCCESS)
        let pointer = try XCTUnwrap(encoded)
        defer { ghostty_free(nil, pointer, length) }
        let terminal = try TermiodStreamTerminal(nativeSnapshot: Data(bytes: pointer, count: length))
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        terminal.write(Data("EF".utf8))
        XCTAssertEqual(try builtFrame(terminal, builder, renderer.atlas).glyphs.count, 4,
                       "held: the decoded screen, not the redraw after it")
        terminal.write(Data("\u{1b}[?2026l".utf8))
        XCTAssertEqual(try builtFrame(terminal, builder, renderer.atlas).glyphs.count, 6)
    }

    /// The column a wrapped wide character left empty keeps its background;
    /// a palette underline color is the palette's; a blinking cursor is drawn
    /// only in the on half of its blink. The wrapped 中 puts `line` on row 2.
    func testSpacersUnderlinesAndBlink() throws {
        let terminal = try terminal()
        try terminal.setTheme(colors())
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        terminal.write(Data("\u{1b}[41m\(String(repeating: "a", count: 39))中\u{1b}[0m\r\n".utf8))
        terminal.write(Data("\u{1b}[4;58;5;4mline\u{1b}[0m".utf8))
        let frame = try builtFrame(terminal, builder, renderer.atlas)
        XCTAssertNotNil(frame.rectangles.first { $0.cellX == 39 && $0.cellY == 0 && $0.r == 220 },
                        "the empty last column is painted red")
        XCTAssertFalse(frame.glyphs.contains { $0.cellX == 39 && $0.cellY == 0 })
        XCTAssertNotNil(frame.rectangles.first { $0.cellY == 2 && $0.overText && $0.b == 220 },
                        "the underline is palette 4")

        terminal.write(Data("\u{1b}[1 q".utf8))
        let state = { (on: Bool) -> [TermiodStreamRectangle] in
            _ = try? terminal.withFrame { state, _ in try builder.build(from: state, atlas: renderer.atlas, focused: true, blinkOn: on) }
            var rectangles: [TermiodStreamRectangle] = []
            var glyphs: [TermiodStreamGlyph] = []
            builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
            return rectangles.filter { $0.cellY == 2 && $0.cellX == 4 && $0.r == 230 && !$0.overText }
        }
        XCTAssertEqual(state(true).count, 1, "blink on: the block is drawn")
        XCTAssertEqual(state(false).count, 0, "blink off: it is not")
    }

    private func blinking(_ terminal: TermiodStreamTerminal) throws -> Bool {
        try terminal.withFrame { state, _ in
            var blinking = false
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking)
            return blinking
        }
    }

    /// The Blink setting is a default: a program that turned blinking off
    /// keeps it off when the theme is applied again.
    func testReapplyingTheThemeKeepsTheProgramsBlinkMode() throws {
        let terminal = try terminal()
        var theme = colors()
        theme.cursorBlink = true
        try terminal.setTheme(theme)
        XCTAssertTrue(try blinking(terminal), "the setting blinks a cursor nobody styled")
        terminal.write(Data("\u{1b}[?12l".utf8))
        XCTAssertFalse(try blinking(terminal))
        theme.palette[1] = GhosttyColorRgb(r: 1, g: 2, b: 3)
        try terminal.setTheme(theme)
        XCTAssertFalse(try blinking(terminal), "a theme change leaves the program's choice alone")
    }

    /// Block elements fill their cells, so a column of them is one solid bar.
    func testBlockElementsMeetAcrossRows() throws {
        let terminal = try terminal()
        try terminal.setTheme(colors())
        terminal.write(Data("\u{2588}\r\n\u{2588}\r\n\u{1b}[?25l".utf8))
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let metrics = renderer.atlas.metrics
        let image = try renderer.image(of: terminal, width: 200, height: 200)
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        let x = Int(appearance.paddingX * 2) + metrics.width / 2
        for y in Int(appearance.paddingY * 2)..<(Int(appearance.paddingY * 2) + 2 * metrics.height) {
            XCTAssertEqual(Int(pixels[y * image.bytesPerRow + x * 4 + 2]), 230, accuracy: 30, "gap at y=\(y)")
        }
    }

    /// The character under a block cursor takes the theme's cursor-text color,
    /// and a light theme's contrast floor rescues text the theme would lose.
    func testCursorTextAndTheContrastFloor() throws {
        let terminal = try terminal()
        var theme = colors()
        theme.background = GhosttyColorRgb(r: 255, g: 255, b: 255)
        theme.cursorText = GhosttyColorRgb(r: 9, g: 99, b: 199)
        theme.minimumContrast = 1.5
        try terminal.setTheme(theme)
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        terminal.write(Data("\u{1b}[38;2;250;250;250mwhite\u{1b}[0mX\u{1b}[D".utf8))
        let frame = try terminal.withFrame { state, theme in
            try builder.build(from: state, atlas: renderer.atlas, focused: true, theme: theme)
        }
        XCTAssertTrue(frame)
        var rectangles: [TermiodStreamRectangle] = []
        var glyphs: [TermiodStreamGlyph] = []
        builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
        let white = try XCTUnwrap(glyphs.first { $0.cellX == 0 })
        XCTAssertEqual([white.r, white.g, white.b], [0, 0, 0], "near-white on white is drawn black")
        let underCursor = try XCTUnwrap(glyphs.first { $0.cellX == 5 })
        XCTAssertEqual([underCursor.r, underCursor.g, underCursor.b], [9, 99, 199])
    }

    private func decoded(_ text: String) throws -> TermiodStreamTerminal {
        var raw: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &raw, 40, 10), GHOSTTY_SUCCESS)
        let source = try XCTUnwrap(raw)
        defer { ghostty_terminal_free(source) }
        let bytes = Array(text.utf8)
        ghostty_terminal_vt_write(source, bytes, bytes.count)
        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertEqual(ghostty_snapshot_encode_alloc(source, nil, &encoded, &length), GHOSTTY_SUCCESS)
        let pointer = try XCTUnwrap(encoded)
        defer { ghostty_free(nil, pointer, length) }
        return try TermiodStreamTerminal(nativeSnapshot: Data(bytes: pointer, count: length))
    }

    /// A program's own blink survives the first theme, and the Blink setting
    /// is still the default a later `CSI 0 q` returns to.
    func testAProgramsBlinkSurvivesAttachAndResetsToTheSetting() throws {
        let terminal = try decoded("\u{1b}[1 q")
        var theme = colors()
        theme.cursorBlink = true
        try terminal.setTheme(theme)
        XCTAssertTrue(try blinking(terminal), "the program's blinking block")
        terminal.write(Data("\u{1b}[0 q".utf8))
        XCTAssertTrue(try blinking(terminal), "reset to the default, which the setting says blinks")
    }

    /// Box and block characters keep the color a program chose, contrast floor
    /// or not; emoji are scaled into their row.
    func testGraphicsKeepTheirColorAndEmojiFitTheirRow() throws {
        let terminal = try terminal()
        var theme = colors()
        theme.background = GhosttyColorRgb(r: 255, g: 255, b: 255)
        theme.minimumContrast = 1.5
        try terminal.setTheme(theme)
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        terminal.write(Data("\u{1b}[38;2;250;250;250m\u{2588}".utf8))
        let frame = try builtFrame(terminal, builder, renderer.atlas)
        XCTAssertEqual(frame.glyphs.first?.r, 250, "the block keeps its color")

        let courier = TermiodStreamRenderer.Appearance(
            fontFamily: "Courier", fallbackFamilies: [], fontSize: 10, paddingX: 8, paddingY: 2, backgroundOpacity: 1)
        let atlas = try TermiodGlyphAtlas(device: renderer.device, appearance: courier, scale: 2)
        let emoji = try XCTUnwrap(atlas.slot(graphemes: [0x1F600], bold: false, italic: false, cells: 2))
        XCTAssertTrue(emoji.colored)
        XCTAssertLessThanOrEqual(Int(emoji.offset.y) + Int(emoji.size.y), atlas.metrics.height, "stays in its row")
        XCTAssertGreaterThanOrEqual(emoji.offset.y, 0)
        let narrow = try XCTUnwrap(atlas.slot(graphemes: [0x1F600], bold: false, italic: false, cells: 1))
        XCTAssertEqual(Int(narrow.size.x), atlas.metrics.width, "one cell: a sprite of its own, one cell wide")
    }
}
