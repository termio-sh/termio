---
title: Terminal loses focus while the window stays key — sibling-render trigger
status: fixed
type: bug
created: 2026-07-14
updated: 2026-07-14
related:
  - terminal-focus-loss-on-window-key.md
  - terminal-focus-loss-on-new-session-mount.md
---

# Terminal loses focus while the window stays key — sibling-render trigger

> Fixed on 2026-07-14. The faithful first-responder fault injector recovered
> without a click, typing landed, and the user confirmed the original problem is
> no longer occurring. The reusable root fix shipped in `libghostty-swift`
> `1.0.12`, which Termio now requires and pins.

## Symptom

While typing in a terminal or agent TUI, another session changing state can make
the active cursor turn hollow. The main window remains key and the selected pane
does not change, but keystrokes have no destination until the user clicks.

## Why the first rescue did not work

All mounted terminal surfaces previously shared one optional SwiftUI focus value:

```swift
@FocusState private var focusedSession: Session.ID?
```

The first attempted repair watched that value change to `nil` and wrote the
selected session id back. Live tracing disproved its premise: clicking the
terminal can make Ghostty's `AppTerminalView` first responder (and its cursor
solid) without ever populating the SwiftUI value. `focusedSession` was already
`nil`, so there was no `value -> nil` transition and the repair was dead code.

The cursor's truth is AppKit first-responder ownership, which drives
`AppTerminalView.becomeFirstResponder` / `resignFirstResponder` and
`core.setFocus`. A shared `@FocusState` is only declarative intent, and was not a
reliable observation of that truth.

The shared optional also allowed cross-talk. Any mounted surface reporting
`false` wrote `nil` through `TerminalFocusBinding.optional`, clearing the intent
for every sibling. The wrapper's `synchronizeFocus` only focuses a view whose
binding already reads true, so nothing recovered from that state.

## Ghostty's model

Ghostty's macOS app uses three defenses that the wrapper integration lacked:

1. Every surface owns its own Boolean focus state; surfaces do not share an
   optional enum binding.
2. Window-key status is a separate axis and never becomes surface-focus truth.
3. `Ghostty.moveFocus` retries with a capped exponential backoff until the target
   view has a window, and explicitly resigns the previously focused surface before
   moving first responder.

Ghostty also remembers the last focused surface as a fallback during transient
SwiftUI focus gaps.

## Fix

`TerminalPane.swift` now adopts the parts of that model possible without rebuilding
the wrapper fork:

- `ManagedTerminalSurface` gives every mounted terminal its own
  `@FocusState<Bool>`. The binding is used to turn a click on a visible split into
  selection; it is not treated as the focus source of truth.
- `TerminalFocusDriver` locates the exact `GhosttyTerminal.TerminalView` in the
  main window by matching its `TerminalViewState` delegate. It moves AppKit first
  responder directly, explicitly resigns a previous terminal, and retries
  `50ms -> 100ms -> ... -> 500ms` while the selected view is not windowed.
- Selection changes, surface mount, palette/overlay close, file drop, and main
  window activation request focus explicitly.
- A small `NSViewRepresentable` probe gets `updateNSView` during parent/store
  reconciliation. On the following runloop it asks the driver to repair focus.
  Render-driven repair is guarded to the orphan shape (`firstResponder` is the
  window itself or `nil`), so it never steals focus from a field, overlay, browser,
  or newly clicked sibling.

The sibling-render path no longer depends on a shared FocusState transition or on
a single wrapper re-render landing at the right time.

## Wrapper root fix (`libghostty-swift` 1.0.12)

The `libghostty-swift` fork now moves the reusable part of the repair into
`AppTerminalView`:

- each AppKit terminal stores only its own current focus binding;
- a focused surface retries first-responder acquisition with Ghostty's capped
  `50ms -> 100ms -> 200ms -> 400ms` backoff while it is not windowed;
- deferred work re-reads the current binding and uses generations so stale render
  passes cannot steal focus;
- a previous terminal is explicitly resigned before moving focus;
- a transient resign to `window` / `nil` is repaired, while a real responder such
  as a text field wins and clears the old surface's intent;
- key-window notifications update Ghostty's visual focus but do not rewrite the
  surface focus binding; and
- an optional enum focus binding only clears itself if it is still the active
  enum case, preventing a late resign from clearing a newly focused sibling.

The wrapper tests cover pre-window retry, orphan recovery, legitimate responder
handoff, and separation of window-key state. `swift test` passed all 104 tests in
12 suites, and `Script/test.sh` compiled the full macOS, Mac Catalyst, iOS, and
iOS Simulator matrix.

## Deterministic verification

The dev command palette keeps **Debug: Orphan Terminal Focus**, but the injector
is now faithful. After the palette closes it finds the selected terminal's real
AppKit view, makes that view first responder, then calls
`window.makeFirstResponder(nil)` while the main window remains key. It does not
mutate SwiftUI focus state directly.

Expected focus-category log sequence:

```text
fault injector: dropped terminal first responder while key=true session=...
recovered terminal focus [fault-injector] -> ...
```

Read info/debug messages explicitly:

```sh
/usr/bin/log stream --level debug \
  --predicate 'subsystem == "sh.termio.app.dev" && category == "focus"'
```

The visual pass condition is that the cursor returns to solid and typing lands
without a click. macOS Accessibility/TCC prevents the shell from synthesizing the
verification keystroke, so the final visual/input check must be performed by a
person.

### Verified result (2026-07-14)

The dev build produced the complete expected sequence against session `831BE9B4`:

```text
13:28:19.611 fault injector: dropped terminal first responder while key=true
13:28:19.616 recovered terminal focus [fault-injector]
```

Recovery took approximately **5 ms**. The cursor returned to solid, subsequent
typing landed without another click, and the user reported that the real-world
problem was basically fixed. This validates the responder drop, app-side repair,
and input path rather than merely a SwiftUI binding transition.

## Defence in depth / monitoring

The current repair covers the observed orphan shape: a selected visible terminal
should own focus, no overlay/palette owns it, and the main window's first responder
has fallen back to the window itself or `nil`. It intentionally does not steal
focus from another real responder.

Two uncommon paths would still need upstream work or additional evidence:

- Ghostty's core could theoretically become visually unfocused while AppKit still
  reports the terminal as first responder; the orphan guard would see nothing to
  repair.
- A future legitimate control could disappear leaving a responder shape other
  than `window` / `nil`; the conservative guard would leave it alone.

Keep the dev injector and `Log.focus` category until the fix has had enough soak
time across agent-state churn, split panes, window switching, and new mounts.

## Release/integration status

The wrapper source change is released as `libghostty-swift` `1.0.12`, and Termio's
manifest and resolved dependency both select that version. Keep the verified
app-side guard through a soak period; then simplify only duplicated acquisition
logic, retaining conservative host policy about which selected/visible pane
should receive focus.

This change is entirely in the Swift wrapper around the prebuilt Ghostty core, so
it does not require rebuilding the Zig core on this machine.
