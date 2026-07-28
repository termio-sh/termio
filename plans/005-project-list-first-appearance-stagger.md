# 005 — Stagger the project list in on first appearance

- **Status**: TODO
- **Severity**: LOW (additive / missed opportunity)
- **Commit**: 74889a8
- **Category**: Cohesion & tokens (stagger) / missed opportunity
- **Estimated scope**: 1 file (`ios/Sources/ProjectListViewController.swift`), ~15 lines

## Problem

The home screen — the project list, the first thing a user sees each launch —
appears with a flat `reloadData()`; all rows paint in the same frame with no
motion. This is a rare, high-value first-run/return moment with none of the
delight budget it is allowed.

```swift
// ios/Sources/ProjectListViewController.swift:31 — plain UITableView, reloadData at :85/:236
private let tableView = UITableView(frame: .zero, style: .grouped)
```

The list uses a classic `UITableViewDataSource`/`Delegate` (extension at
`ProjectListViewController.swift:346`), so a `willDisplay` hook is the right seam.

## Target

On the **first** appearance only, the initially-visible rows rise 8pt and fade in
with a 40ms per-row stagger (within the 30–80ms guidance), using a strong
ease-out spring. It is decorative and must never block interaction
(`.allowUserInteraction`), never repeats after the first paint, and is fully
skipped under Reduce Motion.

```swift
// target — add to ProjectListViewController
private var hasStaggeredIn = false

// in the UITableViewDelegate extension (near ProjectListViewController.swift:346)
func tableView(_ tableView: UITableView,
               willDisplay cell: UITableViewCell,
               forRowAt indexPath: IndexPath) {
    guard !hasStaggeredIn, !UIAccessibility.isReduceMotionEnabled else { return }
    let visible = tableView.indexPathsForVisibleRows ?? []
    let row = visible.firstIndex(of: indexPath) ?? 0
    cell.alpha = 0
    cell.transform = CGAffineTransform(translationX: 0, y: 8)
    UIView.animate(withDuration: 0.35, delay: Double(row) * 0.04,
                   usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                   options: [.curveEaseOut, .allowUserInteraction]) {
        cell.alpha = 1
        cell.transform = .identity
    }
}

// in viewDidAppear (add if absent), after super:
hasStaggeredIn = true   // latch once per VC lifetime; returns don't re-stagger
```

## Repo conventions to follow

- Spring shape matches the rest of the app (`withDuration: 0.35,
  usingSpringWithDamping: 0.9` — same as `setDrawer` and the screen push at
  `RootContainerViewController.swift:202`).
- Reduce-Motion gating mirrors the `UIAccessibility.isReduceMotionEnabled` guard
  used in `TerminalAccessoryBar.showVoiceBar` (`:261`).
- 8pt translate + `.identity` reset uses `CGAffineTransform`, the transform type
  used throughout `TerminalAccessoryBar`.

## Steps

1. Add the `hasStaggeredIn` stored property to `ProjectListViewController`.
2. Add the `willDisplay` delegate method to the existing
   `UITableViewDataSource, UITableViewDelegate` extension (around line 346).
3. In `viewDidAppear(_:)` (add the override if it doesn't exist, calling `super`),
   set `hasStaggeredIn = true` so only the very first paint animates.

## Boundaries

- Do NOT apply this to `TerminalListViewController` or any inner list — the home
  project list only. (One delight moment, not motion on every list.)
- Do NOT animate on `reloadData` refreshes, pull-to-refresh, or row
  insert/delete — the `hasStaggeredIn` latch must gate all of those out.
- Do NOT exceed 80ms stagger or 8pt translate; do NOT drop
  `.allowUserInteraction` (the user must be able to tap through the animation).
- If the delegate extension or `reloadData` sites don't match the excerpts (drift
  since 74889a8), STOP and report.

## Verification

- **Mechanical**: `swift build` (iOS target) clean.
- **Feel check** (`ios-rebuild-dev`):
  - Cold launch → the project rows should ripple in top-to-bottom, each a beat
    after the last, settling within ~0.5s total; tapping a row *during* the
    ripple must open it immediately (no blocked touches).
  - Navigate into a project and back → the list must appear **without** re-running
    the stagger (latch works).
  - Reduce Motion ON → rows appear instantly, no rise/fade.
- **Done when**: first launch staggers once, subsequent appearances are instant,
  interaction is never blocked, and Reduce Motion disables it.
