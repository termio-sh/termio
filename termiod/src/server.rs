//! `termio server …` and `termio pair`: the client verbs that act on a
//! machine's daemon. They lived on `termiod` until the daemon was cut down to
//! `serve`; every verb a person or a control plane runs is `termio`'s now, the
//! way `docker` holds every verb and `dockerd` only runs.
//!
//! The sessions a daemon hosts are `termio session`'s, not this file's verbs:
//! `ls`, `create`, `attach`, `kill` and `send` stay here hidden, because
//! shipped apps and older clients run them on remote boxes, and both trees call
//! the functions at the bottom of this file.
//!
//! `--host` is the root's, so it reaches every verb, the way Rex's `--server`
//! does: `deploy` runs its loop from here, and every other command runs as the
//! same words on that machine over the user's own `ssh`.

use anyhow::{bail, Result};
use clap::{Args, Subcommand};
use std::path::PathBuf;

use crate::protocol::{CreateSpec, SessionInfo};
use crate::{agent, client, lifecycle, log, remote, service, tailnet, wss};

#[derive(Args)]
#[command(after_help = SERVER_EXAMPLES)]
pub struct ServerArgs {
    /// The root's `-H`, also accepted anywhere among `server`'s words, as it
    /// was before it moved to the root: shipped apps run
    /// `termio server --host <host> deploy`.
    #[arg(short = 'H', long, value_name = "HOST", global = true, hide = true)]
    pub host: Option<String>,

    #[command(subcommand)]
    pub cmd: ServerCmd,
}

const SERVER_EXAMPLES: &str = "\
Examples:
  termio server status
  termio server logs -f
  termio server service install
  termio -H mybox server deploy
  termio -H mybox server tailscale on";

#[derive(Subcommand)]
pub enum ServerCmd {
    /// What this machine has: the daemon binary, the daemon, its sessions.
    ///
    /// Read-only, one connection.
    ///
    /// The daemon's version comes from the daemon, not from the file on disk:
    /// the two differ exactly when an update is staged and not yet running.
    Status {
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Print the daemon's log — what it recorded while nobody was attached.
    Logs {
        /// Print the path and exit, for piping into an editor or a bug report.
        #[arg(long)]
        path: bool,

        /// Keep printing as the daemon writes, like `tail -f`.
        #[arg(short, long)]
        follow: bool,

        /// How many trailing lines to print (default 200; 0 for the whole file).
        #[arg(short = 'n', long, default_value_t = 200)]
        lines: usize,
    },

    /// Ask the daemon to stop.
    ///
    /// Declines while a command is running or an agent is mid-task, and names
    /// the sessions; `--force` stops it regardless.
    /// A client attached to an idle prompt does not hold it up.
    ///
    /// The daemon is found by the credential on its socket, never by its
    /// command line, so a second daemon someone runs by hand on another socket
    /// is never the one stopped. Exit 3 means "in use", not failure.
    Stop {
        /// Stop even while work is in progress. Every session ends.
        #[arg(long)]
        force: bool,
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Install or update the daemon, and check it answers.
    ///
    /// One loop for every state the machine can be in: nothing installed, an
    /// older binary, a newer binary the daemon has not picked up. It asks the
    /// old daemon to hand off or stop when it is idle, checks the new one
    /// answers, and puts the previous binary back if it does not. Running it
    /// again is the recovery from any outcome. With `--host` the loop runs from
    /// here and copies this build to that machine over `ssh`.
    Deploy {
        /// Stop the old daemon even while its sessions have work in progress.
        #[arg(long)]
        force: bool,
        /// Put the binary in place and leave the running daemon alone.
        #[arg(long)]
        stage_only: bool,
        /// Upgrade only if the daemon can hand off in place: one that cannot
        /// and holds any live session is left running and reported as staged,
        /// never stopped. For automatic callers with no user behind them.
        #[arg(long, conflicts_with = "force", conflicts_with = "stage_only")]
        handoff_only: bool,
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
        /// With `--host`: send this prebuilt daemon (and the `termio` beside
        /// it) instead of the bundled or cross-compiled build.
        #[arg(long, value_name = "PATH")]
        bin: Option<PathBuf>,
        /// With `--host`: the Rust target triple, instead of asking `uname`.
        #[arg(long, value_name = "TRIPLE")]
        target: Option<String>,
    },

    /// Put the machine on your tailnet with Tailscale built in.
    ///
    /// Paired Macs and iPhones then reach it with no Tailscale install there.
    Tailscale {
        #[command(subcommand)]
        cmd: TailscaleCmd,
    },

    /// Keep the daemon running across logins and crashes.
    ///
    /// launchd on macOS, systemd --user on Linux.
    Service {
        #[command(subcommand)]
        cmd: service::ServiceCmd,
    },

    /// Replace the running daemon's binary without stopping it.
    ///
    /// The host `execve`s the new binary, keeping its pid, its children and
    /// every PTY, so nothing running in a session notices. `deploy` runs it
    /// as its first rung; run it by hand after replacing the binary yourself.
    Handoff {
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
        /// Hand off to this binary instead of the daemon beside this client.
        #[arg(long, value_name = "PATH")]
        binary: Option<std::path::PathBuf>,
    },

    /// `termio session ls --all`.
    #[command(alias = "ls", hide = true)]
    List {
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },

    /// `termio session create`.
    #[command(hide = true)]
    Create(CreateArgs),

    /// `termio session attach`.
    #[command(hide = true)]
    Attach(AttachArgs),

    /// `termio session close`.
    #[command(hide = true)]
    Kill {
        target: String,
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },

    /// `termio session send`.
    #[command(hide = true)]
    Send {
        target: String,
        text: Vec<String>,
        #[arg(long)]
        no_enter: bool,
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Stream a workspace's filesystem changes from the host (§C.10).
    ///
    /// The host owns the watch; this is a resumable subscriber. Stop it, change
    /// the tree, restart with `--since <seq>` and the missed batches replay —
    /// or the host reports a gap when the cursor has aged out of its ring.
    #[command(hide = true)]
    Watch {
        /// Absolute workspace root to watch on the host.
        root: String,
        /// Resume from this seq instead of starting fresh.
        #[arg(long)]
        since: Option<u64>,
    },
}

#[derive(Subcommand)]
pub enum TailscaleCmd {
    /// Join the tailnet, printing a sign-in link the first time.
    ///
    /// Only the Tailscale account that signs in gets in, and each client still
    /// needs the pairing token. The setting survives restarts and reboots.
    On {
        /// The device name on the tailnet (default: termio).
        #[arg(long, value_name = "NAME")]
        hostname: Option<String>,
        /// Sign in with a one-time auth key from this file, or `-` for stdin,
        /// instead of a browser.
        #[arg(long, value_name = "FILE")]
        auth_key_file: Option<PathBuf>,
        /// Return at once instead of waiting for the sign-in.
        #[arg(long)]
        no_wait: bool,
    },
    /// Leave the tailnet until `on`. The machine stays signed in.
    Off,
    /// Sign the machine out of Tailscale and turn built-in Tailscale off.
    Logout,
    /// Show whether the machine is on the tailnet, and where clients reach it.
    Status {
        /// Print the reply as JSON.
        #[arg(long)]
        json: bool,
    },
}

/// `termio server <verb>`. `host` is the root's `--host`, which only `deploy`
/// sees: every other verb with a host never reaches here, because the root
/// runs it on that host instead.
pub async fn run(args: ServerArgs, host: Option<String>) -> Result<()> {
    match (host, args.cmd) {
        (
            Some(host),
            ServerCmd::Deploy {
                force,
                stage_only,
                handoff_only,
                json,
                bin,
                target,
            },
        ) => {
            let options = lifecycle::Options {
                force,
                stage_only,
                handoff_only,
            };
            let report = remote::deploy(host, bin, target, options).await?;
            print_report(&report, json)
        }
        (_, cmd) => run_here(cmd).await,
    }
}

/// Runs the command on `host` as the words the user typed, less `--host`, so
/// a box answers with its own build's code. Exits with the remote status.
pub fn run_on_host(host: &str, tty: bool) -> Result<()> {
    let words = verb_words_of(&std::env::args().collect::<Vec<String>>());
    std::process::exit(remote::run_verb(host, tty, &words)?)
}

/// The words after the program name, without `--host`, as the user typed
/// them — which is what the host's own `termio` should parse. Taken from argv
/// rather than rebuilt from the parsed command, so no flag can be dropped on
/// the way.
///
/// `-H` is removed only where it is a flag: among the root's flags, before
/// the command word, and anywhere among `server`'s words before `--`, where
/// it has been global since `termio server --host` was introduced. After any
/// other command word it is the verb's text, such as a prompt that starts
/// with `-H`.
///
/// `session` goes out as `sessions`, its old name, which every build parses:
/// a host still on an older build then answers with its own error for the
/// verb, not by opening a project called `session`.
/// The top-level shortcuts, such as `ls`, go out the same way, as
/// `sessions ls`.
fn verb_words_of(argv: &[String]) -> Vec<String> {
    #[derive(PartialEq)]
    enum Place {
        Root,
        Server,
        Verbatim,
    }
    let mut words = Vec::new();
    let mut rest = argv.iter().skip(1);
    let mut place = Place::Root;
    while let Some(word) = rest.next() {
        if place == Place::Verbatim {
            words.push(word.clone());
            continue;
        }
        match word.as_str() {
            "--" => {
                place = Place::Verbatim;
                words.push(word.clone());
            }
            "-H" | "--host" => {
                rest.next();
            }
            _ if word.starts_with("--host=") => {}
            _ if word.starts_with("-H") => {}
            // Short flags combined into one word, `-fHbox`: everything from
            // the `H` on is the host. No other short flag of `server` takes
            // a value that could contain an `H`, except `-n`, which takes
            // digits.
            _ if place == Place::Server
                && !word.starts_with("--")
                && word.starts_with('-')
                && word[1..].contains('H') =>
            {
                let at = word.find('H').unwrap_or(word.len());
                if at > 1 {
                    words.push(word[..at].to_string());
                }
                // `-fH box`: the host is the next word.
                if at + 1 == word.len() {
                    rest.next();
                }
            }
            _ if word.starts_with('-') || place == Place::Server => words.push(word.clone()),
            "server" => {
                place = Place::Server;
                words.push(word.clone());
            }
            "session" => {
                place = Place::Verbatim;
                words.push("sessions".to_string());
            }
            // `termio ls` and the other shortcuts go out in full, so a host
            // on a build from before them still knows the command.
            "ls" | "list" | "spawn" | "run" | "send" | "read" | "attach" | "close" => {
                place = Place::Verbatim;
                words.push("sessions".to_string());
                words.push(word.clone());
            }
            _ => {
                place = Place::Verbatim;
                words.push(word.clone());
            }
        }
    }
    words
}

fn print_report(report: &lifecycle::Report, json: bool) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(report)?);
    } else {
        println!("{}", report.describe());
    }
    let code = report.exit_code();
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}

async fn run_here(cmd: ServerCmd) -> Result<()> {
    match cmd {
        ServerCmd::Status { json } => {
            let status = lifecycle::status().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                lifecycle::print_status(&status);
            }
            Ok(())
        }

        ServerCmd::Logs {
            path,
            follow,
            lines,
        } => log::show(path, follow, lines).await,

        ServerCmd::Stop { force, json } => {
            let outcome = lifecycle::stop(force).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&outcome)?);
            } else {
                println!("{}", outcome.message);
                for session in &outcome.busy {
                    println!("  • {} — {}", session.name, session.command);
                }
            }
            if !outcome.stopped {
                std::process::exit(lifecycle::EXIT_BUSY);
            }
            Ok(())
        }

        ServerCmd::Deploy {
            force,
            stage_only,
            handoff_only,
            json,
            bin,
            target,
        } => {
            // A global flag set on `server` is not visible to clap's `requires`
            // on the verb, so the pairing is checked here.
            if bin.is_some() || target.is_some() {
                bail!("--bin and --target choose what to send to another machine; add --host <HOST>");
            }
            let options = lifecycle::Options {
                force,
                stage_only,
                handoff_only,
            };
            let report =
                lifecycle::reconcile(&lifecycle::LocalNode, lifecycle::BUILD_VERSION, options)
                    .await;
            print_report(&report, json)
        }

        ServerCmd::Tailscale { cmd } => match cmd {
            TailscaleCmd::On {
                hostname,
                auth_key_file,
                no_wait,
            } => {
                tailnet::run_on(tailnet::OnOptions {
                    hostname,
                    auth_key_file,
                    no_wait,
                })
                .await
            }
            TailscaleCmd::Off => tailnet::run_off(),
            TailscaleCmd::Logout => tailnet::run_logout().await,
            TailscaleCmd::Status { json } => tailnet::run_status(json),
        },

        ServerCmd::Service { cmd } => service::run(cmd),

        ServerCmd::Handoff { json, binary } => lifecycle::run_handoff(json, binary).await,

        // A bare array: older clients on other boxes parse exactly this.
        ServerCmd::List { json } => list_sessions(json, false).await,
        ServerCmd::Create(args) => create_session(args, None).await,
        ServerCmd::Attach(args) => attach_session(args).await,
        ServerCmd::Kill { target, json } => close_session(&target, json).await,
        ServerCmd::Send {
            target,
            text,
            no_enter,
            json,
        } => send_to_session(&target, &text.join(" "), !no_enter, json).await,

        ServerCmd::Watch { root, since } => client::watch(&root, since).await,
    }
}

/// `termio session create`: a session on this machine's daemon that no app
/// window shows.
#[derive(Args)]
pub struct CreateArgs {
    /// A name to address the session by (default: its id).
    #[arg(long, value_name = "NAME")]
    pub name: Option<String>,
    /// The working directory (default: the daemon's home directory).
    #[arg(long, value_name = "DIR")]
    pub cwd: Option<String>,
    /// Print the reply as JSON.
    #[arg(long)]
    pub json: bool,
    /// The program and its arguments, after `--` (default: your login shell).
    #[arg(last = true, value_name = "PROGRAM")]
    pub argv: Vec<String>,
}

/// `termio session attach`.
#[derive(Args)]
pub struct AttachArgs {
    /// The session, by link, id, id prefix or name. A name that matches
    /// nothing creates a session with that name.
    #[arg(value_name = "SESSION")]
    pub target: String,
    /// The working directory, if the session is created.
    #[arg(long, value_name = "DIR")]
    pub cwd: Option<String>,
    /// Fail instead of creating a session that does not exist.
    #[arg(long)]
    pub no_create: bool,
    /// Watch the output with no keyboard, no resize and no write access.
    #[arg(long)]
    pub observe: bool,
    /// Receive changed grid rows instead of the program's bytes. Opt-in: it
    /// costs 8.6× more bytes on scrolling output, and pays off only for
    /// catch-up and sparse full-screen redraws.
    #[arg(long, hide_short_help = true)]
    pub grid_diff: bool,
    /// The program and its arguments, if the session is created, after `--`.
    #[arg(last = true, value_name = "PROGRAM")]
    pub argv: Vec<String>,
}

/// Every session the daemon hosts, across projects and apps. Starts the
/// daemon if none is running, so a fresh box answers "no sessions".
/// `contract` wraps the JSON in the reply shape every `termio session` verb
/// prints; without it the JSON is the bare array.
pub async fn list_sessions(json: bool, contract: bool) -> Result<()> {
    let sessions = client::list().await?;
    if json && contract {
        // The contract omits a field it does not know rather than send null.
        let mut rows = serde_json::to_value(&sessions)?;
        if let Some(rows) = rows.as_array_mut() {
            for row in rows.iter_mut().filter_map(serde_json::Value::as_object_mut) {
                row.retain(|_, value| !value.is_null());
            }
        }
        let reply = serde_json::json!({ "ok": true, "schema_version": 1, "sessions": rows });
        println!("{}", serde_json::to_string_pretty(&reply)?);
        return Ok(());
    }
    if json {
        println!("{}", serde_json::to_string_pretty(&sessions)?);
        return Ok(());
    }
    if sessions.is_empty() {
        println!("no sessions");
        return Ok(());
    }
    println!(
        "{:<10} {:<14} {:>6} {:>7} {:>4}  COMMAND",
        "ID", "NAME", "PID", "CLIENTS", "SIZE"
    );
    for s in sessions {
        println!(
            "{:<10} {:<14} {:>6} {:>7} {:>3}x{:<3} {}",
            s.id,
            s.name,
            s.pid,
            s.attached_clients,
            s.rows,
            s.cols,
            s.command.replace('\n', "; ")
        );
    }
    Ok(())
}

/// Creates a session on the daemon. `command` is a shell command line, which
/// the daemon runs in the box's login shell; `argv` runs a program directly.
pub async fn create_session(args: CreateArgs, command: Option<String>) -> Result<()> {
    let (rows, cols) = client::term_size();
    let spec = CreateSpec {
        name: args.name,
        cwd: args.cwd,
        argv: args.argv,
        command,
        env: Vec::new(),
        rows,
        cols,
        workstream: None,
        place: None,
    };
    let id = client::create(spec).await?;
    if args.json {
        println!("{}", serde_json::json!({ "ok": true, "schema_version": 1, "id": id }));
    } else {
        println!("{id}");
    }
    Ok(())
}

/// `termio session run` with no app: a login shell on termiod with `line`
/// typed into it, as the app's `run` types it. The shell stays when the
/// command exits, so its output stays on the screen for `read`. Replies in
/// the shape of the app's `run` reply.
pub async fn run_session(args: CreateArgs, line: String) -> Result<()> {
    let (rows, cols) = client::term_size();
    let json = args.json;
    let spec = CreateSpec {
        name: args.name,
        cwd: args.cwd,
        argv: Vec::new(),
        command: None,
        env: Vec::new(),
        rows,
        cols,
        workstream: None,
        place: None,
    };
    let id = client::create(spec).await?;
    settle(&id, rows, cols).await;
    let mut data = line.into_bytes();
    data.push(b'\r');
    client::send(&id, data).await?;
    if json {
        let reply = serde_json::json!({
            "ok": true, "schema_version": 1, "id": id, "target": id, "title": id,
            "created": true, "queued": true,
        });
        println!("{reply}");
    } else {
        println!("started {id} — command queued; use this address for follow-ups");
        println!("  (read its output with `termio session read {id}`)");
    }
    Ok(())
}

/// Waits for a new shell to finish starting, by the app's rule: after a
/// beat to start painting, two identical frames that are not blank, or 10 s.
/// Typed before then, the line can be eaten by the shell's startup files.
async fn settle(id: &str, rows: u16, cols: u16) {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    tokio::time::sleep(std::time::Duration::from_millis(700)).await;
    let mut previous: Option<String> = None;
    while tokio::time::Instant::now() < deadline {
        // A shell that already exited fails the send that follows, which
        // reports it; a daemon that stops answering is cut off at the deadline.
        let screen = tokio::time::timeout_at(deadline, client::observe_screen_rows(id, rows, cols));
        let Ok(Ok(rows)) = screen.await else {
            return;
        };
        let frame = rows.join("\n").trim().to_string();
        if !frame.is_empty() {
            if previous.as_deref() == Some(frame.as_str()) {
                return;
            }
            previous = Some(frame);
        }
        tokio::time::sleep(std::time::Duration::from_millis(350)).await;
    }
}

pub async fn attach_session(args: AttachArgs) -> Result<()> {
    let existing = resolve(&args.target).await?;
    let target = existing.as_ref().map_or(args.target.clone(), |info| info.id.clone());
    let create_if_missing = if args.no_create || existing.is_some() {
        None
    } else {
        let (rows, cols) = if args.observe {
            (24, 80)
        } else {
            client::term_size()
        };
        Some(CreateSpec {
            name: Some(args.target.clone()),
            cwd: args.cwd,
            argv: args.argv,
            command: None,
            env: Vec::new(),
            rows,
            cols,
            workstream: None,
            place: None,
        })
    };
    if args.observe {
        client::observe(&target, create_if_missing, args.grid_diff).await
    } else {
        client::attach(&target, create_if_missing, args.grid_diff, None).await
    }
}

/// Ends a session and its process group. Replies the way the app's `close`
/// does, on stdout.
pub async fn close_session(target: &str, json: bool) -> Result<()> {
    let info = resolve_running_or_fail(target).await?;
    client::kill(&info.id).await?;
    if json {
        println!(
            "{}",
            serde_json::json!({ "ok": true, "schema_version": 1, "id": info.id, "closed": info.id, "title": info.name })
        );
    } else {
        println!("closed {} ({})", info.id, info.name);
    }
    Ok(())
}

/// Types `text` into a session, with a Return after it when `enter` is set.
/// The bytes go as they are: the daemon's one-shot `send` has no key encoder,
/// so named keys and `--wait` belong to the app.
pub async fn send_to_session(target: &str, text: &str, enter: bool, json: bool) -> Result<()> {
    // The app refuses an empty send too: a bare Return is rarely what was meant.
    if text.is_empty() {
        bail!("send needs text to send");
    }
    let info = resolve_running_or_fail(target).await?;
    let mut data = text.as_bytes().to_vec();
    if enter {
        data.push(b'\r');
    }
    client::send(&info.id, data).await?;
    if json {
        println!(
            "{}",
            serde_json::json!({ "ok": true, "schema_version": 1, "id": info.id, "target": info.id, "title": info.name })
        );
    } else {
        println!("sent to {}", info.id);
    }
    Ok(())
}

async fn resolve_running_or_fail(target: &str) -> Result<SessionInfo> {
    match resolve_running(target, LOOKUP_TIMEOUT).await? {
        Some(info) => Ok(info),
        None => bail!("no session matches '{target}'"),
    }
}

/// How long a lookup waits for a running daemon to list its sessions.
pub const LOOKUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// `resolve` against a daemon that is already running. No daemon is no
/// session, so a lookup that finds nothing never leaves a daemon behind. A
/// daemon that accepts but never answers is an error after `timeout`, never
/// a hang.
pub async fn resolve_running(
    target: &str,
    timeout: std::time::Duration,
) -> Result<Option<SessionInfo>> {
    let sessions = match tokio::time::timeout(timeout, client::sessions_of_running_daemon()).await {
        Ok(sessions) => sessions?,
        Err(_) => bail!("termiod did not answer within {}s", timeout.as_secs()),
    };
    match sessions {
        Some(sessions) => resolve_in(&sessions, target),
        None => Ok(None),
    }
}

/// The daemon session `target` names. A target is a `…://session/<id>` link,
/// an id, a name, or a hex prefix of 8 or more characters of an id or of an
/// app session's UUID name; the same forms `termio session` takes from the app.
/// `None` is "no such session"; a prefix that matches two is an error.
pub async fn resolve(target: &str) -> Result<Option<SessionInfo>> {
    let sessions = client::list().await?;
    resolve_in(&sessions, target)
}

/// A target that matches more than one session: the `ambiguous` error of the
/// reply contract, not a daemon failure.
#[derive(Debug)]
pub struct Ambiguous(pub String);

impl std::fmt::Display for Ambiguous {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Ambiguous {}

pub fn resolve_in(sessions: &[SessionInfo], target: &str) -> Result<Option<SessionInfo>> {
    let token = session_token(target);
    if let Some(info) = sessions.iter().find(|info| info.id == token) {
        return Ok(Some(info.clone()));
    }
    // `create --name` takes a name already in use, so a name can be shared.
    let named: Vec<&SessionInfo> = sessions.iter().filter(|info| info.name == token).collect();
    match named.as_slice() {
        [] => {}
        [only] => return Ok(Some((*only).clone())),
        _ => return Err(Ambiguous(format!("more than one session is named '{target}'; use its id")).into()),
    }
    let lower = token.to_lowercase();
    let prefix = lower.len() >= 8 && lower.chars().all(|c| c.is_ascii_hexdigit() || c == '-');
    if !prefix {
        return Ok(None);
    }
    let matches: Vec<&SessionInfo> = sessions
        .iter()
        .filter(|info| {
            info.id.to_lowercase().starts_with(&lower)
                || info.name.to_lowercase().starts_with(&lower)
        })
        .collect();
    match matches.as_slice() {
        [] => Ok(None),
        [only] => Ok(Some((*only).clone())),
        _ => Err(Ambiguous(format!("'{target}' matches more than one session; use a longer id")).into()),
    }
}

/// The id inside a `<scheme>://session/<id>` link; any other target as it is.
pub fn session_token(target: &str) -> String {
    let Some(scheme_end) = target.find("://") else {
        return target.to_string();
    };
    let rest = &target[scheme_end + 3..];
    match rest.to_lowercase().find("session/") {
        Some(index) => rest[index + 8..]
            .split(['/', '?'])
            .next()
            .unwrap_or("")
            .to_string(),
        None => target.to_string(),
    }
}

/// `termio pair` — the pairing token that lets a phone or a browser attach.
///
/// The token authenticates the WebSocket pipe. It is not the session write
/// token, and it never expires: `--rotate` is the only revocation.
#[derive(Args)]
pub struct PairArgs {
    /// Print the reply as JSON.
    #[arg(long)]
    json: bool,
    /// Print the invite as a QR code for a phone to scan off this terminal.
    #[arg(long)]
    qr: bool,
    /// Replace the token. Attached clients detach; no session is killed.
    #[arg(long)]
    rotate: bool,
    /// Stop listening for WebSocket clients on the next start.
    #[arg(long)]
    wss_off: bool,
    /// The URL this box is reachable at, when it is not the daemon's own
    /// `--wss-origin` — a tunnel, or a proxy mounted under a path.
    #[arg(long, value_name = "URL")]
    url: Option<String>,
}

pub fn pair(args: PairArgs) -> Result<()> {
    wss::run_pair(wss::PairOptions {
        json: args.json,
        qr: args.qr,
        rotate: args.rotate,
        wss_off: args.wss_off,
        url: args.url,
    })
}

/// `termio agent install` — termio's agent integration in this machine's agent
/// configs.
///
/// The daemon owns the files, so it decides what goes in them: it reads the
/// same agent manifests the Mac app reads, works out which agent CLIs are
/// actually here, and merges. The client only says which agents the user has
/// enabled.
#[derive(Args)]
pub struct InstallArgs {
    /// Only these agent ids (repeatable). Default: every agent in the catalog
    /// whose CLI is installed here.
    #[arg(long)]
    agent: Vec<String>,
    /// Install the skill but not the hooks.
    #[arg(long)]
    no_hooks: bool,
    /// Install the hooks but not the skill.
    #[arg(long)]
    no_skills: bool,
    /// Install this Mac's skill payload instead of a box's. Hooks are identical
    /// either way — they all report to this daemon.
    #[arg(long)]
    this_mac: bool,
    /// Print the reply as JSON.
    #[arg(long)]
    json: bool,
}

pub async fn install_agents(args: InstallArgs) -> Result<()> {
    use agent::install::{HalfAction, InstallRequest, Reporter};
    let request = InstallRequest::new(
        (!args.agent.is_empty()).then_some(args.agent),
        if args.no_hooks { HalfAction::Leave } else { HalfAction::Install },
        if args.no_skills { HalfAction::Leave } else { HalfAction::Install },
        if args.this_mac { Reporter::ThisMac } else { Reporter::Device },
        Default::default(),
    );
    print_install(request, args.json).await.map(|_| ())
}

/// `termio skill install` — the skill half of `agent install`, alone.
#[derive(Args)]
pub struct SkillInstallArgs {
    /// Only these agent ids (repeatable). Default: every agent in the catalog
    /// whose CLI is installed here.
    #[arg(long)]
    agent: Vec<String>,
    /// Install this Mac's skill, which teaches the app's commands, instead of
    /// a box's.
    #[arg(long)]
    this_mac: bool,
    /// Print the reply as JSON.
    #[arg(long)]
    json: bool,
}

/// The skill this build carries. `install_skill` asks the running daemon,
/// which writes the skill *it* carries: the same bytes when the client and the
/// daemon come from one install, older ones from a daemon not yet upgraded.
pub fn skill_text(this_mac: bool) -> &'static str {
    use agent::install::Reporter;
    if this_mac { Reporter::ThisMac } else { Reporter::Device }.skill()
}

pub async fn install_skill(args: SkillInstallArgs) -> Result<()> {
    use agent::install::{HalfAction, InstallRequest, Reporter};
    let request = InstallRequest::new(
        (!args.agent.is_empty()).then_some(args.agent),
        HalfAction::Leave,
        HalfAction::Install,
        if args.this_mac { Reporter::ThisMac } else { Reporter::Device },
        Default::default(),
    );
    let failed = print_install(request, args.json).await?;
    if failed > 0 {
        bail!("could not install the skill for {failed} agent(s)");
    }
    Ok(())
}

/// `termio skill uninstall` — sweep the skill from every agent; hooks stay.
pub async fn uninstall_skill(json: bool) -> Result<()> {
    use agent::install::{HalfAction, InstallRequest, Reporter};
    let request = InstallRequest::new(
        None,
        HalfAction::Leave,
        HalfAction::Remove,
        Reporter::Device,
        Default::default(),
    );
    let failed = print_install(request, json).await?;
    if failed > 0 {
        bail!("could not remove the skill for {failed} agent(s)");
    }
    Ok(())
}

/// `termio agent uninstall` — remove every agent integration termio installed
/// on this machine.
pub async fn uninstall_agents(json: bool) -> Result<()> {
    use agent::install::{HalfAction, InstallRequest, Reporter};
    let request = InstallRequest::new(
        None,
        HalfAction::Remove,
        HalfAction::Remove,
        Reporter::Device,
        Default::default(),
    );
    print_install(request, json).await.map(|_| ())
}

/// Prints what an install did, and returns how many of its rows failed.
async fn print_install(request: agent::install::InstallRequest, json: bool) -> Result<usize> {
    use agent::install::{HalfAction, InstallStatus};
    let removed = match (request.hooks, request.skills) {
        (HalfAction::Remove, HalfAction::Remove) => {
            Some("removed every agent integration termio installed")
        }
        (HalfAction::Remove, _) => Some("removed termio's hooks from every agent"),
        (_, HalfAction::Remove) => Some("removed termio's skill from every agent"),
        _ => None,
    };
    let results = client::install_agents(request).await?;
    let failed = results
        .iter()
        .filter(|result| result.status == InstallStatus::Failed)
        .count();
    if json {
        println!("{}", serde_json::to_string_pretty(&results)?);
        return Ok(failed);
    }
    if results.is_empty() {
        // Removal sweeps every directory termio has ever written into and has
        // nothing per-agent to report; an install with nothing to report found
        // no agent on this box at all.
        match removed {
            Some(sentence) => println!("{sentence}"),
            None => println!("no agent on this box declares an integration to install"),
        }
        return Ok(failed);
    }
    for result in &results {
        let mark = match result.status {
            InstallStatus::Installed => "ok",
            InstallStatus::Failed => "failed",
            InstallStatus::Skipped => "skipped",
        };
        print!("{:<8} {:<14} {:<6} {}", mark, result.name, result.kind, result.path);
        match &result.detail {
            Some(detail) => println!(" — {detail}"),
            None => println!(),
        }
    }
    Ok(failed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(line: &str) -> Vec<String> {
        let argv: Vec<String> = line.split(' ').map(str::to_string).collect();
        verb_words_of(&argv)
    }

    /// The host's own `termio` must parse exactly what was typed, less the
    /// host: every spelling of `--host` goes, wherever it stands, and nothing
    /// after `--` is touched, even a `-H`.
    #[test]
    fn the_host_is_the_only_thing_removed() {
        assert_eq!(words("termio -H box server status --json"), ["server", "status", "--json"]);
        assert_eq!(words("termio server --host box deploy --json"), ["server", "deploy", "--json"]);
        assert_eq!(words("termio --host=box session ls"), ["sessions", "ls"]);
        assert_eq!(words("termio -Hbox server logs -n 5"), ["server", "logs", "-n", "5"]);
        assert_eq!(
            words("termio -H box session create -- sh -c -H"),
            ["sessions", "create", "--", "sh", "-c", "-H"]
        );
    }

    /// A shortcut reaches the host as the `session` verb it stands for, which
    /// every build parses. Its own words, a `-H` among them, are untouched.
    #[test]
    fn a_shortcut_goes_out_as_its_session_verb() {
        assert_eq!(words("termio -H box ls --json"), ["sessions", "ls", "--json"]);
        assert_eq!(words("termio -H box attach 8de0b387"), ["sessions", "attach", "8de0b387"]);
        assert_eq!(
            words("termio -H box send 8de0b387 -Hello"),
            ["sessions", "send", "8de0b387", "-Hello"]
        );
    }

    /// Past the command word, `-H` is text the verb owns.
    #[test]
    fn a_later_dash_h_is_left_alone() {
        assert_eq!(
            words("termio -H box session send 8de0b387 -Hello"),
            ["sessions", "send", "8de0b387", "-Hello"]
        );
    }

    /// Within `server` the host is global, as it was before it moved to the
    /// root, so every spelling and position still goes.
    #[test]
    fn a_server_host_goes_from_any_position() {
        assert_eq!(words("termio server attach rmt --host box"), ["server", "attach", "rmt"]);
        assert_eq!(words("termio server logs -fHbox"), ["server", "logs", "-f"]);
        assert_eq!(
            words("termio server logs -fH box -n 5"),
            ["server", "logs", "-f", "-n", "5"]
        );
        assert_eq!(
            words("termio server -H box send x -- -H y"),
            ["server", "send", "x", "--", "-H", "y"]
        );
    }

    fn session(id: &str, name: &str) -> SessionInfo {
        serde_json::from_value(serde_json::json!({
            "id": id, "name": name, "cwd": "/", "command": "sh", "pid": 1,
            "rows": 24, "cols": 80, "clients": 0, "created_unix": 0, "alive": true,
        }))
        .expect("a session")
    }

    /// Every target form `termio session` documents reaches the same session,
    /// and a name never matches as a prefix.
    #[test]
    fn a_target_is_a_link_an_id_a_prefix_or_a_name() {
        let uuid = "8de0b387-485a-4016-8990-cbcbfff03199";
        let sessions = [session("a1b2c3d4e5", uuid), session("ffff0000aa", "build")];
        let id = |target: &str| resolve_in(&sessions, target).unwrap().map(|info| info.id);
        assert_eq!(id(uuid).as_deref(), Some("a1b2c3d4e5"));
        assert_eq!(id(&format!("termio://session/{uuid}")).as_deref(), Some("a1b2c3d4e5"));
        assert_eq!(id(&format!("termio-dev://session/{uuid}?focus=1")).as_deref(), Some("a1b2c3d4e5"));
        assert_eq!(id("8de0b387").as_deref(), Some("a1b2c3d4e5"));
        assert_eq!(id("a1b2c3d4e5").as_deref(), Some("a1b2c3d4e5"));
        assert_eq!(id("build").as_deref(), Some("ffff0000aa"));
        assert_eq!(id("buil"), None);
        assert_eq!(id("8de0b3"), None);
    }

    #[test]
    fn a_prefix_that_matches_two_sessions_is_an_error() {
        let sessions = [session("abcdef0011", "x"), session("abcdef0022", "y")];
        assert!(resolve_in(&sessions, "abcdef00").is_err());
    }

    #[test]
    fn a_name_two_sessions_share_is_an_error() {
        let sessions = [session("abcdef0011", "dup"), session("abcdef0022", "dup")];
        assert!(resolve_in(&sessions, "dup").is_err());
        let by_id = resolve_in(&sessions, "abcdef0022").unwrap().unwrap();
        assert_eq!(by_id.id, "abcdef0022");
    }
}
