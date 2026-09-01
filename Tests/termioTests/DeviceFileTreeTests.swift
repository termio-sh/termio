import XCTest
import TermioShared
@testable import termio

/// What the file tree asks a device for, and what it does with the answer —
/// pinned without a device, because every claim here is about the model's own
/// bookkeeping.
///
/// The tree used to drop every node it held and re-list the root alone, leaving
/// each still-expanded folder to fetch itself from the `children` getter — one
/// SSH round trip per open folder, on every app focus. It now names them all in
/// one `fs.list` and grafts the replies onto the nodes already on screen.
///
/// One model serves every machine, this Mac included. What still divides is
/// what may be *written*, and that divides on one fact per node — whether it
/// has a URL this process can open.
@MainActor
final class DeviceFileTreeTests: XCTestCase {
    private let root = "/srv/api"

    private func model() -> DeviceFileTreeModel {
        // A route nothing will answer on: every assertion here is about what the
        // model does with listings it is handed, never about fetching them.
        DeviceFileTreeModel(
            checkout: Checkout(
                device: KnownDevice(alias: "test-box", deviceID: nil), root: root),
            root: root)
    }

    /// The header names the folder, as the local explorer does — not the device,
    /// which titled every project on one box with the box's name.
    func testHeaderNamesTheRootFolderNotTheDevice() {
        XCTAssertEqual(model().rootName, "api")
        let home = DeviceFileTreeModel(
            checkout: Checkout(
                device: KnownDevice(alias: "test-box", deviceID: nil), root: "/"),
            root: "/")
        XCTAssertEqual(home.rootName, "test-box")
    }

    private func listing(
        _ path: String, _ entries: [(String, FileEntry.Kind)], error: String? = nil,
        isShortened: Bool = false
    ) -> Termiod.DirectoryListing {
        Termiod.DirectoryListing(
            path: path,
            entries: entries.map { FileEntry(name: $0.0, kind: $0.1) },
            error: error,
            isShortened: isShortened)
    }

    /// The ask: the root plus every directory whose contents the tree is holding,
    /// parents before children so a graft never runs ahead of the node it hangs
    /// off.
    func testARefreshNamesEveryDirectoryTheTreeIsShowing() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory), ("README.md", .file)])])
        XCTAssertEqual(tree.loadedDirectories(), [], "nothing under the root is open yet")

        tree.apply([listing("\(root)/src", [("deep", .directory)])])
        tree.apply([listing("\(root)/src/deep", [("x.swift", .file)])])

        XCTAssertEqual(
            tree.loadedDirectories(), ["\(root)/src", "\(root)/src/deep"],
            "shallowest first, so a parent's rows exist before its child's land")
    }

    /// The graft: a folder that is still there keeps the node it had, and so
    /// keeps everything loaded underneath it. Minting a fresh node would leave
    /// the outline expanded over an empty folder and send the tree back to
    /// fetching each level again — the exact cost this refresh removes.
    func testAnOpenFolderKeepsItsSubtreeAcrossARefresh() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory)])])
        tree.apply([listing("\(root)/src", [("x.swift", .file)])])

        let before = try? XCTUnwrap(tree.node(at: "\(root)/src"))
        tree.apply([listing(root, [("src", .directory), ("new.md", .file)])])
        let after = try? XCTUnwrap(tree.node(at: "\(root)/src"))

        XCTAssertTrue(before === after, "the surviving folder keeps its node")
        XCTAssertEqual(after?.children?.map(\.name), ["x.swift"])
        XCTAssertEqual(tree.rootNodes.map(\.name), ["src", "new.md"])
        XCTAssertEqual(tree.loadedDirectories(), ["\(root)/src"],
                       "and is still counted as loaded, so it re-lists in the batch")
    }

    /// A name that changed kind is a different thing wearing the same path, and
    /// must not inherit the old node's children.
    func testAPathThatChangedKindIsRebuilt() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory)])])
        tree.apply([listing("\(root)/src", [("x.swift", .file)])])
        let directory = tree.node(at: "\(root)/src")

        tree.apply([listing(root, [("src", .file)])])

        let file = tree.node(at: "\(root)/src")
        XCTAssertFalse(directory === file)
        XCTAssertNil(file?.children, "a file has no children to inherit")
    }

    /// `fs.list` fails one path at a time. A folder the device refused keeps the
    /// rows it had rather than blanking, so one deleted directory does not empty
    /// the pane around it.
    func testAPathTheDeviceRefusedLeavesItsRowsAlone() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory)])])
        tree.apply([listing("\(root)/src", [("x.swift", .file)])])

        tree.apply([
            listing(root, [("src", .directory)]),
            listing("\(root)/src", [], error: "No such file or directory"),
        ])

        XCTAssertEqual(tree.node(at: "\(root)/src")?.children?.map(\.name), ["x.swift"])
    }

    /// A folder that is gone takes its subtree with it, or the paths a refresh
    /// asks for would grow for the life of the pane.
    func testAFolderThatDisappearedStopsBeingAskedFor() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory), ("docs", .directory)])])
        tree.apply([listing("\(root)/src", [("x.swift", .file)])])
        tree.apply([listing("\(root)/docs", [("y.md", .file)])])
        XCTAssertEqual(tree.loadedDirectories().count, 2)

        tree.apply([listing(root, [("docs", .directory)])])

        XCTAssertNil(tree.node(at: "\(root)/src"))
        XCTAssertEqual(tree.loadedDirectories(), ["\(root)/docs"])
    }

    // MARK: - What a live batch re-lists

    /// The rule the subscription exists for: a batch names every directory that
    /// changed under the checkout, and the tree asks about the ones it is
    /// actually drawing. This is VS Code's `doesFileEventAffect` — refresh on a
    /// file event only when a *visible* item was hit.
    func testABatchOnlyRelistsDirectoriesTheTreeIsShowing() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory), ("target", .directory)])])
        tree.apply([listing("\(root)/src", [("app.swift", .file)])])

        XCTAssertEqual(
            tree.directoriesToRelist(for: ["\(root)/src"]), ["\(root)/src"],
            "an open folder that changed is re-read")
        XCTAssertEqual(
            tree.directoriesToRelist(for: ["\(root)"]), ["\(root)"],
            "the root is always realized")
    }

    /// The case that used to cost a full re-list and now costs nothing: an agent
    /// writing into a directory nobody has expanded. `target` is a row on screen,
    /// but its *contents* are not — so a change inside it is not news.
    func testABatchUnderAnUnopenedFolderAsksForNothing() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory), ("target", .directory)])])
        tree.apply([listing("\(root)/src", [("app.swift", .file)])])

        XCTAssertEqual(
            tree.directoriesToRelist(for: [
                "\(root)/target",
                "\(root)/target/debug",
                "\(root)/src/generated/nested",
            ]),
            [],
            "nothing realized was touched, so the device is not asked anything")
    }

    /// A batch repeats a directory when several files under it moved inside one
    /// quiet window. The tree asks once — `fs.list` is batched, and naming a path
    /// twice would list it twice.
    func testARepeatedDirectoryIsAskedForOnce() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory)])])
        tree.apply([listing("\(root)/src", [("app.swift", .file)])])

        XCTAssertEqual(
            tree.directoriesToRelist(for: [
                "\(root)/src", "\(root)/src", "\(root)/nope", "\(root)",
            ]),
            ["\(root)/src", "\(root)"],
            "deduplicated, in the order the batch named them")
    }

    /// A folder that was open and has since been collapsed out of the tree stops
    /// being asked about — the same pruning `loadedDirectories` already does for
    /// the whole-tree refresh.
    func testACollapsedFolderIsNoLongerRelisted() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory)])])
        tree.apply([listing("\(root)/src", [("app.swift", .file)])])
        XCTAssertEqual(tree.directoriesToRelist(for: ["\(root)/src"]), ["\(root)/src"])

        // The folder is gone from the root's listing, so `apply` prunes it.
        tree.apply([listing(root, [("docs", .directory)])])
        XCTAssertEqual(
            tree.directoriesToRelist(for: ["\(root)/src"]), [],
            "a path the tree no longer holds is not worth a round trip")
    }

    // MARK: - The window between the first listing and the first batch

    /// A listing taken before the device had any watch is stamped `seq == 0`.
    /// Anything that changed between it and the subscription raised no batch
    /// anybody was subscribed for, and the watch then starts at a cursor already
    /// past it — so nothing later repairs the tree. `established` is when that
    /// has to be re-read.
    func testATreeListedBeforeTheWatchExistedReconcilesWhenItArrives() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory)])])
        XCTAssertTrue(
            tree.needsReconcile(atWatchCursor: 0),
            "nothing has stamped these rows, so they may already be stale")
    }

    /// The opposite, which is the common case and must not cost a second full
    /// listing: the load happened under this subscription's own cursor, so it
    /// already reflects everything the watch could replay.
    func testATreeListedUnderThisWatchNeedsNoReconcile() {
        let tree = model()
        tree.noteListed(at: 42)
        XCTAssertFalse(
            tree.needsReconcile(atWatchCursor: 42),
            "a listing at the watch's own cursor already reflects it")
        XCTAssertFalse(
            tree.needsReconcile(atWatchCursor: 7),
            "and one taken after it is newer still")
    }

    /// A stamped listing is not automatically a *current* one. The `fs:` cursor
    /// moves for any watcher on the device — another pane's, or one this pane
    /// held a moment ago — so a listing can carry a real, nonzero stamp and
    /// still sit behind the batches this subscription begins past. Reading the
    /// stamp as "somebody was watching, so this is fresh" is what left the tree
    /// permanently stale.
    func testAListingOlderThanTheWatchsCursorStillReconciles() {
        let tree = model()
        tree.noteListed(at: 5)
        XCTAssertTrue(
            tree.needsReconcile(atWatchCursor: 9),
            "batches 6…9 raised no event this watch will replay")
    }

    /// A tree with no subscription — a daemon too old to grant `resources` —
    /// keeps the app-focus reconcile it always had. Dropping that unconditionally
    /// left those trees with nothing but the refresh button.
    func testATreeWithNoSubscriptionIsNotLive() {
        XCTAssertFalse(
            model().isLive,
            "no watch means the pane's own reconcile is still the only signal")
    }

    /// The bug the `established` reconcile shipped with: a refresh raised while
    /// one is in flight used to be dropped on the floor. At startup that is the
    /// ordinary case — `onAppear` starts the subscription and the first listing
    /// together, both one round trip — so the reconcile hit the guard, returned,
    /// and the listing it was meant to correct settled at `seq == 0` behind it.
    func testARefreshRaisedDuringOneIsQueuedRatherThanDropped() {
        let tree = model()
        XCTAssertFalse(tree.refreshQueued)

        tree.refresh()   // takes the guard synchronously; its listing never answers
        tree.refresh()   // this is the reconcile, and it must not vanish

        XCTAssertTrue(
            tree.refreshQueued,
            "the second refresh is held for after the first, not discarded")
    }

    // MARK: - Which rows this Mac may write

    private func localModel(root: String) -> DeviceFileTreeModel {
        DeviceFileTreeModel(
            checkout: Checkout(device: .thisMac, root: root), root: root)
    }

    /// The gate every write-shaped control hangs off. A checkout on this Mac
    /// addresses real files, so a row drags, opens in the editor and carries the
    /// row menu; one on another device has no URL this process could act on, and
    /// the controls are absent rather than present and refusing (Stage 9's gate:
    /// unsupported controls hidden, not inert).
    func testOnlyACheckoutOnThisMacGivesItsRowsAURL() {
        let here = localModel(root: "/Users/me/code/api")
        here.apply([listing("/Users/me/code/api", [("README.md", .file)])])
        let local = here.node(at: "/Users/me/code/api/README.md")
        XCTAssertEqual(local?.localURL?.path, "/Users/me/code/api/README.md")

        let there = model()
        there.apply([listing(root, [("README.md", .file)])])
        let device = there.node(at: "\(root)/README.md")
        XCTAssertNil(device?.localURL, "this Mac has no such file to drag, reveal or rename")
        XCTAssertEqual(
            device?.url.lastPathComponent, "README.md",
            "the name still reaches the icon, which is all the synthetic URL is for")
    }

    /// A link to a directory browses as the directory it points at — the Finder's
    /// and the VS Code explorer's rule, and what this repo's own
    /// `.claude/skills → ../skills` needs. The row still knows it is a link, which
    /// is what swaps its glyph and arms its tooltip.
    func testASymlinkedFolderIsAFolderAndStillReadsAsALink() {
        let tree = localModel(root: "/Users/me/code/api")
        tree.apply([Termiod.DirectoryListing(
            path: "/Users/me/code/api",
            entries: [
                FileEntry(
                    name: "skills", kind: .symlink,
                    target: .directory, symlinkTarget: "../skills"),
                FileEntry(name: "loose", kind: .symlink, target: nil, symlinkTarget: "/etc"),
            ],
            error: nil)])

        let linked = tree.node(at: "/Users/me/code/api/skills")
        XCTAssertEqual(linked?.isDirectory, true, "it expands like what it points at")
        XCTAssertEqual(linked?.isSymbolicLink, true)
        XCTAssertEqual(linked?.symbolicLinkTarget, "../skills")

        let loose = tree.node(at: "/Users/me/code/api/loose")
        XCTAssertEqual(
            loose?.isDirectory, false,
            "a link the device would refuse to list offers no disclosure triangle")
    }

    /// Folders sort above files, and a symlinked folder sorts with the folders —
    /// the ordering follows what a row *browses as*, not what kind the host
    /// stamped on it.
    func testASymlinkedFolderSortsWithTheFolders() {
        let tree = localModel(root: "/r")
        tree.apply([Termiod.DirectoryListing(
            path: "/r",
            entries: [
                FileEntry(name: "a.txt", kind: .file),
                FileEntry(name: "zlink", kind: .symlink, target: .directory),
            ],
            error: nil)])
        XCTAssertEqual(tree.rootNodes.map(\.name), ["zlink", "a.txt"])
    }

    // MARK: - A listing that stopped short

    /// A directory the device could only answer part of says so, in itself.
    ///
    /// Only an old daemon produces one — it pages by offset, which the keyset
    /// cursor replaced, so the listing stops at its first page. Logging that was
    /// not enough: the flag died at the client boundary and the tree drew two
    /// thousand entries as a folder. On screen a prefix of a directory is a
    /// directory, and the rows themselves can never say otherwise.
    func testAShortenedListingCarriesANoteIntoTheTree() {
        let tree = localModel(root: "/r")
        tree.apply([listing(
            "/r", [("a", .file), ("b", .file)], isShortened: true)])

        let rows = tree.rootNodes
        XCTAssertEqual(rows.map(\.name).prefix(2).map { $0 }, ["a", "b"])
        let note = try? XCTUnwrap(rows.last)
        XCTAssertNotNil(note?.notice, "the folder has to say its listing stopped short")
        XCTAssertEqual(note?.isDirectory, false)
        XCTAssertEqual(note?.canPreview, false)
        XCTAssertNil(note?.localURL, "there is no file here to drag, reveal or open")
    }

    /// The ordinary complete listing carries no note — every row is a real one.
    func testACompleteListingCarriesNoNote() {
        let tree = localModel(root: "/r")
        tree.apply([listing("/r", [("a", .file)])])
        XCTAssertEqual(tree.rootNodes.count, 1)
        XCTAssertNil(tree.rootNodes.first?.notice)
    }

    /// And the note goes away once the device can answer the whole directory —
    /// a re-list must not leave the previous answer's note behind.
    func testTheNoteClearsWhenTheListingComesBackWhole() {
        let tree = localModel(root: "/r")
        tree.apply([listing("/r", [("a", .file)], isShortened: true)])
        XCTAssertNotNil(tree.rootNodes.last?.notice)

        tree.apply([listing("/r", [("a", .file), ("b", .file)])])
        XCTAssertEqual(tree.rootNodes.map(\.name), ["a", "b"])
        XCTAssertTrue(tree.rootNodes.allSatisfy { $0.notice == nil })
    }
}
