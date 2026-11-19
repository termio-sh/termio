import Image from "next/image";
import Link from "next/link";
import type { ComponentProps, ReactNode } from "react";
import type { MDXComponents } from "mdx/types";
import defaultMdxComponents from "fumadocs-ui/mdx";
import { Keybindings } from "@/components/docs/keybindings";
import { cn } from "@/lib/utils";

// Glyphs and optional titles identify the callout type without adding colour.
type CalloutType = "note" | "tip" | "warning";

const CALLOUT_ICONS: Record<CalloutType, ReactNode> = {
  note: <InfoIcon className="h-4 w-4 text-foreground" />,
  tip: <BulbIcon className="h-4 w-4 text-foreground" />,
  warning: <WarnIcon className="h-4 w-4 text-foreground" />,
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
  const icon = CALLOUT_ICONS[type];
  // The title stays above the body rather than on its first line, which is where
  // opencode puts it: their aside titles are one word ("Tip", "Note") and sit in
  // front of the sentence the way a label does. These titles are whole sentences —
  // "Workspace" means the sidebar's scope — and a sentence set beside a paragraph
  // leaves both of them in a third of the column.
  return (
    <div
      className={cn(
        "my-6 rounded-xl border border-border bg-secondary/40 px-4 py-3",
        className,
      )}
    >
      <div className="flex gap-3">
        <span className="mt-0.5 shrink-0">{icon}</span>
        <div className="min-w-0 leading-[1.7] text-foreground/80 [&>:first-child]:mt-0">
          {title && <p className="mb-1 font-medium text-foreground">{title}</p>}
          {children}
        </div>
      </div>
    </div>
  );
}

// A card grid for hub navigation and "Next steps" sections — the pattern Ghostty
// and the JetBrains AI docs use to point readers at the next thing to read.
function Cards({ children }: { children: ReactNode }) {
  return <div className="mt-6 grid gap-3 sm:grid-cols-2">{children}</div>;
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
  // Unfilled until you point at it: the card is a link, and a permanent tinted
  // panel per card turns a "Next steps" grid into four competing blocks. Base UI
  // treats its own affordances the same way — the surface arrives on hover.
  const cls =
    "group block rounded-xl border border-border p-4 no-underline transition-colors hover:border-foreground/20 hover:bg-secondary/50";
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

type DocsImageVariant = "window" | "phone";

function DocsImage({
  src,
  alt,
  width,
  height,
  variant = "window",
}: {
  src: string;
  alt: string;
  width: number;
  height: number;
  variant?: DocsImageVariant;
}) {
  return (
    <figure className="not-prose my-8">
      <a
        href={src}
        target="_blank"
        rel="noreferrer"
        className={cn(
          "mx-auto block cursor-zoom-in overflow-visible rounded-xl focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring",
          variant === "phone" ? "max-w-[380px]" : "w-full",
        )}
      >
        <Image
          src={src}
          alt={alt}
          width={width}
          height={height}
          sizes={
            variant === "phone"
              ? "(max-width: 640px) 88vw, 380px"
              : "(max-width: 768px) 100vw, 768px"
          }
          className="h-auto w-full select-none"
        />
      </a>
    </figure>
  );
}

function DocsMediaGrid({ children }: { children: ReactNode }) {
  return (
    <div className="not-prose my-8 grid items-start gap-5 sm:grid-cols-2 [&>figure]:my-0">
      {children}
    </div>
  );
}

function DocsVideo({
  src,
  poster,
  label,
}: {
  src: string;
  poster: string;
  label: string;
}) {
  return (
    <figure className="not-prose my-8">
      <video
        controls
        muted
        playsInline
        preload="metadata"
        poster={poster}
        aria-label={label}
        className="h-auto w-full rounded-xl"
      >
        <source src={src} type="video/mp4" />
      </video>
    </figure>
  );
}

// Internal links route through Next's <Link>; anything absolute (http, mailto)
// stays a plain anchor that opens in a new tab.
function DocsLink({ href = "", ...props }: ComponentProps<"a">) {
  const isInternal = href.startsWith("/") || href.startsWith("#");
  if (isInternal) {
    return <Link href={href} {...props} />;
  }
  // The link text arrives as `children` inside `props`.
  // oxlint-disable-next-line jsx-a11y/anchor-has-content
  return <a href={href} target="_blank" rel="noreferrer" {...props} />;
}

// The component map handed to every compiled MDX page. It starts from the
// library's defaults and overrides from there — replacing them outright meant a
// fenced code block rendered as a bare <pre><code> with no `CodeBlock` around it,
// so it had no surface of its own and the only thing painting it was the
// inline-code chip repeating once per line. Ours win where we have a considered
// version: smart links, and the Callout and Card set built for this site.
export function getMDXComponents(extra?: MDXComponents): MDXComponents {
  return {
    ...defaultMdxComponents,
    a: DocsLink as MDXComponents["a"],
    Callout,
    Cards,
    Card,
    DocsImage,
    DocsMediaGrid,
    DocsVideo,
    Keybindings,
    ...extra,
    // `MDXComponents` declares every tag optional and also carries an index
    // signature that rejects `undefined`, so spreading it into itself never
    // satisfies its own type.
  } as MDXComponents;
}

function InfoIcon({ className }: { className?: string }) {
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
      <circle cx="12" cy="12" r="10" />
      <path d="M12 16v-4M12 8h.01" />
    </svg>
  );
}
function BulbIcon({ className }: { className?: string }) {
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
      <path d="M9 18h6M10 22h4M12 2a7 7 0 0 0-4 12.7c.6.5 1 1.3 1 2.1v.2h6v-.2c0-.8.4-1.6 1-2.1A7 7 0 0 0 12 2Z" />
    </svg>
  );
}
function WarnIcon({ className }: { className?: string }) {
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
      <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" />
      <path d="M12 9v4M12 17h.01" />
    </svg>
  );
}
function ArrowIcon({ className }: { className?: string }) {
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
      <path d="M5 12h14M13 6l6 6-6 6" />
    </svg>
  );
}
