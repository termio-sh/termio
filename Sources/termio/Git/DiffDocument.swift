import AppKit
import TermioShared

// MARK: - Diff document

/// The whole diff as one immutable text document: an attributed string (one paragraph
/// per rendered element) plus per-paragraph metadata the layout manager and gutter
/// read at draw time. Built once per (rows, expansion) pair; the text view swaps it
/// in wholesale — TextKit owns layout, wrapping, selection, and the find bar from
/// there, which is what buys continuous multi-line selection and ⌘F.
final class DiffDocument {
    /// One paragraph of the document — a code line, or a collapsed band standing in
    /// for a run of unchanged lines.
    struct Line {
        enum Role {
            case code(DiffRow.Kind)
            /// A band's `controls` are the reveal buttons the gutter offers for it. Empty
            /// means the band is inert: the default-context fallback, where the hidden
            /// lines were never fetched and so cannot be revealed at all.
            case band(controls: DiffBandControls)
        }

        let role: Role
        /// The paragraph's range in the document, including its trailing newline.
        let range: NSRange
        /// `DiffRow.id` for a code line (keys the syntax-color pass); the run's anchor
        /// row id for a band (keys the reveal state).
        let rowId: Int
        let oldLine: Int?
        let newLine: Int?

        var isBand: Bool {
            if case .band = role { return true }
            return false
        }

        /// The reveal buttons this line offers, empty for anything that is not an
        /// expandable band.
        var bandControls: DiffBandControls {
            if case .band(let controls) = role { return controls }
            return []
        }

        /// Whether a click anywhere on this row reveals the run it stands for.
        var isRevealable: Bool { !bandControls.isEmpty }
    }

    let attributed: NSAttributedString
    let lines: [Line]
    /// The tints this document was laid out with. Carried here rather than passed
    /// alongside so the layout manager, the gutter, and the emphasis spans baked into
    /// `attributed` can never disagree about the palette.
    let palette: DiffPalette
    /// Whether any code line carries an old/new number. A pure-addition file has no
    /// old numbers, so that gutter column collapses rather than showing a blank band;
    /// likewise a pure deletion collapses the new column.
    let hasOldGutter: Bool
    let hasNewGutter: Bool
    /// The largest line number shown, sizing the gutter columns.
    let maxLineNumber: Int

    private init(attributed: NSAttributedString, lines: [Line], palette: DiffPalette,
                 hasOldGutter: Bool, hasNewGutter: Bool, maxLineNumber: Int) {
        self.attributed = attributed
        self.lines = lines
        self.palette = palette
        self.hasOldGutter = hasOldGutter
        self.hasNewGutter = hasNewGutter
        self.maxLineNumber = maxLineNumber
    }

    /// Extra breathing room drawn around a band row (the fill is expanded to match).
    static let bandPadding: CGFloat = 3

    // MARK: Building

    /// Folds the parsed rows into the display list and lays it down as one attributed
    /// string. Hunk plumbing disappears (its gap becomes a band), unchanged runs longer
    /// than a handful of lines collapse to a band keeping 3 lines of context on the
    /// side(s) that face a change, and whatever `expansion` has revealed is spliced back in.
    static func build(rows: [DiffRow], expansion: DiffExpansion, palette: DiffPalette,
                      codeFont: NSFont, lineSpacing: CGFloat,
                      gapText: DiffGapText = .unavailable) -> DiffDocument {
        build(items: displayItems(rows: rows, expansion: expansion, gapText: gapText),
              allRows: rows, palette: palette, codeFont: codeFont, lineSpacing: lineSpacing)
    }

    /// The shared assembly: lays the display items down as one attributed string with
    /// per-paragraph metadata. `allRows` sizes the gutter columns (which sides carry
    /// numbers, and the widest).
    private static func build(items: [DisplayItem], allRows: [DiffRow], palette: DiffPalette,
                              codeFont: NSFont, lineSpacing: CGFloat) -> DiffDocument {
        var text = String()
        text.reserveCapacity(items.reduce(0) { $0 + $1.textLength + 1 })
        var lines: [Line] = []
        lines.reserveCapacity(items.count)
        var maxLineNumber = 0
        // Tracked rather than re-measured: `(text as NSString).length` is only O(1) while
        // the accumulated string stays ASCII, so one curly quote anywhere in the file
        // turned this loop quadratic — and the reveal buttons rebuild on every click.
        var location = 0

        for item in items {
            switch item {
            case .line(let row):
                text += row.text
                text += "\n"
                let length = (row.text as NSString).length + 1
                lines.append(Line(role: .code(row.kind), range: NSRange(location: location, length: length),
                                  rowId: row.id, oldLine: row.oldLine, newLine: row.newLine))
                location += length
                maxLineNumber = max(maxLineNumber, row.oldLine ?? 0, row.newLine ?? 0)
            case .band(let id, let label, let controls):
                text += label
                text += "\n"
                let length = (label as NSString).length + 1
                lines.append(Line(role: .band(controls: controls),
                                  range: NSRange(location: location, length: length),
                                  rowId: id, oldLine: nil, newLine: nil))
                location += length
            }
        }

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: codeFont,
            .foregroundColor: NSColor.labelColor,
        ])
        // Leading from the configured code line height — the same lift the file editor gets.
        // Bands and headers re-set their own styles below, with the same spacing.
        let baseStyle = NSMutableParagraphStyle()
        baseStyle.lineSpacing = lineSpacing
        attributed.addAttribute(.paragraphStyle, value: baseStyle,
                                range: NSRange(location: 0, length: attributed.length))
        styleBandsAndEmphasis(attributed, items: items, lines: lines, palette: palette,
                              lineSpacing: lineSpacing)

        return DiffDocument(
            attributed: attributed,
            lines: lines,
            palette: palette,
            hasOldGutter: allRows.contains { $0.kind != .hunk && $0.oldLine != nil },
            hasNewGutter: allRows.contains { $0.kind != .hunk && $0.newLine != nil },
            maxLineNumber: maxLineNumber
        )
    }

    /// The index of the first line whose paragraph ends past `location` — the entry
    /// point for draw-time walks, so painting only ever touches the visible lines.
    func lineIndex(at location: Int) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(lines[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The line containing the character at `location`, if any.
    func line(at location: Int) -> Line? {
        let index = lineIndex(at: location)
        guard index < lines.count, NSLocationInRange(location, lines[index].range) else { return nil }
        return lines[index]
    }

    // MARK: Attributes

    /// Bands restyle to the UI font — left-aligned at the code column, so the row reads as
    /// a control rather than as decoration floating in the middle of the diff; the reveal
    /// chevrons live in the gutter beside it. Intraline emphasis lands as a
    /// `.backgroundColor` attribute — the layout manager's washes paint underneath, and
    /// TextKit's own background pass composites the deeper tint on top.
    private static func styleBandsAndEmphasis(_ attributed: NSMutableAttributedString,
                                              items: [DisplayItem], lines: [Line],
                                              palette: DiffPalette, lineSpacing: CGFloat) {
        let bandStyle = NSMutableParagraphStyle()
        bandStyle.lineSpacing = lineSpacing
        bandStyle.paragraphSpacingBefore = bandPadding
        bandStyle.paragraphSpacing = bandPadding

        for (item, line) in zip(items, lines) {
            switch item {
            case .band(_, _, let controls):
                // The label keeps the code font (inherited from the base attributes):
                // it is a line range, so it should line up with the numbers it names, the
                // way github.com renders its `@@` row in the code face.
                var attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: bandStyle,
                ]
                if !controls.isEmpty { attrs[.cursor] = NSCursor.pointingHand }
                attributed.addAttributes(attrs, range: line.range)
            case .line(let row):
                guard !row.emphasis.isEmpty else { continue }
                let color = row.kind == .addition
                    ? palette.additionEmphasis
                    : palette.deletionEmphasis
                for span in row.emphasis {
                    guard !span.isEmpty, let range = utf16Range(of: span, in: row.text) else { continue }
                    attributed.addAttribute(
                        .backgroundColor, value: color,
                        range: NSRange(location: line.range.location + range.location,
                                       length: range.length))
                }
            }
        }
    }

    /// `DiffRow.emphasis` is in `Character` offsets (the intraline pass is CJK-aware);
    /// attributed-string ranges are UTF-16. Bail rather than misplace the span.
    private static func utf16Range(of emphasis: Range<Int>, in text: String) -> NSRange? {
        guard let lower = text.index(text.startIndex, offsetBy: emphasis.lowerBound,
                                     limitedBy: text.endIndex),
              let upper = text.index(text.startIndex, offsetBy: emphasis.upperBound,
                                     limitedBy: text.endIndex),
              lower < upper else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    // MARK: Display fold

    private enum DisplayItem {
        case line(DiffRow)
        case band(id: Int, label: String, controls: DiffBandControls)

        var textLength: Int {
            switch self {
            case .line(let row): return (row.text as NSString).length
            case .band(_, let label, _): return (label as NSString).length
            }
        }
    }

    /// The shared fold, rendered into this document's paragraphs. A band says *where* the
    /// skipped lines are, not how many there are: a line range tells the reader what they
    /// are jumping over, while "137 unchanged lines" only describes the widget. git's
    /// section heading rides along when the gap came from a hunk boundary.
    private static func displayItems(rows: [DiffRow], expansion: DiffExpansion,
                                     gapText: DiffGapText) -> [DisplayItem] {
        DiffParser.displayItems(lines: rows, expansion: expansion, gapText: gapText).map { item in
            switch item {
            case .line(let row):
                return .line(row)
            case .band(let id, let lines, let controls, let heading):
                let range = lines.lowerBound == lines.upperBound
                    ? "\(lines.lowerBound)"
                    : "\(lines.lowerBound)–\(lines.upperBound)"
                let label = heading.map { "\(range)   \($0)" } ?? range
                return .band(id: id, label: label, controls: controls)
            }
        }
    }
}
