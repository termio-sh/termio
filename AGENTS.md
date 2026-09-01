# AGENTS.md

This file provides guidance to AI coding agents working in this repository.

## Core rules

- termio is a deliberately small, focused tool. Keep the surface area minimal;
  prefer clarity over cleverness. Do not add features that were not requested.
- Keep changes scoped to the request. Do not refactor unrelated code.
- Respect existing worktree changes. Do not revert the user's edits unless asked.
- Prefer editing existing files over creating new ones. Do not add new
  documentation files unless requested.
- Commit or push only when the user asks.
- Never add an SPM dependency that ships resources — see "Dependencies" below.
  This has shipped as a release-only crash twice.
- Read `CONTRIBUTING.md` for the long-form version of the build, branching, and
  release flow. This file is the short, agent-facing subset.

## Repo overview

termio is a native macOS terminal app for AI coding agents: Swift +
AppKit/SwiftUI on top of **libghostty** (Ghostty's terminal core). It is free
software with no backend, no account, and no license server.

- `Sources/termio` — the macOS app (SwiftPM executable target). Organized by
  feature: `Terminal`, `Sidebar`, `TermioStore`, `Agents`, `Companion`, `Git`,
  `FileBrowser`, `Editor`, `Issues`, `Settings`, `Welcome`, `Info`,
  `CommandPalette`, `Keybindings`, `Browser`, `Theme`, `App`.
- `Shared/` — SwiftPM package (`TermioShared`) shared by the Mac app and the iOS
  companion. The companion wire protocol lives here so both ends stay in sync.
- `ios/` — the iOS companion app (`TermioMobile.xcodeproj`, scheme
  `TermioMobile`).
- `web/landing` — the marketing site (Next.js + Tailwind + shadcn/ui), deployed
  to Vercel.
- `scripts/` — `build-app.sh` (packages the `.app`), `termio` (the CLI that
  drives a running app over its control socket), plus icon and stats helpers.
- `packaging/` — `Info.plist`, entitlements, icon assets for the bundle.
- `docs/` — design docs, RFCs, runbooks, bug handoffs, essays. See "Docs" below.
- `skills/` — agent skills. See "Skills" below.

## Setup

macOS 14+ and Swift 6 (Xcode 26). No `zig` toolchain is needed: libghostty
ships as a prebuilt `GhosttyKit.xcframework` through the
[termio-sh/libghostty-swift](https://github.com/termio-sh/libghostty-swift)
package. Do not try to build Ghostty from source in this repo.

## Common commands

```sh
swift build                                # resolve + compile
swift run                                  # launch the bare binary
swift test                                 # run the unit tests
./scripts/build-app.sh                     # ad-hoc-signed .app → ./termio.app
TERMIO_CHANNEL=dev ./scripts/build-app.sh  # side-by-side dev app → ./termio-dev.app
./ios/dev-run.sh                           # build + install iOS app on the device
cargo build --bin termio                   # (in termiod/) the Rust CLI, for checkout use
```

termio is a real foreground AppKit app bootstrapped by an explicit
`NSApplication` in `Sources/termio/App/App.swift`, not the SwiftUI `App`
lifecycle. Run it from a macOS GUI session.

Use the dev channel whenever a released termio is installed: it gets its own
bundle id (`sh.termio.app.dev`), state dir (`~/.termio-dev`), companion port
(8788), and `termio-dev` CLI, with no Sparkle update feed, so it can never
auto-update itself onto the release channel.

The `macos-rebuild-dev` and `ios-rebuild-dev` skills wrap the rebuild-and-
relaunch loop; prefer them over hand-rolling the commands.

## Validation workflow

- `swift build` is the baseline check for any Swift change.
- `swift test` for changes to the units that have coverage — split-tree layout,
  OSC parsing, stall probing, Markdown/HTML rendering, git service, editor text.
- Behavior that only shows up on screen (layout, spacing, focus, terminal
  repaint) needs a real run. Rebuild the dev app, then use the
  `app-screenshot-debug` skill to capture and read back the window.
- Do not screenshot the app yourself by other means, and never claim a UI change
  works without having seen it.
- Task notifications never fire from a dev build. Verify those on a release
  build only.

## Architecture notes

Terminal core:

- libghostty exposes two backends: `.exec` runs a PTY inside ghostty;
  `.inMemory` is host-managed. termio uses **`.inMemory`** — the app owns the
  PTY via `Sources/termio/Terminal/Ghostty/PTYProcess.swift` and the surface only
  renders.
- The PTY is spawned with `forkpty` (login_tty shape). Do **not** switch to
  `posix_spawn`: that shape breaks agents' resize repaint. See
  `docs/bug/terminal-resize-no-reflow-HANDOFF.md`.
- PTY writes must stay non-blocking. A blocking write under the surface lock
  beachballs the app.
- One `TerminalViewState` (`Sources/termio/App/Models.swift`) owns one surface.
  `TermioStore`'s SurfaceCache keeps it alive across view rebuilds so shells
  survive session switching.
- Changes to libghostty itself go to the fork as rebased patch files, not here;
  termio then bumps the package version in `Package.swift`.

State and sessions:

- `TermioStore` is the app's store, split across `TermioStore+*.swift` by
  concern. `StateFile` owns the on-disk snapshot — only the session tree,
  selection, and inspector layout persist. Live state is never written; shells
  restart fresh.
- Sessions are addressed by `termio://session/<uuid>` deep links. The `agent@id`
  addressing scheme is dead.
- The `scripts/termio` CLI talks to the running app over a local control socket.
  `termio agent report` is the public hook contract agents call to report
  working / waiting / done.

Companion:

- The Mac serves the iOS app over a WebSocket; the wire protocol is in
  `Shared/Sources/TermioShared/WireProtocol.swift`. The mirror is a live
  surface, not a screenshot feed.
- The Usage tab reads each agent through a `UsageProvider`
  (`Sources/termio/Companion/Usage/`) — one file per agent, holding its
  credential read, its plan-limit endpoint, and its session-log scanner.
  `UsageMonitor` knows only the list, so supporting another agent is a new
  provider file plus a line in `UsageMonitor.providers`, not an edit threaded
  through the fetch and scan paths. Only agents whose CLI leaves a usable
  credential on disk qualify; termio never runs a login flow.

## Where to work

- `Sources/termio/Terminal` — surfaces, splits, panes, link opening.
- `Sources/termio/TermioStore` — session tree, persistence, split groups,
  agent status.
- `Sources/termio/Agents` — agent manifests, session control, hook contract.
- `Sources/termio/Companion` — companion server, tunnel, per-agent usage
  providers.
- `Shared/` — anything both platforms must agree on. Changing the wire protocol
  means changing both ends.
- `web/landing` — marketing copy and site. See `docs/ARCHITECTURE.md`.

## Testing

- Tests live in `Tests/termioTests/` and run with `swift test` from the root.
- Coverage is deliberately narrow: pure logic with a real failure mode
  (`SplitTreeTests`, `OSCProgressScannerTests`, `StallProbeTests`,
  `MarkdownHTMLTests`, `GitServiceScaleTests`, `EditorTextTests`,
  `InstallFeedbackTests`). Add a test when the logic is testable without a
  window; do not stand up UI test scaffolding to hit a coverage number.

## Skills

- Canonical agent skills live in `skills/`.
- `.claude/skills` and `.agents/skills` are symlinks to `../skills`. Keep
  `skills/` as the source of truth and do not duplicate a skill per agent.
- Skill folders are `skill-name/SKILL.md` with YAML frontmatter containing at
  least `name` and `description`. Put scripts, references, and assets inside the
  skill's own folder.
- Third-party skills vendored from other repos are recorded in
  `skills-lock.json` with their upstream source and hash. Do not hand-edit them;
  re-pull from upstream instead.
- Skills that encode this repo's workflows, by area:
  - Build & run: `macos-rebuild-dev`, `ios-rebuild-dev`, `app-screenshot-debug`
  - Release: `bump-version`, `check-ghostty-update`, `testflight-release`
    (iOS beta builds), `asc` (App Store Connect)
  - Repo hygiene: `conventional-commit`, `doc`, `issue-creator`
  - Writing: `review-copy` (scores copy against `VOICE.md`)
  - Web/landing: `og-generation`
  - Research: `dia-source-analysis`
- Vendored design/UI skills (emilkowalski pack, keep upstream names):
  `apple-design`, `emil-design-eng`, `prototype`, `pick-ui-library`,
  `animation-vocabulary`, `find-animation-opportunities`, `improve-animations`,
  `review-animations`.

## Code conventions

Swift:

- Prioritize correctness and clarity over micro-optimization.
- No force-unwraps (`!`) or anything that traps. Use `guard let` / `if let` and
  surface failures instead of crashing.
- Never silently discard an error. Handle it, log it, or propagate it.
- Comments explain *why*, not *what*. No summary or organizational comments.
- Full words for names, no abbreviations.
- Prefer adding to an existing file over creating many small ones. A new file is
  for a genuinely new component.

Dependencies and vendored code:

- Be conservative about new SPM dependencies, and **never** add one that ships
  resources: plain `swift build` bakes a `Bundle.module` accessor that only
  checks the `.app` root and a build-machine path, so CI-built releases crash at
  runtime even when local dev builds work. Vendor such code instead, the way
  `Sources/termio/Editor/Highlightr/` does — upstream license in a vendor
  `README.md`, lookups through `Bundle.termioResources`, deviations listed in the
  file header.
- A local build working is not evidence. Verify resource-touching changes
  against a packaged `.app`.

## Writing style

`VOICE.md` at the repo root is the full guide — read it before writing anything
a user reads (UI strings, landing copy, docs, release notes, issues, PR bodies).
The `review-copy` skill scores copy against it. The rules below are the ones you
must not get wrong even if you never open it.

- Direct, concrete language. No AI attribution anywhere — not in commits, PR
  descriptions, issues, docs, or release notes.
- UI copy follows Apple's conventions: one-sentence subtexts that say what a
  control does, not essays about mechanism.
- Split panes use "Group with" / "Ungroup" / "Close Session". "Close Pane" and
  "Unsplit" are dead vocabulary.
- termio is **free**. Never describe it, in any copy, as paid or trial-limited.
- GitHub issue and PR comments are one clean line, not essays.

## Git and PR notes

- Trunk-based: `main` is the single trunk. Branch off the latest `main` as
  `feat/…`, `fix/…`, or `chore/…`, keep it short-lived, and open a PR against
  `main`. For a substantial feature, use a worktree:
  `git worktree add ../termio-worktrees/<slug> -b feat/<slug> main`.
- Commits follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/):
  `type(scope): imperative, lowercase summary`. Use the `conventional-commit`
  skill.
- No `Co-Authored-By` trailers. Never add yourself or an AI tool as a co-author.
- PR titles are imperative and correctly capitalized, with **no**
  conventional-commit prefix and no trailing punctuation. Include a
  `Release Notes:` section in the body.
- Never rewrite pushed history on `main`: the release build number is
  `git rev-list --count HEAD`, and Sparkle treats a lower build number as older,
  which breaks auto-update.

## Docs

- Everything under `docs/` carries YAML front matter (`title`, `status`, `type`,
  `created`/`updated`). The front matter is the single source of truth for a
  doc's status.
- The index table in `docs/README.md` is generated from that front matter. Do
  not edit it by hand — use the `doc` skill, which writes the front matter on
  create and regenerates the index.

The user-facing docs site is `web/landing/content/docs`, and three things there
are derived rather than written:

- **The shortcut tables** come from `KeyCommandCatalog`. Change a binding in
  Swift, then `pnpm keybindings:sync` in `web/landing`. Never restate a shortcut
  by hand — the page renders `<Keybindings category="…" />` from the generated
  JSON.
- **The translations** (`<page>.<locale>.mdx`) are made from the English page and
  record which revision they came from. After editing an English page, retranslate
  it and re-run `pnpm docs:stamp`; anchors that other pages link to carry an
  explicit English id (`## 状态 [#status]`) so a link works in every language.
  Locale wording follows `content/docs/.i18n/glossary.<locale>.json`, which tracks
  the app's own localized UI strings.
- **The changelog** (`src/data/changelog.ts`) must cover the newest release tag.

`pnpm docs:check` enforces all three, and the `Docs` workflow runs it.

## Releases

Releases are cut by pushing a version tag; nothing in the repo needs editing.
The tag is the version (`v0.3.0` → `CFBundleShortVersionString = 0.3.0`) and
`.github/workflows/release.yml` handles signing, notarization, the DMG, the
Sparkle appcast, and the GitHub Release. Use the `bump-version` skill. Details
and the manual verification checklist live in `docs/RELEASING.md` and
`docs/runbook/macos-release-runbook.md`.
