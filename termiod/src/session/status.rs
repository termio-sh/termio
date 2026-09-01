//! The agent status engine, beside the sidecar VT.
//!
//! Ported from the Mac app's `TermioStore+AgentStatus.swift` and its two
//! helpers, for the reason `docs/design/20260831-companion-second-protocol-retires.md`
//! §3 gives: the rules are not functions of the byte stream alone. They read a
//! rendered screen, this client's keystrokes, this client's tick history and
//! this client's selection — so two viewers running them independently disagree
//! by construction, and a phone attached straight to a device runs none of them
//! at all.
//!
//! What moved is every rule that decides a state. What did **not** move is
//! every rule that decides how a state *looks*: the tooltip sentence, the
//! done-versus-idle arbitration a viewer makes from its own selection, and
//! argv → glyph. Those stay client-side (§3.3), which is why this module emits
//! an enum and a source and never a sentence.
//!
//! Everything here is a plain value with no session, no PTY and no VT, so the
//! promotion rules and the stall verdict are testable as arithmetic — which is
//! how the Swift cases came across.

use std::time::{Duration, Instant};

use regex::{Regex, RegexBuilder};

use crate::agent::manifest::StatusRules;

// ---------------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------------

/// What one signal says about a session, before arbitration. The three the
/// screen, the title and the progress channel can each reach.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Activity {
    Working,
    Attention,
    Idle,
}

/// Which channel produced a status. The client needs this to apply the one
/// arbitration that is genuinely its own: a turn that ended reads `done` on a
/// row nobody is looking at and `idle` on the one they are — but only when the
/// signal was derived here. A hook that says `done` means `done` on every
/// client, which is what it meant before this engine existed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StatusSource {
    /// `termio agent report` — the agent's own words.
    Hook,
    /// The agent's live `OSC 0/2` title.
    Title,
    /// ConEmu-style `OSC 9;4` progress.
    Progress,
    /// The agent's declared screen regex rules.
    Screen,
    /// The screen-streak promotion, or the stale-working sweep that undoes it.
    Screen0Streak,
}

impl StatusSource {
    pub fn as_str(self) -> &'static str {
        match self {
            StatusSource::Hook => "hook",
            StatusSource::Title => "title",
            StatusSource::Progress => "progress",
            StatusSource::Screen => "screen",
            StatusSource::Screen0Streak => "streak",
        }
    }

    /// Whether a `done` from this source is the device's own conclusion, which
    /// the viewer then judges against its selection. A hook's is not.
    pub fn is_derived(self) -> bool {
        !matches!(self, StatusSource::Hook)
    }
}

/// The protocol states this engine can reach. `failed` is hook-only — nothing
/// observable from outside an agent distinguishes a failed turn from a quiet
/// one — so it is not in this enum and passes through as a hook report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Working,
    NeedsYou,
    Idle,
    Done,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Working => "working",
            State::NeedsYou => "needs_you",
            State::Idle => "idle",
            State::Done => "done",
        }
    }
}

// ---------------------------------------------------------------------------
// Compiled rules
// ---------------------------------------------------------------------------

/// A manifest's regex lists, compiled. Whole-screen match, precedence
/// `attention > working > idle` — the herdr shape, kept deliberately small: no
/// regions, no priorities, no remote manifests.
///
/// The engine is `regex`, not ICU, and that is a narrowed accepted language:
/// no backreferences and no lookaround. Every pattern termio ships is inside
/// the intersection (asserted by `bundled_status_patterns_compile`), and a
/// user's own pattern that is not compiles to nothing and is dropped with a log
/// — which is exactly what Swift's `NSRegularExpression` path already did with
/// an invalid one.
#[derive(Debug, Clone)]
pub struct RuleSet {
    working: Vec<Regex>,
    attention: Vec<Regex>,
}

impl RuleSet {
    /// Compile a manifest's raw patterns, dropping (with a log) any the engine
    /// will not take, so one typo cannot sink an agent. `None` when nothing
    /// usable is declared, which leaves the agent on its other channels.
    pub fn compile(rules: &StatusRules, label: &str) -> Option<RuleSet> {
        let working = compile_all(&rules.working, label);
        let attention = compile_all(&rules.attention, label);
        if working.is_empty() && attention.is_empty() {
            return None;
        }
        Some(RuleSet { working, attention })
    }

    /// The activity a screen reads as, plus the pattern that decided it — the
    /// analogue of `herdr agent explain`, and the same pair the Swift
    /// `explain` returned.
    pub fn explain<'a>(&'a self, screen: &str) -> (Activity, Option<&'a str>) {
        if let Some(hit) = self.attention.iter().find(|rule| rule.is_match(screen)) {
            return (Activity::Attention, Some(hit.as_str()));
        }
        if let Some(hit) = self.working.iter().find(|rule| rule.is_match(screen)) {
            return (Activity::Working, Some(hit.as_str()));
        }
        (Activity::Idle, None)
    }

    pub fn classify(&self, screen: &str) -> Activity {
        self.explain(screen).0
    }
}

fn compile_all(patterns: &[String], label: &str) -> Vec<Regex> {
    patterns
        .iter()
        .filter_map(|pattern| match compile_one(pattern) {
            Ok(compiled) => Some(compiled),
            Err(error) => {
                eprintln!("termiod: {label}: ignoring status pattern /{pattern}/: {error}");
                None
            }
        })
        .collect()
}

/// Case-insensitive, multi-line off — the same two options Swift compiled with,
/// so `^` anchors a screen and not a row. A spinner rule that means "first
/// column of the title" stays a title rule.
fn compile_one(pattern: &str) -> Result<Regex, regex::Error> {
    RegexBuilder::new(pattern).case_insensitive(true).build()
}

// ---------------------------------------------------------------------------
// OSC scanning
// ---------------------------------------------------------------------------

/// What an OSC in the byte stream said, when it said something this engine
/// reads. Everything else falls through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OscSignal {
    /// `OSC 0` / `OSC 2` — the window title. Every frame of a ticking spinner
    /// arrives here, which is the point: the transition guard collapses the
    /// repeats and the liveness clock is refreshed by each one.
    Title(String),
    /// `OSC 9;4` progress, classified to busy/idle.
    Progress(Activity),
}

/// Parses the two in-band status channels out of a raw PTY chunk: the `OSC 0/2`
/// title, and ConEmu-style `OSC 9;4` progress.
///
/// `ESC ] 9 ; 4 ; <state> ; <progress> (BEL | ST)` — state `0` = clear → idle,
/// `1`/`3` (normal/indeterminate) → working, `2`/`4` (error/paused) ignored.
/// Grok emits `9;4;1;-1` while a turn runs and `9;4;0;` when it ends.
///
/// It keeps parse state across chunks — a sequence split by a `read()` boundary
/// reassembles — but it does **not** dedup: every completed report is returned,
/// including a run of identical keepalives. The arbiter is where duplicates
/// collapse (`note_progress`, on `last_progress_activity`), and it refreshes the
/// liveness clock *before* that guard, so a keepalive is still evidence a turn
/// is running even when it moves nothing. A scanner that deduped privately would
/// swallow the keepalives a row promoted to a progress-emitting agent mid-stream
/// needs, because its first `working` was rejected by the live-agent gate.
#[derive(Default)]
pub struct OscScanner {
    state: ScanState,
    payload: Vec<u8>,
    /// Set when a payload outgrows `MAX_PAYLOAD`: too long to be a progress
    /// report or a title worth carrying, so it is rejected outright rather than
    /// classified from its prefix.
    overflowed: bool,
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum ScanState {
    #[default]
    Ground,
    Esc,
    Osc,
    OscEsc,
}

impl OscScanner {
    /// Titles are the long payload here; a progress report is a handful of
    /// bytes. Past this an OSC is some other, longer sequence and is dropped.
    const MAX_PAYLOAD: usize = 1024;

    /// Scan a raw chunk, returning every signal in it in byte order.
    pub fn scan(&mut self, data: &[u8]) -> Vec<OscSignal> {
        let mut signals = Vec::new();
        for byte in data {
            match self.state {
                ScanState::Ground => {
                    if *byte == 0x1B {
                        self.state = ScanState::Esc;
                    }
                }
                ScanState::Esc => {
                    if *byte == b']' {
                        self.begin_payload();
                    } else if *byte == 0x1B {
                        self.state = ScanState::Esc;
                    } else {
                        self.state = ScanState::Ground;
                    }
                }
                ScanState::Osc => match byte {
                    0x07 => {
                        self.emit(&mut signals);
                        self.state = ScanState::Ground;
                    }
                    0x1B => self.state = ScanState::OscEsc,
                    _ => {
                        if self.payload.len() < Self::MAX_PAYLOAD {
                            self.payload.push(*byte);
                        } else {
                            self.overflowed = true;
                        }
                    }
                },
                ScanState::OscEsc => {
                    if *byte == b'\\' {
                        self.emit(&mut signals);
                        self.state = ScanState::Ground;
                    } else if *byte == 0x1B {
                        self.state = ScanState::OscEsc;
                    } else {
                        // A bare ESC mid-payload aborts this OSC.
                        self.state = ScanState::Ground;
                    }
                }
            }
        }
        signals
    }

    fn begin_payload(&mut self) {
        self.state = ScanState::Osc;
        self.payload.clear();
        self.overflowed = false;
    }

    fn emit(&mut self, signals: &mut Vec<OscSignal>) {
        let overflowed = self.overflowed;
        self.overflowed = false;
        if !overflowed {
            if let Some(activity) = classify_progress(&self.payload) {
                signals.push(OscSignal::Progress(activity));
            } else if let Some(title) = read_title(&self.payload) {
                signals.push(OscSignal::Title(title));
            }
        }
        self.payload.clear();
    }
}

/// `OSC 0;<text>` (icon + title) and `OSC 2;<text>` (title) both set the title
/// termio reads. `OSC 1` is the icon name alone and is not a title.
fn read_title(payload: &[u8]) -> Option<String> {
    let (number, rest) = payload.split_at(payload.iter().position(|byte| *byte == b';')?);
    if number != b"0" && number != b"2" {
        return None;
    }
    Some(String::from_utf8_lossy(&rest[1..]).into_owned())
}

/// Maps an OSC 9 payload to an activity. Fast-rejects everything that is not a
/// `9;4;<state>` progress report before allocating, so the common title spinner
/// — one OSC per frame — never pays for a `String`, then validates the whole
/// grammar so a longer OSC 9 notification beginning `4;…` is not misread.
pub fn classify_progress(payload: &[u8]) -> Option<Activity> {
    if payload.len() < 3 || payload[0] != b'9' || payload[1] != b';' || payload[2] != b'4' {
        return None;
    }
    let text = std::str::from_utf8(payload).ok()?;
    let parts: Vec<&str> = text.split(';').collect();
    // `9 ; 4 ; <state>` with an optional trailing `<progress>` — nothing more.
    // The byte prefix pinned `parts[0] == "9"`, but `4` may have been a longer
    // run (`9;41;…`), so the second field is re-checked exactly.
    if (parts.len() != 3 && parts.len() != 4) || parts[1] != "4" {
        return None;
    }
    match parts[2].parse::<i32>().ok()? {
        0 => Some(Activity::Idle), // clear; any progress value is ignored
        1 | 3 => {
            // Busy states carry a progress field: a percentage (`0…100`),
            // Grok's indeterminate `-1`, or empty. A missing field, a stray
            // value or an out-of-range number means this was not a report.
            let progress = parts.get(3)?;
            if progress.is_empty() {
                return Some(Activity::Working);
            }
            let value = progress.parse::<i32>().ok()?;
            (value == -1 || (0..=100).contains(&value)).then_some(Activity::Working)
        }
        // 2 = error, 4 = paused — not a clean transition.
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Thresholds
// ---------------------------------------------------------------------------

/// How long a working session may go with no screen change and no working hook
/// before the sweep flips it back to idle. A working agent's TUI repaints
/// changing content sub-second, so this only elapses once the screen has
/// genuinely gone static — recovering the many turns that end without a `Stop`
/// hook (a cancelled `/resume`, an esc-interrupt, a hook that never
/// correlated) instead of spinning forever.
pub const STALE_WORKING_TIMEOUT: Duration = Duration::from_secs(12);
/// No promotion this soon after launch: an agent's banner and first prompt
/// paint across several ticks while it is simply starting up.
pub const LAUNCH_GRACE: Duration = Duration::from_secs(10);
/// How long after input the screen must settle before promotion; typing a long
/// prompt repaints the input box on every keystroke.
pub const USER_INPUT_QUIET: Duration = Duration::from_secs(3);
/// Hooks are trusted for this long after their last report before the screen
/// may promote a session on its own. Just above `STALE_WORKING_TIMEOUT`, so a
/// live turn the sweep mistakenly cleared becomes recoverable the moment it
/// repaints, while the repaint burst right after a `Stop` hook — the final
/// answer rendering — can never re-light the spinner.
pub const HOOK_QUIET: Duration = Duration::from_secs(15);
/// PTY bytes in one tick that read as genuine streaming for the *sustain* path:
/// enough to keep a working session alive while a viewer has scrolled away from
/// the live tail, yet above the trickle an idle prompt emits (a cursor park, a
/// redraw) so a finished turn still goes static and gets swept.
pub const STREAMING_BYTE_FLOOR: u64 = 512;
/// Consecutive changed ticks that promote `idle` back to `working`.
pub const PROMOTION_STREAK: u32 = 2;

/// How long a session must be continuously working with no progress marker
/// before it reads as stalled — probe 1's window, and the span every other
/// probe compares across.
pub fn stall_window() -> Duration {
    Duration::from_secs_f64(threshold("TERMIOD_STALL_WINDOW_SECONDS", 20.0 * 60.0))
}

/// Transcript lines the window must add to count as progress (probe 3's K).
pub fn stall_transcript_line_floor() -> usize {
    threshold("TERMIOD_STALL_TRANSCRIPT_LINES", 5.0) as usize
}

/// The average PTY output rate (bytes/second across the window) at or above
/// which probe 4 suppresses the alert: the agent is visibly producing.
/// Calibrated against measured Claude Code rates (2026-07) — parked on a
/// spinner ~1.4 KB/s, a tool call ~1.1 KB/s, streaming text ~1.5 KB/s, while
/// full-screen scrolls run tens of KB/s. The default sits above every measured
/// idle mode.
pub fn stall_stream_byte_rate() -> f64 {
    threshold("TERMIOD_STALL_STREAM_BYTES_PER_SECOND", 4096.0)
}

/// How often the expensive probes may re-run once a window has elapsed. Scaled
/// with the window so a shortened testing window still probes promptly.
pub fn stall_probe_interval() -> Duration {
    Duration::from_secs_f64((stall_window().as_secs_f64() / 40.0).max(2.0))
}

/// Testing-only override, so live verification does not take twenty minutes.
/// Deliberately an environment variable and not a setting: the Swift side read
/// a `defaults` key of the same name, which a daemon has no equivalent for.
fn threshold(key: &str, fallback: f64) -> f64 {
    std::env::var(key)
        .ok()
        .and_then(|raw| raw.parse::<f64>().ok())
        .filter(|value| *value > 0.0)
        .unwrap_or(fallback)
}

// ---------------------------------------------------------------------------
// Stall detection (device architecture §4.7)
// ---------------------------------------------------------------------------

/// One off-main reading of a session's progress evidence: the repo fingerprint
/// plus the transcript's current extent.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StallMeasurement {
    pub repo_fingerprint: String,
    pub transcript_path: Option<String>,
    pub transcript_lines: usize,
    pub transcript_size: u64,
}

/// What the window's probes compare against, captured just after `window_start`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StallBaseline {
    /// The directory fingerprinted at capture, reused for the whole window so
    /// an agent `cd`-ing between repos cannot masquerade as repo progress.
    pub directory: Option<String>,
    pub repo_fingerprint: String,
    pub transcript_path: Option<String>,
    pub transcript_lines: usize,
    pub transcript_size: u64,
}

impl StallBaseline {
    pub fn new(directory: Option<String>, measured: &StallMeasurement) -> StallBaseline {
        StallBaseline {
            directory,
            repo_fingerprint: measured.repo_fingerprint.clone(),
            transcript_path: measured.transcript_path.clone(),
            transcript_lines: measured.transcript_lines,
            transcript_size: measured.transcript_size,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Assessment {
    /// A progress marker landed — the window slid forward and re-armed.
    Progress,
    /// Every probe agrees: emit the one `stalled` event.
    Stalled { transcript_lines_grown: usize },
    /// No progress, but the alert already fired — keep holding.
    Hold,
}

/// Per-session state for loop-level stall detection. One value exists per
/// continuously-working session, created on the `working` transition and
/// dropped on the way out. The window slides forward on every progress marker;
/// `alerted` is the edge-trigger latch — one `stalled` event per quiet window,
/// re-armed only by progress.
#[derive(Debug, Clone)]
pub struct StallProbe {
    /// When the session entered `working` — probe 1's clock, and the duration
    /// the evidence string reports.
    pub working_since: Instant,
    /// Start of the current no-progress window; slides to "now" on any progress.
    pub window_start: Instant,
    /// PTY output bytes seen since `window_start` — probe 4's numerator.
    /// Volume, not tick counting: an idle agent's spinner repaints on every
    /// tick too, so only the byte *rate* separates "parked on a spinner" from
    /// "build logs scrolling through the TUI".
    pub streamed_bytes: u64,
    pub baseline: Option<StallBaseline>,
    /// A measurement is in flight; the sweep must not stack another.
    pub measuring: bool,
    /// Ties an in-flight measurement back to this exact probe, so a result
    /// landing after the session left and re-entered `working` is discarded
    /// instead of judged against the wrong window.
    pub generation: u64,
    pub last_probe_at: Option<Instant>,
    pub alerted: bool,
}

impl StallProbe {
    pub fn new(now: Instant, generation: u64) -> StallProbe {
        StallProbe {
            working_since: now,
            window_start: now,
            streamed_bytes: 0,
            baseline: None,
            measuring: false,
            generation,
            last_probe_at: None,
            alerted: false,
        }
    }

    /// Whether probe 4 suppresses the alert: the window's average output rate
    /// says the agent is visibly producing.
    pub fn is_stream_suppressed(&self, now: Instant, bytes_per_second: f64) -> bool {
        let elapsed = now.saturating_duration_since(self.window_start).as_secs_f64();
        if elapsed <= 0.0 {
            return false;
        }
        self.streamed_bytes as f64 >= elapsed * bytes_per_second
    }

    /// Judge a fresh measurement against the baseline (probes 2 and 3) and
    /// apply the verdict: progress slides the window and re-arms; the first
    /// all-probes-agree verdict latches `alerted` so the event fires once.
    pub fn assess(
        &mut self,
        measured: &StallMeasurement,
        now: Instant,
        transcript_line_floor: usize,
    ) -> Assessment {
        let Some(baseline) = self.baseline.clone() else {
            return Assessment::Hold;
        };
        let lines_grown = measured
            .transcript_lines
            .saturating_sub(baseline.transcript_lines);
        if measured.repo_fingerprint != baseline.repo_fingerprint
            || lines_grown >= transcript_line_floor
        {
            let slid = StallBaseline::new(baseline.directory.clone(), measured);
            self.slide_window(now, Some(slid));
            return Assessment::Progress;
        }
        if self.alerted {
            return Assessment::Hold;
        }
        self.alerted = true;
        Assessment::Stalled {
            transcript_lines_grown: lines_grown,
        }
    }

    /// Restart the no-progress window at `now` and re-arm the alert. A `None`
    /// baseline makes the next sweep tick capture a fresh one.
    pub fn slide_window(&mut self, now: Instant, baseline: Option<StallBaseline>) {
        self.window_start = now;
        self.streamed_bytes = 0;
        self.baseline = baseline;
        self.alerted = false;
    }
}

// ---------------------------------------------------------------------------
// Arbitration
// ---------------------------------------------------------------------------

/// What the engine decided a session should now read as, and why. `None` from
/// every `note_*` means nothing changed and no client needs telling.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusChange {
    pub state: State,
    pub source: StatusSource,
    /// Set when this change is the device concluding a turn ended. A client
    /// turns it into `done` on a row it is not looking at and `idle` on the one
    /// it is — the one arbitration §3.3 keeps client-side.
    pub turn_ended: bool,
}

/// Everything the arbiter needs to know about a session that is not a signal:
/// what it is running, and whether it is running at all.
#[derive(Debug, Clone, Default)]
pub struct SessionFacts {
    /// The resolved agent, or `None` for a plain shell. A shell is never
    /// promoted and never classified — a `wget` progress bar is not a turn.
    pub agent_id: Option<String>,
    /// The agent's screen rules, when it declared any. Their presence is also
    /// what stands the streak promotion down: an agent whose screen already
    /// owns its status must not be guessed over.
    pub screen_rules: Option<RuleSet>,
    /// The agent's title rules. Unlike the screen rules these coexist with
    /// hooks — the title is a correction channel on a wire that cannot break.
    pub title_rules: Option<RuleSet>,
    /// Whether this agent emits `OSC 9;4` at all. Gates the progress channel so
    /// an unrelated shell's `npm` bar cannot move a dot.
    pub emits_progress: bool,
}

impl SessionFacts {
    fn is_agent(&self) -> bool {
        self.agent_id.is_some()
    }
}

/// One session's live status state. Everything the Swift store held in eight
/// parallel dictionaries keyed by session id, gathered into the value they were
/// always describing — which is also why the teardown path here cannot drift
/// out of step the way `clearActivityTracking` had to be kept in step by hand.
#[derive(Debug, Clone)]
struct SessionStatus {
    state: State,
    /// Set by a hook `failed` or by anything else the daemon passes through
    /// untouched. While present the engine's derived channels stand down: it is
    /// a state this engine cannot reason about.
    opaque: Option<String>,
    launched_at: Instant,
    last_working_at: Option<Instant>,
    last_hook_report_at: Option<Instant>,
    last_user_input_at: Option<Instant>,
    promotion_streak: u32,
    last_title_activity: Option<Activity>,
    last_progress_activity: Option<Activity>,
    last_screen_activity: Option<Activity>,
    stall: Option<StallProbe>,
    /// Raised by a hook / screen / title "attention" signal. Unlike a one-shot
    /// bell these have a matching resolved transition, so the flag survives a
    /// client looking at the row — reading a permission prompt is not answering
    /// it. Clients read it to decide whether their own selection clears the dot.
    blocking_attention: bool,
}

impl SessionStatus {
    fn new(now: Instant) -> SessionStatus {
        SessionStatus {
            state: State::Idle,
            opaque: None,
            launched_at: now,
            last_working_at: None,
            last_hook_report_at: None,
            last_user_input_at: None,
            promotion_streak: 0,
            last_title_activity: None,
            last_progress_activity: None,
            last_screen_activity: None,
            stall: None,
            blocking_attention: false,
        }
    }

    /// The single place a turn stops. The hook path and every derived channel
    /// end a turn through this door, so the two cannot drift on what "stopped
    /// working" clears.
    fn clear_working(&mut self) {
        self.last_working_at = None;
        self.promotion_streak = 0;
    }
}

/// The arbiter. One per session actor; holds no VT, no PTY and no client.
///
/// Every method returns `Option<StatusChange>` and mutates only this value, so
/// the precedence rules — hooks senior, attention above working, a derived
/// idle only ever *ending* a turn — are readable in one file and testable
/// without a daemon.
pub struct StatusEngine {
    session: SessionStatus,
    facts: SessionFacts,
    next_generation: u64,
}

impl StatusEngine {
    pub fn new(now: Instant, facts: SessionFacts) -> StatusEngine {
        StatusEngine {
            session: SessionStatus::new(now),
            facts,
            next_generation: 1,
        }
    }

    /// Adopt a status this actor did not derive — the one a session was created
    /// with, or the one it carried across a handoff. Without this the engine
    /// would start every adopted session at `idle` while `SessionInfo` still
    /// said `working`, and the two would only agree again on the next
    /// transition.
    ///
    /// `clocks` is what an `execve` handoff carries so the adopted session keeps
    /// its *place* in both timers, not just its state. Absent — a fresh session,
    /// or a blob from a daemon that predates the field — the clocks start now,
    /// which is right for a session that has no history to keep.
    ///
    /// Deliberately silent: nothing changed for a client, so nothing is emitted.
    pub fn seed(&mut self, status: &str, clocks: Option<&CarriedClocks>, now: Instant) {
        match status {
            "working" => {
                self.session.state = State::Working;
                self.session.last_working_at = Some(now);
                self.begin_stall_watch(now);
            }
            "needs_you" => {
                self.session.state = State::NeedsYou;
                self.session.blocking_attention = true;
            }
            "done" => self.session.state = State::Done,
            "idle" => self.session.state = State::Idle,
            // `unknown` is the daemon's own default for a session nobody has
            // reported on, and is not a state to adopt.
            "unknown" | "" => {}
            other => {
                self.session.state = State::Idle;
                self.session.opaque = Some(other.to_string());
            }
        }
        if let Some(clocks) = clocks {
            self.restore_clocks(clocks, now);
        }
    }

    /// Re-anchor the carried clocks against this process's `now`.
    ///
    /// Everything crosses as an *elapsed* duration rather than an instant:
    /// `Instant` has no serialisable form, and the value that matters is "how
    /// long has this been true", which survives an exec and a clock the far
    /// side cannot name. Without this, every handoff restarted both timers —
    /// so a box upgrading its daemon on a timer could defer stale-working
    /// cleanup, and the stall signal, indefinitely.
    fn restore_clocks(&mut self, clocks: &CarriedClocks, now: Instant) {
        if let Some(quiet) = clocks.working_quiet_seconds {
            self.session.last_working_at =
                Some(now.checked_sub(Duration::from_secs(quiet)).unwrap_or(now));
        }
        self.session.blocking_attention = clocks.blocking_attention;
        let Some(stall) = clocks.stall.as_ref() else {
            // Not working, or working with no window open. Either way there is
            // no window to keep, and `begin_stall_watch` will open one when the
            // next turn starts.
            if self.session.state != State::Working {
                self.session.stall = None;
            }
            return;
        };
        let Some(probe) = self.session.stall.as_mut() else {
            return;
        };
        probe.working_since = now
            .checked_sub(Duration::from_secs(stall.working_for_seconds))
            .unwrap_or(now);
        probe.window_start = now
            .checked_sub(Duration::from_secs(stall.window_for_seconds))
            .unwrap_or(now);
        probe.streamed_bytes = stall.streamed_bytes;
        probe.alerted = stall.alerted;
        // The baseline deliberately does *not* cross. It describes a repo and a
        // transcript as they were before the exec, and this process cannot
        // vouch for either across the gap — so the next sweep re-captures
        // against the world as of now. `window_start` is what carries the
        // elapsed time, and a capture does not move it, so an already-elapsed
        // window still probes on its next tick.
    }

    /// What this session's clocks are worth carrying across an `execve`, or
    /// `None` when there is nothing running to keep time for.
    pub fn carried_clocks(&self, now: Instant) -> Option<CarriedClocks> {
        let quiet = self
            .session
            .last_working_at
            .map(|at| now.saturating_duration_since(at).as_secs());
        if quiet.is_none() && !self.session.blocking_attention && self.session.stall.is_none() {
            return None;
        }
        Some(CarriedClocks {
            working_quiet_seconds: quiet,
            blocking_attention: self.session.blocking_attention,
            stall: self.session.stall.as_ref().map(|probe| CarriedStall {
                working_for_seconds: now.saturating_duration_since(probe.working_since).as_secs(),
                window_for_seconds: now.saturating_duration_since(probe.window_start).as_secs(),
                streamed_bytes: probe.streamed_bytes,
                alerted: probe.alerted,
            }),
        })
    }

    pub fn set_facts(&mut self, facts: SessionFacts) {
        // An agent that changed identity is a new conversation as far as the
        // derived channels are concerned: a spinner alphabet, a progress
        // opt-in and a screen rule set all just changed under them, and a
        // latched transition from the previous agent would suppress the first
        // real signal from this one.
        if facts.agent_id != self.facts.agent_id {
            self.session.last_title_activity = None;
            self.session.last_progress_activity = None;
            self.session.last_screen_activity = None;
        }
        self.facts = facts;
    }

    pub fn facts(&self) -> &SessionFacts {
        &self.facts
    }

    pub fn state(&self) -> State {
        self.session.state
    }

    /// The status string a roster reads. An opaque hook state (`failed`, or
    /// anything a future agent invents) is reported verbatim — the daemon is
    /// not the judge of what a status may be.
    pub fn wire_status(&self) -> String {
        match &self.session.opaque {
            Some(status) => status.clone(),
            None => self.session.state.as_str().to_string(),
        }
    }

    pub fn blocking_attention(&self) -> bool {
        self.session.blocking_attention
    }

    /// Whether the screen half needs reading at all. A plain shell with no
    /// rules is never promoted and never classified, so its sidecar spends
    /// nothing on a once-a-second grid walk.
    pub fn wants_screen_watch(&self) -> bool {
        self.facts.is_agent()
    }

    /// …and whether that read has to carry the text, or only whether it moved.
    pub fn wants_screen_text(&self) -> bool {
        self.facts.screen_rules.is_some()
    }

    fn set_state(&mut self, state: State, source: StatusSource) -> Option<StatusChange> {
        let turn_ended = matches!(state, State::Idle | State::Done);
        self.session.opaque = None;
        if self.session.state == state && !turn_ended {
            return None;
        }
        self.session.state = state;
        if state != State::NeedsYou {
            self.session.blocking_attention = false;
        }
        Some(StatusChange {
            state,
            source,
            turn_ended: turn_ended && source.is_derived(),
        })
    }

    /// Light the "blocked on you" dot from a genuine, observable blocking
    /// condition. Recorded as blocking so a client's own selection does not
    /// clear it: looking at a permission prompt is not answering it.
    fn flag_blocking_attention(&mut self, source: StatusSource) -> Option<StatusChange> {
        self.session.clear_working();
        let change = self.set_state(State::NeedsYou, source);
        // Set even when the state write was a no-op, so a dot already showing
        // is *upgraded* to blocking when the real signal arrives.
        self.session.blocking_attention = true;
        change
    }

    // -- Hooks ------------------------------------------------------------

    /// A `termio agent report`, already normalized (`attention` → `needs_you`).
    /// A host that is speaking for this session is exactly the condition the
    /// derived channels stand down for.
    pub fn note_hook(&mut self, status: &str, now: Instant) -> Option<StatusChange> {
        if matches!(status, "working" | "idle" | "needs_you" | "done" | "failed") {
            self.session.last_hook_report_at = Some(now);
        }
        match status {
            "working" => {
                self.session.last_working_at = Some(now);
                self.begin_stall_watch(now);
                self.set_state(State::Working, StatusSource::Hook)
            }
            "needs_you" => {
                self.end_stall_watch();
                self.flag_blocking_attention(StatusSource::Hook)
            }
            "done" => {
                self.session.clear_working();
                self.end_stall_watch();
                self.set_state(State::Done, StatusSource::Hook)
            }
            "idle" => {
                self.session.clear_working();
                self.end_stall_watch();
                self.set_state(State::Idle, StatusSource::Hook)
            }
            other => {
                // `failed`, and anything an agent invents. Carried verbatim so
                // a client can render what the agent actually said, with the
                // derived channels held off it until the next hook or turn.
                self.session.clear_working();
                self.end_stall_watch();
                self.session.opaque = Some(other.to_string());
                self.session.state = State::Idle;
                Some(StatusChange {
                    state: State::Idle,
                    source: StatusSource::Hook,
                    turn_ended: false,
                })
            }
        }
    }

    // -- Title ------------------------------------------------------------

    /// The agent's live `OSC 0/2` title — the in-band state broadcast some
    /// agents ship (Claude prefixes a spinner mid-turn; Codex and Grok flip to
    /// "Action Required" when blocked).
    ///
    /// Unlike the screen path this *coexists* with hooks: the title is the
    /// agent's own deliberate signal on a channel that cannot break, so it
    /// corrects a missed `working` the instant a turn starts and ends a lost
    /// turn the instant the title calms. Hooks stay senior where they are more
    /// precise: a title-working never overrides `needs_you` (a blocked agent's
    /// title can keep spinning), and a title-idle only *ends* a turn, so an
    /// arbitrary title — which classifies idle by no-match — cannot clear a
    /// hook-set state.
    pub fn note_title(&mut self, title: &str, now: Instant) -> Option<StatusChange> {
        let rules = self.facts.title_rules.as_ref()?;
        let activity = rules.classify(title);
        // Liveness first, before the transition guard: every frame of a ticking
        // spinner is evidence the turn is still running, not just the first.
        // Refreshing only on the transition let the stale sweep clear the
        // spinner mid-turn, and the latch below then stopped any later frame
        // from raising it again — the turn finished with a calm row.
        if activity == Activity::Working {
            self.note_working_liveness(now);
        }
        if self.session.last_title_activity == Some(activity) {
            return None;
        }
        let previous = self.session.last_title_activity;
        self.session.last_title_activity = Some(activity);
        match activity {
            Activity::Working => {
                if self.session.state == State::NeedsYou || !self.facts.is_agent() {
                    return None;
                }
                self.begin_stall_watch(now);
                self.set_state(State::Working, StatusSource::Title)
            }
            Activity::Attention => {
                self.end_stall_watch();
                self.flag_blocking_attention(StatusSource::Title)
            }
            Activity::Idle => {
                if previous != Some(Activity::Working) || self.session.state != State::Working {
                    return None;
                }
                self.session.clear_working();
                self.end_stall_watch();
                self.set_state(State::Idle, StatusSource::Title)
            }
        }
    }

    // -- Progress ---------------------------------------------------------

    /// The agent's ConEmu-style `OSC 9;4` progress reports — the in-band
    /// busy/idle signal Grok ships natively. A correction channel layered over
    /// hooks on the one channel that cannot break, so its arbitration is
    /// deliberately identical to the title's and just as subordinate.
    pub fn note_progress(&mut self, activity: Activity, now: Instant) -> Option<StatusChange> {
        // Gate on the session's live agent, not one captured when the scanner
        // was built: a plain terminal promoted to a hand-started Grok now opts
        // in, while a shell that stays a shell (its `wget` bar) stays out.
        if !self.facts.emits_progress {
            return None;
        }
        if activity == Activity::Working {
            self.note_working_liveness(now);
        }
        if self.session.last_progress_activity == Some(activity) {
            return None;
        }
        let previous = self.session.last_progress_activity;
        self.session.last_progress_activity = Some(activity);
        match activity {
            Activity::Working => {
                if self.session.state == State::NeedsYou {
                    return None;
                }
                self.begin_stall_watch(now);
                self.set_state(State::Working, StatusSource::Progress)
            }
            // The scanner only reaches busy/idle, so this arm is unreachable —
            // kept exhaustive for the shared enum.
            Activity::Attention => {
                self.end_stall_watch();
                self.flag_blocking_attention(StatusSource::Progress)
            }
            Activity::Idle => {
                if previous != Some(Activity::Working) || self.session.state != State::Working {
                    return None;
                }
                self.session.clear_working();
                self.end_stall_watch();
                self.set_state(State::Idle, StatusSource::Progress)
            }
        }
    }

    // -- Screen -----------------------------------------------------------

    /// Drives status from an agent's own screen when it ships no hook system —
    /// the path for agents whose manifest declared `status` regex rules.
    ///
    /// Status is rewritten only on a *transition*, so an idle screen does not
    /// re-emit every second; a working screen refreshes the liveness clock on
    /// every tick so the sweep cannot clear a live turn whose screen briefly
    /// stopped changing.
    pub fn note_screen(&mut self, screen: &str, now: Instant) -> Option<StatusChange> {
        let rules = self.facts.screen_rules.as_ref()?;
        let activity = rules.classify(screen);
        if activity == Activity::Working {
            self.note_working_liveness(now);
        }
        if self.session.last_screen_activity == Some(activity) {
            return None;
        }
        let previous = self.session.last_screen_activity;
        self.session.last_screen_activity = Some(activity);
        match activity {
            Activity::Working => {
                self.begin_stall_watch(now);
                self.set_state(State::Working, StatusSource::Screen)
            }
            Activity::Attention => {
                self.end_stall_watch();
                self.flag_blocking_attention(StatusSource::Screen)
            }
            Activity::Idle => {
                self.session.clear_working();
                self.end_stall_watch();
                // A turn that just ended and a screen that was merely calm both
                // read `idle` here. The Swift version distinguished them only to
                // pick `done` for the first, and that pick is the viewer's now
                // (§3.3) — it reads `turn_ended` off the change instead.
                let _ = previous;
                self.set_state(State::Idle, StatusSource::Screen)
            }
        }
    }

    /// Marks live user input into this session's PTY. Keystroke echo and
    /// mouse-mode scrolling repaint a screen exactly like agent output, so
    /// promotion holds off while the human is the one causing the changes.
    ///
    /// Fed from the daemon's own write path, which is the choke point *every*
    /// input crosses — this Mac, a phone, and `termio sessions send` alike.
    /// The Mac's version only ever saw its own keystrokes.
    pub fn note_user_input(&mut self, now: Instant) {
        if self
            .session
            .last_user_input_at
            .is_some_and(|existing| existing >= now)
        {
            return;
        }
        self.session.last_user_input_at = Some(now);
    }

    /// Keeps a session's status honest against its live output, in both
    /// directions.
    ///
    /// *Sustain*: while working, a changed screen (streaming tokens, a ticking
    /// spinner) refreshes the liveness clock so the sweep leaves the turn
    /// alone; a static screen lets it age out — the recovery for a turn that
    /// ended without a `Stop` hook. The screen, not raw bytes, is the primary
    /// key: a finished agent still dribbles output at an idle prompt, which is
    /// exactly the stuck-spinner failure. The byte floor is the one exception,
    /// for a client whose surface stopped changing mid-stream.
    ///
    /// *Promote*: hooks miss turns in the wild — an uninstalled hook file, a
    /// turn the sweep cleared mid-stream, a TUI that never fires them — and
    /// historically nothing could re-light the spinner until the next hook
    /// event. Two consecutive changed ticks promote `idle` back to `working`,
    /// guarded so precision states are never guessed over.
    pub fn note_output(&mut self, changed: bool, bytes: u64, now: Instant) -> Option<StatusChange> {
        if let Some(probe) = self.session.stall.as_mut() {
            probe.streamed_bytes = probe.streamed_bytes.saturating_add(bytes);
        }
        if self.session.state == State::Working {
            self.session.promotion_streak = 0;
            if changed || bytes >= STREAMING_BYTE_FLOOR {
                self.session.last_working_at = Some(now);
            }
            return None;
        }
        if !changed {
            self.session.promotion_streak = 0;
            return None;
        }
        if self.session.state != State::Idle
            || self.session.opaque.is_some()
            || !self.facts.is_agent()
            // An agent whose declared screen rules already own its status is
            // never guessed over.
            || self.facts.screen_rules.is_some()
        {
            return None;
        }
        if now.saturating_duration_since(self.session.launched_at) < LAUNCH_GRACE {
            return None;
        }
        if self
            .session
            .last_user_input_at
            .is_some_and(|at| now.saturating_duration_since(at) < USER_INPUT_QUIET)
        {
            return None;
        }
        if self
            .session
            .last_hook_report_at
            .is_some_and(|at| now.saturating_duration_since(at) < HOOK_QUIET)
        {
            return None;
        }
        self.session.promotion_streak += 1;
        if self.session.promotion_streak < PROMOTION_STREAK {
            return None;
        }
        self.session.promotion_streak = 0;
        self.session.last_working_at = Some(now);
        self.begin_stall_watch(now);
        self.set_state(State::Working, StatusSource::Screen0Streak)
    }

    /// Sweeps a session stuck working with no liveness back to idle. This only
    /// matters while nobody is looking — a client selecting a session clears it
    /// anyway — so the timeout is long enough never to interrupt a genuine long
    /// turn, and is purely a recovery path for an agent that died mid-turn.
    pub fn sweep_stale_working(&mut self, now: Instant) -> Option<StatusChange> {
        let since = self.session.last_working_at?;
        if now.saturating_duration_since(since) <= STALE_WORKING_TIMEOUT {
            return None;
        }
        self.session.clear_working();
        self.end_stall_watch();
        if self.session.state != State::Working {
            return None;
        }
        self.set_state(State::Idle, StatusSource::Screen0Streak)
    }

    fn note_working_liveness(&mut self, now: Instant) {
        self.session.last_working_at = Some(now);
    }

    // -- Stall ------------------------------------------------------------

    /// Opens the stall window for a session entering `working`. Called from
    /// every path that sets it, which is the one choke point the Swift version
    /// had in `setStatus`.
    fn begin_stall_watch(&mut self, now: Instant) {
        if self.session.stall.is_some() {
            return;
        }
        let generation = self.next_generation;
        self.next_generation += 1;
        self.session.stall = Some(StallProbe::new(now, generation));
    }

    fn end_stall_watch(&mut self) {
        self.session.stall = None;
    }

    pub fn stall_probe(&self) -> Option<&StallProbe> {
        self.session.stall.as_ref()
    }

    pub fn stall_probe_mut(&mut self) -> Option<&mut StallProbe> {
        self.session.stall.as_mut()
    }

    /// What the stall sweep should do for this session on this tick, evaluated
    /// cheapest-first: the clock and the output-rate suppressor are arithmetic
    /// and gate everything, so only a fully-elapsed, unsuppressed window pays
    /// for the git + transcript measurement.
    pub fn stall_step(&mut self, now: Instant) -> StallStep {
        if self.session.state != State::Working {
            self.session.stall = None;
            return StallStep::Nothing;
        }
        let window = stall_window();
        let interval = stall_probe_interval();
        let rate = stall_stream_byte_rate();
        let Some(probe) = self.session.stall.as_mut() else {
            return StallStep::Nothing;
        };
        if probe.measuring {
            return StallStep::Nothing;
        }
        if probe.baseline.is_none() {
            probe.measuring = true;
            return StallStep::Capture {
                generation: probe.generation,
            };
        }
        if now.saturating_duration_since(probe.window_start) < window {
            return StallStep::Nothing;
        }
        if probe
            .last_probe_at
            .is_some_and(|at| now.saturating_duration_since(at) < interval)
        {
            return StallStep::Nothing;
        }
        if probe.is_stream_suppressed(now, rate) {
            // Sustained output is progress in itself: slide the window instead
            // of alerting, and drop the baseline so the next capture compares
            // against the world as of now.
            probe.slide_window(now, None);
            return StallStep::Nothing;
        }
        probe.measuring = true;
        probe.last_probe_at = Some(now);
        StallStep::Probe {
            generation: probe.generation,
            directory: probe.baseline.as_ref().and_then(|b| b.directory.clone()),
            transcript: probe.baseline.as_ref().and_then(|b| b.transcript_path.clone()),
        }
    }

    /// Apply a measurement that came back from the blocking pool. A result
    /// landing after the session left and re-entered `working` carries an older
    /// generation and is dropped.
    pub fn apply_stall_measurement(
        &mut self,
        generation: u64,
        directory: Option<String>,
        measured: &StallMeasurement,
        capture: bool,
        now: Instant,
    ) -> Option<Assessment> {
        let floor = stall_transcript_line_floor();
        let probe = self.session.stall.as_mut()?;
        if probe.generation != generation {
            return None;
        }
        probe.measuring = false;
        if capture {
            probe.baseline = Some(StallBaseline::new(directory, measured));
            return None;
        }
        Some(probe.assess(measured, now, floor))
    }

    /// How long the current turn has been running, for the one `stalled`
    /// event's evidence line.
    pub fn working_since(&self) -> Option<Instant> {
        self.session.stall.as_ref().map(|probe| probe.working_since)
    }
}

/// A session's status clocks, packed for an `execve` handoff.
///
/// Durations, not instants: what has to survive is *elapsed time*, and that is
/// the one form both processes agree on. Every field is additive with a serde
/// default, so a blob written by a daemon that predates this reads as "no
/// clocks" and the adopted session starts them fresh — the behaviour before
/// this existed.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CarriedClocks {
    /// How long the session has been quiet, measured from the last liveness the
    /// old process saw. This is the stale-working sweep's clock, and the reason
    /// this struct exists: without it, a box that upgrades its daemon can never
    /// sweep a turn that ended.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_quiet_seconds: Option<u64>,
    #[serde(default)]
    pub blocking_attention: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stall: Option<CarriedStall>,
}

/// The open stall window, as elapsed time. The baseline is not here on purpose
/// — see `restore_clocks`.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CarriedStall {
    pub working_for_seconds: u64,
    pub window_for_seconds: u64,
    #[serde(default)]
    pub streamed_bytes: u64,
    #[serde(default)]
    pub alerted: bool,
}

/// What one stall sweep tick asks the caller to do. The engine never touches
/// the filesystem: it says what to measure and judges what comes back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StallStep {
    Nothing,
    /// Seed a fresh window's baseline. The directory is resolved by the caller,
    /// which is the only side that knows a session's worktree.
    Capture { generation: u64 },
    /// Judge against the existing baseline, reusing its directory for the whole
    /// window so an agent `cd`-ing between repos cannot look like progress.
    Probe {
        generation: u64,
        directory: Option<String>,
        transcript: Option<String>,
    },
}

// ---------------------------------------------------------------------------
// Agent resolution
// ---------------------------------------------------------------------------

/// Resolve a session's agent to the facts the engine needs.
///
/// Two inputs, in order: the workstream a client declared when it created the
/// session, then the argv the kernel reports for whatever holds the tty's
/// foreground — which is how a hand-started `claude` in a plain shell gets its
/// rules. This is *not* the argv → glyph mapping device architecture keeps
/// client-side: which icon a row wears is presentation, and nothing here
/// decides it. Selecting which regex list to run against this box's own screen
/// is the device parsing its own signal.
pub fn resolve_facts(
    catalog: &crate::agent::manifest::AgentCatalog,
    agent_id: Option<&str>,
    foreground_argv: Option<&[String]>,
) -> SessionFacts {
    let declared = agent_id.and_then(|id| catalog.all.iter().find(|agent| agent.id == id));
    let detected = declared.or_else(|| foreground_argv.and_then(|argv| match_argv(catalog, argv)));
    let Some(agent) = detected else {
        return SessionFacts::default();
    };
    SessionFacts {
        agent_id: Some(agent.id.clone()),
        screen_rules: agent
            .status_rules
            .as_ref()
            .and_then(|rules| RuleSet::compile(rules, &agent.id)),
        title_rules: agent
            .title_rules
            .as_ref()
            .and_then(|rules| RuleSet::compile(rules, &agent.id)),
        emits_progress: agent.emits_progress_status,
    }
}

/// Match a foreground argv to a catalog entry by the program's own name. Only
/// argv[0]'s basename is considered: a wrapper's flags are not identity, and an
/// agent invoked through `npx` or a shim still reports its own binary once the
/// exec has happened.
fn match_argv<'a>(
    catalog: &'a crate::agent::manifest::AgentCatalog,
    argv: &[String],
) -> Option<&'a crate::agent::manifest::AgentDefinition> {
    let program = argv.first()?;
    let name = std::path::Path::new(program)
        .file_name()
        .and_then(|name| name.to_str())?;
    catalog.all.iter().find(|agent| {
        agent
            .command
            .as_deref()
            .and_then(|command| std::path::Path::new(command).file_name())
            .and_then(|command| command.to_str())
            .is_some_and(|command| command == name)
    })
}

/// The device's agent manifests, loaded once.
///
/// Read-only after the first call, which is what lets every session actor share
/// one copy of sixteen parsed manifests. The cost is that a manifest dropped
/// into `~/.termio/config/agents` after the daemon started is not seen until it
/// restarts — the same rule the installer already follows, and stated here
/// because it is now also what decides whether a row gets a status dot.
pub fn catalog() -> &'static crate::agent::manifest::AgentCatalog {
    static CATALOG: std::sync::OnceLock<crate::agent::manifest::AgentCatalog> =
        std::sync::OnceLock::new();
    CATALOG.get_or_init(crate::agent::manifest::AgentCatalog::load)
}

/// One reading of the two progress markers, taken off the actor thread because
/// both touch the filesystem and one shells out to git — the main-thread-git
/// freeze is the documented hazard on the other side of this port.
///
/// The transcript's full line count is only paid for when its size moved (or
/// nothing is known yet): an unchanged `stat` answers "grew < K lines" by
/// itself.
pub fn measure_stall_evidence(
    directory: Option<&str>,
    transcript: Option<&str>,
    known: Option<&StallBaseline>,
) -> StallMeasurement {
    let repo_fingerprint = directory.map(stall_fingerprint).unwrap_or_default();
    let Some(transcript) = transcript else {
        return StallMeasurement {
            repo_fingerprint,
            transcript_path: None,
            transcript_lines: 0,
            transcript_size: 0,
        };
    };
    let size = std::fs::metadata(transcript)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let lines = match known {
        Some(baseline)
            if baseline.transcript_path.as_deref() == Some(transcript)
                && baseline.transcript_size == size =>
        {
            baseline.transcript_lines
        }
        _ => line_count(transcript),
    };
    StallMeasurement {
        repo_fingerprint,
        transcript_path: Some(transcript.to_string()),
        transcript_lines: lines,
        transcript_size: size,
    }
}

/// Probe 2's evidence: what the repo looked like, cheap enough to run every
/// probe interval. `HEAD` plus a hash of the porcelain status — the same pair
/// `GitService.stallFingerprint` compared, so a commit, a checkout, or a single
/// edited file all move it.
fn stall_fingerprint(directory: &str) -> String {
    let head = git_output(directory, &["rev-parse", "HEAD"]).unwrap_or_default();
    let status = git_output(directory, &["status", "--porcelain"]).unwrap_or_default();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    std::hash::Hash::hash(&status, &mut hasher);
    format!("{}#{}", head.trim(), std::hash::Hasher::finish(&hasher))
}

fn git_output(directory: &str, arguments: &[&str]) -> Option<String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(arguments)
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Lines in a file, counted by reading it. A transcript is JSONL and grows at
/// the end, so this is a whole read — which is why the caller only asks for it
/// when `stat` says the size moved.
fn line_count(path: &str) -> usize {
    use std::io::{BufRead, BufReader};
    let Ok(file) = std::fs::File::open(path) else {
        return 0;
    };
    BufReader::new(file).split(b'\n').count()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::manifest::AgentCatalog;

    fn at(seconds: u64) -> Instant {
        // Every case is relative, and `Instant` has no epoch to construct from —
        // so a fixed origin plus an offset is the portable way to write "later".
        origin() + Duration::from_secs(seconds)
    }

    fn origin() -> Instant {
        // One process-wide base, far enough ahead that a case may also subtract.
        static BASE: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        *BASE.get_or_init(|| Instant::now() + Duration::from_secs(24 * 60 * 60))
    }

    fn rules(working: &[&str], attention: &[&str]) -> Option<RuleSet> {
        RuleSet::compile(
            &StatusRules {
                working: working.iter().map(|p| p.to_string()).collect(),
                attention: attention.iter().map(|p| p.to_string()).collect(),
            },
            "test",
        )
    }

    fn agent_facts() -> SessionFacts {
        SessionFacts {
            agent_id: Some("claudeCode".to_string()),
            screen_rules: None,
            title_rules: None,
            emits_progress: false,
            }
    }

    // -- StallProbeTests, ported case for case ---------------------------

    fn measurement(fingerprint: &str, lines: usize, size: u64) -> StallMeasurement {
        StallMeasurement {
            repo_fingerprint: fingerprint.to_string(),
            transcript_path: Some("/tmp/t.jsonl".to_string()),
            transcript_lines: lines,
            transcript_size: size,
        }
    }

    fn probe_with_baseline() -> StallProbe {
        let mut probe = StallProbe::new(origin(), 1);
        probe.baseline = Some(StallBaseline::new(
            Some("/repo".to_string()),
            &measurement("abc#1", 100, 1000),
        ));
        probe
    }

    /// The edge trigger fires exactly once per quiet window.
    #[test]
    fn unchanged_evidence_alerts_once_then_holds() {
        let mut probe = probe_with_baseline();
        let later = at(1200);
        assert_eq!(
            probe.assess(&measurement("abc#1", 103, 1000), later, 5),
            Assessment::Stalled {
                transcript_lines_grown: 3
            }
        );
        assert!(probe.alerted);
        assert_eq!(
            probe.assess(&measurement("abc#1", 104, 1000), at(1230), 5),
            Assessment::Hold
        );
    }

    /// A commit moves the fingerprint: the window slides and the latch re-arms,
    /// so a later quiet stretch may alert again — one event per window, not one
    /// per turn.
    #[test]
    fn repo_change_is_progress_and_rearms() {
        let mut probe = probe_with_baseline();
        let later = at(1200);
        assert_eq!(
            probe.assess(&measurement("abc#1", 100, 1000), later, 5),
            Assessment::Stalled {
                transcript_lines_grown: 0
            }
        );
        let after_commit = at(1260);
        assert_eq!(
            probe.assess(&measurement("def#2", 100, 1000), after_commit, 5),
            Assessment::Progress
        );
        assert!(!probe.alerted);
        assert_eq!(probe.window_start, after_commit);
        assert_eq!(
            probe.baseline.as_ref().map(|b| b.repo_fingerprint.as_str()),
            Some("def#2")
        );
        assert_eq!(
            probe.assess(&measurement("def#2", 100, 1000), at(2460), 5),
            Assessment::Stalled {
                transcript_lines_grown: 0
            }
        );
    }

    #[test]
    fn transcript_burst_is_progress() {
        let mut probe = probe_with_baseline();
        assert_eq!(
            probe.assess(&measurement("abc#1", 105, 2000), at(1200), 5),
            Assessment::Progress
        );
        assert_eq!(probe.baseline.as_ref().map(|b| b.transcript_lines), Some(105));
    }

    /// The suppressor reads sustained volume, not spinner dribble.
    #[test]
    fn stream_suppressor_reads_sustained_volume_only() {
        let mut probe = StallProbe::new(origin(), 1);
        let later = at(1000);
        probe.streamed_bytes = 2048 * 1000;
        assert!(!probe.is_stream_suppressed(later, 4096.0));
        probe.streamed_bytes = 20_000 * 1000;
        assert!(probe.is_stream_suppressed(later, 4096.0));
    }

    #[test]
    fn slide_window_without_baseline_forces_recapture() {
        let mut probe = probe_with_baseline();
        probe.alerted = true;
        probe.streamed_bytes = 300_000;
        let now = at(1200);
        probe.slide_window(now, None);
        assert!(probe.baseline.is_none());
        assert!(!probe.alerted);
        assert_eq!(probe.streamed_bytes, 0);
        assert_eq!(probe.window_start, now);
        // With no baseline the assessment cannot judge — it holds until recapture.
        assert_eq!(
            probe.assess(&measurement("abc#1", 100, 1000), at(2400), 5),
            Assessment::Hold
        );
    }

    // -- AgentTitleStatusTests, ported ------------------------------------

    fn title_engine() -> StatusEngine {
        let mut facts = agent_facts();
        facts.title_rules = rules(&["^[\u{2800}-\u{28ff}\u{25d0}-\u{25d3}] "], &[]);
        StatusEngine::new(origin(), facts)
    }

    /// Every frame of a ticking title spinner is evidence the turn is still
    /// running. They collapse to a no-op at the transition guard, so if only the
    /// first refreshed the liveness clock the sweep cleared the spinner mid-turn
    /// — and the latch then stopped any later frame from raising it again.
    #[test]
    fn every_working_title_frame_refreshes_liveness() {
        let mut engine = title_engine();
        engine.note_title("\u{280b} Fix the resize bug", at(0));
        assert_eq!(engine.state(), State::Working);

        // Stand in for a turn that has run long enough for the sweep to be
        // interested, then let the agent tick its spinner once more.
        let stale = at(600);
        engine.note_title("\u{2819} Fix the resize bug", stale);
        assert_eq!(engine.sweep_stale_working(at(605)), None);
        assert_eq!(engine.state(), State::Working);
        // Without a fresh frame the same window does clear it.
        assert!(engine.sweep_stale_working(at(700)).is_some());
        assert_eq!(engine.state(), State::Idle);
    }

    /// The other direction still has to work: a title that calms is how a turn
    /// ends without a `Stop` hook.
    #[test]
    fn a_calm_title_ends_the_turn() {
        let mut engine = title_engine();
        engine.note_title("\u{280b} Fix the resize bug", at(0));
        let change = engine.note_title("Fix the resize bug", at(10));
        assert_eq!(engine.state(), State::Idle);
        // Derived, so the viewer decides whether this reads as done.
        assert!(change.is_some_and(|change| change.turn_ended));
    }

    /// Claude ships two spinner alphabets: braille through 2.1.227, half-circles
    /// from 2.1.228. Matching only the first meant the title channel went silent
    /// the day a user updated.
    #[test]
    fn claude_title_rules_read_both_spinner_alphabets() {
        let catalog = AgentCatalog::load_from(None);
        let claude = catalog
            .all
            .iter()
            .find(|agent| agent.id == "claudeCode")
            .expect("bundled claude manifest");
        let compiled = claude
            .title_rules
            .as_ref()
            .and_then(|rules| RuleSet::compile(rules, "claudeCode"))
            .expect("claude declares title rules");

        for frame in [
            "\u{280b}", "\u{2819}", "\u{2839}", "\u{25d0}", "\u{25d1}", "\u{25d2}", "\u{25d3}",
        ] {
            assert_eq!(
                compiled.classify(&format!("{frame} Fix the resize bug")),
                Activity::Working,
                "{frame} should read as working"
            );
        }
        assert_eq!(
            compiled.classify("\u{2733} Fix the resize bug"),
            Activity::Idle
        );
    }

    /// The narrowed accepted language (§3.4) has to hold for everything termio
    /// ships, or an agent's dot stops moving the day this lands.
    #[test]
    fn bundled_status_patterns_compile() {
        let catalog = AgentCatalog::load_from(None);
        for agent in &catalog.bundled {
            for spec in [&agent.status_rules, &agent.title_rules].into_iter().flatten() {
                for pattern in spec.working.iter().chain(spec.attention.iter()) {
                    assert!(
                        compile_one(pattern).is_ok(),
                        "{}: /{pattern}/ does not compile",
                        agent.id
                    );
                }
            }
        }
    }

    /// A pattern the engine will not take is dropped, not fatal — one typo in a
    /// user's own manifest must not sink the agent's other rules.
    #[test]
    fn an_unsupported_pattern_is_dropped_and_the_rest_survive() {
        let set = rules(&["(?=lookahead)", "Thinking\\.\\.\\."], &[]).expect("the valid one");
        assert_eq!(set.classify("Thinking..."), Activity::Working);
        assert_eq!(set.classify("lookahead"), Activity::Idle);
        assert!(rules(&["(?=only-invalid)"], &[]).is_none());
    }

    // -- OSCProgressScannerTests, ported ----------------------------------

    fn progress(chunk: &[u8]) -> Vec<Activity> {
        let mut scanner = OscScanner::default();
        scanner
            .scan(chunk)
            .into_iter()
            .filter_map(|signal| match signal {
                OscSignal::Progress(activity) => Some(activity),
                OscSignal::Title(_) => None,
            })
            .collect()
    }

    #[test]
    fn reads_both_terminators_and_both_busy_states() {
        assert_eq!(progress(b"\x1b]9;4;1;-1\x07"), vec![Activity::Working]);
        assert_eq!(progress(b"\x1b]9;4;3;50\x1b\\"), vec![Activity::Working]);
        assert_eq!(progress(b"\x1b]9;4;0;\x07"), vec![Activity::Idle]);
        assert_eq!(progress(b"\x1b]9;4;1;\x07"), vec![Activity::Working]);
    }

    #[test]
    fn both_edges_of_one_turn_arrive_in_order() {
        assert_eq!(
            progress(b"\x1b]9;4;1;-1\x07work\x1b]9;4;0;\x07"),
            vec![Activity::Working, Activity::Idle]
        );
    }

    #[test]
    fn a_sequence_split_across_reads_is_tolerated() {
        let mut scanner = OscScanner::default();
        assert!(scanner.scan(b"\x1b]9;4").is_empty());
        assert_eq!(
            scanner.scan(b";1;-1\x07"),
            vec![OscSignal::Progress(Activity::Working)]
        );
    }

    #[test]
    fn error_and_paused_states_are_not_transitions() {
        assert!(progress(b"\x1b]9;4;2;50\x07").is_empty());
        assert!(progress(b"\x1b]9;4;4;50\x07").is_empty());
    }

    /// A notification body beginning `4;…` is not a progress report, and neither
    /// is a longer OSC number that merely starts with 4.
    #[test]
    fn other_osc_nine_payloads_are_not_progress() {
        assert!(progress(b"\x1b]9;4 files changed\x07").is_empty());
        assert!(progress(b"\x1b]9;41;1;50\x07").is_empty());
        assert!(progress(b"\x1b]9;4;1;900\x07").is_empty());
        assert!(progress(b"\x1b]9;4;1\x07").is_empty());
    }

    /// Keepalives are not collapsed here — not within a chunk and not across
    /// one. The arbiter collapses them; this reports what the agent actually
    /// said, which is what makes each one liveness evidence.
    #[test]
    fn every_keepalive_is_reported_within_a_chunk_and_across_them() {
        assert_eq!(
            progress(b"\x1b]9;4;1;-1\x07\x1b]9;4;1;-1\x07\x1b]9;4;1;-1\x07"),
            vec![Activity::Working; 3]
        );

        let mut scanner = OscScanner::default();
        let mut seen = Vec::new();
        for _ in 0..3 {
            seen.extend(scanner.scan(b"\x1b]9;4;1;-1\x07"));
        }
        assert_eq!(seen, vec![OscSignal::Progress(Activity::Working); 3]);
    }

    /// An overlong payload cannot be classified from its truncated prefix, so
    /// it is rejected outright. The bound is a title's, not a progress
    /// report's, because both ride this scanner now — a report is still a
    /// handful of bytes, and nothing that long is one.
    #[test]
    fn an_overlong_payload_is_rejected_rather_than_truncated() {
        let mut chunk = b"\x1b]9;4;1;".to_vec();
        chunk.extend(std::iter::repeat(b'9').take(OscScanner::MAX_PAYLOAD + 8));
        chunk.push(0x07);
        assert!(progress(&chunk).is_empty());

        // …and the scanner recovers: the next report in the same stream lands.
        let mut scanner = OscScanner::default();
        let _ = scanner.scan(&chunk);
        assert_eq!(
            scanner.scan(b"\x1b]9;4;0;\x07"),
            vec![OscSignal::Progress(Activity::Idle)]
        );
    }

    /// A report embedded in a burst of ordinary output still lands, and the
    /// ordinary bytes do not become one.
    #[test]
    fn a_report_amidst_other_output_still_lands() {
        assert_eq!(
            progress(b"hello\r\nworld \x1b]9;4;1;-1\x07 more \x1b[32mgreen\x1b[0m"),
            vec![Activity::Working]
        );
    }

    /// The grammar, directly — the same table the Swift `classify` case pinned.
    #[test]
    fn classify_pins_the_grammar() {
        assert_eq!(classify_progress(b"9;4;0;"), Some(Activity::Idle));
        // Clear needs no progress field.
        assert_eq!(classify_progress(b"9;4;0"), Some(Activity::Idle));
        assert_eq!(classify_progress(b"9;4;1;-1"), Some(Activity::Working));
        // Indeterminate with an empty field.
        assert_eq!(classify_progress(b"9;4;3;"), Some(Activity::Working));
        // A busy state needs the field.
        assert_eq!(classify_progress(b"9;4;3"), None);
        assert_eq!(classify_progress(b"9;4"), None);
        assert_eq!(classify_progress(b"9;4;1;text"), None);
        assert_eq!(classify_progress(b"9;9;cwd"), None);
    }

    #[test]
    fn a_title_is_read_and_an_icon_name_is_not() {
        let mut scanner = OscScanner::default();
        assert_eq!(
            scanner.scan(b"\x1b]0;\xe2\xa0\x8b Fixing\x07"),
            vec![OscSignal::Title("\u{280b} Fixing".to_string())]
        );
        assert_eq!(
            scanner.scan(b"\x1b]2;plain\x1b\\"),
            vec![OscSignal::Title("plain".to_string())]
        );
        assert!(scanner.scan(b"\x1b]1;icon\x07").is_empty());
        // OSC 7 (cwd) and OSC 4 (palette) fall through, as they must.
        assert!(scanner.scan(b"\x1b]7;file:///tmp\x07").is_empty());
        assert!(scanner.scan(b"\x1b]4;1;rgb:00/00/00\x07").is_empty());
    }

    // -- Arbitration ------------------------------------------------------

    /// Hooks are senior: a title that keeps spinning must not clear the dot on
    /// an agent that told us it is blocked.
    #[test]
    fn a_title_working_never_overrides_needs_you() {
        let mut engine = title_engine();
        engine.note_hook("needs_you", at(0));
        assert_eq!(engine.state(), State::NeedsYou);
        engine.note_title("\u{280b} still spinning", at(1));
        assert_eq!(engine.state(), State::NeedsYou);
        assert!(engine.blocking_attention());
    }

    /// …and a title that calms only ever *ends* a turn. An arbitrary title
    /// classifies idle by no-match, and must not clear a hook-set state.
    #[test]
    fn a_title_idle_only_ends_a_live_turn() {
        let mut engine = title_engine();
        engine.note_hook("done", at(0));
        engine.note_title("some unrelated title", at(1));
        assert_eq!(engine.state(), State::Done);
    }

    /// Two consecutive changed ticks promote a quiet agent back to working —
    /// the recovery for a hook that never fired.
    #[test]
    fn two_changed_ticks_promote_and_one_does_not() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        assert_eq!(engine.note_output(true, 0, at(20)), None);
        let change = engine.note_output(true, 0, at(21)).expect("promoted");
        assert_eq!(change.state, State::Working);
        assert_eq!(change.source, StatusSource::Screen0Streak);
    }

    #[test]
    fn promotion_holds_off_during_the_launch_grace() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        assert_eq!(engine.note_output(true, 0, at(1)), None);
        assert_eq!(engine.note_output(true, 0, at(2)), None);
        assert_eq!(engine.state(), State::Idle);
    }

    #[test]
    fn promotion_holds_off_right_after_the_user_typed() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        engine.note_user_input(at(20));
        assert_eq!(engine.note_output(true, 0, at(20)), None);
        assert_eq!(engine.note_output(true, 0, at(21)), None);
        // Once the quiet window has passed, the same two ticks promote.
        assert_eq!(engine.note_output(true, 0, at(30)), None);
        assert!(engine.note_output(true, 0, at(31)).is_some());
    }

    #[test]
    fn promotion_holds_off_while_hooks_are_speaking() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        engine.note_hook("idle", at(20));
        assert_eq!(engine.note_output(true, 0, at(21)), None);
        assert_eq!(engine.note_output(true, 0, at(22)), None);
        assert_eq!(engine.state(), State::Idle);
    }

    /// A plain shell is never promoted: a `wget` bar is not a turn.
    #[test]
    fn a_shell_is_never_promoted() {
        let mut engine = StatusEngine::new(origin(), SessionFacts::default());
        assert_eq!(engine.note_output(true, 0, at(20)), None);
        assert_eq!(engine.note_output(true, 0, at(21)), None);
        assert_eq!(engine.state(), State::Idle);
        assert!(!engine.wants_screen_watch());
    }

    /// An agent whose declared screen rules already own its status is never
    /// guessed over by the streak.
    #[test]
    fn declared_screen_rules_stand_the_streak_down() {
        let mut facts = agent_facts();
        facts.screen_rules = rules(&["Thinking"], &[]);
        let mut engine = StatusEngine::new(origin(), facts);
        assert_eq!(engine.note_output(true, 0, at(20)), None);
        assert_eq!(engine.note_output(true, 0, at(21)), None);
        assert_eq!(engine.state(), State::Idle);
        assert!(engine.wants_screen_text());
    }

    /// A working screen refreshes liveness every tick, so the sweep cannot
    /// clear a live turn whose screen briefly stopped changing.
    #[test]
    fn a_changed_screen_sustains_a_live_turn() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        engine.note_hook("working", at(0));
        engine.note_output(true, 0, at(10));
        assert_eq!(engine.sweep_stale_working(at(15)), None);
        assert_eq!(engine.state(), State::Working);
        assert!(engine.sweep_stale_working(at(30)).is_some());
        assert_eq!(engine.state(), State::Idle);
    }

    /// A viewport that stopped changing mid-stream still counts as alive when
    /// the byte volume says so.
    #[test]
    fn a_streaming_byte_volume_sustains_a_static_screen() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        engine.note_hook("working", at(0));
        engine.note_output(false, STREAMING_BYTE_FLOOR, at(10));
        assert_eq!(engine.sweep_stale_working(at(15)), None);
        assert_eq!(engine.state(), State::Working);
    }

    /// Precedence within one screen: a permission prompt under a still-spinning
    /// header is attention, not working.
    #[test]
    fn attention_outranks_working_on_one_screen() {
        let set = rules(&["Thinking"], &["Permission Required"]).expect("rules");
        assert_eq!(
            set.classify("Thinking...\nPermission Required"),
            Activity::Attention
        );
    }

    /// A hook state the daemon does not model rides through untouched — the
    /// daemon is not the judge of what a status may be.
    #[test]
    fn an_opaque_hook_state_is_carried_verbatim() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        engine.note_hook("failed", at(0));
        assert_eq!(engine.wire_status(), "failed");
        // …and the streak does not overwrite it, hook-quiet window or not.
        assert_eq!(engine.note_output(true, 0, at(60)), None);
        assert_eq!(engine.note_output(true, 0, at(61)), None);
        assert_eq!(engine.wire_status(), "failed");
    }

    /// A hook `done` is the agent's own word and reads `done` on every client;
    /// only a derived turn end is the viewer's to judge.
    #[test]
    fn only_a_derived_turn_end_is_the_viewers_to_judge() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        let change = engine.note_hook("done", at(0)).expect("a change");
        assert_eq!(change.state, State::Done);
        assert!(!change.turn_ended);
    }

    /// The progress channel is gated on the live agent, so an unrelated shell's
    /// download bar cannot move a dot.
    #[test]
    fn progress_is_gated_on_the_agent_opting_in() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        assert_eq!(engine.note_progress(Activity::Working, at(10)), None);

        let mut facts = agent_facts();
        facts.emits_progress = true;
        let mut engine = StatusEngine::new(origin(), facts);
        assert!(engine.note_progress(Activity::Working, at(10)).is_some());
        assert_eq!(engine.state(), State::Working);
    }

    /// A session carried across a handoff keeps the status it arrived with,
    /// rather than reading `idle` until its next transition.
    #[test]
    fn an_adopted_status_seeds_the_engine() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        engine.seed("working", None, at(0));
        assert_eq!(engine.state(), State::Working);
        assert!(engine.stall_probe().is_some());
        // …and the stale sweep can still end it, so an agent that died during
        // the handoff does not spin forever.
        assert!(engine.sweep_stale_working(at(100)).is_some());

        let mut engine = StatusEngine::new(origin(), agent_facts());
        engine.seed("unknown", None, at(0));
        assert_eq!(engine.state(), State::Idle);
        assert_eq!(engine.wire_status(), "idle");

        let mut engine = StatusEngine::new(origin(), agent_facts());
        engine.seed("failed", None, at(0));
        assert_eq!(engine.wire_status(), "failed");
    }

    /// The clocks cross an `execve`, or a box that upgrades its daemon on a
    /// timer never sweeps a turn that ended: each handoff restarted the window
    /// and pushed the deadline out by another full timeout.
    #[test]
    fn a_handoff_keeps_the_stale_working_clock_on_its_original_schedule() {
        let mut before = StatusEngine::new(origin(), agent_facts());
        before.note_hook("working", at(0));
        // Eleven seconds of quiet — one short of the sweep's timeout.
        let handoff = at(11);
        assert_eq!(before.sweep_stale_working(handoff), None);

        let clocks = before.carried_clocks(handoff).expect("a live turn carries");
        assert_eq!(clocks.working_quiet_seconds, Some(11));

        // The far side of the exec: a new engine, a new clock, the same turn.
        let after_origin = origin() + Duration::from_secs(1_000);
        let mut after = StatusEngine::new(after_origin, agent_facts());
        after.seed("working", Some(&clocks), after_origin);
        assert_eq!(after.state(), State::Working);

        // One more second reaches the original 12s deadline, not a fresh one.
        assert!(after
            .sweep_stale_working(after_origin + Duration::from_secs(2))
            .is_some());
        assert_eq!(after.state(), State::Idle);
    }

    /// The stall window crosses too, and for the same reason: a 20-minute
    /// window restarted by every upgrade is a signal that never fires.
    #[test]
    fn a_handoff_keeps_the_stall_window_and_its_latch() {
        let mut before = StatusEngine::new(origin(), agent_facts());
        before.note_hook("working", at(0));
        let probe = before.stall_probe_mut().expect("working opens a window");
        probe.streamed_bytes = 4_096;
        probe.alerted = true;

        let handoff = at(900);
        let clocks = before.carried_clocks(handoff).expect("clocks");
        let stall = clocks.stall.as_ref().expect("an open window");
        assert_eq!(stall.window_for_seconds, 900);
        assert_eq!(stall.streamed_bytes, 4_096);
        assert!(stall.alerted);

        let after_origin = origin() + Duration::from_secs(10_000);
        let mut after = StatusEngine::new(after_origin, agent_facts());
        after.seed("working", Some(&clocks), after_origin);

        let restored = after.stall_probe().expect("the window survived");
        assert_eq!(
            after_origin.saturating_duration_since(restored.window_start),
            Duration::from_secs(900)
        );
        assert!(restored.alerted, "the latch crosses, so one window alerts once");
        // The baseline deliberately does not cross: this process cannot vouch
        // for a repo it did not watch, so the next tick re-captures — and a
        // capture does not move the window it is measured against.
        assert!(restored.baseline.is_none());
        assert!(matches!(
            after.stall_step(after_origin),
            StallStep::Capture { .. }
        ));
    }

    /// A blob from a daemon that predates the field carries no clocks, and the
    /// adopted session starts them fresh rather than failing to adopt.
    #[test]
    fn an_older_blob_with_no_clocks_still_adopts() {
        let mut engine = StatusEngine::new(origin(), agent_facts());
        engine.seed("working", None, at(0));
        assert_eq!(engine.state(), State::Working);
        assert_eq!(engine.sweep_stale_working(at(5)), None);
        assert!(engine.sweep_stale_working(at(20)).is_some());
    }

    /// An idle session has no clocks worth carrying, so the blob does not grow
    /// a field for every quiet row on the box.
    #[test]
    fn a_quiet_session_carries_nothing() {
        let engine = StatusEngine::new(origin(), agent_facts());
        assert!(engine.carried_clocks(at(10)).is_none());
    }

    #[test]
    fn argv_resolves_a_hand_started_agent() {
        let catalog = AgentCatalog::load_from(None);
        let facts = resolve_facts(&catalog, None, Some(&["/usr/local/bin/claude".to_string()]));
        assert_eq!(facts.agent_id.as_deref(), Some("claudeCode"));
        let shell = resolve_facts(&catalog, None, Some(&["/bin/zsh".to_string()]));
        assert_eq!(shell.agent_id, None);
    }
}
