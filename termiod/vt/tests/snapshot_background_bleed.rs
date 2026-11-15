//! A snapshot payload must not paint a background the host never set.
//!
//! The `Vt` formatter writes a run of blank cells under whatever style the
//! preceding run left active. Claude Code's banner sets a literal black
//! background for its block art, jumps the cursor past three untouched columns
//! with CHA, and only then restores the default — so the formatter re-serialised
//! that gap as spaces inside the black run and every attach, resync and resize
//! repainted a black rectangle beside "Claude Code".
//!
//! Fixed in ghostty's formatter (`terminal/formatter.zig`), which already reset
//! the style before a run of blank *rows* for this exact reason and did not for
//! blank *cells*. A repair in the daemon was tried first and reverted: its CUP
//! was redirected by origin mode onto real text, and the DECSC slot it borrowed
//! is one an already-attached client still holds across a resync.

use termiod_vt::{Cell, Color, Rgb, VtTerminal};

/// The banner's first two rows, byte for byte off a real `claude` v2.1.246 PTY.
const BANNER: &[u8] = b"\x1b[2J\x1b[H\r\x1b[1B\x1b[38;2;215;119;87m \xe2\x96\x90\
\x1b[48;2;0;0;0m\xe2\x96\x9b\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x9b\xe2\x96\x88\
\x1b[12G\x1b[39m\x1b[49m\x1b[1mClaude Code\x1b[24G\x1b[22m\
\x1b[38;2;153;153;153mv2.1.246\r\x1b[1B\x1b[38;2;215;119;87m\xe2\x96\x9d\xe2\x96\x9c\
\x1b[48;2;0;0;0m\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\x1b[49m\
\xe2\x96\x88\xe2\x96\x80\x1b[12G\x1b[38;2;153;153;153mOpus 5 (1M context)\r\n";

fn cells(vt: &mut VtTerminal) -> Vec<Cell> {
    vt.snapshot().expect("snapshot").cells
}

fn replay(host: &mut VtTerminal, rows: u16, cols: u16) -> VtTerminal {
    let payload = host.format_vt().expect("format_vt");
    let mut client = VtTerminal::new(rows, cols).expect("client terminal");
    client.vt_write(&payload);
    client
}

#[test]
fn replayed_banner_leaves_no_background_the_host_never_set() {
    let mut host = VtTerminal::new(24, 100).expect("host terminal");
    host.vt_write(BANNER);
    let mut client = replay(&mut host, 24, 100);

    let host_cells = cells(&mut host);
    let client_cells = cells(&mut client);
    for (index, (want, got)) in host_cells.iter().zip(client_cells.iter()).enumerate() {
        assert_eq!(
            want.background,
            got.background,
            "cell {} (row {}, col {}) replayed with background {:?}, host holds {:?}",
            index,
            index / 100 + 1,
            index % 100 + 1,
            got.background,
            want.background
        );
    }
}

/// The exact reported artifact: columns 9-11 of the banner's first row are
/// jumped over by `ESC[12G` and never written, so nothing may paint them.
#[test]
fn the_column_the_cursor_jumped_stays_unpainted() {
    let mut host = VtTerminal::new(24, 100).expect("host terminal");
    host.vt_write(BANNER);
    let mut client = replay(&mut host, 24, 100);

    let client_cells = cells(&mut client);
    for column in 9..=11 {
        let cell = &client_cells[100 + column - 1];
        assert_eq!(
            cell.background,
            Color::Default,
            "row 1 col {column} replayed with background {:?}",
            cell.background
        );
    }
    // The art itself keeps the background the program really asked for.
    assert_eq!(
        client_cells[100 + 3].background,
        Color::Rgb(Rgb { r: 0, g: 0, b: 0 }),
        "the block art's own black background must survive the repair"
    );
}

/// Claude Code draws on the alternate screen, which the formatter serialises by
/// a different path than the primary. The repair has to hold on both.
#[test]
fn the_repair_holds_on_the_alternate_screen() {
    let mut host = VtTerminal::new(24, 100).expect("host terminal");
    host.vt_write(b"\x1b[?1049h");
    host.vt_write(BANNER);
    let mut client = replay(&mut host, 24, 100);

    let host_cells = cells(&mut host);
    let client_cells = cells(&mut client);
    for (index, (want, got)) in host_cells.iter().zip(client_cells.iter()).enumerate() {
        assert_eq!(
            want.background,
            got.background,
            "alt-screen cell {} (row {}, col {}) replayed with background {:?}, host holds {:?}",
            index,
            index / 100 + 1,
            index % 100 + 1,
            got.background,
            want.background
        );
    }
    assert_eq!(
        client_cells[100 + 8].background,
        Color::Default,
        "row 1 col 9 must stay unpainted on the alternate screen too"
    );
}

/// The bleed also reached cells a pending-wrap cursor sits behind, which the
/// reverted daemon-side repair skipped entirely.
#[test]
fn the_bleed_is_gone_under_pending_wrap() {
    let mut host = VtTerminal::new(3, 10).expect("host terminal");
    host.vt_write(b"\x1b[41mX\x1b[5G\x1b[0m123456");
    let mut client = replay(&mut host, 3, 10);
    let (host_row, client_row) = (cells(&mut host), cells(&mut client));
    for column in 0..10 {
        assert_eq!(
            host_row[column].background, client_row[column].background,
            "pending-wrap row, col {} replayed with background {:?}",
            column + 1, client_row[column].background
        );
    }
}

/// And to rows that have scrolled into history, which a repair reading only the
/// active grid could never have reached.
#[test]
fn the_bleed_is_gone_from_scrollback() {
    let mut host = VtTerminal::new(3, 10).expect("host terminal");
    host.vt_write(b"\x1b[41mX\x1b[5G\x1b[0mZ\r\nline2\r\nline3\r\nline4");
    let client = replay(&mut host, 3, 10);
    let host_history = host.scrollback(1).expect("host scrollback");
    let client_history = client.scrollback(1).expect("client scrollback");
    for (column, (want, got)) in host_history.rows[0]
        .iter()
        .zip(client_history.rows[0].iter())
        .enumerate()
    {
        assert_eq!(
            want.background, got.background,
            "scrolled-off row, col {} replayed with background {:?}",
            column + 1, got.background
        );
    }
}
