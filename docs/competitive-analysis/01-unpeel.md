---
title: "Competitive analysis: Unpeel"
status: done
type: research
created: 2026-06-27
updated: 2026-07-02
---

# Unpeel

> Termio's **design prototype** and direct benchmark. Complete philosophy, all
> four differentiators present; closed-source, single maintainer.

## One-line positioning

Native macOS terminal that "puts every AI coding agent in one place as a
teammate", with a built-in **Sessions MCP** that lets one agent read/drive
another agent's session.

## Vendor / open source / links

- Author: Tommy Vedvik (indie developer, @tommyvedvik)
- Open source: no (closed-source commercial product)
- Price: **$59 one-time purchase** (7-day trial, no account required); first
  year of updates included, renewals at half price
- Site: https://unpeel.com

## Tech stack & form factor

- **Swift + libghostty** (same terminal core lineage as Termio and cmux), Metal
  rendering, native — not Electron.
- Apple Silicon only, native macOS app; local-first, **no telemetry, no cloud,
  no account**.

## Core capabilities

- **Project → session sidebar**: sessions auto-title from the first prompt and
  are grouped by project; the sidebar reads like a dashboard (who's busy, who's
  done, who needs you).
- **Sessions MCP** (the signature feature): a local MCP server that lets any
  session safely "see and drive" its sibling sessions — read output, type
  prompts, answer menus on their behalf, even start/stop sessions. Scoped per
  project by default, can be disabled entirely. This is the core of its
  "agents orchestrating agents, humans out of the per-keystroke loop" story.
- **Never-die sessions**: each session runs in an independent host process —
  **agents keep working after quit / crash / window reopen**. A persistent
  menu-bar icon spins while someone is working, rings when someone needs you,
  and clicking it brings the window back to that session.
- **Built-in git worktrees**: one branch and one checkout per agent, grouped by
  project, so agents never step on each other.
- **Quick presets**: Claude / Codex / Gemini etc., launched with the right
  flags and project in one click.
- **Deliberately no diff / code panel**: "the agent already lives in the code";
  Unpeel keeps only the conversation.

## Strengths

- Complete philosophy: never-die / status dashboard / Sessions MCP / worktrees
  — all four pillars present, positioning is crisp.
- Local-first and privacy-friendly; one-time purchase, restrained pricing.
- Highly aligned with Termio's philosophy — Termio's best "north star".

## Weaknesses

- Closed-source, single maintainer — iteration and ecosystem speed are limited.
- Apple Silicon / macOS only.
- Far less mindshare and community than the open-source cmux (see
  [02](02-cmux.md)).

## vs. Termio / takeaways

- **Same lineage, same philosophy**: Swift + libghostty, project/session
  sidebar, menu-bar pulse, worktrees, no diff, local-first. Termio is
  essentially an "open-source, customizable" re-implementation of Unpeel.
- **Already matched by Termio**: the status dashboard (zero-config, and less
  fragile than a bolt-on because Termio owns the PTY), worktrees, the menu-bar
  tray, settings.
- **Two remaining moats**:
  1. **Sessions MCP** — high value, medium cost (the official
     `modelcontextprotocol/swift-sdk` exists); should be the next-phase P0;
  2. **Never-die host processes** — highest value but the biggest rework;
     tackle it after MCP is stable.
- **Where Termio can surpass Unpeel**: open source / customizable, a broader
  agent-preset surface (OpenCode / Pi / …).

## References

- Product site: https://unpeel.com
- Author: https://x.com/tommyvedvik
