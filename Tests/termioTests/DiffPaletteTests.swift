import AppKit
import XCTest
@testable import termio

/// The diff's tints are mixed in Oklab, which is a pile of magic constants: a single
/// transposed digit would shift every wash in a way that looks plausible on one theme and
/// wrong on another. These pin the conversion's round trip and the mix's endpoints, then
/// check the property the whole approach exists for — that a wash stays a visible, similar
/// step away from the background whether the background is black, white, or something in
/// between.
final class DiffPaletteTests: XCTestCase {
    /// Perceptual distance between two colors — how far a wash sits from its background.
    private func distance(_ from: Oklab, _ to: Oklab) -> CGFloat {
        let dl = to.lightness - from.lightness
        let da = to.a - from.a
        let db = to.b - from.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    private func components(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return (-1, -1, -1) }
        return (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
    }

    private func assertClose(_ lhs: NSColor, _ rhs: NSColor, accuracy: CGFloat = 0.002,
                             file: StaticString = #filePath, line: UInt = #line) {
        let a = components(lhs), b = components(rhs)
        XCTAssertEqual(a.0, b.0, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.1, b.1, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.2, b.2, accuracy: accuracy, file: file, line: line)
    }

    func testOklabRoundTripsSRGB() {
        let samples: [NSColor] = [
            .init(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            .init(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            .init(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
            .init(srgbRed: 0.051, green: 0.745, blue: 0.306, alpha: 1),
            .init(srgbRed: 1, green: 0.18, blue: 0.247, alpha: 1),
            .init(srgbRed: 0.11, green: 0.13, blue: 0.18, alpha: 1),
        ]
        for sample in samples {
            guard let oklab = Oklab(sample) else { return XCTFail("no sRGB components") }
            assertClose(oklab.color, sample)
        }
    }

    func testMixEndpointsAreTheInputs() {
        let background = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        let tint = NSColor(srgbRed: 0.369, green: 0.8, blue: 0.443, alpha: 1)
        assertClose(DiffPalette.mix(background, tint, 0), background)
        assertClose(DiffPalette.mix(background, tint, 1), tint)
    }

    func testMixIsMonotonicInLightness() {
        let background = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let tint = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let steps = stride(from: CGFloat(0), through: 1, by: 0.1).map {
            Oklab(DiffPalette.mix(background, tint, $0))?.lightness ?? -1
        }
        for (lower, higher) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThan(lower, higher)
        }
    }

    /// The failure this replaced: one alpha over any background. On near-black, an sRGB
    /// alpha wash all but vanishes; the mix has to stay a real step away on both extremes.
    func testWashIsVisibleOnAnyBackground() {
        let backgrounds: [(NSColor, Bool)] = [
            (NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), true),
            (NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1), true),
            (NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), false),
            (NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1), false),
        ]
        for (background, isDark) in backgrounds {
            let palette = DiffPalette(background: background, isDark: isDark)
            guard let base = Oklab(background),
                  let addition = Oklab(palette.additionWash),
                  let deletion = Oklab(palette.deletionWash) else { return XCTFail("no components") }
            XCTAssertGreaterThan(distance(base, addition), 0.02, "addition wash vanished")
            XCTAssertGreaterThan(distance(base, deletion), 0.02, "deletion wash vanished")
            // Neither side may read as the louder one — that is what makes a diff
            // lopsided, and it is exactly what a fixed alpha stops guaranteeing.
            XCTAssertEqual(distance(base, addition), distance(base, deletion), accuracy: 0.035,
                           "add and delete washes are not the same strength")
        }
    }

    func testEmphasisIsStrongerThanTheWashItSitsOn() {
        let background = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1)
        let palette = DiffPalette(background: background, isDark: true)
        guard let base = Oklab(background),
              let wash = Oklab(palette.additionWash),
              let emphasis = Oklab(palette.additionEmphasis) else { return XCTFail("no components") }
        XCTAssertGreaterThan(abs(emphasis.lightness - base.lightness),
                             abs(wash.lightness - base.lightness))
    }
}
