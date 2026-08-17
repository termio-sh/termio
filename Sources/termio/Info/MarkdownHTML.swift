import Foundation
import Markdown

/// Markdown → HTML, shared by the session trace (agent messages) and the file-preview
/// Markdown reader. Built on Apple's swift-markdown (cmark-gfm underneath, so GFM tables /
/// strikethrough / task lists parse correctly). We walk the AST and emit HTML ourselves
/// instead of using a stock formatter so every piece of source text is escaped (transcripts
/// carry untrusted tool output, so raw HTML in the markdown renders as text, never as
/// markup). Soft-break handling differs per caller — see `softBreaksAsBreaks`.
///
/// GitHub-flavored constructs that cmark-gfm itself doesn't hand us are added around the
/// parse: alerts and heading anchors come off the AST, bare-URL autolinks and `:emoji:`
/// off the text nodes, and footnotes and `$math$` are lifted out of the source before
/// parsing (see `MarkdownPreprocessor`). Code fences and math are rendered to finished
/// markup by `MarkdownScripting`, so the page still runs no script of its own.
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
    ///
    /// A ```` ```mermaid ```` fence renders as a code block here. Drawing it needs a DOM,
    /// so `MermaidRenderer` swaps the fences for SVG in a second pass over this output —
    /// which keeps this function synchronous and every surface on one mechanism.
    static func html(
        _ source: String, softBreaksAsBreaks: Bool = true, documentMode: Bool = false
    ) -> String {
        let prepared = MarkdownPreprocessor.prepare(source)
        var visitor = HTMLVisitor(
            softBreaksAsBreaks: softBreaksAsBreaks,
            documentMode: documentMode,
            math: prepared.math,
            footnotes: prepared.footnotes
        )
        let body = visitor.visit(Document(parsing: prepared.text))
        return body + visitor.footnotesSection()
    }
}

// MARK: - Preprocessing

/// A `$…$` / `$$…$$` span lifted out of the source before parsing.
struct MathSpan {
    let tex: String
    let display: Bool
}

/// The two constructs that have to leave the source before cmark sees it.
///
/// Math, because `*`, `_` and `\` inside TeX are inline Markdown syntax — `$a_1 * b_1$`
/// would come back with an emphasis node in the middle of the formula. Footnotes, because
/// `[^1]: a note` is a *link reference definition* as far as cmark is concerned, which
/// silently turns every `[^1]` in the prose into a link to the note's first word.
///
/// Both are replaced by private-use sentinels (`U+E000 index U+E001`), which survive
/// parsing and escaping untouched and are swapped for finished markup in the text visitor.
enum MarkdownPreprocessor {
    struct Prepared {
        let text: String
        let math: [MathSpan]
        let footnotes: [(identifier: String, markdown: String)]
    }

    static func prepare(_ source: String) -> Prepared {
        let (footnotes, withoutDefinitions) = extractFootnoteDefinitions(source)
        let (math, text) = extractMath(withoutDefinitions)
        return Prepared(text: text, math: math, footnotes: footnotes)
    }

    static let sentinelOpen: Character = "\u{E000}"
    static let sentinelClose: Character = "\u{E001}"

    static func sentinel(_ index: Int) -> String {
        "\(sentinelOpen)\(index)\(sentinelClose)"
    }

    // MARK: Math

    /// Scans the source outside fenced blocks and code spans for `$$…$$` (display) and
    /// `$…$` (inline). Inline math follows GitHub's rule that the delimiters hug their
    /// content — `$5 and $6` stays prose, `$x + y$` becomes math.
    private static func extractMath(_ source: String) -> ([MathSpan], String) {
        guard source.contains("$") else { return ([], source) }
        var spans: [MathSpan] = []
        var out = ""
        let chars = Array(source)
        var index = 0
        var atLineStart = true
        var fence: (marker: Character, length: Int)?

        while index < chars.count {
            if atLineStart, let run = fenceRun(chars, at: index) {
                if let open = fence {
                    if run.marker == open.marker, run.length >= open.length { fence = nil }
                } else {
                    fence = run
                }
                copyLine(chars, from: &index, into: &out)
                atLineStart = true
                continue
            }
            if fence != nil {
                copyLine(chars, from: &index, into: &out)
                atLineStart = true
                continue
            }

            let character = chars[index]
            atLineStart = character == "\n"

            switch character {
            case "\\" where index + 1 < chars.count:
                // An escaped delimiter is prose: `\$5` must never open math.
                out.append(character)
                out.append(chars[index + 1])
                index += 2
            case "`":
                copyCodeSpan(chars, from: &index, into: &out)
            case "$" where index + 1 < chars.count && chars[index + 1] == "$":
                if let close = find(chars, of: "$$", after: index + 2) {
                    spans.append(MathSpan(
                        tex: String(chars[(index + 2)..<close]).trimmingCharacters(in: .whitespacesAndNewlines),
                        display: true))
                    out += sentinel(spans.count - 1)
                    index = close + 2
                } else {
                    out += "$$"
                    index += 2
                }
            case "$":
                if let close = inlineMathClose(chars, from: index) {
                    spans.append(MathSpan(
                        tex: String(chars[(index + 1)..<close]), display: false))
                    out += sentinel(spans.count - 1)
                    index = close + 1
                } else {
                    out.append(character)
                    index += 1
                }
            default:
                out.append(character)
                index += 1
            }
        }
        return (spans, out)
    }

    /// The closing `$` of an inline formula: on the same line, with no space just inside
    /// either delimiter and no nested `$`.
    private static func inlineMathClose(_ chars: [Character], from open: Int) -> Int? {
        let first = open + 1
        guard first < chars.count, !chars[first].isWhitespace else { return nil }
        var index = first
        while index < chars.count, chars[index] != "\n" {
            if chars[index] == "\\" { index += 2; continue }
            if chars[index] == "$" {
                guard index > first, !chars[index - 1].isWhitespace else { return nil }
                return index
            }
            index += 1
        }
        return nil
    }

    /// A code span runs to the next backtick run of the same length, across lines, and is
    /// copied verbatim — `` `$PATH` `` is a shell variable, not math.
    private static func copyCodeSpan(_ chars: [Character], from index: inout Int, into out: inout String) {
        let start = index
        while index < chars.count, chars[index] == "`" { index += 1 }
        let length = index - start
        out += String(repeating: "`", count: length)
        var scan = index
        while scan < chars.count {
            guard chars[scan] == "`" else { scan += 1; continue }
            var run = scan
            while run < chars.count, chars[run] == "`" { run += 1 }
            if run - scan == length {
                out += String(chars[index..<run])
                index = run
                return
            }
            scan = run
        }
    }

    private static func find(_ chars: [Character], of pair: String, after start: Int) -> Int? {
        let needle = Array(pair)
        var index = start
        while index + needle.count <= chars.count {
            if Array(chars[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    private static func copyLine(_ chars: [Character], from index: inout Int, into out: inout String) {
        while index < chars.count {
            let character = chars[index]
            out.append(character)
            index += 1
            if character == "\n" { return }
        }
    }

    /// A ``` / ~~~ fence at the start of a line, allowing CommonMark's 3 spaces of indent.
    private static func fenceRun(_ chars: [Character], at start: Int) -> (marker: Character, length: Int)? {
        var index = start
        var indent = 0
        while index < chars.count, chars[index] == " ", indent < 3 { index += 1; indent += 1 }
        guard index < chars.count, chars[index] == "`" || chars[index] == "~" else { return nil }
        let marker = chars[index]
        var length = 0
        while index < chars.count, chars[index] == marker { index += 1; length += 1 }
        return length >= 3 ? (marker, length) : nil
    }

    // MARK: Footnotes

    /// Lifts `[^id]: note text` definitions (and their indented continuation lines) out of
    /// the source, leaving the references in the prose for the visitor to number.
    private static func extractFootnoteDefinitions(
        _ source: String
    ) -> ([(identifier: String, markdown: String)], String) {
        guard source.contains("[^") else { return ([], source) }
        let definition = #/^ {0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$/#
        var definitions: [(identifier: String, markdown: String)] = []
        var kept: [String] = []
        var fence: (marker: Character, length: Int)?
        var collecting = false

        for line in source.components(separatedBy: "\n") {
            let characters = Array(line)
            if let run = fenceRun(characters, at: 0) {
                if let open = fence {
                    if run.marker == open.marker, run.length >= open.length { fence = nil }
                } else {
                    fence = run
                }
                collecting = false
                kept.append(line)
                continue
            }
            if fence != nil {
                kept.append(line)
                continue
            }
            if let match = line.wholeMatch(of: definition) {
                definitions.append((String(match.1), String(match.2)))
                collecting = true
                continue
            }
            // An indented, non-blank line after a definition continues that note.
            if collecting, let first = line.first, first == " " || first == "\t" {
                let index = definitions.count - 1
                definitions[index].markdown += "\n" + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            collecting = false
            kept.append(line)
        }
        return (definitions, kept.joined(separator: "\n"))
    }
}

// MARK: - Punctuation compression

/// 标点挤压 — the one thing Chinese typesetting does that no browser does for you.
///
/// A full-width mark owns a full em with its glyph sitting on one side, so two in a row
/// (`。（`, `）、`) leave a gap the width of a character in the middle of a sentence.
/// Chinese typesetting closes it by pulling the first mark of the pair back; the pair
/// rules and the ½ / ¼ amounts are Heti's (sivan/heti, MIT), which is the reference
/// implementation of this on the web.
///
/// The cheaper routes were measured first and both were wrong: PingFang's `palt` is a
/// no-op under WebKit, and `halt` compresses *every* mark, including single ones, which
/// costs a sentence its ordinary rhythm. `text-spacing-trim`, the CSS property meant for
/// exactly this, isn't in WebKit yet.
///
/// Heti needs JavaScript to walk the DOM for this; termio builds the HTML itself, so the
/// same wrapping happens at render time and the page still runs nothing. The rule is
/// local to a pair of characters, so it needs no notion of what language the document is
/// in — these marks only ever occur in CJK text.
enum CJKPunctuation {
    private static let stop: Set<Character> = ["。", "．", "，", "、", "：", "；", "！", "‼", "？", "⁇"]
    private static let open: Set<Character> = ["「", "『", "（", "《", "〈", "【", "〖", "〔", "［", "｛"]
    private static let close: Set<Character> = ["」", "』", "）", "》", "〉", "】", "〗", "〕", "］", "｝"]
    private static let separator: Set<Character> = ["·", "・", "‧"]
    private static let quoteOpen: Set<Character> = ["“", "‘"]
    private static let quoteClose: Set<Character> = ["”", "’"]

    static func compressed(_ text: String) -> String {
        guard text.contains(where: { isMark($0) }) else { return text }
        var out = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch amount(character, followedBy: next) {
            case .none: out.append(character)
            case .half: out += "<span class=\"punctuation-half\">\(character)</span>"
            case .quarter: out += "<span class=\"punctuation-quarter\">\(character)</span>"
            }
        }
        return out
    }

    private enum Amount { case none, half, quarter }

    private static func amount(_ character: Character, followedBy next: Character?) -> Amount {
        guard let next else { return .none }
        // A stop or a bracket running into another bracket closes by half an em.
        if stop.contains(character), open.contains(next) || close.contains(next) { return .half }
        if open.contains(character), open.contains(next) { return .half }
        if close.contains(character),
           stop.contains(next) || open.contains(next) || close.contains(next) { return .half }
        // A middot, or a curly quote, carries less of its own space, so it closes by a
        // quarter — closing it by half would collide the glyphs.
        if separator.contains(character), open.contains(next) { return .quarter }
        if close.contains(character), separator.contains(next) { return .quarter }
        if stop.contains(character),
           quoteOpen.contains(next) || quoteClose.contains(next) { return .quarter }
        if quoteOpen.contains(character), open.contains(next) { return .quarter }
        return .none
    }

    private static func isMark(_ character: Character) -> Bool {
        stop.contains(character) || open.contains(character) || close.contains(character)
            || separator.contains(character) || quoteOpen.contains(character)
    }
}

// MARK: - Alerts

/// GitHub's blockquote alerts. Rendered as a titled, tinted block rather than GitHub's
/// icon row — the reader's register is a document, not a web page.
enum MarkdownAlert: String, CaseIterable {
    case note, tip, important, warning, caution

    var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    var marker: String { "[!\(rawValue.uppercased())]" }

    /// The alert kind a blockquote opens with, if any. Matched on the quote's plain text so
    /// it doesn't depend on how cmark split `[`, `!NOTE`, `]` into inline nodes.
    static func opening(_ quote: BlockQuote) -> MarkdownAlert? {
        guard let paragraph = quote.child(at: 0) as? Paragraph else { return nil }
        let text = paragraph.plainText.trimmingCharacters(in: .whitespaces)
        return allCases.first { alert in
            guard text.uppercased().hasPrefix(alert.marker) else { return false }
            let rest = text.dropFirst(alert.marker.count)
            return rest.isEmpty || rest.first?.isWhitespace == true || rest.first == "\n"
        }
    }
}

// MARK: - Visitor

private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String
    let softBreaksAsBreaks: Bool
    let documentMode: Bool
    let math: [MathSpan]
    let footnotes: [(identifier: String, markdown: String)]

    /// Heading slugs already used, so a document with two "Overview" sections gets
    /// `#overview` and `#overview-1` the way GitHub's anchors do.
    private var usedSlugs: [String: Int] = [:]
    /// Footnote identifiers in order of first reference — GitHub numbers by reference, not
    /// by definition order.
    private var referencedFootnotes: [String] = []
    /// Autolinking is suppressed inside a link's label so `[https://x](https://y)` can't
    /// nest one anchor inside another.
    private var insideLink = false

    init(
        softBreaksAsBreaks: Bool, documentMode: Bool, math: [MathSpan],
        footnotes: [(identifier: String, markdown: String)]
    ) {
        self.softBreaksAsBreaks = softBreaksAsBreaks
        self.documentMode = documentMode
        self.math = math
        self.footnotes = footnotes
    }

    /// A code block's text as both the collector and the renderer see it.
    static func codeText(_ block: CodeBlock) -> String {
        block.code.hasSuffix("\n") ? String(block.code.dropLast()) : block.code
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        children(markup)
    }

    private mutating func children(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    // MARK: Blocks

    mutating func visitParagraph(_ p: Paragraph) -> String {
        // A paragraph that is nothing but a `$$…$$` block is the formula's own block:
        // wrapping display MathML in `<p>` would center a line of prose around it.
        if let span = displayMathOnly(p) { return renderedMath(span) }
        return "<p>\(children(p))</p>"
    }

    mutating func visitHeading(_ h: Heading) -> String {
        let content = children(h)
        let slug = uniqueSlug(for: h.plainText)
        return "<h\(h.level) id=\"\(escape(slug))\">\(content)</h\(h.level)>"
    }

    /// GitHub's anchor slug: lowercased, punctuation dropped, spaces to hyphens, and a
    /// `-1`, `-2` … suffix on repeats. Without these ids every in-document table of
    /// contents is a dead link.
    private mutating func uniqueSlug(for text: String) -> String {
        var slug = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " {
                slug.append("-")
            }
        }
        if slug.isEmpty { slug = "section" }
        let seen = usedSlugs[slug, default: 0]
        usedSlugs[slug] = seen + 1
        return seen == 0 ? slug : "\(slug)-\(seen)"
    }

    /// Fenced code: ```` ```math ```` is a formula, anything highlight.js knows is
    /// highlighted here (never auto-detected — a three-line block guesses wrong and the
    /// colors lie), and everything else keeps the plain escaped `<code>` it always had.
    mutating func visitCodeBlock(_ c: CodeBlock) -> String {
        let code = Self.codeText(c)
        let language = c.language?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if language == "math", let html = MarkdownScripting.math(code, display: true) {
            return "<div class=\"math math-display\">\(html)</div>"
        }
        let classAttribute = language.isEmpty ? "" : " class=\"language-\(escape(language)) hljs\""
        if !language.isEmpty, let highlighted = MarkdownScripting.highlight(code, language: language) {
            return "<pre><code\(classAttribute)>\(highlighted)</code></pre>"
        }
        return "<pre><code\(classAttribute)>\(escape(code))</code></pre>"
    }

    mutating func visitBlockQuote(_ q: BlockQuote) -> String {
        guard let alert = MarkdownAlert.opening(q) else {
            return "<blockquote>\(children(q))</blockquote>"
        }
        var blocks = ""
        for (index, child) in q.children.enumerated() {
            guard index == 0, let paragraph = child as? Paragraph else {
                blocks += visit(child)
                continue
            }
            // Drop the `[!NOTE]` marker from the rendered first paragraph: it escapes to
            // itself, so trimming the string is exact regardless of how it was tokenized.
            var content = children(paragraph)
            if content.count >= alert.marker.count { content.removeFirst(alert.marker.count) }
            if content.hasPrefix("<br>") { content.removeFirst(4) }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { blocks += "<p>\(content)</p>" }
        }
        return "<div class=\"alert alert-\(alert.rawValue)\">"
            + "<p class=\"alert-title\">\(alert.title)</p>\(blocks)</div>"
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
        var out = ""
        for segment in autolinkSegments(text.string) {
            switch segment {
            case .url(let url):
                let destination = url.hasPrefix("www.") ? "http://\(url)" : url
                out += "<a href=\"\(escape(destination))\">\(escape(url))</a>"
            case .plain(let plain):
                out += inlineSubstitutions(escape(plain))
            }
        }
        return out
    }

    /// Everything that rewrites plain prose, in the one order that composes: emoji first
    /// (its `:` delimiters can't collide with anything else), then footnote references,
    /// then the math sentinels planted before parsing, then punctuation compression, which
    /// must run last so it never inspects a character that later becomes markup.
    private mutating func inlineSubstitutions(_ escaped: String) -> String {
        var html = MarkdownEmoji.substitute(escaped)
        html = footnoteReferences(in: html)
        html = mathSentinels(in: html)
        return CJKPunctuation.compressed(html)
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
        let wasInsideLink = insideLink
        insideLink = true
        defer { insideLink = wasInsideLink }
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

    // MARK: Autolinks

    private enum TextSegment {
        case plain(String)
        case url(String)
    }

    /// swift-markdown attaches only the table, strikethrough and tasklist extensions, so
    /// cmark never autolinks bare URLs the way GitHub does. This finds them in text nodes:
    /// `http(s)://…` and `www.…` runs, ended at whitespace and trimmed of the trailing
    /// punctuation that belongs to the sentence rather than the link.
    private func autolinkSegments(_ raw: String) -> [TextSegment] {
        guard !insideLink, raw.contains("://") || raw.contains("www.") else { return [.plain(raw)] }
        var segments: [TextSegment] = []
        var plain = ""
        var rest = Substring(raw)

        while let start = rest.firstIndex(where: { $0 == "h" || $0 == "w" }) {
            let candidate = rest[start...]
            let isBoundary = start == rest.startIndex
                || !isURLBodyCharacter(rest[rest.index(before: start)])
            let scheme = ["https://", "http://", "www."].first { candidate.hasPrefix($0) }
            guard isBoundary, let scheme else {
                plain += rest[..<rest.index(after: start)]
                rest = rest[rest.index(after: start)...]
                continue
            }
            let end = candidate.firstIndex { $0.isWhitespace || $0 == "<" } ?? candidate.endIndex
            let url = trimTrailingPunctuation(candidate[..<end])
            guard url.count > scheme.count else {
                plain += rest[..<rest.index(after: start)]
                rest = rest[rest.index(after: start)...]
                continue
            }
            plain += rest[..<start]
            if !plain.isEmpty { segments.append(.plain(plain)); plain = "" }
            segments.append(.url(String(url)))
            rest = candidate[candidate.index(candidate.startIndex, offsetBy: url.count)...]
        }
        plain += rest
        if !plain.isEmpty { segments.append(.plain(plain)) }
        return segments
    }

    private func isURLBodyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "/@.-_".contains(character)
    }

    /// GFM's trailing rules: sentence punctuation after a link isn't part of it, and a
    /// closing paren only counts when the link opened one (`(see https://x.y/a_(b))`).
    private func trimTrailingPunctuation(_ url: Substring) -> Substring {
        var trimmed = url
        while let last = trimmed.last {
            if ".,;:!?\"'".contains(last) {
                trimmed = trimmed.dropLast()
            } else if last == ")" {
                let opens = trimmed.filter { $0 == "(" }.count
                let closes = trimmed.filter { $0 == ")" }.count
                if closes > opens { trimmed = trimmed.dropLast() } else { break }
            } else {
                break
            }
        }
        return trimmed
    }

    // MARK: Math

    private func displayMathOnly(_ p: Paragraph) -> MathSpan? {
        let text = p.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, text.first == MarkdownPreprocessor.sentinelOpen,
              text.last == MarkdownPreprocessor.sentinelClose,
              let index = Int(text.dropFirst().dropLast()), math.indices.contains(index),
              math[index].display
        else { return nil }
        return math[index]
    }

    private func renderedMath(_ span: MathSpan) -> String {
        guard let html = MarkdownScripting.math(span.tex, display: span.display) else {
            // KaTeX unavailable: the formula still has to be readable, so it degrades to
            // its own source rather than vanishing.
            return "<code class=\"math-source\">\(escape(span.tex))</code>"
        }
        return span.display ? "<div class=\"math math-display\">\(html)</div>" : html
    }

    private func mathSentinels(in escaped: String) -> String {
        guard escaped.contains(MarkdownPreprocessor.sentinelOpen) else { return escaped }
        var out = ""
        var rest = Substring(escaped)
        while let open = rest.firstIndex(of: MarkdownPreprocessor.sentinelOpen) {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: MarkdownPreprocessor.sentinelClose),
                  let index = Int(rest[afterOpen..<close]), math.indices.contains(index)
            else {
                rest = rest[afterOpen...]
                continue
            }
            out += renderedMath(math[index])
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    // MARK: Footnotes

    private mutating func footnoteReferences(in escaped: String) -> String {
        guard !footnotes.isEmpty, escaped.contains("[^") else { return escaped }
        var out = ""
        var rest = Substring(escaped)
        while let open = rest.range(of: "[^") {
            guard let close = rest[open.upperBound...].firstIndex(of: "]") else { break }
            let identifier = String(rest[open.upperBound..<close])
            guard footnotes.contains(where: { $0.identifier == identifier }) else {
                out += rest[..<open.upperBound]
                rest = rest[open.upperBound...]
                continue
            }
            out += rest[..<open.lowerBound]
            if !referencedFootnotes.contains(identifier) { referencedFootnotes.append(identifier) }
            let number = (referencedFootnotes.firstIndex(of: identifier) ?? 0) + 1
            let slug = escape(identifier)
            out += "<sup class=\"footnote-ref\" id=\"fnref-\(slug)\">"
                + "<a href=\"#fn-\(slug)\">\(number)</a></sup>"
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// The notes themselves, numbered by order of reference and rendered as Markdown in
    /// their own right. Definitions nobody referenced are dropped, as on GitHub.
    mutating func footnotesSection() -> String {
        guard !referencedFootnotes.isEmpty else { return "" }
        var items = ""
        for identifier in referencedFootnotes {
            guard let note = footnotes.first(where: { $0.identifier == identifier }) else { continue }
            let slug = escape(identifier)
            let body = MarkdownHTML.html(
                note.markdown, softBreaksAsBreaks: softBreaksAsBreaks, documentMode: documentMode)
            items += "<li id=\"fn-\(slug)\">\(body)"
                + "<a class=\"footnote-back\" href=\"#fnref-\(slug)\" aria-label=\"Back to content\">↩</a></li>"
        }
        return items.isEmpty ? "" : "<section class=\"footnotes\"><ol>\(items)</ol></section>"
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
        "picture", "source", "video",
    ]

    /// The useful subset of GitHub's `:all` attribute list plus its per-element ones.
    /// `style`, `class`, `id`, and event handlers are intentionally absent — GitHub
    /// strips those too. `autoplay` is absent by choice: a conversation that starts
    /// playing the moment it opens is hostile in a pane the user only glanced at.
    private static let allowedAttributes: Set<String> = [
        "href", "src", "srcset", "media", "alt", "title", "align", "valign", "width",
        "height", "border", "colspan", "rowspan", "open", "dir", "lang", "start", "type",
        "checked", "disabled", "datetime", "cite", "cellpadding", "cellspacing",
        "controls", "poster", "muted", "loop", "playsinline", "preload",
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
