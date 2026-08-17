import Foundation

/// Decodes the daemon's `S` snapshot frame and synthesises the ANSI byte
/// stream that repaints it into a libghostty surface.
///
/// This is what turns a reattach from M2's ring-replay tear into a clean
/// repaint: instead of replaying a torrent of historical escapes (which mangles
/// an idle TUI), the daemon's authoritative VT hands us the *current* grid and
/// we redraw exactly that frame, then live `D` bytes resume on top.
///
/// The wire cell already carries fully resolved colours — the host VT folds
/// `inverse` into an fg/bg swap and `invisible` into a zero codepoint before it
/// packs the cell (see `termiod/vt/src/lib.rs`), and the `attributes` field is
/// reserved-zero in this format version. So the synthesiser only needs
/// truecolour SGR plus text; bold/underline/italic are intentionally not
/// carried yet (a later additive wire extension).
enum TermiodSnapshot {
    struct Cell: Equatable {
        var codepoint: UInt32
        var foreground: (UInt8, UInt8, UInt8)
        var background: (UInt8, UInt8, UInt8)

        static func == (lhs: Cell, rhs: Cell) -> Bool {
            lhs.codepoint == rhs.codepoint
                && lhs.foreground == rhs.foreground
                && lhs.background == rhs.background
        }
    }

    struct Frame {
        var rows: Int
        var cols: Int
        var cursorX: Int
        var cursorY: Int
        var alternateScreen: Bool
        var title: String
        var cells: [Cell]
        /// Set for payload v2 — the repaint, already in the terminal's own
        /// language. When present, `cells` is empty and `render` is a pass-through.
        var vt: Data?
    }

    /// Snapshot payload v1 (see `encode_snapshot_payload` in `protocol.rs`):
    /// version:u8, rows/cols/cursor_x/cursor_y:u16be, alt_screen:u8,
    /// title_len:u16be, UTF-8 title, then row-major 16-byte cells —
    /// codepoint:u32be, fg RGB, bg RGB, attributes:u16be, 4 reserved bytes.
    static let formatVersion: UInt8 = 1
    /// Payload v2 carries VT sequences instead of packed cells. Preferred: the
    /// host describes screen *content* and this client's libghostty decides how
    /// it looks, so the local theme, the ANSI palette, and bold/underline/OSC 8
    /// all survive. v1 resolved colour host-side and overrode the theme.
    static let vtFormatVersion: UInt8 = 2
    static let cellSize = 16

    static func decode(_ payload: Data) -> Frame? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 12,
              bytes[0] == formatVersion || bytes[0] == vtFormatVersion
        else { return nil }
        let isVT = bytes[0] == vtFormatVersion

        func u16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        let rows = u16(1)
        let cols = u16(3)
        let cursorX = u16(5)
        let cursorY = u16(7)
        let alternateScreen = bytes[9] != 0
        let titleLength = u16(10)

        let cellsOffset = 12 + titleLength
        guard cellsOffset <= bytes.count,
              let title = String(bytes: bytes[12..<cellsOffset], encoding: .utf8)
        else { return nil }

        if isVT {
            // Format v2: the host serialised the screen back into VT sequences.
            // Nothing to synthesise — the bytes go straight to libghostty, which
            // is what lets the *viewer's* theme, palette and SGR handling apply.
            guard bytes.count >= cellsOffset + 4 else { return nil }
            let length = Int(bytes[cellsOffset]) << 24 | Int(bytes[cellsOffset + 1]) << 16
                | Int(bytes[cellsOffset + 2]) << 8 | Int(bytes[cellsOffset + 3])
            let start = cellsOffset + 4
            guard bytes.count == start + length else { return nil }
            return Frame(
                rows: rows, cols: cols, cursorX: cursorX, cursorY: cursorY,
                alternateScreen: alternateScreen, title: title, cells: [],
                vt: Data(bytes[start..<(start + length)])
            )
        }

        let cellCount = rows * cols
        guard bytes.count == cellsOffset + cellCount * cellSize else { return nil }

        var cells = [Cell]()
        cells.reserveCapacity(cellCount)
        var offset = cellsOffset
        for _ in 0..<cellCount {
            let codepoint = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            cells.append(Cell(
                codepoint: codepoint,
                foreground: (bytes[offset + 4], bytes[offset + 5], bytes[offset + 6]),
                background: (bytes[offset + 7], bytes[offset + 8], bytes[offset + 9])
            ))
            offset += cellSize
        }

        return Frame(
            rows: rows, cols: cols, cursorX: cursorX, cursorY: cursorY,
            alternateScreen: alternateScreen, title: title, cells: cells
        )
    }

    /// Builds the repaint byte stream. Runs of cells sharing colours coalesce
    /// into one SGR + text run to keep the stream small. The result is
    /// idempotent — feeding it again repaints the same frame — so a mid-session
    /// keyframe (the resize barrier's fresh `S`) can reuse it verbatim.
    static func render(_ frame: Frame) -> Data {
        // v2: the host already produced the repaint, prologue included. Replay it
        // verbatim — deciding anything about colour here is exactly the bug this
        // format exists to fix, and a client-side prelude is what the host-owned
        // prologue replaces. The old one was also asymmetric in the same way the
        // formatter is: it entered the alternate screen for an alt-screen frame
        // but never left it, so a primary-screen snapshot arriving while this
        // surface still sat in alt repainted onto the wrong buffer.
        if let vt = frame.vt {
            return vt
        }

        var output = String()
        // Alt-screen frames (vim, top) must repaint on the alternate buffer, or
        // the redraw lands on the primary screen and the live TUI paints over a
        // stale scrollback. Primary-screen frames leave the buffer alone.
        if frame.alternateScreen {
            output += "\u{1b}[?1049h"
        }
        output += "\u{1b}[2J\u{1b}[H"

        for row in 0..<frame.rows {
            output += "\u{1b}[\(row + 1);1H"
            var column = 0
            while column < frame.cols {
                let cell = frame.cells[row * frame.cols + column]
                // Extend the run while colours hold.
                var runEnd = column + 1
                while runEnd < frame.cols {
                    let next = frame.cells[row * frame.cols + runEnd]
                    if next.foreground != cell.foreground || next.background != cell.background {
                        break
                    }
                    runEnd += 1
                }
                let (fr, fg, fb) = cell.foreground
                let (br, bg, bb) = cell.background
                output += "\u{1b}[38;2;\(fr);\(fg);\(fb);48;2;\(br);\(bg);\(bb)m"
                for index in column..<runEnd {
                    let point = frame.cells[row * frame.cols + index].codepoint
                    output.unicodeScalars.append(Unicode.Scalar(point == 0 ? 32 : point)
                        ?? Unicode.Scalar(32))
                }
                column = runEnd
            }
        }

        output += "\u{1b}[0m\u{1b}[\(frame.cursorY + 1);\(frame.cursorX + 1)H"
        return Data(output.utf8)
    }
}
