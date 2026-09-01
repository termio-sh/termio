import { ImageResponse } from "next/og";
import { i18n } from "@/lib/i18n";
import { source } from "@/lib/source";

// The social card for a doc page. Every docs link used to share the landing page's
// picture, so fifteen different pages arrived in a chat as the same image; this
// gives each one its own title, which is the only thing a reader can act on when a
// link lands in Slack or a thread. `docPageMetadata` points og:image here.
//
// It is a route handler rather than the `opengraph-image` file convention because
// the docs page is an optional catch-all, and Next refuses a metadata route under
// one. Same reason `/docs/<slug>.md` is served from /docs-md.
//
// English only: the card is drawn with the default font next/og ships, which has
// no CJK coverage, and a Chinese title would render as boxes. The translated pages
// keep the site card until a subset font is worth carrying.
//
// Prerendered at build time — the docs sources aren't in the serverless bundle.
export const dynamic = "force-static";
export const dynamicParams = false;

export const size = { width: 1200, height: 630 };

export function generateStaticParams() {
  return source
    .getPages(i18n.defaultLanguage)
    .map((page) => ({ slug: page.slugs.length ? page.slugs : ["index"] }));
}

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ slug: string[] }> },
) {
  const { slug } = await params;
  const path = slug.join("/") === "index" ? [] : slug;
  const page = source.getPage(path, i18n.defaultLanguage);
  const title = drawable(page?.data.title ?? "Documentation");
  const description = drawable(page?.data.description ?? "");
  const trail = ["termio.sh", "docs", ...path].join("/");

  return new ImageResponse(
    (
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          width: "100%",
          height: "100%",
          backgroundColor: "#08080a",
          color: "#fafafa",
        }}
      >
        <div
          style={{
            display: "flex",
            height: 8,
            width: "100%",
            backgroundImage:
              "linear-gradient(90deg, #00d3c7 0%, #0088ff 55%, #b855e7 100%)",
          }}
        />
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            flex: 1,
            justifyContent: "space-between",
            padding: "68px 76px 60px",
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
            <div style={{ display: "flex", fontSize: 30, letterSpacing: -0.5 }}>
              termio
            </div>
            <div
              style={{
                display: "flex",
                borderRadius: 8,
                border: "1px solid #2a2a30",
                padding: "3px 10px",
                fontSize: 20,
                color: "#9b9ba4",
              }}
            >
              Docs
            </div>
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 22 }}>
            <div
              style={{
                display: "flex",
                fontSize: 74,
                lineHeight: 1.08,
                letterSpacing: -2,
                maxWidth: 960,
              }}
            >
              {title}
            </div>
            {description ? (
              <div
                style={{
                  display: "flex",
                  fontSize: 30,
                  lineHeight: 1.4,
                  color: "#9b9ba4",
                  maxWidth: 900,
                }}
              >
                {clamp(description, 150)}
              </div>
            ) : null}
          </div>

          <div style={{ display: "flex", fontSize: 24, color: "#6d6d78" }}>
            {trail}
          </div>
        </div>
      </div>
    ),
    size,
  );
}

// The bundled font has no glyph for the ▸ this site uses for menu paths, and
// satori draws a missing glyph as an empty box — "Settings ▸ Keyboard" arrived on
// the card as "Settings ☐ Keyboard". The single-angle quote says the same thing
// and is in the font.
function drawable(text: string): string {
  return text.replace(/▸/g, "›");
}

/** Keeps a long description from pushing the title off the card. */
function clamp(text: string, limit: number): string {
  if (text.length <= limit) return text;
  const cut = text.slice(0, limit);
  const lastSpace = cut.lastIndexOf(" ");
  return `${(lastSpace > limit * 0.6 ? cut.slice(0, lastSpace) : cut).trimEnd()}…`;
}
