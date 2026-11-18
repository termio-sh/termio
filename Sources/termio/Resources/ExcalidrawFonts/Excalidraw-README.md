# Excalidraw renderer and fonts

Vendored from [@excalidraw/excalidraw](https://github.com/excalidraw/excalidraw)
0.18.1 (MIT), in two pieces:

- `../assets/excalidraw-render.js` — a single-file IIFE exposing
  `window.termioRenderExcalidraw`, built from the package's `exportToSvg` and
  `loadFromBlob` exports. Loaded by `ExcalidrawRenderer` into its offscreen
  harness; nothing else in termio runs it.
- `*.woff2` — the subset faces a drawing's text is set in, declared as
  `@font-face` by `ExcalidrawReaderRenderer`. The manifest that pairs each file
  with its family and `unicode-range` is `../assets/excalidraw-fonts.json`,
  extracted from the same package build.

## Rebuilding

The bundle is not `@excalidraw/excalidraw` as published — that entry statically
reaches the editor's 57 UI locales and the mermaid-to-excalidraw importer
(which drags in mermaid, cytoscape and katex). The export path calls none of
it, so both are stubbed at build time, taking the bundle from 8.2MB to 2.9MB.

```sh
npm i @excalidraw/excalidraw@0.18.1 react react-dom esbuild
esbuild entry.js --bundle --format=iife --minify \
  --define:process.env.NODE_ENV='"production"' --outfile=excalidraw-render.js
```

`entry.js` is the whole of the termio-side source:

```js
import { exportToSvg, loadFromBlob } from "@excalidraw/excalidraw";

// A drawing ships in one of three containers: the scene as JSON, embedded in an
// SVG's <metadata>, or in a PNG's tEXt chunk. Which one is decided by sniffing the
// bytes, not by the file's extension — `.excalidraw` is conventional, not enforced,
// and feeding one container's bytes to another's decoder is pathologically slow
// (a 145KB PNG offered to the JSON and SVG decoders takes ~40s to be rejected).
function containersFor(bytes) {
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    return ["image/png"];
  }
  // Text, so it is JSON or SVG; the first non-space character says which. The other
  // is kept as a fallback only because both are cheap to reject.
  const head = new TextDecoder().decode(bytes.subarray(0, 512)).trimStart();
  return head.startsWith("<")
    ? ["image/svg+xml", "application/json"]
    : ["application/json", "image/svg+xml"];
}

// Nothing but whitespace — the file `touch` or a New File command leaves behind. It is a
// drawing with no elements yet, not a file that failed to decode, so it never reaches a
// decoder (which would reject it) and resolves to an empty scene instead.
function isBlank(bytes) {
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] > 0x20) return false;
  }
  return true;
}

async function loadScene(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  if (isBlank(bytes)) return { elements: [] };
  let lastError;
  for (const type of containersFor(bytes)) {
    try {
      const body = type === "image/png" ? bytes : new TextDecoder().decode(bytes);
      return await loadFromBlob(new Blob([body], { type }), null, null);
    } catch (error) { lastError = error; }
  }
  throw new Error(lastError ? lastError.message : "no excalidraw scene in this file");
}

// Returns `{ empty }` for a drawing with nothing in it and `{ empty: false, svg }`
// otherwise; a file that holds no scene at all throws, and the host shows it as source.
// The distinction is the host's to render: an empty drawing is a normal state, a file that
// won't decode is not, and `exportToSvg` on no elements returns only a padding-sized box
// that would read as a broken render.
window.termioRenderExcalidraw = async (base64, options) => {
  const scene = await loadScene(base64);
  const elements = (scene.elements || []).filter((element) => !element.isDeleted);
  if (elements.length === 0) return { empty: true };
  const svg = await exportToSvg({
    elements,
    appState: {
      ...(scene.appState || {}),
      // No background rect: the page behind the drawing is already the app's canvas, and
      // in dark mode Excalidraw's theme filter (`invert(93%) hue-rotate(180deg)`) is
      // applied to the whole SVG — so a background painted here would be inverted back
      // to a light grey slab sitting on a dark page.
      exportBackground: false,
      exportWithDarkMode: !!options.dark,
      exportEmbedScene: false,
    },
    files: scene.files || {},
    exportPadding: 24,
    // Declared once by the page that shows the result instead: inlining awaits a font
    // fetch that never resolves offline, and would repeat woff2 in every drawing.
    skipInliningFonts: true,
    // An embeddable element carries a third-party URL. Rendering it would put a live
    // iframe in a page that shows somebody else's file; it draws as a placeholder.
    renderEmbeddables: false,
  });
  return { empty: false, svg: svg.outerHTML };
};
```

The `Xiaolai` CJK face is deliberately not shipped: it is 12MB of woff2, and
macOS resolves CJK text through a system fallback without it.

## Upstream license (MIT)

```
MIT License

Copyright (c) 2020 Excalidraw

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The bundled faces carry their own licenses upstream: Excalifont, Virgil and
Comic Shanns are OFL/MIT per `excalidraw/excalidraw`'s `public/fonts`, and
Nunito, Lilita One, Cascadia Code and Liberation Sans are OFL.
