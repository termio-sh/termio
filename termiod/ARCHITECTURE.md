# termiod architecture

> **A session lives in a host. Viewers only attach.**  
> **Composable** · **Direct.**

| | Composable | Direct |
| --- | --- | --- |
| | Host · protocol · clients · pipes plug independently | One hop: client → protocol → host → PTY |
| | Any client, any pipe, any host | No second session owner, no nested WM, no invented crypto |

Local is remote to localhost. Design: `docs/design/20260730-termiod-session-mux.md`.

## Three parts

```
   CLIENTS                         PROTOCOL                      HOST
   (stateless)                     (versioned)                   (authority)
┌──────────────┐              ┌─────────────────┐          ┌──────────────┐
│ termio.app   │──┐           │ attach / detach │          │   termiod    │
│ TermioMobile │  │  transport│ create / list   │  always  │ session table│
│ CLI (ref)    │──┼──────────►│ I/O · resize    │─────────►│ owns PTYs    │
│ (web later)  │  │  (pipe)   │ status · roster │          │ (later: vt)  │
└──────────────┘──┘           └─────────────────┘          └──────┬───────┘
                                                                  │
                                                                  ▼
                                                         shell / agent
```

| Part | What it is | What it is not |
| --- | --- | --- |
| **Host** | Long-lived process on a machine; owns every session PTY | A public TCP service; a window manager |
| **Protocol** | Framed control + terminal bytes (v0); later snapshots/diffs | Tied to SSH or Unix sockets |
| **Clients** | Viewers that attach/detach | Owners of process lifetime |

**Transport** is not a fourth product. It is how protocol bytes move:

| Pipe | Use |
| --- | --- |
| Unix socket | Host on this machine |
| System SSH | Host on a VPS / devbox (auth + crypto for free) |
| WSS / relay | Phone / hostile networks (optional) |

## Hard rules

1. **Host ≠ viewer** — closing every client leaves sessions alive.  
2. **PTY only on the host** — clients never allocate the agent’s TTY.  
3. **SSH is a pipe** — never `ssh -tt host claude` as the product path.  
4. **No nested WM** — tabs/splits belong to the OS / native app (zmx).  
5. **No invented crypto** — build host + protocol only.

## Vocabulary

| Say | Don’t say |
| --- | --- |
| host / daemon / `termiod` | “the CLI tool” (as the architecture) |
| attach client | “the SSH session” (for our session object) |
| transport / pipe | “remote mode that owns the agent” |

The shipped binary is host **and** a reference CLI client (tmux/zmx packaging). That does not change the model: **`termiod serve` is the product core; `attach` is a client.**

## Data path (v0.1 POC)

```
client ──► pipe ──► termiod ──► PTY ──► agent
                │
                └── fan-out to other clients
                └── ring replay on reattach
```

- Hot path: raw PTY bytes over the pipe.  
- Every negotiated channel starts with `hello`; a no-`hello` v0 control frame
  enters legacy mode with no capabilities.
- One interactive attachment owns the write/resize token. A newer interactive
  claim demotes (but does not detach) the prior writer; observers never claim.
- `E` frames fan out status, writer, resize, exit, and roster deltas. A
  control channel can subscribe without attaching to a PTY.
- VT / libghostty snapshot: **later** (host-side sidecar for resync), not in the critical path for every keystroke.

## Protocol v0.1 contract

```
[ kind:u8 ][ len:u32 big-endian ][ payload ]
```

| Kind | Payload | Plane |
| --- | --- | --- |
| `C` | JSON object tagged by `op` | lifecycle/control |
| `D` | raw bytes, ≤64 KiB per emitted frame | terminal |
| `R` | `rows:u16 BE · cols:u16 BE` | terminal |
| `E` | JSON object tagged by `ev` | events |

Reads reject frames above 16 MiB. Unknown JSON operations/events are additive
and ignored; unknown kinds close the channel after `proto_error`.

Negotiated clients advertise a protocol range, channel role, and
capabilities in `hello`. Protocol 1 currently offers `events` and
`send_wait`. The reply supplies a stable random `host_id` (persisted as
`host.id` beside the Unix socket) and a per-connection `client_id`.
Incompatible ranges are refused; legacy v0 first operations remain accepted.

Optional request `seq` is echoed by response `re`. The control channel stays
open for multiplexed requests, roster/status subscriptions, and asynchronous
wait results. Session records carry optional workstream metadata and live
`status`, `title`, `attached_clients`, and `writer_client_id` fields.

## Remote

```
Mac client ── ssh ──► Linux termiod ── PTY ──► agent
```

Same protocol as local. Daemon on the VPS auto-starts (or runs under systemd `--user`). SSH disconnect detaches the client; it does not kill the session.

## Map to source

| Module | Part |
| --- | --- |
| `daemon.rs` · `session.rs` · `pty.rs` | Host |
| `protocol.rs` | v0/v0.1 codecs, handshake/control/event types, frame limits |
| `client.rs` · CLI in `main.rs` | Reference client |
| `remote.rs` | Transport helper (SSH deploy / stdio bridge) |
| `paths.rs` | Socket location |

## Three-step product sequence

1. **Incredible host** — durable multi-session runtime (**direct**).  
2. **Composable agent surface** — status, worktrees, tools as real protocol clients (**composable**).  
3. **Multi-device operable** — Mac/iOS, discovery, optional relay — still direct pipes, no required cloud.

Superlogical: *mux → composable → production*. We keep **composable** and insist on **direct**.
