import TermioShared
import XCTest

/// The shared diff model the iOS reader renders from: parsing unified-diff text into
/// numbered lines, folding unchanged runs into bands, and marking the changed span of a
/// modified line. Pure logic, and the place an off-by-one turns into "the phone showed
/// the wrong line number next to the wrong code".
final class DiffParserTests: XCTestCase {
    func testLineNumbersFollowTheHunkHeader() {
        let diff = """
        @@ -10,4 +10,5 @@ func makeThing() {
             let a = 1
        -    let b = 2
        +    let b = 3
        +    let c = 4
             return a
        """
        let lines = DiffParser.lines(from: diff)
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .deletion, .addition, .addition, .context])
        // Context at the hunk's start sits on line 10 of both sides.
        XCTAssertEqual(lines[1].oldLine, 10)
        XCTAssertEqual(lines[1].newLine, 10)
        // A deletion advances only the old side, an addition only the new side.
        XCTAssertEqual(lines[2].oldLine, 11)
        XCTAssertNil(lines[2].newLine)
        XCTAssertEqual(lines[3].newLine, 11)
        XCTAssertNil(lines[3].oldLine)
        XCTAssertEqual(lines[4].newLine, 12)
        // The trailing context resumes past both edits.
        XCTAssertEqual(lines[5].oldLine, 12)
        XCTAssertEqual(lines[5].newLine, 13)
    }

    func testMarkersAreStrippedAndPlumbingDropped() {
        let diff = """
        diff --git a/App.swift b/App.swift
        index 1234567..89abcde 100644
        --- a/App.swift
        +++ b/App.swift
        @@ -1,2 +1,2 @@
        -let old = 1
        +let new = 1
        \\ No newline at end of file
        """
        let lines = DiffParser.lines(from: diff)
        XCTAssertEqual(lines.map(\.kind), [.hunk, .deletion, .addition])
        XCTAssertEqual(lines[1].text, "let old = 1")
        XCTAssertEqual(lines[2].text, "let new = 1")
    }

    /// A `+` in column 1 of the *content* (a diff of a diff, or a leading-plus line)
    /// must still read as an addition — the marker is positional, not semantic.
    func testEmptyContextLineSurvives() {
        let diff = """
        @@ -1,3 +1,3 @@
         first
        \u{20}
         third
        """
        let lines = DiffParser.lines(from: diff)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[2].kind, .context)
        XCTAssertEqual(lines[2].text, "")
    }
}

final class DiffFoldTests: XCTestCase {
    /// One addition buried in a long file: the run before it keeps 3 lines of context
    /// and folds the rest into an expandable band; the run after it does the same.
    func testLongUnchangedRunsCollapseAroundAChange() {
        var rows: [DiffLine] = []
        for i in 0..<30 {
            rows.append(DiffLine(id: i, kind: .context, text: "line \(i)", oldLine: i + 1, newLine: i + 1))
        }
        rows.insert(DiffLine(id: 100, kind: .addition, text: "new", oldLine: nil, newLine: 16), at: 15)

        let items = DiffParser.displayItems(lines: rows, expansion: DiffExpansion())
        guard case .band(let id, let range, let controls, _) = items.first else {
            return XCTFail("a 15-line leading run should fold to a band, got \(String(describing: items.first))")
        }
        // Nothing is rendered above the leading band, so it reveals upward only.
        XCTAssertEqual(controls, [.up])
        // 15 lines, 3 kept facing the change → 12 hidden, keyed by the first of them, and
        // named by the lines they hide rather than counted.
        XCTAssertEqual(range, 1...12)
        XCTAssertEqual(id, 0)
        XCTAssertEqual(items.count, 1 + 3 + 1 + 3 + 1) // band, context, add, context, band
        XCTAssertEqual(items.filter { if case .band = $0 { return true } else { return false } }.count, 2)
    }

    func testExpandingABandSplicesItsLinesBack() {
        var rows: [DiffLine] = []
        for i in 0..<30 {
            rows.append(DiffLine(id: i, kind: .context, text: "line \(i)", oldLine: i + 1, newLine: i + 1))
        }
        rows.insert(DiffLine(id: 100, kind: .addition, text: "new", oldLine: nil, newLine: 16), at: 15)

        var expansion = DiffExpansion()
        expansion.reveal(0, .all)
        let items = DiffParser.displayItems(lines: rows, expansion: expansion)
        // The leading band is gone; its 12 lines are back, so only the trailing one is left.
        XCTAssertEqual(items.filter { if case .band = $0 { return true } else { return false } }.count, 1)
        guard case .line(let first) = items[0] else { return XCTFail("expanded band should start with a line") }
        XCTAssertEqual(first.id, 0)
    }

    func testShortRunsAreNeverFolded() {
        var rows: [DiffLine] = []
        for i in 0..<8 {
            rows.append(DiffLine(id: i, kind: .context, text: "line \(i)", oldLine: i + 1, newLine: i + 1))
        }
        rows.append(DiffLine(id: 100, kind: .addition, text: "new", oldLine: nil, newLine: 9))
        let items = DiffParser.displayItems(lines: rows, expansion: DiffExpansion())
        XCTAssertEqual(items.count, 9)
        XCTAssertFalse(items.contains { if case .band = $0 { return true } else { return false } })
    }

    /// A diff fetched at git's default context has real gaps between hunks. Those become
    /// bands too — but fixed ones: the hidden lines were never sent, so tapping can't
    /// reveal them.
    func testHunkGapBecomesAFixedBand() {
        let diff = """
        @@ -1,2 +1,2 @@
        -one
        +ONE
        @@ -40,2 +40,2 @@
        -forty
        +FORTY
        """
        let items = DiffParser.displayItems(lines: DiffParser.lines(from: diff),
                                            expansion: DiffExpansion())
        let bands = items.compactMap { item -> (ClosedRange<Int>, DiffBandControls)? in
            if case .band(_, let range, let controls, _) = item { return (range, controls) }
            return nil
        }
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands.first?.0, 2...39) // the gap between the two hunks
        XCTAssertEqual(bands.first?.1, [], "the hidden lines were never sent, so nothing reveals them")
    }

    /// GitHub Desktop's `getHunkExpansionType`, which termio's gutter copies: the file's
    /// first hunk can only be read upward, a gap within one step opens in a single jump,
    /// and anything longer offers both ends. All three need the file on hand.
    func testGapControlsFollowGitHubDesktopsRules() {
        let firstHunkDiff = """
        @@ -92,2 +92,2 @@
        -ninetytwo
        +NINETYTWO
        """
        let file = DiffGapText(fileLines: (1...200).map { "line \($0)" })
        XCTAssertEqual(controls(of: firstHunkDiff, gapText: file), [.up],
                       "nothing is rendered above a first hunk to read downward from")

        let shortGap = """
        @@ -1,2 +1,2 @@
        -one
        +ONE
        @@ -12,2 +12,2 @@
        -twelve
        +TWELVE
        """
        XCTAssertEqual(controls(of: shortGap, gapText: file), [.all],
                       "a gap no longer than one step opens at once")

        let longGap = """
        @@ -1,2 +1,2 @@
        -one
        +ONE
        @@ -80,2 +80,2 @@
        -eighty
        +EIGHTY
        """
        XCTAssertEqual(controls(of: longGap, gapText: file), [.up, .down])
        XCTAssertEqual(controls(of: longGap, gapText: .unavailable), [],
                       "without the file there is nothing to splice, so the band stays inert")
    }

    func testRevealingAGapSplicesTheFilesOwnLines() {
        let diff = """
        @@ -1,2 +1,2 @@
        -one
        +ONE
        @@ -80,2 +80,2 @@
        -eighty
        +EIGHTY
        """
        let rows = DiffParser.lines(from: diff)
        let file = DiffGapText(fileLines: (1...200).map { "line \($0)" })
        // The gap is 2…79; the band anchors on the second hunk row.
        guard let anchor = rows.last(where: { $0.kind == .hunk })?.id else {
            return XCTFail("the fixture has two hunks")
        }
        var expansion = DiffExpansion()
        expansion.reveal(anchor, .down)
        let items = DiffParser.displayItems(lines: rows, expansion: expansion, gapText: file)
        let spliced = items.compactMap { item -> DiffLine? in
            if case .line(let line) = item, line.id < 0 { return line }
            return nil
        }
        XCTAssertEqual(spliced.count, DiffExpansion.step)
        XCTAssertEqual(spliced.first?.newLine, 2, "revealing downward starts at the gap's top")
        XCTAssertEqual(spliced.first?.text, "line 2")
        XCTAssertEqual(spliced.first?.oldLine, 2, "unchanged lines carry the same number on both sides")
        XCTAssertEqual(spliced.last?.newLine, 21)
        let bands = items.compactMap { item -> ClosedRange<Int>? in
            if case .band(_, let range, _, _) = item { return range }
            return nil
        }
        XCTAssertEqual(bands, [22...79], "the band keeps what is still hidden")
    }

    private func controls(of diff: String, gapText: DiffGapText) -> DiffBandControls? {
        let items = DiffParser.displayItems(lines: DiffParser.lines(from: diff),
                                            expansion: DiffExpansion(), gapText: gapText)
        for item in items {
            if case .band(_, _, let controls, _) = item { return controls }
        }
        return nil
    }
}

final class DiffIntralineSpanTests: XCTestCase {
    func testSpanCoversTheChangedWordOnly() {
        let diff = """
        @@ -1,1 +1,1 @@
        -let value = oldName
        +let value = newName
        """
        let lines = DiffParser.lines(from: diff)
        guard let old = lines[1].emphasis.first, let new = lines[2].emphasis.first else {
            return XCTFail("a one-word edit should carry an intraline span")
        }
        XCTAssertEqual(String(Array(lines[1].text)[old]), "oldName")
        XCTAssertEqual(String(Array(lines[2].text)[new]), "newName")
    }

    /// Spans are whole words: a character-level peel of the shared `alph` prefix would
    /// emphasize a bare `a` / `b` and leave the identifier visually split.
    func testSpanCoversTheWholeWord() {
        let diff = """
        @@ -1,1 +1,1 @@
        -call(alpha)
        +call(alphb)
        """
        let lines = DiffParser.lines(from: diff)
        guard let old = lines[1].emphasis.first else {
            return XCTFail("a near-identical pair should carry a span")
        }
        XCTAssertEqual(String(Array(lines[1].text)[old]), "alpha")
    }

    /// Two lines with almost nothing in common are a rewrite, not an edit — spanning
    /// them would highlight the whole line, which says nothing.
    func testUnrelatedLinesGetNoSpan() {
        let diff = """
        @@ -1,1 +1,1 @@
        -let a = 1
        +print(somethingElseEntirely)
        """
        let lines = DiffParser.lines(from: diff)
        XCTAssertTrue(lines[1].emphasis.isEmpty)
        XCTAssertTrue(lines[2].emphasis.isEmpty)
    }
}
