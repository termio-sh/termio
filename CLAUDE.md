@AGENTS.md

# termio

## What termio is

**A terminal-first agentic development environment, including its own remote server.**

Coding agents live in terminals. termio is the place those agents run, on machines
the user already owns — a laptop, a VPS, a devbox — supervised from a native Mac
app and an iPhone. `termiod` is the durable session host that makes "on any box"
one code path instead of four.

The category is crowded (Zed remote, VS Code Remote, Codespaces, Warp). That is a
known and accepted cost of this position, not an oversight. **Do not re-argue the
positioning.** Build it.

## What makes it different (aim here, not at editors)

- **The session lives on the box, not in the connection.** Detach ≠ kill. An agent
  keeps working while the laptop is shut; reattach restores the exact screen.
  Zed and VS Code tie remote work to a live connection; termio does not.
- **The user's machines, not our cloud.** termio never provisions compute and never
  runs a hosted control plane. The code never leaves hardware the user controls —
  the only trust story that survives giving an agent shell access to a private repo.
- **Agent-native at the protocol level.** Workstream status (`working` / `idle` /
  `needs-you` / `done`) is a first-class protocol object, not a heuristic scraped
  off the screen.
- **Terminal-first is a commitment, not a stage.** The terminal *is* the interface.
  Chat UIs have been built and fully reverted twice. Don't rebuild them.

## Architectural non-negotiables

These come from `docs/design/20260730-termiod-session-protocol.md` §A and §H. Violating one
is a design regression, not a tradeoff:

1. **Anti-100× invariant** — byte delivery never blocks on host-side VT parse. The
   authoritative VT is a sidecar for snapshots; any per-frame grid encoder between
   the PTY and the pipe rebuilds the tmux tax and is rejected.
2. **State sync only at boundaries** — snapshots on attach / resize / resync, never
   per frame. `grid_diff` is an opt-in bad-network degrade, never the default.
3. **Never embed SSH or crypto.** System OpenSSH, tailnets, and OS keychains are the
   security team we didn't hire. The user's `~/.ssh/config` is authoritative — read
   it, never override it.
4. **One protocol, versioned and transport-agnostic.** Unix socket, SSH stdio, and
   later QUIC carry the *same* framed messages. No second protocol for the phone.
5. **No nested window manager in the host.** One PTY per session; panes and layout
   are client concerns.
6. **Single writer, many readers.** Observers never claim the write token.

## Working style

- Elegance is a small surface area. No grand architecture, no cut-rate MVP.
- Verify before claiming done; report failures with the actual output.
- Name mechanisms, not agents.
- Don't re-pitch ideas that were built and dropped — the design docs record why.
