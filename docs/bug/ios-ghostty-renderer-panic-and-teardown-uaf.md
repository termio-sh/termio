---
title: iOS libghostty "non-functional" panel + surface-teardown crash — fix journey
status: active
type: bug
created: 2026-07-06
updated: 2026-07-06
related:
  - ../design/20260706-ios-ghostty-renderer-panic-investigation-findings.md
  - ../design/20260706-ios-scroll-renderer-health.md
  - ../prompts/ios-ghostty-renderer-panic-investigation.md
---

# iOS libghostty "non-functional" panel + surface-teardown crash — fix journey

> The record of chasing two iOS libghostty bugs to their real root causes,
> including the wrong turns, and what actually shipped vs. what is staged.
> Read the companion design doc for the full source-level citations.

## The two symptoms

**Bug A — the "non-functional" panel.** On iPhone, sustained finger-drag through
scrollback makes libghostty paint, into the surface:

> This error is usually due to exhausting a system resource. … This terminal is
> non-functional. Please close it and try again.

The session opens fine; only drag-scroll trips it; **it clears when you scroll
back to the live bottom** (the toggle behavior — important later).

**Bug B — the teardown crash (闪退).** Frequent `EXC_BAD_ACCESS object_getClass`
/ `objc_msgSend` / `SIGABRT doesNotRecognizeSelector`, top Zig frame
`object.Object.getProperty`, inside `CA::Context::commit_transaction` →
`_UIApplicationFlushCATransaction`. Worst when surfaces are torn down often
(session switching / eviction).

## The wrong turns (what we believed, and why it was wrong)

1. **"The panel is libghostty's renderer-health failsafe (GPU/Metal)."** We spent
   days here. We cut `scrollback-limit` 2 MB→256 KB, cut `maxRecentTerminals`,
   added scroll-draw coalescing (`docs/design/20260706-ios-scroll-renderer-health.md`),
   forked the wrapper to forward `GHOSTTY_ACTION_RENDERER_HEALTH` and auto-rebuild
   the surface. **None stopped the panel.**
2. **On-device ground truth killed that theory.** `log collect --device-udid`
   (idevicesyslog can't see os_log on iOS 26; `log collect` can) with a probe on
   every ghostty action tag showed **RENDERER_HEALTH (tag 39) fires ZERO times**,
   and there was **no OS Metal/IOGPU/drawable error and no jetsam**. The panel is
   painted purely inside Zig; nothing is dispatched to the app. So the whole
   detect-and-recover fork was hooking a signal that is never produced.

## The reframe (2026-07-06, two source-reading research passes)

Reading Ghostty's Zig core + official Swift integration against the vendored
wrapper produced the correction that unblocked everything:

**Bug A is NOT a renderer-health event at all.** The exact panel strings exist in
exactly one place — `ghostty:src/termio/Thread.zig`, the `threadMain` error
handler (`else` arm, ~L201-219): it is the **IO-thread death message**, printed
into the grid via `eraseDisplay(.complete)` + `printString` whenever
`threadMain_` **returns any error**. "Exhausting a system resource" is generic
boilerplate on the catch-all arm — not a diagnosed resource.

- Renderer health is a red herring: it is binary, per-frame, GPU-only (flips only
  on `MTLCommandBufferStatus == .error` in `metal/Frame.zig`), has **no counter /
  threshold**, and emits **only on change**. The device never GPU-errors, so tag
  39 is correctly never sent. The embedded apprt (`embedded.zig performAction`)
  forwards *every* action unconditionally — it was never filtering health.
- Under the host-managed backend the only unguarded throw inside `threadMain_` is
  `try self.loop.run(.until_done)` (`Thread.zig:278`), the kqueue event loop. The
  wrapper's own patch `Patches/ghostty/0004-ios-fixes.sh` even documents "the
  kqueue-based event loop panics on iOS" — but it hardened only the **CF-release
  thread's** `loop.run`, not the IO thread's. Sustained drag-scroll floods that
  loop with wakeups; a kqueue hiccup returns → `threadMain_` returns → panel.
- **Confidence: source-consistent, not source-proven.** The toggle behavior
  (panel when scrolled up, gone at bottom) is consistent with the death message
  being written to the primary screen — visible only in scrollback, while the
  alt-screen TUI still shows its last frame — but that isn't nailed from source.
  The cheap confirmation is on-device: `Thread.zig:138` logs `io thread err={}`
  and `:227` logs `abrupt io thread exit`.

**Bug B's "adopt the official `layerClass = CAMetalLayer`" idea is impossible on
this path.** A third source-read settled the decisive fact: on iOS ghostty's
Metal renderer (`src/renderer/Metal.zig`) **unconditionally** allocates its own
`IOSurfaceLayer` (a hand-rolled `CALayer` subclass) and `addSublayer`s it,
because the iOS view's backing `layer` is *readonly*:

```zig
.ios => {
    const view_layer = objc.Object.fromId(info.view.getProperty(?*anyopaque, "layer"));
    view_layer.msgSend(void, objc.sel("addSublayer:"), .{layer.layer.value});
},
```

There is no branch that inspects whether the view's backing layer is already a
Metal layer. So `override class var layerClass { CAMetalLayer.self }` is **inert**
on the embedded path — ghostty ignores it and drops its own sublayer on top.
Which means the wrapper's `removeFromSuperlayer` cleanup is **not a hack** — given
ghostty's design it is the *correct* fix. The only real improvement is making that
cleanup cover **every** teardown path. (The wrapper also nils the sublayer's
`delegate`, but that turns out not to be load-bearing — see "Should Termio follow
ghostty's iOS practices?" below for the actual crash mechanism.)

## What actually shipped (Bug B — the crash)

The crash cleanup existed on exactly one teardown path and missed the other:

| teardown path | reaches | cleaned orphaned layer? |
| --- | --- | --- |
| `UITerminalView.didMoveToWindow(nil)` → `freeSurface()` | `tearDownSurface` | ✅ yes (inline) |
| `TerminalSurfaceCoordinator.rebuildIfReady()` → `tearDownSurface()` | `surface.free()` | ❌ **no** |
| `TerminalSurfaceCoordinator.deinit` → `tearDownSurface()` | `surface.free()` | ❌ no |

`rebuildIfReady` fires on **session switch / config change / controller swap** —
it frees the surface (orphaning the `IOSurfaceLayer`) and *immediately* builds a
new one that adds a second sublayer, leaving the dead layer attached — its
overridden `display` still bound to the now-freed renderer — for the next
CoreAnimation commit to composite and crash on. This is a live crash source the
`didMoveToWindow` mitigation never covered.

**Fix (vendored wrapper, iOS-only, builds green):** route every teardown through
one cleanup via a coordinator hook.

- `TerminalSurfaceCoordinator`: new `onSurfaceLayersOrphaned` closure, fired in
  `tearDownSurface()` right after `surface.free()` (guarded by `hadSurface`).
- `UITerminalView.commonInit`: wires the hook to a new
  `detachOrphanedSurfaceLayers()` (nil each sublayer delegate + `removeFromSuperlayer`).
- `didMoveToWindow(nil)` now calls the same helper instead of its own inline copy.

AppKit leaves the hook nil (macOS uses `setProperty("layer")` + `wantsLayer`, no
sublayer, so no orphan). Verified: `swift build` (macOS slice) and
`xcodebuild -scheme GhosttyTerminal -destination 'iOS Simulator'` both
**BUILD SUCCEEDED**. Behavioral verification on device pending (reproduce rapid
session switching, confirm no `object_getClass` crash).

## What is staged but NOT built (Bug A — the panel)

The real fix is a one-line Zig patch mirroring `0004`'s CF-thread guard, applied
to the IO thread. **It cannot be built in this repo — `zig` is not installed and
the Zig core ships as a prebuilt xcframework.** So it is documented here,
ready to drop into `Patches/ghostty/` for the next zig-equipped xcframework
rebuild — deliberately NOT added as an active auto-applying patch, so it can't
silently break an untested rebuild.

Proposed `Patches/ghostty/0010-io-thread-loop-resilience.sh`:

```bash
#!/bin/bash
set -euo pipefail
SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# The IO thread's kqueue loop can error under wakeup flood (drag-scroll on iOS).
# When threadMain_ propagates that error, threadMain prints the "non-functional"
# death panel into the grid. Patch 0004 already guards the CF-release thread's
# loop.run the same way; the IO thread was left unguarded. Catch + log so a
# transient kqueue hiccup does not tear down the terminal.
THREAD="${SOURCE_DIR}/src/termio/Thread.zig"
if [ -f "$THREAD" ]; then
    if grep -q 'try self.loop.run(.until_done);' "$THREAD"; then
        sed -i '' 's/try self\.loop\.run(\.until_done);/self.loop.run(.until_done) catch |err| { log.warn("io thread loop failed err={}", .{err}); return; };/' "$THREAD"
        echo "[+] patched io thread to survive loop.run errors"
    else
        echo "[+] io thread already patched"
    fi
fi
```

**Caveats to resolve before trusting it:**
- Confirm on device that the actual `io thread err=` is the kqueue loop (not a
  different throw) — this patch only helps if the trigger is `loop.run`.
- `catch … return` suppresses the *panel* but leaves the terminal non-functional
  (the IO loop has exited). A better fix re-arms/retries the loop instead of
  returning — but a kqueue loop that re-errors immediately would busy-loop, so
  that needs device testing. Ship the conservative catch first, measure, then
  decide on retry.
- The true prevention is upstream (Ghostty): the iOS kqueue backend shouldn't
  error under wakeup flood in the first place.

## Should Termio follow ghostty's iOS practices?

We read the official ghostty iOS integration (commit `0535770`, 2026-07-06) to
decide. The short answer: **adopt the lifecycle *discipline*, not the
integration** — and most of what looks like "the ghostty way" is either vestigial
or impossible on our path.

- **`layerClass = CAMetalLayer` is vestigial even in ghostty.** Their
  `SurfaceView_UIKit` overrides it, but the renderer draws into its own
  `IOSurfaceLayer` sublayer on *both* platforms and never uses the view's backing
  layer as a drawable. Copying it would be cargo-culting. Correctly *not* adopted.
- **There is no CALayer delegate.** ghostty subclasses `CALayer`, overrides
  `display`, and stores the callback + renderer context as *instance variables on
  the layer*. So the real dangling reference on teardown is the layer's
  `display_ctx` (the freed renderer), read if CA composites/displays the orphan —
  **the load-bearing cleanup is `removeFromSuperlayer`, not `delegate = nil`.**
  Our hook does both; the `removeFromSuperlayer` is what actually prevents the
  crash. (Our comments' "dangling delegate" framing is inherited from the wrapper
  and slightly imprecise, but the fix is correct.)
- **Why ghostty never hits our crash — and why we must.** The official view is
  strictly 1:1 with its surface and thrown away together, so it frees the surface
  synchronously in the view's own `deinit` and lets the whole view+layer tree die
  at once — no manual sublayer teardown anywhere. Termio deliberately does the
  opposite: it **keeps surfaces alive and reloads them in place** so a phone
  session survives reconnects/evictions. That capability is the *reason* we
  inherit the orphaned-layer teardown that ghostty gets for free. So the crash
  isn't "we diverged from ghostty" — it's the tax for a feature ghostty doesn't
  have, and the fix is necessarily termio-specific (the teardown hook above).
- **The official integration is exec/PTY-only** (no host-managed backend in the
  Swift layer). Termio *must* keep the wrapper. Switching is off the table.
- **Adoptable practices we already meet or now meet:** free the surface exactly
  once, on the main actor (`TerminalSurface.free` guards `hasBeenFreed`, is
  `@MainActor`); hand libghostty an unretained view pointer and free the surface
  before the view dies; never build a Swift render loop for drawing (ghostty owns
  the render thread; our only display links are for scroll coalescing); create
  surfaces only at non-zero size (`rebuildIfReady` guards `hasValidViewSize`).
- **Intrinsic-to-official, not cherry-pickable:** the "free in deinit and let CA
  ordering protect you" trick works only with 1:1 throwaway views. Because Termio
  moves/reuses surfaces, it must sequence teardown explicitly — which is exactly
  what the `onSurfaceLayersOrphaned` hook now enforces on every path.

**Verdict:** Termio's design is already converging on ghostty's actual principle
(deterministic single-owner surface lifetime); this change closes the last gap.
No re-architecture toward the official integration is warranted or possible.

## Status

- **Bug B:** fixed in the vendored wrapper, compiles for iOS and macOS. Needs a
  device run to confirm the session-switch crash is gone.
- **Bug A:** root cause reframed and the fix specified; blocked on a zig
  toolchain + one on-device log capture. Panel remains a known limitation until
  the xcframework is rebuilt.
