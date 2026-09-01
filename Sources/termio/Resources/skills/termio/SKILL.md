---
name: termio
description: See and drive the sibling agent sessions running alongside you in this Termio project via the `termio sessions` CLI — list and watch their status, spawn new agent or plain-terminal sessions, send a prompt or an answer into a session, and read an agent's reply from its transcript. Use when delegating work to another session, checking on or supervising what other sessions are doing, or starting a command the user should see in its own visible pane. Do not use merely because a task could run in parallel. Requires running inside Termio (TERMIO_SESSION set).
---

# Driving sibling sessions (Termio)

If `TERMIO_SESSION` is not set in your environment, you are not running inside
a Termio-managed session — say so and stop instead of trying to drive sessions
you cannot see.

A sandboxed command cannot reach the CLI: seatbelt profiles that deny network
access (Codex `workspace-write` is one) refuse unix-socket connects with
EPERM, so `termio sessions …` fails with "the OS denied the connection". The
socket and the app are fine — do not restart Termio; run the command outside
the sandbox (in Codex, request escalated permissions for it). The link is
one-directional there: siblings can still drive the sandboxed session, but it
cannot drive back.

You are running inside Termio alongside other agent sessions in this same
project. Coordinate with them through the `termio sessions` CLI. Every command
is scoped to this project automatically; add `--json` for machine-readable
output. The installed CLI is the authority on syntax: where this text and
`termio sessions --help` disagree, trust the CLI. Sessions are addressed by
the link `list` prints: `termio://session/<uuid>` (a bare id or unique
id-prefix works too).

- `termio sessions list` — siblings in this project, with status (working /
  idle / needs-you / done)
- `termio sessions watch` — block and stream one line per sibling status
  change (`done` / `needs-you` by default) until you interrupt it — the push
  alternative to polling `list`. `--state working,idle,done,needs-you` widens
  it, and `--state stalled` adds the runaway signal: a sibling still
  `working` that has made no repo or transcript progress for 20+ minutes
  (long builds streaming output don't trip it). A stalled event says why in
  `evidence`, fires once, and re-arms when progress resumes. It opens with
  one snapshot line per sibling's current status
  (`"snapshot":true` in `--json`; `--no-snapshot` skips), and in `--json`
  writes `{"heartbeat":true}` after 30s of silence so a dead stream is
  detectable. Exits 0 on your Ctrl-C, 2 if Termio itself went away.
- `termio sessions spawn "<prompt>"` — start a NEW agent session on the
  prompt (`--agent codex` picks the agent; default: your own kind). Replies
  immediately with the new session's link (`target` in `--json`) — use it
  for every follow-up; the prompt itself is typed in once the agent
  finishes booting.
- `termio sessions run "<command>"` — start a NEW plain terminal session
  typing that shell command (a dev server, a test run) into a visible pane —
  no LLM. Use it instead of your own background shell when the user should
  be able to see and take over the process.
- `--direction right|down` and `--ratio <0..1>` on `spawn`/`run` — place the
  new pane beside or below YOUR pane (every spawn anchors to the caller),
  and give it that share of the split: `--direction down --ratio 0.25` is a
  log strip under you. Omit both for the default placement. Panes without a
  stated ratio share their run evenly, and a stated one holds against later
  spawns — so only state a ratio when the content needs it.
- `termio sessions send <link> "<text>"` — type text into that existing
  sibling and submit it with a real Return keypress. Send a prompt to drive
  it, or a menu choice (`"1"`, `"yes"`) to answer a permission prompt. A
  single-line payload arrives verbatim, exactly as typed; a multi-line one is
  wrapped in bracketed paste so a TUI takes it as one block instead of
  submitting each line as its own turn. Add `--no-enter` when a gate wants a
  bare keypress and no Return — the lone `t` that trusts a folder. Text that
  itself begins with a dash goes after `--`, which ends the flags:
  `termio sessions send <link> -- --force`.
- `termio sessions send <link> --key <name>` — press a named key in that
  session: `--key escape` to back out of a menu, `--key up --key enter` to
  rerun its last entry, `--key ctrl-c` to interrupt. Repeatable and pressed
  in the order named, after any text. Never hand-write escape bytes into the
  text instead: a key's bytes depend on the mode the program negotiated (Up
  is `ESC[A` in normal mode, `ESC O A` in application mode), and only the
  terminal's key encoder knows which. Any `--key` suppresses the implicit
  Return — name `--key enter` when you want one. Names follow kitty and tmux,
  both spellings accepted: `enter`, `escape`, `tab`, `space`, `backspace`,
  `delete`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`,
  `pagedown`, `f1`–`f12`, single characters, and chords prefixed
  `ctrl-`/`c-` or `shift-`/`s-`. Those two are the modifiers a program sees;
  for a meta chord press ESC first (`--key escape --key b`). An unknown name
  fails with the list; it is never sent as text.
- `termio sessions read <link> [--lines N]` — the session's current
  screen. The result channel for `run` sessions (a plain command has no
  transcript; its screen is the result) — for agent replies keep using the
  transcript, not the screen.
- `--wait [--timeout <ms>]` on `send`, `spawn`, or `run` — block until that turn
  settles and reply with the final `status`, the `transcript` path, and the
  `cursor`..`cursor_end` line range holding the response — one call instead
  of send-then-poll. A sibling that stops to ask you something short-circuits
  the wait: the reply is `status:"needs-you"` with the on-screen question in
  `prompt` — answer it with another `send`. Exit codes: 0 settled, 1 error
  (`prompt_stalled` = the input showed no effect within 5s; `session_closed`
  / `agent_gone` = the target vanished mid-wait), 3 timed out (session still
  running — re-arm or read its transcript).
- `termio sessions close <link> …` — close session tabs;
  `termio sessions focus <link>` — bring one to the front in the app

### Targeting discipline

- Copy links verbatim from `list` or a `send` reply; never guess or
  construct one.
- An unknown flag is an error, never text. Exit 2 means the command was
  malformed and never reached Termio — fix it rather than retry.
  `--agent codex` and `--agent=codex` are both accepted.
- One request, one target. Never send the same prompt to several siblings,
  and never run multiple `send` commands in parallel — delegate to ONE
  session.
- Unsure which sibling the user means? Ask them, or start a fresh session
  with `spawn` — don't broadcast.

### Reading a sibling's response

Don't scrape the terminal. `spawn`/`send` returns the sibling's **transcript**
— the agent's own structured Q&A log (Claude Code: a JSONL file) — plus a
**cursor** (its line count at send time). To read the reply:

1. `spawn`/`send` and note `transcript` + `cursor` from the output. (A just-
   started session has no transcript yet; it appears in `list --json` once the
   agent reports it — read that file from the start.)
2. Poll `termio sessions list` until that session's status is `done` (or
   `needs-you` if it's blocked waiting on input — then `send` its answer).
3. Read the transcript file from line `cursor` onward; the `assistant` entries
   after it are the reply. (Each line is a JSON object with a `type`/`role`.)

Workflow: send → wait for `done` via `list` → read the transcript tail. Prefer
this over assuming a sibling is finished — or collapse steps 1–2 into one call
with `send --wait`, whose reply carries the final status and the exact
`cursor`..`cursor_end` range to read. Supervising several at once? Block on
`termio sessions watch` instead of polling — it prints the link the moment any
sibling turns `done` or `needs-you`, so you act on the transition, not a spin
loop; its `--json` `needs-you` events carry the question in `prompt`, and `done`
events carry `transcript` + `cursor_end`, so you can act straight from the event.
