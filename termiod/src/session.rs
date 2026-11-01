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
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc, oneshot};

const RING_CAP: usize = 128 * 1024;
/// The `vt_resize` markers kept for `vt_resume`, beyond those the ring prunes.
const STREAM_MARKER_CAP: usize = 4096;
const READ_CHUNK: usize = 64 * 1024;
/// How long a keystroke from a screen not yet reported as rendering keeps its
/// claim on the size. Long enough to cover the Mac's 400 ms visibility
/// debounce; short enough that a scripted send into a hidden pane does not
/// take the size when that pane is shown much later.
const TYPED_CLAIM_WINDOW: std::time::Duration = std::time::Duration::from_secs(2);
pub const KEYFRAME_EVERY_FRAMES: u32 = 256;
mod backlog;

pub(crate) use backlog::{ClientBacklog, Metered};

mod sidecar;

pub(crate) use sidecar::{SidecarCapture, SidecarCommand, SidecarQueue, SidecarResult, Vt};

mod foreground;

use foreground::{Foreground, ForegroundResolution};

pub mod status;

use status::{OscScanner, OscSignal, ProgramFeed, StallStep, StatusEngine, SupportQuery};

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
        /// Whether there is a screen in front of this attachment. Attaching is
        /// usually a viewer arriving to look, which is why the wire's default
        /// is `true` — but a Mac makes a surface for a session nobody is
        /// showing (a phone opening one it never displayed), and that one says
        /// so here rather than a round trip later.
        rendering: bool,
        out: mpsc::UnboundedSender<ClientEvent>,
        backlog: Arc<ClientBacklog>,
        snapshot: bool,
        scrollback: bool,
        grid_diff: bool,
        vt_stream: bool,
        /// Negotiated `vt_answers`: this client answers no query itself while
        /// it writes, so the host's VT does.
        vt_answers: bool,
        /// The answers it attached with, if it sent them then.
        answers: Option<termiod_vt::Answers>,
        /// Negotiated `vt_resume`: told its stream position after each `S`.
        vt_resume: bool,
        /// Where its previous connection's stream stood, to continue from.
        resume: Option<crate::protocol::ResumeSpec>,
        reply: oneshot::Sender<AddClientReply>,
    },
    /// What a `vt_answers` client wants queries answered with while it writes.
    Answers {
        id: ClientId,
        answers: termiod_vt::Answers,
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
    /// Input from a `vt_stream` attachment as an event, which the session
    /// encodes against its own VT's modes. Only a `key`, `paste`, `mouse`,
    /// `wheel` or `focus` event reaches here.
    InputEvent {
        id: ClientId,
        event: crate::protocol::Event,
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
    /// `termio server send` — inject input without attaching. Always applied.
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
    /// on a background tab keeps its viewport but cannot control the size.
    viewport: Option<(u16, u16)>,
    rendering: bool,
    /// When a person typed here while this screen had not yet said it was
    /// rendering. The Mac debounces visibility and sends keys at once, so the
    /// keystroke that should move the size can arrive first; the rendering
    /// declaration that follows within `TYPED_CLAIM_WINDOW` finishes the
    /// transfer instead of only requesting it.
    typed_unseen: Option<std::time::Instant>,
    /// Attach-only history staging. Resize barriers discard any remainder and
    /// deliberately do not restage it; resize/reflow history is a later policy.
    staged_history: VecDeque<Bytes>,
    /// Backlog strikes taken by this attachment. The first buys a forced
    /// resync; the second is the drop. Strikes are never forgiven — the resync
    /// already zeroed the count of what the client owes, so a second overflow
    /// means it could not keep up even from a clean start.
    backlog_strikes: u32,
    /// Whether this attachment's pane has focus, as it last said. The writer's
    /// is what a program asking for focus reports is told.
    focused: Option<bool>,
    /// `Some` when it negotiated `vt_answers`: what the host answers with while
    /// it writes. `None` is a client that answers for itself, so the host's VT
    /// must not answer too, or the program would read every answer twice.
    answers: Option<termiod_vt::Answers>,
    /// Whether it has sent `answers` yet. Until it has, the last answers stand.
    answers_said: bool,
    /// Negotiated `vt_resume`: sent `stream_position` after each `S`.
    vt_resume: bool,
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
    /// Negotiated `snapshot` + `vt_stream`: the client keeps its own VT in step
    /// with this one. `S` is libghostty's native snapshot, which it decodes
    /// into a fresh terminal; after that it gets raw PTY bytes and a
    /// `vt_resize` marker wherever this VT resized — no barrier, no keyframe.
    /// A resize still re-snapshots it while its attach snapshot is pending,
    /// because markers deferred behind a barrier would land after its data.
    Stream(ClientDelivery),
}

impl ClientPlane {
    fn snapshots(&self) -> bool {
        !matches!(self, ClientPlane::Raw)
    }

    fn is_grid(&self) -> bool {
        matches!(self, ClientPlane::Grid(_))
    }

    fn is_stream(&self) -> bool {
        matches!(self, ClientPlane::Stream(_))
    }

    /// Where this attachment stands relative to its snapshot boundary. `None`
    /// for a raw attachment, which has no boundary and is live by construction.
    fn delivery(&self) -> Option<&ClientDelivery> {
        match self {
            ClientPlane::Raw => None,
            ClientPlane::Snapshot(delivery)
            | ClientPlane::Grid(delivery)
            | ClientPlane::Stream(delivery) => Some(delivery),
        }
    }

    fn delivery_mut(&mut self) -> Option<&mut ClientDelivery> {
        match self {
            ClientPlane::Raw => None,
            ClientPlane::Snapshot(delivery)
            | ClientPlane::Grid(delivery)
            | ClientPlane::Stream(delivery) => Some(delivery),
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
    /// The encoders `vt_stream` input goes through, which the sidecar keeps
    /// at the modes of the last byte it parsed (`termiod_vt::InputEncoder`).
    input: Arc<Mutex<termiod_vt::InputEncoder>>,
    /// A paste arriving in pieces: who is sending it, and whether it is
    /// bracketed, which its first piece decided.
    paste_in_progress: Option<(ClientId, bool)>,
    /// Whether the input encoders hold the program's modes. False after a
    /// handoff that could not carry the VT and whose ring does not replay
    /// the whole session: a mode set before the ring's start is gone, and
    /// input encoded without it would not be what the program reads. Such a
    /// session serves `vt_stream` to nobody; its panes encode for themselves.
    input_modes_known: bool,
    clients: HashMap<ClientId, ClientEntry>,
    writer: Option<ClientId>,
    next_seq: u64,
    /// Only this viewer's declared viewport can resize the PTY. Input transfers
    /// ownership; layout and reconnects only request it when nobody is sizing.
    size_owner: Option<ClientId>,
    /// The screens that were attached when the size owner left. Their layout
    /// reports are automatic, so the departed owner's size holds against them
    /// (§12). A screen that attaches afterwards is a person opening the
    /// session, and may take the size.
    survivors: HashSet<ClientId>,
    next_snapshot_request: u64,
    ring: VecDeque<Bytes>,
    ring_bytes: usize,
    /// Names this actor's stream for `vt_resume`: an offset means nothing in
    /// another one, so a reattach after a handoff or a restart snapshots.
    stream_epoch: u64,
    /// Bytes fanned out since this actor began; the ring's end.
    stream_offset: u64,
    /// The `vt_resize` markers inside the ring: the offset each was sent at
    /// and its number, so a resumed client takes the ones it missed where the
    /// live ones went.
    stream_markers: VecDeque<(u64, u64, Event)>,
    /// `vt_resize` markers sent since this actor began.
    stream_marker_count: u64,
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
    support_query: SupportQuery,
    /// Whether the VT answers the program's queries now (`sync_answering`).
    answering: bool,
    /// Off until the previous image's output has been replayed into the VT:
    /// a query in the replay was answered long ago.
    answers_live: bool,
    /// What the VT was last told to answer with.
    applied_answers: Option<termiod_vt::Answers>,
    /// Whether the VT was last told nobody writes (`SetAlone`).
    size_reports: bool,
    /// Replies that arrived while a paste was open, which would otherwise
    /// become part of the pasted text. Sent when it closes.
    held_replies: Vec<u8>,
    /// The transcript address the last hook report carried, kept for the stall
    /// detector's probe 3. Deliberately not on `SessionInfo`: it describes one
    /// report, and a stale path surviving in a roster is a fact nobody
    /// re-checked.
    transcript_path: Option<String>,
    /// Who is in the tty's foreground and where the child is standing.
    /// `info()` reads this cache so a roster request never turns into a burst
    /// of syscalls.
    foreground: Foreground,
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
            // A session created by a client names its project; one started by
            // hand on this box carries none, so the checkout its child is
            // standing in stands in — the repo root, not the raw cwd, because a
            // cwd is wherever the user walked and filing by it would invent
            // projects nobody opened (`TermiodRoster`, and the loose-terminal
            // RFC). Cached by the foreground poll, so a roster request still
            // costs no syscalls.
            project: self
                .workstream
                .as_ref()
                .map(|workstream| workstream.project.clone())
                .filter(|project| !project.is_empty())
                .or_else(|| self.foreground.current().repo_root.clone()),
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
        let writer = self
            .clients
            .iter()
            .filter_map(|(id, entry)| entry.role.attach_seq().map(|seq| (id, seq)))
            .max_by_key(|(_, seq)| *seq)
            .map(|(id, _)| id.clone());
        self.set_writer(writer);
    }

    /// Another writer's focus is not known until its pane says.
    fn set_writer(&mut self, writer: Option<ClientId>) {
        let changed = writer != self.writer;
        if changed {
            self.close_open_paste();
        }
        self.writer = writer;
        // The program hears focus from whoever types; the new writer's pane
        // may have said it has focus while it could not report it.
        if changed {
            self.report_writer_focus();
        }
        self.sync_answering();
    }

    /// The host's VT answers the program's queries while the writer
    /// negotiated `vt_answers`, or while nobody writes; a writer without it
    /// answers for itself. Never for a replay, nor once the VT is stale, when
    /// the writer is told (`vt_stale`) and answers again.
    fn sync_answering(&mut self) {
        // A writer that has not said yet, and nobody writing, keep the last
        // answers: what the previous writer, or the previous image, said.
        //
        // Two limits are accepted. A Mac pane on the embedded surface that
        // claims the token within milliseconds of a query can answer it as
        // well, since its surface parses on its own thread. And a scheme
        // report (mode 2031) follows a change between two `vt_answers`
        // writers, not one from a writer that answers for itself, whose
        // appearance the host never knew.
        let last = || self.applied_answers.clone().unwrap_or_default();
        let answers = match self.writer.as_ref() {
            Some(writer) => self.clients.get(writer).and_then(|entry| {
                entry.answers.as_ref().map(|answers| if entry.answers_said { answers.clone() } else { last() })
            }),
            None => Some(last()),
        };
        let answering = self.answers_live && self.vt.is_live() && answers.is_some();
        if let Some(answers) = answers.filter(|_| answering) {
            if self.applied_answers.as_ref() != Some(&answers) {
                self.send_sidecar(SidecarCommand::SetAnswers(answers.clone()));
                self.applied_answers = Some(answers);
            }
        }
        if answering != self.answering {
            self.answering = answering;
            self.send_sidecar(SidecarCommand::SetAnswering(answering));
        }
        let size_reports = self.writer.is_none();
        if size_reports != self.size_reports {
            self.size_reports = size_reports;
            self.send_sidecar(SidecarCommand::SetAlone(size_reports));
        }
    }

    /// Replies the VT wrote, onto the PTY's input path. Not gated again here:
    /// `SetAnswering` travels the sidecar's FIFO with the bytes, so a reply
    /// exists only for a query parsed while the host was the one to answer.
    /// Held while a paste is open, which it would otherwise join.
    fn write_replies(&mut self, mut replies: Vec<u8>) {
        // `SupportQuery` answered this one before the VT parsed it.
        SupportQuery::strip_other_reply(&mut replies);
        if replies.is_empty() {
            return;
        }
        if self.paste_in_progress.is_some() {
            self.held_replies.extend_from_slice(&replies);
        } else {
            let _ = self.input_tx.send(replies);
        }
    }

    fn flush_held_replies(&mut self) {
        if self.paste_in_progress.is_none() && !self.held_replies.is_empty() {
            let _ = self.input_tx.send(std::mem::take(&mut self.held_replies));
        }
    }

    /// Ends a paste whose pieces stopped coming — its sender lost the token,
    /// or sent something else — so the program does not stay in a paste.
    fn close_open_paste(&mut self) {
        if let Some((_, true)) = self.paste_in_progress.take() {
            let _ = self.input_tx.send(PASTE_END.to_vec());
        }
        self.flush_held_replies();
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
        self.set_writer(Some(id.clone()));
        true
    }

    /// A `vt_stream` client's input event, encoded with the modes of the last
    /// byte the sidecar parsed. Everything but focus is typing, and follows
    /// `Input`'s rules: only the writer's lands, and it counts as use.
    fn input_event(&mut self, id: &ClientId, event: crate::protocol::Event) {
        use crate::protocol::{Event, InputAction};
        use termiod_vt::{KeyAction, MouseAction, Pointer};
        // A session that lost its modes in a handoff takes no encoded input:
        // its stream attachments are refused once their snapshot settles, and
        // nothing may reach the program encoded with guesses meanwhile.
        if !self.input_modes_known {
            return;
        }
        if let Event::Focus { focused } = event {
            // Kept for every attachment, so a pane that takes the token back
            // has its focus known; reported only for the writer, since a pane
            // that merely gained focus is not claiming the session.
            if let Some(entry) = self.clients.get_mut(id) {
                entry.focused = Some(focused);
            }
            if self.writer.as_ref() == Some(id) {
                self.report_writer_focus();
            }
            return;
        }
        if self.writer.as_ref() != Some(id) {
            // A release, plain motion or a composing key does not claim the
            // token, so from a non-writer it is dropped without a complaint.
            // The app's rule (`Termiod.InputEvent.claimsWriter`), so neither
            // side calls a modifier on its way to a shortcut typing.
            let typing = match &event {
                Event::Key { action, composing, key, .. } => {
                    *action != InputAction::Release && !*composing && !termiod_vt::is_modifier_key(key)
                }
                Event::Mouse { action, .. } => *action == InputAction::Press,
                _ => true,
            };
            if typing {
                self.reject_not_writer(id);
            }
            return;
        }
        let continues_paste = matches!(event, Event::Paste { .. })
            && self.paste_in_progress.as_ref().is_some_and(|(sender, _)| sender == id);
        if !continues_paste {
            self.close_open_paste();
        }
        let Ok(mut encoder) = self.input.lock() else { return };
        let bytes = match event {
            Event::Key { action, key, mods, consumed_mods, text, unshifted, composing } => {
                let action = match action {
                    InputAction::Release => KeyAction::Release,
                    InputAction::Repeat => KeyAction::Repeat,
                    InputAction::Press | InputAction::Motion => KeyAction::Press,
                };
                encoder.key(&termiod_vt::KeyInput {
                    action,
                    key,
                    mods,
                    consumed_mods,
                    text,
                    unshifted,
                    composing,
                })
            }
            Event::Paste { text, more } => {
                let open = self.paste_in_progress.take().filter(|(sender, _)| sender == id);
                let bracketed = open.as_ref().map_or(encoder.modes().bracketed_paste, |(_, bracketed)| *bracketed);
                if more {
                    self.paste_in_progress = Some((id.clone(), bracketed));
                }
                encoder.paste_piece(&text, bracketed, open.is_none(), !more)
            }
            Event::Mouse { action, button, mods, x, y, cell_width, cell_height, buttons_held } => {
                let action = match action {
                    InputAction::Press => MouseAction::Press,
                    InputAction::Release => MouseAction::Release,
                    InputAction::Motion | InputAction::Repeat => MouseAction::Motion,
                };
                encoder.mouse(&termiod_vt::MouseInput {
                    action,
                    button,
                    mods,
                    at: Pointer { x, y, cell_width, cell_height },
                    buttons_held,
                })
            }
            Event::Wheel { rows, columns, mods, x, y, cell_width, cell_height } => {
                encoder.wheel(&termiod_vt::WheelInput {
                    rows,
                    columns,
                    mods,
                    at: Pointer { x, y, cell_width, cell_height },
                })
            }
            _ => return,
        };
        drop(encoder);
        if bytes.is_empty() {
            // The last piece of a paste can encode to nothing; replies held
            // while it was open go now.
            self.flush_held_replies();
            return;
        }
        self.status_engine.note_user_input(std::time::Instant::now());
        self.take_size_for_input(id);
        self.apply_size_policy();
        let _ = self.input_tx.send(bytes);
        self.flush_held_replies();
    }

    /// Tells the program whether the writer's pane has focus, if it asked for
    /// focus reports and the writer has said.
    fn report_writer_focus(&mut self) {
        // A report sent between a paste's pieces would become part of it.
        self.close_open_paste();
        let Some(focused) = self
            .writer
            .as_ref()
            .and_then(|writer| self.clients.get(writer))
            .and_then(|entry| entry.focused)
        else {
            return;
        };
        let bytes = match self.input.lock() {
            Ok(encoder) => encoder.focus(focused),
            Err(_) => return,
        };
        if !bytes.is_empty() {
            let _ = self.input_tx.send(bytes);
        }
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
    fn into_carried(self, native: Option<Vec<u8>>) -> anyhow::Result<Carried> {
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
                input_modes_unknown: !self.input_modes_known,
                paste_open: matches!(self.paste_in_progress, Some((_, true))),
                pending_len: 0,
                pending_input: Vec::new(),
                native_len: native.as_ref().map_or(0, |bytes| bytes.len() as u64),
                answers: self.applied_answers.clone().map(|answers| crate::handoff::CarriedAnswers {
                    xtversion: answers.xtversion,
                    foreground: answers.foreground,
                    background: answers.background,
                    cursor: answers.cursor,
                    palette: answers.palette,
                    dark: answers.dark,
                }),
                native: native.map(Bytes::from).unwrap_or_default(),
            },
            master,
            ring,
        })
    }

    fn push_ring(&mut self, data: Bytes) {
        self.ring_bytes += data.len();
        self.stream_offset += data.len() as u64;
        self.ring.push_back(data);
        while self.ring_bytes > RING_CAP {
            if let Some(evicted) = self.ring.pop_front() {
                self.ring_bytes -= evicted.len();
                self.ring_reconstructs_screen = false;
            }
        }
        let start = self.ring_start();
        while self.stream_markers.front().is_some_and(|(offset, _, _)| *offset < start) {
            self.stream_markers.pop_front();
        }
    }

    /// The stream offset of the ring's first byte.
    fn ring_start(&self) -> u64 {
        self.stream_offset - self.ring_bytes as u64
    }

    /// What a `vt_resume` client that stood at `resume` missed, in stream
    /// order: the ring's bytes from its offset, each marker before the byte it
    /// preceded live. `None` when that is not this stream, or the ring no
    /// longer reaches back to it.
    fn resume_replay(&self, resume: crate::protocol::ResumeSpec) -> Option<Vec<Replayed>> {
        let start = self.ring_start();
        if resume.epoch != self.stream_epoch
            || resume.offset < start
            || resume.offset > self.stream_offset
            || resume.markers > self.stream_marker_count
        {
            return None;
        }
        let missed: Vec<&(u64, u64, Event)> =
            self.stream_markers.iter().filter(|(_, number, _)| *number > resume.markers).collect();
        // Every marker it missed must still be here and lie at or past its
        // offset, and every one it applied at or before it; anything else is
        // a position this stream never had.
        let applied_past = self
            .stream_markers
            .iter()
            .any(|(offset, number, _)| *number <= resume.markers && *offset > resume.offset);
        if applied_past
            || missed.len() as u64 != self.stream_marker_count - resume.markers
            || missed.iter().any(|(offset, _, _)| *offset < resume.offset)
        {
            return None;
        }
        let mut replay = Vec::new();
        let mut markers = missed.into_iter().peekable();
        let mut position = start;
        for chunk in &self.ring {
            let end = position + chunk.len() as u64;
            let mut from = position.max(resume.offset);
            while from < end {
                // A marker at `from` went out before the byte at `from`.
                while let Some((_, _, marker)) = markers.next_if(|(offset, _, _)| *offset <= from) {
                    replay.push(Replayed::Marker(marker.clone()));
                }
                let until = markers.peek().map_or(end, |(offset, _, _)| (*offset).min(end));
                replay.push(Replayed::Bytes(chunk.slice((from - position) as usize..(until - position) as usize)));
                from = until;
            }
            position = end;
        }
        for (_, _, marker) in markers {
            replay.push(Replayed::Marker(marker.clone()));
        }
        Some(replay)
    }

    /// Answers `OSC 7501 ; ?` in live output before it goes out; see
    /// `SupportQuery`. Only while the VT is live: it is what keeps the
    /// records, so a stale VT would advertise reports nobody reads.
    fn answer_support_query(&mut self, chunk: &[u8]) {
        let reply = self.support_query.scan(chunk);
        if !reply.is_empty() && self.vt.is_live() {
            let _ = self.input_tx.send(reply);
        }
    }

    /// Resize this session's VT, and put the same operation in every live
    /// `vt_stream` client's stream at this exact byte position, so their VTs
    /// make it too. Sent whether or not the sidecar is live: the clients' VTs
    /// do not depend on it.
    ///
    /// A pending client gets no marker — deferred, it would land after the
    /// data buffered behind its barrier — so its snapshot is re-requested
    /// here, behind this resize. Here rather than in the barrier, because the
    /// rollback and the trimmed-by-the-kernel paths resize the VT without
    /// opening one.
    fn resize_vt(&mut self, rows: u16, cols: u16, reflow: bool) {
        self.send_sidecar(SidecarCommand::Resize { rows, cols, reflow });
        let pending: Vec<ClientId> = self
            .clients
            .iter()
            .filter(|(_, entry)| entry.plane.is_stream() && entry.plane.is_pending())
            .map(|(id, _)| id.clone())
            .collect();
        for client_id in pending {
            let request_id = self.allocate_snapshot_request();
            let Some(entry) = self.clients.get_mut(&client_id) else {
                continue;
            };
            let superseded = entry.plane.begin_pending(request_id);
            release_buffered(&entry.backlog, superseded);
            self.request_snapshot(client_id, request_id, false);
        }
        let marker = Event::VtResize {
            session: self.id.to_string(),
            rows,
            cols,
            reflow,
        };
        self.stream_marker_count += 1;
        self.stream_markers.push_back((self.stream_offset, self.stream_marker_count, marker.clone()));
        // Resizes over a child that prints nothing never move the ring; past
        // this many, a position from before them snapshots instead.
        if self.stream_markers.len() > STREAM_MARKER_CAP {
            self.stream_markers.pop_front();
        }
        let dead = self
            .clients
            .iter()
            .filter(|(_, entry)| entry.plane.is_stream() && !entry.plane.is_pending())
            .filter_map(|(id, entry)| {
                entry
                    .out
                    .send(ClientEvent::Event(marker.clone()))
                    .is_err()
                    .then(|| id.clone())
            })
            .collect();
        self.remove_dead(dead);
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
        self.answering = false;
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
        let native = self
            .clients
            .get(&client_id)
            .is_some_and(|entry| entry.plane.is_stream());
        if !self.send_sidecar(SidecarCommand::Snapshot {
            client_id: client_id.clone(),
            request_id,
            // The native snapshot already carries the scrollback.
            scrollback: scrollback && !native,
            native,
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

    /// How long after a resize the child is asked to repaint once more.
    ///
    /// Long enough that a drag's own bursts have stopped pushing it out — every
    /// resize re-arms it, so a drag costs one nudge, at the end — and that the
    /// child's answer to the *last* resize has drained. Anything the transition
    /// mis-parsed is still on screen until something overwrites it, and only
    /// the child can.
    const RESIZE_SETTLE_NUDGE: std::time::Duration = std::time::Duration::from_millis(300);

    /// A resize's barrier: opened and captured in the same step, so the
    /// keyframe describes the screen *before* the child's answer and every byte
    /// the child writes from here lands on top of it exactly once.
    ///
    /// The capture used to wait out a settle window, on the reasoning that a
    /// keyframe carrying the child's own redraw spares every attachment a paint
    /// of a screen about to be replaced. It cost correctness. One PTY chunk
    /// takes two paths — `write_sidecar` into the authoritative VT,
    /// `fan_out` toward the clients — and the barrier buffers the second while
    /// the first runs. A capture taken after the child has begun answering
    /// therefore absorbs bytes that are still sitting in every client's buffer,
    /// and draining that buffer onto the snapshot applies them a second time.
    ///
    /// Nothing about a repaint is idempotent. A redraw that happens to be
    /// split — `ESC[A ESC[3G` in the capture, the text that follows it after —
    /// replays its cursor motion on top of a screen that already moved,
    /// so the text lands a row above where the child put it: the input box's
    /// rule with the typed characters punched through it and the prompt
    /// chevron stranded on the row below (#698). A slow child is what splits
    /// the redraw across the boundary, which is why the reports come from
    /// agents carrying a large context. The grids agree afterwards, so no
    /// resync is ever armed and the mangled screen stays up until the child
    /// repaints on its own.
    ///
    /// Capturing at the opening makes the two orderings one: the snapshot
    /// precedes every buffered byte, so the drain carries it forward instead of
    /// doubling it. The child's redraw still reaches the client — as the data
    /// it is, in order, behind the keyframe — and nothing has to be retired, so
    /// output that scrolled past the top during the barrier keeps its place in
    /// the scrollback.
    fn begin_resize_snapshot_barrier(&mut self) {
        // `vt_stream` clients are not behind this barrier: `resize_vt` already
        // gave each live one its marker and re-snapshotted each pending one.
        let snapshot_clients: Vec<ClientId> = self
            .clients
            .iter()
            .filter(|(_, entry)| entry.plane.snapshots() && !entry.plane.is_stream())
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

        // Asked for here rather than left to a timer: a capture the sidecar
        // takes before the next `write_sidecar` is one no buffered byte is
        // inside yet.
        for (client_id, request_id) in requests {
            self.request_snapshot(client_id, request_id, false);
        }
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

    /// Removes an attachment, and records who saw it go if it held the size.
    fn drop_client(&mut self, id: &ClientId) -> Option<ClientEntry> {
        let entry = self.clients.remove(id)?;
        self.note_departure(id);
        Some(entry)
    }

    /// Called once, right after `id` really left. A departed size owner's
    /// size holds against the screens still here (`survivors`).
    fn note_departure(&mut self, id: &ClientId) {
        if self.size_owner.as_ref() == Some(id) {
            self.survivors = self.clients.keys().cloned().collect();
        } else {
            self.survivors.remove(id);
        }
    }

    fn remove_dead(&mut self, dead: Vec<ClientId>) {
        if dead.is_empty() {
            return;
        }
        let old_writer = self.writer.clone();
        for id in dead {
            self.drop_client(&id);
        }
        self.sync_grid_diff_interest();
        self.recompute_writer();
        if self.writer != old_writer {
            self.emit_writer_changed(self.writer.clone());
        }
        // Deliberately no size recomputation: a death is not a person acting
        // (§12 of the size RFC). If the dead viewer owned the size, the session
        // keeps the shape that person gave it until somebody else does
        // something.
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
        self.support_query.forget_held();
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

    fn policy_size(&self) -> Option<(u16, u16)> {
        self.size_owner
            .as_ref()
            .and_then(|id| self.clients.get(id))
            .filter(|entry| entry.role.is_interactive() && entry.rendering)
            .and_then(|entry| entry.viewport)
    }

    /// A viewport report records a preference, not an interaction. In
    /// particular, rotation and reconnecting a phone must not take the size
    /// from a Mac somebody is using.
    ///
    /// A departed owner still holds the size against the screens that saw it
    /// leave (`survivors`): the report a survivor sends on being handed the
    /// token is automatic, not a person, so it takes the size only by typing.
    fn request_size(&mut self, id: &ClientId) {
        if self.policy_size().is_none() && !self.survivors.contains(id) {
            self.take_size(id);
        }
        if self.size_owner.as_ref() == Some(id) {
            self.apply_size_policy();
        }
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
        let sample = self.foreground.current();
        // A job holding the terminal is not the shell whose redisplay the
        // truncating resize protects, whatever its name says. The name check
        // alone called an agent's tool subshell a shell, so a resize landing
        // mid-command truncated a screen the agent's TUI had painted — tails
        // lost from rows the resize should have rewrapped (the phone's
        // stale-tail blend). Only the session's own child at the prompt does
        // old-width cursor arithmetic; a nested interactive shell loses this
        // protection, which is the cheaper edge by far.
        if sample.job {
            return false;
        }
        let Some(argv0) = sample.argv.as_ref().and_then(|argv| argv.first()) else {
            return true;
        };
        let name = argv0
            .rsplit('/')
            .next()
            .unwrap_or(argv0)
            .trim_start_matches('-');
        SHELLS.contains(&name)
    }

    /// A keystroke takes the size. One from a screen that has not said it is
    /// rendering yet is remembered, so its rendering declaration completes the
    /// transfer (`typed_unseen`).
    fn take_size_for_input(&mut self, id: &ClientId) {
        let Some(entry) = self.clients.get(id) else {
            return;
        };
        if !entry.role.is_interactive() {
            return;
        }
        let eligible = entry.rendering && entry.viewport.is_some();
        // The newest keystroke wins outright, so no older claim from any
        // screen may finish after it. At most one claim is ever pending.
        for other in self.clients.values_mut() {
            other.typed_unseen = None;
        }
        if eligible {
            self.take_size(id);
        } else if let Some(entry) = self.clients.get_mut(id) {
            entry.typed_unseen = Some(std::time::Instant::now());
        }
    }

    /// Human input transfers sizing separately from the write token. Device
    /// reports and focus notifications never pass through here.
    fn take_size(&mut self, id: &ClientId) {
        if self.clients.get(id).is_some_and(|entry| {
            entry.role.is_interactive() && entry.rendering && entry.viewport.is_some()
        }) {
            self.size_owner = Some(id.clone());
            self.survivors.clear();
        }
    }

    /// Moves the PTY to whatever the policy now says, if that is somewhere else.
    ///
    /// This is the only thing in the daemon that resizes a session, and (§12)
    /// it runs only when a person acts: an arrival with a screen, a keystroke,
    /// the size owner declaring its viewport. Never on a departure, a death, or
    /// a screen parking — leaving is not using, and recomputing on the way out
    /// handed the size to whichever unattended window happened to remain,
    /// which made every phone lock/unlock cycle cost two full TUI reflows.
    /// The write token is not consulted — the token is about who may type, and
    /// a device can be the one being looked at without holding it
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
        // Probe the PTY with the size it already has before anything is
        // enqueued. Re-asserting an unchanged size raises no SIGWINCH on any
        // kernel this runs on, so the probe is silent — it only proves the
        // descriptor can take an ioctl at all. That proof is what lets the VT
        // resize below go out *first* while keeping the failure contract:
        // a session whose PTY is gone stays exactly where it was and tells
        // nobody.
        if let Err(error) = self.pty.resize(self.rows, self.cols) {
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
        let reflow = !self.foreground_is_a_shell();
        // The VT's resize is enqueued *before* the ioctl that raises
        // SIGWINCH. The shell answers that signal by redrawing its prompt,
        // and those bytes travel the same FIFO as this command — enqueueing
        // the resize first is what guarantees `resize_for_shell` clears the
        // *old* prompt and never the one the shell just repainted. With the
        // order reversed, a redraw that won the race was blanked and nothing
        // repainted it: the session sat at a bare cursor (the "prompt
        // disappeared" report), because zsh may skip its redisplay for a
        // nudge that changes nothing.
        self.resize_vt(rows, cols, reflow);
        let applied = match self.pty.resize(rows, cols) {
            Ok(applied) => applied,
            Err(error) => {
                // The probe passed and this did not: the PTY died in between.
                // Put the VT back on the grid the kernel still holds — a plain
                // reflow, because no SIGWINCH is coming to repaint anything a
                // clear would blank — and leave the session's state alone.
                eprintln!(
                    "termiod: resize of session {} to {rows}x{cols} failed: {error}",
                    self.id
                );
                self.resize_vt(self.rows, self.cols, true);
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
            // The VT already took the requested grid; align it with the one
            // the kernel actually kept.
            self.resize_vt(applied.0, applied.1, true);
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
    /// Shells used to be excluded — a shell repainted its prompt on the
    /// resize's own SIGWINCH, and while the resize merely truncated, a second
    /// poke bought nothing. The mark-gated reflow changed that arithmetic:
    /// the shell's redraw and the sidecar's Resize race through the same
    /// FIFO, and when the redraw's bytes land first, `resize_for_shell`
    /// blanks the prompt the shell just painted — with nothing left to paint
    /// it again, the session sits at a bare cursor. The nudge is that
    /// something: zsh's WINCH handler redisplays the prompt even when the
    /// size did not change, and when the redraw won the race after all, the
    /// extra redisplay repaints the same cells.
    fn fire_settle_nudge(&mut self) {
        self.settle_nudge_at = None;
        self.pty.nudge_repaint();
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
    /// An attachment whose snapshot fails is dropped, and that is a departure.
    fn finish_snapshot(
        &mut self,
        client_id: &ClientId,
        request_id: u64,
        result: Result<SidecarCapture, String>,
    ) -> bool {
        let present = self.clients.contains_key(client_id);
        let finished = self.settle_snapshot(client_id, request_id, result);
        if present && !self.clients.contains_key(client_id) {
            self.note_departure(client_id);
        }
        finished
    }

    fn settle_snapshot(
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

        if entry.plane.is_stream() {
            let unusable = match &result {
                _ if !self.input_modes_known => {
                    Some("the program's input modes did not survive a handoff".to_string())
                }
                Err(error) => Some(error.clone()),
                Ok(capture) => match &capture.native {
                    None => Some("the native snapshot could not be encoded".to_string()),
                    Some(native) if native.len() > MAX_NATIVE_SNAPSHOT_BYTES => Some(format!(
                        "the native snapshot is {} bytes, more than one frame carries",
                        native.len()
                    )),
                    Some(_) => None,
                },
            };
            if let Some(reason) = unusable {
                // A repaint or a replay would start this client's VT somewhere
                // the host's is not, and every later marker would keep it there.
                eprintln!(
                    "termiod: vt_stream unavailable for client {client_id} in session {}: {reason}",
                    self.id
                );
                release_buffered(&entry.backlog, data);
                let _ = entry.out.send(ClientEvent::Control(Control::Error {
                    re: None,
                    code: ErrorCode::VtStreamUnavailable,
                    message: format!("vt_stream unavailable: {reason}"),
                    retryable: false,
                }));
                self.remove_finished_client(client_id);
                return false;
            }
        }
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
        let native = if entry.plane.is_stream() { capture.native } else { None };
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
        let snapshot = self.protocol_snapshot(engine, snapshot_vt, native);

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

        // The boundary is where this client's buffered bytes begin: they were
        // fanned out after the sidecar took the snapshot, in the same order.
        if entry.plane.is_stream() && entry.vt_resume {
            let buffered: u64 = data.iter().map(|payload| payload.bytes.len() as u64).sum();
            let position = Event::StreamPosition {
                session: self.id.to_string(),
                epoch: self.stream_epoch,
                offset: self.stream_offset - buffered,
                markers: self.stream_marker_count,
            };
            if entry.out.send(ClientEvent::Event(position)).is_err() {
                release_buffered(&entry.backlog, data);
                self.remove_finished_client(client_id);
                return false;
            }
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

    fn protocol_snapshot(
        &self,
        engine: termiod_vt::Snapshot,
        vt: Option<Vec<u8>>,
        native: Option<Vec<u8>>,
    ) -> Snapshot {
        Snapshot {
            native,
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
        let snapshot = self.protocol_snapshot(engine, None, None);
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
            if let Some(mut entry) = self.drop_client(&id) {
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

/// The largest native snapshot one `S` frame carries, with room for the header
/// and the title. Kitty images on both screens can exceed it.
const MAX_NATIVE_SNAPSHOT_BYTES: usize =
    crate::protocol::MAX_FRAME_SIZE - 16 - u16::MAX as usize;

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
/// `termio agent report`, which needs two things the child would otherwise have
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
    // A directory holding just the paired `termio` leads the session's PATH,
    // so every terminal opened through termio finds the client the deploy loop
    // installed beside this daemon — with no dotfile written, the same
    // principle as never overriding `~/.ssh/config` (docker-lessons RFC §1.2).
    // A bare SSH login outside termio keeps whatever the box's own profile
    // does.
    if let Some(directory) = client_path_directory() {
        lead_path_with(&directory, &mut env);
    }
    env
}

fn lead_path_with(directory: &str, env: &mut Vec<(String, String)>) {
    let inherited = env
        .iter()
        .rev()
        .find(|(key, _)| key == "PATH")
        .map(|(_, value)| value.clone())
        .or_else(|| std::env::var("PATH").ok());
    if let Some(path) = path_led_by(directory, inherited.as_deref()) {
        env.push(("PATH".to_string(), path));
    }
}

/// A daemon-owned directory holding one symlink — `termio`, pointing at the
/// client installed beside this daemon — for a session's PATH to lead with.
///
/// The client's own directory is deliberately *not* what leads the PATH. It
/// works only where the daemon is installed somewhere private; where it is
/// shared (`TERMIOD_REMOTE_BIN=/usr/local/bin/termiod`, or a `/usr/bin`
/// install) leading with it would put that whole directory ahead of the user's
/// own PATH, so every session would resolve `node`, `python` and `git` from
/// there while a plain ssh login resolved them normally. A directory with
/// exactly one thing in it can be led with safely, and nothing else on the box
/// changes meaning.
///
/// `None` on a Mac, always. The Mac's client reaches sessions through the
/// app's own support copy, never through this prepend, and the directory the
/// daemon runs from there is actively wrong to advertise: a checkout-run
/// daemon's `target/release` holds cargo's unsuffixed release-channel
/// `termio` (the cross-channel skew the `termio-dev` naming exists to
/// prevent), and after a Sparkle update the still-serving old daemon's
/// bundle path names a client from a build it is not.
///
/// `None` too when there is no client to point at — a box the deploy loop has
/// not reached yet — because a prepend that guarantees nothing is only a way
/// to change a PATH for no reason.
pub(crate) fn client_path_directory() -> Option<String> {
    if cfg!(target_os = "macos") {
        return None;
    }
    let client = crate::lifecycle::paired_client()?;
    let directory = crate::paths::durable_state_dir().ok()?.join("bin");
    if let Err(error) = std::fs::create_dir_all(&directory) {
        eprintln!("termiod: could not create {}: {error}", directory.display());
        return None;
    }
    match place_client_link(&directory, &client) {
        Ok(()) => Some(directory.display().to_string()),
        Err(error) => {
            eprintln!(
                "termiod: could not point {}/termio at {}: {error}",
                directory.display(),
                client.display()
            );
            None
        }
    }
}

/// Distinguishes the staging names two spawns in this process may need at the
/// same instant — the pid alone does not, and both would then write one path.
static LINK_ATTEMPT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Point `<directory>/termio` at `client`, replacing whatever is there.
///
/// Re-pointed rather than trusted: a client-only redeploy can move the client
/// under a daemon that keeps running, and a link left pointing at the old path
/// would hand sessions a build the box no longer has.
///
/// Replaced by rename, never by remove-then-create. Two sessions spawning at
/// once both take this path on the first spawn after a daemon starts, and
/// unlinking first gave them a window where the link was missing — a child
/// exec'ing at that instant finding nothing, and the loser of the race failing
/// `EEXIST` and handing its session no `PATH` entry at all. `rename` is atomic:
/// every reader sees the old link or the new one, and concurrent placements
/// all succeed.
fn place_client_link(
    directory: &std::path::Path,
    client: &std::path::Path,
) -> std::io::Result<()> {
    let link = directory.join("termio");
    if std::fs::read_link(&link).ok().as_deref() == Some(client) {
        return Ok(());
    }
    let staging = directory.join(format!(
        "termio.{}.{}",
        std::process::id(),
        LINK_ATTEMPT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&staging);
    std::os::unix::fs::symlink(client, &staging)?;
    if let Err(error) = std::fs::rename(&staging, &link) {
        let _ = std::fs::remove_file(&staging);
        return Err(error);
    }
    Ok(())
}

/// `directory` put at the front of `path`, or `None` when there is nothing to
/// do. Prepended even when the directory already appears further back: an
/// older `termio` earlier on the PATH would otherwise shadow the one shipped
/// beside this daemon, which is exactly the skew the same-pass deploy exists
/// to rule out. No PATH at all is left alone — a PATH invented from one
/// directory would cost the child every standard tool.
fn path_led_by(directory: &str, path: Option<&str>) -> Option<String> {
    let path = path?;
    if path.is_empty() {
        return Some(directory.to_string());
    }
    if path.split(':').next() == Some(directory) {
        return None;
    }
    Some(format!("{directory}:{path}"))
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
            answers: None,
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
        input_modes_unknown: carried.input_modes_unknown,
        paste_open: carried.paste_open,
        pending_input: carried.pending_input,
        native: (!carried.native.is_empty()).then(|| carried.native.to_vec()),
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
            answers: carried.answers.map(|answers| termiod_vt::Answers {
                xtversion: answers.xtversion,
                foreground: answers.foreground,
                background: answers.background,
                cursor: answers.cursor,
                palette: answers.palette,
                dark: answers.dark,
            }),
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
const PASTE_END: &[u8] = b"\x1b[201~";

/// Gives an adopted session's encoders the program's modes, from the carried
/// snapshot or by replaying the ring, and returns the snapshot if it decoded.
///
/// Done on the actor before it takes input: the sidecar parses on its own
/// thread after the session is already accepting keystrokes, so it cannot be
/// what seeds them. The ring is bounded by `RING_CAP`, replayed once here.
fn seed_input(
    encoder: &mut termiod_vt::InputEncoder,
    native: Option<Vec<u8>>,
    chunks: &[Bytes],
    rows: u16,
    cols: u16,
) -> Option<Vec<u8>> {
    if let Some(bytes) = native {
        match termiod_vt::VtTerminal::from_native_snapshot(&bytes) {
            Ok(terminal) => {
                encoder.refresh(&terminal);
                return Some(bytes);
            }
            Err(error) => {
                eprintln!("termiod: carried VT snapshot undecodable, replaying the ring: {error}");
            }
        }
    }
    // A new session is a blank terminal of its size; an adopted one without a
    // usable snapshot is that terminal after the ring.
    if let Ok(mut terminal) = termiod_vt::VtTerminal::new(rows, cols) {
        for chunk in chunks {
            terminal.vt_write(chunk);
        }
        encoder.refresh(&terminal);
    }
    None
}

/// How long a handoff waits for the VT to finish what it was fed and
/// snapshot it. Past it the session still crosses, on ring replay. Well inside
/// `handoff::CARRY_TIMEOUT`, which this actor must answer within or the session
/// is left behind.
const CARRY_SNAPSHOT_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(500);

struct Replay {
    chunks: Vec<Bytes>,
    /// The previous image no longer knew the program's input modes.
    input_modes_unknown: bool,
    /// The previous image left the program inside a paste.
    paste_open: bool,
    /// Input the previous image accepted and had not written.
    pending_input: Vec<Bytes>,
    /// The previous image's VT, as a native snapshot. When present the new VT
    /// starts from it and the chunks only refill the ring.
    native: Option<Vec<u8>>,
    /// See `Session::ring_reconstructs_screen`. False means the replay leaves
    /// rows this actor's VT cannot know; the adopting actor nudges the program
    /// to repaint them rather than taking the VT down.
    faithful: bool,
}

impl Replay {
    fn none() -> Replay {
        Replay {
            chunks: Vec::new(),
            input_modes_unknown: false,
            paste_open: false,
            pending_input: Vec::new(),
            native: None,
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
    /// What the previous image answered queries with. `None` for a fresh spawn.
    answers: Option<termiod_vt::Answers>,
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
    // It knows what reached the program, so it is the one that ends a paste
    // left open when the session's sender goes away: a handoff drops it after
    // the last byte this image will write.
    // Input accepted but not yet on the PTY, which the writer hands back
    // when it is stopped: a handoff carries it to the next image instead of
    // losing it in the exec, and a handoff that fails puts it back.
    let unwritten = Arc::new(Mutex::new(Vec::<Bytes>::new()));
    let writer_unwritten = unwritten.clone();
    let (stop_writer, mut writer_stopped) = tokio::sync::oneshot::channel::<()>();
    let input_writer = tokio::spawn(async move {
        let mut current: Vec<u8> = Vec::new();
        let mut offset = 0;
        loop {
            if offset == current.len() {
                // Dropped, not cleared: a carried backlog can be large, and an
                // idle session should not keep its allocation.
                current = Vec::new();
                offset = 0;
                tokio::select! {
                    next = input_rx.recv() => match next {
                        Some(bytes) => current = bytes,
                        None => return,
                    },
                    _ = &mut writer_stopped => break,
                }
            }
            // `write_some` writes or does not, with nothing awaited after a
            // write, so stopping here never loses a byte it took.
            tokio::select! {
                written = writer_pty.write_some(&current[offset..]) => match written {
                    Ok(count) => offset += count,
                    Err(_) => return,
                },
                _ = &mut writer_stopped => break,
            }
        }
        // Moved, not joined: handing back a large backlog costs nothing
        // inside the carry deadline.
        let mut rest = Vec::new();
        if offset < current.len() {
            rest.push(Bytes::from(current).slice(offset..));
        }
        while let Ok(bytes) = input_rx.try_recv() {
            rest.push(Bytes::from(bytes));
        }
        if let Ok(mut unwritten) = writer_unwritten.lock() {
            *unwritten = rest;
        }
    });

    let input = Arc::new(Mutex::new(
        termiod_vt::InputEncoder::new().map_err(|error| anyhow::anyhow!("input encoders: {error}"))?,
    ));
    let mut replay = replay;
    // Before anything can attach, the encoders take the program's modes, and
    // a snapshot that does not decode leaves the ring to replay instead.
    let native = match input.lock() {
        Ok(mut encoder) => seed_input(&mut encoder, replay.native.take(), &replay.chunks, facts.rows, facts.cols),
        Err(_) => None,
    };
    let starts_from_snapshot = native.is_some();
    let input_modes_unknown = replay.input_modes_unknown;
    let paste_was_open = replay.paste_open;
    let pending_input = std::mem::take(&mut replay.pending_input);

    let sidecar = spawn_sidecar_sharing(facts.rows, facts.cols, input.clone(), native)?;

    let (tx, rx) = mpsc::unbounded_channel();
    let termination_reason = Arc::new(Mutex::new(None));
    let workstream_agent = facts
        .workstream
        .as_ref()
        .map(|workstream| workstream.agent_id.clone());
    let adopted_clocks = facts.status_clocks.clone();
    let facts_answers = facts.answers.clone();
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
        input,
        paste_in_progress: None,
        input_modes_known: true,
        clients: HashMap::new(),
        writer: None,
        next_seq: 0,
        size_owner: None,
        survivors: HashSet::new(),
        next_snapshot_request: 1,
        ring: VecDeque::new(),
        ring_bytes: 0,
        stream_epoch: new_stream_epoch(),
        stream_offset: 0,
        stream_markers: VecDeque::new(),
        stream_marker_count: 0,
        ring_reconstructs_screen: true,
        settle_nudge_at: None,
        events,
        vt: Vt::live(sidecar.commands, sidecar.queue),
        support_query: SupportQuery::default(),
        answering: false,
        answers_live: false,
        applied_answers: None,
        size_reports: true,
        held_replies: Vec::new(),
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
    };
    // A carried or created session arrives with a status this actor did not
    // derive; the engine adopts it so the roster and the engine never disagree
    // about a session neither of them has seen a transition for yet.
    let adopted = session.status.clone();
    session
        .status_engine
        .seed(&adopted, adopted_clocks.as_ref(), std::time::Instant::now());
    session.sync_status_watch();
    // The previous image's answers, applied while answering is still off, so
    // the program is not told of a change that did not happen.
    if let Some(answers) = facts_answers {
        session.send_sidecar(SidecarCommand::SetAnswers(answers.clone()));
        session.applied_answers = Some(answers);
    }
    for chunk in replay.chunks {
        // Through the same two paths a live byte takes, in the same order: the
        // ring it will be replayed from, and the VT that answers snapshots —
        // unless that VT already holds the previous image's screen.
        if !starts_from_snapshot {
            session.send_sidecar(SidecarCommand::Write(chunk.clone()));
        }
        session.push_ring(chunk);
    }
    // Live output from here on: a query in it is the program waiting.
    session.answers_live = true;
    session.sync_answering();
    // `push_ring` may have set this itself, if what was carried no longer fits
    // the cap; either way the previous actor's verdict still applies.
    session.ring_reconstructs_screen &= replay.faithful;
    // A snapshot of a VT that had already lost the program's modes carries
    // the loss, so the previous image's verdict travels too.
    session.input_modes_known = !input_modes_unknown && (starts_from_snapshot || session.ring_reconstructs_screen);
    // What the previous image accepted and never wrote goes first, then the
    // end of a paste whose remaining pieces went to that image's connection.
    for chunk in pending_input {
        let _ = session.input_tx.send(chunk.to_vec());
    }
    if paste_was_open {
        let _ = session.input_tx.send(PASTE_END.to_vec());
    }

    if !session.ring_reconstructs_screen {
        // The VT this actor started is blank plus a replay that does not draw
        // the screen the program believes it is looking at — output older than
        // the ring is gone, or was written into a different grid. It used to
        // be declared stale for that, permanently: every attach for the rest
        // of this image's life then served a raw ring replay smeared over
        // whatever the client already showed — after every update, every
        // long-lived session greeted the phone with a garbled screen until it
        // was closed. The VT stays live instead. From the replay onward it has
        // eaten every byte, so its screen is a coherent composition — blank
        // where history is gone — and the snapshot prologue is built to land
        // that cleanly on a client in any prior state. What the VT cannot
        // know, the program is asked to say again: the nudge's SIGWINCH makes
        // a TUI repaint as ordinary output, which corrects this VT and every
        // attachment at once. (`mark_vt_stale` remains for the one case that
        // truly cannot heal — a sidecar left behind by the PTY — where nothing
        // will ever feed the VT the missing bytes.)
        session.pty.nudge_repaint();
    }

    tokio::spawn(run(
        session,
        rx,
        waiter,
        on_exit,
        sidecar.results,
        sidecar.thread,
        input_writer,
        stop_writer,
        unwritten,
        termination_reason.clone(),
    ));
    Ok(SessionHandle {
        id: facts.id,
        pid,
        tx,
        termination_reason,
    })
}

/// One step of a `vt_resume` replay: ring bytes, or a marker between them.
enum Replayed {
    Bytes(Bytes),
    Marker(Event),
}

/// A stream epoch no other actor shares: seeded per process by the hasher's
/// random keys, and mixed with the clock so two actors in one process differ.
fn new_stream_epoch() -> u64 {
    use std::hash::BuildHasher;
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_nanos());
    // 53 bits, so every JSON reader on the wire holds it exactly.
    std::collections::hash_map::RandomState::new().hash_one(nanos) & ((1 << 53) - 1)
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

#[cfg(test)]
fn spawn_sidecar(rows: u16, cols: u16) -> anyhow::Result<Sidecar> {
    let input = termiod_vt::InputEncoder::new()
        .map_err(|error| anyhow::anyhow!("input encoders: {error}"))?;
    spawn_sidecar_sharing(rows, cols, Arc::new(Mutex::new(input)), None)
}

/// Copies the VT's modes into the session's input encoders, and says when the
/// program has just turned focus reports on.
fn refresh_input(
    input: &Mutex<termiod_vt::InputEncoder>,
    terminal: Option<&termiod_vt::VtTerminal>,
) -> bool {
    let Some(terminal) = terminal else { return false };
    let Ok(mut encoder) = input.lock() else { return false };
    let before = encoder.modes().focus_reporting;
    encoder.refresh(terminal);
    !before && encoder.modes().focus_reporting
}

fn spawn_sidecar_sharing(
    rows: u16,
    cols: u16,
    input: Arc<Mutex<termiod_vt::InputEncoder>>,
    snapshot: Option<Vec<u8>>,
) -> anyhow::Result<Sidecar> {
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
            let restored = snapshot.and_then(|bytes| {
                termiod_vt::VtTerminal::from_native_snapshot(&bytes)
                    .map_err(|error| {
                        eprintln!("termiod: carried VT snapshot undecodable, replaying the ring: {error}");
                    })
                    .ok()
            });
            let mut terminal = match restored.map(Ok).unwrap_or_else(|| termiod_vt::VtTerminal::new(rows, cols)) {
                Ok(terminal) => Some(terminal),
                Err(error) => {
                    eprintln!("termiod: failed to initialize VT sidecar: {error}");
                    None
                }
            };
            let mut fault = terminal
                .is_none()
                .then(|| "VT sidecar initialization failed".to_string());
            // Not refreshed here: `seed_input` already gave the encoders this
            // session's modes, and a terminal still blank before its replay
            // would take them away again. The first parsed batch refreshes.
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
            let mut programs = ProgramFeed::default();
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
                        let mut replies = Vec::new();
                        if let Some(terminal) = terminal.as_mut() {
                            terminal.vt_write(&bytes);
                            programs.note(terminal.take_events());
                            replies.append(&mut terminal.take_replies());
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
                                        programs.note(terminal.take_events());
                                        replies.append(&mut terminal.take_replies());
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
                        if !replies.is_empty() && result_tx.send(SidecarResult::Replies(replies)).is_err() {
                            break;
                        }
                        if refresh_input(&input, terminal.as_ref())
                            && result_tx.send(SidecarResult::FocusReportsOn).is_err()
                        {
                            break;
                        }
                        if let Some(signal) = programs.take_signal() {
                            signals.push(signal);
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
                                refresh_input(&input, Some(terminal));
                                // In-band size reports (mode 2048) are written
                                // by the resize itself, not by any output.
                                let replies = terminal.take_replies();
                                if !replies.is_empty() && result_tx.send(SidecarResult::Replies(replies)).is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    SidecarCommand::Snapshot {
                        client_id,
                        request_id,
                        scrollback,
                        native,
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
                                    let native = native
                                        .then(|| match terminal.native_snapshot() {
                                            Ok(bytes) => Some(bytes),
                                            Err(error) => {
                                                eprintln!(
                                                    "termiod: native snapshot unavailable: {error}; sending the VT repaint"
                                                );
                                                None
                                            }
                                        })
                                        .flatten();
                                    Ok(SidecarCapture {
                                        snapshot,
                                        vt,
                                        native,
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
                    SidecarCommand::SetAlone(alone) => {
                        if let Some(terminal) = terminal.as_mut() {
                            terminal.set_alone(alone);
                        }
                    }
                    SidecarCommand::SetAnswering(on) => {
                        if let Some(terminal) = terminal.as_mut() {
                            terminal.set_answering(on);
                        }
                    }
                    SidecarCommand::SetAnswers(answers) => {
                        if let Some(terminal) = terminal.as_mut() {
                            if let Err(error) = terminal.set_answers(&answers) {
                                eprintln!("termiod: VT answers not applied: {error}");
                            }
                            let replies = terminal.take_replies();
                            if !replies.is_empty() && result_tx.send(SidecarResult::Replies(replies)).is_err() {
                                break;
                            }
                        }
                    }
                    SidecarCommand::Shutdown => break,
                    SidecarCommand::Carry(reply) => {
                        let native = match (&fault, terminal.as_ref()) {
                            (None, Some(terminal)) => terminal.native_snapshot().ok(),
                            _ => None,
                        };
                        let _ = reply.send(native);
                        break;
                    }
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
    input_writer: tokio::task::JoinHandle<()>,
    stop_writer: tokio::sync::oneshot::Sender<()>,
    unwritten: Arc<Mutex<Vec<Bytes>>>,
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
        let settle_nudge_at = session.settle_nudge_at;
        tokio::select! {
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
                    // The VT goes with the session when it can: a native
                    // snapshot taken after every byte this actor fed it. A VT
                    // that is down, or too far behind to answer in time,
                    // sends none, and the new image replays the ring instead.
                    let (native_tx, native_rx) = std_mpsc::channel();
                    let answer = if session.send_sidecar(SidecarCommand::Carry(native_tx)) {
                        tokio::task::spawn_blocking(move || native_rx.recv_timeout(CARRY_SNAPSHOT_TIMEOUT))
                            .await
                            .ok()
                    } else {
                        None
                    };
                    // A sidecar that answered — snapshot or not — has stopped.
                    let answered = matches!(answer, Some(Ok(_)) | Some(Err(std_mpsc::RecvTimeoutError::Disconnected)));
                    let native = match answer {
                        Some(Ok(native)) => native,
                        _ => None,
                    };
                    // Replies to bytes the sidecar parsed before it stopped are
                    // still in flight; on the input path they cross with the
                    // session, which the new image does not answer again. An
                    // open paste ends here first, or they would cross inside it.
                    session.close_open_paste();
                    while let Ok(result) = sidecar_results.try_recv() {
                        if let SidecarResult::Replies(mut replies) = result {
                            SupportQuery::strip_other_reply(&mut replies);
                            session.held_replies.extend_from_slice(&replies);
                        }
                    }
                    if !session.held_replies.is_empty() {
                        let _ = session.input_tx.send(std::mem::take(&mut session.held_replies));
                    }
                    // The PTY writer stops at once and hands back what it
                    // had not written, which crosses with the session.
                    let carried = session.into_carried(native);
                    let _ = stop_writer.send(());
                    let _ = input_writer.await;
                    let mut carried = carried;
                    if let Ok(carried) = carried.as_mut() {
                        carried.info.pending_input =
                            unwritten.lock().map(|mut bytes| std::mem::take(&mut *bytes)).unwrap_or_default();
                        carried.info.pending_len =
                            carried.info.pending_input.iter().map(|chunk| chunk.len() as u64).sum();
                    }
                    // The parser is a few kilobytes of grid and a thread that
                    // has already stopped; joining it costs a scheduler turn,
                    // and skipping it would leave the thread running into the
                    // exec. One still parsing a backlog past the timeout is
                    // left to the exec instead: waiting for it would spend the
                    // carry deadline and strand the session.
                    if answered {
                        let _ = tokio::task::spawn_blocking(move || sidecar_thread.join()).await;
                    }
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
                                OscSignal::ProgramStatus(summary) => {
                                    session.status_engine.note_program_status(summary, now)
                                }
                            };
                            if let Some(change) = change {
                                session.apply_status_change(change);
                            }
                        }
                    }
                    Some(SidecarResult::FocusReportsOn) => session.report_writer_focus(),
                    Some(SidecarResult::Replies(replies)) => session.write_replies(replies),
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
                        session.answer_support_query(&chunk);
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
    session.vt.shut_down();

    let code = match waiter.take() {
        Some(waiter) => reap_answering(&mut session, &mut rx, waiter).await,
        None => -1,
    };
    // Read after the reap rather than before: a `Kill` that arrived while the
    // reap was pending recorded its reason on the handle, and that reason is
    // still the truth about how this session ended.
    if end_reason == EndReason::Exited {
        if let Some(requested) = *termination_reason.lock().unwrap() {
            end_reason = requested;
        }
    }
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

/// Waits for the child to be reaped while still answering the daemon.
///
/// The PTY closing does not mean the child can be reaped yet. A process the
/// kernel holds in exit (`ps` state `E`) was seen to stay there for hours, with
/// `kill -9` doing nothing. Until the reap returns, this session's handle is
/// still in the daemon's table, and `list` asks every handle for its info with
/// no deadline. An actor that stopped reading its messages here hung `list`,
/// and every attach and create behind it, for the whole host.
async fn reap_answering(
    session: &mut Session,
    rx: &mut mpsc::UnboundedReceiver<SessionMsg>,
    mut waiter: tokio::task::JoinHandle<i32>,
) -> i32 {
    let mut messages_open = true;
    loop {
        tokio::select! {
            code = &mut waiter => return code.unwrap_or(-1),
            msg = rx.recv(), if messages_open => match msg {
                Some(SessionMsg::Info { reply }) => {
                    let mut info = session.info();
                    info.alive = false;
                    let _ = reply.send(info);
                }
                Some(SessionMsg::Kill { .. }) => kill_process_groups(session),
                // Everything else asks a live PTY for something. Dropping the
                // message drops its reply channel, which every caller already
                // reads as a session that could not answer.
                Some(_) => {}
                None => messages_open = false,
            },
        }
    }
}

/// The child is a session leader, so its own group is `pid` — but it is not
/// always the group the program is in. A launch line the shell could not
/// `exec` into leaves that shell in place, and `-i` turns job control on, so the
/// shell puts the agent in a group of its own; a plain terminal does the same
/// for everything the user runs. The pty hangup covers most of it, and an agent
/// that ignores SIGHUP would outlive the session that started it, so the
/// foreground group is killed too. Ordered so the program dies before the shell
/// that would otherwise be told its child went away.
fn kill_process_groups(session: &Session) {
    let child_group = session.pid;
    let foreground_group = session.foreground.group();
    unsafe {
        if let Some(group) = foreground_group {
            if group != child_group {
                libc::kill(-group, libc::SIGKILL);
            }
        }
        libc::kill(-child_group, libc::SIGKILL);
    }
}

fn handle_msg(session: &mut Session, msg: SessionMsg) -> Option<EndReason> {
    match msg {
        SessionMsg::AddClient {
            id,
            interactive,
            rows,
            cols,
            rendering,
            out,
            backlog,
            snapshot,
            scrollback,
            grid_diff,
            vt_stream,
            vt_answers,
            answers,
            vt_resume,
            resume,
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
            // A resume continues the stream plane where it stopped, so it is
            // only taken whole: every replayed byte is reserved first, and a
            // replay that does not fit falls back to a fresh snapshot.
            // Not while the VT is stale or the input modes are unknown: the
            // snapshot path refuses the stream plane then, and so must this.
            let resumed = resume
                .filter(|_| snapshot && vt_stream && !grid_diff)
                .filter(|_| session.vt.is_live() && session.input_modes_known)
                .and_then(|position| session.resume_replay(position).map(|replay| (position, replay)))
                .and_then(|(position, replay)| {
                    let mut metered = Vec::with_capacity(replay.len());
                    for step in replay {
                        match step {
                            Replayed::Bytes(bytes) => match backlog.reserve(bytes) {
                                Some(payload) => metered.push(ClientEvent::Data(payload)),
                                None => {
                                    for event in &metered {
                                        if let ClientEvent::Data(payload) = event {
                                            backlog.release(payload);
                                        }
                                    }
                                    return None;
                                }
                            },
                            Replayed::Marker(marker) => metered.push(ClientEvent::Event(marker)),
                        }
                    }
                    Some((position, metered))
                });
            let snapshot_request =
                (snapshot && resumed.is_none()).then(|| session.allocate_snapshot_request());

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
                None if resumed.is_some() => ClientPlane::Stream(ClientDelivery::Live),
                None => ClientPlane::Raw,
                Some(request_id) => {
                    let delivery = ClientDelivery::SnapshotPending {
                        request_id,
                        data: VecDeque::new(),
                        deferred: VecDeque::new(),
                    };
                    if grid_diff {
                        ClientPlane::Grid(delivery)
                    } else if vt_stream {
                        ClientPlane::Stream(delivery)
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
                    // What it declares here is a best guess — the window it is
                    // going into may not have laid out yet, and says so with a
                    // zero.
                    viewport: (rows > 0 && cols > 0).then_some((rows, cols)),
                    rendering,
                    typed_unseen: None,
                    staged_history: VecDeque::new(),
                    backlog_strikes: 0,
                    focused: None,
                    answers_said: vt_answers && answers.is_some(),
                    answers: vt_answers.then(|| answers.unwrap_or_default()),
                    vt_resume,
                },
            );
            // Ahead of anything the session sends it from here on, so the
            // replay ends exactly where live output and markers continue.
            if let Some((position, replay)) = resumed {
                if let Some(entry) = session.clients.get(&id) {
                    let mut steps = std::iter::once(ClientEvent::Event(Event::StreamResumed {
                        session: session.id.to_string(),
                        epoch: position.epoch,
                        offset: position.offset,
                        live: session.stream_offset,
                        live_markers: session.stream_marker_count,
                    }))
                    .chain(replay);
                    for step in steps.by_ref() {
                        if let Err(error) = entry.out.send(step) {
                            if let ClientEvent::Data(payload) = error.0 {
                                entry.backlog.release(&payload);
                            }
                            break;
                        }
                    }
                    for step in steps {
                        if let ClientEvent::Data(payload) = step {
                            entry.backlog.release(&payload);
                        }
                    }
                }
            }
            // `vt_stale` went out once, to whoever was attached; a client
            // arriving later must hear it too, or it would wait for the host
            // to answer queries the host can no longer answer.
            if vt_answers {
                if let Some(reason) = session.vt.refusal().map(str::to_string) {
                    if let Some(entry) = session.clients.get(&id) {
                        let _ = entry.out.send(ClientEvent::Event(Event::VtStale {
                            session: session.id.to_string(),
                            reason,
                        }));
                    }
                }
            }
            // Enabling precedes this client's in-band Snapshot request, so
            // later Writes can only produce G results after its S boundary.
            session.sync_grid_diff_interest();
            // Attaching is a viewer arriving, not a device taking over. The
            // token travels by typing — both ends claim on input — so the only
            // attach that takes it is the one that finds nobody holding it.
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
            session.request_size(&id);
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
            session.drop_client(&id);
            session.sync_grid_diff_interest();
            if old_writer.as_ref() == Some(&id) {
                session.recompute_writer();
            }
            if session.writer != old_writer {
                session.emit_writer_changed(session.writer.clone());
            }
            // Leaving is not using: the size stays where the last person put
            // it (§12). The viewer that left may have been the phone whose
            // socket iOS just tore down on a backgrounding — resizing here is
            // what made every pocket-and-return cost a full TUI reflow. The
            // remaining screens reclaim the size the moment somebody types or
            // resizes at one of them.
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
        SessionMsg::Input { id, mut data } => {
            if session.writer.as_ref() == Some(&id) {
                // While the VT is live `SupportQuery` has answered, so the
                // writer's own answer would be a second one.
                if session.vt.is_live() {
                    session.support_query.strip_writer_reply(&mut data);
                    if data.is_empty() {
                        return None;
                    }
                }
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
                session.take_size_for_input(&id);
                session.apply_size_policy();
                session.close_open_paste();
                let _ = session.input_tx.send(data);
            } else {
                session.reject_not_writer(&id);
            }
        }
        SessionMsg::InputEvent { id, event } => session.input_event(&id, event),
        SessionMsg::Answers { id, answers } => {
            if let Some(entry) = session.clients.get_mut(&id) {
                if entry.answers.is_some() {
                    entry.answers = Some(answers);
                    entry.answers_said = true;
                }
            }
            session.sync_answering();
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
            entry.viewport = declared;
            entry.rendering = rendering;
            if entry
                .typed_unseen
                .is_some_and(|at| at.elapsed() > TYPED_CLAIM_WINDOW)
            {
                entry.typed_unseen = None;
            }
            // A claim is spent only by a declaration that can complete it: one
            // that renders and has a size. A 0×0 layout pass keeps it.
            let typed = rendering && declared.is_some() && entry.typed_unseen.take().is_some();
            // Keep the committed grid when a screen parks. A remaining viewer
            // can request the size on its next layout or take it by typing.
            if typed {
                session.take_size(&id);
                session.apply_size_policy();
            } else if rendering {
                session.request_size(&id);
            }
        }
        SessionMsg::Inject { data } => {
            session.close_open_paste();
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
            kill_process_groups(session);
            return Some(reason);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{
        daemon_owned_env, handle_msg, path_led_by, should_emit_keyframe, spawn_sidecar, ClientBacklog,
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

    /// A hook reports with `termio agent report --id "$TERMIOD_SESSION_ID"`, so a
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

    /// §1.2 of the docker-lessons RFC: every session this daemon spawns finds
    /// the `termio` installed beside it, because the daemon's own directory
    /// leads the session's PATH — and no dotfile is ever written for it.
    #[test]
    fn the_daemons_directory_leads_the_sessions_path() {
        assert_eq!(
            path_led_by("/home/u/.local/bin", Some("/usr/bin:/bin")),
            Some("/home/u/.local/bin:/usr/bin:/bin".to_string())
        );
        // Already leading: nothing to change.
        assert_eq!(path_led_by("/home/u/.local/bin", Some("/home/u/.local/bin:/usr/bin")), None);
        // Present but shadowed: still prepended, so the client shipped beside
        // this daemon wins over a stray older install.
        assert_eq!(
            path_led_by("/home/u/.local/bin", Some("/opt/stale:/home/u/.local/bin")),
            Some("/home/u/.local/bin:/opt/stale:/home/u/.local/bin".to_string())
        );
        // No PATH to prepend to is not a PATH to invent.
        assert_eq!(path_led_by("/home/u/.local/bin", None), None);
        assert_eq!(
            path_led_by("/home/u/.local/bin", Some("")),
            Some("/home/u/.local/bin".to_string())
        );
    }

    /// A client-supplied PATH is the base, not a casualty: the daemon's entry
    /// is layered after it and extends it rather than replacing it.
    #[test]
    fn a_client_supplied_path_is_extended_not_replaced() {
        let mut env = vec![("PATH".to_string(), "/only/what/the/client/sent".to_string())];
        super::lead_path_with("/home/u/.local/bin", &mut env);
        let path = env
            .iter()
            .rev()
            .find(|(key, _)| key == "PATH")
            .map(|(_, value)| value.as_str())
            .expect("a PATH entry");
        assert_eq!(path, "/home/u/.local/bin:/only/what/the/client/sent");
    }

    /// The prepend is for boxes the deploy loop installed. On a Mac the
    /// client reaches sessions through the app's own support copy, and the
    /// daemon's directory — a bundle Sparkle may have replaced, or a cargo
    /// checkout holding another channel's `termio` — must never lead a
    /// session's PATH.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_mac_daemon_never_leads_the_sessions_path() {
        assert_eq!(super::client_path_directory(), None);
    }

    /// Sessions spawning at once all get a usable link. Removing the old link
    /// before creating the new one failed both halves of that: the loser of the
    /// race got `EEXIST` and its session no `PATH` entry at all, and until the
    /// winner finished there was an instant with no link for a child to exec.
    #[test]
    fn concurrent_spawns_all_get_the_client_link() {
        let root = std::path::PathBuf::from(format!(
            "/tmp/termiod-link-{}-{}",
            std::process::id(),
            "concurrent"
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("test directory");
        let client = root.join("termio-real");
        std::fs::write(&client, b"#!/bin/sh\n").expect("client");
        let directory = root.join("bin");
        std::fs::create_dir_all(&directory).expect("link directory");
        // A stale link, so every caller takes the replacing path rather than
        // the read-link fast path.
        std::os::unix::fs::symlink(root.join("termio-old"), directory.join("termio"))
            .expect("stale link");

        let failures = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let absent = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        std::thread::scope(|scope| {
            for _ in 0..8 {
                let directory = directory.clone();
                let client = client.clone();
                let failures = std::sync::Arc::clone(&failures);
                scope.spawn(move || {
                    if super::place_client_link(&directory, &client).is_err() {
                        failures.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                });
            }
            // A reader standing in for a child about to exec. What it must never
            // see is the link *gone*, which is what unlinking first produced;
            // `rename` leaves the name occupied throughout.
            let link = directory.join("termio");
            let absent = std::sync::Arc::clone(&absent);
            scope.spawn(move || {
                for _ in 0..2_000 {
                    if matches!(
                        std::fs::read_link(&link),
                        Err(ref error) if error.kind() == std::io::ErrorKind::NotFound
                    ) {
                        absent.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                }
            });
        });

        assert_eq!(failures.load(std::sync::atomic::Ordering::Relaxed), 0);
        assert_eq!(absent.load(std::sync::atomic::Ordering::Relaxed), 0);
        assert_eq!(
            std::fs::read_link(directory.join("termio")).expect("a link"),
            client
        );
        // Nothing is left behind but the link itself.
        let entries: Vec<_> = std::fs::read_dir(&directory)
            .expect("read")
            .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
            .collect();
        assert_eq!(entries.len(), 1, "{entries:?}");

        let _ = std::fs::remove_dir_all(&root);
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
                native: false,
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
                input: Arc::new(std::sync::Mutex::new(termiod_vt::InputEncoder::new().unwrap())),
                        paste_in_progress: None,
                        input_modes_known: true,
                clients: HashMap::new(),
                writer: None,
                next_seq: 0,
                size_owner: None,
                survivors: std::collections::HashSet::new(),
                next_snapshot_request: 1,
                ring: VecDeque::new(),
                ring_bytes: 0,
                stream_epoch: super::new_stream_epoch(),
                stream_offset: 0,
                stream_markers: VecDeque::new(),
                stream_marker_count: 0,
                ring_reconstructs_screen: true,
                settle_nudge_at: None,
                events,
                vt: Vt::live(sidecar_tx, sidecar_queue),
                support_query: super::SupportQuery::default(),
                answering: false,
                answers_live: false,
                applied_answers: None,
                size_reports: true,
                held_replies: Vec::new(),
                status_engine: super::StatusEngine::new(
                    std::time::Instant::now(),
                    super::status::SessionFacts::default(),
                ),
                transcript_path: None,
                foreground: super::Foreground::default(),
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
            SidecarResult::FocusReportsOn => session.report_writer_focus(),
            SidecarResult::Replies(replies) => session.write_replies(replies),
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
        attach_interactive_client_showing(session, id, rows, cols, true)
    }

    fn attach_interactive_client_showing(
        session: &mut Session,
        id: &str,
        rows: u16,
        cols: u16,
        rendering: bool,
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
                rendering,
                out: client_tx,
                backlog: Arc::new(ClientBacklog::new()),
                snapshot: false,
                scrollback: false,
                grid_diff: false,
                vt_stream: false,
                vt_answers: false,
                vt_resume: false,
                resume: None,
                answers: None,
                reply,
            },
        );
        client_rx
    }

    /// The answering switch, from the commands the sidecar is sent: never
    /// before the replay is behind the VT, on while nobody writes or the
    /// writer negotiated `vt_answers`, off for a writer that answers for
    /// itself, and off for good once the VT is stale.
    #[tokio::test]
    async fn the_vt_answers_only_for_a_writer_that_does_not() {
        let (sidecar_tx, sidecar_rx) = std_mpsc::channel();
        let (mut session, _events) = test_session(sidecar_tx, Arc::new(SidecarQueue::new()));
        let switches = |rx: &std_mpsc::Receiver<SidecarCommand>| {
            let mut seen = Vec::new();
            while let Ok(command) = rx.try_recv() {
                match command {
                    SidecarCommand::SetAnswering(on) => seen.push(format!("answering {on}")),
                    SidecarCommand::SetAnswers(answers) => seen.push(format!("answers {:?}", answers.xtversion)),
                    _ => {}
                }
            }
            seen
        };
        let attach_with = |session: &mut Session, id: &str, vt_answers: bool, answers: Option<termiod_vt::Answers>| {
            let (out, _rx) = mpsc::unbounded_channel();
            let (reply, _reply_rx) = oneshot::channel();
            handle_msg(
                session,
                SessionMsg::AddClient {
                    id: ClientId::new(id),
                    interactive: true,
                    rows: 24,
                    cols: 80,
                    rendering: true,
                    out,
                    backlog: Arc::new(ClientBacklog::new()),
                    snapshot: false,
                    scrollback: false,
                    grid_diff: false,
                    vt_stream: false,
                    vt_answers,
                    answers,
                    vt_resume: false,
                    resume: None,
                    reply,
                },
            );
        };
        let attach = |session: &mut Session, id: &str, vt_answers: bool| attach_with(session, id, vt_answers, None);

        session.sync_answering();
        assert!(switches(&sidecar_rx).is_empty(), "answered before the replay was behind it");
        session.answers_live = true;
        session.sync_answering();
        assert_eq!(switches(&sidecar_rx), ["answers \"\"", "answering true"]);

        attach(&mut session, "old-mac", false);
        assert_eq!(switches(&sidecar_rx), ["answering false"]);
        handle_msg(&mut session, SessionMsg::RemoveClient { id: ClientId::new("old-mac") });
        assert_eq!(switches(&sidecar_rx), ["answering true"]);

        attach(&mut session, "mac", true);
        handle_msg(
            &mut session,
            SessionMsg::Answers {
                id: ClientId::new("mac"),
                answers: termiod_vt::Answers { xtversion: "ghostty 1.3.1".to_string(), ..Default::default() },
            },
        );
        assert_eq!(switches(&sidecar_rx), ["answers \"ghostty 1.3.1\""]);

        // Answers sent with the attach are applied before the token is
        // granted, so no query after it is answered with the last writer's.
        handle_msg(&mut session, SessionMsg::RemoveClient { id: ClientId::new("mac") });
        let _ = switches(&sidecar_rx);
        let phone = termiod_vt::Answers { xtversion: "ghostty phone".to_string(), dark: Some(false), ..Default::default() };
        attach_with(&mut session, "phone", true, Some(phone));
        assert_eq!(switches(&sidecar_rx), ["answers \"ghostty phone\""]);

        session.mark_vt_stale("test".to_string());
        assert!(!session.answering);
        session.sync_answering();
        assert!(!session.answering, "a stale VT answered again");
    }

    /// A reply that arrives between a paste's pieces would become part of the
    /// pasted text, so it waits for the paste to close.
    #[tokio::test]
    async fn a_reply_waits_for_an_open_paste_to_close() {
        let (sidecar_tx, _sidecar_rx) = std_mpsc::channel();
        let (mut session, _events) = test_session(sidecar_tx, Arc::new(SidecarQueue::new()));
        let (input_tx, mut input_rx) = mpsc::unbounded_channel();
        session.input_tx = input_tx;
        session.paste_in_progress = Some((ClientId::new("mac"), true));
        session.write_replies(b"\x1b[1;1R".to_vec());
        assert!(input_rx.try_recv().is_err(), "a reply joined an open paste");
        session.close_open_paste();
        assert_eq!(input_rx.try_recv().unwrap(), super::PASTE_END.to_vec());
        assert_eq!(input_rx.try_recv().unwrap(), b"\x1b[1;1R".to_vec());
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
                rendering: true,
                out: client_tx,
                backlog: backlog.clone(),
                snapshot,
                scrollback: false,
                grid_diff: false,
                vt_stream: false,
                vt_answers: false,
                vt_resume: false,
                resume: None,
                answers: None,
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
    /// `vt_stream` input arrives as events and is encoded here, against the
    /// modes of the host's own VT (Rex's model): application cursor keys turn
    /// Up into `ESC O A` with no help from the client. Only the writer types,
    /// and a pane's focus report waits until the program asks for one.
    #[tokio::test]
    async fn input_events_are_encoded_with_the_host_vt_modes() {
        use crate::protocol::{Event, InputAction};
        let Sidecar { commands, results: _results, queue, thread } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        let (input_tx, mut input_rx) = mpsc::unbounded_channel();
        session.input_tx = input_tx;
        let mut vt = termiod_vt::VtTerminal::new(24, 80).unwrap();
        vt.vt_write(b"\x1b[?1h");
        session.input.lock().unwrap().refresh(&vt);

        let _mac = attach_interactive_client(&mut session, "mac");
        let _phone = attach_interactive_client(&mut session, "phone");
        assert!(claim_writer(&mut session, "mac"));
        let up = || Event::Key {
            action: InputAction::Press,
            key: "arrow_up".into(),
            mods: 0,
            consumed_mods: 0,
            text: None,
            unshifted: 0,
            composing: false,
        };
        handle_msg(&mut session, SessionMsg::InputEvent { id: ClientId::new("mac"), event: up() });
        assert_eq!(input_rx.try_recv().unwrap(), b"\x1bOA");
        handle_msg(&mut session, SessionMsg::InputEvent { id: ClientId::new("phone"), event: up() });
        assert!(input_rx.try_recv().is_err(), "an attachment without the token does not type");

        let focus = |focused| Event::Focus { focused };
        handle_msg(&mut session, SessionMsg::InputEvent { id: ClientId::new("mac"), event: focus(true) });
        assert!(input_rx.try_recv().is_err(), "nobody asked for focus reports");
        vt.vt_write(b"\x1b[?1004h");
        session.input.lock().unwrap().refresh(&vt);
        session.report_writer_focus();
        assert_eq!(input_rx.try_recv().unwrap(), b"\x1b[I", "told at once when it asks");
        handle_msg(&mut session, SessionMsg::InputEvent { id: ClientId::new("phone"), event: focus(false) });
        assert!(input_rx.try_recv().is_err(), "only the writer's pane reports focus");
        // The token goes to the phone and comes back. Each move tells the
        // program the new writer's focus, which each pane said while it could
        // not report it.
        assert!(claim_writer(&mut session, "phone"));
        assert_eq!(input_rx.try_recv().unwrap(), b"\x1b[O", "the phone said it lost focus");
        assert!(claim_writer(&mut session, "mac"));
        assert_eq!(input_rx.try_recv().unwrap(), b"\x1b[I", "the Mac's focus was kept");

        // A paste in pieces is one paste; a piece left hanging is closed when
        // the token moves.
        vt.vt_write(b"\x1b[?2004h");
        session.input.lock().unwrap().refresh(&vt);
        let piece = |text: &str, more| Event::Paste { text: text.into(), more };
        handle_msg(&mut session, SessionMsg::InputEvent { id: ClientId::new("mac"), event: piece("a", true) });
        handle_msg(&mut session, SessionMsg::InputEvent { id: ClientId::new("mac"), event: piece("b", false) });
        let pasted: Vec<u8> = std::iter::from_fn(|| input_rx.try_recv().ok()).flatten().collect();
        assert_eq!(pasted, b"\x1b[200~ab\x1b[201~");
        handle_msg(&mut session, SessionMsg::InputEvent { id: ClientId::new("mac"), event: piece("c", true) });
        assert!(claim_writer(&mut session, "phone"));
        let hanging: Vec<u8> = std::iter::from_fn(|| input_rx.try_recv().ok()).flatten().collect();
        assert_eq!(hanging, b"\x1b[200~c\x1b[201~\x1b[O", "closed, then the phone's focus");

        session.vt.shut_down();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// An adopted session's encoders hold the program's modes before the
    /// sidecar has parsed anything, so the first keystroke is encoded right.
    #[test]
    fn an_adopted_session_is_seeded_with_the_carried_modes() {
        let mut vt = termiod_vt::VtTerminal::new(24, 80).unwrap();
        vt.vt_write(b"\x1b[?2004h");
        let mut encoder = termiod_vt::InputEncoder::new().unwrap();
        let kept = super::seed_input(&mut encoder, Some(vt.native_snapshot().unwrap()), &[], 24, 80);
        assert!(kept.is_some());
        assert!(encoder.modes().bracketed_paste, "seeded from the carried VT");

        let mut encoder = termiod_vt::InputEncoder::new().unwrap();
        let kept = super::seed_input(
            &mut encoder,
            Some(b"not a snapshot".to_vec()),
            &[Bytes::from_static(b"\x1b[?1h")],
            24,
            80,
        );
        assert!(kept.is_none(), "an undecodable snapshot falls back to the ring");
        assert!(encoder.modes().cursor_keys_application, "seeded from the ring");
    }

    /// A handoff carries the VT as a native snapshot, so the next image's
    /// sidecar keeps the program's modes — set long ago, past anything
    /// the replay ring still holds — instead of a blank terminal's.
    #[tokio::test]
    async fn a_carried_vt_brings_the_programs_input_modes_with_it() {
        let mut vt = termiod_vt::VtTerminal::new(24, 80).unwrap();
        vt.vt_write(b"\x1b[?1h\x1b[?2004h");
        let input = Arc::new(std::sync::Mutex::new(termiod_vt::InputEncoder::new().unwrap()));
        let Sidecar { commands, results: _results, queue: _queue, thread } =
            super::spawn_sidecar_sharing(24, 80, input.clone(), Some(vt.native_snapshot().unwrap())).unwrap();
        // The sidecar's VT is the carried one: the first batch it parses
        // refreshes the encoders with the program's modes, not a blank's.
        commands.send(SidecarCommand::Write(Bytes::from_static(b"x"))).unwrap();
        let (reply, answer) = std_mpsc::channel();
        commands.send(SidecarCommand::Carry(reply)).unwrap();
        assert!(answer.recv().unwrap().is_some(), "a live VT answers a carry with its snapshot");
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
        let modes = input.lock().unwrap().modes();
        assert!(modes.cursor_keys_application && modes.bracketed_paste);
    }

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

    /// Attaching only requests the size; actual input transfers it.
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
            Some((50, 200)),
            "opening it on the phone must not take the Mac's size"
        );

        // Taking the token is not using the device: a client claims it to be
        // allowed to type, and the claim can arrive from a queued keystroke or a
        // handover. Only the typing itself counts.
        assert!(claim_writer(&mut session, "phone"));
        assert_eq!(session.policy_size(), Some((50, 200)), "a claim is not a use");

        type_into(&mut session, "phone");
        assert_eq!(session.policy_size(), Some((42, 47)));
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

    #[tokio::test]
    async fn only_the_size_owners_viewport_changes_the_pty() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        assert_eq!((session.rows, session.cols), (50, 200));

        // Rotation records the phone's latest preference without reflowing
        // the terminal somebody is using on the Mac.
        declare_viewport(&mut session, "phone", 22, 90, true);
        declare_viewport(&mut session, "mac", 50, 240, true);
        assert_eq!((session.rows, session.cols), (50, 240));
        assert_eq!(
            session.clients[&ClientId::new("phone")].viewport,
            Some((22, 90))
        );

        type_into(&mut session, "phone");
        assert_eq!((session.rows, session.cols), (22, 90));
        declare_viewport(&mut session, "mac", 45, 180, true);
        assert_eq!((session.rows, session.cols), (22, 90));
        declare_viewport(&mut session, "phone", 44, 48, true);
        assert_eq!((session.rows, session.cols), (44, 48));

        type_into(&mut session, "mac");
        assert_eq!((session.rows, session.cols), (45, 180));
        session.vt.shut_down();
        let _ = thread.join();
    }

    #[tokio::test]
    async fn stream_input_takes_the_size_but_focus_and_device_replies_do_not() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());
        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        assert!(claim_writer(&mut session, "phone"));

        handle_msg(
            &mut session,
            SessionMsg::InputEvent {
                id: ClientId::new("phone"),
                event: crate::protocol::Event::Focus { focused: true },
            },
        );
        session.write_replies(b"\x1b[1;1R".to_vec());
        assert_eq!((session.rows, session.cols), (50, 200));

        handle_msg(
            &mut session,
            SessionMsg::InputEvent {
                id: ClientId::new("phone"),
                event: crate::protocol::Event::Paste {
                    text: "hello".into(),
                    more: false,
                },
            },
        );
        assert_eq!((session.rows, session.cols), (42, 47));
        session.vt.shut_down();
        let _ = thread.join();
    }

    #[tokio::test]
    async fn returning_to_a_parked_screen_does_not_take_the_size_back() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        type_into(&mut session, "phone");
        declare_viewport(&mut session, "phone", 42, 47, false);
        assert_eq!(session.policy_size(), None);
        assert_eq!((session.rows, session.cols), (42, 47));

        // An unchanged declaration may acquire an unowned size, but never
        // steal an owned one. Otherwise a surviving viewer could not recover.
        declare_viewport(&mut session, "mac", 50, 200, true);
        assert_eq!((session.rows, session.cols), (50, 200));
        declare_viewport(&mut session, "phone", 42, 47, true);
        assert_eq!((session.rows, session.cols), (50, 200));
        type_into(&mut session, "phone");
        assert_eq!((session.rows, session.cols), (42, 47));

        session.vt.shut_down();
        let _ = thread.join();
    }

    #[tokio::test]
    async fn reconnecting_a_viewer_does_not_take_the_size() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());
        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        type_into(&mut session, "phone");
        handle_msg(
            &mut session,
            SessionMsg::RemoveClient {
                id: ClientId::new("phone"),
            },
        );
        assert_eq!((session.rows, session.cols), (42, 47));
        type_into(&mut session, "mac");
        let _reconnected = attach_interactive_client_at(&mut session, "phone-new", 42, 47);
        assert_eq!((session.rows, session.cols), (50, 200));
        type_into(&mut session, "phone-new");
        assert_eq!((session.rows, session.cols), (42, 47));
        session.vt.shut_down();
        let _ = thread.join();
    }

    /// §12: parking is not using. A phone going to a pocket sends
    /// `rendering: false`; the session must keep the shape that person gave it
    /// rather than snap to an unattended Mac window — that snap is what made
    /// every lock/unlock cycle cost two full TUI reflows. The Mac reclaims the
    /// size the moment somebody actually acts there.
    #[tokio::test]
    async fn parking_the_size_owner_leaves_the_size_behind() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        // A PTY whose resize actually applies: these tests assert the
        // committed size, not just the policy's answer.
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        type_into(&mut session, "phone");
        assert_eq!((session.rows, session.cols), (42, 47));

        declare_viewport(&mut session, "phone", 42, 47, false);
        assert_eq!(
            (session.rows, session.cols),
            (42, 47),
            "the phone locked; nobody used the Mac, so nothing may resize"
        );

        type_into(&mut session, "mac");
        assert_eq!(
            (session.rows, session.cols),
            (50, 200),
            "typing at the Mac is a person acting; now it resizes"
        );

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// The Mac debounces visibility and sends keys at once, so a person who
    /// shows a pane and types can be heard before the pane says it renders.
    /// That keystroke still moves the size once the declaration lands; a claim
    /// older than the window does not, so a scripted send into a hidden pane
    /// cannot take the size when the pane is shown much later.
    #[tokio::test]
    async fn typing_just_before_rendering_still_takes_the_size() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        type_into(&mut session, "mac");
        declare_viewport(&mut session, "phone", 42, 47, false);
        assert_eq!((session.rows, session.cols), (50, 200));

        type_into(&mut session, "phone");
        assert_eq!(
            (session.rows, session.cols),
            (50, 200),
            "the phone has not said it renders yet"
        );
        declare_viewport(&mut session, "phone", 42, 47, true);
        assert_eq!(
            (session.rows, session.cols),
            (42, 47),
            "the keystroke that came first finishes the transfer"
        );

        type_into(&mut session, "mac");
        declare_viewport(&mut session, "phone", 42, 47, false);
        type_into(&mut session, "phone");
        let stale =
            std::time::Instant::now() - super::TYPED_CLAIM_WINDOW - std::time::Duration::from_secs(1);
        session
            .clients
            .get_mut(&ClientId::new("phone"))
            .unwrap()
            .typed_unseen = Some(stale);
        declare_viewport(&mut session, "phone", 42, 47, true);
        assert_eq!(
            (session.rows, session.cols),
            (50, 200),
            "an expired claim only requests, and the Mac is still sizing"
        );

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// The daemon drops a client on its own, such as one whose backlog
    /// overflowed. That is a departure too: the survivor's automatic report
    /// must not take the size, even before the socket's own removal arrives.
    #[tokio::test]
    async fn a_dropped_size_owner_holds_the_size_like_one_that_left() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        type_into(&mut session, "phone");
        assert_eq!((session.rows, session.cols), (42, 47));

        session.remove_dead(vec![ClientId::new("phone")]);
        declare_viewport(&mut session, "mac", 50, 200, true);
        assert_eq!((session.rows, session.cols), (42, 47));

        // The socket's own removal arrives late and changes nothing.
        handle_msg(
            &mut session,
            SessionMsg::RemoveClient {
                id: ClientId::new("phone"),
            },
        );
        declare_viewport(&mut session, "mac", 50, 200, true);
        assert_eq!((session.rows, session.cols), (42, 47));

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// A pending claim is the last keystroke's, never an older one's; it
    /// survives a layout pass with no size; and a parked owner's keystroke is
    /// remembered like anyone else's.
    #[tokio::test]
    async fn a_pending_size_claim_is_the_newest_and_waits_for_a_real_viewport() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);

        // Newer typing elsewhere cancels the claim.
        type_into(&mut session, "mac");
        declare_viewport(&mut session, "phone", 42, 47, false);
        type_into(&mut session, "phone");
        type_into(&mut session, "mac");
        declare_viewport(&mut session, "phone", 42, 47, true);
        assert_eq!(
            (session.rows, session.cols),
            (50, 200),
            "the Mac typed after the phone, so the phone's claim is gone"
        );

        // Newer typing on another hidden screen cancels it too.
        type_into(&mut session, "mac");
        declare_viewport(&mut session, "mac", 50, 200, false);
        declare_viewport(&mut session, "phone", 42, 47, false);
        type_into(&mut session, "mac");
        type_into(&mut session, "phone");
        declare_viewport(&mut session, "phone", 42, 47, true);
        assert_eq!((session.rows, session.cols), (42, 47));
        declare_viewport(&mut session, "mac", 50, 200, true);
        assert_eq!(
            (session.rows, session.cols),
            (42, 47),
            "the phone typed last, so the Mac's older claim is gone"
        );
        type_into(&mut session, "mac");

        // A 0×0 layout pass does not spend the claim.
        declare_viewport(&mut session, "phone", 42, 47, false);
        type_into(&mut session, "phone");
        declare_viewport(&mut session, "phone", 0, 0, true);
        assert_eq!((session.rows, session.cols), (50, 200));
        declare_viewport(&mut session, "phone", 42, 47, true);
        assert_eq!(
            (session.rows, session.cols),
            (42, 47),
            "the claim waited for a viewport that can complete it"
        );

        // The parked owner's own keystroke is remembered too.
        declare_viewport(&mut session, "phone", 42, 47, false);
        type_into(&mut session, "phone");
        declare_viewport(&mut session, "mac", 50, 200, true);
        assert_eq!(
            (session.rows, session.cols),
            (50, 200),
            "nobody was sizing, so the Mac's layout took the size"
        );
        declare_viewport(&mut session, "phone", 42, 47, true);
        assert_eq!(
            (session.rows, session.cols),
            (42, 47),
            "the phone typed first and is now showing, so it takes the size back"
        );

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// §12, the harder half: even the size owner's *death* moves nothing. A
    /// backgrounded iOS app tears its socket down without a goodbye, so a
    /// departure is routinely the same person who is about to come back.
    #[tokio::test]
    async fn a_departed_size_owner_leaves_the_size_behind() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());

        let _mac = attach_interactive_client_at(&mut session, "mac", 50, 200);
        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        type_into(&mut session, "phone");
        assert_eq!((session.rows, session.cols), (42, 47));

        handle_msg(
            &mut session,
            SessionMsg::RemoveClient {
                id: ClientId::new("phone"),
            },
        );
        assert_eq!(
            (session.rows, session.cols),
            (42, 47),
            "the phone's socket died; the size it chose stays"
        );
        declare_viewport(&mut session, "mac", 50, 200, true);
        assert_eq!(
            (session.rows, session.cols),
            (42, 47),
            "the survivor re-declaring its viewport is not a person acting"
        );
        type_into(&mut session, "mac");
        assert_eq!((session.rows, session.cols), (50, 200));

        // A screen that arrives after the owner left is a person opening the
        // session, such as a phone reconnecting under a new id.
        handle_msg(
            &mut session,
            SessionMsg::RemoveClient {
                id: ClientId::new("mac"),
            },
        );
        let _returning = attach_interactive_client_at(&mut session, "phone-again", 42, 47);
        assert_eq!(
            (session.rows, session.cols),
            (42, 47),
            "nobody saw the owner leave, so the new screen sizes the session"
        );

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
        assert_eq!(session.policy_size(), Some((50, 200)));
        type_into(&mut session, "phone");
        assert_eq!(session.policy_size(), Some((42, 47)));

        session.vt.shut_down();
        let _ = thread.join();
    }

    /// An attachment that arrives with no screen in front of it is not a
    /// viewer arriving, and must not take the size on its way in.
    ///
    /// The Mac makes a surface for a session nobody is showing whenever
    /// something other than a pane asks for one — a phone opening a session it
    /// never displayed. That attachment used to be counted as rendering by
    /// construction here, so it was instantly the newest-used candidate and the
    /// PTY moved to a width no screen was showing until its first `R` said
    /// otherwise. One wrong resize per open.
    #[tokio::test]
    async fn an_attachment_that_arrives_not_rendering_never_takes_the_size() {
        let Sidecar {
            commands,
            results: _results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);

        let _phone = attach_interactive_client_at(&mut session, "phone", 42, 47);
        assert_eq!(session.policy_size(), Some((42, 47)));

        let _offscreen =
            attach_interactive_client_showing(&mut session, "offscreen", 50, 200, false);
        assert_eq!(
            session.policy_size(),
            Some((42, 47)),
            "a pane nobody is looking at must not resize the session"
        );

        declare_viewport(&mut session, "offscreen", 50, 200, true);
        assert_eq!(session.policy_size(), Some((42, 47)));
        type_into(&mut session, "offscreen");
        assert_eq!(session.policy_size(), Some((50, 200)));

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

        // A shell running as a *job* — an agent's tool subshell, `claude`
        // shelling out mid-turn — is not the shell whose redisplay the
        // truncating resize protects: the screen it would truncate belongs to
        // the TUI that spawned it.
        session.foreground.set_argv_for_tests(Some(vec!["/bin/zsh".to_string()]));
        session.foreground.set_job_for_tests(true);
        assert!(
            !session.foreground_is_a_shell(),
            "a tool subshell must not switch the resize to truncation"
        );
        session.foreground.set_job_for_tests(false);

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
    /// What a `vt_stream` client receives, with the marker's fields kept: the
    /// order of bytes and markers is the whole contract.
    #[derive(Debug, PartialEq)]
    enum Streamed {
        Data(Vec<u8>),
        Snapshot { native: bool },
        Ready,
        VtResize { rows: u16, cols: u16, reflow: bool },
        Resized { rows: u16, cols: u16 },
    }

    fn drain_stream(
        client: &mut mpsc::UnboundedReceiver<ClientEvent>,
    ) -> (Vec<Streamed>, Option<Vec<u8>>) {
        let mut seen = Vec::new();
        let mut native = None;
        while let Ok(event) = client.try_recv() {
            match event {
                ClientEvent::Data(payload) => seen.push(Streamed::Data(payload.bytes.to_vec())),
                ClientEvent::Snapshot(snapshot) => {
                    seen.push(Streamed::Snapshot {
                        native: snapshot.native.is_some(),
                    });
                    native = snapshot.native.or(native);
                }
                ClientEvent::Event(Event::Ready { .. }) => seen.push(Streamed::Ready),
                ClientEvent::Event(Event::VtResize {
                    rows, cols, reflow, ..
                }) => seen.push(Streamed::VtResize { rows, cols, reflow }),
                ClientEvent::Event(Event::Resized { rows, cols, .. }) => {
                    seen.push(Streamed::Resized { rows, cols })
                }
                _ => {}
            }
        }
        (seen, native)
    }

    fn attach_stream_client(session: &mut Session, id: &str) -> mpsc::UnboundedReceiver<ClientEvent> {
        let (tx, rx) = mpsc::unbounded_channel();
        let (reply, _reply_rx) = oneshot::channel();
        handle_msg(
            session,
            SessionMsg::AddClient {
                id: ClientId::new(id),
                interactive: true,
                rows: 0,
                cols: 0,
                rendering: true,
                out: tx,
                backlog: Arc::new(ClientBacklog::new()),
                snapshot: true,
                scrollback: false,
                grid_diff: false,
                vt_stream: true,
                vt_answers: false,
                vt_resume: false,
                resume: None,
                answers: None,
                reply,
            },
        );
        rx
    }

    fn attach_resuming_client(
        session: &mut Session,
        id: &str,
        resume: Option<crate::protocol::ResumeSpec>,
    ) -> mpsc::UnboundedReceiver<ClientEvent> {
        let (tx, rx) = mpsc::unbounded_channel();
        let (reply, _reply_rx) = oneshot::channel();
        handle_msg(
            session,
            SessionMsg::AddClient {
                id: ClientId::new(id),
                interactive: true,
                rows: 0,
                cols: 0,
                rendering: true,
                out: tx,
                backlog: Arc::new(ClientBacklog::new()),
                snapshot: true,
                scrollback: false,
                grid_diff: false,
                vt_stream: true,
                vt_answers: false,
                vt_resume: true,
                resume,
                answers: None,
                reply,
            },
        );
        rx
    }

    #[derive(Debug, PartialEq)]
    enum Resumed {
        Snapshot,
        Position { offset: u64, markers: u64 },
        Resumed { offset: u64 },
        Marker { rows: u16, cols: u16 },
        Data(Vec<u8>),
    }

    fn drain_resumed(client: &mut mpsc::UnboundedReceiver<ClientEvent>) -> Vec<Resumed> {
        let mut seen = Vec::new();
        while let Ok(event) = client.try_recv() {
            match event {
                ClientEvent::Snapshot(_) => seen.push(Resumed::Snapshot),
                ClientEvent::Data(payload) => seen.push(Resumed::Data(payload.bytes.to_vec())),
                ClientEvent::Event(Event::StreamPosition { offset, markers, .. }) => {
                    seen.push(Resumed::Position { offset, markers })
                }
                ClientEvent::Event(Event::StreamResumed { offset, .. }) => seen.push(Resumed::Resumed { offset }),
                ClientEvent::Event(Event::VtResize { rows, cols, .. }) => seen.push(Resumed::Marker { rows, cols }),
                _ => {}
            }
        }
        seen
    }

    /// A `vt_resume` client that drops and comes back is handed what it
    /// missed from the ring, the marker in its place and no snapshot; one
    /// that already applied the marker is not handed it again; and a position
    /// from another stream, or older than the ring, gets a fresh snapshot.
    #[tokio::test]
    async fn a_stream_client_resumes_where_its_connection_dropped() {
        let Sidecar { commands, mut results, queue, thread } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());
        session.write_sidecar(Bytes::from_static(b"start "));
        session.fan_out(Bytes::from_static(b"start "));

        let mut first = attach_resuming_client(&mut session, "first", None);
        pump_sidecar(&mut session, &mut results, 1).await;
        let attach = drain_resumed(&mut first);
        assert_eq!(attach[..2], [Resumed::Snapshot, Resumed::Position { offset: 6, markers: 0 }]);
        let epoch = session.stream_epoch;

        session.write_sidecar(Bytes::from_static(b"before"));
        session.fan_out(Bytes::from_static(b"before"));
        declare_viewport(&mut session, "first", 10, 40, true);
        session.write_sidecar(Bytes::from_static(b"after"));
        session.fan_out(Bytes::from_static(b"after"));
        pump_sidecar(&mut session, &mut results, 0).await;
        assert_eq!(
            drain_resumed(&mut first),
            [Resumed::Data(b"before".to_vec()), Resumed::Marker { rows: 10, cols: 40 }, Resumed::Data(b"after".to_vec())]
        );
        // Its connection dropped after "before", while more was written.
        handle_msg(&mut session, SessionMsg::RemoveClient { id: ClientId::new("first") });
        session.write_sidecar(Bytes::from_static(b"later"));
        session.fan_out(Bytes::from_static(b"later"));

        let position = |offset, markers| Some(crate::protocol::ResumeSpec { epoch, offset, markers });
        let mut missed_marker = attach_resuming_client(&mut session, "missed", position(12, 0));
        let replay = drain_resumed(&mut missed_marker);
        assert_eq!(
            replay[..4],
            [
                Resumed::Resumed { offset: 12 },
                Resumed::Marker { rows: 10, cols: 40 },
                Resumed::Data(b"after".to_vec()),
                Resumed::Data(b"later".to_vec()),
            ]
        );
        assert!(!replay.contains(&Resumed::Snapshot), "a resumed client was sent a snapshot");
        handle_msg(&mut session, SessionMsg::RemoveClient { id: ClientId::new("missed") });

        let mut applied_marker = attach_resuming_client(&mut session, "applied", position(12, 1));
        assert_eq!(
            drain_resumed(&mut applied_marker)[..3],
            [Resumed::Resumed { offset: 12 }, Resumed::Data(b"after".to_vec()), Resumed::Data(b"later".to_vec())]
        );
        handle_msg(&mut session, SessionMsg::RemoveClient { id: ClientId::new("applied") });

        let other_stream = Some(crate::protocol::ResumeSpec { epoch: epoch ^ 1, offset: 12, markers: 0 });
        let mut stranger = attach_resuming_client(&mut session, "stranger", other_stream);
        pump_sidecar(&mut session, &mut results, 1).await;
        assert_eq!(drain_resumed(&mut stranger).first(), Some(&Resumed::Snapshot));
        handle_msg(&mut session, SessionMsg::RemoveClient { id: ClientId::new("stranger") });

        let flood = Bytes::from(vec![b'x'; super::RING_CAP + 1]);
        session.write_sidecar(flood.clone());
        session.fan_out(flood);
        let mut too_old = attach_resuming_client(&mut session, "too-old", position(12, 1));
        pump_sidecar(&mut session, &mut results, 1).await;
        assert_eq!(drain_resumed(&mut too_old).first(), Some(&Resumed::Snapshot));
        handle_msg(&mut session, SessionMsg::RemoveClient { id: ClientId::new("too-old") });

        // A stale VT refuses the stream plane, resumed or not.
        let live = session.stream_offset;
        session.mark_vt_stale("test".to_string());
        let mut after_stale = attach_resuming_client(&mut session, "after-stale", position(live, 1));
        pump_sidecar(&mut session, &mut results, 0).await;
        assert!(vt_stream_refusal(&mut after_stale).is_some(), "a stale VT resumed a stream client");

        session.vt.shut_down();
        drop(session);
        let _ = thread.join();
    }

    fn vt_stream_refusal(client: &mut mpsc::UnboundedReceiver<ClientEvent>) -> Option<String> {
        while let Ok(event) = client.try_recv() {
            match event {
                ClientEvent::Control(Control::Error {
                    code: ErrorCode::VtStreamUnavailable,
                    message,
                    ..
                }) => return Some(message),
                ClientEvent::Snapshot(_) | ClientEvent::Data(_) => return None,
                _ => {}
            }
        }
        None
    }

    /// A stale VT has no exact state to hand over. The client is told so and
    /// let go, instead of being given a replay its VT would diverge from.
    #[tokio::test]
    async fn a_stream_client_is_refused_rather_than_replayed_from_a_stale_vt() {
        let Sidecar { commands, mut results, queue, thread } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.mark_vt_stale("test".to_string());
        let mut stream = attach_stream_client(&mut session, "stream");
        pump_sidecar(&mut session, &mut results, 0).await;
        let refusal = vt_stream_refusal(&mut stream);
        assert!(refusal.is_some(), "a stale VT still served a vt_stream client");
        assert!(!session.clients.contains_key(&ClientId::new("stream")));
        session.vt.shut_down();
        drop(session);
        let _ = thread.join();
    }

    /// Nor does it take an input event while that refusal is on its way.
    #[tokio::test]
    async fn input_events_are_dropped_while_the_input_modes_are_unknown() {
        use crate::protocol::Event;
        let Sidecar { commands, results: _results, queue, thread } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        let (input_tx, mut input_rx) = mpsc::unbounded_channel();
        session.input_tx = input_tx;
        session.input_modes_known = false;
        let _mac = attach_interactive_client(&mut session, "mac");
        assert!(claim_writer(&mut session, "mac"));
        handle_msg(
            &mut session,
            SessionMsg::InputEvent { id: ClientId::new("mac"), event: Event::Paste { text: "a\nb".into(), more: false } },
        );
        assert!(input_rx.try_recv().is_err(), "a paste encoded without the program's modes");
        session.vt.shut_down();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// A session that lost its input modes in a handoff refuses the stream:
    /// its input would be encoded with modes the program no longer has.
    #[tokio::test]
    async fn a_stream_client_is_refused_when_the_input_modes_are_unknown() {
        let Sidecar { commands, mut results, queue, thread } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.input_modes_known = false;
        let mut stream = attach_stream_client(&mut session, "stream");
        pump_sidecar(&mut session, &mut results, 1).await;
        let refusal = vt_stream_refusal(&mut stream);
        assert!(
            refusal.as_deref().is_some_and(|message| message.contains("input modes")),
            "a session with unknown input modes served a stream: {refusal:?}"
        );
        session.vt.shut_down();
        drop(session);
        let _ = thread.join();
    }

    /// Past the continuation limit the native snapshot cannot be encoded, and
    /// a repaint would start the client outside the sequence the host is in.
    #[tokio::test]
    async fn a_stream_client_is_refused_mid_sequence_past_the_tracking_limit() {
        let Sidecar { commands, mut results, queue, thread } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        let mut unfinished = b"\x1b_Ga=t,f=32;".to_vec();
        unfinished.resize(termiod_vt::CONTINUATION_LIMIT + 4096, b'A');
        session.write_sidecar(Bytes::from(unfinished));
        let mut stream = attach_stream_client(&mut session, "stream");
        pump_sidecar(&mut session, &mut results, 1).await;
        let refusal = vt_stream_refusal(&mut stream);
        assert!(
            refusal
                .as_deref()
                .is_some_and(|message| message.contains("could not be encoded")),
            "a snapshot cut past the tracking limit was served anyway: {refusal:?}"
        );
        session.vt.shut_down();
        drop(session);
        let _ = thread.join();
    }

    /// A resize while the attach snapshot is pending re-requests it behind
    /// the resize: one S, at the new grid, and no marker for a VT the client
    /// does not have yet.
    #[tokio::test]
    async fn a_resize_while_the_attach_snapshot_is_pending_resnapshots_behind_it() {
        let Sidecar { commands, mut results, queue, thread } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());
        let mut stream = attach_stream_client(&mut session, "stream");
        declare_viewport(&mut session, "stream", 12, 40, true);
        pump_sidecar(&mut session, &mut results, 2).await;
        let mut snapshots = Vec::new();
        let mut markers = 0;
        while let Ok(event) = stream.try_recv() {
            match event {
                ClientEvent::Snapshot(snapshot) => snapshots.push((snapshot.rows, snapshot.cols, snapshot.native.is_some())),
                ClientEvent::Event(Event::VtResize { .. }) => markers += 1,
                _ => {}
            }
        }
        assert_eq!(snapshots, vec![(12, 40, true)], "the pre-resize capture was delivered");
        assert_eq!(markers, 0, "a pending client was sent a marker");
        session.vt.shut_down();
        drop(session);
        let _ = thread.join();
    }

    /// The `vt_stream` plane end to end in the session actor: the attach `S`
    /// is native and decodes to the host's screen, and a resize afterwards is a
    /// marker in place between the bytes that straddle it — no barrier and no
    /// keyframe. A `snapshot` client beside it still gets its barrier keyframe,
    /// so the old plane is untouched.
    #[tokio::test]
    async fn a_stream_client_gets_a_marker_in_place_and_no_keyframe_on_resize() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(24, 80).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        // A real PTY, so the resize is applied rather than refused.
        session.pty = Arc::new(Pty::childless_pty_for_resize_test().unwrap());

        let (stream_tx, mut stream) = mpsc::unbounded_channel();
        let (reply, _reply_rx) = oneshot::channel();
        handle_msg(
            &mut session,
            SessionMsg::AddClient {
                id: ClientId::new("stream"),
                interactive: true,
                rows: 0,
                cols: 0,
                rendering: true,
                out: stream_tx,
                backlog: Arc::new(ClientBacklog::new()),
                snapshot: true,
                scrollback: true,
                grid_diff: false,
                vt_stream: true,
                vt_answers: false,
                vt_resume: false,
                resume: None,
                answers: None,
                reply,
            },
        );
        let (mut keyframed, _keyframed_backlog) = attach_snapshot_client(&mut session, "keyframed");
        session.write_sidecar(Bytes::from_static(b"\x1b[1;32mhello\x1b[0m"));
        session.fan_out(Bytes::from_static(b"\x1b[1;32mhello\x1b[0m"));
        pump_sidecar(&mut session, &mut results, 2).await;

        let (attach, native) = drain_stream(&mut stream);
        assert_eq!(
            attach[..2],
            [Streamed::Snapshot { native: true }, Streamed::Ready],
            "the attach S was not native"
        );
        let mut decoded =
            termiod_vt::VtTerminal::from_native_snapshot(&native.expect("native bytes"))
                .expect("the native snapshot did not decode");
        // The S was captured where the attach landed in the VT's FIFO; bytes
        // written after it follow it as data, and the client applies them.
        for item in &attach[2..] {
            match item {
                Streamed::Data(bytes) => decoded.vt_write(bytes),
                other => panic!("unexpected after the attach S: {other:?}"),
            }
        }
        drain(&mut keyframed);

        session.write_sidecar(Bytes::from_static(b"before"));
        session.fan_out(Bytes::from_static(b"before"));
        declare_viewport(&mut session, "stream", 10, 40, true);
        session.write_sidecar(Bytes::from_static(b"after"));
        session.fan_out(Bytes::from_static(b"after"));
        pump_sidecar(&mut session, &mut results, 1).await;

        let (streamed, _) = drain_stream(&mut stream);
        assert_eq!(
            streamed,
            vec![
                Streamed::Data(b"before".to_vec()),
                Streamed::VtResize {
                    rows: 10,
                    cols: 40,
                    reflow: false
                },
                Streamed::Resized { rows: 10, cols: 40 },
                Streamed::Data(b"after".to_vec()),
            ],
            "the marker was not in place, or a keyframe was sent"
        );
        assert!(
            drain(&mut keyframed).contains(&Received::Snapshot),
            "the snapshot-plane client lost its barrier keyframe"
        );

        // The client applies the stream; its screen is the host's.
        decoded.vt_write(b"before");
        decoded.resize_for_shell(10, 40).unwrap();
        decoded.vt_write(b"after");
        session.vt.shut_down();
        drop(session);
        let _ = thread.join();
        let mut reference = termiod_vt::VtTerminal::new(24, 80).unwrap();
        reference.vt_write(b"\x1b[1;32mhello\x1b[0mbefore");
        reference.resize_for_shell(10, 40).unwrap();
        reference.vt_write(b"after");
        assert_eq!(decoded.format_vt().unwrap(), reference.format_vt().unwrap());
    }

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

    /// A resize's keyframe has to precede every byte replayed onto it.
    ///
    /// One PTY chunk takes two paths — `write_sidecar` into the authoritative
    /// VT, `fan_out` toward the clients — and a resize opens the barrier before
    /// the child has answered SIGWINCH. So the answer is *buffered* for the
    /// client while it is *parsed* into the VT. A capture taken after those
    /// writes puts the redraw inside the snapshot, and draining the buffer on
    /// top of it hands the client the same redraw twice.
    ///
    /// The older test beside this one drove the redraw through `write_sidecar`
    /// alone and never called `fan_out`, which is exactly the half that cannot
    /// see this.
    #[tokio::test]
    async fn a_resize_does_not_replay_what_its_keyframe_already_contains() {
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

        // The screen as the child last drew it, before anything moved.
        let stale = Bytes::from_static(b"STALE");
        session.write_sidecar(stale.clone());
        session.fan_out(stale);
        assert_eq!(
            drain(&mut client),
            vec![Received::Data(b"STALE".to_vec())],
            "the pre-resize screen never reached the client"
        );

        session.begin_resize_snapshot_barrier();
        assert!(
            session.clients[&ClientId::new("viewer")].plane.is_pending(),
            "the barrier must open with the resize"
        );

        // The child's answer to SIGWINCH, taking both paths the way a real PTY
        // byte does (see the read loop: `write_sidecar(chunk.clone())` then
        // `fan_out(chunk)`).
        let redraw = Bytes::from_static(b"\x1b[2J\x1b[HREDRAWN");
        session.write_sidecar(redraw.clone());
        session.fan_out(redraw);

        pump_sidecar(&mut session, &mut results, 1).await;

        assert_eq!(
            drain(&mut client),
            vec![
                Received::Snapshot,
                Received::Ready,
                Received::Data(b"\x1b[2J\x1b[HREDRAWN".to_vec()),
            ],
            "the keyframe and the child's redraw did not line up: the redraw \
             belongs behind the keyframe, exactly once"
        );

        session.vt.shut_down();
        let _ = tokio::task::spawn_blocking(move || thread.join()).await;
    }

    /// The screen a resize leaves a client with has to be the one the child
    /// drew, cell for cell — including when the child's redraw is split across
    /// the capture.
    ///
    /// Nothing about a repaint is idempotent: it is cursor addressing and
    /// relative motion, so applying a prefix twice lands the text that follows
    /// it somewhere the child never put it. With the capture taken mid-redraw,
    /// `ESC[A ESC[3G` ends up both inside the keyframe and in the buffer
    /// drained onto it, and the `ddd` behind it is written a row high: the
    /// input box's rule with the typed characters punched through it and the
    /// prompt chevron stranded on the row below. That is #698, and it never
    /// repairs — the grids agree, so no resync is ever armed.
    ///
    /// Replays what the client actually received into a scratch VT and compares
    /// it against the same stream applied once, which is the host's screen.
    #[tokio::test]
    async fn a_redraw_split_across_a_resize_lands_where_the_child_put_it() {
        let Sidecar {
            commands,
            mut results,
            queue,
            thread,
        } = spawn_sidecar(4, 20).unwrap();
        let (mut session, _events) = test_session(commands, queue);
        let (mut client, _backlog) = attach_snapshot_client(&mut session, "viewer");
        pump_sidecar(&mut session, &mut results, 1).await;
        drain(&mut client);

        // An agent's input box: a rule, the prompt row, a rule, with the cursor
        // parked on the bottom one.
        let drawn: &[u8] =
            b"\x1b[2J\x1b[H--------------------\r\n> \r\n--------------------\x1b[3;1H";
        // The answer to SIGWINCH, split the way a busy child splits it: the
        // cursor motion in one write, the text it addresses in the next.
        let moves: &[u8] = b"\x1b[A\x1b[3G";
        let types: &[u8] = b"ddd";

        fn feed(session: &mut Session, bytes: &[u8]) {
            let chunk = Bytes::copy_from_slice(bytes);
            session.write_sidecar(chunk.clone());
            session.fan_out(chunk);
        }
        feed(&mut session, drawn);
        session.begin_resize_snapshot_barrier();
        feed(&mut session, moves);
        pump_sidecar(&mut session, &mut results, 1).await;
        feed(&mut session, types);

        let mut replayed = Vec::new();
        while let Ok(event) = client.try_recv() {
            match event {
                ClientEvent::Snapshot(snapshot) => {
                    replayed.clear();
                    replayed.extend_from_slice(&snapshot.vt.clone().unwrap_or_default());
                }
                ClientEvent::Data(payload) => replayed.extend_from_slice(&payload.bytes),
                _ => {}
            }
        }

        let screen = |bytes: &[u8]| {
            let mut terminal = termiod_vt::VtTerminal::new(4, 20).unwrap();
            terminal.vt_write(bytes);
            terminal.screen_text().unwrap()
        };
        let mut host = Vec::new();
        for chunk in [drawn, moves, types] {
            host.extend_from_slice(chunk);
        }

        assert_eq!(
            screen(&replayed),
            screen(&host),
            "the client's screen is not the one the child drew — the redraw's \
             cursor motion was applied twice, so the text landed a row high"
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
            input: Arc::new(std::sync::Mutex::new(termiod_vt::InputEncoder::new().unwrap())),
                paste_in_progress: None,
                input_modes_known: true,
            clients: HashMap::from([(
                ClientId::new("writer"),
                ClientEntry {
                    out: client_tx,
                    backlog,
                    role: ClientRole::Interactive { seq: 1 },
                    plane: ClientPlane::Raw,
                    viewport: Some((24, 80)),
                    rendering: true,
                    typed_unseen: None,
                    staged_history: VecDeque::new(),
                    backlog_strikes: 0,
                    focused: None,
                    answers: None,
                    answers_said: false,
                    vt_resume: false,
                },
            )]),
            writer: Some(ClientId::new("writer")),
            next_seq: 2,
            size_owner: None,
            survivors: std::collections::HashSet::new(),
            next_snapshot_request: 1,
            ring: VecDeque::new(),
            ring_bytes: 0,
            stream_epoch: super::new_stream_epoch(),
            stream_offset: 0,
            stream_markers: VecDeque::new(),
            stream_marker_count: 0,
            ring_reconstructs_screen: true,
            settle_nudge_at: None,
            events,
            vt: Vt::live(sidecar_tx, Arc::new(SidecarQueue::new())),
            support_query: super::SupportQuery::default(),
            answering: false,
            answers_live: false,
            applied_answers: None,
            size_reports: true,
            held_replies: Vec::new(),
            status_engine: super::StatusEngine::new(
                std::time::Instant::now(),
                super::status::SessionFacts::default(),
            ),
            transcript_path: None,
            foreground: super::Foreground::default(),
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

    /// The whole reflow pipeline against a real zsh: injection gives the
    /// prompt its marks, a storm of narrowing viewports drives
    /// `resize_for_shell` through the same FIFO as the shell's own redraws,
    /// and at the end the screen must still show a prompt — the exact thing
    /// the "prompt disappeared after resize" reports lost. Asserted from the
    /// authoritative snapshot, not the byte stream, because the byte stream
    /// always contains a redraw; the question is whether a later clear ate it.
    #[tokio::test]
    async fn a_real_zsh_keeps_its_prompt_through_a_resize_storm() {
        let Some(zsh) = ["/bin/zsh", "/usr/bin/zsh"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
        else {
            return;
        };
        let home = std::env::temp_dir().join(format!("termiod-zsh-storm-{}", std::process::id()));
        std::fs::create_dir_all(&home).expect("scratch home");

        let (on_exit, _on_exit_rx) = mpsc::unbounded_channel();
        let (events, _events_rx) = broadcast::channel(64);
        let handle = super::spawn(
            SessionId::new("zsh-storm"),
            "test".to_string(),
            "/".to_string(),
            "zsh".to_string(),
            vec![zsh.to_string(), "-i".to_string()],
            vec![
                ("HOME".to_string(), home.display().to_string()),
                ("ZDOTDIR".to_string(), home.display().to_string()),
            ],
            24,
            80,
            None,
            on_exit,
            events,
        )
        .expect("spawning zsh");

        let (client_tx, mut client_rx) = mpsc::unbounded_channel();
        let (reply, answer) = oneshot::channel();
        handle.send(SessionMsg::AddClient {
            id: ClientId::new("writer"),
            interactive: true,
            rows: 24,
            cols: 80,
            rendering: true,
            out: client_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: true,
            scrollback: false,
            grid_diff: false,
            vt_stream: false,
            vt_answers: false,
            vt_resume: false,
            resume: None,
            answers: None,
            reply,
        });
        answer.await.expect("attached");

        // Wait until the injected shim has marked a prompt, which is also the
        // signal that zsh is at its prompt and idle.
        let mut seen = Vec::new();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
        loop {
            let event = tokio::time::timeout_at(deadline, client_rx.recv())
                .await
                .expect("zsh reached a marked prompt")
                .expect("client stream open");
            if let ClientEvent::Data(payload) = event {
                seen.extend_from_slice(&payload.bytes);
                if seen
                    .windows(7)
                    .any(|window| window == b"\x1b]133;A")
                {
                    break;
                }
            }
        }

        // The streaming cadence of a window drag: several narrowings in
        // flight, each racing the redraw of the one before it.
        for cols in [70u16, 60, 50, 40] {
            handle.send(SessionMsg::Viewport {
                id: ClientId::new("writer"),
                rows: 24,
                cols,
                rendering: true,
            });
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        }

        // Poll the authoritative screen until the cursor's row holds a prompt
        // again. A bare zsh prompt ends in "% ", so the row the cursor sits on
        // must contain a '%' once the storm settles.
        let prompt_deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut last_row = String::new();
        loop {
            assert!(
                tokio::time::Instant::now() < prompt_deadline,
                "prompt never came back after the storm; cursor row: {last_row:?}"
            );
            handle.send(SessionMsg::ResendSnapshot {
                id: ClientId::new("writer"),
            });
            let snapshot_deadline =
                tokio::time::Instant::now() + std::time::Duration::from_millis(900);
            let snapshot = loop {
                match tokio::time::timeout_at(snapshot_deadline, client_rx.recv()).await {
                    Ok(Some(ClientEvent::Snapshot(snapshot))) => break Some(snapshot),
                    Ok(Some(_)) => continue,
                    Ok(None) => panic!("client stream ended"),
                    Err(_) => break None,
                }
            };
            let Some(snapshot) = snapshot else { continue };
            // The attach's own snapshot (and any captured mid-storm) still
            // carries an earlier width; only the settled grid answers the
            // question.
            if snapshot.cols != 40 {
                continue;
            }
            let row_start = usize::from(snapshot.cursor_y) * usize::from(snapshot.cols);
            let row_end = row_start + usize::from(snapshot.cols);
            last_row = snapshot.cells[row_start..row_end.min(snapshot.cells.len())]
                .iter()
                .map(|cell| char::from_u32(cell.codepoint).unwrap_or(' '))
                .collect();
            if last_row.contains('%') {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        }

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
        let _ = std::fs::remove_dir_all(&home);
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

    /// A session handed over with a ring that cannot draw its screen comes
    /// back with a *live* VT that answers snapshots. Declaring it stale was
    /// permanent, and the sentence outlived the crime: the VT eats every byte
    /// from the replay onward, so within one repaint it describes the real
    /// screen — while the stale path kept smearing raw ring replays over
    /// whatever each reattaching client still showed, for the rest of the
    /// image's life. The screen's unknowable rows are handled by the nudge
    /// (`a_knowingly_wrong_replay_nudges_the_foreground_to_repaint`), not by
    /// going dark.
    #[tokio::test]
    async fn an_unfaithful_ring_comes_back_with_a_vt_that_answers_snapshots() {
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

        // A snapshot-capable viewer gets a real snapshot, not the fallback.
        let (client_tx, mut client_rx) = mpsc::unbounded_channel();
        let (reply, answer) = oneshot::channel();
        adopted.send(SessionMsg::AddClient {
            id: ClientId::new("viewer"),
            interactive: true,
            rows: 40,
            cols: 120,
            rendering: true,
            out: client_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: true,
            scrollback: false,
            grid_diff: false,
            vt_stream: false,
            vt_answers: false,
            vt_resume: false,
            resume: None,
            answers: None,
            reply,
        });
        answer.await.expect("attached to the adopted session");
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                match client_rx.recv().await {
                    Some(ClientEvent::Snapshot(_)) => return,
                    Some(_) => continue,
                    None => panic!("client stream ended before a snapshot"),
                }
            }
        })
        .await
        .expect("the adopted session answered a snapshot");

        // And nothing declared the VT stale along the way.
        while let Ok(event) = events_rx.try_recv() {
            assert!(
                !matches!(event, Event::VtStale { .. }),
                "the adopted session must not declare its VT stale"
            );
        }

        adopted.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
    }

    /// A screen adopted with an unfaithful ring must not sit wrong until the
    /// program happens to print. An idle program never does, and a viewer at
    /// the session's own size gets no resize to force a repaint either — so
    /// the adoption itself nudges the foreground with the SIGWINCH a resize
    /// would have delivered, and the repaint arrives as fresh output that
    /// corrects the VT and every attachment at once.
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
            rendering: true,
            out: ready_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: false,
            scrollback: false,
            grid_diff: false,
            vt_stream: false,
            vt_answers: false,
            vt_resume: false,
            resume: None,
            answers: None,
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
        let (events, events_rx) = broadcast::channel(64);
        let adopted = super::adopt(carried.info, Vec::new(), on_exit, events)
            .expect("adopting the carried session");
        drop(events_rx);

        // Attach at the session's own size, on the raw plane so the child's
        // repaint arrives as bytes: no resize fires, so without the adopt-time
        // nudge nothing would ever repaint this screen.
        let (client_tx, mut client_rx) = mpsc::unbounded_channel();
        let (reply, answer) = oneshot::channel();
        adopted.send(SessionMsg::AddClient {
            id: ClientId::new("viewer"),
            interactive: true,
            rows: 24,
            cols: 80,
            rendering: true,
            out: client_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: false,
            scrollback: false,
            grid_diff: false,
            vt_stream: false,
            vt_answers: false,
            vt_resume: false,
            resume: None,
            answers: None,
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
    /// more SIGWINCH to the foreground: the child's answer to the resize
    /// raced the grid change, and its post-settle repaint is the only thing
    /// that can overwrite whatever the race painted — for a shell, that
    /// includes the prompt `resize_for_shell` blanked after the shell had
    /// already redrawn it. The child counts the signals — the resize's own
    /// ioctl delivers the first, the settle nudge the second.
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
            rendering: true,
            out: client_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: false,
            scrollback: false,
            grid_diff: false,
            vt_stream: false,
            vt_answers: false,
            vt_resume: false,
            resume: None,
            answers: None,
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
            rendering: true,
            out: client_tx,
            backlog: Arc::new(ClientBacklog::new()),
            snapshot: false,
            scrollback: false,
            grid_diff: false,
            vt_stream: false,
            vt_answers: false,
            vt_resume: false,
            resume: None,
            answers: None,
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

    /// A child that closes its PTY but is not reapable yet must not take the
    /// actor's mailbox with it: the daemon's `list` waits on every session's
    /// `Info` with no deadline, so one silent actor hangs the whole host.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn a_session_waiting_on_its_reap_still_answers_info() {
        let (on_exit, mut on_exit_rx) = mpsc::unbounded_channel();
        let (events, _events_rx) = broadcast::channel(64);
        // A session leader's controlling terminal keeps the tty open on its
        // own, so closing stdio is not enough. `revoke(2)` (syscall 56 on
        // macOS) cuts every reference to the terminal, the master reads EOF,
        // and the child sleeps on: a PTY that is gone, a child that is not.
        let script = r#"use POSIX; $SIG{HUP}="IGNORE"; syscall(56, POSIX::ttyname(0)); close STDIN; close STDOUT; close STDERR; sleep 60"#.to_string();
        let handle = super::spawn(
            SessionId::new("reap-pending-session"),
            "test".to_string(),
            "/".to_string(),
            script.clone(),
            vec!["/usr/bin/perl".to_string(), "-e".to_string(), script],
            Vec::new(),
            24,
            80,
            None,
            on_exit,
            events,
        )
        .expect("spawning a real session");

        // The child closes the PTY at once and then sleeps until the `Kill`
        // below, so the actor is waiting on the reap for as long as the test
        // needs. Every ask in that window must come back promptly.
        let started = std::time::Instant::now();
        loop {
            let (tx, rx) = oneshot::channel();
            assert!(handle.send(SessionMsg::Info { reply: tx }));
            let info = tokio::time::timeout(std::time::Duration::from_secs(1), rx)
                .await
                .expect("the actor answered Info")
                .expect("session info");
            if !info.alive {
                break;
            }
            assert!(
                started.elapsed() < std::time::Duration::from_secs(2),
                "the PTY never closed while the child was still running"
            );
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
        let ended = tokio::time::timeout(std::time::Duration::from_secs(2), on_exit_rx.recv())
            .await
            .expect("a kill during the reap ended the session")
            .expect("session ended");
        assert_eq!(ended.reason, EndReason::Killed);
    }

    /// A session nobody named a project for — a shell started by hand on this
    /// box — still groups under the checkout its child is standing in. The
    /// repo root, found by walking up to `.git`, is what a directly attached
    /// phone files the row under; without it every hand-started session lands
    /// in the loose Terminals bucket.
    #[tokio::test]
    async fn a_hand_started_session_reports_the_checkout_it_stands_in() {
        let cat = ["/bin/cat", "/usr/bin/cat"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no cat binary on this host");
        let scratch = std::fs::canonicalize(std::env::temp_dir())
            .expect("canonical temp dir")
            .join(format!("termiod-project-root-{}", std::process::id()));
        let checkout = scratch.join("checkout");
        let nested = checkout.join("src");
        std::fs::create_dir_all(&nested).expect("scratch tree");
        std::fs::create_dir_all(checkout.join(".git")).expect("git dir");

        let (handle, _events_rx, _on_exit) = start_session(
            vec![cat.to_string()],
            nested.to_str().expect("utf-8 path"),
        );

        let info = settled_info(&handle, |info| info.project.is_some()).await;
        assert_eq!(info.project.as_deref(), checkout.to_str());

        handle.send(SessionMsg::Kill {
            reason: EndReason::Killed,
        });
        std::fs::remove_dir_all(&scratch).expect("scratch cleanup");
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
