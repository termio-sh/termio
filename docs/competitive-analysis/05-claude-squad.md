---
title: "Competitive analysis: claude-squad"
status: done
type: research
created: 2026-06-27
updated: 2026-07-02
---

# claude-squad (smtg-ai)

> The **authoritative, copy-ready reference** for worktree git plumbing; TUI
> form factor, no native-GUI polish.

## One-line positioning

A Go TUI that manages multiple Claude / Codex / Aider sessions in parallel
using **tmux + git worktrees**.

## Vendor / open source / links

- Open source. GitHub: https://github.com/smtg-ai/claude-squad
- Tech stack: Go, TUI; underneath, tmux (session survival) + git worktrees
  (isolation).

## Core capabilities

- One independent worktree per session (kept **outside the repo**:
  `<config>/worktrees/<sanitized-branch>_<nanosecond-timestamp>`), with a
  dedicated branch prefix; new branches are created from `HEAD`'s SHA to
  guarantee a clean starting point.
- A push action (commit + push branch); cleanup chain
  `worktree remove -f → branch -D → prune`, never deleting pre-existing
  branches.
- Thanks to tmux: **sessions survive exit** (reattach).

## Strengths

- **Clean, directly reusable git plumbing** (Termio's worktree command
  sequences are modeled on it).
- Pure terminal, cross-platform, open source; tmux gives it never-die for
  free.

## Weaknesses

- TUI rather than native GUI; status visualization and brand polish far behind
  Termio/cmux/Unpeel.
- Expressiveness limited by the terminal UI.

## vs. Termio / takeaways

- **The git parts have the highest direct reference value**: the branch prefix
  + "was it pre-existing" flag in the cleanup strategy avoids deleting user
  branches by mistake; timestamped worktree directory names guarantee
  uniqueness.
- It achieves never-die with tmux — a useful "simplest viable" counterpoint
  for Termio's never-die host design (see also zmx/dtach in
  [09](09-differentiation-and-gaps.md)).
- Termio's edge is wrapping these CLI capabilities in a **native GUI with a
  status dashboard and a menu-bar tray**.

## References

- https://github.com/smtg-ai/claude-squad
