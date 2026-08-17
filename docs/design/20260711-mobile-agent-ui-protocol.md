---
title: 移动端 Agent UI 协议 —— PTY 之上的旁路结构面（ACP 词汇）
status: draft (v2)
type: design
created: 2026-07-11
updated: 2026-08-03
related:
  - 20260705-remote-access-relay-strategy.md
  - 20260628-session-share.md
  - 20260708-session-daemon-architecture.md
  - 20260703-ios-terminal-input.md
---

# 设计：移动端 Agent UI 协议 —— PTY 之上的旁路结构面

> 不改变 agent 的任何运行行为，基于 agent 自己落盘的 JSON（transcript）和 hooks 做一条旁路信号，
> 归一化成 ACP 词汇的事件流供移动端（iOS 现在、Android 将来）渲染原生 chat UI；
> PTY session 是唯一的 session 原语，Mac 是 PTY host，所有 UI 都只是应用层。

## 1. 背景与问题

手机上渲染 raw terminal 不是 agent 交互的好界面：字太小、触控没有原生审批、
且 iOS 端的 VT 网格模拟带来了一连串只因"手机在模拟终端"才存在的工程成本
（libghostty 死锁、IO-thread panic、resize reflow、PROMPT_SP 等，见相关 docs）。

2026-07-10/11 调研了四个同类产品（详见 §12 Prior Art），结论一致：
**没有人把 TUI 字节流转译成 GUI —— 都是绕过终端，去上游拿结构化数据**
（JSONL transcript / stream-json / SDK），在 host 侧归一化成统一 schema，客户端原生渲染。

Termio 与它们的差别：Termio 是终端产品，agent 的 TUI 本身就是产品承诺，
所以不能走 headless/适配器路线 —— 结构面必须是 PTY 之上的**旁路**（sidecar），
而不是替代运行时。

## 2. 核心原则（已定，不再重开）

1. **PTY session 是唯一的 session 原语。** Mac = headless PTY host；
   macOS 窗口、iOS、Android、`termio sessions` CLI 全部是对等的应用层客户端，
   谁都不拥有 session。
2. **零行为改变。** agent 原样跑在 PTY 里（真 TUI，非 headless、非 ACP 适配器、非 SDK 包装）。
   结构面从 transcript + hooks **推导**，agent 感知不到自己被投影。
3. **iOS/macOS 复用同一个 live session。** 两端是同一 PTY 的两种镜头，随时互相接管。
4. **手机可以创建 session，但只是 relay。** 真正的 spawn（worktree、PTY、agent 进程）
   全部发生在 Mac；创建者无特权。
5. **协议站在 AG-UI 的位置，说 ACP 的语言。** 栈位置 = frontend↔agent 的 UI 事件缝
   （AG-UI 的角色）；载荷词汇 = ACP 的 coding-agent 语义（diff、tool kind、permission option）。

## 3. 分层架构

```
L0  PTY Host（Mac，唯一的 session 所有者）
    PTYProcess(forkpty) · ring buffer/replay · transcript 发现 · hooks · 状态机
    ← session 在这里活着，不依赖任何 viewer

L1  四个 host 派生的 plane（同一 PTY session 的投影）
    · 字节面   raw PTY 流（terminal 渲染；随进程死）
    · 内容面   对话事件（transcript+hooks 归一化；随磁盘活）★本设计新增
    · 交互面   待答问题（agent hook 声明；认不出的才退到控件原型）★v2 新增
    · 控制面   prompt/answer→键击注入 · roster · 文件面（已存在）

L2  应用层（全部对等，均为 L1 的订阅者）
    · macOS 窗口       进程内订阅（1 号客户端）
    · iOS app          companion WebSocket
    · Android（将来）   companion WebSocket + 同一套事件 switch
    · termio sessions CLI   unix socket（headless 可驱动的既有证明）
```

纪律：**新代码不允许绕过 L1 直接摸 PTY。** 这条边界同时是将来（如果需要）
daemon 化的现成切割线 —— 但 daemon 化本设计**不做**（见 §11 非目标）。

## 4. 两层 session 模型

| 层 | 内容 | 生命周期 |
|---|---|---|
| Session 记录（持久） | UUID、agent 类型、worktree、resumeID、transcript 路径 | 跨 app 重启存活 |
| 活进程（短暂） | PTY + agent 进程 | app 退出即死 |

关键不对称：**字节面随进程死**（scrollback 是进程内存），
**结构面随磁盘活**（transcript 落盘）。推论：

- 死（dormant）session 用 terminal 视图打开是空白；用 chat lens 打开是**完整历史 + Resume**。
  这是 chat lens 在移动端最强的单条论据。
- **Resume 是协议一等操作**：用户在 dormant session 里输入 → host 以 resumeID
  起 `claude --resume` → session 转活，三个 plane 点亮。
- roster 状态需增加正交维度：`live | dormant`（现有 idle/working/done/needsAttention
  都是 live 内的子状态）。

## 5. 协议选型（2026-08-03 修订）：借 ACP 的名词，不借它的方法层

原稿采纳 ACP v1 session 层的**词汇 + 方法**。重读 Happy 当前代码后修订为：
**只借名词（ToolCall kind、PermissionOption kind、diff content、locations、plan、usage），
丢掉方法层与 JSON-RPC 框架。**

新证据（Happy 仓库 2026-08-03 快照）：Happy 曾经有一个自定义 `acp` 内容格式，已被替换掉。
其 `docs/session-protocol.md` 开篇即写：新协议"replaces the existing mix of `output`、
`codex` 和自定义 `acp` 格式"，换成 **9 种事件的扁平流**
（`text`/`service`/`tool-call-start`/`tool-call-end`/`file`/`turn-start`/`turn-end`/`start`/`stop`），
给出的理由与 Termio 的处境高度重合：载荷要端到端加密（ACP 假设明文 REST）、
**tool call 是要渲染的一等 UI 而非 debug 元数据**、客户端一个 `switch` 就能实现全协议。
一家真出货了 iOS/Android/Web 三端的产品，试过 ACP 形状又主动退回扁平事件流 ——
这是目前能拿到的最强单条经验证据。

对 Termio 而言，ACP 的方法层本来就是重复的：`session/new`、`session/load`、
`session/prompt`、`session/cancel` 在 companion wire 上分别已经是 `.start`、`.attach` +
回放、PTY 二进制帧、中断键注入。再套一层 JSON-RPC 只是把同一件事说两遍，
而且要在一个手写 JSON 编解码的 wire（`CompanionControl`）上模拟 RPC 语义。
放弃方法层也就放弃了"Android 官方 Kotlin SDK"这条收益 —— 可以接受：
Android 将来照样是一个 switch，10 个 case。

**不采纳：ACP 作为运行时**（即跑 claude-code-acp 之类适配器）。
对 ACP 的实质批评全部指向这个用法：适配器是二等公民且可被 vendor 掐掉
（Claude 的 ACP 支持是 Zed 维护的 SDK 包装而非官方；Amp 把 ACP 锁在付费额度后）；
最小公分母抽象丢 agent 特性；stdio/1:1/本地假设没有重连与多客户端。
herdr（同架构竞品）与 vibe-kanban（编排器）都因此绕开了 ACP。
Termio 只借它的 schema：最坏情况 ACP 标准死掉，我们手里仍是一套形状良好的私有
schema（vibe-kanban 的 NormalizedEntry 就是自己发明了一遍）；
若它活下来，原生 ACP agent（Gemini CLI、Goose）可免费直通。

**不采纳：AG-UI 作为载荷 schema。** 它是通用 chat+state 协议，
无 diff/file/terminal/permission 原语，coding 语义全要自造。
借鉴其两个点：interrupt 的 `expiresAt`、恢复前先发快照的规则。

## 6. Wire 映射：4 个新 case + 10 种事件

载体：现有 companion WebSocket（tunnel + 配对 token 不变）。字节面
（`.attach` + 二进制帧）**一行不动** —— 两个面可以同时订阅，也可以只订一个。

### 6.1 新增的 `CompanionControl` case

| case | 方向 | 语义 |
|---|---|---|
| `subscribeEvents(sessionID:since:)` | 手机 → Mac | 订阅结构面；`since` = 已收到的最大 seq（0 = 全量回放）。对 dormant session 同样有效 |
| `events(sessionID:batch:)` | Mac → 手机 | 一批事件，每条带 seq |
| `answer(sessionID:questionID:optionID:)` | 手机 → Mac | 回答待答问题；host 兑现成 hook 的返回值（declared）或方向键注入（observed，§6.4） |
| `capabilities(sessionID:flags:)` | Mac → 手机 | 该 session 点亮了哪些能力（§8），客户端据此决定默认镜头 |

已有 case 继续承担它们的角色，不重复造：`.start`/`.startTerminal` = 创建，
`.stop` = 结束，`.attach` + 二进制帧 = prompt 注入与中断，
`.listFiles`/`.readFile`/`.searchFiles` = 文件面，roster 广播 = 会话列表。

### 6.2 事件信封与 10 种事件

```json
{ "seq": 412, "time": 1754200000000, "role": "agent",
  "turn": "t7", "parent": "sa3", "ev": { "t": "...", ... } }
```

| # | `ev.t` | 载荷 |
|---|---|---|
| 1 | `turn-start` | — |
| 2 | `turn-end` | `status: completed \| failed \| cancelled` |
| 3 | `text` | `text`（markdown）、`thinking?` |
| 4 | `tool` | `call`、`name`、`kind`（ACP 名词：read/edit/execute/search/think/fetch/other）、`title`、`subtitle?`、`status: pending\|running\|done\|error`、`locations?` |
| 5 | `diff` | `call`、`path`、`unified`（编辑类 tool 的内容） |
| 6 | `permission` | `request`、`call`、`options: [{id, label, kind}]`、`expiresAt` |
| 7 | `permission-resolved` | `request`、`optionID`、`by: phone \| mac \| tui` |
| 8 | `plan` | `items: [{text, status}]`（Claude 的 TodoWrite → 原生清单） |
| 9 | `usage` | `tokens`、`cost?`、`contextLeft?` |
| 10 | `session-info` | `title`、`model?`、`mode?`、`state: live \| dormant`、`activity: idle \| working \| needs-you \| done` |

与 Happy 的三处刻意分歧 —— 每一处都因为**信号源不同**，不是口味不同：

1. **tool 用 upsert，不用 `start`/`end` 两条事件。** Happy 的远程流是 SDK 直播，
   先开始后结束很自然；Termio 的源是**磁盘上的 transcript 文件**，重读、resume、
   fork 都会让同一条 tool 记录再次出现。以 `call` 为键的幂等 upsert 让"重放即收敛"，
   客户端不需要 dedupe，host 也不需要 Happy 那套 `processedMessageKeys` 全局去重表。
2. **`seq` + `since` 游标写进协议。** Happy 有服务器存全量消息、客户端拉；
   Termio 没有服务器，重连时必须能说"我到 seq N 了"。这与字节面的 ring-buffer
   catch-up 是同构的机制，直接复用心智模型。
3. **审批是一对事件而非一次 RPC 往返。** 同一个 TUI 菜单可能被坐在 Mac 前的人回答，
   解析必须能从外部到达（§9 先答者赢）。Happy 踩过的坑值得先抄进设计：
   CLI 进程死掉后服务端仍留着 pending request，App 永远转圈且点不掉 ——
   对策是 `permission-resolved{by:}` 由 host 无条件广播，且 host 重启时
   把所有未决请求一律广播为 cancelled。

### 6.3 subagent 从第一天就在信封里

Happy 的 `session-protocol-claude.md` 里篇幅最大的一节是 sidechain：Task 子代理的消息
可能先于父 `tool_use` 到达（要在 host 缓冲、等父到了再 flush），provider 的 tool id
不能泄漏进协议（要映射成自己的 id）。Termio 的 transcript 里是完全相同的结构
（`parentUuid` / `isSidechain`）。教训直接照抄：`parent` 字段进信封、
**孤儿缓冲在 host 做、客户端保持哑**。这是一个改造成本远高于预留成本的字段。

### 6.4 交互面：**向 agent 提问，不向屏幕取证**

内容面有一个先天空洞：**当下正在等什么答案，transcript 里没有** ——
权限菜单、mode 状态、输入行能不能打字。这恰恰是**交互**本身。

第一版设计（2026-08-03 上午）打算照 yetone 的路走：在屏幕上认控件、
用正则把菜单抬起来。当天下午的复盘推翻了它。判据来自对 yetone 路线的评估
（§12）：无协议时只能读格子，**匹配的是"Claude Code 这一版长什么样"，不是系统 API**；
Claude 改一行布局、权限菜单加第四项，matcher 就废。终点是
"停在某个版本 Claude Code 的美颜滤镜"。

而 Termio **不是一个 emulator**：它装 hooks、读 agent manifest、拥有 session 生命周期。
它不需要猜 Claude 的脸 —— 它可以直接问。

> **核心原则：一个 TUI 菜单不是问题本身，它是 agent 对问题的一次渲染。**
> 抄屏幕等于拍显示器。问题在变成像素之前就存在于 agent 自己公开的通道里 ——
> 去那里拿。

#### 唯一的概念：待答问题（pending question）

```json
{ "id": "q7", "source": "declared|observed", "title": "Run npm test?",
  "detail": { "tool": "Bash", "input": { "command": "npm test" } },
  "options": [{ "id": "allow", "label": "Yes", "selected": true }, …],
  "answer": "direct|cursor", "expiresAt": 1754200060000 }
```

手机 → Mac 只有一个动词：`answer(questionID:, optionID:)`。
客户端**看不出问题来自哪一级**，`answer` 字段只影响 host 怎么兑现，不影响渲染。

#### 两个来源，一个降级终点

**① declared（声明级）—— 没有任何解析**

Claude Code 的 `PreToolUse` / `PermissionRequest` hook 把问题结构化地交给我们：
`tool_name`、`tool_input`、`tool_use_id`、`permission_mode`、`cwd`。
而且 hook **可以决定结果**：

```json
{ "hookSpecificOutput": { "hookEventName": "PreToolUse",
    "permissionDecision": "allow|deny|ask|defer" } }
```

- agent 在 hook 运行期间**阻塞**（默认 timeout 600s，可配）——
  于是"等用户在手机上点"天然合法，不需要任何异步协商机制。
- `ask` = 升级到正常的交互式菜单，`defer` / 空输出 = 走原有权限流程 ——
  **官方文档承诺的兜底路径**，我们的降级不是自己发明的。

于是流程是：hook 拿到问题 → 广播成 question → 谁先答谁赢 → hook 打印 allow/deny 退出 →
**TUI 那个菜单从头到尾没有出现过**。没有正则、没有按键注入、没有版本耦合。

触发规则一句话：**问题只发给正在看的设备。**
没有远程客户端 attach 时，hook 立刻 `defer`，桌面行为逐字节不变；
有客户端时才 hold，同一张卡片同时出现在手机和 Mac 的这个 pane 上。

**② observed（观察级）—— 认原型，不认 app**

没有决策通道的 agent（Codex/Grok 的 hook 目前只报状态）仍需读屏，但读的必须是
**控件原型**而不是某家的样子：

> 屏幕底部一段连续的行，每行一个条目，其中一行带光标标记（`❯`/`>`/反显）
> —— 这是 Ink `SelectInput`、Bubble Tea `list`、Textual `OptionList` 共有的
> **单选列表原型**，不是 Claude 的某一版布局。

答案通道同样去掉版本耦合：**用 `↓`×(目标行−当前行) + `Enter`**，
不用 `1`/`2`/`3` 数字键（数字键是 Claude 的做法，方向键是所有 TUI 列表的做法）。
于是我们既不需要解析编号，也不需要知道每项绑了哪个键。

**③ 没有 hook、也认不出原型 → 显示终端，句号。**
不做"半 GUI 半乱"的中间态；不引入模型识别（§11 非目标）。

#### 这个设计顺手删掉的东西

- `input` / `completions` / `status` / `interrupt` 四种事件全部不需要了：
  **输入区状态是推导出来的** —— 有待答问题就显示按钮，没有就是普通文本框。
  这正是"盖住输入区"的正解：不是去认输入框长什么样，而是知道现在该问什么。
- declared 级不需要"先答者赢"的仲裁：菜单压根没被画出来。
- 不需要 Mac 已挂载 surface。hook 在后台 session、dormant 窗口、
  甚至 Mac 没打开过这个 pane 时照样触发 —— 读屏方案在这些场景全瞎。

#### 待验证（在写代码前必须实测）

1. `PermissionRequest` 是否也支持"空输出 = 走原流程"（文档只写了 allow/deny）。
2. hook 阻塞数秒时 Claude 的 TUI 画什么（有无难看的中间态）。
3. Codex / Grok 的 hook 有没有任何决策通道；没有就老实留在 observed 级。

## 7. iOS 的镜头（lens）：默认 GUI，终端一键可达，不做偏好设置迷宫

同一个 session 在手机上有两个镜头，用户随时切换，**不是两种 session、不是两种模式**：

- **Chat 镜头（GUI）** —— 上半部是**内容面**（对话、tool 卡、diff、plan、
  以及 **dormant session 的完整历史** —— 字节面此时是空白），
  下半部是**交互面**（有待答问题就是选项按钮，没有就是普通输入框，§6.4）。
  两个面拼成一个完整界面：读什么 + 现在在等什么答案。
- **Terminal 镜头** —— 订阅字节面。真 TUI：ctrl-r、菜单滚动、裸 shell、ssh、
  以及"我要看屏幕真相"的那一刻。

**"盖住 TUI 的输入区"是这套设计里价值最高、风险最低的第一刀** ——
但正确的做法不是去**认**输入框长什么样，而是知道**现在该问什么**：
有待答问题就画按钮，没有就画文本框。输入区的形态是 §6.4 那一个概念的投影，
不是第二套识别逻辑。

手机上最难用的正是 agent 的输入行（边框、占位符、mode 行全挤在 80 列网格里），
而它同时是唯一每轮都必须碰的控件。抬成原生输入框之后，
iOS 已经建好的东西立刻全部生效：长按粘贴、语音听写、系统键盘。
注意与 2026-07-03 被砍掉的 composer 的区别（见 memory: termio-ios-input）：
那是一个**摆在终端旁边的另一个输入框**，自己发明状态；
这里的状态**来自 agent 自己声明的那个问题**。

**默认镜头由能力推导，不由用户先做选择题**：
`capabilities.streamsTranscript` 为真 → 默认 Chat；否则默认 Terminal。
裸 shell 与未知 agent 因此自然落在终端上 —— 降级是涌现性质，不是设计分支（§8）。

**配置面只有三档，放 Settings：`默认视图 = 自动 / 对话 / 终端`。**
"自动"是默认值，另外两档是给有明确偏好的人的一次性总开关。
除此之外只有一个 per-session 的镜头切换按钮（导航栏，像 Safari 的阅读器），
**按 session 记忆**。不做 per-agent 偏好矩阵 —— 那是把 §8 的 capability flags
重新暴露给用户，让人替系统做本该推导出来的决定。

诚实前提：GUI 在手机上更好，是因为 80×24 网格在 390pt 宽度上读不了、
触控没有原生审批、dormant session 没有字节可放；**不是因为 TUI 不好**。
桌面端不套用这个结论 —— Mac 上终端就是产品本身。

## 8. Per-agent adapter（单一方案，无分档）

方案只有一个：**每个 session = PTY（必有）+ 至多一个 AgentAdapter（可无）**。
adapter 是唯一抽象,所有 agent 走同一接口、同一 host 管线、同一协议 —— 不存在
"模式"或"档位"这个设计维度:

```swift
protocol AgentAdapter {
    var agentID: String { get }
    // 信号源皆为可选实现;实现了什么,能力就有什么
    func transcriptURL(for session: Session) -> URL?          // 内容信号
    func events(tailing url: URL) -> AsyncStream<SessionUpdate>
    func handleHookEvent(_ event: HookEvent) -> [SessionUpdate]?  // 生命周期/审批信号
    func resumeArgv(for session: Session) -> [String]?        // resume 能力
}
```

- **能力是细粒度 flags,不是档位枚举**（LSP 的教训:capability 协商必须按特性,
  不能按等级）:`streamsTranscript`、`emitsApprovals`、`supportsResume`、`reportsUsage`…
  由 adapter 实际接了哪些信号源**推导**,不手工声明,经 `.capabilities` case 下发,
  客户端按 flag 决定点亮哪些 UI。
- **没有 adapter 不是一个"档"**,只是 adapter 缺席:字节面对每个 session 无条件存在,
  裸 shell / 未知 agent 的手机视图自然就是 terminal。降级是**涌现性质**,不是设计分支。
- adapter 单调生长:新 agent 第零天零代码即可用(纯字节面);之后接 transcript、
  接 hooks,每接一个信号源多亮一批 flag —— 管线与客户端零改动。
- 现状对应:Claude adapter 信号最全(hooks+transcript 均已有);Codex/OpenCode
  有 transcript 发现;normalizer 从 `SessionTraceRenderer` 的解析循环重构而来
  (一次性 HTML → 增量 tail → update 事件),提升到 host 层(TermioStore),
  macOS UI 是它的 1 号进程内订阅者。

## 9. 多客户端 envelope 三规则（ACP 缺失、Termio 补齐）

ACP 假设 1:1 本地连接；共享 session 需要 envelope 层规定：

1. **Permission 广播与先答者赢。** 请求广播给所有客户端（Mac TUI 本身也在显示同一菜单）；
   任一端回答后，host 从 hook/transcript 观察到放行，向其余客户端发
   `permission-resolved{by:}` 使过期卡片消失。手机答 → 注入 "1" → Mac TUI 菜单当场收起；
   Mac 在 TUI 里答 → 手机卡片消失。最终都是同一个 TUI 菜单收到一次按键，
   不可能答出两个结果。host 重启时把所有未决请求广播为 cancelled（Happy 的教训）。
2. **每客户端独立 attach/replay 游标。** 断线重连各自用 `subscribeEvents(since:)` 回放再接直播，
   互不影响（PTY 层 ring-buffer + catch-up 的同构模式）。
3. **Presence（可选）。** 轻量在场通知，不影响正确性，影响接管体验。

已解决、不需新机制：PTY 尺寸归属（tmux 式最后活跃客户端持有 + jiggle 回收）。
chat lens 不依赖网格尺寸，进一步缩小了尺寸竞争面。

输入竞态唯一残留：人在 TUI 打半句话时手机注入 prompt 会交错。
bracketed-paste 原子注入已把窗口压到极小；性质同 tmux 双人，不做协议级锁。

## 10. 实施阶段（每步独立可用）

0. **hook 持有的权限问题（可独立发布，不依赖内容面）。** 交互面的最小切片，
   只做 declared 级：`termio agent ask` 新 CLI 动词（读 stdin、走控制 socket、
   **等回答**、打印 `permissionDecision`）+ `question` / `answer` 两条 wire 消息 +
   手机上的一张卡片。先只服务现有的终端镜头 —— 终端照旧渲染，
   底部多一张原生审批卡。不需要 normalizer、不需要 chat 视图、**不需要一行正则**，
   却已经解决手机上最痛的那件事。
   前置：先做完 §6.4 的三条实测。
1. **Normalizer + wire 新 case。** `SessionTraceRenderer`（已能解析 Claude/Codex/Grok
   三种 transcript，969 行一次性 HTML）的解析循环 → 增量、可订阅的 AgentAdapter 管线；
   `CompanionControl` 增加 4 个 case；Claude adapter 打通全部信号源（transcript+hooks），
   只发不收。
2. **只读 chat 镜头（iOS）。** 消息/tool 卡/diff 渲染（消息模型参考 sarea 的
   `ChatMessageContent` 判别联合 + tool-call 连续折叠 + 手势跟随）；输入沿用现有终端注入；
   镜头切换按钮 + 按 session 记忆。**dormant session 历史即刻可看**，这是第一阶段就成立的
   单条最强论据 —— 已强于现 trace HTML 一代。
   （2026-07-03 备份 `~/termio-chatview-backup-20260703/` 可作脚手架。）
3. **审批卡。** hook PreToolUse 驱动 + `answer` 键击注入 + 三规则广播。
   这是 GUI 相对终端的第二条不可替代能力。
4. **Resume 一等公民 + Codex adapter（transcript 信号）+ `.capabilities` + Settings 三档默认视图。**

不动的东西：PTY 层、libghostty 渲染、tunnel/配对、agent 本身、Mac 终端 UI。

## 11. 非目标与诚实边界

- **不做 daemon。** 现架构（host 住 app 进程）满足全部需求；唯一需要 daemon 的场景是
  "Mac 上 app 已退出、手机还想连"。等它成为真实诉求再抽,L1 边界即切割线。
  另见 session-daemon-architecture.md。
- **不跑 ACP/headless 运行时,不做 relay server。**（BYO-tunnel 策略见
  remote-access-relay-strategy.md。）
- **不为了手机而重启 agent。** Happy 的做法是：手机接管时杀掉本地 TUI、用 Agent SDK
  以 headless 流重开一个 session（`claudeRemoteLauncher`），此时 Mac 上的终端退化为一个
  ink 状态板,双击空格才切回本地 TUI。Termio 不做这件事 —— 我们自己持有 PTY,
  两个面来自**同一个活着的 session**,不存在 local/remote 模式切换、不存在会话重启。
  这是 Termio 相对 Happy 的结构性优势,也是本设计不能被"照抄 Happy"取代的原因。
- **GUI 必须靠终端做不到的事立身。** iOS chat UI 曾两次被砍（见 memory:
  termio-ios-chat / termio-chat-lens）,原因一致：气泡只是把终端已经显示的东西
  重画一遍。第三次要成立,验收标准是四条不可替代能力 —— dormant 历史、
  可点审批、原生 diff、plan 清单。做不到这四条就不要重做这个视图。
- **延迟不对称**：结构面隔 transcript 落盘,滞后数百 ms～1s;不承诺与字节面逐帧同步。
- **结构面覆盖不到 TUI 全部**：TUI 内的菜单滚动、/help、ctrl-r 不产生事件 ——
  chat lens 呈现对话而非屏幕;要屏幕就切字节面。
- **TUI permission 菜单 → PermissionOption 的映射是启发式**（hook payload + 菜单解析）,
  偶尔退化为通用 "Option 1/2/3" 标签,可接受。
- **不训练/不内嵌"自动识别任意 TUI 控件"的模型。** yetone 的路线图里有这一条
  （小模型识别未支持控件 → 转义 → 之后走模式匹配）。Termio 走不到那一步就够了：
  最关键的控件根本不用认（§6.4 declared 级）。
  开放集识别是研究赌注,而运行时依赖推理既不可复现也没法做确定性测试。
- **不写"某家 agent 某一版菜单"的正则** —— 无论写在 Swift 里还是写成 manifest 数据。
  observed 级只允许**控件原型**（带光标的单选列表）+ 方向键作答。
  一条规则如果需要知道是 Claude、需要知道是哪个版本,它就不该存在。
- **transcript 格式是各 vendor 的非契约实现细节**,可能随版本变化;
  adapter 解析必须宽容（沿用 TraceRenderer 的 lenient 风格）,破坏时降级不崩溃。
  可借鉴 herdr 的热更新 manifest 思路,把解析规则做成可下发数据。

## 12. Prior Art（2026-07-10/11 调研，2026-08-03 复核 Happy）

| 产品 | 架构 | 对 Termio 的启示 |
|---|---|---|
| Happy (slopus/happy) | CLI 包装 + E2EE relay + RN app;**双 launcher**:local=tail JSONL,remote=Agent SDK 直播 | 见下方复核 |
| vibe-kanban (BloopAI) | 编排器;各家原生 stream-json → 自有 NormalizedEntry | 跨 agent 统一 schema 的词汇;resume token 模型;拒绝 ACP 的理由 |
| sarea（本机 repo） | 原生 SwiftUI chat-first;stream-json headless | iOS 视图层蓝本:ChatMessageContent、内联审批卡、tool 折叠 |
| herdr.dev | **同架构竞品**:PTY host + 真 TUI + 读屏 manifest + hooks | 验证 PTY 路线;其空档（无移动端/结构面）= Termio 差异化;热更新 manifest 可偷 |
| **yetone（2026-08-02 演示）** | macOS 终端 + **渲染层钩子实时识别 TUI 控件 → GUI 重绘**;底下是真终端跑真 Claude Code | §6.4 交互面的直接来源;声明将开源 |

### Happy 复核（2026-08-03，读其仓库 HEAD）

四条可直接采信的结论：

1. **App 里没有终端模拟器。** 全 GUI,一个 `switch(ev.t)` 完事;
   代码里的 "terminal" 只指配对流程。他们把"手机上要不要有终端"这个问题
   回答成了"完全不要"——这是最激进的一端。
2. **协议从 ACP 形状退回扁平 9 事件流**（§5）。
3. **本地模式下 TUI 与 GUI 并存,靠 SessionStart hook + JSONL 扫描**,
   与 Termio 现有信号源完全一致 —— 这条路已被验证可行。
4. **难点全在 subagent 与去重**(`session-protocol-claude.md` 最长的一节):
   孤儿 sidechain 缓冲、provider id 不外泄、重启后按 uuid 去重。
   Termio 用 upsert + seq 可以绕开一半(§6.2),但 `parent` 字段必须第一天就留。

### yetone 演示复核（2026-08-02，X 帖 2083948454116831711，~216k 阅读）

原帖一句话："This is what the Terminal should look like in 2026: Why must your TUI be a TUI at all?"
附 67 秒视频。作者在回复里给出的技术事实：

- **"No, it's a regular standard terminal — it just renders certain TUI widget elements
  with GUI-style appearance and interaction."** —— 不是浏览器、不是 headless、不换运行时。
- **"Added hooks at the rendering layer to parse TUI patterns in real time"** —— 识别发生在渲染层。
- 路线图：抽象一层 GUI，再"integrate a small proprietary model to automatically identify
  unsupported TUI controls and perform escaping on them"，首次昂贵、之后退化为模式匹配。
- 声明会开源。

**对这条路线的判决（2026-08-03 评估，直接决定了 §6.4 的推翻重写）：**

> 产品方向是大道，实现路线是奇技 —— 而且是当前窗口期里很有用的那种奇技。

理由与 Termio 的处境完全对得上：
**问题在于协议不存在，只好读格子。** Ink / Bubble Tea / Textual 各自往 cell buffer 画,
你匹配的是"Claude Code 这一版长什么样",不是系统 API;**升级即断裂**
（改一行布局、权限菜单加第四项,matcher 就废）;yetone 自己要拿小模型兜底,
等于承认 pattern 不够。而**终局不在这里**：若 agent 有一等 UI 协议
（结构化事件：tool call、permission request、diff）,直接画 native UI 才是干净架构,
屏幕反推只是**过渡期兼容层**。做不到收敛,就会停在
**"某个版本 Claude Code 的美颜滤镜"**。

三条可直接抄的收敛判据：(1) 从"针对某家的 pattern"长成**稳定的控件中间表示**；
(2) 模型识别只当 bootstrapping,绝不进运行时；(3) **认不出就老实显示纯 TUI,
绝不半 GUI 半乱**。§6.4 的三级结构就是按这三条重写的 ——
而 Termio 比 yetone 多一张牌：**它装 hooks,所以第一级根本不用读屏。**

视频里被 GUI 化的控件与 Termio 的封闭集高度重合：**权限菜单**（1 Yes / 2 Yes,
allow reading from tmp/ / 3 No）、tool 卡（Write/Read，含 Error writing file）、
状态栏（模型、用量条、manual mode on）、图片输入。
窗口形态（左会话列表 + 右 SESSION/GIT/PROCESSES 检查器 + 标签页）与 Termio 近乎同构 ——
这条赛道上"终端 + agent GUI"的收敛形状已经出现，差异化只能来自**手机**与**hook 真值**。

SDK 资产：随方法层放弃,不再 vendor swift-acp、不再引 Kotlin SDK;
事件类型直接写进 `TermioShared`,与 `CompanionControl` 同一份、两端共享。
ACP 名词的正式来源仍是 agentclientprotocol/agent-client-protocol 的 `schema/v1/schema.json`。
