import XCTest
import TermioShared
@testable import termio

/// The wrapped-tree exit detector (RFC 20260830 §D2), as pure verdict logic —
/// the same shape as `StallProbeTests`: sequences of foreground samples in,
/// exactly one demotion out.
///
/// The scenario is #528's process tree: `zsh -ilc "exec claude"` where the
/// `exec` didn't replace the shell (an alias or function shim is enough), so
/// the agent quitting leaves the daemon session alive and no exit event ever
/// fires. The foreground sampler reporting the login shell is the only signal
/// left, and these pin how much of it counts as evidence.
final class AgentExitStreakTests: XCTestCase {
    func testTwoShellSamplesDemote() {
        var streak = AgentExitStreak()
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold,
                       "one sample is a coincidence, not an exit")
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .demote)
    }

    func testTheAgentInFrontResetsTheStreak() {
        var streak = AgentExitStreak()
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold)
        XCTAssertEqual(streak.observe(foregroundArgv: ["claude"]), .hold)
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold,
                       "the reset means the evidence starts over")
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .demote)
    }

    /// `nil` argv is *unanswered* — a daemon too old to sample and an unreadable
    /// process look identical — so it must neither advance nor reset the streak.
    func testAnUnansweredSampleStandsDown() {
        var streak = AgentExitStreak()
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold)
        XCTAssertEqual(streak.observe(foregroundArgv: nil), .hold)
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .demote,
                       "an unanswered sample erased evidence it never contradicted")
    }

    func testDemotionFiresExactlyOnce() {
        var streak = AgentExitStreak()
        _ = streak.observe(foregroundArgv: ["-zsh"])
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .demote)
        XCTAssertEqual(streak.observe(foregroundArgv: ["-zsh"]), .hold,
                       "a shell that stays in front must not re-fire every sample")
    }

    func testSomethingElseTakingTheForegroundBackClearsTheNotice() {
        var streak = AgentExitStreak()
        _ = streak.observe(foregroundArgv: ["-zsh"])
        _ = streak.observe(foregroundArgv: ["-zsh"])
        XCTAssertEqual(streak.observe(foregroundArgv: ["claude"]), .agentReturned)
        XCTAssertEqual(streak.observe(foregroundArgv: ["claude"]), .hold,
                       "the return is an edge, not a level")
    }

    func testShellRecognitionNormalizesLikeTheAgentCatalog() {
        XCTAssertTrue(AgentExitStreak.isShell(["-zsh"]), "login-shell marker")
        XCTAssertTrue(AgentExitStreak.isShell(["/bin/bash", "-il"]), "full path")
        XCTAssertTrue(AgentExitStreak.isShell(["fish"]))
        XCTAssertFalse(AgentExitStreak.isShell(["claude"]))
        XCTAssertFalse(AgentExitStreak.isShell(["vim", "notes.md"]))
        XCTAssertFalse(AgentExitStreak.isShell([]))
    }
}

/// The roster sweep's verdict for a session no row accounts for (RFC 20260830
/// §D3), and the path containment its project filing rests on.
final class ExternalSessionResolutionTests: XCTestCase {
    private func record(
        _ name: String, alias: String? = nil, daemonID: String? = "aaaa1111"
    ) -> ClosedDaemonSession {
        ClosedDaemonSession(name: name, sshAlias: alias, deviceID: nil, daemonID: daemonID)
    }

    func testAJournaledNameIsKilledOnSight() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "orphan", rowID: "aaaa1111", attachedClients: 0, isLocal: true,
                journaled: record("orphan")),
            .killOnSight)
    }

    /// The journal outranks an attached client: a journaled name is this app's
    /// own closed session, and the close already promised it would end.
    func testTheJournalOutranksAnAttachedClient() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "orphan", rowID: "aaaa1111", attachedClients: 1, isLocal: true,
                journaled: record("orphan")),
            .killOnSight)
    }

    /// A same-named row with a different daemon id is legitimate name reuse —
    /// someone recreated `build` from the CLI after the kill landed — and
    /// killing it would murder a session the close never promised to end. It
    /// resolves like any other stranger.
    func testASameNamedRowWithADifferentIDIsSparedTheKill() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "build", rowID: "bbbb2222", attachedClients: 0, isLocal: true,
                journaled: record("build", daemonID: "aaaa1111")),
            .adopt)
    }

    /// The identity gate, arm by arm: the daemon never reuses an id, so a
    /// matching id is the closed session itself and a different id is a new
    /// one. A record without an id may claim by name only when the name is
    /// app-authored — a UUID, which nothing else mints. An id-less record with
    /// a device-given name proves nothing about which same-named session it
    /// meant, so it never kills.
    func testJournalClaimsMatchesByDaemonID() {
        XCTAssertTrue(TermioStore.journalClaims(
            record("n", daemonID: "aaaa1111"), rowID: "aaaa1111"))
        XCTAssertFalse(TermioStore.journalClaims(
            record("n", daemonID: "aaaa1111"), rowID: "bbbb2222"))
        XCTAssertTrue(
            TermioStore.journalClaims(
                record(UUID().uuidString, daemonID: nil), rowID: "bbbb2222"),
            "an id-less record for an app-authored (UUID) name still claims it")
        XCTAssertFalse(
            TermioStore.journalClaims(record("build", daemonID: nil), rowID: "bbbb2222"),
            "an id-less record for a device-given name must never kill — "
                + "identity unproven means safety over kill")
    }

    /// The local socket is per-uid, so an attached unknown on this Mac is a
    /// second install's live session — the one place attachment proves
    /// foreign ownership.
    func testAnAttachedStrangerIsLeftAloneOnThisMac() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "theirs", rowID: "cccc3333", attachedClients: 1, isLocal: true,
                journaled: nil),
            .leaveAlone)
    }

    /// On a remote device the roster is that box's whole sidebar, and
    /// attachment is read-many by design — a session the phone has open is
    /// still one of the box's own sessions, so it gets a row like any other.
    func testAnAttachedStrangerIsAdoptedOnARemoteDevice() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "phones", rowID: "cccc3333", attachedClients: 1, isLocal: false,
                journaled: nil),
            .adopt)
    }

    func testADetachedStrangerIsAdopted() {
        XCTAssertEqual(
            TermioStore.resolveExternalSession(
                name: "cli-started", rowID: "cccc3333", attachedClients: 0, isLocal: true,
                journaled: nil),
            .adopt)
    }

    func testPathContainmentIsByWholeComponents() {
        XCTAssertTrue(TermioStore.path("/code/termio", isInside: "/code/termio"))
        XCTAssertTrue(TermioStore.path("/code/termio/Sources/termio", isInside: "/code/termio"))
        XCTAssertFalse(TermioStore.path("/code/termio-worktrees/x", isInside: "/code/termio"),
                       "a sibling sharing a string prefix is not inside")
        XCTAssertFalse(TermioStore.path("/code", isInside: "/code/termio"))
        XCTAssertFalse(TermioStore.path("", isInside: "/code/termio"))
        XCTAssertFalse(TermioStore.path("/code/termio", isInside: ""))
    }
}

/// The sweep run against a real store: what one roster refresh does to rows,
/// the journal, and the tree. No daemon — the roster rows are decoded from the
/// wire shape, which is also the only way to construct them from here.
@MainActor
final class ExternalSessionSweepTests: XCTestCase {
    private func makeStore(projectPath: String = "/code/termio")
        -> (TermioStore, Workspace, Project) {
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "termio", path: projectPath,
                              branch: "main", sessions: [])
        let defaults = UserDefaults(suiteName: "sweep-\(UUID().uuidString)")
        let store = TermioStore(workspaces: [workspace], projects: [project],
                                settings: AppSettings(defaults: defaults ?? .standard))
        return (store, workspace, project)
    }

    private func information(
        name: String, id: String? = nil, cwd: String = "", attached: Int = 0
    ) throws -> Termiod.SessionInformation {
        let json = """
        {"id": "\(id ?? "\(name)-id")", "name": "\(name)", "pid": 1, "alive": true,
         "cwd": "\(cwd)", "command": "", "status": "unknown",
         "createdUnix": 0, "attachedClients": \(attached)}
        """
        return try JSONDecoder().decode(Termiod.SessionInformation.self, from: Data(json.utf8))
    }

    func testANameMatchingACurrentRowChangesNothing() throws {
        let (store, _, project) = makeStore()
        let session = Session(title: "agent", agent: .terminal)
        store.projects[0].sessions = [session]
        _ = project

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: session.id.uuidString, id: "aaaa1111")],
            from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before, "an accounted row was adopted twice")
        XCTAssertEqual(
            store.session(session.id)?.termiodDaemonID, "aaaa1111",
            "the roster answered for the row, so its daemon id must be remembered — "
                + "it is what a later close journals")
    }

    func testAJournaledNameIsNotAdopted() throws {
        let (store, _, _) = makeStore()
        // An app-authored (UUID) name, closed before anything revealed its id —
        // the shape a restored row's close leaves behind.
        let orphan = UUID().uuidString
        store.journalClosedSession(named: orphan, sshAlias: nil)

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: orphan)], from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before,
                       "this app's own orphan was adopted instead of killed")
        XCTAssertTrue(store.closedSessionJournal.contains { $0.name == orphan },
                      "the record must survive until the roster stops naming it")
    }

    func testADetachedStrangerAdoptsIntoTheProjectHoldingItsCwd() throws {
        let (store, _, project) = makeStore(projectPath: "/code/termio")

        try store.reconcileExternalSessions(
            [information(name: "cli-started", cwd: "/code/termio/Sources")],
            from: .thisMac, route: .local)

        let adopted = store.projects[0].sessions.first
        XCTAssertNotNil(adopted, "the stranger never landed in the cwd-matching project")
        XCTAssertEqual(adopted?.termiodSessionName, "cli-started",
                       "the row must keep the daemon's name to reach that exact PTY")
        XCTAssertNil(store.selectedSessionID,
                     "auto-adoption moved the selection — nobody clicked anything")
        _ = project
    }

    func testADetachedStrangerOutsideEveryProjectAdoptsAsALooseTerminal() throws {
        let (store, workspace, _) = makeStore()

        try store.reconcileExternalSessions(
            [information(name: "wanderer", cwd: "/somewhere/else")],
            from: .thisMac, route: .local)

        XCTAssertTrue(store.projects[0].sessions.isEmpty)
        let workspaceIndex = store.workspaces.firstIndex { $0.id == workspace.id }
        XCTAssertEqual(
            workspaceIndex.map { store.workspaces[$0].terminals.count }, 1,
            "the stranger belongs in the workspace's loose terminals")
    }

    func testAnAttachedStrangerGetsNoRowOnThisMac() throws {
        let (store, _, _) = makeStore()

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: "theirs", attached: 1)], from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before,
                       "a second install's live session is not ours to claim")
    }

    /// The guard is local-only: on a remote device an attached session is still
    /// one of that box's own sessions — read-many is the design — and hiding it
    /// would hide the box's work from the Mac.
    func testAnAttachedStrangerIsAdoptedOnARemoteDevice() throws {
        let (store, _, _) = makeStore()
        let device = KnownDevice(alias: "vps", deviceID: nil)

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: "phones", attached: 1)], from: device, route: .ssh("vps"))

        XCTAssertEqual(store.allSessions.count, before + 1,
                       "the box's own attached session never got a row")
        let adopted = store.allSessions.first { $0.termiodSessionName == "phones" }
        XCTAssertEqual(adopted?.termiodRemoteHost, "vps")
    }

    func testASpentJournalRecordIsDropped() throws {
        let (store, _, _) = makeStore()
        store.journalClosedSession(named: "long-dead", sshAlias: nil)

        try store.reconcileExternalSessions([], from: .thisMac, route: .local)

        XCTAssertFalse(store.closedSessionJournal.contains { $0.name == "long-dead" },
                       "a record whose name the roster no longer lists has done its job")
    }

    /// A record for another route must survive this route's sweep: the close it
    /// remembers can only be settled by the machine it happened on.
    func testAnotherRoutesRecordSurvivesThisSweep() throws {
        let (store, _, _) = makeStore()
        store.journalClosedSession(named: "remote-orphan", sshAlias: "vps")

        try store.reconcileExternalSessions([], from: .thisMac, route: .local)

        XCTAssertTrue(store.closedSessionJournal.contains { $0.name == "remote-orphan" })
    }

    /// A record's identity is `(name, sshAlias)`: adopted sessions keep
    /// device-given names, so `build` can exist on several machines at once —
    /// journaling or forgetting it on one route must not touch another's
    /// pending kill.
    func testSameNamedRecordsOnDifferentRoutesAreIndependent() {
        let (store, _, _) = makeStore()
        store.journalClosedSession(named: "build", sshAlias: "vps-a")

        store.journalClosedSession(named: "build", sshAlias: nil)
        XCTAssertTrue(
            store.closedSessionJournal.contains { $0.name == "build" && $0.sshAlias == "vps-a" },
            "a local close of \"build\" erased vps-a's pending kill")

        store.forgetClosedSession(named: "build", sshAlias: nil)
        XCTAssertTrue(
            store.closedSessionJournal.contains { $0.name == "build" && $0.sshAlias == "vps-a" },
            "a local reattach under \"build\" erased vps-a's pending kill")
        XCTAssertFalse(
            store.closedSessionJournal.contains { $0.name == "build" && $0.sshAlias == nil })
    }

    /// The close only ever promised to end the session that existed when it
    /// happened, and the daemon id is what names that session: a row under the
    /// same name with a **different** id — the kill landed, then someone ran
    /// `termiod` with the same name again before the next refresh — is a fresh
    /// stranger: adopted, and the spent record dropped rather than left to
    /// murder it on a later sweep. Its id is gone for good, so the record can
    /// never claim anything again.
    func testANameReusedAfterTheCloseIsAdoptedNotKilled() throws {
        let (store, _, _) = makeStore()
        store.journalClosedSession(named: "build", sshAlias: nil, daemonID: "aaaa1111")

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: "build", id: "bbbb2222")],
            from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before + 1,
                       "the recreated session never got a row")
        XCTAssertFalse(store.closedSessionJournal.contains { $0.name == "build" },
                       "a spent record left behind would kill the new session later")
    }

    /// A respawn-in-place reuses its name but never its daemon id, and the new
    /// id is unknown until the fresh attach or roster answers — so the respawn
    /// must clear the stale one. A close inside that window then journals an
    /// id-less record, and because the name is app-authored (a UUID) that
    /// record still claims and kills the respawned session. With the stale id
    /// left in place, the sweep would read the respawn's fresh id as
    /// legitimate reuse and adopt the very orphan the close meant to end.
    func testACloseInTheRelaunchWindowStillClaimsTheRespawn() throws {
        let (store, _, _) = makeStore()
        let session = Session(title: "agent", agent: .terminal)
        store.projects[0].sessions = [session]
        store.updateSession(session.id) { $0.termiodDaemonID = "aaaa1111" }

        store.relaunchSession(session.id)
        XCTAssertNil(store.session(session.id)?.termiodDaemonID,
                     "the old id died with the old daemon session")

        store.closeSession(session.id)
        let name = session.id.uuidString
        let recorded = store.closedSessionJournal.first { $0.name == name }
        XCTAssertNotNil(recorded, "the close was not journaled")
        XCTAssertNil(recorded?.daemonID,
                     "a stale id in the record would spare the respawned orphan")

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: name, id: "bbbb2222")], from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before,
                       "the respawned orphan was adopted instead of killed")
        XCTAssertTrue(store.closedSessionJournal.contains { $0.name == name },
                      "the record must survive until the roster stops naming the orphan")
    }

    /// The upgrade corner: an adopted row persisted by a build before
    /// `termiodDaemonID` existed decodes with no id, and closing it before the
    /// first roster answers writes an id-less record for a device-given name.
    /// Such a record proves nothing about which same-named session it meant,
    /// so it never kills — the row is resolved normally and the record dropped.
    /// A true orphan resurfacing is re-adopted, and *that* row's close
    /// journals with the id, so the miss converges.
    func testAnIDLessRecordWithADeviceGivenNameNeverKills() throws {
        let (store, _, _) = makeStore()
        store.journalClosedSession(named: "build", sshAlias: nil)

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: "build")], from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before + 1,
                       "identity unproven means safety over kill — the row gets a row")
        XCTAssertFalse(store.closedSessionJournal.contains { $0.name == "build" },
                       "a record that can never claim again must be dropped")
    }

    /// The counterpart: the same name under the **same** id is the very orphan
    /// the close named — killed, never adopted, and the record kept until the
    /// roster stops naming it (the kill just issued may still fail).
    func testTheSameIDUnderTheSameNameIsKilledNotAdopted() throws {
        let (store, _, _) = makeStore()
        store.journalClosedSession(named: "build", sshAlias: nil, daemonID: "aaaa1111")

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: "build", id: "aaaa1111")],
            from: .thisMac, route: .local)

        XCTAssertEqual(store.allSessions.count, before,
                       "this app's own orphan was adopted instead of killed")
        XCTAssertTrue(store.closedSessionJournal.contains { $0.name == "build" },
                      "the record must survive until the roster stops naming its id")
    }

    /// An alias rename must not orphan a pending kill: the record carries the
    /// machine's identity, so a close made via `prod-old` still settles when
    /// the box is reached as `prod-new`.
    func testARecordMatchesByDeviceIDUnderADifferentAlias() throws {
        let (store, _, _) = makeStore()
        store.journalClosedSession(
            named: "orphan", sshAlias: "prod-old", deviceID: "h_1", daemonID: "aaaa1111")

        let before = store.allSessions.count
        try store.reconcileExternalSessions(
            [information(name: "orphan", id: "aaaa1111")],
            from: KnownDevice(alias: "prod-new", deviceID: "h_1"), route: .ssh("prod-new"))

        XCTAssertEqual(store.allSessions.count, before,
                       "the orphan was adopted instead of matched to its pending kill")
        XCTAssertTrue(store.closedSessionJournal.contains { $0.name == "orphan" },
                      "the record must survive until the roster stops naming the orphan")
    }
}

/// The §D2 demotion through the store: the row transitions in place — status,
/// notice, identity — driven by the same foreground samples the daemon sends.
@MainActor
final class DeclaredAgentDemotionTests: XCTestCase {
    private func makeStore(with session: Session) -> TermioStore {
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "termio", path: "/code/termio",
                              branch: "main", sessions: [session])
        let defaults = UserDefaults(suiteName: "demotion-\(UUID().uuidString)")
        return TermioStore(workspaces: [workspace], projects: [project],
                           settings: AppSettings(defaults: defaults ?? .standard))
    }

    func testAWrappedAgentExitDemotesTheRowInPlace() {
        let session = Session(title: "agent", agent: .claudeCode)
        let store = makeStore(with: session)
        _ = store.setStatus(.working, for: session.id)

        store.noteDeclaredAgentForeground(["claude"], for: session.id)
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)
        XCTAssertNil(store.agentExitNotice(for: session.id), "one sample must not demote")
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)

        XCTAssertEqual(store.status(for: session.id), .idle)
        XCTAssertEqual(store.agentExitNotice(for: session.id), "Claude Code exited — shell")
        XCTAssertEqual(store.session(session.id)?.agent, .claudeCode,
                       "identity is untouched — the row never re-files (#528)")
    }

    /// The full resume sequence, including the self-heal for a `ctrl-z`d or
    /// hand-restarted agent that never fires a hook: the returning foreground
    /// clears the notice but honestly leaves the row idle (a resumed agent
    /// sitting at its prompt IS idle), and the screen-liveness streak promotes
    /// it back to working once it produces output.
    ///
    /// The streak itself is the device's — its rules and their guards are
    /// asserted in `termiod/src/session/status.rs` — so what this covers is the
    /// half that stayed here: the verdict arriving as `working` from the
    /// `streak` channel must clear the exit notice and light the spinner, on a
    /// row this app had written off as back at its shell.
    func testTheAgentComingBackClearsTheNoticeAndScreenActivityPromotes() {
        let session = Session(title: "agent", agent: .claudeCode)
        let store = makeStore(with: session)
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)
        XCTAssertNotNil(store.agentExitNotice(for: session.id), "the fixture never demoted")

        store.noteDeclaredAgentForeground(["claude"], for: session.id)

        XCTAssertNil(store.agentExitNotice(for: session.id))
        XCTAssertEqual(store.status(for: session.id), .idle,
                       "the return alone is not evidence of work — no status is invented")

        store.applyTermiodStatus(
            Termiod.StatusPayload(
                session: session.id.uuidString, status: "working", title: nil, source: "streak"),
            for: session.id)

        XCTAssertEqual(store.status(for: session.id), .working,
                       "a resumed agent producing output must light its spinner again")
        XCTAssertNil(store.agentExitNotice(for: session.id))
    }

    /// An agent that came back can finish a turn without ever passing through
    /// `working` from this side's view — its first addressed report may be
    /// `done` or `idle`. Any addressed report proves the agent alive, so every
    /// one of them must clear the stale "exited — shell" notice.
    func testANonWorkingStatusReportClearsTheNotice() {
        let session = Session(title: "agent", agent: .claudeCode)
        let store = makeStore(with: session)
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)
        store.noteDeclaredAgentForeground(["-zsh"], for: session.id)
        XCTAssertNotNil(store.agentExitNotice(for: session.id), "the fixture never demoted")

        store.applyTermiodStatus(
            Termiod.StatusPayload(session: session.id.uuidString, status: "done", title: nil),
            for: session.id)

        XCTAssertNil(store.agentExitNotice(for: session.id),
                     "a done report left the row claiming the agent exited")
    }

    /// The agent's own subprocess (`rg`, a build) holding the foreground is a
    /// working agent, not an exit — only the login shell counts as evidence.
    func testASubprocessInTheForegroundNeverDemotes() {
        let session = Session(title: "agent", agent: .claudeCode)
        let store = makeStore(with: session)
        _ = store.setStatus(.working, for: session.id)

        for _ in 0..<5 { store.noteDeclaredAgentForeground(["rg", "pattern"], for: session.id) }

        XCTAssertEqual(store.status(for: session.id), .working)
        XCTAssertNil(store.agentExitNotice(for: session.id))
    }
}
