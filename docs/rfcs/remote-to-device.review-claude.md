---
title: Adversarial review — Retire "remote", every machine is a device
status: draft
type: rfc
created: 2026-08-15
updated: 2026-08-15
related:
  - remote-to-device.md
  - 20260805-termiod-device-architecture.md
---

# Adversarial review — "Retire remote"

Review only. Nothing here reopens the "Already decided" table; where I touch one of
those rows it is because the RFC's *citation* of it is inaccurate, not because the
decision is wrong.

**Verdict up front.** The thesis is right and the RFC does not deliver it. It
retires the *word* "remote" while leaving the *fork* — which lives in
`sshHost` vs `termiodRemoteHost`, not in menu titles — intact and, after the
rename, harder to name. Four shipped surfaces that this work must absorb are
missing from the document entirely: `New SSH Connection`, `New SSH Shell`,
**Settings ▸ SSH**, and the command palette's `New SSH Connection…`. Two of the
RFC's factual premises are false against `main` as of today.

Of your four positions: **2 and 3 survive** (3 with a stronger mechanism than you
gave it), **1 fails on its own safety argument**, **4 is right about the slot and
wrong about which item to convert**. All three gaps you named are real; there is a
fourth that is worse than any of them.

---

## 1. Where it recreates the two-copies problem

This is the central claim, so it gets the most space.

### 1.1 The fork is in the data model, and the RFC removes the wrong half

There are two ways to reach a machine today, and they are not "a verb and its
remote twin" — they are genuinely different products:

| | `Session.sshHost` (`Models.swift:298`) | `Session.termiodRemoteHost` (`Models.swift:311`) |
| --- | --- | --- |
| What runs | `ssh <host>` in a **local** PTY | a session inside the **remote** `termiod` |
| Survives detach | no | yes |
| Needs `termiod` on the box | **no** | yes |
| Verb | `New SSH Connection` / `New SSH Shell` | `New Remote Terminal` |

The shipped code states the distinction as load-bearing, not vestigial —
`TermioStore+ProjectActions.swift:434-437`:

> the distinction matters inside a host block: an "SSH Shell" dies with the
> connection, while the numbered rows beside it are durable termiod sessions that
> survive a detach.

The RFC's data-model table disposes of this in six words: `Session.sshHost` →
"**removed**; such a session is a device session." That is not a rename. It
deletes the only path that reaches a box where `termiod` cannot be installed —
no write access, an unsupported arch, a jump host, a router, a container, a
colleague's machine, a box you are touching once. After it, "device" means "a
machine running our daemon", and every machine that isn't one becomes
unreachable from termio. The word "remote" disappears; the *capability* fork
becomes a hard wall.

Either outcome is a two-copies regression:

- **Keep both** — then after the rename a host header offers `New Terminal` and
  `New SSH Shell` (`SidebarView.swift:610-618`) and nothing in either name says
  which one survives a detach. Today "Remote" vs "SSH" at least carries that
  signal, badly. The rename makes the fork *less* legible.
- **Drop `sshHost`** — then you have deleted a working feature with four entry
  points (File menu `App.swift:2133`, `+` menu `App.swift:1804`, Settings ▸ SSH's
  Connect button `SSHSettingsTab.swift:11`, command palette `CommandPalette.swift:342`)
  and the RFC nowhere says so.

**The RFC must pick one and defend it.** My recommendation: keep both, and rename
on the axis that actually differs — `New Terminal on <device>` (durable) vs
`SSH Shell to <host>` (transient, no daemon). "Remote" is the wrong word because
it names the road; "SSH Shell" is the *right* word for the same reason — that
session really is nothing but an ssh road in a local PTY.

### 1.2 Settings ▸ SSH already exists, and it is Settings ▸ Devices

The ownership table's second row — "The list of reachable machines | the user's
`~/.ssh/config` | **read-only; no Settings entry**" — is false today.
`Sources/termio/Settings/SSHSettingsTab.swift` is a shipped settings tab
(`SettingsTab.swift:10`, subtitle "Your ~/.ssh/config hosts, one click away")
that lists every alias, tests reachability per host, opens the raw config in the
editor, and **appends `Host` blocks via Add Host** (`SSHSettingsTab.swift:279-282`).

So the RFC proposes `Settings ▸ Devices` next to an existing `Settings ▸ SSH`,
where both are lists of machines built from overlapping sources, and never
mentions the collision. That is the two-copies problem instantiated *inside the
Settings window* by the document that exists to delete it. Whatever lands must
either subsume the SSH tab into Devices or say precisely which machine facts live
in which tab — and the ownership rule as written cannot decide it, because
"reachability" is produced by termio's own probe (`SSHSettingsTab.swift:241-247`)
and therefore qualifies as "termio produced this state itself".

### 1.3 The argument against `Add Device…` is a strawman that shipped code refutes

> it implies a termio-owned roster, which would immediately fork from the
> `~/.ssh/config` it was copied from

`AddSSHHostSheet` already solves this and has for releases: it appends a real
`Host` block to the real file, "indistinguishable from a hand-written one"
(`SSHSettingsTab.swift:278-281`), then connects. No second roster, no fork,
because the write goes to the authoritative file rather than beside it. The RFC
rejects a verb on grounds the codebase has already disproved.

This matters for the `Already decided` row that reads "`~/.ssh/config` is
authoritative — read it, **never write it**", cited to `CLAUDE.md` #3. CLAUDE.md
#3 says "read it, **never override it**." Those are different rules, and the
substitution retroactively makes a shipped, deliberate feature a violation. I am
not reopening the decision; I am flagging that the RFC's version of it is not the
one in the file it cites.

### 1.4 The device would live in three places at once

`Project.kind == .host` containers already exist and already group both session
kinds under one machine (`hostContainer(for:)`,
`TermioStore+ProjectActions.swift:398-420`; header menu at `SidebarView.swift:608`).
The RFC adds (a) an always-visible indicator with a switcher, and (b) a device
column on the cross-device session list — without retiring (c) the host container
that is the sidebar's current answer to "which machine is this".

Three representations of device identity, each authoritative for a different
question. If the indicator says `vps` and the sidebar simultaneously shows host
blocks for `vps` and `laptop`, "the current device" is a *fourth* thing that
scopes only new work. That needs to be designed, not assumed; right now the RFC
adds a layer and deletes none.

### 1.5 `Connect to…` is not new

The vocabulary table lists `Connect to…` as "— (new)". It is `New SSH Connection`,
shipped, in the File menu, the `+` pull-down and the command palette, complete
with the free-form `user@host` entry the RFC asks for
(`presentSSHConnectPanel`, `TermioStore+ProjectActions.swift:447-469`) and the
"not in the config yet" escape (`addSSHHost`, `App.swift:926-935`). Presenting it
as new is how the third connect verb gets added without anyone noticing.

---

## 2. Repo invariants and shipped conventions

**Colour is already spent, twice, in the exact surfaces the RFC wants to tint.**

| Surface | What colour already means | Cite |
| --- | --- | --- |
| Sidebar session ring | **orange = needs you**, **green = done** | `SidebarView.swift:1393-1395` |
| Sidebar session icon | the **agent's** brand tint | `AgentDefinition.swift:129`, `BrandIcons.swift:96` |
| Settings ▸ SSH row badge | green / orange / red = reachable / auth-failed / unreachable | `SSHSettingsTab.swift:263-268` |

Workstream status being first-class is the stated differentiator (`CLAUDE.md`,
"agent-native at the protocol level"). Colour in the sidebar is its channel. A
third colour system — device identity, hash-assigned from a fixed palette —
puts an arbitrary orange next to a meaningful orange in the same row. That is not
a preference; it degrades the one signal the product claims as its own.

**Accent-coloured control backgrounds are forbidden.** Any tint that lands on a
control must be a swatch, not a fill. Your position 2 already says this; the RFC's
"colour … **bleeds into the surface**" heading and its Dia precedent
(`didBackfillSpaceThemesFromProfileColor`) say the opposite.

**Evidence policy.** The companion doc labels every external claim
**Announced / Inferred / Unknown** and states the policy up front. This RFC's
entire Interface section rests on private symbol names from a closed-source
competitor's binary with no label and no way for a reader to check any of it.
Same repo, same subject, weaker standard.

**Localization.** `New Remote Terminal` appears zero times in
`Sources/termio/Resources/Localizable.xcstrings` while `New Terminal` and
`New SSH Connection` are both there, and the sidebar/menu sites pass bare strings
(`SidebarView.swift:797`, `App.swift:1457`, `SidebarView.swift:610-618`). So
stage 1 is not "client-only, no persistence change" — it is also the zh-Hans work
(#224) these strings never got, plus whatever the iOS catalogue needs. Small, but
the staging note currently understates it.

---

## 3. Your four positions

### Q1 — Deterministic colour from `host_id`: **fails**

Determinism and distinguishability are in direct conflict, and the RFC's own
safety argument ("picking the wrong machine runs `rm -rf` on the wrong disk")
depends entirely on distinguishability.

A palette that survives §2 above — chrome-legible, not colliding with
orange/green/red status, readable in both appearances — is realistically 8 to 10
colours. Hashing `host_id` into it is uniform random assignment, so by the
birthday bound two devices share a colour with ~50% probability at **four**
devices, and near-certainty by eight. The failure mode is not cosmetic: two
same-coloured devices is strictly worse than no colour, because the user has been
taught to read colour as identity and now reads it wrong.

Least-recently-used assignment guarantees zero collisions until the palette is
exhausted — the whole range where the feature is supposed to work.

The benefit you are buying with determinism is "the same machine gets the same
colour on every Mac the user pairs". Weigh it honestly: the user looks at one Mac
at a time. They never see two Macs' sidebars side by side, so there is no moment
where the inconsistency is visible. You are trading a real, common failure
(collision at 4 devices) for a benefit that is only observable across a context
switch measured in minutes.

If cross-Mac stability matters to you, it is a *sync* problem, and you already
have the place for it — `devices.json` is termio-produced state
(`TermiodDevice.swift:94-110`), so the colour belongs there and travels the same
way any other device fact would. Hashing is not the cheap way to get sync; it is
a way to get collisions and call them consistency.

**Recommendation:** assign least-used-first on first handshake, persist per Mac,
user-overridable. Keep the "user-overridable in Settings" half of your position —
that part is right, and it is also the escape hatch when two machines land close.

### Q2 — Chrome only, never the grid: **survives**

Correct, and it is a boundary consequence rather than taste: the grid's colours
are the viewer's theme, and the presentation boundary (device-architecture §4)
says the viewer decides. A host-derived tint in the grid is the same class of
error as the resolved-RGB bug that section was written about. Add the swatch-not-
fill constraint from §2 and this is settled. Nothing to argue.

One addition the RFC needs and you did not mention: the **title bar** you list is
the one chrome surface that is also the macOS window's own; tinting it needs to
survive fullscreen and inactive-window states, where a low-saturation tint on
an inactive title bar is close to invisible — i.e. the indicator has to carry the
signal on its own anyway, and the title bar tint is decoration. Cheapest correct
answer: indicator + sidebar header only.

### Q3 — No device-scoped guardrail: **survives, and the RFC asked the wrong question**

Your argument is right and the shipped rule is stronger than the one you made.
`closeConfirmationReason` (`TermioStore+ProjectActions.swift:684-692`) confirms on
exactly one condition — a shell with a live foreground job, because that command
"exists nowhere else" — and explicitly refuses to confirm for agent sessions
because taxing every close to protect a resumable conversation was not worth it.

That is the repo's actual doctrine: **confirm when closing destroys the only copy
of something, never because of where it runs.** A device-scoped confirmation
fails that test on both halves.

But the interesting part is that the RFC has the polarity backwards. The
confirmation reads `ptyProcesses[session.id]` — the **in-process** PTY handle. A
termiod-backed session has no entry there (it lives in `termiodLinks`), and
`hasForegroundJob` exists only on `PTYProcess` (`PTYProcess.swift:923`), with no
counterpart anywhere in `termiod/src`. So **today a remote session with a build
running closes silently, and a local one asks.** Non-local sessions have *less*
protection, not more.

So the real work item is not "how heavy should the extra dialog be" — it is
*port the existing rule across the wire*: `termiod` needs to report whether a
session has a foreground job (a `tcgetpgrp` on the PTY master, one field on the
`list`/`kill` path), so the one confirmation the product already believes in
works on every device. That is the same rule everywhere, which is the RFC's whole
thesis; the RFC's three options are all the local/remote fork wearing a warning
triangle.

Keep your carve-out for Forget device / uninstall termiod. Those are
device-scoped irreversible actions, not command execution, and Apple confirms
those too.

### Q4 — Right slot, wrong item: **half survives**

The slot is right: `New Remote Terminal ▸ (No SSH hosts in ~/.ssh/config)`
(`SidebarView.swift:795-797`) is a dead end and should not exist. Adding a fifth
verb to fix it would be absurd. Agreed, and the `+` menu's global rule is
satisfied — `makeNewSessionMenu` is explicitly context-free
(`App.swift:1790-1794`).

Two problems with converting *that* item:

1. **The dead end is already solved one row below.** `New SSH Connection ▸` ends
   with `Add Host…` (`App.swift:926-935`), which is the exact escape the empty
   submenu lacks. The narrow bug is that `remoteTerminalMenuItem` doesn't share
   it. That is a three-line fix, not an RFC item, and the RFC's opening
   motivation overstates it as a design flaw.
2. **Converting `New Remote Terminal` into `Connect to…` puts two connect verbs
   one row apart** — `Connect to…` and `New SSH Connection`, both enumerating the
   same aliases from the same file, differing only in durability, with the more
   descriptive name now on the *less* capable one. Your position deletes the
   ambiguity from one item by concentrating it in the pair.

`Connect to…` is also a weaker string than what it replaces. Finder's precedent
is `Connect to Server` — the noun is what makes it legible. And `Connect` is
already spent in this product on the transient act: the Settings ▸ SSH row button
(`SSHSettingsTab.swift:10-12`) and the connect panel's default button
(`TermioStore+ProjectActions.swift:450`) both mean "open a plain ssh shell now",
whereas the RFC's `Connect to…` means "install a daemon and open a durable
session." Same word, opposite weight.

**Recommendation:** your slot, but the conversion has to cover both items or
neither. One machine-reaching verb in the `+` menu, named for the object
(`Connect to Device…`), whose submenu lists known devices, then unused
`~/.ssh/config` aliases, then `Add Host…`, then free-form entry — and
`New SSH Connection` retires into it as the transient variant (a modifier row, or
the `SSH Shell` verb kept only on a host header where the machine is already
named). That fixes the dead end, removes a verb instead of renaming one, and
costs a single-device user nothing.

---

## 4. Your three gaps

**Unreachable presentation — real, and partly already built.** Confirmed: the RFC
puts device identity in permanent chrome and never says what it renders when the
device is gone. But you are being slightly unfair to the codebase — the vocabulary
exists, in the tab the RFC doesn't cite: `reachable / authFailed / unreachable`
with per-state copy and tint (`SSHSettingsTab.swift:251-275`), and
`ensureRemoteReady` already produces a specific human-readable cause, including
ssh's own last stderr line (`TermioStore+Termiod.swift:386-394`). The gap is that
none of it reaches the indicator, and that the architecture doc's §8.6 promises a
**third** state — *degraded* — that has no representation anywhere. Three states
in the settings tab, four in the architecture, zero in the RFC. Name them once,
in the RFC, and reuse the shipped ones.

**`TERMIO_TERMIOD` retirement missing from Staging — real, and it is the most
dangerous omission in the document.** Confirmed absent; the architecture doc
claims it (§0, §8.5) and the RFC's four stages never mention it. And it is worse
than "its own risk profile":

Retiring the flag deletes the in-process `PTYProcess` path. `ptyProcesses` becomes
permanently empty. `closeConfirmationReason` gates on
`ptyProcesses[session.id]` (`TermioStore+ProjectActions.swift:690`). Therefore
**retiring the flag silently deletes the "a command is still running" confirmation
for every session on every device, including purely local ones**, with no code
change at the call site and nothing in any staging list that would catch it. It is
a one-line consequence of a step nobody scheduled, landing on the user who never
leaves their laptop.

That single finding ties your gap 2 to your position 3, and it is the strongest
argument in the document for why the foreground-job probe has to be part of the
protocol before the flag goes away — not a guardrail *added* for remote devices,
but an existing guardrail *rescued* before the fork deletion takes it out.

**Stale PR #177 paragraph — confirmed, worse than stale.** PR #177
("termiod: durable PTY session host (Rust POC)") merged to `main` at
2026-08-15T13:07:15Z, commit `66b1722`. Every factual claim in that paragraph is
now false: it is not a draft, it is not 73 commits ahead, and `main` has both
`termiod/` and `Sources/termio/Terminal/Termiod/`. Stage 1 is unblocked. Delete
the paragraph rather than updating it — the reasoning it contains ("renaming now
enlarges a hard merge") has no successor.

### A fourth gap: `Connect to…` promises an install that most users cannot run

The RFC's switcher entry says "First use installs `termiod`
(`ensureRemoteReady` already does this)." What `ensureRemoteReady` actually does
when the binary is absent is shell out to `termiod remote deploy <host>`, which
**cross-compiles a musl binary with `cargo` on the user's Mac**
(`termiod/src/remote.rs:211-280`), and whose failure message tells the user to
`brew install FiloSottile/musl-cross/musl-cross`
(`termiod/src/remote.rs:271-275`).

For a shipped `.app`, that is not an install path — it is a toolchain
prerequisite that approximately no user of a native Mac terminal has. The
architecture doc knows this (§2: "adding a box means … a deploy that
cross-compiles a musl binary on the Mac and `scp`s it") and schedules prebuilt
per-arch binaries at §8.8, which is not done.

So `Connect to…` as specified is a verb that fails for most users at the moment
of first use — the exact "dead end at the moment a new user arrives" the RFC
opens by condemning, moved one click later. **Prebuilt binaries (§8.8) are a
hard prerequisite for stage 1**, not a later nicety, and the RFC must say so.

---

## 5. One device

The RFC's promise is "no indicator, no submenu, no Settings tab". That part it
can keep — the collapse is cheap and the Dia precedent for it is the least
contentious thing in the document.

What the single-device user actually pays is everything in §4 gap 2, none of
which is in the RFC:

- Their local terminal moves from an in-process PTY to a daemon over a Unix
  socket — a new process, a launchd agent (which the architecture doc §8.3 says
  is deliberately *never* installed automatically, so someone must decide when it
  is), and a new single point of failure where the app previously shared fate
  with its PTYs (§6).
- They lose the running-command confirmation, as above.
- Crash recovery becomes "tombstone says what died" instead of "the PTY died with
  the app", which is better in principle and is more UI they now have to meet.

None of that is an argument against the direction. It is an argument that "someone
who never leaves their laptop must never pay for this feature" is a claim the RFC
has not earned, because the largest cost to that user is in the step the RFC
forgot to list.

## 6. Twenty devices

- **Colour breaks first**, at four, for the reasons in Q1. By twenty it is
  decoration, and the RFC's safety argument for it is gone. At that scale the
  identity signal has to be text — the device name in the indicator, colour as a
  secondary cue — which inverts the RFC's "colour is readable in peripheral
  vision; a text label is not."
- **The menus become unusable before the switcher does.**
  `remoteTerminalMenuItem` and `cloneOnRemoteMenuItem` both map *every*
  `SSHConfigFile.hosts()` alias into a flat submenu (`SidebarView.swift:799-813`,
  `SidebarView.swift:833-841`), built synchronously on every right-click. Twenty
  aliases is a twenty-row submenu on a project row; a config with `Include`d
  work hosts is routinely more than that. The RFC's `Clone to <device>…` inherits
  this shape unchanged and needs a scale answer (recents first, then a search
  field) that it does not have.
- **`Connect to…` gets worse with scale, not better.** It is specified as
  "aliases not yet used" — a list that is *largest* for the user with the most
  hosts, and that shrinks only as they connect. The heavy user gets the longest
  list of the least interesting items.
- **Aliases outnumber devices.** The whole point of `host_id` is that
  `vps-lan` / `vps-wan` / a tailnet name are one machine (architecture §2). So at
  twenty devices the alias list is 30–50 rows while the switcher shows twenty.
  Two lists of different lengths describing the same machines, and the RFC never
  says how the `Connect to…` list hides aliases that resolve to a device already
  in the switcher — it can't, because that mapping is only known after connecting.
  This is fine, but it should be stated: the unused-alias list is necessarily
  imprecise, and some rows will resolve to a device the user already has.

---

## 7. Vocabulary table

| Row | Assessment |
| --- | --- |
| `New Remote Terminal` → **New Terminal** | **Worse.** Collides with two shipped items: `New Terminal` (⌘T, follows the focused session's directory, `App.swift:2111-2115`) and `New Terminal at Home` (context-free, the `+` menu's own, `App.swift:1797`). Under the RFC the `+` menu would carry `New Terminal at Home` and a device-submenu `New Terminal` — and ⌘T becomes ambiguous the moment the focused session is on another device, because "here" no longer has a referent. The collapse silently makes ⌘T device-dependent and the RFC does not say what it does. |
| `Clone on Remote…` → **Clone to \<device\>…** | **Actively misleading.** The operation runs `git clone` from `origin` **on** that machine (`cloneOnRemote`, `SidebarView.swift:830-855`); nothing is copied from the Mac, and uncommitted or unpushed work does not travel — which is exactly the mistake the click-time `cloneInfo` check exists to catch. "to" names a copy destination and invites precisely that expectation. Keep the preposition: **Clone on \<device\>…**. |
| "remote session/host" → "a session on \<device\>" | Fine. No objection. |
| **Connect to…** (new) | **Not new** (§1.5), **and the word is spent** (§3 Q4). Name the object: `Connect to Device…`. |
| — | **Missing rows:** `New SSH Connection`, `New SSH Shell`, `Add Host…`, and the palette's `New SSH Connection…`. A vocabulary table that retires "remote" while leaving four SSH-named verbs in the same menus has not retired the road-name — it has retired one synonym for it. |
| **"Device"** | **Collides in the shipped Settings sidebar.** `Settings ▸ Mobile` is the iPhone pairing tab (`SettingsTab.swift:13`), and in everyday Apple usage a paired iPhone *is* "a device". `Settings ▸ Devices` sitting beside `Settings ▸ Mobile` will read as "my paired phones", not "machines that run my agents". This deserves an explicit answer in the RFC — either Mobile folds into Devices, or the tab is named for what it holds (`Machines`). Note the architecture doc has the same exposure but never has to render the word in a settings sidebar; the RFC does. |

---

## 8. What I would change before this is implementable

1. **Decide `sshHost`'s fate explicitly** and say which machines termio can still
   reach without `termiod` (§1.1). This is the RFC's real subject.
2. **Fold Settings ▸ SSH into the Devices design** or state the split (§1.2).
3. **Schedule the `TERMIO_TERMIOD` retirement**, with the foreground-job probe as
   its precondition (§4 gap 2). Without it, deleting the fork deletes a shipped
   confirmation on every device.
4. **Make prebuilt per-arch binaries (architecture §8.8) a stage-1 prerequisite**,
   or `Connect to…` ships as a dead end (§4 gap 4).
5. **Name the reachability states once** — reachable / auth-failed / unreachable /
   degraded — and reuse the shipped copy and tints (§4 gap 1).
6. **Delete the stale PR #177 paragraph** (§4 gap 3).
7. **Drop hash-derived colour for least-used assignment**, and state the palette
   constraint that it must not collide with the status ring's orange/green (§3 Q1).
8. **Add the four missing verbs to the vocabulary table** and re-derive the menu
   shape from the full set, not from two of six (§7).

Nothing here argues against the thesis. Every machine should be a device, and the
word "remote" should go. The document just has not yet found the fork — it is in
`Models.swift:298` and `Models.swift:311`, not in the menu titles.
