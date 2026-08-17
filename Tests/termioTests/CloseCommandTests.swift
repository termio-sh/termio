import XCTest
@testable import termio

/// ⌘W must never reach past what's in front of it, and must never end a process.
/// Both properties live in one decision (`CloseCommand.action`), and both regress
/// silently — the window still closes, just the wrong one — so they are pinned
/// here. See `docs/design/keyboard-command-design.md`.
final class CloseCommandTests: XCTestCase {
    // ⌘W passes the live split state; ⌘⇧W always passes false.
    private func commandW(_ frontmost: CloseCommand.Frontmost, split: Bool) -> CloseCommand.Action {
        CloseCommand.action(for: frontmost, ungroupingSplit: split)
    }

    private func commandShiftW(_ frontmost: CloseCommand.Frontmost) -> CloseCommand.Action {
        CloseCommand.action(for: frontmost, ungroupingSplit: false)
    }

    func testCommandWPeelsAPaneOffASplitBeforeTouchingTheWindow() {
        XCTAssertEqual(commandW(.mainWindow, split: true), .ungroupPane)
    }

    func testCommandWClosesTheWindowOnlyWhenNoSplitIsLeft() {
        XCTAssertEqual(commandW(.mainWindow, split: false), .closeMainWindow)
    }

    /// The #242 regression guard: with Settings in front, ⌘W must close Settings
    /// rather than reach through to the terminal's layout or window.
    func testCommandWClosesAnAuxiliaryWindowInsteadOfTheTerminalBehindIt() {
        XCTAssertEqual(commandW(.auxiliaryWindow(closable: true), split: true), .closeKeyWindow)
        XCTAssertEqual(commandW(.auxiliaryWindow(closable: true), split: false), .closeKeyWindow)
    }

    /// The palette panel is borderless, so `performClose` would only beep at the
    /// user; it dismisses through the store flag that owns its presentation.
    func testCommandWDismissesThePaletteRatherThanBeepingAtIt() {
        XCTAssertEqual(commandW(.palette, split: true), .dismissPalette)
        XCTAssertEqual(commandShiftW(.palette), .dismissPalette)
    }

    func testAnUnclosableWindowSwallowsTheKeyInsteadOfBeeping() {
        XCTAssertEqual(commandW(.auxiliaryWindow(closable: false), split: false), .nothing)
    }

    /// The app outlives its window (#242). With nothing on screen there is nothing
    /// to close, and ungrouping would mutate a layout the user cannot see.
    func testCloseKeysDoNothingWhenNoWindowIsOnScreen() {
        XCTAssertEqual(commandW(.nothing, split: true), .nothing)
        XCTAssertEqual(commandW(.nothing, split: false), .nothing)
        XCTAssertEqual(commandShiftW(.nothing), .nothing)
    }

    /// ⌘⇧W is "close the window" whatever the layout — it never peels off a pane.
    func testCommandShiftWIgnoresSplitsEntirely() {
        XCTAssertEqual(commandShiftW(.mainWindow), .closeMainWindow)
    }

    /// The whole decision as a table, so any change to it has to be made on
    /// purpose. Only `.mainWindow` may read the split state; every other row is
    /// the same under both keys.
    func testEveryCombinationResolvesAsDocumented() {
        let expected: [(CloseCommand.Frontmost, Bool, CloseCommand.Action)] = [
            (.nothing, true, .nothing),
            (.nothing, false, .nothing),
            (.palette, true, .dismissPalette),
            (.palette, false, .dismissPalette),
            (.auxiliaryWindow(closable: true), true, .closeKeyWindow),
            (.auxiliaryWindow(closable: true), false, .closeKeyWindow),
            (.auxiliaryWindow(closable: false), true, .nothing),
            (.auxiliaryWindow(closable: false), false, .nothing),
            (.mainWindow, true, .ungroupPane),
            (.mainWindow, false, .closeMainWindow),
        ]
        for (frontmost, split, action) in expected {
            XCTAssertEqual(
                CloseCommand.action(for: frontmost, ungroupingSplit: split), action,
                "\(frontmost) ungroupingSplit=\(split)")
        }
    }
}
