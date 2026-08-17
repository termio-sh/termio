import XCTest
@testable import termio

/// `TermioStore.openTerminalLink` — the junction both link detectors end at, and
/// therefore the place the device rule has to hold. Resolving a link with no scheme
/// reads *this Mac's* disk, and `src/main.rs` exists on both boxes, so a link printed
/// by a session running elsewhere names a file there and must open nothing here.
///
/// These tests drive the resolution point directly, which is the only part of the
/// click that is testable: the click→surface mapping is AppKit geometry over a live
/// ghostty surface and stays a human check.
@MainActor
final class TerminalLinkDeviceGateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("link-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# readme".write(to: root.appendingPathComponent("README.md"), atomically: true,
                             encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeStore(with session: Session) -> TermioStore {
        let project = Project(name: "termio", path: root.path, branch: "main",
                              sessions: [session], kind: .folder)
        let defaults = UserDefaults(suiteName: "link-gate-\(UUID().uuidString)")
        return TermioStore(projects: [project],
                           settings: AppSettings(defaults: defaults ?? .standard))
    }

    private func session(sshHost: String? = nil, termiodRemoteHost: String? = nil) -> Session {
        var session = Session(title: "shell", agent: .terminal)
        session.sshHost = sshHost
        session.termiodRemoteHost = termiodRemoteHost
        return session
    }

    /// The ordinary case: a session on this Mac, a relative path that exists under its
    /// project. Read-only, because a link is a look, not a buffer to edit.
    func testALocalSessionResolvesARelativePathAgainstItsProject() {
        let local = session()
        let store = makeStore(with: local)

        store.openTerminalLink("README.md", from: local.id)

        XCTAssertEqual(store.openFileURL?.standardizedFileURL,
                       root.appendingPathComponent("README.md").standardizedFileURL)
        XCTAssertTrue(store.openFileReadOnly)
    }

    /// A termiod session runs the same in-memory backend a local shell does, so nothing
    /// about the surface says "elsewhere" — only the session does. This is the case the
    /// pre-termiod `sshHost` check could not see.
    func testATermiodSessionDoesNotResolveAgainstLocalDisk() {
        let remote = session(termiodRemoteHost: "ukvps")
        let store = makeStore(with: remote)

        store.openTerminalLink("README.md", from: remote.id)

        XCTAssertNil(store.openFileURL)
    }

    /// A plain `ssh` terminal's PTY runs here, but the shell printing the path is on the
    /// far box — same rule, other road.
    func testAnSSHSessionDoesNotResolveAgainstLocalDisk() {
        let remote = session(sshHost: "ukvps")
        let store = makeStore(with: remote)

        store.openTerminalLink("README.md", from: remote.id)

        XCTAssertNil(store.openFileURL)
    }

    /// The gate is about whose filesystem is being read, not about how the path is
    /// spelled: an absolute path from a remote box is the same mistake with a leading
    /// slash — `/etc/hosts` exists on both machines too.
    func testAnAbsolutePathFromARemoteSessionIsAlsoDeclined() {
        let remote = session(termiodRemoteHost: "ukvps")
        let store = makeStore(with: remote)

        store.openTerminalLink(root.appendingPathComponent("README.md").path, from: remote.id)

        XCTAssertNil(store.openFileURL)
    }

    /// A click we cannot attribute to a surface is a click whose device we do not know.
    /// Declined rather than assumed local — the convention the bare-path fallback set.
    func testAnUnidentifiedSurfaceIsDeclinedRatherThanAssumedLocal() {
        let store = makeStore(with: session())

        store.openTerminalLink("README.md", from: nil)

        XCTAssertNil(store.openFileURL)
    }

    /// Same for a surface whose session the store no longer holds — a stale id proves
    /// nothing about a machine.
    func testAnUnknownSessionIsDeclined() {
        let store = makeStore(with: session())

        store.openTerminalLink("README.md", from: UUID())

        XCTAssertNil(store.openFileURL)
    }
}
