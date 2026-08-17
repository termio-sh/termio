---
title: Every machine is a device, every place you work is a project
status: in-review
type: rfc
created: 2026-08-14
updated: 2026-08-16
related:
  - 20260805-termiod-device-architecture.md
  - 20260730-termiod-session-protocol.md
  - 20260805-termiod-hot-path-and-client-classes.md
  - remote-to-device.decisions.md
---

# Every machine is a device, every place you work is a project

> The fork is in the data model, not in the menu titles. Give the two planes
> different first-class nouns — **device** (`host_id`) below, **project**
> (workspace) above — retire "remote" as a UI word rather than as a string, and
> answer the one question the architecture leaves open: how the phone reaches a
> device without a Mac in the path.

This revision replaces the first draft wholesale. Two adversarial reviews
(`remote-to-device.review-claude.md`, `remote-to-device.review-codex.md`) landed
the same verdict — *the thesis is right and the draft does not deliver it; it
retires the word while leaving the fork intact and, after the rename, harder to
name.* Both are accepted. What follows is what the draft was missing: a naming
model, a decision on `sshHost`, a disposition for every shipped surface, and a
transport for iOS.

## 0. What was checked before rewriting

Every load-bearing claim in both reviews was verified against `main` at
`a3a6483`. All but three hold exactly as written.

| Claim | Verdict |
| --- | --- |
| Four SSH surfaces are missing from the draft: `New SSH Connection` (File + `+` + palette), `New SSH Shell`, Settings ▸ SSH, palette `New SSH Connection…` | **True** — `App.swift:1471`, `SidebarView.swift:613`, `SSHSettingsTab.swift`, `CommandPalette.swift:342` |
| PR #177 has merged; the staging paragraph blocking on it is false | **True** — `66b1722` on `main`; `termiod/` and `Sources/termio/Terminal/Termiod/` both present |
| `Session.sshHost` is a plain `ssh` in a *local* PTY; `termiodRemoteHost` is the durable path; the distinction is load-bearing in shipped code | **True** — `Models.swift:298,311`; `TermioStore+ProjectActions.swift:434-437` |
| `AddSSHHostSheet` already writes real `Host` blocks to `~/.ssh/config`, so "Add Device implies a second roster" is a strawman | **True** — `SSHSettingsTab.swift:279-282` |
| `closeConfirmationReason` gates on `ptyProcesses[session.id]`, so retiring `TERMIO_TERMIOD` silently deletes the running-command confirmation on *every* device | **True** — `TermioStore+ProjectActions.swift:684-692`; `hasForegroundJob` exists only on `PTYProcess`, with no counterpart in `termiod/src` |
| `ensureRemoteReady` deploys by cross-compiling a musl binary with `cargo` on the user's Mac | **True** — `termiod/src/remote.rs:236-275`, down to the `brew install …musl-cross` hint |
| Colour is already spent in the sidebar (orange = needs you, green = done) and in the SSH tab's badge | **True** — `SidebarView.swift:1393-1395`, `SSHSettingsTab.swift:263-268` |
| `New Remote Terminal` and `Clone on Remote` are unlocalized bare strings; `New Terminal at Home` / `New SSH Connection` are in the catalogue | **True** — zero hits in `Localizable.xcstrings` for the first two, one each for the last two |
| `New SSH Connection ▸` ends in `Add Host…`; `New Remote Terminal ▸` dead-ends on a disabled row | **True** — `App.swift:1639` vs `App.swift:1650-1655`, `SidebarView.swift:797` |
| The draft's citation "`~/.ssh/config` … read it, **never write it**" | **False as a citation.** `CLAUDE.md` #3 says *never override it*. The substitution retroactively made a shipped feature a violation. Corrected in §3 |
| "Accent-coloured control backgrounds are forbidden" as a repo-wide invariant | **Overstated.** The themed sidebar deliberately fills the selected row with the theme accent (`SidebarView.swift:1355-1371`). The real rule is narrower: no accent fill behind a *button or toggle*. Moot here — §1 removes device colour entirely |
| "list works, terminal unauthorized" was caused by a stale tunnel URL | **False.** Root cause was `resize` frames overtaking `auth` (`docs/bug/companion-terminal-unauthorized-over-tunnel.md:9-37`); tunnel churn was contributory. The lesson that survives — two independent connections reporting incompatible truths — is why §5 gives readiness one owner |

**A fifth "remote" surface neither review named:** the sidebar carries a whole
**section header literally titled `"Remote"`** (`SidebarView.swift:263`,
hardcoded and unlocalized), holding one `.host` block per machine. That is not a
menu verb — it is device-as-hierarchy, shipped. It is the single largest thing
this RFC retires, and the draft did not mention it.

## Already decided — do not reopen

| Decision | Where |
| --- | --- |
| A device's identity is its `termiod` `host_id`, not an SSH alias | device architecture §0.2 |
| Alias and `deviceID` **coexist**; the alias is the bootstrap identity, the device id the stable one, backfilled on first `hello_ok` | device architecture §9.5 |
| Workspaces belong to the device, not to a viewer | device architecture §2.2 |
| The host describes state; it never decides presentation | device architecture §4 |
| Raw PTY bytes are teed; nothing per-frame sits between PTY and pipe | protocol §A, §H #3a |
| Never embed SSH or crypto; the user's `~/.ssh/config` is authoritative — read it, **never override it** | `CLAUDE.md` #3, protocol §H #8 |
| A viewer connects to the device it is showing, never through another viewer | device architecture §2.1 |
| One protocol, versioned, transport-agnostic — no second protocol for the phone | protocol §H #9 |

That SSH row was previously paraphrased here as "never write it", which is
stricter than the rule actually says (`CLAUDE.md:43-44`). The distinction is
load-bearing: appending a user-authorised `Host` block does not override
anything, which is what keeps the shipped **Add Host** legitimate.

---

## 1. Two planes, two nouns

The draft failed because it used one noun — *device* — for both the thing the
code keys state by and the thing the user works in. Those are different, and
naming them the same forces the interface to expose the storage layer.

**Below, the first-class noun is the device.** State is keyed by `host_id`
because keying by alias silently splits the day the user changes networks:
`vps-lan`, `vps-wan`, and a tailnet name are three names for one machine
(architecture §2). Nothing in this plane is negotiable; it is already built
(`TermiodDeviceRegistry`, `devices.json`).

**Above, the first-class noun is the project.** A project is a workspace —
`(device, path)` — because the unit of work is a repository, not a machine.
Nobody opens a laptop wanting *the laptop*; they want the checkout.

That gives the rule the draft was missing:

> **"Remote" should not exist as a UI word, and neither should "device" as a UI
> level.** There is no *Remote Project*. There is a project, which lives on some
> machine, and this Mac is one of the machines. The machine is an **annotation
> on the project**, not a tier above it. This Mac is not annotated; everywhere
> else is.

### 1.1 What that deletes

Each of these was in the first draft or is in shipped code. The conceptual model
above removes all of them, which is what makes this a net deletion rather than a
new layer on top of two old ones (review-claude §1.4).

| Deleted | Why |
| --- | --- |
| The `"Remote"` sidebar section and `ProjectKind.host` | A machine is not a peer of a folder. Its projects go in Projects, its loose shells in Terminals, each annotated with the machine |
| **"Current device"** and the switcher | With projects annotated, the target of new work is already named by the project you start it from. There is nothing left for a current device to scope |
| The always-visible device indicator | It existed to answer "which machine am I about to type on". The project row answers it, in the place the user is already looking |
| Device colour, and the palette/collision/assignment questions under it | Colour in the sidebar means workstream status (orange = needs you, green = done). A second colour system next to it degrades the one signal the product claims as its own. The device is text |
| A device column on a cross-device session list | Same information, and it competes with the session label in a 220–360 pt column |

The switcher's removal is worth being explicit about, because it dissolves the
review's second-largest blocking finding without answering it. Codex asked for a
transition table proving the indicator, the focused terminal, the panels, the
title bar, and the creation verbs can never name different machines
(review-codex §2). **They cannot disagree if only one of them holds an opinion.**
The focused session names its project; the project names its device; every panel
and every creation verb reads through that single chain. ⌘T means "another
terminal here", and *here* is a workspace, exactly as today.

### 1.2 The three things a device still needs a direct entry for

Device does not vanish from the interface — it stops being a *navigation* level
and becomes an *administrative* one. Three scenarios, and only three:

| Scenario | Where it lives |
| --- | --- |
| Add a machine (a route not used before) | `New Terminal on…` ▸ `Add Host…` / free-form entry (§4) |
| Open a bare terminal on a machine — no project involved | `New Terminal on…` ▸ the machine (§4) |
| See whether a machine is ready, what it runs, forget it | Settings ▸ Machines (§4.2) |

Where the word is needed in the interface, it is **machine**, not device.
"Device" stays the data-model and protocol noun. Two reasons, both concrete:
Settings ▸ Devices would sit next to the shipped Settings ▸ Mobile, where a
paired iPhone is obviously "a device" (review-claude §7); and the peer-client
model says a phone is a viewer, not a session host, so the tab that lists
session hosts must not use the word that reads as "my Apple devices".

---

## 2. Where the fork actually lives, and how it dissolves

The reviews are right that the fork is `Models.swift:298` vs `Models.swift:311`,
and that the draft's six-word disposal of it ("**removed**; such a session is a
device session") deleted a working feature by accident.

| | `Session.sshHost` | `Session.termiodRemoteHost` |
| --- | --- | --- |
| What runs | `ssh <host>` in a **local** PTY | a session inside the **remote** `termiod` |
| Survives detach | no | yes |
| Needs `termiod` on the box | **no** | yes |
| Verbs today | `New SSH Connection`, `New SSH Shell` | `New Remote Terminal` |

The draft treated these as two roads to one place. They are not. Keeping both as
named verbs makes the fork *less* legible after the rename (`New Terminal` vs
`New SSH Shell`, with nothing in either name saying which survives a detach).
Deleting `sshHost` walls off every machine where `termiod` cannot be installed —
no write access, an unsupported arch, a container, a router, a colleague's box.

**Both horns are avoidable, because the second field is not a location at all.**

> A plain-`ssh` session is **a session on this Mac whose command happens to be
> `ssh`**. Its PTY is here. It is exactly as durable as any other session on this
> Mac. `sshHost` is not a second answer to *where does this run* — it is a
> **spawn spec**, the same class of field as `spawnDirectory`.

That is not a redefinition to win an argument; it is what the code does today
(`addSSHSession` sets `session.sshHost` and spawns a local PTY). Reading it
correctly collapses the fork with nothing deleted:

- **One field answers "where does this run": `deviceID`.** For an `ssh` shell,
  that is this Mac. For a durable session, it is the box.
- **`termiodRemoteHost` is demoted to a route hint** — the alias used to reach
  the device before the handshake named it. `deviceID` is the truth (§9.5's
  bootstrap-vs-stable identity, unchanged).
- **The escape hatch survives.** A machine that cannot run the daemon is still
  reachable, by exactly the mechanism that reaches it today.
- **The verb disappears without the capability disappearing** (§4): running
  `ssh vps` is something the user can type into any terminal, so a menu item for
  it is a shortcut, not a product concept, and it does not deserve a top-level
  slot beside the machine roster.

### 2.1 Data model after

| Field | Now | After |
| --- | --- | --- |
| `Session.deviceID` | backfilled on first handshake | **the** location field, for every session including local ones |
| `Session.sshHost` | implies "this session is elsewhere" | kept, demoted to a spawn spec: argv is `ssh <value>`; `deviceID` is this Mac |
| `Session.isSSH` (`sshHost != nil`) | used as "is remote" | removed. Nothing may branch on it; the durability question is answered by the device's daemon, not by argv |
| `Session.termiodRemoteHost` | source of truth for where a session runs | route hint only; removed once `deviceID` is populated for every persisted session |
| `Project.kind == .host` | a machine container in the sidebar | retired (§1.1). Its projects become workspaces with a `deviceID`; its bare shells become Terminals entries with a `deviceID` |
| `Project.deviceID` / `remoteCheckouts` | device-keyed already | unchanged |

**Migration of saved state**, because tolerant decoding is not a migration
policy (review-codex §4):

1. A session with `termiodRemoteHost` and no `deviceID` keeps working: the alias
   is a route, `deviceID` backfills on the next handshake, exactly as today.
2. A session with `sshHost` and no `termiodRemoteHost` is assigned this Mac's
   `deviceID`, and its title changes from `SSH Shell` to `ssh <alias>` — which is
   what it is, and what the user would have typed. **It is never silently
   upgraded** to a durable session: that would install software on a box the user
   did not ask to install on, and change durability under a running shell.
3. A `.host` container is dissolved on load: sessions move to the Terminals
   section (bare shells) or to the workspace named by `remoteCheckouts` (clones),
   carrying the container's `deviceID`. Containers that the user renamed keep the
   name as the workspace's display name.

---

## 3. Authorities, not provenance

The draft's ownership test — *did termio produce this state itself?* — was
attacked from both sides and does not survive. It cannot classify its own table
(a probe *observes* readiness rather than producing it; the user, not termio,
produces a typed target), and it was used to reject `Add Device…` on a ground the
codebase disproves. Replace it with explicit authorities:

| State | Authority | Where it lives | Rule |
| --- | --- | --- | --- |
| SSH route configuration | `~/.ssh/config` | the user's file | termio reads it and never overrides it. `Add Host` appends a real `Host` block, indistinguishable from a hand-written one — that is not a second roster, it is a write to the authoritative file, and it is already shipped |
| Which device a route reached | termio's registry | `devices.json` | An **observation cache**, never a route source. Every route is re-resolved against the live config before it is offered or dialled; an alias no longer in the file is not offered |
| Readiness (reachable / version / daemon present) | runtime probe | memory only | Never persisted. Already true — `lastSeen` is deliberately excluded from `Codable` |
| A typed `user@host` | the user | **ephemeral** | Used for the connection at hand and not persisted. If the user wants it back, `Add Host…` writes it to `~/.ssh/config`, which is the only place a route may live |
| Display name of a machine | the viewer | client state | The host never supplies a display name (§4 presentation boundary) |
| Sessions, workspaces, processes, workstream status | the device's `termiod` | on the device | Viewers cache, never own |

Two corrections follow directly:

- The `Already decided` row that read "read it, **never write it**" was a
  misquote of `CLAUDE.md` #3 (*never override it*). Writing a `Host` block the
  user asked for is not overriding anything; overriding would be injecting `-o`
  options that outrank their config, which the ControlMaster injection already
  guards against by probing `ssh -G` first (protocol §D).
- Persisting a typed `user@host` in termio state is the one genuine second-copy
  violation the draft contained. It is removed above.

---

## 4. Every shipped surface, and where it goes

Six surfaces name the road today. All six are accounted for; the net change is
**minus two verbs**, not a rename.

| Surface | Today | After |
| --- | --- | --- |
| `New Remote Terminal ▸` (File menu, `+` menu, sidebar project rows) | one row per alias, dead-ends on `(No SSH hosts…)` | becomes **`New Terminal on…`**, the one machine-reaching verb (§4.1) |
| `New SSH Connection ▸` (File menu, `+` menu) | one row per alias + `Add Host…` | folded into `New Terminal on…`. Its `Add Host…` row survives as that submenu's last row — it is the escape the other submenu never had |
| `New SSH Shell` (host header) | plain `ssh` in a local PTY | the header is gone with `.host`. The capability survives in two places: the named fallback when a machine cannot be readied ("Open an SSH shell instead"), and a row action in Settings ▸ Machines |
| Command palette `New SSH Connection…` | opens the connect panel | becomes `New Terminal on…`, one entry, same panel |
| Settings ▸ SSH | `~/.ssh/config` aliases, per-host probe, Add Host, Edit config | becomes **Settings ▸ Machines** (§4.2), same file as its source, plus what the handshake learned |
| Sidebar `"Remote"` section + `.host` blocks | device-as-hierarchy | retired (§1.1). Projects and Terminals carry a machine annotation |
| `Clone on Remote… ▸` (sidebar project rows) | `git clone <origin>` **on** the box | **`Clone on <machine>…`** — keep the preposition. Nothing is copied from the Mac and unpushed work does not travel; "to" invites exactly the mistake the click-time `cloneInfo` warning exists to catch |

### 4.1 `New Terminal on…` — one verb, specified

One item, in the slot `New Remote Terminal` occupies today (directly under
`New Terminal at Home` in the `+` menu, which is context-free by rule, and the
same position in the File menu). The submenu, in order:

1. **Machines with a recent session**, most recently used first, by display name.
2. **Routes from `~/.ssh/config` not yet resolved to a machine**, alphabetical,
   under a separator.
3. `Add Host…` — the shipped sheet, which writes the block and then connects.
4. `Other…` — free-form `user@host`, ephemeral (§3).

Above ~12 rows the submenu is truncated to the 10 most recent with a
`More…` row opening Settings ▸ Machines, which has a search field. A flat map of
every alias — which both `remoteTerminalMenuItem` and `cloneOnRemoteMenuItem` do
today, synchronously on every right-click — is unusable for a config with
`Include`d work hosts.

Two properties this must state rather than imply:

- **Section 2 is necessarily imprecise.** Aliases outnumber machines, and which
  alias resolves to which device is only known after connecting. Some untried
  rows will turn out to be a machine already listed above. That is inherent in
  bootstrap-vs-stable identity (§9.5), not a defect to design around; it heals on
  first handshake.
- **Picking a machine here creates a session there and nothing else.** It does
  not set a mode, and there is no mode for it to set (§1.1).

**Prebuilt binaries are a hard prerequisite for this verb.** Today a machine
without the daemon triggers `termiod remote deploy`, which cross-compiles with
`cargo` on the user's Mac and tells them to `brew install musl-cross` when the
linker is missing. For a shipped `.app` that is not an install path; it moves the
draft's own "dead end at the moment a new user arrives" one click later.
Architecture §8.8 (prebuilt per-arch binaries, content-addressed install) is
scheduled below as a stage-0 item, not a later nicety.

### 4.2 Settings ▸ Machines

One list, replacing Settings ▸ SSH. A row is a machine where one is known and a
route where it is not — the same imprecision as §4.1, made visible instead of
being split across two tabs:

| Column | Source |
| --- | --- |
| Name | user-set, else the most recently used alias |
| Routes | `~/.ssh/config` (live), ordered most recently used first |
| Readiness | runtime probe, on demand (§5) |
| `termiod` version | `hello_ok` |
| Actions | Connect · Open SSH shell · Install / upgrade `termiod` · Forget · Merge (§9.5) · Edit `~/.ssh/config` · Add Host |

The tab is shown when there is more than one machine or when the local daemon is
unhealthy. It is **never hidden by an error** — codex is right that the
one-machine user is the one most likely to have no alternative when the local
daemon fails (review-codex §6). The promise is *no steady-state tax*, not
literal absence.

**Against one list: the coexistence decision.** `remote-to-device.decisions.md`
§1, written against the first draft, decided the opposite — that
`Settings ▸ SSH` and `Settings ▸ Devices` **coexist**, split at the handshake:

> `Settings ▸ SSH` owns **routes** — anything meaningful *before* `hello_ok`,
> keyed by an SSH alias, or affecting how OpenSSH resolves and authenticates.
> `Settings ▸ Devices` owns **identities** — anything learned *after*
> `hello_ok`, keyed by `host_id`, or describing termiod, device lifecycle and
> device preferences. A value is never persisted in both.

Its argument is that an alias can exist before any device is known and one
`host_id` can be reached through several aliases, so a single list must either
invent device rows for unresolved routes or hide a second route model inside each
device — the two-copies problem under one tab. Its accepted cost is that two tabs
read as competing machine lists.

This revision keeps the key rule and rejects the split. **The rule survives as a
field-placement test** — routes are re-resolved from `~/.ssh/config`, identities
live in `devices.json`, and no value is persisted in both (§3) — but a rule about
where a *field* lives does not require two *tabs*. The unresolved-route case is
not invented away here: §4.1 and the table above state it plainly, a row is a
machine where one is known and a route where it is not, which is the same
imprecision the coexistence decision routes around by hiding it in a second tab.
One list makes it visible once instead of asking the user to learn which tab a
machine is currently in.

One divergence must be recorded rather than absorbed: the decisions doc also says
**"Add Host. Remove it."** That is answered by §0 — `AddSSHHostSheet` ships and
appends a real `Host` block, `CLAUDE.md` #3 says *never override*, not *never
write*, and the decisions doc's own RFC edit says "Add Host stays in SSH". Add
Host stays, in the Machines tab.

---

## 5. Readiness — one vocabulary, named once

Three states exist in the SSH tab, a fourth is promised by architecture §8.6, and
the draft had none. Name them here and reuse the shipped copy and tints
(`SSHSettingsTab.swift:251-275`):

| State | Meaning | Copy |
| --- | --- | --- |
| `notChecked` | no probe since launch — the default for every machine | "Not checked" |
| `reachable` | handshake completed | "Reachable" |
| `authFailed` | SSH refused the identity | "Auth failed" |
| `unreachable` | no route answered; carries ssh's own last stderr line | the reason itself |
| `degraded` | connected, but the link is repairing or the daemon is a version behind | "Reconnecting" / "Older termiod" |

Rules:

- **No eager probing.** Reaching every known route at launch puts 216–292 ms of
  cold SSH per machine on the startup path. Twenty machines start at
  `notChecked`, and that state is rendered honestly rather than as an absence.
- **Readiness has exactly one owner: the device's `TermiodConnection`**
  (architecture §5.1 / §8.4b). This is why that step is a prerequisite and not a
  parallel track — two connections reporting independently is the shape of the
  companion bug in §0.
- **A transport failure is never rendered as `exited`.** The protocol already
  says so normatively (architecture §5.1); with no connection object there is
  nowhere for `degraded` to live, which is why the draft had no word for it.

---

## 6. Guardrails: rescue the one that exists

The draft asked how heavy a confirmation should be for destructive actions on a
non-local device. Wrong question, and it has the polarity backwards.

`closeConfirmationReason` confirms on exactly one condition: a plain shell with a
live foreground job, because that command exists nowhere else. It reads
`ptyProcesses[session.id]` — the **in-process** PTY handle. A termiod session has
no entry there. So **today a session with a build running on another machine
closes silently, and a local one asks.**

Two consequences, both scheduled:

1. **`termiod` must report the foreground job** — one `tcgetpgrp` on the PTY
   master, one field on the `list` reply. Then the rule the product already
   believes in works on every device, which is this RFC's whole thesis applied to
   a guardrail.

   It rides as an **optional additive field** on the existing session payload and
   needs no `proto` bump: the protocol already treats unknown control ops and
   events as ignorable, and its `caps` and error codes as additive
   (`remote-to-device.decisions.md` §2). **Skew rule:** an older daemon that omits
   the field preserves today's no-confirm behaviour. It must never be read as
   "unknown, so confirm", which would tax every close on exactly the sessions the
   shipped rule deliberately exempts. Both directions — old client / new daemon
   and new client / old daemon — are tested.

   Accepted cost, stated in the decisions doc and not reduced here: this turns a
   vocabulary-and-UI RFC into a shipped Rust/Swift protocol change carrying
   version-skew semantics. Splitting it out would not remove the dependency, only
   let the convergence plan claim a parity it does not have.
2. **That field is a precondition for deleting `TERMIO_TERMIOD`.** Retiring the
   flag deletes the in-process path, `ptyProcesses` becomes permanently empty,
   and the confirmation silently disappears **for every session on every device,
   including purely local ones** — with no code change at the call site to catch
   it in review. This is the single most dangerous item in the whole migration
   and it appeared in no staging list before this revision.

**Confirmation is keyed on irreversibility and blast radius, never on locality.**
"Not this machine" is a Mac-centric predicate that fails on iOS, where every
session host is another machine. Forget Machine and Uninstall `termiod` with live
sessions confirm because they are irreversible and device-wide; they name the
machine in the message. termio never interposes on ordinary shell commands.

---

## 7. How iOS reaches a device directly

Architecture §2.1 requires a viewer to connect to the device it is showing and to
no one else. This is the one place that rule has no answer, and it is the second
block this RFC exists to add.

**Rejected first, so the rest is not read as a compromise:** the Mac as a
transparent relay for the phone. It satisfies the letter of the topology while
keeping a Mac awake and on the path — which is the thing being removed, and which
the companion tunnel has spent a year failing at.

### 7.1 §H #8, read by intent

*"Never embed an SSH or crypto library"* cannot be executed literally on iOS:
there is no system OpenSSH to shell out to, and an in-app SSH client has been
built and removed twice. The rule's intent is what transfers: **borrow the
operating system's existing trust layer instead of writing one.** On the Mac that
layer is OpenSSH; on iOS it is the tailnet's WireGuard, or the system TLS stack.

### 7.2 Preferred: bind to the tailnet

`termiod` gains a bind option that accepts a specific interface, and the
recommended configuration is **the tailscale interface only**.

- Encryption and node identity are WireGuard's. termio writes no cryptography and
  ships no PKI.
- No public port exists. The daemon is unreachable from the internet at all;
  reachability is the tailnet ACL, which the user already administers.
- The phone dials `100.x` directly. One hop, no Mac.
- Roaming may come free: WireGuard peers are keyed by public key, not endpoint,
  so a TCP connection carrying `termiod stdio` should survive Wi-Fi → 5G with the
  overlay address unchanged. Protocol §D.1 already flags this as the experiment
  that decides whether QUIC is a roadmap item or a someday item; it is the same
  experiment. **Verify before relying on it.**
- Discovery composes with the provider interface architecture §2 already
  specifies: `tailscale status --json`, read-only, no account in the protocol.
  (Superlogical productises the same step — **Announced:** *"Servers can
  automatically join a tailscale … and clients can automatically find them with
  one config."* Their wire protocol remains **Unknown**; nothing here copies it.)

This path needs no change to §H #4 at all, which is the strongest argument for
preferring it.

### 7.3 Fallback: system TLS, pinned fingerprint, pairing token

For a user with no tailnet, a device may run a listener bound to a **specific
interface** with:

- **TLS from Network.framework / rustls-with-system-roots** — the system's own
  TLS implementation. Calling this "embedding crypto" would also condemn using
  `URLSession`; the rule forbids *writing* or *vendoring* a crypto stack, not
  using the platform's.
- **A self-signed certificate, TOFU-pinned at pairing.** This is structurally
  identical to `known_hosts`, which is SSH's own answer to the same problem, and
  it is what protocol §D.1 already reserves for the QUIC binding's identity
  ("pairing-pinned host cert (TOFU like SSH). **No DIY PKI**"). §D.1 wrote it as
  *later, if earned*; this is the requirement that earns it.
- **A per-device bearer token**, scoped to one device, revocable, presented on
  every connection — the companion model, which already ships.

Certificate pinning plus a token, over the system TLS stack, is the same trust
shape SSH gives us on the Mac: a fingerprint the user vouched for once, and an
identity that proves possession.

### 7.4 Pairing bootstraps from a trust path that already exists

Pairing is where the Mac is allowed to help, because it is a **one-time control
action, not a data path** — it does not put the Mac between the phone and the
device, and therefore does not violate §2.1.

```
Mac ──ssh──▶ device : termiod pair issue
             device ──▶ token + cert SPKI fingerprint + reachable addresses
Mac  renders QR  ──▶  iPhone  ──▶  Keychain
iPhone ──────────────── direct ────────────────▶ device
```

After the scan the Mac is out of the path entirely, including when it is asleep
or off. The QR carries the device's `host_id` too, so the phone keys its pairing
by device identity rather than by address, and a changed address heals without a
re-scan — the failure the companion tunnel produces on every cloudflared restart
today.

Listeners are **off by default**. A device accepts nothing on any network
interface until a pairing explicitly turns one on, and `termiod pair revoke`
turns it back off.

### 7.5 The §H #4 amendment, written out

Protocol §H #4 currently reads *"Public `0.0.0.0` bind / raw TCP + DIY TLS — Unix
socket and SSH only until QUIC arrives with borrowed identity."* Taken literally
it forbids §7.3. It must be **amended explicitly**, not quietly worked around:

> **4. Public `0.0.0.0` bind, DIY TLS, or any invented crypto** — still rejected,
> without exception. A listener MUST bind a named interface (a tailnet or
> loopback), never a wildcard address; TLS MUST come from the platform's own
> stack; and the trust anchor MUST be borrowed — a tailnet's node identity, or a
> self-signed certificate pinned during an out-of-band pairing, as SSH's
> `known_hosts` does. No certificate authority, no key exchange, and no cipher
> code is written or vendored by termio. Any listener is off until a pairing
> enables it and off again when that pairing is revoked.

What stays forbidden is unchanged: wildcard binds, hand-rolled TLS, invented key
exchange. What becomes permitted is exactly what the phone needs and nothing
more. §7.2 does not touch this rule at all.

### 7.6 Backgrounding makes resumable subscriptions mandatory

iOS suspends a backgrounded app; the socket dies every time the user switches
away. **For the phone, reconnect is the steady state, not the exception.** That
promotes two things from polish to prerequisite:

- **§C.10 resumable subscriptions.** Every resource re-subscribes at its last
  applied `seq` and the device answers with continuity or an explicit `gap`. On
  the Mac this saves a rescan; on the phone it is the difference between
  reattaching and rebuilding the world several times an hour. Cursors already
  survive the client, not just the connection — that property was written for
  exactly this case.
- **Attach-with-cursor and `S` bootstrap on every foreground.** The phone is a
  **Replica** (client-classes §D.3): it runs libghostty and receives raw `D`.
  Being on cellular must not select `grid_diff` — §D.4 forbids choosing a client
  class from transport class, and a Mirror has no native scrollback or selection,
  which is precisely what a phone user reaches for.

**APNs wake is viable on iOS**, unlike the Mac — a slept Mac cannot be woken by a
push, which is why the companion has no answer there, but a suspended iPhone can
be. A `needs-you` workstream on a device the phone has paired with is the event
worth waking for. One question is open and named in §10: a push needs an
Apple-issued credential, and termio runs no hosted control plane, so *who signs
the push* is unresolved. Everything above works without it; APNs only decides
whether the phone learns about `needs-you` while closed.

### 7.7 What the device must gain first

A phone talking to a Linux box needs to ask *what projects are here*. Today the
project tree lives in the Mac's `StateFile`, so the only place to ask is a Mac —
the hop §2.1 removes. **Workspaces on the device (architecture §8.11) is a
prerequisite for iOS-direct**, and it is the same work that makes "open a project
on another machine" a normal action on the Mac.

Order within this block: bind + pairing (§7.2–7.4) → the §H #4 amendment (§7.5) →
resumable subscription hardening on the phone (§7.6) → workspaces on the device
(§7.7) → the phone speaks this protocol and the companion wire is deleted
(architecture §8.12). Until that last step the companion wire remains a second
protocol and a live violation of §H #9; it is scheduled for deletion, not carried
as an exception.

---

## 8. Staging, and how each step is verified

The draft's ordering was reversed against architecture §8. Corrected: the fork
dies before the vocabulary changes, and the connection object comes before both.
The architecture doc orders the work — own the connection → delete the fork,
including `TERMIO_TERMIOD` → device switcher — and marks the switcher *"Only
meaningful after step 5 — before it, local is still a special case"*
(`20260805-termiod-device-architecture.md:513-531`). That document is listed
above under "do not reopen", so the RFC cannot contradict its ordering.

The reversal is not academic. `Termiod.isEnabled` reads the flag
(`TermiodClient.swift:17-20`) and surface creation still chooses between termiod
and an in-process `PTYProcess` (`TermioStore+TerminalSurface.swift:214-231`), so
with the flag off, opening on a non-local device stops at an alert reading *"Set
TERMIO_TERMIOD=1 and relaunch termio"* (`TermioStore+Termiod.swift:468-476`). Any
device-naming surface above that fork names a machine the product cannot open a
session on.

### Stage 0 — prerequisites (no UI change)

| Step | Verification |
| --- | --- |
| **0a.** Prebuilt per-arch `termiod` binaries, content-addressed install (arch §6, §8.8) | From a packaged `.app` on a Mac with no `cargo` and no `musl-cross`, add a fresh Linux box and reach a prompt. A local dev build is not evidence |
| **0b.** ControlMaster options on the app's own ssh invocation, plus `BatchMode` / `ConnectTimeout` (arch §8.4a) | Cold vs warm connect timings on one box; an unloaded key must produce a named error instead of a silent hang |
| **0c.** `TermiodConnection` per device owning health and reconnect (arch §8.4b) | Pull the network with a session attached: the pane shows `degraded`, never `exited`, and recovers without losing scrollback |
| **0d.** Foreground-job field on the `list` reply (§6) | Start `sleep 60` in a session on another machine, close it: the confirmation appears with the same copy as a local one |

### Stage 1 — delete the fork

Remove `TERMIO_TERMIOD`, the in-process `PTYProcess` path, and the alert that
today stands in for a remote terminal when the flag is off (arch §8.5).

*Verification:* every session on this Mac survives quitting and relaunching the
app; `ptyProcesses` no longer exists; the close confirmation still fires (0d is
what makes this true, and its absence is what would make this step silently
destructive).

### Stage 2 — data model

`deviceID` as the single location field; `sshHost` demoted to a spawn spec;
`termiodRemoteHost` demoted to a route hint; `.host` containers dissolved; the
`isSSH` branch deleted (§2.1).

*Verification:* a state file written by the current release loads with every
session in the right place — durable sessions under their workspace, `ssh`
shells under Terminals — with no `.host` container left and nothing lost. Test
against a real pre-migration `state.json`, not a synthesized one.

### Stage 3 — vocabulary and menus

`New Terminal on…` replacing two verbs, `Clone on <machine>…`, the palette entry,
the retired `"Remote"` section header, the machine annotation on project and
terminal rows.

*Verification:* `grep -ri "remote" Sources/termio --include=*.swift` returns only
`remoteCheckouts` and comparable identifiers — no user-visible string. Every new
or changed string is in `Localizable.xcstrings` and in the zh-Hans catalogue; the
three strings this touches were never localized, so this stage carries l10n work
the draft called "client-only, no persistence change".

### Stage 4 — Settings ▸ Machines

Subsume the SSH tab; readiness states (§5); forget; install/upgrade; merge
(§9.5).

*Verification:* with `~/.ssh/config` edited outside the app, the list reflects the
edit on next open and a removed alias is no longer offered anywhere. Forgetting a
machine with live sessions warns and names it.

### Stage 5 — iOS direct

§7, in the order given there.

*Verification:* with the Mac powered off, the phone opens a session on a Linux
device, backgrounds for ten minutes, returns, and resumes the same session with
scrollback intact and no full rescan. Then the same over a network flip.

---

## 9. Scale

**One machine.** No Machines tab in steady state, no annotations, no machine
submenu beyond `Add Host…`. What that user genuinely pays — and the draft never
listed — is stage 1: their local terminal moves from an in-process PTY to a
daemon over a Unix socket. That means a launchd agent someone must decide when to
install (architecture §8.3 deliberately never installs it automatically), a new
single point of failure where the app previously shared fate with its PTYs, and
tombstone UI where a PTY used to die quietly with the app. Those are the cost of
the direction, they are worth paying, and they belong in the plan rather than in
a promise that "someone who never leaves their laptop never pays for this."

**Twenty machines.** No colour to collide (§1.1). Submenus bounded at 10 by
recency with `More…` into a searchable list (§4.1). No eager probing; twenty rows
at `notChecked` (§5). Attention routing stays where it already works — the
session rows themselves, which are cross-device by construction now that a
project carries its device — so there is no single badge to become a generic
alarm. Stale machines are forgettable, and a machine with no sessions, no live
route, and no alias left in `~/.ssh/config` does not count toward "more than one".

---

## 10. Open questions

1. **Who signs the APNs push** (§7.6). termio runs no hosted control plane and an
   Apple key cannot ship inside `termiod`. The narrowest shape that might fit is a
   stateless forwarder that sees an opaque device token and a wake flag and stores
   nothing — which is still a service, and must be argued on its own terms rather
   than smuggled in here.
2. **Does the tailnet supply roaming** (§7.2), i.e. does an attached session
   survive Wi-Fi → 5G on the overlay address? One experiment, and it also decides
   whether QUIC is a roadmap item.
3. **What annotates a project row** — the machine's name always, or only when
   more than one machine is in play. The rule in §1 says this Mac is not
   annotated; whether a second machine's name appears on every row or only in the
   header is a layout call that wants a real sidebar in front of it.
4. **Merge on the same Mac** (§9.5, §9.1): the dev and release channels are two
   `host_id`s on one machine, so merge is not only a cross-route feature. Not
   reopened here; noted because Settings ▸ Machines is where it surfaces.

### 10.1 The first draft's questions, and where each went

The pre-rewrite draft carried seven. None is silently dropped; two were settled in
`remote-to-device.decisions.md` and the rest are answered by the model in §1.

| Draft question | Disposition |
| --- | --- |
| 1. Colour assignment — auto-assign from a palette or let the user pick | **Dissolved.** §1.1 removes device colour entirely; sidebar colour means workstream status and nothing else |
| 2. How far colour bleeds — chrome only, or the whole space | **Dissolved** with it. The presentation boundary still stands: the viewer decides, and nothing tints the grid |
| 3. Guardrail strength on a non-local device | **Closed, and the question was wrong.** All three proposals were the local/remote fork wearing a warning triangle. §6 keys confirmation on irreversibility and blast radius, never on locality, and names the live defect: today the non-local session has *less* protection, not more |
| 4. Does `Connect to…` belong in the `+` menu | **Answered by §4.1.** There is no `Connect to…`; `New Terminal on…` takes the slot `New Remote Terminal` occupies today, and the dead-end `(No SSH hosts in ~/.ssh/config)` row it complained about is replaced by `Add Host…` and `Other…` |
| 5. Does `Settings ▸ Devices` subsume `Settings ▸ SSH` | **Decided coexist** in `remote-to-device.decisions.md` §1; §4.2 keeps that decision's key rule as a field-placement test and argues one tab instead of two, with the divergence and the Add Host reversal recorded there |
| 6. Does foreground-job parity belong in this RFC | **Decided yes** in `remote-to-device.decisions.md` §2, and it gates the fork deletion. Carried as stage 0d (§8) with the additive-field and skew rules in §6 |
| 7. What does an unreachable device look like | **Answered by §5.** Five named states with shipped copy, no eager probing, and one owner — the device's `TermiodConnection` |

---

## 11. Vocabulary

| Dead | Replacement |
| --- | --- |
| New Remote Terminal | **New Terminal on…** — one machine-reaching verb |
| New SSH Connection | folded into the same verb; its `Add Host…` survives as that submenu's last row |
| New SSH Shell | no menu verb; a named fallback and a Settings row action (§4) |
| Clone on Remote… | **Clone on \<machine\>…** — the preposition stays; nothing is copied from the Mac |
| The `"Remote"` sidebar section | gone; projects and terminals carry a machine annotation |
| "remote session", "remote host", "remote project" | "a session on \<machine\>", "a project on \<machine\>" |
| "Remote Project" as a concept | a workspace, which lives on a machine, and this Mac is one |

**Scope of the retirement:** execution-topology nouns and verbs only. `git
remote`, `remoteCheckouts` as a field name, Apple's Remote Management, and remote
access as a description of what the phone does over a network all stay — they are
accurate in their own domains, and a lexical purge would make those strings
worse.
