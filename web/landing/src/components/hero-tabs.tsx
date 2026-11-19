"use client";

import Image from "next/image";
import { useState } from "react";
import { cn } from "@/lib/utils";
import { HeroGradient } from "@/components/hero-gradient";

export type HeroSlide = {
  src: string;
  alt: string;
  width: number;
  height: number;
  /** Tab title in the hero's tabbed window. */
  label: string;
};

// One flat window with a tab per screenshot (Sketch's hero shape). The viewer
// picks what to look at, so nothing autoplays and nothing moves on its own.
export function HeroTabs({ slides }: { slides: readonly HeroSlide[] }) {
  const [active, setActive] = useState(0);
  const [visited, setVisited] = useState<ReadonlySet<number>>(
    () => new Set([0]),
  );

  if (slides.length === 0) return null;
  const { width, height } = slides[0];

  const select = (index: number) => {
    setActive(index);
    setVisited((prev) => (prev.has(index) ? prev : new Set(prev).add(index)));
  };

  return (
    <div className="@container w-full">
      <div
        role="tablist"
        aria-label="Termio screenshots"
        className="mx-auto mb-5 flex w-fit max-w-full gap-1 overflow-x-auto rounded-full bg-foreground/[0.06] p-1"
      >
        {slides.map((slide, i) => (
          <button
            key={slide.src}
            type="button"
            role="tab"
            aria-selected={i === active}
            onClick={() => select(i)}
            onMouseEnter={() =>
              setVisited((prev) => (prev.has(i) ? prev : new Set(prev).add(i)))
            }
            className={cn(
              "shrink-0 rounded-full px-3 py-1.5 text-sm font-medium sm:px-4",
              i === active
                ? "bg-foreground text-background"
                : "text-muted-foreground hover:text-foreground",
            )}
          >
            {slide.label}
          </button>
        ))}
      </div>
      {/* The stage: the aurora behind the window, the page's one use of colour
          (Cursor puts its screenshots on painted panels the same way). The
          window sits inset on it with a real cast shadow. */}
      <div className="relative isolate overflow-hidden rounded-[clamp(12px,2cqw,24px)] bg-[#070710] p-[clamp(12px,4.5cqw,56px)]">
        <HeroGradient className="absolute inset-0 -z-10" />
        <div
          aria-hidden="true"
          className="grain-overlay pointer-events-none absolute -inset-[6%] -z-10"
        />
        <div
          role="tabpanel"
          className="relative w-full overflow-hidden rounded-[clamp(6px,1cqw,12px)] shadow-[0_30px_80px_-30px_rgba(0,0,0,0.75)] ring-1 ring-white/10"
          style={{ aspectRatio: `${width} / ${height}` }}
        >
          {slides.map((slide, i) =>
            visited.has(i) ? (
              <Image
                key={slide.src}
                src={slide.src}
                width={slide.width}
                height={slide.height}
                alt={slide.alt}
                priority={i === 0}
                sizes="(max-width: 68rem) 100vw, 64rem"
                draggable={false}
                aria-hidden={i !== active}
                className={cn(
                  "absolute inset-0 h-full w-full object-cover transition-opacity duration-200",
                  i === active
                    ? "opacity-100"
                    : "pointer-events-none opacity-0",
                )}
              />
            ) : null,
          )}
        </div>
      </div>
    </div>
  );
}
