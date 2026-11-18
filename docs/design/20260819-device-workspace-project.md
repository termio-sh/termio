---
title: Device → Workspace → Project
status: draft
type: design
created: 2026-08-19
updated: 2026-10-30
related:
  - 20260805-termiod-device-architecture.md
  - 20260819-workspace-switch-latency.md
---

# Device → Workspace → Project

> Settle what a workspace is, which device owns it, and retire the two other things the word currently names.

## 1. The word means three things right now

Three documents and the shipped code use "workspace" for three different
objects. Every argument about where workspaces belong has been an argument
between these definitions without saying so.

| Source | "Workspace" means | Owned by |
| --- | --- | --- |
| `20260805-termiod-device-architecture.md` §2.2 | *"a directory root on a device — what the UI calls a project"*, i.e. `(device, path)` | the device's `termiod`, as an enumerable object |
| `design/20260814-remote-to-device.md` §3 ownership table | listed beside sessions and processes: *"the device's `termiod` / on the device / viewers cache, never own"* | the device |
| Shipped code (#345) | a **named scope in the sidebar** holding projects and loose sessions — not a directory at all | the Mac's `state.json` |

The shipped meaning is the newest and the one users see, and #346 already
conceded the collision when it picked `Checkout` for "a repo on a machine"
because *"#345 gives Workspace to the sidebar scope."*

So the conflict is not really "should a workspace live on a device". It is that
the architecture doc's workspace **is termio's project**, and a genuinely new
grouping concept took its name afterwards.

## 2. The model

Four levels, each owned by exactly one of the level above:

```
Device        a machine, identified by host_id, reached by ≥1 ~/.ssh/config alias
  └ Workspace a named scope in the sidebar; holds projects and loose sessions
      └ Project    a checkout: a directory root on that device
          └ Session a PTY in that device's termiod
```

**A workspace belongs to exactly one device.** This Mac is a device like any
other, so a purely local user has one device holding all their workspaces — and
the device level stays invisible until there is a second machine, the same
collapse `New Terminal` and `Open Project…` already do.

The device is the workspace's **owner**. The sidebar scope stays the workspace,
but the switcher groups workspaces by machine, and entering a machine reopens
the workspace last used there. `⌘1…9` number the current machine's workspaces.
This narrows #345, which removed machine-scoped navigation: there is still no
machine scope in the sidebar, only a machine you can reach directly.

## 3. What the hierarchy deletes

State currently kept in more than one place collapses to one statement:

| Today | Under the hierarchy |
| --- | --- |
| `Project.deviceAlias` / `Project.deviceID` (#347) | inherited from the workspace |
| `Session.deviceID` as a filing key | inherited; still recorded as the *observation* of where it attached |
| `Workspace.deviceAlias` / `deviceID` only on fallbacks | every workspace has one, so the field stops being conditional |
| `Workspace.isDeviceFallback` and its ordering and drop-when-empty rules | gone — a fallback is just a device's default workspace |
| `deviceWorkspace(for:)` inventing a workspace per machine | still creates the default, but it is no longer a second kind of thing |

The hybrid is what made the current design hard to hold in the head: some
workspaces secretly belonged to a machine and behaved differently. Either
direction removes it; this one also removes the duplicated device fields.

## 4. What it costs

**One workspace can no longer span two machines.** A task that touches a repo
here and a repo on the VPS needs two workspaces.

This is accepted rather than mitigated: a checkout is already pinned to one
machine (`Checkout` = device + root, #346), so a workspace spanning devices was
never more than a visual grouping over leaves that each had a hard, different
device identity.

## 5. The second axis, still open

"Belongs to a device" is a *hierarchy* claim. It does not by itself say **where
the state lives**, and the two have been conflated:

- **Viewer-owned** (today): workspaces are in the Mac's `state.json`. Works
  offline, needs no protocol, but the organization does not survive losing that
  file and is not visible to another viewer.
- **Device-owned** (the architecture doc's rule): `termiod` gains a workspace
  registry. Durable and shared, but it needs create/rename/delete/list messages,
  a sync story, conflict handling when two viewers rename, and it cannot be read
  while the device is unreachable.

**The architecture doc already argues device-owned, and not on durability
grounds.** Its §2.1 rule is that every viewer attaches to the device it is
showing and never through another viewer, from which it draws the load-bearing
consequence:

> **The Mac may hold nothing a viewer needs.** […] Today the project tree lives
> in the Mac's `StateFile`; a phone talking straight to a Linux box would have
> no way to learn what projects exist on it.

Its §0.6 states the conclusion outright — the peer-viewer rule *"forces
workspaces onto the device"*. That argument does not depend on whether the
companion mirrors workspaces **today**; it is about the target architecture, in
which the phone reaches a Linux box with no Mac in the path. Under that model,
viewer-owned workspaces are not a smaller design — they are a dead end.

**Checked 2026-08-19: no viewer knows what a workspace is.** The companion wire
protocol has no workspace type, no workspace id on any session or project, and
no scope selector — `WireProtocol.swift` contains the word zero times.
`CompanionServer.companionRoster()` (`:1319`) flattens every workspace into
ordinary `RosterProject` cards, and the only trace that survives is a display
prefix (`"Alpha — Terminals"`, `:1327`) plus an opaque routing id that happens
to embed the workspace UUID (`looseWireID`, `:1313`). The iOS target has no
`Workspace` type at all. The server's own comment already records this as
deferred, not decided:

> *"telling the phone about workspaces themselves is an additive protocol change
> and belongs to its own RFC."* — `CompanionServer.swift:1321`

Two consequences, and they point in opposite directions:

- **Nothing today depends on workspaces being viewer-owned.** The entire wire
  artifact is a name prefix and a routing token, both cheap to replace. So this
  decision is not being locked in by existing clients.
- **A directly-attached viewer would be blind above the session level.**
  `termiod`'s `Control` enum has no message enumerating projects or roots, and
  the gap is one field wide: `WorkstreamSpec` already carries `project`
  (`protocol.rs:333`), the daemon stores it (`session.rs:302`), and
  `Session::info()` reads back only `agent_id` (`session.rs:335`). A client can
  *write* a session's project and can never read it.

**Recommendation, held loosely: stay viewer-owned until the phone attaches
directly.** The hierarchy in §2 buys every simplification in §3 on its own,
without touching the wire protocol, and it is compatible with either answer here.
Moving authority to the device is the larger decision, and it should be made
*with* the direct-attach work rather than ahead of it — but it should be made,
and this section should not be read as an argument that it will not happen.

The dependency runs one way, which is what makes it safe to defer: adopting the
hierarchy now does not make device-owned state harder later. Every workspace will
already name its device.

## 6. Retired vocabulary

| Dead | Replacement |
| --- | --- |
| "workspace" meaning a directory root (`architecture` §2.2) | **project**, or **checkout** when the device matters (`Checkout` = device + root) |
| "workspace fallback" / `isDeviceFallback` | a device's **default workspace** |
| "local project" / "remote project" | a project in a workspace on \<machine\>; this Mac is one |

## 7. Migration

Existing `state.json` files hold workspaces with no device (user-made) and
fallbacks with one. Both must land on a device:

- A workspace with no device and projects all on one machine adopts it.
- A workspace whose projects span machines **splits**, one per device, keeping
  the name with a machine suffix. This is the only lossy case and it is the
  reason migration cannot be skipped.
- A workspace with no projects adopts this Mac.

`WorkspaceMigration.swift` and its 13 tests are the place this goes —
specifically `reconcile(_:_:)`, which runs on **every** load
(`TermioStore.swift:1075`), not `migrate(_:)`, which runs once.

### 7.1 The decode trap

**The on-disk format must not change.** A `Snapshot` decode failure is swallowed
by `try?` (`StateFile.swift:108`), so `TermioStore.restored` sees `nil` and seeds
`Workspace.firstRun()` (`TermioStore.swift:1298`) — the user's entire sidebar
replaced by a fresh install, silently, with no error anywhere.

So `Workspace.deviceAlias` stays `String?` and stays `decodeIfPresent`
(`Models.swift:84`). The invariant is established at load time, never by
tightening a decoder. Making the field required is the one change that looks
tidiest and is most destructive.

### 7.2 The split must preserve the original UUID

A workspace's UUID is not private to the state file. `looseWireID` builds
`"<workspace-uuid>-terminals"`, which the phone sends back to start a session
(`CompanionServer.swift:1313`, `:1221`), and `ControlScope.id` keys the
`termio sessions watch` streams (`TermioStore+SessionControl.swift:908`).

Splitting must therefore keep the original id on one half — the `.thisMac` half
where there is one, else the largest — and mint a new id only for the others.
Two fresh ids breaks both the phone's ＋ and any live `watch`.

### 7.3 Confirmed reachable

The mixed-device workspace is not hypothetical. `addRemoteProject` is called
with `workspace: currentWorkspace.id` (`TermioStore+ProjectActions.swift:651`),
so `Open Project ▸ ukvps` while sitting in a local workspace files a remote
project beside local ones; and `addProject(at:)` (`:546`) files a **local**
folder into whatever workspace is current, including a device's. Both are
reachable from ⌘O and the welcome page today.

## 8. Creating a workspace

Under §2 a new workspace needs a name **and** a device, and the device must not
be visible to someone who owns one machine.

### 8.1 Where the verb lives

| Surface | Role |
| --- | --- |
| `File ▸ Workspace ▸ New Workspace…` | the canonical home — permanent, never gated on how many workspaces exist |
| The sidebar `+` menu, last row after a separator | the reachable one. `New Workspace…` depends on no selection and no focus, so it meets the bar for that menu; it sits last because a container verb is rarer than New Terminal or New Chat |
| The toolbar switcher menu | keeps the verbs, keeps collapsing at one workspace |

The switcher's single-workspace collapse was never the defect — owning the
*only* copy of a creating verb was. With the first two surfaces present, the
collapse is correct again: with one scope there is nothing to switch.

### 8.2 The device comes from the menu, not the panel

`New Workspace…` grows a device submenu on a second machine and collapses to a
plain verb without one (`refreshNewWorkspaceItem`, `DeviceMenuTag`):

```
One machine:     New Workspace…              → name panel
Two or more:     New Workspace ▸ This Mac…   → name panel
                                ──────────
                                ukvps…       → name panel
```

This is what makes §2's "the device level stays invisible until there is a
second machine" true in the interface. A device pop-up inside the panel cannot:
it would show a one-item menu reading "This Mac" to every local-only user, which
is a control for a decision they never took.

The panel keeps #347's copy shape — **"New Workspace on ukvps"** beside
**"Open a Project on ukvps"**.

**`New Workspace` is the only device submenu this shape applies to**, and the
rule that decides it is short: *a verb that creates the owner of a device must
ask for one; a verb that creates something which inherits one must not.* A
workspace is the owner, and a new one is not the one on screen, so there is
nothing for it to inherit — the menu is the only place that choice can live.

Everything below the workspace inherits, so `New Terminal` and `Open Project…`
are plain verbs on every install (§9.1). `New SSH Connection ▸ <host>` keeps its
list because the host is that verb's payload, not a device picker.

### 8.3 The panel opens with a usable default

`presentNewWorkspacePanel` currently passes `defaultName: ""`, and
`promptForWorkspaceName` ends `return name.isEmpty ? nil : name`. So the panel
opens empty and Return creates **nothing, silently**. Prefilling the next free
name — bumping a counter the way `uniqueWorktreeDirName` already does for
worktrees — makes Return create and typing over the selection rename, which is
the standard behaviour for a new item on macOS.

This one is independent of the model decision and is a live bug; it does not
have to wait for §2.

## 9. Open questions

1. When the phone attaches directly to a device, does the workspace registry move
   to `termiod`? (§5. The architecture doc says yes; this doc defers rather than
   disagrees. **Answered enough to proceed**: no viewer knows what a workspace is
   today, so the hierarchy can be adopted without settling this. The smallest
   first step, when it is settled, is surfacing `WorkstreamSpec.project` in
   `Session::info()` — the daemon already stores it and throws it away.)
2. Does `moveProject(_:toWorkspace:)` refuse a cross-device target, or move the
   checkout? Refusing is correct today; moving means a clone, which is a
   different verb. (Today it has no device predicate at all —
   `TermioStore+Workspaces.swift:382`.)
3. Does the workspace switcher group by device once there are several, or stay
   one flat list with a device mark per row?

The audit of 2026-08-19 raised three more, each a product decision rather than a
mechanical one. **Stage 1 of the implementation deliberately does none of them.**

4. **Does a device get one default workspace, or one per alias?**
   `deviceWorkspace(for:)` keys by **alias** (`TermioStore+Workspaces.swift:471`),
   so `vps-lan` and `vps-wan` already produce two workspaces sharing one
   `host_id` — and `TermiodDeviceAdoptionTests.swift:104` pins that they must
   *not* merge, citing the cloned-VM duplicate-`host_id` hazard in device
   architecture §9.5. So "a workspace belongs to one device" holds trivially,
   but "a device has one workspace" is false, and making it true *is* the §9.5
   merge that is deliberately deferred. §2 should not be read as deciding it.

5. **What replaces drop-when-empty?** `pruneEmptyDeviceWorkspaces`
   (`TermioStore+ProjectActions.swift:827`) is the only thing stopping the
   switcher accumulating a permanent row for every box the user ever opened one
   terminal on. §3 lists the rule as a casualty of the hybrid and supplies no
   successor. Deleting it without one is a visible regression.

6. **Does `Project` keep a derived device accessor?** This is the real cost of
   §3's headline deletion. `Project.isOnAnotherDevice` is a *local-disk gate*,
   not a display flag — it decides recents exclusion (`WelcomeView.swift:114`),
   duplicate detection (`TermioStore+ProjectActions.swift:551`), and which agent
   presets and context menu a row offers (`SidebarView.swift:653`, `:676`) — and
   `Project` is exercised as a pure value with no store at all in
   `RemoteProjectTests`. Moving the field to the workspace turns each read into a
   `project → workspace → device` lookup and gives a whole test file a store
   dependency. Either that cost is paid, or `Project` keeps a derived accessor
   and §3's deletion is smaller than advertised.

### 9.1 Consequences already known, needing no decision

- **`DeviceContext.swift:47` documents the opposite of §2** — *"one workspace
  holds checkouts on several devices"*. It must be corrected when Stage 2 lands.
- **`Open Project ▸ <device>` lost its stated reason, and is gone.** The menu
  carried the device *because* "the workspace the row lands in has no device of
  its own to inherit". Under §2 it inherits one, which left the submenu either
  redundant or a workspace-switching verb in a filing verb's clothes — and it was
  already the latter, since `addRemoteProject` ends in `switchToWorkspace`.
  `Open Project…` is now a plain verb on every install and
  `presentOpenProjectPanel` dispatches on `currentWorkspace.device`: the folder
  picker on this Mac, the remote path panel in a workspace that is a box's.

  This also fixed the live half of it. ⌘O rode on the This Mac row, so pressing
  it inside a workspace on a box opened a *local* picker, filed the folder into
  `workspaceForThisMac`, and threw the user out of the scope they were in.

  Opening a project on another machine is two steps now — switch workspace, then
  ⌘O — which §2 already required of everything else. §8.2 records the rule that
  decides which verbs keep a device submenu.
- **Every workspace switch starts paying an SSH roster round trip.**
  `finishArriving` calls `switchToDevice` only when the workspace has an alias
  (`TermioStore+Workspaces.swift:284`); making that unconditional costs the
  216–292 ms cold roster measured at `TermioStore+Termiod.swift:258`.
  `20260819-workspace-switch-latency.md` was written when user-made workspaces
  never paid this.
- **⌘1…9 reshuffle once.** `orderedWorkspaces` is also the shortcut order
  (`WorkspaceMenu.rows`); dropping the fallback-last rule moves them. The comment
  on `KeybindingStore.workspaceShortcuts` already accepts positional instability.
- **`Session.deviceID` is the small half.** Every "which machine is this
  session on" read is `session.termiodRemoteHost ?? session.sshHost`
  (`DeviceContext.swift:181`, `TermioStore.swift:494`, and four more).
  `Session.inheritDevice` names the endgame itself (`Models.swift:441`).
  §3's line about `Session.deviceID` understates the work.
