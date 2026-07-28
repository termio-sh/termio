import XCTest
@testable import termio

/// Pins the `OSC 9;4` progress parser (issue #23): the ConEmu busy/idle states map
/// correctly, the busy/idle transition fires only on a real flip, the two OSC
/// terminators (BEL and ST) both close a sequence, sequences split across read
/// chunks reassemble, and neighbouring OSC forms (title, notification, palette) are
/// ignored so nothing but a genuine progress report can move an agent's dot.
final class OSCProgressScannerTests: XCTestCase {
    private func scan(_ chunks: [String]) -> [AgentStatusRules.Activity] {
        var scanner = OSCProgressScanner()
        return chunks.compactMap { scanner.scan(Data($0.utf8)) }
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

    func testRepeatedBusyKeepalivesCollapseToOneTransition() {
        XCTAssertEqual(
            scan(["\u{1B}]9;4;1;-1\u{07}", "\u{1B}]9;4;1;-1\u{07}", "\u{1B}]9;4;1;-1\u{07}"]),
            [.working])
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

    func testProgressAmidstOtherOutput() {
        // A busy report embedded in a burst of ordinary bytes still lands.
        XCTAssertEqual(
            scan(["hello\r\n\u{1B}]2;title\u{07}world \u{1B}]9;4;1;-1\u{07} more"]),
            [.working])
    }

    func testClassifyDirect() {
        XCTAssertEqual(OSCProgressScanner.classify(Array("9;4;0;".utf8)), .idle)
        XCTAssertEqual(OSCProgressScanner.classify(Array("9;4;1;-1".utf8)), .working)
        XCTAssertNil(OSCProgressScanner.classify(Array("9;4".utf8)))
        XCTAssertNil(OSCProgressScanner.classify(Array("9;9;cwd".utf8)))
    }
}
