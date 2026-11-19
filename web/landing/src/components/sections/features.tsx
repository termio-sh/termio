import { FeatureVideo } from "@/components/feature-video";
import { Reveal } from "@/components/reveal";
import { Section, Stage } from "@/components/section-label";
import { cn } from "@/lib/utils";
import { testflightUrl } from "@/lib/site";

// Five panels after Cursor's feature sections: the text and the picture share
// one card, so the words sit against the thing they describe instead of
// floating in the page. The text is anchored to the panel's bottom corner and
// the sides swap panel by panel. Every picture is a silent, level loop rendered
// from a real capture (termio-sh/launch-video, 20261024-landing-* and
// 20261025-ios-simulator/site); each carries its own aurora, so it fills the
// stage edge to edge.
const rows = [
  {
    title: "See which agent needs you.",
    blurb: "Every session shows working, done or waiting on you.",
    video: "session-status",
    label:
      "Termio's sidebar: one agent turns orange because it needs you, two turn green as they finish",
  },
  {
    title: "Quit Termio. Agents keep going.",
    blurb:
      "Sessions live in the background, so reopening brings back the same screen.",
    video: "survive-quit",
    label:
      "Termio quits with Command-Q and reopens on the same session, where the agent has read further",
  },
  {
    title: "Agents test your iOS app in a pane.",
    blurb: (
      <>
        They launch and tap it with{" "}
        <code className="whitespace-nowrap font-mono text-[0.9em]">
          termio sim
        </code>
        , and you can type into the same simulator.
      </>
    ),
    video: "ios-simulator",
    label:
      "Claude Code launches TermioMobile in the Simulator pane with termio sim, taps through to an address field, and the person types an address into it",
  },
  {
    title: "Every agent, one switch.",
    blurb: "Turn one on and Termio installs its hooks on every machine.",
    video: "agents",
    label:
      "Agent settings: the switches for OpenCode, Amp, Droid, Copilot, Kimi and Qwen Code turn on one by one",
  },
  {
    title: "Your sessions, on your phone.",
    blurb: "Check progress and answer prompts from your iPhone.",
    video: "phone",
    label:
      "The iPhone app: open a project, see Claude Code's live terminal, tap the prompt and type",
    link: { label: "Get the iOS beta", href: testflightUrl },
  },
] as const;

export function Features() {
  return (
    <Section id="features">
      <div className="flex flex-col gap-6">
        {rows.map((row, i) => {
          const flipped = i % 2 === 1;
          return (
            <Reveal
              key={row.title}
              className={cn(
                "grid overflow-hidden rounded-2xl border border-border bg-card",
                flipped
                  ? "lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]"
                  : "lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]",
              )}
            >
              <div
                className={cn(
                  "flex flex-col justify-end p-8 sm:p-10",
                  flipped && "lg:order-last",
                )}
              >
                <p className="max-w-sm text-pretty text-xl font-medium leading-snug tracking-tight sm:text-2xl">
                  <span className="text-foreground">{row.title}</span>{" "}
                  <span className="text-muted-foreground">{row.blurb}</span>
                </p>
                {"link" in row ? (
                  <a
                    href={row.link.href}
                    className="mt-5 inline-block text-sm font-medium text-foreground underline-offset-4 hover:underline"
                  >
                    {row.link.label} →
                  </a>
                ) : null}
              </div>
              <Stage className="aspect-video rounded-none">
                <FeatureVideo name={row.video} label={row.label} />
              </Stage>
            </Reveal>
          );
        })}
      </div>
    </Section>
  );
}
