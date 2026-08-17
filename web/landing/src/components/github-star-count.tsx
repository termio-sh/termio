"use client";

import { useEffect, useState } from "react";
import { formatStarCount } from "@/lib/site";

function StarMark({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 16 16"
      fill="currentColor"
      aria-hidden="true"
      className={className}
    >
      <path d="M8 .25a.75.75 0 0 1 .673.418l1.882 3.815 4.21.612a.75.75 0 0 1 .416 1.279l-3.046 2.97.719 4.192a.75.75 0 0 1-1.088.791L8 12.347l-3.766 1.98a.75.75 0 0 1-1.088-.79l.72-4.194L.818 6.374a.75.75 0 0 1 .416-1.28l4.21-.611L7.327.668A.75.75 0 0 1 8 .25Z" />
    </svg>
  );
}

// The count arrives twice: server-rendered with the page (may be up to an hour
// stale) and then refreshed on mount from /api/github-stars, whose server-side
// cache keeps it within 30 minutes of live. A failed refresh keeps the
// server-rendered number.
export function GitHubStarCount({
  initialStars,
}: {
  initialStars: number | null;
}) {
  const [stars, setStars] = useState(initialStars);

  useEffect(() => {
    let cancelled = false;
    fetch("/api/github-stars")
      .then((response) => (response.ok ? response.json() : null))
      .then((data: { stars?: number | null } | null) => {
        if (!cancelled && typeof data?.stars === "number") {
          setStars(data.stars);
        }
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  if (stars === null) return null;
  return (
    <span className="ml-1 inline-flex items-center gap-1 border-l border-primary-foreground/20 pl-3 text-primary-foreground/70">
      <StarMark className="h-3.5 w-3.5 text-brand-gold" />
      {formatStarCount(stars)}
    </span>
  );
}
