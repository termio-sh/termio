import { cn } from "@/lib/utils";

// A pure-CSS mock of a Termio terminal running a Claude Code session — the same
// window shown in the OG image: a Mac-style title bar with traffic lights above a
// single dark terminal pane. No screenshots — everything here is JSX so it stays
// crisp at any size.
export function TermioWindow({ className }: { className?: string }) {
  return (
    <div
      className={cn(
        "shadow-soft overflow-hidden rounded-2xl border border-white/10 bg-card",
        className,
      )}
      role="img"
      aria-label="A Termio terminal running a Claude Code session that survives app restarts"
    >
      {/* Title bar */}
      <div className="flex items-center gap-2 border-b border-white/[0.08] bg-white/[0.03] px-4 py-3">
        <span className="h-3 w-3 rounded-full bg-brand-red" />
        <span className="h-3 w-3 rounded-full bg-brand-amber" />
        <span className="h-3 w-3 rounded-full bg-brand-green" />
        <span className="ml-3 font-mono text-xs text-muted-foreground">
          Claude Code — ~/termio
        </span>
      </div>

      {/* Terminal pane */}
      <div className="bg-[#0b0b0d] px-6 py-7 text-left font-mono text-sm leading-[1.9] text-zinc-400 sm:px-9 sm:py-9 sm:text-base">
        <p>
          <span className="text-brand-teal">→</span>{" "}
          <span className="text-zinc-100">claude</span>
        </p>
        <p className="flex items-center gap-2.5">
          <span className="h-2 w-2 shrink-0 rounded-full bg-brand-blue" />
          <span className="text-zinc-100">Understand Termio terminal I/O</span>
        </p>
        <p className="text-zinc-500">⌊ Read TermioStore.swift (420 lines)</p>
        <p className="text-zinc-500">⌊ Edited 3 files · ran tests</p>
        <p>
          <span className="text-brand-green">✓</span>{" "}
          <span className="text-zinc-100">12 passed</span>{" "}
          <span className="text-zinc-500">· 0 failed</span>
        </p>
        <p className="mt-5">
          <span className="inline-block rounded-full bg-brand-green/15 px-3.5 py-1 text-xs text-brand-green sm:text-sm">
            session survives restarts
          </span>
        </p>
      </div>
    </div>
  );
}
