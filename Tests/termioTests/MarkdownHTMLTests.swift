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
