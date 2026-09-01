//! Reference client for Session Protocol v0.1. It negotiates `hello`, but
//! reconnects in legacy mode when talking to a v0 daemon.

use crate::paths;
use crate::protocol::{
    read_frame, write_control, write_data, write_viewport, AttachMode, ChannelRole, Control,
    CreateSpec, Event, Frame, GridDiff, SessionInfo, Snapshot, WireCell, PROTOCOL_VERSION,
};
use anyhow::{bail, Context, Result};
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;

/// Byte that detaches an interactive attach without killing the session.
/// Ctrl-\ (0x1c) — same idea as abduco's default; rarely typed by agents.
const DETACH_KEY: u8 = 0x1c;

/// Connect to the daemon, auto-starting it if the socket is dead/missing.
pub async fn connect() -> Result<UnixStream> {
    let sock = paths::socket_path()?;
    let error = match UnixStream::connect(&sock).await {
        Ok(s) => return Ok(s),
        Err(error) => error,
    };
    // Only a connect failure that proves nothing is serving may recover by
    // spawning. Anything else — EPERM from a sandbox above all — can be a
    // healthy daemon this process is not allowed to reach, and the daemon a
    // spawn starts here would unlink the live socket and displace it (#526,
    // #527).
    if !absent_daemon(error.raw_os_error()) {
        bail!(
            "connecting to termiod at {} failed: {error}{}",
            sock.display(),
            denial_hint(error.raw_os_error())
        );
    }
    // No live daemon — spawn one detached and wait for it to bind.
    spawn_daemon()?;
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(40)).await;
        if let Ok(s) = UnixStream::connect(&sock).await {
            return Ok(s);
        }
    }
    bail!("could not reach termiod at {}", sock.display());
}

/// Transparent stdio bridge: splice this process's stdin/stdout to the local
/// daemon socket, byte for byte, understanding no frames of its own. Run as
/// `ssh <host> termiod stdio`, it puts the *framed protocol itself* on the SSH
/// pipe — so a native client (Mac app, iOS) speaks the exact same messages to a
/// remote host that it speaks to a local Unix socket, and the §C.9 "recorded
/// transcript replays byte-identical over SSH" claim becomes real. This is what
/// today's `ssh -t host termiod attach` never did (that ran the client on the
/// far end; the frames stopped at the remote socket).
///
/// The daemon auto-starts if it is not already running, exactly like every
/// other client verb, so first contact over SSH brings the host up.
pub async fn stdio() -> Result<()> {
    let stream = connect().await?;
    let (mut socket_read, mut socket_write) = stream.into_split();
    let mut input = tokio::io::stdin();
    let mut output = tokio::io::stdout();

    // stdin closing (the SSH pipe dropped — client detached or died) half-closes
    // the socket so the daemon sees a clean detach and keeps the session alive.
    let upstream = async {
        let _ = tokio::io::copy(&mut input, &mut socket_write).await;
        let _ = socket_write.shutdown().await;
    };
    // The socket closing (the session exited or the daemon went away) ends the
    // bridge so the remote `ssh … termiod stdio` command returns.
    let downstream = async {
        let _ = tokio::io::copy(&mut socket_read, &mut output).await;
        let _ = output.flush().await;
    };

    tokio::select! {
        _ = upstream => {}
        _ = downstream => {}
    }
    Ok(())
}

/// Whether a connect failure proves nothing is serving the socket. `ENOENT`
/// (no file) and `ECONNREFUSED` (a file no listener backs) do; every other
/// errno describes this client's situation, not the daemon's.
/// Whether a failed connect licenses *acting on* the path: starting a daemon
/// that will bind it, or — in [`crate::daemon`] — unlinking it first.
///
/// Narrower than [`crate::lifecycle::nothing_is_serving`] by exactly one errno,
/// and the difference is the point. `ENOTSOCK` says a plain file holds the
/// path. That proves no daemon is serving, which is all a stop needs to
/// conclude; it is not permission to delete a file this daemon did not create,
/// nor to spawn one that would fail to bind over it. That state needs a human,
/// and the two questions are different enough that folding them would answer
/// one of them wrongly.
pub(crate) fn absent_daemon(errno: Option<i32>) -> bool {
    matches!(errno, Some(libc::ENOENT) | Some(libc::ECONNREFUSED))
}

fn denial_hint(errno: Option<i32>) -> &'static str {
    match errno {
        Some(libc::EPERM) | Some(libc::EACCES) => {
            " — the OS denied the connection, most likely a sandbox; \
             the daemon may be running fine, and restarting it will not help"
        }
        _ => "",
    }
}

fn spawn_daemon() -> Result<()> {
    // A box whose unit systemd owns gets its daemon back from systemd. After a
    // clean `termiod stop` the unit is merely inactive, and a `setsid` fork
    // here would take the socket the unit binds next — leaving the unit
    // failing at every later start and the daemon unsupervised again.
    if crate::service::systemd_unit_owns_daemon() {
        return crate::service::start_systemd_unit();
    }
    let exe = std::env::current_exe().context("locating termiod binary")?;
    use std::os::unix::process::CommandExt;
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("serve");
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::null());
    cmd.stderr(std::process::Stdio::null());
    unsafe {
        cmd.pre_exec(|| {
            // Detach from the client's session so the daemon survives us.
            libc::setsid();
            // Then fork once more, so the daemon's parent is pid 1 rather than
            // whichever client happened to autostart it. Clients here outlive
            // the daemon routinely — the app, and the long-lived `termiod
            // stdio` an SSH attach runs — and none of them waits on it, so its
            // exit used to leave a zombie whose pid still answered `kill(pid,
            // 0)`. Supervised hosts never had this: systemd is the parent
            // there, and it reaps (#571).
            match libc::fork() {
                -1 => Err(std::io::Error::last_os_error()),
                0 => Ok(()),
                _ => libc::_exit(0),
            }
        });
    }
    // Waits on the intermediate, which exits the instant it has forked — never
    // on the daemon, which is no longer a child of this process at all.
    cmd.spawn()
        .context("starting termiod daemon")?
        .wait()
        .context("waiting for the daemon to detach")?;
    Ok(())
}

async fn request(msg: &Control) -> Result<Control> {
    request_with_capabilities(msg, &[]).await
}

/// A request on a control channel that negotiates extra capabilities. The
/// daemon refuses a verb whose capability was not asked for, so a verb that
/// needs one has to say so at the handshake rather than at use.
async fn request_with_capabilities(msg: &Control, extra: &[&str]) -> Result<Control> {
    let mut stream = connect_control(extra).await?;
    write_control(&mut stream, msg).await?;
    match read_frame(&mut stream).await? {
        Some(Frame::Control(c)) => Ok(c),
        Some(_) => bail!("daemon sent an unexpected frame"),
        None => bail!("daemon closed the connection"),
    }
}

async fn connect_channel(role: ChannelRole) -> Result<UnixStream> {
    Ok(connect_channel_with_identity(role, false, false, &[]).await?.0)
}

async fn connect_control(extra: &[&str]) -> Result<UnixStream> {
    Ok(
        connect_channel_with_identity(ChannelRole::Control, false, false, extra)
            .await?
            .0,
    )
}

async fn connect_channel_with_identity(
    role: ChannelRole,
    snapshot: bool,
    grid_diff: bool,
    extra: &[&str],
) -> Result<(UnixStream, Option<String>)> {
    let mut stream = connect().await?;
    let mut caps = vec!["events".to_string(), "send_wait".to_string()];
    if snapshot {
        caps.push("snapshot".to_string());
        caps.push("scrollback".to_string());
    }
    if grid_diff {
        caps.push("grid_diff".to_string());
    }
    caps.extend(extra.iter().map(|cap| cap.to_string()));
    write_control(
        &mut stream,
        &Control::Hello {
            proto: PROTOCOL_VERSION,
            min_proto: PROTOCOL_VERSION,
            role,
            caps,
            client: format!("termiod-cli/{}", env!("CARGO_PKG_VERSION")),
        },
    )
    .await?;
    match read_frame(&mut stream).await {
        Ok(Some(Frame::Control(Control::HelloOk { client_id, .. }))) => {
            Ok((stream, Some(client_id)))
        }
        Ok(Some(Frame::Control(Control::HelloErr { code, supported }))) => {
            bail!("protocol negotiation failed ({code:?}); host supports {supported:?}")
        }
        // A v0 host either closes on the unknown hello op or returns its
        // legacy error. Reconnect and send the original v0-shaped request.
        Ok(Some(_)) | Ok(None) | Err(_) => Ok((connect().await?, None)),
    }
}

/// Subscribe to a workspace's filesystem resource and stream its batches
/// (§C.10). `since` resumes from a cursor a previous run printed; without it
/// the host reports `gap`, meaning "scan before applying anything".
///
/// This is the reference consumer of resumable subscriptions: kill it, let the
/// tree change, restart with `--since <seq>`, and the missed batches replay.
pub async fn watch(root: &str, since: Option<u64>) -> Result<()> {
    let mut stream = connect().await?;
    write_control(
        &mut stream,
        &Control::Hello {
            proto: PROTOCOL_VERSION,
            min_proto: PROTOCOL_VERSION,
            role: ChannelRole::Control,
            caps: vec!["events".to_string(), "resources".to_string()],
            client: format!("termiod-cli/{}", env!("CARGO_PKG_VERSION")),
        },
    )
    .await?;
    match read_frame(&mut stream).await {
        Ok(Some(Frame::Control(Control::HelloOk { caps, .. }))) => {
            if !caps.iter().any(|c| c == "resources") {
                bail!("this host does not support resource subscriptions");
            }
        }
        Ok(Some(Frame::Control(Control::HelloErr { code, supported }))) => {
            bail!("protocol negotiation failed ({code:?}); host supports {supported:?}")
        }
        _ => bail!("this host does not support resource subscriptions"),
    }

    write_control(
        &mut stream,
        &Control::SubscribeResource {
            resource: root.to_string(),
            since,
            seq: Some(1),
        },
    )
    .await?;

    loop {
        match read_frame(&mut stream).await? {
            Some(Frame::Control(Control::Subscribed { resource, seq, gap, .. })) => {
                println!("subscribed {resource} seq={seq} gap={gap}");
                if gap {
                    println!("  (no usable baseline — a real client scans here)");
                }
            }
            Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
            Some(Frame::Event(Event::FsChanged {
                seq,
                paths,
                full_rescan,
                git_meta,
                ..
            })) => {
                if full_rescan {
                    println!("seq={seq} FULL RESCAN (git_meta={git_meta})");
                } else {
                    println!(
                        "seq={seq} git_meta={git_meta} dirs={}",
                        if paths.is_empty() {
                            "-".to_string()
                        } else {
                            paths.join(", ")
                        }
                    );
                }
            }
            Some(_) => {}
            None => return Ok(()),
        }
    }
}

pub async fn create(spec: CreateSpec) -> Result<String> {
    match request(&Control::Create { spec, seq: Some(1) }).await? {
        Control::Created { id, .. } => Ok(id),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

pub async fn list() -> Result<Vec<SessionInfo>> {
    match request(&Control::List { seq: Some(1) }).await? {
        Control::Sessions { sessions, .. } => Ok(sessions),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

pub async fn kill(id: &str) -> Result<()> {
    match request(&Control::Kill {
        id: id.to_string(),
        seq: Some(1),
    })
    .await?
    {
        Control::Ok { .. } => Ok(()),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

pub async fn send(id: &str, data: Vec<u8>) -> Result<()> {
    match request(&Control::Send {
        id: id.to_string(),
        data,
        seq: Some(1),
    })
    .await?
    {
        Control::Ok { .. } => Ok(()),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

pub async fn set_status(
    id: &str,
    status: &str,
    title: Option<String>,
    details: crate::protocol::StatusDetails,
) -> Result<()> {
    let details = details.sanitized();
    match request(&Control::SetStatus {
        id: id.to_string(),
        status: status.to_string(),
        title,
        transcript_path: details.transcript_path,
        conversation_id: details.conversation_id,
        tool: details.tool,
        prompt_title: details.prompt_title,
        seq: Some(1),
    })
    .await?
    {
        Control::Ok { .. } => Ok(()),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

/// Install (or remove) termio's agent integration on the daemon's box.
pub async fn install_agents(
    request: crate::agent::install::InstallRequest,
) -> Result<Vec<crate::agent::install::InstallResult>> {
    let control = Control::InstallAgents {
        agents: request.agents,
        hooks: request.hooks,
        skills: request.skills,
        reporter: request.reporter,
        hook_version: Some(request.hook_version),
        seq: Some(1),
    };
    match request_with_capabilities(&control, &["agents"]).await? {
        Control::AgentsInstalled { results, .. } => Ok(results),
        Control::Error { message, .. } => bail!(message),
        other => bail!("unexpected reply: {other:?}"),
    }
}

/// Local terminal window size via TIOCGWINSZ, with a sane fallback.
pub fn term_size() -> (u16, u16) {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::ioctl(libc::STDIN_FILENO, libc::TIOCGWINSZ, &mut ws) };
    if rc == 0 && ws.ws_row > 0 && ws.ws_col > 0 {
        (ws.ws_row, ws.ws_col)
    } else {
        (24, 80)
    }
}

/// RAII raw-mode guard for stdin; restores the saved termios on drop.
struct RawMode {
    fd: i32,
    saved: libc::termios,
    active: bool,
}

impl RawMode {
    fn enable() -> Result<RawMode> {
        let fd = std::io::stdin().as_raw_fd();
        let mut saved: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(fd, &mut saved) } != 0 {
            bail!("stdin is not a tty (tcgetattr failed)");
        }
        let mut raw = saved;
        unsafe { libc::cfmakeraw(&mut raw) };
        if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) } != 0 {
            bail!("tcsetattr failed");
        }
        Ok(RawMode {
            fd,
            saved,
            active: true,
        })
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        if self.active {
            unsafe {
                libc::tcsetattr(self.fd, libc::TCSANOW, &self.saved);
            }
        }
    }
}

/// Observe a session without interacting with it. PTY data is copied directly
/// to stdout until the session exits, the pipe closes, or SIGINT arrives.
pub async fn observe(
    target: &str,
    create_if_missing: Option<CreateSpec>,
    grid_diff: bool,
) -> Result<()> {
    let (local_rows, local_cols) = term_size();
    let mut stream = if grid_diff {
        connect_channel_with_identity(ChannelRole::Attach, true, true, &[])
            .await?
            .0
    } else {
        connect_channel(ChannelRole::Attach).await?
    };
    write_control(
        &mut stream,
        &Control::Attach {
            target: target.to_string(),
            create_if_missing,
            rows: 24,
            cols: 80,
            mode: AttachMode::Observe,
            seq: Some(1),
        },
    )
    .await?;

    match read_frame(&mut stream).await? {
        Some(Frame::Control(Control::Attached { rows, cols, .. })) => {
            if (rows, cols) != (local_rows, local_cols) {
                eprintln!(
                    "session is {rows}x{cols}; your terminal is {local_rows}x{local_cols} \
                     — display may wrap differently"
                );
            }
        }
        Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
        other => bail!("unexpected attach reply: {other:?}"),
    }

    let mut stdout = tokio::io::stdout();
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())
        .context("installing SIGINT handler")?;

    let mut grid = None;
    loop {
        tokio::select! {
            _ = interrupt.recv() => return Ok(()),
            frame = read_frame(&mut stream) => {
                match frame {
                    Ok(Some(Frame::Data(bytes))) => {
                        if stdout.write_all(&bytes).await.is_err()
                            || stdout.flush().await.is_err()
                        {
                            return Ok(());
                        }
                    }
                    Ok(Some(Frame::Snapshot(snapshot))) if grid_diff => {
                        grid = Some(GridView::from_snapshot(snapshot));
                        if render_grid(&mut stdout, grid.as_ref().unwrap()).await.is_err() {
                            return Ok(());
                        }
                    }
                    Ok(Some(Frame::Grid(diff))) if grid_diff => {
                        let Some(view) = grid.as_mut() else { continue };
                        if view.apply(diff).is_err()
                            || render_grid(&mut stdout, view).await.is_err()
                        {
                            return Ok(());
                        }
                    }
                    Ok(Some(Frame::Control(Control::Exited { .. }))) => return Ok(()),
                    Ok(Some(_)) => {}
                    Ok(None) => return Ok(()),
                    Err(error) => return Err(error),
                }
            }
        }
    }
}

type LinkRead = Box<dyn tokio::io::AsyncRead + Unpin + Send>;
type LinkWrite = Box<dyn tokio::io::AsyncWrite + Unpin + Send>;

/// Open an attach channel to a **remote** host: the framed protocol itself
/// rides `ssh <host> termiod stdio`, so this process is a full protocol client
/// of the remote daemon — not a terminal watching a remote CLI's tty. That
/// distinction is what makes the parsed plane (`S` + `G`) reachable over the
/// network at all.
async fn open_ssh_attach_link(
    host: &str,
    grid_diff: bool,
) -> Result<(LinkRead, LinkWrite, tokio::process::Child, Option<String>)> {
    let mut cmd = tokio::process::Command::new("ssh");
    cmd.arg("-o").arg("BatchMode=yes");
    for arg in crate::remote::ssh_multiplex_args() {
        cmd.arg(arg);
    }
    cmd.arg(host)
        .arg(format!("{} stdio", crate::remote::remote_bin()))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true);
    let mut child = cmd.spawn().context("spawning ssh")?;
    let mut rd: LinkRead = Box::new(child.stdout.take().context("ssh stdout")?);
    let mut wr: LinkWrite = Box::new(child.stdin.take().context("ssh stdin")?);

    let mut caps = vec![
        "events".to_string(),
        "send_wait".to_string(),
        "snapshot".to_string(),
        "scrollback".to_string(),
    ];
    if grid_diff {
        caps.push("grid_diff".to_string());
    }
    write_control(
        &mut wr,
        &Control::Hello {
            proto: PROTOCOL_VERSION,
            min_proto: PROTOCOL_VERSION,
            role: ChannelRole::Attach,
            caps,
            client: format!("termiod-cli/{}", env!("CARGO_PKG_VERSION")),
        },
    )
    .await?;
    let client_id = match read_frame(&mut rd).await {
        Ok(Some(Frame::Control(Control::HelloOk {
            caps, client_id, ..
        }))) => {
            if grid_diff && !caps.iter().any(|c| c == "grid_diff") {
                // Better to say so than to silently stream unbounded bytes over
                // a metered link.
                eprintln!("[warning: {host} did not negotiate grid_diff — falling back to raw bytes]");
            }
            Some(client_id)
        }
        Ok(Some(Frame::Control(Control::HelloErr { code, supported }))) => {
            bail!("{host}: protocol negotiation failed ({code:?}); host supports {supported:?}")
        }
        _ => bail!("{host}: no protocol reply — is termiod deployed there? try `termiod remote deploy {host}`"),
    };
    Ok((rd, wr, child, client_id))
}

/// Attach interactively. Creates the session first if `create_if_missing` is
/// set and the target does not exist. Returns when the user detaches (Ctrl-\)
/// or the session's process exits.
///
/// With `host`, the protocol rides an SSH pipe to that host's daemon; without
/// it, the local Unix socket. Local and remote differ only in the pipe.
pub async fn attach(
    target: &str,
    create_if_missing: Option<CreateSpec>,
    grid_diff: bool,
    host: Option<&str>,
) -> Result<()> {
    let (rows, cols) = term_size();
    let (mut rd, mut wr, _ssh, negotiated_client_id) = match host {
        Some(host) => {
            let (rd, wr, child, id) = open_ssh_attach_link(host, grid_diff).await?;
            (rd, wr, Some(child), id)
        }
        None => {
            let (stream, id) =
                connect_channel_with_identity(ChannelRole::Attach, true, grid_diff, &[]).await?;
            let (r, w) = stream.into_split();
            (Box::new(r) as LinkRead, Box::new(w) as LinkWrite, None, id)
        }
    };
    write_control(
        &mut wr,
        &Control::Attach {
            target: target.to_string(),
            create_if_missing,
            rows,
            cols,
            mode: AttachMode::Interact,
            seq: Some(1),
        },
    )
    .await?;

    // Attaching no longer takes the token off whoever holds it, so this
    // attachment types its way in like any other device (`Control::ClaimWriter`).
    let holds_token = Arc::new(AtomicBool::new(false));
    let id = match read_frame(&mut rd).await? {
        Some(Frame::Control(Control::Attached { id, name, writer, .. })) => {
            eprintln!("[attached to {name} ({id}) — detach with Ctrl-\\ ]\r");
            holds_token.store(writer, Ordering::Relaxed);
            id
        }
        Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
        other => bail!("unexpected attach reply: {other:?}"),
    };

    let _raw = RawMode::enable()?;

    // Reader: daemon frames → stdout. Signals the main loop via `done_tx` when
    // the stream ends (session exited or closed), carrying any exit status.
    let (done_tx, mut done_rx) = tokio::sync::oneshot::channel::<Option<i32>>();
    let (resize_claim_tx, mut resize_claim_rx) = tokio::sync::mpsc::unbounded_channel();
    let scrollback_rows = Arc::new(AtomicUsize::new(0));
    let reader_scrollback_rows = scrollback_rows.clone();
    let reader_holds_token = holds_token.clone();
    let reader_client_id = negotiated_client_id.clone();
    // Shared with the input loop rather than kept local to it, so the answer to
    // a claim clears the latch from wherever it arrives — including a refusal,
    // which carries no `writer_changed` and would otherwise leave this
    // attachment silently unable to ever ask again.
    let claiming = Arc::new(AtomicBool::new(false));
    let reader_claiming = claiming.clone();
    let reader = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        let mut status = None;
        let mut grid = None;
        loop {
            match read_frame(&mut rd).await {
                Ok(Some(Frame::Data(bytes))) => {
                    if stdout.write_all(&bytes).await.is_err() {
                        break;
                    }
                    let _ = stdout.flush().await;
                }
                Ok(Some(Frame::Snapshot(snapshot))) => {
                    let rendered = if grid_diff {
                        grid = Some(GridView::from_snapshot(snapshot));
                        render_grid(&mut stdout, grid.as_ref().unwrap()).await
                    } else {
                        render_snapshot(&mut stdout, &snapshot).await
                    };
                    if rendered.is_err() {
                        break;
                    }
                }
                Ok(Some(Frame::Grid(diff))) if grid_diff => {
                    let Some(view) = grid.as_mut() else { continue };
                    if view.apply(diff).is_err() || render_grid(&mut stdout, view).await.is_err() {
                        break;
                    }
                }
                Ok(Some(Frame::History(history))) => {
                    reader_scrollback_rows
                        .fetch_add(usize::from(history.row_count), Ordering::Relaxed);
                }
                Ok(Some(Frame::Control(Control::ResizeClaim {
                    writer: Some(writer),
                    ..
                }))) if negotiated_client_id.as_deref() == Some(writer.as_str()) => {
                    let _ = resize_claim_tx.send(());
                }
                Ok(Some(Frame::Event(Event::WriterChanged { writer, .. }))) => {
                    let mine = matches!((&writer, &reader_client_id), (Some(w), Some(id)) if w == id);
                    reader_holds_token.store(mine, Ordering::Relaxed);
                    reader_claiming.store(false, Ordering::Relaxed);
                }
                Ok(Some(Frame::Control(Control::Error { .. }))) => {
                    reader_claiming.store(false, Ordering::Relaxed);
                }
                Ok(Some(Frame::Control(Control::Exited { status: s, .. }))) => {
                    status = Some(s);
                    break;
                }
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => break,
            }
        }
        let _ = done_tx.send(status);
    });

    // SIGWINCH → resize.
    let mut winch = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())
        .context("installing SIGWINCH handler")?;

    // stdin → daemon (watching for the detach key).
    let mut stdin = tokio::io::stdin();
    use tokio::io::AsyncReadExt;
    let mut buf = [0u8; 8192];
    let mut detached = false;
    loop {
        tokio::select! {
            _ = winch.recv() => {
                let (r, c) = term_size();
                let _ = write_viewport(&mut wr, r, c).await;
            }
            Some(()) = resize_claim_rx.recv() => {
                let (r, c) = term_size();
                let _ = write_viewport(&mut wr, r, c).await;
            }
            n = stdin.read(&mut buf) => {
                match n {
                    Ok(0) => break, // stdin closed
                    Ok(n) => {
                        if let Some(pos) = buf[..n].iter().position(|&b| b == DETACH_KEY) {
                            if pos > 0 {
                                let _ = write_data(&mut wr, &buf[..pos]).await;
                            }
                            detached = true;
                            break;
                        }
                        // Typing is what takes the token; attaching no longer
                        // does. Sent at most once per lost token — the answer
                        // clears the latch — so a burst of keystrokes on a muted
                        // attachment is not a burst of claims. Latched only on a
                        // claim that actually reached the wire: a write that
                        // failed draws no answer at all, and latching it anyway
                        // would mute this attachment for good.
                        if !holds_token.load(Ordering::Relaxed)
                            && !claiming.load(Ordering::Relaxed)
                        {
                            // Latched *before* the write is awaited. The answer
                            // can land during that await, and a latch written
                            // afterwards would overwrite the reader's clear —
                            // leaving this attachment unable to claim again the
                            // next time it loses the token. Only a write that
                            // never reached the wire unlatches, because nothing
                            // is coming back to do it.
                            claiming.store(true, Ordering::Relaxed);
                            if write_control(
                                &mut wr, &Control::ClaimWriter { seq: None }).await.is_err()
                            {
                                claiming.store(false, Ordering::Relaxed);
                            }
                        }
                        if write_data(&mut wr, &buf[..n]).await.is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            done = &mut done_rx => {
                // Reader finished: session exited or the socket closed.
                drop(_raw);
                if let Ok(Some(status)) = done {
                    eprintln!("\r\n[session exited: status {status}]");
                } else {
                    eprintln!("\r\n[disconnected]");
                }
                report_scrollback(scrollback_rows.load(Ordering::Relaxed));
                return Ok(());
            }
        }
    }

    if detached {
        let _ = write_control(&mut wr, &Control::Detach { seq: None }).await;
        eprintln!("\r\n[detached — session {id} still running]");
    }
    reader.abort();
    report_scrollback(scrollback_rows.load(Ordering::Relaxed));
    Ok(())
}

fn report_scrollback(rows: usize) {
    if rows > 0 {
        eprintln!("scrollback: {rows} rows staged");
    }
}

struct GridView {
    rows: u16,
    cols: u16,
    cursor_x: u16,
    cursor_y: u16,
    cells: Vec<WireCell>,
}

impl GridView {
    fn from_snapshot(snapshot: Snapshot) -> Self {
        Self {
            rows: snapshot.rows,
            cols: snapshot.cols,
            cursor_x: snapshot.cursor_x,
            cursor_y: snapshot.cursor_y,
            cells: snapshot.cells,
        }
    }

    fn apply(&mut self, diff: GridDiff) -> Result<()> {
        if (self.rows, self.cols) != (diff.rows, diff.cols) {
            self.rows = diff.rows;
            self.cols = diff.cols;
            self.cells = vec![WireCell::default(); usize::from(diff.rows) * usize::from(diff.cols)];
        }
        for row in diff.dirty_rows {
            if row.row_index >= self.rows || row.cells.len() != usize::from(self.cols) {
                bail!("malformed grid-diff row {}", row.row_index);
            }
            let start = usize::from(row.row_index) * usize::from(self.cols);
            self.cells[start..start + usize::from(self.cols)].clone_from_slice(&row.cells);
        }
        self.cursor_x = diff.cursor_x;
        self.cursor_y = diff.cursor_y;
        Ok(())
    }
}

async fn render_snapshot<W: AsyncWriteExt + Unpin>(
    output: &mut W,
    snapshot: &Snapshot,
) -> Result<()> {
    // Format v2: the host already expressed the screen as VT sequences, prologue
    // included. Write them through untouched — synthesising anything here would
    // put this client back in the business of deciding colour, and prepending a
    // reset of its own is what the host-owned prologue exists to replace (a
    // client-side `ESC[2J ESC[H` clears the screen but leaves the mode state
    // that actually breaks the repaint).
    if let Some(vt) = &snapshot.vt {
        output.write_all(vt).await?;
        output.flush().await?;
        return Ok(());
    }
    render_cells(
        output,
        snapshot.rows,
        snapshot.cols,
        snapshot.cursor_x,
        snapshot.cursor_y,
        &snapshot.cells,
    )
    .await
}

async fn render_grid<W: AsyncWriteExt + Unpin>(output: &mut W, grid: &GridView) -> Result<()> {
    render_cells(
        output,
        grid.rows,
        grid.cols,
        grid.cursor_x,
        grid.cursor_y,
        &grid.cells,
    )
    .await
}

async fn render_cells<W: AsyncWriteExt + Unpin>(
    output: &mut W,
    rows: u16,
    cols: u16,
    cursor_x: u16,
    cursor_y: u16,
    cells: &[WireCell],
) -> Result<()> {
    let mut rendered = Vec::with_capacity(cells.len() + usize::from(rows) * 2);
    rendered.extend_from_slice(b"\x1b[2J\x1b[H");
    for row in 0..rows {
        if row > 0 {
            rendered.extend_from_slice(b"\r\n");
        }
        let start = usize::from(row) * usize::from(cols);
        let end = start + usize::from(cols);
        for cell in &cells[start..end] {
            let character = if cell.codepoint == 0 {
                ' '
            } else {
                char::from_u32(cell.codepoint).unwrap_or('\u{fffd}')
            };
            let mut encoded = [0; 4];
            rendered.extend_from_slice(character.encode_utf8(&mut encoded).as_bytes());
        }
    }
    rendered.extend_from_slice(
        format!(
            "\x1b[{};{}H",
            cursor_y.saturating_add(1),
            cursor_x.saturating_add(1)
        )
        .as_bytes(),
    );
    output.write_all(&rendered).await?;
    output.flush().await?;
    Ok(())
}

#[cfg(test)]
mod autostart_tests {
    #[test]
    fn only_a_provably_absent_daemon_recovers_by_spawning() {
        assert!(super::absent_daemon(Some(libc::ENOENT)));
        assert!(super::absent_daemon(Some(libc::ECONNREFUSED)));
        // Proof that nothing is serving, but not permission to unlink a file
        // this daemon did not create or to spawn one that cannot bind over it.
        assert!(!super::absent_daemon(Some(libc::ENOTSOCK)));
        assert!(crate::lifecycle::nothing_is_serving(Some(libc::ENOTSOCK)));
        assert!(!super::absent_daemon(Some(libc::EPERM)));
        assert!(!super::absent_daemon(Some(libc::EACCES)));
        assert!(!super::absent_daemon(Some(libc::ETIMEDOUT)));
        assert!(!super::absent_daemon(None));
    }
}

/// The daemon's roster over a connection that never spawns one. A daemon this
/// call would have to start hosts no sessions, so an absent daemon simply
/// answers `None` — and from the `termio` client binary, `current_exe()` is
/// not the daemon anyway (see the crate-root seam note in `lib.rs`). Errors
/// only when a live daemon answers badly.
pub async fn sessions_of_running_daemon() -> Result<Option<Vec<SessionInfo>>> {
    let sock = paths::socket_path()?;
    let mut stream = match UnixStream::connect(&sock).await {
        Ok(stream) => stream,
        Err(_) => return Ok(None),
    };
    write_control(
        &mut stream,
        &Control::Hello {
            proto: PROTOCOL_VERSION,
            min_proto: PROTOCOL_VERSION,
            role: ChannelRole::Control,
            caps: vec!["events".to_string()],
            client: format!("termiod-cli/{}", env!("CARGO_PKG_VERSION")),
        },
    )
    .await?;
    match read_frame(&mut stream).await? {
        Some(Frame::Control(Control::HelloOk { .. })) => {}
        _ => return Ok(None),
    }
    write_control(&mut stream, &Control::List { seq: Some(1) }).await?;
    loop {
        match read_frame(&mut stream).await? {
            Some(Frame::Control(Control::Sessions { sessions, .. })) => return Ok(Some(sessions)),
            Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
            Some(_) => continue,
            None => bail!("the daemon closed the connection before answering list"),
        }
    }
}

/// One read-only look at a session's current screen: an observe-mode
/// attachment negotiated with the snapshot capability, dropped as soon as
/// the screen is known. Observe mode never takes the write token and never
/// resizes the PTY, so reading a screen is invisible to the session's real
/// client. Never spawns a daemon, for the same reason as the roster above.
///
/// Two ways the screen arrives: the normal `S` frame, or — when the host's
/// VT is stale and it explicitly falls back to ring replay — a run of `D`
/// frames closed by `ready`, which this end replays into its own engine.
/// Both paths sit under one deadline so a host that answers with neither
/// can never hang the caller.
pub async fn observe_screen_rows(target: &str, rows: u16, cols: u16) -> Result<Vec<String>> {
    let sock = paths::socket_path()?;
    let mut stream = UnixStream::connect(&sock)
        .await
        .with_context(|| format!("connecting to termiod at {}", sock.display()))?;
    write_control(
        &mut stream,
        &Control::Hello {
            proto: PROTOCOL_VERSION,
            min_proto: PROTOCOL_VERSION,
            role: ChannelRole::Attach,
            caps: vec![
                "events".to_string(),
                "send_wait".to_string(),
                "snapshot".to_string(),
                "scrollback".to_string(),
            ],
            client: format!("termiod-cli/{}", env!("CARGO_PKG_VERSION")),
        },
    )
    .await?;
    match read_frame(&mut stream).await? {
        Some(Frame::Control(Control::HelloOk { .. })) => {}
        Some(Frame::Control(Control::HelloErr { code, supported })) => {
            bail!("protocol negotiation failed ({code:?}); host supports {supported:?}")
        }
        _ => bail!("this daemon cannot answer snapshot reads"),
    }
    write_control(
        &mut stream,
        &Control::Attach {
            target: target.to_string(),
            create_if_missing: None,
            rows,
            cols,
            mode: AttachMode::Observe,
            seq: Some(2),
        },
    )
    .await?;
    let collected = tokio::time::timeout(Duration::from_secs(10), async {
        let mut dimensions = (rows, cols);
        let mut replay: Vec<u8> = Vec::new();
        loop {
            match read_frame(&mut stream).await? {
                Some(Frame::Snapshot(snapshot)) => return Ok(Screen::Snapshot(snapshot)),
                Some(Frame::Control(Control::Attached { rows, cols, .. })) => {
                    dimensions = (rows, cols);
                }
                Some(Frame::Control(Control::Error { message, .. })) => bail!(message),
                Some(Frame::Data(bytes)) => replay.extend_from_slice(&bytes),
                Some(Frame::Event(Event::Ready { .. })) => {
                    return Ok(Screen::Replay {
                        rows: dimensions.0,
                        cols: dimensions.1,
                        bytes: replay,
                    })
                }
                Some(_) => continue,
                None => bail!("the daemon closed the stream before sending a screen"),
            }
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("timed out waiting for the session's screen"))??;
    match collected {
        Screen::Snapshot(snapshot) => snapshot_text_rows(&snapshot),
        Screen::Replay { rows, cols, bytes } => {
            let mut terminal = termiod_vt::VtTerminal::new(rows, cols)?;
            terminal.vt_write(&bytes);
            let grid = terminal.snapshot()?;
            let mut lines =
                text_rows(usize::from(grid.cols), grid.cells.iter().map(|cell| cell.codepoint));
            while lines.last().is_some_and(|line| line.is_empty()) {
                lines.pop();
            }
            Ok(lines)
        }
    }
}

enum Screen {
    Snapshot(Snapshot),
    Replay { rows: u16, cols: u16, bytes: Vec<u8> },
}

/// A snapshot's text rows the way the app's `read` renders a screen: each row
/// right-trimmed, trailing blank rows dropped. A v2 payload is VT sequences
/// replayed into a fresh engine — self-contained by design, proven by
/// `snapshot_prologue.rs` — and the packed-cell form reads straight off the
/// grid.
pub fn snapshot_text_rows(snapshot: &Snapshot) -> Result<Vec<String>> {
    let mut rows = if let Some(vt) = &snapshot.vt {
        let mut terminal = termiod_vt::VtTerminal::new(snapshot.rows, snapshot.cols)?;
        terminal.vt_write(vt);
        let grid = terminal.snapshot()?;
        text_rows(usize::from(grid.cols), grid.cells.iter().map(|cell| cell.codepoint))
    } else {
        text_rows(
            usize::from(snapshot.cols),
            snapshot.cells.iter().map(|cell| cell.codepoint),
        )
    };
    while rows.last().is_some_and(|row| row.is_empty()) {
        rows.pop();
    }
    Ok(rows)
}

fn text_rows(cols: usize, codepoints: impl Iterator<Item = u32>) -> Vec<String> {
    if cols == 0 {
        return Vec::new();
    }
    let cells: Vec<u32> = codepoints.collect();
    cells
        .chunks(cols)
        .map(|row| {
            row.iter()
                .map(|&codepoint| {
                    let character = char::from_u32(codepoint).unwrap_or(' ');
                    if character == '\0' {
                        ' '
                    } else {
                        character
                    }
                })
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect()
}
