# Vendored @pierre/trees

The Files pane draws its tree with [@pierre/trees](https://trees.software)
`1.0.0-beta.6` ([pierrecomputer/pierre](https://github.com/pierrecomputer/pierre)),
inside a `WKWebView` (`../FileTreeWebView.swift`). The library is bundled once
into `../../Resources/assets/pierre-trees.min.js`, which ships inside
`termio_termio.bundle` and is read through `Bundle.termioResources`. The page's
side of the bridge is `../../Resources/assets/file-tree.js`.

Why a vendored script instead of a package: there is no Swift package to add.
The bundle is one IIFE that sets `window.PierreTrees`, with its two runtime
dependencies, preact `11.0.0-beta.0` and preact-render-to-string `6.6.5`,
inlined. Nothing is fetched at runtime.

## Rebuild

```sh
mkdir /tmp/pierre-trees && cd /tmp/pierre-trees
echo '{"private":true}' > package.json
npm install @pierre/trees@1.0.0-beta.6 esbuild@0.25.10
echo "export { FileTree } from '@pierre/trees';" > entry.js
npx esbuild entry.js --bundle --minify --format=iife --global-name=PierreTrees \
  --target=safari17 --legal-comments=none --outfile=pierre-trees.min.js
```

That output has sha256
`77dae7aaf2696b5ac7342968e96d58062d08a98a46e94a2f354902af2a3316bb`. The bundle
in the repo differs from it in one place, so a rebuild must apply it again:

- `FileTree` gains `selectOnlyPath(e){this.#t.selectOnlyPath(e)}`, inserted
  right after `focusPath(e){this.#t.focusPath(e)}`. The controller has it, but
  `FileTree` does not pass it on, and an item's `select()` keeps the old range
  anchor. Without it, a row the keyboard walked onto can't become the row a
  shift-click extends from.

With that line the sha256 is
`64c60ad0fcb82345c23ef761183ef54c6f26533d74e78aba05589fd300782a7c`.

## Licenses

@pierre/trees is Apache-2.0: `LICENSE.md` and `NOTICE.md` here are upstream's,
verbatim. preact and preact-render-to-string are MIT:

```
The MIT License (MIT)

Copyright (c) 2015-present Jason Miller

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
