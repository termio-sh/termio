---
title: 可扩展 Agent —— 配置化定义 + 配置化 Hook
status: in-progress
type: rfc
updated: 2026-07-07
related:
  - 20260719-vibe-island-status.md
---

> **as-built（2026-07-07，Cut 1 已落地）**：`enum AgentPreset` → `struct AgentDefinition`
> 已完成（`Sources/termio/AgentDefinition.swift`）。要点与本 RFC 一致，实现上做了一个降churn的选择：
> - **保留类型名与 case 值**：`typealias AgentPreset = AgentDefinition` + 每个内置 agent 一个
>   `static let`（`.claudeCode` / `.codex` …），并让 `AgentDefinition` **按 `id` 判等/哈希**。于是
>   ~154 处旧调用里绝大多数（`agent == .claudeCode`、`[AgentPreset: T]` 字典键、`.allCases`、
>   `agent.rawValue`、`agent.command/.icon/.displayName`、`agent: .terminal` 默认参数）**零改动**编译通过。
>   真正需要重写的只有 4 处 value-`switch`（`AgentSessionStore.match`、`UsageMonitor.fetch`、
>   `CompanionServer.wireAgent` 正反向）——都改成 `if agent == …` 或按 `wireName` 查表。
> - **持久化零迁移**：`AgentDefinition` 的 `Codable` 用 `singleValueContainer` **只编解码 `id` 字符串**，
>   与旧 `String`-backed enum 的线格式逐字节一致；`Session.agent` 存储字段与其 `init(from:)` 都不用动。
>   实测现存 `state.json` 里 `agent` 就是 `"claudeCode"`/`"codex"`/`"terminal"` 裸串，原样反序列化。
> - **用户 agent 加载**：`AgentCatalog.shared` = 内置数组 + 扫 `~/.termio/agents/<id>/agent.json` 合并
>   （懒加载，首次在 Session 解码时触发，故 `state.json` 加载时用户 agent 必已可解析）。内置 id 冲突时
>   内置胜出；解析失败的 `agent.json` 记日志跳过、不拖垮其余；session 引用了已删除的用户 agent →
>   `AgentDefinition.fallback(id:)` 退化为纯 shell 且以 id 作标题，不丢会话。
> - **图标**：`AgentIcon` 新增 `.imageFile(URL)`（`UserAgentIconView` 从磁盘任意路径加载 NSImage，
>   圆角 tile，加载失败留白）。用户 agent 的 SF Symbol 用其 `tint` 上色（内置无一使用 `.systemSymbol`，
>   无回归）。
> - **本 Cut 不含 hook 配置**（Cut 2）：用户 agent 无 live-status hook，退化到铃/OSC "done" 信号 +
>   [`20260719-vibe-island-status.md`](./20260719-vibe-island-status.md) 的屏幕变化清扫（screen-change 兜底）。对绝大多数
>   本就没有 hook 系统的长尾 agent 这是诚实的表现。
>
> **用户写的 `agent.json`（Cut 1 + 状态检测）**：
> ```json
> {
>   "id": "aider",
>   "name": "Aider",
>   "command": "aider",
>   "permissionBypassFlag": "--yes-always",
>   "installURL": "https://aider.chat",
>   "icon": { "path": "logo.svg" },
>   "status": {
>     "working": ["esc to interrupt", "\\bthinking\\b"],
>     "attention": ["\\(y/n\\)", "do you want to (proceed|apply)"]
>   }
> }
> ```
> `icon` 二选一：`{ "symbol": "<SF Symbol 名>", "tint": "#RRGGBB" }` 或
> `{ "path": "logo.svg" }`（相对该 agent 文件夹，或绝对/`~` 路径）。**SVG 已支持**——`NSImage` 原生
> 用 `_NSSVGImageRep` 渲染 SVG（内置 Pi 图标就是 SVG），`.imageFile(URL)` 路径通吃 PNG/SVG。`command`
> 省略 = 纯 shell；`sandboxStandDownArguments` 可选。放到 `~/.termio/agents/aider/agent.json`，重启即出现。
>
> **状态检测（"忙 / 需要你" 如何测）**：内置 agent 走 hook（精确），但用户的任意 CLI 大多**没有 hook 系统**，
> 唯一通用信号是**渲染出来的屏幕**——这正是 herdr 的路线。所以 `status` 块用正则刮屏（复用我们为
> stale-working sweep 已经在读的 `readViewportText()`，每秒多一次正则）：
> - `status.working`：任一命中 → `.working`（spinner 转起来）。
> - `status.attention`：任一命中 → `.needsAttention`（侧栏标"需要你"，即权限/需人工输入）。**优先级高于
>   working**（提示框可能压在还在转的 header 下）。
> - 两者都不中 → 静止（idle / done：刚从 working/attention 跌落且未选中 = 绿点 done，否则 idle）。
>
> 实现：`AgentStatusRules`（预编译 `NSRegularExpression`，大小写不敏感，整屏匹配，优先级
> `attention > working > idle`）；`TermioStore.applyScreenDetectedActivity` 只在**状态跳变**时改
> `statuses`（idle 屏不会每秒重发 done），working 每 tick 刷 `lastWorkingAt`（静止的 working 屏不会被
> sweep 误清）。**刻意不抄** herdr 的 regions / priorities / 远程 manifest 引擎——两条正则数组足够，表面积最小。
> 无效正则记日志跳过；不写 `status` = 退回零配置铃/OSC。误报靠用户调正则（整屏匹配的固有取舍，已在文档说明）。
>
> **调试（借 herdr 的 `agent explain`）**：设 `TERMIO_STATUS_TRACE=1` 启动 Termio，每次分类往
> `/tmp/termio-status.log` 追一行 `[sess] <agent> → working /matched-pattern/`，用户调 `status` 正则时
> 能直接看到活屏命中了哪条规则（没命中 → idle）。零成本（env 只查一次）。
>
> **已知限制（对标 herdr "live bottom-buffer" 的差距）**：分类读的是 `readViewportText()` = **当前显示的
> 视口**，会跟随用户的 scrollback——把内联渲染的 agent 面板往上滚，分类器就读到过期的行，直到滚回底部自愈。
> herdr 专门读**活跃底部缓冲**规避此问题。这里的干净修法需要 libghostty wrapper 上一个 `readActiveText()`
> （用 `GHOSTTY_POINT_ACTIVE`）——其 blessed 读在私有锁下与 PTY 写串行，而从读泵线程直接发无锁
> `GHOSTTY_POINT_ACTIVE` 读会和 `inMemory.receive` 抢，正是 Termio 栽过的 libghostty 线程 UAF 雷区。
> **故作为上游 ask 记录，不在本仓做不安全的绕路**。影响面小且自愈（仅"有 status 规则的用户 agent"+"滚离底部"时
> 侧栏状态点短暂错，无误动作）。
>
> **更新（2026-07-08，hook 配置化 = Cut 2 tier-1 已落地）**：用户 agent 现在也能声明 `hooks` 块拿到
> **精确**状态（不止刮屏）。三档"侧栏怎么知道状态"的阶梯，从便宜到精确：
> 1. **`status` 刮屏正则**——任何 agent，零代码（上面那节）。
> 2. **`hooks` JSON-hook-file**——仍是**纯数据、无需写任何 JS**，给"自带 Claude/Codex/Cursor 形状 hook
>    文件"的 agent 用。Termio 自己写 report 命令（`reportCommand`），用户只声明 `file` + `dialect` +
>    `events:[{event,state,matcher?}]`。装/卸随全局 hooks 开关（`AgentStatusHooks.installers` 现在 =
>    内置 + 每个带 `hookSpec` 的用户 agent，复用 `JSONHookFile.userAgent(id:spec:)`，零新 installer 代码）。
> 3. **plugin-API agent（Pi/Amp/OpenCode 式）**——**没有 hook 文件，只有各自的插件 API**，事件名/接口都不同，
>    Termio 无法替未知 API 生成插件。这类**只能有人手写插件 JS**。但因为 socket 收任何来源的报文，用户的插件
>    直接往 socket 发 `{termio_session,state,cwd}` 即可（wire 契约文档化），**无需 Termio 配置**；若不想写插件，
>    退回第 1 档刮屏即可。故本仓**不做 pluginFile 配置**（RFC §5.3 早已判定：为未知插件 API 背代码不值当）。
>
> **权威唯一（对标 herdr "one authority per pane"）**：一个 agent 同时声明 `hooks` 和 `status` 时，
> **hooks 胜**——`UserAgentManifest.definition` 里 `hookSpec != nil` 就把 `statusRules` 置 nil，刮屏这条
> 完全不跑，避免两个真相源打架。`AgentHookSpec`（file/dialect/events）+ `HookSpec` DTO。`dialect` 取
> `"cursor"→.cursorFlat`，否则 `.claudeNested`。
>
> **未做（后续 Cut）**：Settings 里增删改 agent 的 UI 与 "live 状态/仅完成" 徽标、file-watch 热加载
> （当前需重启）、给用户 agent 接 resume（当前一律 `.none`）、pluginFile 配置（见上，判定不做）。

# RFC：可扩展 Agent —— 配置化定义 + 配置化 Hook

> 状态：草案（Draft）· 作者：—— · 关联：[`20260719-vibe-island-status.md`](./20260719-vibe-island-status.md)（hook 状态层的前置设计）
>
> 目标：让 Termio 支持任意 CLI coding agent，且用户能**用配置（而非改 Swift、发版本）**新增一个 agent 及其状态 hook。

## 一、摘要（TL;DR）

Termio 当前把 agent 写死成一个**闭合枚举** `AgentPreset`（`Models.swift:18-78`），新增一个
agent = 改 Swift + 发版。而 2026 年的 agent 榜单换得比发版还快（Gemini CLI 2026-06-18 起停服
个人用户、转向闭源 Antigravity；Claw Code 空降第一；Roo Code 自我归档）。结论：**不该用枚举追长尾，
应该把 agent 做成数据。**

本 RFC 提议：

1. `AgentPreset` 枚举 → `AgentDefinition` 值类型；内置 agent 仍在代码里（保留矢量品牌图标），
   用户 agent 从磁盘加载、与内置合并。
2. 采用 **一 agent 一目录** 的打包方式（VSCode extension 的*文件夹*模型，但**只取文件夹，
   不取 manifest / API / 市场**）：`~/.termio/agents/<id>/agent.json`。
3. Hook 也配置化：`agent.json` 里一个 `hooks` 块即可声明该 agent 的状态集成；常见情形是**纯声明
   数据**（event→state 映射），复杂情形提供 **shell 逃生舱**。
4. **明确否决**：内嵌 Lua 运行时、完整插件平台（manifest/activation/API/marketplace）、
   "Termio 进程内执行 agent 代码"的 smart-receive 变体。

不变量保持不变：统一的 wire format（`{termio_session,state,cwd}` 经 `nc -U` 进一个 socket）、
**Termio 自身从不执行 agent 提供的代码**（hook 始终跑在 agent 进程里）。

## 二、动机

### 2.1 枚举是闭合的

今天一个 agent 是 `AgentPreset` 的一个 case，硬编码 `displayName` / `command` /
`permissionBypassFlag` / `icon`。但设置层（`agentCommandOverrides`、`bypassPermissionAgents`、
`disabledAgents`，见 `Settings.swift`）**已经按 `rawValue`（字符串）寻址**，`Session` 也把
`agent` 以 rawValue 字符串持久化（`Models.swift:226-248`）。也就是说——数据模型其实已经*几乎*是
数据驱动的，唯一闭合的就是那个枚举。

### 2.2 长尾 + 高频换血

按 GitHub star（2026-06）：OpenCode ~176k（已内置）、Claude ~131k（已内置）、Gemini CLI ~105k
（**转 Antigravity**）、Codex ~90k（已内置）、OpenHands ~78k、Pi ~64k（已内置）、Cline ~63k、
Goose ~48k、Aider ~46k、Crush、Amp……缺口里大多数是**没有 hook 系统**的 agent。用枚举一个个补，
既追不上换血，也撑爆"小而专"的产品边界。

### 2.3 每个 agent 是一座"岛"

hook 配置散落在各 agent 自己的家里：`~/.claude`、`~/.codex`、`~/.config/opencode`、`~/.pi`，
事件词表也各不相同。要支持任意 agent 的 hook，就得让**岛主（用户）在配置里声明这座岛的 hook 入口
和事件词表**——只有他知道。

## 三、非目标（Non-goals）

- **不**做完整插件平台：没有 manifest schema、activation events、暴露给插件的 API、版本协商、市场。
  那些是为第三方生态服务的；Termio 是单一用途工具，不是平台。除非明确要做 marketplace，否则属于
  "宏大架构"陷阱。
- **不**内嵌 Lua / JS 运行时（理由见 §六）。
- **不**在 Termio 进程内执行 agent 提供的脚本（保留"Termio 从不跑 agent 代码"这一安全/简单性属性）。
- **不**改 wire format、不改 `HookListener` 的 socket 传输层。

## 四、设计

### 4.1 数据模型：`AgentDefinition`

内置与用户 agent 流经同一个值类型：

```swift
struct AgentDefinition: Identifiable, Hashable, Codable {
    var id: String                    // 稳定 slug，与今天的 rawValue 对齐："claudeCode" / "codex" / "aider" …
    var name: String                  // "Aider"
    var command: String?              // "aider"；nil = 纯 shell（即今天的 .terminal）
    var permissionBypassFlag: String? // 可选；启用 bypass 时追加
    var icon: AgentIcon               // 内置用 .brand 矢量；用户 agent 用 .systemSymbol 或 .brandImage(path)
    var hooks: HookSpec?              // 见 §4.4；nil = 无 hook，退化到铃/OSC
}
```

- **内置**：代码里 `static let builtin: [AgentDefinition]`，保留 `BrandIcons.swift` 的矢量品牌图标。
- **用户**：从磁盘加载、追加合并。
- 全 app **一律按 `id: String` 寻址**——设置层三个字典本就如此，零改动。

### 4.2 打包：一 agent 一目录

```
~/.termio/agents/
  aider/
    agent.json          # 声明式定义（"主题"那一半）
  myagent/
    agent.json          # 含 hooks 块
    plugin.js           # 仅当是 tier-2 插件型 agent 时才有
```

- 卸载 = 删目录；分享 = 打包目录。与 `state.json` 同一套目录解析（`TermioStore.swift:979` 的
  Application Support / `~/.termio` fallback）。
- 这是"像 VSCode"里**唯一该取的部分**：文件夹模型。manifest / API / 市场一概不取。
- VSCode 的教训其实反向：**theme 是纯声明数据、不带代码**。agent 定义就是 theme 形状的——是数据，
  不是计算。所以常见情形保持声明式，只为罕见情形留代码逃生舱。

`agent.json` 示例（tier-1 声明式）：

```json
{
  "id": "aider",
  "name": "Aider",
  "command": "aider",
  "icon": { "symbol": "wand.and.stars", "tint": "#14B8A6" },
  "hooks": {
    "kind": "jsonHookFile",
    "path": "~/.aider/hooks.json",
    "events": [
      { "event": "PreToolUse",        "state": "working",   "matcher": "*" },
      { "event": "PermissionRequest", "state": "attention" },
      { "event": "Stop",              "state": "done" }
    ]
  }
}
```

### 4.3 图标

用户 agent 只暴露两种用户*能*提供的模式：**SF Symbol 名 + tint 十六进制**，或 **指向 PNG/SVG
的路径**（复用 `AgentIcon.systemSymbol` / `.brandImage`）。矢量品牌 logo 仍是内置 agent 的代码特权。
保证配置易写，同时内置依旧一等公民。

### 4.4 Hook：三档现实 + shell 逃生舱

现有 hook 层（`HookListener.swift`）的精髓：**wire format 统一、Termio 不做按-agent 解析**，
所有按-agent 知识都被隔离在 *installer* 里，而 installer 只有两种形状：

- `JSONHookFile`（`HookListener.swift:238`）—— Claude 形状 JSON 文件；全部可变性 = `url` + `events`。
- `PluginFile`（`HookListener.swift:382`）—— 往 agent 插件目录丢一个 JS；可变性 = `url` + `contents`。

agent 按 hook 能力分三档，这是"任意岛都能配 hook"无法一键化的根因：

| 档 | 机制 | 例 | 配置能否描述 |
|---|---|---|---|
| **1. JSON hook 文件** | Claude 形状 `{hooks:{Event:[…]}}` | Claude, Codex | **能——纯数据**（path + event→state） |
| **2. 插件丢入** | 用该 agent 自己的插件 API 写 JS | OpenCode, Pi | 部分——需 agent 专属 JS，非数据 |
| **3. 无 hook** | 无 | Aider, Goose, Cline, Crush, 长尾 | **不能**——退化到铃/OSC |

设计动作：

- **Tier-1 配置化（最高杠杆）**：`HookSpec.jsonHookFile(path, events)` 直接构造现有
  `JSONHookFile` struct——**零新 installer 代码**，把静态工厂换成"从配置喂"。
  `AgentStatusHooks.installers`（`HookListener.swift:206`）变成 内置 + 每个声明
  `kind:jsonHookFile` 的配置 agent。
- **Shell 逃生舱**：hook 命令本就是 shell 字符串（`reportCommand`，`HookListener.swift:219`）。
  允许某 event 用自带 shell 片段替代固定的 `printf|nc`，即可在 agent 进程里做分支（按 exit code /
  tool 名 / payload 判 state）——这正是大家想用 Lua 拿到的能力，而 shell 已经在那、零新依赖。

  ```json
  { "event": "PostToolUse",
    "shell": "test \"$EXIT\" = 0 && S=working || S=attention; printf '{\"termio_session\":\"%s\",\"state\":\"%s\"}' \"$TERMIO_SESSION\" \"$S\" | nc -U $TERMIO_SOCK" }
  ```

- **Tier-2 插件**：`PluginFile` 已是通用（`url`+`contents`）。可让配置指 `kind:pluginFile`
  + `path` + 目录内 `plugin.js`，Termio 仅负责带 marker 丢入/安全卸载。**但**几乎没人会照某 agent
  的私有 API 手写插件——**暂缓，不投机**。
- **Tier-3 无 hook**：无可安装，且没关系——已优雅退化。唯一要做的是**诚实**：设置里按 agent 标注
  "实时状态" vs "仅完成（铃）"，免得用户困惑 Aider 为何永不转圈。

### 4.5 持久化与迁移

- `Session.agent: AgentPreset` → `Session.agentID: String`。**只要内置 id 与今日 rawValue 一致**
  （`claudeCode`/`codex`/`opencode`/`pi`/`terminal`），现存 `state.json` 原样反序列化——会话树**零迁移**。
- 设置三字典本就按字符串寻址，零改动。
- **未知 id**（用户删了某 agent 但会话仍引用）：退化为纯 terminal + 用原始 id 作标题，**不丢会话、
  不 trap**——符合 CLAUDE.md "surface failures rather than crashing"。
- 加载时机：启动时扫 `~/.termio/agents/`；可选 file-watch 热加载（nice-to-have，v1 不强求）。

## 五、被否决的方案

### 5.1 内嵌 Lua 运行时 —— 否

决定性事实：**hook 不跑在 Termio 里，跑在 agent 进程里**。Termio 把命令装进 agent 的配置，由
*agent* 执行，Termio 只从 socket 读 JSON。那 Lua 跑哪？

- **agent 进程内** → hook 变 `lua x.lua | nc`，但 macOS 不带 Lua，得 bundle 一个 `lua` 二进制；
  而 shell 已能干这活、零依赖。Lua 只多给"更好的解析语言"。
- **Termio 进程内** → 收原始 payload 后跑 per-agent Lua 归一化。这是**唯一**有意思的变体，但要内嵌
  Lua VM、设计暴露给 Lua 的 API、做沙箱，并**放弃"Termio 从不跑 agent 代码"**。为罕见情形背永久的
  大面积 surface area，违背"小而专"。

Lua 相对 shell 只多"复杂 payload 解析更顺手"，这场景稀少到不值一个内嵌解释器。**用 shell 逃生舱替代。**

### 5.2 完整插件平台（manifest/API/marketplace）—— 否（除非要做生态）

那套基础设施是为第三方生态存在的。没有 marketplace 意图时，"文件夹 + 声明式 `agent.json` +
shell 逃生舱"以 5% 成本拿到 95% 收益。

### 5.3 Smart-receive（Termio 跑归一化脚本）—— 否

今天是 smart-install / dumb-receive（装 N 条 per-event 入口，各自硬编码 state）。插件式替代是
dumb-install / smart-receive（装一条转发原始 payload，Termio 跑 per-agent 脚本归一）。它能把
per-agent 逻辑集中到一个文件（很"插件"），**但**正是要在 Termio 内跑 agent 代码的那个变体，且只对
"单一 catch-all hook + 全 payload"的 agent 成立（Claude 仍需 per-event matcher）。集中化的收益
不抵丢失隔离的代价。

## 六、风险

- **声明了事件 ≠ agent 真会触发**。代码自己都不确定 Codex 是否真发 hook（`HookListener.swift:150-167`
  的 `TERMIO_HOOK_TRACE` 诊断就在查"Codex TUI 到底发不发、`termio_session` 是否活着进到 hook"）。
  → 把 trace 作为"测试你 agent 的 hook"的文档化步骤，别假设声明即生效。
- **shell 逃生舱 = 任意代码执行**。但用户在自己配置里写自己的 shell，信任级别等同其 shell rc；且仍跑在
  agent 进程，不在 Termio。可接受。
- **路径/解析健壮性**：拒绝改写无法解析的文件（现有 `JSONHookFile` 已如此）；`agent.json` 解析失败应
  跳过该 agent 并记日志，不影响其余。

## 七、实现切分

- **Cut 1（小、价值高）**：`AgentPreset` → `AgentDefinition` + 内置静态数组；`Session` 改
  `agentID: String`；扫 `~/.termio/agents/*/agent.json` 合并。**仅此**就让用户用 SF Symbol 图标
  自助加 Aider/Goose/Cline/Amp/Gemini。无需新 UI（设置页本就遍历列表）。
- **Cut 2（hook 配置化）**：`HookSpec.jsonHookFile` 从配置构造现有 `JSONHookFile`；加 `shell`
  per-event 覆盖字段。让任意 Claude/Codex 形状的岛**零 Swift 改动**可加。
- **Cut 3（打磨）**：设置里 per-agent "实时状态 / 仅完成" 徽标；"编辑 agents 目录"按钮；可选 file-watch；
  可选补 2–3 个带真品牌图标的内置（Gemini/Antigravity、Aider、Cline）。

## 八、待定问题

1. Gemini 正处 CLI→Antigravity 过渡，要不要现在就内置，还是等 Antigravity 稳定？
2. 一目录一 agent 是否同时取代扁平设置，还是 `agent.json` 仅承载定义、用户偏好仍留 UserDefaults？
3. tier-3 agent 的"死感"——除诚实标注外，是否值得做一个轻量推断（如基于 PTY 输出节流的"疑似在忙"）？
4. shell 逃生舱是否需要一个 `$TERMIO_SOCK` / `$TERMIO_SESSION` 的稳定契约文档？
