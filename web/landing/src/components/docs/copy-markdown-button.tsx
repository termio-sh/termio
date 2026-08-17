"use client";

import { useState } from "react";
import { cn } from "@/lib/utils";

// "Copy for LLM" — copies the page's raw Markdown to the clipboard, so you can
// paste it into an agent for context. Borrowed from Warp's docs, and especially
// fitting here: Termio's readers are running coding agents all day.
export function CopyMarkdownButton({
  markdown,
  labels,
}: {
  markdown: string;
  labels: { copy: string; copied: string; aria: string };
}) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(markdown);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard blocked (e.g. insecure context) — nothing useful to do.
    }
  }

  return (
    <button
      type="button"
      onClick={copy}
      aria-label={labels.aria}
      // Ghost button, Base UI style: no resting border, the surface arrives on
      // hover. Two of these sit beside a page title and shouldn't read as a
      // toolbar bolted to the heading.
      className={cn(
        "inline-flex h-7 shrink-0 items-center gap-1.5 rounded-lg px-2 text-[12px] font-medium transition-colors hover:bg-fd-accent hover:text-fd-accent-foreground",
        copied ? "text-brand-green" : "text-fd-muted-foreground",
      )}
    >
      {copied ? (
        <CheckIcon className="h-3.5 w-3.5" />
      ) : (
        <CopyIcon className="h-3.5 w-3.5" />
      )}
      {copied ? labels.copied : labels.copy}
    </button>
  );
}

function CopyIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <rect x="9" y="9" width="13" height="13" rx="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}
function CheckIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="M20 6 9 17l-5-5" />
    </svg>
  );
}
