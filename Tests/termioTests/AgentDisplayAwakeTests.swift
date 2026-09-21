import AppKit
import IOKit.pwr_mgt
import XCTest
import TermioShared
@testable import termio

@MainActor
final class AgentDisplayAwakeTests: XCTestCase {
    private func makeStore() throws -> (TermioStore, Session, Session) {
        _ = NSApplication.shared
        let workspace = Workspace(name: "Display awake tests")
        let agent = Session(title: "Agent", agent: .claudeCode)
        let terminal = Session(title: "Remote agent", agent: .terminal)
        let project = Project(workspaceID: workspace.id, name: "Test", path: "/tmp",
                              branch: "main", sessions: [agent, terminal])
        let suiteName = "display-awake-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults, settingsStore: SettingsStore(
            defaults: defaults, fileURL: directory.appendingPathComponent("settings.json"),
            domainName: suiteName))
        let store = TermioStore(workspaces: [workspace], projects: [project], settings: settings)
        for session in [agent, terminal] {
            store.termiodLinks[session.id] = TermiodSessionLink(
                sessionName: session.id.uuidString,
                specification: Termiod.CreateSpecification(
                    cwd: "/tmp", argv: [], env: [], rows: 24, cols: 80),
                rows: 24, cols: 80)
        }
        return (store, agent, terminal)
    }

    private func report(_ status: String, for id: Session.ID, in store: TermioStore) {
        store.applyTermiodStatus(Termiod.StatusPayload(session: "test", status: status, title: nil), for: id)
    }

    func testDefaultOffAndOnlyWorkingHoldsOneAssertion() throws {
        let (store, agent, terminal) = try makeStore()
        var created = 0
        var released: [IOPMAssertionID] = []
        let controller = AgentDisplayAwakeController(store: store, createAssertion: {
            created += 1
            return IOPMAssertionID(created)
        }, releaseAssertion: { released.append($0); return true })
        defer { controller.stop() }

        XCTAssertFalse(store.settings.keepDisplayAwakeWhileWorking)
        report("working", for: agent.id, in: store)
        controller.refresh()
        XCTAssertEqual(created, 0)
        store.settings.keepDisplayAwakeWhileWorking = true
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(created, 1)

        // Waiting in another session must not mask the working session, unlike aggregateStatus.
        report("needs_you", for: terminal.id, in: store)
        controller.refresh()
        XCTAssertTrue(released.isEmpty)
        for status in ["needs_you", "done", "idle", "failed", "unknown"] {
            report(status, for: agent.id, in: store)
            controller.refresh()
            XCTAssertEqual(released, [1])
        }

        // A terminal-shaped remote session can report agent activity before identity catches up.
        report("working", for: terminal.id, in: store)
        controller.refresh()
        XCTAssertEqual(created, 2)
        report("working", for: agent.id, in: store)
        controller.refresh()
        XCTAssertEqual(created, 2)
        report("done", for: terminal.id, in: store)
        controller.refresh()
        XCTAssertEqual(released, [1])
        store.settings.keepDisplayAwakeWhileWorking = false
        controller.refresh()
        XCTAssertEqual(released, [1, 2])
    }

    func testDisconnectExitAndStopReleaseStaleWorkingState() throws {
        let (store, agent, _) = try makeStore()
        store.settings.keepDisplayAwakeWhileWorking = true
        report("working", for: agent.id, in: store)
        var created = 0
        var released = 0
        let controller = AgentDisplayAwakeController(store: store, createAssertion: {
            created += 1; return IOPMAssertionID(created)
        }, releaseAssertion: { _ in released += 1; return true })
        defer { controller.stop() }
        XCTAssertEqual(created, 1)
        store.applyTermiodConnectionLost(for: agent.id, attempts: 1, surface: nil)
        controller.refresh()
        XCTAssertEqual(released, 1)
        store.applyTermiodReattached(for: agent.id)
        controller.refresh()
        XCTAssertEqual(created, 1)
        report("working", for: agent.id, in: store)
        controller.refresh()
        XCTAssertEqual(created, 2)
        store.termiodLinks[agent.id] = nil
        controller.refresh()
        XCTAssertEqual(released, 2)
        controller.stop()
        controller.refresh()
        XCTAssertEqual(created, 2)
    }

    func testPublisherUpdatesAcquireAndReleaseWithoutManualRefresh() async throws {
        let (store, agent, _) = try makeStore()
        let acquired = expectation(description: "Working acquires assertion")
        let released = expectation(description: "Disconnect releases assertion")
        let controller = AgentDisplayAwakeController(store: store, createAssertion: {
            acquired.fulfill(); return 1
        }, releaseAssertion: { _ in released.fulfill(); return true })
        defer { controller.stop() }
        store.settings.keepDisplayAwakeWhileWorking = true
        report("working", for: agent.id, in: store)
        await fulfillment(of: [acquired], timeout: 2)
        store.applyTermiodConnectionLost(for: agent.id, attempts: 1, surface: nil)
        await fulfillment(of: [released], timeout: 2)
    }

    func testDisplayPolicyDoesNotFollowViewerDependentStatusDots() throws {
        let (store, agent, _) = try makeStore()
        store.settings.keepDisplayAwakeWhileWorking = true
        var released = 0
        let controller = AgentDisplayAwakeController(store: store, createAssertion: { 1 },
                                                     releaseAssertion: { _ in released += 1; return true })
        defer { controller.stop() }
        report("working", for: agent.id, in: store)
        controller.refresh()
        report("needs_you", for: agent.id, in: store)
        // Selection may leave or alter the presentation status; the daemon's state must win.
        store.setStatus(.working, for: agent.id)
        controller.refresh()
        XCTAssertEqual(released, 1)
    }

    func testNativeDisplayAssertionIsAcquiredAndReleased() throws {
        let (store, agent, _) = try makeStore()
        store.settings.keepDisplayAwakeWhileWorking = true
        let controller = AgentDisplayAwakeController(store: store)
        defer { controller.stop() }

        func displayAssertionCount() throws -> Int {
            var assertions: Unmanaged<CFDictionary>?
            XCTAssertEqual(IOPMCopyAssertionsByProcess(&assertions), kIOReturnSuccess)
            let dictionary = try XCTUnwrap(assertions).takeRetainedValue() as NSDictionary
            let current = dictionary[NSNumber(value: ProcessInfo.processInfo.processIdentifier)]
                as? [[String: Any]] ?? []
            return current.filter {
                $0[kIOPMAssertionNameKey as String] as? String == "Termio agent is working"
                    && $0[kIOPMAssertionTypeKey as String] as? String == "PreventUserIdleDisplaySleep"
            }.count
        }

        XCTAssertEqual(try displayAssertionCount(), 0)
        report("working", for: agent.id, in: store)
        controller.refresh()
        XCTAssertEqual(try displayAssertionCount(), 1)
        report("done", for: agent.id, in: store)
        controller.refresh()
        XCTAssertEqual(try displayAssertionCount(), 0)
    }

    func testFailedAcquisitionRetriesAndShutdownReleases() throws {
        let (store, agent, _) = try makeStore()
        store.settings.keepDisplayAwakeWhileWorking = true
        report("working", for: agent.id, in: store)
        var attempts = 0
        var releases = 0
        let controller = AgentDisplayAwakeController(store: store, createAssertion: {
            attempts += 1
            return attempts == 1 ? nil : 42
        }, releaseAssertion: { _ in releases += 1; return true })
        XCTAssertEqual(attempts, 1)
        controller.refresh()
        XCTAssertEqual(attempts, 2)
        controller.stop()
        controller.stop()
        controller.refresh()
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(attempts, 2)
    }
}
