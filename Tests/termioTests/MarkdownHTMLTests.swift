import XCTest
@testable import termio

/// The document-mode HTML whitelist: the boundary where README markup becomes real
/// layout while script vectors must die. Each case pins one edge of that boundary.
final class HTMLSanitizerTests: XCTestCase {
    func testWhitelistedLayoutTablePassesThrough() {
        let html = #"<table><tr><td width="50%" valign="middle"><img src="web/shot.png" alt="a" width="100%" /></td></tr></table>"#
        let out = HTMLSanitizer.sanitize(html)
        XCTAssertEqual(
            out,
            #"<table><tr><td width="50%" valign="middle"><img src="web/shot.png" alt="a" width="100%"></td></tr></table>"#
        )
    }

    func testScriptAndHandlersDie() {
        XCTAssertEqual(
            HTMLSanitizer.sanitize("<script>alert(1)</script>"),
            "&lt;script&gt;alert(1)&lt;/script&gt;"
        )
        // The tag survives; the handler, style, and class do not.
        XCTAssertEqual(
            HTMLSanitizer.sanitize(#"<img src="x.png" onerror="alert(1)" style="x" class="y">"#),
            #"<img src="x.png">"#
        )
    }

    func testVideoKeepsItsPlayerAttributesButNeverAutoplays() {
        XCTAssertEqual(
            HTMLSanitizer.sanitize(#"<video src="a.mp4" controls muted autoplay poster="p.png">"#),
            #"<video src="a.mp4" controls muted poster="p.png">"#
        )
    }

    func testJavascriptURLsDropped() {
        XCTAssertEqual(HTMLSanitizer.sanitize(#"<a href="javascript:alert(1)">x</a>"#), "<a>x</a>")
        XCTAssertEqual(HTMLSanitizer.sanitize(#"<img src="data:text/html,x">"#), "<img>")
    }

    func testCommentsDropAndDetailsKeepOpen() {
        XCTAssertEqual(
            HTMLSanitizer.sanitize("<!-- hidden -->\n<details open><summary>t</summary></details>"),
            "\n<details open><summary>t</summary></details>"
        )
    }

    func testSafeURL() {
        XCTAssertTrue(HTMLSanitizer.safeURL("https://x.y/z", allowRelative: false))
        XCTAssertTrue(HTMLSanitizer.safeURL("docs/a.png", allowRelative: true))
        XCTAssertTrue(HTMLSanitizer.safeURL("#anchor", allowRelative: true))
        XCTAssertFalse(HTMLSanitizer.safeURL("docs/a.png", allowRelative: false))
        XCTAssertFalse(HTMLSanitizer.safeURL("javascript:x", allowRelative: true))
        XCTAssertFalse(HTMLSanitizer.safeURL("JAVASCRIPT:x", allowRelative: true))
    }

    func testDocumentModeImageAndTranscriptPlaceholder() {
        let md = "![shot](web/shot.png)"
        XCTAssertTrue(
            MarkdownHTML.html(md, documentMode: true).contains(#"<img src="web/shot.png" alt="shot">"#))
        XCTAssertTrue(MarkdownHTML.html(md).contains("🖼 shot"))
    }

    func testTranscriptModeStillEscapesRawHTML() {
        XCTAssertFalse(MarkdownHTML.html("<table><tr><td>x</td></tr></table>").contains("<table>"))
    }
}

/// The GitHub-flavored constructs cmark-gfm doesn't give us: anchors, autolinks, alerts,
/// emoji, footnotes, math and highlighted fences. Each case pins the behavior a document
/// written for GitHub expects to see in the reader.
final class MarkdownGitHubFeatureTests: XCTestCase {
    // MARK: Heading anchors

    func testHeadingsGetSlugIDsAndDeduplicate() {
        let html = MarkdownHTML.html("# Design Notes\n\n## Design Notes\n", documentMode: true)
        XCTAssertTrue(html.contains(#"<h1 id="design-notes">"#))
        XCTAssertTrue(html.contains(#"<h2 id="design-notes-1">"#))
    }

    func testHeadingSlugDropsPunctuationAndKeepsCase() {
        let html = MarkdownHTML.html("### What's *new* in v0.34?\n", documentMode: true)
        XCTAssertTrue(html.contains(#"id="whats-new-in-v034""#), html)
    }

    // MARK: Autolinks

    func testBareURLBecomesALink() {
        let html = MarkdownHTML.html("See https://termio.sh/docs for more.")
        XCTAssertTrue(html.contains(#"<a href="https://termio.sh/docs">https://termio.sh/docs</a>"#), html)
    }

    func testTrailingSentencePunctuationStaysOutsideTheLink() {
        let html = MarkdownHTML.html("Read https://termio.sh/docs.")
        XCTAssertTrue(html.contains(#"<a href="https://termio.sh/docs">"#), html)
        XCTAssertTrue(html.hasSuffix(".</p>"), html)
    }

    func testWWWLinksGetAScheme() {
        XCTAssertTrue(MarkdownHTML.html("www.termio.sh").contains(#"<a href="http://www.termio.sh">"#))
    }

    func testAutolinkNeverNestsInsideAMarkdownLink() {
        let html = MarkdownHTML.html("[https://a.example](https://b.example)")
        XCTAssertEqual(html, #"<p><a href="https://b.example">https://a.example</a></p>"#)
    }

    func testEmailsAndBareWordsAreNotLinked() {
        XCTAssertFalse(MarkdownHTML.html("write to hi@termio.sh").contains("<a "))
        XCTAssertFalse(MarkdownHTML.html("the whole thing").contains("<a "))
    }

    // MARK: Alerts

    func testAlertRendersAsATitledBlock() {
        let html = MarkdownHTML.html("> [!WARNING]\n> Do not ship this.\n", documentMode: true)
        XCTAssertTrue(html.contains(#"<div class="alert alert-warning">"#), html)
        XCTAssertTrue(html.contains(#"<p class="alert-title">Warning</p>"#), html)
        XCTAssertTrue(html.contains("<p>Do not ship this.</p>"), html)
        XCTAssertFalse(html.contains("[!WARNING]"), html)
    }

    func testAlertKeepsLaterBlocksAndPlainQuotesAreUntouched() {
        let alert = MarkdownHTML.html("> [!NOTE]\n> First.\n>\n> - second\n", documentMode: true)
        // The blank line makes it a loose list, so the item keeps its paragraph.
        XCTAssertTrue(alert.contains("<ul><li><p>second</p></li></ul>"), alert)
        let quote = MarkdownHTML.html("> just a quote\n", documentMode: true)
        XCTAssertTrue(quote.contains("<blockquote><p>just a quote</p></blockquote>"), quote)
    }

    // MARK: Emoji

    func testEmojiShortcodesSubstitute() {
        XCTAssertTrue(MarkdownHTML.html("ship it :rocket:").contains("🚀"))
        XCTAssertTrue(MarkdownHTML.html("meet at 10:30 tomorrow").contains("10:30"))
        XCTAssertTrue(MarkdownHTML.html("`:rocket:` stays").contains("<code>:rocket:</code>"))
    }

    // MARK: Footnotes

    func testFootnotesNumberByReferenceOrder() {
        let source = """
        Second claim.[^b] First claim.[^a]

        [^a]: The A note.
        [^b]: The B note.
        """
        let html = MarkdownHTML.html(source, documentMode: true)
        XCTAssertTrue(html.contains(##"<sup class="footnote-ref" id="fnref-b"><a href="#fn-b">1</a></sup>"##), html)
        XCTAssertTrue(html.contains(##"<sup class="footnote-ref" id="fnref-a"><a href="#fn-a">2</a></sup>"##), html)
        XCTAssertTrue(html.contains(#"<section class="footnotes">"#), html)
        XCTAssertTrue(html.contains(#"<li id="fn-b">"#), html)
        // The definitions never reach the prose, either as text or as cmark link
        // reference definitions.
        XCTAssertFalse(html.contains("[^a]"), html)
        XCTAssertFalse(html.contains("]: The A note."), html)
    }

    func testUnreferencedFootnoteIsDropped() {
        let html = MarkdownHTML.html("Nothing here.\n\n[^x]: orphan\n", documentMode: true)
        XCTAssertFalse(html.contains("footnotes"), html)
        XCTAssertFalse(html.contains("orphan"), html)
    }

    // MARK: Math

    func testInlineAndDisplayMathRenderAsMathML() {
        let inline = MarkdownHTML.html("The identity $E = mc^2$ holds.", documentMode: true)
        XCTAssertTrue(inline.contains("<math"), inline)
        XCTAssertFalse(inline.contains("$"), inline)

        let display = MarkdownHTML.html("$$\\sum_{i=1}^{n} i$$", documentMode: true)
        XCTAssertTrue(display.contains(#"<div class="math math-display">"#), display)
        // Display math owns its line; it is never wrapped in a paragraph.
        XCTAssertFalse(display.hasPrefix("<p>"), display)
    }

    func testMathFenceRenders() {
        let html = MarkdownHTML.html("```math\n\\frac{a}{b}\n```", documentMode: true)
        XCTAssertTrue(html.contains(#"<div class="math math-display">"#), html)
    }

    func testDollarsInProseAndCodeAreNotMath() {
        let prose = MarkdownHTML.html("It costs $5 and $6 total.", documentMode: true)
        XCTAssertTrue(prose.contains("$5 and $6"), prose)
        let code = MarkdownHTML.html("run `echo $PATH` first", documentMode: true)
        XCTAssertTrue(code.contains("<code>echo $PATH</code>"), code)
        let fence = MarkdownHTML.html("```sh\necho $HOME $USER\n```", documentMode: true)
        XCTAssertTrue(fence.contains("$HOME"), fence)
    }

    // MARK: Code fences

    func testKnownLanguageIsHighlightedAndUnknownIsNot() {
        let swift = MarkdownHTML.html("```swift\nlet x = 1\n```", documentMode: true)
        XCTAssertTrue(swift.contains("hljs-keyword"), swift)
        XCTAssertTrue(swift.contains(#"class="language-swift hljs""#), swift)

        let unknown = MarkdownHTML.html("```notalanguage\nlet x = 1\n```", documentMode: true)
        XCTAssertFalse(unknown.contains("hljs-"), unknown)
        XCTAssertTrue(unknown.contains("let x = 1"), unknown)
    }

    func testHighlightedCodeStillEscapes() {
        let html = MarkdownHTML.html("```html\n<script>x</script>\n```", documentMode: true)
        XCTAssertFalse(html.contains("<script>"), html)
    }
}

/// End-to-end pass over `Fixtures/markdown-features.md`, the sheet used to judge the
/// reader by eye. The unit cases above pin each construct; this one pins that a real
/// document exercising all of them at once leaks no source markers.
final class MarkdownFeatureSheetTests: XCTestCase {
    private func featureSheet() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "markdown-features", withExtension: "md",
                              subdirectory: "Fixtures"),
            "the feature sheet is missing from the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testFeatureSheetLeavesNoSourceMarkers() throws {
        let html = MarkdownHTML.html(try featureSheet(), softBreaksAsBreaks: false, documentMode: true)
        for marker in ["[!NOTE]", "[!WARNING]", "$$", "[^anti100x]", "[^boundaries]:"] {
            XCTAssertFalse(html.contains(marker), "\(marker) survived into the output")
        }
        // The sheet's one surviving `:rocket:` is the deliberate one inside a code span.
        XCTAssertTrue(html.contains("<code>:rocket:</code>"))
        XCTAssertFalse(
            html.replacingOccurrences(of: "<code>:rocket:</code>", with: "").contains(":rocket:"),
            "an emoji shortcode outside code survived into the output")
    }

    func testFeatureSheetRendersEveryConstruct() throws {
        let html = MarkdownHTML.html(try featureSheet(), softBreaksAsBreaks: false, documentMode: true)
        for fragment in [
            #"<h2 id="alerts">"#,          // heading anchors
            #"id="mermaid-diagrams""#,     // the sheet's own TOC links resolve
            #"id="duplicate-1""#,          // slug de-duplication
            "<h6 id=",                     // every heading level
            "alert alert-caution",         // all five alert kinds present
            "🚀",                          // emoji shortcodes
            "hljs-keyword",                // fenced-code highlighting
            "<math",                       // KaTeX MathML
            #"<div class="math math-display">"#,
            #"<section class="footnotes">"#,
            #"<a href="https://github.com/termio-sh/termio">"#,  // bare-URL autolink
            #"<a href="http://www.termio.sh">"#,
            #"<a href="mailto:hi@termio.sh">"#,
            #"<a href="../MarkdownHTMLTests.swift">"#,           // relative link
            "<ol>", "<ul>",                // ordered, unordered and nested lists
            #"<li class="task">"#,
            "<table>", "<thead>",          // GFM table
            #"<img src="../../../packaging/AppIcon.png""#,
            "<details", "<summary>",       // whitelisted raw HTML
            #"<td width="50%">"#,          // the README layout-table idiom
            "<kbd>", "<sub>", "<sup>",
            "<hr>",
            "<blockquote><p>A quote inside a quote.</p></blockquote>",  // nested quote
        ] {
            XCTAssertTrue(html.contains(fragment), "\(fragment) is missing from the output")
        }
        // Prose that merely looks like markup stays prose.
        XCTAssertTrue(html.contains("costs $5 and $6"), "prose dollars were eaten by math")
        XCTAssertTrue(html.contains("10:30"), "a clock time was eaten by emoji substitution")
        XCTAssertTrue(html.contains("*not emphasis*"), "a backslash escape was not honored")
        XCTAssertFalse(html.contains("<script>"), "a script tag survived the sanitizer")
    }

    /// The sheet's two diagrams, through the full pipeline: found in the built page, drawn
    /// by the offscreen engine, swapped back in as SVG.
    @MainActor
    func testFeatureSheetDiagramsRenderToSVG() async throws {
        let theme = MermaidRenderer.Theme(TraceTheme.builtin(dark: true))
        let document = MarkdownHTML.html(
            try featureSheet(), softBreaksAsBreaks: false, documentMode: true)
        let sources = MermaidRenderer.sources(in: document)
        XCTAssertEqual(sources.count, 2, "the sheet should hold a flowchart and a sequence diagram")

        let drawn = await MermaidRenderer.shared.diagrams(for: sources, theme: theme)
        try XCTSkipIf(drawn.isEmpty, "no window server to run the mermaid harness in")
        XCTAssertEqual(drawn.count, 2)

        let rendered = MermaidRenderer.applying(drawn, to: document)
        XCTAssertTrue(rendered.contains(#"<figure class="mermaid"><svg"#), "diagrams were not swapped in")
        XCTAssertFalse(rendered.contains(#"class="language-mermaid"#), "a fence survived the swap")
        // What the renderer refuses to hand back, restated as an assertion about output
        // that lands in a page which can read local files.
        for marker in ["<script", "javascript:", "<foreignObject", "onload="] {
            XCTAssertFalse(rendered.contains(marker), "\(marker) reached the page")
        }
    }
}

/// Which typographic register a document is set in. CSS can't tell Han from Latin inside a
/// paragraph, so the reader decides once per document from the source; these pin where the
/// line falls.
final class ReaderScriptDetectionTests: XCTestCase {
    private let theme = TraceTheme.builtin(dark: true)

    func testChineseProseIsCJK() {
        XCTAssertTrue(MarkdownReaderRenderer.isCJK(
            "会话活在机器上,而不是连接里。断开不等于杀死,agent 会继续工作。"))
    }

    func testEnglishProseIsNot() {
        XCTAssertFalse(MarkdownReaderRenderer.isCJK(
            "The session lives on the box, not in the connection. Detach is not kill."))
    }

    func testAnEnglishDocumentQuotingOneTermKeepsTheLatinRegister() {
        let source = String(
            repeating: "Byte delivery never blocks on the host-side VT parse. ", count: 8)
            + "The docs call this 旁路."
        XCTAssertFalse(MarkdownReaderRenderer.isCJK(source), "one quoted term flipped the register")
    }

    func testJapaneseAndKoreanCount() {
        XCTAssertTrue(MarkdownReaderRenderer.isCJK("セッションはマシン上で生きている"))
        XCTAssertTrue(MarkdownReaderRenderer.isCJK("세션은 기계에서 살아 있습니다"))
    }

    func testBodyClassCarriesTheDecision() {
        let chinese = MarkdownReaderRenderer.document(
            "# 设计\n\n会话活在机器上,断开不等于杀死。\n", theme: theme, fontFamily: "",
            embedFonts: false)
        XCTAssertTrue(chinese.contains(#"<body class="reader cjk">"#), "the CJK class is missing")

        let english = MarkdownReaderRenderer.document(
            "# Design\n\nThe session lives on the box.\n", theme: theme, fontFamily: "",
            embedFonts: false)
        XCTAssertTrue(english.contains(#"<body class="reader">"#), "an English document was set as CJK")
    }
}

/// 标点挤压: a full-width mark that runs into another one gets pulled back, and nothing
/// else does. Over-compression is the failure mode worth guarding — it costs an ordinary
/// sentence its rhythm — so most of these pin what is *not* touched.
final class CJKPunctuationTests: XCTestCase {
    func testAdjacentMarksCompress() {
        XCTAssertEqual(
            CJKPunctuation.compressed("里。（断开）"),
            #"里<span class="punctuation-half">。</span>（断开）"#)
        XCTAssertEqual(
            CJKPunctuation.compressed("（断开）。"),
            #"（断开<span class="punctuation-half">）</span>。"#)
    }

    func testCurlyQuotesAndMiddotsCompressByAQuarter() {
        XCTAssertEqual(
            CJKPunctuation.compressed("说。“好”"),
            #"说<span class="punctuation-quarter">。</span>“好”"#)
        XCTAssertEqual(
            CJKPunctuation.compressed("甲·（乙）"),
            #"甲<span class="punctuation-quarter">·</span>（乙）"#)
    }

    func testLonePunctuationIsUntouched() {
        XCTAssertEqual(CJKPunctuation.compressed("会话活在机器上，而不是连接里。"),
                       "会话活在机器上，而不是连接里。")
        XCTAssertEqual(CJKPunctuation.compressed("（断开）不等于杀死"), "（断开）不等于杀死")
    }

    func testLatinTextIsUntouched() {
        let latin = "The session lives on the box, not in the connection. (Detach.)"
        XCTAssertEqual(CJKPunctuation.compressed(latin), latin)
    }

    func testCodeKeepsItsExactCharacters() {
        // Compression runs on prose text nodes only; a code span is never a text node.
        let html = MarkdownHTML.html("`（a）。（b）` 与 里。（外）", documentMode: true)
        XCTAssertTrue(html.contains("<code>（a）。（b）</code>"), html)
        XCTAssertTrue(html.contains(#"<span class="punctuation-half">。</span>"#), html)
    }
}

/// The pure half of diagram rendering — finding fences and swapping them — which every
/// surface shares and which needs no web view to test.
final class MermaidSubstitutionTests: XCTestCase {
    private let markdown = "before\n\n```mermaid\ngraph LR\n  A --> B\n```\n\nafter\n"

    func testFenceIsFoundWithItsSourceUnescaped() {
        let html = MarkdownHTML.html(markdown, softBreaksAsBreaks: false, documentMode: true)
        XCTAssertEqual(MermaidRenderer.sources(in: html), ["graph LR\n  A --> B"])
    }

    func testEscapedCharactersSurviveTheRoundTrip() {
        let source = "graph LR\n  A[\"a & b\"] --> B[\"<c>\"]"
        let html = MarkdownHTML.html("```mermaid\n\(source)\n```", documentMode: true)
        XCTAssertEqual(MermaidRenderer.sources(in: html), [source])
    }

    func testDiagramReplacesItsFence() {
        let html = MarkdownHTML.html(markdown, softBreaksAsBreaks: false, documentMode: true)
        let svg = "<svg id=\"x\"><g></g></svg>"
        let out = MermaidRenderer.applying(["graph LR\n  A --> B": svg], to: html)
        XCTAssertTrue(out.contains("<figure class=\"mermaid\">\(svg)</figure>"), out)
        XCTAssertFalse(out.contains("language-mermaid"), out)
        XCTAssertTrue(out.contains("<p>before</p>"), out)
    }

    func testUndrawnFenceKeepsItsSource() {
        let html = MarkdownHTML.html(markdown, softBreaksAsBreaks: false, documentMode: true)
        XCTAssertEqual(MermaidRenderer.applying([:], to: html), html)
        // A stale set from a previous document substitutes nothing in this one.
        XCTAssertEqual(MermaidRenderer.applying(["graph TD\n  X --> Y": "<svg/>"], to: html), html)
    }

    func testOnlyMermaidFencesAreTouched() {
        let html = MarkdownHTML.html("```swift\nlet x = 1\n```", documentMode: true)
        XCTAssertTrue(MermaidRenderer.sources(in: html).isEmpty)
    }
}
