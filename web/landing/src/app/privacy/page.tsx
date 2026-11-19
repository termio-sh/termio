import type { Metadata } from "next";
import { SiteNav } from "@/components/site-nav";
import { SiteFooter } from "@/components/site-footer";
import { SectionLabel } from "@/components/section-label";
import { Reveal } from "@/components/reveal";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "Termio is local-first by design: no accounts, no analytics, no telemetry. This policy explains the little that ever touches the network — and why we can't see any of it.",
  alternates: {
    canonical: "/privacy",
  },
  openGraph: {
    title: "Termio privacy policy",
    description:
      "Termio is local-first by design: no accounts, no analytics, no telemetry.",
    url: "/privacy",
  },
};

// Legal prose, changelog-style: a 640px reading column of h2 sections. The
// content is deliberately concrete — it enumerates every network touchpoint the
// app actually has, so the policy stays checkable against the source.
export default function PrivacyPage() {
  return (
    <>
      <SiteNav />
      <main className="flex-1">
        <section className="scroll-mt-24">
          <div className="mx-auto w-full px-5 pb-32 pt-36 sm:px-8 sm:pb-40 sm:pt-44">
            <Reveal className="mx-auto mb-14 w-full max-w-[680px] text-center sm:mb-20">
              <SectionLabel accent="muted">Privacy</SectionLabel>
              <h1 className="mt-4 text-balance text-4xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-5xl">
                Privacy Policy
              </h1>
              <p className="mx-auto mt-5 max-w-md text-base leading-relaxed text-muted-foreground">
                Last updated: July 4, 2026
              </p>
            </Reveal>

            <article className="prose-legal mx-auto w-full max-w-[640px]">
              <h2>Overview</h2>
              <p>
                Termio is local-first by design. There is no account, no
                sign-in, no analytics SDK and no telemetry. Your terminals, your
                code and your agent conversations run and stay on your own Mac —
                they never pass through servers of ours, because there are none
                in the product&apos;s data path.
              </p>

              <h2>What we don&apos;t collect</h2>
              <ul>
                <li>Terminal content, code, prompts or agent conversations</li>
                <li>Personal information — no names, emails or accounts</li>
                <li>Usage analytics or behavioral tracking of any kind</li>
                <li>Crash reports or device fingerprints</li>
              </ul>

              <h2>What Termio stores</h2>
              <p>
                Settings and session metadata are stored locally on your Mac, in
                your user library. They stay on your device and are removed when
                you delete the app and its data.
              </p>

              <h2>When Termio touches the network</h2>
              <p>
                The Mac app makes exactly two kinds of connections of its own:
              </p>
              <ul>
                <li>
                  <strong>Auto-updates.</strong> Termio periodically checks our
                  download server for a newer version (powered by Sparkle). The
                  check carries no account or device identifier — like any HTTPS
                  request, the server sees an IP address and the app version
                  being asked about, nothing more.
                </li>
                <li>
                  <strong>Your own usage dashboards.</strong> If you open the
                  Usage view, Termio reads the credentials your agent CLIs
                  already keep on your Mac and queries the provider&apos;s own
                  usage endpoint directly from your machine. Those credentials
                  go only where they already go — to their own provider — and
                  never to us.
                </li>
              </ul>
              <p>
                The coding agents you run inside Termio (Claude Code, Codex and
                friends) talk to their own providers under your own accounts and
                their own privacy policies. Termio does not proxy, intercept or
                store that traffic.
              </p>

              <h2>The iOS app</h2>
              <p>
                Termio for iPhone connects to exactly one place: the Termio app
                on your own Mac, over your local network or a tunnel you
                configure. There is no relay service in between. The camera is
                used only to scan the pairing QR code shown on your Mac;
                scanning happens on-device and no images are stored or
                transmitted. The iOS app contains no third-party SDKs, no ads
                and no analytics.
              </p>

              <h2>Website &amp; cookies</h2>
              <p>
                termio.sh uses no analytics, no tracking pixels and sets no
                cookies. That is also why you don&apos;t see a cookie banner.
                Our hosting provider keeps standard, short-lived server logs (IP
                address, user agent) to operate the service, as any web host
                does.
              </p>

              <h2>Data sharing</h2>
              <p>
                We do not share your data with anyone — we hold none to share.
              </p>

              <h2>Your rights</h2>
              <p>
                Regulations like the GDPR and CCPA give you rights over data a
                company holds about you. Termio&apos;s answer is structural:
                since we collect nothing, there is nothing to request, export or
                delete on our side. Everything lives on your devices, under your
                control.
              </p>

              <h2>Changes to this policy</h2>
              <p>
                If this policy materially changes, we&apos;ll say so in the
                changelog and update the date at the top of this page.
              </p>

              <h2>Contact</h2>
              <p>
                Questions or concerns? Open an issue at{" "}
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
