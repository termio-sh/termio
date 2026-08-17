---
title: "ADE 赛道全景表（2026-07）：开源 + 闭源一张表，Termio 亮点"
status: done
type: research
created: 2026-07-11
updated: 2026-07-11
related:
  - 09-differentiation-and-gaps.md
---

# ADE 赛道全景表（2026-07）

> 把"人监督多个 coding agent"这个方向上所有重要的开源/闭源产品收进一张表，
> 按与 Termio 的物理距离分层，最后回答一个问题：Termio 的亮点到底在哪。
> 综合 01–09 号文档（2026-07-02）与 2026-07-11 的最新调研。

## 第一层：同赛道直接竞品（本地多 agent 终端 / Mac 编排 app）

这些产品和 Termio 抢同一批用户、同一个桌面位置。

| 产品 | 开源 | 技术形态 | 定位一句话 | 商业模式 | 相对 Termio 的关键差异 |
| --- | --- | --- | --- | --- | --- |
| **Unpeel** | ❌ 闭源 | Swift + libghostty | Termio 的设计基准：agent 即队友 + Sessions MCP | $59 买断 | 有 Sessions MCP、会话跨 app 存活；单人维护、不可定制 |
| **cmux** (manaflow) | ✅ GPL | Swift + libghostty | 同底座最直接竞品，YC 背书，~23k★ | 未变现 | 心智份额碾压；但无菜单栏 tray、原语铺得太宽、worktree 只是"推荐用法" |
| **Conductor** (Melty Labs) | ❌ 闭源 | Mac 原生 | 并行 Claude Code/Codex，每 agent 一个 worktree + 内建 diff 审查 | 免费（BYO 订阅，待变现） | diff-重哲学；无状态 tray、无移动端；免费=商业模式悬空 |
| **herdr** | ✅ 开源 | 跨平台终端复用器 | "tmux for agents"，~15k★，持久工作区 + agent 状态检测 | 未变现 | 同样的 PTY-host 架构；但远程只有 SSH、无移动端/结构化监督面、无原生 Mac 体验 |
| **muxy** | ✅ 开源 | GhosttyKit | 分屏树 + 命令面板的 ghostty 套壳 | 未变现 | 单人单会话取向，无多 agent 状态模型；对 Termio 是分屏/面板的蓝图而非威胁 |
| **Crystal → Nimbalyst** | ✅ 开源 | Electron | 多会话 + 最好的 merge-back 体验 | 未变现 | Electron 重、非原生；改名重启中 |
| **Sculptor** (Imbue) | 🟡 部分 | 桌面 + 容器 | 每个 agent 一个容器的隔离编排 | 融资驱动 | 容器隔离重（Termio 用 Seatbelt 零成本达到同类安全）；不拥有终端 |

## 第二层：开源 CLI / TUI 工具（同需求、更简形态）

验证了需求、定义了 DIY 底线，但形态天花板低。

| 产品 | 开源 | 形态 | 定位 | 现状 / 教训 |
| --- | --- | --- | --- | --- |
| **claude-squad** | ✅ | Go TUI | tmux + worktree 管多个 Claude Code | 活跃；TUI 天花板：无 ambient 状态、无移动端 |
| **vibe-kanban** (Bloop) | ✅ Apache | Web 看板 | 卡片拖进 In Progress，agent 领活 | **2026-04 关停**。教训：不拥有运行时的调度视图 + 无商业引擎 = 死 |
| **container-use** (Dagger) | ✅ | CLI/容器 | branch-as-environment 隔离 | 太重，理念可借鉴 |
| **awesome-agent-orchestrators 长尾** | ✅ | 各种 | Shipyard、AgentsRoom、ADE-app.dev 等数十个 | 品类热度证明；无一家同时做到原生+状态+移动 |

## 第三层：巨头 / 平台级 ADE（自上而下压过来的）

不与 Termio 抢"本地终端"这个位置，但定义品类叙事、教育市场。

| 产品 | 开源 | 形态 | 定位 | 商业模式 | 与 Termio 的关系 |
| --- | --- | --- | --- | --- | --- |
| **Warp Oz**（2026-02） | ❌ | 终端 + 云 | 本地 agent + 云 Docker agent 双模式，TIME 最佳发明 | 订阅 | 云依赖 + 账号强制，隐私/内网用户的反面；Termio 的"本地信任"对照组 |
| **JetBrains Air** | ❌ | 桌面 ADE | 官方自称 agentic development environment，IDE 级审查 | 订阅 | IDE 巨头背书品类；重、绑 JetBrains 生态 |
| **GitKraken Kepler** | ❌ | 桌面 ADE | 多分支多 worktree 的 agent 编排，OG 图直接印 "ADE" | 订阅 | Git 工具厂切入；CEO 语录是品类最佳广告 |
| **Cursor**（SpaceX/xAI） | ❌ | AI-IDE | 编辑器形态的 agent 编排 + background agents | 订阅，$60B 收购 | 旧位置（编辑器）上的最强者；证明入口的定价 |
| **Claude Code 自带编排** | 🟡 部分 | CLI + 桌面 app | Agent Teams / Dynamic Workflows / 桌面并行 agent 界面 | 订阅/用量 | **最大结构性风险**：模型厂商向上做环境。但天然不中立（不会好好伺候 Codex/Gemini） |
| **OpenAI Codex cloud / Devin (Cognition)** | ❌ | 云 agent 农场 | 云端异步跑任务、PR 回来 | 订阅/用量 | 代码出机器 = 企业硬约束反面；与本地路线互补而非互斥 |

## 第四层：移动端监督（Termio iOS 的对照）

| 产品 | 开源 | 形态 | 与 Termio iOS 的差异 |
| --- | --- | --- | --- |
| **Happy** | ✅ | Claude Code 手机客户端 + 云 relay | 只服务 Claude Code；结构化聊天渲染；走第三方 relay。Termio：多 agent、真终端画面、BYO 隧道不经第三方 |
| **herdr 远程** | ✅ | SSH | 需要用户自己会配 SSH/公网；无推送、无 attention 路由 |
| **其余全部** | — | 无移动端 | Unpeel/cmux/Conductor/Crystal/claude-squad 均无手机监督面 |

## Termio 的亮点到底在哪

一句话版本：**全场没有第二个产品同时做到「原生 Mac + 拥有运行时 + 多 agent 中立 + 手机监督」——单项都有人做，四项交集只有 Termio。**

拆开说（全部为已实现并验证的能力）：

1. **拥有运行时，而不是调度视图。** Termio 自己持有 PTY 字节流（host PTY + libghostty 只做渲染）：所以有零配置状态检测、ring-buffer 回放、转录读取、以及 `termio sessions` CLI 控制面（list/send/answer——agent 可以驱动 agent）。vibe-kanban 之死证明了"不拥有运行时"这条路走不通；herdr 懂这一点，但它没有下面三条。
2. **多 agent 中立。** Claude Code / Codex / OpenCode / Pi / Amp / Cursor 六家 hook 内建。模型厂商（Anthropic/OpenAI/Google）结构上做不了这件事——这是第三方环境唯一不可被垂直整合吃掉的位置。
3. **Ambient 注意力路由。** 菜单栏 tray + working/idle/attention/done 状态机：不占屏幕的"谁在等我"。cmux 没有 tray，Conductor 没有状态机，TUI 类产品做不了 ambient。
4. **手机监督面（赛道内几乎独有）。** iOS companion：QR 配对、BYO 隧道（cloudflared，不经第三方 relay）、真终端画面 + 文件预览、分级重连。第一层竞品全军没有移动端；Happy 有但只绑 Claude Code 且走云 relay。
5. **本地信任 + 零成本安全。** 无账号、代码不出机、可选 per-project Seatbelt 沙箱（容器级隔离的安全性，~0 运行成本——Sculptor 用容器达到同样目标，重一个数量级）。
6. **验收面克制而完整。** 内建轻量 diff 查看器 + 文件编辑器 + Quick Look——够"签收代码"，不滑向 IDE。这是对"环境的中心从编辑器挪到 diff"的最小实现。
7. **从第一天就是生意。** 买断 $19.90/$39.90（Lemon Squeezy），拒绝订阅疲劳。第一层竞品里 cmux/herdr/Crystal 无商业模式，Conductor 免费悬空——唯一同样想清楚的是 Unpeel（$59），而 Termio 比它便宜、比它多移动端。

诚实的短板（对内提醒，别写进营销）：会话不跨 app 退出存活（Unpeel/claude-squad 有）；Sessions MCP 形态用 CLI-over-socket 实现而非 MCP 协议本身；worktree 为 git-aware 感知而非全自动创建（营销文案见 termio-capabilities 备忘）。

## 一张浓缩对照表（Termio vs 各层代表）

| 能力 | Termio | Unpeel | cmux | Conductor | herdr | Warp Oz | Claude Code 自带 |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| 原生 Mac（非 Electron/Web） | ✅ | ✅ | ✅ | ✅ | ➖ CLI | ✅ | ➖ |
| 拥有 PTY 运行时 | ✅ | ✅ | ✅ | 🟡 | ✅ | ✅ | ➖ |
| 多 agent 中立 | ✅ 6 家 | ✅ | ✅ | 🟡 2 家 | ✅ | 🟡 | ⛔ 自家 |
| 状态机 + 菜单栏 ambient | ✅ | ✅ | 🟡 | ❌ | 🟡 | ❌ | ❌ |
| **手机监督面** | ✅ | ❌ | ❌ | ❌ | 🟡 SSH | ❌ | 🟡 网页 |
| 本地信任（无账号/代码不出机） | ✅ | ✅ | ✅ | 🟡 | ✅ | ❌ | 🟡 |
| 沙箱隔离 | ✅ Seatbelt | ❌ | ❌ | ❌ | ❌ | ✅ 云容器 | 🟡 |
| agent 驱动 agent（控制面） | ✅ CLI | ✅ MCP | 🟡 socket | ❌ | ❌ | 🟡 | ✅ |
| 会话跨 app 退出存活 | ❌ | ✅ | 🟡 | ? | ✅ | ✅ | ➖ |
| 商业模式 | ✅ 买断 | ✅ 买断 | ❌ | 🟡 免费 | ❌ | ✅ 订阅 | ✅ |

> 图例：✅ 有 | 🟡 部分/受限 | ❌ 无 | ⛔ 结构上不会做 | ➖ 形态不同 | ? 未验证
