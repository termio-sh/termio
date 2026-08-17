import XCTest
@testable import termio

/// The editor's pure text logic: line/offset mapping and bracket pairing. These are the pieces
/// where a silent off-by-one becomes "revealed the wrong line" — cheap to pin down.
final class TextPositionsTests: XCTestCase {
    func testOffsetOfLineWalksAndClamps() {
        let text = "one\ntwo\nthree\n" as NSString
        XCTAssertEqual(TextPositions.offset(ofLine: 1, in: text), 0)
        XCTAssertEqual(TextPositions.offset(ofLine: 2, in: text), 4)
        XCTAssertEqual(TextPositions.offset(ofLine: 3, in: text), 8)
        // Past the end: clamps into the document instead of running off it.
        XCTAssertLessThan(TextPositions.offset(ofLine: 99, in: text), text.length)
    }

    /// Multi-byte content doesn't shift the mapping: `offset(ofLine:)` counts UTF-16 units, the
    /// same unit `NSTextView` selections use.
    func testOffsetOfLineCountsUTF16Units() {
        let text = "alpha\nβeta 🙂\ngamma" as NSString
        XCTAssertEqual(TextPositions.offset(ofLine: 2, in: text), 6)
        // "🙂" is a surrogate pair, so line 3 starts 8 units after line 2, not 7.
        XCTAssertEqual(TextPositions.offset(ofLine: 3, in: text), 14)
    }
}

final class BracketMatcherTests: XCTestCase {
    func testSimplePair() {
        let text = "f(x)" as NSString
        XCTAssertEqual(BracketMatcher.match(at: 1, in: text), 3)
        XCTAssertEqual(BracketMatcher.match(at: 3, in: text), 1)
    }

    func testNestedPairsSkipInnerLevels() {
        let text = "{ a: [1, (2)], b: {} }" as NSString
        XCTAssertEqual(BracketMatcher.match(at: 0, in: text), 21)
        XCTAssertEqual(BracketMatcher.match(at: 5, in: text), 12) // [ … ]
        XCTAssertEqual(BracketMatcher.match(at: 9, in: text), 11) // ( … )
    }

    func testEachKindCountsOnlyItself() {
        // Interleaved kinds: the scanner tracks one pair-kind at a time (the standard
        // lightweight-editor behavior — strict cross-kind nesting would need a full parser
        // and get fooled by brackets in strings far more often than this does).
        let text = "([)]" as NSString
        XCTAssertEqual(BracketMatcher.match(at: 0, in: text), 2) // ( … )
        XCTAssertEqual(BracketMatcher.match(at: 1, in: text), 3) // [ … ]
    }

    func testUnbalancedReturnsNil() {
        let text = "((a)" as NSString
        XCTAssertNil(BracketMatcher.match(at: 0, in: text))
        XCTAssertEqual(BracketMatcher.match(at: 1, in: text), 3)
    }

    func testNonBracketAndOutOfBounds() {
        let text = "abc" as NSString
        XCTAssertNil(BracketMatcher.match(at: 1, in: text))
        XCTAssertNil(BracketMatcher.match(at: -1, in: text))
        XCTAssertNil(BracketMatcher.match(at: 3, in: text))
    }
}
