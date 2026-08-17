import AppKit

/// An Xcode-style line-number gutter for the editor's text view: right-aligned numbers, one per
/// logical line. A soft-wrapped line keeps a single number on its first visual row (drawn at the
/// first line fragment of each paragraph), and a trailing empty line is numbered like Xcode's.
final class LineNumberRulerView: NSRulerView {
    private var numberFont: NSFont
    private var numberColor: NSColor
    private var gutterColor: NSColor
    /// How far below each line fragment's top the editor's glyph tops sit (the centering lift
    /// from its fixed line height). The numbers shift by the same amount to stay on the code's
    /// baseline instead of floating above it.
    private var baselineShift: CGFloat

    override var isOpaque: Bool { true }

    init(scrollView: NSScrollView, editorFont: NSFont, numberColor: NSColor, gutterColor: NSColor,
         baselineShift: CGFloat) {
        self.numberFont = Self.gutterFont(for: editorFont)
        self.numberColor = numberColor
        self.gutterColor = gutterColor
        self.baselineShift = baselineShift
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = scrollView.documentView
        ruleThickness = 42
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func restyle(editorFont: NSFont, numberColor: NSColor, gutterColor: NSColor,
                 baselineShift: CGFloat) {
        // Called from every representable update — bail when nothing changed, so the routine
        // per-render pass doesn't force a full gutter repaint alongside every keystroke.
        let font = Self.gutterFont(for: editorFont)
        if font == numberFont, numberColor == self.numberColor,
           gutterColor == self.gutterColor, baselineShift == self.baselineShift { return }
        numberFont = font
        self.numberColor = numberColor
        self.gutterColor = gutterColor
        self.baselineShift = baselineShift
        needsDisplay = true
    }

    /// The editor's own face, slightly smaller — numbers set in the system font next to mono code
    /// read as a different app (and its light digits vanished on dark themes). Monospace families
    /// have monospaced digits by nature, so alignment holds.
    private static func gutterFont(for editorFont: NSFont) -> NSFont {
        let size = max(9, editorFont.pointSize - 1.5)
        return NSFont(descriptor: editorFont.fontDescriptor, size: size)
            ?? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        gutterColor.setFill()
        bounds.fill()
        drawLineNumbers()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // The full ruler is drawn in `draw(_:)` so AppKit never paints its default ruler chrome.
    }

    private func drawLineNumbers() {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let content = textView.string as NSString
        let inset = textView.textContainerInset.height
        // Maps the text view's y-coordinates into the ruler's (carries the scroll offset).
        let yOffset = convert(NSPoint.zero, from: textView).y
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor]

        let drawNumber: (Int, CGFloat) -> Void = { number, fragMinY in
            let string = "\(number)" as NSString
            let size = string.size(withAttributes: attributes)
            let x = self.ruleThickness - size.width - 6
            let y = fragMinY + inset + yOffset + self.baselineShift
            let topClipInset = self.window.map { 1 / $0.backingScaleFactor } ?? 0
            guard y > self.bounds.minY + topClipInset else { return }
            string.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        }

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Line number of the first visible character, counted from the scroll anchor — O(delta)
        // per draw. Counting from character zero made every scroll tick O(document prefix).
        var lineNumber = line(forCharacter: visibleCharRange.location, in: content)

        // One number per logical line (paragraph), at its first line fragment.
        content.enumerateSubstrings(
            in: visibleCharRange,
            options: [.byParagraphs, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let glyph = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: lineRange.location, length: 0),
                actualCharacterRange: nil
            )
            let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            drawNumber(lineNumber, fragRect.minY)
            lineNumber += 1
        }

        // The trailing empty line (empty document, or one ending in a newline) gets a number too —
        // only drawn when the document's end is actually in view.
        if NSMaxRange(visibleCharRange) >= content.length,
           layoutManager.extraLineFragmentTextContainer != nil {
            drawNumber(lineNumber, layoutManager.extraLineFragmentRect.minY)
        }
    }

    // MARK: Line numbering anchor

    /// The line number at a known character offset, advanced as the view scrolls so each draw
    /// counts newlines only over the scroll delta. Reset whenever the text changes — an edit
    /// above the anchor shifts every line number below it.
    private var lineAnchor: (character: Int, line: Int) = (0, 1)

    /// The text changed: restart the anchor from the top. The next draw pays one prefix scan;
    /// scrolling stays O(delta).
    func invalidateLineAnchor() {
        lineAnchor = (0, 1)
    }

    /// 1-based line number of the character at `index`, counted from the nearest anchor, which
    /// then moves to `index` for the next draw.
    private func line(forCharacter index: Int, in content: NSString) -> Int {
        var (anchorCharacter, anchorLine) = lineAnchor
        if anchorCharacter > content.length { (anchorCharacter, anchorLine) = (0, 1) }
        var line = anchorLine
        if index >= anchorCharacter {
            for position in anchorCharacter..<index where content.character(at: position) == 10 {
                line += 1
            }
        } else {
            for position in index..<anchorCharacter where content.character(at: position) == 10 {
                line -= 1
            }
        }
        lineAnchor = (index, line)
        return line
    }
}
