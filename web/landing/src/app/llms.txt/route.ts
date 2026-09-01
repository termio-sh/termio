import { markdownUrl, orderedDocPages, siteUrl } from "@/lib/docs-llms";
import { testflightUrl } from "@/lib/site";

// /llms.txt — the llmstxt.org index for agents: what Termio is, plus every doc
// page linked in its raw-Markdown form so an agent never has to parse the HTML
// shell. Must render at build time: route handlers are dynamic by default, and
// at request time the content/docs sources aren't in the serverless bundle.
export const dynamic = "force-static";

export function GET() {
  const docLines = orderedDocPages().map((page) => {
    const description = page.data.description
      ? `: ${page.data.description}`
      : "";
    return `- [${page.data.title}](${markdownUrl(page)})${description}`;
  });

  const body = [
    "# Termio",
    "",
    "> Termio is the Terminal-first Agentic Development Environment — a free, native macOS app for running AI coding agents (Claude Code, Codex, Antigravity, and friends) side by side. Sessions are organized by project, each with a live status, a built-in inspector, and an iPhone companion app. No account, no payment.",
    "",
    "## Docs",
    "",
    ...docLines,
    "",
    "## Optional",
    "",
    `- [Changelog](${siteUrl}/changelog): release history`,
    `- [iPhone companion beta](${testflightUrl}): TestFlight — mirrors Mac sessions live on the phone`,
    `- [Full docs in one file](${siteUrl}/llms-full.txt): every page above, concatenated`,
    `- [Agent skill](${siteUrl}/skill.md): the termio skill the Mac app installs into ~/.claude/skills and ~/.codex/skills — save it there yourself to drive sibling sessions from an agent Termio doesn't auto-configure`,
    `- Any docs page also answers with Markdown at its own URL when the request carries \`Accept: text/markdown\` — the \`.md\` links above are the explicit form of the same thing`,
    `- Programmatic docs search: \`GET ${siteUrl}/api/search?query=<terms>\` returns JSON results with page URLs`,
  ].join("\n");

  return new Response(`${body}\n`, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
