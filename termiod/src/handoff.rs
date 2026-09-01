//! Replacing the daemon's binary without replacing the daemon.
//!
//! Every other way of upgrading the host ends with the sessions dead, and not
//! by oversight. A PTY's master is a descriptor held by this process; when this
//! process goes the descriptor closes, the slave side raises `SIGHUP`, and the
//! agent that was mid-task goes with it. Writing state down does not help — a
//! file can describe a session but cannot hold a running process.
//!
//! `execve` is the exception. It replaces the process *image* while keeping the
//! *process*: same pid, same children, same open descriptors (anything without
//! `FD_CLOEXEC`), same session and process group. So the PTY masters stay open,
//! the shells never see a hangup, and the only thing that changes is which code
//! is on the other end of the descriptor. This is what makes "detach ≠ kill"
//! survive an upgrade rather than only a disconnect: the lifecycle loop can
//! stop asking the user to close their work before a new build goes on.
//!
//! What it costs is that nothing in memory survives. Tasks, the session table,
//! the replay rings, the client connections: gone the instant `execve` succeeds.
//! Whatever the new image needs, this one has to write down first and pass along
//! by descriptor number. That is what a [`Blob`] is.
//!
//! The blob is written to a file that is unlinked before a byte goes into it,
//! so it has no name for anything to open and the kernel frees it when the last
//! descriptor closes. That matters: it holds every session's replay ring, which
//! is raw terminal output — an agent's transcript, whatever `env` printed, a
//! token someone echoed. A handoff must not become a way of writing that to
//! disk behind the user's back.
//!
//! Not everything crosses:
//!
//! - **Client connections.** A Mac or a phone is holding a socket to us; that
//!   socket dies with the image. Clients reconnect and re-attach by session id,
//!   which is the path they already use after any restart — except that this
//!   time the attach finds the session alive, with its ring and its running
//!   program.
//! - **The WebSocket listener.** Re-bound by the new image from the same
//!   on-disk configuration rather than carried, so its splices end the way a
//!   dropped tunnel already does.
//! - **The VT sidecar.** A parser is state in memory, not a descriptor. The new
//!   image starts a fresh one and replays the carried ring through it, which
//!   reconstructs the screen from the same bytes that produced it.
//!
//! ## What is still not proven
//!
//! The probe below asks a candidate whether it implements this contract, and a
//! candidate that lies passes. Nothing short of running `serve --handoff` for
//! real would prove otherwise, and running it for real is the thing that cannot
//! be taken back — by the time a new image could report that it cannot start,
//! the old one no longer exists to hear it.
//!
//! So the residual risk is stated rather than hidden: **a binary that answers
//! the probe correctly and then fails to start takes every session with it.**
//! What the probe does close is the case that actually happens — a termiod old
//! enough to answer `--version` and too old to know this verb — and what keeps
//! the rest small is that the caller with any business asking for a handoff is
//! `deploy`, handing off to a binary it staged from its own bundle moments
//! earlier and has just seen answer `status`.
//!
//! The far side helps where it can: every startup step that a cold start is
//! right to refuse over degrades instead, because on this path refusing means
//! killing what it was handed. See `daemon::serve`.
//!
//! The Unix listener *is* carried, on its own descriptor. Re-binding would mean
//! unlinking and re-creating the socket, and a client connecting in that window
//! would find nothing there and autostart a second daemon over a state
//! directory this one still owns. Carrying it means connects queue in the
//! kernel's backlog and are served by whichever image is up when they are
//! accepted.

use anyhow::{bail, Context, Result};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};

/// The flag that tells a starting daemon it is the far side of a handoff. Its
/// value is the descriptor number the blob can be read from.
pub const HANDOFF_FLAG: &str = "--handoff";

const MAGIC: &[u8; 8] = b"TERMIOD\x01";

/// The shape of what crosses. Bumped whenever [`Blob`] or [`CarriedSession`]
/// changes in a way the far side would misread — a renamed field, a new
/// descriptor, a different order for the ring runs.
///
/// It is checked *before* the exec, not after: by the time a new image could
/// notice it cannot read the blob, the old one is gone and so are the sessions.
pub const FORMAT_VERSION: u32 = 1;

/// What `termiod handoff --probe` prints, and the only thing `vet` accepts.
///
/// Whether a candidate can be handed off to is not a question `--version`
/// answers. Every termiod ever built answers `--version`, including the ones
/// that have never heard of `serve --handoff`; so does `/usr/bin/true` with a
/// wrapper around it. Exec'ing one of those replaces the daemon with a program
/// that exits, and every PTY master closes behind it.
///
/// So the probe asks the one question that matters — "do you implement this
/// exact contract" — and the candidate answers by naming the format it speaks.
pub fn probe_token() -> String {
    format!("termiod-handoff {FORMAT_VERSION}")
}

/// How long the daemon waits for a session actor to hand its PTY over. A
/// session that misses this is left behind rather than holding the upgrade
/// open, and is named in the daemon's log on the way out.
pub const CARRY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// One session, packed for the crossing. The descriptor numbers are meaningless
/// to anything but the process that wrote them, which is the same process that
/// reads them back — that is the whole point of the exec.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CarriedSession {
    pub id: String,
    pub name: String,
    pub cwd: String,
    pub command: String,
    pub pid: i32,
    pub rows: u16,
    pub cols: u16,
    pub created_unix: u64,
    pub status: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub workstream: Option<crate::protocol::WorkstreamSpec>,
    /// The PTY master, as a descriptor number in the process about to `execve`.
    ///
    /// Filled in at [`pack`] time, from the owning descriptor the session actor
    /// handed over, and *only* for the sessions that actually reach the blob.
    /// A number written here earlier would outlive the decision to carry it:
    /// a session dropped for missing the carry deadline would have left an open
    /// master with no owner and no reader on the far side of the exec — a
    /// process alive, un-hung-up, and invisible.
    pub master_fd: RawFd,
    /// How many bytes of replay ring follow this session's header in the blob.
    pub ring_len: u64,
    /// Whether replaying that ring into a blank terminal of these dimensions
    /// draws the screen the program is actually looking at.
    ///
    /// False once the ring has evicted anything, or the session was resized
    /// after those bytes were written. The new image starts its VT stale rather
    /// than answering snapshots from a reconstruction it has been told is
    /// wrong. Defaults to false for a blob that predates the field: a daemon
    /// that did not think about the question is not evidence the answer is yes.
    #[serde(default)]
    pub ring_reconstructs_screen: bool,
    /// The status engine's clocks, as elapsed durations
    /// (`session::status::CarriedClocks`).
    ///
    /// `status` alone says *what* the session reads as; this says *how long*
    /// that has been true. Without it every handoff restarted the stale-working
    /// sweep and the stall window, so a daemon upgraded on a timer could defer
    /// both indefinitely. Absent from a blob that predates the field, which
    /// starts the clocks fresh — the old behaviour, for a blob that carries no
    /// answer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_clocks: Option<crate::session::status::CarriedClocks>,
}

/// The header the new image reads before it has any state of its own. Ring
/// bytes follow it, one run per session in `sessions` order.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Blob {
    /// What [`FORMAT_VERSION`] was when this was written. `vet` has already
    /// refused a candidate that speaks a different one, so a mismatch here is
    /// not a version skew but a corrupt or forged blob.
    pub format: u32,
    /// The build that packed this. Recorded for the log line the new image
    /// writes: "0.46.0+1201 handed off to 0.47.0+1240" is the one fact that
    /// makes an upgrade legible after the fact.
    pub from_build: String,
    /// This host's stable identity, carried rather than re-read.
    ///
    /// The new image could load it from disk the way a cold start does, but
    /// that is a fallible read on a path where a failure costs every carried
    /// session — and the identity must not change across a handoff anyway,
    /// which carrying it states outright.
    pub host_id: String,
    /// The already-bound Unix listener. See the module docs for why this is
    /// carried rather than re-bound.
    pub listener_fd: RawFd,
    pub sessions: Vec<CarriedSession>,
}

/// Whether `binary` can be handed off to at all, checked *before* the running
/// daemon takes a single session apart.
///
/// The order matters more than the checks do. Once the session actors have
/// given up their PTYs there is no way back. So everything that can say no says
/// it here, while the daemon is still whole and the client is still holding a
/// socket that can carry the refusal.
///
/// The last check is the strong one: the candidate is *run*, and it has to
/// answer [`probe_token`]. That catches all of the same things `stat` cannot —
/// a binary for the wrong architecture, one missing an interpreter, one
/// truncated by an upload that lost its connection — and, unlike `--version`,
/// also catches the case that actually happens: a termiod old enough to answer
/// but too old to know what `serve --handoff` means.
pub fn vet(binary: &Path) -> Result<PathBuf> {
    if !binary.is_absolute() {
        bail!("{} is not an absolute path", binary.display());
    }
    let binary = binary
        .canonicalize()
        .with_context(|| format!("resolving {}", binary.display()))?;
    let metadata =
        std::fs::metadata(&binary).with_context(|| format!("reading {}", binary.display()))?;
    if !metadata.is_file() {
        bail!("{} is not a regular file", binary.display());
    }
    let probe = run_probe(&binary)?;
    let spoken = probe.trim().to_string();
    let wanted = probe_token();
    if spoken != wanted {
        bail!(
            "{} speaks {:?} where this daemon speaks {wanted:?}",
            binary.display(),
            spoken
        );
    }
    Ok(binary)
}

/// Create the file the blob will be written to, before anything irreversible
/// has happened.
///
/// Split from [`pack`] because it is the fallible half: a missing state
/// directory, a read-only filesystem, no space. Doing it while the daemon is
/// still whole turns those from "the sessions are gone and so is the daemon"
/// into an ordinary refusal the client is told about.
///
/// The file is unlinked before it is returned, so it has no name for anything
/// to open and the kernel reclaims it when the last descriptor closes. That
/// matters: it is about to hold every session's replay ring, which is raw
/// terminal output — an agent's transcript, whatever `env` printed, a token
/// someone echoed. A handoff must not become a way of writing that to disk
/// behind the user's back.
pub fn stage_blob(state_dir: &Path) -> Result<std::fs::File> {
    let path = state_dir.join(format!("handoff.{}", std::process::id()));
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .read(true)
        .write(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))?;
    std::fs::remove_file(&path).with_context(|| format!("unlinking {}", path.display()))?;
    Ok(file)
}

/// How long a candidate binary gets to answer the probe, and how much it may
/// say. A binary that hangs must not hang the daemon with it: `vet` runs on a
/// control task, and a handoff that never resolves is a daemon that can no
/// longer be upgraded — by anyone, ever, until it is stopped.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const PROBE_MAX_OUTPUT: u64 = 4 * 1024;

/// Ask a candidate what handoff contract it speaks, without letting it decide
/// how long that takes or how much it costs.
///
/// The process is waited on *before* its output is read, which is the only
/// order that bounds anything. Reading first looks natural and is a trap: a
/// child that never writes and never exits holds its end of the pipe open, the
/// read blocks in the kernel, and no deadline written after it is ever
/// evaluated — the daemon's control task waits forever on a program whose whole
/// contribution was to sleep. Killing the child on the deadline closes that
/// pipe, which is what makes the read below terminate.
fn run_probe(binary: &Path) -> Result<String> {
    use std::io::Read as _;

    let mut child = std::process::Command::new(binary)
        .arg("handoff")
        .arg("--probe")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .with_context(|| format!("running {} handoff --probe", binary.display()))?;

    let deadline = std::time::Instant::now() + PROBE_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                bail!(
                    "{} did not answer handoff --probe within {}s",
                    binary.display(),
                    PROBE_TIMEOUT.as_secs()
                );
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(20)),
            Err(error) => bail!("waiting for {} handoff --probe: {error}", binary.display()),
        }
    };

    let mut spoken = String::new();
    if let Some(stdout) = child.stdout.take() {
        // Capped: an answer longer than this is not an answer, and a candidate
        // does not get to spend the daemon's memory saying it. A child that
        // wrote more than a pipe holds never exited, so it was killed above and
        // never reaches here.
        let _ = stdout.take(PROBE_MAX_OUTPUT).read_to_string(&mut spoken);
    }
    if !status.success() {
        bail!(
            "{} does not implement the handoff contract (handoff --probe exited {status})",
            binary.display()
        );
    }
    Ok(spoken)
}

/// Write the blob into the staged file and return its descriptor, rewound and
/// exec-safe.
///
/// Consumes the owning master descriptors: a session's number is written into
/// the header at the moment it is committed to the blob, and not before.
/// What a failed [`pack`] gives back: the error, and every descriptor it was
/// handed, still owned and still open.
///
/// Returning them is the whole difference between an upgrade that fails and an
/// upgrade that destroys. By the time `pack` runs, `carry_all` has already made
/// every actor exit — the sessions exist only as these descriptors. Dropping
/// them here, which is what this used to do, closes every PTY master at once
/// and every shell and agent behind them takes SIGHUP. Handed back, they can be
/// adopted again and the daemon goes on as though nothing happened.
impl std::fmt::Debug for PackFailed {
    /// Only the error: the descriptors are numbers whose meaning died with the
    /// process that held them, and printing them invites reading them.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PackFailed")
            .field("error", &format_args!("{:#}", self.error))
            .field("sessions", &self.sessions.len())
            .finish()
    }
}

pub struct PackFailed {
    pub error: anyhow::Error,
    pub listener: OwnedFd,
    pub sessions: Vec<(CarriedSession, OwnedFd, Vec<Bytes>)>,
}

pub fn pack(
    blob: Blob,
    listener: OwnedFd,
    sessions: Vec<(CarriedSession, OwnedFd, Vec<Bytes>)>,
    file: std::fs::File,
) -> std::result::Result<OwnedFd, PackFailed> {
    // Everything fallible happens against borrows, so a failure anywhere leaves
    // the caller holding exactly what it passed in. Ownership moves only after
    // the last of it has succeeded, which is the instant the crossing becomes
    // certain.
    match write_blob(blob, &listener, &sessions, file) {
        Ok(fd) => {
            // Committed. From here the descriptors belong to the next image, so
            // they must not be closed by this one.
            let _ = listener.into_raw_fd();
            for (_, master, _) in sessions {
                let _ = master.into_raw_fd();
            }
            Ok(fd)
        }
        Err(error) => Err(PackFailed {
            error,
            listener,
            sessions,
        }),
    }
}

/// Writes the header and every replay ring into `file`, and hands back its
/// descriptor rewound and exec-safe. Borrows throughout: see [`pack`].
/// Fault injection for the one path that cannot be reached any other way.
///
/// The claim this whole rollback exists to make — that a blob write failing
/// after `carry_all` costs nothing — is only true if it has been watched
/// happening. A real ENOSPC cannot be arranged inside a test, and the failure
/// is the difference between an upgrade that aborts and one that kills every
/// session on the box, so it is worth a gate to reach. Read once, from the
/// environment of the daemon under test.
const FAIL_AFTER_CARRY: &str = "TERMIOD_HANDOFF_FAIL_AFTER_CARRY";

fn write_blob(
    mut blob: Blob,
    listener: &OwnedFd,
    sessions: &[(CarriedSession, OwnedFd, Vec<Bytes>)],
    mut file: std::fs::File,
) -> Result<OwnedFd> {
    if let Some(setting) = std::env::var_os(FAIL_AFTER_CARRY) {
        // A number holds the failure open that many milliseconds first. The
        // instant failure is enough to prove the rollback, but not to prove
        // anything about what happens *during* a handoff: a second request
        // arriving after the first has already aborted is not a race. Holding
        // the window open is what makes it one.
        if let Some(ms) = setting.to_str().and_then(|value| value.parse::<u64>().ok()) {
            std::thread::sleep(std::time::Duration::from_millis(ms));
        }
        bail!("{FAIL_AFTER_CARRY} is set");
    }
    set_inheritable(listener.as_raw_fd())?;
    blob.listener_fd = listener.as_raw_fd();
    for (info, master, _) in sessions {
        set_inheritable(master.as_raw_fd())?;
        let mut info = info.clone();
        // A descriptor number is stable while something owns it, and these are
        // owned by the caller for the whole of this function — so the header
        // can name them without anything giving up ownership.
        info.master_fd = master.as_raw_fd();
        blob.sessions.push(info);
    }

    let header = serde_json::to_vec(&blob).context("encoding the handoff header")?;
    file.write_all(MAGIC)?;
    file.write_all(&(header.len() as u32).to_le_bytes())?;
    file.write_all(&header)?;
    for (_, _, ring) in sessions {
        for chunk in ring {
            file.write_all(chunk)?;
        }
    }
    file.flush()?;
    // The bytes have to be on the file, not in this process's buffers: the
    // reader is a different program image and shares nothing with this one but
    // the descriptor.
    file.sync_data()
        .context("flushing the handoff blob to disk")?;
    file.seek(SeekFrom::Start(0))?;
    let fd = unsafe { OwnedFd::from_raw_fd(file.into_raw_fd()) };
    set_inheritable(fd.as_raw_fd())?;
    Ok(fd)
}

/// Read back what [`pack`] wrote. Consumes the descriptor: the blob has served
/// its purpose the moment it is in memory, and leaving it open would keep every
/// session's terminal output alive in a file for the daemon's whole life.
pub fn unpack(fd: RawFd) -> Result<(Blob, Vec<Vec<u8>>)> {
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
    let mut magic = [0u8; 8];
    file.read_exact(&mut magic)
        .context("reading the handoff blob")?;
    if &magic != MAGIC {
        bail!("descriptor {fd} does not hold a handoff blob");
    }
    let mut length = [0u8; 4];
    file.read_exact(&mut length)?;
    let mut header = vec![0u8; u32::from_le_bytes(length) as usize];
    file.read_exact(&mut header)?;
    let blob: Blob = serde_json::from_slice(&header).context("decoding the handoff header")?;
    if blob.format != FORMAT_VERSION {
        bail!(
            "the handoff blob is format {} where this build reads {FORMAT_VERSION}",
            blob.format
        );
    }

    let mut rings = Vec::with_capacity(blob.sessions.len());
    for session in &blob.sessions {
        let mut ring = vec![0u8; session.ring_len as usize];
        file.read_exact(&mut ring)
            .with_context(|| format!("reading the replay ring for session {}", session.id))?;
        rings.push(ring);
    }
    Ok((blob, rings))
}

/// A descriptor the new image will need, duplicated so it outlives whatever
/// owns the original and cleared for exec.
///
/// Duplicating rather than leaking the original is what lets the session actor
/// be dropped normally on its way out: its `OwnedFd` closes, this copy stays,
/// and both named the same open file description all along — the same PTY
/// master, at the same offset, with the same termios.
pub fn duplicate_for_exec(fd: RawFd) -> Result<OwnedFd> {
    let copy = unsafe { libc::dup(fd) };
    if copy < 0 {
        bail!(
            "duplicating descriptor {fd}: {}",
            std::io::Error::last_os_error()
        );
    }
    // `dup` already clears `FD_CLOEXEC` on the copy. Set it anyway: the one
    // invariant this whole module rests on should not be an inherited default.
    set_inheritable(copy)?;
    Ok(unsafe { OwnedFd::from_raw_fd(copy) })
}

fn set_inheritable(fd: RawFd) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        bail!("F_GETFD on {fd}: {}", std::io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) } < 0 {
        bail!(
            "clearing FD_CLOEXEC on {fd}: {}",
            std::io::Error::last_os_error()
        );
    }
    Ok(())
}

/// This daemon's own `serve` invocation, with any previous handoff flag taken
/// out. Re-passing the arguments verbatim is what keeps an explicit `--wss` or
/// `--wss-origin` in force across an upgrade; stripping the old `--handoff`
/// keeps the second handoff of a daemon's life from pointing the new image at a
/// descriptor number that meant something two builds ago.
pub fn serve_arguments() -> Vec<std::ffi::OsString> {
    strip_handoff(std::env::args_os().skip(1))
}

fn strip_handoff(arguments: impl Iterator<Item = std::ffi::OsString>) -> Vec<std::ffi::OsString> {
    let prefixed = format!("{HANDOFF_FLAG}=");
    let mut kept = Vec::new();
    let mut arguments = arguments.peekable();
    while let Some(argument) = arguments.next() {
        if argument == HANDOFF_FLAG {
            let _ = arguments.next();
            continue;
        }
        if argument
            .to_str()
            .is_some_and(|text| text.starts_with(&prefixed))
        {
            continue;
        }
        kept.push(argument);
    }
    kept
}

/// Become `binary`. Returns only on failure — success has no return address.
///
/// The caller has already given up every session actor by the time this runs,
/// so a failure here is not recoverable: the PTYs are held by descriptors this
/// process still owns but nothing is left that knows how to read them. The
/// error is for the log and for the exit that follows it.
pub fn exec(binary: &Path, blob_fd: RawFd) -> anyhow::Error {
    use std::os::unix::process::CommandExt;

    let mut command = std::process::Command::new(binary);
    command.args(serve_arguments());
    command.arg(HANDOFF_FLAG).arg(blob_fd.to_string());
    let error = command.exec();
    anyhow::Error::new(error).context(format!("exec {}", binary.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_packed_blob_reads_back_with_its_rings_in_order() {
        let dir = std::env::temp_dir().join(format!("termiod-handoff-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let blob = Blob {
            format: FORMAT_VERSION,
            from_build: "0.1.0+1".to_string(),
            host_id: "h_1".to_string(),
            listener_fd: -1,
            sessions: Vec::new(),
        };
        // Two descriptors that are not ptys but are perfectly good stand-ins
        // for "an owning fd the actor handed over".
        let sessions = vec![
            (session("a", 3), devnull(), vec![Bytes::from_static(b"abc")]),
            (
                session("b", 5),
                devnull(),
                vec![Bytes::from_static(b"de"), Bytes::from_static(b"fgh")],
            ),
        ];
        let file = stage_blob(&dir).unwrap();
        let listener = devnull();
        let listener_number = listener.as_raw_fd();
        let fd = pack(blob, listener, sessions, file).unwrap();
        let (read_back, read_rings) = unpack(fd.into_raw_fd()).unwrap();
        assert_eq!(read_back.listener_fd, listener_number);
        unsafe { libc::close(read_back.listener_fd) };
        assert_eq!(read_back.from_build, "0.1.0+1");
        assert_eq!(read_back.host_id, "h_1");
        assert_eq!(read_rings, vec![b"abc".to_vec(), b"defgh".to_vec()]);
        // The numbers were assigned at pack time, from the descriptors handed
        // over — never the placeholder the caller built the header with.
        for carried in &read_back.sessions {
            assert!(carried.master_fd > 2, "{}", carried.master_fd);
            unsafe { libc::close(carried.master_fd) };
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_previous_handoff_flag_never_reaches_the_next_image() {
        let kept = strip_handoff(
            ["serve", "--handoff", "9", "--wss", "127.0.0.1:8790"]
                .into_iter()
                .map(std::ffi::OsString::from),
        );
        assert_eq!(kept, ["serve", "--wss", "127.0.0.1:8790"]);
        assert_eq!(
            strip_handoff(
                ["serve", "--handoff=9"]
                    .into_iter()
                    .map(std::ffi::OsString::from)
            ),
            ["serve"]
        );
    }

    /// The property the stranded-session path rests on: what a session actor
    /// hands over is *owned*, so a `Carried` nobody takes closes the master
    /// instead of leaking an un-hung-up process into the next image. Only
    /// `pack` gives that ownership up, and only for what reaches the blob.
    #[test]
    fn a_carried_descriptor_that_is_dropped_is_closed() {
        let original = devnull();
        let copy = duplicate_for_exec(original.as_raw_fd()).unwrap();
        let number = copy.as_raw_fd();
        assert!(unsafe { libc::fcntl(number, libc::F_GETFD) } >= 0);
        drop(copy);
        assert!(
            unsafe { libc::fcntl(number, libc::F_GETFD) } < 0,
            "descriptor {number} outlived the Carried that held it"
        );
    }

    fn devnull() -> OwnedFd {
        std::fs::File::open("/dev/null")
            .expect("open /dev/null")
            .into()
    }

    fn session(id: &str, ring_len: u64) -> CarriedSession {
        CarriedSession {
            id: id.to_string(),
            name: id.to_string(),
            cwd: String::new(),
            command: "sh".to_string(),
            pid: 1,
            rows: 24,
            cols: 80,
            created_unix: 0,
            status: "unknown".to_string(),
            title: None,
            workstream: None,
            master_fd: -1,
            ring_len,
            ring_reconstructs_screen: true,
            status_clocks: None,
        }
    }

    /// The blob is written by one build and read by another, so a field added
    /// on one side has to be absent-tolerant on the other. `status_clocks` is
    /// the newest, and this is the shape an older daemon writes.
    #[test]
    fn a_carried_session_without_status_clocks_still_decodes() {
        let older = serde_json::json!({
            "id": "s_1", "name": "s_1", "cwd": "", "command": "sh", "pid": 1,
            "rows": 24, "cols": 80, "created_unix": 0, "status": "working",
            "master_fd": -1, "ring_len": 0,
        });
        let decoded: CarriedSession =
            serde_json::from_value(older).expect("an older blob still crosses");
        assert!(decoded.status_clocks.is_none());
        assert!(!decoded.ring_reconstructs_screen);
    }
}
