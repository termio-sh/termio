import type { Viewport } from "next";
import { notFound } from "next/navigation";
import { DocsFrame } from "@/components/docs/docs-frame";
import { i18n, isDocsLanguage } from "@/lib/i18n";

// Same as the English docs: the browser chrome follows the page, not the landing.
export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#08080a" },
  ],
};

// The translated docs. English is served prefix-free by /docs, so /en/docs is not
// a second address for the same page — it 404s.
export default async function LocalizedDocsLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  if (!isDocsLanguage(lang) || lang === i18n.defaultLanguage) notFound();

  return <DocsFrame lang={lang}>{children}</DocsFrame>;
}
