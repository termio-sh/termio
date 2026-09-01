# Termio docs — wiki

How the docs in this folder are organized. GitHub renders this as the landing
page when you browse `docs/`.

## How docs are organized

- Every doc lives **somewhere under `docs/`** and carries its own metadata in
  **YAML front matter** at the top of the file. Subfolders (`design/`,
  `competitive-analysis/`, …) are just loose grouping — the authoritative
  category is the front matter `type`, **not** the path.
- **Product promo assets and posts** (App Store shots, social covers, launch
  posts) live in a private sibling `marketing` repo, and **strategy / pitch
  markdown** in a private sibling `pitch` repo — neither ships here.
- Each doc declares: `title`, `status`, `type`, `created`/`updated`, and optional
  `related`. The front matter is the **single source of truth** for status —
  there is no separate status file to keep in sync.
- `status` moves down this line over a doc's life:
  `draft → in-review → approved → active → done → archived`.
- `type` is a label: `design` · `rfc` · `marketing` · `research` (add more only
  when a doc genuinely doesn't fit).

To create a new doc or ask "which docs are done / still in draft", use the `doc`
skill (`.claude/skills/doc/`) — it writes the front matter on create and scans it
live on query. Don't hand-maintain doc status anywhere but the doc itself.

## Index

The table below is **generated** from each doc's front matter — it is a derived
view, not a source of truth. The `doc` skill regenerates everything between the
markers; don't edit rows by hand (your edits would be overwritten and could drift
from the real front matter).

<!-- BEGIN docs-index -->
| status | type | title |
| --- | --- | --- |
| active | backlog | [Backlog](backlog/backlog.md) |
| active | bug | [Agent TUIs shake on the phone — focus reports claim the write token](bug/agent-tui-focus-report-resize-storm.md) |
| active | bug | [iOS libghostty "non-functional" panel + surface-teardown crash — fix journey](bug/ios-ghostty-renderer-panic-and-teardown-uaf.md) |
| active | design | ["Issue tracker 集成：inspector Issues tab（GitHub / Linear，per-project provider）"](design/20260726-issue-tracker-integration.md) |
| active | design | ["Remote-access design lessons: sleep reachability, stable domains, identity, monetization"](design/20260705-remote-access-lessons.md) |
| active | design | [Handoff — collapsing the two session paths into termiod](handoff/20260817-one-path-refactor.md) |
| active | design | [iOS libghostty "non-functional" panel + teardown UAF — root-cause findings](design/20260706-ios-ghostty-renderer-panic-investigation-findings.md) |
| active | design | [iOS terminal input & attachments](design/20260703-ios-terminal-input.md) |
| active | design | [iOS TestFlight runbook — build, upload, and drive ASC from the API](runbook/ios-testflight-runbook.md) |
| active | design | [Keyboard and command design](design/20260812-keyboard-command-design.md) |
| active | design | [macOS release runbook — cut, notarize, publish termio.dmg](runbook/macos-release-runbook.md) |
| active | design | [Research brief — termiod Session Protocol (for design agent)](design/20260730-_research-session-protocol-brief.md) |
| active | design | [Sessions CLI v2 — reliability & command design](design/20260724-sessions-cli-v2.md) |
| active | research | ["Reading list: PTYs, SSH, and detachable remote terminals"](READING.md) |
| active | rfc | [可扩展 Agent —— 配置化定义 + 配置化 Hook](design/20260707-agent-extensibility.md) |
| active | rfc | [Agent integration moves into termiod](design/20260825-agent-integration-moves-to-termiod.md) |
| active | rfc | [One path — local sessions run through termiod too](design/20260817-one-path-local-through-termiod.md) |
| active | rfc | [Push-to-talk voice dictation — hold the space bar (iOS shipped, OpenAI)](design/20260704-push-to-talk-voice-dictation.md) |
| active | rfc | [Unify the server plane in Rust, reduce the Mac app to a viewer](design/20260819-unify-server-plane.md) |
| active | rfc | [What ten years of docker/dockerd teach the termio/termiod split](design/20260831-docker-dockerd-lessons.md) |
| approved | design | [会话历史 · 搜索 · 恢复（Session History / Search / Resume）](design/20260628-session-history-search-resume.md) |
| approved | design | [Agent Resume Identity — keeping the resume pin on the live conversation](design/20260716-agent-resume-identity.md) |
| approved | design | [Git worktree creation & lifecycle (Codex-aligned)](design/20260706-worktree-creation-lifecycle.md) |
| approved | design | [Refresh session identity when Claude Code /clear rotates the conversation](design/20260720-clear-conversation-rotation.md) |
| approved | design | [Worktree information architecture](design/20260628-worktree-information-architecture.md) |
| approved | rfc | [Theme store — browse 50, install on demand, library is truth](design/20260814-theme-store.md) |
| archived | design | [移动端 Agent UI 协议 —— PTY 之上的旁路结构面（ACP 词汇）](design/20260711-mobile-agent-ui-protocol.md) |
| archived | design | [Agent permission questions on the phone](design/20260803-agent-permission-questions.md) |
| archived | design | [iOS scroll-draw coalescing (vsync-capped surface draws)](design/20260706-ios-scroll-renderer-health.md) |
| archived | design | [Sandbox VM —— 原生 per-project 容器（Apple Containerization）](design/20260629-sandbox-vm.md) |
| archived | essay | ["From IDE to ADE: Sixty Years of Development Environments, and Why the Era Is Ending"](essays/from-ide-to-ade.md) |
| archived | plan | [Fix — defer the PTY spawn to the first real layout size so the agent banner boots at pane width](plan/terminal-narrow-grid-frozen-banner-fix.md) |
| archived | rfc | ["Adversarial review: One workspace source — the inspector reads the session's device"](design/20260818-one-workspace-source.review-codex.md) |
| archived | rfc | ["Adversarial review: Retire remote — every machine is a device"](design/20260814-remote-to-device.review-codex.md) |
| archived | rfc | ["RFC: Per-project agent sandbox (Apple Seatbelt)"](design/20260630-sandbox-seatbelt.md) |
| archived | rfc | [Adversarial review — Retire "remote", every machine is a device](design/20260814-remote-to-device.review-claude.md) |
| archived | rfc | [Device RFC blocking decisions](design/20260814-remote-to-device.decisions.md) |
| archived | rfc | [Review — One path, local sessions run through termiod too](design/20260817-one-path-local-through-termiod.review-claude.md) |
| done | bug | ["HANDOFF: terminal content does not reflow on window resize"](bug/terminal-resize-no-reflow-HANDOFF.md) |
| done | bug | [Agent welcome banner frozen into a narrow column when a session opens in a wide window](bug/terminal-narrow-grid-frozen-banner-on-open.md) |
| done | bug | [iOS terminal fails "unauthorized" while the session list works (companion over tunnel)](bug/companion-terminal-unauthorized-over-tunnel.md) |
| done | bug | [New terminal opens unfocused (hollow cursor, beeps until clicked)](bug/terminal-focus-loss-on-new-session-mount.md) |
| done | bug | [Terminal loses focus after window deactivation](bug/terminal-focus-loss-on-window-key.md) |
| done | bug | [Terminal loses focus while the window stays key — sibling-render trigger](bug/terminal-focus-loss-on-sibling-render.md) |
| done | design | ["Sandbox removal & restoration (Apple Seatbelt subsystem)"](design/20260718-sandbox-removal-and-restoration.md) |
| done | design | [Agent Abstraction & Configuration](design/20260718-agent-abstraction-and-configuration.md) |
| done | design | [Config-driven agent resume](design/20260720-config-driven-agent-resume.md) |
| done | design | [Quick theme switching from the command palette](design/20260727-command-palette-theme-switching.md) |
| done | design | [Session deep links (termio:// addresses)](design/20260801-session-deep-link.md) |
| done | design | [Sessions CLI v3 — command design (better than tmux)](design/20260808-sessions-cli-v3-command-design.md) |
| done | design | [Sidebar scroll performance — per-session runtime state](design/20260724-sidebar-scroll-performance.md) |
| done | design | [Vibe Island 式 Agent 状态层（Claude Code hooks）](design/20260719-vibe-island-status.md) |
| done | research | ["ADE 赛道全景表（2026-07）：开源 + 闭源一张表，Termio 亮点"](competitive-analysis/10-landscape-table-2026-07.md) |
| done | research | ["Competitive analysis: claude-squad"](competitive-analysis/05-claude-squad.md) |
| done | research | ["Competitive analysis: cmux (manaflow-ai)"](competitive-analysis/02-cmux.md) |
| done | research | ["Competitive analysis: Conductor"](competitive-analysis/03-conductor.md) |
| done | research | ["Competitive analysis: container-use (dagger)"](competitive-analysis/06-container-use.md) |
| done | research | ["Competitive analysis: Crystal / Nimbalyst"](competitive-analysis/04-crystal.md) |
| done | research | ["Competitive analysis: Superset (superset.sh)"](competitive-analysis/11-superset.md) |
| done | research | ["Competitive analysis: Unpeel"](competitive-analysis/01-unpeel.md) |
| done | research | ["Competitive analysis: Vibe Island family (status monitors)"](competitive-analysis/07-vibe-island.md) |
| done | research | ["Competitive analysis: Warp (alternative paradigm)"](competitive-analysis/08-warp.md) |
| done | research | ["Termio differentiation, gaps, and risks"](competitive-analysis/09-differentiation-and-gaps.md) |
| done | rfc | [A project carries its machine — delete the host container](design/20260818-one-workspace-source.md) |
| done | rfc | [Companion Wire Protocol](design/20260810-companion-wire-protocol.md) |
| done | rfc | [Fork libghostty-spm — own the wrapper, rent the engine?](design/20260703-fork-libghostty-spm.md) |
| done | rfc | [Loose terminals as first-class entities](design/20260713-loose-terminal-entity.md) |
| done | rfc | [PTY size is not the write token](design/20260901-pty-size-is-not-the-write-token.md) |
| done | rfc | [Remote git — the pane's verbs run on the device](design/20260818-remote-git-plane.md) |
| done | rfc | [Session identity survives the agent](design/20260830-session-identity-survives-the-agent.md) |
| draft | design | [分享 Agent 会话（带密码的实时分享链接）](design/20260628-session-share.md) |
| draft | design | [调研：下一批 AgentAdapter 的落盘格式（OpenCode / Pi / Amp / Cursor / Kimi）](design/20260711-agent-transcript-survey.md) |
| draft | design | ["Markdown preview — Apple-grade reading typography"](design/20260718-markdown-preview-reading-typography.md) |
| draft | design | [Agent Plugins](design/20260812-agent-plugins.md) |
| draft | design | [Browser Control over CDP](design/20260807-browser-cdp.md) |
| draft | design | [Device → Workspace → Project](design/20260819-device-workspace-project.md) |
| draft | design | [Device Architecture — one server per device, every UI a client](design/20260805-termiod-device-architecture.md) |
| draft | design | [Hot path, attach join point, and client classes](design/20260805-termiod-hot-path-and-client-classes.md) |
| draft | design | [Instant view switching — prior art and technique](design/20260819-instant-view-switching.md) |
| draft | design | [Issue Triage → 本地 agent（GitHub / Linear 事件驱动 Termio session）](design/20260723-issue-triage-local-agent.md) |
| draft | design | [Mac retention analytics (no app changes)](design/20260715-mac-retention-analytics.md) |
| draft | design | [Remote Projects (open an SSH/VPS box like a local project)](design/20260708-remote-projects.md) |
| draft | design | [Session Daemon Architecture (termiod — one model for local, remote, mobile)](design/20260708-session-daemon-architecture.md) |
| draft | design | [Session guests — three deltas, not a sharing subsystem](design/20260818-session-guests.md) |
| draft | design | [Superlogical research brief (Codex / competitive)](design/20260805-_research-superlogical-codex-brief.md) |
| draft | design | [termiod — Agent-native session mux](design/20260730-termiod-session-mux.md) |
| draft | design | [termiod Session Protocol](design/20260730-termiod-session-protocol.md) |
| draft | design | [远程访问与中转策略（tunelo / BYO-tunnel）](design/20260705-remote-access-relay-strategy.md) |
| draft | essay | ["How Claude Code Got the Mouse: Reverse-Engineering the Clickable Terminal"](essays/how-claude-code-got-the-mouse.md) |
| draft | rfc | [零前置远程访问：把 dev tunnels 的形状搬到 termio](design/20260827-remote-access-dev-tunnels-model.md) |
| draft | rfc | [Automation — scheduled agent runs](design/20260702-automation-scheduled-agent-runs.md) |
| draft | rfc | [Feature cut after Superlogical's 28 Aug demo](design/20260829-feature-cut-after-superlogical-demo.md) |
| draft | rfc | [Installing termio's agent integration on a device](design/20260824-agent-integration-on-a-device.md) |
| draft | rfc | [iOS as a device client](design/20260824-ios-as-device-client.md) |
| draft | rfc | [Onboarding —— 首次启动体验设计](design/20260630-onboarding.md) |
| draft | rfc | [PTY size is not the write token](design/20260901-pty-size-is-not-the-write-token.md) |
| draft | rfc | [Retire the companion's second protocol — the phone attaches to a device](design/20260831-companion-second-protocol-retires.md) |
| draft | rfc | [Settings that know which machine they mean](design/20260824-settings-that-know-which-machine.md) |
| draft | rfc | [Termiod web client on official Ghostty WASM (Linux first)](design/20260818-termiod-web-client-ghostty-wasm.md) |
| draft | rfc | [The tab strip is the collapsed sidebar](design/20260829-tab-strip-is-the-collapsed-sidebar.md) |
| in-review | design | [Workspace switch latency](design/20260819-workspace-switch-latency.md) |
| in-review | rfc | [Every machine is a device, every place you work is a project](design/20260814-remote-to-device.md) |
| in-review | rfc | [Split panes — Ghostty-style splits in the terminal column](design/20260702-split-panes.md) |
| in-review | rfc | [termiod lifecycle — install and update as one reconcile loop](design/20260827-termiod-lifecycle-reconcile.md) |
<!-- END docs-index -->
