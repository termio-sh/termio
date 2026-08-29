//! termiod — durable session host (POC).
//!
//! Architecture (three parts): **host** · **protocol** · **clients**.
//! `termiod serve` is the host; other subcommands are reference clients
//! (or SSH transport helpers). Detach never kills a session.
//! Local = remote to localhost over a Unix socket.
//!
//! See `ARCHITECTURE.md` and `README.md`.

mod agent;
mod client;
mod daemon;
mod files;
mod git;
mod id;
mod lifecycle;
mod log;
mod paths;
mod proc;
mod protocol;
mod pty;
mod remote;
mod resource;
mod service;
mod session;
mod tombstone;
mod wss;

use anyhow::Result;
use clap::{Parser, Subcommand};
use protocol::CreateSpec;
use std::net::SocketAddr;

#[derive(Parser)]
#[command(
    name = "termiod",
    version = lifecycle::BUILD_VERSION,
    about = "Durable session host — viewers attach; detach ≠ kill (#164 POC)",
    long_about = "termiod is a session host (not a window manager).\n\
A session lives in the host; Mac/iOS/CLI only attach.\n\
Local: Unix socket. Remote: SSH pipe to the same host binary.\n\
See ARCHITECTURE.md."
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
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

    /// Run the session host in the foreground (usually auto-started).
    Serve {
        /// Also accept WebSocket clients on this address (default port 8790).
        ///
        /// Loopback only — 127.0.0.0/8 or ::1. `0.0.0.0`, `[::]`, a LAN
        /// address and a hostname that resolves off loopback are all refused.
        /// Put TLS in front with Tailscale Serve or Caddy; termiod never
        /// terminates it. Needs a token from `termiod pair`.
        #[arg(long, value_name = "ADDR", value_parser = wss::parse_bind)]
        wss: Option<SocketAddr>,

        /// Browser origin allowed on the WebSocket. Repeatable, or comma-separated.
        ///
        /// Required in front of a TLS terminator: the default same-origin check
        /// compares the page's Origin against a loopback Host and refuses.
        #[arg(long, value_name = "URL", value_parser = wss::parse_origin, value_delimiter = ',')]
        wss_origin: Vec<wss::Origin>,
    },

    /// Print the pairing token that lets a phone or a browser attach.
    ///
    /// The token authenticates the WebSocket pipe. It is not the session write
    /// token, and it never expires: `--rotate` is the only revocation.
    Pair {
        /// Emit the invite as JSON — url, token, host_id, proto.
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
    },

    /// Create a new session and print its id.
    Create {
        /// Human name for the session (defaults to the id).
        #[arg(long)]
        name: Option<String>,
        /// Working directory for the session's process.
        #[arg(long)]
        cwd: Option<String>,
        /// Program + args to run. Empty ⇒ your login shell. Put after `--`.
        #[arg(last = true)]
        argv: Vec<String>,
    },

    /// List sessions — locally, or across a fleet with `--host`.
    List {
        /// Emit JSON instead of a table.
        #[arg(long)]
        json: bool,
        /// Also list this SSH host's daemon. Repeatable. Queried concurrently;
        /// a host that is down is reported in place, not fatal.
        #[arg(long)]
        host: Vec<String>,
        /// Skip the local daemon and show only the `--host` fleet.
        #[arg(long)]
        no_local: bool,
    },

    /// Kill a session (by id or name) and its process group.
    Kill {
        /// Session id or name.
        target: String,
    },

    /// Inject input into a session without attaching.
    Send {
        /// Session id or name.
        target: String,
        /// Text to inject.
        text: Vec<String>,
        /// Do not append a newline (Enter) after the text.
        #[arg(long)]
        no_enter: bool,
    },

    /// Set agent/workstream status metadata for a session.
    ///
    /// What every installed hook runs, on every machine. The mining flags exist
    /// because a hook's host hands it a JSON blob on stdin that nothing else
    /// sees, so mining here is what lets a device agent carry the transcript
    /// path, the conversation id, the running tool and a first-prompt label.
    ///
    /// Flag names match `termio agent report`'s deliberately: it is the public
    /// hook contract and now forwards here, and two spellings of one vocabulary
    /// is how the report forms drifted apart in the first place.
    SetStatus {
        /// Session id or name.
        target: String,
        /// working, idle, needs_you, done, failed, or unknown.
        status: String,
        /// Optional display title.
        #[arg(long)]
        title: Option<String>,
        /// Read stdin as the host's JSON payload and forward its
        /// `transcript_path`, so a client can address the raw Q&A log.
        #[arg(long)]
        transcript: bool,
        /// Forward this conversation id verbatim, for an in-process plugin that
        /// already holds the live id.
        #[arg(long, value_name = "ID")]
        conversation: Option<String>,
        /// Mine the conversation id from this stdin field. Agents disagree on
        /// the name: Codex `session_id`, Grok `sessionId`.
        #[arg(long, value_name = "FIELD")]
        conversation_from: Option<String>,
        /// Mine the running tool's name from this stdin field (Claude
        /// `tool_name`). Events without the field simply omit it.
        #[arg(long, value_name = "FIELD")]
        tool_from: Option<String>,
        /// Mine a first-prompt title candidate from this stdin field.
        #[arg(long, value_name = "FIELD")]
        prompt_title_from: Option<String>,
        /// Stay silent on stdout and print `{}` at the end, for agents (Cursor)
        /// that read a hook's stdout as its JSON reply.
        #[arg(long)]
        reply: bool,
    },

    /// Install termio's agent integration into this box's agent configs.
    ///
    /// The daemon owns the files, so it decides what goes in them: it reads the
    /// same agent manifests the Mac app reads, works out which agent CLIs are
    /// actually here, and merges. The client only says which agents the user
    /// has enabled.
    Agent {
        #[command(subcommand)]
        cmd: AgentCmd,
    },

    /// Attach to a session (interactively by default, or as an observer).
    Attach {
        /// Session id or name to attach to / create.
        target: String,
        /// Working directory if the session is created.
        #[arg(long)]
        cwd: Option<String>,
        /// Do not create the session if it does not already exist.
        #[arg(long)]
        no_create: bool,
        /// Stream output without a tty, stdin, resize handling, or write access.
        #[arg(long)]
        observe: bool,
        /// Use capability-gated dirty-row grid diffs instead of downstream PTY
        /// bytes. Opt-in on every transport: measured 8.6× *more* bytes than
        /// raw for scrolling output, since every row goes dirty and each cell
        /// costs 16 bytes. Its value is catch-up and sparse TUI redraw.
        #[arg(long)]
        grid_diff: bool,
        /// Accepted and ignored; raw is already the default everywhere.
        #[arg(long, hide = true, conflicts_with = "grid_diff")]
        no_grid_diff: bool,
        /// Attach to a daemon on this SSH host: the framed protocol rides
        /// `ssh <host> termiod stdio`, so local and remote differ only in the pipe.
        #[arg(long)]
        host: Option<String>,
        /// Program + args if the session is created. Put after `--`.
        #[arg(last = true)]
        argv: Vec<String>,
    },

    /// Stream a workspace's filesystem changes from the host (§C.10).
    ///
    /// The host owns the watch; this is a resumable subscriber. Stop it, change
    /// the tree, restart with `--since <seq>` and the missed batches replay —
    /// or the host reports a gap when the cursor has aged out of its ring.
    Watch {
        /// Absolute workspace root to watch on the host.
        root: String,
        /// Resume from this seq instead of starting fresh.
        #[arg(long)]
        since: Option<u64>,
    },

    /// Bridge the framed protocol over stdin/stdout to the local daemon.
    ///
    /// Non-interactive: no tty, no raw mode. Run as `ssh <host> termiod stdio`,
    /// it lets a native client speak the same framed protocol to a remote host
    /// that it speaks to a local Unix socket. The daemon auto-starts.
    Stdio,

    /// What this machine has: the binary, the daemon on its socket, and the
    /// daemon's sessions. Read-only, one process, one connection.
    ///
    /// The daemon's version comes from the daemon, not from the file on disk:
    /// the two differ exactly when an update is staged and not yet running.
    Status {
        #[arg(long)]
        json: bool,
    },

    /// Ask the daemon to stop. Declines while a command is running or an
    /// agent is mid-task, and names the sessions; `--force` stops it regardless.
    /// A client attached to an idle prompt does not hold it up.
    ///
    /// The daemon is found by the credential on its socket, never by its
    /// command line, so a second daemon someone runs by hand on another socket
    /// is never the one stopped. Exit 3 means "in use", not failure.
    Stop {
        /// Stop even while work is in progress. Every session ends.
        #[arg(long)]
        force: bool,
        #[arg(long)]
        json: bool,
    },

    /// Install or update termiod here or on an SSH host, and verify it.
    ///
    /// One loop for every state the machine can be in: nothing installed, an
    /// older binary, a newer binary the daemon has not picked up. It stages
    /// the binary this build carries, asks the old daemon to stop when it is
    /// idle, checks the new one answers, and puts the previous binary back if
    /// it does not. Running it again is the recovery from any outcome.
    Deploy {
        /// SSH host alias from `~/.ssh/config` (or user@host). Without it,
        /// this machine's own daemon is checked and restarted if stale.
        #[arg(long)]
        host: Option<String>,
        /// Stop the old daemon even while its sessions have work in progress.
        #[arg(long)]
        force: bool,
        /// Put the binary in place and leave the running daemon alone.
        #[arg(long)]
        stage_only: bool,
        /// Emit the outcome as one JSON document on stdout.
        #[arg(long)]
        json: bool,
    },

    /// Remote (SSH) deploy and attach — see `termiod remote --help`.
    Remote {
        #[command(subcommand)]
        cmd: remote::RemoteCmd,
    },

    /// Keep the daemon running across logins and crashes (launchd on macOS,
    /// systemd --user on Linux).
    Service {
        #[command(subcommand)]
        cmd: service::ServiceCmd,
    },
}

#[derive(Subcommand)]
enum AgentCmd {
    /// Install status hooks and the termio skill for the agents on this box.
    Install {
        /// Only these agent ids (repeatable). Default: every agent in the
        /// catalog whose CLI is installed here.
        #[arg(long)]
        agent: Vec<String>,
        /// Install the skill but not the hooks.
        #[arg(long)]
        no_hooks: bool,
        /// Install the hooks but not the skill.
        #[arg(long)]
        no_skills: bool,
        /// Install this Mac's skill payload (which teaches the `termio` CLI)
        /// instead of a box's. Hooks are identical either way — they all report
        /// to this daemon now.
        #[arg(long)]
        this_mac: bool,
        /// Version stamped into each hook command. Defaults to this daemon's.
        #[arg(long, value_name = "VERSION")]
        hook_version: Option<String>,
        /// Emit the per-agent results as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Remove every agent integration termio has installed on this box.
    Uninstall {
        #[arg(long)]
        json: bool,
    },
}

async fn run_agent(cmd: AgentCmd) -> Result<()> {
    use agent::install::{HalfAction, InstallRequest, InstallStatus, Reporter};

    let (request, json) = match cmd {
        AgentCmd::Install {
            agent,
            no_hooks,
            no_skills,
            this_mac,
            hook_version,
            json,
        } => (
            InstallRequest::new(
                (!agent.is_empty()).then_some(agent),
                if no_hooks { HalfAction::Leave } else { HalfAction::Install },
                if no_skills { HalfAction::Leave } else { HalfAction::Install },
                if this_mac { Reporter::ThisMac } else { Reporter::Device },
                hook_version.unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string()),
            ),
            json,
        ),
        AgentCmd::Uninstall { json } => (
            InstallRequest::new(
                None,
                HalfAction::Remove,
                HalfAction::Remove,
                Reporter::Device,
                env!("CARGO_PKG_VERSION").to_string(),
            ),
            json,
        ),
    };

    let removing = request.hooks == HalfAction::Remove && request.skills == HalfAction::Remove;
    let results = client::install_agents(request).await?;
    if json {
        println!("{}", serde_json::to_string_pretty(&results)?);
        return Ok(());
    }
    if results.is_empty() {
        // Removal sweeps every directory termio has ever written into and has
        // nothing per-agent to report; an install with nothing to report found
        // no agent on this box at all.
        println!(
            "{}",
            if removing {
                "removed every agent integration termio installed"
            } else {
                "no agent on this box declares an integration to install"
            }
        );
        return Ok(());
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
    Ok(())
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
/// Only a string, and only at the top level: the shell CLI this replaces mined
/// exactly that much, and a hook contract that quietly started accepting nested
/// paths would be a second dialect to keep in step.
fn mine_field(payload: &serde_json::Value, field: &str) -> Option<String> {
    payload
        .get(field)?
        .as_str()
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Logs {
            path,
            follow,
            lines,
        } => log::show(path, follow, lines).await,

        Cmd::Serve { wss, wss_origin } => daemon::serve(wss, wss_origin).await,

        Cmd::Pair {
            json,
            qr,
            rotate,
            wss_off,
            url,
        } => wss::run_pair(wss::PairOptions {
            json,
            qr,
            rotate,
            wss_off,
            url,
        }),

        Cmd::Create { name, cwd, argv } => {
            let (rows, cols) = client::term_size();
            let spec = CreateSpec {
                name,
                cwd,
                argv,
                env: Vec::new(),
                rows,
                cols,
                workstream: None,
            };
            let id = client::create(spec).await?;
            println!("{id}");
            Ok(())
        }

        Cmd::Watch { root, since } => client::watch(&root, since).await,

        Cmd::List {
            json,
            host,
            no_local,
        } => {
            // A cloud fleet is many hosts. Sweep them concurrently so the view
            // costs one slow host, not the sum of all of them.
            let mut fleet: Vec<(String, anyhow::Result<Vec<_>>)> = Vec::new();
            if !no_local {
                fleet.push(("local".to_string(), client::list().await));
            }
            let probes: Vec<_> = host
                .into_iter()
                .map(|h| tokio::spawn(async move { remote::list_json(&h).await }))
                .collect();
            for probe in probes {
                match probe.await {
                    Ok(pair) => fleet.push(pair),
                    Err(e) => fleet.push(("?".to_string(), Err(anyhow::anyhow!("{e}")))),
                }
            }

            if json {
                // Back-compat: the plain local list stays a flat SessionInfo
                // array. Only a genuine cross-host query changes the shape.
                if fleet.len() == 1 && fleet[0].0 == "local" {
                    let sessions = fleet.pop().unwrap().1?;
                    println!("{}", serde_json::to_string_pretty(&sessions)?);
                    return Ok(());
                }
                let payload: Vec<_> = fleet
                    .iter()
                    .map(|(host, result)| match result {
                        Ok(sessions) => {
                            serde_json::json!({"host": host, "sessions": sessions})
                        }
                        Err(e) => {
                            serde_json::json!({"host": host, "error": format!("{e:#}")})
                        }
                    })
                    .collect();
                println!("{}", serde_json::to_string_pretty(&payload)?);
                return Ok(());
            }

            let multi = fleet.len() > 1;
            // Width the host column to the widest name so a long alias does
            // not shear the table.
            let hw = fleet.iter().map(|(h, _)| h.len()).max().unwrap_or(4).max(4);
            let has_rows = fleet
                .iter()
                .any(|(_, r)| matches!(r, Ok(sessions) if !sessions.is_empty()));
            if has_rows {
                if multi {
                    print!("{:<hw$} ", "HOST");
                }
                println!(
                    "{:<10} {:<14} {:>6} {:>7} {:>4}  COMMAND",
                    "ID", "NAME", "PID", "CLIENTS", "SIZE"
                );
            }
            for (host, result) in &fleet {
                match result {
                    // A host that is down is a row, not an abort — and it must
                    // read differently from a host that is simply idle.
                    Err(e) => println!("{host:<hw$} unreachable: {e:#}"),
                    Ok(sessions) if sessions.is_empty() => {
                        if multi {
                            println!("{host:<hw$} (no sessions)");
                        }
                    }
                    Ok(sessions) => {
                        for s in sessions {
                            if multi {
                                print!("{host:<hw$} ");
                            }
                            println!(
                                "{:<10} {:<14} {:>6} {:>7} {:>3}x{:<3} {}",
                                s.id, s.name, s.pid, s.attached_clients, s.rows, s.cols, s.command
                            );
                        }
                    }
                }
            }
            if !has_rows && !multi {
                println!("no sessions");
            }
            Ok(())
        }

        Cmd::Kill { target } => {
            client::kill(&target).await?;
            eprintln!("killed {target}");
            Ok(())
        }

        Cmd::Send {
            target,
            text,
            no_enter,
        } => {
            let mut data = text.join(" ").into_bytes();
            if !no_enter {
                data.push(b'\r');
            }
            client::send(&target, data).await?;
            Ok(())
        }

        Cmd::SetStatus {
            target,
            status,
            title,
            transcript,
            conversation,
            conversation_from,
            tool_from,
            prompt_title_from,
            reply,
        } => {
            let wants_stdin = transcript
                || conversation_from.is_some()
                || tool_from.is_some()
                || prompt_title_from.is_some();
            let payload = if wants_stdin { read_hook_payload() } else { None };
            let mined = |field: &Option<String>| -> Option<String> {
                let field = field.as_deref()?;
                mine_field(payload.as_ref()?, field)
            };
            let details = protocol::StatusDetails {
                transcript_path: transcript
                    .then(|| payload.as_ref().and_then(|p| mine_field(p, "transcript_path")))
                    .flatten(),
                conversation_id: conversation.clone().or_else(|| mined(&conversation_from)),
                tool: mined(&tool_from),
                prompt_title: mined(&prompt_title_from),
            };
            let outcome = client::set_status(&target, &status, title, details).await;
            // Cursor reads a hook's stdout as its JSON reply, so the contract is
            // an empty object even when the report itself could not be delivered.
            if reply {
                print!("{{}}");
            }
            outcome
        }

        Cmd::Attach {
            target,
            cwd,
            no_create,
            observe,
            grid_diff,
            no_grid_diff,
            host,
            argv,
        } => {
            // Raw stays the default on every transport, including remote.
            // Measured against a real VPS (2026-08-05, 300-line burst): raw
            // 50 KB vs grid 436 KB — 8.6× *worse* for grid. Scrolling output
            // dirties every row, so dirty-row filtering saves nothing and the
            // 16-byte-per-cell wire format is pure inflation. `G` earns its
            // place as a catch-up/degrade mode (a client that has fallen
            // behind skips intermediate states) and for sparse full-screen
            // TUI updates — not as a steady-state bandwidth win.
            let _ = no_grid_diff;
            if observe && host.is_some() {
                anyhow::bail!("--observe does not yet support --host; run it on the remote instead");
            }
            let create_if_missing = if no_create {
                None
            } else {
                let (rows, cols) = if observe {
                    (24, 80)
                } else {
                    client::term_size()
                };
                Some(CreateSpec {
                    name: Some(target.clone()),
                    cwd,
                    argv,
                    env: Vec::new(),
                    rows,
                    cols,
                    workstream: None,
                })
            };
            if observe {
                client::observe(&target, create_if_missing, grid_diff).await
            } else {
                client::attach(&target, create_if_missing, grid_diff, host.as_deref()).await
            }
        }

        Cmd::Agent { cmd } => run_agent(cmd).await,

        Cmd::Stdio => client::stdio().await,

        Cmd::Status { json } => {
            let status = lifecycle::status().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                lifecycle::print_status(&status);
            }
            Ok(())
        }

        Cmd::Stop { force, json } => {
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

        Cmd::Deploy {
            host,
            force,
            stage_only,
            json,
        } => {
            let options = lifecycle::Options { force, stage_only };
            let report = match host {
                Some(host) => remote::reconcile(&remote::SshNode::new(host), options).await,
                None => {
                    lifecycle::reconcile(&lifecycle::LocalNode, lifecycle::BUILD_VERSION, options)
                        .await
                }
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!("{}", report.describe());
            }
            let code = report.exit_code();
            if code != 0 {
                std::process::exit(code);
            }
            Ok(())
        }

        Cmd::Remote { cmd } => remote::run(cmd).await,

        Cmd::Service { cmd } => service::run(cmd),
    }
}
