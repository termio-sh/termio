# Termio competitive analysis

> Version: 2026-06-27 | Corresponding Termio progress: Milestones 1–5
> (project/session sidebar, PTY persistence, agent presets, status + menu-bar
> tray, 5-page settings, per-session git worktrees)

One standalone doc per product in this directory. Reading order is by "how
directly it competes with Termio".

## Contents

| # | Product | One line | Relationship to Termio |
| --- | --- | --- | --- |
| [01](01-unpeel.md) | **Unpeel** | Native Mac terminal + Sessions MCP; Termio's benchmark prototype | Direct benchmark (design prototype) |
| [02](02-cmux.md) | **cmux** (manaflow-ai) | Native Swift+libghostty terminal, YC-backed, 23k★ | **Most direct competitor (same foundation)** |
| [03](03-conductor.md) | Conductor | Mac-native, worktree parallelism + in-app review | Opposite philosophy (diff-heavy) |
| [04](04-crystal.md) | Crystal / Nimbalyst | Electron, multi-session + best merge-back UX | Reference (worktrees/merging) |
| [05](05-claude-squad.md) | claude-squad | Go TUI, tmux + worktrees | Reference (git plumbing) |
| [06](06-container-use.md) | container-use | Container isolation + branch-as-environment | Too heavy (isolation ideas only) |
| [07](07-vibe-island.md) | Vibe Island family | Notch/tray status monitors | Source of status-detection methodology |
| [08](08-warp.md) | Warp | AI-native general-purpose terminal | Alternative paradigm |
| [10](10-landscape-table-2026-07.md) | **Landscape table 2026-07** | Every notable open/closed product in one table + Termio highlights | **Latest consolidated view** (adds herdr, muxy, vibe-kanban, JetBrains Air, GitKraken Kepler, Warp Oz, Happy, Sculptor) |

> Also under "alternative paradigms": Cursor / VS Code + extensions
> (IDE-built-in agents, diff-heavy — the opposite of Termio), Ghostty /
> WezTerm / iTerm2 (Termio's **foundation**, not competitors), plain tmux
> hand-rolling (the DIY baseline).

## Termio capability snapshot

| Capability | Status | Notes |
| --- | --- | --- |
| Native libghostty terminal | ✅ | `.exec` real PTY, Metal rendering, not Electron |
| Project → session sidebar | ✅ | Sessions grouped by project; session tree persists (sidebar survives restart) |
| Session survival (SurfaceCache) | ✅ | Switching sessions doesn't kill the shell; **PTY is not preserved after quitting the app** |
| Agent presets | ✅ | Terminal / Claude Code / Codex / OpenCode / Pi, with brand logos |
| Session status (busy/done/needs you) | ✅ | Sidebar status dots + menu-bar tray pulse/ring, zero-config |
| Live titles (OSC title) | ✅ | Agents describe their current action via the title |
| 5-page settings, live-applied | ✅ | appearance / interface / terminal / agents / worktrees |
| Per-session git worktree | ✅ | Each session edits its branch in an isolated worktree |
| **Sessions MCP (cross-session orchestration)** | ❌ | Let one agent read/drive another session |
| **Never-die session host** | ❌ | Agents keep running after the window closes; reconnect and replay |
| **Per-turn working state (hooks layer)** | 🟡 | Currently only zero-config bell/notifications; missing continuous "thinking" |

## Cross-product capability matrix

| Capability | Termio | cmux | Unpeel | Conductor | Crystal | claude-squad |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| Native (not Electron) | ✅ | ✅ | ✅ | ✅ | ❌ | ➖ TUI |
| libghostty terminal core | ✅ | ✅ | ✅ | ? | ❌ | ❌ |
| Multi-agent session dashboard | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Status visualization (busy/needs you) | ✅ | ✅ | ✅ | 🟡 | 🟡 | 🟡 |
| **Menu-bar pulse tray** | ✅ | ❌ (pane ring) | ✅ | ? | ❌ | ❌ |
| **App-managed worktrees** | ✅ | 🟡 (pattern only) | ✅ | ✅ | ✅ | ✅ |
| Sessions MCP / agents driving agents | ❌ | 🟡 (socket API) | ✅ | ❌ | ❌ | 🟡 |
| Sessions survive app exit | ❌ | 🟡 (restore) | ✅ | ? | ❌ | ✅ (tmux) |
| Diff / code review panel | ⛔ deliberately none | ⛔ none | ⛔ deliberately none | ✅ | ✅ | ❌ |
| Local-first / no account | ✅ | ✅ | ✅ | ? | ✅ | ✅ |
| Open source | ❌ private | ✅ GPL | ❌ closed | ❌ | ✅ | ✅ |

> Legend: ✅ yes | 🟡 partial | ❌ no | ⛔ deliberately not built | ➖ different form factor | ? unverified

## Conclusion (up front)

The only real gaps between Termio and its benchmark **Unpeel** are two:
**Sessions MCP** and the **never-die host**. But the real market threat is
**cmux** — also native + libghostty + local-first + status visualization + no
diff, and already validated by YC and 23k★ for the entire category. Termio
cannot beat cmux on "breadth/mindshare"; **the only defensible moat is
"minimal yet opinionated": make the project → session → worktree flow
first-class automation, and make the menu-bar tray an always-on ambient
presence** — exactly the ground that neither cmux (sprawling primitives, no
menu-bar tray, worktrees only a recommended pattern) nor Conductor/Crystal
(diff-heavy) occupies. Sticking to "small and focused, no code panels,
local-first" is the fundamental stance that distinguishes Termio from every
competitor.

See the per-product docs and
[09-differentiation-and-gaps.md](09-differentiation-and-gaps.md) for details.
