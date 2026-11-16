import CoreGraphics
import Foundation
import GhosttyVt
import ImageIO
import os

/// The client's own copy of a session's screen on the `vt_stream` plane: a
/// libghostty-vt terminal that follows the daemon's byte for byte.
///
/// It is built only from the daemon's native snapshot and changed only by what
/// follows it on the wire — `D` bytes and `E vt_resize` markers, applied in the
/// order they arrived. Nothing else resizes it: a view that is larger or smaller
/// than the session draws it clipped or with room to spare, and says how much it
/// could hold through the viewport declaration instead. That is the whole design
/// (docs/design/20261024-client-vt-follows-the-stream.md): the daemon placed the
/// marker where its own VT changed size, so applying the same operation at the
/// same byte leaves both screens identical, with no keyframe to wait for.
///
/// Two threads use it: the link's reader writes bytes and applies markers, and
/// the renderer copies the screen out once a frame. One lock covers both, held
/// by the renderer only for `ghostty_render_state_begin_update`.
public final class TermiodStreamTerminal: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case engine(String, GhosttyResult)
    }

    /// The cell metrics termiod's sidecar resizes with (`resize_reflowing` in
    /// `termiod/vt/src/lib.rs`). The grid does not depend on them, but pixel
    /// sizes reach size reports and image placement, so both ends use one pair.
    public static let cellWidth: UInt32 = 8
    public static let cellHeight: UInt32 = 16
    /// The decoder's cap on unfinished input carried in a snapshot, matching
    /// the daemon's `CONTINUATION_LIMIT`. A snapshot taken mid-sequence carries
    /// the partial sequence; a larger one than this is refused, not truncated.
    public static let continuationLimit = 1 << 20

    private let terminal: GhosttyTerminal
    /// The screen as the renderer last copied it. Owned here, not by the
    /// renderer, because synchronized output has to be copied on the writing
    /// thread at the byte its hold begins; it is only ever touched under `lock`.
    private let renderState: GhosttyRenderState
    private let lock = NSLock()
    /// Raised under `lock` by everything that can change what a cell shows:
    /// bytes, viewport moves and resizes. A hover reads it to skip copying
    /// the line under a pointer that has not moved.
    private var changesLocked: UInt64 = 0
    public var changes: UInt64 { locked { changesLocked } }
    /// Raised by the renderer before it asks for `lock`. NSLock is not fair, and
    /// a reader writing chunk after chunk re-takes it before a waiting renderer
    /// wakes: the phase 1 spike measured frames starved for up to 34 ms.
    private let rendererWaiting = OSAllocatedUnfairLock(initialState: false)
    private let animationClock = ContinuousClock.now
    /// What the terminal answers a program's query with — a cursor position
    /// report, a mode report. Called on the writing thread, inside `write`.
    private let onReply: (Data) -> Void
    /// What the program tells the terminal that the app acts on, as the
    /// embedded surface publishes it: the title, the working directory, the
    /// bell, a desktop notification, a clipboard write. Called on the writing
    /// thread, inside `write`, with `lock` held.
    private let onSignal: (Signal) -> Void
    /// The text a program reading the clipboard (OSC 52 `?`) is given, which
    /// reaches it through `onReply`, so only the writer's answer is sent.
    private let readClipboard: () -> String?
    /// The mouse selection's state machine and its reusable events, used only
    /// under `lock`: Ghostty's own click, double-click and drag rules.
    private let gesture: GhosttySelectionGesture
    private let pressEvent: GhosttySelectionGestureEvent
    private let dragEvent: GhosttySelectionGestureEvent
    private let releaseEvent: GhosttySelectionGestureEvent

    public enum Signal: Equatable, Sendable {
        case title(String)
        case workingDirectory(String)
        case bell
        case notification(title: String, body: String)
        /// Text a program copied with OSC 52 to the standard clipboard.
        case clipboard(String)
    }
    /// When the program began synchronized output (mode 2026), set by the
    /// render-hold callback under `lock`. Nil while nothing is held.
    private var heldSince: ContinuousClock.Instant?
    /// The theme last set, under `lock`; the renderer reads the parts of it
    /// libghostty does not hold (cursor text, the contrast floor).
    private var theme: Theme?
    /// How long a program may hold the screen before the hold is ended for
    /// it, as libghostty's own example does.
    public static let holdLimit: Duration = .seconds(1)

    /// Decodes the daemon's native snapshot (`S` format 4) into a new terminal.
    /// An attach always builds a fresh one: nothing the previous terminal held
    /// may survive into the new stream.
    /// `xtversion` is the name XTVERSION reports, the app's embedded Ghostty
    /// (`ghostty <version>`); empty reports libghostty's own.
    public init(
        nativeSnapshot: Data, xtversion: String = "", onReply: @escaping (Data) -> Void = { _ in },
        onSignal: @escaping (Signal) -> Void = { _ in },
        readClipboard: @escaping () -> String? = { nil }
    ) throws {
        Self.installPNGDecoder
        terminal = try nativeSnapshot.withUnsafeBytes { buffer in
            try Self.decode(buffer.bindMemory(to: UInt8.self))
        }
        var state: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS, let state else {
            ghostty_terminal_free(terminal)
            throw Failure.engine("ghostty_render_state_new", GHOSTTY_OUT_OF_MEMORY)
        }
        renderState = state
        var gesture: GhosttySelectionGesture?
        var press: GhosttySelectionGestureEvent?
        var drag: GhosttySelectionGestureEvent?
        var release: GhosttySelectionGestureEvent?
        _ = ghostty_selection_gesture_new(nil, &gesture)
        _ = ghostty_selection_gesture_event_new(nil, &press, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS)
        _ = ghostty_selection_gesture_event_new(nil, &drag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG)
        _ = ghostty_selection_gesture_event_new(nil, &release, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)
        guard let gesture, let press, let drag, let release else {
            ghostty_selection_gesture_event_free(press)
            ghostty_selection_gesture_event_free(drag)
            ghostty_selection_gesture_event_free(release)
            ghostty_selection_gesture_free(gesture, terminal)
            ghostty_render_state_free(state)
            ghostty_terminal_free(terminal)
            throw Failure.engine("selection gesture", GHOSTTY_OUT_OF_MEMORY)
        }
        self.gesture = gesture
        pressEvent = press
        dragEvent = drag
        releaseEvent = release
        self.onReply = onReply
        self.onSignal = onSignal
        self.readClipboard = readClipboard
        // Allocated once nothing before it can throw: a terminal that fails to
        // decode never owns it.
        let name = Array(xtversion.utf8)
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(1, name.count))
        _ = buffer.initialize(from: name)
        xtversionBytes = UnsafeBufferPointer(rebasing: buffer[0 ..< name.count])
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata), "ghostty_terminal_set(userdata)")
        let reply: GhosttyTerminalWritePtyFn = { _, userdata, bytes, count in
            guard let userdata, let bytes, count > 0 else { return }
            let owner = Unmanaged<TermiodStreamTerminal>.fromOpaque(userdata).takeUnretainedValue()
            owner.onReply(Data(bytes: bytes, count: count))
        }
        try Self.check(
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(reply, to: UnsafeRawPointer.self)),
            "ghostty_terminal_set(write_pty)"
        )
        try installQueryAnswers()
        // Called inside `vt_write` or `resize`, so `lock` is already held. At
        // the start of a hold the terminal holds exactly the frame the program
        // wants on screen, and nothing after it has been parsed yet: that is
        // the moment to copy it (render.h, "synchronized output").
        let hold: GhosttyTerminalRenderHoldFn = { terminal, userdata, held in
            guard let userdata else { return }
            let owner = Unmanaged<TermiodStreamTerminal>.fromOpaque(userdata).takeUnretainedValue()
            if held {
                _ = ghostty_render_state_update(owner.renderState, terminal)
                owner.heldSince = ContinuousClock.now
            } else {
                owner.heldSince = nil
            }
        }
        try Self.check(
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(hold, to: UnsafeRawPointer.self)),
            "ghostty_terminal_set(render_hold)"
        )
        // A snapshot taken mid-hold restores mode 2026 without a callback, and
        // a repeated begin raises none: start held, on the frame decoded.
        if try mode(ghostty_mode_new(2026, false)) {
            try Self.check(ghostty_render_state_update(renderState, terminal), "ghostty_render_state_update")
            heldSince = ContinuousClock.now
        }
        try installSignals()
        // The snapshot's directory is reported, since it is a fact about the
        // session. Its title is not: the embedded surface never learns a title
        // from an attach, and one a conversation rotation cleared would come
        // back on every relaunch.
        if let directory = workingDirectoryLocked() { onSignal(.workingDirectory(directory)) }
    }

    private func installSignals() throws {
        func owner(_ userdata: UnsafeMutableRawPointer?) -> TermiodStreamTerminal? {
            userdata.map { Unmanaged<TermiodStreamTerminal>.fromOpaque($0).takeUnretainedValue() }
        }
        let title: GhosttyTerminalTitleChangedFn = { _, userdata in
            guard let owner = owner(userdata) else { return }
            owner.onSignal(.title(owner.string(GHOSTTY_TERMINAL_DATA_TITLE) ?? ""))
        }
        let directory: GhosttyTerminalPwdChangedFn = { _, userdata in
            guard let owner = owner(userdata), let path = owner.workingDirectoryLocked() else { return }
            owner.onSignal(.workingDirectory(path))
        }
        let bell: GhosttyTerminalBellFn = { _, userdata in
            owner(userdata)?.onSignal(.bell)
        }
        let notification: GhosttyTerminalDesktopNotificationFn = { _, userdata, notification in
            guard let owner = owner(userdata), let notification else { return }
            owner.onSignal(.notification(
                title: TermiodStreamTerminal.text(notification.pointee.title), body: TermiodStreamTerminal.text(notification.pointee.body)
            ))
        }
        // Written as the embedded surface writes it: the text, with no prompt.
        // The reply must come before this returns.
        let clipboard: GhosttyTerminalClipboardWriteFn = { _, userdata, write in
            guard let write else { return }
            var reply = GhosttyClipboardWriteReply()
            reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
            reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
            defer { withUnsafePointer(to: &reply) { write.pointee.reply(write, $0) } }
            // Every location is the one pasteboard, as the embedded surface
            // treats them: macOS has no selection clipboard.
            guard let owner = owner(userdata), let contents = write.pointee.contents else { return }
            let entries = UnsafeBufferPointer(start: contents, count: write.pointee.contents_len)
            guard let text = entries.first(where: { TermiodStreamTerminal.text($0.mime).hasPrefix("text/plain") }) else { return }
            owner.onSignal(.clipboard(TermiodStreamTerminal.text(text.data)))
        }
        let clipboardRead: GhosttyTerminalClipboardReadFn = { _, userdata, read in
            guard let read else { return }
            var reply = GhosttyClipboardReadReply()
            reply.size = MemoryLayout<GhosttyClipboardReadReply>.size
            guard let owner = owner(userdata), let text = owner.readClipboard() else {
                reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_UNSUPPORTED
                withUnsafePointer(to: &reply) { read.pointee.reply(read, $0) }
                return
            }
            let mime = Array("text/plain".utf8)
            let data = Array(text.utf8)
            mime.withUnsafeBufferPointer { mime in
                data.withUnsafeBufferPointer { data in
                    var content = GhosttyClipboardContent(
                        mime: GhosttyString(ptr: mime.baseAddress, len: mime.count),
                        data: GhosttyString(ptr: data.baseAddress, len: data.count)
                    )
                    withUnsafePointer(to: &content) { content in
                        reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS
                        reply.contents = content
                        reply.contents_len = 1
                        withUnsafePointer(to: &reply) { read.pointee.reply(read, $0) }
                    }
                }
            }
        }
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, unsafeBitCast(clipboardRead, to: UnsafeRawPointer.self)), "ghostty_terminal_set(clipboard read)")
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer.self)), "ghostty_terminal_set(title)")
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(directory, to: UnsafeRawPointer.self)), "ghostty_terminal_set(pwd)")
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self)), "ghostty_terminal_set(bell)")
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(notification, to: UnsafeRawPointer.self)), "ghostty_terminal_set(notification)")
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clipboard, to: UnsafeRawPointer.self)), "ghostty_terminal_set(clipboard write)")
    }

    private static func text(_ string: GhosttyString) -> String {
        guard let pointer = string.ptr, string.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: string.len), as: UTF8.self)
    }

    /// A borrowed string the terminal holds; read with `lock` held.
    private func string(_ data: GhosttyTerminalData) -> String? {
        var value = GhosttyString()
        guard ghostty_terminal_get(terminal, data, &value) == GHOSTTY_SUCCESS else { return nil }
        return Self.text(value)
    }

    private func workingDirectoryLocked() -> String? {
        string(GHOSTTY_TERMINAL_DATA_PWD).flatMap { Self.workingDirectory(fromOSC7: $0, localHost: Self.localHost) }
    }

    /// Ghostty's own rule for OSC 7 (`StreamHandler.reportPwd`), which
    /// libghostty-vt leaves to the embedder: a `file` or `kitty-shell-cwd` URL
    /// naming this machine. A shell on a box reached with ssh reports a path
    /// that does not exist here, and is ignored, as the embedded surface does.
    public static func workingDirectory(fromOSC7 reported: String, localHost: String) -> String? {
        let raw = reported.hasPrefix("kitty-shell-cwd://")
        guard raw || reported.hasPrefix("file://") else { return nil }
        let rest = reported.dropFirst(raw ? "kitty-shell-cwd://".count : "file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash])
        guard !host.isEmpty, host == "localhost" || host == localHost else { return nil }
        let path = String(rest[slash...])
        // kitty sends the path as it is; a file URL percent-encodes it.
        return raw ? path : path.removingPercentEncoding
    }

    /// Asked at every report, as Ghostty does: a Mac's name can change while
    /// the app runs, as when it joins another network.
    private static var localHost: String {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// The decoder borrows `bytes` until it is freed, so everything from its
    /// creation to its release stays inside the caller's `withUnsafeBytes`.
    private static func decode(_ bytes: UnsafeBufferPointer<UInt8>) throws -> GhosttyTerminal {
        var decoder: GhosttySnapshotDecoder?
        try check(
            ghostty_snapshot_decoder_new_buf(nil, &decoder, bytes.baseAddress, bytes.count),
            "ghostty_snapshot_decoder_new_buf"
        )
        guard let decoder else {
            throw Failure.engine("ghostty_snapshot_decoder_new_buf", GHOSTTY_INVALID_VALUE)
        }
        defer { ghostty_snapshot_decoder_free(decoder) }
        var limit = continuationLimit
        try check(
            ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit),
            "ghostty_snapshot_decoder_set(max continuation)"
        )
        var decoded: GhosttyTerminal?
        try check(ghostty_snapshot_decoder_decode(decoder, &decoded), "ghostty_snapshot_decoder_decode")
        guard let decoded else {
            throw Failure.engine("ghostty_snapshot_decoder_decode", GHOSTTY_INVALID_VALUE)
        }
        return decoded
    }

    /// The largest decoded PNG accepted, in RGBA bytes. termiod refuses past
    /// the same size (`DECODED_LIMIT` in `termiod/vt/src/kitty_png.rs`).
    public static let pngDecodedLimit = 10_000_000

    /// libghostty-vt decodes no PNG itself; it calls a process-wide hook. The
    /// decoded size decides how many cells a Kitty image covers and so where
    /// the cursor lands after it, so this must accept exactly the PNGs termiod
    /// accepts, at the same sizes, or the screens drift apart. ImageIO and the
    /// `png` crate are lenient about different damage, so neither decides:
    /// `pngHeader` does, and termiod's `kitty_png::header` is the same walk
    /// in Rust. Pixels ImageIO cannot decode are stored as zeros at the header
    /// size, as termiod stores them.
    private static let installPNGDecoder: Void = {
        let hook: GhosttySysDecodePngFn = { _, allocator, data, length, out in
            guard let data, let out,
                  let image = TermiodStreamTerminal.decodePNG(UnsafeRawBufferPointer(start: data, count: length)),
                  let buffer = ghostty_alloc(allocator, image.pixels.count)
            else { return false }
            image.pixels.withUnsafeBufferPointer { pixels in
                if let base = pixels.baseAddress {
                    buffer.update(from: base, count: pixels.count)
                }
            }
            out.pointee = GhosttySysImage(
                width: image.width, height: image.height, data: buffer, data_len: image.pixels.count
            )
            return true
        }
        let result = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(hook, to: UnsafeRawPointer.self))
        if result != GHOSTTY_SUCCESS {
            StreamLog.logger.error("PNG decoder not installed: \(result.rawValue, privacy: .public)")
        }
    }()

    /// Straight (not premultiplied) RGBA at the size `pngHeader` accepted.
    public static func decodePNG(_ bytes: UnsafeRawBufferPointer) -> (width: UInt32, height: UInt32, pixels: [UInt8])? {
        guard let (width, height) = pngHeader(bytes), let base = bytes.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
        let pixels = pngPixels(data, width: Int(width), height: Int(height))
            ?? [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
        return (width, height, pixels)
    }

    private static func pngPixels(_ data: Data, width: Int, height: Int) -> [UInt8]? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == width, image.height == height
        else { return nil }
        // The image's own RGB space, so no colour conversion changes the
        // values a program sent; termiod passes them through untouched.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // A bitmap context only holds premultiplied alpha.
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = UInt16(pixels[index + 3])
            guard alpha != 255 else { continue }
            for channel in index ..< index + 3 {
                pixels[channel] = alpha == 0 ? 0 : UInt8(min(255, (UInt16(pixels[channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return pixels
    }

    /// The size a PNG is accepted at, or nil when it is refused: the
    /// signature, then IHDR first with 13 bytes, then every chunk whole with a
    /// matching CRC, up to an IEND with no body. Bytes after IEND are ignored.
    /// Neither dimension may be 0 or past 2^31 - 1, and the decoded RGBA may
    /// not pass `pngDecodedLimit`. Keep in step with `kitty_png::header`.
    public static func pngHeader(_ bytes: UnsafeRawBufferPointer) -> (UInt32, UInt32)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= signature.count, bytes.prefix(signature.count).elementsEqual(signature) else { return nil }
        func word(_ at: Int) -> UInt32 {
            (0 ..< 4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[at + $1]) }
        }
        var offset = signature.count
        var size: (UInt32, UInt32)?
        while true {
            guard offset + 8 <= bytes.count else { return nil }
            let length = Int(word(offset))
            let kind = offset + 4
            guard length <= bytes.count, kind + 4 + length + 4 <= bytes.count,
                  crc32(UnsafeRawBufferPointer(rebasing: bytes[kind ..< kind + 4 + length])) == word(kind + 4 + length)
            else { return nil }
            let name = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[kind ..< kind + 4]), as: UTF8.self)
            switch (size, name) {
            case (nil, "IHDR") where length == 13:
                let width = word(kind + 4), height = word(kind + 8)
                guard width > 0, height > 0, width <= UInt32(Int32.max), height <= UInt32(Int32.max) else { return nil }
                let (pixels, overflow) = Int(width).multipliedReportingOverflow(by: Int(height))
                guard !overflow, pixels <= pngDecodedLimit / 4 else { return nil }
                size = (width, height)
            case (nil, _):
                return nil
            case (let accepted?, "IEND"):
                return length == 0 ? accepted : nil
            default:
                break
            }
            offset = kind + 4 + length + 4
        }
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { index in
        (0 ..< 8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    private static func crc32(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        crcTable.withUnsafeBufferPointer { table in
            var crc = UInt32.max
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            return ~crc
        }
    }

    deinit {
        UnsafeMutableBufferPointer(mutating: xtversionBytes).deallocate()
        ghostty_selection_gesture_event_free(pressEvent)
        ghostty_selection_gesture_event_free(dragEvent)
        ghostty_selection_gesture_event_free(releaseEvent)
        ghostty_selection_gesture_free(gesture, terminal)
        ghostty_terminal_free(terminal)
        ghostty_render_state_free(renderState)
    }

    /// What the embedded surface answers, so a program sees one terminal in
    /// either pane: Ghostty's DA1 with clipboard access (termio leaves
    /// `clipboard-write` at its default, allow) and DA2, Ghostty's XTVERSION,
    /// size reports in this terminal's 8 by 16 cells, which Kitty images are
    /// laid out in, and the color scheme of the appearance the theme was picked
    /// for. libghostty-vt answers none of the last three by itself, and answers
    /// DA2 and XTVERSION as libghostty. One difference stays: libghostty-vt
    /// answers DA3, which Ghostty does not, and the callback is not told which
    /// level was asked.
    private func installQueryAnswers() throws {
        let attributes: GhosttyTerminalDeviceAttributesFn = { _, _, out in
            guard let out else { return false }
            var answer = GhosttyDeviceAttributes()
            answer.primary.conformance_level = 62
            answer.primary.features.0 = 22
            answer.primary.features.1 = 52
            answer.primary.num_features = 2
            answer.secondary = GhosttyDeviceAttributesSecondary(device_type: 1, firmware_version: 10, rom_cartridge: 0)
            out.pointee = answer
            return true
        }
        let version: GhosttyTerminalXtversionFn = { _, userdata in
            guard let userdata else { return GhosttyString(ptr: nil, len: 0) }
            let name = Unmanaged<TermiodStreamTerminal>.fromOpaque(userdata).takeUnretainedValue().xtversionBytes
            return GhosttyString(ptr: name.baseAddress, len: name.count)
        }
        let size: GhosttyTerminalSizeFn = { terminal, _, out in
            guard let out else { return false }
            var rows: UInt16 = 0
            var cols: UInt16 = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            out.pointee = GhosttySizeReportSize(
                rows: rows, columns: cols, cell_width: TermiodStreamTerminal.cellWidth, cell_height: TermiodStreamTerminal.cellHeight)
            return true
        }
        let scheme: GhosttyTerminalColorSchemeFn = { _, userdata, out in
            guard let userdata, let out else { return false }
            let owner = Unmanaged<TermiodStreamTerminal>.fromOpaque(userdata).takeUnretainedValue()
            guard let theme = owner.theme else { return false }
            out.pointee = theme.dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            return true
        }
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, unsafeBitCast(attributes, to: UnsafeRawPointer.self)), "ghostty_terminal_set(device attributes)")
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(version, to: UnsafeRawPointer.self)), "ghostty_terminal_set(xtversion)")
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self)), "ghostty_terminal_set(size)")
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(scheme, to: UnsafeRawPointer.self)), "ghostty_terminal_set(color scheme)")
    }

    /// The XTVERSION name, owned here for as long as the engine may read it.
    private let xtversionBytes: UnsafeBufferPointer<UInt8>

    public func write(_ bytes: Data) {
        locked { writeLocked(bytes) }
        while rendererWaiting.withLock({ $0 }) { sched_yield() }
    }

    private func writeLocked(_ bytes: Data) {
        bytes.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base, bytes.count)
            changesLocked &+= 1
        }
    }

    /// How much history this client keeps: the Scrollback setting, in bytes,
    /// as the embedded surface's `scrollback-limit`. A decoded snapshot carries
    /// termiod's own limits, about a thousand lines, which are the daemon's
    /// memory budget per session and not what a pane should show. The line
    /// limit is removed so the byte limit alone decides, as in Ghostty.
    public func setScrollbackLimit(bytes: Int) throws {
        try locked {
            var limit = max(0, bytes)
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit), "ghostty_terminal_set(scrollback bytes)")
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, nil), "ghostty_terminal_set(scrollback lines)")
        }
    }

    public func scrollbackRows() throws -> Int {
        try locked {
            var rows = 0
            try get(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &rows)
            return rows
        }
    }

    /// The theme: libghostty resolves "default foreground" and palette indices
    /// against these, so a session drawn by two Macs follows each one's theme.
    /// A decoded snapshot carries none of the daemon's, which never sets any.
    public func setTheme(_ colors: Theme) throws {
        let report = try locked { () -> Data? in
            // A program that turned on color scheme reports (mode 2031) is told
            // when the appearance changes, as Ghostty tells it.
            let reportsScheme = theme.map { $0.dark != colors.dark } == true
                && (try? mode(ghostty_mode_new(2031, false))) == true
            var foreground = colors.foreground
            var background = colors.background
            var palette = colors.palette
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground), "ghostty_terminal_set(foreground)")
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background), "ghostty_terminal_set(background)")
            if var cursor = colors.cursor {
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor), "ghostty_terminal_set(cursor)")
            } else {
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil), "ghostty_terminal_set(cursor)")
            }
            try palette.withUnsafeMutableBufferPointer { buffer in
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress), "ghostty_terminal_set(palette)")
            }
            // The default a program's DECSCUSR 0 returns to — and what a cursor
            // nobody styled shows. One the program chose explicitly keeps its
            // own shape: the terminal tells the two apart even after a decode.
            //
            // Setting either default also rewrites the blink mode, so each is
            // set only when its setting changes, as Ghostty does on a config
            // change. On the first theme a decoded screen that already blinks
            // keeps blinking — the daemon's own default is off, so that blink
            // is the program's. One a program turned off cannot be told from
            // that default, and takes the setting.
            let programBlinks = theme == nil ? try mode(ghostty_mode_new(12, false)) : false
            if theme?.cursorStyle != colors.cursorStyle {
                var cursorStyle = colors.cursorStyle
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &cursorStyle), "ghostty_terminal_set(default cursor)")
            }
            if theme?.cursorBlink != colors.cursorBlink {
                var cursorBlink = colors.cursorBlink
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &cursorBlink), "ghostty_terminal_set(default blink)")
            }
            if programBlinks {
                var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(12, false), value: true)
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode), "ghostty_terminal_set(blink mode)")
            }
            theme = colors
            return reportsScheme ? Data((colors.dark ? "\u{1b}[?997;1n" : "\u{1b}[?997;2n").utf8) : nil
        }
        if let report { onReply(report) }
    }

    /// Tells a program that turned on color scheme reports (mode 2031) the
    /// scheme it is in now. A terminal decoded on reattach starts with no
    /// theme, so a change made while the pane was detached reaches the program
    /// only this way; a report repeating the current scheme does no harm.
    public func reportColorSchemeIfSubscribed() {
        let report = locked { () -> Data? in
            guard let theme, (try? mode(ghostty_mode_new(2031, false))) == true else { return nil }
            return Data((theme.dark ? "\u{1b}[?997;1n" : "\u{1b}[?997;2n").utf8)
        }
        if let report { onReply(report) }
    }

    public struct Theme: Equatable {
        public init(foreground: GhosttyColorRgb, background: GhosttyColorRgb, cursor: GhosttyColorRgb?, palette: [GhosttyColorRgb], cursorStyle: GhosttyCursorStyle, cursorBlink: Bool, cursorText: GhosttyColorRgb? = nil, minimumContrast: Double = 1, selectionBackground: GhosttyColorRgb? = nil, selectionForeground: GhosttyColorRgb? = nil, dark: Bool = false) {
            self.dark = dark
            self.foreground = foreground
            self.background = background
            self.cursor = cursor
            self.palette = palette
            self.cursorStyle = cursorStyle
            self.cursorBlink = cursorBlink
            self.cursorText = cursorText
            self.minimumContrast = minimumContrast
            self.selectionBackground = selectionBackground
            self.selectionForeground = selectionForeground
        }
        public static func == (left: Theme, right: Theme) -> Bool {
            func same(_ a: GhosttyColorRgb, _ b: GhosttyColorRgb) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }
            return left.dark == right.dark
                && left.cursorStyle == right.cursorStyle && left.cursorBlink == right.cursorBlink
                && left.minimumContrast == right.minimumContrast
                && left.selectionBackground.map { color in right.selectionBackground.map { same(color, $0) } ?? false }
                    ?? (right.selectionBackground == nil)
                && left.selectionForeground.map { color in right.selectionForeground.map { same(color, $0) } ?? false }
                    ?? (right.selectionForeground == nil)
                && left.cursorText.map { text in right.cursorText.map { same(text, $0) } ?? false } ?? (right.cursorText == nil)
                && same(left.foreground, right.foreground) && same(left.background, right.background)
                && left.cursor.map { cursor in right.cursor.map { same(cursor, $0) } ?? false } ?? (right.cursor == nil)
                && left.palette.count == right.palette.count
                && zip(left.palette, right.palette).allSatisfy(same)
        }

        public var foreground: GhosttyColorRgb
        public var background: GhosttyColorRgb
        public var cursor: GhosttyColorRgb?
        /// Exactly 256 entries.
        public var palette: [GhosttyColorRgb]
        /// The cursor settings, as the defaults a program's DECSCUSR can override.
        public var cursorStyle: GhosttyCursorStyle
        public var cursorBlink: Bool
        /// The color of a character under a block cursor; nil is the background.
        public var cursorText: GhosttyColorRgb? = nil
        /// The WCAG ratio a glyph keeps against its own background, 1 for none.
        public var minimumContrast: Double = 1
        /// The theme's selection colors; nil is Ghostty's default, the
        /// default foreground behind the default background.
        public var selectionBackground: GhosttyColorRgb? = nil
        public var selectionForeground: GhosttyColorRgb? = nil
        /// The appearance this theme was picked for, which a program asking
        /// for the color scheme is told: Ghostty reports the window's
        /// appearance, and either slot in Settings may hold any theme.
        public var dark = false
    }

    /// Runs `body` with the screen's render state, under the terminal lock so
    /// the writing thread cannot copy into it meanwhile.
    ///
    /// The state is refreshed first, unless the program holds synchronized
    /// output (mode 2026): then it keeps the frame copied when the hold began,
    /// and a program that redraws hold after hold shows each finished frame in
    /// turn. A hold longer than `holdLimit` is ended for the program.
    public func withFrame<Result>(_ body: (GhosttyRenderState, Theme?) throws -> Result) throws -> Result {
        try withFrame { state, theme, _ in try body(state, theme) }
    }

    /// The image storage as a frame sees it. The render state says where each
    /// image goes; only the pixels and the animation clock live in the
    /// terminal, so they are read here, under the frame's lock.
    public struct FrameImages {
        fileprivate let terminal: GhosttyTerminal

        /// The view's place in the screen and its history, read under the
        /// frame's lock so a scrollbar polling it every frame keeps the
        /// renderer's place in line for the lock.
        public var scrollbar: Scrollbar? {
            var state = GhosttyTerminalScrollbar()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &state) == GHOSTTY_SUCCESS else {
                return nil
            }
            return Scrollbar(total: state.total, offset: state.offset, length: state.len)
        }

        /// An image's pixels as straight-alpha RGBA, with the generation they
        /// belong to, or nil while it has none.
        public func pixels(id: UInt32) -> ImagePixels? {
            guard let graphics = storage(), let image = ghostty_kitty_graphics_image(graphics, id) else { return nil }
            var width: UInt32 = 0
            var height: UInt32 = 0
            var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
            var pixels = GhosttyString()
            var generation: UInt64 = 0
            // PIXELS is NO_VALUE until the image's data has arrived.
            guard ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH, &width)
                    == GHOSTTY_SUCCESS,
                  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT, &height)
                    == GHOSTTY_SUCCESS,
                  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT, &format)
                    == GHOSTTY_SUCCESS,
                  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &pixels)
                    == GHOSTTY_SUCCESS,
                  ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION, &generation)
                    == GHOSTTY_SUCCESS,
                  let pointer = pixels.ptr, width > 0, height > 0
            else { return nil }
            let length = pixels.len
            let channels: Int
            switch format {
            case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA: channels = 4
            case GHOSTTY_KITTY_IMAGE_FORMAT_RGB: channels = 3
            case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA: channels = 2
            case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY: channels = 1
            default: return nil
            }
            let count = Int(width) * Int(height) * channels
            guard length >= count else { return nil }
            // Only the copy happens under the lock; `rgba()` converts later.
            return ImagePixels(
                width: Int(width), height: Int(height), channels: channels, generation: generation,
                bytes: Data(bytes: pointer, count: count)
            )
        }

        private func storage() -> GhosttyKittyGraphics? {
            var graphics: GhosttyKittyGraphics?
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS
            else { return nil }
            return graphics
        }
    }

    public struct ImagePixels {
        public init(width: Int, height: Int, channels: Int, generation: UInt64, bytes: Data) {
            self.width = width
            self.height = height
            self.channels = channels
            self.generation = generation
            self.bytes = bytes
        }
        public var width: Int
        public var height: Int
        public var channels: Int
        public var generation: UInt64
        public var bytes: Data

        /// Premultiplied RGBA, which the image shader filters without the
        /// colour of transparent pixels bleeding into the edges.
        public func rgba() -> [UInt8] {
            let count = width * height
            var rgba = [UInt8](repeating: 255, count: count * 4)
            bytes.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: UInt8.self)
                for index in 0 ..< count {
                    let at = index * channels
                    let alpha = channels == 4 ? source[at + 3] : channels == 2 ? source[at + 1] : 255
                    let red = source[at]
                    let green = channels >= 3 ? source[at + 1] : red
                    let blue = channels >= 3 ? source[at + 2] : red
                    func premultiplied(_ value: UInt8) -> UInt8 {
                        UInt8((UInt16(value) * UInt16(alpha) + 127) / 255)
                    }
                    rgba[index * 4] = premultiplied(red)
                    rgba[index * 4 + 1] = premultiplied(green)
                    rgba[index * 4 + 2] = premultiplied(blue)
                    rgba[index * 4 + 3] = alpha
                }
            }
            return rgba
        }
    }

    public func withFrame<Result>(_ body: (GhosttyRenderState, Theme?, FrameImages) throws -> Result) throws -> Result {
        rendererWaiting.withLock { $0 = true }
        lock.lock()
        rendererWaiting.withLock { $0 = false }
        defer { lock.unlock() }
        if let since = heldSince, ContinuousClock.now - since >= Self.holdLimit {
            // Setting the mode directly never invokes the callback.
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode)
            heldSince = nil
        }
        if heldSince == nil {
            advanceAnimationsLocked()
            try Self.check(ghostty_render_state_update(renderState, terminal), "ghostty_render_state_update")
        }
        return try body(renderState, theme, FrameImages(terminal: terminal))
    }

    /// Shows each playing animation's frame for now, as Ghostty's renderer
    /// drives it: the terminal keeps no clock of its own. It runs before the
    /// update, so the image list names the frame the storage holds, and on
    /// this terminal's own clock, which only moves forward while it lives.
    private func advanceAnimationsLocked() {
        var graphics: GhosttyKittyGraphics?
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS,
              let graphics
        else { return }
        let elapsed = ContinuousClock.now - animationClock
        let milliseconds = UInt64(max(0, elapsed.components.seconds)) * 1000
            + UInt64(max(0, elapsed.components.attoseconds) / 1_000_000_000_000_000)
        var next: UInt64 = 0
        _ = ghostty_kitty_graphics_animation_tick(graphics, milliseconds, &next)
    }

    private func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Where a wheel turn goes, as Ghostty routes it: to a program tracking
    /// the mouse, or to one on the alternate screen with alternate scroll
    /// (mode 1007), which termiod encodes; otherwise it moves this view
    /// through scrollback. termiod decides again against its own modes and
    /// sends nothing for a turn that is scrollback there.
    public var wheelGoesToProgram: Bool {
        locked {
            var tracking = false
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            guard !tracking else { return true }
            var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
            return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE && (try? mode(ghostty_mode_new(1007, false))) == true
        }
    }

    /// Whether the program asked for mouse reports, so a click is its.
    public var tracksMouse: Bool {
        locked {
            var tracking = false
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            return tracking
        }
    }

    /// The grid's size in cells.
    public var grid: (rows: UInt16, cols: UInt16) {
        locked {
            var rows: UInt16 = 0
            var cols: UInt16 = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            return (rows, cols)
        }
    }

    /// Moves this view through scrollback by `rows`, negative up. Only the
    /// client's view moves; the session is untouched.
    public func scrollViewport(rows: Int) {
        locked {
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = rows
            ghostty_terminal_scroll_viewport(terminal, behavior)
            changesLocked &+= 1
        }
    }

    /// Where the view sits in the screen and its history, in rows. libghostty
    /// sends no change notification, so a scrollbar polls this each frame.
    public struct Scrollbar: Equatable, Sendable {
        public var total: UInt64
        public var offset: UInt64
        public var length: UInt64
    }

    /// Moves this view so `row`, in `Scrollbar.offset`'s row space, is at its top.
    public func scrollViewport(toRow row: UInt64) {
        locked {
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW
            behavior.value.row = Int(clamping: row)
            ghostty_terminal_scroll_viewport(terminal, behavior)
            changesLocked &+= 1
        }
    }

    /// The active screen as plain text, one line per row, whatever part of
    /// scrollback the view shows: what `termio session read` reports.
    public func activeText() throws -> String {
        try locked {
            var rows: UInt16 = 0
            var cols: UInt16 = 0
            try get(GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            try get(GHOSTTY_TERMINAL_DATA_COLS, &cols)
            guard rows > 0, cols > 0 else { return "" }
            func reference(_ x: UInt16, _ y: UInt16) throws -> GhosttyGridRef {
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_ACTIVE
                point.value.coordinate = GhosttyPointCoordinate(x: x, y: UInt32(y))
                var reference = GhosttyGridRef()
                try Self.check(ghostty_terminal_grid_ref(terminal, point, &reference), "ghostty_terminal_grid_ref")
                return reference
            }
            var selection = GhosttySelection()
            selection.start = try reference(0, 0)
            selection.end = try reference(cols - 1, rows - 1)
            return try withUnsafePointer(to: &selection) { selection in
                let options = FormatOptions(
                    emit: GHOSTTY_FORMATTER_FORMAT_PLAIN, unwrap: false, trim: true, selection: selection.pointee
                )
                return String(decoding: try format(options), as: UTF8.self)
            }
        }
    }

    /// Where the pointer is, for a selection: the viewport cell under it and
    /// its position in the pane, in pixels.
    public struct SelectionPoint: Equatable {
        public init(column: UInt16, row: UInt16, x: Double, y: Double) {
            self.column = column
            self.row = row
            self.x = x
            self.y = y
        }
        public var column: UInt16
        public var row: UInt16
        public var x: Double
        public var y: Double
    }

    /// What a drag needs to tell which cell the pointer is over at the edges.
    public struct SelectionGeometry: Equatable {
        public init(cellWidth: UInt32, paddingLeft: UInt32, screenHeight: UInt32) {
            self.cellWidth = cellWidth
            self.paddingLeft = paddingLeft
            self.screenHeight = screenHeight
        }
        public var cellWidth: UInt32
        public var paddingLeft: UInt32
        public var screenHeight: UInt32
    }

    /// A mouse press starting or extending a selection. `time` is monotonic
    /// nanoseconds, which double- and triple-click are told from; `interval`
    /// is the system's double-click interval.
    public func pressSelection(at point: SelectionPoint, time: UInt64, interval: UInt64, distance: Double) {
        locked {
            guard var reference = viewportReference(point) else { return }
            var position = GhosttySurfacePosition(x: point.x, y: point.y)
            var time = time
            var interval = interval
            // How far a second click may land from the first, as Ghostty
            // allows: a cell's width.
            var distance = distance
            _ = ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
            _ = ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &reference)
            _ = ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            _ = ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time)
            _ = ghostty_selection_gesture_event_set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
            // A single click selects nothing and clears what was selected; a
            // double or triple click selects the word or the line at once.
            applyGesture(pressEvent)
        }
    }

    public func dragSelection(to point: SelectionPoint, geometry: SelectionGeometry, rectangle: Bool) {
        locked {
            guard var reference = viewportReference(point) else { return }
            var position = GhosttySurfacePosition(x: point.x, y: point.y)
            var cols: UInt16 = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            var shape = GhosttySelectionGestureGeometry(
                columns: UInt32(max(1, cols)), cell_width: max(1, geometry.cellWidth),
                padding_left: geometry.paddingLeft, screen_height: max(1, geometry.screenHeight)
            )
            var rectangle = rectangle
            _ = ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &reference)
            _ = ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            _ = ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &shape)
            _ = ghostty_selection_gesture_event_set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle)
            applyGesture(dragEvent)
        }
    }

    public func releaseSelection(at point: SelectionPoint?) {
        locked {
            if let point, var reference = viewportReference(point) {
                _ = ghostty_selection_gesture_event_set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &reference)
            } else {
                _ = ghostty_selection_gesture_event_set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
            }
            _ = ghostty_selection_gesture_event(gesture, terminal, releaseEvent, nil)
        }
    }

    /// Installs what a gesture event produced as the terminal's selection, or
    /// clears it when the event produced none.
    private func applyGesture(_ event: GhosttySelectionGestureEvent) {
        var selection = GhosttySelection()
        if ghostty_selection_gesture_event(gesture, terminal, event, &selection) == GHOSTTY_SUCCESS {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        } else {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
    }

    public func selectAll() {
        locked {
            var selection = GhosttySelection()
            if ghostty_terminal_select_all(terminal, &selection) == GHOSTTY_SUCCESS {
                _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
            }
        }
    }

    public func clearSelection() {
        locked {
            ghostty_selection_gesture_reset(gesture, terminal)
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
    }

    public var hasSelection: Bool {
        locked {
            var selection = GhosttySelection()
            return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
        }
    }

    /// The selection as Ghostty copies it (`Screen.selectionString`): plain
    /// text, soft wraps joined, trailing whitespace trimmed. Nil when nothing
    /// is selected.
    public var selectedText: String? {
        locked {
            var selection = GhosttySelection()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
            else { return nil }
            let options = FormatOptions(
                emit: GHOSTTY_FORMATTER_FORMAT_PLAIN, unwrap: true, trim: true, selection: selection
            )
            return (try? format(options)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// The cell under a pointer, in viewport coordinates, clamped to the grid.
    private func viewportReference(_ point: SelectionPoint) -> GhosttyGridRef? {
        var rows: UInt16 = 0
        var cols: UInt16 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols)
        guard rows > 0, cols > 0 else { return nil }
        var target = GhosttyPoint()
        target.tag = GHOSTTY_POINT_TAG_VIEWPORT
        target.value.coordinate = GhosttyPointCoordinate(
            x: min(point.column, cols - 1), y: UInt32(min(point.row, rows - 1))
        )
        var reference = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(terminal, target, &reference) == GHOSTTY_SUCCESS else { return nil }
        return reference
    }

    /// Where Ghostty's scrolling bindings move the view.
    public enum ViewportMove: Equatable {
        case top, bottom, pageUp, pageDown, previousPrompt, nextPrompt
    }

    public func moveViewport(_ move: ViewportMove) {
        locked {
            var rows: UInt16 = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            var behavior = GhosttyTerminalScrollViewport()
            switch move {
            case .top: behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP
            case .bottom: behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
            case .pageUp, .pageDown:
                behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
                behavior.value.delta = (move == .pageUp ? -1 : 1) * Int(max(1, rows))
            case .previousPrompt, .nextPrompt:
                behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT
                behavior.value.delta_prompt = move == .previousPrompt ? -1 : 1
            }
            ghostty_terminal_scroll_viewport(terminal, behavior)
            changesLocked &+= 1
        }
    }

    /// A link under the pointer: what it opens and the cells it covers, one
    /// range per row, since a long one wraps.
    public struct Link: Equatable {
        public init(url: String, segments: [Segment]) {
            self.url = url
            self.segments = segments
        }
        public struct Segment: Equatable {
            var row: UInt16
            var columns: ClosedRange<UInt16>
        }

        public var url: String
        public var segments: [Segment]
    }

    /// The text of the soft-wrapped line under a pointer, copied under `lock`,
    /// with the cell each UTF-16 unit came from (in screen rows), and where the
    /// viewport begins in screen rows. The match runs on it after the lock is
    /// released. A line longer than the copy budget is cut, and says so.
    public struct LineText: Equatable {
        public init(
            text: String, cells: [Cell], pointer: Cell, viewportTop: UInt32, viewportRows: UInt16,
            cutBefore: Bool = false, cutAfter: Bool = false
        ) {
            self.text = text
            self.cells = cells
            self.pointer = pointer
            self.viewportTop = viewportTop
            self.viewportRows = viewportRows
            self.cutBefore = cutBefore
            self.cutAfter = cutAfter
        }
        public struct Cell: Equatable {
            var row: UInt32
            var column: UInt16
        }

        public var text: String
        public var cells: [Cell]
        public var pointer: Cell
        public var viewportTop: UInt32
        public var viewportRows: UInt16
        public var cutBefore = false
        public var cutAfter = false
    }

    /// How many cells either side of the pointer's row a wrapped line is
    /// followed for, into scrollback or below the view: a URL of a couple of
    /// thousand characters, at a cost that stays flat however wide the pane.
    public static let lineCellBudget = 1024

    public enum Under: Equatable {
        case hyperlink(Link)
        case text(LineText)
    }

    /// The link at a viewport cell, as Ghostty finds it (`Surface.linkAtPin`):
    /// an OSC 8 hyperlink first, then a URL or a path in the whole soft-wrapped
    /// line, followed past the edges of the view as Ghostty's `selectLine` is.
    public func link(at point: SelectionPoint) -> Link? {
        switch lineUnder(point) {
        case .hyperlink(let link): return link
        case .text(let line): return Self.link(in: line)
        case .none: return nil
        }
    }

    /// What is under a pointer: a hyperlink, or the text of its line to
    /// search. Only this runs under `lock`.
    public func lineUnder(_ point: SelectionPoint) -> Under? {
        locked { () -> Under? in
            var rows: UInt16 = 0
            var cols: UInt16 = 0
            var total = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)
            guard point.row < rows, point.column < cols,
                  var pointerRef = cellReference(column: point.column, row: point.row)
            else { return nil }
            if let uri = hyperlink(&pointerRef) {
                var first = point.column
                var last = point.column
                while first > 0, var reference = cellReference(column: first - 1, row: point.row),
                      hyperlink(&reference) == uri {
                    first -= 1
                }
                while last + 1 < cols, var reference = cellReference(column: last + 1, row: point.row),
                      hyperlink(&reference) == uri {
                    last += 1
                }
                return .hyperlink(Link(url: uri, segments: [.init(row: point.row, columns: first ... last)]))
            }
            var screen = GhosttyPointCoordinate()
            var top = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(terminal, &pointerRef, GHOSTTY_POINT_TAG_SCREEN, &screen)
                    == GHOSTTY_SUCCESS,
                  var viewportTop = cellReference(column: 0, row: 0),
                  ghostty_terminal_point_from_grid_ref(terminal, &viewportTop, GHOSTTY_POINT_TAG_SCREEN, &top)
                    == GHOSTTY_SUCCESS
            else { return nil }
            var pointer = LineText.Cell(row: screen.y, column: point.column)
            switch wide(&pointerRef) {
            case GHOSTTY_CELL_WIDE_SPACER_TAIL where point.column > 0:
                // The right half of a wide character is that character.
                pointer.column -= 1
            case GHOSTTY_CELL_WIDE_SPACER_HEAD:
                // The last column before a wide character that wrapped stands
                // for it, at the start of the next row.
                pointer = .init(row: screen.y + 1, column: 0)
            default:
                break
            }
            let reach = UInt32(max(1, Self.lineCellBudget / Int(max(cols, 1))))
            var first = screen.y
            while first > 0, screen.y - first < reach, wraps(screenRow: first - 1) { first -= 1 }
            var last = screen.y
            while Int(last) + 1 < total, last - screen.y < reach, wraps(screenRow: last) { last += 1 }
            var line = LineText(
                text: "", cells: [], pointer: pointer, viewportTop: top.y, viewportRows: rows,
                cutBefore: first > 0 && wraps(screenRow: first - 1),
                cutAfter: Int(last) + 1 < total && wraps(screenRow: last)
            )
            var buffer = [UInt32](repeating: 0, count: 16)
            for row in first ... last {
                for column in 0 ..< cols {
                    guard var reference = screenReference(column: column, row: row) else { return nil }
                    var length = 0
                    var result = buffer.withUnsafeMutableBufferPointer {
                        ghostty_grid_ref_graphemes(&reference, $0.baseAddress, $0.count, &length)
                    }
                    if result == GHOSTTY_OUT_OF_SPACE, length > buffer.count {
                        buffer = [UInt32](repeating: 0, count: length)
                        result = buffer.withUnsafeMutableBufferPointer {
                            ghostty_grid_ref_graphemes(&reference, $0.baseAddress, $0.count, &length)
                        }
                    }
                    var cell = ""
                    if result == GHOSTTY_SUCCESS, length > 0 {
                        for scalar in buffer.prefix(length).compactMap(Unicode.Scalar.init) {
                            cell.unicodeScalars.append(scalar)
                        }
                    }
                    if cell.isEmpty {
                        // A wide character's second half adds no text.
                        let kind = wide(&reference)
                        if kind == GHOSTTY_CELL_WIDE_SPACER_TAIL || kind == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                        cell = " "
                    }
                    line.text += cell
                    line.cells += Array(repeating: .init(row: row, column: column), count: cell.utf16.count)
                }
            }
            return .text(line)
        }
    }

    /// The link a line's text holds under its pointer, in viewport rows. A
    /// link that runs into a cut edge of the line is not offered: opening the
    /// part of it that was copied would open the wrong place.
    public static func link(in line: LineText) -> Link? {
        guard let index = line.cells.firstIndex(of: line.pointer) else { return nil }
        for range in linkRanges(in: line.text, around: index) {
            let covered = line.cells[range.location ..< range.location + range.length]
            guard covered.contains(line.pointer) else { continue }
            if line.cutBefore && range.location == 0 || line.cutAfter && range.location + range.length == line.cells.count {
                return nil
            }
            var segments: [Link.Segment] = []
            for cell in covered {
                let row = Int64(cell.row) - Int64(line.viewportTop)
                guard row >= 0, row < Int64(line.viewportRows) else { continue }
                if let last = segments.last, last.row == UInt16(row) {
                    segments[segments.count - 1].columns = last.columns.lowerBound ... cell.column
                } else {
                    segments.append(.init(row: UInt16(row), columns: cell.column ... cell.column))
                }
            }
            return Link(url: (line.text as NSString).substring(with: range), segments: segments)
        }
        return nil
    }

    /// How far either side of the pointer paths are searched for. Ghostty's
    /// path patterns cost the square of what they search, so a pasted blob
    /// thousands of characters long is searched only near the pointer.
    public static let pathWindow = 256

    /// Ghostty's links in a text (`config/url.zig`), left to right, none
    /// overlapping: what its one pattern finds scanning from the start. URLs
    /// with a scheme are found over the whole text by `schemeURL`, which
    /// matches Ghostty's scheme branch in one pass; paths by Ghostty's own
    /// path branches, within `pathWindow` of `index`.
    public static func linkRanges(in text: String, around index: Int? = nil) -> [NSRange] {
        let units = Array(text.utf16)
        let window: Range<Int> = index.map { max(0, $0 - pathWindow) ..< min(units.count, $0 + pathWindow) }
            ?? 0 ..< units.count
        var urls: [NSRange] = []
        if let schemes = schemePattern {
            var end = 0
            for match in schemes.matches(in: text, range: NSRange(location: 0, length: units.count))
            where match.range.location >= end {
                if let range = schemeURL(in: units, schemeAt: match.range) {
                    urls.append(range)
                    end = range.location + range.length
                }
            }
        }
        func isPathCharacter(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(units[index]) else { return true }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || "-.~:/?#@!$&*+;=%".unicodeScalars.contains(scalar)
        }
        // Ghostty's paths carry across a single space not after a colon.
        func joins(_ space: Int) -> Bool {
            space > 0 && space + 1 < units.count && units[space] == 0x20
                && isPathCharacter(space - 1) && units[space - 1] != 0x3A && isPathCharacter(space + 1)
        }
        // A path whose characters run past a window edge the text goes past
        // may be longer than what was searched, and is passed over.
        func isCut(_ range: NSRange) -> Bool {
            var start = range.location
            while start > window.lowerBound, isPathCharacter(start - 1) || joins(start - 1) { start -= 1 }
            if start == window.lowerBound, start > 0, isPathCharacter(start - 1) || joins(start - 1) { return true }
            var end = range.location + range.length
            while end < window.upperBound, isPathCharacter(end) || joins(end) { end += 1 }
            return end == window.upperBound && end < units.count && (isPathCharacter(end) || joins(end))
        }
        // The next path from `position`, seen through the window. One search
        // answers every later position up to the path it found, and a search
        // that found none answers all of them.
        var searchedFrom: Int?
        var found: NSRange?
        func nextPath(from position: Int) -> (range: NSRange, whole: Bool)? {
            if let searchedFrom, searchedFrom <= position, found.map({ $0.location >= position }) ?? true {
                return found.map { ($0, !isCut($0)) }
            }
            let start = max(position, window.lowerBound)
            searchedFrom = position
            found = nil
            guard let paths = pathPattern, start < window.upperBound,
                  let match = paths.firstMatch(
                      in: text, options: .withTransparentBounds,
                      range: NSRange(location: start, length: window.upperBound - start)
                  )
            else { return nil }
            found = match.range
            return (match.range, !isCut(match.range))
        }
        var ranges: [NSRange] = []
        var position = 0
        var next = 0
        while true {
            while next < urls.count, urls[next].location < position { next += 1 }
            let url = next < urls.count ? urls[next] : nil
            let path = nextPath(from: position)
            // Leftmost first, and a URL before a path at the same place.
            if let url, path.map({ url.location <= $0.range.location }) ?? true {
                ranges.append(url)
                position = url.location + url.length
            } else if let path {
                if path.whole { ranges.append(path.range) }
                position = path.range.location + max(path.range.length, 1)
            } else {
                return ranges
            }
        }
    }

    /// Ghostty's scheme branch, in one pass:
    /// `scheme(?:ipv6|chars+(?:\(\w*\)|\[\w*\])?)+(?<![,.])`. Its pattern says
    /// this with nested repetition, which ICU backtracks through exponentially.
    public static func schemeURL(in units: [UInt16], schemeAt scheme: NSRange) -> NSRange? {
        let limit = units.count
        func ascii(_ character: Unicode.Scalar) -> UInt16 { UInt16(character.value) }
        /// The width in units of the `\w` character at `index`, or nil.
        func word(at index: Int) -> Int? {
            guard index < limit else { return nil }
            let unit = units[index]
            if UTF16.isLeadSurrogate(unit), index + 1 < limit, UTF16.isTrailSurrogate(units[index + 1]) {
                let scalar = UTF16.decode(UTF16.EncodedScalar([unit, units[index + 1]]))
                return CharacterSet.alphanumerics.contains(scalar) ? 2 : nil
            }
            guard let scalar = Unicode.Scalar(unit) else { return nil }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar) ? 1 : nil
        }
        func urlCharacter(at index: Int) -> Int? {
            guard index < limit else { return nil }
            return word(at: index) ?? ("-.~:/?#@!$&*+,;=%".utf16.contains(units[index]) ? 1 : nil)
        }
        /// The end of a bracketed IPv6 host with an optional port at `index`.
        func ipv6(at index: Int) -> Int? {
            guard index < limit, units[index] == ascii("[") else { return nil }
            var end = index + 1
            while end < limit, ":0123456789abcdefABCDEF".utf16.contains(units[end]) { end += 1 }
            guard end > index + 1, end < limit, units[end] == ascii("]") else { return nil }
            end += 1
            if end < limit, units[end] == ascii(":") {
                var port = end + 1
                while port < limit, "0123456789".utf16.contains(units[port]) { port += 1 }
                if port > end + 1 { end = port }
            }
            return end
        }
        /// The end of a `(word)` or `[word]` suffix at `index`.
        func suffix(at index: Int) -> Int? {
            guard index < limit else { return nil }
            let close: UInt16
            switch units[index] {
            case ascii("("): close = ascii(")")
            case ascii("["): close = ascii("]")
            default: return nil
            }
            var end = index + 1
            while let width = word(at: end) { end += width }
            return end < limit && units[end] == close ? end + 1 : nil
        }
        let body = scheme.location + scheme.length
        var index = body
        while true {
            if let end = ipv6(at: index) {
                index = end
                continue
            }
            let run = index
            while let width = urlCharacter(at: index) { index += width }
            guard index > run else { break }
            if let end = suffix(at: index) { index = end }
        }
        while index > body, units[index - 1] == ascii(".") || units[index - 1] == ascii(",") {
            index -= 1
        }
        return index > body ? NSRange(location: scheme.location, length: index - scheme.location) : nil
    }

    private static let schemePattern = try? NSRegularExpression(
        pattern: #"https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:"#
    )

    private func cellReference(column: UInt16, row: UInt16) -> GhosttyGridRef? {
        var target = GhosttyPoint()
        target.tag = GHOSTTY_POINT_TAG_VIEWPORT
        target.value.coordinate = GhosttyPointCoordinate(x: column, y: UInt32(row))
        var reference = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(terminal, target, &reference) == GHOSTTY_SUCCESS else { return nil }
        return reference
    }

    private func hyperlink(_ reference: inout GhosttyGridRef) -> String? {
        var length = 0
        guard ghostty_grid_ref_hyperlink_uri(&reference, nil, 0, &length) == GHOSTTY_OUT_OF_SPACE, length > 0 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: length)
        guard bytes.withUnsafeMutableBufferPointer({
            ghostty_grid_ref_hyperlink_uri(&reference, $0.baseAddress, length, &length)
        }) == GHOSTTY_SUCCESS else { return nil }
        return String(decoding: bytes.prefix(length), as: UTF8.self)
    }

    private func wide(_ reference: inout GhosttyGridRef) -> GhosttyCellWide {
        var raw: GhosttyCell = 0
        var wide = GHOSTTY_CELL_WIDE_NARROW
        if ghostty_grid_ref_cell(&reference, &raw) == GHOSTTY_SUCCESS {
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        }
        return wide
    }

    private func screenReference(column: UInt16, row: UInt32) -> GhosttyGridRef? {
        var target = GhosttyPoint()
        target.tag = GHOSTTY_POINT_TAG_SCREEN
        target.value.coordinate = GhosttyPointCoordinate(x: column, y: row)
        var reference = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(terminal, target, &reference) == GHOSTTY_SUCCESS else { return nil }
        return reference
    }

    /// Whether a screen row continues on the next one.
    private func wraps(screenRow row: UInt32) -> Bool {
        guard var reference = screenReference(column: 0, row: row) else { return false }
        var gridRow: GhosttyRow = 0
        guard ghostty_grid_ref_row(&reference, &gridRow) == GHOSTTY_SUCCESS else { return false }
        var wrapped = false
        _ = ghostty_row_get(gridRow, GHOSTTY_ROW_DATA_WRAP, &wrapped)
        return wrapped
    }

    /// Ghostty's path branches of its link pattern (`src/config/url.zig`), with
    /// changes that keep its matches: a lookbehind must be bounded, so `\$\d*`
    /// becomes `\$\d{0,9}`; the dot lookaheads scan once, possessively, up to
    /// the first dot; and repetition no later step can use is possessive. Its
    /// scheme branch is `schemeURL`.
    public static let pathPattern: NSRegularExpression? = {
        let pathCharacters = #"[\w\-.~:\/?#@!$&*+;=%]"#
        let noTrailingColon = #"(?<!:)"#
        let dottedLookahead = #"(?=[\w\-~:\/?#@!$&*+;=%]*+\.)"#
        let undottedLookahead = #"(?![\w\-~:\/?#@!$&*+;=%]*+\.)"#
        let dottedSpaceSegments = #"(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]*[\/.])*"#
        let anySpaceSegments = #"(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]+)*"#
        let rootedPrefix = #"(?:\.\.\/|\.\/|(?<!\w)~\/|(?<!\w)(?:[\w][\w\-.]*\/)*+(?<!\w)\$[A-Za-z_]\w*\/|\.[\w][\w\-.]*\/|(?<![\w~\/])\/(?!\/))"#
        let rooted = rootedPrefix + "(?:" + dottedLookahead + pathCharacters + "+" + dottedSpaceSegments + noTrailingColon
            + "|" + undottedLookahead + pathCharacters + "+" + anySpaceSegments + noTrailingColon + ")"
        // Ghostty puts the dotted lookahead before these lookbehinds. ICU
        // tries each at every position, and a lookahead that scans the rest
        // of a long word there costs its square; lookbehinds first is the
        // same match.
        let bare = #"(?<!\$\d{0,9})(?<!\w)"# + dottedLookahead + #"[\w][\w\-.]*\/"# + pathCharacters + "+" + noTrailingColon
        do {
            return try NSRegularExpression(pattern: rooted + "|" + bare)
        } catch {
            // Only detected paths go; URLs and OSC 8 hyperlinks still work.
            StreamLog.logger.error("path pattern does not compile: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    /// Whether the view follows the live screen, rather than showing history.
    public var followsLiveScreen: Bool {
        locked {
            var active = true
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &active)
            return active
        }
    }

    /// Back to the live screen, as a keystroke does in Ghostty.
    public func scrollViewportToBottom() {
        locked { scrollToBottomLocked() }
    }

    /// The cursor's cell on the active screen.
    public var cursorPosition: (x: UInt16, y: UInt16)? {
        locked {
            var x: UInt16 = 0
            var y: UInt16 = 0
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x) == GHOSTTY_SUCCESS,
                  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y) == GHOSTTY_SUCCESS
            else { return nil }
            return (x, y)
        }
    }

    private func scrollToBottomLocked() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(terminal, behavior)
        changesLocked &+= 1
    }

    /// Applies an `E vt_resize` marker: the same operation the daemon's sidecar
    /// applied at this byte (`SidecarCommand::Resize` in `termiod/src/session.rs`).
    /// `reflow` is set when no shell held the terminal, and the screen rewraps;
    /// otherwise this is `resize_for_shell`.
    public func resize(rows: UInt16, cols: UInt16, reflow: Bool) throws {
        try locked {
            changesLocked &+= 1
            if reflow {
                try resizeReflowing(rows: rows, cols: cols)
            } else {
                try resizeForShell(rows: rows, cols: cols)
            }
        }
    }

    /// What the terminal holds, in a form two engines can be compared by: the
    /// grid and its pixel size, the cursor, the active screen, and the screen
    /// serialised as VT with styles, modes, charsets and keyboard state. The
    /// parity test reads it against what termiod's VT recorded.
    public struct Screen: Equatable {
        public init(rows: UInt16, cols: UInt16, widthPixels: UInt32, heightPixels: UInt32, cursorX: UInt16, cursorY: UInt16, alternate: Bool, vt: Data) {
            self.rows = rows
            self.cols = cols
            self.widthPixels = widthPixels
            self.heightPixels = heightPixels
            self.cursorX = cursorX
            self.cursorY = cursorY
            self.alternate = alternate
            self.vt = vt
        }
        public var rows: UInt16
        public var cols: UInt16
        public var widthPixels: UInt32
        public var heightPixels: UInt32
        public var cursorX: UInt16
        public var cursorY: UInt16
        public var alternate: Bool
        public var vt: Data
    }

    public func screen() throws -> Screen {
        try locked { try screenLocked() }
    }

    private func screenLocked() throws -> Screen {
        var rows: UInt16 = 0
        var cols: UInt16 = 0
        var widthPixels: UInt32 = 0
        var heightPixels: UInt32 = 0
        var cursorX: UInt16 = 0
        var cursorY: UInt16 = 0
        var active = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        try get(GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        try get(GHOSTTY_TERMINAL_DATA_COLS, &cols)
        try get(GHOSTTY_TERMINAL_DATA_WIDTH_PX, &widthPixels)
        try get(GHOSTTY_TERMINAL_DATA_HEIGHT_PX, &heightPixels)
        try get(GHOSTTY_TERMINAL_DATA_CURSOR_X, &cursorX)
        try get(GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursorY)
        try get(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active)
        return Screen(
            rows: rows, cols: cols, widthPixels: widthPixels, heightPixels: heightPixels,
            cursorX: cursorX, cursorY: cursorY,
            alternate: active == GHOSTTY_TERMINAL_SCREEN_ALTERNATE, vt: try formattedVT()
        )
    }

    /// The options `VtTerminal::format_vt` formats with, so the two engines'
    /// output can be compared byte for byte.
    private func formattedVT() throws -> Data {
        // The extras `VtTerminal::vt_formatter` sets: no PALETTE, so the
        // viewer's theme applies, and no TABSTOPS, whose walk lands the cursor
        // on the last stop ahead of the content.
        let extras: GhosttyFormatterExtras = GHOSTTY_FORMATTER_EXTRA_MODES
            | GHOSTTY_FORMATTER_EXTRA_SCROLLING_REGION
            | GHOSTTY_FORMATTER_EXTRA_PWD
            | GHOSTTY_FORMATTER_EXTRA_KEYBOARD
            | GHOSTTY_FORMATTER_EXTRA_CURSOR
            | GHOSTTY_FORMATTER_EXTRA_STYLE
            | GHOSTTY_FORMATTER_EXTRA_HYPERLINK
            | GHOSTTY_FORMATTER_EXTRA_PROTECTION
            | GHOSTTY_FORMATTER_EXTRA_KITTY_KEYBOARD
            | GHOSTTY_FORMATTER_EXTRA_CHARSETS
        let options = FormatOptions(emit: GHOSTTY_FORMATTER_FORMAT_VT, unwrap: false, trim: false, extras: extras)
        return try format(options)
    }

    /// What one format call asks of the formatter. libghostty-vt sets these
    /// one option at a time on the formatter, never as one struct.
    private struct FormatOptions {
        var emit: GhosttyFormatterFormat
        var unwrap: Bool
        var trim: Bool
        var selection: GhosttySelection?
        var extras: GhosttyFormatterExtras = 0
    }

    private func format(_ options: FormatOptions) throws -> Data {
        var formatter: GhosttyFormatter?
        try Self.check(ghostty_formatter_terminal_new(nil, &formatter, terminal), "ghostty_formatter_terminal_new")
        guard let formatter else {
            throw Failure.engine("ghostty_formatter_terminal_new", GHOSTTY_INVALID_VALUE)
        }
        defer { ghostty_formatter_free(formatter) }
        func set<Value: BitwiseCopyable>(_ option: GhosttyFormatterOption, _ value: Value, _ name: String) throws {
            try withUnsafePointer(to: value) { pointer in
                try Self.check(ghostty_formatter_set(formatter, option, pointer), name)
            }
        }
        try set(GHOSTTY_FORMATTER_OPT_EMIT, options.emit, "GHOSTTY_FORMATTER_OPT_EMIT")
        try set(GHOSTTY_FORMATTER_OPT_UNWRAP, options.unwrap, "GHOSTTY_FORMATTER_OPT_UNWRAP")
        try set(GHOSTTY_FORMATTER_OPT_TRIM, options.trim, "GHOSTTY_FORMATTER_OPT_TRIM")
        try set(GHOSTTY_FORMATTER_OPT_EXTRAS, options.extras, "GHOSTTY_FORMATTER_OPT_EXTRAS")
        if let selection = options.selection {
            try set(GHOSTTY_FORMATTER_OPT_SELECTION, selection, "GHOSTTY_FORMATTER_OPT_SELECTION")
        }
        // A blank screen formats to nothing, which the allocating call reports
        // as an error, so this sizes first and writes into a buffer.
        var length = 0
        let sizing = ghostty_formatter_format_buf(formatter, nil, 0, &length)
        guard sizing != GHOSTTY_SUCCESS else { return Data() }
        guard sizing == GHOSTTY_OUT_OF_SPACE else {
            throw Failure.engine("ghostty_formatter_format_buf(size)", sizing)
        }
        var text = Data(count: length)
        var written = 0
        let result = text.withUnsafeMutableBytes { buffer in
            ghostty_formatter_format_buf(
                formatter, buffer.bindMemory(to: UInt8.self).baseAddress, length, &written
            )
        }
        try Self.check(result, "ghostty_formatter_format_buf")
        return text.prefix(written)
    }

    /// A port of `VtTerminal::resize_for_shell`, which documents why: with
    /// OSC 133 marks, blank the prompt the cursor sits in and then reflow, so
    /// the shell's SIGWINCH redraw lands on clean rows; without them, resize
    /// without reflowing, the way the shell's redraw arithmetic assumes.
    private func resizeForShell(rows: UInt16, cols: UInt16) throws {
        guard let promptRow = try currentPromptStart() else {
            try resizeTruncating(rows: rows, cols: cols)
            return
        }
        writeLocked(Data("\u{1b}7\u{1b}[\(UInt32(promptRow) + 1);1H\u{1b}[J\u{1b}8".utf8))
        try resizeReflowing(rows: rows, cols: cols)
    }

    /// `VtTerminal::resize`: libghostty reflows only while wraparound is on, so
    /// turning it off for the resize is what truncates.
    private func resizeTruncating(rows: UInt16, cols: UInt16) throws {
        let wraparound = try mode(GHOSTTY_MODE_WRAPAROUND_VALUE)
        if wraparound {
            try setMode(GHOSTTY_MODE_WRAPAROUND_VALUE, false)
        }
        let resized = Result { try resizeReflowing(rows: rows, cols: cols) }
        if wraparound {
            // Restored even when the resize failed: the mode is the program's.
            try setMode(GHOSTTY_MODE_WRAPAROUND_VALUE, true)
        }
        try resized.get()
    }

    private func resizeReflowing(rows: UInt16, cols: UInt16) throws {
        try Self.check(
            ghostty_terminal_resize(terminal, cols, rows, Self.cellWidth, Self.cellHeight),
            "ghostty_terminal_resize"
        )
    }

    /// `VtTerminal::current_prompt_start`: the first row of the prompt the
    /// cursor is in, or nil whenever the marks do not say so for certain.
    private func currentPromptStart() throws -> UInt16? {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        try get(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        guard screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY else { return nil }
        var row: UInt16 = 0
        try get(GHOSTTY_TERMINAL_DATA_CURSOR_Y, &row)
        while true {
            switch try semanticPrompt(row: row) {
            case GHOSTTY_ROW_SEMANTIC_PROMPT:
                return row
            case GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION where row > 0:
                row -= 1
            default:
                return nil
            }
        }
    }

    private func semanticPrompt(row: UInt16) throws -> GhosttyRowSemanticPrompt {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_ACTIVE
        point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(row))
        var reference = GhosttyGridRef()
        try Self.check(ghostty_terminal_grid_ref(terminal, point, &reference), "ghostty_terminal_grid_ref")
        var gridRow: GhosttyRow = 0
        try Self.check(ghostty_grid_ref_row(&reference, &gridRow), "ghostty_grid_ref_row")
        var prompt = GHOSTTY_ROW_SEMANTIC_NONE
        try Self.check(ghostty_row_get(gridRow, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &prompt), "ghostty_row_get")
        return prompt
    }

    private func mode(_ mode: GhosttyMode) throws -> Bool {
        var config = GhosttyTerminalModeConfig(mode: mode, value: false)
        try get(GHOSTTY_TERMINAL_DATA_MODE, &config)
        return config.value
    }

    private func setMode(_ mode: GhosttyMode, _ value: Bool) throws {
        var config = GhosttyTerminalModeConfig(mode: mode, value: value)
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &config), "ghostty_terminal_set(mode)")
    }

    private func get<Value>(_ data: GhosttyTerminalData, _ value: inout Value) throws {
        try Self.check(ghostty_terminal_get(terminal, data, &value), "ghostty_terminal_get")
    }

    private static func check(_ result: GhosttyResult, _ call: String) throws {
        guard result == GHOSTTY_SUCCESS else { throw Failure.engine(call, result) }
    }
}

/// `GHOSTTY_MODE_WRAPAROUND` is a function-like macro, which Swift does not import.
private let GHOSTTY_MODE_WRAPAROUND_VALUE = ghostty_mode_new(7, false)

/// This module's log, filed where the Mac's termiod lines go.
enum StreamLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "sh.termio.app", category: "termiod")
}

extension TermiodStreamTerminal.Theme {
    /// A theme from colors written as Ghostty's theme files write them
    /// (`rrggbb`, with or without `#`), over xterm's 256: what the Mac and the
    /// phone each build from their own theme settings. Nil when the
    /// foreground or background does not parse.
    public init?(
        hexForeground foreground: String, background: String, palette: [Int: String], cursor: String?,
        cursorText: String?, selectionBackground: String?, selectionForeground: String?,
        cursorStyle: GhosttyCursorStyle, cursorBlink: Bool, minimumContrast: Double, dark: Bool
    ) {
        guard let foreground = Self.rgb(foreground), let ground = Self.rgb(background) else { return nil }
        var colors = Self.xtermPalette
        for (index, hex) in palette where (0..<256).contains(index) {
            if let color = Self.rgb(hex) { colors[index] = color }
        }
        self.init(
            foreground: foreground, background: ground, cursor: cursor.flatMap(Self.rgb), palette: colors,
            cursorStyle: cursorStyle, cursorBlink: cursorBlink, cursorText: cursorText.flatMap(Self.rgb),
            minimumContrast: minimumContrast, selectionBackground: selectionBackground.flatMap(Self.rgb),
            selectionForeground: selectionForeground.flatMap(Self.rgb), dark: dark)
    }

    public static func rgb(_ hex: String) -> GhosttyColorRgb? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return GhosttyColorRgb(r: UInt8(value >> 16 & 0xff), g: UInt8(value >> 8 & 0xff), b: UInt8(value & 0xff))
    }

    /// xterm's 256 colors: the 16 a theme usually overrides, the 6x6x6 cube,
    /// and the grey ramp.
    public static let xtermPalette: [GhosttyColorRgb] = {
        let base: [UInt32] = [
            0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
            0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
        ]
        var colors = base.map { GhosttyColorRgb(r: UInt8($0 >> 16), g: UInt8($0 >> 8 & 0xff), b: UInt8($0 & 0xff)) }
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for red in steps { for green in steps { for blue in steps {
            colors.append(GhosttyColorRgb(r: red, g: green, b: blue))
        } } }
        for index in 0..<24 {
            let level = UInt8(8 + index * 10)
            colors.append(GhosttyColorRgb(r: level, g: level, b: level))
        }
        return colors
    }()
}
