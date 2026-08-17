---
title: Session deep links (termio:// addresses)
status: draft
type: design
created: 2026-08-01
updated: 2026-08-01
---

# Session deep links (termio:// addresses)

> One address format for a session — pasteable into an agent prompt, clickable
> on this Mac, and (with the termiod refactor) shareable to another machine.

## Why

The CLI handle `<agent>@<shortid>` bakes mutable state into the address: a
session promotes (`terminal@x` → `claude@x`) and every previously copied handle
dies. And a bare short id pasted into an agent conversation is noise — the agent
can't tell what it names or which tool to reach for. A URL is self-describing:
the scheme says what it is and implies how to act on it.

Principle: **the address names the container (the pane/session id), never its
contents** (agent kind, title, status — all mutable). Anything already written
down must survive promotion, demotion, rename, and self-update relaunch.

## Grammar

```
termio://[<endpoint>]/session/<uuid>[?k=<token>]
```

| Form | Meaning |
| --- | --- |
| `termio://session/<uuid>` | Session on **this** Mac's Termio (the reserved authority `session` marks the local shorthand). |
| `termio://<host>[:<port>]/session/<uuid>` | Session hosted at a termiod endpoint. Opening it attaches remotely — same principle as the remote-terminal refactor: the session's home is an endpoint, not "this Mac". |
| `https://<endpoint>/session/<uuid>#k=<token>` | The **share** artifact (slice 3). Humans share https, never a custom scheme — previewable, clickable without Termio installed; the endpoint page hands off to `termio://` when the app is present. The capability rides in the *fragment*: browsers never transmit `#…`, so the token stays out of relay/tunnel logs (sshx's zero-knowledge link pattern). |

- Generated links carry the **full lowercase UUID** (a shared link must stay
  unambiguous forever). Resolvers additionally accept an 8+ char id prefix.
- The dev channel registers `termio-dev://` (same `AppChannel.suffix` mechanism
  as ports/dirs) so dev and release never fight LaunchServices. Parsers accept
  either scheme; the app only claims its own.

## Resolution

Every CLI verb that takes a target accepts:

1. `termio://…/session/<uuid-or-prefix>` — canonical
2. bare id — full UUID or unique prefix (git/docker style)
3. display title — existing fallback, unchanged

The old `<agent>@<id>` handle is gone entirely — output and input. It baked
mutable state (the agent kind) into the address, so every copied handle died
on promotion; and since the handle era never shipped alongside links, there
was no external consumer to stay compatible with — removing the parse was a
free clean break.

`sessions list --json` gains a `link` field (canonical local link). The text
output keeps the compact short-id rows for scanning; the copyable canonical
form comes from `link` and the sidebar's **Copy Session Link**.

Clicking a link (`application(_:open:)`):

- local form → focus that session (existing `focus` verb semantics)
- endpoint form → hand off to the termiod attach client (until that lands: log
  and ignore, documented here as the seam)

## Slices

1. **Now (this doc's companion change)**: resolver acceptance, `link` in list
   JSON, sidebar "Copy Session Link", `CFBundleURLTypes` registration
   (+ dev-channel rewrite in `build-app.sh`), click-to-focus for the local form.
2. **termiod refactor**: endpoint-form open → remote attach; session identity on
   the daemon side reuses the same UUID so links are location-transparent.
3. **Sharing**: "Copy Share Link" as a distinct, consent-bearing action that
   embeds the reachable endpoint and mints a `#k=` capability token on the
   https form. Requires relay/tunnel reachability; out of scope until (2)
   ships. Link durability equals authority durability — quick-tunnel hostnames
   are ephemeral, so share links require a *registered* name (named tunnel /
   tunelo subdomain), the same durability move as tmate `-n` and VS Code
   tunnel machine names.

## Prior art (2026-08 survey)

- **Custom schemes are never the shared artifact.** Warp shares
  `https://app.warp.dev/session/<id>` and keeps `warp://` for local actions;
  VS Code shares `vscode.dev/tunnel/<machine>/<path>` and keeps `vscode://`
  for handoff; Zoom shares https and hands off to `zoommtg://`. Termio
  follows: `termio://` is the local/agent/scripting hop, https is the share.
- **Session id lives in the path** everywhere modern: sshx `/s/<id>`, tmate
  `/t/<token>`, Warp `/session/<id>`, vscode.dev `/tunnel/<machine>`.
  (Codespaces uses subdomains for browser-origin isolation — worth
  remembering if termiod ever serves per-session web views on one origin.)
- **Secrets: fragment > path > query.** sshx puts the E2EE key in `#…`
  (never sent to the server); Jupyter's `?token=` is the logged-everywhere
  cautionary tale; every post-2000 protocol spec deprecates `user:pass@`.
- **Classic schemes carry no session identity at all** (ssh/telnet/vnc name
  endpoints; RDP hides reconnect in a broker cookie; mosh's session *is* a
  bearer key, hence unshareable). The one credential-adjacent thing that
  belongs in an address is server-identity pinning (ssh `;fingerprint=`,
  vnc `IdHash`) — a candidate `#fp=` addition when share links ship.
- **Stable id + friendly name dual** (tmux `$id` vs fuzzy names, added after
  scripts broke on fuzzy matching): the id form is canonical, names are
  display sugar — matches this design's uuid-canonical rule.

## Migration notes

- **The `<agent>@<id>` handle is removed from every output surface**
  (2026-08-01): list text/JSON, spawn/send/read/close/focus/wait replies,
  watch events (text + JSON), the caller envelope, and the installed
  CLAUDE.md instruction block all speak `termio://session/<uuid>` now.
  `sessionHandle` is deleted.
- Input stays tolerant forever: the resolver still parses `<anything>@<id>`
  (name half ignored), bare ids, prefixes, and titles.
- The instruction block self-heals into the shared `~/.claude/CLAUDE.md` on
  sync, from either channel. Until a release build ships this change, agents
  driving the *release* app should use the bare-id form the new instructions
  also permit — old resolvers accept ids/prefixes, just not links.
