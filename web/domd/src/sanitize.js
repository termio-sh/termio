// Raw HTML in a Markdown file is somebody else's text, and this page's CSP allows
// `script-src 'self' 'unsafe-inline'` — an injected <script> would run. So no source
// string ever reaches the DOM: the HTML is parsed into an inert document, walked, and
// rebuilt from allow-listed parts as real nodes. The caller inserts those nodes with
// `replaceChildren`, never `innerHTML`, so nothing is parsed a second time.
//
// The policy mirrors `HTMLSanitizer` in Sources/termio/Info/MarkdownHTML.swift, which
// follows GitHub's html-pipeline SanitizationFilter, so the rendered face and the
// reader agree on what a document may contain. Two deliberate differences are marked
// DIVERGENCE below.

/// GitHub's element allow-list, as the Swift sanitizer has it.
const ALLOWED_TAGS = new Set([
  "h1", "h2", "h3", "h4", "h5", "h6", "br", "b", "i", "strong", "em", "a", "pre",
  "code", "img", "div", "ins", "del", "sup", "sub", "p", "ol", "ul", "li", "table",
  "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "blockquote", "dl", "dt",
  "dd", "kbd", "q", "samp", "var", "hr", "s", "summary", "details", "figure",
  "figcaption", "abbr", "cite", "dfn", "mark", "small", "span", "time", "wbr",
  "picture", "source", "video",
]);

/// DIVERGENCE 1: these are dropped with their whole subtree rather than escaped to
/// visible text. The Swift sanitizer's honesty rule — show the tag you refused — is
/// right for an unknown element, but printing the body of a <script> or <style> as
/// prose is noise, not honesty, and <form>/<iframe> would show their contents as
/// stray text. Nothing here is renderable, so nothing is lost by dropping it.
const DROPPED_SUBTREES = new Set([
  "script", "style", "iframe", "object", "embed", "link", "meta", "base", "form",
  "input", "button", "textarea", "select", "option", "noscript", "template",
  "svg", "math", "frame", "frameset", "applet", "canvas", "audio", "map", "area",
]);

const ALLOWED_ATTRIBUTES = new Set([
  "href", "src", "srcset", "media", "alt", "title", "align", "valign", "width",
  "height", "border", "colspan", "rowspan", "open", "dir", "lang", "start", "type",
  "checked", "disabled", "datetime", "cite", "cellpadding", "cellspacing",
  "controls", "poster", "muted", "loop", "playsinline", "preload",
]);

const URL_ATTRIBUTES = new Set(["href", "src", "srcset", "poster", "cite"]);

/// http / https / mailto / relative — GitHub's protocol allow-list, and the same rule
/// `HTMLSanitizer.safeURL` applies: a colon before any of `/ ? #` means an explicit
/// scheme, so `javascript:`, `data:` and `vbscript:` are all rejected by construction
/// rather than by name. Control characters are rejected outright (scheme smuggling:
/// `java\0script:` and friends).
import { isRemote, remoteImages } from "./remote-images.js";

export function isSafeURL(value, { allowRelative = true } = {}) {
  const trimmed = String(value).trim();
  if (!trimmed) return false;
  for (const ch of trimmed) if (ch.codePointAt(0) < 0x20 || ch.codePointAt(0) === 0x7f) return false;
  const lower = trimmed.toLowerCase();
  if (lower.startsWith("http://") || lower.startsWith("https://") ||
      lower.startsWith("mailto:") || lower.startsWith("termio-domd:")) return true;
  if (!allowRelative) return false;
  const colon = trimmed.indexOf(":");
  if (colon >= 0) {
    const before = trimmed.slice(0, colon);
    // A scheme is only a scheme if no path/query/fragment separator precedes it.
    if (!/[/?#]/.test(before)) return false;
  }
  return true;
}

/// A repo-relative image reference routed to the host's scheme handler, which is the
/// only way bytes off disk reach this page. Markdown `![]()` images go through the
/// kernel's imageLoader; an `<img>` inside a raw HTML block does not, so it is
/// rewritten here to the same destination.
function resolveImageSource(value) {
  const trimmed = String(value).trim();
  // A remote image is held until the reader asks for it — see remote-images.js.
  if (isRemote(trimmed)) return remoteImages().resolve(trimmed);
  if (/^(data:|termio-domd:|blob:)/i.test(trimmed)) return trimmed;
  if (!isSafeURL(trimmed)) return null;
  return `termio-domd:///img/${encodeURIComponent(trimmed.replace(/^\.\//, ""))}`;
}

function copyAttributes(source, target) {
  for (const { name, value } of Array.from(source.attributes)) {
    const key = name.toLowerCase();
    // Event handlers can never survive, whatever else the allow-list says.
    if (key.startsWith("on")) continue;
    if (!ALLOWED_ATTRIBUTES.has(key)) continue;
    if (key === "srcset") continue;        // candidate lists are not worth parsing; drop
    if (key === "src" && target.tagName === "IMG") {
      const resolved = resolveImageSource(value);
      if (resolved) target.setAttribute("src", resolved);
      continue;
    }
    if (URL_ATTRIBUTES.has(key)) {
      if (!isSafeURL(value)) continue;
      target.setAttribute(key, String(value).trim());
      continue;
    }
    target.setAttribute(key, value);
  }
}

function convert(node, doc, into) {
  if (node.nodeType === Node.TEXT_NODE) {
    into.appendChild(doc.createTextNode(node.nodeValue));
    return;
  }
  // DIVERGENCE 2: comments are dropped here as they are in the reader
  // (`MarkdownHTML.swift:837`), so an editorial note in a README stays invisible.
  if (node.nodeType === Node.COMMENT_NODE) return;
  if (node.nodeType !== Node.ELEMENT_NODE) return;

  const tag = node.tagName.toLowerCase();
  if (DROPPED_SUBTREES.has(tag)) return;

  if (!ALLOWED_TAGS.has(tag)) {
    // The reader's honesty rule: show the tag that was refused rather than
    // silently swallowing content. Emitted as TEXT, so it cannot become markup.
    into.appendChild(doc.createTextNode(`<${tag}>`));
    for (const child of Array.from(node.childNodes)) convert(child, doc, into);
    into.appendChild(doc.createTextNode(`</${tag}>`));
    return;
  }

  const element = doc.createElement(tag);
  copyAttributes(node, element);
  for (const child of Array.from(node.childNodes)) convert(child, doc, element);
  into.appendChild(element);
}

/// Parse `html` inertly and return a DocumentFragment of allow-listed nodes.
///
/// `DOMParser` with "text/html" builds a document that is never connected to a
/// browsing context: its scripts do not run, its images do not load, and its
/// `on*` handlers are never registered. Only rebuilt nodes leave this function.
export function sanitizeHTMLFragment(html) {
  const fragment = document.createDocumentFragment();
  let parsed;
  try {
    parsed = new DOMParser().parseFromString(String(html), "text/html");
  } catch {
    // A parser that refuses the input renders as nothing rather than as markup.
    return fragment;
  }
  for (const child of Array.from(parsed.body.childNodes)) {
    convert(child, document, fragment);
  }
  return fragment;
}
