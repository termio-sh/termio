import { defineDocs, defineConfig } from "fumadocs-mdx/config";

// The docs collection lives under content/docs. Fumadocs MDX compiles each .mdx
// file into a React component (page.data.body) plus a table of contents, which
// our own headless UI renders — we use fumadocs-core only, none of fumadocs-ui.
export const docs = defineDocs({
  dir: "content/docs",
});

export default defineConfig();
