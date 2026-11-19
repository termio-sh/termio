#!/usr/bin/env node
// Guards the two ways the docs site rots silently.
//
// 1. The changelog falls behind the releases. It did: the page stopped at 0.22.0
//    while the app shipped through 0.34.0, so the site read as abandoned.
// 2. A translation drifts from its English source — missing, restructured, or
//    stale after the English page was edited.
//
// Both are mechanical, so neither should depend on someone remembering.
//
//   node scripts/docs-check.mjs              # all checks
//   node scripts/docs-check.mjs --changelog  # just the changelog
//   node scripts/docs-check.mjs --i18n       # just the translations

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const landingRoot = resolve(scriptDir, "..");
const repoRoot = resolve(landingRoot, "../..");
const docsDir = resolve(landingRoot, "content/docs");

const errors = [];
const notes = [];

function fail(message) {
  errors.push(message);
}

// ---------------------------------------------------------------- changelog

/** The locales the docs are translated into, read from the i18n config. */
function configuredLocales() {
  const source = readFileSync(resolve(landingRoot, "src/lib/i18n.ts"), "utf8");
  const languages = source.match(/languages:\s*\[([^\]]+)\]/);
  const fallback = source.match(/defaultLanguage:\s*"([^"]+)"/);
  if (!languages || !fallback) {
    fail("could not read languages out of src/lib/i18n.ts");
    return { defaultLanguage: "en", locales: [] };
  }
  const all = [...languages[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  return {
    defaultLanguage: fallback[1],
    locales: all.filter((locale) => locale !== fallback[1]),
  };
}

function parseVersion(version) {
  const parts = version.split(".").map((part) => Number.parseInt(part, 10));
  if (parts.length !== 3 || parts.some(Number.isNaN)) return null;
  return parts;
}

function compareVersions(a, b) {
  const left = parseVersion(a);
  const right = parseVersion(b);
  if (!left || !right) return 0;
  for (let i = 0; i < 3; i += 1) {
    if (left[i] !== right[i]) return left[i] - right[i];
  }
  return 0;
}

function newestTag() {
  try {
    const output = execFileSync(
      "git",
      ["tag", "--list", "v*", "--sort=-v:refname"],
      { cwd: repoRoot, encoding: "utf8" },
    );
    const tags = output
      .split("\n")
      .map((line) => line.trim().replace(/^v/, ""))
      .filter((version) => parseVersion(version) !== null);
    return tags[0];
  } catch {
    return undefined;
  }
}

function checkChangelog() {
  const source = readFileSync(
    resolve(landingRoot, "src/data/changelog.ts"),
    "utf8",
  );
  const newestEntry = source.match(/version:\s*"([^"]+)"/);
  if (!newestEntry) {
    fail("no entries found in src/data/changelog.ts");
    return;
  }

  const tag = newestTag();
  if (!tag) {
    // A shallow CI checkout has no tags; say so rather than passing quietly.
    notes.push(
      "changelog: no release tags visible (shallow clone?) — freshness unverified",
    );
    return;
  }

  if (compareVersions(newestEntry[1], tag) < 0) {
    fail(
      `changelog: the site's newest entry is ${newestEntry[1]} but v${tag} is released — ` +
        "add the missing entries to src/data/changelog.ts (the changelog is how the " +
        "site shows the project is alive)",
    );
    return;
  }

  notes.push(`changelog: newest entry ${newestEntry[1]} covers v${tag}`);
}

// The mechanical half of the translation conventions in
// content/docs/.i18n/glossary.<locale>.json — the rules a reader feels as
// "this was typed carefully" and that drift silently otherwise: a half-width
// space between Chinese and Latin (盘古之白), full-width Chinese punctuation,
// half-width digits and Latin.
//
// Only CJK locales are checked, and only prose: code spans and fences, front
// matter, MDX tags, link targets, URLs and explicit anchor ids are blanked out
// first, because `git worktree add` and `## 设备 [#device]` are correct exactly
// as written and would otherwise trip every rule here.
const CJK = "\\u4e00-\\u9fff\\u3400-\\u4dbf";

function proseOnly(text) {
  const out = text.split("");
  // Newlines survive the blanking, or every reported line number would be short
  // by however many lines the front matter and fenced blocks span.
  const blank = (match, index) => {
    for (let i = index; i < index + match.length; i += 1) {
      if (out[i] !== "\n") out[i] = "\u0000";
    }
  };
  const patterns = [
    /```[\s\S]*?```/g,
    /`[^`\n]*`/g,
    /^---\n[\s\S]*?\n---/gm,
    /\[#[^\]]+\]/g,
    /<[^>\n]+>/g,
    /\]\([^)]*\)/g,
    /https?:\/\/\S+/g,
  ];
  for (const pattern of patterns) {
    for (const match of text.matchAll(pattern)) blank(match[0], match.index);
  }
  return out.join("");
}

function checkTypography(name, text) {
  const prose = proseOnly(text);
  const rules = [
    {
      re: new RegExp(`[${CJK}][A-Za-z0-9]|[A-Za-z0-9][${CJK}]`, "g"),
      why: "needs a half-width space between Chinese and Latin or digits",
    },
    {
      re: new RegExp(`[${CJK}]\\s*[,.;:!?]\\s*[${CJK}]`, "g"),
      why: "uses half-width punctuation between Chinese — use 。，、：；！？",
    },
    {
      re: /[\uff21-\uff3a\uff41-\uff5a\uff10-\uff19]/g,
      why: "uses full-width Latin or digits — those stay half-width",
    },
  ];
  for (const rule of rules) {
    const hit = rule.re.exec(prose);
    if (!hit) continue;
    const line = prose.slice(0, hit.index).split("\n").length;
    fail(`i18n: ${name}:${line} ${rule.why} — "${hit[0]}"`);
  }
}

// --------------------------------------------------------------------- i18n

/** `<name>.mdx` → English source pages, excluding translations. */
function englishPages() {
  return readdirSync(docsDir)
    .filter((name) => name.endsWith(".mdx"))
    .filter((name) => name.split(".").length === 2)
    .sort();
}

/** The sequence of heading levels, ignoring fenced code. */
function headingOutline(text) {
  const outline = [];
  let fenced = false;
  for (const line of text.split("\n")) {
    const trimmed = line.trimStart();
    if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
      fenced = !fenced;
      continue;
    }
    if (fenced || !trimmed.startsWith("#")) continue;
    const level = trimmed.match(/^#+/)[0].length;
    if (level > 6 || trimmed[level] !== " ") continue;
    outline.push(level);
  }
  return outline;
}

function frontmatter(text) {
  const match = text.match(/^---\n([\s\S]*?)\n---/);
  return match ? match[1] : "";
}

// ---------------------------------------------------------------------- links

/**
 * The anchor id of a heading, the way the docs pipeline assigns it: an explicit
 * `## 状态 [#status]` wins, otherwise the text is slugified. Inline markup is
 * stripped first, so `## The \`termio\` command-line tool` and `## **Panes**`
 * anchor on their words rather than their backticks and asterisks.
 */
function headingAnchor(heading) {
  const explicit = heading.match(/\[#([^\]]+)\]\s*$/);
  if (explicit) return explicit[1];
  return (
    heading
      .replace(/`([^`]*)`/g, "$1")
      .replace(/\*\*?([^*]*)\*\*?/g, "$1")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .trim()
      .toLowerCase()
      .replace(/[^\p{Letter}\p{Number}\s-]/gu, "")
      // One hyphen per space, not one per run. `## Command Palette — ⇧⌘P` loses
      // the dash and the glyphs but keeps the spaces that flanked them, so the id
      // the site renders is `command-palette--p` — with the double hyphen. A
      // slugifier that collapses runs here rejects the correct anchor.
      .replace(/\s/g, "-")
  );
}

/** Every heading's anchor id on a page, ignoring fenced code. */
function pageAnchors(text) {
  const anchors = new Set();
  let fenced = false;
  for (const line of text.split("\n")) {
    const trimmed = line.trimStart();
    if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
      fenced = !fenced;
      continue;
    }
    if (fenced || !trimmed.startsWith("#")) continue;
    const level = trimmed.match(/^#+/)[0].length;
    if (level > 6 || trimmed[level] !== " ") continue;
    anchors.add(headingAnchor(trimmed.slice(level + 1)));
  }
  return anchors;
}

/** The public URL a content file is served at. */
function pageHref(name, defaultLanguage) {
  const parts = name.replace(/\.mdx$/, "").split(".");
  const slug = parts[0];
  const locale = parts.length > 1 ? parts[1] : defaultLanguage;
  const base = locale === defaultLanguage ? "/docs" : `/${locale}/docs`;
  return slug === "index" ? base : `${base}/${slug}`;
}

/**
 * Every internal link lands on a page that exists, and every `#anchor` on a
 * heading that exists. Both rot silently: a renamed page leaves a 404 behind a
 * link that still looks fine in the source, and a reworded heading breaks every
 * anchor pointing at it — including the explicit `[#id]` a translation carries so
 * its links survive. Neither shows up in a build, because MDX links are just
 * strings until someone clicks one.
 */
function checkLinks() {
  const { defaultLanguage } = configuredLocales();
  const files = readdirSync(docsDir).filter((name) => name.endsWith(".mdx"));

  const anchorsByHref = new Map();
  for (const name of files) {
    anchorsByHref.set(
      pageHref(name, defaultLanguage),
      pageAnchors(readFileSync(resolve(docsDir, name), "utf8")),
    );
  }

  let checked = 0;
  for (const name of files) {
    const text = readFileSync(resolve(docsDir, name), "utf8");
    const lines = text.split("\n");

    for (const [index, line] of lines.entries()) {
      // Markdown links and JSX `href` attributes, absolute paths only —
      // external URLs are not this script's business.
      const found = [
        ...line.matchAll(/\]\((\/[^)\s]*)\)/g),
        ...line.matchAll(/href="(\/[^"]*)"/g),
      ];
      for (const [, href] of found) {
        checked += 1;
        const [path, anchor] = href.split("#");
        const target = path.replace(/\/$/, "") || "/docs";
        if (!anchorsByHref.has(target)) {
          fail(`links: ${name}:${index + 1} → ${href} (no such page)`);
          continue;
        }
        if (anchor && !anchorsByHref.get(target).has(anchor)) {
          fail(
            `links: ${name}:${index + 1} → ${href} (no heading anchors to #${anchor})`,
          );
        }
      }
    }
  }

  if (errors.length === 0) {
    notes.push(
      `links: ${checked} internal links resolve to a page and an anchor`,
    );
  }
}

function sourceHash(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function checkI18n() {
  const { locales } = configuredLocales();
  if (locales.length === 0) {
    notes.push("i18n: no locales configured");
    return;
  }

  const english = englishPages();
  const present = new Set(readdirSync(docsDir));

  for (const locale of locales) {
    const glossary = `.i18n/glossary.${locale}.json`;
    try {
      JSON.parse(readFileSync(resolve(docsDir, glossary), "utf8"));
    } catch {
      fail(`i18n: ${glossary} is missing or not valid JSON`);
    }

    if (!present.has(`meta.${locale}.json`)) {
      fail(
        `i18n: content/docs/meta.${locale}.json is missing — the sidebar would fall back to English`,
      );
    } else {
      const base = JSON.parse(
        readFileSync(resolve(docsDir, "meta.json"), "utf8"),
      );
      const translated = JSON.parse(
        readFileSync(resolve(docsDir, `meta.${locale}.json`), "utf8"),
      );
      const strip = (pages) => pages.filter((page) => !page.startsWith("---"));
      if (
        JSON.stringify(strip(base.pages ?? [])) !==
        JSON.stringify(strip(translated.pages ?? []))
      ) {
        fail(
          `i18n: meta.${locale}.json lists different pages than meta.json — ` +
            "the two must stay in the same order, only the separator labels translate",
        );
      }
    }

    // Translations that no longer have an English source.
    for (const name of readdirSync(docsDir)) {
      if (!name.endsWith(`.${locale}.mdx`)) continue;
      const base = name.replace(`.${locale}.mdx`, ".mdx");
      if (!english.includes(base)) {
        fail(
          `i18n: ${name} has no English source (${base} was renamed or removed)`,
        );
      }
    }

    for (const name of english) {
      const translatedName = name.replace(/\.mdx$/, `.${locale}.mdx`);
      if (!present.has(translatedName)) {
        fail(`i18n: ${translatedName} is missing`);
        continue;
      }

      const sourceText = readFileSync(resolve(docsDir, name), "utf8");
      const translatedText = readFileSync(
        resolve(docsDir, translatedName),
        "utf8",
      );

      const declared = frontmatter(translatedText).match(
        /source_hash:\s*([0-9a-f]{64})/,
      );
      if (!declared) {
        fail(
          `i18n: ${translatedName} has no x-i18n.source_hash — a translation must record ` +
            "which English revision it was made from",
        );
      } else if (declared[1] !== sourceHash(sourceText)) {
        fail(
          `i18n: ${translatedName} is stale — ${name} changed since it was translated ` +
            `(expected source_hash ${sourceHash(sourceText)})`,
        );
      }

      if (/^zh/.test(locale)) checkTypography(translatedName, translatedText);

      const sourceOutline = headingOutline(sourceText);
      const translatedOutline = headingOutline(translatedText);
      if (JSON.stringify(sourceOutline) !== JSON.stringify(translatedOutline)) {
        fail(
          `i18n: ${translatedName} has a different heading structure than ${name} ` +
            `(${sourceOutline.join("/")} vs ${translatedOutline.join("/")}) — ` +
            "a translation keeps the same sections so anchors and links survive",
        );
      }
    }
  }

  if (errors.length === 0) {
    notes.push(
      `i18n: ${english.length} pages × ${locales.length} locale(s) in step with English`,
    );
  }
}

// -------------------------------------------------------------------- stamp

/**
 * Records provenance in every translation: which English file it came from, and
 * the hash of that file's exact bytes. Run it after translating (or re-translating)
 * a page — the check above then knows the translation is current, and knows to
 * complain the next time the English page moves ahead of it.
 */
function stampTranslations(dateISO) {
  const { locales } = configuredLocales();
  const english = englishPages();
  let stamped = 0;

  for (const locale of locales) {
    for (const name of english) {
      const translatedName = name.replace(/\.mdx$/, `.${locale}.mdx`);
      const path = resolve(docsDir, translatedName);
      let text;
      try {
        text = readFileSync(path, "utf8");
      } catch {
        continue;
      }

      const block = [
        "x-i18n:",
        `  source_path: ${name}`,
        `  source_hash: ${sourceHash(readFileSync(resolve(docsDir, name), "utf8"))}`,
        `  generated_at: ${dateISO}`,
      ].join("\n");

      const front = frontmatter(text);
      if (!front) {
        fail(`stamp: ${translatedName} has no frontmatter`);
        continue;
      }
      const withoutBlock = front
        .replace(/\nx-i18n:(?:\n[ \t]+.*)*/g, "")
        .replace(/\s+$/, "");
      const updated = text.replace(
        /^---\n[\s\S]*?\n---/,
        `---\n${withoutBlock}\n${block}\n---`,
      );
      if (updated !== text) {
        writeFileSync(path, updated);
        stamped += 1;
      }
    }
  }

  notes.push(`stamp: updated ${stamped} translation(s)`);
}

// --------------------------------------------------------------------- main

// The anchor rules are exported so they can be tested directly: they encode how
// the docs pipeline slugifies a heading, and a slugifier that disagrees with the
// renderer rejects correct links. See docs-check.test.mjs.
export { headingAnchor, pageAnchors };

// The checks run only when this file is the command being executed. Importing it
// from a test must not run them, or the test inherits its exit code.
if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const only = process.argv.slice(2);
  const stampArg = only.find(
    (arg) => arg === "--stamp" || arg.startsWith("--stamp="),
  );
  const run = (flag) => only.length === 0 || only.includes(flag);

  if (stampArg) {
    // The date the translation was generated. Can be passed in rather than read
    // from the clock so a re-run is reproducible: --stamp=2026-08-10.
    const given = stampArg.startsWith("--stamp=")
      ? stampArg.slice("--stamp=".length)
      : undefined;
    stampTranslations(given ?? new Date().toISOString().slice(0, 10));
  }

  if (run("--changelog")) checkChangelog();
  if (run("--i18n")) checkI18n();
  if (run("--links")) checkLinks();

  for (const note of notes) console.log(note);
  if (errors.length > 0) {
    console.error("");
    for (const error of errors) console.error(`✗ ${error}`);
    console.error(`\n${errors.length} problem(s) found.`);
    process.exit(1);
  }
  console.log("docs-check: ok");
}
