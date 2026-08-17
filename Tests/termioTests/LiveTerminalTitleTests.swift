import TermioShared
import XCTest

/// Pins the live-title sanitizer both platforms display through: what counts as
/// the animated status mark agents prefix their `OSC 0/2` title with, and what
/// is the title itself.
final class LiveTerminalTitleTests: XCTestCase {
    func testSpinnerFramesCollapseToOneTitle() {
        let frames = ["✳ Refactoring", "✻ Refactoring", "· Refactoring", "⁝ Refactoring"]
        XCTAssertEqual(Set(frames.map(LiveTerminalTitle.sanitized)), ["Refactoring"])
    }

    func testStripsLeadingRunAndWhitespace() {
        XCTAssertEqual(
            LiveTerminalTitle.sanitized("  ✳ ·· Building the app  "), "Building the app")
    }

    /// Only the *leading* run goes: separators inside the title carry meaning
    /// (Pi reports `pi | 019fe98c | working`).
    func testKeepsInteriorPunctuation() {
        XCTAssertEqual(
            LiveTerminalTitle.sanitized("· pi | 019fe98c | working"), "pi | 019fe98c | working")
    }

    /// Callers treat empty as "nothing to show" rather than blanking a good title.
    func testMarkOnlyTitleSanitizesToEmpty() {
        XCTAssertEqual(LiveTerminalTitle.sanitized(" ✳ "), "")
    }

    func testPlainTitleIsUnchanged() {
        XCTAssertEqual(LiveTerminalTitle.sanitized("termio — zsh"), "termio — zsh")
    }
}
