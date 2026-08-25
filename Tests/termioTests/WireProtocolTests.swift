@testable import termio
import TermioShared
import XCTest

final class WireProtocolTests: XCTestCase {
    /// The keys every wire-2 project carries, spliced into the fixtures below so
    /// each test is about the one tolerance it names rather than about these.
    private static let workspaceFields =
        #""workspaceID":"w1","workspaceName":"Sessions","branch":"","kind":"folder""#

    /// The wire-2 break, stated as a test: a project from a v1 Mac names no
    /// workspace, so it is unreadable rather than half-read. The version gate is
    /// what turns that into "update the other end"; this only pins that the
    /// decoder does not quietly invent a workspace for it.
    func testProjectWithoutAWorkspaceIsUnreadable() throws {
        let json = #"""
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio","sessions":[]}]}
        """#

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects, [])
    }

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
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio",\
        \(Self.workspaceFields),"sessions":[\
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
        {"id":"p1","name":"termio","path":"/tmp/termio",\(Self.workspaceFields),"sessions":[]},\
        {"name":"no id","path":"/tmp/broken",\(Self.workspaceFields),"sessions":[]},\
        {"id":"p3","name":"other","path":"/tmp/other",\(Self.workspaceFields),"sessions":[]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.map(\.id), ["p1", "p3"])
    }

    /// A session from a newer Mac carrying fields this build never heard of
    /// still decodes — unknown keys are ignored, not fatal.
    func testRosterKeepsSessionWithUnknownFields() throws {
        let json = """
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio",\
        \(Self.workspaceFields),"sessions":[\
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
            {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio",\
            \(Self.workspaceFields),"sessions":[\
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
                    workspaceID: "w1", workspaceName: "ukvps", deviceAlias: "ukvps",
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

        XCTAssertNotEqual(
            CompanionControl.decode(unsupported.encoded()), .startTerminal(workspaceID: nil))
        XCTAssertEqual(CompanionControl.decode(unsupported.encoded()), unsupported)
    }

    /// The workspace a phone-started terminal lands in is additive: a phone that
    /// predates the field sends the older shape, and it has to keep meaning what
    /// it meant — "the Mac picks" — rather than failing to decode.
    func testStartWithoutAWorkspaceStillDecodes() {
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"startTerminal"}"#), .startTerminal(workspaceID: nil))
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"startSSH","host":"vps"}"#),
            .startSSH(host: "vps", workspaceID: nil))
    }

    /// And a named workspace survives the round trip, so the Mac resolves the
    /// funnel where the phone said rather than where its own window is pointed.
    func testStartCarriesItsWorkspace() {
        let terminal = CompanionControl.startTerminal(workspaceID: "WS-1")
        let ssh = CompanionControl.startSSH(host: "vps", workspaceID: "WS-2")

        XCTAssertEqual(CompanionControl.decode(terminal.encoded()), terminal)
        XCTAssertEqual(CompanionControl.decode(ssh.encoded()), ssh)
    }

    /// Both ends build a loose section's wire id, so a phone can address the
    /// Chats funnel of a workspace the Mac has not opened one in yet.
    @MainActor
    func testLooseSectionIDMatchesTheMacsOwn() {
        let workspace = Workspace(name: "Alpha")

        XCTAssertEqual(
            TermioStore.looseWireID(workspace: workspace, chats: true),
            Wire.looseSectionID(workspaceID: workspace.id.uuidString, chats: true))
        XCTAssertEqual(
            TermioStore.looseWireID(workspace: workspace, chats: false),
            Wire.looseSectionID(workspaceID: workspace.id.uuidString, chats: false))
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
