---
title: "From IDE to ADE: Sixty Years of Development Environments, and Why the Era Is Ending"
status: archived
type: essay
created: 2026-07-11
updated: 2026-07-24
description: For sixty years, every generation of development environment has killed the slowest link in the loop between human intent and machine state. The bottleneck has finally moved to us — and that changes what programming means.
---

On July 8, 2026, InfoWorld ran a piece with a blunt headline: **"The IDE is dead, long live the ADE."** Nick Hodges's argument: the integrated development environment, after forty years of ruling software development, is becoming a tool developers reach for less and less.

It sounds like clickbait. But lay out sixty years of IDE history and you'll see this isn't an accident — it's the sixth rerun of the same law. The law fits in two sentences:

**Every generation of development environment kills the slowest link in the loop of its time. And every time the bottleneck moves, the entire tooling industry gets reshuffled.**

History first. Once you've seen it, you'll recognize that what's happening now is following the script almost line by line.

## Sixty Years, Five Migrations

### 1950s–60s: Code Lived Far From the Machine

Before the phrase "development environment" existed, programming was physical labor. You wrote code by hand on coding sheets, a keypunch operator turned it into a stack of cards, you handed the stack to the machine room, and you waited — hours, sometimes a day — for a printout that might contain a single compile error.

![A FORTRAN punch card](https://upload.wikimedia.org/wikipedia/commons/5/58/FortranCardPROJ039.agr.jpg)
*A FORTRAN program punch card. One line of code, one card. (Arnold Reinhold, Wikimedia Commons, CC BY-SA)*

The slowest link: **the feedback cycle**. Between writing code and seeing the result stood an entire bureaucracy.

### 1964: Dartmouth BASIC, and Sitting Down at a Terminal for the First Time

Dartmouth's time-sharing system and the BASIC language put the language, the editor, and the execution environment inside one system for the first time. Programmers sat down at a "terminal," wrote code, and ran it — even if that terminal was a clattering teletype. The feedback cycle collapsed from a day to seconds.

![An ASR-33 teletype](https://upload.wikimedia.org/wikipedia/commons/d/df/ASR-33_at_CHM.agr.jpg)
*The Teletype ASR-33, the standard "display" of the time-sharing era. (Computer History Museum; photo by Arnold Reinhold, CC BY-SA)*

### 1975: Maestro I, the First Commercial IDE

The first IDE ever sold as a product came not from Silicon Valley but from Munich. Softlab's **Maestro I** gave minicomputers a dedicated programming workstation, eventually serving 22,000 programmers worldwide. "A machine built just for programming" was a radical idea then — and the first proof that **the development environment is itself a business.**

![The Maestro I keyboard](https://upload.wikimedia.org/wikipedia/commons/c/cc/Maestro-I-Keyboard.JPG)
*The Maestro I's dedicated keyboard. (Wikimedia Commons, CC BY-SA 4.0)*

### 1983: Turbo Pascal, the $49.95 Revolution

Borland packed an editor and a compiler into one program, on a personal computer, compiling in seconds — for $49.95, when comparable tools cost hundreds or thousands. "Change a line, hit F9, see the result two seconds later" redefined the rhythm of programming. The slowest link had shifted from "waiting for the machine" to "switching between edit, compile, and run"; Borland killed it, and swallowed the developer-tools market of its decade along the way.

![The Turbo Pascal 6 interface](https://upload.wikimedia.org/wikipedia/commons/8/84/Turbopascal_6.png)
*Turbo Pascal's character-mode IDE: edit, compile, run, debug — on one screen for the first time. (Wikimedia Commons)*

### 1991–2001: The Golden Age of the Enterprise IDE

In this decade the IDE went from tool to industry, and four names each claimed a milestone.

**1991, Visual Basic**: it stitched a GUI builder to code — drag a control, double-click, write the event handler — and an entire generation of business software was born. "Visual programming" carried millions of people over the threshold into programming.

![Visual Basic 6.0](https://upload.wikimedia.org/wikipedia/en/0/0e/Visual_Basic_6.0_on_Windows_XP.png)
*Visual Basic 6.0: toolbox on the left, form designer in the middle, double-click to write an event handler — the birthplace of countless internal enterprise systems. (Wikipedia, fair use)*

**1997, Visual Studio**: Microsoft gathered every language and tool under one roof, then ruled Windows development for twenty years. The development environment stopped being a product and became a platform strategy.

![Visual Studio .NET](https://upload.wikimedia.org/wikipedia/en/f/f2/Visual_Studio_.NET_2002_EN.png)
*Visual Studio .NET (2002) — citable screenshots of the original VS 97 are nearly extinct; this is its closest descendant. The trinity of solution tree, properties panel, and designer took its final shape here. (Wikipedia, fair use)*

**2001, Eclipse**: funded by IBM and then open-sourced, the first open-source IDE to beat commercial products head-on; its plugin architecture became the template for every "platform IDE" since.

![Eclipse's Java development view](https://upload.wikimedia.org/wikipedia/commons/e/e3/Eclipse_Java_Development_GTK.png)
*Eclipse's classic anatomy: project tree, editor, Outline, Problems panel. (Wikimedia Commons, EPL)*

**2001, IntelliJ IDEA**: JetBrains turned "treat code as a syntax tree, not text" into a creed — refactoring, semantic completion, intention detection. The gold standard for language-level intelligence has carried the letter J ever since.

![IntelliJ IDEA](https://upload.wikimedia.org/wikipedia/commons/8/89/IntelliJ_IDEA_14.1.3.png)
*IntelliJ IDEA: the definitive work of deep semantic understanding, and the foundation under Android Studio and a whole family of IDEs. (Wikimedia Commons)*

The slowest link of this decade was **the human cost of comprehending a large codebase** — when a project grows from one file to ten thousand, the IDE remembers the structure for you. Microsoft collected rent on that for twenty years.

### 2015: VS Code and LSP — the Editor Becomes a Platform

Microsoft shipped VS Code and, with it, defined the **Language Server Protocol**: language intelligence peeled out of the IDE into a separate process and an open protocol. The N-editors × M-languages compatibility matrix collapsed into N + M. The IDE went from monolith to light kernel plus ecosystem.

![An early version of VS Code](https://upload.wikimedia.org/wikipedia/commons/8/80/Visual_Studio_Code_0.10.1_on_Windows_7%2C_with_search.png)
*VS Code 0.10.1 in 2015 — the editor that would rule the next decade, as it first looked. (Wikimedia Commons, MIT)*

VS Code was free, and it ended the paid-IDE business. Here, for the first time, the industry's hidden thread became visible: **the tool itself keeps getting cheaper; what's valuable is where it stands.** Whoever stands between the developer and the code defines the next decade. Copilot growing out of exactly that spot ten years later was not a coincidence.

## AI Moves Into the IDE (2021–2024)

In 2021, GitHub Copilot pushed completion from the syntax level to the intent level. In 2023, Cursor simply forked VS Code and put a conversation — and then an agent — inside the editor. What followed is rare even by software-history standards:

![Cursor](https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/og/opengraph-default.png)
*Cursor: the biggest winner of the AI-IDE era. (Image: Cursor)*

Cursor's ARR went from $100M in January 2025 to $4B by June 2026 — 40x in eighteen months, among the fastest in B2B software history. It raised at a $29.3B valuation in November 2025, and in June 2026 SpaceX acquired it in an all-stock deal at **$60 billion**. A forked editor. Three years. Sixty billion dollars.

The same period produced a counterexample: **Windsurf**. OpenAI's $3B acquisition collapsed mid-2025, Google carried off the core team in a licensing deal, and by December what remained sold to Cognition for roughly $250M. Six months, ninety percent of the value gone.

Same category — why does one fetch $60B and the other $250M? Because a fault line was cracking open underground, and the two companies happened to stand on opposite sides of it. The fault line is the next section.

## Agents Leave the Editor (2025–2026)

In February 2025, Anthropic released Claude Code — not a plugin, not an editor, but an agent that runs in **the terminal**. Then came the steepest growth curve in the history of developer tools:

![Claude Code](https://cdn.sanity.io/images/4zrzovbb/claude-com/6c36adaaf60ecdde313a93ad255eef573ea4de97-1200x630.jpg?w=1200&h=630&fit=crop)
*Claude Code: it runs in the terminal, not in an editor. (Image: Anthropic)*

Annualized revenue: $500M in September 2025, $1B by November, $2.5B by February 2026, roughly **$8B by May**. The average developer uses it 20 hours a week. SemiAnalysis estimates the share of public commits it authors went from 4% at the start of 2026 to a projected 20%+ by year's end. In the Pragmatic Engineer survey of 15,000 developers, 73% of teams use AI coding tools daily, and Claude Code was voted "most loved" at 46%. OpenAI's Codex CLI and Google's Gemini CLI followed — **every one of the strongest agents was born in the terminal. Not one was born in an IDE.**

The numbers aren't the point; the change of form is. An agent is no longer a prompt-response answering machine — it's a unit of work that runs for tens of minutes, reads the code, runs the tests, fixes its own errors. And with that, every core assumption of the IDE fails at once. It assumes one person at one cursor; the reality is one person with N agents in parallel. It assumes the core action is typing; the reality is delegating, reviewing, arbitrating. It assumes one workspace on one branch; the reality is every agent squatting on its own worktree. Its entire interface is optimized for reading and writing code — when what you actually need to see, at a glance, is who's running, who's idle, and who has been stuck on a confirmation prompt waiting forty minutes for you.

That's where Windsurf lost: it bet everything on "editor + AI," and when the fault line opened, the editor was on the wrong side.

## The Land Grab Has Begun

"Humans directing fleets of agents" needs a new environment. In the past twelve months, nearly every kind of player has turned in an answer.

**Warp → Oz** (February 2026): the terminal vendor moving up into orchestration — local agents plus cloud agents in reproducible Docker environments; named to TIME's Best Inventions. This is the bottom-up route.

![Warp](https://www.warp.dev/og/default.png)
*Warp: from "a better terminal" to an Agentic Development Environment. (Image: Warp)*

**JetBrains → Air**: the IDE giant's self-revolution, officially described — verbatim — as an "agentic development environment": delegate tasks to parallel agents, accept the results through IDE-grade review. When a company that has sold IDEs for twenty-five years starts naming the new category, the category exists.

**GitKraken → Kepler**: the Git-tooling vendor entering multi-agent orchestration from the branch-management side. CEO Matt Johnston's line could be this essay's epigraph:

> "The IDE was built for the age of one human typing. The ADE is built for the age of humans orchestrating fleets of agents."

![GitKraken Kepler](https://www.gitkraken.com/wp-content/uploads/2026/06/ADE_product_OG-1024x538.png)
*GitKraken Kepler: the official OG image has "ADE" printed right on it. (Image: GitKraken)*

**Conductor** (Melty Labs): a native Mac app running parallel Claude Code and Codex agents, one isolated git worktree each. Free product, bring your own subscription — the classic "claim the workflow now, monetize later" play.

![Conductor](https://www.conductor.build/opengraph-image?f984893ec97162f4)
*Conductor: a team of coding agents running in parallel on a Mac. (Image: Conductor)*

**herdr**: an open-source, agent-aware terminal multiplexer — "tmux for agents" — with 15k+ GitHub stars, persistent workspaces, and agent status detection. The open-source community voting with its feet that the need is real; but it covers only the terminal side.

![herdr](https://opengraph.githubassets.com/1/ogulcancelik/herdr)
*herdr: one terminal for the whole herd. (Image: GitHub)*

**vibe-kanban** (Bloop): a kanban board for agents — drag a card to In Progress and an agent picks it up on its own branch. Apache-licensed, huge community — and then, in **April 2026, it shut down**, handing the code to volunteers.

![vibe-kanban](https://vibekanban.com/images/cta-product-desktop.webp)
*vibe-kanban: the category's first casualty — its lesson worth more than most successes. (Image: vibe-kanban)*

The death of vibe-kanban deserves a second look. It proved the demand is real, and it proved two roads are closed: the pure "board" abstraction is too thin — an agent's real interface is the terminal and the diff, not a card — and a free, open-source orchestration tool can't sustain the investment the problem demands. Which means the category's correct shape has been defined by elimination: **you must own the runtime itself (the terminal), not just a scheduling view on top of it; and you must be a business from day one.** Softlab understood both in 1975. Borland understood both in 1983.

## The Slowest Link

Now the sixty years fold into a single model.

Strip away the product names and the essence of a development environment is one sentence: **it is a loop between human intent and machine state.** Programming is the continuous act of pushing intent into the machine and reading the machine's true state back into your head. Every generational change in sixty years has been the same move — find the slowest link in the loop and kill it. The machine-room queue was slow; time-sharing killed it. Compilation was slow; Turbo Pascal killed it. Ten thousand files wouldn't fit in a human head; Eclipse and IntelliJ killed that. A fragmented ecosystem slowed everything; LSP killed it. Each kill moves "slowest" down the chain.

In 2026 it reached the end of the chain. Typing is no longer slow — agents write the code. Compilation isn't slow. Navigation isn't slow. For the first time, the slowest link in the loop is **the human**: how many parallel agents can you actually supervise? And this bottleneck differs from every one before it in a fundamental way — it cannot be killed. Agents will get more numerous, faster, cheaper; human attention will never gain a minute. Every previous environment eliminated its bottleneck. This generation's environment can only do one thing: **serve it well.**

So what's really changing isn't the tooling — it's what the word "programming" means. For sixty years the core act was translating ideas into code, and the environment's whole mission was making translation faster. Now translation itself has been outsourced, and what's left to the human is something older, something never automated: **judgment**. What's worth building. What counts as correct. Which approach deserves to die. People no longer write code; people sign off on code. The center of the development environment has moved from the editor to the diff.

The form of the tool merely follows that logic. Agents being born in the terminal isn't nostalgia; it's physics. An agent's body is processes and the filesystem. The terminal composes, runs headless, and travels through any tunnel; GUIs were designed for human hands, pipes were designed for programs — and an agent is a program. So building an environment for agents doesn't mean bolting a plugin onto an IDE. It means reinventing the terminal — except this time, the person on the other side of the screen isn't the one typing. It's the one **signing off**.

The vocabulary changes with it. The last generation's nouns were file, buffer, project. This generation's are session — an agent process forty minutes into its run; worktree — each agent's own parallel universe; and the question that matters most: "**who is waiting on me?**" Whoever first turns those words into developers' muscle memory becomes this generation's VS Code.

Even the protocol layer is rerunning the script. LSP abstracted language intelligence into a protocol and collapsed N×M into N+M; today MCP is doing it for tools and ACP for agent-environment communication — the identical move. And LSP's lesson is still warm: the protocol earns nothing; everything grows where the protocol lands.

The money is just a shadow of all of the above. Cursor's $60B bought not an editor but the position it might hold. Windsurf's $250M punished not bad technology but the wrong side of a fault line. Claude Code's $8B is a reminder that the agent itself becomes the model vendor's giveaway — model companies hand out agents the way carriers once handed out phones, and you can't build a business on the giveaway; the business lives where the giveaway runs. The model vendors can see that place too, but there's one thing they constitutionally cannot be: neutral. Developers already run Claude Code, Codex, and Gemini CLI side by side — and Anthropic's environment will never treat Codex well, just as Google was never going to build a great iPhone launcher.

A shift like this comes once or twice in an engineer's career. The last one was 2015. The one before that was 1983.

## Epilogue: The Environment That Watches

The vehicle of this revolution, ironically, is the thing the IDE spent forty years replacing — the terminal. Agents are born in the terminal, and the ADE's natural form is a terminal reinvented for directing them.

This is why we build [Termio](https://termio.sh): a native macOS terminal for agents — multiple CLI agents running in parallel, a menu-bar glance telling you who's working and who's waiting on your call, and your phone taking over supervision when you step away from the desk. Not an AI plugin for an editor, not a scheduling dashboard in the cloud: own the runtime, stand neutral, and make one thing — a human supervising a fleet of agents — into muscle memory.

In the punch-card era, the environment queued for you. In the time-sharing era, it waited for you. In the Turbo era, it compiled for you. In the Eclipse era, it remembered for you. In the VS Code era, it connected for you.

In the agent era, the environment **watches** for you.

---

## References

### History

- [Integrated development environment — Wikipedia](https://en.wikipedia.org/wiki/Integrated_development_environment)
- [The evolution to integrated development environments (IDE) — Computerworld](https://www.computerworld.com/article/1341391/the-evolution-to-integrated-development-environments-ide.html)
- [A Bird's View on Language Servers — itemis](https://blogs.itemis.com/en/a-birds-view-on-language-servers) · [LSP — Eclipse Foundation](https://www.eclipse.org/community/eclipse_newsletter/2017/may/article1.php)

### The ADE Thesis

- [The IDE is dead, long live the ADE — Nick Hodges, InfoWorld, 2026-07-08](https://www.infoworld.com/article/4193975/the-ide-is-dead-long-live-the-ade.html)
- [What Is an Agentic Development Environment? — Augment Code](https://www.augmentcode.com/guides/what-is-an-agentic-development-environment)
- [Is the IDE Dead? — Coder](https://coder.com/blog/is-the-ide-dead-the-rise-of-agentic-ai-in-software-development)
- [2026 Agentic Coding Trends Report — Anthropic](https://resources.anthropic.com/hubfs/2026%20Agentic%20Coding%20Trends%20Report.pdf)

### Market

- [Cursor $2B ARR & valuation — TNW](https://thenextweb.com/news/cursor-anysphere-2-billion-funding-50-billion-valuation-ai-coding) · [Cursor (company) — Wikipedia](https://en.wikipedia.org/wiki/Cursor_(company)) · [SpaceX × Cursor $60B — Digital Applied](https://www.digitalapplied.com/blog/spacex-acquires-cursor-anysphere-60b-ai-coding-2026)
- [Claude Code usage statistics — SerpSculpt](https://serpsculpt.com/claude-code-usage-statistics/) · [Anthropic $30B run rate — VentureBeat](https://venturebeat.com/technology/anthropic-says-it-hit-a-30-billion-revenue-run-rate-after-crazy-80x-growth)

### The Field

- [Warp ADE — TIME Best Inventions 2025](https://time.com/collections/best-inventions-2025/7318249/warp-agentic-development-environment/) · [JetBrains Air](https://rywalker.com/research/air-jetbrains) · [Conductor](https://www.conductor.build/) · [herdr](https://herdr.dev/) · [vibe-kanban — GitHub](https://github.com/BloopAI/vibe-kanban)

**Image credits**: historical images from [Wikimedia Commons](https://commons.wikimedia.org/) (CC BY-SA / EPL / MIT, per captions); the Visual Basic 6.0 and Visual Studio .NET screenshots are fair-use material from English Wikipedia; recent product images are the companies' own public OG/press assets, quoted for commentary with attribution.
