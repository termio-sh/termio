---
title: Fix — defer the PTY spawn to the first real layout size so the agent banner boots at pane width
status: archived
type: plan
created: 2026-07-08
updated: 2026-07-09
related:
  - bug/terminal-narrow-grid-frozen-banner-on-open.md
---

# Fix — defer the PTY spawn to the first real layout size

> **ARCHIVED 2026-07-09 — superseded.** The real root cause was the PTY spawn
> shape (`posix_spawn+SETSID` broke Claude Code's resize repaint); fixed via
> `forkpty` in `PTYProcess`. See `docs/bug/terminal-resize-no-reflow-HANDOFF.md` §0.
> Deferred birth is unnecessary: a narrow-born banner now recovers on the first resize.

> The agent's welcome banner freezes into a narrow column because Termio spawns
> the child at a stale guessed winsize before the terminal view knows its real
> width (see [the bug report](../bug/terminal-narrow-grid-frozen-banner-on-open.md)).
> The fix: **spawn the PTY lazily, at the first real layout grid** — mirroring
> Muxy's `pendingSurfaceCreation` gate — with a headless fallback so companion-only
> sessions still spawn. This can be done **entirely on the Termio side**; no fork
> or xcframework change is required.

## Goal / acceptance test

Open a Claude Code session with the sidebar making the pane narrow at launch, in a
wide window. **Pass = the welcome box + banner print at the full pane width** (no
narrow box, no dead space), because the first `receive resize cols=…` the PTY
delivers equals the real pane width — not `lastHostGridColumns`. Regression check:
growing/shrinking afterward must still reflow the live grid; a phone attaching to a
never-shown session must still get a running agent. Verify with
`/tmp/termio-metrics.log` and a screenshot of the running dev app.

## Why termio-side only

The ghostty surface is **already** created lazily and correctly: `rebuildIfReady`
is gated on `hasValidViewSize`, and right after it creates the surface it calls
`synchronizeMetrics`, which computes the true grid from the view's pixel size and
calls `inMemorySession.updateViewport(...)`. That is the exact moment the first
**real** grid becomes known, and it already flows into Termio's InMemory `resize`
closure. So Termio can hang the PTY spawn off that first closure fire without any
new signal from the fork. (A fork-side "first real layout" hook was considered and
rejected as unnecessary — see Alternatives.)

## The one hazard that shapes the design: the headless path

A naive "only spawn on first resize" breaks sessions that are never shown on the
Mac. `CompanionServer.companionPTY(for:)`
(`Sources/termio/CompanionServer.swift:919`) calls `surface(for:in:)` and then
**synchronously** reads `ptyProcesses[session.id]` to hand a PTY to an attaching
phone. For an offscreen session there is no `NSView`, so no layout, so the resize
closure never fires and the PTY would never spawn. The fix must therefore expose an
explicit "spawn now at a fallback grid" entry point for the headless path, the way
Muxy's `materializeHeadless()` complements its lazy `createSurface()`.

## Design

Introduce an **idempotent, main-actor** spawn step keyed by session id. Two
triggers call it; whichever fires first wins, the other is a no-op.

1. **On-screen trigger (the fix):** the InMemory `resize` closure, on its **first**
   fire, spawns the PTY at the real `cols`/`rows` it was handed. Subsequent fires
   call `resizeFromHost` as today.
2. **Headless trigger (the safety net):** `companionPTY(for:)` calls the same spawn
   step at the fallback grid (`lastHostGridColumns/Rows`) if the PTY still doesn't
   exist after `surface(for:in:)`. The phone reports its own grid on attach and
   claims size ownership (`resizeFromCompanion` + jiggle), and an alt-screen TUI
   repaints on that SIGWINCH — so a fallback-width birth is corrected immediately
   for the companion case (its banner isn't the Mac pane anyway).

### Restructuring `surface(for:in:)`

Today, from `TermioStore+TerminalSurface.swift:95` down to `ptyProcesses[session.id]
= pty` (line 186), the method: creates the `PTYProcess`, builds the
`InMemoryTerminalSession` with `write`/`resize` closures capturing `pty`, then wires
three things onto the pty — the output→surface sink, the liveness/status sink, and
`onExit`. All of that must move into the deferred spawn step, because it all needs
the live `pty`.

Sketch (names illustrative; keep Termio's existing comments):

```swift
func surface(for session: Session, in project: Project) -> TerminalViewState {
    if let existing = surfaces[session.id] { return existing }
    // …resolve launch, sandbox, argv, env exactly as today…

    let controller = TerminalController { [self] builder in applyAppearance(to: &builder) }
    let state = TerminalViewState(controller: controller)
    state.controller.setTheme(makeTheme())

    let inMemory = InMemoryTerminalSession(
        write: { [weak self] data in
            // No pty yet ⇒ nothing rendered yet ⇒ nothing to type into. Drop.
            guard let pty = self?.ptyProcesses[session.id] else { return }
            pty.claimHostOwnership()
            pty.write(data)
        },
        resize: { [weak self] viewport in
            let columns = Int(viewport.columns), rows = Int(viewport.rows)
            // First real layout size spawns the child AT that size (the fix).
            self?.spawnPTYIfNeeded(for: session, in: project,
                                   argv: argv, env: env, cwd: workspacePath,
                                   inMemory: inMemory, cols: columns, rows: rows)
            self?.ptyProcesses[session.id]?.resizeFromHost(cols: columns, rows: rows)
            DispatchQueue.main.async { self?.rememberHostGrid(columns: columns, rows: rows) }
        }
    )

    state.configuration = TerminalSurfaceOptions(backend: .inMemory(inMemory))
    surfaces[session.id] = state
    monitor(state, for: session.id)
    warmUpRendering(state)
    DispatchQueue.main.async { [self] in recordLaunch(session.id, resumeID: launch.resumeID) }
    return state
}
```

`spawnPTYIfNeeded` holds everything that needs the live pty and is idempotent:

```swift
private func spawnPTYIfNeeded(
    for session: Session, in project: Project,
    argv: [String], env: [String: String], cwd: String,
    inMemory: InMemoryTerminalSession, cols: Int, rows: Int
) {
    guard ptyProcesses[session.id] == nil else { return }   // idempotent
    guard let pty = PTYProcess(argv: argv, cwd: cwd, env: env, cols: cols, rows: rows)
    else { return }
    ptyProcesses[session.id] = pty                          // set BEFORE wiring, so re-entrancy no-ops
    pty.addSink { [weak inMemory] data in inMemory?.receive(data) }
    // …the liveness / status-rules sink, verbatim from today…
    pty.onExit = { [weak self, weak inMemory] code in
        inMemory?.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: 0)
        self?.ptyProcesses[session.id] = nil
        self?.lastScreenActivity[session.id] = nil
    }
}
```

`companionPTY(for:)` becomes:

```swift
func companionPTY(for wireID: String) -> PTYProcess? {
    guard let (project, session) = findCompanionSession(wireID) else { return nil }
    if let pty = ptyProcesses[session.id] { return pty }
    let state = surface(for: session, in: project)          // builds the InMemory session
    if ptyProcesses[session.id] == nil {                    // never shown ⇒ no layout ⇒ spawn headless
        spawnPTYIfNeeded(for: session, in: project, argv: …, env: …, cwd: …,
                         inMemory: state.inMemorySession, cols: lastHostGridColumns, rows: lastHostGridRows)
    }
    return ptyProcesses[session.id]
}
```

To make the headless call reachable, the resolved `argv`/`env`/`cwd`/`inMemory`
need to be available to it. Two clean options — pick one during implementation:
- **(a)** Stash a small per-session `pendingSpawn` closure (capturing argv/env/cwd/
  inMemory) in a `[Session.ID: () -> Void]` map that `surface(...)` populates and
  both triggers invoke; clear it once spawned. Keeps `surface`'s locals private.
- **(b)** Expose `inMemory` off `TerminalViewState` (it already carries the backend
  in `configuration`) and recompute argv/env in `companionPTY` via the same
  `resolveLaunch` path. More duplication; avoid unless (a) proves awkward.

Recommend **(a)** — one map, both call sites invoke the stored thunk, idempotency is
the `ptyProcesses[id] == nil` guard already inside the thunk.

### Thread-safety notes

- The InMemory `resize` closure is driven from `synchronizeMetrics` →
  `updateViewport` on the **main actor**, and `TermioStore` is `@MainActor`, so the
  spawn and the `ptyProcesses` mutation happen on main — no locking needed. Keep the
  `rememberHostGrid` hop on `DispatchQueue.main.async` as today.
- Set `ptyProcesses[session.id] = pty` **before** attaching sinks so any re-entrant
  resize during wiring hits the idempotent guard.
- No birth-time coalescing: the first spawn uses the real size directly, so there is
  no 50 ms `resizeFromHost` delay on the child's first winsize (only later resizes
  coalesce, which is correct).

## Optional hardening (only if the acceptance test still shows a narrow box)

If AppKit delivers a transient tiny first layout (the instrumentation saw 12 cols at
an artificially 700 pt window), the first spawn could still be too narrow. If
observed, gate the spawn on a plausibility floor — ignore a first grid below, say,
20 cols and wait for the next resize, with a short timed backstop that spawns at the
fallback grid if no larger size arrives (mirrors `warmUpRendering`'s
`elapsed > 6.0` backstop). Do **not** add this pre-emptively; the bug report’s
evidence is that a normal wide window’s first real layout is already full width, and
an unnecessary floor risks mis-sizing a genuinely narrow pane.

## Alternatives considered (and why not)

- **Fork/package-side "first real layout" signal / defer the `.inMemory` viewport.**
  Unnecessary: `synchronizeMetrics` already delivers the first real grid to the
  InMemory session, and the fork surface is already lazy. Adding a fork signal means
  a new semver tag + a `Package.swift` bump for zero behavioral gain. Keep the fix in
  one repo. (Revisit only if option (a)/(b) plumbing turns out ugly enough that a
  fork-side `onFirstLayout` callback would materially simplify Termio.)
- **Roll back to `Lakr233/libghostty-spm`.** Off the table and irrelevant — both
  cores reflow the live grid; the frozen banner is a spawn-timing bug, not a core bug.
- **Spawn eagerly but `TIOCSWINSZ` before the child prints.** Can't — `openpty` needs
  a winsize and `posix_spawn` runs immediately in `PTYProcess.init`; the child can
  win the race to `TIOCGWINSZ` before any later SIGWINCH. The size must be right *at
  birth*.
- **Keep guessing but never persist a narrow grid.** Fragile; a wide previous run
  still mis-fits a differently-sized current window, and it doesn't help the very
  first launch. Deferral is the only correct source of the real size.

## Constraints (from the investigation brief)

- Do **not** roll back to `Lakr233/libghostty-spm`; stay on
  `jiweiyuan/libghostty-swift` (pinned `1.0.5`).
- No zig / no building Ghostty from source. If a fork change *does* prove worth it,
  ship it as a Swift-wrapper-only edit committed on the fork + a new semver tag (the
  binary target keeps pointing at the `storage.1.0.4` xcframework), then bump
  Termio's `Package.swift`. The plan above needs none of this.
- Work on a branch / worktree; do not touch Termio `main` until the acceptance test
  passes. Remove the `TERMIO_METRICS_LOG` diagnostic harness in `App.swift` when done.

## Outcome (2026-07-08) — INSUFFICIENT, see the bug doc

This plan's core idea (defer the PTY spawn instead of guessing `lastHostGridColumns`)
is correct and implemented, but it did **not** fully fix the symptom. Two further
early-wrong sizes were found (ghostty's `48×17` placeholder, and the window's
pre-restore `1100` width), and even a 200 ms birth-debounce births too early relative
to the window's saved-frame restore. The live record of all three attempts, the
measured timelines, the current hypothesis (window frame restored *after* content
layout in `App.swift`), and the handoff prompt now live in
[the bug doc](../bug/terminal-narrow-grid-frozen-banner-on-open.md) — treat that as the
source of truth for the next debugging pass. The deferred-spawn code below still stands
in the tree and should be kept; the missing piece is making the window reach its final
frame before the terminal first lays out (Muxy's SwiftUI-scene behaviour).

## Step list

1. Branch off `macos-libghostty-swift-fork` (or a worktree).
2. Refactor `surface(for:in:)`: build the InMemory session first; move the
   `PTYProcess` creation + all three sink/`onExit` wirings into an idempotent
   `spawnPTYIfNeeded`, stored as a per-session thunk (option (a)).
3. First-resize trigger: call the thunk from the InMemory `resize` closure before
   `resizeFromHost`.
4. Headless trigger: call the thunk from `companionPTY(for:)` at the fallback grid
   when no PTY exists after `surface(...)`.
5. Guard the pre-spawn window: `write` closure drops when no pty; confirm
   `send()`/companion paths tolerate a momentarily-absent pty (they already retry).
6. Build (`swift build`), run the dev app with `TERMIO_METRICS_LOG=1`, and confirm
   the first `receive resize cols=…` equals the real pane width and the banner fills
   the pane.
7. Regression: grow/shrink reflows the live grid; open a plain shell (no `%` stack
   regression); attach a phone to a never-shown session and confirm the agent spawns.
8. Remove the metrics harness; screenshot; commit; PR (imperative title, no
   conventional-commit prefix, include a `Release Notes:` section).
</content>
