---
title: Agent Plugins
status: draft
type: design
created: 2026-08-12
updated: 2026-08-12
related:
  - agent-extensibility.md
  - browser-cdp.md
---

# Agent Plugins

> Adopt the Agent Plugins spec so a user can install one folder and have every
> agent termio manages pick up its skills — starting with skills only, because
> the MCP half is where config-clobbering lives.

## 1. Why a standard instead of our own scheme

termio already fans out per-agent configuration: hooks are written into
`~/.claude/settings.json`, `~/.codex/hooks.json`, Cursor's flat dialect, and
plugin drop-in directories for OpenCode and Pi — all modelled by
`AgentHookSpec` + `HookDialect` in `AgentDefinition.swift`. Skills are the same
shape of problem one level up, and today every tool solves it privately: the
browser CLI ships its own `skill install` that writes into `~/.claude/skills`
and `~/.agents/skills`.

[Agent Plugins v1](https://agent-plugins.org) is a vendor-neutral format for
exactly that, with 900+ stars and an active spec repo. Adopting it means a
plugin authored for any conforming host works here, and a plugin we ship works
elsewhere.

This is not the "plugin system" argument rejected in
[browser-cdp.md §10](./browser-cdp.md). That objection was against **inventing** a
bespoke extension API for a single internal consumer. Adopting a published
standard with an existing ecosystem is a different act, and the objection does
not transfer.

## 2. What v1 actually is

Two component types, and the spec is explicit that the list is closed:

> "Agent Plugins v1 defines exactly two component types: **skills** and **MCP
> servers**. Other component types are outside the v1 format and do not affect
> conformance."

and

> "Other component types — such as commands, hooks, agents, rules, and LSP
> servers — remain too client-specific for a stable portable contract and are
> outside the v1 format until their formats converge."

Layout:

```
my-plugin/
├── plugin.json
├── skills/
│   └── <skill-name>/SKILL.md
├── mcp.json
└── LICENSE
```

`plugin.json` permits only `$schema`, `name`, `version`, `description`,
`author`, `homepage`, `repository`, `license`, `keywords`, `extensions`.
`$schema` and `name` are required. **There is no registry** — v1 is a format,
not a distribution network — so there is nothing to "browse", and install is
always from a path or a git URL.

Consequences worth stating plainly:

- termio's **hooks stay outside the spec**. `AgentHookSpec` continues to be
  termio's own concern; a plugin cannot ship hooks in v1.
- A plugin cannot ship a **CLI command**. So `termio browser` is not, and will
  not become, a plugin artifact.

## 3. Where plugins live

```
~/.termio/plugins/<name>/          # the plugin directory, spec layout verbatim
~/.termio/plugins/.state.json      # enabled flags, source, installed hashes
```

The plugin directory is stored **unmodified** — a byte-identical copy of what
was fetched. Anything termio needs to remember about it goes in `.state.json`,
never inside the plugin, so a `git pull` on a plugin installed from source is
never in conflict with our bookkeeping.

## 4. Lifecycle

**Add** — from a local path or a git URL. Validate `plugin.json` against the
1.0.0 schema before anything is copied; a manifest that fails validation is
rejected with the schema error, not partially installed.

**Enable** — fan out its components (§5, §6). Disabled is the default on add,
so adding is never the same act as granting.

**Disable** — remove what we installed, leave the plugin directory.

**Remove** — disable, then delete the directory.

Fan-out is idempotent and re-runs on launch, so upgrading a plugin (or termio)
converges without user action — the same property `BundledSkillInstaller`-style
symlinking has in prior art.

## 5. Skills fan-out — cut 1

For each `skills/<name>/` in an enabled plugin, symlink into both:

```
~/.claude/skills/<name>   →  ~/.termio/plugins/<plugin>/skills/<name>
~/.agents/skills/<name>   →  (same)
```

Symlink rather than copy, so updating the plugin updates the skill with no
second sync path.

Two directories because the ecosystem has two conventions and agents read one or
the other; writing both is what the browser CLI already does and what makes a
skill work regardless of which agent picks it up.

**Name collision across plugins** is possible — two plugins can both ship
`skills/browser/`. Reject the second at enable time with a clear message naming
the holder, rather than silently letting one win.

## 6. MCP fan-out — cut 2, deliberately

This is where the risk is. `mcp.json` is portable, but the file it must be
merged into is not: every agent keeps MCP servers in its own location and shape,
exactly as hooks do.

Reuse the existing model — a per-agent descriptor beside `AgentHookSpec` saying
where that agent's MCP config lives and which dialect it speaks — rather than
inventing a second fan-out mechanism.

Merging into a config file the user also edits is the operation that has already
bitten this project once: Superset wiped termio's hooks, and the fix was
strip-conflicts + re-assert on refocus + a version stamp. Any MCP writer must
carry that lesson from the start.

**Cut 1 ships skills only.** A plugin declaring `mcp.json` installs, and the
Settings tab shows its MCP servers as *recognised but not installed*, with the
reason. That is honest and inert; silently ignoring them is not.

## 7. Never clobber

The rule from the browser CLI's installer, corrected by review: **an ownership
marker proves origin, not absence of edits.** A file we wrote and the user then
edited must not be overwritten by a later enable, nor deleted by disable.

So `.state.json` records a content hash per installed artifact:

- hash matches → ours, untouched → safe to replace or remove
- hash differs → the user edited it → leave it, report it
- path exists but we have no record → not ours → leave it, report it

## 8. What a plugin may not do

`AgentHookSpec` already encodes the right instinct: *"The dialect chooses the
fixed filename and source shape; the manifest cannot inject code."* Extend it.

A `plugin.json` is **data**. It may not name an executable, a script path, a
postinstall step, or an arbitrary destination. Everything a plugin ships lands
in locations termio chooses, derived from the component type — never from a
string in the manifest.

The counter-example is in our own history: the browser repo's site-command
system downloads unpinned JavaScript from GitHub and executes modules through
`jiti` **merely to list them**. Enumerating available extensions should never
run third-party code. Listing a plugin reads `plugin.json` and nothing else.

MCP servers are the exception that proves it — an MCP server *is* a command the
agent will run, which is precisely why that half is cut 2 and why enabling it
must be an explicit, per-plugin act with the command shown before it is written.

## 9. The Settings tab

`PluginsSettingsTab`, beside `AgentSettingsTab`. Per row: name, version,
description, source, an enable toggle, and what it contributed — "2 skills" or
"1 skill, 1 MCP server (not installed)".

Follows the Agents tab's established grammar: **added ≠ enabled**, availability
gated on something external, and neutral rather than accent-coloured controls.

Actions: *Add Plugin…* (path or git URL), *Reveal in Finder*, *Remove*. No
browse or search, because v1 has no registry and pretending otherwise would be
inventing one.

## 10. `extensions` is the escape hatch

The spec reserves a reverse-domain namespace for client-specific data:

```json
"extensions": { "sh.termio": { } }
```

Anything termio-specific goes there and conformance is preserved. Use it
sparingly — every key added is a thing that only works here, which is the
opposite of why the standard was adopted.

## 11. Relationship to the browser work

The browser skill is the obvious first plugin: it exists, it is maintained in
another repo, and it currently ships through a bespoke `skill install` in the
browser CLI. Repackaging it as a conforming plugin dogfoods the loader against
a real case instead of a toy.

Note what does *not* move: `termio browser cdp`, the Settings gate, and the
Chrome extension stay native, because v1 has no component type for any of them.
The plugin carries the skill; termio carries the capability.

## 12. Open questions

1. **Does enabling a plugin need per-agent scoping** — this plugin for Claude
   Code but not Codex — or is global fan-out enough? Global is simpler and
   matches how hooks are installed today. Start there.
2. **Updating a git-sourced plugin**: a *Check for updates* action, or refresh
   on launch? Refreshing silently changes agent behaviour without the user
   asking, which argues for explicit.
3. **Project-local plugins** — a `.termio/plugins/` in a repo, so a project can
   carry its own. Defer; nothing asks for it yet.
4. **MCP dialect coverage** — cut 2 needs the real per-agent config shapes
   surveyed the way the hook dialects were.

## Sources

- Spec and schemas: <https://github.com/agentplugins/agent-plugins-spec>
- <https://agent-plugins.org/schemas/1.0.0/plugin.schema.json>
