import Darwin
import Foundation
import XCTest
@testable import termio

/// The SFTP client, exercised against OpenSSH's own `sftp-server`.
///
/// The subsystem binary speaks the protocol on stdin/stdout — that is how `sshd`
/// invokes it — so running it directly tests the real client against the real
/// server with no network, no SSH, and nothing mocked. What `ssh -s <host> sftp`
/// adds on a live host is transport, not protocol.
final class SFTPProtocolTests: XCTestCase {
    private static let serverPath = "/usr/libexec/sftp-server"

    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.serverPath),
            "no local sftp-server to test against")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-sftp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func connect() async throws -> SFTPChannel {
        try await SFTPChannel.connect(
            argv: [Self.serverPath], requestTimeout: 10, connectTimeout: 10)
    }

    /// The names a shell protocol has to escape and a `find`/`ls` parser can be
    /// spoofed by. Over SFTP they are length-prefixed bytes, so they need no
    /// handling at all — which is the point of the test.
    func testListsHostileNamesAndClassifiesEveryKind() async throws {
        let channel = try await connect()
        defer { channel.close() }

        let regularNames = [
            "line\nbreak.txt", "quote's file", "tab\tfile", "-leading-option",
            "space and 空格.md",
        ]
        for name in regularNames {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name).path,
                contents: Data("hello".utf8)))
        }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("safe-link").path,
            withDestinationPath: directory.appendingPathComponent("line\nbreak.txt").path)
        XCTAssertEqual(mkfifo(directory.appendingPathComponent("named-pipe").path, 0o600), 0)

        let entries = try await channel.entries(at: directory.path, limit: 1000)
        let kinds = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.name, $0.kind) })

        XCTAssertEqual(
            Set(entries.map(\.name)),
            Set(regularNames + ["folder", "safe-link", "named-pipe"]))
        for name in regularNames {
            XCTAssertEqual(kinds[name], .file, name)
        }
        XCTAssertEqual(kinds["folder"], .directory)
        // lstat semantics: a link to a regular file is still a link, and the tree
        // never chases it.
        XCTAssertEqual(kinds["safe-link"], .symlink)
        XCTAssertEqual(kinds["named-pipe"], .other)
        XCTAssertFalse(entries.contains { $0.name == "." || $0.name == ".." })
        // Folders first, then the Finder's name order — the shared tree contract.
        XCTAssertEqual(entries.first?.name, "folder")
    }

    func testListingCarriesSizeAndModificationTime() async throws {
        let channel = try await connect()
        defer { channel.close() }

        let file = directory.appendingPathComponent("sized.bin")
        try Data(repeating: 7, count: 4242).write(to: file)

        let listing = try await channel.entries(at: directory.path, limit: 1000)
        let entry = try XCTUnwrap(listing.first)
        XCTAssertEqual(entry.size, 4242)
        let modified = try XCTUnwrap(entry.modified)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 60)
    }

    func testListingDropsVCSMetadataAndAppliesTreeOrder() async throws {
        let channel = try await connect()
        defer { channel.close() }

        for name in [".git", ".DS_Store", ".hidden-but-shown", "visible.txt"] {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name).path, contents: Data()))
        }

        let entries = try await channel.entries(at: directory.path, limit: 1000)
        XCTAssertEqual(entries.map(\.name), [".hidden-but-shown", "visible.txt"])
    }

    func testEntryLimitFailsClosed() async throws {
        let channel = try await connect()
        defer { channel.close() }

        for index in 0..<40 {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: directory.appendingPathComponent("entry-\(index)").path,
                contents: Data()))
        }

        do {
            _ = try await channel.entries(at: directory.path, limit: 5)
            XCTFail("expected the entry cap to reject an oversized listing")
        } catch SSHProviderError.listingTooLarge {
            // expected
        }
    }

    func testMissingDirectoryReportsTheServersReason() async throws {
        let channel = try await connect()
        defer { channel.close() }

        do {
            _ = try await channel.entries(
                at: directory.appendingPathComponent("absent").path, limit: 1000)
            XCTFail("expected a failure for a missing directory")
        } catch SSHProviderError.commandFailed(let detail) {
            XCTAssertFalse(detail.isEmpty)
        }
    }

    /// A read spans many chunks and several pipelined rounds, so this covers the
    /// offset arithmetic that assembles them.
    func testReadsExactBytesAcrossChunkBoundaries() async throws {
        let channel = try await connect()
        defer { channel.close() }

        let contents = Data((0..<(SFTP.readChunkBytes * 3 + 17)).map {
            UInt8(truncatingIfNeeded: $0 &* 31)
        })
        let file = directory.appendingPathComponent("large.bin")
        try contents.write(to: file)

        let read = try await channel.fileContents(at: file.path, limit: contents.count)
        XCTAssertEqual(read, contents)
    }

    func testReadStopsAtEndOfFileBelowTheLimit() async throws {
        let channel = try await connect()
        defer { channel.close() }

        let file = directory.appendingPathComponent("small.txt")
        try Data("just a little".utf8).write(to: file)

        let read = try await channel.fileContents(at: file.path, limit: 1_048_576)
        XCTAssertEqual(String(decoding: read, as: UTF8.self), "just a little")
    }

    /// The size is known from the open handle, so an oversized file is refused
    /// before a byte moves.
    func testOversizedFileIsRefusedBeforeTransfer() async throws {
        let channel = try await connect()
        defer { channel.close() }

        let file = directory.appendingPathComponent("oversized.bin")
        try Data(repeating: 98, count: 129).write(to: file)

        do {
            _ = try await channel.fileContents(at: file.path, limit: 128)
            XCTFail("expected the preview cap to reject an oversized file")
        } catch SSHProviderError.tooLarge {
            // expected
        }
    }

    func testRefusesSymlinksFIFOsAndDirectories() async throws {
        let channel = try await connect()
        defer { channel.close() }

        let target = directory.appendingPathComponent("target.txt")
        try Data("target".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: target.path)
        let fifo = directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        for path in [link.path, fifo.path, directory.path] {
            do {
                _ = try await channel.fileContents(at: path, limit: 1024)
                XCTFail("expected \(path) to be refused")
            } catch SSHProviderError.notRegularFile {
                // expected
            }
        }
        // The link's target is still readable when asked for directly, so the
        // refusal is about not chasing links, not about the file being unreadable.
        let readThroughTarget = try await channel.fileContents(at: target.path, limit: 1024)
        XCTAssertEqual(readThroughTarget, Data("target".utf8))
    }

    func testResolvesAStartDirectory() async throws {
        let channel = try await connect()
        defer { channel.close() }

        let root = try await channel.resolveRoot()
        XCTAssertTrue(root.hasPrefix("/"), root)
    }

    /// Requests are matched by id, so many can be in flight on one channel. If the
    /// dispatcher ever mismatched a reply, the contents would cross over.
    func testConcurrentRequestsOnOneChannelDoNotCross() async throws {
        let channel = try await connect()
        defer { channel.close() }

        for index in 0..<16 {
            try Data("contents-\(index)".utf8).write(
                to: directory.appendingPathComponent("file-\(index).txt"))
        }

        let results = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for index in 0..<16 {
                group.addTask {
                    (index, try await channel.fileContents(
                        at: self.directory.appendingPathComponent("file-\(index).txt").path,
                        limit: 1024))
                }
            }
            var collected: [Int: Data] = [:]
            for try await (index, data) in group { collected[index] = data }
            return collected
        }

        for index in 0..<16 {
            XCTAssertEqual(
                String(decoding: try XCTUnwrap(results[index]), as: UTF8.self),
                "contents-\(index)")
        }
    }

    func testClosedChannelReportsDisconnected() async throws {
        let channel = try await connect()
        channel.close()
        XCTAssertFalse(channel.isOpen)

        do {
            _ = try await channel.entries(at: directory.path, limit: 10)
            XCTFail("expected a closed channel to refuse work")
        } catch SSHProviderError.disconnected {
            // expected
        }
    }

    func testLaunchFailureIsReportedNotTrapped() async {
        do {
            _ = try await SFTPChannel.connect(
                argv: ["/nonexistent/sftp-server"], requestTimeout: 2, connectTimeout: 2)
            XCTFail("expected a launch failure")
        } catch {
            XCTAssertTrue(
                error is SSHProviderError, String(describing: error))
        }
    }
}

/// Wire-format decoding, checked against bytes rather than a server: the cases a
/// real server won't produce but a hostile or desynchronised one might.
final class SFTPWireFormatTests: XCTestCase {
    func testDecodesAttributeFlagCombinations() throws {
        var payload = Data()
        SFTP.append(UInt32(0x0000_0001 | 0x0000_0002 | 0x0000_0004 | 0x0000_0008), to: &payload)
        SFTP.append(UInt64(4096), to: &payload)
        SFTP.append(UInt32(501), to: &payload) // uid
        SFTP.append(UInt32(20), to: &payload) // gid
        SFTP.append(UInt32(0o100_644), to: &payload)
        SFTP.append(UInt32(1_700_000_000), to: &payload) // atime
        SFTP.append(UInt32(1_700_000_500), to: &payload) // mtime

        var reader = SFTPReader(payload)
        let attributes = try reader.readAttributes()

        XCTAssertEqual(attributes.size, 4096)
        XCTAssertEqual(attributes.kind, .file)
        XCTAssertEqual(attributes.modified, Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertTrue(reader.isAtEnd, "attribute parsing left the cursor misaligned")
    }

    func testKindFailsClosedWhenPermissionsAreAbsent() throws {
        var payload = Data()
        SFTP.append(UInt32(0x0000_0001), to: &payload)
        SFTP.append(UInt64(10), to: &payload)

        var reader = SFTPReader(payload)
        let attributes = try reader.readAttributes()

        XCTAssertEqual(attributes.kind, .other)
        XCTAssertFalse(attributes.isRegularFile)
    }

    func testExtendedAttributesAreSkippedWithoutLosingAlignment() throws {
        var payload = Data()
        SFTP.append(UInt32(0x0000_0004 | 0x8000_0000), to: &payload)
        SFTP.append(UInt32(0o040_755), to: &payload)
        SFTP.append(UInt32(2), to: &payload)
        SFTP.append(string: "vendor@example.com", to: &payload)
        SFTP.append(string: "value", to: &payload)
        SFTP.append(string: "another@example.com", to: &payload)
        SFTP.append(string: "value", to: &payload)
        SFTP.append(UInt32(0xDEAD_BEEF), to: &payload) // a field that must survive

        var reader = SFTPReader(payload)
        XCTAssertEqual(try reader.readAttributes().kind, .directory)
        XCTAssertEqual(try reader.readUInt32(), 0xDEAD_BEEF)
    }

    func testTruncatedFieldsThrowRatherThanTrap() {
        var short = Data()
        SFTP.append(UInt32(64), to: &short) // claims 64 bytes, supplies none
        var reader = SFTPReader(short)
        XCTAssertThrowsError(try reader.readBytes())

        var stub = SFTPReader(Data([0x01, 0x02]))
        XCTAssertThrowsError(try stub.readUInt32())
    }

    func testNameRecordsRejectTraversalAndSeparators() {
        XCTAssertFalse(SFTPChannel.isSafeEntryName(".."))
        XCTAssertFalse(SFTPChannel.isSafeEntryName("."))
        XCTAssertFalse(SFTPChannel.isSafeEntryName("../../etc/passwd"))
        XCTAssertFalse(SFTPChannel.isSafeEntryName("nested/name"))
        XCTAssertFalse(SFTPChannel.isSafeEntryName("nul\0byte"))
        XCTAssertFalse(SFTPChannel.isSafeEntryName(""))
        XCTAssertTrue(SFTPChannel.isSafeEntryName("line\nbreak.txt"))
        XCTAssertTrue(SFTPChannel.isSafeEntryName("-leading-dash"))
    }

    func testNameParsingRejectsAMismatchedPacketType() {
        let packet = SFTPPacket(type: SFTP.PacketType.status, payload: Data())
        XCTAssertThrowsError(try SFTPChannel.parseNames(packet))
    }

    func testFramingPrefixesLengthAndType() {
        let frame = SFTP.frame(type: SFTP.PacketType.initialize, payload: Data([0, 0, 0, 3]))
        XCTAssertEqual(Array(frame), [0, 0, 0, 5, 1, 0, 0, 0, 3])
    }
}

final class SSHClientOptionsTests: XCTestCase {
    @MainActor
    func testSSHArgvTerminatesOptionsBeforeDestination() {
        let options = ["-o", "BatchMode=yes"]
        XCTAssertEqual(
            SSHFileSystemProvider.checkArgv(host: "-host", clientOptions: options),
            ["/usr/bin/ssh", "-o", "BatchMode=yes", "-O", "check", "--", "-host"])
        XCTAssertEqual(
            SSHFileSystemProvider.sftpArgv(host: "-host", clientOptions: options),
            ["/usr/bin/ssh", "-o", "BatchMode=yes", "-s", "--", "-host", "sftp"])
        XCTAssertTrue(TermioStore.sshCommand(host: "-host").contains(" -- '-host'"))
    }

    /// A host whose `~/.ssh/config` forces a remote command or a tty would break
    /// the subsystem channel; the helper pins both off, and nothing else.
    func testHelperOptionsNeutraliseConfigDirectivesThatBreakSubsystems() throws {
        let options = try XCTUnwrap(SSHMux.clientOptions)
        XCTAssertTrue(options.contains("RemoteCommand=none"))
        XCTAssertTrue(options.contains("RequestTTY=no"))
        XCTAssertTrue(options.contains("ControlMaster=no"))
        XCTAssertTrue(options.contains("BatchMode=yes"))
    }

    func testControlPathBudgetHandlesLongHomesAndActualTemplate() throws {
        XCTAssertTrue(SSHMux.isControlPathSafe(directoryPath: "/tmp/termio-501-ABCDEF"))
        XCTAssertFalse(SSHMux.isControlPathSafe(directoryPath: "/" + String(repeating: "x", count: 80)))
        let template = try XCTUnwrap(SSHMux.controlPathTemplate)
        let expanded = template.replacingOccurrences(
            of: "%C", with: String(repeating: "a", count: SSHMux.controlHashBytes))
        XCTAssertLessThanOrEqual(expanded.utf8.count, SSHMux.maximumSocketPathBytes)
    }
}

final class RemotePreviewStagingTests: XCTestCase {
    @MainActor
    func testPreviewLeasesArePrivateIndependentAndCleanUp() throws {
        XCTAssertTrue(RemotePreviewStorage.isSafeComponent("hello world.swift"))
        XCTAssertTrue(RemotePreviewStorage.isSafeComponent("line\nbreak.txt"))
        XCTAssertFalse(RemotePreviewStorage.isSafeComponent("../../tmp/owned"))
        XCTAssertFalse(RemotePreviewStorage.isSafeComponent(".."))
        XCTAssertFalse(RemotePreviewStorage.isSafeComponent("nul\0byte"))

        var first: RemotePreviewLease? = try RemotePreviewStorage.stage(
            Data("first".utf8), named: "remote\nname.txt")
        let firstURL = try XCTUnwrap(first?.fileURL)
        XCTAssertEqual(first?.displayName, "remote\nname.txt")
        XCTAssertEqual(firstURL.lastPathComponent, "preview.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: firstURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o700)

        var second: RemotePreviewLease? = try RemotePreviewStorage.stage(
            Data("second".utf8), named: "safe.txt")
        let secondURL = try XCTUnwrap(second?.fileURL)
        first = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        second = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testRemoteActiveContentClassification() {
        XCTAssertTrue(FileActivation.isActiveWebContent(URL(fileURLWithPath: "/tmp/page.html")))
        XCTAssertTrue(FileActivation.isActiveWebContent(URL(fileURLWithPath: "/tmp/vector.svg")))
        XCTAssertFalse(FileActivation.isActiveWebContent(URL(fileURLWithPath: "/tmp/image.png")))
        XCTAssertFalse(FilePreviewView.usesWebFallback(
            imageDecoded: false, allowsWebFallback: false))
        XCTAssertTrue(FilePreviewView.usesWebFallback(
            imageDecoded: false, allowsWebFallback: true))
    }

    @MainActor
    func testStoreRejectsStaleRemotePresentationAndOwnsAcceptedLease() throws {
        let suite = "termio-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TermioStore(projects: [], settings: AppSettings(defaults: defaults))

        var staleLease: RemotePreviewLease? = try RemotePreviewStorage.stage(
            Data("stale".utf8), named: "stale.txt")
        let staleURL = try XCTUnwrap(staleLease?.fileURL)
        let staleGeneration = store.filePresentationGeneration
        store.openFileInEditor(URL(fileURLWithPath: "/tmp/local-winner.txt"))

        XCTAssertFalse(store.presentRemoteFilePreview(
            try XCTUnwrap(staleLease), expectedGeneration: staleGeneration))
        staleLease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))

        var acceptedLease: RemotePreviewLease? = try RemotePreviewStorage.stage(
            Data("accepted".utf8), named: "remote name.md")
        let acceptedURL = try XCTUnwrap(acceptedLease?.fileURL)
        XCTAssertTrue(store.presentRemoteFilePreview(
            try XCTUnwrap(acceptedLease),
            expectedGeneration: store.filePresentationGeneration))
        XCTAssertEqual(store.openFileDisplayName, "remote name.md")
        acceptedLease = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: acceptedURL.path))

        store.openFileURL = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: acceptedURL.path))
    }
}

final class SSHProcessRunnerTests: XCTestCase {
    func testDrainsLargeStderrWithoutDeadlock() async {
        let result = await SSHProcessRunner.run([
            "/bin/sh", "-c",
            "/usr/bin/yes x | /usr/bin/head -c 131072 >&2; printf ok",
        ], timeout: 5)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ok")
        XCTAssertEqual(result.stderr.utf8.count, SSHProcessRunner.stderrCaptureLimit)
        XCTAssertFalse(result.timedOut)
    }

    func testTimeoutTerminatesProcess() async {
        let started = Date()
        let result = await SSHProcessRunner.run(
            ["/bin/sleep", "5"],
            timeout: 0.05)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTaskCancellationTerminatesProcess() async throws {
        let started = Date()
        let task = Task {
            await SSHProcessRunner.run([
                "/bin/sh", "-c",
                "trap '' TERM; /bin/sleep 30 & printf '%s' \"$!\"; wait",
            ], timeout: 10)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let result = await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let childPID = try XCTUnwrap(
            pid_t(String(decoding: result.stdout, as: UTF8.self)))
        var childIsGone = false
        for _ in 0..<20 {
            if kill(childPID, 0) == -1, errno == ESRCH {
                childIsGone = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(childIsGone, "cancellation left a subprocess running")
    }
}
