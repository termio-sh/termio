---
title: Loose terminals as first-class entities
status: draft
type: rfc
created: 2026-07-13
updated: 2026-07-13
related:
  - 20260628-worktree-information-architecture.md
  - 20260630-sandbox-seatbelt.md
---

# Loose terminals as first-class entities

> Stop modeling scratch terminals as sessions of a fake "home" project. A loose
> terminal is its own kind of entity — a session that *owns* a mutable working
> directory — with a sidebar section, a cwd-following inspector, and a typed
> path to promotion into a real project.

## Background

User feedback (2026-07-13, WeChat, a CLI-native early user) surfaced three
connected complaints:

1. **"我要手动新开这个 folder 才能作为 project 有点奇怪，理想状态我 cd 到一个
   folder 它就是 project"** — CLI users express intent through `cd`, not
   through Open Folder. They open a terminal as an *entry point* and
   immediately cd away from home.
2. **"我都要开始 cd 了然后我发现我的上级是 home"** — every loose terminal is
   parented under a section rooted at `$HOME`, which asserts something false:
   that the user is working *in* home. They're just passing through.
3. **"hover 里面能开 claude codex 我是找不到的"** — the agent quick-add buttons
   only appear on project-header hover; the toolbar `+` is a single hidden
   action. Discoverability fails for exactly the mouse-averse users the app
   targets. His fix suggestion: make `+` a dropdown (new terminal / open
   folder), which we adopt.

An earlier Termio version *did* make cd-creates-a-project the model, and it was
deliberately backed out: it's too fluid — cd'ing around sprays project entries,
and projects should be persistent, deliberately-created things. That decision
stands. This RFC keeps the project entity exactly as it is and fixes the other
half of the model.

## Problem

Termio today has one entity: **Project** (a path that owns sessions). Loose
terminals are shoehorned into it via a synthetic project at `$HOME`
(`addScratchSession`, `Project.firstRunProjects`). All three complaints above
are downstream of that one lie:

- The sidebar shows a "home"/"yuanjiwei" section over every scratch terminal.
- The file tree is hardwired to `project.path` (`FileBrowserView.projectPath`),
  so it sits at `$HOME` no matter where the user cd's — even though libghostty
  already publishes the live OSC 7 cwd (`TerminalViewState.workingDirectory`).
- A terminal opened at `$HOME` invites running agents there, which triggers the
  macOS TCC permission storm (see *Design rules* below).

## Design

Two entity kinds, with opposite ownership arrows:

| | identity | path | sessions |
|---|---|---|---|
| **Project** | its path (persistent, stable) | owns the sessions | many |
| **Loose terminal** | the session itself | a *mutable property* (live cwd) | one |

This matches the two mental models users already have: iTerm2 (the tab is the
entity, cwd is ephemeral state) and VS Code (the folder is the entity). Termio
needs both, as two honest kinds — not one kind simulating the other.

### Sidebar: a "Terminals" section

Loose terminals live in a flat **Terminals** section, pinned above the
projects. It is not presented as a folder: terminal glyph instead of the folder
mark, fixed "Terminals" label, no branch, no sandbox pill, no agent quick-add
hover buttons (agents don't belong in `$HOME`; scratch agents keep their own
`~/.termio/default` flow, unchanged). Each row's title is the **basename of its
live cwd** (`~` at home), so after `cd ~/code/foo` the row reads `foo` — the
row itself becomes the answer to "where am I".

Implementation note: the storage container survives as a `Project` with a
`kind: .terminals` marker. That is an implementation detail — persistence
shape, selection, splits, and surface caching all key on the Project→Session
tree, and a parallel top-level array would fork all of them for zero user
visible gain. The *presented* entity is what changes.

### Inspector follows the loose terminal's cwd

For sessions in the Terminals section, the file tree / search / git-changes
root is the live cwd (falling back to the last persisted cwd, then `$HOME`),
instead of `project.path`. Real projects keep their stable root — the anchor is
the point of a project; only loose terminals follow.

Free side effect: cd into a git repo and the right pane already shows the
tree + changes — a live preview of what promotion to a project would give.

### Spawn and restore at the last cwd

The OSC 7 stream is persisted per loose session
(`Session.lastWorkingDirectory`). A relaunched loose terminal's shell starts at
its last cwd rather than `$HOME` — for users whose real life starts after the
first `cd`, restart drops them back where they were. (Shells themselves still
restart fresh; only the directory is remembered.)

### Toolbar `+` becomes a dropdown

`NSMenuToolbarItem` (same construction as the sort pull-down), exactly two
entries — the two ways something new enters the sidebar:

- **New Terminal**
- **Open Project…**

Agent entries were built and then cut by user decision (2026-07-13, "加了太多
戏"): agents are started *inside* a project (header buttons / context menu),
and the welcome page's chips already cover the scratch case — listing them in
`+` duplicated both. This is the discoverability fix: each entry point is one
visible click, no hover required.

### Promotion: cd, then say so (Phase 2)

The bridge from loose terminal → project is an explicit action, not automatic
(automatic promotion is the rejected v1). Because terminal users abandon the
mouse, the primary affordance is typed:

```
termio open .        # promote this terminal's cwd to a project
```

delivered over the existing `termio sessions` control socket. The calling
session (identified by `$TERMIO_SESSION`) is **re-parented in place** under the
new (or existing) project — the same PTY, same scrollback, new home in the
sidebar. Mouse path: a context-menu "Open as Project" on the terminal row when
its cwd isn't inside an existing project.

When a loose terminal cd's *into* an existing project's path: do nothing
(perhaps a quiet marker later). Auto-adoption takes control away.

### Design rules (TCC / permission storm)

Verified against the Warp source (2026-07-13; it ships **zero** TCC-path
exclusion lists because its architecture never needs one):

1. **Never recursively walk down from `$HOME`** — no indexing, no watchers, no
   full-tree scans rooted there. Enumerating `~` itself is TCC-free; descending
   into `~/Music`, `~/Desktop`, `~/Library/...` is what fires the Apple
   Music/Photos/Contacts prompts, attributed to Termio as the responsible
   process.
2. **Detect repos by walking *up*** from the reported cwd (`.git` parent
   lookup), never down. Cheap, TCC-free, and doubles as the promotion signal.
3. **Lazy enumeration only** in the file tree — expanding a protected folder is
   the user's explicit intent, and the prompt is then expected.
4. Agents are child processes Termio can't gate in-process the way Warp gates
   its in-process AI file reads; the equivalents are cwd scoping
   (`~/.termio/default`) and the Seatbelt sandbox (a Seatbelt deny returns
   EPERM *before* tccd is consulted — no prompt at all).

## Non-goals

- **Auto-creating projects on cd** — rejected v1, stays rejected.
- **Unifying the two entities** (e.g. `Project.anchored: Bool`) — a project is
  one-path-many-sessions, a loose terminal is one-session-one-cwd; forcing one
  shape breaks on multi-session.
- **Changing scratch agents** — `~/.termio/default` is a safety decision,
  untouched.
- **cwd-following file tree inside real projects** — the stable anchor is the
  feature.

## Implementation

### Phase 1 (this RFC's refactor)

- `Models.swift` — `Project.kind: ProjectKind` (`.folder`/`.terminals`,
  decode-defaulted to `.folder`); `Session.lastWorkingDirectory: String?`;
  `firstRunProjects()` seeds a Terminals container instead of a "home" project.
- `TermioStore.restored` — migrate any persisted project whose path is `$HOME`
  to `kind: .terminals`.
- `TermioStore+ProjectActions.swift` — `addScratchTerminal` finds the container
  by kind, not path; `orderedProjects` floats the Terminals section to the top.
- `TermioStore+TerminalSurface.swift` — subscribe to
  `state.$workingDirectory` in `monitor(_:for:)` → publish
  `workingDirectories[id]` + persist `lastWorkingDirectory` for loose
  terminals; spawn loose terminals at `lastWorkingDirectory ?? $HOME`.
- `TermioStore.displayTitle(for:)` — loose auto-named terminals display the
  live cwd basename (`~` at home).
- `SidebarView.swift` — `ProjectHeader` renders the Terminals section variant
  (terminal glyph, fixed label, trimmed menu, no agent hover buttons).
- `FileBrowserView.swift` — `projectPath` resolves to the live cwd for
  sessions in a `.terminals` container (tree, search, and changes all key off
  it already).
- `App.swift` — `.newTerminal` toolbar item becomes an `NSMenuToolbarItem`
  with New Terminal / Open Folder… / agent entries.

### Phase 2

`termio open .` promotion + row context-menu equivalent, with in-place session
re-parenting.

### Phase 3 (only if pressure appears)

Quiet "≙ project" marker when a loose terminal sits inside a known project;
"New terminal default directory" setting.

## Implementation prompt

A self-contained prompt for executing Phase 1 in a fresh session:

```text
In ~/Documents/GitHub/termio (native Swift/AppKit/SwiftUI Mac terminal app,
SwiftPM, builds with `swift build`), implement Phase 1 of
docs/design/20260713-loose-terminal-entity.md — read that RFC first; it is the spec.

Summary: loose scratch terminals currently masquerade as sessions of a fake
"home" project rooted at $HOME. Make them an honest "Terminals" entity:

1. Models.swift: add `enum ProjectKind: String, Codable { case folder,
   terminals }` and `Project.kind` (decode-default `.folder`, keep the
   memberwise init working — the file already shows the custom-decoder
   pattern for `pinned`). Add `Session.lastWorkingDirectory: String?`
   (same decode-default pattern). Update `Project.firstRunProjects()` to seed
   name "Terminals", kind `.terminals`, path $HOME.
2. TermioStore.restored (TermioStore.swift): after loading the snapshot,
   migrate any project whose standardized path == $HOME to kind `.terminals`
   (idempotent).
3. TermioStore+ProjectActions.swift: `addScratchSession(agent: .terminal)`
   must find/create the container by `kind == .terminals` (name "Terminals"),
   not by path. `orderedProjects` sorts `.terminals` ahead of everything
   (before pinned).
4. TermioStore.swift: add `@Published var workingDirectories: [Session.ID:
   String] = [:]`. In TermioStore+TerminalSurface.swift `monitor(_:for:)`,
   append a sink on `state.$workingDirectory` (compactMap, removeDuplicates)
   that updates the map and, when the session lives in a `.terminals` project,
   writes `lastWorkingDirectory` back onto the persisted session (mirror how
   the `$title` sink writes `liveTitle`). In `surface(for:in:)`, when
   `project.kind == .terminals`, spawn at `session.lastWorkingDirectory ??
   project.path` (verify the directory still exists, else fall back).
5. `displayTitle(for:)` (TermioStore.swift): for a `.terminals`-contained,
   auto-named ("Terminal N") plain terminal, return the basename of
   `workingDirectories[id] ?? lastWorkingDirectory`, with $HOME displayed as
   "~"; keep "Terminal" as the pre-first-report fallback. User-renamed
   sessions keep their name.
6. SidebarView.swift ProjectHeader: when `project.kind == .terminals`, render
   the HugeIcon `.terminal` glyph (not folder), the fixed label "Terminals",
   suppress the agent quick-add hover overlay and the Sandbox pill, and trim
   the context menu to: New Terminal / separator / Remove.
7. FileBrowserView.swift `projectPath`: when the selected session's project
   kind is `.terminals`, return `store.workingDirectories[id] ??
   session.lastWorkingDirectory ?? project.path`. Everything (tree, search,
   changes) already keys off this property and refreshes onChange.
8. App.swift: replace the `.newTerminal` NSToolbarItem with an
   NSMenuToolbarItem (copy the `.sortProjects` construction in
   MainToolbarDelegate) holding exactly two entries: "New Terminal" →
   `store.addScratchTerminal()` and "Open Project…" →
   `store.presentOpenProjectPanel()`. No agent entries (user decision — they
   live on project headers and the welcome page). Keep the plus icon; tooltip
   "New terminal or project".

Constraints: match surrounding comment density/idiom; no new dependencies; do
NOT touch the scratch-agent flow (~/.termio/default), worktrees, or split
groups. Never add any code that recursively scans $HOME (RFC design rules).
Build with `swift build`; then rebuild+relaunch the dev app via the
macos-rebuild-dev skill and verify: fresh terminal shows under "Terminals",
`cd` into a repo renames the row and moves the file tree, relaunch restores
the cwd, and the + dropdown shows all entries.
```
