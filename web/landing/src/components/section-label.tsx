import { cn } from "@/lib/utils";

// Superwhisper's section eyebrow: small, semibold, *colored* text — each section
// carries a different accent ("What's inside" magenta, "Custom Mode" blue, "Beep
// boop" yellow). Not a pill, not uppercase — just a tinted one-liner above the
// heading.
export type Accent = "pink" | "blue" | "green" | "yellow" | "violet" | "muted";

const accentText: Record<Accent, string> = {
  pink: "text-[#f472b6]",
  blue: "text-[#4ea3ff]",
  green: "text-[#34d399]",
  yellow: "text-[#fbbf24]",
  violet: "text-[#a78bfa]",
  muted: "text-muted-foreground",
};

export function SectionLabel({
  children,
  accent = "muted",
  className,
}: {
  children: React.ReactNode;
  accent?: Accent;
  className?: string;
}) {
  return (
    <span
      className={cn(
        "block text-sm font-semibold tracking-tight",
        accentText[accent],
        className,
      )}
    >
      {children}
    </span>
  );
}

// Apple logo glyph for the "Download for Mac" pills — the single most recognizable
// cue that this is a native Mac app.
export function AppleMark({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 16 16"
      aria-hidden="true"
      className={cn("h-[1.05em] w-[1.05em]", className)}
      fill="currentColor"
    >
      <path d="M11.182 8.41c.013 1.473 1.292 1.963 1.306 1.969-.011.035-.204.7-.673 1.385-.405.592-.825 1.182-1.487 1.194-.65.012-.86-.385-1.602-.385-.743 0-.976.373-1.591.397-.64.024-1.126-.64-1.534-1.23-.835-1.21-1.473-3.42-.616-4.91.425-.74 1.185-1.21 2.01-1.222.628-.012 1.221.422 1.605.422.384 0 1.105-.522 1.863-.445.317.013 1.208.128 1.78.964-.046.029-1.063.62-1.05 1.85ZM9.96 4.69c.34-.412.57-.985.507-1.555-.49.02-1.083.327-1.435.738-.315.365-.591.948-.517 1.508.547.042 1.105-.278 1.445-.69Z" />
    </svg>
  );
}

// GitHub's octocat glyph — the open-source cue, shared by the nav pill and the
// hero's star button.
export function GitHubMark({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      className={cn("h-[1.05em] w-[1.05em]", className)}
    >
      <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />
    </svg>
  );
}
