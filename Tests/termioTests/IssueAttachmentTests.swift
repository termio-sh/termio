import XCTest
@testable import termio

/// GitHub uploads a video as a bare attachment link, so the detail page has to recognize
/// that shape and only that shape — every other bare link in a conversation is prose.
final class IssueAttachmentTests: XCTestCase {
    func testBareAttachmentLinkBecomesPlayer() {
        let url = "https://github.com/user-attachments/assets/f65d6538-863f-40da-ae49-bea4d5fd15fd"
        XCTAssertEqual(
            IssueDetailHTML.embedAttachments("<p><a href=\"\(url)\">\(url)</a></p>"),
            "<video class=\"attachment\" controls preload=\"metadata\" src=\"\(url)\"></video>"
        )
    }

    func testLegacyUserImagesVideoBecomesPlayer() {
        let url = "https://user-images.githubusercontent.com/1/demo.mp4"
        XCTAssertTrue(
            IssueDetailHTML.embedAttachments("<p><a href=\"\(url)\">\(url)</a></p>")
                .hasPrefix("<video")
        )
    }

    func testOrdinaryLinksAreLeftAlone() {
        for url in [
            "https://github.com/termio-sh/termio/issues/272",
            "https://example.com/user-attachments/assets/1234",
            "https://user-images.githubusercontent.com/1/shot.png",
        ] {
            let paragraph = "<p><a href=\"\(url)\">\(url)</a></p>"
            XCTAssertEqual(IssueDetailHTML.embedAttachments(paragraph), paragraph)
        }
    }

    func testLinkedAttachmentInsideProseStaysALink() {
        let html = "<p>see <a href=\"https://github.com/user-attachments/assets/abc\">this</a> too</p>"
        XCTAssertEqual(IssueDetailHTML.embedAttachments(html), html)
    }

    /// The byte ranges a `<video>` element asks the asset loader for: playback stalls on any
    /// slice that comes back off by one, so each bound is pinned.
    func testByteRangesTheMediaLoaderSends() {
        XCTAssertEqual(GitHubAssetSchemeHandler.byteRange("bytes=0-1", count: 100), 0..<2)
        XCTAssertEqual(GitHubAssetSchemeHandler.byteRange("bytes=10-", count: 100), 10..<100)
        // An end past the last byte clamps rather than overruns the buffer.
        XCTAssertEqual(GitHubAssetSchemeHandler.byteRange("bytes=90-200", count: 100), 90..<100)
    }

    /// Everything else answers as the whole asset — a legal reply to any range request.
    func testUnrangedRequestsTakeTheWholeAsset() {
        XCTAssertNil(GitHubAssetSchemeHandler.byteRange(nil, count: 100))
        XCTAssertNil(GitHubAssetSchemeHandler.byteRange("bytes=-500", count: 100))
        XCTAssertNil(GitHubAssetSchemeHandler.byteRange("bytes=0-1,5-6", count: 100))
        XCTAssertNil(GitHubAssetSchemeHandler.byteRange("bytes=200-300", count: 100))
        XCTAssertNil(GitHubAssetSchemeHandler.byteRange("bytes=0-1", count: 0))
    }
}
