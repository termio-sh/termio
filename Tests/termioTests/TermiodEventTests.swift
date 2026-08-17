import XCTest
@testable import termio

/// The frames the Mac client negotiates for and now acts on. Decoding is where a
/// protocol client silently goes wrong: a field renamed on the wire, or an event
/// this build has never seen, must degrade to "ignored", never to a dropped
/// status or a dead reader. The payloads below are the daemon's own JSON
/// (termiod/src/protocol.rs `Event` / `Control`), spelled exactly as it emits it.
final class TermiodEventTests: XCTestCase {
    private func event(_ json: String) throws -> Termiod.IncomingEvent {
        try Termiod.decodeEvent(Data(json.utf8))
    }

    private func control(_ json: String) throws -> Termiod.IncomingControl {
        try Termiod.decodeControl(Data(json.utf8))
    }

    /// The event this whole capability exists for: an agent on another machine
    /// reporting a turn boundary, with its workstream title riding along.
    func testStatusCarriesTheStateAndTitle() throws {
        guard case .status(let status) = try event(
            #"{"ev":"status","session":"s_1","status":"needs_you","title":"pick a branch"}"#)
        else { return XCTFail("expected a status event") }
        XCTAssertEqual(status.session, "s_1")
        XCTAssertEqual(status.status, "needs_you")
        XCTAssertEqual(status.title, "pick a branch")
    }

    /// The daemon omits `title` when a session has none — an absent field is not
    /// an empty title and must not fail the decode.
    func testStatusWithoutATitleDecodes() throws {
        guard case .status(let status) = try event(
            #"{"ev":"status","session":"s_1","status":"working"}"#)
        else { return XCTFail("expected a status event") }
        XCTAssertNil(status.title)
    }

    /// `writer_changed` names a client id, which is only meaningful next to the
    /// one `hello_ok` handed this connection.
    func testWriterChangedNamesAClient() throws {
        guard case .writerChanged(let change) = try event(
            #"{"ev":"writer_changed","session":"s_1","writer":"c_41"}"#)
        else { return XCTFail("expected a writer_changed event") }
        XCTAssertEqual(change.writer, "c_41")
    }

    /// Nobody holds the token — the last interactive client detached. `null` is
    /// a legitimate value here, not a missing field.
    func testWriterChangedWithNoWriterDecodes() throws {
        guard case .writerChanged(let change) = try event(
            #"{"ev":"writer_changed","session":"s_1","writer":null}"#)
        else { return XCTFail("expected a writer_changed event") }
        XCTAssertNil(change.writer)
    }

    func testResizedCarriesTheAuthoritativeGrid() throws {
        guard case .resized(let size) = try event(
            #"{"ev":"resized","session":"s_1","rows":40,"cols":120}"#)
        else { return XCTFail("expected a resized event") }
        XCTAssertEqual(size.rows, 40)
        XCTAssertEqual(size.cols, 120)
    }

    func testReadyAndSessionExitedDecode() throws {
        guard case .ready(let session) = try event(#"{"ev":"ready","session":"s_1"}"#)
        else { return XCTFail("expected a ready event") }
        XCTAssertEqual(session, "s_1")

        guard case .sessionExited(let exit) = try event(
            #"{"ev":"session_exited","session":"s_1","status":137}"#)
        else { return XCTFail("expected a session_exited event") }
        XCTAssertEqual(exit.status, 137)
    }

    /// Additive evolution: an event from a newer daemon is ignored by name, not
    /// by killing the reader that carries the session's bytes.
    func testAnUnknownEventIsIgnoredByName() throws {
        guard case .unknown(let name) = try event(
            #"{"ev":"approval_requested","session":"s_1","tool":"Bash"}"#)
        else { return XCTFail("expected an unknown event") }
        XCTAssertEqual(name, "approval_requested")
    }

    /// The addressed half of the writer handover. It shares the payload shape
    /// with the broadcast, and the client feeds both to one handler.
    func testResizeClaimDecodesLikeAWriterChange() throws {
        guard case .resizeClaim(let claim) = try control(
            #"{"op":"resize_claim","session":"s_1","writer":"c_41"}"#)
        else { return XCTFail("expected a resize_claim control") }
        XCTAssertEqual(claim.writer, "c_41")
    }

    /// A dead session's record. `daemon_lost` is the case tombstones exist for,
    /// and the one with no exit status to report — nobody was left to reap the
    /// child, so the field is absent rather than zero.
    func testSessionsReplyCarriesTombstones() throws {
        guard case .sessions(let payload) = try control("""
        {"op":"sessions","sessions":[],"tombstones":[
          {"id":"s_9","name":"9F1C-…","cwd":"/home/me/termio","command":"claude",
           "reason":"daemon_lost","created_unix":1786880000,"ended_unix":1786886075,
           "agent_id":"claude","title":"fix #164","status":"working"}]}
        """) else { return XCTFail("expected a sessions reply") }
        XCTAssertEqual(payload.tombstones.count, 1)
        let grave = try XCTUnwrap(payload.tombstones.first)
        XCTAssertEqual(grave.reason, "daemon_lost")
        XCTAssertNil(grave.exitStatus)
        XCTAssertEqual(grave.status, "working")
        XCTAssertEqual(grave.agentID, "claude")
    }

    /// A daemon too old to bury anything answers without the field. The live
    /// list is still the answer to the question asked, so the reply must decode.
    func testSessionsReplyWithoutTombstonesDecodes() throws {
        guard case .sessions(let payload) = try control("""
        {"op":"sessions","sessions":[
          {"id":"s_1","name":"demo","pid":4242,"alive":true}]}
        """) else { return XCTFail("expected a sessions reply") }
        XCTAssertEqual(payload.sessions.count, 1)
        XCTAssertTrue(payload.tombstones.isEmpty)
    }

    /// Negotiation, not lockstep: a `hello_ok` from a daemon that predates
    /// capability reporting leaves the client with an empty set, not an error.
    func testHelloOkWithoutCapsDecodes() throws {
        guard case .helloOk(let hello) = try control("""
        {"op":"hello_ok","proto":1,"host_id":"h_1","host":"termiod/0.1.0 linux-aarch64",
         "client_id":"c_7"}
        """) else { return XCTFail("expected hello_ok") }
        XCTAssertEqual(hello.clientId, "c_7")
        XCTAssertTrue(hello.caps.isEmpty)
    }
}
