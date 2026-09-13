import Foundation
import OSLog

/// Unified-logging categories for the Mac app. One `Logger` per subsystem area,
/// so Console.app and the `log` CLI can filter first-class:
///
///     log stream --predicate 'subsystem == "sh.termio.app" && category == "companion"'
///
/// The subsystem is taken from the bundle id at runtime rather than hardcoded, so
/// it always matches the app's real identity — release (`sh.termio.app`) or the
/// side-by-side dev build (`sh.termio.app.dev`), which lets `log stream` filter to
/// one channel.
///
/// Levels carry persistence semantics: `.debug` is memory-only (free in
/// release), `.info`/`.notice` are the default operational trail, and
/// `.error`/`.fault` are always persisted to disk. Interpolated values are
/// redacted by default — tag operational (non-sensitive) values `.public`;
/// never log the pairing token or anything that would grant access.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "sh.termio.app"
    static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
    static let pty = Logger(subsystem: subsystem, category: "pty")
    static let termiod = Logger(subsystem: subsystem, category: "termiod")
    static let companion = Logger(subsystem: subsystem, category: "companion")
    static let files = Logger(subsystem: subsystem, category: "files")
    static let issues = Logger(subsystem: subsystem, category: "issues")
    static let focus = Logger(subsystem: subsystem, category: "focus")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let markdown = Logger(subsystem: subsystem, category: "markdown")
}

/// Timing for the paths a user waits on, in the same categories `Log` already
/// defines. Each span is an `os_signpost` interval — which is what Instruments'
/// os_signpost instrument and `xctrace` group by name — *and* a line carrying
/// `elapsed_ms`, so the numbers are readable without a trace running:
///
///     log show --last 5m --predicate 'subsystem BEGINSWITH "sh.termio" && category == "app"'
///
/// Instrumented paths are the ones with a user waiting on the other end. A span
/// that only ever reads sub-millisecond is noise and should be removed rather
/// than left to make the log harder to read.
struct Trace: Sendable {
    /// Switching the sidebar's scope: the gesture, the selection move it drags
    /// behind it, and the state write at the end.
    static let workspace = Trace(Log.app)
    /// Asking a device what is running on it, and landing the answer.
    static let device = Trace(Log.termiod)
    /// The launch a user watches the Dock icon through (see `LaunchTrace`).
    static let launch = Trace(Log.app)
    /// Main-thread stalls the watchdog caught in the act (see `StallWatchdog`).
    static let stall = Trace(Log.app)

    private let logger: Logger
    private let signposter: OSSignposter

    private init(_ logger: Logger) {
        self.logger = logger
        signposter = OSSignposter(logger: logger)
    }

    /// A span begun in one place and ended in another — a `defer` inside a
    /// property observer, where wrapping the body in a closure would reindent
    /// code that has nothing to do with measuring it.
    struct Span {
        let name: StaticString
        let state: OSSignpostIntervalState
        let started: ContinuousClock.Instant
    }

    func begin(_ name: StaticString) -> Span {
        Span(name: name,
             state: signposter.beginInterval(name, id: signposter.makeSignpostID()),
             started: .now)
    }

    /// Ends `span`. `detail` is appended to the log line, never to the signpost
    /// name — the instrument groups by that name, so it has to stay constant.
    func end(_ span: Span, _ detail: String = "") {
        signposter.endInterval(span.name, span.state)
        report(span.name, detail, since: span.started)
    }

    /// Times `body` and reports it under `name`.
    @discardableResult
    func measure<Result>(
        _ name: StaticString,
        _ detail: @autoclosure () -> String = "",
        _ body: () throws -> Result
    ) rethrows -> Result {
        let span = begin(name)
        defer { end(span, detail()) }
        return try body()
    }

    /// Reports a span whose start was recorded elsewhere and whose two ends sit
    /// on different queues, so no interval can bracket it.
    func report(_ name: StaticString, _ detail: String = "", since started: ContinuousClock.Instant) {
        mark(name, detail, elapsed: started.duration(to: .now))
    }

    /// Reports a point on a timeline whose zero is not a `ContinuousClock`
    /// instant. The launch is the case that needs it: it starts at `exec`,
    /// before any Swift runs, so its origin can only arrive as a `Duration`.
    func mark(_ name: StaticString, _ detail: String = "", elapsed: Duration) {
        let label = "\(name)"
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        signposter.emitEvent(name, id: signposter.makeSignpostID())
        logger.info("""
        \(label, privacy: .public) \(detail, privacy: .public) \
        elapsed_ms=\(String(format: "%.2f", milliseconds), privacy: .public)
        """)
    }
}

/// Launch timing, measured from when the kernel created this process rather
/// than from `main`, so the numbers cover what a user watching the Dock icon
/// actually waits through. Everything before `main` — dyld, the Swift runtime,
/// static initializers — is invisible to a clock started in Swift, so the
/// origin comes from the kernel's own `p_starttime`. That is process-creation
/// metadata, not an `execve` timestamp: near enough to frame a launch of
/// several hundred milliseconds, and not the tool to settle an argument about
/// a few of them.
///
///     log show --last 5m --predicate 'subsystem BEGINSWITH "sh.termio" && category == "app"'
///
/// The marks name the phases a launch is actually spent in, so a regression
/// says *where* rather than only *how much*.
enum LaunchTrace {
    /// The launch's origin, resolved once, the first time this type is touched
    /// — which is the first line of `main`.
    ///
    /// `age` is how long the process had already been alive by then: dyld, the
    /// Swift runtime, and static initializers, none of which a clock started in
    /// Swift can see. `stamped` is the monotonic instant that reading took, and
    /// every later mark is an offset from it.
    ///
    /// Both halves are resolved in one closure, adjacently, because they are
    /// two ends of the same measurement: split across separate lazy properties,
    /// whichever Swift happens to force second leaves the `sysctl` between them
    /// counted in neither term.
    private static let origin: (age: Duration, stamped: ContinuousClock.Instant) = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, ProcessInfo.processInfo.processIdentifier]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return (.zero, .now) }
        let started = Double(info.kp_proc.p_starttime.tv_sec)
            + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        let now = Date().timeIntervalSince1970
        let stamped = ContinuousClock.now
        // Both ends are wall clock, so a clock adjustment mid-launch could in
        // principle land this negative; report zero rather than a lie.
        return (.seconds(max(0, now - started)), stamped)
    }()

    /// Records `name` as a point on the launch timeline. Cheap enough to leave
    /// in: one `os_log` line and one signpost event per phase, seven in all.
    static func mark(_ name: StaticString, _ detail: String = "") {
        Trace.launch.mark(name, detail, elapsed: origin.age + origin.stamped.duration(to: .now))
    }

    /// Runs `work` the first time the run loop is about to sleep, and marks
    /// that instant as the end of the launch.
    ///
    /// Ordering the window front does not end a launch: AppKit still owes the
    /// window layout and a commit, and the observers wired up here keep
    /// answering for a good while after the first frame reaches the screen.
    /// The first `beforeWaiting` is the first moment nothing is owed — the
    /// real end of the launch, and the only safe place to start work that
    /// would otherwise re-render everything before the user has seen it once.
    @MainActor static func whenLaunchSettles(_ work: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0
        ) { _, _ in
            MainActor.assumeIsolated {
                mark("idle")
                work()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
