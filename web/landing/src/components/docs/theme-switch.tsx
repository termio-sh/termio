"use client";

import { useEffect, useState } from "react";
import { cn } from "@/lib/utils";
import type { DocsChrome } from "@/lib/docs-ui";

export type DocsTheme = "system" | "light" | "dark";

// Where the choice is kept, and the attribute the stylesheet keys on. The inline
// script in the docs layout reads the same two names before first paint — keep
// them in step (see DocsThemeScript).
export const DOCS_THEME_KEY = "termio-docs-theme";

function apply(theme: DocsTheme) {
  const root = document.documentElement;
  if (theme === "system") {
    delete root.dataset.docsTheme;
    localStorage.removeItem(DOCS_THEME_KEY);
  } else {
    root.dataset.docsTheme = theme;
    localStorage.setItem(DOCS_THEME_KEY, theme);
  }
}

// The docs' appearance switch: System, Light, Dark. Only the docs have it — the
// landing page is a dark object by design — so the choice is stored under its own
// key and applied to a `data-docs-theme` attribute the docs styles scope on.
export function ThemeSwitch({ chrome }: { chrome: DocsChrome }) {
  // Undefined until mounted: the server has no way to know what the reader
  // picked, and rendering a guess would flip a button under them on hydration.
  const [theme, setTheme] = useState<DocsTheme | undefined>(undefined);

  // The attribute on <html> is the state, not this component — the shell renders
  // one switch for the desktop sidebar and one inside the mobile menu, and
  // watching the attribute keeps both honest instead of letting the hidden one go
  // stale until a resize reveals it.
  useEffect(() => {
    const root = document.documentElement;
    const read = () => {
      const current = root.dataset.docsTheme;
      setTheme(current === "light" || current === "dark" ? current : "system");
    };
    read();
    const observer = new MutationObserver(read);
    observer.observe(root, {
      attributes: true,
      attributeFilter: ["data-docs-theme"],
    });
    return () => observer.disconnect();
  }, []);

  const options: { value: DocsTheme; label: string; icon: React.ReactNode }[] = [
    { value: "system", label: chrome.themeSystem, icon: <SystemIcon /> },
    { value: "light", label: chrome.themeLight, icon: <SunIcon /> },
    { value: "dark", label: chrome.themeDark, icon: <MoonIcon /> },
  ];

  return (
    <div
      className="inline-flex items-center gap-0.5 rounded-lg border border-border p-0.5"
      role="group"
      aria-label={chrome.theme}
    >
      {options.map((option) => {
        const active = theme === option.value;
        return (
          <button
            key={option.value}
            type="button"
            title={option.label}
            aria-label={option.label}
            aria-pressed={theme === undefined ? undefined : active}
            // No setTheme here: apply() moves the attribute, and the observer
            // above turns that into state — for every switch on the page.
            onClick={() => apply(option.value)}
            className={cn(
              "inline-flex h-6 w-6 items-center justify-center rounded-md transition-colors",
              active
                ? "bg-secondary text-foreground"
                : "text-muted-foreground hover:text-foreground",
            )}
          >
            {option.icon}
          </button>
        );
      })}
    </div>
  );
}

const iconProps = {
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 2,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
  "aria-hidden": true,
  className: "h-3.5 w-3.5",
};

function SystemIcon() {
  return (
    <svg {...iconProps}>
      <rect x="2" y="3" width="20" height="14" rx="2" />
      <path d="M8 21h8M12 17v4" />
    </svg>
  );
}

function SunIcon() {
  return (
    <svg {...iconProps}>
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
    </svg>
  );
}

function MoonIcon() {
  return (
    <svg {...iconProps}>
      <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z" />
    </svg>
  );
}
