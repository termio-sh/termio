//! `termio api` acceptance: the protocol reaches a third-party program without
//! that program implementing framing, and an op the daemon does not know comes
//! back as a refusal rather than silence.
//!
//! The refusal is the load-bearing one. `Control` used to carry a
//! `#[serde(other)]` catch-all, so an unknown op decoded to it and the daemon
//! dropped the request on the floor — the `unknown op` error existed in the
//! source and was unreachable, and any client waiting on the reply's `re`
//! waited forever. Forward compatibility is the reason to publish a protocol at
//! all, so it gets a test that fails loudly if the catch-all comes back.

use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const DAEMON: &str = env!("CARGO_BIN_EXE_termiod");
const CLI: &str = env!("CARGO_BIN_EXE_termio");

struct Daemon {
    child: Child,
    directory: String,
    socket: String,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

/// One daemon per test, each in its own directory. The serve lock lives beside
/// the socket (`paths::acquire_serve_lock`), so daemons sharing `/tmp` would
/// serialize on one lock and every test but the first would fail to bind.
fn start_daemon(tag: &str) -> Daemon {
    let directory = format!("/tmp/termiod-api-test-{tag}");
    let socket = format!("{directory}/termiod.sock");
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).expect("test directory");
    let child = Command::new(DAEMON)
        .arg("serve")
        .env("TERMIOD_SOCK", &socket)
        .env("TERMIOD_KEEP_AWAKE", "off")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !std::path::Path::new(&socket).exists() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
    Daemon {
        child,
        directory,
        socket,
    }
}

fn api(daemon: &Daemon, args: &[&str]) -> (bool, String, String) {
    let output = Command::new(CLI)
        .arg("api")
        .args(args)
        .env("TERMIOD_SOCK", &daemon.socket)
        // Short, because a test that reaches this bound is a hang, and a hang
        // should fail in seconds rather than at the harness timeout.
        .env("TERMIO_CLI_TIMEOUT", "10")
        .output()
        .expect("run termio api");
    (
        output.status.success(),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

#[test]
fn an_unknown_op_is_refused_rather_than_swallowed() {
    let daemon = start_daemon("unknown-op");
    let (ok, stdout, stderr) = api(&daemon, &["call", r#"{"op":"teleport","seq":7}"#]);

    assert!(
        !ok,
        "an unknown op must fail; stdout={stdout} stderr={stderr}"
    );
    let reply: serde_json::Value =
        serde_json::from_str(stdout.trim()).unwrap_or_else(|_| panic!("no reply: {stderr}"));
    assert_eq!(reply["op"], "error");
    assert_eq!(reply["code"], "proto_error");
    assert_eq!(
        reply["re"], 7,
        "the refusal must echo the request's seq, or a client cannot match it"
    );
    assert!(
        reply["message"]
            .as_str()
            .is_some_and(|message| message.contains("teleport")),
        "the refusal should name the op: {reply}"
    );
}

#[test]
fn call_answers_a_known_op_and_echoes_its_seq() {
    let daemon = start_daemon("list");
    let (ok, stdout, stderr) = api(&daemon, &["call", r#"{"op":"list"}"#]);

    assert!(ok, "list failed: {stderr}");
    let reply: serde_json::Value =
        serde_json::from_str(stdout.trim()).unwrap_or_else(|_| panic!("no reply: {stderr}"));
    assert_eq!(reply["op"], "sessions");
    assert_eq!(reply["re"], 1, "an omitted seq defaults to 1");
    assert!(reply["sessions"].is_array());
}

#[test]
fn capabilities_reports_the_handshake() {
    let daemon = start_daemon("capabilities");
    let (ok, stdout, stderr) = api(&daemon, &["capabilities"]);

    assert!(ok, "capabilities failed: {stderr}");
    let hello: serde_json::Value =
        serde_json::from_str(stdout.trim()).unwrap_or_else(|_| panic!("no reply: {stderr}"));
    assert_eq!(hello["op"], "hello_ok");
    assert_eq!(hello["proto"], 1);
    assert!(
        hello["caps"]
            .as_array()
            .is_some_and(|caps| caps.iter().any(|cap| cap == "events")),
        "the handshake should report negotiated capabilities: {hello}"
    );
    assert!(
        hello["version"].as_str().is_some_and(|v| !v.is_empty()),
        "the handshake should name the daemon's build: {hello}"
    );
}

/// The summary is derived from the schema document, so it is worth one test
/// that the derivation still finds the ops — a refactor that silently produced
/// an empty summary would otherwise ship.
#[test]
fn schema_prints_a_summary_and_the_document_without_a_daemon() {
    // No daemon: the schema is baked into the binary, and a box that cannot
    // reach a daemon must still be able to read what it would say.
    let summary = Command::new(CLI)
        .args(["api", "schema"])
        .env("TERMIOD_SOCK", "/nonexistent/termiod.sock")
        .output()
        .expect("run termio api schema");
    assert!(summary.status.success());
    let text = String::from_utf8_lossy(&summary.stdout);
    for expected in [
        "Termio session protocol 1",
        "Handshake",
        "Requests",
        "Replies",
        "Events",
        "subscribe_resource",
        "fs_search",
    ] {
        assert!(text.contains(expected), "summary is missing {expected}:\n{text}");
    }
    assert!(
        !text.contains("\"$schema\""),
        "the bare summary should not be the JSON document"
    );

    let document = Command::new(CLI)
        .args(["api", "schema", "--json"])
        .output()
        .expect("run termio api schema --json");
    assert!(document.status.success());
    let parsed: serde_json::Value =
        serde_json::from_slice(&document.stdout).expect("--json prints a JSON document");
    assert_eq!(parsed["protocol"], 1);

    let path = std::env::temp_dir().join("termio-api-schema-test.json");
    let _ = std::fs::remove_file(&path);
    let written = Command::new(CLI)
        .args(["api", "schema", "--output"])
        .arg(&path)
        .output()
        .expect("run termio api schema --output");
    assert!(written.status.success());
    let from_file: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).expect("written schema"))
            .expect("--output writes a JSON document");
    assert_eq!(from_file, parsed, "--output and --json must write the same document");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_malformed_request_fails_before_connecting() {
    let daemon = start_daemon("malformed");

    let (ok, _, stderr) = api(&daemon, &["call", "[1]"]);
    assert!(!ok, "an array is not a control message");
    assert!(stderr.contains("JSON object"), "unhelpful error: {stderr}");

    let (ok, _, stderr) = api(&daemon, &["call", r#"{"id":"x"}"#]);
    assert!(!ok, "a message with no op is not a control message");
    assert!(stderr.contains("op"), "unhelpful error: {stderr}");
}
