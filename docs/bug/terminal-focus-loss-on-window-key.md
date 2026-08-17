---
title: Terminal loses focus after window deactivation
status: fixed
type: bug
created: 2026-07-02
updated: 2026-07-14
related:
  - terminal-focus-loss-on-sibling-render.md
  - terminal-focus-loss-on-new-session-mount.md
---

# Terminal loses focus after window deactivation

> Fixed on 2026-07-14. The app-side focus driver restores deterministic responder
> loss automatically, and wrapper-level per-surface `moveFocus` behavior shipped
> in `libghostty-swift` `1.0.12`, which Termio now requires and pins.

## Symptom

After Cmd-Tab, Spotlight, a settings/update panel, or another key-window change,
the terminal cursor could remain hollow when the main window became key again.
Keystrokes went nowhere until the user clicked the terminal.

## Original root cause

Older `libghostty-swift` focus plumbing conflated two independent facts:

- whether the terminal view is AppKit first responder; and
- whether its window is key.

`windowDidResignKey` dimmed Ghostty's cursor and also wrote `false` through the
SwiftUI focus binding. A host render while the app was inactive then saw a false
binding and could call `makeFirstResponder(nil)`. On reactivation the view was no
longer first responder, so the wrapper had nothing to restore.

The race correlated with agent activity because sibling status, live-title, and
git updates caused the renders that completed the failure while the window was
inactive.

## Wrapper fix (1.0.11)

The fork now keeps window-key state separate. `windowDidResignKey` calls
`core.setFocus(false)` to draw an inactive cursor but does not write to the
SwiftUI binding. `synchronizeFocus` also refuses to surrender a terminal merely
because a false binding is observed while the window is non-key.

Wrapper version 1.0.12 extends that 1.0.11 fix with per-view binding intent,
stale-work cancellation, deferred orphan detection, and Ghostty-style focus-move
retry. Its tests also assert that a window-key callback never rewrites surface
focus intent. See `terminal-focus-loss-on-sibling-render.md` for implementation
and test details.

## App-side hardening

`TerminalPane` no longer restores window focus by writing a shared optional
FocusState. Its `NSWindow.didBecomeKeyNotification` handler asks
`TerminalFocusDriver` to repair the selected surface directly.

The driver resolves the actual `GhosttyTerminal.TerminalView` and only performs a
window-activation repair when first responder is orphaned (the window itself or
`nil`). A legitimate first responder such as an editor, command-palette field, or
browser is left alone. If the surface has not reached a window yet, the request is
retried with a capped backoff.

The same driver covers the window-stays-key sibling-render race documented in
`terminal-focus-loss-on-sibling-render.md`, but that path is triggered after
surface reconciliation rather than by a key-window notification.

## Verification

With an agent producing background updates, Cmd-Tab away for several seconds and
return. The terminal should accept typing immediately without a click. For the
window-stays-key deterministic check, use **Debug: Orphan Terminal Focus** in the
dev command palette and inspect the `focus` log category with `--level debug`.

The 2026-07-14 verification exercised the harder window-stays-key responder loss
and passed (see the sibling-render note). It also showed explicit focus moves
across several session selections. A longer soak with repeated Cmd-Tab cycles is
still useful because this document's original trigger is timing-dependent.
