import { NextResponse, type NextRequest } from "next/server";
import { i18n, isDocsLanguage } from "@/lib/i18n";

// A doc page has two representations at one address: the HTML a reader sees, and
// the Markdown an agent wants. `/docs/<slug>.md` names the Markdown explicitly —
// this serves the same bytes at the plain page URL when the client asked for
// Markdown in its `Accept` header, so an agent handed a docs link out of a search
// result or a chat message never has to know about the suffix or parse the shell.
//
// Browsers are unaffected: they send `text/html,…,*/*;q=0.8` and never name
// Markdown, and `*/*` deliberately doesn't count as a request for it.
export const config = {
  matcher: ["/docs/:path*", "/:lang/docs/:path*"],
};

const MARKDOWN_TYPES = new Set(["text/markdown", "text/x-markdown"]);

/** True when the client ranks Markdown at or above HTML in its `Accept` header. */
function prefersMarkdown(accept: string | null): boolean {
  if (!accept) return false;

  let markdown = 0;
  let html = 0;
  for (const range of accept.split(",")) {
    const [type, ...parameters] = range.trim().split(";");
    const quality = parameters
      .map((parameter) => parameter.trim().match(/^q=([0-9.]+)$/i))
      .find(Boolean);
    const weight = quality ? Number.parseFloat(quality[1]) : 1;
    if (Number.isNaN(weight)) continue;

    const media = type.trim().toLowerCase();
    if (MARKDOWN_TYPES.has(media)) markdown = Math.max(markdown, weight);
    else if (media === "text/html") html = Math.max(html, weight);
  }

  return markdown > 0 && markdown >= html;
}

export function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;
  // Already the Markdown twin — next.config's rewrite takes it from here.
  if (pathname.endsWith(".md")) return NextResponse.next();
  if (!prefersMarkdown(request.headers.get("accept"))) {
    return varyOnAccept(NextResponse.next());
  }

  const segments = pathname.split("/").filter(Boolean);
  const head = segments[0];
  // The default language has no prefix of its own, so `/en/docs` is not a route.
  const localized =
    isDocsLanguage(head) && head !== i18n.defaultLanguage && segments[1] === "docs";
  if (!localized && head !== "docs") return NextResponse.next();

  const slug = segments.slice(localized ? 2 : 1);
  const path = [
    ...(localized ? [head] : []),
    ...(slug.length ? slug : ["index"]),
  ];

  return varyOnAccept(
    NextResponse.rewrite(new URL(`/docs-md/${path.join("/")}`, request.url)),
  );
}

// Two representations answer to one URL, so a downstream cache that keyed on the
// URL alone would hand one client the other's. It sticks to the Markdown branch;
// on the HTML branch Next writes its own `Vary` onto the prerendered response and
// drops this one — configuring it in next.config's `headers` loses the same way.
// The consequence is contained: this proxy runs ahead of the CDN's own lookup, so
// the cache is keyed on the rewritten path rather than on `/docs/<slug>`.
function varyOnAccept(response: NextResponse): NextResponse {
  response.headers.append("Vary", "Accept");
  return response;
}
