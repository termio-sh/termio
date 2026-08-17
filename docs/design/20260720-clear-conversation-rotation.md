---
title: Refresh session identity when Claude Code /clear rotates the conversation
status: approved
type: design
created: 2026-07-20
updated: 2026-07-20
related:
  - 20260716-agent-resume-identity.md
  - 20260720-config-driven-agent-resume.md
---

# Refresh session identity when Claude Code `/clear` rotates the conversation

> Close the blind window between `/clear` and the next user prompt: advance the
> transcript path and resume pin the moment the conversation rotates, and drop
> the stale sidebar topic title that belongs to the discarded conversation.

## Symptom

After the user runs `/clear` inside a Claude Code session:

- **View Trace** (Info pane) still renders the *old* conversation's JSONL.
- The **sidebar row title** still shows the *old* conversation's topic
  (e.g. "Review Markdown preview feature on t…").
- The **resume pin** (`Session.resumeID`) still points at the cleared
  conversation, so quitting Termio in this window would resume a conversation
  the user deliberately discarded.

Everything self-heals on the *first prompt of the new conversation* — but until
then Termio is blind, and the Info pane actively shows wrong data.

## Root cause

The event model assumes "conversation identity only changes when a subscribed
hook fires." `/clear` breaks that assumption: the one event Claude Code fires
at that moment — `SessionStart` with `source: "clear"` — is not in the
manifest's event list (`Sources/termio/Resources/agents/claude.json`), which
subscribes only to `UserPromptSubmit` / `PreToolUse` / `PostToolUse` /
`PermissionRequest` / `Stop`.

Two mechanisms downstream are starved by that missing subscription:

1. **Transcript + resume pin.** `applyStatusReport`
   (`TermioStore+AgentStatus.swift:65-80`) updates `transcriptPaths[id]` and
   calls `reconcileResumeID` on any report carrying a `transcript_path`. The
   mechanism was built precisely for the `/clear` rotation (the comment says
   so) — it is just wired to a signal that arrives one user-action too late.
2. **Sidebar title.** `liveTitles` only advances on a *meaningful* OSC title
   (`TermioStore+TerminalSurface.swift:751-764`). After `/clear` Claude resets
   its title to the agent/folder name, which `isMeaningfulLiveTitle`
   deliberately rejects as startup noise — good default, but there is no
   "the conversation ended, the old topic is now wrong" invalidation signal.

## Design

Three small pieces. No new subsystems — the fix is one manifest entry plus
teaching the existing rotation point to invalidate the title.

### 1. Subscribe to `SessionStart(source: clear)` in the Claude manifest

Add to `claude.json` `hooks.events`:

```json
{ "on": "SessionStart", "state": "idle", "matcher": "clear" }
```

- Claude Code's `SessionStart` hook supports a source matcher
  (`startup` / `resume` / `clear` / `compact`); matching only `clear` keeps
  startup/resume/compact from firing this hook at all, so there is no risk of
  clobbering a mid-turn status during auto-compact.
- The installer already writes per-event matchers into the nested Claude
  settings shape (`HookListener.swift` `JSONHookFile.install`, ~line 395-408),
  and `capturesTranscript: true` means the hook command carries
  `--transcript`, so the report arrives with the **new** `session_id`'s
  `transcript_path`.
- `state: "idle"` flows through the existing `applyStatusReport` switch
  (`case "idle"` → `clearWorking` + `.idle`) — correct, since a
  just-cleared session *is* idle. No state-machine changes needed.

With this alone, `transcriptPaths[id]` and `reconcileResumeID` advance at
`/clear` time instead of first-prompt time.

### 2. Invalidate the stale topic title on conversation rotation

`reconcileResumeID` (`TermioStore+TerminalSurface.swift:530-538`) is the single
point that *knows* the conversation rotated (extracted id ≠ pinned id). When it
detects a rotation, additionally:

- clear `liveTitles[id]` (the in-memory topic),
- clear the persisted `session.liveTitle`,

so `displayTitle(for:)` falls back to the agent display name ("Claude Code")
until the new conversation earns a topic. Do **not** touch `lastTitleActivity`
or the status dictionaries — title-driven status is a separate channel and the
`idle` report already handles status.

Rotation is a safe trigger: on normal launch/resume the hook-carried id equals
the pinned id (create pre-pins via `--session-id {id}`), so this fires only
when the conversation genuinely changed.

### 3. Graceful trace for a not-yet-materialized transcript

At `/clear` time the new JSONL does not exist yet — Claude Code creates it on
the first message. After piece 1, `transcriptPaths[id]` points at a
nonexistent file until then. The Info pane / View Trace path must handle this:
render an honest empty state ("New conversation — no messages yet" or simply
the trace with zero entries) rather than an error. Check how the trace
renderer (`Sources/termio/Info/`) behaves on a missing file and patch the
smallest spot that makes it graceful.

## Things to verify while implementing

- **Launch-time resume with a file-less pin.** After rotation, if the user
  quits before the first prompt, `Session.resumeID` names a conversation with
  no on-disk file. Confirm the launch path (resume spec resolution) checks
  store existence to decide `--resume {id}` vs create `--session-id {id}` — if
  it does an exact-file check, a file-less pin degrades to *creating* a fresh
  session under that id, which is exactly right. If it blindly passes
  `--resume`, fix that decision to be existence-gated. (Resume is
  exact-or-nothing per [[agent-resume-identity]]; resurrecting the cleared
  conversation would be wrong.)
- **`SessionStart` payload shape.** Confirm the hook stdin JSON carries
  `transcript_path` for `source: "clear"` (it should — same payload family as
  the other events). The report CLI already mines stdin when `--transcript`
  is set.
- **Hook install refresh.** `AgentStatusHooks.sync` rewrites
  `~/.claude/settings.json` at app launch, so the new event installs on next
  Termio start. Note: an *already-running* Claude session snapshots its hook
  config at startup and won't fire the new hook until relaunched — expected,
  document nothing.
- **Other agents.** This is Claude-manifest-only. Codex/OpenCode use
  discovered ids ([[config-driven-agent-resume]]) and have no `/clear`
  equivalent wired to hooks; leave them alone.

## Test plan

1. Rebuild dev app, start a Claude session, chat until a topic title appears
   and a trace renders.
2. `/clear` (no further input). Expect, within a beat: sidebar title falls
   back to "Claude Code"; Info pane View Trace shows the empty new
   conversation (no error); `Session.resumeID` equals the new id (check via
   the persisted store or a debug print).
3. Type a first prompt. Expect: trace fills with the new conversation, title
   reappears once Claude emits a topic.
4. Regression: plain launch and `--resume` of an existing session still work;
   auto-compact mid-turn does not flick status (matcher excludes it);
   quit-and-relaunch right after `/clear` opens a working fresh session, not a
   resume error.

## Phase 2 — rotation signals for the other agents

Phase 1's three downstream mechanisms — advance `transcriptPaths`, advance the
resume pin, invalidate the stale topic title — were already agent-generic; only
the *signal* (Claude's hook-carried `transcript_path`) was Claude-specific.
Phase 2 gives every other rotating agent a signal, through two new ATP manifest
mechanisms. All three consequences now flow through one shared adoption point
(`TermioStore.adoptConversationID`), so title invalidation comes for free
regardless of which signal fired.

### Mechanism 1 — identity-bearing reports (`hooks.conversation`)

The manifest's `hooks` object gains a `conversation` locator: where the hook
host exposes the agent's own id for the conversation it is currently writing.
`termio agent report` grew matching flags (`--conversation <id>` for plugins
that hold the id in-process, `--conversation-from <field>` to mine it out of
the JSON blob shell hooks receive on stdin), and the report payload carries it
as `conversation_id`. A report whose conversation id differs from the session's
pin *is* the rotation — `applyStatusReport` adopts it exactly the way a
hook-carried transcript path is adopted today. The locator is
dialect-interpreted, mechanism-named, never agent-named:

| dialect | locator meaning | example |
| --- | --- | --- |
| json (shell hooks) | stdin JSON field name | `session_id` (Codex), `sessionId` (Grok) |
| opencode plugin | dot key path in the event object | `properties.sessionID` |
| pi plugin | the `context` mechanism — the extension context's session manager | `context` |

Identity adoption is deliberately narrower than status adoption. It requires an
*exactly-stamped* report (`TERMIO_SESSION` echoed back — the hook files are
global, so a same-directory agent run outside Termio also reports, and a
cwd-guessed match must never re-pin a tab), fires only at a **turn boundary**
(`state != working` — a working-state payload embeds prompt/tool content on
stdin, where a colliding field name could be mined as the id; SessionStart/Stop
payloads are the agent's own minimal envelope), and accepts only bare-token ids
(the shell miner reads an arbitrary blob; anything that isn't UUID-shaped is
treated as no identity). On rotation, the transcript follows the *pinned id
exactly*: `resolveTranscriptPath` looks a discovered-id conversation up by its
id in the store rather than by launch-time file matching, which would drift
back to the rotated-away record.

### Mechanism 2 — turn-boundary re-discovery

For a discovered-id agent whose reports carry no identity, discovery no longer
runs at most once: on each `done` report that arrived without a
`conversation_id`, `AgentSessionStore.rediscover` re-scans the agent's declared
`discover` store for the **newest** record born in the session's directory
since this app run spawned the process (the original discovery binds to the
*earliest* record after the persisted first-ever launch; re-discovery bounds
itself to the live process so a resumed tab's window can't span days and
swallow records from runs in between). A newer record with a different id is
an in-process rotation;
adopt it. The no-guessing rule holds: when two same-agent sessions share the
directory, a newer record can't be attributed and nothing moves. The scan runs
only at turn end, never on a timer, and is skipped entirely for agents whose
manifest declares an identity locator — from such an agent, a report *without*
an id is deliberate (an OpenCode subagent's turn end), and its store record
would be exactly the false match the scan must not adopt.

### What each agent ships

| Agent | signal | rotation command | verified against |
| --- | --- | --- | --- |
| Codex | `conversation: session_id` + `capturesTranscript` (its hook stdin carries `session_id` and `transcript_path` = the live rollout); `SessionStart` event added so rotation lands at `/new` time; mechanism 2 covers it only when a user-override manifest drops the locator | `/new` | codex-cli 0.144.6 binary + openai/codex hook schemas |
| OpenCode | plugin passes `event.properties.sessionID` on `session.status` / `session.idle` / `permission.updated`. Subagent child sessions share the plugin bus, so the template learns top-level ids from `session.created`/`session.updated` (children carry `parentID`) and forwards only those | `session.new` (`<leader>n`) | opencode 1.17.20 bundled schemas + SDK types |
| Pi | extension reads `context.sessionManager.getSessionId()` (Pi reloads extensions with a fresh context after a session switch); `session_start` event added so rotation lands at `/new` time, before the lazily-created session file exists | `/new` | pi 0.80.6 shipped source |
| Grok | `conversation: sessionId` mined from hook stdin (Grok's payload is camelCase); `SessionStart` event added | `/new` (alias `/clear`) | grok 0.2.106 local docs (`~/.grok/docs/user-guide/10-hooks.md`, `17-sessions.md`) |
| Claude Code | unchanged — Phase 1's transcript-filename reconcile, now routed through the shared adoption point | `/clear` | — |

Notes: Codex's and Grok's `SessionStart` subscriptions also fire at process
start, where the reported id equals the pin — a no-op by construction (`state:
idle` matches a freshly started session). Pi's and Grok's rotated pins point at
conversations the pinned-store probe resolves on relaunch (create-vs-resume
stays existence-gated, so quitting before the new conversation's first message
correctly re-creates under the adopted id). A plain terminal running a
hand-started agent never adopts an id — the tab relaunches as a shell, so
there is no pin to keep honest.

### Phase 2 test plan

Per agent: start a session in Termio, chat until the trace/title reflect the
conversation, run the rotation command, then verify (a) the resume pin
(`Session.resumeID`) advances to the agent's new id, (b) the sidebar title
falls back to the agent name, (c) View Trace follows for agents with a
transcript (Claude, Codex, Pi — Codex's arrives with the next hook event, Pi's
once the new session file materializes on the first assistant reply), and (d)
quit-and-relaunch resumes the *new* conversation. For OpenCode, additionally
run a subagent-spawning prompt and confirm the pin never moves to a child
session id. For Codex, verify mechanism 2 by the same steps with
`capturesTranscript`/`conversation` removed from a user-override manifest —
rotation must then land on the `done` report at turn end.
