//! termiod — durable session host (POC).
//!
//! Architecture (three parts): **host** · **protocol** · **clients**.
//! `termiod serve` is the host; other subcommands are reference clients
//! (or SSH transport helpers). Detach never kills a session.
//! Local = remote to localhost over a Unix socket.
//!
//! See `ARCHITECTURE.md` and `README.md`.

mod client;
mod daemon;
mod files;
mod git;
mod paths;
mod protocol;
mod pty;
mod remote;
mod resource;
mod service;
mod session;
mod tombstone;

use anyhow::Result;
use clap::{Parser, Subcommand};
use protocol::CreateSpec;

#[derive(Parser)]
#[command(
    name = "termiod",
    version,
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
    /// Run the session host in the foreground (usually auto-started).
    Serve,

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
    SetStatus {
        /// Session id or name.
        target: String,
        /// working, idle, needs_you, done, failed, or unknown.
        status: String,
        /// Optional display title.
        #[arg(long)]
        title: Option<String>,
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

    /// Remote (SSH) deploy and attach — see `termiod remote --help`.
    Remote {
        #[command(subcommand)]
        cmd: remote::RemoteCmd,
    },

    /// Keep the daemon running across logins and crashes (launchd, macOS).
    Service {
        #[command(subcommand)]
        cmd: service::ServiceCmd,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Serve => daemon::serve().await,

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
        } => {
            client::set_status(&target, &status, title).await?;
            Ok(())
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

        Cmd::Stdio => client::stdio().await,

        Cmd::Remote { cmd } => remote::run(cmd).await,

        Cmd::Service { cmd } => service::run(cmd),
    }
}
