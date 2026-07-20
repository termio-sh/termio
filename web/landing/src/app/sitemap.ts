import type { MetadataRoute } from "next";
import { changelog } from "@/data/changelog";
import { source } from "@/lib/source";

// /colors is a design scratch page and is deliberately left out (it is also
// noindexed via its own layout).
export default function sitemap(): MetadataRoute.Sitemap {
  const latestRelease = new Date(`${changelog[0].date}T12:00:00Z`);
  const docPages: MetadataRoute.Sitemap = source.getPages().map((page) => ({
    url: `https://www.termio.sh${page.url}`,
    lastModified: latestRelease,
    changeFrequency: "weekly",
    priority: 0.6,
  }));
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
      url: "https://www.termio.sh/docs/atp",
      changeFrequency: "monthly",
      priority: 0.6,
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
