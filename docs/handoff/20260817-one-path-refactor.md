---
title: Handoff — collapsing the two session paths into termiod
status: active
type: design
created: 2026-08-17
updated: 2026-08-17
related:
  - ../rfcs/one-path-local-through-termiod.md
  - ../rfcs/remote-to-device.md
  - ../design/20260805-termiod-device-architecture.md
---

# Handoff — one path through termiod

> Pick this up cold. Everything below is verified state, not recollection.

## 1. The one idea that explains the rest

termio runs sessions two ways: the Swift in-process `PTYProcess`, and the Rust
`termiod` daemon behind `TERMIO_TERMIOD=1` (off by default). **Every bug this
round was the same shape — the feature exists on the Swift path and has no
counterpart on the termiod path:**

| # | Symptom | Cause |
| --- | --- | --- |
| 1 | Every local terminal silently became remote | `TERMIO_TERMIOD_REMOTE` fallback on the wrong path |
| 2 | Splitting a remote session gave a shell on the Mac | inheritance written on one path only |
| 3 | Image paste did nothing remotely | local relies on the *agent* reading the Mac pasteboard |
| 4 | File tree is SFTP, git shells out locally | `files`/`git` planes shipped daemon-side, never consumed |
| 5 | Agent icon never changes on a remote session | `pty.foregroundProcessArguments()` is a local syscall; `pty == nil` under termiod |
| 6 | `termio sessions send` cannot send a bare keypress | the CLI talks to the **Mac app**, not the daemon |

All six become structurally impossible once there is one path. That is the
whole justification; each individual fix is a patch on the mechanism that keeps
producing them.

Strategic addition: **the Swift local-PTY path can never run on Windows.** The
Rust daemon can.

## 2. State — verified 2026-08-17

### Landed on main
`termiod` is not a skeleton. Ten capabilities, all implemented daemon-side with
smoke coverage: `events, send_wait, snapshot, scrollback, grid_diff, resources,
fs_watch, files, upload, git`. Baseline: **46 unit + 84 smoke + 8 remote smoke**,
CI green on macos + linux.

Also landed this round: VT-sequence snapshots (client theme survives), the
resource plane (§C.10 resumable subscriptions), fleet `list --host`,
protocol-over-SSH `attach --host` with ControlMaster, launchd service, session
tombstones, sidecar backpressure (#316), image-paste transfer plane (#308),
device identity (`TermiodDevice`), and #314 which settled the RFC's two blocking
questions.

### The gap that matters
The Mac app negotiates **two** of the ten capabilities (`snapshot`, `events`).
`scrollback`, `grid_diff`, `files`, `upload`, `git` are implemented and unused.
The daemon ran ahead; the client never caught up.

### Open PRs on this line
- **#310** — the device RFC. Conflicts resolved, `MERGEABLE`. **No longer
  blocked**: #314 settled the Settings question (SSH and Devices tabs *coexist*,
  split at the handshake — routes before `hello_ok`, identities after).
- **#317** — ghostty formatter emits tabstops before the screen.

### Uncommitted worktrees
| Worktree | Contents | Call to make |
| --- | --- | --- |
| `device-context` | device is a store-level context; sidebar shows the device's own daemon roster; three UI fixes (title badge removed, switcher moved to top, New Terminal stops asking which machine) | **Ready — commit and open a PR** |
| `one-path-design` | the RFC below + this handoff | commit with the RFC |
| `one-path-review` | adversarial review in progress | wait for it |
| `remote-to-device` | `DeviceSwitcher` — **already patched into `device-context`** | verify nothing unique, then discard |
| `ios-device-rename` | `PairedMac` → `PairedDevice` | blocked on a real-device migration test (§5) |
| `settings-file-watch`, `agent-a6effa8411d2998e7`, `editor-scrollaway-header` | unrelated lines | commit or discard — they are mines under the refactor |

## 3. The plan

`docs/rfcs/one-path-local-through-termiod.md` (869 lines). Verified: the
inventory cites real file:line, not guessed names.

Its most valuable finding, which no one anticipated: **deleting the in-process
`PTYProcess` dismantles the iPhone mirror.** `CompanionServer`'s `PTYBridge` is
typed on `PTYProcess` (`addSink`, `isAlternateScreenActive`,
`claimHostOwnership`, …). Read the other way this is also the argument *for*
doing it — the phone is a viewer mirroring another viewer, which protocol §H #9
already condemned, and the only reason that wire survives is the Mac holding a
`PTYProcess` the phone can tap.

CLI split is §7 + Stage 6, deliberately not entangled with the PTY work.

## 4. What to do next, in order

1. **Merge #310.** Unblocked since #314.
2. **Read the review** in `one-path-review` when it lands; expect it to move
   stages around. Do not start implementing before reading it.
3. **Commit `device-context`** and open a PR — it is finished and verified.
4. **Clear the field (RFC Stage 0).** Every uncommitted worktree above touches
   `TermioStore+TerminalSurface` / `PTYProcess` / `GitService` / `FileBrowser`,
   which is exactly what the refactor rewrites. Each one gets committed or
   discarded; none may stay.
5. **Then implement**, stage by stage, verifying each against a criterion that
   is not "it compiles".

## 5. Traps that cost real time

**"It compiles" proves nothing here.** All six bugs above passed every test that
runs. Two of them shipped.

**`swift test` cannot run at all** — 285 Swift 6 concurrency errors in
`CompanionServer.swift` on `main` ([#311](https://github.com/termio-sh/termio/issues/311)).
Every file under `Tests/termioTests/` compiles and never executes. Swift is only
verifiable through `TERMIO_CHANNEL=dev ./scripts/build-app.sh`.

**Do not set `DEVELOPER_DIR=…/CommandLineTools`** for that script — it dies on
`xcstringstool not found`, which only ships with full Xcode.

**`ZIG=…` as an environment variable does nothing.** `libghostty-vt-sys/build.rs`
execs `zig` from `PATH`, and CI pins **0.16.0**:
`export PATH=$HOME/.local/share/termiod-toolchains/zig-0.16.0:$PATH`

**`termio sessions spawn` can silently drop the prompt** while still reporting
`idle`/`done`. Confirm a transcript exists before believing an agent ran —
`done` is not proof. One agent this round produced nothing and reported success.

**Codex could not be driven at all** — four attempts, four different failures
(hook-trust gate, no live terminal, prompt not delivered, cwd landed at `/`).
The gate needs a bare `t` or `esc`, and `send` only emits text+Return. RFC §7
fixes exactly this; until then a human has to press the key.

**Concurrent smoke runs interfere** — they share `/tmp/termiod-smoke`. A lone
failure that passes on rerun is contention, not a regression.

## 6. Decided, do not reopen

- Raw PTY bytes are teed; the host parses in parallel, never in between.
  Superlogical converged on the identical design independently (primary sources,
  not press paraphrase).
- `G` grid diffs are never the default — a diff-fed client owns no real
  scrollback and cannot select across history. That is a capability argument,
  not bandwidth.
- The host describes state and never decides presentation.
- Never embed SSH or crypto; `~/.ssh/config` is authoritative — read it, never
  override it.
- A device's identity is its `host_id`; SSH is one route among several.
- "Remote" is not a UI word. It describes the road, not the thing at the end.
- Settings ▸ SSH and Settings ▸ Devices coexist, split at the handshake (#314).
