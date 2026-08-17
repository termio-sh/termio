@testable import termio
import TermioShared
import XCTest

final class WireProtocolTests: XCTestCase {
    func testAuthRoundTripCarriesCurrentWireVersion() {
        let auth = CompanionControl.auth(token: "pairing-token", wire: Wire.current)

        XCTAssertEqual(CompanionControl.decode(auth.encoded()), auth)
    }

    func testAuthWithoutWireDecodesAsLegacy() {
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"auth","token":"pairing-token"}"#),
            .auth(token: "pairing-token", wire: Wire.legacy)
        )
    }

    func testRosterRoundTripCarriesCurrentWireVersion() throws {
        let roster = CompanionRoster(projects: [])

        let decoded = try XCTUnwrap(CompanionRoster.decode(roster.encodedJSON()))
        XCTAssertEqual(decoded, roster)
        XCTAssertEqual(decoded.wire, Wire.current)
    }

    func testRosterWithoutWireDecodesAsLegacy() throws {
        let decoded = try XCTUnwrap(
            CompanionRoster.decode(#"{"t":"roster","projects":[]}"#)
        )

        XCTAssertEqual(decoded.wire, Wire.legacy)
    }

    /// The whole point: one session the phone can't read costs that row, not the
    /// tree. Before lossy decoding this returned nil and the phone showed an
    /// empty app.
    func testRosterDropsOnlyTheUnreadableSession() throws {
        let json = """
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio","sessions":[\
        {"id":"s1","title":"Good","agent":"claude","status":"idle"},\
        {"id":"s2","title":"Missing agent and status"},\
        {"id":"s3","title":"Also good","agent":"codex","status":"working"}]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.count, 1)
        XCTAssertEqual(decoded.projects.first?.sessions.map(\.id), ["s1", "s3"])
    }

    func testRosterDropsOnlyTheUnreadableProject() throws {
        let json = """
        {"t":"roster","projects":[\
        {"id":"p1","name":"termio","path":"/tmp/termio","sessions":[]},\
        {"name":"no id","path":"/tmp/broken","sessions":[]},\
        {"id":"p3","name":"other","path":"/tmp/other","sessions":[]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.map(\.id), ["p1", "p3"])
    }

    /// A session from a newer Mac carrying fields this build never heard of
    /// still decodes — unknown keys are ignored, not fatal.
    func testRosterKeepsSessionWithUnknownFields() throws {
        let json = """
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio","sessions":[\
        {"id":"s1","title":"Good","agent":"claude","status":"idle","somethingNewer":{"a":1}}]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.first?.sessions.map(\.id), ["s1"])
    }

    /// An unknown tag has to arrive as a value, not as nil: the drop is only
    /// loggable if the receiver is handed something.
    func testUnknownControlTypeDecodesAsUnsupported() {
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"somethingFromANewerPhone","x":1}"#),
            .unsupported(type: "somethingFromANewerPhone")
        )
    }

    func testMalformedControlFrameStillDecodesToNil() {
        XCTAssertNil(CompanionControl.decode("not json at all"))
    }

    /// A bad element is not always an object. The slot-consuming decode has to
    /// swallow scalars, null, and arrays too, or the array truncates at the
    /// first one of those and everything after it is lost.
    func testRosterSkipsNonObjectSessionEntries() throws {
        for bad in ["null", "42", #""a string""#, "[1,2]", "[]", "true"] {
            let json = """
            {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio","sessions":[\
            {"id":"s1","title":"Good","agent":"claude","status":"idle"},\
            \(bad),\
            {"id":"s3","title":"Also good","agent":"codex","status":"working"}]}]}
            """

            let decoded = try XCTUnwrap(CompanionRoster.decode(json), "failed for \(bad)")

            XCTAssertEqual(
                decoded.projects.first?.sessions.map(\.id), ["s1", "s3"],
                "the element after \(bad) was lost"
            )
        }
    }

    func testRosterDropsOnlyTheUnreadableAgent() throws {
        let json = """
        {"t":"roster","projects":[],"agents":[\
        {"id":"claude","name":"Claude Code"},\
        {"id":"missing name"},\
        {"id":"codex","name":"Codex"}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.agents.map(\.id), ["claude", "codex"])
    }

    /// `RosterProject` decodes through a hand-written `init(from:)` while its
    /// encoder stays synthesized, so the two can drift apart. Every optional
    /// field has to be populated or the round trip proves nothing.
    func testPopulatedRosterRoundTrips() throws {
        let roster = CompanionRoster(
            projects: [
                RosterProject(
                    id: "p1", name: "termio", path: "/tmp/termio",
                    branch: "fix/wire-tolerance", kind: "folder",
                    sessions: [
                        RosterSession(
                            id: "s1", title: "Session", agent: "claude", status: "working",
                            subtitle: "Working — Bash", branch: "fix/wire-tolerance"
                        )
                    ]
                )
            ],
            agents: [RosterAgent(id: "claude", name: "Claude Code", tintHex: "#D97757")]
        )

        XCTAssertEqual(CompanionRoster.decode(roster.encodedJSON()), roster)
    }

    /// Re-encoding an unsupported message must not hand a peer the command this
    /// build refused to read: `.unsupported("startTerminal")` may never come
    /// back out as a real `.startTerminal`.
    func testUnsupportedDoesNotReEncodeAsARealCommand() {
        let unsupported = CompanionControl.unsupported(type: "startTerminal")

        XCTAssertNotEqual(CompanionControl.decode(unsupported.encoded()), .startTerminal)
        XCTAssertEqual(CompanionControl.decode(unsupported.encoded()), unsupported)
    }

    /// The tag reaches a `.public` log field and a paired phone picks it, so a
    /// newline in it would forge a log line and a long one would bury its
    /// neighbours.
    func testLoggableTagCannotForgeALogLine() {
        let forged = CompanionServer.loggableTag("secret-value\nmisleading log text")

        XCTAssertFalse(forged.contains("\n"))
        XCTAssertFalse(forged.contains(" "))
        XCTAssertEqual(forged, "secret-value?misleading?log?text")
    }

    func testLoggableTagIsBounded() {
        XCTAssertEqual(CompanionServer.loggableTag(String(repeating: "a", count: 500)).count, 40)
    }

    func testLoggableTagKeepsRealTagsReadable() {
        XCTAssertEqual(CompanionServer.loggableTag("startTerminal"), "startTerminal")
        XCTAssertEqual(CompanionServer.loggableTag("read-file_v2.1"), "read-file_v2.1")
        XCTAssertEqual(CompanionServer.loggableTag(""), "(empty)")
    }
}
