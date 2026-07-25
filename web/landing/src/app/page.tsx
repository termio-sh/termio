import { SiteNav } from "@/components/site-nav";
import { Hero } from "@/components/sections/hero";
import { AgentShowcase } from "@/components/sections/agent-showcase";
import { FeatureGrid } from "@/components/sections/feature-grid";
import { Faq } from "@/components/sections/faq";
import { CtaBand } from "@/components/sections/cta-band";
import { SiteFooter } from "@/components/site-footer";
import { HeroGradient } from "@/components/hero-gradient";
import { downloadUrl } from "@/lib/site";

// SoftwareApplication structured data — tells search engines this page is a
// free, native macOS developer app with a direct download.
const appJsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Termio",
  operatingSystem: "macOS",
  applicationCategory: "DeveloperApplication",
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  url: "https://www.termio.sh",
  downloadUrl,
  image: "https://www.termio.sh/og.webp",
  description:
    "Termio is the Terminal-first Agentic Development Environment — a native Mac app for your AI coding agents: Claude Code, Codex, OpenCode, Pi Agent and more. Run them side by side, each in a real terminal, and nothing ever leaves your machine.",
};

export default function Home() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(appJsonLd) }}
      />
      <SiteNav />
      <main className="flex-1">
        <Hero />
        <AgentShowcase />
        <FeatureGrid />
        <Faq />
      </main>
      {/* Shaded outro — mirrors the hero. The CTA band and footer share one slow
          aurora (same MeshGradient), and the footer floats over it as glass,
          echoing the way the nav floats over the hero shader up top. */}
      <div className="hero-cinematic relative isolate overflow-hidden">
        <HeroGradient className="absolute inset-0 -z-10" />
        {/* Frosted film grain over the aurora, matching the hero. */}
        <div
          aria-hidden="true"
          className="grain-overlay pointer-events-none absolute -inset-[6%] -z-10"
        />
        {/* Fade the page above down into the aurora (the hero's bottom fade, flipped). */}
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-72 bg-gradient-to-b from-background to-transparent"
        />
        <CtaBand />
        <SiteFooter />
      </div>
    </>
  );
}
