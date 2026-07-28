# 001 — Carry fling velocity into the drawer settle spring

- **Status**: TODO
- **Commit**: 74889a8
- **Severity**: HIGH
- **Category**: Interruptibility
- **Estimated scope**: 1 file (`ios/Sources/TerminalViewController.swift`), ~15 lines

## Problem

The slide-over drawer is the app's primary gesture. During the drag it is
finger-tracked frame-by-frame (`layoutDrawer(progress:)`), which feels great —
but on release it settles with a spring whose **initial velocity is hardcoded to
zero**, so a hard flick and a slow drag-and-let-go settle at exactly the same
speed. The motion "detaches" from the finger at the moment of release. The pan
handlers even *measure* the fling velocity to pick the target, then discard it.

```swift
// ios/Sources/TerminalViewController.swift:856 — current
func setDrawer(open: Bool, animated: Bool) {
    drawerOpen = open
    dimView.isUserInteractionEnabled = open
    if open { setTerminalFocused(false) }
    let animations = { self.layoutDrawer() }
    if animated {
        UIView.animate(withDuration: 0.35, delay: 0,
                       usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       animations: animations)
    } else {
        animations()
    }
    if !open { focusInput() }
}
```

```swift
// ios/Sources/TerminalViewController.swift:893 — current (handleOpenPan)
case .ended, .cancelled:
    let fling = -pan.velocity(in: view).x > 300
    setDrawer(open: fling || progress > 0.4, animated: true)   // velocity thrown away
```

```swift
// ios/Sources/TerminalViewController.swift:907 — current (handleClosePan)
case .ended, .cancelled:
    let fling = pan.velocity(in: view).x > 300
    setDrawer(open: !(fling || progress < 0.6), animated: true)   // velocity thrown away
```

Per the audit rule "gesture-driven motion should use springs — they carry
velocity when interrupted." The spring is here; the velocity input is missing.

## Target

`setDrawer` accepts an optional normalized initial velocity (default `0`, so
every non-gesture caller — the dim-view tap, menu actions — is unaffected). Both
pan handlers compute it from the release velocity, normalized by the distance the
drawer still has to travel, and clamped to keep the spring from overshooting
wildly on very fast flicks.

`initialSpringVelocity` for `UIView.animate` is expressed as *fraction of the
remaining animation distance, per second*. So:

```
normalizedVelocity = pointsPerSecond / pointsRemainingToTarget
```

```swift
// target — setDrawer signature + spring
func setDrawer(open: Bool, animated: Bool, initialVelocity: CGFloat = 0) {
    drawerOpen = open
    dimView.isUserInteractionEnabled = open
    if open { setTerminalFocused(false) }
    let animations = { self.layoutDrawer() }
    if animated {
        UIView.animate(withDuration: 0.35, delay: 0,
                       usingSpringWithDamping: 0.9, initialSpringVelocity: initialVelocity,
                       animations: animations)
    } else {
        animations()
    }
    if !open { focusInput() }
}
```

```swift
// target — handleOpenPan .ended (leftward drag opens; -velocity.x is "toward open")
case .ended, .cancelled:
    let vOpen = -pan.velocity(in: view).x
    let willOpen = vOpen > 300 || progress > 0.4
    let remaining = drawerWidth * (willOpen ? (1 - progress) : progress)
    // Signed toward the target: a flick toward the target speeds the spring;
    // a flick away from it starts from rest rather than a backward blip.
    let signed = willOpen ? vOpen : -vOpen
    let v = remaining > 1 ? min(max(signed / remaining, 0), 30) : 0
    setDrawer(open: willOpen, animated: true, initialVelocity: v)
```

```swift
// target — handleClosePan .ended (rightward drag closes; +velocity.x is "toward close")
case .ended, .cancelled:
    let vClose = pan.velocity(in: view).x
    let willClose = vClose > 300 || progress < 0.6
    let open = !willClose
    let remaining = drawerWidth * (open ? (1 - progress) : progress)
    let signed = willClose ? vClose : -vClose
    let v = remaining > 1 ? min(max(signed / remaining, 0), 30) : 0
    setDrawer(open: open, animated: true, initialVelocity: v)
```

`30` is the clamp ceiling (a 30×-per-second spring is already an aggressive
flick); it prevents pathological division when `remaining` is tiny.

## Repo conventions to follow

- The drawer spring is `withDuration: 0.35, usingSpringWithDamping: 0.9` — do NOT
  change the duration or damping; only feed the velocity.
- `progress`, `drawerWidth`, and `pan.velocity(in: view)` already exist in both
  handlers (`handleOpenPan` line 875, `handleClosePan` line 901) — reuse them, do
  not recompute geometry.
- `setDrawer` is also called with no velocity from the dim-view tap
  (`configureDrawer`, line 821) and from `setDrawer(open: false…)` sites — the
  default parameter keeps those call sites untouched.

## Steps

1. In `ios/Sources/TerminalViewController.swift`, change the `setDrawer`
   signature (line 856) to add `initialVelocity: CGFloat = 0` and replace
   `initialSpringVelocity: 0` (line 863) with `initialSpringVelocity: initialVelocity`.
2. Replace the `.ended, .cancelled` case in `handleOpenPan` (lines 893–895) with
   the target block above.
3. Replace the `.ended, .cancelled` case in `handleClosePan` (lines 907–909) with
   the target block above.
4. Leave every other `setDrawer(open:animated:)` call site unchanged (they use the
   default `initialVelocity: 0`).

## Boundaries

- Do NOT touch any file other than `TerminalViewController.swift`.
- Do NOT change the spring duration (0.35) or damping (0.9), the fling threshold
  (300), or the commit-thresholds (`progress > 0.4`, `progress < 0.6`).
- Do NOT add dependencies.
- If the `setDrawer` body or the pan `.ended` cases don't match the excerpts
  above (code drifted since commit 74889a8), STOP and report.

## Verification

- **Mechanical**: `swift build` (from repo root, the iOS target) compiles with no
  new warnings. If the iOS target isn't in the default SwiftPM build, confirm via
  the `ios-rebuild-dev` skill's build step.
- **Feel check**: run on a device/simulator (`ios-rebuild-dev`), open a terminal
  session, then:
  - **Flick** the drawer open fast and release early (~30% out) — it should shoot
    the rest of the way, not crawl at the same speed as a slow drag.
  - Slow-drag to ~50% and release gently — it should ease to rest with no
    perceptible kick (velocity ≈ 0).
  - Flick it *closed* from fully open — same carry-through on the way out.
  - Drag past the commit threshold then reverse the flick at release — it should
    still settle to the threshold target without a visible backward jump (the
    `max(…, 0)` clamp guarantees no negative start).
- **Done when**: fast flicks visibly settle faster than slow releases, and no
  release produces a backward blip or overshoot past the drawer's open/closed rest
  positions.
