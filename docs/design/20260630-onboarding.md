---
title: Onboarding —— 首次启动体验设计
status: draft
type: rfc
created: 2026-06-30
updated: 2026-06-30
related:
  - 20260707-agent-extensibility.md
---

# RFC：Onboarding —— Termio 首次启动体验

> 把用户从「装好却空白的 app」带到「一个 agent 在某个项目里跑起来」。引导只负责**搬走挡路的障碍**,不负责教功能。

## 1. 目标与非目标

**目标(唯一一句话):** blank app → 一个 agent 在一个项目里跑起来。引导的成败只用这一个「第一会话」来衡量。

**非目标(明确不做):**

- 多屏价值轮播 / slideshow tour。
- 强制登录或注册(Termio 已免费,无账号体系)。
- 埋点漏斗、激活率 A/B。
- 在用户跑起来之前就问主题、字体、sandbox、键位等外观/高级设置 —— 这些一律留给 Settings,按需发现。

理由见 `docs/CLAUDE.md`:Termio 是「刻意、最小、聚焦」的工具,引导也必须是终端式的极简,而不是消费 App 的那套。

## 2. 核心问题:agent readiness 才是真正的卡点

Termio 是 agent CLI 的**宿主**。如果用户机器上没有 `claude` / `codex` / `opencode` / `pi`,打开 Termio 就是一片空白、无从下手 —— 这是第一启动最常见、且**不引导就完全不可见**的失败。

所以引导最有价值的单一动作,是**检测已安装的 agent,并指引装上至少一个**。这一块做对了,其余都是次要授权。

按优先级,引导必须做三件事:

1. **检测 agent**(`which claude` 等)→ 每个 agent 显示 ✓/✗,缺的给一行可复制的安装命令。这是核心。
2. **打开第一个文件夹** → 主 CTA;开一个 project + 一个 session,产生「aha」。
3. **两个授权开关**(把目前散落的「侵入式 opt-in」收拢到这里,而不是各弹各的):
   - 安装 `termio` 命令行工具(用于 `termio .` / `termio sessions`;`/usr/local/bin` 为 root 所有时走一次性 admin 提示)。
   - 「让 agent 互相协作」(session control 的 skill + hooks)—— **把现有的 `App.swift maybePromptForSessionControl()` 那个独立 NSAlert 折叠进来**,避免二次打扰。

## 3. 形态:一个 welcome window,不是 wizard

参照同类原生工具(Ghostty 近乎无引导;Zed 一个 welcome tab;Warp 登录 + 几步;Xcode 的 welcome window)。结论:**用单个 Xcode 式 welcome window**,一屏搞定,且**兼做 recents 启动器**(之后每次启动都是「最近项目 + Open」)。

```text
┌──────────────────────────────────────────────┐
│            ▦  Welcome to termio                │
│     A native terminal for your AI agents       │
│                                                │
│  Agents on your Mac                            │
│   ✓ Claude Code      ✓ Codex                   │
│   ✗ OpenCode   → npm i -g opencode-ai    ⧉     │
│   ✗ Pi         → …                        ⧉    │
│                                                │
│  ☑ Install `termio` command-line tool          │
│  ☑ Let agents coordinate (sessions CLI+hooks)  │
│                                                │
│        [ Open a Folder… ]   (primary)          │
│  Recent:  (none yet)                           │
└──────────────────────────────────────────────┘
```

**为什么是 window 而不是模态 carousel:** 可重开(Help ▸ Welcome)、每次启动复用为 recents 启动器、不会把用户困在步骤里。

**被否决的两个替代:**

- **多屏 carousel**:更手把手,但与极简定位冲突,且是单向流程。
- **纯 inline empty-state**(侧栏「No projects — Open a folder」):最轻,但**丢掉了 agent-readiness 检测**,也就丢掉了防止「空白死角」的那一环。可作为 welcome window 之外的补充空状态,但不能替代它。

## 4. 状态与版本:存 `lastSeenVersion`,不要 bool

把两件常被混淆的事拆开:

| | 触发 | 存什么 | 给谁 |
|---|---|---|---|
| 首次引导 (first-run) | 全新安装 | —— | 新用户 |
| What's New (更新说明) | 版本升级后 | 版本号 | 老用户 |

**决定:用 `settings.lastSeenVersion: String` 持久化引导状态,而不是 `didOnboard: Bool`。** bool 是单向门;版本号面向未来,免费解锁三件事:

1. 老用户跳过引导:`lastSeenVersion == CFBundleShortVersionString` 时不弹。
2. 升级后弹一个**轻量 What's New**:`current > lastSeen` 时显示;与 **Sparkle 自动更新天然配套**(Mac 应用更新后弹更新说明是惯例)。
3. 将来新增**单个 setup 步骤**(例如又一个授权开关),可只把那一步补给老用户,而不必重跑整个引导 —— 用「该步骤引入的版本号 > lastSeen」判断。

不做「版本化引导内容引擎」:引导内容本身保持静态,只有**状态**用版本号存。这是低成本、不后悔的选择。

## 5. 权限就近(just-in-time)

侵入式动作只在「用到那一刻」征求同意,不在前置 wizard 里一次性全问:

- `termio` CLI 与 session control 两个开关默认勾选但**需要用户在 welcome 里确认**;勾掉就不装。
- session control 的 admin 提示(写 `/usr/local/bin`)只在用户真的勾了「安装 CLI」时才弹。
- 引导**以「真的打开一个文件夹跑起来」收尾**,而不是看演示。

## 6. 复用现有积木(实现草图)

引导不是从零造,而是把已有能力编排到一个 welcome 表面:

- **agent 检测**:复用 `AgentPreset` + `settings.command(for:)`,每个 preset 加一个 PATH 探测(`which`-style)。
- **CLI 安装**:已有 `CommandLineTool`(含 `/usr/local/bin` 的一次性 admin 提示)。
- **协作开关**:已有 `SessionSkillInstaller` + `AgentStatusHooks`;welcome 勾选即 `settings.sessionControlEnabled = true`(store 观察到 → 自动装 skill+hooks)。
- **折叠现有提示**:删掉/降级 `App.swift maybePromptForSessionControl()` 独立 NSAlert —— 它的逻辑并入 welcome;仅当用户**跳过** welcome 时,作为兜底再单独询问一次。
- **What's New 钩子**:Sparkle 更新完成回调里比较 `lastSeenVersion`,复用同一个 window 切到「更新说明」态。

## 7. 流程

```text
launch
  └─ lastSeenVersion 缺失 ──────────────→ 显示 Welcome(首次引导态)
  └─ lastSeenVersion < current ────────→ 显示 Welcome(What's New 态)
  └─ lastSeenVersion == current ───────→ 直接进 app(welcome 仅在 Help 菜单可重开)
关闭 / 完成 Welcome → 写入 lastSeenVersion = current
```

## 8. 待定问题(Open questions)

1. **默认勾选**:两个授权开关默认勾选(零配置)还是默认不勾(更尊重)?倾向默认勾选 + 明示文案,因为这正是「install onto their agents on install」的意图;但二者皆改用户全局文件(`~/.claude/CLAUDE.md`、`settings.json`),需在文案里说清「可随时在 Settings ▸ Agents 关」。
2. **What's New 内容来源**:手写 release notes(随版本维护)还是从 git/CHANGELOG 生成?首版手写最简单。
3. **没装任何 agent 时**:是否软性阻止「Open a Folder」(没 agent 开了也只有 shell),还是照常允许(shell 也是合法用法)?倾向允许,但在 agent 区给醒目的「装一个更好用」提示。
4. **welcome 与 recents**:首版可以先只做引导态,recents 列表作为后续增量(它需要持久化最近项目列表)。

## 9. 结论

- **形态**:单个 welcome window(兼 recents 启动器),不做 carousel。
- **核心**:agent 检测 + Open Folder + 两个授权开关;权限就近,以真打开文件夹收尾。
- **状态**:`lastSeenVersion`(非 bool),同时驱动「跳过引导 + 升级 What's New + 将来补单步」,与 Sparkle 配套。
- **复用**:`AgentPreset` / `CommandLineTool` / `SessionSkillInstaller` / `AgentStatusHooks` 已就位,引导只是把它们编排到一个表面,并折叠掉现有的独立 NSAlert。
