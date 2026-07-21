import AppKit

/// The diff's gutter, following `LineNumberRulerView`'s ruler precedent (including its
/// hard-won full-redraw-on-scroll invalidation, wired up by the pane's coordinator):
/// old and new line-number columns in quaternary ink plus the `+`/`−` sign, drawn at
/// each paragraph's first line fragment. Living in the ruler — outside the text view —
/// is what keeps the numbers out of selection and the clipboard. The add/delete washes
/// and band fills continue across it so each row reads as one full-width band.
final class DiffGutterRulerView: NSRulerView {
    private var document: DiffDocument?
    private var numberFont: NSFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private var signFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var gutterColor: NSColor = .textBackgroundColor
    private var oldColumnWidth: CGFloat = 0
    private var newColumnWidth: CGFloat = 0

    private static let leadingPad: CGFloat = 8
    private static let columnGap: CGFloat = 8
    private static let signWidth: CGFloat = 12
    private static let trailingPad: CGFloat = 2

    override var isOpaque: Bool { true }

    init(scrollView: NSScrollView, codeFont: NSFont, gutterColor: NSColor) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = scrollView.documentView
        self.gutterColor = gutterColor
        restyle(codeFont: codeFont)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(document: DiffDocument, codeFont: NSFont, gutterColor: NSColor) {
        self.document = document
        self.gutterColor = gutterColor
        restyle(codeFont: codeFont)
    }

    /// Line numbers step down from the code the same way the editor's gutter does.
    private func restyle(codeFont: NSFont) {
        numberFont = .monospacedDigitSystemFont(ofSize: max(9, codeFont.pointSize - 1.5),
                                                weight: .regular)
        signFont = codeFont
        let digits = max(2, String(max(document?.maxLineNumber ?? 0, 1)).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        let columnWidth = (digitWidth * CGFloat(digits)).rounded(.up)
        oldColumnWidth = document?.hasOldGutter == false ? 0 : columnWidth
        newColumnWidth = document?.hasNewGutter == false ? 0 : columnWidth
        var thickness = Self.leadingPad + Self.signWidth + Self.trailingPad
        if oldColumnWidth > 0 { thickness += oldColumnWidth + Self.columnGap }
        if newColumnWidth > 0 { thickness += newColumnWidth + Self.columnGap }
        ruleThickness = thickness
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        gutterColor.setFill()
        bounds.fill()
        drawGutter()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // The full ruler is drawn in `draw(_:)` so AppKit never paints its default chrome.
    }

    private func drawGutter() {
        guard let document,
              let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let inset = textView.textContainerInset.height
        // Maps the text view's y-coordinates into the ruler's (carries the scroll offset).
        let yOffset = convert(NSPoint.zero, from: textView).y
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: numberFont, .foregroundColor: NSColor.quaternaryLabelColor,
        ]
        // Numbers stranded in the strip above the content clip would ghost over the
        // header; anything at or above the ruler's top edge stays undrawn.
        let topClipInset = window.map { 1 / $0.backingScaleFactor } ?? 0

        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect,
                                                     in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs,
                                                        actualGlyphRange: nil)

        var index = document.lineIndex(at: visibleChars.location)
        while index < document.lines.count {
            let line = document.lines[index]
            index += 1
            if line.range.location >= NSMaxRange(visibleChars) { break }
            let glyphs = layoutManager.glyphRange(forCharacterRange: line.range,
                                                  actualCharacterRange: nil)

            // Continue the row's wash/band fill across the gutter, over every wrapped
            // fragment of the paragraph, so the tint reads edge-to-edge.
            if let fill = DiffWashLayoutManager.fill(for: line.role) {
                var band = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                band.origin.y += inset + yOffset
                band.origin.x = 0
                band.size.width = ruleThickness
                if line.isBand { band = band.insetBy(dx: 0, dy: -DiffDocument.bandPadding) }
                fill.setFill()
                band.fill()
            }

            guard case .code(let kind) = line.role else { continue }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location,
                                                          effectiveRange: nil)
            let y = fragment.minY + inset + yOffset
            guard y > bounds.minY + topClipInset else { continue }

            var x = Self.leadingPad
            if oldColumnWidth > 0 {
                if let number = line.oldLine {
                    drawNumber(number, rightEdge: x + oldColumnWidth, y: y, attrs: numberAttrs)
                }
                x += oldColumnWidth + Self.columnGap
            }
            if newColumnWidth > 0 {
                if let number = line.newLine {
                    drawNumber(number, rightEdge: x + newColumnWidth, y: y, attrs: numberAttrs)
                }
                x += newColumnWidth + Self.columnGap
            }
            if let sign = Self.sign(for: kind) {
                sign.text.draw(at: NSPoint(x: x, y: y), withAttributes: [
                    .font: signFont, .foregroundColor: sign.color,
                ])
            }
        }
    }

    private func drawNumber(_ number: Int, rightEdge: CGFloat, y: CGFloat,
                            attrs: [NSAttributedString.Key: Any]) {
        let string = "\(number)" as NSString
        let width = string.size(withAttributes: attrs).width
        string.draw(at: NSPoint(x: rightEdge - width, y: y), withAttributes: attrs)
    }

    private static func sign(for kind: DiffRow.Kind) -> (text: NSString, color: NSColor)? {
        switch kind {
        case .addition: return ("+", .systemGreen)
        case .deletion: return ("−", .systemRed)
        case .context, .hunk: return nil
        }
    }
}
