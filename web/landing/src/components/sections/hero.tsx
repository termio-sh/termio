import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { HeroTabs } from "@/components/hero-tabs";
import { AppleMark, GitHubMark } from "@/components/section-label";
import { downloadUrl, githubUrl, heroSlides } from "@/lib/site";

// A flat hero (Antimetal / Dovetail): the download sits directly under the
// headline so it is above the fold, and one tabbed window shows the app on the
// page's single colour moment — the aurora stage behind it.
export function Hero() {
  return (
    <section
      id="top"
      className="relative isolate overflow-hidden text-foreground"
    >
      <div className="mx-auto flex w-full max-w-6xl flex-col items-center px-5 pb-8 pt-36 text-center sm:px-8 sm:pt-44">
        <Reveal>
          <h1 className="text-balance pb-2 text-5xl font-medium leading-[1.05] tracking-tight sm:text-7xl">
            Orchestrate your fleet of agents.
          </h1>
        </Reveal>
        <Reveal delayMs={60}>
          <p className="mx-auto mt-6 max-w-xl text-balance text-lg leading-relaxed text-muted-foreground">
            A native Mac terminal for Claude Code, Codex and every other agent.
          </p>
        </Reveal>
        <Reveal delayMs={120}>
          <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
            <a
              href={downloadUrl}
              className={cn(
                buttonVariants(),
                "h-11 gap-2 rounded-full px-6 text-[15px]",
              )}
            >
              <AppleMark />
              Download for Mac
            </a>
            <a
              href={githubUrl}
              target="_blank"
              rel="noreferrer"
              className={cn(
                buttonVariants({ variant: "secondary" }),
                "h-11 gap-2 rounded-full px-6 text-[15px]",
              )}
            >
              <GitHubMark />
              View on GitHub
            </a>
          </div>
          <p className="mt-4 text-sm text-muted-foreground">
            Requires macOS 14 or later
          </p>
        </Reveal>

        <Reveal delayMs={180} className="mt-16 w-full max-w-5xl">
          <HeroTabs slides={heroSlides} />
        </Reveal>
      </div>
    </section>
  );
}
