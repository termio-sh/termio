---
title: "Termio differentiation, gaps, and risks"
status: done
type: research
created: 2026-06-27
updated: 2026-07-02
---

# Termio differentiation, gaps, and risks

> Cross-cutting conclusions synthesized from the per-product docs
> ([01](01-unpeel.md)–[08](08-warp.md)).

## 1. Established differentiation

1. **Native + libghostty + zero-config status dashboard + menu-bar tray**:
   beats Crystal (Electron) and claude-squad (TUI) on polish; beats cmux (pane
   border rings, no menu-bar tray) on "always-on ambient presence"; and beats
   the Vibe Island-style bolt-ons because Termio owns the PTY and can emit
   "needs you" with **zero configuration**.
2. **First-class, app-automated local git worktrees**: cmux's worktrees are
   only a "recommended pattern"; Termio makes auto-create/isolate/cleanup per
   session a first-class capability — a clear gap cmux left open.
3. **Deliberately no diff**: a clean dividing line against Conductor / Crystal
   / Cursor — lighter and focused on the conversation.
4. **Local-first, no account, open-source and customizable**: a hard selling
   point for privacy/intranet users (the inverse of Warp), and more
   customizable than Unpeel (closed-source, single maintainer).

## 2. Capability gaps (ranked by moat value / implementation cost)

| Priority | Gap | Value | Reference implementation |
| --- | --- | --- | --- |
| **P0** | **Per-turn working state (hooks layer)** | Upgrades the status dashboard from "needs you" to full "busy/done/needs you"; low cost | `Octane0411/open-vibe-island` (hook → socket → reducer); the per-session worktree already provides a unique cwd for correlation |
| **P0** | **Sessions MCP** | Unpeel's soul; cmux has only a socket API; "agents orchestrating agents", medium cost | `modelcontextprotocol/swift-sdk` + the `iterm-mcp`/`libtmux-mcp` toolsets |
| **P1** | **Sessions that survive app exit (host process)** | Unpeel/cmux signature; the biggest rework | `neurosnap/zmx` (built on libghostty-vt), `wezterm` mux-server, `dtach`, claude-squad's tmux approach |

Recommended order: hooks first (small, immediate payoff, completes the status
dashboard) → then Sessions MCP (medium, a moat) → finally the never-die host
(large; take it on once MCP is stable).

## 3. Risks

- **cmux's overwhelming mindshare**: same foundation, open-source, YC, 23k★ —
  the category is validated. Termio **must not fight on breadth/mindshare**;
  hold only "opinionated minimalism + first-class worktrees + menu-bar
  ambience".
- **Category absorbed by giants**: if Cursor/VS Code or Warp build a
  "multi-agent session dashboard + status" into their main products, indie
  tool space shrinks. Hedge: native and lightweight + no account + not an IDE.
- **Single upstream dependency**: `libghostty-spm` (an individually maintained
  prebuilt XCFramework) — if it stalls, Termio is stuck; pin versions, watch
  its activity.
- **Agent CLI protocol drift**: status detection depends on Claude Code hooks
  / OSC behavior, which agent upgrades may change. **The zero-config
  (bell/OSC) layer is more drift-resistant than hooks and must always remain
  the baseline.**
- **"No diff" cuts both ways**: focus buys lightness, but some users want
  in-app review; redirect them with clear copy toward "the agent lives in the
  code + review with git/IDE" rather than bolting on a panel mid-course and
  breaking the positioning.

## 4. One-sentence conclusion

The only remaining gaps between Termio and **Unpeel** are Sessions MCP and
never-die; the contest with **cmux** is not about breadth but about
**"minimal yet opinionated + first-class worktree automation + always-on
menu-bar ambience"**. Sticking to "small and focused, no code panels,
local-first" is the fundamental stance that distinguishes Termio from every
competitor — and one none of them can casually copy.
