import AppKit
import GhosttyTerminal
import IOSurface
import ObjectiveC

/// Dev-only instrumentation for the "the pane flashes once while an agent is
/// working" report: a frame older than the one already on screen landing on the
/// layer, which reads as the text area briefly rolling backwards.
///
/// ghostty presents through a `CALayer` subclass it registers at runtime as
/// `IOSurfaceLayer` (`src/renderer/metal/IOSurfaceLayer.zig`), and there are two
/// ways a frame reaches it:
///
/// - the renderer thread's command-buffer completion handler, which hands the
///   surface to the main queue as a block (`setSurface`), and
/// - the layer's own `display` pass, which renders inline on the main thread and
///   assigns `contents` directly (`setSurfaceSync`).
///
/// Neither path carries a frame number. The async one drops only *wrong-sized*
/// surfaces, so a block queued before an inline present runs after it and
/// overwrites a newer frame with an older one. Whether that actually happens
/// depends on how deep the main queue is at that moment, which is why the glitch
/// comes and goes.
///
/// The probe records rather than judges. Every present is written with the raw
/// identity of the surface that landed, so the frame order can be rebuilt exactly,
/// offline — an earlier version inferred the swap chain's cycle live and was wrong
/// three different ways, because presents that arrive within the same millisecond
/// can land in any order and naming the cycle from them records a permutation.
/// Each `display` pass goes on the same timeline, since the inline render is the
/// only path that can break the ordering, as do layout passes on the terminal
/// views, which is where two other embedders traced their own flicker.
///
/// Dev channel only, and inert until the palette's "Debug: Start Present Trace"
/// arms it — nothing is interposed before that. Once armed it costs a lock and a
/// dictionary lookup per present, writes the raw frame order to `tracePath`, and
/// dumps the surrounding window to `logPath` whenever the order breaks or a target
/// is rebuilt at a new size.
enum TerminalPresentProbe {
    /// Where dumps land, in addition to stdout — the app is usually launched from
    /// Finder, where stdout goes nowhere.
    static let logPath = "/tmp/termio-dev-present.log"

    /// The continuous trace, kept out of `logPath` so the anomaly dumps there stay
    /// readable. One line per present, buffered.
    static let tracePath = "/tmp/termio-dev-present-trace.log"

    /// Installs the probe once the class exists. ghostty registers `IOSurfaceLayer`
    /// lazily, on the first surface it builds, so this retries until a terminal has
    /// come up rather than giving up at launch.
    static func install() {
        guard AppChannel.isDev else { return }
        // Only the triggers are registered here. The interposed methods are not
        // installed until a trace is started: they sit on ghostty's render layer and
        // on the terminal view's layout path, and the dev channel is the build every
        // other piece of UI work is done in — one carrying live interposition all the
        // time would be able to contaminate an unrelated investigation.
        //
        // Same trigger shape as `DebugWindowSnapshot`, so a dump can be taken
        // without focusing the app:
        //   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("termio.dev.presentDump"), object: nil, userInfo: nil, deliverImmediately: true)'
        DistributedNotificationCenter.default().addObserver(
            Trigger.shared, selector: #selector(Trigger.fire),
            name: Notification.Name("termio.dev.presentDump"), object: nil,
            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            Trigger.shared, selector: #selector(Trigger.toggleTrace),
            name: Notification.Name("termio.dev.presentTrace"), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    // @unchecked: stateless — it exists only as a selector target, and the probe
    // state it reaches carries its own lock.
    private final class Trigger: NSObject, @unchecked Sendable {
        static let shared = Trigger()
        @objc func fire(_: Notification) {
            TerminalPresentProbe.dump(reason: "triggered dump")
        }

        @objc func toggleTrace(_: Notification) {
            TerminalPresentProbe.setTracing(!TerminalPresentProbe.isTracing)
        }
    }

    /// Writes the recorded window to stdout and the log file. Bound to the
    /// palette's "Debug: Dump Present Order" so it can be run the moment a flash is
    /// seen, whether or not the automatic check fired.
    static func dump(reason: String) {
        guard state.isInstalled else {
            emit("nothing recorded — start a present trace first")
            return
        }
        state.dump(reason: reason)
    }

    /// Turns the continuous trace on or off. The slot bookkeeping below is an
    /// *inference* — it labels targets by the order their IOSurfaces first appear,
    /// which a resize can permute. The trace writes the raw surface identity of
    /// every present instead, so the frame order can be reconstructed after the
    /// fact without trusting that inference.
    @discardableResult
    static func setTracing(_ enabled: Bool) -> Bool {
        guard AppChannel.isDev else { return false }
        if enabled { arm(attemptsLeft: 60) }
        state.setTracing(enabled)
        emit(enabled ? "trace ON — every present is being written" : "trace OFF")
        return enabled
    }

    /// Interposes on the render and layout paths. ghostty registers its
    /// `IOSurfaceLayer` class lazily, on the first surface it builds, so this retries
    /// until a terminal has come up rather than giving up on the first try.
    private static func arm(attemptsLeft: Int) {
        guard !state.isInstalled else { return }
        if swizzle() {
            emit("armed — swap-chain order and layout churn are now recorded")
            return
        }
        guard attemptsLeft > 0 else {
            emit("not armed: ghostty never registered an IOSurfaceLayer class")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            arm(attemptsLeft: attemptsLeft - 1)
        }
    }

    static var isTracing: Bool { state.isTracing }

    fileprivate typealias SetContentsIMP = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    fileprivate typealias DisplayIMP = @convention(c) (AnyObject, Selector) -> Void
    fileprivate typealias SetFrameSizeIMP = @convention(c) (AnyObject, Selector, NSSize) -> Void

    fileprivate static let state = ProbeState()

    fileprivate static func emit(_ message: String) {
        emit(block: [message])
    }

    fileprivate static func emit(block: [String]) {
        guard !block.isEmpty else { return }
        let text = block.map { "[termio][present] \($0)" }.joined(separator: "\n")
        print(text)
        append(text + "\n", to: logPath)
    }

    private static func swizzle() -> Bool {
        guard !state.isInstalled,
              let layerClass = objc_getClass("IOSurfaceLayer") as? AnyClass else { return false }

        // `contents` is where both present paths converge, and `IOSurfaceLayer`
        // does not override it — so the interposed method is *added* to the
        // subclass and forwards to CALayer's own implementation. Adding it to the
        // subclass rather than swizzling CALayer keeps every other layer in the app
        // untouched.
        let setContents = #selector(setter: CALayer.contents)
        guard let inherited = class_getMethodImplementation(CALayer.self, setContents) else {
            return false
        }
        originalSetContents = unsafeBitCast(inherited, to: SetContentsIMP.self)
        let setContentsTrampoline: SetContentsIMP = { layer, selector, contents in
            TerminalPresentProbe.state.recordPresent(layer: layer, contents: contents)
            originalSetContents?(layer, selector, contents)
        }
        guard class_addMethod(
            layerClass,
            setContents,
            unsafeBitCast(setContentsTrampoline, to: IMP.self),
            "v@:@"
        ) else {
            originalSetContents = nil
            return false
        }

        // The embedder's own layout churn. Two other apps embedding libghostty
        // (cmux #1625, #2279) traced their terminal flicker to exactly this and
        // confirmed upstream Ghostty does not do it — so a capture has to show
        // whether a burst of layout passes coincides with the flash, not just what
        // the present path did.
        if let method = class_getInstanceMethod(TerminalView.self, #selector(NSView.layout)) {
            originalLayout = unsafeBitCast(
                method_getImplementation(method), to: DisplayIMP.self
            )
            let trampoline: DisplayIMP = { view, selector in
                TerminalPresentProbe.state.recordLayout(view: view, kind: "layout")
                originalLayout?(view, selector)
            }
            method_setImplementation(method, unsafeBitCast(trampoline, to: IMP.self))
        }
        if let method = class_getInstanceMethod(
            TerminalView.self, #selector(NSView.setFrameSize(_:))
        ) {
            originalSetFrameSize = unsafeBitCast(
                method_getImplementation(method), to: SetFrameSizeIMP.self
            )
            let trampoline: SetFrameSizeIMP = { view, selector, size in
                TerminalPresentProbe.state.recordLayout(
                    view: view, kind: "setFrameSize \(Int(size.width))x\(Int(size.height))"
                )
                originalSetFrameSize?(view, selector, size)
            }
            method_setImplementation(method, unsafeBitCast(trampoline, to: IMP.self))
        }

        // `display` is ghostty's own override — the entry point of the inline,
        // main-thread render. Replacing it in place marks the presents that happen
        // underneath as synchronous.
        let display = #selector(CALayer.display)
        if let method = class_getInstanceMethod(layerClass, display) {
            originalDisplay = unsafeBitCast(
                method_getImplementation(method), to: DisplayIMP.self
            )
            let displayTrampoline: DisplayIMP = { layer, selector in
                TerminalPresentProbe.state.beginDisplay(layer: layer)
                originalDisplay?(layer, selector)
                TerminalPresentProbe.state.endDisplay()
            }
            method_setImplementation(
                method, unsafeBitCast(displayTrampoline, to: IMP.self)
            )
        }

        state.isInstalled = true
        return true
    }

    fileprivate static func append(_ text: String, to path: String) {
        guard let data = text.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        do {
            if FileManager.default.fileExists(atPath: path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            // Never let diagnostics take the app down, and never swallow the reason
            // either — stdout already carries the line itself.
            print("[termio][present] could not append to \(path): \(error)")
        }
    }
}

// The interposed methods run wherever ghostty presents from, so the saved
// implementations live at file scope and the shared state carries its own lock
// rather than an actor hop that would change the timing the probe measures.
private nonisolated(unsafe) var originalSetContents: TerminalPresentProbe.SetContentsIMP?
private nonisolated(unsafe) var originalDisplay: TerminalPresentProbe.DisplayIMP?
private nonisolated(unsafe) var originalLayout: TerminalPresentProbe.DisplayIMP?
private nonisolated(unsafe) var originalSetFrameSize: TerminalPresentProbe.SetFrameSizeIMP?

private final class ProbeState: @unchecked Sendable {
    /// One entry per present, kept in a ring so a dump taken after a flash still
    /// has the run-up to it.
    private struct Event {
        let at: TimeInterval
        let layer: Int
        let isSync: Bool
        let isMainThread: Bool
        let gapMilliseconds: Double
        let note: String?
    }

    /// Per-layer, because every terminal surface owns its own swap chain and its
    /// own round-robin cycle.
    private struct LayerState {
        let tag: Int
        var knownSurfaces: Set<UnsafeRawPointer> = []
        var lastPresentAt: TimeInterval?
        var lastSurfaceSize: String?
        var presents = 0
        var displays = 0
        var resizes = 0
        var maxGapMilliseconds: Double = 0
    }

    private static let eventCapacity = 256
    private static let dumpWindow = 32
    private static let dumpCooldown: TimeInterval = 2
    private static let displayLineCap = 40

    private let lock = NSLock()
    private var layers: [ObjectIdentifier: LayerState] = [:]
    private var events: [Event] = []
    private var displayDepth = 0
    private var lastDumpAt: TimeInterval = 0
    private var suppressedDumps = 0

    private var tracing = false
    private var traceBuffer: [String] = []
    private var viewTags: [ObjectIdentifier: Int] = [:]
    private var layoutPasses = 0
    private var lastTraceFlushAt: TimeInterval = 0
    private var autoDumps = 0
    private var tracedLines = 0

    /// Automatic dumps stop after this many. A repeating fault would otherwise
    /// write ~38 lines every cooldown for as long as the app runs, which is how an
    /// earlier log reached thousands of lines and became unreadable. The trace keeps
    /// running, and the palette can still take a dump by hand.
    private static let autoDumpBudget = 8

    /// Roughly 20 MB. At 120 Hz across three panes the trace writes ~360 lines a
    /// second, so a trace left on overnight would otherwise fill the disk.
    private static let traceLineBudget = 300_000

    private static let traceFlushThreshold = 512
    /// Also flush on a timer, so a quiet capture is readable while it is still
    /// running rather than only once the buffer fills or tracing stops.
    private static let traceFlushInterval: TimeInterval = 2

    /// Whether the methods have been interposed. Only ever read and written on the
    /// main thread, while arming.
    var isInstalled = false

    var isTracing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracing
    }

    func setTracing(_ enabled: Bool) {
        lock.lock()
        tracing = enabled
        if enabled { tracedLines = 0 }
        let pending = enabled ? [] : traceBuffer
        traceBuffer = []
        lock.unlock()
        flush(pending)
    }

    private func flush(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        TerminalPresentProbe.append(
            lines.joined(separator: "\n") + "\n", to: TerminalPresentProbe.tracePath
        )
        lock.lock()
        tracedLines += lines.count
        let overBudget = tracing && tracedLines >= Self.traceLineBudget
        if overBudget { tracing = false }
        let total = tracedLines
        lock.unlock()
        if overBudget {
            TerminalPresentProbe.emit(
                "trace stopped at \(total) lines — budget reached, start it again if needed"
            )
        }
    }

    func beginDisplay(layer: AnyObject) {
        lock.lock()
        displayDepth += 1
        let key = ObjectIdentifier(layer)
        let tag = layers[key]?.tag ?? layers.count
        layers[key, default: LayerState(tag: tag)].displays += 1
        let count = layers[key]?.displays ?? 0
        // The inline, main-thread render is the only path that can present out of
        // order, so it belongs on the same timeline as the presents rather than only
        // in the dump log — a burst of these is meaningless until you can see what
        // it landed between.
        if tracing {
            traceBuffer.append("\(Self.format(Self.now() * 1000)) L\(tag) display #\(count)")
        }
        let shouldEmit = count <= Self.displayLineCap
        lock.unlock()

        // Standalone lines are capped: they exist to make a display pass visible
        // without a trace running, and a pathological case must not fill the disk.
        // The per-layer counter in a dump stays accurate either way.
        if shouldEmit {
            TerminalPresentProbe.emit("L\(tag) display pass #\(count) (inline sync render)")
        }
    }

    func endDisplay() {
        lock.lock()
        displayDepth = max(0, displayDepth - 1)
        lock.unlock()
    }

    /// A layout pass on a terminal view. Recorded only while tracing — these fire
    /// far more often than presents and are only meaningful next to them on one
    /// timeline.
    func recordLayout(view: AnyObject, kind: String) {
        let now = Self.now()
        lock.lock()
        layoutPasses += 1
        guard tracing else {
            lock.unlock()
            return
        }
        let tag = viewTags[ObjectIdentifier(view)] ?? {
            let next = viewTags.count
            viewTags[ObjectIdentifier(view)] = next
            return next
        }()
        traceBuffer.append("\(Self.format(now * 1000)) V\(tag) \(kind)")
        var pending: [String] = []
        if traceBuffer.count >= Self.traceFlushThreshold {
            pending = traceBuffer
            traceBuffer = []
        }
        lock.unlock()
        flush(pending)
    }

    func recordPresent(layer: AnyObject, contents: AnyObject?) {
        guard let contents else { return }
        let pointer = Unmanaged.passUnretained(contents).toOpaque()
        let now = Self.now()
        let onMain = Thread.isMainThread

        lock.lock()
        let isSync = displayDepth > 0
        let key = ObjectIdentifier(layer)
        var layerState = layers[key] ?? LayerState(tag: layers.count)
        let gap = layerState.lastPresentAt.map { (now - $0) * 1000 } ?? 0
        layerState.maxGapMilliseconds = max(layerState.maxGapMilliseconds, gap)
        layerState.presents += 1

        // Deliberately no frame-order judgement here. Naming the swap chain's
        // targets by the order their surfaces first appear is an inference, and it
        // is wrong whenever presents arrive close enough together to land in any
        // order — which is exactly when the interesting things happen. Three
        // attempts at it produced three flavours of false positive and nothing
        // real. The trace records raw surface identity, so the order can be
        // rebuilt exactly, offline, with no premise about the cycle at all.
        //
        // What is recorded here is only what needs no inference: a target rebuilt
        // at a new size, which is a genuine geometry event.
        var note: String?
        if layerState.knownSurfaces.insert(pointer).inserted {
            let size = Self.describe(contents)
            if let previous = layerState.lastSurfaceSize, previous != size {
                layerState.resizes += 1
                note = "SIZE CHANGE \(previous) → \(size)"
            }
            layerState.lastSurfaceSize = size
        }
        layerState.lastPresentAt = now
        layers[key] = layerState

        events.append(Event(
            at: now, layer: layerState.tag, isSync: isSync,
            isMainThread: onMain, gapMilliseconds: gap, note: note
        ))
        if events.count > Self.eventCapacity {
            events.removeFirst(events.count - Self.eventCapacity)
        }

        // The raw record: surface identity rather than the inferred slot, so the
        // frame order can be rebuilt afterwards without trusting the slot table.
        var pending: [String] = []
        if tracing {
            traceBuffer.append(
                "\(Self.format(now * 1000)) L\(layerState.tag)"
                    + " surf=\(Self.identify(pointer))"
                    + " \(layerState.lastSurfaceSize ?? Self.describe(contents))"
                    + (isSync ? " sync" : " async")
                    + (onMain ? "" : " off-main")
                    + " gap=\(Self.format(gap))"
                    + (note.map { "  \($0)" } ?? "")
            )
            if traceBuffer.count >= Self.traceFlushThreshold
                || now - lastTraceFlushAt > Self.traceFlushInterval {
                pending = traceBuffer
                traceBuffer = []
                lastTraceFlushAt = now
            }
        }

        let isAnomaly = note?.hasPrefix("SIZE CHANGE") == true
        var shouldDump = false
        if isAnomaly {
            if now - lastDumpAt < Self.dumpCooldown || autoDumps >= Self.autoDumpBudget {
                suppressedDumps += 1
            } else {
                lastDumpAt = now
                autoDumps += 1
                shouldDump = true
            }
        }
        lock.unlock()

        flush(pending)
        if shouldDump { dump(reason: note ?? "anomaly") }
    }

    func dump(reason: String) {
        lock.lock()
        // Mark the moment in the trace too — the dump's own timeline is relative,
        // and lining a reported flash up against the raw frame order is the whole
        // point of taking one.
        if tracing {
            traceBuffer.append("\(Self.format(Self.now() * 1000)) ---- \(reason) ----")
        }
        let window = Array(events.suffix(Self.dumpWindow))
        let snapshot = layers.values.sorted { $0.tag < $1.tag }
        let suppressed = suppressedDumps
        let layouts = layoutPasses
        let pending = traceBuffer
        traceBuffer = []
        suppressedDumps = 0
        let exhausted = autoDumps == Self.autoDumpBudget
        lock.unlock()
        flush(pending)

        var report = [
            "---- \(reason) ----",
            "layout passes on terminal views so far: \(layouts)",
        ]
        for layerState in snapshot {
            report.append(
                "L\(layerState.tag): presents=\(layerState.presents) "
                    + "displays=\(layerState.displays) "
                    + "sizeChanges=\(layerState.resizes) "
                    + "targets=\(layerState.knownSurfaces.count) "
                    + "size=\(layerState.lastSurfaceSize ?? "?") "
                    + "maxGap=\(Self.format(layerState.maxGapMilliseconds))ms"
            )
        }
        if suppressed > 0 {
            report.append("(\(suppressed) further size changes inside the cooldown)")
        }
        if let first = window.first {
            for event in window {
                let offset = (event.at - first.at) * 1000
                var line = "+\(Self.format(offset))ms L\(event.layer)"
                line += event.isSync ? " sync(display)" : " async"
                if !event.isMainThread { line += " OFF-MAIN" }
                line += " gap=\(Self.format(event.gapMilliseconds))ms"
                if let note = event.note { line += "  \(note)" }
                report.append(line)
            }
        } else {
            report.append("no presents recorded")
        }
        if exhausted {
            report.append(
                "automatic dumps are done — the rest of this run is trace-only, "
                    + "take further snapshots from the palette"
            )
        }
        // One write, not one per line: an automatic dump is ~38 lines and can fire
        // every couple of seconds, and re-opening the file that often is both slow
        // and the reason an earlier log grew unreadable.
        TerminalPresentProbe.emit(block: report)
    }

    /// The low bytes of the surface's address — enough to tell ghostty's three
    /// targets apart in the trace without printing full pointers.
    private static func identify(_ pointer: UnsafeRawPointer) -> String {
        String(UInt(bitPattern: pointer) & 0xFF_FFFF, radix: 16)
    }

    private static func describe(_ contents: AnyObject) -> String {
        guard let surface = contents as? IOSurface else {
            return String(describing: type(of: contents))
        }
        return "\(surface.width)x\(surface.height)"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
