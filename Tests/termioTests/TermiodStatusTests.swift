import AppKit
import XCTest
@testable import termio

/// `TermioStore.applyTermiodStatus` — where a host-reported workstream state
/// becomes a row's status. The host names the state and this side decides what
/// it looks like, so these tests pin the *decisions*: which state settles as a
/// calm cue, which demands attention, and which is not the host's to make.
@MainActor
final class TermiodStatusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The attention arms ask whether the user is looking, which reads
        // `NSApp` — nil in a bare test process until something asks for the
        // shared application.
        _ = NSApplication.shared
    }

    private func makeStore(with session: Session) -> TermioStore {
        let project = Project(name: "termio", path: "/code/termio", branch: "main",
                              sessions: [session], kind: .folder)
        let defaults = UserDefaults(suiteName: "termiod-status-\(UUID().uuidString)")
        return TermioStore(projects: [project],
                           settings: AppSettings(defaults: defaults ?? .standard))
    }

    private func status(_ state: String, title: String? = nil) -> Termiod.StatusPayload {
        Termiod.StatusPayload(session: "s_1", status: state, title: title)
    }

    /// A remote terminal is a plain `.terminal` row — the agent runs on the far
    /// machine. Gating on the local agent kind, as the hook path does, would
    /// discard every status a VPS agent reports, which is the entire reason this
    /// path exists.
    func testWorkingSpinsAPlainRemoteTerminalRow() {
        var session = Session(title: "ukvps", agent: .terminal)
        session.termiodRemoteHost = "ukvps"
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working"), for: session.id)

        XCTAssertEqual(store.status(for: session.id), .working)
    }

    func testDoneAndIdleSettleTheRow() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working"), for: session.id)
        store.applyTermiodStatus(status("done"), for: session.id)
        XCTAssertEqual(store.status(for: session.id), .done)

        store.applyTermiodStatus(status("idle"), for: session.id)
        XCTAssertEqual(store.status(for: session.id), .idle)
    }

    /// A failed run is not a green "ready for you" dot. It settles as attention
    /// the user can dismiss by looking, unlike a genuine blocking prompt.
    func testFailedAsksForAttentionRatherThanReadingAsSuccess() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working"), for: session.id)
        store.applyTermiodStatus(status("failed"), for: session.id)

        XCTAssertEqual(store.status(for: session.id), .needsAttention)
        XCTAssertFalse(store.blockingAttention.contains(session.id))
    }

    /// `needs_you` is an observable blocking condition, so its dot is recorded
    /// as blocking and survives a click — reading a permission prompt is not
    /// answering it.
    func testNeedsYouIsRecordedAsBlocking() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("needs_you"), for: session.id)

        XCTAssertEqual(store.status(for: session.id), .needsAttention)
        XCTAssertTrue(store.blockingAttention.contains(session.id))
    }

    /// `unknown` is the daemon's default for a session nobody has reported on.
    /// Writing it would erase what the local signals worked out.
    func testUnknownLeavesTheRowAlone() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working"), for: session.id)
        store.applyTermiodStatus(status("unknown"), for: session.id)

        XCTAssertEqual(store.status(for: session.id), .working)
    }

    /// The workstream title is the agent's own label for the row, and lands in
    /// the same place the OSC 0/2 title does.
    func testTheWorkstreamTitleLandsOnTheRow() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.applyTermiodStatus(status("working", title: "fix #164"), for: session.id)

        XCTAssertEqual(store.runtimes[session.id]?.liveTitle, "fix #164")
    }

    /// A report addressed to a session this app does not have is not this app's
    /// story — it must not mint a runtime for a row that isn't there.
    func testAReportForAnUnknownSessionIsDropped() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)
        let stranger = UUID()

        store.applyTermiodStatus(status("working"), for: stranger)

        XCTAssertNil(store.runtimes[stranger])
    }

    // MARK: - Tombstones

    private func tombstone(name: String, reason: String) throws -> Termiod.SessionTombstone {
        let json = """
        {"id":"s_1","name":"\(name)","cwd":"/code","command":"claude","reason":"\(reason)",
         "created_unix":1786880000,"ended_unix":1786886075,"status":"working"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Termiod.SessionTombstone.self, from: Data(json.utf8))
    }

    private func live(name: String) throws -> Termiod.SessionInformation {
        let json = """
        {"id":"s_1","name":"\(name)","pid":42,"alive":true,"cwd":"/code",
         "command":"claude","status":"working","agent_id":null,"title":null,
         "created_unix":1786880000,"attached_clients":1}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Termiod.SessionInformation.self, from: Data(json.utf8))
    }

    /// The reason a row's session died is addressable from the row.
    func testAnEndReasonIsFoundBySessionID() throws {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)
        let name = session.id.uuidString

        store.recordTombstones(
            [try tombstone(name: name, reason: "daemon_lost")], live: [], persisted: [name])

        XCTAssertEqual(store.termiodEndReason(for: session.id)?.reason, "daemon_lost")
    }

    /// A name that comes back alive buries its own grave. Tombstones merge rather
    /// than replace, so without this a session restarted under the same name would
    /// keep wearing the end reason of the run before it.
    func testALiveNameLosesItsTombstone() throws {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)
        let name = session.id.uuidString

        store.recordTombstones(
            [try tombstone(name: name, reason: "daemon_lost")], live: [], persisted: [name])
        XCTAssertNotNil(store.termiodEndReason(for: session.id))

        store.recordTombstones([], live: [try live(name: name)], persisted: [name])
        XCTAssertNil(store.termiodEndReason(for: session.id))
    }

    /// Another client's sessions share the daemon but not the sidebar. Keeping
    /// their graves would put rows in this map that no row can ever ask about.
    func testTombstonesForOtherClientsSessionsAreNotKept() throws {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(with: session)

        store.recordTombstones(
            [try tombstone(name: "someone-elses-session", reason: "exited")],
            live: [], persisted: [session.id.uuidString])

        XCTAssertTrue(store.termiodTombstones.isEmpty)
        XCTAssertNil(store.termiodEndReason(for: session.id))
    }
}
