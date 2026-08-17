---
title: "Competitive analysis: container-use (dagger)"
status: done
type: research
created: 2026-06-27
updated: 2026-07-02
---

# container-use (dagger)

> Strongest isolation (container-level) + a "branch = environment" model; **too
> heavy** for Termio's "small, focused, no sandbox" positioning.

## One-line positioning

Models each agent environment as "**branch = environment, worktree =
filesystem, container = runtime**", exposed to agents via MCP.

## Vendor / open source / links

- Open source (by Dagger). GitHub: https://github.com/dagger/container-use

## Core capabilities

- Each agent environment = a branch on the `container-use/` remote + a
  worktree + a container.
- Every change is auto-committed → an audit trail; environments can be rebuilt
  from git history + git notes.
- Agents create/manipulate environments through MCP.

## Strengths

- Strongest isolation (container-level); multiple agents cannot pollute the
  host or each other.
- The auto-commit audit trail and rebuildability are valuable for
  rigor/traceability-heavy scenarios.

## Weaknesses

- Brings in **Docker** — heavy; conflicts with Termio's "no sandbox, real
  `.exec` PTY, lightweight" positioning.

## vs. Termio / takeaways

- The only thing truly worth absorbing is **one invariant**: **never check out
  the same branch in two worktrees simultaneously** — Termio's worktree logic
  must uphold this (create a new branch per session, never attach to a branch
  in use elsewhere).
- Container isolation itself is **over-engineering** for Termio and should not
  be adopted.

## References

- https://github.com/dagger/container-use
- Side reference: devflowinc/uzi (a similar CLI worktree orchestrator —
  another command-sequence reference)
