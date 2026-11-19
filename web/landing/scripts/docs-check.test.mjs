// The anchor rules, pinned. `headingAnchor` has to agree with the id the docs
// pipeline actually renders, because a link is checked against what this function
// returns — a slugifier that is merely close rejects correct anchors and passes
// broken ones. The cases below are taken from real headings in content/docs, and
// the expected values were read back off the rendered pages.
//
//   pnpm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { headingAnchor, pageAnchors } from "./docs-check.mjs";

test("slugifies plain headings", () => {
  assert.equal(headingAnchor("Status"), "status");
  assert.equal(
    headingAnchor("Where the signal comes from"),
    "where-the-signal-comes-from",
  );
});

test("an explicit [#id] wins over the text", () => {
  assert.equal(headingAnchor("恢复 [#resume]"), "resume");
  assert.equal(headingAnchor("状态 [#status]"), "status");
});

test("strips inline markup rather than slugifying it", () => {
  assert.equal(
    headingAnchor("The `termio` command-line tool"),
    "the-termio-command-line-tool",
  );
  assert.equal(headingAnchor("**Panes**"), "panes");
  assert.equal(headingAnchor("See [Concepts](/docs/concepts)"), "see-concepts");
});

// The bug this file exists for: dropped punctuation leaves its spaces behind, and
// the renderer emits one hyphen per space instead of one per run. Collapsing the
// run here produced `command-palette-p` for a heading the site serves at
// `command-palette--p`.
test("keeps one hyphen per space, so dropped glyphs leave their gap", () => {
  assert.equal(headingAnchor("Command Palette — `⇧⌘P`"), "command-palette--p");
  assert.equal(headingAnchor("Open Quickly — `⇧⌘O`"), "open-quickly--o");
  assert.equal(headingAnchor("命令面板 —— `⇧⌘P`"), "命令面板--p");
});

test("keeps CJK headings addressable", () => {
  assert.equal(headingAnchor("信号从哪里来"), "信号从哪里来");
});

test("pageAnchors collects every heading and ignores fenced code", () => {
  const page = [
    "---",
    "title: Example",
    "---",
    "",
    "Opening prose.",
    "",
    "## Real heading",
    "",
    "```sh",
    "# not a heading, a shell comment",
    "```",
    "",
    "### Nested one [#pinned]",
    "",
    "#not-a-heading-either",
  ].join("\n");

  assert.deepEqual([...pageAnchors(page)].sort(), ["pinned", "real-heading"]);
});
