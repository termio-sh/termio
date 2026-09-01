import XCTest
import TermioShared
@testable import termio

/// Which keyframes a termiod attachment is allowed to paint.
///
/// The daemon's `S` payload is a formatted repaint — wrapped rows and all — laid
/// out for the grid the host VT held when it was taken. Painting one that
/// *overflows* the surface shifts every wrapped row, and an incrementally
/// redrawing TUI never repairs it, so the damage sits on screen until the next
/// keystroke. One that fits paints right: under the per-axis-min size policy the
/// PTY never outgrows a declared viewport, so the only overflowing keyframe is
/// one taken before this client's own shrinking declaration was applied — and
/// that declaration's barrier will push a fresh keyframe that fits. Who holds
/// the write token plays no part; the token gates input, not size.
final class TermiodKeyframeGridTests: XCTestCase {
    private let surface = TerminalGrid(rows: 40, cols: 100)

    func testAKeyframeWiderThanTheSurfaceIsStale() {
        XCTAssertTrue(TermiodSessionLink.snapshotIsStale(
            payload: TerminalGrid(rows: 37, cols: 154),
            target: surface))
    }

    func testAKeyframeTallerThanTheSurfaceIsStale() {
        XCTAssertTrue(TermiodSessionLink.snapshotIsStale(
            payload: TerminalGrid(rows: 47, cols: 54),
            target: surface))
    }

    func testAMatchingKeyframePaints() {
        XCTAssertFalse(TermiodSessionLink.snapshotIsStale(
            payload: surface,
            target: surface))
    }

    /// The steady state under min: another rendering viewport is smaller, the
    /// PTY sits at its grid, and this wider surface paints the content with the
    /// remainder blank — dropping it would leave the pane permanently stale,
    /// because nothing this client does will produce another `S`.
    func testASmallerKeyframePaints() {
        XCTAssertFalse(TermiodSessionLink.snapshotIsStale(
            payload: TerminalGrid(rows: 37, cols: 54),
            target: surface))
    }

    /// A single column apart is the case that matters: it is invisible in a log
    /// line and it wraps every full-width row one cell early.
    func testOneColumnOfOverflowIsStale() {
        XCTAssertTrue(TermiodSessionLink.snapshotIsStale(
            payload: TerminalGrid(rows: 40, cols: 101),
            target: surface))
    }
}
