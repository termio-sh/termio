//! Where the control socket lives.
//!
//! Prefer `$XDG_RUNTIME_DIR/termiod/` (per-user, tmpfs, auto-cleaned on
//! logout). Fall back to a uid-scoped dir under the system temp dir. Either
//! way the directory is created 0700 so no other user can connect.

use crate::id::SessionId;
use anyhow::{bail, Context, Result};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// `"-dev"` for a side-by-side dev build, `""` for a release one.
///
/// Mirrors `AppChannel.suffix` in the app, and must keep mirroring it: the two
/// derive it separately and a disagreement puts them on different sockets. Only
/// a plain name becomes a path component, so a typo in `TERMIO_CHANNEL` falls
/// back to the release channel instead of opening a stray directory. The app
/// reads its channel off its bundle identifier, which a spawned binary cannot
/// see, so whoever starts the daemon has to say which channel it serves.
pub fn channel_suffix() -> String {
    let requested = std::env::var("TERMIO_CHANNEL")
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if requested.is_empty() || requested == "release" {
        return String::new();
    }
    if requested
        .chars()
        .all(|character| character.is_alphanumeric() || character == '-')
    {
        return format!("-{requested}");
    }
    String::new()
}

/// Directory holding the socket (and, later, logs / pid files).
///
/// Scoped by channel as well as by user. The socket is the rendezvous for a
/// whole session table, so sharing one between the release app and a dev build
/// beside it makes them one device: each is handed the other's entire roster,
/// draws every row of it as a session nothing accounts for, and can kill it.
/// Whether the caller pinned its own socket — the axis every "beside the
/// socket or not" decision in this file turns on. Empty counts as unset.
fn socket_is_pinned() -> bool {
    std::env::var_os("TERMIOD_SOCK").is_some_and(|value| !value.is_empty())
}

pub fn runtime_dir() -> Result<PathBuf> {
    let suffix = channel_suffix();
    let base = if let Some(xdg) = std::env::var_os("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg).join(format!("termiod{suffix}"))
    } else {
        let uid = unsafe { libc::getuid() };
        std::env::temp_dir().join(format!("termiod-{uid}{suffix}"))
    };
    Ok(base)
}

/// Where the daemon writes its own diagnostics.
///
/// Deliberately **not** under `runtime_dir()` in the ordinary case: that lives in
/// `$TMPDIR`, which the OS may sweep, and a log whose whole purpose is to explain
/// a crash that happened yesterday has to outlive the socket beside it. On macOS
/// that means `~/Library/Logs`, the directory Console.app opens and the one place
/// a user can be told to look without being handed a path. Elsewhere it is
/// `$XDG_STATE_HOME/termio{suffix}`, which is already the path
/// `RemoteTunnelPaths.daemonLog` names for a published Linux box.
///
/// An explicit `TERMIOD_SOCK` overrides that and puts the log beside the socket,
/// the same rule `durable_state_dir` follows: a daemon pointed at its own socket
/// is its own daemon, and its files must not land on the real one's. Without this the test suite — which gives each daemon
/// a temp socket but no channel — appends its runs to the installed app's log.
/// That is the same accident `AppChannel.isRunningTests` exists to prevent on the
/// Swift side, where it once overwrote a real user's session tree.
///
/// `TERMIOD_LOG` names the file outright, for tests and for anyone who wants it
/// somewhere else.
pub fn log_path() -> Result<PathBuf> {
    if let Some(explicit) = std::env::var_os("TERMIOD_LOG") {
        return Ok(PathBuf::from(explicit));
    }
    if socket_is_pinned() {
        return Ok(state_dir()?.join("termiod.log"));
    }
    durable_log_dir(&channel_suffix())?.map_or_else(
        || state_dir().map(|dir| dir.join("termiod.log")),
        |dir| Ok(dir.join("termiod.log")),
    )
}

/// The per-user log directory for a channel, or `None` when there is no home to
/// hang it off — in which case the caller falls back beside the socket rather
/// than failing to start over a log file.
fn durable_log_dir(suffix: &str) -> Result<Option<PathBuf>> {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return Ok(None);
    };
    let directory = if cfg!(target_os = "macos") {
        home.join("Library").join("Logs").join(format!("termio{suffix}"))
    } else if let Some(state) = std::env::var_os("XDG_STATE_HOME") {
        PathBuf::from(state).join(format!("termio{suffix}"))
    } else {
        home.join(".local").join("state").join(format!("termio{suffix}"))
    };
    Ok(Some(directory))
}

/// Full path to the control socket. Overridable with `TERMIOD_SOCK` so tests
/// (and side-by-side daemons) can isolate.
/// Claims the exclusive right to serve this channel's socket. The returned
/// file *is* the claim — hold it for the daemon's life; dropping it (or the
/// process ending, however it ends) releases it.
pub fn acquire_serve_lock() -> Result<std::fs::File> {
    // Beside the socket, not in `runtime_dir()`: a `TERMIOD_SOCK` override
    // moves the socket, and a lock guarding a different directory would
    // serialize nothing.
    let dir = state_dir()?;
    let _ = std::fs::create_dir_all(&dir);
    flock_exclusive(&dir.join("termiod.lock"))
}

fn flock_exclusive(path: &std::path::Path) -> Result<std::fs::File> {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(path)
        .with_context(|| format!("opening {}", path.display()))?;
    let taken = unsafe {
        libc::flock(
            std::os::fd::AsRawFd::as_raw_fd(&file),
            libc::LOCK_EX | libc::LOCK_NB,
        )
    };
    if taken != 0 {
        bail!(
            "another termiod is starting or serving this channel (lock held at {})",
            path.display()
        );
    }
    Ok(file)
}

pub fn socket_path() -> Result<PathBuf> {
    // An empty value is unset, not a socket in the current directory — the
    // Swift mirror (`Termiod.socketPath`) already reads it that way, and the
    // two sides deriving different sockets from one environment is the drift
    // this file exists to prevent.
    if let Some(explicit) = std::env::var_os("TERMIOD_SOCK").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(explicit));
    }
    Ok(runtime_dir()?.join("termiod.sock"))
}

/// The directory the *configured* socket lives in — which is not always
/// `runtime_dir()`, because `TERMIOD_SOCK` may point anywhere. Everything with
/// the socket's lifetime hangs off this: the serve lock, session scratch, the
/// handoff blob. What must outlive the socket — identity, pairing secret,
/// graveyard — hangs off `durable_state_dir` instead.
pub fn state_dir() -> Result<PathBuf> {
    Ok(socket_path()?
        .parent()
        .map(|path| path.to_path_buf())
        .unwrap_or_else(|| PathBuf::from(".")))
}

/// Durable per-daemon state: identity, pairing secret, WSS bind, graveyard.
///
/// **Not** beside the socket, unlike everything above. On Linux the canonical
/// socket lives in `$XDG_RUNTIME_DIR`, a tmpfs a reboot empties — and the first
/// reboot drill renamed a fifteen-week-old box and silently disarmed its WSS
/// listener, because identity, secret and graveyard were all riding the
/// socket's lifetime. sshd survives the same reboot because its host keys live
/// in `/etc/ssh`; this is that split, per user: files with the socket's
/// lifetime stay in `state_dir`, files with the *host's* lifetime live here,
/// in the directory the log already proved durable (macOS: `Application
/// Support`, where state belongs rather than `Logs`).
///
/// An explicit `TERMIOD_SOCK` keeps everything beside the socket — a daemon
/// pointed at its own socket is its own daemon, and its identity must not land
/// on the real one's. No `$HOME` falls back the same way rather than refusing
/// to start.
pub fn durable_state_dir() -> Result<PathBuf> {
    if socket_is_pinned() {
        return state_dir();
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return state_dir();
    };
    let dir = durable_state_base(&home, std::env::var_os("XDG_STATE_HOME"), &channel_suffix());
    if !dir.exists() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .with_context(|| format!("creating state dir {}", dir.display()))?;
    }
    Ok(dir)
}

fn durable_state_base(home: &Path, xdg_state: Option<std::ffi::OsString>, suffix: &str) -> PathBuf {
    if cfg!(target_os = "macos") {
        home.join("Library")
            .join("Application Support")
            .join(format!("termio{suffix}"))
    } else if let Some(state) = xdg_state.filter(|value| !value.is_empty()) {
        PathBuf::from(state).join(format!("termio{suffix}"))
    } else {
        home.join(".local").join("state").join(format!("termio{suffix}"))
    }
}

/// Bring the files an older daemon kept beside the socket into the durable
/// dir — at startup, before anything reads them, so an upgrade keeps the
/// identity and the token the box already has. Copy then remove rather than
/// rename: `/run` and `$HOME` are different filesystems. Best-effort per
/// file; one that cannot move is left where the next start can try again.
pub fn adopt_runtime_state() {
    for name in [
        "host.id",
        "pair.token",
        "wss.bind",
        "wss.origin",
        "tombstones.json",
        "roster.json",
    ] {
        adopt_runtime_file(name);
    }
}

fn adopt_runtime_file(name: &str) {
    let (Ok(legacy_dir), Ok(durable)) = (state_dir(), durable_state_dir()) else {
        return;
    };
    if legacy_dir == durable {
        return;
    }
    // Adoption's decision (legacy present, target absent) and `--wss-off`'s
    // deletion must not interleave: an adopter that read the legacy bind
    // before the deletion would publish it *after*, resurrecting the listener
    // the operator just turned off. Both sides serialize on the same flock;
    // losing the lock file falls back to unlocked best effort, which is the
    // pre-lock behaviour, not a new failure mode.
    let _lock = adoption_lock(&durable);
    let legacy = legacy_dir.join(name);
    let target = durable.join(name);
    if target.exists() || !legacy.exists() {
        return;
    }
    let Ok(contents) = std::fs::read(&legacy) else {
        return;
    };
    // Staged under a name unique to this adopter, then published with
    // `hard_link`, which refuses an existing target. Both halves matter. A
    // shared staged name lets two concurrent adopters (`serve()` and a
    // client's lazy read) unlink each other's staging and `rename` would then
    // publish whatever half-written file the *pathname* resolves to. And
    // `rename` replaces, so even unique staging could clobber a finished
    // target with a slower copy. With link-as-publish the durable file only
    // ever appears complete, and losing the race is success: the winner's
    // file is whole, because only whole files get published.
    static ADOPTING: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let staged = durable.join(format!(
        "{name}.adopting.{}.{}",
        std::process::id(),
        ADOPTING.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    // A leftover under this exact name is a crashed adopter on a since-reused
    // pid — ours to clear, and no live adopter's, since live pids are unique.
    let _ = std::fs::remove_file(&staged);
    let staged_written = (|| -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&staged)?;
        file.write_all(&contents)?;
        file.sync_all()
    })();
    // `AlreadyExists` means "another adopter published a complete file" only
    // when it comes from the link itself and the target is really there —
    // conflating a staging failure with it would delete the legacy original
    // without anything ever having been published.
    let published = staged_written.and_then(|()| std::fs::hard_link(&staged, &target));
    let _ = std::fs::remove_file(&staged);
    match published {
        Ok(()) => {
            let _ = std::fs::remove_file(&legacy);
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists && target.exists() => {
            let _ = std::fs::remove_file(&legacy);
        }
        Err(_) => {}
    }
}

/// Stable host identity. Durable on purpose: a host id that changes on every
/// reboot is not an identity, and every pairing invite embeds it.
pub fn host_id_path() -> Result<PathBuf> {
    Ok(durable_state_dir()?.join("host.id"))
}

/// The persisted host identity, if any — for read-only callers (`status`).
/// Only the daemon mints one.
pub fn stored_host_id() -> Option<String> {
    adopt_runtime_file("host.id");
    read_host_id(&host_id_path().ok()?).ok()
}

/// The pairing secret that authenticates a WebSocket pipe — never the session
/// write token, which arbitrates who may type into a PTY. Beside `host.id`
/// because two daemons on two sockets must not share a secret, and durable
/// because losing it disarms the listener until the phone re-pairs.
pub fn pair_token_path() -> Result<PathBuf> {
    Ok(durable_state_dir()?.join("pair.token"))
}

/// The durable WSS bind, so a crash restart, a reboot, or a `spawn_daemon`
/// child that execs bare `termiod serve` keeps listening.
pub fn wss_bind_path() -> Result<PathBuf> {
    Ok(durable_state_dir()?.join("wss.bind"))
}

/// The durable allowed origin. Not in the web-client RFC's file table, but
/// `pair --qr` runs in a different process from the daemon and the listener
/// binds loopback by design, so without this the reachable name is knowable
/// only to whoever typed the daemon's argv.
pub fn wss_origin_path() -> Result<PathBuf> {
    Ok(durable_state_dir()?.join("wss.origin"))
}

/// 24 random bytes as base64url. No padding: 24 is a multiple of 3.
fn encode_base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        let symbols = match chunk.len() {
            1 => 2,
            2 => 3,
            _ => 4,
        };
        for index in 0..symbols {
            let sextet = (triple >> (18 - 6 * index)) & 0x3f;
            out.push(ALPHABET[sextet as usize] as char);
        }
    }
    out
}

fn random_bytes(count: usize) -> Result<Vec<u8>> {
    let mut buffer = vec![0u8; count];
    std::fs::File::open("/dev/urandom")
        .context("opening OS random source")?
        .read_exact(&mut buffer)
        .context("reading OS random source")?;
    Ok(buffer)
}

/// Create a 0600 file that must not already exist.
fn write_new_secret(path: &std::path::Path, value: &str) -> Result<()> {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("writing {}", path.display()))?;
    file.write_all(value.as_bytes())
        .with_context(|| format!("writing {}", path.display()))?;
    file.sync_all()
        .with_context(|| format!("syncing {}", path.display()))?;
    Ok(())
}

/// Whether a failure is "the file was already there" rather than a real IO
/// fault. The context layers `publish_new_secret` adds are transparent to
/// `downcast_ref`, so the original `io::Error` is still the one asked.
fn is_already_exists(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<std::io::Error>()
        .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists)
}

/// Create a 0600 file that must not already exist, publishing it atomically.
///
/// `write_new_secret` alone is not enough for a file other processes read by
/// name. `create_new` publishes the name before the contents, so a concurrent
/// reader that opens it in between finds it empty — which `read_pair_token`
/// rejects, correctly, as an empty secret. Two `termiod pair` invocations
/// racing each other is exactly that: one mints while the other reads.
///
/// Staging the contents and publishing them with `link` closes the window. The
/// name appears already complete, and `link` refuses to replace an existing
/// file, so the loser of a minting race still gets `AlreadyExists` and can read
/// the winner's token — the contract `load_or_create_pair_token` depends on,
/// and the reason this is not a `rename`.
fn publish_new_secret(path: &std::path::Path, value: &str) -> Result<()> {
    // Named for this process, because the racing writer is another `pair` with
    // the same idea. A shared staging name would have them overwrite each
    // other's contents before either published.
    let staged = path.with_file_name(format!(
        "{}.{}.staged",
        path.file_name().unwrap_or_default().to_string_lossy(),
        std::process::id()
    ));
    let _ = std::fs::remove_file(&staged);
    write_new_secret(&staged, value)?;
    let published = std::fs::hard_link(&staged, path);
    let _ = std::fs::remove_file(&staged);
    published.with_context(|| format!("publishing {}", path.display()))
}

/// Replace a 0600 file through a rename, so a concurrent reader sees either the
/// old value or the new one and never a truncated file.
pub fn replace_secret(path: &std::path::Path, value: &str) -> Result<()> {
    let staged = path.with_extension("staged");
    let _ = std::fs::remove_file(&staged);
    write_new_secret(&staged, value)?;
    std::fs::rename(&staged, path)
        .with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

/// The current pairing token, or `None` when the file is absent. Reading is
/// separate from minting on purpose: `serve --wss` must never mint one, or an
/// operator who forgot to pair gets a listener with a secret nobody has seen.
pub fn read_pair_token() -> Result<Option<String>> {
    adopt_runtime_file("pair.token");
    let path = pair_token_path()?;
    match std::fs::read_to_string(&path) {
        Ok(contents) => {
            let token = contents.trim().to_string();
            if token.is_empty() {
                bail!("empty pairing token in {}", path.display());
            }
            Ok(Some(token))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

/// Read the pairing token, minting one on first use. Only `termiod pair` calls
/// this.
pub fn load_or_create_pair_token() -> Result<String> {
    if let Some(existing) = read_pair_token()? {
        return Ok(existing);
    }
    let token = encode_base64url(&random_bytes(24)?);
    let path = pair_token_path()?;
    match publish_new_secret(&path, &token) {
        Ok(()) => Ok(token),
        // Another `pair` won the race; its token is the one on disk, and it was
        // published whole, so reading it back cannot see a half-written secret.
        //
        // Only that one failure is recoverable. Testing `path.exists()` alone
        // would also swallow a full disk or a read-only state dir and answer
        // with whatever happens to sit at the path, so the error has to say
        // `AlreadyExists` — which, now that the contents are staged, only the
        // publishing link can raise.
        Err(error) if is_already_exists(&error) => read_pair_token()?
            .ok_or_else(|| anyhow::anyhow!("pairing token vanished during minting")),
        Err(error) => Err(error),
    }
}

/// Replace the pairing token. The only revocation there is: a live daemon
/// drops every spliced socket, and anything holding the old secret is out.
pub fn rotate_pair_token() -> Result<String> {
    let token = encode_base64url(&random_bytes(24)?);
    replace_secret(&pair_token_path()?, &token)?;
    // Rotation is revocation, and the legacy copy beside the socket is still a
    // live credential: a pre-split daemon reads it per handshake, and it would
    // keep admitting the old secret until a restart while `--rotate` reports
    // everyone signed out. Removing it is part of the rotation, not cleanup.
    remove_legacy_runtime_file("pair.token");
    Ok(token)
}

/// Best-effort removal of the copy an older daemon kept beside the socket.
/// Only for writers that must not leave a stale twin behind (`--rotate`,
/// `--wss-off`); readers go through adoption instead.
fn remove_legacy_runtime_file(name: &str) {
    let (Ok(legacy_dir), Ok(durable)) = (state_dir(), durable_state_dir()) else {
        return;
    };
    if legacy_dir == durable {
        return;
    }
    let _ = std::fs::remove_file(legacy_dir.join(name));
}

/// The flock every adopter and every legacy-removing writer holds while it
/// decides. The file itself is meaningless; only the lock matters, so it is
/// created on demand in the durable dir and never removed. `None` (no durable
/// dir, or flock failing) degrades to the unlocked behaviour.
fn adoption_lock(durable: &Path) -> Option<std::fs::File> {
    use std::os::fd::AsRawFd;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(durable.join(".adopt.lock"))
        .ok()?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return None;
    }
    Some(file)
}

/// Disarm the WSS listener durably: both the durable bind and any legacy copy
/// beside the socket go. Removing only the durable file re-armed the listener
/// on the next daemon start, because startup adoption dutifully promoted the
/// legacy bind the operator thought they had turned off. Holding the adoption
/// lock closes the other resurrection path: an adopter that read the legacy
/// bind before this deletion but would have published it after.
pub fn remove_wss_bind() -> Result<()> {
    let lock_dir = durable_state_dir()?;
    let _lock = adoption_lock(&lock_dir);
    let path = wss_bind_path()?;
    match std::fs::remove_file(&path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).with_context(|| format!("removing {}", path.display())),
    }
    remove_legacy_runtime_file("wss.bind");
    Ok(())
}

/// Root of the per-session upload scratch dirs (§C.12 `temp:` dests). Lives
/// beside the socket for the same reason as the graveyard: two daemons on two
/// sockets must not share scratch space.
pub fn scratch_root() -> Result<PathBuf> {
    Ok(state_dir()?.join("scratch"))
}

/// One session's scratch dir, created 0700 on first use and reaped with the
/// session.
pub fn session_scratch_dir(session_id: &SessionId) -> Result<PathBuf> {
    let dir = scratch_root()?.join(format!("session-{session_id}"));
    if !dir.exists() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .with_context(|| format!("creating scratch dir {}", dir.display()))?;
    }
    Ok(dir)
}

fn read_host_id(path: &std::path::Path) -> Result<String> {
    let id = std::fs::read_to_string(path)
        .with_context(|| format!("reading host id {}", path.display()))?
        .trim()
        .to_string();
    if id.len() != 34
        || !id.starts_with("h_")
        || !id[2..].bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        bail!("invalid host id in {}", path.display());
    }
    Ok(id)
}

/// Load the daemon's stable random 128-bit identity, minting it on first run.
pub fn load_or_create_host_id() -> Result<String> {
    adopt_runtime_file("host.id");
    let path = host_id_path()?;
    if path.exists() {
        return read_host_id(&path);
    }

    let mut random = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .context("opening OS random source")?
        .read_exact(&mut random)
        .context("reading OS random source")?;
    let id = format!(
        "h_{}",
        random
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    );

    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
    {
        Ok(mut file) => {
            file.write_all(id.as_bytes())
                .with_context(|| format!("writing host id {}", path.display()))?;
            file.sync_all()
                .with_context(|| format!("syncing host id {}", path.display()))?;
            Ok(id)
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => read_host_id(&path),
        Err(error) => Err(error).with_context(|| format!("creating host id {}", path.display())),
    }
}

/// Create the runtime dir with 0700 permissions if it does not exist.
pub fn ensure_runtime_dir() -> Result<PathBuf> {
    let dir = if socket_is_pinned() {
        state_dir()?
    } else {
        runtime_dir()?
    };
    if !dir.exists() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .with_context(|| format!("creating runtime dir {}", dir.display()))?;
    }
    Ok(dir)
}

#[cfg(test)]
mod serve_lock_tests {
    #[test]
    fn the_serve_lock_is_exclusive_and_released_on_drop() {
        let path = std::env::temp_dir().join(format!(
            "termiod-lock-test-{}",
            std::process::id()
        ));
        let held = super::flock_exclusive(&path).expect("first claim");
        assert!(super::flock_exclusive(&path).is_err(), "second claim must fail");
        drop(held);
        // Not instantaneous, and not this lock's fault: `flock` follows the open
        // file *description*, and a sibling test spawning a session forks this
        // very binary — the child holds every descriptor the parent had until
        // its `execvp` runs and `O_CLOEXEC` shuts them. A reclaim landing inside
        // that window sees the lock still held by a process that is microseconds
        // from dropping it. The retry says "released", which is what this test
        // is about, without asserting a scheduling guarantee nothing offers.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let reclaimed = loop {
            match super::flock_exclusive(&path) {
                Ok(file) => break Some(file),
                Err(_) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
                Err(_) => break None,
            }
        };
        assert!(reclaimed.is_some(), "claim after release");
        let _ = std::fs::remove_file(&path);
    }
}

#[cfg(test)]
mod tests {
    use super::{durable_state_base, is_already_exists, publish_new_secret};
    use std::path::Path;

    /// Losing the minting race is recoverable; a full disk is not. Both arrive
    /// as an `Err` from the same call, so only the kind separates them — and
    /// answering a write fault with whatever sits at the path would hand back
    /// someone else's file as this host's pairing token.
    #[test]
    fn only_a_lost_race_counts_as_already_existing() {
        let directory =
            std::env::temp_dir().join(format!("termiod-mint-kind-{}", std::process::id()));
        std::fs::create_dir_all(&directory).expect("test directory");
        let path = directory.join("pair.token");
        let _ = std::fs::remove_file(&path);

        publish_new_secret(&path, "first").expect("first mint");
        let lost_race = publish_new_secret(&path, "second").expect_err("second mint");
        assert!(
            is_already_exists(&lost_race),
            "a lost minting race was not recognised: {lost_race:#}"
        );

        // A write that cannot happen at all must not read as a lost race.
        let missing = directory.join("absent").join("pair.token");
        let fault = publish_new_secret(&missing, "third").expect_err("mint into a missing dir");
        assert!(
            !is_already_exists(&fault),
            "an IO fault was mistaken for a lost race: {fault:#}"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    /// A secret is published whole or not at all. `create_new` followed by a
    /// write leaves the name visible and empty in between, and a reader that
    /// lands there — a second `termiod pair`, which is what
    /// `wss_off_wins_against_a_concurrent_adopter` runs — rejects it as an
    /// empty pairing token.
    #[test]
    fn a_minted_secret_is_never_visible_empty() {
        const TOKEN: &str = "a-token-nobody-should-see-half-of";
        let directory =
            std::env::temp_dir().join(format!("termiod-mint-race-{}", std::process::id()));
        std::fs::create_dir_all(&directory).expect("test directory");
        let path = directory.join("pair.token");

        for round in 0..500 {
            let _ = std::fs::remove_file(&path);
            let target = path.clone();
            let writer = std::thread::spawn(move || publish_new_secret(&target, TOKEN));
            // Spin until the name exists, then judge what it held the instant
            // it appeared. An empty read here is the defect.
            loop {
                match std::fs::read_to_string(&path) {
                    Ok(contents) => {
                        assert_eq!(
                            contents, TOKEN,
                            "round {round}: a reader saw a partially written secret"
                        );
                        break;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => panic!("round {round}: reading the secret: {error}"),
                }
            }
            writer.join().expect("writer thread").expect("publishing");
        }

        // The staging copy is not left behind to be mistaken for a credential.
        let strays: Vec<_> = std::fs::read_dir(&directory)
            .expect("listing the test directory")
            .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
            .filter(|name| name.to_string_lossy().ends_with(".staged"))
            .collect();
        assert!(strays.is_empty(), "staging copies survived: {strays:?}");

        let _ = std::fs::remove_dir_all(&directory);
    }

    /// Minting must still refuse to replace a token another process published,
    /// or the loser of the race overwrites the winner's secret and the two
    /// disagree about what the pairing token is.
    #[test]
    fn minting_never_replaces_an_existing_secret() {
        let directory =
            std::env::temp_dir().join(format!("termiod-mint-exclusive-{}", std::process::id()));
        std::fs::create_dir_all(&directory).expect("test directory");
        let path = directory.join("pair.token");
        let _ = std::fs::remove_file(&path);

        publish_new_secret(&path, "first").expect("first mint");
        let second = publish_new_secret(&path, "second");
        assert!(second.is_err(), "minting replaced an existing secret");
        assert_eq!(
            std::fs::read_to_string(&path).expect("reading the secret"),
            "first",
            "the loser of a minting race overwrote the winner's token"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    /// One durable dir per channel, or the dev daemon's identity overwrites the
    /// release one's — the same two-axis scoping the socket and the unit have.
    #[test]
    fn durable_state_is_scoped_by_channel() {
        let home = Path::new("/home/u");
        let release = durable_state_base(home, None, "");
        let dev = durable_state_base(home, None, "-dev");
        assert_ne!(release, dev);
        assert!(dev.to_string_lossy().ends_with("termio-dev"), "{dev:?}");
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn xdg_state_home_outranks_the_default() {
        let dir = durable_state_base(Path::new("/home/u"), Some("/var/state".into()), "");
        assert_eq!(dir, Path::new("/var/state/termio"));
        let fallback = durable_state_base(Path::new("/home/u"), None, "");
        assert_eq!(fallback, Path::new("/home/u/.local/state/termio"));
        // An empty variable is unset, not a root-relative state dir.
        let empty = durable_state_base(Path::new("/home/u"), Some("".into()), "");
        assert_eq!(empty, fallback);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_state_lives_in_application_support() {
        let dir = durable_state_base(Path::new("/Users/u"), None, "");
        assert_eq!(dir, Path::new("/Users/u/Library/Application Support/termio"));
    }
}
