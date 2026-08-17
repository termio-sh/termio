import XCTest
@testable import termio

/// The line a Settings install button shows after it runs. The rule that matters:
/// anything that didn't land has to be visible and has to stay visible, so a
/// half-installed set of hooks can never read as a clean success.
final class InstallFeedbackTests: XCTestCase {
    private func outcome(succeeded: [String] = [], failed: [String] = []) -> InstallOutcome {
        var outcome = InstallOutcome()
        for name in succeeded { outcome.record(name, installed: true) }
        for name in failed { outcome.record(name, installed: false) }
        return outcome
    }

    func testNamesEveryTargetItReached() {
        let feedback = InstallFeedback.summarizing(
            outcome(succeeded: ["Claude Code", "Codex", "Cursor"]),
            headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.kind, .success)
        XCTAssertEqual(feedback.message, "Hooks reinstalled — Claude Code, Codex and Cursor.")
    }

    /// Past three the names would wrap the row, so the line counts instead.
    func testCountsBeyondThreeTargets() {
        let feedback = InstallFeedback.summarizing(
            outcome(succeeded: ["A", "B", "C", "D"]),
            headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.message, "Hooks reinstalled — 4 agents.")
    }

    /// A partial install is a failure: it stays on screen, because the half that
    /// didn't land is the half the user has to deal with.
    func testPartialInstallReportsAsFailure() {
        let feedback = InstallFeedback.summarizing(
            outcome(succeeded: ["Claude Code"], failed: ["Codex"]),
            headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.kind, .failure)
        XCTAssertEqual(
            feedback.message, "Hooks reinstalled — Claude Code. Couldn’t update Codex.")
    }

    func testTotalFailureNamesOnlyWhatFailed() {
        let feedback = InstallFeedback.summarizing(
            outcome(failed: ["~/.claude/CLAUDE.md"]),
            headline: "Note reinstalled", unit: "files")
        XCTAssertEqual(feedback.kind, .failure)
        XCTAssertEqual(feedback.message, "Couldn’t update ~/.claude/CLAUDE.md.")
    }

    /// Nothing attempted is not a success — silence is what this feedback exists
    /// to eliminate.
    func testEmptyOutcomeIsNotASuccess() {
        let feedback = InstallFeedback.summarizing(
            outcome(), headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.kind, .failure)
        XCTAssertEqual(feedback.message, "Nothing to install.")
    }

    /// Re-running the same action must restart the dismissal timer, which is keyed
    /// on the state's identity — so two identical messages must not compare equal.
    func testRepeatedShowChangesIdentity() {
        var state = InstallFeedbackState()
        state.show(.success("Installed."))
        let first = state
        state.show(.success("Installed."))
        XCTAssertNotEqual(first, state)
    }
}
