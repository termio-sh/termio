---
title: New terminal opens unfocused (hollow cursor, beeps until clicked)
status: fixed
type: bug
created: 2026-07-14
updated: 2026-07-14
related:
  - terminal-focus-loss-on-window-key.md
  - terminal-focus-loss-on-sibling-render.md
---

# New terminal opens unfocused (hollow cursor, beeps until clicked)

> Fixed on 2026-07-14. The app-side `moveFocus` driver covers the selected surface,
> and equivalent pre-window retry behavior shipped in `libghostty-swift` `1.0.12`,
> which Termio now requires and pins.

## Symptom

A freshly created or first-mounted terminal can open without keyboard focus.
Typing does nothing (or rings the macOS no-responder beep) until the pane is
clicked. Quiet plain terminals show the failure more often than agent sessions.

## Root cause

The wrapper's `synchronizeFocus` gives up when its `TerminalView` is not attached
to a window:

```swift
guard let view, let window = view.window else { return }
```

The old selection handler wrote a shared `@FocusState` in the same render pass
that mounted the surface. If that write reached the wrapper before AppKit attached
the view, it was dropped with no retry. Busy agent sessions often appeared to
self-heal because later status/output renders called `updateNSView`; idle shells
had no incidental update and stayed unfocused.

A later bounded `focusSelected` experiment retried the SwiftUI value itself. That
still observed the wrong signal: the binding can read as selected while the
terminal is not first responder, or remain nil while Ghostty is actually focused.

## Fix

The shared optional FocusState and the bounded value retry are gone. The selected
surface requests `TerminalFocusDriver.moveFocus` from both its selection change
and `onAppear`. The driver resolves the actual `TerminalView`, and if it is not
windowed yet it reschedules with the same capped exponential backoff used by
Ghostty (`50ms`, `100ms`, up to `500ms`) for as long as that session remains the
selected visible terminal.

Once attached, the driver calls `window.makeFirstResponder(target)` and verifies
that AppKit accepted the move. No unrelated render is needed.

`libghostty-swift` 1.0.12 performs the same retry inside each
`AppTerminalView`, so the reusable component no longer drops a focus request just
because `updateNSView` arrived before window attachment. Its pre-window regression
test attaches the view after the first attempt and verifies that it becomes first
responder without another SwiftUI render. Termio's manifest and resolved dependency
both select that release.

## Verification

Rebuild and open a new idle `~` terminal. Without clicking, type immediately. The
cursor should be solid and the keystrokes should land without a beep.

During the 2026-07-14 focus verification, logs showed successful explicit
`selection-changed` focus moves across multiple sessions and the deterministic
orphan recovered in about 5 ms. That strongly exercises the shared driver, but it
is not a substitute for repeatedly opening a brand-new idle terminal; keep the
manual check above in the release regression pass.
