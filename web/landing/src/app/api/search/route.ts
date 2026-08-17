import { source } from "@/lib/source";
import { createFromSource } from "fumadocs-core/search/server";

// Orama search index, built server-side from the docs source and queried by the
// ⌘K dialog (see components/docs/docs-search.tsx). Self-hosted and free — no
// external search service.
//
// One index per locale: the client passes its language, so the Chinese docs never
// answer with English pages. `mandarin` gives Orama the right stop words and
// stemming for zh-CN; segmentation is still whitespace-based, which is good enough
// for a page set this size and costs no extra dependency.
export const { GET } = createFromSource(source, {
  language: "english",
  localeMap: {
    "zh-CN": "mandarin",
  },
});
