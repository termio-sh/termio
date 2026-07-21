import AppKit
import SwiftUI

// MARK: - Diff text pane

/// The diff overlay's content: one non-editable `NSTextView` (TextKit 1, matching the
/// editor) holding the whole `DiffDocument`. Line semantics are painted, not stacked —
/// `DiffWashLayoutManager` fills the add/delete washes and band fills behind the text,
/// the gutter ruler draws line numbers and the `+`/`−` signs *outside* the selectable
/// text — so selection runs continuously across lines, copies pure code, and ⌘F is
/// the system find bar.
struct DiffTextPane: NSViewRepresentable {
    let document: DiffDocument
    /// Syntax-colored lines by row id (the `DiffHighlighter` pass), applied in place
    /// once they land; the document renders plain until then.
    let styled: [Int: NSAttributedString]
    let font: NSFont
    let backgroundColor: NSColor
    /// Splices a clicked band's hidden lines back in (rebuilds the document upstream).
    let onExpand: (Int) -> Void
    /// ← / → sibling walk; returns false at either end so the press dies quietly.
    let onWalk: (Int) -> Bool
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = DiffWashLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = true          // soft-wrap to the panel width
        layoutManager.addTextContainer(container)

        let textView = DiffTextView(frame: .zero, textContainer: container)
        textView.onExpand = onExpand
        textView.onWalk = onWalk
        textView.onClose = onClose
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor
        // Paint the clip view the same color so the ruler/text seam can never show as a hairline.
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = backgroundColor

        let ruler = DiffGutterRulerView(scrollView: scrollView, codeFont: font,
                                        gutterColor: backgroundColor)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler

        // The ruler must fully redraw on three events: content changes and the view
        // re-wrapping on resize (both via the text view's frame changes), and —
        // crucially — *scrolling*. AppKit's copy-on-scroll only repaints the newly
        // exposed strip, so without a full invalidation the gutter's absolutely
        // positioned numbers desync into a garbled smear (the editor's ruler learned
        // this the hard way).
        textView.postsFrameChangedNotifications = true
        context.coordinator.observeFrame(of: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(of: scrollView)

        apply(to: textView, layoutManager: layoutManager, ruler: ruler,
              coordinator: context.coordinator)

        // Keys (← → walk, Esc, ⌘F) should work the moment the overlay lands, without
        // a click first. Deferred one turn — at make time the view has no window yet.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if window.firstResponder === window || window.firstResponder is NSTextView == false {
                window.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? DiffTextView,
              let layoutManager = textView.layoutManager as? DiffWashLayoutManager,
              let ruler = context.coordinator.ruler else { return }
        textView.onExpand = onExpand
        textView.onWalk = onWalk
        textView.onClose = onClose
        scrollView.backgroundColor = backgroundColor
        scrollView.contentView.backgroundColor = backgroundColor
        textView.backgroundColor = backgroundColor
        apply(to: textView, layoutManager: layoutManager, ruler: ruler,
              coordinator: context.coordinator)
    }

    /// Swaps the document in when it changed (initial load, band expand) and lays the
    /// syntax colors over it when they land — both idempotent against re-renders.
    private func apply(to textView: DiffTextView, layoutManager: DiffWashLayoutManager,
                       ruler: DiffGutterRulerView, coordinator: Coordinator) {
        textView.backgroundColor = backgroundColor
        if coordinator.appliedDocument !== document {
            coordinator.appliedDocument = document
            coordinator.appliedStyled = nil
            layoutManager.document = document
            textView.document = document
            textView.textStorage?.setAttributedString(document.attributed)
            ruler.configure(document: document, codeFont: font, gutterColor: backgroundColor)
        }
        // A dictionary identity check, not equality: the highlight pass lands at most
        // once per load, so pointer-style diffing by count is enough and O(1).
        if !styled.isEmpty, coordinator.appliedStyled != styled.count {
            coordinator.appliedStyled = styled.count
            applyStyled(to: textView)
        }
    }

    /// Lays the highlighter's colors (and any bold/italic trait fonts) over the plain
    /// document in place — geometry-stable for same-width fonts, so the scroll
    /// position holds while the colors fade in.
    private func applyStyled(to textView: DiffTextView) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        for line in document.lines where !line.isBand {
            guard let colored = styled[line.rowId],
                  colored.length == line.range.length - 1 else { continue }
            colored.enumerateAttributes(in: NSRange(location: 0, length: colored.length)) { attrs, range, _ in
                var overlay: [NSAttributedString.Key: Any] = [:]
                if let color = attrs[.foregroundColor] as? NSColor { overlay[.foregroundColor] = color }
                if let font = attrs[.font] as? NSFont { overlay[.font] = font }
                guard !overlay.isEmpty else { return }
                storage.addAttributes(overlay, range: NSRange(
                    location: line.range.location + range.location, length: range.length))
            }
        }
        storage.endEditing()
    }

    @MainActor
    final class Coordinator {
        var appliedDocument: DiffDocument?
        var appliedStyled: Int?
        weak var ruler: DiffGutterRulerView?

        func observeFrame(of textView: NSTextView) {
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: textView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            }
        }

        func observeScroll(of scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            }
        }
    }
}

// MARK: - Text view

/// The diff's text view: read-only but selectable, with the overlay's keys folded in —
/// ← / → walk the sibling files, Esc closes, ↑ / ↓ stay with scrolling (there is no
/// caret to move), and a click on an expandable band splices its lines back in.
final class DiffTextView: NSTextView {
    var document: DiffDocument?
    var onExpand: ((Int) -> Void)?
    var onWalk: ((Int) -> Bool)?
    var onClose: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let hasModifiers = !event.modifierFlags
            .intersection([.command, .option, .control, .shift]).isEmpty
        if !hasModifiers {
            switch event.keyCode {
            case 123: _ = onWalk?(-1); return    // ← — dies quietly at either end
            case 124: _ = onWalk?(+1); return    // →
            case 125: scroll(byLines: +3); return
            case 126: scroll(byLines: -3); return
            case 53: onClose?(); return          // Esc (find bar handles its own first)
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        if let anchor = expandableBand(at: event) {
            onExpand?(anchor)
            return
        }
        super.mouseDown(with: event)
    }

    /// The band under a click, hit anywhere across the row (the nearest-glyph mapping
    /// clamps horizontally; the fragment-rect check rejects clicks past the last line).
    private func expandableBand(at event: NSEvent) -> Int? {
        guard let document, let layoutManager, let textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let padding = DiffDocument.bandPadding
        guard local.y >= fragment.minY - padding, local.y <= fragment.maxY + padding else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard let line = document.line(at: character),
              case .band(_, expandable: true) = line.role else { return nil }
        return line.rowId
    }

    /// ⌘C copies the selected *code* — band labels are chrome, not content, so a
    /// selection sweeping across one drops the "n unchanged lines" text on the way
    /// to the pasteboard. (The gutter never needs stripping; it lives in the ruler.)
    override func copy(_ sender: Any?) {
        guard let document else { return super.copy(sender) }
        let content = string as NSString
        var pieces: [String] = []
        for value in selectedRanges {
            let selection = value.rangeValue
            guard selection.length > 0 else { continue }
            var kept = ""
            var index = document.lineIndex(at: selection.location)
            while index < document.lines.count {
                let line = document.lines[index]
                let overlap = NSIntersectionRange(line.range, selection)
                if overlap.length == 0, line.range.location >= NSMaxRange(selection) { break }
                if overlap.length > 0, !line.isBand {
                    kept += content.substring(with: overlap)
                }
                index += 1
            }
            if !kept.isEmpty { pieces.append(kept) }
        }
        guard !pieces.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pieces.joined(separator: "\n"), forType: .string)
    }

    private func scroll(byLines delta: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let lineHeight = layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 12)) ?? 14
        var origin = clip.bounds.origin
        origin.y += delta * lineHeight
        clip.scroll(to: clip.constrainBoundsRect(
            NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

// MARK: - Layout manager

/// Paints the diff's line semantics behind the text: full-width add/delete washes and
/// the bands' faint fills. Runs before `super.drawBackground`, so TextKit's own pass
/// (the intraline-emphasis `.backgroundColor` spans, the selection highlight) always
/// composites on top.
final class DiffWashLayoutManager: NSLayoutManager {
    var document: DiffDocument?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let document, let container = textContainers.first {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            // Washes span the full panel width, not just the laid-out text.
            let width = max(usedRect(for: container).width + origin.x,
                            container.textView?.bounds.width ?? 0)
            var index = document.lineIndex(at: charRange.location)
            while index < document.lines.count {
                let line = document.lines[index]
                index += 1
                if line.range.location >= NSMaxRange(charRange) { break }
                guard let fill = Self.fill(for: line.role) else { continue }
                let glyphs = glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
                var rect = boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.x = 0
                rect.size.width = width
                rect.origin.y += origin.y
                if line.isBand { rect = rect.insetBy(dx: 0, dy: -DiffDocument.bandPadding) }
                fill.setFill()
                rect.fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    static func fill(for role: DiffDocument.Line.Role) -> NSColor? {
        switch role {
        case .code(.addition): return NSColor.systemGreen.withAlphaComponent(0.13)
        case .code(.deletion): return NSColor.systemRed.withAlphaComponent(0.13)
        case .band: return NSColor.labelColor.withAlphaComponent(0.045)
        case .code: return nil
        }
    }
}
