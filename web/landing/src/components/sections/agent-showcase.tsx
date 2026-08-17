"use client";

import Image from "next/image";
import { useCallback, useEffect, useRef, useState } from "react";
import useEmblaCarousel, {
  type UseEmblaCarouselType,
} from "embla-carousel-react";
import Autoplay from "embla-carousel-autoplay";
import { WheelGesturesPlugin } from "embla-carousel-wheel-gestures";
import { Reveal } from "@/components/reveal";
import { AgentIcon } from "@/components/agent-icons";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";

// The carousel API, named off the hook so the core package stays a transitive
// dependency of `embla-carousel-react` rather than a second entry to keep in
// step with it.
type EmblaApi = NonNullable<UseEmblaCarouselType[1]>;

const AUTOPLAY_MS = 2600;
// How far from the focused row a name has faded out completely.
const FALLOFF_ROWS = 2.2;
const MAX_BLUR_PX = 4.5;
// Blur stays gentler on the screenshots: it costs far more on a 500px image
// than on a line of text, and the perspective already carries the depth.
const FRAME_BLUR_PX = 2.5;

// Both columns ride the same kind of cylinder: a step in the list is a step in
// degrees, and a slot's position, tilt and depth all fall out of that one
// angle. Straight `translateY` reads as a conveyor belt, not a drum — what
// sells the rotation is that the slots crowd together and turn away as they
// approach the rim.
//
// Degrees per step, and the arc each step covers as a multiple of the slot's
// own height. The names sit shoulder to shoulder (1), so their neighbours peek
// in like an iOS picker. The screenshots get a gap between them (1.35), so only
// one is ever in the window at rest.
const NAME_STEP_DEG = 22;
const NAME_PITCH = 1;
const NAME_PERSPECTIVE_PX = 900;
const FRAME_STEP_DEG = 30;
const FRAME_PITCH = 1.35;
const FRAME_PERSPECTIVE_PX = 1800;

// A slot `offset` steps from the front of a cylinder built from that slot's own
// height. The two `translateZ`s put the axis of rotation behind the surface and
// bring the front of the cylinder back to the screen plane, so the slot in
// focus is unrotated, undisplaced and pixel-sharp.
function cylinderTransform(
  offset: number,
  slotHeight: number,
  stepDeg: number,
  pitch: number,
  perspective: number,
) {
  const radius =
    (pitch * slotHeight) / (2 * Math.tan((stepDeg * Math.PI) / 360));
  return `perspective(${perspective}px) translateZ(${-radius.toFixed(
    1,
  )}px) rotateX(${(-offset * stepDeg).toFixed(2)}deg) translateZ(${radius.toFixed(
    1,
  )}px)`;
}

// One entry per agent capture in public/agent/ (all 1280×1236 @2x).
const agents = [
  {
    name: "Claude Code",
    blurb:
      "Anthropic's agentic coding CLI. Session status flows into the sidebar as it works.",
    src: "/agent/claude.png",
  },
  {
    name: "Codex",
    blurb: "OpenAI's coding agent, with your plan usage tracked in Settings.",
    src: "/agent/codex.png",
  },
  {
    name: "OpenCode",
    blurb: "The open-source terminal agent — full TUI, rendered natively.",
    src: "/agent/opencode.png",
  },
  {
    name: "Amp",
    blurb: "Sourcegraph's agent for big, multi-file changes.",
    src: "/agent/amp.png",
  },
  {
    name: "Kimi",
    blurb: "Moonshot AI's Kimi CLI, launched in one tap.",
    src: "/agent/kimi.png",
  },
  {
    name: "Pi",
    blurb: "Pi Agent — tracked in the sidebar like everything else.",
    src: "/agent/pi.png",
  },
] as const;

// Agent showcase: the sentence sits on its own line, and under it a drum of
// agent names rolls on where the sentence left off — the focused name sharp,
// its neighbours falling out of focus above and below it — with the screenshot
// beside it panning in step. Wheel, drag or click the drum to turn it.
//
// The roll itself is Embla (`axis: "y"`, looped), used headless: it owns the
// scroll physics, autoplay, drag and looping, we own every pixel. Embla's
// continuous `scroll` event is what lets the focus falloff track a finger
// mid-drag instead of stepping one row at a time.
export function AgentShowcase() {
  const [active, setActive] = useState(0);
  const [paused, setPaused] = useState(false);
  const [rolling, setRolling] = useState(false);
  const reducedMotion = useRef(false);
  // The screenshot for each agent, positioned frame by frame from the same
  // measurement that drives the names.
  const frames = useRef<(HTMLImageElement | null)[]>([]);
  const { ref: viewRef, inView } = useInView<HTMLDivElement>();

  const [emblaRef, emblaApi] = useEmblaCarousel(
    {
      axis: "y",
      loop: true,
      align: "center",
      containScroll: false,
      duration: 30,
      // Mouse drag spins the drum; touch drag is refused so a thumb swiping
      // down the page is never trapped by the drum on the way past.
      watchDrag: (_, event) =>
        !("pointerType" in event) || event.pointerType !== "touch",
    },
    [
      Autoplay({
        delay: AUTOPLAY_MS,
        playOnInit: false,
        stopOnInteraction: false,
        stopOnMouseEnter: false,
      }),
      // A wheel over the drum turns the drum instead of the page. It only
      // claims wheel events inside the drum's own five lines, so the rest of
      // the section scrolls normally.
      WheelGesturesPlugin({ forceWheelAxis: "y" }),
    ],
  );

  useEffect(() => {
    reducedMotion.current = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
  }, []);

  // One measurement, both columns: how far each row sits from the drum's
  // centre, in rows. Positive means below it. That distance blurs the name and
  // pans its screenshot by the same amount, so the whole section reads as a
  // single camera moving down a wall of agents rather than two widgets that
  // happen to change together.
  //
  // It is measured off the DOM rather than off Embla's internals, which is what
  // keeps the looped copies (repositioned by Embla itself) honest — so the
  // styles go on the row's child, never on the slide Embla is transforming.
  const applyFalloff = useCallback((api: EmblaApi) => {
    const viewport = api.rootNode().getBoundingClientRect();
    const slides = api.slideNodes();
    // A row's own height, not a hard-coded row count: the drum shows fewer
    // rows on a phone than on a desktop.
    const rowHeight = slides[0]?.getBoundingClientRect().height ?? 0;
    if (!rowHeight) return;
    const centre = viewport.top + viewport.height / 2;
    const reduced = reducedMotion.current;

    slides.forEach((slide, i) => {
      const rect = slide.getBoundingClientRect();
      const offset = (rect.top + rect.height / 2 - centre) / rowHeight;
      const distance = Math.abs(offset);

      const row = slide.firstElementChild;
      if (row instanceof HTMLElement) {
        const focus = Math.max(0, 1 - distance / FALLOFF_ROWS);
        row.style.opacity = (focus * focus).toFixed(3);
        row.style.pointerEvents = focus > 0.35 ? "auto" : "none";
        row.style.filter = reduced
          ? "none"
          : `blur(${((1 - focus) * MAX_BLUR_PX).toFixed(2)}px)`;
        // Embla has already moved the slide a whole row; the cylinder is the
        // difference between that and where the row would sit on a drum.
        row.style.transform = reduced
          ? "none"
          : `translateY(${(-offset * 100).toFixed(2)}%) ${cylinderTransform(
              offset,
              rowHeight,
              NAME_STEP_DEG,
              NAME_PITCH,
              NAME_PERSPECTIVE_PX,
            )}`;
      }

      const frame = frames.current[i];
      if (!frame) return;
      if (reduced) {
        frame.style.opacity = distance < 0.5 ? "1" : "0";
        frame.style.transform = "none";
        frame.style.filter = "none";
        return;
      }
      // Frames sit on the same drum, a gap apart, so only the one entering and
      // the one leaving are ever in the window at once — they turn past each
      // other instead of ghosting through each other. A frame a full step away
      // has left the window, so it is dropped rather than composited and
      // blurred where nobody can see it.
      const inShot = distance < 1.02;
      const sharpness = Math.max(0, 1 - distance);
      frame.style.opacity = inShot ? "1" : "0";
      frame.style.transform = cylinderTransform(
        offset,
        frame.clientHeight,
        FRAME_STEP_DEG,
        FRAME_PITCH,
        FRAME_PERSPECTIVE_PX,
      );
      frame.style.filter = inShot
        ? `blur(${((1 - sharpness) * FRAME_BLUR_PX).toFixed(2)}px)`
        : "none";
    });
  }, []);

  useEffect(() => {
    if (!emblaApi) return;

    const onScroll = () => applyFalloff(emblaApi);
    const onSelect = () => setActive(emblaApi.selectedScrollSnap());

    emblaApi
      .on("scroll", onScroll)
      .on("resize", onScroll)
      .on("reInit", onScroll)
      .on("select", onSelect)
      .on("pointerDown", () => setPaused(true))
      .on("pointerUp", () => setPaused(false));

    applyFalloff(emblaApi);
    setRolling(true);

    return () => {
      emblaApi
        .off("scroll", onScroll)
        .off("resize", onScroll)
        .off("reInit", onScroll)
        .off("select", onSelect);
    };
  }, [emblaApi, applyFalloff]);

  // Autoplay only while the section is on screen, unpaused, and motion is
  // welcome.
  useEffect(() => {
    const autoplay = emblaApi?.plugins().autoplay;
    if (!autoplay) return;
    if (inView && !paused && !reducedMotion.current) autoplay.play();
    else autoplay.stop();
  }, [emblaApi, inView, paused]);

  const goTo = useCallback(
    (index: number) => {
      emblaApi?.scrollTo(index);
      emblaApi?.plugins().autoplay?.reset();
    },
    [emblaApi],
  );

  return (
    <section id="agents" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-6xl px-5 pb-32 sm:pb-40 sm:px-8">
        <Reveal as="article" className="rounded-3xl bg-card p-6 sm:p-10 lg:p-14">
          <div
            ref={viewRef}
            onMouseEnter={() => setPaused(true)}
            onMouseLeave={() => setPaused(false)}
            onFocus={() => setPaused(true)}
            onBlur={() => setPaused(false)}
            onKeyDown={(e) => {
              if (e.key === "ArrowUp") emblaApi?.scrollPrev();
              if (e.key === "ArrowDown") emblaApi?.scrollNext();
            }}
            className="flex flex-col gap-10 lg:gap-12"
          >
            {/* The sentence owns its own full-width line; the drum and the
                screenshot sit under it, side by side. */}
            <h2 className="text-pretty text-3xl font-medium leading-snug tracking-tight text-foreground sm:text-4xl">
              We build Terminal-first Agentic Development Environment for
            </h2>

            <div className="grid gap-10 lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)] lg:items-stretch lg:gap-14">
              {/* Left: the drum of agent names, then the line about the one in
                  focus. */}
              <div className="flex min-w-0 flex-col">
                {/* Three rows on a phone, five from `sm` up, so the names
                    either side of the focused one bleed out of focus without
                    opening a hole above it on a narrow screen. */}
                <div
                  ref={emblaRef}
                  className={cn(
                    "h-[calc(3*1lh)] cursor-grab overflow-hidden text-3xl font-medium leading-snug tracking-tight text-foreground transition-opacity duration-500 active:cursor-grabbing sm:h-[calc(5*1lh)] sm:text-4xl",
                    "[mask-image:linear-gradient(to_bottom,transparent,black_20%,black_80%,transparent)]",
                    rolling ? "opacity-100" : "opacity-0",
                  )}
                >
                  <div
                    role="tablist"
                    aria-label="Supported agents"
                    aria-orientation="vertical"
                    className="flex h-full flex-col"
                  >
                    {agents.map((agent, i) => (
                      <div
                        key={agent.name}
                        className="min-h-0 shrink-0 grow-0 basis-1/3 sm:basis-1/5"
                      >
                        <button
                          type="button"
                          role="tab"
                          aria-selected={i === active}
                          aria-label={`Show ${agent.name}`}
                          tabIndex={i === active ? 0 : -1}
                          onClick={() => goTo(i)}
                          className="flex h-full w-full origin-left items-center whitespace-nowrap text-left will-change-[opacity,filter,transform]"
                        >
                          {agent.name}.
                        </button>
                      </div>
                    ))}
                  </div>
                </div>

                {/* Per-agent line, cross-faded in place at the foot of the
                    column. Stacking every blurb in one grid cell keeps the
                    block as tall as the longest one, so the drum above it never
                    shifts. */}
                <div className="mt-8 grid max-w-md lg:mt-auto">
                  {agents.map((agent, i) => (
                    <p
                      key={agent.name}
                      aria-hidden={i !== active}
                      className={cn(
                        "col-start-1 row-start-1 flex gap-2.5 text-pretty text-sm leading-relaxed text-muted-foreground transition-opacity sm:text-base",
                        // The outgoing line clears out before the incoming one
                        // arrives — two blurbs at half opacity are unreadable.
                        i === active
                          ? "opacity-100 delay-150 duration-300"
                          : "opacity-0 duration-150",
                      )}
                    >
                      <AgentIcon
                        name={agent.name}
                        size={18}
                        className="mt-0.5 shrink-0 text-foreground"
                      />
                      <span>{agent.blurb}</span>
                    </p>
                  ))}
                </div>
              </div>

              {/* Right: the filmstrip. Every capture is mounted and stacked in
                  the same window; `applyFalloff` puts each one a full frame
                  from the last, so the strip runs past the window as the drum
                  turns. The @container wrapper lets the corner radius scale
                  with the rendered image width (cqw), like the hero carousel. */}
              <div className="@container">
                <div
                  role="region"
                  aria-roledescription="carousel"
                  aria-label="Agent screenshots"
                  className={cn(
                    "relative overflow-hidden rounded-[clamp(6px,1cqw,12px)] transition-opacity duration-500",
                    rolling ? "opacity-100" : "opacity-0",
                  )}
                  style={{ aspectRatio: "1280 / 1236" }}
                >
                  {agents.map((agent, i) => (
                    <Image
                      key={agent.src}
                      ref={(node) => {
                        frames.current[i] = node;
                      }}
                      src={agent.src}
                      width={1280}
                      height={1236}
                      alt={`${agent.name} running in Termio`}
                      loading="lazy"
                      // The captures are 1280px wide but render in the ~32rem
                      // right column of the card; without `sizes` the browser
                      // downloads the 3840px rendition.
                      sizes="(min-width: 64rem) 32rem, calc(100vw - 5.5rem)"
                      draggable={false}
                      aria-hidden={i !== active}
                      className="pointer-events-none absolute inset-0 h-full w-full object-cover will-change-[opacity,filter,transform] motion-reduce:transition-opacity motion-reduce:duration-300"
                    />
                  ))}
                </div>
              </div>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
