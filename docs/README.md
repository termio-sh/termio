# termio docs — wiki

How the docs in this folder are organized. GitHub renders this as the landing
page when you browse `docs/`.

## How docs are organized

- Every doc lives **somewhere under `docs/`** and carries its own metadata in
  **YAML front matter** at the top of the file. Subfolders (`design/`,
  `competitive-analysis/`, …) are just loose grouping — the authoritative
  category is the front matter `type`, **not** the path.
- **Product promo assets** (App Store shots, social covers) stay under
  `maketing/` in this repo. **Strategy / pitch markdown** lives in the sibling
  `pitch` repo: `/Users/yuanjiwei/Documents/GitHub/pitch/termio`.
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
|  |  | [](talks/shaogefenhao-20260725/shaogefenhao-ai-product-termio.md) |
| active | backlog | [Backlog](backlog/backlog.md) |
| active | bug | [iOS libghostty "non-functional" panel + surface-teardown crash — fix journey](bug/ios-ghostty-renderer-panic-and-teardown-uaf.md) |
| active | design | ["Issue tracker 集成：inspector Issues tab（GitHub / Linear，per-project provider）"](design/issue-tracker-integration.md) |
| active | design | ["Remote-access design lessons: sleep reachability, stable domains, identity, monetization"](design/remote-access-lessons.md) |
| active | design | [iOS libghostty "non-functional" panel + teardown UAF — root-cause findings](design/ios-ghostty-renderer-panic-investigation-findings.md) |
| active | design | [iOS terminal input & attachments](design/ios-terminal-input.md) |
| active | design | [macOS release runbook — cut, notarize, publish termio.dmg](runbook/macos-release-runbook.md) |
| active | design | [Sessions CLI v2 — reliability & command design](design/sessions-cli-v2.md) |
| active | rfc | [Push-to-talk voice dictation — hold the space bar (iOS shipped, OpenAI)](rfcs/push-to-talk-voice-dictation.md) |
| approved | design | [会话历史 · 搜索 · 恢复（Session History / Search / Resume）](design/session-history-search-resume.md) |
| approved | design | [Agent Resume Identity — keeping the resume pin on the live conversation](design/agent-resume-identity.md) |
| approved | design | [Git worktree creation & lifecycle (Codex-aligned)](design/worktree-creation-lifecycle.md) |
| approved | design | [Refresh session identity when Claude Code /clear rotates the conversation](design/clear-conversation-rotation.md) |
| approved | design | [Worktree information architecture](design/worktree-information-architecture.md) |
| archived | design | [iOS scroll-draw coalescing (vsync-capped surface draws)](design/ios-scroll-renderer-health.md) |
| archived | design | [Sandbox VM —— 原生 per-project 容器（Apple Containerization）](design/sandbox-vm.md) |
| archived | essay | ["From IDE to ADE: Sixty Years of Development Environments, and Why the Era Is Ending"](essays/from-ide-to-ade.md) |
| archived | plan | [Fix — defer the PTY spawn to the first real layout size so the agent banner boots at pane width](plan/terminal-narrow-grid-frozen-banner-fix.md) |
| done | bug | ["HANDOFF: terminal content does not reflow on window resize"](bug/terminal-resize-no-reflow-HANDOFF.md) |
| done | bug | [Agent welcome banner frozen into a narrow column when a session opens in a wide window](bug/terminal-narrow-grid-frozen-banner-on-open.md) |
| done | design | ["Sandbox removal & restoration (Apple Seatbelt subsystem)"](design/sandbox-removal-and-restoration.md) |
| done | design | [Agent Abstraction & Configuration](design/agent-abstraction-and-configuration.md) |
| done | design | [Config-driven agent resume](design/config-driven-agent-resume.md) |
| done | design | [Quick theme switching from the command palette](design/command-palette-theme-switching.md) |
| done | design | [Vibe Island 式 Agent 状态层（Claude Code hooks）](design/vibe-island-status.md) |
| done | research | ["ADE 赛道全景表（2026-07）：开源 + 闭源一张表，termio 亮点"](competitive-analysis/10-landscape-table-2026-07.md) |
| done | research | ["Competitive analysis: claude-squad"](competitive-analysis/05-claude-squad.md) |
| done | research | ["Competitive analysis: cmux (manaflow-ai)"](competitive-analysis/02-cmux.md) |
| done | research | ["Competitive analysis: Conductor"](competitive-analysis/03-conductor.md) |
| done | research | ["Competitive analysis: container-use (dagger)"](competitive-analysis/06-container-use.md) |
| done | research | ["Competitive analysis: Crystal / Nimbalyst"](competitive-analysis/04-crystal.md) |
| done | research | ["Competitive analysis: Superset (superset.sh)"](competitive-analysis/11-superset.md) |
| done | research | ["Competitive analysis: Unpeel"](competitive-analysis/01-unpeel.md) |
| done | research | ["Competitive analysis: Vibe Island family (status monitors)"](competitive-analysis/07-vibe-island.md) |
| done | research | ["Competitive analysis: Warp (alternative paradigm)"](competitive-analysis/08-warp.md) |
| done | research | ["termio differentiation, gaps, and risks"](competitive-analysis/09-differentiation-and-gaps.md) |
| draft | design | [分享 Agent 会话（带密码的实时分享链接）](design/session-share.md) |
| draft | design | [移动端 Agent UI 协议 —— PTY 之上的旁路结构面（ACP 词汇）](design/mobile-agent-ui-protocol.md) |
| draft | design | [调研：下一批 AgentAdapter 的落盘格式（OpenCode / Pi / Amp / Cursor / Kimi）](design/agent-transcript-survey.md) |
| draft | design | ["Markdown preview — Apple-grade reading typography"](design/markdown-preview-reading-typography.md) |
| draft | design | [Issue Triage → 本地 agent（GitHub / Linear 事件驱动 termio session）](design/issue-triage-local-agent.md) |
| draft | design | [Mac retention analytics (no app changes)](design/mac-retention-analytics.md) |
| draft | design | [Remote Projects (open an SSH/VPS box like a local project)](design/remote-projects.md) |
| draft | design | [Session Daemon Architecture (termiod — one model for local, remote, mobile)](design/session-daemon-architecture.md) |
| draft | design | [Sidebar scroll performance — per-session runtime state](design/sidebar-scroll-performance.md) |
| draft | design | [远程访问与中转策略（tunelo / BYO-tunnel）](design/remote-access-relay-strategy.md) |
| draft | rfc | ["RFC: Per-project agent sandbox (Apple Seatbelt)"](design/sandbox-seatbelt.md) |
| draft | rfc | [Automation — scheduled agent runs](rfcs/automation-scheduled-agent-runs.md) |
| draft | rfc | [Fork libghostty-spm — own the wrapper, rent the engine?](rfcs/fork-libghostty-spm.md) |
| draft | rfc | [Loose terminals as first-class entities](design/loose-terminal-entity.md) |
| draft | rfc | [Onboarding —— 首次启动体验设计](design/onboarding.md) |
| fixed | bug | [New terminal opens unfocused (hollow cursor, beeps until clicked)](bug/terminal-focus-loss-on-new-session-mount.md) |
| fixed | bug | [Terminal loses focus after window deactivation](bug/terminal-focus-loss-on-window-key.md) |
| fixed | bug | [Terminal loses focus while the window stays key — sibling-render trigger](bug/terminal-focus-loss-on-sibling-render.md) |
| in-progress | rfc | [可扩展 Agent —— 配置化定义 + 配置化 Hook](design/agent-extensibility.md) |
| in-review | rfc | [Split panes — Ghostty-style splits in the terminal column](rfcs/split-panes.md) |
| resolved | bug | [iOS terminal fails "unauthorized" while the session list works (companion over tunnel)](bug/companion-terminal-unauthorized-over-tunnel.md) |
<!-- END docs-index -->
