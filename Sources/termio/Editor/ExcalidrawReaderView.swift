import AppKit
import SwiftUI
import WebKit

/// The Preview side of `FileEditorView` for Excalidraw drawings: renders the file as the
/// picture it is, on the app's own background.
///
/// It renders the file's *bytes*, not the editor buffer, because a drawing is authored
/// elsewhere — Excalidraw, or an agent writing the scene JSON. Flipping to Edit and back
/// re-renders from what was loaded; the source face is for reading the scene, not drawing
/// in it.
struct ExcalidrawReaderView: View {
    let data: Data
    @ObservedObject var settings: AppSettings
    let colorScheme: ColorScheme
    /// Whether Preview is the face on screen. The reader stays mounted while Edit shows, so
    /// rendering keys off this rather than off being alive.
    var isActive: Bool = true

    /// The rendered drawing, filled in by the task below. Drawing one needs a DOM and is
    /// therefore asynchronous, so the page shows the app background until it arrives.
    @State private var svg: String?
    /// Whether a render has finished and produced nothing — the file holds no scene. Kept
    /// apart from `svg == nil` so the empty state doesn't flash before the first render.
    @State private var failed = false

    var body: some View {
        let theme = DocumentTheme.resolveReader(settings: settings, colorScheme: colorScheme)
        let drawingTheme = ExcalidrawRenderer.Theme(theme)
        // Anything already rendered goes into the first pass, so reopening a file or
        // flipping the theme back shows the drawing without a blank frame.
        let drawn = svg ?? ExcalidrawRenderer.shared.cachedDrawing(for: data, theme: drawingTheme)
        ExcalidrawWebView(html: page(drawn: drawn, theme: theme), isActive: isActive)
            .task(id: RenderRequest(theme: drawingTheme, active: isActive)) {
                guard isActive, drawn == nil else { return }
                let rendered = await ExcalidrawRenderer.shared.drawing(for: data, theme: drawingTheme)
                svg = rendered
                failed = rendered == nil
            }
    }

    private func page(drawn: String?, theme: DocumentTheme) -> String {
        if let drawn { return ExcalidrawReaderRenderer.document(svg: drawn, theme: theme) }
        if failed { return ExcalidrawReaderRenderer.failureDocument(theme: theme) }
        // Still rendering: the bare themed background, so the flip into Preview doesn't
        // flash white before the picture lands.
        return ExcalidrawReaderRenderer.document(svg: "", theme: theme)
    }

    /// What a render depends on: change the colors and it runs again. It carries `active`
    /// so a drawing hidden mid-render finishes on the flip back.
    private struct RenderRequest: Equatable {
        let theme: ExcalidrawRenderer.Theme
        let active: Bool
    }
}

/// A `WKWebView` host for the rendered drawing. Deliberately thinner than the Markdown
/// reader's: the page is one self-contained SVG, so there are no local files to resolve
/// through a scheme handler and no links to intercept.
///
/// It also never claims first responder, unlike the Markdown reader. There is nothing here
/// to select or copy, and taking focus would swallow the Escape that closes the overlay.
private struct ExcalidrawWebView: NSViewRepresentable {
    let html: String
    var isActive: Bool

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
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

    final class Coordinator {
        var lastHTML = ""
    }
}
