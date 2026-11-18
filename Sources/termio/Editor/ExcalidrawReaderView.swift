import AppKit
import SwiftUI
import WebKit

/// The Preview side of `FileEditorView` for Excalidraw drawings: renders the file as the
/// picture it is, on the app's own background.
///
/// It renders *bytes*, not a string, because a scene embedded in a PNG has no text form.
/// For a text scene the caller passes the editor buffer, so an edit to the JSON shows on
/// the flip back to Preview.
struct ExcalidrawReaderView: View {
    let data: Data
    @ObservedObject var settings: AppSettings
    let colorScheme: ColorScheme
    /// Whether Preview is the face on screen. The reader stays mounted while Edit shows, so
    /// rendering keys off this rather than off being alive.
    var isActive: Bool = true

    /// The last finished render and what it was a render of. Rendering needs a DOM and is
    /// therefore asynchronous, so the page shows the app background until it lands. The
    /// bytes and the theme are kept with it so a picture of the old buffer, or one in the
    /// other appearance, is never shown as the current one.
    @State private var rendered: Rendered?

    var body: some View {
        let theme = DocumentTheme.resolveReader(settings: settings, colorScheme: colorScheme)
        let drawingTheme = ExcalidrawRenderer.Theme(theme)
        let current = rendered.flatMap { $0.data == data && $0.theme == drawingTheme ? $0 : nil }
        // Anything already rendered goes into the first pass, so reopening a file or
        // flipping the theme back shows the drawing without a blank frame.
        let drawn = current?.drawing
            ?? ExcalidrawRenderer.shared.cachedDrawing(for: data, theme: drawingTheme)
        // A finished render that found no scene. Kept apart from "not rendered yet" so the
        // failure page doesn't flash before the first render.
        let failed = current != nil && drawn == nil
        ExcalidrawWebView(html: page(drawn: drawn, failed: failed, theme: theme), isActive: isActive)
            .task(id: RenderRequest(data: data, theme: drawingTheme, active: isActive)) {
                guard isActive, drawn == nil else { return }
                let drawing = await ExcalidrawRenderer.shared.drawing(for: data, theme: drawingTheme)
                // A render the view has moved on from must not replace the newer picture.
                guard !Task.isCancelled else { return }
                rendered = Rendered(data: data, theme: drawingTheme, drawing: drawing)
            }
    }

    private struct Rendered {
        let data: Data
        let theme: ExcalidrawRenderer.Theme
        let drawing: ExcalidrawRenderer.Drawing?
    }

    private func page(drawn: ExcalidrawRenderer.Drawing?, failed: Bool, theme: DocumentTheme) -> String {
        switch drawn {
        case .drawing(let svg):
            return ExcalidrawReaderRenderer.document(svg: svg, theme: theme)
        case .empty:
            // A drawing with nothing in it — a file just created, or one emptied out. Not
            // the failure page: nothing is wrong with the file.
            return ExcalidrawReaderRenderer.emptyDocument(theme: theme)
        case nil where failed:
            return ExcalidrawReaderRenderer.failureDocument(theme: theme)
        case nil:
            // Still rendering: the bare themed background, so the flip into Preview
            // doesn't flash white before the picture lands.
            return ExcalidrawReaderRenderer.document(svg: "", theme: theme)
        }
    }

    /// What a render depends on: change the bytes or the colors and it runs again. It
    /// carries `active` so a drawing hidden mid-render finishes on the flip back.
    private struct RenderRequest: Equatable {
        let data: Data
        let theme: ExcalidrawRenderer.Theme
        let active: Bool
    }
}

/// A `WKWebView` host for the rendered drawing. Deliberately thinner than the Markdown
/// reader's: the page is one self-contained SVG, so there are no local files to resolve
/// through a scheme handler. A drawing is somebody else's file, so the page runs no
/// script and goes nowhere: a web link on a shape opens in the browser instead.
///
/// It also never claims first responder, unlike the Markdown reader. There is nothing here
/// to select or copy, and taking focus would swallow the Escape that closes the overlay.
struct ExcalidrawWebView: NSViewRepresentable {
    let html: String
    var isActive: Bool

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // A drawing is fit to the pane, and a large one is then too small to read. Pinch
        // zooms in and scrolling pans, with no script in the page.
        view.allowsMagnification = true
        // Cleared so the terminal background shows through until the themed page paints,
        // rather than a white flash.
        view.setValue(false, forKey: "drawsBackground")
        view.isHidden = !isActive
        view.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastHTML = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.isHidden == isActive { view.isHidden = !isActive }
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // The only load this view makes is its own page, which has no URL.
            let isOwnPage = navigationAction.navigationType == .other
                && navigationAction.request.url?.absoluteString == "about:blank"
            decisionHandler(isOwnPage ? .allow : .cancel)
            if navigationAction.navigationType == .linkActivated,
               let link = Self.externalLink(navigationAction.request.url) {
                NSWorkspace.shared.open(link)
            }
        }

        /// A link on a shape opens in the browser, never in this view. Only web links: a
        /// drawing is somebody else's file and does not get to open a local path or an
        /// app's URL scheme.
        static func externalLink(_ url: URL?) -> URL? {
            guard let url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil else { return nil }
            return url
        }

        /// The policy above refuses the reload WebKit would make by itself after the page's
        /// process ends, so the page is loaded again here.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.loadHTMLString(lastHTML, baseURL: nil)
        }
    }
}
