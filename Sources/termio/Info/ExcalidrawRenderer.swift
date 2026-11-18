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
/// harness has no scheme handler and loads nothing but a string, its content policy
/// allows no network, embeddable elements (which carry third-party URLs) are drawn as
/// placeholders rather than live frames, and the SVG is checked again on the way out so
/// a drawing can at worst paint pixels.
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

    /// What a file's bytes turned out to hold. An empty drawing is a normal state — the
    /// file a New File command leaves behind, or one whose elements were all deleted — and
    /// is deliberately not the same answer as a file that holds no scene at all, which is
    /// `nil` and shows as source.
    enum Drawing: Hashable {
        case drawing(String)
        case empty
    }

    private var cache: [Key: Drawing] = [:]
    private var cachedBytes = 0
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
    func cachedDrawing(for data: Data, theme: Theme) -> Drawing? {
        cache[Key(digest: Self.digest(data), theme: theme)]
    }

    /// Renders the drawing, or returns `nil` if these bytes hold no scene at all. A caller
    /// that gets `nil` shows the file as source, which is the readable failure.
    func drawing(for data: Data, theme: Theme) async -> Drawing? {
        let key = Key(digest: Self.digest(data), theme: theme)
        if let drawing = cache[key] { return drawing }
        guard let drawing = await render(data, theme: theme) else { return nil }
        // A drawing's SVG is tens of KB and a session opens a handful; the caps are a
        // runaway guard, not a working-set limit. The byte cap is there because an SVG
        // carries every embedded image, and each edit of such a scene is a new entry.
        let bytes = Self.size(of: drawing)
        guard bytes <= Self.largestCachedDrawing else { return drawing }
        if cache.count >= 32 || cachedBytes + bytes > Self.cacheBudget {
            cache.removeAll(keepingCapacity: true)
            cachedBytes = 0
        }
        cache[key] = drawing
        cachedBytes += bytes
        return drawing
    }

    private static let largestCachedDrawing = 4 << 20
    private static let cacheBudget = 16 << 20

    private static func size(of drawing: Drawing) -> Int {
        if case .drawing(let svg) = drawing { return svg.utf8.count }
        return 0
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func render(_ data: Data, theme: Theme) async -> Drawing? {
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
            guard let payload = result as? [String: Any] else { return nil }
            if payload["empty"] as? Bool == true { return .empty }
            guard let svg = payload["svg"] as? String, !svg.isEmpty else { return nil }
            guard Self.isInert(svg) else {
                Log.markdown.error("excalidraw: dropped a drawing whose SVG carried script")
                return nil
            }
            return .drawing(svg)
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
        <meta http-equiv="Content-Security-Policy" content="\(Self.harnessPolicy)">
        <style>body { margin: 0; background: transparent; }</style>
        <script>window.EXCALIDRAW_ASSET_PATH = "termio-no-assets:///";</script>
        <script>\(engine)</script>
        </head><body></body></html>
        """
    }

    /// The engine runs inline script and measures images, and a scene can name any URL as
    /// an image. Nothing here leaves the machine: only `data:` and `blob:` load.
    private static let harnessPolicy =
        "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; "
        + "img-src data: blob:; font-src data:; connect-src data: blob:; worker-src blob:"

    /// Last guard before the SVG is inlined into the preview page. Excalidraw's exporter
    /// should make every one of these impossible; this is the check that doesn't depend
    /// on it.
    ///
    /// It reads the markup as a tree, because a label is free text: "use javascript: with
    /// care" in a text element is a drawing, and the same words in an attribute are not.
    nonisolated static func isInert(_ svg: String) -> Bool {
        guard let document = try? XMLDocument(xmlString: svg, options: [.nodeLoadExternalEntitiesNever]),
              let root = document.rootElement()
        else {
            // Markup that is not well-formed XML gets the blunt scan, which errs toward
            // refusing a drawing.
            return isInertText(svg)
        }
        return isInert(root)
    }

    private nonisolated static func isInert(_ element: XMLElement) -> Bool {
        let name = (element.localName ?? element.name ?? "").lowercased()
        if ["script", "foreignobject", "iframe", "object", "embed"].contains(name) { return false }
        for attribute in element.attributes ?? [] {
            let key = (attribute.localName ?? attribute.name ?? "").lowercased()
            let value = (attribute.stringValue ?? "").lowercased()
            if key.hasPrefix("on") { return false }
            if value.filter({ !$0.isWhitespace && !$0.isNewline }).hasPrefix("javascript:") { return false }
            if key == "style", loadsRemoteStyle(value) { return false }
        }
        if name == "style", loadsRemoteStyle((element.stringValue ?? "").lowercased()) { return false }
        for case let child as XMLElement in element.children ?? [] where !isInert(child) {
            return false
        }
        return true
    }

    private nonisolated static func loadsRemoteStyle(_ css: String) -> Bool {
        ["@import", "url(http", "url('http", "url(\"http", "url(//"].contains { css.contains($0) }
    }

    private nonisolated static func isInertText(_ svg: String) -> Bool {
        let lowered = svg.lowercased()
        for marker in ["<script", "javascript:", "<foreignobject", "<iframe", "<object", "<embed"]
        where lowered.contains(marker) {
            return false
        }
        return !loadsRemoteStyle(lowered) && lowered.firstMatch(of: #/\son[a-z]+\s*=/#) == nil
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

    /// A WebContent process that died takes the loaded engine with it. Forgetting the
    /// load makes the next render start a fresh one instead of calling into a dead page.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            Log.markdown.error("excalidraw: the harness process ended; it reloads on the next render")
            self.finishLoading(loaded: false)
        }
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
