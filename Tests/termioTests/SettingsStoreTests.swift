import XCTest

@testable import termio

/// `settings.json` is the file a user hand-edits and commits to a dotfiles repo,
/// so what it *omits* matters as much as what it stores. These cover the rule
/// that makes the omission safe: only a chosen value is written, and everything
/// else keeps resolving through the layers below.
@MainActor
final class SettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("settings.json")
        suiteName = "settings-store-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, fileURL: fileURL, domainName: suiteName)
    }

    // MARK: - The rule

    func testUntouchedSettingWritesNoFile() {
        let store = makeStore()
        defaults.register(defaults: ["appearance.fontSize": 13.0])

        XCTAssertEqual(store.double("appearance.fontSize"), 13.0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "reading a default must not create settings.json — an untouched key stays inherited")
    }

    /// The reason the file stores choices rather than a full snapshot: a user who
    /// never picked a font size follows termio's default when that default moves.
    func testChangedDefaultReachesAnUntouchedSetting() {
        defaults.register(defaults: ["appearance.fontSize": 13.0])
        XCTAssertEqual(makeStore().double("appearance.fontSize"), 13.0)

        // Ship a new default in a later version.
        defaults.register(defaults: ["appearance.fontSize": 14.0])
        XCTAssertEqual(makeStore().double("appearance.fontSize"), 14.0)
    }

    /// ...while a value the user did pick survives that same default change, even
    /// when their pick happens to equal the old default.
    func testChosenValueSurvivesADefaultChange() {
        defaults.register(defaults: ["appearance.fontSize": 13.0])
        let store = makeStore()
        store.set(13.0, forKey: "appearance.fontSize")

        defaults.register(defaults: ["appearance.fontSize": 14.0])
        XCTAssertEqual(makeStore().double("appearance.fontSize"), 13.0)
    }

    func testClearingAChoiceRestoresTheInheritedValue() {
        defaults.register(defaults: ["appearance.fontSize": 13.0])
        let store = makeStore()
        store.set(20.0, forKey: "appearance.fontSize")
        XCTAssertTrue(store.isChosen("appearance.fontSize"))

        store.set(nil, forKey: "appearance.fontSize")
        XCTAssertFalse(store.isChosen("appearance.fontSize"))
        XCTAssertEqual(makeStore().double("appearance.fontSize"), 13.0)
    }

    // MARK: - Round trip

    func testValuesRoundTripAcrossTypes() {
        let store = makeStore()
        store.set("Menlo", forKey: "appearance.fontFamily")
        store.set(15.5, forKey: "appearance.fontSize")
        store.set(12, forKey: "appearance.windowPadding")
        store.set(true, forKey: "terminal.copyOnSelect")
        store.set(["gemini", "amp"], forKey: "agents.disabled")
        store.set(["claudeCode": "claude --resume"], forKey: "agents.commandOverrides")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.string("appearance.fontFamily"), "Menlo")
        XCTAssertEqual(reloaded.double("appearance.fontSize"), 15.5)
        XCTAssertEqual(reloaded.integer("appearance.windowPadding"), 12)
        XCTAssertTrue(reloaded.bool("terminal.copyOnSelect"))
        XCTAssertEqual(reloaded.stringArray("agents.disabled"), ["gemini", "amp"])
        XCTAssertEqual(
            reloaded.stringDictionary("agents.commandOverrides"), ["claudeCode": "claude --resume"])
    }

    /// The file is hand-editable, so a key termio doesn't manage — a typo, a
    /// comment-ish marker, a key from a newer version — must survive a write.
    func testUnmanagedKeySurvivesAWrite() throws {
        try Data(#"{"appearance.fontSize": 15, "some.future.key": "keep me"}"#.utf8)
            .write(to: fileURL)

        let store = makeStore()
        store.set(16.0, forKey: "appearance.fontSize")

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
        let parsed = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(parsed["some.future.key"] as? String, "keep me")
        XCTAssertEqual(parsed["appearance.fontSize"] as? Double, 16.0)
    }

    func testMalformedFileFallsBackToInheritedValues() throws {
        try Data("{ not json".utf8).write(to: fileURL)
        defaults.register(defaults: ["appearance.fontSize": 13.0])

        // A corrupt file must not take the app's settings down with it.
        XCTAssertEqual(makeStore().double("appearance.fontSize"), 13.0)
    }

    func testRewritingTheSameValueIsANoOp() throws {
        let store = makeStore()
        store.set(15.0, forKey: "appearance.fontSize")
        let firstWrite = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        store.set(15.0, forKey: "appearance.fontSize")
        let secondWrite = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(firstWrite, secondWrite, "an unchanged value should not rewrite the file")
    }

    // MARK: - Migration

    func testMigrationCarriesOnlyManagedKeys() {
        defaults.set(17.0, forKey: "appearance.fontSize")
        defaults.set(["a-project"], forKey: "welcome.recentProjects")

        let store = makeStore()
        store.migrateIfNeeded(managing: ["appearance.fontSize"])

        XCTAssertTrue(store.isChosen("appearance.fontSize"))
        XCTAssertFalse(
            store.isChosen("welcome.recentProjects"),
            "app state must stay in UserDefaults rather than leak into the config file")
    }

    func testMigrationDoesNotRunTwice() {
        defaults.set(17.0, forKey: "appearance.fontSize")
        let store = makeStore()
        store.migrateIfNeeded(managing: ["appearance.fontSize"])

        // The user clears the value by hand; a second launch must respect that.
        store.set(nil, forKey: "appearance.fontSize")
        let relaunched = makeStore()
        relaunched.migrateIfNeeded(managing: ["appearance.fontSize"])
        XCTAssertFalse(relaunched.isChosen("appearance.fontSize"))
    }
}

/// The rewiring itself: `AppSettings`' setters must land in `settings.json`, and
/// its reads must come back from there on the next launch. Covers the seam the
/// unit tests above cannot — that every `didSet` was pointed at the file rather
/// than left writing to `UserDefaults`.
@MainActor
final class AppSettingsFileBackingTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("settings.json")
        suiteName = "app-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults, fileURL: fileURL, domainName: suiteName))
    }

    private func fileContents() throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testChangingASettingWritesItToTheFile() throws {
        let settings = makeSettings()
        settings.fontSize = 17
        settings.copyOnSelect = true
        settings.cursorStyle = .bar

        let parsed = try fileContents()
        XCTAssertEqual(parsed["appearance.fontSize"] as? Double, 17)
        XCTAssertEqual(parsed["terminal.copyOnSelect"] as? Bool, true)
        XCTAssertEqual(parsed["appearance.cursorStyle"] as? String, "bar")
    }

    func testSettingsReloadFromTheFile() {
        let settings = makeSettings()
        settings.fontSize = 19
        settings.lightThemeName = "xcode-light"

        let relaunched = makeSettings()
        XCTAssertEqual(relaunched.fontSize, 19)
        XCTAssertEqual(relaunched.lightThemeName, "xcode-light")
    }

    /// App state must not follow preferences into the file.
    func testStateStaysOutOfTheFile() throws {
        let settings = makeSettings()
        settings.fontSize = 15
        settings.noteRecentProject(name: "termio", path: "/tmp/termio")

        XCTAssertNil(try fileContents()["welcome.recentProjects"])
    }
}
