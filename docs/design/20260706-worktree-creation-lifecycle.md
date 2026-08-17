---
title: Git worktree creation & lifecycle (Codex-aligned)
status: approved
type: design
created: 2026-07-06
updated: 2026-07-16
related:
  - 20260628-worktree-information-architecture.md
---

# Git worktree creation & lifecycle (Codex-aligned)

> How Termio *creates*, *names*, *branches*, and *cleans up* git worktrees for agent
> sessions. The sibling IA doc covers how worktrees are *presented*; this covers the
> mechanics it deferred.

`20260628-worktree-information-architecture.md` shipped phase 1 (the three-level sidebar +
live branch label) and explicitly deferred "isolate-on-demand" and the
"create-isolated entry." This doc specifies that deferred creation path, aligned to
the **OpenAI Codex desktop** model — which has thought through the failure modes
(branch-in-two-places, missing `.env`, unbounded disk) that a naive version hits.

## ⚠️ Status vs. shipped code (2026-07-16)

The **current `addWorktree(from:)`** (`TermioStore+ProjectActions.swift`) does **not**
implement the model in either doc. It runs `git worktree add --detach` into
`~/.termio*/worktrees/<name>`, copies `.worktreeinclude`, then
`projects.append(worktreeProject)` — surfacing the worktree as a **flat, top-level
`Project` with no sessions and no link to its parent repo.** That directly
contradicts the IA doc's core rule (a worktree is a folder *under* the project, a
derived grouping over `Session.worktreePath` — never a sibling top-level project).

So `addWorktree` creates *a bare top-level project*, which is the visible symptom
("worktrees show up as top-level entries, not indented under the repo like Codex").
**The fix (revised 2026-07-16, see the IA doc's *Revised model*):**

- Represent the worktree as a **light entity nested under its parent**, not a
  top-level project: append to `parentProject.worktrees` (`Worktree = { id, path,
  createdAt }`), *not* to `projects`. Sessions stay flat on `Project.sessions` and
  attach by `worktreePath`.
- Render it as a **folder node** (a `ProjectHeader` reused one level down) that groups
  the parent's sessions whose `worktreePath` matches — with its own hover quick-add
  cluster (agents + New Terminal) and right-click lifecycle menu.
- Drop the `projects.append(worktreeProject)` branch entirely.

This makes the worktree a **session container** (empty-then-fill: create the folder,
then add terminals/agents into it) and makes the sidebar match Codex/Conductor. The
old "must create a session at the same time" idea is dropped — the stored entity lets
an empty worktree persist with its add-buttons.

## Cross-product model check (Codex / Conductor / JetBrains Air)

Surveyed 2026-07-16; all three confirm the nested "folder-under-repo" IA and add a
few borrowables:

- **Naming: hide "worktree."** Codex = "thread," Conductor = "Workspace," Air =
  "Task." Users never type `git worktree`. Termio's "New Worktree Session…" is close;
  the noun users see should be the *session/branch*, not the git primitive.
- **Disk: everyone moved out of the repo.** Conductor `~/conductor/workspaces/<repo>/`,
  Air `~/Library/Caches/JetBrains/Air/tasks/`, Codex `~/.codex/worktrees/`. Conductor
  *deprecated* its in-repo `.conductor/` layout. Termio's `~/.termio/worktrees/` is on
  the right side of this.
- **Untracked-files gap is universal.** All three copy gitignored files in; Conductor
  + Claude Code use the *same* `.worktreeinclude` format Termio already adopted.
- **Setup + teardown hooks are table stakes.** Conductor `[scripts]` setup/run/archive;
  Air `.air/worktree.json` setup/cleanup. Both pair a create-time setup with a
  **pre-delete cleanup** hook (tear down DBs/containers living outside the dir).
- **Branch handle:** Conductor auto-generates a city-name dir handle (`warsaw`)
  *separate* from the branch, then has the agent rename the branch from the first
  prompt. Air names the branch `air/<task>`. Termio's "repo-name + session-id" leaf is
  a fine handle; the live branch already shows separately (IA doc rule 2).

## Guiding principle

**Match Codex exactly; diverge only where Termio's architecture forces it.** During
design, every reflex to *add structure* (sibling dirs, Application Support nesting,
per-project subdirs, forced branch prefixes) turned out to buy nothing over Codex's
plainer shape. The two justified divergences are both architectural, not aesthetic:

1. Termio is a **terminal**, so the worktree's cwd basename is visible everywhere
   (shell prompt, tab title) → the folder name must be self-describing.
2. Termio already has `Session.worktreePath` and resolves it as the PTY cwd
   everywhere → bind the worktree to a **session**, reusing existing plumbing.

## What Codex does (the model we're following)

- **Worktree per task/thread**, auto-managed — the user never hand-picks a path.
- Central app-owned dir: `~/.codex/worktrees/thread-*`.
- **Detached HEAD by default** — no branch auto-created. A "Create branch here"
  action materializes a branch only on explicit intent (avoids branch-name
  pollution + git's one-branch-one-checkout conflict).
- Finish by commit/push/PR from the app, or "hand off" changes to the local
  checkout.
- Bounded retention (keep N most recent, snapshot before delete, pin exemptions).
- `.worktreeinclude` copies git-ignored files (`.env`, secrets) into fresh
  worktrees; a post-create setup hook runs.

## Termio design

### Entry point

Right-click a project (or its hover cluster) → **"New Worktree"**. This creates the
worktree **folder entity** and adds it as a nested folder node under the project; you
then add terminals/agents into it from *the worktree node's own* quick-add cluster and
right-click menu (it reuses `ProjectHeader` — see the IA doc's *Behavior* section). An
accelerator for the common "start an agent isolated from t=0" case: ⌥-click one of the
project header's agent icons = create a worktree **and** launch that agent in it in one
gesture (the IA doc's deferred "create-isolated entry", item 2). Both routes exist; the
plain "New Worktree" makes the empty container, the ⌥-accelerator fills it in one step.

### Location & naming

```
~/.termio/worktrees/
  termio-worktree-a1b2c3d4/      ← session a1b2c3d4, repo "termio", detached HEAD
  vibewizard-worktree-9f3e21c0/
<repo>/.worktreeinclude            ← repo root (SAME file Conductor/Claude Code use — interop)
<repo>/.termio/                    ← termio-specific config (branchPrefix, setup.sh)
```

- **`~/.termio/`, not `~/Library/Application Support/termio/`.** The Application
  Support path exists to satisfy the App Store sandbox; Termio ships via
  Sparkle/direct-download and is **not sandboxed**, so a `~/.termio/` home dotfolder
  is both the Unix dev-tool idiom (`~/.ssh`, `~/.codex`) and more faithful to Codex.
  The codebase already treats `~/.termio` as a fallback location (`StateFile.swift`,
  `SessionControl.swift`, `ThemeLibrary.swift`); this promotes it for worktrees.
- **Flat**, not nested by project. Session ids are UUIDs — already globally unique —
  so a `<project>/` namespace level is redundant. The repo name lives *in the leaf*
  for orientation, not as a directory level.
- **Leaf = `<repo-dir-name>-worktree-<8char-session-id>`.** The repo name earns its
  place because Termio is a terminal: a bare-UUID basename would leave you blind in
  the shell prompt / tab title. Codex's plain `thread-N` is fine for a chat-desktop
  app where the basename isn't surfaced; it isn't for us. The `<id>` is the same
  8-char id shown in `termio sessions list`, so the folder matches the id the user
  sees elsewhere. Uniqueness comes from the id, so two clones both named `termio`
  won't collide.
- **Chosen at creation, never renamed.** We start detached (no branch yet), so the
  only always-available parts are repo-name + session-id. When a branch is
  materialized later we do **not** rename the dir (`git worktree move` rewrites
  `worktreePath` + git metadata for no gain; the git-prompt shows the branch
  separately anyway).

### Branch: detached HEAD first, materialize on intent

Create with:

```sh
git worktree add --detach <path> <base>
```

- **Detached, not `-b <branch>`.** Agent worktrees are *mostly disposable* — most
  sessions are experiments you throw away. `git worktree add -b` immediately locks
  that branch out of the main checkout (git's one-branch-one-place rule) and
  pollutes the branch list with dead experiments. Detached-until-it-matters defers
  the name until the work earns one.
- **"Create branch" is a later session action** (the IA doc's item 1, "isolated =
  right-click Worktree ▸ menu"), running `git switch -c <name>` in the worktree.

### Branch naming when materializing

Single editable text field, **pre-filled with a slug of `Session.liveTitle`** (the
agent-updated title Termio already tracks):

```
Session "Fix login redirect"  →  prefill: fix-login-redirect  (Enter, or edit)
```

- The user inputs the name — Codex does too, and auto-generating branch names from
  agent output yields junk (`fix-stuff-2`). It's an explicit "I'm keeping this"
  intent, so a human names it.
- **No global forced prefix.** A hard-coded `feature/` fights repos that use
  `feat/`, `username/`, or none. If a team wants a convention, it's **opt-in
  per-repo**: a `branchPrefix` key in the project-local `<repo>/.termio/` config, so
  `prefill = branchPrefix + slug(liveTitle)`, still fully editable.

### Ignored-files gap (table stakes, not gold-plating)

A fresh worktree has **no `.env`, no `node_modules`, no secrets** — so the agent's
dev server won't boot and half its commands fail. This is very likely *why worktree
creation was walked back before* (`Models.swift` says "Termio no longer creates
worktrees itself"). It must be solved for the feature to be real.

#### How the field solves it (survey)

Three strategies across the AI-agent-worktree tools:

1. **Setup/init hook re-runs the package manager** (dominant) — Conductor, Cursor
   (`.cursor/worktrees.json` `setup-worktree`), Zed (`create_worktree` hook), Claude
   Code (`WorktreeCreate` hook), Vibe Kanban, uzi. A per-repo script fires on
   worktree-create and runs `pnpm/npm/pip install`.
2. **Declarative copy of gitignored files** for `.env`/secrets — Conductor and Claude
   Code use the **identical `.worktreeinclude`** format (globs, copies only files that
   are *both* matched and gitignored).
3. **Container/image-baked env** — Sculptor, container-use (sidesteps worktrees).

One trap the field warns about:

- **Symlinking `node_modules` is a trap** (Cursor explicitly discourages it): breaks
  on dependency drift, Node realpath resolution (Vite/Vitest), native addons, and
  **pnpm refuses to install into a symlinked `node_modules`**. Never automate it.

#### Termio's approach — the field minimum, and that's it

Match the proven, low-surface-area answer everyone converged on. No cleverness:

- **`.worktreeinclude`** — adopt the *exact filename/format* Conductor + Claude Code
  use, for free interop (a repo already carrying one Just Works). Copies `.env` &
  small gitignored config into the new worktree. Never propagate prod secrets (skip
  `.env.production`).
- **`<repo>/.termio/setup.sh`** hook, run after the copy, with `TERMIO_WORKTREE_ROOT`
  + `TERMIO_MAIN_ROOT` env vars (mirrors Zed/Conductor). The user puts `pnpm install`
  / `npm ci` here. This alone is *correct for every ecosystem*.

That's the whole design. It's already fast where the package manager has a global
store (**pnpm/uv** hard-link from it; pnpm's `enableGlobalVirtualStore: true` is
purpose-built for multi-worktree agents). **npm / yarn-classic** re-install is
inherently slower (no global store) — we accept that; the fix is "use pnpm/uv," not
more machinery in Termio.

#### Rejected: copy-on-write (APFS `clonefile`) of `node_modules`

Considered and **rejected** (2026-07-06). Termio is macOS-native on APFS, so it
*could* `clonefile`-clone `node_modules` to make npm/yarn setup near-instant — and no
competitor ships this. But it was cut deliberately:

- It's a **pure speed optimization for npm/yarn only** — pnpm/uv already solve it, so
  the payoff is narrow.
- It drags in real surface area and edge cases: APFS-only + same-volume guards,
  non-APFS/cross-volume fallbacks, per-ecosystem branching, and a follow-up `npm ci`
  to reconcile the cloned tree against the branch's lockfile anyway.
- The whole field settled on "just a hook" for a reason. A setup hook is *correct and
  complete*; CoW is complexity in the name of speed the user chose not to carry.

Do **not** re-propose CoW without a concrete, measured npm/yarn pain point that pnpm
migration can't solve.

### Hand-off / merge-back (was undesigned — the real gap)

Both docs covered *deleting* a worktree but never *getting the work back out*. Two
field models:

- **Conductor:** the branch is real; you `commit → push → open PR → merge`, then
  **archive** (delete the dir + run the archive hook). Merge-back is just normal git.
- **Air:** the isolated branch stays isolated; you pull it into your real checkout via
  an explicit gate — **"Apply Locally"** (copies the branch's changes in as
  *uncommitted* working-tree changes) or **"Checkout Branch Locally"** (checks the
  branch out under a **`-copy`-suffixed** name, e.g. `air/feature-copy`, to dodge git's
  one-branch-one-checkout rule). Air's model avoids the branch-in-two-places error *by
  construction*.

**Termio recommendation:** since Termio starts **detached** (no branch), the natural
hand-off is Air-shaped — a session action **"Bring changes to <main-checkout>"** that
either (a) `git -C <main> checkout <sha> -- .`-style applies the worktree's diff as
uncommitted changes into the primary checkout, or (b) if a branch was materialized,
checks it out in the main checkout (suffixing `-copy` on the one-checkout conflict).
Full PR flow is just "commit + push from the session's terminal" — no bespoke UI
needed; Termio *is* a terminal. Ship (a) first (matches the "mostly disposable,
occasionally graduate" reality); (b) when branch-materialization lands.

### Cleanup / retention

- On session removal → ask "also remove this worktree?" (`git worktree remove`,
  refuse if dirty, then `git worktree prune`). Uncommitted work belongs to the
  folder (per the IA doc's rule 1), so never remove silently.
- **Pre-delete cleanup hook** — Conductor's `archive` / Air's `cleanup` both run a
  user script *before* the dir is removed, to tear down resources living outside it
  (DBs, containers, dev servers). Pairs with the create-time `setup.sh`;
  `<repo>/.termio/cleanup.sh` with the same `TERMIO_WORKTREE_ROOT` env. Defer, but
  design the setup hook so its teardown twin drops in symmetrically.
- Bounded retention (keep N most recent, pin exemptions) mirrors Codex. **Phase
  this**, and honestly: plain retention (remove old *clean* worktrees) is cheap;
  Codex's *snapshot-before-delete* of dirty ones is real engineering — ship
  retention-of-clean first, add snapshotting when the flow is trusted.

### Parallel-agent hygiene: port collisions (Termio's own thesis)

Termio's reason to exist is *many agents at once*; N worktrees each booting a dev
server on the same port collide. **Conductor's fix:** reserve a 10-port block per
worktree and expose it as `CONDUCTOR_PORT`..`+9`, plus a `run_mode`
(`concurrent`/`nonconcurrent`) guard. Termio's equivalent: hand the `setup.sh`/session
env a `TERMIO_PORT` (base of a reserved block, allocated per live worktree) so a
project's `dev` script can bind `$TERMIO_PORT` instead of a hard-coded 3000. Small,
optional, but it's the difference between "5 agents" working and "5 agents" all
fighting for `:3000`. Defer to when multi-worktree is actually in daily use.

## Implementation touchpoints

Existing plumbing already honors worktrees end-to-end (see IA doc); creation is
mostly UI + one git command + setting a field:

- `SidebarView.swift` `projectMenuItems` (~L121) — add "New Worktree Session…".
- `TermioStore+ProjectActions.swift` `addSession` (~L6) — add optional
  `worktreePath:` param.
- New `TermioStore` method — `git worktree add --detach` into `~/.termio/worktrees/`,
  copy `worktreeinclude` globs, then `addSession(worktreePath:)`.
- Session action "Create branch…" — `git switch -c`, prefill from `liveTitle`.
- `BranchModel` / `syncWatchedFolders()` — already auto-picks-up the new folder; no
  change.

## Open decisions

1. Retention default N (Codex uses 15) and whether to ship any retention in the
   first cut, or rely on manual "remove worktree?" on session close only.
2. Whether `.worktreeinclude` + `setup.sh` land with the first cut or a fast-follow
   (leaning: with the first cut — without them the feature is half-broken).

### Resolved (2026-07-16)

- **Row label** = the **live branch** (from `BranchModel`), which — see the branch
  reversal below — is now always a real name, so the label is consistent with the
  inspector chip and the shell prompt.
- **Creation model** = **empty-then-fill** via a stored `Project.worktrees` entity, not
  create-with-session. See the IA doc's *Storage* and *Behavior* sections.

### Reversal: create on a named branch, not detached (2026-07-16, supersedes *Branch: detached HEAD first*)

The *Branch* section above chose `git worktree add --detach` (materialize a branch only
on intent). Shipping it exposed a concrete UX bug: a **detached HEAD has no name**, so
the same worktree was labelled three different ways — the sidebar node showed the folder
name (`feedar-worktree`), while the inspector branch chip and zsh's own prompt showed the
commit SHA (`563b5e2`). The shell prompt is unreachable from Termio (zsh reads `HEAD`
itself), so the *only* way to make all surfaces agree is a real branch.

Now: `git worktree add -b <name> <path> HEAD`, where `<name>` is the worktree's
(collision-guarded) dir name. This costs the "no branch pollution" property the detached
model bought, reclaimed two ways: (1) `uniqueBranchName` bumps a `-2`/`-3` suffix so a
pre-existing branch never blocks creation; (2) `removeWorktree` best-effort `git branch
-d` (safe delete — refuses unmerged work, so nothing is lost) tidies the branch when the
worktree is removed. The one-branch-one-checkout lock never applies, because the branch
is freshly created, not an existing one checked out elsewhere.
