---
name: og-generation
description: "Regenerate the landing site's OG/social card (web/landing/public/og.webp) by rendering a temporary in-app route with the real hero WebGL aurora and screenshotting it with headless Chrome. Invoke when the user says 'regenerate the og image', 'update the og card', 'change the og screenshot/copy', '重新生成 og 图', or edits any copy/screenshot that appears on the social card."
---

# OG Card Generation

The OG image is NOT hand-drawn or CSS-faked: it is a screenshot of a temporary
Next.js route that reuses the site's real components (`HeroGradient` WebGL
aurora + grain overlay + `AgentIcon`), so the card always matches the live
hero. The canonical card source lives in this skill at
`assets/og-card-page.tsx`.

## Workflow

All paths below are relative to `web/landing/`.

1. **Restore the temp route** from the skill asset:
   ```bash
   mkdir -p src/app/og-card
   cp <skill-dir>/assets/og-card-page.tsx src/app/og-card/page.tsx
   ```

2. **Apply the requested changes** (copy, screenshot, layout) to
   `src/app/og-card/page.tsx`. Current design decisions — keep them unless the
   user overrides:
   - Wordmark is capitalized **"Termio"** (matches the nav `Logo` component).
   - Headline slogan has **no trailing period**.
   - Subline: "Terminal-first Agentic Development Environment, built for
     AI builders."
   - Agent row uses real `AgentIcon` icons; sizes are tuned (30px text / 34px
     icons / 30px gap) so all six agents fit on ONE row inside the 1080px left
     column — if you add an agent or grow the sizes, re-check that Kimi/Pi
     don't clip under the screenshot or wrap to a lonely second line.
   - Screenshot window: `public/screenshots/hero1.png` at left 1240 / top 150 /
     width 1560, 28px radius, white/0.18 border.
   - The page includes `nextjs-portal { display: none }` — this hides the Next
     dev-tools badge, which otherwise ships in the capture. Don't remove it.

3. **Find the landing dev server port — do NOT assume 3000.** Port 3000 is
   often a different project (you'll get a foreign 404 page). Trick: attempt to
   start a server; if one is already running for this directory, Next refuses
   and prints the existing server's port:
   ```bash
   npx next dev -p 3210   # either becomes the server, or prints
                          # "Another next dev server is already running.
                          #  - Local: http://localhost:3001"
   ```
   Verify with `curl -s localhost:<port>/og-card` returning 200 (and kill the
   server afterwards if you started it yourself).

4. **Screenshot with headless Chrome** (WebGL needs the swiftshader flag;
   virtual time budget lets hydration + the shader's first frame land):
   ```bash
   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
     --headless=new --enable-unsafe-swiftshader \
     --screenshot=/tmp/og-card/og.png --window-size=2400,1260 \
     --hide-scrollbars --force-device-scale-factor=1 \
     --virtual-time-budget=15000 http://localhost:<port>/og-card
   ```

5. **Visually inspect** `/tmp/og-card/og.png` (Read tool) before shipping —
   check for the dev badge, clipped/wrapped agent row, stale screenshot, typos.

6. **Ship + clean up** (the route must never be deployed):
   ```bash
   magick /tmp/og-card/og.png -quality 88 public/og.webp
   cp src/app/og-card/page.tsx <skill-dir>/assets/og-card-page.tsx  # persist edits
   rm -rf src/app/og-card
   curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>/og-card  # expect 404
   ```

7. **Sync metadata**: `og.webp` is referenced from `src/app/layout.tsx`
   (`openGraph.images` + `twitter.images`, 2400×1260). If the embedded
   screenshot or its content changed, update the `alt` text there to describe
   what's actually shown.

## Notes

- Keep the copy consistent with the hero section (`sections/hero.tsx`) — the
  card's headline/tagline should track it when the hero copy changes.
- OG rendition is 2400×1260 (2× of the 1200×630 OG standard, 1.9:1).
- Social platforms cache OG images by URL; after deploying, old shares may show
  the previous card until their cache expires. Remind the user.
