---
title: "RFC: Per-project agent sandbox (Apple Seatbelt)"
status: draft
type: rfc
created: 2026-06-30
updated: 2026-06-30
related:
  - 20260629-sandbox-vm.md
  - 20260707-agent-extensibility.md
---

# RFC: Per-project agent sandbox (Apple Seatbelt)

> Confine each sandboxed project's agent sessions to the project folder using a
> host-side Apple Seatbelt profile — no VM, no daemon, no disk — so a rogue or
> prompt-injected coding agent cannot read SSH keys, the Keychain, or the rest of
> the user's machine.

## Summary

Termio runs coding agents (Claude Code, Codex, OpenCode, Pi) in terminal sessions.
A project can opt into a **sandbox**: every session of that project runs as a normal
host process wrapped in an Apple **Seatbelt** profile (`sandbox-exec -f`). The
project directory stays read-write, system paths stay readable, and everything else
— SSH keys, the login Keychain, the rest of `~`, cloud credentials, browser data —
is invisible. Because Seatbelt restrictions are inherited across `fork`/`exec` and
can only tighten, the profile confines the **agent process itself and its whole
subtree**, not just the commands the agent chooses to run.

This RFC supersedes the micro-VM design in [[sandbox-vm.md]].

## Motivation

The original design (see [[sandbox-vm.md]]) ran each project's sessions inside a
per-project Linux micro-VM via `apple/containerization`. It worked end-to-end but
the cost was enormous, and almost all of it existed **only because the agent lived
across a VM boundary from the terminal**:

- a serve/attach daemon + socket→PTY byte-pump (the VM broke libghostty's native `.exec`);
- copy-on-write credential cloning + a Keychain→file bridge + transcript sync-back;
- a 16 GiB rootfs per project, orphan-cleanup signal handlers (VMs leaked);
- a `com.apple.security.virtualization` entitlement that broke `swift run`, a macOS-26
  floor, and a vmnet bug under `~/Documents`;
- the hook/control plane (`HookListener`, `SessionControl`, `termio sessions`) broke
  inside the VM and needed a "Phase 2 socket bridge".

Studying `nolabs-ai/nono` (a zero-VM agent sandbox: macOS Seatbelt, Linux Landlock+seccomp)
made the reframe obvious: **the VM was the wrong axis for a terminal app.** Seatbelt
keeps the agent a host process (PTY stays native), costs ~0 (no boot, no disk), and
fully covers Termio's actual threat model. Every line in the list above disappears.

## Threat model

**In scope.** A coding agent that goes rogue on the user's own machine: prompt
injection causing `rm -rf`, `curl … | sh`, reading `~/.ssh` / cloud creds / the
login Keychain and exfiltrating them, or writing outside the project. This includes
the agent's *own* non-Bash tools (e.g. a file-read tool) and any subprocess it spawns
— Seatbelt confines the entire process tree, which an agent's *own* sandbox does not
(that only gates its Bash tool).

**Out of scope.** A macOS kernel privilege-escalation exploit chained by the agent to
escape Seatbelt. A VM is a stronger boundary here, but this is not Termio's threat
model — and the defense would fail anyway the moment the user pastes the agent's output.

## Design

### One enforcement layer, owned by Termio

macOS **forbids applying a second Seatbelt sandbox inside an existing one** (verified:
nested `sandbox-exec` fails to initialize). Both Claude Code and Codex sandbox their
own Bash execution via Seatbelt. Therefore the agent **must be told to stand down its
own sandbox** so Termio's outer profile is the single layer — this is required, not an
optimization. Termio's outer profile already covers every Bash command the agent runs
(inheritance), *plus* the agent process itself, so nothing is lost.

Per-agent stand-down (`AgentPreset.sandboxStandDownArguments`):

- Claude Code → `--settings '{"sandbox":{"enabled":false}}'` (inline JSON, overrides
  user settings for the session, no file written — verified).
- Codex → `--sandbox danger-full-access`.

Approval prompts (`--dangerously-skip-permissions` etc.) are an **orthogonal** knob and
are not touched by sandboxing.

### The chokepoint

The entire integration is one place — `TermioStore.surface(for:in:)` — the same spot
the VM used. When `project.sandbox != nil`, the session's PTY command is wrapped:

```
sandbox-exec -f <profile.sb> <login-shell> -lc '<agentCommand + standDown>'
```

The profile rides in a **temp file** (`-f`), not inline (`-p`), so its parentheses,
quotes, and newlines never have to survive however libghostty tokenizes the command
string. `SandboxLauncher` writes/cleans the per-session `.sb` file. libghostty stays
oblivious; the PTY stays native `.exec`; hooks and the control plane work again because
the agent is a host process (`TERMIO_SESSION` is now always set).

### The profile compiler

`SeatbeltProfile.compile(SandboxProfile, workspacePath:) -> String` emits SBPL. The
allow/deny baseline is lifted from nono's `policy.json` groups (Apache-2.0; credit in
`NOTICE`). Key properties:

- `(deny default)`; the workspace is the only writable user path; system trees are read-only.
- **Security denies are emitted LAST** so they override the broad allows ("last matching
  rule wins"): `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/Library/Keychains`, browser data, etc.
- **Keychain-via-Mach-IPC leak plugged**: `(deny mach-lookup …)` on `com.apple.secd` /
  `keychaind` / `security.agent` — a file-level deny on `~/Library/Keychains` is otherwise
  bypassable via Mach IPC. *(See open question on auth.)*
- **DYLD injection guard**: `file-map-executable` is scoped to trusted read-only trees.
- `.env` / `.env.*` denied **even inside the writable workspace** (toggle), proving the
  deny-inside-allow override works. Writes to `.env` stay allowed (scaffolding).

**Canonicalization gotcha (fixed):** Foundation's `resolvingSymlinksInPath()` *strips*
`/private` (`/private/var/folders/…` → `/var/folders/…`), but Seatbelt matches against
the physical path. The workspace `subpath` never matched → all writes denied. Fix:
`realpath(3)`.

### Verification

`scripts/seatbelt-smoke.sh` and an end-to-end run of the real `SandboxLauncher` output
(through a shell) confirm: workspace read+write OK, `/etc` readable, `~/.ssh` / Keychain
/ in-workspace `.env` denied, `.env` write allowed, and the double-quoting chain delivers
the stand-down JSON to the agent as one clean argv token. Real `claude` / `codex` accept
their stand-down flags (exit 0).

## Configuration model

The per-project config is a **JSON file at `<project>/.termio/sandbox.json`** — the
source of truth — with the Security panel as a view over it.

- **JSON, not TOML.** `SandboxProfile` is already `Codable` → native `JSONEncoder`/
  `Decoder`, **zero new dependency** (TOML has no Foundation parser; we just removed all
  VM dependencies). Optional JSONC (`//` comments via a ~15-line stripper, as nono does)
  if power-users want to annotate.
- **In-repo, so it travels with the project** and is team-shareable (nono's "fork the
  config, share it" model), git-diffable.
- **⚠️ The file is read-only inside the sandbox.** The workspace is writable, so an agent
  could otherwise rewrite `.termio/sandbox.json` to widen its own jail — the same class
  of hole as a writable `.git/hooks` or `.mcp.json`. `.termio/` goes in the deny-write
  baseline. Non-negotiable while the file is in-repo.
- Source of truth = the file; `Project.sandbox` is the in-memory mirror loaded on open.
  `enabled` (or file presence) gates the sandbox.

```jsonc
// .termio/sandbox.json — this project's agent sandbox (read-only to the agent)
{
  "enabled": true,
  "workspaceReadOnly": false,
  "network": "full",
  "blockDotEnv": true,
  "read":      ["~/.config/mytool"],
  "readWrite": ["~/.cache/myproj"],
  "deny":      ["src/secrets"],
  "allowSSH": false,
  "allowFullHomeRead": false
}
```

## UX — the Apple lens

The Security panel (right-click project → "Security…", or the "Sandbox" pill) is a direct
view over `SandboxProfile`. Keep it **visually simple** (Apple's data-minimization pillar):
sandbox on/off, workspace editable, hide `.env`, allow SSH, allow full home, network
on/off, with the baseline (Keychain, all of `~`, browser data, hardening) handled
invisibly. A top-tier Apple design would add, **without** turning it into a matrix:

1. **User intent = the grant.** Custom paths are added via "+ Add Folder…" → `NSOpenPanel`
   → a **security-scoped bookmark**, not a text field. The act of choosing the folder is
   the permission (PowerBox pattern).
2. **Just-in-time escalation.** When a sandboxed agent hits a denied path, surface a
   contextual, agent-named prompt ("*Claude Code wants to read ~/.aws* — Allow once /
   Always / Deny"), TCC-style, instead of upfront configuration. Technical enabler:
   **sandbox extension tokens** (`sandbox_extension_issue_file`) to widen access at runtime.
3. **Progressive disclosure.** Simple by default; "Advanced…" reveals/opens
   `.termio/sandbox.json` and a raw-SBPL appendix (`extraRules`).
4. **Make risk legible.** The off-state warning (built) + a "recently blocked" activity
   view (transparency & control).

## Open questions / hardening (from prior-art research)

These came out of studying `CJHwong/agent-seatbelt`, `webcoyote/sandvault`, Codex's
implementation, and Pierce Freeman's deep dive. Roughly in priority order:

1. **Keychain vs auth — the crux.** The baseline denies the Keychain, but Claude Code and
   Codex store their OAuth token in the macOS login Keychain → a sandboxed agent may boot
   "Not logged in", and `git push` over HTTPS breaks. Options: (a) **allow** the Keychain
   service (auth + git work; agent can read all stored passwords — agent-seatbelt's
   default); (b) **least-privilege** — keep the Keychain denied and feed the agent only
   its own token via a file (`~/.claude/.credentials.json`), with a clearly-labeled
   "Allow Keychain access" escape hatch (more Apple, more data-minimization). **Must
   verify whether macOS `claude` reads the file fallback before deciding.** This decides
   whether the sandbox is usable at all.
2. **Write-protect dangerous in-project paths.** Carve `.git` (especially `.git/hooks`),
   `.mcp.json`, `.vscode/`, `.idea/` **read-only inside the writable workspace** — an agent
   can write a malicious git hook or MCP config to escalate. (Pierce: "agents can modify
   your workspace but can't mess up your git history.")
3. **Clean the environment.** The agent can read API keys / tokens from inherited env
   vars even with files blocked. Rebuild a minimal env instead of passing the shell's.
4. **Network domain allowlist.** Seatbelt network rules are coarse (host:port only); v1
   ships on/off. Domain-level allowlisting needs a local filtering proxy (later milestone),
   not faked.

## Implementation status

- **Phase 0 (done).** `SandboxProfile` + `SeatbeltProfile.compile`; `scripts/seatbelt-smoke.sh`
  proves the denies hold.
- **Phase 1 (done).** `SandboxLauncher` + chokepoint wiring; per-agent stand-down; `realpath`
  fix; verified end-to-end.
- **Phase 2 (done).** VM substrate deleted (`sandbox-helper/`, entitlement, kernel cache,
  build-script sections). `swift run` works; app stays macOS 14; no entitlement.
- **Phase 3 (in progress).** Security panel built and visually verified (toggle, filesystem,
  secrets, network); custom-paths picker, `.git`/clean-env hardening, the keychain decision,
  and the `.termio/sandbox.json` file-as-source-of-truth are the remaining work.

## Alternatives considered

- **Keep the micro-VM.** Stronger boundary, but wrong threat model and enormous cost (see
  Motivation). Rejected.
- **Link nono's Rust C FFI.** Reintroduces a Rust toolchain + static-lib + codesign — exactly
  the build pain we removed with the VM. Rejected.
- **Bundle the `nono` binary and shell out.** Fastest spike, but a black-box external
  dependency for the core feature, and 90% of nono (Linux/Windows, registry, proxy, audit)
  is unused. Rejected in favor of a ~250-line Swift compiler that lifts only nono's
  allow/deny *data* (with `NOTICE` credit).
- **Call `sandbox_init` directly via a bundled shell.** Marginally "purer" (no dependency on
  the deprecated `/usr/bin/sandbox-exec`), but requires shipping a signed helper binary — the
  artifact we're trying to avoid. Both paths hit the same deprecated SPI underneath.
  Documented as the later hardening option.

## References

- nono — `nolabs-ai/nono` (Apache-2.0): macOS Seatbelt + Linux Landlock/seccomp; profile
  groups lifted as the baseline allow/deny data.
- `CJHwong/agent-seatbelt`, `webcoyote/sandvault` — Seatbelt sandboxing for Claude/Codex.
- Pierce Freeman, "A deep dive on agent sandboxes."
- Apple HIG — Privacy; "Accessing files from the macOS App Sandbox" (security-scoped
  bookmarks / PowerBox).
