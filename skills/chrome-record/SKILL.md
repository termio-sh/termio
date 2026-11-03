---
name: chrome-record
description: "Drive Google Chrome from the shell — open a URL, click and inspect the page through JavaScript — and record what happens as a sequence of frames assembled into a GIF, for showing an interaction rather than a moment: a flow that breaks halfway, a hover or transition, a before/after of a UI change, a repro to attach to an issue. Has a headless path that needs no screen-recording permission and renders deterministic frames, and a live path that records the real window and the user's logged-in session. Invoke when the user says 'record the browser', 'make a GIF of this flow', 'show me what happens when you click', 'screenshot the web page', 'record Chrome', '录个屏', '把这个流程录成 GIF', '截图看看网页'. Pairs with app-screenshot-debug, which does the same for the termio app itself."
---

# Recording Chrome as frames → GIF

A still screenshot shows a state. Most browser questions are about a
*transition* — what happens between the click and the result — and a GIF is the
shortest way to answer one, for you and for the human reading the issue.

There are two capture paths. **Try headless first**: it needs no permissions at
all, so it works on a machine where the live path is blocked.

| | headless | live |
|---|---|---|
| capture | `chrome-frames-headless.sh` | `chrome-snap.sh` / `chrome-burst.sh` |
| permission | **none** | Screen Recording |
| driving | URL only | `chrome-js.sh`, `chrome-click.sh` |
| sees | the page, its own fresh profile | the real window, the user's session |
| repeatable | byte-identical across runs | never |

Use **headless** for page load, CSS animation, a layout at a given width, or a
before/after of two URLs. Use **live** when the recording needs the user's
logged-in session, something behind a click, or Chrome's own UI.

Both write `frame-NNNN.png` into the same session directory and both feed
`chrome-gif.sh`, so a recording can mix them and can span several turns.

## Headless — no permission needed

```bash
S=skills/chrome-record/scripts
SESSION=/tmp/rec-$(date +%s)

"$S/chrome-frames-headless.sh" "http://localhost:3000/page" "$SESSION" 8 250 900 600
"$S/chrome-gif.sh" "$SESSION" "$SESSION/recording.gif" 6
```

Frames are rendered at successive **virtual times** (`--virtual-time-budget`),
not wall-clock, so the same URL yields the same frames every run.

Two things to know, both measured here:

- **Chrome writes the PNG and then does not exit.** The script polls for the
  file to stop growing and kills it — ~1.5s per frame instead of ~15s. Don't
  "fix" it by waiting on the process.
- **Virtual time does not sample every animation evenly.** It advances while the
  page has work pending, then stalls, so a long CSS animation can come back as a
  few repeated stills. The script counts distinct frames and says so
  (`only 4 of 8 frames differ`). When you see that, either widen the step or
  record that motion live.

## Live — prerequisites, both one-time human grants

You cannot grant either from a shell. Check them before promising a recording;
when one is missing, tell the user exactly what to click.

1. **Screen Recording** for the app running this shell: System Settings →
   Privacy & Security → Screen Recording. **The app must be restarted
   afterwards** — the grant does not apply to a running process. Probe with
   `screencapture -x /tmp/probe.png`; without it every capture fails with
   `could not create image from rect`, and `chrome-snap.sh` says so rather than
   producing a black GIF.

   **Grant it to the app, not to the helper.** Inside termio the shell's parent
   is `termiod`, which is signed as its own identifier and launched by launchd —
   but TCC still attributes the request to the GUI app. Confirm rather than
   guess, by reading what TCC actually recorded:

   ```bash
   screencapture -x /tmp/probe.png
   log show --last 30s --style compact \
     --predicate 'subsystem == "com.apple.TCC"' | grep AUTHREQ_ATTRIBUTION | tail -1
   ```

   The `responsible=` field names the row to tick — observed here as
   `identifier=sh.termio.app`, `responsible_path=/Applications/termio.app/…`.
   If that line ends in **`The user declined TCCs`**, the permission was denied
   once and macOS will never prompt again: toggling it on in System Settings is
   the only fix (or `tccutil reset ScreenCapture sh.termio.app`, which also
   clears any grant the app already has — ask before running it).
2. **Chrome → View → Developer → Allow JavaScript from Apple Events**, for
   `chrome-js.sh`. Without it Chrome refuses with `-1743`. Everything else —
   opening URLs, reading the window rect, capturing, clicking — works without
   it.

Accessibility permission is also needed (the same grant `app-screenshot-debug`
uses) and is usually already in place.

## The live loop

```bash
S=skills/chrome-record/scripts
SESSION=/tmp/rec-$(date +%s)

"$S/chrome-open.sh" "http://localhost:3000/some/page"   # prints: X Y W H
"$S/chrome-snap.sh" "$SESSION" "before"

"$S/chrome-js.sh" 'document.querySelector("#save").click()'
"$S/chrome-snap.sh" "$SESSION" "after save"

"$S/chrome-gif.sh" "$SESSION"                            # → $SESSION/recording.gif
```

Then **Read the GIF or a frame** and judge it. An assembled GIF is not evidence
that the flow worked — it is evidence of what the screen did, which you still
have to look at.

## Choosing how to drive the page

- **`chrome-js.sh` first.** `document.querySelector('#save').click()` survives a
  layout shift and cannot miss. It also *reads*: return a string and the script
  prints it, so you can assert state between frames instead of eyeballing every
  one.
- **`chrome-click.sh <dx> <dy>` only for what the DOM cannot reach** — Chrome's
  own toolbar, a native dialog, an extension popup. Coordinates are
  window-relative, exactly as measured off a frame, and are re-based against the
  live window origin on every call.

## Frames vs a burst

- **`chrome-snap.sh` — one frame per call, in call order.** The default. You
  act, you snap; no timer can race the page into the wrong state.
- **`chrome-burst.sh <session> <seconds> [fps]` — frames on a timer.** For
  motion nothing drives: a CSS animation, a spinner, a video. Run it with `&` to
  record while you keep driving; both write into the same session.

## Pitfalls

- **The window rect is read live on every call**, so a window moved mid-session
  does not silently capture the wrong region. It does make the GIF jump — don't
  move or resize the window while recording.
- **A resized window produces mixed frame sizes.** `chrome-gif.sh` handles it by
  normalizing every frame to the first frame's shape (fit + letterbox). This is
  worth knowing because the underlying failure is unhelpful: ffmpeg's image
  reader dies with `Internal bug, should not have happened`, not a size error,
  and a `scale` filter does NOT fix it — the break is upstream of the filter.
- **`chrome-open.sh` reuses window 1** rather than opening a new one, to keep
  geometry stable. Window 1 is Chrome's *frontmost* window, so it takes over
  whatever the user was looking at. When their session matters, make a new
  window first (`osascript -e 'tell application "Google Chrome" to make new
  window'`) and close it when done.
- **GIF size grows fast.** 6 frames at 900px ≈ 260KB. Drop `--width` (4th arg)
  or the fps for a long flow before attaching it anywhere.
- This ffmpeg build has **no `drawtext`** (no freetype) — don't try to burn
  captions into frames.
