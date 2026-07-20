import type { NextConfig } from "next";
import { createMDX } from "fumadocs-mdx/next";

const nextConfig: NextConfig = {
  // Emit a self-contained server bundle so the Docker runtime image only needs
  // the standalone output plus static assets, not the full node_modules tree.
  output: "standalone",
  // /docs/<slug>.md serves a page's raw Markdown for agents (llms.txt links
  // here). The handler lives at /docs-md because a route.ts can't sit beside
  // the docs page.tsx.
  async rewrites() {
    return [{ source: "/docs/:slug.md", destination: "/docs-md/:slug" }];
  },
};

// Wire Fumadocs MDX into the build: this generates the `.source` folder from
// content/docs on `next dev` / `next build` and lets us import compiled MDX.
const withMDX = createMDX();

export default withMDX(nextConfig);
