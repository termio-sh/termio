---
title: Unify the server plane in Rust, reduce the Mac app to a viewer
status: active
type: rfc
created: 2026-08-19
updated: 2026-08-31
related:
  - 20260831-companion-second-protocol-retires.md
  - 20260831-docker-dockerd-lessons.md
  - 20260817-one-path-local-through-termiod.md
  - 20260817-one-path-local-through-termiod.review-claude.md
  - 20260818-one-workspace-source.md
  - 20260818-one-workspace-source.review-codex.md
  - 20260818-remote-git-plane.md
  - 20260805-termiod-device-architecture.md
  - 20260819-device-workspace-project.md
  - 20260818-termiod-web-client-ghostty-wasm.md
---

# Unify the server plane in Rust, reduce the Mac app to a viewer

> One server — `termiod` — owns every answer two people on two machines would
> expect to match. Swift renders and nothing else. This is the **execution
> spine**: the single ordered list of what happens next, restamped against the
> tree at `c69c022`.

---

## 0. What this document is, and is not

It is not a re-argument. Four documents already made the case and are still the
place to read *why*:

| Document | What it is authoritative for |
| --- | --- |
| `20260805-termiod-device-architecture.md` | **The normative invariants.** §4 the presentation boundary, §4.1 what each side owns, §5 the four planes and one connection, §5.1 the connection as an object |
| `20260819-device-workspace-project.md` | The vocabulary: Device → Workspace → Project → Session, and which of those a device owns |
| `20260817-one-path-local-through-termiod.md` | The Swift-side inventory, the daemon-lifecycle blockers, the CLI verb-by-verb split |
| `20260818-remote-git-plane.md` | The git tiers, and the askpass mechanism |

This document does the three things none of them can do individually:

1. **Restamps them against the tree**, so nobody rebuilds what has landed or
   reads a solved problem as current (§2).
2. **Draws the boundary as a file-by-file table** — stays Swift, moves to Rust,
   deleted (§4).
3. **Orders the work into one list with gates that run** (§6), and says where it
   disagrees with a source RFC (§7).

**Two ordering claims are normative here and supersede their sources:**

- **This RFC supersedes device architecture §8's migration ordering.** §8 was
  written before the daemon shipped in the bundle, before `Checkout`, and before
  the git read tier; its steps 5–12 no longer describe a runnable sequence. §8's
  *invariants* stand; its *order* does not. Where §8 numbers a step, §6 cites it
  and says where it now sits. The one piece of §8's numbering worth keeping is
  its 4a/4b/4c split of the connection work, which §6 Stage 4 adopts verbatim.
- **This RFC supersedes `20260818-one-workspace-source.md` §5's stage order**, for the
  reason its own codex review gave (§7.3).

The deciding rule is unchanged, from device architecture §4.1: *would two people
watching this session from two different machines expect the same answer?* Yes →
Rust. No → Swift.

---

## 1. The invariants this plan runs under

Restated only so a stage cannot be read as licence to break one. All are
inherited; none is new here.

1. **Anti-100×** — byte delivery never blocks on a host-side VT parse. The
   foreground sampler is a two-second poll on the session actor for exactly this
   reason (`session.rs:1501-1509`), not a read per frame.
2. **State sync at boundaries only** — snapshots on attach, resize and resync.
   `grid_diff` stays opt-in.
3. **Never embed SSH or crypto.** System OpenSSH, the user's `~/.ssh/config`.
4. **One protocol, versioned and transport-agnostic.** A second protocol for the
   phone is a violation, which is why the companion wire is a debt (§8) and not
   a design.
5. **No nested window manager in the host.** One PTY per session.
6. **Single writer, many readers.**
7. **The host describes state; it never decides how that state looks**
   (device arch §4). The `grid_diff` refusal at `TermiodClient.swift:27` and the
   `S`-payload `palette: false` fix are the same rule twice.

---

## 2. Ground truth — measured 2026-08-22 at `c69c022`

The first revision of this document was cut at `7fedc72`. Thirteen commits have
landed under `termiod/` since, and they move three of its eight stages. What
follows replaces §1 of that revision wholesale.

> **Restamp, 2026-08-31.** The tree outran this section within hours of the
> 2026-08-22 stamp, and the doc went nine days without recording it. What is
> true now:
>
> - **Stage 2 is done.** `feat/termiod-session-facts` merged as PR #400 the
>   same afternoon (2026-08-22T14:46Z); all four of its gates closed —
>   `termiod.yml` has the ubuntu-24.04-arm job, the wire-order integration
>   test exists (`TermiodWireOrderIntegrationTests.swift`),
>   `Tombstone::from_info` carries `child_executable_replaced`
>   (`tombstone.rs:123`), and `displayLabel` reads `foregroundArgv` first
>   (`TermiodProtocol.swift:966-977`).
> - **Stages 7 and 8 collapsed into one step, and the soak was served
>   retroactively.** `a8b15bd` (2026-08-22, two hours after PR #400) deleted
>   `PTYProcess.swift` and every `TERMIO_TERMIOD` branch without the
>   flag-default-on release Stage 7 specified. The sequencing risk was taken,
>   not mitigated — and then paid off empirically: the daemon-only backend
>   shipped in every tag from v0.41.0 onward with no rollback. Stage 8's greps
>   pass on main today.
> - **Stage 6 is done.** `grep -rn 'PTYProcess' Sources/termio/Companion/` → 0;
>   `PTYBridge` no longer exists (PR #404 and follow-ups #490, #495, #517).
> - **Stage 5** items 2 and 3 are done differently than written: Linux systemd
>   `--user` supervision landed inside PR #522 (`a1a8cdc`), and PR #530 made
>   termiod own the unit; `feat/termiod-remote-install` was superseded by the
>   reconcile loop (PRs #499, #522, #543) and deleted. Item 1 (local launchctl
>   supervision) is still open.
> - **Stage 3** is half done: `fs.search` shipped and is consumed
>   (`TermiodFiles.swift:559-644`). The daemon's `git.diff` shipped long ago
>   (`d38f50c`, §2 table below); what is untouched is its Swift consumer —
>   `grep -rn '"git\.' Sources/` → 0.
> - **Stage 10 is pulled forward, starting 2026-08-31.** Its gate was never
>   "Stages 3–9 finished"; it was the reason behind the ordering — do not move
>   the CLI while two session backends exist. That condition has been met since
>   `a8b15bd`. The still-open stages (3's git half, 4b/4c, 5 item 1, 9) are
>   orthogonal to CLI verbs and continue independently. Stage 10's own gates —
>   one-path Stage 6's criteria, plus `20260831-docker-dockerd-lessons.md`
>   §1.3's additions — are unchanged.

### 2.1 Landed since the last stamp

| Commit | What it changes for this plan |
| --- | --- |
| `d38f50c feat(termiod): serve the git read tier from the device` | `git.log`, `git.show`, `git.branches` beside `git.diff`. `git.rs` 501 → **1,271 lines** (`run_log:374`, `run_show:426`, `run_branches:503`); `protocol.rs:611-642` carries the requests, `:770-811` the replies. Every verb runs the box's own git with `--no-optional-locks`. **This is remote-git-plane §5 Stage 1, minus `git.blame`** |
| `ab104f3 test(termiod): cover the git read tier over the wire` | the read tier is tested at the protocol boundary, not only in-process |
| `26a5dcb` + `c4934c2` (`feat/rust-foreground`, PR #366) | `foreground_pid`, `foreground_argv`, `foreground_job`, `child_cwd`, `child_executable`, `child_executable_replaced` on `SessionInfo` (`protocol.rs:1020-1045`), fed by a new `termiod/src/proc.rs` (416 lines, cfg-gated: `KERN_PROCARGS2` on macOS, `/proc/<pid>/{cmdline,cwd,exe}` on Linux) and `tcgetpgrp` on the PTY **master** (`pty.rs:252-260`). **First time a Linux host can name the agent in a session at all** |
| `1746593 fix(termiod): scope the daemon socket and launchd job by channel` | **Stage 4 items 1 and 2 of the last revision, both done.** `Termiod.socketPath(channelSuffix:environment:)` (`TermiodClient.swift:62-85`) mirrors `paths::channel_suffix()` (`paths.rs:23`); `service::label()` (`service.rs:36-40`) suffixes the launchd label, which is also the plist filename and the `gui/$UID` target |
| `ff53d19 perf(files): score the name index with frizbee's SIMD matcher` | `fs.match`'s scorer (`files.rs:348-381`), `frizbee 0.13` in `termiod/Cargo.toml` |
| `2ed6ff6 ci(termiod): run the Swift files client against a real daemon` | `.github/workflows/termiod.yml:139` runs `swift test --filter TermiodFilesIntegrationTests` against a daemon CI just built. The opt-in integration suite is no longer opt-in-and-never-run |
| `96dc2df fix(termiod): give daemon-hosted sessions the same status tap as local ones` | agent status no longer degrades when a session moves to the daemon |
| `3ded234 fix(termiod): strip the launcher's identity from spawned sessions` | `CLAUDE_CODE_*`, `TMUX`, `TERM_PROGRAM` no longer leak from whoever started the daemon into every session it spawns |

Still true from the previous stamp, re-verified today: `Checkout` is the shipped
`(device, root)` reference (`DeviceContext.swift:56-101`); the panes no longer
ask a session how it was opened; `multiplexingArguments(host:)` ships
(`TermiodClient.swift:233`, applied at `:406`); the daemon builds universal,
`lipo`s with a failing arch check, signs inside the outer seal, and resolves out
of `Bundle.main` (`daemonBinaryPath()`, `:119`).

### 2.2 Stage-1 gates, re-run today

```
grep -rn 'SFTPClient\|SSHFileSystemProvider\|SSHMux\|SSHProviderError\|sftpAlias' Sources/ Tests/ | wc -l   → 0
grep -rc 'op = "fs_list"' Sources/                                                                          → 1
grep -rn 'PTYProcess(' Sources/ | wc -l                                                                     → 1
grep -rn 'TermiodConnection' Sources/ | wc -l                                                               → 0
```

(Restamp 2026-08-31: the `PTYProcess(` row is now 0 — the constructor went
with `a8b15bd`. The others are unchanged.)

`FileBrowserView.swift:77-84` now has exactly two branches plus an honest empty
state: `RemoteFileTreeView` for any checkout with a root on another device, the
`unavailable(pane:on:)` state when the device has no root to give, and the local
tree. Stage 1 is closed.

### 2.3 The three gaps this restamp exists to record

Stages 5 and 6 of the last revision were **half-landed in Rust and unreached from
Swift**. All three gaps below now have an implementation, **written, reviewed,
and committed together on `feat/termiod-session-facts`, but unmerged** (§2.4) —
they are recorded here as the problem statement Stage 2 is answering, not as
open work. Where an answer is only partial, the gate that remains is named in
Stage 2.

**(a) Swift never decodes the foreground fields.**
`Termiod.SessionInformation` (`TermiodClient.swift:780-819`) decodes eleven keys
— `id, name, pid, alive, cwd, command, status, agentId, title, createdUnix,
attachedClients` — and **none** of the six the daemon now sends. The consequence
is visible: `displayLabel` still falls back to `programName(in: command)`
(`:838-849`), which splits the login-shell wrapper apart with string rules to
guess what is running. That heuristic is precisely what a kernel read exists to
replace, and it is still what the sidebar shows.

**Mostly answered.** The decode is built — all six fields, every one optional so
"the device said no" stays distinct from "the device did not say". `displayLabel`
is **not** rewired and still reaches the command-string guess for a roster-only
row, which is a Stage 2 gate.

**(b) `child_executable_replaced` is computed at exit and then dropped.**
`Session::info()` deliberately re-checks the pinned inode rather than caching it,
with a comment saying why: *"the record that matters most is the one built on the
exit path"* (`session.rs:366-379`). The exit path does call it — `session.rs:1587`
builds an `info` with `alive: false` for the tombstone. But:

- `Event::SessionExited` carries `{ session, status }` and nothing else
  (`protocol.rs:924-927`), so an attached client learns the session ended and
  never learns why the binary moved.
- `Tombstone::from_info` copies eleven fields and not this one
  (`tombstone.rs:96-108`), so the durable record drops it too.

"The agent updated itself and quit" is therefore computed correctly at the one
moment it matters and cannot reach any client by either route. This is a
delivery gap, not a mechanism gap — `proc::ExecutableIdentity::was_replaced()`
is right and tested (`proc.rs:44-58`, `notices_a_replaced_executable`).

**Half answered** at the stamp; closed since. `Tombstone::from_info` dropped
the field then, so a client that was not attached when the session died could
not learn it. It carries the field now (`tombstone.rs:123`) — the gate closed
with the rest of Stage 2 (§2 restamp).

**(c) Linux has no live-process-group-member scan.**
`sample_foreground` reads argv straight off the pgid
(`session.rs:389-410`), resting on the comment *"the foreground group leader's
pid **is** the pgid"*. That holds while the leader is alive. It stops holding in
the ordinary pipeline case — `foo | bar` puts both in a group named after `foo`,
and when `foo` exits first the group still owns the tty. `/proc/<pgid>/cmdline`
is then gone, `process_arguments` returns `None`, and the session reports
`foreground_job: true` with no argv: the client knows a job is running and
cannot name it. `grep -rn 'pgrp' termiod/src/` finds only `tcgetpgrp` — nothing
scans `/proc/*/stat` field 5 for a live member of the group, and nothing calls
libproc's `proc_listpgrppids` on macOS, though both mechanisms exist. The fix is
per-platform and belongs with the rest of `proc.rs`'s cfg-gating.

**Answered on both targets** (Stage 2), with the macOS path additionally
re-checking `pbi_pgid` per candidate so a recycled pid cannot be reported. The
Linux path had never been compiled or run at the stamp; the
`ubuntu-24.04-arm` job closed that gate with the rest of Stage 2 (§2
restamp).

### 2.4 Unmerged branches that bear on this plan

(Restamp 2026-08-31: the two `feat/termiod-session-facts` rows merged as
PR #400 the same afternoon this table was written; `feat/termiod-remote-install`
was superseded by the reconcile loop and deleted. Only `feat/termiod-wss` is
still an unmerged branch; `feat/foreground-parity` remains a dead worktree.
The rows stand as the record of what was measured.)

| Branch | Size | Standing |
| --- | --- | --- |
| `feat/termiod-remote-install` (`a497c00`) | 7 files, +732/−3 | **Answers open question 2 of the last revision.** Settings ▸ Machines reports what a box has and installs the slice this app carries; freshness is a digest, not a version string; the upload lands on a temp name and is moved only after `chmod`. Ships `TermiodInstaller.swift` (335) + 155 lines of tests, a `release.yml` artifact step, and `web/landing/public/install.sh`. Folded into Stage 5 |
| `feat/termiod-wss` (5 commits) | 69 files, +18,791/−4 | A third client and a transport. Adds **zero** protocol verbs and touches **zero** Swift. **Its merge risk is no longer near zero** — `git log --oneline main --not feat/termiod-wss -- termiod/` is now **13 commits**, including `d38f50c`, `c4934c2` and `1746593`, so it needs a rebase across `protocol.rs`, `daemon.rs`, `git.rs` and `session.rs` rather than the byte-identical merge the last stamp described. Deferred, §8 |
| `feat/termiod-session-facts` (`f4d8903`, `4f0e7da`) | 4 files · **+985/−62** | **Stage 2's host half, implemented and reviewed.** `proc.rs` +595, `session.rs` +328, `protocol.rs` +117, `daemon.rs` +7. The second commit adapts the new tests to `c69c022`'s graceful-shutdown API. **101 tests pass.** |
| `feat/termiod-session-facts` (`96c73ad`) | 6 files · **+856/−59** | **Stage 2's client half, implemented and reviewed.** `TermiodClient.swift` +181, `TermioStore+Termiod.swift` +135, `TermioStore+TerminalSurface.swift` +95, `TermioStore+ProjectActions.swift` +38, and 28 new cases across `TermiodEventTests` (+179) and `TermiodStatusTests` (+287). **483 tests pass.** |
| `feat/foreground-parity` | 0 commits · +42 uncommitted, plus an untracked `TermioStore+SessionFacts.swift` | **An earlier, superseded attempt at the same client half.** It decodes `foregroundJob` as a non-optional `Bool` with `?? false`, which erases "the device did not answer" from the type — the distinction the skew rule rests on — and it carries no tests. **Do not merge it alongside the pair above**; harvest `SessionFacts`'s single-answer framing if anything, and drop the rest. |

The two completion worktrees were committed separately, then cherry-picked onto
`feat/termiod-session-facts` at `c69c022` with this RFC. That integration branch
was the only branch to review or merge for Stage 2 (merged as PR #400).
`feat/foreground-parity` remains a superseded, uncommitted worktree and must
not be combined with it.

---

## 3. Vocabulary — Workspace is not Project, and only one of them is the device's

The word "workspace" named three different objects across these documents, and
every argument about *where workspaces live* was an argument between the
definitions. `20260819-device-workspace-project.md` settled it, and this plan
uses the settled terms exclusively:

```
Device        a machine, identified by host_id, reached by ≥1 ~/.ssh/config alias
  └ Workspace a named scope in the sidebar; holds projects and loose sessions
      └ Project    a checkout: a directory root on that device
          └ Session a PTY in that device's termiod
```

Two ownership claims, and they point in different directions on purpose:

- **Workspace is a client concern, and stays viewer-owned for now.** It is the
  user's arrangement of their own work — the same class of thing as split
  layout and session naming, which §4.1 already keeps in Swift. It lives in the
  Mac's `state.json`, and #345 removed machine-scoped navigation deliberately:
  you switch workspaces, never machines. Every workspace *names* a device
  (`20260819` §2), which is a hierarchy claim, not a storage one.
- **Project and Checkout are device-owned facts, and the registry that
  enumerates them is device work.** A directory root either exists on that box
  or does not; two viewers must agree. `Checkout` (`DeviceContext.swift:56-101`)
  is already the client-side spelling of `(device, root)` with `host_id`-first
  identity. What is missing is the device's own answer to *what projects are
  here* — device arch §8.11's registry.

The gap is one field wide and worth stating precisely, because it looks larger
than it is: `WorkstreamSpec` already carries `project` (`protocol.rs:390`), the
daemon stores it (`session.rs:306`), and `Session::info()` reads back only
`agent_id` (`:358`). **A client can write a session's project and can never read
it.** Closing that is the first inch of the registry, not a new plane.

Deliberately deferred, per `20260819` §5: moving workspace *authority* to the
device. That decision belongs with direct-attach (§8), because its whole
justification is a phone talking to a Linux box with no Mac in the path.
Adopting the hierarchy now costs nothing later — every workspace already names
its device.

Retired vocabulary, do not reintroduce: "workspace" meaning a directory root;
"workspace fallback" / `isDeviceFallback`; "local project" versus "remote
project".

---

## 4. The boundary

### 4.1 Stays Swift — the viewer, and the stopping line

These fail the two-observers test outright, or are macOS-coupled. Nothing in
this plan touches them, and a future stage that proposes to must argue against
this list rather than around it.

| Area | Lines | Why it stays |
| --- | --- | --- |
| libghostty surface, `TerminalPane`, `SplitTree`, every `*View` | `Terminal/` 6,218 · `Sidebar/` 1,971 · `Info/` 5,813 | Rendering, layout and panes are client concerns — invariant #5 |
| ~~`OSCProgressScanner`~~ · ~~`AgentStatusRules`~~ | — | **Struck 2026-08-31.** They moved, and the argument is in [`20260831-companion-second-protocol-retires.md`](20260831-companion-second-protocol-retires.md) §3: identical bytes do not produce identical verdicts, because the rules also read *this* client's scroll, keystrokes, tick history and selection. What stays is the presentation half below |
| `statusDescription`, the done-vs-idle call, argv → glyph | `TermioStore+AgentStatus.swift` | The device sends an enum and a source; the sentence, the dot and "has this person seen it" are the viewer's — §4 |
| Theme, palette, fonts, keybindings | `Theme/` 527 · `Keybindings/` 628 | The `grid_diff` refusal (`TermiodClient.swift:27`) is the same rule: the host must never resolve a colour |
| `TaskNotifications`, `MenuBarController`, keychain reads, `NSWorkspace`, Quick Look | `App/` 4,320 · `Companion/Usage/` | This Mac's Notification Center is this Mac's |
| Encoding a human keypress | `Terminal/Ghostty/` | Needs an `NSEvent` and ghostty's key encoder — invariant #5 wearing a keyboard |
| **Workspace grouping**, session naming, `termio://session/<uuid>` links | `TermioStore/` | §3. The arrangement is the user's, not the device's |
| `focus`, `notify` CLI verbs | `TermioStore+SessionControl.swift:44-53` | Name *this* window and *this* Mac |
| argv → agent mapping | client-side | The daemon reports argv; which glyph that becomes is presentation |

### 4.2 Moves to Rust

Ordered by how ready the daemon already is. "Daemon state" is measured today.

| Responsibility | Swift today | Daemon state | Stage |
| --- | --- | --- | --- |
| Directory listing, file read | — (deleted) | **Shipped and consumed** | **1 — done** |
| Foreground job / argv / cwd / executable identity | `PTYProcess.swift:864-930` (deleted in `a8b15bd`) | **Shipped** (`proc.rs`, `pty.rs:258`); group-member resolution and the client decode merged as PR #400 | **2 — done** |
| Content search | `ContentSearch.swift` 144 (`git grep` via `Process`) | **Shipped**, streamed + cancellable | 3 |
| Git diff for one path | `GitService.diffText` | **Shipped** (`git.diff`) | 3 |
| Filename fuzzy finder | local walk | **Shipped** (`fs.match`, frizbee scorer); needs a subscription for coverage | 9 (gated on 4b) |
| Filesystem change notification | `FileTreeWatcher.swift` 139 (FSEvents), no remote equivalent | **Shipped** as the `fs:` resource | 9 (gated on 4b) |
| Git status | `GitService.changes` → `/usr/bin/git` | **Shipped** as the `git:` resource | 9 (gated on 4b) |
| Git history, commit contents, branch list | `GitService.log/commitChanges/branchCompare` | **Shipped** (`git.log`, `git.show`, `git.branches`) | 9 |
| Blame | absent both sides | **Absent** | 9 (or never — §9.5) |
| Worktree enumeration | `WorktreeService.swift` 72 | **Absent** | 9 |
| `.gitignore`, remote/PR URLs, clone info, stall fingerprint | `GitService.swift:565-984` | **Absent** | 9 |
| Discard, stage, commit, stash, branch ops | `GitService.discard` + absent | **Absent** — new scope | 11 |
| Fetch / pull / push, askpass | absent | **Absent** — new scope | 11 |
| Session roster, `read`, `send`, `watch`, `spawn`, `close` | `TermioStore+SessionControl.swift` 1,040 | Verbs exist; the CLI talks to the Swift socket | 10 |
| Agent hook sink | `HookListener.swift` 944, `agent-status.sock` on this Mac | `set_status` exists; nothing routes a hook into it | 10 |
| Agent status: screen rules, `OSC 0/2` title, `OSC 9;4` progress, streak promotion, stale sweep, stall probe | `TermioStore+AgentStatus.swift` 793 (deleted) | **Shipped** (`session/status.rs`), published as the `status:` resource | **done — retirement RFC Stage 1** |
| PTY ownership | `PTYProcess.swift` 996 (deleted in `a8b15bd`) | **Shipped** (`pty.rs`) | **8 — done** |

### 4.3 Deleted outright

| File | Lines | Stage | Gate |
| --- | --- | --- | --- |
| `SFTPClient.swift`, `SSHFileSystemProvider.swift`, `SSHFileSystemProviderTests.swift`, `Checkout.sftpAlias`, `SSHMux` | 1,409 + ~120 | 1 | **done** — the symbol grep in §2.2 is 0 |
| `PTYBridge`'s dependence on `PTYProcess` | — | 6 | `grep -rn 'PTYProcess' Sources/termio/Companion/` → 0 |
| `Termiod.isEnabled` (`TermiodClient.swift:46`) and every branch on it | — | 8 | `grep -rn 'TERMIO_TERMIOD\b' Sources/ \| wc -l` → 0 |
| `PTYProcess(` construction (`TermioStore+TerminalSurface.swift:253`) and `PTYProcess.swift` | 996 | 8 | `grep -rn 'PTYProcess(' Sources/ \| wc -l` → 0 |
| `ContentSearch.swift`, `FileTreeWatcher.swift` | 283 | 9 | their symbol grep → 0 |

`RemoteFileTree.swift` (507 lines) is **not** deleted — settled in the last
revision and unchanged. Only the provider behind it was SFTP-shaped, and it was
four methods wide. The tree's lazy-load re-entrancy, expansion-state identity
and preview-race guards are correct; rewriting the view would be new code where
the deletion target was the transport.

---

## 5. The blocker, narrowed

`withControlChannel` (`TermiodClient.swift:1155`) is one-shot: it opens a
`Transport`, `defer`s its close, and nothing can outlive the closure. Re-verified
today; `grep -rn 'TermiodConnection' Sources/` → 0.

**What it does and does not gate:**

- **Not gated** — `fs.list`, `fs.read`, `fs.search`, `git.diff`, `git.log`,
  `git.show`, `git.branches`. Each is one request and its replies on one
  channel. `fs.search` streams, but the stream ends with `fs_searched` inside
  the same call.
- **Gated** — `subscribe_resource` for `fs:` and `git:`, and therefore live file
  watching, the git Changes pane, and `fs.match` coverage. A subscription's
  whole value is that it outlives the request.
- **Gated** — the companion's exit fan-out (§6 Stage 6). `TermiodSessionLink.onExit`
  is one closure held by `attachTermiodLink` (`TermioStore+Termiod.swift:119`);
  the observer registry belongs on a connection, not on a transport.

The cost the blocker does not name: each one-shot call over SSH is a full connect
plus hello. Locally 0.2 ms; remotely 26–33 ms with a warm ControlMaster and
230–300 ms without. A tree that expands one directory per click is inside that
budget; a search that re-issues per keystroke is not. Stage 3's gate measures it.

`20260818-remote-git-plane.md` §8.1 names a *second* prerequisite — the workspace
reference — and that one is resolved (`Checkout`). §8.1 should be struck; §8.2
and §8.3 stand.

---

## 6. Stages

Each is independently shippable and carries a gate that runs. **This list
supersedes device architecture §8's ordering** (§0).

The shape of the reorder, against the previous revision: foreground parity moves
from 5 to **2** because Rust already shipped its half — and the rest of it is now
written, reviewed and waiting on four gates (§2.4, Stage 2); supervision moves from 4
to **5** and absorbs the remote-install branch; and **companion decoupling, the
default-on soak, and deleting the local PTY fork (6, 7, 8) now come before the
CLI move and before any git expansion.** The reason is one-path §5's own
rollback note: Stage 8 is the only step that is hard to revert, its mitigation is
sequencing rather than a switch, and every stage that runs *after* the flag is
deleted is a stage that would otherwise have to be built twice — once for each
side of the fork. Moving the CLI while two session backends exist is exactly that
double build.

### Stage 1 — the Files pane reads a device through `fs.*`; SFTP is deleted — **done**

Landed as `68f5006` + `8e106ea`: **+513 / −2,030** across 14 files, of which 141
additions are integration tests. Gates re-run in §2.2 and all clean. CI now runs
the Swift client against a real daemon (`termiod.yml:139`), which closes the
"opt-in and therefore never run" gap the original stage carried.

One verification remains open and is recorded as open, not claimed: the device
branch of the pane has not been seen on screen against a second machine running
`termiod`.

### Stage 2 — foreground parity: the client half — **done**

Rust's first half shipped in `c4934c2`; the rest merged as **PR #400**
(2026-08-22), and all four gates below closed since (§2 restamp). The section
is kept as written because it records the decisions, two of which contradict
one-path §3.2 and won.

Nothing below is a proposal. It is the shape the implementation settled on,
recorded because two of the decisions contradict what `20260817-one-path-local-through-termiod.md`
§3.2 specified, and a later reader comparing the two needs to know which won.

#### The wire, as built

Both changes are additive within `proto:1` and both reuse events that already
existed. **No `foreground_changed` event exists, and none is needed** — see §7.9.

```
E { ev: "roster", session, action: "updated", info: SessionInfo }   # whole row, on change
E { ev: "session_exited", session, status, info: SessionInfo? }     # + final row
```

- **`E roster` carries whole `SessionInfo` updates.** `emit_roster()` already
  sent `{session, action, info}` with the complete row; the foreground poll now
  calls it on change. A client never merges deltas, so there is no partial-update
  ordering problem to get wrong, and no second event shape to version.
- **`E session_exited` gains an optional final `info`** (`Option<Box<SessionInfo>>`).
  It is sampled once, after the reap, and the *same* record feeds both the event
  and the tombstone — deliberately not sampled twice, because
  `child_executable_replaced` is a fresh disk read every time it is asked and an
  agent that replaced its binary between two reads is precisely the case both
  consumers exist for. Absent from an old daemon; a client that finds it absent
  keeps what it last read from `list`, which is today's behaviour. Round-trip and
  old-payload-decodes tests both exist.

#### Close confirmation reads the cached push, on purpose

`closeConfirmationReason` answers from the last roster push —
a sample up to one `FOREGROUND_POLL` (**2 s**) old — and **does not** ask `list`.
This inverts one-path §3.2's instruction (§7.10). The reason is mechanical:
`Session::info()` reads the `self.foreground` cache, so a `list` round trip
returns the same sample built from the same poll. **It is not fresher.** It
would cost 216–292 ms on the main thread over SSH to learn nothing.

An in-process PTY still wins outright when one exists — it is asked `tcgetpgrp`
at the instant of the question, so its `false` is a genuinely fresher no
(`TermioStore.foregroundJob(reportedLocally:reportedByDevice:)`). Only a session
this app does not host falls through to the device's cache.

The staleness is accepted because it is bounded in both directions, and the two
directions cost differently:

- **False positive** — the job finished within the last poll and the user is
  asked about a command that already ended. Cost: one dismissed dialog. This is
  the safe direction to be wrong in.
- **False negative** — a job started within the last poll and the close goes
  through unasked. Cost: exactly the shipped no-confirm rule, which is what an
  absent field already means.

Which is why only an explicit `true` confirms. `nil` is nobody answering and
must never be read as "unknown, so confirm" — that would tax every close on the
sessions the shipped rule deliberately exempts (`20260814-remote-to-device.decisions.md` §2).

#### Resolving the group, per platform

`tcgetpgrp` names a *group*; every argv lookup wants a *pid*. The two agree while
the leader lives, and part in a pipeline the moment it does not — `find . | grep foo`
after `find` finishes leaves `grep` holding the terminal with a zero-length
`/proc/<pgid>/cmdline`. tmux scans for a live member (`osdep-linux.c`); so does
this, behind one `proc::foreground_member(pgid)` with a per-target body.

- **macOS** — `proc_listpgrppids` enumerates the group, then each candidate is
  read back through `proc_pidinfo(PROC_PIDTBSDINFO)` for its state **and a
  re-check that `pbi_pgid` still matches the group we were asked about**. That
  recheck is not redundant with having enumerated the group: between `tcgetpgrp`
  naming it and this running, a pid can be recycled into something else, and a
  member whose group no longer matches is a different process wearing the same
  number.
- **Linux** — `/proc/<pgid>/stat` first, which answers on nearly every sample for
  one `stat` read and no walk. Only when the leader cannot answer does it walk
  `/proc`, reading one `stat` per process and **no `cmdline` at all**; argv is
  resolved afterwards, in preference order, stopping at the first process that
  answers.
- **Selection is leader-first, then ascending pid** — arbitrary but *stable*, so
  a wide pipeline does not flap between two survivors and push a roster event
  every poll for no new information. Zombies and dead states are filtered.
- **`foreground_job` is derived from the group, not from the resolved pid.** A
  pipeline whose leader exited is still a running job; keying it on a member that
  could not be read would say the opposite at the worst moment.

#### The expensive half is off the session actor

The poll now splits along what it costs to learn. `tcgetpgrp` and the job flag
stay on the actor — cheap, and the close confirmation needs them current. Argv,
cwd, the executable pin and the group walk are dispatched to
`spawn_blocking` and applied later, because that actor also runs the PTY read
and the fan-out, and a process-table walk there is time the byte path spends
waiting. **The anti-100× invariant is about more than the VT parse.**

Two guards make the split safe:

- **One resolution in flight per session** (`foreground_pending`). The poll is
  slower than the work; queueing would only pile up answers about groups that
  have already lost the terminal.
- **Stale-pgid rejection.** A resolution carries the `pgid` it describes, and
  `apply_foreground` drops it if the foreground moved while it was in flight.
  That is not a stale version of the truth — it is the answer to a different
  question. When the group changes, the cached pid and argv are cleared rather
  than carried, so the gap is honest until the next resolution fills it.

#### Remaining gates — all four closed by 2026-08-31 (kept as the record of what they were)

- **Linux `cfg` compilation and runtime.** The `/proc` path has never been
  compiled or run; it waits on `termiod.yml`'s ubuntu-24.04-arm job. Behaviourally:
  run `sleep 60 | cat` in a session, and after the leader exits `foreground_job`
  is true **and** `foreground_argv` is non-empty.
- **Combined wire-order integration coverage is absent.** Each half is tested
  against its own fixtures; nothing exercises a real daemon pushing a roster
  update and then an exit event to a real Swift client, in order. The
  `TermiodFilesIntegrationTests` pattern (`termiod.yml:139`) is the place for it.
- **`child_executable_replaced` is still not on `Tombstone`.** The exit *event*
  carries it; `Tombstone::from_info` (`tombstone.rs:96-108`) does not, so a
  client that was not attached when the session died cannot learn it. §2.3(b).
- **`displayLabel` still falls back to `programName(in: command)`** for
  roster-only rows the app has never attached to — which is exactly the row that
  has no other source of truth. The decode is in place; the consumer is not
  rewired.

Non-blocking, and explicitly **not** a gate: Linux reads argv twice on the walk
path — once as the `has_argv` predicate that selects the member, once again in
`process_arguments`. Returning the argv from the probe would halve it. That is an
optimization on the rare branch, not a correctness issue, and it should not hold
the stage.

### Stage 3 — Search and the diff view read a device

`fs.search` (streamed, cancellable) behind `FileSearchView`/`ContentSearch`, and
`git.diff` behind the TextKit diff overlay. Still one channel per request; still
not blocked.

**Gates:** ⇧⌘F on a VPS session returns hits with correct paths and line numbers;
cancelling mid-stream produces `fs_searched {canceled: true}`; a diff for a
device path renders in the existing overlay. **Cold-expand latency over a warm
ControlMaster is recorded** — this is the measurement open question 1 of the last
revision asked for, and it decides nothing else in this list, so take it here.

### Stage 4 — the connection is an object

Device architecture §8.4's split, adopted verbatim because the sub-steps have
genuinely different shapes and only one of them is hard.

**4a — the argument list.** `multiplexingArguments(host:)` already ships
`ControlMaster`, `ControlPersist` and a length-capped `ControlPath`, and refuses
to override a user's `ControlMaster no` (`TermiodClient.swift:233-236`, applied
at `:406`). What is missing is `BatchMode` and `ConnectTimeout`, which every
other ssh call site in the app sets and this one does not — so an unloaded key
prompts onto an unread stderr and the attach hangs with no error. **A one-line
change with a real failure behind it.**

*Gate:* attach to a host with a passphrase-protected key and no agent: a named
error inside `ConnectTimeout`, never a hang.

**4b — `TermiodConnection`.** One per device, owning the transport, its health
and reconnect. `TermiodSessionLink` becomes a client of it rather than a
transport owner; `withControlChannel` becomes a channel *on* it rather than a
process. `handleStreamEnd` (`TermiodClient.swift:1867-1873`) stops calling
`deliverExitLocked` — **a transport failure is not a process exit**, and today
they are the same code path. The exit observer registry Stage 6 needs lands here.

*Gates:*
- Three panes on one SSH device: `pgrep -lf 'ssh .*<alias>'` shows **one** ssh.
- `launchctl kickstart -k` the daemon with three local panes open: each pane
  shows a state named `daemon_lost`, distinct from `exited`, and `termiod
  tombstones` lists all three with no invented exit status. **Not** "history
  intact" — sessions do not survive a daemon restart and by decision never will
  (`tombstone.rs`, burial loop).
- Pull the network on an attached device: panes degrade, and nothing reports an
  exit status the child never produced.

**4c — channel ids in the framing.** An additive `proto` bump so the four planes
genuinely share one pipe rather than one pipe each. Sequenced last of the three
because 4b keeps the durability promise on its own; 4c is what makes the promise
cheap.

*Gate:* a session attachment, an `fs:` subscription and an upload run
concurrently over one transport, and the upload's chunking does not stall the
byte path.

### Stage 5 — the daemon is supervised, on both platforms

Items 1 and 2 of the *last revision's* list landed in `1746593`; the three
numbered below are what remained when this was written. Of those, items 2 and
3 are done as of 2026-08-31 (systemd inside PR #522, unit ownership in
PR #530; the reconcile loop of PRs #499/#522/#543 superseding
`feat/termiod-remote-install`). Item 1 — nothing calls `launchctl` on the
local Mac — is the one still open. See the §2 restamp.

1. **The app installs or repairs the launchd job on launch.** Nothing calls
   `launchctl` — `grep -rn 'launchctl' Sources/` → **0**. Until it does,
   `KeepAlive` is a mitigation that does not exist and `spawnDaemon` is the only
   path. `service::install()` (`service.rs:175-201`) already writes the
   channel-scoped plist and boots the label out first; it can only plist
   `std::env::current_exe()`, so the app must invoke the bundled daemon's own
   `service install` rather than reimplement it in Swift.
2. **Linux: a systemd `--user` unit plus `loginctl enable-linger`.**
   `service.rs:161-165` currently *refuses* on Linux with an error telling the
   user to do it by hand. That refusal is honest and is not shippable as the
   answer.
3. **Merge `feat/termiod-remote-install`** (§2.4), which is what makes 1 and 2
   reachable for a box the user has not touched: Settings ▸ Machines probes with
   `--version` rather than `test -x` (executing the binary is what proves it
   matches the CPU and links against a libc that exists), compares a digest
   rather than a crate version, and moves the upload into place only after
   `chmod`. This is open question 2 of the last revision, answered.

Plus the standing decision from one-path §5.2 item 9: what a Sparkle update does
to a running daemon. The recommendation there is a compatibility window; take it
or replace it, but do not ship Stage 7 without an answer.

**Gates:** two plists, one per channel, both `RunAtLoad` + `KeepAlive`;
`kill -9` the daemon and it respawns; `lipo -archs` on the shipped binary prints
both slices (true today); a fresh Linux box reachable by alias goes from nothing
installed to an open session without a terminal, and survives a logout.

### Stage 6 — the companion stops depending on `PTYProcess` — **done** (PR #404; gate grep → 0)

one-path §5 Stage 4, and the biggest single stage here. **Not** "extract a
protocol both types satisfy": `PTYBridge` uses thirteen `PTYProcess` members
(`CompanionServer.swift:985-1080`), and the ones without a daemon counterpart are
each a decision:

- **`modeResyncPreamble()` / `isAlternateScreenActive`.** `alt_screen` *is* on
  the wire (`protocol.rs:174`, carried in both the `S` snapshot and the `G`
  grid), so the alt-screen test has a counterpart. The mode **preamble** — mouse
  reporting, the modes a skipped replay never carries — does not. The `S`
  snapshot is the natural home; say so before writing it.
- **Byte-capped replay.** The phone needs at most 128 KiB of the ring, because
  the whole ring reflowed at a narrow grid is the allocator-panic trigger
  recorded at `CompanionServer.swift:1007-1010`. Either the wire grows a replay
  bound on `attach`, or the client truncates what it receives. The second wastes
  bandwidth on exactly the link that has least to spare. **Decide it here, not
  in code review.**
- **`jiggleResize()`.** A resize to identical dimensions is a daemon no-op, so
  "make the child redraw" has no verb. The honest options are a client-side wipe
  plus a snapshot request, or accepting a stale frame until the next output. Do
  **not** invent a host-side redraw op without arguing it — the host does not
  decide presentation (invariant #7).
- **Ownership.** `claimCompanionOwnership` / `claimHostOwnership` are an explicit
  claim; the daemon's writer token is newest-interactive-wins
  (`recompute_writer`, `session.rs`). Reconciling them is the piece most likely
  to change phone behaviour visibly.

Exit fan-out is inherited from 4b rather than solved here.

**Gates:** one-path §5 Stage 4's criteria, unchanged, plus
`grep -rn 'PTYProcess' Sources/termio/Companion/` → 0. Verified on a real device,
not the simulator.

### Stage 7 — default on, for one full release — **collapsed into Stage 8; soak served retroactively** (§2 restamp)

Ship with `Termiod.isEnabled` defaulting to **true** and `TERMIO_TERMIOD=0`
able to force it off. Then run one release and change nothing else in this list.

This is not a formality. Stages 1–6 each removed a reason the flag existed;
Stage 8 removes the alternative, and its rollback is a release rollback rather
than a runtime switch. The soak is the only thing standing between that and a
user with no way back. **Task notifications never fire from a dev build**, so the
notification path in particular has to be exercised on the release channel here
or it is not exercised at all.

**Gate:** one shipped release on the release channel with the daemon backend on
by default and no rollback. Concretely: local sessions survive an app quit and
relaunch reattaching to the same pid; the companion, agent status, and task
notifications behave as they did with the flag off.

### Stage 8 — delete the local PTY fork — **done** (`a8b15bd`, 2026-08-22; gates pass on main)

Only now. Remove `Termiod.isEnabled` and every branch on it, the in-process
`PTYProcess` construction (`TermioStore+TerminalSurface.swift:253`), the flag-off
alerts (`TermioStore+Termiod.swift:861-865`, `TermioStore+TerminalSurface.swift:572`),
the `ptyProcesses` half of `terminateAllSessions`, and `PTYProcess.swift` itself.

**Gates:** one-path §5 Stage 5's criteria verbatim —
`grep -rn 'TERMIO_TERMIOD\b' Sources/ | wc -l` → 0 (correctly excluding
`TERMIO_TERMIOD_BIN`); `grep -rn 'PTYProcess(' Sources/ | wc -l` → 0; `sleep 300`
in a local pane survives a quit and relaunch at the same pid; `swift test` green;
a screen-recorded pass of new terminal, new agent session, group, close with a
running job, close idle, agent self-quit.

**Rollback: a release rollback.** That is what Stage 7 buys.

### Stage 9 — the git and file panes read the device

**This stage migrates capabilities the app already has. It adds no verb the
product does not already ship**, and that boundary is what separates it from
Stage 11.

Gated on 4b for everything subscription-shaped:

- `fs:` subscription → live tree updates; delete `FileTreeWatcher.swift`.
- `git:` subscription → the Changes pane on a device.
- `fs.match` coverage → Open Quickly against a device.
- `git.log` / `git.show` / `git.branches`, already shipped in Rust and consumed
  by nobody (`grep -rn '"git\.' Sources/` → **0**) → History and Compare.
- The verbs the daemon does **not** have yet but the app does, all read-only:
  worktree enumeration (`WorktreeService.swift`), `.gitignore` pattern reads,
  remote/PR URL derivation, clone info, the stall fingerprint.

`GitService.discard` is the one mutation in today's app. It moves in **Stage 11**
with the rest of the mutation tier, not here — a discard that runs on the wrong
machine destroys work.

**Gates:** History, Compare and Changes render for a device checkout with the
same views they use locally, and every unsupported control is **hidden rather
than inert**. `touch` a file on the VPS and the tree updates without a manual
refresh. Replay inside the watcher's 300-second linger (`resource.rs:51`) is
exact; past it, `gap: true` forces a full rescan. **The watcher's budget is
bounded before this ships** — a recursive watch plus a full BFS name-index walk
over `$HOME` or a large monorepo, alive five minutes past the last subscriber, is
not obviously authorized by "the user let us read this machine" (open question 3).

### Stage 10 — the CLI moves, verb by verb — **in progress since 2026-08-31, pulled forward** (§2 restamp; gates unchanged)

one-path §7 and its Stage 6, unchanged in content and in internal order: `read`,
`send`/`answer`, `watch`, `list`, `spawn`/`run`/`close`, then
`agent report` → `set-status` plus hook installation on the device.
`scripts/termio` becomes a router; `focus` and `notify` stay in Swift (§4.1).

Now cheap, because there is one session backend to route to rather than two.

**Gates:** one-path Stage 6's criteria verbatim, including the old-shape check on
**values** — `termio sessions list --json` matched against the pre-move build for
a session that has `cd`'d out of its spawn directory, which is the case that
passes a field-identical check while `cwd` silently rots.

### Stage 11 — remote git's new scope: mutation, askpass, network

`20260818-remote-git-plane.md` §5 Stages 2–4, in its order, and **only** these — the read
tier (its Stage 1) landed in `d38f50c` and is consumed in Stage 9 above.

- **Local mutation tier**: staging, commit, discard, stash, branch ops, ignore
  writes. No network, no credentials. Commit runs the box's hooks, which is the
  point — hook output and hook failure must reach the pane rather than be
  swallowed into a generic error.
- **The askpass channel, built and tested alone**, before any verb depends on
  it: a prompt raised on the box, answered on the Mac, plus cancel and timeout.
- **Network tier**: `git.fetch`, `git.pull`, `git.push`, cancellable, with
  progress.

The prompt-answered-from-the-phone property is a *consequence* of the askpass
prompt being a typed protocol object, not extra work, and it must not be built
into the askpass stage.

**Gates:** remote-git-plane §5's per-stage gates verbatim — a failing
`pre-commit` hook shows its own output; `index.lock` contention is reported as
contention; a passphrase-protected clone completes after answering on the Mac and
a cancel produces a named error rather than a hang.

`git.blame` (remote-git-plane §5 Stage 1) is **not** scheduled: it is
editor-adjacent and termio's editor is a preview (§9.5).

---

## 7. Where this disagrees with an existing RFC

1. **Device architecture §8's ordering is superseded** (§0). Its invariants and
   its 4a/4b/4c split stand; steps 5–12 do not describe a runnable sequence any
   more. In particular §8's step 9 ("request plane, then file tree and git move")
   sits at Stage 9 here and needs no request plane — `fs.*` and `git.*` are their
   own verbs and shipped that way.

2. **`20260818-remote-git-plane.md` §8.1 is stale.** It says the workspace reference "is
   unresolved" and that the RFC "should not be implemented before it". `Checkout`
   (`DeviceContext.swift:56-101`) resolves it, with the `host_id`-first identity
   the codex review asked for. Strike §8.1; §8.2 and §8.3 stand. Its §5 Stage 1
   is done in Rust, which §8.1 would have forbidden starting.

3. **`20260818-one-workspace-source.md` §2's `ProjectLocation` should not be built.** A
   two-case enum keyed on `deviceID` is a second spelling of `KnownDevice` +
   `Checkout`, which is already in the tree, already tested
   (`InspectorCheckoutTests`, 6 tests), and already consumed by every inspector
   pane. `grep -rn ProjectLocation Sources/ Shared/` → 0, and should stay 0. The
   codex review anticipated this: it proposed `WorkspaceReference { deviceID;
   root }`, and `Checkout` *is* that struct.

4. **`20260818-one-workspace-source.md` §5's stage order is inverted**, and this document
   supersedes it. It put "delete SFTP" last, behind editing and mutations; its
   own review disagreed and was right. That deletion shipped first and removed
   1,409 lines.

5. **The brief's "delete `RemoteFileTree.swift`" is wrong.** §4.3.

6. **`20260817-one-path-local-through-termiod.md` §5.2 item 1 and
   `one-binary-and-a-daemon-that-ships.md` §1 both lead with a solved problem.**
   "A released build cannot start a daemon at all" was true when written:
   `2199f35` builds, `lipo`s, arch-checks and signs `termiod` into
   `Contents/Resources`, and `daemonBinaryPath()` resolves it. What is left is
   Stage 5, a much smaller item than either RFC prices it at.

7. **`20260817-one-path-local-through-termiod.md` Stage 2 item `4a` is partly done, not
   done.** The last revision of this document said "done"; that overstated it.
   `multiplexingArguments` ships, `BatchMode`/`ConnectTimeout` do not, and the
   missing pair is the difference between a named error and a hang. Corrected in
   Stage 4a.

8. **`one-binary-and-a-daemon-that-ships.md` §2.3 stays dead.** Two binaries, two
   names. A daemon named `termio` copied to Application Support lands byte-for-
   byte on the path `CommandLineTool.supportCopyURL` owns and that every
   installed hook names absolutely; the hook ends `2>/dev/null || true`, so
   status reporting would die silently. And a router named `termio` cannot
   dispatch to a binary named `termio`. **Do not re-propose.**

9. **`20260817-one-path-local-through-termiod.md` §3.2's `foreground_changed` event does
   not exist and should not be built.** That section specifies
   `E { ev: "foreground_changed", session, pid, argv, cwd? }` as a debounced
   push. The implementation instead reuses `E roster`, which already carried
   `{session, action, info}` with the **whole** `SessionInfo`, and adds an
   optional final `info` to `E session_exited`. Every property §3.2 argued for is
   kept — it is a push and not a poll, it never touches `fan_out`, and the host
   reports argv while the client maps it to an agent — and one problem is
   removed: a whole-row event has no partial-update ordering to get wrong and
   needs no second shape to version. **Strike the `foreground_changed` line from
   §3.2; its three rules stand.**

10. **`20260817-one-path-local-through-termiod.md` §3.2's last sentence is inverted by the
    mechanism.** It reads: *"`foreground_job` rides `list` rather than an event
    because its consumer asks once, at close time, and a stale push is worse than
    a fresh question."* The premise does not hold. `Session::info()` reads the
    `self.foreground` cache, so a `list` reply is built from **the same 2-second
    sample** the push carried — the question is not fresher, it is the same
    answer fetched again at 216–292 ms of main-thread SSH latency. The close
    confirmation therefore reads the cached push deliberately, with an
    in-process PTY overriding it whenever one exists, and both stale directions
    bounded (Stage 2). **Strike that sentence.** The skew rule it sits beside —
    an absent field preserves today's no-confirm behaviour and must never be read
    as "unknown, so confirm" — is unchanged and is load-bearing.

---

## 8. Explicitly deferred

Not "out of scope forever" — sequenced after this plan, with the reason recorded
so nobody reads the absence as an oversight.

- **Merging `feat/termiod-wss`.** Worth doing on its own terms: it proves the
  protocol is transport-agnostic (invariant #4) with a byte-identical splice, it
  is 100% additive, and it adds zero protocol verbs. It is **not** progress on
  the Swift→Rust boundary and nothing here depends on it. Two conditions before
  it lands: it needs a rebase across the thirteen `termiod/` commits it is now
  behind (§2.4), and nothing in CI runs `vitest`/`tsc`/`vite build` for
  `web/client/`. `termiod/ARCHITECTURE.md` still describes termiod as
  Unix-socket + `termiod stdio` only.
- **iOS attaching directly to a device.** Device arch §8.12. The topology is
  decided; the transport is not, and it is gated on §9.6 — how a phone reaches a
  device without embedding SSH (invariant #3). Until that is answered, the phone
  stays a client of the Mac.
- **Deleting the companion wire.** Now laddered in its own RFC,
  [`20260831-companion-second-protocol-retires.md`](20260831-companion-second-protocol-retires.md).
  It is the one place the repo contradicts
  invariant #4, and it is *not* deletable before the line above: deleting it
  first leaves the phone with nothing to speak. §5 of
  `20260819-device-workspace-project.md` establishes the cost is low when the
  time comes — `WireProtocol.swift` contains the word "workspace" zero times, and
  the whole artifact is a display prefix plus a routing id.
- **Moving workspace authority to the device.** §3. Belongs with direct-attach,
  for the same reason.
- **QUIC, discovery, `grid_diff` by default.**
- **Session survival across a daemon restart.** Decided against
  (`20260817-one-path-local-through-termiod.md` §5.2 item 7): a holder process or an
  `exec`-preserving re-exec is a supervisor design, and it reintroduces the
  failure mode the daemon exists to remove — two processes disagreeing about who
  owns a PTY. Make restarts rare and honest instead.
- **Merging `termio` and `termiod` into one binary.** §7.8.
- ~~**Moving `OSCProgressScanner` or `AgentStatusRules` to the host.**~~
  **Reversed and done**, as Stage 1 of
  [`20260831-companion-second-protocol-retires.md`](20260831-companion-second-protocol-retires.md).
  The deferral held only while the Mac was the sole viewer running the rules; a
  phone attached straight to a device ran none of them, so deferring it made the
  direct-attach path a regression rather than a step.
- **A chat / structured-event lens.** Built and reverted three times; the design
  docs record why.
- **Windows.** ConPTY has no controlling terminal and no `tcgetpgrp`. The
  foreground fields would be absent, which is the same shape as an old daemon
  that does not send them — one degrade path serves both.

---

## 9. Open questions

1. **Does the one-shot channel cost show up over SSH?** Stage 3 measures cold
   expansion over a warm ControlMaster. If it does not hold under ~50 ms, Stage 4
   moves ahead of Stage 3. *(Carried from the last revision; Stage 1 shipped
   without measuring it because the tree expands one directory per click and
   search does not.)*
2. ~~**What does a plain-`ssh` session's Files pane say, and who installs the
   daemon?**~~ **Answered** by `feat/termiod-remote-install` (§2.4), folded into
   Stage 5. The pane's honest empty state names the host; Settings ▸ Machines is
   the affordance.
3. **Does the watcher's budget need a bound before Stage 9?** Raised by the codex
   review: a recursive watch plus a full BFS name-index walk over `$HOME` or a
   large monorepo, alive five minutes past the last subscriber
   (`resource.rs:51`). Reaching a machine authorizes reads; it does not obviously
   authorize that. Stage 9's gate says yes; the shape of the bound is open.
4. **File identity for the editor and the diff overlay.** `openFileURL`,
   `GitDiffRequest` and `IssuesPanelModel.repoRoot` all store local paths. They
   need `(Checkout, relative path)` before Stage 9. Not before Stage 3 —
   previews stage to a local temp file and already work that way.
5. **Does blame belong at all?** remote-git-plane §5 Stage 1 lists it and its own
   §9.5 doubts it, on the grounds that blame is editor-adjacent and termio's
   editor is a preview. It did not ship with the rest of the read tier
   (`grep -rn blame termiod/src/` → 0). Decide when there is a real editor
   surface, not before.
6. **What does a Sparkle update do to a running daemon?** one-path §5.2 item 9
   recommends a compatibility window. Stage 7 cannot ship without an answer,
   because the soak is the release where it would first bite.
7. **Where does the device's project registry start?** §3 shows the first inch is
   one field — `Session::info()` reading back `workstream.project`. Whether the
   registry grows past that before direct-attach is the same question as
   workspace authority, and should be answered with it.
