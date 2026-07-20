"use client";

import { Fragment, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { useDocsSearch } from "fumadocs-core/search/client";
import { fetchClient } from "fumadocs-core/search/client/fetch";
import { cn } from "@/lib/utils";

// A ⌘K search dialog over the headless Orama index (/api/search). The trigger is
// a quiet search field that matches the sidebar; the dialog itself is a
// lightweight modal so we don't pull in extra dependencies.
export function DocsSearch() {
  const [open, setOpen] = useState(false);

  // Global ⌘K / Ctrl-K to open, Escape to close.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((v) => !v);
      }
      if (e.key === "Escape") setOpen(false);
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="flex w-full items-center gap-2 rounded-xl border border-border bg-secondary/50 px-3 py-2 text-[13px] text-muted-foreground transition-colors hover:border-foreground/20 hover:text-foreground"
      >
        <SearchIcon className="h-3.5 w-3.5" />
        <span className="flex-1 text-left">Search docs</span>
        <kbd className="rounded-md border border-border bg-background px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground">
          ⌘K
        </kbd>
      </button>
      {open && <SearchDialog onClose={() => setOpen(false)} />}
    </>
  );
}

function SearchDialog({ onClose }: { onClose: () => void }) {
  const router = useRouter();
  const { search, setSearch, query } = useDocsSearch({
    client: fetchClient(),
  });

  const results = Array.isArray(query.data) ? query.data : [];

  function go(url: string) {
    onClose();
    router.push(url);
  }

  return (
    <div
      className="fixed inset-0 z-[100] flex items-start justify-center px-4 pt-[12vh]"
      role="dialog"
      aria-modal="true"
      aria-label="Search docs"
    >
      {/* Scrim */}
      <button
        type="button"
        aria-label="Close search"
        onClick={onClose}
        className="absolute inset-0 bg-black/50 backdrop-blur-sm"
      />
      <div className="liquid-glass relative w-full max-w-xl overflow-hidden rounded-2xl">
        <div className="flex items-center gap-3 border-b border-border px-4">
          <SearchIcon className="h-4 w-4 text-muted-foreground" />
          {/* eslint-disable-next-line jsx-a11y/no-autofocus */}
          <input
            autoFocus
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search the docs…"
            className="w-full bg-transparent py-3.5 text-[15px] text-foreground placeholder:text-muted-foreground focus:outline-none"
          />
          <kbd className="rounded-md border border-border px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground">
            esc
          </kbd>
        </div>

        <div className="max-h-[min(60vh,24rem)] overflow-y-auto p-2">
          {query.isLoading && (
            <p className="px-3 py-6 text-center text-[13px] text-muted-foreground">
              Searching…
            </p>
          )}
          {!query.isLoading && query.error && (
            <p className="px-3 py-6 text-center text-[13px] text-muted-foreground">
              Search isn’t available right now — try again in a moment.
            </p>
          )}
          {!query.isLoading &&
            !query.error &&
            search.length > 0 &&
            results.length === 0 && (
              <p className="px-3 py-6 text-center text-[13px] text-muted-foreground">
                No results for “{search}”.
              </p>
            )}
          {results.map((item) => (
            <button
              key={item.id}
              type="button"
              onClick={() => go(item.url)}
              className={cn(
                "block w-full rounded-lg px-3 py-2 text-left transition-colors hover:bg-secondary",
                item.type === "page" ? "mt-1" : "",
              )}
            >
              {item.type !== "page" && item.breadcrumbs?.length ? (
                <span className="block text-[11px] text-muted-foreground/70">
                  {item.breadcrumbs.map((crumb, i) => (
                    <Fragment key={i}>
                      {i > 0 && " › "}
                      <Highlighted text={crumb} />
                    </Fragment>
                  ))}
                </span>
              ) : null}
              <span
                className={cn(
                  "block truncate text-[14px]",
                  item.type === "page"
                    ? "font-medium text-foreground"
                    : "text-foreground/80",
                )}
              >
                <Highlighted text={item.content} />
              </span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// Result content arrives as a Markdown string with the matched terms wrapped in
// `<mark>` tags (fumadocs SortedResult). Render the marks as real highlights and
// strip the inline-code/bold markers that read as noise in a one-line result.
function Highlighted({ text }: { text: string }) {
  const parts = text.split(/<mark>([\s\S]*?)<\/mark>/g);
  return (
    <>
      {parts.map((part, i) =>
        i % 2 === 1 ? (
          <mark
            key={i}
            className="rounded-[3px] bg-primary/25 px-px text-foreground"
          >
            {stripInlineMarkdown(part)}
          </mark>
        ) : (
          <Fragment key={i}>{stripInlineMarkdown(part)}</Fragment>
        ),
      )}
    </>
  );
}

function stripInlineMarkdown(text: string) {
  return text.replace(/\*\*|[`]/g, "");
}

function SearchIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className={className}
    >
      <circle cx="11" cy="11" r="8" />
      <path d="m21 21-4.3-4.3" />
    </svg>
  );
}
