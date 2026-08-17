import AppKit
import SwiftUI

/// A soft-wrapped, monospaced `NSTextView` whose backing store is Highlightr's `CodeAttributedString`
/// — so syntax highlighting happens in the text storage as the buffer changes, no manual re-coloring.
/// AppKit's prose conveniences (smart quotes, dashes, replacement, spell-check) are off for code, and
/// long lines wrap rather than scroll horizontally.
struct HighlightedTextView: NSViewRepresentable {
    @Binding var text: String
    let language: String?
    let theme: String
    let font: NSFont
    /// Extra leading between lines (points), from the configured code line height.
    let lineSpacing: CGFloat
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
    /// Search query for the in-editor find bar. Empty string clears highlights.
    var findQuery: String = ""
    var findOptions: FindOptions = FindOptions()
    /// 0-based match to focus; ignored on empty query or empty result.
    var findFocusedIndex: Int = 0
    /// Fires with the total match count after any recompute (new query, options, or edit).
    var onMatchesChanged: ((Int) -> Void)? = nil
    /// Appends a "Close" item to the right-click menu — the editor closes terminal-style, alongside
    /// the toolbar button. Left off wherever the text view isn't the closable editor overlay.
    var showsCloseMenuItem: Bool = false
    /// "Add to Chat" in the right-click menu. The argument is the selected text, `nil`
    /// when nothing is selected — the owner sends the selection as a pasted snippet, or
    /// falls back to the document's path (Cursor's split: selection → snippet, file →
    /// reference). Injected (the text view has no reach into the store); `canAddToChat`
    /// is read at menu-open time, so a plain-shell session shows no item.
    var addToChat: ((String?) -> Void)? = nil
    var canAddToChat: (() -> Bool)? = nil
    /// Invoked when the user presses ⌘S — flushes the buffer to disk immediately.
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = context.coordinator.textStorage
        _ = storage.highlightr.setTheme(to: theme)
        storage.highlightr.theme.setCodeFont(font)
        storage.highlightr.theme.codeParagraphStyle = Self.paragraphStyle(font: font, lineSpacing: lineSpacing)
        storage.highlightr.theme.codeBaselineOffset = Self.baselineOffset(lineSpacing: lineSpacing)
        storage.language = language
        context.coordinator.appliedTheme = theme
        context.coordinator.appliedFont = font
        context.coordinator.appliedLanguage = language
        context.coordinator.appliedLineSpacing = lineSpacing

        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = true          // wrap to the view width
        layoutManager.addTextContainer(container)

        let textView = SavingTextView(frame: .zero, textContainer: container)
        textView.onSave = onSave
        textView.showsCloseMenuItem = showsCloseMenuItem
        textView.addToChat = addToChat
        textView.canAddToChat = canAddToChat
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
            numberColor: lineNumberColor, gutterColor: backgroundColor,
            baselineShift: Self.gutterBaselineShift(font: font, lineSpacing: lineSpacing)
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
            coordinator.appliedFont = font
            needsRehighlight = true
        }
        if coordinator.appliedLineSpacing != lineSpacing {
            coordinator.appliedLineSpacing = lineSpacing
            needsRehighlight = true
        }
        if coordinator.appliedLanguage != language {
            coordinator.appliedLanguage = language
            needsRehighlight = true
        }
        // Setting the language re-runs the highlight over the whole document, applying any new theme
        // colors — so it doubles as the "re-color everything" trigger after a theme/font change.
        // `setTheme` above replaces the whole `Theme` instance (dropping its font and line metrics),
        // so the font, line height, and baseline lift are reasserted as one package first.
        if needsRehighlight {
            storage.highlightr.theme.setCodeFont(font)
            storage.highlightr.theme.codeParagraphStyle = Self.paragraphStyle(font: font, lineSpacing: lineSpacing)
            storage.highlightr.theme.codeBaselineOffset = Self.baselineOffset(lineSpacing: lineSpacing)
            storage.language = language
        }

        // Only overwrite on a genuine external change — writing on every keystroke would stomp the
        // insertion point. Never while an input method is composing: marked text lives in the view
        // but not in the binding (AppKit doesn't fire textDidChange for setMarkedText), so the two
        // strings differ for the whole composition — overwriting then kills the composition and
        // throws the caret to the end of the document on any unrelated SwiftUI re-render.
        if textView.string != text, !textView.hasMarkedText() {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(
                NSRange(location: location, length: min(selection.length, length - location))
            )
            // A programmatic replace bypasses textDidChange, so the gutter's line anchor
            // must be reset here.
            coordinator.ruler?.invalidateLineAnchor()
        }
        apply(to: textView)
        scrollView.backgroundColor = backgroundColor
        scrollView.contentView.backgroundColor = backgroundColor
        coordinator.ruler?.restyle(
            editorFont: font, numberColor: lineNumberColor, gutterColor: backgroundColor,
            baselineShift: Self.gutterBaselineShift(font: font, lineSpacing: lineSpacing)
        )

        // A new jump target while the same file stays open (the user clicked another search hit).
        if jumpToLine != coordinator.appliedJumpLine {
            coordinator.appliedJumpLine = jumpToLine
            if let jumpToLine { Self.reveal(line: jumpToLine, in: textView) }
        }

        coordinator.onMatchesChanged = onMatchesChanged
        coordinator.updateFind(query: findQuery, options: findOptions, focusedIndex: findFocusedIndex, in: textView)
    }

    /// Shared between the theme's highlight attributes and the view's typing attributes so
    /// freshly typed text lays out at the same height before its first highlight pass.
    /// A fixed line height (the font's natural height plus the configured extra) instead of
    /// `lineSpacing`: TextKit hangs `lineSpacing` entirely *below* the glyphs, which left the
    /// text riding the top of the current-line band and the caret. Fixing the height makes the
    /// glyphs bottom-align instead; `baselineOffset(lineSpacing:)` lifts them to the center.
    static func paragraphStyle(font: NSFont, lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = NSLayoutManager().defaultLineHeight(for: font) + lineSpacing
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }

    /// Half the extra leading — lifts the bottom-aligned glyphs to sit centered in the fixed-height
    /// line. Must travel with `paragraphStyle(font:lineSpacing:)` everywhere (typing attributes and
    /// the theme's highlight attributes alike), or freshly typed text would jump on its first
    /// highlight pass.
    static func baselineOffset(lineSpacing: CGFloat) -> CGFloat {
        lineSpacing / 2
    }

    /// How far below each line fragment's top the glyph tops now sit (the font's own leading plus
    /// the centering lift) — the gutter shifts its numbers by the same amount so they keep riding
    /// the code's baseline.
    static func gutterBaselineShift(font: NSFont, lineSpacing: CGFloat) -> CGFloat {
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        let leading = max(0, natural - font.ascender + font.descender)
        return leading + baselineOffset(lineSpacing: lineSpacing)
    }

    private func apply(to textView: NSTextView) {
        // `NSText.font` is a whole-document setter — assigning it stamps the plain face over
        // every glyph, wiping the bold/italic variants the markdown highlight applied (invisible
        // in code files, a per-keystroke flicker of `**strong**` runs in markdown). Only touch it
        // when the configured font genuinely changed; the re-highlight rebuilds the variants.
        if textView.font != font { textView.font = font }
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = caretColor
        let style = Self.paragraphStyle(font: font, lineSpacing: lineSpacing)
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.paragraphStyle] = style
        textView.typingAttributes[.baselineOffset] = Self.baselineOffset(lineSpacing: lineSpacing)
        if let saving = textView as? SavingTextView {
            saving.currentLineColor = currentLineColor
            saving.caretIndicatorColor = caretColor
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
        var appliedLineSpacing: CGFloat?
        var appliedLanguage: String?
        /// The last jump target acted on, so `updateNSView` only re-scrolls on a genuine new hit.
        var appliedJumpLine: Int?
        weak var ruler: LineNumberRulerView?
        var onMatchesChanged: ((Int) -> Void)?
        private let text: Binding<String>
        private let find = TextFindEngine()
        private var appliedFindQuery: String = ""
        private var appliedFindOptions: FindOptions = FindOptions()
        private var appliedFocusedIndex: Int = -1
        /// Block-based notification tokens, removed on teardown — without this every opened file
        /// left two registrations behind for the lifetime of the process.
        private let observers = NotificationObserverBag()

        init(text: Binding<String>) {
            self.text = text
        }

        /// Redraw the gutter whenever the text view's frame changes — new lines grow it, a window
        /// resize re-wraps it; both shift where each line sits.
        func observeFrame(of textView: NSTextView) {
            observers.add(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: textView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            })
        }

        /// Fully redraw the gutter on every scroll tick — AppKit's copy-on-scroll otherwise leaves
        /// stale, smeared numbers (and numbers stranded in the titlebar strip) behind.
        func observeScroll(of scrollView: NSScrollView) {
            observers.add(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            })
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            ruler?.invalidateLineAnchor()
            ruler?.needsDisplay = true
            if !appliedFindQuery.isEmpty {
                find.recompute(query: appliedFindQuery, options: appliedFindOptions, in: textView)
                // An edit reshuffles the matches, so repaint the highlights — but the user is
                // typing in the document, not navigating, so don't steal the scroll or re-pulse
                // the find indicator.
                find.paint(focused: min(appliedFocusedIndex, find.matches.count - 1), reveal: false, in: textView)
                (textView as? SavingTextView)?.reassertBracketMatch()
                notifyMatchCount()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            (textView as? SavingTextView)?.caretDidMove()
        }

        /// Recompute + repaint after a new query, option change, or focus move. Same query
        /// with a new focused index only re-scrolls.
        func updateFind(query: String, options: FindOptions, focusedIndex: Int, in textView: NSTextView) {
            let queryChanged = query != appliedFindQuery || options != appliedFindOptions
            if queryChanged {
                appliedFindQuery = query
                appliedFindOptions = options
                find.recompute(query: query, options: options, in: textView)
                notifyMatchCount()
                appliedFocusedIndex = -1
            }
            // Every unrelated SwiftUI re-render (caret moves, footer refresh) flows through
            // `updateNSView` → here. Bail unless the query, options, or focused match actually
            // moved, so we don't churn the temporary attributes or re-fire the find pulse.
            guard queryChanged || focusedIndex != appliedFocusedIndex else { return }
            find.paint(focused: focusedIndex, reveal: true, in: textView)
            (textView as? SavingTextView)?.reassertBracketMatch()
            appliedFocusedIndex = focusedIndex
        }

        /// SwiftUI forbids mutating parent state inside `updateNSView`, so defer the callback
        /// to the next runloop.
        private func notifyMatchCount() {
            let count = find.matches.count
            let callback = onMatchesChanged
            DispatchQueue.main.async { callback?(count) }
        }
    }
}

/// Block-based notification tokens whose last-resort teardown lives in the bag's own deinit: the
/// owning views' deinits are nonisolated in Swift 6 and cannot touch main-actor state, but dropping
/// an owner drops its bag, which still removes every registration.
///
/// @unchecked: the tokens are only ever added or removed on the main actor, and the deinit reads
/// them once nothing can reach the bag any more.
private final class NotificationObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
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
    /// "Add to Chat": the argument is the selected text (`nil` = whole file, the owner
    /// inserts its path). The gate is read at menu-open time; a plain shell shows no item.
    var addToChat: ((String?) -> Void)?
    var canAddToChat: (() -> Bool)?
    /// Full-width wash under the caret's line; `.clear` (or a read-only buffer) draws nothing.
    /// Reassigned from every representable update, so only a genuine change may invalidate —
    /// an unconditional `didSet` forced a full-view repaint per keystroke, defeating the
    /// caret-line optimization in `caretDidMove`.
    var currentLineColor: NSColor = .clear {
        didSet { if currentLineColor != oldValue { needsDisplay = true } }
    }
    /// Background wash on a bracket pair when the caret sits against one of them.
    var bracketHighlightColor: NSColor = .clear

    /// The system insertion indicator (macOS 14's `NSTextInsertionIndicator`) in place of the
    /// legacy hard-blink caret — the same soft fade-and-glide caret Xcode shows. TextKit 2 text
    /// views adopt it automatically; this TextKit 1 view hosts it as a subview instead: the
    /// legacy caret draw is suppressed in `drawInsertionPoint`, and the indicator is repositioned
    /// (with a short glide) on every caret move.
    private let insertionIndicator = NSTextInsertionIndicator()
    /// Tint for the indicator; the view's own `insertionPointColor` no longer draws anything.
    var caretIndicatorColor: NSColor = .textColor {
        didSet { insertionIndicator.color = caretIndicatorColor }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        insertionIndicator.displayMode = .hidden
        addSubview(insertionIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The bracket pair currently washed, so the previous pair can be cleanly un-washed.
    private var bracketRanges: [NSRange] = []
    /// Start offset of the line last painted with the current-line band (-1 = none), so caret
    /// moves within one line skip the repaint.
    private var lastCaretLineStart = -1

    /// Turn off Core Graphics font smoothing before AppKit lays down glyphs. On a dark terminal
    /// background CG "smoothing" fattens every stroke, so the same face reads heavier here than in
    /// the Ghostty surface beside it (Ghostty draws its own glyphs and skips this). Killing it per
    /// draw keeps the editor's weight matched to the terminal. (Xcode fought the same battle; its
    /// modern answer is to defer to the system setting — we instead pin it off for in-window
    /// consistency.)
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }

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
    /// the terminal has no use for.
    ///
    /// The edit items go through private wrappers rather than `cut:` / `copy:` / `paste:` because
    /// macOS 26 decorates the standard editing selectors with a system symbol that cannot be
    /// cleared — `item.image = nil` reads back as the symbol again. The wrappers forward to the
    /// real actions and `validateUserInterfaceItem` restores the selection / clipboard gating the
    /// responder chain used to do.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard showsCloseMenuItem else { return super.menu(for: event) }
        let menu = NSMenu()
        if isEditable {
            menu.addItem(withTitle: localized("Cut"), action: #selector(cutSelection), keyEquivalent: "")
        }
        menu.addItem(withTitle: localized("Copy"), action: #selector(copySelection), keyEquivalent: "")
        if isEditable {
            menu.addItem(withTitle: localized("Paste"), action: #selector(pasteClipboard), keyEquivalent: "")
        }
        menu.addItem(.separator())
        if canAddToChat?() == true {
            // One name everywhere (Cursor's): with a selection the selected text goes
            // over as a pasted snippet, without one the document's path — the context
            // says which, the label stays put.
            let add = NSMenuItem(title: localized("Add to Chat"), action: #selector(addToChatAction), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
        }
        let close = NSMenuItem(title: localized("Close"), action: #selector(closeEditorOverlay), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func addToChatAction() {
        let range = selectedRange()
        let selection = range.length > 0 ? (string as NSString).substring(with: range) : nil
        addToChat?(selection)
    }

    @objc private func cutSelection(_ sender: Any?) { cut(sender) }
    @objc private func copySelection(_ sender: Any?) { copy(sender) }
    @objc private func pasteClipboard(_ sender: Any?) { paste(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(cutSelection):
            return isEditable && selectedRange().length > 0
        case #selector(copySelection):
            return selectedRange().length > 0
        case #selector(pasteClipboard):
            return isEditable && NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    /// AppKit appends AutoFill + Services to an EDITABLE text view's context menu after
    /// BOTH `menu(for:)` and `willOpenMenu` — no override in that pipeline can strip
    /// them (the read-only diff view never gets them, which is why its plain
    /// `menu(for:)` sufficed). So the right-click menu is popped OUTSIDE the pipeline,
    /// the file tree's `popUp` shape, which AppKit never augments.
    override func rightMouseDown(with event: NSEvent) {
        guard showsCloseMenuItem, let menu = menu(for: event) else {
            return super.rightMouseDown(with: event)
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    /// The Services injector asks this before adding its submenu; refusing kills
    /// Services at the source — it covers the ctrl-click path, which still runs
    /// AppKit's own context-menu pipeline.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        showsCloseMenuItem
            ? nil
            : super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc private func closeEditorOverlay() {
        // The same teardown the toolbar X used to post — `TerminalPane` flushes and clears the editor.
        NotificationCenter.default.post(name: .termioCloseContentOverlay, object: nil)
    }

    // MARK: Insertion indicator

    /// The caret's bar width, matching the system indicator's own preference.
    private static let caretWidth: CGFloat = 2

    /// Whether this view currently holds first-responder status. Tracked here because inside
    /// `resignFirstResponder` the window still reports the *old* responder — asking the window
    /// would keep the caret alive through the handoff.
    private var isCaretFocused = false

    /// The legacy caret stays undrawn — `insertionIndicator` is the caret.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    override var isEditable: Bool {
        didSet { updateInsertionIndicator() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isCaretFocused = true
            updateInsertionIndicator()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            isCaretFocused = false
            updateInsertionIndicator()
        }
        return accepted
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A resize re-wraps the text, moving the caret's rect without any selection change.
        updateInsertionIndicator()
    }

    /// The caret follows the platform convention of showing only in the key window: re-evaluate
    /// on every key-status change of whichever window the view lands in.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowKeyObservers.removeAll()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowKeyObservers.add(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInsertionIndicator() }
            })
        }
    }

    private let windowKeyObservers = NotificationObserverBag()

    /// The one decision point for the caret: every input that can change its visibility or rect
    /// (selection, focus, editability, resize, window key status) funnels through here.
    private func updateInsertionIndicator() {
        guard isEditable, isCaretFocused, selectedRange().length == 0,
              let window, window.isKeyWindow else {
            insertionIndicator.displayMode = .hidden
            return
        }
        // `firstRect` (the input-method geometry query) over hand-rolled layout math: it already
        // answers for wrapped lines, marked text, and the trailing newline — the round-trip
        // through screen coordinates is the price of not duplicating those cases here.
        let caret = NSRange(location: selectedRange().location, length: 0)
        var rect = convert(
            window.convertFromScreen(firstRect(forCharacterRange: caret, actualRange: nil)),
            from: nil
        )
        if rect.height <= 0 {
            // An empty document has no glyphs for `firstRect` to measure; stand the caret at the
            // text origin at the line height every real line will use.
            let height = fixedLineHeight
            guard height > 0 else {
                insertionIndicator.displayMode = .hidden
                return
            }
            let padding = textContainer?.lineFragmentPadding ?? 0
            rect = NSRect(x: textContainerOrigin.x + padding, y: textContainerOrigin.y,
                          width: 0, height: height)
        }
        rect.size.width = Self.caretWidth
        // Always snap to the new position — a glide between caret positions read as lag on every
        // click (user report). The smoothness this indicator buys is the soft blink, not movement.
        insertionIndicator.frame = rect
        insertionIndicator.displayMode = .automatic
    }

    /// The fixed line height the paragraph style enforces, falling back to the font's natural
    /// height — shared by the empty-document caret and the empty-document current-line band so
    /// the two can never disagree.
    private var fixedLineHeight: CGFloat {
        if let height = defaultParagraphStyle?.minimumLineHeight, height > 0 { return height }
        guard let layoutManager else { return 0 }
        return layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 12))
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
                lineRect = NSRect(x: 0, y: 0, width: 0, height: fixedLineHeight)
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

    /// The find bar's repaint clears the temporary background color over the whole document,
    /// taking the bracket wash with it while `bracketRanges` still claims it's applied — re-derive
    /// the wash after any find repaint so the pair doesn't silently vanish until the caret moves.
    func reassertBracketMatch() {
        updateBracketMatch()
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
        updateInsertionIndicator()
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
