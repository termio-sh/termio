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
        let fire: ([String]) -> Void
        init(_ fire: @escaping ([String]) -> Void) { self.fire = fire }
    }

    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue,
          handler: @escaping ([String]) -> Void) {
        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(Handler(handler)).toOpaque()
        context.release = { info in
            guard let info else { return }
            Unmanaged<Handler>.fromOpaque(info).release()
        }
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let raw = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)
            handler.fire((0..<count).map { String(cString: raw[$0]) })
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
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
