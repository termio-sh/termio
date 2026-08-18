//! WSS binding — the browser's pipe to the same framed protocol.
//!
//! This is a *transport*, not a second protocol. A WebSocket binary message
//! carries protocol bytes and nothing else: the 5-byte framing stays inside the
//! payload, so a recorded transcript replays byte-identical here, over the Unix
//! socket, and over `termiod stdio` (§C.9). Message boundaries are deliberately
//! **not** frame boundaries — leaning on them would make the web a dialect, and
//! the companion wire already taught us what that costs.
//!
//! Three rules this module exists to enforce, none of them negotiable:
//!
//! 1. **Loopback only.** The bind address is parsed and refused unless
//!    `is_loopback()`. TLS lives in Tailscale Serve or Caddy in front; `termiod`
//!    never grows a TLS stack, because "never embed crypto" is a trust choice
//!    and not a performance one.
//! 2. **Authenticate before the splice.** Origin allowlist plus a pairing token,
//!    both checked on the handshake, before a single byte reaches the session
//!    socket.
//! 3. **Serve files, do not be a web server.** The GET side is a jail: a fixed
//!    root, no traversal, no symlink escape, no directory listing, an explicit
//!    MIME map. Anything past that belongs to the reverse proxy.

use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use bytes::Bytes;
use futures_util::stream::{SplitSink, StreamExt};
use futures_util::SinkExt;
use notify::{RecursiveMode, Watcher};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::error::ProtocolError;
use tokio_tungstenite::tungstenite::handshake::derive_accept_key;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, Message, Role};
use tokio_tungstenite::tungstenite::Error as WsError;
use tokio_tungstenite::WebSocketStream;

use crate::paths;

/// One read of the Unix socket. An IO chunk size, deliberately *not* a frame
/// boundary: a chunk may split a protocol frame anywhere and may carry several.
const SPLICE_CHUNK: usize = 64 * 1024;

/// How often the host pings a quiet tab. Both Tailscale Serve and Caddy
/// idle-timeout upstreams, and a shell can be silent for hours, so transport
/// pings are what keep a left-open tab a live attachment.
const PING_INTERVAL: Duration = Duration::from_secs(30);

/// Where the pairing secret lives, beside the socket like every other
/// per-daemon file (`host.id`, the graveyard). Two daemons on two sockets must
/// not share one token.
pub fn token_path() -> Result<PathBuf> {
    Ok(paths::state_dir()?.join("pair.token"))
}

/// The remembered bind, so a crash restart or a bare `termiod serve` from
/// systemd brings WSS back. A flag that only lives on one foreground argv dies
/// on the next restart.
pub fn bind_path() -> Result<PathBuf> {
    Ok(paths::state_dir()?.join("wss.bind"))
}

#[derive(Debug, Clone)]
pub struct WssConfig {
    pub bind: SocketAddr,
    /// Exact origins to allow. Empty means "same-origin against the request's
    /// own Host", which is what a loopback / `ssh -L` setup wants.
    pub origins: Vec<String>,
    pub web_root: Option<PathBuf>,
}

/// Parse and **refuse anything that is not loopback**. Stronger than rejecting
/// `0.0.0.0`: a LAN address, a public address, or a hostname that resolves off
/// loopback are all errors here, at parse time, with the same wording the
/// `--help` and DEPLOY.md carry.
pub fn parse_bind(value: &str) -> Result<SocketAddr> {
    let addr: SocketAddr = value
        .parse()
        .with_context(|| format!("`{value}` is not a host:port address"))?;
    if !addr.ip().is_loopback() {
        bail!(
            "--wss must bind a loopback address (127.0.0.0/8 or ::1); `{}` is reachable from the \
             network. Put Tailscale Serve or Caddy in front instead — termiod does not terminate TLS."
        , value);
    }
    Ok(addr)
}

/// Resolve the bind from flag, then env, then the remembered file. First
/// present *valid* value wins; absent everywhere means no TCP listener at all
/// and the DEPLOY.md contract is unchanged.
pub fn resolve_bind(flag: Option<&str>) -> Result<Option<SocketAddr>> {
    if let Some(value) = flag {
        return Ok(Some(parse_bind(value)?));
    }
    if let Ok(value) = std::env::var("TERMIOD_WSS") {
        if !value.trim().is_empty() {
            return Ok(Some(parse_bind(value.trim())?));
        }
    }
    let path = bind_path()?;
    if let Ok(contents) = std::fs::read_to_string(&path) {
        let value = contents.trim();
        if !value.is_empty() {
            return Ok(Some(parse_bind(value)?));
        }
    }
    Ok(None)
}

/// Read the pairing secret. `None` means the daemon may not accept a WebSocket:
/// there is nothing to authenticate with, and an unauthenticated splice onto a
/// PTY is not a degraded mode, it is a hole.
pub fn load_token() -> Result<Option<String>> {
    let path = token_path()?;
    match std::fs::read_to_string(&path) {
        Ok(contents) => {
            let token = contents.trim().to_string();
            Ok(if token.is_empty() { None } else { Some(token) })
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

/// base64url without padding. Twenty-four bytes divide evenly into four-byte
/// groups, so there is no tail case to get wrong and no reason to take a
/// dependency for thirty-two characters.
fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let bits = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        let indices = [
            (bits >> 18) & 0x3f,
            (bits >> 12) & 0x3f,
            (bits >> 6) & 0x3f,
            bits & 0x3f,
        ];
        for (position, index) in indices.iter().enumerate() {
            if position <= chunk.len() {
                out.push(ALPHABET[*index as usize] as char);
            }
        }
    }
    out
}

fn mint_token() -> Result<String> {
    let mut random = [0u8; 24];
    std::fs::File::open("/dev/urandom")
        .context("opening OS random source")?
        .read_exact(&mut random)
        .context("reading OS random source")?;
    Ok(base64url(&random))
}

/// Write a per-daemon file at 0600. Through a temp file and a rename, because
/// `OpenOptions::mode` is ignored when the file already exists — rotating onto
/// a file someone once chmod'd would otherwise keep the looser mode.
fn write_private_file(path: &Path, contents: &str) -> Result<()> {
    let temp = path.with_extension("tmp");
    let _ = std::fs::remove_file(&temp);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)
        .with_context(|| format!("creating {}", temp.display()))?;
    file.write_all(contents.as_bytes())
        .with_context(|| format!("writing {}", temp.display()))?;
    file.sync_all()
        .with_context(|| format!("syncing {}", temp.display()))?;
    drop(file);
    std::fs::rename(&temp, path)
        .with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// `termiod pair` — the only thing that mints. `--wss` never does: a listener
/// that can invent its own credential is a listener with no credential.
pub fn pair(rotate: bool, wss_off: bool) -> Result<()> {
    paths::ensure_runtime_dir()?;

    if wss_off {
        let path = bind_path()?;
        match std::fs::remove_file(&path) {
            Ok(()) => eprintln!("termiod: wss off — removed {}", path.display()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                eprintln!("termiod: wss already off");
            }
            Err(error) => {
                return Err(error).with_context(|| format!("removing {}", path.display()))
            }
        }
        return Ok(());
    }

    let path = token_path()?;
    let existing = load_token()?;
    let token = match existing {
        Some(token) if !rotate => token,
        _ => {
            let token = mint_token()?;
            write_private_file(&path, &token)?;
            if rotate {
                // The running daemon notices through `notify` and drops its live
                // splices. Detach, not kill: the sessions do not care.
                eprintln!("termiod: rotated — open web attachments will detach");
            }
            token
        }
    };
    println!("{token}");
    Ok(())
}

/// What `termiod serve` was told about the web pipe, before any of it is
/// resolved against the environment or the remembered file.
#[derive(Debug, Default, Clone)]
pub struct ServeOptions {
    pub wss: Option<String>,
    pub origins: Vec<String>,
    pub web_root: Option<PathBuf>,
}

fn origins_from_env() -> Vec<String> {
    std::env::var("TERMIOD_WSS_ORIGIN")
        .map(|value| {
            value
                .split(',')
                .map(|part| part.trim().to_string())
                .filter(|part| !part.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// Decide whether this process listens on TCP at all, and remember the answer.
///
/// The rules exist because a flag that only lives on one foreground argv dies
/// on the next crash restart, and because the two ways to be unpaired are not
/// the same mistake:
///
/// - An **explicit** `--wss` without `pair.token` is an operator asking for a
///   listener that cannot authenticate. Refuse the whole start, write nothing.
/// - An **inherited** bind without `pair.token` is a restart of something that
///   used to work. Skip TCP, keep the Unix socket, say so on stderr. Bringing
///   down `handle_conn` because the token went missing would turn a web-pipe
///   problem into a lost Mac and a lost CLI.
pub fn plan(options: &ServeOptions) -> Result<Option<WssConfig>> {
    let explicit = options.wss.is_some();
    let Some(bind) = resolve_bind(options.wss.as_deref())? else {
        return Ok(None);
    };

    if load_token()?.is_none() {
        if explicit {
            bail!(
                "--wss {bind} needs a pairing token: run `termiod pair` first.\n\
                 Nothing was written to {} — a WSS listener that cannot authenticate is a hole, \
                 not a degraded mode.",
                bind_path()?.display()
            );
        }
        eprintln!("termiod: wss skipped: no pair.token");
        return Ok(None);
    }

    if explicit {
        let path = bind_path()?;
        write_private_file(&path, &bind.to_string())
            .with_context(|| format!("remembering the wss bind in {}", path.display()))?;
    }

    let mut origins = options.origins.clone();
    origins.extend(origins_from_env());
    origins.retain(|entry| !entry.trim().is_empty());
    origins.dedup();

    Ok(Some(WssConfig {
        bind,
        origins,
        web_root: options.web_root.clone(),
    }))
}

/// Watch `pair.token` and bump a counter on every change.
///
/// The directory is watched rather than the file: an atomic rotate replaces the
/// inode, and a watch on the old inode would never fire again. The caller keeps
/// the returned watcher alive — dropping it silently stops the watch.
pub fn watch_token() -> Result<(watch::Receiver<u64>, notify::RecommendedWatcher)> {
    let path = token_path()?;
    let name = path
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_default();
    let directory = paths::state_dir()?;
    let (sender, receiver) = watch::channel(0u64);

    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let Ok(event) = event else { return };
        // Matched on the file name, not the whole path: FSEvents reports
        // `/private/var/...` where `state_dir()` says `/var/...`, and a
        // canonicalisation mismatch would silently disarm rotation. The watch
        // is non-recursive on one directory, so the name is unambiguous.
        if event
            .paths
            .iter()
            .any(|changed| changed.file_name() == Some(name.as_os_str()))
        {
            sender.send_modify(|generation| *generation += 1);
        }
    })
    .context("starting the pair.token watcher")?;
    watcher
        .watch(&directory, RecursiveMode::NonRecursive)
        .with_context(|| format!("watching {}", directory.display()))?;

    Ok((receiver, watcher))
}

/// One parsed request head. Only what the two decisions need: route, upgrade or
/// not, and the headers that gate the splice or complete the handshake.
#[derive(Debug, Default)]
struct RequestHead {
    method: String,
    path: String,
    host: Option<String>,
    origin: Option<String>,
    upgrade: bool,
    protocols: Vec<String>,
    /// `Sec-WebSocket-Key`. Absent ⇒ 400; there is nothing to derive an accept
    /// key from.
    key: Option<String>,
    /// `Sec-WebSocket-Version`. Anything but "13" ⇒ 426 Upgrade Required.
    version: Option<String>,
}

fn parse_head(raw: &str) -> Option<RequestHead> {
    let mut lines = raw.split("\r\n");
    let mut request_line = lines.next()?.split_whitespace();
    let mut head = RequestHead {
        method: request_line.next()?.to_string(),
        path: request_line.next()?.to_string(),
        ..RequestHead::default()
    };

    for line in lines {
        if line.is_empty() {
            break;
        }
        let (name, value) = match line.split_once(':') {
            Some((name, value)) => (name.trim().to_ascii_lowercase(), value.trim()),
            None => continue,
        };
        match name.as_str() {
            "host" => head.host = Some(value.to_string()),
            "origin" => head.origin = Some(value.to_string()),
            "upgrade" => head.upgrade = value.eq_ignore_ascii_case("websocket"),
            "sec-websocket-protocol" => {
                head.protocols = value
                    .split(',')
                    .map(|part| part.trim().to_string())
                    .filter(|part| !part.is_empty())
                    .collect();
            }
            "sec-websocket-key" => head.key = Some(value.to_string()),
            "sec-websocket-version" => head.version = Some(value.to_string()),
            _ => {}
        }
    }
    Some(head)
}

/// An authority as the Origin check compares them: host plus an explicit port,
/// with the scheme's default filled in so `https://box` and `box:443` match.
fn authority(host: &str, default_port: u16) -> (String, u16) {
    let host = host.trim();
    // IPv6 literals are bracketed, and the colon inside them is not a port.
    if let Some(rest) = host.strip_prefix('[') {
        if let Some((inside, tail)) = rest.split_once(']') {
            let port = tail
                .strip_prefix(':')
                .and_then(|p| p.parse().ok())
                .unwrap_or(default_port);
            return (inside.to_ascii_lowercase(), port);
        }
    }
    match host.rsplit_once(':') {
        Some((name, port)) if port.chars().all(|c| c.is_ascii_digit()) && !port.is_empty() => {
            (name.to_ascii_lowercase(), port.parse().unwrap_or(default_port))
        }
        _ => (host.to_ascii_lowercase(), default_port),
    }
}

fn is_loopback_host(host: &str) -> bool {
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    host.parse::<IpAddr>().map(|ip| ip.is_loopback()).unwrap_or(false)
}

/// The Origin algorithm from the RFC, in order.
///
/// A missing Origin is rejected rather than waved through: a browser always
/// sends one on a cross-document WebSocket, so its absence means the caller is
/// not the page we serve, and this is the only check standing between a hostile
/// page and someone's shell.
fn origin_allowed(head: &RequestHead, allowed: &[String]) -> bool {
    let origin = match head.origin.as_deref() {
        Some(value) if !value.is_empty() && value != "null" => value,
        _ => return false,
    };
    let (scheme, rest) = match origin.split_once("://") {
        Some(parts) => parts,
        None => return false,
    };
    let default_port = match scheme {
        "https" => 443,
        "http" => 80,
        _ => return false, // file://, ws://, anything else
    };

    if !allowed.is_empty() {
        // Explicit allowlist: compare scheme, host, and port exactly, with the
        // scheme default filled in on both sides so `https://box` == `https://box:443`.
        let (origin_host, origin_port) = authority(rest, default_port);
        return allowed.iter().any(|entry| {
            match entry.trim().split_once("://") {
                Some((entry_scheme, entry_rest)) if entry_scheme == scheme => {
                    let (host, port) = authority(entry_rest, default_port);
                    host == origin_host && port == origin_port
                }
                _ => false,
            }
        });
    }

    // Default same-origin: the Origin's authority must equal the request's own
    // Host authority. A TLS terminator in front rewrites Host, which is exactly
    // why it must pass --wss-origin instead of relying on this branch.
    let host = match head.host.as_deref() {
        Some(value) => value,
        None => return false,
    };
    let (origin_host, origin_port) = authority(rest, default_port);
    // The listener is plain HTTP, so a Host with no port means 80.
    let (host_name, host_port) = authority(host, 80);
    if origin_host != host_name || origin_port != host_port {
        return false;
    }
    // A raw loopback Host is only same-origin with a loopback Origin — this is
    // the `ssh -L` case, and it must not become a way for any page to reach a
    // daemon by naming 127.0.0.1.
    if is_loopback_host(&host_name) {
        return is_loopback_host(&origin_host);
    }
    true
}

/// Constant-time-ish comparison. The token is compared on every handshake and
/// a naive `==` leaks its length and prefix through timing; this is cheap
/// enough that there is no reason to take that risk.
fn secret_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The token rides the WebSocket **subprotocol**, never the query string: a
/// URL lands in logs, in `Referer`, and in screenshots, and this one is a key
/// to a shell.
fn token_from_protocols(protocols: &[String], token: &str) -> Option<String> {
    protocols
        .iter()
        .find(|entry| {
            entry
                .strip_prefix("termiod.token.")
                .map(|value| secret_eq(value, token))
                .unwrap_or(false)
        })
        .cloned()
}

/// The client offers `["termiod.v1", "termiod.token.<token>"]`. The token entry
/// authenticates; the *selected* protocol is `termiod.v1` and never the token
/// entry, because the selected value is echoed into a response header that
/// every proxy in front of us logs.
fn selected_protocol(protocols: &[String]) -> Option<&'static str> {
    protocols
        .iter()
        .any(|entry| entry == "termiod.v1")
        .then_some("termiod.v1")
}

/// Strip the optional `/termio` mount prefix. Tailscale Serve's `--set-path`
/// publishes rather than strips, so requests arrive with the prefix; Caddy's
/// `handle_path` strips it and they arrive without. Accepting both is what lets
/// one recipe work behind either without telling the operator to add a rewrite.
fn route(path: &str) -> &str {
    let path = path.split('?').next().unwrap_or(path);
    match path.strip_prefix("/termio") {
        Some("") => "/",
        Some(rest) if rest.starts_with('/') => rest,
        Some(_) => path,
        None => path,
    }
}

fn content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        // Explicit, because a Wasm served as octet-stream fails
        // `instantiateStreaming` with an error that reads like a build problem.
        "wasm" => "application/wasm",
        "woff2" => "font/woff2",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        _ => "application/octet-stream",
    }
}

/// Resolve a request path inside the web root, or `None` if it escapes.
///
/// Canonicalising both sides is what closes symlink traversal — a `..` filter
/// alone does not, because a symlink inside the root can point anywhere.
fn resolve_asset(root: &Path, request: &str) -> Option<PathBuf> {
    let relative = request.trim_start_matches('/');
    let relative = if relative.is_empty() { "index.html" } else { relative };
    // Source maps are excluded outright: they are build output that describes
    // the client to anyone who asks, and nothing in the product needs them.
    if relative.ends_with(".map") || relative.contains("..") {
        return None;
    }
    let root = root.canonicalize().ok()?;
    let candidate = root.join(relative).canonicalize().ok()?;
    if !candidate.starts_with(&root) || !candidate.is_file() {
        return None;
    }
    Some(candidate)
}

async fn write_simple(stream: &mut TcpStream, status: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\n\
         Connection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.flush().await;
}

async fn serve_asset(stream: &mut TcpStream, root: &Path, request: &str) {
    let Some(path) = resolve_asset(root, request) else {
        write_simple(stream, "404 Not Found", "not found").await;
        return;
    };
    let Ok(body) = std::fs::read(&path) else {
        write_simple(stream, "404 Not Found", "not found").await;
        return;
    };
    let header = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        content_type(&path),
        body.len()
    );
    let _ = stream.write_all(header.as_bytes()).await;
    let _ = stream.write_all(&body).await;
    let _ = stream.flush().await;
}

/// Read the request head. Bounded: a client that never sends `\r\n\r\n` must
/// not be able to grow this buffer, and a head this large is not a browser.
async fn read_head(stream: &mut TcpStream) -> Option<(String, Vec<u8>)> {
    const MAX_HEAD: usize = 16 * 1024;
    let mut buffer = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    loop {
        let read = stream.read(&mut chunk).await.ok()?;
        if read == 0 {
            return None;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buffer[..end]).into_owned();
            return Some((head, buffer[end + 4..].to_vec()));
        }
        if buffer.len() > MAX_HEAD {
            return None;
        }
    }
}

type WsSink = SplitSink<WebSocketStream<TcpStream>, Message>;

/// Close the WebSocket with a reason the browser can read in `onclose`. Errors
/// are ignored on purpose: this runs on paths where the peer is already gone.
async fn close_ws(sink: &mut WsSink, code: CloseCode, reason: &str) {
    let _ = sink
        .send(Message::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        })))
        .await;
    let _ = sink.flush().await;
}

/// Finish the WebSocket handshake on an already-gated connection, then splice it
/// onto a fresh Unix-socket channel until either side ends.
///
/// Everything that authenticates has already happened: loopback bind, Origin
/// allowlist, pairing token. This function authenticates nothing and parses no
/// protocol frame — it is `client::stdio()` with an HTTP Upgrade in front. The
/// 5-byte framing stays inside the payload, WebSocket message boundaries are
/// deliberately not frame boundaries, and a transcript recorded over the Unix
/// socket replays byte-identical here.
async fn splice(
    mut stream: TcpStream,
    head: &RequestHead,
    mut rotate: watch::Receiver<u64>,
) -> Result<()> {
    let Some(key) = head.key.clone() else {
        write_simple(&mut stream, "400 Bad Request", "missing Sec-WebSocket-Key").await;
        return Ok(());
    };
    if head.version.as_deref() != Some("13") {
        let body = "this endpoint speaks WebSocket version 13";
        let response = format!(
            "HTTP/1.1 426 Upgrade Required\r\nSec-WebSocket-Version: 13\r\n\
             Content-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\n\
             Connection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(response.as_bytes()).await;
        let _ = stream.flush().await;
        return Ok(());
    }

    // `read_head` already consumed the request, so the 101 is written by hand
    // rather than by tungstenite's server handshake. The accept key is still
    // tungstenite's SHA-1 + base64; we write no crypto of our own.
    let mut response = String::from(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
    );
    response.push_str(&format!(
        "Sec-WebSocket-Accept: {}\r\n",
        derive_accept_key(key.as_bytes())
    ));
    if let Some(selected) = selected_protocol(&head.protocols) {
        response.push_str(&format!("Sec-WebSocket-Protocol: {selected}\r\n"));
    }
    response.push_str("\r\n");
    stream
        .write_all(response.as_bytes())
        .await
        .context("writing the websocket handshake response")?;
    stream.flush().await.ok();
    // One line per accepted Upgrade, and never the token. The `client_id` the
    // observability plan also wants would mean reading a frame on the way past,
    // which is the one thing this function must not do.
    eprintln!(
        "termiod: wss upgrade accepted origin={}",
        head.origin.as_deref().unwrap_or("-")
    );

    let websocket = WebSocketStream::from_raw_socket(stream, Role::Server, None).await;
    let (mut ws_write, mut ws_read) = websocket.split();

    let socket_path = paths::socket_path()?;
    let unix = match UnixStream::connect(&socket_path).await {
        Ok(unix) => unix,
        Err(error) => {
            // A clean close beats a hung tab: the browser learns the host is
            // gone instead of waiting on a socket that will never speak.
            close_ws(&mut ws_write, CloseCode::Error, "session host unavailable").await;
            return Err(error)
                .with_context(|| format!("connecting to {}", socket_path.display()));
        }
    };
    let (mut unix_read, mut unix_write) = unix.into_split();

    let mut chunk = vec![0u8; SPLICE_CHUNK];
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    ping.tick().await; // the first tick is immediate; the pipe is not idle yet
    let mut awaiting_pong = false;

    loop {
        tokio::select! {
            incoming = ws_read.next() => match incoming {
                None => {
                    // Half-close upstream so the daemon sees a detach, not a kill.
                    let _ = unix_write.shutdown().await;
                    return Ok(());
                }
                Some(Err(error)) => {
                    let _ = unix_write.shutdown().await;
                    // A closed tab is not an incident. Anything else is.
                    return match error {
                        WsError::ConnectionClosed
                        | WsError::AlreadyClosed
                        | WsError::Protocol(ProtocolError::ResetWithoutClosingHandshake) => Ok(()),
                        other => Err(other.into()),
                    };
                }
                Some(Ok(Message::Binary(bytes))) => {
                    // Verbatim. No byte is inspected, counted into a frame, or
                    // buffered on a frame boundary. An empty payload is a legal
                    // no-op.
                    unix_write
                        .write_all(&bytes)
                        .await
                        .context("writing browser bytes to the session socket")?;
                }
                Some(Ok(Message::Text(_))) => {
                    close_ws(&mut ws_write, CloseCode::Unsupported, "binary frames only").await;
                    let _ = unix_write.shutdown().await;
                    bail!("wss: text message — the browser is speaking a dialect");
                }
                Some(Ok(Message::Ping(payload))) => {
                    ws_write.send(Message::Pong(payload)).await?;
                }
                Some(Ok(Message::Pong(_))) => awaiting_pong = false,
                Some(Ok(Message::Close(_))) => {
                    let _ = unix_write.shutdown().await;
                    let _ = ws_write.flush().await;
                    return Ok(());
                }
                Some(Ok(Message::Frame(_))) => {}
            },

            read = unix_read.read(&mut chunk) => match read {
                Ok(0) => {
                    close_ws(&mut ws_write, CloseCode::Normal, "session closed").await;
                    return Ok(());
                }
                Ok(count) => {
                    // Feed-then-flush, awaited: a slow browser applies
                    // backpressure to this socket instead of growing an
                    // unbounded queue in our process. What happens next is the
                    // daemon's CLIENT_BACKLOG_CAP decision, not ours.
                    ws_write
                        .feed(Message::Binary(Bytes::copy_from_slice(&chunk[..count])))
                        .await?;
                    ws_write.flush().await?;
                }
                Err(error) => {
                    close_ws(&mut ws_write, CloseCode::Error, "session host error").await;
                    return Err(error).context("reading the session socket");
                }
            },

            _ = ping.tick() => {
                if awaiting_pong {
                    eprintln!("termiod: wss detach (no pong)");
                    close_ws(&mut ws_write, CloseCode::Away, "no pong").await;
                    let _ = unix_write.shutdown().await;
                    return Ok(());
                }
                ws_write.send(Message::Ping(Bytes::new())).await?;
                awaiting_pong = true;
            },

            _ = rotate.changed() => {
                close_ws(&mut ws_write, CloseCode::Policy, "token rotated").await;
                let _ = unix_write.shutdown().await;
                return Ok(());
            },
        }
    }
}

pub async fn serve(config: WssConfig, rotate: watch::Receiver<u64>) -> Result<()> {
    let listener = TcpListener::bind(config.bind)
        .await
        .with_context(|| format!("binding {}", config.bind))?;
    eprintln!("termiod: wss listening on {}", config.bind);

    // Live splices, so a rotate can report what it cost. Detach, never kill.
    let live = Arc::new(AtomicUsize::new(0));
    {
        let live = live.clone();
        let mut rotate = rotate.clone();
        tokio::spawn(async move {
            while rotate.changed().await.is_ok() {
                eprintln!(
                    "termiod: wss rotate: dropped {} splices",
                    live.load(Ordering::Relaxed)
                );
            }
        });
    }

    loop {
        let Ok((stream, _peer)) = listener.accept().await else {
            continue;
        };
        let config = config.clone();
        let rotate = rotate.clone();
        let live = live.clone();
        tokio::spawn(async move {
            handle(stream, config, rotate, live).await;
        });
    }
}

async fn handle(
    mut stream: TcpStream,
    config: WssConfig,
    rotate: watch::Receiver<u64>,
    live: Arc<AtomicUsize>,
) {
    let Some((raw_head, rest)) = read_head(&mut stream).await else {
        return;
    };
    let Some(head) = parse_head(&raw_head) else {
        write_simple(&mut stream, "400 Bad Request", "bad request").await;
        return;
    };
    let path = route(&head.path).to_string();

    // `GET /termio` without the slash: redirect rather than serve, or every
    // relative asset in the page resolves one directory too high. The build is
    // emitted with a relative base precisely so one bundle works under both
    // mounts, and that only holds from the trailing slash.
    if head.path.split('?').next() == Some("/termio") {
        let response = "HTTP/1.1 302 Found\r\nLocation: /termio/\r\nContent-Length: 0\r\n\
                        Connection: close\r\n\r\n";
        let _ = stream.write_all(response.as_bytes()).await;
        let _ = stream.flush().await;
        return;
    }

    if !head.upgrade {
        if head.method != "GET" {
            write_simple(&mut stream, "405 Method Not Allowed", "method not allowed").await;
            return;
        }
        match config.web_root.as_deref() {
            Some(root) => serve_asset(&mut stream, root, &path).await,
            None => write_simple(&mut stream, "404 Not Found", "no web root configured").await,
        }
        return;
    }

    if path != "/ws" {
        write_simple(&mut stream, "404 Not Found", "not found").await;
        return;
    }
    let origin = head.origin.clone().unwrap_or_else(|| "-".to_string());
    if !origin_allowed(&head, &config.origins) {
        // Terse on the wire, specific in the log: the caller learns nothing
        // about which check it failed, the operator learns everything.
        eprintln!("termiod: wss reject (origin) origin={origin}");
        write_simple(&mut stream, "403 Forbidden", "forbidden").await;
        return;
    }
    let Ok(Some(token)) = load_token() else {
        eprintln!("termiod: wss reject (unpaired) origin={origin}");
        write_simple(&mut stream, "503 Service Unavailable", "not paired").await;
        return;
    };
    let Some(_accepted) = token_from_protocols(&head.protocols, &token) else {
        eprintln!("termiod: wss reject (token) origin={origin}");
        write_simple(&mut stream, "401 Unauthorized", "unauthorized").await;
        return;
    };
    // Anything sent before the 101 would be lost when the stream is handed to
    // the WebSocket codec. No browser pipelines an Upgrade; something that does
    // is confused, and silently dropping its first frames is worse than saying so.
    if !rest.is_empty() {
        write_simple(&mut stream, "400 Bad Request", "data before the handshake").await;
        return;
    }

    live.fetch_add(1, Ordering::Relaxed);
    let result = splice(stream, &head, rotate).await;
    live.fetch_sub(1, Ordering::Relaxed);
    if let Err(error) = result {
        eprintln!("termiod: wss splice error: {error:#}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn head(origin: Option<&str>, host: Option<&str>) -> RequestHead {
        RequestHead {
            method: "GET".into(),
            path: "/ws".into(),
            host: host.map(str::to_string),
            origin: origin.map(str::to_string),
            upgrade: true,
            protocols: Vec::new(),
            key: Some("dGhlIHNhbXBsZSBub25jZQ==".into()),
            version: Some("13".into()),
        }
    }

    /// The token must never be the value we echo back: `Sec-WebSocket-Protocol`
    /// appears in every proxy access log in front of us.
    #[test]
    fn the_selected_subprotocol_is_never_the_token() {
        let offered = vec!["termiod.v1".to_string(), "termiod.token.abc123".to_string()];
        assert_eq!(selected_protocol(&offered), Some("termiod.v1"));
        assert_eq!(selected_protocol(&["termiod.token.abc123".to_string()]), None);
        assert_eq!(selected_protocol(&[]), None);
    }

    #[test]
    fn the_handshake_headers_are_parsed() {
        let raw = "GET /termio/ws HTTP/1.1\r\nHost: 127.0.0.1:8790\r\nUpgrade: websocket\r\n\
                   Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\
                   Sec-WebSocket-Protocol: termiod.v1, termiod.token.abc123";
        let head = parse_head(raw).expect("head");
        assert!(head.upgrade);
        assert_eq!(head.key.as_deref(), Some("dGhlIHNhbXBsZSBub25jZQ=="));
        assert_eq!(head.version.as_deref(), Some("13"));
        assert_eq!(head.protocols.len(), 2);
        assert_eq!(route(&head.path), "/ws");
        // RFC 6455's own worked example, so a wrong accept key fails here and
        // not in a browser console.
        assert_eq!(
            derive_accept_key(head.key.as_deref().unwrap_or_default().as_bytes()),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        );
    }

    #[test]
    fn tokens_are_base64url_without_padding() {
        assert_eq!(base64url(b""), "");
        assert_eq!(base64url(&[0xff, 0xff, 0xff]), "____");
        assert_eq!(base64url(b"a"), "YQ");
        assert_eq!(base64url(b"ab"), "YWI");
        assert_eq!(base64url(b"abc"), "YWJj");
        let token = mint_token().expect("mint");
        assert_eq!(token.len(), 32, "24 random bytes are 32 base64url characters");
        assert!(token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }

    #[test]
    fn bind_refuses_anything_reachable_from_the_network() {
        assert!(parse_bind("127.0.0.1:8790").is_ok());
        assert!(parse_bind("[::1]:8790").is_ok());
        assert!(parse_bind("127.0.0.2:8790").is_ok());
        for reachable in ["0.0.0.0:8790", "[::]:8790", "192.168.1.10:8790"] {
            assert!(parse_bind(reachable).is_err(), "{reachable} must be refused");
        }
    }

    #[test]
    fn origin_must_be_present_and_http() {
        let allowed: Vec<String> = Vec::new();
        assert!(!origin_allowed(&head(None, Some("127.0.0.1:8790")), &allowed));
        assert!(!origin_allowed(&head(Some("null"), Some("127.0.0.1:8790")), &allowed));
        assert!(!origin_allowed(&head(Some("file://"), Some("127.0.0.1:8790")), &allowed));
    }

    /// The `ssh -L` case: browser at http://localhost:8790 against a loopback
    /// bind, with no --wss-origin flag at all.
    #[test]
    fn loopback_is_same_origin_with_itself() {
        let allowed: Vec<String> = Vec::new();
        assert!(origin_allowed(
            &head(Some("http://localhost:8790"), Some("localhost:8790")),
            &allowed
        ));
        assert!(origin_allowed(
            &head(Some("http://127.0.0.1:8790"), Some("127.0.0.1:8790")),
            &allowed
        ));
        // A public page may not reach a daemon by naming loopback.
        assert!(!origin_allowed(
            &head(Some("https://evil.example"), Some("127.0.0.1:8790")),
            &allowed
        ));
    }

    #[test]
    fn explicit_allowlist_fills_in_the_scheme_default_port() {
        let allowed = vec!["https://box.tailnet.ts.net".to_string()];
        assert!(origin_allowed(
            &head(Some("https://box.tailnet.ts.net"), Some("127.0.0.1:8790")),
            &allowed
        ));
        assert!(origin_allowed(
            &head(Some("https://box.tailnet.ts.net:443"), Some("127.0.0.1:8790")),
            &allowed
        ));
        // Same host, wrong scheme and wrong port are both misses.
        assert!(!origin_allowed(
            &head(Some("http://box.tailnet.ts.net"), Some("127.0.0.1:8790")),
            &allowed
        ));
        assert!(!origin_allowed(
            &head(Some("https://box.tailnet.ts.net:8443"), Some("127.0.0.1:8790")),
            &allowed
        ));
    }

    #[test]
    fn the_mount_prefix_is_optional_and_does_not_nest() {
        assert_eq!(route("/ws"), "/ws");
        assert_eq!(route("/termio/ws"), "/ws");
        assert_eq!(route("/"), "/");
        assert_eq!(route("/termio/"), "/");
        assert_eq!(route("/ghostty-vt.wasm"), "/ghostty-vt.wasm");
        assert_eq!(route("/termio/ghostty-vt.wasm"), "/ghostty-vt.wasm");
        // A second prefix is a real path, not another strip.
        assert_eq!(route("/termio/termio/ws"), "/termio/ws");
        // A prefix that is only a name fragment is left alone.
        assert_eq!(route("/termiodocs"), "/termiodocs");
    }

    #[test]
    fn token_rides_the_subprotocol_and_must_match_exactly() {
        let protocols = vec!["termiod.v1".into(), "termiod.token.abc123".into()];
        assert!(token_from_protocols(&protocols, "abc123").is_some());
        assert!(token_from_protocols(&protocols, "abc124").is_none());
        assert!(token_from_protocols(&protocols, "abc1234").is_none());
        assert!(token_from_protocols(&[], "abc123").is_none());
    }

    #[test]
    fn the_asset_jail_refuses_traversal_and_source_maps() {
        let dir = std::env::temp_dir().join(format!("termiod-wss-jail-{}", std::process::id()));
        let _ = std::fs::create_dir_all(dir.join("sub"));
        std::fs::write(dir.join("index.html"), b"<!doctype html>").unwrap();
        std::fs::write(dir.join("app.js.map"), b"{}").unwrap();
        std::fs::write(dir.join("sub").join("app.js"), b"//").unwrap();

        assert!(resolve_asset(&dir, "/").is_some(), "root serves index.html");
        assert!(resolve_asset(&dir, "/sub/app.js").is_some());
        assert!(resolve_asset(&dir, "/app.js.map").is_none(), "source maps are excluded");
        assert!(resolve_asset(&dir, "/../etc/passwd").is_none());
        assert!(resolve_asset(&dir, "/sub/../../etc/passwd").is_none());
        assert!(resolve_asset(&dir, "/nope.js").is_none());
        // A directory is not an asset, and there is no listing.
        assert!(resolve_asset(&dir, "/sub").is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn wasm_gets_its_own_mime_type() {
        assert_eq!(content_type(Path::new("a/ghostty-vt.wasm")), "application/wasm");
        assert_eq!(content_type(Path::new("a/index.html")), "text/html; charset=utf-8");
        assert_eq!(content_type(Path::new("a/font.woff2")), "font/woff2");
    }
}
