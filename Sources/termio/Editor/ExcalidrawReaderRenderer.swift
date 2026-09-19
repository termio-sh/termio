import Foundation

/// Assembles the self-contained HTML document that shows one Excalidraw drawing: the
/// bundled hand-drawn faces, a themed canvas, and the finished SVG `ExcalidrawRenderer`
/// produced.
///
/// The page is deliberately plain. A drawing carries its own composition, so the only
/// jobs here are to sit the picture on the app's background, keep it legible at any
/// window size, and set its text in the faces Excalidraw drew it with.
enum ExcalidrawReaderRenderer {
    static func document(svg: String, theme: DocumentTheme) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(fontFaces)
        :root { --background: \(theme.background); --secondary: \(theme.secondary); }
        \(css)
        </style>
        </head>
        <body>
        <figure class="drawing">\(svg)</figure>
        </body>
        </html>
        """
    }

    /// The page shown when a file that should hold a drawing doesn't — the bytes decode to
    /// no scene, or the engine failed to load. Says so in the reader's own voice rather
    /// than leaving an empty canvas; the source is a flip away.
    static func failureDocument(theme: DocumentTheme) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { --background: \(theme.background); --secondary: \(theme.secondary); }
        \(css)
        </style>
        </head>
        <body><p class="empty">No drawing in this file.</p></body>
        </html>
        """
    }

    private static let css = """
    html, body { height: 100%; }
    body {
      margin: 0;
      background: var(--background);
      display: flex;
      align-items: center;
      justify-content: center;
      -webkit-font-smoothing: antialiased;
    }
    .drawing { margin: 0; padding: 24px; max-width: 100%; max-height: 100%; }
    /* The exported SVG carries its own width and height in scene units. Overriding both
       lets a drawing shrink to fit a narrow pane and stops a large one from forcing the
       page to scroll in two directions, while `height: auto` keeps its aspect ratio. */
    .drawing svg { max-width: 100%; height: auto; }
    .empty {
      color: var(--secondary);
      font: 13px -apple-system, system-ui, sans-serif;
    }
    """

    /// The faces Excalidraw sets a drawing's text in, embedded as base64 `@font-face`.
    ///
    /// They must be embedded for `MarkdownReaderRenderer`'s reason: `loadHTMLString` gives
    /// the WebContent process no read access to the app bundle, so a `file://` font URL
    /// would silently fail. ~350KB of CSS, built once.
    ///
    /// Each entry keeps the `unicode-range` Excalidraw subset it with — without it the
    /// browser picks the first face of a family and every glyph outside that subset falls
    /// through to a system serif, which is the giveaway that a drawing isn't rendering
    /// properly. If the manifest or a face is missing the rules are simply absent and the
    /// text falls back to the system sans — a different face, never a broken page.
    private static let fontFaces: String = {
        guard let manifest = Bundle.termioResources.url(
                  forResource: "excalidraw-fonts", withExtension: "json"),
              let data = try? Data(contentsOf: manifest),
              let faces = try? JSONDecoder().decode([Face].self, from: data)
        else {
            Log.markdown.error("excalidraw: excalidraw-fonts.json is missing from the bundle")
            return ""
        }
        return faces.compactMap { face -> String? in
            let name = (face.file as NSString).deletingPathExtension
            guard let url = Bundle.termioResources.url(forResource: name, withExtension: "woff2"),
                  let woff2 = try? Data(contentsOf: url) else { return nil }
            var rule = "@font-face { font-family: \"\(face.family)\"; "
            rule += "src: url(data:font/woff2;base64,\(woff2.base64EncodedString())) format(\"woff2\"); "
            if let weight = face.weight { rule += "font-weight: \(weight); " }
            if let range = face.unicodeRange { rule += "unicode-range: \(range); " }
            return rule + "}"
        }.joined(separator: "\n")
    }()

    private struct Face: Decodable {
        let family: String
        let file: String
        let unicodeRange: String?
        let weight: String?
    }
}
