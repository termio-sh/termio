import type { ReactNode } from "react";
import { RootProvider } from "fumadocs-ui/provider/next";
import { DocsLayout } from "fumadocs-ui/layouts/docs";
import { DocsHeader } from "@/components/docs/docs-header";
import { source } from "@/lib/source";
import { docsChrome } from "@/lib/docs-ui";
import { i18n, languageNames, type DocsLanguage } from "@/lib/i18n";
import { githubUrl } from "@/lib/site";

// The docs chrome is fumadocs-ui's: sidebar, mobile nav, search dialog, table of
// contents, breadcrumbs. Everything interactive here used to be hand-written, and
// every layout bug this site had came from that code — stacking contexts, focus
// handling, sticky scroll ranges. The library has solved those already.
//
// Two things stay ours, and both are declarative rather than interactive:
//
//   - the header, because the docs deliberately don't wear the landing's floating
//     marketing pill (`nav={{ enabled: false }}`, the same escape hatch
//     better-auth uses);
//   - the appearance switch, because this site's dark landing and switchable docs
//     need theming scoped to `.docs-surface` rather than next-themes writing a
//     class onto <html> for every route.
//
// The header's height is handed to the library through `--fd-banner-height` in
// globals.css — that is the row it reserves for anything sitting above the docs.
export function DocsFrame({
  lang,
  children,
}: {
  lang: DocsLanguage;
  children: ReactNode;
}) {
  const chrome = docsChrome(lang);

  return (
    <div
      className="docs-surface flex min-h-full flex-1 flex-col"
      lang={lang}
    >
      <RootProvider
        theme={{ enabled: false }}
        i18n={{
          locale: lang,
          locales: i18n.languages.map((language) => ({
            locale: language,
            name: languageNames[language] ?? language,
          })),
        }}
      >
        <DocsHeader lang={lang} />
        <DocsLayout
          tree={source.getPageTree(lang)}
          nav={{ enabled: false }}
          themeSwitch={{ enabled: false }}
          githubUrl={githubUrl}
          // No collapse toggle: our header already brands the page, so that row
          // held nothing but the button, and collapsing a five-section tree buys
          // nothing on a docs set this size.
          sidebar={{ defaultOpenLevel: 1, collapsible: false }}
          containerProps={{ className: "flex-1" }}
        >
          {children}
        </DocsLayout>
      </RootProvider>
      <span className="sr-only">{chrome.docsLabel}</span>
    </div>
  );
}
