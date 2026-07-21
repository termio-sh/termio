import Foundation

/// Assembles a self-contained HTML document for `MarkdownReaderView`: the reader `<head>`
/// (viewport, embedded fonts, theme variables, reading stylesheet) wrapped around
/// `MarkdownHTML`'s output.
///
/// The stylesheet is a document-reading skin — capped measure, generous vertical rhythm, a
/// clear type scale — the Apple-docs / iA-Writer register, distinct from the session
/// trace's dense dashboard CSS. Prose is set in the bundled iA Writer Quattro (a
/// "three-quarter mono": mono bones, proportional density — reads like a document while
/// still belonging in a terminal app); code spans and blocks stay in the terminal font so
/// they match the editor you flip from. All colors come through `var(--…)` filled from
/// the active `TraceTheme`, so the page tracks whatever chrome theme termio is on.
enum MarkdownReaderRenderer {
    /// `embedFonts: false` drops the ~230KB of inlined Quattro `@font-face`
    /// CSS — the companion server's phone previews take this path, where the
    /// stack's system-sans fallthrough beats paying the weight per file read.
    static func document(
        _ source: String, theme: TraceTheme, fontFamily: String, embedFonts: Bool = true
    ) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(embedFonts ? quattroFontFaces : "")
        \(themeVariables(theme))
        :root { --font-mono: \(monoStack(fontFamily)); }
        \(css)
        </style>
        </head>
        <body class="reader">
        \(MarkdownHTML.html(source, softBreaksAsBreaks: false))
        </body>
        </html>
        """
    }

    /// The bundled iA Writer Quattro faces (SIL OFL, license alongside the woff2s in
    /// Resources/Fonts) as `@font-face` rules with base64 `data:` sources. They must be
    /// embedded: `loadHTMLString` gives the WebContent process no read access to the app
    /// bundle, so a `file://` font URL would silently fail. ~230KB of CSS, built once.
    /// If the resources are missing the rules are simply absent and the stack falls
    /// through to the system sans — a different face, never a broken page.
    private static let quattroFontFaces: String = {
        let faces: [(file: String, weight: Int, style: String)] = [
            ("iAWriterQuattroS-Regular", 400, "normal"),
            ("iAWriterQuattroS-Italic", 400, "italic"),
            ("iAWriterQuattroS-Bold", 700, "normal"),
            ("iAWriterQuattroS-BoldItalic", 700, "italic"),
        ]
        return faces.compactMap { face in
            guard let url = Bundle.termioResources.url(forResource: face.file, withExtension: "woff2"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return "@font-face { font-family: \"iA Writer Quattro\"; font-weight: \(face.weight); "
                + "font-style: \(face.style); "
                + "src: url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\"); }"
        }.joined(separator: "\n")
    }()

    /// The code font: the terminal face the editor uses, so code in Preview matches the
    /// source you flip from. Empty family → the system monospace WebKit resolves for
    /// `ui-monospace` (SF Mono), matching `resolvedTerminalFont`'s fallback. Quotes are
    /// stripped so a pathological family name can't break out of the `<style>` block.
    private static func monoStack(_ family: String) -> String {
        let base = "ui-monospace, SFMono-Regular, \"SF Mono\", Menlo, monospace"
        let trimmed = family.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "<", with: "")
        return trimmed.isEmpty ? base : "\"\(trimmed)\", \(base)"
    }

    /// The live termio theme injected as CSS custom properties; the stylesheet references
    /// them, so the reader always matches the app's current colors.
    private static func themeVariables(_ t: TraceTheme) -> String {
        """
        :root {
          color-scheme: \(t.isDark ? "dark" : "light");
          --bg: \(t.background);
          --panel: \(t.panel);
          --fg: \(t.foreground);
          --muted: \(t.secondary);
          --accent: \(t.accent);
          --line: \(t.isDark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.10)");
          --soft: \(t.isDark ? "rgba(255,255,255,0.045)" : "rgba(0,0,0,0.035)");
          --font-prose: "iA Writer Quattro", -apple-system, system-ui, sans-serif;
        }
        """
    }

    /// The reading stylesheet. Metrics follow the Apple/iA register: ~17px prose on a 1.6
    /// rhythm, a measure capped at 76 characters (Apple docs' column, the classic 45–75
    /// comfort band), hierarchy carried by weight + space. Quattro ships 400/700 only, so
    /// those are the only weights used — a 600 would silently snap to 700 anyway.
    /// Only `{`/`}` literals — interpolation is solely `\(…)`, no backslashes.
    private static let css = """
    * { box-sizing: border-box; }
    /* Never let the page grow wider than the pane: a long code line, wide table, or
       unbreakable token would otherwise pin the body width so prose stops reflowing on
       resize (while the code block's own overflow-x hid it — the "only code block
       changes" bug). Keep horizontal scroll contained to the blocks that opt into it. */
    html, body { max-width: 100%; overflow-x: hidden; }
    ::selection { background: color-mix(in srgb, var(--accent) 20%, transparent); }
    body.reader {
      /* A ceiling, not a column: narrow panes still fill edge-to-edge; on a wide pane the
         text stops at ~76ch and centers instead of running to 120+ characters a line.
         (+88px keeps the 44px side padding from eating into the 76ch of actual text —
         border-box puts padding inside max-width.) */
      max-width: calc(76ch + 88px); margin: 0 auto; padding: 52px 44px 180px;
      background: var(--bg); color: var(--fg);
      font: 17px/1.6 var(--font-prose);
      /* NOT antialiased — grayscale smoothing thins the strokes and reads "轻飘飘"; the
         default (subpixel) smoothing keeps the face solid, like the editor. */
      -webkit-font-smoothing: auto; text-rendering: optimizeLegibility;
      font-feature-settings: "kern", "liga", "calt";
      overflow-wrap: anywhere; word-break: break-word;
    }
    .reader > *:first-child { margin-top: 0; }
    .reader > *:last-child { margin-bottom: 0; }
    /* Headings carry hierarchy through weight + space, not rules or color — no
       underlines (that GitHub look is the main "webpage" tell). */
    .reader h1 { font-size: 28px; font-weight: 700; letter-spacing: -0.019em; line-height: 1.2; margin: 0 0 0.7em; }
    .reader h2 { font-size: 22px; font-weight: 700; letter-spacing: -0.014em; line-height: 1.3; margin: 2em 0 0.5em; }
    .reader h3 { font-size: 19px; font-weight: 700; margin: 1.7em 0 0.35em; }
    .reader h4, .reader h5, .reader h6 { font-size: 17px; font-weight: 700; margin: 1.5em 0 0.35em; }
    .reader p { margin: 0 0 1.2em; }
    /* Quiet links: a faint underline, no hover jump — reading, not browsing. */
    .reader a { color: var(--accent); text-decoration: underline;
      text-decoration-color: color-mix(in srgb, var(--accent) 30%, transparent); text-underline-offset: 3px; }
    .reader strong { font-weight: 700; }
    .reader em { font-style: italic; }
    .reader del { color: var(--muted); }
    /* Indented + muted, no accent bar or box. */
    .reader blockquote { margin: 1.3em 0; padding-left: 20px;
      border-left: 2px solid var(--line); color: var(--muted); }
    .reader ul, .reader ol { margin: 0 0 1.2em; padding-left: 1.4em; }
    .reader li { margin: 0.35em 0; padding-left: 0.2em; }
    .reader li::marker { color: var(--muted); }
    .reader li > ul, .reader li > ol { margin: 0.35em 0; }
    /* Code stays in the terminal face, on a whisper of tint — no borders/pills. */
    .reader code { font: 0.82em var(--font-mono);
      background: var(--soft); border-radius: 4px; padding: 0.1em 0.35em; }
    .reader pre { background: var(--soft); border-radius: 8px;
      padding: 15px 18px; margin: 1.3em 0; overflow-x: auto; max-width: 100%; }
    .reader pre code { background: none; padding: 0; font-size: 13.5px; line-height: 1.6; }
    .reader img { max-width: 100%; margin: 0.6em 0; border-radius: 6px; }
    /* Tables: horizontal rules only, like a native document — no grid, no outer box. */
    .reader table { border-collapse: collapse; max-width: 100%; margin: 1.4em 0; font-size: 15px; display: block; overflow-x: auto; }
    .reader th, .reader td { border-bottom: 1px solid var(--line); padding: 7px 16px 7px 0; text-align: left; }
    .reader th { font-weight: 700; color: var(--muted); border-bottom-color: var(--fg); }
    .reader hr { border: none; border-top: 1px solid var(--line); margin: 2.4em 0; }
    .reader .image { color: var(--muted); font-size: 15px; }
    """
}
