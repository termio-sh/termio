---
title: Agent Resume Identity — keeping the resume pin on the live conversation
status: approved
type: design
created: 2026-07-16
updated: 2026-07-16
related:
  - 20260628-session-history-search-resume.md
  - 20260711-agent-transcript-survey.md
  - 20260707-agent-extensibility.md
---

# Agent Resume Identity

> Keep a session's resume pin (`Session.resumeID`) pointed at the conversation the
> agent is *currently* in, so a reopened tab resumes that one — not a conversation
> the agent has since rotated away from (Claude Code's `/clear`).

## The bug

Termio binds each tab to one agent conversation so closing and reopening the tab
(or relaunching the app) resumes the *exact* prior session rather than starting
over. For Claude Code that binding is `Session.resumeID`, pinned once at first
launch and used to build `--resume <id>` / `--session-id <id>`
(`AgentDefinition.resumeArguments`).

The pin is written exactly once — `recordLaunch` sets `resumeID` only when it is
still `nil` (`TermioStore+TerminalSurface.swift`). It never advances. That is
wrong whenever the agent **rotates its conversation mid-session**:

- Claude Code's `/clear` mints a **new session id and a new
  `~/.claude/projects/<cwd>/<new-id>.jsonl`**, leaving the old `<old-id>.jsonl`
  on disk (it is not truncated in place). `/compact`, by contrast, keeps the same
  id — so only `/clear` (and picking another session via `/resume`) desyncs.
- The live transcript address Termio uses for the sidebar / `sessions` CLI / trace
  *does* follow the rotation, because `applyStatusReport` re-stores
  `transcriptPaths[id]` from every hook that carries a path. Only the **durable
  resume pin** is left frozen.

Result: while the tab is open everything tracks the new conversation, but on
close/reopen `resolveLaunch` sees the pre-`/clear` `<old-id>.jsonl` still exists,
so `pinnedConversationExists` is true and Termio launches `--resume <old-id>` —
resuming the conversation the user *cleared*, and orphaning the real one.

## The invariant

> `Session.resumeID` names the conversation the session is **currently writing**,
> and advances whenever the agent rotates to a new conversation.

This is a small strengthening of today's behavior: the pin was already "the id we
resume"; it just needs to stay current instead of being captured once. Termio
already learns the live conversation for other reasons (transcript path for the
trace, discovery for Codex/OpenCode) — the fix reuses that same signal to keep the
pin honest, rather than inventing a new source of truth.

## Where the live id comes from, per resume style

Each `ResumeStyle` exposes its *current* conversation through a different channel,
which is what makes a single reconcile point clean rather than a pile of special
cases. The reconcile only needs one question answered per style: **given the live
transcript path Termio just learned, what conversation id does it name?**

| Style | Agent | Transcript naming | Live id source | Advances on rotation? |
| --- | --- | --- | --- | --- |
| `claudeStyle` | Claude Code | `<id>.jsonl` — filename *is* the id | Hook-delivered `transcript_path`, event-driven | ✅ implemented (Phase 1) |
| `piStyle` | Pi | `<timestamp>_<id>.jsonl` — id is the trailing stem component | Filename glob (transcript discovery not yet wired) | ⏸ audit-gated (Phase 3) |
| `codexStyle` | Codex | `rollout-*.jsonl` — id lives *inside* the file (`session_meta.payload.id`) | `AgentSessionStore` scan | ⏸ re-discovery (Phase 3) |
| `openCodeStyle` | OpenCode | id in a metadata record / SQLite row, not the filename | `AgentSessionStore` scan | ⏸ re-discovery (Phase 3) |
| `none` | shell / others | — | — | n/a |

The key split:

- **Filename-encoded id** (Claude, Pi): the live transcript *path* alone yields the
  id, so reconcile is a pure `path → id` function and advancing the pin is a
  string operation on a signal Termio already holds. Claude additionally gets the
  path pushed by a hook, so it advances the instant `/clear` runs.
- **In-file / metadata id** (Codex, OpenCode): the filename does not carry the id,
  so advancing requires re-running discovery — and discovery today deliberately
  binds to the **earliest** session created after launch (`AgentSessionStore.bestMatch`,
  *"the session born when we launched this one"*) to avoid grabbing a *sibling*
  agent's session in the same directory. Flipping earliest→newest is not safe
  without a per-session identity signal, so this is left for Phase 3 rather than
  bolted on.

## Design: one reconcile seam

Model "the live conversation id from a transcript path" as a property of the
resume style, parallel to how `resumeArguments` already lives on `AgentDefinition`:

```swift
extension AgentDefinition.ResumeStyle {
    /// The agent's conversation id read from its live transcript *path*, for styles
    /// whose filename encodes the id. Returns nil when the id isn't in the filename
    /// (Codex/OpenCode carry it inside the file — advancing those is re-discovery's
    /// job, not path parsing) or the style doesn't resume.
    func conversationID(fromTranscriptPath path: String) -> String?
}
```

Then a single writer on the store, sibling to `recordLaunch` (the only other place
that writes `resumeID`), advances the pin when — and only when — the live id
differs:

```swift
func reconcileResumeID(_ id: Session.ID, transcriptPath: String) {
    guard let location = locate(id) else { return }
    var session = projects[location.project].sessions[location.session]
    guard let liveID = session.agent.resumeStyle.conversationID(fromTranscriptPath: transcriptPath),
          liveID != session.resumeID
    else { return }
    session.resumeID = liveID
    projects[location.project].sessions[location.session] = session   // didSet persists
}
```

It is fed from the one place that already learns a fresh live path — the
hook-carried branch of `applyStatusReport`:

```swift
if let path = report.transcriptPath, !path.isEmpty {
    transcriptPaths[id] = path
    reconcileResumeID(id, transcriptPath: path)   // ← advance the pin with the live path
}
```

Why this shape:

- **Trust the per-session hook path, not a directory re-glob.** The hook's
  `transcript_path` belongs to *that* session, so it stays correct even when
  several sessions share a project directory — the failure mode a "newest file in
  the dir" heuristic would have.
- **Reuses the existing source of truth.** No new state, no watcher, no second
  notion of "current session." The pin is derived from the same live path the
  trace and `sessions` CLI already use.
- **Extensible by construction.** Adding an agent is answering one question
  (`conversationID(fromTranscriptPath:)`) or, for in-file ids, wiring its
  discovery — not touching the reconcile or the launch path.
- **Safe no-op everywhere else.** For Codex/OpenCode the function returns `nil`
  (id isn't in the filename), so the seam is inert for them until Phase 3 gives
  them a real advance path — it never guesses.

## Phasing

- **Phase 1 — Claude Code (this change).** Implement `conversationID(fromTranscriptPath:)`
  for `claudeStyle` and the `reconcileResumeID` seam. Closes the reported case; the
  hook fires on `/clear` (`SessionStart source: clear`), so the pin advances live.
- **Phase 2 — Audit the rest.** Empirically confirm, per agent, whether its
  clear/`new` command rotates the on-disk id and what per-session signal Termio
  receives (hook field vs scan-only). Some may be non-bugs (like `/compact`).
- **Phase 3 — Generalize.** For filename-encoded ids (Pi) wire transcript discovery
  and enable its `conversationID` case. For in-file ids (Codex/OpenCode), make
  discovery advance to the live session behind a sibling-safety guard (agent-reported
  id, or cwd-match + single-candidate), rather than the current earliest-match.
- **Phase 4 — Reopen-time safety net.** If a tab is closed *before* any post-`/clear`
  hook fires, the pin never advanced. Have `resolveLaunch` reconcile from the newest
  transcript for the cwd when the pinned conversation no longer exists, instead of
  launching a stale `--session-id`. Small residual window; deferred until the above
  land.

## Relationship to other designs

`20260628-session-history-search-resume.md` §二 proposes a durable `agentSessionID` captured
at spawn for a future history/search feature. That is the same underlying fact as
this pin but for a different consumer (an index of *past* sessions). When that lands,
both should read from one reconcile point rather than two capture mechanisms — this
seam is the natural home. `20260711-agent-transcript-survey.md` documents each agent's
on-disk format and is the reference for the Phase 3 per-agent discovery work.
