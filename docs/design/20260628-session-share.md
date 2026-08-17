---
title: 分享 Agent 会话（带密码的实时分享链接）
status: draft
type: design
updated: 2026-06-28
---

# 设计：分享 Agent 会话（带密码的实时分享链接）

> 目标：在标题栏加一个 **Share** 按钮，把当前 pane 的 Agent 对话导出成一条
> 可分享链接（`https://termio.app/s/<slug>`）。链接本身不可枚举、可选密码保护、
> **实时同步**（Agent 继续干活时观看者能看到更新）。后端落在现有 `web/server`。
>
> 竞品参考：opencode 的 share（`docs/competitive-analysis` 未单列，结论见下文「四」）。

---

## 一、先厘清「talking session」到底是什么

截图里跑的是 OpenAI Codex。要分享的不是终端 scrollback——那是 ANSI / box-drawing
噪声，没法直接当 Markdown。真正干净的来源是 **Agent 自己写的 JSONL transcript**：

| Agent | transcript 路径 | 定位字段 |
| --- | --- | --- |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | 首行 `session_meta.payload.cwd` / `.session_id` |
| Claude Code | `~/.claude/projects/<dashified-cwd>/<sessionId>.jsonl` | 目录名 = cwd 把 `/` 换 `-` |
| 普通终端 | 无 transcript | 退化为 scrollback 文本，或禁用按钮 |

**Termio 的结构性优势**：每个 session 有唯一 `cwd`（每会话 worktree，见
`Session.worktreePath` `Models.swift:204`）。所以「这个 pane ↔ 哪个 transcript 文件」
是确定可解的——这就是你问的 *"check the session id"*：用 `cwd` 反查 transcript，
再在该 cwd 下取**最新**的 rollout / `.jsonl`。已实地验证（2026-06-27）：

```
~/.codex/sessions/2026/06/27/rollout-...-019f0989-...jsonl
  → line 1: {"type":"session_meta","payload":{"session_id":"019f0989...","cwd":"/Users/yuanjiwei/Documents/GitHub/termio", ...}}
~/.claude/projects/-Users-yuanjiwei-Documents-GitHub-termio/50a328ae-....jsonl
  → {"type":"...","sessionId":"50a328ae-..."}
```

---

## 二、竞品 opencode 怎么做的（事实，来自 `sst/opencode` 源码）

- **公开即链接，无任何读权限校验、无密码。** 观看 URL `opncd.ai/s/<id>`，`<id>` =
  **session id 的后 8 位**——确定性、可部分枚举、无限流。任何拿到链接的人看全文。
- 有一个 per-share `secret`（`crypto.randomUUID()`），但**只**用于授权 `sync` 和
  `unshare`，**从不**用于 gate 观看（`share.secret !== input.secret → InvalidSecret`，
  仅在写路径）。
- 上传是**增量实时**的：`/share` 先 `full()` 全量推一次，之后订阅内部事件
  （`Session.Updated` / `MessageV2.Updated` / `PartUpdated` / `Session.Diff`），
  **1s debounce** 推 delta 到 `POST /api/share/{id}/sync`。
- 存储：早期 Cloudflare Durable Object + R2（`share/${key}.json`），现版本是 KV
  抽象 `["share", id]` / `["share_snapshot", id]`。观看端 SolidStart 静态站，靠
  `GET /share_poll`（WebSocket）实时拉。
- 默认 `share: "manual"`（opt-in），文档只有一句「公开，别分享敏感信息」的**advisory**
  警告，无自动脱敏。

**结论**：opencode 的「隐私」只是一个短而弱的 slug，**没有密码**。Termio 要做的是
**取它实时同步的优点 + 把 slug 改成不可枚举 + 补上你要的密码层**。

来源：`packages/opencode/src/share/share-next.ts`、`packages/enterprise/src/core/share.ts`、
`packages/function/src/api.ts`、`opencode.ai/docs/share`。

---

## 三、Termio 的安全模型（最终决策）

opencode 的**超集**，三层清晰分开：

1. **不可枚举 slug** — 22 字符随机 base62（`nanoid`），**不**从 session id 派生。
   链接本身即基础密钥，修掉 opencode 的枚举弱点。
2. **可选密码（hash-gate）** — 用户设了密码时，Markdown 在 `POST /unlock` 用
   **bcrypt** 校验通过前不下发。服务端仍能读明文（实时同步 + 匿名创建 + 服务端
   渲染观看页都需要它能读；真正的 E2E 与「匿名 + 服务端观看」互斥，故不做）。
3. **editSecret** — 另一个 `randomUUID()`，创建时返回给 app 并**本地持久化**，
   用于 `sync`（增量推送）和 `DELETE`（撤销/unshare）。等价于 opencode 的 secret。

**创建方式**：匿名 + IP 限流（无需 license key——降低免费/试用用户门槛）。
**内容范围**：完整 transcript（含 tool call / diff / 命令输出）。
**警告**：分享 sheet 上给一句 advisory「全文公开，注意密钥/路径泄露」，不做自动脱敏（1.0 范围外）。

> 注：匿名 + 完整 transcript 是放大泄密面的组合。1.0 接受这个权衡并用 advisory 文案
> 兜底；若后续要收紧，再加 license-gate 或正则脱敏 pass，对本设计是增量。

---

## 四、实时同步：Termio 用「tail JSONL」而非「订阅内部事件」

opencode 能订阅自己进程的内部事件；Termio 是**外部**观察 Codex/Claude 进程，拿不到
它们的事件总线。但 Termio 有它们的 transcript 文件——所以 Termio 的实时同步 = **tail
那个 JSONL 文件**（正是 `docs/competitive-analysis/07-vibe-island.md` 提到的 `claude-watch`
「无 hook 直接 tail JSONL」路子）。

```
[focused session] --cwd--> 解析出 transcript 路径
        │
        ▼
SessionShareWatcher (FSEvents + 末尾偏移量)
        │  新增的若干行 → 解析 → 转成有序 Markdown part
        ▼
POST /api/share/:slug/sync  (body: editSecret + 增量 parts)   ← 500ms~1s debounce
        │
        ▼
后端 append 到快照 + 向该 slug 的 SSE 订阅者 publish
        │
        ▼
观看页 /s/:slug  (EventSource 订阅，增量渲染)
```

要点：
- **断点续传**：记录文件已读字节偏移；FSEvents 触发后只 `seek` 读新增部分，避免重复。
- **首帧全量**：创建分享时先把当前整份 transcript 解析成 parts 一次推上去（= opencode 的 `full()`）。
- **会话切换**：watcher 绑定在「被分享的那个 session」，不是「当前 focused pane」——
  分享后用户切走，同步仍继续，直到 unshare 或退出 app。
- **停止条件**：app 退出 / 用户点 Unshare / transcript 文件消失。app 退出后链接仍可看
  （快照已落库），只是不再更新。

---

## 五、传输数据模型（part，借 opencode 的 discriminated union）

每条增量是有序 `part[]`，每个 part 一个 `seq`（单调递增，供观看端去重/排序）：

```jsonc
{ "seq": 12, "kind": "message", "role": "user|assistant", "text": "..." }
{ "seq": 13, "kind": "tool",    "name": "shell", "summary": "git status", "detail": "..." }
{ "seq": 14, "kind": "diff",    "path": "Sources/...", "patch": "..." }
{ "seq": 15, "kind": "reasoning", "text": "..." }   // Codex 的思考块，可选
```

app 端的 JSONL→part 转换器按 agent 分两个 parser（Codex `response_item` vs Claude
`type:user/assistant`），输出统一 part schema。观看端只认 part schema，不关心来源 agent。
落库时服务端把 part 流既 append 进事件表（实时 replay 用）也 merge 进一份快照（首屏快）。

---

## 六、后端（`web/server`，Hono + Drizzle + Supabase Postgres）

### 6.1 新表 `shared_session`（+ 一张 `shared_part`）

```ts
// schema.ts 追加
export const sharedSession = pgTable("shared_session", {
  slug: text("slug").primaryKey(),               // 22-char nanoid，不可枚举
  editSecret: text("edit_secret").notNull(),     // randomUUID，授权 sync/delete
  title: text("title").notNull(),
  agent: text("agent").notNull(),                // "codex" | "claude" | ...
  passwordHash: text("password_hash"),           // bcrypt，null = 无密码
  status: text("status").notNull().default("live"), // live | ended
  viewCount: integer("view_count").notNull().default(0),
  expiresAt: timestamp("expires_at", { withTimezone: true }), // 可选 TTL
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

export const sharedPart = pgTable("shared_part", {
  id: text("id").primaryKey(),
  slug: text("slug").notNull().references(() => sharedSession.slug, { onDelete: "cascade" }),
  seq: integer("seq").notNull(),                 // 会话内单调递增
  payload: jsonb("payload").notNull(),           // 第五节的 part
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
}, (t) => [uniqueIndex("shared_part_slug_seq").on(t.slug, t.seq)]);
```

迁移：`pnpm drizzle-kit generate`（沿用现有 `web/server/drizzle/` 流程，会生成
`0003_*.sql` + snapshot）。

### 6.2 路由 `routes/share.ts`，挂 `/api/share`（仿 `routes/license.ts` 的 bearer 风格）

| 方法 | 路径 | 鉴权 | 作用 |
| --- | --- | --- | --- |
| `POST` | `/api/share` | 无（IP 限流） | 创建分享，body 含 title/agent/可选 password/首帧 parts，返回 `{ slug, editSecret, url }` |
| `POST` | `/api/share/:slug/sync` | `editSecret` | append 增量 parts，向订阅者 publish |
| `POST` | `/api/share/:slug/end` | `editSecret` | 标记 `status=ended`，停止接收 sync |
| `DELETE`| `/api/share/:slug` | `editSecret` | 删除（级联删 parts） |
| `GET` | `/api/share/:slug` | 无 | 元信息：`{ title, agent, requiresPassword, status }`，**不含内容** |
| `POST` | `/api/share/:slug/unlock` | 密码（如有） | 校验 bcrypt → 返回当前全部 parts；`viewCount++` |
| `GET` | `/api/share/:slug/stream` | 同上（无密码或已 unlock 带短 token） | **SSE**，推送后续 part |
| `GET` | `/api/share/:slug/raw` | 无密码直读；有密码需 `?key=<token>` | **`text/markdown`** 全文（见下文「两种链接形态」），供别的 agent 直接 fetch |

> `raw` 把全部 parts 拼成一份连续 Markdown 文档（与观看页同一渲染，只是纯文本无样式），
> `Content-Type: text/markdown; charset=utf-8`，CORS 全开。无密码时 slug 本身即凭证，URL
> 自鉴权；有密码时附 `?key=<view-token>`（同 §6.2 的 HMAC token）。

- **限流**：`POST /api/share` 按 IP（内存令牌桶即可，1.0 不引 Redis；`license.ts`
  已有 `TODO(production): per-IP rate limiting` 同款诉求）。
- **SSE 实现**：Hono `streamSSE`；服务端进程内维护 `Map<slug, Set<subscriber>>`，
  `sync` 时往对应 set 推。单实例够用；多实例再换 Postgres `LISTEN/NOTIFY` 或 Supabase
  Realtime（增量改造，不影响接口）。
- **密码与 SSE**：有密码时，`unlock` 成功后发一个短期 view-token（HMAC，含 slug+exp），
  `stream` 和 `unlock` 用它放行，避免把密码放进 EventSource URL。

### 6.3 挂载（`index.ts`）

```ts
import { shareRoutes } from "./routes/share.js";
app.route("/api/share", shareRoutes);
// CORS allowMethods 需加 "DELETE"
```

---

## 七、观看页（`web/landing`，Next.js）

- 新增 `app/s/[slug]/page.tsx`：
  - SSR 拉 `GET /api/share/:slug` 元信息。
  - 无密码 → 直接 SSR `unlock`（或客户端拉）渲染 parts；订阅 `/stream` 增量追加。
  - 有密码 → 渲染密码输入框 → `POST /unlock` → 拿 view-token → 渲染 + 订阅。
  - `status==="live"` 显示「● 实时」徽标；`ended` 显示「会话已结束」。
- 渲染器按 part `kind` 分别渲染（message/tool/diff/reasoning），代码块高亮，diff 着色——
  与 opencode 观看端同构。
- **`.md` 后缀直通 raw**：Next.js `rewrites` 把 `/s/:slug.md` 映射到后端
  `/api/share/:slug/raw`（带 `?key=` 透传），让「Agent 链接」是一个看起来像文件的
  漂亮 URL，而不是 `/api/...` 路径。

---

## 七·五、按「消费者在哪」分三种复制目标

核心判断：**该把会话交给谁、在不在本机**，决定复制什么——而不是简单分「人 / agent」。
同机交接根本不需要后端，本地文件路径在每个维度都优于 web URL（零上传、零后端、无隐私面、
离线可用、天然实时）。而「把它塞进另一个 agent session」几乎一定就是同机场景。

| 动作 | 剪贴板内容 | 后端 | 给谁 | 说明 |
| --- | --- | --- | --- | --- |
| **Copy for agent**（默认） | `~/.termio/shares/<slug>.md` 绝对路径 | ❌ 无 | 本机另一个 agent | 渲染过的干净 Markdown 文件，watcher 持续重写 → 始终最新 |
| Copy raw transcript path | `~/.codex/.../rollout-*.jsonl` 原始路径 | ❌ 无 | 本机全保真交接 | 不经渲染，全字节；含 agent 的 base_instructions/sandbox 前言 |
| Share link… | `https://termio.app/s/<slug>` 或 `…/s/<slug>.md` | ✅ 上传 | 人 / 远端 agent | 渲染页给人；`.md` 给远端 agent fetch |

### 为什么默认是「本地 `.md` 路径」而非原始 JSONL

原始 rollout JSONL 开头是一大段 `session_meta` + `developer` 角色的
`<permissions instructions>` + sandbox 前言（见 §一 实测样本）——对接收方 agent 是纯噪声、
白烧 context，且泄露你本机的 sandbox 配置。所以默认复制**经同一套渲染器产出的干净
`.md`**（与 §五 part schema 同源，只是落成本地文件而非上传）；想要全字节的人走「Copy raw
transcript path」副选项。

接收方 agent 怎么用：粘贴路径后 `@/Users/.../<slug>.md`（截图里 Codex 的 `@filename`
约定）或直接 `Read`。同机即时、离线、永远是最新——之前选的「实时同步」在本地场景退化成
「文件本来就在更新」，无需 SSE。

### 本地文件落在哪

`~/.termio/shares/<slug>.md`（Termio 自管目录，不污染用户 repo）。watcher 把解析出的 part
增量重写进这个文件；unshare / 退出后文件保留，下次可复用或清理。

### Share link…（远端）仍是两条链接

| 形态 | URL | Content-Type | 给谁 |
| --- | --- | --- | --- |
| Human 链接 | `https://termio.app/s/<slug>` | `text/html` | 人看，带实时徽标/高亮/diff |
| Agent 链接 | `https://termio.app/s/<slug>.md` | `text/markdown` | 远端 agent `WebFetch`/`curl` |

有密码时 `.md` 自动带 `?key=<view-token>`（HMAC，免交互输入密码），复制时提示「此链接含
访问密钥」；无密码则裸 `.md`（slug 自鉴权）。

---

## 八、App 端（Swift）

新文件 `Sources/termio/SessionShare.swift`，含三块：

1. **`TranscriptLocator`** — 由 session 的 `cwd` 解析 transcript 路径（Codex / Claude
   两套规则），取最新文件。
2. **`TranscriptParser`** — JSONL 行 → 统一 `SharePart`（按 agent 分支）。
3. **`SessionShareWatcher`** — FSEvents 监听该文件，维护读偏移，debounce 后调用
   后端 `sync`。一个 `@Published var activeShare: ShareHandle?` 挂在 `TermioStore`
   上，使按钮能反映「已分享 / 同步中」状态，并支持 Unshare。

UI：
- `TerminalPane.titleToolbar` 增加 **trailing** `ToolbarItem`（截图里框住的右上角位置），
  图标 `square.and.arrow.up`。当前 session 无 transcript（普通终端）时 disabled。
- **按钮主点击 = 默认动作「Copy for agent」**：渲染 transcript → 写
  `~/.termio/shares/<slug>.md` → 复制该绝对路径到剪贴板，**不开 sheet、不连后端**。
  与你「default copy 就是 file address」的诉求一致——一下就能粘进另一个 agent session。
- 按钮的下拉菜单（或 sheet）给其余目标（见 §七·五）：
  - 「Copy raw transcript path」— 复制原始 JSONL 路径（全保真，本机）。
  - 「Share link…」— 才走 `POST /api/share` 上传，弹 sheet：标题、可选密码、advisory
    文案，创建后给「Copy human link」「Copy agent link (.md)」「Unshare」。
- 当前 session 无 transcript（普通终端）时按钮 disabled。
- `editSecret` 仅在用了「Share link…」时才需要；本地持久化（随会话快照或 Keychain），
  以便重启后仍能 sync/撤销。本地 `.md` 路径无此负担。
- 严格遵守 `CLAUDE.md`：不 force-unwrap，网络/解析错误向用户呈现而非吞掉。

---

## 九、落地顺序（每步可独立验证）

把**本机文件交接**排在最前——它是主用途，且完全不依赖后端，能最快交付价值：

1. **App：定位 + 解析 + 本地 `.md`**（`TranscriptLocator` + `TranscriptParser` →
   写 `~/.termio/shares/<slug>.md` → 复制路径）。**无后端**即可端到端可用：在另一个
   pane `@` 这个文件验证。
2. **App：FSEvents 让本地 `.md` 保持更新**（watcher 增量重写；本地「实时」到此完成）。
3. **后端 schema + 路由**（`curl` 跑通 create/sync/unlock/stream/raw）。
4. **观看页 + `.md` rewrite**（渲染 + SSE 实时追加）。
5. **App：「Share link…」接上后端**（上传 + 两条远端链接 + Unshare）。
6. **密码 + 限流 + TTL 收尾**。

---

## 十、明确不做（保持最小面）

- 不做服务端自动脱敏 / 密钥扫描（仅 advisory 文案）。
- 不做账号体系下的「我的分享」列表（匿名创建；`editSecret` 在本地即可撤销）。
- 不做真正 E2E 加密（与匿名 + 服务端观看渲染互斥）。
- 不接管或重放终端；分享的是 transcript 文本，不是可交互会话。
