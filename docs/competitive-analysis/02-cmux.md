---
title: "Competitive analysis: cmux (manaflow-ai)"
status: done
type: research
created: 2026-06-27
updated: 2026-07-02
---

# cmux (manaflow-ai)

> **Termio's single most direct competitor**: also native Swift + libghostty +
> local-first + status visualization + no diff. But open-source, YC-backed,
> ~23,000★ — it has already validated the entire category.

## Disambiguation ("cmux" is a heavily overloaded name)

1. **manaflow-ai/cmux (cmux.com)** — the subject of this doc. Native macOS
   libghostty terminal, built for running AI coding agents in parallel.
2. **Manaflow's earlier cmux (cmux.sh)** — the same company's **previous
   product**: an agent manager built on cloud/Docker containers + VS Code
   workspaces, with a git diff viewer. The company has **pivoted** to the
   native terminal. ⚠️ "Run agents in isolated cloud containers + diff viewer"
   belongs to the **old architecture** — don't confuse it with the current
   flagship.
3. **craigsc/cmux** — an unrelated pure-Bash CLI, "tmux for Claude Code",
   ~574★.
4. (`soheilhy/cmux` is a Go connection-multiplexing library, entirely
   unrelated.)

Everything below refers to **#1**.

## One-line positioning

"The open-source terminal built for coding agents" — native macOS, built on
Ghostty, runs multiple agents in parallel as **native panes/splits/tabs**, with
an emphasis on **programmability** and **multitasking**.

## Vendor / open source / links

- Vendor: **Manaflow** (YC **S24**, an "open-source applied-AI lab"); founders
  Lawrence Chen and Austin Wang.
- Open source: **yes**, **GPL-3.0-or-later** (some materials say AGPL), with a
  **commercial license** sold separately.
- GitHub: https://github.com/manaflow-ai/cmux — **~23k★ / ~1.8k forks**, 48+
  releases. Launched around 2026-02, hit ~17k★ within two weeks, #2 on HN,
  endorsed by Ghostty author Mitchell Hashimoto.
- Site: https://cmux.com

## Tech stack & form factor

- **Native macOS, Swift + AppKit, built on libghostty** (as a library, not a
  fork), GPU-accelerated; **not Electron**.
- Distribution: DMG + **Sparkle auto-update**, **Homebrew cask**
  (`brew install --cask cmux`), nightlies. **Not on the Mac App Store**
  (GPL/Sparkle incompatible).
- **Local-first; the terminal itself needs no account**, and it reads your
  existing `~/.config/ghostty/config` directly.
- Platforms: currently **macOS only**; Linux in public beta, Windows
  waitlisted, plus an **iOS companion app** (real-time sync).

## Core capabilities

- **Parallel agent sessions**: each agent runs in a native **pane/split/tab**
  (not a hidden background process); a **vertical tab sidebar** shows each
  tab's git branch, working directory, active ports, and associated PR
  number/status.
- **Agent-agnostic**: anything that runs in a terminal is supported — Claude
  Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor
  Agent, Grok; with special integrations for **Claude Code Teams** and
  **oh-my-opencode** multi-model orchestration (sub-agents render as real
  panes).
- **Status visualization (the signature "Notification Rings")**: when an agent
  in a pane is waiting for input, the **pane border lights up with a blue
  ring**; plus sidebar unread badges, a notification popover, and macOS
  desktop notifications. Triggered via terminal escape sequences (OSC
  9/99/777) or the cmux CLI. The design goal is **watching 5–10 concurrently
  blocked agents without polling**.
- **git worktrees**: recommends "one tab per worktree" for per-PR isolation —
  but **worktree lifecycle is not deeply automated in the app core**; it's
  more a **recommended pattern** surfaced through the sidebar's branch/PR
  metadata (third-party articles often oversell it as "fully automatic").
- **No diff/review**: the native terminal is **conversation/terminal only**;
  the sidebar shows branch + PR number but there is **no built-in diff panel**
  (the diff viewer lives in the old cloud product).
- **Lightweight cross-agent orchestration**: a **CLI + Unix socket API** can
  create workspaces, control panes, inject keystrokes, and **spawn other
  agents**; agents can also drive an **embedded scriptable browser** (read the
  AX tree, click, fill forms, run JS). Positioned as "composable primitives",
  not MCP-style governed orchestration.
- Session restore (windows/panes/scrollback); SSH remote workspaces; no
  terminal web UI (only the old cloud product had one).

## Strengths

- Native Swift/libghostty: fast, no Electron baggage.
- **Huge and fast-growing mindshare and endorsements** (23k★, Hashimoto, YC) —
  the category demand is already validated.
- Truly agent-agnostic; Notification Rings are an effective answer to "which
  agent is stuck".
- Programmable: socket API + embedded scriptable browser + a CLI for spawning
  agents.

## Weaknesses

- macOS only (Linux beta, Windows waitlist) — narrow coverage.
- **No diff/review in the terminal** — you switch to GitHub or an editor.
- **Worktrees are a "pattern", not first-class automated UX**; **no menu-bar
  tray** model.
- Copyleft (GPL/AGPL) + commercial licensing will deter some adopters.
- Large surface area (browser panes, SSH, socket API, iOS, Teams) —
  "composable primitives" = not opinionated / not guided enough.
- Product identity drift (cloud container manager → native terminal) muddies
  its positioning.

## vs. Termio / takeaways

- **Points of convergence**: both native macOS, local-first, status-indicating
  sidebar, **no diff**, worktree-oriented. Termio's status dots ≈ cmux's
  notification rings/badges; Termio's project → session sidebar ≈ cmux's
  vertical tabs. **What Termio is building is exactly the category cmux has
  validated.**
- **Termio is deliberately narrower and cleaner**: **project → session
  hierarchy + menu-bar tray** + **first-class, app-automated local worktrees**
  — a small, opinionated surface. cmux is more "kitchen sink": embedded
  browser, SSH, socket automation, Claude Teams, multi-model orchestration,
  iOS, plus its cloud/Docker sandbox heritage — optimized for "programmable +
  multi-pane".
- **The defensible angle**: Termio = **opinionated minimalism + first-class
  worktree automation + always-on menu-bar ambience**; these are precisely
  cmux's two gaps (no deep worktree lifecycle, no menu-bar tray, diff
  relegated to the de-emphasized cloud product).
- **Where not to fight head-on**: breadth, mindshare, community, programmable
  surface — don't compete with cmux on these dimensions.

## References

- Repo: https://github.com/manaflow-ai/cmux | Site: https://cmux.com
- YC Launch: https://www.ycombinator.com/launches/PbB-cmux-the-open-source-terminal-built-for-coding-agents
- Technical deep dive: https://www.oflight.co.jp/en/columns/cmux-manaflow-ai-agent-terminal-2026
- Old cloud product (cmux.sh) background: https://www.scriptbyai.com/coding-agents-parallel-manaflow/
