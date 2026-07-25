import type { Metadata, Viewport } from "next";
import { Analytics } from "@vercel/analytics/next";
import "./globals.css";

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
    <html lang="en" className="dark h-full antialiased">
      <body className="min-h-full flex flex-col bg-background text-foreground">
        {children}
        <Analytics />
      </body>
    </html>
  );
}
