import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { AppleMark } from "@/components/section-label";
import { CtaGrain } from "@/components/cta-grain";
import { downloadUrl, testflightUrl } from "@/lib/site";

export function CtaBand() {
  return (
    <section aria-labelledby="cta-heading">
      <div className="mx-auto w-full max-w-6xl px-5 py-32 sm:py-40 sm:px-8">
        <Reveal>
          <div className="brand-wash shadow-soft relative isolate overflow-hidden rounded-[2rem] border border-white/10 bg-card px-8 py-20 text-center sm:px-16">
            {/* Grainy light waves rolling slowly across the card. */}
            <div
              aria-hidden="true"
              className="pointer-events-none absolute inset-0 -z-10"
            >
              <CtaGrain />
            </div>
            <h2
              id="cta-heading"
              className="mx-auto max-w-2xl text-balance text-3xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-[44px]"
            >
              Stop babysitting terminals
            </h2>
            <p className="mx-auto mt-5 max-w-xl text-lg text-muted-foreground">
              Run Claude Code, Codex, OpenCode, Pi Agent and more side by side in
              one native
              window. Free to use — no account, no card.
            </p>
            <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <a
                href={downloadUrl}
                className={cn(
                  buttonVariants(),
                  "h-12 gap-2 rounded-full px-7 text-base",
                  "shadow-[0_12px_32px_rgba(20,23,28,0.18),0_0_0_1px_rgba(0,211,199,0.14)]",
                )}
              >
                <AppleMark />
                Download for Mac
              </a>
              <a
                href={testflightUrl}
                className={cn(
                  buttonVariants({ variant: "outline" }),
                  "h-12 rounded-full px-7 text-base",
                )}
              >
                Download for iOS Beta
              </a>
            </div>
            <p className="mt-4 text-sm text-muted-foreground">
              Requires macOS 14 or later
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
