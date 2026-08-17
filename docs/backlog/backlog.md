---
title: Backlog
status: active
type: backlog
created: 2026-07-03
updated: 2026-07-16
related:
  - rfcs/fork-libghostty-spm.md
  - design/20260628-session-history-search-resume.md
---

# Backlog
https://x.com/mitchellh/status/2072724957902381319
> Deferred-but-decided work items, each with the trigger that makes it start.
> Not a wish list — an item enters only with a concrete "why" and "when".

## libghostty official packages (watch)

Mitchell Hashimoto announced (2026-07-02) a pure-Swift package family for
libghostty embedders: **GhosttyVT** (raw VT, no rendering), **GhosttyRender**
(Metal renderer, retained-frame + dirty-row tracking), **GhosttyTerminal**
(input over a reader/writer interface, PTY included). As of 2026-07-03 none are
published; the foundation (`include/ghostty/vt/render.h`, nightly signed
`ghostty-vt.xcframework` with macOS + iOS slices) is already public in
`ghostty-org/ghostty`.

- [ ] **Migrate rendering off Lakr233/libghostty-spm** when GhosttyRender /
  GhosttyTerminal ship. Expected wins: the iOS lock-contention class
  (scroll-during-output jank, the 07-03 freeze) disappears by design — render
  state only locks the terminal during `update`; redraw issues addressed by
  dirty-row retained-frame model. The official GhosttyTerminal reader/writer
  interface matches our host-PTY (`PTYProcess`) architecture directly.
  *Trigger: package repos appear (watch @mitchellh, ghostty-org).*
- [ ] **`sessions read` via ghostty-vt formatter API** — the CLI `read` op is
  stubbed ("needs a terminal-core buffer API"). `formatter.h` (plain text / VT
  / HTML export) in the official nightly xcframework is that API. Host-side
  headless VT mirror fed from `PTYProcess`'s byte stream; no rendering-layer
  changes. Keep the C binding thin — GhosttyVT will replace it.
  *Trigger: can start now; vendor a pinned nightly xcframework (tip assets
  rotate per commit).*
- [ ] **iOS local VT mirror for scroll latency** — measure how much composer
  scroll latency is WebSocket round-trip vs renderer lock contention; if the
  wire dominates, run a GhosttyVT instance on-device so scrollback lives
  locally (zero round-trip). *Trigger: after the latency measurement, and
  ideally on GhosttyVT rather than a hand-rolled binding.*

## libghostty-spm soft fork (bridge, not home)

Per `rfcs/fork-libghostty-spm.md` — Option B confirmed, executed as a bridge
until the official packages land.

- [ ] **Fork libghostty-spm and land the deadlock fix** (`receive()` releases
  the session lock before the blocking `ghostty_surface_write_buffer`), plus
  teardown hardening and a real link-delegate hook. Keep the diff minimal;
  PR every patch upstream. *Trigger: now — the freeze mitigation is
  probabilistic and the official replacement has no release date.*
- [ ] **Offer the one-line lock fix upstream first** as a cheap test of
  Lakr233's responsiveness before (or alongside) forking.
- [ ] **Restore a real vsync render loop** — `TerminalSurfaceCoordinator`'s
  `startDisplayLink()` is a stub: every frame (PTY output, scroll, momentum)
  presents through `DispatchQueue.main.async { surface.draw() }`, off the CA
  commit deadline, so iOS scroll lands a beat behind the finger. The intended
  design (the package still imports `MSDisplayLink`, names `startDisplayLink`
  / `DisplayLinkCallbackContext`) is a CADisplayLink that ticks+draws at vsync
  while input/PTY events just mark dirty. Land it in the fork and PR upstream.
  *Workaround shipped termio-side (2026-07-05, `DisplayTerminalView` in
  `TerminalViewController.swift`): ride the wrapper's scroll pan (our target
  fires after its) and drive `ghostty_surface_refresh`+`draw` synchronously on
  `.changed`, plus a momentum-tail CADisplayLink — via `@_silgen_name`, the
  same private-handle route as the mouse-pos seed. Remove once the fork's loop
  lands. Trigger: with the fork.*
- [ ] **Expose `touchScrollMultiplier` (scroll gain)** — hardcoded `3.0` in the
  package's `handleTouchScrollGesture`; if finger-to-content gain still reads
  slow after the vsync fix, make it configurable in the fork. *Trigger: only if
  the render-timing fix doesn't settle the "scroll too slow" feel.*

## Deferred designs

- [ ] **Session history / search / resume** — direction approved, design
  archived in [session-history-search-resume](../design/20260628-session-history-search-resume.md)
  (`status: approved`). *Trigger: after the current `20260628-session-share.md` mainline
  ships.*

## Agent resume identity — non-Claude agents (Phases 2–4)

Phase 1 shipped: Claude Code's resume pin (`Session.resumeID`) now advances to the
live conversation when `/clear` rotates it, via `reconcileResumeID` fed by the hook
transcript path. Design + phasing in
[agent-resume-identity](../design/20260716-agent-resume-identity.md) (`status: approved`).
The rest is gated on an audit that a first attempt couldn't complete.

- [ ] **Audit Codex / OpenCode / Pi rotation (Phase 2)** — empirically confirm, per
  agent, whether its clear/`new` command rotates the on-disk session id (and thus
  whether the resume target goes stale), and what per-session signal Termio receives
  (hook field vs scan-only). First attempt (2026-07-16) stalled: a throwaway Codex
  session driven via `termio sessions` never accepted input (stayed `idle`, wrote no
  rollout — a login/trust/model gate on TUI launch), so no rotation data was
  captured. *Trigger: when the three agents are confirmed logged-in and drivable via
  `sessions send` — or audit each by hand (launch, run its clear, `find -newer` its
  store dir) outside Termio.*
- [ ] **Generalize the pin advance to the confirmed agents (Phase 3)** — for
  filename-encoded ids (Pi, `<timestamp>_<id>.jsonl`) wire its transcript discovery
  and enable the `piStyle` case of `ResumeStyle.conversationID(fromTranscriptPath:)`.
  For in-file ids (Codex/OpenCode), `AgentSessionStore` discovery today binds to the
  **earliest** session after launch (`bestMatch`) to avoid grabbing a sibling
  session's file; advancing it to the live session needs a sibling-safety guard
  (agent-reported id, or cwd-match + single-candidate) rather than a blind
  earliest→newest flip. *Trigger: for each agent the Phase 2 audit shows actually
  rotates — and only those.*
- [ ] **Reopen-before-hook safety net (Phase 4)** — if a tab is closed after `/clear`
  but before any hook advanced the pin, `resolveLaunch` still resumes the stale id
  (the pre-`/clear` `.jsonl` survives, so `pinnedConversationExists` stays true).
  Razor-thin window (a hook fires on essentially every turn incl. `/clear`), and a
  robust fix reintroduces the sibling-session ambiguity Phase 3 has to solve — so
  deferred rather than added speculatively. *Trigger: only if the window is observed
  in practice, and ideally after Phase 3's sibling-safe reconciliation exists to
  reuse.*

## Repo / infra

- [ ] **Branch protection for `dev` + `main`** — decided rules: `main` = block
  deletion **+** block force push (non-fast-forward), admin-enforced (the release
  line must never be rewritten); `dev` = block deletion only (force push stays
  open so amend/rebase keeps working). Blocked today: GitHub gates branch
  protection (both rulesets and classic protection) behind a paid plan for
  **private** repos — every API/UI path returns `403 "Upgrade to GitHub Pro or
  make this repository public"`. Three unlock paths: (a) GitHub Pro (~$4/mo);
  (b) make the repo public — aligns with the planned open-sourcing, then
  protection is free; (c) a local `pre-push` hook that refuses force-push /
  deletion of `main` (free, but only guards this one clone). *Trigger: when the
  repo goes public (preferred — do it then for free), or sooner via a local
  pre-push hook if a手滑 force-push scare makes it urgent.*
