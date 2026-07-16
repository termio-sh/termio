import AppKit
import SwiftUI

/// The Keyboard settings pane: every rebindable command grouped by category, each
/// with a live recorder. Bindings resolve through `KeybindingStore` (catalog
/// default + user override), so a change here updates the main menu and the
/// command palette immediately. Only ⌘-based combos are accepted — anything
/// without Command could shadow a key an agent TUI or the shell needs.
struct KeybindingsSettingsTab: View {
    @ObservedObject private var keys = KeybindingStore.shared
    @State private var query = ""
    /// The command whose last recording was refused, plus why — shown inline.
    @State private var rejection: (id: KeyCommandID, message: String)?

    var body: some View {
        VStack(spacing: 0) {
            searchField
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
                    Text("No commands match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter commands", text: $query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func row(_ info: KeyCommandInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(info.title) {
                HStack(spacing: 6) {
                    KeyRecorderField(display: keys.display(for: info.id)) { captured in
                        handle(captured, for: info.id)
                    }
                    Button {
                        keys.reset(info.id)
                        clearRejection(for: info.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to default")
                    .disabled(!keys.isCustomized(info.id))
                    .opacity(keys.isCustomized(info.id) ? 1 : 0.25)
                }
            }
            if let rejection, rejection.id == info.id {
                Text(rejection.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Press ⌫ while recording to revert a row. Shortcuts must include ⌘.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Restore Defaults") {
                keys.resetAll()
                rejection = nil
            }
            .disabled(keys.overrides.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            rejection = (id, message)
            return
        }
        clearRejection(for: id)
        keys.setShortcut(shortcut, for: id)
    }

    private func clearRejection(for id: KeyCommandID) {
        if rejection?.id == id { rejection = nil }
    }
}

// MARK: - Recorder

/// A push button that records the next key chord. AppKit, not SwiftUI, because
/// only a live NSView can intercept ⌘-combos via `performKeyEquivalent` *before*
/// the main menu claims them — a SwiftUI key handler never sees ⌘D.
struct KeyRecorderField: NSViewRepresentable {
    /// Current shortcut glyphs (`⌥⌘←`), or nil when the command is unbound.
    let display: String?
    /// Captured chord, or nil when the user pressed ⌫ to clear.
    let onCapture: (Shortcut?) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onCapture = onCapture
        button.refresh(display: display)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onCapture = onCapture
        button.refresh(display: display)
    }
}

final class RecorderButton: NSButton {
    var onCapture: ((Shortcut?) -> Void)?
    private var currentDisplay: String?
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var acceptsFirstResponder: Bool { true }

    /// Fixed width so the column doesn't jump between "Add Shortcut" and a glyph.
    override var intrinsicContentSize: NSSize {
        NSSize(width: 128, height: super.intrinsicContentSize.height)
    }

    func refresh(display: String?) {
        currentDisplay = display
        updateTitle()
    }

    private func updateTitle() {
        if isRecording {
            title = "Type shortcut…"
            contentTintColor = .controlAccentColor
        } else {
            title = currentDisplay ?? "Add Shortcut"
            contentTintColor = currentDisplay == nil ? .tertiaryLabelColor : nil
        }
    }

    @objc private func toggle() {
        isRecording ? endRecording() : beginRecording()
    }

    private func beginRecording() {
        isRecording = true
        updateTitle()
        window?.makeFirstResponder(self)
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        updateTitle()
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    // Intercept ⌘-combos before the menu; only while actively recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        capture(event)
    }

    private func capture(_ event: NSEvent) {
        switch event.keyCode {
        case 53: endRecording(); return                        // esc cancels, no change
        case 51, 117: onCapture?(nil); endRecording(); return  // delete/fwd-delete clears
        default: break
        }
        guard let shortcut = Shortcut(event: event) else { return } // ignore lone modifiers
        onCapture?(shortcut)
        endRecording()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            updateTitle()
        }
        return super.resignFirstResponder()
    }
}
