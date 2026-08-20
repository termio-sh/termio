//! §C.9 acceptance for the WSS binding: the browser's pipe is the *same*
//! protocol, not a dialect of it.
//!
//! `stdio_bridge.rs` proves it for `termiod stdio`. This file proves it for the
//! WebSocket, and adds the two things only a WebSocket can get wrong:
//!
//! - **Message boundaries are not frame boundaries.** One protocol frame is
//!   sent split across three binary messages, and two frames are sent packed
//!   into one. Both must reach the daemon intact, because that is the only
//!   reason a transcript recorded over the Unix socket replays here.
//! - **The token is never echoed.** The selected subprotocol is `termiod.v1`;
//!   `Sec-WebSocket-Protocol` lands in every proxy access log in front of us.
//!
//! The equality assertion is a real one: the same session, attached over the
//! Unix socket and over WSS, must produce a byte-identical `S` payload.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UnixStream};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::Message;

const BIN: &str = env!("CARGO_BIN_EXE_termiod");
const SETTLE: Duration = Duration::from_secs(10);

fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + payload.len());
    out.push(kind);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// Pull whole frames out of an accumulating byte buffer. This is the codec the
/// browser will run, and the reason it is here rather than in the assertions is
/// that a WebSocket message carries an arbitrary slice of the stream.
fn drain_frames(buffer: &mut Vec<u8>, into: &mut Vec<(u8, Vec<u8>)>) {
    loop {
        if buffer.len() < 5 {
            return;
        }
        let length =
            u32::from_be_bytes([buffer[1], buffer[2], buffer[3], buffer[4]]) as usize;
        if buffer.len() < 5 + length {
            return;
        }
        let kind = buffer[0];
        let payload = buffer[5..5 + length].to_vec();
        buffer.drain(..5 + length);
        into.push((kind, payload));
    }
}

fn free_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("probe port");
    let port = listener.local_addr().expect("probe addr").port();
    drop(listener);
    port
}

struct Daemon {
    child: Option<Child>,
    dir: PathBuf,
    socket: String,
    port: u16,
    token: String,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn state_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("termiod-wss-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("state dir");
    dir
}

fn pair(socket: &str) -> String {
    let output = Command::new(BIN)
        .arg("pair")
        .env("TERMIOD_SOCK", socket)
        .output()
        .expect("pair");
    assert!(output.status.success(), "pair failed: {output:?}");
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// A daemon with the web pipe armed: a pairing token, then `serve --wss` on a
/// loopback port nobody else has.
fn start_daemon(tag: &str) -> Daemon {
    let dir = state_dir(tag);
    let socket = dir.join("termiod.sock").to_string_lossy().into_owned();
    let token = pair(&socket);
    let port = free_port();

    let child = Command::new(BIN)
        .args(["serve", "--wss", &format!("127.0.0.1:{port}")])
        .env("TERMIOD_SOCK", &socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve --wss");

    let deadline = Instant::now() + Duration::from_secs(10);
    while !std::path::Path::new(&socket).exists() {
        assert!(Instant::now() < deadline, "daemon never bound the socket");
        std::thread::sleep(Duration::from_millis(30));
    }
    while std::net::TcpStream::connect(("127.0.0.1", port)).is_err() {
        assert!(Instant::now() < deadline, "daemon never bound the wss port");
        std::thread::sleep(Duration::from_millis(30));
    }

    Daemon {
        child: Some(child),
        dir,
        socket,
        port,
        token,
    }
}

/// A session whose screen is fixed after one line, so two attaches a second
/// apart see the same grid and the `S` payloads are comparable byte for byte.
///
/// Live `D` is produced on demand instead: `sleep` never reads stdin, so
/// anything injected with `termiod send` comes straight back off the tty's own
/// echo, after `ready`, without disturbing the settled screen first.
fn create_session(socket: &str, name: &str, alive_seconds: u32) {
    let created = Command::new(BIN)
        .args([
            "create",
            "--name",
            name,
            "--",
            "bash",
            "--norc",
            "-c",
            &format!("printf 'WSS_ACCEPTANCE_MARK\\r\\n'; sleep {alive_seconds}"),
        ])
        .env("TERMIOD_SOCK", socket)
        .output()
        .expect("create");
    assert!(created.status.success(), "create failed: {created:?}");
    // Let the marker land before anyone attaches, so the snapshot is settled.
    std::thread::sleep(Duration::from_millis(600));
}

fn send(socket: &str, name: &str, text: &str) {
    let sent = Command::new(BIN)
        .args(["send", name, text])
        .env("TERMIOD_SOCK", socket)
        .output()
        .expect("send");
    assert!(sent.status.success(), "send failed: {sent:?}");
}

fn hello() -> Vec<u8> {
    frame(
        b'C',
        br#"{"op":"hello","proto":1,"min_proto":1,"role":"attach","caps":["events","snapshot","scrollback"],"client":"termio-web/test"}"#,
    )
}

fn attach(name: &str) -> Vec<u8> {
    frame(
        b'C',
        format!(r#"{{"op":"attach","target":"{name}","rows":24,"cols":80,"mode":"observe"}}"#)
            .as_bytes(),
    )
}

fn contains(payload: &[u8], needle: &str) -> bool {
    String::from_utf8_lossy(payload).contains(needle)
}

/// `Event::Ready` is what ends the attach barrier — not the first `D`. The
/// transcript is complete there, on both pipes, by definition.
fn transcript_is_complete(frames: &[(u8, Vec<u8>)]) -> bool {
    frames
        .iter()
        .any(|(kind, payload)| *kind == b'E' && contains(payload, "\"ev\":\"ready\""))
}

async fn unix_transcript(socket: &str, name: &str) -> Vec<(u8, Vec<u8>)> {
    let mut stream = UnixStream::connect(socket).await.expect("unix connect");
    stream.write_all(&hello()).await.expect("hello");
    stream.write_all(&attach(name)).await.expect("attach");

    let mut buffer = Vec::new();
    let mut frames = Vec::new();
    let mut chunk = vec![0u8; 64 * 1024];
    let deadline = tokio::time::Instant::now() + SETTLE;
    while !transcript_is_complete(&frames) {
        let read = tokio::time::timeout_at(deadline, stream.read(&mut chunk))
            .await
            .expect("unix transcript timed out")
            .expect("unix read");
        assert!(read > 0, "daemon closed the unix socket early");
        buffer.extend_from_slice(&chunk[..read]);
        drain_frames(&mut buffer, &mut frames);
    }
    frames
}

async fn open_socket(
    daemon: &Daemon,
    path: &str,
) -> (
    tokio_tungstenite::WebSocketStream<TcpStream>,
    tokio_tungstenite::tungstenite::handshake::client::Response,
) {
    let mut request = format!("ws://127.0.0.1:{}{path}", daemon.port)
        .into_client_request()
        .expect("request");
    request.headers_mut().insert(
        "origin",
        format!("http://127.0.0.1:{}", daemon.port)
            .parse()
            .expect("origin"),
    );
    request.headers_mut().insert(
        "sec-websocket-protocol",
        format!("termiod.v1, termiod.token.{}", daemon.token)
            .parse()
            .expect("subprotocol"),
    );
    let tcp = TcpStream::connect(("127.0.0.1", daemon.port))
        .await
        .expect("tcp connect");
    tokio_tungstenite::client_async(request, tcp)
        .await
        .expect("websocket handshake")
}

/// Read binary messages, reassemble frames, and stop when `until` says so. The
/// leftover buffer is kept: a message may end mid-frame, which is the whole
/// point.
async fn wss_frames_until(
    websocket: &mut tokio_tungstenite::WebSocketStream<TcpStream>,
    buffer: &mut Vec<u8>,
    until: impl Fn(&[(u8, Vec<u8>)]) -> bool,
) -> Vec<(u8, Vec<u8>)> {
    let mut frames = Vec::new();
    let deadline = tokio::time::Instant::now() + SETTLE;
    while !until(&frames) {
        let message = tokio::time::timeout_at(deadline, websocket.next())
            .await
            .expect("wss transcript timed out")
            .expect("websocket closed early")
            .expect("websocket error");
        match message {
            Message::Binary(bytes) => {
                buffer.extend_from_slice(&bytes);
                drain_frames(buffer, &mut frames);
            }
            Message::Ping(_) | Message::Pong(_) => {}
            other => panic!("unexpected message from the host: {other:?}"),
        }
    }
    frames
}

async fn wss_frames(
    websocket: &mut tokio_tungstenite::WebSocketStream<TcpStream>,
) -> Vec<(u8, Vec<u8>)> {
    let mut buffer = Vec::new();
    wss_frames_until(websocket, &mut buffer, transcript_is_complete).await
}

#[tokio::test]
async fn framed_protocol_is_byte_identical_over_the_wss_binding() {
    let daemon = start_daemon("replay");
    create_session(&daemon.socket, "wsssession", 30);

    let over_unix = unix_transcript(&daemon.socket, "wsssession").await;

    let (mut websocket, response) = open_socket(&daemon, "/ws").await;
    assert_eq!(
        response
            .headers()
            .get("sec-websocket-protocol")
            .map(|value| value.to_str().unwrap_or_default()),
        Some("termiod.v1"),
        "the selected subprotocol must be the version, never the token"
    );

    // One frame, three messages. If the host treated a message as a frame this
    // is where the whole design would fall over.
    let hello = hello();
    for slice in [&hello[..2], &hello[2..7], &hello[7..]] {
        websocket
            .send(Message::Binary(slice.to_vec().into()))
            .await
            .expect("send hello slice");
    }
    websocket
        .send(Message::Binary(attach("wsssession").into()))
        .await
        .expect("send attach");

    let mut leftover = Vec::new();
    let over_wss =
        wss_frames_until(&mut websocket, &mut leftover, transcript_is_complete).await;

    // The attach sequence, in order. Roster and status events are published on
    // their own schedule and may or may not land inside a given window, so they
    // are not part of what the two pipes have to agree on.
    let sequence = |frames: &[(u8, Vec<u8>)]| -> String {
        frames
            .iter()
            .filter(|(kind, payload)| *kind != b'E' || contains(payload, "\"ev\":\"ready\""))
            .map(|(kind, _)| *kind as char)
            .collect()
    };
    assert_eq!(
        sequence(&over_unix),
        sequence(&over_wss),
        "the two pipes produced different frame sequences"
    );
    assert_eq!(sequence(&over_wss), "CCSE", "hello_ok, attached, S, ready");

    let snapshot = |frames: &[(u8, Vec<u8>)]| {
        frames
            .iter()
            .find(|(kind, _)| *kind == b'S')
            .map(|(_, payload)| payload.clone())
            .expect("no S frame")
    };
    assert_eq!(
        snapshot(&over_unix),
        snapshot(&over_wss),
        "the same session produced different snapshots on the two pipes"
    );

    assert!(over_wss.iter().any(|(kind, payload)| *kind == b'C'
        && contains(payload, "\"op\":\"hello_ok\"")));
    assert!(over_wss.iter().any(|(kind, payload)| *kind == b'C'
        && contains(payload, "\"op\":\"attached\"")));

    // Live D after the barrier: the tty echoes what `send` injects, so bytes
    // travel PTY → daemon → splice → browser with nothing in between parsing
    // them.
    send(&daemon.socket, "wsssession", "LIVE_D_MARK");
    let live = wss_frames_until(&mut websocket, &mut leftover, |frames| {
        frames
            .iter()
            .any(|(kind, payload)| *kind == b'D' && contains(payload, "LIVE_D_MARK"))
    })
    .await;
    assert!(live.iter().any(|(kind, _)| *kind == b'D'));
}

/// Tailscale Serve publishes `/termio` rather than stripping it, so the same
/// build has to work at both mounts — and two frames packed into one message
/// must arrive as two frames.
#[tokio::test]
async fn the_mount_prefix_and_a_packed_message_reach_the_same_daemon() {
    let daemon = start_daemon("mount");
    create_session(&daemon.socket, "mountsession", 30);

    let (mut websocket, _response) = open_socket(&daemon, "/termio/ws").await;
    let mut packed = hello();
    packed.extend_from_slice(&attach("mountsession"));
    websocket
        .send(Message::Binary(packed.into()))
        .await
        .expect("send packed frames");

    let frames = wss_frames(&mut websocket).await;
    assert!(frames
        .iter()
        .any(|(kind, payload)| *kind == b'C' && contains(payload, "\"op\":\"hello_ok\"")));
    assert!(frames
        .iter()
        .any(|(kind, payload)| *kind == b'C' && contains(payload, "\"op\":\"attached\"")));
    assert!(frames.iter().any(|(kind, _)| *kind == b'S'));
}

/// 300 KB in one breath: several `D` frames, many 64 KiB socket reads, and no
/// alignment between the two. If the splice ever re-chunked on frame boundaries
/// — or lost a byte at a message edge — this is where it would show.
#[tokio::test]
async fn a_burst_larger_than_one_chunk_stays_framed() {
    let daemon = start_daemon("burst");
    let created = Command::new(BIN)
        .args(["create", "--name", "burstsession", "--", "bash", "--norc", "-i"])
        .env("TERMIOD_SOCK", &daemon.socket)
        .output()
        .expect("create");
    assert!(created.status.success(), "create failed: {created:?}");
    std::thread::sleep(Duration::from_millis(600));

    let (mut websocket, _response) = open_socket(&daemon, "/ws").await;
    let mut packed = hello();
    packed.extend_from_slice(&attach("burstsession"));
    websocket
        .send(Message::Binary(packed.into()))
        .await
        .expect("send");
    let mut leftover = Vec::new();
    wss_frames_until(&mut websocket, &mut leftover, transcript_is_complete).await;

    // The quotes keep the sentinel out of the tty's echo of the command line,
    // so the wait below ends on the burst's tail and not on its own request.
    send(
        &daemon.socket,
        "burstsession",
        "head -c 300000 /dev/zero | tr '\\0' x; echo BURST\"_\"END",
    );
    let frames = wss_frames_until(&mut websocket, &mut leftover, |frames| {
        frames
            .iter()
            .any(|(kind, payload)| *kind == b'D' && contains(payload, "BURST_END"))
    })
    .await;

    let data: Vec<&(u8, Vec<u8>)> = frames.iter().filter(|(kind, _)| *kind == b'D').collect();
    let total: usize = data.iter().map(|(_, payload)| payload.len()).sum();
    assert!(total >= 300_000, "only {total} bytes of the burst arrived");
    assert!(data.len() > 1, "a 300 KB burst is more than one D frame");
    for (_, payload) in &data {
        assert!(
            payload.len() <= 64 * 1024,
            "a D frame exceeded MAX_DATA_FRAME_SIZE: {}",
            payload.len()
        );
    }
}

/// A text message means someone is speaking a dialect. Close, do not guess.
#[tokio::test]
async fn a_text_message_is_a_protocol_error() {
    let daemon = start_daemon("text");

    let (mut websocket, _response) = open_socket(&daemon, "/ws").await;
    websocket
        .send(Message::Text("{\"op\":\"hello\"}".into()))
        .await
        .expect("send text");

    let deadline = tokio::time::Instant::now() + SETTLE;
    loop {
        let message = tokio::time::timeout_at(deadline, websocket.next())
            .await
            .expect("no close after a text message");
        match message {
            Some(Ok(Message::Close(frame))) => {
                assert_eq!(
                    frame.map(|frame| frame.code),
                    Some(CloseCode::Unsupported),
                    "a text message must close 1003"
                );
                return;
            }
            Some(Ok(_)) => continue,
            Some(Err(_)) | None => return, // an abrupt close is the same verdict
        }
    }
}

/// Rule 3 of the durable-start contract: an operator asking for a listener that
/// cannot authenticate gets no listener, no `wss.bind`, and a non-zero exit.
#[test]
fn explicit_wss_without_a_token_refuses_to_start() {
    let dir = state_dir("notoken");
    let socket = dir.join("termiod.sock");
    let port = free_port();

    let output = Command::new(BIN)
        .args(["serve", "--wss", &format!("127.0.0.1:{port}")])
        .env("TERMIOD_SOCK", &socket)
        .output()
        .expect("serve");

    assert!(!output.status.success(), "serve should have refused to start");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("termiod pair"),
        "the error must name the fix, got: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!dir.join("wss.bind").exists(), "wss.bind must not be written");
    assert!(!socket.exists(), "the whole start is refused, socket included");

    let _ = std::fs::remove_dir_all(&dir);
}

/// Rule 4: a *remembered* bind without a token is a restart of something that
/// used to work. Skip TCP, keep the Unix socket — `spawn_daemon` must not take
/// down the Mac and the CLI because a token went missing.
#[test]
fn an_inherited_bind_without_a_token_still_serves_unix() {
    let dir = state_dir("inherited");
    let socket = dir.join("termiod.sock");
    let port = free_port();
    std::fs::write(dir.join("wss.bind"), format!("127.0.0.1:{port}")).expect("wss.bind");

    let mut child = Command::new(BIN)
        .arg("serve")
        .env("TERMIOD_SOCK", &socket)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn serve");

    let deadline = Instant::now() + Duration::from_secs(10);
    while !socket.exists() {
        assert!(Instant::now() < deadline, "unix socket never appeared");
        std::thread::sleep(Duration::from_millis(30));
    }
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        std::net::TcpStream::connect(("127.0.0.1", port)).is_err(),
        "TCP must stay closed without a pairing token"
    );

    let listed = Command::new(BIN)
        .args(["list", "--json"])
        .env("TERMIOD_SOCK", &socket)
        .output()
        .expect("list");
    assert!(listed.status.success(), "the unix socket must still answer");

    let _ = child.kill();
    let mut stderr = String::new();
    if let Some(mut pipe) = child.stderr.take() {
        let _ = pipe.read_to_string(&mut stderr);
    }
    let _ = child.wait();
    assert!(
        stderr.contains("wss skipped: no pair.token"),
        "the skip must be visible on stderr, got: {stderr}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// `pair` mints once and then prints the same secret; `--rotate` replaces it and
/// `--wss-off` forgets the bind. All three at 0600, beside the socket.
#[test]
fn pair_mints_rotates_and_turns_the_bind_off() {
    let dir = state_dir("pair");
    let socket = dir.join("termiod.sock").to_string_lossy().into_owned();

    let first = pair(&socket);
    assert_eq!(first.len(), 32);
    assert_eq!(first, pair(&socket), "pair prints, it does not re-mint");

    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(dir.join("pair.token"))
        .expect("token file")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600, "the token is a credential");

    let rotated = Command::new(BIN)
        .args(["pair", "--rotate"])
        .env("TERMIOD_SOCK", &socket)
        .output()
        .expect("rotate");
    assert!(rotated.status.success());
    let second = String::from_utf8_lossy(&rotated.stdout).trim().to_string();
    assert_ne!(first, second, "--rotate must replace the token");

    std::fs::write(dir.join("wss.bind"), "127.0.0.1:8790").expect("wss.bind");
    let off = Command::new(BIN)
        .args(["pair", "--wss-off"])
        .env("TERMIOD_SOCK", &socket)
        .output()
        .expect("wss-off");
    assert!(off.status.success());
    assert!(!dir.join("wss.bind").exists(), "--wss-off forgets the bind");

    let _ = std::fs::remove_dir_all(&dir);
}

/// Rotating the token drops live splices. Detach, not kill: the session is
/// still there afterwards.
#[tokio::test]
async fn rotating_the_token_drops_a_live_splice() {
    let daemon = start_daemon("rotate");
    create_session(&daemon.socket, "rotatesession", 30);

    let (mut websocket, _response) = open_socket(&daemon, "/ws").await;
    let mut packed = hello();
    packed.extend_from_slice(&attach("rotatesession"));
    websocket
        .send(Message::Binary(packed.into()))
        .await
        .expect("send");
    let frames = wss_frames(&mut websocket).await;
    assert!(frames.iter().any(|(kind, _)| *kind == b'S'));

    let rotated = Command::new(BIN)
        .args(["pair", "--rotate"])
        .env("TERMIOD_SOCK", &daemon.socket)
        .output()
        .expect("rotate");
    assert!(rotated.status.success());

    let deadline = tokio::time::Instant::now() + SETTLE;
    let mut closed = false;
    while !closed {
        let message = tokio::time::timeout_at(deadline, websocket.next())
            .await
            .expect("the splice outlived the token");
        match message {
            Some(Ok(Message::Close(_))) | Some(Err(_)) | None => closed = true,
            Some(Ok(_)) => {}
        }
    }

    // The session survives its viewer.
    let listed = Command::new(BIN)
        .args(["list", "--json"])
        .env("TERMIOD_SOCK", &daemon.socket)
        .output()
        .expect("list");
    assert!(
        String::from_utf8_lossy(&listed.stdout).contains("rotatesession"),
        "rotate is a detach, not a kill"
    );
}

/// A quiet shell produces no `D` for hours and both Tailscale Serve and Caddy
/// idle-timeout upstreams, so the transport ping is what keeps a left-open tab
/// a live attachment — and an unanswered one is a detach, never a kill.
///
/// Ignored by default: two 30-second ticks is a minute of wall clock, which
/// does not belong in the default run. Run it with
/// `cargo test --test wss_bridge -- --ignored`.
#[test]
#[ignore]
fn an_unanswered_ping_detaches_the_splice() {
    let daemon = start_daemon("ping");
    // Outlives two ping ticks, so "the session survived" is a real assertion.
    create_session(&daemon.socket, "pingsession", 120);

    // A hand-rolled client, because every WebSocket library answers a ping for
    // you and the point here is to not answer one.
    let mut stream =
        std::net::TcpStream::connect(("127.0.0.1", daemon.port)).expect("connect");
    let request = format!(
        "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n\
         Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
         Sec-WebSocket-Version: 13\r\nOrigin: http://127.0.0.1:{port}\r\n\
         Sec-WebSocket-Protocol: termiod.v1, termiod.token.{token}\r\n\r\n",
        port = daemon.port,
        token = daemon.token
    );
    stream.write_all(request.as_bytes()).expect("upgrade");

    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        assert_eq!(stream.read(&mut byte).expect("head"), 1, "closed mid-head");
        head.push(byte[0]);
    }
    let head = String::from_utf8_lossy(&head).into_owned();
    assert!(head.starts_with("HTTP/1.1 101"), "{head}");
    assert!(
        head.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
        "{head}"
    );
    assert!(head.contains("Sec-WebSocket-Protocol: termiod.v1"), "{head}");
    assert!(!head.contains(&daemon.token), "the token must not be echoed");

    stream
        .set_read_timeout(Some(Duration::from_secs(100)))
        .expect("timeout");
    let mut read_exact = |buffer: &mut [u8]| stream.read_exact(buffer).is_ok();

    let (mut pings, mut closed) = (0, false);
    let started = Instant::now();
    while !closed {
        let mut header = [0u8; 2];
        if !read_exact(&mut header) {
            break; // the host hung up without a close frame; still a detach
        }
        let length = usize::from(header[1] & 0x7f);
        let length = match length {
            126 => {
                let mut extended = [0u8; 2];
                assert!(read_exact(&mut extended));
                usize::from(u16::from_be_bytes(extended))
            }
            127 => {
                let mut extended = [0u8; 8];
                assert!(read_exact(&mut extended));
                u64::from_be_bytes(extended) as usize
            }
            short => short,
        };
        let mut payload = vec![0u8; length];
        assert!(read_exact(&mut payload));
        match header[0] & 0x0f {
            0x9 => pings += 1,
            0x8 => closed = true,
            _ => {}
        }
    }

    assert!(pings >= 1, "the host never pinged a quiet splice");
    let elapsed = started.elapsed();
    assert!(
        elapsed >= Duration::from_secs(45),
        "detached after {elapsed:?} — that is not two 30s ticks"
    );

    let listed = Command::new(BIN)
        .args(["list", "--json"])
        .env("TERMIOD_SOCK", &daemon.socket)
        .output()
        .expect("list");
    assert!(
        String::from_utf8_lossy(&listed.stdout).contains("pingsession"),
        "a missing pong is a detach, not a kill"
    );
}

/// The web root is a jail, and the Wasm has to arrive as `application/wasm` or
/// `instantiateStreaming` fails with an error that reads like a build problem.
#[test]
fn the_web_root_serves_index_at_both_mounts() {
    let dir = state_dir("webroot");
    let socket = dir.join("termiod.sock").to_string_lossy().into_owned();
    let root = dir.join("web");
    std::fs::create_dir_all(&root).expect("web root");
    std::fs::write(root.join("index.html"), b"<!doctype html>termio").expect("index");
    std::fs::write(root.join("ghostty-vt.wasm"), b"\0asm").expect("wasm");
    let token = pair(&socket);
    let port = free_port();

    let mut child = Command::new(BIN)
        .args([
            "serve",
            "--wss",
            &format!("127.0.0.1:{port}"),
            "--web-root",
            &root.to_string_lossy(),
        ])
        .env("TERMIOD_SOCK", &socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn serve");

    let deadline = Instant::now() + Duration::from_secs(10);
    while std::net::TcpStream::connect(("127.0.0.1", port)).is_err() {
        assert!(Instant::now() < deadline, "wss port never came up");
        std::thread::sleep(Duration::from_millis(30));
    }
    assert!(!token.is_empty());

    let get = |path: &str| -> String {
        let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        stream
            .write_all(
                format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n")
                    .as_bytes(),
            )
            .expect("request");
        let mut response = Vec::new();
        stream.read_to_end(&mut response).expect("response");
        String::from_utf8_lossy(&response).into_owned()
    };

    for path in ["/", "/termio/"] {
        let response = get(path);
        assert!(response.starts_with("HTTP/1.1 200 OK"), "{path}: {response}");
        assert!(response.contains("termio"), "{path} did not serve index.html");
    }
    for path in ["/ghostty-vt.wasm", "/termio/ghostty-vt.wasm"] {
        assert!(
            get(path).contains("Content-Type: application/wasm"),
            "{path} must carry the Wasm MIME type"
        );
    }
    assert!(
        get("/termio").starts_with("HTTP/1.1 302"),
        "/termio redirects to /termio/ so relative assets resolve"
    );
    assert!(get("/../../etc/passwd").starts_with("HTTP/1.1 404"));

    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
