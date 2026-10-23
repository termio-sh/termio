import XCTest
@testable import termio

/// Cmd-click routing hinges on which preview a file gets. Images and PDFs stay in the in-app
/// preview, and so does video AVFoundation decodes; the other formats Quick Look already plays must not fall through to the
/// text editor, and must not be claimed by the in-app preview either.
final class FileActivationTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testImagesAndPDFsStayInTheInAppPreview() {
        for name in ["shot.png", "photo.JPEG", "page.pdf", "icon.svg", "note.html", "clip.mp4", "take.MOV"] {
            XCTAssertTrue(FileActivation.isPreviewable(url(name)), name)
            XCTAssertFalse(FileActivation.quickLooks(url(name)), name)
        }
    }

    func testUndecodableVideoAudioAndOfficeDocsGoToQuickLook() {
        for name in ["clip.webm", "clip.MKV", "song.mp3", "deck.pptx", "font.ttf"] {
            XCTAssertTrue(FileActivation.quickLooks(url(name)), name)
            XCTAssertFalse(FileActivation.isPreviewable(url(name)), name)
        }
    }

    func testSourceFilesGetNeitherPreview() {
        let source = url("App.swift")
        XCTAssertFalse(FileActivation.isPreviewable(source))
        XCTAssertFalse(FileActivation.quickLooks(source))
    }

    func testOnlyDecodableMoviesPlayInApp() {
        for name in ["clip.mp4", "take.MOV", "screen.m4v"] {
            XCTAssertTrue(FileActivation.isVideo(url(name)), name)
        }
        for name in ["clip.webm", "clip.mkv", "song.mp3", "shot.png"] {
            XCTAssertFalse(FileActivation.isVideo(url(name)), name)
        }
    }
}
