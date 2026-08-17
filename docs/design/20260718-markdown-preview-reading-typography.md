---
title: "Markdown preview — Apple-grade reading typography"
status: draft
type: design
created: 2026-07-18
updated: 2026-07-19
related:
  - 20260718-agent-abstraction-and-configuration.md
---

# Markdown preview — Apple-grade reading typography

> Add an Edit/Preview toggle to the file editor whose Preview mode renders `.md`
> with a document-grade reading experience — the feel of Apple Developer docs /
> iA Writer, not a dense dashboard — reusing the WebView engine we already have.

## Goal & non-goals

**Goal.** When you open a Markdown file (`CLAUDE.md`, `AGENTS.md`,
`docs/design/*.md`, READMEs) in Termio's over-the-terminal file editor, a
**Preview** mode renders it with excellent reading typography that (a) follows
Termio's active chrome theme, (b) works fully offline, and (c) feels native and
premium.

**Non-goals.**

- Not a WYSIWYG editor. Edit stays the Highlightr source editor; Preview is
  read-only rendered output. Toggle between them.
- Not the DocC pipeline. We are not building `.docc` catalogs or a compile step.
- Not a chat/transcript surface. The session trace (`Info/`) keeps its own dense
  dashboard CSS; this is a separate *document reader* skin.

## As built — final typography decisions (2026-07-19)

The sections below this one are the original plan; where they disagree, **this
list is what shipped** (the CSS sketch in §2 is kept as historical reference):

- **Body face: bundled iA Writer Quattro** (static S cuts, four woff2 ≈ 172KB,
  SIL OFL — license shipped alongside in `Resources/Fonts/`), `17px/1.6`,
  falling back to `-apple-system`. The earlier "terminal font as body"
  experiment was reverted: pure mono is a terminal aesthetic, not a reading
  one — Quattro is the mono-boned face *designed* for reading, which is the
  "terminal-native document" register this feature wants.
- **Fonts are base64-embedded `@font-face`**, not `baseURL`-resolved as §4
  planned: `loadHTMLString` gives the WebContent process **no read access to
  the app bundle**, so `file://` font URLs silently fail. Built once and cached
  in `MarkdownReaderRenderer.quattroFontFaces`.
- **Measure: a ceiling, not a column** — `max-width: calc(76ch + side padding)`,
  centered. Narrow/medium panes still fill edge-to-edge (the pane stays the
  measure control); a wide pane stops at ~76 characters instead of 120+.
- **Code spans/blocks keep the terminal font** (`--font-mono`, from
  `settings.fontFamily`) so code in Preview matches the editor you flip from.
  iA Writer Mono is not bundled.
- **Only real weights (400/700)** — Quattro S ships Regular/Bold (+italics);
  the sketch's 650/680 would silently snap to 700 anyway.
- **No `scroll-behavior: smooth`** — it animated the post-reload scroll
  restore, and AppKit has no such global smoothing; removed.
- **Reader fallback palette decoupled from the trace**: `TraceTheme.reader(dark:)`
  carries the muted reading accents; `builtin` stays untouched so Mac/phone
  trace colors are stable.

## Why the current path isn't enough

We already render Markdown → HTML via `TraceMarkdown.html()` and show it in a
`WKWebView`. Two gaps:

1. **`TraceView.TraceWebView` is a bare string-loader.** It calls
   `loadHTMLString(html, baseURL: nil)` — no `<head>` control, no bundled fonts,
   no base URL (so relative images/fonts can't resolve), no scroll preservation.
2. **The trace stylesheet is a dashboard, not a document.** 13.5px body, 900px
   measure, uppercase micro-labels, tight rhythm — tuned for *scanning a
   transcript*, the opposite of comfortable *reading*.

So the work is a dedicated **reader renderer** + a dedicated **reader
stylesheet**, reusing the same parse (`TraceMarkdown`) and the same engine
(`WKWebView` — which is, notably, exactly what Xcode's DocC preview uses).

## How Xcode / Apple do it (for reference)

- **DocC documentation preview** (the `developer.apple.com` look) is a
  `WKWebView` rendering `swift-docc-render`. Apple's *premium* Markdown reading
  experience is a web view — the quality is entirely in typography, not the
  engine. This validates our architecture.
- **Playground rendered markup** is native `NSAttributedString` rich text —
  beautiful but only handles lightweight inline markup, not full block layout
  (tables, fenced code, images). Not a fit for arbitrary docs.

Takeaway: keep the WebView, invest everything in typography + a proper renderer.

## The curated stack

No single OSS project drops in, because Termio has two constraints most ignore:
**fully offline/bundled**, and **must track Termio's arbitrary chrome-theme
colors** (not just `prefers-color-scheme` light/dark). So we borrow the best
piece from each and drive it all off Termio's theme variables.

| Layer | Decision | Source / license |
| --- | --- | --- |
| Reading metrics | Port **Tailwind Typography (`prose`)** vertical rhythm, type scale, and measure into a standalone, `var(--…)`-driven `reader.css`. Port the *metrics*, not the Tailwind build. | [tailwindlabs/tailwindcss-typography](https://github.com/tailwindlabs/tailwindcss-typography) (MIT) |
| Signature body font | Bundle **iA Writer Quattro** (variable, proportional-but-monospaced-rooted — the reference face for Markdown reading). System `-apple-system` is the graceful fallback. | [iaolo/iA-Fonts](https://github.com/iaolo/iA-Fonts) (SIL OFL 1.1) |
| Code highlighting | **Shiki-grade fidelity, zero web-view JS**: pre-highlight fenced blocks **host-side in Swift** using the already-vendored Highlightr / highlight.js, emit classed `<span>` HTML, ship a highlight theme CSS mapped to Termio vars. | reuse vendored `Editor/Highlightr` |
| Layout principles | Tufte's *ideas* — narrow measure, quiet links, real italics/bold — not the library. | [tufte-css](https://edwardtufte.github.io/tufte-css/) (reference only) |

### Rejected alternatives

- **github-markdown-css** (MIT, standalone) — themes via
  `@media (prefers-color-scheme)`, so it can't follow Termio's custom chrome
  colors. Excellent reference for GFM element coverage; wrong theming model to
  adopt wholesale.
- **Shiki JS in the web view** — best-in-class highlighter, but its whole win is
  *pre-rendered, zero client JS*. We already ship highlight.js via Highlightr;
  bundling Shiki's engine + TextMate grammars would be a redundant second
  highlighter and a heavier bundle for no reading-quality gain.
- **Tufte CSS as-is** — gorgeous but idiosyncratic (serif body, margin
  sidenotes, no hover on links). Wrong register for `CLAUDE.md` / engineering
  docs.
- **DocC pipeline** — needs a `.docc` catalog + a compile step + a local server.
  Massive overkill to preview a single `.md`.
- **Native NSAttributedString reader** (the Playground approach) — true native
  text, but full block layout (tables, fenced code, images, task lists) in
  TextKit is a large hand-rolled effort for a worse result than tuned HTML/CSS.

## Architecture

```
FileEditorView (over-terminal overlay)
├── header: [ Edit | Preview ] segmented control   ← only shown for .md/.markdown
├── Edit    → HighlightedTextView (unchanged)
└── Preview → MarkdownReaderView (new)
                 └── MarkdownReaderRenderer.document(text, theme, baseURL) -> String
                        ├── TraceMarkdown.html(text)            (reuse parse; trusted mode, see below)
                        ├── CodeHighlighter.highlight(block)    (host-side hljs → classed HTML)
                        └── reader <head> + @font-face + reader.css + theme vars
```

### 1. `MarkdownReaderView` — a real renderer (replaces bare `TraceWebView`)

A new `NSViewRepresentable` (do **not** extend `TraceWebView`; keep the trace's
dense skin separate). Responsibilities the current loader lacks:

- Load via `loadHTMLString(html, baseURL: <file's directory URL>)` so relative
  `![](./shot.png)` and the bundled `@font-face` URLs resolve. Grant read access
  to the file's directory and to the resource bundle.
- Full `<head>`: `<meta viewport>`, `color-scheme`, inlined `@font-face`, inlined
  `reader.css`, inlined theme variables.
- **Scroll preservation** across re-render (theme flip, live edit → preview):
  read `window.scrollY` before reload, restore after `didFinish`.
- Navigation delegate: intra-doc `#anchor` scrolls in place; `http(s)` opens in
  the default browser (reuse the existing trace link handler); `file://` routes
  back through Termio's file-preview overlay.
- Transparent background (`drawsBackground = false`) to avoid white flash, like
  `FilePreview.WebPreview`.

### 2. `reader.css` — the reading stylesheet

Standalone, `var(--…)`-driven (same theme-injection mechanism as the trace CSS,
so it tracks any chrome theme). Metrics ported from `prose`, tuned to an Apple/iA
register:

```css
:root { /* injected from TraceTheme — reused verbatim */ }
body.reader {
  max-width: 680px; margin: 0 auto; padding: 56px 32px 140px;
  background: var(--bg); color: var(--fg);
  font: 17px/1.7 "iA Writer Quattro", -apple-system, "SF Pro Text", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
  font-feature-settings: "kern", "liga", "calt";
}
.reader h1 { font-size: 30px; font-weight: 700; letter-spacing: -0.021em; line-height: 1.15; margin: 0 0 0.5em; }
.reader h2 { font-size: 22px; font-weight: 650; letter-spacing: -0.014em; margin: 2em 0 0.6em; padding-bottom: 0.3em; border-bottom: 1px solid var(--line); }
.reader h3 { font-size: 18px; font-weight: 650; margin: 1.7em 0 0.4em; }
.reader p, .reader li { font-size: 17px; }
.reader p { margin: 0 0 1.15em; }
.reader a { color: var(--accent); text-decoration: none; }
.reader a:hover { text-decoration: underline; text-underline-offset: 2px; }
.reader strong { font-weight: 680; }
.reader blockquote { margin: 1.3em 0; padding: 2px 0 2px 18px; border-left: 3px solid var(--accent); color: var(--muted); }
.reader code { font: 0.88em "iA Writer Mono", ui-monospace, "SF Mono", Menlo, monospace; background: var(--soft); border-radius: 5px; padding: 2px 6px; }
.reader pre { background: var(--soft); border: 1px solid var(--line); border-radius: 12px; padding: 18px 20px; margin: 1.3em 0; overflow-x: auto; }
.reader pre code { background: none; padding: 0; font-size: 13.5px; line-height: 1.55; }
.reader img { max-width: 100%; border-radius: 10px; border: 1px solid var(--line); margin: 0.5em 0; }
.reader table { border-collapse: collapse; width: 100%; margin: 1.3em 0; font-size: 15px; }
.reader th, .reader td { border: 1px solid var(--line); padding: 8px 14px; text-align: left; }
.reader th { background: var(--soft); font-weight: 600; }
.reader ul[data-tasklist] { list-style: none; padding-left: 0; }
.reader hr { border: none; border-top: 1px solid var(--line); margin: 2.2em 0; }
```

### 3. Host-side code highlighting (`CodeHighlighter`)

`TraceMarkdown` currently emits fenced code as escaped plain text in
`<pre><code class="language-xxx">`. Add a Swift helper that, per fenced block,
runs highlight.js (already loaded by Highlightr via JavaScriptCore) to produce
the highlighted **HTML string** (`hljs.highlight(code, {language}).value`) and
splices it in. Ship a highlight theme CSS whose token colors are mapped onto
Termio theme vars (or reuse Highlightr's Xcode/Xcode-dark theme for parity with
the editor). Result: no JavaScript runs in the reader web view at all — same
"zero client JS" property that makes Shiki fast, using what we already bundle.

> Requires exposing the raw `.value` HTML from Highlightr's JSContext (it
> currently only vends `NSAttributedString`). Small addition, not a fork.

### 4. Fonts

Add `iA Writer Quattro` (and `Mono` for code) variable `.woff2`/`.ttf` to the
resource bundle under `Editor/Fonts/`, reference via `@font-face` with the bundle
`baseURL`. Keep `-apple-system` first-fallback so the reader never renders
unstyled if a font fails to load. Record the OFL license in the repo's
third-party notices.

### 5. Trusted rendering + images

Add a `trusted: Bool` parameter to `TraceMarkdown.html()`. For **transcripts**
(untrusted tool output) keep today's behavior: escape raw HTML, images → alt
text. For a **user's own file**, `trusted: true` emits real `<img>` and passes
raw HTML through — and combined with the reader's `baseURL`, relative image
paths in a doc resolve. This is the one change to `TraceMarkdown` itself; it must
default to `false` so the trace path is unaffected.

## File changes (estimate)

| File | Change |
| --- | --- |
| `Editor/FileActivation.swift` | Keep `.md` routing to the editor (not preview); add an `isMarkdown(_:)` helper. |
| `Editor/FileEditorView.swift` | Add `Edit/Preview` segmented control (markdown only) + mode state; render `MarkdownReaderView` in Preview. |
| `Editor/MarkdownReaderView.swift` | **New.** The renderer `NSViewRepresentable` (§1). |
| `Editor/MarkdownReaderRenderer.swift` | **New.** Assembles `<head>` + reader.css + theme vars + highlighted body. |
| `Editor/CodeHighlighter.swift` | **New.** Host-side hljs highlight → HTML (§3). |
| `Editor/Highlightr/Highlightr.swift` | Expose raw highlighted-HTML string from JSContext. |
| `Info/TraceMarkdown.swift` | Add `trusted:` flag (default `false`) for images/raw HTML (§5). |
| `Editor/Resources/reader.css`, `Editor/Fonts/*` | **New** bundled assets. |

Theme injection (`TraceTheme` / `themeVariables`) is reused verbatim.

## Open questions

1. **Code theme**: reuse Highlightr's Xcode/Xcode-dark (editor parity) vs. a
   var-mapped theme that follows arbitrary chrome themes? Lean editor-parity for
   v1.
2. **Font weight of Quattro** for body vs. system SF — validate on a Retina
   panel before committing; iA Quattro at 17px may want 1.7+ line-height (set
   above) to breathe.
3. **iOS parity**: the Mac already renders trace HTML that the phone displays
   (`Info/`); the reader could ride the same wire later. Out of scope for v1.
4. **Default mode** for `.md`: Edit (it's source you work on) with last-mode
   remembered per file — confirm.

## Rollout

- **v1**: reader renderer + reader.css + Edit/Preview toggle, `trusted: true`
  images, system SF font, editor-parity code theme. Ships the reading experience.
- **v2**: bundle iA Writer Quattro/Mono; var-mapped code theme; scroll-sync
  between edit and preview.
