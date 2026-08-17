import Image from "next/image";
import { Reveal } from "@/components/reveal";
import { SectionLabel } from "@/components/section-label";

// One entry per capture in public/feature/ (native dimensions vary, so each
// card carries its own intrinsic size and the row stretches to the taller one).
const features = [
  {
    title: "Knows when an agent needs you",
    blurb:
      "Session dots show working, idle, or needs-you, aggregated into a menu-bar tray — calm while agents work, ringing the moment one is blocked on you.",
    src: "/feature/tray.png",
    alt: "The Termio menu-bar tray listing sessions grouped by project",
    width: 870,
    height: 700,
  },
  {
    title: "Command palette",
    blurb:
      "Jump to any session, project, or action from one search box — themes too, previewed live as you browse, Enter to keep or Esc to revert.",
    src: "/feature/pallette.png",
    alt: "The Termio command palette over a terminal session",
    width: 1120,
    height: 800,
  },
  {
    title: "Usage at a glance",
    blurb:
      "Your Claude and Codex plan limits in Settings, read locally from your own credentials — no proxy, no account.",
    src: "/feature/usage.png",
    alt: "Claude and Codex usage meters in Termio's settings",
    width: 1150,
    height: 918,
  },
  {
    title: "Native appearance",
    blurb:
      "Light, dark, and a glass look that follows the system, with hundreds of built-in terminal themes or your own. A real Mac app, down to the chrome.",
    src: "/feature/appearance.png",
    alt: "Termio's appearance settings with light, dark, and glass modes",
    width: 1160,
    height: 926,
  },
] as const;

export function FeatureGrid() {
  return (
    <section id="features" className="scroll-mt-24">
      {/* Light top padding — the showcase above already ends with pb-32/40. */}
      <div className="mx-auto w-full max-w-6xl px-5 pb-32 pt-8 sm:px-8 sm:pb-40 sm:pt-10">
        <Reveal className="flex flex-col items-center text-center">
          <SectionLabel accent="muted">What&apos;s inside</SectionLabel>
          <h2 className="mt-4 text-balance text-3xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-[44px]">
            Built for watching agents work
          </h2>
          <p className="mt-5 max-w-lg text-balance text-base leading-relaxed text-muted-foreground">
            Several agents going at once, most of them fine without you, one of
            them stuck — Termio keeps the whole fleet in view.
          </p>
        </Reveal>

        <div className="mt-12 grid gap-5 sm:grid-cols-2 sm:gap-6">
          {features.map((feature, i) => (
            <Reveal
              key={feature.src}
              as="article"
              delayMs={(i % 2) * 80}
              className="flex flex-col rounded-3xl bg-card p-6 sm:p-8"
            >
              <h3 className="text-xl font-medium tracking-tight text-foreground">
                {feature.title}
              </h3>
              <p className="mt-2 max-w-md text-pretty text-sm leading-relaxed text-muted-foreground">
                {feature.blurb}
              </p>
              <div className="mt-auto pt-6">
                <Image
                  src={feature.src}
                  width={feature.width}
                  height={feature.height}
                  alt={feature.alt}
                  loading="lazy"
                  // The captures render inside a ~32rem card column; without
                  // `sizes` the browser downloads the full-width rendition.
                  sizes="(min-width: 40rem) 32rem, calc(100vw - 5.5rem)"
                  draggable={false}
                  className="w-full rounded-xl"
                />
              </div>
            </Reveal>
          ))}
        </div>

        <Reveal delayMs={80}>
          <p className="mx-auto mt-10 max-w-3xl text-balance text-center text-sm leading-relaxed text-muted-foreground">
            Also in the box: git worktrees nested under each project, a
            read-only git pane with unified diffs, a click-to-edit file editor,
            and Ghostty-style split panes.
          </p>
        </Reveal>
      </div>
    </section>
  );
}
