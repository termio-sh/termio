---
title: termiod Session Protocol
status: draft
type: design
created: 2026-07-30
updated: 2026-08-16
related:
  - 20260730-termiod-session-mux.md
  - 20260708-session-daemon-architecture.md
  - 20260730-_research-session-protocol-brief.md
---

<!-- 2026-07-31: hardened the input-replication vs state-sync framing (§A core
mental model + anti-100× invariant), clarified the two roles of state transfer
and the `S` snapshot triggers (§C.6), and linked the empirical anti-100×
benchmark (termiod/bench). Later same day, folded in a Codex implementation
review vs Mitchell's Superlogical talk: the authoritative-PTY-dimensions
correctness requirement (§C.5), and risks #10 (unbounded per-client backlog)
and #11 (resize is not a barrier).
2026-08-04: added §C.10 resumable subscriptions — the terminal plane's
durable-object-plus-cursor pattern generalised so files/git/agent state inherit
one reconnect story; added Workspace and Resource to §B and the two verbs to
§C.4. Implemented for `fs:` in `termiod/src/resource.rs`.
2026-08-05: corrected §D's ControlMaster claim (documented, never implemented);
made the head-of-line cost a criterion that scales with attached-session count
rather than a WAN adjective; qualified §D.1's roaming argument now that a
tailnet supplies migration to plain TCP; recorded why WebTransport stays
refused *even though* a web client is now planned (§D.1); split §F #2's "own
SSH" into the three senses it was conflating; added §C.11, the spawn-environment
half of the presentation boundary.
2026-08-07: added §C.12 (file request plane — lazy+cached+predictive listings,
`fs.read`/`fs.search`/`fs.match` with a coverage-honest host name index, and
the chunked `upload.*` verbs with HOL discipline) and §C.13 (`git:` resource
kind — Zed's two-axis status vocabulary, read-only, one event shape + `git.diff`),
from a design pass against Zed's replicate-everything remote worktree model.
2026-08-07 (later): §C.12 and §C.13 implemented in termiod
(`59b5b7a`..`f1d8871`), with four deviations from the text as written:
(1) §C.13's status trigger is any watcher batch, not only `git_meta` — a
worktree edit changes `git status` without touching `.git`, so the narrower
trigger goes stale on exactly the edits the pane exists to show; runs use
`--no-optional-locks` so status itself cannot re-trigger the watcher.
(2) §C.13 gap semantics: a subscriber whose cursor cannot replay is served a
synthetic full-state `git_changed` at the current cursor — "rescan before
applying" done host-side, because only the host can compute git status.
(3) §C.12 `upload.open` carries two extra fields the shape omitted: `root`
for project dests and `session` for `temp:` dests — the host cannot anchor
confinement (or reap scratch with its session) without being told which.
(4) cancellation of `fs.search` is a generic `cancel {request}` verb rather
than a search-specific one, since request ids are already protocol-wide; and
the `git:` kind is gated on a `git` capability, parallel to `fs_watch`.
2026-08-13: §C.6 gained the snapshot-prologue rule (delta D2 of
`20260805-termiod-hot-path-and-client-classes.md`) — the `S` payload carries its
own scoped reset and clients apply it raw. Implemented in `VtTerminal::format_vt`
with `termiod/tests/snapshot_prologue.rs` as the acceptance test; the reference
client and the Mac client stopped synthesising preludes of their own. -->


# Design: termiod Session Protocol

> One transport-agnostic protocol between attach clients and the `termiod`
> session host: framed channels, `hello`-negotiated capabilities, raw-PTY hot
> path staged toward snapshots and diffs, agent workstreams as first-class
> events. Unix socket and SSH are the product transports; QUIC and WSS bind
> the *same* messages later. Product/competitive framing:
> [termiod-session-mux.md](20260730-termiod-session-mux.md); host architecture:
> [session-daemon-architecture.md](20260708-session-daemon-architecture.md).

**Evidence policy:** every Superlogical statement in this doc is labeled
**Announced** (superlogical.com / Mitchell's post), **Inferred**, or
**Unknown**. Superlogical has published no wire protocol, RPC schema, or
SSH/QUIC internals; nothing here guesses at them.

---

## A. Executive recommendation

The Session Protocol is a **small framed message contract over ordered,
reliable, bidirectional byte channels** — not an RPC framework, not a
transport. It has four nouns (host, session, workstream, client), two channel
roles (control, attach), and three payload planes (control JSON, terminal
bytes/diffs, agent events). Every transport — Unix socket, SSH stdio, QUIC,
WSS — supplies channels; none of them ever changes a message.

**The core mental model — input replication, not state synchronization.**
A VT parser is a deterministic state machine: the same bytes in produce the
same screen out. So the host keeps every viewer consistent by **shipping the
log** (raw PTY bytes to every client, which each replay through their own
`libghostty`) — *not* by shipping the state (a server-maintained grid diffed
to clients). This is state-machine replication in the database sense: replicate
the input, replay deterministically, and snapshot only to bootstrap a replica
that missed the start. tmux does the opposite — it parses every byte into an
authoritative grid and diffs *that* to clients — which is precisely why a slow
middle emulator throttles the whole pipe. Our load-bearing invariant follows:

> **Anti-100× invariant: byte delivery MUST NOT block on host-side VT parse.**
> The host tees raw bytes to clients and to its ring the instant it reads them;
> the authoritative VT (v1) is a **sidecar** consulted only to build snapshots,
> off the hot path. Any design that puts a per-frame grid encoder between the
> PTY and the pipe rebuilds the tmux tax and is rejected.

Empirically confirmed: `termiod/bench/bench_100x.py` measures termiod at
**4.4–6.0× tmux's throughput** on the same byte stream, and — the real tell —
tmux's throughput falls ~50% from plain to ANSI-heavy payloads (a parser is
content-sensitive) while termiod's barely moves (a tee is not). State sync is
not the engine; it is two edge cases (§C.6): a one-shot bootstrap and an
opt-in bad-network degrade.

- **Now (v0.1):** freeze the POC's 5-byte framing; add `hello`/capabilities,
  request ids, a typed error model, and an event frame kind. Transports:
  Unix socket (local default), system SSH stdio (remote default).
- **v1:** host-side `libghostty-vt` becomes terminal-state authority; attach
  and resize resync via **snapshot** frames; raw bytes remain the steady-state
  hot path.
- **v1.1:** capability-gated **dirty-row diffs** replace raw bytes for clients
  that negotiate them (phone first).
- **Later, only if earned:** QUIC (roaming/multi-stream, identity borrowed
  from Tailscale or pairing-pinned certs — never DIY PKI) and WSS relay
  (phone through hostile NAT, relay as blind pipe).

One-sentence differentiator vs Superlogical's mux layer: **Superlogical is
building a general multiplexer for all work (Announced); Termio's protocol is
deliberately narrower — an agent-native session contract where `working` /
`needs-you` / approvals are wire events, running local-first over pipes the
user already trusts.**

## B. Domain model

```
Host 1 ──< Workspace 1 ──< Session 1 ──? Workstream   (workstream = agent overlay, optional)
    │                          │
    │                          └──< Attachment >── Client  (N viewers per session)
    └──< Resource >── Client                        (§C.10, resumable, workspace-scoped)
```

| Noun | What it is | Identity | Lifetime |
| --- | --- | --- | --- |
| **Host** | One `termiod` process on one machine; owns every PTY and the session table | `host_id`: stable random 128-bit, minted on first run, stored beside the socket | Daemon process (launchd/systemd `--user`); survives all clients |
| **Session** | Durable runtime: PTY + process + (v1) vt state + ring/scrollback | `session_id`: host-scoped ULID; `name` is a mutable human alias, never an identity | From `create` until process exit or `kill`. **Detach never ends it** |
| **Workstream** | Agent metadata over a session: `agent_id`, project/worktree, `status` (`working·idle·needs_you·done·failed·unknown`), pending approval, title | Same `session_id`; workstream fields are session attributes, not a second object to address | Attached at create or promoted later (agent detection); removed on demotion to plain shell |
| **Workspace** | A directory root on the host that sessions and non-terminal state are scoped to (a project or worktree). Not a container for processes — a *scope* for filesystem, git, and watch state | Canonicalised absolute path; two spellings of one root are one workspace | Implicit: exists while anything references it. Never created or destroyed explicitly |
| **Resource** | Durable host-side state a client subscribes to with a replayable cursor (§C.10): `fs:<workspace>` in v1, git/status later | `<kind>:<scope>`; `seq` is its monotonic cursor | Independent of any connection **or** client; lingers past its last subscriber |
| **Client** | One viewer/controller endpoint (Mac app, iOS, CLI, tool) | `client_id` per *connection*, assigned by host at `hello`; clients may also send a stable `client_name` for display | Connection lifetime; nothing a client holds is load-bearing |
| **Transport endpoint** | Where a host is reachable: `unix:<path>` · `ssh:<host>` · later `quic:<addr>` · `wss:<url>` | Resolved by discovery (`HostRef → Endpoint`); opaque to the protocol | Config lifetime |

**Detach vs kill:** `detach` closes an attachment; the session (and the
agent inside it) keeps running and its terminal state keeps advancing.
`kill` ends the process. The CLI verb mapping is `close` → kill,
window-close → detach. This distinction is the whole point of the host and is
non-negotiable in every client UI.

**Why workstream ≠ session:** a plain shell has no workstream; an agent
session has exactly one. Folding agent fields into the session record (rather
than a second addressable object) keeps the protocol at four nouns and makes
"agent-native" a *field set plus an event type*, not a parallel API.

## C. Session Protocol specification

### C.1 Channels and roles

A **channel** is an ordered, reliable, bidirectional byte stream carrying
frames. Transports provide channels; the protocol defines two roles, declared
in `hello`:

| Role | Purpose | Cardinality |
| --- | --- | --- |
| `control` | list / create / kill / `send` / roster subscription / agent events / waits | Usually one long-lived channel per client |
| `attach` | Exactly one session's terminal plane: data, resize, snapshots, plus that session's events | One channel per attached session |

This split is what lets a status tray, `termio sessions watch`, and an iOS
roster exist **without a TTY attach** — and it maps 1:1 onto QUIC streams
later (§D.3). A minimal client (the POC CLI today) may open only an `attach`
channel; `attach` channels accept the lifecycle requests too, so v0 clients
stay valid.

### C.2 Framing (frozen from POC v0)

```
[ kind: u8 ][ len: u32 big-endian ][ payload: len bytes ]
```

| Kind | Byte | Payload | Plane | Since |
| --- | --- | --- | --- | --- |
| Control | `C` | JSON object (`op`-tagged) | control | v0 |
| Data | `D` | raw PTY bytes, both directions | terminal | v0 |
| Resize | `R` | rows u16 BE · cols u16 BE | terminal | v0 |
| Event | `E` | JSON object (`ev`-tagged) | events | v0.1 |
| Snapshot | `S` | binary: header + packed vt cells (§C.6) | terminal | v1 |
| History | `H` | binary: newest-first scrollback rows (§C.6) | terminal | v1 |
| Diff (POC shipped) | `G` | binary: dirty-row grid update (§C.6) | terminal | v1.1 |

Rules: unknown *control ops* and *event types* are ignored (additive
evolution); unknown *frame kinds* are a protocol error → `proto_error` +
close (a frame kind changes how bytes parse; silently skipping risks
desync). Max frame 16 MiB; `D` frames should stay ≤ 64 KiB (write coalescing,
fair fan-out). JSON for control is deliberate: control is low-rate, and
debuggability beats micro-efficiency. The hot path never pays for it — `D`,
`S`, `G` are binary.

### C.3 `hello` / capabilities / versioning

First frame in each direction on **every** channel, before anything else:

```json
→ {"op":"hello","proto":1,"min_proto":1,"role":"attach",
   "caps":["events","snapshot"],"client":"termio-mac/0.22.0"}
← {"op":"hello_ok","proto":1,"caps":["events","snapshot"],
   "host_id":"h_9f3k…","host":"termiod/0.3.0 linux-arm64","client_id":"c_41"}
```

- **`proto` is the protocol version; binary versions are cosmetic.** Host and
  client each advertise `[min_proto, proto]`; the session runs at the highest
  common version. No overlap → `hello_err {code:"incompatible", supported:[…]}`
  and immediate close. **Hard refuse, never limp** — a half-understood session
  stream corrupts terminals (the weak-IPC-upgrade failure mode the companion
  wire taught us).
- **`caps` are additive feature flags**, intersected: `events`, `snapshot`,
  `grid_diff`, `send_wait`, `approvals`, later `share`, `file`, `git`. New
  nouns arrive as capabilities inside `proto:1` for as long as additivity
  holds; `proto:2` is reserved for breaking framing/semantics changes.
- Compatibility matrix commitment: **old client × new host and new client ×
  old host both work at the intersection** for all of `proto:1`. Golden-file
  codec tests + a state-machine test that replays recorded attach/reattach/
  resize transcripts against both directions of skew (POC smoke tests grow
  into this).

Frozen in v0: framing, `C`/`D`/`R` semantics, `Attach`/`Create`/`List`/
`Kill`/`Send`/`Detach` ops. Deliberately unstable until v1 ships: snapshot
encoding, event field details beyond `ev`/`session`, workstream field names.

### C.4 Control catalog (proto 1)

Requests carry `seq` (client-chosen int); responses echo `re` — this is what
makes one control channel safely multiplexable. Ops marked ✦ exist in POC v0.

| Op | Direction | Notes |
| --- | --- | --- |
| `hello` / `hello_ok` / `hello_err` | both | §C.3 |
| `create` ✦ | c→h | `CreateSpec {name?, cwd?, argv, env, rows, cols, workstream?}` — `workstream {agent_id, project, worktree?}` is new |
| `list` ✦ / `sessions` ✦ | c→h / h→c | `SessionInfo` gains `status`, `agent_id`, `title`, `attached_clients`, `writer_client_id` |
| `attach` ✦ / `attached` ✦ | c→h / h→c | `{target, mode:"interact"|"observe", create_if_missing?, rows, cols}`; reply carries `session_id`, `writer` (bool), and (v1) is followed by one `S` frame |
| `detach` ✦ | c→h | Leave stream; session lives |
| `kill` ✦ | c→h | End process; every attachment gets `session_exited` |
| `send` ✦ | c→h | Inject bytes without attaching — the `termio sessions send` path, now first-class |
| `wait` | c→h | `{target, until:["needs_you","idle","done","exited"], timeout_ms}` → `wait_result`; gives `send --wait` real semantics instead of transcript polling |
| `subscribe` | c→h | `{events:["roster","status"]}` on a control channel → stream of `E` frames for all sessions |
| `subscribe_resource` / `subscribed` | c→h / h→c | §C.10. `{resource, since?}` → `{resource, seq, gap}`; replayed `E` frames follow the reply. Gated on the `resources` capability |
| `unsubscribe_resource` | c→h | Release interest; the resource lingers for other subscribers and for this client's own return |
| `resize_claim` | h→c | Informs a demoted client who owns size now (§C.5) |
| `ok` ✦ / `error` ✦ | h→c | §C.7 |

### C.5 Attach flow, writer policy, resize policy

**Attach (same messages on every transport):**

1. channel opens → `hello` exchange (role `attach`)
2. `attach {target, mode, rows, cols}`
3. `attached {session_id, writer:true|false, rows, cols}` — **must carry the
   authoritative PTY dimensions** (see below)
4. resync: v0 = ring-buffer replay as `D` frames; v1 = one `S` snapshot
   (viewport + cursor + title + a scrollback slice), then live `D` (or `G`)
5. steady state: `D`/`R` up, `D`/`S`/`G`/`E` down
6. `detach` (or channel death — equivalent) → session unaffected

**Invariant JOIN — the attach boundary is exact, and the PTY never pauses.**
For each attaching client there is exactly one boundary B in the session's
output byte stream such that the `S` payload reflects the terminal after
applying every byte before B, and the client receives every byte from B onward,
in order, exactly once. B is established by enqueueing `Snapshot` on the sidecar
FIFO in the same critical section that flips the client to `SnapshotPending`, so
the snapshot boundary is "after every `Write` enqueued before this `Snapshot`"
and the per-client buffer starts at the same instant. **The FIFO is the sequence
number** — which is why no cursor rides the wire (a per-`D` sequence would tax
the one path §A exists to keep free, and the client could not act on it anyway,
because the host has already done the filtering).

Three corollaries, each load bearing:

1. **The sidecar channel must be lossless and ordered with respect to `Write`.**
   If bytes destined for the VT can be dropped or reordered, B stops existing
   and `S` silently describes a screen that never occurred. The permitted
   degrade under queue pressure is therefore never "drop bytes to the VT" — it
   is to mark the VT stale and refuse snapshots, falling back to ring replay.
2. **Snapshot failure falls back to ring replay, and that fallback is lossy.**
   `RING_CAP` is 128 KiB, so a client resynced from the ring alone can land
   mid-escape. It must be reported, not silent.
3. **Resize is the same barrier, not a second mechanism.** `Resize` and the
   per-client `Snapshot` land adjacently on the FIFO with no intervening
   `Write`, and `TIOCSWINSZ` failure surfaces before stored dimensions move.

`termiod/tests/join_invariant.rs` is the acceptance test: a second client
attaches mid-flood of a monotonic counter, and the sequence must run unbroken
from the last complete line on the snapshot screen into the first line of the
buffered stream. The flood must be unbroken — a paced one lets the attach land
in a gap, where an empty buffer hides a broken barrier.

**Every client parses at the authoritative PTY dimensions — this is a
correctness requirement, not a preference.** Input replication is only
deterministic if the replicas run the same state machine on the same input,
and a VT parser's output depends on its *width*: wrap points, `\r\n` handling,
and DECAWM autowrap all key off the column count. An observer whose terminal is
a different size than the PTY will wrap the identical byte stream differently
and diverge — the synchronized-state-machine guarantee silently breaks. So:
`attached` (and the v1 `S` snapshot) **carry `rows`/`cols`**, and a smart client
maintains an internal grid at *authoritative PTY dimensions* with its own
*local* viewport layered on top (letterbox / scale / scroll) — never by parsing
at its own window size. *(`Attached` carries `rows`/`cols` as of Phase 1c. The
residual gap is client conformance, not the wire: the reference client still
ignores `Resized`/`WriterChanged` (`client.rs`) — acceptable for a single
same-size CLI, incorrect the moment a second differently-sized viewer
attaches.)*

**Writer policy — single writer, newest claim, observable.** Any
`mode:"interact"` attach takes the write token; the previous writer stays
attached but demoted, and *everyone* on the session gets
`E {ev:"writer_changed", writer:"c_41"}`. Observers' `D`/`R` frames are
answered with `error {code:"not_writer"}` rather than dropped. This is the
POC behavior formalized plus notification. CRDT/multi-caret input is
explicitly rejected (§H); the write token is also the natural place a future
share ACL plugs in without new message shapes.

**Resize policy — the PTY has one size and the writer owns it.** `R` from the
writer resizes PTY + vt and fan-outs `E {ev:"resized"}`; in v1 a resize is a
barrier: quiesce, resize, emit fresh `S`, resume deltas (the ghostty-web
lesson). `R` from observers → `not_writer`; observer UIs letterbox or scale
client-side. Per-client server-side reflow is rejected — it means one vt per
viewer per session, which is a nested-window-manager tax in disguise.

### C.6 Terminal plane staging

The default steady state is **raw `D` bytes** — input replication (§A). A v1.1
client may instead opt into `G` after bootstrap; state transfer appears in two
roles: a one-shot **bootstrap** for a replica that missed the log, and an opt-in
**bad-network degrade**.

| Stage | Steady state | State transfer (when) | Who parses VT |
| --- | --- | --- | --- |
| v0 | raw `D` bytes | bootstrap = ring replay (`D`) on attach | every client |
| v1 | raw `D` bytes | bootstrap = one `S` snapshot on attach/resize/resync | host (sidecar) + every client on live bytes |
| v1.1 | raw `D` bytes, **or** `G` dirty-row diffs for clients that negotiate `grid_diff` | `S` keyframe + `G` deltas | host, only for `grid_diff` clients |

**When state transfer fires (`S` snapshot triggers) — boundaries only, never
per frame:** (1) **attach** — a new viewer missed the byte log, so bootstrap it
with one state frame, then it follows raw `D`; (2) **resize** — the writer
changes PTY size, a barrier quiesces, resizes, emits a fresh `S`, resumes
deltas; (3) **desync / host restart recovery**; (4) in v1.1 diff mode only, a
**periodic keyframe** to bound drift. Steady-state typing and output never
snapshot — that would be the tmux tax.

Clients that negotiate both `snapshot` and `scrollback` receive staged history
on attach only. The sidecar captures it at the same in-band boundary as `S`,
keeps at most 1 MiB of encoded rows with the newest rows winning, then emits
small newest-first `H` chunks after `ready` so live `D` can interleave. Resize
snapshots do not restage history; reflow semantics remain a later decision.

`S`/`G` carry packed cells + per-row damage. **The wire cell is defined by
termiod and is engine-independent — it is NOT the VT engine's in-memory cell**
(corrected 2026-07-31 by the #181 de-risk spike, `20260731-termiod-vt-sidecar-spike.md`).
The earlier assumption that "the C struct doubles as the wire cell" is false:
libghostty-vt 1.3.2 exposes render-state cell iteration + per-row dirty tracking
(enough to *build* `S`/`G`) but its cells are **opaque**, with no wire-ready
16-byte packed cell and no one-call viewport snapshot — a conversion step is
required regardless of engine. **v1 engine DECISION (2026-07-31): `libghostty-vt`**,
FFI'd into the Rust host. The spike's build-convenience pick was
`alacritty_terminal`, but that was overridden on a **correctness** ground: every
Termio client *is* libghostty (Mac embeds it, iOS mirrors it), and the
"synchronized distributed state machines" model only holds if the host authority
runs the **same** VT — a different engine (alacritty) can diverge on grapheme /
width / autowrap / obscure-escape handling, so its `S` snapshot would not match
what a libghostty client renders. Fidelity parity with the clients is the whole
point (Mitchell's "assume libghostty everywhere"), so we accept the Zig 0.15.2 +
FFI cost. Keep the opaque-cell → wire-cell conversion behind an engine-neutral
boundary anyway. The vt stays a **host-side authority/sidecar for resync**, never
a per-keystroke re-encoder in the middle of every pipe (the anti-100× invariant,
§A). Build path (from the #181 spike): vendor libghostty-vt 1.3.2 + a `build.rs`
that invokes Zig (herdr's pattern), bindgen `ghostty/vt.h`, link the static lib,
cross-compile to aarch64-musl. Phase 0 = an FFI build proof before daemon
integration.

**The `S` snapshot carries VT sequences, not resolved cells (format v2).** The
host serialises the screen with libghostty-vt's own formatter
(`ghostty_formatter_*`, `emit = VT`) and the client feeds those bytes straight
into its terminal. This is not an encoding preference — it is the boundary the
whole architecture rests on: **the client's libghostty is the style authority,
never the host.** Packed 16-byte cells (v1) forced the host to resolve every
colour against *its* palette, which overrode the viewer's theme, silently
dropped bold/underline (the `attributes` field was reserved-zero) and lost
OSC 8. Concretely the formatter emits `38;5;N` palette indices, so the viewer's
own ANSI colours apply; `palette` (OSC 4) is deliberately **off**, because
emitting it would push the host's colours onto every client. Measured on a
10×40 screen: 559 bytes of VT against 6,504 bytes of cells — 11.6× smaller and
strictly more faithful.

One caveat worth keeping: the formatter emits the cursor's CUP *before* state
extras, and some extras move the cursor as a side effect (`tabstops` walks the
row with CHA/HTS; DECSTBM homes it). The host re-asserts the true position with
a trailing CUP.

**The `S` payload carries its own prologue, and clients MUST apply it raw.**
Applying one snapshot to a client screen in any prior state must land where
applying it to a fresh terminal would; a client that prepends its own reset
cannot deliver that, because the state that actually breaks a repaint is mode
state, not screen content. The formatter alone does not deliver it either: it
emits only state the host *has* — `ESC[?1049h` for an alt-screen session,
`ESC(0` for a shifted charset, `ESC[?6h` for origin mode — never the negation,
and it paints relative to wherever the cursor already sits. Measured, a client
in five ordinary states (stale content, alt-screen, origin mode, a shifted
charset, a pending SGR) reached a different screen than a fresh one. So the host
prepends a scoped reset: `DECSTR` for what is not enumerated, then explicit
primary-screen / SGR / charset / origin-mode / autowrap / insert-mode /
reverse-video / margin resets, then erase-and-home. It stops short of `RIS`,
which would clear what the client owns — palette, title, scrollback. Nothing in
the prologue is host state the payload does not immediately restate. Acceptance
test: `termiod/tests/snapshot_prologue.rs`, one case per state, plus the reverse
direction (an alt-screen host must still land its client on the alternate
screen). *(libghostty's own `DECSTR` was measured incomplete — SGR, charsets,
origin mode and autowrap survive it — which is why the explicit resets follow
it rather than trusting it.)*

Format v1 survives **only** for `grid_diff` clients, whose model is explicitly
server-side state and which need cells to seed their grid.

**v1.1 `G` diffs are the bad-network degrade, not a faster default.** They are
capability-gated (`grid_diff` requires `snapshot`), phone-first, and are the
*same mechanism* as the QUIC state-sync layer in §D.1 — supersedable dirty rows
where a newer row version obsoletes an older one. After `S` + `ready`, a
grid-diff client receives no downstream `D`: each version-1 `G` carries a
monotonic per-session `frame_seq`, authoritative rows/cols and cursor/screen
state, then full 16-byte wire cells for each dirty row. Every 256 damage
flushes by default (test-overridable with `TERMIOD_KEYFRAME_EVERY`), the host
substitutes an ordered `S` + `ready` keyframe and then resumes increasing-seq
`G`. This is mosh's SSP rebuilt on standard transport.
On a good link (LAN, good Wi-Fi) raw byte replication wins outright and no
client should negotiate `grid_diff`; the diff path exists because a *reliable
ordered* byte stream must deliver every intermediate byte in order, which a
lossy high-RTT phone link cannot do cheaply — there, shipping "the latest row
state" is the win.

**Measured, so nobody re-derives it the hard way** (2026-08-05, framed protocol
over SSH to the `ukvps` aarch64 host, identical 300-line scrolling burst):

| Plane | Bytes on the wire | Frames |
| --- | --- | --- |
| raw `D` | **50,423** | 16 |
| `G` dirty rows | **435,573** | 18 |

`G` cost **8.6× more**, not less. Two compounding reasons, both structural:
scrolling output dirties *every* row, so dirty-row filtering filters nothing;
and each cell is 16 wire bytes against roughly one byte of source text, so what
remains is a ~16× encoding inflation. Terminal output is dominated by
scrolling, so this is the common case, not a corner.

The consequence for transport policy: **"remote ⇒ prefer `G`" is wrong.** `G`
is not a bandwidth optimisation at all. It buys two other things: a *bound*
(cost is capped at frame-rate × screen regardless of how much the PTY emits, so
a `yes` flood cannot melt a metered link) and *catch-up* (a client that has
fallen behind skips intermediate states instead of replaying them). Select it
on backlog pressure or measured loss — never on "this connection is remote".
A worthwhile future change is compressing the wire cell (run-length spans,
style separated from text); at 16 bytes per cell the format, not the idea, is
what makes `G` expensive. The current reliable transport delivers every emitted `G`,
but each `G` already coalesces source bytes into current full-row state; a QUIC
binding may later discard superseded row versions (§D.1). It coexists with the
byte path; it never replaces it. Paired with client-side predictive echo
(§D.1), this is what makes a 100 ms-RTT link *feel* local — the piece no
transport choice (SSH or QUIC) can deliver alone.

### C.7 Error model

```json
{"op":"error","re":7,"code":"no_such_session","message":"…","retryable":false}
```

Closed `code` vocabulary (extensible additively): `incompatible`,
`proto_error`, `no_such_session`, `not_writer`, `already_exited`,
`create_failed`, `denied`, `busy`, `internal`. Three severities: request
errors (respond, keep channel), channel errors (`proto_error` → close channel,
sessions unaffected), host errors (host restart → clients reconnect, sessions
are the durable thing that makes this survivable). Channel death mid-frame is
always safe: framing is self-delimiting and no request is applied twice
(`create` idempotency via client-supplied `seq` + connection scope; `kill` is
naturally idempotent).

### C.8 Security-sensitive fields

| Field | Risk | Rule |
| --- | --- | --- |
| `CreateSpec.env`, `argv` | API keys, tokens | Never logged; never echoed in `SessionInfo`; **never traverses a third-party relay un-encrypted-end-to-end** |
| `D`/`S`/`G` payloads | The work itself | Same relay rule; host never persists beyond ring/scrollback |
| `send.data` | Injected secrets | Same as `D` |
| Approval payloads (tool args, diffs) | Code + paths | Carried only on channels whose transport authenticates the *user* (Unix perms, SSH identity, paired device) |
| `host_id`, socket paths | Fingerprinting | Fine locally; don't publish through relays |

Baseline stance (unchanged from the mux doc): default listen is **Unix socket
only**, `0700` runtime dir; no TCP bind by default; relays are optional and
blind (§D.4).

### C.9 Wire example — same messages, three pipes

```
# local            : termio.app ── unix socket ──────────────► termiod (Mac)
# remote           : termio.app ── ssh vps "termiod stdio" ──► termiod (VPS)
# future QUIC      : termio.app ── quic stream N ────────────► termiod (VPS)

→ hello {proto:1, role:"attach", caps:["events","snapshot"]}
← hello_ok {proto:1, caps:["events","snapshot"], host_id:"h_9f3k", client_id:"c_7"}
→ attach {target:"fix-issue-164", mode:"interact", rows:48, cols:180,
          create_if_missing:{argv:["claude"], cwd:"~/work/termio-w1",
          workstream:{agent_id:"claude", project:"termio", worktree:"w1"}}}
← attached {session_id:"s_01J…", writer:true}
← S ▸ snapshot: viewport 48×180 + cursor + title + scrollback slice   (v1)
← D ▸ live PTY bytes …            → D ▸ keystrokes …    → R ▸ 50×190
← E {ev:"status", session:"s_01J…", status:"needs_you",
     approval:{id:"a_3", tool:"Bash", summary:"rm -rf node_modules"}}
→ (control channel) send {target:"s_01J…", data:"1\n"}   ← ok
```

The transport rows differ; every frame after them is byte-identical. That is
the acceptance test for "transport-agnostic": **a recorded local session
transcript must replay verbatim against an SSH-piped host.**

### C.10 Resumable subscriptions (the generalised reconnect)

The terminal plane already solved reconnect once: a session is a durable object
with an id, a monotonic cursor, a bounded ring, and `S` to bootstrap a replica
that missed the start. **§C.10 makes that one mechanism instead of one
terminal feature**, so every later plane — files, git, agent state — inherits
the same reconnect story rather than inventing its own. Without it, the file
plane grows a bespoke "re-sync on reconnect" path and we have rebuilt the
four-code-paths disease *inside* the host.

**A resource** is durable host-side state a client observes. It has:

| Property | Rule |
| --- | --- |
| **Id** | `<kind>:<scope>`, host-unique and stable across connections. v1 kind: `fs:<canonical workspace root>` |
| **Cursor** | `seq`, monotonic per resource, starting at 1. Never reused, never rewound |
| **Ring** | A bounded replay buffer of recent batches. Overflow is *reported*, never silent |
| **Lifetime** | Independent of any connection **or client**. A watch outlives its last subscriber by a linger window — detach ≠ kill, applied to the resource plane |

**The one verb:**

```
→ subscribe_resource {resource:"/work/termio", since?:41}
← subscribed {resource:"fs:/work/termio", seq:44, gap:false}
← E {ev:"fs_changed", resource:"fs:/work/termio", seq:42, paths:["/work/termio/src"]}
← E {ev:"fs_changed", …, seq:43, git_meta:true}
← E {ev:"fs_changed", …, seq:44, paths:["/work/termio/docs"]}
   … then live batches continue from 45
```

`gap:true` means the client's baseline is unusable and it must do a full scan
before applying anything further. It is returned for a first subscribe, for a
`since` that has aged out of the ring, and for a `since` ahead of the host.
**The reply always precedes replayed events**, so a client knows whether to
rescan before it starts applying them.

**Reconnect is therefore not a feature.** It is: open a pipe, re-subscribe each
resource at the last `seq` you applied. There is no retry ceiling, because a
retry loses nothing — which is the substantive difference from Zed's bounded
`MAX_RECONNECT_ATTEMPTS` and from VS Code's reconnection tokens, which die with
the server PID. Cursors survive the *client*, not just the connection: quit the
Mac app, open the phone, resume the same cursor.

**Workspace scope.** `fs:` resources are keyed by **canonicalised** root, so two
clients naming one repo differently share a single watcher. This is what keeps
five sessions in one repo at one OS watch rather than five — the failure mode
that exhausts Linux `max_user_watches`.

**`fs_changed` semantics** (chosen to match the Mac client's existing
`FileTreeWatcher`, so the consumer needs no new model):

| Field | Meaning |
| --- | --- |
| `paths` | Directories whose listing changed. Re-read only realized ones |
| `full_rescan` | The path set is **not** authoritative — re-walk. Set on watcher overflow (the wire form of FSEvents `MustScanSubDirs`), on watch-limit exhaustion, and on a change storm exceeding the per-batch path cap |
| `git_meta` | Index / HEAD / refs moved → re-read git status. Object-store and packfile churn is dropped host-side and never appears at all |

Batches are debounced host-side (300 ms quiet window, matching the client's own
FSEvents coalescing) so a `git checkout` publishes one batch, not one per file.

**Invariant:** resources live on the control plane and are **never** on the
terminal hot path (§A). A resource flush must never delay `fan_out`. Capability
`resources` gates the verb; `fs_watch` gates the `fs:` kind.

### C.11 Spawn environment — the other half of the presentation boundary

The device doc's §4 rule ("the host describes state, it never decides how that
state looks") has been read as a rule about *what the host sends back*. It is
also a rule about **what environment the host starts a process in**, and that
half is currently violated.

`CreateSpec.env` (`protocol.rs`) is layered over the daemon's own environment at
spawn (`pty.rs`). For a remote session the Mac client sends `env: []`
(`TermioStore+Termiod.swift`), on the correct reasoning that the Mac's `PATH`,
`HOME`, and `SHELL` are wrong on a VPS. But that throws away the *presentation*
context along with the machine context, and the agent inside the PTY then
guesses. Concretely: without `COLORTERM`, Claude Code and every other
`supports-color` consumer decides the terminal is 256-colour and quantises the
user's theme to the nearest palette cube entry — the same washed-out remote
rendering users report against plain `ssh`. So `env` splits in two:

| Machine environment — **never** travels | Presentation environment — **always** travels |
| --- | --- |
| `PATH` `HOME` `SHELL` `USER` | `TERM` `COLORTERM` |
| the client's `cwd`, `TMPDIR` | `TERM_PROGRAM` |
| anything naming a client-side path | `FORCE_HYPERLINK` |

Implemented 2026-08-05 as `TermioStore.presentationEnvironment(from:)`, with
`PresentationEnvironmentTests` pinning both halves. Two decisions the table
does not show:

- **`TERM` travels, and safely, because termio sends `xterm-256color`** rather
  than a ghostty-specific value. A terminfo name the far box lacks would break
  the session outright, so this column is only safe while the value stays
  universal — revisit if termio ever wants `xterm-ghostty`, which needs remote
  terminfo first.
- **`TERMIO_SESSION` is deliberately excluded.** It is identity, not
  presentation: a hook on the far machine that echoed it back would be
  reporting to a control socket that exists only on the Mac.

The rule generalises: **the client declares how output should be produced; the
device decides where it runs.** Anything a program reads to choose colours,
glyph width, or capability level is the client's to declare.

This is also a capability plain SSH structurally lacks, and therefore worth
naming as a differentiator rather than filing as a bug fix: OpenSSH forwards
only `TERM` plus the config's `SendEnv` whitelist (`LANG LC_*` by default), so
matching this over `ssh` requires editing `SendEnv` *and* the server's
`AcceptEnv` and restarting `sshd`. termiod spawns the process, so it simply
declares the environment. Same VPS, same agent: through `ssh` the colours are
wrong, through termio they are right.

### C.12 File request plane — remote tree, reads, search, uploads

§C.10's `fs:` resources solve *change notification*; this section adds the
**pull side** (listings, reads, search) and the **write side** (uploads), so a
remote project gets a working file tree, drag-file upload, and paste-image —
without replicating the tree to the client. Everything here rides the control
channel with the existing `seq`/`re` request ids and typed errors; none of it
touches `fan_out`.

**Posture: lazy + cached + predictive, never a client replica.** Zed replicates
the whole worktree snapshot to every client (SumTree replica streamed as
chunked `UpdateWorktree`; ignored/external dirs excepted as unloaded stubs, a
pull RPC expands them). That buys a zero-RTT tree and a client-side fuzzy
finder at the price of a full initial scan, tree-sized memory on both ends,
and snapshot resync on reconnect. termiod inverts it: attach costs one
listing, and three mechanisms buy back the replica's perceived speed:

1. **Cached listings, watcher-invalidated.** Every `fs.list` reply is stamped
   with the `fs:` resource's current `seq`. Clients cache listings
   indefinitely; the existing `fs_changed` batches are the invalidation feed
   (a batch naming a cached dir → re-list it). Visited dirs are 0-RTT until
   they actually change — freshness is proven by cursor, not guessed by TTL.
2. **Batched, speculative listing.** `fs.list {root, paths: […], page?}`
   accepts many paths. Clients SHOULD list a rendered directory together with
   its visible child dirs (the only possible next clicks), making expansion
   0-RTT in the common case and one RTT worst-case.
3. **Host-side name index for the fuzzy finder.** `fs.match {root, query,
   limit}` matches file *names* against a paths-only index the host builds
   lazily at idle priority after the first subscribe, honoring the same
   ignore rules as the watcher, kept incremental by it afterwards. Replies
   carry `coverage: 0.0–1.0` so a client can say "still indexing" instead of
   silently missing files. The index is evictable state, never
   correctness-bearing. This is what gives an iPhone a monorepo fuzzy finder
   in kilobytes of client memory.

**Verbs** (capability `files`):

| Verb | Shape | Rules |
| --- | --- | --- |
| `fs.list` | `{root, paths[], page?}` → per-path `{entries[], next_page?, seq}` | entry = `{name, kind: file\|dir\|symlink\|unloaded_dir, size, mtime, symlink_target?}`; pages capped (~2,000 entries); ignored/external dirs are `unloaded_dir` stubs — never walked until explicitly listed (the one Zed lesson kept as invariant) |
| `fs.read` | `{path, range?}` → chunked binary | 1 MiB soft cap for preview parity with the companion; `range` for the editor later |
| `fs.search` | `{root, query, limit}` → streamed result events, terminal reply | host runs `git grep`; cancellable by request id (⇧⌘F) |
| `fs.match` | `{root, query, limit}` → `{paths[], coverage}` | filename fuzzy (⌘⇧O); see index above |

**Uploads** (capability `upload`) — one mechanism, three gestures (drag onto a
tree folder, drag into the terminal, paste an image at a remote agent):

```
→ upload.open   {dest, size, sha256, mode?}    ← {upload_id, offset}
→ U <upload_id, offset> + ≤64 KiB payload      ← {ack, offset}   (×N, credit-of-one)
→ upload.commit {upload_id}                    ← {path}
   (or upload.abort {upload_id})
```

- `dest` is a path under the project root **or** `temp:` — the session-scoped
  scratch dir (`…/session-<id>/paste-<n>.png`, 0600, reaped with the
  session). Paste-image and drag-into-terminal upload to `temp:` and then
  inject the returned path into the PTY as bracketed-paste text; drag-onto-
  tree uploads to the real path and injects nothing — the `fs_changed` push
  makes the file appear in every attached client's tree.
- Host writes to a dotfile, verifies size + sha256 on commit, `rename()`s
  into place. Memory stays O(chunk) throughout.
- **Re-`open` is idempotent and resumes.** Same dest, size, and hash returns
  the same `upload_id` plus the `offset` already on disk, so a client that
  lost its pipe sends only the tail. Resuming is safe *because* size and
  sha256 are declared at open: two transfers agreeing on both have the same
  bytes, so any prefix of one is a prefix of the other and the running hash
  stays valid. A client that ignores `offset` and sends from 0 is read as a
  restart and served by rewinding, which is what makes the field additive.
- **Head-of-line discipline** (the anti-100× clause for a shared pipe):
  credit-of-one — the client sends the next chunk only after the previous
  ack — and the daemon's writer drains PTY frames before upload chunks.
  Worst-case added keystroke latency is one chunk (~5 ms at 100 Mbit/s),
  bounded by construction. On the QUIC binding uploads get their own stream
  and the discipline is free.
- **Confinement**: the host canonicalises `dest` and rejects escapes from
  the project root / session temp dir (dotdot, symlink traversal). Old
  daemons without the capability degrade cleanly at `hello`.

**Not in scope, deliberately**: download-direction drag-out (symmetric,
later — `fs.read` already covers preview), rsync-style tree sync,
thumbnails, and any in-band TTY file transfer à la kitty's `kitten
transfer` — the control plane exists precisely so the TTY never moonlights
as a file channel.

### C.13 `git:` resource kind — status as a subscription, read-only

The git tree is the second consumer of §C.10's one mechanism — id
`git:<canonical repo root>`, cursor, ring, `gap` semantics, linger — nothing
new to learn. The host computes status off the watcher's existing `git_meta`
signal (index/HEAD/refs moved → debounced `git status --porcelain=v2` →
publish a delta batch):

```
E {ev:"git_changed", resource:"git:/work/termio", seq:12,
   updated_statuses:[{path, status}], removed_paths:[…],
   branch?, ahead_behind?, head?, conflicts?}
```

**Status vocabulary is adopted from Zed verbatim** — two axes per tracked
file (`{index_status, worktree_status}` over
added/modified/deleted/renamed/…), plus `untracked | ignored |
unmerged{first_head, second_head}`, with the merge-conflict path set
first-class. It is battle-tested and maps 1:1 onto the GitHub-Desktop-shaped
changes pane.

**Read-only by design.** No stage/commit/push verbs — the user commits in
the terminal, which is the same app. This deletes the majority of Zed's git
surface (mutation RPCs, optimistic-update reconciliation, a write-permission
model) and is why the whole kind fits in one event shape plus one verb:
`git.diff {path, staged?}` → unified diff, rendered client-side. Zed's proto
carries deprecated `RepositoryEntry` debris from migrating git between two
replication schemes; a single-mechanism resource plane cannot drift that way.

## D. Transport bindings

| | Unix socket | SSH stdio | QUIC (later) | WSS + relay (later) |
| --- | --- | --- | --- | --- |
| **Auth** | Filesystem perms on `$XDG_RUNTIME_DIR/termiod/` (0700); peer-cred check optional | ssh-agent / `~/.ssh/config` — user's existing identity, keys never touch Termio | Borrowed identity only: Tailscale tailnet, or pairing-pinned host cert (TOFU like SSH). **No DIY PKI** | Pairing token (companion model), scoped per device; tokens gate every connection |
| **Channel mapping** | 1 connection = 1 channel | 1 exec (`termiod stdio`) = 1 channel; ControlMaster **would** multiplex execs over one TCP+auth session — **not implemented**, see the note below the table | 1 QUIC connection per (client, host); stream 0 = control, one bidi stream per attach — the roles were designed for this | 1 WebSocket = 1 channel (matches today's companion shape) |
| **Failure / reconnect** | Retry connect; host down = launchd/systemd restarts it | TCP drop = detach, never kill; reattach replays ring / snapshot; ControlMaster + `ServerAliveInterval` for fast resume | Connection migration = roaming survives network flips; 0-RTT resume | Relay drop = detach; client re-pairs/reconnects; tiered ReconnectPolicy already exists on iOS |
| **When (product)** | Local, always — the default | Remote VPS/devbox — the default remote through v1 | Only after measured pain: the §D p95 criterion, or a supersedable plane the browser needs | **The web client's transport** (a Replica over WSS), plus a phone with no tailnet behind hostile NAT |

**ControlMaster — was documented but unimplemented for a while; implemented
2026-08-05.** The client used to spawn a bare `ssh -o ServerAliveInterval=15
<host> <command>`, so every remote session and every reconnect paid a full
TCP + SSH KEX while this table claimed the cost was amortized. Measured on
`ukvps` before and after, same box, same session:

| | cold | warm |
| --- | --- | --- |
| no multiplexing | 260 / 260 / 290 ms | — |
| `ControlMaster=auto` + `ControlPersist=10m` | 210 ms (mints the master) | **20 / 110 / 20 ms** |

`Termiod.multiplexingArguments(host:)` injects the three options, with two
constraints worth keeping:

- **The user's config wins.** A command-line `-o` outranks `~/.ssh/config`, so
  the options are injected only when `ssh -G <host>` shows the user has
  configured neither `ControlMaster` nor `ControlPath`. A failed probe answers
  "don't inject". Note that OpenSSH 10.2 *omits* the `controlpath` line when it
  is unset where older versions print `none` — treating an absent line as
  "configured" silently disables the whole feature, which is how the first cut
  of this shipped as a no-op.
- **Path length is a hard limit, not a preference.** A Unix socket path caps at
  104 bytes and an over-long `ControlPath` makes ssh fail rather than degrade,
  so the socket name is a truncated SHA-256 of the alias under `$TMPDIR`
  (76 bytes for a typical account) and multiplexing is dropped if it would not
  fit.

This is the cheapest form of Superlogical's *"the mux owns SSH"*
(**Announced**) — the connection becomes a resource the client holds rather than
a process each session spawns — and it costs zero new security surface, unlike
the custody sense of that phrase (§F #2).

**SSH vs QUIC — complementary planes, not a religion.** SSH's unbeatable
asset is **deployed identity and trust**: every target VPS already has the
user's key, agent, jump hosts, and ops muscle; using it means Termio ships
zero crypto and inherits every enterprise's existing audit story. Its real
costs are per-connection process+handshake overhead (amortizable by
ControlMaster once it is passed), TCP head-of-line blocking under loss, and no
roaming on a bare network (a phone changing networks re-handshakes).

**The head-of-line cost is not a WAN adjective — it scales with attached
session count.** An earlier revision called it "tolerable on good WAN", which
is true at one or two sessions and misleading at ten. `termiod` multiplexes
*every* plane — N terminals, files, git, control — over **one** `termiod stdio`
pipe, so SSH's own channel multiplexing is never used and a single lost segment
stalls all of them at once: one agent's output burst delays keystrokes in an
unrelated session. Since "supervise many agents at once" is the product, the
exposure grows with the thing the product is for. Note the coupling:
ControlMaster *increases* this exposure (it collapses N TCP connections into
one), so the two changes must be measured together. Make it a criterion, not a
judgement call:

> Run with `tc qdisc add dev eth0 root netem loss 2% delay 30ms`, 8 attached
> sessions, 2 of them streaming output; measure p95 keystroke echo in a third.
> Sustained p95 > ~200 ms is what promotes QUIC from roadmap to work.

QUIC fixes exactly those three — streams, loss independence,
connection migration, 0-RTT — but brings the one problem SSH had already
solved: *who are you?* DIY certs would violate the no-invented-crypto rule.
So the sequencing writes itself: **SSH is the trust/bootstrap plane and
default remote; QUIC is a performance plane added later, borrowing identity
from a tailnet (where QUIC-over-Tailscale gets migration for free) or from a
pairing ceremony.** The protocol needs zero changes either way — that's what
the channel abstraction buys. Raw TCP + DIY TLS as a third path stays
rejected: it is QUIC's identity problem with none of QUIC's benefits.

*(For reference: Superlogical says its mux "owns SSH" as a durable session
resource — **Announced** in spirit, custody and implementation **Unknown**.
Termio's fork — system OpenSSH as a pipe to a user-run host — stays deliberate:
smaller security scope, at the cost of some seamless-reconnect polish we buy
back with ControlMaster and setup helpers.)*

### D.1 QUIC binding — full design (v2, specified now so v1 aligns)

Measured motivation (live `ukvps` run, 2026-07-30, v0.1 over system SSH):
keystroke echo **12.1 ms median** — already local-feeling — but **65 ms p95**
(TCP head-of-line under loss), **~230–300 ms** per cold SSH exec, and no
roaming. QUIC's targets are exactly those three numbers plus the phone's
network flips; the median needs no help.

**Connection layout.** One QUIC connection per (client, host), ALPN
`termiod/1`; never one connection per session (it forfeits handshake
amortization and migration):

```
├─ bidi stream (first opened) → hello{role:"control"}          roster · subscribe · wait · send
├─ bidi stream per attach     → hello{role:"attach", target}   that session's terminal plane
└─ DATAGRAMs (RFC 9221)       → supersedable frames only: grid-diff repair, predictions
```

Same 5-byte framing inside every stream — a recorded Unix-socket transcript
replays byte-identical over a QUIC stream (the §C.9 acceptance test).
`hello` per stream keeps streams self-describing; QUIC deliberately does not
order across streams, and nothing here needs it to. Per-stream delivery is
the p95 fix: one session's retransmit can no longer stall another session or
the control channel.

**State-sync layer (the one real protocol addition).** v1.1 dirty-row diffs
are *supersedable*: a newer version of a row obsoletes the older one, so
reliable-ordered delivery of stale rows is wasted work. Binding: rows
versioned by frame counter; diffs ride datagrams fire-and-forget; the client
acks the highest contiguous frame on its attach stream; the host re-sends
rows dirty-and-unacked past ~2×RTT *at their current version*; a periodic
keyframe (full `S` on the reliable stream) bounds drift. This is mosh's SSP
rebuilt on standard transport — datagrams, congestion control, encryption,
and migration come from QUIC instead of invented UDP framing, so the
no-invented-crypto rule survives. **Input never rides datagrams** —
keystrokes are non-idempotent and stay on the reliable attach stream.
Client-side predictive echo (capability `predict`) renders keystrokes
immediately and lets authoritative diffs confirm or correct — the piece that
makes a 100 ms+ RTT link *feel* local, which no transport can do alone.

**Reattach and roaming.** 0-RTT resumption + `attach {target, last_seen}`:
the host replies with diffs-since or a fresh snapshot if the window is gone —
reattach drops from ~300 ms to ~1 RTT. 0-RTT safety rule: only `hello` and
`attach` may ride early data (replay-safe); `D`/`send` wait for handshake
completion. Connection migration is the iOS feature: Wi-Fi → 5G mid-session
and attach streams simply continue — no protocol event, no torn TUI. SSH
structurally cannot do this **over a bare network**.

**A tailnet, however, supplies migration to plain TCP — which weakens this
argument considerably.** WireGuard peers are keyed by public key, not by
endpoint: the underlay address may change while the overlay `100.x` address
stays put, so a TCP connection carrying `termiod stdio` should survive
Wi-Fi → 5G with no QUIC involved. If that holds, roaming collapses into the
Tailscale integration this section already wants for *identity*, and what
remains uniquely QUIC's is only the p95-under-loss criterion in §D. **Verify
before relying on it:** hold an attached session over a tailnet, flip the
physical network, and record whether the session survives, how long it stalls,
and whether the TUI tears. That one experiment decides whether QUIC is a
roadmap item or a someday item.

**Identity (decides when this ships).** QUIC mandates TLS and DIY PKI is
banned, so trust is borrowed, in preference order:

1. **Inside Tailscale** — tailnet is identity + ACL; TLS uses a
   host-generated self-signed cert the client pins (the tunnel already
   authenticated the machine).
2. **Bootstrap over SSH** — first contact runs over the already-trusted SSH
   pipe; through it the client fetches the host cert's SPKI fingerprint and a
   client credential, then dials QUIC directly, pinning what SSH vouched
   for; mutual TLS thereafter. "SSH is the trust plane, QUIC the performance
   plane" as mechanism, not slogan — SSH never leaves, it just stops
   carrying keystrokes.
3. **Pairing ceremony** for the phone — the companion pairing flow upgraded
   to exchange cert pins instead of bearer tokens.

**Free housekeeping.** QUIC per-stream flow control replaces userland
backlog rules (a slow observer just stops getting credit; the writer and
other sessions are untouched; the host ring absorbs the gap). Idle timeout =
clean implicit detach; PING replaces `ServerAliveInterval`. Protocol
versioning stays in `hello`, transport-independent — the v0.1 message set
runs over QUIC unchanged the day the binding lands.

**Refused even in the "perfect" version:** per-session connections;
everything-on-one-stream (recreates TCP HoL); input or `create` in datagrams
or 0-RTT early data (replay hazards); WebTransport as the base binding (see
below); shipping any of this before v1 snapshots exist.

**WebTransport / HTTP-3 stays refused — and the reason changed.** The old
reason was "revisit only if the web client becomes real". A web client is now
planned, and the answer is still no, for a better reason: **the web client is a
Replica, not a Mirror** (see the client-classes doc §D.3). `libghostty-vt`
compiles to a standalone Wasm module, so the browser runs the same VT as the
Mac and receives the same raw `D` bytes. Raw bytes are reliable, ordered, and
non-supersedable — exactly what datagrams are useless for. WebTransport's one
unique asset over WSS is datagram delivery of supersedable `G` frames, and a
Replica sends no `G`. Multi-session head-of-line is handled by opening one
WebSocket per attach, which browsers permit. Revisit only if a supersedable
plane becomes load-bearing in the browser; note that WebTransport did reach
Baseline in March 2026 (Safari 26.4), so availability is no longer the blocker
— *need* is. That last is the sequencing truth: the QUIC binding is ~80%
"the v1/v1.1 snapshot+diff work already planned" and ~20% transport code —
QUIC without v1 would be raw bytes with a fancier handshake, fixing nothing
measured except the p95 hiccup.

## E. Comparison matrix

| Dimension | **Termio Session Protocol** | Superlogical | tmux | zmx | herdr-style remote | Termio Companion wire (today) |
| --- | --- | --- | --- | --- | --- | --- |
| Durable host ≠ viewer | ✅ `termiod` | ✅ **Announced** (long-lived sessions, reconnect) | ✅ | ✅ | Partial (app/daemon hybrid) | ❌ host is the GUI |
| Transport-agnostic protocol | ✅ channels over any pipe | **Unknown** (nothing published) | ❌ Unix socket only | ❌ local socket; SSH as workflow | ❌ bespoke per-feature | ❌ WSS-only, bespoke |
| Terminal state authority | Host vt (v1), staged | **Inferred** server-side (web client implies it); details **Unknown** | Server-side (own VT) | Sidecar VT for reattach only | Client-side | Mac-side, ad-hoc (MirrorReportFilter…) |
| Agent events on the wire | ✅ first-class (`status`, approvals, `wait`) | ❌ not announced; "supports agents, not agent-specific" — **Announced** | ❌ | ❌ | Partial (product events, not an open protocol) | Partial (roster pushes) |
| Multi-client / writer policy | ✅ multi-viewer, single writer, observable claim | ✅ live sharing built in — **Announced**; policy **Unknown** | ✅ (size = smallest client — a known wart) | ✅ attach-only | Single app | 1 phone |
| Versioning / capability negotiation | ✅ `hello` + caps, hard refuse | **Unknown** | ❌ (server/client must match) | ❌ minimal | ❌ | ❌ (skew caused real bugs) |
| Nested window manager | ❌ by rule | ❌ blocks in *client*, mux not nested-terminal — **Inferred** from "architectural dead end" remark | ✅ (panes in server) | ❌ by design | ✅ (app-level) | ❌ |
| Remote model | Same protocol, SSH pipe | Mux "owns SSH" — **Announced**, details **Unknown** | `ssh -t tmux` (nested) | `ssh` + local zmx | Product relay | Tunnel to Mac only |

Reading of the matrix: the defensible, *unoccupied* cell is **agent events as
an open, versioned protocol concern**. Everyone durable has sessions; nobody
announced has `needs_you` on the wire.

## F. Risks & open decisions

| # | Risk / decision | Position |
| --- | --- | --- |
| 1 | **Phone→Mac gateway vs phone-direct-to-remote-termiod** | Start with Mac-as-gateway (reuses companion pairing + relay work; one trust decision for the user). Phone-direct is v2 via Tailscale, where identity comes free. Gateway's cost: Mac must be reachable — already a known constraint. **Needs product call (§ top-5).** |
| 2 | **Does Termio ever "own SSH"?** | The phrase conflates three things and they carry wildly different prices, so answer them separately. **(a) The connection is a durable resource the mux holds**, not a process each session spawns — **accept, and it is overdue**: that is ControlMaster/ControlPersist, three flags, zero new security surface (see the note under §D). **(b) Termio implements the SSH protocol in-process** — **refuse**: key custody, agent forwarding, host-key policy, a security surface Superlogical appears to have chosen (**Announced** in spirit, custody **Unknown**) and we deliberately will not staff. **(c) Termio owns the wire that carries session bytes** — **later, and as a route, not a rewrite** (§D.1). The standing position was written as a flat "no" and so quietly declined (a) along with (b); (a) is where most of the felt UX of "owns SSH" actually lives. |
| 3 | **Sharing ACL** | Out of protocol v1. The writer token + `hello` identity are the future hook; external identities (a colleague's device) need a pairing/ACL design that must not be improvised. |
| 4 | **Relay threat model** | Relay is a blind pipe: no session semantics, no `hello` termination, no plaintext `env`/`D` unless the leg is user-owned (own cloudflared/tunnel today). True E2EE-through-untrusted-relay is future work; until then docs must say plainly which legs see plaintext. |
| 5 | **Ring vs snapshot gap (v0→v1)** | v0 ring replay can tear TUIs on reattach (replayed escape torrent). Confirmed live 2026-07-30: reattaching to a remote `top`, the alt-screen enter (`ESC[?1049h`) had scrolled out of the 41 KB ring — `top` self-heals (periodic repaint), an idle TUI like vim would not. Acceptable for POC; v1 snapshot is the fix — don't polish ring replay further. |
| 6 | **Linux host + libghostty-vt** | v1 bets on `libghostty-vt` building cleanly into the Rust host on Linux (zig cross-compile). De-risk with a spike before committing v1 dates; fallback is any correct VT with damage tracking, at the cost of cell-format alignment. |
| 7 | **Event flood vs UI** | Protocol allows high-rate `E`; client discipline (per-session `SessionRuntime`, no roster replace per tick) is already law — see sidebar-scroll-performance. Host also coalesces status transitions (≤ ~10/s per session). |
| 8 | **Superlogical ships first and defines expectations** | Their step 1 is an incredible mux (**Announced**). Our counter is not feature racing; it's landing #170–#172 so agents *survive the app* this quarter, with agent events they haven't announced. |
| 9 | **No pipe-mode (non-tty) attach client** | The CLI `attach` assumes an interactive tty; driven non-interactively over a bare SSH channel it delivers **0 bytes** (confirmed 2026-07-31 on `ukvps`), which blocks scripting, piping, and honest WAN-throughput measurement. The protocol already has `mode:"observe"`; the fix is a CLI surface for it (`attach --observe`/`pipe` → raw `D` to stdout, no raw-mode, no stdin capture). Small, and needed before the Mac/iOS clients rely on the same read path. Note the sharper framing (Codex review 2026-07-31): today `remote attach` runs `ssh -t host termiod attach`, so the framed protocol lives *between the remote CLI and the remote socket* and never crosses SSH from a native client — the "same bytes over every transport" claim (§C.9) is **not yet exercised end-to-end**; a non-tty `termiod stdio` bridge is what makes it real. |
| 10 | **Unbounded per-client backlog (the non-blocking hot path's shadow cost)** | The anti-100× invariant makes `fan_out` never block on a slow consumer — but per-client and outbound channels are **unbounded** (`daemon.rs`), so a stalled socket (a wedged phone, a paused SSH client) accumulates raw output without limit until it threatens the daemon. The fix pairs with the `bytes::Bytes` fan-out (single shared chunk, refcounted): give each client a **byte budget / sequence cursor**; when a client falls behind the retained window, **drop it (v0) or resnapshot it (v1)** rather than grow forever. One change closes both the (C+2)×n copy cost and this memory risk. |
| 11 | **Resize is not a barrier; `pty.resize` errors ignored** | `handle_msg(Resize)` (`session.rs`) updates stored dims + emits `Resized` even if the `TIOCSWINSZ` ioctl failed, and a promoted writer after failover keeps stale dims and is not told to reclaim size. v1 must make resize the quiesce → resize → fresh `S` → resume barrier (§C.5) and surface ioctl failure. |

## G. Phased roadmap

Mapped to the three-step sequence (§0 of the mux doc) and the GitHub epic
[#164](https://github.com/termio-sh/termio/issues/164):

| Step | Protocol work | Repo milestone |
| --- | --- | --- |
| **1 · Incredible host** | **v0 frozen** (shipped in POC, [#177](https://github.com/termio-sh/termio/pull/177)). **v0.1 implemented** (branch commit `6855552`): `hello`+caps, `seq`/`re`, error codes, `E` frames, `send`/`wait`, `workstream` in CreateSpec — 28 local + 8 fake-ssh smoke checks green. **Live VPS e2e passed 2026-07-30** on `ukvps` (aarch64, static-musl cross-compile deploy): detach ≠ kill across hard disconnect, send-without-attach, set-status; echo 12.1 ms median, throughput ≈ local | #170 local host: Mac app attaches over Unix socket; sessions survive app quit. #171 SSH deploy helper. #172 remote open (same protocol, SSH pipe) |
| **2 · Composable agent surface** | **v1**: host-side vt authority, `S` snapshot on attach/resize, host-side status sources (hooks/OSC on the host, heuristics as fallback), approvals in events. `termio sessions` CLI re-based on control channel (retires transcript scraping) | Post-#172: iOS roster + needs-you from `subscribe`; unify companion semantics onto the protocol |
| **3 · Multi-device operable** | **v1.1**: `G` dirty-row diffs (phone first); QUIC spike behind the channel abstraction; WSS relay binding with blind-pipe rule | Discovery providers (static SSH config, optional Tailscale); phone-direct decision falls due here |

Gate between steps: don't start v1 until the v0.1 skew test suite (old
client × new host replay) is green — versioning discipline is cheap now and
impossible retroactively.

## H. What we reject (beautiful ideas we will not do)

1. **gRPC/protobuf/CBOR for the hot path** — an IDL buys nothing for raw
   bytes and packed cells; it buys codegen complexity on every client.
2. **Protocol = shell over SSH** (`ssh -tt host claude` productized) — pipes
   are not sessions; this was the founding rule.
3. **Freezing raw-PTY forever** — v0 raw is a stage, not the contract;
   `snapshot`/`grid_diff` capabilities are on the roadmap with dates.
3a. **State sync on the hot path** — a server-maintained grid diffed to clients
   as the *default* steady state (the tmux/VNC model). That reintroduces the
   middle-emulator parse tax the whole design exists to avoid (measured 4–6× in
   `termiod/bench`); `grid_diff` stays an opt-in bad-network degrade (§C.6),
   never the default, and never blocks byte delivery (§A invariant).
4. **Public `0.0.0.0` bind / raw TCP + DIY TLS** — Unix socket and SSH only
   until QUIC arrives with borrowed identity.
5. **CRDT multiplayer typing** — single writer with an observable claim;
   sharing, if it comes, builds on the token, not on merged input.
6. **Per-client PTY size / server-side per-viewer reflow** — one PTY, one
   size, writer owns it; observers adapt client-side.
7. **Nested window manager in the host** — no panes/tabs/layout in `termiod`,
   ever; that's the tmux dead end both we and Superlogical (**Announced**)
   are escaping.
8. **Embedding an SSH or crypto library in the host/client** — system
   OpenSSH, tailnets, and OS keychains are the security team we didn't hire.
9. **A second protocol for the phone** — the companion wire is the cautionary
   tale; iOS becomes a `grid_diff`-capable client of *this* protocol.
10. **Guessing Superlogical's wire format** — we compete on our contract, not
    on speculation about theirs (**Unknown** stays unknown).

## Top 5 decisions that need a human product call

1. **Phone path order:** Mac-as-gateway first (recommended) or jump straight
   to phone-direct-to-remote-termiod — this decides whether iOS remote works
   before discovery/QUIC lands, and what users must trust in between.
2. **Sharing:** is live sharing with another *person* (Superlogical's
   built-in headline feature, **Announced**) a v2 goal or a non-goal? The
   protocol reserves the hooks either way, but positioning and ACL work are
   product commitments.
3. **Openness:** is the Session Protocol spec + `termiod` published as
   open/self-hostable infrastructure (the composable-platform story from the
   funding thesis), or kept as an app implementation detail? This changes how
   hard we must version, document, and stabilize.
4. **SSH custody line:** confirm the standing bet — system OpenSSH forever,
   even if Superlogical's integrated remote UX is smoother — or budget a
   future "Termio manages the connection" mode with its key-custody cost.
5. **Deprecation policy:** how long do v0-only clients (raw PTY, no `hello`)
   stay supported once v1 ships — i.e., when may the host require `hello`?
   This is a support/commercial promise, not an engineering choice.
