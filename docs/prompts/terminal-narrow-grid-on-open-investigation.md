# Investigation prompt — terminal grid boxed narrow when a session opens in a wide window

> **RESOLVED 2026-07-09 — do not run this prompt.** Root cause was the PTY spawn
> shape, fixed via `forkpty` in `PTYProcess`; see `docs/bug/terminal-resize-no-reflow-HANDOFF.md` §0.

> Hand this to a fresh agent. It front-loads everything already proven (via live
> metric instrumentation and a read of a reference project, Muxy) so the agent
> does NOT re-run the dead ends — the biggest one being "chase the resize path."
> Goal: confirm the spawn-timing root cause and fix it **on the `jiweiyuan/libghostty-swift`
> fork and/or in Termio — WITHOUT rolling the dependency back to Lakr233/libghostty-spm.**

---

## The symptom

Termio is a native macOS terminal for AI agents (Swift + AppKit/SwiftUI, libghostty
core via the `GhosttyTerminal` product). When a Claude Code session opens — or when
the window is wide — the agent's TUI (the welcome box: the pig art, "Welcome back
Jiwei!", the model line, and the "Meet Fable 5…" banner) renders **boxed into a
narrow column on the left, with dead empty space filling the rest of the wide pane.**
The user reads this as "resize doesn't work." Screenshots show the welcome box and
banner clipped at ~50–76 columns while the pane is far wider.

## ALREADY PROVEN — do NOT re-derive these

These were established with live instrumentation (see "Repro harness" below). Trust
them; re-deriving them is the trap that already burned one session.

1. **Live resize WORKS. This is NOT a frame-stall, frame-propagation, render-tick,
   or reflow bug.** Hard numbers from an in-app driven resize:

   | window width | terminal `NSView` frame | grid |
   | --- | --- | --- |
   | 700 pt | **115.5 pt** (`frame == superview.bounds`) | 12 cols |
   | 1460 pt | **750 pt** (`frame == superview.bounds`) | 91 cols |

   The terminal view grows with the window, fills its pane superview **exactly**,
   and the core reflows the grid (12 → 91 cols). `surface.setSize`, the coordinator's
   `synchronizeMetrics`, and the PTY's `receive resize cols=…` all fire with the
   correct sizes. So the grid genuinely tracks the window on grow. **Do not touch
   the resize path expecting to fix the symptom.**

2. The package's AppKit resize path is already hardened (fork `1.0.5`): `setFrameSize`
   / `layout` / `viewDidEndLiveResize` → `fitToSize`, plus a Muxy-style settle re-sync
   (`layoutSubtreeIfNeeded()` + a next-runloop and a ~120 ms catch-up). That change is
   fine but was **not** the fix — resize was never the bug.

3. It is **not** the tip-vs-old ghostty core. Commit `0bd4559` once moved macOS to
   Lakr233 1.2.9 believing the fork's tip core "grew wrong"; that was about live
   resize, which we now know works on both. The frozen-content symptom is orthogonal
   to the core version. **Rolling back to Lakr233 is explicitly off the table.**

## The root-cause hypothesis to confirm (high confidence)

**Frozen scrollback from spawning the shell/agent at a guessed width before the
terminal view has its real size.**

- Termio owns the PTY (host-managed `.inMemory` backend via `PTYProcess`, *not*
  `.exec` — `docs/CLAUDE.md` is stale on this). It creates the `PTYProcess` **eagerly**
  in `TermioStore.surface(for:in:)` at `cols: lastHostGridColumns, rows: lastHostGridRows`
  — a value **persisted in UserDefaults from a previous run**, i.e. a guess.
- At window-open the sidebar (and inspector) squeeze the terminal pane small — the
  instrumentation measured the pane as low as **12 cols**. So the guess is very often
  narrower than the pane the user ends up looking at.
- Claude reads that narrow winsize via `TIOCGWINSZ` at startup and prints its welcome
  box + banner using **box-drawing characters and hard newlines**. That content is
  committed to scrollback and **never soft-wraps / reflows** on a later grow (unlike
  plain wrapped text). So the live grid widens but the printed box stays frozen narrow.

Confirm this: at session open, log the FIRST winsize the PTY delivers to the child
(`receive resize cols=…`) and compare it to the pane's real width a moment later. If
the first size is the narrow guess and the box is printed before the real size
arrives, the hypothesis holds.

## Reference project — Muxy (this is how to fix it)

`github.com/muxy-app/muxy` — MIT, SwiftUI + libghostty, **same architecture as Termio**
(it even vendors its own `GhosttyKit.xcframework`). Clone it and read
`Muxy/Views/Terminal/GhosttyTerminalNSView.swift`.

The decisive difference: **Muxy creates its surface — and therefore spawns the PTY —
LAZILY, at the first real layout, never at a guess:**

```swift
override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if pendingSurfaceCreation { createSurface() }   // ← spawn only once the frame is real
    updateMetalLayerSize(deferred: false)
}
```

`createSurface()` calls `ghostty_surface_set_size(surface, backingSize…)` at the
view's actual backing size, and `materializeHeadless()` uses a 1×1 frame only for
genuinely offscreen panes. So Muxy's agent always boots at the true pane width and
never leaves a frozen-narrow banner. Termio boots eagerly at a stale guess — that is
the whole gap.

## The fix to design (leave room to find the cleanest split)

Make the agent's **first** winsize equal the real pane width. The PTY winsize is set
by Termio's `PTYProcess`, and the real size is known only once the package fires its
first resize callback — so the fix likely spans both sides. Evaluate:

- **Termio side:** defer `PTYProcess` creation (or at least its first `TIOCSWINSZ`)
  in `TermioStore.surface(for:in:)` until the InMemory `resize` closure fires with the
  first real grid, then spawn/size at that. Keep `lastHostGridColumns` only as the
  metal layer's initial visual guess, not as the shell's birth size. Guard the
  pre-spawn window (the drop-path and `send()` already retry).
- **fork/package side (`GhosttyTerminal`):** if useful, add a clean signal for
  "surface laid out at a real, non-placeholder size for the first time," and/or make
  the `.inMemory` backend defer its initial viewport until then, so Termio's
  coordination is simple and not racy. Mirror Muxy's `pendingSurfaceCreation` gate.

Pick whichever split is cleanest and least invasive; the acceptance test (below) is
what matters.

### Hard constraints
- **Do NOT roll back to `Lakr233/libghostty-spm`.** Stay on `jiweiyuan/libghostty-swift`
  (Termio's `Package.swift` is currently pinned to it at `1.0.5`).
- **No zig / no building Ghostty from source.** The xcframework is a prebuilt binary
  target. Only the Swift wrapper (`Sources/GhosttyTerminal`) is editable; it compiles
  against the downloaded xcframework via `swift build` / `swift build --target GhosttyTerminal`.
  To ship a wrapper change: commit on the fork, push a new semver tag (next after
  `1.0.5`); the binary target keeps pointing at the `storage.1.0.4` xcframework, so no
  rebuild is needed. Then bump Termio's `Package.swift` pin.
- Work on a branch / git worktree; do not touch Termio `main` until verified.

## Key files

**Termio** (`~/Documents/GitHub/termio`):
- `Sources/termio/TermioStore/TermioStore+TerminalSurface.swift` — `surface(for:in:)`
  creates the `PTYProcess` eagerly and wires the InMemory `resize` closure. **Primary
  edit site.**
- `Sources/termio/PTYProcess.swift` — PTY init sets the initial winsize; `resizeFromHost`,
  `sizeOwner`, `applyWindowSizeAndUnlock`.
- `Sources/termio/TermioStore/TermioStore.swift` — `lastHostGridColumns` / `rememberHostGrid`.
- `Sources/termio/TerminalPane.swift` — the SwiftUI embedding (all sessions mounted in a
  `ZStack`, opacity-toggled).
- `Package.swift` — dependency is `jiweiyuan/libghostty-swift` from `1.0.5`.

**fork** (`git clone https://github.com/jiweiyuan/libghostty-swift`; gh is authed as
`jiweiyuan`, push access available):
- `Sources/GhosttyTerminal/Platform/AppKit/AppTerminalView.swift` + `AppTerminalView+Lifecycle.swift`
  — AppKit view, resize overrides, the `1.0.5` settle-resync, the `viewSize` closure
  (`{ (bounds.width, bounds.height) }`).
- `Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift` — `synchronizeMetrics`,
  `fitToSize`, the `viewSize()` read, the `lastMetrics` early-out.
- `Sources/GhosttyTerminal/InMemory/…` — `InMemoryTerminalSession`, `TerminalSessionBackend`
  (`case inMemory`), `updateViewport`.

## Repro harness (reuse it — System Events window control is BLOCKED here)

A temporary diagnostic already exists in the working tree on branch
`macos-libghostty-swift-fork` (**remove it when done**): in
`App.swift`’s `applicationDidFinishLaunching`, gated on env `TERMIO_METRICS_LOG`, it
sets `GhosttyTerminal.TerminalDebugLog.sink` to append to `/tmp/termio-metrics.log`,
calls `TerminalDebugLog.enable(.metrics)`, then drives `window.setContentSize(…)`
narrow→wide on a delay and walks `contentView` for a subview whose class name contains
`"Terminal"`, logging its `frame` vs `superview.bounds`.

- Launch the dev bundle's inner binary directly so `Bundle.main` stays the `.dev` app:
  `TERMIO_METRICS_LOG=1 ./termio-dev.app/Contents/MacOS/termio` (build the dev bundle
  with `TERMIO_CHANNEL=dev ./scripts/build-app.sh`, or use the `macos-rebuild-dev` skill).
- `osascript`/System Events **cannot** set window bounds here (`Can't set bounds…`) —
  resize from inside the app instead, as above.
- `.metrics` log lines to read: `sync view=<pt>x<pt>`, `surface setSize <px>x<px>`,
  `surface size cols=<n> rows=<n>`, `receive resize cols=<n>` (the PTY-side size),
  `in-memory viewport update`.

## Acceptance test for the fix

Open a Claude Code session with the sidebar making the pane narrow at launch, in a
wide window. **Pass = the welcome box + banner print at the full pane width** (no
narrow box, no dead space), because the first `receive resize cols=…` the PTY delivers
equals the real pane width — not `lastHostGridColumns`. Growing/shrinking afterward
must still reflow the live grid (regression check). Verify with the metrics log and a
window screenshot of the running dev app.

## History pointers (context, not tasks)
- Memory `project_termio_prompt_eol_mark`: prior fix = spawn at `lastHostGrid` + coalesce
  SIGWINCH; it explicitly deferred the real fix — *"defer the pty spawn until the first
  real layout size instead of guessing lastHostGrid."* **That deferred fix is this task.**
- Commits: `57e0ea3` (first-prompt-at-real-width), `e5d9084` (coalesce host resizes),
  `0bd4559` (moved macOS to Lakr233 — reasoning now known to be about live resize, which
  works either way). Termio was later repointed to the fork at `1.0.5`.
