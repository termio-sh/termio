---
title: PTY size is not the write token
status: active
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

> termio bound the PTY's size to the write token: whoever typed last owned the
> grid. That is tmux's `latest` policy, which tmux ships as an option and not as
> the default, because it thrashes. This replaces it — size is a session-level
> policy the daemon computes over the attachments that are actually rendering,
> unrelated to who may type.
>
> §1–§4 are the argument, written before the code. §5 settles what §4 left open,
> §6 records where §4 was wrong, and §10 says what the tests hold.

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

What makes it load-bearing is one line in `applyWriter`, on both ends: on
gaining the token, re-assert this client's grid. Under that rule the classifier is the only thing
standing between an unexpected byte and a full-speed resize loop. **Size is bound
to the write token, so every misclassification is a resize bug.**

## 2. Prior art

Every multiplexer hits this. The answers agree.

| system | policy |
| --- | --- |
| tmux `window-size` | `smallest` (default) — window takes the smallest attached client; larger clients pad unused space with `·`. `largest` — biggest client wins, smaller clients see part. `latest` — the client most recently *used*, e.g. typed into. `manual` — fixed, `resize-window` only. |
| GNU screen | smallest attached client wins; `C-a F` lets one client force the window to its own size, leaving the larger client blank space. |
| Zellij | was smallest-wins; since 0.45.0 / [#5133](https://github.com/zellij-org/zellij/pull/5133) each **tab** is sized from only the clients *currently viewing it*. Clients on different tabs stop constraining each other; unviewed tabs keep their last size. |

Two principles hold across all three.

**Size is a declared session-level policy over the attachment set — never a race
decided by who most recently produced bytes.** tmux does ship a
most-recently-used policy, `latest`. It is an option, and it is not the default.

**The mismatch is shown, not hidden.** tmux pads with `·`, screen leaves blank,
Zellij clips. Nobody reflows per client. Per-client reflow is the only thing that
would make both ends correct simultaneously, and for termio it is closed by
construction: §A's anti-100× invariant rejects any per-frame grid encoder between
the PTY and the pipe. Don't go looking for it.

## 3. Where termio sits in that vocabulary

termio implemented `latest`, in its most reactive form:

- the write token follows input;
- `applyWriter` re-asserted the winner's grid on every grant;
- `applyAuthoritativeGrid` had the writer answer any divergence by putting its
  own size back.

So termio chose the one policy that oscillates, made it the only policy, and gave
it a trigger surface as wide as "any byte a client writes".

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
  ends. The observer's repaint handling stays; it is about keyframes, not sizing.
- iOS `layoutTerminalSurface`'s letterbox branch — deleted. Under `smallest` an
  observer is never *narrower* than the PTY, so there is nothing to scale down;
  blank space replaces a scaled surface.

Small surface area is the point, not a side effect.

*Mostly true. It is subtraction on the wire and in the daemon; on the Mac one
thing had to be added, and §6.1 is why.*

## 5. What the wire says

Decided while building; §4 left these open.

### 5.1 `R` grew one optional byte

```
R payload: rows u16be, cols u16be, [flags u8]
           flags bit 0 (0x01) = this attachment is rendering
```

A **rendering** attachment writes v0's exact four bytes. The fifth byte exists
only to say *not* rendering, so the only payload an old host cannot read is the
one it has no policy for anyway. That matters because an old host does not
ignore a payload of the wrong length — `read_frame` fails the frame and the
connection dies — so the five-byte form is gated on the host advertising a new
capability, `viewport`.

Zero in either dimension means **no viewport at all**: a window that has not
laid out yet. It is counted by nobody. This is not the same state as "has a
viewport, is not showing it", and keeping the two apart earns its byte: a hidden
pane keeps its size and gets it back the moment it is shown, while a window with
no size yet has nothing to get back. The same rule applies to `attach`'s
`rows`/`cols`, which are now that attachment's opening declaration rather than
an instruction to resize — the phone used to send a 24×80 stand-in there when
its surface had not measured itself, and under smallest-wins that stand-in would
squeeze every other viewer until the first layout pass landed.

**Alternative rejected:** overloading `0×0` to mean "not rendering". It needs no
new byte and no capability, and it is exactly the kind of implied meaning §5's
last paragraph complains about. Two facts, two fields.

### 5.2 Nobody rendering keeps the last size

Zellij's rule for unviewed tabs, and for the same reason: a session every viewer
walked away from should come back looking the way they left it, not reflowed by
a policy that had no inputs. `apply_size_policy` returns early when the set is
empty; the PTY, the VT, and the ring stay where they were.

### 5.3 Only interactive attachments count

An observer attaches without a tty. §A already says it never holds the write
token; the sizing half is the same fact — there is no screen behind it that a
viewport could be about. So `termio read` tailing a session cannot squeeze the
window somebody is working in. A read-only *renderer*, if one is ever built,
attaches `interact` and simply never types.

### 5.4 The companion bridge speaks for the phone

The bridge is a byte forwarder with no surface. It declares no viewport of its
own — a stand-in grid there would size the session for a screen nobody is
looking at — and the phone's `{"t":"resize"}` is where it borrows one. That
message grew an optional `rendering` field (absent = showing, which is what
every phone built before it means by sending a grid at all), so a phone that
navigates away from a parked session stops counting on the daemon.

The Mac forwards the phone's declaration as both its bridge attachment's
viewport *and* its surface grid. That second one is not a redundancy: the phone
fills its screen and never letterboxes, so the two really are the same number
there, and the repaint arming has no local surface to hear it from.

## 6. What the RFC got wrong

Found in the code, not in the reading. Recorded in the order they bite.

### 6.1 Deleting `applyWriter`'s re-assertion deadlocks the Mac unless the pane learns to measure itself

§4 says the deletions are subtraction. One of them is not.

The Mac pane letterboxes: a surface showing a session smaller than the pane is
laid out at the *session's* grid, with the rest of the pane blank. libghostty
then reports that grid — a surface's viewport is its frame — and that report is
what used to travel to the daemon as `R`.

Today that is survivable because the letterbox lifts when the token comes back:
the surface returns to the pane, reports the pane's grid, and the session grows.
`applyWriter`'s re-assertion is the other half of the same crutch. Delete both
and a pane that has once been letterboxed can only ever declare the grid it was
shrunk to. **The session can never grow back.** A phone that opens a session
once holds a 200-column Mac pane at 47 columns forever, and no user action
recovers it.

So the Mac had to gain something: the pane now measures its viewport from its
own geometry — `floor((paneSize − 2·padding) / cell)`, libghostty's own
arithmetic — and the surface's report is demoted to a separate, never-sent fact
(`noteSurfaceGrid`) that only arms the repaint. Two quantities that were one:
*how much this pane could show*, which is what the daemon sizes by, and *what
the surface is laid out at*, which is what the letterbox sets.

The same trap exists on any client that lays its surface out at the shared grid.
It does not exist on the phone, because §4's other deletion removes the phone's
letterbox entirely.

### 6.2 The Mac letterbox is not keyed on the write token any more

§4 leaves `SharedGridLetterbox` alone, and it needed one change: it was gated on
`!runtime.isWriter`. Under a size policy the pane holding the token is
letterboxed too, whenever somebody smaller is looking. It now keys on the only
thing that matters — whether the shared grid differs from what this pane could
show.

### 6.3 "Delete the iOS letterbox branch" means delete the *scale*, not the sizing

§4's wording ("blank space replaces a scaled surface") is the right instruction
read one way and a bug read the other. What is genuinely gone is
`CGAffineTransform(scaleX: fit)`: under smallest-wins no renderer is ever
narrower than the PTY, so there is never anything to scale *down*.

The implementation goes further and drops the shared-grid sizing on iOS too, so
the phone simply fills its screen. That is a deliberate asymmetry with the Mac,
and the reason is the size ratio, not principle. The residual: if a Mac pane is
ever narrower than the phone, the phone shows a screen wrapped at the Mac's
width inside a wider surface. Widening does not re-wrap rows that are already
drawn — the damage §C.5 is about is *narrowing* — so what is left is a program
that thinks it has fewer columns than the surface has, which reads as a narrow
column of output rather than a scrambled one. Against a 47-column phone and a
200-column pane that case does not arise; the Mac keeps its letterbox because
for the Mac it is the common case, not the corner.

### 6.4 Dropping a stale keyframe stops being safe

Not mentioned in §4 at all. Both clients drop an arriving `S` whose grid is not
the one the surface is laid out at — but only when they hold the write token,
because a writer's own in-flight resize guarantees another keyframe behind it.

Under a size policy **no client can make that promise**. This pane's viewport
changing may move the session or may not, depending on who else is looking. A
client that dropped a keyframe on that reasoning could sit blank forever. So the
drop is gone on both ends and every keyframe is painted; the one mangled frame
after a barrier is repaired by the mechanism that already existed for observers
(`repaintPending` → `request_snapshot` once the surface reaches the shared grid).
`TermiodKeyframeGridTests` went with it.

### 6.5 §6's "the line stays as it is" is right, and now for a second reason

`companionAttachment`'s `_ = surface(for: session)` is uninteresting under §4, as
predicted. It is *doubly* uninteresting with Zellij's refinement in: the Mac
surface it forces into existence belongs to a pane that is not on screen, so it
is not rendering and does not enter the min at all.

## 7. Costs and open questions

**The Mac gets squeezed by the phone.** This is tmux's most-complained-about
default. Zellij's visibility filter is the best known mitigation and it is in the
proposal, but a Mac pane left open on a session the phone is also watching will
sit at 38 columns. Whether that is acceptable, or whether termio needs tmux's
`window-size` as a user-facing option, is the open question. Recommendation: ship
the correct default first; add the option only if the complaint is real.

**Where the policy runs.** Settled: the daemon, in
`Session::apply_size_policy`, called from every change to the attachment set —
an arrival, a departure, a viewport, a pane going to a background tab. It is the
only thing in termiod that resizes a session. `R` and the companion `resize`
carry viewports (§5); `E resized` is unchanged.

**Attachments that render nothing.** Settled in §5.4.

**One piece of dead weight left behind.** With the phone's letterbox gone,
nothing on iOS reads `onSharedGrid` — the phone knows the authoritative grid and
has nothing to do with it. The consumption is deleted; the plane itself
(`DeviceSession.onSharedGrid`, the companion `grid` message, the Mac's
`publishGrid`) is still there and is the next thing to cut if no read-only cue
ever wants it.

## 8. An adjacent behaviour this makes harmless

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

## 9. Sequence

1. Land the classifier fix on its own. It is a misclassification bug with a unit
   test, independent of everything here. Do not hold it for this design work.
   *(Separate branch; unaffected by this one.)*
2. Verify it against a binary whose pid owns the port — the harness rules are in
   the bug doc, §4.
3. ~~Decide this RFC.~~ Built, on `feat/size-over-rendering-attachments`.
4. Revisit the residual (generated-reply marking in the libghostty-swift fork)
   afterwards. It is now a correctness nicety, not a load-bearing guard: a
   misclassified byte costs a stray keystroke, and the size does not move.

## 10. What the tests hold

- `termiod/src/session.rs` — the policy itself: smallest wins; rows and columns
  minimised independently; a hidden attachment stops counting and starts again;
  nobody rendering leaves the size alone; a viewport of zero counts for nobody;
  an observer never sizes anything. Plus the one that had to change shape: a
  failed `TIOCSWINSZ` now tells nobody, because there is no requester to answer.
- `Tests/termioTests/TermiodSizePolicyIntegrationTests.swift` — two real Swift
  attachments against a real daemon: the session is the smaller of the two, and
  **typing on either end does not move it**. That last assertion is the whole
  RFC, and it was false before this branch.
- `Tests/termioTests/TermiodWriteTokenIntegrationTests.swift` — unchanged, and
  that is the point: §H #6 is an input invariant and this did not touch it.
- `Tests/termioTests/TermiodViewportFrameTests.swift` — the `R` payload's
  layout, which is the whole compatibility story.
