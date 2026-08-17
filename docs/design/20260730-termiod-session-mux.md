---
title: termiod — Agent-native session mux
status: draft
type: design
created: 2026-07-30
updated: 2026-07-31
related:
  - 20260708-session-daemon-architecture.md
  - 20260724-sidebar-scroll-performance.md
  - 20260708-remote-projects.md
  - 20260705-remote-access-relay-strategy.md
  - 20260705-remote-access-lessons.md
  - 20260711-mobile-agent-ui-protocol.md
  - 20260706-worktree-creation-lifecycle.md
---

# Design: termiod — Agent-native session mux

> **A session lives in a host. Viewers only attach.**  
> Architecture is **composable** and **direct** — Superlogical’s sequencing, Termio’s agent-native wedge. Not a clone of “multiplexer for all work.”

**Evidence policy:** Superlogical statements are **announced / pre-beta** unless marked shipped. Wire-protocol and SSH-custody details they have not published stay **unknown**. Revisit after their first beta or protocol devlog.

**Research input:** Codex sibling research (2026-07-30) against primary sources: [superlogical.com](https://www.superlogical.com/), [mitchellh.com/writing/superlogical](https://mitchellh.com/writing/superlogical), Mitchell’s X replies, HN [#49098965](https://news.ycombinator.com/item?id=49098965).

## 0. Conclusion first

### One sentence

**`termiod` is the durable session host.** Clients never own process death. Pipes only move the protocol.

### Two adjectives

| | **Composable** | **Direct** |
| --- | --- | --- |
| **Means** | Host · protocol · clients · transports plug independently; any client on any pipe to any host | One hop to authority: client → protocol → host → PTY. No second session owner, no nested WM, no product-level proxy |
| **Allows** | Mac / iOS / CLI / tools as equal clients; Unix / SSH / WSS as equal pipes; agent events as protocol modules | Local-first; system SSH as pipe; keys stay in ssh-agent; no cloud required to attach |
| **Forbids** | Special-case “remote code path” that reimplements attach | `ssh -tt host claude` as the product; app-owned PTYs; inventing crypto transport |

Superlogical’s step 2 is *make everything composable*. We take that and add **direct**: composition must not insert indirection between the viewer and the host that owns the work.

### Three parts (and nothing else)

| Part | Name | Owns |
| --- | --- | --- |
| **1. Host** | `termiod` | PTY lifetime, session table, terminal state (staged), agent metadata |
| **2. Protocol** | Session Protocol | attach/detach, I/O, resize, roster, status — **transport-agnostic** |
| **3. Clients** | termio.app · iOS · CLI | Render, input, approvals — **stateless relative to the process** |

Pipes (Unix socket / SSH / Tailscale / WSS) are **not a fourth product**. They plug under the protocol — **composable**. Each pipe is a straight byte path — **direct**.

### Three steps (Superlogical-shaped sequence, Termio wedge)

1. **Incredible host** — durable sessions; detach ≠ kill; multi-viewer; local + remote same model (**direct**).  
2. **Composable agent surface** — workstreams, `needs-you`, worktrees, `termio sessions` as real clients of the same protocol (**composable**).  
3. **Multi-device operable** — iOS, discovery, optional share/relay — still no required cloud control plane (**direct** + **composable**).

### Stance

- **What we build:** host + protocol; clients and pipes are replaceable.  
- **Competitor at the mux layer:** Superlogical (announced). Overlap is real; differentiation is **agent-first ADE + local-first + direct**, not denial.  
- **Supersedes:** interim `ssh -tt` remote projects once Phase 2 lands.  
- **Do not invent:** crypto transport, nested window managers, “CLI tool” as the architecture story.

## 1. Problem

Termio solves “run a session and show it” in four places:

| Path | Today | Failure |
| --- | --- | --- |
| Local Mac | `PTYProcess` in-app | Dies when the app quits |
| iOS companion | WSS → app-owned PTYs | Host is the GUI |
| Remote VPS | Not real / `ssh -tt` hacks | Second-class, no clean reattach |
| `termio sessions` CLI | Transcript scrape + key inject | Not a real session client |

One operation — **attach a viewer to a running session** — implemented four times.

Market context (2026-07):

| Player | Role |
| --- | --- |
| **Superlogical** | Announced terminal mux as foundation of “multiplexer for all work”; Go server / Swift Apple apps / Zig low-level; web+macOS+iOS; multiplayer; Tailscale discovery; not agent-first |
| **herdr / cmux** | Agent or ADE mux shells; mostly local or thin remote |
| **tmux / zellij** | Durable sessions; weak agent UX and multi-device |

**Termio’s gap is not another UI — sessions lack a home independent of the Mac window.**

## 2. Superlogical (sourced snapshot)

### 2.1 Facts (primary)

- **Launch:** 2026-07-29; beta waitlist; **not shipped**.
- **Team:** Mitchell Hashimoto, Jack Pearkes, Alasdair Monk, Hector Simpson (equal cofounders per announcement).
- **Funding:** Notable Capital, Amplify Partners + angels (Levie, Dadgar, Rauch, Collison, Lütke, …). **Amount unknown.**
- **Vision:** “multiplexer for all work” — durable sessions spanning local, remote, agents, CI, production, multiplayer.
- **Sequence:** (1) incredible mux → (2) composable → (3) production-safe.
- **Announced terminal product:** long-lived sessions, reconnect, multi-block, web, **native macOS/iOS**, **built-in live sharing**, native scrollback/selection.
- **Stack (Mitchell quote):** *“The server/networking components are Go, native apps are Swift (Apple), and the low level bits and bobs are Zig.”*
- **libghostty:** Superlogical is *“Not Ghostty btw (but, libghostty)”*; Ghostty nonprofit remains independent; same public MIT components as everyone else. **libghostty is not a moat.**
- **OSS:** some OSS releases promised; **full product open-source: unknown.**

### 2.2 Design intentions (Mitchell)

| Theme | Position |
| --- | --- |
| Agent positioning | Supports agents well; **not agent-specific / less AI-focused, more platform** |
| vs herdr/cmux | **Not a clone**; those tools more likely **partners** (their terminals become remote) |
| vs tmux architecture | Cloning nested-terminal muxes is an **architectural dead end** for their goals; rebuild foundation |
| SSH | Mux **owns SSH** (durable remote as session resource) — **implementation/custody unpublished** |
| Discovery | **Direct Tailscale integration** likely ships: servers join, clients find with one config |
| Clients | Web + Swift macOS/iOS; multi-attach |

### 2.3 Overlap with Termio (session layer)

Durable sessions, daemon≠viewer, Mac+iOS, remote reconnect, Tailscale-class discovery, libghostty fidelity, multi-client / sharing, agents-in-terminals, future software-driven API, native scrollback UX.

**Conclusion:** treat Superlogical as **direct session-layer competitor; differentiated product thesis** — not “platform peer only.”

### 2.4 Where Superlogical is *not* (announced)

- First-class agent states: `working` / `idle` / `needs-you` / approvals  
- Opinionated worktree / review / PR ADE workflow  
- Multi-agent supervisory CLI like `termio sessions`  
- Commercializing Ghostty  

These are **positioning differences today**, not permanent guarantees.

## 3. Goals and non-goals

### Goals

1. **Session home** independent of any viewer.
2. **One attach model** for Mac, iOS, CLI (and optional web later).
3. **Remote agent runtime** on user-controlled hosts (VPS/devbox).
4. **Agent-native metadata at protocol level** (not only PTY heuristics).
5. **Local-first:** no hosted control plane required for local or direct SSH/Tailscale.
6. **Ship incrementally** with user-visible wins each phase.

### Non-goals (relative to Superlogical’s broader vision)

Unless product strategy changes, **out of scope** for termiod v1–v2:

- “Multiplexer for all work” (production apps, incident response, general ops fabric)
- CI replacement / production control plane
- Hosted Superlogical-style control plane as default
- Competing as a generic multiplayer terminal first

Also non-goals: inventing SSH/mosh; Windows host first; multiplayer product before multi-**viewer**.

## 4. Architecture

Inspired by Superlogical’s clarity (*durable session as the missing layer; start with an incredible mux*) and zmx’s restraint (*persist sessions; do not reimplement the window manager*). Termio’s cut is narrower and agent-first.

### 4.0 The clean model

```
                    CLIENTS  (stateless viewers)
         termio.app · TermioMobile · CLI · (web later)
                           │
                           │  Session Protocol
                           │  (versioned, transport-agnostic)
              ┌────────────┼────────────┐
              │            │            │
         Unix socket      SSH        WSS / relay
         (local host)  (remote host)  (phone / edge)
              │            │            │
              └────────────┼────────────┘
                           ▼
                    HOST  —  termiod
              durable session runtime on a machine
         · session table + agent workstream metadata
         · owns every PTY (spawn / reap)
         · terminal state authority (staged: raw → vt → diffs)
         · multi-viewer · resize claim · status events
                           │
                           ▼
                 shell / claude / codex / …
```

**Rules that keep this elegant:**

| Rule | Meaning |
| --- | --- |
| **Host ≠ viewer** | Closing Mac/iOS/CLI never kills the session |
| **Local = remote to localhost** | Same protocol; only the pipe changes |
| **PTY only on the host** | Clients never allocate the agent’s TTY |
| **SSH is a pipe, not a session** | `ssh -tt host claude` is interim debt; target is `ssh → termiod → PTY` |
| **No nested WM** | Tabs/splits stay in the OS / native app (zmx lesson) |
| **No invented crypto** | Build host + protocol; inherit SSH/Tailscale/WSS |

**Vocabulary (use these words, not “the CLI tool”):**

| Say | Don’t say |
| --- | --- |
| host / `termiod` | “the remote CLI” |
| attach client | “ssh session” (for our product object) |
| transport / pipe | “connection mode that owns the agent” |
| session | “tmux window” |

### 4.1 Components

| Component | Responsibility | Non-responsibility |
| --- | --- | --- |
| **Host (`termiod`)** | Session lifecycle, PTY, (later) vt authority, agent events | Window chrome, credentials UI, cloud tenancy |
| **Session Protocol** | Framed control + terminal stream/diffs; versioned `hello` | Knowing if the pipe is SSH or a socket |
| **Transport** | Byte pipe + auth boundary | Session semantics |
| **Discovery** (optional) | `HostRef → Endpoint` | Session protocol itself |
| **Clients** | Render, input, ADE actions | Process lifetime |

One binary may ship host *and* a reference CLI client (tmux/zmx style). That is packaging — **architecture still names the host as the product core.**

### 4.2 Session vs agent workstream

A **session** is the durable runtime (PTY + terminal state).
An **agent workstream** is Termio’s product object on top:

```
Workstream {
  session_id
  agent_id          // claude, codex, …
  project_id / repo
  worktree_path?    // isolation (local or remote host)
  status            // working | idle | needs_you | done | failed | unknown
  current_tool?
  title?
  approval?         // pending human action
  artifacts?        // diffs, pr urls — later
}
```

**Agent-native means these fields are protocol events**, not sidebar cosmetics.

| Status source | Use |
| --- | --- |
| Agent hooks / OSC / transcripts **on the host** | Preferred for needs-you / working |
| Heuristic PTY scrape | Fallback only; never sole long-term design |

### 4.3 Protocol — staged contract

Align with [session-daemon-architecture](20260708-session-daemon-architecture.md):

| Stage | Wire | Purpose |
| --- | --- | --- |
| **v0** | Control frames + **raw PTY** binary | Bootstrap; POC; simple clients |
| **v1** | Host **libghostty-vt**; attach → viewport **snapshot** (+ scrollback slice) | Clean reconnect, multi-client, mobile |
| **v1.1** | Dirty-row / grid diffs at frame cap | Bandwidth + fidelity |
| **always** | list/create/kill/attach, resize claim, **agent status**, roster deltas | ADE |

**Rules:** detach ≠ kill · resize newest-client (v1) · multi-viewer observe yes · default **single writer** until §8 · capability negotiation on `hello`.

**Input replication, not state sync (the anti-100× core).** The host keeps
viewers consistent by shipping the **log** (raw PTY bytes, each client replays
through its own `libghostty` — a deterministic state machine), not by shipping
the **state** (a server grid diffed to clients, the tmux model). State transfer
(`S` snapshot) fires only to bootstrap a viewer that missed the log — on attach,
resize, or resync — never per frame. This yields a hard invariant:

> **Byte delivery MUST NOT block on host-side VT parse.** The authoritative VT
> is a sidecar for snapshots, off the hot path (zmx lesson). Putting a per-frame
> grid encoder between PTY and pipe rebuilds the middle-emulator tax and is
> rejected.

Confirmed empirically: `termiod/bench/bench_100x.py` — termiod sustains
**4–6× tmux's throughput** on identical bytes, and tmux's throughput drops ~50%
plain→ANSI (parser: content-sensitive) while termiod's holds (tee: not). Full
protocol staging and the bad-network `grid_diff` degrade: [termiod-session-protocol.md](20260730-termiod-session-protocol.md) §C.6/§D.1.

### 4.4 Transport and discovery (pluggable, boring)

```
DiscoveryProvider {
  listHosts() -> [HostRef]
  resolve(HostRef) -> Endpoint   // unix | ssh | tailnet | wss
}
```

| Transport | When | Auth |
| --- | --- | --- |
| Unix socket | Host on this machine | Filesystem permissions |
| System SSH | Host on VPS/devbox | ssh-agent / `~/.ssh/config` |
| Tailscale (opt.) | Same, mesh discovery | Tailnet |
| WSS + relay | Phone / hostile NAT | Pairing tokens; optional |

Built-in discovery: **Local** socket · **Static** SSH config hosts · optional **Tailscale**. Core protocol never depends on a vendor.

### 4.5 SSH boundary (deliberate vs Superlogical)

| Superlogical (announced) | Termio |
| --- | --- |
| Mux “owns SSH”; integrated remote | **OpenSSH / user Tailscale** as transport to user-run `termiod` |
| Custody **unknown** | Keys stay in ssh-agent / user config |

Smaller security scope; existing ops muscle. Reconnection polish (ControlMaster, pooling) is UX investment — not a reason to own SSH in-process in v1.

### 4.6 Security / local-first

| Asset | Lives where |
| --- | --- |
| PTY, scrollback, agent events | **Host termiod** (user machine) |
| Credentials | ssh-agent / OS keychain — not Termio cloud |
| Default listen | **Unix socket only** (no public bind) |
| Hosted relay | Optional; never required for local or direct SSH |

### 4.7 Client observation (sidebar performance)

High-frequency fields must **not** ride `TermioStore.objectWillChange`:

- Mirror host events into per-session `@Observable SessionRuntime` — see [sidebar-scroll-performance](20260724-sidebar-scroll-performance.md).
- Structural tree (Host → Project → Worktree → Session) is low-frequency.
- **Forbidden:** full roster replace on every status tick.

### 4.8 Remote worktrees (on the host)

1. termiod on remote ensures main clone / bare repo.
2. `git worktree add` **on that host**.
3. Setup hooks.
4. Agent session `cwd = worktree`.
5. Clients attach by session id.

Cloud sandboxes = Phase 5+ plugins, not v1.

## 5. Competitive matrix (updated)

| Dimension | Superlogical (**announced**) | Termio target |
| --- | --- | --- |
| Durable sessions | Yes | Yes |
| Daemon ≠ viewer | Yes | Yes (`termiod`) |
| Clients | Web, macOS, iOS | macOS, iOS, CLI; web later |
| Stack | Go / Swift / Zig | Host language spike; Swift clients; libghostty |
| libghostty | Public consumer | Public consumer (**shared infra**) |
| Live sharing | Built-in from start | Multi-viewer first; sharing product TBD |
| Tailscale discovery | Direct integration likely | Optional discovery provider |
| Agent-first UX | No (platform) | **Yes (ADE)** |
| Agent status protocol | Not announced | **First-class** |
| Worktree / review ADE | Not announced | **Yes** |
| Multi-agent CLI | Not announced | **`termio sessions`** |
| SSH | Mux owns (details unknown) | System SSH (deliberate) |
| Hosted control plane | Unknown | Not required |
| Full OSS product | Unknown | Daemon + protocol should be open/self-hostable |
| Pricing | Unknown | Existing product model |
| Shipped | No (waitlist) | Partial ADE shipped; mux host not yet |

## 6. Phased delivery

Mapped to the three-step sequence in §0:

| Step | Phase | Outcome |
| --- | --- | --- |
| **1 · Incredible host** | 0–2 | Boundary → local `termiod` → remote host over SSH |
| **2 · Agent-native** | 3–4 | vt/snapshot protocol · host-side status · ADE depth |
| **3 · Multi-device operable** | 4–5 | iOS intervention · discovery · optional share / sandboxes |

### Phase 0 — Boundary

- All create/attach through host API (in-process or localhost).
- Status writes only via `setStatus` / host event → `SessionRuntime`.

### Phase 1 — Local host

- `termiod` process + Unix socket (**host**, not “a CLI”).
- Quit app → sessions live; iOS can hit the same host.
- Reference CLI is an attach **client**.

### Phase 2 — Remote host

- Same `termiod` binary on Linux/macOS; `termio remote setup` / deploy.
- Transport: system SSH (Tailscale if available).
- Remote cwd sessions; then **remote worktrees**.

### Phase 3 — Protocol v1 + unify

- Server-side vt + snapshot resync.
- Host-side agent status for remote.
- Collapse companion-only parallel semantics.

### Phase 4 — ADE depth

- Approvals / needs-you on iOS as intervention surface.
- `termio sessions` over host protocol.
- Optional sharing product semantics.

### Phase 5 — Platform edges (only if earned)

- Partner clients as viewers.
- Optional cloud sandbox provider.

## 7. Client capability matrix (sketch)

| Capability | macOS | iOS | CLI |
| --- | --- | --- | --- |
| Attach / view | ✅ | ✅ | ✅ |
| Input | ✅ | ✅ | ✅ (send) |
| Create session | ✅ | ✅ | ✅ |
| Agent status / tray | ✅ | ✅ roster | ✅ list |
| needs-you intervention | ✅ | ✅ **priority UX** | ✅ answer |
| Scrollback | ✅ full | capped / snapshot | capture |
| File / git review | ✅ | preview | — |
| Voice | — | ✅ | — |
| Background reconnect | ✅ | ✅ | ✅ |

Native Apple clients alone are **table stakes** vs Superlogical; **ADE actions** (status, approve, project context) are the differentiator.

## 8. Open decisions

1. ~~Host language for Linux~~ → **Rust POC shipped** ([#177](https://github.com/termio-sh/termio/pull/177) / #170–#172); revisit only if spike fails product needs.
2. Multi-viewer write policy (single writer vs lock vs CRDT — default single writer).
3. Sharing with external identities: v1 non-goal or scoped feature?
4. Phone → Mac gateway vs phone-direct-to-remote-termiod first.
5. When to freeze Protocol v1 (snapshot) vs extend v0 raw too long. *(Anti-100× property already benchmarked on v0 raw: `termiod/bench`, 4–6× tmux — the raw path is the fast path, so there is no throughput reason to rush v1; snapshot is a correctness/reconnect fix, not a speed fix.)*
6. Commercial: durable remote / relay free vs paid.

## 9. Success metrics

- Quit Mac 30+ min; agents alive; clean reattach.
- Remote VPS agent; reattach from Mac and iOS.
- needs-you on tray for **remote** sessions.
- Sidebar remains scroll-smooth with 10 local + 10 remote working agents ([sidebar-scroll-performance](20260724-sidebar-scroll-performance.md) verification upgraded).
- Users never need tmux for this path.
- No hosted account required for local or SSH remote.

## 10. Risks

| Risk | Mitigation |
| --- | --- |
| Scope creeps to Superlogical’s “all work” | Hard non-goals §3 |
| Underestimating Superlogical | Treat as direct mux competitor; ship ADE wedge faster |
| Freezing raw-PTY forever | Staged protocol §4.3 |
| Status floods kill UI | SessionRuntime discipline §4.7 |
| libghostty as false moat | Compete on agent protocol + local-first |
| SSH UX gap vs integrated mux | ControlMaster, setup helper, discovery providers |

## 11. Relation to existing docs

| Doc | Relation |
| --- | --- |
| [session-daemon-architecture.md](20260708-session-daemon-architecture.md) | Parent host model; **authoritative terminal state** — this doc adds product/competitive/protocol staging |
| [sidebar-scroll-performance.md](20260724-sidebar-scroll-performance.md) | **Client observation** contract for host event volume |
| [remote-projects.md](20260708-remote-projects.md) | Interim SSH path; superseded by Phase 2 |
| [remote-access-relay-strategy.md](20260705-remote-access-relay-strategy.md) | Phone WSS transport |
| [worktree-creation-lifecycle.md](20260706-worktree-creation-lifecycle.md) | Local worktrees; remote creation runs **on termiod host** |

## 12. Decision

**Build `termiod` as a Superlogical-class durable session host** — three clean parts (host · protocol · clients), local = remote to localhost, SSH only a pipe — then win with an **agent-native, local-first ADE** on that foundation. Do not race “multiplexer for all work”; do not describe the architecture as a CLI.

Tracking issue: https://github.com/termio-sh/termio/issues/164  
POC: https://github.com/termio-sh/termio/pull/177
