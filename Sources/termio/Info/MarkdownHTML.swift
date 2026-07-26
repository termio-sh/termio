import Foundation
import Markdown

/// Markdown → HTML, shared by the session trace (agent messages) and the file-preview
/// Markdown reader. Built on Apple's swift-markdown (cmark-gfm underneath, so GFM tables /
/// strikethrough / task lists parse correctly). We walk the AST and emit HTML ourselves
/// instead of using a stock formatter so every piece of source text is escaped (transcripts
/// carry untrusted tool output, so raw HTML in the markdown renders as text, never as
/// markup). Soft-break handling differs per caller — see `softBreaksAsBreaks`.
enum MarkdownHTML {
    /// `softBreaksAsBreaks`: agent messages use single newlines for line-based content, so
    /// the trace renders each as `<br>`. A *document* (README, design doc) hard-wraps its
    /// source at ~80 columns and expects those newlines to collapse to spaces and reflow to
    /// the viewport — pass `false` there, or every source line break becomes a literal break
    /// (ragged short lines, big right-hand gap, and no reflow on resize).
    ///
    /// `documentMode`: the GitHub-compatibility switch for the file reader. Transcripts are
    /// untrusted tool output, so the default renders raw HTML as text and images as
    /// placeholders. A file the user opened is a document: images become real `<img>` tags
    /// (relative paths resolve against the reader's base URL), relative links work, and raw
    /// HTML passes through `HTMLSanitizer`'s whitelist (the README `<table>` screenshot
    /// grid renders as layout, while script/style/event handlers still die).
    static func html(
        _ source: String, softBreaksAsBreaks: Bool = true, documentMode: Bool = false
    ) -> String {
        var visitor = HTMLVisitor(softBreaksAsBreaks: softBreaksAsBreaks, documentMode: documentMode)
        return visitor.visit(Document(parsing: source))
    }
}

private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String
    let softBreaksAsBreaks: Bool
    let documentMode: Bool

    mutating func defaultVisit(_ markup: Markup) -> String {
        children(markup)
    }

    private mutating func children(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    // MARK: Blocks

    mutating func visitParagraph(_ p: Paragraph) -> String {
        "<p>\(children(p))</p>"
    }

    mutating func visitHeading(_ h: Heading) -> String {
        "<h\(h.level)>\(children(h))</h\(h.level)>"
    }

    mutating func visitCodeBlock(_ c: CodeBlock) -> String {
        let lang = (c.language?.isEmpty == false)
            ? " class=\"language-\(escape(c.language!))\"" : ""
        let code = c.code.hasSuffix("\n") ? String(c.code.dropLast()) : c.code
        return "<pre><code\(lang)>\(escape(code))</code></pre>"
    }

    mutating func visitBlockQuote(_ q: BlockQuote) -> String {
        "<blockquote>\(children(q))</blockquote>"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        "<ul>\(children(list))</ul>"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        "<ol>\(children(list))</ol>"
    }

    mutating func visitListItem(_ item: ListItem) -> String {
        guard let checkbox = item.checkbox else {
            return "<li>\(children(item))</li>"
        }
        // The box must land INSIDE the item's first paragraph: `<li>☐ <p>…` puts the
        // box alone on its own line, because the block-level <p> opens a new line.
        // `li.task` lets the host stylesheet drop the `•` marker (box + bullet is a
        // double marker) and pull the box into the marker gutter, GitHub-style.
        let icon = taskBox(checked: checkbox == .checked)
        var content = children(item)
        if let range = content.range(of: "<p>") {
            content.replaceSubrange(range, with: "<p>" + icon)
        } else {
            content = icon + content
        }
        return "<li class=\"task\">\(content)</li>"
    }

    /// The task checkbox as an inline SVG in the app's icon language: Hugeicons
    /// "square" (path data mirrors `TermioShared.HugeIcon.square`), with the
    /// checkmark-02 tick added when checked — 24×24 viewBox, 1.5 round stroke.
    /// The width/height attributes are only a sane fallback; both host stylesheets
    /// (trace, reader) size and color `.task-box` themselves.
    private func taskBox(checked: Bool) -> String {
        let square = "M2.5 12C2.5 7.52166 2.5 5.28249 3.89124 3.89124C5.28249 2.5 "
            + "7.52166 2.5 12 2.5C16.4783 2.5 18.7175 2.5 20.1088 3.89124C21.5 5.28249 "
            + "21.5 7.52166 21.5 12C21.5 16.4783 21.5 18.7175 20.1088 20.1088C18.7175 "
            + "21.5 16.4783 21.5 12 21.5C7.52166 21.5 5.28249 21.5 3.89124 20.1088C2.5 "
            + "18.7175 2.5 16.4783 2.5 12Z"
        let tick = " M8 12.5L10.5 15L16 9"
        return "<svg class=\"task-box\(checked ? " checked" : "")\" viewBox=\"0 0 24 24\" "
            + "width=\"16\" height=\"16\" fill=\"none\" stroke=\"currentColor\" "
            + "stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\" "
            + "aria-hidden=\"true\"><path d=\"\(square)\(checked ? tick : "")\"/></svg>"
    }

    mutating func visitThematicBreak(_ hr: ThematicBreak) -> String {
        "<hr>"
    }

    /// Raw HTML: untrusted transcript content is shown as text, never run; a document
    /// passes it through the GitHub-style whitelist instead so README layout markup
    /// (`<table>` grids, `<details>`, `<img>`) renders as markup.
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        documentMode
            ? HTMLSanitizer.sanitize(html.rawHTML)
            : "<p>\(escape(html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)))</p>"
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) -> String {
        "<table>\(children(table))</table>"
    }

    mutating func visitTableHead(_ head: Table.Head) -> String {
        let cells = head.children.map { "<th>\(children($0))</th>" }.joined()
        return "<thead><tr>\(cells)</tr></thead>"
    }

    mutating func visitTableBody(_ body: Table.Body) -> String {
        "<tbody>\(children(body))</tbody>"
    }

    mutating func visitTableRow(_ row: Table.Row) -> String {
        let cells = row.children.map { "<td>\(children($0))</td>" }.joined()
        return "<tr>\(cells)</tr>"
    }

    // MARK: Inline

    mutating func visitText(_ text: Markdown.Text) -> String {
        escape(text.string)
    }

    mutating func visitInlineCode(_ code: InlineCode) -> String {
        "<code>\(escape(code.code))</code>"
    }

    mutating func visitEmphasis(_ em: Emphasis) -> String {
        "<em>\(children(em))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(children(strong))</strong>"
    }

    mutating func visitStrikethrough(_ s: Strikethrough) -> String {
        "<del>\(children(s))</del>"
    }

    /// Web links become anchors everywhere; documents additionally get relative links
    /// and in-page anchors (resolved against the reader's base URL, GitHub-style).
    /// Anything else (`javascript:`, `file:`) renders as its label text.
    mutating func visitLink(_ link: Link) -> String {
        guard let dest = link.destination, HTMLSanitizer.safeURL(dest, allowRelative: documentMode)
        else { return children(link) }
        return "<a href=\"\(escape(dest))\">\(children(link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        if documentMode, let src = image.source, HTMLSanitizer.safeURL(src, allowRelative: true) {
            return "<img src=\"\(escape(src))\" alt=\"\(escape(image.plainText))\">"
        }
        let alt = children(image)
        return "<span class=\"image\">🖼 \(alt.isEmpty ? "image" : alt)</span>"
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> String {
        documentMode ? HTMLSanitizer.sanitize(html.rawHTML) : escape(html.rawHTML)
    }

    mutating func visitSoftBreak(_ br: SoftBreak) -> String {
        // A document collapses source line breaks to spaces (normal Markdown) so text
        // reflows; the trace keeps them as `<br>` for line-based agent output.
        softBreaksAsBreaks ? "<br>" : " "
    }

    mutating func visitLineBreak(_ br: LineBreak) -> String {
        "<br>"
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Whitelist sanitizer for raw HTML in *document* mode, mirroring GitHub's
/// `html-pipeline` SanitizationFilter: a fixed tag list, a small attribute list, and
/// http/https/mailto/relative protocols only. Tags are re-emitted from parsed parts —
/// nothing from the source reaches the output verbatim — so `script`/`style`/`iframe`,
/// inline `style`, `class`/`id`, and `on*` handlers can't survive. Non-whitelisted tags
/// are escaped to visible text (the trace's honesty rule) rather than dropped.
enum HTMLSanitizer {
    /// GitHub's element whitelist, minus obscure/legacy entries termio never styles
    /// (`tt`, `strike`, `ruby`…). `figure`/`figcaption`/`picture` kept for READMEs.
    private static let allowedTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "br", "b", "i", "strong", "em", "a", "pre",
        "code", "img", "div", "ins", "del", "sup", "sub", "p", "ol", "ul", "li", "table",
        "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "blockquote", "dl", "dt",
        "dd", "kbd", "q", "samp", "var", "hr", "s", "summary", "details", "figure",
        "figcaption", "abbr", "cite", "dfn", "mark", "small", "span", "time", "wbr",
        "picture", "source",
    ]

    /// The useful subset of GitHub's `:all` attribute list plus its per-element ones.
    /// `style`, `class`, `id`, and event handlers are intentionally absent — GitHub
    /// strips those too.
    private static let allowedAttributes: Set<String> = [
        "href", "src", "srcset", "media", "alt", "title", "align", "valign", "width",
        "height", "border", "colspan", "rowspan", "open", "dir", "lang", "start", "type",
        "checked", "disabled", "datetime", "cite", "cellpadding", "cellspacing",
    ]

    /// `http`/`https`/`mailto`/relative, GitHub's protocol whitelist for href/src.
    /// A colon before any `/`, `?`, `#` means an explicit scheme; everything else is
    /// relative. Control characters are rejected outright (scheme-smuggling guard).
    static func safeURL(_ url: String, allowRelative: Bool) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return false }
        let lower = trimmed.lowercased()
        for scheme in ["http://", "https://", "mailto:"] where lower.hasPrefix(scheme) {
            return true
        }
        guard allowRelative else { return false }
        if let colon = trimmed.firstIndex(of: ":"),
           !trimmed[..<colon].contains(where: { "/?#".contains($0) }) {
            return false
        }
        return true
    }

    static func sanitize(_ html: String) -> String {
        // Comments die silently (GitHub drops them); everything else is tokenized.
        let source = html.replacing(#/<!--.*?-->/#.dotMatchesNewlines(), with: "")
        let tag = #/<(/?)([a-zA-Z][a-zA-Z0-9-]*)((?:[^<>"']|"[^"]*"|'[^']*')*?)(/?)>/#
        var out = ""
        var index = source.startIndex
        while let match = source[index...].firstMatch(of: tag) {
            out += escapeText(String(source[index..<match.range.lowerBound]))
            let name = String(match.2).lowercased()
            if allowedTags.contains(name) {
                out += match.1.isEmpty
                    ? "<\(name)\(rebuildAttributes(String(match.3)))>"
                    : "</\(name)>"
            } else {
                out += escapeText(String(source[match.range]))
            }
            index = match.range.upperBound
        }
        out += escapeText(String(source[index...]))
        return out
    }

    private static func rebuildAttributes(_ raw: String) -> String {
        let attribute = #/([a-zA-Z][a-zA-Z0-9-]*)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s"'<>`]+))?/#
        var parts = ""
        for match in raw.matches(of: attribute) {
            let key = String(match.1).lowercased()
            guard allowedAttributes.contains(key) else { continue }
            guard let rawValue = match.2 else {
                parts += " \(key)"  // boolean attribute (`open`, `checked`)
                continue
            }
            var value = String(rawValue)
            if value.hasPrefix("\"") || value.hasPrefix("'") {
                value = String(value.dropFirst().dropLast())
            }
            if ["href", "src", "srcset"].contains(key),
               !safeURL(value, allowRelative: true) { continue }
            parts += " \(key)=\"\(escapeAttribute(value))\""
        }
        return parts
    }

    private static func escapeText(_ s: String) -> String {
        // `&` passes through so entities in the source (`&amp;`, `&nbsp;`) keep working.
        s.replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
