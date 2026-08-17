---
title: Remote Projects (open an SSH/VPS box like a local project)
status: draft
type: design
created: 2026-07-08
updated: 2026-07-08
related:
  - 20260708-session-daemon-architecture.md
  - 20260705-remote-access-relay-strategy.md
  - 20260705-remote-access-lessons.md
  - 20260707-agent-extensibility.md
---

# Design: Remote Projects

> Open a remote SSH/VPS host in Termio the same way you open a local folder — a real terminal session running an agent (Claude Code, Codex, …) on the remote box, hosted in a native Mac window. Ship the terminal-only slice first; treat remote file-tree / git / agent-status as a deferred phase.

> **Superseded as the target architecture by [session-daemon-architecture.md](20260708-session-daemon-architecture.md).** Under the session-daemon model, remote is not a feature but a *transport* (`ssh host termiod --attach <id>`), and the local/remote feature asymmetry this doc works around simply doesn't exist. Keep this doc as the **interim** plan only if we want remote VPS *before* `termiod` lands; otherwise Phase 2 of the daemon architecture is the real answer.

## 0. Conclusion first

- **A remote project is not a new networking stack.** Termio already launches every session by handing an `argv` to a local `PTYProcess`. The Mac's own `ssh` binary is the transport, and the remote PTY is allocated by `ssh -t`. A remote project is therefore **one branch at the launch seam**, not a rewrite.
- **Everything downstream of the PTY is already agnostic.** The terminal surface, output sinks, resize, composer, and reconnect logic only see bytes. They do not care whether the bytes came from a local shell or an `ssh` process.
- **Three subsystems assume local disk** and are the real cost: the file tree (`FileManager`), the git pane (`git -C <localpath>`), and Claude's hook-based agent-status (fires on the remote box, writes remote files). These are **disabled for remote projects in v1**, not reimplemented.
- **Recommendation: ship v1 (terminal-only remote project).** It is the 90% win — a persistent remote Claude Code you can open, name, and reattach from a native Mac window — and it adds almost no surface area (one enum field + one `if` at the launch site). This keeps Termio's "small surface area = elegance" principle intact and directly answers the herdr/VPS use-case without becoming herdr.

## 1. Motivation

Users want to run Claude Code (and other agents) on a remote VPS — for always-on compute, a fixed IP, or to keep long jobs alive after the laptop closes — while driving it from Termio's native Mac UI. Today Termio only spawns **local** shells. The competitor framing is [herdr](https://herdr.dev/): a Rust TUI whose headline is `herdr --remote ssh://user@host` — the server half runs on the box, the local terminal is a thin client. Termio can offer the equivalent without a server component by treating a remote host as just another Project whose sessions happen to be `ssh` processes.

Related prior work: [remote-access-relay-strategy.md](20260705-remote-access-relay-strategy.md) covers the *inverse* direction (phone → Mac reach-back). Remote Projects is Mac → VPS and is orthogonal to it.

## 2. The seam that already exists

From `TermioStore+TerminalSurface.swift`, session launch reduces to building an `argv` and a `cwd` for a local `PTYProcess`:

```
local project:   argv = ["/bin/sh", "-c", "exec <agent>"]   cwd = /local/path
remote project:  argv = ["ssh", "-tt", "<sshHost>", "--",
                         "sh -lc 'cd <remotePath> && exec <agent>'"]
```

The remote `argv` still runs a **local** `PTYProcess` (the `ssh` client). `ssh -tt` forces remote PTY allocation so the agent behaves as an interactive TTY. Resize, keystrokes (`ghostty_surface_key`), and output streaming all work unchanged because they operate on the local PTY that fronts the ssh connection.

## 3. What assumes local disk (and is deferred)

| Subsystem | Where | Local assumption | v1 behavior |
| --- | --- | --- | --- |
| File tree | `FileBrowser/FileBrowserView.swift` | `FileManager` walk of `project.path` | Greyed out — "remote — terminal only" |
| Git pane | `Git/GitService.swift` (`git -C <path>`) | local repo root | Greyed out |
| Branch watcher | `TermioStore.swift` `syncWatchedFolders()` | polls local paths | Skip remote projects |
| Agent status | `TermioStore+AgentStatus.swift` + Claude hooks | hooks write local files, glob `~/.claude/projects/*.jsonl` | No hook status for remote; see §6 |
| Resume discovery | `resolveLaunch` / `ClaudeConversation.exists` | globs local `~/.claude/` | `--resume` still works remotely (agent reads its own remote store); the local *existence check* is skipped, so pass resume flags optimistically |

None of these block a working remote terminal. They are the content of a future **v2** (§7).

## 4. Data model

Extend `Project` in `Models.swift` with an optional connection. `path` becomes the **remote** path when a connection is present; a `nil` connection means local (today's behavior, unchanged).

```swift
struct Project: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var path: String                 // local path, OR remote path when connection != nil
    var branch: String
    var sessions: [Session]
    var sandbox: SandboxProfile?
    var connection: RemoteConnection?   // NEW — nil = local project
    var pinned: Bool = false
}

struct RemoteConnection: Codable, Hashable {
    var sshHost: String      // an ssh_config Host alias, or user@host
    var remotePath: String   // working directory on the remote box
    // Deliberately minimal: no port/key/user fields.
    // Delegate all of that to ~/.ssh/config so termio never becomes an SSH manager.
}
```

Design note: **do not build an SSH credential manager.** Lean entirely on `~/.ssh/config` and the user's existing agent/keys. Termio only stores a Host alias + a remote path. This keeps the feature small and avoids re-solving key management (which the deferred iOS SSH manager, [termio-ios-ssh], already shows is a large surface).

Persistence is free — `Project` is `Codable` and already saved to `state.json`. Remote projects restore across restarts; the live ssh session restarts fresh on relaunch, exactly like local shells today.

## 5. UX flow

1. **File ▸ Open Remote Project…** (sibling of "Open Project…" in `App.swift`).
2. A small connect sheet:
   - **Host** — a combo box seeded by parsing `Host` entries from `~/.ssh/config` (pick or type `user@host`).
   - **Path** — remote working directory (default `~`).
   - **Agent** — the initial session's agent preset (same picker as local).
3. On confirm, create a `Project` with `connection` set and one session; branch label shows a small remote glyph instead of a git branch.
4. Sidebar/WelcomeView: remote projects get a distinguishing badge. The Recent-projects list may include remote entries (store the `RemoteConnection`, not just a path).

Optional later nicety: register an `ssh://user@host/path` URL scheme so `open ssh://…` creates a remote project (mirrors the existing `application(_:open:)` path).

## 6. Persistence of the remote session (important for "close the laptop")

A bare `ssh -tt host -- claude` **dies when the ssh connection drops**. To match herdr's "agents keep working after you detach," wrap the remote command in a multiplexer the user already has:

```
sh -lc 'cd <remotePath> && exec tmux new -A -s termio-<sessionShortID> "claude …"'
```

`tmux new -A -s <name>` attaches if the named session exists, else creates it — so a reconnect from Termio re-attaches the still-running agent. This is opt-in via a per-project **"Keep running when disconnected"** toggle (default on for remote). If `tmux`/`zellij` is absent on the host, fall back to a plain `exec` and note the limitation in the sheet.

This also recovers a form of **agent status**: on reattach Termio can shell out `ssh host tmux capture-pane` or reuse the same output heuristics used locally. Full hook-based status is a v2 concern — for v1, remote agent-status degrades gracefully to "unknown / output-based," not a hook feed.

## 7. Phase 2 (only if demanded) — first-class remote projects

Make the deferred subsystems remote-aware, each independently:

- **File tree over SSH** — `ssh host find <path>` for listing + `ssh host cat` for preview (respect the existing 1 MB cap), or SFTP via libssh2. Reuse the read-only preview overlay ([termio-file-editor]).
- **Git over SSH** — wrap `GitService` calls as `ssh host 'git -C <path> …'`. Diffs are already pure-Swift over text ([termio-git-view]), so only the data source changes.
- **Agent-status forwarding** — install a tiny hook shim on the remote box that POSTs status events back to the Mac's companion server (reuses the companion wire, [termio-companion-tunnel-churn]).

Each is a separate, sizeable chunk. None should block v1.

## 8. Risks & open questions

- **Latency / rendering** — interactive TUIs (Claude Code) over ssh are fine on low RTT; high-latency links feel sluggish. The warm-up tick pump ([termio-opencode-blank]) still applies to the local PTY, so opentui-style blocking queries should behave.
- **Host key prompts** — first connect may prompt for host-key acceptance; the ssh process will emit it into the terminal. Acceptable (it's a real terminal), but the connect sheet should mention "you may be asked to confirm the host key."
- **`tmux` naming collisions** — key the tmux session name on the Termio session UUID to avoid two termio sessions fighting over one remote pane.
- **Sandbox** — the Seatbelt sandbox ([termio-sandbox]) is a *host* concern and does not apply to remote sessions; disable the sandbox toggle for remote projects.
- **Which agents** — v1 targets Claude Code + a plain shell. Codex/OpenCode resume relies on discovering IDs from local stores; for remote, resume flags are passed optimistically and discovery is skipped.

## 9. v1 implementation checklist

1. `Models.swift`: add `RemoteConnection` + `Project.connection`.
2. `App.swift`: add **Open Remote Project…** menu item + `presentOpenRemoteProjectPanel()`.
3. Connect sheet (new small SwiftUI view): host combo seeded from `~/.ssh/config`, path, agent, "keep running" toggle.
4. `TermioStore+ProjectActions.swift`: `addRemoteProject(connection:agent:)`.
5. `TermioStore+TerminalSurface.swift`: branch `surface(for:in:)` — when `project.connection != nil`, build the `ssh -tt … tmux …` argv instead of the local one.
6. Guard local-only subsystems: `FileBrowserView`, `GitService` callers, `syncWatchedFolders()`, agent-status — no-op / greyed for remote projects.
7. Sidebar + WelcomeView: remote badge; Recent list stores `RemoteConnection`.
