import TermioShared
import AppKit
import XCTest
@testable import termio

/// The split pane's layout, verified against real TextKit rather than argued from flags: a column
/// must not fold a long line (wrapping would give the two columns different row counts and pull
/// them out of step), and the two columns of one diff must lay out to the *same* height, because
/// that equal height is the whole reason a single scroll offset can drive both.
final class DiffPaneLayoutTests: XCTestCase {
    private let palette = DiffPalette(
        background: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1), isDark: true)
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var longLine: String { String(repeating: "let aVeryLongIdentifier = 1234567890; ", count: 12) }

    /// One modification (with a long deletion), an addition-only block that pads the old side, and
    /// a long unchanged tail that folds into a band.
    private var diff: String {
        var text = """
        @@ -1,4 +1,4 @@
        -short old
        +short new
        -\(longLine)
        +\(longLine)tail
         kept
        +added
        +also added
        """
        for number in 1...30 { text += " unchanged \(number)\n" }
        return text
    }

    private func pane(wraps: Bool, document: DiffDocument,
                      width: CGFloat = 300) -> DiffTextPane.PaneViews {
        let views = DiffTextPane.makeViews(
            wraps: wraps, showsVerticalScroller: true,
            backgroundColor: .black, numberColor: .gray, font: font)
        views.textView.frame = NSRect(x: 0, y: 0, width: width, height: 4000)
        views.textView.textStorage?.setAttributedString(document.attributed)
        views.layoutManager.ensureLayout(for: views.container)
        return views
    }

    private func contentSize(_ views: DiffTextPane.PaneViews) -> NSSize {
        views.layoutManager.usedRect(for: views.container).size
    }

    /// The number of laid-out lines, which is more than the paragraph count exactly when the pane
    /// wrapped something.
    private func fragmentCount(_ views: DiffTextPane.PaneViews) -> Int {
        var count = 0
        let glyphs = NSRange(location: 0, length: views.layoutManager.numberOfGlyphs)
        views.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in
            count += 1
        }
        return count
    }

    private func splitPair() -> DiffDocument.SplitPair {
        DiffDocument.buildSplitPair(
            rows: DiffParser.lines(from: diff), expansion: DiffExpansion(), palette: palette,
            codeFont: font, lineSpacing: 0)
    }

    func testSplitColumnDoesNotWrapALongLine() {
        let pair = splitPair()
        let views = pane(wraps: false, document: pair.left)
        XCTAssertFalse(views.container.widthTracksTextView)
        XCTAssertTrue(views.textView.isHorizontallyResizable)
        XCTAssertTrue(views.scrollView.hasHorizontalScroller,
                      "a column that never wraps needs the sideways scroller to reach the rest")
        XCTAssertGreaterThan(contentSize(views).width, 300,
                             "the long line runs past the column instead of folding into it")
        XCTAssertEqual(fragmentCount(views), pair.left.lines.count,
                       "one laid-out line per paragraph: nothing wrapped")
    }

    func testInlinePaneWrapsToItsWidth() {
        let inline = DiffDocument.build(
            rows: DiffParser.lines(from: diff), expansion: DiffExpansion(), palette: palette,
            codeFont: font, lineSpacing: 0)
        let views = pane(wraps: true, document: inline)
        XCTAssertTrue(views.container.widthTracksTextView)
        XCTAssertFalse(views.textView.isHorizontallyResizable)
        XCTAssertFalse(views.scrollView.hasHorizontalScroller)
        XCTAssertLessThanOrEqual(contentSize(views).width, 300,
                                 "the inline pane stays inside its width")
        XCTAssertGreaterThan(fragmentCount(views), inline.lines.count,
                             "and pays for it by folding the long line")
    }

    /// The two columns are the same rows, so at the same width they must measure the same height —
    /// including the empty rows padding a one-sided change and the band standing in for the folded
    /// run. If they differed, one shared scroll offset would drift them apart line by line.
    func testBothColumnsLayOutToTheSameHeight() {
        let pair = splitPair()
        let left = pane(wraps: false, document: pair.left)
        let right = pane(wraps: false, document: pair.right)
        XCTAssertEqual(pair.left.lines.count, pair.right.lines.count)
        XCTAssertEqual(contentSize(left).height, contentSize(right).height, accuracy: 0.5,
                       "a shared scroll offset is only honest if both columns are as tall")
    }

    /// Each column carries only its own line numbers, so the digits a column reserves are the
    /// ones its own file reaches.
    func testEachColumnGutterReservesItsOwnSideWidth() {
        let pair = splitPair()
        let left = pane(wraps: false, document: pair.left)
        let right = pane(wraps: false, document: pair.right)
        left.ruler.configure(document: pair.left, codeFont: font, gutterColor: .black,
                             numberColor: .gray, metrics: .side(true, digits: pair.lineNumberDigits))
        right.ruler.configure(document: pair.right, codeFont: font, gutterColor: .black,
                              numberColor: .gray, metrics: .side(false, digits: pair.lineNumberDigits))
        XCTAssertEqual(left.ruler.ruleThickness, right.ruler.ruleThickness,
                       "both code columns start at the same x")
    }
}

/// The pair's shared viewport: whichever column the reader moves, the other follows — and the push
/// that comes back around is not mistaken for a move of its own.
@MainActor
final class DiffPaneScrollSyncTests: XCTestCase {
    private func pane() -> NSScrollView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 4000))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = textView
        return scrollView
    }

    private func syncedPair() -> (sync: DiffPaneScrollSync, left: NSScrollView, right: NSScrollView) {
        let sync = DiffPaneScrollSync()
        let left = pane(), right = pane()
        sync.register(left, side: .left)
        sync.register(right, side: .right)
        return (sync, left, right)
    }

    func testMovingOneColumnMovesTheOther() {
        let (sync, left, right) = syncedPair()
        left.contentView.scroll(to: NSPoint(x: 120, y: 340))
        sync.scrolled(left.contentView, from: .left)
        XCTAssertEqual(right.contentView.bounds.origin, NSPoint(x: 120, y: 340),
                       "the same x is the same column of code, the same y the same line")
    }

    func testTheEchoedPushDoesNotMoveTheDriverBack() {
        let (sync, left, right) = syncedPair()
        left.contentView.scroll(to: NSPoint(x: 120, y: 340))
        sync.scrolled(left.contentView, from: .left)
        // AppKit posts the peer's own bounds change back through the same handler.
        sync.scrolled(right.contentView, from: .right)
        XCTAssertEqual(left.contentView.bounds.origin, NSPoint(x: 120, y: 340))
    }

    func testTheOtherColumnStillDrivesAfterAnEcho() {
        let (sync, left, right) = syncedPair()
        left.contentView.scroll(to: NSPoint(x: 120, y: 340))
        sync.scrolled(left.contentView, from: .left)
        sync.scrolled(right.contentView, from: .right)
        // A real move in the other column: the reader scrolled the right pane themselves.
        right.contentView.scroll(to: NSPoint(x: 40, y: 90))
        sync.scrolled(right.contentView, from: .right)
        XCTAssertEqual(left.contentView.bounds.origin, NSPoint(x: 40, y: 90))
    }
}

final class DiffFindMergeTests: XCTestCase {
    private func match(_ row: Int, offset: Int = 0) -> DiffFindMatch {
        DiffFindMatch(rowID: row, range: NSRange(location: offset, length: 3))
    }

    func testContextOccurrencesAreDeduplicatedWithoutLosingRepeatedWords() {
        let repeated = [match(4), match(4, offset: 5), match(9)]
        XCTAssertEqual(DiffFindMatch.merge(left: repeated, right: repeated), repeated)
    }

    func testChangesOnEitherSideSurviveInColumnOrder() {
        XCTAssertEqual(DiffFindMatch.merge(left: [match(2), match(7)],
                                          right: [match(3), match(7), match(11)]),
                       [match(2), match(7), match(3), match(11)])
    }

    func testAPaneWithNoMatchesContributesNothing() {
        XCTAssertEqual(DiffFindMatch.merge(left: [], right: [match(5), match(6)]),
                       [match(5), match(6)])
        XCTAssertEqual(DiffFindMatch.merge(left: [match(5)], right: []), [match(5)])
    }
}

final class DiffRevealButtonLayoutTests: XCTestCase {
    func testTwoDirectionsHaveSeparateTargetsCenteredInAWrappedBand() {
        let band = NSRect(x: 0, y: 40, width: 46, height: 70)
        let buttons = DiffGutterRulerView.revealButtonFrames(controls: [.down, .up], in: band)
        XCTAssertEqual(buttons.count, 2)
        guard buttons.count == 2 else { return }
        XCTAssertEqual(buttons[0].direction, .down)
        XCTAssertEqual(buttons[1].direction, .up)
        XCTAssertFalse(buttons[0].rect.intersects(buttons[1].rect))
        for button in buttons {
            XCTAssertTrue(band.contains(button.rect))
            XCTAssertEqual(button.rect.midY, band.midY)
            XCTAssertGreaterThanOrEqual(button.rect.width, 20)
            XCTAssertGreaterThanOrEqual(button.rect.height, 20)
        }
    }

    func testSingleDirectionIsCenteredAndInertBandHasNoTargets() {
        let band = NSRect(x: 0, y: 10, width: 70, height: 28)
        for control in [DiffBandControls.up, .down, .all] {
            let buttons = DiffGutterRulerView.revealButtonFrames(controls: control, in: band)
            XCTAssertEqual(buttons.count, 1)
            XCTAssertEqual(buttons.first?.rect.midX, band.midX)
            XCTAssertEqual(buttons.first?.rect.midY, band.midY)
        }
        XCTAssertTrue(DiffGutterRulerView.revealButtonFrames(controls: [], in: band).isEmpty)
    }
}
