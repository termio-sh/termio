# 2026-06-29 — Sandbox M2 handoff prompt

Handoff prompt for another agent to continue the Termio sandbox work (M2:
per-project container + agent install). Paste the block below.

---

```
继续 termio 的 sandbox 功能开发（M2）。termio 是 ~/Documents/GitHub/termio 的原生 Swift + libghostty 终端。

先读这两个，它们是完整交接：
1. docs/design/20260629-sandbox-vm.md —— 完整设计（必读）
2. 你的记忆里的 project-termio-sandbox —— 当前状态 + NEXT

== 目标 ==
把 sandbox 从"每 session 一个 VM"改成"一个 project 一个容器，所有 session 共享它（exec 进去）"，并在容器里装一次 agent（解决 Claude Code 会话报 `claude: not found`）。

== 当前状态 ==
- UI/控制层已上线：项目 header 上的 "VM" pill、File ▸ Open Project in VM…（⇧⌘O）、addProject(at:sandboxed:)。侧栏的 Sandbox Switch 已删。
- helper 已重写成 serve/attach 双模式：sandbox-helper/Sources/termio-sandbox/main.swift
    serve  = 守护进程，boot 容器一次、init=sleep infinity、可选 --install 装 agent、unixListen+accept
    attach = 每 session 的 PTY 客户端，连 socket、发 JSON header{cols,rows,command}、PTY↔socket 字节桥接
  ✅ 第 1 步已完成（2026-06-29 验证）：helper `swift build` 通过；从 /tmp 跑签名二进制，serve 暖启 <5s；attach（用 `script -q /dev/null` 给真 PTY）能桥进容器；/workspace bind-mount 双向 OK；两个 attach 同一 hostname + 共享 /root 文件 → 确认是「一个共享容器」而非 per-session VM；base image alpine→node:22 + `--install 'npm install -g @anthropic-ai/claude-code'` 后容器内 `which claude`=/usr/local/bin/claude、`claude --version`=2.1.195，`claude: not found` 已解决。codex/opencode 安装尚未测。
  ⚠️ app 侧仍未接 helper——TermioStore.surface(for:in:) 和 Container.swift 仍调旧的 per-session launchCommand。下一步是第 2 步（接 app）。

== 要做的三步（按顺序）==
1. 编译 + standalone 测 helper 的 serve/attach。从 /tmp 测（不能在 ~/Documents 下跑，macOS 26 vmnet bug）：
   - cd sandbox-helper && swift build；codesign --sign - --entitlements ../packaging/termio-sandbox.entitlements 二进制
   - 先不带 --install：后台跑 serve（--workspace /tmp/ws --kernel <内核> --socket /tmp/s.sock），再 attach（--socket /tmp/s.sock -- /bin/sh），用 `script -q /dev/null` 给真 PTY，验证多个 attach 共享同一容器
   - 再带 --install 测装 claude
   - 内核在 packaging/.cache/vmlinux-arm64
2. 接 TermioStore：VM 项目打开时 spawn 一个 serve（后台 Process，生命周期=项目打开..关闭/退出 app），chokepoint 改成跑 bundle 里的 helper `attach --socket <每项目 sock>`，关项目/退出时 teardown 守护进程。Container.swift 的 ContainerManager 要从"拼 per-session launchCommand"改成"管 serve 守护 + 拼 attach 命令"。
3. 挂 agent 凭据（~/.claude、~/.claude.json → /root/...，serve 的 --mount）+ 设 --install（npm i -g @anthropic-ai/claude-code @openai/codex opencode-ai）。基础镜像从 alpine 换成有 node 的（如 docker.io/library/node:22）。

== 硬约束 ==
- 只 Apple Silicon + macOS 26。helper 在 ~/Documents 或 ~/Desktop 下 vmnet 会失败（status 1001）——编译在原地 OK，但运行的 .app 必须在 /Applications。
- 构建/装/跑：./scripts/build-app.sh → rm -rf /Applications/termio.app && cp -R termio.app /Applications/ → lsregister -f → open。helper+内核由 build-app.sh 编译/签名/打包进 Resources。
- sandbox-helper 是独立 SwiftPM 包（需 .macOS("26.0")，不能并进主包否则抬高 app 的 macOS-14 下限）。
- 验证 UI：用 .claude/skills/app-screenshot-debug 截图驱动；启用沙箱可直接改持久化 state（~/Library/Application Support/Termio/state.json 给项目加 container 对象）再重启，比点 UI 稳。

每改完一块先 swift build 验证，再 build-app.sh 全量。先从第 1 步把 helper 测通，别急着接 app。
```
