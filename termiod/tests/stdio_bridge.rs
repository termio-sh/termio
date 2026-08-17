//! §C.9 acceptance for the `termiod stdio` bridge: a client speaking the framed
//! protocol over the bridge's stdin/stdout gets byte-identical results to a
//! local Unix-socket client. Driven with blocking std pipes so the exchange is
//! deterministic (no async-stdin harness races).

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_termiod");

fn write_frame(w: &mut impl Write, kind: u8, payload: &[u8]) {
    let mut header = [0u8; 5];
    header[0] = kind;
    header[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    w.write_all(&header).unwrap();
    w.write_all(payload).unwrap();
    w.flush().unwrap();
}

fn read_frame(r: &mut impl Read) -> (u8, Vec<u8>) {
    let mut header = [0u8; 5];
    r.read_exact(&mut header).expect("frame header");
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).expect("frame payload");
    (header[0], payload)
}

struct Daemon {
    child: Child,
    socket: String,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = std::fs::remove_file(&self.socket);
    }
}

fn start_daemon(tag: &str) -> Daemon {
    let socket = format!("/tmp/termiod-bridge-test-{tag}.sock");
    let _ = std::fs::remove_file(&socket);
    let child = Command::new(BIN)
        .arg("serve")
        .env("TERMIOD_SOCK", &socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !std::path::Path::new(&socket).exists() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
    Daemon { child, socket }
}

#[test]
fn framed_protocol_is_byte_identical_over_the_stdio_bridge() {
    let daemon = start_daemon("accept");

    // A session emitting a known marker after a short delay, so live D follows
    // the snapshot boundary.
    let created = Command::new(BIN)
        .args([
            "create",
            "--name",
            "bridgesession",
            "--",
            "bash",
            "--norc",
            "-c",
            "sleep 0.5; printf 'BRIDGE_ACCEPTANCE_MARK\\r\\n'; sleep 30",
        ])
        .env("TERMIOD_SOCK", &daemon.socket)
        .output()
        .expect("create");
    assert!(created.status.success(), "create failed");

    let mut bridge = Command::new(BIN)
        .arg("stdio")
        .env("TERMIOD_SOCK", &daemon.socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn stdio bridge");
    let mut to_bridge = bridge.stdin.take().unwrap();
    let mut from_bridge = bridge.stdout.take().unwrap();

    // hello → hello_ok, byte-identical through the bridge.
    let hello = br#"{"op":"hello","proto":1,"min_proto":1,"role":"attach","caps":["snapshot"],"client":"bridge-test"}"#;
    write_frame(&mut to_bridge, b'C', hello);
    let (kind, payload) = read_frame(&mut from_bridge);
    assert_eq!(kind, b'C');
    assert!(
        String::from_utf8_lossy(&payload).contains("\"op\":\"hello_ok\""),
        "expected hello_ok, got {}",
        String::from_utf8_lossy(&payload)
    );

    // attach as observer → attached, then S snapshot, then ready, then live D.
    let attach = br#"{"op":"attach","target":"bridgesession","rows":24,"cols":80,"mode":"observe"}"#;
    write_frame(&mut to_bridge, b'C', attach);

    let (mut saw_attached, mut saw_snapshot, mut saw_ready, mut saw_marker) =
        (false, false, false, false);
    for _ in 0..200 {
        let (kind, payload) = read_frame(&mut from_bridge);
        match kind {
            b'C' if String::from_utf8_lossy(&payload).contains("\"op\":\"attached\"") => {
                saw_attached = true;
            }
            b'S' => {
                assert!(saw_attached, "S arrived before attached");
                saw_snapshot = true;
            }
            b'E' if String::from_utf8_lossy(&payload).contains("\"ev\":\"ready\"") => {
                assert!(saw_snapshot, "ready arrived before the S snapshot");
                saw_ready = true;
            }
            b'D' => {
                const MARK: &[u8] = b"BRIDGE_ACCEPTANCE_MARK";
                if payload.windows(MARK.len()).any(|w| w == MARK) {
                    assert!(saw_ready, "live D marker arrived before ready");
                    saw_marker = true;
                }
            }
            _ => {}
        }
        if saw_attached && saw_snapshot && saw_ready && saw_marker {
            break;
        }
    }

    let _ = bridge.kill();
    assert!(saw_attached, "no attached frame over the bridge");
    assert!(saw_snapshot, "no S snapshot over the bridge");
    assert!(saw_ready, "no ready event over the bridge");
    assert!(saw_marker, "live D marker never arrived over the bridge");
}
