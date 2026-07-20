import { source } from "@/lib/source";
import { createFromSource } from "fumadocs-core/search/server";

// Orama search index, built server-side from the docs source and queried by the
// ⌘K dialog (see components/docs/docs-search.tsx). Self-hosted and free — no
// external search service.
export const { GET } = createFromSource(source, {
  language: "english",
});
