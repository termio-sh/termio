# Landing screenshots

Drop polished, real app captures here, then wire them up. These replace the
hand-built CSS mockups so the page shows the actual product.

## Hero (the one that matters most)

- **File:** `public/screenshots/hero.png` (or `.webp` — webp is smaller, prefer it)
- **What to show:** the termio window, **dark**, showing the sidebar (project →
  agent sessions) next to a **working** terminal pane — ideally a real Claude Code
  or Codex session mid-task. A dark screenshot is correct: it floats as a dark
  product shot on the light page (Apple "dark device on white" treatment).
- **Size:** capture at 2× (Retina). The app window is ~998×605 pt, so the PNG is
  ~**1996×1210 px**. Any 16:10-ish ratio is fine — just note the real pixel size.
- **Trim:** no window shadow, no desktop background — just the window
  (`screencapture -o`, or crop tightly).

Then set this in `src/lib/site.ts`:

```ts
export const heroScreenshot = {
  src: "/screenshots/hero.png",   // match the filename you dropped
  width: 1996,                    // real pixel width
  height: 1210,                   // real pixel height
};
```

That's it — the hero swaps from the CSS mock to your image automatically. (Tell me
the real dimensions if you'd rather I wire it.)

## Optional: bento card visuals

The four feature cards currently use stylized CSS diagrams (agent list, live
sessions, branch tree, privacy toggles). Those are fine as diagrams, but if you
want real crops, drop e.g. `multi-agent.png`, `sessions.png`, `worktrees.png` and
I'll swap them in the same way.


![alt text](image.png)