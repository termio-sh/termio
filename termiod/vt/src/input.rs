//! Input from a `vt_stream` client, encoded where Rex's server encodes it:
//! against the host VT's own modes, not the client's copy, which is one round
//! trip behind the program.
//!
//! The sidecar thread owns the VT, so it copies the modes into the encoders
//! after each batch it parses (`refresh`), and the session actor encodes with
//! them as they are. Input never waits for the parse: a Ctrl-C sent during a
//! flood is encoded at once, against the modes of the last byte parsed.

use libghostty_vt::key::{self, Key, Mods, OptionAsAlt};
use libghostty_vt::mouse;
use libghostty_vt::screen::Screen;
use libghostty_vt::mode::Mode;

use crate::{Result, VtError, VtTerminal};

/// What a key did, as the keyboard reported it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAction {
    Press,
    Release,
    Repeat,
}

/// One key event. `key` is the physical key by Ghostty's name for it
/// (`arrow_up`, `a`, `digit_1`), `mods` and `consumed_mods` are libghostty's
/// modifier bits, and `text` is what the layout typed, never a control code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyInput {
    pub action: KeyAction,
    pub key: String,
    pub mods: u16,
    pub consumed_mods: u16,
    pub text: Option<String>,
    pub unshifted: u32,
    pub composing: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Motion,
}

/// A point on the grid, in pixels from its top-left corner, with the cell
/// size the client drew it at.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pointer {
    pub x: f32,
    pub y: f32,
    pub cell_width: u32,
    pub cell_height: u32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MouseInput {
    pub action: MouseAction,
    /// 1 left, 2 right, 3 middle, 4 to 11 the rest; none for plain motion.
    pub button: Option<u8>,
    pub mods: u16,
    pub at: Pointer,
    /// Whether any button is down once this event has happened.
    pub buttons_held: bool,
}

/// A wheel turned by whole rows and columns; negative is up and left.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WheelInput {
    pub rows: i32,
    pub columns: i32,
    pub mods: u16,
    pub at: Pointer,
}

/// The modes beyond the encoders' own options that decide where input goes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InputModes {
    pub rows: u16,
    pub cols: u16,
    pub bracketed_paste: bool,
    pub focus_reporting: bool,
    pub mouse_tracking: bool,
    pub alternate_screen: bool,
    pub alternate_scroll: bool,
    pub cursor_keys_application: bool,
}

pub struct InputEncoder {
    key: key::Encoder<'static>,
    key_event: key::Event<'static>,
    mouse: mouse::Encoder<'static>,
    mouse_event: mouse::Event<'static>,
    modes: InputModes,
    /// The size last given to the mouse encoder. Setting it clears the
    /// encoder's motion deduplication, so it is set only when it changes.
    mouse_size: Option<mouse::EncoderSize>,
    /// The cell the last mouse report named. The engine's own deduplication
    /// is cleared each time the terminal's options are copied in, which is
    /// after every parsed batch, so motion is deduplicated here instead.
    last_cell: Option<(i64, i64)>,
    /// Whether the active format is SGR-Pixels, which reports every pixel and
    /// so is never deduplicated by cell. The format is whichever the program
    /// set last, which no mode bit says, so it is read off the encoder.
    pixel_reports: bool,
    /// Keys whose press went out without Alt because Option typed text with
    /// them, so their repeats and release go out the same way.
    option_text_keys: std::collections::HashSet<String>,
}

/// The most rows or columns one wheel event may scroll. A real gesture is a
/// few; this keeps one event from holding the session for billions.
pub const WHEEL_LIMIT: i32 = 500;

const ALT: u16 = 1 << 2;

// SAFETY: the encoders and events are option holders that keep no pointer to
// any terminal once `set_options_from_terminal` returns, and every use goes
// through `&mut self`, so moving them to another thread is sound; the session
// shares one behind a mutex.
unsafe impl Send for InputEncoder {}

fn check<T>(result: libghostty_vt::error::Result<T>, call: &str) -> Result<T> {
    result.map_err(|error| VtError(format!("{call}: {error}")))
}

impl InputEncoder {
    pub fn new() -> Result<Self> {
        let mut mouse = check(mouse::Encoder::new(), "mouse::Encoder::new")?;
        mouse.set_track_last_cell(false);
        Ok(Self {
            key: check(key::Encoder::new(), "key::Encoder::new")?,
            key_event: check(key::Event::new(), "key::Event::new")?,
            mouse,
            mouse_event: check(mouse::Event::new(), "mouse::Event::new")?,
            modes: InputModes::default(),
            mouse_size: None,
            last_cell: None,
            pixel_reports: false,
            option_text_keys: std::collections::HashSet::new(),
        })
    }

    /// Copies the terminal's modes in. Called on the sidecar thread after it
    /// parses a batch or resizes, under the session's lock on this encoder.
    pub fn refresh(&mut self, vt: &VtTerminal) {
        let terminal = &vt.terminal;
        self.key.set_options_from_terminal(terminal);
        // Option composes text on a Mac, as Ghostty leaves it by default.
        self.key.set_macos_option_as_alt(OptionAsAlt::False);
        let mode = |mode| terminal.mode(mode).unwrap_or(false);
        // Every time: which format wins depends on the order the program set
        // them in, which only the terminal knows.
        self.mouse.set_options_from_terminal(terminal);
        self.modes = InputModes {
            rows: terminal.rows().unwrap_or(0),
            cols: terminal.cols().unwrap_or(0),
            bracketed_paste: mode(Mode::BRACKETED_PASTE),
            focus_reporting: mode(Mode::FOCUS_EVENT),
            mouse_tracking: terminal.is_mouse_tracking().unwrap_or(false),
            alternate_screen: matches!(terminal.active_screen(), Ok(Screen::Alternate)),
            alternate_scroll: mode(Mode::ALT_SCROLL),
            cursor_keys_application: mode(Mode::DECCKM),
        };
        // Probed with the grid known, so the probe's point is on it.
        self.pixel_reports = mode(Mode::SGR_PIXELS_MOUSE) && self.encodes_pixels();
    }

    pub fn modes(&self) -> InputModes {
        self.modes
    }

    /// The bytes a key sends. A key whose name this engine does not know sends
    /// nothing rather than a guess.
    pub fn key(&mut self, input: &KeyInput) -> Vec<u8> {
        let Some(key) = key_named(&input.key) else {
            return Vec::new();
        };
        // On a Mac, Option composes text, and libghostty built for macOS
        // treats it so: no ESC prefix, and the text survives under Kitty. A
        // daemon built for anything else takes Alt for a real modifier, so a
        // German `@` (Option-L) would arrive as `ESC @`. When Option produced
        // the text, the key is sent without it.
        let mut mods = input.mods;
        if cfg!(not(target_os = "macos")) && mods & ALT != 0 {
            let typed = input.text.as_deref().is_some_and(|text| !text.is_empty());
            let pressed_so = self.option_text_keys.contains(&input.key);
            if (input.action == KeyAction::Press && typed) || (input.action != KeyAction::Press && pressed_so) {
                mods &= !ALT;
            }
        }
        match input.action {
            KeyAction::Press if mods != input.mods => {
                self.option_text_keys.insert(input.key.clone());
            }
            KeyAction::Press => {
                self.option_text_keys.remove(&input.key);
            }
            KeyAction::Release => {
                self.option_text_keys.remove(&input.key);
            }
            KeyAction::Repeat => {}
        }
        self.key_event
            .set_action(match input.action {
                KeyAction::Press => key::Action::Press,
                KeyAction::Release => key::Action::Release,
                KeyAction::Repeat => key::Action::Repeat,
            })
            .set_key(key)
            .set_mods(Mods::from_bits_truncate(mods))
            .set_consumed_mods(Mods::from_bits_truncate(input.consumed_mods & (mods | !ALT)))
            .set_composing(input.composing)
            .set_utf8(input.text.clone())
            .set_unshifted_codepoint(char::from_u32(input.unshifted).unwrap_or('\0'));
        let mut bytes = Vec::new();
        if let Err(error) = self.key.encode_to_vec(&self.key_event, &mut bytes) {
            eprintln!("termiod: key {} not encoded: {error}", input.key);
        }
        bytes
    }

    pub fn mouse(&mut self, input: &MouseInput) -> Vec<u8> {
        // In the motion modes the encoder reports a point off the grid while a
        // button is held, clamped to the edge. That is for a drag that leaves
        // the grid; a click in the pane's blank space is not on the terminal.
        if input.action == MouseAction::Press && !self.on_grid(input.at) {
            return Vec::new();
        }
        // The cell the report names: clamped to the grid, as the encoder does.
        let clamp = |value: f32, cell: u32, count: u16| {
            let index = (f64::from(value) / f64::from(cell.max(1))).floor() as i64;
            index.clamp(0, i64::from(count.max(1)) - 1)
        };
        let cell = (
            clamp(input.at.x, input.at.cell_width, self.modes.cols),
            clamp(input.at.y, input.at.cell_height, self.modes.rows),
        );
        if input.action == MouseAction::Motion && !self.pixel_reports && self.last_cell == Some(cell) {
            return Vec::new();
        }
        self.set_size(input.at);
        self.mouse.set_any_button_pressed(input.buttons_held);
        self.mouse_event
            .set_action(match input.action {
                MouseAction::Press => mouse::Action::Press,
                MouseAction::Release => mouse::Action::Release,
                MouseAction::Motion => mouse::Action::Motion,
            })
            .set_button(input.button.and_then(button))
            .set_mods(Mods::from_bits_truncate(input.mods))
            .set_position(mouse::Position { x: input.at.x, y: input.at.y });
        let mut bytes = Vec::new();
        if let Err(error) = self.mouse.encode_to_vec(&self.mouse_event, &mut bytes) {
            eprintln!("termiod: mouse event not encoded: {error}");
        }
        if !bytes.is_empty() {
            self.last_cell = Some(cell);
        }
        bytes
    }

    /// Ghostty's wheel: a program tracking the mouse gets wheel buttons, four
    /// and five for rows and six and seven for columns; one on the alternate
    /// screen with alternate scroll (mode 1007) gets a cursor key per row, in
    /// the cursor-key mode it chose. Anything else is the client's own
    /// scrollback, and sends nothing.
    pub fn wheel(&mut self, input: &WheelInput) -> Vec<u8> {
        let mut bytes = Vec::new();
        let rows = input.rows.clamp(-WHEEL_LIMIT, WHEEL_LIMIT);
        let columns = input.columns.clamp(-WHEEL_LIMIT, WHEEL_LIMIT);
        if self.modes.mouse_tracking {
            let mut press = |button: u8, count: i32| {
                for _ in 0..count.unsigned_abs() {
                    bytes.extend(self.mouse(&MouseInput {
                        action: MouseAction::Press,
                        button: Some(button),
                        mods: input.mods,
                        at: input.at,
                        buttons_held: false,
                    }));
                }
            };
            press(if rows < 0 { 4 } else { 5 }, rows);
            press(if columns < 0 { 6 } else { 7 }, columns);
        } else if self.modes.alternate_screen && self.modes.alternate_scroll {
            let arrow: &[u8] = match (rows < 0, self.modes.cursor_keys_application) {
                (true, false) => b"\x1b[A",
                (true, true) => b"\x1bOA",
                (false, false) => b"\x1b[B",
                (false, true) => b"\x1bOB",
            };
            for _ in 0..rows.unsigned_abs() {
                bytes.extend_from_slice(arrow);
            }
        }
        bytes
    }

    /// Pasted text: wrapped when the program asked for bracketed paste, with
    /// newlines as returns when it did not, and with any control byte that
    /// could end the paste early replaced.
    pub fn paste(&self, text: &str) -> Vec<u8> {
        self.paste_piece(text, self.modes.bracketed_paste, true, true)
    }

    /// One piece of a paste too large for one event. `bracketed` is decided
    /// once, by the first piece; the wrapping opens on the first and closes on
    /// the last, so the program sees one paste.
    pub fn paste_piece(&self, text: &str, bracketed: bool, opens: bool, closes: bool) -> Vec<u8> {
        const START: &[u8] = b"\x1b[200~";
        const END: &[u8] = b"\x1b[201~";
        let mut data = text.as_bytes().to_vec();
        let mut out = vec![0; data.len() + START.len() + END.len()];
        let mut encoded = match libghostty_vt::paste::encode(&mut data, bracketed, &mut out) {
            Ok(written) => {
                out.truncate(written);
                out
            }
            Err(error) => {
                eprintln!("termiod: paste not encoded: {error}");
                return Vec::new();
            }
        };
        if bracketed {
            if !closes && encoded.ends_with(END) {
                encoded.truncate(encoded.len() - END.len());
            }
            if !opens && encoded.starts_with(START) {
                encoded.drain(..START.len());
            }
        }
        encoded
    }

    /// The focus report, for a program that asked for one (mode 1004).
    pub fn focus(&self, focused: bool) -> Vec<u8> {
        if !self.modes.focus_reporting {
            return Vec::new();
        }
        let event = if focused {
            libghostty_vt::focus::Event::Gained
        } else {
            libghostty_vt::focus::Event::Lost
        };
        let mut out = [0u8; 8];
        match event.encode(&mut out) {
            Ok(written) => out[..written].to_vec(),
            Err(error) => {
                eprintln!("termiod: focus report not encoded: {error}");
                Vec::new()
            }
        }
    }

    /// Encodes one press to see which format won: the point (5, 10) in 10×20
    /// cells is cell (1, 1) on any grid, even one cell, so any report not
    /// naming that cell names pixels.
    fn encodes_pixels(&mut self) -> bool {
        self.mouse_size = None;
        self.set_size(Pointer { x: 0.0, y: 0.0, cell_width: 10, cell_height: 20 });
        self.mouse.set_any_button_pressed(true);
        self.mouse_event
            .set_action(mouse::Action::Press)
            .set_button(Some(mouse::Button::Left))
            .set_mods(Mods::empty())
            .set_position(mouse::Position { x: 5.0, y: 10.0 });
        let mut bytes = Vec::new();
        let _ = self.mouse.encode_to_vec(&self.mouse_event, &mut bytes);
        // The next real event sets its own size.
        self.mouse_size = None;
        bytes.starts_with(b"\x1b[<") && !bytes.ends_with(b";1;1M")
    }

    fn on_grid(&self, at: Pointer) -> bool {
        let width = u32::from(self.modes.cols) * at.cell_width.max(1);
        let height = u32::from(self.modes.rows) * at.cell_height.max(1);
        at.x >= 0.0 && at.y >= 0.0 && at.x < width as f32 && at.y < height as f32
    }

    /// The grid is the VT's, so a point past its last column is outside the
    /// terminal, not on its edge.
    fn set_size(&mut self, at: Pointer) {
        let cell_width = at.cell_width.max(1);
        let cell_height = at.cell_height.max(1);
        let size = mouse::EncoderSize {
            screen_width: u32::from(self.modes.cols) * cell_width,
            screen_height: u32::from(self.modes.rows) * cell_height,
            cell_width,
            cell_height,
            padding_top: 0,
            padding_bottom: 0,
            padding_right: 0,
            padding_left: 0,
        };
        if self.mouse_size != Some(size) {
            // Left unrecorded on failure, so the next event tries again.
            match self.mouse.set_size(size) {
                Ok(_) => self.mouse_size = Some(size),
                Err(error) => eprintln!("termiod-vt: mouse encoder size not set: {error}"),
            }
        }
    }
}

fn button(number: u8) -> Option<mouse::Button> {
    Some(match number {
        1 => mouse::Button::Left,
        2 => mouse::Button::Right,
        3 => mouse::Button::Middle,
        4 => mouse::Button::Four,
        5 => mouse::Button::Five,
        6 => mouse::Button::Six,
        7 => mouse::Button::Seven,
        8 => mouse::Button::Eight,
        9 => mouse::Button::Nine,
        10 => mouse::Button::Ten,
        11 => mouse::Button::Eleven,
        _ => return None,
    })
}

/// The modifier keys, by name: pressed alone they type nothing, so they do
/// not take the write token (the app's `claimsWriter` lists the same).
pub fn is_modifier_key(name: &str) -> bool {
    matches!(
        name,
        "shift_left" | "shift_right" | "control_left" | "control_right" | "alt_left" | "alt_right"
            | "meta_left" | "meta_right" | "caps_lock" | "fn" | "fn_lock"
    )
}

/// Ghostty's own names for the physical keys, as its keybind syntax spells
/// them. The wire carries names, not the C enum's numbers, because a remote
/// daemon and the app can run different engine releases for a while.
pub fn key_named(name: &str) -> Option<Key> {
    Some(match name {
        "backquote" => Key::Backquote,
        "backslash" => Key::Backslash,
        "bracket_left" => Key::BracketLeft,
        "bracket_right" => Key::BracketRight,
        "comma" => Key::Comma,
        "digit_0" => Key::Digit0,
        "digit_1" => Key::Digit1,
        "digit_2" => Key::Digit2,
        "digit_3" => Key::Digit3,
        "digit_4" => Key::Digit4,
        "digit_5" => Key::Digit5,
        "digit_6" => Key::Digit6,
        "digit_7" => Key::Digit7,
        "digit_8" => Key::Digit8,
        "digit_9" => Key::Digit9,
        "equal" => Key::Equal,
        "intl_backslash" => Key::IntlBackslash,
        "intl_ro" => Key::IntlRo,
        "intl_yen" => Key::IntlYen,
        "a" => Key::A,
        "b" => Key::B,
        "c" => Key::C,
        "d" => Key::D,
        "e" => Key::E,
        "f" => Key::F,
        "g" => Key::G,
        "h" => Key::H,
        "i" => Key::I,
        "j" => Key::J,
        "k" => Key::K,
        "l" => Key::L,
        "m" => Key::M,
        "n" => Key::N,
        "o" => Key::O,
        "p" => Key::P,
        "q" => Key::Q,
        "r" => Key::R,
        "s" => Key::S,
        "t" => Key::T,
        "u" => Key::U,
        "v" => Key::V,
        "w" => Key::W,
        "x" => Key::X,
        "y" => Key::Y,
        "z" => Key::Z,
        "minus" => Key::Minus,
        "period" => Key::Period,
        "quote" => Key::Quote,
        "semicolon" => Key::Semicolon,
        "slash" => Key::Slash,
        "alt_left" => Key::AltLeft,
        "alt_right" => Key::AltRight,
        "backspace" => Key::Backspace,
        "caps_lock" => Key::CapsLock,
        "context_menu" => Key::ContextMenu,
        "control_left" => Key::ControlLeft,
        "control_right" => Key::ControlRight,
        "enter" => Key::Enter,
        "meta_left" => Key::MetaLeft,
        "meta_right" => Key::MetaRight,
        "shift_left" => Key::ShiftLeft,
        "shift_right" => Key::ShiftRight,
        "space" => Key::Space,
        "tab" => Key::Tab,
        "convert" => Key::Convert,
        "kana_mode" => Key::KanaMode,
        "non_convert" => Key::NonConvert,
        "delete" => Key::Delete,
        "end" => Key::End,
        "help" => Key::Help,
        "home" => Key::Home,
        "insert" => Key::Insert,
        "page_down" => Key::PageDown,
        "page_up" => Key::PageUp,
        "arrow_down" => Key::ArrowDown,
        "arrow_left" => Key::ArrowLeft,
        "arrow_right" => Key::ArrowRight,
        "arrow_up" => Key::ArrowUp,
        "num_lock" => Key::NumLock,
        "numpad_0" => Key::Numpad0,
        "numpad_1" => Key::Numpad1,
        "numpad_2" => Key::Numpad2,
        "numpad_3" => Key::Numpad3,
        "numpad_4" => Key::Numpad4,
        "numpad_5" => Key::Numpad5,
        "numpad_6" => Key::Numpad6,
        "numpad_7" => Key::Numpad7,
        "numpad_8" => Key::Numpad8,
        "numpad_9" => Key::Numpad9,
        "numpad_add" => Key::NumpadAdd,
        "numpad_backspace" => Key::NumpadBackspace,
        "numpad_clear" => Key::NumpadClear,
        "numpad_clear_entry" => Key::NumpadClearEntry,
        "numpad_comma" => Key::NumpadComma,
        "numpad_decimal" => Key::NumpadDecimal,
        "numpad_divide" => Key::NumpadDivide,
        "numpad_enter" => Key::NumpadEnter,
        "numpad_equal" => Key::NumpadEqual,
        "numpad_memory_add" => Key::NumpadMemoryAdd,
        "numpad_memory_clear" => Key::NumpadMemoryClear,
        "numpad_memory_recall" => Key::NumpadMemoryRecall,
        "numpad_memory_store" => Key::NumpadMemoryStore,
        "numpad_memory_subtract" => Key::NumpadMemorySubtract,
        "numpad_multiply" => Key::NumpadMultiply,
        "numpad_paren_left" => Key::NumpadParenLeft,
        "numpad_paren_right" => Key::NumpadParenRight,
        "numpad_subtract" => Key::NumpadSubtract,
        "numpad_separator" => Key::NumpadSeparator,
        "numpad_up" => Key::NumpadUp,
        "numpad_down" => Key::NumpadDown,
        "numpad_right" => Key::NumpadRight,
        "numpad_left" => Key::NumpadLeft,
        "numpad_begin" => Key::NumpadBegin,
        "numpad_home" => Key::NumpadHome,
        "numpad_end" => Key::NumpadEnd,
        "numpad_insert" => Key::NumpadInsert,
        "numpad_delete" => Key::NumpadDelete,
        "numpad_page_up" => Key::NumpadPageUp,
        "numpad_page_down" => Key::NumpadPageDown,
        "escape" => Key::Escape,
        "f1" => Key::F1,
        "f2" => Key::F2,
        "f3" => Key::F3,
        "f4" => Key::F4,
        "f5" => Key::F5,
        "f6" => Key::F6,
        "f7" => Key::F7,
        "f8" => Key::F8,
        "f9" => Key::F9,
        "f10" => Key::F10,
        "f11" => Key::F11,
        "f12" => Key::F12,
        "f13" => Key::F13,
        "f14" => Key::F14,
        "f15" => Key::F15,
        "f16" => Key::F16,
        "f17" => Key::F17,
        "f18" => Key::F18,
        "f19" => Key::F19,
        "f20" => Key::F20,
        "f21" => Key::F21,
        "f22" => Key::F22,
        "f23" => Key::F23,
        "f24" => Key::F24,
        "f25" => Key::F25,
        "fn" => Key::Fn,
        "fn_lock" => Key::FnLock,
        "print_screen" => Key::PrintScreen,
        "scroll_lock" => Key::ScrollLock,
        "pause" => Key::Pause,
        "browser_back" => Key::BrowserBack,
        "browser_favorites" => Key::BrowserFavorites,
        "browser_forward" => Key::BrowserForward,
        "browser_home" => Key::BrowserHome,
        "browser_refresh" => Key::BrowserRefresh,
        "browser_search" => Key::BrowserSearch,
        "browser_stop" => Key::BrowserStop,
        "eject" => Key::Eject,
        "launch_app_1" => Key::LaunchApp1,
        "launch_app_2" => Key::LaunchApp2,
        "launch_mail" => Key::LaunchMail,
        "media_play_pause" => Key::MediaPlayPause,
        "media_select" => Key::MediaSelect,
        "media_stop" => Key::MediaStop,
        "media_track_next" => Key::MediaTrackNext,
        "media_track_previous" => Key::MediaTrackPrevious,
        "power" => Key::Power,
        "sleep" => Key::Sleep,
        "audio_volume_down" => Key::AudioVolumeDown,
        "audio_volume_mute" => Key::AudioVolumeMute,
        "audio_volume_up" => Key::AudioVolumeUp,
        "wake_up" => Key::WakeUp,
        "copy" => Key::Copy,
        "cut" => Key::Cut,
        "paste" => Key::Paste,        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encoder(vt: &mut VtTerminal, bytes: &[u8]) -> InputEncoder {
        vt.vt_write(bytes);
        let mut encoder = InputEncoder::new().unwrap();
        encoder.refresh(vt);
        encoder
    }

    fn key(name: &str) -> KeyInput {
        KeyInput {
            action: KeyAction::Press,
            key: name.into(),
            mods: 0,
            consumed_mods: 0,
            text: None,
            unshifted: 0,
            composing: false,
        }
    }

    const CTRL: u16 = 1 << 1;

    #[test]
    fn keys_follow_the_modes_the_program_set() {
        let mut vt = VtTerminal::new(10, 40).unwrap();
        let mut plain = encoder(&mut vt, b"");
        assert_eq!(plain.key(&key("arrow_up")), b"\x1b[A");
        let mut a = key("a");
        a.text = Some("a".into());
        assert_eq!(plain.key(&a), b"a");
        let mut release = key("a");
        release.action = KeyAction::Release;
        assert!(plain.key(&release).is_empty());
        assert!(plain.key(&key("no_such_key")).is_empty(), "an unknown name sends nothing");

        let mut application = encoder(&mut vt, b"\x1b[?1h");
        assert_eq!(application.key(&key("arrow_up")), b"\x1bOA");

        let mut kitty = encoder(&mut vt, b"\x1b[>1u");
        let mut control_c = key("c");
        control_c.mods = CTRL;
        control_c.unshifted = u32::from('c');
        assert_eq!(kitty.key(&control_c), b"\x1b[99;5u");
    }

    fn at(column: f32, row: f32) -> Pointer {
        Pointer { x: column * 10.0 + 5.0, y: row * 20.0 + 10.0, cell_width: 10, cell_height: 20 }
    }

    fn click(action: MouseAction, column: f32, held: bool) -> MouseInput {
        MouseInput { action, button: Some(1), mods: 0, at: at(column, 2.0), buttons_held: held }
    }

    #[test]
    fn clicks_reach_only_a_program_that_asked_and_only_on_the_grid() {
        let mut vt = VtTerminal::new(10, 40).unwrap();
        let mut none = encoder(&mut vt, b"");
        assert!(none.mouse(&click(MouseAction::Press, 3.0, true)).is_empty());

        let mut sgr = encoder(&mut vt, b"\x1b[?1002h\x1b[?1006h");
        assert_eq!(sgr.mouse(&click(MouseAction::Press, 3.0, true)), b"\x1b[<0;4;3M");
        assert_eq!(sgr.mouse(&click(MouseAction::Release, 3.0, false)), b"\x1b[<0;4;3m");
        assert!(
            sgr.mouse(&click(MouseAction::Press, 45.0, true)).is_empty(),
            "the pane's blank space past column 40 is not the last cell"
        );
    }

    #[test]
    fn the_wheel_goes_where_ghostty_sends_it() {
        let wheel = |rows, columns| WheelInput { rows, columns, mods: 0, at: at(0.0, 0.0) };
        let mut vt = VtTerminal::new(10, 40).unwrap();
        let mut primary = encoder(&mut vt, b"");
        assert!(primary.wheel(&wheel(-2, 0)).is_empty(), "scrollback is the client's");

        let mut alternate = encoder(&mut vt, b"\x1b[?1049h\x1b[?1007h");
        assert_eq!(alternate.wheel(&wheel(-2, 0)), b"\x1b[A\x1b[A");
        // Plain cursor keys, never Kitty key events with no release.
        let mut kitty = encoder(&mut vt, b"\x1b[?1h\x1b[>11u");
        assert_eq!(kitty.wheel(&wheel(1, 0)), b"\x1bOB");

        let mut tracking = encoder(&mut vt, b"\x1b[?1000h\x1b[?1006h");
        assert_eq!(tracking.wheel(&wheel(-1, 0)), b"\x1b[<64;1;1M");
        assert_eq!(tracking.wheel(&wheel(0, 1)), b"\x1b[<67;1;1M", "sideways is buttons six and seven");
        assert_eq!(
            alternate.wheel(&wheel(i32::MAX, 0)).len(),
            3 * WHEEL_LIMIT as usize,
            "one event scrolls at most the limit"
        );
    }

    #[test]
    fn motion_within_one_cell_is_reported_once() {
        let mut vt = VtTerminal::new(10, 40).unwrap();
        let mut any = encoder(&mut vt, b"\x1b[?1003h\x1b[?1006h");
        let moved = |x| MouseInput {
            action: MouseAction::Motion,
            button: None,
            mods: 0,
            at: Pointer { x, y: 10.0, cell_width: 10, cell_height: 20 },
            buttons_held: false,
        };
        assert!(!any.mouse(&moved(12.0)).is_empty());
        assert!(any.mouse(&moved(15.0)).is_empty(), "the same cell again");
        assert!(!any.mouse(&moved(25.0)).is_empty());
        // Output between movements leaves the deduplication alone.
        vt.vt_write(b"x");
        any.refresh(&vt);
        assert!(any.mouse(&moved(26.0)).is_empty(), "still the same cell after output");
    }

    /// The format is the one the program set last, even when it reasserts a
    /// mode that was already on.
    #[test]
    fn the_mouse_format_follows_the_order_modes_were_set() {
        let mut vt = VtTerminal::new(10, 40).unwrap();
        let mut encoder = encoder(&mut vt, b"\x1b[?1000h\x1b[?1015h\x1b[?1006h");
        let click = MouseInput {
            action: MouseAction::Press,
            button: Some(1),
            mods: 0,
            at: Pointer { x: 15.0, y: 10.0, cell_width: 10, cell_height: 20 },
            buttons_held: true,
        };
        assert_eq!(encoder.mouse(&click), b"\x1b[<0;2;1M", "SGR, set last");
        vt.vt_write(b"\x1b[?1015h");
        encoder.refresh(&vt);
        assert_eq!(encoder.mouse(&click), b"\x1b[32;2;1M", "urxvt, set again");
    }

    /// Motion is deduplicated by the cell the report names, which is clamped
    /// to the grid; and SGR set after SGR-Pixels is cells, not pixels.
    #[test]
    fn motion_is_deduplicated_by_the_reported_cell() {
        let mut vt = VtTerminal::new(10, 40).unwrap();
        let mut any = encoder(&mut vt, b"\x1b[?1003h\x1b[?1016h\x1b[?1006h");
        let drag = |x| MouseInput {
            action: MouseAction::Motion,
            button: Some(1),
            mods: 0,
            at: Pointer { x, y: 10.0, cell_width: 10, cell_height: 20 },
            buttons_held: true,
        };
        assert!(!any.mouse(&drag(11.0)).is_empty());
        assert!(any.mouse(&drag(12.0)).is_empty(), "cell SGR won over SGR-Pixels");
        assert!(!any.mouse(&drag(1.0)).is_empty());
        assert!(any.mouse(&drag(-11.0)).is_empty(), "left of the grid is still column one");
        assert!(any.mouse(&drag(-21.0)).is_empty());

        // One row, one column: cell SGR is still told from pixels.
        let mut tiny = VtTerminal::new(1, 1).unwrap();
        let one = encoder(&mut tiny, b"\x1b[?1003h\x1b[?1016h\x1b[?1006h");
        assert!(!one.pixel_reports, "cell SGR on a one-cell grid");
        let pixels = encoder(&mut tiny, b"\x1b[?1006h\x1b[?1016h");
        assert!(pixels.pixel_reports, "SGR-Pixels set last");
    }

    /// Option-L types `@` on a German Mac. It must arrive as `@`, as it does
    /// from a daemon built for macOS, not as Alt-@.
    #[test]
    fn option_composed_text_arrives_as_text() {
        let mut vt = VtTerminal::new(10, 40).unwrap();
        let mut plain = encoder(&mut vt, b"");
        let mut at = key("l");
        at.mods = ALT;
        at.consumed_mods = ALT;
        at.text = Some("@".into());
        at.unshifted = u32::from('l');
        assert_eq!(plain.key(&at), b"@");

        // Under Kitty's event reporting the release matches the press.
        let mut kitty = encoder(&mut vt, b"\x1b[>11u");
        let press = kitty.key(&at);
        let mut release = at.clone();
        release.action = KeyAction::Release;
        release.text = None;
        let released = kitty.key(&release);
        let modifiers = |bytes: &[u8]| String::from_utf8_lossy(bytes).contains(";3");
        assert_eq!(modifiers(&press), modifiers(&released), "{press:?} then {released:?}");
    }

    #[test]
    fn paste_and_focus_follow_their_modes() {
        let mut vt = VtTerminal::new(10, 40).unwrap();
        let plain = encoder(&mut vt, b"");
        assert_eq!(plain.paste("one\ntwo"), b"one\rtwo");
        assert!(plain.focus(true).is_empty());
        let asked = encoder(&mut vt, b"\x1b[?2004h\x1b[?1004h");
        assert_eq!(asked.paste("a\x1b[201~b"), b"\x1b[200~a [201~b\x1b[201~");
        assert_eq!(asked.focus(true), b"\x1b[I");
        assert_eq!(asked.focus(false), b"\x1b[O");
        let pieces = [
            asked.paste_piece("one\n", true, true, false),
            asked.paste_piece("two\n", true, false, false),
            asked.paste_piece("three", true, false, true),
        ]
        .concat();
        assert_eq!(pieces, b"\x1b[200~one\ntwo\nthree\x1b[201~", "one paste in three pieces");
    }
}
