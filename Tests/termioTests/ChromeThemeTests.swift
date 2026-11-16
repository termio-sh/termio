import AppKit
import SwiftUI
import XCTest
@testable import termio

/// The chrome colours are derived, not picked, so one test can hold every
/// built-in theme to the same rules.
@MainActor
final class ChromeThemeTests: XCTestCase {
    private func lightness(_ color: Color) -> CGFloat {
        Oklab(NSColor(color))?.lightness ?? -1
    }

    /// Oklab is a pile of magic constants: one transposed digit would shift every surface.
    func testOklabRoundTripsSRGB() throws {
        let samples: [NSColor] = [
            .init(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            .init(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            .init(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
            .init(srgbRed: 0.051, green: 0.745, blue: 0.306, alpha: 1),
            .init(srgbRed: 1, green: 0.18, blue: 0.247, alpha: 1),
            .init(srgbRed: 0.11, green: 0.13, blue: 0.18, alpha: 1),
        ]
        for sample in samples {
            let back = try XCTUnwrap(Oklab(sample)).color
            XCTAssertEqual(back.redComponent, sample.redComponent, accuracy: 0.002)
            XCTAssertEqual(back.greenComponent, sample.greenComponent, accuracy: 0.002)
            XCTAssertEqual(back.blueComponent, sample.blueComponent, accuracy: 0.002)
        }
    }

    func testPanelIsTheSameLightnessStepOnEveryTheme() throws {
        for definition in ThemeLibrary.builtInThemes {
            let chrome = try XCTUnwrap(ChromeTheme(definition), definition.name)
            let step = lightness(chrome.panelBackground) - lightness(chrome.background)
            // Giving up chroma moves lightness a little once the colour is back in sRGB.
            XCTAssertEqual(abs(step), 0.035, accuracy: 0.012, definition.name)
            XCTAssertEqual(step > 0, chrome.isDark, definition.name)
        }
    }

    func testRaisedSurfaceStandsAboveThePanel() throws {
        for definition in ThemeLibrary.builtInThemes {
            let chrome = try XCTUnwrap(ChromeTheme(definition), definition.name)
            XCTAssertGreaterThan(
                lightness(chrome.raisedBackground), lightness(chrome.panelBackground) + 0.02, definition.name)
        }
    }

    func testMutedTextHoldsItsContrastOnThePanel() throws {
        for definition in ThemeLibrary.builtInThemes {
            let chrome = try XCTUnwrap(ChromeTheme(definition), definition.name)
            let muted = ChromeTheme.contrastRatio(chrome.secondaryForeground, chrome.panelBackground)
            let full = ChromeTheme.contrastRatio(chrome.foreground, chrome.panelBackground)
            // A theme whose own foreground is under the target keeps the foreground.
            XCTAssertGreaterThanOrEqual(muted, min(4.5, full) - 0.01, definition.name)
            XCTAssertLessThanOrEqual(muted, max(4.8, full), definition.name)
        }
    }
}
