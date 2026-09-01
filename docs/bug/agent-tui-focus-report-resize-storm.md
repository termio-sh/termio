---
title: Agent TUIs shake on the phone — focus reports claim the write token
status: active
type: bug
created: 2026-09-01
updated: 2026-09-01
related:
  - ../design/20260901-pty-size-is-not-the-write-token.md
  - ../design/20260730-termiod-session-protocol.md
---

# Agent TUIs shake on the phone — focus reports claim the write token

> Opening Claude Code, Codex, or pi on the phone makes the screen flicker and
> jitter as if it were being resized continuously. A plain shell never does. The
> trigger is three bytes — `ESC [ I` — that `TerminalDeviceReport` did not
> recognise, so a terminal-generated focus report was read as typing and took
> the write token. The fix is in the tree; it is **not yet verified end to end**
> (§4).

**Reported:** 2026-08-31, iOS companion against a Mac with the same session open
in a pane.
**Symptoms:** high-frequency flicker; the screen visibly re-laying-out; garbled
text with characters stranded in the right margin.

---

## 1. Measurement

`log stream --predicate 'subsystem BEGINSWITH "sh.termio"'` over 30 seconds of
shaking:

| signal | count |
| --- | --- |
| `write token on <session> claimed` | 6135 |
| `write token on <session> lost` | 6135 |
| `PTY is now 39x38; this client renders 47x42` | 1904 |
| `PTY is now 47x42; this client renders 39x38` | 1903 |
| `daemon error: this attachment does not own the write token` | present |

Sub-millisecond cadence, sustained. Both attachments live in the Mac process
(the pane's `TermiodClient` and the companion bridge's), so one log shows both
halves of the loop.

Two distinct user-visible damages, one cause:

- The oscillation itself reads as flicker.
- Every keyframe landing while `isWriter` is mid-flip is painted at the wrong
  width. That is §C.5 divergence: wrapped rows shift, an incrementally
  redrawing TUI never repairs them, and the phone shows a screen with stranded
  characters in the right margin.

## 2. Mechanism

Seven steps, each verified against source.

1. Claude Code, Codex, and pi all enable focus reporting, `CSI ? 1004 h`.
   pi's is explicit in `pi-tui/dist/tui-alt-screen.js`:
   `ENABLE_BUTTON_MOTION_MOUSE = "\x1b[?1000h\x1b[?1002h\x1b[?1004h\x1b[?1006h"`.
   A login shell never sets it — **that is why only agent TUIs shake**.
2. The daemon's snapshot formatter runs with `with_modes(true)`
   (`termiod/vt/src/lib.rs:287`), so every keyframe replays `?1004h`.
3. ghostty answers a focus-reporting *enable* by writing a focus report
   immediately, unasked — `termio/stream_handler.zig`:
   `.focus_event => if (enabled) self.messageWriter(.{ .focused = ... })`,
   with bytes from `terminal/focus.zig`: `.gained => "\x1B[I"`,
   `.lost => "\x1B[O"`.
4. `TerminalDeviceReport.isReport` did not recognise those three bytes. A CSI
   whose final byte is `I` or `O` fell through to `default: return false`, so
   the reply was classified as **typing**.
5. Typing claims the write token (`TermiodClient.send`).
6. `applyWriter` re-asserts the new writer's grid
   (`TermiodClient.swift:1779`, `TermiodSession.swift:327`). That is a resize,
   which is a host-side barrier, which pushes a fresh keyframe **to every
   attachment**.
7. Go to 3, at the other client.

Nothing here is probabilistic. The loop runs as fast as the IO threads carry it.

## 3. Fix

`Shared/Sources/TermioShared/TerminalDeviceReport.swift:92` classifies the bare
three-byte `ESC [ I` / `ESC [ O` as a device report:

```swift
case 0x49, 0x4F: // I O
    // A focus report carries nothing between the introducer and
    // its final byte, and no key encodes to those three bytes.
    return index == 2
```

One classifier, three call sites — the Mac pane
(`TermioStore+TerminalSurface.swift:295`), the companion bridge
(`CompanionServer.swift:1091`), and iOS
(`TerminalViewController.swift:763`) — so one edit covers every path.
Parameterised forms (`ESC [ 2 I`) stay input; no key encodes to the bare form.
`swift build` and `TerminalDeviceReportTests` pass, with assertions both ways.

The mode-enable audit found no second gap: `?2048` in-band size reports end in
`t`, `?998` visibility reports end in `n`, and both are already classified. The
broader generated-write audit did find kitty graphics and glyph APC replies plus
kitty clipboard `OSC 5522` status replies; they are now classified too. An
unsolicited kitty paste event has the same status shape but carries `:pw=`; it
stays input so an observer's Paste action is never swallowed.

**Residual, not fixed.** The writer still emits a spurious focus-in on every
keyframe, because a replayed mode is indistinguishable from the host setting it.
It no longer storms, but the agent is told the window regained focus on every
resize. The real answer is the wrapper hook that marks generated replies at the
write callback, in the libghostty-swift fork — `TerminalDeviceReport`'s own doc
comment already names it.

## 4. Verification status — NOT DONE

Three attempts to reproduce against a patched binary all measured an unpatched
one instead. Each was defeated by the harness, not the code:

1. The phone was paired to the release app; the patch was in the dev app. Every
   log line came from the unpatched binary.
2. The dev channel was in direct-attach mode (`companion.directAttach = 1`,
   `DeviceSpliceServer` on 8796, not companion on 8788) — a different code path
   from the one the storm was measured on — and its `tunnelProvider = off`, so
   the phone could not reach it off-LAN.
3. Two dev builds were running from different worktrees. They share a bundle id,
   a state dir, and a daemon, so port 8788 went to whichever launched first —
   the unpatched one. A launch-time benchmark in another worktree kept
   relaunching it.

**Rule this earns: a dev-channel measurement is invalid until you have proved
which binary owns the port.** Run
`lsof -nP -iTCP -sTCP:LISTEN | grep termio`, match the pid to a bundle path with
`ps -axo pid,args`, and only then trust a log line.

A valid run needs all of:

- exactly one dev app alive, and it owns 8788
- `companion.directAttach = 0` (companion shape, matching where the storm was
  measured)
- the phone paired to *that* app and reachable (same LAN, or a tunnel on)
- an agent session created in that app
- a Mac pane left open on the same session (the storm needs two attachments)

Pass condition is absolute: **zero** `write token … claimed` lines for that pid.

## 5. Why one sequence could do this

`TerminalDeviceReport` exists because this class of bug already happened once —
its doc comment names "the resize storm two devices watching one session used to
produce". The classifier was hardened, the storm returned through a sequence
nobody had enumerated, and it will return again through the next one.

A byte-grammar of "what libghostty happens to emit" has to be complete forever,
against an upstream that keeps adding to it. It is the wrong place to be
load-bearing — and it is load-bearing only because step 6 exists: the PTY's size
is bound to the write token, so **every misclassification is a resize bug**.

That is a design problem, not a bug, and it is argued separately in
[PTY size is not the write token](../design/20260901-pty-size-is-not-the-write-token.md).
This fix should land on its own without waiting for it.
