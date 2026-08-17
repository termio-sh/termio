---
name: doc
description: "Use for ANY operation on a doc under docs/ — creating, updating/editing, changing its status, or querying. Keeps the YAML front matter (title/status/type/updated) correct and regenerates the docs/README.md wiki index. Invoke when the user says 'new doc', 'create a doc/design/RFC', 'start a design doc', 'update the doc', 'edit this doc', 'mark this doc done/in-review', 'change the doc status', or asks 'which docs are done/draft', 'what am I still working on', 'list my docs by status', '新建文档', '建一个设计文档/RFC', '更新文档', '改一下这个文档', '把这个文档标记成完成/评审中', '哪些文档写完了', '我还有哪些没做完的文档', '按状态列出文档'."
---

# Project docs — create & query

Every doc under `docs/` carries its status in **YAML front matter** at the very
top of the file. That front matter is the **single source of truth** — there is
**no** central index/JSON to keep in sync. "What's done?" is answered by scanning
the front matter live (see *Query*). This skill writes that front matter when
creating a doc, and reads it when querying.

`docs/README.md` is the human-facing **wiki** for the folder: it explains the
organization and holds a generated index table between
`<!-- BEGIN docs-index -->` / `<!-- END docs-index -->` markers. That table is a
**derived view**, not a source of truth — regenerate it from front matter (see
*Maintain the wiki index*); never hand-edit the rows.

## Front matter schema

```yaml
---
title: <free text — the human title>
status: draft        # see vocabulary below
type: design         # design | rfc | marketing
created: 2026-06-28  # YYYY-MM-DD, only the day the doc was first written
updated: 2026-06-28  # YYYY-MM-DD, bump on every meaningful edit
related:             # optional — sibling filenames (YYYYMMDD- prefix under design/)
  - 20260719-vibe-island-status.md
---
```

- `status` vocabulary (a doc moves down this list over its life):
  - `draft` — being written, nothing committed to.
  - `in-review` — content complete, awaiting sign-off.
  - `approved` — signed off, not yet built.
  - `active` — currently being executed / lived against (e.g. a strategy memo).
  - `done` — fully delivered; kept for reference.
  - `archived` — superseded or abandoned; ignore for planning.
- `type` is just a label on the doc; it does **not** dictate a subdirectory. The
  set is small on purpose; add a new type only when a doc genuinely doesn't fit.
- Keys are English (tooling/Obsidian compatibility); values may be Chinese where
  natural (e.g. a Chinese `title`). Quote any value containing `:` `#` `[` `]`.

## Create a doc

All docs live somewhere under `docs/`. The skill does not impose a per-type
folder layout — place the file under `docs/` (or whichever existing
`docs/` subfolder the user points at), and let `type` in the front matter, not
the path, carry the category.

1. Ask the user for the `title` and `type` if not already clear from the request.
   Default `status: draft`. Set both `created` and `updated` to today.
2. Pick a **kebab-case** filename derived from the title (ASCII slug; for a
   Chinese title, ask for or invent a short English slug — keep the Chinese in
   `title`). Put it under `docs/` unless the user names a subfolder.
3. Write the file: front matter block first, then a single `# <H1>` title, then a
   one-line `>` blockquote stating the doc's goal. Do not pad with boilerplate
   sections — let the content grow naturally.
4. **Regenerate the wiki index** (see below) so `docs/README.md` reflects the new
   doc.
5. Tell the user the path you created.

Also regenerate the index whenever a doc's `status`/`title`/`type` changes, not
only on create — the table is otherwise stale.

## Update a doc

Use this skill for **any** edit to an existing doc, not just creation — editing
its body, advancing its status, renaming it, or changing its type. The point is
to keep the front matter honest and the wiki in sync after every change.

1. Make the requested edit to the doc body and/or front matter.
2. **Bump `updated`** to today on any meaningful change (the whole point of the
   field). Leave `created` alone.
3. If the user is advancing the doc's lifecycle, move `status` along the line
   `draft → in-review → approved → active → done → archived` — don't skip to a
   value that doesn't match reality.
4. If you changed `status`/`title`/`type`, **regenerate the wiki index** (see
   *Maintain the wiki index*) so `docs/README.md` matches.
5. Report what changed (path, old → new status if it moved).

Note: markdownlint's MD025 may warn "multiple top-level headings" because it
treats the front matter `title:` as an H1. It's a false positive for
front-matter docs and renders fine everywhere; ignore it (or the repo can set
`MD025: { front_matter_title: "" }` in `.markdownlint.json`).

## Query — "which docs are done / in draft / ...?"

Scan the front matter directly. This reads only the **top** of each file (the
front matter sits at byte 0), so it stays cheap even with many docs:

```bash
find docs -name '*.md' -print0 | sort -z | while IFS= read -r -d '' f; do
  awk -v file="$f" '
    NR==1 && $0!="---" { exit }                       # no front matter → skip file
    NR==1 { next }
    /^status:/ { sub(/^status:[ \t]*/,""); status=$0 }
    /^type:/   { sub(/^type:[ \t]*/,"");   type=$0 }
    /^title:/  { sub(/^title:[ \t]*/,"");  title=$0 }
    NR>1 && $0=="---" {                                # end of front matter → emit, stop
      printf "%-10s %-9s %-40s %s\n", status, type, title, file
      exit }
  ' "$f"
done | sort
```

The `exit` on the closing `---` is what keeps this fast: awk never reads past the
front matter into the document body. To answer a specific question, filter the
output — e.g. append `| grep -E '^(draft|in-review)'` for "what's unfinished",
or `| grep design` to scope to design docs. Report the result grouped by status.

## Maintain the wiki index

`docs/README.md` holds a generated table between `<!-- BEGIN docs-index -->` and
`<!-- END docs-index -->`. Regenerate it (don't hand-edit the rows) after
creating a doc or changing any doc's `status`/`title`/`type`. This rebuilds the
table from front matter and splices it back between the markers atomically:

```bash
readme=docs/README.md
rows=$(find docs -name '*.md' ! -name 'README.md' -print0 | sort -z |
  while IFS= read -r -d '' f; do
    awk -v file="$f" '
      NR==1 && $0!="---" { exit }
      NR==1 { next }
      /^status:/ { sub(/^status:[ \t]*/,""); status=$0 }
      /^type:/   { sub(/^type:[ \t]*/,"");   type=$0 }
      /^title:/  { sub(/^title:[ \t]*/,"");  title=$0 }
      NR>1 && $0=="---" {
        rel=file; sub(/^docs\//,"",rel)
        printf "| %s | %s | [%s](%s) |\n", status, type, title, rel
        exit }
    ' "$f"
  done | sort)
{
  printf '| status | type | title |\n| --- | --- | --- |\n'
  printf '%s\n' "$rows"
} > /tmp/docs-index.md
awk '
  /<!-- BEGIN docs-index -->/ { print; while ((getline l < "/tmp/docs-index.md")>0) print l; skip=1; next }
  /<!-- END docs-index -->/   { skip=0 }
  !skip { print }
' "$readme" > "$readme.tmp" && mv "$readme.tmp" "$readme" && rm -f /tmp/docs-index.md
```

The rows are sorted by status, so `draft`/`in-review` (unfinished) float to the
top. The splice only touches lines between the markers — the hand-written wiki
prose above is left alone.

## Scale — does this hold at 1000+ docs?

Yes. The work is **one `open()` + a few lines read per file**, not a full-content
scan — the early `exit` above means each file contributes ~200 bytes of reads
regardless of how long the document is. 1000 small files is on the order of tens
of milliseconds on a local SSD; the cost is dominated by file-open syscalls, not
parsing.

It only stops being instant in the tens-of-thousands range, or on a slow/network
filesystem. If that ever happens, the fix is **not** to make the front matter
non-authoritative — it's to add a *derived* cache: regenerate `docs/.index.json`
from the front matter (keyed by file `mtime`, rebuilt when stale) and read that.
That index is a rebuildable cache, never hand-edited and never the source of
truth. Don't add it preemptively — the live scan is correct and fast for the
foreseeable size of this repo.
