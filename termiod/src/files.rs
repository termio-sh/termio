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

/// List a batch of directories under `root`, one page per path.
pub fn list(root: &str, paths: &[String], page: Option<u64>) -> Result<Vec<PathListing>> {
    list_with_page_size(root, paths, page, LIST_PAGE_SIZE)
}

fn list_with_page_size(
    root: &str,
    paths: &[String],
    page: Option<u64>,
    page_size: usize,
) -> Result<Vec<PathListing>> {
    let root = canonical_root(root)?;
    // A batched, speculative request must not be all-or-nothing: one child
    // that vanished between render and click fails alone.
    Ok(paths
        .iter()
        .map(|requested| match list_one(&root, requested, page, page_size) {
            Ok(listing) => listing,
            Err(error) => PathListing {
                path: requested.clone(),
                entries: Vec::new(),
                next_page: None,
                error: Some(format!("{error:#}")),
            },
        })
        .collect())
}

fn list_one(
    root: &Path,
    requested: &str,
    page: Option<u64>,
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
        let mtime = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| duration.as_secs())
            .unwrap_or(0);
        let (kind, symlink_target) = if metadata.file_type().is_symlink() {
            let target = std::fs::read_link(item.path())
                .ok()
                .map(|target| target.display().to_string());
            (EntryKind::Symlink, target)
        } else if metadata.is_dir() {
            if is_unloaded_dir_name(&name) {
                (EntryKind::UnloadedDir, None)
            } else {
                (EntryKind::Dir, None)
            }
        } else {
            (EntryKind::File, None)
        };
        entries.push(DirEntry {
            name,
            kind,
            size: metadata.len(),
            mtime,
            symlink_target,
        });
    }

    // A stable order is what makes pages meaningful across two requests.
    entries.sort_by(|a, b| a.name.cmp(&b.name));

    let page = usize::try_from(page.unwrap_or(0)).unwrap_or(usize::MAX);
    let start = page.saturating_mul(page_size).min(entries.len());
    let end = start.saturating_add(page_size).min(entries.len());
    let next_page = if end < entries.len() {
        Some(page as u64 + 1)
    } else {
        None
    };
    Ok(PathListing {
        path: requested.to_string(),
        entries: entries[start..end].to_vec(),
        next_page,
        error: None,
    })
}

/// A served `fs.read` window: the header fields plus the bytes themselves.
pub struct FileWindow {
    pub size: u64,
    pub offset: u64,
    pub truncated: bool,
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
    pub fn matches(&self, query: &str, limit: usize) -> (Vec<String>, f32) {
        let inner = self.inner.lock().unwrap();
        let mut scored: Vec<(i64, String)> = inner
            .dirs
            .iter()
            .flat_map(|(dir, files)| {
                let prefix = dir
                    .strip_prefix(&self.root)
                    .unwrap_or(dir)
                    .to_string_lossy()
                    .into_owned();
                files.iter().filter_map(move |name| {
                    let relative = if prefix.is_empty() {
                        name.clone()
                    } else {
                        format!("{prefix}/{name}")
                    };
                    fuzzy_score(&relative, name, query).map(|score| (score, relative))
                })
            })
            .collect();
        drop(inner);
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
fn fuzzy_score(relative: &str, basename: &str, query: &str) -> Option<i64> {
    if query.is_empty() {
        return Some(-(relative.len() as i64));
    }
    let query = query.to_ascii_lowercase();
    let basename_lower = basename.to_ascii_lowercase();
    let relative_lower = relative.to_ascii_lowercase();
    let length_penalty = relative.len() as i64;
    if basename_lower.contains(&query) {
        return Some(4000 - length_penalty);
    }
    if is_subsequence(&query, &basename_lower) {
        return Some(3000 - length_penalty);
    }
    if relative_lower.contains(&query) {
        return Some(2000 - length_penalty);
    }
    if is_subsequence(&query, &relative_lower) {
        return Some(1000 - length_penalty);
    }
    None
}

fn is_subsequence(needle: &str, haystack: &str) -> bool {
    let mut chars = haystack.chars();
    needle
        .chars()
        .all(|wanted| chars.by_ref().any(|have| have == wanted))
}

/// Long minified lines would bloat a `search_results` event; the match is
/// findable from far less.
const SEARCH_TEXT_CAP: usize = 512;

/// Parse one `git grep -n` line: `path:lineno:text`. Colons inside the text
/// are safe — only the first two split.
pub fn parse_grep_line(line: &str) -> Option<crate::protocol::SearchMatch> {
    let (path, rest) = line.split_once(':')?;
    let (line_number, text) = rest.split_once(':')?;
    let line_number: u64 = line_number.parse().ok()?;
    let mut text = text.to_string();
    if text.len() > SEARCH_TEXT_CAP {
        let mut cut = SEARCH_TEXT_CAP;
        while !text.is_char_boundary(cut) {
            cut -= 1;
        }
        text.truncate(cut);
    }
    Some(crate::protocol::SearchMatch {
        path: path.to_string(),
        line: line_number,
        text,
    })
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
    session: Option<String>,
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
        session: Option<String>,
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
    pub fn commit(&self, upload_id: &str) -> Result<PathBuf> {
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
            let mode = if state.scratch {
                0o600
            } else {
                state.mode.unwrap_or(0o644)
            };
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&state.dotfile, std::fs::Permissions::from_mode(mode))
                .context("setting upload permissions")?;
            std::fs::rename(&state.dotfile, &state.dest)
                .with_context(|| format!("renaming into {}", state.dest.display()))?;
            Ok(state.dest.clone())
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
    pub fn drop_session(&self, session_id: &str) {
        let mut inner = self.inner.lock().unwrap();
        let doomed: Vec<String> = inner
            .by_id
            .iter()
            .filter(|(_, state)| state.session.as_deref() == Some(session_id))
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
    fn pages_are_stable_and_chain_through_next_page() {
        let root = scratch("pages");
        for index in 0..7 {
            touch(&root.join(format!("f{index}")), b"x");
        }
        let root_str = root.to_str().unwrap();
        let paths = [".".to_string()];
        let first = list_with_page_size(root_str, &paths, None, 3).unwrap();
        assert_eq!(first[0].entries.len(), 3);
        assert_eq!(first[0].next_page, Some(1));
        let second = list_with_page_size(root_str, &paths, first[0].next_page, 3).unwrap();
        assert_eq!(second[0].entries.len(), 3);
        assert_eq!(second[0].next_page, Some(2));
        let last = list_with_page_size(root_str, &paths, second[0].next_page, 3).unwrap();
        assert_eq!(last[0].entries.len(), 1);
        assert_eq!(last[0].next_page, None);

        let mut seen: Vec<String> = [&first, &second, &last]
            .iter()
            .flat_map(|page| page[0].entries.iter().map(|e| e.name.clone()))
            .collect();
        seen.dedup();
        assert_eq!(seen.len(), 7, "pages must partition, not overlap");
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

    #[test]
    fn grep_lines_parse_with_colons_in_the_text_and_cap_long_lines() {
        let hit = parse_grep_line("src/main.rs:42:let url = \"http://x:8080\";").unwrap();
        assert_eq!(hit.path, "src/main.rs");
        assert_eq!(hit.line, 42);
        assert_eq!(hit.text, "let url = \"http://x:8080\";");

        let long = format!("a.txt:1:{}", "é".repeat(SEARCH_TEXT_CAP));
        let capped = parse_grep_line(&long).unwrap();
        assert!(capped.text.len() <= SEARCH_TEXT_CAP);
        assert!(capped.text.chars().all(|c| c == 'é'), "cut on a boundary");

        assert!(parse_grep_line("no line number here").is_none());
        assert!(parse_grep_line("path:notanumber:text").is_none());
    }

    #[test]
    fn fuzzy_ranking_prefers_basename_and_substring() {
        let hit = |relative: &str, query: &str| {
            let basename = relative.rsplit('/').next().unwrap();
            fuzzy_score(relative, basename, query)
        };
        assert!(hit("src/main.rs", "zzz").is_none());
        let basename_substring = hit("src/main.rs", "main").unwrap();
        let basename_subsequence = hit("src/main.rs", "mrs").unwrap();
        let path_substring = hit("src/main.rs", "src/ma").unwrap();
        let path_subsequence = hit("src/main.rs", "smain").unwrap();
        assert!(basename_substring > basename_subsequence);
        assert!(basename_subsequence > path_substring);
        assert!(path_substring > path_subsequence);
        assert!(
            hit("main.rs", "main").unwrap() > hit("deeply/nested/main.rs", "main").unwrap(),
            "shorter paths win ties"
        );
        assert!(hit("src/Main.RS", "main").is_some(), "case-insensitive");
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
        let landed = uploads.commit(&id).unwrap();
        assert_eq!(std::fs::read(&landed).unwrap(), body);
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&landed).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o644, "project files default to 0644");
        assert_eq!(
            std::fs::read_dir(&root).unwrap().flatten().count(),
            1,
            "the dotfile is gone after the rename"
        );
        assert!(uploads.commit(&id).is_err(), "an upload commits once");
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
        let error = uploads.commit(&id).unwrap_err().to_string();
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
                .commit(&id)
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
        let landed = uploads.commit(&second).unwrap();
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
            std::fs::read(uploads.commit(&third).unwrap()).unwrap(),
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
                Some("s_1".to_string()),
            )
            .unwrap();
        uploads.chunk(&id, 0, &body).unwrap();
        let landed = uploads.commit(&id).unwrap();
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&landed).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "scratch files are 0600 whatever mode asked");

        // A second upload still in flight when the session dies leaves no
        // dotfile behind.
        let dest = resolve_scratch_dest(&root, "paste-2.png").unwrap();
        let (id, _) = uploads
            .open(dest, 4, &hex_sha256(b"gone"), None, Some("s_1".to_string()))
            .unwrap();
        uploads.chunk(&id, 0, b"go").unwrap();
        uploads.drop_session("s_1");
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
