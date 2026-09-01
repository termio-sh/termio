//! The file request plane (§C.12): the **pull side** of the resource story.
//!
//! §C.10's `fs:` resources push change notification; this module answers the
//! reads — directory listings and file content. The posture is lazy + cached
//! + predictive, never a client replica: attach costs one listing, and
//! freshness is proven by the `fs:` resource cursor stamped on every reply
//! rather than guessed by TTL.
//!
//! Everything here is plain blocking filesystem code. The daemon calls it via
//! `spawn_blocking`, so a huge directory never parks other connections — and
//! nothing here can touch the terminal hot path by construction, because it
//! only ever runs on control channels.

use crate::id::SessionId;
use crate::protocol::{DirEntry, EntryKind, PathListing};
use anyhow::{anyhow, bail, Context, Result};
use std::path::{Component, Path, PathBuf};

/// Entries per `fs.list` page (§C.12: "pages capped (~2,000 entries)").
pub const LIST_PAGE_SIZE: usize = 2000;

/// `fs.read` soft cap: preview parity with the companion's 1 MiB budget.
pub const READ_SOFT_CAP: u64 = 1024 * 1024;

/// Directory names the host never walks on its own. These are the watcher's
/// ignore rules (`resource.rs::classify`) seen from the pull side: what the
/// watcher drops, the lister stubs as `unloaded_dir`.
/// A file's modification time in whole seconds, or 0 when the host cannot say.
/// Whole seconds because that is what the listing has always reported and what
/// every filesystem here agrees on; sub-second precision differs by filesystem
/// and would make a version comparison fail for reasons that have nothing to do
/// with the file changing.
fn mtime_seconds(metadata: &std::fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn is_unloaded_dir_name(name: &str) -> bool {
    name == ".git" || name == ".hg" || name == ".svn"
}

/// Canonicalise a workspace root. The root anchors confinement for every
/// path in the request, so it must resolve and be a directory.
pub fn canonical_root(root: &str) -> Result<PathBuf> {
    let path = Path::new(root);
    if !path.is_absolute() {
        bail!("workspace root must be absolute: {root}");
    }
    let canonical =
        std::fs::canonicalize(path).with_context(|| format!("resolving workspace root {root}"))?;
    if !canonical.is_dir() {
        bail!("workspace root is not a directory: {root}");
    }
    Ok(canonical)
}

/// Resolve one requested path against the canonical root and confine it:
/// no `..` components, and the canonicalised result must stay under the
/// root (which also rejects symlink escapes, because canonicalising
/// resolves the links first).
fn confine(root: &Path, requested: &str) -> Result<PathBuf> {
    let raw = Path::new(requested);
    if raw
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        bail!("path escapes the workspace root: {requested}");
    }
    let joined = if raw.is_absolute() {
        raw.to_path_buf()
    } else {
        root.join(raw)
    };
    let canonical =
        std::fs::canonicalize(&joined).with_context(|| format!("resolving {requested}"))?;
    if !canonical.starts_with(root) {
        bail!("path escapes the workspace root: {requested}");
    }
    Ok(canonical)
}

/// What a symlink resolves to, but only while the target stays under the root.
///
/// The listing itself never follows a link — `lstat`, not `stat`, because
/// following is how a listing walks out of the workspace. This is the one fact
/// about the target a tree still needs: the Finder and the VS Code explorer
/// both draw a link to a directory as a directory, and a client that could not
/// tell would draw this repo's own `.claude/skills` as an inert row.
///
/// Confined for the same reason the answer is useful: `confine` canonicalises
/// before it lists, so a link pointing out of the root would be refused on the
/// click that followed the disclosure triangle. Reporting `None` there is what
/// keeps the tree from offering a control the device will not honour.
fn confined_target_kind(root: &Path, link: &Path) -> Option<EntryKind> {
    let resolved = std::fs::canonicalize(link).ok()?;
    if !resolved.starts_with(root) {
        return None;
    }
    let metadata = std::fs::metadata(&resolved).ok()?;
    if metadata.is_dir() {
        let unloaded = resolved
            .file_name()
            .is_some_and(|name| is_unloaded_dir_name(&name.to_string_lossy()));
        Some(if unloaded {
            EntryKind::UnloadedDir
        } else {
            EntryKind::Dir
        })
    } else if metadata.is_file() {
        Some(EntryKind::File)
    } else {
        None
    }
}

/// List a batch of directories under `root`, one page per path.
///
/// `after` resumes a directory too large for one page at the entry following
/// that name — a **keyset** cursor, not an offset. A directory being written
/// while it is read is the ordinary case here (an agent is working in it), and
/// an offset shifts under every insert and delete before it: the client would
/// see one entry twice and never see another, with nothing in the reply saying
/// so. Resuming at a name cannot shift. What a concurrent write can still cost
/// is an entry that appeared *behind* the cursor, and that is what the `fs:`
/// batch the same write raises is for.
pub fn list(root: &str, paths: &[String], after: Option<&str>) -> Result<Vec<PathListing>> {
    list_with_page_size(root, paths, after, LIST_PAGE_SIZE)
}

fn list_with_page_size(
    root: &str,
    paths: &[String],
    after: Option<&str>,
    page_size: usize,
) -> Result<Vec<PathListing>> {
    let root = canonical_root(root)?;
    // A batched, speculative request must not be all-or-nothing: one child
    // that vanished between render and click fails alone.
    Ok(paths
        .iter()
        .map(|requested| match list_one(&root, requested, after, page_size) {
            Ok(listing) => listing,
            Err(error) => PathListing {
                path: requested.clone(),
                entries: Vec::new(),
                next_after: None,
                error: Some(format!("{error:#}")),
            },
        })
        .collect())
}

fn list_one(
    root: &Path,
    requested: &str,
    after: Option<&str>,
    page_size: usize,
) -> Result<PathListing> {
    let dir = confine(root, requested)?;
    if !dir.is_dir() {
        bail!("not a directory: {requested}");
    }

    let mut entries: Vec<DirEntry> = Vec::new();
    for item in std::fs::read_dir(&dir).with_context(|| format!("listing {requested}"))? {
        let item = match item {
            Ok(item) => item,
            Err(_) => continue,
        };
        let name = item.file_name().to_string_lossy().into_owned();
        // lstat, not stat: a symlink is reported as itself, never followed —
        // following is how a listing walks out of the workspace.
        let Ok(metadata) = std::fs::symlink_metadata(item.path()) else {
            continue;
        };
        let mtime = mtime_seconds(&metadata);
        let (kind, symlink_target, target_kind) = if metadata.file_type().is_symlink() {
            let target = std::fs::read_link(item.path())
                .ok()
                .map(|target| target.display().to_string());
            (EntryKind::Symlink, target, confined_target_kind(root, &item.path()))
        } else if metadata.is_dir() {
            if is_unloaded_dir_name(&name) {
                (EntryKind::UnloadedDir, None, None)
            } else {
                (EntryKind::Dir, None, None)
            }
        } else {
            (EntryKind::File, None, None)
        };
        entries.push(DirEntry {
            name,
            kind,
            size: metadata.len(),
            mtime,
            symlink_target,
            target_kind,
        });
    }

    // A stable order is what makes the keyset cursor meaningful across two
    // requests: `after` names a point in this order, not a count into it.
    entries.sort_by(|a, b| a.name.cmp(&b.name));

    // Everything strictly after the cursor. Strictly, so an entry can never be
    // served twice; and by name, so a delete or an insert ahead of the cursor
    // moves nothing that has already been read.
    let start = match after {
        Some(after) => entries.partition_point(|entry| entry.name.as_str() <= after),
        None => 0,
    };
    let end = start.saturating_add(page_size).min(entries.len());
    let next_after = if end < entries.len() {
        entries.get(end.saturating_sub(1)).map(|entry| entry.name.clone())
    } else {
        None
    };
    Ok(PathListing {
        path: requested.to_string(),
        entries: entries[start..end].to_vec(),
        next_after,
        error: None,
    })
}

/// A served `fs.read` window: the header fields plus the bytes themselves.
pub struct FileWindow {
    pub size: u64,
    pub offset: u64,
    pub truncated: bool,
    /// Seconds since the epoch, as the host sees them. This is the *version* a
    /// reader holds: an editor that means to write the file back sends it to
    /// `commit` as `if_unmodified_since`, and that is the whole of the
    /// lost-update check. Zero when the host could not read a timestamp, which
    /// a writer must treat as "no version" rather than as "epoch".
    pub mtime: u64,
    pub data: Vec<u8>,
}

/// Read a window of a regular file, applying the 1 MiB soft cap. `truncated`
/// is set exactly when the served window stops short of what was asked —
/// the whole file when no range was given, the requested length otherwise.
pub fn read(path: &str, offset: Option<u64>, length: Option<u64>) -> Result<FileWindow> {
    read_with_cap(path, offset, length, READ_SOFT_CAP)
}

fn read_with_cap(
    path: &str,
    offset: Option<u64>,
    length: Option<u64>,
    cap: u64,
) -> Result<FileWindow> {
    let raw = Path::new(path);
    if !raw.is_absolute() {
        bail!("file path must be absolute: {path}");
    }
    let canonical = std::fs::canonicalize(raw).with_context(|| format!("resolving {path}"))?;
    let metadata =
        std::fs::metadata(&canonical).with_context(|| format!("inspecting {path}"))?;
    if !metadata.is_file() {
        bail!("not a regular file: {path}");
    }
    let size = metadata.len();
    let start = offset.unwrap_or(0).min(size);
    let asked = length.unwrap_or(u64::MAX).min(size - start);
    let serve = asked.min(cap);

    use std::io::{Read, Seek, SeekFrom};
    let mut file =
        std::fs::File::open(&canonical).with_context(|| format!("opening {path}"))?;
    file.seek(SeekFrom::Start(start))
        .with_context(|| format!("seeking {path}"))?;
    let mut data = vec![
        0u8;
        usize::try_from(serve).map_err(|_| anyhow!("read window exceeds memory"))?
    ];
    file.read_exact(&mut data)
        .with_context(|| format!("reading {path}"))?;

    Ok(FileWindow {
        size,
        offset: start,
        truncated: serve < asked,
        mtime: mtime_seconds(&metadata),
        data,
    })
}

/// The lazy, paths-only name index behind `fs.match` (§C.12). Built at idle
/// priority after a workspace's first subscribe, kept incremental by the
/// watcher's batches, evicted with the watch. It is a cache of names, never
/// correctness-bearing — `coverage` tells the client how much of the tree it
/// has seen so "still indexing" is honest instead of silently incomplete.
pub struct NameIndex {
    root: PathBuf,
    inner: std::sync::Mutex<IndexInner>,
}

#[derive(Default)]
struct IndexInner {
    /// Files per directory (absolute dir → file names). Per-dir granularity is
    /// what makes watcher batches cheap to apply: one changed dir = one
    /// re-list, not a walk.
    dirs: std::collections::HashMap<PathBuf, Vec<String>>,
    walked_dirs: usize,
    pending_dirs: usize,
    complete: bool,
}

impl NameIndex {
    pub fn new(root: PathBuf) -> NameIndex {
        NameIndex {
            root,
            inner: std::sync::Mutex::new(IndexInner::default()),
        }
    }

    /// Walk the tree breadth-first, yielding between directories so the build
    /// stays idle-priority work. Skips symlinks (external escape) and the
    /// watcher's ignored dirs — the "never walk them" invariant.
    pub async fn build(&self) {
        {
            let mut inner = self.inner.lock().unwrap();
            inner.dirs.clear();
            inner.walked_dirs = 0;
            inner.pending_dirs = 1;
            inner.complete = false;
        }
        let mut frontier = std::collections::VecDeque::from([self.root.clone()]);
        while let Some(dir) = frontier.pop_front() {
            let (files, subdirs) = list_index_dir(&dir);
            {
                let mut inner = self.inner.lock().unwrap();
                inner.dirs.insert(dir, files);
                inner.walked_dirs += 1;
                inner.pending_dirs = inner.pending_dirs.saturating_sub(1) + subdirs.len();
            }
            frontier.extend(subdirs);
            tokio::task::yield_now().await;
        }
        self.inner.lock().unwrap().complete = true;
    }

    /// Apply one watcher batch: re-list exactly the named directories and
    /// prune index entries beneath any that vanished. `full_rescan`
    /// invalidates everything; the caller rebuilds instead. All IO happens
    /// outside the lock so `fs.match` never waits on the filesystem.
    pub fn apply(&self, changed_dirs: &[String]) {
        for changed in changed_dirs {
            let dir = PathBuf::from(changed);
            if !dir.starts_with(&self.root) {
                continue;
            }
            if dir
                .file_name()
                .is_some_and(|name| is_unloaded_dir_name(&name.to_string_lossy()))
            {
                continue;
            }
            if dir.is_dir() {
                let (files, subdirs) = list_index_dir(&dir);
                // A freshly created subtree names only the dirs that received
                // entries; unseen children get one level here and name their
                // own children in the batches their contents raised.
                let unseen: Vec<PathBuf> = {
                    let inner = self.inner.lock().unwrap();
                    subdirs
                        .into_iter()
                        .filter(|subdir| !inner.dirs.contains_key(subdir))
                        .collect()
                };
                let listed: Vec<(PathBuf, Vec<String>)> = unseen
                    .into_iter()
                    .map(|subdir| {
                        let (files, _) = list_index_dir(&subdir);
                        (subdir, files)
                    })
                    .collect();
                let mut inner = self.inner.lock().unwrap();
                inner.dirs.insert(dir.clone(), files);
                for (subdir, files) in listed {
                    inner.dirs.insert(subdir, files);
                }
            } else {
                // The dir is gone; everything indexed beneath it is stale.
                self.inner
                    .lock()
                    .unwrap()
                    .dirs
                    .retain(|indexed, _| !indexed.starts_with(&dir));
            }
        }
    }

    pub fn coverage(&self) -> f32 {
        let inner = self.inner.lock().unwrap();
        if inner.complete {
            return 1.0;
        }
        let walked = inner.walked_dirs as f32;
        let pending = inner.pending_dirs as f32;
        if walked + pending == 0.0 {
            return 0.0;
        }
        walked / (walked + pending)
    }

    /// Best `limit` workspace-relative matches for `query`, plus coverage.
    ///
    /// Scored in two batched passes — basenames, then whole relative paths —
    /// because that is where frizbee's SIMD earns anything: one `match_list`
    /// over every candidate vectorizes, where a per-file call would not.
    pub fn matches(&self, query: &str, limit: usize) -> (Vec<String>, f32) {
        let inner = self.inner.lock().unwrap();
        let mut relatives: Vec<String> = Vec::new();
        let mut basenames: Vec<&str> = Vec::new();
        for (dir, files) in inner.dirs.iter() {
            let prefix = dir
                .strip_prefix(&self.root)
                .unwrap_or(dir)
                .to_string_lossy()
                .into_owned();
            for name in files {
                relatives.push(if prefix.is_empty() {
                    name.clone()
                } else {
                    format!("{prefix}/{name}")
                });
                basenames.push(name);
            }
        }

        // An empty query is not a match at all — it is "show me the tree",
        // shortest first, which is what the picker opens on.
        if query.is_empty() {
            let mut all: Vec<String> = relatives;
            all.sort_by(|a, b| a.len().cmp(&b.len()).then_with(|| a.cmp(b)));
            all.truncate(limit);
            drop(inner);
            return (all, self.coverage());
        }

        let mut scores = vec![None::<i64>; relatives.len()];
        // `Ignore`, not frizbee's default `Smart`: the scorer this replaced
        // lowercased both sides, so smart-case would silently stop `Main` from
        // finding `main.rs`. Smart-case is a product decision, not a side
        // effect of changing matchers.
        let config = frizbee::Config::default().casing(frizbee::CaseMatching::Ignore);
        let mut matcher = frizbee::Matcher::new(query, &config);
        // Path pass first, so a basename hit overwrites it: a name match must
        // outrank any path match, which is the ordering the picker is judged on.
        for hit in matcher.match_list(&relatives) {
            scores[hit.index as usize] = Some(hit.score as i64);
        }
        for hit in matcher.match_list(&basenames) {
            scores[hit.index as usize] = Some(BASENAME_BAND + hit.score as i64);
        }
        drop(inner);

        let mut scored: Vec<(i64, String)> = relatives
            .into_iter()
            .zip(scores)
            .filter_map(|(relative, score)| {
                // Shorter paths win ties, as they did before frizbee: the band
                // is far wider than any path length, so this can never demote a
                // basename hit below a path hit.
                score.map(|score| (score - relative.len() as i64, relative))
            })
            .collect();
        scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        scored.truncate(limit);
        (
            scored.into_iter().map(|(_, path)| path).collect(),
            self.coverage(),
        )
    }
}

/// Bind a name index to a workspace watch: build lazily at idle priority,
/// then apply the watcher's batches as they arrive. The watch owns the
/// sender; when the watch retires, the task ends and the index memory goes
/// with it — evictable by construction.
pub fn spawn_index(
    root: PathBuf,
) -> (
    std::sync::Arc<NameIndex>,
    tokio::sync::mpsc::UnboundedSender<crate::resource::FsBatch>,
) {
    let index = std::sync::Arc::new(NameIndex::new(root));
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<crate::resource::FsBatch>();
    let worker = index.clone();
    tokio::spawn(async move {
        worker.build().await;
        while let Some(batch) = rx.recv().await {
            if batch.full_rescan {
                worker.build().await;
            } else if !batch.paths.is_empty() {
                let apply_on = worker.clone();
                let _ =
                    tokio::task::spawn_blocking(move || apply_on.apply(&batch.paths)).await;
            }
        }
    });
    (index, tx)
}

fn list_index_dir(dir: &Path) -> (Vec<String>, Vec<PathBuf>) {
    let mut files = Vec::new();
    let mut subdirs = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return (files, subdirs);
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(metadata) = std::fs::symlink_metadata(entry.path()) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            if !is_unloaded_dir_name(&name) {
                subdirs.push(entry.path());
            }
        } else if metadata.is_file() {
            files.push(name);
        }
    }
    (files, subdirs)
}

/// Filename fuzzy score: higher is better, `None` is no match. Substring
/// beats subsequence, the basename beats the full path, and shorter paths
/// win ties — the ⌘⇧O ranking, kept simple enough to be deterministic.
/// Separates a basename hit from a path hit. frizbee scores are `u16`, and a
/// path cannot exceed `PATH_MAX`, so this band is wide enough that no score
/// plus no length penalty can ever carry a path match over a name match.
const BASENAME_BAND: i64 = 1_000_000;

/// Long minified lines would bloat a `search_results` event; the match is
/// findable from far less.
const SEARCH_TEXT_CAP: usize = 512;

/// How much of a long line to keep before the first match, so the hit does not
/// sit flush against the left edge of the window.
const SEARCH_WINDOW_LEAD: usize = 64;

/// Matches per `search_results` event — small enough to render as they arrive,
/// large enough that a big result set is not one event per line.
pub const SEARCH_BATCH: usize = 50;

/// Lines of context on each side of a hit. Two is what reads as an excerpt
/// without the results pane turning into the file.
pub const SEARCH_CONTEXT_LINES: usize = 2;

/// How much of a file decides whether it is binary. `git grep -I` looks at the
/// first 8000 bytes for a NUL and skips the whole file when it finds one; this
/// search kept that rule rather than ripgrep's "stop at the first NUL", because
/// stopping mid-file emits the text that preceded the NUL as ordinary hits.
const BINARY_PROBE: usize = 8000;

/// Ceiling on what one file may cost the searcher. A line longer than this is
/// not searched at all — the file is skipped and the walk continues. Without it
/// a single minified blob with no line terminator decides how much memory the
/// daemon allocates, and the daemon hosts live sessions.
const SEARCH_HEAP_LIMIT: usize = 32 * 1024 * 1024;

/// What one `fs.search` run ended up doing. The counts are the daemon's — it
/// reports them in the terminal `fs_searched` reply.
pub struct SearchOutcome {
    pub matches: u64,
    pub limit_hit: bool,
    pub canceled: bool,
}

/// A fixed-string matcher over the query, folded the same ASCII way the spans
/// are. Fixed strings rather than a regex because that is what the wire has
/// always promised: a query is text the user typed, not a pattern, so a stray
/// `(` cannot turn a search into a syntax error.
struct LiteralMatcher {
    finder: aho_corasick::AhoCorasick,
}

impl grep_matcher::Matcher for LiteralMatcher {
    type Captures = grep_matcher::NoCaptures;
    type Error = grep_matcher::NoError;

    fn find_at(
        &self,
        haystack: &[u8],
        at: usize,
    ) -> Result<Option<grep_matcher::Match>, grep_matcher::NoError> {
        // A plain literal has no anchors and no look-around, so searching the
        // suffix is the same answer as searching the whole line from `at`.
        Ok(self
            .finder
            .find(&haystack[at..])
            .map(|found| grep_matcher::Match::new(at + found.start(), at + found.end())))
    }

    fn new_captures(&self) -> Result<Self::Captures, grep_matcher::NoError> {
        Ok(grep_matcher::NoCaptures::new())
    }
}

/// Search `root` for `query`, handing finished batches to `emit` as they fill.
///
/// Blocking by construction — the daemon runs it on a blocking thread, which is
/// also what keeps a pathological file off the runtime. `cancel` is read at
/// every file and every reported line, so an abandoned search stops within one
/// file rather than running the tree to completion.
///
/// The domain is what `git grep --untracked` covered: tracked and untracked
/// files that no ignore rule excludes, `.git` never walked, binary files
/// skipped. The rules come from the `ignore` crate reading `.gitignore`, the
/// global excludes file and `.git/info/exclude` — the same inputs git reads,
/// re-implemented rather than asked, so the two can disagree in corner cases.
pub fn search(
    root: &Path,
    query: &str,
    limit: u64,
    cancel: &std::sync::atomic::AtomicBool,
    emit: &mut dyn FnMut(Vec<crate::protocol::SearchMatch>),
) -> SearchOutcome {
    use std::sync::atomic::Ordering;

    // A stall directory makes this search take a fixed time while staying
    // cancellable — the integration tests' stand-in for the enormous checkout
    // they cannot afford to create, now that there is no `git grep` subprocess
    // left to shim. Absent outside a test harness, this costs one env lookup.
    if let Some(stall) = std::env::var_os("TERMIOD_TEST_SEARCH_STALL") {
        let stall = Path::new(&stall);
        let seconds = std::fs::read_to_string(stall.join("seconds"))
            .ok()
            .and_then(|value| value.trim().parse::<f64>().ok())
            .unwrap_or(0.0);
        if seconds > 0.0 {
            let _ = std::fs::write(stall.join("started"), b"");
            let deadline =
                std::time::Instant::now() + std::time::Duration::from_secs_f64(seconds);
            while std::time::Instant::now() < deadline {
                if cancel.load(Ordering::Relaxed) {
                    // The marker is the host's own record that the walk was
                    // stopped, not merely abandoned by its client.
                    let _ = std::fs::write(stall.join("canceled"), b"");
                    return SearchOutcome { matches: 0, limit_hit: false, canceled: true };
                }
                std::thread::sleep(std::time::Duration::from_millis(25));
            }
            let _ = std::fs::write(stall.join("finished"), b"");
        }
    }

    // An empty query has no literal to look for. `git grep -e ""` answered it
    // by matching every line in the tree, which is the whole repo streamed back
    // with nothing to highlight; no result is the more useful reading and the
    // one clients already assume, since they refuse to send it.
    // A query spanning lines has nothing a line-oriented literal search can
    // match, which is also what ripgrep answers without `-U`.
    if query.is_empty() || limit == 0 || query.contains(['\n', '\r']) {
        return SearchOutcome { matches: 0, limit_hit: false, canceled: false };
    }

    // Smart case, the fzf/ripgrep default every client already expects: an
    // all-lowercase query matches insensitively, and one uppercase letter opts
    // back into exactness. Decided from the query itself rather than a flag on
    // the wire, so a client cannot ask two hosts for the same search and get two
    // different answers.
    let insensitive = query == query.to_lowercase();
    let finder = aho_corasick::AhoCorasickBuilder::new()
        .ascii_case_insensitive(insensitive)
        .build([query.as_bytes()]);
    let Ok(finder) = finder else {
        return SearchOutcome { matches: 0, limit_hit: false, canceled: false };
    };
    let matcher = LiteralMatcher { finder };

    let mut searcher = grep_searcher::SearcherBuilder::new()
        .line_number(true)
        .before_context(SEARCH_CONTEXT_LINES)
        .after_context(SEARCH_CONTEXT_LINES)
        // The probe below already decided the file is text, so the searcher does
        // not get a second, different opinion about it.
        .binary_detection(grep_searcher::BinaryDetection::none())
        // Also what turns memory maps off: a bounded buffer is the point.
        .heap_limit(Some(SEARCH_HEAP_LIMIT))
        .build();

    let mut collector = Collector {
        query,
        insensitive,
        limit,
        cancel,
        emit,
        path: String::new(),
        pending: Vec::new(),
        before: std::collections::VecDeque::new(),
        trailing: None,
        streamed: 0,
        limit_hit: false,
        canceled: false,
    };

    let mut walker = ignore::WalkBuilder::new(root);
    walker
        // git has no notion of a hidden file: a tracked `.env` is searched and
        // an untracked one is too. Only `.git` itself is off limits.
        .hidden(false)
        // `.ignore` and `.rgignore` are ripgrep's own files, not git's.
        .ignore(false)
        .git_ignore(true)
        // `.git/info/exclude` stays the crate's job: it resolves `.git` as a
        // file too (a linked worktree's `commondir`), and its matcher is rooted
        // at the repository, so an anchored `/target` still anchors.
        .git_exclude(true)
        // The global excludes file is not: see `global_excludes`.
        .git_global(false)
        .parents(true)
        .follow_links(false)
        // Deterministic order, which also means single-threaded. Results stream
        // as they are found, and a client that renders them in arrival order
        // should not see a different pane on every keystroke.
        .sort_by_file_path(|a, b| a.cmp(b))
        // What `add_ignore` roots its matcher at. Without it the crate reaches
        // for the *process's* working directory, and a global `/root-only.txt`
        // would anchor wherever the daemon happened to be launched instead of
        // at the tree being searched. git anchors it at the top of the working
        // tree; so does this.
        .current_dir(root)
        .filter_entry(|entry| entry.file_name() != ".git");
    // Lower precedence than every ignore file in the tree, which is where git
    // puts it (`add_ignore` is the last matcher consulted).
    if let Some(global) = global_excludes(root) {
        walker.add_ignore(global);
    }

    for entry in walker.build() {
        if cancel.load(Ordering::Relaxed) {
            collector.canceled = true;
            break;
        }
        // A directory that cannot be read, a file that vanished mid-walk: the
        // rest of the tree is still worth searching. `git grep` skipped these
        // onto a stderr nobody read.
        let Ok(entry) = entry else { continue };
        if !entry.file_type().is_some_and(|kind| kind.is_file()) {
            continue;
        }
        let path = entry.path();
        let Some(relative) = path.strip_prefix(root).ok().and_then(|p| p.to_str()) else {
            continue;
        };
        let Some(file) = open_text(path) else { continue };
        collector.begin_file(relative);
        // A file the searcher refuses — a line past the heap limit, a read that
        // failed — is one file, not the search.
        let _ = searcher.search_file(&matcher, &file, &mut collector);
        if collector.limit_hit || collector.canceled {
            break;
        }
    }

    collector.finish()
}

/// The global excludes file git would apply to `root`, or nothing.
///
/// Asked of git rather than parsed here, because `core.excludesFile` is not a
/// value sitting in one file: it comes off a config stack — system, XDG,
/// `~/.gitconfig`, the repository — that `[include]` and `[includeIf]` can
/// redirect, and the value itself may be a quoted path with spaces in it
/// (`"~/Library/Application Support/git/ignore"` is what a Mac writes). The
/// `ignore` crate reads that with one regex and says so in its own source:
/// "this is the lazy approach, and isn't technically correct". A path with a
/// space in it comes back truncated, which silently drops every rule in the
/// file. `git config --path` resolves the whole stack and expands `~`, and git
/// is already the authority for the tree being searched.
///
/// A root outside a repository gets none: git applies no excludes to a
/// directory it does not own, and neither does this. Same answer when git is
/// missing altogether, which is a box this search still has to work on.
fn global_excludes(root: &Path) -> Option<PathBuf> {
    resolve_global_excludes(root, default_excludes_file)
}

/// `global_excludes` with git's default path handed in, so all three answers
/// can be pinned without a test having to move the process's environment out
/// from under every other thread in it.
fn resolve_global_excludes(
    root: &Path,
    fallback: impl FnOnce() -> Option<PathBuf>,
) -> Option<PathBuf> {
    // Doubles as the repository test: outside one, `rev-parse` fails.
    git_says(root, &["rev-parse", "--git-dir"])?;
    match git_says(root, &["config", "--path", "--get", "core.excludesFile"]).as_deref() {
        // Set to the empty string. git reads that as "no global excludes at
        // all" and does *not* fall back to its default — the setting exists to
        // be turned off. `git config` reports it as success with empty output,
        // which is the only thing separating it from the key being absent.
        Some("") => None,
        Some(configured) => Some(PathBuf::from(configured)),
        // Absent, so git's own default applies.
        None => fallback(),
    }
    // Both answers can come back relative — `git config --path` hands back what
    // the config holds, and `XDG_CONFIG_HOME` may hold a relative path git will
    // happily use. Relative to git's working directory, which is `root`: that
    // is the `-C` this module runs git under. Anchoring it here is what keeps a
    // relative path from resolving against wherever the daemon was launched.
    // `join` leaves an absolute path alone, so this costs the normal case
    // nothing.
    .map(|path| root.join(path))
}

/// Where git looks when `core.excludesFile` is not set at all. A fixed path
/// rather than a parsed value — naming it here reimplements nothing.
fn default_excludes_file() -> Option<PathBuf> {
    excludes_default_from(
        std::env::var_os("XDG_CONFIG_HOME"),
        std::env::var_os("HOME"),
    )
}

/// git's rule, with the environment handed in so it can be pinned without a
/// test moving the process's own out from under every thread in it.
///
/// `XDG_CONFIG_HOME` wins whenever it is set and not empty — *including* when
/// it holds a relative path, which the XDG spec says to ignore and git uses
/// anyway (`path.c`, `xdg_config_home`: `if (config_home && *config_home)`,
/// with no test for absoluteness). `HOME` is consulted only when it is not,
/// and setting `XDG_CONFIG_HOME` to something relative therefore turns the
/// `HOME` default off rather than falling back to it. Relative to what is the
/// caller's problem: `resolve_global_excludes` anchors it where git had its
/// working directory.
fn excludes_default_from(
    xdg_config_home: Option<std::ffi::OsString>,
    home: Option<std::ffi::OsString>,
) -> Option<PathBuf> {
    match xdg_config_home {
        Some(base) if !base.is_empty() => Some(PathBuf::from(base).join("git/ignore")),
        _ => Some(PathBuf::from(home?).join(".config/git/ignore")),
    }
}

/// What git printed, trimmed of its trailing newline, or nothing if git
/// refused, is not installed, or was not asked from inside a repository.
///
/// An empty string is a real answer here rather than an absence — see
/// `resolve_global_excludes`, where the difference is the whole point.
fn git_says(root: &Path, args: &[&str]) -> Option<String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        // Nothing here may sit waiting for a human: this runs on a search
        // thread, and a credential prompt would park it until the client's
        // idle bound gave up.
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    Some(text.trim_end_matches(['\n', '\r']).to_string())
}

/// Opens `path` only if it reads as text, positioned back at the start so the
/// searcher can have it. One open for both jobs: the probe is the same read the
/// searcher would have done first anyway.
fn open_text(path: &Path) -> Option<std::fs::File> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let mut probe = [0u8; BINARY_PROBE];
    let mut filled = 0;
    while filled < probe.len() {
        match file.read(&mut probe[filled..]) {
            Ok(0) => break,
            Ok(read) => filled += read,
            Err(_) => return None,
        }
    }
    if probe[..filled].contains(&0) {
        return None;
    }
    file.seek(SeekFrom::Start(0)).ok()?;
    Some(file)
}

/// Turns the searcher's per-line callbacks into the batches the wire carries.
///
/// The state is the shape `git grep -C` output forced and the clients now
/// expect: context banked before a hit belongs to it, the same lines after a
/// hit belong to the hit above, and a break between runs retires both.
struct Collector<'a> {
    query: &'a str,
    insensitive: bool,
    limit: u64,
    cancel: &'a std::sync::atomic::AtomicBool,
    emit: &'a mut dyn FnMut(Vec<crate::protocol::SearchMatch>),
    path: String,
    pending: Vec<crate::protocol::SearchMatch>,
    before: std::collections::VecDeque<String>,
    trailing: Option<usize>,
    streamed: u64,
    limit_hit: bool,
    canceled: bool,
}

impl Collector<'_> {
    fn begin_file(&mut self, relative: &str) {
        self.path.clear();
        self.path.push_str(relative);
        // Context never spans files, and the searcher has no break between them.
        self.before.clear();
        self.trailing = None;
    }

    fn keep_going(&mut self) -> bool {
        if self.cancel.load(std::sync::atomic::Ordering::Relaxed) {
            self.canceled = true;
            return false;
        }
        true
    }

    fn take_match(&mut self, line: u64, text: &str) -> bool {
        let mut found =
            match_from_line(self.path.clone(), line, text, self.query, self.insensitive);
        found.before = self.before.iter().cloned().collect();
        self.before.clear();
        self.trailing = Some(self.pending.len());
        self.pending.push(found);
        if self.streamed + self.pending.len() as u64 >= self.limit {
            self.limit_hit = true;
            return false;
        }
        if self.pending.len() >= SEARCH_BATCH {
            self.flush();
        }
        true
    }

    fn take_context(&mut self, text: String) {
        // Context after a match, and context before the next one, are the same
        // lines — bank them once and let both sides read them.
        if let Some(index) = self.trailing {
            let match_at = &mut self.pending[index];
            if match_at.after.len() < SEARCH_CONTEXT_LINES {
                match_at.after.push(text.clone());
            } else {
                self.trailing = None;
            }
        }
        self.before.push_back(text);
        if self.before.len() > SEARCH_CONTEXT_LINES {
            self.before.pop_front();
        }
    }

    fn flush(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        self.streamed += self.pending.len() as u64;
        // The batch leaves, so nothing in it can still be collecting its
        // trailing context.
        self.trailing = None;
        (self.emit)(std::mem::take(&mut self.pending));
    }

    fn finish(mut self) -> SearchOutcome {
        // A canceled search delivers nothing further: the client that abandoned
        // it is not waiting for a last partial batch.
        if !self.canceled {
            self.flush();
        }
        SearchOutcome {
            matches: self.streamed,
            limit_hit: self.limit_hit,
            canceled: self.canceled,
        }
    }
}

/// One line as the searcher hands it over: bytes including the terminator, and
/// not necessarily UTF-8. Lossy rather than fatal — a single bad byte in one
/// file used to end the whole search, because the old parser read the subprocess
/// pipe as lines of `String`.
fn line_text(bytes: &[u8]) -> String {
    let mut end = bytes.len();
    if end > 0 && bytes[end - 1] == b'\n' {
        end -= 1;
        if end > 0 && bytes[end - 1] == b'\r' {
            end -= 1;
        }
    }
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

impl grep_searcher::Sink for Collector<'_> {
    type Error = std::io::Error;

    fn matched(
        &mut self,
        _searcher: &grep_searcher::Searcher,
        found: &grep_searcher::SinkMatch<'_>,
    ) -> Result<bool, std::io::Error> {
        if !self.keep_going() {
            return Ok(false);
        }
        let line = found.line_number().unwrap_or(0);
        let text = line_text(found.bytes());
        Ok(self.take_match(line, &text))
    }

    fn context(
        &mut self,
        _searcher: &grep_searcher::Searcher,
        context: &grep_searcher::SinkContext<'_>,
    ) -> Result<bool, std::io::Error> {
        if !self.keep_going() {
            return Ok(false);
        }
        self.take_context(line_text(context.bytes()));
        Ok(true)
    }

    fn context_break(
        &mut self,
        _searcher: &grep_searcher::Searcher,
    ) -> Result<bool, std::io::Error> {
        // A run ended: whatever context was banked belongs to nothing that
        // follows it.
        self.before.clear();
        self.trailing = None;
        Ok(true)
    }
}

/// Builds the match a client draws: where the query hit inside the line, and a
/// window of the line that contains the first hit.
///
/// The spans come from the same case rule that decided the line matched, which
/// is the whole point — a client that re-finds the query itself is running a
/// second matcher, and two matchers eventually disagree (an uppercase query
/// painting lowercase text, a canonically-equal-but-different byte sequence).
fn match_from_line(
    path: String,
    line: u64,
    text: &str,
    query: &str,
    insensitive: bool,
) -> crate::protocol::SearchMatch {
    let spans = spans_in(text, query, insensitive);
    // Window a long line around its first hit rather than truncating the head
    // off it: a line cut at a fixed 512 bytes with its match at column 900
    // arrives with nothing to highlight, which is exactly how a result row ends
    // up looking wrong.
    let first = spans.first().map(|span| span.0).unwrap_or(0);
    let (offset, windowed) = window(text, first);
    let spans = spans
        .into_iter()
        .filter(|span| span.0 >= offset && span.1 <= offset + windowed.len())
        .map(|span| [(span.0 - offset) as u32, (span.1 - offset) as u32])
        .collect();
    crate::protocol::SearchMatch {
        path,
        line,
        text: windowed,
        text_offset: offset as u64,
        spans,
        before: Vec::new(),
        after: Vec::new(),
    }
}

/// Byte ranges of every occurrence of `query` in `text`, under the case rule the
/// search itself used. Non-overlapping and left to right, like `git grep`.
fn spans_in(text: &str, query: &str, insensitive: bool) -> Vec<(usize, usize)> {
    if query.is_empty() {
        return Vec::new();
    }
    // Lowercasing can change byte length (İ, ẞ), which would make an index into
    // the lowered copy meaningless against the original. Only ASCII is folded
    // for that reason — and an ASCII fold is what `--ignore-case` on a
    // fixed-string grep does for the queries this search sees.
    let (hay, needle) = if insensitive {
        (text.to_ascii_lowercase(), query.to_ascii_lowercase())
    } else {
        (text.to_string(), query.to_string())
    };
    let mut spans = Vec::new();
    let mut from = 0;
    while let Some(at) = hay[from..].find(&needle) {
        let start = from + at;
        let end = start + needle.len();
        // Never split a character: a fold that lands mid-sequence would produce
        // a span the client cannot turn into a range.
        if text.is_char_boundary(start) && text.is_char_boundary(end) {
            spans.push((start, end));
        }
        from = end.max(start + 1);
    }
    spans
}

/// A cap-sized window of `text` containing `around`, snapped to character
/// boundaries. Returns where the window starts and the window itself.
fn window(text: &str, around: usize) -> (usize, String) {
    if text.len() <= SEARCH_TEXT_CAP {
        return (0, text.to_string());
    }
    let mut start = around.saturating_sub(SEARCH_WINDOW_LEAD);
    while start > 0 && !text.is_char_boundary(start) {
        start -= 1;
    }
    let mut end = (start + SEARCH_TEXT_CAP).min(text.len());
    while end > start && !text.is_char_boundary(end) {
        end -= 1;
    }
    (start, text[start..end].to_string())
}

/// Where an upload lands, after confinement has been decided by the caller
/// (project dest under a canonical root, or a session scratch dir).
pub struct UploadDest {
    pub final_path: PathBuf,
    /// Scratch files are always 0600; project files honor `mode` (0644
    /// default). Decided at open so commit cannot be talked into anything.
    pub scratch: bool,
}

/// Confine a project-root upload dest (§C.12): no dotdot, parent must exist
/// and canonicalise under the root (which resolves symlink traversal), and
/// the final component must be a plain name. The file itself may not exist
/// yet, so confinement is proven on the parent.
pub fn resolve_project_dest(root: &str, dest: &str) -> Result<UploadDest> {
    let root = canonical_root(root)?;
    let raw = Path::new(dest);
    if raw
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        bail!("upload dest escapes the workspace root: {dest}");
    }
    let joined = if raw.is_absolute() {
        raw.to_path_buf()
    } else {
        root.join(raw)
    };
    let name = joined
        .file_name()
        .ok_or_else(|| anyhow!("upload dest needs a file name: {dest}"))?
        .to_os_string();
    let parent = joined
        .parent()
        .ok_or_else(|| anyhow!("upload dest needs a parent directory: {dest}"))?;
    let parent = std::fs::canonicalize(parent)
        .with_context(|| format!("resolving upload dest parent for {dest}"))?;
    if !parent.starts_with(&root) {
        bail!("upload dest escapes the workspace root: {dest}");
    }
    Ok(UploadDest {
        final_path: parent.join(name),
        scratch: false,
    })
}

/// Validate a `temp:` name: one plain component headed for the session's
/// scratch dir, nothing that could navigate out of it.
pub fn resolve_scratch_dest(scratch_dir: &Path, name: &str) -> Result<UploadDest> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\0')
    {
        bail!("invalid temp: file name: {name}");
    }
    Ok(UploadDest {
        final_path: scratch_dir.join(name),
        scratch: true,
    })
}

struct UploadState {
    dest: PathBuf,
    dotfile: PathBuf,
    scratch: bool,
    size: u64,
    sha256: String,
    mode: Option<u32>,
    session: Option<SessionId>,
    received: u64,
    hasher: sha2::Sha256,
    file: std::fs::File,
}

/// In-flight uploads (§C.12). Memory stays O(chunk): bytes stream through an
/// incremental hasher into a dotfile beside the dest, and commit verifies
/// size + sha256 before the atomic rename.
///
/// A re-open with the same dest/size/hash is idempotent and **resumes**: it
/// returns the same id and the byte count already on disk, so a client that
/// lost its connection mid-transfer sends only the tail. Resuming is safe
/// precisely because size and sha256 are declared up front — two transfers
/// that agree on both have the same bytes, so any prefix of one is a prefix
/// of the other, and the running hash over that prefix stays valid.
#[derive(Clone, Default)]
pub struct Uploads {
    inner: std::sync::Arc<std::sync::Mutex<UploadsInner>>,
}

#[derive(Default)]
struct UploadsInner {
    counter: u64,
    by_id: std::collections::HashMap<String, UploadState>,
}

impl Uploads {
    pub fn new() -> Uploads {
        Uploads::default()
    }

    /// Open (or idempotently re-open) an upload. `session` ties a scratch
    /// upload to the session whose death reaps it. Returns the upload id and
    /// the offset the next chunk must carry — 0 for a fresh open, the bytes
    /// already landed when resuming.
    pub fn open(
        &self,
        dest: UploadDest,
        size: u64,
        sha256: &str,
        mode: Option<u32>,
        session: Option<SessionId>,
    ) -> Result<(String, u64)> {
        if sha256.len() != 64 || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            bail!("sha256 must be 64 hex characters");
        }
        let sha256 = sha256.to_ascii_lowercase();

        let mut inner = self.inner.lock().unwrap();
        let existing = inner
            .by_id
            .iter()
            .find(|(_, state)| state.dest == dest.final_path)
            .map(|(id, state)| (id.clone(), state.size == size && state.sha256 == sha256));
        if let Some((id, matches)) = existing {
            if !matches {
                bail!(
                    "another upload is already open for {} with different content",
                    dest.final_path.display()
                );
            }
            // Idempotent re-open: same id, resumed where the bytes stopped.
            // This is the reconnect story — the client lost the acks, not the
            // daemon, so the daemon is the one that knows how far it got.
            let state = inner.by_id.get(&id).expect("looked up above");
            return Ok((id, state.received));
        }

        inner.counter += 1;
        let id = format!("u_{:x}", inner.counter);
        let name = dest
            .final_path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "upload".to_string());
        let dotfile = dest
            .final_path
            .with_file_name(format!(".{name}.{id}.part"));
        use std::os::unix::fs::OpenOptionsExt;
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&dotfile)
            .with_context(|| format!("creating upload dotfile {}", dotfile.display()))?;
        inner.by_id.insert(
            id.clone(),
            UploadState {
                dest: dest.final_path,
                dotfile,
                scratch: dest.scratch,
                size,
                sha256,
                mode,
                session,
                received: 0,
                hasher: <sha2::Sha256 as sha2::Digest>::new(),
                file,
            },
        );
        Ok((id, 0))
    }

    /// Apply one chunk. Credit-of-one makes chunks strictly sequential, so
    /// any offset other than the running total is a protocol violation, not
    /// something to reorder around. Returns the new total (the next expected
    /// offset, echoed in the ack).
    ///
    /// The one exception is offset 0 on an upload that already has bytes: that
    /// is a client restarting rather than resuming — the shape every client
    /// had before `upload_opened` carried an offset — and it rewinds instead
    /// of failing.
    pub fn chunk(&self, upload_id: &str, offset: u64, data: &[u8]) -> Result<u64> {
        let mut inner = self.inner.lock().unwrap();
        let state = inner
            .by_id
            .get_mut(upload_id)
            .ok_or_else(|| anyhow!("no such upload: {upload_id}"))?;
        if offset == 0 && state.received > 0 {
            state.file.set_len(0).context("truncating upload dotfile")?;
            use std::io::Seek;
            state
                .file
                .seek(std::io::SeekFrom::Start(0))
                .context("rewinding upload dotfile")?;
            state.received = 0;
            state.hasher = <sha2::Sha256 as sha2::Digest>::new();
        }
        if offset != state.received {
            bail!(
                "upload {upload_id} expected offset {}, got {offset}",
                state.received
            );
        }
        if state.received + data.len() as u64 > state.size {
            bail!(
                "upload {upload_id} overruns its declared size of {} bytes",
                state.size
            );
        }
        use std::io::Write;
        state
            .file
            .write_all(data)
            .context("writing upload chunk")?;
        sha2::Digest::update(&mut state.hasher, data);
        state.received += data.len() as u64;
        Ok(state.received)
    }

    /// Verify and land the upload: size and sha256 must match what open
    /// declared, then the dotfile is renamed into place — readers only ever
    /// see nothing or the whole verified file.
    /// Lands a finished upload at its destination.
    ///
    /// `if_unmodified_since` is what makes this usable as *save*: the editor
    /// read a file at a version, and a commit that names that version is
    /// refused when the file on disk has moved on. Without it two writers —
    /// and on this host the other writer is usually an agent with a shell in
    /// the same checkout — silently overwrite each other, with the loser's work
    /// gone and nothing on screen having said so. `None` keeps the old
    /// behaviour, which is what a paste into a scratch directory wants.
    pub fn commit(
        &self,
        upload_id: &str,
        if_unmodified_since: Option<u64>,
    ) -> Result<(PathBuf, u64)> {
        let mut inner = self.inner.lock().unwrap();
        let state = inner
            .by_id
            .remove(upload_id)
            .ok_or_else(|| anyhow!("no such upload: {upload_id}"))?;
        let finish = (|| {
            if state.received != state.size {
                bail!(
                    "upload has {} of {} declared bytes",
                    state.received,
                    state.size
                );
            }
            let digest = sha2::Digest::finalize(state.hasher.clone());
            let actual = digest
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            if actual != state.sha256 {
                bail!("sha256 mismatch: expected {}, got {actual}", state.sha256);
            }
            state.file.sync_all().context("syncing upload")?;
            // Read once: the same stat answers both the version check and the
            // mode to keep, and asking twice would leave a window between them.
            let existing = std::fs::metadata(&state.dest).ok();
            if let Some(expected) = if_unmodified_since {
                let current = existing.as_ref().map(mtime_seconds);
                match current {
                    Some(current) if current == expected => {}
                    Some(current) => bail!(
                        "conflict: {} changed on this device (read at {expected}, now {current})",
                        state.dest.display()
                    ),
                    None => bail!(
                        "conflict: {} is no longer there",
                        state.dest.display()
                    ),
                }
            }
            use std::os::unix::fs::PermissionsExt;
            let mode = if state.scratch {
                0o600
            } else {
                // The file's own mode outlives the write: replacing an
                // executable script with a 0644 file is a broken script, and
                // the writer did not ask for that by saving.
                state
                    .mode
                    .or_else(|| {
                        existing
                            .as_ref()
                            .map(|metadata| metadata.permissions().mode() & 0o7777)
                    })
                    .unwrap_or(0o644)
            };
            std::fs::set_permissions(&state.dotfile, std::fs::Permissions::from_mode(mode))
                .context("setting upload permissions")?;
            std::fs::rename(&state.dotfile, &state.dest)
                .with_context(|| format!("renaming into {}", state.dest.display()))?;
            // The version this write produced. Answered here rather than left
            // for the client to go and read, because a save that means to be
            // followed by another save needs to know what it just created —
            // and a second stat from over there could already be a third
            // writer's file.
            let mtime = std::fs::metadata(&state.dest)
                .as_ref()
                .map(mtime_seconds)
                .unwrap_or(0);
            Ok((state.dest.clone(), mtime))
        })();
        if finish.is_err() {
            let _ = std::fs::remove_file(&state.dotfile);
        }
        finish
    }

    /// Drop an upload and its dotfile. Idempotent — aborting what is already
    /// gone is not an error.
    pub fn abort(&self, upload_id: &str) {
        let removed = self.inner.lock().unwrap().by_id.remove(upload_id);
        if let Some(state) = removed {
            let _ = std::fs::remove_file(&state.dotfile);
        }
    }

    /// Drop every in-flight upload bound for a dead session's scratch dir.
    /// Called from the reaper before the dir itself is removed.
    pub fn drop_session(&self, session_id: &SessionId) {
        let mut inner = self.inner.lock().unwrap();
        let doomed: Vec<String> = inner
            .by_id
            .iter()
            .filter(|(_, state)| state.session.as_ref() == Some(session_id))
            .map(|(id, _)| id.clone())
            .collect();
        for id in doomed {
            if let Some(state) = inner.by_id.remove(&id) {
                let _ = std::fs::remove_file(&state.dotfile);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("termiod-files-test-{name}-{}", unsafe {
            libc::getpid()
        }));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn touch(path: &Path, bytes: &[u8]) {
        let mut file = std::fs::File::create(path).unwrap();
        file.write_all(bytes).unwrap();
    }

    #[test]
    fn listing_reports_kinds_sorts_names_and_stubs_vcs_dirs() {
        let root = scratch("kinds");
        std::fs::create_dir(root.join("src")).unwrap();
        std::fs::create_dir(root.join(".git")).unwrap();
        touch(&root.join(".git").join("config"), b"[core]");
        touch(&root.join("b.txt"), b"bb");
        touch(&root.join("a.txt"), b"a");
        std::os::unix::fs::symlink("/etc", root.join("link")).unwrap();

        let listings = list(root.to_str().unwrap(), &[".".to_string()], None).unwrap();
        let entries = &listings[0].entries;
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec![".git", "a.txt", "b.txt", "link", "src"]);
        assert_eq!(entries[0].kind, EntryKind::UnloadedDir);
        assert_eq!(entries[1].kind, EntryKind::File);
        assert_eq!(entries[1].size, 1);
        assert_eq!(entries[3].kind, EntryKind::Symlink);
        assert_eq!(entries[3].symlink_target.as_deref(), Some("/etc"));
        assert_eq!(entries[4].kind, EntryKind::Dir);

        // A VCS dir is a stub in its parent, but an explicit list request for
        // it still answers — "never walked until explicitly listed".
        let explicit = list(root.to_str().unwrap(), &[".git".to_string()], None).unwrap();
        assert!(explicit[0].error.is_none());
        assert_eq!(explicit[0].entries[0].name, "config");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_symlink_names_its_target_kind_only_inside_the_root() {
        let root = scratch("symlink_target_kind");
        std::fs::create_dir_all(root.join("skills")).unwrap();
        touch(&root.join("skills/one.md"), b"x");
        touch(&root.join("note.txt"), b"x");
        std::os::unix::fs::symlink("skills", root.join("inside_dir")).unwrap();
        std::os::unix::fs::symlink("note.txt", root.join("inside_file")).unwrap();
        std::os::unix::fs::symlink("/etc", root.join("outside")).unwrap();
        std::os::unix::fs::symlink("nowhere", root.join("dangling")).unwrap();

        let listing = list(root.to_str().unwrap(), &[".".to_string()], None).unwrap();
        let kind_of = |name: &str| {
            listing[0]
                .entries
                .iter()
                .find(|entry| entry.name == name)
                .map(|entry| (entry.kind, entry.target_kind))
                .unwrap()
        };
        // A link is still reported as a link — the listing never follows one.
        assert_eq!(
            kind_of("inside_dir"),
            (EntryKind::Symlink, Some(EntryKind::Dir)),
            "a link to a directory under the root is one a tree may expand"
        );
        assert_eq!(kind_of("inside_file"), (EntryKind::Symlink, Some(EntryKind::File)));
        assert_eq!(
            kind_of("outside"),
            (EntryKind::Symlink, None),
            "descending it would be refused by confine, so it is not offered"
        );
        assert_eq!(kind_of("dangling"), (EntryKind::Symlink, None));

        // And the offer is honest: the link that named a directory lists.
        let followed = list(root.to_str().unwrap(), &["inside_dir".to_string()], None).unwrap();
        assert!(followed[0].error.is_none());
        assert_eq!(followed[0].entries[0].name, "one.md");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn pages_are_stable_and_chain_through_next_after() {
        let root = scratch("pages");
        for index in 0..7 {
            touch(&root.join(format!("f{index}")), b"x");
        }
        let root_str = root.to_str().unwrap();
        let paths = [".".to_string()];
        let first = list_with_page_size(root_str, &paths, None, 3).unwrap();
        assert_eq!(first[0].entries.len(), 3);
        assert_eq!(first[0].next_after.as_deref(), Some("f2"));
        let second =
            list_with_page_size(root_str, &paths, first[0].next_after.as_deref(), 3).unwrap();
        assert_eq!(second[0].entries.len(), 3);
        assert_eq!(second[0].next_after.as_deref(), Some("f5"));
        let last =
            list_with_page_size(root_str, &paths, second[0].next_after.as_deref(), 3).unwrap();
        assert_eq!(last[0].entries.len(), 1);
        assert_eq!(last[0].next_after, None);

        let mut seen: Vec<String> = [&first, &second, &last]
            .iter()
            .flat_map(|page| page[0].entries.iter().map(|e| e.name.clone()))
            .collect();
        seen.sort();
        seen.dedup();
        assert_eq!(seen.len(), 7, "pages must partition, not overlap");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The reason the cursor is a name and not an offset.
    ///
    /// A directory being written while it is read is the ordinary case here —
    /// an agent is working in it. With an offset, deleting an entry behind the
    /// cursor slides everything left: the next page repeats the entry at the
    /// boundary and the last one falls off the end, and nothing in the reply
    /// says so. Resuming at a name cannot slide.
    #[test]
    fn a_write_behind_the_cursor_neither_repeats_nor_drops_an_entry() {
        let root = scratch("pages_racing");
        for index in 0..7 {
            touch(&root.join(format!("f{index}")), b"x");
        }
        let root_str = root.to_str().unwrap();
        let paths = [".".to_string()];

        let first = list_with_page_size(root_str, &paths, None, 3).unwrap();
        assert_eq!(
            first[0].entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            ["f0", "f1", "f2"]
        );

        // Two writes behind the cursor between the pages: one entry removed,
        // one added. An offset of 3 would now point at "f4" and lose "f3".
        std::fs::remove_file(root.join("f0")).unwrap();
        touch(&root.join("early"), b"x");

        let second =
            list_with_page_size(root_str, &paths, first[0].next_after.as_deref(), 3).unwrap();
        assert_eq!(
            second[0].entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            ["f3", "f4", "f5"],
            "the resume point is a name, so nothing behind it moved this page"
        );
        let last =
            list_with_page_size(root_str, &paths, second[0].next_after.as_deref(), 3).unwrap();
        assert_eq!(
            last[0].entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            ["f6"]
        );
        assert_eq!(last[0].next_after, None);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A cursor naming an entry that has since been deleted still resumes at
    /// the right place: `after` is a point in the order, not a row that has to
    /// still exist.
    #[test]
    fn a_cursor_whose_entry_vanished_still_resumes_after_it() {
        let root = scratch("pages_vanished");
        for index in 0..5 {
            touch(&root.join(format!("f{index}")), b"x");
        }
        let root_str = root.to_str().unwrap();
        let paths = [".".to_string()];
        let first = list_with_page_size(root_str, &paths, None, 2).unwrap();
        assert_eq!(first[0].next_after.as_deref(), Some("f1"));

        std::fs::remove_file(root.join("f1")).unwrap();

        let second =
            list_with_page_size(root_str, &paths, first[0].next_after.as_deref(), 2).unwrap();
        assert_eq!(
            second[0].entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            ["f2", "f3"]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn escapes_fail_alone_without_sinking_the_batch() {
        let root = scratch("confine");
        std::fs::create_dir(root.join("inside")).unwrap();
        std::os::unix::fs::symlink("/", root.join("out")).unwrap();

        let listings = list(
            root.to_str().unwrap(),
            &[
                "inside".to_string(),
                "../".to_string(),
                "out".to_string(),
                "/etc".to_string(),
            ],
            None,
        )
        .unwrap();
        assert!(listings[0].error.is_none());
        assert!(listings[1].error.is_some(), "dotdot must be rejected");
        assert!(
            listings[2].error.is_some(),
            "a symlink pointing out of the root must be rejected"
        );
        assert!(
            listings[3].error.is_some(),
            "an absolute path outside the root must be rejected"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn reads_window_and_honor_the_soft_cap() {
        let root = scratch("reads");
        let path = root.join("blob");
        touch(&path, b"0123456789");
        let path = path.to_str().unwrap().to_string();

        let whole = read_with_cap(&path, None, None, 1024).unwrap();
        assert_eq!(whole.data, b"0123456789");
        assert!(!whole.truncated);
        assert_eq!(whole.size, 10);

        let window = read_with_cap(&path, Some(2), Some(3), 1024).unwrap();
        assert_eq!(window.data, b"234");
        assert_eq!(window.offset, 2);
        assert!(!window.truncated);

        let capped = read_with_cap(&path, None, None, 4).unwrap();
        assert_eq!(capped.data, b"0123");
        assert!(capped.truncated, "cap short of the file must say so");

        let ranged_cap = read_with_cap(&path, Some(1), Some(9), 4).unwrap();
        assert_eq!(ranged_cap.data, b"1234");
        assert!(ranged_cap.truncated);

        let past_end = read_with_cap(&path, Some(50), None, 4).unwrap();
        assert!(past_end.data.is_empty());
        assert!(!past_end.truncated, "beyond EOF serves empty, not an error");

        assert!(read_with_cap(root.to_str().unwrap(), None, None, 4).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Runs one search to completion, the way the daemon does minus the wire.
    fn found(root: &Path, query: &str, limit: u64) -> (Vec<crate::protocol::SearchMatch>, SearchOutcome) {
        let cancel = std::sync::atomic::AtomicBool::new(false);
        let mut all = Vec::new();
        let outcome = search(root, query, limit, &cancel, &mut |batch| all.extend(batch));
        (all, outcome)
    }

    /// A repository marker, which is what makes the ignore rules apply at all —
    /// outside a repo there is nothing to honour and everything is searched.
    fn repo(name: &str) -> PathBuf {
        let root = scratch(name);
        std::fs::create_dir(root.join(".git")).unwrap();
        root
    }

    /// Colons in the text used to be a parsing hazard, because the hit arrived
    /// as `path:line:text` on a pipe. It arrives as three values now, and the
    /// context around it arrives as its own callback rather than a `-` line.
    #[test]
    fn a_hit_carries_its_path_line_text_and_context() {
        let root = repo("search-basics");
        std::fs::create_dir(root.join("src")).unwrap();
        touch(
            &root.join("src/main.rs"),
            b"one\ntwo\nlet url = \"http://x:8080\";\nfour\nfive\nsix\n",
        );

        let (hits, outcome) = found(&root, "url", 100);

        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].path, "src/main.rs");
        assert_eq!(hits[0].line, 3);
        assert_eq!(hits[0].text, "let url = \"http://x:8080\";");
        assert_eq!(hits[0].before, vec!["one", "two"]);
        assert_eq!(hits[0].after, vec!["four", "five"]);
        assert_eq!(outcome.matches, 1);
        assert!(!outcome.limit_hit && !outcome.canceled);
    }

    /// The whole point of reporting spans: they come from the rule that decided
    /// the line matched, so an uppercase query cannot paint lowercase text.
    #[test]
    fn spans_follow_the_smart_case_rule() {
        let root = repo("search-case");
        touch(&root.join("a.rs"), b"let Widget = widget();\n");

        let (exact, _) = found(&root, "Widget", 100);
        assert_eq!(exact[0].spans, vec![[4, 10]], "an uppercase query is exact");

        let (loose, _) = found(&root, "widget", 100);
        assert_eq!(
            loose[0].spans,
            vec![[4, 10], [13, 19]],
            "an all-lowercase query matches both cases"
        );
        for span in &loose[0].spans {
            let range = span[0] as usize..span[1] as usize;
            assert_eq!(loose[0].text[range].to_lowercase(), "widget");
        }
    }

    /// A hit far down a long line used to arrive with the line truncated in
    /// front of it — a result row with nothing highlighted. The window follows
    /// the match instead, and says where it starts so columns still resolve.
    #[test]
    fn a_long_line_is_windowed_around_its_hit() {
        let root = repo("search-long-line");
        let mut line = "x".repeat(900);
        line.push_str("needle");
        line.push_str(&"y".repeat(900));
        line.push('\n');
        touch(&root.join("bundle.js"), line.as_bytes());

        let (hits, _) = found(&root, "needle", 100);

        assert_eq!(hits.len(), 1);
        assert!(hits[0].text.len() <= SEARCH_TEXT_CAP);
        let span = hits[0].spans[0];
        assert_eq!(&hits[0].text[span[0] as usize..span[1] as usize], "needle");
        assert_eq!(hits[0].text_offset as usize + span[0] as usize, 900);
    }

    /// A window that would cut a character in half must step back to a boundary
    /// rather than produce a string the client cannot index into.
    #[test]
    fn a_long_line_of_multibyte_text_is_cut_on_a_boundary() {
        let root = repo("search-multibyte");
        let mut line = "é".repeat(SEARCH_TEXT_CAP);
        line.push('\n');
        touch(&root.join("accents.txt"), line.as_bytes());

        let (hits, _) = found(&root, "é", 100);

        assert!(hits[0].text.len() <= SEARCH_TEXT_CAP);
        assert!(hits[0].text.chars().all(|c| c == 'é'));
    }

    /// The search domain: tracked and untracked files that no ignore rule
    /// names, dotfiles included, `.git` never walked, binary files skipped.
    #[test]
    fn the_walk_honours_ignore_rules_and_skips_binaries() {
        let root = repo("search-domain");
        touch(&root.join(".gitignore"), b"ignored/\n*.log\n");
        touch(&root.join("keep.txt"), b"needle\n");
        touch(&root.join(".hidden.txt"), b"needle\n");
        touch(&root.join("notes.log"), b"needle\n");
        touch(&root.join("bundle.bin"), b"needle\0trailing\n");
        touch(&root.join(".git/config"), b"needle\n");
        std::fs::create_dir(root.join("ignored")).unwrap();
        touch(&root.join("ignored/deep.txt"), b"needle\n");
        std::fs::create_dir(root.join("nested")).unwrap();
        touch(&root.join("nested/.gitignore"), b"skip.txt\n");
        touch(&root.join("nested/skip.txt"), b"needle\n");
        touch(&root.join("nested/keep.txt"), b"needle\n");

        let (hits, _) = found(&root, "needle", 100);
        let paths: Vec<&str> = hits.iter().map(|hit| hit.path.as_str()).collect();

        assert_eq!(paths, vec![".hidden.txt", "keep.txt", "nested/keep.txt"]);
    }

    /// Runs `git grep --untracked` in a fixture repo and returns the files it
    /// matched, or `None` when there is no git to ask.
    fn git_grep_files(root: &Path, query: &str) -> Option<Vec<String>> {
        let output = std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args(["grep", "-l", "-I", "--no-color", "--untracked", "--fixed-strings", "-e", query])
            .output()
            .ok()?;
        let listed = String::from_utf8_lossy(&output.stdout);
        let mut files: Vec<String> = listed.lines().map(str::to_string).collect();
        files.sort();
        Some(files)
    }

    fn git(root: &Path, args: &[&str]) {
        std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .output()
            .expect("run git");
    }

    /// The differential test: every ignore rule git honours, checked against
    /// what git itself answers on the same tree rather than against what this
    /// engine was expected to do.
    ///
    /// The global excludes file is the case that pays for the whole test. Its
    /// path comes off a config stack with quoting rules, and the `ignore`
    /// crate's own regex reads `excludesFile = "…/with a space/ignore"` as the
    /// text up to the first space — dropping every rule in the file, silently.
    /// The path here has spaces and is quoted for exactly that reason. Asking
    /// git for the value is what makes both sides agree.
    #[test]
    fn the_ignore_rules_agree_with_git_grep_file_for_file() {
        if std::process::Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let root = scratch("search-differential");
        git(&root, &["init", "-q"]);

        let excludes = root.join("config dir/global ignore");
        std::fs::create_dir_all(excludes.parent().expect("a parent")).unwrap();
        // The anchored pattern is the second half of the point: git matches it
        // against the top of the working tree, so `root-only.txt` goes and
        // `sub/root-only.txt` stays. A matcher rooted at the daemon's own
        // working directory would drop the rule instead.
        touch(&excludes, b"by-global.txt\n/root-only.txt\n");
        // Written straight into the config so the value keeps its quotes: this
        // is the shape a Mac's `~/Library/Application Support/git/ignore` takes,
        // and the shape the crate's parser truncates. Repo-local rather than
        // global so the fixture cannot be perturbed by the machine it runs on.
        let mut config = std::fs::OpenOptions::new()
            .append(true)
            .open(root.join(".git/config"))
            .unwrap();
        writeln!(
            config,
            "[core]\n\texcludesFile = \"{}\"",
            excludes.display()
        )
        .unwrap();
        drop(config);

        touch(&root.join(".git/info/exclude"), b"by-info-exclude.txt\n");
        touch(&root.join(".gitignore"), b"*.log\n!keep.log\nbuilt/\n");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        touch(&root.join("sub/.gitignore"), b"*.tmp\n!ok.tmp\n");

        for named in [
            "plain.txt",
            "by-global.txt",
            "by-info-exclude.txt",
            "drop.log",
            "keep.log",
            "sub/ok.tmp",
            "sub/no.tmp",
            ".dotfile.txt",
            "root-only.txt",
            "sub/root-only.txt",
        ] {
            touch(&root.join(named), b"needle\n");
        }
        std::fs::create_dir_all(root.join("built")).unwrap();
        touch(&root.join("built/out.txt"), b"needle\n");
        // Tracked *and* ignored. `--untracked` implies `--exclude-standard`, so
        // git skips it too — the case that looked like a divergence and is not.
        git(&root, &["add", "-f", "drop.log"]);

        let theirs = git_grep_files(&root, "needle").expect("git grep");
        let (hits, _) = found(&root, "needle", 1000);
        let mut ours: Vec<String> = hits.into_iter().map(|hit| hit.path).collect();
        ours.dedup();

        assert_eq!(ours, theirs, "the ignore rules must agree file for file");
        assert_eq!(
            theirs,
            vec![
                ".dotfile.txt",
                "keep.log",
                "plain.txt",
                "sub/ok.tmp",
                "sub/root-only.txt",
            ],
            "and agree on the right answer, not on a shared mistake"
        );
    }

    /// `core.excludesFile` has three states, not two, and the difference is
    /// invisible in `git config`'s output alone: absent exits non-zero, set to
    /// a path exits zero with the path, set to the empty string exits zero with
    /// nothing. The last one means "no global excludes", *not* "use the
    /// default" — treating it as absent turns a setting someone deliberately
    /// switched off back on.
    #[test]
    fn an_empty_excludes_setting_disables_global_excludes_like_git() {
        if std::process::Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let root = scratch("search-excludes-off");
        git(&root, &["init", "-q"]);
        git(&root, &["config", "core.excludesFile", ""]);

        // git's default location, populated. Neither side may reach it.
        let xdg = root.join("xdg");
        std::fs::create_dir_all(xdg.join("git")).unwrap();
        touch(&xdg.join("git/ignore"), b"named-by-the-default-file.txt\n");
        touch(&root.join("plain.txt"), b"needle\n");
        touch(&root.join("named-by-the-default-file.txt"), b"needle\n");

        let listed = std::process::Command::new("git")
            .arg("-C")
            .arg(&root)
            .args(["grep", "-l", "-I", "--untracked", "--fixed-strings", "-e", "needle"])
            .env("XDG_CONFIG_HOME", &xdg)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .expect("run git grep");
        let text = String::from_utf8_lossy(&listed.stdout);
        let mut theirs: Vec<String> = text.lines().map(str::to_string).collect();
        theirs.sort();

        let (hits, _) = found(&root, "needle", 1000);
        let ours: Vec<String> = hits.into_iter().map(|hit| hit.path).collect();

        assert_eq!(ours, theirs);
        assert_eq!(ours, vec!["named-by-the-default-file.txt", "plain.txt"]);
        // The walk above cannot prove *why* it agreed: this daemon's own home
        // is not the fixture's, so a wrong fallback would have reached a file
        // with none of these names in it and the sets would have matched
        // anyway. The rule itself is what has to be pinned.
        assert_eq!(
            resolve_global_excludes(&root, || Some(xdg.join("git/ignore"))),
            None,
            "an empty setting must not reach for the default git would skip"
        );
    }

    /// The same three states, pinned at the resolver so the empty case cannot
    /// be read as the absent one. The default is handed in rather than read
    /// from the environment: a test that moved `HOME` would move it for every
    /// other thread in the process too.
    #[test]
    fn the_three_states_of_the_excludes_setting_resolve_apart() {
        if std::process::Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let root = scratch("search-excludes-states");
        git(&root, &["init", "-q"]);
        let default = PathBuf::from("/somewhere/git/ignore");
        let fallback = || Some(default.clone());

        assert_eq!(
            resolve_global_excludes(&root, fallback),
            Some(default.clone()),
            "absent means git's own default"
        );

        git(&root, &["config", "core.excludesFile", "/named/ignore"]);
        assert_eq!(
            resolve_global_excludes(&root, fallback),
            Some(PathBuf::from("/named/ignore")),
            "a path means that path"
        );

        git(&root, &["config", "core.excludesFile", ""]);
        assert_eq!(
            resolve_global_excludes(&root, fallback),
            None,
            "empty means off, and must not reach for the default"
        );

        let outside = scratch("search-excludes-no-repo");
        assert_eq!(
            resolve_global_excludes(&outside, fallback),
            None,
            "outside a repository git applies none, and neither does this"
        );
    }

    /// A relative `XDG_CONFIG_HOME` must not fall through to `$HOME/.config`.
    ///
    /// The premise is checked against git rather than read off the spec,
    /// because the two disagree: XDG says a relative base directory is invalid
    /// and must be ignored, and git uses it anyway — `xdg_config_home` in
    /// `path.c` tests only that the variable is set and non-empty. So the
    /// fixture proves what git does before anything asserts what this matches.
    #[test]
    fn a_relative_xdg_config_home_is_used_and_does_not_fall_back_to_home() {
        if std::process::Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let root = scratch("search-xdg-relative");
        git(&root, &["init", "-q"]);
        touch(&root.join("plain.txt"), b"needle\n");
        touch(&root.join("named-by-xdg.txt"), b"needle\n");
        touch(&root.join("named-by-home.txt"), b"needle\n");
        // Reachable only by resolving "relative-xdg" against the repository,
        // which is the working directory git runs with here.
        std::fs::create_dir_all(root.join("relative-xdg/git")).unwrap();
        touch(&root.join("relative-xdg/git/ignore"), b"named-by-xdg.txt\n");
        let home = scratch("search-xdg-home");
        std::fs::create_dir_all(home.join(".config/git")).unwrap();
        touch(&home.join(".config/git/ignore"), b"named-by-home.txt\n");

        let grep = |xdg: Option<&str>| {
            let mut command = std::process::Command::new("git");
            command
                .arg("-C")
                .arg(&root)
                .args(["grep", "-l", "-I", "--untracked", "--fixed-strings", "-e", "needle"])
                .env("HOME", &home)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env_remove("XDG_CONFIG_HOME");
            if let Some(xdg) = xdg {
                command.env("XDG_CONFIG_HOME", xdg);
            }
            let output = command.output().expect("run git grep");
            let listed = String::from_utf8_lossy(&output.stdout);
            let mut files: Vec<String> = listed.lines().map(str::to_string).collect();
            files.sort();
            files
        };

        assert_eq!(
            grep(None),
            vec!["named-by-xdg.txt", "plain.txt"],
            "with no XDG set, git reads $HOME/.config/git/ignore"
        );
        assert_eq!(
            grep(Some("relative-xdg")),
            vec!["named-by-home.txt", "plain.txt"],
            "a relative XDG_CONFIG_HOME is used, and it displaces the HOME default"
        );

        // And that is the rule this resolves by.
        let relative = excludes_default_from(
            Some("relative-xdg".into()),
            Some(home.clone().into_os_string()),
        );
        assert_eq!(relative, Some(PathBuf::from("relative-xdg/git/ignore")));
        assert_eq!(
            resolve_global_excludes(&root, || relative.clone()),
            Some(root.join("relative-xdg/git/ignore")),
            "a relative answer anchors where git had its working directory"
        );
    }

    /// The rest of the table, which needs no repository to be true.
    #[test]
    fn the_default_excludes_path_follows_gits_own_rule() {
        let home = std::ffi::OsString::from("/home/someone");
        assert_eq!(
            excludes_default_from(None, Some(home.clone())),
            Some(PathBuf::from("/home/someone/.config/git/ignore")),
            "unset falls back to HOME"
        );
        assert_eq!(
            excludes_default_from(Some("".into()), Some(home.clone())),
            Some(PathBuf::from("/home/someone/.config/git/ignore")),
            "empty counts as unset, which is git's own test"
        );
        assert_eq!(
            excludes_default_from(Some("/xdg".into()), Some(home.clone())),
            Some(PathBuf::from("/xdg/git/ignore")),
            "set wins over HOME"
        );
        assert_eq!(
            excludes_default_from(Some("relative".into()), Some(home)),
            Some(PathBuf::from("relative/git/ignore")),
            "and wins even when relative — no fall back to HOME"
        );
        assert_eq!(
            excludes_default_from(None, None),
            None,
            "with neither, git has nowhere to look and neither does this"
        );
    }

    /// Where this parts ways with `git grep --untracked`, asserted against real
    /// git so the day either side moves is not a silent one.
    ///
    /// The two mostly agree, and for a reason worth pinning: `--untracked`
    /// implies `--exclude-standard`, so git was already deciding by the ignore
    /// files rather than by the index — which is the only thing the `ignore`
    /// crate can read. A file tracked *and* ignored is skipped by both.
    ///
    /// A nested repository is the case that differs. git never descends into
    /// one without `--recurse-submodules`; this walk treats it as an ordinary
    /// directory with ignore rules of its own. A vendored checkout becomes
    /// searchable, and a submodule's working tree becomes something the walk
    /// pays for. That is the accepted cost of dropping the index.
    #[test]
    fn a_nested_repository_is_where_this_parts_ways_with_git_grep() {
        if std::process::Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let root = scratch("search-divergence");
        let git = |at: &Path, args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(at)
                .args(args)
                .output()
                .unwrap()
        };
        git(&root, &["init", "-q"]);
        touch(&root.join(".gitignore"), b"secrets.txt\n");
        touch(&root.join("secrets.txt"), b"needle\n");
        git(&root, &["add", "-f", "secrets.txt"]);
        touch(&root.join("plain.txt"), b"needle\n");
        std::fs::create_dir(root.join("vendor")).unwrap();
        git(&root.join("vendor"), &["init", "-q"]);
        touch(&root.join("vendor/inner.txt"), b"needle\n");

        let grep = git(
            &root,
            &["grep", "-l", "-I", "--untracked", "--fixed-strings", "-e", "needle"],
        );
        let listed = String::from_utf8_lossy(&grep.stdout);
        let git_saw: Vec<&str> = listed.lines().collect();
        assert_eq!(git_saw, vec!["plain.txt"]);

        let (hits, _) = found(&root, "needle", 100);
        let paths: Vec<&str> = hits.iter().map(|hit| hit.path.as_str()).collect();
        assert_eq!(
            paths,
            vec!["plain.txt", "vendor/inner.txt"],
            "the ignored file agrees with git; the nested repository does not"
        );
    }

    /// The limit is a cap on matches, not on files, and the run that hits it
    /// says so — the pane draws "showing the first N" from that flag.
    #[test]
    fn the_limit_stops_the_walk_and_is_reported() {
        let root = repo("search-limit");
        touch(&root.join("many.txt"), "needle\n".repeat(20).as_bytes());

        let (hits, outcome) = found(&root, "needle", 3);

        assert_eq!(hits.len(), 3);
        assert_eq!(outcome.matches, 3);
        assert!(outcome.limit_hit);
        assert!(!outcome.canceled);
    }

    /// Cancellation reaches inside a single file, not just between files: a
    /// client that abandoned the query stops paying for it mid-walk, and gets
    /// no further batch — including the partial one still in hand.
    #[test]
    fn cancelling_mid_file_stops_the_search_and_withholds_the_tail() {
        let root = repo("search-cancel");
        touch(&root.join("many.txt"), "needle\n".repeat(SEARCH_BATCH * 3).as_bytes());

        let cancel = std::sync::atomic::AtomicBool::new(false);
        let mut delivered = 0usize;
        let outcome = search(&root, "needle", 10_000, &cancel, &mut |batch| {
            delivered += batch.len();
            cancel.store(true, std::sync::atomic::Ordering::Relaxed);
        });

        assert_eq!(delivered, SEARCH_BATCH, "one batch left before the cancel");
        assert_eq!(outcome.matches, SEARCH_BATCH as u64);
        assert!(outcome.canceled);
        assert!(!outcome.limit_hit);
    }

    /// Outside a repository there are no ignore files to honour, so everything
    /// under the root is searched. `git grep` refused the same request with
    /// "not a git repository"; answering it is the friendlier failure.
    #[test]
    fn a_root_that_is_not_a_repository_is_still_searched() {
        let root = scratch("search-no-repo");
        touch(&root.join("plain.txt"), b"needle\n");

        let (hits, _) = found(&root, "needle", 100);

        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].path, "plain.txt");
    }

    /// The picker's ranking contract, asserted through the public entry point
    /// rather than a private scorer: a name hit outranks a path hit, a shorter
    /// path wins a tie, case does not matter, and a miss is a miss.
    #[tokio::test]
    async fn fuzzy_ranking_prefers_the_basename_over_the_path() {
        let root = scratch("ranking");
        std::fs::create_dir_all(root.join("main/other")).unwrap();
        touch(&root.join("main/other/zebra.rs"), b"");
        touch(&root.join("main.rs"), b"");
        std::fs::create_dir_all(root.join("deeply/nested")).unwrap();
        touch(&root.join("deeply/nested/main.rs"), b"");

        let index = NameIndex::new(root.clone());
        index.build().await;

        // "main" hits three files: two by basename, one only by its directory.
        // Both name hits must precede the path-only hit.
        let (paths, _) = index.matches("main", 10);
        let path_only = paths
            .iter()
            .position(|p| p == "main/other/zebra.rs")
            .expect("a path-only match still matches");
        assert_eq!(paths[0], "main.rs", "shortest basename hit ranks first");
        assert!(
            paths.iter().position(|p| p == "deeply/nested/main.rs") < Some(path_only),
            "every basename hit outranks a path-only hit"
        );

        assert!(index.matches("zzzqqq", 10).0.is_empty(), "a miss is a miss");
        assert_eq!(
            index.matches("MAIN.RS", 10).0.first().map(String::as_str),
            Some("main.rs"),
            "matching is case-insensitive"
        );
    }

    #[tokio::test]
    async fn index_builds_walks_lazily_and_stays_incremental() {
        let root = scratch("index");
        std::fs::create_dir_all(root.join("src/deep")).unwrap();
        std::fs::create_dir(root.join(".git")).unwrap();
        touch(&root.join(".git/config"), b"");
        touch(&root.join("src/main.rs"), b"");
        touch(&root.join("src/deep/hidden.rs"), b"");
        std::os::unix::fs::symlink("/", root.join("outside")).unwrap();

        let index = NameIndex::new(root.clone());
        index.build().await;
        assert_eq!(index.coverage(), 1.0);
        let (paths, coverage) = index.matches("rs", 10);
        assert_eq!(coverage, 1.0);
        assert_eq!(paths, vec!["src/main.rs", "src/deep/hidden.rs"]);
        let (ignored, _) = index.matches("config", 10);
        assert!(
            ignored.is_empty(),
            "VCS internals are never walked into the index"
        );

        // The watcher names a dir; the index re-lists just that dir.
        touch(&root.join("src/fresh.rs"), b"");
        index.apply(&[root.join("src").display().to_string()]);
        let (paths, _) = index.matches("fresh", 10);
        assert_eq!(paths, vec!["src/fresh.rs"]);

        // A dir that vanished takes its subtree out of the index.
        std::fs::remove_dir_all(root.join("src/deep")).unwrap();
        index.apply(&[root.join("src/deep").display().to_string()]);
        let (paths, _) = index.matches("hidden", 10);
        assert!(paths.is_empty(), "stale entries must be pruned");

        // A subtree created in one batch is picked up via its parent.
        std::fs::create_dir_all(root.join("newdir")).unwrap();
        touch(&root.join("newdir/inside.txt"), b"");
        index.apply(&[
            root.display().to_string(),
            root.join("newdir").display().to_string(),
        ]);
        let (paths, _) = index.matches("inside", 10);
        assert_eq!(paths, vec!["newdir/inside.txt"]);

        let (limited, _) = index.matches("rs", 1);
        assert_eq!(limited.len(), 1, "limit caps the reply");
        let _ = std::fs::remove_dir_all(&root);
    }

    fn hex_sha256(data: &[u8]) -> String {
        let digest = <sha2::Sha256 as sha2::Digest>::digest(data);
        digest.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn upload_streams_verifies_and_lands_atomically() {
        let root = scratch("upload");
        let uploads = Uploads::new();
        let body = vec![7u8; 100_000];
        let dest = resolve_project_dest(root.to_str().unwrap(), "out.bin").unwrap();
        let (id, offset) = uploads
            .open(dest, body.len() as u64, &hex_sha256(&body), None, None)
            .unwrap();
        assert_eq!(offset, 0, "a fresh open starts at zero");

        let mut sent = 0;
        for piece in body.chunks(64 * 1024 - 64) {
            assert!(
                uploads.chunk(&id, sent + 1, piece).is_err(),
                "a skewed offset must be rejected"
            );
            let total = uploads.chunk(&id, sent, piece).unwrap();
            sent += piece.len() as u64;
            assert_eq!(total, sent, "ack carries the running total");
        }
        assert!(
            !std::fs::read_dir(&root)
                .unwrap()
                .flatten()
                .any(|e| e.file_name() == "out.bin"),
            "nothing lands before commit"
        );
        let (landed, _) = uploads.commit(&id, None).unwrap();
        assert_eq!(std::fs::read(&landed).unwrap(), body);
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&landed).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o644, "project files default to 0644");
        assert_eq!(
            std::fs::read_dir(&root).unwrap().flatten().count(),
            1,
            "the dotfile is gone after the rename"
        );
        assert!(uploads.commit(&id, None).is_err(), "an upload commits once");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Saving a file read at one version over a file that has since changed is
    /// the lost update this check exists to prevent — and on this host the other
    /// writer is usually an agent with a shell in the same checkout.
    #[test]
    fn upload_commit_refuses_a_destination_that_moved_since_it_was_read() {
        let root = scratch("save-conflict");
        let uploads = Uploads::new();
        touch(&root.join("notes.md"), b"first\n");
        let read = read(root.join("notes.md").to_str().unwrap(), None, None).unwrap();
        assert!(read.mtime > 0, "the read reports the version it holds");

        // Somebody else writes, moving the file's version on. The sleep is the
        // resolution of the timestamp itself, not a race being papered over.
        std::thread::sleep(std::time::Duration::from_millis(1100));
        touch(&root.join("notes.md"), b"theirs\n");

        let body = b"mine\n".to_vec();
        let dest = resolve_project_dest(root.to_str().unwrap(), "notes.md").unwrap();
        let (id, _) = uploads
            .open(dest, body.len() as u64, &hex_sha256(&body), None, None)
            .unwrap();
        uploads.chunk(&id, 0, &body).unwrap();
        let refused = uploads.commit(&id, Some(read.mtime)).unwrap_err().to_string();
        assert!(refused.starts_with("conflict: "), "got {refused}");
        assert_eq!(
            std::fs::read(root.join("notes.md")).unwrap(),
            b"theirs\n",
            "the other writer's file is untouched"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The same save with the version the file actually carries goes through —
    /// the check must not stand in the way of the ordinary case.
    #[test]
    fn upload_commit_lands_when_the_destination_is_unchanged() {
        let root = scratch("save-clean");
        let uploads = Uploads::new();
        touch(&root.join("notes.md"), b"first\n");
        let read = read(root.join("notes.md").to_str().unwrap(), None, None).unwrap();

        let body = b"second\n".to_vec();
        let dest = resolve_project_dest(root.to_str().unwrap(), "notes.md").unwrap();
        let (id, _) = uploads
            .open(dest, body.len() as u64, &hex_sha256(&body), None, None)
            .unwrap();
        uploads.chunk(&id, 0, &body).unwrap();
        let (landed, _) = uploads.commit(&id, Some(read.mtime)).unwrap();
        assert_eq!(std::fs::read(&landed).unwrap(), body);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A save must not quietly disarm an executable. The mode rides the file,
    /// not the request, when the request names none.
    #[test]
    fn upload_commit_keeps_the_destination_mode() {
        use std::os::unix::fs::PermissionsExt;
        let root = scratch("save-mode");
        let uploads = Uploads::new();
        let script = root.join("run.sh");
        touch(&script, b"#!/bin/sh\necho one\n");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

        let body = b"#!/bin/sh\necho two\n".to_vec();
        let dest = resolve_project_dest(root.to_str().unwrap(), "run.sh").unwrap();
        let (id, _) = uploads
            .open(dest, body.len() as u64, &hex_sha256(&body), None, None)
            .unwrap();
        uploads.chunk(&id, 0, &body).unwrap();
        let (landed, _) = uploads.commit(&id, None).unwrap();
        assert_eq!(
            std::fs::metadata(&landed).unwrap().permissions().mode() & 0o777,
            0o755,
            "the script is still executable after being saved"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn upload_commit_rejects_a_hash_mismatch_and_cleans_up() {
        let root = scratch("upload-hash");
        let uploads = Uploads::new();
        let dest = resolve_project_dest(root.to_str().unwrap(), "bad.bin").unwrap();
        let (id, _) = uploads
            .open(dest, 4, &hex_sha256(b"good"), None, None)
            .unwrap();
        uploads.chunk(&id, 0, b"evil").unwrap();
        let error = uploads.commit(&id, None).unwrap_err().to_string();
        assert!(error.contains("sha256 mismatch"), "got: {error}");
        assert_eq!(
            std::fs::read_dir(&root).unwrap().flatten().count(),
            0,
            "neither dest nor dotfile survives a failed verify"
        );

        let dest = resolve_project_dest(root.to_str().unwrap(), "short.bin").unwrap();
        let (id, _) = uploads
            .open(dest, 10, &hex_sha256(b"0123456789"), None, None)
            .unwrap();
        uploads.chunk(&id, 0, b"0123").unwrap();
        assert!(
            uploads
                .commit(&id, None)
                .unwrap_err()
                .to_string()
                .contains("declared bytes"),
            "a short upload must not commit"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn upload_reopen_resumes_at_the_bytes_already_landed() {
        let root = scratch("upload-reopen");
        let uploads = Uploads::new();
        let body = b"reconnect survivor".to_vec();
        let sha = hex_sha256(&body);
        let root_str = root.to_str().unwrap();

        let dest = resolve_project_dest(root_str, "again.txt").unwrap();
        let (first, _) = uploads
            .open(dest, body.len() as u64, &sha, None, None)
            .unwrap();
        uploads.chunk(&first, 0, &body[..5]).unwrap();

        // The connection dies; the client re-opens and is told where to pick up.
        let dest = resolve_project_dest(root_str, "again.txt").unwrap();
        let (second, offset) = uploads
            .open(dest, body.len() as u64, &sha, None, None)
            .unwrap();
        assert_eq!(first, second, "same dest + hash + size = same upload");
        assert_eq!(offset, 5, "re-open resumes rather than restarting");
        uploads.chunk(&second, offset, &body[5..]).unwrap();
        let (landed, _) = uploads.commit(&second, None).unwrap();
        assert_eq!(std::fs::read(&landed).unwrap(), body);

        // A client that ignores the offset restarts from zero, which still
        // works — the hash is what proves the bytes, not the route to them.
        let dest = resolve_project_dest(root_str, "restart.txt").unwrap();
        let (third, _) = uploads
            .open(dest, body.len() as u64, &sha, None, None)
            .unwrap();
        uploads.chunk(&third, 0, &body[..5]).unwrap();
        uploads.chunk(&third, 0, &body).unwrap();
        assert_eq!(
            std::fs::read(uploads.commit(&third, None).unwrap().0).unwrap(),
            body
        );

        // A different payload aimed at the same dest is a conflict, not a
        // silent replacement.
        let dest = resolve_project_dest(root_str, "again.txt").unwrap();
        let (one, _) = uploads.open(dest, 1, &hex_sha256(b"a"), None, None).unwrap();
        let dest = resolve_project_dest(root_str, "again.txt").unwrap();
        assert!(uploads.open(dest, 1, &hex_sha256(b"b"), None, None).is_err());
        uploads.abort(&one);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn upload_dests_are_confined() {
        let root = scratch("upload-confine");
        std::fs::create_dir(root.join("ok")).unwrap();
        std::os::unix::fs::symlink("/tmp", root.join("leak")).unwrap();
        let root_str = root.to_str().unwrap();

        assert!(resolve_project_dest(root_str, "ok/file.png").is_ok());
        assert!(
            resolve_project_dest(root_str, "../escape.png").is_err(),
            "dotdot must be rejected"
        );
        assert!(
            resolve_project_dest(root_str, "leak/escape.png").is_err(),
            "a symlinked parent outside the root must be rejected"
        );
        assert!(
            resolve_project_dest(root_str, "missing/escape.png").is_err(),
            "the parent must already exist"
        );
        assert!(
            resolve_project_dest("/definitely/not/here", "x").is_err(),
            "the root itself must resolve"
        );

        let scratch_dir = root.join("scratch");
        std::fs::create_dir(&scratch_dir).unwrap();
        assert!(resolve_scratch_dest(&scratch_dir, "paste-1.png").is_ok());
        assert!(resolve_scratch_dest(&scratch_dir, "a/b.png").is_err());
        assert!(resolve_scratch_dest(&scratch_dir, "..").is_err());
        assert!(resolve_scratch_dest(&scratch_dir, "").is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn scratch_uploads_are_0600_and_reaped_with_their_session() {
        let root = scratch("upload-scratch");
        let uploads = Uploads::new();
        let body = b"paste".to_vec();
        let dest = resolve_scratch_dest(&root, "paste-1.png").unwrap();
        let (id, _) = uploads
            .open(
                dest,
                body.len() as u64,
                &hex_sha256(&body),
                Some(0o777),
                Some(SessionId::new("s_1")),
            )
            .unwrap();
        uploads.chunk(&id, 0, &body).unwrap();
        let (landed, _) = uploads.commit(&id, None).unwrap();
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&landed).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "scratch files are 0600 whatever mode asked");

        // A second upload still in flight when the session dies leaves no
        // dotfile behind.
        let dest = resolve_scratch_dest(&root, "paste-2.png").unwrap();
        let (id, _) = uploads
            .open(dest, 4, &hex_sha256(b"gone"), None, Some(SessionId::new("s_1")))
            .unwrap();
        uploads.chunk(&id, 0, b"go").unwrap();
        uploads.drop_session(&SessionId::new("s_1"));
        assert!(uploads.chunk(&id, 2, b"ne").is_err(), "upload is gone");
        let names: Vec<String> = std::fs::read_dir(&root)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["paste-1.png"], "no dotfile survives the reap");
        let _ = std::fs::remove_dir_all(&root);
    }
}

