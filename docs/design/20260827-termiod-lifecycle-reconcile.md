---
title: termiod lifecycle — install and update as one reconcile loop
status: in-review
type: rfc
created: 2026-08-27
updated: 2026-08-29
related:
  - 20260825-agent-integration-moves-to-termiod.md
  - 20260824-agent-integration-on-a-device.md
  - 20260819-unify-server-plane.md
  - 20260814-remote-to-device.md
  - 20260730-termiod-session-protocol.md
---

# termiod lifecycle: install and update as one reconcile loop

> The Mac is a control plane and every termiod is a data-plane node. Install
> and update are not two features; they are one loop — observe the node, diff
> against what should be there, act, verify, roll back — and the node reports
> its own state instead of being probed. This RFC specifies that loop, the two
> protocol additions it needs, and the one thing it deliberately does not do.

## 0. What was checked before writing

Every claim below about shipped code was verified against
`fix/termiod-remote-deploy` (PR #496) and against the daemon running on the
author's VPS on 2026-08-27.

| Claim | Where |
| --- | --- |
| The app bundle already ships static Linux daemons for both architectures | `termio.app/Contents/Resources/termiod-{x86_64,aarch64}-unknown-linux-musl`; `scripts/build-app.sh:298` |
| Deploy is already atomic: upload beside, `rename(2)` over | `termiod/src/remote.rs` `deploy()` |
| The handshake carries a protocol number and capabilities but **no build version** | `protocol.rs` `Hello { proto, min_proto, role, caps, client }`, `HelloOk { proto, caps, host_id, host, client_id, home }` |
| `PROTOCOL_VERSION` has been `1` since the first commit | `protocol.rs:28` |
| The daemon already drains cleanly on `SIGTERM` | `daemon.rs:449–490` — `begin_draining` / `finish_draining`, socket removed last |
| Supervision exists on macOS only (launchd); Linux is `setsid` autostart on first client contact | `service.rs` header; `client.rs:75` `spawn_daemon` |
| "Set up this device" is a ladder of **ten** sequential ssh round trips across two languages | `TermioStore+Termiod.swift:970–1090` `performRemoteReadyCheck` |
| The ladder never reads a version; it infers "old" from the absence of the `agents` capability | `TermiodClient.swift:658` `supportsAgentInstall` |
| The restart step can never match: `$HOME` is interpolated inside single quotes and `pkill` exit 1 is accepted as success | `TermioStore+Termiod.swift:1134–1137` |
| The idle check computes `attachedClients`, prints "nobody attached", then ignores it | `TermioStore+Termiod.swift:1099–1110` `staleDaemonHolds` |
| A previous binary is already kept on the box and nothing uses it | `~/.local/bin/termiod.prev` on the VPS, written by an earlier deploy |

The VPS at the time of writing had six `termiod serve` processes from protocol
testing, on six different sockets. An argv-matched `pkill` would have hit two
of them; the one on the canonical socket was holding a login shell nobody had
attached to for eleven hours.

## 1. The problem

Setting up a machine today fails in a way the user cannot act on:

> Updated termiod on ukvps, but the daemon still running there is the older one
> and can't install agent integration. Restarting it would kill what it is
> hosting, so it is left alone: • /bin/bash (login shell) · nobody attached.
> Close those on ukvps and set it up again.

Four things are wrong at once, and they share one root:

1. The Mac cannot tell *what version* is on the box, only *whether a capability
   is present*, so it redeploys on every skew and cannot distinguish "old
   daemon" from "old binary" from "handshake failed".
2. The Mac tries to restart the daemon by guessing its process from its command
   line, and the guess is wrong by construction.
3. The Mac has the information to know the daemon is idle and does not use it.
4. Install and update are two code paths with a third — the failure above —
   that is neither, and has no command that resumes it.

The root: **the control plane is reconstructing the node's state from shell
probes instead of asking the node**, and it has separate procedures for each
state it can imagine instead of one loop that handles any state.

## 2. The model

Every modern control plane — the kubelet, Terraform, Ansible, Teleport's agent
updater — is the same abstraction:

```
reconcile(desired, observed) → actions
```

Install is reconcile from an empty box. Update is reconcile from a stale one.
Repair is reconcile from a broken one. There is one code path; it is idempotent;
and **recovery from any failure is "run it again"**. The screenshot above stops
being an error with instructions and becomes a state the loop resumes from.

For termiod, `desired` is fixed by the Mac's own bundle: *the daemon version
this app ships, running, with this user's agent integration installed.*
`observed` comes from the node.

## 3. Observe: the node reports itself

Add one read-only subcommand, run on the box by whatever binary is on disk:

```
termiod status --json
```

```json
{
  "binary":  { "version": "0.44.0", "path": "/home/ubuntu/.local/bin/termiod" },
  "daemon":  { "running": true, "version": "0.43.0", "pid": 2496439,
               "socket": "/run/user/1001/termiod/termiod.sock" },
  "sessions": [
    { "id": "1c2be530", "command": "/bin/bash (login shell)",
      "attached": 0, "alive": true }
  ],
  "host_id": "…",
  "supervisor": "none" | "launchd" | "systemd-user"
}
```

Three rules:

- **One round trip.** This replaces `test -x`, two handshakes, and a roster
  read. Latency to a VPS is 200–300 ms per fresh ssh; the ladder today is
  two to three seconds of pure waiting before anything is written.
- **The daemon's version comes from the daemon, not from `--version` of the
  file on disk.** They differ exactly when an update has been staged but not
  activated, and that is the state the loop most needs to see.
- **`daemon.pid` comes from the socket, not from `ps`.** The CLI connects to the
  canonical socket and reads `SO_PEERCRED`. This identifies the process that
  *owns the socket*, which is the only process the loop may ever stop. It
  works against a daemon of any version because it never speaks the protocol.

For a daemon too old to answer a `status` control message, the CLI falls back
to what old daemons can answer — `list` over the existing protocol — and
reports `daemon.version: null`. The loop treats null as "older than anything
that reports a version", which is correct.

## 4. Install

Install is the `observed = {}` branch of the loop. Four principles, each
already the shape of the shipped code or a one-line change to it:

**The bootstrap channel is borrowed.** System ssh, the user's `~/.ssh/config`
as the authority. This is non-negotiable §3 of the session protocol and it is
also what every agentless system does (Ansible is nothing but ssh). Nothing
here adds a transport.

**The artifact is one static binary, chosen by the control plane.** The bundle
ships musl builds for both Linux architectures; `uname -sm` picks one. The box
never needs cargo, zig, or a package manager. `cross_compile()` in `remote.rs`
stays as a developer fallback and is never reached from the app.

**The daemon is handed to the OS supervisor when there is one.** `service.rs`
does this for launchd. The Linux half — a systemd `--user` unit plus
`loginctl enable-linger` — is specified there and was built after this RFC
(2026-08-29); it records that `status.supervisor` is the field that will
tell the loop whether "restart" means `systemctl --user restart termiod` or
"stop it and let the next client autostart it". Both paths converge on the same
loop; only the activate step differs.

**Install produces an identity, not just a file.** `host.id` is already written
on first start. The loop's last step registers it in the device list, which is
what makes every later run a lookup instead of a probe.

## 5. Update

Update is where the real tension lives: **the process being replaced holds
state that cannot be rebuilt** — a PTY with an agent in it. The loop splits
this into four steps with different risk, and names the state between each.

### 5.1 Stage

Upload beside the target, `rename(2)` over it. Already shipped and already
correct: atomic on the filesystem, safe against a running daemon (it keeps the
old inode), safe to repeat. One addition: **keep the previous binary** as
`termiod.prev` before the rename. This is an A/B slot, the precondition for
rollback in §5.4, and it is what the box already has by accident.

After stage, the node is in a named state: **staged** — binary new, daemon
old. This is not an error. The device pane shows it as one line ("Update ready,
waiting for the daemon to be idle"), not as a failure.

### 5.2 Activate

The one disruptive step. It is a request to the node, made by the *new* CLI
running on the box:

```
termiod stop --if-idle [--force]
```

- Find the daemon by `SO_PEERCRED` on the socket (§3). Never by argv.
- Ask it what it holds — `list` over the existing protocol, which every
  shipped daemon answers.
- **Idle** means every live session has `attached == 0`. Exit code 0 after
  `SIGTERM` and waiting for the socket to disappear; the daemon's existing
  drain path handles the rest.
- **Busy** means at least one session has a client attached. Print the
  sessions by name — the user decides whether to close an agent mid-task, and
  a count cannot inform that decision — and exit non-zero. `--force` overrides.

Two properties matter here:

*It works on the first upgrade.* The old daemon needs no new protocol message;
`SO_PEERCRED` and `SIGTERM` are kernel facilities and `list` is protocol v1.
There is no "upgrade once by hand to get graceful upgrades after that".

*"Idle" is decided by the node, with the node's information.* The Mac never
computes it. This is the HDFS `shutdownDatanode … upgrade` shape: the control
plane requests, the node — which alone knows what it holds — decides how to
leave.

The daemon comes back on the next client contact via the autostart that
already exists. On a supervised box the same command becomes
`systemctl --user restart` once §4's Linux unit lands; the loop does not
change.

### 5.3 Verify

Handshake with the new daemon and compare `HelloOk.version` (§6) to the
bundled version. Then install agent integration through the existing
`install_agents` message. Success is *verified*, not inferred from `pkill`
having exited.

### 5.4 Roll back

If the handshake fails, or the new daemon never binds its socket within a
timeout: `mv termiod.prev termiod`, stop whatever is running, let autostart
bring the old one back, and report the failure with the new binary's stderr.
The user is left on the version that worked. Teleport's updater does exactly
this; so do ChromeOS and Android at the partition level.

### 5.5 The Mac's bookkeeping

While a device is between 5.2 and 5.3, the Mac marks it **upgrading**. Not
offline, not unreachable. No reconnect storm, no red dot, no "device
unreachable" alert. A timeout degrades it to unreachable. This is the cheapest
rule in the RFC and the one the current code most visibly lacks: today, a
daemon the Mac itself asked to exit looks identical to a dead machine.

## 6. Protocol changes

Two, both additive under protocol v1:

1. **`HelloOk` gains `version: String`** — the daemon's build version
   (`CARGO_PKG_VERSION`). Optional with `serde(default)`, so old clients ignore
   it and old daemons omit it. From this point `PROTOCOL_VERSION` starts
   meaning something: the Mac states the range it supports, and skew is a
   sentence ("termiod 0.43 on ukvps; this app needs 0.44") instead of a
   silently missing capability.
2. **`Control::Status` / `Control::StatusReply`** carrying the fields in §3.
   Answered by daemons from this version on; §3 defines the fallback for older
   ones.

No message is needed for *stop*. A control-message shutdown would be cleaner
than `SIGTERM`, but it would only work against daemons that already have it,
which is the bootstrap problem this RFC is avoiding. It can be added later as a
refinement; the `SO_PEERCRED` + `SIGTERM` path stays as the floor.

## 7. What the Swift side becomes

`performRemoteReadyCheck` today is ~120 lines that probe, deploy, re-probe,
inspect the roster, and try to `pkill`. Under this RFC it is:

```
status   ← ssh host termiod status --json          (or "no binary")
if binary missing or binary.version < bundled:
    scp + rename                                    (stage)
if daemon.version < bundled:
    ssh host termiod stop --if-idle                 (activate; busy → report names)
hello → verify version → install_agents            (verify)
on failure → mv termiod.prev termiod               (roll back)
```

Three to four ssh operations, one decision, all state read from one JSON
document. The `$HOME`-in-single-quotes bug, the two redundant handshakes, and
the `.sessions`-ignores-`attached` bug are deleted, not fixed.

## 8. Control-plane state machine

The device pane today has one cached state. It needs these, and §3 supplies
every one of them from a single read:

| State | Meaning | Shown as |
| --- | --- | --- |
| `absent` | reachable, no binary | "Set up this device" |
| `staged` | binary new, daemon old, busy | "Update ready — close *n* sessions" (named) |
| `upgrading` | Mac asked the daemon to stop; waiting | spinner, no alert |
| `current` | daemon version == bundled, hooks installed | nothing to do |
| `unhealthy` | new daemon failed verify; rolled back | the new binary's error |
| `unreachable` | ssh failed | ssh's own last line |

`staged` and `upgrading` are the two the current code cannot represent, and
the absence of each produces one of the confusing messages users see today.

## 9. What this RFC does not do

**It does not make sessions survive an upgrade.** Under this RFC, activating an
update still kills the daemon's sessions — it only refuses to do so when a
client is attached, and asks first.

The correct fix is known and it is not small. Docker, Kubernetes, and Nomad all
converged on the same shape: *the process that changes often must not be the
process that holds the irreplaceable state.* A per-session holder process — the
`containerd-shim` / Nomad `executor` pattern — owns the PTY master and outlives
the daemon; the daemon re-adopts its sessions on start. That gives
upgrade-survival and crash-survival in one move, at the price of one process per
session and a reattach protocol whose failure modes are a long tail (Nomad's
issue tracker is the honest preview).

Two alternatives were considered and rejected for this data plane:

- **In-process handoff** (nginx / HAProxy hot restart, systemd's fd store):
  pass the PTY fds to a new instance of the daemon. This is the right tool when
  the thing handed over is *retryable* — a listening socket; if the new process
  fails, clients reconnect. A PTY with an agent in it is not retryable; a
  failed handoff loses it with no fallback.
- **Persist and re-adopt** (YARN NodeManager work-preserving restart): only
  possible when the manager holds no lifeline fd to the work. YARN redirects
  container I/O to files; termiod holds the PTY master, and closing it SIGHUPs
  the shell.

The holder-process design should be its own RFC, and **this RFC is its
precondition**: without version negotiation (§6), a status report (§3), and a
verify-and-roll-back loop (§5.3–5.4), a reattach failure would be
undiagnosable. Build the loop first.

**It does not add pull-based updates.** Teleport, Tailscale, and cloudflared
agents poll for their desired version. termio has no hosted control plane to
poll and, by design, never will; the Mac pushes over the channel the user
already trusts. The cost — a machine does not update while the Mac is closed —
is accepted for the fleet size this targets (one to a few machines the user
owns) and is consistent with "the session lives on the box": the update is not
part of the session.

## 10. Prior art

| System | What it contributes here |
| --- | --- |
| Kubernetes kubelet / Terraform / Ansible | one reconcile loop; install = reconcile from empty |
| HDFS `shutdownDatanode … upgrade` | stop is a request with intent; control plane marks "restarting ≠ dead" |
| Teleport Managed Updates v2 | control plane owns the version; verify after switch; automatic rollback; updater is not the updated |
| k3s | single static binary, zero host dependencies; systemd unit on install |
| ChromeOS / Android / CoreOS | A/B slots: keep the previous artifact to make rollback possible |
| cloudflared graceful restart | new process up and connected *before* the old one drains |
| Docker / Nomad / containerd | the stability gradient — deferred to the holder-process RFC (§9) |

## 11. Implementation notes

Built as `termiod/src/lifecycle.rs` on 2026-08-27. Where the code departs from
the text above, the code is right and the reason is recorded here:

- **The loop lives in the daemon, not the app.** `termiod deploy [--host]`
  runs observe → stage → activate → verify → roll back against a `Node` — this
  machine, or a box over the user's ssh — and prints one JSON `Report` in the
  §8 vocabulary. `termiod remote deploy` is the same loop. §7's Swift is one
  process call and a decode (`Termiod.LifecycleReport`); the ladder, its
  `pkill`, and `supportsAgentInstall` are deleted. One ssh wrapper remains.
- **The version is the app's build stamp**, `0.44.0+1533`, not the crate
  version (pinned at 0.1.0 and never comparable). `termiod/build.rs` takes it
  from the same `TERMIO_VERSION`/`TERMIO_BUILD` the bundle is stamped with; a
  checkout reports `0.0.0+<commit count>`, which orders below every release so
  a dev build never stages itself over a released box. Compared as
  `(semver, build)`.
- **§6 item 2 (`Control::Status`) was not added.** `hello_ok.version` plus the
  existing `list` answer every field of §3, and both work against the daemons
  already deployed; a status message only new daemons answer is the bootstrap
  problem this RFC set out to avoid.
- **§3's bootstrap gap is wider than an old daemon:** `status` runs by the
  binary on disk, and the binary on the first upgrade has no `status`. The
  loop reads clap's "unrecognized subcommand" as *older than anything*, stages
  first, and observes again with the new binary.
- **Idle (open question 1) is decided, and §5.2's `attached == 0` is not it.**
  Busy means *work in progress*: a command running in the foreground
  (`foreground_job`, the daemon's own "closing this loses work" signal) or a
  session `working` / `needs_you`. Being attached does not count — the client
  on an idle prompt is usually the app whose user just asked for the update,
  and an update the user's own tabs could veto has them closing tabs to get
  it. `stop` declines by default and names the sessions (exit 3); `--force`
  overrides, and the pane offers it as "Update Anyway" beside those names.
  There is no `--if-idle` flag — declining is the default, not an option.
- **A box a newer app set up is left alone** and reported as `current` with
  `newer: true`; the loop only ever moves a version up.
- **§5.5 is `TermioStore.upgradingRoutes`:** a roster that fails while the app
  itself has the daemon between builds keeps its spinner instead of turning
  into an unreachable row.

Not built here: the holder process (§9). The systemd `--user` unit (question
4) landed on 2026-08-29 without touching the loop: `Restart=on-failure` leaves
a cleanly stopped unit inactive, and the verify handshake's reconnect starts
the unit again instead of forking a `setsid` daemon beside it.

## 12. Open questions for review

1. **Idle definition.** `attached == 0` treats an agent running unattended as
   killable. Should idle instead require the session's *status* to be `idle` or
   `done` — i.e. respect the workstream status the protocol already carries —
   so a `working` agent nobody is watching is still protected?
2. **Timeout for `upgrading`.** Autostart is on next contact; the verify
   handshake is that contact. Ten seconds from `stop` to a bound socket seems
   generous. Is there a case (slow disk, first-run migration) that needs more?
3. **Should stage run eagerly?** Once the Mac can see `staged`, it could stage
   on every app launch and only ever ask the user about activation. That is the
   Chrome model. It makes the update the user sees a one-click restart instead
   of a deploy — at the cost of writing to the box without being asked.
4. **systemd user unit.** §4 defers it. Is `enable-linger` an acceptable ask
   in the install flow, given it changes the box's logout behavior?
