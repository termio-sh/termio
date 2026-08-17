//! Remote sessions over **system SSH only** — no custom transport, no public
//! listener. The remote `termiod` owns the PTY; SSH is the transport and the
//! ACL. This covers issue #171 (deploy + attach) and #172 (`remote open`).
//!
//! The trick that makes this ~200 lines instead of a network stack: the daemon
//! auto-starts (detached via `setsid`) on the first client op. So
//! `ssh host termiod attach <id>` runs the *client* on the remote host, whose
//! stdin/stdout are the SSH channel; the daemon it starts survives the SSH
//! disconnect because it is in its own session. Detach ≠ kill, remotely, free.

use anyhow::{bail, Context, Result};
use clap::Subcommand;
use std::process::Command;

/// Where the binary is installed on the remote host. `$HOME` is expanded by
/// the remote shell. Overridable with `TERMIOD_REMOTE_BIN` for custom install
/// paths (and to point tests at a local binary).
pub fn remote_bin() -> String {
    std::env::var("TERMIOD_REMOTE_BIN").unwrap_or_else(|_| "$HOME/.local/bin/termiod".to_string())
}

/// SSH options shared by every outbound connection.
///
/// `ControlMaster` is the load-bearing one for cloud use: the first connection
/// to a host opens a master, and every later channel — another session, the
/// resource plane, a `list` — rides it for about one round trip instead of a
/// fresh TCP and key exchange. Zed does the same thing; unlike Zed we take the
/// user's own `ControlPath` when they have set one rather than overriding it.
pub fn ssh_multiplex_args() -> Vec<String> {
    let mut args = vec![
        "-o".into(),
        "ServerAliveInterval=15".into(),
        "-o".into(),
        "ControlMaster=auto".into(),
        "-o".into(),
        "ControlPersist=10m".into(),
    ];
    if std::env::var_os("TERMIOD_SSH_KEEP_CONTROLPATH").is_none() {
        if let Some(path) = control_path() {
            args.push("-o".into());
            args.push(format!("ControlPath={path}"));
        }
    }
    args
}

/// `%C` is a hash of (host, port, user), so one path template serves every
/// host without collisions.
fn control_path() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let dir = std::path::Path::new(&home).join(".termio").join("ssh");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("%C").display().to_string())
}

#[derive(Subcommand)]
pub enum RemoteCmd {
    /// Build for the remote's arch and install `termiod` over SSH.
    Deploy {
        /// SSH host alias from `~/.ssh/config` (or user@host).
        host: String,
        /// Use this prebuilt Linux binary instead of cross-compiling.
        #[arg(long)]
        bin: Option<String>,
        /// Force a Rust target triple instead of auto-detecting from `uname`.
        #[arg(long)]
        target: Option<String>,
    },

    /// List sessions on a remote host.
    List {
        host: String,
        #[arg(long)]
        json: bool,
    },

    /// Attach to (or create) a session on a remote host.
    Attach {
        host: String,
        /// Session id or name.
        target: String,
        /// Stream output without allocating an SSH tty or accepting input.
        #[arg(long)]
        observe: bool,
        /// Program + args if created. Put after `--`.
        #[arg(last = true)]
        argv: Vec<String>,
    },

    /// One-shot: ensure deployed, create a durable session, then attach (#172).
    Open {
        /// SSH host alias from `~/.ssh/config`.
        host: String,
        /// Remote working directory (default: `~`).
        #[arg(long)]
        cwd: Option<String>,
        /// Agent/shell to launch: `shell` (default), `claude`, `codex`, …
        #[arg(long, default_value = "shell")]
        agent: String,
        /// Session name (default: derived from agent).
        #[arg(long)]
        name: Option<String>,
        /// Skip the deploy check (assume `termiod` is already installed).
        #[arg(long)]
        no_deploy: bool,
    },
}

pub async fn run(cmd: RemoteCmd) -> Result<()> {
    // These shell out to ssh/scp; run them on a blocking thread so the async
    // runtime stays free.
    tokio::task::spawn_blocking(move || run_blocking(cmd)).await?
}

fn run_blocking(cmd: RemoteCmd) -> Result<()> {
    match cmd {
        RemoteCmd::Deploy { host, bin, target } => {
            deploy(&host, bin.as_deref(), target.as_deref())?;
            Ok(())
        }
        RemoteCmd::List { host, json } => {
            let bin = remote_bin();
            let flag = if json { " --json" } else { "" };
            let status = ssh_interactive(&host, false, &format!("{bin} list{flag}"))?;
            std::process::exit(status);
        }
        RemoteCmd::Attach {
            host,
            target,
            observe,
            argv,
        } => {
            let remote = build_attach_cmd(&target, observe, &argv);
            let status = ssh_interactive(&host, !observe, &remote)?;
            std::process::exit(status);
        }
        RemoteCmd::Open {
            host,
            cwd,
            agent,
            name,
            no_deploy,
        } => open(&host, cwd.as_deref(), &agent, name.as_deref(), no_deploy),
    }
}

/// Build the remote `termiod attach` command line.
fn build_attach_cmd(target: &str, observe: bool, argv: &[String]) -> String {
    let bin = remote_bin();
    let mut s = format!("{bin} attach {}", shell_quote(target));
    if observe {
        s.push_str(" --observe");
    }
    if !argv.is_empty() {
        s.push_str(" --");
        for a in argv {
            s.push(' ');
            s.push_str(&shell_quote(a));
        }
    }
    s
}

fn open(
    host: &str,
    cwd: Option<&str>,
    agent: &str,
    name: Option<&str>,
    no_deploy: bool,
) -> Result<()> {
    let bin = remote_bin();
    if !no_deploy {
        // Deploy if the binary is missing (cheap idempotent check).
        let present = ssh_capture(host, &format!("test -x {bin} && echo yes || echo no"))?;
        if present.trim() != "yes" {
            eprintln!("termiod not found on {host}; deploying…");
            deploy(host, None, None)?;
        }
    }

    let argv: Vec<String> = match agent {
        "shell" | "" => Vec::new(),
        other => vec![other.to_string()],
    };
    let session_name = name.unwrap_or(if argv.is_empty() { "shell" } else { agent });

    // Create the durable session on the remote host.
    let mut create = format!("{bin} create --name {}", shell_quote(session_name));
    if let Some(dir) = cwd {
        create.push_str(&format!(" --cwd {}", shell_quote(dir)));
    }
    if !argv.is_empty() {
        create.push_str(" --");
        for a in &argv {
            create.push(' ');
            create.push_str(&shell_quote(a));
        }
    }
    let id = ssh_capture(host, &create)?.trim().to_string();
    if id.is_empty() {
        bail!("remote create returned no session id");
    }
    eprintln!("[remote {host}] created session {id} ({session_name}); attaching…");

    let remote = format!("{bin} attach {}", shell_quote(&id));
    let status = ssh_interactive(host, true, &remote)?;
    std::process::exit(status);
}

/// Cross-compile (or take a prebuilt binary) and install it on the remote.
fn deploy(host: &str, prebuilt: Option<&str>, target_override: Option<&str>) -> Result<()> {
    let bin_path = match prebuilt {
        Some(p) => p.to_string(),
        None => {
            let target = match target_override {
                Some(t) => t.to_string(),
                None => detect_target(host)?,
            };
            cross_compile(&target)?
        }
    };

    eprintln!("[deploy] installing {bin_path} → {host}:~/.local/bin/termiod");
    run_cmd(Command::new("ssh").args([host, "mkdir -p ~/.local/bin"]))?;
    // scp expands ~ on the remote for OpenSSH.
    run_cmd(Command::new("scp").args([&bin_path, &format!("{host}:.local/bin/termiod")]))?;
    run_cmd(Command::new("ssh").args([host, "chmod +x ~/.local/bin/termiod"]))?;

    let bin = remote_bin();
    let version = ssh_capture(host, &format!("{bin} --version"))?;
    eprintln!("[deploy] installed: {}", version.trim());
    eprintln!("[deploy] daemon auto-starts on first attach/list (no service needed).");
    Ok(())
}

/// Ask the remote `uname` and map to a musl Rust target.
fn detect_target(host: &str) -> Result<String> {
    let uname = ssh_capture(host, "uname -sm")?;
    let uname = uname.trim();
    if !uname.starts_with("Linux") {
        bail!("remote host is not Linux (uname: '{uname}'); pass --target explicitly");
    }
    let target = if uname.contains("x86_64") || uname.contains("amd64") {
        "x86_64-unknown-linux-musl"
    } else if uname.contains("aarch64") || uname.contains("arm64") {
        "aarch64-unknown-linux-musl"
    } else {
        bail!("unrecognized remote arch (uname: '{uname}'); pass --target explicitly");
    };
    Ok(target.to_string())
}

/// `cargo build --release --target <triple>` for this crate; returns the
/// binary path. Falls back to a clear message if the cross-linker is missing.
fn cross_compile(target: &str) -> Result<String> {
    let manifest = format!("{}/Cargo.toml", env!("CARGO_MANIFEST_DIR"));
    eprintln!("[deploy] cross-compiling for {target}…");
    let status = Command::new("cargo")
        .args([
            "build",
            "--release",
            "--target",
            target,
            "--manifest-path",
            &manifest,
        ])
        .status()
        .context("running cargo build (is cargo on PATH?)")?;
    if !status.success() {
        bail!(
            "cross-compile for {target} failed.\n\
             A musl cross-linker is usually the missing piece. Options:\n  \
             • rustup target add {target}\n  \
             • brew install FiloSottile/musl-cross/musl-cross  (or messense/macos-cross-toolchains)\n  \
             • or build on the host and deploy with: termiod remote deploy <host> --bin <path>"
        );
    }
    let dir = env!("CARGO_MANIFEST_DIR");
    // With a workspace-less crate, target/ sits next to Cargo.toml.
    let bin = format!("{dir}/target/{target}/release/termiod");
    if !std::path::Path::new(&bin).exists() {
        bail!("expected built binary at {bin} but it is missing");
    }
    Ok(bin)
}

/// Run an interactive/remote command over SSH. `tty` requests a PTY (`-t`),
/// needed for `attach`; list uses no tty. Returns the child's exit code.
fn ssh_interactive(host: &str, tty: bool, remote_cmd: &str) -> Result<i32> {
    let mut cmd = Command::new("ssh");
    if tty {
        cmd.arg("-t");
    }
    // ServerAliveInterval keeps the control channel honest; on disconnect the
    // remote client dies and the session detaches.
    cmd.args(["-o", "ServerAliveInterval=15"]);
    cmd.arg(host);
    cmd.arg(remote_cmd);
    let status = cmd.status().context("spawning ssh")?;
    Ok(status.code().unwrap_or(1))
}

/// Run an SSH command and capture stdout (for create/list/version probes).
/// One host's session table, for the cross-host view. Failure is returned per
/// host rather than aborting the sweep — a cloud fleet always has one box
/// that is rebooting, and that must not blank the other rows.
pub async fn list_json(host: &str) -> (String, Result<Vec<crate::protocol::SessionInfo>>) {
    let owned = host.to_string();
    let probe = owned.clone();
    let result = tokio::task::spawn_blocking(move || {
        let out = ssh_capture(&probe, &format!("{} list --json", remote_bin()))?;
        serde_json::from_str::<Vec<crate::protocol::SessionInfo>>(&out)
            .context("parsing remote session list")
    })
    .await;
    match result {
        Ok(inner) => (owned, inner),
        Err(e) => (owned, Err(anyhow::anyhow!("{e}"))),
    }
}

fn ssh_capture(host: &str, remote_cmd: &str) -> Result<String> {
    let mut cmd = Command::new("ssh");
    cmd.arg("-o").arg("BatchMode=yes");
    for arg in ssh_multiplex_args() {
        cmd.arg(arg);
    }
    let out = cmd
        .args([host, remote_cmd])
        .output()
        .context("spawning ssh")?;
    if !out.status.success() {
        bail!(
            "ssh {host} '{remote_cmd}' failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

fn run_cmd(cmd: &mut Command) -> Result<()> {
    let status = cmd.status().context("spawning subprocess")?;
    if !status.success() {
        bail!("command failed: {:?}", cmd);
    }
    Ok(())
}

/// Minimal single-quote shell escaping for remote command args.
fn shell_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".to_string();
    }
    if s
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b'/' | b'=' | b'@' | b':'))
    {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}
