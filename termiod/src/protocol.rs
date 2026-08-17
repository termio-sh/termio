//! Session Protocol v0.1 — the wire contract between clients and `termiod`.
//!
//! Framing is frozen from v0:
//!
//! ```text
//! [ kind: u8 ][ len: u32 big-endian ][ payload: len bytes ]
//! ```
//!
//! Control and event payloads are JSON. PTY data stays raw and resize stays a
//! four-byte binary payload, so v0 clients remain byte-compatible.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub const KIND_CONTROL: u8 = b'C';
pub const KIND_DATA: u8 = b'D';
pub const KIND_RESIZE: u8 = b'R';
pub const KIND_EVENT: u8 = b'E';
pub const KIND_SNAPSHOT: u8 = b'S';
pub const KIND_HISTORY: u8 = b'H';
pub const KIND_GRID: u8 = b'G';
pub const KIND_FILE: u8 = b'F';
pub const KIND_UPLOAD: u8 = b'U';

pub const MAX_FRAME_SIZE: usize = 16 * 1024 * 1024;
pub const MAX_DATA_FRAME_SIZE: usize = 64 * 1024;
pub const PROTOCOL_VERSION: u32 = 1;
pub const SUPPORTED_PROTOCOLS: &[u32] = &[PROTOCOL_VERSION];
pub const HOST_CAPABILITIES: &[&str] = &[
    "events",
    "send_wait",
    "snapshot",
    "scrollback",
    "grid_diff",
    "resources",
    "fs_watch",
    "files",
    "upload",
    "git",
];
pub const SNAPSHOT_FORMAT_VERSION: u8 = 1;
/// Snapshot payload carrying **VT sequences** instead of packed cells.
///
/// This is the correct shape for the raw plane: the host says *what is on the
/// screen* in the terminal's own language and the client's libghostty decides
/// how it looks. Packed cells (v1) force the host to resolve colour, which
/// overrides the viewer's theme and silently drops bold/underline/OSC 8. v1 is
/// retained only for `grid_diff` clients, whose whole model is server-side
/// state and which need cells to seed their grid.
pub const SNAPSHOT_FORMAT_VT: u8 = 2;
pub const SNAPSHOT_CELL_SIZE: usize = 16;
pub const HISTORY_FORMAT_VERSION: u8 = 1;
pub const HISTORY_HEADER_SIZE: usize = 9;
pub const MAX_HISTORY_FRAME_SIZE: usize = 64 * 1024;
pub const GRID_FORMAT_VERSION: u8 = 1;
pub const GRID_HEADER_SIZE: usize = 16;
/// `F` chunk header: request id (u64be), offset (u64be), last flag (u8).
pub const FILE_CHUNK_HEADER_SIZE: usize = 17;
/// Whole-frame cap for `F`, matching the `D`/`H` fair-write chunk size so a
/// file read never parks a keystroke behind more than one chunk on a shared
/// pipe (§C.12 head-of-line discipline).
pub const MAX_FILE_FRAME_SIZE: usize = 64 * 1024;
/// Whole-frame cap for `U` upload chunks — the same one-chunk bound: with
/// credit-of-one acks, a keystroke on a shared pipe waits behind at most one
/// of these (§C.12 head-of-line discipline).
pub const MAX_UPLOAD_FRAME_SIZE: usize = 64 * 1024;

/// A single decoded frame off the wire.
#[derive(Debug)]
pub enum Frame {
    Control(Control),
    Data(Vec<u8>),
    Resize { rows: u16, cols: u16 },
    Event(Event),
    Snapshot(Snapshot),
    History(HistoryChunk),
    Grid(GridDiff),
    // The daemon only ever rejects an inbound F frame; the chunk body is for
    // protocol clients (the CLI reads it when file verbs land there).
    #[allow(dead_code)]
    File(FileChunk),
    Upload(UploadChunk),
}

/// One `U` frame of upload content (§C.12), client → host only. The daemon
/// answers each with `upload_ack`; credit-of-one means the client holds the
/// next chunk until that ack arrives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadChunk {
    pub upload_id: String,
    pub offset: u64,
    pub data: Vec<u8>,
}

/// One `F` frame of `fs.read` content (§C.12), host → client only. `re` ties
/// the chunk back to the `fs_read` request whose `fs_file` reply preceded it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileChunk {
    pub re: u64,
    pub offset: u64,
    pub last: bool,
    pub data: Vec<u8>,
}

/// Engine-independent 16-byte cell representation used by snapshot v1.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WireCell {
    pub codepoint: u32,
    pub foreground: [u8; 3],
    pub background: [u8; 3],
    pub attributes: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    /// VT-sequence repaint (format v2). When set, `cells` is empty and the
    /// client feeds these bytes straight into its own terminal.
    pub vt: Option<Vec<u8>>,
    pub rows: u16,
    pub cols: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub alt_screen: bool,
    pub title: String,
    pub cells: Vec<WireCell>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryChunk {
    pub cols: u16,
    /// Distance above the snapshot viewport of this chunk's first row.
    pub first_offset: u32,
    pub row_count: u16,
    /// Row-major cells, with rows ordered from newer to older.
    pub cells: Vec<WireCell>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GridRow {
    pub row_index: u16,
    pub cells: Vec<WireCell>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GridDiff {
    pub frame_seq: u32,
    pub rows: u16,
    pub cols: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub alt_screen: bool,
    pub dirty_rows: Vec<GridRow>,
}

/// What a directory entry is, as far as the tree needs to know (§C.12).
/// `unloaded_dir` marks a directory the host will never walk on its own
/// (VCS internals today); a client may still list it explicitly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    File,
    Dir,
    Symlink,
    UnloadedDir,
}

/// One row of an `fs.list` page.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirEntry {
    pub name: String,
    pub kind: EntryKind,
    pub size: u64,
    /// Seconds since the Unix epoch; 0 when the filesystem cannot say.
    pub mtime: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symlink_target: Option<String>,
}

/// The listing for one requested path inside an `fs_listed` reply. A path
/// that vanished or escapes the root fails alone (`error`), so a batched
/// speculative request is never all-or-nothing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PathListing {
    pub path: String,
    #[serde(default)]
    pub entries: Vec<DirEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_page: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// One axis of a tracked file's two-axis status (§C.13). The vocabulary is
/// adopted from Zed verbatim — battle-tested and 1:1 with the
/// GitHub-Desktop-shaped changes pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitStatusCode {
    Unmodified,
    Modified,
    TypeChanged,
    Added,
    Deleted,
    Renamed,
    Copied,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitUnmergedCode {
    Updated,
    Added,
    Deleted,
}

/// A file's git status (§C.13): two axes for tracked files, plus
/// `untracked | ignored | unmerged {first_head, second_head}` with the
/// merge-conflict path set first-class.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitFileStatus {
    Untracked,
    Ignored,
    Tracked {
        index_status: GitStatusCode,
        worktree_status: GitStatusCode,
    },
    Unmerged {
        first_head: GitUnmergedCode,
        second_head: GitUnmergedCode,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitStatusEntry {
    pub path: String,
    pub status: GitFileStatus,
}

/// One `fs.search` hit (§C.12): workspace-relative path, 1-based line, the
/// matching line's text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchMatch {
    pub path: String,
    pub line: u64,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChannelRole {
    Control,
    Attach,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttachMode {
    #[default]
    Interact,
    Observe,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    Incompatible,
    ProtoError,
    NoSuchSession,
    NotWriter,
    AlreadyExited,
    CreateFailed,
    Denied,
    Busy,
    #[default]
    Internal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkstreamSpec {
    pub agent_id: String,
    pub project: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
}

/// How to spawn a session's process.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateSpec {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    /// argv[0] is the program. Empty ⇒ the daemon picks the login shell.
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub env: Vec<(String, String)>,
    #[serde(default = "default_rows")]
    pub rows: u16,
    #[serde(default = "default_cols")]
    pub cols: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workstream: Option<WorkstreamSpec>,
}

fn default_rows() -> u16 {
    24
}

fn default_cols() -> u16 {
    80
}

impl Default for CreateSpec {
    fn default() -> Self {
        CreateSpec {
            name: None,
            cwd: None,
            argv: Vec::new(),
            env: Vec::new(),
            rows: default_rows(),
            cols: default_cols(),
            workstream: None,
        }
    }
}

/// Control-plane messages. `op` tags the variant on the wire.
///
/// Optional `seq`/`re` fields are omitted when absent, preserving the exact v0
/// shapes. Unknown operations deserialize to `Unknown` and are ignored.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Control {
    // Handshake.
    Hello {
        proto: u32,
        min_proto: u32,
        role: ChannelRole,
        #[serde(default)]
        caps: Vec<String>,
        client: String,
    },
    HelloOk {
        proto: u32,
        #[serde(default)]
        caps: Vec<String>,
        host_id: String,
        host: String,
        client_id: String,
    },
    HelloErr {
        code: ErrorCode,
        supported: Vec<u32>,
    },

    // Client → daemon requests.
    Create {
        #[serde(flatten)]
        spec: CreateSpec,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    List {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Kill {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Send {
        id: String,
        data: Vec<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Attach {
        /// Session id or name to attach to.
        target: String,
        /// If the target does not exist, create it with this spec.
        #[serde(default)]
        create_if_missing: Option<CreateSpec>,
        rows: u16,
        cols: u16,
        #[serde(default)]
        mode: AttachMode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Client asks to leave the stream but keep the session alive.
    Detach {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Subscribe {
        events: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Resumable subscription to a durable host resource (§C.10). `since` is
    /// the highest `seq` the client has already applied; omit it on a first
    /// subscribe. Requires the `resources` capability.
    SubscribeResource {
        resource: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        since: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    UnsubscribeResource {
        resource: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// List directories under a workspace root (§C.12, capability `files`).
    /// Batched and speculative: a client SHOULD name a rendered directory
    /// together with its visible child dirs. `page` continues one path's
    /// listing past the per-page entry cap.
    FsList {
        root: String,
        paths: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        page: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Read a file (§C.12, capability `files`). The reply is one `fs_file`
    /// header followed by `F` chunks. Without a range the read is capped at
    /// the 1 MiB preview budget; `offset`/`length` window the file for the
    /// editor later.
    FsRead {
        path: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        offset: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        length: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Open an upload (§C.12, capability `upload`). `dest` is either a path
    /// under `root` (which must then be present) or `temp:<name>` with
    /// `session` naming whose scratch dir receives it. Re-opening with the
    /// same dest, size, and sha256 is idempotent: same id, restarted from 0
    /// (no resume in v1).
    UploadOpen {
        dest: String,
        size: u64,
        sha256: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mode: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        root: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Content search (§C.12, capability `files`): the host runs `git grep`
    /// and streams `search_results` events tagged with this request's `seq`,
    /// then closes with one `fs_searched` reply. Cancellable mid-stream with
    /// `cancel {request: <seq>}`.
    FsSearch {
        root: String,
        query: String,
        limit: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Cancel an in-flight cancellable request on this channel by its request
    /// id (§C.12 — the ⇧⌘F escape hatch). Idempotent: cancelling what
    /// already finished is `ok`, not an error.
    Cancel {
        request: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// The `git:` kind's one verb (§C.13, capability `git`): a unified diff
    /// for one path, rendered client-side. Read-only by design — no
    /// stage/commit/push verbs; the user commits in the terminal, which is
    /// the same app.
    GitDiff {
        root: String,
        path: String,
        #[serde(default)]
        staged: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Fuzzy filename lookup against the host-side name index (§C.12,
    /// capability `files`). The index is built lazily after the workspace's
    /// first `subscribe_resource` and kept incremental by the watcher, so
    /// replies carry `coverage` — a client shows "still indexing" instead of
    /// silently missing files.
    FsMatch {
        root: String,
        query: String,
        limit: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    UploadCommit {
        upload_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    UploadAbort {
        upload_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    Wait {
        target: String,
        until: Vec<String>,
        timeout_ms: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    SetStatus {
        id: String,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },

    // Daemon → client responses.
    Ok {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    Created {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    Sessions {
        sessions: Vec<SessionInfo>,
        /// Sessions that have died, newest first (§6). Sent with the live list
        /// rather than behind a second verb because the question a client is
        /// asking — "what is running?" — has a wrong answer when a daemon crash
        /// silently turned it into an empty list. Additive: a client that does
        /// not know the field ignores it.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        tombstones: Vec<crate::tombstone::Tombstone>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    Attached {
        /// v0 response field, retained for byte compatibility.
        id: String,
        name: String,
        /// Canonical v0.1 field.
        #[serde(default)]
        session_id: String,
        #[serde(default)]
        writer: bool,
        #[serde(default = "default_rows")]
        rows: u16,
        #[serde(default = "default_cols")]
        cols: u16,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `subscribe_resource`. `seq` is the resource's current cursor —
    /// what to pass back as `since` after a reconnect. `gap` means the client's
    /// baseline is unusable and it must do a full scan before applying further
    /// events (a first subscribe, or a `since` that aged out of the ring).
    /// Replayed batches arrive as events *after* this reply, in seq order.
    Subscribed {
        resource: String,
        seq: u64,
        #[serde(default)]
        gap: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `fs_list`. `seq` is the `fs:` resource's current cursor at
    /// listing time — the freshness proof that lets clients cache listings
    /// until an `fs_changed` batch names the directory (0 when no watch is
    /// running, i.e. nothing will invalidate the cache).
    FsListed {
        seq: u64,
        listings: Vec<PathListing>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply header for `fs_read`: `length` bytes from `offset` follow as `F`
    /// chunks. `truncated` means the served window stopped short of what was
    /// asked (the 1 MiB soft cap); `size` lets the client ask for the rest.
    FsFile {
        size: u64,
        offset: u64,
        length: u64,
        #[serde(default)]
        truncated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Terminal reply to `fs_search`, sent after the last `search_results`
    /// event: how many matches streamed and why the stream ended.
    FsSearched {
        matches: u64,
        #[serde(default)]
        limit_hit: bool,
        #[serde(default)]
        canceled: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `git_diff`. `truncated` marks a diff cut at the 1 MiB cap.
    GitDiffResult {
        diff: String,
        #[serde(default)]
        truncated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `fs_match`: workspace-relative paths, best first. `coverage`
    /// is how much of the tree the index has walked (0.0–1.0); the index is
    /// evictable state, never correctness-bearing.
    FsMatched {
        paths: Vec<String>,
        coverage: f32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `upload_open`. `offset` is where the next chunk should start:
    /// 0 for a fresh upload, and the bytes already landed when this open
    /// resumed one the daemon still holds. Purely additive — a client that
    /// ignores the field starts at 0, which the daemon reads as "restart" and
    /// serves by rewinding, exactly as it did before resume existed.
    UploadOpened {
        upload_id: String,
        #[serde(default)]
        offset: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Credit-of-one grant: `offset` is the total received so far — the next
    /// chunk the host expects. The client sends chunk N+1 only after the ack
    /// for chunk N, which bounds a keystroke's wait on a shared pipe to one
    /// chunk (§C.12).
    UploadAck { upload_id: String, offset: u64 },
    UploadCommitted {
        path: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Sent when the attached session's process exits (retained for v0).
    Exited { id: String, status: i32 },
    WaitResult {
        session: String,
        status: String,
        #[serde(default)]
        timed_out: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit_status: Option<i32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    ResizeClaim {
        session: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        writer: Option<String>,
    },
    Error {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
        #[serde(default)]
        code: ErrorCode,
        message: String,
        #[serde(default)]
        retryable: bool,
    },

    #[serde(other)]
    Unknown,
}

impl Control {
    pub fn seq(&self) -> Option<u64> {
        match self {
            Control::Create { seq, .. }
            | Control::List { seq }
            | Control::Kill { seq, .. }
            | Control::Send { seq, .. }
            | Control::Attach { seq, .. }
            | Control::Detach { seq }
            | Control::Subscribe { seq, .. }
            | Control::SubscribeResource { seq, .. }
            | Control::UnsubscribeResource { seq, .. }
            | Control::FsList { seq, .. }
            | Control::FsRead { seq, .. }
            | Control::FsMatch { seq, .. }
            | Control::FsSearch { seq, .. }
            | Control::Cancel { seq, .. }
            | Control::GitDiff { seq, .. }
            | Control::UploadOpen { seq, .. }
            | Control::UploadCommit { seq, .. }
            | Control::UploadAbort { seq, .. }
            | Control::Wait { seq, .. }
            | Control::SetStatus { seq, .. } => *seq,
            _ => None,
        }
    }
}

/// Event-plane messages. Unknown event types are ignored additively.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "ev", rename_all = "snake_case")]
pub enum Event {
    Ready {
        session: String,
    },
    Status {
        session: String,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    WriterChanged {
        session: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        writer: Option<String>,
    },
    Resized {
        session: String,
        rows: u16,
        cols: u16,
    },
    SessionExited {
        session: String,
        status: i32,
    },
    /// This attachment's stream was cut and restarted at a fresh boundary. It
    /// arrives after the `S`/`ready` pair that re-establishes JOIN, and it means
    /// the bytes between the previous boundary and this one were never
    /// delivered — the screen is right, but nothing scrolled past is recoverable.
    Resynced {
        session: String,
        reason: String,
    },
    /// The host's VT no longer describes any boundary in this session's output,
    /// so it can no longer answer a snapshot. Attach and resync fall back to
    /// ring replay, which can open mid-escape.
    VtStale {
        session: String,
        reason: String,
    },
    /// A filesystem batch for an `fs:` resource (§C.10). `seq` is monotonic per
    /// resource and is what a reconnecting client passes back as `since`.
    /// `full_rescan` means the path set is not authoritative — re-walk what is
    /// realized. `git_meta` means index/HEAD/refs moved; object-store churn is
    /// dropped host-side and never appears here.
    FsChanged {
        resource: String,
        seq: u64,
        #[serde(default)]
        paths: Vec<String>,
        #[serde(default)]
        full_rescan: bool,
        #[serde(default)]
        git_meta: bool,
    },
    /// A batch of `fs.search` hits (§C.12), addressed to the requesting
    /// connection alone. `request` echoes the `fs_search` seq so several
    /// searches can share one channel.
    SearchResults {
        request: u64,
        matches: Vec<SearchMatch>,
    },
    /// A status delta for a `git:` resource (§C.13) — the second consumer of
    /// §C.10's one mechanism. `updated_statuses` and `removed_paths` are a
    /// delta against the subscriber's baseline; branch metadata rides along
    /// whole so clients never merge it.
    GitChanged {
        resource: String,
        seq: u64,
        #[serde(default)]
        updated_statuses: Vec<GitStatusEntry>,
        #[serde(default)]
        removed_paths: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        branch: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        head: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ahead_behind: Option<(u32, u32)>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflicts: Vec<String>,
    },
    /// Roster delta used by control-channel `subscribe`.
    Roster {
        session: String,
        action: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        info: Option<Box<SessionInfo>>,
    },
    #[serde(other)]
    Unknown,
}

/// A row in `termiod list`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub name: String,
    pub cwd: String,
    pub command: String,
    pub pid: i32,
    pub rows: u16,
    pub cols: u16,
    /// v0 field retained for old consumers.
    pub clients: usize,
    pub created_unix: u64,
    pub alive: bool,
    #[serde(default = "default_status")]
    pub status: String,
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub attached_clients: usize,
    #[serde(default)]
    pub writer_client_id: Option<String>,
}

fn default_status() -> String {
    "unknown".to_string()
}

pub async fn write_frame<W: AsyncWriteExt + Unpin>(
    w: &mut W,
    kind: u8,
    payload: &[u8],
) -> Result<()> {
    if payload.len() > MAX_FRAME_SIZE {
        bail!(
            "frame payload too large: {} > {MAX_FRAME_SIZE}",
            payload.len()
        );
    }
    let mut header = [0u8; 5];
    header[0] = kind;
    header[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    w.write_all(&header).await?;
    w.write_all(payload).await?;
    w.flush().await?;
    Ok(())
}

pub async fn write_control<W: AsyncWriteExt + Unpin>(w: &mut W, msg: &Control) -> Result<()> {
    let payload = serde_json::to_vec(msg)?;
    write_frame(w, KIND_CONTROL, &payload).await
}

pub async fn write_event<W: AsyncWriteExt + Unpin>(w: &mut W, event: &Event) -> Result<()> {
    let payload = serde_json::to_vec(event)?;
    write_frame(w, KIND_EVENT, &payload).await
}

pub async fn write_snapshot<W: AsyncWriteExt + Unpin>(
    w: &mut W,
    snapshot: &Snapshot,
) -> Result<()> {
    let payload = encode_snapshot_payload(snapshot)?;
    write_frame(w, KIND_SNAPSHOT, &payload).await
}

pub async fn write_history_payload<W: AsyncWriteExt + Unpin>(
    w: &mut W,
    payload: &[u8],
) -> Result<()> {
    if payload.len() > MAX_HISTORY_FRAME_SIZE {
        bail!(
            "history payload too large: {} > {MAX_HISTORY_FRAME_SIZE}",
            payload.len()
        );
    }
    write_frame(w, KIND_HISTORY, payload).await
}

pub async fn write_grid_payload<W: AsyncWriteExt + Unpin>(w: &mut W, payload: &[u8]) -> Result<()> {
    write_frame(w, KIND_GRID, payload).await
}

pub async fn write_file_payload<W: AsyncWriteExt + Unpin>(w: &mut W, payload: &[u8]) -> Result<()> {
    if payload.len() > MAX_FILE_FRAME_SIZE {
        bail!(
            "file payload too large: {} > {MAX_FILE_FRAME_SIZE}",
            payload.len()
        );
    }
    write_frame(w, KIND_FILE, payload).await
}

/// File-chunk payload: re:u64be, offset:u64be, last:u8, then the bytes.
pub fn encode_file_chunk(chunk: &FileChunk) -> Result<Vec<u8>> {
    let payload_len = FILE_CHUNK_HEADER_SIZE
        .checked_add(chunk.data.len())
        .ok_or_else(|| anyhow::anyhow!("file chunk length overflow"))?;
    if payload_len > MAX_FILE_FRAME_SIZE {
        bail!("file payload too large: {payload_len} > {MAX_FILE_FRAME_SIZE}");
    }
    let mut payload = Vec::with_capacity(payload_len);
    payload.extend_from_slice(&chunk.re.to_be_bytes());
    payload.extend_from_slice(&chunk.offset.to_be_bytes());
    payload.push(u8::from(chunk.last));
    payload.extend_from_slice(&chunk.data);
    Ok(payload)
}

/// Upload-chunk payload: id_len:u8, upload id, offset:u64be, then the bytes.
/// The sending side of `U` — the daemon only decodes; this is for protocol
/// clients and the codec tests.
#[allow(dead_code)]
pub fn encode_upload_chunk(chunk: &UploadChunk) -> Result<Vec<u8>> {
    let id = chunk.upload_id.as_bytes();
    let id_len =
        u8::try_from(id.len()).map_err(|_| anyhow::anyhow!("upload id too long"))?;
    if id.is_empty() {
        bail!("upload id must not be empty");
    }
    let payload_len = 1 + id.len() + 8 + chunk.data.len();
    if payload_len > MAX_UPLOAD_FRAME_SIZE {
        bail!("upload payload too large: {payload_len} > {MAX_UPLOAD_FRAME_SIZE}");
    }
    let mut payload = Vec::with_capacity(payload_len);
    payload.push(id_len);
    payload.extend_from_slice(id);
    payload.extend_from_slice(&chunk.offset.to_be_bytes());
    payload.extend_from_slice(&chunk.data);
    Ok(payload)
}

pub fn decode_upload_chunk(payload: &[u8]) -> Result<UploadChunk> {
    if payload.len() > MAX_UPLOAD_FRAME_SIZE {
        bail!(
            "upload payload too large: {} > {MAX_UPLOAD_FRAME_SIZE}",
            payload.len()
        );
    }
    let Some((&id_len, rest)) = payload.split_first() else {
        bail!("malformed upload chunk header");
    };
    let id_len = usize::from(id_len);
    if id_len == 0 || rest.len() < id_len + 8 {
        bail!("malformed upload chunk header");
    }
    let upload_id = std::str::from_utf8(&rest[..id_len])
        .map_err(|error| anyhow::anyhow!("upload id is not UTF-8: {error}"))?
        .to_string();
    let offset = u64::from_be_bytes(rest[id_len..id_len + 8].try_into().expect("sized slice"));
    Ok(UploadChunk {
        upload_id,
        offset,
        data: rest[id_len + 8..].to_vec(),
    })
}

pub fn decode_file_chunk(payload: &[u8]) -> Result<FileChunk> {
    if payload.len() < FILE_CHUNK_HEADER_SIZE {
        bail!("malformed file chunk header");
    }
    if payload.len() > MAX_FILE_FRAME_SIZE {
        bail!(
            "file payload too large: {} > {MAX_FILE_FRAME_SIZE}",
            payload.len()
        );
    }
    let re = u64::from_be_bytes(payload[0..8].try_into().expect("sized slice"));
    let offset = u64::from_be_bytes(payload[8..16].try_into().expect("sized slice"));
    let last = match payload[16] {
        0 => false,
        1 => true,
        other => bail!("invalid file chunk last flag {other}"),
    };
    Ok(FileChunk {
        re,
        offset,
        last,
        data: payload[FILE_CHUNK_HEADER_SIZE..].to_vec(),
    })
}

/// Snapshot payload v1:
/// version:u8, rows/cols/cursor_x/cursor_y:u16be, alt_screen:u8,
/// title_len:u16be, UTF-8 title, then row-major 16-byte cells. Each cell is
/// codepoint:u32be, foreground RGB, background RGB, attributes:u16be, and
/// four reserved zero bytes.
pub fn encode_snapshot_payload(snapshot: &Snapshot) -> Result<Vec<u8>> {
    let vt = snapshot.vt.as_deref();
    let expected_cells = usize::from(snapshot.rows) * usize::from(snapshot.cols);
    if vt.is_none() && snapshot.cells.len() != expected_cells {
        bail!(
            "snapshot has {} cells, expected {expected_cells}",
            snapshot.cells.len()
        );
    }
    let title = snapshot.title.as_bytes();
    let title_len =
        u16::try_from(title.len()).map_err(|_| anyhow::anyhow!("snapshot title too long"))?;
    let body_len = match vt {
        Some(bytes) => 4 + bytes.len(),
        None => expected_cells * SNAPSHOT_CELL_SIZE,
    };
    let payload_len = 12usize
        .checked_add(title.len())
        .and_then(|len| len.checked_add(body_len))
        .ok_or_else(|| anyhow::anyhow!("snapshot payload length overflow"))?;
    if payload_len > MAX_FRAME_SIZE {
        bail!("snapshot payload too large: {payload_len} > {MAX_FRAME_SIZE}");
    }

    let mut payload = Vec::with_capacity(payload_len);
    payload.push(if vt.is_some() {
        SNAPSHOT_FORMAT_VT
    } else {
        SNAPSHOT_FORMAT_VERSION
    });
    payload.extend_from_slice(&snapshot.rows.to_be_bytes());
    payload.extend_from_slice(&snapshot.cols.to_be_bytes());
    payload.extend_from_slice(&snapshot.cursor_x.to_be_bytes());
    payload.extend_from_slice(&snapshot.cursor_y.to_be_bytes());
    payload.push(u8::from(snapshot.alt_screen));
    payload.extend_from_slice(&title_len.to_be_bytes());
    payload.extend_from_slice(title);
    match vt {
        Some(bytes) => {
            let len = u32::try_from(bytes.len())
                .map_err(|_| anyhow::anyhow!("snapshot vt payload too long"))?;
            payload.extend_from_slice(&len.to_be_bytes());
            payload.extend_from_slice(bytes);
        }
        None => encode_cells(&mut payload, &snapshot.cells),
    }
    Ok(payload)
}

pub fn decode_snapshot_payload(payload: &[u8]) -> Result<Snapshot> {
    if payload.len() < 12 {
        bail!("malformed snapshot header");
    }
    let is_vt = match payload[0] {
        SNAPSHOT_FORMAT_VERSION => false,
        SNAPSHOT_FORMAT_VT => true,
        other => bail!("unsupported snapshot payload version {other}"),
    };
    let rows = u16::from_be_bytes([payload[1], payload[2]]);
    let cols = u16::from_be_bytes([payload[3], payload[4]]);
    let cursor_x = u16::from_be_bytes([payload[5], payload[6]]);
    let cursor_y = u16::from_be_bytes([payload[7], payload[8]]);
    let alt_screen = match payload[9] {
        0 => false,
        1 => true,
        other => bail!("invalid snapshot alt-screen value {other}"),
    };
    let title_len = usize::from(u16::from_be_bytes([payload[10], payload[11]]));
    let cells_offset = 12usize
        .checked_add(title_len)
        .ok_or_else(|| anyhow::anyhow!("snapshot title length overflow"))?;
    if cells_offset > payload.len() {
        bail!("snapshot title exceeds payload");
    }
    let title = std::str::from_utf8(&payload[12..cells_offset])
        .map_err(|error| anyhow::anyhow!("snapshot title is not UTF-8: {error}"))?
        .to_string();
    if is_vt {
        let body = &payload[cells_offset..];
        if body.len() < 4 {
            bail!("malformed snapshot vt length");
        }
        let vt_len = u32::from_be_bytes([body[0], body[1], body[2], body[3]]) as usize;
        if body.len() != 4 + vt_len {
            bail!(
                "snapshot vt payload has {} bytes, expected {}",
                body.len() - 4,
                vt_len
            );
        }
        return Ok(Snapshot {
            rows,
            cols,
            cursor_x,
            cursor_y,
            alt_screen,
            title,
            cells: Vec::new(),
            vt: Some(body[4..].to_vec()),
        });
    }

    let cell_count = usize::from(rows) * usize::from(cols);
    let expected_len = cells_offset
        .checked_add(cell_count * SNAPSHOT_CELL_SIZE)
        .ok_or_else(|| anyhow::anyhow!("snapshot cell length overflow"))?;
    if payload.len() != expected_len {
        bail!(
            "snapshot payload has {} bytes, expected {expected_len}",
            payload.len()
        );
    }

    let cells = decode_cells(&payload[cells_offset..]);
    Ok(Snapshot {
        rows,
        cols,
        cursor_x,
        cursor_y,
        alt_screen,
        title,
        cells,
        vt: None,
    })
}

/// Scrollback payload v1: version:u8, cols:u16be, first_offset:u32be,
/// row_count:u16be, then row-major 16-byte wire cells. Rows are newest-first.
pub fn encode_history_payload(history: &HistoryChunk) -> Result<Vec<u8>> {
    if history.cols == 0 || history.row_count == 0 {
        bail!("history chunks require non-zero columns and rows");
    }
    let expected_cells = usize::from(history.cols) * usize::from(history.row_count);
    if history.cells.len() != expected_cells {
        bail!(
            "history chunk has {} cells, expected {expected_cells}",
            history.cells.len()
        );
    }
    let payload_len = HISTORY_HEADER_SIZE
        .checked_add(expected_cells * SNAPSHOT_CELL_SIZE)
        .ok_or_else(|| anyhow::anyhow!("history payload length overflow"))?;
    if payload_len > MAX_HISTORY_FRAME_SIZE {
        bail!("history payload too large: {payload_len} > {MAX_HISTORY_FRAME_SIZE}");
    }

    let mut payload = Vec::with_capacity(payload_len);
    payload.push(HISTORY_FORMAT_VERSION);
    payload.extend_from_slice(&history.cols.to_be_bytes());
    payload.extend_from_slice(&history.first_offset.to_be_bytes());
    payload.extend_from_slice(&history.row_count.to_be_bytes());
    encode_cells(&mut payload, &history.cells);
    Ok(payload)
}

pub fn decode_history_payload(payload: &[u8]) -> Result<HistoryChunk> {
    if payload.len() < HISTORY_HEADER_SIZE {
        bail!("malformed history header");
    }
    if payload.len() > MAX_HISTORY_FRAME_SIZE {
        bail!(
            "history payload too large: {} > {MAX_HISTORY_FRAME_SIZE}",
            payload.len()
        );
    }
    if payload[0] != HISTORY_FORMAT_VERSION {
        bail!("unsupported history payload version {}", payload[0]);
    }
    let cols = u16::from_be_bytes([payload[1], payload[2]]);
    let first_offset = u32::from_be_bytes([payload[3], payload[4], payload[5], payload[6]]);
    let row_count = u16::from_be_bytes([payload[7], payload[8]]);
    if cols == 0 || row_count == 0 {
        bail!("history chunks require non-zero columns and rows");
    }
    let cell_count = usize::from(cols) * usize::from(row_count);
    let expected_len = HISTORY_HEADER_SIZE
        .checked_add(cell_count * SNAPSHOT_CELL_SIZE)
        .ok_or_else(|| anyhow::anyhow!("history cell length overflow"))?;
    if payload.len() != expected_len {
        bail!(
            "history payload has {} bytes, expected {expected_len}",
            payload.len()
        );
    }

    let cells = decode_cells(&payload[HISTORY_HEADER_SIZE..]);
    Ok(HistoryChunk {
        cols,
        first_offset,
        row_count,
        cells,
    })
}

/// Grid-diff payload v1: version:u8, frame_seq:u32be,
/// rows/cols/cursor_x/cursor_y:u16be, alt_screen:u8, row_count:u16be, then
/// row_index:u16be plus `cols` 16-byte wire cells for each dirty row.
pub fn encode_grid_payload(grid: &GridDiff) -> Result<Vec<u8>> {
    if grid.rows == 0 || grid.cols == 0 {
        bail!("grid diffs require non-zero dimensions");
    }
    let row_count = u16::try_from(grid.dirty_rows.len())
        .map_err(|_| anyhow::anyhow!("grid diff has too many dirty rows"))?;
    if row_count == 0 {
        bail!("grid diffs require at least one dirty row");
    }
    let row_bytes = 2usize
        .checked_add(usize::from(grid.cols) * SNAPSHOT_CELL_SIZE)
        .ok_or_else(|| anyhow::anyhow!("grid row length overflow"))?;
    let payload_len = GRID_HEADER_SIZE
        .checked_add(usize::from(row_count) * row_bytes)
        .ok_or_else(|| anyhow::anyhow!("grid payload length overflow"))?;
    if payload_len > MAX_FRAME_SIZE {
        bail!("grid payload too large: {payload_len} > {MAX_FRAME_SIZE}");
    }

    let mut payload = Vec::with_capacity(payload_len);
    payload.push(GRID_FORMAT_VERSION);
    payload.extend_from_slice(&grid.frame_seq.to_be_bytes());
    payload.extend_from_slice(&grid.rows.to_be_bytes());
    payload.extend_from_slice(&grid.cols.to_be_bytes());
    payload.extend_from_slice(&grid.cursor_x.to_be_bytes());
    payload.extend_from_slice(&grid.cursor_y.to_be_bytes());
    payload.push(u8::from(grid.alt_screen));
    payload.extend_from_slice(&row_count.to_be_bytes());
    for row in &grid.dirty_rows {
        if row.row_index >= grid.rows {
            bail!("grid row {} exceeds {} rows", row.row_index, grid.rows);
        }
        if row.cells.len() != usize::from(grid.cols) {
            bail!(
                "grid row {} has {} cells, expected {}",
                row.row_index,
                row.cells.len(),
                grid.cols
            );
        }
        payload.extend_from_slice(&row.row_index.to_be_bytes());
        encode_cells(&mut payload, &row.cells);
    }
    Ok(payload)
}

pub fn decode_grid_payload(payload: &[u8]) -> Result<GridDiff> {
    if payload.len() < GRID_HEADER_SIZE {
        bail!("malformed grid-diff header");
    }
    if payload[0] != GRID_FORMAT_VERSION {
        bail!("unsupported grid-diff payload version {}", payload[0]);
    }
    let frame_seq = u32::from_be_bytes([payload[1], payload[2], payload[3], payload[4]]);
    let rows = u16::from_be_bytes([payload[5], payload[6]]);
    let cols = u16::from_be_bytes([payload[7], payload[8]]);
    let cursor_x = u16::from_be_bytes([payload[9], payload[10]]);
    let cursor_y = u16::from_be_bytes([payload[11], payload[12]]);
    let alt_screen = match payload[13] {
        0 => false,
        1 => true,
        other => bail!("invalid grid-diff alt-screen value {other}"),
    };
    let row_count = u16::from_be_bytes([payload[14], payload[15]]);
    if rows == 0 || cols == 0 || row_count == 0 {
        bail!("grid diffs require non-zero dimensions and dirty rows");
    }
    let row_bytes = 2usize
        .checked_add(usize::from(cols) * SNAPSHOT_CELL_SIZE)
        .ok_or_else(|| anyhow::anyhow!("grid row length overflow"))?;
    let expected_len = GRID_HEADER_SIZE
        .checked_add(usize::from(row_count) * row_bytes)
        .ok_or_else(|| anyhow::anyhow!("grid payload length overflow"))?;
    if payload.len() != expected_len {
        bail!(
            "grid-diff payload has {} bytes, expected {expected_len}",
            payload.len()
        );
    }

    let mut dirty_rows = Vec::with_capacity(usize::from(row_count));
    let mut offset = GRID_HEADER_SIZE;
    for _ in 0..row_count {
        let row_index = u16::from_be_bytes([payload[offset], payload[offset + 1]]);
        offset += 2;
        if row_index >= rows {
            bail!("grid row {row_index} exceeds {rows} rows");
        }
        let cells_end = offset + usize::from(cols) * SNAPSHOT_CELL_SIZE;
        dirty_rows.push(GridRow {
            row_index,
            cells: decode_cells(&payload[offset..cells_end]),
        });
        offset = cells_end;
    }
    Ok(GridDiff {
        frame_seq,
        rows,
        cols,
        cursor_x,
        cursor_y,
        alt_screen,
        dirty_rows,
    })
}

fn encode_cells(payload: &mut Vec<u8>, cells: &[WireCell]) {
    for cell in cells {
        payload.extend_from_slice(&cell.codepoint.to_be_bytes());
        payload.extend_from_slice(&cell.foreground);
        payload.extend_from_slice(&cell.background);
        payload.extend_from_slice(&cell.attributes.to_be_bytes());
        payload.extend_from_slice(&[0; 4]);
    }
}

fn decode_cells(payload: &[u8]) -> Vec<WireCell> {
    payload
        .chunks_exact(SNAPSHOT_CELL_SIZE)
        .map(|bytes| WireCell {
            codepoint: u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
            foreground: [bytes[4], bytes[5], bytes[6]],
            background: [bytes[7], bytes[8], bytes[9]],
            attributes: u16::from_be_bytes([bytes[10], bytes[11]]),
        })
        .collect()
}

/// Data is always split into fair-write chunks, including large ring replays.
pub async fn write_data<W: AsyncWriteExt + Unpin>(w: &mut W, data: &[u8]) -> Result<()> {
    if data.is_empty() {
        return write_frame(w, KIND_DATA, data).await;
    }
    for chunk in data.chunks(MAX_DATA_FRAME_SIZE) {
        write_frame(w, KIND_DATA, chunk).await?;
    }
    Ok(())
}

pub async fn write_resize<W: AsyncWriteExt + Unpin>(w: &mut W, rows: u16, cols: u16) -> Result<()> {
    let mut buf = [0u8; 4];
    buf[0..2].copy_from_slice(&rows.to_be_bytes());
    buf[2..4].copy_from_slice(&cols.to_be_bytes());
    write_frame(w, KIND_RESIZE, &buf).await
}

/// Read one frame. Returns `None` on EOF. Any malformed frame is a channel
/// protocol error; the daemon turns the returned error into `proto_error`.
pub async fn read_frame<R: AsyncReadExt + Unpin>(r: &mut R) -> Result<Option<Frame>> {
    let mut header = [0u8; 5];
    match r.read_exact(&mut header).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let kind = header[0];
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    if len > MAX_FRAME_SIZE {
        bail!("frame length {len} exceeds maximum {MAX_FRAME_SIZE}");
    }
    if !matches!(
        kind,
        KIND_CONTROL
            | KIND_DATA
            | KIND_RESIZE
            | KIND_EVENT
            | KIND_SNAPSHOT
            | KIND_HISTORY
            | KIND_GRID
            | KIND_FILE
            | KIND_UPLOAD
    ) {
        bail!("unknown frame kind {kind:#x}");
    }

    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).await?;
    match kind {
        KIND_CONTROL => {
            let ctrl: Control = serde_json::from_slice(&payload)
                .map_err(|e| anyhow::anyhow!("invalid control JSON: {e}"))?;
            Ok(Some(Frame::Control(ctrl)))
        }
        KIND_DATA => Ok(Some(Frame::Data(payload))),
        KIND_RESIZE => {
            if payload.len() != 4 {
                bail!("malformed resize frame");
            }
            let rows = u16::from_be_bytes([payload[0], payload[1]]);
            let cols = u16::from_be_bytes([payload[2], payload[3]]);
            Ok(Some(Frame::Resize { rows, cols }))
        }
        KIND_EVENT => {
            let event: Event = serde_json::from_slice(&payload)
                .map_err(|e| anyhow::anyhow!("invalid event JSON: {e}"))?;
            Ok(Some(Frame::Event(event)))
        }
        KIND_SNAPSHOT => Ok(Some(Frame::Snapshot(decode_snapshot_payload(&payload)?))),
        KIND_HISTORY => Ok(Some(Frame::History(decode_history_payload(&payload)?))),
        KIND_GRID => Ok(Some(Frame::Grid(decode_grid_payload(&payload)?))),
        KIND_FILE => Ok(Some(Frame::File(decode_file_chunk(&payload)?))),
        KIND_UPLOAD => Ok(Some(Frame::Upload(decode_upload_chunk(&payload)?))),
        _ => unreachable!("frame kind validated above"),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        decode_file_chunk, decode_grid_payload, decode_history_payload, decode_snapshot_payload,
        decode_upload_chunk, encode_file_chunk, encode_grid_payload, encode_history_payload,
        encode_snapshot_payload, encode_upload_chunk, Control, FileChunk, GridDiff, GridRow,
        HistoryChunk, Snapshot, UploadChunk, WireCell, FILE_CHUNK_HEADER_SIZE,
        MAX_FILE_FRAME_SIZE, MAX_UPLOAD_FRAME_SIZE,
    };

    #[test]
    fn upload_chunk_round_trip_and_size_cap() {
        let chunk = UploadChunk {
            upload_id: "u_2a".to_string(),
            offset: 131072,
            data: b"pasted image bytes".to_vec(),
        };
        let encoded = encode_upload_chunk(&chunk).unwrap();
        assert_eq!(decode_upload_chunk(&encoded).unwrap(), chunk);

        let oversize = UploadChunk {
            upload_id: "u_1".to_string(),
            offset: 0,
            data: vec![0; MAX_UPLOAD_FRAME_SIZE],
        };
        assert!(encode_upload_chunk(&oversize).is_err());
        assert!(decode_upload_chunk(&[]).is_err());
        assert!(decode_upload_chunk(&[4, b'u']).is_err(), "truncated id");
    }

    #[test]
    fn file_chunk_round_trip_and_size_cap() {
        let chunk = FileChunk {
            re: 91,
            offset: 65536,
            last: true,
            data: b"preview bytes".to_vec(),
        };
        let encoded = encode_file_chunk(&chunk).unwrap();
        assert_eq!(decode_file_chunk(&encoded).unwrap(), chunk);

        let empty = FileChunk {
            re: 1,
            offset: 0,
            last: true,
            data: Vec::new(),
        };
        let encoded = encode_file_chunk(&empty).unwrap();
        assert_eq!(decode_file_chunk(&encoded).unwrap(), empty);

        let oversize = FileChunk {
            re: 1,
            offset: 0,
            last: false,
            data: vec![0; MAX_FILE_FRAME_SIZE - FILE_CHUNK_HEADER_SIZE + 1],
        };
        assert!(encode_file_chunk(&oversize).is_err());
        assert!(decode_file_chunk(&[0; FILE_CHUNK_HEADER_SIZE - 1]).is_err());
    }

    #[test]
    fn history_payload_round_trip() {
        let history = HistoryChunk {
            cols: 2,
            first_offset: 7,
            row_count: 2,
            cells: vec![
                WireCell {
                    codepoint: u32::from('D'),
                    ..Default::default()
                },
                WireCell::default(),
                WireCell {
                    codepoint: u32::from('C'),
                    ..Default::default()
                },
                WireCell::default(),
            ],
        };

        let encoded = encode_history_payload(&history).unwrap();
        assert_eq!(decode_history_payload(&encoded).unwrap(), history);
    }

    #[test]
    fn attached_dimensions_are_additive() {
        let old_host = br#"{
            "op":"attached",
            "id":"s_1",
            "name":"demo",
            "session_id":"s_1",
            "writer":false
        }"#;
        match serde_json::from_slice::<Control>(old_host).unwrap() {
            Control::Attached { rows, cols, .. } => assert_eq!((rows, cols), (24, 80)),
            _ => panic!("old attached payload decoded as the wrong control variant"),
        }

        let new_host = serde_json::to_value(Control::Attached {
            id: "s_1".to_string(),
            name: "demo".to_string(),
            session_id: "s_1".to_string(),
            writer: false,
            rows: 48,
            cols: 180,
            re: Some(1),
        })
        .unwrap();
        assert_eq!(new_host["rows"], 48);
        assert_eq!(new_host["cols"], 180);
    }

    #[test]
    fn snapshot_payload_round_trip() {
        let snapshot = Snapshot {
            vt: None,
            rows: 1,
            cols: 2,
            cursor_x: 1,
            cursor_y: 0,
            alt_screen: true,
            title: "proof ✓".to_string(),
            cells: vec![
                WireCell {
                    codepoint: u32::from('A'),
                    foreground: [1, 2, 3],
                    background: [4, 5, 6],
                    attributes: 7,
                },
                WireCell::default(),
            ],
        };

        let encoded = encode_snapshot_payload(&snapshot).unwrap();
        assert_eq!(decode_snapshot_payload(&encoded).unwrap(), snapshot);
    }

    #[test]
    fn snapshot_payload_rejects_wrong_cell_count() {
        let snapshot = Snapshot {
            vt: None,
            rows: 1,
            cols: 1,
            cursor_x: 0,
            cursor_y: 0,
            alt_screen: false,
            title: String::new(),
            cells: Vec::new(),
        };

        assert!(encode_snapshot_payload(&snapshot).is_err());
    }

    #[test]
    fn grid_payload_round_trip() {
        let grid = GridDiff {
            frame_seq: 42,
            rows: 3,
            cols: 2,
            cursor_x: 1,
            cursor_y: 2,
            alt_screen: true,
            dirty_rows: vec![
                GridRow {
                    row_index: 0,
                    cells: vec![
                        WireCell {
                            codepoint: u32::from('A'),
                            foreground: [1, 2, 3],
                            background: [4, 5, 6],
                            attributes: 7,
                        },
                        WireCell::default(),
                    ],
                },
                GridRow {
                    row_index: 2,
                    cells: vec![WireCell::default(), WireCell::default()],
                },
            ],
        };

        let encoded = encode_grid_payload(&grid).unwrap();
        assert_eq!(decode_grid_payload(&encoded).unwrap(), grid);
    }
}
