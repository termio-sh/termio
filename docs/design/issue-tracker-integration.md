---
title: "Issue tracker 集成：inspector Issues tab（GitHub / Linear，per-project provider）"
status: draft
type: design
created: 2026-07-26
updated: 2026-07-26
related:
  - issue-triage-local-agent.md
  - worktree-information-architecture.md
---

# 设计：Issue tracker 集成（inspector Issues tab）

> 在 inspector 加第五个 pane：当前项目的 issue + PR 列表 + 详情 + 完整交互（reaction / label / 评论），tracker 按项目绑定（GitHub Issues 或 Linear，协议留好 Jira 的位置），核心出口是把 issue / PR 一键派给本地 agent session。

## 1. 为什么做 / 边界

- 用户在 termio 里看着 repo、开着 agent，但查 issue / PR 要回浏览器。原生 macOS 的阅读器这个位置是空的（GitHub Desktop 的 PR 只在 branch 下拉里；Trailer/Gitify 是通知聚合器；GitHawk 死了且是 iOS）。
- termio 的差异点不是"更好看的 issue 列表"，而是**读完直接派活**：issue / PR → send to agent，接上 [issue-triage-local-agent.md](issue-triage-local-agent.md) 的出站半场（那篇是事件*进来*自动触发，本篇是人*看着*手动派）。
- **PR 从第一版就在读的范围内**：读是每日高频动作，PR 是 agent 干活的产物；而且 GitHub API 里 PR 就是带附加字段的 issue（同一个 list endpoint），issue 读通了 PR 读几乎免费。PR 读 = 标题/正文/评论线 + 状态，到此为止。
- **第一版不做**：通知（badge / 系统通知都不做）、建 issue、关闭/改状态、Jira provider、PR review 线程 / 本地 diff / checks 详情 / merge 操作（PR 本地 diff 属于 git pane 的 Review mode，后续单独接）。协议为它们留缝，但不实现。

## 2. 核心问题：不同项目用不同 tracker

同一个用户，A 项目用 GitHub Issues，B 项目用 Linear，C 项目用 Jira。解法是把三个概念拆开：

| 概念 | 作用域 | 存哪 | 内容 |
| --- | --- | --- | --- |
| **Connection** | 全局，每 provider 一个 | 凭证进 Keychain，元数据进 UserDefaults | "我登录了 GitHub"、"我登录了 Linear" |
| **Provider** | 代码 | app 内置 | `IssueProvider` 协议的一个实现（GitHub、Linear；未来 Jira = 再写一个 conformance） |
| **Binding** | 每 project 一个 | `Project` 持久化字段 | 这个项目用哪个 provider + 哪个远端容器（GitHub 的 `owner/repo`，Linear 的 team） |

Binding 的解析顺序：

1. 项目已手动绑定 → 用它。
2. 未绑定且 origin remote 是 `github.com` → 自动绑 GitHub Issues 的那个 repo（零配置，多数用户到此为止）。
3. 否则（或用户想改）→ Issues tab 零态里选：GitHub repo 选择器 / Linear team 选择器。Linear 与本地 repo 没有可推导的对应关系，必选一次，选完记住。

这就是"extension 形式"的落点：**内置 provider 注册表 + per-project binding**，不是对外插件系统。加 Jira 是一天的 conformance 工作，不是平台工程。

## 3. IssueProvider 协议

归一化模型 + capability 声明，UI 只认协议不认 provider：

```swift
protocol IssueProvider: Sendable {
    var id: ProviderID { get }                 // .github / .linear
    var capabilities: IssueCapabilities { get } // reactions? labelEdit? comment?

    func containers() async throws -> [IssueContainer]   // repos / teams，绑定用
    func issues(in c: IssueContainer, query: IssueQuery) async throws -> [IssueSummary]
    func detail(_ ref: IssueRef) async throws -> IssueDetail

    func setReaction(_ r: Reaction, on target: ReactionTarget, add: Bool) async throws
    func setLabels(_ labels: [Label], on ref: IssueRef) async throws
    func availableLabels(in c: IssueContainer) async throws -> [Label]
    func comment(_ markdown: String, on ref: IssueRef) async throws
}
```

- `IssueQuery` 带 `kind`（`.issue` / `.pullRequest`）：GitHub 里 PR 就是 issue，同一套模型直接覆盖。
- `IssueSummary`：`identifier`（GH 的 `#95` / Linear 的 `TER-123`）、title、state（PR 多 merged / draft 两态）、labels（name+color）、assignees、updatedAt。
- `IssueDetail`：+ body（markdown）、comment 线程（author/时间/body/reactions）。
- `IssueCapabilities` 让 UI 按 provider 收缩：Linear 没有 GitHub 式 emoji reaction 全集，就只显示它支持的；也没有 PR——`pullRequests` capability 关掉，kind filter 整个消失。
- GitHub 走 REST（`URLSession`，不引 SDK），Linear 走 GraphQL（同样裸 `URLSession`，query 手写）。

## 4. 认证

| Provider | 流程 | 为什么 |
| --- | --- | --- |
| GitHub | **OAuth Device Flow**：Connect → 显示 8 位码 + 自动开 `github.com/login/device` → 轮询换 token。scope `repo`（写 label/评论需要）。 | 只需公开 client_id，无 secret 无回调服务器——termio 开源，secret 不能进仓库。需在 GitHub 注册 OAuth App 并勾选 Enable Device Flow（发布前的一次性人工步骤）。 |
| Linear | **Personal API key 粘贴**：Connect → 开 `linear.app/settings/api` → 用户粘贴 key。 | Linear OAuth2 强制 client secret，开源 app 用不了；API key 是 Linear 给本地工具的正路（linear-cli 同款）。 |

凭证一律进 Keychain（service `sh.termio.app.issues`，account = provider id）。断开 = 删 Keychain 项 + 清 binding。Usage tab 已有读 OAuth 凭证的先例，模式一致。

## 5. UI

- **入口**：`InspectorTab` 加 `.issues`，`InspectorTabsToolbar` 第五个 segment（HugeIcon 需新增一个 issue/task 玻璃线框图标，现有 30 个 case 里没有合适的）。tab 常显；未连接/未绑定时显示零态而不是藏 tab（可发现性优先）。
- **零态**：未连接 → "Connect GitHub / Connect Linear" 两个按钮；已连接未绑定 → 容器选择器。
- **列表**：顶部 Issues / Pull Requests kind filter（沿用 Changes/History 的迷你 segmented 样式，provider 无 PR 则不显示）；一行式 row——state 圆点（open 绿 / closed & merged 紫 / draft 灰，Linear 用状态色）、`identifier` 等宽、title、右侧 label 色点 chips。默认 open + 按 updated 排序；旁边一个轻量 filter（open/closed、assigned to me）。
- **详情**：推入式（沿用 git pane 文件→diff 的导航模式）。body 与 comment 用现成 `MarkdownHTML` 渲染（session trace 同款）；底部评论输入框；每条 comment/body 挂 reaction bar；toolbar 上 label 编辑 popover（`availableLabels` 勾选）。
- **Send to Agent**：详情页首要按钮。生成 prompt（`Work on <identifier>: <title>\n\n<body>` + issue URL），走 `TermioStore+SessionControl` 现成的 deliver/spawn 路径：有活跃 session 就送入，没有就 spawn。这是本功能存在的理由，位置必须最显眼。

## 6. 里程碑

读 + 派活在前（每日高频 + 差异点，且派活只是「拼 prompt + 现成 deliver 路径」的小步）；写在后（每个写操作都有浏览器兜底）；Linear 收尾（协议从第一天就管住它，conformance 不急）。

1. **M1 读（issues + PRs）**：协议 + GitHub provider（device flow、列表、详情、kind filter）、tab + 零态 + 列表 + 详情渲染。→ [#99](https://github.com/jiweiyuan/termio/issues/99)
2. **M2 派活**：Send to Agent（prompt 模板、目标 session 选择），issue 与 PR 同一条路径。→ [#102](https://github.com/jiweiyuan/termio/issues/102)
3. **M3 写**：reaction、label 编辑、评论（GitHub，issue 与 PR 通用）。→ [#100](https://github.com/jiweiyuan/termio/issues/100)
4. **M4 Linear**：API key connect、GraphQL provider、binding 选择器。→ [#101](https://github.com/jiweiyuan/termio/issues/101)
