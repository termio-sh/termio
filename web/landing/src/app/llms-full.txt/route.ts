import {
  markdownUrl,
  orderedDocPages,
  siteUrl,
  stripFrontmatter,
} from "@/lib/docs-llms";

// /llms-full.txt — the entire docs corpus as one Markdown document, in sidebar
// order. Small enough to fit any model's context, so a single fetch gives an
// agent the complete picture. Must render at build time: getText("raw") reads
// the content/docs sources from disk, which aren't in the serverless bundle.
export const dynamic = "force-static";

export async function GET() {
  const sections = await Promise.all(
    orderedDocPages().map(async (page) => {
      const raw = await page.data.getText("raw");
      return [
        `# ${page.data.title}`,
        "",
        `URL: ${siteUrl}${page.url}`,
        `Markdown: ${markdownUrl(page)}`,
        "",
        stripFrontmatter(raw),
      ].join("\n");
    }),
  );

  return new Response(`${sections.join("\n\n---\n\n")}\n`, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
