import TermioShared
import XCTest
@testable import termio

/// The order a subscribe handshake's two answers may reach a watch in — and
/// that the watch survives the wrong one.
///
/// A channel arms the subscription handler *before* the subscribe request goes
/// out, precisely because the first batch can arrive ahead of the reply (see
/// `Termiod.subscribeResource`). So a batch can be delivered while the caller is
/// still inside that call, against a subscription it has not installed yet — and
/// `watchedRoot`, which the tree translates every batch path by, reads nil then.
/// On a checkout reached through a symlink that means every canonical path
/// matches no row the tree holds: the batch is dropped having already advanced
/// the cursor past itself, and nothing later repairs the tree.
///
/// Driven through the watch's `Subscribing` seam rather than a socket. A real
/// daemon writes its ack first and cannot be asked not to, and a stub socket
/// cannot be held reliably in this suite — `TERMIOD_SOCK` is process-wide, so
/// every other reach for the local daemon lands on it. The seam is the only way
/// to state the ordering as a fact rather than as a race that usually goes the
/// right way.
final class TermiodWatchOrderingTests: XCTestCase {
    /// The spelling the client asks with, and the one the host answers with —
    /// `/var` against `/private/var` is this platform's own version of it.
    private let asked = "fs:/var/checkout"
    private let canonical = "fs:/private/var/checkout"

    /// What the watch handed over, in order.
    fileprivate enum Seen: Equatable {
        case established(UInt64)
        case reset
        /// The batch, and what the watch could say it was watching at the moment
        /// it was handed over. `nil` is the defect: a batch nothing can translate.
        case batch(UInt64, watching: String?)
    }

    private func fsChanged(resource: String, seq: UInt64) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "ev": "fs_changed",
            "resource": resource,
            "seq": seq,
            "paths": ["/private/var/checkout"],
            "full_rescan": false,
            "git_meta": false,
        ])
    }

    /// The batch is delivered inside the subscribe call — the exact window the
    /// channel opens by arming the handler before it sends — and must reach the
    /// caller only after the subscription is installed and the baseline decided.
    func testABatchArrivingAheadOfTheAckIsHeldUntilTheSubscriptionIsInstalled() throws {
        let seen = SeenBox()
        let settled = expectation(description: "the watch handed over both")
        settled.assertForOverFulfill = false
        let batch = try fsChanged(resource: asked, seq: 9)

        var watch: Termiod.ResourceWatch?
        let watching = WatchedRootReader()
        watch = Termiod.ResourceWatch(
            route: .local,
            caps: ["files", Termiod.ResourceWatch.capability],
            resource: asked,
            subscribing: { _, _, onEvent, _ in
                // The host queued a batch behind its ack, and the reader thread
                // reached it before this call could return.
                onEvent(batch)
                return (
                    .unattached(resource: self.canonical), false, 7)
            }
        ) { update in
            switch update {
            case .established(let cursor):
                seen.append(.established(cursor))
            case .reset:
                seen.append(.reset)
            case .batch(let payload):
                seen.append(.batch(payload.seq, watching: watching.read()))
            }
            if seen.value.count == 2 { settled.fulfill() }
        }
        watching.source = { [weak watch] in watch?.watchedRoot }

        wait(for: [settled], timeout: 5)
        XCTAssertEqual(
            seen.value,
            [.established(7), .batch(9, watching: "/private/var/checkout")],
            """
            the baseline decision must land first, and the batch that raced it \
            must be handed over only once the subscription can say what it watches
            """)
        withExtendedLifetime(watch) {}
    }

    /// The batch that raced the ack, and a live one that lands while it is
    /// still being handed over, must both apply — in order.
    ///
    /// The release calls out to the pane, so it cannot happen under the watch's
    /// lock, and the channel's reader thread is free to deliver during it. If
    /// the live batch is let through first the cursor moves to *its* seq, and
    /// the older batch still waiting is then discarded as already-reflected —
    /// so a directory only that batch named goes stale with nothing to repair
    /// it. The reader being serial does not help: the drain runs on the watch's
    /// own queue, not the reader's.
    func testALiveBatchDuringTheDrainQueuesBehindTheOneStillWaiting() throws {
        let seen = SeenBox()
        let settled = expectation(description: "the watch handed over all three")
        settled.assertForOverFulfill = false
        let early = try fsChanged(resource: asked, seq: 8)
        let live = try fsChanged(resource: canonical, seq: 9)
        // Captured from the handshake so the test can deliver a batch *after*
        // the subscribe returns — which is where the reader thread would.
        let reader = EventReader()

        let watch = Termiod.ResourceWatch(
            route: .local,
            caps: ["files", Termiod.ResourceWatch.capability],
            resource: asked,
            subscribing: { _, _, onEvent, _ in
                reader.source = onEvent
                onEvent(early)
                return (.unattached(resource: self.canonical), false, 7)
            }
        ) { update in
            switch update {
            case .established(let cursor):
                seen.append(.established(cursor))
                // Raised after `settle` and before the queue has drained: the
                // exact window a batch may overtake one already waiting in.
                reader.deliver(live)
            case .reset:
                seen.append(.reset)
            case .batch(let payload):
                seen.append(.batch(payload.seq, watching: nil))
            }
            if seen.value.count == 3 { settled.fulfill() }
        }

        wait(for: [settled], timeout: 5)
        XCTAssertEqual(
            seen.value,
            [.established(7), .batch(8, watching: nil), .batch(9, watching: nil)],
            "the batch that was already waiting must be handed over first")
        withExtendedLifetime(watch) {}
    }

    /// A subscribe that fails takes its held batches with it: the retry
    /// re-subscribes from the cursor it had *before* the attempt, so a batch the
    /// caller never saw must not have moved it.
    func testAFailedSubscribeResumesFromTheCursorItStartedWith() throws {
        let resumed = SinceBox()
        let attempts = expectation(description: "the watch tried twice")
        attempts.expectedFulfillmentCount = 2
        attempts.assertForOverFulfill = false
        let batch = try fsChanged(resource: asked, seq: 9)

        let watch = Termiod.ResourceWatch(
            route: .local,
            caps: ["files", Termiod.ResourceWatch.capability],
            resource: asked,
            subscribing: { _, since, onEvent, _ in
                resumed.append(since)
                attempts.fulfill()
                // A batch lands, and then the handshake fails: the batch was
                // never handed to anybody, so nothing may have moved on.
                onEvent(batch)
                throw TermiodClientError.connectionClosed
            }
        ) { _ in }

        // Wide, because the retry ladder is wall-clock: what is being pinned is
        // which cursor the second attempt resumes from, not how soon it runs.
        wait(for: [attempts], timeout: 60)
        XCTAssertEqual(
            resumed.value, [nil, nil],
            "a batch nobody applied must not become the cursor a retry resumes from")
        withExtendedLifetime(watch) {}
    }
}

/// The watch raises its updates off an arbitrary queue, so what a test records
/// has to be reachable from one.
private final class SeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [TermiodWatchOrderingTests.Seen] = []

    var value: [TermiodWatchOrderingTests.Seen] { lock.withLock { seen } }

    func append(_ item: TermiodWatchOrderingTests.Seen) {
        lock.withLock { seen.append(item) }
    }
}

private final class SinceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64?] = []

    var value: [UInt64?] { lock.withLock { values } }

    func append(_ since: UInt64?) { lock.withLock { values.append(since) } }
}

/// Reads `watchedRoot` at the moment a batch is handed over. Held apart so the
/// watch can be captured weakly after it exists.
private final class WatchedRootReader: @unchecked Sendable {
    private let lock = NSLock()
    private var _source: (@Sendable () -> String?)?

    var source: (@Sendable () -> String?)? {
        get { lock.withLock { _source } }
        set { lock.withLock { _source = newValue } }
    }

    func read() -> String? { source?() }
}

/// Holds the event handler the watch armed, so a test can deliver a batch after
/// the subscribe has returned — where the channel's reader thread would.
private final class EventReader: @unchecked Sendable {
    private let lock = NSLock()
    private var _source: (@Sendable (Data) -> Void)?

    var source: (@Sendable (Data) -> Void)? {
        get { lock.withLock { _source } }
        set { lock.withLock { _source = newValue } }
    }

    func deliver(_ payload: Data) { source?(payload) }
}
