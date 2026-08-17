---
title: Session Daemon Architecture (termiod — one model for local, remote, mobile)
status: draft
type: design
created: 2026-07-08
updated: 2026-07-30
related:
  - 20260730-termiod-session-mux.md
  - 20260708-remote-projects.md
  - 20260705-remote-access-relay-strategy.md
  - 20260628-session-share.md
---

# Design: Session Daemon Architecture (`termiod`)

> **A session lives in a host. Viewers only attach.** Collapse four code-paths (local, remote, phone, CLI) into three parts: **host · protocol · clients**. Local is remote to localhost. Product/competitive framing: [termiod-session-mux.md](20260730-termiod-session-mux.md).

## 0. Conclusion first

- **Termio already has a PTY server — it's just implicit.** Today `PTYProcess` + the `.inMemory` backend + `libghostty-vt` all live in one process; the boundary between "who owns the bytes" and "who renders them" is a function call, never drawn explicitly. Every architectural mess in the project comes from that boundary being invisible.
- **The clean architecture is one sentence:** a session is a first-class object living in a host (`termiod`); its lifecycle is independent of any viewer; all UIs (Mac window, iOS app, CLI, a future web client) are **stateless clients that attach/detach**. **Local = "host is localhost, transport is a Unix socket."** There is only one code path.
- **Three parts only:** **Host** (owns PTYs) · **Protocol** (transport-agnostic) · **Clients** (viewers). SSH/WSS/Unix socket are pipes, not product modes.
- **Remote VPS then costs almost nothing.** It is not a feature — it is *one transport implementation*: `ssh host → termiod attach`. The host and protocol are identical to local; only the byte pipe changes. This is the direct answer to "make remote VPS easy": you stop building "remote" and instead build "the session boundary," after which remote is a thin transport.
- **The flicker problem dissolves too.** Clients render `libghostty-vt` grid diffs/snapshots, never the app's raw redraw torrent. Images, OSC 8, reflow, and no-flicker become uniform and free — not a remote-only patch. See [remote-projects.md](20260708-remote-projects.md) §Transport for why raw-byte-over-SSH flickers and grid-diff does not.
- **Performance is a non-issue.** A local Unix socket hop is ~5–20 µs against a 16 ms frame budget (~0.06%), and only frame-rate-capped diffs cross it (not the byte torrent, which is absorbed server-side). tmux has shipped exactly this client/server-over-Unix-socket model, locally, for 15 years. The real tax is a new *failure surface*, not latency — and Termio has already built the primitives for it (backpressure, ring-buffer replay, catch-up snapshot, heartbeat — see [host-pty notes]).
- **It is not a rewrite-from-zero.** The boundary is drawn **once** (Phase 0, in-process, zero new features) and paid down incrementally, each phase shipping a real user-visible win: persistence → remote → unified mobile/CLI.

## 1. The problem: four architectures doing one thing

Termio currently solves "run a terminal session and show it" four separate times:

| Path | How it works today | Pain |
| --- | --- | --- |
| **Local session** | `PTYProcess` in-process, host owns bytes, libghostty renders | fine — but the session dies when the app quits (shells restart fresh) |
| **Remote (proposed)** | a bespoke `ssh -tt … tmux` launch string with degraded file-tree/git/status | a whole second code path + a "remote is second-class" story |
| **Phone companion** | a bespoke wire protocol, its own reconnect policy, its own auth | "list works but terminal unauthorized" tunnel churn; a parallel stack |
| **`termio sessions` CLI** | scrapes transcripts + injects keys via `ghostty_surface_key` | reads state indirectly; not a real client of the session |

These are the same operation — *attach a viewer to a running PTY* — implemented four times with four state models. That duplication **is** the architectural debt. One daemon + one protocol retires all four.

## 2. The unifying model

> **A session lives in a daemon. Viewers attach and detach. Local is the degenerate remote.**

This is precisely tmux's model: tmux is *always* client/server, even locally — your terminal attaches to the tmux server over a Unix socket. Termio should adopt the same mental model, with `libghostty-vt` as the server-side terminal state machine and grid diffs as the wire format.

The load-bearing consequence: **local and remote stop being different.** "Local" is `host = localhost, transport = Unix socket`. "Remote" is `host = vps, transport = SSH-tunneled stdio`. Same daemon binary, same protocol, same client. The distinction the current `20260708-remote-projects.md` worries about (feature degradation for remote) evaporates, because there was never a "remote mode" — only a different pipe.

## 3. Components (there are three)

### 3.1 `termiod` — the session daemon
- Owns PTYs (one per session). Spawns the agent/shell exactly as `TermioStore+TerminalSurface.swift` does today.
- Runs a `libghostty-vt` instance per session as the **authoritative terminal state** (grid, scrollback, cursor, title, reflow-on-resize).
- Exposes an **attach/detach** protocol; persists sessions across client disconnects.
- Runs on whichever host the session lives on: the Mac (local), a Linux VPS (remote). Same binary, cross-compiled (`libghostty-vt` is zero-dependency Zig/C and targets macOS + Linux + Windows + WASM).

### 3.2 Session Protocol — transport-agnostic, bidirectional, framed
- **Client → daemon:** input events (key/resize/mouse), `attach(sessionID)`, `detach`, scrollback/history requests, create/kill session.
- **Daemon → client:** grid updates, title/status/bell, session-list changes.
- Runs over **any** bidirectional byte stream — it must not know its transport.
- Frame-rate capped (≤120 fps): the app's redraw torrent is absorbed into the server-side grid; only resolved updates cross the wire.

**Wire format is a solved problem — copy `coder/ghostty-web`'s RenderState model** (§11). `libghostty-vt` already exposes exactly the read-out API a daemon needs:
- `ghostty_render_state_update(term) → DirtyState {NONE, PARTIAL, FULL}` — one call tells you whether anything changed.
- `ghostty_render_state_is_row_dirty(term, row)` — per-row damage tracking.
- `ghostty_render_state_get_viewport(term, buf, n)` — the **whole viewport in one call**, as a packed array of fixed **16-byte cells** (codepoint u32, fg/bg RGB, flags, width, hyperlink_id, grapheme_len).

So the daemon→client frame is: on tick, call `update()`; if dirty, serialize **only the dirty rows** (row index + their 16-byte cells) + cursor + title; client applies them to its local grid mirror and repaints. **On attach/resize → send a full viewport snapshot**, then resume dirty-row deltas. This is ghostty-web's renderer loop with a socket spliced into the middle — the cell struct doubles as the wire cell format.

**Open decision — where keys get encoded.** ghostty-web encodes client-side: a pure `KeyEncoder` (structured `KeyEvent` → escape bytes via `libghostty`'s own encoder), then the app ships the raw bytes. Two options for Termio:
- *Client-encodes* (ghostty-web's choice): client owns the key encoder + must know terminal modes (DECCKM, kitty flags) → daemon must publish mode changes. Fewer round-trips; keystroke never waits on the daemon.
- *Daemon-encodes*: client sends structured key events, daemon (which owns mode state) encodes. Simpler client, one authority for mode state; costs one hop of echo latency (hidden by predictive echo).
Lean *daemon-encodes* for correctness (single source of mode truth), revisit if echo latency is felt.

### 3.3 Transport — pluggable, never hand-rolled
| Transport | Use | Cost |
| --- | --- | --- |
| **Unix domain socket** | local (daemon on the Mac) | ~5–20 µs/hop, negligible |
| **SSH-tunneled stdio** (`ssh host termiod --attach <id>`) | remote VPS | auth/crypto/reconnect inherited from SSH — **do not build your own transport** |
| **tunelo / QUIC** (later) | phone over the internet | reuses the [relay strategy] work |

**Rule:** Termio builds the daemon and the protocol, never the transport. Remote tunnels over SSH so authentication, encryption, and key management come free. (Building a bespoke network transport = reimplementing mosh's SSP — explicitly rejected.)

### 3.4 Clients — stateless, interchangeable
- **Mac app** (AppKit + libghostty) — renders grid diffs; today's UI, minus PTY ownership.
- **iOS app** — the same client, different transport. The bespoke companion wire is deleted.
- **`termio sessions` CLI** — a headless client of the same socket API, not a transcript scraper.
- **Web client** (future) — `coder/ghostty-web` already renders `libghostty-vt` in a browser.

## 4. Why remote VPS becomes trivial (the question that started this)

Under this model, "open a remote project" is:

```
# local session (today's behavior, now via the socket):
termiod  (on Mac)  ←unix-socket→  Mac client

# remote session — the ONLY new code is the transport line:
ssh vps termiod --attach <id>   ←ssh-stdio→  Mac client
```

Everything downstream is identical because the client only ever speaks the Session Protocol. No `20260708-remote-projects.md`-style "grey out file tree / git / status for remote" — those subsystems, if they run **inside** `termiod`, work the same whether the daemon is on the Mac or the VPS. Remote file tree = the daemon's local file tree. Remote git = the daemon's local git. Remote agent-status = the daemon reads its own local hooks. **The local/remote asymmetry that made remote hard simply isn't expressible in this architecture.**

So: **yes — adopting this architecture is what makes remote VPS easy.** It converts remote from "a second code path with degraded features" into "a one-line transport swap."

## 5. Data path & performance

Current (in-process): PTY read → libghostty state → render, hand-off ≈ ns.

Proposed (Phase 1+): PTY read → `libghostty-vt` grid (in `termiod`) → **diff** → socket → client → render.

- **Socket hop:** ~5–20 µs one-way vs a 16.6 ms (60 fps) / 8.3 ms (120 fps) frame budget → ~0.06%. Imperceptible.
- **Keystroke echo:** adds one process wakeup (~0.1–1 ms), far under the ~50 ms human threshold; hideable with client-side predictive echo (mosh's trick).
- **Throughput:** the byte torrent is parsed in `termiod`; only frame-rate diffs (KB, ≤120/s) cross the socket. Unix sockets do GB/s — orders of magnitude of headroom. The naïve failure mode (stream raw bytes, context-switch per byte) is exactly what the grid-diff protocol avoids.
- **Escape hatch (won't be needed):** if a bottleneck is ever measured, put the grid in an `mmap` shared-memory ring and send only "frame N ready" notifications over the socket → zero-copy.

Existence proof: tmux, VS Code's terminal (IPC to the extension host), and kitty's remote-control all cross a local IPC boundary per session and are not perceived as slow.

## 6. Where state lives (the clarifying discipline)

The protocol boundary is **load-bearing**: every feature must answer "do I live in the daemon or the client?" This is a constraint, but a *clarifying* one — it forces the "where does this state live?" question that today's four-path mess never had to answer.

| Feature | Lives in | Rationale |
| --- | --- | --- |
| PTY, grid, scrollback, reflow | daemon | it's the session's authoritative state |
| File tree | daemon | it's the daemon host's filesystem (so remote "just works") |
| Git changes / diff | daemon | same — runs against the daemon host's repo |
| Agent status (hooks) | daemon | hooks fire on the daemon host; forwarded as protocol events |
| Rendering, mouse, selection, theme | client | pure presentation |
| Session list / project model | daemon (source of truth) + client (view) | one authority, many viewers |

## 7. Migration — one boundary, drawn once, paid down incrementally

Not a big-bang rewrite. Each phase ships a standalone user-visible win while converging on one model.

- **Phase 0 — draw the boundary in-process (zero new features).** Split "session owner" from "renderer" inside the *same* process, talking through the Session Protocol over an in-memory pipe. No behavior change; it just forces the boundary to exist and become testable. Pure refactor of `TermioStore` / `PTYProcess` / `TermioStore+TerminalSurface.swift`.
- **Phase 1 — extract `termiod` as a local process; Mac app attaches over Unix socket.** Delivers **session persistence across app quit** — a long-standing want ([capabilities notes]: sessions currently do *not* survive app quit). Independently shippable.
- **Phase 2 — allow `termiod` on a remote host over SSH-tunneled stdio.** **Remote VPS projects fall out** with no new session logic. Supersedes the bespoke plan in [remote-projects.md].
- **Phase 3 — make the phone and CLI clients of the same protocol.** Deletes the companion-wire special-casing and the transcript-scraping CLI; unblocks multi-human collab ("one session, many clients" is the architecture's definition — the prerequisite flagged in [collab prior-art]).

Each phase is a commit-worthy milestone; none requires the next to be valuable.

## 8. Failure surface & what's already built

The real cost is not latency — it's failure modes that in-process code never had: daemon crash, socket disconnect mid-write, client/daemon version skew, reconnection/catch-up.

**But Termio already built these primitives** for the host-PTY work: **backpressure, ring-buffer replay, catch-up snapshot, heartbeat** ([host-pty notes]). Today they guard an in-process byte source→renderer hand-off; Phase 1 lifts the same mechanisms onto a real socket. The hard IPC engineering is largely pre-paid.

Additional must-haves:
- **Protocol versioning** from day one (client/daemon may differ, especially remote where the VPS daemon updates independently).
- **Reattach = full snapshot then diffs** (the catch-up snapshot mechanism already exists).
- **Daemon lifecycle**: who starts it (launchd/systemd? on-demand via the first attach?), how it's stopped, how orphaned daemons are reaped (cf. the tunnel-reaping lesson in [companion tunnel churn]).

## 9. Non-goals & risks

- **Non-goal: build a network transport.** Always tunnel over SSH (remote) or the existing relay (phone). No custom UDP/SSP.
- **Non-goal: multi-human collab in the first pass.** The architecture *enables* it (Phase 3+), but shipping it is a separate product decision.
- **Risk: scope discipline.** This is the largest structural change Termio has taken; it must stay a *refactor that draws one boundary*, not a licence to redesign every subsystem. The [ambition] principle applies — elegance is the small surface area of "one daemon, one protocol, many clients," not a sprawling feature set.
- **Risk: cross-compiling `termiod` for Linux.** `libghostty-vt` targets Linux, but any Swift glue in the daemon must build on Linux (Swift-on-Linux is viable; keep the daemon's Swift surface minimal, or write it in Zig/C against `libghostty-vt` directly).
- **Open question: how much of `TermioStore` moves server-side?** The project/session model is authoritative in the daemon, but the Mac app has a lot of AppKit-coupled state. Phase 0 must find the clean cut.

## 10. Relationship to existing docs

- **Supersedes the transport core of [remote-projects.md].** That doc's v1 (SSH-as-session-command, feature degradation) becomes unnecessary under Phase 2; keep it as the *interim* plan if we want remote before `termiod` lands, but the daemon is the real answer.
- **Absorbs [remote-access-relay-strategy.md] and [session-share.md]** as Phase 3 transports/clients rather than separate stacks.
- **Builds on the host-PTY work** — this architecture is that work's logical conclusion: if the host already owns the byte stream, make the host a first-class, viewer-independent daemon.

## 11. Prior-art validation: `coder/ghostty-web`

[`coder/ghostty-web`](https://github.com/coder/ghostty-web) is, in effect, **the client half of this exact architecture**, already built and shipping: it drives `libghostty-vt` (compiled to WASM) as a headless terminal-state machine and renders the grid to a canvas, with the byte source unplugged. Studying it settles several of our open questions with a working reference. Key transferable lessons:

1. **The transport is deliberately *not* in the library — and that's the correct seam.** ghostty-web's `Terminal` exposes exactly two directions and nothing else: output via `onData`/`onResize` events, input via `write()`/`resize()` calls. The embedder wires the pipe (`term.onData(d => ws.send(d))`, `ws.onmessage = e => term.write(e.data)`). Its `Terminal` class contains **zero** WebSocket/PTY code. → **Validates our "transport is pluggable, never in the core" rule (§3.3).** Our Session Protocol is precisely the byte-in/grid-out seam ghostty-web exposes, with a socket instead of in-process callbacks.

2. **The grid read-out API is already the wire format.** Rather than per-cell chatter, ghostty-web does one `render_state_update()` → check `DirtyState` → one `get_viewport()` read of packed 16-byte cells, gated by per-row `is_row_dirty()`. → **This is our daemon→client frame, verbatim** (§3.2). We serialize the dirty rows that call already identifies; the 16-byte cell struct is the wire cell. No protocol invention required.

3. **Batch across the boundary; never cross it per-cell.** The whole viewport is read in a *single* WASM call to avoid boundary-crossing overhead, then repaint is `requestAnimationFrame`-scheduled (≈ vsync). → **Directly confirms our §5 performance model**: coalesce to frame rate, one batched read per tick. The socket is a slower boundary than a WASM call, so batching matters *more* for us, not less — but the pattern is identical.

4. **The input encoder is a pure, self-contained function.** `KeyEncoder`: structured `KeyEvent` → escape bytes, via `libghostty`'s own encoder, decoupled from transport. → Makes our §3.2 "where do keys get encoded" decision concrete and low-risk either way, because the encoder is a movable pure unit — it can live client-side or daemon-side without entanglement.

5. **Resize must be sequenced against reads.** ghostty-web *pauses its render loop* during `resize()` because the WASM realloc can detach TypedArray views, then flushes a queued-write buffer and restarts. → Our analogue: **resize is a barrier** — quiesce reads, resize the grid, emit a **full snapshot** (not a diff), resume deltas. The "queued writes during resize" pattern maps onto our backpressure/ring-buffer machinery (§8).

6. **Headless-testable by construction.** Because `Terminal` accepts direct `write()`, ghostty-web's 95 unit tests need **no PTY server** — they inject bytes and assert grid state. → **This is the safety rail for Phase 0**: our in-process boundary, driven by an in-memory pipe, is unit-testable with injected byte streams and asserted grid snapshots *before* any process split or socket exists.

**Net:** ghostty-web de-risks the client and the protocol. The parts of this doc that were "we'll design a grid-diff protocol" are now "port ghostty-web's RenderState loop and put a socket in the middle." What ghostty-web does *not* give us — and what remains genuinely ours to build — is the **daemon** (PTY ownership, session lifecycle, persistence, attach/detach, transport) and the **native libghostty renderer** on the Mac client. A local clone is at `/tmp/ghostty-web`; `lib/terminal.ts`, `lib/ghostty.ts` (the `RenderState`/`KeyEncoder` bridge), and `lib/renderer.ts` are the files to mine, and `AGENTS.md` documents the WASM-boundary gotchas.
