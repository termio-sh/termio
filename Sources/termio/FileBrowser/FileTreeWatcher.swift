import Foundation

/// A recursive filesystem watch over the file tree's root, so the explorer picks up
/// files an agent (or any outside tool) creates, renames, or deletes without waiting
/// for the manual Refresh button. Owns one `FolderEventStream` at a time, restarting
/// it when the root moves, and coalesces bursts into a single `changeToken` bump — the
/// view rebuilds the whole tree from disk on each bump, so *which* path changed doesn't
/// matter, only that something did.
@MainActor
final class FileTreeWatcher: ObservableObject {
    /// Bumped once per settled change; observed by `FileBrowserView` to rebuild.
    @Published private(set) var changeToken = 0

    private var stream: FolderEventStream?
    private var watchedPath: String?
    private var debounce: DispatchWorkItem?

    /// (Re)starts the recursive watch on `path`, tearing down any prior watch. A nil
    /// path (nothing selected) just stops watching. A no-op when the path is unchanged,
    /// so the every-render `onChange`/`onAppear` calls don't churn the stream.
    func watch(_ path: String?) {
        guard path != watchedPath else { return }
        watchedPath = path
        debounce?.cancel()
        stream = nil
        guard let path else { return }
        // Deliver on the main queue so `scheduleTick` can safely touch this main-actor
        // object; FSEvents' own latency window gives a first coalescing pass.
        stream = FolderEventStream(paths: [path], latency: 0.3, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTick() }
        }
    }

    /// A second, short coalescing step beyond FSEvents' latency, so a storm of
    /// callbacks (a git checkout, an npm install) collapses into one tree rebuild
    /// shortly after the disk settles rather than one per callback.
    private func scheduleTick() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.changeToken += 1 }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
