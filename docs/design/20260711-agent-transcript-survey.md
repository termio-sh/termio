---
title: 调研：下一批 AgentAdapter 的落盘格式（OpenCode / Pi / Amp / Cursor / Kimi）
status: draft
type: design
created: 2026-07-11
updated: 2026-07-11
---

# 调研：下一批 AgentAdapter 的落盘格式

移动端结构面（docs/design/20260711-mobile-agent-ui-protocol.md §7）要求每个 agent 一个
adapter，从它自己的落盘 transcript 增量推导 ACP `session/update`。Claude 已上线、
Codex 进行中。本文对 OpenCode、Pi、Amp、Cursor、Kimi 五个候选逐一回答：落盘在哪、
粒度够不够、怎么 tail、怎么发现、做不做。

结论先行（按性价比排序）：**Pi ＞ OpenCode ＞ Kimi ＞ Amp（暂缓）＞ Cursor（暂缓）**。

验证方法：本机真实数据 + 向 roster 里 idle 的 OpenCode/Pi/Amp session 各注入一条
`reply with just: ok`，用 `find -newer` 对比数据目录变化（2026-07-11 实测）。
Cursor 本机未安装、Kimi 未登录（headless 报 No model configured），二者靠已有落盘
残留 + 开源仓库/公开资料初判。

---

## 1. Pi —— 可做，性价比最高

**落盘**：`~/.pi/agent/sessions/<encoded-cwd>/<ISO时间戳>_<UUID>.jsonl`，
一个 session 一个 append-only JSONL（Claude 同构）。encoded-cwd 形如
`--Users-yuanjiwei-Documents-GitHub-termio--`（`/`→`-`，前后加 `--`）。
实测：注入后消息逐行追加到既有文件尾部。

**记录粒度 → 六变体**（实测样本）：

| 变体 | 有无 | 来源 |
|---|---|---|
| user chunk | 有 | `type:"message"` → `message.role:"user"`，content `text` 块 |
| agent chunk | 有 | `role:"assistant"` 的 `text` 块 |
| thought chunk | 有 | `assistant` 的 `thinking` 块（含 thinkingSignature，忽略即可） |
| tool_call（含 diff） | 有 | `assistant` 的 `toolCall` 块 `{id,name,arguments}`；**edit 工具 arguments 直接是 `{path,oldText,newText}`** → ACP diff content 零启发式 |
| tool_call_update | 有 | `role:"toolResult"` 消息 `{toolCallId,toolName,content,isError}` |
| usage_update | 有 | 每条 assistant 消息带 `usage{input,output,cacheRead,cacheWrite,totalTokens,cost}`；**窗口大小不在 transcript** → 需 model→window 常数表（heuristic，同 Claude 的 200k 常数做法） |

其它入账类型：`session`（首行，含 cwd）、`model_change`、`thinking_level_change`，
跳过即可。条目有 `parentId` 树结构（支持 fork），线性 tail 场景直接忽略。

**Tail**：append-only 完整行 → 现有 `TranscriptTailer` 直接复用，零新机制。

**发现**：**Termio 已经 pin 了**——`AgentDefinition.swift:130-134` 启动即传
`--session-id <resumeID>`（创建即用我们的 id，resume 同一开关）。adapter 的
`transcriptURL` = encoded-cwd 目录里 glob `*_<resumeID>.jsonl`（文件名带时间戳
前缀，所以是一次 glob 而非拼路径）。实测注入产生的文件名 UUID 正是 Termio 的 id。

**结论：可做。** ClaudeAdapter 的孪生：一个 `PiAdapter`（transcriptURL glob +
mapper ~200 行），无新 tailer、无发现逻辑。预估半天内含真机验证。resume 能力
（`resumeArgv`）也是现成的。

---

## 2. OpenCode —— 可做，但要一个 SQLite tailer（并顺手修一处既有腐烂）

**落盘（重要变化）**：v1.17.x 已迁移到 **SQLite**：
`~/.local/share/opencode/opencode.db`（WAL 模式，Drizzle 建表）。
`~/.local/share/opencode/storage/{session,message,part}/**` 的 per-record JSON
文件树是**旧版遗留**，本机自 1 月后不再更新；实测注入的新消息只进 db 不落旧文件。
**这意味着 `AgentSessionStore.matchOpenCode` 读的是死数据——现有 OpenCode 发现
逻辑对当前版本已失效**，做 adapter 时顺手改成 SQL 即修复。

关键表（`sqlite3 file:...?mode=ro` 实测）：
- `session(id, project_id, directory, title, time_created, time_updated, tokens_*, cost, …)`
- `message(id, session_id, time_created, time_updated, data JSON)`——data 含
  `role`、`tokens{input,output,reasoning,cache}`、`time.completed`、`error`
- `part(id, message_id, session_id, time_created, time_updated, data JSON)`——data
  `type` ∈ `text | reasoning | tool | patch | step-start | step-finish`
- `event(aggregate_id, seq, type, data)`——`message.updated` / `message.part.updated` /
  `session.updated` 事件日志，但仅 37 行、疑似会修剪，不作依赖

**记录粒度 → 六变体**：

| 变体 | 有无 | 来源 |
|---|---|---|
| user chunk | 有 | user message 的 `text` part；**须过滤 `synthetic:true`**（注入的 system-reminder、search-mode 前缀等） |
| agent chunk | 有 | assistant message 的 `text` part |
| thought chunk | 有 | `reasoning` part |
| tool_call（含 diff） | 有 | `tool` part `state{status:pending/running/completed/error, input, output, title, metadata}`；**edit 工具 input = `{filePath,oldString,newString}`** → diff 零启发式；`patch` part 另给文件级变更摘要 |
| tool_call_update | 有 | 同一 `tool` part 的 `state.status` 原地跃迁（row UPDATE，靠 `time_updated` 观测） |
| usage_update | 有 | `step-finish` part 的 `tokens{...}` + assistant message data 的 `tokens`；窗口大小不在库里 → model 常数表 heuristic |

**Tail**：**不是追加，是 INSERT + 原地 UPDATE** → `TranscriptTailer` 不适用。
需一个 `SQLiteTailer`：只读打开（`mode=ro`，WAL 并发读安全），~700ms 轮询
`SELECT ... FROM part WHERE session_id=? AND time_updated>? ORDER BY id`；
- text/reasoning part 流式期间会被反复 UPDATE → 记住每 part 已发长度，发**后缀**
  作为 chunk（与 chat lens 的 append 语义正好吻合）；
- tool part 状态跃迁 → 首见发 `tool_call`，后续变更发 `tool_call_update`。
macOS 系统自带 libsqlite3，Swift 直接 `import SQLite3`，无新依赖。

**发现**：比文件时代更强——`session` 表有 `directory` + `time_created`，
launch-time 匹配一句 SQL；`opencode run` 有 `--session`，TUI 无 pin（维持匹配式）。

**结论：可做。** 一次性投入 SQLiteTailer（~150 行）+ mapper（~250 行）+
AgentSessionStore 改 SQL（顺手修复既有失效）。预估 1–1.5 天。是三个"可做"里
唯一新 tailer，但 OpenCode 是用户真实高频 agent，值得。

---

## 3. Kimi (kimi-code) —— 可做，缺一次登录后的实测

**落盘**：`~/.kimi-code/sessions/wd_<basename>_<hash>/session_<uuid>/agents/main/wire.jsonl`
（append-only 事件日志，`protocol_version 1.4`）+ 同目录 `state.json`（含 workDir、
agents 表）+ 根部 `session_index.jsonl`（append-only：sessionId → sessionDir + workDir）。
子 agent 各有自己的 `agents/<id>/wire.jsonl`（sidechain 天然隔离）。
官方文档（docs/en/guides/sessions.md）确认 wire.jsonl 即"session recovery and
replay 的事件流"。

**记录粒度 → 六变体**（源码 `packages/agent-core/src/agent/records/types.ts`，
开源可查；本机 wire.jsonl 只有迁移壳，未登录无法产真实样本）：

| 变体 | 有无 | 来源 |
|---|---|---|
| user chunk | 有 | `turn.prompt {input: ContentPart[], origin}` |
| agent / thought chunk | 有（需实测块形状） | `context.append_message {message: ContextMessage}`——kosong 的 ContentPart 含 text/think/tool_call 类块，具体字段名需真实样本确认 |
| tool_call / tool_call_update | 有（diff 需实测） | 同上，tool 调用与结果都走 `context.append_message`；kimi 内置 edit 工具参数是否携带 old/new 全文未验证 |
| usage_update | 有 | `usage.record {model, usage: TokenUsage}` |

噪音类型（跳过）：`metadata`、`config.update`（含整个 system prompt）、
`tools.set_active_tools`、`llm.request`/`llm.tools_snapshot`（observability）、
permission/plan_mode/compaction 等。注意 `context.apply_compaction` 会改写上下文，
但对只读 chat lens 无影响（我们不重建 agent 状态，只播消息）。

**Tail**：append-only → `TranscriptTailer` 直接复用。

**发现**：`session_index.jsonl` 是现成的 append-only 索引（workDir 字段精确匹配 +
mtime after launch）；比 Codex 的目录扫描还省。`kimi -S <id>` 有 resume、无
create-with-id → 不能 pin，走 launch-time 匹配。

**结论：可做（第三顺位）。** 阻塞项唯一：本机 kimi 未配置模型（`-p` 报
No model configured），`context.append_message` 的块形状与 edit-diff 有无未实测。
登录后跑一条真实会话即可开工；mapper 预估 ~250 行 + 半天。
（旁注：kimi 有原生 `kimi acp` ACP-server 模式——它是唯一原生说 ACP 的候选，但
Termio 架构是 PTY+旁路 transcript，TUI 与 acp server 不共存，仍走 wire.jsonl。）

---

## 4. Amp —— 暂缓：线程内容不落本地盘

**落盘**：没有本地 transcript。实测注入后本地仅出现：
- `~/.local/share/amp/session.json`——UI 状态，含 `lastThreadByTerminal`
  （**tty → threadId 映射**）
- `~/.local/share/amp/history.jsonl`——仅 prompt 文本历史 `{text,cwd}`
- `~/.cache/amp/logs/threads/T-<id>.log`——运营日志（transport 状态机），无消息内容
- `~/.amp/file-changes/T-<id>/`——被编辑文件的备份（本次为空）

线程内容在 ampcode.com 服务端（"usesThreadActors"）。`amp threads export T-<id>`
可拉回完整 JSON（v8：`messages[]` content 块、env、meta），实测可用——但这是
服务端往返，不是可 700ms 轮询的本地面。

**六变体**：export JSON 里 user/agent 文本可映射；tool/usage 块形状未深究——
因为信号源本身不成立，粒度评估无意义。

**发现（讽刺地容易）**：Termio 持有 PTY 的 tty 名 → `session.json.lastThreadByTerminal`
精确给出 threadId；或 logs/threads/ 新文件 mtime 匹配。发现能做，内容拿不到。

**结论：暂缓。** 缺的是本地内容面。两条未来路线：
1. dormant 回放场景用 `amp threads export` 一次性拉取（历史可看，直播缺失）；
2. Termio 已给 Amp 装 hook 插件（`~/.config/amp/plugins/*.ts`）——若插件 API 能
   订阅 thread 事件，可让插件把事件推给 Termio，绕开落盘。需另行调研插件 API 面。

---

## 5. Cursor (cursor-agent CLI) —— 暂缓：本机无数据 + 格式无契约

**落盘（公开资料初判，本机未安装 CLI、无 `~/.cursor/chats`）**：
`~/.cursor/chats/<md5(cwd)>/<session-uuid>/store.db`——SQLite，仅 `meta` +
`blobs` 两表；meta 含 agentId/name/mode/createdAt/`latestRootBlobId`；对话是
JSON blob 组成的图，根在 latestRootBlobId，无官方 spec，社区工具
（cursor-history、cursor-session 等）靠逆向解析。IDE 侧的
`state.vscdb`（globalStorage）是另一套，与 CLI 无关。

**六变体**：社区已证明能提取 user/agent/tool 内容 → 理论上映射得出，但 blob DAG
的遍历与版本漂移都是逆向负担；diff/usage 有无未知。

**Tail**：SQLite 原地写 → 需 OpenCode 同款轮询 tailer + blob 图重放，成本更高。

**发现**：`md5(cwd)` 目录名 + createdAt 匹配，straightforward。

**结论：暂缓。** 双重欠账：本机没有 cursor-agent 使用数据可验证；格式是无契约的
逆向产物（对比 Pi/Kimi 的自述格式、OpenCode 的规整 schema，风险最高）。等有真实
使用需求 + 装机数据再评。若届时只需 headless，cursor-agent 有
`--output-format stream-json`，但那是换 agent 运行方式，违背"旁路不改运行"原则。

---

## 推荐开工顺序

| 顺位 | Agent | 理由 | 预估 |
|---|---|---|---|
| 1 | **Pi** | TranscriptTailer 复用、diff 原生、`--session-id` pin 已存在——ClaudeAdapter 孪生 | ~半天 |
| 2 | **OpenCode** | 数据最全、用户高频；SQLiteTailer 一次性投入，顺手修复 AgentSessionStore 的 stale 文件层 | 1–1.5 天 |
| 3 | **Kimi** | tailer 复用 + session_index 现成；等登录实测一条真实会话 | ~1 天（含实测） |
| 4 | Amp | 无本地内容面；等 export 回放需求或插件 API 调研 | — |
| 5 | Cursor | 无数据 + 无契约逆向 | — |

三个"可做"共享的一个既有资产：mapper 全部是纯函数（`[String:Any] → [SessionUpdate]`），
与 Claude/Codex 同构，管线与客户端零改动——正是 §7"adapter 单调生长"的预期路径。
