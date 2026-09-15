//! Tombstones: what a session was when it died, and why.
//!
//! Making the daemon the only PTY owner makes it a single point of failure. An
//! in-process PTY at least died *with* the app — a shared fate the user could
//! interpret. A daemon that dies takes every session with it and, without this,
//! leaves the UI showing an empty list, which reads as "nothing was running"
//! rather than "everything was lost".
//!
//! Sessions cannot be resurrected; the PTYs are gone. They must not vanish
//! silently either. So two records are kept in the daemon's durable state
//! dir — not beside the socket, whose tmpfs a reboot empties:
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
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::id::SessionId;
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
    /// The daemon was deliberately stopped and drained its sessions first.
    DaemonStopped,
    /// The daemon went away while the session was running. Nobody chose this,
    /// and it is the reason tombstones exist at all.
    DaemonLost,
}

impl EndReason {
    pub fn as_str(self) -> &'static str {
        match self {
            EndReason::Exited => "exited",
            EndReason::Killed => "killed",
            EndReason::DaemonStopped => "daemon_stopped",
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
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Tombstone {
    pub id: String,
    pub name: String,
    pub cwd: String,
    pub command: String,
    /// `exited` · `killed` · `daemon_stopped` · `daemon_lost`.
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
    /// The session's binary was replaced on disk while it ran — "the agent
    /// updated itself and quit" rather than "the agent crashed". Computed on
    /// the exit path, where the inode read is still meaningful, and carried
    /// here because a client that was not attached when the session died has
    /// no other route to it: `Event::SessionExited` reaches only the attached.
    #[serde(default)]
    pub child_executable_replaced: bool,
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
            child_executable_replaced: info.child_executable_replaced,
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

    fn into_tombstone(self, reason: EndReason) -> Tombstone {
        Tombstone {
            id: self.id,
            name: self.name,
            cwd: self.cwd,
            command: self.command,
            reason: reason.as_str().to_string(),
            exit_status: None,
            created_unix: self.created_unix,
            ended_unix: now_unix(),
            agent_id: self.agent_id,
            title: self.title,
            status: self.status,
            // Both roads here — a daemon that died under the session, and one
            // that stopped before the ordinary reaper reached it — skip the exit
            // path, so the pinned inode was never re-read. `false` means "nobody
            // looked", the same shape of ignorance as `exit_status: None` above,
            // and neither grave can testify to a self-update either way.
            child_executable_replaced: false,
        }
    }
}

/// What identifies one session's end. The id alone is not enough: ids are short
/// and can eventually be reused, so the creation time rides along. Built only
/// from a whole record, so the pair cannot be assembled half-right.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct GraveKey {
    session: SessionId,
    created_unix: u64,
}

impl GraveKey {
    fn of(session: &str, created_unix: u64) -> GraveKey {
        GraveKey {
            session: SessionId::new(session),
            created_unix,
        }
    }

    fn from_info(info: &SessionInfo) -> GraveKey {
        GraveKey::of(&info.id, info.created_unix)
    }

    fn from_grave(grave: &Tombstone) -> GraveKey {
        GraveKey::of(&grave.id, grave.created_unix)
    }

    fn from_roster(entry: &RosterEntry) -> GraveKey {
        GraveKey::of(&entry.id, entry.created_unix)
    }
}

struct State {
    graves: Vec<Tombstone>,
    roster: HashMap<SessionId, RosterEntry>,
    /// An index of `graves`, keeping the "has this end already been recorded?"
    /// question O(1). It is what stops the bounded shutdown fallback and a late
    /// session reaper from recording the same end twice, and what stops a
    /// roster refresh from resurrecting something already buried.
    buried: HashSet<GraveKey>,
}

impl State {
    /// Records one session's end, unless that end is already recorded. Returns
    /// whether it was added, so a caller can skip work it does not need.
    fn record(&mut self, key: GraveKey, tombstone: impl FnOnce() -> Tombstone) -> bool {
        if !self.buried.insert(key.clone()) {
            return false;
        }
        self.roster.remove(&key.session);
        self.graves.insert(0, tombstone());
        true
    }

    /// Drops the oldest graves past the cap, and their index entries with them.
    /// The index describes `graves`, so letting it outlive what it describes is
    /// how it would grow without bound on a long-lived host.
    fn cap_graves(&mut self) {
        for dropped in self.graves.drain(MAX_GRAVES.min(self.graves.len())..) {
            self.buried.remove(&GraveKey::from_grave(&dropped));
        }
    }
}

/// The on-disk record of what died. One per daemon, in `durable_state_dir` —
/// a record whose whole purpose is to explain a loss must survive the reboot
/// that caused it.
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
    /// A graveyard that records nothing, for the one caller that must not fail:
    /// a daemon that has just inherited live sessions across an `execve`.
    ///
    /// Opening the real one reads and rewrites two files, and on that path a
    /// failure would end the process — taking with it the PTYs it was handed,
    /// which are the only things in this system that cannot be recreated. A
    /// daemon with no tombstone log explains a later loss worse. A daemon that
    /// exited caused one.
    ///
    /// The cost is larger than "no history": every session this daemon goes on
    /// to create is invisible to the roster too, so a later crash cannot
    /// explain their loss either, and this does not heal by itself. The way
    /// back is to repair the state directory and hand off again — a restart
    /// would end the very sessions the fallback existed to keep.
    pub fn detached() -> Graveyard {
        Graveyard {
            graves_path: PathBuf::new(),
            roster_path: PathBuf::new(),
            state: Mutex::new(State {
                graves: Vec::new(),
                roster: HashMap::new(),
                buried: HashSet::new(),
            }),
        }
    }

    /// Move a session from the roster to the graves by id, for a caller that
    /// knows the session is gone but never held its `SessionInfo` — the
    /// adoption path, where what is known about a session is whatever the
    /// previous daemon wrote down.
    pub fn bury_by_id(&self, id: &str, reason: EndReason) {
        {
            let mut state = self.state.lock().unwrap();
            let key = SessionId::new(id.to_string());
            let Some(entry) = state.roster.remove(&key) else {
                return;
            };
            let grave = entry.into_tombstone(reason);
            let grave_key = GraveKey::from_grave(&grave);
            if state.buried.insert(grave_key) {
                state.graves.insert(0, grave);
                state.graves.truncate(MAX_GRAVES);
            }
        }
        if let Err(error) = self.persist_graves().and_then(|_| self.persist_roster()) {
            eprintln!("termiod: could not record the loss of session {id}: {error:#}");
        }
    }

    /// Open the graveyard, keeping `alive` on the roster instead of burying it.
    ///
    /// The roster's whole meaning is "these were running when a daemon last
    /// wrote this file, and nobody buried them" — which is a crash everywhere
    /// except one place: a handoff, where the new image inherits the very
    /// processes the roster names. Those are alive and must stay on the roster;
    /// anything else in the file is the loss it has always been.
    pub fn open_retaining(dir: &Path, alive: &[String]) -> Result<Graveyard> {
        let graveyard = Graveyard {
            graves_path: dir.join("tombstones.json"),
            roster_path: dir.join("roster.json"),
            state: Mutex::new(State {
                graves: Vec::new(),
                roster: HashMap::new(),
                buried: HashSet::new(),
            }),
        };

        let mut graves: Vec<Tombstone> = read_json(&graveyard.graves_path).unwrap_or_default();
        let entries: Vec<RosterEntry> = read_json(&graveyard.roster_path).unwrap_or_default();
        let (survivors, orphans): (Vec<RosterEntry>, Vec<RosterEntry>) = entries
            .into_iter()
            .partition(|entry| alive.contains(&entry.id));
        // Newest first, so the cap drops the oldest history rather than the
        // sessions that just died.
        for orphan in orphans.into_iter().rev() {
            graves.insert(0, orphan.into_tombstone(EndReason::DaemonLost));
        }
        graves.truncate(MAX_GRAVES);

        {
            let mut state = graveyard.state.lock().unwrap();
            state.graves = graves;
            // Index what was just loaded, so the invariant holds from the first
            // burial rather than from the first one this daemon happens to make.
            state.buried = state.graves.iter().map(GraveKey::from_grave).collect();
            // The roster starts with the survivors and nothing else: whatever
            // the last daemon held and did not hand over is now buried, and
            // leaving it in the file would bury it twice on the next start.
            state.roster = survivors
                .into_iter()
                .map(|entry| (SessionId::new(entry.id.clone()), entry))
                .collect();
        }
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
            if state.buried.contains(&GraveKey::from_info(info)) {
                return;
            }
            state
                .roster
                .insert(SessionId::new(info.id.clone()), RosterEntry::from_info(info));
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
            let key = GraveKey::from_info(info);
            if !state.record(key, || Tombstone::from_info(info, reason, exit_status)) {
                return;
            }
            state.cap_graves();
        }
        if let Err(error) = self.persist_roster().and_then(|_| self.persist_graves()) {
            eprintln!("termiod: could not record session end: {error:#}");
        }
    }

    /// Converts anything that did not reach the ordinary reaper before the
    /// shutdown deadline. The shared `buried` set makes this atomic with
    /// `bury`, so a late reaper cannot replace or duplicate the stop reason.
    pub fn bury_remaining(&self, reason: EndReason) -> Result<()> {
        {
            let mut state = self.state.lock().unwrap();
            let mut remaining: Vec<RosterEntry> =
                state.roster.drain().map(|(_, entry)| entry).collect();
            // Oldest first, because each is pushed onto the front: the graves
            // come out newest-first, the order every other path leaves them in.
            remaining.sort_by_key(|entry| entry.created_unix);
            for entry in remaining {
                let key = GraveKey::from_roster(&entry);
                state.record(key, || entry.into_tombstone(reason));
            }
            state.cap_graves();
        }

        // The grave must reach disk before its roster entry disappears. If the
        // process dies between these writes, the next daemon may show a
        // duplicate explanation, but it cannot silently lose the session.
        self.persist_graves()?;
        self.persist_roster()
    }

    /// Every tombstone, newest first.
    pub fn all(&self) -> Vec<Tombstone> {
        self.state.lock().unwrap().graves.clone()
    }

    fn persist_graves(&self) -> Result<()> {
        if self.detached_from_disk() {
            return Ok(());
        }
        let graves = self.state.lock().unwrap().graves.clone();
        write_json(&self.graves_path, &graves)
    }

    /// A `detached` graveyard has no files. Writing is a success that writes
    /// nothing rather than an error, so the callers that already treat a
    /// persist failure as "a worse explanation later, never a broken terminal
    /// now" do not fill the log saying so on every session.
    fn detached_from_disk(&self) -> bool {
        self.graves_path.as_os_str().is_empty()
    }

    fn persist_roster(&self) -> Result<()> {
        if self.detached_from_disk() {
            return Ok(());
        }
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
            project: Some("/work".to_string()),
            title: Some("fixing the parser".to_string()),
            attached_clients: 0,
            writer_client_id: None,
            foreground_pid: None,
            foreground_argv: None,
            foreground_job: false,
            child_cwd: None,
            child_executable: None,
            child_executable_replaced: false,
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
        let graveyard = Graveyard::open_retaining(&dir, &[]).unwrap();
        graveyard.note_live(&info("a"));
        graveyard.bury(&info("a"), EndReason::Exited, Some(0));

        let graves = graveyard.all();
        assert_eq!(graves.len(), 1);
        assert_eq!(graves[0].reason, "exited");
        assert_eq!(graves[0].exit_status, Some(0));
        assert_eq!(graves[0].status, "working");
        assert_eq!(graves[0].title.as_deref(), Some("fixing the parser"));
    }

    /// "The agent updated itself and quit" survives to a client that was not
    /// watching. `Event::SessionExited` reaches only attached clients, so the
    /// durable record is the sole route for anyone who reconnects afterwards —
    /// and the field it needs is computed exactly once, on the exit path.
    #[test]
    fn a_replaced_executable_survives_in_the_durable_record() {
        let dir = temp_dir("replaced");
        let graveyard = Graveyard::open_retaining(&dir, &[]).unwrap();
        let mut dying = info("a");
        dying.alive = false;
        dying.child_executable_replaced = true;
        graveyard.note_live(&info("a"));
        graveyard.bury(&dying, EndReason::Exited, Some(0));
        drop(graveyard);

        // Reopened, so this reads the field back off disk rather than out of
        // the in-memory copy that bury() just wrote.
        let graves = Graveyard::open_retaining(&dir, &[]).unwrap().all();
        assert_eq!(graves.len(), 1);
        assert!(
            graves[0].child_executable_replaced,
            "a self-update is why the session ended, and the record must say so"
        );
    }

    /// Graveyards written before the field existed must still load. It is the
    /// one file in the daemon that outlives its own binary by design, so a
    /// missing key is an ordinary older-daemon read, not corruption.
    #[test]
    fn a_grave_written_without_the_field_still_loads() {
        let dir = temp_dir("legacy");
        std::fs::write(
            dir.join("tombstones.json"),
            r#"[{"id":"a","name":"a","cwd":"/tmp","command":"sh","reason":"exited",
                 "exit_status":0,"created_unix":1000,"ended_unix":2000,"status":"idle"}]"#,
        )
        .unwrap();

        let graves = Graveyard::open_retaining(&dir, &[]).unwrap().all();
        assert_eq!(graves.len(), 1);
        assert!(
            !graves[0].child_executable_replaced,
            "absent means the older daemon never measured it, which is not a replacement"
        );
    }

    /// The case the whole file exists for: a session still on the roster when a
    /// new daemon starts was never buried, so the last daemon died under it.
    #[test]
    fn a_session_the_daemon_died_under_is_adopted_as_lost() {
        let dir = temp_dir("crash");
        let first = Graveyard::open_retaining(&dir, &[]).unwrap();
        first.note_live(&info("a"));
        drop(first); // no bury — the daemon vanished

        let second = Graveyard::open_retaining(&dir, &[]).unwrap();
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
        let first = Graveyard::open_retaining(&dir, &[]).unwrap();
        first.note_live(&info("a"));
        first.bury(&info("a"), EndReason::Killed, Some(137));
        drop(first);

        let graves = Graveyard::open_retaining(&dir, &[]).unwrap().all();
        assert_eq!(graves.len(), 1);
        assert_eq!(graves[0].reason, "killed");
    }

    /// The index exists to answer "already recorded?" about the graves it
    /// describes. A host that runs for months buries thousands of sessions, so
    /// an index that outlived the capped list would be the one part of this
    /// file that grows for ever.
    #[test]
    fn the_index_is_capped_with_the_graves() {
        let dir = temp_dir("index-cap");
        let graveyard = Graveyard::open_retaining(&dir, &[]).unwrap();
        for index in 0..MAX_GRAVES + 50 {
            let mut ended = info(&format!("s{index}"));
            ended.created_unix = 1000 + index as u64;
            graveyard.bury(&ended, EndReason::Exited, Some(0));
        }

        let state = graveyard.state.lock().unwrap();
        assert_eq!(state.graves.len(), MAX_GRAVES);
        assert_eq!(state.buried.len(), MAX_GRAVES);
    }

    /// The deadline fallback and the actor reaper can finish in either order.
    /// Whichever arrives late must not duplicate the grave or change its reason.
    #[test]
    fn a_late_reaper_does_not_replace_the_shutdown_reason() {
        let dir = temp_dir("shutdown-race");
        let graveyard = Graveyard::open_retaining(&dir, &[]).unwrap();
        graveyard.note_live(&info("a"));
        graveyard
            .bury_remaining(EndReason::DaemonStopped)
            .unwrap();
        graveyard.bury(&info("a"), EndReason::Exited, Some(137));

        let graves = graveyard.all();
        assert_eq!(graves.len(), 1);
        assert_eq!(graves[0].reason, "daemon_stopped");
        assert_eq!(graves[0].exit_status, None);
    }

    /// Restarting repeatedly must not keep re-burying the same dead session.
    #[test]
    fn adoption_is_not_repeated_on_every_restart() {
        let dir = temp_dir("idempotent");
        let first = Graveyard::open_retaining(&dir, &[]).unwrap();
        first.note_live(&info("a"));
        drop(first);

        assert_eq!(Graveyard::open_retaining(&dir, &[]).unwrap().all().len(), 1);
        assert_eq!(Graveyard::open_retaining(&dir, &[]).unwrap().all().len(), 1);
    }

    /// History is bounded, and the cap drops the oldest — a box that has been up
    /// for a year must still be able to explain this morning.
    #[test]
    fn history_is_capped_and_drops_the_oldest() {
        let dir = temp_dir("cap");
        let graveyard = Graveyard::open_retaining(&dir, &[]).unwrap();
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
        let first = Graveyard::open_retaining(&dir, &[]).unwrap();
        first.bury(&info("a"), EndReason::Exited, Some(3));
        drop(first);

        let graves = Graveyard::open_retaining(&dir, &[]).unwrap().all();
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

        assert_eq!(Graveyard::open_retaining(&dir, &[]).unwrap().all().len(), 0);
    }
}
