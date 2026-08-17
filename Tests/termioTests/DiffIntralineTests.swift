import TermioShared
import XCTest
@testable import termio

/// The word-level intraline pass, pinned on the cases that motivated it: two edits in one
/// line must produce two spans (prefix/suffix stripping could only produce one, swallowing
/// everything between them), spans must not open or close on whitespace, CJK must not
/// collapse into a single line-long run, and a rewritten line must produce nothing at all.
final class DiffIntralineTests: XCTestCase {
    private func spans(_ old: String, _ new: String) -> (old: [String], new: [String])? {
        guard let result = DiffIntraline.spans(old: old, new: new) else { return nil }
        func texts(_ ranges: [Range<Int>], in text: String) -> [String] {
            let characters = Array(text)
            return ranges.map { String(characters[$0]) }
        }
        return (texts(result.old, in: old), texts(result.new, in: new))
    }

    func testSingleWordEditMarksOnlyThatWord() {
        let result = spans("let value = compute(input)", "let value = derive(input)")
        XCTAssertEqual(result?.old, ["compute"])
        XCTAssertEqual(result?.new, ["derive"])
    }

    func testTwoSeparateEditsProduceTwoSpans() {
        let result = spans("foo(alpha, beta)", "bar(alpha, gamma)")
        XCTAssertEqual(result?.old, ["foo", "beta"])
        XCTAssertEqual(result?.new, ["bar", "gamma"])
    }

    func testAdjacentEditsMergeAcrossUnchangedWhitespace() {
        let result = spans("let a = 1", "var b = 1")
        XCTAssertEqual(result?.old, ["let a"])
        XCTAssertEqual(result?.new, ["var b"])
    }

    func testSpanDoesNotOpenOnWhitespace() {
        let result = spans("call(one)", "call(one, two)")
        XCTAssertEqual(result?.old, [])
        // The inserted text is `, two` — the span starts at the comma, not at the space
        // that happens to precede `two`.
        XCTAssertEqual(result?.new, [", two"])
    }

    func testIndentOnlyChangeKeepsItsWhitespaceSpan() {
        let result = spans("  return x", "    return x")
        XCTAssertEqual(result?.old, ["  "])
        XCTAssertEqual(result?.new, ["    "])
    }

    /// A long insertion into a short line: the old side survives whole, so it is an edit,
    /// not a rewrite. Charging the inserted characters against the shorter line's budget
    /// classified this as a rewrite and dropped the span.
    func testLongInsertionIntoAShortLineIsStillMarked() {
        let result = spans("call()", "call(aVeryLongInsertedIdentifier)")
        XCTAssertEqual(result?.old, [])
        XCTAssertEqual(result?.new, ["aVeryLongInsertedIdentifier"])
    }

    /// The mirror case: a long deletion leaving a short line behind.
    func testLongDeletionLeavingAShortLineIsStillMarked() {
        let result = spans("call(aVeryLongInsertedIdentifier)", "call()")
        XCTAssertEqual(result?.old, ["aVeryLongInsertedIdentifier"])
        XCTAssertEqual(result?.new, [])
    }

    func testRewrittenLineIsNotMarked() {
        XCTAssertNil(spans("let greeting = \"hello\"",
                           "await database.commit(transaction, retries: 3)"))
    }

    func testIdenticalLinesAreNotMarked() {
        XCTAssertNil(spans("same", "same"))
    }

    /// CJK has no intra-word boundaries; tokenizing per ideograph is what keeps a
    /// one-character edit from marking the whole line.
    func testCJKMarksOnlyTheChangedCharacters() {
        let result = spans("会话已断开连接", "会话已恢复连接")
        XCTAssertEqual(result?.old, ["断开"])
        XCTAssertEqual(result?.new, ["恢复"])
    }

    /// Character offsets, not UTF-16 or byte offsets — the document maps them back itself.
    func testOffsetsAreCharacterOffsets() {
        let result = DiffIntraline.spans(old: "🎉 party time", new: "🎉 party hard")
        XCTAssertEqual(result?.new, [8..<12])
    }

    /// A line with hundreds of tokens must still return promptly, and a wholly rewritten
    /// one stays unmarked however long it is.
    func testTokenHeavyPairsStayUnmarked() {
        let old = (0..<400).map { "token\($0)" }.joined(separator: " ")
        let new = (0..<400).map { "value\($0)" }.joined(separator: " ")
        XCTAssertNil(DiffIntraline.spans(old: old, new: new))
    }

    /// A token-heavy line that still fits under the length cap: one rename in a hundred
    /// words must come back as one span, not as everything from the change to the end.
    func testLongLineMarksOnlyTheRenamedWord() {
        let old = "config = " + (0..<100).map { "field\($0)" }.joined(separator: ", ")
        let new = old.replacingOccurrences(of: "field7,", with: "renamed,")
        XCTAssertEqual(spans(old, new)?.new, ["renamed"])
    }

    func testOverlongLinesAreSkipped() {
        let long = String(repeating: "a", count: 2100)
        XCTAssertNil(DiffIntraline.spans(old: long, new: long + "b"))
    }
}
