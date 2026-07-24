import Darwin
import Foundation

/// A PTY that termio owns, running one child process (an agent command or a
/// login shell). Replaces libghostty's `.exec` backend so termio holds the byte
/// stream itself: PTY output fans out to every attached sink (the local surface,
/// and — later — a phone), and input from any of them is written back.
///
/// The child is spawned via `forkpty` — the shape every terminal uses
/// (node-pty, iTerm2, kitty): the child does `setsid` + `TIOCSCTTY`
/// explicitly, so the pts is a fully-wired controlling terminal and job
/// control and signals (Ctrl-C → SIGINT, SIGWINCH on resize) work exactly
/// as under a real terminal.
final class PTYProcess: @unchecked Sendable {
    /// Which device's grid the PTY is sized for. One PTY has one winsize and
    /// the child lays its output out for it, so two differently-sized viewers
    /// can't both fit — the size follows the device being used (tmux's
    /// newest-client rule): a companion claims by resizing (it reports its
    /// grid on attach, foreground, and layout) or typing; the host claims
    /// back by typing; a companion detach hands back.
    enum SizeOwner {
        case host
        case companion
    }

    /// How much recent raw output is kept for replay to late-attaching sinks
    /// (a phone connecting mid-session). Bounded so an long-lived chatty agent
    /// can't grow memory without limit.
    private static let replayCapacity = 1 << 20 // 1 MB

    private struct Sink {
        /// Serial queue the handler is dispatched on; nil = called inline on
        /// the read pump (only for cheap, never-blocking consumers like the
        /// local surface — a networked consumer MUST bring its own queue so a
        /// slow send can't stall the local terminal).
        let queue: DispatchQueue?
        let handler: (Data) -> Void
    }

    /// DEC private modes a TUI sets once at startup (alternate screen, mouse
    /// reporting, bracketed paste, …). A late-attaching sink whose replay
    /// window no longer contains those set sequences would join believing the
    /// terminal is in its default state — its scroll gestures then move a
    /// nonexistent scrollback instead of being reported to the app as wheel
    /// events. The read pump tracks these so `addSink` can re-assert them.
    private static let trackedPrivateModes: Set<Int> = [
        25, 47, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1047, 1048, 1049, 2004, 2031,
    ]
    /// Modes that are ON in a fresh terminal; everything else defaults off.
    private static let defaultOnPrivateModes: Set<Int> = [25]
    /// Emission order: enter the alternate screen first so the cursor/mouse
    /// modes land in the screen the TUI is about to repaint into.
    private static let privateModeEmissionOrder = [
        1049, 1047, 47, 1048, 25, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 2004, 2031,
    ]

    private enum ModeScanState {
        case idle
        case escape        // saw ESC
        case csi           // saw ESC [
        case privateParams // saw ESC [ ? — accumulating digits and semicolons
    }

    /// Upper bound on buffered-but-unwritten input. A child that has not read
    /// this much of its stdin is wedged; dropping the excess (with a log)
    /// beats both blocking the writer and growing without limit.
    private static let maxWriteBacklog = 16 << 20 // 16 MB
    /// Consumed-prefix size beyond which a partially drained backlog is
    /// compacted (`removeFirst` is O(n), so it must not run per drain chunk).
    private static let writeBacklogCompactThreshold = 1 << 20 // 1 MB

    private let masterFD: Int32
    /// Dup of the master used by the write side, so the read source and the
    /// write source each own — and close, in their own cancel handler — their
    /// own descriptor.
    private let writeFD: Int32
    private(set) var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// Input the kernel buffer had no room for, awaiting a writability event.
    /// `pendingWriteOffset` marks how much of its prefix is already written.
    /// Guarded by `writeLock`, as is all write-side state below.
    private var pendingWrite = Data()
    private var pendingWriteOffset = 0
    /// Whether `writeSource` is currently resumed. Suspend/resume must stay
    /// balanced, so every transition happens under `writeLock`.
    private var writeSourceArmed = false
    private var writerTornDown = false
    private let writeLock = NSLock()
    private var sinks: [UUID: Sink] = [:]
    private var replayBuffer = Data()
    private var totalBytesRead = 0
    private var privateModeStates: [Int: (enabled: Bool, offset: Int)] = [:]
    private var modeScanState: ModeScanState = .idle
    private var modeScanParams: [Int] = []
    private var modeScanCurrent: Int?
    private var lastCols: Int
    private var lastRows: Int
    private var sizeOwner: SizeOwner = .host
    private var hostCols: Int
    private var hostRows: Int
    private var companionCols = 0
    private var companionRows = 0
    private var resizeObservers: [UUID: (Int, Int) -> Void] = [:]
    private var exitObservers: [UUID: (Int32) -> Void] = [:]
    private var terminated = false
    /// Set (under `lock`) the moment `waitpid` reaps the child, after which its
    /// pid may be recycled — the escalation kill checks this so a delayed
    /// SIGKILL can never hit an innocent reused pid/pgid.
    private var childExited = false
    /// The executable the child exec'd into (kernel path + inode), pinned by
    /// `recordChildExecutable` once it has moved past the spawn shell. The
    /// baseline `childExecutableWasReplaced()` compares against. Lock-guarded.
    private var childExecutable: (path: String, inode: ino_t?)?
    /// argv[0] of the spawn — the login shell the child starts as, which
    /// `recordChildExecutable` must wait out before pinning the identity.
    private let spawnExecutablePath: String
    /// Pending coalesced host SIGWINCH (see `resizeFromHost`). Lock-guarded.
    private var hostApplyWork: DispatchWorkItem?
    private let lock = NSLock()

    /// Wall-clock instant the child was spawned. Reported (as elapsed ms) on
    /// exit so libghostty's abnormal-exit overlay can distinguish a genuine
    /// sub-threshold launch failure from a normal exit: on macOS ghostty
    /// ignores the exit code and shows its scary "failed to launch the
    /// requested command" banner purely when runtime ≤ `abnormal-command-exit-runtime`
    /// (250 ms). Passing a hardcoded 0 tripped that on *every* exit; the real
    /// runtime lets a long-lived session close with the neutral "process
    /// exited" message instead.
    private let startedAt = Date()

    /// Fired (on the main queue) when the child exits, with its exit code and
    /// how long it ran (milliseconds).
    var onExit: ((Int32, UInt64) -> Void)?

    /// Spawns `argv` in `cwd` with `env` overrides at an initial `cols`×`rows`.
    /// Returns nil if the PTY or the process could not be created.
    init?(argv: [String], cwd: String, env: [String: String], cols: Int, rows: Int) {
        spawnExecutablePath = argv[0]
        lastCols = cols
        lastRows = rows
        hostCols = cols
        hostRows = rows
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)

        // Spawn with `forkpty`, NOT posix_spawn. The old shape —
        // `POSIX_SPAWN_SETSID` plus opening the pts in the child's file
        // actions — produced a controlling terminal that *looked* wired
        // (`/dev/tty` resolved, shell WINCH traps fired) but under which
        // Claude Code's resize detection never triggered: the TUI simply
        // never repainted on a window resize, in termio or in a minimal
        // repro harness (docs/bug/terminal-resize-no-reflow-HANDOFF.md).
        // `forkpty` runs `setsid` + `TIOCSCTTY` explicitly in the child —
        // the login_tty shape under which the same agent binary reflows
        // correctly. Everything between fork and exec must be
        // async-signal-safe, so the argv/env C arrays are built up front
        // and the child only calls chdir + execve + _exit.
        let pathC = strdup(argv[0])
        let argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let envpC: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cwdC = strdup(cwd)
        var master: Int32 = -1
        var childPID: pid_t = -1
        argvC.withUnsafeBufferPointer { argvBuffer in
            envpC.withUnsafeBufferPointer { envpBuffer in
                childPID = forkpty(&master, nil, nil, &win)
                if childPID == 0 {
                    if let cwdC { _ = chdir(cwdC) }
                    if let pathC {
                        _ = execve(pathC, argvBuffer.baseAddress, envpBuffer.baseAddress)
                    }
                    _exit(127)
                }
            }
        }
        argvC.forEach { free($0) }
        envpC.forEach { free($0) }
        free(pathC)
        free(cwdC)
        guard childPID > 0 else {
            Log.pty.error("forkpty failed errno=\(errno, privacy: .public)")
            if master >= 0 { close(master) }
            return nil
        }
        // The master must never block: `write(_:)` is called from libghostty's
        // io thread *while it holds the surface lock*, and a blocking write(2)
        // against a full kernel buffer (a child that stopped reading stdin)
        // parks that lock forever — the read pump and the main thread queue up
        // behind it and the app beachballs. The read pump already tolerates
        // EAGAIN. O_NONBLOCK lives on the file description, which the dup'd
        // write fd shares, so setting it once here covers both.
        let fdFlags = fcntl(master, F_GETFL)
        if fdFlags < 0 || fcntl(master, F_SETFL, fdFlags | O_NONBLOCK) < 0 {
            Log.pty.error("pty O_NONBLOCK failed errno=\(errno, privacy: .public)")
        }
        let writer = dup(master)
        guard writer >= 0 else {
            Log.pty.error("pty dup failed errno=\(errno, privacy: .public)")
            kill(childPID, SIGKILL)
            waitpid(childPID, nil, 0)
            close(master)
            return nil
        }
        masterFD = master
        writeFD = writer
        pid = childPID

        // Reap the child asynchronously to fire onExit + observers.
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
            self?.markChildExited()
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            DispatchQueue.main.async {
                guard let self else { return }
                let runtimeMs = UInt64(max(0, Date().timeIntervalSince(self.startedAt) * 1000))
                self.onExit?(Int32(code), runtimeMs)
                self.lock.lock()
                let observers = Array(self.exitObservers.values)
                self.lock.unlock()
                for observer in observers { observer(Int32(code)) }
            }
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(masterFD, &buffer, buffer.count)
            if n > 0 {
                let data = Data(buffer[0 ..< n])
                lock.lock()
                scanPrivateModesLocked(data)
                replayBuffer.append(data)
                if replayBuffer.count > Self.replayCapacity {
                    replayBuffer.removeFirst(replayBuffer.count - Self.replayCapacity)
                }
                let current = Array(sinks.values)
                lock.unlock()
                for sink in current {
                    if let queue = sink.queue {
                        queue.async { sink.handler(data) }
                    } else {
                        sink.handler(data)
                    }
                }
            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                // EOF (the child and every slave fd are gone) or a hard read
                // error ends the pump for good; a transient EINTR/EAGAIN just
                // waits for the next readability event. Cancelling fires the
                // cancel handler below — the one place the master fd is closed.
                if n < 0 {
                    Log.pty.error("pty read failed errno=\(errno, privacy: .public)")
                }
                self.markTerminated()
                self.readSource?.cancel()
                self.tearDownWriter()
            }
        }
        // Dispatch's documented pattern: release the fd in the cancellation
        // handler, which runs exactly once after the source can no longer
        // fire — whether the pump ended itself (EOF above), `terminate()`
        // cancelled it, or deinit did. Captures the fd by value so the close
        // still happens if the handler runs after this object is gone.
        source.setCancelHandler { [masterFD] in
            close(masterFD)
        }
        source.resume()
        readSource = source

        // The writability twin of the read source: drains `pendingWrite` once
        // the kernel buffer has room again. Born suspended — armed only while
        // a backlog exists (a pty master is writable nearly always, so a
        // permanently resumed source would spin). It owns the dup'd fd and
        // closes it in its own cancel handler.
        let wSource = DispatchSource.makeWriteSource(fileDescriptor: writer, queue: .global())
        wSource.setEventHandler { [weak self] in self?.drainWriteBacklog() }
        wSource.setCancelHandler { [writer] in close(writer) }
        writeSource = wSource
    }

    deinit {
        // Cancelling is idempotent; without this, dropping the last reference
        // before the EOF event fires would strand the master fd open forever.
        readSource?.cancel()
        tearDownWriter()
    }

    /// Marks the PTY dead so late writers and resizers become no-ops instead
    /// of touching a closed (and possibly recycled) file descriptor.
    private func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    private func markChildExited() {
        lock.lock()
        childExited = true
        lock.unlock()
    }

    /// Register an output sink; returns a token to remove it later.
    ///
    /// - Parameters:
    ///   - queue: a **serial** queue the handler runs on. Pass nil only for
    ///     cheap in-process consumers (the local surface); anything that can
    ///     block (network) must bring a queue so it never stalls the read pump.
    ///   - replayingBuffer: when true, the recent-output ring buffer is
    ///     delivered to this sink first, so a late-attaching client paints the
    ///     current screen instead of joining blind. Enqueued under the same
    ///     lock as live delivery, so replay/live ordering is preserved.
    ///   - replayCap: when set, only the last `replayCap` bytes of the ring
    ///     buffer are replayed to this sink. The local surface passes nil (it
    ///     wants the full history); a memory-constrained network viewer (the
    ///     phone) caps it so the cold-attach reflow at its narrow grid can't
    ///     spike libghostty's allocator into its "non-functional" panic. Only
    ///     the leading bytes are dropped, so the worst case is a clipped top
    ///     line — and a mode change inside that dropped prefix isn't re-asserted,
    ///     which is why the cap is only used on the plain-shell path (alt-screen
    ///     TUIs skip the byte replay entirely and resync modes explicitly).
    @discardableResult
    func addSink(
        on queue: DispatchQueue? = nil,
        replayingBuffer: Bool = false,
        replayCap: Int? = nil,
        _ handler: @escaping (Data) -> Void
    ) -> UUID {
        let id = UUID()
        lock.lock()
        if replayingBuffer {
            // Replay first, then re-assert private modes whose set sequences
            // have already been evicted from the ring buffer — the client's
            // terminal must agree with the child about alternate screen and
            // mouse reporting, or its scroll input goes nowhere.
            var replay = replayCap.map { Data(replayBuffer.suffix($0)) } ?? replayBuffer
            replay.append(modeCatchUpPreambleLocked())
            if !replay.isEmpty {
                if let queue {
                    queue.async { handler(replay) }
                } else {
                    handler(replay)
                }
            }
        }
        sinks[id] = Sink(queue: queue, handler: handler)
        lock.unlock()
        return id
    }

    /// Byte-level scan for `ESC [ ? params h/l` (DECSET/DECRST), tolerant of
    /// sequences split across read chunks. Only tracked modes are recorded,
    /// along with the stream offset of their last change so the preamble can
    /// tell whether the replay window already carries the sequence.
    private func scanPrivateModesLocked(_ data: Data) {
        let chunkStart = totalBytesRead
        totalBytesRead += data.count
        for (index, byte) in data.enumerated() {
            switch modeScanState {
            case .idle:
                if byte == 0x1B { modeScanState = .escape }
            case .escape:
                modeScanState = byte == UInt8(ascii: "[") ? .csi : .idle
            case .csi:
                if byte == UInt8(ascii: "?") {
                    modeScanState = .privateParams
                    modeScanParams = []
                    modeScanCurrent = nil
                } else if byte == 0x1B {
                    modeScanState = .escape
                } else {
                    modeScanState = .idle
                }
            case .privateParams:
                switch byte {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                    modeScanCurrent = (modeScanCurrent ?? 0) * 10 + Int(byte - UInt8(ascii: "0"))
                case UInt8(ascii: ";"):
                    if let current = modeScanCurrent { modeScanParams.append(current) }
                    modeScanCurrent = nil
                case UInt8(ascii: "h"), UInt8(ascii: "l"):
                    if let current = modeScanCurrent { modeScanParams.append(current) }
                    let enabled = byte == UInt8(ascii: "h")
                    for mode in modeScanParams where Self.trackedPrivateModes.contains(mode) {
                        privateModeStates[mode] = (enabled, chunkStart + index)
                    }
                    modeScanState = .idle
                case 0x1B:
                    modeScanState = .escape
                default:
                    modeScanState = .idle
                }
            }
        }
    }

    /// DECSET/DECRST sequences a replay-attached sink still needs: modes whose
    /// current state deviates from a fresh terminal's defaults AND whose last
    /// change happened before the replay window (a change inside the window is
    /// already delivered by the replay itself).
    private func modeCatchUpPreambleLocked() -> Data {
        let windowStart = totalBytesRead - replayBuffer.count
        var preamble = ""
        for mode in Self.privateModeEmissionOrder {
            guard let state = privateModeStates[mode],
                  state.offset < windowStart,
                  state.enabled != Self.defaultOnPrivateModes.contains(mode)
            else { continue }
            preamble += "\u{1B}[?\(mode)\(state.enabled ? "h" : "l")"
        }
        return Data(preamble.utf8)
    }

    /// True when the child is currently drawing in the alternate screen — a
    /// full-screen TUI (Claude Code, vim). Such a session repaints its whole
    /// screen on the next SIGWINCH, so an attaching client needs only the
    /// current modes and a resize, never a raw byte replay laid out for the
    /// grid the buffer was captured at.
    var isAlternateScreenActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return [1049, 1047, 47].contains { privateModeStates[$0]?.enabled == true }
    }

    /// Every private mode that currently deviates from a fresh terminal's
    /// defaults, as the DECSET/DECRST sequences to re-assert it — for a client
    /// that attaches *without* a byte replay (an alt-screen TUI it will repaint
    /// from scratch) and so must be put into the alternate screen and mouse
    /// modes explicitly, since no replay carries those set sequences.
    func modeResyncPreamble() -> Data {
        lock.lock()
        defer { lock.unlock() }
        var preamble = ""
        for mode in Self.privateModeEmissionOrder {
            guard let state = privateModeStates[mode],
                  state.enabled != Self.defaultOnPrivateModes.contains(mode)
            else { continue }
            preamble += "\u{1B}[?\(mode)\(state.enabled ? "h" : "l")"
        }
        return Data(preamble.utf8)
    }

    func removeSink(_ id: UUID) {
        lock.lock()
        sinks[id] = nil
        lock.unlock()
    }

    /// Observe child exit (in addition to `onExit`, which the store owns).
    /// Fired on the main queue. The token unregisters it — an observer tied to
    /// something shorter-lived than the PTY (a phone attach, outlived when the
    /// same connection re-attaches to another session) must be removed on that
    /// teardown, or the dead pairing still hears this PTY's exit.
    @discardableResult
    func addExitObserver(_ observer: @escaping (Int32) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        exitObservers[id] = observer
        lock.unlock()
        return id
    }

    func removeExitObserver(_ id: UUID) {
        lock.lock()
        exitObservers[id] = nil
        lock.unlock()
    }

    /// Queues `data` for the child's stdin. Never blocks — callers include
    /// libghostty's io thread, which invokes the surface write callback while
    /// holding the surface lock: a write that waited on a full kernel buffer
    /// (a child that stopped reading, e.g. a wedged TUI fed a large paste)
    /// would park that lock, and the read pump and main thread deadlock
    /// behind it. The common case is exactly one non-blocking write(2); only
    /// a full kernel buffer diverts the remainder into the backlog, which
    /// `writeSource` drains as the child reads.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let dead = terminated
        lock.unlock()
        guard !dead else { return }

        writeLock.lock()
        defer { writeLock.unlock() }
        guard !writerTornDown else { return }
        lastInputAtLocked = Date()
        // Once a backlog exists every write must append behind it, or these
        // bytes would overtake the queued remainder and reorder the stream.
        guard pendingWrite.isEmpty else {
            appendBacklogLocked(data)
            return
        }
        switch writeChunkLocked(data, from: 0) {
        case .drained, .failed:
            return
        case .blocked(let resumeAt):
            appendBacklogLocked(data.subdata(in: resumeAt ..< data.count))
        }
    }

    /// Instant of the last stdin write. Every input path funnels through
    /// `write(_:)` — Mac keystrokes via the surface's write callback, phone
    /// keystrokes via the companion bridge, synthetic `sessions send` text — so
    /// this is the one place input can be timestamped for all of them. Guarded
    /// by `writeLock` like the rest of the writer state.
    private var lastInputAtLocked = Date.distantPast

    /// Thread-safe read of the last stdin-write instant. The status tap reads it
    /// each poke to tell input echo apart from agent-driven output (see
    /// `TermioStore.noteUserInput`).
    var lastInputAt: Date {
        writeLock.lock()
        defer { writeLock.unlock() }
        return lastInputAtLocked
    }

    /// Result of pushing bytes at the non-blocking write fd.
    private enum WriteAttempt {
        /// Everything through `data.count` reached the kernel.
        case drained
        /// The kernel buffer filled; resume from this offset when writable.
        case blocked(resumeAt: Int)
        /// Hard error (already logged); the rest of this data is dropped.
        case failed
    }

    /// Writes `data[start...]` until drained, blocked, or failed. Must be
    /// entered with `writeLock` held (the syscall is non-blocking, so holding
    /// the lock across it costs microseconds, not a wait).
    private func writeChunkLocked(_ data: Data, from start: Int) -> WriteAttempt {
        var offset = start
        let count = data.count
        while offset < count {
            let n = data.withUnsafeBytes { raw -> Int in
                Darwin.write(writeFD, raw.baseAddress! + offset, count - offset)
            }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return .blocked(resumeAt: offset) }
            Log.pty.error("pty write failed errno=\(errno, privacy: .public)")
            return .failed
        }
        return .drained
    }

    /// Appends to the backlog (bounded by `maxWriteBacklog` — excess is
    /// dropped with a log, since a child this far behind on stdin is wedged
    /// and blocking or unbounded growth are both worse) and arms the
    /// writability source. Must be entered with `writeLock` held.
    private func appendBacklogLocked(_ data: Data) {
        let pending = pendingWrite.count - pendingWriteOffset
        guard pending + data.count <= Self.maxWriteBacklog else {
            Log.pty.error("""
            pty write backlog full (\(pending) bytes pending); \
            dropping \(data.count) bytes
            """)
            return
        }
        pendingWrite.append(data)
        if !writeSourceArmed {
            writeSourceArmed = true
            writeSource?.resume()
        }
    }

    /// Writability-source handler: pushes the backlog until it drains (then
    /// suspends the source) or the kernel fills again (stays armed for the
    /// next writability event).
    private func drainWriteBacklog() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !writerTornDown, writeSourceArmed else { return }
        switch writeChunkLocked(pendingWrite, from: pendingWriteOffset) {
        case .blocked(let resumeAt):
            pendingWriteOffset = resumeAt
            // Compact occasionally so a slowly draining backlog doesn't hold
            // its consumed prefix alive for its whole lifetime.
            if pendingWriteOffset > Self.writeBacklogCompactThreshold {
                pendingWrite.removeFirst(pendingWriteOffset)
                pendingWriteOffset = 0
            }
        case .drained, .failed:
            pendingWrite.removeAll(keepingCapacity: false)
            pendingWriteOffset = 0
            writeSourceArmed = false
            writeSource?.suspend()
        }
    }

    /// Stops the write side exactly once: further writes become no-ops, the
    /// backlog is dropped, and the source is cancelled (its cancel handler
    /// closes the write fd). Releasing a suspended source is a libdispatch
    /// error, so an unarmed source is resumed before cancelling.
    private func tearDownWriter() {
        writeLock.lock()
        guard !writerTornDown else {
            writeLock.unlock()
            return
        }
        writerTornDown = true
        pendingWrite.removeAll(keepingCapacity: false)
        pendingWriteOffset = 0
        if !writeSourceArmed {
            writeSourceArmed = true
            writeSource?.resume()
        }
        writeLock.unlock()
        writeSource?.cancel()
    }

    /// The Mac surface's grid changed. Applied only while the host owns the
    /// size — a layout pass on the Mac (window resize, inspector toggle) must
    /// not yank the width from a phone that is actively viewing. Recorded
    /// regardless, so a later host claim restores the surface's real size.
    func resizeFromHost(cols: Int, rows: Int) {
        lock.lock()
        hostCols = cols
        hostRows = rows
        guard sizeOwner == .host else {
            lock.unlock()
            return
        }
        // Coalesce the burst of *distinct* grid sizes a Mac layout pass emits
        // (window open, split-view settle, live drag) into a single SIGWINCH once
        // the size stops changing. Applying each intermediate size makes zsh redraw
        // its prompt per step, and ghostty reflowing the previous PROMPT_SP line
        // strands its `%` end-of-line mark — the stack of stray `%` at startup. The
        // size is recorded above regardless, so a companion claim still restores the
        // true host grid; typing (`claimHostOwnership`) snaps immediately.
        hostApplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyPendingHostSize() }
        hostApplyWork = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Applies the latest recorded host grid after the coalescing delay, unless the
    /// process died or a companion took ownership in the meantime.
    private func applyPendingHostSize() {
        lock.lock()
        guard !terminated, sizeOwner == .host else {
            lock.unlock()
            return
        }
        applyWindowSizeAndUnlock(cols: hostCols, rows: hostRows)
    }

    /// A phone reported its grid; a companion resize always claims the size
    /// (the phone only reports it while actively viewing: attach, foreground,
    /// layout). Returns whether the applied winsize actually changed — an
    /// unchanged size delivers no SIGWINCH, so a caller that needs a repaint
    /// must jiggle.
    @discardableResult
    func resizeFromCompanion(cols: Int, rows: Int) -> Bool {
        lock.lock()
        companionCols = cols
        companionRows = rows
        sizeOwner = .companion
        return applyWindowSizeAndUnlock(cols: cols, rows: rows)
    }

    /// Host input reclaims the size — typing on the Mac means the user is
    /// there. Also the hand-back when the last companion detaches. A no-op
    /// while the host already owns it, so it is cheap on every keystroke.
    func claimHostOwnership() {
        lock.lock()
        guard sizeOwner != .host else {
            lock.unlock()
            return
        }
        sizeOwner = .host
        applyWindowSizeAndUnlock(cols: hostCols, rows: hostRows)
    }

    /// Companion input reclaims the size using the last grid the phone
    /// reported (nothing to apply if it never reported one — its resize
    /// control is about to arrive anyway).
    func claimCompanionOwnership() {
        lock.lock()
        guard sizeOwner != .companion else {
            lock.unlock()
            return
        }
        sizeOwner = .companion
        guard companionCols > 0, companionRows > 0 else {
            lock.unlock()
            return
        }
        applyWindowSizeAndUnlock(cols: companionCols, rows: companionRows)
    }

    /// Observe applied winsize changes from any side. Fired on the resizing
    /// thread — hop to your own queue before doing anything slow. A bridge
    /// uses this to wipe its client ahead of a repaint laid out for some
    /// other device's grid.
    func addResizeObserver(_ observer: @escaping (Int, Int) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        resizeObservers[id] = observer
        lock.unlock()
        return id
    }

    func removeResizeObserver(_ id: UUID) {
        lock.lock()
        resizeObservers[id] = nil
        lock.unlock()
    }

    /// Applies the winsize if it differs from the current one and notifies
    /// resize observers. Must be entered with `lock` held; always unlocks.
    @discardableResult
    private func applyWindowSizeAndUnlock(cols: Int, rows: Int) -> Bool {
        guard !terminated, cols != lastCols || rows != lastRows else {
            lock.unlock()
            return false
        }
        lastCols = cols
        lastRows = rows
        let observers = Array(resizeObservers.values)
        lock.unlock()
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        if ioctl(masterFD, TIOCSWINSZ, &win) != 0 {
            Log.pty.error("TIOCSWINSZ failed errno=\(errno, privacy: .public)")
        }
        for observer in observers { observer(cols, rows) }
        return true
    }

    /// Force a full-screen repaint from TUI apps by delivering a spurious
    /// SIGWINCH (shrink one row, restore). Used after a replay or after a
    /// slow client dropped frames, so the child redraws its current state.
    func jiggleResize() {
        lock.lock()
        let dead = terminated
        let cols = lastCols
        let rows = lastRows
        lock.unlock()
        guard !dead else { return }
        var shrunk = winsize(ws_row: UInt16(max(rows - 1, 1)), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &shrunk)
        // A beat between the two so the child observes both changes. The size
        // is re-read at fire time: if a client resized during the beat (a
        // phone attaching does), its size must win, not the captured one.
        // The terminated check keeps the delayed ioctl off a recycled fd.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let dead = self.terminated
            let cols = self.lastCols
            let rows = self.lastRows
            self.lock.unlock()
            guard !dead else { return }
            var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.masterFD, TIOCSWINSZ, &win)
        }
    }

    func terminate() {
        lock.lock()
        terminated = true
        lock.unlock()
        // The read source's cancel handler owns closing the master fd; closing
        // it here as well would double-close (and could hit a recycled fd).
        readSource?.cancel()
        tearDownWriter()
        guard pid > 0 else { return }
        // Signal the whole process *group*, not just the direct child: the
        // forkpty child is the session leader (pgid == pid), and agents spawn
        // their own subprocess trees (tool shells, MCP servers) that a
        // single-pid SIGTERM strands. SIGHUP first — the "terminal went away"
        // signal a plain shell exits on — then SIGTERM for everything else.
        killpg(pid, SIGHUP)
        killpg(pid, SIGTERM)
        // Agent TUIs (Claude Code) install handlers for BOTH and keep running —
        // the source of the orphaned `claude` swarm that survives app restarts
        // for days. Escalate to SIGKILL after a grace period unless waitpid has
        // already reaped the child. Captures self strongly on purpose: the
        // store drops its reference right after terminate(), and a dealloc'd
        // PTYProcess can't follow through on the kill (the fds are already
        // closed, so the lingering reference holds nothing else open).
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.forceKillIfAlive() }
    }

    /// The child's current working directory, read from the kernel
    /// (`PROC_PIDVNODEPATHINFO`) — the fallback iTerm2 uses when the shell has no
    /// integration to say so itself. macOS's stock zsh only emits OSC 7 under
    /// `TERM_PROGRAM=Apple_Terminal`, and termio's host-managed PTY injects no
    /// shell integration, so a plain login shell here reports nothing — but the
    /// kernel always knows. The direct child *is* the login shell whose cwd `cd`
    /// mutates, which is exactly what the loose-terminal cwd sink wants (see
    /// `TermioStore.noteWorkingDirectory`). `nil` once the child has been reaped
    /// (a recycled pid must never be queried) or if the kernel refuses.
    func currentWorkingDirectory() -> String? {
        lock.lock()
        let exited = childExited
        lock.unlock()
        guard !exited, pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                                Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard size > 0 else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let path = String(cString: base.assumingMemoryBound(to: CChar.self))
            return path.isEmpty ? nil : path
        }
    }

    /// Records which executable the child is running right now (`proc_pidpath`
    /// plus its inode), once it has exec'd past the spawn shell. Called
    /// opportunistically from the output ticks, so by the time an agent has
    /// printed anything the identity is pinned. One-shot on purpose: the first
    /// non-shell sample is the *launch* baseline `childExecutableWasReplaced()`
    /// compares against — resampling later would paper over an in-place upgrade.
    func recordChildExecutable() {
        lock.lock()
        let skip = childExited || childExecutable != nil
        lock.unlock()
        guard !skip, pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return }
        let path = String(cString: buffer)
        guard path != spawnExecutablePath else { return }
        var info = stat()
        let inode: ino_t? = stat(path, &info) == 0 ? info.st_ino : nil
        lock.lock()
        childExecutable = (path, inode)
        lock.unlock()
    }

    /// Whether the recorded launch executable has since been replaced on disk:
    /// the file is gone (Homebrew purges the old versioned dir on upgrade) or
    /// its inode changed (an in-place reinstall). The exit path uses this to
    /// tell "the agent updated itself and quit" from a plain quit, whose binary
    /// is untouched. `false` when no identity was ever pinned — no evidence.
    func childExecutableWasReplaced() -> Bool {
        lock.lock()
        let identity = childExecutable
        lock.unlock()
        guard let identity else { return false }
        var info = stat()
        guard stat(identity.path, &info) == 0 else { return true }
        guard let inode = identity.inode else { return true }
        return info.st_ino != inode
    }

    /// The argv of the process group currently in the *foreground* of this PTY —
    /// the program the user is actually interacting with: the login shell until it
    /// runs a command, then that command (a hand-started `claude`), then the shell
    /// again once it exits. Read via `tcgetpgrp` + `KERN_PROCARGS2`, the pair iTerm2
    /// and friends use to name a pane's running program (`tcgetpgrp` on a forkpty
    /// master returns the tty's foreground group on macOS — verified). `nil` once the
    /// child is reaped (a recycled pid must never be queried) or if the kernel refuses.
    func foregroundProcessArguments() -> [String]? {
        lock.lock()
        let exited = childExited
        lock.unlock()
        guard !exited, pid > 0 else { return nil }
        let foreground = tcgetpgrp(masterFD)
        guard foreground > 0 else { return nil }
        return Self.processArguments(pid: foreground)
    }

    /// Reads a process's full argument vector from the kernel (`KERN_PROCARGS2`),
    /// whose buffer is laid out `[argc: Int32][exec path]\0…\0[argv0]\0[argv1]\0…[env]`.
    /// Own-user processes only — exactly the scope here (the child shell and its
    /// descendants). `nil` on any short read or refusal.
    private static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path that precedes argv[0], then the NUL padding
        // between it and argv[0].
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        var current: [UInt8] = []
        while index < size, arguments.count < Int(argc) {
            let byte = buffer[index]
            index += 1
            if byte == 0 {
                arguments.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        return arguments.isEmpty ? nil : arguments
    }

    /// SIGKILLs the child's process group if it hasn't been reaped yet.
    /// Idempotent; safe after the pid is reaped (the `childExited` check keeps
    /// the kill off a recycled pid). The app-quit path calls this directly
    /// after a short synchronous grace, since a dying app can't rely on a
    /// dispatched escalation timer.
    func forceKillIfAlive() {
        lock.lock()
        let exited = childExited
        lock.unlock()
        guard !exited, pid > 0 else { return }
        killpg(pid, SIGKILL)
    }

    /// Kills sessions a previous termio left behind when it died without
    /// running any teardown (a crash, a force-quit, the dev rebuild's
    /// `kill -9`). Those children re-parent to launchd and — because agent
    /// TUIs swallow the SIGHUP the closing PTY delivers — idle forever,
    /// accumulating into a memory-pressure swarm. Matched by the env termio
    /// stamps into every PTY (`TERMIO_SESSION` plus `TERM_PROGRAM=termio` —
    /// the session id alone leaks into unrelated processes when an editor is
    /// launched from a termio pane, but such descendants overwrite
    /// TERM_PROGRAM) and `ppid == 1` (parent gone). A live termio's sessions
    /// have that termio as their parent, so a dev and a prod instance never
    /// reap each other's running sessions.
    static func reapStrayOrphans() {
        DispatchQueue.global(qos: .utility).async {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            // -E appends each process's environment to the command column
            // (own-user processes only, which is exactly the scope wanted).
            ps.arguments = ["-axEww", "-o", "pid=,ppid=,command="]
            let out = Pipe()
            ps.standardOutput = out
            do { try ps.run() } catch {
                Log.pty.error("reap: ps failed to launch: \(error.localizedDescription, privacy: .public)")
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                guard line.contains("TERMIO_SESSION="),
                      line.contains("TERM_PROGRAM=termio") else { continue }
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 2,
                      let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]),
                      ppid == 1, pid != getpid()
                else { continue }
                Log.pty.info("reaping stray session process pid=\(pid, privacy: .public)")
                // The group first (the leader's tree), then the pid itself —
                // an orphaned *grandchild* isn't a group leader, so killpg
                // alone would miss it.
                killpg(pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }
}
