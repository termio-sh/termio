---
title: Sandbox VM —— 原生 per-project 容器（Apple Containerization）
status: archived
type: design
created: 2026-06-29
updated: 2026-06-30
related:
  - 20260630-sandbox-seatbelt.md
  - 20260707-agent-extensibility.md
---

# Sandbox VM —— 原生 per-project 容器

> **ARCHIVED (2026-06-30).** 这个 micro-VM 方案已被废弃并删除代码，由 Apple Seatbelt
> 方案取代——见 [[sandbox-seatbelt.md]]。原因：VM 对一个终端 app 是错误的轴线，几乎所有
> 复杂度都只是因为 agent 跨在 VM 边界之外。以下保留作历史参考。

> 让一个项目的 agent 会话跑在隔离的 Linux micro-VM 里，用户零安装，一个项目共享一个容器。

## 1. 目标与动机

Termio 跑的是真实 PTY（`.exec`），agent 在用户真机上有完全访问权。沙箱的目的：把 agent 能搞坏的范围（文件系统、网络、装的软件）关进一台一次性的 Linux VM，逃出来也只碰到一次性盒子，而不是用户的真机。

关键约束 —— **用户零安装**。不要求用户去装 Docker / Apple 的 `container` CLI / 任何特权 daemon。因此 Termio 自己当 runtime：通过 Apple 开源的 **`apple/containerization`** Swift 框架直接起 VM。

## 2. 核心设计决策

### 2.1 原生，零安装（不走 `container` CLI）

- 不依赖用户安装的 `container` CLI（它需要一个特权系统 daemon，且和 Homebrew 装法冲突）。
- termio.app 内置一个签了 `com.apple.security.virtualization` entitlement 的 **helper 可执行文件**（`termio-sandbox`），由它 link Containerization 起 VM。主 app 不 link 这套重框架，也不需要这个 entitlement。
- 参考实现：Apple 的 `ctr-example` 和 `sandboxy` 示例（同 repo，Apache-2.0）。

### 2.2 一个 project = 一个 container（不是 per-session）

**这是和 Apple sandboxy 范式的关键分歧。** sandboxy 是"每个会话一个 VM"；Termio 要的是**每个项目一个容器，项目下所有会话 `exec` 进同一个容器共享它**。

为什么 per-project：

- **依赖装一次，全会话共享**。Claude Code、语言工具链在项目容器里装一次，Terminal / Claude Code / Codex 各个会话都能用，而不是每开一个会话重装。
- 进程 / 状态共享，符合"这个项目被容器化了"的心智模型。
- 决策点在**打开项目时**（见 §4 UX），不是事后翻来覆去的开关。

`/workspace` 是宿主项目目录 bind-mount，所以多个会话看到的是同一份文件，天然一致。

### 2.3 依赖只能在 Linux 侧重建，不能从宿主借

宿主装的是 macOS-arm64 二进制，Linux VM 跑不了（OS 不同，架构相同也不行）。所以：

| 东西 | 哪来 |
| --- | --- |
| 系统工具 + agent CLI（claude/codex）+ 语言运行时 | **在容器里装一次**（npm 在 Linux 里拉对应平台的二进制），缓存 |
| 项目源码 | `/workspace` bind-mount，宿主↔VM 共享 |
| agent 登录凭据（`~/.claude`、`~/.claude.json`） | 纯文本、跨平台，**挂/拷进去** → 免重新登录 |
| 项目依赖（node_modules / .venv / target） | 平台相关，需 VM 侧 overlay，避免和宿主 macOS 版本互相污染（M2/M3） |

**要点**：claude 的*二进制*平台相关（捆了原生 ripgrep，本体也是按平台编译），必须在 VM 里装 Linux 版；claude 的*凭据*可移植，直接挂。

## 3. 架构：serve / attach 守护进程

因为 Containerization 的 `LinuxContainer` 句柄活在某个进程的内存里，别的进程没法直接 exec 进去——所以 per-project 容器需要一个"每项目 VM 守护进程"。

```
菜单 "Open Project in VM…"
   └─ termio.app 启 1 个  termio-sandbox serve  （后台守护 / 项目）
          • boot 容器一次，init = /bin/sleep infinity
          • 装 agent 一次，挂 /workspace + 凭据
          • 监听 unix socket；项目开着就活，关项目 / 退出 app 才 tear down
   每个会话的 libghostty PTY 跑  termio-sandbox attach --socket …
          • 连守护进程，发一行 JSON header（窗口大小 + 命令）
          • 守护进程在共享容器里 container.exec(该会话命令)
          • PTY 字节通过 socket 双向桥接
```

### helper 两个模式

- **serve**（`sandbox-helper/`，独立 SwiftPM 包，需 `.macOS("26.0")`）：
  `ContainerManager(kernel:initfsReference:network:VmnetNetwork())` → `manager.create{ Mount.share(workspace→/workspace); init = sleep infinity }` → `create/start` → 装 agent（`container.exec` 跑 `npm install -g …`）→ `unixListen` → accept 循环。
- **attach**：`Terminal.current` 设 raw → 连 socket（带重试，等守护进程就绪）→ 发 header → PTY ↔ socket 双向 `pump`。

### PTY 桥接为什么这么做

- `setTerminalIO(terminal:)` 要求宿主侧 fd 是**真 PTY**（socket 当 IO 会报 "fd is not a pty"）。
- 守护进程每个连接 `Terminal.create()` 造 PTY 对，把 slave 给 `setTerminalIO`，pump master ↔ socket。
- attach 端在 libghostty 给的真 PTY 上跑，pump 自己的 PTY ↔ socket。

## 4. UX

- **File ▸ Open Project…**（⌘O）：宿主项目（现状）。
- **File ▸ Open Project in VM…**（⇧⌘O）：同样的文件夹选择器，但打开的项目带 `ContainerConfig`，会话跑在 VM 里。沙箱在**打开时**决定。
- 侧栏项目 header 上一个安静的 **`VM`** 胶囊标识（借用 title-bar chips 的 `.quaternary` 材质），只标"这是 VM 项目"，不是开关。
- （已废弃：侧栏底部的 Sandbox 开关——"事后翻开关"模型不对，删掉了。）

## 5. 构建 / 签名 / 打包

- `sandbox-helper/` 是**独立**包：它需要 `.macOS("26.0")`（Containerization / VmnetNetwork 要求），独立才不会把主 app 的 macOS-14 下限抬高。
- `scripts/build-app.sh`：编 helper 包 → 取并缓存 Kata 内核（`packaging/.cache/vmlinux-arm64`，来自 kata-static 3.17.0）→ `codesign --entitlements packaging/termio-sandbox.entitlements`（vz）→ 把 helper + 内核打进 `termio.app/Contents/Resources`。
- 开发回路：`build-app.sh → cp 到 /Applications → lsregister -f → open`。**必须从 /Applications 跑**（见 §6 vmnet bug）。

## 6. 硬约束（环境）

- 只支持 **Apple Silicon + macOS 26 (Tahoe)**；非 26 / 非 arm64 时 `isAvailable()` 为假，会话静默回退到宿主。
- **macOS 26 vmnet bug**：app 在 `~/Documents` 或 `~/Desktop` 下 `VmnetNetwork()` 失败（status 1001）。Termio repo 在 `~/Documents/GitHub/termio`——**编译在原地没事，运行必须在 Documents 之外**（开发期跑 /Applications 里的副本）。
- 首次开 VM 项目要联网下内核 + 基础镜像 + 装 agent（一次，之后缓存）。VM 够不到宿主 `localhost`，只能连 `0.0.0.0` 上的服务。

## 7. 里程碑

- **M1 — 完成（2026-06-29）**：native sandbox 端到端通。helper 启 VM + virtio-fs 挂 `/workspace`（双向验证）、entitlement + 签名、vmnet、内核。真 app 里 agent0 项目的 Terminal 会话显示 `/workspace #` 的 Linux shell。UI（VM pill + Open Project in VM 菜单）就位。
  - *当时是 per-session VM；alpine 基础镜像没有 agent，所以 Claude Code 会话报 `claude: not found`。*
- **M2 — 进行中**：serve/attach 重写成 **per-project 容器** + boot 时装 agent（解决 `claude not found`，且依赖只装一次共享）。挂 agent 凭据。
- **M3**：权限面板（从打开方式 / 项目配置长出来）+ 域名白名单 egress 代理（sandbox 的 HostProxy）+ hook/socket 跨 VM 桥接（让菜单栏状态、`termio sessions` 在沙箱里也工作）+ node_modules 等平台目录的 VM 侧 overlay + rootfs 缓存（连 app 重启都跳过重装）。

## 8. 已知限制（当前）

- 实时 resize 未做（启动时定窗口大小；中途拉伸窗口 TUI 可能不重排）。
- 控制平面（HookListener / `termio sessions`）假设宿主 unix socket，跨 VM 边界目前断（M3 修）。
- agent 安装在 serve boot（首开慢）；rootfs 缓存留到 M3。

## 9. 相关文件

- `sandbox-helper/` —— helper 独立包（`serve` / `attach`）。
- `Sources/termio/Container.swift` —— `ContainerConfig`（面板就绪）+ 给 chokepoint 拼命令的 `ContainerManager`。
- `Sources/termio/TermioStore.swift` —— chokepoint `surface(for:in:)`、`addProject(at:sandboxed:)`。
- `Sources/termio/SidebarView.swift` —— VM pill。
- `Sources/termio/App.swift` —— Open Project in VM 菜单。
- `scripts/build-app.sh`、`packaging/termio-sandbox.entitlements`。
