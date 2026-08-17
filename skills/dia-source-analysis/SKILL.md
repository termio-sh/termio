---
name: dia-source-analysis
description: "Analyze / reverse-engineer the locally installed Dia Browser mac app (The Browser Company; bundle id company.thebrowser.dia; shares ArcCore with Arc). Inspect its app bundle, extract its Bun/TypeScript agent-server source from shipped source maps, fingerprint the runtime, read native-Swift symbols, and map its AI-agent / sandbox / on-device-ML architecture. Invoke when the user wants to study how Dia works internally, extract Dia's agent code, or compare Dia's agent/terminal approach against termio. (User sometimes voice-types the name as 'DotBrowser' — same app.)"
---

# Analyze Dia Browser source

Dia (`/Applications/Dia.app`, The Browser Company, `company.thebrowser.dia`) is a
WebKit-based browser (~1.4 GB) that shares `ArcCore.framework` with Arc. termio uses
it as a reference for how a shipping product **drives AI coding agents as sandboxed
child processes** (Dia shells to the real Claude Code CLI under Seatbelt) and for its
agent-server / IPC architecture. This skill captures how to dig into it and what's
already known, so analysis doesn't start from scratch each time.

## Golden rules

- **Read-only, on the user's own machine, for research.** This is proprietary code shipped
  to the user. Use it to *understand and learn*, never to copy/redistribute verbatim or
  ship lifted code. State this caveat when sharing recovered source.
- **Verify before trusting old findings.** The "Established facts" below are version-stamped.
  Dia auto-updates (Sparkle); bundle layout, file hashes, runtime versions, and even whether
  source maps ship can all change. Always re-read `info.json` + `CFBundleShortVersionString`
  first and treat mismatches as "re-derive from scratch."
- **Two recoverability tiers:** the Bun/TS agent backend is near-fully recoverable (source
  maps); the native Swift app is symbols/structure only (no real source).

## Established facts (as of Dia 1.34.2 — RE-VERIFY)

Agent-server `info.json` (1.34.2): version 1.0.0, buildDate 2026-06-10, commit `47de9fbe6c4`,
`claudeCodeVersion 2.1.131`. (Was 1.32.0 / commit `55d9d2e174b` / buildDate 2026-05-20.)

- **⚠️ Source maps NO LONGER SHIP as of 1.34.2.** `extract-sourcemaps.py` returns "No .map
  files found" — the Bun/TS agent-server backend is no longer recoverable as near-original TS
  (only logic compiled into the Mach-O remains). The native-Swift tier is unchanged: symbols +
  embedded source paths only. So "the big win" in §1 below is gone on current builds; keep the
  procedure for older installs / in case they return.
- **Agent backend = Bun-compiled standalone Mach-O** (`agent-server`, `handler`) + **the real
  Claude Code CLI** (`claude`, 206 MB, itself a Bun binary). No separate Node/Bun runtime is
  installed — each binary embeds Bun. They run as **child processes under Seatbelt sandbox**
  (`sandbox-exec -f agent.sb` / `agent-claude-code.sb`, params via `-D DATA_DIR=…`), talking
  to the native UI over SSE/IPC (`transport/sse.ts`, `ipc-gateway.ts`). Per-context workspace
  at `data/contexts/{contextId}` with resumable disk buffers (`session/buffer.ts`, JSONL). **This
  is the part most relevant to termio** — termio runs agents in real PTYs (`.exec`) instead, but
  the child-process-under-sandbox + resumable-buffer + IPC design is the directly comparable bit.
- **Streaming smoothness** comes from native rendering + `session/update-batcher.ts`: deltas are
  coalesced and flushed only on **≥256 B** OR **250 ms idle** OR completion — so the UI updates a
  few times/sec, not per token. The Bun agent-server is backend orchestration and does NOT touch
  UI perf.
- **AI chat ("AssistantPanel") renders NATIVELY, not in a webview.** Markdown parsed by
  `cmark` (swift-markdown), code highlighted by **Highlightr** (`CodeAttributedString` →
  NSAttributedString), math by **SwiftMath** (`MTMathListDisplay`, CoreText). UI is AppKit
  `NSViewController`s (source paths `Frameworks/BoostBrowser/Sources/AssistantPanel/*.swift`).
- **The AI input is the native AppKit module `BoostCommandBar`** (`Frameworks/BoostBrowser/
  Sources/BoostCommandBar/*`): a token/pill `TokenTextView` w/ `SkillPillTokenViewProvider`;
  Skills = `SkillsV3`; `@`-mentions (`AtMentionKeywords`: @Search/@Slack/@Gmail/@Notion) insert
  context/tool pills. On-device `cmd_t_router` (3-label intent) + `skills` classifier rank
  proactive suggestions.
- **WKWebView (~45 refs) is for web pages + HTML "artifacts"** (reports/slides via
  `report-kit`/`slide-kit`), NOT for chat bubbles.
- **On-device ML** (`OnDeviceLoRAadaptors` bundle, 152 M): one shared **DistilBERT-base** encoder
  (126 M, fp16) + three LoRA adapters + heads — `cmd_t_router` (input intent), `skills` (which
  skill to fire), `sensitive_content` (privacy gate). Run via MLX (`mlx-swift`).

## Bundle map

| Path | Size | What |
|---|---|---|
| `Contents/Frameworks/ArcCore.framework` | ~548 M | browser engine core (WebKit + Arc) |
| `Contents/Resources/agent-server-resources/dist` | ~371 M | Bun agent backend + bundled `claude` CLI (206 M) |
| `Contents/Resources/OnDeviceLoRAadaptors_…bundle` | ~152 M | DistilBERT base + 3 LoRA classifiers |
| `Contents/MacOS/Dia` | ~106 M | native Swift app binary (AssistantPanel etc.) |
| `Contents/Frameworks/libAIInfra.dylib` | ~21 M | on-device classification (`LocalClassification`) |
| `Contents/Resources/*.bundle` | — | Highlightr, SwiftMath, SwiftProtobuf, mlx-swift, swift-transformers, ARC/BoostBrowser feature bundles |
| `dist/*.sb` | — | Seatbelt sandbox profiles |

## Procedure

### 0. Identify version (always first)
```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Dia.app/Contents/Info.plist
cat "/Applications/Dia.app/Contents/Resources/agent-server-resources/dist/info.json"
```

### 1. Recover the agent-server source (the big win)
The `.js` bundles are compiled into the Mach-O binaries and NOT shipped, but `entrypoint.js.map`
and `handler-entrypoint.js.map` ship with `sourcesContent` populated → near-original TS.
```bash
python3 skills/dia-source-analysis/scripts/extract-sourcemaps.py --out /tmp/dia-src
```
Yields ~40 "own" TS files (non-node_modules): `agent/harness/claude-sdk/*` (how it drives the
Claude SDK — `prompt-template.ts`, `proxy-tools.ts`, `claude-sdk-in-process.ts`, `sandbox.ts`),
`session/*`, `transport/*`, `handler/*`, `runtime.ts`, `watchdog.ts`, `main.ts`. Also readable
without extraction: `dist/agents/*/spec.yaml`, `dist/agents/*/.claude/`, `dist/resources/tool-schemas/*.json`.

### 2. Fingerprint the runtime
```bash
D=/Applications/Dia.app/Contents/Resources/agent-server-resources/dist
for f in agent-server handler claude; do echo "== $f"; \
  strings -a "$D/$f" | grep -iE "Bun v[0-9]|Bun/[0-9]|node\.js v[0-9]"|sort -u|head; done
```

### 3. Native Swift binary — structure recoverable via `ipsw class-dump --swift` (no bodies)
The symbol table is **stripped** (`nm` ≈ 8.5k symbols, no Swift method-body symbols; debugger
attach is blocked by hardened runtime `flags=0x10000(runtime)` + no `get-task-allow`). But the
Swift **reflection metadata** survives and gives field-level structure — the closest thing to source:
```bash
brew install ipsw   # one-time
BIN=/Applications/Dia.app/Contents/MacOS/Dia
strings -a "$BIN" | grep -iE "AssistantPanel|Highlightr|SwiftMath|cmark|MarkdownText" | sort -u | head
ipsw class-dump "$BIN" --class 'AssistantPanel'                    # response/content view controllers
ipsw macho info  "$BIN" --swift-all | grep -i <Type>              # generics
```
This yields class/struct **instance-variable layouts, superclasses, protocol conformances, and
method signatures** — NOT bodies, and NOT the numeric values of fields. `strings` still gives
demangled type names + embedded source *paths* (`/Users/admin/actions-runner/_work/arc/arc/…`).
For deeper work use Hopper/Ghidra, but Swift ABI makes UI/animation bodies near-unreadable.

### 4. On-device models
```bash
B=/Applications/Dia.app/Contents/Resources/OnDeviceLoRAadaptors_OnDeviceLoRAadaptors.bundle/Contents/Resources
cat "$B/config.json"; ls -lhS "$B"/*.safetensors
strings -a /Applications/Dia.app/Contents/Frameworks/libAIInfra.dylib | grep -iE "cmd_t|router|sensitive|skills_|distilbert|lora" | sort -u | head
```

### 5. Sandbox profiles (most relevant to termio)
```bash
cat /Applications/Dia.app/Contents/Resources/agent-server-resources/dist/agent.sb
cat /Applications/Dia.app/Contents/Resources/agent-server-resources/dist/agent-claude-code.sb
```
These are Seatbelt (`sandbox-exec`) profiles — read them to see exactly what the agent / Claude
Code subprocess may touch.

## Relevance to termio

termio is a **native Swift + libghostty terminal for AI coding agents** (unpeel-style): it runs
each agent/session in a real PTY (`.exec`) via a libghostty surface, unsandboxed. Dia solves an
adjacent problem — driving the same Claude Code CLI — but from a browser, sandboxed, over IPC.
When comparing, borrow narrowly (termio is deliberately simple/minimal — do **not** import Dia's
~370 M Bun agent-server, on-device ML stack, or browser surface):

- **Sandbox profiles (§5)** are the highest-value takeaway: if termio ever wants to constrain
  what an agent session can touch beyond the PTY, Dia's `agent.sb` / `agent-claude-code.sb`
  Seatbelt profiles are a concrete, shipping reference for `sandbox-exec`.
- **Child-process + resumable buffer + IPC design** (`session/buffer.ts` JSONL, per-context
  workspace) is the architecture analog to termio keeping a `TerminalController` alive per
  session in the SurfaceCache — same goal (survive view rebuilds / resume), different mechanism.
- **Delta coalescing** (`update-batcher.ts`: flush on ≥256 B / 250 ms idle / completion) is a
  generic perf lesson if termio ever renders agent output outside the raw terminal grid.
- **Skip:** the native AssistantPanel renderer and on-device LoRA classifiers — termio shows a
  real terminal, not a native chat surface, so those don't map.
