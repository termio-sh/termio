# Vendored domd

The rendered Markdown face of `FileEditorView` (`MarkdownEditorView.swift`) is a
`WKWebView` running [do-md/domd](https://github.com/do-md/domd)
`@do-md/core-react` **0.12.3** — a Markdown-native WYSIWYG kernel where the
Markdown text *is* the model, so the rendered face edits the same bytes the
source face does rather than a converted document.

`app.js` is a built bundle: the kernel, React 19.3.0, react-dom and immer,
compiled to one IIFE (`esbuild --bundle --format=iife`). The build input lives
in `.domd-proto/app/src` on the prototype branch. IIFE rather than ESM because
a `WKWebView` loading over a custom scheme gets no module CORS.

`domd.css` is the kernel's own `style.css`, verbatim. `app.css` is termio's —
theme tokens, the math / mermaid / alert / front-matter faces. The kernel is
**unmodified**; everything termio adds goes through its documented injection
points (`inlineRules`, `renderComponent`, `imageLoader`).

`katex.min.js` and `mermaid.min.js` are not duplicated here — the page loads the
copies already in `../assets/`, served by `DomdSchemeHandler`.

Why vendored instead of an SPM dependency: this is a web bundle, not a Swift
package, and it ships as a resource. See `../../Editor/Highlightr/README.md` for
the resource-bundle rule that governs both.

## Upstream license (GPL-3.0-only, with additional permissions)

The kernel is GPL-3.0-only. `LICENSE` and `LICENSE-EXCEPTIONS.md` ship beside it
here, unmodified, as those terms require.

termio relies on the **FOSS License Exception** (`LICENSE-EXCEPTIONS.md` §2),
which permits combining the kernel with a work under any license on its FOSS
list — MIT among them — and conveying the combination under that license. Unlike
the small-entity exception in §1, it carries no revenue or funding threshold.

Its conditions, which constrain this directory:

- The kernel stays under the GPL and **must not be modified**. Its complete
  corresponding source is the public repository named above, at version 0.12.3.
- The combined work may contain **no other GPL code**. Everything else in the
  bundle is MIT (React, immer, KaTeX, mermaid).
- Every copyright, license and attribution notice stays intact, and `LICENSE`
  and `LICENSE-EXCEPTIONS.md` are conveyed with it — which is why both files are
  here and shipped.

Bumping the kernel version means re-reading `LICENSE-EXCEPTIONS.md`: the holder
may narrow these permissions for future versions, though never retroactively.
