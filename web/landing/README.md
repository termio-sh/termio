# Termio — landing page

The marketing site for **Termio**, a native macOS terminal that gives every AI
coding agent (Claude Code, Codex, Gemini, Amp, and more) a first-class home.
Termio is **free to use** — the site's only call to action is the Mac download.

Built with **Next.js (App Router) + TypeScript + Tailwind CSS v4 + shadcn/ui**.
The visual design is modeled on [superwhisper.com](https://superwhisper.com) — a
dark, cinematic, gradient-forward Mac-app aesthetic — while all copy and product
facts are about Termio.

## Run it

```sh
pnpm install
pnpm dev      # http://localhost:3000
```

Other scripts:

```sh
pnpm build    # production build (type-checks the whole app)
pnpm start    # serve the production build
pnpm lint     # ESLint
```

No environment variables are required — there is no backend. The **Download for
Mac** buttons link to the notarized `.dmg` URL configured in
[`src/lib/site.ts`](src/lib/site.ts) (`downloadUrl`).

## Structure

```
src/
  app/
    layout.tsx          # Inter font, SEO metadata, favicon
    page.tsx            # the landing page (assembles all sections)
    changelog/page.tsx  # /changelog route, rendered from src/data/changelog.ts
    globals.css         # dark cinematic theme + brand palette + reveal animation
  components/
    site-nav.tsx        # sticky nav
    site-footer.tsx     # grouped footer links
    hero-gradient.tsx   # animated WebGL mesh-gradient hero backdrop
    termio-window.tsx   # CSS/JSX mock of the app (hero visual)
    reveal.tsx          # IntersectionObserver scroll-entrance wrapper
    sections/           # hero, social-proof, features, faq, cta-band
    ui/                 # shadcn components (button, card, accordion, badge, separator)
  data/changelog.ts     # the entries rendered at /changelog
  lib/site.ts           # download URL, nav links, supported agents, hero screenshot
```

## Notes

- **Theme: dark, cinematic**, matching the design source. The hero backdrop is an
  animated WebGL mesh gradient (`hero-gradient.tsx`) with a CSS gradient fallback
  in `globals.css`; brand accents use the terminal traffic-light trio plus
  gradient blues, cyan, and purple.
- Scroll-entrance animations are a tiny IntersectionObserver wrapper (no heavy
  animation library) and respect `prefers-reduced-motion`.
- The hero/feature visuals are pure CSS/JSX mocks — no screenshots required.
