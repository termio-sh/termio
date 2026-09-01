//! Session Protocol v0.1 — the wire contract between clients and `termiod`.
//!
//! Framing is frozen from v0:
//!
//! ```text
//! [ kind: u8 ][ len: u32 big-endian ][ payload: len bytes ]
//! ```
//!
//! Control and event payloads are JSON. PTY data stays raw and the viewport
//! frame stays a four-byte binary payload, so v0 clients remain byte-compatible.
//!
//! `R` names an *attachment's viewport*, not the PTY's size. The host derives
//! the PTY size from the set of viewports that are currently rendering — see
//! `session::Session::apply_size_policy` and
//! `docs/design/20260901-pty-size-is-not-the-write-token.md`.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub const KIND_CONTROL: u8 = b'C';
pub const KIND_DATA: u8 = b'D';
/// `R`: one attachment's viewport. The name is v0's and is frozen on the wire.
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
    "agents",
    "handoff",
    "viewport",
];
/// Snapshot payload carrying packed cells.
///
/// v3 replaced v1's resolved-RGB cell with a tagged colour slot. v1 is gone
/// rather than kept for compatibility: it could express neither "the client's
/// default" nor "palette index N", so every payload it produced had already
/// lost what a client needs to apply its own theme, and nothing shipped
/// consumed it. Old clients hard-refuse on the version byte rather than limp.
pub const SNAPSHOT_FORMAT_VERSION: u8 = 3;
/// Snapshot payload carrying **VT sequences** instead of packed cells.
///
/// This is the correct shape for the raw plane: the host says *what is on the
/// screen* in the terminal's own language and the client's libghostty decides
/// how it looks. Packed cells are retained only for `grid_diff` clients, whose
/// whole model is server-side state and which need cells to seed their grid,
/// and as the fallback when the formatter itself fails.
pub const SNAPSHOT_FORMAT_VT: u8 = 2;
pub const SNAPSHOT_CELL_SIZE: usize = 16;
pub const HISTORY_FORMAT_VERSION: u8 = 2;
pub const HISTORY_HEADER_SIZE: usize = 9;
pub const MAX_HISTORY_FRAME_SIZE: usize = 64 * 1024;
pub const GRID_FORMAT_VERSION: u8 = 2;
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
/// `R` flags bit 0: this attachment is showing the session. Absent flags byte
/// means set — v0's four-byte payload is a rendering attachment.
pub const VIEWPORT_RENDERING: u8 = 0x01;

/// A single decoded frame off the wire.
#[derive(Debug)]
pub enum Frame {
    Control(Control),
    /// A control frame whose `op` this build has never heard of. Kept apart
    /// from `Control` so an op from a newer peer degrades to a per-request
    /// error instead of killing the connection — before this, one unknown verb
    /// tore down the channel and every subscription riding it.
    UnknownControl { op: String, seq: Option<u64> },
    Data(Vec<u8>),
    /// `R`: this attachment's viewport is now `rows`×`cols`, and it is or is not
    /// rendering the session. Zero in either dimension means the attachment has
    /// no viewport at all — it has not laid out yet — which is not the same as
    /// having one it is not currently showing.
    Viewport {
        rows: u16,
        cols: u16,
        rendering: bool,
    },
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

/// One cell's colour, as the program expressed it rather than as the host would
/// paint it. Mirrors `termiod_vt::Color`; see that type for why the three
/// variants are the whole point and not an encoding detail.
///
/// Wire form is 4 bytes: a tag byte then its value, zero-padded.
/// `0` default (no value) · `1` palette (index in the first byte) · `2` rgb.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum WireColor {
    #[default]
    Default,
    Palette(u8),
    Rgb([u8; 3]),
}

pub const COLOR_TAG_DEFAULT: u8 = 0;
pub const COLOR_TAG_PALETTE: u8 = 1;
pub const COLOR_TAG_RGB: u8 = 2;

impl WireColor {
    fn encode(self) -> [u8; 4] {
        match self {
            WireColor::Default => [COLOR_TAG_DEFAULT, 0, 0, 0],
            WireColor::Palette(index) => [COLOR_TAG_PALETTE, index, 0, 0],
            WireColor::Rgb([r, g, b]) => [COLOR_TAG_RGB, r, g, b],
        }
    }

    /// An unknown tag decodes as `Default` rather than failing the frame: the
    /// tag space is meant to grow (a future indexed-style tag, say), and a cell
    /// that falls back to the client's default colour is a far better outcome
    /// than dropping a whole screen.
    fn decode(bytes: &[u8]) -> Self {
        match bytes[0] {
            COLOR_TAG_PALETTE => WireColor::Palette(bytes[1]),
            COLOR_TAG_RGB => WireColor::Rgb([bytes[1], bytes[2], bytes[3]]),
            _ => WireColor::Default,
        }
    }
}

/// Engine-independent 16-byte cell representation used by packed snapshots,
/// scrollback, and grid diffs.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WireCell {
    pub codepoint: u32,
    pub foreground: WireColor,
    pub background: WireColor,
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
    /// For a `symlink`, what it resolves to — and only when the target stays
    /// inside the workspace root. A tree draws a link to a directory as a
    /// directory (the Finder's and the VS Code explorer's rule), and it may
    /// only offer that when descending would actually be answered: `confine`
    /// canonicalises before it lists, so a link out of the root is refused.
    /// `None` means "do not descend this" — dangling, outside the root, or a
    /// host too old to say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_kind: Option<EntryKind>,
}

/// The listing for one requested path inside an `fs_listed` reply. A path
/// that vanished or escapes the root fails alone (`error`), so a batched
/// speculative request is never all-or-nothing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PathListing {
    pub path: String,
    #[serde(default)]
    pub entries: Vec<DirEntry>,
    /// The last name served, when more entries follow — pass it back as
    /// `after`. Absent when the listing is complete, which is every ordinary
    /// directory. A client that never sees this field is talking to a host too
    /// old to continue a listing and must say so rather than treat one page as
    /// the whole directory.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_after: Option<String>,
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

/// One changed path in a `git_changed` batch (§C.13).
///
/// The line counts ride the status rather than waiting for a diff, because the
/// row that shows the path shows `+N −M` beside it — a client that had to ask
/// per file would need one round trip per row to draw one list. Zed carries the
/// same numbers on the same message (`git.proto` `StatusEntry.diff_stat_added`),
/// for the same reason.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitStatusEntry {
    pub path: String,
    pub status: GitFileStatus,
    /// Where a renamed file came from, for the row that says `old → new`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_path: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub additions: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub deletions: u64,
    /// The counts are not numbers for this file — git reported `-`, or it is an
    /// untracked file that sniffs as binary. `+0 −0` would be a lie, not a zero.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub binary: bool,
}

/// One commit row (§C.13 read tier), as `git.log` and `git.show` report it.
///
/// Both a rendered `relative_date` and a `timestamp`: the box prints git's own
/// "3 hours ago" in the box's language, and the client rendering the row may be
/// in another one, so it needs the instant to format for itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitCommitEntry {
    pub sha: String,
    pub short_sha: String,
    pub subject: String,
    pub author: String,
    pub author_email: String,
    pub relative_date: String,
    /// Author date, Unix seconds.
    pub timestamp: i64,
    /// Tags pointing at this commit. Branch decorations are dropped — the
    /// sidebar and the pane's own scope already say which branch this is.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    /// The commit has not reached the branch's upstream (`@{upstream}..HEAD`).
    /// False for every row when the branch has no upstream, so a purely local
    /// branch does not mark all of them.
    #[serde(default)]
    pub unpushed: bool,
}

/// One file a commit touched (§C.13 read tier). `status` reuses the status
/// vocabulary the `git:` kind already publishes; a commit's file carries one
/// axis, not two.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitCommitFile {
    pub path: String,
    /// For a rename or a copy, the path the file came from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_path: Option<String>,
    pub status: GitStatusCode,
    #[serde(default)]
    pub additions: u64,
    #[serde(default)]
    pub deletions: u64,
    /// `--numstat` reported `-` for the counts, so `+`/`−` numbers would be a
    /// lie rather than a zero.
    #[serde(default)]
    pub binary: bool,
}

/// Why a `git_compare` could not compare — each a different instruction to the
/// user, so folding them into an empty file list (which reads as "this branch
/// changes nothing") is the one thing this must never do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitCompareProblem {
    /// The base no longer resolves: its branch was deleted since it was picked.
    MissingBase,
    /// No merge base connects the two — unrelated histories, or a shallow
    /// clone grafted above the divergence point.
    NoCommonHistory,
}

/// One ref in a `git.branches` reply (§C.13 read tier).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitBranchEntry {
    /// Short name: `main` for a local branch, `origin/main` for a
    /// remote-tracking one. The two are told apart by `remote`, never by the
    /// shape of the name.
    pub name: String,
    #[serde(default)]
    pub remote: bool,
}

/// One `fs.search` hit (§C.12): workspace-relative path, 1-based line, the
/// matching line's text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchMatch {
    pub path: String,
    pub line: u64,
    /// The matching line, or a window of it when the line is long. `text_offset`
    /// says where the window starts, so a client can show that it was cut.
    pub text: String,
    /// Byte offset of `text` within the real line. Non-zero only for a windowed
    /// long line, and always chosen so the first match is inside the window —
    /// truncating from the left would send a line with the match cut off it,
    /// which no client can highlight.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub text_offset: u64,
    /// Where the query matched inside `text`, as byte ranges. Produced by the
    /// same case rule that decided the line matched at all, so a client paints
    /// hits instead of re-deriving them with a second, differently-behaved
    /// matcher. Empty from a host too old to report them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub spans: Vec<[u32; 2]>,
    /// The lines just before and after, for an excerpt. Capped by the host; a
    /// client that wants only the matching line ignores them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub before: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub after: Vec<String>,
}

fn is_zero(value: &u64) -> bool {
    *value == 0
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
    /// The write was refused because what it would replace has changed since
    /// the writer read it. Its own code because a client shows it as a question
    /// (overwrite, or not) rather than as a failure.
    Conflict,
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

fn default_true() -> bool {
    true
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

/// The protocol's workstream vocabulary, from whatever a hook said.
///
/// A manifest declares its events as `working` / `attention` / `done` / `idle`;
/// the protocol says `needs_you` where a manifest says `attention`. Untranslated,
/// a device agent stopped at a permission prompt reported a state no client
/// recognised and sat there looking idle. Anything else passes through untouched
/// — the daemon is not the judge of what a status may be.
pub fn normalize_status(status: &str) -> &str {
    match status {
        "attention" => "needs_you",
        other => other,
    }
}

/// The four per-report facts a status carries beyond its state and title.
///
/// Bundled so the daemon can hand them from `set_status` to the event without
/// four parameters threading through the session actor, and so growing a fifth
/// is one edit rather than five.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StatusDetails {
    pub transcript_path: Option<String>,
    pub conversation_id: Option<String>,
    pub tool: Option<String>,
    pub prompt_title: Option<String>,
}

impl StatusDetails {
    /// Empty strings are how a shell hook says "nothing here" — `--tool-from` on
    /// an event whose payload has no such field mines to `""`. Treated as
    /// absent, so a client never has to distinguish the two.
    pub fn sanitized(self) -> StatusDetails {
        fn some(value: Option<String>) -> Option<String> {
            value.filter(|text| !text.is_empty())
        }
        StatusDetails {
            transcript_path: some(self.transcript_path),
            conversation_id: some(self.conversation_id),
            tool: some(self.tool),
            prompt_title: some(self.prompt_title),
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
        /// The daemon's build, `<app version>+<build>` — the version of the
        /// app that shipped it (`lifecycle::BUILD_VERSION`). This is what
        /// lets a control plane say "termiod 0.43 on ukvps; this app needs
        /// 0.44" instead of inferring age from a missing capability. Absent
        /// from a daemon that predates it, which the lifecycle loop reads as
        /// older than anything that reports one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        version: Option<String>,
        /// This account's home directory on the device, so a client that has
        /// to name a path over here — a project picker, a `~`-prefixed entry —
        /// starts where the user's work is instead of at `/`. Sent at the
        /// handshake rather than fetched, because expanding `~` client-side
        /// costs no round trip while someone is typing. Empty when the home
        /// directory cannot be determined; clients fall back to `/`.
        #[serde(default)]
        home: String,
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
    /// Client asks for a fresh snapshot of the screen it is attached to.
    ///
    /// The byte stream is raw PTY output, so a client that lost any of it holds
    /// a screen that is simply wrong — and only the host can say what the
    /// screen should be. Attaching is the other way to get one; this is the
    /// way that does not cost an attachment.
    ///
    /// The gap is not always the daemon's to see: a Mac relaying to a phone
    /// drops frames on *its* outbound socket, downstream of everything the
    /// daemon's own backlog protects.
    RequestSnapshot {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Client asks for the write token, without re-attaching to get it.
    ///
    /// Attaching takes the token only when nobody holds it, so without this a
    /// Mac and a phone on one session would rebuild their attachments every time
    /// the user's hands moved, and the newcomer's grid would drag the shared PTY
    /// to its own width behind the muted client's back. The token follows the
    /// device being *used*: a client claims it when its user actually types.
    /// Observers are refused — they never claim the write token.
    ClaimWriter {
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
        /// Resume a directory larger than one page at the entry *after* this
        /// name — a keyset cursor rather than an offset, so a directory being
        /// written while it is read cannot serve one entry twice and skip
        /// another (`files.rs` `list`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        after: Option<String>,
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
    /// Content search (§C.12, capability `files`): the host walks the root
    /// itself — ripgrep's searcher over the ignore rules, no subprocess and no
    /// git — and streams `search_results` events tagged with this request's `seq`,
    /// then closes with one `fs_searched` reply. Cancellable mid-stream with
    /// `cancel {request: <seq>}`.
    FsSearch {
        root: String,
        query: String,
        limit: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Replace the daemon's own binary without stopping it (capability
    /// `handoff`). The host `execve`s `binary`, keeping its pid, its children
    /// and every PTY master, so no session is lost to the upgrade.
    ///
    /// `binary` is the path the *client* wants the host to become, absolute and
    /// on the host's own filesystem — normally the client's own executable,
    /// because the thing that asks for a handoff is the new build that was just
    /// staged there. The socket is owner-only, and anyone who can reach it can
    /// already ask for a session running anything, so naming an executable here
    /// grants nothing that was not already granted.
    ///
    /// The reply is `ok` and it means the host accepted, not that it finished:
    /// the exec follows it, and it takes the connection with it. A client
    /// confirms by reconnecting and reading the version at the handshake — with
    /// the pid unchanged, which is the whole claim.
    Handoff {
        binary: String,
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
    /// The `git:` kind's diff verb (§C.13, capability `git`): a unified diff
    /// for one path, rendered client-side.
    GitDiff {
        root: String,
        path: String,
        #[serde(default)]
        staged: bool,
        /// The `-U` the client wants. A pane that folds unchanged runs into
        /// expandable bands needs the whole file, not git's default three lines
        /// of context; absent means git's default.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        context: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Commit list (§C.13 read tier, capability `git`) — what the History tab
    /// shows. `limit` is clamped to the host's cap; `range` narrows the walk to
    /// a revision range (`origin/main..HEAD`), which is what lets the Compare
    /// tab be composed from this verb plus `git.diff` rather than a verb of its
    /// own.
    GitLog {
        root: String,
        limit: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        range: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// One commit's contents and its diff (§C.13 read tier, capability `git`).
    /// `path` narrows the diff to a single file — the row a History entry
    /// expands to — while the file list always describes the whole commit.
    GitShow {
        root: String,
        commit: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// The checkout's refs (§C.13 read tier, capability `git`) — the Compare
    /// tab's base picker in one hop, rather than a `git` per field.
    GitBranches {
        root: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// The branch measured against a base (§C.13 read tier, capability `git`):
    /// the three-dot file list and how far the base has moved on — the halves
    /// of the Compare tab that `git.log`'s range cannot compose. `path` narrows
    /// to one file's ranged diff, the row a compare entry expands to, exactly
    /// as `git.show`'s `path` does for a commit.
    GitCompare {
        root: String,
        base: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        path: Option<String>,
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
        /// The version the writer read, for a commit that replaces a file it
        /// read first (§C.12 save). The host refuses the commit when the
        /// destination has moved on, which is what keeps two writers in one
        /// checkout — usually a person and an agent — from silently
        /// overwriting each other. Omitted for a transfer that overwrites
        /// nothing, like a paste into a scratch directory.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        if_unmodified_since: Option<u64>,
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
    /// Report a session's agent status.
    ///
    /// Everything past `title` used to reach only the Mac app's own socket: the
    /// transcript address, the `/new` rotation signal, the running tool, and a
    /// first-prompt label are now available wherever the agent runs. All
    /// optional and additive — an older client ignores what it does not know,
    /// and a hook with nothing to say omits the field rather than sending an
    /// empty one.
    SetStatus {
        id: String,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        /// The agent's own conversation log for this session (Claude Code's
        /// `transcript_path`), so a caller can be handed the address of the raw
        /// Q&A instead of scraping the screen.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        transcript_path: Option<String>,
        /// The agent's own id for the conversation it is writing now. Lets a
        /// client follow an in-process `/new` rotation without the id having to
        /// be encoded in a transcript filename.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation_id: Option<String>,
        /// The tool a tool-scoped event fired for, so real work can be told from
        /// a prose-only turn.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tool: Option<String>,
        /// A raw first-prompt title candidate. The client normalizes and bounds
        /// it; the daemon passes it through untouched.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        prompt_title: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
    /// Install termio's agent integration on this box, or remove it
    /// (capability `agents`).
    ///
    /// The machine that owns the files decides what goes in them: the client
    /// names which agents the user enabled — a preference — and the daemon works
    /// out where each keeps its config, whether its CLI is even here, and what
    /// to merge. What used to be forty to sixty sequential `ssh` round trips is
    /// this one message.
    ///
    /// The client never names a destination. Every path written comes from a
    /// manifest this box already has, so the write surface is fixed by the box
    /// rather than chosen by the caller.
    InstallAgents {
        /// The agent ids the user has enabled, or absent for the whole catalog.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        agents: Option<Vec<String>>,
        /// What to do with each half: install, remove, or leave alone. Stated
        /// per half because the two Integration switches are independent, and
        /// one message has to stay one message when they disagree.
        #[serde(default)]
        hooks: crate::agent::install::HalfAction,
        #[serde(default)]
        skills: crate::agent::install::HalfAction,
        /// What an installed hook runs to report status. Only the client knows
        /// whether an app is listening, and where its CLI copy is.
        reporter: crate::agent::install::Reporter,
        /// Version stamped into each hook command, so the first sync after an
        /// upgrade rewrites the hooks. Absent means this daemon's own version.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        hook_version: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },

    /// Which of these agents' CLIs are present on this box (capability
    /// `agents`). Read-only, and one round trip for the whole roster.
    ProbeAgents {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        agents: Option<Vec<String>>,
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
        /// The file's modification time in whole seconds — the version this
        /// read holds. A client that means to write the file back sends it to
        /// `upload_commit` as `if_unmodified_since`. Absent from a host too old
        /// to report it, which reads as 0: no version, so no check.
        #[serde(default)]
        mtime: u64,
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
    /// Reply to `git_log`, newest first. `truncated` means the walk stopped at
    /// the limit and older commits exist — a client asks for more by raising
    /// `limit`, never by assuming this was the whole history.
    GitLogResult {
        commits: Vec<GitCommitEntry>,
        #[serde(default)]
        truncated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `git_show`. Two caps, two flags: `truncated` marks the diff cut
    /// at the 1 MiB cap, `files_truncated` a file list cut at the host's file
    /// cap. One flag for both would leave a client unable to say which half of
    /// the reply it is missing.
    GitShowResult {
        commit: GitCommitEntry,
        files: Vec<GitCommitFile>,
        diff: String,
        #[serde(default)]
        truncated: bool,
        #[serde(default)]
        files_truncated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `git_branches`. `current` is absent on a detached or unborn
    /// HEAD, where "the branch this checkout is on" has no answer.
    /// `default_branch` is the remote's own recorded default
    /// (`refs/remotes/origin/HEAD`) as a remote-tracking name — the base a
    /// forge would default a pull request to.
    GitBranchesResult {
        branches: Vec<GitBranchEntry>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        current: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        default_branch: Option<String>,
        #[serde(default)]
        truncated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `git_compare`. `problem` set means no comparison could be made
    /// and the other fields are empty — stated as its own field rather than an
    /// `error`, because "this base is gone" is an answer about the checkout,
    /// not a failed request. `behind` counts commits on the base this branch
    /// lacks (two-dot, tips apart), while `files` is three-dot from the merge
    /// base — the change a merge would introduce.
    GitCompareResult {
        files: Vec<GitCommitFile>,
        /// The commits the merge would bring, newest first — carried here
        /// rather than composed from a separate `git_log` so the file list,
        /// the commits and the behind count all describe one pinned head.
        #[serde(default)]
        commits: Vec<GitCommitEntry>,
        #[serde(default)]
        behind: u64,
        diff: String,
        #[serde(default)]
        truncated: bool,
        #[serde(default)]
        files_truncated: bool,
        #[serde(default)]
        commits_truncated: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        problem: Option<GitCompareProblem>,
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
        /// The version the write produced, in whole seconds. A client saving
        /// the same file again sends this back as `if_unmodified_since`;
        /// without it the second save would claim the version the file was
        /// *opened* at and be refused by its own first write.
        #[serde(default)]
        mtime: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `probe_agents`.
    AgentsProbed {
        agents: Vec<crate::agent::install::AgentPresence>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        re: Option<u64>,
    },
    /// Reply to `install_agents`, one row per agent per kind. Every agent the
    /// request selected appears, including the ones that were refused and the
    /// ones whose dialect this daemon does not write yet: a silent no-op is what
    /// "no hooks on the VPS" looked like, and it is the failure this must not
    /// have.
    AgentsInstalled {
        results: Vec<crate::agent::install::InstallResult>,
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
    /// Sent to the client that just took the write token. The name is v0's,
    /// from when the token carried the grid with it; it now says only that this
    /// attachment may type. Retained because it is the one writer signal a
    /// client without the `events` capability receives.
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
            | Control::ClaimWriter { seq }
            | Control::RequestSnapshot { seq }
            | Control::Subscribe { seq, .. }
            | Control::SubscribeResource { seq, .. }
            | Control::UnsubscribeResource { seq, .. }
            | Control::FsList { seq, .. }
            | Control::FsRead { seq, .. }
            | Control::FsMatch { seq, .. }
            | Control::FsSearch { seq, .. }
            | Control::Cancel { seq, .. }
            | Control::GitDiff { seq, .. }
            | Control::GitLog { seq, .. }
            | Control::GitShow { seq, .. }
            | Control::GitBranches { seq, .. }
            | Control::UploadOpen { seq, .. }
            | Control::UploadCommit { seq, .. }
            | Control::UploadAbort { seq, .. }
            | Control::Wait { seq, .. }
            | Control::SetStatus { seq, .. }
            | Control::InstallAgents { seq, .. }
            | Control::ProbeAgents { seq, .. } => *seq,
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
    /// A session's agent status changed.
    ///
    /// Queued into the session's own per-client channel, the same FIFO its `D`
    /// data goes through, so it cannot overtake output the daemon has already
    /// read and needs no sequence number. (`SetStatus.seq` is a request id, not
    /// an ordering token.) What no token could fix is upstream: an agent may run
    /// its hook before the daemon has read the bytes it just wrote. That race is
    /// bounded by one read, so `working` arriving a few milliseconds early is
    /// not worth a buffering client.
    Status {
        session: String,
        status: String,
        /// Which channel produced this status: `hook`, `title`, `progress`,
        /// `screen`, or `streak`. Additive, and absent from an older daemon —
        /// which a client reads as `hook`, because that is the only channel an
        /// older daemon had.
        ///
        /// A client needs it for exactly one decision: `done` from a hook is the
        /// agent's own word and reads `done` everywhere, while a turn this host
        /// concluded on its own is judged against the viewer's own selection
        /// (§3.3 of the retirement RFC). Nothing else about presentation is
        /// carried here.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source: Option<String>,
        /// This status is the end of a turn that the host derived rather than
        /// was told about. The one bit a viewer needs to apply its own focus.
        #[serde(default, skip_serializing_if = "is_false")]
        turn_ended: bool,
        /// The session is blocked on a person, from an observable condition with
        /// a matching resolved transition — not a one-shot bell. A viewer keeps
        /// the dot through a selection change, because reading a permission
        /// prompt is not answering it.
        ///
        /// Always serialized, unlike the other additive fields: absent means an
        /// older daemon, and every `needs_you` such a daemon sent was blocking.
        /// A client reads a missing field as `true`, so the field can only ever
        /// *narrow* the claim — which is what makes it safe to add.
        #[serde(default)]
        blocking: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        transcript_path: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tool: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        prompt_title: Option<String>,
    },
    /// A session has been working for a full window with no sign of progress
    /// (device architecture §4.7). Watch-plane only: the session's status stays
    /// `working`, because from outside an agent a quiet long build and a wedged
    /// loop are indistinguishable — which is exactly why this plane signals and
    /// never kills. Edge-triggered: one event per quiet window, re-armed by
    /// progress.
    Stalled {
        session: String,
        /// How long the turn has been running, for the evidence line a client
        /// words itself.
        working_seconds: u64,
        transcript_lines_grown: u64,
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
        /// The session's last `SessionInfo`, sampled after the child was reaped
        /// and carried on the event so the answer travels with the news. Nobody
        /// can ask for it afterwards: the session actor stops the moment this is
        /// sent, and `list` no longer has a row. It always reports
        /// `alive: false`, and `child_executable_replaced` is evaluated at exit
        /// time — the whole reason the record has to be built here rather than
        /// reconstructed from an earlier poll.
        ///
        /// Optional because an old daemon does not send it. A client that finds
        /// it absent keeps whatever it last read from `list`, which is exactly
        /// today's behaviour.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        info: Option<Box<SessionInfo>>,
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
    /// A status delta for the `status:` resource — the third consumer of
    /// §C.10's one mechanism, and the one whose producer is the host's own
    /// status engine rather than a filesystem watch.
    ///
    /// Carries the same facts as `Event::Status` plus the cursor. Both exist on
    /// purpose: the event is how an attached client hears about its *own*
    /// session without a second subscription; the resource is how a roster
    /// hears about every session and can resume at a cursor after a reconnect.
    StatusChanged {
        resource: String,
        seq: u64,
        session: String,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source: Option<String>,
        #[serde(default, skip_serializing_if = "is_false")]
        turn_ended: bool,
        #[serde(default, skip_serializing_if = "is_false")]
        blocking: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        /// Present only on the one `stalled` signal per quiet window.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        stalled_working_seconds: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        stalled_transcript_lines_grown: Option<u64>,
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
        /// How many paths the status run named, when the list was cut below
        /// that (`git::STATUS_CAP`) — a batch is one frame, and an uncapped
        /// `--untracked-files=all` over a tree with no `.gitignore` would
        /// exceed `MAX_FRAME_SIZE` and take the whole connection with it.
        /// Carried so a partial list cannot read as a complete one, and so the
        /// pane can say how much of it is missing.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        total: Option<u64>,
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
    /// The workstream's project root. A client attached straight to this host
    /// has no other source for it, and without it the roster is a flat list of
    /// sessions with nothing to group them under.
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub attached_clients: usize,
    #[serde(default)]
    pub writer_client_id: Option<String>,
    /// The live process inside the tty's foreground process group whose argv is
    /// reported below. This is the program the user is talking to, which after
    /// the first minute of a session is rarely the one in `command`.
    ///
    /// A pid, not the process group id. The two agree whenever the group leader
    /// is still running, which is every simple command; they part in a pipeline
    /// whose leader has exited while a later stage still runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground_pid: Option<i32>,
    /// Argv of that process — the agent's identity, read from the kernel rather
    /// than scraped off the screen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground_argv: Option<Vec<String>>,
    /// Whether something other than the session's own child holds the
    /// foreground, i.e. a command is running rather than a shell idling at its
    /// prompt. This is the signal a client keys "closing this loses work" off.
    ///
    /// Derived from the foreground *process group*, not from `foreground_pid`:
    /// a pipeline whose leader has already exited is still a running job, and
    /// comparing the surviving member's pid against the shell would say so
    /// twice over — but comparing a *missing* one would say the opposite.
    #[serde(default, skip_serializing_if = "is_false")]
    pub foreground_job: bool,
    /// The child's *current* directory, which `cd` moves and `cwd` (the
    /// directory the session was created in) does not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub child_cwd: Option<String>,
    /// The binary the child is running, as the kernel resolved it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub child_executable: Option<String>,
    /// Whether that binary has been replaced on disk since it was pinned — an
    /// agent that updated itself and quit, told apart from one that just quit.
    #[serde(default, skip_serializing_if = "is_false")]
    pub child_executable_replaced: bool,
}

fn default_status() -> String {
    "unknown".to_string()
}

fn is_false(value: &bool) -> bool {
    !*value
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

/// Snapshot payload v3:
/// version:u8, rows/cols/cursor_x/cursor_y:u16be, alt_screen:u8,
/// title_len:u16be, UTF-8 title, then row-major 16-byte cells. Each cell is
/// codepoint:u32be, foreground colour (4), background colour (4),
/// attributes:u16be, and two reserved zero bytes.
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

/// 16 bytes: codepoint u32be, foreground 4, background 4, attributes u16be,
/// then 2 reserved. The cell stays 16 bytes wide so both decoders can keep
/// indexing by offset; shrinking it (run-length spans, style split from text)
/// is a separate, still-conditional optimisation.
fn encode_cells(payload: &mut Vec<u8>, cells: &[WireCell]) {
    for cell in cells {
        payload.extend_from_slice(&cell.codepoint.to_be_bytes());
        payload.extend_from_slice(&cell.foreground.encode());
        payload.extend_from_slice(&cell.background.encode());
        payload.extend_from_slice(&cell.attributes.to_be_bytes());
        payload.extend_from_slice(&[0; 2]);
    }
}

fn decode_cells(payload: &[u8]) -> Vec<WireCell> {
    payload
        .chunks_exact(SNAPSHOT_CELL_SIZE)
        .map(|bytes| WireCell {
            codepoint: u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
            foreground: WireColor::decode(&bytes[4..8]),
            background: WireColor::decode(&bytes[8..12]),
            attributes: u16::from_be_bytes([bytes[12], bytes[13]]),
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

/// Writes one `R` frame. A rendering attachment sends v0's exact four bytes; the
/// flags byte exists only to say *not* rendering, so a client that never hides a
/// session never puts a byte on the wire an old host cannot read.
pub async fn write_viewport<W: AsyncWriteExt + Unpin>(
    w: &mut W,
    rows: u16,
    cols: u16,
    rendering: bool,
) -> Result<()> {
    let mut buf = [0u8; 5];
    buf[0..2].copy_from_slice(&rows.to_be_bytes());
    buf[2..4].copy_from_slice(&cols.to_be_bytes());
    buf[4] = if rendering { VIEWPORT_RENDERING } else { 0 };
    let len = if rendering { 4 } else { 5 };
    write_frame(w, KIND_RESIZE, &buf[..len]).await
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
            match serde_json::from_slice::<Control>(&payload) {
                Ok(ctrl) => Ok(Some(Frame::Control(ctrl))),
                Err(decode_error) => {
                    // An op this build doesn't know is version skew, not a
                    // broken pipe: answer it, don't hang up on it. Only a frame
                    // that names an op qualifies — anything else really is
                    // malformed JSON and keeps failing the read.
                    #[derive(serde::Deserialize)]
                    struct Tagged {
                        op: String,
                        #[serde(default)]
                        seq: Option<u64>,
                    }
                    match serde_json::from_slice::<Tagged>(&payload) {
                        Ok(tagged) => Ok(Some(Frame::UnknownControl {
                            op: tagged.op,
                            seq: tagged.seq,
                        })),
                        Err(_) => Err(anyhow::anyhow!("invalid control JSON: {decode_error}")),
                    }
                }
            }
        }
        KIND_DATA => Ok(Some(Frame::Data(payload))),
        KIND_RESIZE => {
            // Four bytes is v0's whole payload and still the common case. The
            // optional fifth carries flags; an unknown bit is ignored rather
            // than fatal, so the byte can grow without a version gate.
            if payload.len() != 4 && payload.len() != 5 {
                bail!("malformed viewport frame");
            }
            let rows = u16::from_be_bytes([payload[0], payload[1]]);
            let cols = u16::from_be_bytes([payload[2], payload[3]]);
            let rendering = payload
                .get(4)
                .is_none_or(|flags| flags & VIEWPORT_RENDERING != 0);
            Ok(Some(Frame::Viewport {
                rows,
                cols,
                rendering,
            }))
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
        decode_cells, decode_file_chunk, decode_grid_payload, decode_history_payload,
        decode_snapshot_payload, decode_upload_chunk, encode_cells, encode_file_chunk,
        encode_grid_payload, encode_history_payload, encode_snapshot_payload, encode_upload_chunk,
        Control, Event, FileChunk, GridDiff, GridRow, HistoryChunk, SessionInfo, Snapshot,
        UploadChunk, WireCell,
        WireColor, COLOR_TAG_RGB, SNAPSHOT_CELL_SIZE, FILE_CHUNK_HEADER_SIZE,
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
                    foreground: WireColor::Rgb([1, 2, 3]),
                    background: WireColor::Palette(4),
                    attributes: 7,
                },
                WireCell::default(),
            ],
        };

        let encoded = encode_snapshot_payload(&snapshot).unwrap();
        assert_eq!(decode_snapshot_payload(&encoded).unwrap(), snapshot);
    }

    /// The three colour slots must survive the round trip *as slots*. A cell
    /// asking for the client's default and a cell asking for palette index 0
    /// are different instructions, and the format that preceded this one
    /// encoded both as black.
    #[test]
    fn wire_colors_round_trip_distinctly() {
        let cells: Vec<WireCell> = [
            WireColor::Default,
            WireColor::Palette(0),
            WireColor::Palette(255),
            WireColor::Rgb([0, 0, 0]),
            WireColor::Rgb([9, 8, 7]),
        ]
        .into_iter()
        .map(|color| WireCell {
            codepoint: u32::from('x'),
            foreground: color,
            background: color,
            attributes: 0,
        })
        .collect();

        let mut payload = Vec::new();
        encode_cells(&mut payload, &cells);
        assert_eq!(payload.len(), cells.len() * SNAPSHOT_CELL_SIZE);
        assert_eq!(decode_cells(&payload), cells);

        // Default and palette-0 must not collapse into one another.
        assert_ne!(cells[0], cells[1]);
        assert_ne!(
            &payload[..SNAPSHOT_CELL_SIZE],
            &payload[SNAPSHOT_CELL_SIZE..SNAPSHOT_CELL_SIZE * 2]
        );
    }

    /// A tag this build does not know falls back to the client's default colour
    /// rather than failing the frame, so the tag space can grow additively.
    #[test]
    fn unknown_color_tag_decodes_as_default() {
        let mut payload = vec![0u8; SNAPSHOT_CELL_SIZE];
        payload[4] = 200;
        payload[8] = COLOR_TAG_RGB;
        payload[9..12].copy_from_slice(&[1, 2, 3]);

        let cells = decode_cells(&payload);
        assert_eq!(cells[0].foreground, WireColor::Default);
        assert_eq!(cells[0].background, WireColor::Rgb([1, 2, 3]));
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
                            foreground: WireColor::Rgb([1, 2, 3]),
                            background: WireColor::Palette(4),
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

    fn ended_session() -> SessionInfo {
        SessionInfo {
            id: "s_1".to_string(),
            name: "demo".to_string(),
            cwd: "/work".to_string(),
            command: "claude".to_string(),
            pid: 4242,
            rows: 48,
            cols: 180,
            clients: 0,
            created_unix: 1_700_000_000,
            alive: false,
            status: "done".to_string(),
            agent_id: Some("claude".to_string()),
            project: Some("/work".to_string()),
            title: None,
            attached_clients: 0,
            writer_client_id: None,
            foreground_pid: None,
            foreground_argv: None,
            foreground_job: false,
            child_cwd: Some("/work/sub".to_string()),
            child_executable: Some("/usr/local/bin/claude".to_string()),
            child_executable_replaced: true,
        }
    }

    /// The exit event is the last thing said about a session, so the record it
    /// carries has to survive the wire intact — `alive` and
    /// `child_executable_replaced` in particular, since the client's whole
    /// relaunch decision reads them.
    #[test]
    fn exit_event_carries_the_final_record() {
        let event = Event::SessionExited {
            session: "s_1".to_string(),
            status: 0,
            info: Some(Box::new(ended_session())),
        };
        let encoded = serde_json::to_value(&event).unwrap();
        assert_eq!(encoded["info"]["alive"], false);
        assert_eq!(encoded["info"]["child_executable_replaced"], true);
        assert_eq!(encoded["info"]["child_executable"], "/usr/local/bin/claude");

        match serde_json::from_value::<Event>(encoded).unwrap() {
            Event::SessionExited { info, status, .. } => {
                let info = info.expect("the record round-trips");
                assert_eq!(status, 0);
                assert!(!info.alive);
                assert!(info.child_executable_replaced);
                assert_eq!(info.pid, 4242);
            }
            other => panic!("decoded as the wrong event: {other:?}"),
        }
    }

    /// Additive in both directions: an old daemon sends no `info`, and a new
    /// daemon that has none to send omits the key rather than writing `null`,
    /// so an old client's payload is byte-identical to what it saw before.
    #[test]
    fn exit_event_info_is_additive() {
        let old_host = br#"{"ev":"session_exited","session":"s_1","status":137}"#;
        match serde_json::from_slice::<Event>(old_host).unwrap() {
            Event::SessionExited {
                session,
                status,
                info,
            } => {
                assert_eq!(session, "s_1");
                assert_eq!(status, 137);
                assert!(info.is_none(), "an absent record must not be invented");
            }
            other => panic!("old exit payload decoded as the wrong event: {other:?}"),
        }

        let without = serde_json::to_value(Event::SessionExited {
            session: "s_1".to_string(),
            status: 0,
            info: None,
        })
        .unwrap();
        assert!(without.get("info").is_none());
    }
}
