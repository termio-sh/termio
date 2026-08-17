---
title: Automation — scheduled agent runs
status: draft
type: rfc
created: 2026-07-02
updated: 2026-07-02
---

# Automation — scheduled agent runs

> Let users schedule a prompt to run in a project on a recurrence (daily code
> review, nightly dependency check), configured from a new Settings ▸ Automation
> tab, executed as ordinary visible termio sessions.

## Motivation

Termio can already drive agents programmatically — the `termio sessions`
control plane types prompts into live PTYs and reads replies from transcripts.
What's missing is the *user-facing* layer: a way for a person to say "run this
prompt in this project every morning at 9" without scripting anything. Sibling
products (sarea) ship this as a first-class feature; for Termio it is a natural
extension of machinery that already exists (session spawning, hooks-based
status, the menu-bar tray).

## Research inputs

### Claude Code's native automation surface (verified 2026-07-02)

- Headless mode is real: `claude -p "prompt" --output-format stream-json`,
  resumable via `-p --resume <session-id>`, forkable via `--fork-session`.
  There is **no** supported IPC into a running interactive TUI session — PTY
  keystrokes remain the only way to drive one.
- `--dangerously-skip-permissions` (= `--permission-mode bypassPermissions`)
  works in both interactive and `-p` mode. It refuses to start as root and
  keeps circuit breakers (`rm -rf /`). Docs recommend isolated environments —
  Termio's per-project Seatbelt sandbox is exactly that.
- Read-only pre-approval: `--allowedTools "Read,Grep,Glob,WebFetch,WebSearch"`.
- Billing: with a Pro/Max subscription login, headless and interactive runs
  both draw from the plan's quota at no per-token charge (the planned June 2026
  Agent-SDK billing split was paused). Footgun: a stray `ANTHROPIC_API_KEY` in
  the environment silently wins over the subscription and bills per-token —
  automation sessions should surface or strip it.

### Prior art: sarea (`../sarea`)

Sarea ships a complete automation engine worth mining:

- **Model** (`Sources/Models/Automation.swift`): name, prompt, working dirs,
  backend id, permission mode (`allowReadOnly`/`allowAll`), full RFC 5545
  RRULE recurrence with IANA timezone, end-after-count/date; persisted to
  `~/.sarea/automations.json`; run history in `automation-runs.json`, pruned
  after 30 days.
- **Engine** (`Sources/Stores/AutomationStore.swift`): a 30-second tick loop
  fires due automations by spawning a *real session* named `Auto: <name>`,
  waiting for it to become active, then sending the prompt. Permission
  requests are auto-resolved by mode (read-ish tools allowed, everything else
  denied, unknown tools fail loud). Completed sessions are archived, not
  deleted, so a run row can re-hydrate into a browsable transcript.
- **Hardening**: backend-readiness check before firing (skip + retry next
  tick, never silently advance past a due run); orphaned `.running` runs
  marked cancelled on relaunch; debounced atomic JSON writes with quarantine
  on decode failure; `scheduleStartDate` reset on edit/resume so count-based
  series don't half-replay.
- **What we deliberately don't copy**: RRULE + timezone pickers + end
  conditions (a huge share of sarea's form complexity), a separate runs
  database, gateway credential routing, per-tool permission matrices.

The load-bearing lesson: sarea runs automations as **visible sessions**, not
invisible background jobs. That fits Termio even better — sessions *are* the
product.

## Design

### Execution: fire a real session, reuse the send machinery

An automation run is an ordinary Termio session:

1. At fire time, create a session in the automation's project (existing
   `TermioStore` session creation, including `SandboxLauncher` wrapping when
   the project is sandboxed), titled `⚡ <automation name>`.
2. Launch the agent with automation flags appended to the preset command —
   for Claude Code either `--allowedTools "Read,Grep,Glob,WebFetch,WebSearch"`
   (read-only) or `--dangerously-skip-permissions` (full access).
3. Once hooks report the session idle/ready, submit the prompt through the
   existing `send` path (the same keystroke injection `termio sessions send`
   uses). This keeps execution agent-agnostic — anything the control plane can
   drive today can be automated.
4. The existing hook pipeline (`Stop` → `.done`) marks the run complete; the
   tray already surfaces done/attention states, so no new notification system
   is needed. The session stays in the sidebar for review and is closeable
   like any other.

Rejected alternative — headless `claude -p` lane: cleaner process model and
structured output, but Claude-only, invisible (would need a whole new results
UI), and it duplicates what sessions already give us: a live view, a
transcript, resume, sandboxing. Headless remains attractive later for
CI-style/batch use, not for this feature.

### Permissions: two modes, sandbox as the backstop

- **Read-only** (default): pre-approve read tools via flags. If the agent
  still hits a permission prompt, the session simply goes to `attention` in
  the tray — a feature, not a failure; the user answers when they're back.
- **Full access**: `--dangerously-skip-permissions` (and the equivalent for
  other agents). The form shows a warning, and strongly suggests enabling the
  project sandbox — dangerous mode inside Seatbelt is the safe-unattended
  story sarea doesn't have.

### Schedule model: deliberately small

`once | hourly | daily | weekly` + time-of-day + weekday set (for weekly).
System timezone, `Calendar`-based next-occurrence computation. No RRULE, no
intervals, no end conditions — that is most of sarea's form complexity for a
sliver of its usage. If Termio is closed at fire time the run is skipped and
`nextRunAt` advances to the next future occurrence (sessions don't survive app
quit anyway; a launchd story is out of scope).

### Data model & persistence

`~/.termio/automations.json`, written atomically like `state.json`:

```swift
struct Automation: Codable, Identifiable {
    var id: UUID
    var name: String
    var prompt: String
    var projectID: Project.ID        // termio is project-scoped; no raw paths
    var agent: AgentPreset
    var schedule: Schedule           // frequency + time + weekdays
    var permissionMode: PermissionMode  // readOnly | fullAccess
    var enabled: Bool
    var lastRuns: [RunRecord]        // capped at ~20, newest first
    var nextRunAt: Date?
}

struct RunRecord: Codable {
    var startedAt: Date
    var status: RunStatus            // running | completed | failed | skipped
    var sessionID: Session.ID?       // jump back to the transcript
    var errorMessage: String?
}
```

Run history lives inline (capped) instead of a second file — enough to render
"last run ✓ 9:02 AM" and link to the session, without a retention subsystem.

### Scheduler

A 60-second timer on `TermioStore` (same pattern as the existing 30-second
stale-working sweep): collect automations with `enabled && nextRunAt <= now`,
fire each, advance `nextRunAt`. Borrow sarea's two hardening rules: check the
project/agent is launchable *before* firing (skip and retry next tick rather
than advancing past a due run), and on app launch mark any orphaned `running`
records as failed.

### Settings ▸ Automation tab

Add `case automation` to `SettingsTab` (`Sources/termio/Settings/SettingsTab.swift`)
with a new `AutomationSettingsTab.swift` following the existing tab pattern.
The 580×520 window fits a list + editor sheet:

```
┌───────────────────────────────────────────────┐
│  Automation                                   │
│                                               │
│  ┌─────────────────────────────────────────┐  │
│  │ ● Daily review     termio · 9:00 daily  │  │
│  │   last run ✓ today 9:02   next 9:00  ⏻ │  │
│  ├─────────────────────────────────────────┤  │
│  │ ○ Dep check        web · Mon 8:00       │  │
│  │   last run ✗ failed        next Mon   ⏻ │  │
│  └─────────────────────────────────────────┘  │
│  [+] [−]                                      │
└───────────────────────────────────────────────┘
```

Row: status dot (from last run), name, project · schedule summary, enable
toggle. Double-click (or +) opens an editor sheet with exactly six fields:

| Field | Control |
| --- | --- |
| Name | text field |
| Project | picker over existing projects |
| Agent | picker over `AgentPreset`s |
| Prompt | multi-line text editor |
| Schedule | frequency picker + time picker + weekday toggles (weekly only) |
| Permissions | segmented Read-only / Full access (+ sandbox hint) |

Clicking a run record selects that session in the main window (if it still
exists) so the transcript review path is the terminal itself — no bespoke
results viewer.

Automation config is structured data, so it lives in `automations.json`
managed by the store, not in `AppSettings`/UserDefaults; only tab-level
toggles (if any emerge) would go through `AppSettings`.

## Out of scope (v1)

- RRULE / custom intervals / timezones / end-after-N — add only on demand.
- Retry policy; failed runs are recorded and visible, not retried.
- Webhooks or event triggers; time is the only trigger.
- A headless `-p` execution lane and a `termio automations` CLI — both natural
  follow-ups on the same data model, neither needed to ship.
- Running while the app is closed (launchd/daemon).

## Open questions

- Should automation sessions auto-close after N days, or accumulate until the
  user closes them? (Lean: accumulate; user closes like any session.)
- Codex/OpenCode full-access flag mapping (`--full-auto` etc.) — confirm per
  preset before exposing Full access for non-Claude agents.
- Whether to strip `ANTHROPIC_API_KEY` from automation session environments to
  protect subscription users from silent per-token billing, or just document
  it.
