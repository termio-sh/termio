import { source } from "@/lib/source";

// Serves a doc page's raw Markdown. Reached as /docs/<slug>.md via the rewrite
// in next.config.ts — a route handler can't sit beside the docs page.tsx, so
// the real path is /docs-md/<slug>. The docs index answers to /docs/index.md.
// Every page prerenders at build time: getText("raw") reads the content/docs
// sources from disk, which aren't in the serverless bundle at request time.
export const dynamic = "force-static";
export const dynamicParams = false;

export function generateStaticParams() {
  return source.getPages().map((page) => ({
    slug: page.slugs.length ? page.slugs : ["index"],
  }));
}

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ slug: string[] }> },
) {
  const { slug } = await params;
  const page = source.getPage(slug.join("/") === "index" ? [] : slug);
  if (!page) return new Response("Not found", { status: 404 });

  const raw = await page.data.getText("raw");
  return new Response(raw, {
    headers: { "Content-Type": "text/markdown; charset=utf-8" },
  });
}
