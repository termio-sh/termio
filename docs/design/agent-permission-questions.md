---
title: Agent permission questions on the phone
status: built, measured, shelved
type: design
created: 2026-08-03
updated: 2026-08-03
related:
  - mobile-agent-ui-protocol.md
---

# Design: answering an agent's permission prompt from the phone

> Built end-to-end on `feat/ios-input-lift`, proven working, then shelved —
> not because the mechanism failed, but because the users who would benefit
> are the ones who keep permissions *on*, and we don't know how many there are.
> This document exists so the next attempt starts from measurements instead of
> from the same first draft.

## 1. The problem

An agent's permission prompt is the one interaction a phone must handle every
single turn, and it is the worst thing to touch through a terminal grid: a
three-line menu rendered at 80 columns, answered by hitting a digit somewhere
on a 390pt screen.

## 2. The route not taken: reading the screen

The obvious approach — and the one yetone demonstrated on 2026-08-02 to ~216k
views (see `mobile-agent-ui-protocol.md` §12) — is to hook the renderer,
pattern-match the TUI's widgets, and redraw them natively. A first version of
this was written here: `TUIWidgetScanner`, ~130 lines of regex over the bottom
rows of the grid, with 7 tests.

It was deleted the same day. The judgement that killed it:

> 你匹配的是「Claude Code 这一版长什么样」，不是系统 API。升级即断裂。
> 做不到收敛，就会停在「某个版本 Claude Code 的美颜滤镜」。

Two things found while testing confirmed it concretely:

- The scanner assumed options like `1. Yes / 2. No`. Claude's actual second
  option that day was *"2. Yes, and always allow access to tmp/ from this
  project"* — wording that varies by tool and path.
- Claude's own startup menu says **"Enter to confirm"**: it is cursor-driven,
  not number-driven. A digit-matching scanner is wrong about half of that
  agent's own menus, never mind other agents.

**Rule that came out of it:** a rule that needs to know it is Claude, and which
version, should not exist. Screen reading survives only as *widget archetype*
detection (a cursor-marked vertical list, which Ink / Bubble Tea / Textual all
render alike), answered with arrow keys rather than digits.

## 3. The route taken: ask the agent

Termio is not an emulator. It installs hooks, reads agent manifests, and owns
the session lifecycle — so it does not have to guess what the agent is asking.
It can be told.

> **A TUI menu is not the question. It is the agent's rendering of the
> question.** The question itself exists upstream, in a channel the agent
> publishes deliberately. Intercept it before it becomes pixels.

### Measured contract (claude 2.1.220, 2026-08-03)

Everything below was verified against a real `claude`, interactively — not read
off documentation. **Re-verify on major Claude Code upgrades.**

| Fact | Evidence |
|---|---|
| `PreToolUse` carries `tool_name`, `tool_input`, `tool_use_id`, `permission_mode`, `cwd`, `session_id`, `transcript_path` | hook payload dump |
| **The agent blocks while the hook runs** | a 15s hook showed the ordinary `Forging… (11s) · esc to interrupt` spinner — no ugly intermediate state |
| **`permissionDecision: "allow"` genuinely grants permission** | hook-less baseline showed `Do you want to proceed? ❯1. Yes / 2. Yes, and always allow… / 3. No` and created nothing; with the hook, no menu and the command ran |
| `"deny"` blocks, and `permissionDecisionReason` reaches the agent | agent reported the refusal in its reply |
| Hook timeout: 600s default, per-hook `timeout` field in seconds | settings |
| ❌ **`PermissionRequest` never fires** in this build | hook installed, log stayed empty across four runs, including cases that genuinely needed permission |
| ⚠️ An explicit `permissions.ask` rule **outranks** hook `allow` | menu still appeared |
| ⚠️ Print mode (`-p`) hard-denies anything needing approval regardless of hooks | permission behaviour can only be tested interactively |

### Shape

```
PreToolUse hook ──▶ `termio agent ask` (blocking, 90s)
                        │  raw hook payload over the control socket
                        ▼
                   PermissionBroker (holds the question, 45s)
                        │  question ──▶ every client watching that session
                        ▼
                   answer ──▶ hook prints permissionDecision ──▶ agent resumes
```

Each layer gives up **before** the one above it — app 45s < CLI 90s < hook 120s
— so a stall always ends in the agent's own menu rather than a killed hook.

Wire: `question` / `questionClosed` (Mac → phone) and `answer` (phone → Mac).
No keystroke is ever encoded, because the answer is redeemed as the hook's
return value, not aimed at a menu that may have moved.

### The rules that make it safe

1. **Fail open, always.** No app, no session id, no watcher, no answer in time,
   unparseable payload, or an app too old to know the op — every one of them
   defers, and deferring prints nothing, which is exactly today's behaviour.
   *Verified against a running release build that had never heard of the op.*
2. **Never hold a question for a session no remote client is watching.** The
   desktop already has a working menu; holding would replace it with a spinner.
3. **Only ask what the agent would have asked.** `PreToolUse` fires for *every*
   tool call, so read-only tools, `bypassPermissions` sessions, and edits under
   `acceptEdits` must defer. Without this the phone lights up on every file
   read — the fastest way to make the feature something people turn off.
4. **Coalesce identical questions.** One decision gets one card and one answer,
   however many hook entries fired.

### Proven end to end

A scripted stand-in for the phone, attached over the companion protocol:

```
QUESTION: {"title":"Run a shell command","id":"q1",
           "detail":"mkdir -p /tmp/termio-probe-x",
           "options":[{"id":"allow","label":"Allow"},{"id":"deny","label":"Deny"}]}
-> tapped Allow
CLOSED: q1
```

The directory was created; the session screen read *"Done — created"* with no
permission menu ever drawn.

## 4. Why it is shelved

**The users it helps are the ones who keep permissions on, and we don't know
how many those are.** The Mac that built it runs `claudeCode` with
`agents.bypassPermissions`, i.e. `--dangerously-skip-permissions` — so no
prompt is ever raised and the card never appears. Permissions had to be turned
back *on* artificially to test it at all.

That is the question to answer before writing more code, not after.

## 5. Known defects in the shelved branch

1. **The installer duplicates the ask entry.** One clean launch produces
   `[ask, report, ask]`; it reached 8 entries over several launches. Root cause
   not found. Harmless in practice only because of rule 4 above.
2. **Cross-channel clobber.** Release and dev apps share one global
   `~/.claude/settings.json`; each strips the other's entries, so the release
   app silently disables the feature whenever it re-asserts its hooks.
   `agent ask` would need to fan out across channels the way `agent report`
   already does — or hooks need per-channel files.
3. **The companion server restarted mid-test and dropped attached clients.**
   Possibly pre-existing; not investigated.

## 6. What would have to be true to revive it

- Evidence that a meaningful share of users run agents with permissions on.
- Defect 2 fixed, or the whole thing scoped to one channel.
- A story for the Mac's own pane: today it shows a spinner while a question is
  held, because only phones render the card.

Branch: `feat/ios-input-lift` (3 commits, builds, 9 tests). Protocol context:
`mobile-agent-ui-protocol.md` §6.4.
