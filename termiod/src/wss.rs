//! The opt-in loopback WebSocket listener, and the pairing token that guards it.
//!
//! A phone or a browser cannot open a Unix socket, so this is the one place
//! `termiod` accepts TCP. Three rules keep it from becoming a second product:
//!
//! - **Loopback only.** TLS lives in Tailscale Serve or Caddy in front; termiod
//!   never grows a TLS stack, ships a CA, or pins a certificate.
//! - **It is a splice, not a second protocol.** After the Upgrade this copies
//!   bytes onto a connected `UnixStream` the way `termio stdio` does. One
//!   WebSocket message is *not* one protocol frame, or a recorded Unix-socket
//!   transcript would no longer replay.
//! - **The pairing token authenticates the pipe**, and is never the session
//!   write token that arbitrates who may type into a PTY.
//!
//! Specified by `docs/design/20260818-termiod-web-client-ghostty-wasm.md`.

use crate::paths;
use anyhow::{bail, Context, Result};
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, UnixStream};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::{HeaderValue, StatusCode};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

/// Not the companion ports (8787 release, 8788 dev): a box running both must
/// not have them fight.
pub const DEFAULT_PORT: u16 = 8790;

const SUBPROTOCOL_PREFIX: &str = "termiod.";
/// Quiet shells emit nothing for long stretches and every proxy in front of us
/// idles out an upstream. Transport pings are how an attached tab stays live.
const PING_INTERVAL: Duration = Duration::from_secs(30);
/// A socket that connects and then says nothing must not pin a task forever.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const SPLICE_CHUNK: usize = 64 * 1024;

// ---------------------------------------------------------------------------
// Bind address
// ---------------------------------------------------------------------------

/// Parse a `--wss` value and refuse anything that is not loopback.
///
/// Stronger than "refuse `0.0.0.0`": a name is resolved and every address it
/// resolves to has to be loopback, because the operator's intent is the
/// listener's reachability, not the string they typed.
pub fn parse_bind(raw: &str) -> std::result::Result<SocketAddr, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("expected an address like 127.0.0.1:8790".to_string());
    }
    let candidates = resolve_candidates(raw)?;
    if let Some(off_loopback) = candidates.iter().find(|addr| !addr.ip().is_loopback()) {
        return Err(format!(
            "{raw} is not loopback ({} is reachable from the network). \
             termiod binds 127.0.0.0/8 or ::1 only; terminate TLS in front of it \
             with Tailscale Serve or Caddy.",
            off_loopback.ip()
        ));
    }
    candidates
        .into_iter()
        .next()
        .ok_or_else(|| format!("{raw} resolves to no address"))
}

fn resolve_candidates(raw: &str) -> std::result::Result<Vec<SocketAddr>, String> {
    if let Ok(addr) = raw.parse::<SocketAddr>() {
        return Ok(vec![addr]);
    }
    let bare = raw.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = bare.parse::<IpAddr>() {
        return Ok(vec![SocketAddr::new(ip, DEFAULT_PORT)]);
    }
    let with_port = if raw.matches(':').count() == 1
        && raw
            .rsplit(':')
            .next()
            .is_some_and(|port| port.parse::<u16>().is_ok())
    {
        raw.to_string()
    } else {
        format!("{raw}:{DEFAULT_PORT}")
    };
    with_port
        .to_socket_addrs()
        .map(|addrs| addrs.collect())
        .map_err(|error| format!("cannot resolve {raw}: {error}"))
}

// ---------------------------------------------------------------------------
// Origin allowlist
// ---------------------------------------------------------------------------

/// A scheme + host + port authority, with the scheme's default port filled in
/// so `https://box` and `https://box:443` are one entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Origin {
    scheme: String,
    host: String,
    port: u16,
}

impl std::fmt::Display for Origin {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}://{}:{}", self.scheme, self.host, self.port)
    }
}

impl Origin {
    /// The `url` an invite carries when only the allowed origin is known.
    pub fn base_url(&self) -> String {
        let default_port = default_port_for(&self.scheme) == Some(self.port);
        if default_port {
            format!("{}://{}/", self.scheme, self.host)
        } else {
            format!("{}://{}:{}/", self.scheme, self.host, self.port)
        }
    }
}

fn default_port_for(scheme: &str) -> Option<u16> {
    match scheme {
        "http" | "ws" => Some(80),
        "https" | "wss" => Some(443),
        _ => None,
    }
}

/// Parse a `--wss-origin` value or an `Origin` header.
pub fn parse_origin(raw: &str) -> std::result::Result<Origin, String> {
    let raw = raw.trim().trim_end_matches('/');
    let Some((scheme, rest)) = raw.split_once("://") else {
        return Err(format!("{raw} is not an origin (expected scheme://host)"));
    };
    let scheme = scheme.to_ascii_lowercase();
    let Some(default_port) = default_port_for(&scheme) else {
        return Err(format!(
            "{raw}: only http, https, ws and wss origins are allowed"
        ));
    };
    if rest.contains('/') {
        return Err(format!("{raw}: an origin has no path"));
    }
    let (host, port) = split_authority(rest)?;
    if host.is_empty() {
        return Err(format!("{raw}: missing host"));
    }
    Ok(Origin {
        scheme,
        host,
        port: port.unwrap_or(default_port),
    })
}

/// Split `host`, `host:port`, `[v6]` or `[v6]:port` into its parts.
fn split_authority(raw: &str) -> std::result::Result<(String, Option<u16>), String> {
    if let Some(rest) = raw.strip_prefix('[') {
        let Some((host, tail)) = rest.split_once(']') else {
            return Err(format!("{raw}: unterminated IPv6 literal"));
        };
        let port = match tail.strip_prefix(':') {
            Some(port) => Some(
                port.parse::<u16>()
                    .map_err(|_| format!("{raw}: invalid port"))?,
            ),
            None if tail.is_empty() => None,
            None => return Err(format!("{raw}: trailing junk after the IPv6 literal")),
        };
        return Ok((host.to_ascii_lowercase(), port));
    }
    match raw.rsplit_once(':') {
        Some((host, port)) => Ok((
            host.to_ascii_lowercase(),
            Some(
                port.parse::<u16>()
                    .map_err(|_| format!("{raw}: invalid port"))?,
            ),
        )),
        None => Ok((raw.to_ascii_lowercase(), None)),
    }
}

fn is_loopback_host(host: &str) -> bool {
    host == "localhost" || host.parse::<IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

/// The CSRF control from §"Auth". It constrains *pages*; the token is what
/// authenticates the pipe. There is deliberately no "looks native" exemption —
/// anything a phone can send, a page can send.
pub fn origin_allowed(origin: Option<&str>, host: Option<&str>, allowed: &[Origin]) -> bool {
    let Some(raw) = origin else { return false };
    let raw = raw.trim();
    if raw.is_empty() || raw.eq_ignore_ascii_case("null") {
        return false;
    }
    let Ok(origin) = parse_origin(raw) else {
        return false;
    };

    if !allowed.is_empty() {
        return allowed.iter().any(|entry| entry == &origin);
    }

    // Default same-origin. The listener only ever speaks plain HTTP, so a Host
    // without a port is port 80.
    let Some(host) = host else { return false };
    let Ok((host_name, host_port)) = split_authority(host.trim()) else {
        return false;
    };
    let host_port = host_port.unwrap_or(80);
    if is_loopback_host(&host_name) && !is_loopback_host(&origin.host) {
        return false;
    }
    host_name == origin.host && host_port == origin.port
}

// ---------------------------------------------------------------------------
// Durable start
// ---------------------------------------------------------------------------

/// What `serve()` needs to bring the listener up.
pub struct Listener {
    pub addr: SocketAddr,
    pub origins: Vec<Origin>,
    /// Whether the bind came from this process's own argv. An operator who
    /// typed `--wss` gets a hard failure; an inherited bind must never take
    /// down `handle_conn`.
    explicit: bool,
}

fn read_trimmed(path: &std::path::Path) -> Result<Option<String>> {
    match std::fs::read_to_string(path) {
        Ok(contents) => {
            let value = contents.trim().to_string();
            Ok((!value.is_empty()).then_some(value))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

fn env_value(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// Resolve the bind, the origins and the token into a listener, or `None` for
/// "Unix socket only". Config outranks the flag because a flag that lives only
/// on one foreground argv dies on the next crash restart: `spawn_daemon` execs
/// bare `termiod serve`, and so does the systemd unit.
pub fn resolve(
    explicit_bind: Option<SocketAddr>,
    explicit_origins: &[Origin],
) -> Result<Option<Listener>> {
    let bind_file = paths::wss_bind_path()?;
    let (addr, explicit) = match explicit_bind {
        Some(addr) => (Some(addr), true),
        None => match env_value("TERMIOD_WSS") {
            // The env overrides the file for one process — tests, a one-shot.
            Some(raw) => (inherited_bind(&raw, "TERMIOD_WSS"), false),
            None => match read_trimmed(&bind_file)? {
                Some(raw) => (
                    inherited_bind(&raw, &bind_file.display().to_string()),
                    false,
                ),
                None => (None, false),
            },
        },
    };
    let Some(addr) = addr else {
        return Ok(None);
    };

    let env_origins = env_value("TERMIOD_WSS_ORIGIN");
    let (origins, origins_given) = if !explicit_origins.is_empty() {
        (explicit_origins.to_vec(), true)
    } else if let Some(raw) = env_origins.as_deref() {
        (parse_origin_list(raw, "TERMIOD_WSS_ORIGIN"), true)
    } else {
        let path = paths::wss_origin_path()?;
        match read_trimmed(&path)? {
            Some(raw) => (parse_origin_list(&raw, &path.display().to_string()), false),
            None => (Vec::new(), false),
        }
    };

    if paths::read_pair_token()?.is_none() {
        if explicit {
            bail!(
                "--wss {addr} has no pairing token to authenticate with — run `termio pair` first.\n\
                 Nothing was written; the daemon did not start."
            );
        }
        eprintln!("termiod: wss skipped: no pair.token");
        return Ok(None);
    }

    if explicit {
        paths::replace_secret(&bind_file, &addr.to_string())?;
        if origins_given {
            let joined = origins
                .iter()
                .map(Origin::to_string)
                .collect::<Vec<_>>()
                .join(",");
            paths::replace_secret(&paths::wss_origin_path()?, &joined)?;
        }
    }

    Ok(Some(Listener {
        addr,
        origins,
        explicit,
    }))
}

fn inherited_bind(raw: &str, source: &str) -> Option<SocketAddr> {
    match parse_bind(raw) {
        Ok(addr) => Some(addr),
        Err(reason) => {
            eprintln!("termiod: wss skipped: {source}: {reason}");
            None
        }
    }
}

fn parse_origin_list(raw: &str, source: &str) -> Vec<Origin> {
    raw.split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .filter_map(|entry| match parse_origin(entry) {
            Ok(origin) => Some(origin),
            Err(reason) => {
                eprintln!("termiod: ignoring origin from {source}: {reason}");
                None
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------
// The listener
// ---------------------------------------------------------------------------

/// Bind the TCP listener and hand the accept loop to the runtime.
///
/// An explicit `--wss` that cannot bind fails the whole start, because the
/// operator asked for it in this process's argv. An inherited one logs and
/// leaves the Unix socket serving.
pub async fn start(config: Listener, shutdown: watch::Receiver<bool>) -> Result<()> {
    let tcp = match TcpListener::bind(config.addr).await {
        Ok(tcp) => tcp,
        Err(error) if !config.explicit => {
            eprintln!("termiod: wss skipped: binding {}: {error}", config.addr);
            return Ok(());
        }
        Err(error) => {
            return Err(error).with_context(|| format!("binding {}", config.addr));
        }
    };
    if config.origins.is_empty() {
        eprintln!(
            "termiod: wss listening on ws://{}/ws (same-origin only — a TLS \
             terminator in front needs --wss-origin)",
            config.addr
        );
    } else {
        let list = config
            .origins
            .iter()
            .map(Origin::to_string)
            .collect::<Vec<_>>()
            .join(", ");
        eprintln!(
            "termiod: wss listening on ws://{}/ws (origins: {list})",
            config.addr
        );
    }
    tokio::spawn(accept_loop(tcp, config.origins, shutdown));
    Ok(())
}

async fn accept_loop(tcp: TcpListener, origins: Vec<Origin>, mut shutdown: watch::Receiver<bool>) {
    let origins = Arc::new(origins);
    let rotation = start_rotation_watch();
    loop {
        let accepted = tokio::select! {
            biased;
            _ = shutdown.changed() => return,
            accepted = tcp.accept() => accepted,
        };
        match accepted {
            Ok((stream, peer)) => {
                let policy = OriginPolicy::Listed(origins.clone());
                let shutdown = shutdown.clone();
                let rotation = rotation.subscribe();
                // Keystrokes are one-byte writes; Nagle would batch them into lag.
                let _ = stream.set_nodelay(true);
                tokio::spawn(async move {
                    if let Err(error) = serve_connection(stream, policy, shutdown, rotation).await
                    {
                        eprintln!("termiod: wss {peer}: {error:#}");
                    }
                });
            }
            // A per-connection accept error (fd exhaustion, a peer that reset
            // between SYN and accept) is not a reason to stop listening.
            Err(error) => {
                eprintln!("termiod: wss accept: {error}");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

/// Which pages may open the socket. A loopback listener checks its allowlist,
/// or same-origin against a loopback Host. A connection the tailnet helper
/// forwards was already admitted by Tailscale identity, and arrives on the
/// node's own name at 443 or 8790, so its rule is that the Origin names the
/// host the caller dialed.
pub(crate) enum OriginPolicy {
    Listed(Arc<Vec<Origin>>),
    SameHostName,
}

impl OriginPolicy {
    fn allows(&self, origin: Option<&str>, host: Option<&str>) -> bool {
        match self {
            OriginPolicy::Listed(origins) => origin_allowed(origin, host, origins),
            OriginPolicy::SameHostName => origin_names_host(origin, host),
        }
    }
}

/// The tailnet rule: the Origin's host is the Host header's host, and neither
/// is loopback. The port is not compared, because the helper hands over
/// connections from two ports and the Host header omits the default one.
pub fn origin_names_host(origin: Option<&str>, host: Option<&str>) -> bool {
    let Some(raw) = origin.map(str::trim) else {
        return false;
    };
    if raw.is_empty() || raw.eq_ignore_ascii_case("null") {
        return false;
    }
    let Ok(origin) = parse_origin(raw) else {
        return false;
    };
    let Some(host) = host else { return false };
    let Ok((host_name, _)) = split_authority(host.trim()) else {
        return false;
    };
    !is_loopback_host(&host_name) && host_name == origin.host
}

pub(crate) async fn serve_connection<S>(
    stream: S,
    policy: OriginPolicy,
    shutdown: watch::Receiver<bool>,
    rotation: watch::Receiver<u64>,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    // Disk is the source of truth for the secret, re-read per handshake, so a
    // rotation takes effect on the next Upgrade even if the watcher is down.
    let expected = paths::read_pair_token()?;
    let refusal: Arc<Mutex<Option<&'static str>>> = Arc::new(Mutex::new(None));

    let config = WebSocketConfig::default()
        .max_message_size(Some(crate::protocol::MAX_FRAME_SIZE))
        .max_frame_size(Some(crate::protocol::MAX_FRAME_SIZE));

    let callback_refusal = refusal.clone();
    let handshake = tokio_tungstenite::accept_hdr_async_with_config(
        stream,
        // The error type is tungstenite's whole HTTP response, so its size is
        // not ours to shrink.
        #[allow(clippy::result_large_err)]
        move |request: &Request, mut response: Response| {
            let record = |reason: &'static str, status: StatusCode| -> ErrorResponse {
                if let Ok(mut slot) = callback_refusal.lock() {
                    *slot = Some(reason);
                }
                // Silence: a status line, no body, no hint about which check
                // failed. The operator gets the reason in the daemon's log.
                let mut refusal = ErrorResponse::new(None);
                *refusal.status_mut() = status;
                refusal
            };

            // The optional `/termio` prefix is a public mount, not a strip:
            // Tailscale Serve's `--set-path=/termio` does not rewrite. A second
            // `/termio` after that is 404, not a loop.
            let path = request.uri().path();
            if path != "/ws" && path != "/termio/ws" {
                return Err(record("no such path", StatusCode::NOT_FOUND));
            }

            let origin = header(request, "origin");
            let host = header(request, "host");
            if !policy.allows(origin, host) {
                return Err(record("origin not allowed", StatusCode::FORBIDDEN));
            }

            let Some(expected) = expected.as_deref() else {
                return Err(record(
                    "no pair.token on this host",
                    StatusCode::UNAUTHORIZED,
                ));
            };
            let Some(selected) =
                select_subprotocol(header(request, "sec-websocket-protocol"), expected)
            else {
                return Err(record(
                    "bad or missing pairing token",
                    StatusCode::UNAUTHORIZED,
                ));
            };
            let Ok(value) = HeaderValue::from_str(&selected) else {
                return Err(record("bad subprotocol", StatusCode::BAD_REQUEST));
            };
            response
                .headers_mut()
                .insert("sec-websocket-protocol", value);
            Ok(response)
        },
        Some(config),
    );

    let websocket = match tokio::time::timeout(HANDSHAKE_TIMEOUT, handshake).await {
        Ok(Ok(websocket)) => websocket,
        Ok(Err(error)) => {
            let reason = refusal.lock().ok().and_then(|slot| *slot);
            match reason {
                Some(reason) => bail!("refused: {reason}"),
                None => bail!("handshake failed: {error}"),
            }
        }
        Err(_) => bail!("handshake timed out"),
    };

    splice(websocket, shutdown, rotation).await
}

fn header<'a>(request: &'a Request, name: &str) -> Option<&'a str> {
    request
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
}

/// The token rides the negotiated subprotocol, never the query string: a query
/// on the Upgrade line is the proxy-log leak this exists to close.
fn select_subprotocol(offered: Option<&str>, expected: &str) -> Option<String> {
    offered?
        .split(',')
        .map(str::trim)
        .find(|entry| {
            entry
                .strip_prefix(SUBPROTOCOL_PREFIX)
                .is_some_and(|token| secret_eq(token, expected))
        })
        .map(str::to_string)
}

/// Compare in time that does not depend on where the first byte differs. Not
/// crypto — a loop and an OR — but a network-facing secret comparison should
/// not hand out a prefix oracle.
fn secret_eq(candidate: &str, expected: &str) -> bool {
    if candidate.len() != expected.len() {
        return false;
    }
    let mut difference = 0u8;
    for (left, right) in candidate.bytes().zip(expected.bytes()) {
        difference |= left ^ right;
    }
    difference == 0
}

// ---------------------------------------------------------------------------
// The splice
// ---------------------------------------------------------------------------

enum Step {
    FromClient(Option<Result<Message, tokio_tungstenite::tungstenite::Error>>),
    FromDaemon(std::io::Result<usize>),
    Ping,
    Stop,
}

/// Copy bytes between the WebSocket and a connected `UnixStream`, understanding
/// no frames — the same shape as `client::stdio()`, so `handle_conn` stays
/// Unix-only and every backlog, snapshot and writer rule keeps working.
async fn splice<S>(
    mut websocket: WebSocketStream<S>,
    mut shutdown: watch::Receiver<bool>,
    mut rotation: watch::Receiver<u64>,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    // Not `client::connect()`: that auto-spawns a daemon, and a listener living
    // inside one must never fork a second.
    let socket_path = paths::socket_path()?;
    let daemon = UnixStream::connect(&socket_path)
        .await
        .with_context(|| format!("connecting {}", socket_path.display()))?;
    let (mut daemon_read, mut daemon_write) = daemon.into_split();

    let mut buffer = vec![0u8; SPLICE_CHUNK];
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    ping.tick().await;
    let mut awaiting_pong = false;
    let mut text_frame = false;

    loop {
        let step = tokio::select! {
            // The daemon signals shutdown exactly once, and a dropped sender
            // means it is already going away, so either resolution is a stop.
            _ = shutdown.changed() => Step::Stop,
            _ = rotation.changed() => Step::Stop,
            incoming = websocket.next() => Step::FromClient(incoming),
            read = daemon_read.read(&mut buffer) => Step::FromDaemon(read),
            _ = ping.tick() => Step::Ping,
        };

        match step {
            Step::Stop => break,
            Step::FromClient(None) | Step::FromClient(Some(Err(_))) => break,
            Step::FromClient(Some(Ok(message))) => match message {
                Message::Binary(bytes) => {
                    if daemon_write.write_all(&bytes).await.is_err() {
                        break;
                    }
                }
                // A text message is a protocol error: the stream is framed
                // bytes, and anything else means the far end is speaking
                // something this is not.
                Message::Text(_) => {
                    text_frame = true;
                    break;
                }
                Message::Pong(_) => awaiting_pong = false,
                Message::Close(_) => break,
                Message::Ping(_) | Message::Frame(_) => {}
            },
            Step::FromDaemon(Ok(0)) | Step::FromDaemon(Err(_)) => break,
            Step::FromDaemon(Ok(count)) => {
                let chunk = Bytes::copy_from_slice(&buffer[..count]);
                if websocket.send(Message::Binary(chunk)).await.is_err() {
                    break;
                }
            }
            Step::Ping => {
                // A missing pong is a detach, never a kill: the session outlives
                // the socket by design.
                if awaiting_pong {
                    break;
                }
                awaiting_pong = true;
                if websocket.send(Message::Ping(Bytes::new())).await.is_err() {
                    break;
                }
            }
        }
    }

    // Half-closing is what tells the daemon this was a clean detach, so the
    // session keeps running.
    let _ = daemon_write.shutdown().await;
    let close = text_frame.then(|| CloseFrame {
        code: CloseCode::Unsupported,
        reason: "the session protocol is binary".into(),
    });
    let _ = websocket.close(close).await;
    if text_frame {
        bail!("closed: text message on a binary framed stream");
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Rotation
// ---------------------------------------------------------------------------

/// Live splices close when the token changes. `pair --rotate` is the only
/// revocation there is, so it has to reach connections that are already up.
///
/// One watch for the process. The accept loop and the tailnet helper both
/// follow it. A watch of this directory feeds itself: notify 8.2.0's inotify
/// mask includes `IN_OPEN`, and reading `pair.token` is that open. A second
/// watch receives every one of those opens.
pub(crate) struct Rotation {
    sender: watch::Sender<u64>,
}

struct RotationHub {
    sender: watch::Sender<u64>,
    watcher: Mutex<Option<RecommendedWatcher>>,
}

static ROTATION: OnceLock<RotationHub> = OnceLock::new();

impl Rotation {
    pub(crate) fn subscribe(&self) -> watch::Receiver<u64> {
        self.sender.subscribe()
    }
}

pub(crate) fn start_rotation_watch() -> Rotation {
    let hub = ROTATION.get_or_init(|| {
        let (sender, _) = watch::channel(0u64);
        RotationHub {
            sender,
            watcher: Mutex::new(None),
        }
    });
    {
        // The accept loop and the tailnet supervisor call this concurrently.
        // Two installs would be two watches of the same directory.
        let mut watcher = hub.watcher.lock().unwrap();
        if watcher.is_none() {
            match install_watch(hub.sender.clone()) {
                Ok(installed) => *watcher = Some(installed),
                Err(error) => {
                    // Degraded, not broken: new Upgrades still read the token
                    // from disk. Leave the slot empty so the next caller retries.
                    eprintln!("termiod: wss: not watching pair.token for rotation: {error:#}");
                }
            }
        }
    }
    Rotation {
        sender: hub.sender.clone(),
    }
}

fn rotation_signal(event: &notify::Event, token_name: &std::ffi::OsStr) -> bool {
    // File name, not full path: `/tmp` is a symlink to `/private/tmp` on macOS.
    !crate::resource::is_read_only_access(&event.kind)
        && event
            .paths
            .iter()
            .any(|path| path.file_name() == Some(token_name))
}

fn install_watch(sender: watch::Sender<u64>) -> Result<RecommendedWatcher> {
    // Derived from the token's own path, not `state_dir`: the token lives in
    // the durable dir, and a watch on the socket dir would never see a rotate.
    let token_path = paths::pair_token_path()?;
    let directory = token_path
        .parent()
        .map(std::path::Path::to_path_buf)
        .ok_or_else(|| anyhow::anyhow!("the pairing token has no parent directory"))?;
    let token_name = token_path
        .file_name()
        .map(std::ffi::OsString::from)
        .ok_or_else(|| anyhow::anyhow!("the pairing token has no file name"))?;
    // Capacity 1. The queued consumer reads `pair.token` from disk, so a
    // newer signal would only repeat that read.
    let (raw_tx, mut raw_rx) = mpsc::channel::<()>(1);
    let mut watcher = notify::recommended_watcher(move |result| {
        let event = match result {
            Ok(event) => event,
            Err(error) => {
                eprintln!("termiod: wss: pair.token watch: {error:#}");
                return;
            }
        };
        if rotation_signal(&event, token_name.as_os_str()) {
            let _ = raw_tx.try_send(());
        }
    })
    .context("creating the pair.token watcher")?;
    // The directory, not the file: rotation renames a staged file into place,
    // so the inode the watcher was holding would go stale.
    watcher
        .watch(&directory, RecursiveMode::NonRecursive)
        .with_context(|| format!("watching {}", directory.display()))?;

    tokio::spawn(async move {
        let mut current = paths::read_pair_token().ok().flatten();
        while raw_rx.recv().await.is_some() {
            let latest = paths::read_pair_token().ok().flatten();
            if latest != current {
                current = latest;
                sender.send_modify(|generation| *generation += 1);
            }
        }
    });
    Ok(watcher)
}

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

pub struct PairOptions {
    pub json: bool,
    pub qr: bool,
    pub rotate: bool,
    pub wss_off: bool,
    pub url: Option<String>,
}

/// `termio pair` — the enrollment ladder's bottom two rungs. A Mac that
/// already has SSH runs `--json` and pushes the invite; an operator sitting in
/// a terminal on the box runs `--qr` and scans the screen in front of them.
pub fn run_pair(options: PairOptions) -> Result<()> {
    paths::ensure_runtime_dir()?;
    // `pair` runs in its own process, usually before the upgraded daemon has
    // restarted — so the files an older build kept beside the socket may not
    // have been adopted yet. Reading (`--json`/`--qr` needs `wss.origin`) or
    // writing around them here would answer from, or leave behind, state the
    // next daemon start will contradict.
    paths::adopt_runtime_state();

    let token = if options.rotate {
        let token = paths::rotate_pair_token()?;
        eprintln!("termiod: pairing token rotated — every paired client must be re-paired");
        token
    } else {
        paths::load_or_create_pair_token()?
    };

    if options.wss_off {
        paths::remove_wss_bind()?;
        eprintln!("termiod: wss off — the next `termiod serve` binds the Unix socket only");
    }

    let url = invite_url(options.url.as_deref())?;

    if options.json || options.qr {
        // The listener binds loopback by design, so the reachable name lives in
        // --wss-origin or the tunnel and cannot be derived here. Printing a QR
        // to nowhere is worse than refusing.
        let Some(url) = url.as_deref() else {
            bail!(
                "no reachable URL for this box, so there is nothing to pair against.\n\
                 Run `termio server tailscale on`, pass `--url https://<host>/termio/`, \
                 or start the daemon with `--wss-origin https://<host>`."
            );
        };
        let host_id = paths::load_or_create_host_id()?;
        let invite = invite_link(url, &token, &host_id);
        if options.json {
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "url": url,
                    "token": token,
                    "host_id": host_id,
                    "proto": crate::protocol::PROTOCOL_VERSION,
                }))?
            );
        }
        if options.qr {
            println!("{}", render_qr(&invite)?);
            println!("{invite}");
        }
        return Ok(());
    }

    println!("{token}");
    if let Some(url) = url.as_deref() {
        let host_id = paths::load_or_create_host_id()?;
        println!("{}", invite_link(url, &token, &host_id));
    }
    Ok(())
}

/// Where this box is reachable from a phone — never derived from the bind,
/// which is loopback on purpose.
fn invite_url(explicit: Option<&str>) -> Result<Option<String>> {
    if let Some(url) = explicit {
        let url = url.trim();
        if url.is_empty() {
            bail!("--url is empty");
        }
        return Ok(Some(url.to_string()));
    }
    if let Some(raw) = env_value("TERMIOD_WSS_ORIGIN") {
        if let Some(origin) = parse_origin_list(&raw, "TERMIOD_WSS_ORIGIN").first() {
            return Ok(Some(origin.base_url()));
        }
    }
    let path = paths::wss_origin_path()?;
    if let Some(raw) = read_trimmed(&path)? {
        if let Some(origin) = parse_origin_list(&raw, &path.display().to_string()).first() {
            return Ok(Some(origin.base_url()));
        }
    }
    Ok(crate::tailnet::read_status().and_then(|status| status.reachable_url()))
}

/// The four fields of the invite, in the `termio://device?…` form a phone can
/// take from a QR or from a paste. No display name: the client names the box.
fn invite_link(url: &str, token: &str, host_id: &str) -> String {
    format!(
        "termio://device?url={}&token={}&host_id={}&proto={}",
        percent_encode(url),
        percent_encode(token),
        percent_encode(host_id),
        crate::protocol::PROTOCOL_VERSION
    )
}

fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Half-block Unicode so one terminal row carries two QR rows and the code
/// stays square enough for a phone camera to lock onto.
fn render_qr(data: &str) -> Result<String> {
    let code = qrcode::QrCode::new(data).context("encoding the pairing QR")?;
    Ok(code
        .render::<qrcode::render::unicode::Dense1x2>()
        .quiet_zone(true)
        .build())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn origins(entries: &[&str]) -> Vec<Origin> {
        entries
            .iter()
            .map(|entry| parse_origin(entry).expect("test origin"))
            .collect()
    }

    #[test]
    fn loopback_addresses_are_accepted() {
        assert_eq!(
            parse_bind("127.0.0.1:8790").unwrap(),
            "127.0.0.1:8790".parse::<SocketAddr>().unwrap()
        );
        assert_eq!(parse_bind("127.0.0.1").unwrap().port(), DEFAULT_PORT);
        assert!(parse_bind("[::1]:8790").unwrap().ip().is_loopback());
        assert!(parse_bind("localhost:8790").unwrap().ip().is_loopback());
    }

    #[test]
    fn off_loopback_addresses_are_refused() {
        for raw in ["0.0.0.0:8790", "[::]:8790", "192.168.1.10:8790", "0.0.0.0"] {
            let error = parse_bind(raw).expect_err(raw);
            assert!(error.contains("not loopback"), "{raw}: {error}");
        }
    }

    /// The four worked examples from the RFC's §"Auth" table, in order.
    #[test]
    fn origin_worked_examples() {
        assert!(origin_allowed(
            Some("http://127.0.0.1:8790"),
            Some("127.0.0.1:8790"),
            &[]
        ));
        assert!(!origin_allowed(
            Some("https://box.tailnet.ts.net"),
            Some("127.0.0.1:8790"),
            &[]
        ));
        assert!(origin_allowed(
            Some("https://box.tailnet.ts.net"),
            Some("127.0.0.1:8790"),
            &origins(&["https://box.tailnet.ts.net"])
        ));
        assert!(origin_allowed(
            Some("https://box.tailnet.ts.net:443"),
            Some("127.0.0.1:8790"),
            &origins(&["https://box.tailnet.ts.net"])
        ));
    }

    #[test]
    fn missing_null_and_file_origins_are_refused() {
        let allowed = origins(&["https://box.example"]);
        assert!(!origin_allowed(None, Some("box.example"), &allowed));
        assert!(!origin_allowed(Some("null"), Some("box.example"), &allowed));
        assert!(!origin_allowed(
            Some("file://"),
            Some("box.example"),
            &allowed
        ));
        // No native exemption: a client that sends no Origin is refused even
        // though the token would have been fine.
        assert!(!origin_allowed(None, Some("127.0.0.1:8790"), &[]));
    }

    #[test]
    fn an_allowlist_entry_must_match_exactly() {
        let allowed = origins(&["https://box.example"]);
        assert!(!origin_allowed(
            Some("http://box.example"),
            Some("box.example"),
            &allowed
        ));
        assert!(!origin_allowed(
            Some("https://evil.example"),
            Some("box.example"),
            &allowed
        ));
        assert!(!origin_allowed(
            Some("https://box.example:8443"),
            Some("box.example"),
            &allowed
        ));
        // Case in the host is not a difference.
        assert!(origin_allowed(
            Some("https://BOX.example"),
            Some("box.example"),
            &allowed
        ));
    }

    #[test]
    fn the_token_must_match_the_offered_subprotocol() {
        assert_eq!(
            select_subprotocol(Some("termiod.secret"), "secret").as_deref(),
            Some("termiod.secret")
        );
        assert_eq!(
            select_subprotocol(Some("chat, termiod.secret"), "secret").as_deref(),
            Some("termiod.secret")
        );
        assert!(select_subprotocol(Some("termiod.wrong"), "secret").is_none());
        assert!(select_subprotocol(Some("termiod."), "secret").is_none());
        assert!(select_subprotocol(Some("secret"), "secret").is_none());
        assert!(select_subprotocol(None, "secret").is_none());
    }

    #[test]
    fn an_origin_renders_back_to_a_base_url() {
        assert_eq!(
            parse_origin("https://box.example").unwrap().base_url(),
            "https://box.example/"
        );
        assert_eq!(
            parse_origin("http://127.0.0.1:8790").unwrap().base_url(),
            "http://127.0.0.1:8790/"
        );
    }

    #[test]
    fn only_a_change_to_the_token_file_wakes_rotation() {
        use notify::event::{AccessKind, AccessMode, ModifyKind, RemoveKind, RenameMode};
        let name = std::ffi::OsStr::new("pair.token");
        let wakes = |kind: notify::EventKind, path: &str| {
            rotation_signal(&notify::Event::new(kind).add_path(path.into()), name)
        };

        assert!(!wakes(
            notify::EventKind::Access(AccessKind::Open(AccessMode::Any)),
            "/private/tmp/pair.token"
        ));
        assert!(!wakes(
            notify::EventKind::Modify(ModifyKind::Any),
            "/private/tmp/termiod.log"
        ));
        assert!(!wakes(
            notify::EventKind::Access(AccessKind::Close(AccessMode::Write)),
            "/private/tmp/.adopt.lock"
        ));
        assert!(wakes(
            notify::EventKind::Access(AccessKind::Close(AccessMode::Write)),
            "/private/tmp/pair.token"
        ));
        assert!(wakes(
            notify::EventKind::Remove(RemoveKind::File),
            "/private/tmp/pair.token"
        ));

        let renamed = notify::Event::new(notify::EventKind::Modify(ModifyKind::Name(
            RenameMode::Both,
        )))
        .add_path("/private/tmp/pair.staged".into())
        .add_path("/private/tmp/pair.token".into());
        assert!(rotation_signal(&renamed, name));
    }
}
