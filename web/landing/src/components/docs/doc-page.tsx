import type { Metadata } from "next";
import { notFound } from "next/navigation";
import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
} from "fumadocs-ui/page";
import { source } from "@/lib/source";
import { getMDXComponents } from "@/mdx-components";
import { CopyMarkdownButton } from "@/components/docs/copy-markdown-button";
import { docsChrome } from "@/lib/docs-ui";
import { siteUrl } from "@/lib/docs-llms";
import { i18n, languageTags, type DocsLanguage } from "@/lib/i18n";

/** The public URL of a doc page in a given language. */
export function docUrl(lang: string, slug: string[]): string {
  const path = ["docs", ...slug].join("/");
  return lang === i18n.defaultLanguage ? `/${path}` : `/${lang}/${path}`;
}

/** The raw-Markdown twin of a page — /docs/<slug>.md, rewritten to /docs-md. */
function markdownUrl(url: string): string {
  return url.endsWith("/docs") ? `${url}/index.md` : `${url}.md`;
}

export async function docPageMetadata(
  lang: DocsLanguage,
  slug: string[],
): Promise<Metadata> {
  const page = source.getPage(slug, lang);
  if (!page) return {};

  const { title, description } = page.data;
  // Every locale is listed as an alternate — including x-default, so a search
  // engine has an explicit fallback rather than inferring one.
  const languages: Record<string, string> = { "x-default": docUrl("en", slug) };
  for (const language of i18n.languages) {
    languages[languageTags[language] ?? language] = docUrl(language, slug);
  }

  return {
    title,
    description,
    alternates: { canonical: docUrl(lang, slug), languages },
    openGraph: { title, description, url: docUrl(lang, slug) },
  };
}

// The page frame — table of contents, breadcrumbs, prev/next, the edit link —
// is fumadocs-ui's. What stays ours are the two page actions, because they exist
// for a readership that is driving coding agents: copy the page as Markdown, or
// open its raw `.md` twin.
export async function DocPage({
  lang,
  slug,
}: {
  lang: DocsLanguage;
  slug: string[];
}) {
  const page = source.getPage(slug, lang);
  if (!page) notFound();

  const chrome = docsChrome(lang);
  const MDX = page.data.body;
  const raw = await page.data.getText("raw");

  // Structured data. `TechArticle` is what a documentation page is, and stating it
  // lets a search engine treat the page as documentation rather than guessing from
  // the markup; `BreadcrumbList` is what produces the "Termio › Docs › …" trail
  // under a result instead of a bare URL. Both are cheap and neither duplicates
  // anything the <meta> tags already say.
  const url = `${siteUrl}${docUrl(lang, slug)}`;
  const jsonLd = [
    {
      "@context": "https://schema.org",
      "@type": "TechArticle",
      headline: page.data.title,
      description: page.data.description,
      inLanguage: languageTags[lang] ?? lang,
      url,
      mainEntityOfPage: url,
      isPartOf: {
        "@type": "WebSite",
        name: "Termio",
        url: siteUrl,
      },
      publisher: {
        "@type": "Organization",
        name: "Termio",
        url: siteUrl,
      },
    },
    {
      "@context": "https://schema.org",
      "@type": "BreadcrumbList",
      itemListElement: [
        { "@type": "ListItem", position: 1, name: "Termio", item: siteUrl },
        {
          "@type": "ListItem",
          position: 2,
          name: chrome.docsLabel,
          item: `${siteUrl}${docUrl(lang, [])}`,
        },
        ...(slug.length
          ? [
              {
                "@type": "ListItem",
                position: 3,
                name: page.data.title,
                item: url,
              },
            ]
          : []),
      ],
    },
  ];

  return (
    <DocsPage
      toc={page.data.toc}
      full={page.data.full}
      tableOfContent={{ style: "clerk" }}
      editOnGithub={{
        owner: "termio-sh",
        repo: "termio",
        sha: "main",
        // page.path is relative to the collection dir (content/docs).
        path: `web/landing/content/docs/${page.path}`,
      }}
    >
      {/* Actions sit on the title's row, hard right: they are page-level tools,
          not part of the prose, and below the description they read as the first
          thing to do rather than something available throughout. */}
      <div className="flex items-start justify-between gap-6">
        <div className="min-w-0">
          <DocsTitle>{page.data.title}</DocsTitle>
          <DocsDescription>{page.data.description}</DocsDescription>
        </div>
        <div className="mt-1 flex shrink-0 items-center gap-1">
          <CopyMarkdownButton
            markdown={raw}
            labels={{
              copy: chrome.copyForLLM,
              copied: chrome.copied,
              aria: chrome.copyAriaLabel,
            }}
          />
          <a
            href={markdownUrl(page.url)}
            aria-label={chrome.markdownAriaLabel}
            className="inline-flex h-7 items-center gap-1.5 rounded-lg px-2 text-[12px] font-medium text-fd-muted-foreground no-underline transition-colors hover:bg-fd-accent hover:text-fd-accent-foreground"
          >
            <MarkdownIcon className="h-3.5 w-3.5" />
            {chrome.markdown}
          </a>
        </div>
      </div>
      <DocsBody>
        <MDX components={getMDXComponents()} />
      </DocsBody>
      <script
        type="application/ld+json"
        // Schema.org data is not markup React can render; it ships as a literal
        // JSON payload the crawler reads.
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
    </DocsPage>
  );
}

function MarkdownIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="M14 3v4a1 1 0 0 0 1 1h4" />
      <path d="M5 8V5a2 2 0 0 1 2-2h7l5 5v11a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-3" />
      <path d="M2 12h6v5M2 17v-5l3 3 3-3" />
    </svg>
  );
}
