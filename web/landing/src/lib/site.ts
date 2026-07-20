// Shared site constants. Termio is free to use and ships with Sparkle
// auto-updates — no account, no license keys, no payment backend. (Source will be
// opened later; not yet.)

export const supportedAgents = [
  "Claude Code",
  "Codex",
  "Gemini",
  "Amp",
  "Pi",
  "OpenCode",
  "Copilot",
  "Cursor",
] as const;

export const navLinks = [
  { label: "Docs", href: "/docs" },
  { label: "Changelog", href: "/changelog" },
] as const;

// Community Discord invite, surfaced in the site nav.
export const discordUrl = "https://discord.gg/H9DKVwsE5f";

// The desktop build download — the stable Cloudflare R2 URL (behind
// downloads.termio.sh) that always serves the newest notarized DMG. The release
// workflow (.github/workflows/release.yml) overwrites this object on every tag.
export const downloadUrl = "https://downloads.termio.sh/termio.dmg";

// Real app captures for the hero carousel (public/screenshots/hero*.png, all
// 3024×1898 @2x). The hero cross-fades through these; the first one is the LCP
// image, so lead with the strongest shot.
export const heroSlides = [
  {
    src: "/screenshots/hero1.png",
    alt: "Termio in dark mode: a live Claude Code session next to the project sidebar.",
  },
  {
    src: "/screenshots/hero2.png",
    alt: "Termio in light mode: a Codex session running beside the session sidebar.",
  },
  {
    src: "/screenshots/hero3.png",
    alt: "Termio's built-in file editor showing a Markdown file next to the project file tree.",
  },
  {
    src: "/screenshots/hero4.png",
    alt: "The inspector panel with working-directory and agent actions beside a Claude Code session.",
  },
  {
    src: "/screenshots/hero5.png",
    alt: "Split panes in Termio: a Claude Code session alongside a dev server and a shell terminal.",
  },
].map((slide) => ({ ...slide, width: 3024, height: 1898 }));
