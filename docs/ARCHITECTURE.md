# Termio Web — Architecture

This describes the `web/` project: the marketing site. Termio is **free to use**
— there is no checkout, no licensing service, and no backend. The desktop app
lives in the repository root (`Sources/termio`) and is out of scope here.

## One sub-project

### `web/landing` — marketing site

The public website. A developer evaluates Termio and clicks through to download
the Mac app.

- **Stack:** Next.js + TypeScript, styled with Tailwind CSS and
  [shadcn/ui](https://ui.shadcn.com/) components.
- **Design:** modeled on [superwhisper.com](https://superwhisper.com/) — clean,
  dark, product-forward. (We borrow superwhisper's *visual* language only.)
- **Responsibility:** present the product, and link out to the Mac download.

## Distribution

Termio ships as a notarized `.dmg` and updates itself in place:

- **Download** — the landing "Download for Mac" buttons point at a stable
  Cloudflare R2 URL (behind `downloads.termio.sh`) that always serves the newest
  build. The single source of that URL is `src/lib/site.ts`; the release workflow
  (`.github/workflows/release.yml`) overwrites the published `.dmg` on every tag.
- **Auto-update** — the app embeds [Sparkle](https://sparkle-project.org/), so
  once installed it keeps itself current from the same R2-hosted appcast. No
  reinstalling, no checking the website.

There is no account, no license key, and no server in the loop.

## Request flow

```
 ┌──────────┐   visit / read   ┌──────────────────┐
 │ Browser  │ ───────────────▶ │  web/landing     │
 │ (dev)    │                  │  Next.js + shadcn │
 └──────────┘                  └─────────┬─────────┘
      │                                  │ "Download for Mac"
      │                                  ▼
      │                        ┌───────────────────┐
      │        download .dmg ──│  Cloudflare R2    │
      │                        │  downloads.termio │
      │                        └─────────┬─────────┘
      ▼                                  │ Sparkle appcast (auto-update)
 ┌──────────────────────┐ ◀──────────────┘
 │  termio desktop app  │
 │  (macOS, local-only) │
 └──────────────────────┘
```

## Tech stack — role of each piece

| Piece | Where | Role |
|-------|-------|------|
| Next.js + TypeScript | landing | Marketing site, SSR/SSG pages |
| Tailwind + shadcn/ui | landing | Styling and component primitives |
| Cloudflare R2 | external | Hosts the notarized `.dmg` + Sparkle appcast |

## Local dev quickstart

- **Landing:** see [`web/landing/README.md`](../landing/README.md) — typically
  `npm install` then `npm run dev` (Next.js dev server).

There is no server to run.

## Deployment

| Component | Target | Notes |
|-----------|--------|-------|
| `web/landing` | **Vercel** | Native Next.js host; preview deploys per PR. |
| App download | **Cloudflare R2** | The `.dmg` + appcast, published by the release workflow on tag. |

### Configuration (high level)

- **Landing:** the download URL in `src/lib/site.ts`.
- **Release:** the notarized `.dmg` and Sparkle appcast are uploaded to R2 by
  `.github/workflows/release.yml` on each version tag.
