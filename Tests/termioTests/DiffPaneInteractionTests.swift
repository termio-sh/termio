import TermioShared
import AppKit
import XCTest
@testable import termio

/// The split column's own input rules. What a click on a band, an arrow key, or the right-click
/// menu does must not change because the pane is one of two — and both columns have to name the
/// *same* band, or one reveal would fold them apart. These drive the pane's own hit-test and key
/// handlers; `super.mouseDown` is deliberately never reached, since it tracks the mouse until a
/// mouse-up arrives and a test has no event stream to deliver one.
final class DiffPaneInteractionTests: XCTestCase {
    private let palette = DiffPalette(
        background: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1), isDark: true)
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// One change, then a long unchanged tail: the tail folds into a band whose reveal is offered.
    private var diff: String {
        var text = "@@ -1,1 +1,1 @@\n-old\n+new\n"
        for number in 1...30 { text += " unchanged \(number)\n" }
        return text
    }

    private func splitPair() -> DiffDocument.SplitPair {
        DiffDocument.buildSplitPair(
            rows: DiffParser.lines(from: diff), expansion: DiffExpansion(), palette: palette,
            codeFont: font, lineSpacing: 0)
    }

    private func pane(document: DiffDocument, side: DiffPaneScrollSync.Side) -> DiffTextPane.PaneViews {
        let views = DiffTextPane.makeViews(
            wraps: false, showsVerticalScroller: true,
            backgroundColor: .black, numberColor: .gray, font: font)
        views.textView.frame = NSRect(x: 0, y: 0, width: 300, height: 4000)
        // The pane's coordinator does this in `apply`; the hit-test and the washes both read the
        // document off the view, so a test that only sets the text would test nothing.
        views.textView.document = document
        views.layoutManager.document = document
        views.textView.textStorage?.setAttributedString(document.attributed)
        views.ruler.configure(document: document, codeFont: font, gutterColor: .black,
                              numberColor: .gray, metrics: .side(side == .left, digits: 2))
        views.layoutManager.ensureLayout(for: views.container)
        return views
    }

    /// A point inside the paragraph at `line`, in the text view's own coordinates.
    private func point(in views: DiffTextPane.PaneViews, at line: DiffDocument.Line) -> NSPoint {
        let glyphs = views.layoutManager.glyphRange(forCharacterRange: line.range,
                                                    actualCharacterRange: nil)
        let rect = views.layoutManager.boundingRect(forGlyphRange: glyphs, in: views.container)
        let origin = views.textView.textContainerOrigin
        return NSPoint(x: origin.x + 20, y: origin.y + rect.midY)
    }

    func testABandRowIsARevealTarget() {
        let pair = splitPair()
        let views = pane(document: pair.left, side: .left)
        guard let band = pair.left.lines.first(where: { $0.isRevealable }) else {
            return XCTFail("the fixture folds a band")
        }
        XCTAssertEqual(views.textView.expandableBand(atViewPoint: point(in: views, at: band)),
                       band.rowId)
    }

    func testACodeRowIsNotARevealTarget() {
        let pair = splitPair()
        let views = pane(document: pair.left, side: .left)
        let code = pair.left.lines[0]
        XCTAssertFalse(code.isBand)
        XCTAssertNil(views.textView.expandableBand(atViewPoint: point(in: views, at: code)),
                     "only the run's row reveals; code is code")
    }

    /// The two columns are the same rows, so the reveal either one triggers names the same anchor —
    /// which is what keeps a single shared expansion state in step across both panes.
    func testBothColumnsNameTheSameBand() {
        let pair = splitPair()
        let left = pane(document: pair.left, side: .left)
        let right = pane(document: pair.right, side: .right)
        guard let leftBand = pair.left.lines.first(where: { $0.isRevealable }),
              let rightBand = pair.right.lines.first(where: { $0.isRevealable }) else {
            return XCTFail("both columns fold the same run")
        }
        XCTAssertEqual(left.textView.expandableBand(atViewPoint: point(in: left, at: leftBand)),
                       right.textView.expandableBand(atViewPoint: point(in: right, at: rightBand)))
    }

    private func key(_ code: UInt16) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
    }

    /// ← / → still walk the sibling files from either column, and Esc still closes the overlay.
    func testArrowKeysWalkAndEscapeClosesFromEitherColumn() {
        for side in [DiffPaneScrollSync.Side.left, .right] {
            let pair = splitPair()
            let views = pane(document: side == .left ? pair.left : pair.right, side: side)
            var walked: [Int] = []
            var closed = false
            views.textView.onWalk = { walked.append($0); return true }
            views.textView.onClose = { closed = true }
            guard let left = key(123), let right = key(124), let escape = key(53) else {
                return XCTFail("no key event")
            }
            views.textView.keyDown(with: left)
            views.textView.keyDown(with: right)
            views.textView.keyDown(with: escape)
            XCTAssertEqual(walked, [-1, 1], "the \(side) column walks both directions")
            XCTAssertTrue(closed, "Esc closes from the \(side) column")
        }
    }

    /// The right-click menu a split column offers: Copy, then Close. AppKit's read-only grab-bag
    /// (Look Up, Translate, Speech, Share, Services) has no place in a diff.
    func testTheContextMenuIsStillCopyAndClose() {
        let pair = splitPair()
        let views = pane(document: pair.left, side: .left)
        views.textView.onClose = {}
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
                                             modifierFlags: [], timestamp: 0, windowNumber: 0,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let menu = views.textView.menu(for: event) else { return XCTFail("no menu") }
        XCTAssertEqual(menu.items.map(\.title).filter { !$0.isEmpty },
                       [localized("Copy"), localized("Close")],
                       "the same two verbs, in the app's language")
        // Nothing is selected yet, so Copy is offered but inactive.
        XCTAssertFalse(views.textView.validateUserInterfaceItem(menu.items[0]))
    }

    /// Copying a selection that sweeps across a band drops the band's label — it is chrome, not
    /// code — which is the rule the split columns have to keep too.
    func testCopyStripsBandLabelsInASplitColumn() {
        let pair = splitPair()
        let views = pane(document: pair.left, side: .left)
        guard let band = pair.left.lines.first(where: { $0.isBand }) else {
            return XCTFail("the fixture folds a band")
        }
        let label = (pair.left.attributed.string as NSString)
            .substring(with: band.range).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(label.isEmpty)
        views.textView.setSelectedRange(NSRange(location: 0, length: pair.left.attributed.length))
        views.textView.copy(nil)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("old"), "the code that was selected is what copies")
        // The three context rows kept above the fold are code; the rest of the run is inside the
        // band, so only its range stands for them.
        XCTAssertTrue(copied.contains("unchanged 1"), "the context rows above the band copy too")
        XCTAssertFalse(copied.contains("unchanged 30"), "a line the band hides is not copied")
        XCTAssertFalse(copied.contains(label), "the band's own line range is not code")
    }
}

@MainActor
final class DiffPaneUpdateTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let palette = DiffPalette(background: .black, isDark: true)

    private func document(_ text: String) -> DiffDocument {
        DiffDocument.build(rows: DiffParser.lines(from: text), expansion: DiffExpansion(),
                           palette: palette, codeFont: font, lineSpacing: 0)
    }

    private func pane(_ document: DiffDocument,
                      styled: [Int: NSAttributedString] = [:]) -> DiffTextPane {
        DiffTextPane(document: document, styled: styled, font: font, thickenGlyphs: false,
                     backgroundColor: .black, numberColor: .gray,
                     onExpand: { _, _ in }, onWalk: { _ in false }, onClose: {},
                     autoFocuses: false)
    }

    func testUpdatingAnExistingPaneReplacesTheDocumentAndCallbacks() throws {
        let first = document("@@ -1 +1 @@\n-old\n+first\n")
        let second = document("@@ -1 +1 @@\n-old\n+second\n")
        let initial = pane(first)
        let coordinator = initial.makeCoordinator()
        let scrollView = initial.makeScrollView(coordinator: coordinator)
        let textView = try XCTUnwrap(scrollView.documentView as? DiffTextView)
        var walked = false
        let updated = DiffTextPane(document: second, styled: [:], font: font, thickenGlyphs: false,
                               backgroundColor: .black, numberColor: .gray,
                               onExpand: { _, _ in }, onWalk: { _ in walked = true; return true },
                               onClose: {}, autoFocuses: false)
        updated.updateScrollView(scrollView, coordinator: coordinator)
        XCTAssertEqual(textView.string, second.attributed.string)
        XCTAssertTrue(textView.document === second)
        XCTAssertTrue(coordinator.ruler === scrollView.verticalRulerView)
        XCTAssertEqual(textView.onWalk?(1), true)
        XCTAssertTrue(walked)
    }

    func testSyntaxColorsArrivingAfterCreationAreApplied() throws {
        let document = document("@@ -1 +1 @@\n-old\n+new\n")
        let initial = pane(document)
        let coordinator = initial.makeCoordinator()
        let scrollView = initial.makeScrollView(coordinator: coordinator)
        let textView = try XCTUnwrap(scrollView.documentView as? DiffTextView)
        let line = try XCTUnwrap(document.lines.last)
        let styled = NSAttributedString(string: "new", attributes: [.foregroundColor: NSColor.systemPurple])
        pane(document, styled: [line.rowId: styled]).updateScrollView(scrollView, coordinator: coordinator)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: line.range.location,
                                                       effectiveRange: nil) as? NSColor,
                       NSColor.systemPurple)
    }

    func testFindCanFocusTheSecondOccurrenceOnOneLine() async throws {
        let document = document("@@ -1 +1 @@\n-old\n+foo foo\n")
        var pane = pane(document)
        pane.findQuery = "foo"
        let reported = expectation(description: "both occurrences")
        var matches: [DiffFindMatch] = []
        pane.onMatchesChanged = { result in
            matches = result
            reported.fulfill()
        }
        let coordinator = pane.makeCoordinator()
        let scrollView = pane.makeScrollView(coordinator: coordinator)
        await fulfillment(of: [reported], timeout: 2)
        XCTAssertEqual(matches.count, 2)
        let first = try XCTUnwrap(matches.first)
        let second = try XCTUnwrap(matches.last)
        XCTAssertEqual(first.rowID, second.rowID)
        XCTAssertNotEqual(first.range, second.range)
        pane.findFocusedMatch = first
        pane.updateScrollView(scrollView, coordinator: coordinator)
        pane.findFocusedMatch = second
        pane.updateScrollView(scrollView, coordinator: coordinator)
        let textView = try XCTUnwrap(scrollView.documentView as? DiffTextView)
        let line = try XCTUnwrap(document.lines.last)
        let manager = try XCTUnwrap(textView.layoutManager)
        let firstColor = manager.temporaryAttribute(.backgroundColor,
            atCharacterIndex: line.range.location + first.range.location, effectiveRange: nil) as? NSColor
        let secondColor = manager.temporaryAttribute(.backgroundColor,
            atCharacterIndex: line.range.location + second.range.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(try XCTUnwrap(firstColor).alphaComponent, 0.35, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(secondColor).alphaComponent, 0.7, accuracy: 0.01)
    }

    func testWalkingToAFileWithNoMatchesClearsTheCount() async {
        var initial = pane(document("@@ -1 +1 @@\n-old\n+foo\n"))
        initial.findQuery = "foo"
        let found = expectation(description: "initial match")
        initial.onMatchesChanged = { matches in
            XCTAssertEqual(matches.count, 1)
            found.fulfill()
        }
        let coordinator = initial.makeCoordinator()
        let scrollView = initial.makeScrollView(coordinator: coordinator)
        await fulfillment(of: [found], timeout: 2)

        var next = pane(document("@@ -1 +1 @@\n-old\n+bar\n"))
        next.findQuery = "foo"
        let cleared = expectation(description: "no matches in next file")
        next.onMatchesChanged = { matches in
            XCTAssertTrue(matches.isEmpty)
            cleared.fulfill()
        }
        next.updateScrollView(scrollView, coordinator: coordinator)
        await fulfillment(of: [cleared], timeout: 2)
    }

    func testClearingFindWhileReplacingTheDocumentDropsOldRanges() async throws {
        var initial = pane(document("@@ -1 +1 @@\n-old\n+prefix prefix foo\n"))
        initial.findQuery = "foo"
        let found = expectation(description: "initial match")
        initial.onMatchesChanged = { _ in found.fulfill() }
        let coordinator = initial.makeCoordinator()
        let scrollView = initial.makeScrollView(coordinator: coordinator)
        await fulfillment(of: [found], timeout: 2)

        var replacement = pane(document("@@ -0,0 +1 @@\n+x\n"))
        replacement.findFocusedMatch = DiffFindMatch(rowID: 2, range: NSRange(location: 14, length: 3))
        let cleared = expectation(description: "empty query")
        replacement.onMatchesChanged = { matches in
            XCTAssertTrue(matches.isEmpty)
            cleared.fulfill()
        }
        replacement.updateScrollView(scrollView, coordinator: coordinator)
        await fulfillment(of: [cleared], timeout: 2)
        let textView = try XCTUnwrap(scrollView.documentView as? DiffTextView)
        XCTAssertNil(textView.layoutManager?.temporaryAttribute(.backgroundColor,
                          atCharacterIndex: 0, effectiveRange: nil))
    }

    func testContextMatchesKeepTheirIdentityAcrossDifferentColumnOffsets() {
        let pair = DiffDocument.buildSplitPair(
            rows: DiffParser.lines(from: "@@ -1,2 +1,2 @@\n-long old text\n+new\n 猫 foo foo\n"),
            expansion: DiffExpansion(), palette: palette, codeFont: font, lineSpacing: 0)
        let leftRanges = TextFindEngine.matches(of: "foo", options: FindOptions(),
                                                in: pair.left.attributed.string as NSString)
        let rightRanges = TextFindEngine.matches(of: "foo", options: FindOptions(),
                                                 in: pair.right.attributed.string as NSString)
        XCTAssertNotEqual(leftRanges, rightRanges)
        let left = leftRanges.compactMap { pair.left.findMatch(at: $0) }
        let right = rightRanges.compactMap { pair.right.findMatch(at: $0) }
        XCTAssertEqual(left, right)
        XCTAssertEqual(DiffFindMatch.merge(left: left, right: right).count, 2)
    }

    func testOnlyTheActivePaneReclaimsFocusAndTheOtherConsumesTheToken() throws {
        let document = document("@@ -1 +1 @@\n-old\n+new\n")
        var left = pane(document), right = pane(document)
        right.reclaimsFocus = false
        let leftCoordinator = left.makeCoordinator(), rightCoordinator = right.makeCoordinator()
        let leftScroll = left.makeScrollView(coordinator: leftCoordinator)
        let rightScroll = right.makeScrollView(coordinator: rightCoordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(leftScroll)
        window.contentView?.addSubview(rightScroll)
        let leftText = try XCTUnwrap(leftScroll.documentView as? DiffTextView)
        let rightText = try XCTUnwrap(rightScroll.documentView as? DiffTextView)
        window.makeFirstResponder(rightText)
        left.reclaimFocus = 1
        right.reclaimFocus = 1
        left.updateScrollView(leftScroll, coordinator: leftCoordinator)
        right.updateScrollView(rightScroll, coordinator: rightCoordinator)
        XCTAssertTrue(window.firstResponder === leftText)
        right.reclaimsFocus = true
        right.updateScrollView(rightScroll, coordinator: rightCoordinator)
        XCTAssertTrue(window.firstResponder === leftText, "a consumed token must not replay")
        right.reclaimFocus = 2
        right.updateScrollView(rightScroll, coordinator: rightCoordinator)
        XCTAssertTrue(window.firstResponder === rightText)
    }
}
