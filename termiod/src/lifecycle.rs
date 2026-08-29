//! The daemon's lifecycle — install, update, repair — as one reconcile loop
//! (`docs/design/20260827-termiod-lifecycle-reconcile.md`).
//!
//! Two halves. The **node** half runs on the box, by whatever binary is on
//! disk: `status` reports what is there and `stop` asks the daemon to leave.
//! The **control-plane** half, `reconcile`, runs wherever the desired build
//! lives — the Mac, usually — against a [`Node`], and is the same function for
//! this machine and for a box over ssh; only the transport behind the trait
//! differs. Install is the loop from an empty box, update is the loop from a
//! stale one, and recovery from any failure is running it again.
//!
//! Nothing here needs a daemon that already knows about this module. The
//! daemon is found by the credential the kernel attaches to its socket, asked
//! what it holds with `list` (protocol v1), and stopped with `SIGTERM`, which
//! its drain path has always handled — so the first upgrade works the same as
//! every later one.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::UnixStream;

use crate::paths;
use crate::protocol::{
    read_frame, write_control, ChannelRole, Control, Frame, SessionInfo, PROTOCOL_VERSION,
};

/// The build this binary is: `<app version>+<build number>`, stamped by
/// `build.rs` from the same two values the app bundle carries.
pub const BUILD_VERSION: &str = env!("TERMIOD_VERSION");

/// How long the loop waits for a daemon to answer after it has been asked to
/// start or stop. Autostart binds within a second on a loaded box; the drain
/// after `SIGTERM` has to bury every session first.
const SETTLE: Duration = Duration::from_secs(15);

/// Exit code for a stop the daemon declined because it holds work someone is
/// using. Distinct from failure: the state is named, and running again after
/// the sessions close is the whole recovery.
pub const EXIT_BUSY: i32 = 3;

// MARK: Versions

/// `major.minor.patch+build`, ordered as written. `build` breaks ties between
/// two builds of one version, which is every dev build.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    major: u64,
    minor: u64,
    patch: u64,
    build: u64,
}

impl Version {
    pub fn parse(text: &str) -> Option<Version> {
        let (semver, build) = match text.trim().split_once('+') {
            Some((semver, build)) => (semver, build.parse().ok()?),
            None => (text.trim(), 0),
        };
        let mut parts = semver.split('.').map(|part| part.parse::<u64>().ok());
        let major = parts.next()??;
        let minor = parts.next()??;
        let patch = parts.next()??;
        if parts.next().is_some() {
            return None;
        }
        Some(Version {
            major,
            minor,
            patch,
            build,
        })
    }
}

// MARK: The handshake, without a client

/// What a daemon says about itself at `hello`.
pub struct DaemonHello {
    /// Absent on a daemon that predates the field — older than anything that
    /// reports one, which is how the loop reads it.
    pub version: Option<String>,
    pub host_id: String,
}

/// `hello` as a control channel with no capabilities, returning the daemon's
/// self-description. Works against every daemon that speaks protocol v1.
pub async fn handshake<R, W>(reader: &mut R, writer: &mut W) -> Result<DaemonHello>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    write_control(
        writer,
        &Control::Hello {
            proto: PROTOCOL_VERSION,
            min_proto: PROTOCOL_VERSION,
            role: ChannelRole::Control,
            caps: Vec::new(),
            client: format!("termiod-cli/{BUILD_VERSION}"),
        },
    )
    .await?;
    match read_frame(reader).await? {
        Some(Frame::Control(Control::HelloOk {
            version, host_id, ..
        })) => Ok(DaemonHello {
            version: version.filter(|value| !value.is_empty()),
            host_id,
        }),
        Some(Frame::Control(Control::HelloErr { supported, .. })) => bail!(
            "the daemon speaks protocol {supported:?}; this binary speaks {PROTOCOL_VERSION}"
        ),
        Some(_) => bail!("the daemon answered hello with something other than hello_ok"),
        None => bail!("the daemon closed the connection during hello"),
    }
}

async fn list_sessions<R, W>(reader: &mut R, writer: &mut W) -> Result<Vec<SessionInfo>>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    write_control(writer, &Control::List { seq: Some(1) }).await?;
    loop {
        match read_frame(reader).await? {
            Some(Frame::Control(Control::Sessions { sessions, .. })) => return Ok(sessions),
            Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
            Some(_) => continue,
            None => bail!("the daemon closed the connection before answering list"),
        }
    }
}

/// A connection to the daemon on `socket`, or `None` when nothing answers.
/// Never autostarts: the question here is what *is* running.
async fn connect_existing(socket: &Path) -> Option<UnixStream> {
    tokio::time::timeout(Duration::from_secs(5), UnixStream::connect(socket))
        .await
        .ok()?
        .ok()
}

/// The pid of the process on the far end of `stream`, from the kernel. This is
/// the process that *owns the socket* — the only one the loop may ever stop —
/// and it needs no protocol, so it identifies a daemon of any age. Never argv:
/// a box running a second daemon by hand on another socket has the same
/// command line, and matching it is how an upgrade kills the wrong process.
fn peer_pid(stream: &UnixStream) -> Option<i32> {
    use std::os::fd::AsRawFd;
    let descriptor = stream.as_raw_fd();
    #[cfg(target_os = "linux")]
    {
        let mut credential = libc::ucred {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        let result = unsafe {
            libc::getsockopt(
                descriptor,
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                &mut credential as *mut libc::ucred as *mut libc::c_void,
                &mut length,
            )
        };
        (result == 0 && credential.pid > 0).then_some(credential.pid)
    }
    #[cfg(target_os = "macos")]
    {
        const SOL_LOCAL: libc::c_int = 0;
        const LOCAL_PEERPID: libc::c_int = 0x002;
        let mut pid: libc::pid_t = 0;
        let mut length = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
        let result = unsafe {
            libc::getsockopt(
                descriptor,
                SOL_LOCAL,
                LOCAL_PEERPID,
                &mut pid as *mut libc::pid_t as *mut libc::c_void,
                &mut length,
            )
        };
        (result == 0 && pid > 0).then_some(pid)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = descriptor;
        None
    }
}

// MARK: Node side — `termiod status`

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeStatus {
    pub binary: BinaryStatus,
    pub daemon: DaemonStatus,
    pub sessions: Vec<SessionSummary>,
    /// The identity written on the daemon's first start. Present without a
    /// running daemon: it is a file beside the socket.
    pub host_id: Option<String>,
    pub supervisor: Supervisor,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BinaryStatus {
    /// The build of the binary answering — the one on disk.
    pub version: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonStatus {
    pub running: bool,
    /// The *running* daemon's build, from its own `hello`. Differs from the
    /// binary's exactly when an update is staged and not yet activated, which
    /// is the state the loop most needs to see. `None` on a daemon too old to
    /// say, or none running.
    pub version: Option<String>,
    pub pid: Option<i32>,
    pub socket: String,
}

/// One session, reduced to what a stop decision needs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    pub id: String,
    pub name: String,
    pub command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub status: String,
    pub attached: usize,
    /// A command is running in the foreground — the shell is not at its
    /// prompt. The daemon's own "closing this loses work" signal.
    #[serde(default)]
    pub running: bool,
    pub alive: bool,
}

impl From<SessionInfo> for SessionSummary {
    fn from(info: SessionInfo) -> SessionSummary {
        SessionSummary {
            id: info.id,
            name: info.name,
            command: info.command,
            title: info.title,
            status: info.status,
            attached: info.attached_clients,
            running: info.foreground_job,
            alive: info.alive,
        }
    }
}

impl SessionSummary {
    /// Whether stopping the daemon would take *work* from someone: a command
    /// running in the foreground, or an agent still working or waiting on its
    /// user. The workstream status is in the protocol so a daemon does not
    /// have to guess from a screen, and an agent nobody is watching is exactly
    /// the session "lives on the box" promises to keep.
    ///
    /// Being attached is deliberately not the test. A client on a shell at its
    /// prompt loses nothing but the prompt, and that client is usually the
    /// app whose user just asked for the update — an update the user's own
    /// idle tabs could veto would have them closing tabs to get it.
    pub fn busy(&self) -> bool {
        self.alive && (self.running || matches!(self.status.as_str(), "working" | "needs_you"))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Supervisor {
    None,
    Launchd,
    SystemdUser,
}

/// What this machine has, from the binary that answers: its own build, the
/// daemon on the canonical socket, and that daemon's sessions. One process,
/// one connection — this replaces `test -x`, two handshakes and a roster read
/// as separate round trips over ssh.
pub async fn status() -> Result<NodeStatus> {
    let socket = paths::socket_path()?;
    let binary = BinaryStatus {
        version: BUILD_VERSION.to_string(),
        path: std::env::current_exe()
            .map(|path| path.display().to_string())
            .unwrap_or_default(),
    };
    let host_id = paths::host_id_path()
        .ok()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty());
    let mut daemon = DaemonStatus {
        running: false,
        version: None,
        pid: None,
        socket: socket.display().to_string(),
    };
    let mut sessions = Vec::new();
    if let Some(mut stream) = connect_existing(&socket).await {
        daemon.running = true;
        daemon.pid = peer_pid(&stream);
        let (mut reader, mut writer) = stream.split();
        let asked = tokio::time::timeout(Duration::from_secs(5), async {
            let hello = handshake(&mut reader, &mut writer).await;
            let list = list_sessions(&mut reader, &mut writer).await;
            (hello, list)
        })
        .await;
        if let Ok((hello, list)) = asked {
            daemon.version = hello.ok().and_then(|hello| hello.version);
            sessions = list
                .unwrap_or_default()
                .into_iter()
                .map(SessionSummary::from)
                .collect();
        }
    }
    Ok(NodeStatus {
        binary,
        daemon,
        sessions,
        host_id,
        supervisor: detect_supervisor().await,
    })
}

/// Which init owns the daemon, if any. This is what decides what "restart"
/// means for a node: a supervised daemon is bounced by its supervisor, an
/// unsupervised one is stopped and autostarted by the next client.
async fn detect_supervisor() -> Supervisor {
    if cfg!(target_os = "macos") {
        let target = format!("gui/{}/{}", unsafe { libc::getuid() }, crate::service::label());
        let loaded = tokio::process::Command::new("launchctl")
            .args(["print", &target])
            .output()
            .await
            .map(|output| output.status.success())
            .unwrap_or(false);
        return if loaded {
            Supervisor::Launchd
        } else {
            Supervisor::None
        };
    }
    // Enabled counts as well as active: after a clean `stop` the unit is
    // inactive (`Restart=on-failure` does not restart a clean exit), but the
    // next client contact starts it again through systemd, so systemd still
    // owns whatever runs next. Mirrors "loaded" on launchd, which likewise
    // says nothing about a pid.
    let owned = tokio::task::spawn_blocking(crate::service::systemd_unit_owns_daemon)
        .await
        .unwrap_or(false);
    if owned {
        Supervisor::SystemdUser
    } else {
        Supervisor::None
    }
}

pub fn print_status(status: &NodeStatus) {
    println!("binary:  {} ({})", status.binary.version, status.binary.path);
    match (&status.daemon.running, &status.daemon.version, status.daemon.pid) {
        (false, _, _) => println!("daemon:  not running ({})", status.daemon.socket),
        (true, version, pid) => println!(
            "daemon:  {} pid {} ({})",
            version.as_deref().unwrap_or("older than this binary, no version"),
            pid.map(|pid| pid.to_string()).unwrap_or_else(|| "?".to_string()),
            status.daemon.socket
        ),
    }
    if let Some(host_id) = &status.host_id {
        println!("host:    {host_id}");
    }
    println!(
        "service: {}",
        match status.supervisor {
            Supervisor::None => "none (autostarts on first contact)",
            Supervisor::Launchd => "launchd",
            Supervisor::SystemdUser => "systemd --user",
        }
    );
    for session in &status.sessions {
        println!(
            "  {:<10} {:<14} {:<9} {} — {}",
            session.id,
            session.name,
            session.status,
            if session.attached > 0 {
                "attached"
            } else {
                "nobody attached"
            },
            session.command
        );
    }
}

// MARK: Node side — `termiod stop`

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StopOutcome {
    pub stopped: bool,
    /// The sessions that kept the daemon up, by name — the user decides
    /// whether to close an agent mid-task, and a count cannot inform that.
    pub busy: Vec<SessionSummary>,
    pub message: String,
}

/// Ask the daemon on the canonical socket to leave. Declines while any session
/// is in use unless `force`; nothing running is already the state wanted, so
/// it is success rather than an error.
pub async fn stop(force: bool) -> Result<StopOutcome> {
    let socket = paths::socket_path()?;
    let Some(mut stream) = connect_existing(&socket).await else {
        return Ok(StopOutcome {
            stopped: true,
            busy: Vec::new(),
            message: "no daemon is running".to_string(),
        });
    };
    let Some(pid) = peer_pid(&stream) else {
        bail!(
            "could not identify the process behind {}; not stopping one by guess",
            socket.display()
        );
    };
    if !force {
        let (mut reader, mut writer) = stream.split();
        let sessions = tokio::time::timeout(Duration::from_secs(5), async {
            // The version is not the question here; the handshake is what
            // makes `list` answerable on a negotiated channel.
            let _ = handshake(&mut reader, &mut writer).await;
            list_sessions(&mut reader, &mut writer).await
        })
        .await
        .context("the daemon did not answer in time")?
        .context("asking the daemon what it holds — not stopping it blind")?;
        let busy: Vec<SessionSummary> = sessions
            .into_iter()
            .map(SessionSummary::from)
            .filter(SessionSummary::busy)
            .collect();
        if !busy.is_empty() {
            let message = format!(
                "{} still working on this machine; wait, or pass --force",
                if busy.len() == 1 {
                    "1 session is".to_string()
                } else {
                    format!("{} sessions are", busy.len())
                }
            );
            return Ok(StopOutcome {
                stopped: false,
                busy,
                message,
            });
        }
    }
    drop(stream);

    if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        bail!(
            "sending SIGTERM to pid {pid}: {}",
            std::io::Error::last_os_error()
        );
    }
    // The daemon removes its socket last, after burying every session, so the
    // socket going away is the drain having finished — not merely begun.
    let deadline = Instant::now() + SETTLE;
    loop {
        let process_gone = unsafe { libc::kill(pid, 0) } != 0;
        if process_gone || !socket.exists() {
            return Ok(StopOutcome {
                stopped: true,
                busy: Vec::new(),
                message: format!("stopped pid {pid}"),
            });
        }
        if Instant::now() >= deadline {
            bail!("pid {pid} was asked to stop and is still holding {} after {}s", socket.display(), SETTLE.as_secs());
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

// MARK: Control-plane side — the loop

/// What one command on a node produced. `Err` from [`Node::run`] is reserved
/// for the transport failing; a command that ran and failed is an `Ok(Run)`
/// with a non-zero code, because the two mean different things to the loop.
#[derive(Debug, Clone, Default)]
pub struct Run {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// The transport to a node failed — ssh could not connect, or authenticate.
/// Its own error type so the loop can name the state (`unreachable`) rather
/// than fold it into "something failed".
#[derive(Debug)]
pub struct Unreachable(pub String);

impl std::fmt::Display for Unreachable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Unreachable {}

/// A machine the loop can act on. Everything the loop needs from a node is
/// these five operations; the arms — this machine, a Linux box over ssh, a
/// Mac over ssh — differ only in how they carry them out.
pub trait Node {
    /// How the node is named in messages: the ssh alias, or "this Mac".
    fn label(&self) -> String;
    /// The daemon binary's path, as the node's own shell should see it.
    fn binary(&self) -> String;
    /// Run a shell command on the node.
    fn run(&self, command: &str) -> impl std::future::Future<Output = Result<Run>> + Send;
    /// Copy `local` to `<name>` beside the daemon binary on the node.
    fn put(&self, local: &Path, name: &str) -> impl std::future::Future<Output = Result<()>> + Send;
    /// The daemon this control plane would install on the node.
    fn artifact(&self) -> impl std::future::Future<Output = Result<PathBuf>> + Send;
    /// Handshake with the node's daemon, starting it if nothing answers —
    /// which is the contact that brings a freshly staged binary up.
    fn hello(&self) -> impl std::future::Future<Output = Result<DaemonHello>> + Send;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Options {
    /// Stop the daemon even while sessions are in use.
    pub force: bool,
    /// Put the binary in place and stop there; the daemon is not touched.
    pub stage_only: bool,
}

/// The state a node was left in. Every variant is a place the loop can resume
/// from by being run again; none is an instruction to the user beyond what the
/// variant carries.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Outcome {
    /// The daemon running is the desired build, or a newer one.
    Current {
        version: String,
        host_id: String,
        /// Another control plane put a newer build here. Left alone.
        newer: bool,
    },
    /// The binary is in place and the daemon still running is the old one.
    /// `busy` is why it was not stopped — empty when stopping was not asked for.
    Staged {
        version: String,
        daemon: Option<String>,
        busy: Vec<SessionSummary>,
    },
    /// The new daemon did not verify. `rolled_back` means the previous binary is
    /// back in place and whatever it autostarts next is the build that worked.
    Unhealthy { message: String, rolled_back: bool },
    /// The transport failed; nothing on the node was touched.
    Unreachable { message: String },
    /// A step failed in a way the loop could not classify.
    Failed { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Report {
    pub node: String,
    pub desired: String,
    #[serde(flatten)]
    pub outcome: Outcome,
}

impl Report {
    pub fn exit_code(&self) -> i32 {
        match self.outcome {
            Outcome::Current { .. } => 0,
            Outcome::Staged { .. } => EXIT_BUSY,
            _ => 1,
        }
    }

    /// One line per state, for a terminal.
    pub fn describe(&self) -> String {
        let node = &self.node;
        match &self.outcome {
            Outcome::Current {
                version,
                host_id,
                newer,
            } => format!(
                "{node}: termiod {version} is running (host {host_id}){}",
                if *newer {
                    " — newer than this build, left alone"
                } else {
                    ""
                }
            ),
            Outcome::Staged {
                version,
                daemon,
                busy,
            } if busy.is_empty() => format!(
                "{node}: termiod {version} is staged; the running daemon ({}) takes over once it is stopped",
                daemon.as_deref().unwrap_or("no version")
            ),
            Outcome::Staged { version, busy, .. } => {
                let mut text = format!(
                    "{node}: termiod {version} is staged, but the daemon still running there has work in progress:"
                );
                for session in busy {
                    text.push_str(&format!(
                        "\n  • {} — {} ({})",
                        session.title.as_deref().unwrap_or(&session.name),
                        session.command,
                        session.status
                    ));
                }
                text.push_str("\nRun this again once it finishes, or pass --force to stop it now.");
                text
            }
            Outcome::Unhealthy {
                message,
                rolled_back,
            } => format!(
                "{node}: the new termiod did not come up — {message}{}",
                if *rolled_back {
                    "\nThe previous binary is back in place."
                } else {
                    ""
                }
            ),
            Outcome::Unreachable { message } => format!("{node}: unreachable — {message}"),
            Outcome::Failed { message } => format!("{node}: {message}"),
        }
    }
}

enum Observed {
    /// No binary at the path.
    Absent,
    /// A binary that predates `status` — it cannot say what it is, only that
    /// it is older than this build.
    OldBinary,
    Reported(NodeStatus),
}

/// Observe → stage → activate → verify → roll back, and a report of where
/// that left the node. Never returns an error: every failure is a state.
pub async fn reconcile<N: Node>(node: &N, desired: &str, options: Options) -> Report {
    let outcome = match run_loop(node, desired, options).await {
        Ok(outcome) => outcome,
        Err(error) => match error.downcast_ref::<Unreachable>() {
            Some(unreachable) => Outcome::Unreachable {
                message: unreachable.0.clone(),
            },
            None => Outcome::Failed {
                message: format!("{error:#}"),
            },
        },
    };
    Report {
        node: node.label(),
        desired: desired.to_string(),
        outcome,
    }
}

async fn run_loop<N: Node>(node: &N, desired: &str, options: Options) -> Result<Outcome> {
    let want = Version::parse(desired)
        .with_context(|| format!("desired version {desired:?} is not a build stamp"))?;
    let label = node.label();

    let mut observed = observe(node).await?;
    let needs_stage = match &observed {
        Observed::Absent | Observed::OldBinary => true,
        Observed::Reported(status) => {
            Version::parse(&status.binary.version).map_or(true, |have| have < want)
        }
    };
    let mut staged = false;
    if needs_stage {
        eprintln!("[deploy] installing termiod {desired} on {label}…");
        stage(node).await?;
        staged = true;
        observed = observe(node).await?;
    }
    let Observed::Reported(status) = observed else {
        bail!("termiod was installed on {label} but does not answer `status` there");
    };

    if options.stage_only {
        return Ok(Outcome::Staged {
            version: status.binary.version,
            daemon: status.daemon.version,
            busy: Vec::new(),
        });
    }

    let daemon_is_stale = status.daemon.running
        && status
            .daemon
            .version
            .as_deref()
            .and_then(Version::parse)
            .map_or(true, |have| have < want);
    if daemon_is_stale {
        // The bounce is the same under every supervisor: `stop` SIGTERMs the
        // daemon and waits for the socket to go, and `verify` reconnects, which
        // autostarts the staged binary. Under launchd `KeepAlive` respawns it;
        // under systemd a clean exit leaves the unit inactive
        // (`Restart=on-failure`) and the reconnect's `spawn_daemon` starts the
        // unit again, so the new daemon comes up supervised rather than as a
        // `setsid` orphan.
        eprintln!("[deploy] asking the daemon on {label} to stop…");
        let command = format!(
            "{} stop --json{}",
            node.binary(),
            if options.force { " --force" } else { "" }
        );
        let run = node.run(&command).await?;
        match run.code {
            0 => {}
            EXIT_BUSY => {
                let outcome: StopOutcome = serde_json::from_str(run.stdout.trim())
                    .context("reading the daemon's answer to stop")?;
                return Ok(Outcome::Staged {
                    version: status.binary.version,
                    daemon: status.daemon.version,
                    busy: outcome.busy,
                });
            }
            _ => bail!("stopping termiod on {label}: {}", last_line(&run.stderr)),
        }
    }

    match verify(node, want).await {
        Ok((hello, version)) => Ok(Outcome::Current {
            version: hello.version.unwrap_or_default(),
            host_id: hello.host_id,
            newer: version > want,
        }),
        Err(error) => {
            let message = format!("{error:#}");
            let rolled_back = staged && roll_back(node).await.is_ok();
            Ok(Outcome::Unhealthy {
                message,
                rolled_back,
            })
        }
    }
}

async fn observe<N: Node>(node: &N) -> Result<Observed> {
    let run = node
        .run(&format!("{} status --json", node.binary()))
        .await?;
    if run.code == 0 {
        let status: NodeStatus = serde_json::from_str(run.stdout.trim())
            .context("reading the node's status report")?;
        return Ok(Observed::Reported(status));
    }
    let stderr = run.stderr.to_ascii_lowercase();
    // The shell's own verdicts. 127 is "command not found"; clap exits 2 for a
    // subcommand this binary does not have, which only an older build lacks.
    if run.code == 127 || stderr.contains("no such file") || stderr.contains("not found") {
        return Ok(Observed::Absent);
    }
    if run.code == 2 && (stderr.contains("unrecognized subcommand") || stderr.contains("unexpected argument")) {
        return Ok(Observed::OldBinary);
    }
    bail!(
        "termiod on {} could not report its status: {}",
        node.label(),
        last_line(&run.stderr)
    )
}

/// Upload beside the target and rename over it, keeping the previous binary
/// as `.prev`. Atomic on the filesystem, and safe against a running daemon —
/// it keeps the old inode until it exits, which is the handover wanted. Linux
/// refuses to open a running executable for writing (`ETXTBSY`), so writing
/// in place is the one shape that always fails when a box is in use.
async fn stage<N: Node>(node: &N) -> Result<()> {
    let artifact = node.artifact().await?;
    node.put(&artifact, "termiod.new").await?;
    let binary = node.binary();
    let command = format!(
        "chmod +x {binary}.new && {{ [ ! -e {binary} ] || mv -f {binary} {binary}.prev; }} && mv -f {binary}.new {binary}"
    );
    let run = node.run(&command).await?;
    if run.code != 0 {
        bail!(
            "installing the binary on {}: {}",
            node.label(),
            last_line(&run.stderr)
        );
    }
    Ok(())
}

/// Handshake with whatever answers now — which, after a stop, is the daemon
/// autostart brings up from the staged binary — and check it is the build
/// wanted, or a newer one.
async fn verify<N: Node>(node: &N, want: Version) -> Result<(DaemonHello, Version)> {
    let deadline = Instant::now() + SETTLE;
    let mut last_error = None;
    while Instant::now() < deadline {
        match node.hello().await {
            Ok(hello) => {
                let Some(version) = hello.version.as_deref().and_then(Version::parse) else {
                    // A daemon with no version is the old one, still up: the
                    // socket it is draining has not gone yet. Ask again.
                    last_error = Some(anyhow::anyhow!(
                        "the daemon that answered is an older build with no version"
                    ));
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    continue;
                };
                if version < want {
                    last_error = Some(anyhow::anyhow!(
                        "the daemon that answered is {}, older than {}",
                        hello.version.as_deref().unwrap_or_default(),
                        BUILD_VERSION
                    ));
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    continue;
                }
                return Ok((hello, version));
            }
            Err(error) => {
                last_error = Some(error);
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow::anyhow!("no daemon answered")))
}

/// Put the previous binary back and stop whatever the new one started, so the
/// next contact autostarts the build that worked.
async fn roll_back<N: Node>(node: &N) -> Result<()> {
    let binary = node.binary();
    eprintln!("[deploy] rolling {} back to the previous binary…", node.label());
    let _ = node.run(&format!("{binary} stop --force --json")).await;
    let run = node
        .run(&format!("[ -e {binary}.prev ] && mv -f {binary}.prev {binary}"))
        .await?;
    if run.code != 0 {
        bail!("no previous binary to roll back to on {}", node.label());
    }
    Ok(())
}

fn last_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .last()
        .unwrap_or("no output")
        .to_string()
}

// MARK: This machine

/// The node this process runs on. Its daemon is the binary running this code,
/// so there is nothing to stage: the loop here is observe → stop-if-idle →
/// verify, which is what picks a new build up after the app updated.
pub struct LocalNode;

impl Node for LocalNode {
    fn label(&self) -> String {
        "this machine".to_string()
    }

    fn binary(&self) -> String {
        std::env::current_exe()
            .map(|path| shell_quote(&path.display().to_string()))
            .unwrap_or_else(|_| "termiod".to_string())
    }

    async fn run(&self, command: &str) -> Result<Run> {
        let output = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(command)
            .output()
            .await
            .context("running sh")?;
        Ok(Run {
            code: output.status.code().unwrap_or(1),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }

    async fn put(&self, _local: &Path, _name: &str) -> Result<()> {
        bail!("this machine's termiod ships inside the app; update the app to update it")
    }

    async fn artifact(&self) -> Result<PathBuf> {
        bail!("this machine's termiod ships inside the app; update the app to update it")
    }

    async fn hello(&self) -> Result<DaemonHello> {
        let mut stream = crate::client::connect().await?;
        let (mut reader, mut writer) = stream.split();
        tokio::time::timeout(Duration::from_secs(5), handshake(&mut reader, &mut writer))
            .await
            .context("the daemon did not answer hello in time")?
    }
}

/// Single-quote shell escaping for a path this loop hands to `sh -c`.
pub fn shell_quote(text: &str) -> String {
    if !text.is_empty()
        && text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b'/' | b'=' | b'@' | b':'))
    {
        return text.to_string();
    }
    format!("'{}'", text.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::VecDeque;

    #[test]
    fn versions_order_by_release_then_build() {
        let parse = |text| Version::parse(text).expect(text);
        assert!(parse("0.43.0+100") < parse("0.44.0+1"));
        assert!(parse("0.44.0+1") < parse("0.44.0+2"));
        assert!(parse("0.44.0") == parse("0.44.0+0"));
        assert!(parse("0.0.0+1533") < parse("0.1.0+0"));
        assert!(parse("1.0.0+5") > parse("0.99.99+999"));
    }

    #[test]
    fn a_crate_version_or_garbage_is_not_a_build_stamp() {
        assert!(Version::parse("").is_none());
        assert!(Version::parse("termiod/0.1.0 linux-aarch64").is_none());
        assert!(Version::parse("0.44").is_none());
        assert!(Version::parse("0.44.0.1").is_none());
        assert!(Version::parse("0.44.0+abc").is_none());
    }

    /// Busy is about work, not watchers: a command in the foreground or an
    /// agent mid-task holds the daemon up; a client attached to an idle prompt
    /// does not, because that client is usually the app asking for the update.
    #[test]
    fn a_session_is_busy_when_work_is_in_progress_not_when_someone_is_attached() {
        let session = |attached, running, status: &str, alive| SessionSummary {
            id: "1".into(),
            name: "s".into(),
            command: "bash".into(),
            title: None,
            status: status.into(),
            attached,
            running,
            alive,
        };
        assert!(!session(0, false, "unknown", true).busy());
        assert!(!session(1, false, "idle", true).busy());
        assert!(!session(3, false, "done", true).busy());
        assert!(session(0, true, "unknown", true).busy());
        assert!(session(0, false, "working", true).busy());
        assert!(session(0, false, "needs_you", true).busy());
        assert!(!session(1, true, "working", false).busy());
    }

    /// The build stamp `build.rs` produces always parses — the loop's desired
    /// version is never garbage.
    #[test]
    fn this_build_has_a_comparable_version() {
        assert!(Version::parse(BUILD_VERSION).is_some(), "{BUILD_VERSION}");
    }

    /// A node scripted as a sequence of answers, one per operation, so every
    /// state in the RFC's table can be walked without a machine.
    struct FakeNode {
        runs: RefCell<VecDeque<Run>>,
        hellos: RefCell<VecDeque<Result<DaemonHello>>>,
        commands: RefCell<Vec<String>>,
        puts: RefCell<Vec<String>>,
    }

    impl FakeNode {
        fn new(runs: Vec<Run>, hellos: Vec<Result<DaemonHello>>) -> FakeNode {
            FakeNode {
                runs: RefCell::new(runs.into()),
                hellos: RefCell::new(hellos.into()),
                commands: RefCell::new(Vec::new()),
                puts: RefCell::new(Vec::new()),
            }
        }
    }

    // The fake is single-threaded by construction; the trait's `Send` bound
    // is for the ssh arm's sake.
    unsafe impl Sync for FakeNode {}

    impl Node for FakeNode {
        fn label(&self) -> String {
            "box".to_string()
        }
        fn binary(&self) -> String {
            "$HOME/.local/bin/termiod".to_string()
        }
        async fn run(&self, command: &str) -> Result<Run> {
            self.commands.borrow_mut().push(command.to_string());
            self.runs
                .borrow_mut()
                .pop_front()
                .ok_or_else(|| anyhow::anyhow!("unscripted command: {command}"))
        }
        async fn put(&self, local: &Path, name: &str) -> Result<()> {
            self.puts.borrow_mut().push(format!("{} → {name}", local.display()));
            Ok(())
        }
        async fn artifact(&self) -> Result<PathBuf> {
            Ok(PathBuf::from("/bundle/termiod-aarch64-unknown-linux-musl"))
        }
        async fn hello(&self) -> Result<DaemonHello> {
            self.hellos
                .borrow_mut()
                .pop_front()
                .unwrap_or_else(|| Err(anyhow::anyhow!("unscripted hello")))
        }
    }

    fn ok(stdout: &str) -> Run {
        Run {
            code: 0,
            stdout: stdout.to_string(),
            stderr: String::new(),
        }
    }

    fn failed(code: i32, stderr: &str) -> Run {
        Run {
            code,
            stdout: String::new(),
            stderr: stderr.to_string(),
        }
    }

    fn status_json(binary: &str, daemon: Option<&str>, running: bool) -> String {
        serde_json::to_string(&NodeStatus {
            binary: BinaryStatus {
                version: binary.to_string(),
                path: "/home/u/.local/bin/termiod".to_string(),
            },
            daemon: DaemonStatus {
                running,
                version: daemon.map(str::to_string),
                pid: running.then_some(4242),
                socket: "/run/user/1001/termiod/termiod.sock".to_string(),
            },
            sessions: Vec::new(),
            host_id: Some("h_1".to_string()),
            supervisor: Supervisor::None,
        })
        .expect("status serializes")
    }

    fn hello(version: Option<&str>) -> Result<DaemonHello> {
        Ok(DaemonHello {
            version: version.map(str::to_string),
            host_id: "h_1".to_string(),
        })
    }

    const WANT: &str = "0.44.0+1600";

    /// Install from an empty box: the binary is staged, nothing is stopped, and
    /// the verify handshake is what starts the daemon.
    #[tokio::test]
    async fn an_empty_box_is_installed_and_verified() {
        let node = FakeNode::new(
            vec![
                failed(127, "bash: /home/u/.local/bin/termiod: No such file or directory"),
                ok(""), // chmod + mv
                ok(&status_json(WANT, None, false)),
            ],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { ref version, newer: false, .. } if version == WANT), "{report:?}");
        assert_eq!(node.puts.borrow().len(), 1);
        assert!(!node.commands.borrow().iter().any(|command| command.contains(" stop")));
    }

    /// A binary too old to answer `status` is staged first and asked again with
    /// the new one — the first-upgrade path, which needs nothing from the old
    /// build but a path.
    #[tokio::test]
    async fn an_old_binary_is_staged_before_it_is_asked_anything() {
        let node = FakeNode::new(
            vec![
                failed(2, "error: unrecognized subcommand 'status'"),
                ok(""),
                ok(&status_json(WANT, None, true)), // old daemon: running, no version
                ok(""),                            // stop
            ],
            vec![hello(Some(WANT))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(commands[1].contains("termiod.prev"), "{}", commands[1]);
        assert!(commands[3].ends_with("stop --json"), "{}", commands[3]);
    }

    /// The daemon declining to stop is a named state with the sessions in it,
    /// not a failure — the binary stays staged for the next run.
    #[tokio::test]
    async fn a_busy_daemon_leaves_the_update_staged() {
        let busy = StopOutcome {
            stopped: false,
            busy: vec![SessionSummary {
                id: "1".into(),
                name: "claude".into(),
                command: "claude".into(),
                title: None,
                status: "working".into(),
                attached: 0,
                running: true,
                alive: true,
            }],
            message: "1 session is in use".into(),
        };
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                Run {
                    code: EXIT_BUSY,
                    stdout: serde_json::to_string(&busy).unwrap(),
                    stderr: String::new(),
                },
            ],
            vec![],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        match &report.outcome {
            Outcome::Staged { busy, daemon, .. } => {
                assert_eq!(busy.len(), 1);
                assert_eq!(busy[0].name, "claude");
                assert_eq!(daemon.as_deref(), Some("0.43.0+1500"));
            }
            other => panic!("expected staged, got {other:?}"),
        }
        assert_eq!(report.exit_code(), EXIT_BUSY);
    }

    /// A new daemon that never verifies is rolled back, and the report says so.
    #[tokio::test]
    async fn a_daemon_that_does_not_come_up_is_rolled_back() {
        let node = FakeNode::new(
            vec![
                ok(&status_json("0.43.0+1500", Some("0.43.0+1500"), true)),
                ok(""),
                ok(&status_json(WANT, Some("0.43.0+1500"), true)),
                ok(""), // stop
                ok(""), // roll back: stop --force
                ok(""), // roll back: mv prev
            ],
            (0..40)
                .map(|_| Err(anyhow::anyhow!("no protocol reply")))
                .collect(),
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unhealthy { rolled_back: true, .. }), "{report:?}");
        let commands = node.commands.borrow();
        assert!(commands.last().unwrap().contains("termiod.prev"), "{commands:?}");
    }

    /// A box another, newer control plane set up is left alone and reported as
    /// such, rather than downgraded.
    #[tokio::test]
    async fn a_newer_box_is_left_alone() {
        let node = FakeNode::new(
            vec![ok(&status_json("0.45.0+1700", Some("0.45.0+1700"), true))],
            vec![hello(Some("0.45.0+1700"))],
        );
        let report = reconcile(&node, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Current { newer: true, .. }), "{report:?}");
        assert!(node.puts.borrow().is_empty());
    }

    /// ssh failing is `unreachable`, kept apart from a step that ran and failed.
    #[tokio::test]
    async fn a_transport_failure_is_unreachable() {
        struct Down;
        impl Node for Down {
            fn label(&self) -> String {
                "vps".into()
            }
            fn binary(&self) -> String {
                "termiod".into()
            }
            async fn run(&self, _: &str) -> Result<Run> {
                Err(Unreachable("ssh: connect to host vps port 22: Operation timed out".into()).into())
            }
            async fn put(&self, _: &Path, _: &str) -> Result<()> {
                unreachable!()
            }
            async fn artifact(&self) -> Result<PathBuf> {
                unreachable!()
            }
            async fn hello(&self) -> Result<DaemonHello> {
                unreachable!()
            }
        }
        let report = reconcile(&Down, WANT, Options::default()).await;
        assert!(matches!(report.outcome, Outcome::Unreachable { ref message } if message.contains("timed out")), "{report:?}");
    }
}
