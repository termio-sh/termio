import XCTest
@testable import termio

/// The `.terminals` → `.host` lift (`TermioStore.liftingRemoteSessionsToHosts`).
/// It rewrites persisted user state on launch, so the cases that matter are the
/// destructive ones: don't lose a session, don't move a local one, don't split a
/// machine in two, and don't do anything at all on a second run.
final class RemoteHostContainerTests: XCTestCase {
    private func local(_ title: String) -> Session {
        Session(title: title, agent: .terminal)
    }

    private func ssh(_ title: String, host: String) -> Session {
        var session = Session(title: title, agent: .terminal)
        session.sshHost = host
        return session
    }

    private func termiod(_ title: String, host: String, cwd: String? = nil) -> Session {
        var session = Session(title: title, agent: .terminal)
        session.termiodRemoteHost = host
        session.termiodRemoteCwd = cwd
        return session
    }

    private func terminals(_ sessions: [Session]) -> Project {
        Project(name: "Terminals", path: NSHomeDirectory(), branch: "—",
                sessions: sessions, kind: .terminals)
    }

    /// Both remote transports leave the funnel for their machine's block; the
    /// local shell stays behind.
    func testLiftsBothRemoteTransportsOutOfTheTerminalsFunnel() {
        let result = TermioStore.liftingRemoteSessionsToHosts([
            terminals([
                local("Terminal 1"),
                ssh("SSH Shell", host: "ukvps"),
                termiod("Terminal 2", host: "ukvps", cwd: "/home/me/repo"),
            ]),
        ])

        let funnel = result.first { $0.kind == .terminals }
        XCTAssertEqual(funnel?.sessions.map(\.title), ["Terminal 1"])

        let hosts = result.filter { $0.kind == .host }
        XCTAssertEqual(hosts.count, 1, "one block per machine, not per session")
        XCTAssertEqual(hosts.first?.sshHost, "ukvps")
        XCTAssertEqual(hosts.first?.name, "ukvps")
        XCTAssertEqual(hosts.first?.sessions.count, 2)
        XCTAssertEqual(hosts.first?.path, "/home/me/repo", "adopts a recorded remote root")
    }

    /// A row auto-named for its box renumbers inside that box's block (the header
    /// already says the name); anything the user or a clone named is left alone.
    func testRenamesOnlyTheAliasAutoTitles() {
        let result = TermioStore.liftingRemoteSessionsToHosts([
            terminals([
                termiod("ukvps", host: "ukvps"),
                termiod("my-repo", host: "ukvps"),
                termiod("ukvps", host: "ukvps"),
            ]),
        ])

        XCTAssertEqual(
            result.first { $0.kind == .host }?.sessions.map(\.title),
            ["Terminal 1", "my-repo", "Terminal 2"]
        )
    }

    /// Renumbering never collides with a title already in the block.
    func testRenumberingSkipsTakenTitles() {
        let result = TermioStore.liftingRemoteSessionsToHosts([
            terminals([termiod("ukvps", host: "ukvps"), termiod("Terminal 1", host: "ukvps")]),
        ])

        let titles = result.first { $0.kind == .host }?.sessions.map(\.title) ?? []
        XCTAssertEqual(Set(titles).count, titles.count, "no duplicate row labels")
        XCTAssertTrue(titles.contains("Terminal 1"))
        XCTAssertTrue(titles.contains("Terminal 2"))
    }

    /// Two machines are two blocks — the alias is the container's identity.
    func testSeparateHostsGetSeparateContainers() {
        let result = TermioStore.liftingRemoteSessionsToHosts([
            terminals([ssh("a", host: "ukvps"), termiod("b", host: "devbox")]),
        ])

        XCTAssertEqual(
            Set(result.filter { $0.kind == .host }.compactMap(\.sshHost)),
            ["ukvps", "devbox"]
        )
    }

    /// A half-migrated file (someone already has a `ukvps` block) merges into the
    /// existing container instead of growing a duplicate.
    func testMergesIntoAnExistingHostContainer() {
        let existing = Project(name: "ukvps", path: "~", branch: "—",
                               sessions: [termiod("Terminal 1", host: "ukvps")],
                               kind: .host, sshHost: "ukvps")
        let result = TermioStore.liftingRemoteSessionsToHosts([
            existing,
            terminals([ssh("SSH Shell", host: "ukvps")]),
        ])

        let hosts = result.filter { $0.kind == .host }
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.sessions.count, 2)
    }

    /// Running twice changes nothing — the funnel has no remote sessions left.
    func testIsIdempotent() {
        let once = TermioStore.liftingRemoteSessionsToHosts([
            terminals([local("Terminal 1"), ssh("SSH Shell", host: "ukvps")]),
        ])
        let twice = TermioStore.liftingRemoteSessionsToHosts(once)

        XCTAssertEqual(once.map(\.id), twice.map(\.id))
        XCTAssertEqual(once.flatMap { $0.sessions.map(\.id) },
                       twice.flatMap { $0.sessions.map(\.id) })
    }

    /// A remote terminal opened from a project row belongs to that project — the
    /// lift drains the loose funnel only.
    func testLeavesProjectOwnedRemoteSessionsAlone() {
        let project = Project(name: "termio", path: "/code/termio", branch: "main",
                              sessions: [termiod("termio · ukvps", host: "ukvps")],
                              kind: .folder)
        let result = TermioStore.liftingRemoteSessionsToHosts([project])

        XCTAssertTrue(result.filter { $0.kind == .host }.isEmpty)
        XCTAssertEqual(result.first?.sessions.count, 1)
    }

    /// An emptied funnel is dropped rather than persisting as a hidden section.
    func testDropsAFunnelEmptiedByTheLift() {
        let result = TermioStore.liftingRemoteSessionsToHosts([
            terminals([ssh("SSH Shell", host: "ukvps")]),
        ])

        XCTAssertTrue(result.filter { $0.kind == .terminals }.isEmpty)
        XCTAssertEqual(result.count, 1)
    }

    /// No session may be lost in the rewrite, whatever the mix.
    func testPreservesEverySession() {
        let input = [
            terminals([local("l1"), ssh("s1", host: "a"), termiod("t1", host: "b"), local("l2")]),
            Project(name: "termio", path: "/code/termio", branch: "main",
                    sessions: [local("p1")], kind: .folder),
        ]
        let result = TermioStore.liftingRemoteSessionsToHosts(input)

        XCTAssertEqual(
            Set(result.flatMap { $0.sessions.map(\.id) }),
            Set(input.flatMap { $0.sessions.map(\.id) })
        )
    }
}
