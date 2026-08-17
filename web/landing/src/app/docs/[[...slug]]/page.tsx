import type { Metadata } from "next";
import { DocPage, docPageMetadata } from "@/components/docs/doc-page";
import { i18n } from "@/lib/i18n";
import { source } from "@/lib/source";

type PageParams = { slug?: string[] };

// One entry per doc page, so the whole docs tree is statically generated.
export function generateStaticParams() {
  return source
    .generateParams()
    .filter((entry) => entry.lang === i18n.defaultLanguage)
    .map(({ slug }) => ({ slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<PageParams>;
}): Promise<Metadata> {
  const { slug } = await params;
  return docPageMetadata(i18n.defaultLanguage, slug ?? []);
}

export default async function Page({
  params,
}: {
  params: Promise<PageParams>;
}) {
  const { slug } = await params;
  return <DocPage lang={i18n.defaultLanguage} slug={slug ?? []} />;
}
