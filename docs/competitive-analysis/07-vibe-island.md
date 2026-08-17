---
title: "Competitive analysis: Vibe Island family (status monitors)"
status: done
type: research
created: 2026-06-27
updated: 2026-07-02
---

# Vibe Island family (status monitors)

> Doesn't take over the terminal; only answers "what state is the agent in
> right now". The **source of Termio's status-detection methodology** — but
> because Termio owns the PTY, it achieves the zero-config detection these
> tools can't.

## One-line positioning

Notch / Dynamic-Island or menu-bar-tray style macOS utilities that **monitor
the status of Claude Code and other agents** (busy / waiting for you / done).

## Vendor / open source / links

- The original is closed-source: https://vibeisland.app
- **Key open-source references**:
  - **`Octane0411/open-vibe-island`** (GPL, Swift) — the best blueprint:
    `hook → unix socket → SessionState.apply reducer → notch UI`;
  - `farouqaldori/vibe-notch`;
  - `gmr/claude-status` (status file + Darwin notifications + FSEvents + 5s
    polling — redundant multi-channel);
  - `sooink/claude-watch` (**no hooks**; infers state by tailing
    `~/.claude/projects/*.jsonl` directly).

## Detection mechanisms (most reliable → most fragile)

1. **Claude Code hooks** (`UserPromptSubmit`/`PreToolUse` → busy,
   `Notification` + `permission_prompt` → waiting for you, `Stop` → done),
   reported over local IPC — **most accurate**.
2. **Tailing the JSONL transcript** to infer state — no hooks needed, but the
   schema is unstable.
3. OTLP telemetry / Codex app-server JSON-RPC — clean protocols but coarse.
4. The process tree is used only for **validation**; nobody relies on screen
   scraping or CPU usage to judge busy/idle.

## "Waiting for your input" is the hardest state

Claude Code emits only a single `Notification` signal, and it conflates
"waiting for permission approval (reliable, immediate)" with "waiting for a
free-text answer (approximated by a ~60s timer)". Precise disambiguation needs
hooks + JSONL combined.

## Strengths / weaknesses

- Strengths: zero intrusion — install and you can watch status; many
  open-source clones, mature methodology.
- Weaknesses: **status only** — they don't own the session/terminal; mostly
  bolt-ons that get signals indirectly via hooks/JSONL.

## vs. Termio / takeaways

- **Termio's structural advantage**: because it **owns the PTY**, it already
  achieves zero-config "needs you" from libghostty's native bell / OSC 9·99
  notifications — something the Vibe Island-style bolt-ons cannot do.
- **To get per-turn precision ("thinking / which tool is running")**, Termio
  still needs the **Claude Code hooks layer**: a local listener, correlating
  sessions by unique `cwd`/worktree path (Termio's per-session worktree
  conveniently provides a unique cwd). The best implementation blueprint is
  `open-vibe-island`'s `hook → socket → reducer`.
- **Form factor**: Termio chose the **menu-bar tray** (already built) over the
  notch — more restrained, doesn't cover content.

## References

- https://vibeisland.app
- https://github.com/Octane0411/open-vibe-island | https://github.com/gmr/claude-status
- https://github.com/sooink/claude-watch
- Claude Code hooks: https://code.claude.com/docs/en/hooks-guide
