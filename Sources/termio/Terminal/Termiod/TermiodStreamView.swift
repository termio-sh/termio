import AppKit
import Carbon.HIToolbox
import GhosttyTerminal
import GhosttyVt
import QuartzCore
import TermioShared
import UniformTypeIdentifiers

/// The pane for a `vt_stream` session: it draws the link's client terminal and
/// says how much of a session it could show. It never sizes the terminal — the
/// session's grid comes only from the daemon's markers — so a pane larger than
/// the grid leaves room to the right and below, and a smaller one clips.
@MainActor
final class TermiodStreamView: NSView {
    /// The terminal to draw, read every frame: an attach replaces it with a
    /// fresh one, and the view follows without being told.
    var terminal: () -> TermiodStreamTerminal? = { nil }
    /// The grid this pane could hold, each time it changes. The link sends it
    /// as the viewport declaration the daemon's size policy reads.
    var onViewport: (TerminalGrid) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    /// The terminal's default background, each time it changes, for the
    /// pane's header (`TermiodStreamRenderer.background`).
    var onBackgroundColor: (NSColor) -> Void = { _ in }
    private var reportedBackground: (r: UInt8, g: UInt8, b: UInt8)?
    /// Writes bytes to the session as typed — the link's `send`, which claims
    /// the write token as typing in the embedded surface does. Only Ghostty's
    /// editing bindings use it; they send fixed bytes in any mode.
    var send: (Data) -> Void = { _ in }
    /// Sends a key, paste, mouse, wheel or focus event, which termiod encodes
    /// against its own VT's modes (`Termiod.InputEvent`).
    var sendInput: (Termiod.InputEvent) -> Void = { _ in }
    /// The session this pane shows, for app code that acts on the focused
    /// terminal (the paste interceptor).
    var sessionID: Session.ID?

    fileprivate let metalLayer = CAMetalLayer()
    fileprivate var renderer: TermiodStreamRenderer?
    private let scroller = TermiodStreamScroller()
    private var displayLinkHandle: CADisplayLink?
    /// Frames presented to the layer, for the debug snapshot: a window
    /// capture cannot read a Metal layer, so this is how a run says it drew.
    private(set) var framesPresented = 0
    private var drawnTerminal: ObjectIdentifier?
    fileprivate var needsFullDraw = true
    private var lastViewport: TerminalGrid?
    private var focused = false {
        didSet {
            guard focused != oldValue else { return }
            needsFullDraw = true
            onFocusChange(focused)
            if !focused { releaseHeldKeys() }
            sendInput(.focus(focused))
        }
    }

    /// Input-method state: the text being composed, and the strings a key
    /// event inserted while `interpretKeyEvents` ran.
    fileprivate var markedText = NSMutableAttributedString()
    fileprivate var markedSelection = NSRange(location: 0, length: 0)
    fileprivate var collectedText: [String]?
    fileprivate var interpretedCommand = false
    /// Ghostty's handshake for Control and Command keys the menu did not take
    /// (`performKeyEquivalent`).
    fileprivate var lastPerformKeyEvent: TimeInterval?
    /// Mouse buttons down that were reported to the program, so their
    /// releases are too, wherever the pointer is let go.
    fileprivate var reportedButtons: Set<UInt8> = []
    /// Where the program last saw the pointer, for releasing buttons the view
    /// never gets a mouse-up for.
    fileprivate var lastPointer: Termiod.InputEvent.Pointer?
    fileprivate var scrollRemainder = CGPoint.zero
    /// Keys whose press the program saw, by keycode, so each gets its release
    /// even when the pane loses the keyboard first.
    fileprivate var heldKeys: [UInt16: Termiod.InputEvent.Key] = [:]
    /// A left-button selection is in progress.
    fileprivate var selecting = false
    /// The link under the pointer while ⌘ is held.
    fileprivate var hoveredLink: TermiodStreamTerminal.Link?
    /// What the last hover looked at, so a resting pointer over unchanged
    /// text costs one counter read a frame, not a copy of its line.
    fileprivate var hoverKey: HoverKey?
    fileprivate var hoverLine: TermiodStreamTerminal.LineText?
    /// Settings ▸ Copy on select.
    var copyOnSelect = false
    /// Keys an editing binding took, whose releases the program never sees.
    fileprivate var consumedKeys: Set<UInt16> = []
    fileprivate var trackingArea: NSTrackingArea?
    /// The pane may take the keyboard, so a view mounted for it does as soon
    /// as it is in a window.
    var claimsFocus = false

    init(appearance: TermiodStreamRenderer.Appearance) {
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.pixelFormat = .bgra8Unorm
        // Theme colors are sRGB values, as the embedded surface treats them.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = appearance.backgroundOpacity >= 1
        metalLayer.maximumDrawableCount = 3
        layer = metalLayer
        scroller.onScrollToRow = { [weak self] row in
            guard let self else { return }
            self.terminal()?.scrollViewport(toRow: row)
            self.needsFullDraw = true
        }
        addSubview(scroller)
        do {
            let renderer = try TermiodStreamRenderer(appearance: appearance, scale: currentScale)
            metalLayer.device = renderer.device
            self.renderer = renderer
        } catch {
            Log.termiod.error("stream renderer unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var cellSize: CGSize? { renderer?.cellSize }
    /// Metal or the shaders could not be set up, so this view can draw nothing.
    var hasRenderer: Bool { renderer != nil }

    func setAppearance(_ appearance: TermiodStreamRenderer.Appearance) {
        guard let renderer else { return }
        do {
            metalLayer.isOpaque = appearance.backgroundOpacity >= 1
            if try renderer.update(appearance: appearance, scale: currentScale) {
                declareViewport()
            }
            needsFullDraw = true
        } catch {
            Log.termiod.error("stream renderer appearance: \(String(describing: error), privacy: .public)")
        }
    }

    private var currentScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        focused = window?.isKeyWindow ?? false
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        return true
    }

    /// A pane going off screen takes its view with it (Rex's rule: the
    /// terminal lives in the link, a view only while someone looks). Leaving
    /// here, rather than trusting a `resignFirstResponder` during removal,
    /// sends the program its key releases and focus-out, and drops unfinished
    /// input.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            if hasMarkedText() {
                inputContext?.discardMarkedText()
                unmarkText()
            }
            focused = false
            releaseHeldButtons()
            if selecting { releaseSelection(nil) }
            clearHoveredLink()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            displayLinkHandle?.invalidate()
            displayLinkHandle = nil
            // A pane leaving the window leaves no hand pointer behind.
            clearHoveredLink()
            return
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyWindowChanged), name: name, object: window
            )
        }
        viewDidChangeBackingProperties()
        if claimsFocus {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.claimsFocus, let window = self.window, window.firstResponder !== self else { return }
                window.makeFirstResponder(self)
            }
        }
        guard displayLinkHandle == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLinkHandle = link
    }

    /// The screen as this view draws it, offscreen at the drawable's size:
    /// what the debug snapshot writes and a pane drag lifts, since neither
    /// can read the layer.
    func screenImage() -> CGImage? {
        guard let renderer, let terminal = terminal() else { return nil }
        let size = metalLayer.drawableSize
        defer { needsFullDraw = true }
        return try? renderer.image(of: terminal, width: Int(size.width), height: Int(size.height), focused: focused)
    }

    @objc private func keyWindowChanged() {
        focused = window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = currentScale
        if let renderer, (try? renderer.update(appearance: renderer.appearance, scale: currentScale)) == true {
            declareViewport()
        }
        resizeDrawable()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scroller.frame = bounds
        resizeDrawable()
        declareViewport()
    }

    private func resizeDrawable() {
        let scale = metalLayer.contentsScale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        guard metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        needsFullDraw = true
    }

    private func declareViewport() {
        guard let renderer,
              let grid = TerminalGrid.fitting(
                  bounds.size, cell: renderer.cellSize,
                  paddingX: renderer.appearance.paddingX, paddingY: renderer.appearance.paddingY
              ),
              grid != lastViewport
        else { return }
        lastViewport = grid
        onViewport(grid)
    }

    @objc private func tick() {
        guard let renderer, let terminal = terminal() else { return }
        // Every frame, as Ghostty does: output scrolls under a resting
        // pointer, and ⌘ can be let go, or the app left, anywhere.
        updateHoveredLink(command: NSEvent.modifierFlags.contains(.command))
        let identity = ObjectIdentifier(terminal)
        let replaced = identity != drawnTerminal
        drawnTerminal = identity
        do {
            if try renderer.draw(
                terminal, into: metalLayer, focused: focused, force: needsFullDraw || replaced,
                preedit: markedText.length > 0 ? markedText.string : nil,
                link: hoveredLink
            ) {
                framesPresented += 1
            }
            needsFullDraw = false
            if let state = renderer.scrollbar {
                scroller.apply(state, cellHeight: renderer.cellSize.height, replaced: replaced)
            }
            let color = renderer.background
            if reportedBackground.map({ $0 != (color.r, color.g, color.b) }) ?? true {
                reportedBackground = (color.r, color.g, color.b)
                onBackgroundColor(NSColor(
                    srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1
                ))
            }
        } catch {
            Log.termiod.error("stream frame failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Keyboard and input methods

extension TermiodStreamView: @preconcurrency NSTextInputClient {
    /// Ghostty's AppKit `keyDown`: the event goes through the input method
    /// first, and what it inserted, if anything, rides the key event as text.
    override func keyDown(with event: NSEvent) {
        guard terminal() != nil else { return }
        if markedText.length == 0, let bytes = TermiodStreamKeyboard.naturalEditing(event) {
            // A binding, not a key: its release must not reach the program.
            consumedKeys.insert(event.keyCode)
            terminal()?.scrollViewportToBottom()
            send(bytes)
            return
        }
        let action: Termiod.InputEvent.Action = event.isARepeat ? .repeat : .press
        let composingBefore = markedText.length > 0
        let layoutBefore = composingBefore ? nil : Self.keyboardLayoutID
        collectedText = []
        interpretedCommand = false
        // As the embedded surface does: a key equivalent that reached here is
        // this key's own, so `doCommand` must not dispatch it a second time.
        lastPerformKeyEvent = nil
        interpretKeyEvents([event])
        let collected = collectedText ?? []
        collectedText = nil
        // A keystroke that switched the input source types nothing.
        if !composingBefore, layoutBefore != Self.keyboardLayoutID { return }
        if !collected.isEmpty {
            for text in collected {
                pressKey(TermiodStreamKeyboard.input(for: event, action: action, text: text), keyCode: event.keyCode)
            }
            return
        }
        // A key the input method took while composing is sent as composing,
        // which termiod encodes as nothing: Backspace edits the composition.
        let text = interpretedCommand ? nil : TermiodStreamKeyboard.typedText(of: event)
        pressKey(TermiodStreamKeyboard.input(
            for: event, action: action, text: text, composing: markedText.length > 0 || composingBefore
        ), keyCode: event.keyCode)
    }

    private func pressKey(_ key: Termiod.InputEvent.Key, keyCode: UInt16) {
        terminal()?.scrollViewportToBottom()
        // Typing clears the selection, Ghostty's `selection-clear-on-typing`.
        if Termiod.InputEvent.key(key).claimsWriter, terminal()?.hasSelection == true {
            terminal()?.clearSelection()
            needsFullDraw = true
        }
        heldKeys[keyCode] = key
        sendInput(.key(key))
    }

    override func keyUp(with event: NSEvent) {
        if consumedKeys.remove(event.keyCode) != nil { return }
        guard heldKeys.removeValue(forKey: event.keyCode) != nil else { return }
        sendInput(.key(TermiodStreamKeyboard.input(for: event, action: .release, text: nil)))
    }

    /// A modifier pressed or released alone, which the Kitty protocol can
    /// report. Its side decides which key it was.
    override func flagsChanged(with event: NSEvent) {
        updateHoveredLink(command: event.modifierFlags.contains(.command))
        guard markedText.length == 0, terminal() != nil else { return }
        // Each side has its own device bit, so releasing one Shift while the
        // other is held reads as the release it is.
        let device: Int32
        switch Int(event.keyCode) {
        case kVK_CapsLock: device = 0
        case kVK_Shift: device = NX_DEVICELSHIFTKEYMASK
        case kVK_RightShift: device = NX_DEVICERSHIFTKEYMASK
        case kVK_Control: device = NX_DEVICELCTLKEYMASK
        case kVK_RightControl: device = NX_DEVICERCTLKEYMASK
        case kVK_Option: device = NX_DEVICELALTKEYMASK
        case kVK_RightOption: device = NX_DEVICERALTKEYMASK
        case kVK_Command: device = NX_DEVICELCMDKEYMASK
        case kVK_RightCommand: device = NX_DEVICERCMDKEYMASK
        default: return
        }
        let held = device == 0
            ? event.modifierFlags.contains(.capsLock)
            : event.modifierFlags.rawValue & UInt(device) != 0
        let key = TermiodStreamKeyboard.input(for: event, action: held ? .press : .release, text: nil)
        if held {
            heldKeys[event.keyCode] = key
        } else {
            heldKeys.removeValue(forKey: event.keyCode)
        }
        sendInput(.key(key))
    }

    /// Releases every key the program saw go down, when the pane loses the
    /// keyboard: their real releases go to whatever has it next.
    func releaseHeldKeys() {
        for (_, key) in heldKeys {
            var release = key
            release.action = .release
            release.text = nil
            sendInput(.key(release))
        }
        heldKeys.removeAll()
        consumedKeys.removeAll()
    }

    /// Ghostty's: the editing keys it binds win over the menu; Control and
    /// Command keys go to the menu first, and come back here as a key the
    /// program receives when the menu has no item for them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, terminal() != nil else { return false }
        if markedText.length == 0, let move = TermiodStreamKeyboard.viewportMove(event) {
            terminal()?.moveViewport(move)
            scroller.userScrolled()
            needsFullDraw = true
            consumedKeys.insert(event.keyCode)
            return true
        }
        if TermiodStreamKeyboard.naturalEditing(event) != nil, markedText.length == 0 {
            keyDown(with: event)
            return true
        }
        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
                break
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }
        guard let translated = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode
        ) else { return false }
        keyDown(with: translated)
        return true
    }

    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
        // An editing command (Shift-Tab is `insertBacktab:`) still reaches the
        // program as the key that was pressed, without the text.
        interpretedCommand = true
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if collectedText != nil {
            collectedText?.append(text)
        } else if !text.isEmpty {
            // Text an input method commits outside a keystroke, as from the
            // character viewer, is text, not a key.
            sendInput(.paste(text))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else if let plain = string as? String {
            markedText = NSMutableAttributedString(string: plain)
        }
        markedSelection = selectedRange
    }

    func unmarkText() {
        markedText.mutableString.setString("")
        markedSelection = NSRange(location: 0, length: 0)
    }

    func selectedRange() -> NSRange {
        markedText.length > 0 ? markedSelection : NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard markedText.length > 0 else { return nil }
        let location = min(max(range.location, 0), markedText.length)
        let end = min(max(range.location + range.length, location), markedText.length)
        let clamped = NSRange(location: location, length: end - location)
        actualRange?.pointee = clamped
        return markedText.attributedSubstring(from: clamped)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// The cursor's cell on screen, where the candidate window goes.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let renderer, let cursor = terminal()?.cursorPosition else { return .zero }
        let cell = renderer.cellSize
        let viewRect = NSRect(
            x: renderer.appearance.paddingX + CGFloat(cursor.x) * cell.width,
            y: bounds.height - renderer.appearance.paddingY - CGFloat(cursor.y + 1) * cell.height,
            width: cell.width, height: cell.height
        )
        guard let window else { return viewRect }
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    private static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    // MARK: - Paste

    /// Edit ▸ Paste. A clipboard holding only an image goes to the program as
    /// Control-V, pressed and released, which agents answer by reading the
    /// image off the clipboard themselves — the embedded surface's rule. Text
    /// is pasted, and termiod brackets it as the program asked.
    @objc func paste(_ sender: Any?) {
        guard terminal() != nil else { return }
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.terminalPasteText() {
            terminal()?.scrollViewportToBottom()
            sendInput(.paste(text))
        } else if pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier]) {
            var controlV = Termiod.InputEvent.Key(
                key: "v", mods: TermiodStreamKeyboard.control, unshifted: 0x76
            )
            sendInput(.key(controlV))
            controlV.action = .release
            sendInput(.key(controlV))
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// The event's point in pixels from the grid's top-left corner, in the
    /// cell size this pane draws.
    private func pointer(_ event: NSEvent) -> Termiod.InputEvent.Pointer? {
        guard let renderer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let scale = metalLayer.contentsScale
        return Termiod.InputEvent.Pointer(
            x: Float(point.x * scale - (renderer.appearance.paddingX * scale).rounded()),
            y: Float((bounds.height - point.y) * scale - (renderer.appearance.paddingY * scale).rounded()),
            cellWidth: UInt32(renderer.atlas.metrics.width), cellHeight: UInt32(renderer.atlas.metrics.height)
        )
    }

    private func onGrid(_ at: Termiod.InputEvent.Pointer) -> Bool {
        guard let grid = terminal()?.grid else { return false }
        return at.x >= 0 && at.y >= 0
            && at.x < Float(UInt32(grid.cols) * at.cellWidth) && at.y < Float(UInt32(grid.rows) * at.cellHeight)
    }

    private func selects(_ event: NSEvent) -> Bool {
        guard let terminal = terminal() else { return false }
        return !terminal.tracksMouse || event.modifierFlags.contains(.shift)
    }

    /// The pointer as a selection sees it: the viewport cell under it, and
    /// where it is in the pane in pixels.
    private func selectionPoint(_ event: NSEvent) -> TermiodStreamTerminal.SelectionPoint? {
        selectionPoint(at: event.locationInWindow)
    }

    private func selectionPoint(at location: NSPoint) -> TermiodStreamTerminal.SelectionPoint? {
        guard let renderer else { return nil }
        let point = convert(location, from: nil)
        let scale = metalLayer.contentsScale
        let x = point.x * scale
        let y = (bounds.height - point.y) * scale
        let left = (renderer.appearance.paddingX * scale).rounded()
        let top = (renderer.appearance.paddingY * scale).rounded()
        let width = CGFloat(max(1, renderer.atlas.metrics.width))
        let height = CGFloat(max(1, renderer.atlas.metrics.height))
        return TermiodStreamTerminal.SelectionPoint(
            column: UInt16(clamping: Int(max(0, (x - left) / width))),
            row: UInt16(clamping: Int(max(0, (y - top) / height))),
            x: Double(x), y: Double(y)
        )
    }

    private func pressSelection(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let terminal = terminal(), let point = selectionPoint(event) else { return }
        selecting = true
        let time = UInt64(max(0, event.timestamp) * 1_000_000_000)
        terminal.pressSelection(
            at: point, time: time, interval: UInt64(NSEvent.doubleClickInterval * 1_000_000_000),
            distance: Double(renderer?.atlas.metrics.width ?? 1)
        )
        needsFullDraw = true
    }

    private func dragSelection(_ event: NSEvent) {
        guard let terminal = terminal(), let renderer, let point = selectionPoint(event) else { return }
        let scale = metalLayer.contentsScale
        terminal.dragSelection(
            to: point,
            geometry: .init(
                cellWidth: UInt32(max(1, renderer.atlas.metrics.width)),
                paddingLeft: UInt32((renderer.appearance.paddingX * scale).rounded()),
                screenHeight: UInt32(max(1, bounds.height * scale))
            ),
            // ⌥-drag selects a block, as in Ghostty.
            rectangle: event.modifierFlags.contains(.option)
        )
        needsFullDraw = true
    }

    private func releaseSelection(_ event: NSEvent?) {
        selecting = false
        guard let terminal = terminal() else { return }
        terminal.releaseSelection(at: event.flatMap(selectionPoint))
        if copyOnSelect, let text = terminal.selectedText, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        needsFullDraw = true
    }

    // MARK: - Copy

    /// Edit ▸ Copy: the selection as Ghostty copies it.
    @objc func copy(_ sender: Any?) {
        guard let text = terminal()?.selectedText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        terminal()?.selectAll()
        needsFullDraw = true
    }

    /// A press on the grid goes to a program tracking the mouse, unless Shift
    /// is held: Ghostty keeps Shift-click for the terminal's own selection.
    /// A program can ask Ghostty for Shift-clicks too (`XTSHIFTESCAPE`);
    /// libghostty-vt does not say whether one did, so here Shift always stays
    /// the terminal's.
    private func press(_ event: NSEvent, _ button: UInt8) {
        window?.makeFirstResponder(self)
        guard let terminal = terminal(), terminal.tracksMouse, !event.modifierFlags.contains(.shift),
              let at = pointer(event), onGrid(at)
        else { return }
        reportedButtons.insert(button)
        lastPointer = at
        sendInput(.mouse(.init(action: .press, button: button, mods: TermiodStreamKeyboard.mods(event.modifierFlags),
                               at: at, buttonsHeld: true)))
    }

    private func release(_ event: NSEvent, _ button: UInt8) {
        guard reportedButtons.remove(button) != nil, let at = pointer(event) else { return }
        sendInput(.mouse(.init(action: .release, button: button, mods: TermiodStreamKeyboard.mods(event.modifierFlags),
                               at: at, buttonsHeld: !reportedButtons.isEmpty)))
    }

    /// Releases every button the program saw go down, where it last saw the
    /// pointer: the view is leaving, so their mouse-ups will never reach it.
    private func releaseHeldButtons() {
        guard let at = lastPointer else {
            reportedButtons.removeAll()
            return
        }
        for button in reportedButtons.sorted() {
            reportedButtons.remove(button)
            sendInput(.mouse(.init(action: .release, button: button, mods: 0, at: at,
                                   buttonsHeld: !reportedButtons.isEmpty)))
        }
    }

    private func motion(_ event: NSEvent, _ button: UInt8?) {
        guard let terminal = terminal(), terminal.tracksMouse, let at = pointer(event) else { return }
        let held = button.flatMap { reportedButtons.contains($0) ? $0 : nil }
        lastPointer = at
        sendInput(.mouse(.init(action: .motion, button: held, mods: TermiodStreamKeyboard.mods(event.modifierFlags),
                               at: at, buttonsHeld: !reportedButtons.isEmpty)))
    }

    // The left button selects, as in Ghostty, unless the program tracks the
    // mouse and Shift is not held.
    override func mouseDown(with event: NSEvent) {
        if selects(event) {
            pressSelection(event)
        } else {
            // A click the program takes ends the terminal's selection, as in
            // Ghostty, so ⌘C cannot copy a highlight the program drew over.
            if terminal()?.hasSelection == true {
                terminal()?.clearSelection()
                needsFullDraw = true
            }
            press(event, 1)
        }
    }
    override func mouseUp(with event: NSEvent) {
        if selecting { releaseSelection(event) } else { release(event, 1) }
    }
    override func rightMouseDown(with event: NSEvent) { press(event, 2) }
    override func rightMouseUp(with event: NSEvent) { release(event, 2) }
    override func otherMouseDown(with event: NSEvent) {
        if let button = Self.otherButton(event) { press(event, button) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if let button = Self.otherButton(event) { release(event, button) }
    }
    override func mouseMoved(with event: NSEvent) {
        updateHoveredLink(command: event.modifierFlags.contains(.command))
        motion(event, nil)
    }

    override func mouseExited(with event: NSEvent) {
        clearHoveredLink()
    }

    /// Ghostty's link hover: with ⌘ held, the link under the pointer is
    /// underlined and the pointer becomes a hand. The app's ⌘-click monitor
    /// opens `TerminalLinkState.hoveredURL`, as it does for the embedded
    /// surface, even inside a program tracking the mouse.
    fileprivate func updateHoveredLink(command: Bool) {
        guard command, NSApp.isActive, let window, window.isKeyWindow, let terminal = terminal() else {
            clearHoveredLink()
            return
        }
        let location = window.mouseLocationOutsideOfEventStream
        // A panel or sheet over the pane takes the pointer, as it takes the click.
        guard bounds.contains(convert(location, from: nil)),
              let hit = window.contentView?.hitTest(location), hit === self || hit.isDescendant(of: self),
              let point = selectionPoint(at: location)
        else {
            clearHoveredLink()
            return
        }
        let key = HoverKey(
            terminal: ObjectIdentifier(terminal), column: point.column, row: point.row, changes: terminal.changes
        )
        guard key != hoverKey else { return }
        hoverKey = key
        switch terminal.lineUnder(point) {
        case .hyperlink(let link):
            hoverLine = nil
            setHoveredLink(link)
        case .text(let line):
            // Output elsewhere on screen leaves this line as it was.
            guard line != hoverLine else { return }
            hoverLine = line
            setHoveredLink(TermiodStreamTerminal.link(in: line))
        case .none:
            hoverLine = nil
            setHoveredLink(nil)
        }
    }

    fileprivate struct HoverKey: Equatable {
        var terminal: ObjectIdentifier
        var column: UInt16
        var row: UInt16
        var changes: UInt64
    }

    /// The pointer stopped hovering: the next ⌘ looks afresh.
    fileprivate func clearHoveredLink() {
        hoverKey = nil
        hoverLine = nil
        setHoveredLink(nil)
    }

    fileprivate func setHoveredLink(_ link: TermiodStreamTerminal.Link?) {
        guard link != hoveredLink else { return }
        hoveredLink = link
        TerminalLinkState.update(hoveredURL: link?.url)
    }
    override func mouseDragged(with event: NSEvent) {
        if selecting { dragSelection(event) } else { motion(event, 1) }
    }
    override func rightMouseDragged(with event: NSEvent) { motion(event, 2) }
    override func otherMouseDragged(with event: NSEvent) { motion(event, Self.otherButton(event)) }

    /// Ghostty's numbering for the buttons past the first two
    /// (`MouseButton(fromNSEventButtonNumber:)`): AppKit's 2 is the middle
    /// button, 3 and 4 are back and forward.
    static func otherButton(_ event: NSEvent) -> UInt8? {
        switch event.buttonNumber {
        case 2: return 3
        case 3: return 8
        case 4: return 9
        case 5: return 6
        case 6: return 7
        case 7: return 4
        case 8: return 5
        case 9: return 10
        case 10: return 11
        default: return nil
        }
    }

    /// Rows and columns to scroll, as Ghostty counts them: a trackpad's points
    /// add up to whole cells, and a wheel's notch is three, however small the
    /// delta macOS reports for it.
    override func scrollWheel(with event: NSEvent) {
        guard let terminal = terminal(), let renderer, let at = pointer(event) else { return }
        let rows: Int
        let columns: Int
        if event.hasPreciseScrollingDeltas {
            func whole(_ delta: CGFloat, _ remainder: inout CGFloat, cell: CGFloat) -> Int {
                remainder += delta
                let cells = min(max((remainder / max(1, cell)).rounded(.towardZero), -500), 500)
                remainder -= cells * max(1, cell)
                return Int(cells)
            }
            rows = -whole(event.scrollingDeltaY, &scrollRemainder.y, cell: renderer.cellSize.height)
            columns = -whole(event.scrollingDeltaX, &scrollRemainder.x, cell: renderer.cellSize.width)
        } else {
            func notches(_ delta: CGFloat) -> Int {
                guard delta != 0 else { return 0 }
                let magnitude = min(max(1, abs(delta)), 500)
                return Int((magnitude * 3).rounded(.towardZero)) * (delta < 0 ? -1 : 1)
            }
            rows = -notches(event.scrollingDeltaY)
            columns = -notches(event.scrollingDeltaX)
        }
        guard rows != 0 || columns != 0 else { return }
        // termiod bounds a turn as well; this keeps the conversion from trapping.
        let limit = 500
        let clampedRows = min(max(rows, -limit), limit)
        let clampedColumns = min(max(columns, -limit), limit)
        if terminal.wheelGoesToProgram {
            sendInput(.wheel(.init(rows: Int32(clampedRows), columns: Int32(clampedColumns),
                                   mods: TermiodStreamKeyboard.mods(event.modifierFlags), at: at)))
        } else if clampedRows != 0 {
            terminal.scrollViewport(rows: clampedRows)
            scroller.userScrolled()
            needsFullDraw = true
        }
    }
}

/// Rex's `SurfaceScroller`, which is Ghostty's macOS scroll view: a native
/// overlay scroller over an empty document as tall as the screen and its
/// history. The terminal still draws and scrolls itself. The knob follows the
/// VT's scrollbar state, and dragging it moves the VT's view to a row.
@MainActor
final class TermiodStreamScroller: NSScrollView {
    var onScrollToRow: (UInt64) -> Void = { _ in }
    private let document = NSView()
    private var state: TermiodStreamTerminal.Scrollbar?
    private var cellHeight: CGFloat = 0
    private var lastSentRow: UInt64?
    /// The clip view is being moved to match the VT, so the bounds change
    /// it posts is not the user's.
    private var applying = false
    /// The user is dragging the knob, so the VT follows the clip view and
    /// not the other way round.
    private var liveScrolling = false
    /// The wheel or a scrolling key moved the view since the last frame, so
    /// the next change shows the scroller. Output and trimmed history move
    /// the state too, and must not.
    private var pendingFlash = false

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: self
        )
    }

    /// Overlay always, even when the system setting changes while the pane
    /// is open: a legacy scroller would cover columns of a grid the daemon
    /// sizes, and take their clicks.
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    func userScrolled() {
        pendingFlash = true
    }

    @objc private func liveScrollStarted() {
        liveScrolling = true
    }

    @objc private func liveScrollEnded() {
        liveScrolling = false
        if let state { layoutDocument(state) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Only the scroller takes the mouse. Clicks, drags and wheel turns over
    /// the text belong to the terminal view under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSScroller ? hit : nil
    }

    /// AppKit clamps the clip view against the old document while the frame
    /// changes; that is layout, not the user scrolling.
    override func setFrameSize(_ newSize: NSSize) {
        applying = true
        super.setFrameSize(newSize)
        applying = false
        if let state { layoutDocument(state) }
    }

    /// Called every frame. Ghostty's renderer polls the same state, since
    /// libghostty reports no change.
    func apply(_ state: TermiodStreamTerminal.Scrollbar, cellHeight: CGFloat, replaced: Bool) {
        let flash = pendingFlash && !replaced
        pendingFlash = false
        guard state != self.state || cellHeight != self.cellHeight || replaced else { return }
        self.state = state
        self.cellHeight = cellHeight
        lastSentRow = state.offset
        hasVerticalScroller = state.total > state.length
        layoutDocument(state)
        if flash { flashScrollers() }
    }

    private static func above(_ state: TermiodStreamTerminal.Scrollbar) -> UInt64 {
        state.total > state.length ? state.total - state.length : 0
    }

    private static func belowView(_ state: TermiodStreamTerminal.Scrollbar) -> UInt64 {
        let travel = above(state)
        return travel > state.offset ? travel - state.offset : 0
    }

    private func layoutDocument(_ state: TermiodStreamTerminal.Scrollbar) {
        guard cellHeight > 0 else { return }
        applying = true
        defer { applying = false }
        // The travel is exactly the rows above and below the view, so every
        // knob position is a row, even when the pane clips the grid.
        let travel = CGFloat(Self.above(state)) * cellHeight
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + travel)
        guard !liveScrolling else { return }
        contentView.scroll(to: NSPoint(x: 0, y: CGFloat(Self.belowView(state)) * cellHeight))
        reflectScrolledClipView(contentView)
    }

    @objc private func clipBoundsChanged() {
        guard !applying, let state, cellHeight > 0 else { return }
        let below = contentView.bounds.minY / cellHeight
        let top = Double(Self.above(state)) - Double(below)
        let row = UInt64(max(0, top.rounded()))
        guard row != lastSentRow else { return }
        lastSentRow = row
        onScrollToRow(row)
    }
}

import SwiftUI
import TermioStream

/// Mounts a `TermiodStreamView` for a pane whose link is on the `vt_stream`
/// plane, in place of the embedded surface. Mounted only while the pane is on
/// screen: the terminal lives in the link, so a hidden pane holds no view,
/// layer or drawables, and showing it again draws the link's current screen.
struct TermiodStreamPane: NSViewRepresentable {
    let link: TermiodSessionLink
    let sessionID: Session.ID
    let appearance: TermiodStreamRenderer.Appearance
    /// The session is selected and nothing else holds the keyboard: no open
    /// detail, no palette.
    let takesKeyboard: Bool
    let copyOnSelect: Bool
    let onViewport: (TerminalGrid) -> Void
    let onFocused: () -> Void
    let onBackgroundColor: (NSColor) -> Void

    func makeNSView(context: Context) -> TermiodStreamView {
        let view = TermiodStreamView(appearance: appearance)
        // A pane that cannot draw this plane hands the session back to the
        // embedded surface rather than stay blank.
        if !view.hasRenderer { link.abandonStream() }
        return view
    }

    func updateNSView(_ view: TermiodStreamView, context: Context) {
        let link = link
        view.terminal = { link.streamTerminal }
        view.send = { link.send($0) }
        view.sendInput = { link.sendInput($0) }
        view.copyOnSelect = copyOnSelect
        view.sessionID = sessionID
        view.onViewport = onViewport
        let onBackgroundColor = onBackgroundColor
        view.onBackgroundColor = { onBackgroundColor($0) }
        let onFocused = onFocused
        view.onFocusChange = { focused in if focused { onFocused() } }
        view.setAppearance(appearance)
        // This runs on every store change. Taking the keyboard each time would
        // pull it out of a field the user is typing in, such as a sidebar
        // rename, so it is taken on the way in, or when nothing holds it — the
        // embedded surface's orphan repair, after that field went away. A view
        // not yet in a window takes it in `viewDidMoveToWindow`.
        let gained = takesKeyboard && !view.claimsFocus
        view.claimsFocus = takesKeyboard
        if takesKeyboard, let window = view.window, window.firstResponder !== view,
           gained || window.firstResponder == nil || window.firstResponder === window {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.claimsFocus, view.window === window else { return }
                window.makeFirstResponder(view)
            }
        }
    }
}
