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
    /// "Add to Chat" in the reader's right-click menu — injected by `FileEditorView`
    /// alongside the editor's, so both faces of the overlay offer the same verb. The
    /// argument is the reader's selected text, `nil` when nothing is selected.
    var addToChat: ((String?) -> Void)? = nil
    var canAddToChat: (() -> Bool)? = nil

    /// Rendered mermaid diagrams, filled in by the task below. Drawing one needs a DOM and
    /// is therefore asynchronous, so the document renders immediately with its diagrams as
    /// source and re-renders once they arrive — the reader already restores scroll across
    /// a re-render, so the swap is where you were looking.
    @State private var diagrams: [String: String] = [:]

    var body: some View {
        let theme = TraceTheme.resolveReader(settings: settings, colorScheme: colorScheme)
        let mermaidTheme = MermaidRenderer.Theme(theme)
        let document = MarkdownReaderRenderer.document(
            source, theme: theme, fontFamily: settings.fontFamily)
        let sources = MermaidRenderer.sources(in: document)
        // Anything already drawn goes into the first pass, so reopening a file or flipping
        // the theme back shows its diagrams without a flash of source.
        let drawn = diagrams.merging(
            MermaidRenderer.shared.cachedDiagrams(for: sources, theme: mermaidTheme)) { _, new in new }
        // Relative image paths (`![](./shot.png)`) resolve against the file's own folder.
        MarkdownReaderWebView(
            html: MermaidRenderer.applying(drawn, to: document),
            baseURL: fileURL.deletingLastPathComponent(),
            fileURL: fileURL,
            addToChat: addToChat,
            canAddToChat: canAddToChat
        )
        .task(id: DiagramRequest(sources: sources, theme: mermaidTheme)) {
            guard !sources.isEmpty else { return }
            diagrams = await MermaidRenderer.shared.diagrams(for: sources, theme: mermaidTheme)
        }
    }

    /// What a render depends on: change either the diagrams or the colors and the task
    /// runs again; type anything else in the editor and it doesn't.
    private struct DiagramRequest: Equatable {
        let sources: [String]
        let theme: MermaidRenderer.Theme
    }
}

/// A `WKWebView` host that renders the reader HTML, preserves scroll position across
/// re-renders (theme flip, live edit), and opens web links in the browser rather than
/// navigating the page away. Its own background is cleared so the terminal background
/// shows through until the themed page paints (no white flash).
private struct MarkdownReaderWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    let fileURL: URL
    var addToChat: ((String?) -> Void)?
    var canAddToChat: (() -> Bool)?

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
        let bridge = WebContextMenuBridge()
        bridge.install(on: config)
        let view = ContextMenuWebView(frame: .zero, configuration: config)
        bridge.attach(to: view) { [weak view] click in
            view?.contextMenu(for: click) ?? NSMenu()
        }
        view.fileURL = fileURL
        view.addToChat = addToChat
        view.canAddToChat = canAddToChat
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: schemeBaseURL)
        // Take first responder off the terminal surface beneath the overlay so ⌘C copies the
        // reader's selection (the Edit menu's Copy routes to whoever holds focus).
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
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

/// A `WKWebView` whose right-click menu is termio's, not WebKit's: `WebContextMenuBridge`
/// suppresses the page's native menu and hands the click here, so the Markdown preview closes
/// terminal-style like the source editor — the overlay has no chrome button.
private final class ContextMenuWebView: WKWebView {
    /// The document on disk, so the menu can reveal it in Finder (like the file tree's row menu).
    var fileURL: URL?
    /// "Add to Chat": the argument is the reader's selected text (`nil` = no selection,
    /// the owner inserts the document's path instead). The gate is read at menu-open
    /// time; a plain-shell session shows no item.
    var addToChat: ((String?) -> Void)?
    var canAddToChat: (() -> Bool)?

    /// The reader's menu, built from the page's own right-click: Copy for a selection, then the
    /// actions that fit a file preview — Reveal in Finder (an explicit item, not a flaky Services
    /// shortcut) and a prominent Close, since the overlay has no chrome button.
    func contextMenu(for click: WebContextMenuBridge.Click) -> NSMenu {
        let menu = NSMenu()
        if !click.selection.isEmpty {
            menu.addPlainItem("Copy", target: self, action: #selector(copySelection(_:)),
                              representedObject: click.selection)
            menu.addItem(.separator())
        }
        if canAddToChat?() == true {
            menu.addPlainItem("Add to Chat", target: self, action: #selector(addToChatAction(_:)),
                              representedObject: click.selection)
        }
        if fileURL != nil {
            menu.addPlainItem("Reveal in Finder", target: self, action: #selector(revealInFinder))
        }
        menu.addPlainItem("Close", target: self, action: #selector(closeEditorOverlay))
        return menu
    }

    @objc private func copySelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A non-empty selection goes over as the snippet, an empty one as `nil` — the owner inserts
    /// the document's path instead.
    @objc private func addToChatAction(_ sender: NSMenuItem) {
        let selection = (sender.representedObject as? String).flatMap { $0.isEmpty ? nil : $0 }
        addToChat?(selection)
    }

    @objc private func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func closeEditorOverlay() {
        NotificationCenter.default.post(name: .termioCloseContentOverlay, object: nil)
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
