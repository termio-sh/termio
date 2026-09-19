import AppKit
import XCTest
@testable import termio

/// Which files preview as a drawing, and what the preview page is built from.
///
/// The detection is suffix work rather than `pathExtension`, because three of the four
/// shapes Excalidraw writes are doubled extensions (`.excalidraw.svg`) whose *last*
/// component names a format termio already previews as flat art.
final class ExcalidrawFileTests: XCTestCase {
    private func isDrawing(_ name: String) -> Bool {
        ExcalidrawRenderer.isDrawing(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testRecognizesEveryContainerExcalidrawWrites() {
        XCTAssertTrue(isDrawing("flow.excalidraw"))
        XCTAssertTrue(isDrawing("flow.excalidraw.json"))
        XCTAssertTrue(isDrawing("flow.excalidraw.svg"))
        XCTAssertTrue(isDrawing("flow.excalidraw.png"))
    }

    /// The doubled extensions are the whole reason this isn't an extension check: a plain
    /// `.svg` or `.png` is flat art and must keep going to the image preview.
    func testLeavesPlainImagesToTheImagePreview() {
        XCTAssertFalse(isDrawing("diagram.svg"))
        XCTAssertFalse(isDrawing("shot.png"))
        XCTAssertFalse(isDrawing("notes.json"))
        XCTAssertFalse(isDrawing("README.md"))
    }

    /// The suffix is matched case-insensitively, and only as a suffix — a file merely
    /// mentioning the word is not a drawing.
    func testMatchesOnlyTheTrailingSuffix() {
        XCTAssertTrue(isDrawing("Flow.Excalidraw"))
        XCTAssertTrue(isDrawing("FLOW.EXCALIDRAW.PNG"))
        XCTAssertFalse(isDrawing("excalidraw"))
        XCTAssertFalse(isDrawing("excalidraw-notes.txt"))
        XCTAssertFalse(isDrawing("flow.excalidraw.bak"))
    }

    /// A drawing preview is a single self-contained page: the SVG inline, the canvas from
    /// the theme, and the faces embedded rather than fetched — `loadHTMLString` gives the
    /// WebContent process no read access to the bundle, so a `file://` font URL would
    /// silently fail and every drawing would render in a system serif.
    func testPageEmbedsTheDrawingAndItsFonts() {
        let theme = DocumentTheme.reader(dark: false)
        let page = ExcalidrawReaderRenderer.document(
            svg: "<svg id=\"drawn\"></svg>", theme: theme)
        XCTAssertTrue(page.contains("<svg id=\"drawn\"></svg>"))
        XCTAssertTrue(page.contains(theme.background))
        XCTAssertTrue(page.contains("@font-face"))
        XCTAssertTrue(page.contains("src: url(data:font/woff2;base64,"))
        XCTAssertFalse(page.contains("file://"))
    }

    /// Every bundled face carries the `unicode-range` Excalidraw subset it with, except the
    /// three that ship as one whole font. Without the range the browser picks the first
    /// face of a family and drops every glyph outside that subset to a system serif.
    func testBundledFacesKeepTheirSubsetRanges() {
        let page = ExcalidrawReaderRenderer.document(svg: "", theme: .reader(dark: false))
        let faces = page.components(separatedBy: "@font-face").dropFirst()
        XCTAssertGreaterThanOrEqual(faces.count, 21)
        let whole = ["Cascadia", "Liberation Sans", "Virgil"]
        for face in faces {
            let rule = face.prefix(while: { $0 != "}" })
            guard !whole.contains(where: { rule.contains("\"\($0)\"") }) else { continue }
            XCTAssertTrue(rule.contains("unicode-range:"), "face without a range: \(rule.prefix(120))")
        }
    }

    /// A drawing never routes to Quick Look, even when it ships as a `.png` or `.svg`:
    /// that would show the exported picture instead of the drawing termio renders at the
    /// app's theme. Plain images are untouched.
    func testDrawingsBypassQuickLook() {
        XCTAssertFalse(FileActivation.isPreviewable(URL(fileURLWithPath: "/tmp/f.excalidraw.png")))
        XCTAssertFalse(FileActivation.isPreviewable(URL(fileURLWithPath: "/tmp/f.excalidraw.svg")))
        XCTAssertTrue(FileActivation.isPreviewable(URL(fileURLWithPath: "/tmp/shot.png")))
        XCTAssertTrue(FileActivation.isPreviewable(URL(fileURLWithPath: "/tmp/art.svg")))
    }

    /// In the Changes pane a drawing opens as the picture, not as a diff: the diff is a
    /// wall of scene JSON, or — for the PNG container — not text at all.
    func testDrawingsPreviewInsteadOfDiffing() {
        XCTAssertTrue(FileActivation.previewsRatherThanDiff(
            URL(fileURLWithPath: "/tmp/f.excalidraw")))
        XCTAssertTrue(FileActivation.previewsRatherThanDiff(
            URL(fileURLWithPath: "/tmp/f.excalidraw.png")))
        // HTML keeps its meaningful text diff, as before.
        XCTAssertFalse(FileActivation.previewsRatherThanDiff(
            URL(fileURLWithPath: "/tmp/page.html")))
    }

    /// A file that holds no scene gets a page that says so, not an empty canvas that reads
    /// as a drawing still loading.
    func testFailurePageSaysThereIsNoDrawing() {
        let page = ExcalidrawReaderRenderer.failureDocument(theme: .reader(dark: true))
        XCTAssertTrue(page.contains("No drawing in this file."))
    }
}

/// The renderer itself, driven the way the preview drives it: real bytes in, finished SVG
/// out, through the offscreen WebKit harness and the bundled engine.
///
/// It needs a WebKit content process, so it is skipped where one can't be started (CI
/// without a window server). Where it does run it is the check that matters — that the
/// engine in the bundle still exposes the contract `ExcalidrawRenderer` calls.
final class ExcalidrawRenderIntegrationTests: XCTestCase {
    /// WebKit needs an `NSApplication` and a window-server session. `swift test` runs as a
    /// plain tool, so the app object is created here rather than assumed; a headless CI
    /// runner has no session and skips.
    private static let canRunWebKit: Bool = {
        guard NSRunningApplication.current.activate(options: []) || true else { return false }
        _ = NSApplication.shared
        return CGSessionCopyCurrentDictionary() != nil
    }()

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    @MainActor
    func testRendersASceneToInertSvg() async throws {
        try XCTSkipUnless(Self.canRunWebKit, "needs a window server for the WebKit harness")
        let data = try fixture("drawing.excalidraw")
        let theme = ExcalidrawRenderer.Theme(.reader(dark: false))
        let rendered = await ExcalidrawRenderer.shared.drawing(for: data, theme: theme)
        let svg = try XCTUnwrap(rendered, "the bundled engine did not return a drawing")

        XCTAssertTrue(svg.hasPrefix("<svg"))
        XCTAssertTrue(svg.contains("termio preview"), "the scene's text is missing")
        // No background rect: the preview page is the canvas, so a drawing never paints
        // its own slab (which dark mode's filter would invert into a light one).
        XCTAssertFalse(svg.contains("<rect x=\"0\" y=\"0\""))
        // Fonts are declared by the page, never inlined per drawing.
        XCTAssertFalse(svg.contains("data:font"))
        // Whatever the engine produced still has to pass the inertness gate.
        XCTAssertFalse(svg.lowercased().contains("<script"))
        XCTAssertFalse(svg.lowercased().contains("<foreignobject"))

        // Second call for the same bytes and theme comes from the cache.
        XCTAssertEqual(ExcalidrawRenderer.shared.cachedDrawing(for: data, theme: theme), svg)
    }

    /// The distinctive container: a PNG with the scene in a tEXt chunk. It decodes to the
    /// same drawing an `.excalidraw` would, not to flat art.
    ///
    /// The deadline is the point of the test. The engine picks a decoder by sniffing the
    /// bytes, because offering a 145KB PNG to the JSON and SVG decoders instead takes
    /// ~40 seconds to be rejected — a stall the preview would wear on every open.
    @MainActor
    func testDecodesASceneEmbeddedInAPng() async throws {
        try XCTSkipUnless(Self.canRunWebKit, "needs a window server for the WebKit harness")
        let data = try fixture("drawing-embedded.excalidraw.png")
        let started = Date()
        let rendered = await ExcalidrawRenderer.shared.drawing(
            for: data, theme: ExcalidrawRenderer.Theme(.reader(dark: false)))
        let svg = try XCTUnwrap(rendered, "the scene embedded in the PNG did not decode")
        XCTAssertTrue(svg.hasPrefix("<svg"))
        XCTAssertTrue(svg.contains("<text"), "the scene's text is missing")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "decoding fell back through the other containers")
    }

    @MainActor
    func testFileWithNoSceneRendersNothing() async throws {
        try XCTSkipUnless(Self.canRunWebKit, "needs a window server for the WebKit harness")
        let data = Data("not a drawing at all".utf8)
        let drawing = await ExcalidrawRenderer.shared.drawing(
            for: data, theme: ExcalidrawRenderer.Theme(.reader(dark: false)))
        XCTAssertNil(drawing)
    }
}
