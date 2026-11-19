import type { Metadata } from "next";
import { SiteNav } from "@/components/site-nav";
import { SiteFooter } from "@/components/site-footer";
import { SectionLabel } from "@/components/section-label";
import { Reveal } from "@/components/reveal";
import { changelog, type ChangeKind } from "@/data/changelog";

export const metadata: Metadata = {
  title: "Changelog",
  description:
    "What's new in Termio — new features, improvements and fixes, shipped to every Mac through built-in auto-updates.",
  alternates: {
    canonical: "/changelog",
  },
  openGraph: {
    title: "Termio changelog",
    description:
      "What's new in Termio — new features, improvements and fixes, shipped to every Mac through built-in auto-updates.",
    url: "/changelog",
  },
};

const kindLabel: Record<ChangeKind, string> = {
  new: "New",
  improved: "Improvements",
  fixed: "Fixes",
};

const kindOrder: ChangeKind[] = ["new", "improved", "fixed"];

function formatDate(iso: string): string {
  // Append a midday UTC time so the calendar date is stable regardless of the
  // renderer's timezone.
  return new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}

// "Label: rest" items get a bold lead. Only short, sentence-free prefixes count
// as labels, so a colon that happens to appear mid-sentence stays plain.
function splitLead(item: string): { lead: string; rest: string } | null {
  const idx = item.indexOf(": ");
  if (idx <= 0 || idx > 40) return null;
  const lead = item.slice(0, idx);
  if (lead.includes(".")) return null;
  return { lead, rest: item.slice(idx + 2) };
}

export default function ChangelogPage() {
  return (
    <>
      <SiteNav />
      <main className="flex-1">
        <section className="scroll-mt-24">
          <div className="mx-auto w-full px-5 pb-32 pt-36 sm:px-8 sm:pb-40 sm:pt-44">
            <Reveal className="mx-auto mb-14 w-full max-w-[680px] text-center sm:mb-20">
              <SectionLabel accent="muted">Changelog</SectionLabel>
              <h1 className="mt-4 text-balance text-4xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-5xl">
                What&apos;s new in Termio
              </h1>
              <p className="mx-auto mt-5 max-w-md text-base leading-relaxed text-muted-foreground">
                Every release ships to your Mac through built-in auto-updates —
                no reinstalling, no checking a website.
              </p>
            </Reveal>

            {/* Glaze-style release ledger: a 640px reading column that grows a
                sticky meta rail (version pill + date, right-aligned) on xl,
                entries separated by hairlines rather than cards. */}
            <div className="mx-auto w-full max-w-[640px] xl:max-w-[1200px]">
              <div className="flex flex-col">
                {changelog.map((entry, index) => (
                  <Reveal
                    as="article"
                    key={entry.version}
                    delayMs={Math.min(index, 3) * 70}
                    className="grid border-t border-border py-10 first:border-t-0 first:pt-0 last:border-b xl:grid-cols-[minmax(0,1fr)_minmax(0,640px)_minmax(0,1fr)] xl:gap-x-16 xl:py-16 xl:first:pt-16"
                  >
                    <aside className="mb-5 xl:col-start-1 xl:mb-0 xl:justify-self-end">
                      <div className="flex items-center gap-3 text-sm text-muted-foreground xl:sticky xl:top-28 xl:justify-end xl:pt-1.5">
                        <span className="inline-flex shrink-0 items-center justify-center rounded-full bg-white/[0.08] px-3 py-1 font-mono text-[13px] font-medium leading-none text-foreground/80">
                          v{entry.version}
                        </span>
                        <time dateTime={entry.date}>
                          {formatDate(entry.date)}
                        </time>
                      </div>
                    </aside>

                    <div className="min-w-0 xl:col-start-2">
                      <h2 className="text-balance text-2xl font-medium leading-[1.08] tracking-tight text-foreground sm:text-3xl">
                        {entry.title}
                      </h2>

                      <div className="mt-6 space-y-6">
                        {kindOrder.map((kind) => {
                          const items = entry.changes[kind];
                          if (!items || items.length === 0) return null;
                          return (
                            <div key={kind}>
                              <h3 className="text-lg font-medium leading-tight text-foreground">
                                {kindLabel[kind]}
                              </h3>
                              <ul className="mt-3 space-y-2.5">
                                {items.map((item) => {
                                  const split = splitLead(item);
                                  return (
                                    <li
                                      key={item}
                                      className="flex gap-3 text-[15px] leading-[1.65] text-foreground/75"
                                    >
                                      {/* Glaze's dash bullet — a short hairline
                                          instead of a dot. */}
                                      <span
                                        aria-hidden="true"
                                        className="mt-[0.78em] h-px w-3 shrink-0 bg-muted-foreground/70"
                                      />
                                      <span>
                                        {split ? (
                                          <>
                                            <strong className="font-medium text-foreground">
                                              {split.lead}:
                                            </strong>{" "}
                                            {split.rest}
                                          </>
                                        ) : (
                                          item
                                        )}
                                      </span>
                                    </li>
                                  );
                                })}
                              </ul>
                            </div>
                          );
                        })}
                      </div>
                    </div>
                  </Reveal>
                ))}
              </div>
            </div>
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
