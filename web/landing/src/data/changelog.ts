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
    version: "0.36.0",
    date: "2026-08-12",
    title: "Speaks Simplified Chinese",
    changes: {
      new: [
        "Simplified Chinese: the Mac app and the iPhone companion are fully translated. Termio follows your macOS language, and Settings ▸ General pins one if you'd rather choose.",
        "More than one Mac: pair every Mac you work on from the phone and switch between them — the laptop at home, the devbox at the office — from a rail on the Projects screen or the Devices settings page.",
        "Custom relay: point remote access at a relay you host yourself instead of the built-in tunnel.",
        "Session control reaches every agent that supports skills, Amp, Antigravity, Hermes and Kimi included. Agents whose CLI isn't installed are skipped rather than half-configured.",
      ],
      improved: [
        "Agents: adding an agent and building a custom one are one flow now, instead of two controls that did nearly the same thing.",
      ],
      fixed: [
        "A file dropped on a split lands in the pane under the pointer, not the focused one.",
        "A pane's empty state scales to the pane instead of overflowing a small one.",
        "A hidden split group keeps its own pane sizes instead of adopting the visible group's.",
        "Closing an agent session only asks when that session is still running something.",
        "The iPhone holds a session's title steady while an agent rewrites it.",
      ],
    },
  },
  {
    version: "0.35.0",
    date: "2026-08-12",
    title: "Runs on Intel Macs",
    changes: {
      new: [
        "Universal binary: Termio runs on Intel Macs as well as Apple silicon, from the same download.",
        "Usage: Kimi Code and Grok plan limits and token usage sit next to Claude Code and Codex, after a per-agent Allow.",
      ],
      improved: [
        "New Terminal (⌘T) opens in the focused session's working directory, beside that session. File ▸ New Terminal at Home still starts at your home directory.",
      ],
      fixed: [
        "⌘W no longer quits Termio — closing the window leaves every session and agent alive, and the Dock icon brings it back. Quitting, or closing a session that is still running something, now asks first.",
        "A split group's sidebar bracket covers the same rows as the panes on screen.",
        "The reveal arrows in a diff's collapsed bands point the way the reveal walks.",
      ],
    },
  },
  {
    version: "0.34.0",
    date: "2026-08-10",
    title: "Markdown that renders like GitHub",
    changes: {
      improved: [
        "Markdown renders GitHub-flavored: alerts, heading anchors, autolinks, emoji, footnotes, math, and mermaid diagrams — in the inspector's preview, in a session trace, and on the phone.",
      ],
    },
  },
  {
    version: "0.33.2",
    date: "2026-08-10",
    title: "A settings crash, gone",
    changes: {
      fixed: ["Editing ~/.ssh/config from Settings no longer crashes."],
    },
  },
  {
    version: "0.33.0",
    date: "2026-08-09",
    title: "Session control, as a skill",
    changes: {
      new: [
        "Agent skill: Termio installs a termio skill into the agents that support one, so an agent can see its sibling sessions, spawn one, send a prompt, and read the reply — without you pasting CLI instructions into a prompt. Switch it off in Settings ▸ General.",
      ],
      improved: [
        "Settings ▸ General leads with the command line and names the skill section.",
      ],
    },
  },
  {
    version: "0.32.0",
    date: "2026-08-09",
    title: "The font and theme you already picked",
    changes: {
      new: [
        "Ghostty config inheritance: on first launch Termio reads your ~/.config/ghostty/config and starts with the font and theme you already chose there.",
      ],
      improved: [
        "The Interface settings tab folded into Appearance.",
        "An installed dual-width CJK face is appended to the font stack silently, so Chinese, Japanese, and Korean columns line up.",
      ],
      fixed: [
        "The editor's caret snaps to its new position instead of gliding, text sits centered in its line, Markdown bold stops flickering, and per-keystroke redraw churn is gone.",
      ],
    },
  },
  {
    version: "0.31.0",
    date: "2026-08-08",
    title: "The phone says why it can't connect",
    changes: {
      improved: [
        "The companion wire protocol is versioned: a phone and a Mac on mismatched builds now say so instead of failing quietly.",
      ],
      fixed: [
        "History diffs a merge commit against its first parent, and the diff header stays on one line in a narrow pane.",
      ],
    },
  },
  {
    version: "0.30.0",
    date: "2026-08-07",
    title: "A smoother pane drag",
    changes: {
      improved: [
        "Pane drag: the grab handle now appears only along a pane’s top edge, brightens under the pointer, and shows a preview of the pane you’re dragging.",
        "Flip Layout is gone. Drag a pane onto a neighbour’s edge instead.",
      ],
    },
  },
  {
    version: "0.29.0",
    date: "2026-08-07",
    title: "Your phone shows the real diff",
    changes: {
      new: [
        "The iPhone shows your Mac's actual changes and diffs, rendered on the Mac.",
        "Split Left and Split Up join Split Right and Split Down.",
      ],
      improved: [
        "Pane rearrange moved off a modifier chord onto a grab handle that appears on the pane header when you hover it.",
        "The diff's washes, bands, and intraline spans were redrawn.",
        "The inspector's file tree stays fast on huge project roots.",
      ],
      fixed: [
        "The terminal surface stopped swallowing Termio's own shortcuts.",
      ],
    },
  },
  {
    version: "0.28.0",
    date: "2026-08-03",
    title: "Add to Chat",
    changes: {
      new: [
        "Add to Chat: pick it from a file-tree row's menu and the file's path lands in the agent's prompt, ready to send.",
        "iPhone: long-press the terminal to paste.",
      ],
      improved: [
        "macOS AutoFill and Services items are gone from the terminal, diff, editor, and file-preview menus, and Settings' install buttons confirm what they actually did.",
      ],
    },
  },
  {
    version: "0.27.0",
    date: "2026-08-02",
    title: "Stack a pane, or lay it side by side",
    changes: {
      new: [
        "Flip a pane pair between side-by-side and stacked from the pane menu.",
        "iPhone: long-press to select text in the terminal, and paste from the same menu.",
      ],
      fixed: [
        "The file tree keeps its expansion when a detail opens and closes.",
        "Mouse-wheel scrolling is back to full speed in the sidebar, git, and issue panes.",
        "The Issues list keeps its kind under an open detail, and the git pane keeps its mode under an open diff.",
      ],
    },
  },
  {
    version: "0.26.0",
    date: "2026-08-01",
    title: "Drag a pane where you want it",
    changes: {
      new: [
        "Rearrange panes by dragging one onto a neighbour: an overlay previews the drop, an edge half places the pane on that side, and the center swaps the two.",
      ],
    },
  },
  {
    version: "0.25.0",
    date: "2026-07-30",
    title: "Notifications an agent can raise",
    changes: {
      new: [
        "termio notify: an agent can raise a native macOS notification from its own shell — a title, a body, and a click that jumps to the session it came from.",
        "The inspector's side is per session, so one session can keep files on the right while another keeps them on the left.",
        "Issues: a pull request's files read as one continuous multi-file diff.",
      ],
      improved: [
        "The pane a CLI-spawned agent anchors to keeps its full size, and the pane context menu grew.",
        "iPhone: theme-tinted chrome and a bigger attach menu.",
      ],
    },
  },
  {
    version: "0.24.0",
    date: "2026-07-28",
    title: "An inspector that gets out of the way",
    changes: {
      new: [
        "Grok's OSC 9;4 progress is read as an in-band busy/idle signal, so its status no longer depends on hooks.",
      ],
      improved: [
        "The inspector's list column resizes, its tabs became one flat pill, and a maximized detail sits beside the sidebar with the tabs hidden.",
        "The your-turn status moved to a ring around the session's icon.",
        "iPhone: gestures follow your finger's velocity, with Reduce Motion fallbacks.",
      ],
      fixed: [
        "Issues recovers from a GitHub 403 with a reconnect and a grant-org-access prompt.",
        "The file preview header keeps its close and maximize controls, and opening a detail no longer force-grows the inspector.",
      ],
    },
  },
  {
    version: "0.23.0",
    date: "2026-07-28",
    title: "A real editor in the inspector",
    changes: {
      new: [
        "Two-column inspector: files, diffs, pull requests, and session traces open in a detail column beside the list instead of replacing it.",
        "The file editor grew a pinned header and an in-editor find bar (contributed by @brelian), both wearing one Liquid Glass design shared with the diff.",
        "iPhone: voice-to-text dictation from the terminal keyboard's ＋ menu, and a ＋ that offers what makes sense on each of the three tabs.",
      ],
      fixed: [
        "Agent hooks survive another tool overwriting the shared hook config.",
      ],
    },
  },
  {
    version: "0.22.0",
    date: "2026-07-27",
    title: "Switch themes without leaving the terminal",
    changes: {
      new: [
        "Change Theme: open the command palette (⌘⇧P), pick Change Theme…, and browse — each theme previews live on your open terminals as you arrow through, Enter keeps it, Esc snaps back. It edits the slot for your current appearance and shows a color swatch per theme.",
      ],
      fixed: [
        "The theme pickers list the full bundled catalog again (hundreds of themes), not just the popular shortlist.",
      ],
    },
  },
  {
    version: "0.20.0",
    date: "2026-07-26",
    title: "Your agents can tap you on the shoulder",
    changes: {
      new: [
        "Task notifications: when an agent finishes a task — or stops to ask you something — while Termio is in the background, a native macOS notification appears with the agent's icon; click it to jump straight to that session. Quick replies and answer-only chat turns stay quiet, and a blocked agent always gets through. Toggle it (and its sound) in Settings › General.",
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
        "Termio is now MIT-licensed.",
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
        "Status from the source: Termio now reads the status marks agents broadcast in their terminal titles — Claude's spinner, Codex and Grok's \"Action Required\" — so the sidebar lights up the instant a turn starts, ends, or blocks on you.",
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
        "The per-project Seatbelt sandbox has been retired: modern agents ship their own sandboxes, and macOS is deprecating the mechanism Termio's relied on. One project setting fewer.",
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
    title: "Termio notices your agents",
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
