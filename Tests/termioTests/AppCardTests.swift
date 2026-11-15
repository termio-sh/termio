import XCTest

@testable import termio

/// An app card is a session with a pane and no terminal. These cover what the store
/// promises about one: where it sits, which card's pane is live, which terminal it reads
/// and types for, and that nothing ever starts a shell behind it.
@MainActor
final class AppCardTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "app-card-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

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

    func testACardOpensBesideItsTerminalAndLeavesTheSelection() throws {
        let terminal = Session(title: "Terminal 1")
        let store = makeStore(sessions: [terminal])
        store.selectedSessionID = terminal.id

        let card = try XCTUnwrap(store.addAppCard(.files, beside: terminal.id, takeFocus: false))

        XCTAssertEqual(store.session(card)?.app, .files)
        XCTAssertEqual(store.splitGroups.first?.leafIDs, [terminal.id, card])
        XCTAssertEqual(store.selectedSessionID, terminal.id)
        XCTAssertEqual(store.liveAppID, card)
        XCTAssertEqual(store.displayTitle(for: try XCTUnwrap(store.session(card))), InspectorTab.files.title)
    }

    /// The card beside a terminal stays live while the terminal has the keyboard, and
    /// stands down when the selection leaves the group.
    func testTheLiveCardFollowsTheSelectedGroup() throws {
        let terminal = Session(title: "Terminal 1")
        let other = Session(title: "Terminal 2")
        let store = makeStore(sessions: [terminal, other])
        store.selectedSessionID = terminal.id
        let card = try XCTUnwrap(store.addAppCard(.changes, beside: terminal.id, takeFocus: false))

        store.selectedSessionID = other.id
        XCTAssertNil(store.liveAppID)
        XCTAssertFalse(store.inspectorVisible)

        store.selectedSessionID = terminal.id
        XCTAssertEqual(store.liveAppID, card)
        XCTAssertEqual(store.inspectorTab, .changes)
    }

    /// With two cards beside one terminal, the one last selected stays live when the
    /// selection returns to the terminal.
    func testSelectingATerminalKeepsTheCardLastLive() throws {
        let terminal = Session(title: "Terminal 1")
        let store = makeStore(sessions: [terminal])
        store.selectedSessionID = terminal.id
        let files = try XCTUnwrap(store.addAppCard(.files, beside: terminal.id, takeFocus: false))
        let changes = try XCTUnwrap(store.addAppCard(.changes, beside: terminal.id, takeFocus: false))

        store.selectedSessionID = files
        XCTAssertEqual(store.liveAppID, files)
        XCTAssertEqual(store.inspectorTab, .files)

        store.selectedSessionID = terminal.id
        XCTAssertEqual(store.liveAppID, files)

        store.selectedSessionID = changes
        XCTAssertEqual(store.liveAppID, changes)
        XCTAssertEqual(store.inspectorTab, .changes)
    }

    func testShowingAnAppTwiceOpensOneCard() {
        let terminal = Session(title: "Terminal 1")
        let store = makeStore(sessions: [terminal])
        store.selectedSessionID = terminal.id

        store.showApp(.files)
        store.showApp(.files)

        XCTAssertEqual(store.splitMembers(of: terminal.id).count, 2)
        XCTAssertEqual(store.selectedSessionID, terminal.id)
    }

    /// Each card shows one pane. Asking for another pane is asking for another card,
    /// never a change to the one on screen.
    func testAskingForAnotherPaneOpensAnotherCard() throws {
        let terminal = Session(title: "Terminal 1")
        let store = makeStore(sessions: [terminal])
        store.selectedSessionID = terminal.id
        store.showApp(.changes)
        let changes = try XCTUnwrap(store.liveAppID)

        store.inspectorTab = .files

        let live = try XCTUnwrap(store.liveAppID)
        XCTAssertNotEqual(live, changes)
        XCTAssertEqual(store.session(live)?.app, .files)
        XCTAssertEqual(store.session(changes)?.app, .changes)
        XCTAssertEqual(store.splitMembers(of: terminal.id).count, 3)
    }

    /// A card reads and types for the terminal beside it, and for no one when alone.
    func testACardAnswersForTheTerminalBesideIt() throws {
        let terminal = Session(title: "Terminal 1")
        let store = makeStore(sessions: [terminal])
        store.selectedSessionID = terminal.id
        let card = try XCTUnwrap(store.addAppCard(.files, beside: terminal.id))

        XCTAssertEqual(store.selectedSessionID, card)
        XCTAssertEqual(store.inspectorSubjectID, terminal.id)
        XCTAssertEqual(store.promptSessionID, terminal.id)

        store.detachFromSplit(card)
        XCTAssertEqual(store.inspectorSubjectID, card)
        XCTAssertNil(store.promptSessionID)
    }

    /// Nothing may ask for a card's surface: that would start a shell behind it.
    func testTypingAtACardStartsNoTerminal() throws {
        let terminal = Session(title: "Terminal 1")
        let store = makeStore(sessions: [terminal])
        let card = try XCTUnwrap(store.addAppCard(.files, beside: terminal.id))
        let session = try XCTUnwrap(store.session(card))

        XCTAssertFalse(store.typeAtPrompt("ls\n", in: session))
        XCTAssertNil(store.surfaces[card])
    }

    func testClosingACardLeavesItsTerminal() throws {
        let terminal = Session(title: "Terminal 1")
        let store = makeStore(sessions: [terminal])
        store.selectedSessionID = terminal.id
        let card = try XCTUnwrap(store.addAppCard(.files, beside: terminal.id, takeFocus: false))

        store.closeSession(card)

        XCTAssertNil(store.session(card))
        XCTAssertNotNil(store.session(terminal.id))
        XCTAssertTrue(store.splitGroups.isEmpty)
        XCTAssertNil(store.liveAppID)
        XCTAssertEqual(store.selectedSessionID, terminal.id)
    }

    func testACardSurvivesEncoding() throws {
        var card = Session(title: "Files")
        card.app = .files

        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(card))

        XCTAssertEqual(decoded.app, .files)
        XCTAssertNil(decoded.givenTitle)
    }

    /// A pane this build does not know costs the card its pane, not the state file: one
    /// thrown decode there loses every project.
    func testAnUnknownPaneDecodesAsATerminal() throws {
        var card = Session(title: "Files")
        card.app = .files
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        object["app"] = "a-pane-from-a-later-build"

        let decoded = try JSONDecoder().decode(
            Session.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(decoded.app)
    }
}
