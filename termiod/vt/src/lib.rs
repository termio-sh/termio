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
use libghostty_vt::style::{Palette, RgbColor, StyleColor};
use libghostty_vt::terminal::{Point, PointCoordinate};
use libghostty_vt::{Error, Terminal, TerminalOptions};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cell {
    pub codepoint: u32,
    pub foreground: Rgb,
    pub background: Rgb,
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

const DEFAULT_FOREGROUND: Rgb = Rgb {
    r: 255,
    g: 255,
    b: 255,
};
const DEFAULT_BACKGROUND: Rgb = Rgb { r: 0, g: 0, b: 0 };

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

    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
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

        // The formatter emits the cursor's CUP *before* the state extras, and
        // some of those move the cursor as a side effect — `tabstops` walks the
        // row with CHA/HTS and leaves it wherever the last stop was, and
        // DECSTBM homes it. Re-assert the real position last so the client
        // lands where the session actually is.
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
        let foreground = self.default_foreground()?;
        let background = self.default_background()?;

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
                    cells.push(viewport_cell(cell, foreground, background)?);
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
        let foreground = self.default_foreground()?;
        let background = self.default_background()?;

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
                        cells.push(viewport_cell(cell, foreground, background)?);
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
        let default_fg = self.default_foreground()?;
        let default_bg = self.default_background()?;
        let palette = check(self.terminal.color_palette(), "Terminal::color_palette")?;
        let first_row = total_rows - capture_rows;
        let mut rows = Vec::with_capacity(capture_rows);

        for y in (first_row..total_rows).rev() {
            let y = u32::try_from(y)
                .map_err(|_| VtError("scrollback row exceeds u32 coordinate space".to_string()))?;
            let mut row = Vec::with_capacity(usize::from(cols));
            for x in 0..cols {
                row.push(self.history_cell(x, y, default_fg, default_bg, &palette)?);
            }
            rows.push(row);
        }

        Ok(Scrollback { total_rows, rows })
    }

    fn default_foreground(&self) -> Result<Rgb> {
        Ok(check(self.terminal.fg_color(), "Terminal::fg_color")?
            .map(rgb)
            .unwrap_or(DEFAULT_FOREGROUND))
    }

    fn default_background(&self) -> Result<Rgb> {
        Ok(check(self.terminal.bg_color(), "Terminal::bg_color")?
            .map(rgb)
            .unwrap_or(DEFAULT_BACKGROUND))
    }

    fn title(&self) -> Result<Option<String>> {
        // The engine reports an unset title as an empty borrowed string, and
        // reports a non-UTF-8 one as an error; neither is a daemon failure.
        Ok(match self.terminal.title() {
            Ok(title) if !title.is_empty() => Some(title.to_string()),
            _ => None,
        })
    }

    fn history_cell(
        &self,
        x: u16,
        y: u32,
        default_fg: Rgb,
        default_bg: Rgb,
        palette: &Palette,
    ) -> Result<Cell> {
        let reference = check(
            self.terminal.grid_ref(Point::History(PointCoordinate { x, y })),
            "Terminal::grid_ref(history)",
        )?;
        let raw_cell = check(reference.cell(), "GridRef::cell(history)")?;
        let style = check(reference.style(), "GridRef::style(history)")?;

        let mut codepoint = check(raw_cell.codepoint(), "Cell::codepoint(history)")?;
        let mut foreground = style_color(style.fg_color, default_fg, palette);
        let mut background = style_color(style.bg_color, default_bg, palette);

        // A bg-color-only cell carries its colour in the cell, not the style.
        match check(raw_cell.content_tag(), "Cell::content_tag(history)")? {
            CellContentTag::BgColorPalette => {
                let index = check(
                    raw_cell.bg_color_palette(),
                    "Cell::bg_color_palette(history)",
                )?;
                background = rgb(palette.get(index));
            }
            CellContentTag::BgColorRgb => {
                background = rgb(check(
                    raw_cell.bg_color_rgb(),
                    "Cell::bg_color_rgb(history)",
                )?);
            }
            _ => {}
        }
        if style.inverse {
            std::mem::swap(&mut foreground, &mut background);
        }
        if style.invisible {
            codepoint = 0;
        }

        Ok(Cell {
            codepoint,
            foreground,
            background,
            // Attribute mapping is shared with viewport snapshots and remains
            // reserved for a later additive wire-format extension.
            attributes: 0,
        })
    }
}

/// Convert one cell of the live viewport. The engine has already flattened
/// palette, RGB, and style sources into resolved colours here, so unlike
/// `history_cell` this needs no content-tag dispatch.
fn viewport_cell(
    cell: &libghostty_vt::render::CellIteration<'_, '_>,
    default_fg: Rgb,
    default_bg: Rgb,
) -> Result<Cell> {
    let raw_cell = check(cell.raw_cell(), "CellIteration::raw_cell")?;
    Ok(Cell {
        codepoint: check(raw_cell.codepoint(), "Cell::codepoint")?,
        foreground: check(cell.fg_color(), "CellIteration::fg_color")?
            .map(rgb)
            .unwrap_or(default_fg),
        background: check(cell.bg_color(), "CellIteration::bg_color")?
            .map(rgb)
            .unwrap_or(default_bg),
        // Phase 1a needs text and colors. Attribute mapping remains owned
        // by this boundary and can fill these protocol bits additively.
        attributes: 0,
    })
}

fn rgb(value: RgbColor) -> Rgb {
    Rgb {
        r: value.r,
        g: value.g,
        b: value.b,
    }
}

fn style_color(color: StyleColor, fallback: Rgb, palette: &Palette) -> Rgb {
    match color {
        StyleColor::None => fallback,
        StyleColor::Palette(index) => rgb(palette.get(index)),
        StyleColor::Rgb(value) => rgb(value),
    }
}
