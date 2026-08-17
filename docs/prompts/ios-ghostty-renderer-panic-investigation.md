# Investigation prompt — iOS libghostty "non-functional" panel + teardown crash

> Hand this to a fresh research agent. It front-loads everything already proven
> (via on-device logs and a read of Ghostty's official iOS integration) so the
> agent doesn't re-derive dead ends. Goal: find the Zig/integration root cause and
> decide whether Termio should switch from the third-party wrapper to Ghostty's
> official iOS integration.

---

You are investigating two bugs in an iOS terminal app (Termio) that embeds
libghostty (Ghostty's terminal core) via the third-party SPM package
`Lakr233/libghostty-spm` (v1.2.8), product `GhosttyTerminal`. The Zig core ships
as a prebuilt `GhosttyKit.xcframework`. Backend is the in-memory / host-managed
I/O apprt (`GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`), not a PTY. Renderer is
Metal. A local vendored copy of the wrapper is at `ios/vendor/libghostty-spm`.

## Bug A — "non-functional" panel on scroll
On iPhone, drag-scrolling back through scrollback makes libghostty paint this
panel directly into the surface:

    "This error is usually due to exhausting a system resource.
     If this looks like a bug, please report it.
     This terminal is non-functional. Please close it and try again."

Session opens fine; only sustained drag-scroll triggers it; it clears when you
scroll back to the live bottom.

## Bug B — use-after-free crash (闪退) on surface teardown
Frequent crashes when surfaces are torn down (session switching / eviction):
`EXC_BAD_ACCESS object_getClass` / `objc_msgSend`, or `SIGABRT
doesNotRecognizeSelector`, top app frame `object.Object.getProperty` (a freed Zig
surface object), inside `CA::Context::commit_transaction` →
`_UIApplicationFlushCATransaction`. Cause: `ghostty_surface_free` frees the Zig
surface but the wrapper adds its `CAMetalLayer` as a **sublayer** of the view
whose delegate still points at the freed surface; the next CoreAnimation commit
messages that dangling delegate. (Termio currently mitigates by nil-ing the
sublayer delegate after free, but that's a patch on a structural problem.)

## ALREADY PROVEN — do not re-investigate from the Swift side
On-device unified logs (`sudo log collect --device-udid <udid> --last 15m`; note
`idevicesyslog` cannot see os_log on iOS 26, `log collect` can):
1. `GHOSTTY_ACTION_RENDERER_HEALTH` (action tag 39) is **never** dispatched to the
   wrapper's app action callback — 0 hits across two captures while the panel was
   on screen (every action tag+target was logged at `TerminalCallbacks.action`).
2. The C API (`ghostty.h`) has **no** renderer-health getter; `renderer_health`
   exists only as a field of the never-dispatched action.
3. No OS-level Metal / IOGPU / CAMetalDrawable error and no jetsam/OOM kill when
   the panel shows. The "exhausting a system resource" is Ghostty's own internal
   judgment, not a surfaced Metal failure.
Prevention guesses that did NOT help Bug A: `scrollback-limit` 2 MB→256 KB, and
cutting parked live surfaces (which made Bug B worse).

## KEY LEAD — the official Ghostty iOS integration differs structurally
From reading `ghostty-org/ghostty` `macos/Sources/Ghostty/`:
- Official surface view `SurfaceView_UIKit.swift` sets
  `override class var layerClass: AnyClass { CAMetalLayer.self }` — the Metal
  layer **is the view's own backing layer**, managed by UIKit's lifecycle. The
  Lakr233 wrapper instead **adds a CAMetalLayer sublayer** → the orphaned-layer
  UAF (Bug B). Official approach likely can't produce Bug B at all.
- Base class `OSSurfaceView.swift` exposes `@Published var healthy: Bool = true`
  and `@Published var error: Error?` — i.e. the official integration **does
  receive renderer-health** and surface it. So in the official path the health
  action IS delivered to the apprt. The wrapper's embedded setup apparently
  drops/never-registers it (Bug A becomes invisible + unrecoverable).

Hypothesis to confirm: the wrapper's **non-standard integration** — stubbed
display link + `DispatchQueue.main.async` draws instead of a real render loop, a
sublayer instead of `layerClass`, and no health-action wiring — is the shared
cause of BOTH bugs, and adopting Ghostty's official iOS integration would fix
both.

## Your tasks (answer from Ghostty's Zig + Swift source)
1. Locate the panel text and the renderer "health" state machine in Zig (grep
   `non-functional`, `exhausting a system resource`, `Health`, `unhealthy`).
   Which file/enum/function, and what condition flips health to UNHEALTHY (the
   failure counter + threshold, and which `drawFrame`/`rebuildCells`/`updateFrame`
   error feeds it)?
2. In the Metal renderer, what op fails during scroll/scrollback-reflow at a
   narrow grid? Confirm or rule out: `nextDrawable` nil/timeout, a GPU
   buffer/texture/glyph-atlas allocation exceeding a limit, a Zig allocator OOM,
   IOSurface/heap cap. Which one = "exhausting a system resource"?
3. Where does the renderer report health, and where does each apprt
   (`src/apprt/embedded.zig` vs macOS/GTK) forward it? Why does the embedded
   apprt (used by libghostty) not deliver tag 39 while the official macOS/iOS
   Swift layer gets `healthy`? Is it a missing handler, a target/filter, or a
   config/callback the wrapper never sets?
4. Compare integration approaches and give a recommendation: should Termio
   **replace `Lakr233/libghostty-spm` with Ghostty's official Swift integration**
   (`SurfaceView_UIKit` / `OSSurfaceView` / `Ghostty.Surface`)? Detail: what those
   files require, whether they support the in-memory/host-managed backend Termio
   needs (companion + SSH streaming, not a PTY), the `layerClass` vs sublayer
   difference for Bug B, and the health wiring for Bug A. Rank against the
   alternative of patching the vendored wrapper.
5. Concrete patch/port options, ranked, with exact files + risk:
   (a) adopt official integration; (b) port just `layerClass=CAMetalLayer` +
   health-action wiring into the wrapper; (c) patch the Zig renderer (threshold /
   non-fatal op / emit the action through embedded apprt).
6. Build path: how to build `GhosttyKit.xcframework` from patched Ghostty for iOS.
   The libghostty-spm repo has `build.sh`, `Script/build-ghostty.sh`, and a
   `Patches/ghostty/` dir that already patches Ghostty for embedding — pin the
   exact Ghostty commit/tag it builds from, the zig version, and the commands.

## Where to look
- Ghostty source: https://github.com/ghostty-org/ghostty
  - Zig: `src/renderer/` (Metal.zig, generic.zig, any health*.zig),
    `src/apprt/embedded.zig`, `src/Surface.zig`.
  - Official Swift iOS integration: `macos/Sources/Ghostty/Surface View/`
    (`SurfaceView_UIKit.swift`, `OSSurfaceView.swift`, `SurfaceView.swift`),
    `macos/Sources/Ghostty/Ghostty.Surface.swift`, `Ghostty.Action.swift`
    (see how it maps `GHOSTTY_ACTION_RENDERER_HEALTH`).
  - Official iOS app entry: `macos/Sources/App/iOS/iOSApp.swift`.
- Local wrapper (how Termio drives it today):
  `ios/vendor/libghostty-spm/Sources/GhosttyTerminal/{Controller,Surface,InMemory,Platform/UIKit}`
  — note the stubbed display link, `main.async` draws, sublayer usage, and
  `TerminalCallbackBridge.handleAction` (which has no RENDERER_HEALTH case because
  the action never arrives). Header: `ghostty.h` (RENDERER_HEALTH = action tag 39,
  targets APP=0 / SURFACE=1).

## Deliverable
A written report quoting the relevant Zig/Swift code: (1) exact
file+function+condition that trips Bug A; (2) the specific resource exhausted
during scroll; (3) why the embedded apprt never delivers the health action while
the official Swift layer does; (4) a ranked recommendation on adopting the
official integration vs patching the wrapper, with the in-memory-backend
compatibility verdict; (5) exact zig-build steps to produce a patched xcframework.
