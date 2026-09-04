use termiod_vt::VtTerminal;

/// The user-visible text of a formatted repaint: escapes stripped, one string
/// per screen row (CUP row addressing and \r\n both split rows).
fn visible(bytes: &[u8]) -> Vec<String> {
    let text = String::from_utf8_lossy(bytes);
    let mut out = vec![String::new()];
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.next() {
                Some('[') => {
                    let mut command = None;
                    let mut params = String::new();
                    for e in chars.by_ref() {
                        // Intermediates like the '!' in DECSTR (ESC[!p) are
                        // not the final byte; only an alphabetic ends a CSI.
                        if e.is_ascii_alphabetic() {
                            command = Some(e);
                            break;
                        }
                        params.push(e);
                    }
                    // CUP to a later row starts a new visible row.
                    if command == Some('H') && !params.is_empty() {
                        out.push(String::new());
                    }
                }
                Some(']') => {
                    // OSC: skip to BEL or ST.
                    while let Some(e) = chars.next() {
                        if e == '\u{7}' {
                            break;
                        }
                        if e == '\u{1b}' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                Some('(') | Some(')') => {
                    chars.next();
                }
                _ => {}
            },
            '\n' => out.push(String::new()),
            '\r' | '\u{f}' => {}
            _ => out.last_mut().unwrap().push(c),
        }
    }
    out.into_iter()
        .map(|l| l.trim_end().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

const PROMPT: &str = ">> termio git:(docs/remote-access-after-shipping) x ";

/// zsh's real SIGWINCH redisplay, captured from a live session: carriage
/// return to what zsh believes is the prompt's first physical row (it assumes
/// the terminal did NOT rewrap the old prompt), clear down, reprint.
const ZSH_WINCH_REDRAW: &[u8] = b"\r\r\x1b[0m\x1b[27m\x1b[24m\x1b[J";

#[test]
fn reflowing_resize_duplicates_the_prompt() {
    // The bug this crate's no-reflow resize exists to prevent, kept as the
    // negative control: with reflow on, the engine rewraps the prompt and
    // moves the cursor down a row, zsh's redraw lands one row low, and the
    // stale prompt fragment above survives (issue: ⌘D duplicate prompts).
    let mut vt = VtTerminal::new(24, 63).expect("new");
    vt.vt_write(b"\x1b[?7h");
    vt.vt_write(PROMPT.as_bytes());
    vt.vt_write(b"\x1b[?7h");
    // Reflowing resize, emulated by leaving wraparound on and calling the
    // engine directly through a plain resize with autowrap untouched.
    // (resize() itself now suppresses reflow, so drive the duplicate through
    // the engine's own behaviour: wraparound on is the engine default.)
    let rows = visible(&{
        vt.resize_reflowing(24, 47).expect("resize");
        vt.vt_write(ZSH_WINCH_REDRAW);
        vt.vt_write(PROMPT.as_bytes());
        vt.format_vt().expect("fmt")
    });
    let copies = rows
        .iter()
        .filter(|row| row.starts_with(">> termio git:("))
        .count();
    assert!(copies >= 2, "expected the duplicate, got rows: {rows:?}");
}

#[test]
fn no_reflow_resize_keeps_zsh_redraw_clean() {
    let mut vt = VtTerminal::new(24, 63).expect("new");
    vt.vt_write(PROMPT.as_bytes());
    vt.resize(24, 47).expect("resize");
    vt.vt_write(ZSH_WINCH_REDRAW);
    vt.vt_write(PROMPT.as_bytes());
    let rows = visible(&vt.format_vt().expect("fmt"));
    assert_eq!(
        rows,
        vec![
            ">> termio git:(docs/remote-access-after-shippin".to_string(),
            "g) x".to_string(),
        ],
        "one prompt, wrapped at the new width, nothing stale above it"
    );
}

#[test]
fn no_reflow_resize_survives_a_split_storm() {
    // Three consecutive splits, zsh redrawing after each — the exact ⌘D
    // sequence from the report. Every intermediate screen must hold exactly
    // one prompt.
    let mut vt = VtTerminal::new(24, 95).expect("new");
    vt.vt_write(PROMPT.as_bytes());
    for (cols, ups) in [(63u16, 0usize), (47, 0), (38, 1)] {
        vt.resize(24, cols).expect("resize");
        vt.vt_write(b"\r");
        // zsh moves up (old prompt rows - 1) rows; emulate its bookkeeping.
        for _ in 0..ups {
            vt.vt_write(b"\x1b[A");
        }
        vt.vt_write(b"\r\x1b[0m\x1b[27m\x1b[24m\x1b[J");
        vt.vt_write(PROMPT.as_bytes());
        let rows = visible(&vt.format_vt().expect("fmt"));
        let copies = rows
            .iter()
            .filter(|row| row.contains(">> termio git:("))
            .count();
        assert_eq!(copies, 1, "at {cols} cols expected one prompt, rows: {rows:?}");
    }
}

#[test]
fn no_reflow_resize_leaves_program_autowrap_choice_alone() {
    // A program that turned autowrap off keeps it off across a resize; one
    // that left it on gets it back.
    // With autowrap off a 60-char write from home pins the cursor to row 0;
    // with it on, the write wraps and the cursor ends on row 1. The cursor
    // row comes from the snapshot, so no formatter encoding is involved.
    let mut vt = VtTerminal::new(24, 80).expect("new");
    vt.vt_write(b"\x1b[?7l");
    vt.resize(24, 40).expect("resize");
    vt.vt_write(b"\x1b[H");
    vt.vt_write("X".repeat(60).as_bytes());
    let snapshot = vt.snapshot().expect("snapshot");
    assert_eq!(snapshot.cursor_y, 0, "autowrap must stay off");

    let mut vt = VtTerminal::new(24, 80).expect("new");
    vt.resize(24, 40).expect("resize");
    vt.vt_write(b"\x1b[H");
    vt.vt_write("X".repeat(60).as_bytes());
    let snapshot = vt.snapshot().expect("snapshot");
    assert_eq!(snapshot.cursor_y, 1, "autowrap must come back on");
}


/// What the no-reflow policy costs on the way *out*: a line the program wrapped
/// at the old width stays broken where it was broken, so widening the window
/// leaves a word split across two rows and the second row starting mid-word.
///
/// This is the tmux/xterm behaviour the policy above is chosen for, seen from
/// the other side — recorded here because it is what a user reports as "the
/// screen is 错位 after I drag the window", and because any future reflow work
/// has to move this assertion rather than discover it.
#[test]
fn widening_does_not_re_join_a_wrapped_line() {
    let mut vt = VtTerminal::new(6, 20).unwrap();
    // 26 columns of text in a 20-column terminal: the program's own autowrap
    // breaks it after "image in clipboar".
    vt.vt_write(b"image in clipboard ok");
    let before = visible(&vt.format_vt().unwrap());
    assert_eq!(before, vec!["image in clipboard o", "k"], "wrapped by the program");

    vt.resize(6, 40).unwrap();
    let after = visible(&vt.format_vt().unwrap());
    assert_eq!(
        after,
        vec!["image in clipboard o", "k"],
        "the break survives the widening — the rows are not re-joined"
    );
}

/// The prompt-start mark termiod's zsh integration carries at the head of
/// `PS1` (invisible to zsh's width math via `%{ %}`), as the engine receives
/// it: every prompt reprint re-marks its first row.
const MARK_PROMPT_START: &[u8] = b"\x1b]133;A\x07";

/// A marked shell gets Ghostty.app's resize: the prompt is blanked before the
/// reflow, so zsh's old-width redraw lands on clean rows — one prompt, never
/// two — while the content above rewraps to the new width.
#[test]
fn marked_prompt_resize_reflows_without_duplicating() {
    let mut vt = VtTerminal::new(24, 63).expect("new");
    vt.vt_write(b"image in clipboard, saved to /tmp/screenshot-2026.png ok\r\n");
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(PROMPT.as_bytes());
    vt.resize_for_shell(24, 47).expect("resize");
    // zsh's redraw reprints PS1, which carries the mark — so the fresh prompt
    // row is marked again and the *next* resize can also reflow.
    vt.vt_write(ZSH_WINCH_REDRAW);
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(PROMPT.as_bytes());
    let rows = visible(&vt.format_vt().expect("fmt"));
    let copies = rows
        .iter()
        .filter(|row| row.contains(">> termio git:("))
        .count();
    assert_eq!(copies, 1, "one prompt after a marked resize, rows: {rows:?}");
}

/// The user-visible half of the fix: text a narrow screen wrapped is re-joined
/// when the window widens again, instead of staying broken (or, before this,
/// being truncated outright on the way down).
#[test]
fn marked_widening_re_joins_a_wrapped_line() {
    let mut vt = VtTerminal::new(6, 20).expect("new");
    vt.vt_write(b"image in clipboard ok\r\n");
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(b"> ");
    vt.resize_for_shell(6, 40).expect("resize");
    vt.vt_write(b"\r\x1b[0m\x1b[27m\x1b[24m\x1b[J");
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(b"> ");
    let rows = visible(&vt.format_vt().expect("fmt"));
    assert_eq!(
        rows,
        vec!["image in clipboard ok".to_string(), ">".to_string()],
        "the wrapped line is re-joined at the new width"
    );
}

/// Narrowing with marks keeps the tails: the long line rewraps onto two rows
/// instead of losing everything past the new width — the `ls` truncation
/// report this exists for.
#[test]
fn marked_narrowing_rewraps_instead_of_truncating() {
    let mut vt = VtTerminal::new(24, 40).expect("new");
    vt.vt_write(b"OakReader-pre-restore-2026-05-17T23-17\r\n");
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(b"> ");
    vt.resize_for_shell(24, 30).expect("resize");
    vt.vt_write(b"\r\x1b[0m\x1b[27m\x1b[24m\x1b[J");
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(b"> ");
    let rows = visible(&vt.format_vt().expect("fmt"));
    assert_eq!(
        rows,
        vec![
            "OakReader-pre-restore-2026-05-".to_string(),
            "17T23-17".to_string(),
            ">".to_string(),
        ],
        "the tail survives on a wrapped second row"
    );
}

/// Without marks, `resize_for_shell` must be indistinguishable from the
/// truncating `resize`: a shell nobody instrumented still redraws against the
/// old wrap points, and reflowing under it recreates the duplicate.
#[test]
fn unmarked_resize_for_shell_still_truncates() {
    let mut vt = VtTerminal::new(24, 63).expect("new");
    vt.vt_write(PROMPT.as_bytes());
    vt.resize_for_shell(24, 47).expect("resize");
    vt.vt_write(ZSH_WINCH_REDRAW);
    vt.vt_write(PROMPT.as_bytes());
    let rows = visible(&vt.format_vt().expect("fmt"));
    assert_eq!(
        rows,
        vec![
            ">> termio git:(docs/remote-access-after-shippin".to_string(),
            "g) x".to_string(),
        ],
        "no marks, no reflow: same screen as the truncating resize"
    );
}

/// An earlier prompt stacked directly above the current one (enter pressed at
/// an empty prompt) is history nobody will redraw: the clear must stop at the
/// current prompt's own first row and leave the one above as text.
#[test]
fn clearing_stops_at_the_current_prompt() {
    let mut vt = VtTerminal::new(24, 63).expect("new");
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(b"> old\r\n");
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(b"> ");
    vt.resize_for_shell(24, 47).expect("resize");
    vt.vt_write(b"\r\x1b[0m\x1b[27m\x1b[24m\x1b[J");
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(b"> ");
    let rows = visible(&vt.format_vt().expect("fmt"));
    assert_eq!(
        rows,
        vec!["> old".to_string(), ">".to_string()],
        "the earlier prompt's row survives the resize"
    );
}

/// The ⌘D split storm again, marked this time: three consecutive narrowings,
/// zsh redrawing after each. Once the prompt no longer fits the width it
/// wraps, so the cursor sits on a *continuation* row and the clear has to
/// ascend to the prompt's first row before it erases — the walk this test
/// pins down. Every intermediate screen must hold exactly one prompt.
#[test]
fn marked_resize_survives_a_split_storm() {
    let mut vt = VtTerminal::new(24, 95).expect("new");
    vt.vt_write(MARK_PROMPT_START);
    vt.vt_write(PROMPT.as_bytes());
    for (cols, ups) in [(63u16, 0usize), (47, 0), (38, 1)] {
        vt.resize_for_shell(24, cols).expect("resize");
        vt.vt_write(b"\r");
        // zsh moves up (prompt rows at the drawn width - 1); emulate it.
        for _ in 0..ups {
            vt.vt_write(b"\x1b[A");
        }
        vt.vt_write(b"\r\x1b[0m\x1b[27m\x1b[24m\x1b[J");
        vt.vt_write(MARK_PROMPT_START);
        vt.vt_write(PROMPT.as_bytes());
        let rows = visible(&vt.format_vt().expect("fmt"));
        let copies = rows
            .iter()
            .filter(|row| row.contains(">> termio git:("))
            .count();
        assert_eq!(copies, 1, "at {cols} cols expected one prompt, rows: {rows:?}");
    }
}

/// The other half of the rule: with a job on screen rather than the shell, the
/// same widening re-joins the line, which is what every terminal the program was
/// written for does and what the user is comparing against.
#[test]
fn widening_with_reflow_re_joins_a_wrapped_line() {
    let mut vt = VtTerminal::new(6, 20).unwrap();
    vt.vt_write(b"image in clipboard ok");
    vt.resize_reflowing(6, 40).unwrap();
    assert_eq!(
        visible(&vt.format_vt().unwrap()),
        vec!["image in clipboard ok"],
        "the rows are re-joined at the new width"
    );
}
