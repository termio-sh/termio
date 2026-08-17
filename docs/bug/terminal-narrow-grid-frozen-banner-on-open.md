---
title: Agent welcome banner frozen into a narrow column when a session opens in a wide window
status: done
type: bug
created: 2026-07-08
updated: 2026-07-09
related:
  - plan/terminal-narrow-grid-frozen-banner-fix.md
  - terminal-resize-no-reflow-HANDOFF.md
---

# Agent welcome banner frozen into a narrow column when a session opens in a wide window

## RESOLUTION (2026-07-09)

**Fixed by the same root cause as `terminal-resize-no-reflow-HANDOFF.md` §0:**
the `posix_spawn + POSIX_SPAWN_SETSID` PTY spawn shape produced a controlling
terminal under which Claude Code v2.1.170 never repaints on resize. That is
what made this bug *fatal*: a banner born at a narrow width could never
recover, because the later grow resize reached the child (TIOCSWINSZ) but the
child never repainted. With `PTYProcess` switched to `forkpty` (login_tty
shape), the child repaints on every real resize — a narrow-born banner now
recovers on the first window/pane resize, and the deferred/debounced-birth
machinery below is unnecessary (it was already reverted from the tree; the PTY
spawns eagerly at the persisted last host grid). The spawn-timing analysis
below is kept as a record of the misdiagnosis.

## Superseded fix candidate (2026-07-08 — never worked, reverted)

Candidate changes are in `Sources/termio/App.swift`,
`Sources/termio/TermioStore/TermioStore+TerminalSurface.swift`, and
`Sources/termio/TermioStore/TermioStore+ProjectActions.swift`.

Root cause addressed: Termio mounted the SwiftUI split/terminal content while the manually
created `NSWindow` and its `NSSplitView` were still restoring stale geometry. The window
frame is only one part of that. The stronger, reproduced local clue is the persisted
`"NSSplitView Subview Frames TermioContentSplit"` default: it can restore the terminal
detail pane to a narrow pre-fullscreen / inspector-open width (for example 412 pt in the
production defaults, or 639 pt in dev) even when the window will later be wide. A
host-owned PTY born during that restored split-frame interval sees a real AppKit view,
but a stale narrow one, so Claude Code prints its box-drawing welcome screen narrow and
the already-printed content never reflows.

The previous fix also trusted `InMemoryTerminalSession.resize`, which is a mixed-source
callback: it receives both real view-derived metrics and ghostty's own `receive_resize`
events. The wrapper merges missing resize metadata from the previous resize, so a later
internal `48×17` placeholder can inherit nonzero cell metrics and look "real". That path
is no longer used to decide PTY birth.

The current candidate has three parts:

1. Restore the saved main-window frame with `setFrameUsingName(...)` and install the
   autosave name before assigning `window.contentViewController`, so the terminal's
   first layout sees the restored frame rather than the construction frame.
2. Stop using `NSSplitView.autosaveName = "TermioContentSplit"` on the terminal split.
   Muxy does not restore raw split subview frames; its terminal column is laid out from
   the current SwiftUI window/sidebar state, and the Ghostty surface is materialized
   from the current backing size. Termio's raw split-frame autosave was restoring stale
   detail widths into a wide-window launch.
3. Mirror Muxy's materialization rule: only real view-derived geometry is allowed to
   arm an on-screen PTY birth. In Termio that now means using
   `TerminalViewState.surfaceSize`, which is published only from
   `TerminalSurfaceCoordinator.synchronizeMetrics()` after reading the AppKit view's
   actual bounds. The in-memory backend's generic resize callback is no longer used
   for birth because it also carries ghostty's internal `48×17` placeholder. Muxy does
   the analogous thing by making
   `GhosttyTerminalNSView.createSurface()` return early until `backingPixelSize()` is
   non-nil, then retrying from `setFrameSize`.
4. Gate on-screen PTY births to the selected session. Hidden mounted sessions can still
   have SwiftUI/AppKit views and resize callbacks; they now record their latest real
   grid but do not spawn until selected. The companion/headless path still calls
   `spawnPTYIfNeeded` directly at the fallback host grid.

Verification completed in this pass:

- `swift build` succeeds.
- `TERMIO_CHANNEL=dev ./scripts/build-app.sh` succeeds and signs
  `termio-dev.app`; rebuilt dev app binary timestamp:
  `Jul 8 22:58:11 2026`.
- `swift test` is not applicable for this package: SwiftPM reports no test targets.

Runtime screenshot/metrics capture was not repeated in this edit pass because the tree
no longer has a committed metrics sink. The key change after comparing Muxy is that the
birth trigger now depends on `surfaceSize` (the view-derived metrics publisher) and
selected-pane eligibility, not merely on a fixed timer after any in-memory resize
callback.

> A full-screen agent's startup box (Claude Code's pig art, "Welcome back Jiwei!",
> the model line, the "Meet Fable 5…" banner) renders boxed into a **narrow ~52-col
> column on the left** with a large dead empty area filling the rest of a **wide**
> pane. This remained unfixed after three earlier attempts (below); the final
> resolution is recorded above.

## Symptom (confirmed with a user screenshot)

Window is wide (~2000 px), sidebar open, inspector (Project Files) closed, so the
terminal pane is ~100+ columns. But Claude Code's whole welcome box + banner + prompt
are boxed into ~52 columns on the left, with the right ~half of the pane a blank white
void. Box-drawing characters + hard newlines do **not** reflow on a later grow, so
whatever width the agent was born at is frozen forever.

## Root cause (this part is solid)

Termio owns the PTY (host-managed `.inMemory` backend via `PTYProcess`, **not**
libghostty's `.exec` — `docs/CLAUDE.md` is stale on this). The agent child reads its
winsize via `TIOCGWINSZ` at startup and prints its box at that width. **If the child
is spawned/sized before the terminal view reaches its final width, the box freezes
narrow.** So the fix must guarantee the child's *first* winsize equals the *final*
pane width.

The hard part is that "final pane width" is not known at any single, reliable moment
during launch — the layout settles in several bursts (see the measured timeline). Two
distinct early-wrong sizes were found feeding the resize path:

1. **ghostty's placeholder default surface size** — a `48×17` grid (`768×578` px) that
   ghostty fires through `receive_resize` (the `receiveResizeCallback`) *before*
   `synchronizeMetrics` delivers the real, view-derived grid. Both land through the
   same `InMemoryTerminalSession` resize closure, so Termio can't tell them apart by
   value.
2. **the window's own not-yet-final size at launch.** Before the final fix, `App.swift`
   created the window at
   a hardcoded `1100×720` (`applicationDidFinishLaunching`), installed the SwiftUI
   content (`contentViewController = makeContentSplitViewController()`) — which lays out
   the terminal and can spawn the session — and only *then* called
   `setFrameAutosaveName`, which restores the saved **wide** frame. So the first layout
   can happen at 1100 (≈52 cols with the sidebar) and the wide frame arrives later.

## What is NOT the cause (proven earlier, don't re-derive)

- **Live resize works.** The view grows with the window, fills its pane superview
  exactly, and the core reflows the *live* grid (12 → 91 cols on a driven resize). Not
  a frame-stall / render-tick / reflow bug. Do not touch the resize path.
- **Not the ghostty core version.** Both tip and Lakr233 reflow the live grid. Rolling
  the dependency back is off the table and irrelevant.
- The fork's AppKit resize hardening (`1.0.5`: `setFrameSize`/`layout`/
  `viewDidEndLiveResize` → `fitToSize` + a 120 ms settle-resync) is fine but was never
  the fix.

## Attempts so far (all insufficient)

All three keep the **deferred-spawn architecture**: `surface(for:in:)` no longer
creates the `PTYProcess` eagerly at the persisted `lastHostGridColumns` guess. Instead
it registers a per-session `pendingSpawns` thunk (capturing the resolved
argv/env/cwd/inMemory) and spawns later. `spawnPTYIfNeeded` / `spawnPTY` are idempotent
and keyed by session id; `companionPTY` fires a headless spawn at the fallback grid for
never-shown sessions. This much is sound and should be kept. What changed between
attempts is *when* and *at what size* the birth fires.

**Attempt 1 — spawn on the first resize-closure fire.**
Result: born at **48×17** — ghostty's placeholder default, which fires before the real
grid. Flaky: occasionally born correct depending on callback ordering (a race). This is
what shipped when the user first said "still not fixed."

**Attempt 2 — `GridBox` (record latest grid synchronously) + spawn 50 ms later, reading
the latest.** Rationale: the 48 and the real grid arrive in the same synchronous
`rebuildIfReady`, so a tiny delay lets the real grid win.
Result: born at **69** (the inspector-open pane) in one run — matched that run's settled
grid, but 50 ms is far too short for the full layout settle.

**Attempt 3 — debounce the birth (current tree state).** Birth fires only after resizes
stop for **200 ms** (`spawnDebounces`, `scheduleSpawn`), at the settled grid. Because
the agent's output can't precede its own birth, delaying birth is race-free — it only
trades startup latency.
Result in **synthetic tests**: correct. With no saved frame (1100 window) → born 52
(correct for 1100). With a **wide** saved frame set in `defaults` → born **121**
(correct). **But the user still sees ~52 in a wide window.** The synthetic test set the
wide frame so the window was already wide at the *first* layout (first resize = 121),
which does **not** reproduce the user's "narrow-first-then-restored-wide" ordering.

## Measured timelines (attempt 3, one-clock NSLog)

Wide saved frame — window wide at first layout, born correct:
```
29.899 resize cols=121        ← saved frame already applied before first layout
29.901 resize cols=48         ← ghostty placeholder default
29.926 resize cols=121
30.017 resize cols=121 rows=52
30.344 BIRTH  cols=121 rows=52   ← correct
35.065…35.947 resize burst 121→108→…→121   ← ~5 s later, app-driven, UNEXPLAINED
```

Default 1100 window — never restored wide, born 52 (correct for 1100):
```
13.112 resize cols=52
13.112 resize cols=48
13.220 resize cols=52 rows=23
13.493 BIRTH  cols=52 rows=23
19.873 resize cols=58         ← much later
```

Two things to chase in these logs:
- The **~5 s-later resize burst** with no user interaction means the layout is **not
  stable** even seconds after launch. A 200 ms quiet-window debounce cannot be trusted
  to have caught the final size.
- The user's failing case (**wide window, born ~52**) was never reproduced under
  instrumentation. The saved-frame restore must be landing *after* the debounce fires
  in their real session — the exact ordering the synthetic test skipped.

## Current hypothesis (for the next agent to confirm or kill)

The birth debounce (200 ms after the last resize) fires **before** the window's saved
wide frame is restored — because `App.swift` installs the content (which lays out the
terminal at 1100 and starts the debounce) **before** `setFrameAutosaveName`, and the
restore's resize can arrive more than 200 ms later (and there's a further mystery
relayout ~5 s in). So the child is born at the pre-restore ~52-col width.

Two families of fix to evaluate (see the prompt):
- **Make the window reach its final frame *before* the terminal ever lays out** — mirror
  Muxy, which is a SwiftUI `WindowGroup` (`MuxyApp.swift`) whose scene restores the
  frame before content layout, so the terminal's *first* `setFrameSize` is already
  final. In Termio: call `setFrameAutosaveName` / restore the saved frame *before*
  `window.contentViewController = …`, and don't spawn until the window is on screen.
- **Stop trusting a timer** — birth only when the grid has been stable across a couple
  of layout passes *and* the window has finished presenting (e.g. after
  `windowDidBecomeKey` + one stable measurement), with no fixed upper bound.

## Reference — Muxy (`github.com/muxy-app/muxy`, cloned to `/tmp/muxy-ref`)

`.exec` backend: ghostty spawns the child inside `ghostty_surface_new`. Muxy defers
`createSurface()` until `backingPixelSize()` is valid and (re)tries it from
`setFrameSize` (`GhosttyTerminalNSView.swift:349`, gate `pendingSurfaceCreation`). Its
terminal view observes only `didChangeScreen` + occlusion — resize sensing is the same
`setFrameSize`/`layout` as Termio. **The decisive difference is the window lifecycle:**
Muxy is a SwiftUI-scene app (`MuxyApp.swift` / `Views/MainWindow.swift`) so the window
is at its restored size before the terminal lays out; Termio hand-builds the `NSWindow`
and restores the frame after installing content.

## Key files

- `Sources/termio/TermioStore/TermioStore+TerminalSurface.swift` — `surface(for:in:)`,
  `spawnPTYIfNeeded`, `spawnPTY`, `scheduleSpawn`, and the `PTYHolder` / `GridBox`
  boxes. The deferred-spawn + debounce lives here.
- `Sources/termio/TermioStore/TermioStore.swift` — `pendingSpawns`, `spawnDebounces`,
  `lastHostGridColumns` / `rememberHostGrid`.
- `Sources/termio/App.swift` — `applicationDidFinishLaunching`: window created at
  `1100×720`, content installed at line ~119, `setFrameAutosaveName` at ~122. **Prime
  suspect for the ordering bug.**
- `Sources/termio/CompanionServer.swift` — `companionPTY(for:)` headless spawn path.
- fork `.../Surface/TerminalSurfaceCoordinator.swift` (`synchronizeMetrics`,
  `updateViewport`) and `.../InMemory/InMemoryTerminalSession.swift`
  (`receiveResizeCallback` fires the 48×17 placeholder).

## Repro & instrumentation notes

- Build the dev bundle: `TERMIO_CHANNEL=dev ./scripts/build-app.sh`; run the inner
  binary directly so `Bundle.main` stays the `.dev` app and to pass env:
  `TERMIO_METRICS_LOG=1 ./termio-dev.app/Contents/MacOS/termio` (the metrics sink in
  `App.swift` was removed — re-add it, or use `TerminalDebugLog.enable(.metrics)`).
- `NSLog` from `spawnPTYIfNeeded` (birth cols/rows) and the resize closure gives a
  single wall-clock timeline in `/tmp/termio-dev.log` via `open … --stderr`.
- To reproduce the user's wide-window case you must get the window to lay out **narrow
  first, then restore wide** — the synthetic `defaults write sh.termio.app.dev
  "NSWindow Frame TermioMainWindow" …` before launch instead made it wide *from the
  first layout* (born correct), which is why attempt 3 looked fixed under test.
- `osascript`/System Events **cannot** set window bounds here; drive resizes from inside
  the app or via the saved frame.

---

## Debugging prompt for a fresh agent

> You are debugging a **spawn-timing / window-lifecycle** bug in Termio (native macOS
> Swift + libghostty terminal for AI agents). A full-screen agent (Claude Code) opens
> with its box-drawing welcome banner **frozen at ~52 columns on the left of a wide
> pane**, with dead space filling the rest. Box-drawing content never reflows, so the
> child must be *born* at the final pane width.
>
> **Read `docs/bug/terminal-narrow-grid-frozen-banner-on-open.md` first — it front-loads
> the root cause, three failed attempts, and measured timelines. Do NOT re-derive: (a)
> live resize works — this is not a resize/reflow bug; (b) the eager-spawn-at-guess was
> already replaced by a deferred-spawn architecture that is correct and must be kept;
> (c) do not roll back the libghostty dependency; (d) no zig / no building ghostty from
> source.**
>
> The current (attempt-3) fix debounces the PTY birth 200 ms after resizes quiesce. It
> births correctly in synthetic tests but the user still sees ~52 cols in a wide window.
> The leading hypothesis: `App.swift`'s `applicationDidFinishLaunching` installs the
> SwiftUI content (which lays the terminal out at the hardcoded `1100×720` and starts
> the birth debounce) **before** `setFrameAutosaveName` restores the saved wide frame,
> and the restore's resize lands after the debounce fires. There is also an unexplained
> layout resize burst ~5 s after launch (logs in the doc) — the layout is not stable.
>
> **Your tasks, in order:**
> 1. **Reproduce the user's exact ordering** (window lays out narrow, *then* restores
>    wide) under instrumentation — the previous agent never did; its synthetic test made
>    the window wide from the first layout. Add one-clock `NSLog` to the resize closure
>    and `spawnPTYIfNeeded`; run the dev bundle's inner binary with `open … --stderr
>    /tmp/termio-dev.log`. Confirm birth cols < final cols and capture the timeline.
> 2. **Explain the ~5 s-later resize burst** — what drives a layout change seconds after
>    launch with no user input? (Toolbar/sidebar/inspector settle? A second frame
>    restore? Metal layer? Grep `App.swift` chrome setup and the fork's settle-resync.)
> 3. **Pick and implement the robust fix.** Strongly consider making the window reach its
>    **final frame before the terminal ever lays out** (restore the saved frame before
>    `window.contentViewController = …`, and don't spawn until the window is presented) —
>    this is what makes Muxy (`/tmp/muxy-ref`, SwiftUI-scene window) immune. Alternatively
>    replace the fixed-timer debounce with a "grid stable across N passes AND window
>    presented" gate with no fixed upper bound. Whatever you choose, the child's first
>    winsize must equal the steady-state pane width.
> 4. **Prove it** with the metrics log (first `receive resize cols=` / birth == final
>    pane cols) AND a user eye-check screenshot: banner fills the pane, no dead space.
>    Regression-check: live grow/shrink still reflows; a plain shell shows no stray `%`;
>    a phone attaching to a never-shown session still spawns the agent.
> 5. Remove all instrumentation; update this doc's status to `done` with the final
>    root-cause and fix; work on a branch, don't touch `main` until verified.
>
> Key files: `Sources/termio/App.swift` (`applicationDidFinishLaunching` — window
> lifecycle, prime suspect), `Sources/termio/TermioStore/TermioStore+TerminalSurface.swift`
> (`surface(for:in:)`, `spawnPTY*`, `scheduleSpawn`, `GridBox`/`PTYHolder`),
> `Sources/termio/TermioStore/TermioStore.swift` (`pendingSpawns`, `spawnDebounces`),
> `Sources/termio/CompanionServer.swift` (`companionPTY`). Reference: `/tmp/muxy-ref`
> (`Muxy/MuxyApp.swift`, `Views/MainWindow.swift`, `Views/Terminal/GhosttyTerminalNSView.swift`).
</content>
