import AppKit
import SwiftUI

/// A soft-wrapped, monospaced `NSTextView` whose backing store is Highlightr's `CodeAttributedString`
/// — so syntax highlighting happens in the text storage as the buffer changes, no manual re-coloring.
/// AppKit's prose conveniences (smart quotes, dashes, replacement, spell-check) are off for code, and
/// long lines wrap rather than scroll horizontally.
struct HighlightedTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursor: EditorCursor?
    let language: String?
    let theme: String
    let font: NSFont
    let backgroundColor: NSColor
    let caretColor: NSColor
    let lineNumberColor: NSColor
    /// The full-width wash under the caret's line (Xcode-style), already dimmed to sit on any
    /// terminal background. Only drawn while the buffer is editable — a read-only peek has no
    /// caret, so a highlighted line would just be a mystery stripe.
    let currentLineColor: NSColor
    /// When false the text stays selectable (copyable) but cannot be typed into — the read-only
    /// preview path. Defaults to editable so the inspector's own opens are unchanged.
    var isEditable: Bool = true
    /// A 1-based line to scroll to and flash (a content-search hit). Applied once on creation and
    /// again whenever the value changes — clicking a different hit in the same file re-scrolls.
    var jumpToLine: Int? = nil
    /// Appends a "Close" item to the right-click menu — the editor closes terminal-style, alongside
    /// the toolbar button. Left off wherever the text view isn't the closable editor overlay.
    var showsCloseMenuItem: Bool = false
    /// Invoked when the user presses ⌘S — flushes the buffer to disk immediately.
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, cursor: $cursor) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = context.coordinator.textStorage
        _ = storage.highlightr.setTheme(to: theme)
        storage.highlightr.theme.setCodeFont(font)
        storage.language = language
        context.coordinator.appliedTheme = theme
        context.coordinator.appliedFont = font
        context.coordinator.appliedLanguage = language

        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = true          // wrap to the view width
        layoutManager.addTextContainer(container)

        let textView = SavingTextView(frame: .zero, textContainer: container)
        textView.onSave = onSave
        textView.showsCloseMenuItem = showsCloseMenuItem
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        apply(to: textView)

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

        // Xcode-style line-number gutter down the leading edge.
        let ruler = LineNumberRulerView(
            scrollView: scrollView, editorFont: font,
            numberColor: lineNumberColor, gutterColor: backgroundColor
        )
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler

        // The ruler must fully redraw on three events: lines added/removed, the view re-wrapping on
        // resize (both via the text view's frame changes), and — crucially — *scrolling*. AppKit's
        // copy-on-scroll only repaints the newly-exposed strip, so without a full invalidation the
        // gutter's absolutely-positioned numbers desync into a garbled smear. Observing the clip
        // view's bounds change and forcing `needsDisplay` repaints every number at its true position.
        textView.postsFrameChangedNotifications = true
        context.coordinator.observeFrame(of: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(of: scrollView)

        // Claim first responder once the editor is in a window, so the Edit menu's Cut/Copy/Paste
        // (and typing) act on this buffer instead of the terminal surface that held focus beneath
        // the overlay. The terminal focus driver won't fight back — its `canFocus` bails while a
        // file is open (see `requestTerminalFocus`).
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }

        // Reveal the requested line once the view has a real frame — at make time it hasn't been
        // laid out, so scrolling now would land nowhere.
        if let jumpToLine {
            context.coordinator.appliedJumpLine = jumpToLine
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                Self.reveal(line: jumpToLine, in: textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SavingTextView else { return }
        // Refresh the save closure each update so ⌘S always flushes the latest buffer (the closure
        // captures the view's current state, which SwiftUI re-creates on every change).
        textView.onSave = onSave
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        let coordinator = context.coordinator
        let storage = coordinator.textStorage

        // Re-theme / re-font only when they actually change (an appearance or font-setting switch) —
        // not on every keystroke. Each is a whole-document recolor, so doing it per edit would jank
        // large files; the text storage already re-highlights edited ranges incrementally on its own.
        var needsRehighlight = false
        if coordinator.appliedTheme != theme {
            _ = storage.highlightr.setTheme(to: theme)
            coordinator.appliedTheme = theme
            needsRehighlight = true
        }
        if coordinator.appliedFont != font {
            storage.highlightr.theme.setCodeFont(font)
            coordinator.appliedFont = font
            needsRehighlight = true
        }
        if coordinator.appliedLanguage != language {
            coordinator.appliedLanguage = language
            needsRehighlight = true
        }
        // Setting the language re-runs the highlight over the whole document, applying any new theme
        // colors — so it doubles as the "re-color everything" trigger after a theme/font change.
        if needsRehighlight { storage.language = language }

        // Only overwrite on a genuine external change — writing on every keystroke would stomp the
        // insertion point. In practice text only changes from inside this view.
        if textView.string != text { textView.string = text }
        apply(to: textView)
        scrollView.backgroundColor = backgroundColor
        scrollView.contentView.backgroundColor = backgroundColor
        coordinator.ruler?.restyle(editorFont: font, numberColor: lineNumberColor, gutterColor: backgroundColor)

        // A new jump target while the same file stays open (the user clicked another search hit).
        if jumpToLine != coordinator.appliedJumpLine {
            coordinator.appliedJumpLine = jumpToLine
            if let jumpToLine { Self.reveal(line: jumpToLine, in: textView) }
        }
    }

    private func apply(to textView: NSTextView) {
        textView.font = font
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = caretColor
        if let saving = textView as? SavingTextView {
            saving.currentLineColor = currentLineColor
            // The matched pair glows in the caret's own accent, dimmed to a wash.
            saving.bracketHighlightColor = caretColor.withAlphaComponent(0.28)
        }
    }

    /// Scrolls the 1-based `line` into view, parks the caret at its start, and flashes the find
    /// indicator over it — Xcode's jump-to-line gesture. The caret is placed with a zero-length
    /// selection (not the whole line) so a keystroke in an editable buffer can't wipe the line.
    private static func reveal(line: Int, in textView: NSTextView) {
        let full = textView.string as NSString
        guard full.length > 0 else { return }
        let location = TextPositions.offset(ofLine: line, in: full)
        let lineRange = full.lineRange(for: NSRange(location: location, length: 0))
        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
        textView.scrollRangeToVisible(lineRange)
        textView.showFindIndicator(for: lineRange)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let textStorage = CodeAttributedString()
        /// What's currently applied to the text storage, so `updateNSView` only re-themes / re-fonts
        /// / re-highlights when something genuinely changed (not on every keystroke).
        var appliedTheme: String?
        var appliedFont: NSFont?
        var appliedLanguage: String?
        /// The last jump target acted on, so `updateNSView` only re-scrolls on a genuine new hit.
        var appliedJumpLine: Int?
        weak var ruler: LineNumberRulerView?
        private let text: Binding<String>
        private let cursor: Binding<EditorCursor?>

        init(text: Binding<String>, cursor: Binding<EditorCursor?>) {
            self.text = text
            self.cursor = cursor
        }

        /// Redraw the gutter whenever the text view's frame changes — new lines grow it, a window
        /// resize re-wraps it; both shift where each line sits.
        func observeFrame(of textView: NSTextView) {
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: textView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            }
        }

        /// Fully redraw the gutter on every scroll tick — AppKit's copy-on-scroll otherwise leaves
        /// stale, smeared numbers (and numbers stranded in the titlebar strip) behind.
        func observeScroll(of scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            ruler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            (textView as? SavingTextView)?.caretDidMove()
            let location = textView.selectedRange().location
            let full = textView.string as NSString
            guard location <= full.length else { return }
            let (line, column) = TextPositions.lineColumn(utf16Offset: location, in: full)
            cursor.wrappedValue = EditorCursor(line: line, column: column)
        }
    }
}

/// An `NSTextView` that intercepts ⌘S to flush a manual save before AppKit routes it anywhere else,
/// then lets every other key equivalent fall through unchanged. The editor auto-saves on idle, so
/// this only serves the reflex of pressing ⌘S — there is still no Save button. It also draws the
/// Xcode-style current-line band and washes the bracket pair beside the caret.
private final class SavingTextView: NSTextView {
    var onSave: (() -> Void)?
    /// When set, the right-click menu carries a trailing "Close" — the editor's only close
    /// affordance now that it has no chrome button (terminal-style, matching how a session closes).
    var showsCloseMenuItem = false
    /// Full-width wash under the caret's line; `.clear` (or a read-only buffer) draws nothing.
    var currentLineColor: NSColor = .clear { didSet { needsDisplay = true } }
    /// Background wash on a bracket pair when the caret sits against one of them.
    var bracketHighlightColor: NSColor = .clear

    /// The bracket pair currently washed, so the previous pair can be cleanly un-washed.
    private var bracketRanges: [NSRange] = []
    /// Start offset of the line last painted with the current-line band (-1 = none), so caret
    /// moves within one line skip the repaint.
    private var lastCaretLineStart = -1

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A deliberately minimal right-click menu — just the edit basics and a prominent Close —
    /// instead of AppKit's full text menu (Look Up, Translate, Font, Substitutions, Speech,
    /// Layout Orientation, Services…), which buried Close under a wall of items an editor covering
    /// the terminal has no use for. `cut`/`copy`/`paste` route through the responder chain, so they
    /// auto-enable off the selection and clipboard exactly like the native items did.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard showsCloseMenuItem else { return super.menu(for: event) }
        let menu = NSMenu()
        if isEditable {
            menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        if isEditable {
            menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close", action: #selector(closeEditorOverlay), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func closeEditorOverlay() {
        // The same teardown the toolbar X used to post — `TerminalPane` flushes and clears the editor.
        NotificationCenter.default.post(name: .termioCloseContentOverlay, object: nil)
    }

    // MARK: Current line

    /// Xcode-style band under the logical line holding the caret (all of its wrapped rows),
    /// drawn behind the text. Only for a zero-length selection — a real selection is its own
    /// highlight — and only while editable, since a read-only peek shows no caret.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard isEditable, currentLineColor.alphaComponent > 0,
              let layoutManager, let textContainer else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let text = string as NSString

        var lineRect: NSRect
        if text.length == 0 || (selection.location == text.length && text.character(at: text.length - 1) == 0x0A) {
            // The empty trailing line (or empty document) has no glyphs — AppKit tracks its
            // fragment separately.
            lineRect = layoutManager.extraLineFragmentRect
            if lineRect.isEmpty {
                lineRect = NSRect(x: 0, y: 0, width: 0, height: layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 12)))
            }
        } else {
            let caret = min(selection.location, text.length - 1)
            let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        }
        lineRect.origin.y += textContainerOrigin.y
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        guard lineRect.intersects(rect) else { return }
        currentLineColor.setFill()
        lineRect.fill()
    }

    /// Selection moved: the line band follows the caret, and the bracket wash re-derives.
    /// The full-view repaint only fires when the caret actually changed lines — per-keystroke
    /// full redraws would scale typing cost with the visible glyph count for nothing (edits on
    /// the same line already invalidate their own rects through the layout manager).
    func caretDidMove() {
        let selection = selectedRange()
        let text = string as NSString
        var lineStart = -1 // "no band": a real selection, or an empty document
        if selection.length == 0, text.length > 0 {
            if selection.location == text.length, text.character(at: text.length - 1) == 0x0A {
                lineStart = text.length // the trailing empty line is its own row
            } else {
                let caret = min(selection.location, text.length - 1)
                lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
            }
        }
        if lineStart != lastCaretLineStart {
            lastCaretLineStart = lineStart
            needsDisplay = true
        }
        updateBracketMatch()
    }

    // MARK: Bracket matching

    /// Washes the bracket beside the caret and its partner (`BracketMatcher` carries the
    /// scan-bound and strings-can-fool-it tradeoffs).
    private func updateBracketMatch() {
        if !bracketRanges.isEmpty, let layoutManager {
            for range in bracketRanges {
                // Clamp against the *current* length — an edit can shrink the text between
                // caret moves, and removing an attribute past the end raises.
                guard let clamped = Self.clamp(range, to: (string as NSString).length) else { continue }
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clamped)
            }
            bracketRanges = []
        }
        // Caret decorations belong to editing; a read-only peek advertises no caret.
        guard isEditable, bracketHighlightColor.alphaComponent > 0, let layoutManager else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let text = string as NSString
        // The bracket just left of the caret wins (the one you typed or stepped past), else the
        // one right under it.
        for index in [selection.location - 1, selection.location]
        where index >= 0 && index < text.length {
            guard let match = BracketMatcher.match(at: index, in: text) else { continue }
            bracketRanges = [NSRange(location: index, length: 1), NSRange(location: match, length: 1)]
            for range in bracketRanges {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: bracketHighlightColor, forCharacterRange: range
                )
            }
            return
        }
    }

    /// `range` cut down to fit a text of `length`, or `nil` when it starts past the end.
    private static func clamp(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location < length else { return nil }
        return NSRange(location: range.location, length: min(range.length, length - range.location))
    }
}
