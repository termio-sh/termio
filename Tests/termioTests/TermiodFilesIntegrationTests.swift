import XCTest
import TermioShared
@testable import termio

/// The files client against a real daemon, end to end.
///
/// Opt-in on the same terms as `TermiodTransferIntegrationTests`: point
/// `TERMIO_TERMIOD_TEST_BIN` at a built `termiod` and it runs, otherwise it
/// skips, so `swift test` never grows a cargo dependency. It is a real daemon
/// rather than a stub because the half worth pinning is *this client's* — the
/// `files` capability gate, the `fs_listed` shape, the `F` chunk header, and the
/// confinement refusal that stops a tree walking out of its root.
final class TermiodFilesIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?
    private var socketPath = ""
    private var root = URL(fileURLWithPath: "/")
    private var stallDirectory = URL(fileURLWithPath: "/")

    // MARK: - A search that takes a known amount of time

    /// `fs.search` runs in-process on the daemon — ripgrep's crates, not a
    /// `git grep` child — so there is no binary to shim and no process to
    /// watch. The daemon's own `TERMIOD_TEST_SEARCH_STALL` hook stands in for
    /// the enormous checkout instead: armed with a duration, every search
    /// stalls for that long before walking, checking its cancel flag all the
    /// while, and records what happened as marker files in this directory.
    /// `started` is written on entry, `finished` only after the full stall,
    /// `canceled` only when the flag stopped it — so "the host stopped early"
    /// is the host's own record, not an inference from the client returning.
    private var stallSecondsFile: URL { stallDirectory.appendingPathComponent("seconds") }
    private var stallStartedFile: URL { stallDirectory.appendingPathComponent("started") }
    private var stallFinishedFile: URL { stallDirectory.appendingPathComponent("finished") }
    private var stallCanceledFile: URL { stallDirectory.appendingPathComponent("canceled") }

    /// Arms the stall for `seconds`, and clears the previous run's marks.
    private func makeSearchTake(seconds: Double) throws {
        try? FileManager.default.removeItem(at: stallStartedFile)
        try? FileManager.default.removeItem(at: stallFinishedFile)
        try? FileManager.default.removeItem(at: stallCanceledFile)
        try Data("\(seconds)\n".utf8).write(to: stallSecondsFile)
    }

    private var searchStarted: Bool {
        FileManager.default.fileExists(atPath: stallStartedFile.path)
    }

    private var searchRanToCompletion: Bool {
        FileManager.default.fileExists(atPath: stallFinishedFile.path)
    }

    private var searchWasCanceledOnTheHost: Bool {
        FileManager.default.fileExists(atPath: stallCanceledFile.path)
    }

    /// Starts a daemon on this test's socket and waits for it to answer. Split
    /// out because one test kills it mid-flight to make sure a pooled channel
    /// that died between requests reconnects rather than failing the click.
    private func startDaemon() throws -> Process {
        // A killed daemon leaves its socket file behind, and a client that finds
        // one nobody is listening on would try to autostart a daemon from the
        // bundle rather than use this test's binary. Wait for *this* daemon's
        // socket, not for a corpse.
        try? FileManager.default.removeItem(atPath: socketPath)
        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging([
            "TERMIOD_SOCK": socketPath,
            // How a search can be made to take a known amount of time. The real
            // engine is far too fast to abandon on purpose — 133 MB of text
            // answers in tens of milliseconds — so a fixture built out of file
            // count would pin nothing.
            "TERMIOD_TEST_SEARCH_STALL": stallDirectory.path,
        ]) { _, new in new }
        serve.standardOutput = FileHandle.nullDevice
        serve.standardError = FileHandle.nullDevice
        try serve.run()

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socketPath), Date() < deadline {
            usleep(50_000)
        }
        return serve
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        binary = configured

        // Short socket directory name: `sun_path` is capped at 104 bytes and the
        // per-user temp directory already spends half of it.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)
        socketPath = socket
        stallDirectory = directory.appendingPathComponent("stall")
        try FileManager.default.createDirectory(
            at: stallDirectory, withIntermediateDirectories: true)
        try Data("0\n".utf8).write(to: stallSecondsFile)
        daemon = try startDaemon()

        // A tree with one of everything the pane draws: a file, a directory, a
        // nested file, and the VCS directory the host stubs rather than walks.
        root = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data(nestedContents.utf8).write(
            to: root.appendingPathComponent("sub/b.txt"))
        try Data("Widget lives here\n".utf8).write(
            to: root.appendingPathComponent("widget.txt"))
        // `fs.search` reads its ignore rules the way git would, so the
        // workspace should be a real checkout. The `.git` directory above is
        // what the listing tests expect to see; this makes it a repository
        // rather than a husk.
        try gitInit()
    }

    private func gitInit() throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "init", "--quiet"]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
    }

    override func tearDownWithError() throws {
        // The pool is process-wide and keyed by route, so a channel left open
        // here would be handed to the next test — pointed at a daemon this one
        // is about to kill.
        Termiod.ControlPool.closeAll()
        daemon?.terminate()
        daemon?.waitUntilExit()
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        unsetenv("TERMIOD_SOCK")
        try super.tearDownWithError()
    }

    private let nestedContents = String(repeating: "nested line\n", count: 400)

    func testTheRootListsAsTheTreeWouldDrawIt() throws {
        let listings = try Termiod.listDirectories(
            route: .local, root: root.path, paths: [root.path]).listings
        XCTAssertEqual(listings.count, 1)
        let listing = try XCTUnwrap(listings.first)
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.path, root.path, "the reply echoes the path asked for")

        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["a.txt"]?.kind, .file)
        XCTAssertEqual(byName["sub"]?.kind, .directory)
        // `.git` comes back as `unloaded_dir` and must still read as a directory,
        // because the tree's own ignore list — not the wire — is what hides it.
        XCTAssertEqual(byName[".git"]?.kind, .directory)
        XCTAssertFalse(listing.entries.sortedForTree().contains { $0.name == ".git" })
    }

    /// A symlinked folder browses as a folder, which is what the local tree
    /// always did through `FileManager` and what it now has to get from the
    /// wire. `.claude/skills → ../skills` is this repo's own case: reported as a
    /// link and nothing else, it would draw as an inert greyed row.
    ///
    /// The host still never *follows* a link while listing — the entry's own
    /// kind stays `symlink`. `target` is the separate fact, and it is absent for
    /// a link the host would refuse to descend, so the tree cannot offer a
    /// disclosure triangle that leads nowhere.
    func testASymlinkedFolderBrowsesAsAFolderAndOneOutOfTheRootDoesNot() throws {
        let manager = FileManager.default
        try manager.createSymbolicLink(
            atPath: root.appendingPathComponent("linked").path,
            withDestinationPath: "sub")
        try manager.createSymbolicLink(
            atPath: root.appendingPathComponent("escape").path,
            withDestinationPath: "/etc")

        let listing = try XCTUnwrap(Termiod.listDirectories(
            route: .local, root: root.path, paths: [root.path]).listings.first)
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })

        let linked = try XCTUnwrap(byName["linked"])
        XCTAssertEqual(linked.kind, .symlink, "the listing reports the link, not its target")
        XCTAssertTrue(linked.isDirectory, "and a link to a directory expands like one")
        XCTAssertTrue(linked.isSymbolicLink)
        XCTAssertEqual(linked.symlinkTarget, "sub")

        let escape = try XCTUnwrap(byName["escape"])
        XCTAssertFalse(
            escape.isDirectory,
            "descending it would be refused by the root confinement, so it is not offered")

        // The offer is honest: what the tree says it can expand, it can expand.
        let followed = try XCTUnwrap(Termiod.listDirectories(
            route: .local, root: root.path,
            paths: [root.appendingPathComponent("linked").path]).listings.first)
        XCTAssertNil(followed.error)
        XCTAssertEqual(followed.entries.map(\.name), ["b.txt"])
    }

    /// A directory larger than the host's page reads whole. The tree used to
    /// stop at the first page and say nothing about the rest — a `node_modules`
    /// with more than 2,000 entries would have shown 2,000 of them and read as
    /// the whole folder.
    func testADirectoryPastOnePageIsReadToTheEnd() throws {
        let big = root.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        // One past the host's page (`files.rs` LIST_PAGE_SIZE), so exactly one
        // extra round is needed and the last page is a short one.
        let count = 2_001
        for index in 0 ..< count {
            try Data("x".utf8).write(to: big.appendingPathComponent("f\(index)"))
        }

        let listing = try XCTUnwrap(Termiod.listDirectories(
            route: .local, root: root.path, paths: [big.path]).listings.first)
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.entries.count, count, "every page, not just the first")
        XCTAssertEqual(
            Set(listing.entries.map(\.name)).count, count,
            "pages partition rather than overlap")
    }

    func testASubdirectoryListsUnderTheSameRoot() throws {
        let listings = try Termiod.listDirectories(
            route: .local, root: root.path,
            paths: [root.appendingPathComponent("sub").path]).listings
        let listing = try XCTUnwrap(listings.first)
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.entries.map(\.name), ["b.txt"])
    }

    /// The confinement the pane depends on: a tree rooted at a checkout must not
    /// be able to list its parent, and the failure is per-path rather than an
    /// error that blanks the pane.
    func testAPathOutsideTheRootIsRefusedOnItsOwn() throws {
        let outside = root.deletingLastPathComponent().path
        let listings = try Termiod.listDirectories(
            route: .local, root: root.path, paths: [root.path, outside]).listings
        XCTAssertEqual(listings.count, 2)
        XCTAssertNil(listings[0].error, "the confined path still answers")
        XCTAssertNotNil(listings[1].error, "the escape is refused")
    }

    func testAFileComesBackByteForByte() throws {
        let file = try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("a.txt").path)
        XCTAssertEqual(file.data, Data("hello\n".utf8))
    }

    /// Several `F` frames' worth, so the chunk loop is genuinely exercised rather
    /// than short-circuited by a payload that fits in one frame.
    func testAMultiChunkFileReassembles() throws {
        let file = try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("sub/b.txt").path)
        XCTAssertEqual(file.data, Data(nestedContents.utf8))
    }

    /// A preview that would be a prefix is refused, so the pane says the file is
    /// too big instead of rendering half of it.
    func testAFileOverTheCallersLimitIsRefusedRatherThanTruncated() throws {
        XCTAssertThrowsError(try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("sub/b.txt").path,
            limit: 16)) { error in
            XCTAssertEqual(error as? DeviceFileError, .tooLarge)
        }
    }

    /// The daemon's own message reaches the caller instead of a hang, for the
    /// path that is not there at all.
    func testAMissingFileFailsWithTheDaemonsReason() {
        XCTAssertThrowsError(try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("nope.txt").path))
    }

    /// Save, end to end: the bytes cross, the version claimed is the one that was
    /// read, and the file on the device is the file that comes back.
    func testSavingAFileLandsOnTheDeviceAndReVersionsIt() throws {
        let path = root.appendingPathComponent("a.txt").path
        let read = try Termiod.readFile(route: .local, path: path)
        XCTAssertEqual(read.data, Data("hello\n".utf8))
        XCTAssertGreaterThan(read.mtime, 0, "the read carries the version it holds")

        let landed = try Termiod.writeFile(
            route: .local, root: root.path, path: path,
            data: Data("edited\n".utf8), ifUnmodifiedSince: read.mtime)

        XCTAssertGreaterThan(landed, 0, "the write answers with the version it made")
        let after = try Termiod.readFile(route: .local, path: path)
        XCTAssertEqual(after.data, Data("edited\n".utf8))
        XCTAssertEqual(after.mtime, landed, "the version the write reported is the file's")
    }

    /// The lost-update guard, over the wire: the agent in that checkout wrote
    /// first, so this save is refused rather than silently replacing its work.
    func testSavingIsRefusedWhenTheDeviceFileMovedOn() throws {
        let path = root.appendingPathComponent("a.txt").path
        let read = try Termiod.readFile(route: .local, path: path)

        // The other writer. The wait is the resolution of the timestamp itself.
        Thread.sleep(forTimeInterval: 1.1)
        try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try Termiod.writeFile(
            route: .local, root: root.path, path: path,
            data: Data("mine\n".utf8), ifUnmodifiedSince: read.mtime)
        ) { error in
            guard case DeviceFileError.conflict(let message) = error else {
                return XCTFail("expected a conflict, got \(error)")
            }
            XCTAssertTrue(message.contains("changed"), message)
        }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path)), Data("theirs\n".utf8),
            "the other writer's file is untouched")
    }

    /// Claiming nothing is how "overwrite anyway" travels, and it must land even
    /// though the file has moved on since it was read.
    func testAnUnversionedSaveOverwritesWhatIsThere() throws {
        let path = root.appendingPathComponent("a.txt").path
        Thread.sleep(forTimeInterval: 1.1)
        try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: path))

        _ = try Termiod.writeFile(
            route: .local, root: root.path, path: path,
            data: Data("mine\n".utf8), ifUnmodifiedSince: nil)

        XCTAssertEqual(try Termiod.readFile(route: .local, path: path).data,
                       Data("mine\n".utf8))
    }

    /// A save may not walk out of the checkout it is rooted at — the same
    /// confinement the listing has, on the write side where it matters more.
    func testASaveOutsideTheRootIsRefused() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("escaped.txt").path
        XCTAssertThrowsError(try Termiod.writeFile(
            route: .local, root: root.path, path: outside,
            data: Data("nope\n".utf8), ifUnmodifiedSince: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside))
    }

    /// The Search pane's whole contract in one call: hits stream as events and
    /// the terminal reply closes them, paths come back relative to the searched
    /// root, and the line numbers are the ones the pane jumps to.
    func testSearchAnswersHitsWithRootRelativePaths() throws {
        let result = try Termiod.searchContents(
            route: .local, root: root.path, query: "Widget", limit: 400)

        XCTAssertFalse(result.limitHit)
        XCTAssertEqual(result.hits.map(\.path), ["widget.txt"])
        XCTAssertEqual(result.hits.first?.line, 1)
        XCTAssertEqual(result.hits.first?.text, "Widget lives here")
    }

    /// The host reports where it hit and the lines around it, because the pane
    /// paints those spans rather than re-finding the query itself.
    func testSearchReportsSpansAndContext() throws {
        let result = try Termiod.searchContents(
            route: .local, root: root.path, query: "Widget", limit: 400)

        let hit = try XCTUnwrap(result.hits.first)
        XCTAssertEqual(hit.path, "widget.txt")
        let text = hit.text
        let spans = hit.spans.compactMap { ContentMatch.range(text, bytes: $0) }
        XCTAssertEqual(spans.map { String(text[$0]) }, ["Widget"],
                       "the host says where it matched")
        XCTAssertFalse(hit.isWindowed, "a short line is not a window")
        XCTAssertTrue(hit.before.isEmpty, "the hit is the first line of its file")
        XCTAssertEqual(hit.after, [], "and its last")
    }

    /// Context arrives on both sides when the file has lines to give.
    func testSearchCarriesTheLinesAroundAHit() throws {
        let path = root.appendingPathComponent("story.txt")
        try Data("one\ntwo\nWidget\nfour\nfive\n".utf8).write(to: path)

        let result = try Termiod.searchContents(
            route: .local, root: root.path, query: "Widget", limit: 400)
        let hit = try XCTUnwrap(result.hits.first { $0.path == "story.txt" })

        XCTAssertEqual(hit.line, 3)
        XCTAssertEqual(hit.before, ["one", "two"])
        XCTAssertEqual(hit.after, ["four", "five"])
    }

    /// The case the old row got wrong: a hit past the line cap. The host windows
    /// the line around it, so there is always something to paint.
    func testAMatchPastTheLineCapStillArrivesPaintable() throws {
        let path = root.appendingPathComponent("minified.js")
        let line = String(repeating: "x", count: 4000) + "needle" + String(repeating: "y", count: 4000)
        try Data((line + "\n").utf8).write(to: path)

        let result = try Termiod.searchContents(
            route: .local, root: root.path, query: "needle", limit: 400)
        let hit = try XCTUnwrap(result.hits.first { $0.path == "minified.js" })

        XCTAssertTrue(hit.isWindowed)
        let spans = hit.spans.compactMap { ContentMatch.range(hit.text, bytes: $0) }
        XCTAssertEqual(spans.map { String(hit.text[$0]) }, ["needle"])
    }

    /// Smart case, matching what the local pane has always done: an all-lowercase
    /// query matches insensitively, and an uppercase letter opts into exactness.
    func testSearchIsSmartCase() throws {
        let loose = try Termiod.searchContents(
            route: .local, root: root.path, query: "widget", limit: 400)
        XCTAssertEqual(loose.hits.map(\.path), ["widget.txt"])

        let exact = try Termiod.searchContents(
            route: .local, root: root.path, query: "WIDGET", limit: 400)
        XCTAssertTrue(exact.hits.isEmpty, "an uppercase query means what it says")
    }

    /// The cap is what keeps a one-letter query in a monorepo from flooding the
    /// pane, and the pane says "more exist" only because the reply does.
    func testSearchStopsAtTheLimitAndSaysSo() throws {
        let result = try Termiod.searchContents(
            route: .local, root: root.path, query: "nested", limit: 5)

        XCTAssertTrue(result.limitHit)
        XCTAssertEqual(result.hits.count, 5)
        XCTAssertTrue(result.hits.allSatisfy { $0.path == "sub/b.txt" })
    }

    /// A query nothing matches is an answer, not a failure: the pane must show
    /// "no matches" rather than an error.
    func testSearchWithNoHitsSucceedsEmpty() throws {
        let result = try Termiod.searchContents(
            route: .local, root: root.path, query: "nothing-here-at-all", limit: 400)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertFalse(result.limitHit)
    }

    // MARK: - The pooled channel

    /// The premise of the whole pool: a second request reaches the device over
    /// the connection the first one opened. If this ever stops holding, nothing
    /// fails — every call still answers — the app just quietly goes back to an
    /// SSH handshake per folder expand.
    func testASecondRequestReusesTheFirstsConnection() throws {
        _ = try Termiod.listDirectories(route: .local, root: root.path, paths: [root.path])
        let first = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        _ = try Termiod.readFile(route: .local, path: root.appendingPathComponent("a.txt").path)
        let second = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        XCTAssertTrue(first === second, "the files plane must hold one channel per device")
    }

    /// A channel that negotiated one capability set must not answer for another:
    /// the daemon settles capabilities at the handshake, so handing a `files`
    /// channel a request it never negotiated would hang on a reply it will not
    /// send.
    func testChannelsAreKeyedByWhatTheyNegotiated() throws {
        let files = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        let other = try Termiod.ControlPool.channel(route: .local, caps: ["files", "git"])
        XCTAssertFalse(files === other)
    }

    /// Requests are demultiplexed by `re`, so several may be outstanding at once
    /// — the daemon `tokio::spawn`s each one and answers out of order.
    ///
    /// The discriminator is *when* the fast two finish, not that they finish. A
    /// channel that took one request at a time would answer all three correctly
    /// and simply make the listing wait out the search, which is exactly the
    /// behaviour worth ruling out: the pane must stay usable while a search runs.
    /// So the search is made to take four seconds and the assertion is that the
    /// listing and the read both landed while it was still going.
    func testASlowSearchDoesNotHoldUpTheRestOfTheChannel() throws {
        try makeSearchTake(seconds: 4)
        let done = expectation(description: "all requests answered")
        done.expectedFulfillmentCount = 3
        let listed = UncheckedBox<[Termiod.DirectoryListing]>([])
        let read = UncheckedBox<Data>(Data())
        let clock = ContinuousClock()
        let searchEnded = UncheckedBox<ContinuousClock.Instant?>(nil)
        let listEnded = UncheckedBox<ContinuousClock.Instant?>(nil)
        let readEnded = UncheckedBox<ContinuousClock.Instant?>(nil)
        let root = root

        DispatchQueue.global().async {
            _ = try? Termiod.searchContents(
                route: .local, root: root.path, query: "anything", limit: 400)
            searchEnded.value = clock.now
            done.fulfill()
        }
        // Give the search time to be on the wire and the walk time to start, so
        // "while it was still running" is a fact rather than a hope.
        let armed = ContinuousClock.now.advanced(by: .seconds(10))
        while !searchStarted, ContinuousClock.now < armed { usleep(20_000) }
        XCTAssertTrue(searchStarted, "the slow search is what this test measures against")

        DispatchQueue.global().async {
            listed.value = (try? Termiod.listDirectories(
                route: .local, root: root.path, paths: [root.path]))?.listings ?? []
            listEnded.value = clock.now
            done.fulfill()
        }
        DispatchQueue.global().async {
            read.value = (try? Termiod.readFile(
                route: .local,
                path: root.appendingPathComponent("sub/b.txt").path))?.data ?? Data()
            readEnded.value = clock.now
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        XCTAssertTrue(listed.value.first?.entries.contains { $0.name == "a.txt" } ?? false)
        XCTAssertEqual(read.value, Data(nestedContents.utf8), "the read got its own bytes")

        let searchAt = try XCTUnwrap(searchEnded.value)
        let listAt = try XCTUnwrap(listEnded.value)
        let readAt = try XCTUnwrap(readEnded.value)
        XCTAssertTrue(listAt < searchAt, "the listing answered while the search was still running")
        XCTAssertTrue(readAt < searchAt, "so did the read")
        // And by a margin that could not be scheduling noise: both should land
        // in well under the four seconds the search is holding the channel for.
        XCTAssertGreaterThan(listAt.duration(to: searchAt), .seconds(2))
        XCTAssertGreaterThan(readAt.duration(to: searchAt), .seconds(2))
    }

    /// Abandoning a search has to stop the walk on the device.
    ///
    /// This is the one thing pooling took away and had to give back. A channel
    /// that lived for one request stopped a search by hanging up — `run_search`
    /// watches `out.closed()` for exactly that, and that arm is the whole reason
    /// an abandoned query did not leave a walk running over someone's checkout.
    /// A pooled channel never hangs up, so the client now sends the protocol's
    /// own `cancel { request: <seq> }` instead, which only a multiplexed channel
    /// *can* send: a synchronous one is blocked reading the descriptor it would
    /// have to write to.
    ///
    /// The assertion is on the host's own record. The stall hook writes
    /// `finished` only if it runs its full ten seconds and `canceled` only when
    /// its cancel flag stops it, so the client giving up cannot produce a pass;
    /// the walk really has to have been stopped.
    func testAnAbandonedSearchStopsTheWalkOnTheDevice() throws {
        try makeSearchTake(seconds: 10)

        let started = ContinuousClock.now
        XCTAssertThrowsError(
            try Termiod.searchContents(
                route: .local, root: root.path, query: "anything", limit: 400,
                idleTimeoutSeconds: 1)
        ) { error in
            guard case TermiodClientError.timedOut = error else {
                return XCTFail("expected the idle bound to fire, got \(error)")
            }
        }
        XCTAssertTrue(searchStarted, "the walk did start, so there was something to stop")

        // The cancel goes out as the request is retired. Allow a moment for the
        // host to act on it, then check its record — well inside the ten seconds
        // an uncancelled walk would still be running for.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !searchWasCanceledOnTheHost, ContinuousClock.now < deadline {
            usleep(100_000)
        }
        XCTAssertTrue(
            searchWasCanceledOnTheHost, "the device's walk was stopped, not left running")
        XCTAssertFalse(
            searchRanToCompletion, "stopped rather than allowed to finish on its own")
        XCTAssertLessThan(
            started.duration(to: .now), .seconds(8),
            "which happened long before the walk would have ended by itself")
    }

    /// The cost of holding a connection: it can die between requests, and the
    /// first click after a laptop wakes must reconnect rather than show an error.
    /// Killing the daemon under a live pooled channel is exactly that.
    func testTheNextRequestAfterADaemonRestartStillAnswers() throws {
        _ = try Termiod.listDirectories(route: .local, root: root.path, paths: [root.path])

        daemon?.terminate()
        daemon?.waitUntilExit()
        daemon = nil
        let restarted = try startDaemon()
        daemon = restarted

        let listings = try Termiod.listDirectories(
            route: .local, root: root.path, paths: [root.path]).listings
        XCTAssertTrue(listings.first?.entries.contains { $0.name == "a.txt" } ?? false)
    }

    /// The retry policy itself, which the restart above does *not* reach: killing
    /// a daemon gives the reader a clean EOF, so by the time the next request
    /// asks for a channel the dead one has already been replaced. The path worth
    /// pinning is the narrower one — a channel that was still believed live when
    /// the request went out and turned out not to be — and its three gates.
    ///
    /// Driven through the real `withPooledRequest` with a body that fails on
    /// cue, because the operating-system race cannot be scheduled on demand.
    func testAnInheritedChannelIsRetriedOnceAndOnlyWhenNothingWasHeard() throws {
        // Open the channel, so everything after this inherits it.
        _ = try Termiod.listDirectories(route: .local, root: root.path, paths: [root.path])

        var attempts = 0
        var reuse: [Bool] = []
        _ = try? Termiod.withPooledRequest(route: .local, caps: ["files"]) { call, _ in
            attempts += 1
            reuse.append(call.wasReused)
            throw TermiodClientError.connectionClosed
        }
        XCTAssertEqual(attempts, 2, "an inherited channel is worth one reconnect")
        XCTAssertEqual(
            reuse, [true, false],
            "the first call inherited a channel; the retry got a freshly opened one — "
                + "which is also what stops the retry from retrying")

        // A refusal is not a broken pipe: the host would say the same thing again.
        attempts = 0
        _ = try? Termiod.withPooledRequest(route: .local, caps: ["files"]) { _, _ in
            attempts += 1
            throw TermiodClientError.requestFailed("no such file")
        }
        XCTAssertEqual(attempts, 1, "a refusal is answered, not retried")

        // Once part of the answer has landed, replaying would splice two halves
        // of different answers together.
        attempts = 0
        _ = try? Termiod.withPooledRequest(route: .local, caps: ["files"]) { call, _ in
            attempts += 1
            try call.send(payload: Termiod.encodeControl(
                Termiod.FsListOperation(root: root.path, paths: [root.path], seq: call.seq)))
            _ = try call.next(timeoutSeconds: 10, operation: "fs.list")
            XCTAssertTrue(call.hasDelivered)
            throw TermiodClientError.connectionClosed
        }
        XCTAssertEqual(attempts, 1, "a request that heard part of its answer is not replayed")
    }

    /// The idle reaper hangs up a connection nobody has used, which is right for
    /// a device nobody is looking at and wrong for a pane that is on screen: its
    /// next click is seconds away, and rebuilding the connection for it is the
    /// 32 ms median / 260 ms p90 the pool exists to stop paying.
    func testAPinnedChannelSurvivesTheIdleReaper() throws {
        let channel = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        let pin = Termiod.ControlPool.pin(route: .local, caps: ["files"])

        // A threshold every idle channel is already past, so only the exemption
        // can be what keeps this one.
        Termiod.ControlPool.reap(idleTimeout: .seconds(-1))

        let held = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        XCTAssertTrue(channel === held, "a pinned channel is not hung up for being idle")

        withExtendedLifetime(pin) {}
    }

    /// And goes back on the clock when the pane does: a pin is a claim, not a
    /// promotion. Holding somebody's VPS process open for a pane that closed an
    /// hour ago is the cost this trade was only ever worth paying while looking.
    func testAReleasedPinPutsTheChannelBackOnTheIdleClock() throws {
        let channel = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        var pin: Termiod.ControlPool.ChannelPin? =
            Termiod.ControlPool.pin(route: .local, caps: ["files"])
        XCTAssertNotNil(pin)
        pin = nil

        Termiod.ControlPool.reap(idleTimeout: .seconds(-1))

        let replacement = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        XCTAssertFalse(channel === replacement, "the unpinned channel was hung up")
    }

    /// Two panes on one device is one connection with two claims on it. The
    /// first one to close must not take the second one's connection with it.
    func testTwoPinsOnOneDeviceAreCountedNotFlagged() throws {
        let channel = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        var first: Termiod.ControlPool.ChannelPin? =
            Termiod.ControlPool.pin(route: .local, caps: ["files"])
        let second = Termiod.ControlPool.pin(route: .local, caps: ["files"])
        XCTAssertNotNil(first)
        first = nil

        Termiod.ControlPool.reap(idleTimeout: .seconds(-1))

        let held = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        XCTAssertTrue(channel === held, "the pane still open keeps the connection")
        withExtendedLifetime(second) {}
    }

    // MARK: - The live subscription

    /// The `fs:` plane end to end: subscribe, touch a file, and see the batch
    /// name the directory it landed in.
    ///
    /// This is the half the client had never exercised. The daemon has served
    /// `fs:` since it grew a watcher; nothing here listened, so the tree re-read
    /// everything on app focus instead. What is worth pinning is precisely what
    /// used to be missing: that a frame answering *no request* reaches a
    /// subscriber at all (`PooledChannel.addObserver`), and that the batch names
    /// the changed directory rather than the changed file.
    func testAWatchDeliversABatchNamingTheChangedDirectory() throws {
        let batches = UncheckedBox<[Termiod.FsChangedPayload]>([])
        let arrived = expectation(description: "a batch names the directory")
        arrived.assertForOverFulfill = false
        let watch = Termiod.ResourceWatch(
            route: .local,
            caps: ["files", Termiod.ResourceWatch.capability],
            resource: "fs:" + root.path
        ) { update in
            guard case .batch(let batch) = update else { return }
            batches.value.append(batch)
            arrived.fulfill()
        }

        // The subscribe is asynchronous; a write that beats it would be watched
        // by nobody. Poll the write rather than sleep once, so a slow machine
        // lengthens the test instead of failing it.
        let armed = Date().addingTimeInterval(20)
        while watch.watchedRoot == nil, Date() < armed { usleep(20_000) }
        let subscribed = Date()
        try Data("live\n".utf8).write(to: root.appendingPathComponent("watched.txt"))
        wait(for: [arrived], timeout: 20)
        let latency = Date().timeIntervalSince(subscribed)
        print(String(format: "fs: batch latency after one write: %.0f ms", latency * 1000))
        XCTAssertLessThan(
            latency, 5,
            "a change is meant to reach the tree while the user is still looking at it")
        withExtendedLifetime(watch) {}

        // The host canonicalises the root it watches, so a `/var/folders` path
        // comes back as `/private/var/folders`. Comparing the resolved spelling
        // is the point rather than an allowance: a client that matched on what
        // it asked for would hear nothing, which is what this test caught.
        // `realpath` rather than `resolvingSymlinksInPath`, which deliberately
        // rewrites `/private/var` *back* to `/var` and would agree with the bug.
        let canonical = try XCTUnwrap(Self.realPath(of: root.path))
        let named = Set(batches.value.flatMap(\.paths))
        XCTAssertTrue(
            named.contains(canonical) || batches.value.contains(where: \.fullRescan),
            "the batch names the directory the file landed in, not the file: \(named)")
        XCTAssertEqual(
            watch.watchedRoot, canonical,
            "the watch adopts the host's spelling, which is what the tree translates by")
        XCTAssertTrue(
            batches.value.allSatisfy { $0.resource == "fs:" + canonical },
            "every batch is tagged with the resource that raised it")
    }

    /// The cursor, which is what keeps a live tree from re-reading what it just
    /// read: a batch at or below the `seq` a listing was taken at is already
    /// reflected in that listing and must not send the tree back to the device.
    func testAListingCarriesTheCursorItWasTakenAt() throws {
        // `fs_listed.seq` is 0 until something is watching the root — the
        // daemon's honest "nothing will invalidate this". So the subscription
        // has to exist before the listing can carry a cursor at all, which is
        // the ordering the tree uses too: subscribe on appear, then load.
        let delivered = UncheckedBox<[UInt64]>([])
        let watch = Termiod.ResourceWatch(
            route: .local,
            caps: ["files", Termiod.ResourceWatch.capability],
            resource: "fs:" + root.path
        ) { update in
            guard case .batch(let batch) = update else { return }
            delivered.value.append(batch.seq)
        }
        let armed = Date().addingTimeInterval(20)
        while watch.watchedRoot == nil, Date() < armed { usleep(100_000) }
        XCTAssertNotNil(watch.watchedRoot, "the subscription is what stamps a listing")

        try Data("cursor\n".utf8).write(to: root.appendingPathComponent("cursor.txt"))
        var listed = try Termiod.listDirectories(
            route: .local, root: root.path, paths: [root.path])
        let cursorDeadline = Date().addingTimeInterval(20)
        while listed.seq == 0, Date() < cursorDeadline {
            usleep(200_000)
            listed = try Termiod.listDirectories(
                route: .local, root: root.path, paths: [root.path])
        }
        withExtendedLifetime(watch) {}

        XCTAssertGreaterThan(
            listed.seq, 0,
            "a listing taken while a watch is running carries that watch's cursor")
        XCTAssertTrue(
            listed.listings.first?.entries.contains { $0.name == "cursor.txt" } ?? false,
            "and the listing the cursor is stamped on is the one that includes the write")
    }

    /// A watch that loses its channel and comes back re-subscribes, and leaves
    /// exactly one entry on the channel it lands on.
    ///
    /// This covers the reconnect path: a hung-up channel is closed and its
    /// subscriptions are swept, so the retry necessarily lands on a fresh one.
    /// What the count pins is that the swept subscription did not survive
    /// alongside its replacement — two entries would double every batch, and
    /// would make the first close of the pane look like the last.
    func testAReconnectingWatchReplacesItsSubscriptionRatherThanStackingOne() throws {
        let watch = Termiod.ResourceWatch(
            route: .local,
            caps: ["files", Termiod.ResourceWatch.capability],
            resource: "fs:" + root.path
        ) { _ in }

        let armed = Date().addingTimeInterval(30)
        while !watch.isSubscribed, Date() < armed { usleep(100_000) }
        XCTAssertTrue(watch.isSubscribed, "the first subscribe never landed")

        // Hang the channel up under it, which is what a ControlPersist expiry or
        // a sleeping laptop does.
        Termiod.ControlPool.closeAll(route: .local)
        let backAgain = Date().addingTimeInterval(90)
        while !watch.isSubscribed, Date() < backAgain { usleep(200_000) }
        XCTAssertTrue(watch.isSubscribed, "the watch never re-established")

        let resource = try XCTUnwrap(watch.watchedRoot.map { "fs:" + $0 })
        let channel = try Termiod.ControlPool.channel(
            route: .local, caps: ["files", Termiod.ResourceWatch.capability])
        XCTAssertEqual(
            channel.subscriberCount(for: resource), 1,
            "one watch, one subscription — a second would double every batch")
        withExtendedLifetime(watch) {}
    }

    /// Two panes on one checkout, and the first of them closes.
    ///
    /// The pool gives every request to a machine the same connection, and the
    /// daemon tracks resource interest per *connection* (`resource.rs`
    /// `subscribers`, keyed by `ClientId`). So an `unsubscribe_resource` sent
    /// because one pane went away retires the watch the other pane is still
    /// drawing from — its tree then goes quietly stale, with no error and no
    /// refresh, which is the worst shape a bug of this kind can take.
    ///
    /// The fix is that a watch retires its interest through the channel's
    /// routing table, which counts subscribers and tells the device only on the
    /// last one. This is the test that fails without it.
    func testClosingOnePaneLeavesASecondPanesWatchLive() throws {
        let surviving = expectation(description: "the second watch still hears the device")
        surviving.assertForOverFulfill = false
        let batches = UncheckedBox<[Termiod.FsChangedPayload]>([])

        var closing: Termiod.ResourceWatch? = Termiod.ResourceWatch(
            route: .local,
            caps: ["files", Termiod.ResourceWatch.capability],
            resource: "fs:" + root.path
        ) { _ in }
        let staying = Termiod.ResourceWatch(
            route: .local,
            caps: ["files", Termiod.ResourceWatch.capability],
            resource: "fs:" + root.path
        ) { update in
            guard case .batch(let batch) = update else { return }
            batches.value.append(batch)
            surviving.fulfill()
        }

        let armed = Date().addingTimeInterval(30)
        while closing?.watchedRoot == nil || staying.watchedRoot == nil, Date() < armed {
            usleep(20_000)
        }
        let resource = try XCTUnwrap(staying.watchedRoot.map { "fs:" + $0 })
        let channel = try Termiod.ControlPool.channel(
            route: .local, caps: ["files", Termiod.ResourceWatch.capability])
        XCTAssertEqual(
            channel.subscriberCount(for: resource), 2,
            "two panes on one machine are two subscriptions on one connection")

        closing = nil
        XCTAssertEqual(
            channel.subscriberCount(for: resource), 1,
            "the pane that closed dropped its own interest and only its own")

        try Data("survivor\n".utf8).write(to: root.appendingPathComponent("survivor.txt"))
        wait(for: [surviving], timeout: 20)
        XCTAssertFalse(
            batches.value.isEmpty,
            "the surviving pane's watch was retired by the pane that closed")
        withExtendedLifetime(staying) {}
    }
}

extension TermiodFilesIntegrationTests {
    /// The path the daemon canonicalises to, resolved the same way it does.
    static func realPath(of path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// A box for handing a result back from a detached queue in a test. The values
/// are read only after `wait(for:)` has returned, which is the barrier that
/// makes this safe; the compiler cannot see that.
private final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
