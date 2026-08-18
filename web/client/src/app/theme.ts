/**
 * The viewer's theme, and the only place in the client that decides what a
 * colour looks like.
 *
 * Every palette here is handed to the *renderer*, never to the Wasm. A cell
 * that says `{tag:"palette", index:4}` is still saying that after this module
 * runs; what changes is which four bytes the renderer paints for it. That is
 * why a theme toggle is one `setPalette` call and not a reload.
 */

import type { Palette, Rgb } from "../renderer/types";

export type ThemeName = "light" | "dark";

const rgb = (r: number, g: number, b: number): Rgb => ({ r, g, b });

/**
 * Indices 0–15 are the theme's own. 16–255 are the xterm cube and grey ramp,
 * which every terminal on earth agrees on and no theme redefines, so they are
 * generated once and shared.
 */
const DARK_BASE: Rgb[] = [
  rgb(0x1c, 0x1c, 0x1c), // black
  rgb(0xe0, 0x5c, 0x59), // red
  rgb(0x76, 0xc0, 0x7a), // green
  rgb(0xd8, 0xb0, 0x5f), // yellow
  rgb(0x64, 0x9d, 0xd8), // blue
  rgb(0xb4, 0x82, 0xd8), // magenta
  rgb(0x5f, 0xbd, 0xbd), // cyan
  rgb(0xc9, 0xc9, 0xc9), // white
  rgb(0x5c, 0x5c, 0x5c), // bright black
  rgb(0xff, 0x78, 0x75),
  rgb(0x92, 0xdd, 0x96),
  rgb(0xf2, 0xcb, 0x77),
  rgb(0x80, 0xb8, 0xf2),
  rgb(0xcf, 0x9d, 0xf2),
  rgb(0x7a, 0xd8, 0xd8),
  rgb(0xf2, 0xf2, 0xf2),
];

const LIGHT_BASE: Rgb[] = [
  rgb(0x2b, 0x2b, 0x2b),
  rgb(0xc0, 0x3a, 0x38),
  rgb(0x36, 0x8a, 0x3d),
  rgb(0x9a, 0x72, 0x11),
  rgb(0x2c, 0x66, 0xa8),
  rgb(0x82, 0x4b, 0xa8),
  rgb(0x2b, 0x82, 0x82),
  rgb(0x63, 0x63, 0x63),
  rgb(0x55, 0x55, 0x55),
  rgb(0xd6, 0x4d, 0x4a),
  rgb(0x45, 0xa1, 0x4c),
  rgb(0xb3, 0x88, 0x1c),
  rgb(0x3a, 0x7b, 0xc7),
  rgb(0x99, 0x5f, 0xc7),
  rgb(0x35, 0x9b, 0x9b),
  rgb(0x1a, 0x1a, 0x1a),
];

const CUBE_STEPS = [0, 95, 135, 175, 215, 255];

function extendedRamp(): Rgb[] {
  const out: Rgb[] = [];
  for (let r = 0; r < 6; r += 1) {
    for (let g = 0; g < 6; g += 1) {
      for (let b = 0; b < 6; b += 1) {
        out.push(rgb(CUBE_STEPS[r] ?? 0, CUBE_STEPS[g] ?? 0, CUBE_STEPS[b] ?? 0));
      }
    }
  }
  for (let step = 0; step < 24; step += 1) {
    const level = 8 + step * 10;
    out.push(rgb(level, level, level));
  }
  return out;
}

const EXTENDED = extendedRamp();

const THEMES: Record<ThemeName, { background: Rgb; foreground: Rgb; cursor: Rgb; base: Rgb[] }> = {
  dark: {
    background: rgb(0x14, 0x14, 0x14),
    foreground: rgb(0xd8, 0xd8, 0xd8),
    cursor: rgb(0xd8, 0xd8, 0xd8),
    base: DARK_BASE,
  },
  light: {
    background: rgb(0xfb, 0xfb, 0xfb),
    foreground: rgb(0x1f, 0x1f, 0x1f),
    cursor: rgb(0x1f, 0x1f, 0x1f),
    base: LIGHT_BASE,
  },
};

/** Exactly 256 entries. The renderer throws on a short one, and it is right to. */
export function buildPalette(theme: ThemeName): Palette {
  const spec = THEMES[theme];
  return {
    background: spec.background,
    foreground: spec.foreground,
    cursor: spec.cursor,
    ansi: [...spec.base, ...EXTENDED],
  };
}

export function preferredTheme(): ThemeName {
  const query =
    typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: light)") : null;
  return query?.matches ? "light" : "dark";
}
