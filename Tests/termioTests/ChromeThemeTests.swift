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
