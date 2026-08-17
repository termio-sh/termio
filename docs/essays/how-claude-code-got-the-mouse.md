---
title: "How Claude Code Got the Mouse: Reverse-Engineering the Clickable Terminal"
status: draft
type: essay
created: 2026-08-03
updated: 2026-08-10
description: Claude Code's fullscreen mode quietly gave the terminal a working mouse — click-to-position, clickable menus, hover states, drag selection. A dig through the shipped binary reveals a five-layer architecture that any code agent could adopt.
---

# How Claude Code Got the Mouse

> A reverse-engineering dig through Claude Code's fullscreen-mode mouse support, written for the people building the other agent TUIs. Everything here was recovered from the publicly shipped binary and a pseudo-terminal probe; inferences are labeled.

The other day I clicked into the middle of a half-typed prompt in Claude Code — the way you'd click into any text field, without thinking — and the cursor *moved there*.

That's not supposed to happen. Terminal input runs through a line editor owned by the child process; the mouse belongs to the host terminal, and clicking a TUI's input box normally does nothing. If you grew up on terminals, your hands know this the way they know Ctrl+C. Every mainstream agent CLI — Claude Code, Codex, Gemini CLI — has been a keyboard-only UI for its entire life. And yet: click, cursor moves. Click a collapsed tool result, it expands. Click "Yes" on a permission prompt. Hover over things and they light up. Drag to select text inside the TUI and it lands on your clipboard.

Here's the part that got me: I went to the changelog to find out when this shipped, and **the sentence "Added mouse support" does not exist in it**. The biggest interaction change a terminal agent has ever shipped was never announced. (The community found it anyway — the most-viewed post about the feature, a 200k-view demo from April, teaches an env var that wasn't documented at the time.)

So I had two questions. How does it work? And why is the paper trail so strange? I build a terminal that hosts these agents, so I had a selfish third: is my side of the pipe doing its job?

## Probe one: what does it ask the terminal for?

You don't need the source to see what a program negotiates with its terminal — spawn it under a pseudo-terminal and log the bytes. Within a second of startup, `claude` emits:

| Sequence | Meaning |
|---|---|
| `CSI ?1049h` | Alternate screen — the fullscreen renderer's canvas |
| `CSI ?1000h` | Report mouse clicks |
| `CSI ?1002h` | Report drags |
| `CSI ?1003h` | Report **all motion** — this is what powers hover |
| `CSI ?1006h` | SGR encoding — coordinates past column 223, distinct press/release |
| `CSI ?2004h` | Bracketed paste |

That's the entire mouse ladder, including the firehose (1003 means the app hears about every pointer movement, not just clicks). From this moment the host terminal streams events as escape sequences on stdin:

```
  ESC [ <   0   ;   34   ;   12   M
        │       │        │        │
        │    column     row       └── M = press, m = release
        │
        └── button: 0=left  2=right  64=wheel-up  65=wheel-down
```

This protocol is older than most people reading this — xterm shipped mouse tracking in the 1980s, and vim and htop have used it forever. Which sharpens the real question. The wire was always there. **What did it take to put a UI toolkit on the other end of it?**

## Probe two: the binary

Claude Code stopped shipping readable JavaScript. The npm package now contains a single 256 MB Bun-compiled Mach-O with the app baked in as JavaScriptCore bytecode. You can't read the logic. But JSC bytecode keeps its **constant tables** — every identifier, property name, and string literal survives verbatim, *grouped by module*. That last part is the gift: run `strings`-style extraction around a known identifier and its neighbors are its module-mates. Identifier archaeology, plus the pty probe, is enough to reconstruct the architecture. (It also coughs up charming internals: the telemetry namespace is `tengu_*`, and there's a flag named `macCmdClickArrivesWithoutSgrModifierBit`, which is an entire war story in eleven words.)

What the tables describe is a pipeline:

```
 ┌──────────────────────────────────────────────────────────┐
 │ you: click at pixel (612, 384)                           │
 └───────────────────────────┬──────────────────────────────┘
                             ▼
 ┌─ host terminal ───────────────────────────────────────┐
 │ pixel → cell    (col 34, row 12)                      │
 │ encode          ESC [ < 0 ; 34 ; 12 M                 │
 └───────────────────────────┬───────────────────────────┘
                             ▼   bytes on stdin — the only wire
 ┌─ Claude Code ─────────────────────────────────────────┐
 │ 1 decode      SGR report → (button 0, col 34, row 12) │
 │ 2 synthesize  click? double? drag? hover?             │
 │ 3 hit-test    "what did I paint at (34, 12)?"         │
 │ 4 dispatch    move cursor / expand / select menu row  │
 └───────────────────────────────────────────────────────┘
```

Layer by layer, bottom up.

### Decode, and the quirk matrix

There's a tidy terminal-mode manager in there (`mouseTracking: off | normal | button | any`, constants `MOUSE_NORMAL / MOUSE_BUTTON / MOUSE_ANY / MOUSE_SGR`) — but the mode manager is the easy 5%. The other 95% is a compatibility program that the changelog documents as a slow war, one skirmish per release:

- Refuse outright where the ground is bad: *"fullscreen disabled: tmux -CC (iTerm2 integration mode) detected"*, *"fullscreen disabled: Windows over SSH (ConPTY re-rendering) detected"*.
- Coach where config can fix it: detect tmux and suggest `set -g mouse on`.
- Patch around named enemies: JetBrains' terminal (*"spurious arrow keys, wrong-direction events, runaway acceleration"* — v2.1.132), an xterm.js wheel-speed bug in VS Code and Cursor, WSL2 regressions, and my favorite — Claude Code *reads VS Code's own `terminal.integrated.mouseWheelScrollSensitivity` setting* so wheel speed matches the host editor.
- Detect terminals that translate wheel events into arrow keys and fall back gracefully (*"Scroll wheel is sending arrow keys"*).

If you're an agent-TUI author budgeting this feature: the escape sequences are a weekend. The quirk matrix is the roadmap.

### Synthesize: the terminal doesn't know what a double-click is

The wire delivers "button 0 pressed at (34, 12)". That's all it delivers. Double-click, triple-click, drag, hover — every gesture above a raw press is synthesized in the app, and the constant tables show exactly the state you'd expect from a GUI toolkit: `clickCount`, `lastClickRow`, `lastClickCol`, `lastClickTime`, `doubleClickInterval`, `onMultiClick`, `onHoverAt`. Word-select on double-click exists because someone wrote the timer logic, not because the terminal helped.

### Hit-test: the load-bearing layer

A click gives you a cell coordinate. The question "what is at row 12, column 34?" has to be answerable, which means the renderer must remember what it painted where. The binary shows a positions registry built during render — `scanElement`, `scanElementSubtree`, `setPositions`, `prefixSum`, and a property literally named `hitTest`:

```
  col→ 1        10        20        30        40
 row ┌─────────────────────────────────────────────┐
  1  │  ● Read(src/main.rs)… +214 lines            │◀─ rect: tool result
  ⋮  │  …transcript…                               │       (expandable)
 10  │  ┌ Select model ──────────────┐             │
 11  │  │  1. Opus        ◀━━ click  │             │◀─ rects: menu rows
 12  │  │  2. Sonnet                 │             │
 13  │  └────────────────────────────┘             │
 14  │  ❯ fix the login bug in │auth.ts            │◀─ rect: the input
     └─────────────────────────────────────────────┘   (cell → char offset)
```

This is a browser's layout tree feeding `elementFromPoint`, rebuilt over terminal cells — and it's worth saying that the renderer underneath is *not* stock Ink. The identifiers describe a custom frame-diffing engine: `renderFullFrame`, `blit`, `invalidatePrevFrame`, pooled styles, chars, and hyperlinks. Links get their own pool (`getHyperlinkAt`, `openHyperlink`) with a scheme allowlist on dispatch — someone thought about what `file://` does when everything is clickable.

Once the registry exists, the features people actually notice fall out almost for free. Click-to-position is "hit-test resolved to the editor; map cell to character offset; move cursor." Click-to-expand is "this rect is expandable." Clickable menus are "this rect is option row 3."

### One asymmetry you can observe from your chair

Here's a detail I hit as a user before I found it in the strings. Type `/` in Claude Code: the command menu pops up, and **hovering it highlights rows — but the scroll wheel won't scroll it**, even while wheel works fine on the transcript behind it. Bug? No — architecture, visible from the outside:

```
        click / hover                        wheel
             │                                 │
     positional routing                 focus routing
     "which rect contains          "which view has claimed
      the pointer cell?"             the scroll box?"
             │                                 │
      hit-test registry             the focused scrollable
             │                     (transcript, open modal)
             ▼                                 ▼
     works anywhere a rect          falls through widgets that
     is registered                  never claim a scroll box —
                                    like the slash-command menu
```

Clicks route by position; wheel routes by focus (the strings: `claimScrollBox`, `modalScrollRef`, *"When a scrollable view is focused"*). The completion menu registers hover rects but never claims a scroll box, so wheel events sail through it. Browsers route wheel positionally, which is why this feels subtly wrong — and why I'd bet a future release either gives that menu a scroll box or flips wheel to positional routing.

(The wheel path has its own sub-engine, by the way: the alt screen has no native scrollback, so scrolling a long transcript is virtualized — `scrollToIndex`, `scrollAnchor`, prefix-summed line heights — with wheel acceleration, burst detection, and a `wheelFlood` guard on top.)

### The tax: you now own selection

The moment an app enables mouse reporting, drag events stop reaching the host terminal — which means **native text selection dies**. Fifteen years of muscle memory, gone. So Claude Code rebuilt selection inside the TUI: `handleSelectionStart`, `handleSelectionDrag`, `getSelectedText`, `copySelection`, auto-copy-on-select, column selection, and a modifier+drag passthrough to native selection as the escape hatch.

The complaints on X corroborate this layer almost line by line: users annoyed that copy-on-select keeps clobbering their clipboard, users startled that clicking the terminal "does something now," one user spending twenty minutes hunting for the off switch. None of these are bugs. They're the cost of taking ownership of a gesture users believed belonged to the terminal — and the opt-out granularity (`CLAUDE_CODE_DISABLE_MOUSE_CLICKS`: drop clicks, keep wheel) exists because the cost is real. If you ship mouse capture without rebuilding selection, you haven't shipped a feature; you've shipped a regression with hover states.

## The release notes that never said it

Back to the strange paper trail. Assembled from the actual changelog:

```
 2.1.83   the fix log starts leaking:  "Fixed mouse tracking escape
          sequences leaking to shell prompt after exit"
 2.1.89   CLAUDE_CODE_NO_FLICKER=1          ← the birth, as an env var
 2.1.110  /tui fullscreen                   ← the front door opens
 2.1.132  banner now mentions              ← the only "announcement"
          "mouse support, auto-copy on select"
 2.1.139  /scroll-speed, with live preview
 2.1.145  slash & @-mention menus: hover + click
 2.1.187  select menus clickable (permissions, /model, /config)
 2.1.195  CLAUDE_CODE_DISABLE_MOUSE_CLICKS
 2.1.208  multi-select menus clickable
   —      click-to-position: never mentioned in any entry, ever
```

Copy-on-select, hover, and click-to-expand all appear in the changelog *as things being fixed* before ever being introduced. The marquee interaction — click into the input, cursor moves — appears in zero entries; the only written evidence anywhere is a banner string inside the binary: *"Click to move your cursor in the text input."*

Why ship the biggest UX change in the product's history this way? Inference, but the shape is recognizable: the risky bet was the *renderer* — an alt-screen rewrite of the whole UI — so it went out as an env var, graduated to a `/tui` toggle, grew an upsell banner, and was paced by telemetry the whole way (`fullscreen-upsell`, `fullscreen-downsell`, and an exit survey: *"what made you switch back?"*). The mouse was never the product. It's a *property of the new renderer*, and you don't announce that a browser supports clicking.

## The playbook

This section is the reason the post exists. Codex CLI users are already asking its maintainers for click-to-position by name — "Claude Code and Grok already have it" — so the demand is public; what's been missing is the map. From the shipped evidence, the build order is:

1. **Own the whole screen first.** Alt-screen, frame-diffing renderer. Claude Code gated the mouse behind fullscreen mode rather than retrofitting the scrolling line-based UI — that ordering is the design.
2. **Enable the ladder**: 1000/1002/1006. Add 1003 only when you have hover to justify the event volume.
3. **Build the layout registry during render.** Every interactive component registers its rect. Hit-testing must be a lookup, not a heuristic — this single structure is what turns "mouse events" into "a UI".
4. **Synthesize gestures yourself**: click count, double/triple, drag, hover. The terminal gives you presses; the toolkit is your job.
5. **Rebuild selection or don't ship.** Auto-copy-on-select plus modifier+drag native passthrough is the floor.
6. **Carry a quirk matrix**: tmux, ConPTY, JediTerm, xterm.js, wheel-as-arrows. Refuse loudly where it can't work; coach where config fixes it.
7. **Opt-outs at every granularity, instrumented.** Claude Code can tell you exactly who turns the mouse off, and asks them why. That feedback loop is why it's still shipping.

## Coda

No single trick here is new. Hit-testing, gesture synthesis, hover, virtualized scrolling — every GUI toolkit since the Xerox Star has these. What's new is the claim implicit in building them *above* a byte stream from the 1980s: that the terminal's event model was never the limitation. The missing piece was always an application willing to treat cells as pixels and put in the unglamorous work — the registry, the quirk matrix, the selection tax — that a real toolkit demands.

Claude Code did the work and didn't even bother to announce it. The other agent TUIs now get to copy it with the map in hand. And if the TUI has the mouse, the line between "terminal app" and "app" is thinner than anyone's roadmap assumed — which should be interesting news for everyone building terminals, multiplexers, or anything else that thought it knew where that line was.

---

*Method: identifiers and quoted strings extracted from the constant tables of the publicly shipped `@anthropic-ai/claude-code` 2.1.220 npm binary; runtime behavior verified by spawning it under a pty and logging its escape output; timeline from the official CHANGELOG. Mechanisms not directly observable in bytecode are labeled as inference.*
