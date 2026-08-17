---
title: Sidebar scroll performance — per-session runtime state
status: draft
type: design
created: 2026-07-24
updated: 2026-07-24
related:
  - 20260713-loose-terminal-entity.md
---

# Sidebar scroll performance — per-session runtime state

## Symptom

With more than a handful of projects open, scrolling the sidebar stutters while
an agent is working. It is smooth when everything is idle.

## Root cause

Not the `List` control. `List(.sidebar)` is backed by `NSTableView` and already
virtualizes rows; painting a hundred rows is not the problem.

The problem is **observation granularity**. `SidebarView`, `SessionRow`, and
`ProjectHeader` all hold `@EnvironmentObject var store: TermioStore`, and
`TermioStore` is an `ObservableObject`. `ObservableObject` invalidation is
*object-level*: any `@Published` change fires one `objectWillChange`, which
re-runs **every** view that observes the store — the whole sidebar tree.

Four `@Published` dictionaries changed at agent-tick frequency:

- `statuses` — flipped on every hook event / screen tick
- `currentTool` — changed per tool call
- `liveTitles` — rewritten on every frame of a ticking title spinner
- `workingDirectories` — on every `cd`

Plus a fifth churn source: `liveActivity[pid] = Date()` was written on *every*
working report (a fresh `Date` each time → always a real change), re-sorting and
rebuilding the container roughly once a second per active agent.

So during agent work the entire `SidebarView.body` re-ran several times a second
— recomputing `orderedProjects` (a sort), the pinned partition (flatMaps + Sets),
and rebuilding every row struct — and that competed with the scroll gesture for
the main thread.

## Fix

Move the four high-frequency fields off the store's single `objectWillChange` and
onto a **per-session `@Observable`**, so a change invalidates only the one row
that owns it.

### `SessionRuntime`

A tiny `@MainActor @Observable final class` holding `status`, `currentTool`,
`liveTitle`, `workingDirectory`. The store keeps a stable `runtimes:
[Session.ID: SessionRuntime]` map (**not** `@Published` — the map's identity is
stable; only each runtime's fields change). `syncRuntimes()`, called from
`projects.didSet` and once after load, creates a runtime when a session enters the
tree and drops it when the session closes, so every row has a stable object to
observe from its first render.

A `SessionRow` reads `store.status(for: id)` → `runtimes[id]?.status`. Because the
row body is evaluated under SwiftUI's observation tracking, accessing that
`@Observable` property — even through a store method — registers a dependency on
*that session's* runtime alone. A status flip on session A now re-renders row A
and nothing else: not the container, not sibling rows.

The public accessors (`status(for:)`, `statusDescription(for:)`,
`displayTitle(for:)`, plus a new `workingDirectory(for:)`) keep their signatures
and are reimplemented over `runtimes`, so the non-SwiftUI readers (companion
server, `termio sessions` CLI, menu-bar tray) are unaffected. Writes go through
no-op-guarded setters (`setStatus`, `setCurrentTool`, `setLiveTitle`,
`setWorkingDirectory`) so a redundant same-value write neither re-renders a row
nor pings observers.

### `liveActivity` coalescing

`liveActivity` stays `@Published` (a sort-order change genuinely must re-render
the container), but it now fires far less. The agent-side bump moved into
`setStatus`'s **transition into `.working`**, so a turn floats its project up once
at turn start rather than on every hook/screen tick. `noteProjectActivity(_:force:)`
still coalesces background bumps within a 4 s window as a flap backstop; deliberate
user actions (selecting a session, attaching from the phone) pass `force: true` so
they float the project *immediately*, never suppressed by a recent background bump
(the ordering regression an unconditional coalescer introduced).

Residual: with many *independently* active projects, `liveActivity` still triggers
one store-wide invalidation per project turn-start — bounded and infrequent, but
not zero. Eliminating it entirely would mean publishing only when the displayed
order actually changes; deferred as not worth the complexity for the common case.

### Non-SwiftUI push consumers

The menu-bar tray is plain AppKit and can't subscribe to a per-session
`@Observable`, yet it previously relied on the store's `objectWillChange` firing on
status/title changes. It now subscribes to a dedicated `sessionRuntimeDidChange`
`PassthroughSubject` (throttled 250 ms), fired only by `setStatus` and
`setLiveTitle` — the two fields the tray presents. `setCurrentTool` and
`setWorkingDirectory` don't ping: those show only in SwiftUI (a row tooltip, the
loose-terminal label, the cwd-following inspector), which track the runtime
directly. The window title bar needs nothing new either — `updateWindowTitle`
reads only the selected session's path, which lives on the structural store, so its
plain `objectWillChange` subscription already covers it. The companion server also
needs nothing — it polls the store once a second and broadcasts on change.

## Why not migrate the whole store to `@Observable`

Considered and rejected for this change. It would fix the container-rebuild path
too, but it also deletes `objectWillChange`, breaking the three subscribers that
depend on it (window title, overlay chrome, tray) and forcing every
`@EnvironmentObject`/`.environmentObject` site to move to
`@Environment`/`@Bindable`. Larger blast radius, higher regression risk, no extra
win for the sidebar over the surgical fix above. The migration remains a sensible
later cleanup, not a prerequisite.

## Caveat — runtime presence is load-bearing

A row reads `runtimes[id]?.status ?? .idle`. If a live session ever lacked a
runtime, that read observes nothing, and a later lazy `runtime(for:)` create
wouldn't fire any invalidation, so the row could stay stale until an unrelated
redraw. `syncRuntimes()` (from `init` and `projects.didSet`) keeps the invariant on
every add/remove/restore path, and no current path renders a live row before its
runtime exists — but the invariant is worth an assertion/test if this grows.

## Verification

- `swift build` clean.
- Independent review (a Codex sibling) confirmed the core claim by local
  `withObservationTracking` experiment: a dictionary lookup followed by a
  method-mediated `@Observable` read does establish the per-session dependency, and
  `@EnvironmentObject` does not defeat it. It also flagged, and this revision fixed:
  a user-focus activity-ordering regression (the `force` path), an over-broad
  runtime ping (now scoped to status/title), and a dead window-title subscription
  (reverted). 18 existing tests pass; none cover this refactor.
- Runtime (pending, needs a busy tree): open many projects, run an agent, scroll
  while it works — the tree should stay smooth; the working row's spinner, the tray
  badge, and the window title should still update live.
