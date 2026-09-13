import AppKit
import Foundation

/// Captures the main thread's stack while a beachball is happening, because
/// that stack exists only then. Issue #638's 3.4 s workspace-switch stall was
/// diagnosed entirely from timing spans — the `sample` ran seconds after the
/// stall ended and showed a healthy idle run loop — so the split between
/// SwiftUI reconciliation and anything else inside that turn stayed a
/// hypothesis. This closes that gap the only way it can be closed: by noticing
/// the stall from off the main thread and sampling the process before it
/// recovers.
///
/// Mechanism: a utility-queue timer posts one acknowledgement block to the
/// main queue and watches how long it stays unanswered. Past the threshold it
/// launches `/usr/bin/sample` against this process as a child — the watchdog
/// thread's own `callStackSymbols` would capture the watchdog, not the stall.
/// One capture per stall (re-armed only by the acknowledgement finally
/// running), a cooldown between captures, and a small rotating file set keep a
/// pathological session from filling the disk.
///
/// Off by default. A signed release may also refuse `sample` without
/// entitlements we will not ship — in that case the failure is recorded in
/// the capture file rather than the signing weakened:
///
///     defaults write sh.termio.app StallCaptureEnabled -bool YES
final class StallWatchdog: @unchecked Sendable {
    static let shared = StallWatchdog()

    static let enabledDefaultsKey = "StallCaptureEnabled"

    /// How often the watchdog checks on its outstanding acknowledgement.
    private static let heartbeat: DispatchTimeInterval = .milliseconds(250)
    /// An acknowledgement older than this means the main thread is stalled.
    /// 500 ms is well past any frame budget but short enough to catch the
    /// multi-second stalls reported in #638 near their start.
    private static let stallThreshold: TimeInterval = 0.5
    /// Seconds `sample` records for. Long enough to profile a multi-second
    /// stall, short enough that brief ones still leave a mostly-stalled file.
    private static let sampleSeconds = 2
    private static let captureCooldown: TimeInterval = 60
    private static let keptCaptures = 5

    /// All mutable state lives on this queue; the main thread only ever runs
    /// the acknowledgement block, which hops back here.
    private let queue = DispatchQueue(label: "sh.termio.stall-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// When the outstanding acknowledgement was posted; nil when none is.
    private var ackPosted: Date?
    /// Whether the current stall already triggered a capture, so one stall
    /// never produces a file per heartbeat.
    private var capturedThisStall = false
    private var lastCapture: Date?

    private init() {}

    /// Starts the watchdog if the hidden default asks for it. Called after the
    /// launch settles — the launch has its own trace, and its long main-thread
    /// turns are expected, not stalls worth a capture each.
    func startIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) else { return }
        queue.async { [self] in
            guard timer == nil else { return }
            Log.app.info("stall watchdog on threshold_ms=\(Int(Self.stallThreshold * 1000), privacy: .public)")
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.heartbeat, repeating: Self.heartbeat)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
        // Sleep parks the main thread legitimately; an acknowledgement posted
        // before sleep would read as a giant stall on wake. Dropping it around
        // the transition keeps those out of the captures.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self, selector: #selector(resetAcknowledgement),
            name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(
            self, selector: #selector(resetAcknowledgement),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func resetAcknowledgement() {
        queue.async { [self] in
            ackPosted = nil
            capturedThisStall = false
        }
    }

    private func tick() {
        if let posted = ackPosted {
            let stalledFor = Date().timeIntervalSince(posted)
            guard stalledFor >= Self.stallThreshold, !capturedThisStall else { return }
            capturedThisStall = true
            capture(stalledFor: stalledFor)
            return
        }
        let posted = Date()
        ackPosted = posted
        DispatchQueue.main.async { [self] in
            queue.async { [self] in
                // A stale acknowledgement (reset by sleep/wake) must not
                // re-arm detection out from under a fresher one.
                guard ackPosted == posted else { return }
                if capturedThisStall {
                    // The stall just ended: this is the moment its true length
                    // is known, and the log line that pairs with the capture.
                    Trace.stall.mark("main-thread stall", elapsed: .seconds(Date().timeIntervalSince(posted)))
                }
                ackPosted = nil
                capturedThisStall = false
            }
        }
    }

    /// Runs `sample` against our own pid, from the watchdog queue, while the
    /// main thread is still stuck. Failures (a signed release refusing
    /// task inspection, sample missing) land in the capture file: a recorded
    /// failure tells us to fall back to Instruments, a silent one looks like
    /// the watchdog never fired.
    private func capture(stalledFor: TimeInterval) {
        if let last = lastCapture, Date().timeIntervalSince(last) < Self.captureCooldown { return }
        lastCapture = Date()

        let directory = AppChannel.supportDirectory.appendingPathComponent("stall-samples", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.app.error("stall capture: create \(directory.path, privacy: .public): \(error, privacy: .public)")
            return
        }
        pruneOldCaptures(in: directory)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("stall-\(stamp).txt")
        Log.app.error("""
        stall capture firing stalled_ms=\(Int(stalledFor * 1000), privacy: .public) \
        file=\(file.lastPathComponent, privacy: .public)
        """)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            String(Self.sampleSeconds),
            "-file", file.path,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            try? "sample failed to launch: \(error)".write(to: file, atomically: true, encoding: .utf8)
            return
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderrData, encoding: .utf8) ?? ""
            try? "sample exited \(process.terminationStatus): \(message)"
                .write(to: file, atomically: true, encoding: .utf8)
            Log.app.error("stall capture: sample exited \(process.terminationStatus, privacy: .public)")
        }
    }

    private func pruneOldCaptures(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("stall-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        // Names embed an ISO timestamp, so lexical order is age order.
        for stale in files.dropLast(Self.keptCaptures - 1) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
