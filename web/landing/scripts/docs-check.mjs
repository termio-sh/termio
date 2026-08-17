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
import { fileURLToPath } from "node:url";

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
      fail(`i18n: content/docs/meta.${locale}.json is missing — the sidebar would fall back to English`);
    } else {
      const base = JSON.parse(readFileSync(resolve(docsDir, "meta.json"), "utf8"));
      const translated = JSON.parse(
        readFileSync(resolve(docsDir, `meta.${locale}.json`), "utf8"),
      );
      const strip = (pages) =>
        pages.filter((page) => !page.startsWith("---"));
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
        fail(`i18n: ${name} has no English source (${base} was renamed or removed)`);
      }
    }

    for (const name of english) {
      const translatedName = name.replace(/\.mdx$/, `.${locale}.mdx`);
      if (!present.has(translatedName)) {
        fail(`i18n: ${translatedName} is missing`);
        continue;
      }

      const sourceText = readFileSync(resolve(docsDir, name), "utf8");
      const translatedText = readFileSync(resolve(docsDir, translatedName), "utf8");

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

      const sourceOutline = headingOutline(sourceText);
      const translatedOutline = headingOutline(translatedText);
      if (
        JSON.stringify(sourceOutline) !== JSON.stringify(translatedOutline)
      ) {
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

const only = process.argv.slice(2);
const stampArg = only.find((arg) => arg === "--stamp" || arg.startsWith("--stamp="));
const run = (flag) => only.length === 0 || only.includes(flag);

if (stampArg) {
  // The date the translation was generated. Can be passed in rather than read from
  // the clock so a re-run is reproducible: --stamp=2026-08-10.
  const given = stampArg.startsWith("--stamp=")
    ? stampArg.slice("--stamp=".length)
    : undefined;
  stampTranslations(given ?? new Date().toISOString().slice(0, 10));
}

if (run("--changelog")) checkChangelog();
if (run("--i18n")) checkI18n();

for (const note of notes) console.log(note);
if (errors.length > 0) {
  console.error("");
  for (const error of errors) console.error(`✗ ${error}`);
  console.error(`\n${errors.length} problem(s) found.`);
  process.exit(1);
}
console.log("docs-check: ok");
