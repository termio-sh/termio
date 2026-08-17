import AppKit
import SwiftUI
import GhosttyTheme

/// App-chrome colors borrowed from the selected terminal theme.
///
/// termio keeps a single source of color truth — the Ghostty theme the user picks
/// for the terminal. Rather than maintain a second palette for the sidebar and
/// window (which would drift from the terminal's), the chrome derives its colors
/// from that same theme. When no terminal theme is selected this type isn't built
/// at all and the chrome falls back to the system appearance.
struct ChromeTheme {
    /// The terminal background, so the chrome can sit flush with the terminal.
    let background: Color
    /// The sidebar fill: a subtle step off the terminal background so the seam
    /// between the columns reads without a hard divider.
    let panelBackground: Color
    /// Primary chrome text (session titles).
    let foreground: Color
    /// Muted chrome text (project labels, icons).
    let secondaryForeground: Color
    /// Selection/hover tint for sidebar rows.
    let accent: Color
    /// Whether the theme reads as dark, so the window can match its system
    /// appearance (traffic lights, scrollbars) to the theme.
    let isDark: Bool

    /// Ink guaranteed to contrast a background: dimmed white over dark, dimmed black over light.
    /// The lesson this encodes (learned in the editor gutter): contrast must come from the
    /// *background's* darkness — a grey or tinted theme foreground sinks into a black background
    /// at any alpha, so never derive overlay ink from the foreground palette.
    static func overlayInk(onDark dark: Bool, alpha: CGFloat) -> NSColor {
        (dark ? NSColor.white : .black).withAlphaComponent(alpha)
    }

    init?(_ definition: GhosttyThemeDefinition) {
        guard let background = Color(hex: definition.background),
              let foreground = Color(hex: definition.foreground)
        else { return nil }
        let dark = definition.isDark
        self.background = background
        self.foreground = foreground
        // Lift the sidebar a touch off the terminal background — lighter in a dark
        // theme, darker in a light one, like VSCode's activity bar.
        self.panelBackground = background.blended(
            with: dark ? .white : .black,
            amount: dark ? 0.06 : 0.04
        )
        // One alpha for both brightnesses is too thin over a light panel: at 0.6
        // Catppuccin Latte's project labels measure 2.69 against `panelBackground`
        // and Rose Pine Dawn's 2.62, under the 3.0 floor muted chrome text needs.
        // Dark themes already clear it, so only the light side is lifted.
        self.secondaryForeground = foreground.opacity(dark ? 0.6 : 0.75)
        // The active row reads as accent-tinted (VSCode's active list item) and the
        // same color inks trace links, so a theme whose ANSI blue is deep enough to
        // vanish on its own background (Melange Light 2.80, Cobalt2 2.64) must use
        // its bright blue instead: take whichever of palette 4 and 12 contrasts the
        // background more. Fall back through the quieter text-selection grey to the
        // foreground so it always resolves.
        let blues = [definition.palette[4], definition.palette[12]]
            .compactMap { $0 }
            .compactMap(Color.init(hex:))
        let accentCandidate = blues.max { Self.contrastRatio($0, background) < Self.contrastRatio($1, background) }
        self.accent = accentCandidate
            ?? definition.selectionBackground.flatMap(Color.init(hex:))
            ?? foreground
        self.isDark = dark
    }

    /// WCAG contrast ratio between two opaque colors (1…21). Colors that can't be
    /// resolved into sRGB components report the neutral 1.0 rather than trapping,
    /// which makes them lose every comparison instead of winning one by accident.
    static func contrastRatio(_ first: Color, _ second: Color) -> Double {
        guard let firstLuminance = relativeLuminance(first),
              let secondLuminance = relativeLuminance(second)
        else { return 1 }
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: Color) -> Double? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }
}

extension AppSettings {
    /// Chrome colors derived from the terminal theme that applies in `colorScheme`,
    /// or `nil` to keep the system appearance when that slot is left on the default.
    /// The light and dark slots are independent — the chrome tracks whichever theme
    /// libghostty is currently rendering. Recomputes when the theme names change
    /// because `AppSettings` republishes on every appearance edit.
    func chromeTheme(for colorScheme: ColorScheme) -> ChromeTheme? {
        let name = colorScheme == .dark ? darkThemeName : lightThemeName
        guard !name.isEmpty,
              let definition = ThemeLibrary.theme(named: name)
        else { return nil }
        return ChromeTheme(definition)
    }

    /// The terminal surface's background color, so the window chrome and the
    /// terminal pane can paint the exact fill the terminal renders. Returned as a
    /// dynamic color that resolves per appearance: each side uses its chosen theme's
    /// background, or the default when that slot is empty — pure white in light mode
    /// (crisper than libghostty's Alabaster #F7F7F7, which reads as an unstyled grey
    /// under termio's mostly-empty canvas) and Afterglow #212121 in dark. Both sides
    /// are resolved up front on the main actor so the dynamic closure captures only
    /// plain colors.
    /// The terminal font resolved to a concrete `NSFont`, shared by every code
    /// surface (file editor, diff view) so they all read in the same face. The
    /// resolution must go through `NSFont(name:)` with an explicit monospace
    /// fallback: name lookup fails for system faces like the default "SF Mono"
    /// (Apple doesn't expose it by name to third-party apps), and SwiftUI's
    /// `Font.custom` would paper over that by silently substituting Helvetica.
    /// The size is the terminal's own — no floor of its own, or a code surface would
    /// stop shrinking with the terminal it is supposed to match.
    func resolvedTerminalFont() -> NSFont {
        if !fontFamily.isEmpty, let font = NSFont(name: fontFamily, size: fontSize) {
            return font
        }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Extra leading (points) lifting `font`'s natural line height to the configured
    /// `codeLineHeight` multiple of its point size; zero when the font already provides it.
    func codeLineSpacing(for font: NSFont) -> CGFloat {
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        return max(0, (CGFloat(codeLineHeight) * font.pointSize - natural).rounded())
    }

    /// Muted line-number ink shared by every code surface's gutter (file editor, diff view),
    /// chosen against the theme *background's* darkness via `ChromeTheme.overlayInk` — an
    /// earlier foreground-derived version sank into black backgrounds whenever the theme's
    /// foreground was grey or tinted, at any alpha (user report ×2). Statically resolved per
    /// `colorScheme`; a dynamic system color is no substitute because it ignores the terminal
    /// theme entirely.
    func gutterInk(for colorScheme: ColorScheme) -> NSColor {
        let dark = chromeTheme(for: colorScheme)?.isDark ?? (colorScheme == .dark)
        return ChromeTheme.overlayInk(onDark: dark, alpha: dark ? 0.55 : 0.42)
    }

    /// The diff's add/delete tints, resolved against the same theme `gutterInk` reads so
    /// the washes and the numbers drawn on them can never disagree about which slot is
    /// showing. `terminalBackgroundColor` is dynamic and would resolve against whatever
    /// `NSAppearance.current` happened to be during the Oklab mix — the theme's own
    /// background is the already-resolved counterpart.
    func diffPalette(for colorScheme: ColorScheme) -> DiffPalette {
        let theme = chromeTheme(for: colorScheme)
        let dark = theme?.isDark ?? (colorScheme == .dark)
        let background = theme.map { NSColor($0.background) }
            ?? (dark
                ? NSColor(srgbRed: 0x21 / 255.0, green: 0x21 / 255.0, blue: 0x21 / 255.0, alpha: 1)
                : .white)
        return DiffPalette(background: background, isDark: dark)
    }

    var terminalBackgroundColor: NSColor {
        let lightBackground = chromeTheme(for: .light)?.background
        let darkBackground = chromeTheme(for: .dark)?.background
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark {
                return darkBackground.map(NSColor.init)
                    ?? NSColor(srgbRed: 0x21 / 255.0, green: 0x21 / 255.0, blue: 0x21 / 255.0, alpha: 1)
            }
            return lightBackground.map(NSColor.init) ?? NSColor.white
        }
    }
}

extension Color {
    /// Parses a six-digit RGB hex string (with or without a leading `#`) — the form
    /// `GhosttyThemeDefinition` stores its colors in. Used by the chrome theme and the
    /// theme picker's swatches.
    init?(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self = Color(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    /// A linear mix toward `other` in sRGB. `amount` is clamped to 0...1; on a color
    /// that can't be resolved into sRGB components the receiver is returned as-is
    /// rather than trapping.
    func blended(with other: Color, amount: Double) -> Color {
        guard let base = NSColor(self).usingColorSpace(.sRGB),
              let target = NSColor(other).usingColorSpace(.sRGB)
        else { return self }
        let t = max(0, min(1, amount))
        return Color(
            .sRGB,
            red: base.redComponent + (target.redComponent - base.redComponent) * t,
            green: base.greenComponent + (target.greenComponent - base.greenComponent) * t,
            blue: base.blueComponent + (target.blueComponent - base.blueComponent) * t
        )
    }
}
