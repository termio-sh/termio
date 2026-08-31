---
title: Session identity survives the agent
status: draft
type: rfc
created: 2026-08-30
updated: 2026-08-31
related:
  - 20260829-tab-strip-is-the-collapsed-sidebar.md
  - 20260827-termiod-lifecycle-reconcile.md
---

# Session identity survives the agent

> A session is a session — there is no second kind. This RFC fixes issue #528
> by making destroy name-addressed and agent exit visible, and removes the
> "Also Running" section entirely: external sessions become ordinary rows —
> following the identity model tmux and herdr both use.

## The bug (#528)

A built-in Claude Code or Codex session runs as:

```text
termiod
└─ /bin/zsh -il
   └─ codex | claude
```

The user exits the agent normally. The outer login shell survives, and the
session's sidebar row disappears — replaced by an entry under **Also Running**
named `zsh`. The user must reattach and `exit` a second time to be rid of it.
The reporter's complaint is exact: the session changed identity silently, so a
finished task reads as a process leak.

## Three root causes

These are separate defects that compound. All file references are current as of
this writing.

### 1. Destroy depends on a lazily-created link

`closeSession` kills the daemon-side session through exactly one line
(`Sources/termio/TermioStore/TermioStore+ProjectActions.swift:1003`):

```swift
termiodLinks[id]?.killAndClose()
termiodLinks[id] = nil
```

The `?.` is the bug. A `TermiodSessionLink` is created only when a pane
actually renders (`surface(for:)` →
`makeTermiodLink` in `TermioStore+TerminalSurface.swift:287`), and it is
cleared in several places — first thing in `applyTermiodExit`
(`TermioStore+Termiod.swift:375`), on connection loss, and wholesale on app
quit. So every one of these closes silently kills nothing:

- a row restored after app relaunch that was never selected,
- a close from the CLI or the phone for a row never viewed this run,
- any close after the exit/connection-lost paths nil'd the link.

The same pattern repeats at `removeProject`
(`TermioStore+ProjectActions.swift:857`) and `relaunchSession` (`:1063`).
`relaunchSession` is the worst case: its comment promises "a respawn-in-place
must not leave the old daemon-side process running under the same name", but on
the revert-to-shell path the kill is *always* a no-op, because
`applyTermiodExit` already nil'd the link before calling it.

The irony: `killAndClose()` itself already kills by name
(`Terminal/Termiod/TermiodClient.swift:1292`), and `closeDeviceSessions`
already does a link-free kill for stranger rows
(`TermioStore+Termiod.swift:770`). The capability exists; `closeSession` just
doesn't use it when the link is gone.

### 2. Agent exit inside a surviving shell is invisible

The launch wrapper is `[shell, "-ilc", "exec \(command)"]`
(`TermioStore+TerminalSurface.swift:502`). When the `exec` actually replaces
the shell, agent exit ends the daemon session, `link.onExit` fires, and
`applyTermiodExit` reverts the row to a shell in place — the designed behavior.

The issue's process tree shows a shell that did **not** exec: the agent ran as
a child of `zsh -il`. (A `claude`/`codex` that resolves to a shell function or
alias shim in the user's zshrc is enough — `exec` of a function cannot replace
the process.) In that tree the daemon session never exits, so no exit event
ever fires. And the app deliberately never demotes a declared agent row from
foreground data — `applyTermiodInformation` is wired with
`identifiesAgent: isPlainTerminal` (`TermioStore+Termiod.swift:135`). Net
effect: no code path in the app can notice the agent left.

termiod, for its part, already reports everything needed: the foreground
sampler (`termiod/src/session/foreground.rs`, 2s cadence) publishes
`foreground_pid` / `foreground_argv` per session, and `zsh` in an Also Running
row is precisely that sampler reporting an idle login shell.

### 3. The stranger filter can't tell strangers from our own orphans

"Also Running" was designed (tab-strip RFC) as *sessions the device reports
that no row accounts for* — the adoption affordance for sessions started from
the `termiod` CLI. The filter (`TermioStore/DeviceContext.swift:205`) is:

```swift
guard information.alive else { return false }
guard !mine.contains(where: { daemonSessionName(for: $0) == information.name }) else { return false }
if isLocal, information.attachedClients > 0 { return false }
```

An app-created session whose row was closed link-lessly satisfies all three
within one roster refresh. The filter checks *live* rows only; the app keeps no
record of sessions it closed, so its own orphan is indistinguishable from a
genuine CLI-started stranger.

## What tmux and herdr do

Both competitors converge on one principle: **identity belongs to the session
object; the foreground process is an attribute of it.**

- **tmux** — a pane's identity never changes when its process exits. Default:
  the pane dies with the process. With `remain-on-exit`, the pane stays *in
  place*, explicitly marked dead ("Pane is dead"), and `respawn-pane` revives
  it in the same spot. There is no path on which a pane migrates to a
  different list under a different name.
- **herdr** — the pane is the stable identity and the agent is *detected
  inside* it ("each agent stays in a real terminal pane with its shell").
  Agent exit rolls the pane's state back to idle/unknown; the pane stays where
  it is. There is no orphan bucket at all. External sessions are handled by
  detection and state roll-up, not by a separate section.

Termio's revert-to-shell is already the right call by this standard — it is
tmux's `remain-on-exit` with a live shell instead of a dead pane. The bug is
that on the non-exec tree the revert never runs, and that close can leak the
daemon session into a bucket that changes its identity.

## Design

### D1. Destroy is name-addressed, never link-addressed

The `(daemon name, route)` pair is the destroy capability. The link is a live
attachment — an optimization, never a prerequisite.

`closeSession`, `removeProject`, and `relaunchSession` kill unconditionally by
name, exactly as `closeDeviceSessions` already does:

```swift
if let link = termiodLinks[id] {
    link.killAndClose()
} else {
    Termiod.killSession(
        target: daemonSessionName(for: session),
        route: TermiodRoute(sshAlias: session.termiodRemoteHost))
}
termiodLinks[id] = nil
```

`closeSession` already reads the session before mutating (`locate(id)` at
`:998`), so name and route are available. "No such session" stays a benign
answer, as it already is in `TermiodClient.swift:829`.

If the route is unreachable at close time (remote host offline), record the
`(name, route)` pair as a pending kill and retry on the next successful roster
refresh for that route. A small persisted ring is enough; this also closes the
close-while-offline hole that no link-based scheme could.

### D2. Agent exit is detected by foreground, not only by process exit

Keep both exit shapes converging on the same UX — the row stays in place:

- **Exec'd tree** (daemon child *is* the agent): unchanged —
  `applyTermiodExit` → revert to shell in place. D1 fixes `relaunchSession` so
  the respawn actually replaces the old daemon session instead of reattaching
  to it.
- **Wrapped tree** (agent is a child of a surviving shell): let foreground data
  demote a declared agent row. When a declared-agent session's
  `foreground_argv` has reported the shell for a stable streak (same streak
  machinery status promotion already uses), transition the row in place:
  status → idle, subtitle → "Claude Code exited — shell". The
  `identifiesAgent: isPlainTerminal` asymmetry stays for *promotion* (a
  declared row never gets re-identified as a different agent), but demotion to
  "agent gone, shell remains" becomes an explicit, visible state.

The issue asks for one of: kill the outer shell too, keep the shell clearly
labeled in place, or a setting. This RFC picks **labeled in place** as the only
behavior — it is tmux's `remain-on-exit` semantics and herdr's idle roll-back,
it preserves scrollback, and it matches "the session lives on the box". A
setting is surface area we don't need until someone asks for the kill
behavior.

### D3. Remove "Also Running" — external sessions become ordinary rows

The section is a second concept of "session" the user has to learn: its own
name, its own close verb ("Close All"), its own gesture (tap to adopt), and
set-difference semantics ("device roster minus rows") that nobody can predict
from the UI. #528 is what that costs — a user staring at a bucket whose
membership rule they were never told. herdr has no orphan bucket; tmux has no
orphan bucket; neither should we.

So the section goes, and its one legitimate job — surfacing a session someone
started from the `termiod` CLI — is served by making that session an ordinary
row automatically. The app remembers the daemon names of sessions it has
closed (the same ring that D1's pending kills use — a closed-session journal
keyed by daemon name, bounded, persisted in `StateFile`). At roster refresh,
each live daemon session resolves to exactly one of:

- name matches a **current row** → accounted for (already the case),
- name matches a **journaled close** → kill it on sight. D1 should have
  killed it; this sweep is the belt-and-braces that makes the invariant hold
  even across crashes and offline closes,
- unknown and adoptable → auto-adopt: run today's manual
  `adoptDeviceSession` path unprompted. The row lands in the project whose
  root contains its cwd, else as a loose terminal; it carries
  `termiodSessionName` and closes like any other row (D1 makes that kill
  real),
- unknown, **on this Mac**, with **another client attached** → leave it
  alone; the local socket is per-uid, so an attached unknown here is a second
  install's live session, not ours to claim.

The attached-client guard is local-only, deliberately: attachment is
read-many by design (single writer, many readers), so on a remote device a
session the phone has open is still one of that box's sessions, and skipping
it would hide the box's own work from the Mac — the exact mistake the old
section's filter already scoped to local.

The journal, not name shape, decides "mine": two Termio installs share one
per-uid daemon roster, so a UUID-shaped name alone proves nothing about whose
session it is.

UI removal: `alsoRunningSection` and `DeviceOnlySessionRow`
(`Sidebar/SidebarView.swift:339`, `:1633`) and the section's menu go away;
`deviceOnlySessions()` stops feeding a view and becomes the auto-adopt
candidate list. The *Also running* group in the tab-strip RFC
(`20260829-tab-strip-is-the-collapsed-sidebar.md`) is superseded by this —
auto-adopted rows appear in the strip as normal rows, which is what that RFC
wanted anyway ("adopts on click exactly as its row does", minus the click.)

One consequence to accept: a second install whose app is quit leaves detached
sessions with zero attached clients, and this install will adopt them. That is
the correct reading of "one roster, any client" — a detached session on the
box *should* be reachable from whichever client is looking at the box. The
original install reclaims its rows by name on relaunch, same as it does today
after its own restart; duplicate rows across installs are already possible via
manual adoption, and the single-writer token arbitrates as it always has.

## Testing

- `Tests/termioTests/TermiodDestroyIntegrationTests.swift` installs the link by
  hand (`:104`), so the link-present path is the only one ever exercised — the
  #528 close path has zero coverage. Add the link-less cases: close of a
  restored row, close after `applyTermiodExit`, close from the CLI path.
- Unit-test the D3 resolution: a roster row matching a journaled name must be
  killed, not adopted; an unknown detached row must adopt into the
  cwd-matching project; an unknown row with an attached client must be left
  alone on the local device and adopted on a remote one.
- The D2 demotion streak is pure logic over `SessionInfo` sequences — testable
  without a window, same shape as `StallProbeTests`.
- Manual: reproduce the issue's tree by shadowing `claude` with a zsh function
  in a probe channel (`TERMIO_CHANNEL=probe`), exit the agent, confirm the row
  demotes in place; close it, confirm the daemon roster is empty.

## Non-goals

- #526/#527 (connect-failure daemon spawning) are a different root cause and
  tracked separately.
- No daemon-side "owner" metadata. termiod stays client-agnostic; ownership is
  the app's bookkeeping (the journal), which also keeps two installs sharing a
  roster honest.
- No change to revert-to-shell as the designed outcome of agent exit, and no
  nested window manager anywhere in the host.
