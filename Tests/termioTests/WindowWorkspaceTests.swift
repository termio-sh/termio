import AppKit
import XCTest

@testable import termio

/// Each main window shows its own workspace. The store's current workspace is the
/// active window's, so a switch in one window must leave the other where it was.
@MainActor
final class WindowWorkspaceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var windows: [MainWindowController] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("window-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "window-workspace-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        for controller in windows { controller.window.close() }
        windows = []
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
    }

    private func makeWorkspace(_ name: String) -> (Workspace, Session) {
        let session = Session(title: name, agent: .terminal)
        var workspace = Workspace(name: name)
        workspace.terminals = [session]
        return (workspace, session)
    }

    /// A parent window is passed so no window claims the first window's saved frame.
    private func makeWindow(_ store: TermioStore, _ settings: AppSettings, selecting id: Session.ID?) -> MainWindowController {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let controller = MainWindowController(store: store, settings: settings, selecting: id, cascadingFrom: parent)
        windows.append(controller)
        return controller
    }

    func testASwitchInTheActiveWindowLeavesTheOtherWindowWhereItWas() {
        let (work, workSession) = makeWorkspace("Work")
        let (home, homeSession) = makeWorkspace("Home")
        let (lab, _) = makeWorkspace("Lab")
        let settings = makeSettings()
        let store = TermioStore(workspaces: [work, home, lab], settings: settings)
        let first = makeWindow(store, settings, selecting: workSession.id)
        let second = makeWindow(store, settings, selecting: homeSession.id)

        second.activate()
        XCTAssertEqual(store.currentWorkspaceID, home.id)
        XCTAssertEqual(first.context.workspaceID, work.id)

        store.currentWorkspaceID = lab.id
        XCTAssertEqual(second.context.workspaceID, lab.id)
        XCTAssertEqual(first.context.workspaceID, work.id)
    }

    func testActivatingAWindowMakesItsWorkspaceCurrent() {
        let (work, workSession) = makeWorkspace("Work")
        let (home, homeSession) = makeWorkspace("Home")
        let settings = makeSettings()
        let store = TermioStore(workspaces: [work, home], settings: settings)
        let first = makeWindow(store, settings, selecting: workSession.id)
        let second = makeWindow(store, settings, selecting: homeSession.id)

        second.activate()
        first.activate()

        XCTAssertEqual(store.currentWorkspaceID, work.id)
        XCTAssertEqual(store.selectedSessionID, workSession.id)
        XCTAssertEqual(second.context.workspaceID, home.id)
        XCTAssertEqual(second.context.selectedSessionID, homeSession.id)
    }

    /// The switch settles its selection a turn later. A window activated in that turn
    /// keeps its own selection, and the window that was left lands in its new workspace.
    func testASwitchStillSettlingStaysInTheWindowThatStartedIt() async {
        let (work, workSession) = makeWorkspace("Work")
        let (home, homeSession) = makeWorkspace("Home")
        let (lab, labSession) = makeWorkspace("Lab")
        let settings = makeSettings()
        let store = TermioStore(workspaces: [work, home, lab], settings: settings)
        let first = makeWindow(store, settings, selecting: workSession.id)
        let second = makeWindow(store, settings, selecting: homeSession.id)

        first.activate()
        store.switchToWorkspace(lab.id)
        second.activate()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.currentWorkspaceID, home.id)
        XCTAssertEqual(store.selectedSessionID, homeSession.id)
        XCTAssertEqual(first.context.workspaceID, lab.id)
        XCTAssertEqual(first.context.selectedSessionID, labSession.id)
    }

    func testASwitchOutOfAnEmptyWorkspaceStillLandsOnARow() {
        let empty = Workspace(name: "Empty")
        let (home, homeSession) = makeWorkspace("Home")
        let (lab, labSession) = makeWorkspace("Lab")
        let settings = makeSettings()
        let store = TermioStore(workspaces: [empty, home, lab], settings: settings)
        let first = makeWindow(store, settings, selecting: nil)
        let second = makeWindow(store, settings, selecting: homeSession.id)

        first.activate()
        store.switchToWorkspace(lab.id)
        second.activate()

        XCTAssertEqual(first.context.workspaceID, lab.id)
        XCTAssertEqual(first.context.selectedSessionID, labSession.id)
    }

    func testAnInactiveWindowWhoseWorkspaceIsDeletedStopsFollowingTheActiveOne() {
        let (work, workSession) = makeWorkspace("Work")
        let (home, homeSession) = makeWorkspace("Home")
        let (lab, _) = makeWorkspace("Lab")
        let settings = makeSettings()
        let store = TermioStore(workspaces: [lab, work, home], settings: settings)
        let first = makeWindow(store, settings, selecting: workSession.id)
        let second = makeWindow(store, settings, selecting: homeSession.id)

        first.activate()
        second.activate()
        store.removeWorkspace(work.id)

        XCTAssertEqual(first.context.workspaceID, lab.id)
        XCTAssertEqual(store.currentWorkspaceID, home.id)
    }

    /// No session to follow: the window's own workspace is what brings it back.
    func testAWindowOnAnEmptyWorkspaceKeepsIt() {
        let (work, workSession) = makeWorkspace("Work")
        let empty = Workspace(name: "Empty")
        let settings = makeSettings()
        let store = TermioStore(workspaces: [work, empty], settings: settings)
        let first = makeWindow(store, settings, selecting: workSession.id)
        let second = makeWindow(store, settings, selecting: nil)

        second.activate()
        store.currentWorkspaceID = empty.id
        store.selectedSessionID = nil
        first.activate()
        XCTAssertEqual(store.currentWorkspaceID, work.id)

        second.activate()
        XCTAssertEqual(store.currentWorkspaceID, empty.id)
        XCTAssertNil(store.selectedSessionID)
    }
}
