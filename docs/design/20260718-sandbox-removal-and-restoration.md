---
title: "Sandbox removal & restoration (Apple Seatbelt subsystem)"
status: done
type: design
created: 2026-07-18
updated: 2026-07-18
related:
  - 20260630-sandbox-seatbelt.md
  - 20260629-sandbox-vm.md
  - 20260707-agent-extensibility.md
---

# Sandbox removal & restoration (Apple Seatbelt subsystem)

This records Termio's own per-project Seatbelt sandbox **before it was removed**, so a
future engineer can rebuild it (or, preferably, bring it back in a lighter shape — see
[§6](#6-if-we-bring-it-back-do-it-lighter)). The subsystem is being deleted, not
deprecated in place, so this doc is the map; git is the backup.

## Why it's being removed

1. **Every serious agent now ships its own sandbox.** Claude Code, Codex, and Grok all
   confine themselves; Termio wrapping a second sandbox around them is redundant and, on
   macOS, actively conflicting (you can't nest Seatbelt — hence the whole "stand-down"
   mechanism below existed only to work around a problem we created).
2. **`sandbox-exec` is deprecated by Apple.** The `SeatbeltProfile` compiler targets a CLI
   Apple has marked deprecated; betting Termio's security story on it is a dead end.
3. **It was only half-built.** There was a working profile compiler and launch wrapper, but
   the "Security panel" was a single sheet (`SecuritySheet`) with no threat model UI, no
   presets, and no per-agent policy — not a finished security surface.
4. **It over-coupled the agent abstraction to a heavy security subsystem.** `AgentDefinition`
   carried a `sandboxStandDownArguments` field purely so the launcher could tell each agent
   to disable *its own* sandbox. Security policy leaked into the agent-definition data model.

## Why it isn't the right thing to invest in *now*

The four points above are the *mechanical* reasons the current implementation had to go.
The deeper reason it isn't being rebuilt right now is a product call, not a code one:

- **The problem is already solved one layer down.** The threat this guarded against — a
  rogue or prompt-injected agent running `rm -rf`, exfiltrating `~/.ssh`/the Keychain, or
  piping `curl | sh` — is now handled by the agents themselves. Claude Code, Codex, and Grok
  each ship their own confinement. Termio spending effort here buys **~zero marginal safety**
  over what the user already gets by default; it mostly duplicates work the vendors do better
  and keep current.
- **It's a moving target we'd be chasing, not owning.** `sandbox-exec` is deprecated, the
  agents' own sandbox flags drift release to release (the stand-down strings were already
  three different dialects), and Apple's replacement story (`sandbox_init`, containers) is
  unsettled. Building on this now means signing up to re-verify a security boundary against
  a shifting substrate — the worst kind of maintenance to carry on an indie, free tool.
- **It fights Termio's whole reason to exist.** Termio is a deliberately small, focused,
  native terminal for agents (see [[ambition]]) — its edge is taste and a tiny surface area,
  not being a security product. A per-project SBPL compiler, a threat-model UI, presets, and
  per-agent policy is a *large, permanent* surface that pulls the project toward something it
  chose not to be. Saying no here is the same discipline that keeps the rest of the app sharp.
- **The cost of waiting is nearly nothing, and it's fully reversible.** Because the agents
  already sandbox themselves, there's no urgency gap to cover. If the calculus changes — a
  headline agent drops its own sandbox, or a real user asks for host-level confinement — this
  doc plus git bring it back in an afternoon, and the recommended shape ([§6](#6-if-we-bring-it-back-do-it-lighter))
  is a few lines of launch-prefix glue rather than a security subsystem to re-own.

In short: **not "sandboxing is unimportant", but "Termio owning the sandbox is the wrong
place to spend a small team's attention right now."** The right posture today is to lean on
each agent's own sandbox and keep Termio's surface small.

Restoration path: **git**. The pre-removal commit (below) contains the complete, working
implementation. Bringing it back = `git revert` / `git cherry-pick` of the removal commit,
or a fresh lighter build per [§6](#6-if-we-bring-it-back-do-it-lighter).

### Pre-removal commit SHA

```
776c280744f6c07dc961d31e95486d0e3356439f   (dev, 2026-07-18)
```

Everything described here exists in full at that commit. `git show 776c280:Sources/termio/Sandbox.swift`
recovers the compiler verbatim.

---

## 1. What the sandbox did & the per-project opt-in model

A **per-project opt-in**: a `Project` carried an optional `SandboxProfile?` (`Models.swift`).
`nil` (the default) ran the project's sessions directly on the host. A non-`nil` value ran
**every session in that project** as a normal host process wrapped in an Apple Seatbelt
profile.

Opt-in happened three ways, all landing on the same `Project.sandbox` field:

- **File ▸ Open Project Sandboxed…** → `presentOpenProjectPanel(sandboxed: true)` →
  `addProject(at:sandboxed: true)` seeded `Project.sandbox = SandboxProfile()`.
  (Note: at removal time, no menu item actually passed `sandboxed: true` — the plumbing
  existed but the only wired entry points were the panel default and the Security sheet.)
- **Right-click a project ▸ Security…** → opened `SecuritySheet`, whose master toggle called
  `setSandbox(true/false, for:)`.
- **The "Sandbox" pill** on a sandboxed project's sidebar header (a shortcut back into the
  same sheet).

Because the profile lived on `Project` and `Project` is `Codable`, the opt-in **persisted
for free** through the existing `state.json` project store. Changes applied only to sessions
opened *after* the change — an already-running session kept its cached surface — so the user
opened a fresh session to enter or leave the sandbox.

The sandbox confined the **agent's whole process tree**: Seatbelt restrictions only tighten
across fork/exec, never widen, so wrapping the session's shell confined the agent itself and
everything it spawned — not just the top-level command.

**Security posture it delivered (default profile):** project directory read-write; system
paths (`/usr`, `/System`, `/bin`, …) readable; dev caches (`~/.npm`, `~/.cache`, homebrew)
readable; temp dirs writable; **denied**: `~/.ssh`, `~/.aws`, `~/.gnupg`, gcloud/kube/docker
creds, `~/.git-credentials`/`~/.netrc`/`~/.npmrc`, the login Keychain (file **and** the
Mach services that reach it via IPC), and `.env`/`.env.*` **even inside the writable
workspace**.

---

## 2. Architecture

### 2a. `SandboxProfile` → SBPL compilation

`SandboxProfile` (in `Sandbox.swift`) was the structured, `Codable`/`Hashable` editing
surface — the thing the Security panel bound to and the thing persisted on `Project`:

| Field | Default | Meaning |
| --- | --- | --- |
| `workspaceReadOnly: Bool` | `false` | workspace read-only vs read-write |
| `network: Network` (`.off`/`.full`) | `.full` | allow/deny all network |
| `blockDotEnv: Bool` | `true` | hide `.env`/`.env.*` even inside the workspace |
| `extraReadPaths: [String]` | `[]` | extra readable trees |
| `extraReadWritePaths: [String]` | `[]` | extra read-write trees |
| `extraDenyPaths: [String]` | `[]` | extra hidden trees on top of baseline |
| `allowSSH: Bool` | `false` | escape hatch: drop the `~/.ssh` deny |
| `allowFullHomeRead: Bool` | `false` | escape hatch: read all of `$HOME` |
| `extraRules: String` | `""` | advanced: raw SBPL appended verbatim |

`SeatbeltProfile.compile(_:workspacePath:home:temporaryDirectory:)` turned that struct into
an **SBPL** (Sandbox Profile Language) string — the format `sandbox-exec -f <file>` enforces.
`home` and `temporaryDirectory` were injected (defaulting to the process's) so the output was
deterministic and testable.

Design invariants of the compiler (all load-bearing, preserve if rebuilding):

- **`(version 1)` then `(deny default)`** — deny-all baseline; every allow is additive.
- **The security baseline (credential/keychain/.env denies) is emitted LAST.** Seatbelt
  resolves to the *last matching rule*, so the denies override every preceding allow —
  including the workspace read-write allow. That's how a `.env` inside the writable
  workspace stays unreadable. A user misconfiguration in `extraRules`/`extra*Paths` can
  widen what the *user* added but can never remove the floor.
- **`file-map-executable` is restricted** to trusted read-only system trees plus the
  workspace — this is the `DYLD_INSERT_LIBRARIES` guard (no loading dylibs from arbitrary
  writable locations).
- **Keychain is denied twice** — at the file level (`~/Library/Keychains`) *and* via
  `mach-lookup` on `com.apple.secd`/`securityd`/`security.keychaind`/`SecurityServer`/
  `security.agent`, because a file deny alone leaves the IPC path open.
- **tty/pty allows** (`pseudo-tty`, `file-ioctl` on `/dev/tty` and `/dev/ttys[0-9]+`) — a
  real terminal session needs its controlling tty.

The compiler was proven end-to-end by `scripts/seatbelt-smoke.sh` (also removed), which
built the baseline profile and asserted, under `sandbox-exec`, that the workspace was
writable, `/etc` readable, and `~/.ssh` / the Keychain / a workspace-local `.env` were NOT
readable.

### 2b. The `/private` realpath handling

Seatbelt matches `(subpath …)` against the **physical** path the kernel resolves to. On
macOS, `/var` and the per-user temp dir are symlinks into `/private/var…`. So the compiler
canonicalized paths with `realpath(3)` (`SeatbeltProfile.canonical`) — **not** Foundation's
`resolvingSymlinksInPath()`, which does the *opposite* (strips `/private`) and would make the
workspace rule silently never match. `canonical` returned the input unchanged when the path
didn't exist yet (`realpath` fails on a missing path). This is the single most subtle bug in
the subsystem — preserve the comment if rebuilding.

### 2c. Applying the profile / launch-command wrapping

`SandboxLauncher.command(agentCommand:agent:profile:workspacePath:sessionID:)` built the PTY
command line:

```
sandbox-exec -f <profilePath> <login-shell> -lc "<agentCommand> <standDownArgs>"
```

or, for a plain terminal (no agent command):

```
sandbox-exec -f <profilePath> <login-shell> -l
```

Key decisions:

- **Profile rides in a file**, not inline (`sandbox-exec -f`, not `-p`), so its parens,
  quotes, and newlines never had to survive the terminal's tokenization. The file was written
  to `TMPDIR/termio-sandbox-<first-8-of-sessionUUID>.sb` by `writeProfile`, and removed by
  `SandboxLauncher.cleanUp(sessionID:)` when the surface was torn down (called from
  `closeSession` and `removeProject`).
- **If the profile file couldn't be written, `command()` returned `nil`** and the caller ran
  on the host — deliberately *never* launching a session that believes it's sandboxed but
  isn't.
- The resulting string was then handed to the normal launch path (`launchArgv`), which wraps
  ANY command in `[shell, "-ilc", "exec <command>"]`. So the sandbox line was itself run
  through the interactive-login shell that sources the user's real PATH. **This login-shell /
  PATH logic in `launchArgv` is SHARED with non-sandbox launching and was kept** — only the
  sandbox wrapping was removed (see [§4](#4-what-was-kept-shared-with-non-sandbox-code)).

Wiring in `TermioStore+TerminalSurface.swift#surface(for:in:)`:

```swift
let sandboxedCommand: String? = project.sandbox.flatMap { profile in
    SandboxLauncher.command(agentCommand: agentCommand, agent: session.agent,
                            profile: profile, workspacePath: workspacePath,
                            sessionID: session.id)
}
...
let effectiveCommand = sandboxedCommand ?? agentCommand
```

`workspacePath` was `session.worktreePath ?? restoredCwd ?? project.path` — so a session's
isolated worktree was the sandbox's writable workspace, exactly where the session works.

---

## 3. The "sandbox stand-down" mechanism

**Why it existed:** macOS forbids a Seatbelt sandbox inside a Seatbelt sandbox — a nested
sandbox fails to initialize. Modern agents (Claude Code, Codex, Grok) start their *own*
Seatbelt sandbox by default. If Termio wrapped such an agent in its profile and the agent
then tried to sandbox itself, the agent would fail to launch. So each agent had to be told,
via its own CLI flags, to **stand down its internal sandbox** — leaving Termio's profile as
the single enforcement layer. This was a **correctness requirement, not an optimization.**

The flag string lived on `AgentDefinition.sandboxStandDownArguments: String?` and was
appended by `SandboxLauncher.command()` right after the agent command. `nil` meant "this
agent has no internal sandbox, nothing to stand down."

Exact per-agent flags at removal time (`AgentDefinition.swift` built-ins):

| Agent | `id` | `sandboxStandDownArguments` |
| --- | --- | --- |
| Claude Code | `claudeCode` | `--settings '{"sandbox":{"enabled":false}}'` |
| Codex | `codex` | `--sandbox danger-full-access` |
| Grok | `grok` | `--sandbox off` |
| Terminal, OpenCode, Pi, Amp, Cursor, Kimi, Antigravity, Hermes | — | `nil` |

User agents could declare their own via `agent.json`'s optional `sandboxStandDownArguments`
string (parsed by `UserAgentManifest`).

> ⚠️ **Interaction with permission-bypass flags.** These stand-down flags are distinct from
> `permissionBypassFlag` (the "YOLO" switch, e.g. `--dangerously-skip-permissions`). Note
> that Codex's stand-down (`--sandbox danger-full-access`) and Grok's (`--sandbox off`)
> *also* weaken the agent's own confinement — which was acceptable *only because* Termio's
> profile was enforcing around them. **After removal, with no Termio profile, we must NOT
> keep injecting these stand-down flags** — doing so would leave the agent both un-sandboxed
> by Termio *and* told to disable its own sandbox = worst case. The removal drops the field
> entirely, so nothing injects them. (We also deliberately do NOT auto-inject
> `permissionBypassFlag` as a side effect of this change.)

---

## 4. Complete inventory of removed code sites

Pre-removal SHA `776c280`. `file:line` are at that commit.

### Deleted files (whole-file)

- `Sources/termio/Sandbox.swift` — `SandboxProfile`, `SeatbeltProfile` (SBPL compiler +
  `canonical`/`subpaths`/`quote`), `SandboxLauncher` (`command`/`cleanUp`/`writeProfile`/
  `profileURL`/`shellQuote`). Entire file (270 lines).
- `scripts/seatbelt-smoke.sh` — the compiler's end-to-end proof harness (sandbox-only).

### `Sources/termio/AgentDefinition.swift`

- `:25-29` — the `sandboxStandDownArguments: String?` stored property + its doc comment.
- `:62` — the `init` parameter `sandboxStandDownArguments: String?`.
- `:70` — `self.sandboxStandDownArguments = sandboxStandDownArguments` in the init body.
- `:201, 207, 214, 220, 226, 232, 240, 246, 252, 258, 270, 287` — the argument in every
  built-in definition (`terminal`, `claudeCode`, `codex`, `opencode`, `pi`, `amp`, `cursor`,
  `kimi`, `antigravity`, `hermes`, `grok`) and the `fallback(id:)`.
- `:266-267` — the Grok stand-down comment lines.
- `:582` — `var sandboxStandDownArguments: String?` on `UserAgentManifest`.
- `:645` — passing it through in `UserAgentManifest.definition(directory:)`.

### `Sources/termio/Models.swift`

- `:70-73` — the `var sandbox: SandboxProfile?` property on `Project` + doc comment.
- `:87` — the `sandbox` case in `Project.CodingKeys`.
- `:102` — `sandbox = try container.decodeIfPresent(SandboxProfile.self, forKey: .sandbox)`
  in `init(from:)`. (Removing the key means an old `state.json` with a `"sandbox"` object is
  simply ignored — Swift `Codable` drops unknown keys — so sandboxed projects reopen as
  normal projects with no migration.)

### `Sources/termio/TermioStore/TermioStore.swift`

- `:88-90` — the `@Published var editingSecurityProjectID: Project.ID?` transient UI state
  driving the Security sheet.

### `Sources/termio/TermioStore/TermioStore+TerminalSurface.swift`

- `:118-128` — the `sandboxedCommand` block calling `SandboxLauncher.command(...)`.
- `:149` — `let effectiveCommand = sandboxedCommand ?? agentCommand` → `agentCommand`.
- `:84-90`, `:104-107`, `:366-369` — comments mentioning the sandbox (updated, not the code).

### `Sources/termio/TermioStore/TermioStore+ProjectActions.swift`

- `:444-459` — `presentOpenProjectPanel(sandboxed:)` — drop the `sandboxed` param and its
  prompt/message branches.
- `:461-482` — `addProject(at:sandboxed:)` — drop the `sandboxed` param and the
  `sandbox: sandboxed ? SandboxProfile() : nil` argument to `Project(...)`.
- `:484-507` — `setSandbox(_:for:)`, `sandboxProfile(for:)`, `updateSandbox(for:_:)` — three
  whole methods.
- `:519` — `SandboxLauncher.cleanUp(sessionID:)` in `removeProject`.
- `:581` — `SandboxLauncher.cleanUp(sessionID:)` in `closeSession`.

### `Sources/termio/SidebarView.swift`

- `:262-274` — the `.sheet` presenting `SecuritySheet` (driven by `editingSecurityProjectID`).
- `:575` — the `Security…` context-menu action.
- `:623-641` — the "Sandbox" pill on the project header.
- `:1171-1301` — the entire `SecuritySheet` view (header, content, `sandboxSettings`, the
  `sandboxOn`/`bind`/`bindInverse` bindings).

### Not touched (verified unrelated)

- `Shared/Sources/TermioShared/WireProtocol.swift:81` — a comment noting the *phone* has no
  `~/.ssh`; unrelated to the Seatbelt subsystem.
- `ios/Sources/TerminalViewController.swift`, `ios/UITests/TermioMobileUITests.swift` — the
  iOS demo **`defaultSandboxShell`** is ShellCraftKit/libghostty's own sample shell, a
  different "sandbox".
- `ios/vendor/libghostty-spm/**`, `ios/build/**` — vendored libghostty (`ShellCraftKit/
  SandboxShell`), unrelated.
- `docs/design/20260630-sandbox-seatbelt.md`, `docs/design/20260629-sandbox-vm.md`, and other doc references —
  left as historical design records (this doc supersedes them for the current state).

---

## 5. Restoration = git

The removal is a single logical change on top of `776c280`. To bring the subsystem back
exactly as it was:

```
git revert <removal-commit>        # or
git cherry-pick 776c280 -- Sources/termio/Sandbox.swift scripts/seatbelt-smoke.sh
git show 776c280 -- Sources/termio/AgentDefinition.swift   # re-apply the field by hand
```

The doc commit for this file lands *before* the removal commit, so this knowledge survives
even if the removal is reverted.

---

## 6. If we bring it back, do it lighter

Do **not** resurrect the SBPL compiler as termio-owned code. `sandbox-exec` is deprecated and
owning a security-policy compiler over-couples Termio to a subsystem the agents now own
themselves. Instead:

**Expose a launch-PREFIX seam.** Let the user prepend their *own* confinement command to a
session's launch via config — Termio just concatenates it, owns none of the policy:

```jsonc
// per-project or per-agent config (illustrative — NOT built)
"launchPrefix": "sandbox-exec -f ~/.termio/my.sb"
// or a container:  "launchPrefix": "container run --rm -v $PWD:/workspace ..."
```

Termio would prepend `launchPrefix` to the resolved command inside the existing `launchArgv`
path and otherwise stay out of the way. This gives power users full reach (Seatbelt,
`sandbox-exec`, containers, `bwrap`, whatever) with **zero** security code in Termio, no SBPL
compiler to maintain, and no `sandboxStandDownArguments` coupling on `AgentDefinition` (if a
user's prefix needs the agent to stand down, they add that flag to their own agent command).

**This is a recommendation, not a task.** Do not build the seam now. Removal is removal.
