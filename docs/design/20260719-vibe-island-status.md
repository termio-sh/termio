---
title: Vibe Island 式 Agent 状态层（Claude Code hooks）
status: done
type: design
updated: 2026-07-19
---

# 设计：Vibe Island 式 Agent 状态层（Claude Code hooks）

> 目标：把竞品分析 `docs/competitive-analysis/07-vibe-island.md` 里 "状态监控方法论" 落到 Termio。
> Termio 已经做完了**结构性的难活**，本设计只补上唯一缺口：可靠的"忙 / 思考中 / 在用哪个工具"。

## 一、为什么这是个小改动

Termio 当前的状态链路（已存在，勿重写）：

- `SessionStatus`（`Models.swift:175`）：`idle / working / needsAttention` 三态。
- `TermioStore.monitor(_:for:)`（`TermioStore.swift:333`）：订阅 libghostty 已发布的
  `lastBellAt` / `lastDesktopNotificationAt`，在用户不在看该会话时置
  `statuses[id] = .needsAttention`。**零配置**——Claude Code 原生发 OSC 9/99，
  Ghostty 直出，Termio 直接消费。

唯一缺口写在代码注释里（`Models.swift:172`）：

> `working` is reserved for the Claude Code hooks layer: the zero-config surface
> signals expose command-*finished* but not per-turn command-*start*…

也就是：表面信号能告诉你"刚响了一声铃（完成/需要你）"，但**无法**告诉你"现在正在思考"。
`.working` 这个枚举值已经造好、UI（侧栏 `StatusDot`、菜单栏 `circle.dotted` 脉冲）也已接好，
**就是没有任何代码去 set 它**。本设计就是把它驱动起来。

| 状态 | vibe-island 来源 | Termio 现状 | 本设计 |
|---|---|---|---|
| 需要你（铃 / 权限） | OSC 9·99 / hooks | ✅ 零配置 → `.needsAttention` | 保留为 fallback |
| 完成（离开时收尾） | `Stop` hook | ✅ 铃声近似 | hook 精确化 |
| 忙 / 思考中 / 用哪个工具 | `UserPromptSubmit`/`PreToolUse` | ❌ `.working` 从不被 set | **本设计补上** |

## 二、架构：`hook → unix socket → reducer → 既有 UI`

照搬 `Octane0411/open-vibe-island` 的蓝图，但 Termio 因自有 PTY，比所有外挂都更稳
（不需要 `claude-watch` 那种 tail `~/.claude/projects/*.jsonl` 的脆弱推断）。

```
Claude Code 子进程
   │  (hook 事件，stdin 一行 JSON)
   ▼
~/.claude/settings.json 里的 hook 命令
   │  把 stdin（含 cwd / session_id）转发到 socket
   ▼
HookListener (新文件)  ──解码──▶  HookEvent
   │
   ▼
TermioStore.applyHookEvent(_:)  (reducer)  ──写──▶  statuses[id]
   │
   ▼
既有 UI：SidebarView.StatusDot / MenuBarController（无需改）
```

> **更新（2026-07-19，channel-stable CLI path + 广播）**：修复一个真实事故——worktree 里
> 构建/启动的 dev app 把**自己 bundle 内的 CLI 绝对路径**盖进了所有 agent 的全局 hook 文件，
> worktree merge 后删除，路径失效，每个 agent 的每次工具调用都刷 hook 报错。三点修正：
> - **hook 只引用 channel 稳定路径**：app 每次启动把打包的 CLI **拷贝**到
>   `~/Library/Application Support/termio[-dev]/bin/termio[-dev]`
>   （`CommandLineTool.refreshSupportCopy`，内容比对 + 原子写 + 0755），hook 与
>   `/usr/local/bin` symlink 一律指向该拷贝。路径永不变；worktree 删除后拷贝仍在，零失效窗口。
> - **CLI 广播**：`agent report` 不再只写本 channel 的 socket，而是向 `termio` 与
>   `termio-dev` 两个 support 目录的 `agent-status.sock` 都发（缺失即跳过）。dev/prod 两个
>   app 共存共享同一份全局 hook 文件时，不论最后由谁安装，两边都收到报告。
> - **收端按 id 路由，杜绝串台**：`sessionID(for:)` 对"带 session id 但本 app 不认识"的
>   报告直接丢弃（那是另一 channel 的会话），cwd 兜底只服务完全没带 id 的手动启动 agent。
>   hook 命令尾部加 `2>/dev/null || true`（Cursor 为 `|| printf '{}'`），路径万一损坏时
>   静默降级而非刷屏。
>
> **更新（2026-07-18，final as-built，多 agent）**：下面 §1 的 cwd 方案已被
> **env-id 注入**取代为主关联键，并从单一 Claude 扩展到声明 hooks 的全部内置 agent。要点：
> - **注入**：`TermioStore.surface` 给每个 PTY 设 `builder.withCustom("env", "TERMIO_SESSION=<session.id>")`
>   （已实测 Ghostty 的 `env` 键对 `.exec` 生效，shell 里 `$TERMIO_SESSION` 正确展开）。
> - **公共上报契约**：每家 agent 的 hook 都调用 channel-correct 的绝对路径
>   `termio[-dev] agent report <working|attention|done|idle>`。CLI 读取 `TERMIO_SESSION` / `PWD`，
>   再向对应 channel 的 socket 写同一个归一化 JSON
>   `{"termio_session","state","cwd"}`；raw `printf | nc` 已成为 CLI 后面的实现细节。
>   "哪个事件=什么 state" 在**安装时**写死，Swift 端零按-agent 解析
>   （`StatusReport` + `applyStatusReport`）。
> - **关联**：`sessionID(for:)` 先按 `termio_session`（UUID 精确命中），cwd 仅作兜底。同目录多会话
>   不再有歧义，Claude-narrowing 启发式已删。
> - **manifest 驱动安装器**（`AgentStatusHooks.sync`）：
>   - Claude `~/.claude/settings.json`、Codex `~/.codex/hooks.json`、Cursor
>     `~/.cursor/hooks.json` —— `JSONHookFile` 合并 Termio 自己的条目，保留用户配置。
>   - Kimi `~/.kimi/config.toml` —— `TOMLHookBlock` 维护 marker 包围的 Termio block。
>   - Grok `~/.grok/hooks/termio.json` —— Grok 自动发现的 Termio 专属 JSON 文件。
>   - OpenCode `~/.config/opencode/plugin/termio.js`、Pi `~/.pi/agent/extensions/termio.js`、
>     Amp `~/.config/amp/plugins/termio.ts` —— `PluginFile` 写入 Termio 自带模板。
>   - 升级时只删除内容可确认为 Termio 所有的旧 `termio-status.*` 文件；若简洁新文件名已被
>     用户文件占用则拒绝覆盖，避免重复 hook 或破坏用户配置。
> - **实测**：Claude 全链路（spinner+env-id 命中）已验；Codex `codex exec` 实跑确认 hooks 触发
>   （`hook: UserPromptSubmit` / `hook: Stop`）；全部 JSON/TOML/plugin 文件已生成并通过语法检查，
>   Grok/OpenCode/Pi/Amp 的旧文件名迁移也已由 dev app 实跑确认。
>
> **更新（best-design，对标 open-vibe-island + cmux 调研）**：状态模型从 3 态扩成 4 态
> `idle / working / done / needsAttention`——**完成 ≠ 需要你**：`Stop`→`.done`（绿点"轮到你了"，
> 平静），`needsAttention`（橙）只留给真正阻塞在用户上的事件。因此 Claude hook 把
> `Notification→attention` 换成 **`PermissionRequest→attention`**（Notification 也会在 idle 等待时触发，
> 会把刚 done 的会话错误标橙）；零配置 bell/OSC 仍是所有 agent 通用的"需要你"兜底。另加
> **stale-`.working` 清扫**（`lastWorkingAt` + 30s Timer，>300s 无活动且仍 working → idle，
> 救回中途崩溃的 agent——正是 cmux issue #3749 缺的兜底）。安装器修了一个 bug：`install` 现在跨
> *所有* hook 事件清除 Termio 旧条目，删掉某事件映射时不会留孤儿。
>
> **更新（2026-07-07，screen-change 兜底，对标 herdr 调研）**：stale-`.working` 清扫的活性判据
> 从"有没有 PTY 字节流动"改成"**渲染出来的屏幕有没有变化**"。原判据的漏洞：agent 跑完停在 idle
> 输入框时，终端仍会零星吐字节（重绘、光标闪烁），`noteOutputActivity` 把这些当成"还在忙"不断刷新
> `lastWorkingAt`，于是 12s 清扫永远等不到"安静"，spinner 卡死不停（实拍复现：选中的 Claude 会话
> 已停在 `❯` 提示符仍转圈）。修法：在 PTY sink 里调 `InMemoryTerminalSession.readViewportText()`
> 取当前视口文本、哈希比对，**只有内容变了才刷新时间戳**；正在思考的一轮会逐秒重绘变化内容（滴答的
> 计时 spinner、流式 token）→ 保持 working，停在静止提示符 → 屏幕不变 → 清扫在 ~12s 内清掉。纯通用
> 判据，无需 per-agent 正则。`readViewportText` 自带锁、线程安全，哈希比对在读泵线程上跑，只把
> changed 标志 hop 回主 actor（`noteOutputActivity(_:screenChanged:)`）。
>
> 这是从 [herdr](https://github.com/ogulcancelik/herdr) 借来的**唯一**高价值点：herdr 全程用
> **屏幕刮取 + per-agent manifest 正则**（`❯` 提示框=idle、OSC 标题盲文 spinner=working、
> 未知即 idle 兜底）当唯一真相源，天然不会卡死——但代价是要养 18 家 agent 的 manifest（脆、需远程
> 更新）。Termio 的 hook 层是**精确**信号（工具名、transcript 路径），不该丢；只把 herdr 的
> "屏幕内容才是活性真相"用作 hook 缺失时的**通用兜底**，不引入 manifest。这也部分回答了
> `20260707-agent-extensibility.md` §八 #3 那个"tier-3 死感 / 轻量推断"的待定问题——recovery 方向已解，
> "无 hook 的 agent 从不转圈"那半仍待办。
>
> 以下 §1 原 cwd 方案保留作背景。

### 1. 关联键：cwd → worktreePath（主方案）

hook 事件回来后，Termio 要回答"这是我哪个会话？"。hook payload 自带 `cwd`，而每个会话
跑在自己的 worktree 目录（`session.worktreePath`，逐会话唯一）。所以
**`event.cwd → worktreePath` 直接精确命中，零注入、零 libghostty API 风险**。
这是 Termio 因自有 PTY + 每会话 worktree 拿到的免费关联键。

唯一的歧义：**worktree 关闭**时，同一 project 下多个会话共享 `project.path`，cwd 撞车
（实测就是常态：一个 repo 里跑一个 Claude Code + 一个普通 Terminal）。**as-built 解法**
（`TermioStore.sessionID(forCwd:)`）：

1. 先按 `(worktreePath ?? project.path)` 精确匹配；命中唯一 → 用它（worktree 开启时就走这条）。
2. 歧义时——**只有 Claude Code 会发这些 hook**，所以把候选收窄到 `agent == .claudeCode`
   的会话；唯一 → 绑定它。这覆盖了"1 个 Claude + N 个终端同目录"的真实主场景。
3. 仍真歧义（同目录两个 Claude Code 会话）→ 留在原状态，不乱猜。

> **env id 仍是可选的更后面 fallback**，仅当"同目录两个 Claude 会话"这种边角也要精确时才需要：
> 注入 `TERMIO_SESSION=<uuid>` 到 PTY、让 hook 回传。当前 Claude-Code-收窄启发式已够，未做。

### 2. 传输：unix domain socket

- 路径：`~/Library/Application Support/termio/agent-status.sock`（app 启动时
  bind，退出时 unlink）。比 TCP 回环更安全：无端口冲突、靠文件权限隔离。
- 协议：一行 JSON（NDJSON），来一个事件断一次连接，足够简单。

### 3. Hook 命令与自动安装

Claude Code hooks 在 `~/.claude/settings.json`，按事件跑 shell 命令，hook 输入从
stdin 给 JSON（含 `hook_event_name` / `tool_name` / `cwd` / `session_id`）。

Termio 启动时**幂等地**写入（已存在则跳过）一组 hook，命令形如：

```jsonc
// UserPromptSubmit / PreToolUse / PostToolUse / Notification / Stop / SubagentStop
"command": "nc -U \"$HOME/Library/Application Support/termio/agent-status.sock\""
```

- hook 输入（含 `cwd` / `session_id` / `hook_event_name` / `tool_name`）从 stdin 原样
  灌进 socket，`HookListener` 端解码——不需要 `jq` 改写 payload，cwd 已在里面。
- `nc -U` 走 unix socket，macOS 自带。若担心精简环境无 `nc`，换 Termio 随包的极小转发
  二进制 / 脚本，读 stdin 直送 socket。
- 自动安装要**克制**：只追加 Termio 自己的 hook 条目（带可识别标记便于卸载/升级），
  绝不覆盖用户已有 hooks。设置里给一个开关 + "重装/移除 hooks" 按钮。

### 4. Reducer：事件 → 三态

新增 `TermioStore.applyHookEvent(_ event: HookEvent)`，按 `event.cwd → worktreePath`
命中 `id` 后：

| hook 事件 | 置为 | 备注 |
|---|---|---|
| `UserPromptSubmit` | `.working` | 这一轮开始 |
| `PreToolUse` | `.working` | 可顺手存 `tool_name` 做 tooltip |
| `PostToolUse` | `.working` | 仍在轮内 |
| `Stop` / `SubagentStop` | 选中→`.idle`；未选中→`.needsAttention` | "完成"（离开时变需要你） |
| `Notification`（权限） | `.needsAttention` | 见下"最难的状态" |

- 与既有 bell/OSC `monitor()` **共写同一个 `statuses[id]`**，天然共存：hook 在时给精度，
  没装 hook 时退回零配置铃声。无需删除 `monitor()`。
- 选中会话清除 `.needsAttention` 的既有逻辑（`selectedSessionID` 判断）保持不变。

### 5. "在用哪个工具" 的精度（可选增量）

`PreToolUse.tool_name` 存进按会话的一个 `currentTool: [Session.ID: String]`，
在侧栏行/菜单栏 tooltip 显示 "Running bash…""Editing file…"。这是竞品文档说的
"逐轮思考中 / 在用哪个工具"。属锦上添花，可二期。

## 三、"等你输入"是最难的状态（照搬竞品结论）

Claude Code 只有 `Notification` 一个信号，且把"等权限审批（可靠、即时）"与
"等自由文本回答（~60s 定时器近似）"混在一起。Termio 的处理：

- **权限审批**：`Notification` → `.needsAttention`，可靠。
- **等自由文本**：`Stop` 之后若长时间无 `UserPromptSubmit`，用一个 ~60s 定时器近似
  推 `.needsAttention`。属 best-effort。
- 好在 Termio 的 bell/OSC 已经把"需要你"兜住了，hook 层主要贡献是把 **`.working`**
  做实，而不是去啃这个最难的细分。

## 四、改动清单（最小面）

- **新增** `Sources/termio/HookListener.swift`：socket bind / accept / 解码 `HookEvent`。
- **新增** hook 自动安装逻辑（可并入 `HookListener` 或一个 `ClaudeHooksInstaller`）。
- **改** `TermioStore`：新增 `applyHookEvent(_:)` reducer（按 cwd 命中会话）；启动时
  拉起 `HookListener`。
- **不改**：`SessionStatus`、`StatusDot`、`MenuBarController`、既有 `monitor()`、
  `surface(for:in:)`——全部复用，无需碰 PTY 命令/环境。`.working` 终于有人 set 了。
- 设置里加：hooks 开关 + 重装/移除按钮（遵循"克制、不覆盖用户配置"）。

## 五、形态决策（已定，记录在案）

Termio 选**菜单栏托盘**（已做），不做刘海。更克制、不挡内容——与竞品文档结论一致。
本设计不引入任何新窗口/HUD。

## 六、开放问题（实现前确认）

1. hook 命令是否依赖 `nc`（系统自带但可被裁剪环境删掉）vs 随包小转发二进制。
2. `Stop` 在选中会话时是否要有一个一闪而过的"完成"反馈（绿点），还是直接回 `.idle`。
3. worktree 关闭时的同目录歧义：先做"单一未匹配会话即绑定"的退化匹配够不够，
   还是干脆把 hooks 层只在 worktree 开启时启用。（env id 是更后面的 fallback。）

## 参考

- 蓝图：https://github.com/Octane0411/open-vibe-island （`hook → socket → reducer`）
- 冗余通道参考：https://github.com/gmr/claude-status
- 无 hook tail 方案（Termio 不需要）：https://github.com/sooink/claude-watch
- Claude Code Hooks：https://code.claude.com/docs/en/hooks-guide
- 竞品分析原文：`docs/competitive-analysis/07-vibe-island.md`
