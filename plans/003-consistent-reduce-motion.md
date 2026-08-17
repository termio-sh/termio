# 003 — Honor Reduce Motion consistently across the accessory bar & tab bar

- **Status**: TODO
- **Commit**: 74889a8
- **Severity**: MEDIUM
- **Category**: Accessibility
- **Estimated scope**: 2 files, 3 edits
- **Depends on**: 002 (the attach-menu dismiss line is also edited there — run 002 first, then this)

## Problem

The codebase already has a *correct* Reduce Motion pattern — `showVoiceBar` /
`hideVoiceBar` drop the scale transform and just cross-fade when
`UIAccessibility.isReduceMotionEnabled` is true:

```swift
// ios/Sources/TerminalAccessoryBar.swift:260 — the exemplar to imitate
private func showVoiceBar() {
    let reduce = UIAccessibility.isReduceMotionEnabled
    ...
    voiceBar.transform = reduce ? .identity : CGAffineTransform(scaleX: 0.96, y: 0.96)
    UIView.animate(withDuration: reduce ? 0.2 : 0.28, ...) {
        self.voiceBar.alpha = 1
        self.voiceBar.transform = .identity
    }
}
```

But three other motions ignore Reduce Motion entirely, so a user who has it
switched on still gets scaling, spinning, and character-tilt motion:

```swift
// ios/Sources/TerminalAccessoryBar.swift:450 — attach menu ENTRANCE, ungated scale-from-corner
let collapsed = CGAffineTransform(scaleX: 0.4, y: 0.4)
    .translatedBy(x: -size.width * 0.5, y: size.height * 0.5)
card.alpha = 0
card.transform = collapsed
UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.78,
               initialSpringVelocity: 0) {
    card.alpha = 1
    card.transform = .identity
}
```

```swift
// ios/Sources/TerminalAccessoryBar.swift:469 — attach menu DISMISS, ungated scale
// (after plan 002 this reads `.curveEaseOut`)
UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
    card?.alpha = 0
    card?.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        .translatedBy(x: -size.width * 0.5, y: size.height * 0.5)
}
```

```swift
// ios/Sources/GlassControls.swift:192 — tab select fires the spin / character-tilt keyframes ungated
if animated, changed, buttons.indices.contains(index) {
    playSelectionAnimation(on: buttons[index], icon: icons[index])
}
```

## Target

Reduce Motion means *fewer and gentler*, not zero — keep the opacity cross-fades
and the selection-pill slide (they aid comprehension of which surface appeared /
which tab is active), and drop only the decorative transform motion: the
card's scale-from-corner and the tab icons' spin/tilt/hop.

```swift
// target — presentAttachMenu (TerminalAccessoryBar.swift:450)
let reduce = UIAccessibility.isReduceMotionEnabled
let collapsed = CGAffineTransform(scaleX: 0.4, y: 0.4)
    .translatedBy(x: -size.width * 0.5, y: size.height * 0.5)
card.alpha = 0
card.transform = reduce ? .identity : collapsed
UIView.animate(withDuration: reduce ? 0.2 : 0.4, delay: 0,
               usingSpringWithDamping: 0.78, initialSpringVelocity: 0) {
    card.alpha = 1
    card.transform = .identity
}
```

```swift
// target — dismissAttachMenu (TerminalAccessoryBar.swift:469, curve already .curveEaseOut after 002)
let reduce = UIAccessibility.isReduceMotionEnabled
UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
    card?.alpha = 0
    if !reduce {
        card?.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            .translatedBy(x: -size.width * 0.5, y: size.height * 0.5)
    }
} completion: { _ in
    scrim.removeFromSuperview()
}
```

```swift
// target — GlassControls.select (GlassControls.swift:192)
if animated, changed, !UIAccessibility.isReduceMotionEnabled,
   buttons.indices.contains(index) {
    playSelectionAnimation(on: buttons[index], icon: icons[index])
}
```

The tab tint cross-fade (`GlassControls.swift:180`) and the selection-pill settle
spring (`GlassControls.swift:198`) stay — they carry meaning, not decoration.

## Repo conventions to follow

- Mirror the `let reduce = UIAccessibility.isReduceMotionEnabled` + ternary
  transform pattern established in `showVoiceBar`/`hideVoiceBar`
  (`TerminalAccessoryBar.swift:260`, `:281`) verbatim — same variable name, same
  shape.
- Gate the *decorative* keyframe/spring layer animations by not starting them at
  all (the `select` guard), rather than threading `reduce` into
  `playSelectionAnimation`.

## Steps

1. `presentAttachMenu` (`TerminalAccessoryBar.swift`, around 450): add
   `let reduce = UIAccessibility.isReduceMotionEnabled`, set the initial
   `card.transform` via `reduce ? .identity : collapsed`, and make the duration
   `reduce ? 0.2 : 0.4`.
2. `dismissAttachMenu` (around 469): add the `reduce` flag and wrap the card's
   `transform` assignment in `if !reduce { … }` (leaving `alpha = 0` unconditional).
3. `GlassControls.select` (around 192): add `!UIAccessibility.isReduceMotionEnabled`
   to the `if animated, changed, …` condition.

## Boundaries

- Do NOT gate or remove the tint cross-fade (`GlassControls.swift:180`) or the
  selection-pill settle spring (`:198`) — those aid comprehension and must remain.
- Do NOT change any non-reduced (normal-motion) durations except the attach
  entrance, which becomes `reduce ? 0.2 : 0.4` (0.4 unchanged when motion is on).
- Do NOT touch `showVoiceBar`/`hideVoiceBar` — they are already correct.
- If the attach card lines still read `.curveEaseIn` at the dismiss, plan 002 has
  not landed — apply 002 first, then return here. If the excerpts otherwise don't
  match (drift since 74889a8), STOP and report.

## Verification

- **Mechanical**: `swift build` (iOS target) compiles clean.
- **Feel check** (`ios-rebuild-dev`): in the simulator, Settings ▸ Accessibility ▸
  Motion ▸ **Reduce Motion = ON**, then relaunch the app and:
  - Open the (+) attach menu — the card should **fade** in place (no growing out
    of the corner) and fade out on dismiss (no shrinking into the key).
  - Tap between the bottom tabs — the active tab should **cross-fade** its tint and
    the pill should still slide, but the icons must **not** spin/rock/hop.
  - Toggle Reduce Motion **OFF**, relaunch, and confirm all the original motion is
    fully restored.
- **Done when**: with Reduce Motion on, no scale/rotation/translate transform
  animates in the attach menu or tab icons, while opacity and the pill slide still
  do; with it off, behavior is byte-for-byte the original.
