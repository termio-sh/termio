import type { Metadata, Viewport } from "next";
import { Analytics } from "@vercel/analytics/next";
import "./globals.css";
import { DocsThemeScript } from "@/components/docs/theme-script";

const siteDescription =
  "Termio is the Terminal-first Agentic Development Environment — a native Mac app for your AI coding agents: Claude Code, Codex, OpenCode, Pi Agent and more. Run them side by side, each in a real terminal, switch between them instantly, and nothing ever leaves your machine.";

export const metadata: Metadata = {
  metadataBase: new URL("https://www.termio.sh"),
  title: {
    default: "Termio — the Terminal-first Agentic Development Environment",
    template: "%s — Termio",
  },
  description: siteDescription,
  keywords: [
    "Termio",
    "AI coding agents",
    "terminal",
    "macOS terminal",
    "Claude Code",
    "Codex",
    "git worktree",
    "Apple Silicon",
    "Intel Mac",
  ],
  applicationName: "Termio",
  alternates: {
    canonical: "/",
  },
  openGraph: {
    title: "Termio — the Terminal-first Agentic Development Environment",
    description: siteDescription,
    type: "website",
    siteName: "Termio",
    url: "/",
    images: [
      {
        url: "/og.webp",
        type: "image/webp",
        width: 2400,
        height: 1260,
        alt: "Termio — orchestrate your fleet of agents. A real Termio window with a sidebar of agent sessions beside a live Codex session.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Termio — the Terminal-first Agentic Development Environment",
    description: siteDescription,
    images: ["/og.webp"],
  },
};

export const viewport: Viewport = {
  themeColor: "#08080a",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    // suppressHydrationWarning covers exactly one thing: the docs' theme script
    // (components/docs/theme-script.tsx) writes `data-docs-theme` onto <html>
    // before React hydrates, so the server markup and the live DOM legitimately
    // differ by that attribute. It suppresses only this element's own attributes,
    // not anything nested, so real mismatches below still report.
    <html
      lang="en"
      className="dark h-full antialiased"
      // globals.css sets scroll-behavior: smooth; Next wants it declared so it can
      // suppress the animation during route transitions.
      data-scroll-behavior="smooth"
      suppressHydrationWarning
    >
      {/* An explicit <head> so the theme script has a defined position: React
          refuses to place a synchronous <script> loose in the document, and this
          one has to run before the body is parsed. Metadata still flows in here
          from the Metadata API. */}
      <head>
        <DocsThemeScript />
      </head>
      <body className="min-h-full flex flex-col bg-background text-foreground">
        {children}
        <Analytics />
      </body>
    </html>
  );
}
