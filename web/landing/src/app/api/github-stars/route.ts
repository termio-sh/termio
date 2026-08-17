import { NextResponse } from "next/server";
import { githubApiUrl } from "@/lib/site";

// Star count for the hero's GitHub button. The Next.js data cache holds the
// GitHub response for 30 minutes, so the server sends GitHub at most two
// requests an hour — far under the unauthenticated 60/hour per-IP limit even
// on a shared egress IP.
export async function GET() {
  try {
    const response = await fetch(githubApiUrl, {
      next: { revalidate: 1800 },
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!response.ok) return NextResponse.json({ stars: null });
    const repo = (await response.json()) as { stargazers_count?: number };
    return NextResponse.json({
      stars:
        typeof repo.stargazers_count === "number"
          ? repo.stargazers_count
          : null,
    });
  } catch {
    return NextResponse.json({ stars: null });
  }
}
