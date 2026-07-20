import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { source } from "@/lib/source";
import { getMDXComponents } from "@/mdx-components";
import { TableOfContents } from "@/components/docs/table-of-contents";
import { CopyMarkdownButton } from "@/components/docs/copy-markdown-button";

type PageParams = { slug?: string[] };

// One entry per doc page, so the whole docs tree is statically generated.
export function generateStaticParams() {
  return source.generateParams();
}

export async function generateMetadata({
  params,
}: {
  params: Promise<PageParams>;
}): Promise<Metadata> {
  const { slug } = await params;
  const page = source.getPage(slug);
  if (!page) return {};

  const { title, description } = page.data;
  return {
    title,
    description,
    alternates: { canonical: page.url },
    openGraph: { title, description, url: page.url },
  };
}

// A flat, meta.json-ordered list of the doc pages, used for the prev/next links.
type Crumb = { url: string; name: string };
function orderedPages(): Crumb[] {
  const out: Crumb[] = [];
  const walk = (nodes: ReturnType<typeof source.getPageTree>["children"]) => {
    for (const node of nodes) {
      if (node.type === "page") out.push({ url: node.url, name: String(node.name) });
      else if (node.type === "folder") {
        if (node.index)
          out.push({ url: node.index.url, name: String(node.index.name) });
        walk(node.children);
      }
    }
  };
  walk(source.getPageTree().children);
  return out;
}

export default async function DocPage({
  params,
}: {
  params: Promise<PageParams>;
}) {
  const { slug } = await params;
  const page = source.getPage(slug);
  if (!page) notFound();

  const MDX = page.data.body;
  const raw = await page.data.getText("raw");
  const pages = orderedPages();
  const index = pages.findIndex((p) => p.url === page.url);
  const previous = index > 0 ? pages[index - 1] : undefined;
  const next =
    index >= 0 && index < pages.length - 1 ? pages[index + 1] : undefined;

  return (
    <div className="flex gap-12 xl:gap-16">
      <div className="min-w-0 max-w-[46rem] flex-1">
        <header className="mb-8">
          <div className="flex items-start justify-between gap-4">
            <h1 className="text-3xl font-semibold leading-tight tracking-tight text-foreground">
              {page.data.title}
            </h1>
            <div className="mt-1">
              <CopyMarkdownButton markdown={raw} />
            </div>
          </div>
          {page.data.description && (
            <p className="mt-3 text-[15px] leading-relaxed text-muted-foreground">
              {page.data.description}
            </p>
          )}
        </header>

        <article className="prose-docs">
          <MDX components={getMDXComponents()} />
        </article>

        {(previous || next) && (
          <nav className="mt-16 grid grid-cols-2 gap-4 border-t border-border pt-8">
            <div>
              {previous && (
                <Link
                  href={previous.url}
                  className="group block rounded-xl border border-border p-4 transition-colors hover:border-foreground/20"
                >
                  <span className="text-[11px] uppercase tracking-[0.08em] text-muted-foreground/70">
                    Previous
                  </span>
                  <span className="mt-1 block text-[14px] font-medium text-foreground">
                    {previous.name}
                  </span>
                </Link>
              )}
            </div>
            <div>
              {next && (
                <Link
                  href={next.url}
                  className="group block rounded-xl border border-border p-4 text-right transition-colors hover:border-foreground/20"
                >
                  <span className="text-[11px] uppercase tracking-[0.08em] text-muted-foreground/70">
                    Next
                  </span>
                  <span className="mt-1 block text-[14px] font-medium text-foreground">
                    {next.name}
                  </span>
                </Link>
              )}
            </div>
          </nav>
        )}
      </div>

      <aside className="hidden w-56 shrink-0 xl:block">
        <div className="sticky top-24">
          <TableOfContents items={page.data.toc} />
        </div>
      </aside>
    </div>
  );
}
