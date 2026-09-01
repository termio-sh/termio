//! Resumable subscriptions (§C.10).
//!
//! A **resource** is durable host-side state that a client observes: it has a
//! stable id, a monotonic `seq`, and a bounded replay ring. Reconnect is not a
//! special case — a client re-subscribes with the last `seq` it saw and either
//! gets the missed batches replayed or is told the ring overflowed and it must
//! rescan. That is the same shape the terminal plane already proved (`S`
//! snapshot bootstrap + `seq`-ordered live frames), generalised so every later
//! plane inherits one reconnect story instead of inventing its own.
//!
//! The first resource type is `fs:<root>` — a recursive filesystem watch scoped
//! to a **workspace** (a canonicalised root path). One watcher per workspace,
//! shared by every subscriber, so five sessions in one repo cost one watch and
//! not five (which is how Linux `max_user_watches` gets exhausted).
//!
//! Event semantics deliberately mirror the Mac client's `FileTreeWatcher`, so
//! the existing consumer needs no new model:
//! - version-control object churn (`.git/objects`, packs) is dropped outright;
//! - meaningful git metadata (index, HEAD, refs) sets `git_meta` and never
//!   reaches the tree paths;
//! - everything else accumulates as the set of changed **directories**;
//! - a watcher-reported overflow sets `full_rescan`, the wire equivalent of
//!   FSEvents' `MustScanSubDirs`.

use crate::protocol::Event;
use crate::id::ClientId;
use anyhow::{anyhow, Context, Result};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// Quiet window before a batch is published. Matches the 0.3 s FSEvents latency
/// the Mac client already coalesces on, so both ends debounce identically.
const DEBOUNCE: Duration = Duration::from_millis(300);

/// Batches retained per resource for replay. A reconnect inside this many
/// batches resumes exactly; beyond it the client is told to rescan.
const RING_CAPACITY: usize = 256;

/// Paths per batch. A change storm (a branch switch, an agent rewriting a tree)
/// is reported as `full_rescan` rather than a megabyte of paths.
const MAX_PATHS_PER_BATCH: usize = 512;

/// How long a watch outlives its last subscriber. This is the resource-plane
/// form of detach ≠ kill: close the laptop, let the agent keep writing, come
/// back and resume from your cursor. Without it, "resumable" would only mean
/// "resumable while somebody else is still watching".
const LINGER: Duration = Duration::from_secs(300);

/// How often an idle watch re-checks whether its linger has expired.
const IDLE_TICK: Duration = Duration::from_secs(30);

/// The `fs:` resource id prefix. Ids are `fs:<canonical absolute path>`.
pub const FS_PREFIX: &str = "fs:";

/// The `status:` resource id — one per device, not one per session. A client
/// watching a roster wants every row, and one subscription is one cursor to
/// resume from. Specified by
/// `docs/design/20260831-companion-second-protocol-retires.md` §3.6.
pub const STATUS_ID: &str = "status:";

/// The `git:` resource id prefix (§C.13). Ids are `git:<canonical repo root>`.
pub const GIT_PREFIX: &str = "git:";

/// Extra quiet window between a watcher batch reaching the git loop and the
/// `git status` run, so one `git checkout` costs one status run, not one per
/// batch.
const GIT_DEBOUNCE: Duration = Duration::from_millis(200);

/// One published batch of filesystem change for a workspace.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FsBatch {
    /// Directories whose contents changed, absolute. Empty when `full_rescan`.
    pub paths: Vec<String>,
    /// The path set is not authoritative — the client must re-walk what it has
    /// realized. Set on watcher overflow or when a batch exceeds the path cap.
    pub full_rescan: bool,
    /// Git metadata (index / HEAD / refs) moved; re-read status. Object-store
    /// churn never sets this.
    pub git_meta: bool,
}

impl FsBatch {
    fn is_empty(&self) -> bool {
        self.paths.is_empty() && !self.full_rescan && !self.git_meta
    }
}

/// What a ring element must do: become the wire event for its kind. This is
/// the §C.10 "one mechanism" seam — the cursor/ring/gap/linger machinery below
/// is identical for every resource kind.
pub trait ResourceBatch: Clone {
    fn into_event(self, resource: String, seq: u64) -> Event;
}

impl ResourceBatch for FsBatch {
    fn into_event(self, resource: String, seq: u64) -> Event {
        Event::FsChanged {
            resource,
            seq,
            paths: self.paths,
            full_rescan: self.full_rescan,
            git_meta: self.git_meta,
        }
    }
}

/// One session's status, as the `status:` resource carries it. A batch is one
/// session because that is the granularity the engine decides at; the ring
/// makes a burst of them replayable as a run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusBatch {
    pub session: String,
    pub status: String,
    pub source: Option<String>,
    pub turn_ended: bool,
    pub blocking: bool,
    pub title: Option<String>,
    /// Set on the one `stalled` signal, which rides this resource rather than
    /// its own: it is evidence about a session's status, and a client that
    /// wants agent state should not have to subscribe twice.
    pub stalled: Option<StatusStall>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusStall {
    pub working_seconds: u64,
    pub transcript_lines_grown: u64,
}

impl ResourceBatch for StatusBatch {
    fn into_event(self, resource: String, seq: u64) -> Event {
        Event::StatusChanged {
            resource,
            seq,
            session: self.session,
            status: self.status,
            source: self.source,
            turn_ended: self.turn_ended,
            blocking: self.blocking,
            title: self.title,
            stalled_working_seconds: self.stalled.as_ref().map(|s| s.working_seconds),
            stalled_transcript_lines_grown: self
                .stalled
                .as_ref()
                .map(|s| s.transcript_lines_grown),
        }
    }
}

impl ResourceBatch for crate::git::GitBatch {
    fn into_event(self, resource: String, seq: u64) -> Event {
        crate::git::GitBatch::into_event(self, resource, seq)
    }
}

/// What a subscriber is told at subscribe time.
///
/// It carries no replay: the batches are queued straight onto the subscriber's
/// own channel inside `attach`, because handing them back for the caller to
/// send after the lock is what let a live batch overtake them.
pub struct SubscribeReply {
    /// The resource's current seq — the cursor the subscription starts *at*,
    /// which is a target and not an achievement: a client that has not yet
    /// applied the replayed batches must not adopt it, or it resumes from a
    /// future it never saw.
    pub seq: u64,
    /// The client's baseline is unusable — it must do a full scan before
    /// applying anything further. True for a first subscribe, and for a resume
    /// whose `since` has already fallen out of the ring.
    pub gap: bool,
}

struct ResourceState<B: ResourceBatch> {
    /// seq of the most recently published batch; 0 = nothing published yet.
    seq: u64,
    ring: VecDeque<(u64, B)>,
    subscribers: HashMap<ClientId, mpsc::UnboundedSender<Event>>,
    /// When the last subscriber left. `None` while anyone is attached.
    idle_since: Option<Instant>,
    /// Dropping the watcher stops the OS-level watch. `None` for kinds that
    /// borrow another resource's watcher (git), and in tests, which exercise
    /// the ring and replay rules without touching the OS.
    _watcher: Option<RecommendedWatcher>,
}

/// The `fs:` kind's state — the name other code and the tests know it by.
type WatchState = ResourceState<FsBatch>;

impl<B: ResourceBatch> ResourceState<B> {
    fn new(watcher: Option<RecommendedWatcher>) -> ResourceState<B> {
        ResourceState {
            seq: 0,
            ring: VecDeque::new(),
            subscribers: HashMap::new(),
            idle_since: None,
            _watcher: watcher,
        }
    }

    /// The oldest seq still replayable, or `seq` when the ring is empty.
    fn oldest(&self) -> u64 {
        self.ring.front().map(|(s, _)| *s).unwrap_or(self.seq)
    }

    /// Append a batch to the ring and fan it out. The ring is written whether
    /// or not anyone is listening — that is what a detached client resumes
    /// from when it comes back.
    fn publish(&mut self, resource: &str, batch: B) {
        self.seq += 1;
        let seq = self.seq;
        if self.ring.len() == RING_CAPACITY {
            self.ring.pop_front();
        }
        self.ring.push_back((seq, batch.clone()));
        let event = batch.into_event(resource.to_string(), seq);
        self.subscribers
            .retain(|_, tx| tx.send(event.clone()).is_ok());
        if self.subscribers.is_empty() && self.idle_since.is_none() {
            self.idle_since = Some(Instant::now());
        }
    }

    fn expired(&self) -> bool {
        self.subscribers.is_empty()
            && self
                .idle_since
                .is_some_and(|since| since.elapsed() >= LINGER)
    }

    /// Install a subscriber and hand it its replay in **one** critical section.
    ///
    /// The two halves used to be split: `subscribe` registered the subscriber,
    /// released the lock, and the caller queued the replay afterwards. Between
    /// those, a `publish` could fan a *live* batch out to a subscriber that had
    /// not been given its replay yet — so the client applied 11 and then had 9
    /// and 10 land on top of it. This is the same ordering family the clients
    /// grew `DeviceWatchLedger` for, one hop upstream: the host should not
    /// hand out an order it did not put the batches in.
    ///
    /// The replay is queued **before** the subscriber is installed, so nothing
    /// this method admits can precede it, and a `publish` that wins the lock
    /// next necessarily lands behind it. `override_replay` is the `git:` gap
    /// case, which serves a full snapshot instead of a ring slice and has to
    /// decide that inside the same section.
    fn attach(
        &mut self,
        resource: &str,
        client: ClientId,
        tx: mpsc::UnboundedSender<Event>,
        since: Option<u64>,
        override_replay: impl FnOnce(u64) -> Option<Vec<Event>>,
    ) -> SubscribeReply {
        let (gap, replay) = self.resume(resource, since);
        let replay = match gap.then(|| override_replay(self.seq)).flatten() {
            Some(full) => full,
            None => replay,
        };
        for event in replay {
            // Unbounded and non-blocking, which is what makes it safe to do
            // under the lock. A closed receiver means the subscriber left
            // between asking and being served; it is dropped below either way.
            let _ = tx.send(event);
        }
        self.subscribers.insert(client, tx);
        self.idle_since = None;
        SubscribeReply {
            seq: self.seq,
            gap,
        }
    }

    /// Decide what a (re)subscribing client gets. A cursor inside the ring
    /// replays exactly; anything else — a first subscribe, a cursor that aged
    /// out, or one ahead of the host — is a gap the client must rescan from.
    fn resume(&self, resource: &str, since: Option<u64>) -> (bool, Vec<Event>) {
        match since {
            Some(since) if since <= self.seq && since + 1 >= self.oldest() => {
                let replay = self
                    .ring
                    .iter()
                    .filter(|(seq, _)| *seq > since)
                    .map(|(seq, batch)| batch.clone().into_event(resource.to_string(), *seq))
                    .collect();
                (false, replay)
            }
            _ => (true, Vec::new()),
        }
    }
}

/// One workspace's live machinery: the subscription state plus the lazy name
/// index that §C.12's `fs.match` reads. Both share the watch's lifetime — the
/// entry leaving the map drops the index sender, which ends the index task.
#[derive(Clone)]
struct WatchEntry {
    state: Arc<Mutex<WatchState>>,
    index: Arc<crate::files::NameIndex>,
    /// Held for ownership: dropping the entry drops the last sender, which
    /// ends the index task.
    _index_tx: mpsc::UnboundedSender<FsBatch>,
}

/// A `git:` resource (§C.13). It owns no watcher — it subscribes to the
/// workspace's `fs:` watch internally and turns that signal into debounced
/// status runs. `snapshot` is the live full state, which is what a gap
/// subscriber is served: only the host can rescan git status, so on gap the
/// host does the scan for the client.
#[derive(Clone)]
struct GitEntry {
    state: Arc<Mutex<ResourceState<crate::git::GitBatch>>>,
    snapshot: Arc<Mutex<crate::git::GitSnapshot>>,
}

/// The `status:` resource. Like `git:` it owns no watcher — the session actors
/// produce its batches — but unlike `git:` it cannot rescan on gap: a status is
/// a history of transitions, and only the roster says what is true *now*. A gap
/// subscriber is told to re-read `list`, which carries each session's current
/// status. That is the honest answer, and it is one round trip.
type StatusEntry = Arc<Mutex<ResourceState<StatusBatch>>>;

#[derive(Clone)]
enum ResourceEntry {
    Fs(WatchEntry),
    Git(GitEntry),
    Status(StatusEntry),
}

#[derive(Clone, Default)]
pub struct Registry {
    watches: Arc<Mutex<HashMap<String, ResourceEntry>>>,
}

impl Registry {
    pub fn new() -> Registry {
        Registry::default()
    }

    /// Canonicalise a client-supplied root into a resource id. Canonicalising
    /// is what makes "one watcher per workspace" hold — two clients naming the
    /// same repo by different paths must land on the same resource.
    pub fn fs_resource_id(root: &str) -> Result<String> {
        let path = PathBuf::from(root);
        if !path.is_absolute() {
            return Err(anyhow!("watch root must be absolute: {root}"));
        }
        let canonical = std::fs::canonicalize(&path)
            .with_context(|| format!("resolving watch root {root}"))?;
        if !canonical.is_dir() {
            return Err(anyhow!("watch root is not a directory: {root}"));
        }
        Ok(format!("{FS_PREFIX}{}", canonical.display()))
    }

    /// Resolve what a client passed as `resource` to a canonical id. A bare
    /// path (the v1 wire shape) is the `fs:` kind; explicit `fs:`/`git:`
    /// prefixes pick the kind (§C.13 adds `git:`), and `status:` names the one
    /// device-wide resource, which takes no root.
    pub fn resource_id(spec: &str) -> Result<String> {
        if spec == STATUS_ID {
            return Ok(STATUS_ID.to_string());
        }
        if let Some(root) = spec.strip_prefix(GIT_PREFIX) {
            let canonical = Registry::fs_resource_id(root)?;
            let canonical = canonical.trim_start_matches(FS_PREFIX);
            if !Path::new(canonical).join(".git").exists() {
                return Err(anyhow!("not a git repository: {root}"));
            }
            return Ok(format!("{GIT_PREFIX}{canonical}"));
        }
        Registry::fs_resource_id(spec.strip_prefix(FS_PREFIX).unwrap_or(spec))
    }

    /// The `fs:` resource cursor for a workspace root, or 0 when nothing is
    /// watching it. `fs.list` replies are stamped with this so cached listings
    /// carry a freshness proof (§C.12); 0 honestly says "no watch — nothing
    /// will invalidate what you cache".
    pub fn fs_seq(&self, root: &str) -> u64 {
        let Ok(id) = Registry::fs_resource_id(root) else {
            return 0;
        };
        let Some(ResourceEntry::Fs(entry)) = self.watches.lock().unwrap().get(&id).cloned()
        else {
            return 0;
        };
        let seq = entry.state.lock().unwrap().seq;
        seq
    }

    /// The name index for a workspace, if its watch is running. `None` means
    /// no one has subscribed yet — `fs.match` answers coverage 0.0 rather
    /// than starting a walk nobody asked to keep fresh.
    pub fn name_index(&self, root: &str) -> Option<Arc<crate::files::NameIndex>> {
        let id = Registry::fs_resource_id(root).ok()?;
        match self.watches.lock().unwrap().get(&id) {
            Some(ResourceEntry::Fs(entry)) => Some(entry.index.clone()),
            _ => None,
        }
    }

    /// Subscribe `client` to `resource`, resuming from `since` when possible.
    /// The first subscriber starts the watch; the last to leave stops it.
    pub fn subscribe(
        &self,
        resource: &str,
        client: ClientId,
        tx: mpsc::UnboundedSender<Event>,
        since: Option<u64>,
    ) -> Result<SubscribeReply> {
        if resource == STATUS_ID {
            return self.subscribe_status(client, tx, since);
        }
        if resource.starts_with(GIT_PREFIX) {
            return self.subscribe_git(resource, client, tx, since);
        }
        let root = resource
            .strip_prefix(FS_PREFIX)
            .ok_or_else(|| anyhow!("unknown resource kind: {resource}"))?
            .to_string();

        let entry = {
            let mut watches = self.watches.lock().unwrap();
            self.fs_entry_locked(&mut watches, resource, Path::new(&root))?
        };
        let mut guard = entry.state.lock().unwrap();
        Ok(guard.attach(resource, client, tx, since, |_| None))
    }

    /// Get or start the `fs:` watch for a workspace. Shared by fs subscribers
    /// and by the `git:` kind, which rides the same watcher — one repo, one
    /// OS watch, whatever is observing it. Takes the already-held map guard:
    /// one lock for the whole get-or-create, and no way to re-lock under it.
    fn fs_entry_locked(
        &self,
        watches: &mut HashMap<String, ResourceEntry>,
        resource: &str,
        root: &Path,
    ) -> Result<WatchEntry> {
        match watches.get(resource) {
            Some(ResourceEntry::Fs(existing)) => Ok(existing.clone()),
            Some(ResourceEntry::Git(_)) | Some(ResourceEntry::Status(_)) => {
                Err(anyhow!("resource id kind collision: {resource}"))
            }
            None => {
                let created = self.start_watch(resource.to_string(), root)?;
                watches.insert(resource.to_string(), ResourceEntry::Fs(created.clone()));
                Ok(created)
            }
        }
    }

    /// Subscribe to a `git:` resource (§C.13): same cursor/ring/gap/linger as
    /// every resource. A gap subscriber whose cursor cannot replay is served
    /// the full current state at the current seq — the host-side form of
    /// "rescan before applying".
    /// Subscribe to the device's agent status. No watcher to start and nothing
    /// to canonicalise: the resource exists as soon as anyone asks for it, and
    /// the session actors publish into it whether or not anyone is listening —
    /// which is what a client that locked its phone resumes from.
    fn subscribe_status(
        &self,
        client: ClientId,
        tx: mpsc::UnboundedSender<Event>,
        since: Option<u64>,
    ) -> Result<SubscribeReply> {
        let entry = {
            let mut watches = self.watches.lock().unwrap();
            match watches.get(STATUS_ID) {
                Some(ResourceEntry::Status(existing)) => existing.clone(),
                Some(_) => return Err(anyhow!("resource id kind collision: {STATUS_ID}")),
                None => {
                    let created: StatusEntry = Arc::new(Mutex::new(ResourceState::new(None)));
                    watches.insert(STATUS_ID.to_string(), ResourceEntry::Status(created.clone()));
                    created
                }
            }
        };
        let mut guard = entry.lock().unwrap();
        // No snapshot to serve on gap: a status is a history of transitions,
        // and only the roster says what is true *now*. The client re-reads
        // `list`, which carries each session's current status.
        Ok(guard.attach(STATUS_ID, client, tx, since, |_| None))
    }

    /// Publish one session's status. Called from the daemon's own event pump
    /// rather than from a session actor, so a session never has to hold the
    /// registry — and so the resource has exactly one writer, which is what
    /// makes its `seq` an order rather than a race.
    pub fn publish_status(&self, batch: StatusBatch) {
        let entry = match self.watches.lock().unwrap().get(STATUS_ID) {
            Some(ResourceEntry::Status(existing)) => existing.clone(),
            // Nobody has ever subscribed, so there is no ring to write and
            // nothing to resume from. The status still reached every attached
            // client on its own channel.
            _ => return,
        };
        entry.lock().unwrap().publish(STATUS_ID, batch);
    }

    fn subscribe_git(
        &self,
        resource: &str,
        client: ClientId,
        tx: mpsc::UnboundedSender<Event>,
        since: Option<u64>,
    ) -> Result<SubscribeReply> {
        let root = resource
            .strip_prefix(GIT_PREFIX)
            .ok_or_else(|| anyhow!("unknown resource kind: {resource}"))?
            .to_string();

        let entry = {
            let mut watches = self.watches.lock().unwrap();
            match watches.get(resource) {
                Some(ResourceEntry::Git(existing)) => existing.clone(),
                Some(ResourceEntry::Fs(_)) | Some(ResourceEntry::Status(_)) => {
                    return Err(anyhow!("resource id kind collision: {resource}"))
                }
                None => {
                    let created =
                        self.start_git_watch(&mut watches, resource.to_string(), &root)?;
                    watches.insert(resource.to_string(), ResourceEntry::Git(created.clone()));
                    created
                }
            }
        };

        let mut guard = entry.state.lock().unwrap();
        let snapshot = entry.snapshot.clone();
        let resource_id = resource.to_string();
        // Only the host can rescan git status, so a gap subscriber is served
        // the full current state at the current seq rather than told to do it
        // itself — decided inside `attach`'s critical section with everything
        // else, so it cannot be overtaken either.
        // Takes the snapshot lock while holding the state lock. Safe in that
        // order and only that order: `refresh_git` releases the snapshot before
        // it touches the state, so the two never nest the other way.
        //
        // **The build stays under the state lock on purpose, and the bound is
        // why that is affordable.** Moving it out would break the one pairing
        // that matters: the full batch must describe the snapshot *at* the seq
        // it is stamped with. `refresh_git` writes the snapshot and then
        // publishes, so a build that read the snapshot outside this lock could
        // be stamped with a seq taken after the publish — old state under a new
        // cursor, and the delta it missed is skipped for good. Holding the state
        // lock across both reads is what makes that interleaving impossible.
        //
        // The cost it buys is bounded by `cap_statuses`: at most `STATUS_CAP`
        // (5,000) entries and `STATUS_PATH_BYTES_CAP` (1 MiB) of paths, so the
        // clone-and-sort is a five-thousand-element sort at worst, on a lock no
        // other resource shares. A tree big enough to matter is capped before it
        // ever reaches here.
        Ok(guard.attach(resource, client, tx, since, move |seq| {
            (seq > 0).then(|| {
                let full = snapshot.lock().unwrap().full_batch();
                vec![crate::git::GitBatch::into_event(full, resource_id, seq)]
            })
        }))
    }

    /// Start the machinery behind one `git:` resource: ensure the workspace's
    /// `fs:` watch is running, register an internal subscriber on it (which
    /// also keeps it alive), and spawn the loop that turns its batches into
    /// debounced status runs.
    fn start_git_watch(
        &self,
        watches: &mut HashMap<String, ResourceEntry>,
        resource: String,
        root: &str,
    ) -> Result<GitEntry> {
        let fs_id = Registry::fs_resource_id(root)?;
        let fs_entry = self.fs_entry_locked(watches, &fs_id, Path::new(root))?;

        let (signal_tx, signal_rx) = mpsc::unbounded_channel::<Event>();
        let internal_client = ClientId::internal(format!("git-signal:{resource}"));
        {
            let mut guard = fs_entry.state.lock().unwrap();
            guard.subscribers.insert(internal_client.clone(), signal_tx);
            guard.idle_since = None;
        }

        let entry = GitEntry {
            state: Arc::new(Mutex::new(ResourceState::new(None))),
            snapshot: Arc::new(Mutex::new(crate::git::GitSnapshot::default())),
        };
        tokio::spawn(git_loop(
            resource,
            root.to_string(),
            signal_rx,
            entry.clone(),
            self.clone(),
            fs_id,
            internal_client,
        ));
        Ok(entry)
    }

    /// Drop one client's interest. Returns whether the client had been
    /// subscribed. The watch keeps running for `LINGER` so the same client can
    /// come back and resume from its cursor — detach ≠ kill, applied to the
    /// resource plane.
    pub fn unsubscribe(&self, resource: &str, client: &ClientId) -> bool {
        fn drop_interest<B: ResourceBatch>(
            state: &Arc<Mutex<ResourceState<B>>>,
            client: &ClientId,
        ) -> bool {
            let mut guard = state.lock().unwrap();
            let removed = guard.subscribers.remove(client).is_some();
            if guard.subscribers.is_empty() && guard.idle_since.is_none() {
                guard.idle_since = Some(Instant::now());
            }
            removed
        }
        let watches = self.watches.lock().unwrap();
        match watches.get(resource) {
            Some(ResourceEntry::Fs(entry)) => drop_interest(&entry.state, client),
            Some(ResourceEntry::Git(entry)) => drop_interest(&entry.state, client),
            Some(ResourceEntry::Status(state)) => drop_interest(state, client),
            None => false,
        }
    }

    /// Drop every subscription held by a departing connection.
    pub fn drop_client(&self, client: &ClientId) {
        let resources: Vec<String> = self.watches.lock().unwrap().keys().cloned().collect();
        for resource in resources {
            self.unsubscribe(&resource, client);
        }
    }

    fn start_watch(&self, resource: String, root: &Path) -> Result<WatchEntry> {
        let (raw_tx, raw_rx) = mpsc::unbounded_channel::<notify::Result<notify::Event>>();
        let mut watcher = notify::recommended_watcher(move |event| {
            // The watcher thread must never block on a slow subscriber; the
            // debounce task owns all fan-out.
            let _ = raw_tx.send(event);
        })
        .context("creating filesystem watcher")?;
        watcher
            .watch(root, RecursiveMode::Recursive)
            .with_context(|| format!("watching {}", root.display()))?;

        let state = Arc::new(Mutex::new(WatchState::new(Some(watcher))));
        // The first subscribe is what triggers the lazy index build (§C.12).
        let (index, index_tx) = crate::files::spawn_index(root.to_path_buf());
        tokio::spawn(debounce_loop(
            resource,
            raw_rx,
            state.clone(),
            index_tx.clone(),
            self.watches.clone(),
        ));
        Ok(WatchEntry {
            state,
            index,
            _index_tx: index_tx,
        })
    }
}

type WatchMap = Arc<Mutex<HashMap<String, ResourceEntry>>>;

/// Drive one `git:` resource: coalesce the workspace watcher's signal, run
/// `git status --porcelain=v2`, publish the delta. Retires itself — and its
/// grip on the `fs:` watch — when its own linger runs out.
///
/// Trigger note: §C.13 names the `git_meta` signal, but a worktree edit
/// changes status without touching `.git`, so every batch triggers a run
/// (recorded as a deviation in the spec changelog).
async fn git_loop(
    resource: String,
    root: String,
    mut signal_rx: mpsc::UnboundedReceiver<Event>,
    entry: GitEntry,
    registry: Registry,
    fs_resource: String,
    internal_client: ClientId,
) {
    refresh_git(&resource, &root, &entry).await;
    loop {
        match tokio::time::timeout(IDLE_TICK, signal_rx.recv()).await {
            Ok(Some(_)) => {
                // One checkout arrives as several watcher batches; quiet them
                // into one status run.
                while let Ok(Some(_)) =
                    tokio::time::timeout(GIT_DEBOUNCE, signal_rx.recv()).await
                {}
                refresh_git(&resource, &root, &entry).await;
            }
            Ok(None) => break,
            Err(_) => {
                if entry.state.lock().unwrap().expired() {
                    break;
                }
            }
        }
    }
    registry.watches.lock().unwrap().remove(&resource);
    registry.unsubscribe(&fs_resource, &internal_client);
}

async fn refresh_git(resource: &str, root: &str, entry: &GitEntry) {
    match crate::git::run_status(root).await {
        Ok(fresh) => {
            let delta = {
                let mut snapshot = entry.snapshot.lock().unwrap();
                let delta = fresh.delta_from(&snapshot);
                *snapshot = fresh;
                delta
            };
            if let Some(batch) = delta {
                entry.state.lock().unwrap().publish(resource, batch);
            }
        }
        // Never silently: a broken repo keeps its subscribers' cursors valid
        // (nothing published) and tells the operator why nothing moves.
        Err(error) => eprintln!("termiod: git status for {resource}: {error:#}"),
    }
}

/// Accumulate raw watcher events and publish one batch per quiet window.
async fn debounce_loop(
    resource: String,
    mut raw_rx: mpsc::UnboundedReceiver<notify::Result<notify::Event>>,
    state: Arc<Mutex<WatchState>>,
    index_tx: mpsc::UnboundedSender<FsBatch>,
    watches: WatchMap,
) {
    let mut pending = FsBatch::default();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    loop {
        // Wait for change, waking periodically so an idle watch whose linger
        // has run out can retire itself instead of holding an OS watch forever.
        let first = loop {
            match tokio::time::timeout(IDLE_TICK, raw_rx.recv()).await {
                Ok(Some(event)) => break event,
                Ok(None) => return,
                Err(_) => {
                    if state.lock().unwrap().expired() {
                        watches.lock().unwrap().remove(&resource);
                        return;
                    }
                }
            }
        };
        absorb(first, &mut pending, &mut seen);
        loop {
            match tokio::time::timeout(DEBOUNCE, raw_rx.recv()).await {
                Ok(Some(event)) => absorb(event, &mut pending, &mut seen),
                Ok(None) => return,
                Err(_) => break,
            }
        }

        let batch = std::mem::take(&mut pending);
        seen.clear();
        if batch.is_empty() {
            continue;
        }
        // The index applies the same batches subscribers see; a git_meta-only
        // batch has nothing for it.
        if batch.full_rescan || !batch.paths.is_empty() {
            let _ = index_tx.send(batch.clone());
        }
        // Published unconditionally: batches recorded while nobody is attached
        // are exactly what a returning client replays.
        state.lock().unwrap().publish(&resource, batch);
    }
}

fn absorb(
    event: notify::Result<notify::Event>,
    pending: &mut FsBatch,
    seen: &mut std::collections::HashSet<String>,
) {
    let event = match event {
        Ok(event) => event,
        // A watcher-level error (queue overflow, watch limit) invalidates the
        // path set — the only safe response is to make the client rescan.
        Err(_) => {
            pending.full_rescan = true;
            pending.paths.clear();
            seen.clear();
            return;
        }
    };
    if event.need_rescan() {
        pending.full_rescan = true;
        pending.paths.clear();
        seen.clear();
        return;
    }
    if is_read_only_access(&event.kind) {
        return;
    }
    for path in event.paths {
        match classify(&path) {
            Classified::Ignored => {}
            Classified::GitMeta => pending.git_meta = true,
            Classified::Tree(dir) => {
                if pending.full_rescan {
                    continue;
                }
                if pending.paths.len() >= MAX_PATHS_PER_BATCH {
                    pending.full_rescan = true;
                    pending.paths.clear();
                    seen.clear();
                    continue;
                }
                if seen.insert(dir.clone()) {
                    pending.paths.push(dir);
                }
            }
        }
    }
}

/// Reading a directory is not a change to it — and on Linux, saying otherwise
/// is a closed loop. `notify`'s inotify backend watches `IN_OPEN`
/// (notify-8.2.0 `inotify.rs`, `WatchMask::OPEN`), so the name index's own
/// `read_dir` of a directory in a batch is reported back as that directory
/// changing, which produces the next batch, which re-walks it. Measured against
/// a Linux host: one lap per `DEBOUNCE` on an empty, untouched directory,
/// forever — and since the watch only retires on its idle tick, which never
/// fires while it is chattering, it never stops. Every batch also drives a
/// `git status` run (`git_loop`), so the cost lands on the user's box, not just
/// on the wire.
///
/// Closing a file after *writing* it (`IN_CLOSE_WRITE`) is a change and stays.
/// macOS never saw this: FSEvents does not report reads at all, which is why
/// the loop is invisible on the platform the daemon is developed on.
fn is_read_only_access(kind: &notify::EventKind) -> bool {
    use notify::event::{AccessKind, AccessMode};
    match kind {
        notify::EventKind::Access(AccessKind::Close(AccessMode::Write)) => false,
        notify::EventKind::Access(_) => true,
        _ => false,
    }
}

enum Classified {
    /// Version-control object churn — never interesting to any client.
    Ignored,
    /// Index / HEAD / refs moved: re-read git status, don't touch the tree.
    GitMeta,
    /// The containing directory whose listing changed.
    Tree(String),
}

fn classify(path: &Path) -> Classified {
    let mut in_vcs = false;
    for component in path.components() {
        let name = component.as_os_str().to_string_lossy();
        if name == ".git" || name == ".hg" || name == ".svn" {
            in_vcs = true;
            continue;
        }
        if in_vcs {
            // Object stores and packfiles churn constantly while an agent runs
            // git; VS Code excludes exactly these by default.
            if name == "objects" || name.ends_with(".pack") || name.ends_with(".idx") {
                return Classified::Ignored;
            }
        }
    }
    if in_vcs {
        return Classified::GitMeta;
    }
    let dir = if path.is_dir() {
        path.to_path_buf()
    } else {
        match path.parent() {
            Some(parent) => parent.to_path_buf(),
            None => return Classified::Ignored,
        }
    };
    Classified::Tree(dir.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn batch(paths: &[&str]) -> FsBatch {
        FsBatch {
            paths: paths.iter().map(|p| p.to_string()).collect(),
            ..FsBatch::default()
        }
    }

    #[test]
    fn git_object_churn_is_dropped_and_metadata_is_flagged() {
        assert!(matches!(
            classify(Path::new("/repo/.git/objects/ab/cdef")),
            Classified::Ignored
        ));
        assert!(matches!(
            classify(Path::new("/repo/.git/objects/pack/pack-1.pack")),
            Classified::Ignored
        ));
        assert!(matches!(
            classify(Path::new("/repo/.git/index")),
            Classified::GitMeta
        ));
        assert!(matches!(
            classify(Path::new("/repo/.git/refs/heads/main")),
            Classified::GitMeta
        ));
        match classify(Path::new("/repo/src/main.rs")) {
            Classified::Tree(dir) => assert_eq!(dir, "/repo/src"),
            _ => panic!("source files must reach the tree"),
        }
    }

    #[test]
    fn a_path_storm_degrades_to_full_rescan_instead_of_a_huge_batch() {
        let mut pending = FsBatch::default();
        let mut seen = std::collections::HashSet::new();
        for i in 0..(MAX_PATHS_PER_BATCH + 10) {
            let event = notify::Event::new(notify::EventKind::Any)
                .add_path(PathBuf::from(format!("/repo/dir{i}/file.txt")));
            absorb(Ok(event), &mut pending, &mut seen);
        }
        assert!(pending.full_rescan, "storm must set full_rescan");
        assert!(pending.paths.is_empty(), "paths are dropped once rescanning");
    }

    /// The index re-walks every directory a batch names, and on Linux that read
    /// comes back as an `IN_OPEN` on the same directory. Treating it as a change
    /// makes the watch feed itself forever, so a read must produce no batch at
    /// all — while a write that closes still must.
    #[test]
    fn reading_a_directory_is_not_a_change_but_closing_a_written_file_is() {
        use notify::event::{AccessKind, AccessMode};
        let mut pending = FsBatch::default();
        let mut seen = std::collections::HashSet::new();

        for kind in [
            notify::EventKind::Access(AccessKind::Open(AccessMode::Any)),
            notify::EventKind::Access(AccessKind::Read),
            notify::EventKind::Access(AccessKind::Close(AccessMode::Read)),
        ] {
            absorb(
                Ok(notify::Event::new(kind).add_path(PathBuf::from("/repo/src/main.rs"))),
                &mut pending,
                &mut seen,
            );
        }
        assert!(pending.paths.is_empty(), "a read is not a change");
        assert!(!pending.full_rescan);

        absorb(
            Ok(
                notify::Event::new(notify::EventKind::Access(AccessKind::Close(
                    AccessMode::Write,
                )))
                .add_path(PathBuf::from("/repo/src/main.rs")),
            ),
            &mut pending,
            &mut seen,
        );
        assert_eq!(pending.paths, vec!["/repo/src".to_string()]);
    }

    /// A watch with no OS watcher behind it, so the ring and replay rules can
    /// be exercised deterministically.
    fn headless() -> WatchState {
        WatchState {
            seq: 0,
            ring: VecDeque::new(),
            subscribers: HashMap::new(),
            idle_since: None,
            _watcher: None,
        }
    }

    fn seqs(events: &[Event]) -> Vec<u64> {
        events
            .iter()
            .map(|e| match e {
                Event::FsChanged { seq, .. } => *seq,
                _ => panic!("fs resources only emit fs_changed"),
            })
            .collect()
    }

    /// The load-bearing property: a resume inside the ring replays exactly, and
    /// a resume that has aged out reports a gap rather than silently skipping.
    #[test]
    fn replay_resumes_inside_the_ring_and_reports_a_gap_beyond_it() {
        let mut state = headless();
        for name in ["a", "b", "c"] {
            state.publish("fs:/repo", batch(&[&format!("/repo/{name}")]));
        }

        let (gap, replay) = state.resume("fs:/repo", Some(1));
        assert!(!gap, "a cursor inside the ring resumes");
        assert_eq!(seqs(&replay), vec![2, 3], "only newer batches replay");

        let (gap, replay) = state.resume("fs:/repo", Some(state.seq));
        assert!(!gap, "an up-to-date cursor resumes with nothing");
        assert!(replay.is_empty());

        let (gap, _) = state.resume("fs:/repo", Some(state.seq + 1));
        assert!(gap, "a cursor ahead of the host is a gap, not a rewind");

        let (gap, _) = state.resume("fs:/repo", None);
        assert!(gap, "a first subscribe has no baseline");

        for i in 0..RING_CAPACITY {
            state.publish("fs:/repo", batch(&[&format!("/repo/x{i}")]));
        }
        let (gap, _) = state.resume("fs:/repo", Some(1));
        assert!(gap, "an aged-out cursor must report a gap");
    }

    /// Detach ≠ kill on the resource plane: batches recorded while nobody is
    /// attached are exactly what the returning client replays. This is the
    /// property a live run caught missing — the watch used to die with its
    /// last subscriber, making "resumable" true only while someone watched.
    #[test]
    fn changes_while_detached_are_recorded_and_replayed_on_return() {
        let mut state = headless();
        let (tx, mut rx) = mpsc::unbounded_channel();
        state.subscribers.insert(ClientId::new("c_1"), tx);

        state.publish("fs:/repo", batch(&["/repo/attached"]));
        assert_eq!(rx.try_recv().map(|e| seqs(&[e])[0]).unwrap(), 1);

        // The client goes away; the agent keeps writing.
        state.subscribers.remove(&ClientId::new("c_1"));
        state.idle_since = Some(Instant::now());
        state.publish("fs:/repo", batch(&["/repo/while-gone-1"]));
        state.publish("fs:/repo", batch(&["/repo/while-gone-2"]));
        assert!(!state.expired(), "the watch lingers well inside LINGER");

        let (gap, replay) = state.resume("fs:/repo", Some(1));
        assert!(!gap, "the cursor is still inside the ring");
        assert_eq!(
            seqs(&replay),
            vec![2, 3],
            "both detached batches must replay"
        );
    }

    fn status_batch(session: &str, status: &str) -> StatusBatch {
        StatusBatch {
            session: session.to_string(),
            status: status.to_string(),
            source: Some("hook".to_string()),
            turn_ended: false,
            blocking: false,
            title: None,
            stalled: None,
        }
    }

    /// The `status:` resource is the same cursor/ring/gap machinery `fs:` and
    /// `git:` ride, which is the point of §C.10's one mechanism: a phone that
    /// locked mid-turn resumes where it left off instead of rescanning.
    #[tokio::test]
    async fn status_resumes_at_a_cursor_and_reports_a_gap_when_it_cannot() {
        let registry = Registry::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        let client = ClientId::new("phone");

        // Nothing published yet, so a first subscribe is honestly a gap.
        let first = registry
            .subscribe(STATUS_ID, client.clone(), tx.clone(), None)
            .expect("status takes no root to canonicalise");
        assert_eq!(first.seq, 0);
        assert!(first.gap);

        registry.publish_status(status_batch("s_1", "working"));
        registry.publish_status(status_batch("s_1", "done"));
        assert!(matches!(
            rx.recv().await,
            Some(Event::StatusChanged { seq: 1, .. })
        ));
        assert!(matches!(
            rx.recv().await,
            Some(Event::StatusChanged { seq: 2, .. })
        ));

        // The phone locks: its subscription goes, the ring keeps filling.
        registry.unsubscribe(STATUS_ID, &client);
        registry.publish_status(status_batch("s_2", "needs_you"));

        let (resumed_tx, mut resumed_rx) = mpsc::unbounded_channel();
        let resumed = registry
            .subscribe(STATUS_ID, client.clone(), resumed_tx, Some(2))
            .expect("resume");
        assert!(!resumed.gap, "a cursor inside the ring is not a gap");
        assert_eq!(resumed.seq, 3);
        // Delivered on the subscriber's own channel rather than handed back,
        // which is what keeps a live batch from overtaking it.
        assert!(matches!(
            resumed_rx.try_recv(),
            Ok(Event::StatusChanged { seq: 3, .. })
        ));
        assert!(resumed_rx.try_recv().is_err(), "only what it missed");

        // A cursor ahead of the host is nonsense, and says so rather than
        // silently replaying nothing.
        let (ahead_tx, _ahead_rx) = mpsc::unbounded_channel();
        let ahead = registry
            .subscribe(STATUS_ID, ClientId::new("other"), ahead_tx, Some(99))
            .expect("subscribe");
        assert!(ahead.gap);
    }

    /// The bug this exists for: the subscriber used to be installed under the
    /// resource lock while its replay was queued *after* the lock was
    /// released, so a batch published in between reached it first. The client
    /// then applied 11, and 9 and 10 landed on top of it — a session's status
    /// silently rolled backwards.
    ///
    /// Ordering is asserted from the subscriber's own channel, because that is
    /// the only place the two streams meet.
    #[tokio::test]
    async fn a_live_batch_cannot_overtake_the_replay_a_subscriber_is_owed() {
        let registry = Registry::new();
        let (warm_tx, _warm_rx) = mpsc::unbounded_channel();
        // Somebody has to be subscribed for the ring to exist at all.
        registry
            .subscribe(STATUS_ID, ClientId::new("warm"), warm_tx, None)
            .expect("subscribe");
        registry.publish_status(status_batch("s_1", "working"));
        registry.publish_status(status_batch("s_1", "idle"));

        let (tx, mut rx) = mpsc::unbounded_channel();
        let reply = registry
            .subscribe(STATUS_ID, ClientId::new("phone"), tx, Some(0))
            .expect("resume from the start of the ring");
        assert!(!reply.gap);
        assert_eq!(reply.seq, 2);

        // The instant the subscription exists, a live batch is published. It
        // must land behind the two it is owed, not in front of them.
        registry.publish_status(status_batch("s_2", "needs_you"));

        let mut seqs = Vec::new();
        while let Ok(Some(event)) = tokio::time::timeout(
            std::time::Duration::from_millis(50),
            rx.recv(),
        )
        .await
        {
            if let Event::StatusChanged { seq, .. } = event {
                seqs.push(seq);
            }
        }
        assert_eq!(seqs, vec![1, 2, 3], "the replay must precede the live batch");
    }

    /// A subscriber that asks for everything gets the ring in order, and the
    /// seq it is handed is the last one *in* that run — so a client that
    /// applies them all can adopt it, and one that does not must not.
    #[tokio::test]
    async fn the_ack_seq_names_the_end_of_the_replay_it_is_handed() {
        let registry = Registry::new();
        let (warm_tx, _warm_rx) = mpsc::unbounded_channel();
        registry
            .subscribe(STATUS_ID, ClientId::new("warm"), warm_tx, None)
            .expect("subscribe");
        for status in ["working", "idle", "working"] {
            registry.publish_status(status_batch("s_1", status));
        }

        let (tx, mut rx) = mpsc::unbounded_channel();
        let reply = registry
            .subscribe(STATUS_ID, ClientId::new("phone"), tx, Some(1))
            .expect("resume");

        assert_eq!(reply.seq, 3);
        let mut seqs = Vec::new();
        while let Ok(event) = rx.try_recv() {
            if let Event::StatusChanged { seq, .. } = event {
                seqs.push(seq);
            }
        }
        assert_eq!(seqs, vec![2, 3], "exactly what the cursor had not seen");
    }

    /// Publishing before anyone has ever asked must not conjure a ring: there is
    /// no cursor to resume from, and the status reached every attached client on
    /// its own channel regardless.
    #[test]
    fn publishing_with_no_subscriber_ever_is_a_no_op() {
        let registry = Registry::new();
        registry.publish_status(status_batch("s_1", "working"));

        let (tx, _rx) = mpsc::unbounded_channel();
        let reply = registry
            .subscribe(STATUS_ID, ClientId::new("late"), tx, None)
            .expect("subscribe");
        assert_eq!(reply.seq, 0);
        assert!(reply.gap);
    }
}
