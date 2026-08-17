# 004 — Make the rightward "back to list" swipe finger-tracked

- **Status**: TODO
- **Severity**: LOW (additive / missed opportunity)
- **Commit**: 74889a8
- **Category**: Interruptibility / missed opportunity
- **Estimated scope**: 2 files (`TerminalViewController.swift`, `RootContainerViewController.swift`), medium — **higher risk than 001–003; do it last**

## Problem

The drawer that opens *leftward* is beautifully interactive — it tracks the finger
frame-by-frame and (after plan 001) settles with carried velocity. But the
*rightward* swipe that pops back to the session list, living in the **same** pan
handler, is discrete: it does nothing until `.ended`, then fires a fixed
container animation.

```swift
// ios/Sources/TerminalViewController.swift:875 — current (handleOpenPan)
if openPanGoesBack {
    guard pan.state == .ended else { return }        // nothing tracks the finger
    let fling = pan.velocity(in: view).x > 300
    if fling || pan.translation(in: view).x > view.bounds.width * 0.3 {
        goBack()
    }
    return
}
```

So the two halves of one gesture feel inconsistent: pull-left rubber-bands under
your thumb; push-right is a button press in disguise. iOS users expect the
back-swipe to track (Messages, Safari).

## Target

During a rightward `.changed`, translate the terminal screen with the finger and
fade in a peek of the list underneath; on `.ended`, complete or cancel with a
velocity-carrying spring — the same feel as the drawer. Because the terminal
screen is owned by the container (`RootContainerViewController`), the interactive
progress must be driven **through the container**, not by `TerminalViewController`
moving a view it doesn't own.

Recommended implementation seam (verify against the code before writing):

1. Add three methods to `RootContainerViewController` that expose the existing
   `goHome` slide as an interactive transition:
   - `func beginInteractiveBack()` — snapshot state, no animation.
   - `func updateInteractiveBack(progress: CGFloat)` — set
     `activeScreen.view.frame.origin.x = view.bounds.width * progress` (0 = full
     screen, 1 = fully off-right); mirror the existing `goHome` offscreen math at
     `RootContainerViewController.swift:220`.
   - `func finishInteractiveBack(velocity: CGFloat, commit: Bool)` — spring the
     frame to either fully-off (then run the same teardown as `goHome`'s
     `finish()` closure, line 221) or back to `view.bounds`, feeding
     `initialSpringVelocity: velocity` exactly as plan 001 does for the drawer.
2. Route these from `handleOpenPan`'s `openPanGoesBack` branch: call
   `updateInteractiveBack(progress:)` on `.changed` and `finishInteractiveBack`
   on `.ended`, using the normalized-velocity formula from plan 001
   (`points/sec ÷ remaining points`, clamped to `[0, 30]`).
3. Keep the current commit thresholds: fling `> 300` **or** translation
   `> bounds.width * 0.3` commits the back.

Reuse plan 001's spring settings (`withDuration: 0.35, damping: 0.9`) so the
interactive back and the drawer share one motion identity.

## Repo conventions to follow

- `goBack()` / `onRequestBack` is the existing hand-off from
  `TerminalViewController` to the container — the new interactive methods should
  be reached the same way (extend the `onRequestBack` seam or add sibling
  closures; do not have `TerminalViewController` reach into the container
  directly).
- The container already parks vs. evicts the screen in `goHome`'s `finish()`
  (line 221) — `finishInteractiveBack(commit: true)` must run that identical
  teardown, not a copy that forgets the park/evict branch.
- Velocity normalization: identical formula and `[0, 30]` clamp as plan 001.

## Steps

1. Add `beginInteractiveBack` / `updateInteractiveBack(progress:)` /
   `finishInteractiveBack(velocity:commit:)` to `RootContainerViewController`,
   factoring the `goHome` offscreen math and `finish()` teardown so both the
   discrete `goHome` and the interactive path share them.
2. Expose them to `TerminalViewController` via the same closure mechanism as
   `onRequestBack`.
3. In `handleOpenPan`, replace the `openPanGoesBack` discrete block with `.began`
   → begin, `.changed` → update(progress), `.ended/.cancelled` → finish with
   carried velocity and the existing commit thresholds.

## Boundaries

- Do NOT change the *leftward* drawer behavior (that is plan 001's territory).
- Do NOT introduce `UIViewControllerAnimatedTransitioning`/
  `UIPercentDrivenInteractiveTransition` unless the screen is actually inside a
  `UINavigationController` — this app uses a custom container; drive the frame
  directly as `goHome` already does.
- Do NOT duplicate the park-vs-evict teardown — share it.
- If `handleOpenPan`, `goHome`, or the `onRequestBack` seam don't match the
  excerpts (drift since 74889a8), STOP and report rather than guessing the
  container's ownership model.

## Verification

- **Mechanical**: `swift build` (iOS target) clean.
- **Feel check** (`ios-rebuild-dev`, real device preferred for gestures):
  - Slow-drag rightward — the terminal should track the finger, revealing the
    list beneath; releasing below threshold should spring it back to full screen.
  - Flick rightward — it should complete the pop with visible carry-through, not a
    fixed-speed slide.
  - Reverse mid-drag — the transition must retarget without snapping (it is a
    live frame follow, not a keyframe).
  - Confirm a parked session stays alive after an interactive back (reopen it and
    the surface/scrollback is intact) and a closed one is torn down — i.e. the
    shared `finish()` teardown ran.
- **Done when**: pull-left and push-right feel like one continuous, interruptible,
  velocity-aware gesture, and session park/evict still works.
