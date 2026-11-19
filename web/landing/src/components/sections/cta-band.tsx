import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { AppleMark, GitHubMark, Section } from "@/components/section-label";
import { GitHubStarCount } from "@/components/github-star-count";
import { HeroGradient } from "@/components/hero-gradient";
import { downloadUrl, githubApiUrl, githubUrl } from "@/lib/site";

// Server-rendered star count so the number is in the initial HTML with no
// pop-in; GitHubStarCount then refreshes it client-side from /api/github-stars.
// Rendering must never depend on the GitHub API being up: any failure just
// drops the count and keeps the button.
async function fetchStarCount(): Promise<number | null> {
  try {
    const response = await fetch(githubApiUrl, {
      next: { revalidate: 3600 },
    });
    if (!response.ok) return null;
    const repo = (await response.json()) as { stargazers_count?: number };
    return typeof repo.stargazers_count === "number"
      ? repo.stargazers_count
      : null;
  } catch (error) {
    console.warn("Could not read the GitHub star count", error);
    return null;
  }
}

// The page's one closing block: download, or star the repo. It sits on the same
// live aurora as the hero window, so the page opens and closes on one picture;
// `dark` keeps its ink light in either appearance, and the background colour
// under the shader keeps it legible where WebGL is unavailable.
export async function CtaBand() {
  const starCount = await fetchStarCount();
  return (
    <Section aria-labelledby="cta-heading">
      <Reveal>
        <div className="dark relative isolate overflow-hidden rounded-[2rem] bg-[#070710] px-8 py-24 sm:px-14 sm:py-32">
          <HeroGradient className="absolute inset-0 -z-10" />
          <div
            aria-hidden="true"
            className="grain-overlay pointer-events-none absolute -inset-[6%] -z-10"
          />
          <div className="flex flex-col items-center text-center">
            <h2
              id="cta-heading"
              className="text-balance text-4xl font-medium leading-[1.05] tracking-tight text-white sm:text-6xl"
            >
              Stop babysitting terminals.
            </h2>
            <div className="mt-9 flex flex-wrap justify-center gap-3">
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
                  "h-11 gap-2 rounded-full bg-white/10 px-6 text-[15px] text-white backdrop-blur-md hover:bg-white/15",
                )}
              >
                <GitHubMark />
                Star on GitHub
                <GitHubStarCount initialStars={starCount} />
              </a>
            </div>
            <p className="mt-4 text-sm text-white/60">
              Requires macOS 14 or later
            </p>
          </div>
        </div>
      </Reveal>
    </Section>
  );
}
