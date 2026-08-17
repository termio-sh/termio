import { Caveat } from "next/font/google";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { GitHubMark } from "@/components/section-label";
import { GitHubStarCount } from "@/components/github-star-count";
import { githubApiUrl, githubUrl } from "@/lib/site";

// Handwritten face for the heading only — a personal ask deserves a personal
// hand. Self-hosted by next/font at build time, so no runtime font request.
const caveat = Caveat({ subsets: ["latin"], weight: "600" });

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
  } catch {
    return null;
  }
}

export async function GitHubBand() {
  const starCount = await fetchStarCount();
  return (
    <section id="github" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-2xl px-5 pb-32 pt-8 sm:px-8 sm:pb-40 sm:pt-10">
        <Reveal className="flex flex-col items-center text-center">
          <h2
            className={cn(
              caveat.className,
              "text-balance text-4xl leading-[1.1] text-foreground sm:text-[56px]",
            )}
          >
            Star us on GitHub
          </h2>
          <p className="mt-5 text-base leading-relaxed text-foreground">
            <span className="block">
              Termio is free and open source, MIT licensed.
            </span>
            <span className="block">A star helps other builders find it.</span>
          </p>
          <a
            href={githubUrl}
            target="_blank"
            rel="noreferrer"
            className={cn(
              buttonVariants(),
              "mt-9 h-12 gap-2 rounded-full px-7 text-base",
              "shadow-[0_12px_32px_rgba(20,23,28,0.18),0_0_0_1px_rgba(0,211,199,0.14)]",
            )}
          >
            <GitHubMark />
            GitHub
            <GitHubStarCount initialStars={starCount} />
          </a>
        </Reveal>
      </div>
    </section>
  );
}
