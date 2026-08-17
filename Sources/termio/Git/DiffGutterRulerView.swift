import TermioShared
import AppKit

/// The diff's gutter, following `LineNumberRulerView`'s ruler precedent (including its
/// hard-won full-redraw-on-scroll invalidation, wired up by the pane's coordinator): old
/// and new line-number columns, the `+`/`−` sign, and — on a collapsed band — the reveal
/// buttons. Living in the ruler — outside the text view — is what keeps the numbers out of
/// selection and the clipboard.
///
/// The washes continue across it so each row reads edge to edge, but a changed row's
/// gutter is mixed one step stronger than its body, which is how github.com anchors the
/// number cell. On a band, the whole gutter becomes one filled cell holding the buttons:
/// a control needs a block to sit in, or it reads as a glyph stranded in empty space.
final class DiffGutterRulerView: NSRulerView {
    /// Reveals part of a collapsed run — the buttons are the ruler's only controls.
    var onExpand: ((Int, DiffBandDirection) -> Void)?

    private var document: DiffDocument?
    private var numberFont: NSFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private var signFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var gutterColor: NSColor = .textBackgroundColor
    private var numberColor: NSColor = .quaternaryLabelColor
    private var oldColumnWidth: CGFloat = 0
    private var newColumnWidth: CGFloat = 0
    private var numberAttributes: [NSAttributedString.Key: Any] = [:]

    /// Where each visible reveal button landed, refreshed every draw and read by
    /// `mouseDown`. Only visible rows are drawn, so this stays a handful of entries.
    private struct ButtonHit {
        let rect: NSRect
        let anchor: Int
        let direction: DiffBandDirection
    }
    private var buttonHits: [ButtonHit] = []
    /// The scroll offset the hit rects were built at. Scrolling only *schedules* a redraw,
    /// so a click landing in between would test the click's position against rects that
    /// describe where the buttons used to be — and expand whichever band happened to sit
    /// there. Stamping the offset lets such a click be ignored instead of misfiring.
    private var hitsOffset: CGFloat = .nan

    private static let leadingPad: CGFloat = 8
    private static let columnGap: CGFloat = 8
    private static let signWidth: CGFloat = 12
    private static let trailingPad: CGFloat = 2

    override var isOpaque: Bool { true }

    init(scrollView: NSScrollView, codeFont: NSFont, gutterColor: NSColor,
         numberColor: NSColor) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = scrollView.documentView
        self.gutterColor = gutterColor
        self.numberColor = numberColor
        restyle(codeFont: codeFont)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(document: DiffDocument, codeFont: NSFont, gutterColor: NSColor,
                   numberColor: NSColor) {
        self.document = document
        self.gutterColor = gutterColor
        self.numberColor = numberColor
        restyle(codeFont: codeFont)
    }

    /// Line numbers step down from the code the same way the editor's gutter does.
    private func restyle(codeFont: NSFont) {
        numberFont = .monospacedDigitSystemFont(ofSize: max(9, codeFont.pointSize - 1.5),
                                                weight: .regular)
        signFont = codeFont
        // Digits stay in the shared muted ink on every row — the cell behind them carries
        // the add/delete signal, and the sign column names it outright.
        numberAttributes = [.font: numberFont, .foregroundColor: numberColor]
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

        let hadButtons = !buttonHits.isEmpty
        buttonHits = []

        let inset = textView.textContainerInset.height
        // Maps the text view's y-coordinates into the ruler's (carries the scroll offset).
        let yOffset = convert(NSPoint.zero, from: textView).y
        hitsOffset = yOffset
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

            // Continue the row's fill across the gutter, over every wrapped fragment of the
            // paragraph — one step stronger than the body's, so the gutter reads as the
            // row's anchor and, on a band, as the block its buttons sit in.
            if let fill = document.palette.gutterFill(for: line.role) {
                var band = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                band.origin.y += inset + yOffset
                band.origin.x = 0
                band.size.width = ruleThickness
                if line.isBand { band = band.insetBy(dx: 0, dy: -DiffDocument.bandPadding) }
                // Clip the wash to the same top margin the numbers respect: a row scrolled
                // partly under the header must not fill the sliver above the content clip, or
                // its tint seams into the header (issue #176 — the green top-left sliver).
                let topClip = bounds.minY + topClipInset
                if band.minY < topClip {
                    band.size.height -= topClip - band.minY
                    band.origin.y = topClip
                }
                if band.height > 0 {
                    fill.setFill()
                    band.fill()
                }
            }

            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location,
                                                          effectiveRange: nil)
            let y = fragment.minY + inset + yOffset
            guard y > bounds.minY + topClipInset else { continue }

            switch line.role {
            case .band:
                drawRevealButtons(for: line, y: y, height: fragment.height)
            case .code:
                drawNumbers(for: line, y: y)
            }
        }

        // The rects move with the scroll offset, so any draw with a band on screen has
        // stale ones; only a draw with no band at either end can skip the invalidation.
        if hadButtons || !buttonHits.isEmpty {
            window?.invalidateCursorRects(for: self)
        }
    }

    private func drawNumbers(for line: DiffDocument.Line, y: CGFloat) {
        let attrs = numberAttributes
        var x = Self.leadingPad
        if oldColumnWidth > 0 {
            if let number = line.oldLine {
                drawNumber(number, rightEdge: x + oldColumnWidth, y: y, attrs: attrs)
            }
            x += oldColumnWidth + Self.columnGap
        }
        if newColumnWidth > 0 {
            if let number = line.newLine {
                drawNumber(number, rightEdge: x + newColumnWidth, y: y, attrs: attrs)
            }
            x += newColumnWidth + Self.columnGap
        }
        guard case .code(let kind) = line.role, let sign = Self.sign(for: kind) else { return }
        sign.text.draw(at: NSPoint(x: x, y: y),
                       withAttributes: [.font: signFont, .foregroundColor: sign.color])
    }

    private static func sign(for kind: DiffRow.Kind) -> (text: NSString, color: NSColor)? {
        switch kind {
        case .addition: return ("+", .systemGreen)
        case .deletion: return ("−", .systemRed)
        case .context, .hunk: return nil
        }
    }

    /// A band's reveal buttons: an arrow over a dotted line, github.com's shape. The dots
    /// stand for the hidden lines and the arrow for the way the reveal walks — up pulls up
    /// the lines nearest the code *below* the band, down pulls down those nearest the code
    /// above. A band that can only be read from one side draws only that button.
    private func drawRevealButtons(for line: DiffDocument.Line, y: CGFloat, height: CGFloat) {
        let controls = line.bandControls
        guard !controls.isEmpty else { return }

        var directions: [DiffBandDirection] = []
        if controls.contains(.all) { directions.append(.all) }
        if controls.contains(.down) { directions.append(.down) }
        if controls.contains(.up) { directions.append(.up) }

        // Stacked, GitHub Desktop's shape: one gutter cell split in half, the downward
        // reveal on top and the upward one below, each reading toward the code it pulls
        // from. A lone control (a first hunk, or a gap short enough to open at once) takes
        // the whole cell.
        let padding = DiffDocument.bandPadding
        let width = ruleThickness - Self.leadingPad - Self.trailingPad
        let full = NSRect(x: Self.leadingPad, y: y - padding,
                          width: width, height: height + padding * 2)
        let slice = full.height / CGFloat(directions.count)
        for (index, direction) in directions.enumerated() {
            let hit = NSRect(x: full.minX, y: full.minY + slice * CGFloat(index),
                             width: full.width, height: slice)
            drawRevealIcon(direction, in: hit, ink: numberColor)
            buttonHits.append(ButtonHit(rect: hit, anchor: line.rowId, direction: direction))
        }
    }

    private func drawRevealIcon(_ direction: DiffBandDirection, in rect: NSRect, ink: NSColor) {
        let width: CGFloat = 7
        let arrowHeight: CGFloat = 5
        let gap: CGFloat = 2.5
        let dotWidth: CGFloat = 1.2
        let originX = (rect.midX - width / 2).rounded()
        // "Open the whole gap" reads as both arrows meeting on the dots — GitHub Desktop's
        // fold glyph — rather than either single direction, neither of which is what a
        // click does here.
        if direction == .all {
            let dotsY = (rect.midY - dotWidth / 2).rounded()
            ink.setFill()
            var dotX = originX
            while dotX < originX + width {
                NSRect(x: dotX, y: dotsY, width: dotWidth, height: dotWidth).fill()
                dotX += dotWidth * 2
            }
            ink.setStroke()
            for pointsDown in [true, false] {
                let tipY = pointsDown ? dotsY - gap : dotsY + dotWidth + gap
                let tailY = pointsDown ? tipY - arrowHeight : tipY + arrowHeight
                let barbY = pointsDown ? tipY - 2.4 : tipY + 2.4
                let arrow = NSBezierPath()
                arrow.lineWidth = 1.2
                arrow.lineCapStyle = .round
                arrow.lineJoinStyle = .round
                arrow.move(to: NSPoint(x: rect.midX, y: tailY))
                arrow.line(to: NSPoint(x: rect.midX, y: tipY))
                arrow.move(to: NSPoint(x: originX + 1, y: barbY))
                arrow.line(to: NSPoint(x: rect.midX, y: tipY))
                arrow.line(to: NSPoint(x: originX + width - 1, y: barbY))
                arrow.stroke()
            }
            return
        }
        // The arrow points the way the reveal walks — the same reading github.com and
        // GitHub Desktop use — and the dots trail behind it, on the side still hidden.
        // A vertical NSRulerView is flipped, so `minY` is the block's *top* edge: an
        // up-pointing arrow puts its tip at `minY` and its dots at the bottom.
        let pointsUp = direction == .up
        let block = NSRect(x: originX, y: rect.midY - (arrowHeight + gap + dotWidth) / 2,
                           width: width, height: arrowHeight + gap + dotWidth)
        let dotsY = pointsUp ? block.maxY - dotWidth : block.minY
        let tipY = pointsUp ? block.minY : block.maxY
        let tailY = pointsUp ? block.minY + arrowHeight : block.maxY - arrowHeight
        let barbY = pointsUp ? tipY + 2.4 : tipY - 2.4

        ink.setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 1.2
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: block.midX, y: tailY))
        arrow.line(to: NSPoint(x: block.midX, y: tipY))
        arrow.move(to: NSPoint(x: block.minX + 1, y: barbY))
        arrow.line(to: NSPoint(x: block.midX, y: tipY))
        arrow.line(to: NSPoint(x: block.maxX - 1, y: barbY))
        arrow.stroke()

        ink.setFill()
        var dotX = block.minX
        while dotX < block.maxX {
            NSRect(x: dotX, y: dotsY, width: dotWidth, height: dotWidth).fill()
            dotX += dotWidth * 2
        }
    }

    private func drawNumber(_ number: Int, rightEdge: CGFloat, y: CGFloat,
                            attrs: [NSAttributedString.Key: Any]) {
        let string = "\(number)" as NSString
        let width = string.size(withAttributes: attrs).width
        string.draw(at: NSPoint(x: rightEdge - width, y: y), withAttributes: attrs)
    }

        override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Only act on rects built at the current scroll position; a click that beat the
        // pending redraw does nothing rather than expanding the wrong band.
        guard let textView = clientView as? NSTextView,
              convert(NSPoint.zero, from: textView).y == hitsOffset,
              let hit = buttonHits.first(where: { $0.rect.contains(point) }) else {
            super.mouseDown(with: event)
            return
        }
        onExpand?(hit.anchor, hit.direction)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for hit in buttonHits {
            addCursorRect(hit.rect, cursor: .pointingHand)
        }
    }
}
