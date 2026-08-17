import { i18n } from "@/lib/i18n";
import { source } from "@/lib/source";

export const siteUrl = "https://www.termio.sh";

type DocPage = NonNullable<ReturnType<typeof source.getPage>>;

// Doc pages in sidebar (meta.json) order, resolved to full page objects so
// callers get frontmatter and raw Markdown, not just tree nodes. Shared by the
// llms.txt / llms-full.txt routes, which index the English docs — the source of
// truth every translation is generated from.
export function orderedDocPages(lang: string = i18n.defaultLanguage): DocPage[] {
  const byUrl = new Map(source.getPages(lang).map((page) => [page.url, page]));
  const out: DocPage[] = [];
  const walk = (nodes: ReturnType<typeof source.getPageTree>["children"]) => {
    for (const node of nodes) {
      if (node.type === "page") {
        const page = byUrl.get(String(node.url));
        if (page) out.push(page);
      } else if (node.type === "folder") {
        if (node.index) {
          const page = byUrl.get(String(node.index.url));
          if (page) out.push(page);
        }
        walk(node.children);
      }
    }
  };
  walk(source.getPageTree(lang).children);
  return out;
}

// The absolute URL of a page's raw-Markdown twin — /docs/<slug>.md, served by
// the app/docs-md handler via the rewrite in next.config.ts. The docs index has
// no slug of its own, so it lives at /docs/index.md.
export function markdownUrl(page: DocPage): string {
  return page.url === "/docs"
    ? `${siteUrl}/docs/index.md`
    : `${siteUrl}${page.url}.md`;
}

// Strip the YAML frontmatter block getText("raw") includes; llms-full.txt
// renders its own title/URL header instead.
export function stripFrontmatter(raw: string): string {
  return raw.replace(/^---\n[\s\S]*?\n---\n/, "").trim();
}
