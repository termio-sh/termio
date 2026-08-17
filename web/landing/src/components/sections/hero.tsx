import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { HeroGradient } from "@/components/hero-gradient";
import { HeroCarousel } from "@/components/hero-carousel";
import { AppleMark } from "@/components/section-label";
import { AgentMarquee } from "@/components/agent-icons";
import { downloadUrl, heroSlides, supportedAgents } from "@/lib/site";

export function Hero() {
  return (
    <section
      id="top"
      className="hero-cinematic relative isolate flex min-h-screen flex-col overflow-hidden text-foreground"
    >
      {/* Slow navy→indigo→violet aurora (WebGL MeshGradient) behind the hero. */}
      <HeroGradient className="absolute inset-0 -z-10" />
      {/* Frosted film grain over the aurora so it reads matte, not glossy. */}
      <div
        aria-hidden="true"
        className="grain-overlay pointer-events-none absolute -inset-[6%] -z-10"
      />
      {/* Fade the hero into the page below. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-72 bg-gradient-to-b from-transparent to-background"
      />
      <div className="relative mx-auto flex w-full max-w-6xl flex-1 flex-col items-center justify-center px-5 pb-20 pt-36 text-center sm:px-8 sm:pt-40">
        <Reveal>
          {/* Category line: quiet title-case medium text, not an
              uppercase letterspaced label. */}
          <p className="text-base font-medium text-muted-foreground sm:text-xl">
            Terminal-first Agentic Development Environment
          </p>
        </Reveal>
        <Reveal delayMs={40}>
          <h1 className="mt-5 text-balance text-5xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-6xl">
            Orchestrate your fleet of agents.
          </h1>
        </Reveal>
        <Reveal delayMs={160} className="mt-12 w-full">
          <div className="mx-auto max-w-5xl [perspective:2400px]">
            <div className="origin-bottom [transform:rotateX(7deg)]">
              <HeroCarousel slides={heroSlides} />
            </div>
          </div>
        </Reveal>

        <Reveal delayMs={200} className="mt-14 w-full max-w-3xl">
          <AgentMarquee agents={supportedAgents} />
        </Reveal>
        <Reveal delayMs={240}>
          <div className="mt-10 flex flex-col items-center justify-center gap-3">
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
            {/* Below 14 the app will not launch, and macOS reports only a generic
                Finder error — so the floor is stated where the download happens. */}
            <p className="text-sm text-muted-foreground">
              Requires macOS 14 or later
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
