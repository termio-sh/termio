# Structured input plane — proof of concept

A spike, not a design. It answers the three questions that decide whether termio
could take a Happy-shaped route for **input** without giving up the terminal,
and it deliberately stops before the questions that need a decision rather than
an experiment.

The GUI is untouched. Nothing here is wired into the app.

## Run it

```sh
python3 probe.py          # costs one cheap Claude turn
python3 probe.py --keep   # keep the scratch dir
```

Everything runs in a temp directory. An agent with tool access pointed at a real
worktree is not a controlled experiment.

## What it proves

Measured on Claude Code 2.1.220, 2026-08-13.

| Question | Result |
| --- | --- |
| Can a prompt be a message instead of keystrokes? | **Yes** — `--print --input-format stream-json --output-format stream-json` answered with 6 typed events (`system/init`, `assistant`, `result/success`) and the reply `pong`. No PTY. |
| Does the handoff to a terminal work? | **Yes** — `--session-id <uuid>` pins the id, `claude --resume <uuid>` on a PTY paints the TUI with the prior turn on screen. |
| Does the existing content plane read it? | **Yes, unchanged** — `ClaudeTranscriptNormalizer` turned the headless transcript into the same `AgentEvent`s (`user text "Reply with exactly…"`, `agent text "pong"`). |

That third row is the load-bearing one: the chat lens, the upsert keys, the
`subscribeEvents` cursor — all of it works over a headless session for free. The
structural plane is already runtime-agnostic; only input is coupled to the PTY.

`headless-transcript.jsonl` is a captured headless transcript, kept as a fixture
for a normalizer test when this is picked up.

## What it does not prove

These are the reasons the design doc closed this route, and none of them are
answered by the spike:

1. **Live state does not survive a resume.** Resume replays the *conversation*,
   not the *process*: an in-flight turn, the current tool call, scrollback,
   background processes the agent spawned, permission mode, MCP connections.
   "Reopen it on the Mac when the user wants the TUI" is cheap when the session
   is idle and lossy exactly when it is busy — which is when someone reaches for
   the terminal.
2. **Two runtimes, one worktree.** If a Mac TUI is open and the phone sends a
   message, two agent processes edit the same files. Happy avoids this by
   allowing one at a time and killing the TUI on takeover. Inverting the
   direction keeps the problem; it needs an ownership rule either way.
3. **Breadth.** This is Claude-only so far. `ResumeSpec` already covers resume
   for pinned-id (Claude, Grok, Pi) and discovered-id (Codex, OpenCode) agents,
   but bidirectional structured *input* is a much narrower capability than
   resume. Everything is a PTY; not everything is a stream-json server.
4. **Behaviour drift.** Headless and TUI Claude differ in permission prompting,
   slash commands, and hook behaviour. "It worked on my phone" becomes a bug
   class with no floor.

## The narrow version worth testing next

Use headless **only for sessions the phone starts cold**, where there is no live
PTY state to lose, and resume them into a TUI when they are opened on the Mac.
Any session with a live terminal keeps the PTY path. That is a per-agent
manifest flag and an ownership rule, not a change of runtime — and it produces
evidence about (2) and (4) before anything is bet on them.

The alternative that needs no runtime split, and fixes the bug that started
this: promote `prompt` to a typed wire message the Mac lands on the PTY when the
agent is ready, and acknowledges. Same benefit for input (a message, an ack, a
cancel), every agent on day one.

## Context

- `docs/design/mobile-agent-ui-protocol.md` — §2 core principles, §12 prior art
  including the Happy `claudeRemoteLauncher` comparison.
- `docs/design/agent-resume-identity.md`, `config-driven-agent-resume.md` —
  how resume is already modelled per agent.
