---
title: Issue Triage → 本地 agent（GitHub / Linear 事件驱动 Termio session）
status: draft
type: design
created: 2026-07-23
updated: 2026-07-23
related:
  - 20260705-remote-access-relay-strategy.md
  - 20260706-worktree-creation-lifecycle.md
  - 20260708-session-daemon-architecture.md
  - 20260718-agent-abstraction-and-configuration.md
---

# 设计：Issue Triage → 本地 agent

> 让一个外部 issue 事件（GitHub/Linear 上被建、被打标签、被 assign、被 @）路由到一个**本地** termio agent session，由它回帖或开 PR —— Termio 版的 Cyrus，但自带原生 UI、多 agent 和已经常驻的隧道。

## 1. 这是什么 / 为什么

**Triage（分诊）** = 外部事件进来 → 判断"该谁做、做什么" → 路由给执行者。这条赛道 2026 年已经很成熟，但主流执行者都在**云端**（Cursor Cloud、Copilot coding agent、Devin、Linear 自带 agent）：代码在别人机器上跑。

Termio 的差异点是执行者在**本地**：用户自己机器上的 Claude/Codex/Pi/Grok session，读本地 repo、开本地 worktree、用用户自己的 key/订阅。Termio 已经有起 session、worktree、隧道、transcript 渲染这一整套零件，缺的只是一个**入站事件桥 + 触发规则**。

本文档盘点先例、拆解通用机制、给出对齐 Termio 现有架构的最小实现，并框定必须先拍板的产品边界。

## 2. 先例盘点（GitHub 全量扫描，2026-07-23）

### 本地 agent 阵营（Termio 的直接对标）

| ★ | 项目 | 是什么 | 对 Termio 的意义 |
| --- | --- | --- | --- |
| 5813 | `builderz-labs/mission-control` | 自托管控制面，dispatch 任务给本地 Claude Code/Codex/OpenClaw，track spend | 证明"本地 agent 控制面"有大需求；但它是通用 dispatcher，无原生终端 |
| **719** | **`cyrusagents/cyrus`** | **事实标准**。监听 Linear/GitHub/GitLab/Slack 上 assign 给它的 issue → 每 issue 一个 git worktree → 跑 Claude Code/Codex/Cursor/Gemini → 活动流式回写。BYOK。 | **就是我们要做的东西**，只是没有原生 UI。见下方深读 |
| 483 | `claude-did-this/claude-hub` | GitHub webhook：@mention → 本地 Claude Code 跑到底（实现、review、merge） | GitHub 侧的最小参考实现（@mention 触发模型） |
| 223 | `coleam00/Linear-Coding-Agent-Harness` | Linear 自主编码 agent 挽具 | Linear→本地 agent 的另一种挽具写法 |
| 23 | `leswww/agentboard-ce` | **local-first** 维护者工作台：SQLite 本地存储、GitHub issue/PR **只读**、把 issue 变成本地 triage draft、"Copy Markdown for AI tools"。**刻意不自主写** | 保守端的对照：human-in-loop、零写操作。Termio 应落在它和 Cyrus 之间 |
| 5 | `hiasinho/linear-pi-agent` | 把你自己的 **Pi** agent 接到 Linear Agent Sessions | 证明 Termio 的内置 agent（Pi）能接 Linear 协议 |

### 云 agent / GitHub Action 阵营（非本地，作背景）

| ★ | 项目 | 是什么 |
| --- | --- | --- |
| 70 | `pamelafox/issue-triager-agent` | LangGraph + Agent Inbox 关 stale issue |
| 20 | `yuxiaoji30-lang/ai-maintainer-copilot-skill` | 维护者 skill：triage/PR review/release notes |
| 17 | `AndreaGriffiths11/IssueCrush` | Tinder 式左右滑处理 issue（Copilot 摘要） |
| 13 | `vercel-labs/express-issue-triage-agent-template` | Express + AI SDK，triage 新 issue、打标签、回一条维护者回复 |
| 8 | `derailed-dash/gemini-review-action` | Gemini 的 PR review + issue triage GitHub Action |
| 6 | `clouatre-labs/aptu` | issue triage / PR review / 安全扫描 的 CLI + Action |
| — | `github/marketplace` Cursor Issue Triage | labeled issue → 起 Cursor Cloud Agent → auto-create PR |

**结论**：本地阵营真正成熟的只有 **Cyrus**（719★，多源多 agent），其余要么是云端、要么是只读工作台、要么是小 demo。Termio 有机会做"Cyrus 的能力 + 原生 Mac 体验 + 已有的手机/隧道"这一组合，而这正是 Cyrus 缺的。

### Cyrus 深读（因为它就是标准）

- **BYOK**：用户自带 key/订阅。
- **每 issue 一个 git worktree + 一个 agent session**，并发不冲突。
- **自托管 = "你的机器是 agent runtime"**：付费版由 Cyrus 云提供网络层和集成，社区版全自己搭（自己的 Linear OAuth app / GitHub App / Slack App）。
- **必须常驻进程**：文档明确让你用 `tmux` / `pm2` / `systemd` 保活 —— 这从侧面确认了下面的 **Mac 睡眠**约束。
- 入站可选 **Cloudflare Tunnel** 暴露本机。
- 回写包含 dropdown select、approval 等富交互（Linear Agent Activities）。

## 3. 通用机制：五段流水线

所有本地方案都是同一条流水线：

```
外部事件 → 公网 webhook → 隧道打到本机 → dispatcher 起 session（带 worktree）→ agent 干活 → 结果回写事件源
```

### 两个入口的差异（重要）

- **Linear —— 有一等公民 Agent 协议，路径干净**
  - OAuth `actor=app`：agent 在 workspace 里变成一个真实用户（assignee/评论者），不占计费席位。
  - 用户把 issue delegate/@ 给它 → 触发 `AgentSessionEvent`（`created`），`agentSession` 对象自带 issue+comment+`promptContext`。
  - **必须 10 秒内 emit 一个 `thought` activity** 确认 session 开始（webhook ack 契约）。
  - 状态可视化由你 emit 的 activity 自动驱动，无需手动管理 session state。
- **GitHub —— 没有"assign 给我的本地 agent"原生概念，要自建**
  - 建 GitHub App，监听 `issues`（labeled/assigned）或 `issue_comment`（@mention）。
  - 触发靠 **label / assign bot user / @mention** 自己模拟；参考 `claude-hub`。
  - 回写 = issue comment + PR。

## 4. Termio 的独特位置：几乎不用造新东西

对着五段流水线，看 Termio 手里已有什么：

| 流水线段 | Cyrus 要现搭 | Termio 已有 |
| --- | --- | --- |
| 起 session 带 prompt | 自己 spawn agent | **`termio sessions send "<prompt>"`** 就是这个（CLI-over-socket 控制面） |
| 每 issue 隔离环境 | 现搭 worktree | **worktree 创建 + 3 级侧栏 UI** 已在（见 `20260706-worktree-creation-lifecycle.md`） |
| 公网入站隧道 | 装 Hookdeck/cloudflared | **companion 的 cloudflared named tunnel 已常驻**（给手机用），加一条 HTTP route 即可（见 `20260705-remote-access-relay-strategy.md`） |
| 多 agent | 只有 Claude Code | **Claude/Codex/Pi/Grok** 都能起，ATP manifest 已抽象好（见 `20260718-agent-abstraction-and-configuration.md`） |
| 看进度 / 回写素材 | 现写 | **transcript 渲染 + session-trace + git pane** 已在 |

**Termio 版 triage ≈ Cyrus + 原生 UI + 多 agent + 你本来就有的隧道**。缺口只有：入站事件桥、触发规则配置、结果回写。

## 5. 架构设计

### 5.1 组件图

```
GitHub App / Linear agent app
        │  webhook
        ▼
现有 cloudflared named tunnel  ──►  companion server 新增 route
                                    POST /hooks/github
                                    POST /hooks/linear
        │  归一化为 TriageEvent
        ▼
TriageRouter  ── 读一份 config-driven 规则（ATP-manifest 同风格）
        │  匹配 rule → 解析 project / worktree / prompt 模板
        ▼
SessionDispatcher  ──►  termio sessions send（新 worktree session）
        │
        │  session 生命周期（复用现有 status promotion / hooks）
        ▼
ReplyWriter  ── session 结束 → 取 transcript 末条 → 回写：
        │        · GitHub: issue comment + PR 链接
        │        · Linear: agent activity（thought → response）
        ▼
   事件源更新
```

### 5.2 触发规则配置（`~/.termio/triage.json`，草案）

刻意做成声明式、与 ATP manifest 同风格，一条规则一个"on → do"：

```jsonc
{
  "rules": [
    {
      "id": "linear-triage-to-claude",
      "on": {
        "source": "linear",
        "event": "session.created",
        "filter": { "label": "triage" }          // 或 assignee=termio-bot
      },
      "do": {
        "agent": "claude",
        "project": "~/Documents/GitHub/termio",  // 由 repo 映射；未配置则拒绝
        "worktree": "new",                        // new | reuse:<branch> | none
        "prompt": "You are triaging Linear issue {{issue.identifier}}: {{issue.title}}\n\n{{issue.description}}\n\nInvestigate and, if in scope, open a PR. Reply with a summary.",
        "reply": "comment",                       // comment | activity | none
        "approval": "queue"                        // run | queue（离开时排队，回来点 Run）
      }
    }
  ]
}
```

映射原则（延续 Termio 的既有铁律）：

- **repo → project 必须显式映射**，未映射的仓库一律拒绝（不猜路径）。
- 无匹配规则 = 静默丢弃（收端丢陌生事件，见 `20260708-session-daemon-architecture.md` 的既有做法）。

### 5.3 时序（Linear 路径，理想态）

1. 维护者给 issue 打 `triage` label（或把它 assign 给 `termio` agent 用户）。
2. Linear 发 `AgentSessionEvent.created` → 打到 `/hooks/linear`。
3. companion **5–10 秒内** emit `thought` activity（"Termio 已接手，正在你的 Mac 上起 session"）完成 ack 契约。
4. TriageRouter 匹配规则 → SessionDispatcher 走 `sessions send` 起一个新 worktree 的 claude session，prompt 由模板渲染。
5. session 跑；关键节点（开始/开 PR/结束）由 ReplyWriter 转成 Linear activity 回写。
6. session 结束 → transcript 末条摘要 + PR 链接 → 作为 `response` activity 收尾。

## 6. 必须先拍板的边界（不是技术，是产品）

1. **Mac 睡眠是硬约束。** 合盖时本地 agent 根本没法跑（见 `20260705-remote-access-lessons.md` / mac-reachable 结论：第三方 app 无法可靠唤醒睡眠的 Mac；Cyrus 也只能靠 tmux/pm2/systemd 保活）。这决定产品语气二选一：
   - (a) **Mac 醒着就即时跑**（`approval: run`）；
   - (b) **离开时把 triage 排队，回来在 Termio 里批量放行**（`approval: queue`）。
   —— **建议 (b) 做默认**：它顺带解决了下面的安全问题，也不假装能解决唤醒。
2. **触发必须显式，杜绝自动。** 陌生人建个 issue 就触发你本机 agent 跑代码是危险的。符合 Termio "显式手势、不广播"哲学的做法：**只在 维护者打 `triage` label / assign 给 Termio bot / 评论 @Termio 时**触发，绝不收 `issue.opened` 全量。approve-to-run 队列是更强的一道闸。
3. **先做哪个源 → Linear 先。** 它有干净的一等 Agent 协议（`actor=app` + AgentSession + `promptContext`），实现成本最低，`linear-pi-agent` 已证明 Termio 的 Pi 能接。GitHub 第二（要自建 GitHub App + 模拟触发）。
4. **回写做到哪一步 → MVP 只回一条评论 + 一个 PR 链接。** 别一上来就做 Linear 那套流式 activity / dropdown / approval 富交互。

## 7. MVP 切片

**Linear + `triage` label 触发 + 复用现有隧道 + `sessions send` 起 worktree session + 回一条评论。**

这一刀几乎全是拼装现有零件，能在一周内验证闭环，且刻意不碰两块最重的地方：Mac 唤醒、GitHub App。

范围内：

- companion 新增 `POST /hooks/linear`（走现有 cloudflared 隧道）+ `thought` ack。
- 一条硬编码规则（先不做完整 config UI）：`label=triage → claude + new worktree`。
- SessionDispatcher 复用 `sessions send`。
- ReplyWriter 最小实现：transcript 末条 → Linear comment。
- `approval: queue`：事件落到 Termio 一个"Triage 收件箱"，用户点 Run 才起 session。

范围外（后续迭代）：GitHub App、config schema UI、流式 activity、多规则路由、spend 追踪。

## 8. 开放问题

- **Triage 收件箱** 放哪：侧栏新 section，还是 Info pane 一个 tab？（倾向侧栏，和 worktree 容器同层级）
- **身份**：Linear `actor=app` 需要注册一个 Termio OAuth app —— 是每个用户自建（Cyrus 社区版模式），还是 Termio 托管一个共享 app（省用户事，但 Termio 要跑网络层）？关系到 `20260705-remote-access-relay-strategy.md` 里 BYO-tunnel vs 托管 relay 的同一取舍。
- **PR 归属**：用用户自己的 `gh` CLI 身份开 PR（BYOK 一致），确认无需额外 GitHub 授权。
- **并发上限**：一次涌入多个 triage 时，同时起几个本地 session 的上限（本机资源）。

## 9. 参考

- Cyrus — <https://github.com/cyrusagents/cyrus>（事实标准，多源多 agent，worktree-per-issue，BYOK）
- claude-hub — <https://github.com/claude-did-this/claude-hub>（GitHub @mention → 本地 Claude Code）
- agentboard-ce — <https://github.com/leswww/agentboard-ce>（local-first、只读、保守端对照）
- linear-pi-agent — <https://github.com/hiasinho/linear-pi-agent>（Termio 的 Pi 接 Linear 已被证明）
- mission-control — <https://github.com/builderz-labs/mission-control>（自托管 agent 控制面）
- Linear Agents 开发文档 — <https://linear.app/developers/agents> · <https://linear.app/developers/agent-interaction>
- Cyrus × Hookdeck 教程（本地 Claude Code 作 Linear agent 的机制）— <https://hookdeck.com/webhooks/platforms/how-to-run-claude-code-as-a-linear-agent-with-cyrus-and-hookdeck-cli>
