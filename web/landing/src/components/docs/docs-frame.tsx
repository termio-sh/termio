import type { ReactNode } from "react";
import { RootProvider } from "fumadocs-ui/provider/next";
import { DocsLayout } from "fumadocs-ui/layouts/docs";
import { SearchTrigger } from "fumadocs-ui/layouts/shared/slots/search-trigger";
import { Logo } from "@/components/logo";
import { GitHubMark } from "@/components/section-label";
import { ThemeSwitch } from "@/components/theme-switch";
import { source } from "@/lib/source";
import { docsChrome, docsLibraryChrome } from "@/lib/docs-ui";
import { i18n, languageNames, type DocsLanguage } from "@/lib/i18n";
import { downloadUrl, githubUrl } from "@/lib/site";

// The docs chrome is fumadocs-ui's: sidebar, mobile nav, search dialog, table of
// contents, breadcrumbs. Everything interactive here used to be hand-written, and
// every layout bug this site had came from that code — stacking contexts, focus
// handling, sticky scroll ranges. The library has solved those already.
//
// There is no top bar. The wordmark and a search button head the sidebar, and the
// appearance switch, GitHub and Download sit at its foot, so the sidebar and the
// page both run the full height of the window. Below `md` the library's own
// mobile bar and drawer carry the same controls.
//
// The appearance switch stays ours rather than the library's: this site's dark
// landing and switchable docs need theming keyed on `data-theme` rather than
// next-themes writing a class onto <html> for every route.
export function DocsFrame({
  lang,
  children,
}: {
  lang: DocsLanguage;
  children: ReactNode;
}) {
  const chrome = docsChrome(lang);

  return (
    <div className="docs-surface flex min-h-full flex-1 flex-col" lang={lang}>
      <RootProvider
        theme={{ enabled: false }}
        i18n={{
          locale: lang,
          locales: i18n.languages.map((language) => ({
            locale: language,
            name: languageNames[language] ?? language,
          })),
          translations: docsLibraryChrome(lang),
        }}
      >
        {/* Every docs page opens with a sidebar tree and a search field
            before the prose starts. A keyboard or screen-reader user should not have
            to walk them on every page — the first thing the tab order offers is the
            way past them. Invisible until focused. */}
        <a
          href="#docs-content"
          className="sr-only z-[100] focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:inline-flex focus:h-9 focus:items-center focus:rounded-lg focus:bg-primary focus:px-3 focus:text-[13px] focus:font-semibold focus:text-primary-foreground focus:no-underline focus:outline-2 focus:outline-offset-2 focus:outline-ring"
        >
          {chrome.skipToContent}
        </a>
        <DocsLayout
          tree={source.getPageTree(lang)}
          // The wordmark always goes to the site root: only the docs are
          // translated, so `/zh-CN` is not a page.
          nav={{
            title: <Logo />,
            url: "/",
            children: (
              <SearchTrigger
                aria-label={chrome.searchTrigger}
                className="docs-search-button text-muted-foreground"
              />
            ),
          }}
          themeSwitch={{ enabled: false }}
          // Collapsing a five-section tree buys nothing on a docs set this size.
          sidebar={{
            defaultOpenLevel: 1,
            collapsible: false,
            footer: (
              <div className="flex items-center gap-2">
                <ThemeSwitch labels={chrome} />
                <a
                  href={githubUrl}
                  target="_blank"
                  rel="noreferrer"
                  aria-label="Termio on GitHub"
                  className="ml-auto inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground"
                >
                  <GitHubMark className="h-4 w-4" />
                </a>
                <a
                  href={downloadUrl}
                  className="docs-sidebar-download inline-flex h-7 items-center rounded-lg bg-primary px-3 text-[12px] font-semibold text-primary-foreground no-underline transition-all hover:brightness-110 active:scale-[0.98]"
                >
                  {chrome.download}
                </a>
              </div>
            ),
          }}
          containerProps={{ className: "flex-1" }}
        >
          {children}
        </DocsLayout>
      </RootProvider>
      <span className="sr-only">{chrome.docsLabel}</span>
    </div>
  );
}
