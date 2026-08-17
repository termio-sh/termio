---
title: "HANDOFF: terminal content does not reflow on window resize"
status: done
type: bug
created: 2026-07-09
updated: 2026-07-09
---

# HANDOFF — terminal content does not reflow when the window is resized

> **RESOLVED 2026-07-09 — root cause found and fixed, user-verified.** See §0.
> The rest of this file is kept as the investigation record.

## 0. RESOLUTION

**Root cause: the PTY spawn shape, not anything in the resize/render path.**
`PTYProcess` spawned children via `posix_spawn` + `POSIX_SPAWN_SETSID` + a
file-actions `open` of the pts. That produces a controlling terminal that
*looks* wired — `/dev/tty` resolves, a `sh` `trap WINCH` fires, `TIOCSWINSZ`
returns 0 — but **Claude Code v2.1.170 (Bun-compiled) never repaints on resize
under it**. The same binary under `forkpty` (login_tty: explicit `setsid` +
`TIOCSCTTY` in the child) reflows correctly. Proven with a minimal Python A/B
harness outside the app (`forkpty`: redraws, 3/3 runs; spawn-shape: 0 bytes
after resize, 2/2 runs), controlled for `TERM_PROGRAM` and signal dispositions.

That is why §3's instrumentation showed every stage "correct": the size *was*
delivered (TIOCSWINSZ succeeded, the grid followed, ghostty painted the new
grid) — but the child never learned it should repaint, so the VT screen kept
the old-width drawing. §1's "environmental, not a code regression" was exactly
right: the variable that changed 2 days prior was the **Claude Code version**
(its resize-detection mechanism changed); Termio's spawn shape had always been
wrong but nothing had stepped on it before.

**Fix:** `PTYProcess.init` now spawns via `forkpty` — the shape every terminal
uses (node-pty, iTerm2, kitty, VS Code). Child side is async-signal-safe only
(prebuilt argv/env C arrays; `chdir` + `execve` + `_exit`). Verified by the
user: dragging the window wide now reflows the Claude TUI to fill the pane.

Also resolved by the same fix: `docs/bug/terminal-narrow-grid-frozen-banner-on-open.md`
(a narrow-born banner now recovers on the first real resize instead of freezing
forever).

---

## 1. THE decisive fact: it is NOT a code regression

The user insists "两天前 (2 days ago) it worked." So we checked out the **exact** 2-days-ago
commit into a clean git worktree and built it:

```
git worktree add /tmp/termio-2daysago 0bd4559   # "build(macos): switch Mac app to Lakr233"
# built its termio.app (Lakr233/libghostty-spm 1.2.9) — an UNTOUCHED checkout
```

**That untouched 2-days-ago build reproduces the bug too.**

Therefore the same source that "worked 2 days ago" fails **now** → the cause is **environmental /
state, not a code change.** Do NOT git-diff or git-bisect the source; the previous agent wasted
hours doing exactly that. Whatever changed lives OUTSIDE the source tree (persisted UserDefaults,
display/monitor configuration, the Claude Code agent version, or macOS state).

The worktree at `/tmp/termio-2daysago` (commit `0bd4559`, bundle id `com.termio.app`) is still there
— use it as the clean control. Remove with `git worktree remove /tmp/termio-2daysago --force`.

---

## 2. The symptom (precisely)

- A Claude Code session's TUI renders **boxed into a narrow column (~38–52 cols) on the LEFT** of a
  **wide** window, with a large **white void** filling the pane to the right.
- The user's sharpest framing: **"初始化正确，resize window 就不行"** — *the terminal is the right
  size when it first opens, but dragging the window to resize does not make the inner content
  follow.* And crucially: **"它里面的东西一直保持那个大小，没有自动放大，并不是跳回去，是一直没变"**
  — the content simply never enlarges; it is not that it grows then snaps back.
- So this is a **live-resize / repaint** problem, not a launch/first-paint problem.

### Acceptance test
Open Claude Code in a narrowish window on the **primary** monitor, drag the window wider.
**PASS = the Claude TUI (welcome box, "Meet Fable 5" banner, prompt line, the `? for shortcuts`
input separator) reflows to fill the new width, no white void on the right.**

---

## 3. What is PROVEN by instrumentation — DO NOT re-derive

The full resize chain was logged end to end (`TERMIO_GEOM` in the wrapper's
`TerminalSurfaceCoordinator.synchronizeMetrics`, plus `TERMIO_RESIZE_CB` / `TERMIO_RESIZEHOST` /
`TERMIO_TIOCSWINSZ` in Termio). Dragging the window produced, per drag:

| step | log | result |
| --- | --- | --- |
| view frame resizes | `TERMIO_GEOM view_pt=326→727 grid=38→84` | ✅ the NSView DOES track the window |
| ghostty recomputes grid | same `grid=` field | ✅ surface grid tracks (up to 84 cols) |
| wrapper → Termio resize callback | `TERMIO_RESIZE_CB cols=84` ×271 | ✅ fires |
| `PTYProcess.resizeFromHost` | `TERMIO_RESIZEHOST … owner=host` ×271 | ✅ runs, `owner=host` (NOT companion) |
| winsize to the child | `TERMIO_TIOCSWINSZ cols=74 rc=0` (coalesced ~5×) | ✅ **child gets the correct winsize** |

**Conclusion: the view resizes, ghostty's grid is correct, and the child process receives the
correct new winsize (TIOCSWINSZ rc=0). Everything up to and including the child is correct. The ONLY
thing that fails is the final step — the visible pixels do not repaint; the rendered frame stays at
the pre-resize width.** It is a **render/repaint** failure, downstream of size propagation.

Corollary rule-outs (already proven, do not revisit):
- **Not the size-ownership / companion gate.** `owner=host` throughout; the phone-attaches-and-claims
  path is not involved.
- **Not the PTY winsize.** The child gets 74 cols, rc=0.
- **Not the NSView being hard-stuck narrow.** `view_pt` grew to 727 pt during the drag — the view
  tracks. (It was measured at 326 pt at one idle moment, but it does resize.)

---

## 4. Architecture facts you MUST know

- **Termio owns the PTY host-side** (`.inMemory` backend via `Sources/termio/PTYProcess.swift`), NOT
  ghostty's `.exec`. The agent process is independent of the ghostty surface, so the surface can be
  torn down / recreated without killing Claude. (`docs/CLAUDE.md` is stale — it says `.exec`.)
- The `InMemoryTerminalSession` (in the wrapper) holds the VT/screen state; the ghostty **surface**
  only renders it.
- **This embedding renders REACTIVELY off coalesced wakeups — there is no guaranteed continuous
  render tick on macOS.** A dropped render edge = stale paint. `warmUpRendering` / `pumpRendering`
  (in `TermioStore+TerminalSurface.swift`) exist to pump `controller.tick()` for a while to force
  paints. This is the likely locus of the repaint failure.
- **Lakr233 vs the jiweiyuan fork is a drop-in swap for Termio.** Session control
  (`TermioStore+SessionControl.swift`) reaches the raw `ghostty_surface_t` by **Mirror reflection**
  and calls the raw C API `ghostty_surface_key` — it does NOT use the fork's public
  `submitReturn`/`sendKeyEvent`/`rawValue`. Verified: Termio compiles **unchanged** against
  `Lakr233/libghostty-spm` 1.2.9. (macOS `Package.swift` is currently pointed at Lakr233 1.2.9.)

---

## 5. Dead ends — DO NOT repeat these (each was tried and failed)

1. **PTY birth timing** — deferred spawn, `surfaceSize`-gated birth, 200/450 ms debounce,
   restore-window-frame-before-`contentViewController`. **~15 rounds, all the wrong layer.** Birth
   width is irrelevant to a *resize* repaint failure. (All reverted.)
2. **Rolling macOS from the fork back to Lakr233** — done; did NOT fix it (§1: the 2-days-ago Lakr233
   build fails too).
3. **`.frame(maxWidth: .infinity, maxHeight: .infinity)` on `TerminalSurfaceView`** in `TerminalPane`
   — stopped a size oscillation but did not fix the narrow render. (Reverted.)
4. **Disabling the fork's `scheduleSettleResync`** (a re-fit loop in `AppTerminalView+Lifecycle`) —
   stopped a 38↔94 col oscillation but left the grid stuck at 38. Not the fix. (Fork-only anyway.)
5. **Render pump `controller.tick()` on resize** — did not visibly fix it (tried under the fork).
6. **git diff / bisect of the source** — pointless; §1 proves the source is identical to the
   working version.

---

## 6. Current state of the working tree (IMPORTANT — it is dirty)

- `Package.swift` → `Lakr233/libghostty-spm` from `1.2.9` (rolled back from the fork).
- App code was `git checkout HEAD`-reverted for the spawn/layout files, so it is ~HEAD.
- **Uncommitted, JUST added, NEVER built/tested** (user interrupted the build): a "force refresh on
  resize" in `monitor()` (`TermioStore+TerminalSurface.swift`) + a `resizeRefreshWork` debounce dict
  in `TermioStore.swift`. It subscribes to `state.$surfaceSize`, debounces ~180 ms after resizes
  stop, then calls `PTYProcess.jiggleResize()` (SIGWINCH shrink+restore → child redraws its whole
  TUI) + `pumpRendering(state, duration: 0.5)`. **This is the user's own suggested "force reload
  ghostty on resize" idea — it is implemented but UNVERIFIED. Build it and test it first.**
- The fork checkout under `.build/checkouts/` may still contain a temporary `TERMIO_GEOM` NSLog in
  `TerminalSurfaceCoordinator.swift` (harmless, and unused now that Package points at Lakr233).
- iOS (`ios/TermioMobile.xcodeproj`) still points at the remote **fork** via
  `XCRemoteSwiftPackageReference` — untouched.

Nothing is committed. The branch is `fix/terminal-narrow-grid-frozen-banner`.

---

## 7. The promising UNEXPLORED leads (start here)

Because §1 says it's environmental, chase these — roughly in order:

1. **Purge persisted state and retest.** The day's broken builds persisted narrow grids via
   `rememberHostGrid`, and a stale `NSSplitView Subview Frames …` can pin the detail pane narrow.
   Clear these keys for `com.termio.app`, `sh.termio.app`, and `sh.termio.app.dev`:
   `termio.lastHostGridColumns` / `termio.lastHostGridRows`, `"NSWindow Frame TermioMainWindow"`,
   any `"NSSplitView Subview Frames …"`, then relaunch a fresh session. (Quick, high-value.)
2. **Test on the PRIMARY monitor.** The user's window was on a **second** monitor (measured window
   frame `x=1858`, screen origin `x=1512, y=-98`). Multi-monitor + differing backing scale/geometry
   is a classic terminal-sizing/repaint breaker. Move the window to the built-in display and retest.
3. **Compare against a known-good terminal.** Run the SAME Claude Code in **Ghostty.app** or
   **Terminal.app** and resize. If Claude Code itself no longer reflows there either, the regression
   is in the **Claude Code agent version**, not Termio — which would perfectly explain "same code,
   worked 2 days ago, broken now." This single test rules the agent in or out and should be done
   EARLY.
4. **Fix the repaint directly** (the confirmed failure point). The size reaches the child correctly,
   so force the surface to repaint at the new size. In order of increasing force:
   a. `jiggleResize()` + `pumpRendering` on resize-settle (the untested code in §6).
   b. Investigate whether the **Metal layer size** updates on resize (`updateMetalLayerMetrics` in
      the wrapper's `AppTerminalView+Lifecycle`) — a Metal layer stuck at the old size would render
      the correct grid into a stale-size drawable.
   c. Nuclear: recreate the ghostty surface on resize (Termio owns the PTY, so the agent survives —
      but the InMemory session must replay/repaint its screen). This is the user's literal
      "reload ghostty on drag" request; keep as last resort due to flicker/scroll loss.

---

## 8. How to build/run/observe (repro harness)

- Dev build (isolated, bundle id `sh.termio.app.dev`, port 8788):
  `TERMIO_CHANNEL=dev ./scripts/build-app.sh` then
  `open ./termio-dev.app --stdout /tmp/termio-dev.log --stderr /tmp/termio-dev.log`.
- Kill only the dev app: `pkill -9 -f "termio-dev.app/Contents/MacOS/termio"`.
- **You cannot script a window resize** (System Events can't set bounds here). You must ask the user
  to drag the window, then read `/tmp/termio-dev.log`.
- Re-add the `TERMIO_GEOM` NSLog to the wrapper's `synchronizeMetrics` (log `size.width` points +
  computed `grid` cols) and the `TERMIO_RESIZE_CB/RESIZEHOST/TIOCSWINSZ` logs in Termio to re-observe
  the chain — but note §3 already established the chain works up to the child.

---

## 9. One honest note for the next agent

This session failed the user across ~30 rounds by fixating on PTY birth timing and by declaring
"probably fixed" from a small screenshot without a wide-window check (the user, rightly, called that
out). Trust the §3 evidence, start from §1 (it's environmental) and §7 lead #3 (test another
terminal — the agent may be the real variable), and get a wide-window visual confirmation from the
user before claiming anything is fixed.
