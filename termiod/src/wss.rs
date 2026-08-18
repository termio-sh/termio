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

use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UnixStream};

use crate::paths;

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

/// One parsed request head. Only what the two decisions need: route, upgrade or
/// not, and the three headers that gate the splice.
#[derive(Debug, Default)]
struct RequestHead {
    method: String,
    path: String,
    host: Option<String>,
    origin: Option<String>,
    upgrade: bool,
    protocols: Vec<String>,
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

pub async fn serve(config: WssConfig) -> Result<()> {
    let listener = TcpListener::bind(config.bind)
        .await
        .with_context(|| format!("binding {}", config.bind))?;
    eprintln!("termiod: wss listening on {}", config.bind);

    loop {
        let Ok((stream, _peer)) = listener.accept().await else {
            continue;
        };
        let config = config.clone();
        tokio::spawn(async move {
            handle(stream, config).await;
        });
    }
}

async fn handle(mut stream: TcpStream, config: WssConfig) {
    let Some((raw_head, _rest)) = read_head(&mut stream).await else {
        return;
    };
    let Some(head) = parse_head(&raw_head) else {
        write_simple(&mut stream, "400 Bad Request", "bad request").await;
        return;
    };
    let path = route(&head.path).to_string();

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
    if !origin_allowed(&head, &config.origins) {
        // Deliberately terse: a rejected origin learns nothing about which of
        // the checks it failed.
        write_simple(&mut stream, "403 Forbidden", "forbidden").await;
        return;
    }
    let Ok(Some(token)) = load_token() else {
        write_simple(&mut stream, "503 Service Unavailable", "not paired").await;
        return;
    };
    let Some(_accepted) = token_from_protocols(&head.protocols, &token) else {
        write_simple(&mut stream, "401 Unauthorized", "unauthorized").await;
        return;
    };

    // Handshake and splice land in the next commit; the gate above is what had
    // to be right first.
    let _ = UnixStream::connect(paths::socket_path().unwrap_or_default()).await;
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
        }
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
