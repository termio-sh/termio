//! Invariant JOIN (§C.5): for each attaching client there is exactly one
//! boundary B in the session's output byte stream such that the `S` payload
//! reflects every byte before B, and the client receives every byte from B
//! onward, in order, exactly once. The PTY is never paused and no other
//! client's delivery is affected.
//!
//! Correctness rests on the sidecar command channel being a lossless FIFO
//! shared by `Write` and `Snapshot` — the FIFO *is* the sequence number, which
//! is why no cursor rides the wire. Nothing enforces that today except this
//! test, so anyone optimising the sidecar finds out here rather than in a
//! client that silently repaints a screen which never occurred.
//!
//! The session floods a monotonic counter, so the byte stream carries its own
//! ordering: a gap, a duplicate, or a snapshot taken at a different boundary
//! than the buffering all show up as a break in the sequence.

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_termiod");
const ROWS: u16 = 24;
const COLS: u16 = 80;
/// Lines the late client must observe past the boundary before the sequence is
/// considered proven.
const LINES_PAST_BOUNDARY: usize = 100;

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
    socket: String,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = std::fs::remove_file(&self.socket);
    }
}

fn start_daemon(tag: &str) -> Daemon {
    let socket = format!("/tmp/termiod-join-test-{tag}.sock");
    let _ = std::fs::remove_file(&socket);
    let child = Command::new(BIN)
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
    Daemon { child, socket }
}

fn spawn_bridge(socket: &str) -> (Child, std::process::ChildStdin, std::process::ChildStdout) {
    let mut bridge = Command::new(BIN)
        .arg("stdio")
        .env("TERMIOD_SOCK", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn stdio bridge");
    let to_bridge = bridge.stdin.take().expect("bridge stdin");
    let from_bridge = bridge.stdout.take().expect("bridge stdout");
    (bridge, to_bridge, from_bridge)
}

fn handshake(
    to_bridge: &mut std::process::ChildStdin,
    from_bridge: &mut std::process::ChildStdout,
    session: &str,
    caps: &str,
    client: &str,
) {
    let hello = format!(
        r#"{{"op":"hello","proto":1,"min_proto":1,"role":"attach","caps":[{caps}],"client":"{client}"}}"#
    );
    write_frame(to_bridge, b'C', hello.as_bytes());
    let (kind, payload) = read_frame(from_bridge).expect("hello reply");
    assert_eq!(kind, b'C');
    assert!(
        String::from_utf8_lossy(&payload).contains("\"op\":\"hello_ok\""),
        "expected hello_ok, got {}",
        String::from_utf8_lossy(&payload)
    );

    let attach = format!(
        r#"{{"op":"attach","target":"{session}","rows":{ROWS},"cols":{COLS},"mode":"observe"}}"#
    );
    write_frame(to_bridge, b'C', attach.as_bytes());
}

/// The `S` payload as a client sees it, parsed independently of `protocol.rs`
/// so a wire regression cannot hide behind a shared encoder bug.
struct WireSnapshot {
    rows: u16,
    cols: u16,
    cursor_x: u16,
    cursor_y: u16,
    /// Row-major codepoints, already resolved through a VT for the v2 format.
    codepoints: Vec<u32>,
}

fn parse_snapshot(payload: &[u8]) -> WireSnapshot {
    assert!(payload.len() >= 12, "malformed snapshot header");
    let format = payload[0];
    let rows = u16::from_be_bytes([payload[1], payload[2]]);
    let cols = u16::from_be_bytes([payload[3], payload[4]]);
    let cursor_x = u16::from_be_bytes([payload[5], payload[6]]);
    let cursor_y = u16::from_be_bytes([payload[7], payload[8]]);
    let title_len = usize::from(u16::from_be_bytes([payload[10], payload[11]]));
    let body = &payload[12 + title_len..];

    match format {
        // v1: row-major 16-byte cells, codepoint first.
        1 => {
            let expected = usize::from(rows) * usize::from(cols);
            assert_eq!(body.len(), expected * 16, "unexpected packed cell length");
            let codepoints = body
                .chunks_exact(16)
                .map(|cell| u32::from_be_bytes([cell[0], cell[1], cell[2], cell[3]]))
                .collect();
            WireSnapshot {
                rows,
                cols,
                cursor_x,
                cursor_y,
                codepoints,
            }
        }
        // v2: the screen serialised back to VT sequences. Replaying it is what
        // every real client does, so the test reads the screen the same way.
        2 => {
            assert!(body.len() >= 4, "malformed snapshot vt length");
            let vt_len = u32::from_be_bytes([body[0], body[1], body[2], body[3]]) as usize;
            assert_eq!(body.len(), 4 + vt_len, "snapshot vt length disagrees");
            let mut terminal = termiod_vt::VtTerminal::new(rows, cols).expect("vt terminal");
            terminal.vt_write(&body[4..]);
            let replayed = terminal.snapshot().expect("replay snapshot");
            WireSnapshot {
                rows: replayed.rows,
                cols: replayed.cols,
                cursor_x: replayed.cursor_x,
                cursor_y: replayed.cursor_y,
                codepoints: replayed.cells.iter().map(|cell| cell.codepoint).collect(),
            }
        }
        other => panic!("unsupported snapshot payload version {other}"),
    }
}

impl WireSnapshot {
    fn row_text(&self, row: u16) -> String {
        let start = usize::from(row) * usize::from(self.cols);
        let end = start + usize::from(self.cols);
        self.codepoints[start..end]
            .iter()
            .map(|&codepoint| match codepoint {
                0 => ' ',
                other => char::from_u32(other).unwrap_or('\u{fffd}'),
            })
            .collect()
    }

    /// The highest complete counter on screen. A truncated counter is always a
    /// proper prefix of the next one, so it is strictly smaller than the last
    /// complete line and never wins the maximum.
    fn highest_counter(&self) -> u64 {
        (0..self.rows)
            .filter_map(|row| parse_counter(&self.row_text(row)))
            .max()
            .expect("no counter line on the snapshot screen")
    }

    /// The in-progress line: the cursor row up to the cursor column.
    fn cursor_fragment(&self) -> String {
        let row = self.row_text(self.cursor_y);
        row.chars().take(usize::from(self.cursor_x)).collect()
    }
}

fn parse_counter(line: &str) -> Option<u64> {
    line.trim().strip_prefix("JOIN ")?.trim().parse().ok()
}

/// Counters in a byte stream, split on line endings with `\r` removed so a
/// boundary landing inside a `\r\n` pair does not read as a missing line.
///
/// Only *complete* lines are returned. Both readers stop mid-flood, so the
/// bytes they hold almost always end part-way through a line, and a counter
/// truncated between its digits still parses — as a much smaller number. Left
/// in, `JOIN 25` sliced out of `JOIN 25484` reads as the stream jumping
/// backwards, and `assert_consecutive` reports a replay the daemon never
/// performed. Dropping the final element removes it: after a trailing newline
/// that element is the empty string, and otherwise it is the partial line.
fn stream_lines(bytes: &[u8]) -> Vec<String> {
    let mut lines: Vec<String> = String::from_utf8_lossy(bytes)
        .replace('\r', "")
        .split('\n')
        .map(str::to_string)
        .collect();
    lines.pop();
    lines
}

/// The truncation that made this test call the daemon a liar: a counter cut
/// between its digits is a proper prefix of the line being written, so it
/// parses, and it is smaller than the counter before it.
#[test]
fn a_line_cut_mid_counter_is_not_a_counter() {
    let cut = b"JOIN 25482\r\nJOIN 25483\r\nJOIN 25";
    assert_eq!(
        stream_lines(cut),
        vec!["JOIN 25482".to_string(), "JOIN 25483".to_string()],
        "the partial line survived and would parse as counter 25"
    );

    let whole = b"JOIN 25482\r\nJOIN 25483\r\n";
    assert_eq!(
        stream_lines(whole),
        vec!["JOIN 25482".to_string(), "JOIN 25483".to_string()],
        "a stream ending on a line terminator lost a complete line"
    );

    let counters: Vec<u64> = stream_lines(cut)
        .iter()
        .filter_map(|line| parse_counter(line))
        .collect();
    assert_consecutive(&counters, "the fixture");
}

fn assert_consecutive(counters: &[u64], who: &str) {
    for pair in counters.windows(2) {
        assert_eq!(
            pair[1],
            pair[0] + 1,
            "{who} saw {} after {} — the byte stream {}",
            pair[1],
            pair[0],
            if pair[1] > pair[0] { "lost bytes" } else { "replayed bytes" }
        );
    }
}

#[test]
fn attaching_mid_flood_joins_the_stream_exactly_once() {
    let daemon = start_daemon("flood");

    // Unbroken output, so the late client always attaches with bytes in flight
    // and the host has something to buffer behind the snapshot. A paced flood
    // lets the attach land in a gap, where an empty buffer hides a broken
    // barrier. Bounded well under the 4 MiB per-client backlog.
    let flood = "i=0; while [ $i -lt 200000 ]; do i=$((i+1)); printf 'JOIN %d\\r\\n' $i; \
                 done; sleep 5";
    let created = Command::new(BIN)
        .args([
            "create",
            "--name",
            "joinsession",
            "--",
            "bash",
            "--norc",
            "-c",
            flood,
        ])
        .env("TERMIOD_SOCK", &daemon.socket)
        .output()
        .expect("create");
    assert!(created.status.success(), "create failed");

    // The early client never negotiates `snapshot`: it is the control for the
    // "no other client's delivery is affected" half of the invariant.
    let (mut early, mut to_early, mut from_early) = spawn_bridge(&daemon.socket);
    handshake(&mut to_early, &mut from_early, "joinsession", "", "join-early");
    let early_bytes = Arc::new(Mutex::new(Vec::new()));
    let early_sink = Arc::clone(&early_bytes);
    let early_reader = std::thread::spawn(move || {
        while let Some((kind, payload)) = read_frame(&mut from_early) {
            if kind == b'D' {
                early_sink.lock().expect("early sink").extend_from_slice(&payload);
            }
        }
    });

    std::thread::sleep(Duration::from_millis(300));

    let (mut late, mut to_late, mut from_late) = spawn_bridge(&daemon.socket);
    handshake(
        &mut to_late,
        &mut from_late,
        "joinsession",
        "\"snapshot\"",
        "join-late",
    );

    // Frames arrive on a channel so a regression that starves this client
    // fails the test instead of blocking it forever on a pipe read.
    let (frames_tx, frames) = mpsc::channel();
    let late_reader = std::thread::spawn(move || {
        while let Some(frame) = read_frame(&mut from_late) {
            if frames_tx.send(frame).is_err() {
                break;
            }
        }
    });

    let mut snapshot: Option<WireSnapshot> = None;
    let mut ready = false;
    let mut late_bytes: Vec<u8> = Vec::new();
    while let Ok((kind, payload)) = frames.recv_timeout(Duration::from_secs(15)) {
        match kind {
            b'S' => {
                assert!(snapshot.is_none(), "a second S arrived without a resize");
                assert!(late_bytes.is_empty(), "D arrived before the S snapshot");
                snapshot = Some(parse_snapshot(&payload));
            }
            b'E' if String::from_utf8_lossy(&payload).contains("\"ev\":\"ready\"") => {
                assert!(snapshot.is_some(), "ready arrived before the S snapshot");
                ready = true;
            }
            b'D' => {
                assert!(ready, "live D arrived before ready");
                late_bytes.extend_from_slice(&payload);
                if stream_lines(&late_bytes).len() > LINES_PAST_BOUNDARY {
                    break;
                }
            }
            _ => {}
        }
    }

    // The early client keeps reading: it is still the control for the second
    // half of the invariant, and where it has got to is judged below, once the
    // boundary is known.
    let _ = late.kill();
    drop(frames);
    let _ = late_reader.join();

    let snapshot = snapshot.expect("no S snapshot for the late client");
    assert_eq!(
        (snapshot.rows, snapshot.cols),
        (ROWS, COLS),
        "snapshot dimensions are not the authoritative PTY size"
    );

    // The boundary. Everything before it is on the screen the host described;
    // everything after it is in the bytes the host buffered for this client.
    let screen_high = snapshot.highest_counter();
    let fragment = snapshot.cursor_fragment();
    let lines = stream_lines(&late_bytes);
    assert!(
        lines.len() > LINES_PAST_BOUNDARY,
        "the late client never received enough live output to prove the join"
    );

    let completed = format!("{}{}", fragment.trim_end(), lines[0]);
    let (first_counter, rest) = if completed.trim().is_empty() {
        // The boundary fell inside the line terminator, so the cursor row
        // already holds the complete line and the stream opens with its tail.
        (
            parse_counter(&lines[1]).unwrap_or_else(|| {
                panic!("first line past the terminator is not a counter: {:?}", lines[1])
            }),
            &lines[2..],
        )
    } else {
        (
            parse_counter(&completed).unwrap_or_else(|| {
                panic!("the line spanning the boundary did not complete: {completed:?}")
            }),
            &lines[1..],
        )
    };

    assert_eq!(
        first_counter,
        screen_high + 1,
        "the snapshot ends at {screen_high} but the stream resumes at {first_counter} — \
         the S payload and the buffered bytes were taken at different boundaries"
    );

    let mut late_counters = vec![first_counter];
    late_counters.extend(rest.iter().filter_map(|line| parse_counter(line)));
    assert!(
        late_counters.len() > LINES_PAST_BOUNDARY / 2,
        "too few counters past the boundary to prove ordering: {}",
        late_counters.len()
    );
    assert_consecutive(&late_counters, "the late client");

    // The early client must be untouched by the barrier: attaching a second
    // client may not pause the PTY, drop bytes, or replay them.
    //
    // "Untouched" is about delivery, not about wall-clock position. This client
    // is reading the flood from its very first byte while the late one joined
    // 40k lines in, so on a slow or loaded machine it is legitimately behind at
    // any instant — comparing the two positions the moment the late client is
    // satisfied measures the reader, not the barrier. So drain until it passes
    // the boundary. A barrier that really blocked it never gets there, and the
    // deadline is what reports that.
    let deadline = Instant::now() + Duration::from_secs(30);
    let early_counters = loop {
        let seen = early_bytes.lock().expect("early bytes").clone();
        let counters: Vec<u64> = stream_lines(&seen)
            .iter()
            .filter_map(|line| parse_counter(line))
            .collect();
        if counters.last().is_some_and(|high| *high >= first_counter) {
            break counters;
        }
        assert!(
            Instant::now() < deadline,
            "the early client stalled at {:?} and never reached {first_counter}, where the \
             late client joined — the barrier blocked another client's delivery",
            counters.last()
        );
        std::thread::sleep(Duration::from_millis(50));
    };

    let _ = early.kill();
    let _ = early_reader.join();

    assert!(
        early_counters.len() > LINES_PAST_BOUNDARY,
        "the early client received too little output to judge: {}",
        early_counters.len()
    );
    // Ring replay can open the stream mid-line; only whole counters are judged.
    assert_consecutive(&early_counters[1..], "the early client");
}
