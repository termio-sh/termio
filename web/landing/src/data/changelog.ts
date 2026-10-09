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
    version: "0.56.0",
    date: "2026-10-09",
    title: "Agents report their own status over the terminal",
    changes: {
      new: [
        "Program status: Claude Code 2.1.295 and Pi 1.1.0 tell Termio whether they are working, waiting on you, or done over the terminal itself (OSC 7501). It needs no hooks and works the same on a remote machine. Older versions keep reporting through hooks.",
      ],
    },
  },
  {
    version: "0.55.1",
    date: "2026-10-07",
    title: "Closing a session stops its agent",
    changes: {
      improved: [
        "The terminal engine moves to the latest Ghostty, with its fixes to character sets, single shifts, and line selection at the prompt.",
      ],
      fixed: [
        "Closing a session stops its agent, even when a launch command runs the agent under a shell.",
        "An agent that updates itself mid-session relaunches as the new version, instead of leaving its pane at a shell.",
        "A remote session that is slow to connect is no longer closed as if its agent had failed to start.",
      ],
    },
  },
  {
    version: "0.55.0",
    date: "2026-09-21",
    title: "Highlights go into a PDF without rewriting it",
    changes: {
      improved: [
        "“Save Highlights into PDF” is near-instant and leaves the document's existing bytes untouched. Marks are appended the way Preview writes them, rather than rewriting the whole book — a 270-page PDF took over a second and grew by megabytes, and now takes milliseconds and adds under a kilobyte.",
        "A passage spanning several lines is written as one highlight instead of one per line, so it reads back as a single mark in Preview, Books, and anything else that opens the file.",
      ],
      fixed: [
        "An agent launch command containing `&&`, `;`, or `|` is no longer cut off at the first command, which used to open a plain shell instead of the agent. An agent that fails the moment it launches now leaves its error on screen instead of silently handing the pane back to a shell.",
        "A PDF opens on the page rather than on its table of contents. The sidebar is one click away in the header, and stays open once you open it.",
        "A diff keeps updating as the working tree changes, search navigation works again, focus returns to the active column, and the folded-line controls have clearer spacing and hover feedback.",
        "Agent status hooks are no longer rewritten on every update, so Codex and other agents that verify their hook files stop asking you to trust them after each release.",
      ],
    },
  },
  {
    version: "0.54.0",
    date: "2026-09-20",
    title: "PDFs open in a reader, not a preview",
    changes: {
      new: [
        "A PDF opens with its own table of contents, a page rail, and a go-to page field. A book that carries no contents of its own still gets a page rail.",
        "Select text in a PDF and right-click to mark it in one of five colours, copy it, or add it to the agent's prompt. ⇧⌘H marks the selection without the menu.",
        "Highlights are kept beside the document as readable JSON, so the PDF itself is never rewritten and a paper in a repo stays clean. Inside a checkout they are filed with the repo, so they can be committed and reviewed. “Save Highlights into PDF” writes them into the document when you want them to travel with it.",
        "Marks made in Preview or Books are listed too, and a highlight survives the document being renamed or re-exported.",
        "A diff can be read side by side, and the diff header picks the file.",
      ],
      fixed: [
        "A remote session's screen no longer paints a background colour the screen never held.",
        "The inspector's list column has its own glyph instead of borrowing the pane switch's.",
      ],
    },
  },
  {
    version: "0.53.5",
    date: "2026-09-19",
    title: "The input method's candidate window stays off what you're typing",
    changes: {
      improved: [
        "Setting a machine up is putting the server and the hooks on it, and reaching the box is the only thing that can stop it. A machine with no agent CLI now says so in its own line instead of failing setup, and an agent you install afterwards is noticed.",
      ],
      fixed: [
        "Typing Chinese, Japanese, or Korean no longer puts the input method's candidate window on top of the characters you are typing.",
        "Hooks are written only for the agents that are on the machine, instead of for every agent in the catalog.",
        "Copying a file in Finder and pasting it into a terminal now gives its full path, not just its name.",
        "An image file copied on the Mac now reaches a session running on another machine.",
      ],
    },
  },
  {
    version: "0.53.4",
    date: "2026-09-18",
    title: "A session that loses its connection comes back on its own",
    changes: {
      improved: [
        "Settings: hooks and the agent skill now sit on a machine's Agents page, beside the CLIs they are written for, and Server has its own page apart from Remote Hosts.",
      ],
      fixed: [
        "Losing the connection to a session no longer strands its pane. Termio reconnects on its own — and immediately when you come back to the app — instead of asking you to close the session, which would have ended it.",
        "Dropping a file onto a split now hands it to the pane you can see, not to whichever pane happened to be mounted last.",
        "Plain-text files — a LICENSE, anything past the highlighting limit — are drawn in the theme's ink instead of black on a dark background.",
        "Collapsing the sidebar and reopening it no longer takes the navigator button, workspace name, sort menu and ＋ out of the toolbar for good.",
        "An ended session says what ended it in plain words, instead of showing the daemon's own vocabulary.",
      ],
    },
  },
  {
    version: "0.53.3",
    date: "2026-09-15",
    title: "Widening a terminal no longer leaves pieces of the old one behind",
    changes: {
      fixed: [
        "Widening a terminal — by dragging a split divider or a window edge, or by maximising the window — no longer leaves stray fragments of the previous width on screen.",
        "Dragging a split divider now reflows the session while you drag, instead of only after you let go.",
      ],
    },
  },
  {
    version: "0.53.2",
    date: "2026-09-13",
    title: "The navigator button holds its line in full screen",
    changes: {
      fixed: [
        "The navigator button no longer sits far right of the sidebar in full screen, where there are no traffic lights for it to clear.",
      ],
    },
  },
  {
    version: "0.53.1",
    date: "2026-09-13",
    title: "The sidebar finds the window's left edge",
    changes: {
      fixed: [
        "Section labels and row icons in the sidebar now line up with the traffic lights, and the first section starts at the top of the column instead of below it.",
        "The navigator button no longer shifts sideways when the sidebar is collapsed or reopened.",
      ],
    },
  },
  {
    version: "0.53.0",
    date: "2026-09-10",
    title: "The branch label goes remote",
    changes: {
      new: [
        "A session's branch label stays live when its repo is on another machine — switch branches on the box and the sidebar follows, no SSH round-trip.",
        "Every remote deploy now ships the termio command beside the session host, and sessions find it first on their PATH, so agents on a box report working / needs-you the same way they do on this Mac.",
        "Diagrams and images in the reader open full screen.",
      ],
      fixed: [
        "Deleting a worktree's folder outside Termio no longer strands its row — the sidebar matches rows to git's own record and lets go of what git no longer tracks, and a checkout that isn't there offers no session.",
      ],
    },
  },
  {
    version: "0.52.1",
    date: "2026-09-09",
    title: "Updates stop garbling running sessions",
    changes: {
      fixed: [
        "Updating Termio no longer leaves running sessions with garbled screens on the next reattach — a session carried across an update repaints cleanly the moment a phone or a Mac window opens it again.",
        "Setting up a remote device records what the deploy just observed, so the next connection doesn't re-ask the machine what it already answered.",
      ],
    },
  },
  {
    version: "0.52.0",
    date: "2026-09-08",
    title: "The phone stops fighting over the width",
    changes: {
      new: [
        "OpenCode 2 joins the agent roster, with live working / needs-you status through its new plugin dialect.",
      ],
      improved: [
        "The session's size now stays where the last person put it: locking or backgrounding the iPhone no longer bounces the width back to an unattended Mac window, so picking the phone back up is instant instead of a full reflow.",
        "Opening the iPhone keyboard no longer resizes the terminal — the view slides just enough to keep the cursor's row above the keys, so agent screens stop repainting on every tap.",
      ],
      fixed: [
        "Resizing a session while its agent ran a shell command no longer truncates the agent's screen — lines rewrap to the new width with nothing lost, which was leaving stale fragments in transcripts after switching between Mac and phone.",
      ],
    },
  },
  {
    version: "0.51.0",
    date: "2026-09-08",
    title: "Remote projects launch agents",
    changes: {
      new: [
        "Remote projects launch agent sessions now, not just terminals: the box's own session host starts the agent through its login shell, in the recorded checkout, and the session survives disconnects like any other.",
        "Updating Termio updates this Mac's session host too: the daemon takes the new binary in place, keeping every running session. When that isn't free, Termio names the sessions in the way and asks instead of interrupting them.",
      ],
      improved: [
        "termio version flags a session host running behind the installed binary and says how to bring it current.",
      ],
      fixed: [
        "Sessions started by hand on a remote box now group under their git repository on a directly-attached iPhone, instead of all landing in Terminals.",
        "Fixed a garbled agent screen on iPhone after the terminal resized down to the phone's width.",
      ],
    },
  },
  {
    version: "0.50.0",
    date: "2026-09-07",
    title: "Resizing reflows the shell",
    changes: {
      new: [
        "Resizing a session no longer cuts off long lines while the shell sits at a prompt — the screen rewraps to the new width in both directions, without duplicating the prompt. zsh gets this automatically; other shells keep the old behavior.",
      ],
      improved: [
        "The terminal reflows under the window edge while you drag, instead of waiting for the drag to end.",
      ],
      fixed: [
        "Opening a session from the phone no longer resizes it to the Mac's window first, which was mangling agent TUIs' composer boxes on every open.",
        "⌘H hides the app: the app menu now carries the standard Hide Termio, Hide Others, and Show All items.",
      ],
    },
  },
  {
    version: "0.49.1",
    date: "2026-09-07",
    title: "The sidebar stops stalling the app",
    changes: {
      fixed: [
        "Beachballs traced to the sidebar are gone: rows measure their height without re-entering the list's own layout, the sidebar stops re-sizing itself on every update, and the working indicator ticks on a clock instead of on every repaint.",
        "The inspector keeps its width while the sidebar toggles, and its divider stays draggable after any split relayout.",
      ],
      improved: [
        "Sidebar icons are parsed once and cached, so a long session list scrolls without redoing that work per row.",
      ],
    },
  },
  {
    version: "0.49.0",
    date: "2026-09-04",
    title: "A remote checkout reads like a local one",
    changes: {
      new: [
        "The Changes pane reads a remote machine's checkout — status, diffs, history, and branch comparison — over the session host instead of shelling out over SSH, so a repo on a VPS behaves like one on this Mac.",
        "The file tree and content search go the same way. Search is ripgrep's own engine embedded in the host, and it honours the repo's excludes.",
        "Agents can carry their own startup arguments, set per agent in Settings.",
        "The termio command is a real binary now, shipped inside the app instead of a shell script — it fails loudly instead of guessing, and rejects a flag it does not know rather than passing it on as text.",
      ],
      improved: [
        "A session is sized to the screen someone is actually using. Working on the phone sizes it to the phone; typing on the Mac hands it back, and a window nobody is looking at stops holding it down.",
        "Workstream status is derived on the machine the session lives on, so a session opened straight from the phone reports without the Mac in the middle.",
      ],
      fixed: [
        "Resizing a window no longer mangles the screen. A drag now costs one repaint at the end instead of twenty racing the program's own redraw, the screen is captured after the program answers rather than before, and dragging outward grows the terminal with the window instead of leaving it in the corner until you let go.",
        "A pane you switch back to repaints instead of showing text wrapped at the width it had when you left it.",
        "Dev servers and test runners no longer die from running out of file descriptors — the session host raises the limit it hands the shells it spawns.",
        "A file sitting where the session host's socket belongs is never deleted, and stopping the host waits on the socket rather than on a pid and a filename.",
        "A terminal answering a query — a cursor or focus report — no longer counts as typing, so two devices watching one session stop fighting over it.",
      ],
    },
  },
  {
    version: "0.48.0",
    date: "2026-08-31",
    title: "A session off screen keeps reporting",
    changes: {
      new: [
        "The Mac stays awake while any session is busy. An agent stopped at a permission prompt no longer lets the machine idle into sleep before your phone can answer.",
        "termio version prints one table — this client, the app, this Mac's session host, and every known remote's — so version skew is visible before it bites.",
      ],
      improved: [
        "When a machine can't be reached, its dot now carries ssh's own last words — \"Permission denied (publickey)\" instead of \"the connection closed\" — and a box without the session host installed says exactly that. Fix the network, switch back to the app, and it reconnects by itself.",
      ],
      fixed: [
        "A session whose pane wasn't on screen could freeze mid-turn: its screen served the same stale frame for minutes, watch missed the moment an agent finished, and send --wait came back while the target was still working. Hidden panes now keep processing their output; only the drawing pauses.",
        "An agent that exited back to its shell no longer loses its row to Also Running — the row demotes in place, and closing a session that never rendered a pane really closes it.",
        "Reattaching could land the screen a line off and eat the bottom row; the repaint now puts everything back exactly where it was.",
        "Linux: a reboot no longer renames the box or disarms its phone listener — the session host's identity and pairing state moved to a directory that survives restarts, and pair --rotate really revokes the old token everywhere.",
        "Font and theme inheritance reads Ghostty's config the way Ghostty does: the config.ghostty filenames, light:/dark: theme pairs, and CRLF-saved files all parse now.",
      ],
    },
  },
  {
    version: "0.47.0",
    date: "2026-08-30",
    title: "Upgrading the session host no longer costs you your sessions",
    changes: {
      new: [
        "Updating a machine's session host replaces the binary in place. Agents keep running, scrollback survives, and an upgrade that cannot go ahead puts everything back and carries on rather than taking your work with it.",
        "The file tree for a remote project updates itself when files change on that machine, instead of reloading every time you switch back to the window.",
        "Linux: the session host is supervised by a systemd --user unit, so it comes back after a reboot.",
      ],
      improved: [
        "Opening a remote file and expanding a folder ask the machine for only what changed, so a checkout an agent is writing to no longer costs a full listing on every glance.",
      ],
      fixed: [
        "Quitting no longer warns that it will end every session — it hasn't for some time.",
        "A finished agent could freeze the app for seconds while its transcript was counted. The count happens off the main thread now, and is cached.",
        "iPhone: an observer's screen could stay blank or letterboxed after the Mac resized, cursor reports could be read as typing, and F3 with a modifier was dropped.",
      ],
    },
  },
  {
    version: "0.46.1",
    date: "2026-08-29",
    title: "A stalled session no longer freezes the app",
    changes: {
      fixed: [
        "Reattaching a session with a large backlog could freeze the whole app with a beachball. The terminal's reader and the main thread no longer share a lock, so a pane that stalls stays one stalled pane.",
      ],
    },
  },
  {
    version: "0.46.0",
    date: "2026-08-28",
    title: "A frozen session leaves evidence behind",
    changes: {
      new: [
        "The session host keeps a log at ~/Library/Logs/termio/termiod.log, so a session that froze or died has something to show for it afterwards. `termiod logs` prints it.",
      ],
      fixed: [
        "In fullscreen, the navigator toggle sat a gap away from the column below it once the titlebar was summoned.",
      ],
    },
  },
  {
    version: "0.45.0",
    date: "2026-08-28",
    title: "A device's files answer the click",
    changes: {
      new: [
        "Settings ▸ Mobile ▸ Direct Attach: the Mac can serve the iPhone from its own session host, the same way a Linux box does.",
        "A machine's pane publishes the box for your phone — Tunelo, Cloudflare, ngrok, or your own command — and reads the address back, so the invite, the daemon and the phone can't disagree about it.",
      ],
      improved: [
        "Opening a file on a device puts the file's header on screen at the click; the content fills in when it lands. A file you've read before opens at once and is checked against the device behind you.",
        "Expanding a folder on a device fetches the folders inside it ahead of your next click, and a folder still waiting on its listing shows a spinner instead of drawing as empty.",
        "A device's file tree keeps its connection warm while the pane is on screen, so a click seconds later doesn't pay to reconnect.",
        "A split opens in the working directory of the pane it came from, on this Mac and on a device.",
      ],
      fixed: [
        "A pane could tear along a vertical seam under a burst of output — the left of the screen a frame ahead of the right — and heal a frame later. The renderer no longer draws into a surface still on screen.",
        "The phone no longer flashes a blank screen on every reconnect.",
        "Dark text on a light theme read thinner on the phone than on the Mac. Both now blend glyphs the same way.",
      ],
    },
  },
  {
    version: "0.44.0",
    date: "2026-08-27",
    title: "Set up a machine in one step, every time",
    changes: {
      new: [
        "Installing and updating termiod on a machine is one step that works from any state: nothing installed, an older build, a newer build the daemon hasn't picked up. Set Up puts the right binary there, restarts the daemon when it's safe, checks the new one answers, and puts the old one back if it doesn't.",
        "termiod reports its version. A machine's pane shows what it runs, and an update waiting on work in progress says so — naming the session — with Update Anyway beside it.",
        "Your own idle terminals on a machine no longer block its update; only a command still running or an agent mid-task does.",
        "Settings ▸ General ▸ Privacy: a switch for anonymous daily usage statistics. It sends nothing in this release.",
      ],
      improved: [
        "A machine's pane offers one action, not the same one twice; hooks and the skill each get their own Reinstall row.",
        "A machine whose daemon is restarting for an update keeps its spinner instead of reading as unreachable.",
        "The terminal engine is ghostty v1.3.1-2293, on the Mac, on the phone, and on every machine's daemon.",
      ],
      fixed: [
        "Installing agent hooks — on this Mac and on devices — failed in 0.43.0 with \"unknown variant\". It works again.",
        "The remote file explorer is titled with the folder it shows, not the device.",
      ],
    },
  },
  {
    version: "0.43.0",
    date: "2026-08-27",
    title: "Every machine, set up like this one",
    changes: {
      new: [
        "Settings now says which machine it means. Agents, Workspace and the rest carry a machine scope, every device you've added is a row rather than something behind a picker, and each one gets its own pages. What you change on a device is what that device gets.",
        "Agent integration installs onto another machine, not just this one. termio reads the same agent manifests it uses here and writes the hooks, the plugin dialects, the config block and the skill onto the box over the daemon — so an agent on a VPS reports working, waiting and done the way a local one does.",
        "The file tree reaches the other machine. Search a checkout on a device and follow its `cd`, open what the search found, and save the file back to the device it was read from.",
        "Your phone can attach straight to a device over the session protocol, instead of only reaching it through this Mac.",
        "The code editor learned real editing: find and replace with the Mac find keys, comment lines, move and copy lines, indent on Return, Tab to indent a block, indentation guides, and a wash on other occurrences of the word under the caret.",
        "⌘W closes the focused session. It never quits termio.",
      ],
      improved: [
        "Panes you can't see stop rendering. A window full of sessions used to keep a live renderer behind every hidden pane; now only what's on screen draws.",
        "Search results read as excerpts painted where the matcher hit, rather than a list of paths you have to open to understand.",
        "Add Host leads with the address, and a host password can be saved to the Keychain and handed to ssh when it asks.",
        "The editor lays the buffer out at its final line height from the first frame, and the Markdown Edit/Preview flip no longer rebuilds a face it already had.",
      ],
      fixed: [
        "A folder git doesn't track is no longer described as a clean working tree.",
        "ANSI white is readable on the light default theme.",
        "termio finds a device's agents where that device actually keeps them, honours the XDG bases on this Mac too, and never merges over a config you edited by hand. A reinstall replaces the device's own hooks instead of stacking beside them.",
        "Installing onto a device no longer freezes the Settings window while it works.",
        "Clicking a file tree row that's already selected reopens the file, and an ended session row drags and drops like a live one.",
      ],
    },
  },
  {
    version: "0.42.0",
    date: "2026-08-24",
    title: "Drag a session where you want it",
    changes: {
      new: [
        "Drag a session out of the sidebar and onto a pane to group it in beside what's already there. Every part of the pane is a live edge, so releasing anywhere picks a side rather than landing in a dead middle. A pane the session can't join declines the drag, and the pane already holding it dims.",
        "Inside the sidebar, where a dragged row lands decides what happens to it: the middle of a row groups the two sessions, the top or bottom edge reorders into that gap. A line means \"between these\", a lifted row means \"into this one\".",
        "`termio sessions spawn` and `run` take `--direction right|down` and `--ratio`, so a spawned session can say where it goes and how much of the split it takes. `--direction down --ratio 0.25` is a log strip.",
      ],
      improved: [
        "Splitting the same way twice now shares the space evenly — split right twice and the panes read as thirds, instead of a half and two quarters. Dividers you've dragged yourself stay where you put them, and the rest redistribute around them.",
        "A workspace comes back to the session you left it on, rather than whatever sorts first. The row carries its panes, its split group and its inspector tab with it, so returning to a scope puts your own work back on screen.",
      ],
      fixed: [
        "A prompt sent to a session now says when it was written but never received. An agent still on a startup gate — a hook-trust prompt, a first-run notice — takes typed text as the answer to its own question and shows nothing for it; the send used to report success anyway. `termio sessions list` flags the session until something else is delivered to it.",
        "The address that serves your phone retries with backoff when it can't come up, stays down once you suspend it, and no longer keeps minting fresh URLs it can't serve. Its failure messages are translated.",
        "A session started by the termio server no longer inherits signals the server happened to have ignored or blocked, which could leave ⌃C or ⌃Z doing nothing in that terminal.",
      ],
    },
  },
  {
    version: "0.41.4",
    date: "2026-08-24",
    title: "The terminal keeps the width of the window you're using",
    changes: {
      fixed: [
        "A terminal no longer draws at the wrong width — a narrow column of text in a wide, half-empty pane — after another device looked at the same session. Opening a session on your phone took the terminal's size with it, and the Mac had no way to take it back, so the pane stayed wrong until you dragged the window edge. The size now follows the device you're actually typing on, not the one that opened the session most recently.",
      ],
    },
  },
  {
    version: "0.41.3",
    date: "2026-08-23",
    title: "A session on another machine says what it's working on",
    changes: {
      fixed: [
        "A session running on another machine now follows what its agent is doing, the way a local one does — the row becomes the agent's name, then the topic it's working on. It used to sit on a fixed \"project · host\" label forever: the name termio composed for the row was kept in the same place a name you type goes, so nothing was ever allowed to replace it.",
        "Maximizing a file no longer flashes the file tree on the way there.",
      ],
    },
  },
  {
    version: "0.41.2",
    date: "2026-08-23",
    title: "A session that can't start says why",
    changes: {
      fixed: [
        "A session whose folder has been deleted, moved, or left on an unmounted drive now names the folder. It used to report that your shell didn't exist — the same error code covers both, and termio picked the wrong one to blame.",
        "Running the test suite from a checkout no longer overwrites the installed app's projects and sessions. This one only ever reached people who build termio themselves.",
      ],
    },
  },
  {
    version: "0.41.1",
    date: "2026-08-23",
    title: "The workspace name holds still",
    changes: {
      fixed: [
        "Switching workspaces no longer makes the name in the toolbar flick and shift. It was drawn at the width of whatever name it held, so every switch resized it and the toolbar re-flowed around it.",
      ],
    },
  },
  {
    version: "0.41.0",
    date: "2026-08-23",
    title: "Put a workspace on another machine",
    changes: {
      new: [
        "A workspace can live on a box you own — a VPS, or the Mac mini on the same desk — and termio sets up the session host there for you. It copies one binary into ~/.local/bin over SSH — no root, no package manager. A machine already running one is upgraded in place.",
        "Settings ▸ Workspaces: every workspace on one screen, with renaming and removing beside the one they act on. The switcher menu could only ever offer those for the workspace you were already in, which is why they read as \"Rename Workspace\" with no name in them.",
        "The phone groups projects by workspace, and each section names the machine that workspace is on. The roster used to arrive as one flat list, so a checkout on a VPS and one on this Mac looked the same.",
      ],
      improved: [
        "Settings ▸ Machines is now Settings ▸ Devices, the word the rest of the app already used.",
        "The dot on a remote row says whether the machine is answering: filled when it is, hollow while it is being reached, orange and struck through when it refused, with the machine's own words in the tooltip. It used to carry a colour that repeated down the whole column.",
        "Open Project opens on the machine the workspace belongs to, through a picker over that machine's own directories. ⌘O inside a workspace on a box used to file the folder under this Mac and throw you out of the scope you were in.",
        "Typing into a session takes back the right to write to it, instead of leaving the keystrokes refused until you reattach.",
        "Every session now runs through the same host, local or remote, so the two behave alike.",
      ],
      fixed: [
        "Reaching a machine no longer hangs when its key needs a passphrase and no agent is loaded. It fails and says so.",
        "Sessions on a VPS get a locale that machine actually has, so a TUI's box characters no longer arrive as mojibake.",
        "Pasting an image into a session running on another machine reaches that session instead of failing to find it.",
        "Removing a project ends the agents filed under it. They kept running with no row left that could reach them.",
        "A maximized file, diff or issue fills the window, rather than sitting under a toolbar with nothing left in it.",
        "The workspace name in the toolbar sits beside the sidebar button instead of adrift from it.",
      ],
    },
  },
  {
    version: "0.40.3",
    date: "2026-08-22",
    title: "A dev build no longer shares the session host",
    changes: {
      fixed: [
        "A second build of termio on the same Mac now keeps its own sessions. Both used one session host, so each was handed the other's entire list, showed every row of it under Also Running, and could close sessions the other was running. Sessions under a shipped termio are unaffected and keep running across the update.",
        "Rows under Also Running show the folder a session is running in, instead of the whole command it was started with. The command was the shell wrapper termio launches through, so the part worth reading was cut off the end; it's on the row's tooltip now.",
      ],
    },
  },
  {
    version: "0.40.2",
    date: "2026-08-22",
    title: "Also Running lists only what nothing is watching",
    changes: {
      new: [
        "Sessions under Also Running can be closed from the sidebar. Hover a row for its close button, or close the whole list from the section header — ending one used to mean opening it first.",
      ],
      improved: [
        "Rows under Also Running are named after the program they're running, instead of the identifier the session was created with.",
      ],
      fixed: [
        "Sessions belonging to another copy of termio on the same Mac no longer appear under Also Running. Both share one session host, so the second one to open was handed the first one's whole list and showed every row of it as a session nothing accounted for.",
      ],
    },
  },
  {
    version: "0.40.1",
    date: "2026-08-22",
    title: "The spinner stays on for the whole turn",
    changes: {
      fixed: [
        "An agent's spinner stopped about twelve seconds into a turn and never came back, so a session that was still working sat there looking idle. It now runs as long as the turn does.",
        "Sessions the daemon hosts read their status from the same signals a local one does. They had only the window title to go on, so a turn that started without a hook went unseen.",
        "Agent status no longer goes quiet for good when another build of termio is launched beside the app. Two of them share the machine now, and one that lost the status channel takes it back on its own.",
        "Claude Code's newer spinner counts as working. It changed shape in 2.1.228, and termio still recognized only the old one.",
      ],
    },
  },
  {
    version: "0.40.0",
    date: "2026-08-21",
    title: "All four Catppuccin flavors",
    changes: {
      new: [
        "Frappé and Macchiato join Latte and Mocha, so the flavor you pick a Catppuccin theme by is the one you find in the picker. Sixty-nine themes are built in now, forty-seven dark and twenty-two light.",
      ],
      improved: [
        "The terminal core moves up to a newer ghostty. Tab stops clear properly when unset, a full reset clears the progress bar and the cursor along with it, and the terminal now answers in-band size reports.",
      ],
      fixed: [
        "Sessions the remote daemon starts keep their transcript again. A daemon launched from inside a Claude Code session handed that session's identity to everything it spawned afterwards, and Claude Code read it as a sign it was a sub-session and stopped writing history.",
      ],
    },
  },
  {
    version: "0.39.0",
    date: "2026-08-21",
    title: "Seventeen more themes",
    changes: {
      new: [
        "Sixty-seven themes are built in, up from fifty. Homebrew and IR Black bring the old Terminal.app look, Ocean has a real blue background, and Zenburn opens a run of neutral greys — Espresso, Miasma, Arthur and traffic — that the list had none of. Shades Of Purple and Blue Matrix fill out the dark end.",
        "The light themes widen too: Coffee Theme, Novel and Belafonte Day for anyone who would rather not stare at white, plus Horizon Bright, Material, Neobones Light and Nvim Light. Nothing was taken away — the themes you already had are all still there.",
      ],
    },
  },
  {
    version: "0.38.0",
    date: "2026-08-21",
    title: "Workspace shortcuts",
    changes: {
      new: [
        "⌘1 through ⌘9 switch workspaces. Each shortcut sits beside its workspace in the sidebar's workspace menu, so you can read it rather than remember it.",
      ],
      improved: [
        "The workspace name in the toolbar stands on its own, larger and without an icon or chevron crowding it.",
        "The sidebar and inspector buttons match each other. The sidebar button no longer carries a background of its own.",
      ],
    },
  },
  {
    version: "0.37.0",
    date: "2026-08-21",
    title: "Workspaces",
    changes: {
      new: [
        "Workspaces: the sidebar shows one workspace at a time instead of everything at once, and you switch from the toolbar. Everything you already had becomes your first workspace on launch — no projects move, no sessions are lost.",
        "Fifty curated themes are built in. Pick one in Settings ▸ Appearance and it applies; the Themes folder goes back to holding only what you put there.",
        "Droid, Copilot, Cline, Crush and Qwen Code join the built-in agent roster.",
        "Git compares a branch against the one it would merge into, so you can see what a pull request would contain.",
      ],
      improved: [
        "Settings ▸ SSH is now Settings ▸ Machines: the hosts from your ~/.ssh/config, each one a click from a connection test or a terminal.",
        "A Codex session names itself from your first prompt, the way the other agents do.",
        "A loose terminal titles the window with its own directory.",
        "`termio sessions send --key` presses a named key, instead of only sending a line of text.",
      ],
      fixed: [
        "Open Project and New Workspace stay clickable in the sidebar's + menu once a second machine is configured.",
        "The workspace switcher leaves the toolbar with the sidebar, instead of sitting beside the window title.",
        "The file editor shows a file even when syntax highlighting cannot start.",
        "Background blur is ignored at full opacity, where it had nothing to blur.",
        "The Issues list rebuilds when you change its kind or filter.",
        "Notifications are gated on Termio's own bundle rather than any bundle.",
        "Markdown with a Mermaid diagram no longer flashes a stray window.",
      ],
    },
  },
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
