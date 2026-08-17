---
title: iOS libghostty "non-functional" panel + teardown UAF — root-cause findings
status: active
type: design
created: 2026-07-06
updated: 2026-07-06
related:
  - 20260706-ios-scroll-renderer-health.md
  - ios-ghostty-renderer-panic-investigation.md
---

# iOS libghostty "non-functional" panel + teardown UAF — root-cause findings

> Source-level root cause for both iOS libghostty bugs, from reading Ghostty's Zig
> core + official Swift integration against the vendored Lakr233 wrapper — and the
> ranked fix. Answers `docs/prompts/ios-ghostty-renderer-panic-investigation.md`.

Sources read: `ghostty-org/ghostty` (main `b213a72` / tag `v1.2.0`); local vendored
`ios/vendor/libghostty-spm` (Lakr233, `storage.1.2.9`).

## Headline correction

**Bug A (the "non-functional" panel) is NOT a renderer-health failure.** The panel
text is the terminal **IO-thread death message**, printed into the grid as cells.
Two premises we carried for weeks were wrong:

- `GHOSTTY_ACTION_RENDERER_HEALTH` (tag 39) never firing is **correct** — health
  only emits on a *change*, and only flips on a hard GPU command-buffer error,
  which the device never hits. The renderer stays healthy the whole time.
- The vendored wrapper is **not** dropping RENDERER_HEALTH anymore — it has a case
  that forwards it to a delegate. That detection/recovery path was chasing a
  signal that is never generated *and* is the wrong signal for this panel.

## Bug A — the panel is the IO-thread death message

Strings live in exactly one place: `ghostty:src/termio/Thread.zig`, the
`threadMain` error handler `else` branch (~lines 201-219):

```zig
\\This error is usually due to exhausting a system resource.
...
\\This terminal is non-functional. Please close it and try again.
```

painted via `t.eraseDisplay(.complete)` + `t.printString(str)` — ordinary grid
cells. It fires whenever `threadMain_` **returns any error**. "Exhausting a system
resource" is generic boilerplate on the catch-all arm, not a diagnosed resource.

Ruled out from source:

- Reflow/resize OOM during scroll — the IO callbacks *swallow* those
  (`coalesceCallback` / `wakeupCallback` log-and-continue).
- `nextDrawable` nil / atlas / texture limits — those surface as renderer-health
  `unhealthy`, which is proven never to happen.
- Host-managed backend ops (`HostManaged.zig`) — can't throw.

The one unguarded throw under host-managed I/O is `try self.loop.run(.until_done)`
(`Thread.zig:278`), the kqueue event loop. The wrapper's own patch
`Patches/ghostty/0004-ios-fixes.sh` documents "the kqueue-based event loop panics
on iOS" — but hardened only the **CF-release thread's** `loop.run`, **not** the IO
thread's. Sustained drag-scroll floods that loop with `scroll_viewport`/`resize`
wakeups; a kqueue hiccup returns an error → `threadMain_` returns → death panel.

**Confidence:** source-consistent, not source-proven. Confirm on-device:
`Thread.zig:138` logs `io thread err={}`, `:227` logs `abrupt io thread exit`.
The toggle behavior (panel scrolled-up, clears at bottom) also isn't fully
explained by a one-shot write — correlate with those log lines.

## Renderer health (the mechanism we mistook this for)

- Enum `src/renderer.zig`: `Health = enum(c_int) { healthy, unhealthy }`.
- State `src/renderer/generic.zig`: `health: Value(Health) = .healthy`.
- Flips **only** in `src/renderer/metal/Frame.zig` `bufferCompleted` when the GPU
  `MTLCommandBufferStatus == .error`. **No failure counter, no threshold** —
  binary, per-frame, GPU-only.
- `frameCompleted` pushes `renderer_health` to the mailbox **only on change**.
- CPU-side `drawFrame`/`rebuildCells`/atlas errors do **not** feed health.

So tag 39 silence is expected. The embedded apprt (`src/apprt/embedded.zig`
`performAction`) forwards **every** action unconditionally to `opts.action` — it is
not filtering health; the event is simply never generated because the GPU never
errors.

## Bug B — teardown use-after-free (this hypothesis was right)

Official `SurfaceView_UIKit.swift`:

```swift
override class var layerClass: AnyClass { CAMetalLayer.self }   // backing layer, UIKit-owned
```

The wrapper hands ghostty only the `uiview` pointer; ghostty `addSublayer`s its own
`CAMetalLayer`; teardown leaves that orphaned sublayer's delegate pointing at the
freed Zig surface → `EXC_BAD_ACCESS` in `CA::Context::commit_transaction`. The
wrapper already mitigates by nil-ing the delegate (its own code comment describes
the exact crash). `layerClass` binds the Metal layer's lifetime to the view, so the
orphan class of bug can't exist.

## Decisive constraint

**Host-managed I/O is wrapper-only.** The official Swift integration is
**exec/PTY-only** — `SurfaceConfiguration.withCValue()` never sets `config.backend`
(defaults to EXEC), and repo-wide there are **zero** Swift hits for `HOST_MANAGED`
/ `receive_buffer` / `receive_resize`. Termio on iOS can't spawn a PTY (sandbox;
data comes from the companion socket + SSH). So "switch to the official
integration" is **not viable** — you'd re-implement the wrapper on top of it.

## Ranked recommendation

1. **Patch the vendored wrapper (recommended).**
   - **Bug B:** port `override class var layerClass { CAMetalLayer.self }` into
     `UITerminalView.swift`, delete the sublayer machinery. Medium risk — first
     verify ghostty's iOS embed renders into the view's backing layer when it's
     already a `CAMetalLayer` (official `SurfaceView_UIKit` proves it can; the
     wrapper's pointer-passing path must be checked).
   - **Bug A:** wrap the IO-thread `loop.run` in a `catch`/re-arm (mirroring what
     patch `0004` already did for the CF-release thread) so a kqueue hiccup doesn't
     kill the thread. This is the real fix — Zig layer, requires an xcframework
     rebuild.
   - **Health recovery (app-side, low risk):** keep the existing
     `terminalDidChangeRendererHealth` → `reloadSurface()` wiring as insurance, but
     know it does **not** address Bug A (not a health event).
2. **Adopt official integration wholesale — rejected.** Exec-only; you'd re-add
   host-managed and still maintain a fork.
3. **Fork ghostty to upstream a host-managed Swift path — high effort**, only if
   Termio wants to shed the wrapper entirely.

## Build path (to ship the Bug A / layerClass Zig patch)

- `Script/build.sh` clones `ghostty-org/ghostty` (default `main`), applies
  `Patches/ghostty/0001..0009` (0002 = host-managed backend, 0004 = iOS kqueue
  fixes), then `zig build -Doptimize=ReleaseFast -Dtarget=<arch> -Dapp-runtime=none
  -Dcustom-shaders=false -Dinspector=false -Demit-exe=false` → `libghostty.a` →
  `merge-xcframework.sh` → `GhosttyKit.xcframework`.
- **Zig 0.14.0** for the 1.2.x line (main now wants 0.15.2). iOS targets: device
  `aarch64-ios`, simulator `aarch64-ios-simulator` forced to `apple_a17`.
- **Unconfirmed:** the exact Ghostty commit `storage.1.2.9` was built from isn't
  pinned anywhere in the wrapper repo — pin one before rebuilding.
