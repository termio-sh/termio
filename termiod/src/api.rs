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
use std::collections::BTreeMap;
use std::path::PathBuf;
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
///
/// Bare, it prints a summary a person can read; `--json` prints the document a
/// code generator wants. The summary is derived from the document rather than
/// written beside it, so an op added to the protocol appears in both or in
/// neither.
pub fn schema(json: bool, output: Option<PathBuf>) -> Result<()> {
    let document = crate::protocol_schema::SCHEMA.trim_end();
    if let Some(path) = output {
        std::fs::write(&path, format!("{document}\n"))
            .with_context(|| format!("writing {}", path.display()))?;
        eprintln!("wrote {}", path.display());
        return Ok(());
    }
    if json {
        println!("{document}");
        return Ok(());
    }
    print!("{}", summarize(document)?);
    Ok(())
}

/// The human-readable form of the schema document: what version this speaks,
/// how a frame is shaped, and every op it will answer — split into requests,
/// replies, and events by the fields the schema itself carries (`seq` on a
/// request, `re` on the reply that answers it) rather than by a list kept by
/// hand next to it.
fn summarize(document: &str) -> Result<String> {
    let schema: serde_json::Value =
        serde_json::from_str(document).context("the shipped schema is not valid JSON")?;

    let mut out = String::new();
    let protocol = schema["protocol"].as_u64().unwrap_or(0);
    let supported = schema["supported_protocols"]
        .as_array()
        .map(|versions| {
            versions
                .iter()
                .map(|version| version.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default();
    out.push_str(&format!(
        "Termio session protocol {protocol} (this build speaks {supported})\n\n"
    ));
    out.push_str("Framing  [ kind: u8 ][ length: u32 big-endian ][ payload ]\n");
    if let Some(kinds) = schema["frame_kinds"].as_object() {
        for (kind, meaning) in kinds {
            out.push_str(&format!(
                "  {kind}  {}\n",
                meaning.as_str().unwrap_or_default()
            ));
        }
    }

    let ops = control_ops(&schema);
    out.push_str(&section("Handshake", &ops.handshake));
    out.push_str(&section("Requests", &ops.requests));
    out.push_str(&section("Replies", &ops.replies));
    out.push_str(&section("Pushed by the daemon", &ops.pushed));
    out.push_str(&section("Events", &event_names(&schema)));
    out.push_str("\nFull document: termio api schema --json\n");
    Ok(out)
}

/// The control ops, split by the direction the schema itself proves. A variant
/// carrying `seq` is a request — `seq` is the caller's id for it. One carrying
/// `re` is what answers a request. The handshake is named rather than derived,
/// because `hello` and its two answers carry neither. What is left over after
/// those three is host-authored and unsolicited: `exited`, `upload_ack`,
/// `resize_claim` arrive because something happened, not because you asked.
#[derive(Default)]
struct ControlOps {
    handshake: Vec<String>,
    requests: Vec<String>,
    replies: Vec<String>,
    pushed: Vec<String>,
}

fn control_ops(schema: &serde_json::Value) -> ControlOps {
    let mut ops = ControlOps::default();
    for variant in schema["schemas"]["control"]["oneOf"]
        .as_array()
        .unwrap_or(&Vec::new())
    {
        let properties = &variant["properties"];
        let Some(op) = properties["op"]["const"].as_str() else {
            continue;
        };
        let bucket = if op.starts_with("hello") {
            &mut ops.handshake
        } else if properties.get("re").is_some() {
            &mut ops.replies
        } else if properties.get("seq").is_some() {
            &mut ops.requests
        } else {
            &mut ops.pushed
        };
        bucket.push(op.to_string());
    }
    ops
}

/// The event names, minus `unknown`. That variant is how a client's decoder
/// tolerates an event from a newer host — events evolve additively — so it is a
/// real part of the document and not a thing anyone can subscribe to. Listing
/// it here would read as one.
fn event_names(schema: &serde_json::Value) -> Vec<String> {
    schema["schemas"]["event"]["oneOf"]
        .as_array()
        .unwrap_or(&Vec::new())
        .iter()
        .filter_map(|variant| variant["properties"]["ev"]["const"].as_str())
        .filter(|name| *name != "unknown")
        .map(str::to_string)
        .collect()
}

/// One titled block of op names, wrapped to a terminal width and grouped by the
/// prefix the protocol already uses (`fs_`, `git_`, `upload_`) so a reader
/// looking for the file verbs finds them together.
fn section(title: &str, names: &[String]) -> String {
    if names.is_empty() {
        return String::new();
    }
    let mut out = format!("\n{title} ({})\n", names.len());
    let mut grouped: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for name in names {
        let prefix = match name.split_once('_') {
            Some((head, _)) if PREFIXES.contains(&head) => head,
            _ => "",
        };
        grouped.entry(prefix).or_default().push(name);
    }
    for (prefix, mut members) in grouped {
        members.sort_unstable();
        let label = if prefix.is_empty() { "" } else { prefix };
        out.push_str(&wrap(label, &members));
    }
    out
}

/// The prefixes worth grouping under. Deliberately a short list rather than
/// "every prefix with more than one member": `hello_ok` and `hello_err` are the
/// handshake, not a `hello` family, and splitting them out would read as one.
const PREFIXES: &[&str] = &["fs", "git", "upload"];

fn wrap(label: &str, names: &[&str]) -> String {
    let indent = if label.is_empty() {
        "  ".to_string()
    } else {
        format!("  {label:<8}")
    };
    let continuation = " ".repeat(indent.chars().count());
    let mut out = String::new();
    let mut line = indent;
    let mut empty = true;
    for name in names {
        if !empty && line.chars().count() + name.len() + 2 > 78 {
            out.push_str(line.trim_end());
            out.push('\n');
            line = continuation.clone();
            empty = true;
        }
        if !empty {
            line.push_str(", ");
        }
        line.push_str(name);
        empty = false;
    }
    out.push_str(line.trim_end());
    out.push('\n');
    out
}
