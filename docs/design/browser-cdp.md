---
title: Browser Control over CDP
status: draft
type: design
created: 2026-08-07
updated: 2026-08-12
related:
  - companion-wire-protocol.md
  - termiod-session-protocol.md
  - agent-extensibility.md
---

# Browser Control over CDP

> Give an agent the user's real logged-in Chrome through two CLI verbs and one
> Chrome extension, with nothing listening until the user turns it on — and
> route it back from a remote session, which is the part nobody else can do.

## 1. The constraint everything else follows from

**Chrome 136 killed the port.** `--remote-debugging-port` and
`--remote-debugging-pipe` are no longer respected against the default user data
directory; they must be accompanied by `--user-data-dir` pointing somewhere
else, and a separate data directory uses different encryption, so the profile
cannot be copied across either. Chrome for Testing keeps the old behaviour.
Current Chrome is 151.

That single fact decides the architecture:

| path | reaches the user's real profile? |
| --- | --- |
| Chrome extension (`chrome.debugger`) | **yes** — cookies, logins, extensions, live sessions |
| `--remote-debugging-port` + `--user-data-dir` | no — a fresh profile, logged into nothing |
| Chrome for Testing | yes, old behaviour — but not the user's browser |

An agent driving a browser that is logged into nothing is worth very little:
the tasks people actually want — read this dashboard, file this form, check
this account — are all behind a session. So the extension is not the convenient
option among several. **It is the only door**, and whoever ships it holds the
capability.

Two consequences that are easy to get wrong:

- The Settings pane must not offer "or just open the debug port" as an
  alternative. It would silently hand the agent a logged-out browser, and every
  authenticated page would fail for a reason the user cannot see.
- A CDP-port path is still legitimate for CI against Chrome for Testing, where
  a fresh profile is what you want. Worth keeping the code path; not worth
  offering to users.

## 2. The interface is two verbs

```
termio browser cdp <Method> [params-json]   # the page API
termio browser status                       # is a browser attached, what is bound
```

That is the whole agent-facing surface. `tabs` is `Target.getTargets`. Reading
the page is `Accessibility.getFullAXTree`. Clicking is `DOM.getBoxModel` plus a
pair of `Input.dispatchMouseEvent` calls. Screenshots are
`Page.captureScreenshot`. None of them needs a verb.

**Why not a verb vocabulary.** Every wrapper encodes one answer to "how do you
click" — resolve a ref, get a box, dispatch a mouse event — and when a page
needs a different answer (a trusted event sequence, a framework-safe value
assignment, a shadow-DOM traversal) the wrapper is not merely unhelpful, it is
in the way. Chrome's protocol is documented, versioned by Chrome, and heavily
represented in model training data. A hand-rolled vocabulary is none of those,
and every name in it has to be taught in a skill file.

This is not speculative. `termio-sh/browser` (formerly `runbrowser`) shipped the
verb design and then removed it: 38 CLI commands to 11, 28 HTTP routes to 6, and
a `@ref` element-handle system deleted outright. Each verb existed in five
places at once — a CLI registration, a client method, an HTTP route, a
server-side implementation and a doc line — and they had drifted far enough
that three tab routes were being called with no route registered to serve them.
`rfcs/minimal-cdp-surface.md` in that repo has the full accounting.

The reason to sit at the raw end rather than the `chrome-devtools-mcp` end
(51 tools, `uid` handles, no CDP passthrough) is specific to termio: **the agent
already has a shell.** A verb CLI re-implements, badly, what the agent can do by
piping. Everything below is why that is necessary but not sufficient.

### Prior art, and the limit of this argument

`remorses/playwriter` (3.7k stars) is the same architecture — Chrome extension,
`chrome.debugger`, WebSocket relay on port 19988 — and `runbrowser` began as a
fork of it. Its interface is not verbs and not raw CDP: it runs **real
Playwright** in a stateful sandbox, so the agent writes
`await page.locator('aria-ref=e5').click()`.

The "don't invent a vocabulary" argument does **not** dispose of that. Playwright
is not a vocabulary we invented — it is a de facto standard with more
training-data presence than raw CDP calls, and `page.click()` is not a naive
wrapper around `Input.dispatchMouseEvent`. It is auto-waiting plus actionability
checks (visible, stable, enabled, receives events) refined over years. On the
two axes that matter most it is simply better than what is specified here:
grounding (`aria-ref` handles) and event-driven waiting (`waitForResponse`,
`Promise.all`).

We are not adopting it, for reasons of dependency rather than design:

- It requires **Node plus Playwright** on the machine. termio ships no JS
  runtime and must not acquire one — the same objection that rules out bundling
  `bun`.
- playwriter depends on `@xmorse/playwright-core`, a **fork** of playwright-core.
  Driving a browser through an extension relay needed patches upstream does not
  carry. Adopting Playwright would mean depending on someone's fork of a large,
  fast-moving Google library, or maintaining our own.

So: same wire as playwriter, none of playwriter's dependencies, and — stated
plainly rather than hidden — **a thinner layer than playwriter's by choice.**
Where that thinness costs real capability, the answer is §7, not a Node runtime.

`browser-use/browser-harness` (16.6k stars) is the third design, and reading it
carefully is what produced §7. Its interface is one code-execution entry point
with ~25 thin helpers, and it clicks with `click_at_xy` computed from an
accessibility-tree box — **no visibility, stability, enabled or obstruction
check**, exactly the weakness of raw CDP. It compensates with two bets nobody
else makes: the agent **edits its own helpers mid-task** when something is
missing, and site-specific knowledge accumulates as **per-domain markdown**
loaded on demand. The repo's mass is in the latter — roughly 20KB per site.

Two theories of reliability, then. Playwright makes the primitive strong so the
agent need not think; browser-harness accepts a weak primitive and invests in
the loop that repairs it. They are complementary, not opposed, and §7 takes
from both.

One asymmetry disqualifies browser-harness as a model for the transport,
though: it connects over `--remote-debugging-port` and launches Chrome itself.
Per §1 that **cannot reach the user's default profile** on Chrome 136+. It
automates *a* browser; termio automates *your* browser. Its design choices —
coordinate clicks, launch-your-own — are reasonable in a world where the
profile does not matter, and are not reasonable here.

**`status` earns its place** because it is the one fact that is not about the
page. Whether a browser is attached, and which target this session is bound to,
are things the app knows and the caller cannot derive from a CDP result.

**No `launch` verb.** The value is the user's authenticated Chrome; spawning a
fresh one abandons it. A verb that has to be documented as "never use this" is
a design error, not a documentation problem.

## 3. Discovery costs zero turns

Browser availability is a fact termio holds — the app *is* the endpoint the
extension connects to. So it belongs in the environment, stamped at PTY spawn
alongside `TERMIO_SESSION`:

```
TERMIO_BROWSER=ready | no-extension | off
```

The skill's first instruction is to read it. `ready` means go straight to the
verb: no probe, no subprocess, no round trip. Anything else means one
`termio browser status` (the env is fixed at spawn; the extension may have
connected since) and then stop.

This matters more because the feature is opt-in: `off` is the common case, and
it is answerable for free.

## 4. Off by default, enabled in Settings

`BrowserSettingsTab`, alongside `AgentSettingsTab` and `MobileSettingsTab`. The
pattern already exists — added ≠ enabled, with availability gated on something
external being present (`AgentAvailability.swift`).

"Install" means four different things and only three are installable:

| piece | preinstalled? |
| --- | --- |
| `termio browser` verbs (Swift) | yes — compiled in; cannot not be |
| companion server accepting extension clients | **no** — refuses until enabled |
| Chrome extension | **no** — only the user can install into Chrome |
| the skill in the agent's skill dirs | **no** — written on enable |

Enabling does three things: flips the gate so the server will accept an
extension, opens the Chrome install path, installs the skill.

**Why off by default is not merely taste.** A `chrome.debugger` extension with
`<all_urls>` over the user's logged-in Chrome is the most invasive thing termio
would ship — more invasive than the agent's shell access, because it carries
live authenticated sessions. And concretely: if the companion server accepted
extension connections unconditionally, any local process could impersonate an
extension and drive the browser. Gating means nothing is listening until asked.
That is the flaw in both `browseruse`'s port 9876 and `runbrowser`'s port 19988,
closed here by construction rather than by adding auth to an always-open door.

**The verb still exists when disabled.** `command not found` teaches an agent
nothing; a structured failure lets it report accurately and move on:

```
error: browser support is off — the user can enable it in Settings ▸ Browser
```

Onboarding is the app's job. An agent mid-task must never be walking the user
through a Chrome Web Store install — it cannot complete it, cannot verify it,
and derails whatever it was doing.

## 5. Transport: no second server

The extension dials **out** to termio's existing companion WebSocket
(`CompanionServer`, port 8787 / 8788 dev) and presents the pairing token, using
the same `.auth` control frame the phone uses. Health check first, reconnect
loop after.

No new port, no second daemon, no Node runtime. termio ships no JS runtime and
must not acquire one for this — the same objection that rules out bundling
`bun` for `browseruse` or depending on a global `npm install` of `runbrowser`.

`termio browser` reaches the app over the existing AF_UNIX control socket,
beside `termio sessions` and `termio agent report`. Passing a method name and a
JSON blob down a socket is framing, not logic, so the CLI stays thin shell.

**The Swift side never parses a page.** It moves a method and a params blob in
one direction and a result blob back. This is the same discipline as the VT
sidecar never sitting in the byte path: no per-call interpretation, no grid
encoder, nothing that has to understand the payload to forward it.

## 6. Tabs are connection state

Bind by **target ID, never by list index**. `Target.getTargets` makes no
ordering guarantee, so an index captured in one call can name a different tab
in the next — a bug shipped in the runbrowser rewrite and caught in review.
`status` reports the bound target; a session binds explicitly at creation
rather than lazily attaching to whatever non-blank target appears first.

Every response echoes the target it acted on. Agents lose their thread between
turns, and self-describing output survives context compaction where implicit
server-side state does not.

## 7. The two known gaps, and where they get closed

Raw CDP is missing two things Playwright gives away for free. Both are real, and
the answer to both is **the extension**, not a runtime on the Mac.

**Events.** `cdp` sends commands and returns results. CDP is commands *and*
events, and this design currently delivers none of them. That forecloses waiting
on navigation, popups, dialogs and download completion; capturing the network or
console activity an action caused; screencast frames, which arrive as
`Page.screencastFrame`; and out-of-process iframe or worker attachment. Polling
for an observable side effect covers loads and most SPA waiting, but genuinely
does not cover downloads or dialogs, and the skill must say so rather than let
an agent discover it by retrying.

**Actionability.** `Input.dispatchMouseEvent` at a computed coordinate has no
notion of whether the element is visible, stable, enabled, scrolled into view,
or covered by an overlay. Writing those steps into a skill file as prose is a
hand-rolled, unverified reimplementation of the thing Playwright spent years
getting right — precisely the mistake §2 claims to avoid, just relocated from
code into documentation.

**The extension is already JavaScript running in the page.** That is the part
worth noticing: actionability does not need Node on the host. A content script
can wait for visible + stable + enabled, scroll into view, and then dispatch —
on the order of a hundred lines, no runtime anywhere, and it recovers most of
what Playwright's `click()` actually buys. The same applies to grounding: stable
element handles minted in-page survive better than backend node ids resolved
host-side.

So the split is:

- **`cdp`** stays the escape hatch and the whole protocol.
- **The extension** owns the few behaviours that are genuinely hard and
  genuinely reusable: actionability, stable handles, and an event subscription
  the host can read.

The host-side surface for events, when it lands, should be one verb —
`termio browser events subscribe|read` — not a per-case `wait` vocabulary.

**Deliberately deferred:** both are designed against a real task that needs
them, not guessed at now. What is decided is *where they live* — in the
extension, not in a skill file and not behind a Node dependency.

### The two capabilities that cost nothing

browser-harness's distinctive bets are the cheapest things on this list for
termio, and they are currently missing from the design.

**Self-repair.** browser-harness lets the agent edit `agent_helpers.py`
mid-task: hit a missing capability, write it, re-run. That requires a code
execution environment with an editable helpers file — which **termio's agent
already has**, because it is sitting in a shell with a filesystem. The cost is
not code; it is one instruction in the skill: *when you work out a CDP sequence
that works, write it to a script and reuse it, rather than re-deriving it next
turn.* Without that sentence the agent re-derives the same click sequence every
time and we get browser-harness's weak primitive with none of its recovery.

**Domain knowledge.** The long tail — this site needs a scroll before the button
is real, that one rejects synthetic events — is not eliminable by any interface.
browser-harness stores it as per-domain markdown. termio's equivalent already
exists: **skills**, with a distribution format defined in
[agent-plugins.md](./agent-plugins.md). Also free.

That yields the full picture:

| need | answer | cost |
| --- | --- | --- |
| grounding | AX tree + stable handles minted in-extension | small |
| actionability | extension content script | ~100 lines |
| waiting / events | `browser events subscribe\|read` | the one real gap |
| self-repair | agent writes scripts to disk — say so in the skill | free |
| domain knowledge | skills, distributed as plugins | free |
| escape hatch | `cdp` | done |

Which is stronger than the alternatives on their own terms: better primitives
than browser-harness, fewer dependencies than playwriter, and the only one of
the three that reaches a logged-in profile at all. **Events remain the honest
weak spot** — the one item where both are ahead and no amount of skill-writing
substitutes.

## 8. Remote sessions: the part that is ours

`termio browser` from a termiod session on a VPS routes back over the same
framed connection to the Mac's Chrome. From the agent's side nothing changes —
same verbs, same PATH, same env var.

This falls out of the transport-agnostic protocol for free, and it is the case
standalone browser tooling structurally cannot serve, because it assumes agent
and browser share a machine. A browser on a VPS is worthless: no cookies, no
SSO, no 2FA. The correct primitive is **the browser lives where the human is,
the agent may live elsewhere.**

## 9. Visibility is the feature

An agent acting in the user's authenticated Chrome is a trust event. Three
surfaces, all of which already exist:

- ghost cursor and element highlight in-page, from the extension's content script
- Chrome's own "termio is debugging this browser" infobar — **never suppress it**
- the session trace: browser calls and screenshots land there, and the trace
  already renders as themed HTML and already shows on the phone

That last one has no equivalent elsewhere: the user can audit what an agent did
in their browser from their pocket.

## 10. What this is not

- **Not a plugin system.** termio has no extension mechanism and should not
  grow one for a single consumer. A settings gate and a skill install is the
  whole mechanism.
- **Not an in-app browser.** A WKWebView pane is logged into nothing, which is
  exactly what makes automated browsing useless for real tasks, and it puts an
  app inside the terminal.
- **Not a second binary.** The capability cannot function without termio.app
  running, so a standalone `browser` command would be a client of termio
  wearing a costume. Its Unix analogues are `systemctl` and `ip` — subcommand
  dispatchers over a daemon — not `ls`.
- **Not an npm dependency.** See §5.

## 11. Open questions

1. ~~Where the extension source lives.~~ **Decided:** `termio-sh/browser`, its
   own repo, transferred from `runbrowser/runbrowser` with history intact. The
   accepted cost is cross-repo protocol sync — the extension and the companion
   server define two ends of one contract and now ship from two repos, which is
   the skew problem `companion-wire-protocol.md` exists to describe. Version the
   handshake accordingly.
2. **Web Store listing** — unavoidable cost, and the long pole. v0 can ship the
   extension unpacked in the bundle with the Settings button revealing it and
   opening `chrome://extensions`; that unblocks everything else.
3. **Skill install scope** — global (`~/.claude/skills`), matching how termio
   installs hooks, rather than project-local.
4. **Events** — §7.
5. **Whether a portable host ever ships** for non-termio agents. The contract
   makes it possible; nothing suggests demand yet. Wait for the signal.

## Sources

- Chrome 136 remote-debugging change:
  <https://developer.chrome.com/blog/remote-debugging-port>
- "The Bitter Lesson of Agent Harnesses":
  <https://browser-use.com/posts/bitter-lesson-agent-harnesses>
- `chrome-devtools-mcp` tool reference:
  <https://github.com/ChromeDevTools/chrome-devtools-mcp>
- The verb-removal accounting: `rfcs/minimal-cdp-surface.md` in
  <https://github.com/termio-sh/browser>
- `remorses/playwriter` — the upstream this forked from; Playwright in a
  stateful sandbox over the same extension relay:
  <https://github.com/remorses/playwriter>
- `browser-use/browser-harness` — thin CDP helpers, agent-editable at runtime,
  with per-domain knowledge as markdown:
  <https://github.com/browser-use/browser-harness>
