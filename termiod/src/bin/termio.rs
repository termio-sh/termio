//! termio — the command a person types. `termiod` is the daemon, like
//! `dockerd`; this client drives the Mac app and the session host
//! (docker-lessons RFC §1).
//!
//! Argument parsing is clap, like `termiod`'s. The hand-rolled dispatcher
//! this replaces was a faithful port of `scripts/termio`, and it inherited
//! the shell client's two parsing defects: a `case` that matched exact flag
//! strings swallowed any unrecognized `--flag` into the payload (so
//! `spawn "hi" --agnet codex` ran on the default agent, silently, exit 0),
//! and `--flag=value` was never a form it understood. Both are structural in
//! clap. A payload that genuinely starts with `--` stays expressible after
//! the `--` separator.
//!
//! What clap could not express stays hand-rolled, in the dispatch below
//! rather than the parser: `termio [DIR]` treats any non-verb first argument
//! as a directory (the `code .` shape, an `external_subcommand`), `--host`
//! re-runs the typed words on another machine, and `send`'s first positional
//! is a target only if it looks like an address.
//!
//! The per-verb prose is the shell client's, verbatim, carried as clap
//! `long_about`. `termiod/tests/cli_compat.py` still holds the wire bytes,
//! the exit codes and the JSON shapes against the shell client; it no longer
//! diffs help text or error wording, which are this client's own.

use anyhow::{bail, Context, Result};
use clap::{Args, CommandFactory, FromArgMatches, Parser, Subcommand, ValueEnum};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use termiod::app_socket::{self, Outcome};
use termiod::channel::{self, Channel};
use termiod::{lifecycle, version};

/// The root help lists commands by what they act on, the way Rex's does;
/// clap has one heading for all subcommands, so the list is written here. A
/// test holds it to the visible subcommands.
const ROOT_TEMPLATE: &str = "\
{about-with-newline}
{usage-heading} {usage}

Common, each short for `termio session <command>`:
  ls          List this project's sessions and their status
  spawn       Start a new agent session on a prompt
  run         Start a new terminal session that runs a shell command
  send        Type text into a session, then press Return
  read        Print a session's screen
  attach      Attach this terminal to a session
  close       Close sessions and end their programs

Sessions:
  session     List, start, drive and close sessions [alias: sessions]
  agent       Report an agent's status; install or remove agent hooks
  skill       Print or install the skill that teaches agents termio
  notify      Post a macOS notification from an agent

Machines:
  server      A machine's termiod: status, logs, deploy, service, Tailscale
  update      Update this machine's termio to the newest release
  pair        Print the link that pairs a phone or a browser
  view        This machine's projects and how their sessions are grouped

App:
  open        Open DIR (default: the current directory) as a project
  sim         Drive the iOS Simulator shown in the Simulator pane

Other:
  whoami      Show the session, channel and host this shell runs in
  version     Show the versions of this client, the app and termiod
  completion  Print a shell completion script
  help        Print help for a command

Options:
{options}{after-help}";

const ROOT_EXAMPLES: &str = "\
Examples:
  termio .
  termio ls
  termio spawn \"fix the failing test\" --agent codex
  termio send 8de0b387 \"run the tests\" --wait
  termio attach 8de0b387
  termio -H mybox ls
  termio -H mybox server deploy
  termio -H mybox update";

#[derive(Parser)]
#[command(
    name = "termio",
    about = "Run and supervise coding-agent sessions on your own machines.",
    help_template = ROOT_TEMPLATE,
    after_help = ROOT_EXAMPLES
)]
struct Cli {
    /// Run the command on this SSH host, with that machine's termio. HOST is
    /// an alias from `~/.ssh/config`, or user@host. It goes before the command.
    ///
    /// A root flag, not a global one: after the command word, `-H` is the
    /// verb's own text, such as a prompt that starts with `-H`.
    #[arg(short = 'H', long, value_name = "HOST")]
    host: Option<String>,

    #[command(subcommand)]
    verb: Option<Verb>,
}

#[derive(Subcommand)]
enum Verb {
    /// Open DIR (default: cwd) as a project.
    Open {
        #[arg(value_name = "DIR")]
        dir: Option<PathBuf>,
    },

    /// This machine's projects and how their sessions are grouped.
    View {
        /// Output the view as JSON.
        #[arg(long)]
        json: bool,
    },

    // The verbs typed most, one word shorter, the way Rex keeps `rex ls` and
    // `rex send` beside `rex session`. Each is exactly one `session` verb:
    // `into_session` turns it into that verb before anything else reads it.
    /// List this project's sessions and their status.
    #[command(alias = "list", long_about = LIST_HELP, after_help = LIST_EXAMPLES)]
    Ls(ListArgs),

    /// Start a new agent session on a prompt.
    #[command(long_about = SPAWN_HELP, after_help = SPAWN_EXAMPLES)]
    Spawn(SpawnArgs),

    /// Start a new terminal session that runs a shell command.
    #[command(long_about = RUN_HELP, after_help = RUN_EXAMPLES)]
    Run(RunArgs),

    /// Type text into a session, then press Return.
    #[command(long_about = SEND_HELP, after_help = SEND_EXAMPLES)]
    Send(SendArgs),

    /// Print a session's screen.
    #[command(long_about = READ_HELP, after_help = READ_EXAMPLES)]
    Read(ReadArgs),

    /// Attach this terminal to a session.
    #[command(long_about = ATTACH_HELP, after_help = ATTACH_EXAMPLES)]
    Attach(termiod::server::AttachArgs),

    /// Close sessions and end their programs.
    #[command(alias = "kill", long_about = CLOSE_HELP, after_help = CLOSE_EXAMPLES)]
    Close(CloseArgs),

    /// List, start, drive and close sessions.
    #[command(alias = "sessions", long_about = SESSION_HELP, after_help = SESSION_EXAMPLES)]
    Session {
        #[command(subcommand)]
        verb: Option<SessionVerb>,
    },

    /// Post a macOS notification from an agent.
    #[command(long_about = NOTIFY_HELP)]
    Notify(NotifyArgs),

    /// Report an agent's status; install or remove agent hooks.
    Agent {
        #[command(subcommand)]
        verb: AgentVerb,
    },

    /// Print or install the skill that teaches agents termio.
    #[command(long_about = SKILL_HELP, after_help = SKILL_EXAMPLES)]
    Skill {
        #[command(subcommand)]
        verb: SkillVerb,
    },

    /// Drive the iOS Simulator shown in the Simulator pane — look, tap, type.
    #[command(long_about = SIM_HELP)]
    Sim {
        #[command(subcommand)]
        verb: SimVerb,
    },

    /// Print the link that pairs a phone or a browser.
    ///
    /// The token in it authenticates the WebSocket pipe. It is not the session
    /// write token, and it never expires: `--rotate` is the only revocation.
    Pair(termiod::server::PairArgs),

    /// A machine's termiod: status, logs, deploy, service, Tailscale.
    ///
    /// This machine's by default; `termio -H <host> server …` acts on another.
    /// Sessions are `termio session`'s.
    Server(termiod::server::ServerArgs),

    /// Update this machine's termio to the newest release.
    ///
    /// On Linux: downloads termiod, termio and termio-tailnet for this CPU,
    /// checks each against the release's SHA256SUMS, puts them in place, and
    /// hands the running daemon off to the new build, so its sessions keep
    /// running. `termio -H <host> update` updates another machine. On a Mac,
    /// termio updates with the app.
    Update(termiod::update::UpdateArgs),

    /// Bridge the framed protocol over stdin/stdout to the local daemon.
    ///
    /// Non-interactive: no tty, no raw mode. Run as `ssh <host> termio stdio`,
    /// it lets a native client speak the same framed protocol to a remote host
    /// that it speaks to a local Unix socket. The daemon auto-starts.
    #[command(hide = true)]
    Stdio,

    /// Show the versions of this client, the app and termiod.
    ///
    /// One table: this client, the running app, this machine's termiod, and
    /// every remote as of its last connect.
    Version {
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Show the session, channel and host this shell runs in.
    #[command(long_about = WHOAMI_HELP)]
    Whoami {
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Print a shell completion script.
    ///
    /// For zsh: `termio completion zsh > ~/.zfunc/_termio`, with `~/.zfunc` on
    /// `fpath`. For bash: `termio completion bash > ~/.local/share/bash-completion/completions/termio`.
    Completion {
        #[arg(value_enum)]
        shell: clap_complete::Shell,
    },

    /// `termio [DIR]` — the `code .`-shaped shorthand for `open DIR`.
    #[command(external_subcommand)]
    Directory(Vec<String>),
}

#[derive(Subcommand)]
enum SessionVerb {
    /// List this project's sessions and their status.
    #[command(long_about = LIST_HELP, visible_alias = "ls", after_help = LIST_EXAMPLES)]
    List(ListArgs),

    /// Print status changes as they happen, until Ctrl-C.
    #[command(long_about = WATCH_HELP, after_help = WATCH_EXAMPLES)]
    Watch(WatchArgs),

    /// Start a new agent session on a prompt.
    #[command(long_about = SPAWN_HELP, after_help = SPAWN_EXAMPLES)]
    Spawn(SpawnArgs),

    /// Start a new terminal session that runs a shell command.
    #[command(long_about = RUN_HELP, after_help = RUN_EXAMPLES)]
    Run(RunArgs),

    /// Start a session on termiod that no app window shows.
    #[command(long_about = CREATE_HELP, after_help = CREATE_EXAMPLES)]
    Create(termiod::server::CreateArgs),

    /// Attach this terminal to a session.
    #[command(long_about = ATTACH_HELP, after_help = ATTACH_EXAMPLES)]
    Attach(termiod::server::AttachArgs),

    /// Type text into a session, then press Return.
    #[command(long_about = SEND_HELP, after_help = SEND_EXAMPLES)]
    Send(SendArgs),

    /// Deprecated, agent-only alias of `send`.
    #[command(long_about = SEND_HELP, hide = true)]
    Answer(SendArgs),

    /// Print a session's screen.
    #[command(long_about = READ_HELP, after_help = READ_EXAMPLES)]
    Read(ReadArgs),

    /// Close sessions and end their programs.
    #[command(alias = "kill", long_about = CLOSE_HELP, after_help = CLOSE_EXAMPLES)]
    Close(CloseArgs),

    /// Show a session in the app.
    #[command(long_about = FOCUS_HELP)]
    Focus(FocusArgs),
}

#[derive(Subcommand)]
enum SimVerb {
    /// List simulators; `*` marks the one the Simulator pane shows.
    List(SimDevice),

    /// Open the Simulator pane on a device; boots it if needed. Run before building.
    Attach(SimDevice),

    /// Close the pane's live view of the device. The device keeps running.
    Detach(SimDevice),

    /// Install a built .app and launch it, replacing a running copy.
    Launch {
        /// The .app bundle, e.g. DerivedData/…/Debug-iphonesimulator/MyApp.app.
        #[arg(value_name = "APP")]
        app: PathBuf,
        /// The bundle identifier (default: read from the app's Info.plist).
        #[arg(long, value_name = "ID")]
        bundle_id: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Open a URL or deep link (myapp://…, https://…).
    OpenUrl {
        #[arg(value_name = "URL")]
        url: String,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Save the screen as a PNG and print its path.
    Screenshot {
        /// Where to write the PNG (default: a new file in the temp directory).
        #[arg(long, value_name = "PATH")]
        out: Option<PathBuf>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Print the frontmost app's accessibility tree, the element at X Y, or the
    /// first element matching --marker.
    #[command(long_about = SIM_INSPECT_HELP)]
    Inspect {
        #[arg(value_name = "X", requires = "y")]
        x: Option<f64>,
        #[arg(value_name = "Y")]
        y: Option<f64>,
        /// Print only the first element whose --match attribute contains this
        /// (case-sensitive), with its descendants.
        #[arg(long, value_name = "TEXT", conflicts_with = "x")]
        marker: Option<String>,
        /// What --marker is compared with.
        #[arg(long, value_name = "ATTRIBUTE", requires = "marker",
              value_parser = ["label", "value", "role", "id"])]
        r#match: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Tap at X Y (device points), or the element whose label contains --label.
    Tap {
        #[arg(value_name = "X", requires = "y", conflicts_with = "label")]
        x: Option<f64>,
        #[arg(value_name = "Y")]
        y: Option<f64>,
        /// Tap the first element whose label contains this (case-sensitive).
        #[arg(long, value_name = "TEXT")]
        label: Option<String>,
        /// Hold for this many seconds; over 0.5 is a long press.
        #[arg(long, value_name = "SECONDS")]
        duration: Option<f64>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Drag from X Y to X2 Y2 (device points). Starting within 4 points of an
    /// edge is the system edge gesture: back, notifications, Home, Control Center.
    Swipe {
        #[arg(value_name = "X")]
        x: f64,
        #[arg(value_name = "Y")]
        y: f64,
        #[arg(value_name = "X2")]
        x2: f64,
        #[arg(value_name = "Y2")]
        y2: f64,
        /// How long the drag takes, in seconds (default 0.3).
        #[arg(long, value_name = "SECONDS")]
        duration: Option<f64>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// One finger along a path: --points '[{"x":200,"y":600,"dt_ms":0},{"x":200,"y":300,"dt_ms":16},…]'.
    TouchPath {
        /// JSON samples; dt_ms (0–1000) is the delay before each, 30 s in all.
        #[arg(long, value_name = "JSON")]
        points: String,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Two fingers, for pinch and rotate: --points '[{"x1":…,"y1":…,"x2":…,"y2":…,"dt_ms":16},…]'.
    Touch2Path {
        #[arg(long, value_name = "JSON")]
        points: String,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Type text into the focused field — any language; non-US text is pasted.
    Text {
        #[arg(value_name = "TEXT", required = true)]
        words: Vec<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Press a key, or an editing command.
    Key {
        #[arg(value_name = "NAME", value_parser = [
            "return", "enter", "tab", "delete", "backspace", "forward-delete",
            "escape", "esc", "space", "up", "down", "left", "right",
            "home", "end", "page-up", "page-down",
            "select-all", "copy", "cut", "paste", "undo", "redo",
        ])]
        name: String,
        /// Press it this many times (1–20).
        #[arg(long, value_name = "N")]
        count: Option<u32>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Press a hardware button.
    Button {
        #[arg(value_name = "NAME", value_parser = [
            "home", "lock", "side", "siri", "volume-up", "volume-down", "apple-pay",
        ])]
        name: String,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Turn the device a quarter left or right, or to --orientation.
    Rotate {
        #[arg(value_name = "DIRECTION", value_parser = ["left", "right"], conflicts_with = "orientation")]
        direction: Option<String>,
        #[arg(long, value_name = "ORIENTATION",
              value_parser = ["portrait", "landscapeLeft", "landscapeRight", "portraitUpsideDown"])]
        orientation: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Print an app's log: the last 100 lines of the last 5 minutes by default.
    Logs {
        /// The app (default: the one `launch` last started on the device).
        #[arg(long, value_name = "ID")]
        bundle_id: Option<String>,
        /// How many lines, newest last (1–1000).
        #[arg(long, value_name = "N")]
        tail: Option<u32>,
        /// How far back to look, in minutes.
        #[arg(long, value_name = "MINUTES")]
        minutes: Option<u32>,
        /// Only lines after this cursor — the `next:` a previous read printed.
        #[arg(long, value_name = "CURSOR")]
        since: Option<String>,
        /// The least severe level to show.
        #[arg(long, value_name = "LEVEL", value_parser = ["debug", "info", "default", "error", "fault"])]
        level: Option<String>,
        /// Only lines containing this (case-insensitive).
        #[arg(long, value_name = "TEXT")]
        filter: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Summarise the app's latest crash on this device: exception, reason, crashed thread.
    CrashReport {
        #[arg(long, value_name = "ID")]
        bundle_id: Option<String>,
        #[command(flatten)]
        device: SimDevice,
    },

    /// Show or hide the on-screen keyboard (hiding connects the Mac's keyboard).
    Keyboard {
        #[arg(value_name = "STATE", value_parser = ["show", "hide"])]
        state: String,
        #[command(flatten)]
        device: SimDevice,
    },
}

#[derive(Args)]
struct SimDevice {
    /// The simulator to act on, by UDID or name (default: a booted one, see
    /// `termio sim --help`).
    #[arg(long, value_name = "DEVICE", global = true)]
    device: Option<String>,

    #[command(flatten)]
    output: Output,
}

#[derive(Subcommand)]
enum AgentVerb {
    /// Report this agent's activity to the session that owns it.
    Report(ReportArgs),

    /// Install status hooks and the termio skill for the agents on this machine.
    Install(termiod::server::InstallArgs),

    /// Remove every agent integration termio has installed on this machine.
    Uninstall {
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum SkillVerb {
    /// Print the skill this termio carries.
    Show {
        /// This Mac's skill, which teaches the app's commands, instead of a box's.
        #[arg(long)]
        this_mac: bool,
    },

    /// Install the skill, and only the skill, for the agents on this machine.
    Install(termiod::server::SkillInstallArgs),

    /// Remove the skill from every agent on this machine. Hooks stay.
    Uninstall {
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },
}

/// `--json` reads the same on every verb that answers, so it is declared once.
#[derive(Args)]
struct Output {
    /// Print the reply as JSON.
    #[arg(long)]
    json: bool,
}

impl Output {
    fn format(&self) -> &'static str {
        if self.json {
            "json"
        } else {
            "text"
        }
    }
}

/// One sync vocabulary: `--wait`/`--timeout` mean the same thing on every verb
/// that accepts them, and no other verb declares them, so a `--wait` on `list`
/// is a parse error rather than a flag that is silently ignored.
#[derive(Args)]
struct Wait {
    /// Return when the turn settles, with its status and transcript lines.
    #[arg(long)]
    wait: bool,

    /// Stop waiting after MS milliseconds (default 300000, 1000–600000).
    /// Implies --wait.
    #[arg(
        long,
        value_name = "MS",
        allow_hyphen_values = true,
        value_parser = parse_timeout
    )]
    timeout: Option<u64>,
}

impl Wait {
    /// A stated timeout is a wait, so `--timeout 5000` alone still blocks.
    fn waiting(&self) -> bool {
        self.wait || self.timeout.is_some()
    }
}

/// Placement only means something on a verb that creates a pane, so only
/// `spawn` and `run` carry it.
#[derive(Args)]
struct Placement {
    /// Where the new pane lands relative to yours.
    #[arg(long, value_enum)]
    direction: Option<Direction>,

    /// The new pane's share of the split (e.g. 0.25); a stated ratio holds
    /// against later spawns.
    #[arg(long, value_name = "0..1", value_parser = parse_ratio)]
    ratio: Option<String>,
}

#[derive(Clone, Copy, ValueEnum)]
enum Direction {
    Right,
    Down,
}

impl Direction {
    fn wire(self) -> &'static str {
        match self {
            Direction::Right => "right",
            Direction::Down => "down",
        }
    }
}

#[derive(Clone, Copy, ValueEnum)]
enum AgentState {
    Working,
    Attention,
    Done,
    Idle,
}

impl AgentState {
    fn wire(self) -> &'static str {
        match self {
            AgentState::Working => "working",
            AgentState::Attention => "attention",
            AgentState::Done => "done",
            AgentState::Idle => "idle",
        }
    }
}

#[derive(Args)]
struct ListArgs {
    /// Every session this machine's termiod hosts, in every project.
    #[arg(long)]
    all: bool,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct WatchArgs {
    /// Comma-separated states to report (working, idle, done, needs-you,
    /// stalled).
    #[arg(long, value_name = "STATES", default_value = "")]
    state: String,

    /// Skip the initial per-session status snapshot.
    #[arg(long)]
    no_snapshot: bool,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct SpawnArgs {
    /// The prompt, e.g. `termio session spawn "fix the build"`.
    #[arg(value_name = "PROMPT", required = true)]
    words: Vec<String>,

    /// Agent to start (e.g. claudeCode, codex, grok, pi; default: caller's kind).
    #[arg(long, value_name = "ID")]
    agent: Option<String>,

    #[command(flatten)]
    placement: Placement,

    #[command(flatten)]
    wait: Wait,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct RunArgs {
    /// The shell command, e.g. `termio session run "pnpm dev"`.
    #[arg(value_name = "COMMAND", required = true)]
    words: Vec<String>,

    #[command(flatten)]
    placement: Placement,

    #[command(flatten)]
    wait: Wait,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct SendArgs {
    /// The session, then the text. Text alone starts a new agent, like `spawn`.
    #[arg(value_name = "SESSION|TEXT", required = true)]
    words: Vec<String>,

    /// Press this key after the text, such as escape, up or ctrl-c.
    /// Repeatable. Drops the Return.
    #[arg(long = "key", value_name = "NAME")]
    keys: Vec<String>,

    /// Type the text with no Return after it.
    #[arg(long)]
    no_enter: bool,

    #[command(flatten)]
    wait: Wait,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct ReadArgs {
    /// The session: a link, an id, an id prefix or a name.
    #[arg(value_name = "SESSION")]
    session: String,

    /// Keep only the last N screen rows.
    #[arg(long, value_name = "N")]
    lines: Option<u64>,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct CloseArgs {
    /// The sessions: links, ids, id prefixes or names.
    #[arg(value_name = "SESSION", required = true)]
    sessions: Vec<String>,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct FocusArgs {
    /// The session: a link, an id or an id prefix.
    #[arg(value_name = "SESSION")]
    session: String,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct NotifyArgs {
    #[arg(value_name = "MESSAGE", required = true)]
    words: Vec<String>,

    /// Override the banner's title (the default is the calling agent's name).
    #[arg(long, value_name = "TITLE")]
    title: Option<String>,

    #[command(flatten)]
    output: Output,
}

/// `read`'s daemon half. `None` means the target is not a session the local
/// daemon owns and the app should answer instead; `Some(code)` means the
/// reply (success or error) was printed here.
async fn daemon_read(
    channel: &Channel,
    target: &str,
    lines: Option<u64>,
    format: &str,
) -> Option<i32> {
    let token = read_token(channel, target)?;
    let token_lower = token.to_lowercase();
    // Daemon-first claims only the canonical app-created population:
    // sessions whose daemon name is a UUID, matched by a hex/dash token. An
    // adopted session keeps whatever name it had, which the app may scope
    // and resolve differently — those targets stay with the app.
    if token_lower.is_empty()
        || !token_lower.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
    {
        return None;
    }
    let listing = tokio::time::timeout(
        termiod::server::LOOKUP_TIMEOUT,
        termiod::client::sessions_of_running_daemon(),
    );
    let sessions = match listing.await {
        Ok(Ok(Some(sessions))) => sessions,
        // A stalled daemon has had its time: with no app to answer instead,
        // that is the reply, not a second wait.
        Err(_) if !app_running(channel) => {
            control_error_reply(
                format,
                "daemon",
                &format!("termiod did not answer within {}s", termiod::server::LOOKUP_TIMEOUT.as_secs()),
            );
            return Some(1);
        }
        _ => return None,
    };
    // A session named exactly the token is that session, as `send` and
    // `close` resolve it, unless the name is an app session's own UUID.
    if sessions
        .iter()
        .any(|info| info.name == token && !uuid_shaped(&info.name.to_lowercase()))
    {
        return None;
    }
    let matches: Vec<&termiod::protocol::SessionInfo> = sessions
        .iter()
        .filter(|info| {
            let name = info.name.to_lowercase();
            uuid_shaped(&name)
                && (name == token_lower || (token_lower.len() >= 8 && name.starts_with(&token_lower)))
        })
        .collect();
    match matches.len() {
        0 => None,
        1 => Some(serve_daemon_read(channel, matches[0], lines, format).await),
        _ => {
            control_error_reply(
                format,
                "ambiguous",
                &format!("'{target}' matches more than one session; use a longer id."),
            );
            Some(1)
        }
    }
}

/// The token to match against daemon session names: a bare id as-is, this
/// channel's own `…://session/<id>` link stripped to the id the way the
/// app's `addressedID` does — case-insensitively, taking the component
/// after `session/` and stopping at `/` or `?`. A foreign channel's link
/// (and any other shape) stays with the app, which owns its error copy.
fn read_token(channel: &Channel, target: &str) -> Option<String> {
    let lowered = target.to_lowercase();
    let Some(scheme_end) = lowered.find("://") else {
        return Some(target.to_string());
    };
    if lowered[..scheme_end] != channel.url_scheme() {
        return None;
    }
    let rest = &lowered[scheme_end + 3..];
    let after = rest.find("session/").map(|index| &rest[index + 8..])?;
    let id: String = after
        .chars()
        .take_while(|character| *character != '/' && *character != '?')
        .collect();
    (!id.is_empty()).then_some(id)
}

/// The 8-4-4-4-12 shape of an app-created session's daemon name.
fn uuid_shaped(name: &str) -> bool {
    name.len() == 36
        && name.char_indices().all(|(index, character)| match index {
            8 | 13 | 18 | 23 => character == '-',
            _ => character.is_ascii_hexdigit(),
        })
}

async fn serve_daemon_read(
    channel: &Channel,
    info: &termiod::protocol::SessionInfo,
    lines: Option<u64>,
    format: &str,
) -> i32 {
    let mut rows =
        match termiod::client::observe_screen_rows(&info.id, info.rows, info.cols).await {
            Ok(rows) => rows,
            Err(error) => {
                control_error_reply(format, "daemon", &format!("{error:#}"));
                return 1;
            }
        };
    if let Some(cap) = lines.map(|cap| cap as usize).filter(|cap| *cap > 0) {
        if rows.len() > cap {
            rows = rows.split_off(rows.len() - cap);
        }
    }
    let screen = rows.join("\n");
    if format == "json" {
        let mut object = std::collections::BTreeMap::new();
        object.insert("ok", serde_json::Value::Bool(true));
        object.insert("schema_version", serde_json::Value::from(1));
        object.insert("screen", serde_json::Value::from(screen));
        object.insert(
            "target",
            serde_json::Value::from(if uuid_shaped(&info.name.to_lowercase()) {
                format!("{}://session/{}", channel.url_scheme(), info.name.to_lowercase())
            } else {
                info.id.clone()
            }),
        );
        object.insert("title", serde_json::Value::from(read_title(info)));
        match serde_json::to_string(&object) {
            Ok(reply) => println!("{reply}"),
            Err(error) => {
                control_error_reply(format, "daemon", &format!("{error}"));
                return 1;
            }
        }
    } else {
        println!("{}", if screen.is_empty() { "(blank screen)" } else { &screen });
    }
    0
}

/// The best name the daemon knows: the agent-reported title, else the live
/// foreground program, else the spawned command, else the placeholder every
/// bare shell gets. The app's own `read` answers with its richer display
/// title; the daemon plane reports what the roster carries.
fn read_title(info: &termiod::protocol::SessionInfo) -> String {
    if let Some(title) = info.title.as_deref().filter(|title| !title.is_empty()) {
        return title.to_string();
    }
    let program = info
        .foreground_argv
        .as_ref()
        .and_then(|argv| argv.first())
        .map(String::as_str)
        .or_else(|| info.command.split_whitespace().next())
        .unwrap_or("");
    let program = program.rsplit('/').next().unwrap_or(program);
    if program.is_empty() {
        "Terminal".to_string()
    } else {
        program.to_string()
    }
}

/// An error in the app's own reply shape, so both halves of the router speak
/// one contract to scripts.
fn control_error_reply(format: &str, code: &str, message: &str) {
    if format == "json" {
        let mut object = std::collections::BTreeMap::new();
        object.insert("error", serde_json::Value::from(code));
        object.insert("message", serde_json::Value::from(message));
        object.insert("ok", serde_json::Value::Bool(false));
        object.insert("schema_version", serde_json::Value::from(1));
        if let Ok(reply) = serde_json::to_string(&object) {
            println!("{reply}");
        }
    } else {
        println!("error: {message}");
    }
}
/// The public hook contract: the flags keep their names because users
/// hand-write hooks against them. Every one forwards to `termio agent report`,
/// which declares the same names and reads the same stdin blob, so the payload
/// is parsed once — by whichever binary the hook actually invoked.
#[derive(Args)]
struct ReportArgs {
    #[arg(value_enum)]
    state: AgentState,

    /// Read stdin as the host's JSON payload and forward its transcript path.
    #[arg(long)]
    transcript: bool,

    /// Forward this conversation id verbatim.
    #[arg(long, value_name = "ID")]
    conversation: Option<String>,

    /// Mine the conversation id from this stdin field.
    #[arg(long, value_name = "FIELD")]
    conversation_from: Option<String>,

    /// Mine the running tool's name from this stdin field.
    #[arg(long, value_name = "FIELD")]
    tool_from: Option<String>,

    /// Mine a first-prompt title candidate from this stdin field.
    #[arg(long, value_name = "FIELD")]
    prompt_title_from: Option<String>,

    /// Stay silent on stdout and print `{}` at the end, for agents (Cursor)
    /// that read a hook's stdout as its JSON reply.
    #[arg(long)]
    reply: bool,
}

/// Digits only: `parse` alone would also take a leading `+`, and
/// `allow_hyphen_values` lets `--timeout -5` reach this instead of being read
/// as a flag — both are the shell client's rejections, kept.
fn parse_timeout(raw: &str) -> Result<u64, String> {
    if raw.is_empty() || !raw.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("whole milliseconds, digits only".to_string());
    }
    raw.parse::<u64>()
        .map_err(|_| "whole milliseconds, digits only".to_string())
}

/// Strictly `0.<digits>` — anything else (".5", "0.", "50%") would land on the
/// wire as invalid JSON or a share the app rejects. Kept as the string the
/// caller typed, because that is what goes on the wire.
fn parse_ratio(raw: &str) -> Result<String, String> {
    let valid = raw
        .strip_prefix("0.")
        .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()));
    if valid {
        Ok(raw.to_string())
    } else {
        Err("a number between 0 and 1, e.g. 0.25".to_string())
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // Rust ignores SIGPIPE and turns a closed pipe into a stdout panic; a CLI
    // whose output feeds `head` must die silently there, like the shell
    // client it replaces.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let (channel, provenance) = channel::resolve();

    // `--version` names the channel it drives, which is only known once
    // argv[0] has been read — so the version string is bound here rather than
    // in the derive.
    let version_line: &'static str = Box::leak(
        format!("{} ({})", lifecycle::BUILD_VERSION, channel.name).into_boxed_str(),
    );
    let command = Cli::command().version(version_line);
    let mut cli = Cli::from_arg_matches(&command.get_matches())?;
    cli.verb = cli.verb.map(into_session);

    let host = match &cli.verb {
        Some(Verb::Server(args)) => cli.host.clone().or_else(|| args.host.clone()),
        _ => cli.host.clone(),
    };
    if let Some(host) = host {
        return on_host(host, cli.verb).await;
    }

    match cli.verb {
        None => open_project(&channel, Path::new(".")).await,
        Some(Verb::Open { dir }) => {
            open_project(&channel, dir.as_deref().unwrap_or(Path::new("."))).await
        }
        Some(Verb::Directory(words)) => {
            let directory = words.first().map(String::as_str).unwrap_or(".");
            if !Path::new(directory).exists() && !path_shaped(directory) {
                unknown_command(directory)
            }
            open_project(&channel, Path::new(directory)).await
        }
        Some(Verb::View { json }) => print_view(json).await,
        Some(Verb::Version { json }) => version::print_table(&channel, provenance, json).await,
        Some(Verb::Whoami { json }) => whoami(&channel, json).await,
        Some(Verb::Skill { verb }) => match verb {
            SkillVerb::Show { this_mac } => {
                print!("{}", termiod::server::skill_text(this_mac));
                Ok(())
            }
            SkillVerb::Install(args) => termiod::server::install_skill(args).await,
            SkillVerb::Uninstall { json } => termiod::server::uninstall_skill(json).await,
        },
        Some(Verb::Completion { shell }) => {
            let mut command = Cli::command();
            let name = command.get_name().to_string();
            clap_complete::generate(shell, &mut command, name, &mut std::io::stdout());
            Ok(())
        }
        Some(Verb::Pair(args)) => termiod::server::pair(args),
        Some(Verb::Server(args)) => termiod::server::run(args, None).await,
        Some(Verb::Update(args)) => termiod::update::run(args).await,
        Some(Verb::Stdio) => termiod::client::stdio().await,
        Some(Verb::Agent { verb }) => match verb {
            AgentVerb::Report(args) => agent_report(args).await,
            AgentVerb::Install(args) => termiod::server::install_agents(args).await,
            AgentVerb::Uninstall { json } => termiod::server::uninstall_agents(json).await,
        },
        Some(Verb::Notify(args)) => notify(&channel, args),
        Some(Verb::Sim { verb }) => simulator(&channel, verb),
        Some(
            Verb::Ls(_)
            | Verb::Spawn(_)
            | Verb::Run(_)
            | Verb::Send(_)
            | Verb::Read(_)
            | Verb::Attach(_)
            | Verb::Close(_),
        ) => bail!("a session shortcut reached dispatch without becoming its session verb"),
        Some(Verb::Session { verb }) => {
            sessions(
                &channel,
                verb.unwrap_or(SessionVerb::List(ListArgs {
                    all: false,
                    output: Output { json: false },
                })),
            )
            .await
        }
    }
}

/// `termio -H <host> …`. `server deploy` runs its loop from here, because it
/// is what puts a build on the host. Everything else runs as the same words on
/// the host, so the host answers with its own build. Opening a project and
/// printing this binary's completions are about this machine, so they refuse.
async fn on_host(host: String, verb: Option<Verb>) -> Result<()> {
    use termiod::server::ServerCmd;
    // Only an interactive attach needs a terminal on the far side.
    let tty = match verb {
        None | Some(Verb::Open { .. }) | Some(Verb::Directory(_)) => {
            bail!("--host runs a command on another machine; opening a project happens on this one")
        }
        Some(Verb::Completion { .. }) => {
            bail!("--host runs a command on another machine; completions are for this one")
        }
        Some(Verb::Server(args)) => {
            if matches!(args.cmd, ServerCmd::Deploy { .. }) {
                return termiod::server::run(args, Some(host)).await;
            }
            matches!(&args.cmd, ServerCmd::Attach(attach) if !attach.observe)
        }
        Some(Verb::Session {
            verb: Some(SessionVerb::Attach(args)),
        }) => !args.observe,
        Some(_) => false,
    };
    termiod::server::run_on_host(&host, tty)
}

/// A top-level shortcut as the `session` verb it is short for; every other
/// command as it was parsed.
fn into_session(verb: Verb) -> Verb {
    let session = match verb {
        Verb::Ls(args) => SessionVerb::List(args),
        Verb::Spawn(args) => SessionVerb::Spawn(args),
        Verb::Run(args) => SessionVerb::Run(args),
        Verb::Send(args) => SessionVerb::Send(args),
        Verb::Read(args) => SessionVerb::Read(args),
        Verb::Attach(args) => SessionVerb::Attach(args),
        Verb::Close(args) => SessionVerb::Close(args),
        other => return other,
    };
    Verb::Session { verb: Some(session) }
}

/// Whether a word was meant as a path, so a missing one is reported as a
/// missing directory rather than as an unknown command.
fn path_shaped(word: &str) -> bool {
    word.contains('/') || word.starts_with('.') || word.starts_with('~')
}

/// `termio [DIR]` receives every word clap does not know, so a mistyped
/// command lands here. It is reported the way clap reports any other unknown
/// command: the same wording, the same tip, the same exit code 2.
fn unknown_command(word: &str) -> ! {
    use clap::error::{ContextKind, ContextValue, ErrorKind};
    let mut command = Cli::command();
    command.build();
    let mut error = clap::Error::new(ErrorKind::InvalidSubcommand).with_cmd(&command);
    error.insert(ContextKind::InvalidSubcommand, ContextValue::String(word.to_string()));
    let closest = command
        .get_subcommands()
        .filter(|sub| !sub.is_hide_set())
        .map(|sub| sub.get_name())
        .map(|name| (edit_distance(word, name), name))
        .filter(|(distance, name)| *distance <= (name.len() / 3).max(1))
        .min();
    if let Some((_, name)) = closest {
        error.insert(
            ContextKind::SuggestedSubcommand,
            ContextValue::Strings(vec![name.to_string()]),
        );
    }
    error.insert(
        ContextKind::Usage,
        ContextValue::StyledStr(command.render_usage()),
    );
    error.exit()
}

fn edit_distance(left: &str, right: &str) -> usize {
    let right: Vec<char> = right.chars().collect();
    let mut previous: Vec<usize> = (0..=right.len()).collect();
    for (row, left_char) in left.chars().enumerate() {
        let mut current = vec![row + 1];
        for (column, right_char) in right.iter().enumerate() {
            let substitution = previous[column] + usize::from(left_char != *right_char);
            current.push(substitution.min(previous[column + 1] + 1).min(current[column] + 1));
        }
        previous = current;
    }
    previous[right.len()]
}

/// `termio whoami`: where this shell runs, from what the session stamped into
/// its environment. The project, group and pane come from the host's view,
/// asked only when this shell is a termiod session, and over a connection that
/// never starts a daemon to answer a question about one.
async fn whoami(channel: &Channel, json: bool) -> Result<()> {
    let variable = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
    let session = variable("TERMIO_SESSION")
        .map(|id| format!("{}://session/{}", channel.url_scheme(), id.to_lowercase()));
    let host_session = variable("TERMIOD_SESSION_ID");
    let socket = termiod::paths::socket_path()?;

    let mut placement = None;
    if let Some(id) = &host_session {
        // The other fields stand on their own, so a host too old to answer
        // `view`, or too wedged to answer at all, costs only the placement,
        // said on stderr.
        let lookup = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            termiod::client::running_view(),
        );
        match lookup.await {
            Ok(Ok(Some(view))) => placement = place_in_view(&view, id),
            Ok(Ok(None)) => {}
            Ok(Err(error)) => eprintln!("termio: the host did not answer with its view: {error:#}"),
            Err(_) => eprintln!("termio: the host did not answer with its view within 2s"),
        }
    }
    let (project, group, pane) = match placement {
        Some((project, group, pane)) => (project, Some(group), Some(pane)),
        None => (None, None, None),
    };

    let host = host_name();
    let app = app_running(channel);
    let reply = serde_json::json!({
        "session": session,
        "host_session": host_session,
        "project": project,
        "group": group,
        "pane": pane,
        "host": host,
        "channel": channel.name,
        "app_running": app,
        "socket": socket.display().to_string(),
    });
    if json {
        println!("{}", serde_json::to_string_pretty(&reply)?);
        return Ok(());
    }
    let show = |value: &Option<String>| value.clone().unwrap_or_else(|| "none".to_string());
    println!("session:      {}", show(&session));
    println!("host session: {}", show(&host_session));
    println!("project:      {}", show(&project));
    println!("group:        {}", show(&group));
    println!("pane:         {}", show(&pane));
    println!("host:         {}", show(&host));
    println!("channel:      {}", channel.name);
    println!("app:          {}", if app { "running" } else { "not running" });
    println!("socket:       {}", socket.display());
    Ok(())
}

/// The project path, group id and pane id that hold the host session `id`.
/// A loose group has no project.
fn place_in_view(
    view: &termiod::view::View,
    id: &str,
) -> Option<(Option<String>, String, String)> {
    let holds = |group: &termiod::view::Group| {
        group.panes().into_iter().find_map(|pane| match &pane.kind {
            termiod::view::PaneKind::Terminal { session } if session == id => {
                Some((group.id.clone(), pane.id.clone()))
            }
            _ => None,
        })
    };
    for project in &view.projects {
        if let Some((group, pane)) = project.groups.iter().find_map(holds) {
            return Some((Some(project.path.clone()), group, pane));
        }
    }
    view.loose
        .iter()
        .find_map(holds)
        .map(|(group, pane)| (None, group, pane))
}

fn host_name() -> Option<String> {
    let mut buffer = [0u8; 256];
    let result = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if result != 0 {
        return None;
    }
    let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
    String::from_utf8(buffer[..end].to_vec()).ok()
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1);
}

fn exit_outcome(outcome: Outcome) -> ! {
    std::process::exit(match outcome {
        Outcome::Ok => 0,
        Outcome::Error => 1,
        Outcome::Timeout => 3,
    })
}

/// The words a verb collected, joined the way the shell client joined them:
/// one space between argv items, so `spawn fix the build` and
/// `spawn "fix the build"` put the same bytes on the wire.
fn join(words: &[String]) -> String {
    words.join(" ")
}

/// One request per verb. Everything that decides *what* goes on the wire lives
/// here; clap has already decided that the flags are spellable at all.
async fn sessions(channel: &Channel, verb: SessionVerb) -> Result<()> {
    // The app is contacted only once argv is fully diagnosed. clap has already
    // rejected what it can see; the checks below are the ones that need to
    // know which verb they are on, and they run before the request for the
    // same reason — a malformed command should say so, not report that the
    // app is down.
    //
    // The app answers whenever it runs, and its project scope and Session
    // control switch hold. termiod answers only when there is no app: the
    // request reached no one, so the termiod half cannot act twice.
    let mut agent = String::new();
    let mut extra = String::new();
    let mut client_timeout = app_socket::client_timeout();

    let (operation, output, target, text, fallback) = match verb {
        SessionVerb::List(args) if args.all => {
            daemon_reply(args.output.format(), termiod::server::list_sessions(args.output.json, true).await);
        }

        // Without an app there is no project, so `ls` lists what termiod
        // holds — the same as `--all`.
        SessionVerb::List(args) => ("list", args.output, String::new(), String::new(), Fallback::List),

        SessionVerb::Watch(args) => {
            // Exit codes tell a supervising agent how the watch ended: Ctrl-C
            // is the normal end of supervision (0, via the handler); an
            // immediate error reply (control disabled, no scope) is 1; the
            // stream reaching EOF means the *app* closed it — 2, "termio
            // died", the case to escalate.
            unsafe {
                libc::signal(libc::SIGINT, watch_interrupted as usize);
            }
            app_socket::require_socket(channel);
            let snapshot = if args.no_snapshot {
                "\"snapshot\":false"
            } else {
                ""
            };
            let code = app_socket::watch(channel, args.output.format(), &args.state, snapshot);
            if code == 2 {
                eprintln!("termio: watch stream closed by the app (termio quit or died)");
            }
            std::process::exit(code);
        }

        SessionVerb::Create(args) => {
            let format = if args.json { "json" } else { "text" };
            daemon_reply(format, termiod::server::create_session(args, None).await);
        }

        SessionVerb::Attach(args) => {
            daemon_reply("text", termiod::server::attach_session(args).await);
        }

        SessionVerb::Close(args) => {
            // One request per tab; any failure fails the whole command, but
            // every target still gets its attempt and its own reply line. A
            // target carrying whitespace splits, the way the shell client's
            // unquoted expansion split it.
            let format = args.output.format();
            let mut failed = 0;
            for target in args.sessions.iter().flat_map(|word| word.split_whitespace()) {
                let reply = app_socket::request_reply(
                    channel,
                    client_timeout,
                    "close",
                    format,
                    target,
                    "",
                    "",
                    "",
                );
                let outcome = match on_termiod(&reply, target).await {
                    Err((code, message)) => {
                        control_error_reply(format, &code, &message);
                        Outcome::Error
                    }
                    Ok(Some(info)) => {
                        match termiod::server::close_session(&info.id, args.output.json).await {
                            Ok(()) => Outcome::Ok,
                            Err(error) => {
                                control_error_reply(format, "daemon", &format!("{error:#}"));
                                Outcome::Error
                            }
                        }
                    }
                    Ok(None) => app_socket::finish(reply, format, ""),
                };
                if outcome != Outcome::Ok {
                    failed = 1;
                }
            }
            std::process::exit(failed);
        }

        SessionVerb::Focus(args) => ("focus", args.output, args.session, String::new(), Fallback::None),

        SessionVerb::Read(args) => {
            // Device verb, daemon first (unify-server-plane Stage 10): a
            // session the local daemon hosts answers from its authoritative
            // VT — including sessions no window ever opened, and boxes with
            // no app at all. A target the daemon does not own (a session on
            // a remote device, an app-side title match, a foreign-channel
            // link) goes to the app, which keeps its coverage.
            if let Some(code) =
                daemon_read(channel, &args.session, args.lines, args.output.format()).await
            {
                std::process::exit(code);
            }
            if let Some(lines) = args.lines {
                extra = format!("\"lines\":{lines}");
            }
            let fallback = Fallback::Read { lines: args.lines };
            ("read", args.output, args.session, String::new(), fallback)
        }

        // `spawn` and the no-target `send` alias both start a fresh session:
        // the app spawns whenever a `send` request carries an empty target.
        SessionVerb::Spawn(args) => {
            // One job, one entry point: spawn creates agents, run creates
            // terminals. The wire cannot tell `spawn --agent terminal` from
            // `run` (both arrive as an empty-target send with the shell
            // pinned), so the split is enforced here, where the user's intent
            // is still visible.
            if let Some(named) = &args.agent {
                if named.eq_ignore_ascii_case("terminal") || named.eq_ignore_ascii_case("shell") {
                    fail("termio: spawn starts agents — for a plain terminal running a command, use `termio session run \"<command>\"`");
                }
                agent = named.clone();
            }
            placement(&mut extra, &args.placement);
            waiting(&mut extra, &args.wait, &mut client_timeout);
            ("send", args.output, String::new(), join(&args.words), Fallback::None)
        }

        // `run` is the same spawn with the agent pinned to the plain shell —
        // the payload is a command line, not a prompt.
        SessionVerb::Run(args) => {
            agent = "terminal".to_string();
            let fallback = Fallback::Run {
                line: join(&args.words),
                app_only: args.wait.waiting()
                    || args.placement.direction.is_some()
                    || args.placement.ratio.is_some(),
            };
            placement(&mut extra, &args.placement);
            waiting(&mut extra, &args.wait, &mut client_timeout);
            ("send", args.output, String::new(), join(&args.words), fallback)
        }

        SessionVerb::Send(args) | SessionVerb::Answer(args) => {
            let format = args.output.format();
            // A leading address targets an existing session. Without one,
            // `send` is a back-compat alias for `spawn`; the strict is_address
            // shape check keeps a prompt that merely opens with a word from
            // being mistaken for an address. With no app there is no spawn
            // to fall back on, so a name that termiod holds addresses it.
            let mut addressed = app_socket::is_address(&args.words[0]);
            if !addressed {
                // Asked in this order so the app is probed only when termiod
                // does hold a session by that name: a probe is a connection
                // the app answers. With a socket file, the lookup is brief,
                // because it delays every prompt sent to the app; with none,
                // there is no app and it gets the full lookup time.
                let lookup = if app_socket::socket_path(channel).exists() {
                    std::time::Duration::from_secs(1)
                } else {
                    termiod::server::LOOKUP_TIMEOUT
                };
                let mut found = termiod::server::resolve_running(&args.words[0], lookup).await;
                // Probed once, and only when the answer matters: a probe is a
                // connection the app answers.
                let mut app = None;
                let mut app_up = || *app.get_or_insert_with(|| app_running(channel));
                // A socket file the app left behind is no app: the lookup
                // then gets its full time.
                if found.is_err() && lookup < termiod::server::LOOKUP_TIMEOUT && !app_up() {
                    found = termiod::server::resolve_running(&args.words[0], termiod::server::LOOKUP_TIMEOUT).await;
                }
                match found {
                    Ok(found) => addressed = found.is_some() && !app_up(),
                    Err(error) if !app_up() => {
                        let (code, message) = lookup_error(&error);
                        refuse(format, code, &message)
                    }
                    Err(_) => {}
                }
            }
            let (target, words) = if addressed {
                (args.words[0].clone(), &args.words[1..])
            } else {
                (String::new(), &args.words[..])
            };

            // --no-enter and --key only read on a send to an existing session:
            // a spawn's prompt has to be submitted or the fresh agent just
            // sits on a filled composer, and a key is pressed against a TUI
            // that is already drawn, which a booting agent has none of.
            if args.no_enter {
                if target.is_empty() {
                    fail("termio: --no-enter needs a session to send to");
                }
                push(&mut extra, "\"enter\":false");
            }
            if !args.keys.is_empty() {
                if target.is_empty() {
                    fail("termio: --key needs a session to press it in");
                }
                // Order matters — the app presses them in the order named — so
                // they accumulate into a JSON array rather than a set. The
                // name itself is validated by the app, the one place that
                // knows the vocabulary.
                let names: Vec<String> = args
                    .keys
                    .iter()
                    .map(|key| format!("\"{}\"", app_socket::json_escape(key)))
                    .collect();
                push(&mut extra, &format!("\"keys\":[{}]", names.join(",")));
            }
            let fallback = Fallback::Send {
                first: args.words[0].clone(),
                enter: !args.no_enter,
                app_only: !args.keys.is_empty() || args.wait.waiting(),
            };
            waiting(&mut extra, &args.wait, &mut client_timeout);
            ("send", args.output, target, join(words), fallback)
        }
    };

    let format = output.format();
    let reply = app_socket::request_reply(
        channel,
        client_timeout,
        operation,
        format,
        &target,
        &agent,
        &text,
        &extra,
    );
    let no_app = matches!(reply, app_socket::Reply::NoApp(..));
    match fallback {
        Fallback::List if no_app => {
            daemon_reply(format, termiod::server::list_sessions(output.json, true).await);
        }
        // With no app to show a pane, the command runs in a session on
        // termiod, typed into a login shell as the app types it.
        Fallback::Run { line, app_only } if no_app => {
            if app_only {
                refuse(format, "needs_app", "--wait, --direction and --ratio need the Termio app, and it is not running");
            }
            let create = termiod::server::CreateArgs {
                name: None,
                cwd: std::env::current_dir()
                    .ok()
                    .map(|directory| directory.display().to_string()),
                json: output.json,
                argv: Vec::new(),
            };
            daemon_reply(format, termiod::server::run_session(create, line).await);
        }
        // An unaddressed send starts an agent, which only the app can do.
        Fallback::Send { first, .. } if target.is_empty() && no_app => refuse(
            format,
            "not_found",
            &format!("no session matches '{first}', and starting an agent needs the Termio app, which is not running"),
        ),
        Fallback::Send { enter, app_only, .. } if !target.is_empty() => {
            match on_termiod(&reply, &target).await {
                Ok(Some(info)) => {
                    if app_only {
                        refuse(format, "needs_app", "--key and --wait need the Termio app, and it is not running");
                    }
                    if text.is_empty() {
                        refuse(format, "no_text", "send needs text to send.");
                    }
                    daemon_reply(
                        format,
                        termiod::server::send_to_session(&info.id, &text, enter, output.json).await,
                    );
                }
                Ok(None) => {}
                Err((code, message)) => refuse(format, &code, &message),
            }
        }
        Fallback::Read { lines } => match on_termiod(&reply, &target).await {
            Ok(Some(info)) => {
                std::process::exit(serve_daemon_read(channel, &info, lines, format).await)
            }
            Ok(None) => {}
            Err((code, message)) => refuse(format, &code, &message),
        },
        _ => {}
    }
    exit_outcome(app_socket::finish(reply, format, &extra));
}

/// What a verb does on termiod when there is no app.
enum Fallback {
    None,
    List,
    Run { line: String, app_only: bool },
    Send { first: String, enter: bool, app_only: bool },
    Read { lines: Option<u64> },
}

/// The termiod session to act on when `reply` found no app, or the error to
/// report as `(code, message)`. `Ok(None)` when there is an app: its reply is
/// the answer.
async fn on_termiod(
    reply: &app_socket::Reply,
    target: &str,
) -> Result<Option<termiod::protocol::SessionInfo>, (String, String)> {
    if !matches!(reply, app_socket::Reply::NoApp(..)) {
        return Ok(None);
    }
    match termiod::server::resolve_running(target, termiod::server::LOOKUP_TIMEOUT).await {
        Ok(Some(info)) => Ok(Some(info)),
        Ok(None) => Err(("not_found".to_string(), format!("no session matches '{target}'"))),
        Err(error) => {
            let (code, message) = lookup_error(&error);
            Err((code.to_string(), message))
        }
    }
}

/// The reply code for a failed lookup: `ambiguous` when the target matches
/// more than one session, `daemon` when termiod did not answer.
fn lookup_error(error: &anyhow::Error) -> (&'static str, String) {
    let code = if error.downcast_ref::<termiod::server::Ambiguous>().is_some() {
        "ambiguous"
    } else {
        "daemon"
    };
    (code, format!("{error:#}"))
}

fn placement(extra: &mut String, placement: &Placement) {
    if let Some(direction) = placement.direction {
        push(extra, &format!("\"direction\":\"{}\"", direction.wire()));
    }
    if let Some(ratio) = &placement.ratio {
        push(extra, &format!("\"ratio\":{ratio}"));
    }
}

fn waiting(extra: &mut String, wait: &Wait, client_timeout: &mut u64) {
    if !wait.waiting() {
        return;
    }
    push(extra, "\"wait\":true");
    if let Some(milliseconds) = wait.timeout {
        push(extra, &format!("\"timeout_ms\":{milliseconds}"));
    }
    // The client read bound must outlive the server-side wait (which the app
    // clamps to 1s–600s), or the read would hang up mid-wait and report a
    // false timeout. An explicit TERMIO_CLI_TIMEOUT still wins — the escape
    // hatch.
    if !app_socket::explicit_client_timeout() {
        *client_timeout = wait.timeout.unwrap_or(300_000) / 1000 + 30;
    }
}

fn push(extra: &mut String, fragment: &str) {
    if !extra.is_empty() {
        extra.push(',');
    }
    extra.push_str(fragment);
}

/// Whether there is an app, by the same rule a request uses: a socket file
/// is an app unless no process listens on it.
fn app_running(channel: &Channel) -> bool {
    match std::os::unix::net::UnixStream::connect(app_socket::socket_path(channel)) {
        Ok(_) => true,
        Err(error) => match error.kind() {
            std::io::ErrorKind::NotFound => false,
            std::io::ErrorKind::ConnectionRefused => {
                app_socket::has_listener(&app_socket::socket_path(channel))
            }
            _ => true,
        },
    }
}

/// Ends the command with an error in the reply contract, on stdout like the
/// app's own errors.
fn refuse(format: &str, code: &str, message: &str) -> ! {
    control_error_reply(format, code, message);
    std::process::exit(1);
}

/// Ends the command on a daemon call's result: an error in the app's reply
/// shape, so a script reads one contract whichever side answered.
fn daemon_reply(format: &str, result: Result<()>) -> ! {
    match result {
        Ok(()) => std::process::exit(0),
        Err(error) => {
            control_error_reply(format, "daemon", &format!("{error:#}"));
            std::process::exit(1);
        }
    }
}

extern "C" fn watch_interrupted(_: libc::c_int) {
    unsafe { libc::_exit(0) }
}

/// `termio agent report <state> …` — what every installed hook runs, on every
/// machine. The mining flags exist because a hook's host hands it a JSON blob
/// on stdin that nothing else sees, so mining here is what lets an agent carry
/// the transcript path, the conversation id, the running tool and a
/// first-prompt label.
async fn agent_report(args: ReportArgs) -> Result<()> {
    // A hook outside a termiod session has nothing to report to, and reporting
    // with an empty target is a call the daemon rejects. Silent, because hooks
    // fire constantly and a hook that talks is worse than one that does not.
    let session = std::env::var("TERMIOD_SESSION_ID").unwrap_or_default();
    let outcome = if session.is_empty() {
        Ok(())
    } else {
        let wants_stdin = args.transcript
            || args.conversation_from.is_some()
            || args.tool_from.is_some()
            || args.prompt_title_from.is_some();
        let payload = if wants_stdin { read_hook_payload() } else { None };
        let mined = |field: &Option<String>| -> Option<String> {
            mine_field(payload.as_ref()?, field.as_deref()?)
        };
        let details = termiod::protocol::StatusDetails {
            transcript_path: args
                .transcript
                .then(|| payload.as_ref().and_then(|p| mine_field(p, "transcript_path")))
                .flatten(),
            conversation_id: args.conversation.clone().or_else(|| mined(&args.conversation_from)),
            tool: mined(&args.tool_from),
            prompt_title: mined(&args.prompt_title_from),
        };
        termiod::client::set_status(&session, args.state.wire(), None, details).await
    };
    // Cursor reads a hook's stdout as its JSON reply, so the contract is an
    // empty object even when the report itself could not be delivered.
    if args.reply {
        print!("{{}}");
    }
    outcome
}

/// The host's JSON payload on stdin, or `None`. Never read from a tty: a hook
/// invoked without its payload piped in would wait on the terminal forever, and
/// a hook that hangs hangs the agent's turn with it.
fn read_hook_payload() -> Option<serde_json::Value> {
    use std::io::Read;
    if unsafe { libc::isatty(libc::STDIN_FILENO) } == 1 {
        return None;
    }
    let mut raw = String::new();
    std::io::stdin().read_to_string(&mut raw).ok()?;
    serde_json::from_str(&raw).ok()
}

/// One top-level string field of the hook payload.
///
/// Only a string, and only at the top level: a hook contract that quietly
/// started accepting nested paths would be a second dialect to keep in step.
fn mine_field(payload: &serde_json::Value, field: &str) -> Option<String> {
    payload
        .get(field)?
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

/// `termio notify [--title T] "<message>"` — post a macOS notification on
/// demand, routed through the running app so the banner wears termio's
/// identity and a click focuses the calling session.
fn notify(channel: &Channel, args: NotifyArgs) -> Result<()> {
    let body = join(&args.words);
    if body.is_empty() {
        fail("termio: notify needs a message (e.g. `termio notify \"tests passed\"`)");
    }
    app_socket::require_socket(channel);
    let extra = match &args.title {
        Some(title) => format!("\"title\":\"{}\"", app_socket::json_escape(title)),
        None => String::new(),
    };
    exit_outcome(app_socket::request_once(
        channel,
        app_socket::client_timeout(),
        "notify",
        args.output.format(),
        "",
        "",
        &body,
        &extra,
    ));
}

/// `termio sim <action>` — one request per action: the action in `target`, its
/// parameters as strings in `arguments`, and the text to type in `text`.
fn simulator(channel: &Channel, verb: SimVerb) -> Result<()> {
    let number = |value: f64| value.to_string();
    let mut arguments: Vec<(&str, String)> = Vec::new();
    let mut text = String::new();
    let (action, device) = match verb {
        SimVerb::List(device) => ("list", device),
        SimVerb::Attach(device) => ("attach", device),
        SimVerb::Detach(device) => ("detach", device),
        SimVerb::Launch { app, bundle_id, device } => {
            arguments.push(("app", app.display().to_string()));
            if let Some(id) = bundle_id {
                arguments.push(("bundle-id", id));
            }
            ("launch", device)
        }
        SimVerb::OpenUrl { url, device } => {
            arguments.push(("url", url));
            ("open-url", device)
        }
        SimVerb::Screenshot { out, device } => {
            if let Some(out) = out {
                arguments.push(("out", out.display().to_string()));
            }
            ("screenshot", device)
        }
        SimVerb::Inspect { x, y, marker, r#match, device } => {
            if let (Some(x), Some(y)) = (x, y) {
                arguments.push(("x", number(x)));
                arguments.push(("y", number(y)));
            }
            if let Some(marker) = marker {
                arguments.push(("marker", marker));
            }
            if let Some(key) = r#match {
                arguments.push(("match", key));
            }
            ("inspect", device)
        }
        SimVerb::Tap { x, y, label, duration, device } => {
            match (x, y, label) {
                (_, _, Some(label)) => arguments.push(("label", label)),
                (Some(x), Some(y), None) => {
                    arguments.push(("x", number(x)));
                    arguments.push(("y", number(y)));
                }
                _ => fail("termio: tap needs X Y or --label (e.g. `termio sim tap 200 400`)"),
            }
            if let Some(duration) = duration {
                arguments.push(("duration", number(duration)));
            }
            ("tap", device)
        }
        SimVerb::Swipe { x, y, x2, y2, duration, device } => {
            arguments.push(("x", number(x)));
            arguments.push(("y", number(y)));
            arguments.push(("x2", number(x2)));
            arguments.push(("y2", number(y2)));
            if let Some(duration) = duration {
                arguments.push(("duration", number(duration)));
            }
            ("swipe", device)
        }
        SimVerb::TouchPath { points, device } => {
            arguments.push(("points", points));
            ("touch-path", device)
        }
        SimVerb::Touch2Path { points, device } => {
            arguments.push(("points", points));
            ("touch2-path", device)
        }
        SimVerb::Text { words, device } => {
            text = join(&words);
            ("text", device)
        }
        SimVerb::Key { name, count, device } => {
            arguments.push(("name", name));
            if let Some(count) = count {
                arguments.push(("count", count.to_string()));
            }
            ("key", device)
        }
        SimVerb::Button { name, device } => {
            arguments.push(("name", name));
            ("button", device)
        }
        SimVerb::Rotate { direction, orientation, device } => {
            if let Some(orientation) = orientation {
                arguments.push(("orientation", orientation));
            } else {
                arguments.push(("direction", direction.unwrap_or_else(|| "right".to_string())));
            }
            ("rotate", device)
        }
        SimVerb::Logs { bundle_id, tail, minutes, since, level, filter, device } => {
            let optional: [(&str, Option<String>); 6] = [
                ("bundle-id", bundle_id),
                ("tail", tail.map(|value| value.to_string())),
                ("minutes", minutes.map(|value| value.to_string())),
                ("since", since),
                ("level", level),
                ("filter", filter),
            ];
            for (key, value) in optional {
                if let Some(value) = value {
                    arguments.push((key, value));
                }
            }
            ("logs", device)
        }
        SimVerb::CrashReport { bundle_id, device } => {
            if let Some(id) = bundle_id {
                arguments.push(("bundle-id", id));
            }
            ("crash-report", device)
        }
        SimVerb::Keyboard { state, device } => {
            arguments.push(("state", state));
            ("keyboard", device)
        }
    };
    if let Some(name) = device.device {
        arguments.push(("device", name));
    }
    let fields = arguments
        .iter()
        .map(|(key, value)| format!("\"{key}\":\"{}\"", app_socket::json_escape(value)))
        .collect::<Vec<_>>()
        .join(",");
    // Any command may wait out a boot `attach` started — half a minute, a first
    // boot several — and installing a large app is slow too; the app answers
    // when it is done. An explicit TERMIO_CLI_TIMEOUT still wins.
    let timeout = if action != "list" && !app_socket::explicit_client_timeout() {
        app_socket::client_timeout().max(180)
    } else {
        app_socket::client_timeout()
    };
    app_socket::require_socket(channel);
    exit_outcome(app_socket::request_once(
        channel,
        timeout,
        "sim",
        device.output.format(),
        action,
        "",
        &text,
        &format!("\"arguments\":{{{fields}}}"),
    ));
}

/// Resolve to an absolute, symlink-free path so termio keys the project by
/// the same canonical path it stores, avoiding duplicate sidebar entries.
async fn open_project(channel: &Channel, directory: &Path) -> Result<()> {
    if !directory.is_dir() {
        eprintln!("termio: not a directory: {}", directory.display());
        std::process::exit(1);
    }
    let absolute = directory
        .canonicalize()
        .with_context(|| format!("resolving {}", directory.display()))?;
    if !cfg!(target_os = "macos") {
        return open_on_this_host(&absolute).await;
    }
    let error = Command::new("open")
        .arg("-b")
        .arg(&channel.bundle_id)
        .arg(&absolute)
        .exec();
    Err(error).context("running open")
}

/// Off a Mac there is no app to hand the directory to. The project goes into
/// this host's view instead, which every client connected here draws. A project
/// with no running session gets a shell, so it opens onto something live.
async fn open_on_this_host(directory: &Path) -> Result<()> {
    let path = directory.to_string_lossy().into_owned();
    let project = termiod::client::project_add(&path).await?;
    let view = termiod::client::view().await?;
    let Some(row) = view.projects.iter().find(|row| row.id == project) else {
        bail!("{path} was registered but is not in the view");
    };
    let live: Vec<String> = termiod::client::list()
        .await?
        .into_iter()
        .map(|info| info.id)
        .collect();
    let running = row.groups.iter().flat_map(|group| group.panes()).any(|pane| match &pane.kind {
        termiod::view::PaneKind::Terminal { session } => live.contains(session),
    });
    if !running {
        let (rows, cols) = termiod::client::term_size();
        let spec = termiod::protocol::CreateSpec {
            cwd: Some(path.clone()),
            rows,
            cols,
            place: Some(termiod::view::Place {
                project: Some(project.clone()),
                ..Default::default()
            }),
            ..Default::default()
        };
        termiod::client::create(spec).await?;
    }
    println!("Opened {}. It shows in termio on every device connected to this machine.", row.label);
    Ok(())
}

/// `termio view`: the host's projects and how their sessions are grouped.
async fn print_view(json: bool) -> Result<()> {
    let view = termiod::client::view().await?;
    if json {
        println!("{}", serde_json::to_string_pretty(&view)?);
        return Ok(());
    }
    fn print_groups(groups: &[termiod::view::Group]) {
        for group in groups {
            let sessions: Vec<String> = group
                .panes()
                .iter()
                .map(|pane| match &pane.kind {
                    termiod::view::PaneKind::Terminal { session } => session.clone(),
                })
                .collect();
            println!("  {}  {}", group.id, sessions.join(" "));
        }
    }
    println!("revision {}", view.revision);
    for project in &view.projects {
        println!("{}  {}", project.label, project.path);
        print_groups(&project.groups);
    }
    if !view.loose.is_empty() {
        println!("(no project)");
        print_groups(&view.loose);
    }
    Ok(())
}

const NOTIFY_HELP: &str = "\
Post a macOS notification from the running app, such as \"build finished\" or
\"need a decision\", whether or not Termio is in front. --title replaces the
default title, the calling agent's name. Clicking the banner shows the session
that posted it.";

const SKILL_HELP: &str = "\
Print or install the skill that teaches agents the termio command. The text is
built into termio, so a new termio brings a new skill. `show` prints the text
this termio carries. `install` asks this machine's termiod to write the text it
carries, which is the same text when both come from one install. Hooks are
separate: `termio agent install` writes both.";

const SKILL_EXAMPLES: &str = "\
Examples:
  termio skill show
  termio skill install --agent claudeCode
  termio skill uninstall";

const WHOAMI_HELP: &str = "\
Show the session, project, group and pane this shell runs in, with the host,
the channel and the socket it talks to. A value this shell does not have
prints as `none`. Run it inside a Termio session to see where a command will
land.";

const SIM_HELP: &str = "\
Drive the iOS Simulator shown in termio's Simulator pane, so an agent can run
and check an iOS app the way the person watching would. Coordinates are device
points from the top-left of the screen as it is shown — after a rotation too —
the unit `inspect` reports frames in, so tap the centre of a frame it printed.
Read the screen with `inspect` before tapping anything you have not located;
use `screenshot` for colour, images and layout.

Run `attach` FIRST, before you build: the person watches from the first
frame, and a shut-down device boots while xcodebuild compiles. It answers as
soon as the device is drawing — a few seconds — not once it has booted; the
next command waits for the boot to finish (half a minute, minutes on a first
boot), so start the build in between.

  termio sim attach --device \"iPhone 17\"
  xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 17' \\
    -derivedDataPath build build
  termio sim launch build/Build/Products/Debug-iphonesimulator/MyApp.app
  termio sim inspect
  termio sim tap --label \"Continue\"
  termio sim swipe 200 700 200 200
  termio sim text \"hello@example.com\" && termio sim key return
  termio sim screenshot --out /tmp/screen.png

With no --device, a command uses the first of these that is booted: the device
this session used last; the device the pane shows, unless another session is
driving it; a device no other session is driving; any device. When nothing is
booted, name one with `attach --device`. Build with xcodebuild in your shell;
`logs` reads the app's log and `crash-report` its last crash.
Needs a Mac with Apple silicon and macOS 15 or later.";

const SIM_INSPECT_HELP: &str = "\
Print the frontmost app's accessibility tree, one element per line:
type, label, value (or an empty field's placeholder), identifier, then the
frame as x,y width x height in device points. Elements that say nothing are
folded away, and elements wholly off the screen are counted, not printed.
With X Y, print the element drawn at that point, as a tap there would find
it — the read that resolves what covers what.
With --marker, print the first element, in tree order, whose label (or
--match value, role or id) contains the text; a title can match before the
button that shares it, so check the type. When the reply names a modal, stay
inside it. --json prints idb's full accessibility document instead.";

const SESSION_HELP: &str = "\
List, start, drive and close sessions.

With the Termio app running, these commands act on the sessions of the
project you run them in. With no app running, they act on this machine's
termiod. `create`, `attach` and `ls --all` always act on termiod, and so
does `read` of a session the app opened.
`termio -H <host> session …` acts on another machine.

A SESSION is a termio://session/<id> link, an id, an id prefix of 8 or more
characters, or a name. `ls` and a `spawn` reply print them. With the app
running, `send` reads a first word that is not a link or id as prompt text.

A command waits up to $TERMIO_CLI_TIMEOUT seconds (default 15) for the app.";

const SESSION_EXAMPLES: &str = "\
Examples:
  termio session ls
  termio session spawn \"fix the failing test\"
  termio session send 8de0b387 \"run the tests\" --wait
  termio session read 8de0b387 --lines 20
  termio -H mybox session ls";

const LIST_HELP: &str = "\
List this project's sessions and their status: working, idle, done or
needs-you. --json adds each agent's transcript path once it has reported one.

--all lists every session this machine's termiod hosts instead, in every
project. With no app running, that is what `ls` lists.";

const LIST_EXAMPLES: &str = "\
Examples:
  termio session ls
  termio session ls --json
  termio session ls --all";

const WATCH_HELP: &str = "\
Print one line each time a session's status changes, until Ctrl-C. It starts
with one line per session; --no-snapshot skips them.

--state picks the states to print, from working, idle, done, needs-you and
stalled (default: done,needs-you). `stalled` means working for 20 minutes or
more with no repository change and almost no transcript growth; the line says
why. In --json, a {\"heartbeat\":true} line follows 30 seconds of silence.

Needs the Termio app. Exit codes: 0 after Ctrl-C, 2 when the app closed the
stream.";

const WATCH_EXAMPLES: &str = "\
Examples:
  termio session watch
  termio session watch --state done,needs-you,stalled --json";

const SPAWN_HELP: &str = "\
Start a new agent session on PROMPT, in a pane beside yours. The reply is the
session's link. The prompt is typed in once the agent has started.

--agent picks the agent (default: the kind that calls). --direction and --ratio
place the pane. --wait returns when the agent's first turn settles.

An agent that stops on a startup prompt, such as a trust prompt, takes PROMPT
as its answer. `session ls --json` then flags it as prompt_undelivered; send
the prompt again with `session send`.

Needs the Termio app. Exit codes: 0 done, 1 error, 3 timed out.";

const SPAWN_EXAMPLES: &str = "\
Examples:
  termio session spawn \"fix the failing test\"
  termio session spawn \"review this branch\" --agent codex --direction down
  termio session spawn \"write the changelog\" --wait --json";

const RUN_HELP: &str = "\
Start a new terminal session and run COMMAND in it, such as a dev server or a
test run. The reply is the session's link. A plain command has no transcript;
`session read` prints its screen.

--direction and --ratio place the pane: `--direction down --ratio 0.25` is a
strip under yours. --wait returns when the screen stops changing.

With no app running, the command runs in a session on termiod instead.
Exit codes: 0 done, 1 error, 3 timed out.";

const RUN_EXAMPLES: &str = "\
Examples:
  termio session run \"pnpm dev\" --direction down --ratio 0.25
  termio session run \"cargo test\" --wait";

const CREATE_HELP: &str = "\
Start a session on termiod that no app window shows, and print its id. It runs
PROGRAM, or your login shell, until it exits or you close it. Attach to it
with `session attach`.";

const CREATE_EXAMPLES: &str = "\
Examples:
  termio session create --name build -- cargo watch -x test
  termio -H mybox session create --name api --cwd ~/api -- npm start";

const ATTACH_HELP: &str = "\
Attach this terminal to a session on termiod. Detach with Ctrl-\\; the session
keeps running. A name that matches no session creates one with that name.

--observe watches without a keyboard and needs no terminal.";

const ATTACH_EXAMPLES: &str = "\
Examples:
  termio session attach build
  termio session attach 8de0b387 --observe
  termio -H mybox session attach api";

const READ_HELP: &str = "\
Print a session's screen, without the scrollback, and leave the session where
it is. --lines keeps the last N rows. It is how you read a `run` session's
result, or check on an agent.";

const READ_EXAMPLES: &str = "\
Examples:
  termio session read 8de0b387
  termio session read build --lines 20";

const SEND_HELP: &str = "\
Type text into a session, then press Return: a prompt, or an answer such as
\"1\" or \"yes\". Without a SESSION, `send` starts a new agent, like `spawn`.

--no-enter types the text and no Return: the lone `t` a trust prompt waits
for.

--key presses a named key after the text, in the order given, and drops the
Return; add `--key enter` for one. Names: enter escape tab space backspace
delete insert up down left right home end pageup pagedown f1-f12, a single
character, and ctrl- or shift- chords (ctrl-c, shift-tab). Option and Command
chords are refused. For a meta chord, send `--key escape --key b`.

--wait returns when the turn the text started settles. The reply carries the
status, the transcript path and the line range of the answer.

--key and --wait need the Termio app. Exit codes: 0 done, 1 error, including
a stalled or closed session, 3 timed out.";

const SEND_EXAMPLES: &str = "\
Examples:
  termio session send 8de0b387 \"run the tests\"
  termio session send 8de0b387 --key escape
  termio session send 8de0b387 t --no-enter
  termio session send 8de0b387 \"summarise the diff\" --wait --json";

const CLOSE_HELP: &str = "\
Close sessions and end their programs. Each SESSION gets its own attempt and
reply line; if any fails, the command fails. `kill` is the same command.";

const CLOSE_EXAMPLES: &str = "\
Examples:
  termio session close 8de0b387
  termio session close build api";

const FOCUS_HELP: &str = "\
Select the session in the app and bring Termio to the front. Needs the
Termio app.";

#[cfg(test)]
mod tests {
    use super::*;

    fn release() -> Channel {
        Channel::from_program_name("termio")
    }

    #[test]
    fn links_resolve_the_way_the_apps_addressed_id_does() {
        let id = "8de0b387-485a-4016-8990-cbcbfff03199";
        let link = format!("termio://session/{id}");
        assert_eq!(read_token(&release(), &link).as_deref(), Some(id));
        // Case-insensitive scheme and id, trailing slash, query suffix.
        assert_eq!(
            read_token(&release(), &format!("TERMIO://session/{}", id.to_uppercase())).as_deref(),
            Some(id)
        );
        assert_eq!(read_token(&release(), &format!("{link}/")).as_deref(), Some(id));
        assert_eq!(read_token(&release(), &format!("{link}?focus=1")).as_deref(), Some(id));
        // A bare token passes through untouched.
        assert_eq!(read_token(&release(), "8de0b387").as_deref(), Some("8de0b387"));
    }

    #[test]
    fn foreign_and_malformed_links_stay_with_the_app() {
        assert_eq!(read_token(&release(), "termio-dev://session/8de0b387"), None);
        assert_eq!(read_token(&release(), "https://example.com/session/x"), None);
        assert_eq!(read_token(&release(), "termio://nothing-here"), None);
        assert_eq!(read_token(&release(), "termio://session/"), None);
    }

    /// The root help is written by hand, so it must name every command a
    /// person can run, and nothing else.
    #[test]
    fn the_root_help_lists_exactly_the_visible_commands() {
        let mut command = Cli::command();
        command.build();
        let visible: Vec<String> = command
            .get_subcommands()
            .filter(|sub| !sub.is_hide_set())
            .map(|sub| sub.get_name().to_string())
            .collect();
        for name in &visible {
            assert!(
                ROOT_TEMPLATE.contains(&format!("\n  {name:<12}")),
                "the root help leaves out `{name}`"
            );
        }
        let listed = ROOT_TEMPLATE
            .lines()
            .filter(|line| line.starts_with("  ") && !line.starts_with("   "))
            .filter_map(|line| line.split_whitespace().next())
            .filter(|name| !name.starts_with('{'));
        for name in listed {
            assert!(visible.iter().any(|v| v == name), "the root help lists `{name}`, which is not a command");
        }
    }

    /// Each shortcut parses to the very `session` verb it is short for, with
    /// the same arguments.
    #[test]
    fn a_shortcut_is_its_session_verb() {
        let parse = |line: &str| {
            let cli = Cli::try_parse_from(line.split(' ')).expect("parses");
            cli.verb.map(into_session)
        };
        let shortcut = |line: &str| match parse(line) {
            Some(Verb::Session { verb: Some(verb) }) => std::mem::discriminant(&verb),
            _ => panic!("`{line}` is not a session verb"),
        };
        assert!(matches!(
            parse("termio ls --all"),
            Some(Verb::Session { verb: Some(SessionVerb::List(ListArgs { all: true, .. })) })
        ));
        for (short, long) in [
            ("termio ls", "termio session ls"),
            ("termio list", "termio session list"),
            ("termio spawn hi", "termio session spawn hi"),
            ("termio run make", "termio session run make"),
            ("termio send 8de0b387 hi", "termio session send 8de0b387 hi"),
            ("termio read 8de0b387", "termio session read 8de0b387"),
            ("termio attach 8de0b387", "termio session attach 8de0b387"),
            ("termio close 8de0b387", "termio session close 8de0b387"),
            ("termio kill 8de0b387", "termio session kill 8de0b387"),
        ] {
            assert_eq!(shortcut(short), shortcut(long), "{short}");
        }
    }

    /// A missing word that looks like a path stays a missing directory; any
    /// other missing word is a mistyped command.
    #[test]
    fn only_path_shaped_words_are_treated_as_directories() {
        assert!(path_shaped("./app"));
        assert!(path_shaped("~/code"));
        assert!(path_shaped("code/app"));
        assert!(path_shaped(".hidden"));
        assert!(!path_shaped("sesion"));
        assert!(!path_shaped("whoami"));
    }

    #[test]
    fn edit_distance_counts_single_character_edits() {
        assert_eq!(edit_distance("sesion", "session"), 1);
        assert_eq!(edit_distance("whoamii", "whoami"), 1);
        assert_eq!(edit_distance("sever", "server"), 1);
        assert_eq!(edit_distance("view", "view"), 0);
        assert_eq!(edit_distance("", "skill"), 5);
    }

    #[test]
    fn only_uuid_shaped_names_belong_to_the_daemon_first_path() {
        assert!(uuid_shaped("8de0b387-485a-4016-8990-cbcbfff03199"));
        assert!(!uuid_shaped("8de0b387"));
        assert!(!uuid_shaped("deadbeef-server"));
        assert!(!uuid_shaped("8de0b387-485a-4016-8990-cbcbfff0319g"));
    }
}
