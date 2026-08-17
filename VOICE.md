# VOICE.md

How termio writes. Read this before writing anything a user reads: UI strings,
the landing site, `docs/`, release notes, issues, PR bodies.

## Where these rules come from

**Not from termio's own copy.** Most strings in this repo were written with AI
assistance. Mining them for examples would make this file a mirror — it would
teach the next writer to reproduce whatever is already here, including the
mistakes. That is the failure mode named below as *regression to the mean*, and
a style guide is the worst place to commit it.

The examples here come from two outside sources:

- **UI copy** — Apple's shipped strings, extracted from this Mac's System
  Settings panes. Quoted verbatim and marked *(Apple)*. When you need to know
  how a control should read, open the pane that does the same job and read it.
- **Prose** — the rules in tldraw's `VOICE.md`, an open, human-written guide by
  a team that ships developer documentation for a living.

termio's existing strings are the **backlog**, not the standard. When a shipped
string and this file disagree, the string is the bug. Run the `review-copy`
skill over a file rather than assuming what is there is right.

`AGENTS.md` carries the few rules an agent must not get wrong even if it never
opens this file. This is the long form.

## The voice in one line

**A colleague who built the thing, telling you what it does and what it costs
you.** Not a manual, not a pitch.

| We are | We are not |
| --- | --- |
| Direct — the sentence states the fact and stops | Not chatty; no warm-up clauses |
| Concrete — names the file, the flag, the key | Not abstract; no "seamlessly", "powerful" |
| Honest — says what a control won't do | Not promotional; no overclaiming |
| Plain — ordinary words, full names | Not clever; no puns in UI, no jargon for its own sake |

The reader's time is the scarce resource. Say the thing, then stop.

## UI copy

termio's largest writing surface. Apple already solved most of it; the job is
to match their register, not to invent one.

### Read how Apple writes the same control

Before writing a subtext, find the System Settings pane that does something
similar and read it. These are real strings from macOS:

> Known networks will be joined automatically. If no known networks are available, you will be asked before joining a new network. *(Apple, Network)*

> Extensions add extra functionality to your Mac and apps, and some may run in the background. *(Apple, Login Items)*

> Allow the applications below to access the contents of your screen and audio through Remote Desktop, even while using other applications. *(Apple, Privacy & Security)*

> Applications that have requested access to your contacts will appear here. *(Apple, Privacy & Security)*

> This will permanently delete it from all your devices. *(Apple, Accessibility)*

Three things to notice, because each contradicts what a language model will
produce by default:

**Apple addresses the user directly.** "your Mac", "your contacts", "you will
be asked". There is no rule that the control must be the grammatical subject.
Write whichever subject makes the sentence clearest.

**Apple uses passive voice when the actor doesn't matter.** "Known networks
will be joined automatically." "Authentication is required to save the VNC
password." Prefer active, but don't contort a sentence to avoid passive when
the actor is the system and nobody cares which part of it.

**Apple's subtexts are not short.** Several run past 140 characters and carry
two clauses. Length is not the enemy; unearned words are. One idea per
sentence, however long that sentence needs to be.

### The second sentence answers "what happens to my stuff?"

When a control has a consequence, name it. This is where honesty lives.

> This will permanently delete it from all your devices. *(Apple)*

> Turning off "Share across devices" will also prevent this Mac from sharing your Focus status. *(Apple)*

Two sentences is the ceiling. A control needing three is a control that needs
redesigning, not more prose.

### Empty states name the next action

An empty state is the one moment the user is actively looking for a way
forward. Don't spend it saying "nothing here".

> Select a command or click Add (+) to create a new command. *(Apple)*

**Don't:** "No hosts found." · "There is no data to display at this time."

### Errors say what happened, then what to do

Name what failed in the user's terms. If there is an action, give it in the
same breath. Never blame the user, never apologize, never use an emoji.

> Remote Management is not installed on this computer. *(Apple)*

> Internet Sharing is not installed on this computer. To install Internet Sharing, install the BSD packages using the macOS Installer. *(Apple)*

> Your organization's device management settings do not recommend beta updates on this device. *(Apple)*

Use `Couldn't`, not `Could not` — Apple contracts, and it is shorter. Use the
curly apostrophe, consistently.

### Buttons and menu items are verbs

The label says what happens when you click it. No trailing punctuation.

**Do:** `Show Original` · `Group with` · `Ungroup` · `Close Session` ·
`Remove from List` · `Reveal in Finder`

**Don't:** `OK` on a destructive action · `Submit` · `Click here` ·
`Are you sure?` as a button

Destructive labels name the destruction: "Delete", "Remove from List", never
"Yes".

### Fixed vocabulary

Decided. A synonym is a bug, not a style choice.

| Use | Never |
| --- | --- |
| Group with / Ungroup | Split / Unsplit |
| Close Session | Close Pane |
| session | tab, window (for a session) |
| project | workspace, folder (in the sidebar) |
| agent | assistant, bot, AI |
| needs you | blocked, waiting for input (as a status label) |

**Termio** in prose, `termio` on the command line. The brand is capitalized
wherever it names the product in a sentence. It stays lowercase wherever it is a
literal someone types or the system reads: the `termio` CLI and its subcommands,
`sh.termio.app`, `~/.termio`, `TERMIO_SESSION`, termio.sh, and the skill's own
`name: termio`. Never `TermIO`.

The landing site, the README, the UI strings, and the `termio` skill follow this.
The design docs under `docs/` still use lowercase in prose — backlog, not a
second standard.

### Never describe termio as paid

termio is free. No tier, no trial, no seat, no license key. Copy implying
otherwise is wrong everywhere — UI, landing site, README, release notes,
replies to users. The words that give it away: "upgrade", "unlock", "pro",
"premium", "free for now".

## Prose: docs, landing, GitHub

### Pronouns

- **"you"** for the reader: "You can drag a session onto another to group them."
- **"termio"** or **"the app"** for the software: "termio reads each agent's
  hooks." Not "we read" — that conflates the software with the person writing.
- **"we"** only in docs and essays where a person is genuinely speaking:
  "We tried a chat lens twice and reverted it both times."
- Never first-person singular. Never "It is recommended that…".

### Rhythm

Vary sentence length. AI defaults to uniform sentences and uniform paragraphs;
that uniformity is itself a tell, independent of any individual word.

**Don't:**

> The store holds session state. The sidebar renders the tree. The watcher
> reloads changed directories. The surface cache keeps shells alive.

**Do:**

> `TermioStore` owns the session tree. The sidebar renders it, the watcher
> reloads directories that actually changed, and a surface cache keeps each
> shell alive across view rebuilds — which is why switching sessions doesn't
> restart your agent.

### The landing site

Same voice, volume up. It may lead with a claim; it may not make one it can't
cash. The pattern is **claim, then the evidence, in the same breath**:

> A real terminal, not a web view. Swift + AppKit on libghostty, rendered with
> Metal. No Electron, no xterm.js.

Claims must match what the code does. A capability that is planned, partial, or
only true on the dev channel is described as such or not at all.

### docs/

Written for whoever maintains this in a year — often you, often an agent.
Front matter carries the status; the prose carries the reasoning.

- Open by saying what the document decides or describes. Never "This document
  aims to…".
- Record **why**, and record what was rejected and why. A design doc with an
  empty alternatives section hasn't done its job.
- Wrong past decisions stay written down, marked. The record is the point.
- Design docs may be long. Runbooks may not — a runbook is a command list with
  just enough prose to say when to run it.

### GitHub

- **Commits** follow Conventional Commits; use the `conventional-commit` skill.
- **PR titles** are imperative, correctly capitalized, no conventional-commit
  prefix, no trailing punctuation.
- **PR bodies** are for a reviewer who knows the architecture but hasn't read
  the diff. What changes for the user, then how, then what you verified.
  Include a `Release Notes:` section.
- **Issue and PR comments are one clean line.** Not an essay with headers.
- **No AI attribution anywhere** — no `Co-Authored-By`, no "Generated with", no
  bot signature, in commits, PRs, issues, docs, or release notes.

## Tells that mean a machine wrote it

Ordered by how often they actually show up.

### Trailing gerunds

The most common pattern, and the one to hunt hardest. A comma followed by an
`-ing` word near the end of a sentence is the signal.

Hollow ones are obvious: "…, ensuring a seamless experience", "…, highlighting
the importance of X". **Neutral ones are just as bad** — they bury the point at
the end and flatten the rhythm:

"…, allowing you to X" · "…, enabling users to X" · "…, making it easy to X" ·
"…, giving you X" · "…, providing X" · "…, resulting in X"

**Don't:** "The store is reactive, allowing you to subscribe to changes."

**Do:** "The store is reactive. You can subscribe to changes."

The fix is always the same: split into two sentences, or restructure so the
important part comes first.

### Regression to the mean

AI replaces specific, unusual facts with generic positive-sounding language,
because that is what the average of its training data looks like. This is the
tell that matters most, because the result reads fine and says nothing.

**Don't:** "The inspector is a powerful and versatile pane that helps you
review your agents' work efficiently."

**Do:** "The inspector shows changes, a file tree, and the session's transcript.
The git pane is read-only — you commit in the terminal."

If you don't know the specific, look it up or drop the claim. A vague
importance claim adds nothing.

### Hollow importance

"plays a crucial role", "is a key component of", "underscores the importance
of", "represents a significant step". Say what it does instead.

### Formulaic transitions

"Moreover", "Furthermore", "Additionally", "It's important to note that",
"In today's fast-paced world". Usually deleting them makes the sentence
stronger. If you need a transition, use a short one: "But", "And", "Also".

### The rule of three

Real lists have two items, or four, or seven. Exactly three adjectives is a
pattern, not an observation.

**Don't:** "fast, reliable, and intuitive" — **Do:** pick the true one.

### Promotional adjectives

"powerful", "seamless", "robust", "comprehensive", "cutting-edge",
"game-changing", "empowers you to", "unlock the full potential of". None
survive review.

### Negation parallelism

"It's not just a terminal — it's a home for agents." Say what it is.

### Bolded pseudo-headers in a list

A bullet opening with a bold phrase and a colon, repeated down a list, is a
table pretending to be prose. Fine in reference material where scanning beats
flow; wrong in prose. If the items are genuinely parallel, use a table.

### Em dash overuse

One per paragraph, for a real aside. Two unpaired dashes in one sentence means
rewrite.

### Emoji

None in copy, anywhere — UI strings, commits, PRs, issues, docs, release notes.

This is a rule about tone, not about glyphs. An emoji standing in for a missing
asset is an *icon* question, and termio answers those with Hugeicons — see the
two `🖼` image placeholders in `MarkdownHTML.swift` and
`SessionTraceRenderer.swift`, which are inconsistent with the icon set rather
than with this guide. Don't read that distinction as a loophole: an emoji in a
sentence, a label, or a commit message is always wrong.

## Mechanics

- **Sentence case** for descriptive sentences, headings, PR titles, and doc
  titles. **Title Case** for the names of features, panes, and menu items —
  Apple writes "Users & Groups", "Internet Sharing", "Remote Management", and
  termio writes "Group with", "Close Session", "Reveal in Finder".
- **Curly quotes and apostrophes** in user-facing strings. Straight quotes only
  inside code, paths, and identifiers.
- **Backticks** in UI copy for literal commands, flags, and paths the user could
  type: `--agent`, `~/.ssh/config`, `termio sessions`.
- **Contractions** are preferred: "won't", "doesn't", "couldn't".
- **Numerals** in UI: "2 sessions", not "two sessions".
- **No trailing periods** on labels, buttons, or table cells. Full sentences in
  subtexts and errors take one.

## Checklist

- [ ] **Trailing gerunds** — any comma + `-ing` near a sentence end?
- [ ] **Specific** — does every claim name a file, flag, key, or observable
      behavior, or has a specific been smoothed into a generic?
- [ ] **One idea per sentence** — regardless of length
- [ ] **Honest** — does it say what the control won't do, or what it costs?
- [ ] **Next action** — do empty states and errors tell the user what to do?
- [ ] **Rhythm** — do the sentences vary in length, or all run the same?
- [ ] **Vocabulary** — Group with / Ungroup / Close Session / session / project
      / agent, `Termio` in prose and `termio` in commands?
- [ ] **Case** — sentence case for sentences, Title Case for feature names?
- [ ] **Apostrophes** — curly, and `Couldn't` over `Could not`?
- [ ] **Never paid** — no upgrade, unlock, pro, trial, or tier?
- [ ] **No AI tells** — hollow importance, rule of three, promotional
      adjectives, negation parallelism, emoji?
- [ ] **No AI attribution** — no co-author trailer, no "generated with"?

The `review-copy` skill runs this as a scored loop; see `skills/review-copy/`.
