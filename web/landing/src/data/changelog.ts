// The changelog rendered at /changelog, newest entry first. Termio ships through
// Sparkle, so a release here corresponds to a notarized build users auto-update
// to. Keep entries short and user-facing — what changed, not how. Categories are
// optional; omit any that are empty for a release. Items may open with a short
// "Label: rest" lead — the page renders the label bold, Glaze-style.

export type ChangeKind = "new" | "improved" | "fixed";

export type ChangelogEntry = {
  version: string;
  // ISO date (YYYY-MM-DD) of the release; formatted for display at render time.
  date: string;
  // The release headline — what this version is remembered for.
  title: string;
  changes: Partial<Record<ChangeKind, string[]>>;
};

export const changelog: ChangelogEntry[] = [
  {
    version: "0.20.0",
    date: "2026-07-26",
    title: "Your agents can tap you on the shoulder",
    changes: {
      new: [
        "Task notifications: when an agent finishes a task — or stops to ask you something — while termio is in the background, a native macOS notification appears with the agent's icon; click it to jump straight to that session. Quick replies and answer-only chat turns stay quiet, and a blocked agent always gets through. Toggle it (and its sound) in Settings › General.",
        "Issues: a new inspector pane lists the project's GitHub issues and pull requests, readable without leaving the terminal.",
        "SSH: an SSH settings tab reads ~/.ssh/config as the source of truth, with Test Connection probes — and New SSH Connection now lists your config hosts, one click to connect.",
        "Sessions CLI: send and spawn take --wait to block until the turn settles, and watch emits stalled events when a working session stops making progress.",
      ],
      improved: [
        "Markdown preview renders GitHub-compatible.",
        "Settings reopens on the tab you last used, and the Keyboard pane is redesigned System Settings style.",
        "Large files open faster in the editor, and branch watching no longer spawns a git subprocess storm.",
      ],
      fixed: [
        "Search results survive multi-byte text at the output cap.",
        "SSH sessions draw with the server glyph at the right size.",
      ],
    },
  },
  {
    version: "0.19.2",
    date: "2026-07-25",
    title: "Cold starts and a louder CLI",
    changes: {
      improved: [
        "The sessions CLI fails loudly instead of silently: spawn stopped blocking, and watch gained a v2 event stream.",
      ],
      fixed: [
        "The shell's first prompt renders on a cold start.",
        "Sidebar session clicks are instant again (0.19.1).",
      ],
    },
  },
  {
    version: "0.19.0",
    date: "2026-07-25",
    title: "Drag to reorder",
    changes: {
      new: [
        "Sidebar sessions reorder by dragging the row — within a project, worktree, Terminals, or Chats bucket. Split-pane grouping moved to the row's context menu and ⌘D.",
      ],
      improved: [
        "Opening projects and scrolling the sidebar stay off blocking I/O, and every working spinner shares one indicator.",
      ],
      fixed: [
        "Per-session state is retired with its session instead of lingering.",
      ],
    },
  },
  {
    version: "0.18.0",
    date: "2026-07-24",
    title: "Supervise sessions from the CLI",
    changes: {
      new: [
        "Sessions CLI: spawn a new agent on a prompt, send follow-ups, and watch status transitions stream by — enough to let one agent supervise its siblings.",
        "Grok transcripts render in the session trace.",
      ],
      improved: [
        "iOS: home chrome redrawn with Hugeicons, and loose terminals get their own tab.",
      ],
      fixed: [
        "iOS: the phone mirror no longer echoes terminal query replies, and slow agent TUIs reflow when entering the alternate screen.",
      ],
    },
  },
  {
    version: "0.17.0",
    date: "2026-07-24",
    title: "Split panes, MIT",
    changes: {
      new: [
        "Split panes: agents started from the CLI auto-split beside their caller, and any two sessions can be grouped or ungrouped by hand.",
        "termio is now MIT-licensed.",
      ],
      improved: [
        "Sidebar scrolling stays smooth with many busy sessions.",
        "The git pane survives floods of untracked files, and its ignore actions match GitHub Desktop verbatim.",
      ],
    },
  },
  {
    version: "0.16.0",
    date: "2026-07-23",
    title: "Sessions that know what they run",
    changes: {
      new: [
        "Persistent agent identity: hand-start claude in a plain terminal and the session becomes a Claude Code session — for real, surviving restarts; a clean /quit returns it to a shell, and an in-pane self-update relaunches the agent in place.",
      ],
      improved: [
        "The menu-bar roster shows only sessions that need you, with the sidebar's comet for working ones.",
        "The file explorer's row menu grew, and the tree auto-refreshes.",
      ],
    },
  },
  {
    version: "0.15.2",
    date: "2026-07-21",
    title: "Green stays green",
    changes: {
      fixed: [
        "A finished turn keeps its green dot when a trailing turn-complete notification arrives (Grok).",
      ],
    },
  },
  {
    version: "0.15.1",
    date: "2026-07-21",
    title: "History chips",
    changes: {
      improved: [
        "History rows carry tag chips and unpushed markers; the commit-count bar is gone.",
      ],
    },
  },
  {
    version: "0.15.0",
    date: "2026-07-21",
    title: "Git pane polish",
    changes: {
      improved: [
        "The git pane gets a glass mode switch, aligned headers, and GitHub-Desktop-style single-line history rows.",
      ],
    },
  },
  {
    version: "0.14.0",
    date: "2026-07-21",
    title: "A real diff viewer",
    changes: {
      new: [
        "The diff is one continuous view: selection flows across hunks, ⌘F searches it, keyboard walks it, and changed words highlight within lines.",
        "Docs: termio.sh gained a documentation site, served for agents too (llms.txt and raw-Markdown routes).",
        "iOS: worktree branches, Chats, and Markdown previews sync to the phone.",
      ],
      improved: [
        "Add Agent replaces the More-agents drawer, gated on what's actually installed.",
        "Status tracking follows in-process conversation rotation (/new, /clear) for Claude, Codex, OpenCode, Pi, and Grok.",
      ],
    },
  },
  {
    version: "0.13.0",
    date: "2026-07-19",
    title: "Agent status you can trust",
    changes: {
      new: [
        "Status from the source: termio now reads the status marks agents broadcast in their terminal titles — Claude's spinner, Codex and Grok's \"Action Required\" — so the sidebar lights up the instant a turn starts, ends, or blocks on you.",
        "Grok joins the built-in agent lineup.",
        "Markdown: .md files open in an Edit/Preview editor with a book-quality reading view.",
        "Agent manifests: the built-in lineup is now driven by editable manifest files, with a redesigned Agents settings pane — reorder the roster or add your own agents.",
      ],
      improved: [
        "The working spinner speaks one status language — motion means working, green means done, orange means needs you — with a sharper comet animation.",
        "Projects sort by name by default.",
      ],
      fixed: [
        "Status dots no longer freeze mid-turn: a session whose status reports go quiet now heals itself from its live output, and status reporting survives app rebuilds.",
        "The Changes pane shows images instead of an empty diff.",
      ],
    },
  },
  {
    version: "0.12.1",
    date: "2026-07-18",
    title: "Sandbox retirement",
    changes: {
      improved: [
        "The per-project Seatbelt sandbox has been retired: modern agents ship their own sandboxes, and macOS is deprecating the mechanism termio's relied on. One project setting fewer.",
      ],
      fixed: [
        "Folders in the file tree expand and collapse from a single click on the row.",
      ],
    },
  },
  {
    version: "0.12.0",
    date: "2026-07-18",
    title: "Antigravity",
    changes: {
      improved: [
        "The Gemini agent is now Antigravity, matching Google's rebrand.",
        "File-tree folders toggle open from a single click.",
      ],
    },
  },
  {
    version: "0.11.0",
    date: "2026-07-17",
    title: "Two more agents",
    changes: {
      new: [
        "Antigravity and Hermes join the built-in lineup, each with its real brand icon and a working install link.",
      ],
      improved: [
        "The Files tab is more compact and always shows dotfiles.",
      ],
    },
  },
  {
    version: "0.10.0",
    date: "2026-07-17",
    title: "Chats, Pinned, and a git reviewer",
    changes: {
      new: [
        "Chats: quick agent conversations that belong to no project get their own top-level section, with a default-agent picker.",
        "Pinned: keep a working set of sessions at the very top of the sidebar.",
        "Worktrees you create from the command line now appear in the sidebar on their own.",
      ],
      improved: [
        "The git pane is now a focused Changes + History reviewer — Xcode-style history with per-commit diffs. Committing and pushing stay where they belong: your terminal.",
      ],
    },
  },
  {
    version: "0.9.0",
    date: "2026-07-16",
    title: "Your keys, your shortcuts",
    changes: {
      new: [
        "Keyboard shortcuts: every command is rebindable from a new Settings pane with a shortcut recorder.",
        "SSH terminals: open a remote terminal straight from the + menu.",
      ],
      improved: [
        "Settings moved to a System Settings-style sidebar window.",
        "Hand-started agents show their agent name on the terminal's sidebar row.",
      ],
    },
  },
  {
    version: "0.8.0",
    date: "2026-07-15",
    title: "termio notices your agents",
    changes: {
      new: [
        "Start claude, codex, or any agent by hand in a plain terminal and its row upgrades itself — brand icon, live title, working status — no setup required.",
      ],
    },
  },
  {
    version: "0.7.0",
    date: "2026-07-14",
    title: "A more native terminal",
    changes: {
      improved: [
        "Sessions handle process exit like a native terminal: exited shells close cleanly instead of lingering.",
        "Search adopts the native macOS find bar.",
      ],
      fixed: [
        "Terminal focus recovers reliably after window and pane switches.",
        "Browser panes match the terminal theme instead of flashing white.",
      ],
    },
  },
  {
    version: "0.6.1",
    date: "2026-07-13",
    title: "Small chrome fix",
    changes: {
      fixed: ["The sidebar's + button keeps its proper width."],
    },
  },
  {
    version: "0.6.0",
    date: "2026-07-13",
    title: "Loose terminals and browser panes",
    changes: {
      new: [
        "Plain terminals and browser panes are now first-class panes alongside agent sessions — split a browser next to your agent.",
      ],
      fixed: [
        "A rare app-wide beachball caused by a blocked terminal write is gone.",
      ],
    },
  },
  {
    version: "0.5.6",
    date: "2026-07-13",
    title: "Paste images to agents",
    changes: {
      fixed: [
        "Cmd+V pastes a clipboard image straight into agent TUIs like Claude Code.",
        "Usage limits refresh on demand with per-agent opt-in, never at launch.",
      ],
    },
  },
  {
    version: "0.5.5",
    date: "2026-07-12",
    title: "Calmer status at rest",
    changes: {
      fixed: [
        "Stale attention and done markers clear when they no longer apply.",
      ],
    },
  },
  {
    version: "0.5.4",
    date: "2026-07-12",
    title: "Palette filtering fix",
    changes: {
      fixed: ["The command palette list renders correctly while filtering."],
    },
  },
  {
    version: "0.5.3",
    date: "2026-07-12",
    title: "Pi launches cleanly",
    changes: {
      fixed: ["Pi sessions launch without a resume warning."],
    },
  },
  {
    version: "0.5.2",
    date: "2026-07-12",
    title: "Diffs in your editor font",
    changes: {
      fixed: ["Diffs render in the same font as the editor."],
    },
  },
  {
    version: "0.5.0",
    date: "2026-07-12",
    title: "The nine-dot T",
    changes: {
      improved: [
        "The app icon now spells a T in its nine-dot grid.",
      ],
      fixed: [
        "Rows in the Changes list reliably open their diff.",
        "A display-sleep memory runaway in the terminal renderer is fixed.",
      ],
    },
  },
  {
    version: "0.4.0",
    date: "2026-07-11",
    title: "Search the whole project",
    changes: {
      new: [
        "Content search: search across every file in the project from the inspector and jump straight to the matching line in the editor.",
      ],
    },
  },
  {
    version: "0.3.0",
    date: "2026-07-10",
    title: "Split panes and command palettes",
    changes: {
      new: [
        "Split panes: split a session vertically or horizontally and work in multiple terminals side by side.",
        "Command palette: drive splits, sessions and terminal actions from the keyboard, alongside a new Terminal menu.",
        "Rename a session from its right-click menu in the sidebar.",
      ],
      fixed: [
        "Opening a file in the editor no longer crashes downloaded builds.",
        "Closing a session now ends its entire process tree, so no stray agent processes are left behind.",
      ],
    },
  },
  {
    version: "0.2.4",
    date: "2026-07-09",
    title: "A welcome start page",
    changes: {
      new: [
        "A welcome page greets you when nothing is open — start a session, pick an agent, or jump back into a recent project.",
      ],
      improved: [
        "Settings now flags agents whose command-line tool isn't installed, and fresh installs start with a focused default lineup.",
      ],
    },
  },
  {
    version: "0.2.3",
    date: "2026-07-09",
    title: "Agents repaint on resize",
    changes: {
      fixed: [
        "Agents now redraw correctly when you resize the window, instead of freezing at their old layout.",
      ],
    },
  },
  {
    version: "0.2.2",
    date: "2026-07-08",
    title: "The right login shell",
    changes: {
      fixed: [
        "Sessions now resolve your login shell from the system's user directory instead of the ambient environment, so they launch with the right shell every time.",
      ],
    },
  },
  {
    version: "0.2.1",
    date: "2026-07-08",
    title: "A new app identity",
    changes: {
      improved: [
        "The app's bundle identifier is now sh.termio.app. If auto-update doesn't offer this release, download it once from the site — updates continue normally afterwards.",
      ],
    },
  },
  {
    version: "0.2.0",
    date: "2026-07-08",
    title: "Four new agents and named worktrees",
    changes: {
      new: [
        "Amp, Cursor, Droid and Kimi Code join the built-in agent lineup, each with live status and its real brand icon.",
        "New Worktree: create a named git worktree straight from a project's right-click menu.",
      ],
      fixed: [
        "The first prompt no longer appears shoved to the right after launch.",
        "The window resizes freely again when no session is selected.",
      ],
    },
  },
  {
    version: "0.1.1",
    date: "2026-07-06",
    title: "Launch fix for downloaded builds",
    changes: {
      fixed: [
        "Downloaded builds now launch reliably — 0.1.0 could crash on first open on some Macs.",
      ],
    },
  },
  {
    version: "0.1.0",
    date: "2026-07-06",
    title: "Hello, Termio",
    changes: {
      new: [
        "Termio's first public release — a native Mac terminal built for running AI coding agents, free to download.",
        "Projects and sessions live in a full-height sidebar, with live working / idle / attention status for every agent.",
        "Git worktrees are grouped as folders under their project, and each folder shows its live branch.",
        "Sandbox: opt a project into running its sessions inside an Apple Seatbelt sandbox, contained from the rest of your Mac.",
        "A menu-bar roster lists your live agent sessions for quick switching.",
        "A bundled command-line tool opens projects and launches sessions from your shell.",
      ],
    },
  },
];
