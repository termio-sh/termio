---
name: app-screenshot-debug
description: "Drive the running termio app via AppleScript / System Events to reach a UI state (focus the window, click a sidebar project, a terminal pane, a control), capture a pixel-accurate screenshot of just that window, and read it back for visual analysis — for diagnosing layout / spacing / alignment / 'this looks ugly' issues that can't be judged from code alone. Invoke when the user says 'screenshot the app', 'take a screenshot', 'show me what it looks like', 'what does X look like', 'debug this visually', 'verify the UI change', '截图看看', '看看长什么样', '帮我截个图分析'. Pairs with `macos-rebuild-dev` — rebuild first if code changed, then capture."
---

# Screenshot-driven UI debugging (AppleScript + screencapture)

The loop for *seeing* a termio UI change instead of guessing from code:

```
(rebuild if code changed)  →  drive app into the target state  →  capture the window  →  Read the PNG  →  judge / iterate
```

You cannot evaluate spacing, alignment, overlap, ghosting, or "this looks ugly"
from source. Get a real screenshot, Read it, then decide.

## Prerequisites

- The app must be **running** and built. If you just changed code, run the
  `macos-rebuild-dev` skill first. The process name for System Events is
  `termio` and the main window's title is `termio`.
- These calls need macOS **Accessibility** + **Screen Recording** permission for
  the terminal / Claude Code host. If `System Events` errors with `-25211` or the
  capture is black, that permission is missing — tell the user to grant it in
  System Settings → Privacy & Security.
- termio is a single-window app (sidebar + terminal panes); there is **no Settings
  window**. Everything you need is in `window 1`.

## The two helper scripts (in `scripts/`)

Run them with bash; they take the app name from `$TERMIO_APP_NAME` (default
`termio`).

1. **`capture-window.sh [out.png]`** — screenshot *just* the frontmost termio
   window (`-o` no shadow, `-x` silent), reading its live bounds first. Prints the
   window origin + size. Captures the region 1:1 in points, so **a point you read
   off the resulting image is window-relative**: image (dx,dy) == screen
   (originX+dx, originY+dy).

2. **`click-in-window.sh <dx> <dy>`** — click at a **window-relative** point: it
   re-reads the live window origin and adds your offset. Use the exact (dx,dy) you
   measured on a `capture-window.sh` image — this survives the window moving or
   reopening on a different display.

## Canonical recipe

```bash
SK=skills/app-screenshot-debug/scripts

osascript -e 'tell application "System Events" to tell process "termio" to set frontmost to true'
bash $SK/capture-window.sh /tmp/shot.png
# → Read /tmp/shot.png with the Read tool, find the control you want at (dx,dy)
bash $SK/click-in-window.sh 120 180   # e.g. click a sidebar project row
bash $SK/capture-window.sh /tmp/shot2.png   # Read again to see the result
```

Then **Read** each PNG to analyze. Capture before *and* after a change for an
honest before/after.

## Driving the UI — patterns that actually work

- **Focus the window:** `tell application "System Events" to tell process "termio" to set frontmost to true`
  (or `tell application "termio" to activate`).
- **Click a control:** prefer `click-in-window.sh` with coords read off the
  screenshot. `click at {x,y}` (global points) conveniently **returns the AX
  element path it hit** — use that to confirm you hit the right thing.
- **Get window bounds live:** `get position of window 1` / `get size of window 1`.
- **Type into the focused terminal:** `keystroke "ls\n"` after the window is
  frontmost — useful to put the terminal surface into a known state before
  capturing.

## Gotchas (learned the hard way)

- **Never hardcode window coordinates across calls.** The window can reopen at a
  different origin or on another display. Always re-read bounds (the scripts do) —
  that's the whole reason `click-in-window.sh` exists.
- **`screencapture -R x,y,w,h` uses the same global point coords** as System
  Events, mapping points→pixels 1:1 for the width you ask for, so window-relative
  math is trivial: `dx = screenX - originX`.
- **Always `-o` (no shadow) and `-x` (silent)** so the crop is exact and there's
  no shutter sound.
- **Add a `sleep`** (~0.8–1.2s) after navigation/clicks before capturing so the
  animation settles — otherwise you screenshot a mid-transition frame.
- The terminal surface is a libghostty-rendered view, mostly opaque to AX — drive
  it by **focusing + keystrokes**, and judge it from the **screenshot**, not the AX
  tree.
- Save shots under `/tmp/<task>/…png` and Read them; don't leave them in the repo.
