import { execFileSync } from "node:child_process";
import type { MetadataRoute } from "next";
import { changelog } from "@/data/changelog";
import { i18n, languageTags } from "@/lib/i18n";
import { source } from "@/lib/source";

// /colors is a design scratch page and is deliberately left out (it is also
// noindexed via its own layout).
// When a page last actually changed, read from git at build time. `lastModified`
// is a freshness signal, and stamping fifteen pages with one shared release date
// tells a crawler they all change together, which is false. Falls back to the
// release date where git history isn't available (a shallow CI checkout).
function lastEdited(path: string, fallback: Date): Date {
  try {
    const stamp = execFileSync(
      "git",
      ["log", "-1", "--format=%cI", "--", path],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    return stamp ? new Date(stamp) : fallback;
  } catch {
    return fallback;
  }
}

export default function sitemap(): MetadataRoute.Sitemap {
  const latestRelease = new Date(`${changelog[0].date}T12:00:00Z`);
  // Every locale of a page is listed, each carrying the alternates map, which is
  // how Google is told the pages are translations rather than duplicates.
  const docPages: MetadataRoute.Sitemap = source.getPages().map((page) => {
    const slug = page.slugs;
    const languages: Record<string, string> = {};
    for (const language of i18n.languages) {
      const path = ["docs", ...slug].join("/");
      languages[languageTags[language] ?? language] =
        language === i18n.defaultLanguage
          ? `https://www.termio.sh/${path}`
          : `https://www.termio.sh/${language}/${path}`;
    }
    return {
      url: `https://www.termio.sh${page.url}`,
      lastModified: lastEdited(`content/docs/${page.path}`, latestRelease),
      changeFrequency: "weekly" as const,
      priority: 0.6,
      alternates: { languages },
    };
  });
  return [
    ...docPages,
    {
      url: "https://www.termio.sh/",
      lastModified: latestRelease,
      changeFrequency: "weekly",
      priority: 1,
    },
    {
      url: "https://www.termio.sh/changelog",
      lastModified: latestRelease,
      changeFrequency: "weekly",
      priority: 0.7,
    },
    {
      url: "https://www.termio.sh/privacy",
      changeFrequency: "yearly",
      priority: 0.3,
    },
    {
      url: "https://www.termio.sh/terms",
      changeFrequency: "yearly",
      priority: 0.3,
    },
  ];
}
