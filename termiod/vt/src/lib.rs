//! Safe, engine-neutral snapshot boundary over libghostty-vt.
//!
//! The engine is reached through the `libghostty-vt` crate, which owns the
//! FFI and the Zig build of `libghostty-vt.a`. This module owns termiod's
//! engine-neutral types so the wire protocol never depends on the engine's
//! in-memory cell layout.

use std::fmt;
use std::marker::PhantomData;
use std::rc::Rc;

use libghostty_vt::fmt::{Format, Formatter, FormatterOptions};
use libghostty_vt::render::{CellIterator, Dirty, RenderState, RowIterator};
use libghostty_vt::screen::{CellContentTag, Screen};
use libghostty_vt::style::{RgbColor, StyleColor};
use libghostty_vt::terminal::{Mode, Point, PointCoordinate};
use libghostty_vt::{Error, Terminal, TerminalOptions};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

/// A colour slot exactly as the program expressed it.
///
/// The host preserves *which* slot a cell asked for; the client decides what
/// that slot looks like. Resolving here — looking a palette index up in the
/// host's palette, or substituting the host's default foreground — bakes the
/// host's theme into the wire and overrides the viewer's, which is the
/// presentation boundary the whole design rests on (device architecture §4).
///
/// The three variants are not an encoding choice; they are the three things a
/// terminal program can actually mean:
///
/// - `Default` — it named no colour, so the *client's* default applies.
/// - `Palette` — it named a theme slot (`38;5;N`), so the *client's* palette
///   resolves it. This is what lets one snapshot look right in a light theme
///   and a dark one.
/// - `Rgb` — it named an exact colour (`38;2;r;g;b`). That was the program's
///   decision, not a theme's, and no client may reinterpret it.
///
/// Collapsing all three into RGB (what this type replaced) does not merely
/// produce wrong colours: it destroys the distinction, so a client can no
/// longer tell a themed red from a program's literal `#FF0000`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Color {
    #[default]
    Default,
    Palette(u8),
    Rgb(Rgb),
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cell {
    pub codepoint: u32,
    pub foreground: Color,
    pub background: Color,
    pub attributes: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub rows: u16,
    pub cols: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub alt_screen: bool,
    /// OSC 0/2 title reported by libghostty-vt, if one was set.
    pub title: Option<String>,
    pub cells: Vec<Cell>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirtyRow {
    pub row_index: u16,
    pub cells: Vec<Cell>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Damage {
    pub rows: u16,
    pub cols: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub alt_screen: bool,
    pub dirty_rows: Vec<DirtyRow>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scrollback {
    pub total_rows: usize,
    /// Rows ordered newest-first, starting immediately above the viewport.
    pub rows: Vec<Vec<Cell>>,
}

#[derive(Debug, Clone)]
pub struct VtError(String);

impl fmt::Display for VtError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for VtError {}

type Result<T> = std::result::Result<T, VtError>;

/// Attach the failing operation's name to an engine error. The engine's own
/// error type carries no context, and a bare "invalid value" in a daemon log
/// is not actionable.
fn check<T>(result: std::result::Result<T, Error>, operation: &str) -> Result<T> {
    result.map_err(|error| VtError(format!("{operation} failed: {error}")))
}

/// `check` with a second label, joined **only when the call actually fails**.
/// Per-cell code must not build the context string eagerly: these run once per
/// cell per screen, so a `format!` argument is an allocation per cell.
fn check_at<T>(result: std::result::Result<T, Error>, operation: &str, origin: &str) -> Result<T> {
    result.map_err(|error| VtError(format!("{operation}({origin}) failed: {error}")))
}

/// What a snapshot payload must undo before it paints, so that applying it to a
/// client screen in *any* prior state lands where applying it to a fresh
/// terminal would. The formatter only ever emits state the host *has* — it
/// writes `ESC[?1049h` for an alt-screen session and `ESC(0` for a shifted
/// charset, but never the negation — and it paints the screen relative to
/// wherever the cursor already sits. So every one of these is a state a client
/// could be carrying that the payload would otherwise inherit
/// (`tests/snapshot_prologue.rs` is the acceptance test, one case each).
///
/// `DECSTR` (`ESC[!p`) leads because it covers what is not enumerated here —
/// G2/G3, DECSCA protection, the saved cursor, keypad mode. It is not sufficient
/// on its own: measured against libghostty, SGR, charsets, origin mode, and
/// autowrap all survive it, so each is re-asserted explicitly afterwards.
///
/// The line stops short of `RIS`, which would also clear what the *client*
/// legitimately owns — its palette, title, and scrollback are not the host's to
/// reset. Nothing here is host state the payload does not immediately restate:
/// a host in alt-screen re-enters it, a host with a scrolling region redeclares
/// it, and a host with a shifted charset re-shifts.
const SNAPSHOT_PROLOGUE: &[u8] = concat!(
    "\x1b[?1049l", // leave the alternate screen; the payload re-enters if the host is there
    "\x1b[!p",     // DECSTR — soft reset, for the state not enumerated below
    "\x1b[m",      // no SGR pending, so the erase below paints the default background
    "\x1b(B\x1b)B\x0f", // G0/G1 back to US-ASCII and shifted in
    "\x1b[?6l",    // origin mode off, so the payload's cursor addressing is absolute
    "\x1b[?7h",    // autowrap on — the default the formatter's full-width rows assume
    "\x1b[4l",     // insert mode off, or painted text shoves what follows it right
    "\x1b[?5l",    // reverse video off; it inverts the whole screen and DECSTR misses it
    "\x1b[r",      // full-height scrolling region; the payload redeclares a narrower one
    "\x1b[2J\x1b[H", // clear and home — the formatter paints relative from the cursor
)
.as_bytes();

/// Mouse format is last-writer-wins, but the formatter re-emits mode bits in
/// enum order — SGR (`?1006h`) before urxvt (`?1015h`). crossterm enables
/// urxvt then SGR, so replaying its payload flips a client into urxvt, which
/// crossterm TUIs don't parse (#441). The engine's API can't read the resolved
/// winner back out, so `format_vt` re-asserts SGR whenever both were emitted:
/// `?1015h` only ever appears as the fallback written before `?1006h`.
const SGR_MOUSE_FORMAT: &[u8] = b"\x1b[?1006h";
const URXVT_MOUSE_FORMAT: &[u8] = b"\x1b[?1015h";

fn last_occurrence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .rposition(|window| window == needle)
}

/// A terminal plus reusable render iterators. This type is deliberately
/// `!Send`/`!Sync`; construct and use it on the sidecar thread that owns it.
pub struct VtTerminal {
    terminal: Terminal<'static, 'static>,
    render_state: RenderState<'static>,
    row_iterator: RowIterator<'static>,
    row_cells: CellIterator<'static>,
    _thread_confined: PhantomData<Rc<()>>,
}

impl VtTerminal {
    pub fn new(rows: u16, cols: u16) -> Result<Self> {
        Ok(Self {
            terminal: check(
                Terminal::new(TerminalOptions {
                    cols,
                    rows,
                    max_scrollback: 1_000,
                }),
                "Terminal::new",
            )?,
            render_state: check(RenderState::new(), "RenderState::new")?,
            row_iterator: check(RowIterator::new(), "RowIterator::new")?,
            row_cells: check(CellIterator::new(), "CellIterator::new")?,
            _thread_confined: PhantomData,
        })
    }

    pub fn vt_write(&mut self, bytes: &[u8]) {
        self.terminal.vt_write(bytes);
    }

    /// Resize the authoritative screen **without reflowing** it — tmux/xterm
    /// semantics, not Ghostty.app's.
    ///
    /// Shells' SIGWINCH redisplay assumes the terminal did not rewrap the old
    /// prompt: zsh moves the cursor up by a row count computed from the *old*
    /// width and repaints from there. A reflowing resize rewraps the prompt
    /// and moves the cursor down, so that repaint lands one row low and the
    /// stale prompt copy above it survives — once per split, which is the
    /// ⌘D duplicated-prompt report. Ghostty.app escapes this only because it
    /// injects shell integration and clears OSC 133-marked prompt rows before
    /// reflowing (and its engine's post-1.3.1 clear-after-reflow ordering,
    /// dde3d4d6b, re-breaks the wrapped case even then). Sessions here carry
    /// no integration, so the marks-free behaviour every shell is written
    /// against — truncate, don't rewrap — is the correct one for the host.
    ///
    /// The engine gates reflow on DECAWM (mode ?7), so wraparound is parked
    /// off across the resize and restored to whatever the program had chosen.
    /// Every attachment repaints from the post-resize keyframe, so clients
    /// converge on this screen regardless of what their own surfaces did.
    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        let wraparound = check(self.terminal.mode(Mode::WRAPAROUND), "mode(WRAPAROUND)")?;
        if wraparound {
            check(
                self.terminal.set_mode(Mode::WRAPAROUND, false),
                "set_mode(WRAPAROUND, false)",
            )?;
        }
        let resized = self.resize_reflowing_for_tests(rows, cols);
        if wraparound {
            // Restore even when the resize failed: the mode belongs to the
            // program, and a failed ioctl must not leave autowrap off.
            check(
                self.terminal.set_mode(Mode::WRAPAROUND, true),
                "set_mode(WRAPAROUND, true)",
            )?;
        }
        resized
    }

    /// The bare engine resize, which reflows whenever the screen's own DECAWM
    /// is set. Public only so tests can reproduce the reflow duplicate this
    /// crate's `resize` exists to prevent.
    pub fn resize_reflowing_for_tests(&mut self, rows: u16, cols: u16) -> Result<()> {
        // Pixel dimensions are not used by the daemon snapshot sidecar; fixed
        // cell metrics still give libghostty-vt consistent total dimensions.
        check(self.terminal.resize(cols, rows, 8, 16), "Terminal::resize")
    }

    /// Serialise the current screen back into **VT sequences** — the repaint a
    /// client can feed straight into its own terminal.
    ///
    /// This is the host's only correct way to hand over screen state. Reading
    /// cells and shipping resolved RGB makes the *host* the style authority,
    /// which breaks the whole reason this project runs libghostty on both ends:
    /// the client's terminal must decide colour. Concretely, `palette` stays
    /// off so no OSC 4 is emitted and the viewer's own theme applies; `style`
    /// carries SGR (so bold/underline/italic survive, unlike the packed cell
    /// format) and `hyperlink` carries OSC 8.
    ///
    /// `modes`, `charsets`, and the scrolling region are included so a
    /// reattached client inherits the screen's actual mode state rather than a
    /// plausible-looking default.
    ///
    /// `tabstops` is the exception, and it is off for a correctness reason
    /// rather than a taste one. The formatter writes them as a walk —
    /// `ESC[3g` then `ESC[<col>G ESC H` per stop — which leaves the cursor on
    /// the last stop. ghostty a887df42c emitted that walk *after* the screen
    /// content, so it was harmless; 9d8fbd1 moved it *before*, so every row
    /// paints from column 73 instead of column 1. Re-asserting the cursor at
    /// the end fixes where the cursor lands but cannot un-paint the content.
    /// Custom tab stops are worth less than a correctly painted screen.
    ///
    /// The payload carries its own prologue (`SNAPSHOT_PROLOGUE`), so a client
    /// applies it raw and must not prepend a reset of its own.
    pub fn format_vt(&mut self) -> Result<Vec<u8>> {
        let options = FormatterOptions::new()
            .with_format(Format::Vt)
            .with_unwrap(false)
            .with_trim(false)
            // Deliberately false: emitting OSC 4 would push the host's palette
            // onto the client and override the local theme.
            .with_palette(false)
            .with_modes(true)
            .with_scrolling_region(true)
            // See the note above: the walk that writes these lands the cursor
            // on the last stop, and 9d8fbd1 emits it ahead of the content.
            .with_tabstops(false)
            .with_pwd(true)
            .with_keyboard(true)
            .with_cursor(true)
            .with_style(true)
            .with_hyperlink(true)
            .with_protection(true)
            .with_kitty_keyboard(true)
            .with_charsets(true);

        let mut formatted = SNAPSHOT_PROLOGUE.to_vec();
        {
            let mut formatter = check(
                Formatter::new(&self.terminal, options),
                "Formatter::new(terminal)",
            )?;
            let bytes = check(formatter.format_alloc(None), "Formatter::format_alloc")?;
            formatted.extend_from_slice(&bytes);
        }

        // See SGR_MOUSE_FORMAT. Guarded on the actual order so this becomes
        // a no-op the day the formatter restates the winner itself.
        if let (Some(sgr), Some(urxvt)) = (
            last_occurrence(&formatted, SGR_MOUSE_FORMAT),
            last_occurrence(&formatted, URXVT_MOUSE_FORMAT),
        ) {
            if urxvt > sgr {
                formatted.extend_from_slice(SGR_MOUSE_FORMAT);
            }
        }

        let pending_wrap = check(
            self.terminal.is_cursor_pending_wrap(),
            "Terminal::is_cursor_pending_wrap",
        )?;

        // The formatter paints a scrolled primary screen as one newline-joined
        // flow and stops at the last non-blank row, dropping the blank rows
        // beneath it — and with them the scroll steps the host has already
        // taken. A client replaying the payload then holds a screen sitting a
        // row (or more) behind the host's, so the cursor re-assert below lands
        // *on* the last painted line instead of the blank row under it, and the
        // first live byte after the snapshot overwrites that line in place.
        // This is the reattach seam that ate exactly one line per attach: the
        // line written in the attach second.
        //
        // The engine itself referees: replay the payload into a scratch
        // terminal of the same grid and, while its screen trails the live one,
        // feed it the newlines the flow dropped. The padding is adopted only
        // once the replay converges on the live screen, so a payload the
        // formatter already positions correctly — an alt-screen frame, a
        // CUP-addressed repaint, an unscrolled screen — passes through
        // untouched. Skipped under pending wrap for the same reason the CUP
        // re-assert is: the formatter's own cell-reprint restore must stand.
        if !pending_wrap {
            if let Some(pad) = self.replay_scroll_shortfall(&formatted)? {
                formatted.extend_from_slice(&pad);
            }
        }

        // The formatter emits the cursor's CUP *before* the state extras, and
        // some of those move the cursor as a side effect — `tabstops` walks the
        // row with CHA/HTS and leaves it wherever the last stop was, and
        // DECSTBM homes it. Re-assert the real position last so the client
        // lands where the session actually is.
        //
        // Except when the cursor is holding pending wrap. A cursor at the right
        // margin has not wrapped yet: the next printable character belongs on
        // the following row, and CUP is exactly what clears that. ghostty#13876
        // taught the formatter to restore the flag by reprinting the final cell,
        // and re-asserting a position on top of that throws the restore away —
        // the client then overwrites the last cell instead of wrapping, and its
        // screen diverges from the host's on the very next byte. The formatter's
        // own restore already leaves the cursor in the right place, so this owes
        // nothing further.
        if !pending_wrap {
            let cursor_x = check(self.terminal.cursor_x(), "Terminal::cursor_x")?;
            let cursor_y = check(self.terminal.cursor_y(), "Terminal::cursor_y")?;
            formatted.extend_from_slice(
                format!(
                    "\x1b[{};{}H",
                    cursor_y.saturating_add(1),
                    cursor_x.saturating_add(1)
                )
                .as_bytes(),
            );
        }
        Ok(formatted)
    }

    pub fn snapshot(&mut self) -> Result<Snapshot> {
        let rows = check(self.terminal.rows(), "Terminal::rows")?;
        let cols = check(self.terminal.cols(), "Terminal::cols")?;
        let cursor_x = check(self.terminal.cursor_x(), "Terminal::cursor_x")?;
        let cursor_y = check(self.terminal.cursor_y(), "Terminal::cursor_y")?;
        let alt_screen =
            check(self.terminal.active_screen(), "Terminal::active_screen")? == Screen::Alternate;
        let title = self.title()?;

        let expected = usize::from(rows) * usize::from(cols);
        let mut cells = Vec::with_capacity(expected);

        let snapshot = check(
            self.render_state.update(&self.terminal),
            "RenderState::update",
        )?;
        let mut row_iteration = check(self.row_iterator.update(&snapshot), "RowIterator::update")?;
        while let Some(row) = row_iteration.next() {
            {
                let mut cell_iteration =
                    check(self.row_cells.update(row), "CellIterator::update")?;
                while let Some(cell) = cell_iteration.next() {
                    cells.push(viewport_cell(cell)?);
                }
            }
            check(row.set_dirty(false), "RowIteration::set_dirty")?;
        }
        check(snapshot.set_dirty(Dirty::Clean), "Snapshot::set_dirty")?;

        if cells.len() != expected {
            return Err(VtError(format!(
                "render grid contained {} cells, expected {expected}",
                cells.len()
            )));
        }

        Ok(Snapshot {
            rows,
            cols,
            cursor_x,
            cursor_y,
            alt_screen,
            title,
            cells,
        })
    }

    /// Drain the render state's dirty viewport rows and reset both layers of
    /// libghostty-vt damage tracking. A full-damage update returns every row.
    pub fn take_damage(&mut self) -> Result<Damage> {
        let rows = check(self.terminal.rows(), "Terminal::rows")?;
        let cols = check(self.terminal.cols(), "Terminal::cols")?;
        let cursor_x = check(self.terminal.cursor_x(), "Terminal::cursor_x")?;
        let cursor_y = check(self.terminal.cursor_y(), "Terminal::cursor_y")?;
        let alt_screen =
            check(self.terminal.active_screen(), "Terminal::active_screen")? == Screen::Alternate;

        let mut dirty_rows = Vec::new();
        let mut row_index = 0u16;

        let snapshot = check(
            self.render_state.update(&self.terminal),
            "RenderState::update",
        )?;
        let full = check(snapshot.dirty(), "Snapshot::dirty")? == Dirty::Full;
        let mut row_iteration = check(self.row_iterator.update(&snapshot), "RowIterator::update")?;
        while let Some(row) = row_iteration.next() {
            if full || check(row.dirty(), "RowIteration::dirty")? {
                let mut cells = Vec::with_capacity(usize::from(cols));
                {
                    let mut cell_iteration =
                        check(self.row_cells.update(row), "CellIterator::update")?;
                    while let Some(cell) = cell_iteration.next() {
                        cells.push(viewport_cell(cell)?);
                    }
                }
                if cells.len() != usize::from(cols) {
                    return Err(VtError(format!(
                        "dirty row {row_index} contained {} cells, expected {cols}",
                        cells.len()
                    )));
                }
                dirty_rows.push(DirtyRow { row_index, cells });
            }
            check(row.set_dirty(false), "RowIteration::set_dirty")?;
            row_index = row_index.saturating_add(1);
        }
        check(snapshot.set_dirty(Dirty::Clean), "Snapshot::set_dirty")?;

        Ok(Damage {
            rows,
            cols,
            cursor_x,
            cursor_y,
            alt_screen,
            dirty_rows,
        })
    }

    /// Copy at most `max_rows` rows of primary-screen history, newest-first.
    /// Callers must invoke this in the same serialized boundary as `snapshot`
    /// if the two results need to describe one terminal state.
    pub fn scrollback(&self, max_rows: usize) -> Result<Scrollback> {
        let total_rows = check(self.terminal.scrollback_rows(), "Terminal::scrollback_rows")?;
        let capture_rows = total_rows.min(max_rows);
        if capture_rows == 0 {
            return Ok(Scrollback {
                total_rows,
                rows: Vec::new(),
            });
        }

        let cols = check(self.terminal.cols(), "Terminal::cols")?;
        let first_row = total_rows - capture_rows;
        let mut rows = Vec::with_capacity(capture_rows);

        for y in (first_row..total_rows).rev() {
            let y = u32::try_from(y)
                .map_err(|_| VtError("scrollback row exceeds u32 coordinate space".to_string()))?;
            let mut row = Vec::with_capacity(usize::from(cols));
            for x in 0..cols {
                row.push(self.history_cell(x, y)?);
            }
            rows.push(row);
        }

        Ok(Scrollback { total_rows, rows })
    }

    fn title(&self) -> Result<Option<String>> {
        // The engine reports an unset title as an empty borrowed string, and
        // reports a non-UTF-8 one as an error; neither is a daemon failure.
        Ok(match self.terminal.title() {
            Ok(title) if !title.is_empty() => Some(title.to_string()),
            _ => None,
        })
    }

    /// How many scroll steps a client replaying `formatted` would end up
    /// behind this terminal's screen, answered as the `\r\n` padding that
    /// closes the gap — or `None` when the replay already matches (nothing to
    /// fix) or never converges within the search bound (nothing this padding
    /// could fix; the payload ships as-is, which is the pre-existing
    /// behaviour).
    ///
    /// The bound is not a tuning knob: each padding newline scrolls one more
    /// blank row onto the scratch screen's bottom, so a padded replay can only
    /// equal the live screen if the live screen ends in at least that many
    /// blank rows. Probing past the live screen's trailing blank run can
    /// therefore never converge, and probing up to it costs exactly as much as
    /// the shortfall that actually exists.
    fn replay_scroll_shortfall(&self, formatted: &[u8]) -> Result<Option<Vec<u8>>> {
        let rows = check(self.terminal.rows(), "Terminal::rows")?;
        let cols = check(self.terminal.cols(), "Terminal::cols")?;
        let live = self.active_codepoints()?;
        let mut scratch = Self::new(rows, cols)?;
        scratch.vt_write(formatted);
        let blank = |cell: &u32| *cell == 0 || *cell == u32::from(b' ');
        let bound = live
            .chunks(usize::from(cols).max(1))
            .rev()
            .take_while(|row| row.iter().all(blank))
            .count();
        for shortfall in 0..=bound {
            if scratch.active_codepoints()? == live {
                if shortfall == 0 {
                    return Ok(None);
                }
                return Ok(Some(b"\r\n".repeat(shortfall)));
            }
            scratch.vt_write(b"\r\n");
        }
        Ok(None)
    }

    /// The active screen's text, one codepoint per cell in row-major order,
    /// read through `grid_ref` like `history_cell` — so nothing here touches
    /// the render state's damage tracking, which `take_damage` owns.
    /// The live screen as text, one row per line with trailing blanks trimmed.
    ///
    /// Reads the **active** area, not a viewport a client has scrolled: the
    /// host has no scroll position, which is the defect this replaces. The Mac
    /// classified agent status against `readViewportText()`, so scrolling a
    /// pane up fed stale rows to the rules; there is nothing here to scroll.
    ///
    /// Deliberately not built on `snapshot()`: that clears both layers of
    /// damage tracking, and a once-a-second status read must not eat a
    /// `grid_diff` client's frame.
    pub fn screen_text(&self) -> Result<String> {
        let cols = usize::from(check(self.terminal.cols(), "Terminal::cols")?);
        let codepoints = self.active_codepoints()?;
        let mut text = String::with_capacity(codepoints.len());
        for (index, row) in codepoints.chunks(cols.max(1)).enumerate() {
            if index > 0 {
                text.push('\n');
            }
            let end = row
                .iter()
                .rposition(|point| *point != 0 && *point != u32::from(b' '))
                .map_or(0, |last| last + 1);
            for point in &row[..end] {
                // A zero codepoint is an unwritten cell, and a wide character's
                // spacer tail is reported as one too — both are "no glyph here".
                let glyph = if *point == 0 {
                    ' '
                } else {
                    char::from_u32(*point).unwrap_or(' ')
                };
                text.push(glyph);
            }
        }
        Ok(text)
    }

    fn active_codepoints(&self) -> Result<Vec<u32>> {
        let rows = check(self.terminal.rows(), "Terminal::rows")?;
        let cols = check(self.terminal.cols(), "Terminal::cols")?;
        let mut codepoints = Vec::with_capacity(usize::from(rows) * usize::from(cols));
        for y in 0..rows {
            for x in 0..cols {
                let reference = check(
                    self.terminal.grid_ref(Point::Active(PointCoordinate {
                        x,
                        y: u32::from(y),
                    })),
                    "Terminal::grid_ref(active)",
                )?;
                let raw_cell = check(reference.cell(), "GridRef::cell(active)")?;
                codepoints.push(check_at(raw_cell.codepoint(), "Cell::codepoint", "active")?);
            }
        }
        Ok(codepoints)
    }

    fn history_cell(&self, x: u16, y: u32) -> Result<Cell> {
        let reference = check(
            self.terminal.grid_ref(Point::History(PointCoordinate { x, y })),
            "Terminal::grid_ref(history)",
        )?;
        let raw_cell = check(reference.cell(), "GridRef::cell(history)")?;
        let style = if check_at(raw_cell.has_styling(), "Cell::has_styling", "history")? {
            Some(check(reference.style(), "GridRef::style(history)")?)
        } else {
            None
        };
        cell_from_parts(raw_cell, style, "history")
    }
}

/// Build one wire cell from the engine's raw cell plus its style, without
/// resolving colour. Both the viewport and the scrollback go through here so
/// the two cannot disagree — before this existed, history applied `inverse` and
/// `invisible` itself while the viewport leaned on the render state's flattened
/// accessors, so one screen could be packed two ways.
///
/// `style` is `None` for a cell that carries none, which is most of them.
fn cell_from_parts(
    raw_cell: libghostty_vt::screen::Cell,
    style: Option<libghostty_vt::style::Style>,
    origin: &str,
) -> Result<Cell> {
    let mut codepoint = check_at(raw_cell.codepoint(), "Cell::codepoint", origin)?;
    // An unstyled cell names no colour, so both slots are the client's default
    // and there is no inverse or invisible to apply.
    let (mut foreground, mut background, inverse, invisible) = match style {
        Some(style) => (
            style_color(style.fg_color),
            style_color(style.bg_color),
            style.inverse,
            style.invisible,
        ),
        None => (Color::Default, Color::Default, false, false),
    };

    // A bg-color-only cell carries its colour in the cell, not the style, so
    // this dispatch is needed whether or not the cell is styled.
    match check_at(raw_cell.content_tag(), "Cell::content_tag", origin)? {
        CellContentTag::BgColorPalette => {
            let index = check_at(raw_cell.bg_color_palette(), "Cell::bg_color_palette", origin)?;
            background = Color::Palette(index.0);
        }
        CellContentTag::BgColorRgb => {
            background = Color::Rgb(rgb(check_at(
                raw_cell.bg_color_rgb(),
                "Cell::bg_color_rgb",
                origin,
            )?));
        }
        _ => {}
    }
    if inverse {
        std::mem::swap(&mut foreground, &mut background);
    }
    if invisible {
        codepoint = 0;
    }

    Ok(Cell {
        codepoint,
        foreground,
        background,
        // Bold, underline, italic and the rest still ride the `S` VT payload
        // rather than these bits. The wire cell keeps reserved room for them so
        // filling it in stays additive.
        attributes: 0,
    })
}

/// Convert one cell of the live viewport. Reads the *unresolved* style rather
/// than the render state's `fg_color`/`bg_color`, which flatten palette indices
/// through the host's palette and substitute the host's defaults — the exact
/// resolution this boundary must not perform.
fn viewport_cell(cell: &libghostty_vt::render::CellIteration<'_, '_>) -> Result<Cell> {
    let raw_cell = check(cell.raw_cell(), "CellIteration::raw_cell")?;
    // Materialising a `Style` copies three tagged colours plus nine flags across
    // FFI and converts all of them, per cell. Most cells on a screen carry no
    // style at all, and the engine exposes this predicate for exactly this
    // reason: "avoids materializing the raw cell for renderers that only need
    // to know whether fetching the full style is necessary."
    let style = if check(cell.has_styling(), "CellIteration::has_styling")? {
        Some(check(cell.style(), "CellIteration::style")?)
    } else {
        None
    };
    cell_from_parts(raw_cell, style, "viewport")
}

fn rgb(value: RgbColor) -> Rgb {
    Rgb {
        r: value.r,
        g: value.g,
        b: value.b,
    }
}

fn style_color(color: StyleColor) -> Color {
    match color {
        StyleColor::None => Color::Default,
        StyleColor::Palette(index) => Color::Palette(index.0),
        StyleColor::Rgb(value) => Color::Rgb(rgb(value)),
    }
}

#[cfg(test)]
mod tests {
    use super::{Color, Rgb, VtTerminal};

    fn screen(input: &str) -> Vec<super::Cell> {
        let mut terminal = VtTerminal::new(1, 8).expect("terminal");
        terminal.vt_write(input.as_bytes());
        terminal.snapshot().expect("snapshot").cells
    }

    /// The boundary this type exists to hold: the host reports *which* colour
    /// slot a cell asked for and never resolves it. Before the tagged colour,
    /// all three of these packed as RGB — so a client could not tell an unstyled
    /// cell from one explicitly painted with the host's palette, and applied the
    /// host's theme either way.
    #[test]
    fn colors_are_reported_as_slots_not_resolved() {
        // Unstyled: the client's own default foreground must apply.
        assert_eq!(screen("a")[0].foreground, Color::Default);

        // `31` is a theme slot, so the viewer's palette decides what red is.
        assert_eq!(screen("\x1b[31ma")[0].foreground, Color::Palette(1));
        assert_eq!(screen("\x1b[38;5;200ma")[0].foreground, Color::Palette(200));

        // Truecolor is the program's own decision and stays exact.
        assert_eq!(
            screen("\x1b[38;2;9;8;7ma")[0].foreground,
            Color::Rgb(Rgb { r: 9, g: 8, b: 7 })
        );

        // Background travels the same three roads.
        assert_eq!(screen("a")[0].background, Color::Default);
        assert_eq!(screen("\x1b[41ma")[0].background, Color::Palette(1));
        assert_eq!(
            screen("\x1b[48;2;1;2;3ma")[0].background,
            Color::Rgb(Rgb { r: 1, g: 2, b: 3 })
        );
    }

    /// Palette index 0 and "no colour named" are different instructions. The
    /// resolved-RGB format collapsed both to black, which is what let a dark
    /// theme's background silently become the client's foreground.
    #[test]
    fn default_is_distinct_from_palette_zero() {
        assert_ne!(screen("a")[0].foreground, screen("\x1b[30ma")[0].foreground);
    }

    /// `inverse` is applied here, on slots, so it survives without either side
    /// resolving a colour — and the viewport takes the same path as scrollback.
    #[test]
    fn inverse_swaps_slots() {
        let cell = &screen("\x1b[31;7ma")[0];
        assert_eq!(cell.background, Color::Palette(1));
        assert_eq!(cell.foreground, Color::Default);
    }
}
