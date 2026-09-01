//! The daemon: a session table plus a Unix-socket accept loop. Connections
//! speak Session Protocol v0.1, with a transparent legacy-v0 first-message
//! fallback.

use crate::paths;
use crate::protocol::{
    encode_file_chunk, read_frame, write_control, write_data, write_event, write_file_payload,
    write_grid_payload, write_history_payload, write_snapshot, AttachMode, Control, ErrorCode,
    Event, FileChunk, Frame, SessionInfo, Snapshot, FILE_CHUNK_HEADER_SIZE, HOST_CAPABILITIES,
    MAX_FILE_FRAME_SIZE, PROTOCOL_VERSION, SUPPORTED_PROTOCOLS,
};
use crate::id::{ClientId, SessionId};
use crate::resource::Registry;
use crate::session::{
    self, ClientBacklog, ClientEvent, Metered, SessionEnded, SessionHandle, SessionMsg,
};
use crate::tombstone::{EndReason, Graveyard};
use anyhow::{Context, Result};
use bytes::Bytes;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, oneshot, watch, Notify};

const EVENT_BUFFER: usize = 1024;
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a handoff waits for its own `ok` to reach the requesting socket
/// before exec'ing anyway.
const HANDOFF_FLUSH_TIMEOUT: Duration = Duration::from_secs(2);

struct ManagerInner {
    sessions: HashMap<SessionId, SessionHandle>,
    id_counter: u32,
    draining: bool,
    /// Whether a handoff has been accepted and not yet finished. Nothing
    /// serialised them before: two clients asking at once both got `ok`, both
    /// requests reached the accept loop, and the second carried a roster the
    /// first had already emptied. One at a time, and the loser is told so.
    handing_off: bool,
}

#[derive(Clone)]
pub struct Manager {
    inner: Arc<Mutex<ManagerInner>>,
    next_client_id: Arc<AtomicU64>,
    on_exit: mpsc::UnboundedSender<SessionEnded>,
    events: broadcast::Sender<Event>,
    host_id: Arc<String>,
    /// Durable non-session state clients can resume against (§C.10). Shared by
    /// every connection so one workspace costs one watcher, not one per client.
    resources: Registry,
    /// In-flight uploads (§C.12). Daemon-wide, not per-connection, so a client
    /// that reconnects mid-upload can idempotently re-open its transfer.
    uploads: crate::files::Uploads,
    /// What died and why (§6). The daemon is now the only PTY owner, so its own
    /// death has to leave evidence — an empty session list otherwise reads as
    /// "nothing was running" rather than "everything was lost".
    graveyard: Arc<Graveyard>,
    session_removed: Arc<Notify>,
    /// Where a `handoff` request goes. The accept loop owns the listener and
    /// the runtime, so replacing the image is its move to make; a connection
    /// task only vets the request and passes it along.
    handoff: mpsc::UnboundedSender<std::path::PathBuf>,
    /// Slots for `fs.search` walks (§C.12). Daemon-wide: the thing being
    /// rationed is the blocking pool, and every connection draws on the same
    /// one.
    searching: Arc<tokio::sync::Semaphore>,
}

/// How many `fs.search` walks may run at once.
///
/// A walk owns a blocking thread for as long as it takes to cross a tree, so
/// this is a queue *in front of* tokio's blocking pool rather than a share of
/// it. Unbounded, a handful of large searches fill the pool, and the next
/// search sits in it holding a slot it cannot use — including the cancel flag
/// it exists to notice, which is how an abandoned query turns into a client
/// waiting out its idle bound. Sized to the machine, floored at two so a second
/// query is never stuck behind the first, and capped because more concurrent
/// tree walks than cores buys contention rather than answers.
fn search_permits() -> usize {
    std::thread::available_parallelism()
        .map(|cores| cores.get())
        .unwrap_or(2)
        .clamp(2, 8)
}

impl Manager {
    fn new(
        on_exit: mpsc::UnboundedSender<SessionEnded>,
        host_id: String,
        graveyard: Arc<Graveyard>,
        handoff: mpsc::UnboundedSender<std::path::PathBuf>,
    ) -> Manager {
        let (events, _) = broadcast::channel(EVENT_BUFFER);
        Manager {
            inner: Arc::new(Mutex::new(ManagerInner {
                sessions: HashMap::new(),
                id_counter: 0,
                draining: false,
            handing_off: false,
            })),
            next_client_id: Arc::new(AtomicU64::new(1)),
            on_exit,
            events,
            host_id: Arc::new(host_id),
            resources: Registry::new(),
            uploads: crate::files::Uploads::new(),
            graveyard,
            session_removed: Arc::new(Notify::new()),
            handoff,
            searching: Arc::new(tokio::sync::Semaphore::new(search_permits())),
        }
    }

    /// Ask every session for its PTY, so an `execve` can carry them.
    ///
    /// Sequential rather than concurrent, and bounded: a session that does not
    /// answer within `handoff::CARRY_TIMEOUT` is left out of the blob and
    /// returned as stranded. It loses its PTY at the exec, and naming it in the
    /// log is the difference between an upgrade with a known cost and an
    /// upgrade that quietly ate someone's work.
    async fn carry_all(&self) -> (Vec<session::Carried>, Vec<String>) {
        let handles: Vec<SessionHandle> = {
            let mut guard = self.inner.lock().unwrap();
            // Nothing new may start once the PTYs are being handed over: a
            // session spawned after this point has no descriptor in the blob.
            guard.draining = true;
            guard.sessions.values().cloned().collect()
        };
        let mut carried = Vec::new();
        let mut stranded = Vec::new();
        for handle in handles {
            let (reply_tx, reply_rx) = oneshot::channel();
            if !handle.send(SessionMsg::Carry { reply: reply_tx }) {
                stranded.push(handle.id.to_string());
                continue;
            }
            match tokio::time::timeout(crate::handoff::CARRY_TIMEOUT, reply_rx).await {
                Ok(Ok(one)) => carried.push(one),
                _ => stranded.push(handle.id.to_string()),
            }
        }
        (carried, stranded)
    }

    fn alloc_client_id(&self) -> ClientId {
        let id = self.next_client_id.fetch_add(1, Ordering::Relaxed);
        ClientId::new(format!("c_{id:x}"))
    }

    fn create(&self, spec: crate::protocol::CreateSpec) -> Result<SessionId> {
        // The lock makes the transition to draining an exact boundary: a
        // create either installs its handle before the shutdown snapshot or
        // observes `draining` and never spawns a child.
        let mut guard = self.inner.lock().unwrap();
        if guard.draining {
            anyhow::bail!("daemon is draining");
        }
        let seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        guard.id_counter = guard.id_counter.wrapping_add(1);
        let id = SessionId::new(format!(
            "{:08x}",
            seed ^ guard.id_counter.wrapping_mul(2654435761)
        ));
        let name = spec.name.clone().unwrap_or_else(|| id.to_string());
        let cwd = spec.cwd.clone().unwrap_or_default();
        let command = if spec.argv.is_empty() {
            format!(
                "{} (login shell)",
                std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into())
            )
        } else {
            spec.argv.join(" ")
        };
        let handle = session::spawn(
            id.clone(),
            name,
            cwd,
            command,
            spec.argv,
            spec.env,
            spec.rows,
            spec.cols,
            spec.workstream,
            self.on_exit.clone(),
            self.events.clone(),
        )
        .context("spawning session")?;
        guard.sessions.insert(id.clone(), handle);
        Ok(id)
    }

    /// Install a session that crossed a handoff. Not a `create`: nothing is
    /// spawned, no id is minted, and the roster entry the previous daemon wrote
    /// is already correct — this session never stopped being alive.
    fn adopt(&self, carried: crate::handoff::CarriedSession, ring: Vec<u8>) -> Result<()> {
        let id = SessionId::new(carried.id.clone());
        let handle = session::adopt(carried, ring, self.on_exit.clone(), self.events.clone())
            .context("adopting session")?;
        self.inner.lock().unwrap().sessions.insert(id, handle);
        Ok(())
    }

    /// Put carried sessions back and start serving them again.
    ///
    /// The undo half of `carry_all`. A session that has handed over its PTY
    /// exists only as a descriptor and a replay ring, and `adopt` is already the
    /// code that turns exactly that back into a running session — it is what the
    /// *new* image does on the other side of a successful exec. An aborted
    /// handoff is the same problem with the same answer, so it uses the same
    /// path rather than a second one written for failures only.
    ///
    /// A session that cannot be adopted back is genuinely lost, and is named:
    /// its descriptor closes with the `OwnedFd` and its child takes SIGHUP.
    fn restore(
        &self,
        sessions: Vec<(crate::handoff::CarriedSession, std::os::fd::OwnedFd, Vec<Bytes>)>,
    ) -> Vec<String> {
        use std::os::fd::IntoRawFd;
        let mut lost = Vec::new();
        for (mut info, master, ring) in sessions {
            let id = info.id.clone();
            let mut bytes = Vec::new();
            for chunk in &ring {
                bytes.extend_from_slice(chunk);
            }
            // Ownership goes before the call, not after it succeeds.
            // `Pty::adopt` wraps the number in an `OwnedFd` the instant it is
            // entered and closes it itself if any of its own steps fail — so
            // holding on here to close it on the error path would close the
            // descriptor twice. By the second close the number can already have
            // been handed to something else, and what dies is whatever that is:
            // another session's master, the listener, a client's socket.
            info.master_fd = master.into_raw_fd();
            if let Err(error) = self.adopt(info, bytes) {
                eprintln!("termiod: session {id} could not be put back: {error:#}");
                lost.push(id);
            }
        }
        // Only once every session is installed again: a create that slipped in
        // before this point would have been spawned into a daemon that was
        // still handing over. The handoff claim goes with it — this attempt is
        // over, and the next one is allowed to try.
        self.inner.lock().unwrap().draining = false;
        lost
    }

    /// Claims the right to hand over, or reports who already has it. Released
    /// by `restore`, which is the end of every attempt that comes back.
    fn begin_handoff(&self) -> bool {
        let mut guard = self.inner.lock().unwrap();
        if guard.handing_off {
            return false;
        }
        guard.handing_off = true;
        true
    }

    /// Gives the claim back. Called where every attempt that comes back
    /// converges — not in `restore`, which the early failures never reach: they
    /// fail before anything is carried, and latching the gate on those would
    /// mean one unreadable state directory blocked every upgrade until restart.
    fn end_handoff(&self) {
        self.inner.lock().unwrap().handing_off = false;
    }

    fn find(&self, id: &SessionId) -> Option<SessionHandle> {
        self.inner.lock().unwrap().sessions.get(id).cloned()
    }

    fn handles(&self) -> Vec<SessionHandle> {
        self.inner
            .lock()
            .unwrap()
            .sessions
            .values()
            .cloned()
            .collect()
    }

    fn remove(&self, id: &SessionId) -> bool {
        let removed = self.inner.lock().unwrap().sessions.remove(id).is_some();
        if removed {
            self.session_removed.notify_one();
        }
        removed
    }

    fn begin_draining(&self, reason: EndReason) {
        let mut guard = self.inner.lock().unwrap();
        guard.draining = true;
        for handle in guard.sessions.values() {
            handle.send(SessionMsg::Kill { reason });
        }
    }

    async fn wait_until_empty(&self) {
        loop {
            let removed = self.session_removed.notified();
            if self.inner.lock().unwrap().sessions.is_empty() {
                return;
            }
            removed.await;
        }
    }

    async fn finish_draining(&self, reason: EndReason) -> Result<()> {
        if tokio::time::timeout(SHUTDOWN_DRAIN_TIMEOUT, self.wait_until_empty())
            .await
            .is_ok()
        {
            return self.graveyard.bury_remaining(reason);
        }

        eprintln!(
            "termiod: shutdown drain exceeded {} seconds; forcing remaining sessions",
            SHUTDOWN_DRAIN_TIMEOUT.as_secs()
        );
        // Mark the surviving roster entries before the direct kill. If their
        // actors wake and reap concurrently, the graveyard's runtime dedupe
        // preserves this deliberate-stop reason.
        let persisted = self.graveyard.bury_remaining(reason);
        for handle in self.handles() {
            handle.force_kill();
        }
        persisted
    }

    fn publish(&self, event: Event) {
        let _ = self.events.send(event);
    }

    pub(crate) fn subscribe_events(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    async fn info(&self, handle: &SessionHandle) -> Option<SessionInfo> {
        let (tx, rx) = oneshot::channel();
        if handle.send(SessionMsg::Info { reply: tx }) {
            rx.await.ok()
        } else {
            None
        }
    }

    async fn publish_created(&self, id: &SessionId) {
        let Some(handle) = self.find(id) else {
            return;
        };
        let info = self.info(&handle).await;
        // The roster file is what lets the *next* daemon notice this session was
        // never buried. Recorded at creation, cleared at burial.
        if let Some(info) = &info {
            self.graveyard.note_live(info);
        }
        self.publish(Event::Roster {
            session: id.to_string(),
            action: "created".to_string(),
            info: info.map(Box::new),
        });
    }

    fn publish_removed(&self, id: &SessionId) {
        self.publish(Event::Roster {
            session: id.to_string(),
            action: "removed".to_string(),
            info: None,
        });
    }

    pub(crate) async fn list(&self) -> Vec<SessionInfo> {
        let handles = self.handles();
        let mut infos = Vec::new();
        for handle in handles {
            if let Some(info) = self.info(&handle).await {
                infos.push(info);
            }
        }
        infos.sort_by_key(|info| info.created_unix);
        infos
    }

    /// Resolve a target that may be an id or a name. The only door into the
    /// session table for a string that came off the wire: `find` takes a
    /// `SessionId`, so nothing else can index the table with an unresolved
    /// target.
    async fn resolve(&self, target: &str) -> Option<SessionHandle> {
        if let Some(handle) = self.find(&SessionId::new(target)) {
            return Some(handle);
        }
        for handle in self.handles() {
            if let Some(info) = self.info(&handle).await {
                if info.name == target {
                    return Some(handle);
                }
            }
        }
        None
    }

    async fn wait_response(
        &self,
        target: String,
        until: Vec<String>,
        timeout_ms: u64,
        re: Option<u64>,
    ) -> Control {
        // Subscribe before resolving/querying so an exit cannot slip through
        // between the state check and the event wait.
        let mut events = self.events.subscribe();
        let Some(handle) = self.resolve(&target).await else {
            return error(
                re,
                ErrorCode::NoSuchSession,
                format!("no such session: {target}"),
                false,
            );
        };
        let session_id = handle.id.clone();
        let Some(initial_info) = self.info(&handle).await else {
            return if until.iter().any(|wanted| wanted == "exited") {
                Control::WaitResult {
                    session: session_id.to_string(),
                    status: "exited".to_string(),
                    timed_out: false,
                    exit_status: None,
                    re,
                }
            } else {
                error(
                    re,
                    ErrorCode::AlreadyExited,
                    "session already exited",
                    false,
                )
            };
        };
        let initial = initial_info.status;
        if until.iter().any(|wanted| wanted == &initial) {
            return Control::WaitResult {
                session: session_id.to_string(),
                status: initial,
                timed_out: false,
                exit_status: None,
                re,
            };
        }

        let wait = async {
            loop {
                match events.recv().await {
                    Ok(Event::Status {
                        session, status, ..
                    }) if session == session_id.as_str()
                        && until.iter().any(|wanted| wanted == &status) =>
                    {
                        return Ok((status, None));
                    }
                    Ok(Event::SessionExited {
                        session, status, ..
                    }) if session == session_id.as_str()
                        && until.iter().any(|wanted| wanted == "exited") =>
                    {
                        return Ok(("exited".to_string(), Some(status)));
                    }
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => {
                        return Err("event stream closed");
                    }
                }
            }
        };

        match tokio::time::timeout(Duration::from_millis(timeout_ms), wait).await {
            Ok(Ok((status, exit_status))) => Control::WaitResult {
                session: session_id.to_string(),
                status,
                timed_out: false,
                exit_status,
                re,
            },
            Ok(Err(message)) => error(re, ErrorCode::Internal, message, true),
            Err(_) => {
                let current = self.info(&handle).await.map(|info| info.status);
                if current.is_none() && until.iter().any(|wanted| wanted == "exited") {
                    return Control::WaitResult {
                        session: session_id.to_string(),
                        status: "exited".to_string(),
                        timed_out: false,
                        exit_status: None,
                        re,
                    };
                }
                Control::WaitResult {
                    session: session_id.to_string(),
                    status: current.unwrap_or_else(|| "exited".to_string()),
                    timed_out: true,
                    exit_status: None,
                    re,
                }
            }
        }
    }
}

/// Run the daemon: bind the socket and accept forever.
///
/// `handoff_fd` is set only when this image is the far side of an `execve` from
/// a previous one (`crate::handoff`). Everything that would otherwise be
/// startup — binding the socket, wiping the scratch tree, reading the roster as
/// evidence of a crash — is instead adoption: the listener and the sessions are
/// already there, on descriptors this process inherited from itself.
pub async fn serve(
    wss_bind: Option<std::net::SocketAddr>,
    wss_origins: Vec<crate::wss::Origin>,
    handoff_fd: Option<std::os::fd::RawFd>,
    keep_awake: bool,
) -> Result<()> {
    // First, before anything that can fail: whoever spawned this daemon most
    // likely pointed its stderr at /dev/null, and a startup error is exactly the
    // kind worth keeping. A failure to set up logging is not a reason to refuse
    // to serve, so it is reported and stepped over.
    if let Err(error) = crate::log::redirect() {
        eprintln!("termiod: could not open the log file: {error:#}");
    }

    let sock_path = paths::socket_path()?;

    let inherited = match handoff_fd {
        Some(fd) => Some(crate::handoff::unpack(fd).context("reading the handoff blob")?),
        None => None,
    };

    // From here to the accept loop, every failure on the handoff path costs the
    // sessions this image was handed: their masters are held by descriptors
    // nothing would be left to read. So each step that a cold start is right to
    // refuse over is, here, something to log and go without. The daemon is worth
    // less with no WebSocket listener or no tombstone log; it is worth nothing
    // to the person whose agent was mid-task if it exits instead.
    let adopted = inherited.is_some();
    // The claim on the channel, held for the daemon's life. Two cold starts
    // racing the socket probe could each decide the path was theirs, and the
    // loser kept a listener bound to an unlinked file forever (#526); with the
    // lock, the loser exits here. A handoff's `execve` closes the descriptor
    // (it is CLOEXEC), which releases the lock for the incoming image — and a
    // failure to re-take it is, like everything on the handoff path, something
    // to log and go without rather than exit over.
    let _serve_lock = match paths::acquire_serve_lock() {
        Ok(lock) => Some(lock),
        Err(error) if adopted => {
            eprintln!("termiod: could not take the serve lock after the handoff: {error:#}");
            None
        }
        Err(error) => return Err(error),
    };
    match paths::ensure_runtime_dir() {
        Ok(_) => {}
        // The directory is already there and already holds the socket this
        // image inherited — a failure here is about creating it, which is a
        // question that was answered before the previous daemon started.
        Err(error) if adopted => {
            eprintln!("termiod: runtime directory check failed after the handoff: {error:#}");
        }
        Err(error) => return Err(error),
    }
    // Before anything reads identity, token, bind or graveyard: a box upgraded
    // from a build that kept them beside the socket still has them there.
    paths::adopt_runtime_state();

    let mut listener = match &inherited {
        Some((blob, _)) => adopt_listener(blob.listener_fd)?,
        None => {
            if sock_path.exists() {
                match UnixStream::connect(&sock_path).await {
                    Ok(_) => {
                        anyhow::bail!("termiod already running at {}", sock_path.display());
                    }
                    // Only these errnos prove the file is a corpse. An EPERM
                    // here is a sandbox denying *this* process, not a dead
                    // daemon: unlinking on it displaced healthy daemons and
                    // left them as the unreachable orphans of #526.
                    // A corpse is still a *socket*. Linux answers a connect to
                    // a plain file with ECONNREFUSED where macOS says ENOTSOCK,
                    // so without this the same mistyped `TERMIOD_SOCK` deletes
                    // the file it names on one platform and is refused on the
                    // other. What the errno licenses is replacing a socket
                    // nobody serves, never destroying something else.
                    Err(error) if socket_is_stale(error.raw_os_error()) => {
                        if !path_is_socket(&sock_path) {
                            anyhow::bail!(
                                "{} is not a socket — refusing to replace a file termiod did not create",
                                sock_path.display()
                            );
                        }
                        let _ = std::fs::remove_file(&sock_path);
                    }
                    Err(error) => {
                        anyhow::bail!(
                            "probing {} failed: {error} — refusing to replace a socket that may still be served",
                            sock_path.display()
                        );
                    }
                }
            }
            let listener = UnixListener::bind(&sock_path)
                .with_context(|| format!("binding {}", sock_path.display()))?;
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&sock_path, std::fs::Permissions::from_mode(0o600))?;
            listener
        }
    };

    // Resolved before anything else starts, because an explicit `--wss` with
    // no pairing token refuses the whole start: the operator asked for a
    // listener that cannot authenticate. After a handoff that same refusal
    // would be a refusal to keep running sessions alive, so it degrades.
    let wss = match crate::wss::resolve(wss_bind, &wss_origins) {
        Ok(wss) => wss,
        Err(error) if adopted => {
            eprintln!("termiod: the WebSocket configuration did not resolve after the handoff: {error:#}");
            eprintln!("termiod: sessions are unaffected; `termiod pair` and a restart re-establish it");
            None
        }
        Err(error) => return Err(error),
    };

    // Carried rather than re-read: the identity must not change across a
    // handoff, and the read that would establish it is one more thing that can
    // fail where failing is expensive.
    let host_id = match &inherited {
        Some((blob, _)) => blob.host_id.clone(),
        None => paths::load_or_create_host_id()?,
    };
    if inherited.is_none() {
        // Scratch dirs are session-scoped and every session died with the
        // previous daemon, so the whole tree is stale by definition here.
        // After a handoff the sessions are the same sessions, and so are
        // their scratch dirs.
        if let Ok(scratch) = paths::scratch_root() {
            let _ = std::fs::remove_dir_all(&scratch);
        }
    }
    // Opening the graveyard is also the crash check: anything the previous
    // daemon left on its roster is adopted as `daemon_lost` here, before this
    // one accepts a single connection. A session that crossed a handoff is on
    // that roster and is alive, so it is retained instead — while one that was
    // stranded at the exec is on it too, and is buried like any other loss.
    let carried_ids: Vec<String> = inherited
        .iter()
        .flat_map(|(blob, _)| blob.sessions.iter().map(|session| session.id.clone()))
        .collect();
    let graveyard = Arc::new(
        match paths::durable_state_dir().and_then(|dir| Graveyard::open_retaining(&dir, &carried_ids)) {
            Ok(graveyard) => graveyard,
            Err(error) if adopted => {
                eprintln!("termiod: the tombstone log did not open after the handoff: {error:#}");
                eprintln!("termiod: sessions are unaffected, but nothing this daemon does will be recorded — no roster, no tombstones");
                eprintln!("termiod: fix the state directory and hand off again; a restart would take the sessions with it");
                Graveyard::detached()
            }
            Err(error) => return Err(error),
        },
    );
    let (on_exit_tx, mut on_exit_rx) = mpsc::unbounded_channel::<SessionEnded>();
    let (handoff_tx, mut handoff_rx) = mpsc::unbounded_channel::<std::path::PathBuf>();
    let manager = Manager::new(on_exit_tx, host_id, graveyard, handoff_tx);
    tokio::spawn(pump_status_resource(
        manager.events.subscribe(),
        manager.resources.clone(),
    ));

    if let Some((blob, rings)) = inherited {
        let from = blob.from_build.clone();
        let mut adopted = 0usize;
        for (carried, ring) in blob.sessions.into_iter().zip(rings) {
            let id = carried.id.clone();
            match manager.adopt(carried, ring) {
                Ok(()) => adopted += 1,
                // The descriptor arrived but this image could not build a
                // session around it. Dropping it closes the master and hangs
                // the program up, which is the honest outcome — the session is
                // gone either way, and leaving the descriptor open would only
                // hide it. Burying it here is what keeps the roster honest too:
                // it was retained as alive on the strength of being carried,
                // and it is not.
                Err(error) => {
                    eprintln!("termiod: could not adopt session {id} after handoff: {error:#}");
                    manager.graveyard.bury_by_id(&id, EndReason::DaemonLost);
                }
            }
        }
        eprintln!(
            "termiod: handoff from {from} to {} complete — {adopted} session(s) carried",
            crate::lifecycle::BUILD_VERSION
        );
    }

    {
        let manager = manager.clone();
        tokio::spawn(async move {
            while let Some(ended) = on_exit_rx.recv().await {
                // The end record is a wire struct, so its id crosses back into
                // the host's vocabulary here.
                let id = SessionId::new(ended.info.id.clone());
                // A termination request can win after PTY EOF but before this
                // task receives the actor's end record. The handle retains the
                // first requested reason until burial completes.
                let reason = manager
                    .find(&id)
                    .and_then(|handle| handle.termination_reason())
                    .unwrap_or(ended.reason);
                manager
                    .graveyard
                    .bury(&ended.info, reason, Some(ended.status));
                // The scratch dir is reaped with the session (§C.12 `temp:`),
                // in-flight uploads first so no dotfile survives the sweep.
                manager.uploads.drop_session(&id);
                if let Ok(scratch) = paths::scratch_root() {
                    let _ = std::fs::remove_dir_all(scratch.join(format!("session-{id}")));
                }
                if manager.remove(&id) {
                    manager.publish_removed(&id);
                }
            }
        });
    }

    if !adopted {
        // Not printed after a handoff: the socket was never unbound, so
        // "listening on" would read as a start that did not happen. The
        // handoff line above is the event.
        eprintln!("termiod listening on {}", sock_path.display());
    }

    // The WSS listener stops accepting and drops its splices on the same signal
    // that ends the accept loop, so nothing attaches into a daemon that is
    // already burying its sessions.
    let (wss_shutdown, wss_shutdown_rx) = watch::channel(false);
    if let Some(config) = wss {
        match crate::wss::start(config, wss_shutdown_rx).await {
            Ok(()) => {}
            // On a cold start, an operator who asked for a listener and did not
            // get one wants to know immediately, and nothing is lost by
            // refusing. After a handoff the same failure would take every
            // carried session down with it, which is a far worse answer to
            // "the phone cannot connect" than the phone not connecting.
            Err(error) if adopted => {
                eprintln!("termiod: the WebSocket listener did not come back after the handoff: {error:#}");
                eprintln!("termiod: sessions are unaffected; `termiod pair` and a restart re-establish it");
            }
            Err(error) => return Err(error),
        }
    }

    // Other platforms never spawn this: the boxes termiod serves there are
    // servers that do not idle-sleep, and the mechanism is caffeinate anyway.
    if keep_awake && cfg!(target_os = "macos") {
        tokio::spawn(crate::keep_awake::run(manager.clone()));
    }

    let mut terminate =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .context("installing SIGTERM handler")?;
    let shutdown_signal = async move {
        tokio::select! {
            result = tokio::signal::ctrl_c() => result.context("waiting for SIGINT"),
            _ = terminate.recv() => Ok(()),
        }
    };
    tokio::pin!(shutdown_signal);

    // The socket file's identity at bind time. macOS sweeps $TMPDIR entries it
    // considers stale, and a raced start used to replace the file — either way
    // a daemon serving an unlinked path is unreachable and must not keep
    // pretending otherwise. The periodic check below re-binds a vanished path
    // and stands down from a replaced one.
    let mut bound_inode = socket_identity(&sock_path);
    let mut displacement_reported = false;
    let mut socket_check = tokio::time::interval(std::time::Duration::from_secs(30));
    socket_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    socket_check.tick().await;

    // Serving is a loop around the accept loop, not the accept loop itself: a
    // handoff that cannot go ahead puts its sessions back and comes out here to
    // carry on serving them. Only a shutdown, or a handoff that lost sessions,
    // leaves.
    'serving: loop {
        let mut becoming: Option<std::path::PathBuf> = None;
        loop {
            tokio::select! {
                biased;
                result = &mut shutdown_signal => {
                    result?;
                    break;
                }
                requested = handoff_rx.recv() => {
                    let Some(binary) = requested else { continue };
                    becoming = Some(binary);
                    break;
                }
                accepted = listener.accept() => {
                    let (stream, _addr) = accepted?;
                    let manager = manager.clone();
                    tokio::spawn(async move {
                        if let Err(e) = handle_conn(stream, manager).await {
                            eprintln!("termiod: connection error: {e:#}");
                        }
                    });
                }
                _ = socket_check.tick() => {
                    let identity = socket_identity(&sock_path);
                    if identity == bound_inode {
                        displacement_reported = false;
                    } else if identity.is_none() {
                        // The file is gone but nothing replaced it — re-bind
                        // in place. Established connections ride the old
                        // listener's descriptors and never notice.
                        match UnixListener::bind(&sock_path) {
                            Ok(rebound) => {
                                use std::os::unix::fs::PermissionsExt;
                                let _ = std::fs::set_permissions(
                                    &sock_path, std::fs::Permissions::from_mode(0o600));
                                listener = rebound;
                                bound_inode = socket_identity(&sock_path);
                                eprintln!(
                                    "termiod: {} had vanished; re-bound it",
                                    sock_path.display());
                            }
                            Err(error) => {
                                eprintln!(
                                    "termiod: {} is gone and re-binding failed: {error:#}",
                                    sock_path.display());
                            }
                        }
                    } else if manager.handles().is_empty() {
                        // Another daemon owns the path and this one holds
                        // nothing — lingering is how the #526 orphans lived
                        // for a week. With sessions it stays: they outrank
                        // reachability, and killing them to tidy a process
                        // table is the wrong trade.
                        eprintln!(
                            "termiod: {} now belongs to another daemon and no sessions are held here; exiting",
                            sock_path.display());
                        std::process::exit(0);
                    } else if !displacement_reported {
                        displacement_reported = true;
                        eprintln!(
                            "termiod: {} now belongs to another daemon; keeping the sessions held here alive",
                            sock_path.display());
                    }
                }
            }
        }

        let Some(binary) = becoming else { break 'serving };
        match hand_over(&manager, &listener, &binary).await {
            // Every session that was carried is back in the roster and running.
            // Nothing was lost, so there is nothing to exit for — go back to
            // accepting. Whoever asked for the upgrade can ask again.
            Handoff::Aborted(error) => {
                eprintln!(
                    "termiod: handoff to {} aborted: {error:#}",
                    binary.display()
                );
                eprintln!("termiod: every session is still here; carrying on");
                manager.end_handoff();
                continue 'serving;
            }
            Handoff::Lost(error) => {
                eprintln!("termiod: handoff to {} failed: {error:#}", binary.display());
                eprintln!(
                    "termiod: the sessions this daemon held are lost; the next start will bury them"
                );
                std::process::exit(1);
            }
        }
    }

    // After the serving loop, not before the handoff: an aborted upgrade goes
    // back to serving, and taking the WebSocket listener down on the way past
    // would leave the phone disconnected from a daemon that never went anywhere.
    let _ = wss_shutdown.send(true);

    manager.begin_draining(EndReason::DaemonStopped);
    let drained = manager.finish_draining(EndReason::DaemonStopped).await;
    // Keeping the bound listener through the drain prevents an autostarting
    // client from placing a replacement daemon over state still being buried.
    drop(listener);
    match std::fs::remove_file(&sock_path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => eprintln!("termiod: could not remove socket during shutdown: {error}"),
    }
    drained
}

/// Whether a failed probe connect proves no daemon is behind the socket file.
fn socket_is_stale(errno: Option<i32>) -> bool {
    crate::client::absent_daemon(errno)
}

/// Whether `path` is a socket. `false` for anything else, a path that cannot be
/// stat'd included: the only caller is about to unlink, and it may act only on
/// what it can positively identify.
fn path_is_socket(path: &std::path::Path) -> bool {
    use std::os::unix::fs::FileTypeExt;
    std::fs::metadata(path)
        .map(|metadata| metadata.file_type().is_socket())
        .unwrap_or(false)
}

/// The inode currently at `path`, or `None` when nothing is.
fn socket_identity(path: &std::path::Path) -> Option<u64> {
    std::fs::metadata(path)
        .ok()
        .map(|metadata| std::os::unix::fs::MetadataExt::ino(&metadata))
}

/// Re-establish a `UnixListener` on a descriptor that crossed an `execve`.
///
/// The socket was never unlinked and never re-bound, so anything that connected
/// during the crossing is sitting in the kernel's accept backlog and is served
/// the moment this listener starts accepting.
fn adopt_listener(fd: std::os::fd::RawFd) -> Result<UnixListener> {
    use std::os::fd::FromRawFd;
    let listener = unsafe { std::os::unix::net::UnixListener::from_raw_fd(fd) };
    // Tokio polls the descriptor and will not block for it; the previous image
    // set this on the same open file description, but a carried descriptor is
    // exactly the kind of assumption worth not making twice.
    listener
        .set_nonblocking(true)
        .context("making the carried listener non-blocking")?;
    UnixListener::from_std(listener).context("adopting the carried listener")
}

/// Pack every session and become `binary`. Returns only on failure.
///
/// Order is what keeps this survivable. Everything fallible that does *not*
/// need the sessions runs first — resolving the state directory, creating and
/// unlinking the file the blob will go in, duplicating the listener — while the
/// daemon is still whole and a failure is an ordinary error. Only then are the
/// actors asked for their PTYs, which is the step that cannot be undone.
///
/// It is not the case that nothing can fail afterwards. Writing the blob can
/// still run out of space, and the new image can still fail to start. What the
/// ordering buys is that the *likely* failures — a missing directory, a
/// read-only filesystem, a listener that cannot be duplicated — happen before
/// the point of no return rather than after it. The far side answers the rest
/// by degrading instead of exiting; see `serve`.
/// How a handoff attempt ended. Only `Lost` is worth exiting over: `Aborted`
/// means every session is back in the roster and the daemon can go on serving,
/// which is the whole point of being able to put them back.
enum Handoff {
    /// Nothing was carried, or everything carried was restored.
    Aborted(anyhow::Error),
    /// Sessions were carried and could not be put back. They are gone.
    Lost(anyhow::Error),
}

async fn hand_over(
    manager: &Manager,
    listener: &UnixListener,
    binary: &std::path::Path,
) -> Handoff {
    use std::os::fd::{AsRawFd, IntoRawFd};

    let state_dir = match paths::state_dir() {
        Ok(dir) => dir,
        Err(error) => return Handoff::Aborted(error.context("locating the state directory")),
    };
    let staged = match crate::handoff::stage_blob(&state_dir) {
        Ok(file) => file,
        Err(error) => return Handoff::Aborted(error.context("staging the handoff blob")),
    };
    let host_id = manager.host_id.to_string();
    // Held, not released: like the session masters, this is committed by `pack`
    // once the blob is written, so a failure before then closes it instead of
    // leaving a listener nothing owns.
    let listener_fd = match crate::handoff::duplicate_for_exec(listener.as_raw_fd()) {
        Ok(fd) => fd,
        Err(error) => return Handoff::Aborted(error.context("carrying the listener")),
    };

    // Past here the sessions are no longer readable by anything in this image.
    let (carried, stranded) = manager.carry_all().await;
    let sessions: Vec<_> = carried
        .into_iter()
        .map(|one| (one.info, one.master, one.ring))
        .collect();
    // An upgrade that takes most of the sessions is not the feature. A session
    // misses the deadline because its actor is busy or its VT sidecar is slow
    // to join — not because it is unhealthy — and going ahead would send SIGHUP
    // to a running agent whose PTY was fine. Put back the ones that did carry
    // and leave the daemon exactly as it was; the upgrade can be asked for
    // again when whatever was slow has finished.
    if !stranded.is_empty() {
        let lost = manager.restore(sessions);
        let error = anyhow::anyhow!(
            "session(s) {} did not hand over their pty within {:?}",
            stranded.join(", "),
            crate::handoff::CARRY_TIMEOUT
        );
        return if lost.is_empty() {
            Handoff::Aborted(error)
        } else {
            Handoff::Lost(error.context(format!("and {} could not be put back", lost.join(", "))))
        };
    }
    eprintln!(
        "termiod: handing off to {} with {} session(s)",
        binary.display(),
        sessions.len()
    );

    let blob = crate::handoff::Blob {
        format: crate::handoff::FORMAT_VERSION,
        from_build: crate::lifecycle::BUILD_VERSION.to_string(),
        host_id,
        // Assigned by `pack`, with the session masters.
        listener_fd: -1,
        sessions: Vec::new(),
    };
    let blob_fd = match crate::handoff::pack(blob, listener_fd, sessions, staged) {
        Ok(fd) => fd.into_raw_fd(),
        // The write ran out of space, or the sync failed. Every descriptor came
        // back, so every session goes back into the roster and the daemon keeps
        // running — this used to close the lot and take every shell with it.
        Err(failed) => {
            let lost = manager.restore(failed.sessions);
            let error = failed.error.context("packing the handoff blob");
            return if lost.is_empty() {
                Handoff::Aborted(error)
            } else {
                Handoff::Lost(
                    error.context(format!("and {} could not be put back", lost.join(", "))),
                )
            };
        }
    };
    let error = crate::handoff::exec(binary, blob_fd);

    // `exec` returns only if it failed — the binary was replaced or removed
    // between the probe and here, or is busy. "Nothing owns the descriptors any
    // more" was the reason this used to give up, and it was wrong: unowned is
    // not closed. Every master is still open in this process, and the blob that
    // was just written names all of them along with the rings. Reading it back
    // is exactly what the new image would have done, so the recovery is the same
    // adoption, run here instead of there.
    let recovered = match crate::handoff::unpack(blob_fd) {
        Ok((blob, rings)) => {
            let sessions: Vec<_> = blob
                .sessions
                .into_iter()
                .zip(rings)
                .map(|(info, ring)| {
                    // Taking back ownership of a number this process released to
                    // an image that never ran. Safe for the same reason the far
                    // side's adoption is: nothing else holds it.
                    let master = unsafe {
                        <std::os::fd::OwnedFd as std::os::fd::FromRawFd>::from_raw_fd(
                            info.master_fd,
                        )
                    };
                    (info, master, vec![Bytes::from(ring)])
                })
                .collect();
            manager.restore(sessions)
        }
        // Without the blob there is no list of what to put back. The descriptors
        // stay open and unreferenced for the life of the process, which is worse
        // than a leak only in that the sessions behind them are unreachable.
        Err(read) => {
            eprintln!("termiod: the handoff blob could not be read back: {read:#}");
            vec!["<unknown>".to_string()]
        }
    };
    if recovered.is_empty() {
        Handoff::Aborted(error)
    } else {
        Handoff::Lost(error.context(format!("and {} could not be put back", recovered.join(", "))))
    }
}

#[derive(Clone)]
struct Connection {
    client_id: ClientId,
    negotiated: bool,
    capabilities: HashSet<String>,
}

enum Outbound {
    Control(Control),
    Data(Metered),
    Event(Event),
    Snapshot(Snapshot),
    History(Metered),
    Grid(Metered),
    File(Bytes),
    /// Not a message: a marker the writer answers once everything queued ahead
    /// of it is on the socket. One caller needs it — `handoff`, which must not
    /// replace the process image while its own `ok` is still in a channel.
    Flushed(oneshot::Sender<()>),
}

async fn write_outbound(
    mut wr: tokio::net::unix::OwnedWriteHalf,
    mut rx: mpsc::UnboundedReceiver<Outbound>,
    backlog: Arc<ClientBacklog>,
) {
    while let Some(message) = rx.recv().await {
        // A forced resync retires everything queued under the old epoch. Those
        // payloads precede a snapshot that supersedes them, so writing them
        // would only make the client that could not keep up wait longer.
        if let Outbound::Data(payload) | Outbound::History(payload) | Outbound::Grid(payload) =
            &message
        {
            if !backlog.is_current(payload) {
                continue;
            }
        }
        let result = match message {
            Outbound::Control(control) => write_control(&mut wr, &control).await,
            Outbound::Data(payload) => {
                let result = write_data(&mut wr, &payload.bytes).await;
                backlog.release(&payload);
                result
            }
            Outbound::Event(event) => write_event(&mut wr, &event).await,
            Outbound::Snapshot(snapshot) => write_snapshot(&mut wr, &snapshot).await,
            Outbound::History(payload) => {
                let result = write_history_payload(&mut wr, &payload.bytes).await;
                backlog.release(&payload);
                result
            }
            Outbound::Grid(payload) => {
                let result = write_grid_payload(&mut wr, &payload.bytes).await;
                backlog.release(&payload);
                result
            }
            Outbound::File(payload) => write_file_payload(&mut wr, &payload).await,
            Outbound::Flushed(signal) => {
                let _ = signal.send(());
                Ok(())
            }
        };
        if result.is_err() {
            break;
        }
    }
}

async fn handle_conn(stream: UnixStream, manager: Manager) -> Result<()> {
    let (mut rd, mut wr) = stream.into_split();
    let client_id = manager.alloc_client_id();

    let first = match read_frame(&mut rd).await {
        Ok(Some(frame)) => frame,
        Ok(None) => return Ok(()),
        Err(e) => {
            write_control(
                &mut wr,
                &error(None, ErrorCode::ProtoError, e.to_string(), false),
            )
            .await?;
            return Ok(());
        }
    };

    let (connection, pending) = match first {
        Frame::Control(Control::Hello {
            proto,
            min_proto,
            role: _,
            caps,
            client: _,
        }) => {
            if min_proto > PROTOCOL_VERSION || proto < PROTOCOL_VERSION {
                write_control(
                    &mut wr,
                    &Control::HelloErr {
                        code: ErrorCode::Incompatible,
                        supported: SUPPORTED_PROTOCOLS.to_vec(),
                    },
                )
                .await?;
                return Ok(());
            }
            let mut seen = HashSet::new();
            let mut negotiated_caps: Vec<String> = caps
                .into_iter()
                .filter(|cap| HOST_CAPABILITIES.contains(&cap.as_str()))
                .filter(|cap| seen.insert(cap.clone()))
                .collect();
            // The parsed plane uses S for bootstrap and recovery. A client
            // offering grid_diff without snapshot therefore does not
            // negotiate grid_diff.
            if negotiated_caps.iter().any(|cap| cap == "grid_diff")
                && !negotiated_caps.iter().any(|cap| cap == "snapshot")
            {
                negotiated_caps.retain(|cap| cap != "grid_diff");
            }
            write_control(
                &mut wr,
                &Control::HelloOk {
                    proto: PROTOCOL_VERSION,
                    caps: negotiated_caps.clone(),
                    host_id: (*manager.host_id).clone(),
                    host: format!(
                        "termiod/{} {}-{}",
                        crate::lifecycle::BUILD_VERSION,
                        std::env::consts::OS,
                        std::env::consts::ARCH
                    ),
                    client_id: client_id.to_string(),
                    version: Some(crate::lifecycle::BUILD_VERSION.to_string()),
                    home: std::env::var("HOME").unwrap_or_default(),
                },
            )
            .await?;
            (
                Connection {
                    client_id,
                    negotiated: true,
                    capabilities: negotiated_caps.into_iter().collect(),
                },
                None,
            )
        }
        Frame::Control(control) => (
            Connection {
                client_id,
                negotiated: false,
                capabilities: HashSet::new(),
            },
            Some(control),
        ),
        _ => {
            write_control(
                &mut wr,
                &error(
                    None,
                    ErrorCode::ProtoError,
                    "expected a control frame first",
                    false,
                ),
            )
            .await?;
            return Ok(());
        }
    };

    let (out, out_rx) = mpsc::unbounded_channel();
    let backlog = Arc::new(ClientBacklog::new());
    let writer = tokio::spawn(write_outbound(wr, out_rx, backlog.clone()));
    let departing = connection.client_id.clone();
    let resources = manager.resources.clone();
    let result = run_connection(
        rd,
        out.clone(),
        connection,
        pending,
        manager,
        backlog.clone(),
    )
    .await;
    // Resource subscriptions are per-connection: a dropped client releases its
    // interest, and the last one out stops the underlying watch.
    resources.drop_client(&departing);
    drop(out);
    if backlog.is_dropped() {
        writer.abort();
    }
    let _ = writer.await;
    result
}

/// In-flight cancellable requests on one control connection, keyed by their
/// request id (§C.12 `fs.search`). Dropping a sender — via `cancel`, or the
/// whole map going away with the connection — stops the work.
type SearchMap = Arc<Mutex<HashMap<u64, oneshot::Sender<()>>>>;

struct AttachRequest {
    handle: SessionHandle,
    rows: u16,
    cols: u16,
    mode: AttachMode,
    re: Option<u64>,
}

enum ControlFlow {
    Continue,
    Attach(AttachRequest),
    Close,
}

async fn run_connection(
    mut rd: tokio::net::unix::OwnedReadHalf,
    out: mpsc::UnboundedSender<Outbound>,
    connection: Connection,
    mut pending: Option<Control>,
    manager: Manager,
    backlog: Arc<ClientBacklog>,
) -> Result<()> {
    let mut subscriptions = HashSet::new();
    let mut events = manager.events.subscribe();
    let mut response_cache: HashMap<u64, Control> = HashMap::new();
    // Resource and search events are addressed to this connection alone, so
    // they take a dedicated channel rather than the roster broadcast every
    // client sees.
    let (resource_tx, mut resource_rx) = mpsc::unbounded_channel::<Event>();
    let searches: SearchMap = Arc::new(Mutex::new(HashMap::new()));

    loop {
        if let Some(control) = pending.take() {
            match process_control(
                control,
                &out,
                &connection,
                &manager,
                &mut subscriptions,
                &mut response_cache,
                &resource_tx,
                &searches,
            )
            .await?
            {
                ControlFlow::Continue => {}
                ControlFlow::Attach(request) => {
                    return run_attach(rd, out, request, connection, backlog).await;
                }
                ControlFlow::Close => return Ok(()),
            }
        }

        tokio::select! {
            frame = read_frame(&mut rd) => {
                match frame {
                    Ok(Some(Frame::Control(control))) => pending = Some(control),
                    // A verb from a newer client is version skew, not a broken
                    // pipe: that request fails, the connection — and every
                    // subscription riding it — lives on.
                    Ok(Some(Frame::UnknownControl { op, seq })) => {
                        let _ = out.send(Outbound::Control(error(
                            seq,
                            ErrorCode::ProtoError,
                            format!("unknown op: {op}"),
                            false,
                        )));
                    }
                    Ok(Some(Frame::Event(event))) => {
                        // Events are host-authored. Unknown/inapplicable event
                        // types are ignored by the additive-evolution rule.
                        drop(event);
                    }
                    Ok(Some(Frame::Snapshot(_))) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "snapshot frames are host-to-client only",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(Some(Frame::History(_))) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "history frames are host-to-client only",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(Some(Frame::Grid(_))) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "grid-diff frames are host-to-client only",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(Some(Frame::File(_))) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "file frames are host-to-client only",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(Some(Frame::Upload(chunk))) => {
                        if !connection.capabilities.contains("upload") {
                            let _ = out.send(Outbound::Control(error(
                                None,
                                ErrorCode::Denied,
                                "the upload capability was not negotiated",
                                false,
                            )));
                            return Ok(());
                        }
                        // The ack is the credit: it goes back only once the
                        // chunk is written, so a client honoring credit-of-one
                        // can never queue more than one chunk in the pipe.
                        let outcome = manager.uploads.chunk(
                            &chunk.upload_id,
                            chunk.offset,
                            &chunk.data,
                        );
                        let reply = match outcome {
                            Ok(offset) => Control::UploadAck {
                                upload_id: chunk.upload_id,
                                offset,
                            },
                            Err(e) => error(None, ErrorCode::Denied, format!("{e:#}"), false),
                        };
                        let _ = out.send(Outbound::Control(reply));
                    }
                    Ok(Some(Frame::Data(_))) | Ok(Some(Frame::Viewport { .. })) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            "terminal frame received before attach",
                            false,
                        )));
                        return Ok(());
                    }
                    Ok(None) => return Ok(()),
                    Err(e) => {
                        let _ = out.send(Outbound::Control(error(
                            None,
                            ErrorCode::ProtoError,
                            e.to_string(),
                            false,
                        )));
                        return Ok(());
                    }
                }
            }
            event = events.recv(), if !subscriptions.is_empty() => {
                match event {
                    Ok(event) if subscribed_to(&subscriptions, &event) => {
                        if connection.capabilities.contains("events") {
                            let _ = out.send(Outbound::Event(event));
                        }
                    }
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return Ok(()),
                }
            }
            Some(event) = resource_rx.recv() => {
                let _ = out.send(Outbound::Event(event));
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn process_control(
    control: Control,
    out: &mpsc::UnboundedSender<Outbound>,
    connection: &Connection,
    manager: &Manager,
    subscriptions: &mut HashSet<String>,
    response_cache: &mut HashMap<u64, Control>,
    resource_tx: &mpsc::UnboundedSender<Event>,
    searches: &SearchMap,
) -> Result<ControlFlow> {
    let seq = control.seq();
    if let Some(cached) = seq.and_then(|id| response_cache.get(&id)) {
        let _ = out.send(Outbound::Control(cached.clone()));
        return Ok(ControlFlow::Continue);
    }

    match control {
        Control::Create { spec, seq } => {
            let response = match manager.create(spec) {
                Ok(id) => {
                    manager.publish_created(&id).await;
                    Control::Created {
                        id: id.to_string(),
                        re: seq,
                    }
                }
                Err(e) => error(seq, ErrorCode::CreateFailed, format!("{e:#}"), false),
            };
            send_response(out, response_cache, seq, response);
        }
        Control::List { seq } => {
            let sessions = manager.list().await;
            send_response(
                out,
                response_cache,
                seq,
                Control::Sessions {
                    sessions,
                    tombstones: manager.graveyard.all(),
                    re: seq,
                },
            );
        }
        Control::Kill { id, seq } => {
            let response = match manager.resolve(&id).await {
                // Same window as `Send`, and the same rule: a kill nobody
                // received must not read as a kill that happened. The session
                // is about to cross into the new image alive, and a caller told
                // otherwise would stop watching something still running.
                Some(handle)
                    if handle.send(SessionMsg::Kill {
                        reason: EndReason::Killed,
                    }) =>
                {
                    Control::Ok { re: seq }
                }
                Some(_) => error(
                    seq,
                    ErrorCode::Busy,
                    format!(
                        "session {id} is being handed to a new daemon; \
                         it was not killed — reconnect and ask again"
                    ),
                    true,
                ),
                None => error(
                    seq,
                    ErrorCode::NoSuchSession,
                    format!("no such session: {id}"),
                    false,
                ),
            };
            send_response(out, response_cache, seq, response);
        }
        Control::Handoff { binary, seq } => {
            let response = if !connection.capabilities.contains("handoff") {
                error(
                    seq,
                    ErrorCode::Denied,
                    "the handoff capability was not negotiated",
                    false,
                )
            } else {
                // Vetting runs on a blocking thread because it *runs* the
                // candidate binary, and the answer decides whether the daemon
                // is still whole a moment from now. Everything that can refuse
                // refuses here, while there is still a connection to refuse on.
                let path = std::path::PathBuf::from(&binary);
                let vetted = tokio::task::spawn_blocking(move || crate::handoff::vet(&path))
                    .await
                    .map_err(|error| anyhow::anyhow!("{error}"))
                    .and_then(|result| result);
                match vetted {
                    // A second request while one is already under way would
                    // carry a roster the first has emptied and pack a blob of
                    // nothing. It is refused where every other refusal happens:
                    // while there is still a connection to refuse on.
                    Ok(_) if !manager.begin_handoff() => error(
                        seq,
                        ErrorCode::Busy,
                        "a handoff is already under way",
                        true,
                    ),
                    Ok(path) => {
                        // The reply goes out *before* the accept loop is told,
                        // and this waits for it to reach the socket: the exec
                        // that follows takes the connection with it, so an `ok`
                        // still sitting in a channel is an `ok` the client
                        // never sees — and a successful handoff that reads, at
                        // the other end, as a daemon that died mid-request.
                        send_response(out, response_cache, seq, Control::Ok { re: seq });
                        let (flushed, on_wire) = oneshot::channel();
                        if out.send(Outbound::Flushed(flushed)).is_ok() {
                            // Bounded, because the queue ahead of the marker is
                            // not this connection's to drain: a client that has
                            // stopped reading its own terminal output blocks the
                            // writer on a payload that came before the request,
                            // and waiting on that forever would let any attached
                            // client veto an upgrade by going quiet. The `ok` is
                            // a courtesy; the handoff is not.
                            if tokio::time::timeout(HANDOFF_FLUSH_TIMEOUT, on_wire)
                                .await
                                .is_err()
                            {
                                eprintln!(
                                    "termiod: the handoff reply could not be flushed in {}s; going ahead without it",
                                    HANDOFF_FLUSH_TIMEOUT.as_secs()
                                );
                            }
                        }
                        let _ = manager.handoff.send(path);
                        return Ok(ControlFlow::Continue);
                    }
                    Err(reason) => error(
                        seq,
                        ErrorCode::Denied,
                        format!("{binary} cannot be handed off to: {reason:#}"),
                        false,
                    ),
                }
            };
            send_response(out, response_cache, seq, response);
        }
        Control::Send { id, data, seq } => {
            let response = match manager.resolve(&id).await {
                // A handle outlives the actor it addresses: `carry_all` makes
                // each actor return, and the manager keeps its handle until the
                // `execve`. A send in that window reaches nobody, and answering
                // `ok` to it is the one failure this whole feature exists to
                // prevent — an agent hook told its input landed when the bytes
                // are gone. `Busy` says the same thing a reconnect will fix.
                Some(handle) if handle.send(SessionMsg::Inject { data }) => {
                    Control::Ok { re: seq }
                }
                Some(_) => error(
                    seq,
                    ErrorCode::Busy,
                    format!(
                        "session {id} is being handed to a new daemon; \
                         the write was not delivered — reconnect and send it again"
                    ),
                    true,
                ),
                None => error(
                    seq,
                    ErrorCode::NoSuchSession,
                    format!("no such session: {id}"),
                    false,
                ),
            };
            send_response(out, response_cache, seq, response);
        }
        Control::Attach {
            target,
            create_if_missing,
            rows,
            cols,
            mode,
            seq,
        } => {
            let handle = match manager.resolve(&target).await {
                Some(handle) => Some(handle),
                None => match create_if_missing {
                    Some(mut spec) => {
                        if spec.name.is_none() {
                            spec.name = Some(target.clone());
                        }
                        // Zero is "my window has not laid out yet" — a real
                        // viewport declaration in every other case, but no
                        // size to spawn a brand-new PTY at. The spec's own
                        // default stands in, and the first `R` corrects it.
                        if rows > 0 && cols > 0 {
                            spec.rows = rows;
                            spec.cols = cols;
                        }
                        match manager.create(spec) {
                            Ok(id) => {
                                manager.publish_created(&id).await;
                                manager.find(&id)
                            }
                            Err(e) => {
                                let response =
                                    error(seq, ErrorCode::CreateFailed, format!("{e:#}"), false);
                                send_response(out, response_cache, seq, response);
                                return Ok(ControlFlow::Continue);
                            }
                        }
                    }
                    None => None,
                },
            };
            let Some(handle) = handle else {
                let response = error(
                    seq,
                    ErrorCode::NoSuchSession,
                    format!("no such session: {target}"),
                    false,
                );
                send_response(out, response_cache, seq, response);
                return Ok(ControlFlow::Continue);
            };
            return Ok(ControlFlow::Attach(AttachRequest {
                handle,
                rows,
                cols,
                mode,
                re: seq,
            }));
        }
        Control::Subscribe { events, seq } => {
            if !connection.capabilities.contains("events") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the events capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                subscriptions.extend(events);
                send_response(out, response_cache, seq, Control::Ok { re: seq });
            }
        }
        Control::SubscribeResource {
            resource,
            since,
            seq,
        } => {
            let response = if !connection.capabilities.contains("resources") {
                error(
                    seq,
                    ErrorCode::Denied,
                    "the resources capability was not negotiated",
                    false,
                )
            } else if resource.starts_with("git:") && !connection.capabilities.contains("git") {
                error(
                    seq,
                    ErrorCode::Denied,
                    "the git capability was not negotiated",
                    false,
                )
            } else {
                // Clients name a workspace root; the host canonicalises it, so
                // two spellings of one repo share a single watch.
                match crate::resource::Registry::resource_id(&resource)
                    .and_then(|id| {
                        manager
                            .resources
                            .subscribe(
                                &id,
                                connection.client_id.clone(),
                                resource_tx.clone(),
                                since,
                            )
                            .map(|reply| (id, reply))
                    }) {
                    Ok((id, reply)) => {
                        // The replay is already queued on `resource_tx` —
                        // `Registry::attach` puts it there under the resource
                        // lock, so no live batch can precede it. This ack
                        // reaches `out` first regardless, because it is sent
                        // from here while the select loop that drains
                        // `resource_rx` is still waiting on this call: the
                        // client learns whether to rescan before it applies
                        // anything.
                        Control::Subscribed {
                            resource: id,
                            seq: reply.seq,
                            gap: reply.gap,
                            re: seq,
                        }
                    }
                    Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                }
            };
            send_response(out, response_cache, seq, response);
        }
        Control::UnsubscribeResource { resource, seq } => {
            let id = crate::resource::Registry::resource_id(&resource)
                .unwrap_or_else(|_| resource.clone());
            manager.resources.unsubscribe(&id, &connection.client_id);
            send_response(out, response_cache, seq, Control::Ok { re: seq });
        }
        Control::FsSearch {
            root,
            query,
            limit,
            seq,
        } => {
            if !connection.capabilities.contains("files") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the files capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                let (cancel_tx, cancel_rx) = oneshot::channel();
                // Without a request id the search cannot be addressed by
                // `cancel`; the task holds the sender itself so only the
                // connection going away stops it.
                let retained = match seq {
                    Some(id) => {
                        searches.lock().unwrap().insert(id, cancel_tx);
                        None
                    }
                    None => Some(cancel_tx),
                };
                tokio::spawn(run_search(
                    out.clone(),
                    searches.clone(),
                    manager.searching.clone(),
                    cancel_rx,
                    retained,
                    root,
                    query,
                    limit,
                    seq,
                ));
            }
        }
        Control::Cancel { request, seq } => {
            let pending = searches.lock().unwrap().remove(&request);
            if let Some(cancel) = pending {
                let _ = cancel.send(());
            }
            // Cancelling what already finished is declaring disinterest in a
            // result that no longer exists — success either way.
            send_response(out, response_cache, seq, Control::Ok { re: seq });
        }
        Control::GitDiff {
            root,
            path,
            staged,
            context,
            seq,
        } => {
            if let Some(denied) = git_denied(connection, seq) {
                send_response(out, response_cache, seq, denied);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let response = match crate::git::run_diff(&root, &path, staged, context).await
                    {
                        Ok((diff, truncated)) => Control::GitDiffResult {
                            diff,
                            truncated,
                            re: seq,
                        },
                        Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::GitLog {
            root,
            limit,
            range,
            seq,
        } => {
            if let Some(denied) = git_denied(connection, seq) {
                send_response(out, response_cache, seq, denied);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let response =
                        match crate::git::run_log(&root, limit, range.as_deref()).await {
                            Ok(page) => Control::GitLogResult {
                                commits: page.commits,
                                truncated: page.truncated,
                                re: seq,
                            },
                            Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                        };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::GitShow {
            root,
            commit,
            path,
            seq,
        } => {
            if let Some(denied) = git_denied(connection, seq) {
                send_response(out, response_cache, seq, denied);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let response =
                        match crate::git::run_show(&root, &commit, path.as_deref()).await {
                            Ok(detail) => Control::GitShowResult {
                                commit: detail.commit,
                                files: detail.files,
                                diff: detail.diff,
                                truncated: detail.truncated,
                                files_truncated: detail.files_truncated,
                                re: seq,
                            },
                            Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                        };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::GitBranches { root, seq } => {
            if let Some(denied) = git_denied(connection, seq) {
                send_response(out, response_cache, seq, denied);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let response = match crate::git::run_branches(&root).await {
                        Ok(list) => Control::GitBranchesResult {
                            branches: list.branches,
                            current: list.current,
                            default_branch: list.default_branch,
                            truncated: list.truncated,
                            re: seq,
                        },
                        Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::GitCompare {
            root,
            base,
            path,
            seq,
        } => {
            if let Some(denied) = git_denied(connection, seq) {
                send_response(out, response_cache, seq, denied);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let response =
                        match crate::git::run_compare(&root, &base, path.as_deref()).await {
                            Ok(outcome) => Control::GitCompareResult {
                                files: outcome.files,
                                commits: outcome.commits,
                                behind: outcome.behind,
                                diff: outcome.diff,
                                truncated: outcome.truncated,
                                files_truncated: outcome.files_truncated,
                                commits_truncated: outcome.commits_truncated,
                                problem: outcome.problem,
                                re: seq,
                            },
                            Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                        };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::FsList {
            root,
            paths,
            after,
            seq,
        } => {
            if !connection.capabilities.contains("files") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the files capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                // Stamp with the resource cursor *before* walking, so a change
                // landing mid-listing makes the stamp stale (client re-lists)
                // rather than falsely fresh. Every request carries its own
                // stamp, so a client continuing a large directory must keep the
                // *first* one: a listing is only as fresh as its earliest read.
                let stamp = manager.resources.fs_seq(&root);
                let out = out.clone();
                tokio::spawn(async move {
                    let listed = tokio::task::spawn_blocking(move || {
                        crate::files::list(&root, &paths, after.as_deref())
                    })
                    .await;
                    let response = match listed {
                        Ok(Ok(listings)) => Control::FsListed {
                            seq: stamp,
                            listings,
                            re: seq,
                        },
                        Ok(Err(e)) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                        Err(e) => error(seq, ErrorCode::Internal, e.to_string(), true),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::FsRead {
            path,
            offset,
            length,
            seq,
        } => {
            if !connection.capabilities.contains("files") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the files capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                let out = out.clone();
                tokio::spawn(async move {
                    let window = tokio::task::spawn_blocking(move || {
                        crate::files::read(&path, offset, length)
                    })
                    .await;
                    match window {
                        Ok(Ok(window)) => {
                            let _ = out.send(Outbound::Control(Control::FsFile {
                                size: window.size,
                                offset: window.offset,
                                length: window.data.len() as u64,
                                truncated: window.truncated,
                                mtime: window.mtime,
                                re: seq,
                            }));
                            send_file_chunks(&out, seq.unwrap_or(0), window.offset, &window.data);
                        }
                        Ok(Err(e)) => {
                            let _ = out.send(Outbound::Control(error(
                                seq,
                                ErrorCode::Denied,
                                format!("{e:#}"),
                                false,
                            )));
                        }
                        Err(e) => {
                            let _ = out.send(Outbound::Control(error(
                                seq,
                                ErrorCode::Internal,
                                e.to_string(),
                                true,
                            )));
                        }
                    }
                });
            }
        }
        Control::FsMatch {
            root,
            query,
            limit,
            seq,
        } => {
            if !connection.capabilities.contains("files") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the files capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                match manager.resources.name_index(&root) {
                    // No subscription yet means no index — an honest 0.0,
                    // not a walk nobody asked the watcher to keep fresh.
                    None => {
                        let response = Control::FsMatched {
                            paths: Vec::new(),
                            coverage: 0.0,
                            re: seq,
                        };
                        send_response(out, response_cache, seq, response);
                    }
                    Some(index) => {
                        let out = out.clone();
                        tokio::spawn(async move {
                            let limit = usize::try_from(limit).unwrap_or(usize::MAX);
                            let matched = tokio::task::spawn_blocking(move || {
                                index.matches(&query, limit)
                            })
                            .await;
                            let response = match matched {
                                Ok((paths, coverage)) => Control::FsMatched {
                                    paths,
                                    coverage,
                                    re: seq,
                                },
                                Err(e) => error(seq, ErrorCode::Internal, e.to_string(), true),
                            };
                            let _ = out.send(Outbound::Control(response));
                        });
                    }
                }
            }
        }
        Control::UploadOpen {
            dest,
            size,
            sha256,
            mode,
            root,
            session,
            seq,
        } => {
            let response = if !connection.capabilities.contains("upload") {
                error(
                    seq,
                    ErrorCode::Denied,
                    "the upload capability was not negotiated",
                    false,
                )
            } else {
                match resolve_upload_dest(manager, &dest, root.as_deref(), session.as_deref())
                    .await
                {
                    Ok((resolved, session_id)) => {
                        match manager
                            .uploads
                            .open(resolved, size, &sha256, mode, session_id)
                        {
                            Ok((upload_id, offset)) => Control::UploadOpened {
                                upload_id,
                                offset,
                                re: seq,
                            },
                            Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                        }
                    }
                    Err((code, message)) => error(seq, code, message, false),
                }
            };
            send_response(out, response_cache, seq, response);
        }
        Control::UploadCommit {
            upload_id,
            if_unmodified_since,
            seq,
        } => {
            let response = if !connection.capabilities.contains("upload") {
                error(
                    seq,
                    ErrorCode::Denied,
                    "the upload capability was not negotiated",
                    false,
                )
            } else {
                match manager.uploads.commit(&upload_id, if_unmodified_since) {
                    Ok((path, mtime)) => Control::UploadCommitted {
                        path: path.display().to_string(),
                        mtime,
                        re: seq,
                    },
                    // A refused *version* is not a refused request: the client
                    // asks the person whether to overwrite, so it has to be
                    // able to tell this apart from a denial.
                    Err(e) if e.to_string().starts_with("conflict: ") => {
                        error(seq, ErrorCode::Conflict, format!("{e:#}"), false)
                    }
                    Err(e) => error(seq, ErrorCode::Denied, format!("{e:#}"), false),
                }
            };
            send_response(out, response_cache, seq, response);
        }
        Control::UploadAbort { upload_id, seq } => {
            // Aborting what is already gone is success, not failure — the
            // client is declaring disinterest, not asserting existence.
            manager.uploads.abort(&upload_id);
            send_response(out, response_cache, seq, Control::Ok { re: seq });
        }
        Control::Wait {
            target,
            until,
            timeout_ms,
            seq,
        } => {
            if !connection.capabilities.contains("send_wait") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the send_wait capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                let manager = manager.clone();
                let out = out.clone();
                tokio::spawn(async move {
                    let response = manager.wait_response(target, until, timeout_ms, seq).await;
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::SetStatus {
            id,
            status,
            title,
            transcript_path,
            conversation_id,
            tool,
            prompt_title,
            seq,
        } => {
            let details = crate::protocol::StatusDetails {
                transcript_path,
                conversation_id,
                tool,
                prompt_title,
            }
            .sanitized();
            let response = match manager.resolve(&id).await {
                Some(handle) => {
                    let (tx, rx) = oneshot::channel();
                    if handle.send(SessionMsg::SetStatus {
                        status: crate::protocol::normalize_status(&status).to_string(),
                        title,
                        details,
                        reply: tx,
                    }) && rx.await.is_ok()
                    {
                        Control::Ok { re: seq }
                    } else {
                        error(
                            seq,
                            ErrorCode::AlreadyExited,
                            "session already exited",
                            false,
                        )
                    }
                }
                None => error(
                    seq,
                    ErrorCode::NoSuchSession,
                    format!("no such session: {id}"),
                    false,
                ),
            };
            send_response(out, response_cache, seq, response);
        }
        Control::InstallAgents {
            agents,
            hooks,
            skills,
            reporter,
            hook_version,
            seq,
        } => {
            if !connection.capabilities.contains("agents") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the agents capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                let request = crate::agent::install::InstallRequest::new(
                    agents,
                    hooks,
                    skills,
                    reporter,
                    hook_version.unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string()),
                );
                // A dozen agents is a few dozen small reads, merges and renames.
                // That is blocking work, and it must not sit on the runtime that
                // is also carrying somebody's keystrokes.
                let out = out.clone();
                tokio::spawn(async move {
                    let installed =
                        tokio::task::spawn_blocking(move || crate::agent::install::run(&request))
                            .await;
                    let response = match installed {
                        Ok(results) => Control::AgentsInstalled { results, re: seq },
                        Err(e) => error(seq, ErrorCode::Internal, e.to_string(), true),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::ProbeAgents { agents, seq } => {
            if !connection.capabilities.contains("agents") {
                let response = error(
                    seq,
                    ErrorCode::Denied,
                    "the agents capability was not negotiated",
                    false,
                );
                send_response(out, response_cache, seq, response);
            } else {
                // The login-shell probe behind this can spawn a shell whose rc
                // takes seconds; it must not sit on the runtime carrying
                // keystrokes.
                let out = out.clone();
                tokio::spawn(async move {
                    let probed =
                        tokio::task::spawn_blocking(move || crate::agent::install::probe(agents))
                            .await;
                    let response = match probed {
                        Ok(agents) => Control::AgentsProbed { agents, re: seq },
                        Err(e) => error(seq, ErrorCode::Internal, e.to_string(), true),
                    };
                    let _ = out.send(Outbound::Control(response));
                });
            }
        }
        Control::Detach { .. } => return Ok(ControlFlow::Close),
        Control::RequestSnapshot { seq } => {
            let _ = out.send(Outbound::Control(error(
                seq,
                ErrorCode::ProtoError,
                "request_snapshot needs an active attachment on this channel",
                false,
            )));
        }
        Control::ClaimWriter { seq } => {
            // The token belongs to an attachment, and this channel has none —
            // the claim is only meaningful inside the attached loop.
            let _ = out.send(Outbound::Control(error(
                seq,
                ErrorCode::ProtoError,
                "claim_writer needs an active attachment on this channel",
                false,
            )));
        }
        Control::Hello { .. } => {
            let _ = out.send(Outbound::Control(error(
                None,
                ErrorCode::ProtoError,
                "hello must be the first control frame",
                false,
            )));
            return Ok(ControlFlow::Close);
        }
        // Unknown operations are ignored. Response-direction messages sent by
        // a client are likewise harmless and ignored.
        Control::Unknown
        | Control::HelloOk { .. }
        | Control::HelloErr { .. }
        | Control::Ok { .. }
        | Control::Created { .. }
        | Control::Sessions { .. }
        | Control::Attached { .. }
        | Control::Exited { .. }
        | Control::WaitResult { .. }
        | Control::ResizeClaim { .. }
        | Control::Subscribed { .. }
        | Control::FsListed { .. }
        | Control::FsFile { .. }
        | Control::FsMatched { .. }
        | Control::FsSearched { .. }
        | Control::GitDiffResult { .. }
        | Control::GitLogResult { .. }
        | Control::GitShowResult { .. }
        | Control::GitBranchesResult { .. }
        | Control::GitCompareResult { .. }
        | Control::UploadOpened { .. }
        | Control::UploadAck { .. }
        | Control::UploadCommitted { .. }
        | Control::AgentsInstalled { .. }
        | Control::AgentsProbed { .. }
        | Control::Error { .. } => {}
    }
    Ok(ControlFlow::Continue)
}

/// Stream one `fs.search` (§C.12): ripgrep's own searcher over the workspace
/// root, batched result events, one terminal `fs_searched` reply. Ends on
/// completion, on the limit, on `cancel`, or on the connection going away (the
/// cancel sender's map is dropped with it). Result events and the terminal
/// reply share `out`, which is what guarantees the reply is last.
///
/// The walk itself is blocking and runs on its own thread, so neither a tree
/// with a million files nor a file the searcher chokes on can stall the
/// runtime. Cancellation is a flag that thread reads rather than a signal —
/// there is no subprocess left to kill.
#[allow(clippy::too_many_arguments)]
async fn run_search(
    out: mpsc::UnboundedSender<Outbound>,
    searches: SearchMap,
    permits: Arc<tokio::sync::Semaphore>,
    mut cancel_rx: oneshot::Receiver<()>,
    _retained: Option<oneshot::Sender<()>>,
    root: String,
    query: String,
    limit: u64,
    seq: Option<u64>,
) {
    let request = seq.unwrap_or(0);
    let cleanup = |searches: &SearchMap| {
        if let Some(id) = seq {
            searches.lock().unwrap().remove(&id);
        }
    };

    let root = match crate::files::canonical_root(&root) {
        Ok(root) => root,
        Err(e) => {
            cleanup(&searches);
            let _ = out.send(Outbound::Control(error(
                seq,
                ErrorCode::Denied,
                format!("{e:#}"),
                false,
            )));
            return;
        }
    };

    // Wait for a slot before taking a blocking thread (see `search_permits`).
    // A search cancelled while it is still queued answers *now*: it has walked
    // nothing, and there is nothing to be gained by making the client wait out
    // the searches ahead of it.
    let permit = tokio::select! {
        slot = permits.clone().acquire_owned() => slot,
        _ = &mut cancel_rx => {
            cleanup(&searches);
            let _ = out.send(Outbound::Control(Control::FsSearched {
                matches: 0,
                limit_hit: false,
                canceled: true,
                re: seq,
            }));
            return;
        }
        // Nobody left to answer.
        _ = out.closed() => {
            cleanup(&searches);
            return;
        }
    };
    // The semaphore is never closed, so this cannot fail; refusing the search
    // is still better than unwrapping if that ever stops being true.
    let Ok(_permit) = permit else {
        cleanup(&searches);
        let _ = out.send(Outbound::Control(error(
            seq,
            ErrorCode::Internal,
            "the host is no longer accepting searches",
            true,
        )));
        return;
    };

    let cancel = Arc::new(AtomicBool::new(false));
    let flag = cancel.clone();
    let sink = out.clone();
    let mut worker = tokio::task::spawn_blocking(move || {
        crate::files::search(&root, &query, limit, &flag, &mut |matches| {
            let _ = sink.send(Outbound::Event(Event::SearchResults { request, matches }));
        })
    });

    // Either end of the client's interest stops the walk: an explicit `cancel`,
    // or the connection itself going away. The latter is not covered by
    // `cancel_rx` — a search addressed by a request id parks its cancel sender
    // in the shared map, and *this task* holds a reference to that map, so the
    // sender outlives the connection that owned it and the receiver never
    // resolves. Without this arm a client that hung up (a timeout, a keystroke
    // abandoning the query) leaves its walk running to completion, writing into
    // a channel nobody reads.
    let outcome = tokio::select! {
        finished = &mut worker => finished,
        _ = &mut cancel_rx => {
            cancel.store(true, Ordering::Relaxed);
            worker.await
        }
        _ = out.closed() => {
            cancel.store(true, Ordering::Relaxed);
            worker.await
        }
    };

    cleanup(&searches);
    let response = match outcome {
        Ok(outcome) => Control::FsSearched {
            matches: outcome.matches,
            limit_hit: outcome.limit_hit,
            canceled: outcome.canceled,
            re: seq,
        },
        // The search panicked. Nothing else on this connection is affected —
        // that is what the separate thread bought — but the client is owed the
        // failure rather than silence.
        Err(e) => error(seq, ErrorCode::Internal, format!("search failed: {e}"), true),
    };
    let _ = out.send(Outbound::Control(response));
}

/// Resolve an `upload.open` dest to a confined landing spot (§C.12): either
/// `temp:<name>` in the named session's scratch dir, or a path under a
/// caller-named project root. Returns the session id that owns a scratch
/// upload so the reaper can drop it with the session.
async fn resolve_upload_dest(
    manager: &Manager,
    dest: &str,
    root: Option<&str>,
    session: Option<&str>,
) -> std::result::Result<(crate::files::UploadDest, Option<SessionId>), (ErrorCode, String)> {
    if let Some(name) = dest.strip_prefix("temp:") {
        let Some(session) = session else {
            return Err((
                ErrorCode::Denied,
                "a temp: upload must name its session".to_string(),
            ));
        };
        let Some(handle) = manager.resolve(session).await else {
            return Err((
                ErrorCode::NoSuchSession,
                format!("no such session: {session}"),
            ));
        };
        let scratch = paths::session_scratch_dir(&handle.id)
            .map_err(|e| (ErrorCode::Internal, format!("{e:#}")))?;
        let resolved = crate::files::resolve_scratch_dest(&scratch, name)
            .map_err(|e| (ErrorCode::Denied, format!("{e:#}")))?;
        return Ok((resolved, Some(handle.id.clone())));
    }
    let Some(root) = root else {
        return Err((
            ErrorCode::Denied,
            "a project upload must name its workspace root".to_string(),
        ));
    };
    let resolved = crate::files::resolve_project_dest(root, dest)
        .map_err(|e| (ErrorCode::Denied, format!("{e:#}")))?;
    Ok((resolved, None))
}

/// Ship an `fs.read` window as `F` chunks: 64 KiB fair-write pieces, the last
/// one flagged, and an empty flagged chunk for an empty window so the client
/// always has one uniform termination signal.
fn send_file_chunks(out: &mpsc::UnboundedSender<Outbound>, re: u64, offset: u64, data: &[u8]) {
    let piece = MAX_FILE_FRAME_SIZE - FILE_CHUNK_HEADER_SIZE;
    let mut sent = 0usize;
    loop {
        let end = (sent + piece).min(data.len());
        let chunk = FileChunk {
            re,
            offset: offset + sent as u64,
            last: end == data.len(),
            data: data[sent..end].to_vec(),
        };
        match encode_file_chunk(&chunk) {
            Ok(payload) => {
                if out.send(Outbound::File(Bytes::from(payload))).is_err() {
                    return;
                }
            }
            Err(e) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::Internal,
                    e.to_string(),
                    true,
                )));
                return;
            }
        }
        if end == data.len() {
            return;
        }
        sent = end;
    }
}

fn send_response(
    out: &mpsc::UnboundedSender<Outbound>,
    cache: &mut HashMap<u64, Control>,
    seq: Option<u64>,
    response: Control,
) {
    if let Some(seq) = seq {
        cache.insert(seq, response.clone());
    }
    let _ = out.send(Outbound::Control(response));
}

/// Copy every status the session actors emit into the `status:` resource ring.
///
/// One task, so the resource has one writer and its `seq` is an order rather
/// than a race between actors. It runs whether or not anyone has subscribed:
/// the ring is written regardless, because that is what a client resumes from
/// after it locked its phone (`resource.rs`, §C.10 linger).
///
/// A lagged broadcast receiver is the one case worth naming. The channel is
/// bounded, so a pump that fell behind has genuinely lost transitions — and
/// silently skipping them would leave a subscriber's cursor claiming a
/// continuity it does not have. Publishing nothing is right: the missed
/// transitions age out of nobody's ring, and the next real status re-states the
/// session's state anyway.
async fn pump_status_resource(
    mut events: broadcast::Receiver<Event>,
    resources: crate::resource::Registry,
) {
    loop {
        let event = match events.recv().await {
            Ok(event) => event,
            Err(broadcast::error::RecvError::Lagged(missed)) => {
                eprintln!("termiod: status resource pump missed {missed} event(s)");
                continue;
            }
            Err(broadcast::error::RecvError::Closed) => return,
        };
        let batch = match event {
            Event::Status {
                session,
                status,
                source,
                turn_ended,
                blocking,
                title,
                ..
            } => crate::resource::StatusBatch {
                session,
                status,
                source,
                turn_ended,
                blocking,
                title,
                stalled: None,
            },
            Event::Stalled {
                session,
                working_seconds,
                transcript_lines_grown,
            } => crate::resource::StatusBatch {
                session,
                // A stall never moves the status: from outside an agent a quiet
                // long build and a wedged loop look the same, which is why this
                // plane signals and never kills.
                status: "working".to_string(),
                source: None,
                turn_ended: false,
                blocking: false,
                title: None,
                stalled: Some(crate::resource::StatusStall {
                    working_seconds,
                    transcript_lines_grown,
                }),
            },
            _ => continue,
        };
        resources.publish_status(batch);
    }
}

fn subscribed_to(subscriptions: &HashSet<String>, event: &Event) -> bool {
    match event {
        // A stall is status the roster reads the same way it reads any other:
        // it is about a session, not about one attachment's stream. It rides
        // the `status` subscription rather than its own so a client that wants
        // agent state does not have to ask twice.
        Event::Status { .. } | Event::Stalled { .. } => subscriptions.contains("status"),
        Event::Roster { .. } | Event::WriterChanged { .. } | Event::SessionExited { .. } => {
            subscriptions.contains("roster")
        }
        Event::Resized { .. } => false,
        Event::Ready { .. } => false,
        // Both are addressed to one attachment's stream, not to the roster: a
        // resync is that client's own, and a stale VT only means anything to a
        // client that was going to ask for a snapshot.
        Event::Resynced { .. } | Event::VtStale { .. } => false,
        // Resource events are delivered on the subscriber's own channel, not
        // through the roster broadcast, so they never match here.
        Event::FsChanged { .. }
        | Event::GitChanged { .. }
        | Event::StatusChanged { .. }
        | Event::SearchResults { .. } => false,
        Event::Unknown => false,
    }
}

/// Bridge one attached client to a session. Disconnect removes only the
/// attachment; the session continues.
async fn run_attach(
    mut rd: tokio::net::unix::OwnedReadHalf,
    out: mpsc::UnboundedSender<Outbound>,
    request: AttachRequest,
    connection: Connection,
    backlog: Arc<ClientBacklog>,
) -> Result<()> {
    let handle = request.handle;
    let client_id = connection.client_id;
    let (client_out, mut client_events) = mpsc::unbounded_channel::<ClientEvent>();
    let (reply_tx, reply_rx) = oneshot::channel();
    handle.send(SessionMsg::AddClient {
        id: client_id.clone(),
        interactive: request.mode == AttachMode::Interact,
        // The attach's own grid is this attachment's opening viewport
        // declaration, not an instruction to resize the PTY. The session's size
        // is derived from every rendering viewport at once.
        rows: request.rows,
        cols: request.cols,
        out: client_out,
        backlog: backlog.clone(),
        snapshot: connection.capabilities.contains("snapshot"),
        scrollback: connection.capabilities.contains("snapshot")
            && connection.capabilities.contains("scrollback"),
        grid_diff: connection.capabilities.contains("snapshot")
            && connection.capabilities.contains("grid_diff"),
        reply: reply_tx,
    });
    let added = reply_rx.await.context("session ended while attaching")?;
    let name = {
        let (tx, rx) = oneshot::channel();
        handle.send(SessionMsg::Info { reply: tx });
        rx.await
            .map(|info| info.name)
            .unwrap_or_else(|_| handle.id.to_string())
    };
    let _ = out.send(Outbound::Control(Control::Attached {
        id: handle.id.to_string(),
        name,
        session_id: handle.id.to_string(),
        writer: added.writer,
        rows: added.rows,
        cols: added.cols,
        re: request.re,
    }));

    let supports_events = connection.capabilities.contains("events");
    let supports_snapshot = connection.capabilities.contains("snapshot");
    let supports_scrollback = supports_snapshot && connection.capabilities.contains("scrollback");
    let supports_grid_diff = supports_snapshot && connection.capabilities.contains("grid_diff");
    let negotiated = connection.negotiated;
    let event_out = out.clone();
    let session_id = handle.id.to_string();
    let bridge_backlog = backlog;
    let mut bridge = tokio::spawn(async move {
        while let Some(event) = client_events.recv().await {
            match event {
                ClientEvent::Data(payload) => {
                    if event_out.send(Outbound::Data(payload.clone())).is_err() {
                        bridge_backlog.release(&payload);
                        break;
                    }
                }
                ClientEvent::Snapshot(snapshot) if supports_snapshot => {
                    if event_out.send(Outbound::Snapshot(snapshot)).is_err() {
                        break;
                    }
                }
                ClientEvent::Snapshot(_) => {}
                ClientEvent::History(payload) if supports_scrollback => {
                    if event_out.send(Outbound::History(payload.clone())).is_err() {
                        bridge_backlog.release(&payload);
                        break;
                    }
                }
                ClientEvent::History(payload) => bridge_backlog.release(&payload),
                ClientEvent::Grid(payload) if supports_grid_diff => {
                    if event_out.send(Outbound::Grid(payload.clone())).is_err() {
                        bridge_backlog.release(&payload);
                        break;
                    }
                }
                ClientEvent::Grid(payload) => bridge_backlog.release(&payload),
                ClientEvent::Control(control) if negotiated => {
                    if event_out.send(Outbound::Control(control)).is_err() {
                        break;
                    }
                }
                ClientEvent::Control(_) => {}
                ClientEvent::Event(event @ Event::Ready { .. }) if supports_snapshot => {
                    if event_out.send(Outbound::Event(event)).is_err() {
                        break;
                    }
                }
                ClientEvent::Event(event) if supports_events => {
                    if event_out.send(Outbound::Event(event)).is_err() {
                        break;
                    }
                }
                ClientEvent::Event(_) => {}
                ClientEvent::Exited(status) => {
                    let _ = event_out.send(Outbound::Control(Control::Exited {
                        id: session_id.clone(),
                        status,
                    }));
                    break;
                }
            }
        }
    });

    loop {
        let frame = tokio::select! {
            _ = &mut bridge => break,
            frame = read_frame(&mut rd) => frame,
        };
        match frame {
            Ok(Some(Frame::Data(data))) => {
                // The same window `Send` and `Kill` answer `busy` for, reached
                // by the other door: a client typing into an attachment whose
                // actor has already handed over its PTY. There is nothing to
                // answer here — an attachment is a stream, not a request — so
                // the honest move is to say the attachment is over and let the
                // client reattach. Swallowing the keystrokes would leave someone
                // typing into a window that stopped listening without saying so.
                if !handle.send(SessionMsg::Input {
                    id: client_id.clone(),
                    data,
                }) {
                    let _ = out.send(Outbound::Control(error(
                        None,
                        ErrorCode::Busy,
                        "this session is being handed to a new daemon; reattach to keep typing",
                        true,
                    )));
                    break;
                }
            }
            Ok(Some(Frame::Viewport {
                rows,
                cols,
                rendering,
            })) => {
                handle.send(SessionMsg::Viewport {
                    id: client_id.clone(),
                    rows,
                    cols,
                    rendering,
                });
            }
            // Version skew, not a broken pipe: the request fails, the
            // attachment lives on.
            Ok(Some(Frame::UnknownControl { op, seq })) => {
                let _ = out.send(Outbound::Control(error(
                    seq,
                    ErrorCode::ProtoError,
                    format!("unknown op: {op}"),
                    false,
                )));
            }
            Ok(Some(Frame::Snapshot(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "snapshot frames are host-to-client only",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::History(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "history frames are host-to-client only",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::Grid(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "grid-diff frames are host-to-client only",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::File(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "file frames are host-to-client only",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::Upload(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    "upload frames ride the control channel, not an attachment",
                    false,
                )));
                break;
            }
            Ok(Some(Frame::Control(Control::Detach { .. }))) => break,
            Ok(Some(Frame::Control(Control::ClaimWriter { seq }))) => {
                let (reply_tx, reply_rx) = oneshot::channel();
                handle.send(SessionMsg::ClaimWriter {
                    id: client_id.clone(),
                    reply: reply_tx,
                });
                // The grant itself reaches every attachment as `writer_changed`;
                // this reply only tells the asker whether it was eligible, so a
                // client that is refused can say "read-only" rather than
                // silently dropping the keystrokes that follow.
                let granted = reply_rx.await.unwrap_or(false);
                let response = if granted {
                    Control::Ok { re: seq }
                } else {
                    error(
                        seq,
                        ErrorCode::NotWriter,
                        "an observer cannot hold the write token",
                        false,
                    )
                };
                let _ = out.send(Outbound::Control(response));
            }
            Ok(Some(Frame::Control(Control::RequestSnapshot { seq }))) => {
                if supports_snapshot {
                    handle.send(SessionMsg::ResendSnapshot {
                        id: client_id.clone(),
                    });
                    let _ = out.send(Outbound::Control(Control::Ok { re: seq }));
                } else {
                    // The snapshot plane was never negotiated on this
                    // attachment, so there is nothing to answer with — say so
                    // rather than leaving the client waiting for a repaint.
                    let _ = out.send(Outbound::Control(error(
                        seq,
                        ErrorCode::ProtoError,
                        "this attachment did not negotiate snapshots",
                        false,
                    )));
                }
            }
            Ok(Some(Frame::Control(Control::Unknown))) => {}
            Ok(Some(Frame::Event(event))) => drop(event),
            Ok(Some(Frame::Control(_))) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::Busy,
                    "attachment is already active on this channel",
                    false,
                )));
            }
            Ok(None) => break,
            Err(e) => {
                let _ = out.send(Outbound::Control(error(
                    None,
                    ErrorCode::ProtoError,
                    e.to_string(),
                    false,
                )));
                break;
            }
        }
    }

    handle.send(SessionMsg::RemoveClient { id: client_id });
    bridge.abort();
    Ok(())
}

/// Every `git:` verb is behind the one capability (§C.13), so they share one
/// gate: `Some(error)` when the channel never negotiated it.
fn git_denied(connection: &Connection, seq: Option<u64>) -> Option<Control> {
    if connection.capabilities.contains("git") {
        return None;
    }
    Some(error(
        seq,
        ErrorCode::Denied,
        "the git capability was not negotiated",
        false,
    ))
}

fn error(re: Option<u64>, code: ErrorCode, message: impl Into<String>, retryable: bool) -> Control {
    Control::Error {
        re,
        code,
        message: message.into(),
        retryable,
    }
}

#[cfg(test)]
mod bind_probe_tests {
    #[test]
    fn only_refused_and_missing_mean_a_stale_socket() {
        assert!(super::socket_is_stale(Some(libc::ECONNREFUSED)));
        assert!(super::socket_is_stale(Some(libc::ENOENT)));
        assert!(!super::socket_is_stale(Some(libc::EPERM)));
        assert!(!super::socket_is_stale(Some(libc::EACCES)));
        assert!(!super::socket_is_stale(None));
    }
}

#[cfg(test)]
mod search_queue_tests {
    use super::*;

    /// The bound in front of the blocking pool must not swallow a `cancel`.
    ///
    /// Every permit is held here, so the search under test can only be queued —
    /// which is the state the bound introduced and the one that would otherwise
    /// make a cancel arrive whenever the searches ahead of it happened to
    /// finish. It answers on the cancel instead, having walked nothing.
    #[tokio::test]
    async fn a_search_cancelled_while_queued_answers_without_waiting_for_a_slot() {
        let permits = Arc::new(tokio::sync::Semaphore::new(1));
        let held = permits.clone().acquire_owned().await.expect("take the only slot");

        let (out, mut replies) = mpsc::unbounded_channel();
        let searches: SearchMap = Arc::new(Mutex::new(HashMap::new()));
        let (cancel_tx, cancel_rx) = oneshot::channel();
        searches.lock().unwrap().insert(7, cancel_tx);

        // A directory of its own, not the temp root: if the queue ever stops
        // holding this search back, the test should notice by failing rather
        // than by walking everything under /tmp.
        let root = std::env::temp_dir().join(format!("termiod-queue-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("a root to search");
        let root = root.to_string_lossy().into_owned();
        let running = tokio::spawn(run_search(
            out,
            searches.clone(),
            permits,
            cancel_rx,
            None,
            root,
            "needle".to_string(),
            1000,
            Some(7),
        ));

        // Queued means silent: nothing has been searched, so nothing is owed
        // until the client says how it wants this to end.
        tokio::task::yield_now().await;
        assert!(replies.try_recv().is_err(), "a queued search reports nothing");

        let cancel = searches.lock().unwrap().remove(&7).expect("the search registered itself");
        let _ = cancel.send(());

        let reply = tokio::time::timeout(Duration::from_secs(5), replies.recv())
            .await
            .expect("a queued search must answer its cancel without waiting for a slot")
            .expect("a terminal reply");
        match reply {
            Outbound::Control(Control::FsSearched {
                matches,
                limit_hit,
                canceled,
                re,
            }) => {
                assert_eq!(matches, 0);
                assert!(!limit_hit);
                assert!(canceled);
                assert_eq!(re, Some(7));
            }
            _ => panic!("a cancelled search ends with fs_searched"),
        }
        assert!(
            searches.lock().unwrap().is_empty(),
            "a cancelled search must not leave its slot in the map"
        );

        running.await.expect("the search task ends with its reply");
        drop(held);
    }
}
