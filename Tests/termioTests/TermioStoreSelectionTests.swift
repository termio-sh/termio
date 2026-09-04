import XCTest

@testable import termio

/// Selecting a session is the store's busiest write: every sidebar click, every
/// deep link and every ⌘⇧] lands in `selectedSessionID`'s `didSet`, which then
/// acknowledges the arriving session's "your turn" cue. These cover that
/// acknowledgement — the half of it a window isn't needed to see.
///
/// The path was untestable until `AppChannel.isTermioAppBundle` learned to tell
/// termio's own bundle from any bundle at all: under `xctest` the old predicate
/// said yes, `markSeen` reached `UNUserNotificationCenter`, and the whole run
/// died on `SIGABRT`.
@MainActor
final class TermioStoreSelectionTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "store-selection-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// Both settings layers are handed scratch storage: a test must not rewrite
    /// the settings file or the defaults domain of the termio the user is running.
    private func makeStore(sessions: [Session]) -> TermioStore {
        var workspace = Workspace(name: "Default")
        workspace.terminals = sessions
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
        return TermioStore(workspaces: [workspace], settings: settings)
    }

    /// A finished agent's dot is dismissed by looking at it: "ready for you" has
    /// been read the moment its session is on screen.
    func testSelectingAFinishedSessionClearsItsCue() {
        let watched = Session(title: "Terminal 1", agent: .terminal)
        let finished = Session(title: "Terminal 2", agent: .claudeCode)
        let store = makeStore(sessions: [watched, finished])
        store.setStatus(.done, for: finished.id)

        store.selectedSessionID = finished.id

        XCTAssertEqual(store.status(for: finished.id), .idle)
    }

    /// A blocked agent's dot is not: reading a permission prompt is not answering
    /// it, so only the agent proceeding clears one.
    func testSelectingABlockedSessionKeepsItsCue() {
        let watched = Session(title: "Terminal 1", agent: .terminal)
        let blocked = Session(title: "Terminal 2", agent: .claudeCode)
        let store = makeStore(sessions: [watched, blocked])
        store.setStatus(.needsAttention, for: blocked.id)
        store.blockingAttention.insert(blocked.id)

        store.selectedSessionID = blocked.id

        XCTAssertEqual(store.status(for: blocked.id), .needsAttention)
    }

    /// Which sessions have a screen in front of them, which is what a surface
    /// declares to the daemon as its viewport when it is made. Surfaces are
    /// made lazily on first render, so this is usually "yes" — but the phone
    /// and `termio sessions send` both make one for a session no pane is
    /// showing, and that one has no viewport to declare
    /// (`docs/design/20260901-pty-size-is-not-the-write-token.md` §5.1).
    func testOnlyTheSessionsAPaneIsShowingHaveAScreen() {
        let shown = Session(title: "Terminal 1")
        let grouped = Session(title: "Terminal 2")
        let elsewhere = Session(title: "Terminal 3")
        let store = makeStore(sessions: [shown, grouped, elsewhere])
        store.selectedSessionID = shown.id

        XCTAssertTrue(store.isPaneOnScreen(shown.id))
        XCTAssertFalse(store.isPaneOnScreen(elsewhere.id))

        // Grouping puts both halves on screen, selected or not.
        store.dropSession(grouped.id, onto: shown.id, zone: .right)
        XCTAssertTrue(store.isPaneOnScreen(shown.id))
        XCTAssertTrue(store.isPaneOnScreen(grouped.id))
        XCTAssertFalse(store.isPaneOnScreen(elsewhere.id))

        // Zooming one takes the others off it — they keep their frames and are
        // drawn at zero opacity, which is not a screen anyone is looking at.
        store.selectedSessionID = grouped.id
        store.isPaneZoomed = true
        XCTAssertTrue(store.isPaneOnScreen(grouped.id))
        XCTAssertFalse(store.isPaneOnScreen(shown.id))
    }
}
