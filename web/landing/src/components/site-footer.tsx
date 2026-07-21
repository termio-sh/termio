const footerLinks: { label: string; href: string }[] = [
  { label: "Changelog", href: "/changelog" },
  { label: "Docs", href: "/docs" },
  { label: "Privacy", href: "/privacy" },
  { label: "Terms", href: "/terms" },
];

// Glaze-style footer: one compact centered column — copyright and page links on
// a single row, a quiet tagline underneath. No border, no link grid; on the
// homepage it floats over the outro aurora, on inner pages it just sits on the
// canvas.
export function SiteFooter() {
  return (
    <footer className="px-5 pb-8 pt-16 sm:px-8 sm:pb-14">
      <div className="mx-auto flex w-full max-w-[960px] flex-col items-center justify-center gap-2.5 text-sm leading-5 text-muted-foreground">
        <div className="flex w-full flex-col items-center justify-center gap-2.5 sm:flex-row sm:gap-4">
          <span>© {new Date().getFullYear()} Termio</span>
          <nav
            className="flex flex-wrap items-center justify-center gap-x-4 gap-y-2"
            aria-label="Footer"
          >
            {footerLinks.map((link) => (
              <a
                key={link.label}
                href={link.href}
                className="py-1 text-muted-foreground transition-colors hover:text-foreground"
              >
                {link.label}
              </a>
            ))}
          </nav>
        </div>
        <p className="font-mono text-xs text-muted-foreground/80">
          Built for AI Builders by AI Builders.
        </p>
      </div>
    </footer>
  );
}
