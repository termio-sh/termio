import type { Viewport } from "next";
import { DocsFrame } from "@/components/docs/docs-frame";
import { i18n } from "@/lib/i18n";

// The docs follow the reader's system appearance, so the browser chrome has to
// as well — otherwise Safari paints a black bar above a white page.
export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#08080a" },
  ],
};

// English docs keep the prefix-free URLs they shipped with; every other locale is
// served by /[lang]/docs. Both render the same frame.
export default function DocsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return <DocsFrame lang={i18n.defaultLanguage}>{children}</DocsFrame>;
}
