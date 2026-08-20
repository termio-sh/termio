import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

/**
 * The seam's rules are review rules, so they are asserted on the source rather
 * than on behaviour. A renderer that reads a host-resolved colour, imports
 * React, or grows a timer of its own still passes every pixel test; it just
 * stops being swappable for a WebGPU implementation.
 */
const here = dirname(fileURLToPath(import.meta.url));

/**
 * Comments are stripped first: the seam file *names* the forbidden accessors
 * in the prohibition itself, and a guard that cannot tell a rule from a call
 * would forbid writing the rule down.
 */
function withoutComments(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
}

function sources(): Array<{ name: string; text: string }> {
  return readdirSync(here)
    .filter((name) => name.endsWith(".ts") && !name.endsWith(".test.ts"))
    .map((name) => ({ name, text: withoutComments(readFileSync(join(here, name), "utf8")) }));
}

describe("renderer seam", () => {
  it("ships types.ts and canvas2d.ts and nothing that is not a renderer", () => {
    expect(sources().map((file) => file.name).sort()).toEqual(["canvas2d.ts", "types.ts"]);
  });

  it("never reads a host-resolved colour", () => {
    for (const file of sources()) {
      // `…_ROW_CELLS_DATA_STYLE` is the unresolved slot; the FG/BG accessors
      // flatten palette indices through someone else's palette, which is the
      // resolution this boundary exists to prevent.
      expect(file.text, file.name).not.toMatch(/DATA_FG_COLOR|DATA_BG_COLOR/);
    }
  });

  it("owns no socket, no Wasm handle, no React and no timer", () => {
    for (const file of sources()) {
      expect(file.text, file.name).not.toMatch(/\bWebSocket\b/);
      expect(file.text, file.name).not.toMatch(/\bWebAssembly\b/);
      expect(file.text, file.name).not.toMatch(/requestAnimationFrame|setInterval|setTimeout/);
      expect(file.text, file.name).not.toMatch(/from "react/);
    }
  });

  it("imports nothing across a module boundary except types", () => {
    for (const file of sources()) {
      const imports = file.text.matchAll(/^import\s+(type\s+)?[^;]*?from\s+"([^"]+)";/gm);
      for (const match of imports) {
        const isTypeOnly = match[1] !== undefined;
        const specifier = match[2];
        const local = specifier.startsWith("./");
        expect(local || isTypeOnly, `${file.name} imports ${specifier} as a value`).toBe(true);
      }
    }
  });
});
