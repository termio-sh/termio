// Shared site constants. Termio is free to use and ships with Sparkle
// auto-updates — no account, no license keys, no payment backend.

// The agents Termio ships a manifest for, in the order the app itself lists
// them (`Sources/termio/Resources/agents/*.json`, the `order` field). Command
// and install link are copied from each manifest. The app bundles a few more
// manifests than this — an agent joins the list once it has a brand mark and
// someone has run it.
export const supportedAgents = [
  {
    name: "Claude Code",
    command: "claude",
    href: "https://claude.com/claude-code",
  },
  {
    name: "Codex",
    command: "codex",
    href: "https://developers.openai.com/codex/cli",
  },
  { name: "OpenCode", command: "opencode", href: "https://opencode.ai" },
  { name: "Pi", command: "pi", href: "https://pi.dev" },
  { name: "Amp", command: "amp", href: "https://ampcode.com/manual" },
  {
    name: "Cursor",
    command: "cursor-agent",
    href: "https://cursor.com/docs/cli",
  },
  {
    name: "Copilot",
    command: "copilot",
    href: "https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli",
  },
  {
    name: "Kimi",
    command: "kimi",
    href: "https://moonshotai.github.io/kimi-code",
  },
  {
    name: "Antigravity",
    command: "agy",
    href: "https://antigravity.google/product/antigravity-cli",
  },
  {
    name: "Crush",
    command: "crush",
    href: "https://github.com/charmbracelet/crush",
  },
  { name: "Grok", command: "grok", href: "https://x.ai/cli" },
] as const;

export const navLinks = [
  { label: "Docs", href: "/docs" },
  { label: "Changelog", href: "/changelog" },
] as const;

// Community Discord invite, surfaced in the site nav.
export const discordUrl = "https://discord.gg/H9DKVwsE5f";

// The public source repository, surfaced in the site nav and footer.
export const githubUrl = "https://github.com/termio-sh/termio";

// GitHub's repo API endpoint for the star count shown in the hero.
export const githubApiUrl = githubUrl.replace(
  "https://github.com/",
  "https://api.github.com/repos/",
);

export function formatStarCount(stars: number): string {
  return stars >= 1000
    ? `${(stars / 1000).toFixed(1).replace(/\.0$/, "")}k`
    : String(stars);
}

// The desktop build download — the stable Cloudflare R2 URL (behind
// downloads.termio.sh) that always serves the newest notarized DMG. The release
// workflow (.github/workflows/release.yml) overwrites this object on every tag.
export const downloadUrl = "https://downloads.termio.sh/termio.dmg";

export const testflightUrl = "https://testflight.apple.com/join/1Arf1UKR";

// Real app captures for the hero carousel (public/screenshots/hero*.png, all
// 2584×1714 @2x, Atom One Dark). The first one is the LCP
// image, so lead with the strongest shot.
export const heroSlides = [
  {
    src: "/screenshots/hero1.png?v=20261017",
    label: "Agents",
    alt: "Codex and Claude Code above a running development server in Atom One Dark.",
  },
  {
    src: "/screenshots/hero2.png?v=20261017",
    label: "Editor",
    alt: "SplitTree.swift open in the editor beside a Claude Code walkthrough.",
  },
  {
    src: "/screenshots/hero3.png?v=20261017",
    label: "Search",
    alt: "Project search showing SplitBranch matches grouped by file beside Claude Code.",
  },
  {
    src: "/screenshots/hero4.png?v=20261017",
    label: "Diff",
    alt: "A unified diff with red and green changes beside Claude Code.",
  },
  {
    src: "/screenshots/hero5.png?v=20261017",
    label: "History",
    alt: "Recent commits in the History panel beside a Claude Code session.",
  },
].map((slide) => ({ ...slide, width: 2584, height: 1714 }));
