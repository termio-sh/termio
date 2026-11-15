//! The `git:` resource kind (§C.13): status as a subscription, plus the read
//! tier the History and Compare panes are made of.
//!
//! Status is the second consumer of §C.10's one mechanism — id, cursor, ring,
//! gap, linger — nothing new to learn. The host runs a debounced
//! `git status --porcelain=v2` when the workspace watcher reports change and
//! publishes the *delta* against the previous run.
//!
//! Beside it sit four request/response verbs: `git.diff`, `git.log`,
//! `git.show`, `git.branches`. All of them read; the mutation and network
//! tiers are staged separately (`docs/design/20260818-remote-git-plane.md` §5) because
//! they need a design for prompts and for index-lock contention that reads do
//! not. Every one of them runs the box's own `git` as a child process, so the
//! box's config, hooks, and credential helper are the ones in force — nothing
//! here reimplements git.

use crate::protocol::{
    EntryKind, Event, GitBranchEntry, GitCommitEntry, GitCommitFile, GitFileStatus, GitStatusCode,
    GitStatusEntry, GitUnmergedCode,
};
use anyhow::{bail, Context, Result};
use ignore::gitignore::{Gitignore, GitignoreBuilder};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// A `git.diff` reply is cut here — the same preview budget as `fs.read`.
pub const DIFF_CAP: usize = 1024 * 1024;

/// A `git.log` walk stops here however large `limit` was. A history pane
/// scrolls; it does not need the whole repository in one frame.
pub const LOG_CAP: u64 = 1000;

/// A `git.show` file list stops here. A tree-wide commit (a vendor drop, a
/// reformat) would otherwise put a megabyte of file rows on a control channel.
pub const SHOW_FILE_CAP: usize = 5000;

/// A `git.branches` reply stops here. Long-lived clones carry thousands of
/// stale remote-tracking refs and the picker shows a handful.
pub const BRANCH_CAP: usize = 2000;

/// Field separator inside one commit record (US), and the fields themselves.
/// Records are NUL-terminated by `-z` — `tformat:` and not `format:`, so the
/// terminator is there even for the single record `git show` prints — which is
/// what lets a subject holding a newline survive intact.
const FIELD: char = '\u{1f}';
const COMMIT_FORMAT: &str =
    "--pretty=tformat:%H\u{1f}%h\u{1f}%s\u{1f}%an\u{1f}%ae\u{1f}%ad\u{1f}%at\u{1f}%D";

/// Every git child starts here: the box's own git, the box's own config, and
/// `--no-optional-locks` so a read can never contend with the agent committing
/// in the terminal beside it.
fn git_command(root: &str) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("git");
    command.arg("--no-optional-locks").arg("-C").arg(root);
    command
}

/// One repository's ignore rules, read for the listings of one request.
///
/// Matched in this process, never by a `git check-ignore` child. The
/// decoration rides the listing's own reply, so a child process put its spawn,
/// its read of the index and a 5 s timeout under every folder expand, and the
/// listings of one repository waited on each other for it.
///
/// Nothing is kept between requests: each re-list reads the rule files afresh,
/// so an edited `.gitignore` cannot leave a cached decoration behind.
///
/// What this cannot know is the index. Git never reports a tracked file as
/// ignored; a file that was force-added under a rule is dimmed here.
struct IgnoreRules {
    root: PathBuf,
    case_insensitive: bool,
    /// `.git/info/exclude`, then the user's global excludes file: the two
    /// sources git consults after every `.gitignore`, in that order.
    fallbacks: Vec<Gitignore>,
    /// Each directory's own `.gitignore`, read once per request. A batched
    /// listing asks about many folders under the same few parents.
    by_directory: HashMap<PathBuf, Option<Gitignore>>,
}

impl IgnoreRules {
    fn new(root: &Path) -> Self {
        let common = common_git_directory(root);
        let case_insensitive = common
            .as_deref()
            .and_then(|common| read_regular_file(&common.join("config"), true))
            .is_some_and(|config| config_ignores_case(&String::from_utf8_lossy(&config)));
        let mut rules = IgnoreRules {
            root: root.to_path_buf(),
            case_insensitive,
            fallbacks: Vec::new(),
            by_directory: HashMap::new(),
        };
        let sources = [
            common.map(|common| common.join("info").join("exclude")),
            ignore::gitignore::gitconfig_excludes_path(),
        ];
        for source in sources.into_iter().flatten() {
            if let Some(matcher) = rules.read(root, &source, true) {
                rules.fallbacks.push(matcher);
            }
        }
        rules
    }

    /// The rules in one file, anchored at `base`. A line git would reject is
    /// skipped and the rest still apply, as git does.
    ///
    /// Fed a line at a time from bytes read here: the crate's own reader stops
    /// at the first line that is not UTF-8 and drops every rule after it. Such
    /// a line is skipped instead. Entry names reach the matcher as UTF-8, so a
    /// rule that is not could only match a name it does not spell.
    fn read(&self, base: &Path, file: &Path, follow_links: bool) -> Option<Gitignore> {
        let bytes = read_regular_file(file, follow_links)?;
        let mut builder = GitignoreBuilder::new(base);
        if let Err(error) = builder.case_insensitive(self.case_insensitive) {
            eprintln!("[git] ignore rules: {error}");
        }
        let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
        for line in bytes.split(|byte| *byte == b'\n') {
            let Ok(line) = std::str::from_utf8(line) else {
                continue;
            };
            let line = literal_braces(line.strip_suffix('\r').unwrap_or(line));
            if let Err(error) = builder.add_line(Some(file.to_path_buf()), &line) {
                eprintln!("[git] {}: {error}", file.display());
            }
        }
        match builder.build() {
            Ok(matcher) if !matcher.is_empty() => Some(matcher),
            Ok(_) => None,
            Err(error) => {
                eprintln!("[git] {}: {error}", file.display());
                None
            }
        }
    }

    fn own_rules(&mut self, directory: &Path) -> Option<&Gitignore> {
        if !self.by_directory.contains_key(directory) {
            // Git refuses a `.gitignore` that is a link, so one that points out
            // of the checkout cannot bring its rules in.
            let matcher = self.read(directory, &directory.join(".gitignore"), false);
            self.by_directory.insert(directory.to_path_buf(), matcher);
        }
        self.by_directory.get(directory).and_then(Option::as_ref)
    }

    /// Whether `path` is ignored, given that no directory above it is. The
    /// deepest `.gitignore` that has a rule for the path decides, and within
    /// one file the last such rule; a `!` rule there un-ignores it.
    fn matches(&mut self, path: &Path, is_dir: bool) -> bool {
        let mut directory = path.parent();
        while let Some(current) = directory.filter(|current| current.starts_with(&self.root)) {
            if let Some(matcher) = self.own_rules(current) {
                match matcher.matched(path, is_dir) {
                    ignore::Match::Ignore(_) => return true,
                    ignore::Match::Whitelist(_) => return false,
                    ignore::Match::None => {}
                }
            }
            directory = current.parent();
        }
        for matcher in &self.fallbacks {
            match matcher.matched(path, is_dir) {
                ignore::Match::Ignore(_) => return true,
                ignore::Match::Whitelist(_) => return false,
                ignore::Match::None => {}
            }
        }
        false
    }

    /// Whether `directory` sits inside an ignored directory, or is one. Git
    /// never looks inside such a directory, so nothing in it can be
    /// un-ignored and every entry is ignored with it.
    fn is_inside_ignored(&mut self, directory: &Path) -> bool {
        let Ok(relative) = directory.strip_prefix(&self.root) else {
            return false;
        };
        let mut current = self.root.clone();
        for component in relative.components() {
            current.push(component);
            if self.matches(&current, true) {
                return true;
            }
        }
        false
    }
}

/// The most of a rule file or a git config that is read. Real ones are a few
/// kilobytes; a checkout is not trusted to keep them that way.
const RULE_FILE_LIMIT: u64 = 1024 * 1024;

/// A file's bytes, when it is a regular file no larger than `RULE_FILE_LIMIT`.
///
/// Opened without blocking and judged by the descriptor that was opened, not
/// by a look at the path first: a FIFO at one of these names would hold a
/// plain open, and the listing with it, until something wrote to it.
fn read_regular_file(path: &Path, follow_links: bool) -> Option<Vec<u8>> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;

    let flags = if follow_links {
        libc::O_NONBLOCK
    } else {
        libc::O_NONBLOCK | libc::O_NOFOLLOW
    };
    let file = match std::fs::OpenOptions::new().read(true).custom_flags(flags).open(path) {
        Ok(file) => file,
        // Most directories have no rule file, and a link that was refused
        // reports ELOOP. Neither is worth a line per listing.
        Err(error) => {
            if error.kind() != std::io::ErrorKind::NotFound && error.raw_os_error() != Some(libc::ELOOP) {
                eprintln!("[git] {}: {error}", path.display());
            }
            return None;
        }
    };
    match file.metadata() {
        Ok(found) if found.is_file() && found.len() <= RULE_FILE_LIMIT => {}
        Ok(found) if found.is_file() => {
            eprintln!("[git] {}: over {RULE_FILE_LIMIT} bytes, not read", path.display());
            return None;
        }
        Ok(_) => return None,
        Err(error) => {
            eprintln!("[git] {}: {error}", path.display());
            return None;
        }
    }
    let mut bytes = Vec::new();
    // Capped again here: the file can grow between the look and the read.
    match file.take(RULE_FILE_LIMIT).read_to_end(&mut bytes) {
        Ok(_) => Some(bytes),
        Err(error) => {
            eprintln!("[git] {}: {error}", path.display());
            None
        }
    }
}

/// A rule with its braces made literal. The crate reads `{a,b}` as a choice
/// between `a` and `b`; git has no such syntax and matches the braces
/// themselves. Inside a `[...]` class they already are literal.
fn literal_braces(line: &str) -> std::borrow::Cow<'_, str> {
    if !line.contains(['{', '}']) {
        return line.into();
    }
    let mut escaped = String::with_capacity(line.len() + 4);
    let mut in_class = false;
    let mut characters = line.chars();
    while let Some(character) = characters.next() {
        match character {
            '\\' => {
                escaped.push(character);
                escaped.extend(characters.next());
                continue;
            }
            '[' => in_class = true,
            ']' => in_class = false,
            '{' | '}' if !in_class => escaped.push('\\'),
            _ => {}
        }
        escaped.push(character);
    }
    escaped.into()
}

/// Where a checkout keeps the files every worktree of it shares, `info/exclude`
/// and `config` among them. A linked worktree's `.git` is a file that names its
/// own directory, and that directory names the shared one in `commondir`.
///
/// Only the line ending is cut from either path, as git cuts it: a
/// directory's name may end in a space.
fn common_git_directory(root: &Path) -> Option<PathBuf> {
    fn path_in(bytes: &[u8]) -> String {
        String::from_utf8_lossy(bytes).trim_end_matches(['\n', '\r']).to_owned()
    }
    let dot_git = root.join(".git");
    let own = if dot_git.is_dir() {
        dot_git
    } else {
        let pointer = path_in(&read_regular_file(&dot_git, true)?);
        root.join(pointer.strip_prefix("gitdir: ")?)
    };
    match read_regular_file(&own.join("commondir"), true) {
        Some(common) => Some(own.join(path_in(&common))),
        None => Some(own),
    }
}

/// `core.ignorecase`, which `git init` writes on a filesystem that folds case.
/// Git matches ignore rules without regard to case when it is set.
///
/// The last setting wins, as in git. A value in quotes or one carried in from
/// an `include` is not read; such a checkout is matched with regard to case.
fn config_ignores_case(config: &str) -> bool {
    let mut in_core = false;
    let mut ignores_case = false;
    // A line ending in a backslash carries its value onto the next line,
    // which is then no setting of its own.
    let mut continued = false;
    for line in config.strip_prefix('\u{feff}').unwrap_or(config).lines() {
        let is_continuation = continued;
        let line = line.split(['#', ';']).next().unwrap_or_default().trim();
        continued = line.ends_with('\\');
        if is_continuation {
            continue;
        }
        if line.starts_with('[') {
            in_core = line.eq_ignore_ascii_case("[core]");
            continue;
        }
        let (key, value) = match line.split_once('=') {
            Some((key, value)) => (key.trim(), Some(value.trim())),
            None => (line, None),
        };
        if in_core && key.eq_ignore_ascii_case("ignorecase") {
            // A key with no value is git's spelling of true, and so is any
            // number but zero.
            ignores_case = value.is_none_or(|value| {
                ["true", "yes", "on"].iter().any(|yes| value.eq_ignore_ascii_case(yes))
                    || value.parse::<i64>().is_ok_and(|number| number != 0)
            });
        }
    }
    ignores_case
}

/// Marks the entries of each listing that the repository's ignore rules cover.
/// A listing outside any repository is left as it is.
///
/// Reads files, so it runs on the blocking pool beside the listing itself.
pub fn decorate_listings(listings: &mut [crate::protocol::PathListing]) {
    let mut repositories: HashMap<PathBuf, IgnoreRules> = HashMap::new();
    for listing in listings.iter_mut() {
        // Canonical, so a folder reached through a link is matched against
        // the repository it is really in.
        let Ok(directory) = std::fs::canonicalize(&listing.path) else {
            continue;
        };
        let Some(root) = directory
            .ancestors()
            .find(|path| path.join(".git").exists())
            .map(Path::to_path_buf)
        else {
            continue;
        };
        let rules = repositories
            .entry(root.clone())
            .or_insert_with(|| IgnoreRules::new(&root));
        let inside_ignored = rules.is_inside_ignored(&directory);
        for entry in &mut listing.entries {
            // The repository's own directory is never a file of the checkout.
            if entry.name == ".git" && directory == root {
                entry.ignored = false;
                continue;
            }
            // A link is a file to git, whatever it points at.
            let is_dir = matches!(entry.kind, EntryKind::Dir | EntryKind::UnloadedDir);
            entry.ignored = inside_ignored || rules.matches(&directory.join(&entry.name), is_dir);
        }
    }
}

/// A revision reaches git as a positional argument, so one beginning with `-`
/// would be read as an option. Refused rather than escaped.
fn validate_revision(revision: &str) -> Result<()> {
    if revision.is_empty() || revision.starts_with('-') {
        bail!("not a usable revision: {revision:?}");
    }
    Ok(())
}

/// Everything one status run said. The live copy backs the synthetic
/// full-state batch a gap subscriber receives — only the host can "rescan"
/// git status, so on gap it does the scan for the client.
/// What one status run said about one path. Kept apart from the wire entry so
/// the snapshot can be diffed by value: a file whose line counts moved has
/// changed as far as the row is concerned, even when its status letter did not.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FileState {
    pub status: Option<GitFileStatus>,
    pub original_path: Option<String>,
    pub additions: u64,
    pub deletions: u64,
    pub binary: bool,
}

impl FileState {
    fn new(status: GitFileStatus) -> FileState {
        FileState {
            status: Some(status),
            ..FileState::default()
        }
    }

    fn entry(&self, path: &str) -> Option<GitStatusEntry> {
        Some(GitStatusEntry {
            path: path.to_string(),
            status: self.status?,
            original_path: self.original_path.clone(),
            additions: self.additions,
            deletions: self.deletions,
            binary: self.binary,
        })
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct GitSnapshot {
    pub statuses: HashMap<String, FileState>,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub ahead_behind: Option<(u32, u32)>,
    /// How many paths the status run actually named, when the list was cut
    /// below that (see [`STATUS_CAP`]). Carried on every batch so the pane can
    /// say how much is missing rather than let a cut list read as the whole
    /// truth — with five thousand conflicts, "first 5,000" and "first 5,000 of
    /// 41,900" are different answers.
    pub total: Option<u64>,
}

impl GitSnapshot {
    pub fn conflicts(&self) -> Vec<String> {
        let mut paths: Vec<String> = self
            .statuses
            .iter()
            .filter(|(_, state)| matches!(state.status, Some(GitFileStatus::Unmerged { .. })))
            .map(|(path, _)| path.clone())
            .collect();
        paths.sort();
        paths
    }

    /// The full state as one batch — what a fresh or gap subscriber applies
    /// to an empty baseline.
    pub fn full_batch(&self) -> GitBatch {
        let mut updated: Vec<GitStatusEntry> = self
            .statuses
            .iter()
            .filter_map(|(path, state)| state.entry(path))
            .collect();
        updated.sort_by(|a, b| a.path.cmp(&b.path));
        GitBatch {
            updated_statuses: updated,
            removed_paths: Vec::new(),
            branch: self.branch.clone(),
            head: self.head.clone(),
            ahead_behind: self.ahead_behind,
            conflicts: self.conflicts(),
            total: self.total,
        }
    }

    /// The delta that turns `previous` into `self`, or `None` when nothing a
    /// client can see moved.
    pub fn delta_from(&self, previous: &GitSnapshot) -> Option<GitBatch> {
        let mut updated: Vec<GitStatusEntry> = self
            .statuses
            .iter()
            .filter(|(path, state)| previous.statuses.get(*path) != Some(state))
            .filter_map(|(path, state)| state.entry(path))
            .collect();
        updated.sort_by(|a, b| a.path.cmp(&b.path));
        let mut removed: Vec<String> = previous
            .statuses
            .keys()
            .filter(|path| !self.statuses.contains_key(*path))
            .cloned()
            .collect();
        removed.sort();

        let metadata_moved = self.branch != previous.branch
            || self.head != previous.head
            || self.ahead_behind != previous.ahead_behind
            || self.total != previous.total;
        if updated.is_empty() && removed.is_empty() && !metadata_moved {
            return None;
        }
        Some(GitBatch {
            updated_statuses: updated,
            removed_paths: removed,
            branch: self.branch.clone(),
            head: self.head.clone(),
            ahead_behind: self.ahead_behind,
            conflicts: self.conflicts(),
            total: self.total,
        })
    }
}

/// One published `git_changed` batch (the §C.10 ring element for this kind).
#[derive(Debug, Clone, PartialEq)]
pub struct GitBatch {
    pub updated_statuses: Vec<GitStatusEntry>,
    pub removed_paths: Vec<String>,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub ahead_behind: Option<(u32, u32)>,
    pub conflicts: Vec<String>,
    /// How many paths there really are, when the list was cut — see
    /// [`STATUS_CAP`].
    pub total: Option<u64>,
}

impl GitBatch {
    pub fn into_event(self, resource: String, seq: u64) -> Event {
        Event::GitChanged {
            resource,
            seq,
            updated_statuses: self.updated_statuses,
            removed_paths: self.removed_paths,
            branch: self.branch,
            head: self.head,
            ahead_behind: self.ahead_behind,
            conflicts: self.conflicts,
            total: self.total,
        }
    }
}

/// Everything a `head:` resource says: which branch the checkout is on, or the
/// commit it is detached at. This is the branch label a client keeps beside a
/// checkout's name — always on, for every checkout a sidebar shows — so it has
/// to cost nothing: one file read per workspace event, no git child. The full
/// `git:` kind runs a status per event and is rightly reserved for an open
/// Changes pane.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HeadSnapshot {
    /// The branch `HEAD` names, `None` when detached — the same split the
    /// `git_changed` metadata carries.
    pub branch: Option<String>,
    /// The commit a detached `HEAD` sits at, abbreviated to 7 characters. A
    /// display label does not need git's ambiguity-aware lengthening, and
    /// asking for it would cost the child process this kind exists to avoid.
    pub head: Option<String>,
}

impl HeadSnapshot {
    pub fn into_event(self, resource: String, seq: u64) -> Event {
        Event::HeadChanged {
            resource,
            seq,
            branch: self.branch,
            head: self.head,
        }
    }
}

/// Read the checkout's HEAD without spawning git: `.git/HEAD` is either
/// `ref: refs/heads/<branch>` or a bare commit hash. A linked worktree's
/// `.git` is a *file* holding `gitdir: <admin dir>`, and its HEAD lives there.
/// Any failure — not a repo, unreadable, garbage — is the empty snapshot: the
/// client hides the label, the same degrade the Mac's own HEAD parser takes.
pub fn read_head(root: &str) -> HeadSnapshot {
    let dot_git = Path::new(root).join(".git");
    let head_path = if dot_git.is_dir() {
        dot_git.join("HEAD")
    } else {
        let Ok(pointer) = std::fs::read_to_string(&dot_git) else {
            return HeadSnapshot::default();
        };
        let Some(git_dir) = pointer.trim().strip_prefix("gitdir:").map(str::trim) else {
            return HeadSnapshot::default();
        };
        let git_dir = if Path::new(git_dir).is_absolute() {
            std::path::PathBuf::from(git_dir)
        } else {
            Path::new(root).join(git_dir)
        };
        git_dir.join("HEAD")
    };
    let Ok(raw) = std::fs::read_to_string(&head_path) else {
        return HeadSnapshot::default();
    };
    let content = raw.trim();
    if let Some(reference) = content.strip_prefix("ref: ") {
        let label = reference.strip_prefix("refs/heads/").unwrap_or(reference);
        if label.is_empty() {
            return HeadSnapshot::default();
        }
        return HeadSnapshot {
            branch: Some(label.to_string()),
            head: None,
        };
    }
    if content.len() >= 7 && content.chars().all(|c| c.is_ascii_hexdigit()) {
        return HeadSnapshot {
            branch: None,
            head: Some(content[..7].to_string()),
        };
    }
    HeadSnapshot::default()
}

/// Run `git status --porcelain=v2 -z` for the repo at `root`.
/// `--no-optional-locks` matters: a plain `git status` refreshes the index
/// file, which the workspace watcher reports as `git_meta`, which would
/// trigger this again — a feedback loop by construction.
pub async fn run_status(root: &str) -> Result<GitSnapshot> {
    let output = git_command(root)
        .arg("status")
        .arg("--porcelain=v2")
        .arg("-z")
        .arg("--branch")
        .arg("--untracked-files=all")
        .output()
        .await
        .context("running git status")?;
    if !output.status.success() {
        bail!(
            "git status failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let mut snapshot = parse_porcelain_v2(&output.stdout)?;
    cap_statuses(&mut snapshot);
    apply_counts(root, &mut snapshot).await;
    Ok(snapshot)
}

/// The most changed paths one `git_changed` batch will ever carry.
///
/// A batch is one frame, and a frame over `protocol::MAX_FRAME_SIZE` is a write
/// error that takes the whole connection down with it — the file tree and agent
/// status ride the same channel. `--untracked-files=all` over a checkout with a
/// missing `.gitignore` reaches that easily: a `node_modules` tree is hundreds
/// of thousands of paths. So the list is cut here, at a size no reviewer reads
/// past, and the batch says it was cut.
pub const STATUS_CAP: usize = 5_000;

/// And the most path bytes, because the entry count alone does not bound a
/// frame — a deeply nested tree can carry very long paths.
///
/// Counted as *encoded* bytes, not raw ones: a byte a filename may legally
/// hold and JSON may not — POSIX forbids only NUL and `/` — becomes six
/// characters (`\u0001`), so a raw-byte budget is a sixth of the bound it
/// looks like. One batch spends its paths three times (updated, removed,
/// conflicts), which puts the worst frame at 3 MiB plus at most `STATUS_CAP`
/// entry envelopes — clear of `MAX_FRAME_SIZE` with room that does not depend
/// on what a path happens to contain.
const STATUS_PATH_BYTES_CAP: usize = 1024 * 1024;

/// What one string costs inside a JSON document. Control bytes escape to six
/// characters, a quote or a backslash to two, and everything else — UTF-8
/// included — passes through as itself.
fn json_cost(text: &str) -> usize {
    text.bytes()
        .map(|byte| match byte {
            b'"' | b'\\' => 2,
            0x08 | 0x09 | 0x0a | 0x0c | 0x0d => 2,
            0x00..=0x1f => 6,
            _ => 1,
        })
        .sum()
}

/// Cut an oversized status list down to what a batch may carry.
///
/// Conflicts survive first — the one status that must be acted on — then the
/// rest of the tracked changes, and untracked paths fill what is left: the
/// flood case is always untracked build output, and the edits a person is
/// reviewing are the rows that must outlive it. That is the order the pane
/// already sorts rows in. Within each tier the order is by path, so the cut is
/// deterministic — two consecutive runs over an unchanged flooded tree keep the
/// same rows and produce no delta.
fn cap_statuses(snapshot: &mut GitSnapshot) {
    // Both bounds are checked before the fast path: five thousand entries is
    // not the only way past a frame, and neither is a million bytes of path.
    // A rename spends its budget twice — the row names where the file came
    // from as well as where it is.
    let cost = |state: &FileState, path: &String| {
        json_cost(path) + state.original_path.as_deref().map_or(0, json_cost)
    };
    let encoded: usize = snapshot
        .statuses
        .iter()
        .map(|(path, state)| cost(state, path))
        .sum();
    if snapshot.statuses.len() <= STATUS_CAP && encoded <= STATUS_PATH_BYTES_CAP {
        return;
    }

    let mut paths: Vec<&String> = snapshot.statuses.keys().collect();
    paths.sort_by_key(|path| {
        let tier = match snapshot.statuses[*path].status {
            Some(GitFileStatus::Unmerged { .. }) => 0,
            Some(GitFileStatus::Untracked) | Some(GitFileStatus::Ignored) => 2,
            _ => 1,
        };
        (tier, *path)
    });
    let mut bytes = 0usize;
    let mut keep: HashSet<String> = HashSet::new();
    for path in paths.into_iter().take(STATUS_CAP) {
        bytes += cost(&snapshot.statuses[path], path);
        if bytes > STATUS_PATH_BYTES_CAP {
            break;
        }
        keep.insert(path.clone());
    }
    if keep.len() == snapshot.statuses.len() {
        return;
    }
    snapshot.total = Some(snapshot.statuses.len() as u64);
    snapshot.statuses.retain(|path, _| keep.contains(path));
}

/// Above this many untracked files the per-file line counts are skipped
/// wholesale — the flood case, almost always a missing `.gitignore` over a
/// build directory. The Mac client degrades at the same number for the same
/// reason, and so does VS Code at its `git.statusLimit`.
const UNTRACKED_COUNT_LIMIT: usize = 500;

/// An untracked file bigger than this is never line-counted: nobody reviews a
/// multi-megabyte file by its `+N` badge.
const UNTRACKED_SIZE_LIMIT: u64 = 4_000_000;

/// Fills each changed path's `+N −M`: `git diff --numstat` merged with
/// `--cached` for tracked files, and a line count for untracked ones.
///
/// This mirrors the Mac client's local pass field for field, deliberately — the
/// Changes pane must read the same whether the checkout is on this box or
/// another one, and "the same" includes what the numbers mean and when they are
/// withheld.
async fn apply_counts(root: &str, snapshot: &mut GitSnapshot) {
    let mut counts: HashMap<String, (u64, u64)> = HashMap::new();
    let mut binaries: HashSet<String> = HashSet::new();
    for cached in [false, true] {
        let mut command = git_command(root);
        command.arg("diff").arg("--numstat");
        if cached {
            command.arg("--cached");
        }
        let Ok(output) = command.output().await else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let mut fields = line.splitn(3, '\t');
            let (Some(added), Some(deleted), Some(path)) =
                (fields.next(), fields.next(), fields.next())
            else {
                continue;
            };
            if added == "-" {
                binaries.insert(path.to_string());
                continue;
            }
            let entry = counts.entry(path.to_string()).or_insert((0, 0));
            entry.0 += added.parse::<u64>().unwrap_or(0);
            entry.1 += deleted.parse::<u64>().unwrap_or(0);
        }
    }

    let untracked_flood = snapshot
        .statuses
        .values()
        .filter(|state| state.status == Some(GitFileStatus::Untracked))
        .count()
        > UNTRACKED_COUNT_LIMIT;

    for (path, state) in snapshot.statuses.iter_mut() {
        if state.status != Some(GitFileStatus::Untracked) {
            if let Some((added, deleted)) = counts.get(path) {
                state.additions = *added;
                state.deletions = *deleted;
            }
            state.binary = binaries.contains(path);
        }
    }

    if untracked_flood {
        return;
    }
    let untracked: Vec<String> = snapshot
        .statuses
        .iter()
        .filter(|(_, state)| state.status == Some(GitFileStatus::Untracked))
        .map(|(path, _)| path.clone())
        .collect();
    if untracked.is_empty() {
        return;
    }
    // Counting lines is bounded but blocking — up to `UNTRACKED_COUNT_LIMIT`
    // files of `UNTRACKED_SIZE_LIMIT` each, read synchronously. Doing that on a
    // runtime worker parks whatever else that worker was carrying, including a
    // connection's writes; `files.rs` moves its directory reads off the runtime
    // for the same reason, and this is the larger read of the two.
    let root_path = Path::new(root).to_path_buf();
    let counted = tokio::task::spawn_blocking(move || {
        untracked
            .into_iter()
            .map(|path| {
                let count = untracked_line_count(&root_path.join(&path));
                (path, count)
            })
            .collect::<Vec<_>>()
    })
    .await;
    let Ok(counted) = counted else { return };
    for (path, count) in counted {
        let Some(state) = snapshot.statuses.get_mut(&path) else {
            continue;
        };
        match count {
            UntrackedCount::Lines(lines) => state.additions = lines,
            UntrackedCount::Binary => state.binary = true,
            UntrackedCount::Skip => {}
        }
    }
}

enum UntrackedCount {
    Lines(u64),
    Binary,
    Skip,
}

/// The `+N` for one untracked file: bounded chunked reads counting newlines,
/// never a whole-file decode. A NUL in the first chunk marks it binary, which
/// is git's own sniff; crossing the size cap gives up rather than paying for it.
fn untracked_line_count(path: &Path) -> UntrackedCount {
    use std::io::Read;
    let Ok(mut file) = std::fs::File::open(path) else {
        return UntrackedCount::Skip;
    };
    let mut buffer = vec![0u8; 262_144];
    let mut lines = 0u64;
    let mut total = 0u64;
    let mut last_byte = b'\n';
    let mut first_chunk = true;
    loop {
        let read = match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => read,
            Err(_) => return UntrackedCount::Skip,
        };
        let chunk = &buffer[..read];
        if first_chunk {
            if chunk[..chunk.len().min(8000)].contains(&0) {
                return UntrackedCount::Binary;
            }
            first_chunk = false;
        }
        total += read as u64;
        if total > UNTRACKED_SIZE_LIMIT {
            return UntrackedCount::Skip;
        }
        lines += chunk.iter().filter(|byte| **byte == b'\n').count() as u64;
        last_byte = *chunk.last().unwrap_or(&last_byte);
    }
    if first_chunk {
        return UntrackedCount::Skip; // empty, or vanished mid-read: no badge
    }
    if last_byte != b'\n' {
        lines += 1;
    }
    UntrackedCount::Lines(lines)
}

/// Parse `--porcelain=v2 -z` output. Records are NUL-terminated; a rename
/// record (`2`) is followed by one extra NUL-terminated field holding the
/// original path.
pub fn parse_porcelain_v2(bytes: &[u8]) -> Result<GitSnapshot> {
    let mut snapshot = GitSnapshot::default();
    let mut fields = bytes.split(|&byte| byte == 0);
    while let Some(record) = fields.next() {
        if record.is_empty() {
            continue;
        }
        let record = String::from_utf8_lossy(record);
        if let Some(header) = record.strip_prefix("# ") {
            parse_branch_header(header, &mut snapshot);
            continue;
        }
        let mut parts = record.splitn(2, ' ');
        let tag = parts.next().unwrap_or_default();
        let rest = parts.next().unwrap_or_default();
        match tag {
            "1" => {
                // 1 XY sub mH mI mW hH hI <path>
                let mut columns = rest.splitn(8, ' ');
                let xy = columns.next().unwrap_or_default();
                let path = columns.nth(6).unwrap_or_default();
                if let (Some(status), false) = (tracked_status(xy), path.is_empty()) {
                    snapshot
                        .statuses
                        .insert(path.to_string(), FileState::new(status));
                }
            }
            "2" => {
                // 2 XY sub mH mI mW hH hI Xscore <path> NUL <origPath>
                let mut columns = rest.splitn(9, ' ');
                let xy = columns.next().unwrap_or_default();
                let path = columns.nth(7).unwrap_or_default();
                // The origPath field must be consumed either way, or it is read
                // as the next record. It is also what the row's `old → new`
                // tooltip is made of, so it is kept rather than dropped.
                let original = fields
                    .next()
                    .map(|field| String::from_utf8_lossy(field).into_owned())
                    .filter(|field| !field.is_empty());
                if let (Some(status), false) = (tracked_status(xy), path.is_empty()) {
                    let mut state = FileState::new(status);
                    state.original_path = original;
                    snapshot.statuses.insert(path.to_string(), state);
                }
            }
            "u" => {
                // u XY sub m1 m2 m3 mW h1 h2 h3 <path>
                let mut columns = rest.splitn(10, ' ');
                let xy = columns.next().unwrap_or_default();
                let path = columns.nth(8).unwrap_or_default();
                if let (Some(status), false) = (unmerged_status(xy), path.is_empty()) {
                    snapshot
                        .statuses
                        .insert(path.to_string(), FileState::new(status));
                }
            }
            "?" => {
                snapshot
                    .statuses
                    .insert(rest.to_string(), FileState::new(GitFileStatus::Untracked));
            }
            "!" => {
                snapshot
                    .statuses
                    .insert(rest.to_string(), FileState::new(GitFileStatus::Ignored));
            }
            _ => {}
        }
    }
    Ok(snapshot)
}

fn parse_branch_header(header: &str, snapshot: &mut GitSnapshot) {
    if let Some(oid) = header.strip_prefix("branch.oid ") {
        if oid != "(initial)" {
            snapshot.head = Some(oid.to_string());
        }
    } else if let Some(name) = header.strip_prefix("branch.head ") {
        if name != "(detached)" {
            snapshot.branch = Some(name.to_string());
        }
    } else if let Some(ab) = header.strip_prefix("branch.ab ") {
        let mut parts = ab.split(' ');
        let ahead = parts
            .next()
            .and_then(|part| part.strip_prefix('+'))
            .and_then(|part| part.parse().ok());
        let behind = parts
            .next()
            .and_then(|part| part.strip_prefix('-'))
            .and_then(|part| part.parse().ok());
        if let (Some(ahead), Some(behind)) = (ahead, behind) {
            snapshot.ahead_behind = Some((ahead, behind));
        }
    }
}

fn status_code(byte: u8) -> Option<GitStatusCode> {
    match byte {
        b'.' => Some(GitStatusCode::Unmodified),
        b'M' => Some(GitStatusCode::Modified),
        b'T' => Some(GitStatusCode::TypeChanged),
        b'A' => Some(GitStatusCode::Added),
        b'D' => Some(GitStatusCode::Deleted),
        b'R' => Some(GitStatusCode::Renamed),
        b'C' => Some(GitStatusCode::Copied),
        _ => None,
    }
}

fn tracked_status(xy: &str) -> Option<GitFileStatus> {
    let bytes = xy.as_bytes();
    if bytes.len() != 2 {
        return None;
    }
    Some(GitFileStatus::Tracked {
        index_status: status_code(bytes[0])?,
        worktree_status: status_code(bytes[1])?,
    })
}

fn unmerged_code(byte: u8) -> Option<GitUnmergedCode> {
    match byte {
        b'U' => Some(GitUnmergedCode::Updated),
        b'A' => Some(GitUnmergedCode::Added),
        b'D' => Some(GitUnmergedCode::Deleted),
        _ => None,
    }
}

fn unmerged_status(xy: &str) -> Option<GitFileStatus> {
    let bytes = xy.as_bytes();
    if bytes.len() != 2 {
        return None;
    }
    Some(GitFileStatus::Unmerged {
        first_head: unmerged_code(bytes[0])?,
        second_head: unmerged_code(bytes[1])?,
    })
}

/// `git.diff` (§C.13): a unified diff for one path, worktree-vs-index by
/// default, index-vs-HEAD with `staged`. Capped at [`DIFF_CAP`].
/// `git.diff` (§C.13): the unified diff for one working-tree path.
///
/// `git diff -- <path>` alone answers for exactly one of the four cases a
/// Changes row can be in, and empty for the rest — an untracked file has no
/// diff at all, and a fully-staged change lives in the index. So this walks the
/// same ladder the Mac's local `GitService.loadDiffText` walks, in the same
/// order, because a row must show the same diff whichever machine the checkout
/// is on. Measured against a real device before it did: 44 rows, every one of
/// them an empty diff.
///
/// `context` is the `-U` the client wants. The overlay asks for a very large one
/// so it holds the whole file and can fold unchanged runs into bands the reader
/// expands; without it a remote diff renders with git's default three lines and
/// silently loses that.
pub async fn run_diff(
    root: &str,
    path: &str,
    staged: bool,
    context: Option<u64>,
) -> Result<(String, bool)> {
    let unified: Vec<String> = context
        .map(|lines| vec![format!("-U{lines}")])
        .unwrap_or_default();

    // An untracked file is not in the index and not in HEAD, so every ordinary
    // form of `git diff` says nothing about it. `--no-index` against /dev/null
    // is what makes it read as one big addition — and it exits non-zero when the
    // two differ, which is the normal case, so its status is not an error.
    let mut against_nothing = git_command(root);
    against_nothing.arg("diff").arg("--no-index");
    for argument in &unified {
        against_nothing.arg(argument);
    }
    against_nothing.arg("--").arg("/dev/null").arg(path);

    // `diff HEAD` shows staged and unstaged together, which is what the row is
    // about; the split forms are the fallback for a repo with no commit yet and
    // for a change that is entirely in the index.
    let mut ladder: Vec<Vec<String>> = Vec::new();
    if staged {
        ladder.push(vec!["--cached".into()]);
    }
    ladder.push(vec!["HEAD".into()]);
    ladder.push(vec![]);
    ladder.push(vec!["--cached".into()]);

    for revision in ladder {
        let mut command = git_command(root);
        command.arg("diff");
        for argument in &unified {
            command.arg(argument);
        }
        for argument in &revision {
            command.arg(argument);
        }
        command.arg("--").arg(path);
        let output = command.output().await.context("running git diff")?;
        // A form that does not apply here (no HEAD yet, a path git will not
        // diff that way) is not a failure — it is the reason there is a ladder.
        if !output.status.success() {
            continue;
        }
        let diff = String::from_utf8_lossy(&output.stdout).into_owned();
        if !diff.is_empty() {
            return Ok(cap_diff(diff));
        }
    }

    let output = against_nothing
        .output()
        .await
        .context("running git diff --no-index")?;
    let diff = String::from_utf8_lossy(&output.stdout).into_owned();
    if diff.is_empty() && !output.status.success() {
        bail!(
            "git diff failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(cap_diff(diff))
}

/// Cut a diff at [`DIFF_CAP`] on a character boundary, reporting that it was
/// cut. A client is told the text is partial; it is never handed a silently
/// short diff.
fn cap_diff(mut diff: String) -> (String, bool) {
    let truncated = diff.len() > DIFF_CAP;
    if truncated {
        let mut cut = DIFF_CAP;
        while !diff.is_char_boundary(cut) {
            cut -= 1;
        }
        diff.truncate(cut);
    }
    (diff, truncated)
}

/// One `git.log` page: commits newest first, and whether the walk stopped at
/// the limit rather than at the root.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitLogPage {
    pub commits: Vec<GitCommitEntry>,
    pub truncated: bool,
}

/// `git.log` (§C.13 read tier): the commit list behind the History tab.
/// `range` narrows the walk (`origin/main..HEAD` for a branch comparison).
pub async fn run_log(root: &str, limit: u64, range: Option<&str>) -> Result<GitLogPage> {
    if let Some(range) = range {
        validate_revision(range)?;
    }
    let wanted = limit.clamp(1, LOG_CAP);
    let mut command = git_command(root);
    command
        .arg("log")
        .arg("-z")
        .arg("-n")
        .arg(wanted.to_string())
        .arg("--date=relative")
        .arg(COMMIT_FORMAT);
    if let Some(range) = range {
        command.arg(range);
    }
    let output = command.output().await.context("running git log")?;
    if !output.status.success() {
        // A repository whose first commit is still unwritten has no history,
        // which is an empty list, not a failure. Asked of git rather than
        // matched against its stderr, which is localized.
        if !has_commits(root).await {
            return Ok(GitLogPage {
                commits: Vec::new(),
                truncated: false,
            });
        }
        bail!(
            "git log failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let unpushed = unpushed_commits(root).await;
    let commits = parse_commits(&output.stdout, &unpushed);
    let truncated = commits.len() as u64 >= wanted;
    Ok(GitLogPage { commits, truncated })
}

/// One commit as `git.show` reports it: what it is, what it touched, and the
/// diff — the whole commit's, or one file's when the caller named a path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitCommitDetail {
    pub commit: GitCommitEntry,
    pub files: Vec<GitCommitFile>,
    pub diff: String,
    pub truncated: bool,
    pub files_truncated: bool,
}

/// `git.show` (§C.13 read tier). `--first-parent` throughout: without it a
/// merge commit's diff is a combined diff, which is empty for a clean merge,
/// so every merged pull request in the history would read as touching nothing.
pub async fn run_show(root: &str, commit: &str, path: Option<&str>) -> Result<GitCommitDetail> {
    validate_revision(commit)?;
    // Metadata and the file list in one child: `--raw` carries the status
    // letter and `--numstat` the counts, already keyed by the same paths.
    let described = git_command(root)
        .arg("show")
        .arg(COMMIT_FORMAT)
        .arg("--date=relative")
        .arg("--raw")
        .arg("--numstat")
        .arg("-z")
        .arg("-M")
        .arg("--first-parent")
        .arg(commit)
        .output()
        .await
        .context("running git show")?;
    if !described.status.success() {
        bail!(
            "git show failed: {}",
            String::from_utf8_lossy(&described.stderr).trim()
        );
    }
    let unpushed = unpushed_commits(root).await;
    let (mut entry, files, files_truncated) = parse_commit_detail(&described.stdout)?;
    entry.unpushed = unpushed.contains(&entry.sha);

    let mut command = git_command(root);
    command
        .arg("show")
        .arg("--format=")
        .arg("-M")
        .arg("--first-parent")
        .arg(commit);
    if let Some(path) = path {
        // A rename is limited to *both* paths: git applies the path limit
        // before rename detection, so asking for the destination alone turns a
        // pure rename into the whole file arriving as additions.
        command.arg("--").arg(path);
        if let Some(original) = files
            .iter()
            .find(|file| file.path == path)
            .and_then(|file| file.original_path.as_deref())
        {
            command.arg(original);
        }
    }
    let patch = command.output().await.context("running git show")?;
    if !patch.status.success() {
        bail!(
            "git show failed: {}",
            String::from_utf8_lossy(&patch.stderr).trim()
        );
    }
    let (diff, truncated) = cap_diff(String::from_utf8_lossy(&patch.stdout).into_owned());
    Ok(GitCommitDetail {
        commit: entry,
        files,
        diff,
        truncated,
        files_truncated,
    })
}

/// The refs a checkout can be compared against, plus where it stands.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GitBranchList {
    pub branches: Vec<GitBranchEntry>,
    pub current: Option<String>,
    pub default_branch: Option<String>,
    pub truncated: bool,
}

/// `git.branches` (§C.13 read tier). One `for-each-ref` answers all of it:
/// `%(HEAD)` marks the checkout's own branch and `%(symref)` resolves
/// `origin/HEAD` to the default branch, so the picker costs one child process
/// rather than one per field.
pub async fn run_branches(root: &str) -> Result<GitBranchList> {
    let output = git_command(root)
        .arg("for-each-ref")
        .arg("--format=%(HEAD) %(refname) %(symref)")
        .arg("refs/heads")
        .arg("refs/remotes")
        .output()
        .await
        .context("running git for-each-ref")?;
    if !output.status.success() {
        bail!(
            "git for-each-ref failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(parse_refs(&String::from_utf8_lossy(&output.stdout)))
}

/// The branch against a base, as `git_compare` answers it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitCompareOutcome {
    pub files: Vec<GitCommitFile>,
    pub commits: Vec<GitCommitEntry>,
    pub behind: u64,
    pub diff: String,
    pub truncated: bool,
    pub files_truncated: bool,
    pub commits_truncated: bool,
    pub problem: Option<crate::protocol::GitCompareProblem>,
}

/// How many commits one comparison carries — the local pane's own limit.
const COMPARE_LOG_CAP: u64 = 200;

/// `git.compare` (§C.13 read tier): the three-dot file list, the commits the
/// merge would bring, and the behind count — the whole Compare tab in one
/// reply, plus one file's ranged diff when `path` narrows it.
///
/// One reply on purpose: `HEAD` is resolved to a sha once and every walk uses
/// the sha, so a commit or checkout landing between the child processes cannot
/// hand back a file list from one head and commits from another. Composed
/// client-side from `git_log` + `git_compare`, that tear was reachable.
///
/// The two problems are asked of git up front rather than inferred from a
/// failed diff: without a merge base the three-dot diff exits non-zero and
/// would degrade to an empty file list, while `base..HEAD` still lists
/// commits — so the tab would show "no files, 40 commits" instead of what is
/// actually wrong.
pub async fn run_compare(root: &str, base: &str, path: Option<&str>) -> Result<GitCompareOutcome> {
    validate_revision(base)?;
    let problem = |problem| {
        Ok(GitCompareOutcome {
            files: Vec::new(),
            commits: Vec::new(),
            behind: 0,
            diff: String::new(),
            truncated: false,
            files_truncated: false,
            commits_truncated: false,
            problem: Some(problem),
        })
    };
    let resolved = git_command(root)
        .arg("rev-parse")
        .arg("--verify")
        .arg("--quiet")
        .arg(format!("{base}^{{commit}}"))
        .output()
        .await
        .context("running git rev-parse")?;
    if !resolved.status.success() {
        return problem(crate::protocol::GitCompareProblem::MissingBase);
    }
    let merge_base = git_command(root)
        .arg("merge-base")
        .arg(base)
        .arg("HEAD")
        .output()
        .await
        .context("running git merge-base")?;
    if !merge_base.status.success() {
        return problem(crate::protocol::GitCompareProblem::NoCommonHistory);
    }
    let pinned = git_command(root)
        .arg("rev-parse")
        .arg("HEAD")
        .output()
        .await
        .context("running git rev-parse")?;
    if !pinned.status.success() {
        bail!(
            "git rev-parse failed: {}",
            String::from_utf8_lossy(&pinned.stderr).trim()
        );
    }
    let head = String::from_utf8_lossy(&pinned.stdout).trim().to_string();

    // Three dots: from the merge base, so commits that landed on the base
    // since this branch started don't show up inverted as changes the branch
    // never made.
    let range = format!("{base}...{head}");
    let listed = git_command(root)
        .arg("diff")
        .arg("--raw")
        .arg("--numstat")
        .arg("-z")
        .arg("-M")
        .arg(&range)
        .output()
        .await
        .context("running git diff")?;
    if !listed.status.success() {
        bail!(
            "git diff failed: {}",
            String::from_utf8_lossy(&listed.stderr).trim()
        );
    }
    let mut fields = listed.stdout.split(|&byte| byte == 0).map(|field| {
        String::from_utf8_lossy(field)
            .trim_start_matches('\n')
            .to_string()
    });
    let (files, files_truncated) = parse_diff_files(&mut fields);

    // Two dots for the count — "how far apart are the tips", not "what would
    // merge". Measured against the last fetched state; nothing here fetches.
    let counted = git_command(root)
        .arg("rev-list")
        .arg("--count")
        .arg(format!("{head}..{base}"))
        .output()
        .await
        .context("running git rev-list")?;
    let behind = String::from_utf8_lossy(&counted.stdout)
        .trim()
        .parse()
        .unwrap_or(0);

    // The commits the merge would bring, walked from the same pinned head.
    let log = run_log(root, COMPARE_LOG_CAP, Some(&format!("{base}..{head}"))).await?;

    let (diff, truncated) = if let Some(path) = path {
        let mut command = git_command(root);
        command.arg("diff").arg("-M").arg(&range).arg("--").arg(path);
        // A rename is limited to *both* paths: git applies the path limit
        // before rename detection, so asking for the destination alone turns a
        // pure rename into the whole file arriving as additions.
        if let Some(original) = files
            .iter()
            .find(|file| file.path == path)
            .and_then(|file| file.original_path.as_deref())
        {
            command.arg(original);
        }
        let patch = command.output().await.context("running git diff")?;
        if !patch.status.success() {
            bail!(
                "git diff failed: {}",
                String::from_utf8_lossy(&patch.stderr).trim()
            );
        }
        cap_diff(String::from_utf8_lossy(&patch.stdout).into_owned())
    } else {
        (String::new(), false)
    };

    Ok(GitCompareOutcome {
        files,
        commits: log.commits,
        behind,
        diff,
        truncated,
        files_truncated,
        commits_truncated: log.truncated,
        problem: None,
    })
}

/// Commits the branch's upstream does not have. No upstream means a non-zero
/// exit, which is an empty set — a purely local branch marks no rows rather
/// than all of them.
async fn unpushed_commits(root: &str) -> HashSet<String> {
    let output = git_command(root)
        .arg("rev-list")
        .arg("@{upstream}..HEAD")
        .output()
        .await;
    match output {
        Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .map(str::to_string)
            .collect(),
        _ => HashSet::new(),
    }
}

/// Whether HEAD resolves to a commit at all.
async fn has_commits(root: &str) -> bool {
    git_command(root)
        .arg("rev-parse")
        .arg("--verify")
        .arg("--quiet")
        .arg("HEAD")
        .output()
        .await
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// Parse `git log -z` in [`COMMIT_FORMAT`]: records NUL-terminated,
/// fields US-separated. A record with the wrong field count is dropped rather
/// than guessed at.
fn parse_commits(bytes: &[u8], unpushed: &HashSet<String>) -> Vec<GitCommitEntry> {
    bytes
        .split(|&byte| byte == 0)
        .filter_map(|record| {
            let record = String::from_utf8_lossy(record);
            parse_commit_record(record.trim_start_matches('\n'), unpushed)
        })
        .collect()
}

fn parse_commit_record(record: &str, unpushed: &HashSet<String>) -> Option<GitCommitEntry> {
    let fields: Vec<&str> = record.split(FIELD).collect();
    if fields.len() != 8 || fields[0].is_empty() {
        return None;
    }
    Some(GitCommitEntry {
        sha: fields[0].to_string(),
        short_sha: fields[1].to_string(),
        subject: fields[2].to_string(),
        author: fields[3].to_string(),
        author_email: fields[4].to_string(),
        relative_date: fields[5].to_string(),
        timestamp: fields[6].parse().unwrap_or(0),
        tags: fields[7]
            .split(", ")
            .filter_map(|decoration| decoration.strip_prefix("tag: "))
            .map(str::to_string)
            .collect(),
        unpushed: unpushed.contains(fields[0]),
    })
}

/// Parse `git show <COMMIT_FORMAT> --raw --numstat -z`: the
/// commit record, then every `--raw` record, then every `--numstat` record.
/// The two sections are told apart by their first byte — `:` opens a raw
/// record — and merged by path, keeping git's own order.
fn parse_commit_detail(bytes: &[u8]) -> Result<(GitCommitEntry, Vec<GitCommitFile>, bool)> {
    let mut fields = bytes.split(|&byte| byte == 0).map(|field| {
        String::from_utf8_lossy(field)
            .trim_start_matches('\n')
            .to_string()
    });
    let header = fields.next().unwrap_or_default();
    let Some(entry) = parse_commit_record(&header, &HashSet::new()) else {
        bail!("git show did not describe a commit");
    };
    let (files, truncated) = parse_diff_files(&mut fields);
    Ok((entry, files, truncated))
}

/// Parse the `--raw --numstat -z` records of one diff — a commit's (after its
/// header) or a range's (which has none) — into file rows.
fn parse_diff_files(fields: &mut impl Iterator<Item = String>) -> (Vec<GitCommitFile>, bool) {
    let mut files: Vec<GitCommitFile> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut truncated = false;
    while let Some(field) = fields.next() {
        if field.is_empty() {
            continue;
        }
        if let Some(raw) = field.strip_prefix(':') {
            // :mode mode sha sha STATUS NUL path [NUL path] — a rename or a
            // copy names both paths, everything else one.
            let Some(code) = raw.split(' ').next_back().and_then(|token| {
                token
                    .as_bytes()
                    .first()
                    .copied()
                    .and_then(commit_status_code)
            }) else {
                continue;
            };
            let renamed = matches!(code, GitStatusCode::Renamed | GitStatusCode::Copied);
            let first = fields.next().unwrap_or_default();
            let (path, original) = if renamed {
                (fields.next().unwrap_or_default(), Some(first))
            } else {
                (first, None)
            };
            if path.is_empty() {
                continue;
            }
            if files.len() >= SHOW_FILE_CAP {
                truncated = true;
                continue;
            }
            index.insert(path.clone(), files.len());
            files.push(GitCommitFile {
                path,
                original_path: original,
                status: code,
                additions: 0,
                deletions: 0,
                binary: false,
            });
            continue;
        }
        // adds TAB dels TAB path, or adds TAB dels TAB NUL old NUL new for a
        // rename. `-` for either count means git called the file binary.
        let mut columns = field.splitn(3, '\t');
        let (Some(additions), Some(deletions), Some(rest)) =
            (columns.next(), columns.next(), columns.next())
        else {
            continue;
        };
        let path = if rest.is_empty() {
            let _original = fields.next();
            fields.next().unwrap_or_default()
        } else {
            rest.to_string()
        };
        let Some(position) = index.get(&path) else {
            continue;
        };
        let file = &mut files[*position];
        file.binary = additions == "-" || deletions == "-";
        file.additions = additions.parse().unwrap_or(0);
        file.deletions = deletions.parse().unwrap_or(0);
    }
    (files, truncated)
}

/// A commit's file carries one status letter, unlike a worktree file's two
/// axes. `T` (type change) is folded into the modified axis exactly as the
/// status kind folds it.
fn commit_status_code(byte: u8) -> Option<GitStatusCode> {
    match byte {
        b'M' => Some(GitStatusCode::Modified),
        b'T' => Some(GitStatusCode::TypeChanged),
        b'A' => Some(GitStatusCode::Added),
        b'D' => Some(GitStatusCode::Deleted),
        b'R' => Some(GitStatusCode::Renamed),
        b'C' => Some(GitStatusCode::Copied),
        _ => None,
    }
}

/// Parse `for-each-ref --format='%(HEAD) %(refname) %(symref)'`. `%(HEAD)` is
/// one character — `*` for the checkout's own branch, a space for every other
/// ref — and a refname can hold no whitespace, which is what makes a
/// space-separated format unambiguous here.
fn parse_refs(text: &str) -> GitBranchList {
    let mut list = GitBranchList::default();
    for line in text.lines() {
        let Some(rest) = line.get(1..) else {
            continue;
        };
        let checked_out = line.starts_with('*');
        let mut columns = rest.split_whitespace();
        let Some(refname) = columns.next() else {
            continue;
        };
        let symref = columns.next().unwrap_or("");
        if let Some(name) = refname.strip_prefix("refs/heads/") {
            if checked_out {
                list.current = Some(name.to_string());
            }
            if list.branches.len() < BRANCH_CAP {
                list.branches.push(GitBranchEntry {
                    name: name.to_string(),
                    remote: false,
                });
            } else {
                list.truncated = true;
            }
        } else if let Some(name) = refname.strip_prefix("refs/remotes/") {
            // `origin/HEAD` is a symbolic pointer at the remote's default
            // branch, not a branch of its own.
            if name.ends_with("/HEAD") {
                list.default_branch = symref
                    .strip_prefix("refs/remotes/")
                    .filter(|target| !target.is_empty())
                    .map(str::to_string);
                continue;
            }
            if list.branches.len() < BRANCH_CAP {
                list.branches.push(GitBranchEntry {
                    name: name.to_string(),
                    remote: true,
                });
            } else {
                list.truncated = true;
            }
        }
    }
    list
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    fn joined(records: &[&str]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for record in records {
            bytes.extend_from_slice(record.as_bytes());
            bytes.push(0);
        }
        bytes
    }

    fn ignored_flags(root: &Path, directory: &Path) -> HashMap<String, bool> {
        let root = root.to_string_lossy().into_owned();
        let path = directory.to_string_lossy().into_owned();
        let mut listings = crate::files::list(&root, &[path], None).unwrap();
        decorate_listings(&mut listings);
        listings[0].entries.iter().map(|entry| (entry.name.clone(), entry.ignored)).collect()
    }

    #[test]
    fn ignored_listings_distinguish_directories_negations_and_local_excludes() {
        let directory = scratch_repo("ignored-listings");
        write(&directory, "tracked.log", "tracked");
        commit(&directory, "tracked file");
        write(&directory, ".gitignore", "node_modules/\n*.log\n!keep.log\n\\!literal\n/anchored\n");
        std::fs::create_dir(directory.join("node_modules")).unwrap();
        std::fs::create_dir(directory.join("sub")).unwrap();
        write(&directory, "sub/anchored", "content");
        // A rule for directories does not cover a link, which is a file to git.
        std::os::unix::fs::symlink(directory.join("sub"), directory.join("node_modules-link")).unwrap();
        for name in ["new.swift", "debug.log", "keep.log", "!literal", "line\nbreak.log", "anchored"] {
            write(&directory, name, "content");
        }
        write(&directory, ".git/info/exclude", "local-only\n");
        write(&directory, "local-only", "excluded");
        let flags = ignored_flags(&directory, &directory);
        // `tracked.log` is in the index, and git would not call it ignored.
        // The rules alone cannot tell, so it is dimmed with the other logs.
        for name in ["node_modules", "debug.log", "!literal", "line\nbreak.log", "local-only", "anchored", "tracked.log"] {
            assert_eq!(flags[name], true, "{name}");
        }
        for name in ["new.swift", "keep.log", ".git", ".gitignore", "sub", "node_modules-link"] {
            assert_eq!(flags[name], false, "{name}");
        }
        assert!(!ignored_flags(&directory, &directory.join("sub"))["anchored"]);
        // The same listing must lose its decoration after the rule is removed.
        write(&directory, ".gitignore", "");
        assert!(!ignored_flags(&directory, &directory)["node_modules"]);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn a_deeper_gitignore_overrides_a_shallower_one_but_not_an_ignored_directory() {
        let directory = scratch_repo("ignored-depth");
        write(&directory, ".gitignore", "*.log\nbuild/\n");
        for folder in ["app", "app/inner", "build", "build/out"] {
            std::fs::create_dir(directory.join(folder)).unwrap();
        }
        write(&directory, "app/.gitignore", "!kept.log\n*.tmp\n");
        for name in ["app/kept.log", "app/other.log", "app/scratch.tmp", "app/inner/kept.log", "app/inner/deep.tmp"] {
            write(&directory, name, "");
        }
        // Git stops at an ignored directory, so a rule inside it re-includes nothing.
        write(&directory, "build/.gitignore", "!artifact.log\n");
        write(&directory, "build/artifact.log", "");
        write(&directory, "build/out/main.o", "");

        let app = ignored_flags(&directory, &directory.join("app"));
        assert_eq!((app["kept.log"], app["other.log"], app["scratch.tmp"]), (false, true, true));
        let inner = ignored_flags(&directory, &directory.join("app/inner"));
        assert_eq!((inner["kept.log"], inner["deep.tmp"]), (false, true));
        assert!(ignored_flags(&directory, &directory.join("build")).values().all(|ignored| *ignored));
        assert!(ignored_flags(&directory, &directory.join("build/out"))["main.o"]);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn a_linked_worktree_reads_the_excludes_and_case_setting_its_checkout_shares() {
        let directory = scratch_repo("ignored-worktree");
        write(&directory, "file", "content");
        commit(&directory, "first");
        write(&directory, ".git/info/exclude", "shared-exclude\n");
        run_git(&directory, &["config", "core.ignorecase", "true"]);
        let linked = directory.join("linked");
        run_git(&directory, &["worktree", "add", "-q", linked.to_str().unwrap()]);
        assert!(linked.join(".git").is_file());
        write(&linked, ".gitignore", "Build\n");
        for name in ["shared-exclude", "build", "other"] {
            write(&linked, name, "");
        }
        let flags = ignored_flags(&linked, &linked);
        assert_eq!((flags["shared-exclude"], flags["build"], flags["other"]), (true, true, false));

        run_git(&directory, &["config", "core.ignorecase", "false"]);
        assert!(!ignored_flags(&linked, &linked)["build"]);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rule_files_that_are_not_plain_text_files_cost_nothing_else() {
        let directory = scratch_repo("ignored-odd-files");
        std::fs::write(directory.join(".gitignore"), b"# legacy \xff comment\nbuild\n").unwrap();
        for folder in ["linked", "piped", "husk"] {
            std::fs::create_dir(directory.join(folder)).unwrap();
        }
        for name in ["build", "linked/out", "piped/out", "husk/out"] {
            write(&directory, name, "");
        }
        // A rule after a line that is not UTF-8 still applies.
        assert!(ignored_flags(&directory, &directory)["build"]);
        // A rule that is not UTF-8 itself is dropped, not bent onto another name.
        std::fs::write(directory.join(".gitignore"), b"foo\xff\n").unwrap();
        write(&directory, "foo\u{fffd}", "");
        assert!(!ignored_flags(&directory, &directory)["foo\u{fffd}"]);
        // Braces are the characters themselves, as in git, not a choice.
        write(&directory, ".gitignore", "{one,two}\n*.{js,css}\n[{]class\n");
        for name in ["one", "two", "{one,two}", "app.js", "app.{js,css}", "{class"] {
            write(&directory, name, "");
        }
        let flags = ignored_flags(&directory, &directory);
        for (name, ignored) in [("one", false), ("two", false), ("{one,two}", true), ("app.js", false), ("app.{js,css}", true), ("{class", true)] {
            assert_eq!(flags[name], ignored, "{name}");
        }
        // A rule file past the size limit is not read at all.
        let huge = std::fs::File::create(directory.join("husk/.gitignore")).unwrap();
        std::io::Write::write_all(&mut &huge, b"out\n").unwrap();
        huge.set_len(RULE_FILE_LIMIT + 1).unwrap();
        assert!(!ignored_flags(&directory, &directory.join("husk"))["out"]);
        std::fs::remove_file(directory.join("husk/.gitignore")).unwrap();
        // Git does not follow a `.gitignore` that is a link.
        write(&directory, "rules", "out\n");
        std::os::unix::fs::symlink(directory.join("rules"), directory.join("linked/.gitignore")).unwrap();
        assert!(!ignored_flags(&directory, &directory.join("linked"))["out"]);
        // A FIFO is never opened: reading one would wait for a writer forever.
        for fifo in ["piped/.gitignore", "husk/.git"] {
            let made = std::process::Command::new("mkfifo").arg(directory.join(fifo)).status().unwrap();
            assert!(made.success());
        }
        assert!(!ignored_flags(&directory, &directory.join("piped"))["out"]);
        assert!(!ignored_flags(&directory, &directory.join("husk"))["out"]);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn the_case_setting_is_read_the_way_git_writes_and_accepts_it() {
        for config in [
            "[core]\n\tignorecase = true\n",
            "[core] # note\n ignorecase = yes ; note\n",
            "[CORE]\nIgnoreCase=1\n",
            "[core]\nignorecase\n",
            "[core]\nignorecase = false\n[user]\nname = x\n[core]\nignorecase = on\n",
            "\u{feff}[core]\nignorecase = 2\n",
        ] {
            assert!(config_ignores_case(config), "{config:?}");
        }
        for config in [
            "",
            "[core]\nignorecase = false\n",
            "[core \"sub\"]\nignorecase = true\n",
            "[user]\nignorecase = true\n",
            "[core]\n# ignorecase = true\n",
            "[core]\nignorecase = true\nignorecase = false\n",
            "[core]\nignorecase = 0\n",
            "[core]\neditor = echo \\\n ignorecase\n",
        ] {
            assert!(!config_ignores_case(config), "{config:?}");
        }
    }

    #[test]
    fn a_git_directory_kept_elsewhere_is_found_by_its_exact_name() {
        let directory = scratch_repo("ignored-separate");
        let checkout = directory.join("checkout");
        // The name ends in a space, which a trim would cut off.
        let store = directory.join("store ");
        run_git(&directory, &["init", "-q", "--separate-git-dir", store.to_str().unwrap(), checkout.to_str().unwrap()]);
        write(&store, "info/exclude", "excluded\n");
        write(&checkout, "excluded", "");
        write(&checkout, "kept", "");
        let flags = ignored_flags(&checkout, &checkout);
        assert_eq!((flags["excluded"], flags["kept"]), (true, false));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn ignore_listings_resolve_nested_repositories_and_symlinked_roots_on_the_host() {
        let directory = scratch_repo("ignored-roots");
        write(&directory, ".gitignore", "*.log\n");
        let nested = directory.join("nested");
        std::fs::create_dir(&nested).unwrap();
        run_git(&nested, &["init", "-q"]);
        write(&nested, ".gitignore", "*.tmp\n");
        write(&nested, "keep.log", "");
        write(&nested, "ignored.tmp", "");
        let alias = directory.join("alias");
        std::os::unix::fs::symlink(&nested, &alias).unwrap();
        let root = directory.to_string_lossy().into_owned();
        let paths = [nested.to_string_lossy().into_owned(), alias.to_string_lossy().into_owned()];
        let mut listings = crate::files::list(&root, &paths, None).unwrap();
        decorate_listings(&mut listings);
        for listing in listings {
            assert!(listing.entries.iter().find(|entry| entry.name == "ignored.tmp").unwrap().ignored);
            assert!(!listing.entries.iter().find(|entry| entry.name == "keep.log").unwrap().ignored);
        }
        std::fs::remove_dir_all(directory.join(".git")).unwrap();
        let mut plain = crate::files::list(&root, &[root.clone()], None).unwrap();
        decorate_listings(&mut plain);
        assert!(plain[0].entries.iter().all(|entry| !entry.ignored));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn porcelain_v2_maps_to_the_two_axis_vocabulary() {
        let snapshot = parse_porcelain_v2(&joined(&[
            "# branch.oid 1234567890abcdef",
            "# branch.head main",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 aaaa bbbb staged.rs",
            "1 .M N... 100644 100644 100644 aaaa aaaa dirty.rs",
            "1 MM N... 100644 100644 100644 aaaa bbbb both.rs",
            "1 D. N... 100644 000000 000000 aaaa 0000 gone.rs",
            "2 R. N... 100644 100644 100644 aaaa aaaa R100 new-name.rs",
            "old-name.rs",
            "u UU N... 100644 100644 100644 100644 a b c conflicted.rs",
            "u AA N... 000000 100644 100644 000000 a b c both-added.rs",
            "? fresh.txt",
            "! target/debug",
        ]))
        .unwrap();

        assert_eq!(snapshot.branch.as_deref(), Some("main"));
        assert_eq!(snapshot.head.as_deref(), Some("1234567890abcdef"));
        assert_eq!(snapshot.ahead_behind, Some((2, 1)));
        let status = |path: &str| snapshot.statuses[path].status.unwrap();
        assert_eq!(
            status("staged.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Modified,
                worktree_status: GitStatusCode::Unmodified,
            }
        );
        assert_eq!(
            status("dirty.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Unmodified,
                worktree_status: GitStatusCode::Modified,
            }
        );
        assert_eq!(
            status("both.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Modified,
                worktree_status: GitStatusCode::Modified,
            }
        );
        assert_eq!(
            status("gone.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Deleted,
                worktree_status: GitStatusCode::Unmodified,
            }
        );
        assert_eq!(
            status("new-name.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Renamed,
                worktree_status: GitStatusCode::Unmodified,
            }
        );
        assert!(
            !snapshot.statuses.contains_key("old-name.rs"),
            "a rename's origin path is a field, not a record"
        );
        assert_eq!(
            snapshot.statuses["new-name.rs"].original_path.as_deref(),
            Some("old-name.rs"),
            "the origin is kept: it is what the row's `old → new` is made of"
        );
        assert_eq!(
            status("conflicted.rs"),
            GitFileStatus::Unmerged {
                first_head: GitUnmergedCode::Updated,
                second_head: GitUnmergedCode::Updated,
            }
        );
        assert_eq!(status("fresh.txt"), GitFileStatus::Untracked);
        assert_eq!(status("target/debug"), GitFileStatus::Ignored);
        assert_eq!(
            snapshot.conflicts(),
            vec!["both-added.rs", "conflicted.rs"],
            "the conflict set is first-class"
        );
    }

    #[test]
    fn branch_placeholders_stay_absent() {
        let snapshot = parse_porcelain_v2(&joined(&[
            "# branch.oid (initial)",
            "# branch.head (detached)",
        ]))
        .unwrap();
        assert_eq!(snapshot.branch, None);
        assert_eq!(snapshot.head, None);
        assert_eq!(snapshot.ahead_behind, None);
    }

    #[test]
    fn deltas_carry_only_what_moved_and_full_batches_carry_everything() {
        let before = parse_porcelain_v2(&joined(&[
            "# branch.head main",
            "1 .M N... 100644 100644 100644 a a keeps.rs",
            "1 .M N... 100644 100644 100644 a a reverts.rs",
            "? becomes-tracked.txt",
        ]))
        .unwrap();
        let after = parse_porcelain_v2(&joined(&[
            "# branch.head main",
            "1 .M N... 100644 100644 100644 a a keeps.rs",
            "1 A. N... 000000 100644 100644 0 b becomes-tracked.txt",
        ]))
        .unwrap();

        let delta = after.delta_from(&before).unwrap();
        assert_eq!(
            delta
                .updated_statuses
                .iter()
                .map(|entry| entry.path.as_str())
                .collect::<Vec<_>>(),
            vec!["becomes-tracked.txt"],
            "an unchanged status is not re-sent"
        );
        assert_eq!(delta.removed_paths, vec!["reverts.rs"]);
        assert_eq!(delta.branch.as_deref(), Some("main"));

        assert!(
            after.delta_from(&after).is_none(),
            "no movement, no batch"
        );

        let mut detached = after.clone();
        detached.branch = None;
        assert!(
            detached.delta_from(&after).is_some(),
            "branch metadata moving is a publishable change"
        );

        let full = after.full_batch();
        assert_eq!(full.updated_statuses.len(), after.statuses.len());
        assert!(full.removed_paths.is_empty());
    }

    #[test]
    fn status_events_serialize_the_adopted_vocabulary() {
        let event = GitBatch {
            updated_statuses: vec![
                GitStatusEntry {
                    path: "a.rs".to_string(),
                    status: GitFileStatus::Tracked {
                        index_status: GitStatusCode::Modified,
                        worktree_status: GitStatusCode::Unmodified,
                    },
                    original_path: None,
                    additions: 12,
                    deletions: 3,
                    binary: false,
                },
                GitStatusEntry {
                    path: "b.rs".to_string(),
                    status: GitFileStatus::Untracked,
                    original_path: None,
                    additions: 0,
                    deletions: 0,
                    binary: false,
                },
            ],
            removed_paths: vec![],
            branch: Some("main".to_string()),
            head: None,
            ahead_behind: Some((1, 0)),
            conflicts: vec![],
            total: None,
        }
        .into_event("git:/repo".to_string(), 7);
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["ev"], "git_changed");
        assert_eq!(json["seq"], 7);
        assert_eq!(
            json["updated_statuses"][0]["status"]["tracked"]["index_status"],
            "modified"
        );
        assert_eq!(json["updated_statuses"][1]["status"], "untracked");
        assert_eq!(json["ahead_behind"][0], 1);
        assert_eq!(json["updated_statuses"][0]["additions"], 12);
        assert_eq!(json["updated_statuses"][0]["deletions"], 3);
        assert!(
            json["updated_statuses"][1].get("additions").is_none(),
            "a zero count is left off the wire, not sent as 0"
        );
    }

    // The read tier is tested against a real repository built here, not
    // against captured fixtures: what it must stay compatible with is the git
    // on the box, and a fixture cannot notice that changing.

    fn run_git(dir: &Path, args: &[&str]) -> String {
        let output = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            // Hermetic: the developer's own global config must not decide
            // whether these commits can be made.
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("GIT_AUTHOR_DATE", "2026-08-18T10:00:00+00:00")
            .env("GIT_COMMITTER_DATE", "2026-08-18T10:00:00+00:00")
            .args(args)
            .output()
            .expect("git is on PATH");
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    fn scratch_repo(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "termiod-git-read-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        run_git(&dir, &["init", "-q", "-b", "main"]);
        run_git(&dir, &["config", "user.email", "test@termio.sh"]);
        run_git(&dir, &["config", "user.name", "termio test"]);
        run_git(&dir, &["config", "commit.gpgsign", "false"]);
        dir
    }

    fn write(dir: &Path, name: &str, body: &str) {
        std::fs::write(dir.join(name), body).unwrap();
    }

    fn commit(dir: &Path, message: &str) -> String {
        run_git(dir, &["add", "-A"]);
        run_git(dir, &["commit", "-q", "-m", message]);
        run_git(dir, &["rev-parse", "HEAD"])
    }

    /// The Changes row shows `+N −M` beside the path, so the status run has to
    /// carry those numbers — for a tracked edit, for a staged one, and for an
    /// untracked file, which has no diff to count and is measured by its lines.
    #[tokio::test]
    async fn status_carries_the_line_counts_the_row_shows() {
        let dir = scratch_repo("counts");
        write(&dir, "tracked.txt", "one\ntwo\nthree\n");
        commit(&dir, "first");
        write(&dir, "tracked.txt", "one\ntwo\nthree\nfour\n");
        write(&dir, "staged.txt", "a\nb\n");
        run_git(&dir, &["add", "staged.txt"]);
        write(&dir, "fresh.txt", "x\ny\nz\n");
        std::fs::write(dir.join("blob.bin"), [0u8, 1, 2, 3]).unwrap();

        let root = dir.to_string_lossy().into_owned();
        let snapshot = run_status(&root).await.unwrap();

        let tracked = &snapshot.statuses["tracked.txt"];
        assert_eq!((tracked.additions, tracked.deletions), (1, 0));
        assert!(!tracked.binary);

        let staged = &snapshot.statuses["staged.txt"];
        assert_eq!(
            (staged.additions, staged.deletions),
            (2, 0),
            "a staged file's numbers come from --cached"
        );

        let untracked = &snapshot.statuses["fresh.txt"];
        assert_eq!(
            (untracked.additions, untracked.deletions),
            (3, 0),
            "an untracked file is counted by its lines"
        );

        assert!(
            snapshot.statuses["blob.bin"].binary,
            "a NUL in the first chunk is binary, and +N would be a lie"
        );
    }

    /// A batch is one frame, and a frame past `MAX_FRAME_SIZE` kills the whole
    /// connection — the file tree and agent status ride the same channel. So a
    /// flooded checkout is cut here, and the cut is announced.
    #[test]
    fn an_oversized_status_list_is_cut_and_says_so() {
        let mut snapshot = GitSnapshot::default();
        snapshot.statuses.insert(
            "src/edited.rs".to_string(),
            FileState::new(GitFileStatus::Tracked {
                index_status: GitStatusCode::Unmodified,
                worktree_status: GitStatusCode::Modified,
            }),
        );
        snapshot.statuses.insert(
            "zzz/conflicted.rs".to_string(),
            FileState::new(GitFileStatus::Unmerged {
                first_head: GitUnmergedCode::Updated,
                second_head: GitUnmergedCode::Updated,
            }),
        );
        for index in 0..STATUS_CAP + 10 {
            snapshot.statuses.insert(
                format!("node_modules/pkg/{index}.js"),
                FileState::new(GitFileStatus::Untracked),
            );
        }
        cap_statuses(&mut snapshot);

        assert_eq!(
            snapshot.total,
            Some(STATUS_CAP as u64 + 12),
            "a cut list must name how many there really were"
        );
        assert_eq!(snapshot.statuses.len(), STATUS_CAP);
        assert!(
            snapshot.statuses.contains_key("src/edited.rs"),
            "the tracked edit is the row a person is reviewing; the flood is not"
        );
        assert!(
            snapshot.statuses.contains_key("zzz/conflicted.rs"),
            "a conflict must act on outlives everything, whatever it sorts as"
        );
        assert_eq!(snapshot.conflicts(), vec!["zzz/conflicted.rs".to_string()]);
    }

    /// The entry count is not the only way past a frame. Few enough rows to
    /// clear `STATUS_CAP` can still carry megabytes of path — and a rename
    /// spends its budget twice, for where the file came from as well as where
    /// it is.
    #[test]
    fn a_short_list_of_very_long_paths_is_cut_too() {
        let mut snapshot = GitSnapshot::default();
        let long = "d".repeat(3_000);
        for index in 0..600 {
            let mut state = FileState::new(GitFileStatus::Tracked {
                index_status: GitStatusCode::Renamed,
                worktree_status: GitStatusCode::Unmodified,
            });
            state.original_path = Some(format!("{long}/was-{index}.rs"));
            snapshot
                .statuses
                .insert(format!("{long}/now-{index}.rs"), state);
        }
        assert!(snapshot.statuses.len() < STATUS_CAP, "the entry cap is clear");
        cap_statuses(&mut snapshot);

        assert_eq!(
            snapshot.total,
            Some(600),
            "the byte budget has to bind on its own, and still name the total"
        );
        let spent: usize = snapshot
            .statuses
            .iter()
            .map(|(path, state)| {
                path.len() + state.original_path.as_ref().map_or(0, String::len)
            })
            .sum();
        assert!(spent <= STATUS_PATH_BYTES_CAP, "spent {spent}");
    }

    /// The cut has to be deterministic, or two runs over an unchanged flooded
    /// tree would keep different rows and publish a delta on every tick.
    #[test]
    fn the_cut_keeps_the_same_rows_across_runs() {
        let build = || {
            let mut snapshot = GitSnapshot::default();
            for index in 0..STATUS_CAP + 50 {
                snapshot.statuses.insert(
                    format!("build/{index}.o"),
                    FileState::new(GitFileStatus::Untracked),
                );
            }
            cap_statuses(&mut snapshot);
            snapshot
        };
        let first = build();
        let second = build();
        assert!(first.total.is_some());
        assert_eq!(first, second);
        assert_eq!(second.delta_from(&first), None, "an unchanged tree is quiet");
    }

    /// A list under the cap is untouched, and never claims to be partial.
    #[test]
    fn an_ordinary_status_list_is_not_cut() {
        let mut snapshot = GitSnapshot::default();
        for index in 0..10 {
            snapshot.statuses.insert(
                format!("src/{index}.rs"),
                FileState::new(GitFileStatus::Untracked),
            );
        }
        cap_statuses(&mut snapshot);
        assert_eq!(snapshot.total, None);
        assert_eq!(snapshot.statuses.len(), 10);
    }

    /// Every state a Changes row can be in has to produce a diff. `git diff --
    /// <path>` alone answers for one of them and returns empty for the rest,
    /// which shipped as a pane full of rows that all opened blank.
    #[tokio::test]
    async fn every_kind_of_working_tree_change_has_a_diff() {
        let dir = scratch_repo("diff");
        write(&dir, "tracked.txt", "one\ntwo\n");
        commit(&dir, "first");
        let root = dir.to_string_lossy().into_owned();

        write(&dir, "fresh.txt", "brand\nnew\n");
        let (untracked, _) = run_diff(&root, "fresh.txt", false, None).await.unwrap();
        assert!(
            untracked.contains("+brand"),
            "an untracked file reads as one big addition, not as nothing: {untracked:?}"
        );

        write(&dir, "tracked.txt", "one\ntwo\nthree\n");
        let (unstaged, _) = run_diff(&root, "tracked.txt", false, None).await.unwrap();
        assert!(unstaged.contains("+three"), "a worktree edit: {unstaged:?}");

        run_git(&dir, &["add", "tracked.txt"]);
        let (staged, _) = run_diff(&root, "tracked.txt", true, None).await.unwrap();
        assert!(
            staged.contains("+three"),
            "a change that is entirely in the index still has a diff: {staged:?}"
        );

        // The overlay folds unchanged runs into expandable bands, which needs the
        // whole file rather than git's three lines of context.
        let (wide, _) = run_diff(&root, "tracked.txt", true, Some(999_999))
            .await
            .unwrap();
        assert!(
            wide.contains(" one") && wide.contains(" two"),
            "a large -U carries the unchanged lines too: {wide:?}"
        );
    }

    #[tokio::test]
    async fn log_reads_a_real_repository_newest_first() {
        let dir = scratch_repo("log");
        write(&dir, "a.txt", "one\n");
        let first = commit(&dir, "first commit");
        run_git(&dir, &["tag", "v0.1.0"]);
        write(&dir, "a.txt", "one\ntwo\n");
        let second = commit(&dir, "second commit: subject with spaces");

        let root = dir.to_string_lossy().into_owned();
        let page = run_log(&root, 50, None).await.unwrap();
        assert_eq!(
            page.commits
                .iter()
                .map(|entry| entry.sha.as_str())
                .collect::<Vec<_>>(),
            vec![second.as_str(), first.as_str()],
            "newest first"
        );
        assert!(!page.truncated, "the walk reached the root commit");
        let newest = &page.commits[0];
        assert_eq!(newest.subject, "second commit: subject with spaces");
        assert_eq!(newest.author, "termio test");
        assert_eq!(newest.author_email, "test@termio.sh");
        assert_eq!(newest.short_sha, second[..newest.short_sha.len()]);
        assert!(newest.timestamp > 0, "an instant the client can format");
        assert!(!newest.relative_date.is_empty());
        assert!(newest.tags.is_empty(), "branch decorations are not tags");
        assert_eq!(
            page.commits[1].tags,
            vec!["v0.1.0"],
            "a tag pointing at the commit is kept"
        );

        let page = run_log(&root, 1, None).await.unwrap();
        assert_eq!(page.commits.len(), 1);
        assert!(page.truncated, "the walk stopped at the limit, and says so");

        let ranged = run_log(&root, 50, Some(&format!("{first}..HEAD")))
            .await
            .unwrap();
        assert_eq!(
            ranged
                .commits
                .iter()
                .map(|entry| entry.sha.as_str())
                .collect::<Vec<_>>(),
            vec![second.as_str()],
            "a range narrows the walk — what the Compare tab is composed from"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn log_marks_what_the_upstream_does_not_have() {
        let dir = scratch_repo("unpushed");
        write(&dir, "a.txt", "one\n");
        let first = commit(&dir, "pushed");
        write(&dir, "a.txt", "one\ntwo\n");
        let second = commit(&dir, "not pushed");
        // A remote-tracking ref and a branch upstream, with no network: the
        // upstream is one commit behind. `@{upstream}` resolves through the
        // remote's fetch refspec, so the remote needs one.
        run_git(&dir, &["update-ref", "refs/remotes/origin/main", &first]);
        run_git(&dir, &["config", "remote.origin.url", "/dev/null"]);
        run_git(
            &dir,
            &[
                "config",
                "remote.origin.fetch",
                "+refs/heads/*:refs/remotes/origin/*",
            ],
        );
        run_git(&dir, &["config", "branch.main.remote", "origin"]);
        run_git(&dir, &["config", "branch.main.merge", "refs/heads/main"]);

        let root = dir.to_string_lossy().into_owned();
        let page = run_log(&root, 50, None).await.unwrap();
        let marked: Vec<&str> = page
            .commits
            .iter()
            .filter(|entry| entry.unpushed)
            .map(|entry| entry.sha.as_str())
            .collect();
        assert_eq!(marked, vec![second.as_str()]);

        // Without an upstream the set is empty, not everything.
        run_git(&dir, &["config", "--unset", "branch.main.remote"]);
        run_git(&dir, &["config", "--unset", "branch.main.merge"]);
        let page = run_log(&root, 50, None).await.unwrap();
        assert!(page.commits.iter().all(|entry| !entry.unpushed));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn log_of_a_repository_with_no_commits_is_empty_not_an_error() {
        let dir = scratch_repo("unborn");
        let root = dir.to_string_lossy().into_owned();
        let page = run_log(&root, 50, None).await.unwrap();
        assert!(page.commits.is_empty());
        assert!(!page.truncated);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn show_reads_a_commit_its_files_and_its_diff() {
        let dir = scratch_repo("show");
        write(&dir, "a.txt", "one\n");
        commit(&dir, "first");
        write(&dir, "a.txt", "one\ntwo\n");
        write(&dir, "added.txt", "fresh\n");
        std::fs::write(dir.join("blob.bin"), [0u8, 1, 2, 0, 3]).unwrap();
        let sha = commit(&dir, "second");

        let root = dir.to_string_lossy().into_owned();
        let detail = run_show(&root, &sha, None).await.unwrap();
        assert_eq!(detail.commit.sha, sha);
        assert_eq!(detail.commit.subject, "second");
        assert!(!detail.truncated && !detail.files_truncated);

        let file = |path: &str| {
            detail
                .files
                .iter()
                .find(|file| file.path == path)
                .unwrap_or_else(|| panic!("{path} missing from the commit"))
        };
        assert_eq!(file("a.txt").status, GitStatusCode::Modified);
        assert_eq!(file("a.txt").additions, 1);
        assert_eq!(file("a.txt").deletions, 0);
        assert_eq!(file("added.txt").status, GitStatusCode::Added);
        assert!(file("blob.bin").binary, "counting binary lines would lie");
        assert_eq!(file("blob.bin").additions, 0);
        assert!(detail.diff.contains("+two"));
        assert!(detail.diff.contains("added.txt"));

        let narrowed = run_show(&root, &sha, Some("a.txt")).await.unwrap();
        assert!(narrowed.diff.contains("+two"));
        assert!(
            !narrowed.diff.contains("added.txt"),
            "a path narrows the diff but not the file list"
        );
        assert_eq!(narrowed.files.len(), detail.files.len());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn show_keeps_a_rename_a_rename() {
        let dir = scratch_repo("rename");
        write(&dir, "before.txt", "one\ntwo\nthree\nfour\n");
        commit(&dir, "first");
        run_git(&dir, &["mv", "before.txt", "after.txt"]);
        let sha = commit(&dir, "rename it");

        let root = dir.to_string_lossy().into_owned();
        let detail = run_show(&root, &sha, None).await.unwrap();
        assert_eq!(detail.files.len(), 1);
        assert_eq!(detail.files[0].path, "after.txt");
        assert_eq!(detail.files[0].status, GitStatusCode::Renamed);
        assert_eq!(
            detail.files[0].original_path.as_deref(),
            Some("before.txt")
        );
        assert_eq!(detail.files[0].additions, 0);

        // Asking for the destination alone would make git limit the path
        // before rename detection and re-emit the whole file as additions.
        let narrowed = run_show(&root, &sha, Some("after.txt")).await.unwrap();
        assert!(
            narrowed.diff.contains("rename from before.txt"),
            "the per-file diff of a rename is still a rename: {}",
            narrowed.diff
        );
        assert!(!narrowed.diff.contains("+one"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn branches_report_locals_remotes_the_checkout_and_the_default() {
        let dir = scratch_repo("branches");
        write(&dir, "a.txt", "one\n");
        let first = commit(&dir, "first");
        run_git(&dir, &["branch", "feat/side"]);
        run_git(&dir, &["update-ref", "refs/remotes/origin/main", &first]);
        run_git(
            &dir,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
            ],
        );

        let root = dir.to_string_lossy().into_owned();
        let list = run_branches(&root).await.unwrap();
        assert_eq!(list.current.as_deref(), Some("main"));
        assert_eq!(list.default_branch.as_deref(), Some("origin/main"));
        assert!(!list.truncated);
        let locals: Vec<&str> = list
            .branches
            .iter()
            .filter(|branch| !branch.remote)
            .map(|branch| branch.name.as_str())
            .collect();
        let remotes: Vec<&str> = list
            .branches
            .iter()
            .filter(|branch| branch.remote)
            .map(|branch| branch.name.as_str())
            .collect();
        assert_eq!(locals, vec!["feat/side", "main"]);
        assert_eq!(
            remotes,
            vec!["origin/main"],
            "origin/HEAD is a pointer at the default, not a branch"
        );

        run_git(&dir, &["checkout", "-q", "--detach", &first]);
        let detached = run_branches(&root).await.unwrap();
        assert_eq!(
            detached.current, None,
            "a detached HEAD is on no branch, and says so rather than guessing"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn compare_measures_a_branch_against_its_base() {
        let dir = scratch_repo("compare");
        write(&dir, "a.txt", "one\n");
        commit(&dir, "first commit");
        run_git(&dir, &["checkout", "-q", "-b", "feat"]);
        write(&dir, "b.txt", "branch work\n");
        commit(&dir, "branch commit");
        // The base moves on after the branch forked: three-dot must not show
        // main's change inverted, and `behind` must count it.
        run_git(&dir, &["checkout", "-q", "main"]);
        write(&dir, "a.txt", "one\ntwo\n");
        commit(&dir, "trunk moved on");
        run_git(&dir, &["checkout", "-q", "feat"]);

        let root = dir.to_string_lossy().into_owned();
        let outcome = run_compare(&root, "main", None).await.unwrap();
        assert_eq!(outcome.problem, None);
        assert_eq!(
            outcome
                .files
                .iter()
                .map(|file| file.path.as_str())
                .collect::<Vec<_>>(),
            vec!["b.txt"],
            "three dots: only the branch's own change, never the base's"
        );
        assert_eq!(outcome.behind, 1, "the base's new commit dates the compare");
        assert_eq!(
            outcome
                .commits
                .iter()
                .map(|entry| entry.subject.as_str())
                .collect::<Vec<_>>(),
            vec!["branch commit"],
            "the commits ride the same reply, walked from the same pinned head"
        );
        assert!(!outcome.commits_truncated);
        assert!(outcome.diff.is_empty(), "no path asked, no diff sent");

        let narrowed = run_compare(&root, "main", Some("b.txt")).await.unwrap();
        assert!(
            narrowed.diff.contains("branch work"),
            "a path narrows to that file's ranged diff"
        );
        assert!(!narrowed.truncated);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn compare_states_its_problems_rather_than_answering_empty() {
        let dir = scratch_repo("compare-problems");
        write(&dir, "a.txt", "one\n");
        commit(&dir, "first commit");

        let root = dir.to_string_lossy().into_owned();
        let gone = run_compare(&root, "deleted-branch", None).await.unwrap();
        assert_eq!(
            gone.problem,
            Some(crate::protocol::GitCompareProblem::MissingBase)
        );
        assert!(gone.files.is_empty());

        // An orphan branch shares no history with main: there is no merge base
        // to diff from, and an empty file list would read as "changes nothing".
        run_git(&dir, &["checkout", "-q", "--orphan", "rootless"]);
        write(&dir, "c.txt", "unrelated\n");
        commit(&dir, "unrelated root");
        let unrelated = run_compare(&root, "main", None).await.unwrap();
        assert_eq!(
            unrelated.problem,
            Some(crate::protocol::GitCompareProblem::NoCommonHistory)
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_revision_that_would_read_as_an_option_is_refused() {
        let dir = scratch_repo("revision");
        write(&dir, "a.txt", "one\n");
        commit(&dir, "first");
        write(&dir, "a.txt", "one\ntwo\n");
        commit(&dir, "second");
        let root = dir.to_string_lossy().into_owned();

        assert!(run_log(&root, 10, Some("--output=/tmp/pwned")).await.is_err());
        assert!(run_show(&root, "-x", None).await.is_err());
        assert!(
            run_log(&root, 10, Some("HEAD~1..HEAD")).await.is_ok(),
            "an ordinary range still runs"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn commit_records_drop_branch_decorations_and_survive_a_missing_field() {
        let unpushed: HashSet<String> = ["aaaa".to_string()].into_iter().collect();
        let record = |fields: &[&str]| fields.join("\u{1f}");
        let bytes = [
            record(&[
                "aaaa", "aaa", "subject", "Ada", "ada@example.com", "2 hours ago", "1787165226",
                "HEAD -> main, tag: v1.2.3, origin/main, tag: latest",
            ]),
            record(&["bbbb", "bbb", "too", "few", "fields"]),
            record(&[
                "cccc", "ccc", "plain", "Ada", "ada@example.com", "3 days ago", "1787165000", "",
            ]),
        ]
        .join("\0");

        let commits = parse_commits(bytes.as_bytes(), &unpushed);
        assert_eq!(commits.len(), 2, "a malformed record is dropped, not guessed");
        assert_eq!(commits[0].tags, vec!["v1.2.3", "latest"]);
        assert_eq!(commits[0].timestamp, 1787165226);
        assert!(commits[0].unpushed);
        assert!(commits[1].tags.is_empty());
        assert!(!commits[1].unpushed);
    }

    #[test]
    fn a_commit_over_the_file_cap_is_cut_and_flagged() {
        let mut records = vec![format!(
            "{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
            "aaaa", "aaa", "wide", "Ada", "ada@example.com", "now", "1", ""
        )];
        for index in 0..(SHOW_FILE_CAP + 5) {
            records.push(":100644 100644 aaa bbb M".to_string());
            records.push(format!("file{index}.rs"));
        }
        let (_, files, truncated) = parse_commit_detail(records.join("\0").as_bytes()).unwrap();
        assert_eq!(files.len(), SHOW_FILE_CAP);
        assert!(truncated, "the list is cut at the cap and says so");
    }

    #[test]
    fn refs_over_the_cap_are_cut_and_flagged() {
        let mut lines = String::new();
        for index in 0..(BRANCH_CAP + 3) {
            lines.push_str(&format!("  refs/heads/branch-{index} \n"));
        }
        let list = parse_refs(&lines);
        assert_eq!(list.branches.len(), BRANCH_CAP);
        assert!(list.truncated);
        assert_eq!(list.current, None);
    }

    /// `read_head` must agree with git about every HEAD shape a checkout can
    /// be in — on a branch, detached, and inside a linked worktree, whose
    /// `.git` is a pointer file rather than a directory — without ever
    /// spawning git to find out.
    #[test]
    fn read_head_names_the_branch_the_detachment_and_the_linked_worktree() {
        let dir = scratch_repo("read-head");
        let root = dir.to_string_lossy().into_owned();
        write(&dir, "a.txt", "one\n");
        let first = commit(&dir, "first");

        assert_eq!(
            read_head(&root),
            HeadSnapshot {
                branch: Some("main".to_string()),
                head: None
            }
        );

        run_git(&dir, &["checkout", "-q", "-b", "feat/branch-chip"]);
        assert_eq!(
            read_head(&root).branch.as_deref(),
            Some("feat/branch-chip")
        );

        run_git(&dir, &["checkout", "-q", "--detach", &first]);
        let detached = read_head(&root);
        assert_eq!(detached.branch, None);
        assert_eq!(detached.head.as_deref(), Some(&first[..7]));

        let linked = dir.with_file_name(format!(
            "termiod-git-read-head-linked-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&linked);
        run_git(
            &dir,
            &["worktree", "add", "-q", "-b", "linked", linked.to_str().unwrap(), "main"],
        );
        assert_eq!(
            read_head(&linked.to_string_lossy()).branch.as_deref(),
            Some("linked"),
            "a linked worktree's HEAD is resolved through its gitdir pointer"
        );

        let _ = std::fs::remove_dir_all(&linked);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A directory git knows nothing about answers the empty snapshot — the
    /// client hides the label — never an error.
    #[test]
    fn read_head_outside_a_repository_is_empty_not_an_error() {
        let dir = std::env::temp_dir().join(format!(
            "termiod-git-read-head-bare-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(read_head(&dir.to_string_lossy()), HeadSnapshot::default());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The wire shape the Mac decodes: `ev` names the kind, absent halves stay
    /// off the wire entirely.
    #[test]
    fn head_snapshot_serializes_to_the_documented_event() {
        let event = HeadSnapshot {
            branch: Some("main".to_string()),
            head: None,
        }
        .into_event("head:/repo".to_string(), 3);
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["ev"], "head_changed");
        assert_eq!(json["resource"], "head:/repo");
        assert_eq!(json["seq"], 3);
        assert_eq!(json["branch"], "main");
        assert!(json.get("head").is_none(), "a detached hash absent stays off the wire");

        let detached = HeadSnapshot {
            branch: None,
            head: Some("abc1234".to_string()),
        }
        .into_event("head:/repo".to_string(), 4);
        let json = serde_json::to_value(&detached).unwrap();
        assert!(json.get("branch").is_none());
        assert_eq!(json["head"], "abc1234");
    }
}
