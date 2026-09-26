import { createElement as h, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { sanitizeHTMLFragment } from "./sanitize.js";
import { isIncompleteLoad } from "./hydration.js";
import { installViewer } from "./viewer.js";
import { isRemote, remoteImages } from "./remote-images.js";
import { installRemoteNotice } from "./remote-notice.js";
import { EMOJI_SHORTCODES } from "./emoji.js";
import {
  DOMDProvider, DOMD, MarkdownType, RenderChildren, viewOnlyProps,
  getRenderElementProps, getSpanRenderIdProps, serializeRenderData, toMarkdown,
  defaultInlineRules, useEditorStoreApi,
} from "@do-md/core-react";

// The one channel back to Swift. Absent when the page is opened outside a
// WKWebView (the browser harness), where every post is a no-op.
const bridge = globalThis.webkit?.messageHandlers?.domd ?? null;
const post = (message) => { try { bridge?.postMessage(message); } catch { /* the host went away */ } };

// ---------------------------------------------------------------------------
// math — $…$ / $$…$$ through inlineRules, rendered by the vendored KaTeX to
// MathML, the same output mode MarkdownScripting.swift uses.
// ---------------------------------------------------------------------------

// GitHub's rule, the one MarkdownHTML.extractMath already implements: the
// delimiters must hug their content, so `$30 and $50` stays prose.
const hugsContent = (s) => s.length > 0 && !/^\s/.test(s) && !/\s$/.test(s);

function renderTeX(tex, display) {
  const katex = globalThis.katex;
  if (!katex) return null;
  try {
    return katex.renderToString(tex, { output: "mathml", displayMode: display, throwOnError: true });
  } catch {
    return null;   // malformed TeX falls back to its own source
  }
}

function MathSpan({ domProps, children, contentText }) {
  const delimiter = domProps["data-inline-rule"] ?? "$";
  const display = delimiter === "$$";
  const body = display ? contentText.trim() : contentText;
  const html = hugsContent(body) ? renderTeX(body, display) : null;
  if (!html) {
    // Not math. The kernel hides MdSymbol delimiters with `display:none`, so
    // they are re-emitted as decoration or the `$` signs vanish from the prose.
    return h("span", domProps,
      h("span", viewOnlyProps, delimiter), children, h("span", viewOnlyProps, delimiter));
  }
  return h("span", domProps,
    h("span", { className: "domd-math-source" }, children),
    h("span", { ...viewOnlyProps, className: display ? "domd-math domd-math-display" : "domd-math",
                dangerouslySetInnerHTML: { __html: html } }));
}

const MATH_BLOCK  = { open: "$$", close: "$$", exactLen: true, allowSpace: true, parseInner: false,
                      tagName: "span", className: "domd-math-block", component: MathSpan };
const MATH_INLINE = { open: "$", close: "$", exactLen: true, allowSpace: true, parseInner: false,
                      tagName: "span", className: "domd-math-inline", component: MathSpan };
// Reserved `[` delimiter: longest-prefix precedence means `[^1]` fires here
// while `[link](url)` still parses as a link.
const FOOTNOTE_REF = { open: "[^", close: "]", exactLen: true, allowSpace: false, parseInner: false,
                       tagName: "sup", className: "domd-footnote-ref" };


// ---------------------------------------------------------------------------
// mermaid — renderComponent[Pre], dispatched on the fence lang
// ---------------------------------------------------------------------------

/// The palette mermaid draws in, taken from the page's own theme tokens so a
/// diagram can never disagree with the prose around it. Mirrors
/// MermaidRenderer.Theme in Sources/termio/Info/MermaidRenderer.swift.
function diagramTheme() {
  const css = getComputedStyle(document.documentElement);
  const token = (name, fallback) => (css.getPropertyValue(name) || fallback).trim();
  const dark = document.documentElement.dataset.appearance === "dark";
  return {
    background: token("--domd-page-bg", "#ffffff"),
    panel: token("--domd-panel", "#f5f5f7"),
    foreground: token("--domd-page-fg", "#1d1d1f"),
    muted: dark ? "rgba(255,255,255,0.55)" : "rgba(0,0,0,0.55)",
    line: dark ? "rgba(255,255,255,0.22)" : "rgba(0,0,0,0.22)",
  };
}

function initMermaid() {
  const mermaid = globalThis.mermaid;
  if (!mermaid) return null;
  const t = diagramTheme();
  mermaid.initialize({
    startOnLoad: false, securityLevel: "strict", htmlLabels: false,
    flowchart: { htmlLabels: false }, theme: "base",
    fontFamily: "-apple-system, system-ui, sans-serif",
    themeVariables: {
      background: t.background, mainBkg: t.panel, primaryColor: t.panel,
      primaryTextColor: t.foreground, primaryBorderColor: t.line,
      secondaryColor: t.panel, tertiaryColor: t.background,
      lineColor: t.muted, textColor: t.foreground,
      // Without this an edge label keeps a light box on a dark page.
      edgeLabelBackground: t.panel,
      noteBkgColor: t.panel, noteTextColor: t.foreground, noteBorderColor: t.line,
      labelBoxBkgColor: t.panel, labelTextColor: t.foreground,
    },
  });
  return mermaid;
}

let diagramSeq = 0;
function Mermaid({ source, appearance }) {
  const [svg, setSvg] = useState(null);
  const [failed, setFailed] = useState(null);
  useEffect(() => {
    let live = true;
    const mermaid = initMermaid();
    if (!mermaid) { setFailed("mermaid is unavailable"); return; }
    mermaid.render(`domd-diagram-${diagramSeq++}`, source)
      .then((out) => { if (live) { setSvg(out.svg); setFailed(null); } })
      .catch((error) => { if (live) setFailed(String(error?.message ?? error)); });
    return () => { live = false; };
  }, [source, appearance]);
  if (failed) return h("div", { className: "domd-diagram-failed" }, failed);
  if (!svg) return h("div", { className: "domd-diagram-pending" }, "…");
  return h("div", { className: "domd-diagram", dangerouslySetInnerHTML: { __html: svg } });
}

function makePre(appearance) {
  return function PreBlock({ parsedData }) {
    const lang = String(serializeRenderData(parsedData).props?.className ?? "")
      .replace(/^language-/, "");
    const rootProps = { ...getRenderElementProps(parsedData), ...getSpanRenderIdProps(parsedData) };
    if (lang !== "mermaid") return h("pre", rootProps, h(RenderChildren, { parsedData }));
    const source = toMarkdown(parsedData)
      .replace(/^```mermaid[^\n]*\n/, "").replace(/\n?```\s*$/, "");
    return h("div", { ...rootProps, className: `${rootProps.className ?? ""} domd-mermaid` },
      // The fence text stays in the DOM — hidden, never dropped. It is the only
      // thing toMarkdown reads back.
      h("pre", { className: "domd-mermaid-source" }, h(RenderChildren, { parsedData })),
      h("div", viewOnlyProps, h(Mermaid, { source, appearance })));
  };
}

// ---------------------------------------------------------------------------
// syntax highlighting — codeTokenizer, backed by the vendored highlight.js
// ---------------------------------------------------------------------------

/// highlight.js emits HTML classed `hljs-keyword`; the kernel wants Prism-shaped
/// tokens and renders a token's `type` as `class="token <type>"` — but only for the
/// type names it knows. Measured: a token typed `hljs-keyword` comes out
/// `class=""`, so the hljs vocabulary has to be translated into Prism's.
///
/// This map is the only place that translation lives. It types the tokens AND, below,
/// rewrites the selectors of the reader's own stylesheet, so the colours still come
/// from one file (`MarkdownSkin.highlightTheme`) rather than being transcribed into a
/// second palette that can drift.
const HLJS_TO_PRISM = {
  "hljs-keyword": "keyword", "hljs-built_in": "builtin", "hljs-type": "class-name",
  "hljs-literal": "boolean", "hljs-number": "number", "hljs-operator": "operator",
  "hljs-punctuation": "punctuation", "hljs-string": "string", "hljs-comment": "comment",
  "hljs-doctag": "comment", "hljs-meta": "atrule", "hljs-title": "function",
  "hljs-function_": "function", "hljs-class_": "class-name", "hljs-params": "variable",
  "hljs-attr": "attr-name", "hljs-attribute": "attr-name", "hljs-variable": "variable",
  "hljs-property": "property", "hljs-regexp": "regex", "hljs-symbol": "symbol",
  "hljs-selector-tag": "selector", "hljs-selector-class": "selector",
  "hljs-selector-id": "selector", "hljs-selector-attr": "selector",
  "hljs-tag": "tag", "hljs-name": "tag", "hljs-section": "important",
  "hljs-addition": "inserted", "hljs-deletion": "deleted", "hljs-emphasis": "italic",
  "hljs-strong": "bold", "hljs-link": "url", "hljs-char": "char",
  "hljs-subst": "variable", "hljs-template-variable": "variable",
  "hljs-template-tag": "tag", "hljs-quote": "comment", "hljs-bullet": "punctuation",
  "hljs-code": "string", "hljs-formula": "string",
};

/// The first class on the span that the kernel will actually honour. hljs emits
/// compound classes (`hljs-title function_`), so each is tried in order.
function prismType(className) {
  for (const cls of String(className).split(/\s+/)) {
    const mapped = HLJS_TO_PRISM[cls] ?? HLJS_TO_PRISM["hljs-" + cls];
    if (mapped) return mapped;
  }
  return "";
}

function tokensFrom(node) {
  const out = [];
  for (const child of Array.from(node.childNodes)) {
    if (child.nodeType === Node.TEXT_NODE) {
      if (child.nodeValue) out.push(child.nodeValue);
      continue;
    }
    if (child.nodeType !== Node.ELEMENT_NODE) continue;
    const inner = tokensFrom(child);
    out.push({
      type: prismType(child.getAttribute("class") || ""),
      content: inner.length === 1 && typeof inner[0] === "string" ? inner[0] : inner,
    });
  }
  return out;
}

/// Runs on every parse of every fence, so it bails cheaply on anything it cannot
/// colour and never throws into the parse pipeline — an unknown language or a
/// malformed fence renders as plain code rather than breaking the document.
function codeTokenizer(code, lang) {
  const hljs = globalThis.hljs;
  if (!hljs || !lang || !code) return [code];
  const language = String(lang).toLowerCase();
  try {
    if (!hljs.getLanguage(language)) return [code];
    const html = hljs.highlight(code, { language, ignoreIllegals: true }).value;
    // Parsed inertly, the same way raw HTML is — hljs output carries the document's
    // own text and nothing here is ever handed to innerHTML.
    const parsed = new DOMParser().parseFromString(`<pre>${html}</pre>`, "text/html");
    const host = parsed.querySelector("pre");
    const tokens = host ? tokensFrom(host) : [];
    return tokens.length ? tokens : [code];
  } catch {
    return [code];
  }
}

/// Install the reader's highlight stylesheet, with its `.hljs-*` selectors rewritten
/// to the `.token.*` the kernel emits. The host hands over
/// `MarkdownSkin.highlightTheme(dark:)` unchanged; only the selectors move, so a
/// colour is still defined in exactly one place.
globalThis.termioDomdSetHighlightTheme = (css) => {
  const rewritten = String(css).replace(/\.hljs-([a-z_]+)/g, (whole, name) => {
    const mapped = HLJS_TO_PRISM["hljs-" + name];
    return mapped ? `.token.${mapped}` : whole;
  });
  let style = document.getElementById("domd-highlight");
  if (!style) {
    style = document.createElement("style");
    style.id = "domd-highlight";
    document.head.appendChild(style);
  }
  style.textContent = rewritten;
};

// ---------------------------------------------------------------------------
// GitHub alerts — renderComponent[Blockquote]
// ---------------------------------------------------------------------------

const ALERT_KINDS = new Set(["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]);

function Alert({ parsedData }) {
  const match = /^>\s*\[!(\w+)\]/.exec(toMarkdown(parsedData));
  const kind = match && ALERT_KINDS.has(match[1].toUpperCase()) ? match[1].toUpperCase() : null;
  const rootProps = { ...getRenderElementProps(parsedData), ...getSpanRenderIdProps(parsedData) };
  if (!kind) return h("blockquote", rootProps, h(RenderChildren, { parsedData }));
  return h("blockquote",
    { ...rootProps, className: `${rootProps.className ?? ""} domd-alert`, "data-alert": kind },
    h("span", { ...viewOnlyProps, className: "domd-alert-badge" },
      kind.charAt(0) + kind.slice(1).toLowerCase()),
    h(RenderChildren, { parsedData }));
}

// ---------------------------------------------------------------------------
// raw HTML blocks — renderComponent[MarkdownType.HTML]
// ---------------------------------------------------------------------------

/// A raw HTML block, rendered rather than printed.
///
/// The kernel parses a block of raw HTML into ONE `HTML` leaf carrying the whole
/// source, and its default rendering is that source as literal text — which is why a
/// README whose header is a `<div align="center">` used to flatten into a wall of
/// prose, taking its logo, badges and links with it.
///
/// The source text stays in the DOM, hidden, exactly as the mermaid fence does: it is
/// what `toMarkdown` reads back, so rendering here cannot change a single byte of the
/// document. The rendered markup is decoration, carries `viewOnlyProps`, and is built
/// from sanitized nodes — never from a source string (see sanitize.js).
function HTMLBlock({ parsedData }) {
  const source = serializeRenderData(parsedData).text ?? toMarkdown(parsedData);
  const host = useRef(null);
  useEffect(() => {
    const node = host.current;
    if (!node) return;
    node.replaceChildren(sanitizeHTMLFragment(source));
  }, [source]);
  const rootProps = { ...getRenderElementProps(parsedData), ...getSpanRenderIdProps(parsedData) };
  return h("div", { ...rootProps, className: `${rootProps.className ?? ""} domd-html` },
    h("div", { className: "domd-html-source" }, h(RenderChildren, { parsedData })),
    h("div", { ...viewOnlyProps, ref: host, className: "domd-html-rendered" }));
}

/// `<!-- … -->` outside a raw HTML block is ordinary paragraph text to the kernel, so
/// the 70-line editorial note at the top of a design doc rendered as body prose. The
/// reader drops comments (`MarkdownHTML.swift:837`); this matches it. The delimiter is
/// strictly longer than the builtin `<`, which is what lets a reserved opener fire.
const HTML_COMMENT = { open: "<!--", close: "-->", allowSpace: true, parseInner: false,
                       tagName: "span", className: "domd-comment", component: HTMLComment };

function HTMLComment({ domProps, children }) {
  // The comment text stays in the DOM (hidden) so the round trip still sees it.
  return h("span", { ...domProps, className: `${domProps.className ?? ""} domd-comment` },
    h("span", { className: "domd-comment-source" }, children));
}

/// `:rocket:` and friends, which the reader already converts.
///
/// A bare `:` pair is far too common in prose for the delimiter alone to decide —
/// `a:b:c` matches the rule perfectly well. The name is what decides: an unknown
/// shortcode renders as its own literal text, delimiters re-emitted, the same guard
/// the `$…$` math rule uses for currency.
function EmojiSpan({ domProps, children, contentText }) {
  const glyph = EMOJI_SHORTCODES[contentText];
  if (!glyph) {
    return h("span", domProps,
      h("span", viewOnlyProps, ":"), children, h("span", viewOnlyProps, ":"));
  }
  return h("span", domProps,
    h("span", { className: "domd-emoji-source" }, children),
    h("span", { ...viewOnlyProps, className: "domd-emoji" }, glyph));
}

const EMOJI = { open: ":", close: ":", exactLen: true, allowSpace: false, parseInner: false,
                tagName: "span", className: "domd-emoji-span", component: EmojiSpan };

/// Declared here, after every rule above it: these are `const`, so listing them
/// before their declarations is a temporal-dead-zone error and the whole set silently
/// fails to register.
const INLINE_RULES = [...defaultInlineRules, MATH_BLOCK, MATH_INLINE, FOOTNOTE_REF,
                      HTML_COMMENT, EMOJI];

// ---------------------------------------------------------------------------
// images — the host's scheme handler serves the document's own folder
// ---------------------------------------------------------------------------

const imageLoader = async (src) => {
  // Markdown images take the same rule as images inside raw HTML: remote is held
  // until the reader asks, local is served by the host's scheme handler.
  if (isRemote(src)) return remoteImages().resolve(src);
  if (/^(data:|blob:|termio-domd:)/.test(src)) return src;
  return `termio-domd:///img/${encodeURIComponent(src)}`;
};

// ---------------------------------------------------------------------------
// the host bridge
// ---------------------------------------------------------------------------

/// Swift owns the document; this component is the seam. It never renders.
///
/// The ownership rule the host depends on: while this face is the visible one
/// it is the single writer of the buffer, and it reports every change back on a
/// short debounce so auto-save and the dirty flag stay honest. `load` is the
/// only way text comes the other way, and it marks the text as host-authored so
/// the change it causes is not echoed back as a user edit.
function Bridge({ markdown, editable }) {
  const store = useEditorStoreApi();
  useEffect(() => {
    if (!store) return;

    // Whether the kernel is holding the whole document. Until it is, this face is
    // not a source of truth for anything and `flush` refuses — see hydration.js for
    // why completeness has to be inferred rather than awaited.
    let hydrated = false;

    // The baseline is the document as the KERNEL holds it, not as the host sent
    // it. domd re-serializes canonically — a table re-pads its columns — so the
    // raw host text and the parsed document differ for most real files. Baselining
    // on the raw text would make merely opening such a file look like an edit, and
    // the host would auto-save re-padded tables over a document nobody touched.
    // Consent is per document: a new one starts held again.
    remoteImages().reset();

    const baseline = (text) => {
      // resetMD is the synchronous full-document path. initMd and resetMDChunked
      // hydrate progressively and would leave a truncated document here; the guard
      // below is what stops that ever reaching the host, whichever path is used.
      store.resetMD(text);
      const serialized = toMarkdown(store.renderData_);
      hydrated = !isIncompleteLoad(text, serialized);
      if (!hydrated) post({ type: "error", message: "The document did not load completely." });
      return serialized;
    };
    let hostAuthored = baseline(markdown);

    let timer = null;
    /// The document if the user has actually changed it, `null` if not. The host
    /// adopts a non-null answer and leaves its buffer alone otherwise, so a flip
    /// through this face never rewrites a file on canonicalization alone.
    ///
    /// Asynchronous because it must be: the kernel renders typed text
    /// speculatively into the DOM and commits it to the model on its own
    /// debounce, so reading `renderData_` straight after a keystroke can miss the
    /// last few characters. `flushPendingInput` is the kernel's own remedy and
    /// the host has to await it — this is exactly the flip that would otherwise
    /// eat the edits just made.
    const flush = async () => {
      if (timer !== null) { clearTimeout(timer); timer = null; }
      // The refusal that matters: a half-loaded document serializes to a PREFIX of
      // the real one, and because `flush` only answers null when nothing CHANGED, a
      // truncation would otherwise look like a legitimate edit and be written to
      // disk. `null` already means "the page could not answer, keep the buffer you
      // have" on the host side, so the safe path is the one this takes.
      if (!hydrated) return null;
      await store.flushPendingInput();
      const current = toMarkdown(store.renderData_);
      if (current === hostAuthored) return null;
      hostAuthored = current;
      post({ type: "edit", markdown: current });
      return current;
    };

    const schedule = () => {
      if (!editable || !hydrated) return;
      if (timer !== null) clearTimeout(timer);
      timer = setTimeout(() => { void flush(); }, 180);
    };

    // Two triggers, because neither alone is sufficient.
    //
    // The op stream is the model's own signal, and it carries programmatic and
    // collaborative changes — but it does not fire for ordinary typing: the
    // kernel renders a keystroke speculatively into the DOM and commits it to
    // the model separately, and that commit emits nothing. Measured against
    // 0.12.3: type into the page, wait two seconds, and the subscription has not
    // been called even though `toMarkdown` already shows the character.
    //
    // `input` on the editable root is the signal that never misses a keystroke,
    // so it is what actually drives auto-save. The debounce then coalesces a
    // burst of typing into one report, and `flush` awaits `flushPendingInput`
    // before reading, so the model is caught up by the time it is sampled.
    const unsubscribe = store.subscribeRenderDataOps(schedule);
    const root = document.querySelector("[data-domd-root]");
    root?.addEventListener("input", schedule);
    root?.addEventListener("compositionend", schedule);

    // The flip out of this face calls this and waits for the answer, so an edit
    // made in the last few milliseconds can never be lost to the debounce.
    // Diagnostics for the one question a screenshot cannot answer: did the click reach
    // the page, and did a caret follow? Costs nothing until something goes wrong, and
    // tells "never arrived" apart from "arrived, no caret".
    const onPointerDown = (event) => {
      const target = event.target instanceof Element ? event.target : null;
      const inEditor = !!target?.closest("[data-domd-root]");
      post({ type: "diagnostic",
             message: `mousedown on ${target?.tagName?.toLowerCase() ?? "?"}`
                    + ` inEditor=${inEditor} editable=${editable}` });
      if (inEditor) return;
      if (target?.closest(".domd-lightbox, .domd-zoom")) return;
      // Outside the editable box but inside the page: hand the caret to the document.
      store.focus();
    };
    document.addEventListener("pointerdown", onPointerDown);
    const onSelectionChange = () => {
      const sel = document.getSelection();
      if (!sel || !sel.anchorNode) return;
      post({ type: "diagnostic", message: `caret at offset ${sel.anchorOffset}` });
    };
    document.addEventListener("selectionchange", onSelectionChange, { once: true });

    globalThis.termioDomd = {
      flush,
      markdown: () => toMarkdown(store.renderData_),
      isHydrated: () => hydrated,
      /// Let this document's remote images in. Re-parsing is what re-runs both image
      /// paths (the kernel's imageLoader and the raw-HTML sanitizer) against the new
      /// answer; the text is unchanged, so no edit is reported.
      allowRemoteImages: () => {
        if (!remoteImages().unlock()) return false;
        store.resetMD(toMarkdown(store.renderData_));
        return true;
      },
      load: (text) => {
        if (timer !== null) { clearTimeout(timer); timer = null; }
        // A different document is a different consent: what the reader allowed for the
        // last file says nothing about this one.
        remoteImages().reset();
        hostAuthored = baseline(text);
      },
    };
    post({ type: "ready" });

    return () => {
      if (timer !== null) clearTimeout(timer);
      unsubscribe();
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("selectionchange", onSelectionChange);
      root?.removeEventListener("input", schedule);
      root?.removeEventListener("compositionend", schedule);
      delete globalThis.termioDomd;
    };
  }, [store, markdown, editable]);
  return null;
}

function App() {
  const [state, setState] = useState(() => globalThis.__domdInitialState ?? {
    markdown: "", editable: false, appearance: "light", cjk: false,
  });
  useEffect(() => {
    // Theme and editability can change under a mounted page; the document
    // cannot — a new document remounts the whole face from Swift.
    globalThis.termioDomdConfigure = (next) => setState((prev) => ({ ...prev, ...next }));
    return () => { delete globalThis.termioDomdConfigure; };
  }, []);
  useEffect(() => { document.documentElement.dataset.appearance = state.appearance; },
            [state.appearance]);
  // The CJK register is a class on the root, decided by the host from the document
  // (see MarkdownReaderRenderer.isCJK) rather than guessed in CSS — CSS cannot tell
  // Han from Latin mid-paragraph, and loosening the leading for everyone would make
  // English lists drift apart.
  useEffect(() => { document.documentElement.classList.toggle("cjk", !!state.cjk); },
            [state.cjk]);

  const renderComponent = useMemo(
    () => ({
      [MarkdownType.Pre]: makePre(state.appearance),
      [MarkdownType.Blockquote]: Alert,
      [MarkdownType.HTML]: HTMLBlock,
    }),
    [state.appearance]);

  // Overrides and inline rules are fixed at construction, so a theme flip
  // remounts the provider rather than trying to hot-swap them.
  // A click that lands beside the column — the page margins, the tail padding — is a
  // click at the document, and every editor treats it as one. The kernel's own
  // `focus()` puts the caret where it belongs (its last position, or the end of the
  // document when there is none) without this having to reason about coordinates.
  return h(DOMDProvider,
    { key: `${state.appearance}-${state.editable}`, initMd: "", editable: state.editable,
      renderComponent, inlineRules: INLINE_RULES, imageLoader, codeTokenizer },
    h(Bridge, { markdown: state.markdown, editable: state.editable }),
    h(DOMD));
}

installViewer(post);
installRemoteNotice();

const mount = document.getElementById("root");
if (mount) createRoot(mount).render(h(App));
else post({ type: "error", message: "the page has no mount point" });

addEventListener("error", (event) => post({ type: "error", message: String(event.message) }));
