import XCTest
import TermioShared
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
        // A daemon that predates the exit row. The exit is still the answer to
        // the question asked, so it decodes — with nothing claimed about the
        // process.
        XCTAssertNil(exit.info)
    }

    // MARK: - What the device says the process is

    /// The push this whole plane exists for: the host reports the foreground
    /// group's argv, the child's live directory, and whether a job is running —
    /// facts, with no opinion about which agent that is.
    func testRosterCarriesTheProcessFacts() throws {
        guard case .roster(let update) = try event("""
        {"ev":"roster","session":"s_1","action":"updated","info":
          {"id":"s_1","name":"demo","cwd":"/code/termio","command":"/bin/zsh -il","pid":4242,
           "rows":40,"cols":120,"clients":1,"created_unix":1786880000,"alive":true,
           "status":"working","attached_clients":1,
           "foreground_pid":4310,"foreground_argv":["claude","--resume"],"foreground_job":true,
           "child_cwd":"/code/termio/web","child_executable":"/opt/homebrew/bin/claude",
           "child_executable_replaced":true}}
        """) else { return XCTFail("expected a roster event") }
        XCTAssertEqual(update.action, "updated")
        let info = try XCTUnwrap(update.info)
        XCTAssertEqual(info.foregroundPid, 4310)
        XCTAssertEqual(info.foregroundArgv, ["claude", "--resume"])
        XCTAssertEqual(info.foregroundJob, true)
        XCTAssertEqual(info.childCwd, "/code/termio/web")
        XCTAssertEqual(info.childExecutable, "/opt/homebrew/bin/claude")
        XCTAssertEqual(info.childExecutableReplaced, true)
    }

    /// A delta that only announces a session's arrival or departure carries no
    /// row. There is nothing to update, and that must not fail the decode.
    func testARosterDeltaWithoutARowDecodes() throws {
        guard case .roster(let update) = try event(
            #"{"ev":"roster","session":"s_1","action":"removed"}"#)
        else { return XCTFail("expected a roster event") }
        XCTAssertNil(update.info)
    }

    /// A daemon too old to sample the child answers with none of these fields.
    /// Each must decode to `nil` — *unanswered* — rather than to a default that
    /// would read as the device asserting something about the process.
    func testAnOldDaemonsRowClaimsNothingAboutTheProcess() throws {
        guard case .sessions(let payload) = try control("""
        {"op":"sessions","sessions":[
          {"id":"s_1","name":"demo","pid":4242,"alive":true,"cwd":"/code","command":"/bin/zsh -il",
           "status":"unknown","created_unix":1786880000,"attached_clients":1}]}
        """) else { return XCTFail("expected a sessions reply") }
        let info = try XCTUnwrap(payload.sessions.first)
        XCTAssertNil(info.foregroundPid)
        XCTAssertNil(info.foregroundArgv)
        XCTAssertNil(info.foregroundJob)
        XCTAssertNil(info.childCwd)
        XCTAssertNil(info.childExecutable)
        XCTAssertNil(info.childExecutableReplaced)
    }

    /// The daemon omits `foreground_job` when it is false, so a shell idling at
    /// its prompt on a *current* daemon carries no more of that field than an old
    /// daemon does. Both mean "do not confirm this close", which is why nothing
    /// has to tell them apart — but the sampled fields that *do* arrive show the
    /// row was sampled, so the absence is a real `false` and not a blind spot.
    func testAnIdlePromptOmitsTheForegroundJobRatherThanDenyingIt() throws {
        guard case .roster(let update) = try event("""
        {"ev":"roster","session":"s_1","action":"updated","info":
          {"id":"s_1","name":"demo","cwd":"/code","command":"/bin/zsh -il","pid":4242,
           "rows":40,"cols":120,"clients":1,"created_unix":1786880000,"alive":true,
           "status":"unknown","attached_clients":1,
           "foreground_pid":4242,"foreground_argv":["-zsh"],"child_cwd":"/code"}}
        """) else { return XCTFail("expected a roster event") }
        let info = try XCTUnwrap(update.info)
        XCTAssertNil(info.foregroundJob)
        XCTAssertEqual(info.foregroundPid, 4242)
        XCTAssertEqual(info.foregroundArgv, ["-zsh"])
    }

    /// The exit's own row, which is the point of carrying one: the replacement
    /// check is made on the exit path, not read from a poll that ran seconds
    /// before the agent quit.
    func testSessionExitedCarriesTheDevicesFinalWord() throws {
        guard case .sessionExited(let exit) = try event("""
        {"ev":"session_exited","session":"s_1","status":0,"info":
          {"id":"s_1","name":"demo","cwd":"/code","command":"codex","pid":4242,
           "rows":40,"cols":120,"clients":0,"created_unix":1786880000,"alive":false,
           "status":"done","attached_clients":0,
           "child_executable":"/opt/homebrew/bin/codex","child_executable_replaced":true}}
        """) else { return XCTFail("expected a session_exited event") }
        let info = try XCTUnwrap(exit.info)
        XCTAssertFalse(info.alive)
        XCTAssertEqual(info.childExecutableReplaced, true)
    }

    // MARK: - Where an arriving row lands

    private func link() -> TermiodSessionLink {
        TermiodSessionLink(
            sessionName: "demo",
            specification: Termiod.CreateSpecification(
                cwd: "/code", argv: [], env: [], rows: 40, cols: 120),
            rows: 40, cols: 120)
    }

    private static let liveRoster = """
    {"ev":"roster","session":"s_1","action":"updated","info":
      {"id":"s_1","name":"demo","cwd":"/code","command":"/bin/zsh -il","pid":4242,
       "rows":40,"cols":120,"clients":1,"created_unix":1786880000,"alive":true,
       "status":"working","attached_clients":1,
       "foreground_pid":4310,"foreground_argv":["npm","run","build"],"foreground_job":true}}
    """

    private static let exitRow = """
    {"ev":"session_exited","session":"s_1","status":0,"info":
      {"id":"s_1","name":"demo","cwd":"/code","command":"codex","pid":4242,
       "rows":40,"cols":120,"clients":0,"created_unix":1786880000,"alive":false,
       "status":"done","attached_clients":0,"child_executable_replaced":true}}
    """

    /// A roster push is what the close confirmation reads, so it lands in the
    /// live cache.
    func testARosterPushLandsInTheLiveCache() {
        let link = self.link()
        _ = link.handleEvent(Data(Self.liveRoster.utf8))
        XCTAssertEqual(link.latestInformation?.foregroundJob, true)
    }

    /// The exit row must never reach that cache. It describes a session that has
    /// **ended** — `alive: false`, nothing in the foreground — and it is recorded
    /// on the reader thread while the link is still registered, so overwriting
    /// the live row here would let a close asked in that window be answered by a
    /// dead process's blank sample.
    func testTheExitRowNeverOverwritesTheLiveCache() {
        let link = self.link()
        _ = link.handleEvent(Data(Self.liveRoster.utf8))
        _ = link.handleEvent(Data(Self.exitRow.utf8))

        let cached = link.latestInformation
        XCTAssertEqual(cached?.foregroundJob, true, "the live row must still be the live row")
        XCTAssertEqual(cached?.alive, true)
        XCTAssertNil(cached?.childExecutableReplaced)
    }

    /// And the exit still gets the device's final word, which is the only place
    /// the replacement check is made on the exit path rather than read off a poll.
    func testTheExitCarriesTheDevicesFinalReplacementAnswer() {
        let link = self.link()
        let delivered = expectation(description: "exit delivered")
        var reported: Termiod.SessionInformation?
        link.onExit = { _, _, information in
            reported = information
            delivered.fulfill()
        }
        _ = link.handleEvent(Data(Self.liveRoster.utf8))
        _ = link.handleEvent(Data(Self.exitRow.utf8))

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(reported?.childExecutableReplaced, true)
        XCTAssertEqual(reported?.alive, false)
    }

    /// A daemon too old to carry an exit row leaves the exit with nothing to read
    /// — and the live cache is deliberately not a fallback: a row sampled seconds
    /// before the exit answers a different question.
    func testAnExitWithNoRowReportsNothingRatherThanTheLastPoll() {
        let link = self.link()
        let delivered = expectation(description: "exit delivered")
        var reported: Termiod.SessionInformation?
        var sawExit = false
        link.onExit = { _, _, information in
            reported = information
            sawExit = true
            delivered.fulfill()
        }
        _ = link.handleEvent(Data(Self.liveRoster.utf8))
        _ = link.handleEvent(Data(#"{"ev":"session_exited","session":"s_1","status":0}"#.utf8))

        wait(for: [delivered], timeout: 2)
        XCTAssertTrue(sawExit)
        XCTAssertNil(reported)
    }

    /// Additive evolution: an event from a newer daemon is ignored by name, not
    /// by killing the reader that carries the session's bytes.
    func testAnUnknownEventIsIgnoredByName() throws {
        guard case .unknown(let name) = try event(
            #"{"ev":"approval_requested","session":"s_1","tool":"Bash"}"#)
        else { return XCTFail("expected an unknown event") }
        XCTAssertEqual(name, "approval_requested")
    }

    /// A daemon predating the size-policy change may still address one client
    /// with `resize_claim`; it decodes as unknown and is ignored, not fatal.
    func testAResizeClaimFromAnOlderDaemonIsIgnored() throws {
        guard case .unknown = try control(
            #"{"op":"resize_claim","session":"s_1","writer":"c_41"}"#)
        else { return XCTFail("expected resize_claim to decode as unknown") }
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

    /// A grave carries the self-update verdict. The exit *event* carries it too,
    /// but only to clients that were attached when it fired — for a Mac that was
    /// asleep when the agent replaced itself and quit, this is the only route.
    func testATombstoneCarriesTheSelfUpdateVerdict() throws {
        guard case .sessions(let payload) = try control("""
        {"op":"sessions","sessions":[],"tombstones":[
          {"id":"s_9","name":"9F1C-…","cwd":"/code","command":"claude",
           "reason":"exited","exit_status":0,"created_unix":1786880000,
           "ended_unix":1786886075,"status":"done","child_executable_replaced":true}]}
        """) else { return XCTFail("expected a sessions reply") }
        let grave = try XCTUnwrap(payload.tombstones.first)
        XCTAssertTrue(grave.childExecutableReplaced)
    }

    /// `daemon_lost` cannot testify either way — the daemon that would have
    /// re-read the inode is the thing that died. An absent field must read as
    /// "nobody measured", never as a positive "not replaced" the UI could show.
    func testALostGraveDoesNotClaimTheBinarySurvived() throws {
        guard case .sessions(let payload) = try control("""
        {"op":"sessions","sessions":[],"tombstones":[
          {"id":"s_9","name":"9F1C-…","cwd":"/code","command":"claude",
           "reason":"daemon_lost","created_unix":1786880000,"ended_unix":1786886075,
           "status":"working"}]}
        """) else { return XCTFail("expected a sessions reply") }
        let grave = try XCTUnwrap(payload.tombstones.first)
        XCTAssertFalse(grave.childExecutableReplaced)
    }

    // MARK: - What a roster-only row is called

    private func information(_ json: String) throws -> Termiod.SessionInformation {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Termiod.SessionInformation.self, from: Data(json.utf8))
    }

    /// The row this whole field exists for: a session on another machine that
    /// this app has never attached to. There is no surface to read a title off,
    /// and `command` is the login-shell wrapper Termio spawns through — so the
    /// only non-guess is what the device's kernel reported.
    func testARosterOnlyRowIsNamedByTheKernelNotTheCommandString() throws {
        let info = try information("""
        {"id":"s_1","name":"9F1C-…","pid":4242,"alive":true,"cwd":"/code",
         "command":"/bin/zsh -ilc exec claude --resume","status":"working",
         "created_unix":1786880000,"attached_clients":0,
         "foreground_pid":4310,"foreground_argv":["/opt/homebrew/bin/npm","run","build"],
         "foreground_job":true}
        """)
        XCTAssertEqual(info.displayLabel, "npm",
                       "the kernel said npm; the command string would have guessed claude")
    }

    /// A daemon that did not answer must leave the label alone rather than blank
    /// it — the string rules stay as the fallback, so an older host reads exactly
    /// as it did before the field existed.
    func testAnUnansweredForegroundFallsBackToTheCommandString() throws {
        let info = try information("""
        {"id":"s_1","name":"9F1C-…","pid":4242,"alive":true,"cwd":"/code",
         "command":"/bin/zsh -ilc exec claude --resume","status":"working",
         "created_unix":1786880000,"attached_clients":0}
        """)
        XCTAssertEqual(info.displayLabel, "claude")
    }

    /// An agent that reported a title outranks both. The title is what the agent
    /// says it is *doing*; the argv is only what it is running.
    func testAReportedTitleStillOutranksTheForegroundArgv() throws {
        let info = try information("""
        {"id":"s_1","name":"9F1C-…","pid":4242,"alive":true,"cwd":"/code",
         "command":"/bin/zsh -il","status":"working","title":"fix #164",
         "created_unix":1786880000,"attached_clients":0,
         "foreground_argv":["/usr/bin/git","rebase","-i"]}
        """)
        XCTAssertEqual(info.displayLabel, "fix #164")
    }

    /// The idle row, which is most of them: a session sitting at its prompt
    /// reports its own login shell as the foreground, and a login shell's
    /// `argv[0]` carries the `-` marker (`termiod/src/pty.rs` sets it). Passing
    /// that through would name the commonest roster row `-zsh`.
    func testALoginShellIsNamedWithoutItsLoginMarker() throws {
        let info = try information("""
        {"id":"s_1","name":"9F1C-…","pid":4242,"alive":true,"cwd":"/code",
         "command":"/bin/zsh -il","status":"idle",
         "created_unix":1786880000,"attached_clients":0,
         "foreground_pid":4242,"foreground_argv":["-zsh"]}
        """)
        XCTAssertEqual(info.displayLabel, "zsh")
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

    /// The Search pane's stream: hits arrive as events addressed to the request,
    /// which is why this is the one event carrying no session.
    func testSearchResultsCarryTheHits() throws {
        guard case .searchResults(let payload) = try event("""
        {"ev":"search_results","request":1,"matches":[
          {"path":"src/main.rs","line":42,"text":"let widget = 1;"}]}
        """) else { return XCTFail("expected search results") }
        XCTAssertEqual(payload.matches.count, 1)
        XCTAssertEqual(payload.matches.first?.path, "src/main.rs")
        XCTAssertEqual(payload.matches.first?.line, 42)
    }

    /// The reply that closes the stream. `limit_hit` is the difference between
    /// "that is everything" and "there is more" — the pane says so out loud.
    func testSearchedReplyCarriesWhyTheStreamEnded() throws {
        guard case .fsSearched(let payload) = try control(
            #"{"op":"fs_searched","matches":400,"limit_hit":true,"re":1}"#)
        else { return XCTFail("expected fs_searched") }
        XCTAssertEqual(payload.matches, 400)
        XCTAssertTrue(payload.limitHit)
        XCTAssertFalse(payload.canceled)
    }

    /// The daemon omits both flags on a clean finish; absent is `false`, not a
    /// decode failure.
    func testSearchedReplyWithoutFlagsDecodes() throws {
        guard case .fsSearched(let payload) = try control(#"{"op":"fs_searched","matches":0}"#)
        else { return XCTFail("expected fs_searched") }
        XCTAssertFalse(payload.limitHit)
        XCTAssertFalse(payload.canceled)
    }

    /// A request must not wait forever on a host that owes it nothing: a daemon
    /// too old for an op drops it silently instead of refusing it, so without a
    /// bound the reader parks a thread and its connection for good.
    func testAWaitingReadGivesUpOnSilence() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }

        XCTAssertThrowsError(
            try Termiod.waitForReadable(pair[0], seconds: 1, operation: "fs.search")
        ) { error in
            guard case TermiodClientError.timedOut = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
        }
    }

    /// And it returns the moment the device does answer — the bound above must
    /// not cost a reply that arrived in time.
    func testAWaitingReadReturnsWhenTheDeviceAnswers() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }

        var byte: UInt8 = 0x43
        XCTAssertEqual(write(pair[1], &byte, 1), 1)
        XCTAssertNoThrow(
            try Termiod.waitForReadable(pair[0], seconds: 5, operation: "fs.search"))
    }

    // MARK: - Routing replies on a shared channel

    /// `re` is what a pooled channel demultiplexes on. It was always on the wire
    /// and nothing read it, so this is the field most likely to be quietly
    /// dropped by a codec change — and dropping it does not fail a build, it
    /// hands one caller another caller's answer.
    func testAReplyNamesTheRequestItAnswers() throws {
        guard case .fsListed = try control(#"{"op":"fs_listed","seq":0,"listings":[],"re":7}"#)
        else { return XCTFail("expected fs_listed") }
        XCTAssertEqual(
            Termiod.responseID(of: Data(#"{"op":"fs_listed","seq":0,"listings":[],"re":7}"#.utf8)),
            7)
        XCTAssertEqual(
            Termiod.responseID(of: Data(#"{"op":"error","code":"denied","message":"x","re":9}"#.utf8)),
            9)
    }

    /// A reply that answers nobody must route nowhere rather than to request 0.
    /// `hello_ok` is the real case: it precedes every id there is.
    func testAReplyThatAnswersNobodyHasNoRequestID() {
        XCTAssertNil(Termiod.responseID(of: Data(
            #"{"op":"hello_ok","proto":1,"caps":[],"host_id":"h","host":"t","client_id":"c"}"#.utf8)))
        XCTAssertNil(Termiod.responseID(of: Data(#"{"ev":"ready","session":"s"}"#.utf8)))
    }

    /// An `F` chunk carries its request id in the binary header, not in JSON, so
    /// it is routed by a different reader than every other frame — and a file
    /// delivered to the wrong request is a corrupted preview, not an error.
    func testAFileChunkCarriesTheRequestItBelongsTo() throws {
        var payload = Data()
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 42]) // re
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 8]) // offset
        payload.append(1) // last
        payload.append(contentsOf: Array("hello".utf8))

        let chunk = try Termiod.decodeFileChunk(payload)
        XCTAssertEqual(chunk.request, 42)
        XCTAssertEqual(chunk.offset, 8)
        XCTAssertTrue(chunk.last)
        XCTAssertEqual(chunk.data, Data("hello".utf8))
    }

    /// A batch of search hits names no session, so `request` is its only route.
    /// A grep sharing a channel with a folder expand depends on it entirely.
    func testASearchBatchNamesTheSearchItBelongsTo() throws {
        guard case .searchResults(let payload) = try event(
            #"{"ev":"search_results","request":3,"matches":[{"path":"a.txt","line":1,"text":"hi"}]}"#)
        else { return XCTFail("expected search_results") }
        XCTAssertEqual(payload.request, 3)
        XCTAssertEqual(payload.matches.map(\.path), ["a.txt"])
    }
}
