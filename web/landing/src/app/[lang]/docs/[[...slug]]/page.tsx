import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { DocPage, docPageMetadata } from "@/components/docs/doc-page";
import { i18n, isDocsLanguage } from "@/lib/i18n";
import { source } from "@/lib/source";

type PageParams = { lang: string; slug?: string[] };

// Every translated page prerenders; English is excluded because /docs serves it.
export function generateStaticParams() {
  return source
    .generateParams()
    .filter((entry) => entry.lang && entry.lang !== i18n.defaultLanguage)
    .map(({ slug, lang }) => ({ slug, lang: lang as string }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<PageParams>;
}): Promise<Metadata> {
  const { lang, slug } = await params;
  if (!isDocsLanguage(lang) || lang === i18n.defaultLanguage) return {};
  return docPageMetadata(lang, slug ?? []);
}

export default async function Page({
  params,
}: {
  params: Promise<PageParams>;
}) {
  const { lang, slug } = await params;
  if (!isDocsLanguage(lang) || lang === i18n.defaultLanguage) notFound();
  return <DocPage lang={lang} slug={slug ?? []} />;
}
