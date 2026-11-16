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
    /// A surface that stands up off the panel: the icon tiles in both sidebars.
    /// Lighter than the background in a dark theme and in a light one, so a tile
    /// reads as raised on either.
    let raisedBackground: Color
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
        // Every surface is a step in Oklab lightness, not a mix with white or
        // black in sRGB. The sRGB mix was measured across the built-in themes: a
        // dark panel landed anywhere from 0.030 to 0.170 lighter than its
        // terminal, so Vesper's sidebar stood far off its background and Nord's
        // barely left it. A fixed lightness step is the same seam on every theme.
        //
        // Large surfaces also give up a quarter of the background's colour. A
        // theme's background is tuned for a pane of text; spread over a whole
        // sidebar, a warm or saturated one (Coffee Theme, Ocean) shouts.
        let panel = Self.surface(background, lightness: dark ? 0.035 : -0.035, chroma: 0.75)
        self.panelBackground = panel
        // Lighter than the panel in a dark theme and in a light one, so a tile
        // reads as raised on either: 0.05 above a dark panel, and up to 0.06
        // above a light background, less where that is already near white.
        self.raisedBackground = Self.surface(
            background,
            lightness: dark ? 0.085 : min(0.06, (1 - Self.lightness(background)) * 0.6),
            chroma: 0.6)
        // A solid ink at a set contrast, not the foreground at an alpha. At
        // 0.6 and 0.75 alpha the muted text measured from 2.36 to 9.9 against
        // the panel, and 28 of the 69 built-in themes fell under 4.5. Walking
        // the foreground toward the panel until 4.5 gives every theme the same
        // step between its two text levels. A theme whose own foreground cannot
        // reach 4.5 on the panel keeps the foreground.
        self.secondaryForeground = Self.ink(from: foreground, toward: panel, contrast: 4.5)
        // The active row reads as accent-tinted (VSCode's active list item) and the
        // same color inks document links, so a theme whose ANSI blue is deep enough to
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

    /// `color` moved by `lightness` in Oklab, keeping `chroma` of its colourfulness.
    static func surface(_ color: Color, lightness delta: CGFloat, chroma: CGFloat) -> Color {
        guard let lab = Oklab(NSColor(color)) else { return color }
        return Color(nsColor: Oklab(
            lightness: max(0, min(1, lab.lightness + delta)),
            a: lab.a * chroma,
            b: lab.b * chroma
        ).color)
    }

    private static func lightness(_ color: Color) -> CGFloat {
        Oklab(NSColor(color))?.lightness ?? 0.5
    }

    /// The dimmest colour between `ink` and `ground`, mixed in Oklab, that still
    /// holds `contrast` against `ground`.
    static func ink(from ink: Color, toward ground: Color, contrast: Double) -> Color {
        guard let from = Oklab(NSColor(ink)), let to = Oklab(NSColor(ground)) else { return ink }
        var best = ink
        for step in 1...100 {
            let t = CGFloat(step) / 100
            let candidate = Color(nsColor: Oklab(
                lightness: from.lightness + (to.lightness - from.lightness) * t,
                a: from.a + (to.a - from.a) * t,
                b: from.b + (to.b - from.b) * t
            ).color)
            guard contrastRatio(candidate, ground) >= contrast else { break }
            best = candidate
        }
        return best
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

/// The colors termio injects into the HTML pages it renders in a web view — the
/// Markdown reader, the preview it renders for the phone, and the Issues pane — so
/// those pages match the app. Resolved from the chosen chrome theme, or termio's
/// built-in light/dark defaults when no Ghostty theme is selected (mirrors
/// `ChromeTheme.terminalBackgroundColor`'s fallbacks).
struct DocumentTheme: Equatable {
    let background: String
    let panel: String
    let foreground: String
    let secondary: String
    let accent: String
    let isDark: Bool

    @MainActor
    static func resolve(settings: AppSettings, colorScheme: ColorScheme) -> DocumentTheme {
        if let chrome = settings.chromeTheme(for: colorScheme) { return from(chrome) }
        return builtin(dark: colorScheme == .dark)
    }

    /// `resolve` for the Markdown reader: the same chrome-theme path, but the no-theme
    /// fallback is the reader palette rather than `builtin`.
    @MainActor
    static func resolveReader(settings: AppSettings, colorScheme: ColorScheme) -> DocumentTheme {
        if let chrome = settings.chromeTheme(for: colorScheme) { return from(chrome) }
        return reader(dark: colorScheme == .dark)
    }

    private static func from(_ chrome: ChromeTheme) -> DocumentTheme {
        DocumentTheme(
            background: hex(chrome.background),
            panel: hex(chrome.panelBackground),
            foreground: hex(chrome.foreground),
            secondary: hex(chrome.secondaryForeground),
            accent: hex(chrome.accent),
            isDark: chrome.isDark
        )
    }

    /// termio's built-in light/dark defaults with no `AppSettings` dependency —
    /// used to render a page for the phone, which sends only its light/dark trait
    /// (not the Mac's chrome theme) over the companion wire. Tune the Markdown
    /// reader in `reader(dark:)` instead.
    static func builtin(dark: Bool) -> DocumentTheme {
        dark
            ? DocumentTheme(background: "#212121", panel: "#2a2a2c", foreground: "#e6e6e8",
                            secondary: "#8a8a90", accent: "#7d8cff", isDark: true)
            : DocumentTheme(background: "#ffffff", panel: "#f2f2f4", foreground: "#1d1d1f",
                            secondary: "#6e6e73", accent: "#2f6fed", isDark: false)
    }

    /// The Markdown reader's fallback palette, deliberately decoupled from `builtin`.
    /// Backgrounds mirror `terminalBackgroundColor`'s fallbacks (pure white in light,
    /// Afterglow #212121 in dark) so the reading view matches the terminal it overlays
    /// and the editor you flip from — seamless, not a differently-tinted page. The
    /// accents are muted, print-like tints tuned for reading; warmth and beauty come
    /// from typography, not a coloured canvas.
    static func reader(dark: Bool) -> DocumentTheme {
        dark
            ? DocumentTheme(background: "#212121", panel: "#2a2a2c", foreground: "#e6e6e8",
                            secondary: "#8a8a90", accent: "#6f9bd8", isDark: true)
            : DocumentTheme(background: "#ffffff", panel: "#f7f6f3", foreground: "#1d1d1f",
                            secondary: "#6e6e73", accent: "#205ea6", isDark: false)
    }

    private static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
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

    /// Base ink for code the syntax highlighter has not colored — the file editor's plain text,
    /// and every buffer that never gets a highlight pass at all (no grammar for the extension,
    /// or past the size limit). The theme's own foreground, so the text sits in the palette the
    /// rest of the chrome is drawn from, falling back to `overlayInk` at full strength when no
    /// theme is picked.
    ///
    /// This has to be stated rather than left to AppKit: an `NSTextView` whose text carries no
    /// color draws its built-in black whatever the appearance is, and the editor paints an opaque
    /// terminal background — black on Afterglow `#212121` reads as an empty file (#662).
    func editorInk(for colorScheme: ColorScheme) -> NSColor {
        let theme = chromeTheme(for: colorScheme)
        if let foreground = theme?.foreground { return NSColor(foreground) }
        return ChromeTheme.overlayInk(
            onDark: theme?.isDark ?? (colorScheme == .dark), alpha: 1
        )
    }

    /// The window's ground — the sidebar, the gaps between the cards, the window's edges — as a
    /// dynamic color: the theme's `panelBackground`, a step off its terminal background, so the
    /// cards read as surfaces on it. Without a theme, the same step off the default background.
    var panelBackgroundColor: NSColor {
        let lightPanel = chromeTheme(for: .light)?.panelBackground
        let darkPanel = chromeTheme(for: .dark)?.panelBackground
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark {
                return darkPanel.map(NSColor.init)
                    ?? NSColor(srgbRed: 0x2c / 255.0, green: 0x2c / 255.0, blue: 0x2c / 255.0, alpha: 1)
            }
            return lightPanel.map(NSColor.init)
                ?? NSColor(srgbRed: 0xf5 / 255.0, green: 0xf5 / 255.0, blue: 0xf5 / 255.0, alpha: 1)
        }
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

/// Björn Ottosson's Oklab, enough of it to interpolate two opaque colors. The
/// chrome theme's surfaces mix in it.
struct Oklab {
    let lightness: CGFloat
    let a: CGFloat
    let b: CGFloat

    init(lightness: CGFloat, a: CGFloat, b: CGFloat) {
        self.lightness = lightness
        self.a = a
        self.b = b
    }

    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Self.linear(srgb.redComponent)
        let g = Self.linear(srgb.greenComponent)
        let b = Self.linear(srgb.blueComponent)

        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    var color: NSColor {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)

        let r = Self.encode(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
        let g = Self.encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
        let blue = Self.encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        return NSColor(srgbRed: r, green: g, blue: blue, alpha: 1)
    }

    private static func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    /// Out-of-gamut mixes are clamped rather than gamut-mapped: the inputs here are a
    /// theme color and a short step away from it, which never strays far.
    private static func encode(_ component: CGFloat) -> CGFloat {
        let clamped = min(max(component, 0), 1)
        let encoded = clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return min(max(encoded, 0), 1)
    }
}
