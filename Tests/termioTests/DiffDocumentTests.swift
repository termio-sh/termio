import TermioShared
import AppKit
import XCTest
@testable import termio

/// The fold: which lines a collapsed band hides, what it says about them, and which
/// reveal buttons it offers. The reveal state is keyed by the run's first hidden row, so
/// the case that matters most is that revealing one end does not lose the other end's
/// state — the anchor has to survive its own band shrinking.
final class DiffDocumentTests: XCTestCase {
    private let palette = DiffPalette(
        background: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1), isDark: true)

    /// One change, then a long unchanged tail: three lines of context stay, the rest folds.
    private func rows(context: Int = 40) -> [DiffRow] {
        var rows = [DiffRow(id: 0, kind: .addition, text: "added", oldLine: nil, newLine: 1)]
        for offset in 0..<context {
            rows.append(DiffRow(id: offset + 1, kind: .context, text: "context",
                                oldLine: offset + 2, newLine: offset + 2))
        }
        return rows
    }

    private func document(_ expansion: DiffExpansion, context: Int = 40) -> DiffDocument {
        DiffDocument.build(rows: rows(context: context), expansion: expansion, palette: palette,
                           codeFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
                           lineSpacing: 0)
    }

    private func band(_ document: DiffDocument) -> (label: String, line: DiffDocument.Line)? {
        guard let line = document.lines.first(where: { $0.isBand }) else { return nil }
        let text = (document.attributed.string as NSString)
            .substring(with: line.range)
            .trimmingCharacters(in: .newlines)
        return (text, line)
    }

    func testBandNamesTheRangeItHides() {
        // Rows 2, 3, 4 stay as context; 5 through 41 fold away.
        XCTAssertEqual(band(document(DiffExpansion()))?.label, "5–41")
    }

    func testBandAtTheEndOfTheFileOffersOnlyTheDownwardButton() {
        let controls = band(document(DiffExpansion()))?.line.bandControls
        XCTAssertEqual(controls, [.down], "nothing follows the run, so up points nowhere")
    }

    func testRevealingDownwardShrinksTheBandFromTheTop() {
        var expansion = DiffExpansion()
        expansion.reveal(4, .down)
        XCTAssertEqual(band(document(expansion))?.label, "25–41")
    }

    func testRevealingUpwardShrinksTheBandFromTheBottom() {
        var expansion = DiffExpansion()
        expansion.reveal(4, .up)
        XCTAssertEqual(band(document(expansion))?.label, "5–21")
    }

    /// The anchor is the run's *first hidden row*, and revealing from the top moves which
    /// row that is on screen — but not the key. If the key drifted, a second click would
    /// start a fresh reveal and the first one would snap shut.
    func testRevealsAccumulateOnTheSameAnchor() {
        var expansion = DiffExpansion()
        expansion.reveal(4, .down)
        expansion.reveal(4, .down)
        // 80 context rows: 5–81 folds, and two 20-line steps leave 45–81.
        XCTAssertEqual(band(document(expansion, context: 80))?.label, "45–81")
    }

    func testRevealingFromBothEndsMeetsInTheMiddle() {
        var expansion = DiffExpansion()
        expansion.reveal(4, .down)
        expansion.reveal(4, .up)
        XCTAssertEqual(band(document(expansion, context: 80))?.label, "25–61")
    }

    /// A run shorter than the reveal steps asked for simply runs out — the band closes
    /// rather than clamping to an empty range.
    func testRevealsThatOverrunTheRunCloseTheBand() {
        var expansion = DiffExpansion()
        expansion.reveal(4, .down)
        expansion.reveal(4, .up)
        XCTAssertNil(band(document(expansion)), "37 hidden lines, 40 revealed")
    }

    func testRevealingEverythingDropsTheBand() {
        var expansion = DiffExpansion()
        expansion.reveal(4, .all)
        XCTAssertNil(band(document(expansion)), "the band is gone once nothing is hidden")
        XCTAssertEqual(document(expansion).lines.count, 41)
    }

    func testShortRunsAreNotFoldedAtAll() {
        XCTAssertFalse(document(DiffExpansion(), context: 8).lines.contains { $0.isBand })
    }

    func testHunkHeadingIsTheSectionAfterTheRanges() {
        XCTAssertEqual(DiffParser.hunkHeading("@@ -8,7 +8,7 @@ func reload() {"),
                       "func reload() {")
    }

    func testHunkHeadingIsNilWhenGitOffersNone() {
        XCTAssertNil(DiffParser.hunkHeading("@@ -8,7 +8,7 @@"))
        XCTAssertNil(DiffParser.hunkHeading("@@ -8,7 +8,7 @@   "))
    }

    /// A heading can itself contain `@@` — an operator, a string, a comment.
    func testHunkHeadingKeepsAtSignsInsideTheHeading() {
        XCTAssertEqual(DiffParser.hunkHeading("@@ -1,2 +1,2 @@ let mark = \"@@\""),
                       "let mark = \"@@\"")
    }
}
