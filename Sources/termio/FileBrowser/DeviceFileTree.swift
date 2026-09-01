import AppKit
import Darwin
import SwiftUI
import TermioShared

/// Owns one staged remote preview. Each lease has an atomic, private 0700
/// directory and removes only that directory when released, so concurrent
/// dev/release app processes cannot delete each other's active previews.
@MainActor
final class RemotePreviewLease {
    let fileURL: URL
    let displayName: String

    private let directoryURL: URL

    fileprivate init(fileURL: URL, displayName: String, directoryURL: URL) {
        self.fileURL = fileURL
        self.displayName = displayName
        self.directoryURL = directoryURL
    }

    deinit {
        let directory = directoryURL
        try? FileManager.default.removeItem(at: directory)
        Task { @MainActor in
            RemotePreviewStorage.didRelease(directory)
        }
    }
}

/// Where a staged file came from, and which version of it — everything a save
/// needs to put the bytes back where they were read.
///
/// Held beside the open file rather than inside the lease: the lease owns a
/// temp directory's lifetime, and this owns a different claim — that those bytes
/// *are* that file on that machine, as it stood at that moment. The version is
/// carried rather than re-read at save time, because re-reading would answer
/// about a file that may already have changed, which is the one question a save
/// must not get wrong.
struct RemoteDocument: Hashable {
    let route: TermiodRoute
    /// The checkout the write stays inside. The host confines it too — this is
    /// the client half of the same rule the tree and search are rooted by.
    let root: String
    /// The absolute path on that machine.
    let path: String
    /// `fs_file`'s `mtime`, and 0 when the host did not report one. Zero means
    /// no version, so a save carrying it claims nothing and is not checked —
    /// the honest behaviour against a daemon too old to answer.
    let mtime: UInt64
    /// The machine, for the sentence shown when a save is refused.
    let host: String

    var provider: DeviceFileProvider { DeviceFileProvider(route: route, root: root) }

    /// The same document, re-versioned after a write landed — what the next save
    /// must claim, since the file on the device now carries a new mtime.
    func read(at mtime: UInt64) -> RemoteDocument {
        RemoteDocument(route: route, root: root, path: path, mtime: mtime, host: host)
    }
}

/// The file a click on a device's tree has asked for, while its bytes are still
/// crossing the network. What the overlay draws until the editor takes over.
struct RemoteFileOpening: Equatable {
    let name: String
    let host: String
    /// The device's own sentence when the read failed. The click has to answer
    /// for itself, and an overlay that opened and then vanished would leave the
    /// same "did it hear me" question the placeholder exists to end.
    var failure: String?
}

/// What went wrong on a device, in the vocabulary the panes show.
///
/// The device describes the cause and is quoted verbatim where it has one; only
/// the cases the client decides for itself are worded here. One table rather
/// than one per pane, because the tree, the search and the file overlay are all
/// answering the same question and were drifting apart doing it.
enum RemoteFileFailure {
    static func message(
        for error: Error, fallback: String = localized("The read failed.")
    ) -> String {
        switch error {
        case DeviceFileError.unsupported:
            return localized("This device’s termiod is too old to browse files.")
        case DeviceFileError.tooLarge:
            return localized("Preview is capped at 1 MB.")
        case DeviceFileError.notRegularFile:
            return localized("Only regular files can be previewed.")
        case DeviceFileError.unsafeName:
            return localized("This device sent a name the file tree can’t show.")
        case TermiodClientError.requestFailed(let detail) where !detail.isEmpty:
            return detail
        default:
            return fallback
        }
    }
}

/// The bytes of files read from a device, so opening one a second time costs no
/// round trip.
///
/// Kept in memory rather than on disk on purpose: this is VS Code's text model
/// cache, not a sync product. It survives closing a file and switching sessions,
/// and dies with the process — nothing on this Mac has to be reconciled with the
/// machine the bytes came from.
///
/// Every hit is still revalidated (`TermioStore.openRemoteFile`): agents rewrite
/// files constantly, so a cache that answered on its own would be wrong within
/// seconds. What it removes is the *wait*, not the read.
@MainActor
enum RemoteFileContentCache {
    struct Key: Hashable {
        let route: TermiodRoute
        let root: String
        let path: String
    }

    struct Entry {
        let data: Data
        let mtime: UInt64
    }

    /// Small on both axes. A file tree is browsed a few files at a time, and the
    /// entries are whole file contents — this is a convenience for going back to
    /// what you just read, not a store worth spending memory on.
    static let capacity = 16
    static let byteBudget = 8 * 1024 * 1024

    private static var entries: [Key: Entry] = [:]
    /// Least-recently-used first, so eviction has an order to follow.
    private static var order: [Key] = []
    private static var bytes = 0

    static func entry(for key: Key) -> Entry? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry
    }

    static func store(_ entry: Entry, for key: Key) {
        if let existing = entries[key] {
            bytes -= existing.data.count
            order.removeAll { $0 == key }
        }
        entries[key] = entry
        order.append(key)
        bytes += entry.data.count
        while order.count > capacity || (bytes > byteBudget && order.count > 1) {
            guard let oldest = order.first else { break }
            order.removeFirst()
            bytes -= entries.removeValue(forKey: oldest)?.data.count ?? 0
        }
    }

    static func clear() {
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }
}

@MainActor
enum RemotePreviewStorage {
    private static var liveDirectories: Set<URL> = []

    static func stage(_ data: Data, named name: String) throws -> RemotePreviewLease {
        guard isSafeComponent(name) else { throw DeviceFileError.unsafeName }

        let parent = FileManager.default.temporaryDirectory
        var template = Array(
            parent.appendingPathComponent(
                "termio-preview-\(getuid())\(AppChannel.suffix)-XXXXXX",
                isDirectory: true
            ).path.utf8CString)
        let directoryPath: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let directoryPath else {
            throw CocoaError(.fileWriteUnknown)
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        let ext = (name as NSString).pathExtension
        let localName = ext.isEmpty ? "preview" : "preview.\(ext)"
        guard isSafeComponent(localName) else {
            try? FileManager.default.removeItem(at: directory)
            throw DeviceFileError.unsafeName
        }
        let url = directory.appendingPathComponent(localName, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent() == directory.standardizedFileURL else {
            try? FileManager.default.removeItem(at: directory)
            throw DeviceFileError.unsafeName
        }
        do {
            try data.write(to: url, options: .atomic)
            liveDirectories.insert(directory)
            return RemotePreviewLease(
                fileURL: url, displayName: name, directoryURL: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }

    fileprivate static func didRelease(_ directory: URL) {
        liveDirectories.remove(directory)
    }

    static func cleanup() {
        let directories = liveDirectories
        liveDirectories.removeAll()
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// A node in the file tree, on whichever device the checkout lives — this Mac
/// included, since the local tree reads the same `fs.list` over the unix socket.
///
/// Lazy: SwiftUI's `List(_:children:)` realizes a folder on first expand. A
/// listing cannot block the getter, so an unloaded folder answers an empty list
/// and kicks the model's async fetch; when the entries land the model publishes
/// and the rows appear. Identity is the path, so the outline keeps its expansion
/// state across a refresh even though the nodes are rebuilt (and a
/// refreshed-but-still-expanded folder re-fetches lazily).
@MainActor
final class DeviceFileNode: Identifiable {
    let path: String
    let name: String
    /// Whether this browses as a folder — resolved *through* a symlink, so a
    /// link to a directory expands like the directory it points at.
    let isDirectory: Bool
    let canPreview: Bool
    /// Whether the entry itself is a symlink, so the row can mark it.
    /// Independent of `isDirectory`: a link can point at either kind.
    let isSymbolicLink: Bool
    /// Where a symlink points, for the row's tooltip — the one fact about a
    /// link an icon can't carry. As the device read it: relative when the
    /// target sits beside the link, absolute when it escapes.
    let symbolicLinkTarget: String?
    /// Whether the checkout this node belongs to is on this Mac, which is what
    /// decides whether `url` addresses a file the Finder, the editor, a drag
    /// and the row menu may touch.
    let isOnThisMac: Bool
    /// Set on the one synthetic row a directory may carry: the note saying its
    /// listing stopped short. Not a file — it opens nothing, drags nowhere, and
    /// is the only row in the tree that is not something on the device.
    let notice: String?
    // Nonisolated: `Identifiable.id` is a nonisolated requirement, and the path
    // is immutable — no main-actor state involved.
    nonisolated var id: String { path }

    fileprivate var loadedChildren: [DeviceFileNode]?
    /// Whether a listing for this folder is on the wire with nothing to show
    /// yet. An unloaded folder answers `[]`, which draws as a folder that is
    /// genuinely empty — the one thing it is not. The row shows a spinner
    /// instead, on the folders slow enough to need one.
    fileprivate(set) var isLoading = false
    private weak var model: DeviceFileTreeModel?

    fileprivate init(
        path: String,
        name: String,
        isDirectory: Bool,
        canPreview: Bool,
        isSymbolicLink: Bool,
        symbolicLinkTarget: String?,
        isOnThisMac: Bool,
        notice: String? = nil,
        model: DeviceFileTreeModel
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.canPreview = canPreview
        self.isSymbolicLink = isSymbolicLink
        self.symbolicLinkTarget = symbolicLinkTarget
        self.isOnThisMac = isOnThisMac
        self.notice = notice
        self.model = model
    }

    /// The path in local-URL form. On a checkout on this Mac it addresses the
    /// real file; on any other device it is synthetic and only the name is
    /// meaningful — `FileIconView` keys icons off `lastPathComponent`. Use
    /// `localURL` for anything that touches disk.
    var url: URL { URL(fileURLWithPath: path) }

    /// The file this row *is*, when the row is on this Mac — what a drag, the
    /// row menu, Quick Look and the editor need, and `nil` for every checkout
    /// on another device, which is what keeps those controls hidden rather
    /// than pointed at a path this Mac does not have.
    var localURL: URL? { isOnThisMac ? url : nil }

    /// Where a symlink actually lands, absolute — for the row menu's Show
    /// Original. Nil when this isn't a link, when the link dangles, or when
    /// the checkout is on another machine, where there is nothing to reveal.
    var resolvedSymbolicLinkTarget: URL? {
        guard isSymbolicLink, let url = localURL else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        guard resolved != url, FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }

    var children: [DeviceFileNode]? {
        guard isDirectory else { return nil }
        if let loadedChildren { return loadedChildren }
        // `loadChildren` adopts a prefetched listing synchronously, so a folder
        // whose contents were fetched ahead of this click opens with its rows
        // already in it — read back here rather than published, because a
        // publish from inside a getter runs during a view update.
        model?.loadChildren(of: self)
        return loadedChildren ?? []
    }
}

/// Drives the file tree for a checkout, over its device's `fs.list`/`fs.read`
/// (`TermiodFiles.swift`).
///
/// **One model, every machine.** This Mac is a device like any other and its
/// tree reads the same way — `fs.list` over the unix socket rather than over
/// `ssh` — so nothing above this branches on where a checkout lives. The local
/// tree used to be `FileManager` plus an FSEvents watcher of its own, which is
/// two implementations of one pane and two sets of bugs; the device plane
/// already answered both halves.
///
/// The tree is **live**: it subscribes to the device's `fs:` resource
/// (`Termiod.ResourceWatch`) and re-lists only the directories a batch names and
/// the tree is actually showing — VS Code's rule, which refreshes on a file
/// event only when the event touched a *visible* item, rather than re-reading
/// the tree because something somewhere moved.
///
/// The whole-tree reload is still here, and still one request for every open
/// directory, but it is now the exception rather than the beat: a first load, a
/// `full_rescan` batch, a dropped subscription, and the refresh button. It used
/// to run on every app focus, which on a box where an agent is writing files
/// meant re-listing everything each time you came back to the window.
@MainActor
final class DeviceFileTreeModel: ObservableObject {
    enum Phase {
        case connecting
        case ready
        case failed(String)
    }

    /// The machine and the directory this tree is rooted at. Identity, not a
    /// route: the pane follows the checkout, never the road it was reached by.
    let checkout: Checkout
    let root: String
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var rootNodes: [DeviceFileNode] = []
    /// Bumped whenever a graft changed rows in place. `rootNodes` compares
    /// unchanged after an incremental re-list — same node references — so this
    /// is what tells the outline there is an update pass worth running.
    @Published private(set) var revision = 0

    /// Raised when the device reports the checkout moved: a batch, or a reset
    /// that says what is held may be stale. The Changes badge is seeded off it,
    /// which is the one thing outside this tree that has to re-read on a write —
    /// including a write to git's own metadata, which arrives as `gitMeta` and
    /// names no directory the tree is showing.
    var onCheckoutChanged: (() -> Void)?

    /// Listings fetched before anything asked for them: when a folder opens, the
    /// folders inside it are the ones about to be clicked, and asking for them
    /// while the user is still reading the rows costs a round trip nobody waits
    /// on. Consumed by the click, so an expand three levels down is three
    /// instant openings instead of three sequential waits.
    ///
    /// Deliberately not tree state — a prefetched folder is not "loaded", it is
    /// a guess held aside. Adopting one still asks the device for real, so a
    /// guess that went stale is corrected within one round trip and never
    /// survives longer than the first look at it.
    private var prefetched: [String: Termiod.DirectoryListing] = [:]
    /// Directories per prefetch, and in total. A checkout with 400 folders under
    /// one parent must not turn one expand into a listing of the whole tree; the
    /// cap is generous enough to cover the folders actually on screen.
    static let prefetchFanout = 32
    static let prefetchCeiling = 256

    private let provider: DeviceFileProvider
    private var nodesByPath: [String: DeviceFileNode] = [:]
    private var loadsInFlight: Set<String> = []
    private var prefetchesInFlight: Set<String> = []
    private var refreshing = false
    /// A refresh that arrived while one was already running, to be run after it.
    ///
    /// Dropping it instead is how the `established` reconcile lost its whole
    /// point: the subscription and the pane's first listing are both started by
    /// `onAppear` and are both one network round trip, so the subscribe landing
    /// *during* the first listing is the ordinary case, not a rare one. The
    /// reconcile then hit this guard, returned, and the listing it was waiting to
    /// correct settled at `seq == 0` behind it — the exact stale tree the signal
    /// exists to repair. Not private so a test can see the queueing.
    var refreshQueued = false
    /// The `fs:` cursor the tree's rows were last stamped at. Zero means the
    /// listing was taken while the device had no watch running, so nothing
    /// invalidates it and nothing will — the state `established` exists to
    /// repair.
    private var listedSeq: UInt64 = 0
    /// The live subscription, held while the pane is on screen. `nil` on a
    /// device whose daemon does not serve `resources`, where the tree falls back
    /// to exactly the manual refresh it always had.
    private var watch: Termiod.ResourceWatch?
    /// Holds this device's channel open, and warm, while the pane is on screen.
    /// See `Termiod.ControlPool.pin`.
    private var pin: Termiod.ControlPool.ChannelPin?

    init(checkout: Checkout, root: String) {
        self.checkout = checkout
        self.root = root
        self.provider = DeviceFileProvider(
            route: checkout.device.route, root: root)
    }

    /// The pane is on screen: keep the connection it browses over alive, so a
    /// click seconds from now does not pay to rebuild it.
    func startWarming() {
        guard pin == nil else { return }
        pin = Termiod.ControlPool.pin(route: checkout.device.route, caps: ["files"])
        guard watch == nil else { return }
        watch = provider.watch { [weak self] update in
            Task { @MainActor in self?.applyWatch(update) }
        }
    }

    /// The pane is gone or hidden. The channel goes back on the idle clock,
    /// which hangs it up two minutes later if nothing else wants it.
    func stopWarming() {
        pin = nil
        // Retiring the subscription is the point: a watch is a recursive
        // `notify` on the device, and one per pane nobody is looking at is how
        // a box runs out of inotify handles.
        watch = nil
    }

    var host: String { checkout.device.name }

    /// What the header calls the tree: the root folder's name, as the local
    /// explorer shows `root.name`. The header used to show the device instead,
    /// so every project on one box was titled with the box. The device still
    /// names the tree where it matters — the failure state, and search — and a
    /// root with no name to give (`/`, or a bare `~`) falls back to it.
    var rootName: String {
        let name = (root as NSString).lastPathComponent
        return name.isEmpty || name == "/" || name == "~" ? host : name
    }

    func node(at path: String) -> DeviceFileNode? { nodesByPath[path] }

    /// Re-lists the tree from the device. Existing rows stay up while the
    /// listing is in flight (no flash to a spinner on an app-focus reconcile);
    /// only the never-loaded state shows `connecting`.
    ///
    /// Every directory the tree is currently showing goes out in **one**
    /// `fs.list`, which is what the `paths` array is for. This used to drop
    /// `nodesByPath` and rebuild from the root alone, leaving each still-expanded
    /// folder to re-fetch itself from the `children` getter — so a tree with
    /// eight folders open cost nine sequential round trips, on every app focus.
    /// Asking for all nine together costs one.
    ///
    /// Directories that answer are replaced in place; ones the reply does not
    /// mention keep the rows they had, so a folder that failed does not blank
    /// itself while the rest of the tree refreshes around it.
    func refresh() {
        guard !refreshing else {
            refreshQueued = true
            return
        }
        refreshing = true
        refreshQueued = false
        Task {
            defer {
                refreshing = false
                // The queued one re-reads what the finished one could not know
                // it needed to. Bounded: only a settled signal queues a refresh,
                // and each is consumed before the next can be raised.
                if refreshQueued {
                    refreshQueued = false
                    refresh()
                }
            }
            // Root first: the reply is applied in the order asked, and the root's
            // children have to exist before a descendant's can be attached.
            let wanted = [root] + loadedDirectories()
            do {
                let listed = try await provider.listing(wanted)
                apply(listed.listings)
                // Tells the watch which batches this listing already reflects,
                // so a change raised *before* it lands does not send the tree
                // back to ask the device a question it just answered.
                noteListed(at: listed.seq)
                phase = .ready
                // The folders at the top of the tree are the ones about to be
                // clicked. Asking for them now costs a round trip nobody is
                // waiting on; asking for them on the click costs one they are.
                prefetchChildren(of: rootNodes)
            } catch {
                report(error, context: "list \(host):\(root)")
            }
        }
    }

    /// Applies one update from the device's `fs:` subscription.
    ///
    /// The whole point is what it does *not* do. A batch names every directory
    /// that changed anywhere under the checkout — an agent's build output, a
    /// `node_modules` install, a `git checkout` — and almost none of it is on
    /// screen. Only the directories the tree has actually realized are asked
    /// about, in one request; a batch that touches nothing realized costs
    /// nothing at all. This is `doesFileEventAffect` from VS Code's explorer
    /// (`explorerService.ts`), which walks the model and returns early unless a
    /// *visible* item was hit.
    ///
    /// `fullRescan` and `.reset` both mean the same thing — what is held may be
    /// wrong and the path set cannot be trusted — so both fall back to the
    /// whole-tree reload.
    func applyWatch(_ update: Termiod.ResourceWatch.Update) {
        switch update {
        case .established(let cursor):
            guard needsReconcile(atWatchCursor: cursor) else { return }
            refresh()
        case .reset:
            onCheckoutChanged?()
            refresh()
        case .batch(let batch):
            // Before the on-screen test below: a batch that names only git
            // metadata, or only directories nobody has expanded, still moved
            // the working tree and still moves the badge.
            onCheckoutChanged?()
            guard !batch.fullRescan else {
                refresh()
                return
            }
            let changed = directoriesToRelist(
                for: batch.paths, watchedRoot: watch?.watchedRoot)
            guard !changed.isEmpty else { return }
            Task {
                do {
                    let listed = try await provider.listing(changed)
                    apply(listed.listings)
                    noteListed(at: listed.seq)
                    Log.files.debug(
                        "\(self.host, privacy: .public) batch \(batch.seq, privacy: .public): \(batch.paths.count, privacy: .public) changed, \(changed.count, privacy: .public) on screen")
                } catch {
                    report(error, context: "relist \(host):\(changed.count) dirs")
                }
            }
        }
    }

    /// Records the cursor a listing was stamped at. Called by the tree's own
    /// loads; separate from the watch's copy because the two answer different
    /// questions — the watch's decides which batches to drop, this one decides
    /// whether the rows predate the watch entirely.
    func noteListed(at seq: UInt64) {
        listedSeq = max(listedSeq, seq)
        watch?.noteListed(at: seq)
    }

    /// Whether the rows on screen predate the subscription that has just been
    /// established, and so have to be re-read.
    ///
    /// Two ways they can, and the tree cannot tell them apart afterwards:
    ///
    /// - **The listing carries no cursor at all** (`seq == 0`): it was taken
    ///   while the device was running no watch, so nothing raised a batch for a
    ///   change in that window and nothing ever will.
    /// - **The listing is older than the cursor the watch starts at.** A
    ///   listing is stamped with the resource's cursor as it was read, and that
    ///   cursor moves for *any* watcher on the device — another pane's, a
    ///   previous one's. So a listing can carry a real, nonzero stamp and still
    ///   sit behind the batches this subscription will never replay: the watch
    ///   begins already past them.
    ///
    /// Either way one re-read closes it, and a listing taken at or after the
    /// watch's own cursor needs nothing.
    ///
    /// Reachable from a test: the window it closes is a race nothing can observe
    /// from the outside once it has been closed.
    func needsReconcile(atWatchCursor cursor: UInt64) -> Bool {
        listedSeq == 0 || listedSeq < cursor
    }

    /// Whether the device is telling this tree about changes.
    ///
    /// False on a daemon too old to grant `resources`, and while a dropped
    /// subscription is being re-established. The pane keeps its app-focus
    /// reconcile for exactly those windows — a live tree does not need it, and a
    /// tree that cannot have one still does.
    var isLive: Bool { watch?.isSubscribed ?? false }

    /// Which of a batch's changed directories this tree actually has to re-read.
    ///
    /// A batch names the directory whose *contents* moved, so a folder created
    /// or deleted arrives as a change to its parent — the row the tree draws —
    /// and nothing has to walk upward to find it. Everything else is dropped:
    /// a checkout has thousands of directories and the tree is showing a
    /// handful, so the common batch (a build wrote into `target/`, an agent
    /// rewrote a file three folders down from anything open) costs no round trip
    /// at all.
    ///
    /// Reachable from a test because it is the whole claim: the tree used to
    /// re-list every open directory whenever anything anywhere changed, and what
    /// it re-lists now is the only thing that changed about that.
    func directoriesToRelist(
        for changed: [String], watchedRoot: String? = nil
    ) -> [String] {
        let realized = Set([root] + loadedDirectories())
        var seen: Set<String> = []
        return changed.compactMap { path -> String? in
            guard let local = localPath(for: path, watchedRoot: watchedRoot) else { return nil }
            guard realized.contains(local), seen.insert(local).inserted else { return nil }
            return local
        }
    }

    /// A batch's path in the spelling this tree holds.
    ///
    /// The daemon canonicalises the root it watches, so a checkout reached
    /// through a symlink — `/home/ubuntu/x` where `/home` is a link, or a macOS
    /// `/var/folders` path, which is really `/private/var/folders` — is reported
    /// under a prefix no row in the tree carries. Swapping the watched root back
    /// for the tree's own is the whole translation: everything below it is the
    /// same relative path either way.
    private func localPath(for path: String, watchedRoot: String?) -> String? {
        guard let watchedRoot, watchedRoot != root else { return path }
        if path == watchedRoot { return root }
        let prefix = watchedRoot.hasSuffix("/") ? watchedRoot : watchedRoot + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return base + "/" + path.dropFirst(prefix.count)
    }

    /// The directories whose contents the tree is holding, deepest last, so a
    /// re-list rebuilds parents before the children hanging off them.
    ///
    /// Reachable from a test: what a refresh asks for, and the order it applies
    /// the answers in, is the whole of this change and needs no window to check.
    func loadedDirectories() -> [String] {
        nodesByPath.values
            .filter { $0.isDirectory && $0.loadedChildren != nil }
            .map(\.path)
            .sorted {
                let left = $0.count(where: { $0 == "/" })
                let right = $1.count(where: { $0 == "/" })
                return left == right ? $0 < $1 : left < right
            }
    }

    /// The folders whose contents have been fetched ahead of a click.
    ///
    /// Reachable from a test for the same reason `loadedDirectories` is: whether
    /// a guess is in hand *before* the folder is touched is the whole of the
    /// claim, and it cannot be seen from the outside once touching it is what
    /// consumes it.
    func prefetchedPaths() -> Set<String> { Set(prefetched.keys) }

    /// Grafts a batch of listings onto the tree, keeping expansion state: a
    /// directory that is still there and still has children keeps them, so the
    /// outline does not collapse under a refresh.
    func apply(_ listings: [Termiod.DirectoryListing]) {
        for listing in listings {
            // The device's per-path error — a folder deleted since it was
            // expanded. Leave the rows it had; the parent's own listing is what
            // removes the row, and that is the answer the tree should follow.
            guard listing.error == nil else { continue }
            let previous = listing.path == root
                ? Dictionary(uniqueKeysWithValues: rootNodes.map { ($0.path, $0) })
                : Dictionary(
                    uniqueKeysWithValues: (nodesByPath[listing.path]?.loadedChildren ?? [])
                        .map { ($0.path, $0) })
            let rebuilt = children(of: listing, reusing: previous)
            if listing.path == root {
                rootNodes = rebuilt
            } else {
                nodesByPath[listing.path]?.loadedChildren = rebuilt
            }
        }
        // Nodes that no longer hang off anything would otherwise keep this
        // dictionary — and the paths `loadedDirectories` asks for — growing for
        // the life of the pane.
        pruneUnreachableNodes()
        revision &+= 1
    }

    /// Asks the device for the contents of the folders in `nodes`, one level
    /// deep, so the click that opens one of them does not have to wait.
    ///
    /// Everything already loaded, already guessed at, or already on the wire is
    /// skipped, so a refresh that re-lists a tree eight folders deep does not
    /// re-prefetch what it prefetched the last time. One `fs.list` for the whole
    /// batch — the same array the refresh uses, for the same reason.
    private func prefetchChildren(of nodes: [DeviceFileNode]) {
        guard prefetched.count < Self.prefetchCeiling else { return }
        let wanted = nodes
            .filter { $0.isDirectory && $0.loadedChildren == nil }
            .map(\.path)
            .filter { prefetched[$0] == nil && !prefetchesInFlight.contains($0) }
            .prefix(Self.prefetchFanout)
        guard !wanted.isEmpty else { return }
        let paths = Array(wanted)
        prefetchesInFlight.formUnion(paths)
        Task {
            defer { prefetchesInFlight.subtract(paths) }
            // A guess that fails is not worth a word: the click that needed it
            // asks again for itself, and reports its own failure if it comes to
            // that.
            guard let listings = try? await provider.list(paths) else { return }
            for listing in listings where listing.error == nil {
                prefetched[listing.path] = listing
            }
        }
    }

    /// Drops every node the tree can no longer reach from its roots.
    private func pruneUnreachableNodes() {
        var reachable: [String: DeviceFileNode] = [:]
        var frontier = rootNodes
        while let node = frontier.popLast() {
            reachable[node.path] = node
            frontier.append(contentsOf: node.loadedChildren ?? [])
        }
        nodesByPath = reachable
        // A guess about a folder that is no longer in the tree answers a click
        // that can no longer happen.
        prefetched = prefetched.filter { reachable[$0.key] != nil }
    }

    /// Fetches one folder's entries — called from the `children` getter on first
    /// expand, so it must tolerate being re-entered on every list render while
    /// the fetch is in flight.
    ///
    /// A folder that was prefetched fills in **synchronously**, before this
    /// returns, so the getter that called it can hand the rows straight to the
    /// outline. The device is asked either way: a guess is shown, never trusted.
    fileprivate func loadChildren(of node: DeviceFileNode) {
        if let ready = prefetched.removeValue(forKey: node.path) {
            node.loadedChildren = children(of: ready)
        }
        guard !loadsInFlight.contains(node.path) else { return }
        loadsInFlight.insert(node.path)
        Task {
            defer { loadsInFlight.remove(node.path) }
            // Only when there is nothing to show meanwhile: a folder opened from
            // a prefetch already has its rows, and a spinner on it would be
            // reporting work the user has no reason to know about.
            if node.loadedChildren == nil {
                node.isLoading = true
                revision &+= 1
            }
            defer {
                if node.isLoading {
                    node.isLoading = false
                    revision &+= 1
                }
            }
            do {
                let listing = try await provider.list(node.path)
                // Reusing the nodes already there keeps whatever is expanded
                // underneath a prefetched folder when its real listing lands.
                let previous = Dictionary(
                    uniqueKeysWithValues: (node.loadedChildren ?? []).map { ($0.path, $0) })
                node.loadedChildren = children(of: listing, reusing: previous)
                revision &+= 1
                prefetchChildren(of: node.loadedChildren ?? [])
            } catch {
                // Settle the folder as empty rather than leaving it unloaded —
                // the getter would re-fire the fetch on every render otherwise.
                // The next refresh retries it.
                node.loadedChildren = []
                report(error, context: "list \(host):\(node.path)")
            }
        }
    }

    /// How this tree's files are read. The open itself belongs to the store
    /// (`TermioStore.openRemoteFile`), which is also where the search pane's
    /// opens go — one path, so the overlay, the cache and the cancellation
    /// behave the same however a file was clicked.
    var files: DeviceFileProvider { provider }

    /// Routes a failure into the pane's state: an already-loaded tree stays up
    /// (a single folder failing shouldn't blank the pane) and only an empty one
    /// fails.
    func report(_ error: Error, context: String) {
        if error is CancellationError { return }
        Log.files.error("device \(context, privacy: .public): \(String(describing: error), privacy: .public)")
        if rootNodes.isEmpty {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Builds one directory's rows.
    ///
    /// `reusing` keeps the node object for a path that survived the re-list.
    /// Node identity is the path, so the outline would keep its expansion either
    /// way — but the children hang off the *object*, and minting a fresh one
    /// would throw away every loaded subtree under it and make the tree fetch
    /// them all again, one at a time, which is the cost this refresh exists to
    /// remove.
    /// One directory's rows: its entries, and — when the device could not give
    /// the whole directory — the note saying so, last.
    ///
    /// Every path that fills a folder goes through here (the refresh graft, a
    /// lazy expand, an adopted prefetch), because the note is not decoration:
    /// without it a listing the host cut at its page size draws as a complete
    /// folder, and there is nothing on screen to tell the difference.
    private func children(
        of listing: Termiod.DirectoryListing,
        reusing existing: [String: DeviceFileNode] = [:]
    ) -> [DeviceFileNode] {
        var rows = nodes(for: listing.entries, under: listing.path, reusing: existing)
        guard listing.isShortened else { return rows }
        let path = Self.noticePath(under: listing.path)
        let sentence = localized(
            "Only the first \(listing.entries.count) items are shown — update termio on this device to list them all.")
        let note = DeviceFileNode(
            path: path, name: sentence,
            isDirectory: false, canPreview: false,
            isSymbolicLink: false, symbolicLinkTarget: nil,
            // Never this Mac's, whatever the checkout is: there is no file here
            // to drag, reveal, rename or open.
            isOnThisMac: false, notice: sentence, model: self)
        nodesByPath[path] = note
        rows.append(note)
        return rows
    }

    /// The identity of a directory's note row. A unit separator cannot be part
    /// of a name the host would list, so the outline can key on it like any
    /// other row without colliding with a real one.
    private static func noticePath(under directory: String) -> String {
        directory + "\u{1f}shortened"
    }

    private func nodes(
        for entries: [FileEntry], under parent: String,
        reusing existing: [String: DeviceFileNode] = [:]
    ) -> [DeviceFileNode] {
        let base = parent.hasSuffix("/") ? parent : parent + "/"
        // The same order and the same hidden names as the local explorer
        // (`FileEntry.sortedForTree`): the host sorts by name alone, which put
        // files above folders and left `.git` in the tree — one browser behaving
        // two ways depending on which machine the checkout is on.
        return entries.sortedForTree().map { entry in
            let path = base + entry.name
            let node: DeviceFileNode
            // Same path but a different kind — a file replaced by a folder, a
            // real folder replaced by a link to one — is a new entry: both
            // flags are immutable on the node.
            if let kept = existing[path],
               kept.isDirectory == entry.isDirectory,
               kept.isSymbolicLink == entry.isSymbolicLink {
                node = kept
            } else {
                node = DeviceFileNode(
                    path: path, name: entry.name,
                    isDirectory: entry.isDirectory,
                    canPreview: entry.isPreviewable,
                    isSymbolicLink: entry.isSymbolicLink,
                    symbolicLinkTarget: entry.symlinkTarget,
                    isOnThisMac: checkout.device.isLocal,
                    model: self)
            }
            nodesByPath[path] = node
            return node
        }
    }

    private static func message(for error: Error) -> String {
        RemoteFileFailure.message(for: error, fallback: localized("The listing failed."))
    }
}

/// What the overlay shows between the click and the bytes: the file's own header
/// — icon, name, and a spinner where the editor's save dot goes — over an empty
/// body.
///
/// The header is built to the editor's own measurements (`FileEditorView.header`)
/// on purpose. When the content lands, only the body below it changes; a
/// placeholder with a different shape would make every remote open flash a
/// second layout on its way in.
struct RemoteFileOpeningView: View {
    let opening: RemoteFileOpening
    @ObservedObject var settings: AppSettings

    /// The name is a device path's leaf, so a synthetic local URL is all the
    /// icon needs to pick the right mark. Never touched on disk.
    private var iconURL: URL {
        URL(fileURLWithPath: "/", isDirectory: true).appendingPathComponent(opening.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FileIconView(url: iconURL, size: 15, symbolSize: 13)
                    .frame(width: 16)
                Text(opening.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if opening.failure == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .help(localized("Reading from \(opening.host)…"))
                }
                Spacer()
                InspectorDetailChromeButtons()
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 32)
            .modifier(DetailHeaderTitlebarInset())
            .background(Color(nsColor: settings.terminalBackgroundColor))

            if let failure = opening.failure {
                PaneEmptyState(
                    localized("Can’t open \(opening.name)"),
                    icon: .fileQuestion,
                    message: failure
                )
            } else {
                // Empty, not a second spinner: the header already says the file
                // is on its way, and a small file lands inside a frame or two.
                Color.clear
            }
        }
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
    }
}
