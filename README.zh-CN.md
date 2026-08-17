> 如对翻译有改进建议，欢迎提交 PR。

<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### 终端优先的智能体开发环境

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p><a href="README.md">English</a> | 简体中文 | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a></p>

<br />

在真正的 Mac 终端里并排运行 Claude Code、Codex 和任意 CLI 智能体——<br />
Swift 与 libghostty，没有 Electron。菜单栏的小圆点告诉您谁在等您，<br />
离开座位时，iPhone 会替您盯着。

<br />

[**下载 macOS 版**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [官网](https://termio.sh) &nbsp;&bull;&nbsp; [文档](https://termio.sh/docs) &nbsp;&bull;&nbsp; [更新日志](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<br />

<img alt="深色模式下的 Termio：一个正在运行的 Claude Code 会话，旁边是项目侧边栏" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## 安装

**[下载 macOS 版 Termio](https://downloads.termio.sh/termio.dmg)**——免费、
无需账号，需要 macOS 14 或更高版本。也可以通过 [Homebrew](https://brew.sh) 安装：

```sh
brew install --cask termio-sh/tap/termio
```

**在 iPhone 上**：从
[TestFlight](https://testflight.apple.com/join/1Arf1UKR) 获取配套应用公测版，
再扫描 Mac 应用 Settings ▸ Mobile 中的二维码完成配对。

## 终端优先的 AI 编程开发环境

IDE 是围绕一个人敲代码设计的。当大部分代码改由 AI 编码智能体来写，环境的职责也随之改变：它既是智能体干活的地方，也是您指挥、审阅、为它们解困的地方。Termio 正是这样一个环境——之所以终端优先，是因为智能体本来就活在终端里；它为工作的新形态而造：几个智能体同时推进，大多数无需您操心，偶尔有一个卡住等您。（更完整的论述见
[*From IDE to ADE*](docs/essays/from-ide-to-ade.md)。）

- **真正的终端，不是网页视图。** Swift + AppKit，基于
  [libghostty](https://ghostty.org)（Ghostty 的终端核心），以 Metal 渲染。
  没有 Electron，也没有 xterm.js。
- **项目 → 会话。** 侧边栏映射您真实的工作方式：每个项目容纳自己的终端和智能体，
  git 工作树嵌套在项目之下，用于并行推进多个任务。
- **状态零配置。** Termio 自动接好每个智能体自带的 hook，读取智能体本就发出的信号。
  工作中、空闲，还是*等您处理*——每个会话都有状态圆点；菜单栏托盘平时安静，
  智能体干活时脉动，有智能体被您卡住时响铃提醒。
- **审阅不必离开。** 只读的 git 面板（变更、历史、统一 diff）、
  点击即可编辑的文件树、项目级内容搜索——提交代码依然在终端里完成。
- **免费。** 无需账号，没有许可证密钥，也没有付费档位。MIT 许可。

## 功能特性

<table>
<tr>
<td width="50%" valign="middle">

### 会话并排

每个项目保有自己的终端和智能体会话，从侧边栏即刻切换——每个会话都是一个
持续运行的真实 PTY，您看别处时它也不会停

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero2.png" alt="一个 Codex 会话运行在会话侧边栏旁" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 知道智能体何时需要您

会话圆点显示工作中 / 空闲 / 等您处理，并汇总到菜单栏托盘，在任何应用里
瞥一眼便知；从托盘选中一个会话，Termio 会把它带到最前面

</td>
<td width="50%">
  <img src="web/landing/public/feature/tray.png" alt="菜单栏托盘，按项目分组列出所有会话" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 分屏

会话内的 Ghostty 风格分屏：左边跑智能体，右边开着开发服务器和一个 shell

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero5.png" alt="一个 Claude Code 会话与开发服务器和 shell 分屏并列" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 文件与内置编辑器

终端旁的文件树，点开文件即可就地编辑，带语法高亮与自动保存；图片和 PDF
在 Quick Look 中打开，⌘-点击智能体输出的任意路径即可预览

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero3.png" alt="内置编辑器显示一个 Markdown 文件，旁边是文件树" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 检查器

当前会话的一切尽收眼底：带统一 diff 的 git 变更与历史、项目级内容搜索、
可读的智能体对话记录，以及工作目录操作

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero4.png" alt="Claude Code 会话旁的检查器面板" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### 命令面板

一个搜索框，跳到任意会话、项目或操作

</td>
<td width="50%">
  <img src="web/landing/public/feature/pallette.png" alt="命令面板" width="100%" />
</td>
</tr>
</table>

**还有这些：**

- **Git 工作树**——从侧边栏创建工作树，它会以嵌套文件夹的形式出现在项目下，
  一个分支对应一个并行任务；您在 CLI 里创建的工作树同样会显示出来
- **Chats**——不属于任何项目的临时智能体对话，一个快捷键即可打开
- **用量仪表**——您的 Claude 和 Codex 套餐额度，从各自的凭据本地读取，
  在 Settings → Usage 中查看
- **主题**——浅色、深色，以及跟随系统的玻璃外观
- **自动更新**——经过公证的 DMG，由 Sparkle 负责更新，新版本自动安装

## 与您的智能体协作

Claude Code、Codex、Gemini CLI、Grok、Cursor Agent、Copilot、Amp、OpenCode、
Pi、Kimi——以及任何其他 CLI 智能体，因为会话就是一个货真价实的终端。
对于内置支持的智能体，Termio 会自动安装它们各自的 hook 或插件，
您第一次启动它们时状态检测就已就绪。

## 从终端驱动

Termio 附带 `termio` CLI，会话因此可以脚本化——智能体自己也能调用。
运行在 Termio 里的智能体可以派生一个同伴会话，交给它一个任务，再读回结果：

```sh
termio sessions list                       # 谁在工作、空闲，或在等你
termio sessions spawn "fix the flaky test" # 用一条提示启动新的智能体会话
termio sessions send claude@ab12cd34 "1"   # 回答同伴会话的权限询问
termio sessions watch                      # 实时流式输出状态变化
```

## 在您的 iPhone 上

配套应用把每个 Mac 会话实时镜像到您的手机上——是完整的 TUI，不是聊天摘要。
按键栏把 esc、tab、ctrl 和方向键放在键盘上方，按住说话即可把语音直接转写进
提示词。免费，公测中：[加入 TestFlight](https://testflight.apple.com/join/1Arf1UKR)。

<table>
<tr>
<td width="33%">
  <img src="web/landing/public/screenshots/phone-mirror.webp" alt="iPhone 上实时镜像的 Claude Code 会话" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/phone-keys.webp" alt="键盘上方带 esc、tab、ctrl 和方向键的按键栏" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/phone-projects.webp" alt="列出项目及其检出分支的主页" width="100%" />
</td>
</tr>
</table>

## 路线图

- **Linux 远程服务器** — 会话运行在您自己的 Linux 机器上（VPS、开发机），
  在 Mac 应用中统一管理。
- **Mux 服务器** — 持久会话主机：会话活在机器上，而不是连接里。合上笔记本，
  智能体继续干活；重新连上，屏幕原样恢复。
- **问题分诊** — 在应用内直接查看 GitHub、GitLab、Linear 的 issue，随手交给
  智能体处理。
- **移动端 TUI → GUI** — 在实时镜像之上，把智能体会话可选地渲染成 GUI。
- **Windows 支持** — 原生 Windows 应用，同样的理念、同样的终端内核，不是
  Electron 移植。
- **Web 支持** — 从任意浏览器接入会话，终端还可以通过链接分享。

欢迎在 [GitHub Issues](https://github.com/termio-sh/termio/issues) 关注进展或参与讨论。

## 社区

**Termio 正在寻找长期维护者。** 如果您喜欢用 Termio，也想负责路线图中的
某一块——Linux 远程服务器、Web 客户端、Windows 或 iOS 配套应用——欢迎来
Discord 打个招呼，或直接认领一个 issue。

- **[Discord](https://discord.gg/H9DKVwsE5f)** — 与开发者和其他用户交流
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — 报告 bug、提出功能需求

## 贡献者

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## 许可证

[MIT](LICENSE)。
