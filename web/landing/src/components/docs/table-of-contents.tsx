"use client";

import { useEffect, useState } from "react";
import type { TOCItemType } from "fumadocs-core/toc";
import { cn } from "@/lib/utils";

// A per-page "On this page" rail with scroll-spy. fumadocs generates the `toc`
// (title/url/depth) from the MDX headings, which carry matching ids; we track
// which heading is in view with an IntersectionObserver and highlight it.
export function TableOfContents({ items }: { items: TOCItemType[] }) {
  const [activeId, setActiveId] = useState<string>("");

  useEffect(() => {
    const ids = items
      .map((item) => item.url.replace(/^#/, ""))
      .filter(Boolean);
    const headings = ids
      .map((id) => document.getElementById(id))
      .filter((el): el is HTMLElement => el !== null);
    if (headings.length === 0) return;

    const observer = new IntersectionObserver(
      (entries) => {
        // Prefer the topmost heading currently intersecting the upper band.
        const visible = entries
          .filter((e) => e.isIntersecting)
          .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
        if (visible[0]) setActiveId(visible[0].target.id);
      },
      // A band near the top of the viewport, so the active item flips as a
      // heading crosses roughly a quarter down the screen.
      { rootMargin: "-96px 0px -66% 0px", threshold: [0, 1] },
    );
    headings.forEach((el) => observer.observe(el));
    return () => observer.disconnect();
  }, [items]);

  if (items.length === 0) return null;

  return (
    <nav aria-label="On this page" className="text-[13px]">
      <p className="mb-3 px-3 text-[11px] font-semibold uppercase tracking-[0.08em] text-muted-foreground/70">
        On this page
      </p>
      <ul className="space-y-0.5 border-l border-border">
        {items.map((item) => {
          const id = item.url.replace(/^#/, "");
          const active = id === activeId;
          return (
            <li key={item.url}>
              <a
                href={item.url}
                className={cn(
                  "-ml-px block border-l py-1 leading-snug transition-colors",
                  item.depth >= 3 ? "pl-6" : "pl-3",
                  active
                    ? "border-brand-teal font-medium text-foreground"
                    : "border-transparent text-muted-foreground hover:text-foreground",
                )}
              >
                {item.title}
              </a>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
