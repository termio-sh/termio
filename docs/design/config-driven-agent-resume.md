---
title: Config-driven agent resume
status: done
type: design
created: 2026-07-20
updated: 2026-07-20
related:
  - agent-resume-identity.md
  - agent-extensibility.md
---

# Config-driven agent resume

> Move an agent's resume behavior out of a hardcoded Swift enum and into its
> manifest, so adding an agent in the common "pin an id, create-then-resume"
> family is JSON alone — no code.

## The problem

Resume behavior used to live in a five-case `ResumeStyle` enum
(`claudeStyle` / `piStyle` / `codexStyle` / `openCodeStyle` / `none`). The
argument strings, the create-vs-resume switch, and the on-disk session-store
lookups were all hardcoded and keyed on agent *identity* — `agent == .claudeCode`,
`agent == .pi`, and so on.

That surfaced as a real bug when Grok was added purely through its manifest
(`grok.json`). Grok's CLI is Claude-shaped — `--session-id <uuid>` creates (and
errors if the id already exists), `--resume <uuid>` continues — so `resume:
"claude"` gave it the right *arguments*. But the create-vs-resume switch asked
"does this conversation already exist on disk?" through a probe hardcoded to
Claude's store (`~/.claude/projects`). For Grok it was always false, so termio
re-sent `--session-id` on every relaunch for an id Grok had already saved under
`~/.grok/sessions`, and Grok rejected the duplicate:

```
Error: Session ID <uuid> is already in use. Process exited.
```

Grok couldn't resume — not because its CLI lacked support, but because the store
probe wasn't expressible in config.

## The interface

`resume` in the manifest becomes a flat object. Everything an agent in the
pinned family needs is data:

```jsonc
"resume": {
  "create":     "--session-id {id}",   // launch fresh with a termio-pinned id
  "resume":     "--resume {id}",        // continue a known conversation id
  "storeRoot":  "~/.grok/sessions",     // root of the agent's on-disk store
  "storeMatch": "dir:{id}",             // how a conversation is named on disk
  "discover": {                          // how to recover an agent-minted id
    "root":   "~/.codex/sessions",       //   where the agent's records live
    "format": "jsonl",                   //   jsonl (header line) | json (whole file)
    "id":     "payload.id",              //   key path to the session id
    "cwd":    "payload.cwd"              //   key path to the working directory
  },
  "seed":       "session-file"          // pre-create the session file at launch
}
```

Rules, all inferred from which fields are present — no `kind`/`style` tag:

- **`create` present ⇒ the id is pinned up front.** termio mints the UUID, launches
  with `create` the first time and `resume` on every relaunch. The switch is driven
  by probing the store (below), because the create flag errors on a duplicate id.
- **`discover` present ⇒ the id is minted by the agent and recovered afterward.**
  `create` and `discover` are mutually exclusive.
- **Neither ⇒ the agent doesn't resume** (omit `resume` entirely, or `"none"`).

`{id}` is the only placeholder; the rendered fragment is appended to the base
command.

### The discovered-id lifecycle

For a discovered-id agent the tab↔conversation connection is *established once,
then saved* — after which resume is exactly as precise as the pinned family:

1. **First launch** — no id exists yet, so the session launches fresh and termio
   stamps `Session.launchedAt`. The agent mints its own id internally.
2. **Discovery** — on the next resolve, `AgentSessionStore` scans the agent's
   store for the session record born at that launch (cwd + creation-time match)
   and `recordLaunch` persists the found id into `Session.resumeID`. Discovery
   runs at most once per session; from here on the saved id wins.
3. **Every later relaunch** — `resume {id}` with the saved id. Exact.

Resume is deliberately exact-or-nothing: if discovery misses (no saved id), the
session launches fresh rather than approximately continuing "whatever is most
recent in this directory" — the prior conversation stays reachable in the
agent's own session picker. An earlier draft carried a `continueLast` fallback
flag for that window; it was cut as surplus. If a discovered-id agent ever grows
a `--session-id`-style flag, it moves to the pinned family and discovery falls
away entirely.

### The store descriptor

`storeRoot` + `storeMatch` describe where the agent keeps conversations, so one
generic probe replaces every per-agent lookup. `storeMatch` is
`dir:<pattern>` or `file:<pattern>`, where `<pattern>` contains `{id}` and may
contain a `*` glob:

| Agent | `storeMatch` | on disk |
| --- | --- | --- |
| Claude | `file:{id}.jsonl` | `~/.claude/projects/<cwd>/<id>.jsonl` |
| Grok | `dir:{id}` | `~/.grok/sessions/<cwd>/<id>/` |
| Pi | `file:*_{id}.jsonl` | `~/.pi/agent/sessions/--<cwd>--/<ts>_<id>.jsonl` |

Agents bucket sessions per working directory under `storeRoot`; the probe
(`SessionStore` in `TermioStore+TerminalSurface.swift`) globs the immediate
buckets for the matching entry rather than reconstruct each agent's private cwd
encoding. The same descriptor backs three consumers:

1. **create-vs-resume** — does an entry for `{id}` exist yet?
2. **Info-pane transcript fallback** — for a `file:` store, the matched path *is*
   the transcript (Claude), when no hook delivered one.
3. **`/clear` id-rotation** — for a `file:` store, `{id}` is recovered back out of a
   transcript filename to re-pin the live conversation (see
   [agent-resume-identity.md](agent-resume-identity.md)).

### The discover descriptor

For agents that mint the id themselves, the id lives *inside* their session
records. `discover` describes how to read it — pure mechanism, no agent names:
`root` (where records live), `format` (`jsonl`: the first line of a `.jsonl` log
is the record and the log itself is the transcript; `json`: a standalone
metadata file), and two dot-separated key paths (`id`, `cwd`). One generic
reader in `AgentSessionStore` walks `root` for records created at this session's
launch whose `cwd` matches, and extracts the id — a new record shape is new
config, not new code. The `format` also answers whether the matched file can
feed the Info-pane trace (`jsonl` yes, `json` no).

### The seed mechanism

`seed: "session-file"` names the one behavior that stays code: pre-creating the
agent's session file so a pinned id resolves silently on first launch (Pi warns
otherwise). It can't be data because it must write the agent's private header
format and cwd encoding. It's still declared in the manifest so the wiring is
visible; strategies are named for what they *do*, never for an agent.

## What each built-in declares

| Agent | create | resume | store | discover | seed |
| --- | --- | --- | --- | --- | --- |
| Claude | `--session-id {id}` | `--resume {id}` | `file:{id}.jsonl` | — | — |
| Grok | `--session-id {id}` | `--resume {id}` | `dir:{id}` | — | — |
| Pi | `--session-id {id}` | `--session-id {id}` | `file:*_{id}.jsonl` | — | `session-file` |
| Codex | — | `resume {id}` | — | `jsonl` · `payload.id` | — |
| OpenCode | — | `--session {id}` | — | `json` · `id` | — |
| Amp, Cursor, Kimi, Antigravity, Hermes | *(no `resume` field)* | | | | |

The five migrated agents produce byte-identical launch arguments to the old
`ResumeStyle`, verified case-by-case — with one deliberate exception: the old
`resume --last` / `--continue` fallback (Codex/OpenCode with no discovered id)
now launches fresh instead of approximately continuing.

## Why this shape

- **No presets, no inheritance.** Each agent's config is self-contained and
  explicit; the only magic string is the one seed name. (The old preset strings
  still decode, as backward-compatibility for existing user manifests, but
  aren't the documented interface.)
- **Mechanisms, not identities.** Strategies describe *how* (a format, a key
  path, a file to pre-create), never *who* — there is no `"discover": "codex"`
  pointing at agent-named code. Agent identity is gone from the launch, probe,
  transcript, and discovery paths; they all read `agent.resumeSpec`.
- **The common case is code-free.** A new claude-like CLI is four lines of JSON;
  a new discovered-id CLI is a `discover` object. Only a genuinely new mechanism
  (a third record format, a second seed) touches Swift.
