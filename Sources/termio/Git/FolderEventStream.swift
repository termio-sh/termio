import CoreServices
import Foundation

/// A recursive FSEvents watch over one or more directory trees. `BranchModel`'s
/// `DispatchSourceFileSystemObject` watches a single directory's own entries; the git
/// pane needs "anything under the worktree (or its git dir) changed", which is exactly
/// what FSEvents provides. Events are coalesced by the stream's own latency window and
/// delivered on `queue` as the raw changed paths.
final class FolderEventStream {
    private var stream: FSEventStreamRef?

    /// Retained by the stream context so the C callback can reach the Swift closure;
    /// released by the context's `release` hook when the stream is invalidated.
    private final class Handler {
        let fire: ([String], [FSEventStreamEventFlags]) -> Void
        init(_ fire: @escaping ([String], [FSEventStreamEventFlags]) -> Void) { self.fire = fire }
    }

    /// `handler` also receives each path's event flags: when the kernel or user-space
    /// queue overflowed, FSEvents sets `kFSEventStreamEventFlagMustScanSubDirs` and
    /// the path means "anything under here may have changed" — a consumer applying
    /// events incrementally must widen to a rescan or go silently stale.
    /// `handler` is `@Sendable` because FSEvents calls it on `queue`, which is rarely the
    /// main one. Without it a closure written inside a `@MainActor` type silently *inherits*
    /// that isolation, compiles clean, and traps the moment an event arrives — the Swift 6
    /// executor check turns the first main-actor touch into `SIGTRAP`, killing the app.
    /// `@Sendable` forbids the inheritance, so the hop back is the caller's explicit job and
    /// forgetting it is a compile error rather than a crash in someone's editor.
    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue,
          handler: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void) {
        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(Handler(handler)).toOpaque()
        context.release = { info in
            guard let info else { return }
            Unmanaged<Handler>.fromOpaque(info).release()
        }
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let raw = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)
            handler.fire(
                (0..<count).map { String(cString: raw[$0]) },
                (0..<count).map { eventFlags[$0] }
            )
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            // WatchRoot is what makes FSEvents deliver `RootChanged` when a watched
            // path itself is moved or deleted — without it consumers checking that
            // flag (the file tree's full-rescan escalation) would never see it.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
