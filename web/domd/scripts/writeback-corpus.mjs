// Emit (original, canonical, edited) triples for every Markdown file in the repo, so the
// Swift write-back merge can be measured against real documents rather than fixtures.
//
//   node scripts/writeback-corpus.mjs > corpus.json
//
// `edited` is `canonical` with one character typed into the first ordinary prose line —
// the cheapest edit a user can make, and the one whose blast radius the merge exists to
// keep to a single line.
import { EditorStore, toMarkdown } from "@do-md/core-react";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = new URL("../../..", import.meta.url).pathname;
const DIRS = ["docs", "web/landing/content"];

function walk(dir, acc = []) {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) walk(path, acc);
    else if (/\.mdx?$/.test(entry)) acc.push(path);
  }
  return acc;
}

/// The first line that is plain prose: no fence, no table, no front matter, no list or
/// heading marker — the places a stray character would change structure rather than text.
function proseLine(lines) {
  let inFence = false;
  let inFrontMatter = lines[0] === "---";
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (inFrontMatter) { if (i > 0 && line === "---") inFrontMatter = false; continue; }
    if (/^\s*(```|~~~)/.test(line)) { inFence = !inFence; continue; }
    if (inFence) continue;
    if (!line.trim()) continue;
    if (/^\s*([#>|*+-]|\d+[.)]|<|:|\[|!)/.test(line)) continue;
    if (line.includes("|")) continue;
    return i;
  }
  return -1;
}

const files = DIRS.flatMap((d) => walk(join(ROOT, d))).sort();
const out = [];
for (const file of files) {
  const original = readFileSync(file, "utf8");
  const store = new EditorStore({ editable: false, initMd: "" });
  store.resetMD(original);
  const canonical = toMarkdown(store.renderData_);
  const lines = canonical.split("\n");
  const at = proseLine(lines);
  if (at < 0) continue;
  const edited = lines.map((l, i) => (i === at ? l + "x" : l)).join("\n");
  out.push({ path: relative(ROOT, file), original, canonical, edited, line: lines[at] });
}
process.stdout.write(JSON.stringify(out));
