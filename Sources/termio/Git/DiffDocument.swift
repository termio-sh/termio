import AppKit

// MARK: - Diff document

/// The whole diff as one immutable text document: an attributed string (one paragraph
/// per rendered element) plus per-paragraph metadata the layout manager and gutter
/// read at draw time. Built once per (rows, expanded) pair; the text view swaps it
/// in wholesale — TextKit owns layout, wrapping, selection, and the find bar from
/// there, which is what buys continuous multi-line selection and ⌘F.
final class DiffDocument {
    /// One paragraph of the document — a code line, or a collapsed band standing in
    /// for a run of unchanged lines.
    struct Line {
        enum Role {
            case code(DiffRow.Kind)
            /// `expandable` bands (full-context loads) splice their hidden lines back
            /// in on click; fixed bands (the default-context fallback, where the
            /// hidden lines were never fetched) just mark the gap.
            case band(count: Int, expandable: Bool)
        }

        let role: Role
        /// The paragraph's range in the document, including its trailing newline.
        let range: NSRange
        /// `DiffRow.id` for a code line (keys the syntax-color pass); the first hidden
        /// row's id for a band (keys the expand action).
        let rowId: Int
        let oldLine: Int?
        let newLine: Int?

        var isBand: Bool {
            if case .band = role { return true }
            return false
        }
    }

    let attributed: NSAttributedString
    let lines: [Line]
    /// Whether any code line carries an old/new number. A pure-addition file has no
    /// old numbers, so that gutter column collapses rather than showing a blank band;
    /// likewise a pure deletion collapses the new column.
    let hasOldGutter: Bool
    let hasNewGutter: Bool
    /// The largest line number shown, sizing the gutter columns.
    let maxLineNumber: Int

    private init(attributed: NSAttributedString, lines: [Line],
                 hasOldGutter: Bool, hasNewGutter: Bool, maxLineNumber: Int) {
        self.attributed = attributed
        self.lines = lines
        self.hasOldGutter = hasOldGutter
        self.hasNewGutter = hasNewGutter
        self.maxLineNumber = maxLineNumber
    }

    /// Meta text (band labels) speaks in the UI font; code speaks in the terminal font.
    static let bandFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    /// Extra breathing room drawn around a band row (the fill is expanded to match).
    static let bandPadding: CGFloat = 3

    // MARK: Building

    /// Folds the parsed rows into the display list and lays it down as one attributed
    /// string. Hunk plumbing disappears (its gap becomes a band), unchanged runs longer
    /// than a handful of lines collapse to a band keeping 3 lines of context on the
    /// side(s) that face a change, and `expanded` bands splice their lines back in.
    static func build(rows: [DiffRow], expanded: Set<Int>, codeFont: NSFont) -> DiffDocument {
        let items = displayItems(rows: rows, expanded: expanded)

        var text = String()
        text.reserveCapacity(items.reduce(0) { $0 + $1.textLength + 1 })
        var lines: [Line] = []
        lines.reserveCapacity(items.count)
        var maxLineNumber = 0

        for item in items {
            let location = (text as NSString).length
            switch item {
            case .line(let row):
                text += row.text
                text += "\n"
                let length = (row.text as NSString).length + 1
                lines.append(Line(role: .code(row.kind), range: NSRange(location: location, length: length),
                                  rowId: row.id, oldLine: row.oldLine, newLine: row.newLine))
                maxLineNumber = max(maxLineNumber, row.oldLine ?? 0, row.newLine ?? 0)
            case .band(let id, let count, let expandable):
                let label = "⋯ \(count) unchanged \(count == 1 ? "line" : "lines")"
                text += label
                text += "\n"
                let length = (label as NSString).length + 1
                lines.append(Line(role: .band(count: count, expandable: expandable),
                                  range: NSRange(location: location, length: length),
                                  rowId: id, oldLine: nil, newLine: nil))
            }
        }

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: codeFont,
            .foregroundColor: NSColor.labelColor,
        ])
        styleBandsAndEmphasis(attributed, items: items, lines: lines)

        return DiffDocument(
            attributed: attributed,
            lines: lines,
            hasOldGutter: rows.contains { $0.kind != .hunk && $0.oldLine != nil },
            hasNewGutter: rows.contains { $0.kind != .hunk && $0.newLine != nil },
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

    /// Bands restyle to the UI font (centered, tertiary ink, pointing-hand cursor when
    /// expandable); intraline emphasis lands as a `.backgroundColor` attribute — the
    /// layout manager's washes paint underneath, and TextKit's own background pass
    /// composites the deeper tint on top.
    private static func styleBandsAndEmphasis(_ attributed: NSMutableAttributedString,
                                              items: [DisplayItem], lines: [Line]) {
        let bandStyle = NSMutableParagraphStyle()
        bandStyle.alignment = .center
        bandStyle.paragraphSpacingBefore = bandPadding
        bandStyle.paragraphSpacing = bandPadding

        for (item, line) in zip(items, lines) {
            switch item {
            case .band(_, _, let expandable):
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: bandFont,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: bandStyle,
                ]
                if expandable { attrs[.cursor] = NSCursor.pointingHand }
                attributed.addAttributes(attrs, range: line.range)
            case .line(let row):
                guard let emphasis = row.emphasis, !emphasis.isEmpty,
                      let range = utf16Range(of: emphasis, in: row.text) else { continue }
                let color = row.kind == .addition
                    ? NSColor.systemGreen.withAlphaComponent(0.28)
                    : NSColor.systemRed.withAlphaComponent(0.28)
                attributed.addAttribute(
                    .backgroundColor, value: color,
                    range: NSRange(location: line.range.location + range.location, length: range.length)
                )
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
        case band(id: Int, count: Int, expandable: Bool)

        var textLength: Int {
            switch self {
            case .line(let row): return (row.text as NSString).length
            case .band: return 24
            }
        }
    }

    private static func displayItems(rows: [DiffRow], expanded: Set<Int>) -> [DisplayItem] {
        var items: [DisplayItem] = []
        var run: [DiffRow] = []
        var sawChange = false
        var lastNewLine = 0

        func flush(isLast: Bool) {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let head = sawChange ? 3 : 0
            let tail = isLast ? 0 : 3
            let hidden = run.count - head - tail
            guard hidden >= 10 else {
                items += run.map(DisplayItem.line)
                return
            }
            items += run.prefix(head).map(DisplayItem.line)
            let hiddenRows = Array(run.dropFirst(head).dropLast(tail))
            if expanded.contains(hiddenRows[0].id) {
                items += hiddenRows.map(DisplayItem.line)
            } else {
                items.append(.band(id: hiddenRows[0].id, count: hiddenRows.count, expandable: true))
            }
            items += run.suffix(tail).map(DisplayItem.line)
        }

        for row in rows {
            switch row.kind {
            case .hunk:
                flush(isLast: false)
                if let start = row.newLine, start > lastNewLine + 1 {
                    items.append(.band(id: row.id, count: start - lastNewLine - 1, expandable: false))
                }
            case .context:
                run.append(row)
                lastNewLine = row.newLine ?? lastNewLine
            case .addition:
                flush(isLast: false)
                sawChange = true
                items.append(.line(row))
                lastNewLine = row.newLine ?? lastNewLine
            case .deletion:
                flush(isLast: false)
                sawChange = true
                items.append(.line(row))
            }
        }
        flush(isLast: true)
        return items
    }
}
