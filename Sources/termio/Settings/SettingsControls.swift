import AppKit
import SwiftUI

/// The leading row icon, rendered as a bare glyph with no backing square. Section
/// and feature symbols stay neutral grey to keep the settings calm and scannable;
/// agent brand marks carry their vendor color so they read as real product logos.
struct IconBadge: View {
    let icon: AgentIcon

    init(_ icon: AgentIcon) { self.icon = icon }

    var body: some View {
        glyph
            .frame(width: 22, height: 22)
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        case .terminalGlyph:
            HugeIconView(icon: .terminal, size: 14, color: .secondary)
        case .huge(let icon):
            HugeIconView(icon: icon, size: 14, color: .secondary)
        case .vector(let logo):
            BrandLogoShape(logo: logo)
                .fill(logo.tint, style: FillStyle(eoFill: logo.usesEvenOddFill))
                .frame(width: 13, height: 13)
        case .image(let url):
            AgentImageView(url: url, size: 18)
        }
    }
}

/// A grouped-section header rendered as a badge plus title, replacing the default
/// uppercased gray caption so each card reads as a labeled group (Dia style).
struct SectionHeaderLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.bottom, 2)
    }
}

/// The standard settings-row label: an optional leading icon badge, a title, and
/// an optional wrapping caption underneath (the Xcode/System Settings two-line
/// idiom). Every explanatory row in the settings tabs uses this so titles, caption
/// styling, and icon spacing stay identical across tabs instead of being
/// hand-rolled per row. Primary rows read at `.headline`; pass `titleFont: .body`
/// for a nested sub-option that should sit visually below its parent row.
struct SettingsLabel: View {
    var icon: AgentIcon?
    let title: String
    var subtext: String?
    var titleFont: Font = .headline

    /// Icon-led row (a system symbol or agent brand mark).
    init(_ icon: AgentIcon, title: String, subtext: String? = nil, titleFont: Font = .headline) {
        self.icon = icon
        self.title = title
        self.subtext = subtext
        self.titleFont = titleFont
    }

    /// Icon-less row, for a nested sub-option that hangs under an icon-led row.
    init(title: String, subtext: String? = nil, titleFont: Font = .body) {
        self.icon = nil
        self.title = title
        self.subtext = subtext
        self.titleFont = titleFont
    }

    var body: some View {
        HStack(spacing: icon == nil ? 0 : 10) {
            if let icon {
                IconBadge(icon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(titleFont)
                if let subtext {
                    Text(subtext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The result of an install button, shown beside it as one caption line.
///
/// Installing writes outside the app — a PATH symlink, an agent's config file, a
/// user-level instruction file — and none of that shows up in the window, so a
/// click that worked and one that quietly failed look identical. A success fades
/// on its own once it has been read; a failure stays put, because it names
/// something the user has to deal with.
struct InstallFeedback: Equatable {
    enum Kind { case success, failure }
    let kind: Kind
    let message: String

    static func success(_ message: String) -> InstallFeedback {
        InstallFeedback(kind: .success, message: message)
    }

    static func failure(_ message: String) -> InstallFeedback {
        InstallFeedback(kind: .failure, message: message)
    }

    /// Turns an installer's per-target result into that one line. The targets are
    /// the point: "Reinstall hooks" writes into several agents' config files the
    /// settings pane never otherwise names, so naming them is what makes the
    /// confirmation worth reading. A partial install reports as a failure even
    /// though something landed — the part that didn't is the part to act on.
    static func summarizing(
        _ outcome: InstallOutcome, headline: String, unit: String
    ) -> InstallFeedback {
        let installed = InstallOutcome.list(outcome.succeeded, unit: unit)
        let missed = InstallOutcome.list(outcome.failed, unit: unit)
        if outcome.isEmpty { return .failure(localized("Nothing to install.")) }
        if outcome.failed.isEmpty { return .success(localized("\(headline) — \(installed).")) }
        if outcome.succeeded.isEmpty { return .failure(localized("Couldn’t update \(missed).")) }
        return .failure(localized("\(headline) — \(installed). Couldn’t update \(missed)."))
    }
}

/// The current message plus the click that produced it. The counter is what makes
/// a *repeat* click honest: keyed on the message alone, pressing the button again
/// inside the dismissal window would inherit the first click's timer and could
/// clear the line a moment later — the button reading as if it did nothing, which
/// is the exact problem this feedback exists to fix.
struct InstallFeedbackState: Equatable {
    private(set) var attempt = 0
    private(set) var feedback: InstallFeedback?

    mutating func show(_ feedback: InstallFeedback) {
        attempt += 1
        self.feedback = feedback
    }

    mutating func clear() {
        feedback = nil
    }
}

/// The message itself: a status glyph and one caption line, sized to sit under or
/// beside a settings control without competing with it.
struct InstallFeedbackLabel: View {
    let feedback: InstallFeedback

    var body: some View {
        HStack(spacing: 5) {
            HugeIconView(
                icon: feedback.kind == .success ? .checkCircle : .infoCircle,
                size: 12,
                color: feedback.kind == .success ? .green : .orange)
            Text(feedback.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A cross-fade rather than a slide: the reduced-motion-safe form, so this
        // needs no separate accessibility path.
        .transition(.opacity)
    }
}

extension View {
    /// Clears a success message a few seconds after it appears — long enough to
    /// read, short enough that a stale "Installed" never sits next to a button the
    /// user is about to press again. Failures stay.
    func autoDismissing(_ state: Binding<InstallFeedbackState>) -> some View {
        task(id: state.wrappedValue) {
            guard state.wrappedValue.feedback?.kind == .success else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { state.wrappedValue.clear() }
        }
    }
}

/// A settings action that writes outside the app, with its result shown next to
/// the button: the action performs the install and hands back the line to display.
struct InstallButtonRow: View {
    let title: String
    let action: () -> InstallFeedback

    @State private var state = InstallFeedbackState()

    var body: some View {
        HStack(spacing: 10) {
            Button(title) { withAnimation { state.show(action()) } }
            if let feedback = state.feedback {
                InstallFeedbackLabel(feedback: feedback)
            }
            Spacer(minLength: 0)
        }
        .autoDismissing($state)
    }
}

/// Centers a `LabeledContent` row's trailing control vertically against its label,
/// matching macOS 26 / System Settings rows. The default style anchors the control
/// to the label's first-text baseline, which sits visibly high once a label wraps to
/// two lines. Applied once on the settings root via `.labeledContentStyle(.settingsCentered)`.
struct SettingsCenteredLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

extension LabeledContentStyle where Self == SettingsCenteredLabeledContentStyle {
    static var settingsCentered: SettingsCenteredLabeledContentStyle {
        SettingsCenteredLabeledContentStyle()
    }
}

/// The font families installed on this Mac, used to populate the font pickers.
/// Enumerating the font manager is not free, so each list is computed once and
/// reused for the lifetime of the process.
enum InstalledFonts {
    /// Fixed-pitch families, for the terminal where a proportional font would
    /// break column alignment.
    static let monospaced: [String] = families(fixedPitchOnly: true)

    /// All families, for the app's own chrome where proportional fonts are fine.
    static let all: [String] = families(fixedPitchOnly: false)

    private static func families(fixedPitchOnly: Bool) -> [String] {
        // Drop the dot-prefixed hidden system faces; they are not meant to be
        // selected by name and only clutter the menu.
        let visible = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
        guard fixedPitchOnly else { return visible.sorted() }
        return visible.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }

    /// Dual-width CJK monospace faces users commonly install, in preference order —
    /// each draws hanzi at exactly two terminal cells, so falling back to one keeps
    /// weight and style consistent with the Latin face.
    private static let cjkFallbackCandidates = [
        "Sarasa Term SC", "Sarasa Mono SC", "Sarasa Fixed SC",
        "Maple Mono NF CN", "Maple Mono CN",
        "LXGW WenKai Mono",
        "Noto Sans Mono CJK SC",
    ]

    /// The first installed candidate, probed once per process — fonts installed mid-run are
    /// deliberately not tracked (a relaunch picks them up).
    @MainActor private static let installedCJKCandidate: String? =
        cjkFallbackCandidates.first { NSFont(name: $0, size: 12) != nil }

    /// Whether a family can draw hanzi, memoized per process: `coveredCharacterSet` allocates
    /// a full coverage bitmap on every call, and the caller sits on the re-style path that
    /// runs once per open surface on every settings change.
    @MainActor private static var hanCoverage: [String: Bool] = [:]

    /// The first installed CJK-capable face to append to the terminal's font chain, or
    /// `nil` when the chain already covers CJK (checked against U+4E00) or none of the known
    /// candidates is installed. Silent by design: no setting, just a better fallback than the
    /// system's proportional PingFang when the user has a purpose-built face on disk.
    @MainActor static func cjkMonospaceFallback(existingChain: [String]) -> String? {
        guard let han = Unicode.Scalar(0x4E00) else { return nil }
        for family in existingChain where !family.isEmpty {
            let covers: Bool
            if let cached = hanCoverage[family] {
                covers = cached
            } else {
                covers = NSFont(name: family, size: 12)
                    .map { ($0.coveredCharacterSet as CharacterSet).contains(han) } ?? false
                hanCoverage[family] = covers
            }
            if covers { return nil }
        }
        guard let candidate = installedCJKCandidate, !existingChain.contains(candidate) else {
            return nil
        }
        return candidate
    }
}

/// A font-family editor: a native pop-up menu of installed families above a live
/// preview, matching the other grouped-form rows (Style, Theme). An empty value
/// is the valid "system default" state. A trailing "Custom…" item reveals an
/// inline text field so any name libghostty accepts — including faces this list
/// does not enumerate — can still be entered; the preview flags a custom name the
/// system cannot resolve rather than letting it fail silently.
struct FontFamilyField: View {
    let title: String
    let prompt: String
    let families: [String]
    /// Size to render the preview at, mirroring the live setting so the preview
    /// reflects what the terminal or sidebar will actually show.
    let previewSize: CGFloat
    /// Whether the default (empty value) is the system *monospaced* font. Drives
    /// which face the preview falls back to so it matches the real default.
    let monospacedDefault: Bool
    @Binding var family: String

    /// Set when the user picks "Custom…" so the text field stays open even while
    /// its value is still empty (which on its own would read as the default).
    @State private var editingCustom = false
    @FocusState private var customFieldFocused: Bool

    private static let sample = "The quick brown fox 0Oo1Il|·{}[]() => != <= ->"

    /// A menu tag that cannot collide with a real font family name, used for the
    /// "Custom…" item.
    private static let customTag = "\u{1}termio.custom"

    /// True when the current value is a custom name (non-empty and not one of the
    /// installed families the pop-up lists).
    private var hasCustomValue: Bool {
        !family.isEmpty && !families.contains(family)
    }

    /// Whether the inline custom field should be shown.
    private var showingCustomField: Bool { editingCustom || hasCustomValue }

    /// Maps the pop-up selection to and from `family`, routing the "Custom…"
    /// sentinel through `editingCustom` rather than the stored value.
    private var selection: Binding<String> {
        Binding(
            get: { showingCustomField ? Self.customTag : family },
            set: { newValue in
                if newValue == Self.customTag {
                    editingCustom = true
                    customFieldFocused = true
                } else {
                    editingCustom = false
                    family = newValue
                }
            }
        )
    }

    /// Resolves the selected family to a concrete font for the preview. An empty
    /// value is the valid "use the default" state, not a failure; a non-empty
    /// name the system cannot resolve flags `isFallback` so the caption can tell
    /// the user it did not take.
    private var preview: (font: NSFont, isFallback: Bool) {
        let size = min(max(previewSize, 9), 22)
        let fallback = monospacedDefault
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size)
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (fallback, false) }
        if let font = NSFont(name: trimmed, size: size) {
            return (font, false)
        }
        return (fallback, true)
    }

    var body: some View {
        let preview = preview
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: selection) {
                Text(prompt).tag("")
                Divider()
                ForEach(families, id: \.self) { name in
                    Text(name).tag(name)
                }
                Divider()
                Text(localized("Custom…")).tag(Self.customTag)
            }
            if showingCustomField {
                TextField(localized("Font name"), text: $family, prompt: Text(localized("e.g. JetBrains Mono")))
                    .textFieldStyle(.roundedBorder)
                    .focused($customFieldFocused)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
            Text(Self.sample)
                .font(Font(preview.font))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(preview.isFallback ? .tertiary : .secondary)
            if preview.isFallback {
                Text(localized("“\(family)” isn’t installed — showing the system default."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
