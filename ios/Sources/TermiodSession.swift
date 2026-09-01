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
/// - **The grid is arbitrated.** Every attachment declares its viewport and the
///   daemon sizes the PTY to the per-axis min over the ones rendering, so
///   `E resized` is authoritative and this client honours it rather than
///   assuming its own viewport won.
/// - **Input is gated on a token.** Many clients may watch one session and
///   exactly one may type into it. The token gates input alone — it never
///   moves the size.
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
    /// What this surface is laid out at, and what the PTY actually is. They
    /// differ while a declaration is in flight, and while another rendering
    /// viewport is the smaller one on some axis.
    private var desiredGrid = TerminalGrid(rows: 0, cols: 0)
    private var authoritativeGrid: TerminalGrid?
    /// The last viewport actually declared to the device, so an unchanged one
    /// isn't re-sent. The device keeps a per-attachment viewport map — every
    /// declaration matters, even one matching the current PTY size.
    private var sentGrid: TerminalGrid?
    /// This surface has not reached the shared grid yet. The keyframe that
    /// announced the grid was parsed at the old one, and the surface is
    /// re-laid-out only after `onSharedGrid` reaches the screen — so the first
    /// `resize` that lands *on* the shared grid asks the device for a fresh
    /// keyframe, and that one paints right.
    ///
    /// Deliberately nothing to do with the write token, which now gates input
    /// alone: a screen can sit behind the shared grid whether or not its user
    /// is the one typing, and gating this on the token dropped the repaint for
    /// the half of the cases that hold it.
    private var surfaceBehindSharedGrid = false
    private var resizeGeneration: UInt64 = 0
    /// Whether this screen ever had a session, which is what separates "the
    /// device refused a request" from "that session is not there".
    private var everAttached = false
    /// Whether this phone's surface is on screen. A session parked behind the
    /// list keeps its socket, its stream and its declared grid, but leaves the
    /// device's size min — otherwise a phone that merely stopped looking holds
    /// every other viewer at phone width.
    private var rendering = true
    private var sentRendering: Bool?
    /// Whether the daemon understands the five-byte `R` frame (`viewport`).
    private var supportsViewport = false

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
            // Recorded before the attach goes out: the five-byte `R` frame is
            // only safe against a daemon that granted `viewport`, and an older
            // one drops the attachment for sending it.
            self?.supportsViewport = handshake.caps.contains("viewport")
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

    func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            let grid = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: columns))
            desiredGrid = grid
            guard attached, grid.rows > 0, grid.cols > 0 else { return }
            // A surface arriving at the shared grid is the one moment it needs
            // something beyond its declaration: a keyframe it can finally
            // paint. Leaving the grid — a pinch reports the old frame at new
            // cell metrics before the layout puts it back — arms the next
            // arrival, so the bytes parsed in between are repainted too.
            if authoritativeGrid != grid {
                surfaceBehindSharedGrid = true
            } else if surfaceBehindSharedGrid {
                surfaceBehindSharedGrid = false
                if let payload = try? Termiod.requestSnapshotPayload() {
                    channel.send(kind: .control, payload: payload)
                }
            }
            scheduleResize()
        }
    }

    func reassertGrid() {
        queue.async { [self] in
            guard attached, desiredGrid.rows > 0, desiredGrid.cols > 0 else { return }
            // The device keeps this attachment's declaration, so re-entering a
            // parked screen normally has nothing to say — `sendResize`'s dedupe
            // makes this free unless the layout moved while the screen was away.
            sendResize(desiredGrid)
        }
    }

    // MARK: - Attach

    private func sendAttach() {
        do {
            let grid = desiredGrid
            // The device turns the attach itself into this attachment's first
            // viewport declaration, so record it as sent — a matching `resize`
            // afterwards has nothing to add.
            let declared = TerminalGrid(
                rows: grid.rows > 0 ? grid.rows : 24,
                cols: grid.cols > 0 ? grid.cols : 80)
            sentGrid = declared
            // An older daemon never saw the visibility on the attach and cannot
            // be told in an `R` frame either, so what stands recorded is the
            // four-byte meaning — rendering — exactly as `sendResize` clamps it.
            sentRendering = supportsViewport ? rendering : true
            channel.send(kind: .control, payload: try Termiod.attachPayload(
                target: sessionName,
                // Never `create_if_missing`: a screen opens on a session that
                // already exists, and spawning one here would turn "that session
                // is gone" into a second, empty shell.
                specification: nil,
                // The surface normally reports its grid before the socket is
                // open; 24×80 stands in when it has not laid out yet, and the
                // first `R` corrects it.
                rows: declared.rows,
                cols: declared.cols,
                rendering: rendering
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
            // The reply reports the session's size *before* this attach is
            // applied; the device then derives the new min and announces it.
            // Seeding from here is what lets a viewer know the grid its bytes
            // are wrapped at.
            authoritativeGrid = TerminalGrid(rows: payload.rows, cols: payload.cols)
            surfaceBehindSharedGrid = authoritativeGrid != desiredGrid
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
        // A keyframe is a formatted repaint, wrapped rows and all, laid out for
        // the grid the device's VT held when it was taken. Painted into a
        // narrower surface every wrapped row shifts, and a TUI that redraws
        // incrementally never repairs it. One that fits paints right — and
        // under the per-axis-min size policy the PTY never outgrows a declared
        // viewport, so the only keyframe that overflows this surface is one
        // taken before this phone's own shrinking declaration was applied. The
        // barrier at the far end of that declaration will push one that fits.
        let payloadGrid = TerminalGrid(
            rows: UInt16(clamping: keyframe.rows), cols: UInt16(clamping: keyframe.cols))
        if desiredGrid.rows > 0,
           payloadGrid.rows > desiredGrid.rows || payloadGrid.cols > desiredGrid.cols {
            Log.device.info("""
            skipping \(payloadGrid.cols, privacy: .public)x\(payloadGrid.rows, privacy: .public) \
            keyframe on \(self.sessionName, privacy: .public); this surface is \
            \(self.desiredGrid.cols, privacy: .public)x\(self.desiredGrid.rows, privacy: .public)
            """)
            return
        }
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
        // The repaint flag is not touched here: it tracks whether this screen
        // has reached the shared grid, which a token move does not change.
        publishSharedGrid()
        // Nothing else moves: the device holds this attachment's viewport
        // declaration, so the size neither needs re-asserting on promotion nor
        // changes on demotion. The re-assert that used to live here is what
        // turned a token ping-pong into a resize storm.
    }

    /// §C.5: the PTY has one size and every client parses at it. Under the
    /// per-axis-min policy that size never exceeds this phone's declared
    /// viewport, so a divergence is a fact to render — content narrower than
    /// the screen, the rest blank — not something to answer. The answer this
    /// method used to send back was the other half of the resize storm.
    private func applyAuthoritativeGrid(_ grid: TerminalGrid) {
        guard authoritativeGrid != grid else { return }
        authoritativeGrid = grid
        surfaceBehindSharedGrid = grid != desiredGrid
        publishSharedGrid()
        guard grid != desiredGrid, desiredGrid.rows > 0 else { return }
        Log.device.info("""
        \(self.sessionName, privacy: .public) PTY is now \
        \(grid.cols, privacy: .public)x\(grid.rows, privacy: .public); this client renders \
        \(self.desiredGrid.cols, privacy: .public)x\(self.desiredGrid.rows, privacy: .public)
        """)
    }

    /// Sends `desiredGrid` once the surface stops moving. Generation-stamped
    /// rather than debounced with a cancellable item because the size is re-read
    /// at fire time: the last scheduled send is the only one that writes, and it
    /// writes whatever the grid settled at.
    private func scheduleResize() {
        resizeGeneration &+= 1
        let generation = resizeGeneration
        queue.asyncAfter(deadline: .now() + Self.resizeCoalescingInterval) { [self] in
            guard attached, generation == resizeGeneration else { return }
            sendResize(desiredGrid)
        }
    }

    private func sendResize(_ grid: TerminalGrid) {
        // Against a daemon without the capability the bit is not on the wire at
        // all, so it must not be part of the dedupe either — otherwise a
        // visibility flip would suppress the next real grid change.
        let declared = supportsViewport ? rendering : true
        guard sentGrid != grid || sentRendering != declared else { return }
        sentGrid = grid
        sentRendering = declared
        channel.send(
            kind: .resize,
            payload: Termiod.resizePayload(grid.rows, grid.cols, rendering: declared))
    }

    /// Whether this session is the one on screen. The phone parks a screen
    /// rather than tearing it down, so nothing else tells the daemon that the
    /// surface behind it stopped being looked at.
    func setRendering(_ visible: Bool) {
        queue.async { [self] in
            guard rendering != visible else { return }
            rendering = visible
            guard attached, desiredGrid.rows > 0, desiredGrid.cols > 0 else { return }
            sendResize(desiredGrid)
        }
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
