---
title: PTY size is not the write token
status: done
type: rfc
created: 2026-09-01
updated: 2026-09-01
related:
  - ../bug/agent-tui-focus-report-resize-storm.md
  - 20260730-termiod-session-protocol.md
  - 20260824-ios-as-device-client.md
  - 20260819-unify-server-plane.md
---

# PTY size is not the write token

> termio binds the PTY's size to the write token: whoever types last owns the
> grid. That is tmux's `latest` policy in its most hair-triggered form — moved
> by any byte a client writes, not by a classified keystroke — and it is the
> form that storms. This RFC replaces it: size becomes a session-level policy
> the daemon computes over the attachments that are actually rendering,
> unrelated to who may type.

---

## 0. What prompted this

A focus report read as typing put the write token into a full-speed ping-pong
between a phone and a Mac pane, and the PTY oscillated with it: 6135 token moves
in 30 seconds, the grid alternating 39×38 ↔ 47×42. The measurement, the seven-step
mechanism, and the one-line classifier fix are in
[Agent TUIs shake on the phone](../bug/agent-tui-focus-report-resize-storm.md).

That fix removes the fuel. This document is about the fuel tank.

## 1. Why one unclassified sequence could do that

`TerminalDeviceReport` sorts a client's outgoing bytes into "the person typed"
and "the terminal answered a query". It exists because this class of bug already
happened once — its doc comment names "the resize storm two devices watching one
session used to produce". It was hardened, and the storm came back through a
sequence nobody had enumerated.

A byte-grammar of "what libghostty happens to emit" has to be complete forever,
against an upstream that keeps adding to it. It should not be load-bearing.

What makes it load-bearing is one line in `applyWriter`
(`TermiodClient.swift:1752`, `TermiodSession.swift:327`): on gaining the token,
re-assert this client's grid. Under that rule the classifier is the only thing
standing between an unexpected byte and a full-speed resize loop. **Size is bound
to the write token, so every misclassification is a resize bug.**

## 2. Prior art

Every multiplexer hits this. The answers agree.

| system | policy |
| --- | --- |
| tmux `window-size` | `latest` (default since tmux 3.1; `smallest` before that) — the window takes the size of the client most recently *used*, meaning a classified keystroke, not any byte. `smallest` — the smallest attached client wins; larger clients pad unused space with `·`. `largest` — biggest client wins, smaller clients see part. `manual` — fixed, `resize-window` only. |
| GNU screen | smallest attached client wins; `C-a F` lets one client force the window to its own size, leaving the larger client blank space. |
| Zellij | was smallest-wins; since 0.45.0 / [#5133](https://github.com/zellij-org/zellij/pull/5133) each **tab** is sized from only the clients *currently viewing it*. Clients on different tabs stop constraining each other; unviewed tabs keep their last size. |

Two principles hold across all three.

**Size is a declared session-level policy over the attachment set — never a race
decided by who most recently produced bytes.** tmux's `latest` — its default
since 3.1 — is still such a policy: "most recently used" means a keystroke tmux
classified at the client edge, where it owns the tty and knows ground truth
about what the user typed. That is precisely what termio lacks: its clients'
bytes arrive pre-mixed with their terminals' generated replies, and a byte
grammar (`TerminalDeviceReport`) is the only thing sorting them — so termio
cannot run `latest` safely at all. And even classified perfectly, `latest`
costs a resize barrier — a full repaint of every viewer — each time the active
device alternates, which is the normal phone-and-Mac rhythm here; the complaint
record runs against it (tmux #2243, wezterm #2133 / #2616 chose aggregate
policies over most-recent for the same reason).

**The mismatch is shown, not hidden.** tmux pads with `·`, screen leaves blank,
Zellij clips. Nobody reflows per client. Per-client reflow is the only thing that
would make both ends correct simultaneously, and for termio it is closed by
construction: §A's anti-100× invariant rejects any per-frame grid encoder between
the PTY and the pipe. Don't go looking for it.

## 3. Where termio sits in that vocabulary

termio implements `latest`, in its most reactive form:

- the write token follows input;
- `applyWriter` re-asserts the winner's grid on every grant;
- `applyAuthoritativeGrid` (`TermiodClient.swift:1823`,
  `TermiodSession.swift:334`) has the writer answer any divergence by putting its
  own size back.

So termio implemented `latest` without the client-edge keystroke ground truth
that makes tmux's version merely costly, made it the only policy, and gave it a
trigger surface as wide as "any byte a client writes".

## 4. Proposal

**Separate who may type from who decides the size.**

Single writer, many readers (§H #6) is an *input* invariant and it is correct.
Leave it alone. Size stops riding on it.

The daemon already knows every attachment and its grid — it is the thing that
emits `E resized`. Let it own the policy:

```
size = min(grid of attachments currently rendering the session)
```

with Zellij's refinement: only attachments *actually showing* the session count.
termio already carries that signal on both ends — `setSurfaceVisible` on the Mac
(a hidden pane is not rendering) and the phone having the session on screen.

Consequences:

- Phone opens the session → the PTY goes to 38 columns and the Mac pane renders
  38 columns of content with the rest of its pane blank. **No tearing**, because
  both surfaces sit at the shared grid by construction.
- Phone leaves the session → the Mac springs back to its own width.
- The token moves between the two ends → **the size does not move at all**. A
  misclassified byte costs a stray keystroke, not a resize loop.

This is subtraction:

- `applyWriter`'s grid re-assertion — deleted, both ends.
- `applyAuthoritativeGrid`'s writer-answers-divergence branch — deleted, both
  ends. The observer's `observerRepaintPending` handling stays; it is about
  keyframes, not sizing.
- iOS `layoutTerminalSurface`'s letterbox branch
  (`TerminalViewController.swift:268`) — deleted. Under `smallest` an observer is
  never *narrower* than the PTY, so there is nothing to scale down; blank space
  replaces a scaled surface.
- The Mac's `SharedGridLetterbox` — deleted, by the same argument and one more:
  it shrank the surface to the shared grid, which made this pane's viewport
  declaration *be* the shared grid and pinned the min at the smallest size any
  viewer ever had. The pane's declaration must be its own capacity or the
  session can never grow back.

Small surface area is the point, not a side effect.

## 5. Costs and open questions

**The Mac gets squeezed by the phone.** This is tmux's most-complained-about
default. Zellij's visibility filter is the best known mitigation and it is in the
proposal, but a Mac pane left open on a session the phone is also watching will
sit at 38 columns. Whether that is acceptable, or whether termio needs tmux's
`window-size` as a user-facing option, is the open question. Recommendation: ship
the correct default first; add the option only if the complaint is real.

**Where the policy runs.** The daemon is the only place that sees every
attachment, so it belongs there — which makes this a protocol change touching
`termiod/src/session/`, `TermiodClient`, and iOS `TermiodSession`. `R` stops
meaning "set the PTY size" and starts meaning "this attachment's viewport is now
N×M"; the daemon derives the PTY size from the set. `E resized` is unchanged.

**Attachments that render nothing.** The companion bridge is a byte forwarder
with no surface of its own; its viewport is the phone's. That is already how it
reports, and the protocol doc's §C.5 resize policy now says so explicitly
rather than leaving it implied.

## 6. An adjacent behaviour this makes harmless

Opening a session on the phone forces a Mac-side surface into existence.
`companionAttachment` (`CompanionServer.swift:1206`) ends with:

```swift
if let project = project(for: session.id) { noteProjectActivity(project.id, force: true) }
_ = surface(for: session)
```

Surfacing is deliberate and documented — it is what spawns the agent with its
recorded resume arguments, so the phone gets the conversation instead of "no
terminal". The side effect is that **the phone can never be the only viewer**: a
second attachment at the Mac window's grid always appears.

Under today's `latest` that is a guaranteed size fight, and it is why the phone
tears even when the user only opened the session there. Under §4 it is
uninteresting: the Mac becomes one more attachment, larger, padded. The line
stays as it is. Recorded so the next reader does not mistake it for the bug.

## 7. Proposed sequence

1. Land the classifier fix on its own. It is a misclassification bug with a unit
   test, independent of everything here. Do not hold it for this design work.
2. Verify it against a binary whose pid owns the port — the harness rules are in
   the bug doc, §4.
3. Decide this RFC. It is a protocol change and wants sign-off before code.
   *(Decided and implemented: `R` is a viewport declaration with an optional
   rendering byte, the daemon derives the PTY size per-axis-min over rendering
   attachments, `resize_claim` and both clients' grid re-asserts are deleted,
   and the daemon's session tests cover the min recompute, empty-set
   retention, the reattach barrier keyframe, and token alternation producing
   zero resizes.)*
4. Revisit the residual (generated-reply marking in the libghostty-swift fork)
   afterwards. Once §4 lands it is a correctness nicety, not a load-bearing
   guard.
