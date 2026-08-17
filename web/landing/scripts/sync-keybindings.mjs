#!/usr/bin/env node
// Derives the docs' keyboard-shortcut table from the app's own catalog.
//
// KeyCommandCatalog in Sources/termio/Keybindings/KeyCommand.swift is the single
// source of truth for every command and its shipped shortcut; the AppKit menu and
// the command palette both read from it. The docs used to restate that table by
// hand, which drifted: the shortcuts page still described a pane-rearrange chord
// two releases after it was replaced. So the page renders this generated JSON
// instead, and `--check` fails the build when the two fall out of step.
//
//   node scripts/sync-keybindings.mjs           # regenerate src/data/keybindings.json
//   node scripts/sync-keybindings.mjs --check   # exit 1 if it is out of date

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const landingRoot = resolve(scriptDir, "..");
const repoRoot = resolve(landingRoot, "../..");

const CATALOG = resolve(
  repoRoot,
  "Sources/termio/Keybindings/KeyCommand.swift",
);
const OUTPUT = resolve(landingRoot, "src/data/keybindings.json");

// macOS renders modifiers in this order, and so does Shortcut.display.
const MODIFIER_GLYPHS = [
  ["control", "⌃"],
  ["option", "⌥"],
  ["shift", "⇧"],
  ["command", "⌘"],
];

// Mirrors Key.displayGlyph. A key the catalog uses but this map doesn't know is
// an error rather than a silently blank cell.
const KEY_GLYPHS = {
  return: "↩",
  left: "←",
  right: "→",
  up: "↑",
  down: "↓",
};

function fail(message) {
  console.error(`sync-keybindings: ${message}`);
  process.exit(1);
}

/**
 * Drops `//` comments, leaving string literals alone. The catalog's comments
 * contain shortcut glyphs like `⌘⇧]`, so a bracket-matching scan has to run on
 * comment-free text or it closes the array early.
 */
function stripComments(source) {
  return source
    .split("\n")
    .map((line) => {
      let quoted = false;
      for (let i = 0; i < line.length - 1; i += 1) {
        if (line[i] === '"' && line[i - 1] !== "\\") quoted = !quoted;
        else if (!quoted && line[i] === "/" && line[i + 1] === "/") {
          return line.slice(0, i);
        }
      }
      return line;
    })
    .join("\n");
}

/**
 * The index of the delimiter closing the one that opens at `from`, skipping
 * string literals — `.char("]")` and `.char("[")` are catalog entries, not
 * brackets.
 */
function matchDelimiter(text, from, open, close) {
  let depth = 0;
  let quoted = false;
  for (let i = from; i < text.length; i += 1) {
    const char = text[i];
    if (quoted) {
      if (char === '"' && text[i - 1] !== "\\") quoted = false;
      continue;
    }
    if (char === '"') quoted = true;
    else if (char === open) depth += 1;
    else if (char === close) {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/** The `static let all: [KeyCommandInfo] = [ … ]` array body. */
function catalogBody(source) {
  const start = source.indexOf("static let all: [KeyCommandInfo] = [");
  if (start < 0) fail(`could not find KeyCommandCatalog.all in ${CATALOG}`);

  // Skip past the `[KeyCommandInfo]` type annotation to the array literal itself.
  const open = source.indexOf("[", source.indexOf("=", start));
  const close = matchDelimiter(source, open, "[", "]");
  if (close < 0) fail("KeyCommandCatalog.all is not closed");
  return source.slice(open + 1, close);
}

function shortcutDisplay(raw) {
  if (/^nil$/.test(raw)) return null;

  const modifiers = raw.match(/modifiers:\s*\[([^\]]*)\]/);
  const key = raw.match(/key:\s*\.(?:char\("(.)"\)|(\w+))/);
  if (!modifiers || !key) fail(`could not parse shortcut: ${raw}`);

  const held = new Set(
    modifiers[1]
      .split(",")
      .map((token) => token.trim().replace(/^\./, ""))
      .filter(Boolean),
  );
  for (const name of held) {
    if (!MODIFIER_GLYPHS.some(([modifier]) => modifier === name)) {
      fail(`unknown modifier "${name}" in: ${raw}`);
    }
  }

  const glyphs = MODIFIER_GLYPHS.filter(([modifier]) => held.has(modifier))
    .map(([, glyph]) => glyph)
    .join("");

  if (key[1]) return `${glyphs}${key[1].toUpperCase()}`;

  const named = KEY_GLYPHS[key[2]];
  if (!named) fail(`unknown key ".${key[2]}" — add it to KEY_GLYPHS`);
  return `${glyphs}${named}`;
}

function parseCatalog(source) {
  const body = catalogBody(source);
  const entries = [];

  // Each element is `.init(id: .x, category: "C", title: "T", defaultShortcut: …)`,
  // wrapped across lines. Split on the element head, then read to the trailing
  // `)` of that element. Category and title may be wrapped in `localized(…)`; the
  // docs want the English key either way, since that is what the table's own
  // translations are keyed on.
  const literal = String.raw`(?:localized\(\s*)?"([^"]+)"\s*\)?`;
  const heads = [
    ...body.matchAll(
      new RegExp(
        String.raw`\.init\(\s*id:\s*\.(\w+),\s*category:\s*${literal},\s*title:\s*${literal},\s*defaultShortcut:\s*`,
        "g",
      ),
    ),
  ];
  if (heads.length === 0) fail("parsed zero commands out of the catalog");

  for (const [index, head] of heads.entries()) {
    const from = head.index + head[0].length;
    const to = index + 1 < heads.length ? heads[index + 1].index : body.length;
    const tail = body.slice(from, to);

    // The shortcut runs to the `)` closing this element's own `.init(`, which the
    // head consumed — so scan from a synthetic opener.
    const scanned = matchDelimiter(`(${tail}`, 0, "(", ")");
    const end = scanned < 0 ? tail.length : scanned - 1;

    entries.push({
      id: head[1],
      category: head[2],
      title: head[3],
      shortcut: shortcutDisplay(tail.slice(0, end).trim()),
    });
  }

  return entries;
}

function build() {
  const entries = parseCatalog(stripComments(readFileSync(CATALOG, "utf8")));

  // Group in catalog order — the same order Settings ▸ Keyboard lists.
  const categories = [];
  for (const entry of entries) {
    let group = categories.find((c) => c.title === entry.category);
    if (!group) {
      group = { title: entry.category, commands: [] };
      categories.push(group);
    }
    group.commands.push({
      id: entry.id,
      title: entry.title,
      shortcut: entry.shortcut,
    });
  }

  return {
    // Regenerate with `pnpm keybindings:sync`; `pnpm docs:check` guards it.
    generatedFrom: "Sources/termio/Keybindings/KeyCommand.swift",
    categories,
  };
}

const serialized = `${JSON.stringify(build(), null, 2)}\n`;

if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(OUTPUT, "utf8");
  } catch {
    fail(`${OUTPUT} is missing — run pnpm keybindings:sync`);
  }
  if (current !== serialized) {
    fail(
      "src/data/keybindings.json is out of step with KeyCommandCatalog — run pnpm keybindings:sync",
    );
  }
  console.log("keybindings: docs table matches the app catalog");
} else {
  writeFileSync(OUTPUT, serialized);
  console.log(`keybindings: wrote ${OUTPUT}`);
}
