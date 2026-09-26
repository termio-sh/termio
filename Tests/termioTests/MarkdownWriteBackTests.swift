import XCTest
@testable import termio

/// The three shapes domd's canonical serializer actually changes in this repository's
/// documents — a re-padded table, a blank line inserted around a block, and a `0.`
/// ordered list renumbered to `1.` — and what has to survive an edit made beside them.
final class MarkdownWriteBackTests: XCTestCase {

    private let original = """
    # Title

    | a | bb |
    |---|----|
    | 1 | 2 |

    Some prose.

    0. first
    0. second
    """

    /// The same document as the kernel serializes it with no edit at all.
    private let canonical = """
    # Title

    | a   | bb  |
    | --- | --- |
    | 1   | 2   |

    Some prose.

    1. first
    2. second
    """

    func testAnUneditedDocumentIsNotRewritten() {
        XCTAssertEqual(
            MarkdownWriteBack.merge(edited: canonical, canonical: canonical, original: original),
            original)
    }

    func testAOneWordEditChangesOneLineAndLeavesTheFormattingAlone() {
        let edited = canonical.replacingOccurrences(of: "Some prose.", with: "Some edited prose.")
        let merged = MarkdownWriteBack.merge(edited: edited, canonical: canonical, original: original)

        XCTAssertEqual(merged, original.replacingOccurrences(of: "Some prose.",
                                                            with: "Some edited prose."))
        XCTAssertTrue(merged.contains("| 1 | 2 |"), "the table keeps its own padding")
        XCTAssertTrue(merged.contains("0. first"), "the staged list keeps its 0. anchor")
    }

    func testAnInsertedParagraphLandsWithoutTouchingTheRest() {
        let edited = canonical.replacingOccurrences(of: "Some prose.",
                                                    with: "Some prose.\n\nAnd more.")
        let merged = MarkdownWriteBack.merge(edited: edited, canonical: canonical, original: original)

        XCTAssertEqual(merged, original.replacingOccurrences(of: "Some prose.",
                                                            with: "Some prose.\n\nAnd more."))
    }

    func testADeletedParagraphIsRemovedWithoutTouchingTheRest() {
        let edited = canonical.replacingOccurrences(of: "Some prose.\n\n", with: "")
        let merged = MarkdownWriteBack.merge(edited: edited, canonical: canonical, original: original)

        XCTAssertFalse(merged.contains("Some prose."))
        XCTAssertTrue(merged.contains("| 1 | 2 |"))
        XCTAssertTrue(merged.contains("0. first"))
    }

    func testAnEditInsideARepaddedTableRowKeepsTheRestOfTheTable() {
        let edited = canonical.replacingOccurrences(of: "| 1   | 2   |", with: "| 1   | 3   |")
        let merged = MarkdownWriteBack.merge(edited: edited, canonical: canonical, original: original)

        // The edited row arrives canonicalized — that is the conflict resolution, and it
        // is confined to the one row the user typed in.
        XCTAssertTrue(merged.contains("| 1   | 3   |"))
        XCTAssertTrue(merged.contains("| a | bb |"), "the header row keeps its own padding")
        XCTAssertTrue(merged.contains("0. first"))
    }

    func testTheFirstAndLastLinesCanBeEdited() {
        let first = MarkdownWriteBack.merge(
            edited: canonical.replacingOccurrences(of: "# Title", with: "# Renamed"),
            canonical: canonical, original: original)
        XCTAssertTrue(first.hasPrefix("# Renamed\n"))
        XCTAssertTrue(first.contains("| 1 | 2 |"))

        let last = MarkdownWriteBack.merge(
            edited: canonical.replacingOccurrences(of: "2. second", with: "2. last"),
            canonical: canonical, original: original)
        XCTAssertTrue(last.hasSuffix("2. last"))
        XCTAssertTrue(last.contains("0. first"), "the line above keeps its 0. anchor")
    }

    func testATrailingNewlineIsPreserved() {
        let merged = MarkdownWriteBack.merge(
            edited: canonical + "\n",
            canonical: canonical + "\n",
            original: original + "\n")
        XCTAssertEqual(merged, original + "\n")
    }

    func testADocumentTheKernelRoundTripsExactlyIsAdoptedWhole() {
        let plain = "# Title\n\nProse.\n"
        let edited = "# Title\n\nMore prose.\n"
        XCTAssertEqual(
            MarkdownWriteBack.merge(edited: edited, canonical: plain, original: plain),
            edited)
    }

    func testAnEmptyDocumentTakesTheWholeEdit() {
        XCTAssertEqual(
            MarkdownWriteBack.merge(edited: "# New\n", canonical: "", original: ""),
            "# New\n")
    }
}
