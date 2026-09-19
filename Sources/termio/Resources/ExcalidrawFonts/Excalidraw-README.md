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
esbuild entry.jsx --bundle --format=iife --minify \
  --define:process.env.NODE_ENV='"production"' --outfile=excalidraw-render.js
```

`entry.js` is the whole of the termio-side source:

```jsx
import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw, exportToBlob, exportToSvg, loadFromBlob, loadLibraryFromBlob,
  serializeAsJSON, serializeLibraryAsJSON, THEME,
} from "@excalidraw/excalidraw";
import "./node_modules/@excalidraw/excalidraw/dist/prod/index.css";

// ---------------------------------------------------------------- containers

const DEFAULT_BACKGROUND = "#ffffff";

const JSON_TYPE = "application/json";
const SVG_TYPE = "image/svg+xml";
const PNG_TYPE = "image/png";

function bytesFromBase64(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64FromBytes(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

// Nothing but whitespace — the file a New File command leaves behind. An empty drawing,
// not a file that failed to decode, so it never reaches a decoder (which would reject it).
function isBlank(bytes) {
  for (let i = 0; i < bytes.length; i++) if (bytes[i] > 0x20) return false;
  return true;
}

// Which container these bytes are, decided by sniffing rather than by the file's
// extension: `.excalidraw` is conventional, not enforced, and feeding one container's
// bytes to another's decoder is pathologically slow (a 145KB PNG offered to the JSON and
// SVG decoders takes ~40s to be rejected).
function containersFor(bytes) {
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    return [PNG_TYPE];
  }
  const head = new TextDecoder().decode(bytes.subarray(0, 512)).trimStart();
  return head.startsWith("<") ? [SVG_TYPE, JSON_TYPE] : [JSON_TYPE, SVG_TYPE];
}

/// Decodes a file into `{ scene, container }`. `container` is what the bytes turned out to
/// be, so a save can write the same shape back rather than silently converting the file.
async function loadScene(base64, declaredContainer) {
  const bytes = bytesFromBase64(base64);
  if (isBlank(bytes)) return { scene: { elements: [] }, container: declaredContainer || JSON_TYPE };
  let lastError;
  for (const container of containersFor(bytes)) {
    try {
      const body = container === PNG_TYPE ? bytes : new TextDecoder().decode(bytes);
      const scene = await loadFromBlob(new Blob([body], { type: container }), null, null);
      return { scene, container };
    } catch (error) { lastError = error; }
  }
  throw new Error(lastError ? lastError.message : "no excalidraw scene in this file");
}

/// Serializes a scene back into the container it was read from, so editing a
/// `.excalidraw.png` keeps producing a PNG with the scene embedded in it.
/// termio paints the canvas in the terminal's colour so a drawing sits in the app rather
/// than on a white slab. That is a view setting, not the document's: unless the colour was
/// picked in Excalidraw's own background swatches, the file keeps the one it came with.
function documentBackground({ current, shown, original }) {
  return current === shown ? (original ?? DEFAULT_BACKGROUND) : current;
}

async function saveScene({ elements, appState, files, container, background }) {
  const live = elements.filter((element) => !element.isDeleted);
  appState = {
    ...appState,
    viewBackgroundColor: documentBackground({
      current: appState.viewBackgroundColor, shown: background.shown, original: background.original,
    }),
  };
  if (container === SVG_TYPE) {
    const svg = await exportToSvg({
      elements: live, appState: { ...appState, exportEmbedScene: true }, files,
      // Excalidraw inlines fonts by subsetting them in a module Web Worker loaded from
      // its asset path. A single-file bundle has no such chunk, so that await never
      // settles — the host splices the bundled faces into the exported SVG instead.
      skipInliningFonts: true,
    });
    return base64FromBytes(new TextEncoder().encode(svg.outerHTML));
  }
  if (container === PNG_TYPE) {
    const blob = await exportToBlob({
      elements: live, appState: { ...appState, exportEmbedScene: true }, files,
      getDimensions: (width, height) => ({ width: width * 2, height: height * 2, scale: 2 }),
    });
    return base64FromBytes(new Uint8Array(await blob.arrayBuffer()));
  }
  return base64FromBytes(new TextEncoder().encode(
    serializeAsJSON(live, appState, files || {}, "local")));
}

// -------------------------------------------------------------- the canvas

function host(message) {
  window.webkit?.messageHandlers?.termioExcalidraw?.postMessage(message);
}

/// A cheap identity for "the drawing as it stands". Excalidraw bumps an element's
/// `version` on every mutation, so the sum plus the count changes whenever the picture
/// does and not when only the selection or the pointer moves.
function sceneVersion(elements) {
  let sum = 0;
  for (const element of elements) sum += element.version;
  return elements.length + ":" + sum;
}

function Canvas({ initial, container, dark: mountDark, canvas: mountCanvas, readOnly, libraryItems }) {
  const [api, setApi] = useState(null);
  // Held in state rather than read from props: `theme` is a controlled prop, so a canvas
  // that took it straight from the mount options could never follow the app afterwards —
  // `updateScene` sets it and the prop immediately puts it back.
  const [dark, setDark] = useState(mountDark);
  const [canvas, setCanvas] = useState(mountCanvas);
  // What the file asked for, so a save can put it back when nobody chose otherwise.
  const original = useRef(initial.appState?.viewBackgroundColor ?? null);
  const saving = useRef(null);
  // Seeded from the scene as loaded, so mounting is not itself a change. Excalidraw
  // normalizes a scene on load (and `scrollToContent` fires onChange), which would
  // otherwise write the file just for having opened it.
  const lastVersion = useRef(sceneVersion(initial.elements || []));

  useEffect(() => { host({ type: "ready" }); }, []);

  // Excalidraw fires onChange for pointer moves and selection too, so the scene is
  // serialized only when the elements actually changed, and never more than once every
  // 400ms — writing a file on every frame of a drag would thrash the disk.
  const onChange = useCallback((elements, appState, files) => {
    if (readOnly) return;
    const version = sceneVersion(elements);
    if (version === lastVersion.current) return;
    lastVersion.current = version;
    clearTimeout(saving.current);
    saving.current = setTimeout(async () => {
      try {
        host({ type: "change", scene: await saveScene({
          elements, appState, files, container,
          background: { shown: canvas, original: original.current },
        }) });
      } catch (error) {
        host({ type: "error", message: String(error && error.message) });
      }
    }, 400);
  }, [container, readOnly, canvas]);

  // The app's appearance, pushed in by the host whenever the chrome theme changes.
  useEffect(() => {
    window.termioExcalidrawSetTheme = (isDark, canvasColor) => {
      setDark(isDark);
      if (canvasColor) setCanvas(canvasColor);
    };
    return () => { delete window.termioExcalidrawSetTheme; };
  }, []);

  // The canvas colour is appState, which Excalidraw owns once it is mounted, so it is
  // pushed through the API rather than passed as a prop.
  useEffect(() => {
    if (!api || !canvas) return;
    api.updateScene({ appState: { viewBackgroundColor: canvas } });
  }, [api, canvas]);

  return React.createElement(Excalidraw, {
    excalidrawAPI: setApi,
    initialData: {
      ...initial,
      appState: { ...(initial.appState || {}), viewBackgroundColor: mountCanvas || DEFAULT_BACKGROUND },
      libraryItems,
      scrollToContent: true,
    },
    theme: dark ? THEME.DARK : THEME.LIGHT,
    viewModeEnabled: readOnly,
    // No scene loading or saving from inside the canvas: the file on disk is the
    // document, and termio owns reading and writing it.
    UIOptions: { canvasActions: { loadScene: false, saveToActiveFile: false, export: false, saveAsImage: false } },
    onChange,
    // The shape library is a personal collection, so it lives in a file the host owns
    // rather than in this web view's storage, which a rebuild would wipe.
    onLibraryChange: (items) => host({ type: "library", library: serializeLibraryAsJSON(items) }),
    // An element's link is somebody else's URL. It goes to the host, which decides
    // whether it opens a sibling file or the browser; the canvas never navigates.
    onLinkOpen: (element, event) => {
      host({ type: "link", url: element.link });
      event.preventDefault();
    },
  });
}

async function loadLibrary(json) {
  if (!json) return [];
  try {
    return await loadLibraryFromBlob(new Blob([json], { type: JSON_TYPE }));
  } catch (error) {
    // A library that won't parse is not a reason to refuse to open the drawing.
    host({ type: "error", message: `library: ${error && error.message}` });
    return [];
  }
}

window.termioExcalidrawMount = async (options) => {
  const root = document.getElementById("root");
  try {
    const { scene, container } = await loadScene(options.scene, options.container);
    createRoot(root).render(React.createElement(Canvas, {
      initial: scene, container, dark: !!options.dark, canvas: options.canvas,
      readOnly: !!options.readOnly, libraryItems: await loadLibrary(options.library),
    }));
    return { ok: true, container };
  } catch (error) {
    return { ok: false, message: String(error && error.message) };
  }
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
