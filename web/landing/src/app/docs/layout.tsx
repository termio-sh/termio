import { source } from "@/lib/source";
import { SiteNav } from "@/components/site-nav";
import { SiteFooter } from "@/components/site-footer";
import { DocsSidebar } from "@/components/docs/docs-sidebar";
import { DocsSearch } from "@/components/docs/docs-search";

// The docs shell: the site's floating nav on top, a sticky navigation tree on
// the left (a collapsible disclosure on mobile), and the page in the middle.
// The per-page "On this page" rail lives in the page itself, since it depends on
// the page's table of contents.
export default function DocsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const tree = source.getPageTree();

  return (
    <>
      <SiteNav />
      <main className="flex-1">
        <div className="mx-auto w-full max-w-7xl px-5 pb-24 pt-28 sm:px-8 sm:pt-32">
          <div className="flex gap-10 lg:gap-14">
            <aside className="hidden w-60 shrink-0 lg:block">
              <div className="sticky top-24 space-y-5">
                <DocsSearch />
                <DocsSidebar tree={tree} />
              </div>
            </aside>

            <div className="min-w-0 flex-1">
              {/* Mobile navigation — a native disclosure so it needs no JS. */}
              <details className="mb-8 rounded-xl border border-border lg:hidden">
                <summary className="cursor-pointer list-none px-4 py-3 text-sm font-medium text-foreground marker:content-none">
                  Documentation menu
                </summary>
                <div className="border-t border-border p-3">
                  <DocsSidebar tree={tree} />
                </div>
              </details>

              {children}
            </div>
          </div>
        </div>
      </main>
      <SiteFooter />
    </>
  );
}
