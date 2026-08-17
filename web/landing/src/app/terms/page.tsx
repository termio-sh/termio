import type { Metadata } from "next";
import { SiteNav } from "@/components/site-nav";
import { SiteFooter } from "@/components/site-footer";
import { SectionLabel } from "@/components/section-label";
import { Reveal } from "@/components/reveal";

export const metadata: Metadata = {
  title: "Terms of Use",
  description:
    "The terms for using Termio — the native Mac workspace for AI coding agents and its iPhone companion.",
  alternates: {
    canonical: "/terms",
  },
  openGraph: {
    title: "Termio terms of use",
    description:
      "The terms for using Termio — the native Mac workspace for AI coding agents and its iPhone companion.",
    url: "/terms",
  },
};

export default function TermsPage() {
  return (
    <>
      <SiteNav />
      <main className="flex-1">
        <section className="scroll-mt-24">
          <div className="mx-auto w-full px-5 pb-32 pt-36 sm:px-8 sm:pb-40 sm:pt-44">
            <Reveal className="mx-auto mb-14 w-full max-w-[680px] text-center sm:mb-20">
              <SectionLabel accent="muted">Terms</SectionLabel>
              <h1 className="mt-4 text-balance text-4xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-5xl">
                Terms of Use
              </h1>
              <p className="mx-auto mt-5 max-w-md text-base leading-relaxed text-muted-foreground">
                Last updated: July 4, 2026
              </p>
            </Reveal>

            <article className="prose-legal mx-auto w-full max-w-[640px]">
              <h2>Acceptance of terms</h2>
              <p>
                By downloading, installing or using Termio — the Mac app or its
                iPhone companion — you agree to these Terms of Use. If you do
                not agree, do not use Termio.
              </p>

              <h2>About Termio</h2>
              <p>
                Termio is a native Mac workspace for running AI coding agents,
                with an iPhone companion app for controlling sessions on your
                own Mac. It is free to use and provided as-is, without
                warranties or guarantees of any kind.
              </p>

              <h2>Acceptable use</h2>
              <p>
                You agree to use Termio responsibly and in compliance with
                applicable laws. You must not:
              </p>
              <ul>
                <li>Use Termio for any illegal or unauthorized purpose</li>
                <li>
                  Attempt to harm, disable or impair Termio or the systems it
                  connects to
                </li>
                <li>
                  Violate the terms of service of any AI provider you use
                  through Termio
                </li>
              </ul>

              <h2>Third-party services</h2>
              <p>
                The coding agents you run inside Termio (such as Claude Code or
                Codex) are third-party tools that connect to their own
                providers. You acknowledge that:
              </p>
              <ul>
                <li>
                  You are responsible for complying with those providers&apos;
                  terms of service
                </li>
                <li>
                  You need your own valid accounts or API keys with those
                  providers
                </li>
                <li>
                  Costs arising from your use of those services are your
                  responsibility
                </li>
                <li>
                  Termio is not responsible for their availability or
                  performance
                </li>
              </ul>

              <h2>Independence</h2>
              <p>
                Termio is an independent project. It is not affiliated with,
                endorsed by or connected to Anthropic, OpenAI, Google or any
                other AI service provider. All product names and trademarks
                belong to their respective owners.
              </p>

              <h2>Updates</h2>
              <p>
                The Mac app keeps itself current through built-in auto-updates.
                Updates may add, change or remove functionality.
              </p>

              <h2>Limitation of liability</h2>
              <p>
                Termio is provided <strong>&quot;as is&quot;</strong> without
                warranty of any kind. To the maximum extent permitted by law,
                the developers and distributors of Termio shall not be liable
                for any direct, indirect, incidental or consequential damages —
                including data loss, lost profits or business interruption —
                arising from your use of Termio. You run AI agents on your own
                machine at your own discretion; review what they do before
                trusting the result.
              </p>

              <h2>Changes to these terms</h2>
              <p>
                We may update these terms from time to time. Continued use of
                Termio after changes constitutes acceptance of the new terms.
              </p>

              <h2>Governing law</h2>
              <p>
                These terms shall be governed by and construed in accordance
                with applicable law, without regard to conflict-of-law
                principles.
              </p>

              <h2>Severability</h2>
              <p>
                If any provision of these terms is found unenforceable, it will
                be limited to the minimum extent necessary so that the rest of
                the terms remain in full force and effect.
              </p>

              <h2>Contact</h2>
              <p>
                Questions about these terms? Open an issue at{" "}
                <a
                  href="https://github.com/termio-sh/termio/issues"
                  target="_blank"
                  rel="noreferrer"
                >
                  github.com/termio-sh/termio
                </a>
                .
              </p>
            </article>
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
