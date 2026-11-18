# Vendored @pierre/diffs

The pull request's Files view, when it stacks every file in one scroll, draws the
diffs with [@pierre/diffs](https://diffs.com) `1.6.4`
([pierrecomputer/pierre](https://github.com/pierrecomputer/pierre)) inside a
`WKWebView` (`../PRDiffWebView.swift`). Two scripts ship in
`termio_termio.bundle` and are read through `Bundle.termioResources`:

- `../../Resources/assets/pierre-diffs.min.js`: one IIFE that sets
  `window.PierreDiffs`, with `CodeView`, `parsePatchFiles`, the worker pool, and
  jsdiff's `parsePatch`, `reversePatch` and `applyPatch`.
- `../../Resources/assets/pierre-diffs-worker.js`: upstream's
  `dist/worker/worker-portable.js`, unchanged. It is a self-contained classic
  script with the @pierre/highlights lexers inside, so the page runs it as a blob
  worker. A page loaded from a string has no origin to fetch a worker from.

The page's side of the bridge is `../../Resources/assets/pr-diff.js`. Nothing is
fetched at runtime.

Shiki is left out on purpose. The page and the worker highlight with
@pierre/highlights, so Shiki's 9 MB of grammars and themes would never load. The
build replaces every `shiki` and `@shikijs/*` import with a stub that throws if
it is ever called.

## Rebuild

```sh
mkdir /tmp/pierre-diffs && cd /tmp/pierre-diffs
echo '{"private":true}' > package.json
npm install @pierre/diffs@1.6.4 esbuild@0.25.10
cat > entry.js <<'JS'
export { CodeView, parsePatchFiles, getFiletypeFromFileName } from '@pierre/diffs';
export { getOrCreateWorkerPoolSingleton } from '@pierre/diffs/worker';
export { applyPatch, reversePatch, parsePatch } from 'diff';
JS
cat > build.mjs <<'JS'
import * as esbuild from 'esbuild';
const noShiki = {
  name: 'no-shiki',
  setup(build) {
    build.onResolve({ filter: /^(shiki|@shikijs\/.*)(\/.*)?$/ }, (args) => ({ path: args.path, namespace: 'no-shiki' }));
    build.onLoad({ filter: /.*/, namespace: 'no-shiki' }, (args) => ({
      contents: `module.exports = new Proxy({}, { get(_, key) {
        if (key === '__esModule') return false;
        return () => { throw new Error('Shiki is not bundled: ' + ${JSON.stringify(args.path)} + '.' + String(key)); };
      } });`,
      loader: 'js',
    }));
  },
};
await esbuild.build({
  entryPoints: ['entry.js'], bundle: true, minify: true, format: 'iife', globalName: 'PierreDiffs',
  target: 'safari17', legalComments: 'none', outfile: 'pierre-diffs.min.js', metafile: true,
  plugins: [noShiki], logLevel: 'warning',
});
JS
node build.mjs
cp node_modules/@pierre/diffs/dist/worker/worker-portable.js pierre-diffs-worker.js
```

sha256 of the outputs:

- `pierre-diffs.min.js`: `c0fb476db521790b21453e3b8a7db899a975bb50ec38f9007783608ed5939fc4`
- `pierre-diffs-worker.js`: `7b3684ea70c1a30c9d5a40b7745fda54e1185f11a665095af57c2663bee147e1`

## Licenses

@pierre/diffs is Apache-2.0: `LICENSE.md` here is upstream's, verbatim. The
bundle also carries:

- Apache-2.0, same license text: @pierre/highlights 0.4.0, @pierre/theme 2.0.0,
  @pierre/theming 1.0.2. `NOTICE-highlights.md` is @pierre/highlights' notice for
  the themes it bundles, verbatim.
- BSD-3-Clause: diff (jsdiff) 9.0.0, in `LICENSE-jsdiff`.
- MIT: hast-util-to-html 9.0.5, hast-util-whitespace 3.0.0, property-information
  7.2.0, stringify-entities 4.0.4, character-entities-html4 2.1.0,
  character-entities-legacy 3.0.0, html-void-elements 3.0.0, comma-separated-tokens
  2.0.3, space-separated-tokens 2.0.2, ccount 2.0.1, zwitch 2.0.4 (Titus Wormer),
  lru_map 0.4.1 (Rasmus Andersson).

```
The MIT License (MIT)

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
