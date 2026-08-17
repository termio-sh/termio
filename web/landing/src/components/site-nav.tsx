import Link from "next/link";
import { cn } from "@/lib/utils";
import { Logo } from "@/components/logo";
import { AppleMark, GitHubMark } from "@/components/section-label";
import { navLinks, downloadUrl, discordUrl, githubUrl } from "@/lib/site";

// Discord's mascot glyph, sized to sit inline with the nav links.
function DiscordMark({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      className={className}
    >
      <path d="M20.317 4.369A19.79 19.79 0 0 0 16.558 3.2a.074.074 0 0 0-.079.037c-.34.607-.719 1.4-.984 2.023a18.27 18.27 0 0 0-5.487 0 12.6 12.6 0 0 0-.997-2.023.077.077 0 0 0-.079-.037A19.74 19.74 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C1.533 7.55.94 10.65 1.219 13.71a.082.082 0 0 0 .031.056 19.9 19.9 0 0 0 5.993 3.03.077.077 0 0 0 .084-.028c.462-.63.874-1.295 1.226-1.994a.076.076 0 0 0-.041-.106 13.1 13.1 0 0 1-1.872-.892.077.077 0 0 1-.008-.128c.126-.094.252-.192.372-.291a.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.009c.12.099.246.198.373.292a.077.077 0 0 1-.006.127c-.598.35-1.22.645-1.873.892a.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028 19.84 19.84 0 0 0 6.002-3.03.077.077 0 0 0 .032-.055c.334-3.54-.559-6.61-2.365-9.314a.06.06 0 0 0-.031-.028zM8.02 11.848c-1.182 0-2.156-1.085-2.156-2.419 0-1.333.955-2.419 2.156-2.419 1.21 0 2.175 1.096 2.156 2.42 0 1.333-.955 2.418-2.156 2.418zm7.975 0c-1.182 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.175 1.096 2.156 2.42 0 1.333-.946 2.418-2.156 2.418z" />
    </svg>
  );
}

// Superwhisper's nav: a single centered floating pill holding the links + a white
// Download button, with the wordmark parked on the far left.
export function SiteNav() {
  return (
    <header className="fixed inset-x-0 top-0 z-50 pt-4">
      <div className="relative mx-auto flex w-full max-w-6xl items-center justify-center px-5 sm:px-8">
        <Link
          href="/"
          className="group absolute left-5 hidden rounded-md focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring sm:left-8 sm:block"
          aria-label="Termio home"
        >
          <Logo size="lg" />
        </Link>

        <nav
          aria-label="Primary"
          className="liquid-glass flex items-center gap-1 rounded-full p-1.5"
        >
          {/* Phone widths tighten the link padding and drop the Discord label
              (icon stays) so the pill fits a 390pt viewport; sm restores the
              full treatment. */}
          {navLinks.map((link) => (
            <a
              key={link.href}
              href={link.href}
              className="rounded-full px-3 py-1.5 text-sm font-medium text-foreground transition-all duration-200 ease-[var(--ease-apple)] hover:bg-foreground/[0.08] hover:shadow-[inset_0_0_0_1px_rgba(255,255,255,0.08)] sm:px-4"
            >
              {link.label}
            </a>
          ))}
          <a
            href={discordUrl}
            target="_blank"
            rel="noreferrer"
            aria-label="Join the Termio Discord"
            className="inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-sm font-medium text-foreground transition-all duration-200 ease-[var(--ease-apple)] hover:bg-foreground/[0.08] hover:shadow-[inset_0_0_0_1px_rgba(255,255,255,0.08)] sm:px-4"
          >
            <DiscordMark className="h-4 w-4" />
            <span className="hidden sm:inline">Discord</span>
          </a>
          <a
            href={githubUrl}
            target="_blank"
            rel="noreferrer"
            aria-label="Termio on GitHub"
            className="inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-sm font-medium text-foreground transition-all duration-200 ease-[var(--ease-apple)] hover:bg-foreground/[0.08] hover:shadow-[inset_0_0_0_1px_rgba(255,255,255,0.08)] sm:px-4"
          >
            <GitHubMark className="h-4 w-4" />
            <span className="hidden sm:inline">GitHub</span>
          </a>
          <a
            href={downloadUrl}
            className={cn(
              "ml-1 inline-flex items-center gap-1.5 rounded-full bg-primary px-3.5 py-1.5 text-sm font-semibold text-primary-foreground transition-all duration-200 ease-[var(--ease-apple)] hover:brightness-110 active:scale-[0.98] sm:px-4",
            )}
          >
            <AppleMark className="h-3.5 w-3.5" />
            Download
          </a>
        </nav>
      </div>
    </header>
  );
}
