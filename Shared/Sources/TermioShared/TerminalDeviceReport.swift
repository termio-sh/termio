import Foundation

/// Tells a terminal's *device report* apart from the person's keystrokes.
///
/// Every attachment to a session runs its own libghostty, and libghostty
/// answers a host query (XTVERSION, DA, DSR, DECRQM, a colour or clipboard
/// query) on its own, through the same write path keystrokes take. With one
/// PTY and several attachments that is one query and several answers — and
/// the answers are indistinguishable from typing to everything downstream.
/// Two things go wrong: the late duplicates miss the agent's parse window and
/// land in its input line as literal text (a stray `>|ghostty 1.3.2…`), and
/// on a client that claims the write token by writing, an observer's reply
/// *claims the token* and drags the PTY back to its own grid. So the rule on
/// both ends is: a report passes only from the writer, and never claims.
///
/// libghostty has no hook that marks a write as generated, so this is a
/// grammar of exactly the replies it emits (`termio/stream_handler.zig`,
/// `terminal/modes.zig`, `terminal/formatter.zig`), each as one standalone
/// write:
///
///   • `ESC [ … c`        Device Attributes, primary (`?62;22c`) and secondary (`>1;10;0c`)
///   • `ESC [ … n`        DSR operating status (`0n`)
///   • `ESC [ … R`        Cursor Position Report
///   • `ESC [ … $ y`      DECRQM mode report, with or without `?`
///   • `ESC [ … t`        XTWINOPS size and title reports
///   • `ESC [ ? … u`      kitty keyboard protocol flags — only with `?`: a key
///                        press under that protocol is `ESC [ code ; mods u`
///   • `ESC [ > … m`      XTQMODKEYS report — only with `>`: SGR mouse input is
///                        `ESC [ < … M` / `m`
///   • `ESC [ I` / `ESC [ O`
///                        focus in / focus out, with no parameters. libghostty
///                        emits one the instant it parses `CSI ? 1004 h`
///                        (`stream_handler.zig`, `.focus_event => if (enabled)`),
///                        and a snapshot replays that mode — so every keyframe
///                        makes every attachment write one. Read as typing they
///                        are the resize storm this type exists to stop: Claude
///                        Code and Codex both enable 1004, so each barrier
///                        keyframe handed the token to whichever surface parsed
///                        it first, which re-asserted its own grid, which was
///                        another barrier. A plain shell never sets 1004, which
///                        is why only the agent TUIs shook.
///   • `ESC P > | …`      XTVERSION;  `ESC P n $ r …` DECRQSS;  `ESC P n + r …` XTGETTCAP
///   • `ESC _ G i=… ; …`  kitty graphics replies; `ESC _ 25a1 ; …` glyph
///                        protocol replies
///   • `ESC ] 4 ; …`, `ESC ] 10–19 ; …`, `ESC ] 21 …`, `ESC ] 52 ; …`
///                        colour, kitty colour, and clipboard query answers
///   • `ESC ] 5522 ; type=…:status=…`
///                        kitty clipboard replies, except a terminal-initiated
///                        paste event, which also carries `:pw=` and is input
///
/// Everything else is input: arrows and function keys end a CSI in A–Z, `~`
/// or `u` without `?`; mouse reports carry `<`; a bare Esc is a lone byte;
/// typed text has no ESC lead-in; a paste arrives inside `ESC [ 200 ~`.
///
/// One collision is xterm's, not ours: a modified F3 in the legacy encoding
/// is `ESC [ 1 ; mod R`, the same shape as a cursor report for row 1, columns
/// 2–16 — and a fresh prompt answering `CSI 6 n` from column 3 of row 1 is
/// exactly that report. Bytes alone cannot tell the two apart, so the report
/// reading wins: an observer's modified F3 is dropped, which costs one
/// keypress, where the other reading would let a real report claim the token
/// and start the resize storm again. Under the kitty keyboard protocol, which
/// every agent TUI enables, F3 is `ESC [ 13 ~` and the collision does not
/// arise. The exact answer is a wrapper hook that marks generated replies at
/// the write callback; that lives in the libghostty-swift fork.
public enum TerminalDeviceReport {
    public static func isReport(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 0x1B else { return false }
        switch bytes[1] {
        case 0x5B: // ESC [
            return isControlSequenceReport(bytes)
        case 0x50: // ESC P
            return isDeviceControlReport(bytes)
        case 0x5D: // ESC ]
            return isOperatingSystemCommandReport(bytes)
        case 0x5F: // ESC _
            return isApplicationProgramCommandReport(bytes)
        default:
            return false
        }
    }

    private static func isControlSequenceReport(_ bytes: [UInt8]) -> Bool {
        let marker = bytes[2]
        var index = 2
        while index < bytes.count {
            let byte = bytes[index]
            // The final byte of a CSI is the first in 0x40–0x7E.
            if byte >= 0x40, byte <= 0x7E {
                switch byte {
                case 0x63, 0x6E, 0x52, 0x79, 0x74: // c n R y t
                    return true
                case 0x49, 0x4F: // I O
                    // A focus report carries nothing between the introducer and
                    // its final byte, and no key encodes to those three bytes.
                    return index == 2
                case 0x75: // u
                    return marker == 0x3F // ?
                case 0x6D: // m
                    return marker == 0x3E // >
                default:
                    return false
                }
            }
            index += 1
        }
        return false
    }

    private static func isDeviceControlReport(_ bytes: [UInt8]) -> Bool {
        // XTVERSION: `ESC P > |`.
        if bytes[2] == 0x3E { return bytes.count > 3 && bytes[3] == 0x7C }
        // DECRQSS `ESC P n $ r` and XTGETTCAP `ESC P n + r`, n a status digit.
        var index = 2
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        guard index > 2, index + 1 < bytes.count else { return false }
        return (bytes[index] == 0x24 || bytes[index] == 0x2B) && bytes[index + 1] == 0x72
    }

    private static func isOperatingSystemCommandReport(_ bytes: [UInt8]) -> Bool {
        var number = 0
        var index = 2
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            number = number * 10 + Int(bytes[index] - 0x30)
            index += 1
            if number > 9999 { return false }
        }
        // The number, then the `;` every reply puts before its payload.
        guard index > 2, index < bytes.count, bytes[index] == 0x3B else { return false }
        switch number {
        case 4, 5, 10...19, 21, 52:
            return true
        case 5522:
            // Kitty clipboard requests omit `status`; terminal-initiated paste
            // events deliberately look like replies but uniquely carry `:pw=`.
            return bytes[index...].starts(with: [0x3B, 0x74, 0x79, 0x70, 0x65, 0x3D])
                && bytes[index...].containsSlice([0x3A, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x3D])
                && !bytes[index...].containsSlice([0x3A, 0x70, 0x77, 0x3D])
        default:
            return false
        }
    }

    private static func isApplicationProgramCommandReport(_ bytes: [UInt8]) -> Bool {
        // Kitty graphics replies carry an image id or image number before the
        // payload separator; requests start with an action (`a=`) or another
        // command field instead.
        if bytes.count >= 5, bytes[2] == 0x47 { // G
            return bytes[3] == 0x69 || bytes[3] == 0x49 // i I
        }

        // Glyph replies use the protocol namespace and either advertise formats
        // or include a status field. Requests never include either response field.
        let glyphPrefix: [UInt8] = [0x32, 0x35, 0x61, 0x31, 0x3B] // 25a1;
        guard bytes[2...].starts(with: glyphPrefix) else { return false }
        let payload = bytes[(2 + glyphPrefix.count)...]
        return payload.starts(with: [0x73, 0x3B, 0x66, 0x6D, 0x74, 0x3D]) // s;fmt=
            || payload.containsSlice([0x3B, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x3D]) // ;status=
    }
}

private extension Collection where Element == UInt8 {
    func containsSlice(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return indices.dropLast(needle.count - 1).contains { start in
            var index = start
            for byte in needle {
                guard self[index] == byte else { return false }
                formIndex(after: &index)
            }
            return true
        }
    }
}
