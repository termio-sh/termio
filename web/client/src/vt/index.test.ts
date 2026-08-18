import { describe, expect, it } from "vitest";

import { createFakeGhostty } from "./__fixtures__/fakeGhostty";
import { buildLayouts, buildManifest } from "./__fixtures__/layout";
import type { GhosttyExports } from "./exports";
import { bindingFromExports, instantiate, VtLoadError } from "./index";

describe("bindingFromExports", () => {
  it("names the export that is missing rather than failing later at a call", () => {
    const fake = createFakeGhostty();
    const exports = { ...fake.exports } as Record<string, unknown>;
    delete exports["ghostty_render_state_row_cells_select"];
    expect(() => bindingFromExports(exports as unknown as GhosttyExports)).toThrow(
      /ghostty_render_state_row_cells_select/,
    );
  });

  it("refuses a Wasm whose ABI is not the one this client was built against", () => {
    const fake = createFakeGhostty();
    const wrong = JSON.parse(buildManifest(buildLayouts())) as {
      abi: Record<string, unknown>;
    };
    wrong.abi["pointer_size"] = 8;
    const json = JSON.stringify(wrong);

    // Republish the manifest through the same export the binding reads.
    const bytes = new TextEncoder().encode(json);
    const pointer = fake.exports.ghostty_wasm_alloc(bytes.length + 1);
    new Uint8Array(fake.memory.buffer).set(bytes, pointer);
    const exports: GhosttyExports = {
      ...fake.exports,
      ghostty_type_json: () => pointer,
    };

    expect(() => bindingFromExports(exports)).toThrow(VtLoadError);
  });

  it("carries the empty-state sentence on every load failure", () => {
    const error = new VtLoadError("anything");
    expect(error.userMessage).toBe(
      "Couldn't load the terminal engine. Check that `ghostty-vt.wasm` is served as `application/wasm`.",
    );
  });
});

describe("instantiate", () => {
  it("fails loudly, and as a VtLoadError, when the fetch or the MIME type is wrong", async () => {
    // No fallback to arrayBuffer(): a wrong Content-Type has to surface here
    // rather than as a silent second 400 KB download.
    await expect(
      instantiate({ url: new URL("https://example.invalid/ghostty-vt.wasm") }),
    ).rejects.toBeInstanceOf(VtLoadError);
  });
});
