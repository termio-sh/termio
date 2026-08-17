import { defineI18n } from "fumadocs-core/i18n";

// The docs are translated; the rest of the site is not (yet). English keeps its
// existing URLs — /docs/keyboard — and a locale gets a prefix: /zh-CN/docs/keyboard.
// `hideLocale: "default-locale"` is what buys that asymmetry, so no English URL
// ever moves and no redirect is needed.
//
// Adding a locale is three steps: add it here, translate content/docs/*.<locale>.mdx
// plus meta.<locale>.json, and add its glossary under content/docs/.i18n. The
// English page is always the source of truth — `pnpm docs:check` fails when a
// translation is missing, restructured, or stale against it.
export const i18n = defineI18n({
  defaultLanguage: "en",
  languages: ["en", "zh-CN"],
  hideLocale: "default-locale",
});

export type DocsLanguage = (typeof i18n.languages)[number];

/** Endonyms, the way the language switcher should name each one. */
export const languageNames: Record<string, string> = {
  en: "English",
  "zh-CN": "简体中文",
};

/** Short forms, for the header switcher on a phone where the endonyms don't fit. */
export const languageShortNames: Record<string, string> = {
  en: "EN",
  "zh-CN": "中文",
};

/** The `hreflang` value for a locale, for the alternates map. */
export const languageTags: Record<string, string> = {
  en: "en",
  "zh-CN": "zh-Hans",
};

export function isDocsLanguage(value: string | undefined): value is DocsLanguage {
  return value !== undefined && (i18n.languages as readonly string[]).includes(value);
}
