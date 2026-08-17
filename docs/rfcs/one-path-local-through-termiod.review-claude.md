---
title: Review — One path, local sessions run through termiod too
status: draft
type: rfc
created: 2026-08-17
updated: 2026-08-17
related:
  - one-path-local-through-termiod.md
  - 20260805-termiod-device-architecture.md
  - 20260730-termiod-session-protocol.md
---

# Review — One path, local sessions run through termiod too

Adversarial read of `docs/rfcs/one-path-local-through-termiod.md` at `b4e3e6c`.
Every claim below was checked against the tree; where I could not check
something I say so instead of guessing.

---

## Verdict

**Implementable as an argument, not yet as a plan.** The diagnosis is right and
the sourcing is unusually good — I spot-checked about 45 `file:line` citations
and the large majority land exactly on the line claimed, including several that
are easy to get wrong (`Models.swift:344`, `TerminalSurface.swift:199`,
`SessionControl.swift:400-402`, `pty.rs:114`, `main.rs:91-100`,
`HookListener.swift:289`). The Stage 0 worktree table is exact: I re-measured
every dirty count and every ahead-of-`origin/main` count and they all match, the
1,415-lines-across-13-files figure is exact, and `DeviceSwitcher.swift` really is
byte-identical between two worktrees (`c51f8eca…`).

> **Editor's note, 2026-08-17.** F4 is **struck**: issue #311 closed the same day
> this review was written, `swift test --filter TermiodStatusTests` runs locally
> (10 tests, 0 failures) and CI's `Test` step is green on `main` at `7206463`, so
> both criteria F4 called unrunnable are executable. The rest of the review
> stands; the RFC's revision addresses it. Three blockers, not four.

~~Four~~ **Three** things must be fixed before anyone builds from it:

1. **Stage 2's central criterion asks the daemon for something it cannot do.**
   Sessions do not survive a daemon restart — `tombstone.rs:178-211` buries every
   one of them as `daemon_lost` on the next start. The criterion says three panes
   repaint "with their shell history intact" after `launchctl kickstart -k`. They
   will not. This is the whole single-point-of-failure argument, and §5 is
   optimistic by one entire failure class. **(F1)**
2. **§1.5's companion inventory is about half the real surface**, and Stage 4's
   five-member protocol cannot be written as described — three of the members it
   omits have no daemon counterpart and are not additive protocol work. **(F2)**
3. **Stage 0's reassurance paragraph is false on the file the RFC itself calls
   the largest single item.** Two open PRs touch `CompanionServer.swift`, and a
   third change to it sits committed-but-unpushed in a `/private/tmp` worktree.
   **(F3)**
4. ~~**Stage 0's first criterion cannot be run** (Swift tests do not run — issue
   #311 is open — and the "+51 lines of smoke" it cites do not exist), and neither
   can Stage 5's.~~ **(F4 — struck, see the note above; the "+51 lines of smoke"
   half was right and the RFC drops that phrase.)** The genuinely unrecoverable
   step is Stage 0, not Stage 5. **(F5)**

Fix those and the ladder is sound. §3, §4 and §7.2's boundary are the strongest
parts and I found no design regression against the four invariants — the daemon
already refuses to send OSC 4 for exactly the "host never decides presentation"
reason (`vt/src/lib.rs:198-200`), and the fan-out really is fire-and-forget
(`session.rs:1466-1469`).

---

## Citation audit

Sampled ~45 citations. Wrong: 3. Inflated: 2. Everything else checked out, most
to the exact line.

| Claim | Verdict | Evidence |
| --- | --- | --- |
| "`libc::` appears 18× in `pty.rs`, 9× in `client.rs`, ≤2× in each of `session.rs`/`files.rs`/`paths.rs`/`service.rs`" (§3.1) | **不属实** — low | Actual: `pty.rs` **26**, `client.rs` **13**, `session.rs` **3** (breaks the "≤2×" bound), `files.rs`/`paths.rs`/`service.rs` 1 each. The *conclusion* (the Unix dependency is concentrated, so a port is bounded) survives; the numbers do not. Fix the numbers or drop them. |
| "the `S` snapshot prologue does this correctly (`protocol.rs:398-417`, `tests/snapshot_prologue.rs`)" (§1.1) | **不属实** (citation) — low | `protocol.rs:398-417` is `Detach` / `Subscribe` / `SubscribeResource` / `UnsubscribeResource`. The prologue is `SNAPSHOT_PROLOGUE` + `VtTerminal::format_vt` in `vt/src/lib.rs:193-215`. The test half of the citation is right and the substance is right. |
| "Its own tests (`TermiodEventTests`, `TermiodStatusTests`, **+51 lines of smoke**) are the criterion" (Stage 0 item 1) | **不属实** — medium, see F4 | `git show --stat 5c6ccf9` and `c504bee`: neither commit touches `termiod/smoke_test.py` at all. The two Swift test files are +287 lines. |
| "31 of the daemon's 86 smoke checks cover `fs.*`/`git*`" (§0) | **夸大** — low | 86 checks total ✓. By verb: 22 (`files` gate + `fs.list`×3 + `fs.read`×3 + `fs.match`×4 + `git`×6 + `git.diff`×1 + `fs.search`×4). You reach 31 only by counting the 9 `upload:` checks, which are not what the row is about. Per-row counts in §1.2 are all exact. |
| "No uncommitted change and no open PR touches … `GitService.swift`" (Stage 0) | **不属实** — low on its own, see F3 | `GitService.swift` is dirty in `feat/remote-to-device` (a one-line comment) and is changed by `feat/client-negotiates-all-caps` itself (2 lines). Materially harmless; the same sentence is badly wrong about `CompanionServer.swift`. |

Verified exact, listed because they carry weight: `PTYProcess.swift:866`
(`foregroundProcessArguments`), `:923` (`hasForegroundJob`), `:805`
(`currentWorkingDirectory`), `:859-865` (records the macOS `tcgetpgrp`-on-master
behaviour as verified); `TerminalSurface.swift:199`, `:228-231`, `:303-328`,
`:390-426` with the call at `:413`; `TermiodClient.swift:40-53`, `:58-64`,
`:733`, `:882`, `:1066-1109`, `:1145-1152`; `TermioStore+Termiod.swift:18-23`,
`:68-70`, `:93-96`, `:382-399`, `:471-477`; `ProjectActions:609/690/704/741`;
`TermioStore.swift:413-416`, `:721-731`; `FileBrowserView.swift:53/297`;
`SessionControl.swift:44-53`, `:400-402`, `:769`; `pty.rs:67-167/114/183/208-226`;
`session.rs:25`; `protocol.rs:423/515/810-832`; `service.rs:121-127`;
`remote.rs:223-227`; `tombstone.rs:66-88`; `main.rs:88/91-100/292`;
`scripts/termio:566-580/581-587/584`; `HookListener.swift:289`. Line counts are
exact too: SFTP 1,409; `SessionControl` 894; `git.rs` really is `run_status` +
`run_diff` and nothing else; no Swift file names an `fs.*`/`git*` verb; no Swift
file consumes tombstones; `scripts/build-app.sh` and `release.yml` really do not
mention `termiod`; `tcgetpgrp` really appears nowhere in `termiod/src`.

§0's premise audit holds. Both "Fixed" rows are genuinely fixed — the
`TERMIO_TERMIOD_REMOTE` fallback is gone, `inheritDevice` is called at both split
sites, and image paste is wired end to end (`TerminalContextMenu.swift:187` →
`TermiodTransfer.pasteImage:212` → `uploadToSessionScratch:32`).

---

## Findings

### F1 — Stage 2's criterion is unachievable: a daemon restart destroys every session

**属实 · blocker · `tombstone.rs:178-211`, `session.rs:1219-1226`**

Stage 2 says:

> `launchctl kickstart -k gui/$UID/sh.termio.termiod` while three local panes are
> open: no pane shows "process exited"; all three show a reconnecting state and
> then repaint from a snapshot with their shell history intact.
> `termiod list` before and after that restart returns the same session ids.

`Graveyard::open` runs at daemon start and does the opposite:

```rust
// tombstone.rs:195-210
let orphans: Vec<RosterEntry> = read_json(&graveyard.roster_path).unwrap_or_default();
for orphan in orphans.into_iter().rev() {
    graves.insert(0, orphan.into_tombstone());
}
// The roster starts empty for this daemon: whatever the last one held is
// now buried …
```

Every session the previous daemon held is buried as `daemon_lost`, and the new
daemon starts with an empty table. There is no fd handoff and no re-exec —
`grep -rn 'SCM_RIGHTS\|execve' termiod/src` returns nothing, and the PTY master
is an `OwnedFd` inside the process (`pty.rs:98-101`). A restarted daemon *cannot*
re-adopt those PTYs. After `kickstart -k`, `termiod list` returns an empty set
plus three fresh tombstones, and the children are re-parented with a dead master.

The RFC knows the fact and does not connect it. §5.1 explains `daemon_lost`
correctly ("a session still on the on-disk roster when a daemon starts was never
buried, so the previous daemon died under it"), and §5.3 concedes the last screen
is unrecoverable on `SIGKILL`. Stage 2 then asks for shell history intact after a
`SIGKILL`.

Why this is a blocker rather than a wording fix: the whole reason Stage 5 is
allowed to delete the alternative is that Stages 1–4 "each remove a reason the
flag existed". Stage 2 was supposed to remove "a daemon restart looks like every
session dying". It removes the *misreporting* (`handleStreamEnd` →
`deliverExitLocked(status: 1)` at `TermiodClient.swift:1145-1152` is a real bug and
worth fixing) but not the *dying*. Today an app crash and its shells share a fate
the user understands. After Stage 5, a daemon crash kills every session on the
machine across every window — strictly worse than today, with no shared-fate
intuition to explain it.

What the RFC has to add, minimum: a seventh §5.2 blocker stating plainly that
session survival across a daemon restart does not exist, and an honest Stage 2
criterion — panes enter a `daemon_lost` state named as such, not `exited`, and
`termiod tombstones` explains each one. If survival is actually wanted, it is a
design (supervisor process holding the masters, or `exec`-preserving re-exec) and
belongs in this RFC, not in a criterion.

Related, and also unanswered: there is no `reapStrayOrphans` on the Rust side.
Open question 4 knows this; it does not know that F1 makes it fire on every
daemon restart, not only on a crash.

### F2 — §1.5's companion inventory is half the surface; Stage 4's protocol is not writable as specified

**属实 · high · `CompanionServer.swift` (grep-verified line by line)**

§1.5 says `PTYBridge` "calls `addSink`, `isAlternateScreenActive`,
`modeResyncPreamble`, `resizeFromCompanion`, `claimHostOwnership`,
`claimCompanionOwnership`", and Stage 4 proposes a protocol of
`(sink, write, resize, alternateScreenActive, resyncPreamble)` — five members.

The real call set, from `grep -rn` over `Sources/termio/Companion/`:

| Member | Site | termiod counterpart |
| --- | --- | --- |
| `addSink(on:replayingBuffer:replayCap:)` | `:985` | **none** — see below |
| `removeSink(token)` | `:1047` | none (no token model on the link) |
| `isAlternateScreenActive` | `:979` | **none as a local query** |
| `modeResyncPreamble()` | `:1006` | none as a local query |
| `addResizeObserver` / `removeResizeObserver` | `:1015`, `:1049` | daemon `resized` event, unwired |
| `resizeFromCompanion` | `:1041` | newest-writer-wins resize, different policy |
| `jiggleResize` | `:1042`, `:1081` | **none** |
| `claimCompanionOwnership` | `:295` (via `bridge.pty`) | writer token, different policy |
| `addExitObserver` | `:345` | **single closure, already taken** |

Three of these are not additive protocol work:

- **`addSink(replayingBuffer:replayCap:)`** is not "a sink". It replays the PTY's
  ring at attach, capped at 128 KiB, and the cap is load-bearing — the comment at
  `:990-995` says replaying the whole 1 MB ring "can tip libghostty's allocator
  into its panic screen on the cold attach". `TermiodSessionLink` has no ring and
  no byte-capped replay verb; the daemon's ring is `RING_CAP = 128 KiB`
  (`session.rs:23`) but no wire op asks for *N bytes of it*. Calling this "sink"
  in a five-member protocol hides the hardest item in Stage 4.
- **`addExitObserver`** is a *registry*. `TermiodSessionLink.onExit` is one
  closure and `attachTermiodLink` already consumes it
  (`TermioStore+Termiod.swift:90`). The companion needs a second observer. That is
  a fan-out the link does not have, not a conformance.
- **`jiggleResize`** is a local `TIOCSWINSZ` twiddle used precisely when the size
  did *not* change, to force a repaint (`:1032-1038` explains why). A `resize` to
  identical dimensions is a no-op on the daemon. There is no wire verb for "make
  the child redraw".

Two smaller corrections in the same area:

- §1.1 calls `modeResyncPreamble` "**Superseded** — the `S` snapshot prologue does
  this correctly". True for *attach*. `PTYBridge` needs `isAlternateScreenActive`
  as a **local, synchronous query** to decide replay-vs-skip *before* any snapshot
  is requested (`:979-1008`). The client has no VT state to answer it from.
- §1.1 says the host-vs-companion resize arbitration "is a companion concept with
  no daemon counterpart". It has a counterpart with different semantics — newest
  interactive attach wins, with `writer_changed` fan-out (smoke checks 2, 9, 14,
  42–44). Reconciling explicit-claim with newest-wins *is* Stage 4's design work,
  and calling it "missing" skips it.

Consequence for the ladder: Stage 4 is not "not a rebuild of the companion", it is
a rebuild of `PTYBridge`. That is fine — it may even be the right thing, since
§1.5 already argues the phone should stop mirroring a viewer — but it should be
sized honestly, because Stage 5 is gated on it.

### F3 — Stage 0's "one thing Stage 0 does not need to clear" is false, on the blocker file

**不属实 · high · `gh pr list`, `git worktree list`**

The RFC says:

> No uncommitted change and no open PR touches `PTYProcess.swift`,
> `TermioStore+TerminalSurface.swift`, `GitService.swift`, or `FileBrowser/`.
> Only PR #73 touches a refactor-critical file at all (`TermioStore.swift`).

Run today:

- **PR #298** "Reap a phone whose companion link died without a FIN" — 4 files,
  including `Sources/termio/Companion/CompanionServer.swift`.
- **PR #296** "Read a session's conversation as a chat lens on the phone" — 17
  files, including `Sources/termio/Companion/CompanionServer.swift`.

`CompanionServer.swift` is the RFC's own "**largest single item**" (§1.5) and the
entire premise of Stage 4. Two open PRs on it, one of them a 17-file feature, is
exactly the collision Stage 0 exists to find.

There is a third, worse one. `git worktree list` shows **22** worktrees; the RFC's
table lists 8. Two of the unlisted ones are ahead of `origin/main` and unpushed:

- `rebase/companion-link-resilience` — commit `a44fd9c`, `CompanionServer.swift`
  +54 plus three iOS files — living in
  `/private/tmp/claude-501/…/scratchpad/wt-298`. A temp directory. The OS may
  delete it.
- `poc/headless-input-plane` — commit `90f75dd`, 263 lines under
  `poc/headless-input-plane/` spiking a structured input plane. That is §7.2's
  subject matter, and the RFC's §7 does not know it exists.

Seven more unlisted branches are ahead of `origin/main` but pushed
(`feat/clickable-file-paths` +3, `feat/settings-file` +2, `docs/ios-agent-gui`,
`feat/ios-chat-lens`, `ci/stats-skip-when-unconfigured`,
`feat/tunelo-stable-subdomain`, `docs/remote-to-device-rfc`). Stage 0's criterion
— "every branch that is ahead of `main` is either pushed with a PR or deleted" —
is therefore roughly ten branches wider than the table implies, and the
"parallelisable, collision is concentrated in device-client files" conclusion is
wrong for the companion specifically.

To be fair to the RFC: **the eight rows it does list are exact.** I re-measured
dirty counts (16 / 9 / 0 / 9 / 10 / 19 / 2 / 7) and ahead-of-`origin/main` counts
(0 / 0 / 2 / 3 / 0 / 0 / 2 / 0) and every one matches. The byte-identical
`DeviceSwitcher.swift` claim is true (`shasum` `c51f8eca…` on both). The 1,415
insertions across 13 files is exact. The `__pycache__` claim about PR #317 is
exact (6 `.pyc` files). This finding is that the table stopped one `git worktree
list` short, not that it is careless.

### ~~F4 — Stage 0's first criterion and Stage 5's criterion cannot be run~~ (STRUCK)

**不属实 · struck 2026-08-17 · issue #311 is CLOSED**

**This finding is wrong and is retained only as a record.** Issue #311 closed at
12:19 on the day of this review; `swift test --filter TermiodStatusTests` runs
locally (10 tests, 0 failures) and the `Test` step is green in the macOS workflow
on `main`. Both criteria F4 called unrunnable are executable today and need no
change. The one true half — that the "+51 lines of smoke" do not exist — survives
in the citation audit above; the RFC drops the phrase.

The original text follows.

**~~属实~~ · high · issue #311 (open), `git show --stat`**

The RFC opens §8 with "Each stage … carries a criterion that can be **run**. 'It
compiles' is not a criterion anywhere below." Then:

- **Stage 0 item 1**: "Its own tests (`TermiodEventTests`, `TermiodStatusTests`,
  +51 lines of smoke) are the criterion." Both named files are Swift tests.
  `gh issue view 311` → **OPEN**, "Swift unit tests cannot run at all". And the
  smoke lines that would have been the runnable half do not exist —
  `git show --stat` on both commits of `feat/client-negotiates-all-caps` touches
  `smoke_test.py` zero times.
- **Stage 5**: "`swift test` green, including `SplitTreeTests` and the status
  tests." Same problem, on the one stage that deletes the alternative.

So the ladder's first gate and its point of no return both depend on a suite that
does not compile. Either #311 becomes Stage 0 item 0 with its own criterion, or
those two stages need criteria that can actually execute today. The daemon's own
suite can: `termiod.yml` runs on both `macos-26` (`:40`) and `ubuntu-24.04-arm`
(`:138`), so Stage 3's "run in `termiod`'s CI on both macOS and Linux" is
genuinely executable — the RFC is right about that one.

### F5 — the unrecoverable step is Stage 0, not Stage 5

**属实 · high · Stage 0 items 2–3**

Stage 5 is labelled "the one stage that is hard to revert" and is given a real
mitigation (flag-on-by-default for a release, rollback is a release rollback).
That is a sound answer, and it *is* recoverable — the commit is in history.

Stage 0 is not. Item 2 says to "discard [`feat/remote-to-device`'s uncommitted
work] after confirming so with a diff". Item 3 says "land or discard" the
`theme-store` worktree's 19 uncommitted files, `settings-file-watch`'s 10, the
`main` checkout's 16, and `editor-scrollaway-header`'s 2. **Uncommitted work has
no reflog.** A `git checkout -- .` there is permanent. Stage 0 is the only step in
the ladder with no rollback line, and it is the only genuinely irreversible one.

Minimum fix: every "discard" becomes "commit on a throwaway `wip/<slug>` branch,
then remove the worktree". Costs nothing and makes the step reversible.

### F6 — §6 measures latency and never measures what the change actually costs: every local byte is parsed twice

**夸大 by omission · medium · `session.rs:1219-1226`, `:1461-1469`, `:23-29`**

The VT sidecar is not conditional. `session.rs:1223` constructs every session with
`sidecar_tx: Some(sidecar.commands)`, and the read loop feeds it on every chunk:

```rust
// session.rs:1464-1469
Ok(n) => {
    let chunk = Bytes::copy_from_slice(&buf[..n]);
    // This refcount clone + unbounded send is strictly
    // fire-and-forget. Fan-out never waits for VT parsing …
    session.write_sidecar(chunk.clone());
```

No `snapshot` negotiation gates it. So after this RFC, a **local** session's bytes
are parsed twice — once by the `termiod-vt` thread (`session.rs:1267-1269`, one
dedicated OS thread per session) and once by libghostty in the app — plus a
128 KiB ring copy (`RING_CAP`, `:23`) and up to 16 MiB of sidecar queue budget
(`SIDECAR_QUEUE_CAP`, `:29`). Today it is parsed once.

The anti-100× invariant is **not** violated: byte delivery genuinely does not wait
on the parse, and the degrade (`mark_vt_stale`, `:399`) is honest. This is not a
design regression. But §6 answers "does it feel slower?" and never answers "what
does it cost?", and `bench/bench_100x.py` cannot answer it either — it compares
termiod against **tmux**, not termiod-plus-client against in-process.

The multi-session case §6 skips entirely: a daemon holding 20 sessions runs 20 VT
threads and 20 tokio tasks **whether or not any pane is attached**. §6 item 3's
"surfaces mount lazily, so this is bounded by *visible* panes" bounds client
connections, not daemon work. On a laptop this is the number that decides whether
the change ships.

Criteria to add, in the same spirit as the existing four:

- `termiod` RSS and steady-state CPU with 20 idle sessions and no client attached,
  against the in-process baseline of 20 sessions in the app.
- CPU-seconds to consume a fixed 200 MB ANSI-heavy payload, in-process vs. daemon
  + client, measured on the *pair*, not on the daemon alone.

§6's existing item 1 (p95 echo under a `yes` flood, <16 ms) is the right latency
criterion and should stay.

### F7 — §7.3's `list` row contradicts §1.1 on `cwd`, and Stage 6's compat check cannot catch it

**属实 · medium · `protocol.rs:810-831` vs `PTYProcess.swift:805`**

§7.3 files `list` as "device answers sessions/status/cwd/agent/title (`SessionInfo`
already carries all of it)". §1.1 files cwd as **Missing**: "`SessionInfo.cwd` is
the *spawn* cwd, never re-read."

Both are right about the field — `protocol.rs:812` has `pub cwd: String` — and only
§1.1 is right about its value. Today `termio sessions list` reports the *followed*
cwd for a loose terminal, because `TerminalSurface.swift:415` polls
`pty.currentWorkingDirectory()` (`PROC_PIDVNODEPATHINFO`) on a 350 ms trailing
debounce. Moving `list` to the device before Stage 3's cwd work regresses it.

Worse, Stage 6's compatibility criterion is "`termio sessions list --json` output
is field-identical to the pre-move build". Field-identical passes while the
*values* silently rot. Field shape is the wrong compatibility test for a field
whose semantics change.

Fix: either order `list` after cwd lands on the device, or state that `list`
returns the spawn cwd and the viewer overlays its own followed value, and change
the criterion to compare values on a session that has `cd`'d.

### F8 — §7.1's headline symptom has a two-line client fix, and the RFC names it without drawing the conclusion

**属实 but 夸大 · medium · `TermioStore.swift:365-372` vs `SessionControl.swift:400-402`**

The `send "t"` bug is real and the code quote is accurate. But `send` does not
route through the surface because the CLI is talking to the wrong server. It
routes through the surface because `sendText` calls `state.send`. One file away,
`addSnippetToSelectedSessionPrompt` already writes verbatim bytes to the backend
for exactly this reason:

```swift
// TermioStore.swift:359-364 — the comment
/// The bytes go RAW into the PTY (the backend session's input), NOT through
/// `state.send`: that routes into `ghostty_surface_text`, whose input encoder
/// re-encodes the ESC of a hand-written `\e[200~` as an escape KEYPRESS …
backend.sendInput(Data(("\u{1B}[200~" + text + "\u{1B}[201~").utf8))
```

`sendText` could call `backend.sendInput` today — no daemon, no protocol, no
migration — and `--no-enter` and `esc` would both work. The RFC notices the
workaround ("one file away") and still leads §7 with the symptom.

This is not an argument against §7. `read` on a session no viewer has ever opened,
and `termio sessions` on a Linux box with no Mac app, are motivations the client
genuinely cannot supply, and they are the honest headline. Leading with a symptom
that has a two-line client fix invites a reviewer to conclude the whole stage is
optional. Reframe: ship the `sendInput` fix as a stopgap in Stage 0 or Stage 3,
and lead §7 with `read` and Linux.

### F9 — §4's "`termio agent report` stays exactly as spelled" is true on the Mac and false on the device

**部分不属实 · medium · `scripts/termio:505-577`, `HookListener.swift:285-300`**

`scripts/termio` is a Mac shell script that does not exist on the device — §4.1
says so. §4.2 item 4 has hook installation become `termiod agent install-hooks`,
writing config files with `cliPath` pointing at the local `termiod`. So on the
device the agent's config says `termiod set-status`, not `termio agent report`.
The published contract is preserved on the machine where it already worked and
replaced on the machine where it is new. Say that, rather than "stays exactly as
spelled".

The under-scoping is concrete. `agent report` is not a status verb, it is a
**stdin-mining** verb:

- flags `--transcript`, `--conversation <id>`, `--conversation-from <field>`,
  `--tool-from <field>`, `--reply` (`scripts/termio:515`, `:525-537`);
- `mine_field` (`:203-207`) greps the agent's hook JSON off stdin, jq-free;
- `--reply` prints `{}` on stdout because Cursor reads the hook's stdout as its
  JSON reply (`:509`);
- `HookListener.reportCommand` picks which flags to bake per `HookDialect`
  (`:285-300`).

§4.2 item 2 scopes only "carry the rest of the payload" on the wire. The
extraction, the dialects, and the stdout-reply contract all have to be
re-implemented in Rust, and none of that is named. `termiod set-status` today is
`target`, `status`, `--title` (`main.rs:91-100`).

Second, smaller: today one hook call fans out to **both** channel sockets
(`scripts/termio:583-587`) so one install serves dev and release. §5.2 item 2
deliberately splits dev and release onto different `TERMIOD_SOCK`s. After that
split the daemon route is point-to-point, and "both can be true during migration
and the broadcast is idempotent" (§4.2) no longer holds on the daemon branch.

The RFC's open question 2 (containers) is the right question to have left open.

### F10 — the third session kind is never inventoried: `session.sshHost`

**属实 · medium · `ProjectActions:431`, `TerminalSurface.swift:165`, `FileBrowserView.swift:53`**

`addSSHSession` — "New SSH Shell" in the sidebar (`SidebarView.swift:613`), the
SSH settings tab, and three call sites in `App.swift` — runs a plain `ssh <host>`
**inside a local PTY** (`TerminalSurface.swift:165`). §1 never lists it. §1.4 does
not claim it. §2's "Opening a session on this Mac and on a VPS run the same code,
differing only in `TermiodRoute`" does not account for it.

After Stage 5 it would run inside a local *termiod* session, which works
mechanically — but leaves two overlapping remote concepts (`sshHost` and
`termiodRemoteHost`) that §2 claims to have collapsed into one.

Stage 7 makes it sharper. It deletes `SSHFileSystemProvider` and `SFTPClient` with
the criterion `grep -rn 'SFTP' Sources/ | wc -l` → 0. But the SFTP tree is keyed
exactly on `session.sshHost` (`FileBrowserView.swift:53,70`) — the one of the three
file-tree behaviours §1.2 identifies that actually *works*. An `sshHost` session's
far end may have no `termiod` at all, so `fs.list` cannot replace it. §1.2 spots
the "three behaviours for two kinds of machine" problem and Stage 7 deletes the
working one without saying what replaces it. Either `addSSHSession` gets a stated
fate (deprecated in favour of remote terminals? kept with SFTP?) or Stage 7's
criterion is wrong.

### F11 — §5's crash mitigation depends on a launchd job nothing installs

**属实 · medium · `TermiodClient.swift:354-390`, `service.rs:79-95`**

§9's risk table mitigates "a daemon crash loses every session at once" with
"launchd `KeepAlive` (shipped)". §5.1 lists it under "what exists".

But the app does not start the daemon through launchd. `spawnDaemon()`
`posix_spawn`s `termiod serve` directly with `POSIX_SPAWN_SETSID` so it outlives
the app (`:352-354`). `RunAtLoad`/`KeepAlive` exist only for a daemon installed by
`termiod service install`, which nothing in the app — and nothing in Stage 1 —
does. Stage 1's criteria check that `termiod service status` reports a live socket
but never require the app to install the job.

For an app-autostarted daemon, the headline mitigation is simply absent: it dies
and stays dead until the next app launch.

Two consequences §5.2 does not list:

- **Two daemons on one machine.** An app-autostarted daemon inherits the app's
  environment (`:381-385` says so, and says why — `TMPDIR` above all); a
  launchd-started one inherits launchd's. If those differ, `socketPath()`
  (`:40-53`) derives two different sockets and you get two daemons and two session
  tables. That is §5.2 item 2's failure with a different cause, and per-channel
  `TERMIOD_SOCK` (Stage 1 item 3) does not fix it.
- **Local version skew the day the daemon ships in the bundle.** §5.2 item 4
  covers *remote* install not being content-addressed. Once the daemon lives at
  `termio.app/Contents/Resources/termiod`, a user who also ran
  `termiod service install` has a launchd job pinned to an absolute path that an
  app update or move invalidates — and `KeepAlive` will keep respawning whatever
  is at that path. Open question 8 gestures at deprecation policy without naming
  this mechanism.

Add to Stage 1: the app installs or repairs the launchd job on first launch, and
the criterion is `kill -9` the daemon, then `launchctl print
gui/$UID/sh.termio.termiod` shows it respawned and `termiod list` answers.

### F12 — §1.1 omits `lastInputAt`; §3.3's "small change" drops a guard that fixed a real bug

**属实 · low-medium · `PTYProcess.swift:522`, `TerminalSurface.swift:325/344`, `TermioStore+AgentStatus.swift:234-241`**

Two items the inventory missed, both of the RFC's own shape.

`PTYProcess.lastInputAt` (`:522`) is read at `TerminalSurface.swift:344` and feeds
`noteUserInput` → `lastUserInputAt`, the choke that keeps agent promotion quiet
after input from *any* device — Mac keystroke, phone over the companion bridge, or
synthetic `sessions send` text (the comment at `:339-343` spells out why it taps
the PTY rather than the Mac surface's write callback). It is not in §1.1's table
and `TermiodSessionLink` never timestamps writes. That is a sixth instance of
"implemented against the object the app happens to hold", found in the file the
RFC was already reading.

Separately, §3.3 says re-pointing the screen-derived signals at `onOutput` "is a
small change and can land before anything else in this RFC". The sink it moves off
carries a guard with no analogue on the link:

```swift
// TerminalSurface.swift:325
guard let self, let pty, self.ptyProcesses[session.id] === pty else { return }
```

The comment above it (`:318-324`) says this exists because a same-agent relaunch
could otherwise let a dead PTY's queued `working` mark the replacement process.
`relaunchSession` re-creates the termiod link too (`ProjectActions:741-748`), so
the same race exists there. The change is small only if it carries the identity
check — state that, or the "land it early, it's cheap" advice reintroduces a fixed
bug.

### F13 — Stage 1's `codesign` criterion is the wrong command

**属实 · low · Stage 1**

`codesign -vvv --deep --strict termio.app` — Apple deprecated `--deep` for
*verification* and it does not validate nested code the way the flag name
suggests. For a bundle with a nested daemon the criterion should be
`codesign --verify --strict --verbose=4 termio.app` plus `spctl -a -vvv -t exec
termio.app` against a notarized build. A criterion the RFC insists must be *run*
should be a command that means what it says.

Also worth noting: the rest of Stage 1's criteria require notarization
credentials, so they are runnable only in CI or by a maintainer. Say which.

---

## Answers to the specific questions asked

**Is the inventory complete?** No — F2 (companion, roughly half missing), F10
(`session.sshHost`, absent entirely), F12 (`lastInputAt`). Two more the table
skips: `App.swift:140`'s `PTYProcess.reapStrayOrphans()` appears in §1.1 and open
question 4 but not in the §1.5 consumer table, and the whole exit-policy block at
`TerminalSurface.swift:427-471` lives inside `if let pty` while the termiod
counterpart (`TermioStore+Termiod.swift:90-107`) reimplements it minus the
self-update branch — the RFC records the gap but not that the policy is
duplicated in two places that must now be kept in sync.

Adjacent same-shape gaps outside the session plane that §1 does not mention at
all, offered as scope warnings rather than findings: `Settings/AgentAvailability.swift`
probes locally whether an agent CLI is installed (a device question);
`Companion/Usage/*` reads agent credentials and session logs off the Mac's disk,
so a remote agent's usage is unreadable by construction; `Git/BranchModel.swift`
watches the local repo. None of these blocks the RFC; all of them are the same
bug shape waiting.

**Cross-platform foreground detection (§3).** The mechanism is sound and the macOS
half is verified in-repo — `PTYProcess.swift:859-865` records `tcgetpgrp` on a
forkpty master as working on macOS, and `:869`/`:929` are the calls. `termiod/src`
contains no `tcgetpgrp` today, so this is new Rust on *both* platforms, not a
port. Two things the table is too clean about:

- `tcgetpgrp` returns a **process group id**; `KERN_PROCARGS2` and
  `/proc/<pid>/cmdline` want a **pid**. The Swift code gets away with passing the
  pgid straight through (`PTYProcess.swift:871`) because the pgid equals the group
  leader's pid. On Linux the same shortcut has a failure mode macOS does not
  share: in `foo | bar`, the leader is `foo`, and if `foo` exits first,
  `/proc/<pgid>/cmdline` is a zero-length read on the zombie — so the pane reports
  no foreground command instead of `bar`. tmux handles this by scanning `/proc`
  for a live group member. The one-line table row hides it, and open question 6's
  proposed fallback (`/proc/<child>/stat`'s `tpgid`) solves a different problem
  (finding the pgid, which `tcgetpgrp` already does) rather than this one.
- The `E { … pid, argv }` event shape is right to send a pid, but §3.1's table says
  the argv lookup takes the *pgid*. Pick one and be explicit about the
  leader-is-a-zombie case.

Stage 3's criterion is genuinely executable — `termiod.yml` runs macOS and Linux.
I did not run `tcgetpgrp` on a Linux ptmx master; the RFC's hedge is the right
posture and I have no evidence it fails.

**Agent hooks (§3/§4).** See F9. The chain works mechanically — `set_status`
exists, fans out (smoke check 46), and `TERMIOD_SESSION` becomes the routing key
once `pty.rs:114` carries a real id — but the "published contract carries" claim
does not survive, and the stdin-mining half of `agent report` is unscoped.

**Daemon single point of failure (§5).** The six blockers listed are all real and
all verified. Missing: F1 (the big one — sessions do not survive a restart at
all), F11 (nothing installs launchd; two-daemons-one-machine; local version skew
once the binary ships in the bundle). §5.3's honesty about the last screen is
good and should be extended one step further to the session itself.

**Performance (§6).** It does not evade high-frequency output — item 1 is exactly
the right question, and the criterion (p95 echo < 16 ms under a `yes` flood) is
well chosen. It does evade **cost**: F6, every local byte parsed twice plus a
thread and a ring per session, and daemon-side work that scales with *sessions*,
not with *visible panes*. Multi-session concurrency is named (item 3) but only as a
startup-connection count, which is the smaller half.

**CLI split (§7).** The boundary in §7.2 is drawn correctly and I could not find a
verb filed on the wrong side. Human keypress encoding stays client-side (right —
`TermioStore.swift:359-364` documents the exact re-encoding hazard that makes it
non-negotiable), programmatic injection leaves the surface (right). `focus` and
`notify` staying is right. Three things to add rather than change:

- `read` moving to the device is a **behaviour change**, not a relocation. The
  daemon's `S` describes the *active* screen; `SessionControl.swift:589` scrapes
  the **viewport**, which follows the user's scrollback — and
  `TerminalSurface.swift:281-286` documents that staleness as a known caveat.
  Moving `read` silently fixes the caveat and changes the answer for a scrolled
  pane. Stage 6's field-identical criterion will not catch it.
- F7: `list`'s cwd.
- §7.4 promises a Linux VPS agent "the same verbs it has on the laptop", while
  §7.3 keeps `send --wait`'s screen-change fallback and `watch --state stalled` on
  the client. Both cannot be true. On a box with no Mac app, `send --wait` degrades
  to the `wait` control op's `until` set and loses the stalled-prompt heuristic —
  which is the one supervising agents actually rely on. Name the degrade, or
  resolve open question 3 before Stage 6 ships `send`.

**Migration stages (§8).** ~~F4 (two stages gate on a suite that does not
compile)~~ (struck),
F5 (Stage 0 is the unrecoverable step, not Stage 5), F1 (Stage 2's criterion is
unachievable), F13 (Stage 1's `codesign` line). The stages that *are* well
specified: Stage 3's criteria are excellent — the "daemon built without the field
shows **no** dialog" case is the kind of negative criterion most plans omit — and
Stage 7's "one round trip per cold expansion, measured with a request log" and
"`coverage < 1.0` shows *still indexing* rather than silently missing files" are
both real and both runnable.

---

## What I checked and could not fault

Recorded so the next reader does not re-do it.

- The four invariants. Byte delivery does not block on VT parse
  (`session.rs:1464-1469`, fire-and-forget with an explicit budget rather than
  backpressure). The host does not decide presentation — `vt/src/lib.rs:198-200`
  disables OSC 4 emission with the reason written down, and `tombstone.rs:62-64`
  says the same about rendered text. No SSH or crypto is embedded; the deploy path
  shells out to system `ssh`/`scp` (`remote.rs:223-227`) and
  `performRemoteReadyCheck` sets `BatchMode=yes` so it can never prompt
  (`TermioStore+Termiod.swift:384`). `grid_diff` stays opt-in and the RFC's §2
  explicitly declines to change that. No chat UI is proposed.
- §3.2's three rules — host reports argv, push not poll, sampler never touches
  `fan_out` — are consistent with all of the above, and the skew rule ("an absent
  field preserves today's no-confirm behaviour, never *unknown so confirm*") is
  the right default given `closeConfirmationReason`'s deliberate agent exemption
  (`ProjectActions:684-692`).
- §5.2's six blockers: all six verified. Item 1 in particular —
  `daemonBinaryPath()` really does fall back to
  `currentDirectoryPath + "/termiod/target/debug/termiod"` (`:63`), and neither
  `build-app.sh` nor `release.yml` mentions `termiod`. A released build genuinely
  cannot start a daemon.
- §7.1's diagnosis of the weld, and that `termiod send --no-enter` already does
  the right thing (`main.rs:291-295`).
- The `--no-enter` grep criterion in Stage 5 is well constructed:
  `grep -rn 'TERMIO_TERMIOD\b'` correctly excludes `TERMIO_TERMIOD_BIN`, which
  Stage 1 item 2 keeps.
