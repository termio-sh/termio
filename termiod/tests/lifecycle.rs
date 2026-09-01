//! `termiod status` and `termiod stop` against a real daemon on an isolated
//! socket — the node half of the lifecycle loop, exercised the way the control
//! plane runs it: as the binary on disk, over the canonical socket.

use serde_json::Value;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_termiod");
const VERSION: &str = env!("TERMIOD_VERSION");

/// One number per directory, per process. The tests here run concurrently in
/// one process, and a clock-based nonce collided on macOS, whose clock is
/// coarse enough for two of them to start in the same tick.
static DIRECTORIES: AtomicUsize = AtomicUsize::new(0);

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> TestDir {
        let nonce = DIRECTORIES.fetch_add(1, Ordering::Relaxed);
        // Unix-domain socket paths are short on macOS; the per-user temporary
        // directory can consume most of that limit before the test adds a name.
        let path = PathBuf::from(format!("/tmp/tlc-{}-{nonce}", std::process::id()));
        std::fs::create_dir(&path).expect("create isolated daemon state directory");
        TestDir(path)
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Daemon {
    child: Child,
}

impl Daemon {
    fn start(socket: &Path) -> Daemon {
        let mut child = Command::new(BIN)
            .arg("serve")
            .env("TERMIOD_SOCK", socket)
            .env("TERMIOD_KEEP_AWAKE", "off")
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn isolated daemon");
        let deadline = Instant::now() + Duration::from_secs(5);
        while !socket.exists() {
            if let Some(status) = child.try_wait().expect("poll daemon startup") {
                let mut stderr = String::new();
                if let Some(mut stream) = child.stderr.take() {
                    let _ = stream.read_to_string(&mut stderr);
                }
                panic!("daemon exited {status} before binding its socket: {stderr}");
            }
            assert!(Instant::now() < deadline, "daemon never bound its socket");
            std::thread::sleep(Duration::from_millis(20));
        }
        Daemon { child }
    }

    fn wait_exit(&mut self) -> bool {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if self.child.try_wait().expect("poll daemon").is_some() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn termiod(socket: &Path, args: &[&str]) -> Output {
    Command::new(BIN)
        .args(args)
        .env("TERMIOD_SOCK", socket)
        .output()
        .expect("run termiod")
}

fn json(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!(
            "stdout is not JSON ({error}): {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    })
}

/// One process, one connection: the report names this build for the binary
/// and the daemon, finds the daemon's pid from the socket, and reports its
/// sessions. Without a daemon it still reports the binary, and says so.
#[test]
fn status_reports_the_binary_the_daemon_and_its_sessions() {
    let dir = TestDir::new();
    let socket = dir.0.join("d.sock");

    let before = termiod(&socket, &["status", "--json"]);
    assert!(before.status.success());
    let report = json(&before);
    assert_eq!(report["binary"]["version"], VERSION);
    assert_eq!(report["daemon"]["running"], false);
    assert!(report["daemon"]["version"].is_null());

    let daemon = Daemon::start(&socket);
    let created = termiod(&socket, &["create", "--name", "shell", "--", "sleep", "300"]);
    assert!(created.status.success(), "{}", String::from_utf8_lossy(&created.stderr));

    let during = termiod(&socket, &["status", "--json"]);
    assert!(during.status.success(), "{}", String::from_utf8_lossy(&during.stderr));
    let report = json(&during);
    assert_eq!(report["daemon"]["running"], true);
    assert_eq!(report["daemon"]["version"], VERSION);
    assert_eq!(report["daemon"]["pid"], daemon.child.id());
    assert_eq!(report["sessions"].as_array().map(Vec::len), Some(1));
    assert_eq!(report["sessions"][0]["name"], "shell");
    assert_eq!(report["sessions"][0]["attached"], 0);
    assert!(report["host_id"].as_str().is_some_and(|id| !id.is_empty()));
}

/// An idle daemon — sessions, but nobody attached and no agent mid-task —
/// leaves on request, and the socket is gone once it has.
#[test]
fn stop_takes_an_idle_daemon_down() {
    let dir = TestDir::new();
    let socket = dir.0.join("d.sock");
    let mut daemon = Daemon::start(&socket);
    let created = termiod(&socket, &["create", "--name", "shell", "--", "sleep", "300"]);
    assert!(created.status.success());

    let stopped = termiod(&socket, &["stop", "--json"]);
    assert!(stopped.status.success(), "{}", String::from_utf8_lossy(&stopped.stderr));
    assert_eq!(json(&stopped)["stopped"], true);
    assert!(daemon.wait_exit(), "daemon still running after stop");
    assert!(!socket.exists(), "socket left behind after stop");

    // Nothing running is the state wanted, so asking again is success.
    let again = termiod(&socket, &["stop", "--json"]);
    assert!(again.status.success());
    assert_eq!(json(&again)["stopped"], true);
}

/// The stop that #571 reported as a failure: the daemon left, but its socket
/// file stayed on disk and its process table entry stayed with it.
///
/// Both halves are reproduced without any timing to lose. The directory is
/// made unwritable so the daemon's own `remove_file` fails on the way out,
/// leaving the same file-still-there state a client autostarting a replacement
/// produces. And the daemon is this test's child, never waited on before the
/// stop runs — the shape of every client that autostarts a daemon and outlives
/// it, and the reason `kill(pid, 0)` kept answering for a process that had
/// already exited.
///
/// `--force` only skips the roster round trip, which the sealed directory would
/// break; the wait this is about is the same in both paths.
#[test]
fn stop_succeeds_when_the_daemon_left_its_socket_and_its_pid_behind() {
    let dir = TestDir::new();
    let socket = dir.0.join("d.sock");
    let mut daemon = Daemon::start(&socket);

    // Owner without write permission cannot unlink from its own directory.
    let sealed = std::fs::Permissions::from_mode(0o500);
    std::fs::set_permissions(&dir.0, sealed).expect("seal the daemon's directory");

    let stopped = termiod(&socket, &["stop", "--force", "--json"]);
    std::fs::set_permissions(&dir.0, std::fs::Permissions::from_mode(0o700))
        .expect("unseal the daemon's directory");

    assert!(stopped.status.success(), "{}", String::from_utf8_lossy(&stopped.stderr));
    assert_eq!(json(&stopped)["stopped"], true);
    // The two states that used to be read as "still running", asserted so the
    // test fails if it stops reproducing them rather than passing vacuously.
    assert!(socket.exists(), "the daemon removed the socket; this no longer reproduces #571");
    assert!(
        unsafe { libc::kill(daemon.child.id() as i32, 0) } == 0,
        "the daemon's pid was already reaped; this no longer reproduces #571"
    );
    assert!(daemon.wait_exit(), "daemon still running after stop");
}

/// `serve` never deletes a file it did not create.
///
/// A plain file where the socket should be proves no daemon is serving — which
/// is enough for a stop to conclude it stopped, and deliberately not enough to
/// unlink the file and bind over its name. `TERMIOD_SOCK` can name anywhere,
/// so the file that would be destroyed is whatever the user pointed it at.
#[test]
fn serve_refuses_to_replace_a_file_it_did_not_create() {
    let dir = TestDir::new();
    let occupied = dir.0.join("d.sock");
    std::fs::write(&occupied, b"someone else's file").expect("occupy the socket path");

    // Spawned rather than run to completion: a `serve` that wrongly accepts the
    // path does not exit, and a test that proves a regression by hanging is not
    // a test. It gets a bounded window to refuse, and is killed if it does not.
    let mut child = Command::new(BIN)
        .arg("serve")
        .env("TERMIOD_SOCK", &occupied)
        .env("TERMIOD_KEEP_AWAKE", "off")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("run termiod serve");
    let deadline = Instant::now() + Duration::from_secs(5);
    let refused = loop {
        match child.try_wait().expect("poll serve") {
            Some(status) => break Some(status),
            None if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            None => std::thread::sleep(Duration::from_millis(20)),
        }
    };

    let refused = refused.expect("serve bound over a file that was not its socket");
    assert!(!refused.success(), "serve accepted a socket path that held a plain file");
    assert_eq!(
        std::fs::read(&occupied).expect("the file must still be there"),
        b"someone else's file",
        "serve destroyed a file it did not create"
    );
}

/// The other half of the same rule: a socket the daemon really did leave behind
/// is still cleaned up. A kill -9 runs no shutdown, so the file survives with
/// nothing serving it, and the next start must replace it rather than refuse —
/// otherwise one crash would leave the machine unable to start a daemon at all.
#[test]
fn serve_replaces_a_socket_its_daemon_died_holding() {
    let dir = TestDir::new();
    let socket = dir.0.join("d.sock");
    let mut dead = Daemon::start(&socket);
    let killed = dead.child.kill().and_then(|()| dead.child.wait());
    assert!(killed.is_ok(), "could not kill the first daemon");
    assert!(socket.exists(), "kill -9 should leave the socket file behind");

    // Not `Daemon::start`'s wait: that watches for the socket file, which the
    // dead daemon already left. Serving is the thing being asserted, so serving
    // is what this waits for.
    let _replacement = Daemon::start(&socket);
    let deadline = Instant::now() + Duration::from_secs(5);
    let running = loop {
        let status = termiod(&socket, &["status", "--json"]);
        if status.status.success() && json(&status)["daemon"]["running"] == true {
            break true;
        }
        if Instant::now() >= deadline {
            break false;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(running, "no daemon came up over the socket its predecessor died holding");
}

/// A daemon this process cannot reach is not a daemon that stopped.
///
/// The socket is denied rather than removed, which is what a sandbox does — and
/// what the fix for #571 must not mistake for absence, since answering a stop
/// with success here would let an upgrade replace the binary under a daemon
/// still serving every session it holds. The daemon must survive, and the
/// refusal must say the connection was denied.
#[test]
fn stop_refuses_to_call_an_unreachable_daemon_stopped() {
    let dir = TestDir::new();
    let socket = dir.0.join("d.sock");
    let mut daemon = Daemon::start(&socket);
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o000))
        .expect("deny the socket");

    let refused = termiod(&socket, &["stop", "--json"]);
    assert!(!refused.status.success(), "an unreachable daemon was reported stopped");
    let complaint = String::from_utf8_lossy(&refused.stderr);
    assert!(
        complaint.contains("reaching the daemon"),
        "the refusal does not name what went wrong: {complaint}"
    );
    assert!(
        daemon.child.try_wait().expect("poll").is_none(),
        "the daemon exited on a stop that never reached it"
    );

    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))
        .expect("restore the socket");
    let stopped = termiod(&socket, &["stop", "--json"]);
    assert!(stopped.status.success(), "{}", String::from_utf8_lossy(&stopped.stderr));
    assert!(daemon.wait_exit(), "daemon still running after stop");
}

/// A session whose agent reports `working` keeps the daemon up, and the
/// refusal names it: the decision is the user's, and a count cannot inform
/// it. `--force` overrides.
#[test]
fn stop_declines_while_an_agent_is_mid_task_unless_forced() {
    let dir = TestDir::new();
    let socket = dir.0.join("d.sock");
    let mut daemon = Daemon::start(&socket);
    let created = termiod(&socket, &["create", "--name", "claude", "--", "sleep", "300"]);
    assert!(created.status.success());
    let id = String::from_utf8_lossy(&created.stdout).trim().to_string();
    let marked = termiod(&socket, &["set-status", &id, "working"]);
    assert!(marked.status.success(), "{}", String::from_utf8_lossy(&marked.stderr));

    let declined = termiod(&socket, &["stop", "--json"]);
    assert_eq!(declined.status.code(), Some(3), "{}", String::from_utf8_lossy(&declined.stderr));
    let report = json(&declined);
    assert_eq!(report["stopped"], false);
    assert_eq!(report["busy"][0]["name"], "claude");
    assert_eq!(report["busy"][0]["status"], "working");
    assert!(daemon.child.try_wait().expect("poll").is_none(), "daemon exited on a declined stop");

    let forced = termiod(&socket, &["stop", "--force", "--json"]);
    assert!(forced.status.success(), "{}", String::from_utf8_lossy(&forced.stderr));
    assert!(daemon.wait_exit(), "daemon still running after --force");
}
