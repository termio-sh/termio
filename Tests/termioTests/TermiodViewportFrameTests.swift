import XCTest
import TermioShared
@testable import termio

/// The `R` frame, which stopped meaning "set the PTY size" and started meaning
/// "this attachment's viewport is now N×M"
/// (`docs/design/20260901-pty-size-is-not-the-write-token.md`).
///
/// The payload's layout is the compatibility story, so it is the thing worth
/// pinning: a rendering attachment writes v0's exact four bytes, and only the
/// one state v0 has no policy for — an attachment that has stopped rendering —
/// costs a fifth. A daemon that predates the flags byte reads a payload of any
/// other length as a malformed frame and drops the connection, which is why the
/// five-byte form is gated on the host offering `viewport`.
final class TermiodViewportFrameTests: XCTestCase {
    func testARenderingViewportIsBytewiseTheOldResizeFrame() {
        XCTAssertEqual(
            Array(Termiod.viewportPayload(rows: 40, cols: 120)),
            [0, 40, 0, 120])
    }

    func testStoppingRenderingCostsOneFlagsByte() {
        XCTAssertEqual(
            Array(Termiod.viewportPayload(rows: 40, cols: 120, rendering: false)),
            [0, 40, 0, 120, 0])
    }

    /// Zero in either dimension is how a window that has not laid out yet says
    /// it has no viewport at all — counted by nobody, rather than squeezing
    /// every other viewer to a stand-in grid until the first layout pass lands.
    func testAnUnlaidOutWindowDeclaresZero() {
        XCTAssertEqual(
            Array(Termiod.viewportPayload(rows: 0, cols: 0)),
            [0, 0, 0, 0])
    }

    /// The capability is what tells the two forms apart on the wire, so an
    /// attach channel has to actually ask for it.
    func testTheAttachChannelAsksForTheSizePolicy() {
        XCTAssertTrue(Termiod.attachCapabilities.contains(Termiod.viewportCapability))
    }
}
