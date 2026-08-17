---
title: Sessions CLI v3 — command design (better than tmux)
status: draft
type: design
created: 2026-08-08
updated: 2026-08-08
related:
  - 20260724-sessions-cli-v2.md
  - 20260730-termiod-session-protocol.md
  - 20260730-termiod-session-mux.md
---

# Design: Sessions CLI v3 — command design (better than tmux)

> The command surface an agent or human drives sessions with, designed against
> tmux's model and this week's dogfooding failures. v2 fixed reliability
> (fail-loud, timeouts, watch semantics); v3 fixes the *vocabulary* — and
> names the contract that makes the CLI strictly better than tmux for
> supervising work, not just equal to it for attaching terminals.

## 0. Conclusions first

- **Links, not coordinates.** tmux addresses work by position
  (`-t work:2.1`) in three coexisting namespaces (`name`, index, `%id`), and
  positions shift under renumbering. termio addresses sessions by one stable
  noun: `termio://session/<uuid>` (unique prefix accepted). Nothing in the CLI
  ever names a window or pane — layout is a client concern (protocol §H.5).
- **Ten verbs, one noun.** tmux has ~90 flat commands mixing lifecycle,
  layout, config scopes, key tables, and copy-mode. termio's surface is ten
  verbs on `session`. Every capability beyond that is either the client's job
  (layout, selection, scrollback) or the protocol's (status, snapshots).
- **JSON is the contract; tmux's format strings are the cautionary tale.**
  tmux scripting means `#{pane_pid}` template soup plus `capture-pane` text
  scraping. Every termio verb takes `--json` and emits one documented, stable
  shape. Screen truth comes from transcripts and `S` snapshots, never scraped
  text.
- **Push, not poll.** tmux has no events; supervision is a poll-and-scrape
  loop (`wait-for` requires the target's cooperation). `watch` streams
  status transitions with an opening snapshot, a heartbeat, and payloads
  actionable without a follow-up query.
- **The CLI knows what's *inside* the session.** tmux cannot distinguish a
  working agent from a wedged one — both are a pane with bytes in it. Status
  (`working / idle / needs-you / done / stalled / closed`) is the product
  object, and v3 completes the vocabulary with the two states dogfooding
  showed were missing: `closed` (with a reason) and a `done` latch for
  fire-and-forget spawns.

## 1. What tmux's command model gets wrong (specifically)

| tmux | Failure |
| --- | --- |
| `-t sess:win.pane`, `%id`, `@id` | Three addressing namespaces; positional indexes shift on move/renumber; scripts break silently |
| ~90 flat commands + aliases | Lifecycle, layout, config, key tables, copy-mode in one namespace; discoverability = the man page |
| `set-option -g/-s/-w/-p` | Four option scopes with inheritance; `show-options` answers depend on flags you didn't pass |
| `#{format}` mini-language | An ad-hoc template DSL instead of structured output; the only machine interface is string interpolation |
| `capture-pane` | Screen scraping as the reading primitive — no history contract, no structure, races with redraw |
| `wait-for` | Sync requires the *target* to signal a channel; you cannot wait on work you didn't instrument |
| No events, no status | A supervisor polls and diffs text; a stuck agent is indistinguishable from a busy one |
| Remote = nested tmux | `C-b C-b` prefix chords; two servers, two option scopes, two clipboards |

None of these are implementation bugs; they follow from tmux's model — the
mux owns layout and config, and scripting was retrofitted. termio's model
(host owns sessions; clients own layout; status is protocol) removes the
categories rather than polishing them.

## 2. The v3 surface

Verbs marked **P** speak the session protocol (termiod) once Phase 4 lands;
**G** verbs address the GUI and stay on the app socket (a window action needs
a window). Until the daemon is default, P-verbs route via the app for
app-owned sessions — a routing bit, not a second vocabulary.

| Verb | Shape | Notes |
| --- | --- | --- |
| `list` **P** | `[--json] [--closed]` | Roster + status. `--closed`: bounded tombstone history — link, exit reason (`user-closed` / `agent-exited(code)` / `boot-failed`), ended-at. A dead link must be distinguishable from a never-existent one |
| `watch` **P** | `[--state …] [--json]` | v2 semantics (snapshot, heartbeat, `stalled`) **plus `closed` events carrying the reason**. A supervisor learns about death the way it learns about `done` |
| `spawn` **P** | `"<prompt>" [--agent] [--wait[=boot\|settle]]` | Returns the link immediately (v2). `--wait=boot` blocks only until the agent reports its transcript — the "did it actually start?" tier; `--wait`/`--wait=settle` = v2 turn-settlement. A session exiting within the boot window is reported as `boot-failed`, loudly |
| `run` **P** | `"<command>"` | Plain terminal session, no LLM; screen is the result |
| `send` **P** | `<link> "<text>" [--wait]` | v2 settle semantics; payloads chunked so long prompts cannot stall the socket (known v2 gap) |
| `read` **P** | `<link> [--lines N]` | Current screen from the `S` snapshot path, not scrape |
| `attach` **P** | `<link>` | Interactive attach (observer by default; write claim per protocol) |
| `close` **P/G** | `<link>…` | Ends the session (host) and its tab (GUI when present) |
| `focus` **G** | `<link>` | Bring to front; errors honestly when headless |
| `agent report` **P** | *(hook contract)* | Unchanged; reports to the *local* host — status never relays through a GUI |

**Status vocabulary** gains: `closed(reason)` — terminal, kept in tombstones;
and the **done latch**: a spawned session's first settle after prompt delivery
latches `done` (instead of decaying to `idle`) until new input arrives.
"Idle, awaiting work" and "done, deliverable ready" are different answers to
the only question a supervisor asks.

**JSON contract:** every verb's `--json` output is one top-level object with a
documented schema (`list` → `{"sessions":[…]}`), versioned by additive change
only. The schema lives in `--help`, not in a wiki. This is the anti-`#{}`:
one shape per verb, no template language, no parsing prose.

**Exit codes** (v2, restated as contract): `0` ok/settled · `1` error, reason
on stderr (`prompt_stalled` / `session_closed` / `agent_gone` / `boot-failed`)
· `2` termio gone · `3` timeout, target still running.

## 3. What we refuse (tmux features that are anti-features here)

- **No window/pane verbs, ever** — no `split-window`, `select-pane`,
  `resize-pane`. Layout belongs to the client (protocol §H.5); the CLI
  addressing model stays one-noun because of it.
- **No option namespace** — no `set`/`show`. Configuration is the app's and
  daemon's config surface; a control CLI with a config store grows scopes.
- **No format-string DSL** — `--json` or human text, nothing in between.
- **No copy-mode / capture verbs** — native selection and transcripts already
  beat them.
- **No prefix-key layer** — the CLI is a CLI; chords belong to the app's
  keybindings.

## 4. Phasing

1. **v3.0 (app socket, now):** `list --closed` + tombstones, `closed` watch
   events, `spawn --wait=boot` + loud boot-failure, done latch, `send`
   chunking, documented JSON schemas. All are app-store changes; none wait on
   termiod.
2. **v3.1 (protocol backing, Phase 4 of the mux plan):** P-verbs move to the
   session protocol in the Rust `termio` binary; `read` switches to `S`
   snapshots; `watch` consumes host `E` events and therefore works with the
   GUI closed. G-verbs stay behind; the routing bit retires with the last
   app-owned session.
3. **v3.2:** remote targets (`<link>` resolves through the device registry;
   same verbs against any host) — the point where the tmux comparison ends,
   because tmux never had an answer here at all.

## 5. Test plan

- Tombstones: close a session each way (user, exit 0, exit 1, boot kill) and
  assert `list --closed` reasons; assert dead-link errors name the tombstone.
- Boot tier: `spawn --wait=boot` against a broken agent PATH exits `1`
  `boot-failed` within the window; against a healthy agent returns on
  transcript registration.
- Done latch: spawn → settle → assert `done` in `list` and `watch`; `send`
  new input → assert transition back to `working`.
- JSON: golden-file the documented schemas; additive-only check in CI.
- Chunking: 256 KiB `send` payload settles without control-socket stall.
