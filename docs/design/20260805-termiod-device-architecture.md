---
title: Device Architecture — one server per device, every UI a client
status: draft
type: design
created: 2026-08-05
updated: 2026-08-16
related:
  - 20260730-termiod-session-protocol.md
  - 20260730-termiod-session-mux.md
  - 20260708-session-daemon-architecture.md
  - 20260708-remote-projects.md
---

# Design: Device Architecture

> There is no "remote". There are **devices**, each running one `termiod`, and every UI — the Mac app included — is a **client** that attaches to one of them.

**Evidence policy** (inherited from [termiod-session-protocol.md](20260730-termiod-session-protocol.md)):
Superlogical statements are labeled **Announced** (superlogical.com / Mitchell's
post / press coverage), **Inferred**, or **Unknown**. They have published no wire
protocol; nothing here guesses at one.

---

## 0. Conclusion first

1. **Client/server is the model, including locally.** `termio.app` owns no PTY.
   tmux has shipped this for twenty years; Superlogical chose the same
   (**Announced**: *"sessions run server-side, clients send input as with SSH"*).
   Local is not a special case — it is the device whose route is a Unix socket.
2. **A device's identity is its `termiod` `host_id`**, not an SSH alias. SSH is
   one *route* to a device, not the device itself.
3. **Raw PTY bytes are teed to clients; the host parses in parallel, never in
   between.** This is Termio's existing anti-100× invariant, and primary
   sources confirm Superlogical converged on the identical design
   (**Announced**: *"we tee them off to all the clients, and we send them raw
   like SSH"*; *"the teeing happens ahead of the server"*). §3 corrects an
   earlier revision of this document that had it backwards.
4. **The server never decides presentation.** It describes what is on the
   screen; the client's libghostty decides how it looks. This is Termio's own,
   learned the expensive way (§4).
5. **Four planes, one connection, one recovery rule.** Terminal, resource
   subscription, request, device transfer — all resumable by cursor.
6. **Every UI is a viewer, and a viewer connects to the device it is showing —
   never through another viewer.** iOS is not a satellite of the Mac; they are
   clients of the same kind. The Mac may therefore hold nothing iOS needs,
   which forces workspaces onto the device (§2).

What this retires: the local/remote fork in the app, `TERMIO_TERMIOD` as a
flag, per-session remote host, every menu verb with "Remote" in its name, and
the companion wire that made the phone a mirror of a Mac.

---

## 1. Why client/server, even locally

Termio today has two ways to run a session: `PTYProcess` in-process, or the
daemon when `TERMIO_TERMIOD=1`. Two paths means every feature is written twice
and the second one rots. The bugs found while testing this branch were all
symptoms: a local terminal silently became remote because of an environment
variable; a remote terminal landed in the loose-terminals bucket because there
was no device to hang it on.

The fix is not better branching. It is deleting the branch:

| | Before | After |
| --- | --- | --- |
| PTY owner | app *or* daemon | **always** the device's `termiod` |
| Local session | in-process | attach over Unix socket |
| Remote session | attach over SSH | attach over SSH |
| Code paths | two | **one** |

**Cost, measured** (this Mac, 2026-08-05): connect+hello 0.2 ms, attach→first
frame 2.2 ms, echo ~1 ms above in-process. Against a 16 ms frame budget this is
not perceptible. The real cost is a new failure mode (§6), not latency.

---

## 2. Device and route

```
Device  (host_id — the machine's identity)
  └──< Route   unix socket · ssh <alias> · later QUIC / relay
```

| Concept | What it is | Source of truth |
| --- | --- | --- |
| **Device** | A machine running `termiod` | `host_id`, minted on the daemon's first run, persisted beside its socket |
| **Route** | A way to reach that device | `~/.ssh/config` for SSH routes; the socket path for local |
| **Readiness** | Reachable? `termiod` installed? version? | Runtime probe, never configuration |

**Devices are discovered, not configured.** You cannot know which device a
route leads to until you connect: open the route, read `host_id` from
`hello_ok`, and record `host_id ← route`. The same `host_id` arriving over a
second route joins that device's route list rather than creating a twin.

This matters concretely: one VPS commonly appears in `~/.ssh/config` as
`vps-lan`, `vps-wan`, and a Tailscale name. Keyed by alias they are three
devices with three session lists. Keyed by `host_id` they are one machine with
three roads, and switching networks does not fork your state.

`~/.ssh/config` remains the single source of SSH hosts — Termio keeps no host
database, per §H #8 (never embed SSH). The parser already handles wildcards,
negation, `Include`, and `%h` (`Sources/termio/Settings/SSHConfig.swift`).

**Discovery is a separate question from that, and currently unanswered.** "No
host database" governs where a *route* comes from; it says nothing about how a
route gets into `~/.ssh/config` in the first place. Today the answer is "the user
already did it": adding a box means hand-writing an alias, then a deploy that
cross-compiles a musl binary on the Mac and `scp`s it. Superlogical productises
the same step — **Announced:** *"Servers can automatically join a tailscale …
and clients can automatically find them with one config."*

The shape that closes the gap without acquiring a host database is a **provider
interface**: a discovery provider enumerates candidate routes, and everything
downstream is unchanged — connect, read `host_id`, record the device. Providers:
`~/.ssh/config` (today, always present), a tailnet (`tailscale status --json`,
read-only, no account in the protocol), Bonjour on a LAN, later others. Rules
that keep this from becoming the thing §H #8 forbids:

- A provider **proposes routes; it never becomes an identity.** Devices are still
  discovered by handshake (§2), so a tailnet name is one more road to a
  `host_id`, exactly like an alias.
- **No provider is required**, and none may be a dependency of the session
  protocol. A user with only `~/.ssh/config` loses nothing.
- Credentials stay where they are. A provider answers *what hosts exist*, never
  *how to authenticate* — that remains system OpenSSH and the user's config.

Pair this with the content-addressed install in §6 and prebuilt per-arch
binaries: "add a machine" should be pick-from-list, not a toolchain exercise.
Scheduled as §8.8.

**Open question (§9.1):** `host_id` is not intrinsic — a cloned VM or a reused
container image carries the same one, and a reinstall mints a new one. See §9.

### 2.1 Viewers attach directly — one hop, always

Every UI is a **viewer**. A viewer connects to the device whose state it is
showing, and to no one else:

```
Linux device (termiod)              Mac device (termiod)
      ▲        ▲                        ▲        ▲
      │        │                        │        │
     Mac      iOS                      Mac      iOS      ← peers, not a hierarchy
```

Not `iOS → Mac → Linux`. The Mac appears twice — once as a device that runs
sessions, once as a viewer that shows some device's state — but it never stands
between the phone and a third machine. There is nothing it could add there
except latency and a Mac that has to be awake.

**Consequence: the Mac may hold nothing a viewer needs.** This is the load-
bearing half of the rule and the reason it is not merely tidy. Today the
project tree lives in the Mac's `StateFile`; a phone talking straight to a
Linux box would have no way to learn what projects exist on it. Either the Mac
is on the path (violating the rule) or that state does not belong to the Mac.

This also retires the companion wire — the phone rendering a mirror of a Mac's
surface — which §H #9 of the protocol spec already condemned as "the cautionary
tale". The phone becomes a client of *this* protocol, not a screen for another
client.

### 2.2 Workspaces live on the device, not in a viewer

A **workspace** is a directory root on a device — what the UI calls a project,
and what `git worktree` extends. §B of the protocol spec introduced it as the
scope for filesystem and git operations. This rule promotes it: a workspace is
a **first-class, enumerable object owned by the device's `termiod`**.

The consequence is worth stating plainly, because it collapses a distinction
the product currently makes:

> There is no "local project" and "remote project". There is a **workspace on a
> device**, and the Mac happens to be one of the devices.

| Today | Under this rule |
| --- | --- |
| `Project` = a path on the Mac | Workspace = `(device, path)`, registered with that device's `termiod` |
| Opening a remote project = a special mode | Opening any project = pick a device, pick a workspace |
| Worktrees created by the Mac running `git worktree add` | Created on the device (request plane `exec`, §5) |
| The Mac's `StateFile` owns the project tree | Each device owns its own list; viewers cache it |
| File tree / git read local disk, greyed out for remote | Always read the workspace's device |

`termiod` currently knows only about sessions — id, name, cwd, command. It does
not know what a project is. **That gap is what makes "open a remote project"
impossible today**, and closing it is a precondition for the phone being a
peer rather than a satellite.

---

## 3. State authority: independent convergence, not a course change

An earlier revision of this section said we should adopt "server maintains all
state" from Superlogical. **That was based on press paraphrase and is wrong.**
Primary sources — Mitchell's 10:40 architecture video and his replies — say the
opposite of what the coverage implied.

**Announced, from the video:**

> instead of sending down **screen diffs** … we take the PTY bytes, we **tee
> them off to all the clients, and we send them raw like SSH** … basically we
> assume you're running libghostty everywhere

**Announced, answering tmux maintainer Jonathan Slenders** — who asked the
sharp question: if the server sends visible screen state on attach, doesn't it
have to parse too, and isn't that still double parsing?

> **Yes, the server parses too. But the teeing happens ahead of the server**, so
> the clients can parse **simultaneously** to the servers (also if anyone is
> slow there's some queues).

That is termiod's anti-100× invariant, stated by someone who arrived at it
independently. **We are already on this architecture; nothing here needs to
change.** The invariant, restated with the extra precision his answer supplies:

**A second independent witness, added 2026-08-08.** [zmx](https://zmx.sh/)
(neurosnap) is session persistence in Zig — abduco's one-daemon-per-session plus
shpool's state restoration — and it reaches the same place from a third
direction, using the *same library termiod binds*: *"ghostty-vt doesn't sit in
the middle of an active terminal session, it simply receives all the same data
the client receives so it can re-hydrate clients that connect."* Three
implementations, no shared code, one design. Treat the invariant as settled and
stop re-deriving it. Two consequences worth carrying: the persistence layer is
commoditising, so *"sessions survive disconnect"* cannot be the pitch by the time
we ship; and zmx's client is a plain tty, which is why it needs `autossh` for
reconnection where a protocol client can repair its own link (§5.1) — and why it
covers the any-terminal case that our replica model does not (§9.6).

> The authoritative VT is fed **in parallel with**, never **between**, the PTY
> and the clients. The host parsing slowly must never slow a client down; a
> backed-up consumer is absorbed by a queue, not by stalling delivery.

**Why the host still keeps authoritative state.** Both designs parse
server-side, because attach needs it. Ours additionally wants it for peek
without attach (`what is on that agent's screen right now?` — today Termio's
CLI scrapes screens for this), and for catch-up. So §C.6's "sidecar consulted
only to build snapshots" understates its role — but the *hot path* framing was
right all along.

**Attach handshake, theirs and ours, are the same shape** (**Announced**):
server pauses PTY processing → sends just enough screen state over a custom
binary protocol → a **ready frame** → then raw teed bytes; scrollback streams
in behind, newest-first. termiod already ships `S` → `ready` → `D`, with `H`
scrollback newest-first.

**Why screen diffs are rejected — the reason we had wrong.** We justified
keeping diffs off the default path with a bandwidth measurement (8.6× worse for
scrolling output on a real VPS, 2026-08-05). That number is real but indicts
our 16-byte-per-cell encoding, not diffing as an idea. His reason is better and
we should adopt it:

> The issue with the screen diffing is **less performance and more making it
> very difficult to allow native scrollback, selection**, etc.

A client that receives diffs owns no real scrollback and cannot select text
across history — it only has the rows the server chose to send. That is a
*capability* argument, and it holds no matter how well the diff is encoded.
Consequence for us: **`G` should not be positioned as the bad-network default
even after the wire cell is compressed.** Theirs stays an opt-in extra —
synced viewports are sent as *additional* frames when a user asks for shared
scrolling, not as the transport.

**Their degrade path** (**Announced**): queues absorb slow clients and a
reconnect catches up by PTY replay; if the queue fills or the disconnect runs
long, a **tombstone** record tells the client to do a full resync. termiod's
ring + 4 MiB backlog + snapshot-on-gap is the same mechanism under different
names — and §C.10's `gap: true` *is* the tombstone.

---

## 4. The presentation boundary (Termio's own rule)

> **The host describes state. It never decides how that state looks.**

This was learned by shipping the violation: the host resolved every cell to RGB
against *its own* palette, so a remote session ignored the viewer's theme and
rendered on a black background, while bold and underline vanished entirely
(the wire cell's `attributes` field was reserved-zero).

| Plane | Host sends | Host must not send |
| --- | --- | --- |
| Screen | VT sequences (`38;5;N` indices) | resolved RGB, OSC 4 palette |
| Files | structured entries | a rendered tree |
| Git | porcelain output | formatted diffs |
| Status | enum values | human-facing copy |

The screen case is fixed: `S` payload v2 is libghostty's own formatter output
with `palette: false`, so colour indices arrive and the viewer's theme resolves
them. Measured 559 B vs 6,504 B of cells for the same 10×40 screen — more
faithful *and* 11.6× smaller.

The rule is testable: **feed one snapshot to a light-theme and a dark-theme
client; they must look different.** If they look the same, the host is
overreaching.

**The rule has a second half, and it is still violated: the environment a
process is born into.** The table above is about what the host sends back. But
the host also decides what environment it spawns a PTY in, and a program that
cannot see `COLORTERM` will pick its own colours before a single byte reaches
the client — the presentation decision has already been made, upstream of
anything a snapshot can fix. Remote sessions currently send `env: []`
(`TermioStore+Termiod.swift`), which correctly withholds the Mac's `PATH` and
`HOME` and incorrectly withholds `TERM`/`COLORTERM`/`TERM_PROGRAM` along with
them; the symptom is an agent on the VPS quantising the user's theme to 256
colours. The split and the reasoning are specified in the protocol doc §C.11.

Stated once, covering both halves: **the client declares how output should be
produced and how it should look; the device decides only where it runs.**

### 4.1 What each side owns

The presentation boundary is one instance of a general split. Once viewers are
peers (§2.1), every piece of state has to belong to exactly one side, and the
test is simple: *would two people watching the same session from two machines
expect to share it?*

| Owned by the **device** | Owned by the **viewer** |
| --- | --- |
| PTY, process, exit status | rendering, font, theme, palette |
| filesystem, git state | selection, scroll position, **viewport** |
| workspaces and worktrees (§2.2) | window and split layout |
| agent workstream status | **clipboard** |
| scrollback content (authoritative) | how much scrollback is shown, and where |

Mitchell states the viewport half from the same conclusion: each client owns
its own viewport and its own selection, and he names tmux's shared viewport —
one client scrolling scrolls everyone's window — as the defect to avoid.

**This is also the correct account of the image-paste failure.** The clipboard
sits on the viewer side; the agent runs on the device side. Pasting a
screenshot is not "uploading to a server", it is **crossing this boundary**,
and today the crossing does not exist — the local mechanism is the agent
reading the Mac's pasteboard itself, which has no meaning when the agent is on
a VPS. The transfer plane (§5) is the crossing, and it is symmetric because
both sides are the user's own.

The spawn-environment half was closed on 2026-08-05
(`TermioStore.presentationEnvironment(from:)`). One known gap remains, recorded
rather than silently carried: the packed-cell encoding still ships resolved RGB
to a Mirror (client-classes doc §D.4).

---

## 5. Four planes, one connection

| Plane | Carries | Recovery | Status |
| --- | --- | --- | --- |
| **Terminal** | raw bytes (default) · `S` VT snapshot (bootstrap) · `G` diffs (opt-in only — §3) | snapshot + seq | shipped |
| **Resource** | subscriptions with `seq` + bounded ring + linger (`fs:` first) | re-subscribe at cursor | `fs:` shipped |
| **Request** | `exec`, `list`, `read`, `write` | idempotent, request id | **not built** |
| **Transfer** | bytes across the viewer↔device boundary (§4.1): clipboard, images, files | resume at offset | `temp:` + project uploads shipped |

All four ride one connection per device, multiplexed by channel id, over one
SSH ControlMaster. Reconnect is not a feature: open a pipe, re-subscribe every
resource at the last applied `seq`. No retry ceiling — a retry loses nothing —
which is strictly stronger than Zed's bounded `MAX_RECONNECT_ATTEMPTS` and than
VS Code's reconnection tokens, which die with the server PID.

### 5.1 The connection is an object, not a side effect of attaching

The paragraph above has read as description since it was written. It is not:
the POC opens **one connection per session**, owned by that session's link and
destroyed with it (`Termiod.Transport` is created inside `TermiodSessionLink`),
plus a whole additional connection for every `list`, `kill`, and device probe.
Nothing in the app models "the link to this device." This section makes the
requirement explicit so §8 can schedule it.

> **A device connection is a durable object with its own lifecycle.** It is
> opened before, and outlives, any session that uses it. Sessions, resource
> subscriptions, requests, and transfers are **channels** on it. Closing a pane
> closes a channel and never the connection; a network drop is repaired once,
> at the connection, and every channel recovers with it.

Why this is the shape rather than a tidier version of per-session pipes:

- **A dropped pipe currently reads as session death.** With no object above the
  session there is nowhere for "reconnecting" to live, so the client's only
  vocabulary for a lost link is `exited` — and the pane reports a death that did
  not happen while the session keeps running on the device.
- **Cost is paid per pane instead of per machine.** Cold SSH is 216–292 ms
  against 26–33 ms warm (measured 2026-08-05); N panes on one box means N key
  exchanges and N reconnect storms after a network change.
- **It is the same rule the host already follows.** One daemon per device, one
  roster, one `host_id`. A client that opens a connection per session is
  modelling the device as N machines, which is exactly the mistake §2 rejects
  one level up.
- **This is the substance of "the mux owns SSH."** Hashimoto's objection to
  `ssh → remote mux` is not about nesting; it is that the remote connection
  should be a managed, durable resource of the mux rather than a transient
  process each client spawns for itself. Termio's answer differs on *custody* —
  system OpenSSH, the user's `~/.ssh/config`, §H #8 — and should not differ on
  *ownership*.

**Two levels, deliberately separated so the cheap one is not blocked:**

| | Mechanism | Buys | Protocol change |
| --- | --- | --- | --- |
| **A** | `ControlMaster`/`ControlPersist`/`ControlPath` on the app's ssh invocation — the option set `remote::ssh_multiplex_args()` already builds for the CLI | one TCP + one auth per device; warm-connect latency | none |
| **B** | Channel ids in the framing, so one pipe carries N sessions plus the resource, request, and transfer planes; a `TermiodConnection` per device owning health and reconnect | reconnect-once semantics; the four planes actually sharing a connection; a coherent "device is reachable / degraded / gone" state for the UI | additive `proto` bump — `hello` fixes one role per connection today |

Do **A** immediately; it is an argument list. **B** is the design change, and it
is a prerequisite for the WebSocket binding (§8.7) rather than a parallel track —
a second transport is worth far more once one connection carries everything.

**What reconnect owes, stated normatively.** On reconnect the client MUST
re-attach every live session by name and re-subscribe every resource at its last
applied cursor; the device MUST answer each with either continuity or an explicit
`gap`. A client MUST NOT report a session as exited because its transport failed —
`exited` means the host said so. Backoff is bounded per attempt and unbounded in
count.

**Transfer is its own plane, not a request verb.** Under the device model,
moving a screenshot to the box an agent runs on is not "uploading to a server";
it is Universal Clipboard between two of your machines, and the direction is
symmetric. This is what unblocks image paste — today it silently fails, because
the local mechanism is *the agent reading the Mac's pasteboard itself*, which
cannot work when the agent runs on a VPS.

---

## 6. Lifecycle and failure

Making the daemon the only PTY owner makes it a single point of failure: today
an in-process PTY dies *with* the app, which is at least a shared fate.

- **Start:** launchd user agent on macOS, systemd `--user` with
  `loginctl enable-linger` on Linux. Without linger, a Linux user daemon is
  killed at logout — sessions would silently die between SSH connections.
- **Crash:** sessions cannot be resurrected — the PTYs are gone. They must not
  vanish silently either: keep a **tombstone** (last snapshot, exit reason,
  timestamp) so the UI can say what died instead of showing an empty list.
- **Version skew:** negotiate, never lockstep. `hello` capabilities already
  express this; a daemon one version behind should serve what it can. Install
  content-addressed (`~/.termio/termiod/<version>-<sha>/`) with an atomically
  flipped `current`, so versions coexist and a redeploy that matches is a no-op
  — this also removes the `ETXTBSY` failure when overwriting a running binary.

---

## 7. Where we agree with Superlogical, and where we do not

All rows **Announced** unless marked; sources are the architecture video, the
reply threads, and superlogical.com.

| | Superlogical | Termio |
| --- | --- | --- |
| Sessions server-side, client/server even locally | yes — *"for local … its still IPC"* | same |
| Raw PTY bytes teed to clients | yes — *"raw like SSH"* | same |
| Server also parses, tee happens **ahead** of it | yes | same (anti-100×) |
| Attach = paused screen state → ready frame → live bytes | yes | same (`S` → `ready` → `D`) |
| Screen diffs as the default path | **rejected** | same, and for a better reason now (§3) |
| Synced viewport across clients | opt-in extra frames | not built |
| Scrollback streamed newest-first | yes | same (`H`) |
| Overflow degrade | queue → **tombstone** → full resync | ring → `gap: true` → snapshot |
| Splits | native windows/tabs, **one connection per PTY** | native panes; §H #7 forbids a nested WM |
| Remote connection ownership | *"the mux owns SSH"* — a durable, managed resource of the mux, explicitly not `ssh → remote mux` | **agreed in §5.1, not built** — the POC opens one client-owned ssh per session. Custody differs (system OpenSSH, user's config); ownership should not |
| Host discovery | **direct Tailscale enrollment**: *"servers can automatically join a tailscale … clients can automatically find them with one config"* | `~/.ssh/config` only; provider interface specified §2, **not built** |
| Legacy terminals | **compat mode**: a libghostty in the middle | not built |
| Wire protocol | custom binary, *"predominantly part of libghostty"*, called an **open protocol** | our own framed protocol. **Checked 2026-08-08: no spec, no OSS release — beta waitlist only.** Nothing to adopt yet; re-evaluate when it lands |
| Remote transport | **WebSockets over HTTP** (browser is first-class); "not at all guaranteed to be final" | **SSH only** — a trust choice (§H #8). WS as a *second binding* of the same protocol is §8.7 |
| Phone client | attaches to the session like any other client | **mirrors the Mac** over the companion channel — the live exception to §H #4, closed by §8.7 |
| Live human sharing | day one | not a v1 goal |
| Where compute lives | **Unknown** | **the user's own machines, never ours** |
| Agent status in the protocol | **Unknown** | first-class workstream object |

**The architecture is not the differentiation.** Three implementations converged
on the same design independently — Superlogical, zmx (§3), and termiod — which is
the strongest evidence available that it is correct, and it means nothing here is
defensible as a moat. The bottom three rows are.

**Two things worth acting on:**

1. Their wire protocol is described as *"predominantly part of libghostty"* and
   an **open protocol**. If it ships that way, the cheapest path to a shared
   ecosystem may be speaking theirs rather than ours. Worth watching before
   investing further in framing details.
2. Their transport being WebSocket-over-HTTP is a **browser-first** decision,
   explicitly not final. Ours being SSH-only is a **trust** decision. These are
   not competing on the same axis, and ours should be stated as a choice rather
   than defended as a feature.

---

## 8. Migration: delete before adding

Each step is independently shippable and mostly removes code.

1. **Record device identity.** Keep `host_id` from `hello_ok`; build the
   `host_id ↔ routes` map. Pure addition, no UI change. **Done** —
   `TermiodDeviceRegistry`, persisted to `devices.json`; every handshake
   (attach, `list`, `kill`) records the device it reached, so a second alias for
   one machine joins its route list instead of forking it.
2. **Re-key state by device.** Sessions belong to a device; `remoteCheckouts`
   moves from alias-keyed to `host_id`-keyed (alias-keyed state silently splits
   the day the user changes networks). **Done, minus the container merge** —
   `Project.deviceID` / `Session.deviceID` are backfilled on first handshake
   (`TermioStore.adoptDevice`), and legacy alias-keyed checkouts are promoted in
   place on the way past, so old state files keep working. Containers are still
   created and matched by alias, because alias is the only identity that exists
   before connecting; merging two of them into one device is §9.5.
3. **Daemon lifecycle on macOS.** launchd agent, restart-on-crash, tombstones.
   **Done** — `termiod service install|uninstall|status` writes a
   `sh.termio.termiod` launchd user agent (`RunAtLoad` + `KeepAlive`); never
   installed automatically, since it makes the daemon outlive every Termio
   process. Tombstones (`termiod/src/tombstone.rs`) ride the `list` reply and
   record `exited` / `killed` / `daemon_lost` with the session's identity,
   status, and timestamps. The crash case is inferred rather than supervised: a
   session still on the on-disk roster when a daemon starts was never buried, so
   the previous daemon died under it. **Not done:** the last screen (§6 asks for
   it; capturing it needs a snapshot request threaded through the sidecar's
   shutdown path), and the Linux systemd `--user` + `enable-linger` unit.
4. **Own the connection (§5.1).** The step this ladder was missing, and the one
   the remote plane is currently failing on. **4a:** put
   `remote::ssh_multiplex_args()`'s option set on the app's own ssh invocation —
   `ControlMaster`, `ControlPersist`, `ControlPath`, and the `BatchMode` /
   `ConnectTimeout` every other ssh call site in the app already sets but this
   one does not, so an unloaded key currently prompts onto an unread stderr and
   the attach hangs with no error. **4b:** a `TermiodConnection` per device that
   owns the transport, its health, and reconnect; `TermiodSessionLink` becomes a
   client of it instead of a transport owner, and a transport failure stops being
   reported as `exited`. **4c:** channel ids in the framing (additive `proto`
   bump) so the four planes genuinely share one pipe. 4a is an argument list; 4b
   is where the durability promise is actually kept.
5. **Delete the fork.** Remove the `TERMIO_TERMIOD` flag, the in-process
   `PTYProcess` path, per-session remote host, and every "Remote" menu verb.
   `New Terminal` opens on the current device.
6. **Device switcher** in window chrome, with readiness state. Only meaningful
   after step 5 — before it, local is still a special case. Reads the connection
   state from step 4b, so a device can show *degraded* rather than only
   present/absent.
7. **WebSocket binding** of the same framed protocol, after 4c. This is what
   makes the phone a client of a *device* rather than a mirror of the Mac — and
   it is the one place the repo currently contradicts §H #4, since the companion
   channel is already a second protocol. SSH stays the default trust plane; a
   binding is not a policy.
8. **Discovery providers** (§2) and prebuilt per-arch install (§6), so adding a
   machine is pick-from-list rather than hand-written alias plus cross-compile.
9. **Request plane**, then file tree and git move to the current device.
10. **Transfer plane**, then clipboard and image paste cross the viewer↔device
    boundary (§4.1). **Image paste done** — `upload.open` / `U` / `upload.commit`
    on a control channel of their own (never an attachment, so the tee is
    untouched), credit-of-one chunks, and re-open resuming at the offset the
    device already holds. ⌘V at a session on another machine moves the bytes to
    that session's scratch dir and pastes the path they landed at; a session on
    this Mac is untouched, because there the agent reads the pasteboard itself.
    **Not done:** the other three directions — text clipboard sync (§9.4's
    push-on-copy vs pull-on-paste is still undecided), drag-a-file-onto-the-tree
    (the same verbs, a project `dest` instead of `temp:`), and download-direction
    drag-out.
11. **Workspaces on the device (§2.2).** `termiod` gains a workspace registry —
    enumerate, open, and create worktrees on the device that owns them. This is
    what makes "open a remote project" a normal action rather than a mode, and
    it must land before a phone can talk to a Linux box usefully: until the
    device can answer *what projects are here*, the only place to ask is a Mac,
    which is exactly the hop §2.1 removes.
12. **iOS as a peer client.** The phone speaks this protocol to the device it
    is showing, and the companion wire is deleted. Gated on §9.6 (how the phone
    reaches a device without embedding SSH) — the topology is decided, the
    transport is not.

Steps 1–5 are net deletions or net structure. The features people are waiting for
(files, git, image paste) are 9–10, and they are last **on purpose**: built before
the device model exists, each would grow its own local/remote fork.

---

## 9. Open questions

1. **`host_id` is not intrinsic.** A cloned VM or reused container image
   carries the same id; a reinstall mints a new one. Options: treat a duplicate
   as a conflict and prompt; mix in a machine fingerprint; or accept that the
   id names *an installation*, not hardware, and let the user merge/split
   devices. Not decided — needs a real collision to reason about honestly.

   Sharpening what "an installation" means, since it is more granular than it
   reads: the id lives at `state_dir()/host.id`, and `state_dir()` is the
   directory of the *configured socket* (`paths.rs`), i.e. `TERMIOD_SOCK` or
   `$XDG_RUNTIME_DIR`/`$TMPDIR`. That is deliberate — two daemons on two sockets
   must not share an identity, or each reports the other's sessions as its own —
   but it has a consequence nobody has written down: **the dev channel and the
   release channel are two devices on one Mac**, and a changed `TMPDIR` re-mints.
   So this is not a bug to relocate the file over; it is the reason device
   *merge* (§9.5) is the load-bearing feature rather than a nicety, and the
   reason a merge must be offered on the same machine, not only across routes.
2. **Route selection.** Half of this question is already answered and should
   stop being carried as open: **a live session does not migrate across routes,
   because it never depended on one.** The session lives in the daemon, so
   changing route is a disconnect plus reattach — exactly the recovery the
   protocol doc §C.10 already specifies (durable object, monotonic cursor,
   snapshot or `gap`). There is no migration mechanism to design.

   What genuinely remains is only *which* route to pick, and the cheap answer
   should be the v1 answer: **routes are ordered, the first reachable wins, and
   it sticks until it fails.** Latency-ranked selection needs probing that costs
   more than it saves at two or three routes; revisit when a user actually has
   enough of them to be wrong about. Baseline measured: SSH cold 216–292 ms,
   warm with ControlMaster 26–33 ms. As of 2026-08-05 the app actually gets the
   warm figure: multiplexing is injected when the user's config leaves it unset
   (protocol doc §D), re-measured at 260–290 ms cold against ~20 ms warm.
3. **Global device vs cross-device roster.** A single "current device" is
   clean, but Termio's value is seeing every agent at once. Current position:
   the device scopes *new work and the panels*; the session list stays
   cross-device with a device column. Unproven in use.
4. **Clipboard semantics.** Push on copy (eager, leaks everything you copy to
   whichever device is current) or pull on paste (lazy, one round trip). Pull
   is the safer default; not yet measured for feel.

5. **Merging two containers that turn out to be one device.** Specified here,
   deliberately **not implemented** — the identities are recorded first
   (`Project.deviceID`, `Session.deviceID`, shipped), and merging becomes a step
   to add rather than a rewrite.

   **Why it cannot simply be "key containers by `host_id`".** `host_id` is
   *a posteriori* and an alias is *a priori*. A container must exist the instant
   a session is created — `hostContainer(for:)` is called synchronously, before
   any handshake has run — and most aliases in a `~/.ssh/config` have never been
   connected to at all. So the model is two identities coexisting, not one
   replacing the other:

   | | Bootstrap identity | Stable identity |
   | --- | --- | --- |
   | What | SSH alias (`Project.sshHost`) | device (`Project.deviceID`) |
   | Known | before connecting, from `~/.ssh/config` | after the first `hello_ok` |
   | Role | the container is born from it and matched by it | the container *is* it, once known |

   A container is created and matched by alias, exactly as today. `deviceID` is
   backfilled on first handshake (`TermioStore.adoptDevice`). Only then can two
   containers be known to be one machine — and only then may a merge run.

   **The rules a merge must satisfy** (each is a question the naive version gets
   wrong):

   - **Sessions.** Concatenate, oldest container first, ordered by `createdAt`
     within each. Session ids are already globally unique, so nothing is
     renumbered — but auto-generated `Terminal N` titles collide across the two
     blocks and must renumber on collision only, exactly as
     `liftingRemoteSessionsToHosts` already does. A title the user or a clone
     chose is never touched.
   - **The container name.** Whichever the user renamed wins; if both were
     renamed, the one with the most recent session activity wins and the other
     name is kept as a secondary label rather than discarded — a name the user
     typed is data, not decoration. If neither was renamed, the alias of the
     most recently used route wins, since that is the road they are currently
     on. Note this is a *client* decision: the host never supplies a display
     name (§4).
   - **`remoteCheckouts`.** Already device-keyed, so the two maps merge by key.
     A genuine conflict — two different paths for one device — means one entry
     is stale; keep the one whose directory the more recent session used and
     surface the other rather than silently dropping it.
   - **Conflicting `host_id`s must not merge blindly** (§9.1). A cloned VM or a
     reused container image carries a duplicate id, so identical `host_id` is
     *evidence* of one machine, not proof. Before merging, require corroboration
     that the two routes reach the same box — matching boot id or machine-id,
     or the same `termiod` process start time — and when it fails, ask rather
     than merge. **A wrong merge is destructive** (two machines' sessions
     collapse into one list); a missed merge is merely untidy. Asymmetric cost,
     asymmetric default: never merge on doubt.
   - **Reversibility.** A merge must be undoable, which means the surviving
     container has to record the aliases it absorbed. A user who splits a
     wrongly merged container should get their two blocks back, not a manual
     rebuild.

6. **How does iOS reach a device directly?** §2.1 forbids routing the phone
   through a Mac, and this is the one place that rule currently has no answer.
   SSH is the transport and §H #8 forbids embedding an SSH or crypto library;
   iOS has no system OpenSSH, and an in-app SSH client has been built and
   removed twice. Note the reachability inversion that makes this worth
   solving rather than working around: **a Linux VPS is easier for a phone to
   reach than a Mac** — public address, always awake — whereas the Mac sits
   behind NAT and sleeps, which is precisely what the companion tunnel keeps
   failing at. The candidate that does not violate anything is **borrowed
   identity**: a tailnet, or a pairing-pinned host certificate (TOFU, as SSH
   itself does), which is what §D.1 of the protocol spec already reserves for
   the QUIC binding. That section was written as "later, if earned"; this is
   the requirement that earns it. Explicitly rejected: making the Mac a
   "transparent relay" for the phone — it satisfies the letter of the topology
   while keeping a Mac on the path, which is the thing being removed.
7. **Is a plain terminal a supported client?** A replica needs libghostty, so
   `ssh box && termiod attach` only works from a termio client — while zmx (§3)
   and Superlogical's announced *compat mode* both cover it, zmx for free because
   its client is a tty. Serving it means the host renders for that one client: a
   scoped, per-client exception to §4, off the shared tee, and a real cost. Not
   serving it means the CLI is a debugging tool rather than a surface anyone
   outside termio can use, and that we are strictly narrower than a one-person
   project on the axis users evaluate first. The trade is understood; the call is
   not made. Tracked as §C.4 / §F.5 in the client-classes doc.

---

## 10. Relationship to existing docs

- **Supersedes** §C.6's "sidecar only" framing of the host VT (§3), and the
  local/remote asymmetry in [remote-projects.md](20260708-remote-projects.md).
- **Extends** [termiod-session-protocol.md](20260730-termiod-session-protocol.md) with
  the device layer above the host noun; §C.10's resumable subscription becomes
  the recovery rule for all four planes.
- **Realises** [session-daemon-architecture.md](20260708-session-daemon-architecture.md)'s
  "local is the degenerate remote" by removing the last in-process PTY path.
