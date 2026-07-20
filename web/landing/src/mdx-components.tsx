import Link from "next/link";
import type { ComponentProps, ReactNode } from "react";
import type { MDXComponents } from "mdx/types";
import { cn } from "@/lib/utils";

// Typed callouts — a quiet note by default, with tip/warning accents. Modeled on
// the admonitions Warp and the JetBrains AI docs use to flag prerequisites and
// gotchas, kept within the site's hairline-panel aesthetic.
type CalloutType = "note" | "tip" | "warning";

const CALLOUT_STYLES: Record<
  CalloutType,
  { edge: string; icon: ReactNode }
> = {
  note: {
    edge: "border-l-brand-teal/50",
    icon: <InfoIcon className="h-4 w-4 text-brand-teal" />,
  },
  tip: {
    edge: "border-l-brand-green/50",
    icon: <BulbIcon className="h-4 w-4 text-brand-green" />,
  },
  warning: {
    edge: "border-l-brand-amber/60",
    icon: <WarnIcon className="h-4 w-4 text-brand-amber" />,
  },
};

function Callout({
  children,
  type = "note",
  title,
  className,
}: {
  children: ReactNode;
  type?: CalloutType;
  title?: string;
  className?: string;
}) {
  const style = CALLOUT_STYLES[type];
  return (
    <div
      className={cn(
        "my-6 rounded-lg border border-border border-l-2 bg-secondary/50 px-5 py-4",
        style.edge,
        className,
      )}
    >
      <div className="flex gap-3">
        <span className="mt-0.5 shrink-0">{style.icon}</span>
        <div className="min-w-0 text-[15px] leading-[1.65] text-foreground/80 [&>:first-child]:mt-0">
          {title && (
            <p className="mb-1 font-semibold text-foreground">{title}</p>
          )}
          {children}
        </div>
      </div>
    </div>
  );
}

// A card grid for hub navigation and "Next steps" sections — the pattern Ghostty
// and the JetBrains AI docs use to point readers at the next thing to read.
function Cards({ children }: { children: ReactNode }) {
  return (
    <div className="mt-6 grid gap-3 sm:grid-cols-2">{children}</div>
  );
}

function Card({
  href,
  title,
  children,
}: {
  href: string;
  title: string;
  children?: ReactNode;
}) {
  const isInternal = href.startsWith("/") || href.startsWith("#");
  const content = (
    <>
      <span className="flex items-center justify-between gap-2">
        <span className="text-[14px] font-semibold text-foreground">
          {title}
        </span>
        <ArrowIcon className="h-3.5 w-3.5 shrink-0 text-muted-foreground transition-transform group-hover:translate-x-0.5 group-hover:text-foreground" />
      </span>
      {children && (
        <span className="mt-1 block text-[13px] leading-relaxed text-muted-foreground">
          {children}
        </span>
      )}
    </>
  );
  const cls =
    "group block rounded-2xl border border-border bg-secondary/30 p-4 no-underline transition-colors hover:border-foreground/20 hover:bg-secondary/60";
  return isInternal ? (
    <Link href={href} className={cls}>
      {content}
    </Link>
  ) : (
    <a href={href} target="_blank" rel="noreferrer" className={cls}>
      {content}
    </a>
  );
}

// Internal links route through Next's <Link>; anything absolute (http, mailto)
// stays a plain anchor that opens in a new tab.
function DocsLink({ href = "", ...props }: ComponentProps<"a">) {
  const isInternal = href.startsWith("/") || href.startsWith("#");
  if (isInternal) {
    return <Link href={href} {...props} />;
  }
  return <a href={href} target="_blank" rel="noreferrer" {...props} />;
}

// The component map handed to every compiled MDX page. Typography is carried by
// the `.prose-docs` wrapper (globals.css); here we swap in behavior — smart
// links — and register the custom components authors can use in MDX.
export function getMDXComponents(extra?: MDXComponents): MDXComponents {
  return {
    a: DocsLink as MDXComponents["a"],
    Callout,
    Cards,
    Card,
    ...extra,
  };
}

function InfoIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <circle cx="12" cy="12" r="10" />
      <path d="M12 16v-4M12 8h.01" />
    </svg>
  );
}
function BulbIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="M9 18h6M10 22h4M12 2a7 7 0 0 0-4 12.7c.6.5 1 1.3 1 2.1v.2h6v-.2c0-.8.4-1.6 1-2.1A7 7 0 0 0 12 2Z" />
    </svg>
  );
}
function WarnIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" />
      <path d="M12 9v4M12 17h.01" />
    </svg>
  );
}
function ArrowIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="M5 12h14M13 6l6 6-6 6" />
    </svg>
  );
}
