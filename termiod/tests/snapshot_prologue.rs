//! Delta D2 (§F.1): the `S` payload owns its prologue.
//!
//! Applying one snapshot to a client screen in *any* prior state — alt-screen
//! active, a scrolling region set, a charset shifted in, an SGR left pending,
//! stale content from before the attach — must land on the same screen as
//! applying it to a fresh terminal. Only then can a client apply `S` raw, which
//! is what D2 requires of them: today the reference client prepends
//! `ESC[2J ESC[H`, the Mac and iOS clients are free to prepend something else,
//! and none of those preludes clears mode state.
//!
//! This test builds the payload the way the daemon does (`VtTerminal::format_vt`)
//! and applies it to both a clean and a dirty terminal, so a failure names the
//! exact state the prologue does not cover. That list is the spec for the fix —
//! it says which mode resets the prologue owes, and nothing more, so the reset
//! stays scoped instead of reaching for `RIS` and clearing state the client
//! legitimately owns.

use termiod_vt::{Cell, Snapshot, VtTerminal};

const ROWS: u16 = 24;
const COLS: u16 = 80;

/// The screen the host is asked to describe. Styled and partly blank on
/// purpose: the blank rows are what a stale client screen shows through if the
/// payload only paints what it has, and the styles are what a pending SGR
/// bleeds into.
fn host_payload() -> Vec<u8> {
    let mut host = VtTerminal::new(ROWS, COLS).expect("host terminal");
    host.vt_write(b"plain first line\r\n");
    host.vt_write(b"\x1b[1;32mbold green\x1b[0m and default\r\n");
    host.vt_write(b"\x1b[4munderlined\x1b[24m tail\r\n");
    host.vt_write(b"\r\n");
    host.vt_write(b"cursor rests after this");
    host.format_vt().expect("format_vt")
}

/// One client applying the payload after `prelude` — the state it was already
/// in when the snapshot arrived.
fn applied(payload: &[u8], prelude: &[u8]) -> Snapshot {
    let mut client = VtTerminal::new(ROWS, COLS).expect("client terminal");
    client.vt_write(prelude);
    client.vt_write(payload);
    client.snapshot().expect("client snapshot")
}

/// Screen state a client can plausibly be sitting in when `S` arrives. Every
/// one of these is reachable from an ordinary session: an editor left the alt
/// screen up, a pager set a region, a TUI shifted charsets, a truncated write
/// left an SGR open, or the previous attach simply painted a different screen.
const DIRTY_STATES: &[(&str, &[u8])] = &[
    ("stale content from the previous screen", b"\x1b[H\x1b[7mstale\x1b[27m content that the snapshot must overwrite entirely\r\nsecond stale row"),
    ("alt-screen active", b"\x1b[?1049h"),
    ("scrolling region 5..10", b"\x1b[5;10r"),
    ("origin mode inside a scrolling region", b"\x1b[5;10r\x1b[?6h"),
    ("DEC line-drawing charset shifted in", b"\x1b(0"),
    ("pending SGR", b"\x1b[1;31;45m"),
    ("insert mode", b"\x1b[4h"),
    ("autowrap off", b"\x1b[?7l"),
    ("reverse video", b"\x1b[?5h"),
];

fn row_text(snapshot: &Snapshot, row: u16) -> String {
    let start = usize::from(row) * usize::from(snapshot.cols);
    let end = start + usize::from(snapshot.cols);
    snapshot.cells[start..end]
        .iter()
        .map(|cell| match cell.codepoint {
            0 => ' ',
            other => char::from_u32(other).unwrap_or('\u{fffd}'),
        })
        .collect()
}

fn describe(cell: &Cell) -> String {
    let character = match cell.codepoint {
        0 => ' ',
        other => char::from_u32(other).unwrap_or('\u{fffd}'),
    };
    format!(
        "{character:?} fg={:?} bg={:?} attr={:#06x}",
        cell.foreground, cell.background, cell.attributes
    )
}

/// The first way `dirty` differs from `clean`, in the order a reader cares
/// about: the screen the user sees, then the cursor, then the cell that broke.
fn first_difference(clean: &Snapshot, dirty: &Snapshot) -> Option<String> {
    if clean.alt_screen != dirty.alt_screen {
        return Some(format!(
            "landed on the {} screen instead of the {} one",
            if dirty.alt_screen { "alternate" } else { "primary" },
            if clean.alt_screen { "alternate" } else { "primary" },
        ));
    }
    if (clean.rows, clean.cols) != (dirty.rows, dirty.cols) {
        return Some(format!(
            "dimensions {}x{} instead of {}x{}",
            dirty.rows, dirty.cols, clean.rows, clean.cols
        ));
    }
    for row in 0..clean.rows {
        let expected = row_text(clean, row);
        let actual = row_text(dirty, row);
        if expected != actual {
            return Some(format!(
                "row {row} reads {:?}\n      expected {:?}",
                actual.trim_end(),
                expected.trim_end()
            ));
        }
    }
    for (index, (expected, actual)) in clean.cells.iter().zip(dirty.cells.iter()).enumerate() {
        if expected != actual {
            let row = index / usize::from(clean.cols);
            let column = index % usize::from(clean.cols);
            return Some(format!(
                "cell ({row},{column}) is {}\n      expected {}",
                describe(actual),
                describe(expected)
            ));
        }
    }
    if (clean.cursor_x, clean.cursor_y) != (dirty.cursor_x, dirty.cursor_y) {
        return Some(format!(
            "cursor at ({},{}) instead of ({},{})",
            dirty.cursor_x, dirty.cursor_y, clean.cursor_x, clean.cursor_y
        ));
    }
    None
}

/// The prologue leaves the alternate screen unconditionally, so the payload
/// owes the re-entry when the host is the one sitting in alt. Without this the
/// fix for a client stuck in alt would silently strand every vim session on the
/// primary screen — the same asymmetry in the other direction.
#[test]
fn an_alt_screen_host_still_lands_on_the_alternate_screen() {
    let mut host = VtTerminal::new(ROWS, COLS).expect("host terminal");
    host.vt_write(b"\x1b[?1049hEDITOR\r\nsecond line of the alternate screen");
    let payload = host.format_vt().expect("format_vt");

    for (state, prelude) in [
        ("a clean client", &b""[..]),
        ("a client in alt", b"\x1b[?1049h"),
    ] {
        let applied = applied(&payload, prelude);
        assert!(
            applied.alt_screen,
            "{state} landed on the primary screen for an alt-screen host"
        );
        assert_eq!(
            row_text(&applied, 0).trim_end(),
            "EDITOR",
            "{state} did not receive the alternate screen's content"
        );
    }
}

#[test]
fn snapshot_applies_identically_to_a_dirty_screen() {
    let payload = host_payload();
    let clean = applied(&payload, b"");

    let broken: Vec<String> = DIRTY_STATES
        .iter()
        .filter_map(|(state, prelude)| {
            first_difference(&clean, &applied(&payload, prelude))
                .map(|difference| format!("  {state}: {difference}"))
        })
        .collect();

    assert!(
        broken.is_empty(),
        "the S payload is not self-contained — a client in these states does not \
         reach the snapshot's screen:\n{}",
        broken.join("\n")
    );
}
