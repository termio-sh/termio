---
title: Theme store — browse 50, install on demand, library is truth
status: approved
type: rfc
created: 2026-08-14
updated: 2026-08-16
related:
  - command-palette-theme-switching.md
  - session-daemon-architecture.md
---

# Theme store — browse 50, install on demand, library is truth

> Split themes into default / library / store so the picker stops dumping 485
> Ghostty schemes. A selected theme is a file in the Themes folder. Install
> writes one file; nothing is fetched. Settings chrome is out of scope.

Reviewed 2026-08-14 (Claude Code, approve-with-changes). Locked below:
library-is-truth (file-only resolve + bounded materialization), Install
must not clobber a same-named user file, one atomic PR, no Settings
chrome, no remote theme fetch. Six draft catalog names that do not
resolve are dropped or substituted.

## Problem

termio treats "theme" as one flat catalog. Settings ▸ Appearance, the command
palette's **Change Theme…**, and the iOS picker all list `GhosttyThemeCatalog`
(~485 iTerm2-Color-Schemes names) plus whatever the user dropped in
`~/Library/Application Support/termio/Themes`. A "Popular" group sits on top;
everything else is still one scroll away.

That catalog is a warehouse of ANSI palettes compiled into the
`GhosttyTheme` product. It is not a library. Showing it in every picker
makes every user "have" 485 themes they never chose.

Two rejected answers sit next to this:

- **Ship 50 as the new bundled picker.** Everyone still "has" them. It is a
  smaller dump, not a library.
- **Invent 41 original named suites** (Superlogical's *Velvet Dusk* /
  *Orchard Breeze* model). That is their product identity. Ours is the Ghostty
  file people already know.

The refactor: a **store that lists**, a **library that holds**, and
**resolve only from the library**. Chrome in the main window already
follows the selected theme (sidebar, editor, git, issues, files, trace).
The Settings window does not; that is not this RFC.

## Anatomy of today

| Piece | Where | What it does |
| --- | --- | --- |
| `GhosttyThemeCatalog` | `GhosttyTheme` product in libghostty-swift | ~485 compiled `GhosttyThemeDefinition`s. Warehouse only |
| `ThemeLibrary` | `Sources/termio/Theme/ThemeLibrary.swift` | Resolves user files first, then the catalog. Parses Ghostty `key = value` text. Partitions popular / all-dark / all-light |
| `ChromeTheme` | `Sources/termio/Theme/ChromeTheme.swift` | Derives tokens from one definition. Already consumed by the main window |
| Light / dark slots | `AppSettings.lightThemeName` / `darkThemeName` | Independent names. Empty = termio canvas |
| Mac picker | `ThemePickerField` | Popular + **All Dark/Light Themes** (the 485) + Custom |
| Palette | `CommandPalette.themeItems` | Popular first, then the rest of the slot's catalog. `beginThemeBrowsing` seeds `highlighted` with `?? 0` |
| Main window chrome | sidebar, editor, git, issues, files, trace | Follows the selected theme |
| Settings window | `SettingsView` | System materials. Out of scope |
| iOS | `ThemePickerViewController`, `ThemeBackdrop` | Same 485-wide catalog. Backdrop only |

`ThemeLibrary.directory` is already the VS Code / Zed install location.
The store is that folder plus a browse UI, not a new persistence scheme.

Theme stays a **client** concern. `termiod` never sees a palette.

## Design invariants

1. **Three layers, one file format.** Default, library, and store all speak
   Ghostty `key = value` (or the empty-slot canvas). No second color system.
2. **Library is truth.** A selected name resolves only from a file in the
   Themes folder. `GhosttyThemeCatalog` is the Install source and the
   materialization source, never a runtime fallback for a slot.
3. **Installed means a file in the Themes folder.** The user's computer
   holds default + what they installed or dropped in. We do not copy 485 —
   or 50 — into Application Support on launch.
4. **The picker lists default + library.** The store lists the curated
   50. Command palette matches the picker, not the store. An
   uninstalled store row is not listed in either, so it cannot paint
   chrome and cannot be the `?? 0` seed.
5. **Bounded materialization, not silent fallback.** On first launch after
   this ships, each occupied slot whose name is not yet a file is written
   once from the catalog into the Themes folder. Two files, not 485.
   Existing selections keep working because they become library entries.
6. **Install never clobbers.** If a file in the folder already parses to
   that name, Install refuses and offers Replace, naming the path. Remove
   only deletes a file whose contents match what `write` would emit;
   otherwise confirm, naming the path.
7. **No network.** Install serializes from `GhosttyThemeCatalog`. No
   remote index, no fetch on Settings open, no later `index.json` in this
   RFC.
8. **No backend, no account, no paid themes.**
9. **Settings chrome is out of scope.** Do not paint `SettingsView`.

## Design

### Layers

```
┌─────────────────────────────────────────────────────────┐
│  Store (curated index, names that resolve)              │
│  Browse / Install / Remove                              │
│  Source: GhosttyThemeCatalog.theme(named:) only         │
└──────────────────────────┬──────────────────────────────┘
                           │ Install writes one file
                           │ (refuse if that name exists)
                           ▼
┌─────────────────────────────────────────────────────────┐
│  Library  ~/Library/Application Support/termio/Themes   │
│  + files the user dropped in themselves                 │
│  + at most two materialized slot files on upgrade       │
└──────────────────────────┬──────────────────────────────┘
                           │ selected name → file only
                           ▼
┌─────────────────────────────────────────────────────────┐
│  Default  empty slot → termio canvas                    │
│  (no file; not Alabaster / Afterglow as named themes)   │
└─────────────────────────────────────────────────────────┘
```

Resolve a selected name:

1. A file in the Themes folder (install, hand-drop, or materialization).
2. Empty / unknown → the slot's canvas.

There is no catalog fallback on this path. The warehouse is consulted
only by Install, by materialization, and by Ghostty-inherit (below).

Remove deletes the file and, if that name is the selected slot, writes
`""` into the slot so the canvas shows. Do not leave the old name sitting
in settings hoping a fallback will still paint it.

### Bounded materialization

One-time, on first launch after this ships, before any picker opens:

For each of `lightThemeName` and `darkThemeName`, if the string is
non-empty and `ThemeLibrary` has no file for that name, and
`GhosttyThemeCatalog.theme(named:)` succeeds, `write` that definition
into `directory`. Skip if a file of that name already exists (the user
already has one). Record a flag in the settings store so this does not
run again.

Same write for Ghostty inherit (`Settings.swift`
`ghosttyRegistrationOverrides`): a `theme = X` that is not yet a file is
materialized, then the slot is set. Inherit is not a permanent catalog
lookup at paint time.

After this, every named selection is a library entry. The palette's
`themeItems.firstIndex { … } ?? 0` cannot land on the default row while
the user's theme is still selected — that name is in the list.

### Store catalog

A static list of well-known Ghostty names, partitioned by `isDark`,
filtered at launch so a package rename drops a stale row. A `swift test`
asserts every remaining name resolves against `GhosttyThemeCatalog`.

Locked set — **50 names: 35 dark, 15 light.** Every name resolves against
the pinned `GhosttyThemeCatalog`, and each one's brightness slot is its
own `isDark`, not a hand-assignment.

Four curation rules, in priority order:

1. **Popular, not merely pretty.** A theme earns a row by being one
   people already ask for by name.
2. **No two rows may read as the same theme.** One variant per family —
   the 485 are mostly near duplicates. Distinctness is measured, not
   argued: weighted mean ΔE (CIE Lab) over background ×2.5, foreground
   ×1.2, and ANSI 1–6 ×0.7 each. **Every pair on the list clears ΔE 12.**
   The rejected pairs show why the rule is needed — TokyoNight Night vs
   Storm ΔE 2.6, Atom One Dark vs One Half Dark 3.7, Catppuccin Mocha vs
   Macchiato 4.3, Rose Pine vs Moon 4.8, Monokai Pro vs Ristretto 7.0,
   Dracula vs Snazzy 8.8, GitHub Dark Default vs Dimmed 9.3, Ayu vs Ayu
   Mirage 9.6. Each of those is one row now, not two.
3. **It must hold up for a working day of code.** Body text ≥ 6:1 on the
   background; ANSI red vs green ≥ ΔE 40, because that pair is a diff and
   a test result before it is decoration; every ANSI 1–6 ≥ 2.6:1 on the
   background, so no syntax color disappears.
4. **It must survive `ChromeTheme`.** The selected theme paints the
   sidebar, editor gutter, git pane, and trace, so a theme that derives a
   dead chrome is not elegant here even if it renders well in a bare
   terminal. Checked against the tokens the chrome actually paints
   (below).

Where a family has both a light and a dark member on the list, the two
slots can be set to one identity (Catppuccin Latte over Mocha, GitHub
Light Default over Dark Default, Modus Operandi over Vivendi). Pairing is
a tiebreaker, never a reason to seat a theme that fails rule 3.

**Dark (35).** Dracula, Catppuccin Mocha, TokyoNight Night, Nord, Gruvbox
Dark, Atom One Dark, Monokai Pro, Rose Pine, Ayu Mirage, Night Owl,
Kanagawa Wave, Kanagawa Dragon, Everforest Dark Hard, GitHub Dark
Default, iTerm2 Solarized Dark, Cobalt2, Vesper, Flexoki Dark, Melange
Dark, Xcode Dark, Aura, Dark Modern, Oxocarbon, Gruber Darker,
Jellybeans, Horizon, Embark, Srcery, Terafox, Modus Vivendi, Vercel,
Poimandres, Matte Black, Carbonfox, Sonokai.

**Light (15).** Catppuccin Latte, GitHub Light Default, Rose Pine Dawn,
Gruvbox Light, iTerm2 Solarized Light, Atom One Light, Flexoki Light,
Kanagawa Lotus, Xcode Light, Monokai Pro Light, Iceberg Light, Melange
Light, One Half Light, Modus Operandi, Bluloco Light.

Dropped as unresolved against the pinned catalog: Ayu Dark, One Dark,
Palenight, One Light, Solarized Light, PaperColor Light.

Dropped on rule 3 despite the name recognition: **Ayu Light** (body 5.9,
green/yellow/cyan under 2.6 on its near-white background), **TokyoNight
Day** (body 4.5), **Everforest Light Med** (body 4.7 and all six ANSI
colors under floor). Each of those families still has a dark member on
the list, so the name is not missing from the store — only its washed-out
light variant is.

Alabaster and Afterglow stay off the list for a different reason: they
are the empty slot's canvas, and installing them as named files is not
the same thing.

### What "survives `ChromeTheme`" means

`ChromeTheme` derives four tokens from a definition, and each has a
contrast floor measured where it is actually drawn:

| Token | Where it lands | Floor |
| --- | --- | --- |
| `secondaryForeground` | project labels and icons on `panelBackground` | 3.0 |
| `foreground` over the selected row (`accent` at 22%) | sidebar selection | 4.5 |
| selected row vs `panelBackground` | selection must be visible at all | 1.12 |
| `accent` as link ink on `background` | trace links (`--accent`) | 3.0 |

Scoring the locked 50 against those floors found two derivation bugs that
the picker's old 485-wide dump hid, both fixed in this PR:

- **`secondaryForeground` is `foreground.opacity(0.6)` for both
  brightnesses**, which is too thin over a light panel: Catppuccin Latte
  lands at 2.69, Rose Pine Dawn 2.62, Kanagawa Lotus 2.55. Raising the
  light side to 0.75 clears the floor (3.42 / 3.30 / 3.19) and leaves
  dark themes untouched.
- **`accent` falls back `palette[4] → selectionBackground → foreground`**
  without ever checking contrast, so a theme with a deep ANSI blue paints
  unreadable trace links (Melange Light 2.80, Gruvbox Light 3.73 for a
  link, Cobalt2 2.64). Prefer whichever of `palette[4]` and `palette[12]`
  contrasts the background more: Melange Light 5.71, Gruvbox Light 5.82,
  Cobalt2 3.00.

Two names stay on the list below a floor because low contrast *is* the
theme: iTerm2 Solarized Dark and iTerm2 Solarized Light. They are the
most-recognized scheme in the catalog, and the fix is never to substitute
a different palette behind a name people know. Everything else on the
list clears every floor, with two marginals worth naming — Atom One Dark
and Poimandres sit at 4.0–4.1 for row text over the selection wash,
against a 4.5 target that is only reachable by darkening the wash for
every theme.

Light themes universally miss the ANSI-yellow gate on a near-white
background (Catppuccin Latte, Rose Pine Dawn, Gruvbox Light, Atom One
Light). That is physics, not a curation miss: there is no yellow that
clears 2.6:1 on `#f9f9f9` and still reads as yellow.

### Store UI

A sheet opened from Appearance (**Browse Themes…**), not a fourth
Settings tab. Each row: name, `ThemeSwatch`, Install or Remove.

The sheet does **not** live-apply. It sits over Settings, which sits over
the terminal — preview-on-highlight would recolor a pane the user cannot
see, and writing an uninstalled name into the slot would violate
library-is-truth. Live preview stays in ⌘⇧P, over installed themes only.

Install writes the file, then selects the slot matching the theme's own
`isDark` (not the slot Browse was opened from). Dismiss without Install
changes nothing.

If a file already parses to that name: refuse, offer Replace, name the
path. A file whose contents differ from what `write` would emit shows
**Remove** only — no Reinstall that silently discards edits.

`write` emits Ghostty `key = value` with no filename extension (the
folder already names a theme after the stem). It must
`ensureDirectoryExists()`, and a write failure is surfaced — never
swallowed. `write` then `parse` must round-trip equal; that is a unit
test. `loadUserThemes` dedupes by name with documented precedence
(first file in directory order after a stable sort by path).

### `ThemeLibrary` refactor

- `directory` / `reload()` / `parse` stay. Add `write` (inverse of
  `parse`).
- `installedThemeNames` — files on disk, brightness-filtered for a slot.
- `storeCatalog` — the locked list above, filtered to names that resolve.
- `theme(named:)` — **files only**. No `GhosttyThemeCatalog` fallback.
- Delete `darkBundledThemeNames` / `lightBundledThemeNames` from every
  picker path. Catalog lookup stays private to Install and
  materialization.
- `popularDarkThemeNames` / `popularLightThemeNames` collapse into
  `storeCatalog`.

Callers that walk `GhosttyThemeCatalog.allThemes` for a UI list
(`ThemePickerField.slotBundledNames`, `CommandPalette.themeItems`, iOS
`ThemePickerViewController.all`) switch to `installedThemeNames` plus
the empty default row.

Install / Remove call `ThemeLibrary.reload()` and
`settings.objectWillChange.send()`, and push fresh names into
`AppearanceSettingsTab`'s `@State` — the same pattern as today's Reload
button. The caption **"N custom"** becomes **"N installed"**. Reload
stays, for external edits to the folder.

### Picker and palette

`ThemePickerField` sections, empty query:

1. Terminal default
2. Installed (the Themes folder, slot-brightness only)

Search covers installed names only. Custom-as-a-separate-group goes away.
An empty search for a store name (e.g. "dracula" on a fresh install)
points at **Browse Themes…**, carrying the query.

Footer keeps the mismatch hint. **Browse Themes…** sits next to **Open
Themes Folder…**.

`CommandPalette.themeItems`: default + installed, same-brightness. Add
**Browse Themes…** as a command that opens the sheet — it does not dump
uninstalled names into the palette. After materialization the current
named theme is always in the list, so `?? 0` cannot overwrite it. Still
seed the highlight from the current name, never assume index 0 is
harmless.

### iOS

No store on the phone. `MobileSettings` keeps the literal default names
`Alabaster` / `Afterglow` (the phone has no empty-slot canvas equivalent).
The iOS picker shrinks to those two defaults plus the same store names,
resolved from `GhosttyThemeCatalog` — resolve-only, no files written.
`ThemeBackdrop` stays. Companion-pushed theme files are out of scope.

### Migration

- On first launch: materialize the two occupied slots (and any
  Ghostty-inherit name) as above. Then set the done flag.
- Do **not** copy the store catalog or the 485 into Themes.
- Do **not** delete `GhosttyTheme` from `Package.swift`. Install and
  materialization need it.
- A user who only ever used empty slots sees no new files until they
  Install something.

## What this is not

- A marketplace, an account, or a paid theme.
- A remote fetch, now or later in this RFC.
- 41 original termio-named palettes.
- Settings-window chrome (cut).
- Pushing theme through `termiod` or the companion wire.
- Replacing the native sidebar material.
- A silent catalog fallback that leaves a selected name off the picker
  list (that is how `?? 0` overwrites the theme).

## PR

One PR. Library API and the picker/store switch are not separately
mergeable: tagging `main` between "picker lists installed only" and
"Browse Themes exists" would ship a picker that only contains Terminal
default.

- `ThemeLibrary`: `write`, `installedThemeNames`, `storeCatalog`, file-only
  `theme(named:)`, name dedupe, bounded materialization.
- `ChromeTheme`: brightness-aware `secondaryForeground` (0.6 dark / 0.75
  light) and a contrast-preferring `accent` (`palette[4]` vs
  `palette[12]` against the background).
- Tests: `write` → `parse` equality; every `storeCatalog` name resolves;
  the catalog is 35 dark + 15 light by each theme's own `isDark`; no two
  names in a slot sit closer than ΔE 12; every name clears the chrome and
  code-reading floors except the documented Solarized pair and the
  light-yellow cases.
- Browse Themes sheet + Install / Remove (no live-apply) + Appearance
  button + palette command.
- Picker and palette drop to default + installed in the same change.
- Appearance footer / "N installed" / Reload copy.
- iOS picker: drop "All Themes".
- Docs: `web/landing/content/docs` appearance page + zh-CN restamp
  (`pnpm docs:stamp`, `pnpm docs:check`). New strings get the zh-Hans
  pass on both platforms.

Not in this PR: Settings chrome, authored `chrome.*` keys, a remote
index, companion file sync, light/dark families as one identity.

## Key decisions

| Decision | Why |
| --- | --- |
| Library is truth; file-only resolve | Catalog fallback + picker-lists-installed leaves a ghost selection. Palette `?? 0` then live-applies over it |
| Bounded materialization of the two slots | Upgrade must not reset terminals, and must not copy 485 files |
| Install refuses a same-named file | A hand-dropped `Dracula` is the user's file. Replace is explicit |
| One PR | Picker shrink without the store is an empty picker on `main` |
| No Settings chrome | Cut. Main window already follows the theme |
| No remote fetch | Warehouse is already in the binary. No host, no account |
| Sheet, no live-apply | Sheet cannot preview the terminal; writing an uninstalled name violates library-is-truth |
| Install selects the theme's own `isDark` slot | Installing dark from the Light slot's Browse must not trip the mismatch hint |
| Store names that resolve, tested | Six draft names were missing from the pinned catalog |

## Open questions

None remaining. Sheet (no live-apply), Install-selects (`isDark` slot),
and per-channel Themes folders (`AppChannel.supportDirectory`) are
locked above.
