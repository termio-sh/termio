import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Preview side of `FileEditorView` for Markdown: renders the file as a themed,
/// document-grade reading view (the Apple-docs / iA-Writer register — narrow measure,
/// generous rhythm), reusing the same `MarkdownHTML` parser the session trace uses but
/// with its own reader stylesheet rather than the trace's dense dashboard skin.
///
/// It renders the *live* editor buffer (`source`), not the file on disk, so flipping over
/// from Edit shows unsaved keystrokes immediately. The page's colors come from termio's
/// active chrome theme via `TraceTheme`, so Preview always matches the app.
struct MarkdownReaderView: View {
    let source: String
    let fileURL: URL
    @ObservedObject var settings: AppSettings
    let colorScheme: ColorScheme

    var body: some View {
        let theme = TraceTheme.resolveReader(settings: settings, colorScheme: colorScheme)
        // Relative image paths (`![](./shot.png)`) resolve against the file's own folder.
        MarkdownReaderWebView(
            html: MarkdownReaderRenderer.document(source, theme: theme, fontFamily: settings.fontFamily),
            baseURL: fileURL.deletingLastPathComponent(),
            background: settings.terminalBackgroundColor
        )
    }
}

/// A `WKWebView` host that renders the reader HTML, preserves scroll position across
/// re-renders (theme flip, live edit), and opens web links in the browser rather than
/// navigating the page away. Its own background is cleared so the terminal background
/// shows through until the themed page paints (no white flash).
private struct MarkdownReaderWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    let background: NSColor

    /// `loadHTMLString` pages get no filesystem access in the WebContent process, so a
    /// `file://` image would silently 404 (same reason the reader fonts are embedded as
    /// base64). Relative image paths instead resolve against this custom scheme, whose
    /// handler serves the bytes from disk.
    static let fileScheme = "termio-md"

    /// The document's folder re-rooted onto the custom scheme, so `![](./shot.png)` and
    /// sanitized `<img src="docs/x.png">` resolve to URLs our scheme handler serves.
    private var schemeBaseURL: URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.scheme = Self.fileScheme
        return comps?.url ?? baseURL
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: Self.fileScheme)
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: schemeBaseURL)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        // Restore the reader's scroll offset after the new content lays out, so re-rendering
        // (e.g. a theme change, or editing then flipping back) doesn't jump to the top.
        context.coordinator.restoreScroll = true
        view.evaluateJavaScript("window.scrollY") { value, _ in
            context.coordinator.savedScrollY = (value as? CGFloat) ?? 0
            view.loadHTMLString(html, baseURL: schemeBaseURL)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(lastHTML: html) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String
        var savedScrollY: CGFloat = 0
        var restoreScroll = false
        init(lastHTML: String) { self.lastHTML = lastHTML }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard restoreScroll else { return }
            restoreScroll = false
            webView.evaluateJavaScript("window.scrollTo(0, \(savedScrollY))")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                // In-page anchors scroll within the doc; external links open in the
                // browser; relative links (resolved onto the reader's scheme) open the
                // target file with its default app.
                if url.fragment != nil, url.path == webView.url?.path {
                    decisionHandler(.allow)
                } else if url.scheme == MarkdownReaderWebView.fileScheme {
                    NSWorkspace.shared.open(URL(fileURLWithPath: url.path))
                    decisionHandler(.cancel)
                } else {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                }
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// Serves local files to the reader page over the custom scheme. Only ever reached for
/// URLs the sanitized document generated (relative image/link paths); the page runs no
/// script (the sanitizer strips it), so a hostile path can at worst paint pixels — it
/// has no way to read them back or send them anywhere.
private final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let data = FileManager.default.contents(atPath: url.path)
        else {
            urlSchemeTask.didFailWithError(CocoaError(.fileReadNoSuchFile))
            return
        }
        let ext = (url.path as NSString).pathExtension
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        urlSchemeTask.didReceive(URLResponse(
            url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
