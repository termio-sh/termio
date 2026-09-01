import XCTest
@testable import termio

/// What the Search pane draws once the daemon has answered.
///
/// The matcher itself is host-side — `files.rs` pins smart case and windowing.
/// What stays here is everything the pane does with the hits afterwards: folding
/// them into runs of real lines, and turning the byte offsets the host measured
/// into ranges of the text this Mac paints. Both are client code on every
/// machine, so both are tested here rather than in the daemon.
final class SearchExcerptTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo", isDirectory: true)

    /// A hit as the pane builds one from `fs.search`, with the query's span
    /// located the way the host reports it — literally, not re-searched with a
    /// second rule.
    private func match(_ text: String, hitting query: String? = nil, line: Int = 10,
                       before: [String] = [], after: [String] = []) -> ContentMatch {
        var spans: [Range<String.Index>] = []
        if let query, let found = text.range(of: query) { spans = [found] }
        return ContentMatch(
            relative: "a.swift", url: root.appendingPathComponent("a.swift"),
            line: line, text: text, spans: spans, isWindowed: false,
            before: before, after: after)
    }

    // MARK: - Excerpt composition

    /// Two hits close enough that their context overlaps are one run of lines,
    /// not two — reading the same context twice with a divider through it is
    /// worse than reading it once.
    func testNearbyHitsMergeIntoOneRun() {
        let first = match("hit one", hitting: "hit", line: 10,
                          before: ["a", "b"], after: ["c", "d"])
        let second = match("hit two", hitting: "hit", line: 13,
                           before: ["c", "d"], after: ["e", "f"])

        let excerpts = SearchExcerpt.compose([first, second])

        XCTAssertEqual(excerpts.count, 1, "overlapping context is one excerpt")
        let numbers = excerpts[0].lines.map(\.number)
        XCTAssertEqual(numbers, Array(8...15), "each line once, in order")
        XCTAssertEqual(excerpts[0].lines.filter(\.isMatch).map(\.number), [10, 13])
    }

    /// Hits far apart stay separate runs, so the gap between them can be shown.
    func testDistantHitsStaySeparateRuns() {
        let first = match("hit one", hitting: "hit", line: 10,
                          before: ["a"], after: ["b"])
        let second = match("hit two", hitting: "hit", line: 90,
                           before: ["c"], after: ["d"])

        XCTAssertEqual(SearchExcerpt.compose([first, second]).count, 2)
    }

    /// A line that arrives first as somebody else's context and later as a hit
    /// has to end up drawn as the hit, or the match goes unpainted.
    func testAContextLineThatIsAlsoAHitBecomesTheHit() {
        let first = match("alpha", hitting: "beta", line: 10, before: [], after: ["beta here"])
        let second = match("beta here", hitting: "beta", line: 11)

        let excerpts = SearchExcerpt.compose([first, second])

        XCTAssertEqual(excerpts.count, 1)
        let eleven = excerpts[0].lines.first { $0.number == 11 }
        XCTAssertEqual(eleven?.isMatch, true)
        XCTAssertFalse(eleven?.spans.isEmpty ?? true, "and it is painted")
    }

    /// The line numbers in the gutter are the file's, taken from the hit and its
    /// context rather than from the excerpt's position in the list.
    func testGutterNumbersComeFromTheFile() {
        let hit = match("x", hitting: "x", line: 42, before: ["above"], after: ["below"])
        let excerpt = SearchExcerpt.compose([hit])[0]
        XCTAssertEqual(excerpt.lines.map(\.number), [41, 42, 43])
        XCTAssertEqual(excerpt.firstLine, 41)
    }

    // MARK: - Host byte offsets as painted ranges

    /// The ordinary case: the host counts bytes, the row paints characters, and
    /// on an all-ASCII line the two agree.
    func testAnAsciiRangeMapsStraightThrough() {
        let text = "let widget = 1"
        let span = ContentMatch.range(text, bytes: 4 ..< 10)
        XCTAssertEqual(span.map { String(text[$0]) }, "widget")
    }

    /// The case the conversion exists for: bytes before the hit that are not
    /// characters. Counting them as characters would slide the highlight left.
    func testAMultibyteLineCountsBytesNotCharacters() {
        let text = "héllo widget"
        // "héllo " is 7 bytes — é is two — so the widget span starts at 7, not 6.
        let span = ContentMatch.range(text, bytes: 7 ..< 13)
        XCTAssertEqual(span.map { String(text[$0]) }, "widget")
    }

    func testAnEmojiIsSpannedWhole() {
        let text = "a🌍b"
        XCTAssertEqual(ContentMatch.range(text, bytes: 1 ..< 5).map { String(text[$0]) }, "🌍")
    }

    /// A range that cuts a character in half is dropped rather than nudged to
    /// the nearest boundary: a highlight one byte off is worse than none.
    func testARangeSplittingACharacterIsRefused() {
        XCTAssertNil(ContentMatch.range("a🌍b", bytes: 1 ..< 3))
        XCTAssertNil(ContentMatch.range("héllo", bytes: 1 ..< 2))
    }

    /// A host and a client that disagree about the line's length — a truncated
    /// window, a stale reply — must not trap on the out-of-range index.
    func testOffsetsPastTheLineAreRefused() {
        XCTAssertNil(ContentMatch.range("short", bytes: 0 ..< 99))
        XCTAssertNil(ContentMatch.range("", bytes: 0 ..< 1))
    }

    /// An empty span is a legitimate answer, not a bug — it paints nothing.
    func testAnEmptyRangeIsEmptyNotNil() {
        let text = "abc"
        XCTAssertEqual(ContentMatch.range(text, bytes: 1 ..< 1).map { String(text[$0]) }, "")
    }
}
