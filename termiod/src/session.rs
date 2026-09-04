//! A single durable session: one PTY, one child process group, and a set of
//! attached clients. It runs as an actor whose lifetime is independent of any
//! connection — detach never kills it.

use crate::protocol::{
    encode_grid_payload, Control, ErrorCode, Event, GridDiff, SessionInfo, Snapshot, WorkstreamSpec,
};
use crate::id::{ClientId, SessionId};
use crate::pty::Pty;
use crate::tombstone::EndReason;
use bytes::Bytes;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc, oneshot};

const RING_CAP: usize = 128 * 1024;
const READ_CHUNK: usize = 64 * 1024;
pub const KEYFRAME_EVERY_FRAMES: u32 = 256;
mod backlog;

pub(crate) use backlog::{ClientBacklog, Metered};

mod sidecar;

pub(crate) use sidecar::{SidecarCapture, SidecarCommand, SidecarQueue, SidecarResult, Vt};

mod foreground;

use foreground::{Foreground, ForegroundResolution};

pub mod status;

use status::{OscScanner, OscSignal, StallStep, StatusEngine};

mod wire;

use wire::{
    encode_scrollback_chunks, grid_from_damage, scrollback_row_limit, wire_cell,
    SCROLLBACK_STAGE_MAX_BYTES,
};

/// Pushed to an attached connection task.
#[derive(Clone)]
pub enum ClientEvent {
    Data(Metered),
    Snapshot(Snapshot),
    History(Metered),
    Grid(Metered),
    Control(Control),
    Event(Event),
    Exited(i32),
}

pub struct AddClientReply {
    pub writer: bool,
    pub rows: u16,
    pub cols: u16,
}

/// Messages accepted by a running session task.
pub enum SessionMsg {
    AddClient {
        id: ClientId,
        interactive: bool,
        /// The viewport the attach control declared. Zero in either dimension
        /// is "not laid out yet"; the first `R` says what it is.
        rows: u16,
        cols: u16,
        out: mpsc::UnboundedSender<ClientEvent>,
        backlog: Arc<ClientBacklog>,
        snapshot: bool,
        scrollback: bool,
        grid_diff: bool,
        reply: oneshot::Sender<AddClientReply>,
    },
    /// A client asks to be repainted: it lost bytes somewhere downstream and
    /// cannot reconstruct the screen from what it has.
    ResendSnapshot { id: ClientId },
    /// A client asks for the write token because its user is typing. Refused
    /// for an observer, which by §A never holds it.
    ClaimWriter {
        id: ClientId,
        reply: oneshot::Sender<bool>,
    },
    RemoveClient {
        id: ClientId,
    },
    /// Interactive input from an attached client.
    Input {
        id: ClientId,
        data: Vec<u8>,
    },
    /// One attachment's viewport changed, or it started or stopped rendering.
    /// The PTY's size is derived from the whole set (`apply_size_policy`); this
    /// message never sets it directly.
    Viewport {
        id: ClientId,
        rows: u16,
        cols: u16,
        rendering: bool,
    },
    /// `termiod send` — inject input without attaching. Always applied.
    Inject {
        data: Vec<u8>,
    },
    SetStatus {
        status: String,
        title: Option<String>,
        /// The four per-report facts. Deliberately *not* stored on the session:
        /// they describe one report, not the session's state, and a stale
        /// transcript path surviving in `SessionInfo` would be a fact nobody
        /// re-checked. They ride the event and are gone.
        details: crate::protocol::StatusDetails,
        reply: oneshot::Sender<()>,
    },
    Info {
        reply: oneshot::Sender<SessionInfo>,
    },
    /// The daemon is about to replace its own image and needs this session's
    /// PTY on a descriptor that survives the `execve`. The actor answers and
    /// stops — without killing anything, and without a burial: the process in
    /// there is about to be someone else's to read.
    Carry {
        reply: oneshot::Sender<Carried>,
    },
    Kill {
        reason: EndReason,
    },
}

/// What the manager needs to bury a session (§6). The session actor is the last
/// thing that can answer `Info` — by the time the manager hears about the exit
/// the actor is gone — so the record travels *with* the notification instead of
/// being asked for afterwards.
pub struct SessionEnded {
    pub info: SessionInfo,
    pub status: i32,
    pub reason: EndReason,
}

/// Cheap, cloneable reference to a session task.
#[derive(Clone)]
pub struct SessionHandle {
    pub id: SessionId,
    pid: i32,
    tx: mpsc::UnboundedSender<SessionMsg>,
    /// PTY EOF can become ready in the same scheduler turn as `Kill`; keeping
    /// the first requested reason outside the queue makes that race deterministic.
    termination_reason: Arc<Mutex<Option<EndReason>>>,
}

impl SessionHandle {
    pub fn send(&self, msg: SessionMsg) -> bool {
        if let SessionMsg::Kill { reason } = &msg {
            let mut requested = self.termination_reason.lock().unwrap();
            if requested.is_none() {
                *requested = Some(*reason);
            }
        }
        self.tx.send(msg).is_ok()
    }

    pub fn termination_reason(&self) -> Option<EndReason> {
        *self.termination_reason.lock().unwrap()
    }

    /// A session actor normally owns termination and reports the exact reason.
    /// This is only for the shutdown deadline: killing the process releases the
    /// blocking child waiter even if the actor itself stopped making progress.
    pub fn force_kill(&self) {
        unsafe {
            libc::kill(-self.pid, libc::SIGKILL);
        }
    }
}

struct ClientEntry {
    out: mpsc::UnboundedSender<ClientEvent>,
    backlog: Arc<ClientBacklog>,
    role: ClientRole,
    plane: ClientPlane,
    /// What this attachment says it is showing, and whether it is showing it.
    ///
    /// `None` is an attachment with no viewport at all — it has not laid out
    /// yet, or it never will (a relay with no surface that declines to speak
    /// for the one downstream of it). `rendering` is the other axis: a Mac pane
    /// on a background tab keeps its viewport and stops counting, so the
    /// session springs back to the width of whoever is still looking.
    viewport: Option<(u16, u16)>,
    rendering: bool,
    /// Where this attachment sits in most-recently-used order (`note_use`).
    /// The session sizes to the highest one that is rendering: the screen a
    /// person is actually in front of.
    used: u64,
    /// Attach-only history staging. Resize barriers discard any remainder and
    /// deliberately do not restage it; resize/reflow history is a later policy.
    staged_history: VecDeque<Bytes>,
    /// Backlog strikes taken by this attachment. The first buys a forced
    /// resync; the second is the drop. Strikes are never forgiven — the resync
    /// already zeroed the count of what the client owes, so a second overflow
    /// means it could not keep up even from a clean start.
    backlog_strikes: u32,
}

/// Whether this attachment can hold the write token.
enum ClientRole {
    /// Attached without a tty. §A: an observer never claims the token, and it
    /// never counts toward the session's size — there is no screen behind it
    /// whose viewport either could be about.
    Observer,
    /// Attached with a tty. `seq` is interactive attach order — the highest
    /// takes the token back when the current holder leaves. Only interactive
    /// attachments are numbered, because only they are ever compared.
    Interactive { seq: u64 },
}

impl ClientRole {
    fn is_interactive(&self) -> bool {
        matches!(self, ClientRole::Interactive { .. })
    }

    /// The attach order to rank this client by, or `None` for an attachment
    /// that is not in the running for the token at all.
    fn attach_seq(&self) -> Option<u64> {
        match self {
            ClientRole::Observer => None,
            ClientRole::Interactive { seq } => Some(*seq),
        }
    }
}

/// Which plane the attachment reads, and — for the two that have one — where it
/// stands relative to its snapshot boundary.
///
/// This is the negotiated capability pair made exclusive. `grid_diff` without
/// `snapshot` was never a state the host would run: the parsed plane bootstraps
/// and recovers through `S`, so the daemon drops the capability at hello and
/// `AddClient` dropped it again. There is now no fourth case to drop.
enum ClientPlane {
    /// Never negotiated `snapshot`: raw PTY bytes only, ring replay on attach.
    /// No boundary to stand behind, so no barrier and nothing to resync to —
    /// which is why this variant carries no delivery state at all.
    Raw,
    /// Negotiated `snapshot`: raw PTY bytes, punctuated by `S` boundaries on
    /// attach, resize and resync.
    Snapshot(ClientDelivery),
    /// Negotiated `snapshot` + `grid_diff`: server-parsed cells and keyframes,
    /// never downstream PTY bytes.
    Grid(ClientDelivery),
}

impl ClientPlane {
    fn snapshots(&self) -> bool {
        !matches!(self, ClientPlane::Raw)
    }

    fn is_grid(&self) -> bool {
        matches!(self, ClientPlane::Grid(_))
    }

    /// Where this attachment stands relative to its snapshot boundary. `None`
    /// for a raw attachment, which has no boundary and is live by construction.
    fn delivery(&self) -> Option<&ClientDelivery> {
        match self {
            ClientPlane::Raw => None,
            ClientPlane::Snapshot(delivery) | ClientPlane::Grid(delivery) => Some(delivery),
        }
    }

    fn delivery_mut(&mut self) -> Option<&mut ClientDelivery> {
        match self {
            ClientPlane::Raw => None,
            ClientPlane::Snapshot(delivery) | ClientPlane::Grid(delivery) => Some(delivery),
        }
    }

    /// The request this attachment is waiting on, if it is behind a barrier.
    fn pending_request(&self) -> Option<u64> {
        match self.delivery() {
            Some(ClientDelivery::SnapshotPending { request_id, .. }) => Some(*request_id),
            _ => None,
        }
    }

    fn is_pending(&self) -> bool {
        self.pending_request().is_some()
    }

    /// Open a snapshot barrier. Events already deferred behind an older barrier
    /// carry over — they are still owed — while the data buffered behind it is
    /// handed back, because the snapshot that is coming supersedes it and the
    /// caller decides whether to credit those bytes or retire them.
    ///
    /// A raw attachment has no barrier to open; nothing calls this for one, and
    /// it is a no-op if anything ever does.
    fn begin_pending(&mut self, request_id: u64) -> VecDeque<Metered> {
        let Some(delivery) = self.delivery_mut() else {
            return VecDeque::new();
        };
        let (superseded, deferred) = match std::mem::replace(delivery, ClientDelivery::Live) {
            ClientDelivery::Live => (VecDeque::new(), VecDeque::new()),
            ClientDelivery::SnapshotPending { data, deferred, .. } => (data, deferred),
        };
        *delivery = ClientDelivery::SnapshotPending {
            request_id,
            data: VecDeque::new(),
            deferred,
        };
        superseded
    }

    /// Queue an event behind this attachment's open barrier. `false` when there
    /// is no barrier and the caller should send it straight out.
    fn defer(&mut self, event: ClientEvent) -> bool {
        match self.delivery_mut() {
            Some(ClientDelivery::SnapshotPending { deferred, .. }) => {
                deferred.push_back(event);
                true
            }
            _ => false,
        }
    }

    /// Close an open barrier, leaving the attachment live, and hand back what
    /// was queued behind it: the buffered data and the deferred events, in that
    /// order. Empty queues for an attachment that had no barrier open.
    fn settle(&mut self) -> (VecDeque<Metered>, VecDeque<ClientEvent>) {
        let Some(delivery) = self.delivery_mut() else {
            return (VecDeque::new(), VecDeque::new());
        };
        match std::mem::replace(delivery, ClientDelivery::Live) {
            ClientDelivery::SnapshotPending { data, deferred, .. } => (data, deferred),
            ClientDelivery::Live => (VecDeque::new(), VecDeque::new()),
        }
    }
}

enum ClientDelivery {
    Live,
    SnapshotPending {
        request_id: u64,
        data: VecDeque<Metered>,
        deferred: VecDeque<ClientEvent>,
    },
}

struct Session {
    id: SessionId,
    name: String,
    cwd: String,
    command: String,
    pid: i32,
    rows: u16,
    cols: u16,
    created_unix: u64,
    status: String,
    title: Option<String>,
    workstream: Option<WorkstreamSpec>,
    pty: Arc<Pty>,
    /// A dedicated writer prevents blocked PTY writes from stalling reads.
    input_tx: mpsc::UnboundedSender<Vec<u8>>,
    clients: HashMap<ClientId, ClientEntry>,
    writer: Option<ClientId>,
    next_seq: u64,
    /// Ticks on every `note_use`, ordering attachments by when a person was
    /// last on them. A counter rather than a clock: it only ever needs to be
    /// compared, and a monotonic integer is the same answer in a test as it is
    /// under a wall clock that jumped.
    use_clock: u64,
    next_snapshot_request: u64,
    ring: VecDeque<Bytes>,
    ring_bytes: usize,
    /// Whether the ring, replayed from its start into a blank terminal of the
    /// current size, still reconstructs this screen.
    ///
    /// It stops being true the moment the ring evicts a chunk (the bytes that
    /// drew what is still on screen may be the ones dropped) or the session is
    /// resized (the bytes that remain were written into a differently shaped
    /// grid, and replaying them into this one lands them elsewhere).
    ///
    /// Nothing about *this* daemon reads it: the live VT has been fed every
    /// byte as it arrived and answers snapshots from what it holds, not from a
    /// replay. It exists for the far side of a handoff, which has only the ring
    /// and would otherwise present a confidently wrong screen.
    ring_reconstructs_screen: bool,
    /// When the last resize's dust should be declared settled and the
    /// foreground asked for one more repaint. Bytes drawn for the old grid can
    /// still be in flight through the PTY when the VT takes the new one —
    /// nothing orders a child's output against a resize it has not seen yet —
    /// and whatever they painted, only the child's own post-settle repaint can
    /// overwrite. Every further resize pushes the deadline out, so a drag
    /// costs one nudge, at the end. (cmux's mirror answers the same problem by
    /// re-reading tmux's screen after a grid grows; the child *is* our tmux.)
    settle_nudge_at: Option<tokio::time::Instant>,
    events: broadcast::Sender<Event>,
    vt: Vt,
    /// This session's agent status, derived here rather than in each viewer.
    /// See `session/status.rs` and
    /// `docs/design/20260831-companion-second-protocol-retires.md` §3.
    status_engine: StatusEngine,
    /// The transcript address the last hook report carried, kept for the stall
    /// detector's probe 3. Deliberately not on `SessionInfo`: it describes one
    /// report, and a stale path surviving in a roster is a fact nobody
    /// re-checked.
    transcript_path: Option<String>,
    /// Who is in the tty's foreground and where the child is standing.
    /// `info()` reads this cache so a roster request never turns into a burst
    /// of syscalls.
    foreground: Foreground,
    /// A resize's barrier, opened but not yet captured. See
    /// `begin_resize_snapshot_barrier`.
    resize_capture: Option<ResizeCapture>,
}

/// The snapshot a resize opened a barrier for, waiting on the child's redraw.
struct ResizeCapture {
    at: tokio::time::Instant,
    requests: Vec<(ClientId, u64)>,
}

impl Session {
    fn info(&self) -> SessionInfo {
        SessionInfo {
            id: self.id.to_string(),
            name: self.name.clone(),
            cwd: self.cwd.clone(),
            command: self.command.clone(),
            pid: self.pid,
            rows: self.rows,
            cols: self.cols,
            clients: self.clients.len(),
            created_unix: self.created_unix,
            alive: true,
            status: self.status.clone(),
            agent_id: self.workstream.as_ref().map(|w| w.agent_id.clone()),
            project: self.workstream.as_ref().map(|w| w.project.clone()),
            title: self.title.clone(),
            attached_clients: self.clients.len(),
            writer_client_id: self.writer.as_ref().map(ClientId::to_string),
            foreground_pid: self.foreground.current().pid,
            foreground_argv: self.foreground.current().argv.clone(),
            foreground_job: self.foreground.current().job,
            child_cwd: self.foreground.current().cwd.clone(),
            child_executable: self.foreground.executable_path(),
            child_executable_replaced: self.foreground.executable_replaced(),
        }
    }

    fn recompute_writer(&mut self) {
        self.writer = self
            .clients
            .iter()
            .filter_map(|(id, entry)| entry.role.attach_seq().map(|seq| (id, seq)))
            .max_by_key(|(_, seq)| *seq)
            .map(|(id, _)| id.clone());
    }

    /// The write token only ever moves through here, and only ever onto a
    /// client that attached with a tty. Returns whether the claim was allowed.
    fn grant_writer(&mut self, id: &ClientId) -> bool {
        if !self
            .clients
            .get(id)
            .is_some_and(|entry| entry.role.is_interactive())
        {
            return false;
        }
        self.writer = Some(id.clone());
        true
    }

    fn allocate_snapshot_request(&mut self) -> u64 {
        let request_id = self.next_snapshot_request;
        self.next_snapshot_request = self.next_snapshot_request.wrapping_add(1);
        request_id
    }

    /// Pack this session for a handoff and give up the actor's claim on it.
    ///
    /// The PTY master is *duplicated* rather than surrendered. The copy names
    /// the same open file description — the same master, the same termios, the
    /// same foreground process group — while the original stays with the `Pty`
    /// and closes normally when this actor drops. Handing out the raw number
    /// instead would leave the new image reading a descriptor the old one had
    /// already closed.
    ///
    /// The copy is handed over *owned*, so that a `Carried` nobody takes is a
    /// session hung up rather than a descriptor orphaned.
    fn into_carried(self) -> anyhow::Result<Carried> {
        let master = crate::handoff::duplicate_for_exec(self.pty.master_fd())?;
        let ring: Vec<Bytes> = self.ring.iter().cloned().collect();
        Ok(Carried {
            info: crate::handoff::CarriedSession {
                id: self.id.to_string(),
                name: self.name.clone(),
                cwd: self.cwd.clone(),
                command: self.command.clone(),
                pid: self.pid,
                rows: self.rows,
                cols: self.cols,
                created_unix: self.created_unix,
                status: self.status.clone(),
                title: self.title.clone(),
                workstream: self.workstream.clone(),
                // Assigned by `handoff::pack`, at the moment this session is
                // committed to the blob.
                master_fd: -1,
                ring_len: self.ring_bytes as u64,
                ring_reconstructs_screen: self.ring_reconstructs_screen,
                status_clocks: self.status_engine.carried_clocks(std::time::Instant::now()),
            },
            master,
            ring,
        })
    }

    fn push_ring(&mut self, data: Bytes) {
        self.ring_bytes += data.len();
        self.ring.push_back(data);
        while self.ring_bytes > RING_CAP {
            if let Some(evicted) = self.ring.pop_front() {
                self.ring_bytes -= evicted.len();
                self.ring_reconstructs_screen = false;
            }
        }
    }

    fn send_sidecar(&mut self, command: SidecarCommand) -> bool {
        let was_live = self.vt.is_live();
        let sent = self.vt.send(command);
        if !sent && was_live {
            eprintln!("termiod: VT sidecar for session {} stopped", self.id);
        }
        sent
    }

    /// The one path that puts PTY bytes into the VT. It is budgeted, and the
    /// only legal degrade is to stop feeding the VT and say so — dropping bytes
    /// silently would leave `S` describing a screen that never occurred, and
    /// blocking here would put the VT parse back on the fan-out path.
    fn write_sidecar(&mut self, chunk: Bytes) {
        // The child answering its SIGWINCH is the event a resize's capture is
        // actually waiting for; the deadline is only there for a child that
        // never answers. Pulling the capture in the moment it does keeps the
        // wait off the common path — a TUI writes within a millisecond of the
        // ioctl — so `E resized` is not held up behind a clock every viewer of
        // this session would feel.
        if let Some(capture) = self.resize_capture.as_mut() {
            capture.at = capture
                .at
                .min(tokio::time::Instant::now() + Self::RESIZE_ANSWER_QUIESCE);
        }
        if !self.vt.is_live() {
            return;
        }
        let len = chunk.len();
        if !self.vt.try_reserve(len) {
            self.mark_vt_stale(format!(
                "VT sidecar fell more than {} behind the PTY",
                sidecar::cap_description()
            ));
            return;
        }
        if !self.send_sidecar(SidecarCommand::Write(chunk)) {
            self.vt.release(len);
        }
    }

    /// Tell the sidecar what this session's status engine needs sampled. Called
    /// whenever the resolved agent changes, so a shell promoted to a
    /// hand-started agent starts paying for a screen read and a demoted one
    /// stops.
    fn sync_status_watch(&mut self) {
        let screen = self.status_engine.wants_screen_watch();
        let text = self.status_engine.wants_screen_text();
        self.send_sidecar(SidecarCommand::SetStatusWatch { screen, text });
    }

    /// Re-resolve the session's agent against what is now in the tty's
    /// foreground. The declared workstream wins; argv is how a hand-started
    /// agent in a plain shell gets its rules at all.
    fn refresh_status_facts(&mut self) {
        let declared = self
            .workstream
            .as_ref()
            .map(|workstream| workstream.agent_id.clone());
        let argv = self.foreground.current().argv.clone();
        let facts = status::resolve_facts(
            status::catalog(),
            declared.as_deref(),
            argv.as_deref(),
        );
        if facts.agent_id == self.status_engine.facts().agent_id {
            return;
        }
        self.status_engine.set_facts(facts);
        self.sync_status_watch();
    }

    /// Publish one engine verdict: the cached wire status, then the event every
    /// attachment and every `status:` subscriber reads.
    ///
    /// The event carries the state and the source and nothing a person reads —
    /// the tooltip sentence, the dot colour and the done-versus-idle call on a
    /// row a viewer is looking at all stay client-side (device architecture §4).
    fn apply_status_change(&mut self, change: status::StatusChange) {
        self.status = self.status_engine.wire_status();
        self.emit_event(Event::Status {
            session: self.id.to_string(),
            status: self.status.clone(),
            source: Some(change.source.as_str().to_string()),
            turn_ended: change.turn_ended,
            blocking: self.status_engine.blocking_attention(),
            title: self.title.clone(),
            transcript_path: None,
            conversation_id: None,
            tool: None,
            prompt_title: None,
        });
    }

    /// Where probe 2 fingerprints: the workstream's worktree when it has one,
    /// else the child's live cwd, else the session's own directory. Resolved
    /// once per window and then reused, so an agent `cd`-ing between repos
    /// cannot masquerade as repo progress.
    fn stall_probe_directory(&self) -> Option<String> {
        if let Some(worktree) = self
            .workstream
            .as_ref()
            .and_then(|workstream| workstream.worktree.clone())
        {
            return Some(worktree);
        }
        if let Some(cwd) = self.foreground.current().cwd.clone() {
            return Some(cwd);
        }
        let project = self
            .workstream
            .as_ref()
            .map(|workstream| workstream.project.clone());
        project.or_else(|| (!self.cwd.is_empty()).then(|| self.cwd.clone()))
    }

    fn mark_vt_stale(&mut self, reason: String) {
        if !self.vt.is_live() {
            return;
        }
        eprintln!(
            "termiod: VT sidecar for session {} is stale: {reason}; snapshots now fall back to ring replay",
            self.id
        );
        // Nothing more will reach the VT, so drain what is queued rather than
        // let a wedged parse hold the memory. The shutdown goes out while the
        // sender is still there; the VT is down the moment it has.
        self.send_sidecar(SidecarCommand::Shutdown);
        self.vt = Vt::down(reason.clone());
        self.emit_event(Event::VtStale {
            session: self.id.to_string(),
            reason: reason.clone(),
        });
        self.disconnect_grid_clients(&reason);
        self.fallback_all_pending(&reason);
    }

    /// Ask the sidecar for one client's snapshot, or fail it straight into the
    /// ring-replay fallback when the VT can no longer answer.
    fn request_snapshot(&mut self, client_id: ClientId, request_id: u64, scrollback: bool) {
        let refusal = self.vt.refusal().map(str::to_string);
        if let Some(reason) = refusal {
            self.finish_snapshot(&client_id, request_id, Err(reason));
            return;
        }
        if !self.send_sidecar(SidecarCommand::Snapshot {
            client_id: client_id.clone(),
            request_id,
            scrollback,
        }) {
            self.finish_snapshot(&client_id, request_id, Err(sidecar::UNAVAILABLE.to_string()));
        }
    }

    fn wants_grid_diffs(&self) -> bool {
        self.clients.values().any(|entry| entry.plane.is_grid())
    }

    fn sync_grid_diff_interest(&mut self) {
        self.send_sidecar(SidecarCommand::SetGridDiff(self.wants_grid_diffs()));
    }

    /// How long a resize's keyframe waits for the child's own redraw.
    ///
    /// The capture used to be adjacent to the sidecar's `Resize`, which by
    /// construction snapshotted the screen the terminal had just rewrapped and
    /// the child had not yet answered — so every resize shipped every
    /// attachment a full-screen paint of a screen that was about to be thrown
    /// away, and that frame is what a drag looked like. A program that answers
    /// SIGWINCH lands its redraw well inside this window: measured from a real
    /// PTY, Claude Code writes its `ESC[2J` repaint 0.3ms after the ioctl and
    /// zsh redisplays within 23ms. A child that takes longer, or writes
    /// nothing, gets exactly the old behaviour — the rewrapped screen — so this
    /// window trades no correctness for the common case.
    const RESIZE_SNAPSHOT_SETTLE: std::time::Duration = std::time::Duration::from_millis(40);

    /// How long the capture waits after the child's *first* byte in answer to
    /// the resize, so a redraw split across two writes is captured whole rather
    /// than half-drawn. Only ever pulls the deadline in, never pushes it out, so
    /// a program that keeps writing cannot hold the barrier open.
    const RESIZE_ANSWER_QUIESCE: std::time::Duration = std::time::Duration::from_millis(5);

    /// How long after a resize the child is asked to repaint once more.
    ///
    /// Long enough that a drag's own bursts have stopped pushing it out — every
    /// resize re-arms it, so a drag costs one nudge, at the end — and that the
    /// child's answer to the *last* resize has drained. Anything the transition
    /// mis-parsed is still on screen until something overwrites it, and only
    /// the child can.
    const RESIZE_SETTLE_NUDGE: std::time::Duration = std::time::Duration::from_millis(300);

    /// A resize's barrier: opened now so nothing reaches a client ahead of the
    /// screen that describes the new grid, captured once the child has had time
    /// to redraw into it.
    fn begin_resize_snapshot_barrier(&mut self) {
        let requests = self.open_snapshot_barrier();
        self.resize_capture = Some(ResizeCapture {
            at: tokio::time::Instant::now() + Self::RESIZE_SNAPSHOT_SETTLE,
            requests,
        });
    }

    /// When the resize barrier opened above should be captured, if one is.
    /// Read by the actor loop, which owns the timer.
    fn resize_capture_deadline(&self) -> Option<tokio::time::Instant> {
        self.resize_capture.as_ref().map(|capture| capture.at)
    }

    /// Captures what the last resize opened a barrier for.
    ///
    /// Each request is checked against the attachment's current barrier: one
    /// superseded in the meantime — a second resize, an attach, a resync — is
    /// already being captured by whoever superseded it, and asking again would
    /// spend a capture on a request `finish_snapshot` would discard as stale.
    fn capture_resize_snapshots(&mut self) {
        let Some(capture) = self.resize_capture.take() else {
            return;
        };
        for (client_id, request_id) in capture.requests {
            let still_waiting = self
                .clients
                .get(&client_id)
                .is_some_and(|entry| entry.plane.pending_request() == Some(request_id));
            if still_waiting {
                self.request_snapshot(client_id, request_id, false);
            }
        }
    }

    /// Opens every snapshot attachment's barrier and answers what each is now
    /// waiting on. Data and events queue behind it from here; who asks for the
    /// capture, and when, is the caller's.
    fn open_snapshot_barrier(&mut self) -> Vec<(ClientId, u64)> {
        let snapshot_clients: Vec<ClientId> = self
            .clients
            .iter()
            .filter(|(_, entry)| entry.plane.snapshots())
            .map(|(id, _)| id.clone())
            .collect();
        let mut requests = Vec::with_capacity(snapshot_clients.len());

        for client_id in snapshot_clients {
            let request_id = self.allocate_snapshot_request();
            let entry = self
                .clients
                .get_mut(&client_id)
                .expect("snapshot client disappeared during barrier setup");
            // Attach history is tied to its original snapshot boundary. A
            // resize cancels any unfinished stage and does not recapture it;
            // history reflow/restaging semantics are intentionally deferred.
            entry.staged_history.clear();
            // The new snapshot includes every write queued before the resize, so
            // replaying older buffered data would overlap.
            let superseded = entry.plane.begin_pending(request_id);
            release_buffered(&entry.backlog, superseded);
            requests.push((client_id, request_id));
        }

        requests
    }

    /// D4(a): a client that outruns its backlog gets one forced resync before it
    /// gets dropped. Everything already queued for it is discarded — that is the
    /// point, since replaying megabytes to a client that could not keep up is
    /// what put it here — and the snapshot that follows re-establishes JOIN at a
    /// fresh boundary. No other client is touched.
    fn force_resync(&mut self, client_id: &ClientId, reason: &str) {
        let request_id = self.allocate_snapshot_request();
        let session_id = self.id.to_string();
        let Some(entry) = self.clients.get_mut(client_id) else {
            return;
        };
        entry.backlog_strikes += 1;
        entry.staged_history.clear();
        entry.backlog.begin_resync();
        // The buffered data was reserved under the epoch just retired, so it is
        // dropped where it sits rather than replayed past the new `S`.
        drop(entry.plane.begin_pending(request_id));
        entry.plane.defer(ClientEvent::Event(Event::Resynced {
            session: session_id,
            reason: reason.to_string(),
        }));
        eprintln!(
            "termiod: resyncing client {client_id} on session {}: {reason}",
            self.id
        );
        self.request_snapshot(client_id.clone(), request_id, false);
    }

    fn queue_non_data(entry: &mut ClientEntry, event: ClientEvent) -> bool {
        match entry.plane.delivery_mut() {
            Some(ClientDelivery::SnapshotPending { deferred, .. }) => {
                deferred.push_back(event);
                true
            }
            _ => entry.out.send(event).is_ok(),
        }
    }

    fn remove_dead(&mut self, dead: Vec<ClientId>) {
        if dead.is_empty() {
            return;
        }
        let old_writer = self.writer.clone();
        for id in dead {
            self.clients.remove(&id);
        }
        self.sync_grid_diff_interest();
        self.recompute_writer();
        if self.writer != old_writer {
            self.emit_writer_changed(self.writer.clone());
        }
        // A viewer that died was very likely the smallest one.
        self.apply_size_policy();
    }

    /// Send a protocol event to attachments and control-channel subscribers.
    fn emit_event(&mut self, event: Event) {
        let _ = self.events.send(event.clone());
        let dead = self
            .clients
            .iter_mut()
            .filter_map(|(id, entry)| {
                (!Self::queue_non_data(entry, ClientEvent::Event(event.clone())))
                    .then(|| id.clone())
            })
            .collect();
        self.remove_dead(dead);
    }

    fn emit_roster(&mut self) {
        self.emit_event(Event::Roster {
            session: self.id.to_string(),
            action: "updated".to_string(),
            info: Some(Box::new(self.info())),
        });
    }

    /// Announces the token's new holder. `resize_claim_target`, if any, also
    /// gets the `resize_claim` control frame directly — a v0 name for what is
    /// now just "you have the token", kept because it is the only writer signal
    /// a client without the `events` capability ever sees.
    fn emit_writer_changed(&mut self, resize_claim_target: Option<ClientId>) {
        if let Some(target) = resize_claim_target {
            if let Some(entry) = self.clients.get_mut(&target) {
                Self::queue_non_data(
                    entry,
                    ClientEvent::Control(Control::ResizeClaim {
                        session: self.id.to_string(),
                        writer: self.writer.as_ref().map(ClientId::to_string),
                    }),
                );
            }
        }
        let writer = self.writer.as_ref().map(ClientId::to_string);
        self.emit_event(Event::WriterChanged {
            session: self.id.to_string(),
            writer,
        });
    }

    /// Fan PTY output out to every attached client; drop dead ones.
    fn fan_out(&mut self, data: Bytes) {
        self.push_ring(data.clone());
        let mut resync = Vec::new();
        let dead = self
            .clients
            .iter_mut()
            .filter_map(|(id, entry)| {
                // The parsed plane is opt-in: G clients never reserve or
                // receive downstream PTY bytes. Raw clients keep this exact
                // byte-blind path regardless of sidecar lag.
                if entry.plane.is_grid() {
                    return None;
                }
                let Some(payload) = entry.backlog.reserve(data.clone()) else {
                    if entry.backlog_strikes == 0 && entry.plane.snapshots() {
                        resync.push(id.clone());
                        return None;
                    }
                    entry.backlog.mark_dropped();
                    eprintln!(
                        "termiod: dropping slow client {id} from session {}: output backlog exceeded {} again",
                        self.id,
                        backlog::cap_description()
                    );
                    return Some(id.clone());
                };
                match entry.plane.delivery_mut() {
                    Some(ClientDelivery::SnapshotPending { data: buffered, .. }) => {
                        buffered.push_back(payload);
                    }
                    // Raw, or snapshot-capable and past its boundary.
                    _ => {
                        if entry.out.send(ClientEvent::Data(payload.clone())).is_err() {
                            entry.backlog.release(&payload);
                            return Some(id.clone());
                        }
                    }
                }
                None
            })
            .collect();
        self.remove_dead(dead);
        for client_id in resync {
            self.force_resync(
                &client_id,
                &format!("output backlog exceeded {}", backlog::cap_description()),
            );
        }
    }

    fn fan_out_grid(&mut self, grid: GridDiff) {
        let payload = match encode_grid_payload(&grid) {
            Ok(payload) => Bytes::from(payload),
            Err(error) => {
                eprintln!(
                    "termiod: failed to encode grid diff for session {}: {error}",
                    self.id
                );
                return;
            }
        };
        let dead = self
            .clients
            .iter_mut()
            .filter_map(|(id, entry)| {
                if !entry.plane.is_grid() || entry.plane.is_pending() {
                    // An ordered G observed while pending precedes this
                    // client's S boundary, so the S supersedes it.
                    return None;
                }
                let Some(metered) = entry.backlog.reserve(payload.clone()) else {
                    entry.backlog.mark_dropped();
                    eprintln!(
                        "termiod: dropping slow grid-diff client {id} from session {}: output backlog exceeded {}",
                        self.id,
                        backlog::cap_description()
                    );
                    return Some(id.clone());
                };
                if entry.out.send(ClientEvent::Grid(metered.clone())).is_err() {
                    entry.backlog.release(&metered);
                    return Some(id.clone());
                }
                None
            })
            .collect();
        self.remove_dead(dead);
    }

    fn reject_not_writer(&mut self, id: &ClientId) {
        if let Some(entry) = self.clients.get_mut(id) {
            Self::queue_non_data(
                entry,
                ClientEvent::Control(Control::Error {
                    re: None,
                    code: ErrorCode::NotWriter,
                    message: "this attachment does not own the write token".to_string(),
                    retryable: false,
                }),
            );
        }
    }

    /// The size this session should be: the viewport of the attachment being
    /// used — the one whose device most recently saw a person. `None` when no
    /// candidate has a viewport at all: every viewer left, or every one of them
    /// is on another tab or has not laid out yet.
    ///
    /// Only interactive attachments are candidates, for the same reason only
    /// they are ranked for the write token: an observer attached without a tty
    /// has no screen a viewport could be about, so `termio read` tailing a
    /// session never resizes the window someone is working in.
    ///
    /// This is tmux's `latest`, and the reason it is safe here is that the
    /// trigger is narrow. `use_clock` moves on the three things a person does —
    /// typing, resizing that screen, opening the session there — and never on a
    /// byte the terminal answered a query with. The old implementation bound the
    /// size to the write token and had *both ends* re-assert their own grid,
    /// which turned one misclassified byte into a full-speed resize loop; the
    /// daemon is the only thing that resizes now, so a stray use costs one
    /// resize rather than an oscillation
    /// (`docs/design/20260901-pty-size-is-not-the-write-token.md`).
    fn policy_size(&self) -> Option<(u16, u16)> {
        self.clients
            .values()
            .filter(|entry| entry.role.is_interactive() && entry.rendering)
            .filter(|entry| entry.viewport.is_some())
            .max_by_key(|entry| entry.used)
            .and_then(|entry| entry.viewport)
    }

    /// Whether the thing on screen is a shell, which is the one class of
    /// program a rewrapping resize breaks.
    ///
    /// A shell answers SIGWINCH by moving the cursor up a number of rows it
    /// computed from the *old* width and repainting its prompt from there.
    /// Rewrap under that and the repaint lands in the wrong place, leaving a
    /// stale prompt above it — the ⌘D duplicate. Nothing else on a terminal
    /// does width-relative arithmetic against a screen it cannot see: an agent
    /// TUI, an editor, a pager all repaint from their own model, and truncating
    /// *their* screen is what leaves a window looking mangled after a drag.
    ///
    /// This asks the foreground rather than the session's spawn command,
    /// because the two are routinely different in both directions: a session
    /// launched as `zsh -ilc exec claude` has no shell in it at all — `exec`
    /// replaced the image, so the child *is* the agent and the old
    /// "is a job running under the shell" test was false for exactly the
    /// sessions that needed rewrapping most — and a plain shell session running
    /// `vim` has no prompt on screen to protect.
    ///
    /// A closed set of names, matched on the executable's basename with the
    /// login-shell `-` stripped. Name matching is the wrong instinct for
    /// agents, whose set is open and whose behaviour termio reads from a
    /// manifest; it is the right one here, because "programs that redraw a
    /// prompt from an old width" is a small set that has not grown in decades.
    /// When the foreground cannot be read, the answer is "shell": the
    /// truncating resize is the conservative one, and it is what shipped.
    fn foreground_is_a_shell(&self) -> bool {
        const SHELLS: [&str; 9] = [
            "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu",
        ];
        let Some(argv0) = self
            .foreground
            .current()
            .argv
            .as_ref()
            .and_then(|argv| argv.first())
        else {
            return true;
        };
        let name = argv0
            .rsplit('/')
            .next()
            .unwrap_or(argv0)
            .trim_start_matches('-');
        SHELLS.contains(&name)
    }

    /// Records that a person is on this attachment's device, so the session
    /// sizes to its screen from now on.
    ///
    /// Stamped by typing, by a viewport declaration (somebody resized that
    /// window or opened its sidebar), and by the attach itself (somebody opened
    /// the session there). Deliberately not by output, by a device report, or by
    /// anything the daemon does on its own: those are the terminal talking, not
    /// the person, and sizing must never follow them.
    fn note_use(&mut self, id: &ClientId) {
        self.use_clock += 1;
        let clock = self.use_clock;
        if let Some(entry) = self.clients.get_mut(id) {
            entry.used = clock;
        }
    }

    /// Moves the PTY to whatever the policy now says, if that is somewhere else.
    ///
    /// This is the only thing in the daemon that resizes a session, and it runs
    /// on every change to the attachment set: an arrival, a departure, a
    /// viewport, a keystroke, a pane going to a background tab. The write token
    /// is not consulted — the token is about who may type, and a device can be
    /// the one being looked at without holding it
    /// (`docs/design/20260901-pty-size-is-not-the-write-token.md`).
    ///
    /// With nobody rendering, the size is left exactly where it was. A session
    /// every viewer walked away from keeps the shape its last viewer gave it,
    /// the way zellij holds an unviewed tab, so coming back to it does not cost
    /// a reflow of a screen nobody watched change.
    fn apply_size_policy(&mut self) {
        let Some((rows, cols)) = self.policy_size() else {
            return;
        };
        // A resize is a barrier: the session quiesces and every attachment is
        // handed a fresh keyframe to repaint from. Doing that for a size the PTY
        // already has buys nothing and costs each viewer a full repaint. The
        // child would see no SIGWINCH from this ioctl either, so nothing
        // downstream is waiting on it.
        if rows == self.rows && cols == self.cols {
            return;
        }
        let applied = match self.pty.resize(rows, cols) {
            Ok(applied) => applied,
            Err(error) => {
                // Nobody asked for this, so there is nobody to answer: the size
                // is a policy over the whole attachment set, not one client's
                // request. The session stays where it was and the next change
                // tries again.
                eprintln!(
                    "termiod: resize of session {} to {rows}x{cols} failed: {error}",
                    self.id
                );
                return;
            }
        };
        // What the kernel holds, not what was asked for. The child reflows from
        // its own `TIOCGWINSZ`, so a divergence here would mean every viewer
        // letterboxing to a grid the child never had — and no event downstream
        // could contradict it. Recording the truth keeps the barrier, the
        // keyframe, and `E resized` describing one screen.
        if applied != (rows, cols) {
            eprintln!(
                "termiod: session {} asked for {rows}x{cols} and the kernel kept {}x{}",
                self.id, applied.0, applied.1
            );
        }
        let (rows, cols) = applied;
        // The kernel can have kept the size it already had, in which case the
        // child saw no SIGWINCH and there is nothing to tell anyone about.
        if rows == self.rows && cols == self.cols {
            return;
        }
        self.rows = rows;
        self.cols = cols;
        // The bytes already in the ring were written into the old grid.
        // Replaying them into this one would put them in the wrong places, which
        // only matters where a replay is all there is — the far side of a
        // handoff.
        self.ring_reconstructs_screen = false;
        let reflow = !self.foreground_is_a_shell();
        self.send_sidecar(SidecarCommand::Resize { rows, cols, reflow });
        self.begin_resize_snapshot_barrier();
        self.emit_event(Event::Resized {
            session: self.id.to_string(),
            rows,
            cols,
        });
        self.settle_nudge_at = Some(tokio::time::Instant::now() + Self::RESIZE_SETTLE_NUDGE);
    }

    /// The settle deadline fired: the last resize has stood for long enough
    /// that the child's answer to it has drained. One more repaint request
    /// makes the child overwrite anything the transition mis-parsed.
    ///
    /// Shells are excluded for the same reason `foreground_is_a_shell` gates
    /// the rewrap: a shell repainted its prompt on the resize's own SIGWINCH
    /// and a second poke buys nothing, while the agents and editors this is
    /// for redraw their whole screen from their own model.
    fn fire_settle_nudge(&mut self) {
        self.settle_nudge_at = None;
        if !self.foreground_is_a_shell() {
            self.pty.nudge_repaint();
        }
    }

    fn queue_history_chunk(
        session_id: &SessionId,
        client_id: &ClientId,
        entry: &mut ClientEntry,
    ) -> Result<bool, ()> {
        let Some(payload) = entry.staged_history.front() else {
            return Ok(false);
        };
        let Some(metered) = entry.backlog.reserve(payload.clone()) else {
            entry.backlog.mark_dropped();
            eprintln!(
                "termiod: dropping slow client {client_id} from session {session_id}: scrollback backlog exceeded {}",
                backlog::cap_description()
            );
            return Err(());
        };
        entry.staged_history.pop_front();
        if entry
            .out
            .send(ClientEvent::History(metered.clone()))
            .is_err()
        {
            entry.backlog.release(&metered);
            return Err(());
        }
        Ok(!entry.staged_history.is_empty())
    }

    fn continue_history(&mut self, client_id: &ClientId) -> bool {
        let result = self
            .clients
            .get_mut(client_id)
            .map(|entry| Self::queue_history_chunk(&self.id, client_id, entry));
        match result {
            Some(Ok(more)) => more,
            Some(Err(())) => {
                self.remove_dead(vec![client_id.clone()]);
                false
            }
            None => false,
        }
    }

    /// Every successful snapshot, whether attach bootstrap or resize/resync
    /// barrier, is followed immediately by `ready`. Attach-only history starts
    /// after `ready`, with buffered live data allowed between staged chunks.
    fn finish_snapshot(
        &mut self,
        client_id: &ClientId,
        request_id: u64,
        result: Result<SidecarCapture, String>,
    ) -> bool {
        // A reply for a request this attachment is no longer waiting on
        // describes a boundary that a resize or a resync has already replaced.
        let is_current = self
            .clients
            .get(client_id)
            .and_then(|entry| entry.plane.pending_request())
            == Some(request_id);
        if !is_current {
            return false;
        }
        let Some(mut entry) = self.clients.remove(client_id) else {
            return false;
        };
        let (mut data, mut deferred) = entry.plane.settle();

        let capture = match result {
            Ok(capture) => capture,
            Err(error) => {
                if entry.plane.is_grid() {
                    eprintln!(
                        "termiod: grid-diff snapshot unavailable for client {client_id} in session {}: {error}; disconnecting client",
                        self.id
                    );
                    release_buffered(&entry.backlog, data);
                    let _ = entry.out.send(ClientEvent::Control(Control::Error {
                        re: None,
                        code: ErrorCode::Internal,
                        message: format!("grid-diff sidecar unavailable: {error}"),
                        retryable: true,
                    }));
                    self.remove_finished_client(client_id);
                    return false;
                }
                self.fallback_snapshot(client_id, entry, data, deferred, &error);
                return false;
            }
        };
        let engine = capture.snapshot;
        // Raw-plane clients get VT sequences so their own libghostty decides
        // colour (their theme, their palette, full SGR). Grid-diff clients are
        // server-state by design and need packed cells to seed the grid.
        let snapshot_vt = if entry.plane.is_grid() { None } else { capture.vt };
        if let Some(scrollback) = capture.scrollback {
            match scrollback {
                Ok(scrollback) => {
                    if scrollback.total_rows > scrollback.rows.len() {
                        eprintln!(
                            "termiod: scrollback stage for client {client_id} in session {} truncated from {} to {} rows at {} MiB",
                            self.id,
                            scrollback.total_rows,
                            scrollback.rows.len(),
                            SCROLLBACK_STAGE_MAX_BYTES / (1024 * 1024)
                        );
                    }
                    match encode_scrollback_chunks(engine.cols, scrollback.rows) {
                        Ok(chunks) => entry.staged_history = chunks,
                        Err(error) => eprintln!(
                            "termiod: scrollback stage unavailable for client {client_id} in session {}: {error}",
                            self.id
                        ),
                    }
                }
                Err(error) => eprintln!(
                    "termiod: scrollback capture unavailable for client {client_id} in session {}: {error}",
                    self.id
                ),
            }
        }
        let snapshot = self.protocol_snapshot(engine, snapshot_vt);

        if entry.out.send(ClientEvent::Snapshot(snapshot)).is_err()
            || entry
                .out
                .send(ClientEvent::Event(Event::Ready {
                    session: self.id.to_string(),
                }))
                .is_err()
        {
            release_buffered(&entry.backlog, data);
            self.remove_finished_client(client_id);
            return false;
        }

        let history_pending = match Self::queue_history_chunk(&self.id, client_id, &mut entry) {
            Ok(more) => more,
            Err(()) => {
                release_buffered(&entry.backlog, data);
                self.remove_finished_client(client_id);
                return false;
            }
        };
        while let Some(payload) = data.pop_front() {
            if entry.out.send(ClientEvent::Data(payload.clone())).is_err() {
                entry.backlog.release(&payload);
                release_buffered(&entry.backlog, data);
                self.remove_finished_client(client_id);
                return false;
            }
        }
        while let Some(event) = deferred.pop_front() {
            if entry.out.send(event).is_err() {
                self.remove_finished_client(client_id);
                return false;
            }
        }
        self.clients.insert(client_id.clone(), entry);
        history_pending
    }

    fn protocol_snapshot(&self, engine: termiod_vt::Snapshot, vt: Option<Vec<u8>>) -> Snapshot {
        Snapshot {
            vt,
            rows: engine.rows,
            cols: engine.cols,
            cursor_x: engine.cursor_x,
            cursor_y: engine.cursor_y,
            alt_screen: engine.alt_screen,
            title: engine
                .title
                .or_else(|| self.title.clone())
                .unwrap_or_else(|| self.name.clone()),
            cells: engine
                .cells
                .into_iter()
                .map(wire_cell)
                .collect(),
        }
    }

    fn fan_out_keyframe(&mut self, engine: termiod_vt::Snapshot) {
        // Keyframes only reach grid-diff clients, which want cells.
        let snapshot = self.protocol_snapshot(engine, None);
        let dead = self
            .clients
            .iter_mut()
            .filter_map(|(id, entry)| {
                if !entry.plane.is_grid() || entry.plane.is_pending() {
                    return None;
                }
                (entry
                    .out
                    .send(ClientEvent::Snapshot(snapshot.clone()))
                    .is_err()
                    || entry
                        .out
                        .send(ClientEvent::Event(Event::Ready {
                            session: self.id.to_string(),
                        }))
                        .is_err())
                .then(|| id.clone())
            })
            .collect();
        self.remove_dead(dead);
    }

    fn disconnect_grid_clients(&mut self, error: &str) {
        let ids: Vec<ClientId> = self
            .clients
            .iter()
            .filter(|(_, entry)| entry.plane.is_grid())
            .map(|(id, _)| id.clone())
            .collect();
        if ids.is_empty() {
            return;
        }
        eprintln!(
            "termiod: disconnecting {} grid-diff client(s) from session {}: {error}",
            ids.len(),
            self.id
        );
        let old_writer = self.writer.clone();
        for id in ids {
            if let Some(mut entry) = self.clients.remove(&id) {
                let (buffered, _deferred) = entry.plane.settle();
                release_buffered(&entry.backlog, buffered);
                let _ = entry.out.send(ClientEvent::Control(Control::Error {
                    re: None,
                    code: ErrorCode::Internal,
                    message: format!("grid-diff sidecar unavailable: {error}"),
                    retryable: true,
                }));
            }
        }
        self.recompute_writer();
        if self.writer != old_writer {
            self.emit_writer_changed(self.writer.clone());
        }
    }

    fn fallback_snapshot(
        &mut self,
        client_id: &ClientId,
        entry: ClientEntry,
        buffered: VecDeque<Metered>,
        deferred: VecDeque<ClientEvent>,
        error: &str,
    ) {
        eprintln!(
            "termiod: VT snapshot unavailable for client {client_id} in session {}: {error}; falling back to ring replay",
            self.id
        );
        release_buffered(&entry.backlog, buffered);

        for replay in &self.ring {
            let Some(metered) = entry.backlog.reserve(replay.clone()) else {
                entry.backlog.mark_dropped();
                self.remove_finished_client(client_id);
                return;
            };
            if entry.out.send(ClientEvent::Data(metered.clone())).is_err() {
                entry.backlog.release(&metered);
                self.remove_finished_client(client_id);
                return;
            }
        }
        for event in deferred {
            if entry.out.send(event).is_err() {
                self.remove_finished_client(client_id);
                return;
            }
        }
        self.clients.insert(client_id.clone(), entry);
        // The replay this client was just handed may not draw the screen the
        // program believes it is looking at (see `ring_reconstructs_screen`).
        // The old answer — "the program repaints on its next output either way"
        // — assumed there would be a next output; an agent idling at its prompt
        // never produces one, and a viewer whose window matches the session's
        // size gets no resize to force the issue either. So force it here: the
        // repaint the nudge provokes is ordinary output, which corrects this
        // screen and every other attachment's at once.
        if !self.ring_reconstructs_screen {
            self.pty.nudge_repaint();
        }
    }

    fn remove_finished_client(&mut self, client_id: &ClientId) {
        let old_writer = self.writer.clone();
        if old_writer.as_ref() == Some(client_id) {
            self.recompute_writer();
        }
        self.sync_grid_diff_interest();
        if self.writer != old_writer {
            self.emit_writer_changed(self.writer.clone());
        }
    }

    fn fallback_all_pending(&mut self, error: &str) {
        let pending: Vec<(ClientId, u64)> = self
            .clients
            .iter()
            .filter_map(|(id, entry)| {
                entry
                    .plane
                    .pending_request()
                    .map(|request_id| (id.clone(), request_id))
            })
            .collect();
        for (id, request_id) in pending {
            self.finish_snapshot(&id, request_id, Err(error.to_string()));
        }
    }
}

fn keyframe_every_frames() -> u32 {
    std::env::var("TERMIOD_KEYFRAME_EVERY")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(KEYFRAME_EVERY_FRAMES)
}

fn should_emit_keyframe(frame_seq: u32, every: u32) -> bool {
    every > 0 && frame_seq.is_multiple_of(every)
}

fn release_buffered(backlog: &ClientBacklog, data: VecDeque<Metered>) {
    for payload in data {
        backlog.release(&payload);
    }
}

/// The environment this daemon adds to every session it spawns, layered *after*
/// the client's `CreateSpec.env` so a client cannot spoof either value.
///
/// A hook installed for an agent on this machine reports by running
/// `termiod set-status`, which needs two things the child would otherwise have
/// to guess:
///
/// - **which session it is.** `Pty::spawn` sets `TERMIOD_SESSION=1`, which says
///   *that* you are inside a termiod session and never *which* one. `TERMIO_SESSION`
///   is not reused for the identity: it is on `LAUNCHER_ENV_KEYS` precisely so a
///   stale value cannot leak into a later session, and giving it a second meaning
///   here would fight that.
/// - **which socket to report on.** Resolved from this daemon's own view rather
///   than left to the child, because `paths::socket_path()` falls back to a
///   uid-scoped temp dir when `XDG_RUNTIME_DIR` is absent — so a daemon started
///   from an ssh exec channel and a hook process that inherited a different
///   environment can otherwise resolve two different sockets.
fn daemon_owned_env(id: &SessionId, mut env: Vec<(String, String)>) -> Vec<(String, String)> {
    env.push(("TERMIOD_SESSION_ID".to_string(), id.to_string()));
    match crate::paths::socket_path() {
        Ok(path) => env.push(("TERMIOD_SOCK".to_string(), path.display().to_string())),
        // Not fatal: the child falls back to resolving the default path itself,
        // which is right whenever this daemon is on the default path too.
        Err(err) => eprintln!("termiod: could not resolve socket path for session env: {err}"),
    }
    env
}

/// Everything a session actor hands over when its daemon is about to `execve`
/// (see `crate::handoff`): the facts that describe it, the PTY master as a
/// descriptor the exec can carry, and the replay ring so the new image can put
/// the screen back without asking the program to redraw it.
pub struct Carried {
    pub info: crate::handoff::CarriedSession,
    /// The PTY master, **owned**. Its number reaches the blob only when the
    /// daemon commits this session to the crossing; until then, dropping this
    /// closes the master and the program in the session is hung up like any
    /// other loss. That is what a session which misses the carry deadline
    /// needs to happen — the alternative is a descriptor with no owner and no
    /// reader surviving the exec, and a process alive inside a session nothing
    /// can see.
    pub master: std::os::fd::OwnedFd,
    pub ring: Vec<Bytes>,
}

/// Spawn a session task. On process exit the session id is sent to the
/// manager so it can remove the handle from the table.
#[allow(clippy::too_many_arguments)]
pub fn spawn(
    id: SessionId,
    name: String,
    cwd: String,
    command: String,
    argv: Vec<String>,
    env: Vec<(String, String)>,
    rows: u16,
    cols: u16,
    workstream: Option<WorkstreamSpec>,
    on_exit: mpsc::UnboundedSender<SessionEnded>,
    events: broadcast::Sender<Event>,
) -> anyhow::Result<SessionHandle> {
    let cwd_opt = if cwd.is_empty() {
        None
    } else {
        Some(cwd.as_str())
    };
    let env = daemon_owned_env(&id, env);
    let (pty, child) = Pty::spawn(&argv, cwd_opt, &env, rows, cols)?;
    let created_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let waiter = tokio::task::spawn_blocking(move || {
        let mut child = child;
        match child.wait() {
            Ok(status) => status.code().unwrap_or_else(|| {
                use std::os::unix::process::ExitStatusExt;
                status.signal().map(|s| 128 + s).unwrap_or(-1)
            }),
            Err(_) => -1,
        }
    });
    start(
        Facts {
            id,
            name,
            cwd,
            command,
            rows,
            cols,
            created_unix,
            status: "unknown".to_string(),
            title: None,
            workstream,
            status_clocks: None,
        },
        pty,
        waiter,
        Replay::none(),
        on_exit,
        events,
    )
}

/// Take a session back over after a handoff: same PTY, same child, same ring,
/// a new actor around them.
///
/// The screen is rebuilt rather than re-fetched. Feeding the carried ring
/// through a fresh VT sidecar is exactly what the previous image did with those
/// same bytes as they arrived, so the snapshot the first re-attaching client
/// gets is the screen it would have got had nothing happened.
pub fn adopt(
    carried: crate::handoff::CarriedSession,
    ring: Vec<u8>,
    on_exit: mpsc::UnboundedSender<SessionEnded>,
    events: broadcast::Sender<Event>,
) -> anyhow::Result<SessionHandle> {
    let pty = Pty::adopt(carried.master_fd, carried.pid)?;
    let waiter = reap(carried.pid);
    let replay = Replay {
        chunks: if ring.is_empty() {
            Vec::new()
        } else {
            vec![Bytes::from(ring)]
        },
        faithful: carried.ring_reconstructs_screen,
    };
    start(
        Facts {
            id: SessionId::new(carried.id),
            name: carried.name,
            cwd: carried.cwd,
            command: carried.command,
            rows: carried.rows,
            cols: carried.cols,
            created_unix: carried.created_unix,
            status: carried.status,
            title: carried.title,
            workstream: carried.workstream,
            status_clocks: carried.status_clocks,
        },
        pty,
        waiter,
        replay,
        on_exit,
        events,
    )
}

/// Reap a child this process still owns but no longer has a `Child` for — the
/// shape every carried session is in, because `execve` kept the parentage and
/// destroyed the bookkeeping.
fn reap(pid: i32) -> tokio::task::JoinHandle<i32> {
    tokio::task::spawn_blocking(move || loop {
        let mut status: libc::c_int = 0;
        let reaped = unsafe { libc::waitpid(pid, &mut status, 0) };
        if reaped < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return -1;
        }
        if libc::WIFEXITED(status) {
            return libc::WEXITSTATUS(status);
        }
        if libc::WIFSIGNALED(status) {
            return 128 + libc::WTERMSIG(status);
        }
        // Stopped or continued. Neither was asked for — no `WUNTRACED`, no
        // `WCONTINUED` — but a spurious wake is cheaper to loop on than to
        // reason about.
    })
}

/// Output this session has already produced, for an actor that is taking over
/// rather than starting: the bytes, and whether replaying them still draws the
/// screen they drew the first time.
struct Replay {
    chunks: Vec<Bytes>,
    /// See `Session::ring_reconstructs_screen`. False means this actor's VT
    /// must not claim to know what is on the screen.
    faithful: bool,
}

impl Replay {
    fn none() -> Replay {
        Replay {
            chunks: Vec::new(),
            faithful: true,
        }
    }
}

/// What describes a session independently of how this daemon came by it.
struct Facts {
    id: SessionId,
    name: String,
    cwd: String,
    command: String,
    rows: u16,
    cols: u16,
    created_unix: u64,
    status: String,
    title: Option<String>,
    workstream: Option<WorkstreamSpec>,
    /// How long the carried status has been true. `None` for a fresh spawn,
    /// which has no history to keep.
    status_clocks: Option<crate::session::status::CarriedClocks>,
}

/// The half of session startup that a fresh spawn and a carried session share:
/// the writer task, the VT sidecar, the ring, and the actor around them.
fn start(
    facts: Facts,
    pty: Pty,
    waiter: tokio::task::JoinHandle<i32>,
    replay: Replay,
    on_exit: mpsc::UnboundedSender<SessionEnded>,
    events: broadcast::Sender<Event>,
) -> anyhow::Result<SessionHandle> {
    let pty = Arc::new(pty);
    let pid = pty.pid;

    let (input_tx, mut input_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let writer_pty = pty.clone();
    tokio::spawn(async move {
        while let Some(bytes) = input_rx.recv().await {
            if writer_pty.write_all(&bytes).await.is_err() {
                break;
            }
        }
    });

    let sidecar = spawn_sidecar(facts.rows, facts.cols)?;

    let (tx, rx) = mpsc::unbounded_channel();
    let termination_reason = Arc::new(Mutex::new(None));
    let workstream_agent = facts
        .workstream
        .as_ref()
        .map(|workstream| workstream.agent_id.clone());
    let adopted_clocks = facts.status_clocks.clone();
    let mut session = Session {
        id: facts.id.clone(),
        name: facts.name,
        cwd: facts.cwd,
        command: facts.command,
        pid,
        rows: facts.rows,
        cols: facts.cols,
        created_unix: facts.created_unix,
        status: facts.status,
        title: facts.title,
        workstream: facts.workstream,
        pty,
        input_tx,
        clients: HashMap::new(),
        writer: None,
        next_seq: 0,
        use_clock: 0,
        next_snapshot_request: 1,
        ring: VecDeque::new(),
        ring_bytes: 0,
        ring_reconstructs_screen: true,
        settle_nudge_at: None,
        events,
        vt: Vt::live(sidecar.commands, sidecar.queue),
        status_engine: StatusEngine::new(
            std::time::Instant::now(),
            status::resolve_facts(
                status::catalog(),
                workstream_agent.as_deref(),
                None,
            ),
        ),
        transcript_path: None,
        foreground: Foreground::default(),
        resize_capture: None,
    };
    // A carried or created session arrives with a status this actor did not
    // derive; the engine adopts it so the roster and the engine never disagree
    // about a session neither of them has seen a transition for yet.
    let adopted = session.status.clone();
    session
        .status_engine
        .seed(&adopted, adopted_clocks.as_ref(), std::time::Instant::now());
    session.sync_status_watch();
    for chunk in replay.chunks {
        // Through the same two paths a live byte takes, in the same order: the
        // ring it will be replayed from, and the VT that answers snapshots.
        session.send_sidecar(SidecarCommand::Write(chunk.clone()));
        session.push_ring(chunk);
    }
    // `push_ring` may have set this itself, if what was carried no longer fits
    // the cap; either way the previous actor's verdict still applies.
    session.ring_reconstructs_screen &= replay.faithful;
    if !session.ring_reconstructs_screen {
        // The VT this actor started is blank plus a replay, and the replay does
        // not draw the screen the program believes it is looking at — output
        // older than the ring is gone, or was written into a different grid.
        // Snapshots fall back to ring replay, which is wrong in exactly the
        // same way but is the client's own terminal being wrong about bytes it
        // was given, not this host asserting a screen it cannot know. The
        // program repaints on its next output either way.
        session.mark_vt_stale(
            "the output that drew this screen did not survive the handoff".to_string(),
        );
    }

    tokio::spawn(run(
        session,
        rx,
        waiter,
        on_exit,
        sidecar.results,
        sidecar.thread,
        termination_reason.clone(),
    ));
    Ok(SessionHandle {
        id: facts.id,
        pid,
        tx,
        termination_reason,
    })
}

struct Sidecar {
    commands: std_mpsc::Sender<SidecarCommand>,
    results: mpsc::UnboundedReceiver<SidecarResult>,
    queue: Arc<SidecarQueue>,
    thread: JoinHandle<()>,
}

/// One status tick's reading of the live screen, taken on the sidecar thread.
///
/// `changed` is a hash compare rather than a diff: the engine only asks whether
/// the screen moved, and hashing a screen costs one pass where keeping the
/// previous one costs a second copy per session.
fn screen_tick(
    terminal: Option<&termiod_vt::VtTerminal>,
    faulted: bool,
    want_text: bool,
    signature: &mut Option<u64>,
    pending_bytes: &mut u64,
) -> sidecar::ScreenTick {
    let bytes = std::mem::take(pending_bytes);
    let text = match (faulted, terminal) {
        (false, Some(terminal)) => terminal.screen_text().ok(),
        _ => None,
    };
    let Some(text) = text else {
        // No readable screen: treat output as activity rather than risk
        // clearing a live turn, which is what the Mac did with a detached
        // surface for the same reason.
        return sidecar::ScreenTick {
            changed: true,
            bytes,
            text: None,
        };
    };
    let hashed = {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        text.hash(&mut hasher);
        hasher.finish()
    };
    let changed = signature.replace(hashed) != Some(hashed);
    sidecar::ScreenTick {
        changed,
        bytes,
        text: want_text.then_some(text),
    }
}

fn spawn_sidecar(rows: u16, cols: u16) -> anyhow::Result<Sidecar> {
    // The channel itself stays unbounded and fire-and-forget — PTY delivery must
    // never wait for VT parsing. `SidecarQueue` is the budget instead: the
    // producer stops feeding the VT and declares it stale rather than blocking
    // or letting a slow parse buy unbounded memory. The consumer drains
    // adjacent Bytes writes in batches.
    let (command_tx, command_rx) = std_mpsc::channel::<SidecarCommand>();
    let (result_tx, result_rx) = mpsc::unbounded_channel::<SidecarResult>();
    let queue = Arc::new(SidecarQueue::new());
    let parsed = queue.clone();
    let thread = std::thread::Builder::new()
        .name("termiod-vt".to_string())
        .spawn(move || {
            let mut terminal = match termiod_vt::VtTerminal::new(rows, cols) {
                Ok(terminal) => Some(terminal),
                Err(error) => {
                    eprintln!("termiod: failed to initialize VT sidecar: {error}");
                    None
                }
            };
            let mut fault = terminal
                .is_none()
                .then(|| "VT sidecar initialization failed".to_string());
            let mut pending = None;
            let mut grid_diff_wanted = false;
            let mut frame_seq = 0u32;
            let keyframe_every = keyframe_every_frames();
            // The status engine's half of this thread: the two in-band channels
            // are scanned out of the same tee that feeds the VT, and the screen
            // is sampled on a timer. Both are off the delivery path by
            // construction — bytes reached every client before this thread saw
            // them — which is the anti-100x invariant, and both degrade with
            // the VT rather than ahead of it: a sidecar that goes stale stops
            // being fed, so status falls back to what hooks report.
            let mut osc = OscScanner::default();
            let mut watch_screen = false;
            let mut watch_text = false;
            let mut screen_signature: Option<u64> = None;
            let mut pending_bytes = 0u64;
            let mut next_tick = std::time::Instant::now() + sidecar::STATUS_TICK;

            loop {
                let command = match pending.take() {
                    Some(command) => command,
                    None => {
                        if watch_screen {
                            let now = std::time::Instant::now();
                            if now >= next_tick {
                                next_tick = now + sidecar::STATUS_TICK;
                                let tick = screen_tick(
                                    terminal.as_ref(),
                                    fault.is_some(),
                                    watch_text,
                                    &mut screen_signature,
                                    &mut pending_bytes,
                                );
                                if result_tx.send(SidecarResult::Screen(tick)).is_err() {
                                    break;
                                }
                                continue;
                            }
                            match command_rx.recv_timeout(next_tick - now) {
                                Ok(command) => command,
                                Err(std_mpsc::RecvTimeoutError::Timeout) => continue,
                                Err(std_mpsc::RecvTimeoutError::Disconnected) => break,
                            }
                        } else {
                            match command_rx.recv() {
                                Ok(command) => command,
                                Err(_) => break,
                            }
                        }
                    }
                };
                match command {
                    SidecarCommand::Write(bytes) => {
                        let mut signals = osc.scan(&bytes);
                        pending_bytes = pending_bytes.saturating_add(bytes.len() as u64);
                        if let Some(terminal) = terminal.as_mut() {
                            terminal.vt_write(&bytes);
                        }
                        parsed.release(bytes.len());
                        loop {
                            match command_rx.try_recv() {
                                Ok(SidecarCommand::Write(bytes)) => {
                                    signals.append(&mut osc.scan(&bytes));
                                    pending_bytes =
                                        pending_bytes.saturating_add(bytes.len() as u64);
                                    if let Some(terminal) = terminal.as_mut() {
                                        terminal.vt_write(&bytes);
                                    }
                                    parsed.release(bytes.len());
                                }
                                Ok(command) => {
                                    pending = Some(command);
                                    break;
                                }
                                Err(std_mpsc::TryRecvError::Empty) => break,
                                Err(std_mpsc::TryRecvError::Disconnected) => return,
                            }
                        }
                        if !signals.is_empty() && result_tx.send(SidecarResult::Osc(signals)).is_err()
                        {
                            break;
                        }
                        if grid_diff_wanted && fault.is_none() {
                            let damage =
                                match terminal.as_mut().expect("live VT terminal").take_damage() {
                                    Ok(damage) => damage,
                                    Err(error) => {
                                        eprintln!("termiod: VT damage drain failed: {error}");
                                        break;
                                    }
                                };
                            if !damage.dirty_rows.is_empty() {
                                frame_seq = frame_seq.wrapping_add(1);
                                if frame_seq == 0 {
                                    frame_seq = 1;
                                }
                                let result = if should_emit_keyframe(frame_seq, keyframe_every) {
                                    match terminal.as_mut().expect("live VT terminal").snapshot() {
                                        Ok(snapshot) => SidecarResult::Keyframe(snapshot),
                                        Err(error) => {
                                            eprintln!(
                                                "termiod: VT keyframe capture failed: {error}"
                                            );
                                            break;
                                        }
                                    }
                                } else {
                                    SidecarResult::Grid(grid_from_damage(frame_seq, damage))
                                };
                                if result_tx.send(result).is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    SidecarCommand::Resize { rows, cols, reflow } => {
                        if fault.is_none() {
                            if let Some(terminal) = terminal.as_mut() {
                                let resized = if reflow {
                                    terminal.resize_reflowing(rows, cols)
                                } else {
                                    terminal.resize_for_shell(rows, cols)
                                };
                                if let Err(error) = resized {
                                    fault = Some(format!("VT resize failed: {error}"));
                                }
                            }
                        }
                    }
                    SidecarCommand::Snapshot {
                        client_id,
                        request_id,
                        scrollback,
                    } => {
                        let result = match (&fault, terminal.as_mut()) {
                            (Some(error), _) => Err(error.clone()),
                            (None, Some(terminal)) => match terminal.snapshot() {
                                Ok(snapshot) => {
                                    let history = scrollback.then(|| {
                                        terminal
                                            .scrollback(scrollback_row_limit(snapshot.cols))
                                            .map_err(|error| error.to_string())
                                    });
                                    // Captured at the same FIFO boundary as the
                                    // cell snapshot so both describe one screen.
                                    let vt = terminal.format_vt().ok();
                                    Ok(SidecarCapture {
                                        snapshot,
                                        vt,
                                        scrollback: history,
                                    })
                                }
                                Err(error) => Err(error.to_string()),
                            },
                            (None, None) => Err("VT sidecar is unavailable".to_string()),
                        };
                        if result_tx
                            .send(SidecarResult::Snapshot {
                                client_id,
                                request_id,
                                result,
                            })
                            .is_err()
                        {
                            break;
                        }
                    }
                    SidecarCommand::SetStatusWatch { screen, text } => {
                        if screen && !watch_screen {
                            // Start the window at the screen as it is now, so a
                            // row promoted to an agent mid-session does not read
                            // its first tick as a change.
                            screen_signature = None;
                            pending_bytes = 0;
                            next_tick = std::time::Instant::now() + sidecar::STATUS_TICK;
                        }
                        watch_screen = screen;
                        watch_text = text;
                    }
                    SidecarCommand::SetGridDiff(wanted) => grid_diff_wanted = wanted,
                    SidecarCommand::Shutdown => break,
                }
            }
        })
        .map_err(|error| anyhow::anyhow!("spawning VT sidecar thread: {error}"))?;
    Ok(Sidecar {
        commands: command_tx,
        results: result_rx,
        queue,
        thread,
    })
}

/// One finished stall measurement, on its way back to the actor that asked.
struct StallResult {
    generation: u64,
    directory: Option<String>,
    measured: status::StallMeasurement,
    capture: bool,
}

async fn run(
    mut session: Session,
    mut rx: mpsc::UnboundedReceiver<SessionMsg>,
    waiter: tokio::task::JoinHandle<i32>,
    on_exit: mpsc::UnboundedSender<SessionEnded>,
    mut sidecar_results: mpsc::UnboundedReceiver<SidecarResult>,
    sidecar_thread: JoinHandle<()>,
    termination_reason: Arc<Mutex<Option<EndReason>>>,
) {
    let mut buf = vec![0u8; READ_CHUNK];
    let mut waiter = Some(waiter);
    let mut sidecar_results_open = true;
    let mut history_stages = VecDeque::<ClientId>::new();
    let mut end_reason = EndReason::Exited;
    // The first tick is immediate, so a session answers "what is running in
    // there" from its first roster request rather than after a cold two
    // seconds. Missed ticks are skipped instead of queued: a busy actor should
    // sample once when it catches up, not replay a backlog of polls.
    let mut foreground_poll = tokio::time::interval(foreground::POLL_INTERVAL);
    foreground_poll.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // The process-table half of each poll runs on a blocking thread and comes
    // back here. Held for the life of the loop so the branch below never sees a
    // closed channel while the session is alive.
    let (foreground_tx, mut foreground_rx) = mpsc::unbounded_channel::<ForegroundResolution>();
    // The stale-working timeout it enforces is a handful of seconds, so the
    // sweep has to tick at that granularity to clear a stuck spinner promptly.
    // The stall probes ride the same tick and gate themselves on their own,
    // much longer, window.
    let mut status_sweep = tokio::time::interval(std::time::Duration::from_secs(2));
    status_sweep.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let (stall_tx, mut stall_rx) = mpsc::unbounded_channel::<StallResult>();

    loop {
        // Read before the select rather than inside a branch: the timer wants
        // an owned deadline, and every other branch takes `&mut session`.
        let resize_capture_at = session.resize_capture_deadline();
        let settle_nudge_at = session.settle_nudge_at;
        tokio::select! {
            // A resize opened a snapshot barrier and left the capture to this
            // timer, so the keyframe carries the child's answer to SIGWINCH
            // rather than the screen the rewrap left behind.
            _ = tokio::time::sleep_until(
                resize_capture_at.unwrap_or_else(tokio::time::Instant::now)
            ), if resize_capture_at.is_some() => {
                session.capture_resize_snapshots();
            }
            _ = foreground_poll.tick() => {
                if session.foreground.poll(&session.pty, session.pid, &foreground_tx) {
                    session.refresh_status_facts();
                    session.emit_roster();
                }
            }
            Some(resolution) = foreground_rx.recv() => {
                if session.foreground.apply(resolution) {
                    // A hand-started agent becomes an agent here, which is when
                    // its rules start applying. A demotion back to the shell is
                    // the same edge run backwards.
                    session.refresh_status_facts();
                    session.emit_roster();
                }
            }
            // The dust from the last resize has settled; the child gets one
            // more SIGWINCH so its own repaint overwrites anything the
            // transition mis-parsed.
            _ = tokio::time::sleep_until(
                settle_nudge_at.unwrap_or_else(tokio::time::Instant::now)
            ), if settle_nudge_at.is_some() => {
                session.fire_settle_nudge();
            }
            _ = status_sweep.tick() => {
                let now = std::time::Instant::now();
                if let Some(change) = session.status_engine.sweep_stale_working(now) {
                    session.apply_status_change(change);
                }
                match session.status_engine.stall_step(now) {
                    StallStep::Nothing => {}
                    StallStep::Capture { generation } => {
                        let directory = session.stall_probe_directory();
                        let transcript = session.transcript_path.clone();
                        let baseline = session
                            .status_engine
                            .stall_probe()
                            .and_then(|probe| probe.baseline.clone());
                        let tx = stall_tx.clone();
                        // Off the actor thread: probe 2 shells out to git, and
                        // a roster request must never wait behind it.
                        tokio::task::spawn_blocking(move || {
                            let measured = status::measure_stall_evidence(
                                directory.as_deref(),
                                transcript.as_deref(),
                                baseline.as_ref(),
                            );
                            let _ = tx.send(StallResult {
                                generation,
                                directory,
                                measured,
                                capture: true,
                            });
                        });
                    }
                    StallStep::Probe { generation, directory, transcript } => {
                        let transcript = transcript.or_else(|| session.transcript_path.clone());
                        let baseline = session
                            .status_engine
                            .stall_probe()
                            .and_then(|probe| probe.baseline.clone());
                        let tx = stall_tx.clone();
                        let probe_directory = directory.clone();
                        tokio::task::spawn_blocking(move || {
                            let measured = status::measure_stall_evidence(
                                probe_directory.as_deref(),
                                transcript.as_deref(),
                                baseline.as_ref(),
                            );
                            let _ = tx.send(StallResult {
                                generation,
                                directory,
                                measured,
                                capture: false,
                            });
                        });
                    }
                }
            }
            Some(result) = stall_rx.recv() => {
                let assessment = session.status_engine.apply_stall_measurement(
                    result.generation,
                    result.directory,
                    &result.measured,
                    result.capture,
                    std::time::Instant::now(),
                );
                if let Some(status::Assessment::Stalled { transcript_lines_grown }) = assessment {
                    let working_seconds = session
                        .status_engine
                        .working_since()
                        .map(|since| since.elapsed().as_secs())
                        .unwrap_or(0);
                    // Watch-plane only: the session's real status stays
                    // `working`. A stall is evidence, not a state, and nothing
                    // about it is certain enough to move a dot.
                    session.emit_event(Event::Stalled {
                        session: session.id.to_string(),
                        working_seconds,
                        transcript_lines_grown: transcript_lines_grown as u64,
                    });
                }
            }
            _ = tokio::task::yield_now(), if !history_stages.is_empty() => {
                let client_id = history_stages
                    .pop_front()
                    .expect("history stage queue became empty");
                if session.continue_history(&client_id) {
                    history_stages.push_back(client_id);
                }
            }
            msg = rx.recv() => {
                let Some(msg) = msg else { break };
                if let SessionMsg::Carry { reply } = msg {
                    let session_id = session.id.clone();
                    // The one exit from this loop that is not an ending. No
                    // reap, no `on_exit`, no tombstone: the child keeps running
                    // and the daemon that reads it next is this same process
                    // with different code in it. Returning here drops the
                    // `Session` — and with it the original PTY descriptor,
                    // which is why `into_carried` duplicated one first.
                    session.send_sidecar(SidecarCommand::Shutdown);
                    let carried = session.into_carried();
                    // The parser is a few kilobytes of grid and a thread that
                    // has already been told to stop; joining it here costs a
                    // scheduler turn on a runtime that is about to cease to
                    // exist, and skipping it would leave the thread running
                    // into the exec.
                    let _ = tokio::task::spawn_blocking(move || sidecar_thread.join()).await;
                    match carried {
                        Ok(carried) => {
                            let _ = reply.send(carried);
                            return;
                        }
                        Err(error) => {
                            // The descriptor could not be duplicated, so this
                            // session cannot cross. Dropping `reply` is what
                            // tells the daemon so, in time for it to name the
                            // session in its report rather than lose it
                            // silently at the exec.
                            eprintln!(
                                "termiod: session {session_id} cannot be carried across a handoff: {error:#}"
                            );
                            return;
                        }
                    }
                }
                if let Some(reason) = handle_msg(&mut session, msg) {
                    end_reason = reason;
                    break;
                }
            }
            result = sidecar_results.recv(), if sidecar_results_open => {
                match result {
                    Some(SidecarResult::Snapshot { client_id, request_id, result }) => {
                        if session.finish_snapshot(&client_id, request_id, result) {
                            history_stages.push_back(client_id);
                        }
                    }
                    Some(SidecarResult::Grid(grid)) => session.fan_out_grid(grid),
                    Some(SidecarResult::Keyframe(snapshot)) => {
                        session.fan_out_keyframe(snapshot);
                    }
                    Some(SidecarResult::Osc(signals)) => {
                        let now = std::time::Instant::now();
                        for signal in signals {
                            let change = match signal {
                                OscSignal::Title(title) => {
                                    // The live title is the row's name as well
                                    // as a status channel: a client attached
                                    // straight to this box has no other source
                                    // for it, and the Mac's surface callback is
                                    // about to stop being one.
                                    //
                                    // Stored, never broadcast on its own. A
                                    // spinner reprints several times a second,
                                    // so a roster event per frame would be a
                                    // fan-out storm for a string that changes
                                    // by one glyph. It rides the status event
                                    // when the status moves, and `info()` reads
                                    // the current one whenever a roster is
                                    // actually asked for.
                                    session.title = Some(title.clone());
                                    session.status_engine.note_title(&title, now)
                                }
                                OscSignal::Progress(activity) => {
                                    session.status_engine.note_progress(activity, now)
                                }
                            };
                            if let Some(change) = change {
                                session.apply_status_change(change);
                            }
                        }
                    }
                    Some(SidecarResult::Screen(tick)) => {
                        let now = std::time::Instant::now();
                        if let Some(change) =
                            session.status_engine.note_output(tick.changed, tick.bytes, now)
                        {
                            session.apply_status_change(change);
                        }
                        if let Some(text) = tick.text {
                            if let Some(change) = session.status_engine.note_screen(&text, now) {
                                session.apply_status_change(change);
                            }
                        }
                    }
                    None => {
                        sidecar_results_open = false;
                        // The VT is down for the reason any absent sidecar is —
                        // it cannot be asked — while the clients that were
                        // waiting on an answer are told what happened to them.
                        session.vt = Vt::down(sidecar::UNAVAILABLE);
                        session.disconnect_grid_clients("VT sidecar response channel closed");
                        session.fallback_all_pending("VT sidecar response channel closed");
                    }
                }
            }
            read = session.pty.read(&mut buf) => {
                match read {
                    Ok(0) => break,
                    Ok(n) => {
                        let chunk = Bytes::copy_from_slice(&buf[..n]);
                        // This refcount clone + unbounded send is strictly
                        // fire-and-forget. Fan-out never waits for VT parsing,
                        // and it runs even when the VT has gone stale.
                        session.write_sidecar(chunk.clone());
                        session.fan_out(chunk);
                    }
                    // Linux delivers EIO when the slave side closes.
                    Err(e) if e.raw_os_error() == Some(libc::EIO) => break,
                    Err(_) => break,
                }
            }
        }
    }

    session.fallback_all_pending("session ended before the VT snapshot completed");
    if end_reason == EndReason::Exited {
        if let Some(requested) = *termination_reason.lock().unwrap() {
            end_reason = requested;
        }
    }
    session.vt.shut_down();

    let code = match waiter.take() {
        Some(w) => w.await.unwrap_or(-1),
        None => -1,
    };
    // One final record, built after the reap and used for everything that
    // outlives the session: the exit event clients hear, and the tombstone the
    // manager buries. Sampling it twice would let the two disagree — the
    // interesting field, `child_executable_replaced`, is a fresh disk read every
    // time it is asked, and an agent that replaced its binary between the two
    // reads is exactly the case both consumers are for.
    //
    // `alive: false` — this record only ever describes a session that has ended.
    let mut info = session.info();
    info.alive = false;
    let exit_event = Event::SessionExited {
        session: session.id.to_string(),
        status: code,
        info: Some(Box::new(info.clone())),
    };
    let _ = session.events.send(exit_event.clone());
    for entry in session.clients.values() {
        let _ = entry.out.send(ClientEvent::Event(exit_event.clone()));
        let _ = entry.out.send(ClientEvent::Exited(code));
    }
    let _ = tokio::task::spawn_blocking(move || sidecar_thread.join()).await;
    let _ = on_exit.send(SessionEnded {
        info,
        status: code,
        reason: end_reason,
    });
}

fn handle_msg(session: &mut Session, msg: SessionMsg) -> Option<EndReason> {
    match msg {
        SessionMsg::AddClient {
            id,
            interactive,
            rows,
            cols,
            out,
            backlog,
            snapshot,
            scrollback,
            grid_diff,
            reply,
        } => {
            // Only interactive attachments are numbered: the sequence exists
            // to rank claims on the write token, and an observer is never in
            // that ranking.
            let role = if interactive {
                let seq = session.next_seq;
                session.next_seq += 1;
                ClientRole::Interactive { seq }
            } else {
                ClientRole::Observer
            };
            let old_writer = session.writer.clone();
            session.use_clock += 1;
            let use_stamp = session.use_clock;
            let snapshot_request = snapshot.then(|| session.allocate_snapshot_request());

            if !snapshot {
                for replay in &session.ring {
                    let Some(metered) = backlog.reserve(replay.clone()) else {
                        break;
                    };
                    if out.send(ClientEvent::Data(metered.clone())).is_err() {
                        backlog.release(&metered);
                        break;
                    }
                }
            }
            // A client that did not negotiate snapshots gets the raw plane and
            // no barrier; one that did starts behind the barrier its bootstrap
            // `S` will open. Grid diffs ride on top of the snapshot plane and
            // are unreachable without it.
            let plane = match snapshot_request {
                None => ClientPlane::Raw,
                Some(request_id) => {
                    let delivery = ClientDelivery::SnapshotPending {
                        request_id,
                        data: VecDeque::new(),
                        deferred: VecDeque::new(),
                    };
                    if grid_diff {
                        ClientPlane::Grid(delivery)
                    } else {
                        ClientPlane::Snapshot(delivery)
                    }
                }
            };
            session.clients.insert(
                id.clone(),
                ClientEntry {
                    out,
                    backlog,
                    role,
                    plane,
                    // An attach is a viewer arriving to look at the session, so
                    // it starts rendering. What it declares here is a best
                    // guess — the window it is going into may not have laid out
                    // yet, and says so with a zero.
                    viewport: (rows > 0 && cols > 0).then_some((rows, cols)),
                    rendering: true,
                    // Opening a session on a device is somebody using that
                    // device, so the newcomer sizes it. The Mac springs back the
                    // moment it is typed in again.
                    used: use_stamp,
                    staged_history: VecDeque::new(),
                    backlog_strikes: 0,
                },
            );
            // Enabling precedes this client's in-band Snapshot request, so
            // later Writes can only produce G results after its S boundary.
            session.sync_grid_diff_interest();
            // Attaching is a viewer arriving, not a device taking over. The
            // token travels by typing — both ends claim on input — so the only
            // attach that takes it is the one that finds nobody holding it.
            // What this attach *does* move is the size: opening a session on a
            // device is somebody using it, and the session sizes to the screen
            // in front of a person. That is `apply_size_policy` below and it is
            // deliberately not this decision.
            if interactive && session.writer.is_none() {
                session.grant_writer(&id);
            }
            let is_writer = session.writer.as_ref() == Some(&id);

            if let Some(request_id) = snapshot_request {
                session.request_snapshot(id.clone(), request_id, scrollback);
            }
            // After the bootstrap request, not before: a policy that moves the
            // size opens a barrier, and `begin_pending` is what supersedes the
            // bootstrap `S` with one taken at the new grid. Reversing these two
            // would leave the newcomer's own snapshot describing the old size.
            session.apply_size_policy();
            let _ = reply.send(AddClientReply {
                writer: is_writer,
                rows: session.rows,
                cols: session.cols,
            });

            if session.writer != old_writer {
                session.emit_writer_changed(old_writer);
            }
            session.emit_roster();
        }
        SessionMsg::RemoveClient { id } => {
            let old_writer = session.writer.clone();
            session.clients.remove(&id);
            session.sync_grid_diff_interest();
            if old_writer.as_ref() == Some(&id) {
                session.recompute_writer();
            }
            if session.writer != old_writer {
                session.emit_writer_changed(session.writer.clone());
            }
            // The viewer that left may have been the one holding the session
            // narrow; the rest of them get their width back.
            session.apply_size_policy();
            session.emit_roster();
        }
        SessionMsg::ResendSnapshot { id } => {
            let request_id = session.allocate_snapshot_request();
            let Some(entry) = session.clients.get_mut(&id) else {
                return None;
            };
            if !entry.plane.snapshots() {
                return None;
            }
            // The barrier has to be opened, not just the capture asked for.
            // `finish_snapshot` matches every answer against the request the
            // attachment is waiting on, so a capture nobody opened a barrier for
            // is discarded as stale — the client asks for a repaint, the sidecar
            // produces one, and it is dropped on the floor. That is a repair
            // that silently never happens, which is worse than not offering one.
            let superseded = entry.plane.begin_pending(request_id);
            release_buffered(&entry.backlog, superseded);
            // No scrollback: this repaints the viewport a client already has
            // room for, and history it never lost.
            session.request_snapshot(id, request_id, false);
        }
        SessionMsg::ClaimWriter { id, reply } => {
            // An observer is refused rather than promoted: it attached without a
            // tty, so there is no person behind it whose typing the token is
            // meant to follow. A stranger — a stale id, a racing reconnect — is
            // refused for the same reason `grant_writer` will not install a
            // writer nobody can reach.
            let held = session.writer.as_ref() == Some(&id);
            let eligible = session.grant_writer(&id);
            let _ = reply.send(eligible);
            if !eligible || held {
                return None;
            }
            // The client that just took the token is told so directly, the same
            // shape `AddClient` uses.
            session.emit_writer_changed(session.writer.clone());
        }
        SessionMsg::Input { id, data } => {
            if session.writer.as_ref() == Some(&id) {
                // The choke point every human keystroke crosses — this Mac, a
                // phone, a browser — which is what the screen-streak promotion
                // has to stand down for. The Mac's own version of this only ever
                // saw its own window's keys.
                session
                    .status_engine
                    .note_user_input(std::time::Instant::now());
                // The same fact the size policy runs on: somebody is typing
                // here, so this screen is the one to fit. A device report never
                // reaches this arm — clients send those on their own frame kind
                // — which is what keeps a terminal's answer to a query from
                // moving the size.
                session.note_use(&id);
                session.apply_size_policy();
                let _ = session.input_tx.send(data);
            } else {
                session.reject_not_writer(&id);
            }
        }
        SessionMsg::Viewport {
            id,
            rows,
            cols,
            rendering,
        } => {
            // Not gated on the write token, and that is the whole point: an
            // attachment saying how big it is is not a claim on the session.
            // Every viewer's declaration counts, and the policy decides.
            let Some(entry) = session.clients.get_mut(&id) else {
                return None;
            };
            let declared = (rows > 0 && cols > 0).then_some((rows, cols));
            if entry.viewport == declared && entry.rendering == rendering {
                return None;
            }
            entry.viewport = declared;
            entry.rendering = rendering;
            // Resizing a window, collapsing its sidebar, turning a phone: the
            // person is on this device. A screen that only stopped rendering is
            // not — nobody is looking at it, so it must not take the size with
            // it on the way out.
            if rendering {
                session.note_use(&id);
            }
            session.apply_size_policy();
        }
        SessionMsg::Inject { data } => {
            let _ = session.input_tx.send(data);
        }
        SessionMsg::SetStatus {
            status,
            title,
            details,
            reply,
        } => {
            if title.is_some() {
                session.title = title;
            }
            if let Some(path) = details.transcript_path.as_deref() {
                // Probe 3 measures this file's growth, and a hook is the only
                // thing that knows where an agent writes.
                session.transcript_path = Some(path.to_string());
            }
            let change = session
                .status_engine
                .note_hook(&status, std::time::Instant::now());
            session.status = session.status_engine.wire_status();
            // The report's four facts ride the event whether or not the state
            // moved — a tool name on a session already working is still news —
            // so this event is built here rather than through
            // `apply_status_change`.
            session.emit_event(Event::Status {
                session: session.id.to_string(),
                status: session.status.clone(),
                source: Some(status::StatusSource::Hook.as_str().to_string()),
                turn_ended: change.is_some_and(|change| change.turn_ended),
                blocking: session.status_engine.blocking_attention(),
                title: session.title.clone(),
                transcript_path: details.transcript_path,
                conversation_id: details.conversation_id,
                tool: details.tool,
                prompt_title: details.prompt_title,
            });
            let _ = reply.send(());
        }
        SessionMsg::Info { reply } => {
            let _ = reply.send(session.info());
        }
        // Intercepted in `run` before it reaches here: handing a session over
        // ends the actor without ending the session, which is not something a
        // handler returning `Option<EndReason>` can express. Dropping `reply`
        // un-answered is the right degradation anyway — the daemon reads a
        // dropped reply as a session that could not be carried, and names it.
        SessionMsg::Carry { .. } => {}
        SessionMsg::Kill { reason } => {
            // The child is a session leader, so pgid == pid.
            unsafe {
                libc::kill(-session.pid, libc::SIGKILL);
            }
            return Some(reason);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{
        daemon_owned_env, handle_msg, should_emit_keyframe, spawn_sidecar, ClientBacklog,
        ClientDelivery, ClientEntry, ClientEvent, ClientPlane, ClientRole, Session, SessionHandle,
        SessionMsg, Sidecar, SidecarCommand, SidecarQueue, SidecarResult, Vt,
    };
    use crate::id::{ClientId, SessionId};
    use crate::protocol::{Control, ErrorCode, Event, SessionInfo};
    use crate::pty::Pty;
    use crate::tombstone::EndReason;
    use bytes::Bytes;
    use std::collections::{HashMap, VecDeque};
    use std::sync::{mpsc as std_mpsc, Arc};
    use tokio::sync::{broadcast, mpsc, oneshot};

    fn chunk(len: usize) -> Bytes {
        Bytes::from(vec![b'x'; len])
    }

    /// A hook reports with `termiod set-status --id "$TERMIOD_SESSION_ID"`, so a
    /// session that cannot name itself cannot report at all.
    #[test]
    fn session_env_carries_the_session_id() {
        let id = SessionId::new("s-42");
        let env = daemon_owned_env(&id, Vec::new());
        assert_eq!(
            env.iter()
                .find(|(key, _)| key == "TERMIOD_SESSION_ID")
                .map(|(_, value)| value.as_str()),
            Some("s-42")
        );
    }

    /// `Pty::spawn` applies the pairs in order, so the daemon's entries must come
    /// last — otherwise a client could name itself another session and report
    /// status on that session's behalf.
    #[test]
    fn daemon_env_outranks_a_client_supplied_value() {
        let id = SessionId::new("real");
        let env = daemon_owned_env(
            &id,
            vec![("TERMIOD_SESSION_ID".to_string(), "spoofed".to_string())],
        );
        assert_eq!(
            env.iter()
                .filter(|(key, _)| key == "TERMIOD_SESSION_ID")
                .last()
                .map(|(_, value)| value.as_str()),
            Some("real")
        );
    }

    /// The write token as a plain str, so the assertions read as they did
    /// when the roster was keyed by `String`.
    fn writer(session: &Session) -> Option<&str> {
        session.writer.as_ref().map(ClientId::as_str)
    }




    #[test]
    fn keyframe_cadence_replaces_every_nth_grid_flush() {
        assert!(!should_emit_keyframe(1, 4));
        assert!(!should_emit_keyframe(3, 4));
        assert!(should_emit_keyframe(4, 4));
        assert!(should_emit_keyframe(8, 4));
    }

    #[test]
    fn resize_snapshot_request_is_an_exact_sidecar_fifo_boundary() {
        let Sidecar {
            commands: sidecar,
            results: mut snapshots,
            queue,
            thread,
        } = spawn_sidecar(2, 16).unwrap();
        assert!(queue.try_reserve("BEFORE".len()));
        assert!(queue.try_reserve("AFTER".len()));
        sidecar
            .send(SidecarCommand::Write(Bytes::from_static(b"BEFORE")))
            .unwrap();
        sidecar
            .send(SidecarCommand::Resize { rows: 3, cols: 20, reflow: false })
            .unwrap();
        sidecar
            .send(SidecarCommand::Snapshot {
                client_id: ClientId::new("client"),
                request_id: 1,
                scrollback: false,
            })
            .unwrap();
        sidecar
            .send(SidecarCommand::Write(Bytes::from_static(b"AFTER")))
            .unwrap();

        let SidecarResult::Snapshot {
            request_id, result, ..
        } = snapshots.blocking_recv().unwrap()
        else {
            panic!("snapshot request returned a grid result");
        };
        assert_eq!(request_id, 1);
        let snapshot = result.unwrap().snapshot;
        assert_eq!((snapshot.rows, snapshot.cols), (3, 20));
        let screen: String = snapshot
            .cells
            .iter()
            .map(|cell| char::from_u32(cell.codepoint).unwrap_or(' '))
            .collect();
        assert!(screen.starts_with("BEFORE"));
        assert!(!screen.contains("AFTER"));

        sidecar.send(SidecarCommand::Shutdown).unwrap();
        thread.join().unwrap();
        // Every byte the session charged to the queue is credited back once the
        // VT has parsed it, or the budget ratchets shut on a healthy session.
        assert!(queue.is_drained());
    }

    /// A session with no clients, a live sidecar, and a PTY that only has to
    /// exist — none of the backlog paths touch it.
    fn test_session(
        sidecar_tx: std_mpsc::Sender<SidecarCommand>,
        sidecar_queue: Arc<SidecarQueue>,
    ) -> (Session, broadcast::Receiver<Event>) {
        let pty = Arc::new(Pty::non_pty_for_resize_failure_test().unwrap());
        let (input_tx, _input_rx) = mpsc::unbounded_channel();
        let (events, event_rx) = broadcast::channel(64);
        (
            Session {
                id: SessionId::new("session"),
                name: "test".to_string(),
                cwd: String::new(),
                command: "cat".to_string(),
                pid: 0,
                rows: 24,
                cols: 80,
                created_unix: 0,
                status: "unknown".to_string(),
                title: None,
                workstream: None,
                pty,
                input_tx,
                clients: HashMap::new(),
                writer: None,
                next_seq: 0,
                use_clock: 0,
                next_snapshot_request: 1,
                ring: VecDeque::new(),
                ring_bytes: 0,
                ring_reconstructs_screen: true,
                settle_nudge_at: None,
                events,
                vt: Vt::live(sidecar_tx, sidecar_queue),
                status_engine: super::StatusEngine::new(
                    std::time::Instant::now(),
                    super::status::SessionFacts::default(),
                ),
                transcript_path: None,
                foreground: super::Foreground::default(),
                resize_capture: None,
            },
            event_rx,
        )
    }

    /// Hand the session the sidecar replies it is waiting on. `run` does this in
    /// its select loop; the tests do it by hand so the barrier is deterministic.
    /// The count is awaited rather than polled — the VT is a real thread, so a
    /// `try_recv` here would race it and hide a working barrier as a hang.
    async fn pump_sidecar(
        session: &mut Session,
        results: &mut mpsc::UnboundedReceiver<SidecarResult>,
        expected: usize,
    ) {
        for _ in 0..expected {
            let result = tokio::time::timeout(std::time::Duration::from_secs(10), results.recv())
                .await
                .expect("the VT sidecar never answered")
                .expect("the VT sidecar hung up");
            apply_sidecar(session, result);
        }
        while let Ok(result) = results.try_recv() {
            apply_sidecar(session, result);
        }
    }

    fn apply_sidecar(session: &mut Session, result: SidecarResult) {
        match result {
            SidecarResult::Snapshot {
                client_id,
                request_id,
                result,
            } => {
                session.finish_snapshot(&client_id, request_id, result);
            }
            SidecarResult::Grid(grid) => session.fan_out_grid(grid),
            SidecarResult::Keyframe(snapshot) => session.fan_out_keyframe(snapshot),
            // The status half of the sidecar's output. These cases assert the
            // snapshot FIFO's boundaries; the engine has its own tests, and
            // routing them here would put a wall clock in an ordering test.
            SidecarResult::Osc(_) | SidecarResult::Screen(_) => {}
        }
    }

    fn attach_snapshot_client(
        session: &mut Session,
        id: &str,
    ) -> (mpsc::UnboundedReceiver<ClientEvent>, Arc<ClientBacklog>) {
        attach_client(session, id, true)
    }

    /// A client with a tty behind it — the kind that can hold the write token.
    /// It declares no viewport, which is a window that has not laid out yet.
    fn attach_interactive_client(
        session: &mut Session,
        id: &str,
    ) -> mpsc::UnboundedReceiver<ClientEvent> {
        attach_interactive_client_at(session, id, 0, 0)
    }

    fn attach_interactive_client_at(
        session: &mut Session,
        id: &str,
        rows: u16,
        cols: u16,
    ) -> mpsc::UnboundedReceiver<ClientEvent> {
        let (client_tx, client_rx) = mpsc::unbounded_channel();
        let (reply, _reply_rx) = oneshot::channel();
        handle_msg(
            session,
            SessionMsg::AddClient {
                id: ClientId::new(id),
                interactive: true,
                rows,
                cols,
                out: client_tx,
                backlog: Arc::new(ClientBacklog::new()),
                snapshot: false,
                scrollback: false,
                grid_diff: false,
                reply,
            },
        );
        client_rx
    }

    fn declare_viewport(session: &mut Session, id: &str, rows: u16, cols: u16, rendering: bool) {
        handle_msg(
            session,
            SessionMsg::Viewport {
                id: ClientId::new(id),
                rows,
                cols,
                rendering,
            },
        );
    }

    /// What a person does: take the token the way a keystroke does, then send
    /// the keystroke. `SessionMsg::Input` is rejected from anyone else, so both
    /// halves are needed to type at all.
    fn type_into(session: &mut Session, id: &str) {
        claim_writer(session, id);
        handle_msg(
            session,
            SessionMsg::Input {
                id: ClientId::new(id),
                data: b"x".to_vec(),
            },
        );
    }

    fn claim_writer(session: &mut Session, id: &str) -> bool {
        let (reply, mut reply_rx) = oneshot::channel();
        handle_msg(
            session,
            SessionMsg::ClaimWriter {
                id: ClientId::new(id),
                reply,
            },
        );
        reply_rx.try_recv().unwrap_or(false)
    }

    fn attach_client(
        session: &mut Session,
        id: &str,
        snapshot: bool,
    ) -> (mpsc::UnboundedReceiver<ClientEvent>, Arc<ClientBacklog>) {
        let (client_tx, client_rx) = mpsc::unbounded_channel();
        let backlog = Arc::new(ClientBacklog::new());
        let (reply, _reply_rx) = oneshot::channel();
        handle_msg(
            session,
            SessionMsg::AddClient {
                id: ClientId::new(id),
                interactive: false,
                rows: 0,
                cols: 0,
                out: client_tx,
                backlog: backlog.clone(),
                snapshot,
                scrollback: false,
                grid_diff: false,
                reply,
            },
        );
        (client_rx, backlog)
    }

    /// Two devices on one session — a Mac and a phone showing the same agent.
    ///
    /// Attaching is what took the token before this verb existed, so the phone
    /// permanently muted the Mac the moment it looked at a session, and the Mac
    /// could only answer by tearing its attachment down and rebuilding it. The
    /// token travels by typing instead.
    #[tokio::test]
    async fn the_write_token_follows_the_device_being_used() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client(&mut session, "mac");
        assert_eq!(writer(&session), Some("mac"), "first in, writer");

        // Looking is not taking: the phone arrives as a reader, and the Mac —
        // whose window is the one sized for this PTY — keeps writing.
        let _phone = attach_interactive_client(&mut session, "phone");
        assert_eq!(writer(&session), Some("mac"));

        assert!(claim_writer(&mut session, "phone"), "the phone's user typed");
        assert_eq!(writer(&session), Some("phone"));

        assert!(claim_writer(&mut session, "mac"), "the Mac's user typed");
        assert_eq!(writer(&session), Some("mac"));

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// The session is the size of the screen a person is in front of, and the
    /// write token is not that signal.
    ///
    /// This is the whole of the policy. Every assertion here used to be false
    /// twice over: the size first followed whoever typed last *through the
    /// token*, so any byte that read as input moved it, and then followed the
    /// smallest viewer, so a phone left open on a session held a 200-column pane
    /// at 47 for as long as it stayed there.
    #[tokio::test]
    async fn the_session_is_the_viewport_of_the_device_being_used() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        assert_eq!(session.policy_size(), Some((50, 200)), "one viewer, its grid");

        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        assert_eq!(
            session.policy_size(),
            Some((42, 47)),
            "opening it on the phone is using the phone"
        );

        // Taking the token is not using the device: a client claims it to be
        // allowed to type, and the claim can arrive from a queued keystroke or a
        // handover. Only the typing itself counts.
        assert!(claim_writer(&mut session, "mac"));
        assert_eq!(session.policy_size(), Some((42, 47)), "a claim is not a use");

        type_into(&mut session, "mac");
        assert_eq!(
            session.policy_size(),
            Some((50, 200)),
            "typing on the Mac hands it the session"
        );

        type_into(&mut session, "phone");
        assert_eq!(session.policy_size(), Some((42, 47)), "and back again");

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// The answer is one screen's viewport, never a blend of two. Under
    /// smallest-wins a short wide pane beside a tall narrow phone produced a
    /// session that was short *and* narrow — a shape neither device had asked
    /// for and neither was using.
    #[tokio::test]
    async fn the_size_is_one_screen_and_not_a_blend_of_two() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _wide = attach_interactive_client_at(&mut session, "wide", 20, 200);
        let _tall = attach_interactive_client_at(&mut session, "tall", 60, 47);
        type_into(&mut session, "wide");
        assert_eq!(session.policy_size(), Some((20, 200)));

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// Resizing a window is using it: the pane that just widened is the one
    /// somebody has their hands on, so the session follows it there without
    /// waiting for a keystroke. This is the report that started it — collapsing
    /// the inspector while a second viewer was attached moved nothing at all.
    #[tokio::test]
    async fn changing_a_viewport_is_using_that_device() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        assert_eq!(session.policy_size(), Some((42, 47)));

        declare_viewport(&mut session, "mac", 50, 240, true);
        assert_eq!(
            session.policy_size(),
            Some((50, 240)),
            "the Mac's sidebar collapsed; the session is the Mac's again"
        );

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// Zellij's refinement: a pane on a background tab is not rendering, so it
    /// stops holding the session down to its width. Without this a Mac window
    /// left open on another workspace would pin every session it has a pane for.
    #[tokio::test]
    async fn an_attachment_that_stopped_rendering_stops_counting() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        assert_eq!(session.policy_size(), Some((42, 47)));

        declare_viewport(&mut session, "phone", 42, 47, false);
        assert_eq!(
            session.policy_size(),
            Some((50, 200)),
            "the phone put the session away; the Mac gets its width back"
        );

        declare_viewport(&mut session, "phone", 42, 47, true);
        assert_eq!(session.policy_size(), Some((42, 47)), "and back again");

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// With nobody looking there is no answer, and `apply_size_policy` leaves
    /// the session exactly where it was rather than inventing one.
    #[tokio::test]
    async fn nobody_rendering_leaves_the_size_alone() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        declare_viewport(&mut session, "mac", 50, 200, false);
        assert_eq!(session.policy_size(), None);
        let (rows, cols) = (session.rows, session.cols);
        session.apply_size_policy();
        assert_eq!((session.rows, session.cols), (rows, cols));

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// A window that has not laid out yet says so with a zero, and is not
    /// counted. Before this the phone's 24x80 stand-in, sent because its surface
    /// had not measured itself, would have squeezed every other viewer for as
    /// long as it took the first layout pass to arrive.
    #[tokio::test]
    async fn a_viewer_with_no_viewport_yet_does_not_count() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 0, 0);
        assert_eq!(session.policy_size(), Some((50, 200)));

        declare_viewport(&mut session, "phone", 42, 47, true);
        assert_eq!(session.policy_size(), Some((42, 47)));

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// The rule the reflow policy turns on, and the case that made the previous
    /// one wrong: `zsh -ilc exec claude` leaves no shell in the session at all,
    /// so "is a job running under the shell" was false for exactly the sessions
    /// a truncating resize mangles. A shell gets the mark-gated resize
    /// (`resize_for_shell`): reflow when its prompt rows are OSC 133-marked,
    /// truncation when they are not.
    #[tokio::test]
    async fn only_a_shell_gets_the_mark_gated_resize() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        for shell in ["/bin/zsh", "-zsh", "bash", "/usr/local/bin/fish"] {
            session.foreground.set_argv_for_tests(Some(vec![shell.to_string()]));
            assert!(
                session.foreground_is_a_shell(),
                "{shell} redraws its prompt from the old width"
            );
        }
        for program in ["claude", "/opt/homebrew/bin/codex", "vim", "less"] {
            session.foreground.set_argv_for_tests(Some(vec![program.to_string()]));
            assert!(
                !session.foreground_is_a_shell(),
                "{program} repaints from its own model and wants the rewrap"
            );
        }
        // Unreadable is treated as a shell: the truncating resize is the
        // conservative one.
        session.foreground.set_argv_for_tests(None);
        assert!(session.foreground_is_a_shell());

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// §A again, from the sizing side: an observer attached without a tty has no
    /// viewport, so `termio read` tailing a session cannot squeeze the window
    /// somebody is working in.
    #[tokio::test]
    async fn an_observer_never_sizes_the_session() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _reader = attach_client(&mut session, "reader", false);
        declare_viewport(&mut session, "reader", 10, 10, true);
        assert_eq!(session.policy_size(), Some((50, 200)));

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// The other half of that rule. A session nobody is holding hands the token
    /// to whoever attaches next, because that attach is the reattach path: the
    /// window coming back to a detached session is what resizes the PTY to fit
    /// it, and refusing the token here would strand the session at the size the
    /// last viewer happened to leave.
    #[tokio::test]
    async fn a_session_nobody_holds_gives_the_token_to_the_next_attach() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client(&mut session, "mac");
        assert_eq!(writer(&session), Some("mac"));

        handle_msg(
            &mut session,
            SessionMsg::RemoveClient {
                id: ClientId::new("mac"),
            },
        );
        assert_eq!(writer(&session), None, "nobody is left to write");

        let _reattached = attach_interactive_client(&mut session, "mac-again");
        assert_eq!(writer(&session), Some("mac-again"));

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// §A: observers never claim the write token. One that could would strand
    /// the session at the last real client's size — it has no tty to resize.
    #[tokio::test]
    async fn an_observer_is_refused_the_write_token() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client(&mut session, "mac");
        let (_watcher, _backlog) = attach_client(&mut session, "watcher", false);

        assert!(!claim_writer(&mut session, "watcher"));
        assert_eq!(
            writer(&session),
            Some("mac"),
            "a refused claim must not disturb the writer it failed to displace"
        );

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// A claim from a client that never attached — a stale id, a racing
    /// reconnect — is refused rather than installing a writer nobody can reach.
    #[tokio::test]
    async fn a_stranger_cannot_claim_the_write_token() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _mac = attach_interactive_client(&mut session, "mac");
        assert!(!claim_writer(&mut session, "ghost"));
        assert_eq!(writer(&session), Some("mac"));

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// What a client got, in the order it got it. `ClientEvent` carries wire
    /// payloads and no `Debug`, so the assertions compare this instead.
    #[derive(Debug, PartialEq, Eq)]
    enum Received {
        Data(Vec<u8>),
        Snapshot,
        Ready,
    }

    /// Everything waiting for a client, minus the control traffic an attach
    /// emits — delivery order is what the barrier can break, not the greeting.
    fn drain(client: &mut mpsc::UnboundedReceiver<ClientEvent>) -> Vec<Received> {
        let mut seen = Vec::new();
        while let Ok(event) = client.try_recv() {
            match event {
                ClientEvent::Data(payload) => seen.push(Received::Data(payload.bytes.to_vec())),
                ClientEvent::Snapshot(_) => seen.push(Received::Snapshot),
                ClientEvent::Event(Event::Ready { .. }) => seen.push(Received::Ready),
                _ => {}
            }
        }
        seen
    }

    /// JOIN's second half (§C.5): an attaching client may not affect anyone
    /// else's delivery. `tests/join_invariant.rs` can only observe that through
    /// two consumers racing a flood, where a reader that is merely behind looks
    /// exactly like a stall — so it proves the joining client's boundary and
    /// leaves this to a test that can hold the barrier open on purpose.
    ///
    /// Here the snapshot request is never answered, so the joining client sits
    /// in `SnapshotPending` for the whole test. Any stall the barrier imposed on
    /// the live client — for a moment or forever — is a missing `Data` below.
    #[tokio::test]
    async fn a_pending_snapshot_never_holds_up_another_client() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        // The control: never negotiates `snapshot`, so it stays `Live`.
        let (mut live, _live_backlog) = attach_client(&mut session, "live", false);
        session.fan_out(Bytes::from_static(b"before"));
        assert_eq!(
            drain(&mut live),
            vec![Received::Data(b"before".to_vec())],
            "the live client did not receive its pre-attach bytes"
        );

        // The barrier opens here and is deliberately left open.
        let (mut joining, _joining_backlog) = attach_client(&mut session, "joining", true);
        assert!(
            matches!(
                session.clients[&ClientId::new("joining")].plane,
                ClientPlane::Snapshot(ClientDelivery::SnapshotPending { .. })
            ),
            "the joining client is not behind a barrier, so this proves nothing"
        );

        session.fan_out(Bytes::from_static(b"during"));
        assert_eq!(
            drain(&mut live),
            vec![Received::Data(b"during".to_vec())],
            "the pending snapshot held up the live client"
        );
        assert!(
            drain(&mut joining).is_empty(),
            "the joining client received its stream before the S that opens it"
        );

        // The other half of the invariant: those bytes were buffered, not lost.
        // Once the snapshot lands they follow it, in order.
        pump_sidecar(&mut session, &mut results, 1).await;
        assert_eq!(
            drain(&mut joining),
            vec![
                Received::Snapshot,
                Received::Ready,
                Received::Data(b"during".to_vec())
            ],
            "the snapshot boundary and the bytes buffered behind it did not line up"
        );

        session.vt.shut_down();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// A resize's keyframe has to describe the screen the *child* redrew.
    ///
    /// The capture used to be adjacent to the sidecar's `Resize`, which by
    /// construction snapshotted the screen the rewrap had just produced and the
    /// child had not yet answered — so every resize handed every attachment a
    /// full-screen paint of a screen that was about to be replaced, and that
    /// frame is what a window drag looked like. The barrier still opens with
    /// the resize, so nothing reaches a client ahead of the new grid; only the
    /// capture waits.
    #[tokio::test]
    async fn a_resize_keyframe_carries_the_child_s_redraw() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        let (mut client, _backlog) = attach_snapshot_client(&mut session, "viewer");
        pump_sidecar(&mut session, &mut results, 1).await;
        assert_eq!(
            drain(&mut client),
            vec![Received::Snapshot, Received::Ready],
            "the attach bootstrap never landed, so this test proves nothing"
        );

        // The screen as the child last drew it, before anything moved. Through
        // `write_sidecar`, which is the path a live PTY byte takes.
        session.write_sidecar(Bytes::from_static(b"STALE"));

        session.begin_resize_snapshot_barrier();
        let armed = session
            .resize_capture_deadline()
            .expect("the resize armed no capture");
        assert!(
            session.clients[&ClientId::new("viewer")].plane.is_pending(),
            "the barrier must open with the resize, not with its capture"
        );
        assert!(
            session.resize_capture_deadline().is_some(),
            "the capture was asked for adjacent to the resize again"
        );
        assert!(
            drain(&mut client).is_empty(),
            "a screen reached the client before the boundary that describes it"
        );

        // What the child writes when it answers SIGWINCH. It reaches the VT
        // ahead of the capture, which is the whole point.
        session.write_sidecar(Bytes::from_static(b"\x1b[2J\x1b[HREDRAWN"));
        assert!(
            session
                .resize_capture_deadline()
                .expect("the capture was given up on")
                < armed,
            "the child answered and the capture still waited out its deadline — \
             every viewer's `E resized` pays for that wait"
        );

        session.capture_resize_snapshots();
        pump_sidecar(&mut session, &mut results, 1).await;

        let mut painted = Vec::new();
        while let Ok(event) = client.try_recv() {
            if let ClientEvent::Snapshot(snapshot) = event {
                painted = snapshot.vt.clone().unwrap_or_default();
            }
        }
        let painted = String::from_utf8_lossy(&painted).to_string();
        assert!(
            painted.contains("REDRAWN"),
            "the keyframe missed the redraw the child answered the resize with: {painted:?}"
        );
        assert!(
            !painted.contains("STALE"),
            "the keyframe painted the screen the child had already replaced: {painted:?}"
        );

        session.vt.shut_down();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// A resync a client asks for has to actually repaint it.
    ///
    /// `finish_snapshot` matches every capture against the request the
    /// attachment is waiting on, so a `ResendSnapshot` that asked the sidecar
    /// for a capture without opening the barrier had its answer discarded as
    /// stale. The client asked for a repaint, the sidecar produced one, and
    /// nobody ever saw it — a repair that silently never happens, which is
    /// worse than not offering one. It is the fallback the resize path leans on
    /// when a keyframe cannot wait for its surface, and the phone bridge's only
    /// recovery from bytes it dropped downstream.
    #[tokio::test]
    async fn a_resync_a_client_asked_for_reaches_it() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        let (mut client, _backlog) = attach_snapshot_client(&mut session, "viewer");
        pump_sidecar(&mut session, &mut results, 1).await;
        assert_eq!(
            drain(&mut client),
            vec![Received::Snapshot, Received::Ready],
            "the attach bootstrap never landed, so this test proves nothing"
        );

        handle_msg(
            &mut session,
            SessionMsg::ResendSnapshot {
                id: ClientId::new("viewer"),
            },
        );
        assert!(
            matches!(
                session.clients[&ClientId::new("viewer")].plane,
                ClientPlane::Snapshot(ClientDelivery::SnapshotPending { .. })
            ),
            "the resync opened no barrier, so its answer will be discarded as stale"
        );

        // Bytes written while the repaint is being captured ride behind it, the
        // same way they do behind a resize's.
        session.fan_out(Bytes::from_static(b"during"));
        pump_sidecar(&mut session, &mut results, 1).await;
        assert_eq!(
            drain(&mut client),
            vec![
                Received::Snapshot,
                Received::Ready,
                Received::Data(b"during".to_vec())
            ],
            "the resync this client asked for never reached it"
        );

        session.vt.shut_down();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// D4(a): the first time a client outruns its budget it is resynced, not
    /// dropped — the queued bytes are retired, a fresh `S`/`ready` pair
    /// re-establishes JOIN, and `resynced` says why. The second overflow is the
    /// drop, because a client that cannot keep up from a clean start is wedged.
    #[tokio::test]
    async fn backlog_pressure_resyncs_a_client_once_before_dropping_it() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        let (mut client, backlog) = attach_snapshot_client(&mut session, "slow");
        pump_sidecar(&mut session, &mut results, 1).await;
        // The attach snapshot: S, then ready.
        assert!(matches!(
            client.recv().await,
            Some(ClientEvent::Snapshot(_))
        ));
        assert!(matches!(
            client.recv().await,
            Some(ClientEvent::Event(Event::Ready { .. }))
        ));

        // Nothing on the far end ever releases, so the budget fills for real.
        let mib = chunk(1024 * 1024);
        for _ in 0..(super::backlog::CAP_FOR_TESTS / mib.len()) {
            session.fan_out(mib.clone());
        }
        assert!(backlog.reserve(chunk(1)).is_none(), "budget is not full");
        assert!(session.clients.contains_key(&ClientId::new("slow")));

        // The overflow chunk. It is not delivered — it is what the snapshot
        // replaces — and the client survives it.
        session.fan_out(mib.clone());
        assert!(
            session.clients.contains_key(&ClientId::new("slow")),
            "the first overflow dropped the client instead of resyncing it"
        );
        assert!(
            backlog.is_drained(),
            "the resync did not retire the queued backlog"
        );
        pump_sidecar(&mut session, &mut results, 1).await;

        let mut kinds = Vec::new();
        while let Ok(event) = client.try_recv() {
            kinds.push(match event {
                ClientEvent::Data(_) => "D".to_string(),
                ClientEvent::Snapshot(_) => "S".to_string(),
                ClientEvent::Event(Event::Ready { .. }) => "ready".to_string(),
                ClientEvent::Event(Event::Resynced { reason, .. }) => format!("resynced:{reason}"),
                _ => "other".to_string(),
            });
        }
        let boundary = kinds
            .iter()
            .position(|kind| kind == "S")
            .expect("no fresh S after the forced resync");
        assert_eq!(kinds[boundary + 1], "ready", "S was not followed by ready");
        assert!(
            kinds[boundary..]
                .iter()
                .any(|kind| kind.starts_with("resynced:output backlog exceeded")),
            "the client was never told why its stream restarted: {kinds:?}"
        );

        // Second strike. The client starts from an empty budget and still
        // cannot drain, so this time it goes.
        for _ in 0..(super::backlog::CAP_FOR_TESTS / mib.len()) {
            session.fan_out(mib.clone());
        }
        session.fan_out(mib.clone());
        assert!(
            !session.clients.contains_key(&ClientId::new("slow")),
            "the second overflow did not drop the client"
        );
        assert!(backlog.is_dropped());

        session.vt.shut_down();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// D4(b): the sidecar budget's only legal degrade. Bytes reach every client
    /// unchanged; what stops is the VT, which then refuses snapshots instead of
    /// answering one that describes a screen that never occurred.
    #[tokio::test]
    async fn an_over_budget_sidecar_goes_stale_without_costing_a_client_one_byte() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        // Park the whole budget so the next PTY chunk cannot be admitted. This
        // stands in for a VT parse that has stopped making progress.
        assert!(queue.try_reserve(super::sidecar::CAP_FOR_TESTS));
        let (mut session, mut events) = test_session(commands, queue);
        let (mut client, _backlog) = attach_snapshot_client(&mut session, "raw");
        pump_sidecar(&mut session, &mut results, 1).await;
        assert!(matches!(
            client.recv().await,
            Some(ClientEvent::Snapshot(_))
        ));
        assert!(matches!(
            client.recv().await,
            Some(ClientEvent::Event(Event::Ready { .. }))
        ));

        let chunk = Bytes::from_static(b"still mine\r\n");
        session.write_sidecar(chunk.clone());
        session.fan_out(chunk.clone());

        assert!(
            session
                .vt
                .refusal()
                .is_some_and(|reason| reason.contains("behind the PTY")),
            "the budget did not bite"
        );
        let mut announced = false;
        while let Ok(event) = events.try_recv() {
            announced |= matches!(event, Event::VtStale { .. });
        }
        assert!(announced, "the stale VT was never announced");
        // The invariant this whole budget exists to protect: the client's bytes
        // are not what gets sacrificed.
        let mut delivered = Vec::new();
        while let Ok(event) = client.try_recv() {
            if let ClientEvent::Data(payload) = event {
                delivered.extend_from_slice(&payload.bytes);
            }
        }
        assert_eq!(delivered, chunk, "a stale VT cost the client PTY bytes");

        // A client attaching now is told the truth by falling back to the ring
        // rather than being handed a snapshot the VT can no longer vouch for.
        // No sidecar round trip this time: a stale VT is refused in-process.
        let (mut late, _late_backlog) = attach_snapshot_client(&mut session, "late");
        pump_sidecar(&mut session, &mut results, 0).await;
        let mut replayed = Vec::new();
        let mut snapshots = 0;
        while let Ok(event) = late.try_recv() {
            match event {
                ClientEvent::Snapshot(_) => snapshots += 1,
                ClientEvent::Data(payload) => replayed.extend_from_slice(&payload.bytes),
                _ => {}
            }
        }
        assert_eq!(snapshots, 0, "a stale VT still answered a snapshot");
        assert_eq!(replayed, chunk, "the ring-replay fallback did not run");

        session.vt.shut_down();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// A PTY that refuses to resize leaves the session where it was, and says
    /// so in the daemon's log rather than to a client: the size is a policy over
    /// the whole attachment set, so there is no requester to answer. Nothing
    /// downstream may move — a `Resized` event or a sidecar barrier for a resize
    /// that did not happen would leave every viewer repainting for a grid the
    /// PTY does not have.
    #[tokio::test]
    async fn failed_pty_resize_preserves_state_and_tells_nobody() {
        let pty = Arc::new(Pty::non_pty_for_resize_failure_test().unwrap());
        let (input_tx, _input_rx) = mpsc::unbounded_channel();
        let (events, mut event_rx) = broadcast::channel(8);
        let (client_tx, mut client_rx) = mpsc::unbounded_channel();
        let backlog = Arc::new(ClientBacklog::new());
        let (sidecar_tx, sidecar_rx) = std_mpsc::channel();
        let mut session = Session {
            id: SessionId::new("session"),
            name: "test".to_string(),
            cwd: String::new(),
            command: "cat".to_string(),
            pid: 0,
            rows: 24,
            cols: 80,
            created_unix: 0,
            status: "unknown".to_string(),
            title: None,
            workstream: None,
            pty,
            input_tx,
            clients: HashMap::from([(
                ClientId::new("writer"),
                ClientEntry {
                    out: client_tx,
                    backlog,
                    role: ClientRole::Interactive { seq: 1 },
                    plane: ClientPlane::Raw,
                    viewport: Some((24, 80)),
                    rendering: true,
                    used: 1,
                    staged_history: VecDeque::new(),
                    backlog_strikes: 0,
                },
            )]),
            writer: Some(ClientId::new("writer")),
            next_seq: 2,
            use_clock: 0,
            next_snapshot_request: 1,
            ring: VecDeque::new(),
            ring_bytes: 0,
            ring_reconstructs_screen: true,
            settle_nudge_at: None,
            events,
            vt: Vt::live(sidecar_tx, Arc::new(SidecarQueue::new())),
            status_engine: super::StatusEngine::new(
                std::time::Instant::now(),
                super::status::SessionFacts::default(),
            ),
            transcript_path: None,
            foreground: super::Foreground::default(),
            resize_capture: None,
        };

        assert!(handle_msg(
            &mut session,
            SessionMsg::Viewport {
                id: ClientId::new("writer"),
                rows: 40,
                cols: 120,
                rendering: true,
            },
        )
        .is_none());

        assert_eq!((session.rows, session.cols), (24, 80));
        assert!(matches!(
            sidecar_rx.try_recv(),
            Err(std_mpsc::TryRecvError::Empty)
        ));
        assert!(matches!(
            event_rx.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
        assert!(
            client_rx.try_recv().is_err(),
            "a failed resize is the daemon's problem, not a client's error"
        );
    }

    /// Drive a real session until its sampled foreground satisfies `ready`, or
    /// give up. The poll runs on a fixed cadence and the first tick can land
    /// before the child has exec'd, so a test that reads once reads the wrong
    /// process.
    async fn settled_info(
        handle: &SessionHandle,
        ready: impl Fn(&SessionInfo) -> bool,
    ) -> SessionInfo {
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
        let mut last = None;
        while tokio::time::Instant::now() < deadline {
            let (tx, rx) = oneshot::channel();
            if !handle.send(SessionMsg::Info { reply: tx }) {
                break;
            }
            let Ok(info) = rx.await else { break };
            if ready(&info) {
                return info;
            }
            last = Some(info);
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        panic!("the session never reported the expected foreground: {last:?}");
    }

    /// Both receivers are handed back rather than dropped here: a broadcast
    /// channel with no receiver discards every send, and the roster assertion
    /// reads one of them.
    #[allow(clippy::type_complexity)]
    fn start_session(
        argv: Vec<String>,
        cwd: &str,
    ) -> (
        SessionHandle,
        broadcast::Receiver<Event>,
        mpsc::UnboundedReceiver<super::SessionEnded>,
    ) {
        let (on_exit, on_exit_rx) = mpsc::unbounded_channel();
        let (events, events_rx) = broadcast::channel(64);
        let handle = super::spawn(
            SessionId::new("foreground-session"),
            "test".to_string(),
            cwd.to_string(),
            argv.join(" "),
            argv,
            Vec::new(),
            24,
            80,
            None,
            on_exit,
            events,
        )
        .expect("spawning a real session");
        (handle, events_rx, on_exit_rx)
    }

    /// A resize invalidates the ring as a source of truth for the screen: the
    /// bytes already in it were written into a differently shaped grid, and
    /// replaying them into this one puts them in the wrong places. Nothing in
    /// this daemon cares — its VT was fed every byte as it arrived — but the far
    /// side of a handoff has only the ring, and must be told not to trust it.
    #[tokio::test]
    async fn a_resize_makes_the_ring_stop_describing_the_screen() {
        let untouched = attached_session().await;
        let carried = carry(&untouched.handle).await;
        assert!(
            carried.info.ring_reconstructs_screen,
            "a session nothing has resized should carry a usable ring"
        );

        let resized = attached_session().await;
        resized.handle.send(SessionMsg::Viewport {
            id: ClientId::new("writer"),
            rows: 40,
            cols: 120,
            rendering: true,
        });
        let carried = carry(&resized.handle).await;
        assert!(
            !carried.info.ring_reconstructs_screen,
            "a resized session must not claim its ring still draws its screen"
        );
    }

    /// A session handed over with a ring that cannot draw its screen comes back
    /// with its VT stale, so snapshots fall back to ring replay instead of the
    /// host asserting a grid it reconstructed from bytes it was told are wrong.
    #[tokio::test]
    async fn an_unfaithful_ring_comes_back_with_a_vt_that_refuses_snapshots() {
        let session = attached_session().await;
        session.handle.send(SessionMsg::Viewport {
            id: ClientId::new("writer"),
            rows: 40,
            cols: 120,
            rendering: true,
        });
        let mut carried = carry(&session.handle).await;
        assert!(!carried.info.ring_reconstructs_screen);

        // Adopt it the way a new image would.
        use std::os::fd::IntoRawFd as _;
        carried.info.master_fd = carried.master.into_raw_fd();
        let (on_exit, _on_exit_rx) = mpsc::unbounded_channel();
        let (events, mut events_rx) = broadcast::channel(64);
        let adopted = super::adopt(carried.info, Vec::new(), on_exit, events)
            .expect("adopting the carried session");

        // The adopting actor declares its VT unusable rather than answering
        // snapshots from a screen it reconstructed out of bytes it was told
        // are wrong.
        let stale = tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                match events_rx.recv().await {
                    Ok(Event::VtStale { reason, .. }) => return reason,
                    Ok(_) => continue,
                    Err(error) => panic!("event stream ended: {error}"),
                }
            }
        })
        .await
        .expect("the adopted session declared its VT stale");
        assert!(stale.contains("handoff"), "{stale}");

        adopted.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// A client handed an unfaithful ring replay must not be left staring at
    /// it until the program happens to print. An idle program never does, and
    /// a viewer at the session's own size gets no resize to force a repaint
    /// either — so the fallback itself nudges the foreground with the SIGWINCH
    /// a resize would have delivered, and the repaint arrives as fresh output.
    #[tokio::test]
    async fn a_knowingly_wrong_replay_nudges_the_foreground_to_repaint() {
        let (handle, _events, _on_exit) = start_session(
            vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "trap 'echo NUDGED' WINCH; echo READY; while :; do read line; done".to_string(),
            ],
            "/",
        );

        // Wait for the child to say the trap is installed; before that a
        // nudge would be absorbed by the default disposition and prove
        // nothing.
        let (ready_tx, mut ready_rx) = mpsc::unbounded_channel();
        let (reply, answer) = oneshot::channel();
        handle.send(SessionMsg::AddClient {
            id: ClientId::new("watcher"),
            interactive: true,
            rows: 24,
            cols: 80,
            out: ready_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: false,
            scrollback: false,
            grid_diff: false,
            reply,
        });
        answer.await.expect("attached");
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            let mut seen = Vec::new();
            loop {
                match ready_rx.recv().await {
                    Some(ClientEvent::Data(payload)) => {
                        seen.extend_from_slice(&payload.bytes);
                        if String::from_utf8_lossy(&seen).contains("READY") {
                            return;
                        }
                    }
                    Some(_) => continue,
                    None => panic!("client stream ended before READY"),
                }
            }
        })
        .await
        .expect("the child announced its trap");

        // Hand the session over with a ring declared unfaithful — the far side
        // of a handoff whose output predates what drew the screen. No resize is
        // involved, so the only SIGWINCH the child can ever see is the nudge.
        let mut carried = carry(&handle).await;
        carried.info.ring_reconstructs_screen = false;
        use std::os::fd::IntoRawFd as _;
        carried.info.master_fd = carried.master.into_raw_fd();
        let (on_exit, _on_exit_rx) = mpsc::unbounded_channel();
        let (events, mut events_rx) = broadcast::channel(64);
        let adopted = super::adopt(carried.info, Vec::new(), on_exit, events)
            .expect("adopting the carried session");
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                match events_rx.recv().await {
                    Ok(Event::VtStale { .. }) => return,
                    Ok(_) => continue,
                    Err(error) => panic!("event stream ended: {error}"),
                }
            }
        })
        .await
        .expect("the adopted session declared its VT stale");

        // Attach at the session's own size: no resize fires, so without the
        // nudge nothing would ever repaint this screen.
        let (client_tx, mut client_rx) = mpsc::unbounded_channel();
        let (reply, answer) = oneshot::channel();
        adopted.send(SessionMsg::AddClient {
            id: ClientId::new("viewer"),
            interactive: true,
            rows: 24,
            cols: 80,
            out: client_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: true,
            scrollback: false,
            grid_diff: false,
            reply,
        });
        answer.await.expect("attached to the adopted session");

        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            let mut seen = Vec::new();
            loop {
                match client_rx.recv().await {
                    Some(ClientEvent::Data(payload)) => {
                        seen.extend_from_slice(&payload.bytes);
                        if String::from_utf8_lossy(&seen).contains("NUDGED") {
                            return;
                        }
                    }
                    Some(_) => continue,
                    None => panic!("client stream ended before the repaint"),
                }
            }
        })
        .await
        .expect("the unfaithful replay was followed by a nudged repaint");

        adopted.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// A resize is followed, once it has stood for the settle window, by one
    /// more SIGWINCH to a non-shell foreground: the child's answer to the
    /// resize raced the grid change, and its post-settle repaint is the only
    /// thing that can overwrite whatever the race painted. The child counts the
    /// signals — the resize's own ioctl delivers the first, the settle nudge
    /// the second.
    #[tokio::test]
    async fn a_settled_resize_nudges_a_job_foreground_once_more() {
        let script = "import signal,sys,time\n\
                      signal.signal(signal.SIGWINCH, lambda *a: print('NUDGED', flush=True))\n\
                      print('READY', flush=True)\n\
                      while True: time.sleep(0.05)\n";
        let (handle, _events, _on_exit) = start_session(
            vec![
                "/usr/bin/python3".to_string(),
                "-c".to_string(),
                script.to_string(),
            ],
            "/",
        );
        let (client_tx, mut client_rx) = mpsc::unbounded_channel();
        let (reply, answer) = oneshot::channel();
        handle.send(SessionMsg::AddClient {
            id: ClientId::new("writer"),
            interactive: true,
            rows: 24,
            cols: 80,
            out: client_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: false,
            scrollback: false,
            grid_diff: false,
            reply,
        });
        answer.await.expect("attached");

        async fn receive_until(
            rx: &mut mpsc::UnboundedReceiver<ClientEvent>,
            seen: &mut Vec<u8>,
            marker: &str,
        ) {
            loop {
                match rx.recv().await {
                    Some(ClientEvent::Data(payload)) => {
                        seen.extend_from_slice(&payload.bytes);
                        if String::from_utf8_lossy(seen).contains(marker) {
                            return;
                        }
                    }
                    Some(_) => continue,
                    None => panic!("client stream ended waiting for {marker}"),
                }
            }
        }
        let mut seen = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(10),
            receive_until(&mut client_rx, &mut seen, "READY"),
        )
        .await
        .expect("the child installed its handler");

        // The foreground poller must see python3 before the resize, or the
        // rewrap/nudge gates still believe a shell is on screen.
        tokio::time::sleep(std::time::Duration::from_millis(600)).await;
        handle.send(SessionMsg::Viewport {
            id: ClientId::new("writer"),
            rows: 30,
            cols: 100,
            rendering: true,
        });

        // Two signals: the resize's own SIGWINCH, then the settle nudge.
        tokio::time::timeout(
            std::time::Duration::from_secs(10),
            receive_until(&mut client_rx, &mut seen, "NUDGED\r\nNUDGED"),
        )
        .await
        .expect("the settled resize delivered a second SIGWINCH");

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// A live session with an interactive client holding the write token.
    ///
    /// The client's receiver is held for as long as the session is: dropping it
    /// closes the channel, the actor removes the client on its next send, and
    /// the write token goes with it — after which a `Resize` is refused as
    /// coming from a stranger and the test silently stops testing anything.
    struct Attached {
        handle: SessionHandle,
        _client: mpsc::UnboundedReceiver<ClientEvent>,
        _events: broadcast::Receiver<Event>,
        _on_exit: mpsc::UnboundedReceiver<super::SessionEnded>,
    }

    async fn attached_session() -> Attached {
        let (handle, events, on_exit) = start_session(vec!["/bin/sh".to_string()], "/");
        let (client_tx, client_rx) = mpsc::unbounded_channel();
        let (reply, answer) = oneshot::channel();
        handle.send(SessionMsg::AddClient {
            id: ClientId::new("writer"),
            interactive: true,
            rows: 24,
            cols: 80,
            out: client_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: false,
            scrollback: false,
            grid_diff: false,
            reply,
        });
        let granted = answer.await.expect("attached");
        assert!(granted.writer, "the first interactive client takes the token");
        Attached {
            handle,
            _client: client_rx,
            _events: events,
            _on_exit: on_exit,
        }
    }

    async fn carry(handle: &SessionHandle) -> super::Carried {
        let (reply, answer) = oneshot::channel();
        assert!(handle.send(SessionMsg::Carry { reply }));
        answer.await.expect("the session handed itself over")
    }

    /// The whole point: a live session can name the program in its terminal,
    /// say where that program is standing, and pin the binary behind it —
    /// against a real child, not a fixture.
    #[tokio::test]
    async fn a_session_names_the_program_running_in_its_terminal() {
        let cat = ["/bin/cat", "/usr/bin/cat"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no cat binary on this host");
        let dir = std::fs::canonicalize(std::env::temp_dir()).expect("canonical temp dir");
        let dir = dir.to_string_lossy().into_owned();
        let (handle, mut events_rx, _on_exit) = start_session(vec![cat.to_string()], &dir);

        let info = settled_info(&handle, |info| {
            info.foreground_argv
                .as_ref()
                .and_then(|argv| argv.first())
                .is_some_and(|arg| arg.ends_with("cat"))
        })
        .await;

        assert_eq!(info.foreground_argv.as_deref(), Some(&[cat.to_string()][..]));
        assert_eq!(
            info.foreground_pid,
            Some(info.pid),
            "the session's own child is the foreground group leader"
        );
        assert!(
            !info.foreground_job,
            "the session child itself is not a job running *inside* the session"
        );
        assert_eq!(info.child_cwd.as_deref(), Some(dir.as_str()));
        // Resolved, not spelled: on a busybox host /bin/cat is a symlink and the
        // kernel correctly names /bin/busybox as what is running.
        let expected = std::fs::canonicalize(cat).expect("canonical cat binary");
        assert_eq!(
            info.child_executable.as_deref().map(std::path::Path::new),
            Some(expected.as_path())
        );
        assert!(
            !info.child_executable_replaced,
            "an untouched binary must not read as replaced"
        );

        // Learning who is in there is a roster change, so clients hear about it
        // without polling. It takes two events, not one: the poll publishes the
        // process group as soon as `tcgetpgrp` answers, and the identity behind
        // it lands when the off-actor resolution comes back. Scanning for the
        // second is the point — taking the first would assert against the half
        // that is deliberately cheap.
        let identified = std::iter::from_fn(|| events_rx.try_recv().ok()).any(|event| {
            matches!(event, Event::Roster { info: Some(info), .. } if info.foreground_pid.is_some())
        });
        assert!(
            identified,
            "no roster event ever carried the resolved foreground pid"
        );

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// The roster carries the whole workstream, not just its agent. A client
    /// attached straight to this host has no other source for the project, and
    /// without it every session is a flat row with nothing to group it under.
    #[tokio::test]
    async fn the_roster_carries_the_workstream_project() {
        let cat = ["/bin/cat", "/usr/bin/cat"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no cat binary on this host");
        let (on_exit, _on_exit_rx) = mpsc::unbounded_channel();
        let (events, _events_rx) = broadcast::channel(64);
        let handle = super::spawn(
            SessionId::new("workstream-session"),
            "test".to_string(),
            "/".to_string(),
            cat.to_string(),
            vec![cat.to_string()],
            Vec::new(),
            24,
            80,
            Some(crate::protocol::WorkstreamSpec {
                agent_id: "claude".to_string(),
                project: "/Users/someone/code/termio".to_string(),
                worktree: None,
            }),
            on_exit,
            events,
        )
        .expect("spawning a real session");

        let (tx, rx) = oneshot::channel();
        assert!(handle.send(SessionMsg::Info { reply: tx }));
        let info = rx.await.expect("session info");
        assert_eq!(info.agent_id.as_deref(), Some("claude"));
        assert_eq!(info.project.as_deref(), Some("/Users/someone/code/termio"));

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// A command started *inside* the session takes the tty's foreground away
    /// from the shell. This is the distinction between "a shell is sitting at a
    /// prompt" and "something is running in there".
    #[tokio::test]
    async fn a_command_started_in_the_session_takes_the_foreground() {
        let shell = ["/bin/sh", "/usr/bin/sh"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no sh binary on this host");
        let (handle, _events_rx, _on_exit) =
            start_session(vec![shell.to_string(), "-i".to_string()], "/");

        let idle = settled_info(&handle, |info| info.foreground_pid == Some(info.pid)).await;
        assert!(!idle.foreground_job, "a bare prompt is not a running job");

        handle.send(SessionMsg::Inject {
            data: b"sleep 30\n".to_vec(),
        });

        // Settled on the argv, not on `foreground_job`. The two now land in
        // separate ticks by design — the group id is read on the actor and the
        // identity behind it arrives from a blocking thread — so waiting on the
        // cheap half and asserting the expensive one is a race.
        let busy = settled_info(&handle, |info| {
            info.foreground_argv
                .as_ref()
                .and_then(|argv| argv.first())
                .is_some_and(|arg| arg.ends_with("sleep"))
        })
        .await;
        assert!(busy.foreground_job, "a running command is a job");
        assert_ne!(busy.foreground_pid, Some(busy.pid));

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// The pipeline case, end to end against a real shell and a real tty: the
    /// group leader exits while a later stage keeps running.
    ///
    /// `true | sleep 30` makes a job whose leader is `true`, which finishes
    /// immediately and is left a zombie or reaped outright while `sleep` still
    /// holds the terminal. Reading argv from the process *group* id — what both
    /// hosts did before this — answers nothing here, so the pane would claim
    /// nothing is running while the user watches a command run. The assertion
    /// is deliberately on argv being present and naming `sleep`: that is the
    /// user-visible property, and it is what regressed.
    #[tokio::test]
    async fn a_pipeline_keeps_its_argv_after_the_group_leader_exits() {
        let shell = ["/bin/sh", "/usr/bin/sh"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no sh binary on this host");
        let (handle, _events_rx, _on_exit) =
            start_session(vec![shell.to_string(), "-i".to_string()], "/");

        settled_info(&handle, |info| info.foreground_pid == Some(info.pid)).await;

        handle.send(SessionMsg::Inject {
            data: b"true | sleep 30\n".to_vec(),
        });

        let piped = settled_info(&handle, |info| {
            info.foreground_job && info.foreground_argv.is_some()
        })
        .await;

        let argv = piped
            .foreground_argv
            .as_ref()
            .expect("a live pipeline must report an argv");
        assert!(
            argv.first().is_some_and(|arg| arg.ends_with("sleep")),
            "the surviving stage should name itself; argv was {argv:?}"
        );
        assert_ne!(
            piped.foreground_pid,
            Some(piped.pid),
            "the pipeline is not the session's own shell"
        );

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// The session actor is the last thing that can answer for a session, and
    /// once it has gone the only descriptions left are the ones it sent on its
    /// way out. Both of them — the event clients hear and the record the
    /// manager buries — have to be the *same* record, or a client and a
    /// tombstone can disagree about a session neither can re-read.
    #[tokio::test]
    async fn the_exit_event_carries_the_record_the_tombstone_is_built_from() {
        let cat = ["/bin/cat", "/usr/bin/cat"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no cat binary on this host");
        let (handle, mut events_rx, mut on_exit_rx) = start_session(vec![cat.to_string()], "/");

        // Wait for the first foreground sample, so the record under test is the
        // fully populated one rather than a session caught before its first
        // poll tick.
        let live = settled_info(&handle, |info| info.child_executable.is_some()).await;
        assert!(live.alive, "a running session says so");

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });

        let exited = loop {
            match events_rx.recv().await {
                Ok(Event::SessionExited { session, info, .. }) => break (session, info),
                Ok(_) => continue,
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(error) => panic!("the exit event never arrived: {error:?}"),
            }
        };
        let (session_id, event_info) = exited;
        assert_eq!(session_id, "foreground-session");
        let event_info = event_info.expect("the exit event carries the final record");
        assert!(
            !event_info.alive,
            "a record built on the exit path must not claim the session is alive"
        );
        assert_eq!(event_info.pid, live.pid);
        assert_eq!(event_info.child_executable, live.child_executable);

        let ended = on_exit_rx
            .recv()
            .await
            .expect("the manager is told the session ended");
        assert_eq!(
            ended.reason,
            EndReason::Killed,
            "a client asked for this end"
        );
        assert!(!ended.info.alive);
        assert_eq!(
            serde_json::to_value(&*event_info).unwrap(),
            serde_json::to_value(&ended.info).unwrap(),
            "the event and the tombstone must be one record, not two samples"
        );
    }
}
