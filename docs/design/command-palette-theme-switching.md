---
title: Quick theme switching from the command palette
status: done
type: design
created: 2026-07-27
updated: 2026-07-27
---

# Quick theme switching from the command palette

> Make trying a terminal theme a fast, keyboard-first flow — search, preview live
> on the real terminal, commit or revert — instead of a trip through Settings.
> Implements [#118](https://github.com/jiweiyuan/termio/issues/118).

## Problem

Theme selection lived only in **Settings ▸ Appearance** (`AppearanceSettingsTab`):
two slots (Light / Dark), each a `ThemePickerField` popover. Trying a theme meant
opening Settings, opening the right slot's popover, browsing, then closing Settings
— with no way to flip through themes while looking at a real terminal. Sublime/Zed/
VS Code all make this a first-class palette flow: fuzzy search, arrow-key live
preview against your real buffer, **Enter commits, Esc reverts**.

## Design (scope locked from #118)

A new **`PaletteMode.themes`** sub-mode of the command palette, opened by a
**"Change Theme…"** command in the ⌘⇧P list. It reuses the palette's existing fuzzy
search, grouping, and keyboard nav; each theme is a `PaletteItem` of kind `.theme`.

1. **Single implicit slot — the two-slot concept is never surfaced.** The selector
   edits **only the slot matching the current effective macOS appearance** (dark
   terminal on screen → Dark slot) and lists **only same-brightness themes**
   (reusing `ThemeLibrary`'s `isDark` partition). You change the theme you're
   looking at. It does **not** offer to switch the app appearance itself — that
   stays in Settings. This is the same tradeoff Zed's theme selector makes (it
   picks one theme for the current mode; the light/dark pair is configured
   elsewhere).
2. **A reset row** labeled **"Default Light Theme" / "Default Dark Theme"** (the
   empty selection), named after the slot so "default" isn't ambiguous.
3. **Warp-style swatch per row** — the theme's real background + ANSI colors are
   its leading icon (reuses `ThemeSwatch`), so the list reads as color, not text.
4. **Live preview is free plumbing; Esc-revert is not.** Arrowing/hovering writes
   the highlighted theme into the slot, which fires `AppSettings.objectWillChange`
   → `applyAppearanceToOpenSurfaces()` and recolors every open terminal — the exact
   path the Settings picker already uses. But that path is **live-apply-only**:
   `ThemePickerField` persists on every hover with **no revert**. So Esc-revert is a
   small new state machine: snapshot the slot's theme name on open (`beginThemeBrowsing`),
   restore it on any dismissal that isn't a commit (`endThemeBrowsing`), and seed the
   highlight to the current theme so the opening preview is a no-op. `Enter`/click
   commits; Esc, click-away, and switching modes all revert.
5. **No dedicated chord** (no `⌘K ⌘T`). termio has no chord-prefix system and one
   feature doesn't justify introducing one; the palette command is the entry point.

### North stars

Sublime invented the pattern; Zed is the best native-Mac execution (same palette
overlay, live preview on the real buffer, Enter/Esc). The swatch idea comes from
Warp (real ANSI color chips); the "edit only the current-appearance slot" tradeoff
mirrors Apple's Light/Dark/Auto model — the full two-slot config stays in Settings.

## Bug found & fixed: the catalog was silently empty

While building this, the bundled catalog turned out to list only ~20–30 themes, not
the expected hundreds. Root cause in `ThemeLibrary`:

```swift
// darkBundledThemeNames / lightBundledThemeNames
GhosttyThemeCatalog.search("")   // intended: "return everything"
```

Swift's `"abc".contains("")` is **`false`**, so `search("")` (which filters by
`name.contains(query)`) returned **nothing**. Both `darkBundledThemeNames` and
`lightBundledThemeNames` were silently empty — every theme picker (the new palette
*and* the old Settings popover's "All …" section) showed only the hardcoded popular
shortlist (~14 dark / ~9 light) plus the default row. That's the "only ~20–30
themes" symptom.

Fix: read the catalog directly.

```swift
GhosttyThemeCatalog.allThemes.filter { $0.isDark } ...
```

The 485 bundled themes partition to **399 dark / 86 light**, both slots full again.

## Key files

- `Sources/termio/CommandPalette/CommandPalette.swift` — `PaletteMode.themes`, the
  "Change Theme…" command, `themeItems`, slot resolution, `begin/endThemeBrowsing`,
  live-preview + revert, swatch rows.
- `Sources/termio/Theme/ThemeLibrary.swift` — the `search("")` → `allThemes` fix.
- `Sources/termio/Settings/ThemePickerField.swift` — existing picker; source of the
  reused `ThemeSwatch` and the live-apply path.
