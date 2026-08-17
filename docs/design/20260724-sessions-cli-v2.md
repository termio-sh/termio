---
title: Sessions CLI v2 — reliability & command design
status: active
type: design
created: 2026-07-24
updated: 2026-07-26
related:
  - 20260708-session-daemon-architecture.md
---

# Design: Sessions CLI v2 — reliability & command design

> The supervision verbs (`spawn` / `send` / `watch`, PR #80) work, but live testing
> exposed a reliability floor the CLI doesn't yet meet: it can report success on
> silence, hang forever on a busy app, and block 15s on `spawn` with no output.
> This doc turns those findings into a v2 design: fail loud, never block, make
> every event actionable, and speak one sync vocabulary across verbs.

## 0. Conclusions first

- **A control CLI must fail loud.** Today an empty socket reply exits `0` — the
  worst possible behavior for a tool driven by agents, which trust exit codes,
  not prose. Empty reply becomes a hard error; every request gets a client-side
  timeout.
- **`spawn` returns the handle immediately.** Boot-settle + prompt delivery move
  off the reply path; waiting becomes explicit (`--wait`). No verb silently
  blocks for 15s.
- **`watch` alone isn't enough to supervise.** It needs an initial snapshot (the
  attach race), a heartbeat (dead-stream detection), and events that carry
  enough to act on — the on-screen question for `needs-you`, the transcript
  cursor for `done`.
- **One sync vocabulary.** `send --wait` (PR #72) waits on one session; `watch`
  waits on any. Same flags, same reply shape, documented as a pair.

## 1. Where v1 stands

After #72 (`--wait`, on its own branch) and #80 (verb split + `watch`, merged):

| Verb | Job | State |
| --- | --- | --- |
| `list` | snapshot of sessions + status | shipped |
| `watch [--state …]` | stream status transitions | shipped (#80) |
| `spawn "<prompt>" [--agent <id>]` | create session, deliver prompt | shipped (#80) |
| `send <handle> "<text>"` | drive / answer an existing session | shipped (#80; absorbed `answer`) |
| `send --wait` / `--timeout` | block until the turn settles | PR #72 **closed** — conflicted after #80/#86; reimplemented in Phase 3, detection logic inherited (§4.4) |
| `close` / `focus` | tab management | unchanged |

## 2. Evidence — what live testing exposed

Findings from driving a dev build end-to-end (2026-07-24), ranked. **Confirmed**
= reproduced with a root cause in hand; **suspected** = observed, cause not yet
isolated.

1. **Empty reply = fake success** (confirmed). `close claude@deadbeef` against a
   wedged app printed nothing and exited `0`. Root cause: `request_once` only
   fails on `error:*` / `"ok":false` matches; an empty `$response` falls through
   to `return 0`.
2. **No client timeout** (confirmed). `nc -U` waits forever; calls hung 15–25s
   whenever the app's main actor was busy. An agent calling the CLI hangs with it.
3. **`spawn` blocks ~15s, silent** (confirmed). The reply waits for
   `waitForBootSettle` (≤10s) + delivery. Orchestrators want the handle *now*.
4. **Head-of-line blocking on main actor** (suspected). During two concurrent
   spawns, `list`/`close` returned empty. `handleSessionControl` runs on the
   main actor and `spawnAndSend` awaits boot-settle inside it. `Task.sleep`
   *should* yield the actor between polls, so the starvation may instead have
   been the dev-channel bundle-id collision swapping app instances — **verify
   with timing instrumentation before designing around it** (§4.2).
5. **`watch` has no initial snapshot.** A supervisor attaching late never learns
   a session is *already* `needs-you`; `list`-then-`watch` has a race window.
6. **`needs-you` events aren't actionable.** No question text; the agent must
   scrape the viewport anyway. Same for `done`: no transcript cursor.
7. **`json_escape` is incomplete.** Only `\` `"` and newline are escaped; a
   literal tab or C0 control char in a prompt produces invalid JSON — same class
   of hand-rolled-protocol fragility as the `build_request | nc` race fixed in #80.
8. **`watch` has no heartbeat or reconnect.** A silently dropped connection looks
   identical to "no transitions"; the hub only reaps dead readers on next write.
9. **No per-verb help.** `spawn --help` prints the global usage.
10. **`cwd` is `""` in events** when the runtime hasn't seen an OSC 7 yet.
11. **Sync semantics are split across PRs.** #72's `--wait` predates the
    `spawn`/`send` split and needs rebasing onto the new verb set.

Test-infra note: three stale `termio-dev` apps from sibling worktrees kept
resurrecting on the shared `sh.termio.app.dev` bundle id / socket, repeatedly
poisoning runs. Not a CLI bug, but it gates trustworthy verification (§7).

## 3. Design principles

- **P1 — Fail loud.** Silence, timeout, malformed reply: all non-zero exit with
  a message naming the next step. Never `0` without a confirmed `ok`.
- **P2 — Never block by default.** Every verb returns as soon as the *request*
  is accepted; waiting for *outcomes* is opt-in (`--wait`) or a dedicated
  streaming verb (`watch`).
- **P3 — Events are actionable.** If an event tells an agent "act here", it must
  carry what's needed to act without a second round-trip.
- **P4 — One sync vocabulary.** `--wait` / `--timeout` mean the same thing on
  every verb that accepts them, and replies share one shape.
- **P5 — The JSON contract is pinned.** `schema_version` on every JSON reply,
  unified error shape `{ok:false, error:<code>, message}`.

## 4. The design

### 4.1 Reliability floor (shell-only)

```
request_once():
  response=$(printf '%s' "$request" | nc -w "${TERMIO_CLI_TIMEOUT:-15}" -U "$SOCKET")
  [ -z "$response" ] && {
    echo "termio: no reply from the app (timed out or not running)" >&2
    return 1
  }
  # existing error:* / "ok":false matching unchanged
```

- Empty reply → exit 1 with a human-actionable message (P1).
- `nc -w` gives every one-shot request a read timeout; `TERMIO_CLI_TIMEOUT`
  overrides for slow machines. `watch` is exempt (it is *supposed* to sit open;
  its liveness comes from the heartbeat, §4.3).
- `json_escape` grows: escape `\t` explicitly, strip remaining C0 controls
  (`tr -d '\000-\010\013\014\016-\037'`). Prompts are text for agent TUIs;
  control bytes in them are never intentional.
- Per-verb help: `sessions <verb> --help` prints a focused usage block
  (one heredoc per verb, dispatched before the socket is touched).

### 4.2 Non-blocking `spawn` (host)

Split `spawnAndSend` into **reply-now, deliver-later**:

1. Create the session + split pane (as today), mint the handle.
2. **Reply immediately**: `started <handle> — prompt queued` (+ handle in JSON).
3. A detached `Task` runs `waitForBootSettle` and delivers the prompt; on
   delivery failure it surfaces via session status (the pane is visibly broken
   anyway) rather than a reply the caller already got.

`spawn --wait` restores blocking, *extended* to #72 semantics: reply when the
turn settles, with the transcript range. So `--wait` means "wait for the
outcome", never "wait for plumbing".

**Field finding (2026-07-25, post-#86): delivery can silently fail.** The first
real fire-and-forget spawn delivered its prompt into a slow-booting TUI and
lost it — session sat `idle`, no transcript, caller none the wiser until a
manual `list` probe. Detached delivery needs a confirmation step: after typing,
re-read the viewport and verify the prompt head landed; retry once, and on
second failure mark the session (status/description) so `list`/`watch` surface
it. `spawn --wait` covers the caller side, but the host should not need a
waiting caller to notice its own delivery failed.

**Head-of-line (finding 4): verify, then fix.** Instrument
`handleSessionControl` with per-op enter/exit timestamps and run
`3 × spawn + list` concurrently. If `list` latency spikes past ~1s while spawns
boot, the fix is already in hand: after this change nothing on the request path
awaits longer than a lock hop, because the only long await (boot-settle) moved
to a detached task. If `list` stays fast, finding 4 was the bundle-id collision
and needs no code.

### 4.3 `watch` v2 (host + shell)

- **Snapshot on subscribe.** On `subscribe`, the hub first emits one line per
  scoped session with its *current* status, tagged `"snapshot":true` in JSON
  (text mode: same line format as live events). Kills the attach race; a
  supervisor can go straight to `watch` with no prior `list`. `--no-snapshot`
  opts out.
- **Heartbeat.** Every 30s of silence the hub writes `{"heartbeat":true}` (text
  mode: nothing — heartbeats are for programs). Gives clients dead-stream
  detection and gives the hub proactive dead-reader reaping instead of
  waiting for the next transition.
- **Actionable payloads** (lands with/after #72, which owns `viewportText`):
  - `needs-you` events add `"prompt": <on-screen question excerpt>`.
  - `done` events add `"transcript"` + `"cursor_end"` so the reply is readable
    without another `list --json` round-trip.
- **`cwd`**: omit the key when unknown rather than emitting `""`.
- **Exit codes**: `0` on interrupt (normal supervision end), `2` when the server
  vanishes (missed heartbeats / EOF) — so a supervising agent can distinguish
  "I chose to stop" from "Termio died".

### 4.4 One sync vocabulary (reimplement #72)

PR #72 predates the verb split and the v2 host rewrite; it was closed as
conflicting. **Port its completion detection, not its wiring**: a turn is
settled when a session seen `working` rests off it for ~1.5s, `needs-you`
short-circuits immediately, and a plain terminal with no status signal falls
back to screen-changed-then-still. Reimplemented on the v2 base, the pair reads:

| Waiting on… | Command |
| --- | --- |
| the one session I just drove | `send <handle> "<text>" --wait [--timeout ms]` |
| a session I'm creating | `spawn "<prompt>" --wait [--timeout ms]` |
| any session in the project | `watch [--state …]` |

All three reply with the same fields on completion: final `status`, `transcript`,
`cursor`..`cursor_end`.

### 4.5 Contract

- `schema_version: 1` on **every** JSON reply (today only `watch` events carry it).
- Errors always `{ok:false, error:<stable-code>, message:<human>}` — the codes
  (`no_scope`, `not_found`, `bad_agent`, `no_reply`, …) become documented API.
- The landing `session-control.mdx` gains a "JSON contract" section listing
  reply shapes per verb — agents are coding against this; stop making them
  reverse-engineer it.

### 4.6 Caller envelope — the spawned agent knows who sent it

Today a spawned sibling has no idea who spawned it: if it has a mid-task
question it can only stop as `needs-you` and hope the supervisor notices via
`watch`, then reads its screen. The host already knows the caller —
`ControlRequest.caller_session` arrives with every request — so `spawn` can
prepend a provenance envelope to the delivered prompt, with zero shell changes:

> You were spawned by `<caller-handle>`. To ask them a question mid-task, run
> `termio sessions send <caller-handle> "<question>"`. Otherwise just finish —
> they read your transcript.

Hard rules, stated in the envelope itself (agent↔agent messaging invites loops
and injection):

- Reply-to-caller is for **questions and a one-line completion ping only** —
  never conversation, never new task delegation back to the caller.
- Completion reporting stays **transcript-as-truth**: the envelope must not
  encourage summarizing results into a message (workers forget instructions;
  the supervisor's `watch`/transcript path is the reliable one and remains the
  backstop regardless).
- Only injected when the caller *is* a Termio session (`caller_session`
  resolves); a plain-shell `spawn` gets no envelope.

### 4.7 Loop-level stall detection — `stalled` watch events (Phase 4)

`prompt_stalled` (#88) answers "did my input land" at second-scale. This answers
the fleet-scale runaway: a session that is `working` for tens of minutes while
producing nothing — the unattended-runaway anti-pattern (arXiv 2607.00038), the
one loop-engineering primitive the supervision plane can uniquely own. Prior
art is all in-harness (OpenHands StuckDetector kills its own agent off its own
event stream, with documented false-kills on legitimately slow builds); Termio
watches any agent from outside, across the fleet.

**Two design laws, learned from OpenHands' scars:**

1. **Signal, never kill.** Termio emits an event; the supervisor (agent or
   human, possibly on the phone) decides. A wrong alert costs nothing; a wrong
   kill destroys a long legitimate task.
2. **Multi-signal AND, edge-triggered.** No single signal may fire alone; any
   progress marker re-arms the window.

**Probes** (evaluated lazily, cheapest first; expensive ones off the main
actor — the BranchModel main-thread-git freeze is a known hazard):

| # | Probe | Signal | Cost |
| --- | --- | --- | --- |
| 1 | Working duration | continuously `working` ≥ 20 min (`workingSince` stamped in `setStatus` on the transition) | timestamp compare |
| 2 | Repo fingerprint | `git rev-parse HEAD` + hash of `git status --porcelain` in the session's cwd/worktree unchanged across the window | one git exec / sweep, off-main |
| 3 | Transcript growth | transcript file grew < K lines over the window | one `stat` |
| 4 | Output byte-rate (suppressor) | sustained novel PTY output (build logs scrolling) suppresses the alert — spinner repaints are too small to trip it | existing PTY activity stamps |

Verdict: `1 AND 2 AND 3 AND NOT 4` → emit once, then hold until a progress
marker (new commit, tree change, transcript burst) resets the window.

**Plumbing.** `stalled` is a **watch-plane event, not a fifth `SessionStatus`**:
the session's real status stays `working` (the sidebar is untouched; the
*supervisor's judgment* is what's being broadcast). `SessionWatchHub` events
gain an `evidence` string:

```json
{"handle":"claude@ab12","status":"stalled",
 "evidence":"working 42m, no commit, transcript +3 lines",
 "schema_version":1}
```

The sweep rides the existing stale-working sweep timer in
`TermioStore+AgentStatus`; per-session probe state (`workingSince`, repo
fingerprint, transcript size, last-alert) lives beside it. The CLI needs no new
flags — `--state stalled` already parses; v1 keeps it **out of the default
filter** until the thresholds have been tuned against real fleets, then it
graduates into `done,needs-you,stalled`.

**Phase 4b (later):** cross-agent tool-signature repetition — parse the
transcript tail's tool calls (name + normalized input, the OpenHands semantic
compare) to catch "Bash(npm test) × 7" loops that do touch the repo. Needs the
per-agent transcript schemas; ship 4a without it.

## 5. What we deliberately do NOT build

- **No `--key` / raw-keypress verb.** Every built-in agent's permission prompt
  accepts text+Return (proven by `answer`'s history). Revisit only when a real
  menu refuses text.
- **No multi-target send / broadcast.** One request, one target — the targeting
  discipline stays a hard rule.
- **No daemon.** The app remains the server; the CLI stays a thin `nc` client.
  (If the app must be running anyway to host the PTYs, a daemon adds surface,
  not capability.)
- **No CLI config file.** One env var (`TERMIO_CLI_TIMEOUT`) is the entire
  configuration surface.

## 6. Phasing

| Phase | Scope | Risk | Contents |
| --- | --- | --- | --- |
| 1 | shell only | trivial | empty-reply failure, client timeout, `json_escape` hardening, per-verb help (§4.1) |
| 2 | host | moderate | non-blocking `spawn` + head-of-line verification (§4.2); `watch` snapshot, heartbeat, `cwd`, exit codes (§4.3) |
| 3 | host + shell | moderate | reimplement `--wait` on the v2 base, `send` + `spawn` (§4.4); actionable `needs-you`/`done` payloads (§4.3); contract docs (§4.5); caller envelope (§4.6) — **shipped #87/#88** |
| 4 | host | moderate | loop-level stall detection: `stalled` watch events with evidence, probes 1–4, signal-not-kill (§4.7) — **4a shipped #92**; 4b tool-signature repetition later |

Each phase is one PR; Phase 1 can ship today with no app update (the installed
CLI is a copied script).

## 7. Test plan

Scripted matrix (superset of the 2026-07-24 manual run):

- All verbs × `--json`/text × error paths (bad agent, bad handle, no prompt,
  no handle) asserting **exit codes**, not just output.
- **Silence tests**: SIGSTOP the app mid-request → expect timeout + exit 1
  within `TERMIO_CLI_TIMEOUT`; kill the app under an open `watch` → expect
  exit 2 after missed heartbeats.
- **Hostile input**: prompts containing tabs, control chars, `"` `\`,
  handle-shaped leading words, 10KB bodies.
- **Concurrency probe**: `3 × spawn` while sampling `list` latency each 500ms —
  the §4.2 verification, kept as a regression test.
- **Watch semantics**: snapshot lines on attach, default filter drops `working`,
  heartbeat cadence, reconnect behavior.

Prerequisite: fix the dev-channel collision that poisoned this round —
per-worktree dev channels (`TERMIO_CHANNEL=dev-<slug>` deriving bundle id,
support dir, and socket) so parallel worktree builds stop fighting over
`sh.termio.app.dev`. Without it, none of the above is trustworthy.
