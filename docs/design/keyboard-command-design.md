---
title: Keyboard and command design
status: active
type: design
created: 2026-08-12
updated: 2026-08-12
---

# Keyboard and command design

> One rule decides every binding: a key either changes what you're looking at or
> it ends a process, and only the second kind is allowed to ask — or to destroy.

## The rule

**Presentation or process.** Every command in termio acts on one or the other,
and that decides its key, its confirmation, and whether it may cascade.

- Keys that change presentation — panes, windows, focus, the inspector — never
  end a process. They need no confirmation, because nothing is lost.
- Keys that end a process are few, named, and confirm when there is live work.

⌘W is always the first kind. ⌘Q is the second. That is the whole design; the rest
of this doc is why the obvious alternative is wrong and how the neighbours answer
the same question.

This replaces the earlier "termio is sidebar-shaped, not tab-shaped" framing,
which described the same conclusion but couldn't be applied to a key you hadn't
already decided. Presentation-or-process can.

## Why the literal translation is wrong

Every tabbed terminal binds ⌘W to "close the surface", and in those apps the
surface *is* the process — closing it kills the program. termio's objects don't
line up that way:

| termio | tabbed terminal (iTerm2, Ghostty) |
| --- | --- |
| **Pane** — a view slot in a split group | surface — the process itself |
| **Session** — durable: owns the PTY, a resume id, sometimes a worktree; lives in the sidebar; survives relaunch | (no equivalent) |
| **Split group** — the layout, persisted | tab |
| **Window** — one, always | one of many |

So `close_surface` has two possible readings in termio: *remove this pane from
the layout* (Ungroup), or *end this session*. Structurally the first is the
faithful one — it's the same "close the thing in front" — while the second
smuggles in a process kill that the original binding only implies because tabs
and processes are the same object there.

Choosing the second reading is what produced [#242](https://github.com/termio-sh/termio/issues/242):
⌘W fell through to closing the single window, the app terminated with it, and
every agent died with no confirmation. Two users reported it the same day.

## The map

| Key | Action | Kind |
| --- | --- | --- |
| ⌘W | Ungroup the focused pane; with no split, close the window; in an auxiliary window, close that window; with the palette up, dismiss it | presentation |
| ⌘⇧W | Close the frontmost window | presentation |
| ⌘M | Minimize the frontmost window | presentation |
| ⌘D / ⌘⇧D | Split right / down | presentation |
| ⌥⌘ arrows | Focus pane by direction | presentation |
| ⌘⇧↩ | Zoom split | presentation |
| ⌘⇧[ / ⌘⇧] | Previous / next session | presentation |
| ⌃⌘F | Toggle full screen | presentation |
| ⌘T / ⌘N | New Terminal / New Chat | creation |
| ⌘Q | Quit — **confirms** when any session is working or needs you | process |
| *(unbound)* | Close Session — **confirms** only for a shell with a command running | process |

Closing the window keeps the app running with every session alive; the Dock icon
brings the window back. Only ⌘Q reaches the teardown that kills PTYs.

Window-scoped commands resolve the **key window**, so ⌘W and ⌘⇧W close Settings
when Settings is in front rather than reaching past it to the terminal behind.
With no window on screen, ⌘W does nothing rather than mutating an invisible
layout.

## Confirmation policy

A confirmation is a tax on every correct use of a key, levied to prevent the
rare wrong one. It is worth paying only where the action destroys something
unrecoverable, which is why the policy is keyed on **what would be lost**, not on
how alarming the command sounds:

- **⌘Q** confirms when a session is `working` or `needs-you`. An all-idle app
  quits without a word.
- **Close Session** confirms only for a plain shell with a command running in
  front of it — the iTerm2 carve-out. Agent sessions close without a word.
- **⌘W** never confirms, because after #242 it destroys nothing.

The first cut of this rule confirmed whenever the session's PTY was alive, and
that shipped. It was wrong for a reason worth recording: an agent session's PTY
is alive from the moment it opens until the moment it closes, so "confirm on a
live PTY" is not a rule about live work at all — it fires on **every** close of
**every** agent session. That is the tax paragraph above describing itself. What
it was protecting is weaker than the dialog claimed, too: an agent conversation
is on disk and resumes, while a command typed into a shell has no other record.

Two traps found while building this, kept because they still bound the design:

1. **Attention status is not process safety.** Keying the confirmation off
   `working` / `needs-you` looks right and is wrong: a `done` or `idle` agent
   still holds an entire conversation, and merely *looking* at a session settles
   it back to `idle`. Status can't carry a safety decision — part of why the
   answer for agent sessions is not to ask at all.
2. **A live agent looks idle to the kernel.** `tcgetpgrp` on the PTY master
   reports the foreground process group, which is how iTerm2 decides whether a
   pane is busy. A running `claude` shares the shell's process group, so that
   check reports *no foreground job* for a live agent — verified. The shell
   carve-out is therefore keyed on `agent.isShell` first and the kernel probe
   second, so an agent that *does* fork a child still never prompts.

## How the neighbours answer this

### cmux — the same category

cmux is a Ghostty-based macOS terminal for coding agents, and the closest
comparison. Its published shortcut table and changelog (2026-02-09):

| Key | cmux |
| --- | --- |
| ⌘W | **Close Tab** — closes the focused tab; if it's the last tab, closes the workspace/window |
| ⌘⇧W | Close Workspace (with a confirmation dialog) |
| ⌃⌘W | Close Window |
| ⌘D | confirms the close dialog (the macOS "Don't Save" mnemonic) |

cmux lets ⌘W cascade all the way up to closing the window, and gates the cascade
with a confirmation — plus a separate "running process" dialog. It also enforces
the routing with a CI lint and a review-bot rule whose stated purpose is that ⌘W
must close the active window "instead of falling through to workspace panel
closing." They care enough about this one key to gate it in CI.

**Where termio differs:** cmux needs the confirmation because its close still
tears things down. termio's doesn't, so there's no dialog to dismiss at all. The
divergence isn't taste — it follows from the window close being non-destructive.

### Zed — the same object problem, solved by context

Zed's `default-macos.json` resolves ⌘W per context:

| Context | Binding |
| --- | --- |
| `Pane` | `pane::CloseActiveItem` |
| `Workspace` | `workspace::CloseActiveDock` |
| `SettingsWindow` | `workspace::CloseWindow` |
| global | ⌘⇧W `CloseWindow`, ⌘M `Minimize`, ⌘Q `Quit` |

Zed is the closest structural match: a durable object list on the side, panes as
views, and ⌘W closing the *item* while the file stays on disk. Two things
transfer directly. First, ⌘W in an auxiliary window means Close Window — the
key-window routing termio now implements. Second, `confirm_quit` defaults to
**false**: Zed doesn't need a quit confirmation because quitting an editor
destroys nothing recoverable.

That last point is the sharpest contrast in this doc. termio confirms on ⌘Q for
exactly the reason Zed doesn't: quitting termio kills live processes that no
autosave can bring back.

### Ghostty — the same confirmation policy, a different probe

Ghostty's `confirm-close-surface` defaults to `true`, documented as: confirm before
closing a surface, *"even if shell integration says a process isn't running"* only
when set to `always`. So its default is already "ask only when something is
running" — the same policy as termio's Close Session, reached independently.

The difference is the liveness probe. Ghostty asks the **shell** (OSC 133 command
marks, via shell integration); termio asks the **kernel** (`tcgetpgrp` on the PTY
master), and only for a session whose declared agent is a shell. Ghostty's signal
is the more general one, but it depends on shell integration being installed and
emitting marks; termio's works regardless of the user's shell config, at the cost
of saying nothing about an agent — which termio answers by not asking for agent
sessions at all.

Its close dialog also defaults focus to **Cancel**, so Return cancels. termio's
does the same, after a first cut where Escape landed on the destructive button.
Two independent implementations converging on that is the strongest signal in this
doc that it's the right default.

Ghostty users push back on that dialog even at its lower frequency —
[#9669](https://github.com/ghostty-org/ghostty/discussions/9669) asks for a
`force_close_surface` action to bypass it,
[#7357](https://github.com/ghostty-org/ghostty/discussions/7357) asks how to
remove it entirely. A confirmation that fires constantly becomes something users
engineer their way around; that is why the prompt stays off ⌘W, and why the
version of Close Session that asked on every agent close didn't survive first
contact with using it.

### Raycast — the command layer, not the window layer

Raycast isn't a window app in this sense, and it's closed-source, so it belongs
here for a different reason: its **command layer**. Every command is an object in
one searchable root, with an optional per-command hotkey and alias, and a
contextual action panel on ⌘K. Almost nothing is bound by default; discovery
carries the long tail and the user promotes what they use.

termio's equivalent is already in place: `KeyCommandCatalog` is the single source
of truth for every rebindable command, the ⌘⇧P palette searches it, Settings ▸
Keyboard rebinds it, and the surface's ghostty unbind set is *derived* from it so
a rebind can't be swallowed by the terminal. The lesson taken from Raycast is
restraint — a command earns a default key by being pressed constantly, not by
existing. Split Left and Split Up ship unbound for this reason, as does Close
Session.

## Resolution: one action that branches, not a context tree

Every tool above resolves a key **declaratively by context**. Zed's rule is
explicit:

> Bindings that match on lower nodes in the context tree win. […] If there are
> multiple bindings that match at the same level in the tree, then the binding
> defined later takes precedence.

VS Code says the same thing with `when` clauses. termio does not: `KeyCommandCatalog`
is a flat table, and ⌘W resolves itself *imperatively*, inside one action — is the
key window an auxiliary one, is there a split, otherwise close the window.

At this size that is the simpler design, and it stays honest because there is
exactly one place to read. It is deliberate, not an oversight — but it only earns
that defence if the decision is *isolated and tested*, because this is the binding
that regresses silently: the window still closes, just the wrong one. cmux guards
the same key with a CI lint. termio's equivalent is `CloseCommand.action`, a pure
function over "what is in front" × "is there a split", with `CloseCommandTests`
pinning every combination.

Keeping the decision pure also made a case visible that the imperative version had
wrong: the ⌘⇧P palette is a **borderless** panel, and `performClose` on a window
with no close button only beeps. Routing it to the store flag that owns the
palette's presentation turns a dead key into a dismiss.

The known cost shows up one layer in: with a diff or editor detail open in the
inspector, ⌘W ungroups a pane instead of closing the detail. Zed would close it —
its `Workspace` context binds ⌘W to `CloseActiveDock`.

That symptom is **not** fixed by adding another branch. Zed's dock binding matches
only when focus is *in* the dock; termio has no focus notion for the inspector, so
"close the detail whenever one is open" would break the common case — a diff open
beside a terminal you are typing in. Doing it correctly needs a focus/context
notion, which is the refactor, not a patch.

**The trigger to build contexts:** when a third state needs its own answer for the
same key, or when a binding's correctness depends on which region has focus. Until
then, branch and keep it in one function.

## Rejected

- **⌘W = Close Session.** The literal iTerm2/Ghostty reading, and the original
  recommendation in [#204](https://github.com/termio-sh/termio/issues/204).
  Adopting it means adopting its running-job prompt too — and with agents,
  `working` is the *normal* state, so the prompt would fire on nearly every press.
  A dialog that always fires is one people learn to dismiss reflexively, which
  arrives back at #242 by a slower road.
- **⌘1…⌘9 to select the Nth session.** Ghostty's `goto_tab` and the
  Safari/Chrome convention, but there is no stable Nth: with `recentActivity`
  sorting, selecting a session reorders the tree, so pressing ⌘4 changes what ⌘1
  means. Positional keys need explicit user-assigned slots, not a live tree.
- **⌥⌘W = Ungroup All.** Mirrors Ghostty's `close_tab:this` positionally, but
  that binding is destructive and dissolving a split group is not, so it would
  mislead both audiences. Ungroup All stays a menu verb.

## Deferred

Tracked in [#204](https://github.com/termio-sh/termio/issues/204):

- The ghostty-defaults fixture test, so a libghostty bump that adds a default
  binding breaks the build instead of silently shadowing an app key.
- ⌘[ / ⌘] for previous/next pane — redundant with ⌥⌘ arrows; wait for demand.
- ⌃⌘ arrows to resize the divider and ⌃⌘= to equalize. Blocked on defining which
  divider moves when the focused pane touches several ancestors; the binding is
  easy, the rule isn't.
- A focus/context notion for key resolution, and with it ⌘W closing a focused
  inspector detail. See *Resolution* above for the trigger.
