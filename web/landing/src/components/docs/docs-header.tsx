import Link from "next/link";
import { Logo } from "@/components/logo";
import { GitHubMark } from "@/components/section-label";
import { ThemeSwitch } from "@/components/docs/theme-switch";
import { docsChrome } from "@/lib/docs-ui";
import type { DocsLanguage } from "@/lib/i18n";
import { githubUrl, downloadUrl } from "@/lib/site";

// The docs get their own top bar rather than the landing's floating pill. The
// pill is marketing chrome — it floats over a hero and pulls the eye; docs chrome
// should sit still, hold the reading column's edge, and carry the controls that
// only exist here (language, appearance). Same shape better-auth gives its docs:
// a fixed-height bar with a hairline under it, flush to the top of the page.
export function DocsHeader({ lang }: { lang: DocsLanguage }) {
  const chrome = docsChrome(lang);
  // The wordmark always goes to the site root: only the docs are translated, so
  // `/zh-CN` is not a page — it 404s. The locale lives on the Docs link below.
  const home = "/";
  const docsHome = lang === "en" ? "/docs" : `/${lang}/docs`;

  return (
    // Opaque, and no backdrop-filter. A translucent blurred header has to
    // re-sample the content moving underneath it on every frame, and that
    // re-rasterisation is what makes the sticky rails beside it shimmer while you
    // scroll. The landing's pill can afford the effect because it floats over a
    // hero; here there is nothing behind the bar worth seeing through it.
    <header className="sticky top-0 z-50 border-b border-border bg-background">
      <div className="mx-auto flex h-14 w-full max-w-7xl items-center gap-3 px-5 sm:px-8">
        <Link
          href={home}
          className="group flex shrink-0 items-center rounded-md focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring"
          aria-label="Termio"
        >
          <Logo />
        </Link>
        {/* Says which section of the site you're in, the way better-auth's bar
            carries a version tag — quiet, and a link back to the docs root. */}
        <Link
          href={docsHome}
          className="hidden rounded-md border border-border px-2 py-0.5 text-[12px] text-muted-foreground no-underline transition-colors hover:text-foreground sm:inline-block"
        >
          {chrome.docsLabel}
        </Link>

        <div className="ml-auto flex items-center gap-2">
          <ThemeSwitch chrome={chrome} />
          <span
            className="hidden h-5 w-px bg-border sm:block"
            aria-hidden="true"
          />
          <a
            href={githubUrl}
            target="_blank"
            rel="noreferrer"
            aria-label="Termio on GitHub"
            className="hidden h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground sm:inline-flex"
          >
            <GitHubMark className="h-4 w-4" />
          </a>
          <a
            href={downloadUrl}
            className="hidden h-7 items-center rounded-lg bg-primary px-3 text-[12px] font-semibold text-primary-foreground no-underline transition-all hover:brightness-110 active:scale-[0.98] md:inline-flex"
          >
            {chrome.download}
          </a>
        </div>
      </div>
    </header>
  );
}
