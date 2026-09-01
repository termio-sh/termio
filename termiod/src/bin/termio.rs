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
//! as a directory (the `code .` shape, an `external_subcommand`), `remote` is
//! an argv passthrough whose help belongs to the daemon, and `send`'s first
//! positional is a target only if it looks like an address.
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

const AFTER_HELP: &str = "\
<session> = a termio://session/<uuid> link or a bare id/prefix — printed by
`termio sessions list` / a `spawn` reply.

Every one-shot command times out after ${TERMIO_CLI_TIMEOUT:-15}s
(TERMIO_CLI_TIMEOUT overrides).";

#[derive(Parser)]
#[command(
    name = "termio",
    about = "Drive the running termio app — open projects, run agent sessions, report status.",
    after_long_help = AFTER_HELP
)]
struct Cli {
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

    /// Sessions in this project — list, start, drive, close.
    Sessions {
        #[command(subcommand)]
        verb: Option<SessionVerb>,
    },

    /// Post a macOS notification (e.g. "I'm done").
    #[command(long_about = NOTIFY_HELP)]
    Notify(NotifyArgs),

    /// Report this agent's activity (hook contract).
    Agent {
        #[command(subcommand)]
        verb: AgentVerb,
    },

    /// Drive a box's termiod over SSH (deploy, list, attach, open).
    ///
    /// Every argument is passed through to the daemon, whose own `--help`
    /// lists the verbs — so this subcommand must not claim `--help` for
    /// itself, and `disable_help_flag` is what keeps `termio remote --help`
    /// reaching the daemon rather than printing this paragraph.
    #[command(disable_help_flag = true)]
    Remote {
        #[arg(value_name = "ARGS", trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// One table: this client, the running app, the local termiod, and every
    /// known remote as of last connect.
    Version,

    /// `termio [DIR]` — the `code .`-shaped shorthand for `open DIR`.
    #[command(external_subcommand)]
    Directory(Vec<String>),
}

#[derive(Subcommand)]
enum SessionVerb {
    /// List the sessions in this project with their live status.
    #[command(long_about = LIST_HELP)]
    List(ListArgs),

    /// Stream status transitions until Ctrl-C.
    #[command(long_about = WATCH_HELP)]
    Watch(WatchArgs),

    /// Start a NEW agent session on the prompt.
    #[command(long_about = SPAWN_HELP)]
    Spawn(SpawnArgs),

    /// Start a NEW terminal session running a shell command.
    #[command(long_about = RUN_HELP)]
    Run(RunArgs),

    /// Type a prompt (or menu answer) into a session.
    #[command(long_about = SEND_HELP)]
    Send(SendArgs),

    /// Deprecated, agent-only alias of `send`.
    #[command(long_about = SEND_HELP, hide = true)]
    Answer(SendArgs),

    /// Print a session's current screen.
    #[command(long_about = READ_HELP)]
    Read(ReadArgs),

    /// Close session tabs.
    #[command(long_about = CLOSE_HELP)]
    Close(CloseArgs),

    /// Select the session in the app.
    #[command(long_about = FOCUS_HELP)]
    Focus(FocusArgs),
}

#[derive(Subcommand)]
enum AgentVerb {
    /// Report this agent's activity to the session that owns it.
    Report(ReportArgs),
}

/// `--json` reads the same on every verb that answers, so it is declared once.
#[derive(Args)]
struct Output {
    /// Machine-readable output.
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
    /// Block until the turn settles; the reply carries the final status and
    /// the transcript line range to read (exit 0 settled, 1 error — including
    /// a stalled or vanished session, 3 timed out).
    #[arg(long)]
    wait: bool,

    /// Cap for --wait (default 300000, clamped 1000–600000); implies --wait.
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
    /// The prompt, e.g. `termio sessions spawn "fix the build"`.
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
    /// The shell command, e.g. `termio sessions run "pnpm dev"`.
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
    /// A session address followed by the text — or text alone, which spawns.
    #[arg(value_name = "SESSION|TEXT", required = true)]
    words: Vec<String>,

    /// Press a named key (escape, up, tab, ctrl-c, f2, …) after the text;
    /// repeatable, in order. Any --key suppresses the implicit Return.
    #[arg(long = "key", value_name = "NAME")]
    keys: Vec<String>,

    /// Deliver the text as-is, with no Return after it — the way to answer a
    /// gate that wants a bare keypress.
    #[arg(long)]
    no_enter: bool,

    #[command(flatten)]
    wait: Wait,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct ReadArgs {
    /// The session to read, as a termio://session link or a bare id.
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
    /// The sessions to close, as termio://session links or bare ids.
    #[arg(value_name = "SESSION", required = true)]
    sessions: Vec<String>,

    #[command(flatten)]
    output: Output,
}

#[derive(Args)]
struct FocusArgs {
    /// The session to select, as a termio://session link or a bare id.
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
    let sessions = match termiod::client::sessions_of_running_daemon().await {
        Ok(Some(sessions)) => sessions,
        _ => return None,
    };
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
    let matches: Vec<&termiod::protocol::SessionInfo> = sessions
        .iter()
        .filter(|info| {
            let name = info.name.to_lowercase();
            uuid_shaped(&name) && (name == token_lower || name.starts_with(&token_lower))
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
        match termiod::client::observe_screen_rows(&info.name, info.rows, info.cols).await {
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
            serde_json::Value::from(format!(
                "{}://session/{}",
                channel.url_scheme(),
                info.name.to_lowercase()
            )),
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
/// hand-write hooks against them. Every one forwards to `termiod set-status`,
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
    let cli = Cli::from_arg_matches(&command.get_matches())?;

    match cli.verb {
        None => open_project(&channel, Path::new(".")),
        Some(Verb::Open { dir }) => {
            open_project(&channel, dir.as_deref().unwrap_or(Path::new(".")))
        }
        Some(Verb::Directory(words)) => {
            let directory = words.first().map(String::as_str).unwrap_or(".");
            open_project(&channel, Path::new(directory))
        }
        Some(Verb::Version) => version::print_table(&channel, provenance).await,
        // The parsed vector cannot be forwarded: clap claims the first `--`
        // after the subcommand as its own end-of-options marker and drops it,
        // so `termio remote -- deploy` reached the daemon as `remote deploy`.
        // Every argument past the literal `remote` belongs to the daemon,
        // including that separator, so they are taken from argv directly.
        Some(Verb::Remote { .. }) => {
            remote_passthrough(&channel, &std::env::args().skip(2).collect::<Vec<String>>())
        }
        Some(Verb::Agent { verb }) => {
            let AgentVerb::Report(args) = verb;
            agent_report(&channel, args)
        }
        Some(Verb::Notify(args)) => notify(&channel, args),
        Some(Verb::Sessions { verb }) => {
            sessions(
                &channel,
                verb.unwrap_or(SessionVerb::List(ListArgs {
                    output: Output { json: false },
                })),
            )
            .await
        }
    }
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
    // know which verb they are on, and they run before `require_socket` for
    // the same reason — a malformed command should say so, not report that the
    // app is down.
    let mut agent = String::new();
    let mut extra = String::new();
    let mut client_timeout = app_socket::client_timeout();

    let (operation, output, target, text) = match verb {
        SessionVerb::List(args) => {
            let format = args.output.format();
            app_socket::require_socket(channel);
            exit_outcome(app_socket::request_once(
                channel,
                client_timeout,
                "list",
                format,
                "",
                "",
                "",
                "",
            ));
        }

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

        SessionVerb::Close(args) => {
            // One request per tab; any failure fails the whole command, but
            // every target still gets its attempt and its own reply line. A
            // target carrying whitespace splits, the way the shell client's
            // unquoted expansion split it.
            let format = args.output.format();
            app_socket::require_socket(channel);
            let mut failed = 0;
            for target in args.sessions.iter().flat_map(|word| word.split_whitespace()) {
                if app_socket::request_once(
                    channel,
                    client_timeout,
                    "close",
                    format,
                    target,
                    "",
                    "",
                    "",
                ) != Outcome::Ok
                {
                    failed = 1;
                }
            }
            std::process::exit(failed);
        }

        SessionVerb::Focus(args) => ("focus", args.output, args.session, String::new()),

        SessionVerb::Read(args) => {
            // Device verb, daemon first (unify-server-plane Stage 10): a
            // session the local daemon hosts answers from its authoritative
            // VT — including sessions no window ever opened, and boxes with
            // no app at all. A target the daemon does not own (a session on
            // a remote device, an app-side title match, a foreign-channel
            // link) falls through to the app, which keeps its coverage.
            if let Some(code) =
                daemon_read(channel, &args.session, args.lines, args.output.format()).await
            {
                std::process::exit(code);
            }
            app_socket::require_socket(channel);
            if let Some(lines) = args.lines {
                extra = format!("\"lines\":{lines}");
            }
            ("read", args.output, args.session, String::new())
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
                    fail("termio: spawn starts agents — for a plain terminal running a command, use `termio sessions run \"<command>\"`");
                }
                agent = named.clone();
            }
            placement(&mut extra, &args.placement);
            waiting(&mut extra, &args.wait, &mut client_timeout);
            ("send", args.output, String::new(), join(&args.words))
        }

        // `run` is the same spawn with the agent pinned to the plain shell —
        // the payload is a command line, not a prompt.
        SessionVerb::Run(args) => {
            agent = "terminal".to_string();
            placement(&mut extra, &args.placement);
            waiting(&mut extra, &args.wait, &mut client_timeout);
            ("send", args.output, String::new(), join(&args.words))
        }

        SessionVerb::Send(args) | SessionVerb::Answer(args) => {
            // A leading address targets an existing session. Without one,
            // `send` is a back-compat alias for `spawn`; the strict is_address
            // shape check keeps a prompt that merely opens with a word from
            // being mistaken for an address.
            let addressed = args
                .words
                .first()
                .is_some_and(|word| app_socket::is_address(word));
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
            waiting(&mut extra, &args.wait, &mut client_timeout);
            ("send", args.output, target, join(words))
        }
    };

    app_socket::require_socket(channel);
    exit_outcome(app_socket::request_once(
        channel,
        client_timeout,
        operation,
        output.format(),
        &target,
        &agent,
        &text,
        &extra,
    ));
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

extern "C" fn watch_interrupted(_: libc::c_int) {
    unsafe { libc::_exit(0) }
}

/// `termio agent report <state> …` forwards to `termiod set-status`, which
/// declares the same flags. The value of a `--…-from` flag is forwarded as one
/// argv item: the shell client expanded its accumulated string unquoted, so a
/// field name containing a space arrived at the daemon as two arguments and
/// `set-status` rejected it as an unexpected positional.
fn agent_report(channel: &Channel, args: ReportArgs) -> Result<()> {
    let mut forwarded: Vec<String> = Vec::new();
    if args.transcript {
        forwarded.push("--transcript".to_string());
    }
    for (flag, value) in [
        ("--conversation", &args.conversation),
        ("--conversation-from", &args.conversation_from),
        ("--tool-from", &args.tool_from),
        ("--prompt-title-from", &args.prompt_title_from),
    ] {
        if let Some(value) = value {
            forwarded.push(flag.to_string());
            forwarded.push(value.clone());
        }
    }

    // A hook outside a termiod session has nothing to report to, and reporting
    // with an empty target is a call the daemon rejects. Silent, because hooks
    // fire constantly and a hook that talks is worse than one that does not.
    let session = std::env::var("TERMIOD_SESSION_ID").unwrap_or_default();
    if session.is_empty() {
        if args.reply {
            print!("{{}}");
        }
        return Ok(());
    }
    let Some(daemon) = channel::daemon_binary(channel) else {
        if args.reply {
            print!("{{}}");
        }
        return Ok(());
    };

    // `--reply` is handled by the daemon binary, which prints `{}` itself even
    // when the report could not be delivered — one implementation of Cursor's
    // stdout contract rather than two. `channel::resolve` already pinned
    // `TERMIO_CHANNEL`, which the exec inherits.
    let mut command = Command::new(&daemon);
    command
        .arg("set-status")
        .arg(&session)
        .arg(args.state.wire())
        .args(&forwarded);
    if args.reply {
        command.arg("--reply");
    }
    let error = command.exec();
    Err(error).with_context(|| format!("running {}", daemon.display()))
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

/// Resolve to an absolute, symlink-free path so termio keys the project by
/// the same canonical path it stores, avoiding duplicate sidebar entries.
fn open_project(channel: &Channel, directory: &Path) -> Result<()> {
    if !directory.is_dir() {
        eprintln!("termio: not a directory: {}", directory.display());
        std::process::exit(1);
    }
    let absolute = directory
        .canonicalize()
        .with_context(|| format!("resolving {}", directory.display()))?;
    if !cfg!(target_os = "macos") {
        bail!("termio open drives the Mac app; there is none on this machine");
    }
    let error = Command::new("open")
        .arg("-b")
        .arg(&channel.bundle_id)
        .arg(&absolute)
        .exec();
    Err(error).context("running open")
}

/// `termio remote …` execs the daemon binary rather than calling
/// `remote::run` in-process: `shipped_binary()` deploys `current_exe()` to
/// Mac targets, so an in-process call from this client would ship the client
/// as the remote daemon. The in-process move happens together with a
/// daemon-sibling fix, not here. `channel::resolve` already pinned
/// `TERMIO_CHANNEL`, which the exec inherits.
fn remote_passthrough(channel: &Channel, rest: &[String]) -> Result<()> {
    let Some(daemon) = channel::daemon_binary(channel) else {
        eprintln!("termio: no termiod binary found — install the termio app, or set TERMIOD_BIN");
        std::process::exit(1);
    };
    let error = Command::new(&daemon).arg("remote").args(rest).exec();
    Err(error).with_context(|| format!("running {}", daemon.display()))
}

const NOTIFY_HELP: &str = "\
Post a macOS notification from the running app. The agent uses this to ping you
directly — \"build finished\", \"need a decision\" — regardless of whether termio is
frontmost (unlike the automatic completion banner). --title overrides the default
(the calling agent's name); the banner's subtitle is the project, and clicking it
focuses the session that posted it.";

const LIST_HELP: &str = "\
List the sessions in this project with their live status (working / idle /
done / needs-you). `--json` adds each session's transcript path once its
agent has reported one.";

const WATCH_HELP: &str = "\
Block and stream one line per session status transition until interrupted.
On attach it first prints a snapshot line per session with its current
status (tagged \"snapshot\":true in --json); --no-snapshot skips that.
--state takes a comma-separated filter (working, idle, done, needs-you,
stalled); the default reports the two states a supervisor acts on: done,
needs-you.
In --json mode the app writes {\"heartbeat\":true} after 30s of silence so a
dead stream is distinguishable from a quiet one.

`stalled` is a watch-plane signal, not a real status: the session is still
working, but for 20+ minutes has made no repo change and next-to-no
transcript growth — the unattended-runaway pattern. Sustained output (a
long build streaming logs) suppresses it. The event carries the reasoning
in `evidence` (\"working 42m, no repo change, transcript +3 lines\"), fires
once per quiet stretch, and re-arms when progress resumes. Opt in with
--state stalled; it is not in the default filter.

exit codes: 0 after Ctrl-C (normal end of supervision), 2 when the stream
closes from the app side (termio quit or died).";

const SPAWN_HELP: &str = "\
Start a NEW agent session on the prompt. Replies immediately with the new
session's termio://session link; the prompt is
typed in once the agent finishes booting. --agent picks the agent (e.g. claudeCode, codex, grok,
pi); the default is the calling agent's own kind.

--direction places the new pane relative to yours (right or down) instead of
the automatic stack; --ratio is the new pane's share of the split (e.g. 0.25
for a short strip) and holds against later spawns. Panes without a stated
ratio share their run evenly.

Readiness is judged from the screen, so an agent sitting on a startup gate —
a trust prompt, a usage notice, a first-run dialog — looks ready while it is
actually waiting for a keypress, and swallows the prompt as its answer. The
reply cannot know this; it has already been sent. When it happens the session
is flagged in `sessions list` (`prompt_undelivered` in --json), so check there
before waiting on a reply that will never come, then resend with
`sessions send`.

--wait holds the reply until the spawned agent's first turn settles (or
--timeout ms elapse; default 300000, clamped 1000–600000). The reply then
carries the final status, the transcript path, and the cursor..cursor_end
line range holding the response. A session that stops to ask you something
returns immediately as needs-you, with the on-screen question in `prompt`.

A prompt that shows no effect within 5s fails fast as prompt_stalled (the
input was eaten) rather than burning the timeout; a session that closes or
whose agent exits mid-wait fails as session_closed / agent_gone.

exit codes: 0 settled, 1 error (including stalled/vanished), 3 timed out.";

const RUN_HELP: &str = "\
Start a NEW plain terminal session and type the shell command into it — a
dev server, a test run, a build — visible in a split pane, no LLM involved.
Replies immediately with the session's address; drive it further with
`send`, read its output with `read` (a plain command has no
transcript; its screen is the result), close it with `close`.

--direction places the pane relative to yours (right or down); --ratio is its
share of the split — `--direction down --ratio 0.25` is a log strip under
your pane, not a column beside it.

--wait settles when the screen goes still after the command's output (or
returns needs-you / times out, exactly as with send).

exit codes: 0 settled, 1 error (including stalled/vanished), 3 timed out.";

const READ_HELP: &str = "\
Print the session's current screen (its viewport, right-trimmed, trailing
blank rows dropped) without focusing it. The result channel for `run`
sessions, and a quick peek at any agent's live TUI. --lines keeps only
the last N rows. Scrollback is not included.";

const SEND_HELP: &str = "\
Type text into an existing session and submit it with a real Return
keypress — a prompt to drive it, or a menu choice (\"1\", \"yes\") to answer a
permission prompt. Addresses come from `termio sessions list` or a `spawn`
reply — a termio://session link or bare id, copied verbatim.

The text reaches the terminal verbatim, so --no-enter (no Return after it)
delivers a bare keypress: the lone `t` a trust gate waits for.

--key presses a NAMED key, repeatable and in order, after the text:
`send <session> --key escape` to back out of a menu, `--key up --key enter`
to rerun the last entry. Use it instead of writing escape bytes yourself —
a key's bytes depend on the mode the program negotiated (Up is ESC[A in
normal mode, ESC O A in application mode), so only the terminal's own key
encoder can get them right. Any --key suppresses the implicit Return; name
`--key enter` when you want one. An unknown name is an error, never text.

Key names follow kitty and tmux, both spellings accepted: enter, escape,
tab, space, backspace, delete, insert, up, down, left, right, home, end,
pageup, pagedown, f1–f12, and single characters — prefixed with ctrl-/c-
or shift-/s- for chords (ctrl-c, c-c, shift-tab). Ctrl and Shift are the
modifiers a program sees: macOS spends Option composing text (option-b is
∫, not meta-b) and Command drives the app, so those chords are refused
rather than silently dropped. A meta chord is ESC then the key:
`--key escape --key b`.

--wait holds the reply until the turn the text kicked off settles (or
--timeout ms elapse; default 300000, clamped 1000–600000). The reply then
carries the final status, the transcript path, and the cursor..cursor_end
line range holding the response. A session that stops to ask you something
returns immediately as needs-you, with the on-screen question in `prompt`.

A prompt that shows no effect within 5s fails fast as prompt_stalled (the
input was eaten) rather than burning the timeout; a session that closes or
whose agent exits mid-wait fails as session_closed / agent_gone.

exit codes: 0 settled, 1 error (including stalled/vanished), 3 timed out.

`answer` is a deprecated, agent-only alias; `send` without a target aliases `spawn`.";

const CLOSE_HELP: &str = "\
Close one or more session tabs. Each target gets its own attempt and reply
line; any failure fails the whole command.";

const FOCUS_HELP: &str = "\
Select the session in the app and bring termio to the front.";

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

    #[test]
    fn only_uuid_shaped_names_belong_to_the_daemon_first_path() {
        assert!(uuid_shaped("8de0b387-485a-4016-8990-cbcbfff03199"));
        assert!(!uuid_shaped("8de0b387"));
        assert!(!uuid_shaped("deadbeef-server"));
        assert!(!uuid_shaped("8de0b387-485a-4016-8990-cbcbfff0319g"));
    }
}
