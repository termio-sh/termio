import AppKit

/// The diff's add/delete tints, mixed into the pane's actual background rather than
/// composited over it with an alpha. An alpha wash drifts in hue and strength with
/// whatever terminal background is configured — firm on one theme, invisible on the next,
/// and rarely equal between the add and delete sides. A fixed fraction mixed in Oklab
/// holds both sides at the same apparent strength on any background.
struct DiffPalette {
    /// Full-row washes, painted by the layout manager behind the text.
    let additionWash: NSColor
    let deletionWash: NSColor
    /// The deeper tint marking the changed span inside a modified line. Opaque, and
    /// mixed from the wash rather than layered over it, so the span's strength does not
    /// depend on how TextKit happens to composite two translucent passes.
    let additionEmphasis: NSColor
    let deletionEmphasis: NSColor
    /// The gutter's share of a changed row, mixed a step stronger than the row's wash.
    /// github.com does the same: the number cell reads as the row's anchor rather than as
    /// the same flat tint running edge to edge, and the digits stay in neutral ink.
    let additionGutter: NSColor
    let deletionGutter: NSColor
    /// A collapsed band's row fill, and the filled gutter cell that acts as its button.
    /// Neutral rather than github.com's blue — an accent-colored block would be the one
    /// loud thing in the pane.
    let bandFill: NSColor
    let bandControlFill: NSColor

    /// Bases are picked per appearance rather than lightened from one color: a green that
    /// reads as green on white is muddy on black, and a red that reads on black glares on
    /// white. `NSColor.systemGreen`/`.systemRed` are tuned for controls on a system
    /// background, not for a wash on an arbitrary terminal background.
    private static let additionLight = NSColor(srgbRed: 0.051, green: 0.745, blue: 0.306, alpha: 1)
    private static let additionDark = NSColor(srgbRed: 0.369, green: 0.800, blue: 0.443, alpha: 1)
    private static let deletionLight = NSColor(srgbRed: 1.000, green: 0.180, blue: 0.247, alpha: 1)
    private static let deletionDark = NSColor(srgbRed: 1.000, green: 0.404, blue: 0.384, alpha: 1)

    init(background: NSColor, isDark: Bool) {
        let addition = isDark ? Self.additionDark : Self.additionLight
        let deletion = isDark ? Self.deletionDark : Self.deletionLight
        // A dark background swallows a tint that would be plenty on a light one, so the
        // wash carries more of the base color there.
        let washAmount: CGFloat = isDark ? 0.20 : 0.12
        let emphasisAmount: CGFloat = isDark ? 0.26 : 0.20
        let ink = isDark ? NSColor.white : NSColor.black

        additionWash = Self.mix(background, addition, washAmount)
        deletionWash = Self.mix(background, deletion, washAmount)
        additionEmphasis = Self.mix(additionWash, addition, emphasisAmount)
        deletionEmphasis = Self.mix(deletionWash, deletion, emphasisAmount)
        additionGutter = Self.mix(background, addition, washAmount * 1.6)
        deletionGutter = Self.mix(background, deletion, washAmount * 1.6)
        bandFill = Self.mix(background, ink, 0.05)
        bandControlFill = Self.mix(background, ink, 0.11)
    }

    /// The fill behind a row's text.
    func wash(for role: DiffDocument.Line.Role) -> NSColor? {
        switch role {
        case .code(.addition): return additionWash
        case .code(.deletion): return deletionWash
        case .band: return bandFill
        case .code: return nil
        }
    }

    /// The fill behind a row's gutter — a step stronger than its body, the way github.com
    /// anchors the number cell. A band's gutter only becomes the button cell when there is
    /// a button in it: an empty raised box on an inert band reads as a control that broke.
    func gutterFill(for role: DiffDocument.Line.Role) -> NSColor? {
        switch role {
        case .code(.addition): return additionGutter
        case .code(.deletion): return deletionGutter
        case .band(let controls): return controls.isEmpty ? bandFill : bandControlFill
        case .code: return nil
        }
    }

    /// `amount` of `tint` mixed into `base`, interpolated in Oklab. Colors that cannot be
    /// read as sRGB (a pattern or catalog color with no concrete components) fall back to
    /// the base — a missing tint is better than a crash.
    static func mix(_ base: NSColor, _ tint: NSColor, _ amount: CGFloat) -> NSColor {
        guard let from = Oklab(base), let to = Oklab(tint) else { return base }
        let t = min(max(amount, 0), 1)
        return Oklab(
            lightness: from.lightness + (to.lightness - from.lightness) * t,
            a: from.a + (to.a - from.a) * t,
            b: from.b + (to.b - from.b) * t
        ).color
    }
}

/// Björn Ottosson's Oklab, enough of it to interpolate two opaque colors. Kept here
/// rather than in a general color utility because the diff is its only client.
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
    /// background and a tint a fifth of the way toward it, which never strays far.
    private static func encode(_ component: CGFloat) -> CGFloat {
        let clamped = min(max(component, 0), 1)
        let encoded = clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return min(max(encoded, 0), 1)
    }
}
