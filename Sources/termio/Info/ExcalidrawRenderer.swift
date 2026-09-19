import AppKit
import CryptoKit
import WebKit

/// Renders an Excalidraw drawing to SVG, off to the side, so the pages that show the
/// result never run Excalidraw themselves.
///
/// The same shape as `MermaidRenderer`, and for the same reason: Excalidraw lays a
/// drawing out against a DOM, so it can't run in a `JSContext`. It gets one offscreen
/// `WKWebView`, loaded once with the bundled engine; callers hand it a file's bytes and
/// get back finished SVG, which the preview inlines as static markup.
///
/// What the bundled engine does *not* include is the editor. termio previews drawings and
/// never writes them, so only `exportToSvg` and `loadFromBlob` are bundled — see
/// `Resources/ExcalidrawFonts/Excalidraw-README.md` for how that build is produced.
///
/// The security argument is `MermaidRenderer`'s: a drawing is somebody else's file, the
/// harness has no scheme handler and loads nothing but a string, embeddable elements
/// (which carry third-party URLs) are drawn as placeholders rather than live frames, and
/// the SVG is checked again on the way out so a drawing can at worst paint pixels.
@MainActor
final class ExcalidrawRenderer: NSObject {
    static let shared = ExcalidrawRenderer()

    /// How a drawing is rendered for the current appearance. Part of the cache key, so
    /// flipping the app theme re-renders rather than showing yesterday's picture.
    ///
    /// Only light-or-dark: a drawing's strokes and fills are authored colors that termio
    /// has no business restyling, and the canvas behind them is the preview page's, not
    /// the SVG's. Dark mode is Excalidraw's own filter over the finished picture.
    struct Theme: Hashable {
        let isDark: Bool

        init(_ theme: DocumentTheme) {
            isDark = theme.isDark
        }
    }

    private struct Key: Hashable {
        /// The file's bytes, hashed: a drawing runs to hundreds of KB and there is no
        /// reason to hold a second copy of every one ever previewed.
        let digest: String
        let theme: Theme
    }

    private var cache: [Key: String] = [:]
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loadContinuations: [CheckedContinuation<Void, Never>] = []
    private var isLoading = false
    private var isLoaded = false

    /// Whether this file is one termio previews as a drawing. `.excalidraw` is the scene
    /// itself; the doubled extensions are Excalidraw's own convention for an image with the
    /// scene embedded in it, and those decode back to the scene rather than to flat art.
    /// Pure, and deliberately not main-actor bound: matching a file name is string work
    /// any thread that has a URL can do.
    nonisolated static func isDrawing(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        for suffix in [".excalidraw", ".excalidraw.json", ".excalidraw.svg", ".excalidraw.png"]
        where name.hasSuffix(suffix) {
            return true
        }
        return false
    }

    // MARK: - Rendering

    /// The drawing for these bytes if it has already been rendered, for the synchronous
    /// first pass — reopening a file or flipping the theme back shows the picture
    /// immediately instead of flashing a placeholder.
    func cachedDrawing(for data: Data, theme: Theme) -> String? {
        cache[Key(digest: Self.digest(data), theme: theme)]
    }

    /// Renders the drawing, or returns `nil` if these bytes hold no scene. A caller that
    /// gets `nil` shows the file as source, which is the readable failure.
    func drawing(for data: Data, theme: Theme) async -> String? {
        let key = Key(digest: Self.digest(data), theme: theme)
        if let svg = cache[key] { return svg }
        guard let svg = await render(data, theme: theme) else { return nil }
        // A drawing's SVG is tens of KB and a session opens a handful; the cap is a
        // runaway guard, not a working-set limit.
        if cache.count >= 32 { cache.removeAll(keepingCapacity: true) }
        cache[key] = svg
        return svg
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func render(_ data: Data, theme: Theme) async -> String? {
        guard let webView = await harness() else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.termioRenderExcalidraw(scene, options);",
                arguments: [
                    // Base64 rather than a byte array: a drawing is routinely hundreds of
                    // KB, and bridging that as a JS array of numbers costs more than the
                    // render does.
                    "scene": data.base64EncodedString(),
                    "options": ["dark": theme.isDark],
                ],
                contentWorld: .page)
            guard let svg = result as? String, !svg.isEmpty else { return nil }
            guard isInert(svg) else {
                Log.markdown.error("excalidraw: dropped a drawing whose SVG carried script")
                return nil
            }
            return svg
        } catch {
            // A file with no scene in it lands here; the caller keeps showing source.
            Log.markdown.info("excalidraw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - The offscreen engine

    /// The engine is themeless — the canvas color is an argument to each render, not a
    /// property of the page — so unlike mermaid's harness this one loads exactly once.
    private func harness() async -> WKWebView? {
        if let webView, isLoaded, !isLoading { return webView }
        if isLoading {
            await withCheckedContinuation { loadContinuations.append($0) }
            return isLoaded ? webView : nil
        }
        guard let engine = Bundle.termioResources.url(
                  forResource: "excalidraw-render", withExtension: "js"),
              let script = try? String(contentsOf: engine, encoding: .utf8)
        else {
            Log.markdown.error("excalidraw: excalidraw-render.js is missing from the bundle")
            return nil
        }

        let webView = self.webView ?? makeWebView()
        self.webView = webView
        isLoading = true
        webView.loadHTMLString(harnessHTML(engine: script), baseURL: nil)
        await withCheckedContinuation { loadContinuations.append($0) }
        return isLoaded ? webView : nil
    }

    /// The view lives in a borderless window that is deliberately never ordered in, for
    /// the reason spelled out in `MermaidRenderer.makeWebView`: WebKit does not lay out a
    /// view that belongs to no window, and text in an unmeasured document collapses —
    /// while ordering the window front leaves a white square in Mission Control (#348).
    private func makeWebView() -> WKWebView {
        let frame = NSRect(x: 0, y: 0, width: 1400, height: 1400)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        self.window = window
        return webView
    }

    private func harnessHTML(engine: String) -> String {
        // `EXCALIDRAW_ASSET_PATH` points nowhere on purpose. The engine is built with
        // `skipInliningFonts`, so nothing here fetches a face — the preview page declares
        // them itself (see `ExcalidrawReaderRenderer`) — and a path that resolves to no
        // host makes that a guarantee rather than an assumption.
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>body { margin: 0; background: transparent; }</style>
        <script>window.EXCALIDRAW_ASSET_PATH = "termio-no-assets:///";</script>
        <script>\(engine)</script>
        </head><body></body></html>
        """
    }

    /// Last guard before the SVG is inlined into a page that isn't sandboxed — the same
    /// check `MermaidRenderer` applies, for the same reason. Excalidraw's exporter should
    /// make every one of these impossible; this is the check that doesn't depend on it.
    private func isInert(_ svg: String) -> Bool {
        let lowered = svg.lowercased()
        for marker in ["<script", "javascript:", "<foreignobject", "@import", "url(http", "url('http", "url(\"http"]
        where lowered.contains(marker) {
            return false
        }
        return lowered.firstMatch(of: #/\son[a-z]+\s*=/#) == nil
    }

    private func finishLoading(loaded: Bool) {
        isLoading = false
        isLoaded = loaded
        let waiting = loadContinuations
        loadContinuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

extension ExcalidrawRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoading(loaded: true) }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        Task { @MainActor in
            Log.markdown.error("excalidraw: harness failed to load: \(error.localizedDescription, privacy: .public)")
            self.finishLoading(loaded: false)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            Log.markdown.error("excalidraw: harness failed to load: \(error.localizedDescription, privacy: .public)")
            self.finishLoading(loaded: false)
        }
    }
}
