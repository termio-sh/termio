# The rendered Markdown face's page

Build input for `Sources/termio/Resources/domd/app.js` — the page
`MarkdownEditorView` loads into its `WKWebView`.

```sh
pnpm install
pnpm build
```

That writes `app.js` beside the vendored kernel. Both versions are pinned
exactly, because the bundle is checked in and a different esbuild or kernel
would rewrite it wholesale; with these two the rebuild is byte-identical to what
is committed, so a stray diff there means the input really did change.

`app.css` and `index.html` are not built. They are termio's own and are authored
in `Sources/termio/Resources/domd` directly — see the README there, which also
carries the kernel's licence terms.

## Measuring the write-back

`scripts/writeback-corpus.mjs` emits, for every Markdown file in the repo, the
file as it is on disk, the kernel's canonical serialization of it, and that
serialization with one character typed into a prose line. Feed the three to
`MarkdownWriteBack.merge` and every document must come back byte-identical on the
unedited save and one line different on the edit. Re-run it after a kernel bump:
it is what proves a save still writes the user's edit and nothing else.
