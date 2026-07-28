# 002 — Replace ease-in on dismiss transitions with ease-out

- **Status**: TODO
- **Commit**: 74889a8
- **Severity**: MEDIUM
- **Category**: Easing & duration
- **Estimated scope**: 2 files, 2 one-line changes

## Problem

Two dismiss animations use `.curveEaseIn`, which *starts slow* — it delays the
first frames, exactly when the user is watching the element leave. The audit rule
is firm: "ease-in on UI is always a finding." Both are exits that the user's eye
follows, and one of them is asymmetric with its own entrance (a spring ease-out),
which makes the exit read as sluggish by comparison.

```swift
// ios/Sources/RootContainerViewController.swift:228 — current (terminal → list pop)
if animated {
    UIView.animate(withDuration: 0.3, delay: 0,
                   options: .curveEaseIn,
                   animations: { screen.view.frame = offscreen },
                   completion: { _ in finish() })
}
```
Its matching entrance (`showScreen`, line 202) is
`usingSpringWithDamping: 0.9 … options: .curveEaseOut` — the push lands crisply,
the pop drags out.

```swift
// ios/Sources/TerminalAccessoryBar.swift:469 — current (attach menu dismiss)
UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
    card?.alpha = 0
    card?.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        .translatedBy(x: -size.width * 0.5, y: size.height * 0.5)
} completion: { _ in
    scrim.removeFromSuperview()
}
```

## Target

Both switch to `.curveEaseOut` (fast start, decelerating finish — responsive the
moment the user asks for it). Durations stay as-is (0.3 and 0.2 are both within
the modal/dropdown budgets). No other properties change.

```swift
// target — RootContainerViewController.swift:228
if animated {
    UIView.animate(withDuration: 0.3, delay: 0,
                   options: .curveEaseOut,
                   animations: { screen.view.frame = offscreen },
                   completion: { _ in finish() })
}
```

```swift
// target — TerminalAccessoryBar.swift:469
UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
    card?.alpha = 0
    card?.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        .translatedBy(x: -size.width * 0.5, y: size.height * 0.5)
} completion: { _ in
    scrim.removeFromSuperview()
}
```

## Repo conventions to follow

- Entrances in this codebase already use `.curveEaseOut` — see the matching push
  at `RootContainerViewController.swift:202` and the pill entrance at
  `TerminalAccessoryBar.swift:269` (`options: [.curveEaseOut, .allowUserInteraction]`).
  The dismiss should mirror them.
- Keep the `.translatedBy` corner-anchor math on the attach card untouched — the
  card is *meant* to collapse into the (+) key; only the easing curve is wrong.

## Steps

1. `ios/Sources/RootContainerViewController.swift:230` — change `options: .curveEaseIn`
   to `options: .curveEaseOut`.
2. `ios/Sources/TerminalAccessoryBar.swift:469` — change `options: .curveEaseIn`
   to `options: .curveEaseOut`.

## Boundaries

- Do NOT change durations, transforms, alpha targets, or completion blocks.
- Do NOT touch the entrance animations (they are already correct).
- Do NOT convert either to a spring — a curve swap is the whole fix.
- If either line no longer reads `.curveEaseIn` (drift since 74889a8), STOP and
  report.

## Verification

- **Mechanical**: `swift build` for the iOS target compiles clean.
- **Feel check** (`ios-rebuild-dev`):
  - Open a session, then tap back to the list — the terminal should start sliding
    off **immediately** on tap, decelerating as it leaves, not creeping for the
    first ~100ms.
  - Open the (+) attach menu, then tap the scrim to dismiss — the card should
    begin collapsing into the (+) key instantly, not hang before moving.
  - With iOS **Reduce Motion OFF**, compare the pop-out to the push-in: they
    should now feel like the same family of motion rather than crisp-in /
    sluggish-out.
- **Done when**: neither dismiss has a perceptible slow start; grep for
  `.curveEaseIn` in `ios/Sources` returns nothing.
