import Foundation
import TermioShared

/// `DeviceSession` over the termiod Session Protocol: one attach channel to a
/// PTY on the device, carrying keystrokes out and its bytes back.
///
/// Everything the companion transport does over a Mac's relay, this does one hop
/// earlier, with three differences the protocol makes possible:
///
/// - **A reattach repaints from a snapshot, not a replay.** The daemon's VT
///   hands over the *current* screen (`S`) and live bytes resume on top, rather
///   than a torrent of historical escapes that mangles an idle TUI. The phone
///   reattaches every time it unlocks.
/// - **The grid is arbitrated.** The PTY's size is a host-side policy over every
///   attachment that is rendering — the smallest viewport wins — so `E resized`
///   is authoritative and this client honours it rather than assuming its own
///   viewport won. It declares that viewport whether or not it holds the write
///   token; the two are unrelated
///   (`docs/design/20260901-pty-size-is-not-the-write-token.md`).
/// - **Input is gated on a token.** Many clients may watch one session and
///   exactly one may type into it.
final class TermiodSession: DeviceSession {
    var onOutput: ((Data) -> Void)?
    var onState: ((DeviceSessionState) -> Void)?
    var onSharedGrid: ((TerminalGrid, Bool) -> Void)?

    /// How long the grid must hold still before a size goes to the device. Every
    /// distinct size is a host-side barrier — quiesce, resize, fresh keyframe to
    /// every attachment — so a settling keyboard animation must not become a
    /// burst of full repaints.
    private static let resizeCoalescingInterval = DispatchTimeInterval.milliseconds(50)

    private let sessionName: String
    private let channel: TermiodChannel
    /// The state below is touched only here, and this is the channel's delegate
    /// queue, so PTY bytes never wait behind UI work.
    private let queue = DispatchQueue(label: "sh.termio.mobile.termiod-session")
    private var attached = false
    private var isWriter = false
    private var claimingWriter = false
    /// Keystrokes that arrived before the attach landed. The device would refuse
    /// them and the person would have to retype, so they wait.
    private var pendingInput = Data()
    /// This screen's viewport: the grid its surface is laid out at, which is the
    /// whole terminal host — the phone shows a session at its own size and never
    /// scales it down, because under a smallest-wins policy it is never the
    /// larger of the two.
    private var viewportGrid = TerminalGrid(rows: 0, cols: 0)
    /// Whether this screen is showing the session. A parked screen the container
    /// kept alive stops counting toward the session's size.
    private var rendering = true
    /// What the PTY actually is: the smallest viewport rendering it.
    private var authoritativeGrid: TerminalGrid?
    /// A surface not yet laid out at the shared grid. The keyframe that
    /// announced the grid was parsed at the old one, and the surface is
    /// re-laid-out only after the layout pass — so the first report that lands
    /// *on* the shared grid asks the device for a fresh keyframe, and that one
    /// paints right.
    private var repaintPending = false
    /// Whether the device said it sizes sessions by policy. Without it this is
    /// an older host that reads `R` as "set the PTY size" and refuses it from
    /// anyone but the writer.
    private var hostSizesByPolicy = false
    private var viewportGeneration: UInt64 = 0
    /// The last declaration actually written, so an unchanged one is not
    /// re-sent: a viewport that moves the session is a host-side barrier.
    private var sentViewport: (grid: TerminalGrid, rendering: Bool)?
    /// Whether this screen ever had a session, which is what separates "the
    /// device refused a request" from "that session is not there".
    private var everAttached = false

    init(endpoint: DeviceEndpoint, sessionName: String) {
        self.sessionName = sessionName
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = self.queue
        channel = TermiodChannel(
            endpoint: endpoint, name: "session", role: "attach",
            capabilities: Termiod.attachCapabilities,
            delegateQueue: queue, pingRunLoopMode: .common
        )
        channel.onReady = { [weak self] handshake in
            self?.hostSizesByPolicy = handshake.caps.contains(Termiod.viewportCapability)
            self?.sendAttach()
        }
        // An attach channel carries one attachment and nothing else, so there is
        // never a second request for a reply to be confused with — the `re` is
        // real but has nothing to demultiplex.
        channel.onControl = { [weak self] reply in self?.receive(reply.control) }
        channel.onEvent = { [weak self] event in self?.receive(event) }
        channel.onData = { [weak self] data in self?.onOutput?(data) }
        channel.onSnapshot = { [weak self] payload in self?.repaint(payload) }
        channel.onLinkState = { [weak self] up in
            guard let self, !up else { return }
            // The socket is gone, so nothing about the old attachment holds:
            // the next `attached` reply is what says so again.
            self.queue.async { [weak self] in
                self?.attached = false
                self?.isWriter = false
                self?.claimingWriter = false
            }
            notify(.reconnecting)
        }
        channel.onFailure = { [weak self] reason in self?.notify(.failed(reason)) }
    }

    func start() {
        notify(.connecting)
        channel.start()
    }

    func stop() {
        // Detach without killing the session — the whole reason it lives in a
        // daemon. Sent straight through rather than by hopping to the frame
        // queue: this runs from a view controller's `deinit`, where capturing
        // self into a later block is not allowed.
        if let payload = try? Termiod.detachPayload() {
            channel.send(kind: .control, payload: payload)
        }
        channel.stop()
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard attached else {
                pendingInput.append(data)
                return
            }
            write(data)
        }
    }

    /// The surface's own answer to a host query. The host asked its terminal
    /// one question and the writer's surface is that terminal, so this goes
    /// through only while this phone holds the token — an observer's answer
    /// would arrive late and land in the agent's input line as text — and it
    /// never claims: a probe is not the person showing up.
    func sendDeviceReport(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard attached, isWriter else { return }
            sendData(data)
        }
    }

    /// Declares how much of a session this screen could show, whether or not
    /// this phone holds the write token. The device sizes the session to the
    /// smallest viewport being rendered; who may type is a separate question.
    func setViewport(columns: Int, rows: Int) {
        queue.async { [self] in
            let grid = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: columns))
            guard viewportGrid != grid else { return }
            viewportGrid = grid
            guard attached, grid.rows > 0, grid.cols > 0 else { return }
            // Arriving at the shared grid is the one moment a screen showing a
            // session smaller than itself needs something from the device: a
            // keyframe it can finally paint. Leaving it — a pinch reports the
            // old frame at new cell metrics before the layout settles — arms the
            // next arrival, so the bytes parsed in between are repainted too.
            if authoritativeGrid != grid {
                repaintPending = true
            } else if repaintPending {
                repaintPending = false
                if let payload = try? Termiod.requestSnapshotPayload() {
                    channel.send(kind: .control, payload: payload)
                }
            }
            scheduleViewport()
        }
    }

    /// Whether this screen is showing the session. The container parks a screen
    /// the person navigated away from rather than tearing it down, and a parked
    /// phone that kept counting would hold a Mac pane at phone width for as long
    /// as the session stayed open.
    func setRendering(_ showing: Bool) {
        queue.async { [self] in
            guard rendering != showing else { return }
            rendering = showing
            guard attached else { return }
            scheduleViewport()
        }
    }

    func reassertGrid() {
        queue.async { [self] in
            guard attached, viewportGrid.rows > 0, viewportGrid.cols > 0 else { return }
            // A rebuilt surface starts blank and no byte is coming, so this asks
            // for the screen rather than for a size — the device answers a
            // viewport it already has with nothing at all.
            if let payload = try? Termiod.requestSnapshotPayload() {
                channel.send(kind: .control, payload: payload)
            }
        }
    }

    // MARK: - Attach

    private func sendAttach() {
        do {
            let grid = viewportGrid
            channel.send(kind: .control, payload: try Termiod.attachPayload(
                target: sessionName,
                // Never `create_if_missing`: a screen opens on a session that
                // already exists, and spawning one here would turn "that session
                // is gone" into a second, empty shell.
                specification: nil,
                // Zero when the surface has not laid out yet, which the device
                // counts as no viewport at all. A 24×80 stand-in used to go here
                // instead, and under a smallest-wins policy that would squeeze
                // every other viewer for as long as the first layout pass took.
                rows: grid.rows,
                cols: grid.cols
            ))
        } catch {
            Log.device.error("""
            encoding attach for \(self.sessionName, privacy: .public) failed: \
            \(error.localizedDescription, privacy: .public)
            """)
            notify(.failed(localized("Termio couldn't attach to that session.")))
        }
    }

    private func receive(_ control: Termiod.IncomingControl) {
        switch control {
        case .attached(let payload):
            attached = true
            everAttached = true
            isWriter = payload.writer
            // The reply reports the size the session settled at once this
            // attachment's viewport was counted — the device applies the policy
            // before it answers — so this is the grid the bytes arriving on this
            // channel are already wrapped for.
            authoritativeGrid = TerminalGrid(rows: payload.rows, cols: payload.cols)
            sentViewport = (viewportGrid, true)
            // A screen parked before its attach landed has to say so: the device
            // counts every arrival as rendering.
            if !rendering { scheduleViewport() }
            repaintPending = authoritativeGrid != viewportGrid
            publishSharedGrid()
            if !pendingInput.isEmpty {
                let buffered = pendingInput
                pendingInput.removeAll(keepingCapacity: false)
                write(buffered)
            }
            notify(.connected)
        case .exited:
            attached = false
            notify(.closed)
        case .resizeClaim(let claim):
            applyWriter(claim.writer)
        case .error(let failure):
            // A refused claim answers here rather than with `writer_changed`,
            // and the flag has to clear either way: left set, one refusal would
            // mute this attachment for the rest of its life.
            claimingWriter = false
            guard !everAttached else {
                Log.device.error("""
                device refused a request on \(self.sessionName, privacy: .public): \
                \(failure.message, privacy: .public)
                """)
                return
            }
            // Refused before ever attaching: the session is not there, which is
            // fatal for this screen rather than something to retry into.
            notify(.failed(failure.message))
        default:
            break
        }
    }

    private func receive(_ event: Termiod.IncomingEvent) {
        switch event {
        case .writerChanged(let change):
            applyWriter(change.writer)
        case .resized(let size):
            applyAuthoritativeGrid(TerminalGrid(rows: size.rows, cols: size.cols))
        case .sessionExited:
            attached = false
            notify(.closed)
        default:
            break
        }
    }

    /// Repaints from the device's authoritative VT. Emitted straight through
    /// `onOutput`, on the same serial queue the live `D` frames arrive on, which
    /// is what preserves snapshot-before-bytes with no hold-back buffer.
    private func repaint(_ payload: Data) {
        guard let keyframe = TermiodSnapshot.decode(payload) else {
            Log.device.error("""
            undecodable snapshot on \(self.sessionName, privacy: .public)
            """)
            return
        }
        // Painted even when it describes a grid the surface is not laid out at
        // yet, which it briefly is: the barrier's `S` arrives ahead of the
        // `E resized` the layout reacts to. Dropping it instead used to be safe
        // only for the writer, whose own resize guaranteed another keyframe
        // behind it — and no client can make that promise now that the size is a
        // policy nobody client-side controls. `repaintPending` is what repairs
        // the one mangled frame, on the far side of the layout pass.
        onOutput?(TermiodSnapshot.render(keyframe))
    }

    // MARK: - Write token

    /// Typing claims the token, which is the same rule every other termio client
    /// follows: size and writes go to the device whose user is at the keyboard.
    /// Attaching does not claim it — a phone merely looking at a session must
    /// not mute the window that opened it and pull the PTY to its own width.
    ///
    /// Ordering is safe: frames on one connection are processed in order, so the
    /// claim resolves before the input queued behind it is tested against it.
    private func write(_ data: Data) {
        if !isWriter, !claimingWriter {
            claimingWriter = true
            if let payload = try? Termiod.claimWriterPayload() {
                channel.send(kind: .control, payload: payload)
            }
        }
        sendData(data)
    }

    private func sendData(_ data: Data) {
        var offset = 0
        while offset < data.count {
            let end = min(offset + Termiod.maximumDataFrameSize, data.count)
            channel.send(kind: .data, payload: data.subdata(in: offset ..< end))
            offset = end
        }
    }

    /// The device names the writer by client id, so this is the one comparison
    /// that tells this connection whether its `D` and `R` frames are honoured.
    private func applyWriter(_ writer: String?) {
        claimingWriter = false
        let mine = writer != nil && writer == channel.clientID
        guard mine != isWriter else { return }
        isWriter = mine
        Log.device.info("""
        write token on \(self.sessionName, privacy: .public) \
        \(mine ? "claimed" : "lost", privacy: .public)
        """)
        publishSharedGrid()
        // An older device still reads `R` as "set the PTY size" and refuses it
        // from anyone but the writer, so on one of those the token is still the
        // only moment this phone may state its size. Nothing here runs against a
        // device that sizes by policy — the token carries no grid.
        guard mine, !hostSizesByPolicy, viewportGrid.rows > 0 else { return }
        sendViewport()
    }

    /// §C.5: the PTY has one size and every client parses at it. Only noted,
    /// never answered — a writer used to answer a divergence by putting its own
    /// size back, which is how two devices watching one session sawed the PTY
    /// between their grids. The screen lays its surface out at the shared grid
    /// instead (`onSharedGrid`).
    private func applyAuthoritativeGrid(_ grid: TerminalGrid) {
        guard authoritativeGrid != grid else { return }
        authoritativeGrid = grid
        repaintPending = grid != viewportGrid
        publishSharedGrid()
        guard grid != viewportGrid, viewportGrid.rows > 0 else { return }
        Log.device.info("""
        \(self.sessionName, privacy: .public) PTY is now \
        \(grid.cols, privacy: .public)x\(grid.rows, privacy: .public); this screen has room for \
        \(self.viewportGrid.cols, privacy: .public)x\(self.viewportGrid.rows, privacy: .public)
        """)
    }

    /// Sends the viewport once the screen stops moving. Generation-stamped
    /// rather than debounced with a cancellable item because the size is re-read
    /// at fire time: the last scheduled send is the only one that writes, and it
    /// writes whatever the layout settled at.
    private func scheduleViewport() {
        viewportGeneration &+= 1
        let generation = viewportGeneration
        queue.asyncAfter(deadline: .now() + Self.resizeCoalescingInterval) { [self] in
            guard attached, generation == viewportGeneration else { return }
            sendViewport()
        }
    }

    /// An older device refuses an `R` from anyone but the writer, and reads a
    /// five-byte payload — the only form that can say "not rendering" — as a
    /// malformed frame and hangs up. So on one of those this stays gated the way
    /// it always was, and never says it has stopped rendering.
    private func sendViewport() {
        guard hostSizesByPolicy || isWriter else { return }
        let showing = hostSizesByPolicy ? rendering : true
        if let sent = sentViewport, sent.grid == viewportGrid, sent.rendering == showing { return }
        sentViewport = (viewportGrid, showing)
        channel.send(
            kind: .resize,
            payload: Termiod.viewportPayload(
                rows: viewportGrid.rows, cols: viewportGrid.cols, rendering: showing))
    }

    private func publishSharedGrid() {
        guard let grid = authoritativeGrid else { return }
        let writer = isWriter
        DispatchQueue.main.async { [onSharedGrid] in onSharedGrid?(grid, writer) }
    }

    private func notify(_ state: DeviceSessionState) {
        DispatchQueue.main.async { [onState] in onState?(state) }
    }
}
