import XCTest
@testable import termio

/// The stall detector's verdict logic (design doc §4.7), pinned as a pure state
/// machine: the edge trigger must fire exactly once per quiet window, every
/// progress marker must slide the window and re-arm it, and the output-rate
/// suppressor must read sustained streams — not spinner dribble — as progress.
final class StallProbeTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func measurement(
        fingerprint: String = "abc#1", lines: Int = 100, size: Int64 = 1000
    ) -> StallMeasurement {
        StallMeasurement(
            repoFingerprint: fingerprint, transcriptPath: "/tmp/t.jsonl",
            transcriptLines: lines, transcriptSize: size)
    }

    private func probeWithBaseline() -> StallProbe {
        var probe = StallProbe(workingSince: start, windowStart: start)
        probe.baseline = StallProbe.Baseline(directory: "/repo", measured: measurement())
        return probe
    }

    func testUnchangedEvidenceAlertsOnceThenHolds() {
        var probe = probeWithBaseline()
        let later = start.addingTimeInterval(1200)
        XCTAssertEqual(
            probe.assess(measurement(lines: 103), at: later, transcriptLineFloor: 5),
            .stalled(transcriptLinesGrown: 3))
        XCTAssertTrue(probe.alerted)
        // The next quiet probe holds — edge-triggered, never spam.
        XCTAssertEqual(
            probe.assess(measurement(lines: 104), at: later.addingTimeInterval(30),
                         transcriptLineFloor: 5),
            .hold)
    }

    func testRepoChangeIsProgressAndReArms() {
        var probe = probeWithBaseline()
        let later = start.addingTimeInterval(1200)
        XCTAssertEqual(
            probe.assess(measurement(), at: later, transcriptLineFloor: 5),
            .stalled(transcriptLinesGrown: 0))
        // A commit moves the fingerprint: the window slides, the latch re-arms.
        let afterCommit = later.addingTimeInterval(60)
        XCTAssertEqual(
            probe.assess(measurement(fingerprint: "def#2"), at: afterCommit,
                         transcriptLineFloor: 5),
            .progress)
        XCTAssertFalse(probe.alerted)
        XCTAssertEqual(probe.windowStart, afterCommit)
        XCTAssertEqual(probe.baseline?.repoFingerprint, "def#2")
        // A later quiet stretch may alert again — one event per window, not per turn.
        XCTAssertEqual(
            probe.assess(measurement(fingerprint: "def#2"),
                         at: afterCommit.addingTimeInterval(1200), transcriptLineFloor: 5),
            .stalled(transcriptLinesGrown: 0))
    }

    func testTranscriptBurstIsProgress() {
        var probe = probeWithBaseline()
        let later = start.addingTimeInterval(1200)
        XCTAssertEqual(
            probe.assess(measurement(lines: 100 + 5, size: 2000), at: later,
                         transcriptLineFloor: 5),
            .progress)
        XCTAssertEqual(probe.baseline?.transcriptLines, 105)
    }

    func testStreamSuppressorReadsSustainedVolumeOnly() {
        var probe = StallProbe(workingSince: start, windowStart: start)
        let later = start.addingTimeInterval(1000)
        // A spinner's frame repaints average ~2 KB/s — under the rate threshold.
        probe.streamedBytes = 2048 * 1000
        XCTAssertFalse(probe.isStreamSuppressed(at: later, bytesPerSecond: 4096))
        // A build scrolling logs through the TUI is an order of magnitude louder.
        probe.streamedBytes = 20_000 * 1000
        XCTAssertTrue(probe.isStreamSuppressed(at: later, bytesPerSecond: 4096))
    }

    func testSlideWindowWithoutBaselineForcesRecapture() {
        var probe = probeWithBaseline()
        probe.alerted = true
        probe.streamedBytes = 300_000
        let now = start.addingTimeInterval(1200)
        probe.slideWindow(to: now, baseline: nil)
        XCTAssertNil(probe.baseline)
        XCTAssertFalse(probe.alerted)
        XCTAssertEqual(probe.streamedBytes, 0)
        XCTAssertEqual(probe.windowStart, now)
        // With no baseline the assessment cannot judge — it holds until recapture.
        XCTAssertEqual(
            probe.assess(measurement(), at: now.addingTimeInterval(1200),
                         transcriptLineFloor: 5),
            .hold)
    }
}
