import AppKit
import XCTest
@testable import termio

/// The two decisions on the clipboard side of the viewer↔device boundary.
///
/// Both have a real failure mode. Misreading the clipboard sends a text paste
/// down the transfer plane (or swallows a normal ⌘V), and a byte of drift in
/// the `U` chunk layout makes the daemon reject the frame outright — there is
/// no partial credit on a wire format, and the failure surfaces as a paste that
/// silently does nothing, which is the bug this whole path exists to end.
final class ClipboardTransferTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("sh.termio.tests.clipboard"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    /// A 1×1 image encoded the way the pasteboard would carry it.
    private func imageData(_ type: NSBitmapImageRep.FileType) -> Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)
        guard let representation,
              let data = representation.representation(using: type, properties: [:])
        else {
            XCTFail("could not build a \(type) fixture")
            return Data()
        }
        return data
    }

    func testPNGOnTheClipboardIsTakenVerbatim() {
        let png = imageData(.png)
        pasteboard.setData(png, forType: .png)

        let image = ClipboardImage.current(pasteboard)
        XCTAssertEqual(image?.data, png, "PNG travels as-is, not re-encoded")
        XCTAssertEqual(image?.fileExtension, "png")
    }

    /// A screenshot lands as PNG *and* TIFF. The far side wants a file an agent
    /// will open, so the flavor the client picks must not be whichever one the
    /// pasteboard happened to list first.
    func testAScreenshotsPNGIsPreferredOverItsTIFFTwin() {
        let png = imageData(.png)
        pasteboard.setData(imageData(.tiff), forType: .tiff)
        pasteboard.setData(png, forType: .png)

        XCTAssertEqual(ClipboardImage.current(pasteboard)?.data, png)
    }

    /// Only TIFF: re-encoded rather than shipped, because a `.png` name has to
    /// mean PNG bytes on the other machine.
    func testATIFFOnlyClipboardIsReencodedAsPNG() {
        pasteboard.setData(imageData(.tiff), forType: .tiff)

        let image = ClipboardImage.current(pasteboard)
        XCTAssertEqual(image?.fileExtension, "png")
        XCTAssertEqual(image?.data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                       "the re-encode must actually produce a PNG")
    }

    /// The rule libghostty's wrapper already applies locally, kept identical so
    /// the two layers cannot disagree about what a paste is: a clipboard that
    /// carries text is a text paste, whatever else rides along with it.
    func testAClipboardCarryingTextIsNeverATransfer() {
        pasteboard.setData(imageData(.png), forType: .png)
        pasteboard.setString("git status", forType: .string)

        XCTAssertNil(ClipboardImage.current(pasteboard))
    }

    func testAnEmptyClipboardIsNotATransfer() {
        XCTAssertNil(ClipboardImage.current(pasteboard))
    }

    /// Each paste gets its own name, so two screenshots in one session cannot
    /// collide on a dest the daemon would then refuse as conflicting content.
    func testEachPasteNamesItsOwnFile() {
        let image = ClipboardImage(data: Data([1]), fileExtension: "png")
        XCTAssertTrue(image.scratchFileName.hasPrefix("paste-"))
        XCTAssertTrue(image.scratchFileName.hasSuffix(".png"))
        XCTAssertFalse(image.scratchFileName.contains("/"), "a temp: name is one plain component")
    }

    /// `decode_upload_chunk` in termiod/src/protocol.rs, byte for byte.
    func testUploadChunkMatchesTheDaemonsLayout() {
        let payload = Termiod.uploadChunkPayload(
            uploadID: "u_2a", offset: 131_072, data: Data("pasted".utf8))

        XCTAssertEqual(payload, Data([4]) + Data("u_2a".utf8)
            + Data([0, 0, 0, 0, 0, 2, 0, 0])
            + Data("pasted".utf8))
    }

    /// The frame the chunk rides in is capped at 64 KiB by the daemon, and a
    /// client that overruns it gets the frame refused rather than truncated.
    func testAFullChunkStaysInsideTheFrameCap() {
        let payload = Termiod.uploadChunkPayload(
            uploadID: String(repeating: "u", count: 64),
            offset: 0,
            data: Data(count: Termiod.uploadChunkSize))

        XCTAssertLessThanOrEqual(payload.count, 64 * 1024)
    }
}
