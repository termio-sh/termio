---
title: Worktree information architecture
status: approved
type: design
created: 2026-06-28
updated: 2026-07-16
related:
  - 20260706-worktree-creation-lifecycle.md
---

# Worktree information architecture

How Termio presents git worktrees in the sidebar, and why. The revised model
(2026-07-16) is at the top; the original derived-grouping design and its rules
follow it for context and are partly superseded — read the revised section first.

## Revised model (2026-07-16): a worktree is a folder node = a project header one level down

Superseding the "derived grouping, never stored" storage decision in *Implementation*
below. After designing the interaction and surveying Codex / Conductor / GitKraken /
JetBrains Air / Crystal (see `20260706-worktree-creation-lifecycle.md`), the worktree settled
into the plainest possible shape: **a Finder-style folder node under the project, and
that node behaves exactly like a project header.**

### Presentation

- **Folder node, git-marked folder glyph, uppercase label.** A worktree renders as a
  collapsible folder row carrying the **git-marked folder glyph** (`HugeIcon.folderGit`
  — Hugeicons "folder-git": the same folder-01 body as a project, with a git commit
  node inside). This is the settled middle of two rejected extremes (both tried
  2026-07-16): a **git-branch fork** glyph read as a dead leaf, not a container; a
  **plain folder** glyph was indistinguishable from a sub-project. The git-marked
  folder reads as a *container linked to the repo* — a worktree — at a glance. Its
  label is the **live** branch name (detached → the user-given worktree name; short
  SHA in the tooltip), shown **verbatim** in the same 11pt medium section-header font
  as the project — but **not uppercased** (reversed 2026-07-16 after a design-validation
  pass): the label is a git ref, which is case-sensitive, lowercase by convention, and
  copy-pasteable into `git checkout`, so uppercasing it (`MY-FEATURE` for `my-feature`)
  would display a name the user cannot actually type — and no surveyed tool
  (Conductor/GitKraken/VS Code/GitLens) uppercases branch names. The project name *is*
  uppercased — a folder-name section label is less type-critical than a ref. A
  worktree's container-ness is carried by the folder-git glyph + indent, not by casing.
  Termio does **not** add a `>`/`⌄` disclosure triangle; the row toggles on tap. (The
  git-marked glyph has no open/closed variant, so unlike the project folder it doesn't
  swap on collapse — the child rows appearing/disappearing carry that cue.)
- **Shallow primary.** The project header *is* the primary checkout. Its sessions sit
  directly under it at the normal indent (16); only a worktree's sessions step one
  level deeper (`SessionRow.leadingIndent` 16 → 32). The common no-worktree project
  never gains depth — the third level is opt-in, paid only by worktree users.
- **Three-level tree — decided, keep it (2026-07-16).** Project → worktree → session
  is three levels, one past Apple's HIG "avoid more than two levels in a sidebar." A
  design-validation pass flagged this as the main HIG deviation and offered the
  sanctioned alternative (push the 3rd level into a content-area session list). That
  alternative was **rejected**: Termio already built and dropped a content-area session
  tab strip as redundant (see `termio-session-tabs-dropped`), and the folder-tree is
  the one pattern every user already knows (Finder, Xcode navigator) while keeping
  every agent one click away — which a terminal you tab between agents in needs. So the
  depth is a **deliberate, accepted override**, held together by strong container
  affordances (the folder-git glyph + the shallow-primary indent step). The
  GitKraken-style **card deck** stays a *later* "Agents" triage surface for the
  5+-worktree case (see Deferred), not the primary navigation.

### Behavior — the worktree node is a session container

The worktree row reuses **`ProjectHeader`**, retargeted at the worktree folder:

- **Hover** → the same quick-add cluster the project header shows: one icon per
  enabled coding agent **plus New Terminal**. One click drops that session into *this*
  worktree (sets its `worktreePath`).
- **Right-click** → "New {Agent} Session" / "New Terminal", then the worktree
  lifecycle: Reveal in Finder · Bring changes to main (the Air-style hand-off, see the
  lifecycle doc) · **Remove worktree** (refused if dirty).

So a worktree holds N sessions (terminal + agents), just like a project — which is why
it's a collapsible container, not a leaf. Implementation is literally `ProjectHeader`
with the folder glyph swapped for the branch glyph and its add-actions pointed at the
worktree folder; **reuse the component, don't rebuild it.**

### Storage — a light worktree entity (revises the "never stored" call below)

Making the worktree a **container with its own add-buttons** breaks the derived-only
approach: an **empty** worktree (created, no session yet) must still render with its
buttons, so it has to exist independently of any session.

Minimal revision: add `Project.worktrees: [Worktree]` where `Worktree = { id, path,
createdAt }` (branch stays a live label from `BranchModel`, never stored). **Sessions
stay flat** on `Project.sessions` and attach by `worktreePath`, so the `termio
sessions` control plane and every session lookup still see one flat list — the exact
thing the derived approach was protecting. Rendering: a node per `worktrees` entry,
sessions grouped under it by matching `worktreePath`.

This resolves the creation question in favor of **empty-then-fill**: "New Worktree"
creates the folder entity (and its `git worktree add`), and you then add terminals /
agents into it — creation no longer has to force a session.

## The core insight: a worktree *is* a folder

`git worktree add ../fix-auth -b fix-auth` creates a real directory on disk with a
full checkout, sharing the repo's `.git`. So "worktree = folder" is not a metaphor —
it is the filesystem truth. A Termio *project* is also a folder (the directory you
opened). The two are the same kind of thing (a directory); they differ only in git
semantics (same repo, different checkout).

This resolves the "is a worktree a new project?" question: **no.** A worktree is a
*folder under the project*, with an agent running inside it — not a sibling
top-level project (which would shatter the "all agents on this repo, together"
grouping that is the sidebar's whole value). This matches Conductor (its unit is a
"workspace" = worktree = folder, agent inside) and the IDEs (IntelliJ/GitLens/Tower
treat worktrees as folders/roots under the repo).

## The three levels

```
▾ acme-storefront            Level 1 — Project (the logical repo)
   ⎇ main                    Level 2 — a worktree/folder, labelled by its LIVE branch
        ● Claude Code        Level 3 — an agent/terminal session, runs IN that folder
        ● shell
   ⎇ fix-auth
        ● Claude Code
   ⎇ migrate
        ● Codex
```

- **Level 1 = Project / repo.**
- **Level 2 = folder + branch.** Node identity is the *folder* (a stable directory
  path). The branch is a *live label* read from `HEAD`. The primary checkout (the
  project's own directory) is just one of these folders — it is **not** hard-coded
  to "main"; it shows whatever branch that directory currently has.
- **Level 3 = the agent/terminal session.** Sessions attach to the **folder**, not
  the branch. So `git checkout` inside a folder changes only its label — the
  sessions stay put (they live in that directory).

### Rules

1. **Node identity = folder (stable); branch = live HEAD label.** Keying a node by
   branch would make it "jump" on checkout — wrong. The folder is the durable
   entity; the branch is its current state. (Corollary: uncommitted work belongs to
   the folder, which is why `closeSession`/`removeProject` deliberately leave
   worktrees on disk.)
2. **Branch updates live.** A file-system watch on the folder's `HEAD` container
   re-reads the branch on `git checkout` / `switch`, with no app interaction.
3. **Progressive disclosure.** The folder layer only appears when a project has
   **≥1 worktree**. With only the primary checkout, the sidebar stays flat
   (Project → sessions) — the common single-checkout case is untouched. Once any
   session runs in a worktree, the layer "grows" and the primary checkout also
   becomes a folder node (so the model is consistent). Remove the last worktree →
   it collapses back to flat.
4. **Detached HEAD** shows the short SHA (rebase in progress, bare-commit checkout).
5. **Empty worktrees** (on disk, no session) belong in a future "Manage worktrees…"
   surface, not the main list — the main list answers "where are my agents."

## Implementation (original phase-1 design — partly superseded, not currently wired)

> **Status (2026-07-16).** Two corrections to what follows. (1) The storage decision
> below (derived grouping, never stored) is replaced by the light `worktrees` entity
> in *Revised model* above — an empty container has to persist. (2) The
> `WorktreeHeader` / `worktreeGroups(for:)` render path described here is **not
> present in the current `SidebarView.swift`** — only `BranchModel` and the
> `SessionRow.leadingIndent` 16/32 scaffolding remain, and `addWorktree` currently
> appends a flat top-level project (see `20260706-worktree-creation-lifecycle.md`). The
> grouping render still needs building against the revised model. Kept below for the
> BranchModel/live-branch mechanics, which stand.

Storage stays **flat**: `Project { sessions: [Session] }`, `Session.worktreePath`.
"Worktree" is a **derived grouping over sessions**, *not* a stored entity. Each
session already knows its folder (`worktreePath ?? project.path`), so grouping by
that folder yields the levels for free — without rippling a nested model through
persistence, the `termio sessions` control plane, and every session lookup. This
fits Termio's "small surface area" ethos and was far lower-risk.

- **`BranchModel.swift`** — live current-branch per folder. Resolves via `git
  rev-parse` off the main thread; watches the directory containing each folder's
  `HEAD` (`git rev-parse --git-path HEAD` handles the linked-worktree path) with a
  `DispatchSource` vnode source, debounced. Watching the *directory* (not the file)
  survives git's atomic replace-of-`HEAD`. `branches: [folder: label]` is published
  on main.
- **`TermioStore`** — owns `branchModel`, forwards its `objectWillChange`, and
  `syncWatchedFolders()` (called on every `projects` change) tells it which folders
  to track: every project path + every session worktree. Exposes
  `branch(forFolder:)`.
- **`SidebarView`** — `hasWorktrees(_:)` + `worktreeGroups(for:)` derive the groups
  (primary first, then worktrees in first-seen order). When there are worktrees it
  renders a `WorktreeHeader` (the ⎇ branch node) per group with sessions at a deeper
  indent (`SessionRow.leadingIndent` 16 → 32); otherwise the original flat list.
- **`TerminalPane`** — the title-bar branch chip now reads `branch(forFolder:)` of
  the selected session's folder (live) instead of the stale stored `Project.branch`.

Verified end-to-end: a project with two injected worktrees rendered the three-level
tree; a second project with none stayed flat; and `git switch` inside a worktree
updated its node from `demo/fix-auth` to `demo/auth-v2` with no app interaction.

> `Project.branch` is now display-dead (still encoded for state compatibility; the
> UI no longer reads it). Can be removed in a later cleanup with a state migration.

## Deferred (next increments)

These were designed but intentionally not built in phase 1:

1. **Isolate-on-demand.** A worktree affordance on a session row: not-isolated =
   hover branch icon → "Isolate in worktree" (recreates the session's shell in a new
   worktree — cleanest before the agent has done work); isolated = the ⎇ badge +
   right-click `Worktree ▸` menu (Open in editor / Reveal / Remove worktree).
2. **Create-isolated entry.** `⌥`-click the project header's `+` (or a small branch
   `+`) → a new session that starts in a fresh worktree from t=0.
3. **Per-preset / per-project default** for isolation, replacing the global
   `worktreeEnabled` toggle, so creation never asks at click time (see
   marketing discussion — decision moved off the hot path).
4. **Manage-worktrees view** listing all worktrees incl. empty ones, with cleanup.
5. **Collapsible folder nodes** + ahead/behind or dirty markers, if wanted.

### Deferred surfaces from the 2026-07-16 competitive survey

Kept out of the sidebar to hold the "small surface" line; revisit when people
actually run many parallel worktrees:

6. **"Agents" card deck** (GitKraken Agent-Sessions / Cursor agent panel / Antigravity
   Mission Control) — a second, HIG-sanctioned surface where one card = one
   worktree + agent, with rich anatomy (agent · live branch · `+n/−n` · dirty · status
   bar with a 🔔 "waiting for input" state · uzi-style dev-server URL · merged-PR pill).
   This is the home for the third level when the sidebar tree gets crowded, and for
   **empty worktrees** that have no session to nest.
7. **Mac "Needs You" strip** — mirror Termio's existing iOS cross-project attention
   queue (see the iOS home design) so a blocked/done agent in *any* worktree floats to
   the top; navigate by attention, not by tree position. Reuse the iOS pattern rather
   than invent a Mac-specific one.
8. **Per-worktree run hygiene** — a reserved port block exposed as `TERMIO_PORT`
   (Conductor's `CONDUCTOR_PORT`+9) and setup/cleanup hooks, so N agents' dev servers
   don't collide. Belongs to `20260706-worktree-creation-lifecycle.md`; noted here because it
   surfaces in the card deck's dev-server URL.

### Coexistence constraint (must not break)

The sidebar already groups rows once — the split-group `┌├└` brackets in the leading
gutter (`SidebarView.splitLinkMarks` / `SplitLinkGlyph`). Worktree folder nodes add a
second grouping. The indent gutter and the branch node must be designed so the two
cues read cleanly together (a worktree's sessions can also be split-grouped) rather
than turning the gutter into competing lines.
