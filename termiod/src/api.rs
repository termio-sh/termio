//! `termio api` — the session protocol as a subprocess.
//!
//! Everything the Mac app and the phone say to `termiod` is one framed JSON
//! message; the schema of every message is `docs/api/session-protocol.schema.json`,
//! generated from the types in [`crate::protocol`] so it cannot drift from the
//! daemon that answers. A program driving sessions has two ways in: implement
//! the five-byte framing and speak the socket, or shell out to this, which does
//! the handshake and the framing and leaves the JSON alone.
//!
//! Nothing here interprets an op. A request this build has never heard of is
//! written through verbatim and the daemon answers it — so a newer daemon stays
//! reachable from an older CLI, and an op that really is wrong comes back as the
//! daemon's own `unknown op` error rather than as a parse failure on this side.
//! That passthrough is the whole point: this file must never grow a list of
//! valid ops.

use crate::app_socket;
use crate::client;
use crate::protocol::{
    read_raw_frame, write_control, write_frame, ChannelRole, Control, KIND_CONTROL, KIND_EVENT,
    PROTOCOL_VERSION,
};
use anyhow::{bail, Context, Result};
use std::time::Duration;
use tokio::net::UnixStream;

/// What this passthrough tells the daemon it can handle. The control-plane
/// capabilities only: the attach-shaping ones (`snapshot`, `scrollback`,
/// `grid_diff`, `viewport`) change what a session sends an *attachment*, and
/// this channel never attaches.
const CLIENT_CAPS: &[&str] = &[
    "events",
    "resources",
    "send_wait",
    "fs_watch",
    "files",
    "upload",
    "git",
    "agents",
];

/// The `seq` given to a request that arrives without one. Every reply carries
/// `re` echoing the request's `seq`, which is how [`call`] knows which frame
/// ends the exchange; a request with no `seq` would be answered by a frame with
/// no `re`, and this client would have nothing to wait for.
const DEFAULT_SEQ: u64 = 1;

/// Connect, negotiate, and hand back the live socket plus the `hello_ok`
/// payload exactly as the daemon wrote it.
async fn handshake() -> Result<(UnixStream, serde_json::Value)> {
    let mut stream = client::connect().await?;
    write_control(
        &mut stream,
        &Control::Hello {
            proto: PROTOCOL_VERSION,
            min_proto: PROTOCOL_VERSION,
            role: ChannelRole::Control,
            caps: CLIENT_CAPS.iter().map(|cap| cap.to_string()).collect(),
            client: format!("termio-api/{}", env!("CARGO_PKG_VERSION")),
        },
    )
    .await?;
    let Some((kind, payload)) = read_raw_frame(&mut stream).await? else {
        bail!("termiod closed the connection during the handshake");
    };
    if kind != KIND_CONTROL {
        bail!("termiod answered the handshake with a {kind:#x} frame, not control");
    }
    let value: serde_json::Value =
        serde_json::from_slice(&payload).context("decoding the handshake reply")?;
    match value.get("op").and_then(|op| op.as_str()) {
        Some("hello_ok") => Ok((stream, value)),
        Some("hello_err") => {
            let supported = value
                .get("supported")
                .map(|s| s.to_string())
                .unwrap_or_else(|| "unknown".to_string());
            bail!(
                "termiod refused protocol {PROTOCOL_VERSION}; it supports {supported}. \
                 Update whichever side is older."
            )
        }
        _ => bail!("termiod answered the handshake with an unexpected message: {value}"),
    }
}

/// Print what this daemon is and what it can do — the first call any client
/// makes. The reply is the handshake's own `hello_ok`, so what this prints is
/// exactly what a client speaking the socket directly would read.
pub async fn capabilities() -> Result<()> {
    let (_stream, hello_ok) = handshake().await?;
    println!("{hello_ok}");
    Ok(())
}

/// Send one control message and print what comes back, one JSON object per
/// line. Returns when the daemon answers this request — the reply whose `re`
/// echoes the request's `seq` — or, with `stream`, when the daemon closes the
/// connection, which is how a subscription is consumed.
///
/// Data, snapshot, and the other binary frames are skipped rather than printed:
/// this is a control-plane tool, and a session's bytes belong on an attachment.
pub async fn call(request: &str, stream: bool) -> Result<()> {
    let mut body: serde_json::Value =
        serde_json::from_str(request).context("the request must be one JSON object")?;
    let object = body
        .as_object_mut()
        .context("the request must be a JSON object, not an array or a scalar")?;
    if !object.contains_key("op") {
        bail!("the request needs an \"op\" — see `termio api schema`");
    }
    let seq = match object.get("seq") {
        Some(value) => value
            .as_u64()
            .context("\"seq\" must be a non-negative integer")?,
        None => {
            object.insert("seq".to_string(), DEFAULT_SEQ.into());
            DEFAULT_SEQ
        }
    };

    let (mut socket, _hello_ok) = handshake().await?;
    write_frame(&mut socket, KIND_CONTROL, &serde_json::to_vec(&body)?).await?;

    // A daemon that never answers must not wedge the caller. It happens for a
    // real reason: a daemon older than the fix that made an unknown op an error
    // swallowed the request instead, so a new CLI asking an old host for a verb
    // it lacks would otherwise wait forever. Only the wait for *this request's*
    // reply is bounded — once it lands, `--stream` is a subscription and being
    // quiet is what a subscription does.
    let deadline = Duration::from_secs(app_socket::client_timeout());
    let mut answered = false;
    let mut failed = false;
    loop {
        let frame = if answered {
            read_raw_frame(&mut socket).await?
        } else {
            match tokio::time::timeout(deadline, read_raw_frame(&mut socket)).await {
                Ok(frame) => frame?,
                Err(_) => {
                    eprintln!(
                        "termiod did not answer {} within {}s — it may not know this op. \
                         A daemon older than the build that made an unknown op an error \
                         stays silent instead of refusing it; `termio api capabilities` \
                         reports its version. Raise TERMIO_CLI_TIMEOUT to wait longer.",
                        body.get("op").and_then(|op| op.as_str()).unwrap_or("the request"),
                        deadline.as_secs(),
                    );
                    std::process::exit(3);
                }
            }
        };
        let Some((kind, payload)) = frame else { break };
        if kind != KIND_CONTROL && kind != KIND_EVENT {
            continue;
        }
        let value: serde_json::Value = match serde_json::from_slice(&payload) {
            Ok(value) => value,
            // A frame this daemon considers well-formed control JSON and this
            // client cannot read is the daemon's news to deliver, not ours to
            // swallow: print the bytes and let the caller's parser say so.
            Err(_) => {
                println!("{}", String::from_utf8_lossy(&payload));
                continue;
            }
        };
        println!("{value}");
        let answers_us = value.get("re").and_then(|re| re.as_u64()) == Some(seq);
        if answers_us {
            answered = true;
            if value.get("op").and_then(|op| op.as_str()) == Some("error") {
                failed = true;
            }
            if !stream {
                break;
            }
        }
    }
    if failed {
        std::process::exit(1);
    }
    Ok(())
}

/// Print the schema shipped in this binary. Baked in rather than read from
/// disk so it answers on a box that has the daemon and none of the checkout,
/// and so it can never describe a build other than the one printing it.
pub fn schema() -> Result<()> {
    println!("{}", crate::protocol_schema::SCHEMA.trim_end());
    Ok(())
}
