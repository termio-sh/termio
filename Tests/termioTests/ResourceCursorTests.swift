import XCTest
@testable import TermioShared

/// The rule that decides what a resumable subscription resumes *from*.
///
/// Two failures it exists to prevent, both silent and both shipped:
///
/// - Adopting the ack's `seq` before the replay it names arrives. A drop in
///   between then resumes past batches nobody applied — on `status:` a session
///   stuck reading `working` after its turn ended; on `git:` a baseline missing
///   the deltas that would have cleaned it.
/// - Applying a stale batch after newer truth, rolling the state backwards.
///
/// The `git:` and `status:` planes both run this; `fs:` follows the same rule
/// in place (`TermiodFiles.deliver`).
final class ResourceCursorTests: XCTestCase {
    /// The ack is not an input at all — that is the whole point. A cursor only
    /// learns from batches that actually applied.
    func testAFreshCursorResumesFromNothing() {
        let cursor = ResourceCursor()
        XCTAssertNil(cursor.resumeFrom)
    }

    func testContiguousBatchesWalkTheCursorForward() {
        var cursor = ResourceCursor()
        XCTAssertEqual(cursor.admit(seq: 1), .apply)
        XCTAssertEqual(cursor.admit(seq: 2), .apply)
        XCTAssertEqual(cursor.admit(seq: 3), .apply)
        XCTAssertEqual(cursor.resumeFrom, 3)
    }

    /// Scenario the phone hit: cursor at 8, ack says 10, the link drops before
    /// 9 and 10 arrive. The next subscribe must ask from 8, or they are gone.
    func testADropBeforeTheReplayResumesFromWhatWasApplied() {
        var cursor = ResourceCursor()
        cursor.adoptBaseline(8)
        cursor.beginAttempt()

        // The ack said 10. Nothing arrives. The cursor has not moved.
        XCTAssertEqual(cursor.resumeFrom, 8)

        // A fresh attempt, and now they land.
        cursor.beginAttempt()
        XCTAssertEqual(cursor.admit(seq: 9), .apply)
        XCTAssertEqual(cursor.admit(seq: 10), .apply)
        XCTAssertEqual(cursor.resumeFrom, 10)
    }

    /// Scenario (b): a live batch reaches the client ahead of the replay it was
    /// owed. The replayed ones are older than what is already applied and must
    /// not roll it back.
    func testAStaleBatchIsDroppedAfterNewerTruth() {
        var cursor = ResourceCursor()
        cursor.adoptBaseline(8)
        cursor.beginAttempt()

        XCTAssertEqual(cursor.admit(seq: 11), .applyAcrossHole)
        XCTAssertEqual(cursor.admit(seq: 9), .drop)
        XCTAssertEqual(cursor.admit(seq: 10), .drop)
        XCTAssertEqual(cursor.resumeFrom, 8, "the hole is still owed")
    }

    /// And the hole repairs itself: the next attempt replays from 8 in order,
    /// and nothing is stale any more because the ordering was restored.
    func testANewAttemptUnsticksTheBatchesSpanningAHole() {
        var cursor = ResourceCursor()
        cursor.adoptBaseline(8)
        cursor.beginAttempt()
        _ = cursor.admit(seq: 11)
        XCTAssertEqual(cursor.resumeFrom, 8)

        cursor.beginAttempt()
        XCTAssertEqual(cursor.admit(seq: 9), .apply)
        XCTAssertEqual(cursor.admit(seq: 10), .apply)
        XCTAssertEqual(cursor.admit(seq: 11), .apply)
        XCTAssertEqual(cursor.resumeFrom, 11, "the cursor caught up rather than deadlocking")
    }

    /// Without the per-attempt reset the two marks deadlock: 9 and 10 read as
    /// stale on every reconnect and the cursor never moves again. This is that
    /// claim stated as a test, because the symptom is a pane that quietly stops
    /// updating rather than anything that throws.
    func testTheAttemptResetIsWhatBreaksTheDeadlock() {
        var cursor = ResourceCursor()
        cursor.adoptBaseline(8)
        cursor.beginAttempt()
        _ = cursor.admit(seq: 11)

        // Same attempt, no reset: still stale, cursor still stuck.
        XCTAssertEqual(cursor.admit(seq: 9), .drop)
        XCTAssertEqual(cursor.resumeFrom, 8)
    }

    /// A duplicate of the batch just applied is dropped, not re-applied — for a
    /// delta plane that is the difference between a clean tree and a resurrected
    /// path.
    func testADuplicateIsDropped() {
        var cursor = ResourceCursor()
        XCTAssertEqual(cursor.admit(seq: 1), .apply)
        XCTAssertEqual(cursor.admit(seq: 1), .drop)
        XCTAssertEqual(cursor.resumeFrom, 1)
    }

    /// A complete baseline — `git:`'s synthesized full state on gap, or an
    /// `fs:` listing's own stamp — is adopted outright. There is nothing before
    /// it to be missing, and walking to it one batch at a time would mean
    /// re-snapshotting on every reconnect forever.
    func testABaselineIsAdoptedOutrightAndNeverGoesBackwards() {
        var cursor = ResourceCursor()
        cursor.adoptBaseline(40)
        XCTAssertEqual(cursor.resumeFrom, 40)
        XCTAssertEqual(cursor.admit(seq: 41), .apply)

        // An older baseline is not news.
        cursor.adoptBaseline(12)
        XCTAssertEqual(cursor.resumeFrom, 41)
    }

    func testResetForgetsEverything() {
        var cursor = ResourceCursor()
        cursor.adoptBaseline(9)
        cursor.reset()
        XCTAssertNil(cursor.resumeFrom)
        // …and the first batch after a reset starts the count again.
        XCTAssertEqual(cursor.admit(seq: 1), .apply)
        XCTAssertEqual(cursor.resumeFrom, 1)
    }
}
