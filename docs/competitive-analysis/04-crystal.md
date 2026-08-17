---
title: "Competitive analysis: Crystal / Nimbalyst"
status: done
type: research
created: 2026-06-27
updated: 2026-07-02
---

# Crystal / Nimbalyst (stravu/crystal)

> The open-source reference with the **most mature merge-back experience** in
> the category; but Electron, and on the diff route.

## One-line positioning

Multi-session Claude Code, one git worktree per session, with the most refined
**rebase / squash / diff preview** flow.

## Vendor / open source / links

- Open source (later renamed Nimbalyst). GitHub:
  https://github.com/stravu/crystal | https://nimbalyst.com/crystal/
- Tech stack: Electron + TypeScript (core in `worktreeManager.ts`).

## Core capabilities

- One worktree and one branch per session; **three merge UIs**: rebase from
  main / squash then rebase / view diff before apply.
- Hovering shows **the exact git commands about to run** (transparent,
  learnable); auto-creates an initial commit in empty repos.

## Strengths

- **The most mature reference for worktree lifecycle + merge UX** in the
  category, and open-source/readable.
- A complete experience for users who want both parallelism and careful
  merging.

## Weaknesses

- **Electron** (not native, heavy) — the fit and finish trail
  Termio/cmux/Unpeel.
- On the diff/review route, large surface area.

## vs. Termio / takeaways

- **Borrow its git plumbing directly**: the worktree create/list/lock/clean
  command sequences, branch naming, and the safety rule of "check
  dirty/untracked/unpushed before destroy".
- "Hover to reveal the real git commands" is a good interaction pattern for a
  tool like Termio that is **opinionated but wants to stay transparent**.
- Termio should not compete on merge-UI richness — Termio's merge story should
  stop at "view diff (externally) + push/PR" and stay light.

## References

- https://github.com/stravu/crystal | https://nimbalyst.com/crystal/
