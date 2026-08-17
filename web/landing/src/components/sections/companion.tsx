"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import { cn } from "@/lib/utils";
import { Reveal } from "@/components/reveal";
import { useInView } from "@/lib/use-in-view";

const CYCLE_MS = 3200;

const points = [
  {
    title: "Same session",
    blurb:
      "The phone attaches to the Mac's terminal — output, prompts, and status stay in sync.",
  },
  {
    title: "Works away",
    blurb:
      "Direct over LAN at home, an outbound tunnel when away. No port forwarding.",
  },
  {
    title: "Paired, not hosted",
    blurb:
      "Pair every Mac you work on with a QR code and switch between them. Token-gated, no Termio cloud in the middle.",
  },
] as const;

const phones = [
  {
    src: "/screenshots/phone-mirror.webp",
    alt: "A live Claude Code session mirrored on the iPhone",
  },
  {
    src: "/screenshots/phone-keys.webp",
    alt: "The key bar with esc, tab, ctrl, and arrows above the iPhone keyboard",
  },
  {
    src: "/screenshots/phone-projects.webp",
    alt: "The Projects list on the iPhone",
  },
  {
    src: "/screenshots/phone-pi.webp",
    alt: "A Pi session with the terminal key bar on the iPhone",
  },
] as const;

export function Companion() {
  const [active, setActive] = useState(0);
  const [paused, setPaused] = useState(false);
  const { ref: viewRef, inView } = useInView<HTMLDivElement>();

  // One phone at a time: advance on a timer while the section is on screen and
  // unhovered. The stack cross-fades in place, so the device never moves.
  useEffect(() => {
    if (!inView || paused) return;
    const timer = window.setInterval(
      () => setActive((current) => (current + 1) % phones.length),
      CYCLE_MS,
    );
    return () => window.clearInterval(timer);
  }, [inView, paused]);

  return (
    <section id="iphone" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-6xl px-5 pb-32 pt-8 sm:px-8 sm:pb-40 sm:pt-10">
        <article className="rounded-3xl bg-card p-6 sm:p-10 lg:p-14">
          <div
            ref={viewRef}
            className="grid items-start gap-12 lg:grid-cols-[minmax(0,6fr)_minmax(0,5fr)] lg:gap-16"
          >
          <Reveal className="flex flex-col items-start text-left">
            <h2 className="text-pretty text-3xl font-medium leading-snug tracking-tight text-foreground sm:text-4xl">
              Your sessions, from anywhere
            </h2>
            <p className="mt-5 max-w-lg text-pretty text-base leading-relaxed text-muted-foreground">
              Start an agent on your Mac, then keep the same live terminal in
              reach from your iPhone — check progress, answer prompts, approve
              a blocked run.
            </p>

            <dl className="mt-8 flex flex-col gap-5">
              {points.map((point) => (
                <div key={point.title}>
                  <dt className="text-base font-medium text-foreground">
                    {point.title}
                  </dt>
                  <dd className="mt-1 max-w-md text-pretty text-sm leading-relaxed text-muted-foreground">
                    {point.blurb}
                  </dd>
                </div>
              ))}
            </dl>
          </Reveal>

          <Reveal delayMs={120}>
            <div
              onMouseEnter={() => setPaused(true)}
              onMouseLeave={() => setPaused(false)}
              className="shadow-soft relative mx-auto w-full max-w-[290px] overflow-hidden rounded-[2.2rem] border-[6px] border-[#1a1a1c] bg-[#1a1a1c]"
              style={{ aspectRatio: "662 / 1440" }}
            >
              {phones.map((phone, index) => (
                <Image
                  key={phone.src}
                  src={phone.src}
                  width={662}
                  height={1440}
                  alt={phone.alt}
                  loading="lazy"
                  sizes="290px"
                  draggable={false}
                  aria-hidden={index !== active}
                  className={cn(
                    "absolute inset-0 h-full w-full rounded-[1.85rem] object-cover transition-opacity duration-700",
                    index === active ? "opacity-100" : "opacity-0",
                  )}
                />
              ))}
            </div>
          </Reveal>
          </div>
        </article>
      </div>
    </section>
  );
}
