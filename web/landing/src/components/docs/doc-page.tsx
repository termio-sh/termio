import type { ReactNode } from "react";
import { HugeiconsIcon } from "@hugeicons/react";
import { File01Icon } from "@hugeicons/core-free-icons";
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
import { AskAIMenu } from "@/components/docs/ask-ai-menu";
import { docsChrome } from "@/lib/docs-ui";
import { siteUrl } from "@/lib/docs-llms";
import { i18n, languageTags, type DocsLanguage } from "@/lib/i18n";

/** The public URL of a doc page in a given language. */
export function docUrl(lang: string, slug: string[]): string {
  const path = ["docs", ...slug].join("/");
  return lang === i18n.defaultLanguage ? `/${path}` : `/${lang}/${path}`;
}

/** The page's social card, drawn by the /docs-og handler. English only. */
function cardUrl(slug: string[]): string {
  return `/docs-og/${slug.length ? slug.join("/") : "index"}`;
}

/** The raw-Markdown twin of a page — /docs/<slug>.md, rewritten to /docs-md. */
function markdownUrl(url: string): string {
  return url.endsWith("/docs") ? `${url}/index.md` : `${url}.md`;
}

/** The tree section a page sits in — "Getting Started", "Agents", "Customize".
 *
 *  Not the library's breadcrumb: that is built from folders, and this tree has
 *  none. Its sections are the `---Getting Started---` separators in meta.json,
 *  which are siblings of the pages rather than parents of them, so the section a
 *  page belongs to is simply the last separator above it. */
function sectionOf(
  tree: ReturnType<typeof source.getPageTree>,
  url: string,
): ReactNode | undefined {
  let section: ReactNode | undefined;
  for (const node of tree.children) {
    if (node.type === "separator") section = node.name;
    else if (node.type === "page" && node.url === url) return section;
  }
  return undefined;
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

  // One card per page, so a docs link in a thread carries the page's own name
  // instead of the landing hero every other link already showed. It is drawn from
  // the English title — see the note in the /docs-og handler — so a translated
  // page shares the English card rather than a boxes-for-glyphs one.
  const english = source.getPage(slug, i18n.defaultLanguage);
  const card = {
    url: cardUrl(english ? slug : []),
    width: 1200,
    height: 630,
    type: "image/png",
    alt: `${english?.data.title ?? title} — Termio documentation`,
  };

  return {
    title,
    description,
    alternates: {
      canonical: docUrl(lang, slug),
      languages,
      // The Markdown twin, named in the page's own head. An agent that reads the
      // HTML once can find the clean copy without guessing at a `.md` suffix.
      types: {
        "text/markdown": [
          { url: markdownUrl(docUrl(lang, slug)), title: page.data.title },
        ],
      },
    },
    openGraph: { title, description, url: docUrl(lang, slug), images: [card] },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [card],
    },
  };
}

// The page frame — table of contents, breadcrumbs, prev/next, the edit link —
// is fumadocs-ui's. What stays ours are the page actions, because they exist for a
// readership that is driving coding agents: copy the page as Markdown, hand it to
// an assistant, or open its raw `.md` twin.
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
  const section = sectionOf(source.getPageTree(lang), page.url);
  const MDX = page.data.body;
  const raw = await page.data.getText("raw");

  // The library's prev/next pager and a hand-authored `<Cards>` block answer the
  // same question, so a page carrying both offered the reader two stacked rows of
  // destination cards — and on Concepts they collided outright: the pager's
  // *previous* page was "Your first session", which the Cards block was offering
  // as a next step. Four pages curate their own next steps; the other eleven rely
  // on the pager. So a page does one or the other, decided by what it contains.
  const curatesNextSteps = raw.includes("<Cards>");

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

  const actions = (
    <div className="docs-page-actions shrink-0 border-t border-fd-border py-3">
      <CopyMarkdownButton
        markdown={raw}
        labels={{
          copy: chrome.copyForLLM,
          copied: chrome.copied,
          aria: chrome.copyAriaLabel,
        }}
      />
      <AskAIMenu
        labels={{
          trigger: chrome.askAI,
          aria: chrome.askAIAriaLabel,
          claude: chrome.askClaude,
          chatgpt: chrome.askChatGPT,
          prompt: chrome.askPrompt.replace(
            "{url}",
            `${siteUrl}${markdownUrl(page.url)}`,
          ),
        }}
      />
      <a
        href={markdownUrl(page.url)}
        aria-label={chrome.markdownAriaLabel}
        className="docs-page-action text-fd-muted-foreground"
      >
        <HugeiconsIcon icon={File01Icon} size={16} aria-hidden="true" />
        {chrome.markdown}
      </a>
    </div>
  );

  return (
    <DocsPage
      toc={page.data.toc}
      full={page.data.full}
      tableOfContent={{
        list: { className: "docs-toc-list", thumbBox: false },
        footer: actions,
      }}
      tableOfContentPopover={{
        list: { className: "docs-toc-list", thumbBox: false },
        footer: actions,
      }}
      footer={{ enabled: !curatesNextSteps }}
      editOnGithub={{
        owner: "termio-sh",
        repo: "termio",
        sha: "main",
        // page.path is relative to the collection dir (content/docs).
        path: `web/landing/content/docs/${page.path}`,
      }}
    >
      {/* The pane's header row: where the page sits in the tree. */}
      <nav
        aria-label="Breadcrumb"
        className="docs-breadcrumb flex items-center gap-1.5 text-[13px] leading-normal text-muted-foreground"
      >
        {section && (
          <>
            <span>{section}</span>
            <span aria-hidden="true">›</span>
          </>
        )}
        <span aria-current="page" className="text-foreground">
          {page.data.title}
        </span>
      </nav>
      <DocsTitle className="text-[33.75px] font-normal leading-[40.5px] tracking-[-0.02em]">
        {page.data.title}
      </DocsTitle>
      <DocsDescription className="page-description mb-8 mt-3 text-[15px] leading-[1.625] sm:mb-9">
        {page.data.description}
      </DocsDescription>
      {/* The skip link in the docs frame lands here — the library's page has no
          anchor of its own, and the frame and the page always render together. */}
      <DocsBody id="docs-content" tabIndex={-1}>
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
