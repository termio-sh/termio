---
title: 会话历史 · 搜索 · 恢复（Session History / Search / Resume）
status: approved
type: design
created: 2026-06-28
updated: 2026-07-03
---

# 设计：会话历史 · 搜索 · 恢复

> **BACKLOG（暂不实现）**：方向已认可，但短期不做。这里是已对齐的设计存档，
> 待日后排期再启动。当前主线是 `20260628-session-share.md`。
>
> 目标：把 Termio 从「一次性终端」升级成「有记忆的 agent 工作台」。
> 用户能**搜索自己跑过的会话** →**点击** →在**新 pane 里恢复**接着聊。
>
> 竞品参考：`jazzyalex/agent-sessions`（只读事后查看器）。Termio 拥有 PTY，
> 所以 resume 是原生开 pane，且会话↔文件映射可做到**精确**而非启发式。

---

## 一、定位：Termio 不做档案馆，只做「自己会话的记忆」

agent-sessions 一半的功能（跨 10+ agent 统一库、归档抢救、iTerm2 探测、图片库、
活动热力图）来自「它不拥有终端、只能事后扒陌生文件」。Termio 拥有 PTY，**只索引自己
启动的会话**——语料小、映射准、不漂移成另一个产品。

**明确不做**：跨 agent 统一浏览器、归档抢救、boolean/`repo:`/`path:` 搜索引擎、
图片库、git inspector。需求真长出来再说。

---

## 二、地基：spawn 时就记下 `session_id`（四个功能共用）

这是 Termio 相对 agent-sessions 的**结构性王牌**。对方只能按「cwd + 最新文件」逆向猜，
会猜错；Termio 是自己 spawn 的 agent，应在**启动那一刻**把 agent 的 session id 绑死到
`Session` 上。

- `Models.swift` 的 `Session`（`Models.swift:193`）加字段：
  ```swift
  /// The coding agent's own session id, captured shortly after the agent
  /// launches by locating the transcript it just started writing under its
  /// per-agent directory (matched by this session's cwd + creation time).
  /// Nil for a plain shell, or before the agent has written its first line.
  var agentSessionID: String?
  ```
- 回填机制（`TermioStore`）：agent pane 启动后，在该 agent 目录下找「cwd 匹配本 session
  且创建时间晚于本 pane 启动」的最新 transcript，读出 id：
  - Codex：`~/.codex/sessions/**/rollout-*.jsonl` 首行 `session_meta.payload.session_id`。
  - Claude：`~/.claude/projects/<dashified-cwd>/<sessionId>.jsonl` 的 `sessionId`。
- 这个 id **同时**喂给：Share、本地 `.md`、搜索索引、Resume——一处采集，四处复用。

> 与 Share 设计的关系：Share 文档（`20260628-session-share.md` §一）原本用「cwd→最新文件」做映射；
> 有了 `agentSessionID` 后两者都升级成精确映射，Share 不必再猜。

---

## 三、索引：轻量、只覆盖自己的会话

- 一个 `SessionHistoryIndex`：每个有 `agentSessionID` 的会话一条记录
  `{ sessionID, agentSessionID, agent, project, cwd, title, transcriptPath, startedAt, lastActivityAt, messageCount }`。
- 来源：当前 `projects` 树里跑过的会话 + 已退出但 transcript 仍在的会话（用启动时记下的
  `transcriptPath` 直接定位，**不全盘扫** `~/.codex` / `~/.claude`）。
- `title` 派生：取首条有意义的 user prompt，跳过 `AGENTS.md`/`CLAUDE.md` 前言与
  `<system-reminder>` 脚手架（参 agent-sessions 的标题启发式）。
- 刷新：会话退出 / FSEvents 触发时增量更新一条，不重建全表。

---

## 四、搜索：substring + 三个 filter，别造引擎

- **不**照抄 agent-sessions 的两阶段渐进引擎 / 15min 渲染缓存 / 操作符语法——那是为
  「海量陌生历史」造的。Termio 语料小。
- 搜索对象：把 transcript 经**与 Share 同一套 parser** 渲成纯文本后做大小写不敏感
  substring（避免在原始 JSON 上误命中 markup）。
- filter：project / agent / 日期范围。就这三个。
- UI：一个搜索面板（命令 `⌘⇧O` 之类，或侧栏「History」分组上方的搜索框），
  结果行显示 日期 · project · agent 图标 · 标题 · 消息数。

---

## 五、恢复：原生开 pane，自动尝试 + 失败兜底复制命令

Termio 的优势：不需要把命令塞进外挂终端，**直接在 Termio 里新开一个 pane** 跑恢复命令
（复用 `TerminalController` builder 的 `command` 注入，见 `CLAUDE.md` 的 libghostty 说明）。

### 5.1 每 agent 的 resume 命令（`ResumeCommandBuilder`）

风险点：这些 flag **无文档、跨版本会变**。所以每条都带 fallback，且最终能降级成
「复制命令」。命令前缀统一 `cd <cwd> &&`。

| agent | 命令（含 fallback） |
| --- | --- |
| Codex | `codex resume <id>` ⟶ `codex -c experimental_resume=<file>` ⟶ `codex -c experimental_resume=<file> resume <id>` |
| Claude | `claude --resume <id>` ⟶ `claude --continue`（要求 cwd = 项目根） |

新 agent 后续按同样模式加（OpenCode `--session` / Pi `--session` 等），1.0 先做
Codex + Claude。

### 5.2 点击行为（已定：自动尝试 + 兜底）

```
点击会话
  ├─ 能恢复（CLI 在、flag 探测通过）→ 新 pane 跑 fallback 链，接着聊
  └─ 恢复不了 / 跑挂了 → 不把裸报错甩给用户：
        弹「复制 resume 命令」+ 一行原因（CLI 未安装 / 该 surface 不支持 / flag 不被接受）
```

- 开跑前做一次轻量可行性检查（`which codex` / `codex --help` 里有没有 `resume`），
  探测不到直接走兜底，不让用户看 pane 里报错刷屏。
- Codex 的 VS Code surface 等已知不支持的，直接禁用「恢复」只留「复制命令」。

---

## 六、UI 落点

- 侧栏新增 **History** 分组（`SidebarView.swift`）：按 project 分组列出历史会话，
  顶部一个搜索框。点击行 → §五 恢复到新 pane。
- 行内右键：恢复 / 复制 resume 命令 / 复制 session id / 在 Finder 显示 transcript /
  Share（接 `20260628-session-share.md`）。
- 普通 shell 会话（无 `agentSessionID`）不进 History。

---

## 七、与其它设计的复用关系（一条线，不是三条）

| 共用件 | Share | 本地 `.md` | 搜索 | 恢复 |
| --- | --- | --- | --- | --- |
| `agentSessionID`（§二） | ✓ | ✓ | ✓ | ✓ |
| parser/renderer（Share §五） | ✓ | ✓ | ✓（渲成纯文本搜） | — |
| cwd / worktree | ✓ | ✓ | ✓ | ✓（`cd`） |

也就是说：渲染器在 Share 那条线已经造好；History/Search/Resume 主要是**加一个索引 +
一个 ResumeCommandBuilder + 侧栏一个分组**，没有新地基。

---

## 八、落地顺序

1. **`agentSessionID` 采集**（`Session` 加字段 + `TermioStore` 回填）——所有功能的地基，
   先做，且 Share 也立刻受益。
2. **ResumeCommandBuilder + 新 pane 恢复 + 兜底复制命令**（先 Codex + Claude）。
3. **SessionHistoryIndex + 侧栏 History 分组**（先列表、点击恢复）。
4. **搜索框 + 三个 filter**（substring，复用 renderer）。

---

## 九、明确不做（与 §一呼应，落到清单）

- ❌ 扫描 / 索引 Termio 之外跑的历史会话（不全盘扫 `~/.codex`、`~/.claude`）。
- ❌ boolean / 字段操作符 / 渐进搜索引擎。
- ❌ 跨 10+ agent 统一库、归档抢救、图片库、活动分析、git inspector。
- ❌ 在外挂终端（iTerm2/Warp）里恢复——Termio 自己就是终端。
