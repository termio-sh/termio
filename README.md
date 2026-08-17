<div align="center">

<img alt="Termio" src="web/landing/public/logo.png" width="88" />

### The Terminal-first Agentic Development Environment

[![Release](https://img.shields.io/github/v/release/termio-sh/termio?style=flat&logo=github)](https://github.com/termio-sh/termio/releases)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat)](LICENSE)
[![Discord](https://img.shields.io/badge/Discord-555?logo=discord&logoColor=white)](https://discord.gg/H9DKVwsE5f)

<p>English | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a></p>

<br />

Run Claude Code, Codex, and any CLI agent side by side in a real Mac terminal —<br />
Swift and libghostty, no Electron. A menu-bar dot tells you which one needs you,<br />
and your iPhone tells you when you're away from the desk.

<br />

[**Download for macOS**](https://downloads.termio.sh/termio.dmg) &nbsp;&bull;&nbsp; [Website](https://termio.sh) &nbsp;&bull;&nbsp; [Docs](https://termio.sh/docs) &nbsp;&bull;&nbsp; [Changelog](https://termio.sh/changelog) &nbsp;&bull;&nbsp; [Discord](https://discord.gg/H9DKVwsE5f)

<br />

<img alt="Termio in dark mode: a live Claude Code session next to the project sidebar" src="web/landing/public/screenshots/hero1.png" width="100%" />

</div>

## Install

**[Download Termio for macOS](https://downloads.termio.sh/termio.dmg)** — free,
no account, macOS 14+. Or with [Homebrew](https://brew.sh):

```sh
brew install --cask termio-sh/tap/termio
```

**On iPhone**: get the companion beta on
[TestFlight](https://testflight.apple.com/join/1Arf1UKR), then pair it by
scanning the QR code in the Mac app's Settings ▸ Mobile.

## Built for agentic coding and engineering

The IDE was built around a person typing code. When agents write most of the
code, the environment's job changes: it's where agents work and where you
direct, review, and unblock them. Termio is that environment — Terminal-first,
because that's where the agents already live — built for the new
shape of the work: several agents going at once, most of them fine without
you, one of them stuck. (The longer argument:
[*From IDE to ADE*](docs/essays/from-ide-to-ade.md).)

- **A real terminal, not a web view.** Swift + AppKit on
  [libghostty](https://ghostty.org) (Ghostty's terminal core), rendered with
  Metal. No Electron, no xterm.js.
- **Projects → sessions.** The sidebar mirrors how you actually work: each
  project holds its terminals and agents, with git worktrees nested beneath it
  for parallel tasks.
- **Status with zero setup.** Termio wires up each agent's own hooks and reads
  the signals agents already emit. Working, idle, or *needs you* — per-session
  dots, and a menu-bar tray that stays calm, pulses while agents work, and
  rings when one is blocked on you.
- **Review without leaving.** A read-only git pane (changes, history, unified
  diffs), a file tree with a click-to-edit editor, and project-wide content
  search — the terminal stays the place where you commit.
- **Free.** No account, no license keys, no paid tier. MIT-licensed.

## Features

<table>
<tr>
<td width="50%" valign="middle">

### Sessions, side by side

Every project keeps its own terminals and agent sessions. Switch instantly from
the sidebar — each session is a live PTY that keeps running while you look
elsewhere.

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero2.png" alt="A Codex session running beside the session sidebar" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### Knows when an agent needs you

Session dots show working / idle / needs-you, aggregated into a menu-bar tray
you can glance at from any app. Pick a session from the tray and Termio brings
it to the front.

</td>
<td width="50%">
  <img src="web/landing/public/feature/tray.png" alt="The menu-bar tray with a roster of sessions grouped by project" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### Split panes

Ghostty-style splits inside a session: an agent on the left, a dev server and a
shell on the right.

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero5.png" alt="A Claude Code session split alongside a dev server and a shell" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### Files and a built-in editor

A file tree beside the terminal; click a file and edit it in place with syntax
highlighting and auto-save. Images and PDFs open in Quick Look. ⌘-click any
path an agent prints to preview it.

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero3.png" alt="The built-in editor showing a Markdown file next to the file tree" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### The inspector

Everything about the session at hand: git changes and history with unified
diffs, project-wide content search, a readable trace of the agent's
conversation, and working-directory actions.

</td>
<td width="50%">
  <img src="web/landing/public/screenshots/hero4.png" alt="The inspector panel beside a Claude Code session" width="100%" />
</td>
</tr>
<tr>
<td width="50%" valign="middle">

### Command palette

Jump to any session, project, or action from one search box.

</td>
<td width="50%">
  <img src="web/landing/public/feature/pallette.png" alt="The command palette" width="100%" />
</td>
</tr>
</table>

**Also in the box:**

- **Git worktrees**: create a worktree from the sidebar and it appears as a
  nested folder under the project — one branch per parallel task. Worktrees you
  create from the CLI show up too.
- **Chats**: scratch agent conversations that don't belong to any project, one
  keystroke away.
- **Usage meters**: your Claude and Codex plan limits, read locally from their
  own credentials, in Settings → Usage.
- **Themes**: light, dark, and a glass appearance that follows the system.
- **Auto-update**: notarized DMG with Sparkle updates; new versions install
  themselves.

## Works with your agents

Claude Code, Codex, Gemini CLI, Grok, Cursor Agent, Copilot, Amp, OpenCode,
Pi, Kimi — and any other CLI agent, because a session is just a real terminal.
For the built-in agents, Termio installs each one's own hook or plugin
automatically, so status detection works the first time you launch them.

## Drive it from the terminal

Termio ships a `termio` CLI, so sessions are scriptable — including by the
agents themselves. An agent running inside Termio can spawn a sibling, hand it
a task, and read back the reply:

```sh
termio sessions list                       # who's working, idle, or waiting on you
termio sessions spawn "fix the flaky test" # start a new agent session on a prompt
termio sessions send ab12cd34 "1"          # answer a sibling's permission prompt
termio sessions watch                      # stream status changes as they happen
```

Agents learn this themselves: Session control installs a `termio`
[agent skill](https://termio.sh/skill.md) into each agent's skills folder
(`~/.claude/skills`, `~/.codex/skills`) and keeps it current on every launch.
Any other agent can install the same skill straight from this repo:

```sh
npx skills add termio-sh/termio --skill termio
```

## On your iPhone

The companion app mirrors every Mac session live on your phone — the full
TUI, not a chat summary. A key bar puts esc, tab, ctrl, and arrows above the
keyboard, and hold-to-speak transcribes straight into the prompt. Free, in
public beta: [join on TestFlight](https://testflight.apple.com/join/1Arf1UKR).

<table>
<tr>
<td width="33%">
  <img src="web/landing/public/screenshots/phone-mirror.webp" alt="A live Claude Code session mirrored on the iPhone" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/phone-keys.webp" alt="The key bar with esc, tab, ctrl, and arrow keys above the keyboard" width="100%" />
</td>
<td width="33%">
  <img src="web/landing/public/screenshots/phone-projects.webp" alt="The home page listing projects with their checked-out branches" width="100%" />
</td>
</tr>
</table>

## Roadmap

- **Linux remote server** — run sessions on a Linux machine you own — a VPS, a
  devbox — supervised from the Mac app.
- **Mux server** — a durable session host: the session lives on the box, not in
  the connection. Shut the laptop and the agent keeps working; reattach and the
  exact screen comes back.
- **Issue triage** — GitHub, GitLab, and Linear issues inside the app, ready to
  hand straight to an agent.
- **TUI → GUI on mobile** — an optional GUI rendering of agent sessions on the
  phone, built on top of the live mirror.
- **Windows support** — Termio as a native Windows app. Same idea, same
  terminal core, no Electron.
- **Web support** — attach to your sessions from any browser, with terminals
  you can share by link.

Follow along or weigh in on [GitHub Issues](https://github.com/termio-sh/termio/issues).

## Community

**Termio is looking for long-term maintainers.** If you love using it and
would like to own an area of the roadmap above — the Linux remote server, the
web client, Windows, or the iOS companion — join the Discord and say hi, or
just pick up an issue.

- **[Discord](https://discord.gg/H9DKVwsE5f)** — chat with the developer and other users
- **[GitHub Issues](https://github.com/termio-sh/termio/issues)** — bugs and feature requests

## Contributors

<a href="https://github.com/termio-sh/termio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=termio-sh/termio" alt="Contributors" />
</a>

## License

[MIT](LICENSE).
