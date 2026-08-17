---
title: "Competitive analysis: Superset (superset.sh)"
status: done
type: research
created: 2026-07-25
updated: 2026-07-25
related:
  - 02-cmux.md
  - 09-differentiation-and-gaps.md
---

# Superset (superset.sh)

> **The heavyweight in Termio's exact category**: YC-backed, ~11k★ in 5 months,
> orchestrates CLI agents in parallel **git worktrees** with built-in terminal,
> diff/review, editor, remote hosts, CLI/SDK/MCP. Where cmux converged on
> Termio's *terminal* bets, Superset converged on the *worktree + review +
> remote* bets — but on Electron, with accounts and a cloud sync layer.

Source: local clone at `~/Documents/GitHub/superset` (commit 5f7b79f,
2026-07-25, v1.17.0). Facts below are read from the source, not marketing.

## One-line positioning

"The Code Editor for AI Agents" — run swarms of Claude Code, Codex, etc. in
parallel, each task isolated in its own git worktree, with agent monitoring,
built-in terminal/diff/editor, and one-click handoff to your real editor.

## Vendor / open source / links

- Vendor: **Superset, Inc.**, YC-backed ("the open source IDE for the AI
  Agents era"). Product Hunt **#1 product of the day 2026-02-27**; ~**11k★ /
  75+ contributors** within 5 months. Very fast shipping (~20 commits in the
  week before this snapshot).
- License: **Elastic License 2.0** — source-available, *not* OSI open source;
  blocks competing SaaS offerings while staying free for users.
- Repo: https://github.com/superset-sh/superset · Site: https://superset.sh ·
  Docs: https://docs.superset.sh
- Monetization signals in-tree: `better-auth` accounts + Stripe subscriptions
  table (`packages/auth`), ElectricSQL local→cloud sync, Next.js `apps/api` +
  `apps/admin` — a hosted/team tier is clearly coming; the desktop app itself
  is free.

## Tech stack & form factor

- **Electron 40 + React 19** desktop app (electron-vite, zustand, TanStack,
  react-mosaic panes) — *not* native. Terminal is **xterm.js 6 beta** with the
  WebGL addon. Bun/Turbo monorepo with ~11 apps (desktop, web, api, admin,
  marketing, docs, relay, streams, **Expo iOS app**…) and ~20 packages.
- **PTY ownership: a standalone `pty-daemon`** (`packages/pty-daemon`, Node +
  node-pty) that outlives the app process. Sessions are held in the daemon
  (64KB ring buffer each, memory-only), so **terminals survive app restarts**
  as long as the daemon lives; an AF_UNIX **fd-handoff protocol** even lets
  sessions survive daemon *binary upgrades*. Desktop reconnects/attaches on
  relaunch.
- Distribution: DMG via electron-builder + Homebrew bump scripts; macOS today,
  iOS companion via Expo.

## Core capabilities

- **Worktree-first workspaces**: every task workspace is `git worktree add`
  under `~/.superset/worktrees/`, own branch/terminal/env, per-workspace port
  allocation. This is the product's central bet — compare the results of N
  parallel agents and merge the winner.
- **Agent integration via shell hooks**: 12 built-in agents (claude, codex,
  opencode, amp, cursor-agent, gemini, kimi, copilot, droid, pi, …). A
  generated `notify.sh` hook posts lifecycle JSON (Start / Complete /
  PermissionRequest / PendingQuestion / Failed) to a Unix socket
  (`apps/desktop/src/main/lib/agent-setup/`). Pane status is an explicit state
  machine — `idle | working | permission | review | failed` with a priority
  order — driving chimes, macOS notifications, and a dock badge count
  (suppressed when the pane is visible). Same architecture family as Termio's
  hook + status-promotion pipeline.
- **Managed agent binaries**: Superset *installs and updates* most agents
  itself (`desktop-agent-capabilities.ts` marks 11 of 12 as managed) — the
  "self-managed install, no nag" pattern Termio deferred for LSP, applied to
  the agents themselves.
- **ACP**: host-service implements the Agent Client Protocol (0.56) with a
  persisted session registry — stateful structured sessions alongside the raw
  PTY. (Convergent with Termio's mobile-protocol choice of ACP vocabulary.)
- **Review/diff/editor built-in**: custom diff viewer on `@pierre/diffs`,
  CodeMirror 6 editor with Shiki highlighting, Tiptap-based **⌘I prompt
  editor** (multiline, @-file mentions).
- **Remote & programmability**: remote hosts via a websocket relay tunnel
  (`packages/host-service/src/tunnel/`), an Ink-based CLI, a published npm SDK
  (alpha), and **two MCP servers** (legacy + v2 exposing host-service tRPC
  routes as tools).

## Strengths

- The most complete package in the category: worktrees + monitoring + diff +
  editor + remote + mobile + CLI/SDK/MCP in one product, shipping weekly.
- Sessions that survive app restarts (pty-daemon) — a real reliability edge.
- Distribution machine: YC + PH #1 + 11k★ + 75 contributors; the category's
  mindshare race is now cmux (terminal-native) vs Superset (IDE-shaped).
- Agent-managed installs remove the "is claude on PATH?" class of failures.

## Weaknesses

- **Electron + xterm.js**: heavier, and terminal fidelity/latency is a real
  gap vs libghostty — TUI-heavy agents (Claude Code) are its worst case.
- **Account + cloud gravity**: better-auth, ElectricSQL sync, Stripe schema —
  the local app is entangled with a platform. Termio is free, no-account,
  local-only by principle.
- **Enormous surface area** (11 apps, 20 packages, relay, admin, Discord
  triage bot) for a ~1.x product — the anti-thesis of 小而美; ELv2 also isn't
  truly open source, which the "open source IDE" framing glosses over.
- Session persistence is memory-only in a daemon — a crash still loses
  everything; no disk-backed scrollback.

## vs. Termio / takeaways

- **Category validation, again**: Superset independently landed on nearly
  every Termio mechanism — worktree isolation, hook-driven status with a
  needs-attention priority, chime/badge ambience, ACP for the structured
  plane, sessions CLI. The bets are right; the fight is execution and taste.
- **Termio's defensible line vs Superset** is the mirror of its line vs cmux:
  **native Swift + libghostty rendering** (Superset's weakest layer), **free /
  no account / no cloud**, and a deliberately small surface. Don't chase its
  breadth (editor, SDK, admin planes).
- **Worth stealing**:
  1. **PTY-daemon session survival** — termio sessions die with the app
     (known gap); a host-owned daemon with attach/reconnect is the proven
     shape, and Superset shows fd-handoff makes even upgrades seamless.
  2. **Managed agent binaries** — quietly install/update agents instead of
     failing on PATH; matches the Zed-style self-managed-install rule already
     in the backlog.
  3. Explicit pane-status **priority ordering** (permission > failed >
     working > review > idle) for aggregating multi-session state into one
     badge.
- **Watch**: their v2 "unified CLI" and MCP v2 — same territory as Termio's
  sessions CLI v2 design; worth a re-read before finalizing that doc.

## References

- Repo: https://github.com/superset-sh/superset (local: `~/Documents/GitHub/superset`)
- YC launch: https://www.ycombinator.com/launches/QWj-superset-the-open-source-ide-for-the-ai-agents-era
- Coverage: https://www.founderland.ai/articles/superset-launches-ide-to-orchestrate-100-ai-coding-agents-in-mpz8db7u ·
  https://byteiota.com/superset-ide-run-10-parallel-ai-coding-agents-2026/
