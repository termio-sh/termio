---
title: iOS scroll-draw coalescing (vsync-capped surface draws)
status: archived
type: design
created: 2026-07-06
updated: 2026-07-06
related:
  - ../bug/ios-ghostty-renderer-panic-and-teardown-uaf.md
  - 20260706-ios-ghostty-renderer-panic-investigation-findings.md
---

# iOS scroll-draw coalescing (vsync-capped surface draws)

> ⚠️ **CORRECTION (superseded by the bug doc).** This doc originally claimed the
> "non-functional" panel is a libghostty *renderer-health / CAMetalDrawable
> starvation* failure that this coalesced-draw change *fixes*. **That root-cause
> theory was wrong** — on-device logs later proved `RENDERER_HEALTH` is never
> emitted and no Metal/drawable error occurs. The panel is actually the
> **libghostty IO-thread death message** (`src/termio/Thread.zig`, kqueue
> `loop.run` throw), unrelated to scroll drawing. See
> [`../bug/ios-ghostty-renderer-panic-and-teardown-uaf.md`](../bug/ios-ghostty-renderer-panic-and-teardown-uaf.md)
> for the real cause and fix. What remains valid below is the coalescing change
> itself — kept as a **scroll-rendering hygiene** improvement (one drawable per
> vsync, smoother momentum), **not** as a fix for the panel. The historical
> renderer-health framing in the sections below is left for the record.

## Symptom

Open a session on the phone, drag to scroll back through the output, and the
surface paints a paragraph over the real content:

```
This error is usually due to exhausting a system resource.
If this looks like a bug, please report it.
This terminal is non-functional. Please close it and try again.
```

It composites *on top of* the still-visible scrollback (a stale layer showing
through — see "Related failure" below), so the screen looks garbled rather than
blank. Coasting (flick-and-release) rarely trips it; a sustained drag does.

## What the panel actually is

It is **not** a Termio view — there is no label to hide, no `.isHidden`, no API
to suppress the string. It is painted by **libghostty's Zig renderer directly
into its own Metal surface** when the renderer flips itself to
`GHOSTTY_RENDERER_HEALTH_UNHEALTHY` after repeated GPU/Metal errors. libghostty
ships as a remote SwiftPM package (`Lakr233/libghostty-spm`, pinned at 1.2.8),
so the panel lives on the GPU, inside code Termio cannot patch without forking.

Two consequences follow:

- **We can't hide it.** The only way Termio can *clear* it is to tear down and
  rebuild the surface — which the manual reload button (`reloadSurface()`)
  already does. That treats the symptom, not the trigger.
- **So we must prevent the Metal error that trips it.** That is what this fix
  does for the scroll path.

## Root cause of the scroll trigger

`DisplayTerminalView` rides libghostty's own pan-to-scroll recognizer with a
second target so it can drive the draw itself (the wrapper's `startDisplayLink`
is a stub — it paints through `DispatchQueue.main.async`, off the vsync
boundary, which lands a frame behind the gesture). The old handler drew
**synchronously on every pan `.changed`**:

```swift
case .changed:
    drawScrollFrameNow()   // ghostty_surface_refresh + ghostty_surface_draw
```

A `UIPanGestureRecognizer` delivers `.changed` **several times per frame** (up
to 120 Hz sampling on ProMotion). Each `ghostty_surface_draw` acquires a
`CAMetalDrawable`, and a `CAMetalLayer`'s drawable pool is only **~3 deep**.
Draw faster than the compositor releases them and the next
`nextDrawable()` returns **nil** → libghostty logs a Metal error → after a few
in a row it trips its renderer-health failsafe and paints the panel.

The momentum tail never had this problem: it already drew on a `CADisplayLink`,
i.e. once per vsync. Only the active-drag path was uncapped. That asymmetry is
exactly why *dragging* trips the panel and *flicking* usually doesn't.

## Fix: one vsync pump, at most one drawable per frame

Coalesce the whole interaction onto a single `CADisplayLink` (`scrollPump`) that
owns both the active drag and the momentum glide, and **draws at most once per
vsync**:

- `.began` — resolve the surface handle, start the pump, mark dirty.
- `.changed` — set `needsScrollDraw = true` only. **No synchronous draw.**
- pump tick (dragging) — if `needsScrollDraw`, clear it and draw *once*.
- `.ended`/`.cancelled` — switch the pump to coasting; it paints every frame
  through a ~1.2 s deceleration tail, then stops itself.

The cap — one `ghostty_surface_draw` per frame regardless of how many `.changed`
events arrived — is the entire fix: the drawable pool can never empty, so the
Metal error that trips the failsafe never fires. Code:
`ios/Sources/TerminalViewController.swift`, `DisplayTerminalView`
(`scrollGestureChanged`, `scrollPumpFrame`, `startScrollPump`, `stopScrollPump`).

This is deliberately a **termio-side** fix — no fork, small surface area. It
targets the scroll trigger specifically.

## Related failure and what's left

The panel is one of several libghostty renderer failures on the phone; the
others (OOM/jetsam, a use-after-free of orphaned `CAMetalLayer`s that also
explains the stale content bleeding through) are covered by
`reloadSurface()` + `detachOrphanedSurfaceLayers()` and remembered separately.
The **true root fix** still lives upstream:

1. libghostty should forward `GHOSTTY_ACTION_RENDERER_HEALTH` to the host so
   Termio can auto-reload instead of showing the panel. The wrapper currently
   drops that action (`default:` case), so nothing rebuilds the dead surface.
2. `ghostty_surface_free` should nil the orphaned layer's delegate and
   `removeFromSuperlayer()` before returning.

Both need a libghostty-spm fork / SwiftPM local override, deferred by choice.
Revisit this doc if the coalesced pump proves insufficient and the fork becomes
worthwhile.

## Verification

- `xcodebuild -scheme TermioMobile -destination 'generic/platform=iOS'` builds
  clean.
- On device: sustained drag-scroll through a long Claude session no longer
  paints the "non-functional" panel; scroll stays smooth (still one draw per
  vsync) and the momentum tail is unchanged.
