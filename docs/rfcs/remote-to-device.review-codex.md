---
title: "Adversarial review: Retire remote — every machine is a device"
status: draft
type: rfc
created: 2026-08-15
updated: 2026-08-15
---

# Adversarial review: Retire remote — every machine is a device

> Request changes. This review accepts every decision in the RFC’s “Already
> decided” table and tests whether the proposed product model actually follows
> from them.

## Verdict

Do not approve the RFC as written. Removing the local/remote product fork is the
right direction, but the replacement currently introduces competing sources of
truth for routes, competing notions of focus, competing device selectors, and an
unresolved choice between plain SSH and device sessions. Those are the same
two-copies failure at different layers.

The most serious defect is staging. The settled architecture requires a durable
connection object, deletion of the `TERMIO_TERMIOD` fork, and only then a device
switcher (`docs/design/20260805-termiod-device-architecture.md:513-531`). This RFC
starts with the switcher, calls that stage client-only, and omits deletion of the
flag (`docs/rfcs/remote-to-device.md:163-176`). That ordering cannot produce a
truthful current-device UI.

## Where the design recreates two copies

| First copy | Second copy | Failure |
| --- | --- | --- |
| Live SSH routes from `~/.ssh/config` | Typed `user@host` targets persisted under Settings ▸ Devices | A port, jump host, username, or removal can change in the authoritative file while termio keeps using its own target. |
| The selected/focused session | An independent “current device” | The terminal can be on device B while the panels, title bar, and creation commands still claim device A. |
| The sidebar switcher | A device submenu under New Terminal | There are two places to choose the target, and no rule says which choice updates the other. |
| `New SSH Connection` and saved `Session.sshHost` state | `Connect to…` and a durable termiod device session | The same machine still has two terminal products unless the RFC explicitly removes, converts, or scopes plain SSH. |
| A learned device row | An unresolved SSH alias row | A second alias for an already-known device appears as another machine until its first handshake. That temporary ambiguity is inherent in the settled bootstrap identity, but the UI currently pretends the two lists are disjoint. |

The alias plus `deviceID` model is not the problem; that coexistence is settled.
The problem is promoting both sides into independent user-facing authorities.

## Blocking findings

### 1. The ownership test is false, and it selects the wrong authority

“Did termio produce this state itself?” (`docs/rfcs/remote-to-device.md:53-63`)
does not classify the RFC’s own table:

- The user produces a display name and colour choice.
- `termiod` produces its version.
- The user produces a typed `user@host` target.
- A probe observes readiness; it does not produce it.

Provenance is not authority. The useful split is narrower: SSH route
configuration belongs to `~/.ssh/config`; handshake observations belong to the
device registry; viewer presentation preferences belong to the viewer; device
state belongs to `termiod`.

The typed-target row is therefore an architectural violation, not an exception.
A `user@host` value is an SSH route. Persisting it in Settings creates the host
database that `CLAUDE.md:42-44` forbids. “It cannot be written to
`~/.ssh/config`” does not make termio its owner (`docs/rfcs/remote-to-device.md:71`);
it means the target must remain ephemeral or the design needs an explicit,
user-authored route mechanism consistent with the settled read-only rule.

There is already a second-copy hazard in the learned map. A `TermiodDevice`
persists routes while deliberately refusing to persist reachability
(`Sources/termio/Terminal/Termiod/TermiodDevice.swift:71-79`), and the registry
loads those routes back as candidates
(`Sources/termio/Terminal/Termiod/TermiodDevice.swift:167-203`). That observation
cache is valid. Treating a cached alias as an actionable route after it has been
removed or changed in `~/.ssh/config` is not. The RFC must say that every SSH
route is revalidated against the live config before selection or connection.

At 20 devices this becomes visible rot: removed aliases remain attached to old
devices, new aliases appear separately until contacted, and one physical machine
can occupy both the known-device section and the untried-route section.

### 2. “Current device” and focused session can disagree

The RFC says new work and panels follow the current device while running
sessions remain cross-device (`docs/rfcs/remote-to-device.md:125-140`). It never
defines what happens when the user clicks a session on another device.

Today there is one focus authority. Changing `selectedSessionID` saves and
restores that session’s inspector state
(`Sources/termio/TermioStore/TermioStore.swift:22-49`), and the file, search, and
git root derives from the selected session
(`Sources/termio/TermioStore/TermioStore.swift:391-410`). The proposed model has
two incompatible outcomes:

- If selecting a session on device B leaves current device A unchanged, the
  terminal and inspector describe different machines. New Terminal, Clone,
  file deletion, and title-bar colour can target or label A while the keyboard
  focus is visibly on B.
- If selecting that session changes the current device to B, “current device” is
  not an independent switcher choice. Merely inspecting an old session changes
  where the next terminal and project will be created.

The wording also drifts from “current device” to “focused device” at
`docs/rfcs/remote-to-device.md:144-146`. Those cannot remain informal synonyms.
The RFC needs a transition table for launch, switcher selection, session
selection, pane focus, Connect, route loss, closing the last session on a device,
and app restore. It must name which state controls terminal input, panels,
creation commands, the indicator, and the title bar after every transition.

The session-list description is internally inconsistent too: it first promises a
cross-device list with a device column, then says the attention badge avoids
“flattening every device into one list”
(`docs/rfcs/remote-to-device.md:133-142`). Pick one information architecture.

### 3. The staging order directly violates the settled architecture

The companion design deliberately orders the work as:

1. own connection health and reconnect per device;
2. delete the backend fork, including `TERMIO_TERMIOD`;
3. add the switcher, reading readiness from that connection object.

That order is explicit at
`docs/design/20260805-termiod-device-architecture.md:513-531`. The RFC reverses
it. Stage 1 adds the switcher and single-device collapse as a client-only change;
the flag is absent from every stage (`docs/rfcs/remote-to-device.md:163-176`).

The current source still has two execution paths. `Termiod.isEnabled` reads
`TERMIO_TERMIOD` (`Sources/termio/Terminal/Termiod/TermiodClient.swift:17-20`),
and surface creation chooses termiod or an in-process `PTYProcess`
(`Sources/termio/TermioStore/TermioStore+TerminalSurface.swift:214-231`). With
the flag off, `New Terminal` cannot open on a non-local current device at all;
the durable-device action currently stops with an alert
(`Sources/termio/Terminal/Termiod/TermioStore+Termiod.swift:205-241`). A switcher
above that fork is cosmetic fiction.

Retiring the flag is not a rename. It changes the execution path of every
session and makes the daemon a release-critical dependency. The current fallback
daemon path points into the working tree unless an environment variable overrides
it (`Sources/termio/Terminal/Termiod/TermiodClient.swift:55-63`), while the
architecture records that the launchd service is never installed automatically
and that Linux lifecycle work is incomplete
(`docs/design/20260805-termiod-device-architecture.md:502-512`). Packaging,
installation, startup failure, upgrade rollback, old-session adoption, and the
removal of the in-process fallback need their own stage and release criteria
before the UI claims there is one path.

### 4. The RFC does not decide the fate of plain SSH

The data-model table says `Session.sshHost` is removed and “such a session is a
device session” (`docs/rfcs/remote-to-device.md:153-161`). The vocabulary and
staging sections never say what happens to the shipped `New SSH Connection`
command. Today that command is separate from the durable termiod action
(`Sources/termio/App/App.swift:2127-2133`), and `Session.sshHost` specifically
means a local PTY running plain `ssh`
(`Sources/termio/App/Models.swift:290-311`).

Every outcome has a product consequence that needs a decision:

- Keep it: the local/device fork survives as plain SSH versus termiod.
- Convert it: clicking a familiar SSH verb can now install software and create a
  durable server-side session.
- Remove it: termio loses the escape hatch for a machine where `termiod` cannot
  be installed or negotiated.

Tolerant decoding only keeps old JSON readable. It does not define what a saved
plain-SSH session becomes after the field disappears. This is a semantic
migration and belongs in staging.

### 5. Unreachable is a first-class state, not an empty-state detail

The RFC defines identity everywhere and failure nowhere. A learned device can
have no valid route, an SSH alias can fail before handshake, an existing
connection can be reconnecting, and a daemon can be incompatible or absent.
Those states have different safe actions.

The architecture already requires a `TermiodConnection` that owns a coherent
“reachable / degraded / gone” state
(`docs/design/20260805-termiod-device-architecture.md:395-411`) and says the
switcher must consume it. The current registry cannot substitute: `lastSeen` is
intentionally cleared on launch so persisted data never claims current
reachability (`Sources/termio/Terminal/Termiod/TermiodDevice.swift:71-79`). The
current startup check also probes only this Mac, specifically to avoid an SSH
round trip to every known route
(`Sources/termio/Terminal/Termiod/TermioStore+Termiod.swift:155-164`).

The RFC must define at least what the user sees and can do when the current
device becomes unreachable, what happens to already-visible sessions and panels,
whether another route is tried, and how the user returns to a reachable device.
Without that, colour can keep confidently naming a device that the UI is no
longer showing.

The cited historical pain is real, but its attribution needs correction. The
“list works but terminal unauthorized” bug was caused by terminal `resize`
frames overtaking authentication
(`docs/bug/companion-terminal-unauthorized-over-tunnel.md:9-37`). The stale tunnel
URL was adjacent and contributory, but the bug reproduced with a fresh pairing
and one clean tunnel (`docs/bug/companion-terminal-unauthorized-over-tunnel.md:98-103`).
The lesson still applies: independent roster and terminal connections can report
incompatible truths, which is exactly why connection ownership must precede the
switcher.

### 6. Literal single-device collapse hides the only recovery surface

“No indicator, no submenu, no Settings tab”
(`docs/rfcs/remote-to-device.md:108-112`) is too strong once termiod is the only
PTY owner. A one-device user is the user most likely to have no alternative when
the local daemon fails. Hiding Devices also hides the RFC’s only home for install
status, version, and device-scoped maintenance
(`docs/rfcs/remote-to-device.md:65-70,119-123`).

The correct promise is no steady-state tax. Failure and maintenance still need a
reachable surface. The RFC also needs to define “one”: one learned identity, one
device with sessions, one currently reachable device, or this Mac plus no other
configured routes. A user who tried one VPS once and later removed its SSH alias
must not pay the multi-device UI forever merely because `devices.json` remembers
the handshake.

## Attack on the four proposed positions

### 1. Colour assignment: reject as stated

Deriving the default from `host_id` is deterministic, but it does not deliver the
stated guarantee that the same machine keeps the same colour. The settled
architecture says the identifier belongs to one daemon installation/socket:
the dev and release channels on one Mac are two devices, and a changed `TMPDIR`
can mint a new identity
(`docs/design/20260805-termiod-device-architecture.md:561-576`). A reinstallation
can therefore change the colour of the same hardware; a cloned identifier gives
two machines the same colour at exactly the moment they most need distinction.
That follows from the settled identity decision and does not reopen it.

A fixed palette also stops being identity at 20 devices. If it has fewer than 20
accessible swatches, repeats are guaranteed; even a larger palette cannot make
20 peripheral-vision colours reliably distinguishable. A user override stored
only on one viewer also defeats the cross-Mac consistency this proposal is meant
to buy.

There is a smaller specification contradiction: “assign on first handshake”
implies persistence, while “derived deterministically” does not need assignment.
If the result is persisted to survive palette changes, define algorithm/version
and override precedence. If it is recomputed, changing the palette or hash
mapping changes existing identities.

Use a deterministic colour only as a default decoration. It cannot be the
identity or the safety mechanism; a text label and non-colour state cue must
remain authoritative.

### 2. Colour bleed: the grid conclusion survives; the rationale does not

The presentation boundary says the host cannot resolve viewer presentation. It
does not say which parts of a viewer may use colour
(`docs/design/20260805-termiod-device-architecture.md:272-309`). “Chrome only” is
a client design choice, not an architectural consequence.

Keeping device colour out of the terminal grid is still correct. The terminal
palette belongs to the selected theme, and the existing title bar is deliberately
the terminal background so it joins the grid without a seam
(`Sources/termio/App/App.swift:629-657`). The title bar is therefore not a free
piece of chrome to tint. A device-coloured title bar would either break that
shipped convention or mislabel a focused session when current device and focus
diverge. A global sidebar tint is also wrong because the sidebar remains
cross-device.

The claimed repo-wide ban on accent-coloured control backgrounds is not an
invariant. The app strips AppKit’s saturated blue selection, but its themed
sidebar intentionally uses an accent-tinted selected-row fill
(`Sources/termio/Sidebar/SidebarView.swift:1318-1371`). The “neutral rather than
accent-coloured controls” sentence in `docs/design/agent-plugins.md:176-187` is
the grammar of that Settings tab, not a global rule.

A swatch beside a device label survives this attack because it occupies a
device-owned atom and does not compete with selection, agent status, terminal
theme, or window focus. The RFC should name exact atoms, not “sidebar, indicator,
title bar” as one undifferentiated chrome region.

### 3. Guardrails: reject locality as the predicate, not confirmation itself

The strongest case against the proposed rejection is that a risk-dependent
policy is not a second execution path. One command implementation can decide
whether to confirm from the action’s reversibility and scope. Network location
can correlate with risk: a local delete goes to Trash, while a device request may
have no recoverable trash operation.

The `rm -rf` comparison misses the RFC’s examples. termio cannot interpret every
shell command, but it does own Close Session and file deletion. The shipped local
file action already confirms and moves the item to Trash
(`Sources/termio/FileBrowser/FileBrowserView.swift:578-593`). Close Session also
confirms when a plain shell has a foreground job
(`Sources/termio/TermioStore/TermioStore+ProjectActions.swift:658-691`). The
existing convention is “confirm known loss,” not “never confirm local actions.”

Your rejection does survive in two narrower forms:

- Never interpose on ordinary terminal commands. Colour, labels, and focus are
  the only viable cues there.
- Do not key app-owned confirmation on “not this machine.” That predicate is
  Mac-centric and fails the settled peer-client model: on iOS every session host
  is another machine. Key it on irreversibility, inability to recover, or a
  device-wide blast radius, identically on every viewer.

Typed device names are especially weak because names are mutable and need not be
unique; hold-to-confirm is undiscoverable and input-device-dependent. A normal
confirmation that names the device and the irreversible consequence remains
defensible for Forget Device, uninstalling termiod with live sessions, permanent
file deletion, and other device-scoped destruction. Colour is a cue, not a
guardrail: palette collisions, colour-vision differences, and ambiguous chrome
make it incapable of carrying that burden alone.

### 4. `Connect to…` in the `+` menu: survives, with two required decisions

Replacing the existing dead `New Remote Terminal` row is the best use of the
slot. The `+` menu already puts that row directly below New Terminal at Home
(`Sources/termio/App/App.swift:1784-1808`), so this adds no new weight for a
one-device user and fixes the empty-config dead end instead of adding another
item.

Two ambiguities remain:

1. Does Connect only learn/switch the device, or does it also create a terminal?
   The former does not replace the old creation action; the latter hides a
   session-creation side effect behind a connection verb.
2. What happens to the adjacent `New SSH Connection` command, which already has
   its own Add Host path (`Sources/termio/App/App.swift:1621-1644`)? Shipping both
   during stage 1 presents two ways to reach the same machine before the data
   model resolves their semantics.

Keep the same slot, but do not stage the rename before those behaviors are
decided.

## The three suspected gaps

| Suspected gap | Verdict |
| --- | --- |
| Unreachable-device presentation | Correct and blocking. The prior bug supports the need for one connection truth, but stale tunnel URL was not its confirmed root cause. |
| `TERMIO_TERMIOD` absent from staging | Correct and the largest omitted risk. The settled architecture places deletion of the flag before the switcher. |
| PR #177 paragraph is stale | Correct. [PR #177](https://github.com/termio-sh/termio/pull/177) merged into `main` on 2026-08-15 at 13:07 UTC as `66b1722`; it is no longer a draft or a blocker. |

## Scale tests

### One device

- Healthy steady state can collapse completely. That part of the promise holds.
- Failure cannot collapse. With termiod as the only PTY owner, daemon failure
  needs an error and recovery action even when no device indicator or Settings
  tab is normally shown.
- “One” must ignore stale learned devices that have no sessions, no live route,
  and no route left in `~/.ssh/config`, or trying the feature once permanently
  changes the UI.
- The fate of old plain-SSH sessions must be explicit. Silent conversion would
  install software and change session durability; retaining them preserves the
  fork.
- Replacing the existing `+`-menu row with Connect costs nothing. Adding a second
  Connect item would break the promise.

### 20 devices

- A fixed colour palette repeats and cannot serve as identity.
- A flat switcher needs search, recent ordering, or another bounded selection
  rule. The current registry’s stable order is opaque `host_id` order
  (`Sources/termio/Terminal/Termiod/TermiodDevice.swift:167-172`), which is unusable
  as presentation order.
- Eager reachability probing is not acceptable, but no probing leaves 20 devices
  in an unknown state after launch. The RFC needs a lazy status model tied to
  actual `TermiodConnection` objects, plus explicit “not checked” presentation.
- A single badge saying another device needs attention loses which device and how
  many. With several devices in `needs-you`, it becomes a generic alarm rather
  than navigation.
- A “device column” does not fit the shipped hierarchical source-list model
  without a layout decision. The sidebar is constrained to 240–400 points
  (`Sources/termio/App/App.swift:505-509`); 20 repeated device names on session
  rows will either dominate the agent/session labels or truncate into uselessness.
- Multiple aliases per device make the switcher’s known-device and untried-alias
  sections duplicate entries until handshake. The design needs an explicit
  unresolved-route row and a merge transition, not the fiction that the sections
  are clean rosters.

## Vocabulary problems

| Term | Problem |
| --- | --- |
| **Device** | In the architecture it means a machine running termiod. In the product it already naturally includes the iPhone viewer. Settings ▸ Devices will sound as if paired phones belong there even though the peer-client model says they do not. The UI needs a qualifier or copy that makes “session host” clear. |
| **Connect to…** | It does not say whether the user is selecting a known device, entering an SSH route, installing termiod, switching context, or opening a terminal. Beside `New SSH Connection`, the ambiguity is worse. Finder’s full verb is “Connect to Server…”, which names the object. |
| **Clone to <device>…** | “To” implies copying the current checkout, including local work. The shipped operation actually runs `git clone <origin>` on the target and excludes unpushed commits (`Sources/termio/Terminal/Termiod/TermioStore+Termiod.swift:489-520`). “Clone on <device>…” is more accurate without restoring the word remote. |
| **New Terminal** | A direct command with one device and a submenu with two changes both interaction shape and keyboard meaning at an arbitrary roster count. If a current device exists, New Terminal should have one target: that device. |
| **Reachable machines** | `~/.ssh/config` contains candidate aliases and patterns, not proof of current reachability. Call them SSH routes or targets until a connection succeeds. |
| **New Project** | This is not shipped vocabulary. The app uses `Open Project…` (`Sources/termio/App/App.swift:2134-2139`), and `VOICE.md:130-138` fixes “project” as the UI noun. The scoping table should use the real command. |
| **Retire remote** | Scope the retirement to execution-topology nouns and verbs. “Git remote”, Apple’s “Remote Management”, and remote access for the iPhone remain accurate domain terms; a lexical purge would make those strings worse. |

## Required changes before approval

1. Replace the provenance-based ownership rule with explicit authorities for
   routes, observations, viewer preferences, and device state. Do not persist a
   typed SSH target as a termio-owned route.
2. Define one focus model with a transition table. It must be impossible for the
   indicator, focused terminal, panels, title bar, and creation commands to name
   different devices without an explicit split-state presentation.
3. Rewrite staging to follow the settled dependency order: own connection health,
   make termiod the default and remove the in-process fork, prove packaging and
   lifecycle, then expose the switcher.
4. Specify unreachable, reconnecting, unverified, incompatible, and route-removed
   presentation, including recovery for the one-device case.
5. Decide and migrate `New SSH Connection` / `Session.sshHost`; tolerant decoding
   is not a migration policy.
6. Treat deterministic colour as a secondary default cue, define its stability
   and accessibility contract, and name the exact UI atoms it may colour.
7. Base confirmations on irreversible consequences and blast radius, never on
   local versus non-local. Do not intercept terminal commands.
8. Define the 20-device interaction: ordering, search or recency, lazy status,
   attention routing, stale-device cleanup, and how device identity fits the
   existing sidebar without becoming a repeated text column.
