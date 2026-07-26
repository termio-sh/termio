import AppKit
import SwiftUI

/// The Keyboard settings pane: every rebindable command grouped by category, each
/// with a live recorder. Bindings resolve through `KeybindingStore` (catalog
/// default + user override), so a change here updates the main menu and the
/// command palette immediately. Only ⌘-based combos are accepted — anything
/// without Command could shadow a key an agent TUI or the shell needs.
///
/// The pane is a single grouped `Form`, System Settings style: search lives in
/// the window toolbar, the reset-all affordance is the list's last section, and
/// a refused recording answers with a shake + transient popover instead of an
/// inline error row that would push the list around.
struct KeybindingsSettingsTab: View {
    @ObservedObject private var keys = KeybindingStore.shared
    @State private var query = ""
    /// The command whose last recording was refused, plus why. `shake` increments
    /// per refusal so a repeated attempt re-triggers the recorder's shake even
    /// while the popover is already up.
    @State private var rejection: Rejection?
    /// Monotonic shake token — never reset, so a row's recorder (which remembers
    /// the last token it consumed) shakes again on a fresh refusal even after
    /// the previous rejection was dismissed.
    @State private var shakeCounter = 0
    /// Auto-dismisses the rejection popover after a beat, cancelled and re-armed
    /// on each refusal.
    @State private var rejectionDismissTask: Task<Void, Never>?

    private struct Rejection {
        let id: KeyCommandID
        let message: String
        let shake: Int
    }

    var body: some View {
        Form {
            ForEach(matchingCategories, id: \.self) { category in
                Section {
                    ForEach(commands(in: category)) { info in
                        row(info)
                    }
                } header: {
                    SectionHeaderLabel(title: category)
                }
            }
            if matchingCategories.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                restoreSection
            }
        }
        .formStyle(.grouped)
        .searchable(text: $query, placement: .toolbar, prompt: "Search commands")
    }

    // MARK: - Pieces

    private func row(_ info: KeyCommandInfo) -> some View {
        LabeledContent(info.title) {
            KeyRecorderField(
                display: keys.display(for: info.id),
                isCustomized: keys.isCustomized(info.id),
                shake: rejection?.id == info.id ? (rejection?.shake ?? 0) : 0,
                onCapture: { handle($0, for: info.id) }
            )
            // A representable stretches to whatever width SwiftUI proposes, so
            // the uniform footprint must be pinned here — the field's intrinsic
            // size alone doesn't hold against a flexible row.
            .frame(width: 130)
            .popover(isPresented: rejectionShown(for: info.id), arrowEdge: .bottom) {
                Text(rejection?.message ?? "")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 280)
            }
        }
    }

    /// The reset-all row, in the list where System Settings keeps such actions —
    /// with the recording hints as its footer, replacing the old pinned bottom bar.
    private var restoreSection: some View {
        Section {
            Button("Restore Defaults") {
                keys.resetAll()
                clearRejection()
            }
            .disabled(keys.overrides.isEmpty)
        } footer: {
            Text("Shortcuts must include ⌘ so they can't shadow a key an agent or the shell needs. While recording, press ⌫ to remove a shortcut, or esc to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Data

    private var matchingCategories: [String] {
        KeyCommandCatalog.categories.filter { !commands(in: $0).isEmpty }
    }

    private func commands(in category: String) -> [KeyCommandInfo] {
        KeyCommandCatalog.all.filter { info in
            info.category == category && matches(info)
        }
    }

    private func matches(_ info: KeyCommandInfo) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return info.title.localizedCaseInsensitiveContains(trimmed)
    }

    // MARK: - Editing

    private func handle(_ shortcut: Shortcut?, for id: KeyCommandID) {
        guard let shortcut else {           // ⌫ while recording = revert to default
            keys.reset(id)
            clearRejection(for: id)
            return
        }
        if let message = keys.rejection(for: shortcut, assigning: id) {
            NSSound.beep()
            shakeCounter += 1
            rejection = Rejection(id: id, message: message, shake: shakeCounter)
            rejectionDismissTask?.cancel()
            rejectionDismissTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                rejection = nil
            }
            return
        }
        clearRejection(for: id)
        keys.setShortcut(shortcut, for: id)
    }

    /// Whether the rejection popover shows on this row; setting it false (the
    /// user clicking away) clears the rejection early.
    private func rejectionShown(for id: KeyCommandID) -> Binding<Bool> {
        Binding(
            get: { rejection?.id == id },
            set: { shown in
                if !shown, rejection?.id == id { clearRejection() }
            }
        )
    }

    private func clearRejection(for id: KeyCommandID? = nil) {
        guard id == nil || rejection?.id == id else { return }
        rejectionDismissTask?.cancel()
        rejection = nil
    }
}

// MARK: - Recorder

/// The recorder pattern borrowed from the de-facto standard implementation of
/// this control, sindresorhus/KeyboardShortcuts' `RecorderCocoa`: an
/// `NSSearchField` dressed as a plain rounded field — centered text, fixed
/// width, no magnifier, the built-in cancel (⨯) button as the "remove
/// customization" affordance — recording driven by focus plus a local event
/// monitor, the only way to see ⌘-combos before the main menu claims them.
/// Being a real system control, hover/press rendering is AppKit's own — no
/// hand-rolled tracking areas to go stale when the list scrolls.
struct KeyRecorderField: NSViewRepresentable {
    /// Current shortcut glyphs (`⌥⌘←`), or nil when the command is unbound.
    let display: String?
    /// Whether the shortcut is a user override — shows the ⨯ (reset) button.
    let isCustomized: Bool
    /// A monotonically increasing token; each new value shakes the field once
    /// (a refused recording). Zero means "no shake pending".
    let shake: Int
    /// Captured chord, or nil when the user cleared the customization.
    let onCapture: (Shortcut?) -> Void

    func makeNSView(context: Context) -> RecorderSearchField {
        let field = RecorderSearchField()
        field.onCapture = onCapture
        field.refresh(display: display, isCustomized: isCustomized)
        return field
    }

    func updateNSView(_ field: RecorderSearchField, context: Context) {
        field.onCapture = onCapture
        field.refresh(display: display, isCustomized: isCustomized)
        if shake > 0, shake != field.lastShake {
            field.lastShake = shake
            field.shake()
        }
    }
}

final class RecorderSearchField: NSSearchField, NSSearchFieldDelegate {
    var onCapture: ((Shortcut?) -> Void)?
    /// The last shake token consumed, so a SwiftUI re-render doesn't replay it.
    var lastShake = 0

    private var currentDisplay: String?
    private var currentCustomized = false
    private var isRecording = false
    private var eventMonitor: Any?
    private var cancelCell: NSButtonCell?
    private var windowObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        delegate = self
        alignment = .center
        wantsLayer = true
        placeholderString = "Record Shortcut"
        // The magnifier and the ⨯ hide via transparency, never by detaching the
        // cells: macOS 26's accessibility builds this cell's AX children by
        // inserting both button cells into an array without a nil check, so a
        // nil'd-out cell crashes the app the moment any AX client (VoiceOver, a
        // window manager, an input method) walks the focused field.
        if let cell = cell as? NSSearchFieldCell {
            cell.searchButtonCell?.isTransparent = true
            cell.searchButtonCell?.isEnabled = false
            cancelCell = cell.cancelButtonCell
        }
        // The ⨯ resets the row instead of merely emptying the text.
        cancelCell?.target = self
        cancelCell?.action = #selector(clearCustomization)
        setShowsCancel(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    /// The upstream control's fixed footprint, one width for every row.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = 130
        return size
    }

    func refresh(display: String?, isCustomized: Bool) {
        currentDisplay = display
        currentCustomized = isCustomized
        guard !isRecording else { return }
        stringValue = display ?? ""
        setShowsCancel(isCustomized)
    }

    /// One bounce left-right — the refused-recording signal, paired with the beep.
    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -5, 5, -4, 4, -2, 2, 0]
        animation.duration = 0.35
        layer?.add(animation, forKey: "shake")
    }

    // MARK: Recording lifecycle

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { beginRecording() }
        return accepted
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        // The current glyphs stay visible while recording (as upstream does) —
        // writing `stringValue` here would end the just-started editing session,
        // whose did-end notification tears the recording straight back down.
        placeholderString = "Press Shortcut…"
        // The field editor attaches just after focus lands; hide its caret then
        // (there is nothing to type — the monitor consumes every key).
        DispatchQueue.main.async { [weak self] in
            (self?.currentEditor() as? NSTextView)?.insertionPointColor = .clear
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.blur() }
        }
    }

    /// Every keystroke while recording routes through here — *before* the main
    /// menu, which is what lets an already-taken ⌘-combo be captured at all.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        switch event.keyCode {
        case 53:                       // esc — cancel, binding unchanged
            blur()
            return nil
        case 51, 117:                  // ⌫ / fwd-delete — remove the customization
            onCapture?(nil)
            blur()
            return nil
        case 48:                       // tab — stop recording, let focus move on
            blur()
            return event
        default: break
        }
        guard let shortcut = Shortcut(event: event) else { return nil } // lone modifiers wait
        onCapture?(shortcut)
        blur()
        return nil
    }

    @objc private func clearCustomization() {
        onCapture?(nil)
        blur()
    }

    private func blur() {
        endRecording()
        if window?.firstResponder === currentEditor() || window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        placeholderString = "Record Shortcut"
        stringValue = currentDisplay ?? ""
        setShowsCancel(currentCustomized)
    }

    /// Clicking away ends the recording (the window's field editor moves on).
    func controlTextDidEndEditing(_ notification: Notification) {
        endRecording()
    }

    /// A hidden ⨯ stays transparent *and* disabled — a transparent NSButtonCell
    /// still tracks clicks, which would make an invisible spot of the field
    /// silently reset the row.
    private func setShowsCancel(_ shows: Bool) {
        cancelCell?.isTransparent = !shows
        cancelCell?.isEnabled = shows
        needsDisplay = true
    }
}
