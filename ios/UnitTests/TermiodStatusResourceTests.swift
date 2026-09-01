@testable import TermioMobile
import TermioShared
import XCTest

/// Agent status reaches this phone as a **resource** — `status:`, with a cursor
/// — and not as a broadcast, so a screen that locked through three turns
/// resumes where it left off instead of rescanning.
///
/// The other half is the one status decision a viewer owns. The device reports
/// that a turn ended; whether that reads as a calm "ready for you" depends on
/// whether this person was looking, and the Mac answers from its selection
/// while this answers from the open session. Getting it wrong shows `done` on
/// the Mac and `idle` on the phone for one session at one moment, which is the
/// disagreement `source` / `turn_ended` exist to prevent.
///
/// The frames below are the daemon's own JSON (`termiod/src/protocol.rs`), run
/// through the real decode.
final class TermiodStatusResourceTests: XCTestCase {
    private func makeBackend() -> TermiodBackend {
        guard let url = URL(string: "ws://127.0.0.1:9/ws") else {
            fatalError("a literal URL that does not parse")
        }
        return TermiodBackend(endpoint: DeviceEndpoint(kind: .termiod, url: url), sessionID: nil)
    }

    private func event(_ json: String) throws -> Termiod.IncomingEvent {
        try Termiod.decodeEvent(Data(json.utf8))
    }

    private func statusChanged(
        seq: UInt64, session: String, status: String,
        source: String = "screen", turnEnded: Bool = false
    ) -> String {
        let ended = turnEnded ? "true" : "false"
        return "{\"ev\":\"status_changed\",\"resource\":\"status:\",\"seq\":\(seq),"
            + "\"session\":\"\(session)\",\"status\":\"\(status)\","
            + "\"source\":\"\(source)\",\"turn_ended\":\(ended),\"blocking\":false}"
    }

    /// The handshake, which is what lets a roster be published at all: the
    /// backend refuses to publish before the device names itself, because a
    /// workspace id that churned between pushes would reshuffle every list on
    /// screen.
    private func handshake(_ backend: TermiodBackend) throws {
        let payload = Data(
            ("{\"op\":\"hello_ok\",\"host_id\":\"h_1\",\"host\":\"vps\","
                + "\"client_id\":\"c_1\",\"proto\":1,\"caps\":[\"events\",\"resources\"],"
                + "\"home\":\"/root\"}").utf8)
        guard case .helloOk(let hello) = try Termiod.decodeControl(payload) else {
            return XCTFail("a hello_ok decoded as something else")
        }
        backend.handshakeLanded(hello)
    }

    /// Give the backend a roster, through the reply that really carries one — a
    /// status delta for a session the roster has never named is dropped, so
    /// without this the assertions below would pass on an empty backend and
    /// prove nothing.
    /// Re-run the handshake, which is what opens a new subscribe attempt.
    private func handshakeAndSubscribe(_ backend: TermiodBackend) throws {
        try handshake(backend)
    }

    /// A backend in the state the status assertions assume: handshaken, its
    /// subscribe attempt settled, and a roster to revise. The ack matters —
    /// without one the ledger holds every batch, by design.
    private func seedRoster(_ backend: TermiodBackend, sessions: [String]) throws {
        try handshake(backend)
        try deliver(backend, ack: subscribed(seq: 0))
        let rows = sessions.map { id in
            "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"pid\":1,\"alive\":true,"
                + "\"cwd\":\"/srv/repo\",\"command\":\"claude\",\"status\":\"working\","
                + "\"agent_id\":\"claudeCode\",\"project\":\"/srv/repo\",\"clients\":0,"
                + "\"created_unix\":0,\"rows\":24,\"cols\":80}"
        }
        let payload = Data(
            "{\"op\":\"sessions\",\"sessions\":[\(rows.joined(separator: ","))],\"re\":1}".utf8)
        backend.receive(TermiodChannel.Reply(
            responseID: Termiod.responseID(of: payload),
            control: try Termiod.decodeControl(payload)))
    }

    /// The status the phone would actually draw for a session — read off the
    /// published roster, through the same mapping the lists render from, not
    /// off the backend's own bookkeeping.
    private func drawnStatus(_ backend: TermiodBackend, _ session: String) -> SessionStatus? {
        var seen: SessionStatus?
        backend.onRoster = { roster in
            seen = roster.projects
                .flatMap(\.sessions)
                .first { $0.rosterID == session }?
                .status
        }
        backend.forcePublishForTests()
        backend.onRoster = nil
        return seen
    }

    /// The ack for a subscription that resumed cleanly.
    private func subscribed(seq: UInt64, gap: Bool = false) -> String {
        "{\"op\":\"subscribed\",\"resource\":\"status:\",\"seq\":\(seq),"
            + "\"gap\":\(gap ? "true" : "false"),\"re\":3}"
    }

    private func deliver(_ backend: TermiodBackend, ack json: String) throws {
        let payload = Data(json.utf8)
        backend.receive(TermiodChannel.Reply(
            responseID: Termiod.responseID(of: payload),
            control: try Termiod.decodeControl(payload)))
    }

    /// A batch that lands before the ack is **held**, not applied — it would
    /// otherwise apply against a baseline the ack has not installed yet.
    func testABatchArrivingBeforeTheAckIsHeldUntilItLands() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        try handshakeAndSubscribe(backend)

        backend.receive(try event(statusChanged(seq: 1, session: "s_1", status: "needs_you")))
        XCTAssertNotEqual(drawnStatus(backend, "s_1"), .needsAttention,
                          "a batch applied before its baseline decision landed")

        try deliver(backend, ack: subscribed(seq: 1))

        XCTAssertEqual(drawnStatus(backend, "s_1"), .needsAttention)
        XCTAssertEqual(backend.statusResumeCursor, 1)
    }

    /// Scenario (a): the cursor must not adopt the ack's `seq`.
    ///
    /// The ack names the end of a replay the host is *about* to send. Adopting
    /// it and then losing the link before the replay arrives means the next
    /// reconnect asks from a future this phone never saw, and 9 and 10 are gone
    /// for good — a session stuck reading `working` after its turn ended.
    func testADisconnectRightAfterTheAckDoesNotSkipTheReplay() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        backend.setStatusCursorForTests(8)
        try handshakeAndSubscribe(backend)  // re-subscribes: the ledger holds again

        // The host says "you will get 9 and 10". Nothing has arrived yet.
        try deliver(backend, ack: subscribed(seq: 10))

        XCTAssertEqual(backend.statusResumeCursor, 8,
                       "the ack is a target, not an achievement")

        // The link drops before either batch lands. The next subscribe must ask
        // from 8, not from 10.
        backend.simulateLinkDropForTests()
        XCTAssertEqual(backend.statusResumeCursor, 8)

        // …and once they do arrive, the cursor follows them one at a time.
        try handshakeAndSubscribe(backend)
        try deliver(backend, ack: subscribed(seq: 10))
        backend.receive(try event(statusChanged(seq: 9, session: "s_1", status: "working")))
        XCTAssertEqual(backend.statusResumeCursor, 9)
        backend.receive(try event(statusChanged(seq: 10, session: "s_1", status: "idle")))
        XCTAssertEqual(backend.statusResumeCursor, 10)
    }

    /// Scenario (b): a stale replayed batch must never overwrite newer truth.
    ///
    /// If a live 11 reaches the phone between the subscription installing and
    /// the replay being queued, applying the replayed 9 and 10 afterwards rolls
    /// the session back to a status that stopped being true two batches ago.
    /// The host now serialises the two, and this is the client's half of the
    /// same guarantee.
    func testAStaleReplayedBatchDoesNotOverwriteALiveOne() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        backend.setStatusCursorForTests(8)
        try handshakeAndSubscribe(backend)  // re-subscribes: the ledger holds again
        try deliver(backend, ack: subscribed(seq: 10))

        // The live one arrives first — the ordering this end must survive.
        backend.receive(try event(statusChanged(seq: 11, session: "s_1", status: "needs_you")))
        XCTAssertEqual(drawnStatus(backend, "s_1"), .needsAttention)

        // Now the replay it was owed. Both are older than what is on screen.
        backend.receive(try event(statusChanged(seq: 9, session: "s_1", status: "working")))
        backend.receive(try event(statusChanged(seq: 10, session: "s_1", status: "idle")))

        XCTAssertEqual(drawnStatus(backend, "s_1"), .needsAttention,
                       "a replayed batch rolled the session backwards")
        XCTAssertEqual(backend.statusResumeCursor, 8,
                       "a hole was crossed, so the cursor stays where it was applied")
    }

    /// A gap has no continuity to preserve, so the cursor restarts at the
    /// baseline the host named and the roster behind it re-establishes rows.
    func testAGapRestartsTheCursorAtTheHostsBaseline() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        backend.setStatusCursorForTests(2)
        try handshakeAndSubscribe(backend)

        try deliver(backend, ack: subscribed(seq: 40, gap: true))

        XCTAssertEqual(backend.statusResumeCursor, 40)
    }

    /// A duplicate this phone has already applied is dropped outright, not
    /// merely ignored for the cursor.
    func testAnAlreadyAppliedBatchIsDropped() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        try handshakeAndSubscribe(backend)
        try deliver(backend, ack: subscribed(seq: 1))

        backend.receive(try event(statusChanged(seq: 1, session: "s_1", status: "needs_you")))
        XCTAssertEqual(drawnStatus(backend, "s_1"), .needsAttention)

        backend.receive(try event(statusChanged(seq: 1, session: "s_1", status: "working")))

        XCTAssertEqual(drawnStatus(backend, "s_1"), .needsAttention, "a duplicate was applied")
        XCTAssertEqual(backend.statusResumeCursor, 1)
    }

    /// An ack for an attempt the link already killed must not settle the
    /// replacement — its batches belong to a subscription that no longer exists.
    func testAnAckFromADeadAttemptIsIgnored() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        try handshakeAndSubscribe(backend)
        backend.simulateLinkDropForTests()

        try deliver(backend, ack: subscribed(seq: 5))

        XCTAssertNil(backend.statusResumeCursor, "a dead attempt installed a baseline")
    }

    /// The daemon's `stalled` fields ride the same batches, so dropping the
    /// broadcast subscription costs nothing — and a batch carrying them is
    /// still an ordinary status batch.
    func testAStalledBatchDecodesAsAStatusBatch() throws {
        let decoded = try event(
            "{\"ev\":\"status_changed\",\"resource\":\"status:\",\"seq\":3,"
                + "\"session\":\"s_1\",\"status\":\"working\","
                + "\"stalled_working_seconds\":1260,\"stalled_transcript_lines_grown\":2}")
        guard case .statusChanged(let change) = decoded else {
            return XCTFail("a status_changed event decoded as something else")
        }
        XCTAssertEqual(change.seq, 3)
        XCTAssertEqual(change.stalledWorkingSeconds, 1260)
        XCTAssertEqual(change.stalledTranscriptLinesGrown, 2)
        XCTAssertEqual(change.report.status, "working", "a stall never moves the status")
    }

    /// A daemon that predates the fields says nothing about them, and every
    /// `needs_you` such a daemon sent was blocking — so absent reads as
    /// blocking, and the field can only ever narrow the claim.
    func testAnOlderDaemonsStatusStillDecodes() throws {
        let decoded = try event("{\"ev\":\"status\",\"session\":\"s_1\",\"status\":\"needs_you\"}")
        guard case .status(let report) = decoded else {
            return XCTFail("a status event decoded as something else")
        }
        XCTAssertNil(report.source)
        XCTAssertFalse(report.turnEnded)
        XCTAssertNil(report.blocking)
        XCTAssertFalse(report.isDerived, "no source means the only channel it had: hooks")
    }

    /// The seam itself: one derived turn end, two viewers, two right answers.
    func testADerivedTurnEndReadsDoneOffScreenAndIdleOnIt() throws {
        let ended = statusChanged(
            seq: 1, session: "s_1", status: "idle", source: "title", turnEnded: true)

        let elsewhere = makeBackend()
        try seedRoster(elsewhere, sessions: ["s_1", "s_2"])
        elsewhere.viewingSessionID = "s_2"
        elsewhere.receive(try event(ended))
        XCTAssertEqual(drawnStatus(elsewhere, "s_1"), .done,
                       "a turn that ended while you were elsewhere is ready for you")

        let watching = makeBackend()
        try seedRoster(watching, sessions: ["s_1"])
        watching.viewingSessionID = "s_1"
        watching.receive(try event(ended))
        XCTAssertEqual(drawnStatus(watching, "s_1"), .idle,
                       "you watched it end — there is nothing to catch up on")
    }

    /// Opening the session clears the mark, the way looking at the row does on
    /// the Mac. Without this the phone keeps a green dot on the screen the user
    /// is already reading.
    func testOpeningASessionClearsItsDoneMark() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        backend.receive(try event(statusChanged(
            seq: 1, session: "s_1", status: "idle", source: "screen", turnEnded: true)))
        XCTAssertEqual(drawnStatus(backend, "s_1"), .done)

        backend.viewingSessionID = "s_1"

        XCTAssertEqual(drawnStatus(backend, "s_1"), .idle)
    }

    /// A hook's own `done` is not the viewer's business: the agent said done, so
    /// it reads done on every client, looked at or not.
    func testAHookDoneIsNotTheViewersToReinterpret() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        backend.viewingSessionID = "s_1"

        backend.receive(try event(statusChanged(
            seq: 2, session: "s_1", status: "done", source: "hook", turnEnded: false)))

        XCTAssertEqual(drawnStatus(backend, "s_1"), .done,
                       "the agent said done; a viewer does not overrule that")
    }

    /// Only the turn end is the viewer's to interpret — a working status is not.
    func testAWorkingStatusIsUntouchedByFocus() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        backend.viewingSessionID = "s_1"

        backend.receive(try event(statusChanged(seq: 3, session: "s_1", status: "working")))

        XCTAssertEqual(drawnStatus(backend, "s_1"), .working)
    }
}
