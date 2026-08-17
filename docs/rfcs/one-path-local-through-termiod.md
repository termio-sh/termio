---
title: One path — local sessions run through termiod too
status: in-review
type: rfc
created: 2026-08-17
updated: 2026-08-17
related:
  - one-path-local-through-termiod.review-claude.md
  - 20260805-termiod-device-architecture.md
  - 20260730-termiod-session-protocol.md
  - remote-to-device.md
---

# One path — local sessions run through termiod too

> Move every server-side responsibility out of the Swift app into `termiod`, delete the in-process PTY path and the app's own control plane, and leave the Mac app as a viewer. This is step 5 of the device architecture's migration ladder, plus the two forks that ladder never named: the inspector panels and the `termio sessions` CLI.

---

## 0. Premise audit — what is still true

The brief for this RFC cited five bugs as one shape. Three are still live; two
were fixed while the argument was being made, and citing them as open would have
been the second-order version of the same mistake. Every citation in this
document was re-checked against `main` at `7206463` on 2026-08-17, after PR #324
(the device-context work) and PR #325 (`sessions send` delivers a keypress)
landed; the first draft was anchored at `b4e3e6c` and its line numbers had
already drifted.

| Cited symptom | State | Evidence |
| --- | --- | --- |
| `TERMIO_TERMIOD_REMOTE` silently turns every local terminal remote | **Fixed** | The fallback is gone and the variable is read nowhere; the name survives only in the comment that records why it was removed (`TermioStore+Termiod.swift:18-23`) |
| Splitting a remote session drops the new pane on this Mac | **Fixed** | `Session.inheritDevice(from:)` (`Models.swift:358`), called at both split sites (`TermioStore+SplitPanes.swift:48,122`) |
| Image paste has no route to a session on another machine | **Fixed for the device direction** | `upload.open`/`U`/`upload.commit` on their own control channel (`TermiodTransfer.swift:32,212`, `protocol.rs:449-514`); three other transfer directions remain unbuilt (device arch §8.10) |
| File tree over SFTP, git through a local `Process`, while the daemon's `files`/`git` planes ship with smoke coverage | **Live** | `SSHFileSystemProvider.swift:249`, `GitService.swift:958-984`; **22** of the daemon's 86 smoke checks cover `fs.*`/`git*` (15 `fs.*` including the capability gate, 7 `git*`) and no Swift file names any of those verbs |
| Agent icon never changes on a termiod session | **Live** | The detector sits inside `if let pty { … }` (`TermioStore+TerminalSurface.swift:390-426`, call at :413); on the termiod path `pty == nil` (:228-231) |

Two of the five landing as point fixes is itself the argument. Each was repaired
where it surfaced; none of them changed the shape that produced it, and the two
that remain are the two nobody could fix locally, because they are not bugs —
they are missing halves.

**The shape, stated once.** A capability is implemented against the object the
app happens to hold — a `PTYProcess`, a local path, a `Process` — and the
termiod path holds a different object, so the capability is absent rather than
broken. Nothing reports it. It is found by a user.

There is also a second fork nobody has written down, and it is larger than the
first: **two CLIs talking to two servers** (§7).

---

## 1. Inventory — what the Swift app does that belongs to a device

The test used throughout, taken from device architecture §4.1: *would two people
watching this session from two different machines expect to see the same
answer?* Yes → the device owns it. No → the viewer owns it.

**Three session kinds, not two.** The RFC's first draft counted a local session
and a termiod session. There is a third, and it is the one the panels are keyed
on: `session.sshHost` — "New SSH Shell" (`SidebarView.swift:685`, the SSH
settings tab, three call sites in `App.swift`) — runs a plain `ssh <host>`
**inside a local PTY** (`TermioStore+ProjectActions.swift:448`,
`TermioStore+TerminalSurface.swift:165`). Mechanically it is a local session
whose command happens to be `ssh`, so Stage 5 does not disturb it: after the
fork is deleted it is a local *termiod* session running `ssh`.

Its fate has to be stated anyway, because Stage 7 deletes the file tree it owns
(§1.2, Stage 7). **The decision: the kind stays, its panels go.**
`addSSHSession` is the zero-install escape hatch — reaching a box you may not
install anything on is worth one code path, and that path is three lines of
argv. What does not survive is a *second* implementation of the workspace
plane for it: the SFTP tree (1,409 lines) exists only to serve a machine with
no daemon, and `remote deploy` turns such a machine into one with a daemon in a
single command. So a plain-`ssh` session is a terminal and nothing more, and the
panels say so and offer to install `termiod` on the host — the same discipline
§1.2 already applies to git history: name the gap, do not render an empty pane.
The alternative — keep SFTP forever — buys one pane at the cost of the sentence
in §2 that this whole RFC is for.

### 1.1 Session and process plane

| Responsibility | Swift today | termiod today |
| --- | --- | --- |
| Own the PTY, spawn with `login_tty` | `PTYProcess.swift:144-231` (`forkpty`) | **Has it** — `pty.rs:67-167`, same shape, deliberately |
| Non-blocking writes, write backlog | `PTYProcess.swift:478-624` | **Has it** — `pty.rs:208-226` + per-client budget `session.rs:25` |
| Resize / `TIOCSWINSZ`, host-vs-companion ownership | `PTYProcess.swift:626-742` | **Different policy, not missing** — resize yes (`pty.rs:183`); the daemon arbitrates by newest interactive attach with a `writer_changed` fan-out (smoke checks 42–44), where the companion arbitrates by explicit claim. Reconciling the two is Stage 4's design work |
| Reap the child, report exit code + true runtime | `PTYProcess.swift:211-224` | **Has it** — `session_exited`, but the daemon reports no runtime; the client substitutes elapsed-since-attach and says so (`TermiodClient.swift:1150-1152`) |
| **Timestamp of the last input from any device** | `PTYProcess.swift:522` (`lastInputAt`), read at `TermioStore+TerminalSurface.swift:344` | **Missing** — the link never timestamps writes. This is the choke that keeps agent promotion quiet after a keystroke from the Mac, the phone, or `sessions send`; the comment at `:337-343` says it taps the PTY precisely so *every* device counts |
| **Foreground process argv** (agent identity) | `PTYProcess.swift:866-874` — `tcgetpgrp` + `KERN_PROCARGS2` | **Missing** — no `tcgetpgrp` anywhere in `termiod/src` |
| **Foreground job present?** (close confirmation) | `PTYProcess.swift:923-927` | **Missing** — `SessionInfo` (`protocol.rs:810-832`) has no such field |
| **Child cwd** (loose-terminal cwd following) | `PTYProcess.swift:805-819` — `PROC_PIDVNODEPATHINFO` | **Missing** — `SessionInfo.cwd` is the *spawn* cwd, never re-read |
| **Child executable identity** (self-update relaunch) | `PTYProcess.swift:827-857`, consumed at `TermioStore+TerminalSurface.swift:446` | **Missing**, and acknowledged in the client: the termiod exit policy "[m]irrors the PTYProcess exit policy, minus the self-update" (`TermioStore+Termiod.swift:119`). Note this is now *two* copies of one policy that must stay in sync |
| **Orphan reaping** across an app crash | `PTYProcess.swift:953-…`, matched by `TERMIO_SESSION` + `TERM_PROGRAM=termio` in `ps -axEww` | **Mostly obviated** — a supervised daemon that keeps running has no orphans, and tombstones (`tombstone.rs:66-88`) record what a daemon crash lost. A `SIGKILL`ed *daemon* strands children on **every** restart, not only on a crash (§5.2 item 7); see open question 4 |
| Alt-screen / private-mode tracking for late attach | `PTYProcess.swift:356-441` (`modeResyncPreamble`) | **Superseded for attach** — the `S` snapshot carries its own prologue (`vt/src/lib.rs:115`, `:193-215`, `tests/snapshot_prologue.rs`). Not superseded as a *local synchronous query*: `PTYBridge` reads `isAlternateScreenActive` to decide replay-vs-skip **before** any snapshot is requested (`CompanionServer.swift:979`), and the client holds no VT state to answer that from (§1.5) |

### 1.2 Workspace plane (files, git, search)

| Responsibility | Swift today | termiod today |
| --- | --- | --- |
| Directory listing | Local `FileManager`; remote via SFTP over `ssh -s host sftp` (`SSHFileSystemProvider.swift:249`, `SFTPClient.swift`, 1,409 lines together) | **Has it** — `fs.list`, batched + speculative + `seq`-stamped (`protocol.rs:423`); 3 smoke checks |
| File read / preview | Local read; SFTP read | **Has it** — `fs.read` + `F` chunks; 3 smoke checks |
| Filesystem change notification | FSEvents (`FileTreeWatcher.swift`, `FolderEventStream.swift`); **no remote equivalent** | **Has it** — `fs:` resource, debounced, `full_rescan`/`git_meta`, resumable by cursor (`resource.rs`) |
| Filename fuzzy finder | Local walk | **Has it** — `fs.match` with honest `coverage`; 4 smoke checks |
| Content search | Local `git grep`/`grep` via `Process` (`ContentSearch.swift:97-105`) | **Has it** — `fs.search`, streamed + cancellable; 4 smoke checks |
| Git status | `GitService.run` → `/usr/bin/git` (`GitService.swift:958-984`) | **Has it** — `git:` resource, Zed's two-axis vocabulary, delta batches; 6 smoke checks |
| Git diff for one path | `GitService.diffText` | **Has it** — `git.diff`; 1 smoke check |
| Git **history**, commit contents, branch compare, discard, `.gitignore` append, remote/PR URLs, clone info, stall fingerprint | `GitService.swift:80-944` — `log`, `commitChanges`, `compareContext`, `branchCompare`, `suggestedCompareBase`, `discard`, `appendToGitignore`, `remotePage`, `newPullRequestPage`, `gitHubRepoSlug`, `cloneInfo`, `stallFingerprint` | **Missing entirely** — `git.rs` is `run_status` + `run_diff` and nothing else |
| Worktree enumeration and creation | `WorktreeService.swift` → `git worktree list` | **Missing** — device arch §8.11 (workspace registry) |

The gap is narrower than it looks and wider than the panels admit: **the read
path a file tree and a changes pane need is finished and tested on the device
side and unwired on the client side.** The git *history* pane is the part that
genuinely does not exist yet.

Note the live inconsistency this leaves: `FileBrowserView` keys its remote tree
on `session.sshHost` (`FileBrowserView.swift:53-54,68-70`) — the
plain-`ssh`-in-a-local-PTY identity of §1's third kind — so a *termiod* session
on another machine matches neither branch and falls to `inspectorProjectPath`,
which returns nil for a `.host` container (`TermioStore.swift:416-422`). The pane
renders the string `"Remote session"` (`FileBrowserView.swift:297`) and does
nothing. So there are three file-tree behaviours today — local, SFTP, dead — and
after Stage 7 there is one, because the SFTP branch is the one §1 decided to
retire and the dead branch is the one `fs.*` replaces.

### 1.3 Agent plane

| Responsibility | Swift today | termiod today |
| --- | --- | --- |
| Status from hooks | `agent-status.sock` on **this Mac** (`scripts/termio:605`, `HookListener.swift`) | **Has the sink** — `set_status` control op and `E {ev:"status"}` fan-out; nothing routes a hook into it |
| Status from screen rules | `AgentStatusRules` over the viewport, inside `if let pty` (`TermioStore+TerminalSurface.swift:356-366`) | **Missing** — but see §3: this is a viewer job and should stay |
| Status from `OSC 9;4` progress | `OSCProgressScanner`, inside `if let pty` (:303-328) | **Missing** — a byte-stream scan; the viewer sees the same bytes, so it can stay client-side |
| Hand-started agent promotion / demotion | `foregroundProcessArguments()` → `AgentCatalog` (:413-414) | **Missing** — §3 |
| Transcript location and reading | `AgentSessionStore`, local disk enumerate + read | **Reachable via `fs.read`**, unwired |
| Hook installation into agent config files | `HookListener`/`AgentStatusHooks`, writes under the Mac's `$HOME`, bakes an absolute `cliPath` (`HookListener.swift:289`) | **Missing** — §4 |

### 1.4 Client-owned, and must stay that way

Listed explicitly so the refactor has a stopping line: rendering, theme,
palette, fonts; selection, scroll position, viewport; window and split layout;
the project tree's *grouping and naming*; `termio://session/<uuid>` links;
macOS notifications; **and the encoding of a human keypress** (§7.2).

### 1.5 The consumers that break when `PTYProcess` stops being used in-process

This is the part a "delete the fork" plan usually misses. Every reference to
`ptyProcesses` and to `PTYProcess`'s API is a thing that must be replaced, not
merely deleted:

| Site | What it uses | Replacement |
| --- | --- | --- |
| `TermioStore+ProjectActions.swift:707` | `pty.hasForegroundJob` for the close confirmation | §3 — an additive `SessionInfo` field |
| `TermioStore+ProjectActions.swift:626,721,758` | `pty.terminate()` | `kill` (already implemented both sides) |
| `TermioStore.swift:756` | `terminateAllSessions` — already detaches termiod links, then SIGTERMs + SIGKILLs every `PTYProcess` | Only the `ptyProcesses` half is deleted; the detach half is the shipped behaviour and stays |
| `TermioStore+TerminalSurface.swift:258-350`, `:390-426`, `:427-473` | the status sinks, the foreground poll, and the whole exit policy, all inside `if let pty` | §3 and §3.3 |
| `CompanionServer.swift:107,145,1096` | `ptyForSession` returns a concrete `PTYProcess` | **The largest single item** — see the table below |

The companion dependency is the reason this RFC cannot be a single stage. It is
also, read the other way, the argument for doing it: the phone is a viewer
mirroring another viewer, which §H #9 already condemned, and the only reason
that wire still exists is that the Mac holds a `PTYProcess` the phone can tap.

**The real call set**, re-derived with `grep -rn` over `Sources/termio/Companion/`
rather than from memory. The first draft named six members and Stage 4 proposed a
five-member protocol; there are twelve, and three of them have no daemon
counterpart at all:

| Member | Site | termiod counterpart |
| --- | --- | --- |
| `addSink(on:replayingBuffer:replayCap:)` | `:985` | **none** — byte-capped ring replay, see below |
| `removeSink(token)` | `:1047` | none — the link has no token model |
| `isAlternateScreenActive` | `:979` | none *as a local synchronous query* (§1.1) |
| `modeResyncPreamble()` | `:1006` | same — needed before a snapshot exists |
| `addResizeObserver` / `removeResizeObserver` | `:1015`, `:1049` | the daemon's `resized` event, unwired |
| `resizeFromCompanion` | `:1041` | newest-writer-wins, a different policy |
| `jiggleResize` | `:1042`, `:1081` | **none** |
| `claimHostOwnership` | `:225`, `:268` | writer token, different policy |
| `claimCompanionOwnership` | `:295` | same |
| `write` | `:296` | `D` frames — the one clean match |
| `addExitObserver` / `removeExitObserver` | `:345`, `:1051` | **a single closure, already taken** |
| object identity — "is any other bridge holding this same PTY?" | `:267` | no stable object to compare; the equivalent is a session id |

Three of these are not additive protocol work, and they are the ones that size
the stage:

- **`addSink(replayingBuffer:replayCap:)` is not a sink.** It replays the PTY's
  ring at attach, capped at 128 KiB (`:959`), and the cap is load-bearing: the
  comment at `:988-992` records that replaying the whole 1 MB ring reflows at the phone's
  narrow grid and "can tip libghostty's allocator into its panic screen on the
  cold attach". The daemon's ring is the same size (`RING_CAP`,
  `session.rs:23`), but no wire op asks for *N bytes of it* — `attach` replays
  what it replays. This is new protocol, not conformance.
- **`addExitObserver` is a registry.** `TermiodSessionLink.onExit` is one
  closure and `attachTermiodLink` has already taken it
  (`TermioStore+Termiod.swift:119`). The companion needs a second observer, so
  the link needs a fan-out it does not have.
- **`jiggleResize` is a local `TIOCSWINSZ` twiddle** used precisely when the
  size did *not* change, to force a repaint (`:1028-1035` explains why: a cold
  attach at the same size fires no `SIGWINCH`). A `resize` to identical
  dimensions is a no-op on the daemon. There is no wire verb for "make the child
  redraw", and inventing one is a host-side presentation decision that needs
  arguing, not assuming.

**So Stage 4 is a rebuild of `PTYBridge`, not a conformance exercise.** That may
well be the right thing — this section's own argument is that the phone should stop
mirroring a viewer — but Stage 5 is gated on it, and a stage sized as "extract a
protocol" when it is "redesign the mirror's attach, resize and exit paths" is how
a ladder stalls on its fourth rung.

---

## 2. Target state

```
                 ┌──────────────── device ─────────────────┐
                 │  termiod                                │
   Mac app ──────┤   PTY · process · exit · foreground job │
   iOS   ────────┤   workspace · files · git · search      │
   CLI   ────────┤   session roster · agent status         │
                 └─────────────────────────────────────────┘
   each client:  rendering · theme · selection · viewport · layout · keypress encoding
```

Concretely, when this is done:

1. `Sources/termio/Terminal/Ghostty/PTYProcess.swift` still exists but is used
   by nothing in the session path. (Whether it is deleted or kept for a test
   harness is a later, cheap decision.)
2. `Termiod.isEnabled` (`TermiodClient.swift:46`) does not exist. Opening a
   session on this Mac and on a VPS run the same code, differing only in
   `TermiodRoute`. A plain-`ssh` session (§1) is not a third route: it is a local
   session whose argv is `ssh`, and it keeps a terminal and nothing else.
3. The inspector reads the workspace's device. There is no `SSHFileSystemProvider`.
4. `termio sessions` speaks the session protocol, and works on a Linux box with
   no Mac app in sight.
5. A capability added to `termiod` is available on every machine at once. That
   is the whole return on this work.

**What this does not do**, so the scope is honest: it does not add QUIC, does
not add discovery, does not make `grid_diff` a default, does not build the
workspace registry (device arch §8.11 stays where it is), and does not rebuild
the companion as a protocol client — it only stops the companion from blocking
the deletion (§8, Stage 4).

---

## 3. Foreground-process detection on the device

Three separate signals are read from the local PTY today and get conflated. They
have different costs and different owners.

| Signal | Read by | Cost | Needed for |
| --- | --- | --- | --- |
| **Is a job in the foreground?** | `tcgetpgrp(master) != child_pid` | one syscall, no allocation | Close confirmation (`closeConfirmationReason`) |
| **What is the foreground argv?** | `tcgetpgrp` then `KERN_PROCARGS2` | a sysctl walk | Hand-started agent promotion, the sidebar icon |
| **What is the child's cwd?** | `PROC_PIDVNODEPATHINFO` | a kernel struct read | Loose-terminal cwd following |

### 3.1 Cross-platform mechanism

`tcgetpgrp` is POSIX and works against the PTY **master** on both platforms; the
per-platform part is only turning a pid into argv and a cwd.

| | macOS | Linux |
| --- | --- | --- |
| Foreground pgid | `tcgetpgrp(master_fd)` | `tcgetpgrp(master_fd)` |
| argv | `sysctl KERN_PROCARGS2` | `/proc/<pid>/cmdline` (NUL-separated) |
| cwd | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` | `readlink /proc/<pid>/cwd` |

Precedent: this is exactly tmux's split (`osdep-darwin.c` uses `KERN_PROCARGS2`,
`osdep-linux.c` reads `/proc/<pgrp>/cmdline`, both after `tcgetpgrp` on the pty
fd). **Uncertain:** I have read the macOS half working in this repo
(`PTYProcess.swift:859-874` records it as verified) but have not run
`tcgetpgrp` on a Linux ptmx master in this codebase. The migration step below
carries a test for it rather than an assumption.

**`tcgetpgrp` returns a process group id; both argv lookups want a pid.** The
Swift code passes the pgid straight through (`PTYProcess.swift:866-874`) and gets
away with it because the pgid equals the group leader's pid. On Linux that
shortcut has a failure mode macOS does not share: in `foo | bar` the leader is
`foo`, and once `foo` exits, `/proc/<pgid>/cmdline` reads zero-length on the
zombie — so the pane would report *no* foreground command while `bar` is still
running. tmux scans `/proc` for a live member of the group instead. The Linux
implementation must do the same; the event carries a pid, and picking which pid
is part of the work, not a detail.

**Windows: no plan, and no pretence of one.** ConPTY has no controlling
terminal, no process group, and no `tcgetpgrp`. `termiod`'s Unix dependency is
concentrated — `grep -o 'libc::' | wc -l` gives 26 in `pty.rs`, 13 in
`client.rs`, 3 in `session.rs`, 1 each in `files.rs`/`paths.rs`/`service.rs`, 45
occurrences in the whole daemon — so a port is bounded, but the concentration is
the point and the count is not: this field would be absent on Windows, which is
exactly the same shape as an old daemon that does not send it. One degrade path
serves both.

### 3.2 Wire shape

Two additions, both additive within `proto:1` (`protocol.rs` treats unknown
control ops and events as ignorable and `caps` as additive), so no version bump:

```
SessionInfo += foreground_job: bool?          # cheap, on every `list`
E { ev: "foreground_changed", session, pid, argv: [...], cwd? }   # debounced push
```

Three rules the shape encodes:

- **The host reports argv; the client decides which agent that is.** Mapping
  argv → agent needs `AgentCatalog`, which is built from the *user's* manifests
  on the viewer. A host that answered `"claude"` would have to be told about
  every user-defined agent, and would be deciding presentation
  (device arch §4). Sending argv keeps user-defined agents working on a box that
  has never heard of them.
- **It is a push, not a poll.** The Mac polls at 350 ms today because it is
  free in-process. Over SSH, N sessions × 3 Hz is not free, and a poll cannot
  see a transition it lands between. The daemon debounces on its own read loop
  the way the Swift sink does now, and pushes only on change.
- **It never touches `fan_out`.** The sampler runs on the session task's timer,
  never inline in the byte path (§A). A `tcgetpgrp` between two `Write`s would
  put a syscall on the one path the whole architecture exists to keep free.

`foreground_job` rides `list` rather than an event because its consumer asks
once, at close time, and a stale push is worse than a fresh question.

**Skew rule, restated from `remote-to-device.decisions.md` §2:** an absent field
preserves today's no-confirm behaviour. It must never be read as "unknown, so
confirm" — that would tax every close on exactly the sessions the shipped rule
deliberately exempts.

### 3.3 What stays on the client

`OSCProgressScanner` and `AgentStatusRules` read the **byte stream** and the
**rendered viewport**. Every client already receives the bytes (that is the tee)
and every client already has a libghostty holding the screen. Moving them to the
host would make the host parse for a decision a viewer can make from data it
already has, and would put the host's opinion of "working" on the wire where the
viewer's own rules disagree. They stay.

The consequence is worth stating because it looks like an inconsistency: **the
screen-derived status signals would already work on a termiod session today** —
they are wired to `pty.addSink` (`TermioStore+TerminalSurface.swift:310`) only by
accident of where the code was written, not because they need a PTY. Re-pointing
them at the link's `onOutput` seam (`TermiodClient.swift:1145`) is a small change
and can land before anything else in this RFC — *provided it carries the identity
guard with it*:

```swift
// TermioStore+TerminalSurface.swift:325
guard let self, let pty, self.ptyProcesses[session.id] === pty else { return }
```

The comment above it (`:318-323`) records why that line exists: the sink is keyed
only on the session id, so a same-agent relaunch could otherwise let a dead PTY's
queued `working` mark the replacement process. `relaunchSession` tears down and
re-creates the termiod link too (`TermioStore+ProjectActions.swift:756-764`), so the race is
identical on the link and the link has no equivalent identity to compare. Move
the signals and drop the guard and this RFC reintroduces a fixed bug on its
cheapest step.

---

## 4. Agent hooks when the agent is on another machine

### 4.1 The chain today

```
agent hook  →  scripts/termio agent report working
            →  nc -U "$HOME/Library/Application Support/termio/agent-status.sock"
            →  HookListener  →  TermioStore
```

Routed by `TERMIO_SESSION`, which the local PTY carries
(`TermioStore+TerminalSurface.swift:199`). Broadcast to both channel sockets so
one installed hook serves a dev and a release app (`scripts/termio:601-608`).

On another machine every link breaks: there is no `scripts/termio`, no
`~/Library/Application Support`, and `TERMIO_SESSION` is deliberately withheld —
"a hook that echoed it back would be reporting to a control socket on the wrong
machine" (`TermioStore+Termiod.swift:68-70`). The exclusion is correct. It is
also the whole problem.

### 4.2 The chain after

```
agent hook  →  termiod set-status "$TERMIOD_SESSION" working
            →  local unix socket, same box
            →  E { ev:"status" }  →  every attached viewer
```

The hook reports to the machine it is running on, over a Unix socket, to a
process that is already there. No SSH, no crypto, no reverse channel, no
listening port. It is the same fan-out `set_status` already performs (smoke
check 46), and `termiod set-status <target> <status> [--title]` already exists
as a subcommand (`main.rs:91-100`) — on the binary that is already deployed.

This also fixes a latent local defect: today a hook reports to the *app*, so a
session that outlives the app has nowhere to report. After the change, status
survives an app quit for the same reason the session does.

**What has to be built:**

1. **Stamp the real session id.** `pty.rs:114` sets `TERMIOD_SESSION=1` — a
   marker, read by nothing. It must carry the session id. This is the whole
   routing key.
2. **Carry the rest of the payload, and the mining that fills it.** The hook
   contract is not only status:
   `{termio_session, state, cwd, transcript_path?, conversation_id?, tool?}`
   (`scripts/termio:587-599`). `set_status` carries `status` and `title`
   (`main.rs:91-100`), so the other four fields need adding — additive optional
   fields on `SetStatus`, or the same fields on a `workstream` update op.
   **Undecided**; the first is smaller and the second is tidier, and nothing yet
   forces the choice. What is *not* undecided is that this is more than four
   fields on a wire: `agent report` is a **stdin-mining** verb. It slurps the
   agent's hook JSON, greps fields out of it without jq (`mine_field`,
   `scripts/termio:212`), and prints `{}` on stdout because Cursor reads a hook's
   stdout as its reply (`:609`), with `HookListener.reportCommand` choosing which
   flags to bake per dialect (`HookListener.swift:285-300`). All of that has to
   exist on the device too, in Rust. Size it as such.
3. **Map the vocabulary.** The hook says `working|attention|done|idle`; the
   protocol says `working|idle|needs_you|done|failed|unknown`. `attention → needs_you`
   is the only translation. Put it in one place, on the device side, so a
   third client cannot get it wrong.
4. **Install hooks on the device.** `HookListener` writes agent config files
   under the Mac's `$HOME` with an absolute `cliPath` baked in
   (`HookListener.swift:289`). On a device that must happen on the device. The
   cheapest shape that does not invent a mechanism: hook installation becomes a
   `termiod` subcommand (`termiod agent install-hooks`), invoked over the
   existing request plane, writing the same files with `cliPath` pointing at the
   local `termiod`. **The manifest set is still the viewer's** — it is user
   configuration — so the viewer sends the specs and the device writes them.

**`termio agent report` stays exactly as spelled on the Mac** — it is a published
contract already baked into users' agent configs by past releases, and it grows
one branch there: `TERMIOD_SESSION` set → speak to the daemon; otherwise → the
legacy app socket, unchanged. On a *device* the contract is not preserved, it is
replaced: there is no `scripts/termio` on that box, so item 4's installer writes
`termiod set-status` into the agent's config instead. Preserved where it already
worked, new where it is new. Say that rather than implying one spelling
everywhere.

One caveat the migration must not inherit: today one hook call fans out to both
channel sockets, so a single install serves dev and release (`:601-608`). §5.2
item 2 deliberately splits dev and release onto different `TERMIOD_SOCK`s, and
after that split the daemon branch is point-to-point — "both can be true during
migration and the broadcast is idempotent" holds only on the legacy branch.

**Open, and I do not have an answer:** an agent running inside a container or a
sandbox on the device may not see the daemon's socket. Today the same agent
cannot see the Mac's socket either, so nothing regresses — but "the socket is
always reachable from the agent" is an assumption this design rests on and has
not been tested against `docker exec`-style sessions.

---

## 5. Daemon lifecycle — the single point of failure

Making `termiod` the only PTY owner is the one part of this RFC with no
mitigating side. An in-process PTY dies with the app, which is at least a shared
fate the user understands. This section is the list of what must be true before
that trade is acceptable.

### 5.1 What exists

- **launchd (macOS), for a daemon nothing installs.** `termiod service
  install|uninstall|status` writes a plist with `RunAtLoad` + `KeepAlive`,
  boot-out-then-bootstrap on reinstall, `TERMIOD_SOCK` forwarded only if the
  caller pinned it (`service.rs:64-95`, `install()` at `:135`, three unit
  tests). The app never calls it: `spawnDaemon()` `posix_spawn`s `termiod serve`
  directly with
  `POSIX_SPAWN_SETSID` (`TermiodClient.swift:369-406`). See item 8.
- **Crash accounting.** `tombstone.rs` records `exited` / `killed` /
  `daemon_lost` with identity, last workstream status, and timestamps, capped at
  100, surviving a restart; 7 smoke checks. A session still on the on-disk
  roster when a daemon starts was never buried, so the previous daemon died
  under it.
- **Version negotiation.** `hello` with `[min_proto, proto]`, hard refuse on no
  overlap, additive `caps` (`protocol.rs:28-41`, 4 smoke checks).
- **Backpressure.** Per-client 4 MiB budget, one forced resync, then drop
  (`session.rs:25`, `daemon.rs:414-444`) — §F #10 is closed.

### 5.2 What is missing or wrong, and each one is a release blocker

1. **The daemon does not ship.** `scripts/build-app.sh` and
   `.github/workflows/release.yml` do not mention `termiod`. There is a
   `termiod.yml` CI workflow that builds and smoke-tests it, and nothing that
   puts it in the `.app`. Worse, `Termiod.daemonBinaryPath()` defaults to
   `FileManager.default.currentDirectoryPath + "/termiod/target/debug/termiod"`
   (`TermiodClient.swift:73-79`) — a dev-tree path relative to a cwd a
   Finder-launched app does not have. **A released build today cannot start a
   daemon at all.** This must be first.

   **Copying the file in is the small half.** Inside the bundle the daemon is
   the first nested Mach-O other than Sparkle, and each of three consequences is
   work this item has been counting as free:

   - **Inside-out signing.** `build-app.sh` seals Sparkle's four helpers, then
     the framework, then the app (`:264-274`), because the comment at `:250-251`
     records that codesign rejects the bundle in any other order. The daemon
     needs the same identity and the same `--options runtime` (`:252-258`)
     *before* the outer seal, or the `notarytool submit` in `release.yml:116-131`
     rejects the submission. Note also that the verification line is `codesign
     --verify --deep --strict` (`build-app.sh:275`): `--deep` is deprecated for
     verification and does not check nested code the way its name suggests, so
     adding nested code makes that line actively misleading. Stage 1's criterion
     drops it.
   - **Slicing.** The release app is `lipo`'d from an arm64 and an x86_64 slice
     and refuses to ship if either is missing (`build-app.sh:122`, `:148-161`);
     the dev channel builds the host arch alone (`:123`). Nothing builds a macOS
     x86_64 `termiod`. `termiod.yml` runs `cargo build` host-native (`:98`) and
     cross-compiles exactly one release target,
     `aarch64-unknown-linux-musl` (`:122`); `release.yml` has no Rust step at
     all. An arm64-only daemon inside a universal app is an Intel Mac that
     cannot open a terminal — and after Stage 5 that is *every* terminal.
   - **TCC responsibility.** Today the daemon is `posix_spawn`ed by the app
     (`TermiodClient.swift:369-406`), so it and its PTY children run under the
     identity the user already granted. Under launchd (item 4) it is its own
     responsible process. This repo already reasons in exactly those terms —
     `docs/design/20260713-loose-terminal-entity.md:143-146` forbids walking
     down from `$HOME` because the resulting prompts are "attributed to Termio
     as the responsible process" — and after Stage 7 it is the daemon, not the
     app, doing the walking. **I did not test this**, so it is a risk row in §9
     and a first-launch check in Stage 1, not an asserted regression.
2. **Dev and release share a daemon.** Nothing sets `TERMIOD_SOCK` per channel,
   and both apps derive the socket from the same `TMPDIR`
   (`TermiodClient.swift:55-68`). Today that is harmless because the flag is off
   by default. After the fork is deleted, launching `termio-dev` shows — and can
   kill — the release app's sessions. Device architecture §9.1 assumes these are
   two devices; the code makes them one. *(Inferred from the path derivation, not
   yet observed; Stage 1's criteria test it.)*

   **The socket is one axis; the launchd job is a second, and item 4 activates
   it.** `service.rs` has a single `LABEL = "sh.termio.termiod"` (`:26`), which
   is also the plist filename (`:44-47`) and the `gui/$UID/…` target
   (`domain_target()` at `:116-118`, used at `:146`, `:162`, `:184`). Every
   other per-machine artifact this app owns is channel-scoped off one bundle-id
   read — support directory, `~/.termio[-dev]`, URL scheme, companion port, CLI
   name (`AppChannel.swift:24`, `:46`, `:57`, `:69`, `:76`;
   `SessionControl.swift:798`). The daemon's are not. Compose that with item 4
   and the channels repair each other's job on every launch: `termio.app` points
   `sh.termio.termiod` at its copy, `termio-dev.app` points it back, and
   `KeepAlive` respawns whichever won. A per-channel `TERMIOD_SOCK` fixes the
   rendezvous and leaves one job, one plist and one label for two apps to fight
   over.

   Not free either: `install()` takes no argument for *what* to install. It
   plists whatever binary ran the command — `std::env::current_exe()`
   (`resolved_binary()` at `service.rs:101-107`, called from `install()` at
   `:135,140`). Installing a job for the app's bundled copy needs a new
   `--binary`, and a per-channel job needs a `--label` beside it.
3. **No systemd unit.** `termiod service` bails on non-macOS with a message
   naming what to do by hand (`service.rs:121-127`). A Linux user daemon without
   `loginctl enable-linger` is killed at logout, so sessions silently die between
   SSH connections — the exact promise the product is built on.
4. **Install is not content-addressed.** `remote deploy` `scp`s over
   `~/.local/bin/termiod` (`remote.rs:223-227`), which is the `ETXTBSY` case
   device arch §6 calls out, and the readiness probe is `test -x` with no version
   check (`TermioStore+Termiod.swift:597-615`) — a stale daemon is caught only if
   `hello` outright fails.
5. **A dead session has no pane that explains it.** The first draft's version of
   this item — "tombstones are produced and never consumed" — was closed by PR
   #324: the client now decodes the roster's tombstones and clears one when the
   name comes back live (`TermioStore+Termiod.swift:298,338-360`). What is left is
   the half a user sees. A tombstone that only reaches the log is the failure mode
   it was built to prevent, and item 7 makes it the *only* thing a restart leaves
   behind.
6. **A transport failure is reported as `exited`.** `handleStreamEnd` →
   `deliverExitLocked(status: 1)` (`TermiodClient.swift:1557-1563`). The pane
   reports a death that did not happen. This is device arch §5.1's `4b`, and it
   is a prerequisite rather than a polish item: a daemon that restarts under a
   running app must not look like every session dying.
7. **Sessions do not survive a daemon restart. At all.** This is the blocker the
   first draft missed, and it invalidated a criterion it had already written.
   `Graveyard::open` runs at daemon start, reads the roster the last daemon left
   behind, and buries every entry on it as `daemon_lost`
   (`tombstone.rs:184`, burial loop `:194-201`). There is no fd handoff and no
   re-exec — `grep -rn 'SCM_RIGHTS\|execve' termiod/src` returns nothing, and the
   PTY master is an `OwnedFd` owned by the process (`pty.rs:99-101`). After a
   restart the new daemon's table is empty, `termiod list` returns nothing plus N
   fresh tombstones, and N children are re-parented holding a master nobody can
   read. Today an app crash and its shells share a fate the user understands;
   after Stage 5 a daemon crash kills every session on the machine, across every
   window, with no shared-fate intuition to explain it.

   **The decision: do not build survival.** Not fd handoff over `SCM_RIGHTS` to a
   holder process, not an `exec`-preserving re-exec. Both mean a second
   long-lived process whose only job is to outlive the first, and then every
   piece of session state — the ring, the writer token, the VT sidecar, the
   roster — has to be either transferable or reconstructible across the boundary,
   which is a supervisor design, not a feature. The daemon would gain the failure
   mode it was built to remove: two processes that can disagree about who owns a
   PTY. The other path is small and half-built already: **make restarts rare and
   honest.** Rare is item 8 — a supervised job that is restarted deliberately
   rather than dying quietly. Honest is item 6 plus a `daemon_lost` pane state
   that says what happened and offers to reopen, which is what tombstones were
   built for and what Stage 2's criterion now asks for. A user who is told "this
   session died when the daemon restarted, here is its last status" has lost
   work; a user whose panes silently report `exited` has lost trust as well.
8. **Nothing installs the launchd job, so the headline crash mitigation does not
   apply.** §9's risk table answers "a daemon crash loses every session at once"
   with `KeepAlive`, but `KeepAlive` only exists for a daemon installed by
   `termiod service install` (`service.rs:86-89`, written by `install()` at
   `:135`), and the app never calls it — it `posix_spawn`s the daemon itself
   (`TermiodClient.swift:369-406`). For an
   app-autostarted daemon there is no supervisor: it dies and stays dead until
   the next app launch. Two consequences follow that item 2 does not cover:

   - **Two daemons on one machine.** The app-spawned daemon inherits the *app's*
     environment — deliberately, and the comment at `TermiodClient.swift:394-396`
     says why (`TMPDIR` above all). A launchd-started one inherits launchd's. When
     those differ, `socketPath()` (`:55-68`) derives two different sockets, so
     there are two daemons and two session tables. Per-channel `TERMIOD_SOCK`
     (Stage 1 item 3) does not fix this; it is a different axis.
   - **Local version skew the day the daemon ships in the bundle.** Item 4 is
     about *remote* install. Once the daemon lives at
     `termio.app/Contents/Resources/termiod`, a user who also ran `termiod
     service install` has a launchd job pinned to an absolute path that an app
     update or a move to another folder invalidates — and `KeepAlive` keeps
     respawning whatever is at that path. Installing the job is therefore also
     *repairing* it, on every launch.
9. **A Sparkle update leaves the previous daemon running, and the only remedy
   buries every session.** Item 8's second bullet is about the *path* an update
   invalidates. This is about the *process*, and it is worse, because it is the
   normal path rather than a corner.

   Nothing stops the daemon on quit, deliberately: `terminateAllSessions`
   detaches the termiod links and kills only the in-process PTYs, and the
   comment says why — "surviving the quit is their whole point"
   (`TermioStore.swift:756-761`). Nothing stops it on update either. Sparkle
   swaps the `.app` under a running process (`App.swift:54-60`,
   `release.yml:133-165`) and the daemon is a separate process in its own
   session (`POSIX_SPAWN_SETSID`, `TermiodClient.swift:369-406`), so the state
   after every auto-update is a new app talking to the old build's daemon —
   and `serve()` refuses to start a second one while the socket still answers
   (`daemon.rs:313-317`).

   Both horns of that are bad, and today we sit on the quiet one:

   - **No gate, so skew is silent.** The handshake already carries the daemon's
     build string — `HelloOk.host` is `termiod/<version> <os>-<arch>`
     (`daemon.rs:511-516`) — and the client records it and logs it
     (`TermiodClient.swift:940`, `TermioStore+Termiod.swift:306-312`) and
     compares it to nothing. Only `proto` is negotiated, and the client sends
     `proto == min_proto == 1` (`TermiodClient.swift:928-929`). A *field* the
     new app expects and the old daemon omits degrades correctly by §3.2's skew
     rule. A changed *behaviour* on either side does not, and nothing reports it.
   - **A gate, so the update is an outage.** The day the app raises `min_proto`
     — open question 9 — `hello` hard-refuses, and every session on the Mac is
     refused at once. The only way to clear it is restarting the daemon, and
     item 7 prices that: every live session buried as `daemon_lost`
     (`tombstone.rs:184`, burial loop `:194-201`).

   Two otherwise-correct behaviours agreeing produce a shipped-product outage,
   and it arrives the day the daemon ships inside the bundle, because that is
   the day the version pair stops being a developer's checkout and becomes ours.
   Stage 1 must pick one of three, and say which:

   - **Drain and restart**, at a moment the app knows is quiet — which after
     item 7 means "no live sessions", so it is not a mitigation, it is a wait.
   - **A compatibility window**: accept an older daemon at the same `proto`,
     surface it, and restart on the user's word rather than on launch. Cheapest,
     and it is the option a `min_proto` gate forecloses.
   - **Updates end sessions**, stated out loud — in which case the user is told
     *before* Sparkle relaunches, the way the language switch already warns that
     "Running terminal sessions will end" (`LanguageSetting.swift:127`), not
     after.

### 5.3 Is a tombstone enough?

For the crash case, no — and the doc already knows it (§8.3: "Not done: the last
screen"). A tombstone says *that* a session died and what its status was; the
user's question is *what was on the screen*. Capturing it needs a snapshot
request threaded through the sidecar's shutdown path, which a `SIGKILL` does not
give you. The honest position: the last screen is recoverable on a **clean**
daemon exit and not on a crash, and the tombstone should say which it was rather
than implying an answer it does not have. `daemon_lost` already carries no
invented exit status; the same discipline applies to the screen — and, per item
7, to the session. The tombstone is not a consolation prize for a lost session;
after item 7 it is the *only* thing a restart leaves behind, so it is the whole
user-facing story of a daemon restart and has to read like one.

For the **skew** case, tombstones are irrelevant and negotiation is enough. The
failure that actually costs a user is not skew — it is (2) above, two channels
racing for one session table.

---

## 6. Performance — is one more IPC hop acceptable?

Measured (device arch §1, 2026-08-05): connect+hello **0.2 ms**, attach→first
frame **2.2 ms**, echo **~1 ms** above in-process. Against a 16 ms frame budget,
imperceptible. The throughput bench (`bench/bench_100x.py`) puts termiod at
4.4–6.0× tmux and, more tellingly, shows termiod's throughput barely moving
between plain and ANSI-heavy payloads.

That is enough to proceed. Five places where it may not be, ranked by how much
they worry me:

1. **Echo under a flood, which is unmeasured.** The 1 ms figure is an idle-system
   number. The interesting question is p95 keystroke echo *while* the same
   session is emitting at rate — a socket wakeup competing with a read pump
   competing with the sidecar. The daemon's own budget machinery says this was
   thought about; the end-to-end number does not exist. **Criterion:** with a
   `yes` flood running in the same session, p95 echo must stay under 16 ms.
   Anything above that is visible as a dropped frame.
2. **Connection-per-operation.** `withControlChannel` opens, hellos, requests,
   and closes for every `list` and every `kill` (`TermiodClient.swift:970`),
   and `TermiodSessionLink` owns a whole transport plus a dedicated
   `Thread` per session (`TermiodClient.swift:1099`, `:1365-1422`). Locally that is
   0.2 ms and a thread; over SSH without a warm ControlMaster it is 216–292 ms
   *per pane*. This is device arch §5.1 `4a`/`4b`, and after the fork is deleted
   it applies to every session on this Mac too.
3. **Startup fan-in.** Surfaces mount lazily (`surface(for:in:)` is called from
   `TerminalPane`'s body), so this is bounded by *visible* panes rather than by
   the restored session count — but a window restored with a 4-way split is
   still 4 connections, 4 handshakes and 4 thread starts on the launch path.
   That is the thing to measure, not the per-attach figure.
4. **The shared pipe.** Files, git, search and uploads ride the same connection
   as keystrokes. The daemon has the head-of-line discipline (credit-of-one,
   PTY frames drained first, 64 KiB caps — `protocol.rs:58-67`) and the client
   currently exercises none of it, because the client uses none of those planes.
   Wiring the panels (Stage 7) is when that discipline first gets tested.
5. **Cost, as opposed to latency — which nothing above measures.** Every one of
   the four items asks "does it feel slower?". None asks what the machine now
   spends. After this RFC a **local** session's bytes are parsed twice: once by
   the `termiod-vt` thread, which is unconditional (`session.rs:1223` builds every
   session with a sidecar, `:1263-1269` gives each one a dedicated OS thread) and
   fed on every chunk (`:1464-1470`), and once by libghostty in the app. Add a
   128 KiB ring per session (`RING_CAP`, `:23`) and up to 16 MiB of sidecar queue
   budget (`SIDECAR_QUEUE_CAP`, `:29`). Today it is parsed once, with neither.

   This is not an invariant violation — delivery genuinely does not wait on the
   parse, the comment at `:1466-1468` says so, and the degrade (`mark_vt_stale`)
   is honest. It is a bill nobody has read. And `bench/bench_100x.py` cannot read
   it either: it compares termiod against **tmux**, not daemon-plus-client
   against in-process. Item 3 is the smaller half of the same question — lazy
   surface mounting bounds *client connections* by visible panes, while daemon
   work scales with **sessions**, attached or not: 20 idle sessions are 20 VT
   threads and 20 tokio tasks whether any pane is open or not. On a laptop that
   is the number that decides whether this ships. **Criteria:** `termiod` RSS and
   steady-state CPU with 20 idle sessions and no client attached, against 20
   in-process sessions in today's app; and CPU-seconds to consume a fixed 200 MB
   ANSI-heavy payload, measured on the *pair* rather than on the daemon alone.

**Where the extra millisecond buys something back:** a session survives the app.
That is not a consolation — an app relaunch today costs a full shell respawn and
a lost screen, which is several orders of magnitude more than 1 ms.

---

## 7. The other fork — two CLIs, two servers

This is a separate axis from the PTY fork and deserves its own stage. It is not
"the CLI is missing a feature"; it is **the CLI is talking to the wrong server**.

```
scripts/termio (shell)  →  session-control.sock  →  TermioStore+SessionControl.swift  (Swift, 927 lines)
termiod        (Rust)   →  termiod.sock          →  termiod/src/                      (Rust)
```

**Merging the two binaries — shipping `termiod` *as* `termio` — was proposed and
rejected.** A hook does not name a binary: `reportCommand` bakes an absolute
Application Support path plus a subcommand and up to four flags
(`HookListener.swift:285-316`, path at `:289,330-331`), so a rename repairs
nothing it is supposed to repair; and a daemon named `termio` copied into
Application Support lands on `…/termio[-dev]/bin/termio`, the exact path the hook
CLI already owns (`SessionControl.swift:798,828-830`). The fork this section is
about is which *server* the CLI talks to, not what the binary is called.

### 7.1 What the client cannot supply at any price

The first draft led with a symptom — `sessions send` could not press a bare key —
and that was a mistake, because the symptom had a two-line client-side fix. It
shipped today as PR #325: delivery now writes raw bytes to the backend
(`TermioStore+SessionControl.swift:428-437`), `--no-enter` exists, and `esc` is
expressible. Leading with a bug that turned out to be a client bug invites the
conclusion that the whole stage is optional. It is not, for two reasons the
client cannot fix at any price:

1. **`read` needs a surface.** `readScreen` scrapes the *viewport* of a live
   libghostty surface (`:622-664`), so it answers `not_live` for a session no
   window has ever opened — and after PR #325 `send` still mounts a surface to
   deliver (`performDelivery` at `:378-409` waits up to three seconds for one to
   attach). An agent supervising a sibling has to make the sibling *visible* to
   read it. The daemon already holds the answer: a VT sidecar per session with a
   snapshot op, maintained whether or not anyone is watching.
2. **On Linux there is no server.** `termio sessions list` on a VPS talks to a
   Unix socket owned by a macOS app that is not running there. Every verb is
   simply absent on the machine where an agent supervising siblings is most
   likely to be. The daemon that is already running those sessions is one static
   binary, and it is already listening.

Neither is a missing feature in the CLI. Both are *the CLI talking to the wrong
server*, which is why this is a stage and not a bug fix.

`send`'s history is still the clearest illustration of the boundary, so it is
kept below as the worked example (§7.2) rather than as the motivation. Worth
recording what it cost: Codex's startup trust gate reads *"Press t to trust all;
esc to close"*, `send "t"` pressed `t` and then Return — answering the next
prompt too — and driving a sibling agent through that gate failed three times in
one session and needed a human at the keyboard. `termiod send` has had
`--no-enter` since it was written (`main.rs:88`, `:285-296`), which is the third
occurrence of this RFC's shape: the capability existed on the device and the
client path did not reach it.

### 7.2 The boundary — and it is not "move everything"

> **Encoding a human keypress is a viewer job. Writing bytes to a PTY is a
> device job. `send` was broken because it routed a byte write through the
> keypress path.**

⌘V, ⌃C, a dead key, an IME commit, kitty-protocol modifiers — all of these need
an `NSEvent` and ghostty's key encoder. Rust has no `NSEvent` and must not grow
a model of one; that is a nested window manager wearing a keyboard (§H #7).

A CLI that wants to press `t` does not have a keypress. It has a byte. Routing
it through a surface was not "reusing the input path" — it asked the human
encoder to reconstruct an intent that was never a keystroke, and the synthetic
Return was the tell. PR #325 drew the line in the right place inside the client
(raw bytes for the payload, a real key event for the submit,
`TermioStore+SessionControl.swift:399-408,428-437`); Stage 6 moves the byte half
to the machine that owns the PTY without moving the encoder half anywhere.

There is a different route to the same problem, already spiked and deliberately
not taken here: `poc/headless-input-plane` (branch `poc/headless-input-plane`,
263 lines) drives an agent over `--input-format stream-json` with no PTY at all
and hands off to `claude --resume` in a terminal afterwards. That is a change to
what a *session* is, not to which server a CLI talks to. This RFC does not take
it; it is noted so nobody re-spikes it.

### 7.3 Verb-by-verb

Classified by the §1 test. "Device" means the answer is the same from any
viewer; "viewer" means it names *this* window or *this* Mac.

| Verb | Asks about | Today | After |
| --- | --- | --- | --- |
| `send` / `answer` | **Device** — bytes into a PTY | raw bytes to the backend, but only after mounting a surface (`:378-409`, `:428-437`) | `termiod send`, same bytes, no surface — so it reaches a session no window has opened, and works with no app at all |
| `read` | **Device** — what is on that screen | client viewport scrape, requires a live surface (`:622-664`) | daemon snapshot; works for a session no viewer has ever opened. **A behaviour change, not a relocation:** the daemon's `S` is the *active screen*, while the scrape follows the user's scrollback — a caveat `TermioStore+TerminalSurface.swift:281-286` already documents. Moving `read` silently fixes it and changes the answer for a scrolled pane |
| `watch` | **Device** — status transitions | `SessionWatchHub` over the app socket (`SessionControl.swift:270-284`, hub at `:381`) | `subscribe {events:["status"]}` → `E` frames |
| `list` | **Split** | app project tree + status (`:169-218`) | device answers sessions/status/agent/title; **cwd is the exception** — `SessionInfo.cwd` is the spawn cwd (§1.1) while the app reports the *followed* cwd from a 350 ms poll (`TermioStore+TerminalSurface.swift:415`), so `list` either waits for Stage 3's cwd work or the viewer keeps overlaying its own value. Grouping and `termio://` links stay with the viewer |
| `spawn` / `run` | **Split** | app creates a `Session`, mounts a surface, then sends (`:252`) | device `create`; viewer places it in a project and a pane |
| `close` | **Split** | `ptyProcesses[id].terminate()` + remove the row (`TermioStore+ProjectActions.swift:721`) | device `kill`; viewer removes the row. The distinction detach≠kill becomes expressible |
| `agent report` | **Device** | Mac's `agent-status.sock` | `termiod set-status` (§4) |
| `focus` | **Viewer** — selects a pane in *this* window | app | **stays in the app** |
| `notify` | **Viewer** — this Mac's Notification Center | app | **stays in the app** |

Two verbs stay. Everything else moves, and `focus`/`notify` staying is not a
residue — they are the two verbs that fail the two-observers test outright.

**`send` keeps appending Enter by default.** "Type a prompt into a session" is
what the verb documents and what every existing caller relies on; making a
one-character payload silently mean something different would be magic. What
changes is that the Enter becomes a `\r` **byte** instead of a synthetic key
event, so it can be turned off: `send --no-enter`, spelled exactly as
`termiod send` already spells it (`main.rs:88,292`). Byte-exact either way — no
surface, no encoder, no 40 ms sleep. `esc` becomes expressible for the first
time because it is just a byte too.

Three sub-features need naming because they are not verbs:

- **`send --wait`** (`:467-621`) waits on *status resting* plus a screen-change
  fallback. Status is already an `E` event and `wait` is already a control op
  (`protocol.rs:515`, smoke check 48). The screen fallback and the
  stalled-prompt / occupant-gone heuristics are supervision policy and belong to
  the client. **Undecided:** whether `wait`'s `until` set grows to cover the
  stalled case or the client keeps polling; I have not thought this through far
  enough to pick. Note what that leaves unresolved for §7.4: on a box with no Mac
  app there *is* no client to hold the policy, so `send --wait` there degrades to
  the `wait` op's `until` set and loses the stalled-prompt heuristic — which is
  the one supervising agents actually rely on. Either name the degrade in the
  CLI's own help, or settle open question 3 before Stage 6 ships `send`.
- **`watch --state stalled`** is explicitly documented as "a watch-plane signal,
  not a real status" and is computed from repo change plus transcript growth. It
  is derived state over device facts; it stays on the client.
- **Project scoping.** Every request today is resolved to a project via
  `callerProject(session:cwd:)` (`:802-830`). On a device that becomes a
  workspace, which is device arch §8.11 and not this RFC. Interim: the viewer
  keeps doing the scoping and passes an explicit target to the device.

### 7.4 The Linux payoff

`termio sessions list` on a box with no Mac app has no server. After the move it
has one — the same daemon that is already running the sessions. An agent
supervising siblings from inside a VPS session gets the same verbs it has on the
laptop, minus the two heuristics that live in the viewer (§7.3's note on
`send --wait`), and `termiod` is one static binary. This is the same return as "local
also goes through termiod", collected on a different surface.

### 7.5 Coexistence during migration

`scripts/termio` is a published contract; `termio agent report` is baked into
users' agent config files by past releases (AGENTS.md names it as the public
hook contract). It cannot be swapped wholesale.

The shape that avoids a flag day: **`scripts/termio` becomes a router, one verb
at a time.**

```
if TERMIOD_SESSION is set (or the resolved target names a device session):
    speak the session protocol   →  termiod
else:
    speak the legacy request     →  app control socket
```

Per verb, the sequence is: implement on the daemon → route the verb → verify
both branches → delete the Swift handler. The Swift control plane's last day is
when its final case is unreachable — `handleSessionControl`'s switch
(`TermioStore+SessionControl.swift:44-53`, `focus` at `:48` and `notify` at
`:50`) is down to those two, at which point they stay and the streaming `watch`
path (`SessionControl.swift:270-284`) goes with the rest.

**Output shape is the compatibility surface, not just the verb.** `--json`
replies carry `schema_version: 1` and a documented field set; a caller that
parses them (an agent, a script) must not see the shape change under it. Each
moved verb keeps its reply shape byte-for-byte until a deliberate, versioned
change.

---

## 8. Migration

Each stage is independently shippable, independently revertible, and carries a
criterion that can be **run**. "It compiles" is not a criterion anywhere below.

### Stage 0 — clear the field

Not optional and not bookkeeping: the refactor rewrites `TermiodClient.swift`,
`TermioStore+Termiod.swift`, `Models.swift`, `TermioStore.swift`,
`TermioStore+ProjectActions.swift`, `CompanionServer.swift` and
`SidebarView.swift`. When this RFC was first written, three worktrees held
uncommitted or unpushed edits to exactly those files, the same 1,415-line change
existed in three places in three states of commit, and none of it was pushed.

**Most of that is now cleared, and the way it cleared is the rule this stage
should carry forward.** Re-measured at `7206463`:

| Worktree | Branch | Uncommitted | Ahead of `origin/main` | Pushed |
| --- | --- | --- | --- | --- |
| `termio` (main checkout) | `main` | 9 files | 0 | — |
| `.../scratchpad/wt-298` | `rebase/companion-link-resilience` | clean | **1** | **no** |
| `termio-worktrees/clickable-paths` | `feat/clickable-file-paths` | clean | 3 | yes (PR #73) |
| `termio-worktrees/ios-chat-lens` | `feat/ios-chat-lens` | clean | 1 | yes (PR #296) |
| `termio-worktrees/stats-cron` | `ci/stats-skip-when-unconfigured` | clean | 1 | yes (PR #307) |
| `termio-worktrees/tunelo-stable` | `feat/tunelo-stable-subdomain` | clean | 1 | yes (PR #299) |
| `termio-worktrees/ios-agent-gui` | `docs/ios-agent-gui` | clean | 1 | yes (PR #275) |

The caps branch landed as PR #324, which also closed §5.2 item 5 (tombstones are
decoded and cleared, `TermioStore+Termiod.swift:298,338-360`), and the duplicate
worktrees were folded in and removed. The three that had been holding dirty
trees were preserved as `wip/remote-to-device`, `wip/settings-file-watch`,
`wip/editor-scrollaway-header` and `wip/ios-device-rename` — commits on throwaway
branches, not discards.

**That is the standing rule, and it replaces the first draft's instruction to
"discard".** Uncommitted work has no reflog; `git checkout -- .` is the only
irreversible operation anywhere in this ladder, and it was in the one stage with
no rollback line. Every time this stage says *clear a worktree*, it means:
**commit on a throwaway `wip/<slug>` branch, then remove the worktree.** It costs
one commit and makes the step reversible. Nothing in Stage 0 is ever discarded.

**What is left, and the test for each:**

1. **Rescue `rebase/companion-link-resilience`.** One commit
   (`CompanionServer.swift` +54 and three iOS files), unpushed, living in a
   `/private/tmp` scratchpad the OS may delete. It is a rebase of PR #298's
   branch. Push it or fold it into PR #298; either way it must stop living in a
   temp directory.
2. **Resolve the two open PRs on `CompanionServer.swift` before Stage 4 starts.**
   PR #298 (4 files) and PR #296 (17 files) both touch it. That file is §1.5's
   "largest single item" and the whole premise of Stage 4, so this is the one
   collision that genuinely serialises work.
3. **Keep the long tail from growing.** Twenty-nine local branches are ahead of
   `origin/main` and unpushed, a third of them `wip/*` snapshots from the
   clean-up above. They are safe by construction — that is the point of the rule
   — but they are also unreviewed, so anything still wanted becomes a PR and the
   rest gets deleted deliberately rather than forgotten.
4. **Close the noise PRs.** PR #317 carries six `__pycache__/*.pyc` files it
   should not.

**Criterion for Stage 0:** `git worktree list` shows no worktree with
uncommitted changes to any of `Sources/termio/Terminal/Termiod/*`,
`Sources/termio/TermioStore/*`, `Sources/termio/Companion/*`,
`Sources/termio/App/Models.swift`,
`Sources/termio/Terminal/Ghostty/PTYProcess.swift`; no worktree lives under
`/tmp` or `/private/tmp`; and every branch ahead of `origin/main` is either
pushed with a PR or deleted.

**What Stage 0 does *not* need to clear.** The first draft claimed no open PR
touched any refactor-critical file except `TermioStore.swift` in PR #73. That was
wrong on the file that matters most: `CompanionServer.swift` carries two open PRs
and the unpushed rebase above. It holds for the rest — no open PR touches
`PTYProcess.swift`, `TermioStore+TerminalSurface.swift`, `GitService.swift` or
`FileBrowser/`, so the PTY and panel work (Stages 3, 5, 7) really can run in
parallel. The companion work cannot.

### Stage 1 — the daemon ships and is reachable

Nothing below is safe until a released app can start a daemon.

1. Build `termiod` in `release.yml` and copy it into the bundle
   (`Contents/Resources/termiod` or `Contents/MacOS/`). Three parts, none of
   them a line of `cp` (§5.2 item 1): a **universal** daemon, `lipo`'d from an
   arm64 and an `x86_64-apple-darwin` slice and checked the way
   `build-app.sh:152-161` already checks the app's own; **signed before the
   outer seal** with the same identity and `--options runtime`, in the
   inside-out order `build-app.sh:264-274` establishes; and carried through
   notarization with the DMG.
2. `daemonBinaryPath()` resolves the bundled binary first, then
   `TERMIO_TERMIOD_BIN`, and only then the dev tree.
3. Make the daemon channel-scoped on **both** axes (§5.2 item 2): derive
   `TERMIOD_SOCK` per channel so `termio-dev` and `termio` are two devices, as
   device arch §9.1 already assumes, *and* give the launchd job a per-channel
   label, since `service.rs:26` has exactly one. That needs `termiod service
   install --label` and `--binary`, because `install()` today can only plist the
   binary that invoked it (`service.rs:101-107,135,140`).
4. **The app installs or repairs the launchd job on first launch**, instead of
   `posix_spawn`ing the daemon and hoping. Repair, not just install, because the
   plist pins an absolute path (`service.rs:101-107`) that an app update or a
   move invalidates (§5.2 item 8). Until this lands, §9's `KeepAlive` mitigation
   is fiction, and `spawnDaemon` remains the fallback for the case where
   bootstrapping the job fails.
5. Ship the systemd `--user` unit + `enable-linger` guidance as
   `termiod service install` on Linux.
6. **Answer what an update does to the running daemon** (§5.2 item 9) and
   implement the answer here, not after the first release that ships one. The
   recommendation is the compatibility window: the app compares `HelloOk.host`
   (`daemon.rs:511-516`) against its own build, and an older same-`proto` daemon
   is accepted with a visible "restart to finish updating" affordance rather
   than refused. Whatever is chosen, `min_proto` must not be raised in the same
   release that first bundles the daemon.

**Criteria (run, not read):**
- On a machine with no checkout: install the notarized `.app`, launch it from
  Finder, open a terminal, and `termiod service status` reports a live socket;
  `ps -o comm= -p <daemon pid>` resolves to a path inside the `.app` bundle.
- `kill -9` the daemon; `launchctl print gui/$UID/<this channel's label>` shows
  it respawned and `termiod list` answers. (This is the criterion that proves
  item 4 — the current build fails it, because nothing bootstraps the job.)
- `lipo -archs termio.app/Contents/Resources/termiod` prints both `arm64` and
  `x86_64` — the same check `build-app.sh:152-161` already runs on the app
  binary, applied to the daemon. Runs on any checkout, no credentials.
- `codesign --verify --strict --verbose=4 termio.app` passes with the daemon
  inside, `codesign -d --verbose=2 termio.app/Contents/Resources/termiod` reports
  the same Developer ID authority as the app and `flags=…(runtime)`, and
  `spctl -a -vvv -t exec termio.app` accepts the notarized build.
  Not `--deep`: Apple deprecated it for verification and it does not check nested
  code the way the flag name suggests — which also means `build-app.sh:275` stops
  being the thing that proves anything once there is nested code to miss.
  **Maintainer- or CI-only**, along with the notarization criteria below: they
  need the Developer ID identity and the App Store Connect key.
- The `notarytool log` for the release submission lists **zero** issues against
  `Contents/Resources/termiod`. A daemon signed after the outer seal, or without
  the hardened runtime, fails here rather than on a user's DMG. **Maintainer- or
  CI-only.**
- First launch from a fresh user account with the launchd job installed: open a
  session, `cd ~/Desktop`, `ls`. No TCC prompt attributed to `termiod` appears,
  and `log show --predicate 'subsystem == "com.apple.TCC"' --last 5m` names no
  denial. This is the check §5.2 item 1's third bullet refuses to assert an
  answer to; if it fails, the daemon needs the app as its responsible process
  and item 4's launchd job is wrong on macOS.
- Launch `termio-dev` and `termio` together; each `termiod list` returns a
  disjoint session set, `hello_ok.host_id` differs between them, and
  `ls ~/Library/LaunchAgents | grep termiod` shows **two** plists whose
  `ProgramArguments` point into their own bundles. Relaunch each app three times
  in alternation and both plists still do.
- Install the previous release, open a session, then let Sparkle update in place
  and relaunch. Sessions still open (the compatibility window of item 6), the app
  says the daemon is behind, and taking the restart it offers is the *only* thing
  that produces a `daemon_lost` tombstone. Nothing is buried by the update
  itself.
- On Linux: `termiod service install`, `loginctl terminate-user $USER`, log back
  in, `termiod list` still shows the session created before logout.

**Rollback:** the flag is still off by default; revert the bundling commit.

### Stage 2 — the connection is an object

Device arch §8.4. Prerequisite for every later stage because it is what stops a
daemon restart from reading as N session deaths.

- `4a`: put `ssh_multiplex_args()`'s option set — plus the `BatchMode` /
  `ConnectTimeout` every other ssh call site already sets and this one does not
  — on the app's own ssh invocation.
- `4b`: a `TermiodConnection` per device owning transport, health and reconnect.
  `TermiodSessionLink` becomes a client of it. `handleStreamEnd` stops calling
  `deliverExitLocked`.

What this stage does **not** do, stated up front because the first draft's
criterion assumed the opposite: it does not make sessions survive a daemon
restart. Nothing does — §5.2 item 7, and by decision nothing will. Stage 2 fixes
the *reporting*, which is a separate and achievable thing.

**Criteria:**
- With three panes open on one SSH device, `pgrep -lf 'ssh .*<alias>'` shows
  **one** ssh process, not three.
- `launchctl kickstart -k gui/$UID/sh.termio.termiod` while three local panes are
  open: no pane shows "process exited". Each shows a reconnecting state, then a
  state named `daemon_lost` — distinct from `exited`, because the session did not
  exit, its daemon did — and offers to reopen. `termiod tombstones` lists all
  three with reason `daemon_lost` and no invented exit status.
- The same restart under an **SSH** device with a transport blip instead of a
  daemon death: panes reconnect and repaint from a snapshot with their history
  intact, and `termiod list` returns the same session ids before and after. This
  is the case Stage 2 genuinely repairs — `handleStreamEnd` today reports it as
  every session dying (`TermiodClient.swift:1557-1563`).

**Rollback:** self-contained; the link keeps working if the connection object is
reverted.

### Stage 3 — foreground parity (§3)

`foreground_job` on `SessionInfo`, `foreground_changed` as an event, the
Linux/macOS split behind one trait, argv → agent mapping staying on the client.

**Criteria:**
- New smoke checks: with `sleep 60` running, `list` reports
  `foreground_job: true`; at a bare prompt, `false`. Run in `termiod`'s CI on
  both macOS and Linux — this is the test that settles §3.1's uncertainty.
- Start a shell session on a VPS, run `sleep 60`, press ⌘W: the same
  confirmation a local shell gives today.
- Type `claude` at a prompt in a *termiod* session; the sidebar row's icon
  becomes Claude's within 1 s, and reverts on exit. (This is the bug from §0
  that has no fix without this stage.)
- A daemon built without the field: closing a shell with a live job shows **no**
  dialog — today's behaviour, not a blanket confirm.

**Rollback:** additive field; an app that ignores it behaves as before.

### Stage 4 — the companion stops depending on `PTYProcess`

The blocker identified in §1.5, and **the biggest stage in this RFC.** Not "extract
a protocol both types satisfy": three of `PTYBridge`'s twelve members have no
daemon counterpart, and each is its own decision.

- **Byte-capped replay.** `attach` replays the daemon's ring; the phone needs *at
  most 128 KiB of* it, because the whole ring reflowed at a narrow grid is the
  allocator-panic trigger the comment at `CompanionServer.swift:988-992` records.
  Either the wire grows a replay bound on `attach`, or the client truncates what
  it receives — the second is cheaper and wastes bandwidth on exactly the link
  (a phone over a tunnel) that has least to spare. Decide it here, not in code
  review.
- **Exit fan-out.** `TermiodSessionLink.onExit` is one closure and
  `attachTermiodLink` holds it (`TermioStore+Termiod.swift:119`). The link needs
  an observer registry, which is a small change made twice as large by the exit
  *policy* already being duplicated (§1.1).
- **`jiggleResize`.** A resize to identical dimensions is a daemon no-op, so
  "make the child redraw" has no verb. The honest options are a client-side
  wipe-plus-snapshot request, or accepting that a phone re-attaching at the same
  size shows a stale frame until the next output. Do not invent a host-side
  redraw op without arguing it — the host does not decide presentation.

Reconciling explicit-claim ownership with newest-writer-wins (§1.1) is the fourth
piece, and the one most likely to change phone behaviour visibly.

**Criteria:**
- With `TERMIO_TERMIOD=1`, open a session on the phone, type, resize, background
  and foreground the app: same behaviour as with the flag off. Verified on a
  real device, not the simulator.
- Cold attach to an alt-screen TUI (Claude Code) and to a plain shell with a full
  scrollback: neither shows a ghost frame, and the phone does not hit the
  allocator panic screen. This is the criterion the replay cap exists for.
- Kill the child from the Mac while the phone is attached: the phone's session
  ends, proving the exit registry fans out to more than one observer.
- `grep -rn 'PTYProcess' Sources/termio/Companion/` returns nothing.

**Rollback:** the seam has one other conformer; revert to the concrete type.

### Stage 5 — delete the fork

Only now. Remove `Termiod.isEnabled` (`TermiodClient.swift:46`) and every branch
on it, the in-process `PTYProcess` construction
(`TermioStore+TerminalSurface.swift:228-231`), the flag-off alert
(`TermioStore+Termiod.swift:699-701`), and the `ptyProcesses` half of
`terminateAllSessions` (`TermioStore.swift:756`; the detach half already ships).

**Criteria:**
- `grep -rn 'TERMIO_TERMIOD\b' Sources/ | wc -l` → 0. (Correctly excludes
  `TERMIO_TERMIOD_BIN`, which Stage 1 item 2 keeps.)
- `grep -rn 'PTYProcess(' Sources/ | wc -l` → 0.
- Open a local terminal, run `sleep 300`, quit the app, relaunch: the pane
  reattaches to the **same pid** (compare `termiod list --json`) with its screen
  intact.
- `swift test` green, including `SplitTreeTests` and the status tests. This is
  runnable: issue #311 ("Swift unit tests cannot run at all") closed on
  2026-08-17 and the `Test` step is green on `main`.
- Screen-recorded pass of: new terminal, new agent session, split, close with a
  running job (dialog), close idle (no dialog), agent self-quit reverting to a
  shell.

**Rollback: this is the one stage that is hard to revert**, because it deletes
the alternative. Mitigation is sequencing, not a switch: Stages 1–4 each remove
a reason the flag existed, so by the time this lands the flag has been on by
default for a full release cycle. Concretely — **ship Stage 4 with the flag
defaulting to on and the env var able to force it off**, run one release, then
delete in Stage 5. The escape hatch is a release rollback, not a runtime flag.

### Stage 6 — the CLI moves, verb by verb (§7)

Order chosen so the verbs the client cannot fix land first (§7.1):

1. `read` — daemon snapshot, for a session no window has opened.
2. `send` / `answer` — the same bytes PR #325 already sends, minus the surface.
3. `watch` — `subscribe`.
4. `list` — device fields from the daemon, grouping from the viewer. Ordered
   after Stage 3 because of cwd, below.
5. `spawn` / `run`, `close` — split as in §7.3.
6. `agent report` → `set-status` (§4), and hook installation on the device.

**Criteria:**
- `termio sessions read <s>` returns the screen of a session that has **never**
  been opened in a window (today: `not_live`), and returns the *active* screen
  for a pane the user has scrolled up — a deliberate change from the viewport
  scrape, so `read --help` says which screen it reports.
- On a Linux box with no Mac app: `termio sessions list`, `read` and `send` work
  against the local daemon.
- `termio sessions send <s> t` reaches a session with **no surface mounted** —
  today it mounts one and waits up to 3 s
  (`TermioStore+SessionControl.swift:378-409`). Keep PR #325's behaviour
  regression tests: on a session running `cat -v`, `send --no-enter <s> t` puts
  exactly `t` on the screen with no `^M` and no second line; plain `send <s> t`
  still shows `t` followed by a submit; a multi-line payload still arrives as one
  bracketed paste.
- Old-shape check, on **values** and not only fields: `termio sessions list
  --json` matches the pre-move build for the same session set, measured on a
  session that has `cd`'d out of its spawn directory. Field-identical output
  passes while `cwd` silently rots back to the spawn cwd (§7.3), which is the
  regression this criterion exists to catch.
- After the last move, `handleSessionControl`'s switch contains `focus` and
  `notify` and nothing else.

**Rollback:** per verb — the router's legacy branch is still there until the
Swift handler is deleted, and deleting each handler is its own commit.

### Stage 7 — the panels move (device arch §8.9)

File tree, search, and git status/diff read the workspace's device through the
`files`/`git` planes. `SSHFileSystemProvider` and `SFTPClient` (531 + 878 = 1,409
lines) are deleted. `GitService`'s 12 history/compare/remote verbs are the part
with no device counterpart and stay local until the daemon grows them — say so in
the UI rather than showing an empty pane.

Deleting SFTP is a **user-visible removal**, not only a refactor, because the
SFTP tree is the one remote file tree that works today and it is keyed on
`session.sshHost` (`FileBrowserView.swift:53-54,68-70`) — a machine that may have
no `termiod` on it at all, so `fs.list` cannot stand in. §1 makes that call and
this stage pays for it: a plain-`ssh` session's panes say the host has no daemon
and offer to install one (`remote deploy` already does the installing), the same
way the git pane will name its missing history verbs.

**Criteria:**
- A plain-`ssh` session (`session.sshHost != nil`) shows the install affordance
  in the Files pane, and taking it turns the same session's host into a device
  whose tree renders through `fs.list`. Not an empty pane, and not a silent one.
- The file tree renders for a session on a VPS, and expanding a directory that
  has never been listed costs one round trip (measure with a request log).
- `touch` a file on the VPS; it appears in the tree without a manual refresh.
- ⌘⇧O finds a file on the VPS by name, and shows "still indexing" rather than
  silently missing files while `coverage < 1.0`.
- The git changes pane shows a VPS worktree edit with the correct two-axis
  status.
- `grep -rn 'SFTP' Sources/ | wc -l` → 0.

---

## 9. Risks and rollback

| Risk | Why it is real | Mitigation |
| --- | --- | --- |
| **The daemon becomes release-critical and it has never shipped** | §5.2 item 1: the release pipeline does not build it and the fallback path is a dev tree | Stage 1 first, with a criterion that runs on a clean machine from a notarized build |
| **A daemon crash loses every session at once** | Shared fate is replaced by a single point, and there is no survival mechanism at all — §5.2 item 7 | Make restarts rare: the app installs and repairs the launchd job so `KeepAlive` actually applies (Stage 1 item 4 — it does **not** today, §5.2 item 8). Make them honest: tombstones (shipped, decoded since PR #324) plus a `daemon_lost` pane state, never `exited` (Stage 2). The last screen stays unrecoverable on `SIGKILL` and the tombstone says so (§5.3) |
| **Two daemons on one machine** | An app-spawned daemon and a launchd-spawned one derive `socketPath()` from different environments (§5.2 item 8) | The app owns the job: install/repair on launch, and treat `spawnDaemon` as the fallback rather than the normal path |
| **The bill nobody read: every local byte parsed twice** | The VT sidecar is unconditional, one thread and one 128 KiB ring per session, attached or not (§6 item 5) | Measure the pair, not the daemon: RSS/CPU at 20 idle sessions and CPU-seconds over a fixed 200 MB payload, both against the in-process baseline, before Stage 5 |
| **Stage 5 is not revertible** | It deletes the alternative | Flag-on-by-default for one release before deletion; rollback is a release rollback |
| **Rebuilding work that exists on an unpushed local branch** | The 1,415-line caps branch landed as PR #324, but a `CompanionServer.swift` change still sits unpushed in a `/private/tmp` worktree | Stage 0 items 1–3; no worktree under `/tmp`, nothing discarded, everything on a `wip/<slug>` branch |
| **The companion breaks silently** | `PTYBridge` is typed on the concrete class, uses twelve of its members, and no test covers the phone (§1.5) | Stage 4 gates Stage 5, with real-device criteria for the cold attach, the replay cap and the exit fan-out |
| **Anti-100× regression** | Adding foreground sampling and a status source to the daemon puts new work near the read loop | Every new sampler runs on its own task; the criterion is the existing `bench_100x.py` staying within its current band, run in CI before and after Stage 3 |
| **`termio sessions` breaks an agent's script** | It is a published contract with a documented JSON shape, and one field (`cwd`) changes meaning rather than shape | Per-verb routing with the legacy branch alive; Stage 6's compatibility criterion compares **values** on a session that has `cd`'d, not just field names |
| **Dev and release fight over one session table** | Same socket derivation, *and* a single launchd label, plist and target (`service.rs:26`, `:44-47`, `:116-118`) that item 4 then makes both apps rewrite on every launch (§5.2 item 2) | Stage 1 item 3 on both axes, with criteria that check `host_id` differs **and** that two plists survive alternating relaunches |
| **The daemon ships but the bundle does not pass notarization** | It is the first nested Mach-O other than Sparkle; signing is inside-out and order-dependent, and `--deep` verification does not catch nested code (§5.2 item 1) | Stage 1 item 1 signs it before the outer seal with `--options runtime`; the criteria check the authority, the runtime flag, and a clean `notarytool log` |
| **An arm64-only daemon inside a universal app** | The app `lipo`s two slices and fails loudly if one is missing (`build-app.sh:152-161`); nothing builds a macOS `x86_64` `termiod` at all (`termiod.yml:98,122`, no Rust step in `release.yml`) | Same check, applied to the daemon: `lipo -archs` in Stage 1's criteria, runnable without credentials |
| **The daemon becomes its own TCC responsible process** | Under launchd it is, and this repo already writes rules keyed on that attribution (`docs/design/20260713-loose-terminal-entity.md:143-146`); after Stage 7 the daemon does the directory walking | Untested — Stage 1 carries a fresh-account first-launch check, and a failure means the launchd job is the wrong shape on macOS, not that the check was pessimistic |
| **A Sparkle update takes every session down** | Nothing stops the daemon on quit or on update (`TermioStore.swift:756-761`), a second one refuses to start (`daemon.rs:313-317`), and the only remedy buries the roster (§5.2 items 7 and 9) | Stage 1 item 6 decides it before the daemon ever ships: a compatibility window, no `min_proto` raise in the bundling release, and a criterion that updates in place from the previous release |
| **Panels regress for local projects** | Stage 7 replaces a working local path with a round trip | `fs.list` replies are `seq`-stamped and clients cache indefinitely (§C.12), so a visited directory is 0-RTT; the criterion measures the cold expansion, and the local socket makes it sub-millisecond |

---

## 10. Open questions

1. **Hook payload shape (§4.2 item 2).** Extend `SetStatus` with four optional
   fields, or add a `workstream` update op? Nothing forces the choice yet.
2. **Can an agent in a container reach the daemon socket?** The whole hook design
   assumes yes. Untested against `docker exec`-style sessions. Nothing regresses
   if the answer is no — the Mac's socket is equally unreachable today — but the
   design would need a second route.
3. **`send --wait`'s stalled-prompt heuristic (§7.3).** Grow `wait`'s `until`
   set, or keep polling on the client? Undecided.
4. **What replaces `reapStrayOrphans`?** Sharper than it looked in the first
   draft: §5.2 item 7 means this fires on **every** daemon restart, not only on a
   crash, because the new daemon never re-adopts the old one's children. They are
   re-parented to launchd holding a master nobody reads. The current Swift sweep
   matches on `TERMIO_SESSION` + `TERM_PROGRAM=termio`
   (`PTYProcess.swift:953`); the daemon needs its own equivalent, run at start,
   before it buries the roster. Unchecked: whether a `KeepAlive` restart adopts
   or races them.
5. **Does `PTYProcess` survive at all?** After Stage 5 nothing constructs it. It
   holds real learning (the `forkpty` shape, the non-blocking write backlog),
   most of which `pty.rs` already mirrors. Delete or keep as a test fixture —
   cheap either way, no need to decide now.
6. **Linux `tcgetpgrp` on the ptmx master (§3.1).** Strong precedent, not
   verified here. Stage 3's CI criterion is the verification. Note that the
   fallback the first draft proposed — `/proc/<child>/stat`'s `tpgid` — answers a
   different question (it finds the *pgid*, which `tcgetpgrp` already gives you)
   and does nothing about §3.1's real Linux hazard, a zombie group leader. Scan
   `/proc` for a live member of the group, as tmux does.
7. **Git history on the device.** 12 `GitService` verbs have no daemon
   counterpart. Port them, or accept that history is a local-project feature
   until someone asks? The read-only-by-design rule (§C.13) covers *mutation*;
   it says nothing about history, which is read-only and genuinely missing.
8. **How does a `daemon_lost` pane offer to reopen?** §5.2 item 7 decides that a
   restart loses sessions and says so. What it does not decide is what the pane
   does next: reopen the same command in the same cwd under a new session id, or
   wait to be asked. Reopening silently would claim a continuity that does not
   exist; asking on every pane after a restart is a wall of dialogs.
9. **When may the app require a `hello`?** Deprecation policy for v0-only
   clients is listed as a human product call in the protocol doc's top five and
   is still open. It becomes load-bearing the day the daemon ships in the app,
   because then the version pair is *ours* and the skew window is a user's
   upgrade lag rather than a developer's checkout. §5.2 item 9 narrows it to one
   rule that has to hold whatever the policy turns out to be: do not raise
   `min_proto` in the release that first bundles the daemon, because a running
   old daemon is guaranteed on that upgrade and refusing it refuses every
   session on the Mac.
