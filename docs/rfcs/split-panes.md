---
title: Split panes — Ghostty-style splits in the terminal column
status: in-review
type: rfc
created: 2026-07-02
updated: 2026-07-02
---

# Split panes — Ghostty-style splits in the terminal column

> Let any session's pane split into a Ghostty-style tree of terminals (⌘D
> right, ⌘⇧D down, a right-click context menu with all four directions,
> draggable dividers, click-to-focus), so e.g. an ssh shell and a local shell —
> or an agent and a scratch terminal — sit side by side.

## Motivation

Termio shows one session at a time; the sidebar is the multiplexer. That is
right for switching *between* agents, but not for working *alongside* one: ssh
into a server while a local shell tails logs, or run commands next to a working
agent. Ghostty solves this with splits — but splits are not a libghostty
feature. They live entirely in Ghostty's macOS app layer; every embedder builds
their own. This RFC is Termio's version.

Two facts make it cheap here:

- **Every session is already an independent, always-mounted surface.** One
  session = one `TerminalViewState` (cached in `TermioStore.surfaces`) backed by
  its own host-managed `PTYProcess`. `TerminalPane` keeps all opened sessions
  mounted in a ZStack and toggles opacity. Splits are a tree model plus layout
  math — **zero PTY / libghostty changes**.
- **ssh needs nothing special.** A pane is a login shell on its own PTY;
  `ssh server` is just a command typed into it.

## Design invariants

1. **View identity stays stable.** SwiftUI teardown of a surface view frees the
   ghostty surface (`TerminalSurfaceCoordinator.deinit` →
   `ghostty_surface_free`) — scrollback is lost, and resize churn causes
   SIGWINCH repaint flicker (the exact bug the mounted-ZStack design fixed).
   Therefore panes are **not** rendered as nested `HSplitView`/`VSplitView`
   containers. The flat `ForEach(mounted, id: \.session.id)` ZStack stays; the
   split tree is flattened to **per-session rects**, applied with
   `.frame(width:height:).position(...)`.
2. **Hidden sessions keep their own tree-frame** (full pane only when
   tree-less). Revealing a tree must never resize its panes — visibility stays
   pure opacity + hit-testing, as today.
3. **Sessions stay flat** in `projects[].sessions`. The sidebar, the
   `termio sessions` CLI, and the iOS companion address sessions by id and are
   unchanged. Split trees are a *layout overlay* that only references session
   ids.
4. **`selectedSessionID` remains the single source of truth** and now means
   "the focused pane's session". Clicking a pane focuses it; a sidebar row
   whose session sits in a tree reveals the whole tree and focuses that pane.
5. **Dividers are layout-reserved strips, not overlays.** `AppTerminalView` is
   a real NSView; AppKit hit-testing returns the deepest NSView, so a SwiftUI
   drag handle floated *over* a terminal does not reliably receive mouseDown.
   The flattener instead reserves a ~7pt strip (1pt visible hairline centered)
   between panes where no NSView lies underneath — SwiftUI `DragGesture` and
   `.onHover` cursor work there. Once a drag starts, AppKit routes subsequent
   drag events to the gesture, so dragging across a terminal is safe.

## Design

### Model — `Sources/termio/SplitTree.swift` (new)

```swift
enum SplitAxis: String, Codable, Hashable { case horizontal, vertical }
// horizontal = panes side by side ("Split Right")

enum SplitBranch: String, Codable, Hashable { case first, second }

indirect enum SplitNode: Codable, Hashable {
    case leaf(Session.ID)
    case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)
}

struct SplitTree: Codable, Hashable, Identifiable {
    var id = UUID()
    var root: SplitNode
}

/// User-facing split direction; not persisted. Maps to an axis plus which
/// branch the NEW pane takes: right/down → second, left/up → first.
enum SplitDirection { case left, right, up, down }
```

Pure helpers on `SplitNode` (all return new values): `leaves`, `contains(_:)`,
`replacingLeaf(_:with:)`, `removingLeaf(_:)` (the removed leaf's parent
collapses to its sibling), `updatingRatio(at: [SplitBranch], to:)` (clamped
0.1…0.9), `pruned(keeping: Set<Session.ID>)` (drops dangling leaves at load).

`Project` gains `var splits: [SplitTree] = []`, decoded with
`decodeIfPresent … ?? []` in its existing custom `init(from:)`
(`Models.swift:34-43`, same pattern as `pinned`). Old `state.json` files load
unchanged; `StateFile.Snapshot` is untouched — trees persist with the project.

### Layout — `Sources/termio/SplitLayout.swift` (new)

A pure, stateless flattener:

```swift
compute(root: SplitNode, in: CGRect, ratioOverride: (path, ratio)?)
    -> (panes: [(Session.ID, CGRect)], dividers: [DividerHandle])
```

Per split node: subtract `dividerThickness` (7pt) from the split axis, apply
the ratio, round all rects to whole points (a half-point Metal layer edge blurs
and can throw the grid-column computation off by one against a neighbor).
`minimumPane` (100pt) is enforced at layout time with a proportional fallback
when the container cannot fit two minimums; it is never persisted.
`DividerHandle` carries the node `path`, `axis`, the strip `rect`, and the
parent `nodeRect` so a drag location maps back to a ratio.

### Store — `Sources/termio/TermioStore/TermioStore+Splits.swift` (new)

- `splitTree(containing id:) -> SplitTree?` — session ids are unique across
  projects.
- `splitSession(_ id:, direction:)` — factor `addSession`'s `Terminal N` title
  numbering (`TermioStore+ProjectActions.swift:6-16`) into a shared
  `makeSession(in:agent:)`; then, in **one** `projects[index]` mutation (one
  `persist()`, one render): append the new `.terminal` session and replace the
  target leaf with `.split(axis:, ratio: 0.5, …)` — the new pane takes the
  `first` branch for left/up, `second` for right/down (or a new tree starts
  when the session was tree-less). Finally select the new session — the
  existing `onChange` chain focuses it. Menu-bar actions pass the selected
  session; the context menu passes the pane under the cursor.
- `commitSplitRatio(treeID:path:ratio:)` — called on drag **end** only. Every
  `projects` write runs `persist()` (disk) + `syncWatchedFolders()`; the live
  ratio during a drag lives in a `TerminalPane` `@State` override fed to the
  flattener.
- `removeFromSplits(_ id:) -> Session.ID?` — collapse the tree around the
  removed leaf, drop the tree entirely once it reaches a single leaf (that
  session renders full-pane again), and return the sibling's first leaf as the
  selection fallback.

`closeSession` (`TermioStore+ProjectActions.swift:169-193`) calls
`removeFromSplits` inside the same mutation and prefers its fallback over the
index-neighbor heuristic. The CLI (`sessions stop`) and the iOS companion both
route through `closeSession`, so tree fix-up is centralized — no other close
path exists (a shell exiting does not close its session today).
`TermioStore.restored` prunes each project's `splits` against live session ids,
defending against a state file written by a crashed run.

### Rendering — `TerminalPane.swift`

- Wrap the ZStack in a `GeometryReader` with a named coordinate space.
  `visibleTree = selectedSessionID.flatMap(store.splitTree(containing:))`.
- Each mounted session's rect comes from *its own* tree's layout (visible or
  not — invariant 2), else the full bounds. Visibility: member of
  `visibleTree`, or `id == selectedSessionID` when tree-less. Frames are
  center-`position`ed (`rect.midX/midY`) and never animated. Frame changes
  automatically drive `setFrameSize → fitToSize → ghostty_surface_set_size →
  PTY resize (SIGWINCH)` — no new resize plumbing.
- Dividers render above the surfaces for the visible tree only: hairline in a
  clear 7pt strip, `.contentShape(Rectangle())`, `.onHover` resize cursor,
  `DragGesture` writing a transient ratio override, `commitSplitRatio` on end.
- Activation (`onChange(of: selectedSessionID)`) also activates every leaf of
  the selected session's tree, so a restored tree mounts (and lazily respawns)
  all its shells the moment any member is selected.
- A new `onChange(of: focusedSession)` promotes pane focus to
  `store.selectedSessionID`. The existing reverse edge
  (`selectedSessionID → focusedSession`) is idempotent-guarded — no cycle. The
  keyboard-focus-rescue path and the file/diff/trace overlays are unchanged;
  overlays deliberately keep covering the whole pane (including dividers). The
  existing file-drop handler (`TerminalPane.swift:123` → `sendPaths`) is also
  unchanged — dropped paths keep going to the selected (focused) session.

### Right-click context menu — `TerminalPane.swift` (or a small helper)

Right-clicking a pane shows **Copy · Split Left / Right / Up / Down · Close
Session**, acting on the pane under the cursor (which is focused first).

The embedded view cannot provide this itself: `libghostty-spm` is an external
package (Lakr233) whose `TerminalViewRepresentable` hardcodes
`TerminalView(frame:)` — Termio cannot inject an `AppTerminalView` subclass to
override `menu(for:)`. And the package's `rightMouseDown`
(`AppTerminalView+Input.swift:157`) forwards right-clicks to the surface as
`GHOSTTY_MOUSE_RIGHT` (never consulting `menu(for:)`), except on a text
selection where it pops its own Copy menu — so SwiftUI `.contextMenu` or the
NSView `.menu` property would never fire.

Instead, Termio installs a **local `NSEvent` monitor** for `.rightMouseDown`
(the same bypass-the-package spirit as the link-open delegate workaround):

- Convert the event location into the terminal pane's coordinate space; ignore
  events outside it or while a content overlay is open. Hit-test against the
  visible pane rects to find the target session.
- Focus that pane, pop an `NSMenu` at the event location, and swallow the
  event (return `nil` from the monitor).
- **Copy** uses a nil-target `copy(_:)` item — selector dispatch walks the
  responder chain to the focused `AppTerminalView`, which implements it (the
  package's selection APIs are internal, but Objective-C dispatch doesn't
  care). No-ops harmlessly without a selection.
- The monitor replaces the package's selection-Copy popup (its path never runs
  once we swallow the event) — Copy in our menu covers it.
- **Trade-off**: the shell no longer receives right-button events, so
  mouse-reporting TUIs lose right-click. Escape hatch: **⌥-right-click
  bypasses the monitor** and forwards to the shell (the terminal convention
  for "send it to the app").

### Menu & keybinds — `App.swift`, `TermioStore+TerminalSurface.swift`

File menu gains **Split Left**, **Split Right ⌘D**, **Split Up**,
**Split Down ⌘⇧D**, and **Close Session ⌘W** (⌘W is currently unclaimed),
backed by `@objc` AppDelegate actions on the store, disabled via
`NSMenuItemValidation` when nothing is selected. Left/up have no key
equivalents (matching Ghostty's defaults); they're reachable via the context
menu.

Ghostty's default config binds `super+d` / `super+shift+d` / `super+w` itself,
and `AppTerminalView.performKeyEquivalent` consumes any key that
`ghostty_surface_key_is_binding` matches — the menu would never see ⌘D. So
`applyAppearance` appends `keybind = super+d=unbind` (and the other two) to the
surface configuration.

## Edge cases

- **Pane closed via CLI / companion / sidebar ✕** — all route through
  `closeSession`; the tree collapses to the sibling and selection falls there.
- **Selection moves to another project** — `visibleTree` derives from the
  selected session; other projects' trees stay mounted-hidden at their own
  frames.
- **App restart** — tree geometry persists; shells respawn lazily on first
  reveal (sessions never survive app quit, unchanged).
- **Tiny window** — ratio clamped at write; minimum pane enforced at layout
  with proportional fallback.
- **Companion/CLI-started sessions** — simply tree-less, render full-pane.

## Out of scope (deliberately)

Pane rearranging (drag panes around), keyboard pane navigation (⌘⌥arrows),
pane zoom, per-pane file-drop targeting (drops keep landing in the focused
session; hit-testing the drop location against pane rects is a later
refinement), and splitting with an *agent* preset (⌘D always opens a plain
terminal; an agent can still be launched inside it by typing `claude`). Each
is additive later without model changes.

## Alternatives considered

- **libghostty's split API** — the C headers expose
  `GHOSTTY_SURFACE_CONTEXT_SPLIT`, but split *management* lives in Ghostty's
  app runtime, which libghostty-spm strips (`-Dapp-runtime=none`). Not usable.
- **Recursive `HSplitView`/`VSplitView`** — breaks view identity (surface
  teardown → scrollback loss), no ratio control, no persistence. Rejected.
- **tmux underneath** — already rejected for the host-PTY architecture
  (VS Code / Zed / zellij / sshx all own the PTY themselves).

## Verification

1. ⌘D / ⌘⇧D split the focused pane; splitting a split nests correctly.
   Right-click on each pane offers all four directions and splits *that* pane
   (left/up place the new pane before it); Copy works on a selection;
   ⌥-right-click still reaches the shell.
2. Divider: hover cursor, live drag resize (both shells SIGWINCH), minimum
   sizes hold, ratio survives restart.
3. Click a pane → focus + sidebar selection follow; sidebar row reveals the
   whole tree.
4. Close a middle pane via sidebar ✕, ⌘W, and `termio sessions stop <id>` —
   tree collapses to the sibling; the last pane renders full-pane.
5. Restart: geometry restored, fresh shells spawn on first reveal.
6. ssh in one pane + local shell in the other; project/session switches cause
   no resize flicker.
7. File editor / diff / trace overlays still cover the pane and hand focus
   back on close.
