import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const here = dirname(fileURLToPath(import.meta.url));

function bindingSources(): { name: string; source: string }[] {
  return readdirSync(here)
    .filter((name) => name.endsWith(".ts") && !name.endsWith(".test.ts"))
    .map((name) => ({ name, source: readFileSync(join(here, name), "utf8") }));
}

describe("presentation boundary", () => {
  /**
   * The failure that disqualified ghostty-web and `@wterm/ghostty`, as a
   * reviewable line in a diff.
   *
   * `…_ROW_CELLS_DATA_FG_COLOR` and `…_DATA_BG_COLOR` resolve palette indices
   * through the palette — render.h's own doc comment says so. That resolution
   * belongs to the viewer's theme, in the renderer, and a cell that arrives
   * pre-resolved can never be re-themed without a reload. The fixture answers
   * both with INVALID_VALUE, and this test keeps them out of the source in the
   * first place.
   */
  it("never names the resolved-colour reads", () => {
    for (const { name, source } of bindingSources()) {
      // The quoted form is how a manifest lookup would name them; prose about
      // why they are forbidden uses backticks and is what this file wants to
      // keep.
      expect(source, `${name} reads a resolved colour`).not.toMatch(/"FG_COLOR"/);
      expect(source, `${name} reads a resolved colour`).not.toMatch(/"BG_COLOR"/);
      // The cell's own BG_COLOR_PALETTE tag is a slot and is fine; the render
      // state's COLOR_PALETTE and its COLORS struct carry the engine's
      // palette[256] and are not.
      expect(source, `${name} reads the engine palette`).not.toMatch(
        /"COLOR_PALETTE"/,
      );
      expect(source, `${name} reads the engine colour block`).not.toMatch(
        /"COLORS"/,
      );
    }
  });

  /**
   * The other half of the same trap: handing a palette to the terminal at
   * construction and treating what comes back as the client's colours. The
   * viewer's Palette goes to the RENDERER; the Wasm never sees one.
   */
  it("never sets a palette or a default colour on the terminal", () => {
    for (const { name, source } of bindingSources()) {
      expect(source, `${name} configures engine colours`).not.toMatch(
        /ghostty_terminal_set\(\s*[^)]*COLOR/,
      );
    }
  });
});
