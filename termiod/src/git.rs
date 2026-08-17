//! The `git:` resource kind (§C.13): status as a subscription, read-only.
//!
//! The second consumer of §C.10's one mechanism — id, cursor, ring, gap,
//! linger — nothing new to learn. The host runs a debounced
//! `git status --porcelain=v2` when the workspace watcher reports change and
//! publishes the *delta* against the previous run. Read-only by design: no
//! stage/commit/push verbs, the user commits in the terminal, which is the
//! same app. The whole kind is one event shape plus one verb (`git.diff`).

use crate::protocol::{
    Event, GitFileStatus, GitStatusCode, GitStatusEntry, GitUnmergedCode,
};
use anyhow::{bail, Context, Result};
use std::collections::HashMap;

/// A `git.diff` reply is cut here — the same preview budget as `fs.read`.
pub const DIFF_CAP: usize = 1024 * 1024;

/// Everything one status run said. The live copy backs the synthetic
/// full-state batch a gap subscriber receives — only the host can "rescan"
/// git status, so on gap it does the scan for the client.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct GitSnapshot {
    pub statuses: HashMap<String, GitFileStatus>,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub ahead_behind: Option<(u32, u32)>,
}

impl GitSnapshot {
    pub fn conflicts(&self) -> Vec<String> {
        let mut paths: Vec<String> = self
            .statuses
            .iter()
            .filter(|(_, status)| matches!(status, GitFileStatus::Unmerged { .. }))
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
            .map(|(path, status)| GitStatusEntry {
                path: path.clone(),
                status: *status,
            })
            .collect();
        updated.sort_by(|a, b| a.path.cmp(&b.path));
        GitBatch {
            updated_statuses: updated,
            removed_paths: Vec::new(),
            branch: self.branch.clone(),
            head: self.head.clone(),
            ahead_behind: self.ahead_behind,
            conflicts: self.conflicts(),
        }
    }

    /// The delta that turns `previous` into `self`, or `None` when nothing a
    /// client can see moved.
    pub fn delta_from(&self, previous: &GitSnapshot) -> Option<GitBatch> {
        let mut updated: Vec<GitStatusEntry> = self
            .statuses
            .iter()
            .filter(|(path, status)| previous.statuses.get(*path) != Some(status))
            .map(|(path, status)| GitStatusEntry {
                path: path.clone(),
                status: *status,
            })
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
            || self.ahead_behind != previous.ahead_behind;
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
        }
    }
}

/// Run `git status --porcelain=v2 -z` for the repo at `root`.
/// `--no-optional-locks` matters: a plain `git status` refreshes the index
/// file, which the workspace watcher reports as `git_meta`, which would
/// trigger this again — a feedback loop by construction.
pub async fn run_status(root: &str) -> Result<GitSnapshot> {
    let output = tokio::process::Command::new("git")
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(root)
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
    parse_porcelain_v2(&output.stdout)
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
                    snapshot.statuses.insert(path.to_string(), status);
                }
            }
            "2" => {
                // 2 XY sub mH mI mW hH hI Xscore <path> NUL <origPath>
                let mut columns = rest.splitn(9, ' ');
                let xy = columns.next().unwrap_or_default();
                let path = columns.nth(7).unwrap_or_default();
                // Consume the origPath field so it is not read as a record.
                let _orig = fields.next();
                if let (Some(status), false) = (tracked_status(xy), path.is_empty()) {
                    snapshot.statuses.insert(path.to_string(), status);
                }
            }
            "u" => {
                // u XY sub m1 m2 m3 mW h1 h2 h3 <path>
                let mut columns = rest.splitn(10, ' ');
                let xy = columns.next().unwrap_or_default();
                let path = columns.nth(8).unwrap_or_default();
                if let (Some(status), false) = (unmerged_status(xy), path.is_empty()) {
                    snapshot.statuses.insert(path.to_string(), status);
                }
            }
            "?" => {
                snapshot
                    .statuses
                    .insert(rest.to_string(), GitFileStatus::Untracked);
            }
            "!" => {
                snapshot
                    .statuses
                    .insert(rest.to_string(), GitFileStatus::Ignored);
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
pub async fn run_diff(root: &str, path: &str, staged: bool) -> Result<(String, bool)> {
    let mut command = tokio::process::Command::new("git");
    command
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(root)
        .arg("diff");
    if staged {
        command.arg("--cached");
    }
    command.arg("--").arg(path);
    let output = command.output().await.context("running git diff")?;
    if !output.status.success() {
        bail!(
            "git diff failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let mut diff = String::from_utf8_lossy(&output.stdout).into_owned();
    let truncated = diff.len() > DIFF_CAP;
    if truncated {
        let mut cut = DIFF_CAP;
        while !diff.is_char_boundary(cut) {
            cut -= 1;
        }
        diff.truncate(cut);
    }
    Ok((diff, truncated))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn joined(records: &[&str]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for record in records {
            bytes.extend_from_slice(record.as_bytes());
            bytes.push(0);
        }
        bytes
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
        let status = |path: &str| snapshot.statuses[path];
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
                },
                GitStatusEntry {
                    path: "b.rs".to_string(),
                    status: GitFileStatus::Untracked,
                },
            ],
            removed_paths: vec![],
            branch: Some("main".to_string()),
            head: None,
            ahead_behind: Some((1, 0)),
            conflicts: vec![],
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
    }
}
