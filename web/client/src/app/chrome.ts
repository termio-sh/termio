/**
 * Chrome colours, derived from the terminal palette rather than invented.
 *
 * This is a port of `Sources/termio/Theme/ChromeTheme.swift`, and the reason it
 * exists is the reason that file exists: termio keeps **one** source of colour
 * truth. The Mac chrome does not own a palette — it derives the sidebar, the
 * toolbar, and its text from the terminal theme the user picked, so the seam
 * between chrome and terminal never shows and the two cannot drift apart.
 *
 * The first cut of this client did the opposite: a second palette of hardcoded
 * greys (`#141414`, `#1b1b1b`, `#2a2a2a`) sitting next to a canvas painted from
 * `buildPalette()`. Two palettes, one screen — so the chrome clashed with the
 * terminal at every theme, and a future theme would have had to be defined
 * twice. That is the same class of mistake as resolving colour host-side: a
 * value invented where it should have been derived.
 *
 * The numbers below are lifted from ChromeTheme.swift deliberately, comments
 * and all, so a reader can diff the two and see they agree.
 */

import type { Palette, Rgb } from "../renderer/types";

const clamp = (value: number) => Math.max(0, Math.min(255, Math.round(value)));

const css = (color: Rgb) => `rgb(${color.r} ${color.g} ${color.b})`;

const rgba = (color: Rgb, alpha: number) =>
  `rgb(${color.r} ${color.g} ${color.b} / ${alpha})`;

/** Mix `color` toward `toward` by `amount`, the Swift `blended(with:amount:)`. */
function blend(color: Rgb, toward: Rgb, amount: number): Rgb {
  return {
    r: clamp(color.r + (toward.r - color.r) * amount),
    g: clamp(color.g + (toward.g - color.g) * amount),
    b: clamp(color.b + (toward.b - color.b) * amount),
  };
}

/** WCAG relative luminance — used only to pick between two candidate accents. */
function luminance({ r, g, b }: Rgb): number {
  const channel = (value: number) => {
    const v = value / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

function contrast(a: Rgb, b: Rgb): number {
  const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (high + 0.05) / (low + 0.05);
}

const WHITE: Rgb = { r: 255, g: 255, b: 255 };
const BLACK: Rgb = { r: 0, g: 0, b: 0 };

/**
 * A theme reads as dark when its background is darker than its foreground.
 * Cheaper and more honest than a luminance threshold, which mislabels the
 * mid-grey themes.
 */
export function isDarkPalette(palette: Palette): boolean {
  return luminance(palette.background) < luminance(palette.foreground);
}

/**
 * The CSS custom properties the stylesheet consumes. Every one is a function of
 * the palette; none is a literal.
 */
export function chromeTokens(palette: Palette): Record<string, string> {
  const dark = isDarkPalette(palette);
  const { background, foreground } = palette;

  // Lift the sidebar a touch off the terminal background — lighter in a dark
  // theme, darker in a light one, like VSCode's activity bar.
  const panel = blend(background, dark ? WHITE : BLACK, dark ? 0.06 : 0.04);
  // A second, smaller step for anything that sits on the panel (buttons).
  const raised = blend(panel, dark ? WHITE : BLACK, dark ? 0.05 : 0.035);

  // One alpha for both brightnesses is too thin over a light panel, so only the
  // light side is lifted — muted chrome text needs 3.0 contrast and the dark
  // themes already clear it at 0.6.
  const secondaryAlpha = dark ? 0.6 : 0.75;

  // The active row reads as accent-tinted, and a theme whose ANSI blue is too
  // deep to survive its own background must use its bright blue instead: take
  // whichever of palette 4 and 12 contrasts the background more.
  const accent =
    contrast(palette.ansi[12], background) > contrast(palette.ansi[4], background)
      ? palette.ansi[12]
      : palette.ansi[4];

  return {
    "--bg": css(background),
    "--panel": css(panel),
    "--raised": css(raised),
    // Hairlines are ink at low alpha, never a fixed grey: a fixed line goes
    // invisible on a dark theme and turns into a black bar on a light one.
    "--line": rgba(dark ? WHITE : BLACK, dark ? 0.09 : 0.08),
    "--line-strong": rgba(dark ? WHITE : BLACK, dark ? 0.16 : 0.14),
    "--text": css(foreground),
    "--muted": rgba(foreground, secondaryAlpha),
    "--faint": rgba(foreground, dark ? 0.38 : 0.5),
    "--accent": css(accent),
    "--accent-soft": rgba(accent, dark ? 0.18 : 0.14),
    // Hover and selection are ink over the panel, so they hold at any theme.
    "--hover": rgba(dark ? WHITE : BLACK, dark ? 0.06 : 0.045),
    // Translucent chrome. The terminal scrolls under the toolbar rather than
    // being walled off by it, which is what makes the app read as one surface.
    "--material": rgba(panel, dark ? 0.72 : 0.68),
    "--shadow": dark ? "0 1px 3px rgb(0 0 0 / 0.5)" : "0 1px 3px rgb(0 0 0 / 0.12)",
    "--scheme": dark ? "dark" : "light",
    // Status dots come from the terminal palette too, so a theme's green is the
    // green you see in the sidebar.
    "--status-working": css(accent),
    "--status-needs-you": css(palette.ansi[3]),
    "--status-done": css(palette.ansi[2]),
    "--status-failed": css(palette.ansi[1]),
    "--status-dead": rgba(foreground, 0.25),
  };
}
