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
            match shipped_binary(&target) {
                Some(path) => {
                    eprintln!("[deploy] using the bundled {target} binary");
                    path
                }
                None => cross_compile(&target)?,
            }
        }
    };

    eprintln!("[deploy] installing {bin_path} → {host}:~/.local/bin/termiod");
    run_cmd(Command::new("ssh").args([host, "mkdir -p ~/.local/bin"]))?;
    // Uploaded beside the target and renamed over it, never written in place: a
    // deployed daemon is usually *running*, and Linux refuses to open a running
    // executable for writing (ETXTBSY) — so writing directly is the one case
    // that always fails, upgrading a machine already in use. `mv` within a
    // directory is `rename(2)`: atomic, and it leaves the running daemon holding
    // the old inode until it exits, which is exactly the handover wanted.
    //
    // scp expands `~` on the remote for OpenSSH.
    run_cmd(Command::new("scp").args([&bin_path, &format!("{host}:.local/bin/termiod.new")]))?;
    run_cmd(Command::new("ssh").args([
        host,
        "chmod +x ~/.local/bin/termiod.new && mv ~/.local/bin/termiod.new ~/.local/bin/termiod",
    ]))?;

    let bin = remote_bin();
    let version = ssh_capture(host, &format!("{bin} --version"))?;
    eprintln!("[deploy] installed: {}", version.trim());
    eprintln!("[deploy] daemon auto-starts on first attach/list (no service needed).");
    Ok(())
}

/// A daemon for `target` shipped beside this executable.
///
/// This is what makes deploying possible for someone who installed Termio rather
/// than cloning it: `cross_compile` below needs cargo, the musl target, and this
/// crate's source tree at the path baked into it, none of which a `.app` from the
/// DMG has. `scripts/build-app.sh` puts both Linux binaries in `Contents/Resources`
/// next to the daemon that reads this, so the common case is a copy.
///
/// A Mac takes the daemon that is *already* there — the one running this code. It
/// is built universal for the same reason the app is, so one file serves both
/// architectures and there is nothing per-target to ship. Sent as a plain copy:
/// `scp` sets no quarantine attribute, so a Developer-ID-signed binary landing on
/// another Mac runs without a Gatekeeper prompt.
///
/// Found by the executable's own directory rather than by a bundle path or an
/// environment variable: the daemon is run by absolute path out of whatever
/// shipped it, and this keeps that the single source of truth. Building from the
/// repo puts no siblings there, so a contributor still gets `cross_compile` — the
/// path that proves the source tree actually cross-builds.
fn shipped_binary(target: &str) -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    if target.contains("apple-darwin") {
        return exe.to_str().map(str::to_owned);
    }
    let candidate = exe.parent()?.join(format!("termiod-{target}"));
    candidate
        .is_file()
        .then(|| candidate.to_string_lossy().into_owned())
}

/// Ask the remote `uname` and map it to a Rust target.
///
/// Macs are here because a device is a machine the user owns, and plenty of them
/// are a Mac mini or a Studio on the same desk — "remote" describes the road, not
/// the thing at the end of it. The daemon's own build already covers Darwin (it is
/// what runs local sessions), so supporting it costs a branch here rather than a
/// new artifact.
fn detect_target(host: &str) -> Result<String> {
    let uname = ssh_capture(host, "uname -sm")?;
    target_for_uname(uname.trim())
}

/// The `uname -sm` half of `detect_target`, split out so the mapping can be
/// checked without a machine to ask.
fn target_for_uname(uname: &str) -> Result<String> {
    let arm = uname.contains("aarch64") || uname.contains("arm64");
    let intel = uname.contains("x86_64") || uname.contains("amd64");
    let target = match (uname.split_whitespace().next(), arm, intel) {
        (Some("Linux"), true, _) => "aarch64-unknown-linux-musl",
        (Some("Linux"), _, true) => "x86_64-unknown-linux-musl",
        (Some("Darwin"), true, _) => "aarch64-apple-darwin",
        (Some("Darwin"), _, true) => "x86_64-apple-darwin",
        (Some("Linux" | "Darwin"), _, _) => {
            bail!("unrecognized remote arch (uname: '{uname}'); pass --target explicitly")
        }
        _ => bail!("remote host is neither Linux nor macOS (uname: '{uname}'); pass --target explicitly"),
    };
    Ok(target.to_string())
}

/// Where the cross-build's tools are, which this process's own `PATH` cannot be
/// trusted to say. A deploy is usually started by the app, and an app launched
/// from Finder inherits launchd's `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin`, which
/// holds neither cargo (`~/.cargo/bin`) nor anything from Homebrew. The login
/// shell knows both, so it answers instead.
///
/// Homebrew's `zig` prefix is added on top of that because `brew` leaves `zig`
/// off `PATH` entirely whenever a second `zig@N` formula holds the link — the
/// same case `scripts/build-app.sh` checks for before building the daemon.
fn toolchain_path() -> Vec<String> {
    let mut directories = crate::agent::machine::login_path();
    for prefix in ["/opt/homebrew/opt/zig/bin", "/usr/local/opt/zig/bin"] {
        if !directories.iter().any(|seen| seen == prefix) {
            directories.push(prefix.to_string());
        }
    }
    directories
}

/// `binary` as an absolute path, looked up across `directories`.
fn find_tool(directories: &[String], binary: &str) -> Option<String> {
    use std::os::unix::fs::PermissionsExt;
    directories.iter().find_map(|directory| {
        let candidate = std::path::Path::new(directory).join(binary);
        let usable = std::fs::metadata(&candidate)
            .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
        usable.then(|| candidate.to_string_lossy().into_owned())
    })
}

/// `cargo build --release --target <triple>` for this crate; returns the
/// binary path. Falls back to a clear message if the cross-linker is missing.
fn cross_compile(target: &str) -> Result<String> {
    let manifest = format!("{}/Cargo.toml", env!("CARGO_MANIFEST_DIR"));
    let path = toolchain_path();
    let Some(cargo) = find_tool(&path, "cargo") else {
        bail!(
            "cross-compiling for {target} needs cargo, and there is none on this machine.\n  \
             • install Rust: https://rustup.rs\n  \
             • or build on the host and deploy with: termiod remote deploy <host> --bin <path>"
        );
    };
    // Checked before cargo runs rather than left to the build script's panic:
    // the VT engine termiod embeds is built by Zig, and a missing `zig` fails
    // several minutes in, inside a wall of cargo output, blaming a build script
    // nobody here wrote.
    if find_tool(&path, "zig").is_none() {
        bail!(
            "cross-compiling for {target} needs zig — the terminal engine termiod embeds\n\
             is built by it.\n  \
             • brew install zig\n  \
             • or build on the host and deploy with: termiod remote deploy <host> --bin <path>"
        );
    }
    eprintln!("[deploy] cross-compiling for {target}…");
    let status = Command::new(cargo)
        .env("PATH", path.join(":"))
        // Run *inside* the crate, not merely at it. Cargo discovers
        // `.cargo/config.toml` by walking up from the working directory —
        // `--manifest-path` does not move that search. Started from anywhere else
        // (an app's working directory is `/`), the musl link falls back to Apple's
        // `cc`, which rejects lld's flags with "ld: unknown options: --as-needed"
        // and no mention of the config it never read. `termiod/.cargo/config.toml`
        // is what points the cross-link at the bundled rust-lld.
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .args([
            "build",
            "--release",
            "--target",
            target,
            "--manifest-path",
            &manifest,
        ])
        .status()
        .context("running cargo build")?;
    if !status.success() {
        bail!(
            "cross-compile for {target} failed.\n\
             The target's std is usually the missing piece — the link itself needs no\n\
             external toolchain (termiod/.cargo/config.toml uses the bundled rust-lld):\n  \
             • rustup target add {target}\n  \
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

#[cfg(test)]
mod tests {
    use super::*;

    /// What `uname -sm` actually prints on the machines Termio is pointed at.
    #[test]
    fn a_machine_is_recognized_from_its_own_uname() {
        assert_eq!(target_for_uname("Linux x86_64").unwrap(), "x86_64-unknown-linux-musl");
        assert_eq!(target_for_uname("Linux aarch64").unwrap(), "aarch64-unknown-linux-musl");
        assert_eq!(target_for_uname("Darwin arm64").unwrap(), "aarch64-apple-darwin");
        assert_eq!(target_for_uname("Darwin x86_64").unwrap(), "x86_64-apple-darwin");
    }

    /// A machine Termio has no daemon for says so, and says which of the two
    /// things it could not recognise — the system or the architecture.
    #[test]
    fn an_unsupported_machine_names_what_was_not_recognized() {
        let arch = target_for_uname("Linux riscv64").unwrap_err().to_string();
        assert!(arch.contains("unrecognized remote arch"), "{arch}");

        let system = target_for_uname("FreeBSD amd64").unwrap_err().to_string();
        assert!(system.contains("neither Linux nor macOS"), "{system}");
    }

    /// The Mac case takes the daemon that is already running this code rather
    /// than a per-target sibling, because it is built universal.
    #[test]
    fn a_mac_is_served_by_the_running_daemon_itself() {
        let running = std::env::current_exe().ok().and_then(|p| p.to_str().map(str::to_owned));
        assert_eq!(shipped_binary("aarch64-apple-darwin"), running);
        assert_eq!(shipped_binary("x86_64-apple-darwin"), running);
    }
}
