import AppKit
import WebKit
import XCTest
@testable import termio

/// Which files open as a drawing.
///
/// The detection is suffix work rather than `pathExtension`, because three of the four
/// shapes Excalidraw writes are doubled extensions (`.excalidraw.svg`) whose *last*
/// component names a format termio otherwise previews as flat art.
final class ExcalidrawFileTests: XCTestCase {
    private func isDrawing(_ name: String) -> Bool {
        ExcalidrawCanvasView.isDrawing(URL(fileURLWithPath: "/tmp/\(name)"))
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

    /// A drawing never routes to Quick Look, even when it ships as a `.png` or `.svg`:
    /// that would show the exported picture instead of opening the canvas. Plain images
    /// are untouched.
    func testDrawingsBypassQuickLook() {
        XCTAssertFalse(FileActivation.isPreviewable(URL(fileURLWithPath: "/tmp/f.excalidraw.png")))
        XCTAssertFalse(FileActivation.isPreviewable(URL(fileURLWithPath: "/tmp/f.excalidraw.svg")))
        XCTAssertTrue(FileActivation.isPreviewable(URL(fileURLWithPath: "/tmp/shot.png")))
        XCTAssertTrue(FileActivation.isPreviewable(URL(fileURLWithPath: "/tmp/art.svg")))
    }

    /// In the Changes pane a drawing opens as the drawing, not as a diff: the diff is a
    /// wall of scene JSON, or — for the PNG container — not text at all.
    func testDrawingsOpenInsteadOfDiffing() {
        XCTAssertTrue(FileActivation.previewsRatherThanDiff(
            URL(fileURLWithPath: "/tmp/f.excalidraw")))
        XCTAssertTrue(FileActivation.previewsRatherThanDiff(
            URL(fileURLWithPath: "/tmp/f.excalidraw.png")))
        // HTML keeps its meaningful text diff, as before.
        XCTAssertFalse(FileActivation.previewsRatherThanDiff(
            URL(fileURLWithPath: "/tmp/page.html")))
    }
}

/// The canvas, driven the way `FileEditorView` drives it: the page it builds, loaded into
/// a real WebKit view, answering the calls the coordinator makes.
///
/// These need a WebKit content process, so they skip where one can't be started (CI with
/// no window server). Where they do run they are the checks that matter — that the engine
/// in the bundle still honours the contract, and that each container is recognised so an
/// edit writes back the shape the file arrived in.
final class ExcalidrawCanvasTests: XCTestCase {
    /// WebKit needs an `NSApplication` and a window-server session. `swift test` runs as a
    /// plain tool, so the app object is created here rather than assumed.
    private static let canRunWebKit: Bool = {
        _ = NSApplication.shared
        return CGSessionCopyCurrentDictionary() != nil
    }()

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    /// Mounts bytes in the real canvas page and returns what the engine answered.
    @MainActor
    private func mount(_ bytes: Data) async throws -> [String: Any] {
        let configuration = WKWebViewConfiguration()
        // The canvas posts to this handler as soon as it is up; without it the page throws.
        configuration.userContentController.add(
            SilentHandler(), name: ExcalidrawCanvasView.messageHandler)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900),
                             configuration: configuration)
        // WebKit lays out only inside a window — the lesson from the mermaid harness (#348);
        // the window is never ordered in.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        let waiter = LoadWaiter()
        view.navigationDelegate = waiter
        view.loadHTMLString(ExcalidrawCanvasView.pageForTesting(), baseURL: nil)
        await waiter.wait()
        defer { configuration.userContentController.removeAllScriptMessageHandlers() }
        let result = try await view.callAsyncJavaScript(
            "return await window.termioExcalidrawMount({ scene, dark: false, readOnly: false });",
            arguments: ["scene": bytes.base64EncodedString()], contentWorld: .page)
        return try XCTUnwrap(result as? [String: Any])
    }

    /// The page carries the engine and the editor stylesheet, points Excalidraw's asset
    /// path at termio's own scheme, and reaches nothing off the machine.
    func testPageIsSelfContained() {
        let page = ExcalidrawCanvasView.pageForTesting()
        XCTAssertTrue(page.contains("termioExcalidrawMount"), "the engine is missing")
        XCTAssertTrue(page.contains("EXCALIDRAW_ASSET_PATH = \"termio-excalidraw:///\""))
        XCTAssertTrue(page.contains("excalidraw"), "the editor stylesheet is missing")
        XCTAssertFalse(page.contains("https://cdn"), "the page must not reach off the machine")
    }

    /// A real scene mounts, and the engine reports which container the bytes turned out to
    /// be — that is what a save writes back, so the file keeps its shape.
    @MainActor
    func testMountsASceneAndNamesItsContainer() async throws {
        try XCTSkipUnless(Self.canRunWebKit, "needs a window server for WebKit")
        let payload = try await mount(try fixture("drawing.excalidraw"))
        XCTAssertEqual(payload["ok"] as? Bool, true, "\(payload["message"] ?? "")")
        XCTAssertEqual(payload["container"] as? String, "application/json")
    }

    /// The PNG container: a scene in a tEXt chunk mounts as the drawing, and is recognised
    /// as a PNG so editing it keeps producing a PNG.
    ///
    /// The deadline is part of the test. The engine picks a decoder by sniffing the bytes,
    /// because offering a 145KB PNG to the JSON and SVG decoders instead takes ~40 seconds
    /// to be rejected — a stall the canvas would wear on every open.
    @MainActor
    func testMountsASceneEmbeddedInAPng() async throws {
        try XCTSkipUnless(Self.canRunWebKit, "needs a window server for WebKit")
        let started = Date()
        let payload = try await mount(try fixture("drawing-embedded.excalidraw.png"))
        XCTAssertEqual(payload["ok"] as? Bool, true, "\(payload["message"] ?? "")")
        XCTAssertEqual(payload["container"] as? String, "image/png")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15,
                          "decoding fell back through the other containers")
    }

    /// An empty file is a new drawing, not a broken one — the file a New File command
    /// leaves behind. Every container decoder rejects empty bytes, so the engine answers
    /// before they see them and the canvas opens ready to draw on.
    @MainActor
    func testEmptyFileOpensAnEmptyCanvas() async throws {
        try XCTSkipUnless(Self.canRunWebKit, "needs a window server for WebKit")
        for (label, bytes) in [("zero bytes", Data()), ("whitespace only", Data("\n  \n".utf8))] {
            let payload = try await mount(bytes)
            XCTAssertEqual(payload["ok"] as? Bool, true, "\(label): \(payload["message"] ?? "")")
            XCTAssertEqual(payload["container"] as? String, "application/json",
                           "\(label) should start a JSON drawing")
        }
    }

    /// A file that holds no scene is refused with a reason, rather than opening as an empty
    /// canvas that would invite you to draw over whatever the file actually is.
    @MainActor
    func testFileWithNoSceneIsRefused() async throws {
        try XCTSkipUnless(Self.canRunWebKit, "needs a window server for WebKit")
        let payload = try await mount(Data("not a drawing at all".utf8))
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertNotNil(payload["message"] as? String)
    }
}

/// Swallows the canvas's messages; these tests exercise the engine, not the host bridge.
private final class SilentHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {}
}

private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}
