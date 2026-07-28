import XCTest
@testable import termio

/// Pins the `OSC 9;4` progress parser (issue #23): the ConEmu busy/idle states map
/// correctly, the busy/idle transition fires only on a real flip, *every* flip in a
/// chunk is reported in order, the two OSC terminators (BEL and ST) both close a
/// sequence, sequences split across read chunks reassemble, and neighbouring OSC
/// forms (title, notification, palette) plus malformed/overlong payloads are all
/// rejected so nothing but a genuine progress report can move an agent's dot.
final class OSCProgressScannerTests: XCTestCase {
    /// Feeds each chunk and flattens every transition, in order.
    private func scan(_ chunks: [String]) -> [AgentStatusRules.Activity] {
        var scanner = OSCProgressScanner()
        return chunks.flatMap { scanner.scan(Data($0.utf8)) }
    }

    func testBusyThenIdle() {
        // Grok's native shape: `9;4;1;-1` busy while a turn runs, `9;4;0;` when done.
        XCTAssertEqual(
            scan(["\u{1B}]9;4;1;-1\u{07}", "\u{1B}]9;4;0;\u{07}"]),
            [.working, .idle])
    }

    func testIndeterminateStateIsWorking() {
        XCTAssertEqual(scan(["\u{1B}]9;4;3;\u{07}"]), [.working])
    }

    func testErrorAndPausedStatesAreIgnored() {
        // State 2 (error) and 4 (paused) are neither a clean busy nor idle edge.
        XCTAssertEqual(scan(["\u{1B}]9;4;2;50\u{07}"]), [])
        XCTAssertEqual(scan(["\u{1B}]9;4;4;\u{07}"]), [])
    }

    func testStringTerminatorClosesSequence() {
        // `9;4;3` opened with an ST (ESC \) instead of BEL.
        XCTAssertEqual(scan(["\u{1B}]9;4;3;\u{1B}\\"]), [.working])
    }

    func testKeepalivesInOneChunkCollapse() {
        // Consecutive duplicates within a single read collapse to one report.
        XCTAssertEqual(
            scan(["\u{1B}]9;4;1;-1\u{07}\u{1B}]9;4;1;-1\u{07}\u{1B}]9;4;1;-1\u{07}"]),
            [.working])
    }

    /// The scanner keeps no memory across reads: each chunk's keepalive is reported,
    /// and the *store* dedupes under the live-agent gate (`lastProgressActivity`).
    /// This is what lets a session promoted to Grok mid-stream pick the signal up
    /// after its first `working` was gate-rejected — a scanner that privately deduped
    /// would swallow the keepalives the promoted row needs.
    func testKeepalivesAcrossChunksAreEachReported() {
        XCTAssertEqual(
            scan(["\u{1B}]9;4;1;-1\u{07}", "\u{1B}]9;4;1;-1\u{07}", "\u{1B}]9;4;1;-1\u{07}"]),
            [.working, .working, .working])
    }

    /// A single PTY read can carry a whole fast turn — both edges must survive, in
    /// order, or the arbitration (keyed on the previous *delivered* state) drops both.
    func testBothTransitionsInOneChunkAreReported() {
        XCTAssertEqual(
            scan(["\u{1B}]9;4;1;-1\u{07}some output\u{1B}]9;4;0;\u{07}"]),
            [.working, .idle])
    }

    func testSequenceSplitAcrossChunks() {
        // The terminator lands in a later read than the introducer.
        XCTAssertEqual(scan(["\u{1B}]9;4", ";1;", "-1\u{07}"]), [.working])
    }

    func testTitleAndNotificationAndPaletteAreIgnored() {
        // OSC 0/2 title (with a Claude braille spinner), OSC 9 notification,
        // OSC 9;9 cwd, OSC 4 palette query — none is a 9;4 progress report.
        XCTAssertEqual(scan(["\u{1B}]2;\u{2801} building\u{07}"]), [])
        XCTAssertEqual(scan(["\u{1B}]9;done\u{07}"]), [])
        XCTAssertEqual(scan(["\u{1B}]9;9;/Users/me/repo\u{07}"]), [])
        XCTAssertEqual(scan(["\u{1B}]4;0;rgb:11/22/33\u{07}"]), [])
    }

    /// A notification whose body merely *starts* `4;<state>;` must not be mistaken for
    /// progress: the trailing field isn't numeric, and extra `;`-fields overrun the
    /// `9;4;state;progress` grammar.
    func testProgressLikeNotificationBodyIsRejected() {
        XCTAssertEqual(scan(["\u{1B}]9;4;1;this is a notification\u{07}"]), [])
        XCTAssertEqual(scan(["\u{1B}]9;4;1;-1;extra;fields\u{07}"]), [])
    }

    /// The busy states carry a progress field in the documented `0…100` range (plus
    /// Grok's `-1`). An out-of-range value, or no field at all, is not a progress
    /// report — which also narrows the OSC 9 notification collision.
    func testBusyStateValidatesProgressRange() {
        XCTAssertEqual(scan(["\u{1B}]9;4;1;100\u{07}"]), [.working]) // upper bound ok
        XCTAssertEqual(scan(["\u{1B}]9;4;1;0\u{07}"]), [.working])   // lower bound ok
        XCTAssertEqual(scan(["\u{1B}]9;4;1;101\u{07}"]), [])         // out of range
        XCTAssertEqual(scan(["\u{1B}]9;4;1;-2\u{07}"]), [])          // only -1 allowed
        XCTAssertEqual(scan(["\u{1B}]9;4;1\u{07}"]), [])             // busy needs a field
    }

    /// An overlong payload can't be a progress report, so it is rejected outright
    /// rather than classified from its truncated prefix.
    func testOverlongPayloadIsRejected() {
        let long = "9;4;1;" + String(repeating: "9", count: 64)
        XCTAssertEqual(scan(["\u{1B}]" + long + "\u{07}"]), [])
    }

    func testProgressAmidstOtherOutput() {
        // A busy report embedded in a burst of ordinary bytes still lands.
        XCTAssertEqual(
            scan(["hello\r\n\u{1B}]2;title\u{07}world \u{1B}]9;4;1;-1\u{07} more"]),
            [.working])
    }

    func testClassifyDirect() {
        XCTAssertEqual(OSCProgressScanner.classify(Array("9;4;0;".utf8)), .idle)
        XCTAssertEqual(OSCProgressScanner.classify(Array("9;4;0".utf8)), .idle) // clear needs no field
        XCTAssertEqual(OSCProgressScanner.classify(Array("9;4;1;-1".utf8)), .working)
        XCTAssertEqual(OSCProgressScanner.classify(Array("9;4;3;".utf8)), .working) // indeterminate, empty
        XCTAssertNil(OSCProgressScanner.classify(Array("9;4;3".utf8))) // busy needs a progress field
        XCTAssertNil(OSCProgressScanner.classify(Array("9;4".utf8)))
        XCTAssertNil(OSCProgressScanner.classify(Array("9;4;1;text".utf8)))
        XCTAssertNil(OSCProgressScanner.classify(Array("9;9;cwd".utf8)))
    }
}
