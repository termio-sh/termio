import XCTest
@testable import termio

/// The refresh preload path (#207): `listingsForRefresh` must read, in one off-main
/// pass, every listing the outline touches on first render — the root, everything
/// previously realized, and every directory that appears as a row of one of those —
/// and `preloaded` must seed exactly that set so rendering performs no disk read.
///
/// Listings are navigated by their own keys, never by reconstructed URLs: the
/// dictionary is keyed by the URLs `contentsOfDirectory` returns (canonicalized,
/// trailing-slashed), which is also the only way production looks entries up —
/// `realized` comes from `FileNode` urls, themselves born from those entries.
final class FileNodePreloadTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileNodePreloadTests-\(UUID().uuidString)")
        // root/{alpha/{nested/{deep.txt}, a.txt}, beta/{b.txt}, top.txt}
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("alpha/nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("beta"), withIntermediateDirectories: true)
        for path in ["alpha/nested/deep.txt", "alpha/a.txt", "beta/b.txt", "top.txt"] {
            try Data().write(to: root.appendingPathComponent(path))
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func key(
        _ listings: [URL: [(url: URL, isDirectory: Bool, isSymbolicLink: Bool)]], named name: String
    ) -> URL? {
        listings.keys.first { $0.lastPathComponent == name }
    }

    func testFreshRootListsRootAndEveryTopLevelDirectory() {
        let listings = FileNode.listingsForRefresh(of: root, realized: [])
        XCTAssertEqual(
            Set(listings.keys.map(\.lastPathComponent)),
            [root.lastPathComponent, "alpha", "beta"])
        // One level ahead of the rendered rows, not the whole tree.
        XCTAssertNil(key(listings, named: "nested"))
    }

    func testRealizedDirectoriesAreRelisted() throws {
        let fresh = FileNode.listingsForRefresh(of: root, realized: [])
        let alpha = try XCTUnwrap(key(fresh, named: "alpha"))
        let nested = try XCTUnwrap(fresh[alpha]?.first { $0.isDirectory }?.url)

        // `alpha` was expanded, which realized its child `nested` (the outline
        // asks every rendered row's directory for its children): both are in the
        // realized set and both get re-listed so the swap keeps them fresh.
        let listings = FileNode.listingsForRefresh(of: root, realized: [root, alpha, nested])
        XCTAssertEqual(
            Set(listings.keys.map(\.lastPathComponent)),
            [root.lastPathComponent, "alpha", "beta", "nested"])
    }

    func testApplyReloadedReportsWhetherTheRowSetChanged() throws {
        let node = FileNode(url: root, isDirectory: true)
        let listing = try XCTUnwrap(node.children.map { _ in FileNode.listContents(of: root) })

        // Same listing again: every node adopted, nothing on screen moved.
        XCTAssertFalse(node.applyReloaded(listing))

        // A new entry changes the row set.
        try Data().write(to: root.appendingPathComponent("fresh.txt"))
        XCTAssertTrue(node.applyReloaded(FileNode.listContents(of: root)))
    }

    func testRefreshRealizationDoesNotCreepDeeper() {
        // A refresh sweep fed by what the previous sweep realized must reproduce
        // the same set — if it swept the children of realized directories, every
        // full rescan would realize one level more than the last, ballooning a
        // high-churn root without the user expanding anything.
        let first = FileNode.listingsForRefresh(of: root, realized: [])
        let node = FileNode.preloaded(url: root, isDirectory: true, listings: first)
        let second = FileNode.listingsForRefresh(of: root, realized: node.realizedDirectoryURLs())
        XCTAssertEqual(Set(second.keys), Set(first.keys))
    }

    func testVanishedRealizedDirectoryListsEmpty() {
        let gone = root.appendingPathComponent("gone")
        let listings = FileNode.listingsForRefresh(of: root, realized: [gone])
        XCTAssertEqual(listings[gone]?.isEmpty, true)
    }

    func testPreloadedSeedsListedDirectoriesAndLeavesTheRestLazy() throws {
        let fresh = FileNode.listingsForRefresh(of: root, realized: [])
        let alphaURL = try XCTUnwrap(key(fresh, named: "alpha"))
        let listings = FileNode.listingsForRefresh(of: root, realized: [root, alphaURL])
        let node = FileNode.preloaded(url: root, isDirectory: true, listings: listings)

        XCTAssertTrue(node.isLoaded)
        XCTAssertEqual(node.children?.map(\.name), ["alpha", "beta", "top.txt"])

        let alpha = try XCTUnwrap(node.children?.first { $0.name == "alpha" })
        XCTAssertTrue(alpha.isLoaded)
        let beta = try XCTUnwrap(node.children?.first { $0.name == "beta" })
        XCTAssertTrue(beta.isLoaded)

        // `nested` was never realized before this refresh, so it is not seeded —
        // it stays lazy exactly as if never expanded (no deeper creep).
        let nested = try XCTUnwrap(alpha.children?.first { $0.name == "nested" })
        XCTAssertFalse(nested.isLoaded)
    }
}
