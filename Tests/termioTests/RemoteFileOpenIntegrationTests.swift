import XCTest
import TermioShared
@testable import termio

/// Opening a device's file, against a real daemon.
///
/// Opt-in on the same terms as `TermiodFilesIntegrationTests`: point
/// `TERMIO_TERMIOD_TEST_BIN` at a built `termiod` and it runs, otherwise it
/// skips. It is the whole path — click, placeholder, read, present — because the
/// interesting claims are about *when* things are on screen, and only a real
/// round trip has a "before it answers" to look at.
@MainActor
final class RemoteFileOpenIntegrationTests: XCTestCase {
    private var daemon: Process?
    private var directory: URL!
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: TermioStore!

    private var provider: DeviceFileProvider {
        DeviceFileProvider(route: .local, root: root.path)
    }

    override func setUp() async throws {
        try await super.setUp()
        let binary = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(binary.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")

        // Short socket directory name: `sun_path` is capped at 104 bytes.
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rfo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)

        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["TERMIOD_SOCK": socket]) { _, new in new }
        serve.standardOutput = FileHandle.nullDevice
        serve.standardError = FileHandle.nullDevice
        try serve.run()
        daemon = serve
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            usleep(50_000)
        }

        root = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub/deep", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("first\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("x\n".utf8).write(to: root.appendingPathComponent("sub/b.txt"))
        try Data("y\n".utf8).write(to: root.appendingPathComponent("sub/deep/c.txt"))

        suiteName = "remote-open-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
        store = TermioStore(workspaces: [Workspace(name: "Default")], settings: settings)
    }

    override func tearDown() async throws {
        store?.openFileURL = nil
        store = nil
        RemoteFileContentCache.clear()
        // The pool is process-wide, so a channel left open here would be handed
        // to the next test — pointed at a daemon this one is about to kill.
        Termiod.ControlPool.closeAll()
        daemon?.terminate()
        daemon?.waitUntilExit()
        defaults?.removePersistentDomain(forName: suiteName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        unsetenv("TERMIOD_SOCK")
        try await super.tearDown()
    }

    private var filePath: String { root.appendingPathComponent("a.txt").path }

    private func openedText() -> String? {
        guard let url = store.openFileURL, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Polls the main actor until `condition` holds. The thing under test is an
    /// async round trip, and every assertion here is about what is true before
    /// or after it lands.
    private func settle(
        _ description: String, within seconds: Double = 10,
        until condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The fix this exists for: the click puts the file's chrome on screen before
    /// the device has said anything. Until it did, a remote open spent its whole
    /// round trip showing the previous file — a click with no answer.
    func testTheOverlayIsUpBeforeTheDeviceAnswers() async throws {
        store.openRemoteFile(
            path: filePath, name: "a.txt", provider: provider, host: "test-box")

        XCTAssertEqual(store.openingRemoteFile?.name, "a.txt", "answered in the same turn")
        XCTAssertEqual(store.openingRemoteFile?.host, "test-box")
        XCTAssertNil(store.openingRemoteFile?.failure)
        XCTAssertNil(store.openFileURL, "the bytes cannot possibly be here yet")
        XCTAssertTrue(store.isDetailPresented, "and the overlay counts as presented")

        try await settle("the file to land") { store.openFileURL != nil }

        XCTAssertNil(store.openingRemoteFile, "the editor takes the placeholder's place")
        XCTAssertEqual(openedText(), "first\n")
        XCTAssertEqual(store.openFileDisplayName, "a.txt")
        XCTAssertEqual(store.openFileRemote?.path, filePath)
        XCTAssertEqual(store.openFileRemote?.host, "test-box")
        XCTAssertFalse(store.openFileReadOnly, "a file with an origin can be saved back")
    }

    /// A file read once opens from memory the second time — no placeholder at
    /// all, because there is nothing to wait for.
    func testReopeningAFileIsInstant() async throws {
        store.openRemoteFile(
            path: filePath, name: "a.txt", provider: provider, host: "test-box")
        try await settle("the first read") { store.openFileURL != nil }
        store.openFileURL = nil

        store.openRemoteFile(
            path: filePath, name: "a.txt", provider: provider, host: "test-box")

        XCTAssertNotNil(store.openFileURL, "shown in the same turn as the click")
        XCTAssertNil(store.openingRemoteFile)
        XCTAssertEqual(openedText(), "first\n")
    }

    /// And is still checked. Agents rewrite files constantly, so what the cache
    /// removes is the wait, never the read: the stale copy goes up at once and
    /// the device's answer replaces it.
    func testAStaleCopyIsShownAtOnceAndThenCorrected() async throws {
        store.openRemoteFile(
            path: filePath, name: "a.txt", provider: provider, host: "test-box")
        try await settle("the first read") { store.openFileURL != nil }
        store.openFileURL = nil
        try Data("second\n".utf8).write(to: root.appendingPathComponent("a.txt"))

        store.openRemoteFile(
            path: filePath, name: "a.txt", provider: provider, host: "test-box")
        XCTAssertEqual(openedText(), "first\n", "the copy in hand, immediately")

        try await settle("the device to correct it") { openedText() == "second\n" }
        XCTAssertNil(store.openingRemoteFile)
    }

    /// Except into a buffer somebody is typing in. The revalidation rebuilds the
    /// editor, so a swap under an unsaved edit would be the app throwing away
    /// what the user just wrote.
    func testAnEditedBufferIsNeverReplacedUnderTheUser() async throws {
        store.openRemoteFile(
            path: filePath, name: "a.txt", provider: provider, host: "test-box")
        try await settle("the first read") { store.openFileURL != nil }
        store.openFileURL = nil
        try Data("second\n".utf8).write(to: root.appendingPathComponent("a.txt"))

        store.openRemoteFile(
            path: filePath, name: "a.txt", provider: provider, host: "test-box")
        let staged = store.openFileURL
        // The editor reports this on the keystroke itself, well before its
        // debounced write — which is the point: the bytes on disk still look
        // untouched at this moment.
        store.openFileDirty = true

        try await settle("the read to land") {
            RemoteFileContentCache.entry(for: RemoteFileContentCache.Key(
                route: .local, root: root.path, path: filePath))?.mtime ?? 0 > 0
                && openedText() != nil
        }
        // Long enough that a swap would have happened if one were coming.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(store.openFileURL, staged, "the same buffer is still open")
        XCTAssertEqual(openedText(), "first\n", "with what was in it")
    }

    /// A file that cannot be read says so in the overlay the click opened, rather
    /// than in a modal the click has to be dismissed out of — and rather than
    /// nowhere, which is what an overlay that quietly vanished would be.
    func testAFailedReadIsReportedInTheOverlay() async throws {
        store.openRemoteFile(
            path: root.appendingPathComponent("missing.txt").path, name: "missing.txt",
            provider: provider, host: "test-box")

        try await settle("the refusal") { store.openingRemoteFile?.failure != nil }

        XCTAssertNil(store.openFileURL)
        XCTAssertEqual(store.openingRemoteFile?.name, "missing.txt")
        XCTAssertTrue(store.isDetailPresented, "the click's answer stays on screen")
    }

    /// A second click while the first file is still crossing the network wins,
    /// however slow the loser turns out to be.
    func testTheLatestClickIsTheOneThatOpens() async throws {
        try Data("other\n".utf8).write(to: root.appendingPathComponent("b.txt"))

        store.openRemoteFile(
            path: filePath, name: "a.txt", provider: provider, host: "test-box")
        store.openRemoteFile(
            path: root.appendingPathComponent("b.txt").path, name: "b.txt",
            provider: provider, host: "test-box")

        XCTAssertEqual(store.openingRemoteFile?.name, "b.txt")
        try await settle("the second file") { store.openFileURL != nil }
        XCTAssertEqual(openedText(), "other\n")
        XCTAssertEqual(store.openFileDisplayName, "b.txt")
    }

    /// The tree and the search open through one path, so a hit's line survives
    /// into the editor the same way it always did.
    func testASearchHitOpensAtItsLine() async throws {
        store.openRemoteFile(
            path: filePath, name: "a.txt", provider: provider, host: "test-box", at: 3)

        try await settle("the file") { store.openFileURL != nil }
        XCTAssertEqual(store.openFileLine, 3)
    }

    // MARK: - The tree

    private func tree() -> DeviceFileTreeModel {
        DeviceFileTreeModel(
            checkout: Checkout(device: .thisMac, root: root.path), root: root.path)
    }

    private var subPath: String { root.appendingPathComponent("sub").path }

    /// Expanding a folder used to be a round trip the user watched. The folders
    /// on screen are the ones about to be clicked, so they are asked for while
    /// nobody is waiting — and the click that follows opens from what came back,
    /// in the same turn it happened.
    func testAFolderOpensFromWhatWasFetchedAheadOfTheClick() async throws {
        let tree = tree()
        tree.refresh()
        try await settle("the root listing") { !tree.rootNodes.isEmpty }
        try await settle("the folders under it to be fetched ahead") {
            tree.prefetchedPaths().contains(subPath)
        }

        // The first touch of `children` is the expand. It must answer with rows,
        // not with an empty folder and a promise.
        let node = try XCTUnwrap(tree.node(at: subPath))
        XCTAssertEqual(node.children?.map(\.name), ["deep", "b.txt"])
        XCTAssertFalse(node.isLoading, "nothing to wait for, so nothing to say")
        XCTAssertTrue(tree.loadedDirectories().contains(subPath))
        XCTAssertFalse(tree.prefetchedPaths().contains(subPath), "the guess was spent")
    }

    /// A guess is shown, never trusted: the folder is asked for again as it
    /// opens, so one that changed since is right a round trip later instead of
    /// staying wrong until the next app focus.
    func testAnOpenedFolderIsStillAskedForAgain() async throws {
        let tree = tree()
        tree.refresh()
        try await settle("the root listing") { !tree.rootNodes.isEmpty }
        try await settle("the folders under it to be fetched ahead") {
            tree.prefetchedPaths().contains(subPath)
        }
        try Data("z\n".utf8).write(to: root.appendingPathComponent("sub/new.txt"))

        let node = try XCTUnwrap(tree.node(at: subPath))
        XCTAssertEqual(node.children?.map(\.name), ["deep", "b.txt"], "the guess, as it stood")

        try await settle("the device's own answer") {
            node.children?.map(\.name) == ["deep", "b.txt", "new.txt"]
        }
    }

    /// And opening it fetches the level below, so walking down a path is one
    /// wait at the top rather than one at every step.
    func testOpeningAFolderFetchesTheLevelBelowIt() async throws {
        let tree = tree()
        tree.refresh()
        try await settle("the root listing") { !tree.rootNodes.isEmpty }
        try await settle("the first level") { tree.prefetchedPaths().contains(subPath) }
        _ = tree.node(at: subPath)?.children

        try await settle("the level below it") {
            tree.prefetchedPaths().contains(root.appendingPathComponent("sub/deep").path)
        }
    }
}
