---
title: Refresh session identity when Claude Code /clear rotates the conversation
status: approved
type: design
created: 2026-07-20
updated: 2026-07-20
related:
  - agent-resume-identity.md
  - config-driven-agent-resume.md
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
  conversation, so quitting termio in this window would resume a conversation
  the user deliberately discarded.

Everything self-heals on the *first prompt of the new conversation* — but until
then termio is blind, and the Info pane actively shows wrong data.

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
  termio start. Note: an *already-running* Claude session snapshots its hook
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
