import AppKit
import WebKit

/// Renders ```` ```mermaid ```` fences to SVG, off to the side, so the pages that show the
/// result never run mermaid themselves.
///
/// Mermaid needs a DOM — it measures label text with `getBBox` before it can lay a diagram
/// out — so unlike highlight.js and KaTeX it can't run in a `JSContext`. It gets one
/// offscreen `WKWebView` instead, loaded once with the bundled engine. Callers hand it the
/// diagram sources found in a document and get back finished SVG, which the Markdown
/// renderer inlines as static markup.
///
/// That indirection is the point:
///
/// - The reader, the trace and the Issues pane keep their no-script-from-content rule.
///   The reader page in particular can read local files through its `termio-md` scheme
///   handler, so script running *there* would be a real escalation; script running in this
///   harness, which has no scheme handler and loads nothing but a string, is not.
/// - A transcript is untrusted agent output. Mermaid runs at its default `strict` security
///   level (labels sanitized, HTML labels off), and the SVG is checked again on the way
///   out, so a diagram can at worst paint pixels.
/// - Nothing but the Mac ever needs the engine. The companion's own pages are still built
///   on a background queue and so don't take this pass yet — the phone shows a diagram as
///   its source — but when they do, they ship a few KB of SVG rather than 3.5MB of mermaid.
@MainActor
final class MermaidRenderer: NSObject {
    static let shared = MermaidRenderer()

    /// The colors a diagram is drawn in. Part of the cache key, so flipping the app theme
    /// re-renders rather than showing yesterday's palette.
    struct Theme: Hashable {
        let background: String
        let panel: String
        let foreground: String
        let muted: String
        let line: String

        init(_ theme: TraceTheme) {
            background = theme.background
            panel = theme.panel
            foreground = theme.foreground
            muted = theme.secondary
            line = theme.isDark ? "rgba(255,255,255,0.22)" : "rgba(0,0,0,0.22)"
        }
    }

    private struct Key: Hashable {
        let source: String
        let theme: Theme
    }

    private var cache: [Key: String] = [:]
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loadedTheme: Theme?
    private var loadContinuations: [CheckedContinuation<Void, Never>] = []
    private var isLoading = false
    private var nextIdentifier = 0

    // MARK: - Finding and replacing diagram fences

    /// The mermaid fences in a page `MarkdownHTML` produced. Working on the built HTML
    /// rather than threading a parameter through every renderer is what lets the reader,
    /// the trace and the Issues pane share one mechanism: each builds its page exactly as
    /// before, then swaps the fences it finds.
    /// `nonisolated(unsafe)` because `Regex` isn't `Sendable`, though a compiled pattern
    /// is immutable and matching never touches the renderer's state.
    nonisolated(unsafe) private static let fence =
        #/<pre><code class="language-mermaid hljs">([\s\S]*?)<\/code><\/pre>/#

    /// Pure, and deliberately not main-actor bound: finding and swapping fences is string
    /// work any thread that built a page can do.
    nonisolated static func sources(in html: String) -> [String] {
        html.matches(of: fence).map { unescape(String($0.1)) }
    }

    /// Replaces each fence whose source has a diagram; fences without one are left as the
    /// readable code block they already are. Pure, so applying a stale set to a newly
    /// edited document can only ever substitute blocks that are still in it.
    nonisolated static func applying(_ diagrams: [String: String], to html: String) -> String {
        guard !diagrams.isEmpty else { return html }
        return html.replacing(fence) { match in
            guard let svg = diagrams[unescape(String(match.1))] else { return String(match.0) }
            return "<figure class=\"mermaid\">\(svg)</figure>"
        }
    }

    nonisolated private static func unescape(_ escaped: String) -> String {
        escaped.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Rendering

    /// Diagrams already rendered, for the synchronous first pass — reopening a file or
    /// flipping the theme back shows its diagrams immediately instead of flashing source.
    func cachedDiagrams(for sources: [String], theme: Theme) -> [String: String] {
        var diagrams: [String: String] = [:]
        for source in sources {
            if let svg = cache[Key(source: source, theme: theme)] { diagrams[source] = svg }
        }
        return diagrams
    }

    /// Renders whatever isn't cached and returns every diagram it has for these sources.
    /// A source that fails to render is simply absent, and the caller keeps showing it as
    /// a code block.
    func diagrams(for sources: [String], theme: Theme) async -> [String: String] {
        var diagrams: [String: String] = [:]
        for source in Set(sources) {
            let key = Key(source: source, theme: theme)
            if let svg = cache[key] {
                diagrams[source] = svg
                continue
            }
            guard let svg = await render(source, theme: theme) else { continue }
            // Diagrams are small and a document has a handful; the cap is a runaway guard,
            // not a working-set limit.
            if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
            cache[key] = svg
            diagrams[source] = svg
        }
        return diagrams
    }

    // MARK: - The offscreen engine

    private func render(_ source: String, theme: Theme) async -> String? {
        guard let webView = await harness(for: theme) else { return nil }
        nextIdentifier += 1
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await window.termioRenderMermaid(id, code);",
                arguments: ["id": "termio-mermaid-\(nextIdentifier)", "code": source],
                contentWorld: .page)
            guard let svg = result as? String, !svg.isEmpty else { return nil }
            guard isInert(svg) else {
                Log.markdown.error("mermaid: dropped a diagram whose SVG carried script")
                return nil
            }
            return svg
        } catch {
            // A syntax error in the diagram lands here; the fence stays as source, which
            // is the readable failure.
            Log.markdown.info("mermaid: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func harness(for theme: Theme) async -> WKWebView? {
        if let webView, loadedTheme == theme, !isLoading { return webView }
        if isLoading {
            await withCheckedContinuation { loadContinuations.append($0) }
            return loadedTheme == theme ? webView : nil
        }
        guard let engine = Bundle.termioResources.url(
                  forResource: "mermaid.min", withExtension: "js"),
              let script = try? String(contentsOf: engine, encoding: .utf8)
        else {
            Log.markdown.error("mermaid: mermaid.min.js is missing from the bundle")
            return nil
        }

        let webView = self.webView ?? makeWebView()
        self.webView = webView
        isLoading = true
        loadedTheme = theme
        webView.loadHTMLString(harnessHTML(engine: script, theme: theme), baseURL: nil)
        await withCheckedContinuation { loadContinuations.append($0) }
        return webView
    }

    /// The view lives in a borderless window parked far offscreen. WebKit does not lay out
    /// a view that belongs to no window, and without layout `getBBox` returns zeroes and
    /// every diagram collapses to a point.
    private func makeWebView() -> WKWebView {
        let frame = NSRect(x: 0, y: 0, width: 1400, height: 1400)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: frame.width, height: frame.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        self.window = window
        return webView
    }

    private func harnessHTML(engine: String, theme: Theme) -> String {
        // `startOnLoad: false` because nothing on this page is a diagram — the host asks
        // for one render at a time. `htmlLabels: false` keeps labels inside SVG <text>,
        // which is what makes the output safe to inline elsewhere.
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>body { margin: 0; background: transparent; }</style>
        <script>\(engine)</script>
        <script>
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: 'strict',
          htmlLabels: false,
          flowchart: { htmlLabels: false },
          theme: 'base',
          // The app's UI face, not the terminal font: WebKit doesn't expose SF Mono under
          // a CSS name, and mermaid's fallback for a name it can't resolve is a serif that
          // belongs to no part of this app.
          fontFamily: "-apple-system, system-ui, sans-serif",
          themeVariables: {
            background: \(jsString(theme.background)),
            mainBkg: \(jsString(theme.panel)),
            primaryColor: \(jsString(theme.panel)),
            primaryTextColor: \(jsString(theme.foreground)),
            primaryBorderColor: \(jsString(theme.line)),
            secondaryColor: \(jsString(theme.panel)),
            tertiaryColor: \(jsString(theme.background)),
            lineColor: \(jsString(theme.muted)),
            textColor: \(jsString(theme.foreground)),
            noteBkgColor: \(jsString(theme.panel)),
            noteTextColor: \(jsString(theme.foreground)),
            noteBorderColor: \(jsString(theme.line)),
            actorBkg: \(jsString(theme.panel)),
            actorBorder: \(jsString(theme.line)),
            actorTextColor: \(jsString(theme.foreground)),
            signalColor: \(jsString(theme.muted)),
            signalTextColor: \(jsString(theme.foreground)),
            labelBoxBkgColor: \(jsString(theme.panel)),
            labelTextColor: \(jsString(theme.foreground))
          }
        });
        window.termioRenderMermaid = async (id, code) => {
          const { svg } = await mermaid.render(id, code);
          return svg;
        };
        </script></head><body></body></html>
        """
    }

    private func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Last guard before the SVG is inlined into a page that isn't sandboxed: no script
    /// element, no event handler, no `javascript:` URL, no HTML label smuggled in through
    /// `<foreignObject>`, and no remote fetch from the `<style>` block mermaid embeds —
    /// a diagram in a transcript must not be able to phone home. Mermaid's strict mode
    /// should have made all of it impossible; this is the check that doesn't depend on it.
    private func isInert(_ svg: String) -> Bool {
        let lowered = svg.lowercased()
        for marker in ["<script", "javascript:", "<foreignobject", "@import", "url(http", "url('http", "url(\"http"]
        where lowered.contains(marker) {
            return false
        }
        return lowered.firstMatch(of: #/\son[a-z]+\s*=/#) == nil
    }
}

extension MermaidRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoading() }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        Task { @MainActor in
            Log.markdown.error("mermaid: harness failed to load — \(error.localizedDescription, privacy: .public)")
            self.finishLoading()
        }
    }

    private func finishLoading() {
        isLoading = false
        let waiting = loadContinuations
        loadContinuations = []
        for continuation in waiting { continuation.resume() }
    }
}
