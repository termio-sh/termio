---
title: Research brief — termiod Session Protocol (for design agent)
status: active
type: design
created: 2026-07-30
updated: 2026-07-30
related:
  - 20260730-termiod-session-mux.md
  - 20260708-session-daemon-architecture.md
---

# Research brief: termiod Session Protocol (transport-agnostic)

> Hand this entire file to a design agent. Output should land at
> `docs/design/20260730-termiod-session-protocol.md` (new design doc) unless the agent
> is told otherwise.

You are a senior systems architect. Think deeply and write a **sharp design note** for Termio’s durable session host protocol. Do **not** implement code unless a tiny example clarifies a wire shape. Prefer clear decisions, tradeoffs, and a staged roadmap over vague vision.

---

## 1. Company / product context (Termio)

**Termio** is a native macOS (and iOS) multi-agent terminal ADE: run many agent/shell sessions (Claude Code, Codex, etc.), status tray, worktrees, `termio sessions` CLI. Today PTYs largely live **inside the Mac app**, so sessions die when the GUI dies; remote is second-class (`ssh -tt` hacks / tmux wraps).

**Goal:** introduce **`termiod`** — a long-lived **session host** on each machine (Mac and Linux VPS). Viewers (Mac app, iOS, CLI) only **attach/detach**. Detach ≠ kill.

**Thesis (do not abandon):**

- Architecture is **composable** and **direct**.
- **Composable:** host · protocol · clients · transports plug independently (any client, any pipe, any host).
- **Direct:** one hop to authority — `client → protocol → host → PTY`. No second session owner, no nested window manager, no product-level proxy that owns the process.
- Win on **agent-native ADE** (workstreams, `needs-you`, worktrees, multi-agent supervision), not by cloning a generic “multiplexer for all work.”

**In-repo design (source of truth — read these):**

- `docs/design/20260730-termiod-session-mux.md`
- `docs/design/20260708-session-daemon-architecture.md`
- POC crate: `termiod/` (branch `termiod/rust-poc`, draft PR #177)
- Epic: https://github.com/termio-sh/termio/issues/164
- Children: #170 (local host), #171 (SSH deploy), #172 (remote open)

**POC already shipped (draft):**

- Rust binary = host + reference CLI client
- Protocol **v0:** framed `[kind:u8][len:u32 BE][payload]` — control JSON (`C`), raw PTY (`D`), resize (`R`)
- Local: Unix socket under XDG_RUNTIME_DIR
- Remote: **system OpenSSH** as pipe (stdio bridge); daemon owns PTY on VPS; no public TCP bind by default
- Multi-client fan-out, single-writer (newest claim), ring replay on reattach
- Smoke: local 16/16; fake-ssh remote 8/8; **live VPS pass still pending**
- Explicitly **out of POC:** libghostty-vt snapshot/diffs, Mac/iOS wiring, host-side agent status as first-class events

---

## 2. Superlogical — primary competitive / architectural foil

**Read these primary sources carefully before designing** (do not rely on secondary summaries alone):

1. https://www.superlogical.com/
2. https://mitchellh.com/writing/superlogical
3. Optional: HN discussion around the launch (e.g. item 49098965) and Mitchell’s public X replies if useful — mark anything non-primary as **uncertain**.

### 2.1 What Superlogical is (announced / pre-beta — not fully shipped)

- New company (public ~2026-07-29): Mitchell Hashimoto, Jack Pearkes, Alasdair Monk, Hector Simpson.
- Vision: **“the multiplexer for all work”** — local dev, remote access, coding agents, background jobs, production apps, live debugging, sandboxes, shared terminals, incident response, humans and machines, operational history, multiplayer.
- Stated build sequence:
  1. **Build an incredible multiplexer**
  2. **Make everything in it composable**
  3. **Make it safe and operable in production**
- They **start with a terminal multiplexer**: long-lived sessions, reconnect from another device, multi-block organization, web + **native macOS/iOS**, **live sharing built in**, native scrollback/selection (fixing tmux papercuts).
- Terminal mux is framed as the **right foundation** because terminals connect developers, agents, tools, and infrastructure — not because the company is “only a terminal app.”
- Stack (Mitchell): **server/networking = Go**, **native Apple apps = Swift**, **low-level bits = Zig**.
- Uses **libghostty** as a public MIT building block (“Not Ghostty btw (but, libghostty)”); Ghostty nonprofit stays independent. **libghostty is not a moat.**
- Positioning vs agents: supports agents well; **not agent-specific / less AI-focused, more platform**.
- vs herdr/cmux: not a clone; those may become **partners** (their terminals become remote clients of the mux).
- vs classic tmux architecture: cloning nested-terminal muxes called an **architectural dead end** for their goals; rebuild foundation.
- SSH: mux is said to **own SSH** / durable remote as a session resource — **implementation details unpublished**.
- Discovery: **Tailscale-class** one-config discovery likely; details unpublished.
- Funding: Notable Capital, Amplify Partners + notable angels (announced). Full OSS product: **unknown**.

### 2.2 Evidence policy (mandatory)

Label every Superlogical claim you use as:

- **Announced** (on superlogical.com / Mitchell’s post)
- **Inferred** (reasonable but not stated)
- **Unknown** (not public)

Do **not** invent Superlogical’s wire protocol, RPC schema, or QUIC/SSH internals. They have not published a protocol spec.

### 2.3 Overlap vs Termio (session layer)

**Real overlap:** durable sessions, daemon ≠ viewer, Mac+iOS, remote reconnect, multi-client, libghostty fidelity, agents-in-terminals, software-driven control, native scrollback UX.

**Termio differentiation (keep sharp):**

- Agent workstream as first-class object (`working` / `idle` / `needs-you` / approvals)
- Opinionated worktrees / ADE workflow
- `termio sessions` multi-agent supervision CLI
- **Local-first:** no hosted control plane required for local or direct SSH/Tailscale
- Deliberately **narrower** than “multiplexer for all work” (no CI/production fabric as v1 goal)

**Architectural fork we already chose vs Superlogical’s announced SSH stance:**

- Superlogical: mux “owns SSH” (details unknown).
- Termio: **system OpenSSH / user Tailscale as transport** to a **user-run `termiod`**; keys stay in ssh-agent. Smaller security scope; may lag on seamless reconnect UX.

---

## 3. Other prior art (use selectively)

| Project | Lesson |
| --- | --- |
| **neurosnap/zmx** (https://zmx.sh) | Session persist only; daemon + unix socket; VT as **sidecar** for reattach snapshot, not MITM on hot path; SSH first-class as *workflow*, not nested WM; no panes in the daemon |
| **shpool** | Session pool + restore inspiration |
| **abduco / dtach** | Minimal attach/detach |
| **tmux / zellij** | Durable sessions but nested terminal / feature lag — Superlogical and Termio both want to escape this as the *foundation* |
| **wezterm mux-server** | Multi-client mux patterns |
| **Companion / Termio WireProtocol** | Existing iOS path: control text + raw PTY; promote carefully, don’t freeze raw-PTY forever |

---

## 4. Design principles (non-negotiable)

1. **Host ≠ viewer** — process lifetime lives in `termiod`.
2. **Local = remote to localhost** — same protocol; only the pipe changes.
3. **PTY only on the host** — clients never allocate the agent’s TTY as the product path.
4. **SSH is a pipe, not a session** — forbid productizing `ssh -tt host claude` as the long-term model.
5. **No nested window manager** inside the host (tabs/splits = OS / native app).
6. **No invented crypto in v1** — don’t build mosh/QUIC-auth theater before the session contract is right.
7. **Protocol is the product core** — elegant, stable, powerful; transports are adapters.
8. **Composable · Direct** — composition must not add indirection that re-owns the session.
9. **Agent-native is a protocol concern** — status/approvals are events, not only PTY heuristics or sidebar cosmetics.
10. **Stage terminal fidelity** — v0 raw bytes → v1 host vt snapshot → v1.1 dirty-row diffs (libghostty-vt or equivalent). Do not freeze raw-PTY-only forever.

---

## 5. The open question we want you to own

### Protocol over transports

We believe the **Session Protocol** should be transport-agnostic and should be able to run on:

- **Unix domain socket** (local default)
- **SSH** (stdio / ControlMaster — remote default today)
- **QUIC** (later: multi-stream, roaming, phone-direct / mesh — optional)
- **WSS + relay** (phone / hostile NAT — optional)

**Your job:** design the protocol so it is **elegant, stable, and powerful**, and specify cleanly how SSH vs QUIC (and Unix/WSS) bind underneath **without** forking session semantics.

Constraints / opinions to challenge or refine (argue with evidence):

- Default remote today = SSH pipe; QUIC only when multi-stream/roaming/identity cost is justified.
- Avoid raw TCP + DIY TLS as a third path.
- On SSH/Unix: userland framing/multiplex is OK.
- On QUIC: map logical channels → streams (control / terminal / events) if that is cleaner — but **nouns stay the same**.
- Hot path should stay cheap (bytes or diffs); VT is host-side authority / sidecar for resync, not a parse tax on every peer for every keystroke if avoidable.
- Versioning: `hello` + capability bits; additive evolution; hard refuse on incompatible versions (don’t silently corrupt sessions like weak IPC upgrades).

---

## 6. What “elegant / stable / powerful” must mean (define and apply)

Propose concrete criteria, e.g.:

**Elegant**

- Small set of nouns/verbs
- One attach model for Mac, iOS, CLI
- Clear ownership (who resizes, who writes, who holds scrollback)

**Stable**

- Protocol version vs binary version
- Compatibility matrix (old client / new host)
- What is frozen in v0 vs deliberately unstable
- Test strategy (codec + state machine golden tests)

**Powerful** (enough for Termio ADE — not Superlogical’s entire vision)

- Durable multi-attach
- Clean reconnect (snapshot)
- Agent events (`working` | `idle` | `needs_you` | approvals…)
- `send` / list / wait without full TTY attach
- Resize arbitration
- Future optional: share, file/git channels — capability-flagged, not v0 bloat

Explicitly list **non-goals** for protocol v1 so we don’t race Superlogical’s “all work” surface.

---

## 7. Deliverables (write these sections)

Produce a design note with:

### A. Executive recommendation (≤15 lines)

What the protocol *is*, what transports we support when, and the one-sentence differentiator vs Superlogical’s mux layer.

### B. Domain model

Session vs agent workstream vs client vs host vs transport endpoint. IDs, lifetime, detach vs kill.

### C. Session Protocol specification (v0 → v1 → v1.1)

- Message catalog (control / terminal / events)
- Framing
- `hello` / capabilities
- Attach flow, multi-writer policy, resize policy
- Error model
- Security-sensitive fields (what must never appear on untrusted relays)

### D. Transport bindings

For each of Unix socket, SSH, QUIC, WSS:

- How auth works
- How streams/channels map
- Failure / reconnect behavior
- When to use it in product

Argue **SSH vs QUIC** explicitly: complementarity, not either/or religion.

### E. Comparison matrix

Termio protocol vs: Superlogical (announced only), tmux, zmx, herdr-style remote, current Termio Companion wire.

### F. Risks & open decisions

Including: phone → Mac gateway vs phone-direct-to-remote-termiod; whether host “owns SSH” later; sharing ACL; relay threat model.

### G. Phased roadmap

Aligned with: (1) incredible host (2) composable agent surface (3) multi-device operable — and mapped to GitHub #164 / #170–#172 / post-POC work.

### H. What to reject

A short “beautiful ideas we will not do” list (e.g. gRPC for PTY hot path, protocol = shell over SSH, freeze raw PTY forever, public 0.0.0.0 by default, full multiplayer CRDT typing in v1, etc.).

---

## 8. Quality bar

- Prefer **decisive** recommendations with tradeoffs over “it depends” without a default.
- Cite Superlogical claims with **Announced / Inferred / Unknown**.
- Keep Termio’s wedge: agent-native + local-first + direct; do not redesign Termio into Superlogical.
- Write so an engineer can implement protocol v0.1 / v1 from your note without reading this brief again.
- If you need a wire example, show 1–2 attach sequences end-to-end (local + remote-SSH + future-QUIC) with the **same** messages.

---

## 9. Start here

1. Open https://www.superlogical.com/ and Mitchell’s post; extract only load-bearing architectural claims.
2. Read Termio design docs / `termiod` POC behavior in this workspace.
3. Write the design note to **`docs/design/20260730-termiod-session-protocol.md`** with YAML front matter:
   ```yaml
   ---
   title: termiod Session Protocol
   status: draft
   type: design
   created: YYYY-MM-DD
   updated: YYYY-MM-DD
   related:
260730-termiod-session-mux.md
260708-session-daemon-architecture.md
260730-_research-session-protocol-brief.md
   ---
   ```
4. Bump `related` in `20260730-termiod-session-mux.md` to include `20260730-termiod-session-protocol.md` if you edit that file.
5. End with: **top 5 decisions that need a human product call** (not engineering bikesheds).
6. Comment a short summary on GitHub issue #164 when done (optional but preferred).
