//! Tombstones: what a session was when it died, and why.
//!
//! Making the daemon the only PTY owner makes it a single point of failure. An
//! in-process PTY at least died *with* the app — a shared fate the user could
//! interpret. A daemon that dies takes every session with it and, without this,
//! leaves the UI showing an empty list, which reads as "nothing was running"
//! rather than "everything was lost".
//!
//! Sessions cannot be resurrected; the PTYs are gone. They must not vanish
//! silently either. So two records are kept beside the socket:
//!
//! - a **roster** of the sessions currently alive, rewritten as they come and
//!   go. It exists solely so the *next* daemon can see what the last one was
//!   holding when it stopped.
//! - a **graveyard** of tombstones, capped and newest-first.
//!
//! A session that ends normally is buried by the daemon that owned it. A
//! session still on the roster when a daemon starts was never buried by anyone,
//! which is only possible if the previous daemon died under it — so it is
//! adopted as `daemon_lost`. That inference is the whole mechanism: no
//! heartbeat, no supervision, just a record nobody got the chance to clear.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::protocol::SessionInfo;

/// How many tombstones are kept. Enough to explain a bad afternoon, bounded so
/// the file cannot grow without limit on a long-lived box.
const MAX_GRAVES: usize = 100;

/// Why a session ended. A string on the wire rather than a closed enum, so a
/// later daemon can add a reason without an older client failing to decode it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndReason {
    /// The process exited on its own — the ordinary end of a shell or agent.
    Exited,
    /// A client asked for it (`kill`). The user meant this.
    Killed,
    /// The daemon went away while the session was running. Nobody chose this,
    /// and it is the reason tombstones exist at all.
    DaemonLost,
}

impl EndReason {
    pub fn as_str(self) -> &'static str {
        match self {
            EndReason::Exited => "exited",
            EndReason::Killed => "killed",
            EndReason::DaemonLost => "daemon_lost",
        }
    }
}

/// A dead session, in the terms a UI needs to say what happened: which session,
/// what it was running, when it started and stopped, and why it stopped.
///
/// Deliberately carries no rendered text — the host describes state and never
/// decides presentation. A tombstone says `daemon_lost` and lets the client
/// choose the words.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Tombstone {
    pub id: String,
    pub name: String,
    pub cwd: String,
    pub command: String,
    /// `exited` · `killed` · `daemon_lost`.
    pub reason: String,
    /// The process's exit code. `None` for `daemon_lost` — the daemon that
    /// would have reaped the child died first, so no honest answer exists.
    #[serde(default)]
    pub exit_status: Option<i32>,
    pub created_unix: u64,
    pub ended_unix: u64,
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    /// The workstream status the session last reported (`working`, `needs_you`,
    /// …). A session that died while `needs_you` is a different story from one
    /// that died `idle`, and that difference is exactly what the user lost.
    #[serde(default)]
    pub status: String,
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Tombstone {
    fn from_info(info: &SessionInfo, reason: EndReason, exit_status: Option<i32>) -> Tombstone {
        Tombstone {
            id: info.id.clone(),
            name: info.name.clone(),
            cwd: info.cwd.clone(),
            command: info.command.clone(),
            reason: reason.as_str().to_string(),
            exit_status,
            created_unix: info.created_unix,
            ended_unix: now_unix(),
            agent_id: info.agent_id.clone(),
            title: info.title.clone(),
            status: info.status.clone(),
        }
    }
}

/// The live roster entry. A trimmed `SessionInfo`: everything a tombstone needs
/// and nothing that changes per frame, because this file is rewritten whenever
/// a session is created or removed.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct RosterEntry {
    id: String,
    name: String,
    cwd: String,
    command: String,
    created_unix: u64,
    #[serde(default)]
    agent_id: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    status: String,
}

impl RosterEntry {
    fn from_info(info: &SessionInfo) -> RosterEntry {
        RosterEntry {
            id: info.id.clone(),
            name: info.name.clone(),
            cwd: info.cwd.clone(),
            command: info.command.clone(),
            created_unix: info.created_unix,
            agent_id: info.agent_id.clone(),
            title: info.title.clone(),
            status: info.status.clone(),
        }
    }

    fn into_tombstone(self) -> Tombstone {
        Tombstone {
            id: self.id,
            name: self.name,
            cwd: self.cwd,
            command: self.command,
            reason: EndReason::DaemonLost.as_str().to_string(),
            exit_status: None,
            created_unix: self.created_unix,
            ended_unix: now_unix(),
            agent_id: self.agent_id,
            title: self.title,
            status: self.status,
        }
    }
}

struct State {
    graves: Vec<Tombstone>,
    roster: HashMap<String, RosterEntry>,
}

/// The on-disk record of what died. One per daemon, living beside the socket so
/// it shares the socket's lifetime and permissions.
pub struct Graveyard {
    graves_path: PathBuf,
    roster_path: PathBuf,
    state: Mutex<State>,
}

impl Graveyard {
    /// Loads the previous daemon's records and adopts anything it left running.
    ///
    /// A roster entry that survived into a new daemon's startup is a session
    /// nobody buried — the previous daemon died holding it. Adopting those as
    /// `daemon_lost` here is what turns a crash from a silently empty list into
    /// an explanation.
    pub fn open(dir: &Path) -> Result<Graveyard> {
        let graveyard = Graveyard {
            graves_path: dir.join("tombstones.json"),
            roster_path: dir.join("roster.json"),
            state: Mutex::new(State {
                graves: Vec::new(),
                roster: HashMap::new(),
            }),
        };

        let mut graves: Vec<Tombstone> = read_json(&graveyard.graves_path).unwrap_or_default();
        let orphans: Vec<RosterEntry> = read_json(&graveyard.roster_path).unwrap_or_default();
        // Newest first, so the cap drops the oldest history rather than the
        // sessions that just died.
        for orphan in orphans.into_iter().rev() {
            graves.insert(0, orphan.into_tombstone());
        }
        graves.truncate(MAX_GRAVES);

        {
            let mut state = graveyard.state.lock().unwrap();
            state.graves = graves;
        }
        // The roster starts empty for this daemon: whatever the last one held is
        // now buried, and leaving the file behind would bury it twice on the
        // next start.
        graveyard.persist_roster()?;
        graveyard.persist_graves()?;
        Ok(graveyard)
    }

    /// Records a session as alive. Best-effort: failing to write the roster must
    /// never stop a session from starting — the cost of the failure is a worse
    /// explanation later, not a broken terminal now.
    pub fn note_live(&self, info: &SessionInfo) {
        {
            let mut state = self.state.lock().unwrap();
            state
                .roster
                .insert(info.id.clone(), RosterEntry::from_info(info));
        }
        if let Err(error) = self.persist_roster() {
            eprintln!("termiod: could not record live session: {error:#}");
        }
    }

    /// Buries a session that ended while this daemon was watching, and clears it
    /// from the roster so the next daemon does not mistake it for a crash.
    pub fn bury(&self, info: &SessionInfo, reason: EndReason, exit_status: Option<i32>) {
        {
            let mut state = self.state.lock().unwrap();
            state.roster.remove(&info.id);
            state.graves.insert(0, Tombstone::from_info(info, reason, exit_status));
            state.graves.truncate(MAX_GRAVES);
        }
        if let Err(error) = self.persist_roster().and_then(|_| self.persist_graves()) {
            eprintln!("termiod: could not record session end: {error:#}");
        }
    }

    /// Every tombstone, newest first.
    pub fn all(&self) -> Vec<Tombstone> {
        self.state.lock().unwrap().graves.clone()
    }

    fn persist_graves(&self) -> Result<()> {
        let graves = self.state.lock().unwrap().graves.clone();
        write_json(&self.graves_path, &graves)
    }

    fn persist_roster(&self) -> Result<()> {
        let mut roster: Vec<RosterEntry> = self
            .state
            .lock()
            .unwrap()
            .roster
            .values()
            .cloned()
            .collect();
        roster.sort_by_key(|entry| entry.created_unix);
        write_json(&self.roster_path, &roster)
    }
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Option<T> {
    let text = std::fs::read_to_string(path).ok()?;
    // A corrupt record is dropped rather than fatal: a daemon that will not
    // start because it cannot parse its own history is a worse outcome than a
    // lost explanation.
    serde_json::from_str(&text).ok()
}

/// Written atomically via a temp file and rename, so a daemon killed mid-write
/// leaves the previous record intact rather than a truncated one — a file that
/// only matters when something died badly must survive dying badly.
fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let text = serde_json::to_vec_pretty(value)?;
    let temporary = path.with_extension("tmp");
    std::fs::write(&temporary, &text)
        .with_context(|| format!("writing {}", temporary.display()))?;
    std::fs::rename(&temporary, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{EndReason, Graveyard, MAX_GRAVES};
    use crate::protocol::SessionInfo;

    fn info(id: &str) -> SessionInfo {
        SessionInfo {
            id: id.to_string(),
            name: format!("name-{id}"),
            cwd: "/work".to_string(),
            command: "zsh".to_string(),
            pid: 42,
            rows: 24,
            cols: 80,
            clients: 0,
            created_unix: 1000,
            alive: true,
            status: "working".to_string(),
            agent_id: Some("claude".to_string()),
            title: Some("fixing the parser".to_string()),
            attached_clients: 0,
            writer_client_id: None,
        }
    }

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("termiod-graves-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The ordinary end: the daemon that owned the session records why it went.
    #[test]
    fn a_session_that_exits_is_buried_with_its_status() {
        let dir = temp_dir("exit");
        let graveyard = Graveyard::open(&dir).unwrap();
        graveyard.note_live(&info("a"));
        graveyard.bury(&info("a"), EndReason::Exited, Some(0));

        let graves = graveyard.all();
        assert_eq!(graves.len(), 1);
        assert_eq!(graves[0].reason, "exited");
        assert_eq!(graves[0].exit_status, Some(0));
        assert_eq!(graves[0].status, "working");
        assert_eq!(graves[0].title.as_deref(), Some("fixing the parser"));
    }

    /// The case the whole file exists for: a session still on the roster when a
    /// new daemon starts was never buried, so the last daemon died under it.
    #[test]
    fn a_session_the_daemon_died_under_is_adopted_as_lost() {
        let dir = temp_dir("crash");
        let first = Graveyard::open(&dir).unwrap();
        first.note_live(&info("a"));
        drop(first); // no bury — the daemon vanished

        let second = Graveyard::open(&dir).unwrap();
        let graves = second.all();
        assert_eq!(graves.len(), 1);
        assert_eq!(graves[0].id, "a");
        assert_eq!(graves[0].reason, "daemon_lost");
        assert_eq!(
            graves[0].exit_status, None,
            "nobody reaped the child, so there is no honest exit code"
        );
    }

    /// A session buried properly is not also mourned as a crash on the next
    /// start — the roster entry must be cleared by the burial.
    #[test]
    fn a_buried_session_is_not_mourned_twice() {
        let dir = temp_dir("once");
        let first = Graveyard::open(&dir).unwrap();
        first.note_live(&info("a"));
        first.bury(&info("a"), EndReason::Killed, Some(137));
        drop(first);

        let graves = Graveyard::open(&dir).unwrap().all();
        assert_eq!(graves.len(), 1);
        assert_eq!(graves[0].reason, "killed");
    }

    /// Restarting repeatedly must not keep re-burying the same dead session.
    #[test]
    fn adoption_is_not_repeated_on_every_restart() {
        let dir = temp_dir("idempotent");
        let first = Graveyard::open(&dir).unwrap();
        first.note_live(&info("a"));
        drop(first);

        assert_eq!(Graveyard::open(&dir).unwrap().all().len(), 1);
        assert_eq!(Graveyard::open(&dir).unwrap().all().len(), 1);
    }

    /// History is bounded, and the cap drops the oldest — a box that has been up
    /// for a year must still be able to explain this morning.
    #[test]
    fn history_is_capped_and_drops_the_oldest() {
        let dir = temp_dir("cap");
        let graveyard = Graveyard::open(&dir).unwrap();
        for index in 0..MAX_GRAVES + 10 {
            graveyard.bury(&info(&format!("s{index}")), EndReason::Exited, Some(0));
        }

        let graves = graveyard.all();
        assert_eq!(graves.len(), MAX_GRAVES);
        assert_eq!(graves[0].id, format!("s{}", MAX_GRAVES + 9), "newest first");
    }

    /// Tombstones outlive the daemon that wrote them, or a crash would erase its
    /// own explanation on the next start.
    #[test]
    fn graves_survive_a_restart() {
        let dir = temp_dir("persist");
        let first = Graveyard::open(&dir).unwrap();
        first.bury(&info("a"), EndReason::Exited, Some(3));
        drop(first);

        let graves = Graveyard::open(&dir).unwrap().all();
        assert_eq!(graves.len(), 1);
        assert_eq!(graves[0].exit_status, Some(3));
    }

    /// A corrupt record must not stop the daemon from starting. Losing an
    /// explanation is recoverable; refusing to boot is not.
    #[test]
    fn a_corrupt_record_does_not_block_startup() {
        let dir = temp_dir("corrupt");
        std::fs::write(dir.join("tombstones.json"), b"{not json").unwrap();
        std::fs::write(dir.join("roster.json"), b"[[[").unwrap();

        assert_eq!(Graveyard::open(&dir).unwrap().all().len(), 0);
    }
}
