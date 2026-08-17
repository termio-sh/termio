---
title: Fork libghostty-spm — own the wrapper, rent the engine?
status: draft
type: rfc
created: 2026-07-03
updated: 2026-07-03
---

# Fork libghostty-spm — own the wrapper, rent the engine?

> Decide how much of Termio's core terminal dependency we should own: keep
> depending on Lakr233/libghostty-spm as-is, soft-fork its Swift wrapper,
> or hard-fork down to building GhosttyKit ourselves.

## Problem

Termio's product **is** the terminal. Both apps render every session through
`Lakr233/libghostty-spm` (currently pinned `from: 1.2.8`):

- macOS: host-managed PTY (`PTYProcess`) feeding the `.inMemory` backend.
- iOS: the same `.inMemory` backend fed by the companion WebSocket bridge.

We have now hit **four production-grade bugs in a few weeks**, and every one of
them lives in the dependency, not in Termio:

| date | bug | layer | our workaround |
| --- | --- | --- | --- |
| ~06-27 | OpenCode renders blank (reply-gated queries never answered without a continuous tick) | Swift wrapper (tick scheduling) | warm-up tick pump in `TermioStore.warmUpRendering` |
| ~07-02 | Engine crashes on surface teardown when switching sessions fast | Swift wrapper (lifecycle) | keep-alive LRU of session screens in `RootContainerViewController` |
| earlier | Hardcoded link-open delegate, no link-regex API | Swift wrapper (API surface) | `@retroactive` conformance + Notification hack |
| 07-03 | **App-wide freeze**: `InMemoryTerminalSession.receive` holds the session lock across a blocking `ghostty_surface_write_buffer` while the io thread's resize ack wants the same lock → three-thread deadlock | Swift wrapper (locking) | ration + debounce `fitToSize` (shrinks the window, cannot close it) |

The pattern: our velocity on the core product is increasingly spent writing
*workarounds around* a dependency instead of *fixes inside* it. The freeze is
the sharpest example — the correct fix is one line of lock hygiene (release
the lock before the blocking C call), and we cannot apply it.

## Anatomy of the dependency

The package is two layers with very different ownership costs:

1. **GhosttyKit** — a prebuilt XCFramework (Zig, compiled from ghostty
   upstream, currently v1.3.1) attached to `storage.1.2.x` GitHub releases.
   Building it requires the Zig toolchain, the ghostty source tree,
   iOS+macOS cross-compilation, and CI. High cost to own.
2. **The Swift wrapper** — `GhosttyTerminal` (surface coordinator,
   `InMemoryTerminalSession`, UIKit/AppKit views), `GhosttyTheme`,
   `ShellCraftKit`. Plain Swift. Trivial to patch, small diff surface.

**All four bugs are in layer 2.** Nothing that has hurt us so far required
touching the Zig binary.

Upstream context worth weighing:

- Lakr233 is *active* (1.2.4 → 1.2.8 in three weeks) and the package is MIT —
  friendly to both PRs and forks, and license-compatible with open-sourcing
  Termio.
- ghostty's own libghostty is still officially "unstable / unsupported"; this
  third-party wrapper exists precisely because there is no blessed
  distribution. That could change — if ghostty ever ships an official
  libghostty release, any fork we hold today becomes a bridge, not a home.
- The binary storage releases are the single supply-chain thread: if those
  release assets ever disappear, every build breaks, fork or no fork.

## Options

### A. Status quo — file issues upstream, keep working around

- **Cost:** zero setup; ongoing cost is each future workaround (the LRU cache,
  the tick pump, the resize debounce are each real complexity we now carry
  *in product code* to route around wrapper internals).
- **Risk:** fix latency is someone else's weekend. The freeze mitigation is
  probabilistic — a heavy output burst racing a real resize can still hang
  the app. For a paid product, "the app can freeze and we can't fix it" is
  the unacceptable sentence.

### B. Soft fork — own the Swift wrapper, rent the binary (recommended so far)

Fork `libghostty-spm`; its `Package.swift` keeps pointing at upstream's
`storage.1.2.x` XCFramework, so we inherit the Zig builds for free. Repoint
Termio's two references (root `Package.swift`, iOS pbxproj) at the fork.

- **Patch set, day one:** (1) the deadlock fix in `receive()`; (2) teardown
  hardening so the LRU cache becomes an optimization instead of a
  crash-avoidance requirement; (3) a real link-delegate hook to retire the
  `@retroactive` hack.
- **Steady state:** rebase a ~3-file diff when bumping upstream versions.
  PR every patch upstream — each merge shrinks the fork toward a no-op.
- **Hedge:** mirror the XCFramework zip onto our fork's release when pinning
  a version, so the supply-chain thread has a second anchor.
- **Cost:** an afternoon of setup; near-zero maintenance while upstream stays
  active. Slightly slower upgrades (rebase + retest).

### C. Hard fork — build GhosttyKit from ghostty source ourselves

- **Unlocks the C-API wishlist**, which the soft fork cannot touch:
  - a terminal-core **buffer read API** — the sessions CLI's `read` op is
    stubbed today ("needs a terminal-core buffer API"); this is a real
    product feature waiting on it;
  - link-regex / OSC hooks at the core level;
  - anything the collab/multi-human direction eventually needs from the VT
    layer.
- **Cost:** Zig toolchain + ghostty build maintenance + tracking ghostty
  releases + XCFramework CI. A standing tax on a solo-maintained product,
  paid monthly whether or not we need it that month.
- **Risk:** we become a de-facto libghostty distributor right before upstream
  possibly ships an official one.

### D. Vendor the wrapper into the Termio repo (copy, not fork)

Copy the Swift sources under `Vendor/` and drop the package. Maximum control,
no upstream sync path — every future upstream improvement must be hand-ported.
Mentioned for completeness; it trades a rebase-able diff for a permanent
divergence. Worse than B on every axis except "no GitHub fork to run".

## Decision drivers to sit with

1. **How often do we expect to need same-day fixes?** Four incidents in three
   weeks during active iOS development; likely fewer once the surface
   stabilizes. If the answer trends to "rarely", A+PRs may suffice; the last
   three weeks argue otherwise.
2. **When does the buffer-read API become commercially real?** That is the
   first genuine hard-fork trigger. If `sessions read` / richer status
   detection is on the 1–2 month roadmap, C stops being over-engineering and
   becomes the plan; B is then a stepping stone, not a destination.
3. **What does open-sourcing Termio change?** A fork is *more* legible to OSS
   users than a pile of workarounds in app code (they can see exactly what we
   changed and why). MIT both ways; no license friction either direction.
4. **Upstream's trajectory.** If Lakr233 merges our PRs promptly, the fork's
   diff trends to zero and B costs nothing; if the repo goes quiet, B was the
   right hedge and C's calculus improves.

## Current lean

B now — it converts three shipped workarounds into three upstream-shaped
patches and makes the freeze actually fixable — while treating C as a
*deferred decision with a named trigger* (the buffer-read API), not a rejected
one. Revisit when that trigger fires or when upstream ships an official
libghostty.

## Open questions

- Fork under the personal account or a Termio org (matters for OSS optics)?
- Do we pin exact versions (`.exact`) in Termio once on a fork, to make every
  upgrade a deliberate rebase?
- Should the deadlock fix land as a PR to upstream *first*, before any fork
  exists, to test upstream responsiveness cheaply?
- CI: do we want a minimal smoke test in the fork (spin an in-memory session,
  flood bytes while resizing) so the deadlock class is regression-guarded
  where it lives?
