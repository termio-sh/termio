import { source } from "@/lib/source";
import { i18n, isDocsLanguage } from "@/lib/i18n";

// Serves a doc page's raw Markdown. Reached as /docs/<slug>.md — and
// /<locale>/docs/<slug>.md — via the rewrites in next.config.ts, and at the plain
// page URL for a client that asked for Markdown in its Accept header (src/proxy.ts).
// A route handler can't sit beside the docs page.tsx, so the real path is
// /docs-md/[<locale>/]<slug>.
// The docs index answers to /docs/index.md.
// Every page prerenders at build time: getText("raw") reads the content/docs
// sources from disk, which aren't in the serverless bundle at request time.
export const dynamic = "force-static";
export const dynamicParams = false;

export function generateStaticParams() {
  return source.getPages().flatMap((page) => {
    const slug = page.slugs.length ? page.slugs : ["index"];
    const lang = page.locale ?? i18n.defaultLanguage;
    // English stays at /docs-md/<slug>; a locale carries its prefix.
    return [lang === i18n.defaultLanguage ? { slug } : { slug: [lang, ...slug] }];
  });
}

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ slug: string[] }> },
) {
  const { slug } = await params;

  const [head, ...rest] = slug;
  const localized = isDocsLanguage(head) && head !== i18n.defaultLanguage;
  const lang = localized ? head : i18n.defaultLanguage;
  const path = localized ? rest : slug;

  const page = source.getPage(
    path.join("/") === "index" ? [] : path,
    lang,
  );
  if (!page) return new Response("Not found", { status: 404 });

  const raw = await page.data.getText("raw");
  return new Response(raw, {
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      // Crawlable, deliberately not indexable: this is the same content as the
      // HTML page, and a duplicate URL in the index only competes with it. Agents
      // fetching it directly (llms.txt links here) are unaffected.
      "X-Robots-Tag": "noindex",
    },
  });
}
