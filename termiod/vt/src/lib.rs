//! Safe, engine-neutral snapshot boundary over libghostty-vt.
//!
//! The engine is reached through the `libghostty-vt` crate, which owns the
//! FFI and the Zig build of `libghostty-vt.a`. This module owns termiod's
//! engine-neutral types so the wire protocol never depends on the engine's
//! in-memory cell layout.

mod input;
mod kitty_png;

pub use kitty_png::DECODED_LIMIT as PNG_DECODED_LIMIT;
pub use input::{
    is_modifier_key, key_named, InputEncoder, InputModes, KeyAction, KeyInput, MouseAction, MouseInput, Pointer,
    WheelInput,
};

use std::cell::{Cell as Slot, RefCell};
use std::fmt;
use std::marker::PhantomData;
use std::rc::Rc;

use libghostty_vt::color::{Palette, Rgb as RgbColor};
use libghostty_vt::effect::{
    ConformanceLevel, DeviceAttributeFeature, DeviceAttributes, DeviceType, PrimaryDeviceAttributes,
    ProgramStatusState, SecondaryDeviceAttributes, SemanticPromptKind, TertiaryDeviceAttributes,
};
use libghostty_vt::fmt::{Extras, Format, Formatter};
use libghostty_vt::mode::Mode;
use libghostty_vt::point::{Coordinate as PointCoordinate, Point};
use libghostty_vt::render::{CellIterator, Dirty, RenderState, RowIterator};
use libghostty_vt::report::{ColorScheme, SizeReportSize};
use libghostty_vt::screen::{CellContentTag, RowSemanticPrompt, Screen};
use libghostty_vt::snapshot::Decoder as SnapshotDecoder;
use libghostty_vt::style::StyleColor;
use libghostty_vt::{Error, Terminal};

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

/// What a program says it is doing, in an `OSC 7501` report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgramState {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
    /// Not a state: removes the addressed record and every record beneath it.
    Clear,
}

/// Something the engine reported while it parsed, in byte order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VtEvent {
    /// An `OSC 7501` report the engine accepted. `id` is empty for the root
    /// record. A full reset arrives as a `Clear` with an empty id.
    ProgramStatus { state: ProgramState, id: String },
    /// `OSC 133;A` — a new shell prompt.
    PromptStart,
}

/// What termiod answers a program's terminal queries with on its writer's
/// behalf (`vt_answers`): the writer's terminal name for XTVERSION, its theme
/// for the color queries, and whether that theme is dark. Colors are RGB.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Answers {
    pub xtversion: String,
    pub foreground: Option<[u8; 3]>,
    pub background: Option<[u8; 3]>,
    pub cursor: Option<[u8; 3]>,
    /// Exactly 256 entries, or none for the engine's default palette.
    pub palette: Option<Vec<[u8; 3]>>,
    pub dark: Option<bool>,
}

/// The cell size every termiod VT and every `vt_stream` client uses, which
/// size reports and Kitty image layout are in.
pub const CELL_WIDTH: u32 = 8;
pub const CELL_HEIGHT: u32 = 16;

/// The state the query callbacks read and the replies they write, shared
/// with the closures the engine holds.
struct Answering {
    on: Slot<bool>,
    /// Whether nobody writes. While somebody does, their pane answers what
    /// only it can answer right: size reports (XTWINOPS and the in-band mode
    /// 2048 one, with its own cell pixels) and kitty clipboard reads (OSC
    /// 5522, which this VT can only refuse).
    alone: Slot<bool>,
    replies: RefCell<Vec<u8>>,
    xtversion: Slot<&'static str>,
    dark: Slot<Option<bool>>,
}

impl Default for Answering {
    fn default() -> Self {
        Self {
            on: Slot::new(false),
            alone: Slot::new(true),
            replies: RefCell::default(),
            xtversion: Slot::new(""),
            dark: Slot::new(None),
        }
    }
}

/// One leaked copy per distinct name: the XTVERSION callback must hand back
/// a string that outlives it, and a host meets only a few app versions.
/// Names past `NAME_LIMIT` bytes are cut (Ghostty's own answer buffer holds
/// 288), and past `NAMES_LIMIT` distinct ones a new name is not kept.
fn interned(name: &str) -> &'static str {
    use std::sync::{Mutex, OnceLock};
    const NAME_LIMIT: usize = 256;
    const NAMES_LIMIT: usize = 64;
    static NAMES: OnceLock<Mutex<Vec<&'static str>>> = OnceLock::new();
    let mut end = name.len().min(NAME_LIMIT);
    while !name.is_char_boundary(end) {
        end -= 1;
    }
    let name = &name[..end];
    let mut names = NAMES.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap_or_else(|poison| poison.into_inner());
    if let Some(known) = names.iter().find(|known| **known == name) {
        return known;
    }
    if names.len() >= NAMES_LIMIT {
        return "";
    }
    let leaked: &'static str = Box::leak(name.to_owned().into_boxed_str());
    names.push(leaked);
    leaked
}

/// A terminal plus reusable render iterators. This type is deliberately
/// `!Send`/`!Sync`; construct and use it on the sidecar thread that owns it.
pub struct VtTerminal {
    terminal: Terminal<'static, 'static>,
    render_state: RenderState<'static>,
    row_iterator: RowIterator<'static>,
    row_cells: CellIterator<'static>,
    events: Rc<RefCell<Vec<VtEvent>>>,
    answering: Rc<Answering>,
    _thread_confined: PhantomData<Rc<()>>,
}

/// Registers the engine callbacks whose events `take_events` hands out.
///
/// Program status reports and prompt starts come from the same `vt_write`, so
/// they stay in byte order: a report printed after a prompt is not dropped by
/// that prompt's cleanup.
///
/// Queries are answered only while `set_answering` is on; until then the
/// writer's surface answers them, as before `vt_answers`. termiod answers
/// `OSC 7501 ; ?` on its read path (`SupportQuery`) either way.
fn listen(
    terminal: &mut Terminal<'static, 'static>,
    events: &Rc<RefCell<Vec<VtEvent>>>,
    answering: &Rc<Answering>,
) -> Result<()> {
    answer_queries(terminal, answering)?;
    let reports = events.clone();
    check(
        terminal.on_program_status(move |_terminal, report| {
            let state = match report.state() {
                Ok(ProgramStatusState::Idle) => ProgramState::Idle,
                Ok(ProgramStatusState::Working) => ProgramState::Working,
                Ok(ProgramStatusState::Done) => ProgramState::Done,
                Ok(ProgramStatusState::Blocked) => ProgramState::Blocked,
                Ok(ProgramStatusState::Error) => ProgramState::Error,
                Ok(ProgramStatusState::Clear) => ProgramState::Clear,
                // A state a newer engine added. The spec lets a terminal
                // ignore what it does not understand.
                Ok(_) | Err(_) => return,
            };
            reports.borrow_mut().push(VtEvent::ProgramStatus {
                state,
                id: String::from_utf8_lossy(report.id()).into_owned(),
            });
        }),
        "Terminal::on_program_status",
    )?;
    let prompts = events.clone();
    check(
        terminal.on_semantic_prompt(move |_terminal, event| {
            if matches!(event.kind(), Ok(SemanticPromptKind::PromptStart)) {
                prompts.borrow_mut().push(VtEvent::PromptStart);
            }
        }),
        "Terminal::on_semantic_prompt",
    )?;
    Ok(())
}

/// The answers Ghostty's embedded surface gives (`termio/stream_handler.zig`):
/// DA1 with clipboard access, which termio leaves at Ghostty's default, and
/// Ghostty's DA2; XTVERSION as the writer's terminal names itself; size
/// reports in `CELL_WIDTH` by `CELL_HEIGHT` cells; the writer's color scheme.
/// One difference stays: the engine answers DA3, which Ghostty does not, and
/// the callback is not told which level was asked. What the engine writes
/// back goes to `replies`, and only while on.
fn answer_queries(terminal: &mut Terminal<'static, 'static>, answering: &Rc<Answering>) -> Result<()> {
    const PRIMARY: PrimaryDeviceAttributes = PrimaryDeviceAttributes::new(
        ConformanceLevel(62),
        &[DeviceAttributeFeature(22), DeviceAttributeFeature(52)],
    );
    let writes = answering.clone();
    check(
        terminal.on_pty_write(move |_terminal, data| {
            // The cursor's blink (DECRQM 12) and style (DECRQSS ` q`) are the
            // pane's too: this VT holds only the engine's default cursor.
            let pane_answers = data.starts_with(b"\x1b[48;")
                || data.starts_with(b"\x1b]5522;")
                || data.starts_with(b"\x1b[?12;")
                || (data.starts_with(b"\x1bP") && data.ends_with(b" q\x1b\\"));
            if writes.on.get() && (writes.alone.get() || !pane_answers) {
                writes.replies.borrow_mut().extend_from_slice(data);
            }
        }),
        "Terminal::on_pty_write",
    )?;
    check(
        terminal.on_device_attributes(|_terminal| {
            Some(DeviceAttributes {
                primary: PRIMARY,
                secondary: SecondaryDeviceAttributes {
                    device_type: DeviceType(1),
                    firmware_version: 10,
                    rom_cartridge: 0,
                },
                tertiary: TertiaryDeviceAttributes { unit_id: 0 },
            })
        }),
        "Terminal::on_device_attributes",
    )?;
    let names = answering.clone();
    check(
        terminal.on_xtversion(move |_terminal| {
            let name = names.xtversion.get();
            (!name.is_empty()).then_some(name)
        }),
        "Terminal::on_xtversion",
    )?;
    let sizes = answering.clone();
    check(
        terminal.on_size(move |terminal| {
            if !sizes.alone.get() {
                return None;
            }
            Some(SizeReportSize {
                rows: terminal.rows().ok()?,
                columns: terminal.cols().ok()?,
                cell_width: CELL_WIDTH,
                cell_height: CELL_HEIGHT,
            })
        }),
        "Terminal::on_size",
    )?;
    let schemes = answering.clone();
    check(
        terminal.on_color_scheme(move |_terminal| {
            schemes.dark.get().map(|dark| if dark { ColorScheme::Dark } else { ColorScheme::Light })
        }),
        "Terminal::on_color_scheme",
    )?;
    Ok(())
}

/// The longest unfinished escape sequence or UTF-8 codepoint the VT carries
/// across writes, so a native snapshot can be taken at any byte boundary
/// (`native_snapshot`). A Kitty graphics APC can run past it; a snapshot taken
/// inside one then fails and the attach falls back to the VT-bytes keyframe.
pub const CONTINUATION_LIMIT: usize = 1 << 20;

impl VtTerminal {
    pub fn new(rows: u16, cols: u16) -> Result<Self> {
        kitty_png::install();
        let mut terminal = check(Terminal::new(cols, rows), "Terminal::new")?;
        check(
            terminal.set_scrollback_max_lines(Some(1_000)),
            "Terminal::set_scrollback_max_lines",
        )?;
        // Before any input: tracking only covers bytes written after it is on.
        check(
            terminal.set_continuation_max_bytes(CONTINUATION_LIMIT),
            "Terminal::set_continuation_max_bytes",
        )?;
        // Grapheme clustering (mode 2027), as Ghostty's default
        // `grapheme-width-method = unicode` sets it: a skin-tone or ZWJ emoji is
        // one grapheme in one cell, not a cell per codepoint. Clients decode it
        // from the snapshot, so every VT of a session clusters alike. A full
        // reset turns it off again, as libghostty-vt has no mode defaults.
        check(
            terminal.set_mode(Mode::GRAPHEME_CLUSTER, true),
            "set_mode(GRAPHEME_CLUSTER, true)",
        )?;
        Self::wrap(terminal)
    }

    /// A terminal decoded from `native_snapshot`, as a client attaching on the
    /// `vt_stream` plane builds its own.
    pub fn from_native_snapshot(snapshot: &[u8]) -> Result<Self> {
        kitty_png::install();
        let mut decoder = check(SnapshotDecoder::new_buf(snapshot), "snapshot::Decoder::new_buf")?;
        check(
            decoder.set_max_continuation_bytes(CONTINUATION_LIMIT),
            "snapshot::Decoder::set_max_continuation_bytes",
        )?;
        check(
            decoder.set_retain_continuation(true),
            "snapshot::Decoder::set_retain_continuation",
        )?;
        let terminal = check(decoder.decode(), "snapshot::Decoder::decode")?;
        Self::wrap(terminal)
    }

    fn wrap(mut terminal: Terminal<'static, 'static>) -> Result<Self> {
        let events = Rc::new(RefCell::new(Vec::new()));
        let answering = Rc::new(Answering::default());
        listen(&mut terminal, &events, &answering)?;
        Ok(Self {
            terminal,
            render_state: check(RenderState::new(), "RenderState::new")?,
            row_iterator: check(RowIterator::new(), "RowIterator::new")?,
            row_cells: check(CellIterator::new(), "CellIterator::new")?,
            events,
            answering,
            _thread_confined: PhantomData,
        })
    }

    /// Whether this VT answers the program's queries. Off for bytes that are
    /// not live output (a replay), and while the writer answers for itself.
    pub fn set_answering(&mut self, on: bool) {
        self.answering.on.set(on);
        if !on {
            self.answering.replies.borrow_mut().clear();
        }
    }

    /// Whether nobody writes, which decides who answers size reports and
    /// kitty clipboard reads (`Answering::alone`).
    pub fn set_alone(&mut self, alone: bool) {
        self.answering.alone.set(alone);
    }

    /// The writer's identity and theme, which the answers carry.
    pub fn set_answers(&mut self, answers: &Answers) -> Result<()> {
        let rgb = |color: [u8; 3]| RgbColor { r: color[0], g: color[1], b: color[2] };
        self.answering.xtversion.set(interned(&answers.xtversion));
        let scheme_changed = self.answering.dark.replace(answers.dark) != answers.dark;
        // A program that turned on color scheme reports (mode 2031) is told
        // when the writer's appearance changes, as Ghostty tells it.
        if scheme_changed && self.answering.on.get() {
            if let (Some(dark), Ok(true)) = (answers.dark, self.terminal.mode(Mode::COLOR_SCHEME_REPORT)) {
                let report: &[u8] = if dark { b"\x1b[?997;1n" } else { b"\x1b[?997;2n" };
                self.answering.replies.borrow_mut().extend_from_slice(report);
            }
        }
        check(self.terminal.set_default_fg_color(answers.foreground.map(rgb)), "Terminal::set_default_fg_color")?;
        check(self.terminal.set_default_bg_color(answers.background.map(rgb)), "Terminal::set_default_bg_color")?;
        check(self.terminal.set_default_cursor_color(answers.cursor.map(rgb)), "Terminal::set_default_cursor_color")?;
        let palette = match &answers.palette {
            Some(colors) if colors.len() == 256 => {
                let mut palette = [RgbColor { r: 0, g: 0, b: 0 }; 256];
                for (slot, color) in palette.iter_mut().zip(colors) {
                    *slot = rgb(*color);
                }
                Some(Palette(palette))
            }
            _ => None,
        };
        check(self.terminal.set_default_color_palette(palette), "Terminal::set_default_color_palette")?;
        Ok(())
    }

    /// What the program's queries were answered with since the last call, in
    /// byte order, for termiod to write to the PTY.
    pub fn take_replies(&mut self) -> Vec<u8> {
        std::mem::take(&mut *self.answering.replies.borrow_mut())
    }

    /// The whole terminal in libghostty's own snapshot format: both screens,
    /// scrollback, modes, Kitty keyboard flags, and any unfinished input. A
    /// `vt_stream` client decodes it into a fresh terminal, so nothing the
    /// client's previous terminal held can survive an attach.
    pub fn native_snapshot(&self) -> Result<Vec<u8>> {
        let bytes = check(self.terminal.encode_snapshot_alloc(None), "Terminal::encode_snapshot_alloc")?;
        // A complete snapshot always carries its envelope, so no bytes is a
        // failure to report, never an empty screen to send.
        bytes
            .map(|bytes| bytes.to_vec())
            .ok_or_else(|| VtError("Terminal::encode_snapshot_alloc: no bytes".to_string()))
    }

    pub fn vt_write(&mut self, bytes: &[u8]) {
        self.terminal.vt_write(bytes);
    }

    /// Everything the engine reported since the last call, in byte order.
    pub fn take_events(&mut self) -> Vec<VtEvent> {
        std::mem::take(&mut *self.events.borrow_mut())
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
    /// dde3d4d6b, re-breaks the wrapped case even then). This is the
    /// marks-free behaviour every shell is written against — truncate, don't
    /// rewrap — and it stays the fallback whenever `resize_for_shell` finds no
    /// marks under the cursor.
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
        let resized = self.resize_reflowing(rows, cols);
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

    /// Resize **with** reflow — Ghostty.app's semantics — for when the shell is
    /// not the thing on screen.
    ///
    /// `resize` above is right whenever the shell will redisplay: its redraw
    /// assumes the old wrap points, and rewrapping under it duplicates the
    /// prompt. That assumption belongs to the shell, and the shell only makes
    /// it while it holds the terminal. When a job does — an agent TUI, an
    /// editor, anything the session spawned — nobody is doing width-relative
    /// cursor arithmetic against the old screen, and truncating instead costs
    /// what a user sees as a mangled window: a line the program wrapped stays
    /// broken where it was broken, so widening leaves rows starting mid-word
    /// (`widening_does_not_re_join_a_wrapped_line`). Ghostty never shows that
    /// because it always reflows; this is the same behaviour, restricted to the
    /// case where it is safe.
    ///
    /// Also the reflow the crate's own tests reproduce the duplicate with.
    pub fn resize_reflowing(&mut self, rows: u16, cols: u16) -> Result<()> {
        // Pixel dimensions are not used by the daemon snapshot sidecar; fixed
        // cell metrics still give libghostty-vt consistent total dimensions.
        check(self.terminal.resize(cols, rows, 8, 16), "Terminal::resize")
    }

    /// Resize while a **shell** holds the terminal: reflow when the screen
    /// carries OSC 133 prompt marks, truncate (`resize`) when it does not.
    ///
    /// This is Ghostty.app's escape from the duplicated-prompt trap, done in
    /// the order its engine regression (dde3d4d6b) got wrong: blank the
    /// current prompt *before* reflowing. zsh's SIGWINCH redisplay moves the
    /// cursor up by the physical rows its prompt occupied at the width it was
    /// drawn, then clears down and reprints. Blank rows do not rewrap, so
    /// clearing the prompt's rows first keeps that arithmetic true across the
    /// reflow — the redraw lands on clean cells — while everything above the
    /// prompt rewraps to the new width instead of losing line tails.
    ///
    /// Only the prompt run the cursor sits in is cleared: the walk ascends
    /// through continuation rows to the nearest primary prompt row and stops
    /// there, so an earlier prompt stacked directly above (enter pressed at an
    /// empty prompt) is history nobody will redraw and is left to reflow as
    /// ordinary text. The cursor is saved and restored (DECSC/DECRC) around
    /// the clear because the redisplay's row arithmetic starts from wherever
    /// the cursor was — parking it at the prompt's first row would shift the
    /// whole repaint up by the prompt's height.
    pub fn resize_for_shell(&mut self, rows: u16, cols: u16) -> Result<()> {
        match self.current_prompt_start()? {
            Some(prompt_row) => {
                let clear = format!("\x1b7\x1b[{};1H\x1b[J\x1b8", u32::from(prompt_row) + 1);
                self.vt_write(clear.as_bytes());
                self.resize_reflowing(rows, cols)
            }
            None => self.resize(rows, cols),
        }
    }

    /// The first row of the prompt the cursor currently sits in, or `None`
    /// when the cursor is not on an OSC 133-marked row — an unmarked shell, a
    /// program that took the alternate screen, or a screen state the marks do
    /// not describe. `None` is the signal to fall back to the truncating
    /// resize, so every uncertain answer here must be `None`.
    fn current_prompt_start(&self) -> Result<Option<u16>> {
        let alternate =
            check(self.terminal.active_screen(), "Terminal::active_screen")? == Screen::Alternate;
        if alternate {
            return Ok(None);
        }
        let mut y = check(self.terminal.cursor_y(), "Terminal::cursor_y")?;
        loop {
            match self.row_semantic_prompt(y)? {
                RowSemanticPrompt::Prompt => return Ok(Some(y)),
                RowSemanticPrompt::Continuation if y > 0 => y -= 1,
                _ => return Ok(None),
            }
        }
    }

    fn row_semantic_prompt(&self, y: u16) -> Result<RowSemanticPrompt> {
        let reference = check(
            self.terminal.grid_ref(Point::Active(PointCoordinate {
                x: 0,
                y: u32::from(y),
            })),
            "Terminal::grid_ref(active)",
        )?;
        let row = check(reference.row(), "GridRef::row")?;
        check(row.semantic_prompt(), "Row::semantic_prompt")
    }

    /// The formatter `format_vt` writes with, shared with the tests that
    /// compare it against the Swift client's.
    ///
    /// Deliberately without `PALETTE`: emitting OSC 4 would push the host's
    /// palette onto the client and override the local theme. And without
    /// `TABSTOPS`: see `format_vt`, the walk that writes them lands the cursor
    /// on the last stop, and 9d8fbd1 emits it ahead of the content.
    fn vt_formatter(&self) -> Result<Formatter<'_, 'static, 'static>> {
        let mut formatter = check(Formatter::new(&self.terminal), "Formatter::new(terminal)")?;
        check(formatter.set_format(Format::Vt), "Formatter::set_format")?;
        check(formatter.set_unwrap(false), "Formatter::set_unwrap")?;
        check(formatter.set_trim(false), "Formatter::set_trim")?;
        check(
            formatter.set_extras(
                Extras::MODES
                    | Extras::SCROLLING_REGION
                    | Extras::PWD
                    | Extras::KEYBOARD
                    | Extras::CURSOR
                    | Extras::STYLE
                    | Extras::HYPERLINK
                    | Extras::PROTECTION
                    | Extras::KITTY_KEYBOARD
                    | Extras::CHARSETS,
            ),
            "Formatter::set_extras",
        )?;
        Ok(formatter)
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
        let mut formatted = SNAPSHOT_PROLOGUE.to_vec();
        {
            let mut formatter = self.vt_formatter()?;
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
            Ok(title) if !title.is_empty() => Some(String::from_utf8_lossy(title).into_owned()),
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
    use super::{Color, ProgramState, Rgb, VtEvent, VtTerminal};

    /// One thing the daemon does to its VT, in stream order: bytes, or a resize
    /// with the `reflow` flag a `vt_stream` client receives in its marker.
    enum Step {
        Bytes(&'static [u8]),
        Resize { rows: u16, cols: u16, reflow: bool },
    }

    fn apply(terminal: &mut VtTerminal, rows: u16, cols: u16, reflow: bool) {
        let resized = if reflow {
            terminal.resize_reflowing(rows, cols)
        } else {
            terminal.resize_for_shell(rows, cols)
        };
        resized.expect("resize");
    }

    fn session_script() -> Vec<Step> {
        use Step::{Bytes, Resize};
        vec![
            Bytes(b"\x1b]133;A\x07\x1b[32m~/repo\x1b[0m $ \x1b]133;B\x07"),
            Bytes(b"echo a long command that wraps past the edge of a narrow terminal"),
            Bytes(b"\r\n\x1b]133;C\x07\x1b[1;31mred\x1b[0m \x1b[3mitalic\x1b[0m \xe4\xbd\xa0\xe5\xa5\xbd\r\n"),
            Resize { rows: 8, cols: 24, reflow: false },
            Bytes(b"\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07typed"),
            Resize { rows: 8, cols: 40, reflow: false },
            Bytes(b"\r\n\x1b[?1049h\x1b[H\x1b[2J\x1b[?7l"),
            Bytes(b"\x1b[1;1H\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x80\xe2\x94\x90\x1b[2;1H\xe2\x94\x82\x1b[7mtui\x1b[0m\xe2\x94\x82"),
            Resize { rows: 10, cols: 30, reflow: true },
            Bytes(b"\x1b[3;1H\x1b[38;2;255;128;0mtrue colour\x1b[0m\x1b[?7h"),
            Resize { rows: 6, cols: 16, reflow: true },
            Bytes(b"\x1b[?1049l\r\n\x1b]133;A\x07$ \x1b]133;B\x07"),
            Resize { rows: 9, cols: 50, reflow: false },
            Bytes(b"done \xf0\x9f\x9a\x80\r\n"),
            // An empty prompt answered with Enter, and below it a command
            // typed long enough to wrap: the resize lands with the cursor on
            // a continuation row, so only a walk that climbs to the second
            // prompt's first row, and no further, clears the right rows.
            Bytes(b"\x1b]133;A\x07$ \x1b]133;B\x07\r\n"),
            Bytes(b"\x1b]133;A\x07$ \x1b]133;B\x07a typed command long enough to wrap twice at fifty columns wide"),
            Resize { rows: 9, cols: 30, reflow: false },
            Bytes(b"\x1b[1;4mstyled\x1b[0m"),
            // A Kitty image 8 by 40 pixels, black RGB: the cursor moves past
            // the three rows it covers at 8 by 16, which a client only does
            // with the same cell size and image rules as the daemon.
            Bytes(kitty_image()),
            Bytes(b"after the image"),
            // A PNG 16 by 20 pixels covers two cells by two rows, a gray one
            // 9 by 17 the same. Each one after is refused by both decoders, so
            // the cursor stays where it was: past the decoded-size limit by its
            // header, cut short before IEND, a damaged CRC. Bytes after the
            // IEND are ignored by both.
            Bytes(kitty_command(&png_image(16, 20, ::png::ColorType::Rgba, ::png::BitDepth::Eight))),
            Bytes(b"png"),
            Bytes(kitty_command(&png_image(9, 17, ::png::ColorType::Grayscale, ::png::BitDepth::Eight))),
            Bytes(b"gray"),
            Bytes(kitty_command(&png_image(1600, 1600, ::png::ColorType::Grayscale, ::png::BitDepth::One))),
            Bytes(b"too big"),
            Bytes(kitty_command(&png_cut())),
            Bytes(b"cut"),
            Bytes(kitty_command(&png_damaged())),
            Bytes(b"damaged"),
            Bytes(kitty_command(&[png_image(8, 16, ::png::ColorType::Rgb, ::png::BitDepth::Eight), b"trailing".to_vec()].concat())),
            Bytes(b"trailing"),
            // The shared header rule decides, not either library: a bad CRC on
            // an ancillary chunk and an IEND with a body are refused, and pixel
            // data a library cannot decode is kept as zeros at the header size,
            // so the cursor still moves.
            Bytes(kitty_command(&png_ancillary_bad_crc())),
            Bytes(b"text crc"),
            Bytes(kitty_command(&png_iend_body())),
            Bytes(b"iend body"),
            Bytes(kitty_command(&png_short_idat())),
            Bytes(b"short"),
            Bytes(kitty_command(&png_empty_idat())),
            Bytes(b"empty"),
        ]
    }

    /// termiod answers as the embedded surface does, and only while on: a
    /// replay, or a writer that answers for itself, gets nothing from here.
    #[test]
    fn queries_are_answered_as_the_embedded_surface_does_only_while_on() {
        let answer = |query: &[u8], answers: Option<&super::Answers>| {
            let mut terminal = VtTerminal::new(24, 80).expect("terminal");
            terminal.resize(24, 80).expect("resize");
            if let Some(answers) = answers {
                terminal.set_answers(answers).expect("answers");
            }
            terminal.vt_write(query);
            assert!(terminal.take_replies().is_empty(), "answered while off");
            terminal.set_answering(true);
            terminal.vt_write(query);
            String::from_utf8(terminal.take_replies()).expect("utf-8")
        };
        let dark = super::Answers {
            xtversion: "ghostty 1.3.1".to_string(),
            foreground: Some([0xdd, 0xdd, 0xdd]),
            background: Some([0x11, 0x22, 0x33]),
            dark: Some(true),
            ..Default::default()
        };
        assert_eq!(answer(b"\x1b[c", None), "\x1b[?62;22;52c");
        assert_eq!(answer(b"\x1b[>c", None), "\x1b[>1;10;0c");
        assert_eq!(answer(b"\x1b[>q", Some(&dark)), "\x1bP>|ghostty 1.3.1\x1b\\");
        assert_eq!(answer(b"\x1b[18t", None), "\x1b[8;24;80t");
        assert_eq!(answer(b"\x1b[16t", None), "\x1b[6;16;8t");
        assert_eq!(answer(b"\x1b[6n", None), "\x1b[1;1R");
        assert_eq!(answer(b"\x1b[?996n", Some(&dark)), "\x1b[?997;1n");
        assert_eq!(answer(b"\x1b[?996n", None), "");
        let light = super::Answers { dark: Some(false), ..dark.clone() };
        assert_eq!(answer(b"\x1b[?996n", Some(&light)), "\x1b[?997;2n");
        assert_eq!(answer(b"\x1b]11;?\x07", Some(&dark)), "\x1b]11;rgb:1111/2222/3333\x07");
    }

    /// The two answers no query asks for: a scheme report when the writer's
    /// appearance changes under mode 2031, and the in-band size report a
    /// resize writes under mode 2048.
    #[test]
    fn unsolicited_reports_follow_their_modes() {
        let mut terminal = VtTerminal::new(24, 80).expect("terminal");
        terminal.resize(24, 80).expect("resize");
        terminal.set_answering(true);
        let light = super::Answers { dark: Some(false), ..Default::default() };
        let dark = super::Answers { dark: Some(true), ..Default::default() };
        terminal.set_answers(&light).expect("answers");
        terminal.set_answers(&dark).expect("answers");
        assert!(terminal.take_replies().is_empty(), "reported a scheme nobody asked to hear");
        terminal.vt_write(b"\x1b[?2031h");
        terminal.set_answers(&light).expect("answers");
        assert_eq!(String::from_utf8(terminal.take_replies()).unwrap(), "\x1b[?997;2n");
        terminal.set_answers(&light).expect("answers");
        assert!(terminal.take_replies().is_empty(), "reported a scheme that did not change");

        terminal.vt_write(b"\x1b[?2048h");
        terminal.take_replies();
        terminal.resize(30, 100).expect("resize");
        assert_eq!(String::from_utf8(terminal.take_replies()).unwrap(), "\x1b[48;30;100;480;800t");
    }

    /// While somebody writes, their pane answers size reports, kitty
    /// clipboard reads and the cursor's style and blink: this VT would report
    /// 8 by 16 cells, refuse, and give the engine's default cursor.
    #[test]
    fn a_writers_pane_answers_sizes_and_the_kitty_clipboard() {
        let mut terminal = VtTerminal::new(24, 80).expect("terminal");
        terminal.resize(24, 80).expect("resize");
        terminal.set_answering(true);
        terminal.vt_write(b"\x1b]5522;type=read\x1b\\");
        assert!(String::from_utf8(terminal.take_replies()).unwrap().contains("EPERM"), "nobody writes: refused here");
        terminal.set_alone(false);
        terminal.vt_write(b"\x1b]5522;type=read\x1b\\\x1b[18t\x1b[?2048h");
        terminal.resize(30, 100).expect("resize");
        terminal.vt_write(b"\x1b[?12$p\x1bP$q q\x1b\\");
        terminal.vt_write(b"\x1b[c");
        assert_eq!(String::from_utf8(terminal.take_replies()).unwrap(), "\x1b[?62;22;52c");
        terminal.set_alone(true);
        terminal.vt_write(b"\x1b[?12$p\x1bP$q q\x1b\\");
        let alone = String::from_utf8(terminal.take_replies()).unwrap();
        assert!(alone.starts_with("\x1b[?12;") && alone.ends_with(" q\x1b\\"), "nobody writes: answered here, {alone:?}");
    }

    /// A skin-tone emoji is one grapheme in one wide cell, as in Ghostty, so
    /// the cursor lands two columns on, not four.
    #[test]
    fn a_modified_emoji_is_one_grapheme() {
        let mut terminal = VtTerminal::new(4, 20).expect("terminal");
        terminal.vt_write("👍🏽x".as_bytes());
        let screen = terminal.snapshot().expect("cells");
        assert_eq!(screen.cursor_x, 3);
    }

    /// A PNG moves the cursor past the rows it covers on any thread, not only
    /// on the one that installed the decoder.
    #[test]
    fn a_kitty_png_is_decoded_on_every_thread() {
        let cursor = |image: &'static [u8]| {
            let mut terminal = VtTerminal::new(10, 20).expect("terminal");
            // A new terminal has no cell size until its first resize.
            terminal.resize(10, 20).expect("resize");
            terminal.vt_write(image);
            let screen = terminal.snapshot().expect("cells");
            (screen.cursor_x, screen.cursor_y)
        };
        let small = kitty_command(&png_image(16, 20, ::png::ColorType::Rgba, ::png::BitDepth::Eight));
        assert_eq!(cursor(small), (2, 2));
        assert_eq!(std::thread::spawn(move || cursor(small)).join().expect("thread"), (2, 2));
        let large = png_image(1600, 1600, ::png::ColorType::Grayscale, ::png::BitDepth::One);
        assert_eq!(cursor(kitty_command(&large)), (0, 1));
        assert_eq!(cursor(kitty_command(&png_cut())), (0, 1));
        assert_eq!(cursor(kitty_command(&png_damaged())), (0, 1));
        assert_eq!(cursor(kitty_command(&png_ancillary_bad_crc())), (0, 1));
        assert_eq!(cursor(kitty_command(&png_iend_body())), (0, 1));
        // Undecodable pixels: accepted as zeros, one cell by one row.
        assert_eq!(cursor(kitty_command(&png_short_idat())), (1, 1));
        assert_eq!(cursor(kitty_command(&png_empty_idat())), (1, 1));
    }

    fn png_image(width: u32, height: u32, color: ::png::ColorType, depth: ::png::BitDepth) -> Vec<u8> {
        let mut encoded = Vec::new();
        let mut encoder = ::png::Encoder::new(&mut encoded, width, height);
        encoder.set_color(color);
        encoder.set_depth(depth);
        let bits = color.samples() * depth as usize;
        let row = (width as usize * bits).div_ceil(8);
        // A pattern for the small images, zeros for the large one, so its
        // payload stays small and the every-boundary test stays quick.
        let pattern = |index: usize| if bits == 1 { 0 } else { (index * 7) as u8 };
        let pixels: Vec<u8> = (0..row * height as usize).map(pattern).collect();
        let mut writer = encoder.write_header().expect("png header");
        writer.write_image_data(&pixels).expect("png data");
        writer.finish().expect("png finish");
        encoded
    }

    /// Every pixel present, the IEND chunk missing.
    fn png_cut() -> Vec<u8> {
        let mut image = png_image(8, 16, ::png::ColorType::Rgb, ::png::BitDepth::Eight);
        image.truncate(image.len() - 12);
        image
    }

    /// The IDAT chunk's CRC with one bit flipped.
    fn png_damaged() -> Vec<u8> {
        let mut image = png_image(8, 16, ::png::ColorType::Rgb, ::png::BitDepth::Eight);
        let end = image.len() - 12;
        image[end - 1] ^= 1;
        image
    }

    fn png_chunk(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let crc = crc32fast::hash(&[kind.as_slice(), body].concat());
        [&(body.len() as u32).to_be_bytes()[..], kind, body, &crc.to_be_bytes()].concat()
    }

    /// A valid 8 by 16 RGB PNG split as (signature and IHDR, IDAT body).
    fn png_parts() -> (Vec<u8>, Vec<u8>) {
        let image = png_image(8, 16, ::png::ColorType::Rgb, ::png::BitDepth::Eight);
        let head = image[..33].to_vec();
        let length = u32::from_be_bytes(image[33..37].try_into().expect("length")) as usize;
        (head, image[41..41 + length].to_vec())
    }

    fn png_ancillary_bad_crc() -> Vec<u8> {
        let (head, idat) = png_parts();
        let mut text = png_chunk(b"tEXt", b"k\0v");
        *text.last_mut().expect("crc") ^= 1;
        [head, text, png_chunk(b"IDAT", &idat), png_chunk(b"IEND", &[])].concat()
    }

    fn png_iend_body() -> Vec<u8> {
        let (head, idat) = png_parts();
        [head, png_chunk(b"IDAT", &idat), png_chunk(b"IEND", &[0, 0])].concat()
    }

    fn png_short_idat() -> Vec<u8> {
        let (head, idat) = png_parts();
        [head, png_chunk(b"IDAT", &idat[..idat.len() / 2]), png_chunk(b"IEND", &[])].concat()
    }

    fn png_empty_idat() -> Vec<u8> {
        let (head, _) = png_parts();
        [head, png_chunk(b"IDAT", &[]), png_chunk(b"IEND", &[])].concat()
    }

    fn kitty_command(image: &[u8]) -> &'static [u8] {
        let command = format!("\r\n\x1b_Ga=T,f=100,q=2;{}\x1b\\", base64(image));
        Box::leak(command.into_bytes().into_boxed_slice())
    }

    fn base64(bytes: &[u8]) -> String {
        const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut text = String::new();
        for chunk in bytes.chunks(3) {
            let word = chunk.iter().enumerate().fold(0u32, |word, (index, byte)| word | u32::from(*byte) << (16 - 8 * index));
            for index in 0..4 {
                text.push(if index <= chunk.len() { ALPHABET[(word >> (18 - 6 * index) & 63) as usize] as char } else { '=' });
            }
        }
        text
    }

    fn kitty_image() -> &'static [u8] {
        let payload = "A".repeat(8 * 40 * 3 / 3 * 4);
        let command = format!("\r\n\x1b_Ga=T,f=24,s=8,v=40,q=2;{payload}\x1b\\");
        Box::leak(command.into_bytes().into_boxed_slice())
    }

    /// The `vt_stream` contract: a client that decodes the native snapshot at
    /// any byte boundary, then applies the same bytes and resize markers, holds
    /// the daemon's screen exactly. Every boundary is tried, including inside
    /// escape sequences and UTF-8 codepoints, and the screens are compared
    /// after every step that follows the attach.
    #[test]
    fn a_client_decoding_the_native_snapshot_tracks_the_daemon_through_resizes() {
        let script = session_script();
        let boundaries: usize = script
            .iter()
            .map(|step| match step {
                Step::Bytes(bytes) => bytes.len(),
                Step::Resize { .. } => 0,
            })
            .sum();
        for attach_at in 0..=boundaries {
            let mut daemon = VtTerminal::new(6, 20).expect("daemon terminal");
            let mut client: Option<VtTerminal> = None;
            let mut written = 0usize;
            for (index, step) in script.iter().enumerate() {
                match step {
                    Step::Bytes(bytes) => {
                        let mut rest: &[u8] = bytes;
                        if client.is_none() && written + rest.len() >= attach_at {
                            let (before, after) = rest.split_at(attach_at - written);
                            daemon.vt_write(before);
                            written += before.len();
                            let snapshot = daemon.native_snapshot().expect("native snapshot");
                            client =
                                Some(VtTerminal::from_native_snapshot(&snapshot).expect("decode"));
                            rest = after;
                        }
                        daemon.vt_write(rest);
                        written += rest.len();
                        if let Some(client) = client.as_mut() {
                            client.vt_write(rest);
                        }
                    }
                    Step::Resize { rows, cols, reflow } => {
                        apply(&mut daemon, *rows, *cols, *reflow);
                        if let Some(client) = client.as_mut() {
                            apply(client, *rows, *cols, *reflow);
                        }
                    }
                }
                if let Some(client) = client.as_mut() {
                    assert_eq!(
                        client.snapshot().expect("client cells"),
                        daemon.snapshot().expect("daemon cells"),
                        "cells diverged attaching at byte {attach_at}, after step {index}"
                    );
                    // Scrollback is pruned by whole pages, and a terminal
                    // decoded from a snapshot lays its pages out differently
                    // from one that grew byte by byte. Where 4 KB pages make
                    // them prune at different rows, the rows the client keeps
                    // must still be the newest the daemon keeps.
                    let client_rows = client.scrollback(usize::MAX).expect("client scrollback").rows;
                    let daemon_rows = daemon.scrollback(usize::MAX).expect("daemon scrollback").rows;
                    if client_rows.len() == daemon_rows.len() {
                        assert_eq!(
                            client.format_vt().expect("client vt"),
                            daemon.format_vt().expect("daemon vt"),
                            "screens diverged attaching at byte {attach_at}, after step {index}"
                        );
                    } else {
                        let kept = client_rows.len().min(daemon_rows.len());
                        assert_eq!(
                            client_rows[..kept],
                            daemon_rows[..kept],
                            "scrollback diverged attaching at byte {attach_at}, after step {index}"
                        );
                    }
                }
            }
        }
    }

    /// The screen as the formatter writes it with `format_vt`'s options, minus
    /// the prologue and fixups that method adds, for comparing a client written
    /// in another language against this one.
    fn formatted(terminal: &VtTerminal) -> Vec<u8> {
        let mut formatter = terminal.vt_formatter().expect("formatter");
        // A blank screen formats to nothing, which `format_alloc` and
        // `format_len` both report as an error.
        let mut text = vec![0; 1 << 16];
        let length = formatter.format_buf(&mut text).expect("formatted screen");
        text.truncate(length);
        text
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    /// The Mac client's `vt_stream` terminal is Swift, so it cannot share
    /// `apply` with the daemon. Instead this records what the daemon's VT holds
    /// after every step of `session_script`, attached inside an OSC sequence,
    /// and the Swift test replays the same steps against it
    /// (`Tests/termioTests/StreamTerminalTests.swift`). Run with
    /// `TERMIO_UPDATE_FIXTURES=1` after changing the script or the engine.
    #[test]
    fn the_client_resize_fixture_matches_the_daemon() {
        let attach_at = 4;
        let mut daemon = VtTerminal::new(6, 20).expect("daemon terminal");
        let mut fixture = String::new();
        let mut written = 0usize;
        let mut attached = false;
        for step in session_script() {
            match step {
                Step::Bytes(bytes) => {
                    let mut rest: &[u8] = bytes;
                    if !attached && written + rest.len() >= attach_at {
                        let (before, after) = rest.split_at(attach_at - written);
                        daemon.vt_write(before);
                        fixture += &format!(
                            "attach {}\n",
                            hex(&daemon.native_snapshot().expect("native snapshot"))
                        );
                        attached = true;
                        rest = after;
                    }
                    daemon.vt_write(rest);
                    written += bytes.len();
                    if !attached {
                        continue;
                    }
                    fixture += &format!("bytes {}\n", hex(rest));
                }
                Step::Resize { rows, cols, reflow } => {
                    apply(&mut daemon, rows, cols, reflow);
                    fixture += &format!("resize {rows} {cols} {}\n", u8::from(reflow));
                }
            }
            let screen = daemon.snapshot().expect("daemon cells");
            let width = daemon.terminal.width_px().expect("width");
            let height = daemon.terminal.height_px().expect("height");
            fixture += &format!(
                "screen {} {} {width} {height} {} {} {} {}\n",
                screen.rows,
                screen.cols,
                screen.cursor_x,
                screen.cursor_y,
                u8::from(screen.alt_screen),
                hex(&formatted(&daemon))
            );
        }

        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Tests/termioTests/Fixtures/vt-stream-resize.txt");
        if std::env::var_os("TERMIO_UPDATE_FIXTURES").is_some() {
            std::fs::write(&path, &fixture).expect("write fixture");
        }
        let committed = std::fs::read_to_string(&path).expect("read fixture");
        assert!(
            committed == fixture,
            "{} is stale; rerun with TERMIO_UPDATE_FIXTURES=1",
            path.display()
        );
    }

    /// The events arrive in the order the bytes did. A query is not one of
    /// them: the read path answers it.
    #[test]
    fn program_status_events_keep_byte_order() {
        let mut terminal = VtTerminal::new(3, 20).expect("terminal");
        terminal.vt_write(b"\x1b[c\x1b]7501;?\x07");
        terminal.vt_write(b"\x1b]7501;state=working\x07\x1b]133;A\x07");
        terminal.vt_write(b"\x1b]7501;state=done:id=build\x07\x1bc");
        assert_eq!(
            terminal.take_events(),
            [
                VtEvent::ProgramStatus {
                    state: ProgramState::Working,
                    id: String::new()
                },
                VtEvent::PromptStart,
                VtEvent::ProgramStatus {
                    state: ProgramState::Done,
                    id: "build".into()
                },
                VtEvent::ProgramStatus {
                    state: ProgramState::Clear,
                    id: String::new()
                },
            ]
        );
        assert!(terminal.take_events().is_empty());
    }

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
