//! Acceptance for the program status protocol (`OSC 7501`) through a real
//! daemon and a real PTY: the host answers the support query ahead of anything
//! a client sends back, and a program's report reaches an attached client as a
//! status event.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
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

fn read_frame(r: &mut impl Read) -> Option<(u8, Vec<u8>)> {
    let mut header = [0u8; 5];
    r.read_exact(&mut header).ok()?;
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).ok()?;
    Some((header[0], payload))
}

struct Daemon {
    child: Child,
    dir: String,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn start_daemon(tag: &str) -> Daemon {
    // The serve lock lives beside the socket, so the socket gets its own
    // directory — a bare /tmp path would contend for /tmp/termiod.lock with
    // whatever real daemon this box is running.
    let dir = format!("/tmp/termiod-program-status-test-{tag}");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("socket dir");
    let child = Command::new(BIN)
        .arg("serve")
        .env("TERMIOD_SOCK", format!("{dir}/termiod.sock"))
        .env("TERMIOD_KEEP_AWAKE", "off")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !std::path::Path::new(&format!("{dir}/termiod.sock")).exists() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
    Daemon { child, dir }
}

#[test]
fn the_host_answers_the_query_and_carries_a_report() {
    let daemon = start_daemon("report");
    let mut stream = UnixStream::connect(format!("{}/termiod.sock", daemon.dir)).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("read timeout");

    let hello = br#"{"op":"hello","proto":1,"min_proto":1,"role":"attach","caps":["snapshot","spawn_command","events"],"client":"program-status-test"}"#;
    write_frame(&mut stream, b'C', hello);
    let (kind, _) = read_frame(&mut stream).expect("hello reply");
    assert_eq!(kind, b'C');

    // The program does what a real one would: asks, reads the answer off its
    // own tty in raw mode, and only then reports. A host that never answered
    // would leave `head` waiting and the marker empty.
    //
    // This client plays the writer's surface at its fastest: the moment the
    // query reaches it, it types a DA1 reply. Claude Code and pi read a DA1
    // reply that arrives first as "not supported", so the host's answer has to
    // be in the PTY before anything a client can send.
    let marker = format!("{}/reply", daemon.dir);
    let script = format!(
        r"stty raw -echo; printf '\033]7501;?\033\\'; head -c 10 > {marker}; printf '\033]7501;state=blocked:kind=permission\033\\'; sleep 5"
    );
    let attach = serde_json::json!({
        "op": "attach",
        "target": "programstatus",
        "rows": 24,
        "cols": 80,
        "mode": "interact",
        "create_if_missing": { "argv": [], "command": script, "rows": 24, "cols": 80 },
    });
    write_frame(&mut stream, b'C', attach.to_string().as_bytes());

    let deadline = Instant::now() + Duration::from_secs(8);
    let mut blocked = None;
    while Instant::now() < deadline && blocked.is_none() {
        let Some((kind, payload)) = read_frame(&mut stream) else {
            break;
        };
        if kind == b'D' && payload.windows(9).any(|window| window == b"\x1b]7501;?") {
            write_frame(&mut stream, b'D', b"\x1b[?62;22c");
        }
        let text = String::from_utf8_lossy(&payload);
        if text.contains("\"ev\":\"status\"") && text.contains("\"status\":\"needs_you\"") {
            blocked = Some(text.into_owned());
        }
    }
    let blocked = blocked.expect("the blocked report never reached the client");
    assert!(
        blocked.contains("\"source\":\"program\""),
        "the status did not name its channel: {blocked}"
    );

    let reply = std::fs::read(&marker).expect("the program never read a reply");
    assert_eq!(reply, b"\x1b]7501;?\x1b\\");
}
