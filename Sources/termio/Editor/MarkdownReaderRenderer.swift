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
    /// `embedFonts: false` drops the ~135KB of inlined Quattro `@font-face`
    /// CSS — the companion server's phone previews take this path, where the
    /// stack's system-sans fallthrough beats paying the weight per file read.
    static func document(
        _ source: String, theme: TraceTheme, fontFamily: String, embedFonts: Bool = true
    ) -> String {
        let (frontmatter, body) = splitFrontmatter(source)
        return """
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
        \(frontmatter.map(frontmatterHTML) ?? "")
        \(MarkdownHTML.html(body, softBreaksAsBreaks: false, documentMode: true))
        </body>
        </html>
        """
    }

    // MARK: - YAML frontmatter

    /// A `---`-fenced YAML header on line 1 (SKILL.md, docs/ design docs, Obsidian notes)
    /// is metadata, not prose — fed to the markdown parser it degrades into a thematic
    /// break plus a run-on paragraph. Split it off and present it as a key–value block.
    /// Display-only parsing: top-level `key: value` lines become rows; indented or
    /// continuation lines fold into the previous key's value. Anything that doesn't look
    /// like that (no closing fence, first line not a key) is left in the body untouched —
    /// a `---` opening a document is also a legitimate thematic break.
    private static func splitFrontmatter(_ source: String)
        -> (pairs: [(key: String, value: String)]?, body: String)
    {
        let lines = source.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  let t = $0.trimmingCharacters(in: .whitespaces)
                  return t == "---" || t == "..."
              })
        else { return (nil, source) }
        let pairs = frontmatterPairs(lines[1..<close])
        guard !pairs.isEmpty else { return (nil, source) }
        return (pairs, lines[(close + 1)...].joined(separator: "\n"))
    }

    private static func frontmatterPairs(_ lines: ArraySlice<String>)
        -> [(key: String, value: String)]
    {
        var pairs: [(key: String, value: String)] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indented = raw.first == " " || raw.first == "\t"
            if !indented, let colon = raw.firstIndex(of: ":"), colon != raw.startIndex,
               raw[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            {
                let value = String(raw[raw.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                pairs.append((String(raw[..<colon]), value))
            } else if !pairs.isEmpty {
                let last = pairs.count - 1
                pairs[last].value += pairs[last].value.isEmpty ? trimmed : "\n" + trimmed
            } else {
                return []
            }
        }
        return pairs
    }

    private static func frontmatterHTML(_ pairs: [(key: String, value: String)]) -> String {
        let rows = pairs.map { pair in
            let value = unquote(pair.value)
            let valueHTML = escape(value).replacingOccurrences(of: "\n", with: "<br>")
            return "<div><dt>\(escape(pair.key))</dt><dd>\(valueHTML)</dd></div>"
        }.joined()
        return "<section class=\"frontmatter\"><dl>\(rows)</dl></section>"
    }

    /// A quoted YAML scalar keeps its quotes in the raw line; strip a matching outer pair
    /// (after multi-line folding, so a string wrapped across source lines unquotes too).
    private static func unquote(_ value: String) -> String {
        for quote: Character in ["\"", "'"]
        where value.count >= 2 && value.first == quote && value.last == quote {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The bundled iA Writer Quattro V faces (SIL OFL, license alongside the woff2s in
    /// Resources/Fonts) as `@font-face` rules with base64 `data:` sources. Variable
    /// fonts with a wght 400–700 axis, so the stylesheet gets real intermediate weights
    /// (bold prose sits at 600, headings at 700) instead of the static 400/700 pair.
    /// They must be embedded: `loadHTMLString` gives the WebContent process no read
    /// access to the app bundle, so a `file://` font URL would silently fail. ~135KB of
    /// CSS, built once. If the resources are missing the rules are simply absent and the
    /// stack falls through to the system sans — a different face, never a broken page.
    private static let quattroFontFaces: String = {
        let faces: [(file: String, style: String)] = [
            ("iAWriterQuattroV", "normal"),
            ("iAWriterQuattroV-Italic", "italic"),
        ]
        return faces.compactMap { face in
            guard let url = Bundle.termioResources.url(forResource: face.file, withExtension: "woff2"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return "@font-face { font-family: \"iA Writer Quattro\"; font-weight: 400 700; "
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
    /// comfort band), hierarchy carried by weight + space. Quattro V's variable wght axis
    /// puts headings at 700 and inline `**bold**` at 600, so emphasis inside a paragraph
    /// doesn't shout at heading weight.
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
      /* Left-aligned, not centered, so the prose lines up under the editor's file-name header
         (which sits at the same 20px leading edge) rather than drifting to the middle of a wide
         pane. A measure ceiling still caps the line length; +40px keeps the 20px side padding from
         eating into the 76ch of actual text (border-box puts padding inside max-width). The top is
         kept small — the scroll-away header already occupies the first strip. */
      max-width: calc(76ch + 40px); margin: 0; padding: 36px 20px 160px;
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
    .reader strong { font-weight: 600; }
    .reader em { font-style: italic; }
    .reader del { color: var(--muted); }
    /* Indented + muted, no accent bar or box. */
    .reader blockquote { margin: 1.3em 0; padding-left: 20px;
      border-left: 2px solid var(--line); color: var(--muted); }
    .reader ul, .reader ol { margin: 0 0 1.2em; padding-left: 1.4em; }
    .reader li { margin: 0.35em 0; padding-left: 0.2em; }
    .reader li::marker { color: var(--muted); }
    .reader li > ul, .reader li > ol { margin: 0.35em 0; }
    /* Task items: the Hugeicons box replaces the bullet, pulled into the marker gutter
       (GitHub positions its checkbox the same way); checked picks up the accent. */
    .reader li.task { list-style: none; }
    .reader li.task .task-box { width: 1.05em; height: 1.05em; vertical-align: -0.16em;
      margin: 0 0.5em 0 -1.6em; color: var(--muted); }
    .reader li.task .task-box.checked { color: var(--accent); }
    /* Code stays in the terminal face, on a whisper of tint — no borders/pills. */
    .reader code { font: 0.82em var(--font-mono);
      background: var(--soft); border-radius: 4px; padding: 0.1em 0.35em; }
    .reader pre { background: var(--soft); border-radius: 8px;
      padding: 15px 18px; margin: 1.3em 0; overflow-x: auto; max-width: 100%; }
    .reader pre code { background: none; padding: 0; font-size: 13.5px; line-height: 1.6; }
    .reader img { max-width: 100%; margin: 0.6em 0; border-radius: 6px; }
    /* Tables: horizontal rules only, like a native document — no grid, no outer box.
       Sizing follows github-markdown-css: `width: max-content` lays the table out at its
       natural content width so the browser's column balancing works unsquashed (equal-ish,
       content-proportioned columns), and `max-width + overflow` makes an oversized table
       scroll as a whole instead of crushing its widest column. Cells reset the body's
       anywhere-wrapping — mid-word breaks were what made columns look lopsided. */
    .reader table { border-collapse: collapse; margin: 1.4em 0; font-size: 15px;
      display: block; width: max-content; max-width: 100%; overflow-x: auto; }
    .reader th, .reader td { border-bottom: 1px solid var(--line); padding: 7px 16px 7px 0;
      text-align: left; overflow-wrap: normal; word-break: normal; }
    .reader th { font-weight: 600; color: var(--muted); border-bottom-color: var(--fg); }
    /* Raw-HTML layout tables (the README screenshot-grid idiom: `<td width="50%">`) are
       page structure, not data — let them fill the measure and keep their cell ratios
       instead of shrink-wrapping to content, and drop the data-table rules. */
    .reader table:has(td[width]) { display: table; width: 100%; table-layout: fixed; }
    .reader table:has(td[width]) td { border-bottom: none; vertical-align: middle; }
    .reader hr { border: none; border-top: 1px solid var(--line); margin: 2.4em 0; }
    .reader .image { color: var(--muted); font-size: 15px; }
    /* YAML frontmatter as a quiet metadata block: mono keys in the muted color, values in
       prose, on the same soft tint code blocks use — clearly apparatus, not document text. */
    .reader .frontmatter { background: var(--soft); border-radius: 8px;
      padding: 14px 18px; margin: 0 0 2.2em; }
    .reader .frontmatter dl { display: grid; grid-template-columns: max-content 1fr;
      column-gap: 22px; row-gap: 7px; margin: 0; }
    .reader .frontmatter div { display: contents; }
    .reader .frontmatter dt { color: var(--muted); font: 12.5px/1.75 var(--font-mono); }
    .reader .frontmatter dd { margin: 0; font-size: 14.5px; line-height: 1.5; }
    """
}
