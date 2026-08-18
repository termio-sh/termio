import { describe, expect, it } from "vitest";

import { buildLayouts, buildManifest } from "./__fixtures__/layout";
import { extractBits, ManifestError, TypeManifest } from "./typeJson";

const manifestJson = buildManifest(buildLayouts());

describe("TypeManifest", () => {
  it("reads struct offsets and enum values by name", () => {
    const manifest = TypeManifest.parse(manifestJson);
    expect(manifest.field("GhosttyStyle", "size").offset).toBe(0);
    expect(manifest.field("GhosttyStyle", "fg_color").offset).toBe(8);
    expect(manifest.enumValue("GhosttyStyleColorTag", "PALETTE")).toBe(1);
    expect(manifest.enumValue("GhosttyRenderStateRowData", "CELLS_RAW")).toBe(5);
  });

  it("describes the packed cell as bit fields, including the tagged union", () => {
    const manifest = TypeManifest.parse(manifestJson);
    const cell = manifest.packed("GhosttyCell");
    expect(cell.underlying).toBe("u64");
    const content = cell.bits["content"];
    expect(content?.kind).toBe("union");
    if (content?.kind !== "union") throw new Error("content is not a union");
    expect(content.tag).toBe("content_tag");
    expect(content.arms["BG_COLOR_RGB"]?.bits["g"]).toEqual({
      kind: "scalar",
      lsb: 8,
      width: 8,
      type: "u8",
    });
  });

  it("refuses a 64-bit manifest rather than reading every struct at the wrong offset", () => {
    const wide = JSON.parse(manifestJson) as { abi: Record<string, unknown> };
    wide.abi["pointer_size"] = 8;
    wide.abi["usize_size"] = 8;
    const manifest = TypeManifest.parse(JSON.stringify(wide));
    expect(() => manifest.assertWasm32LittleEndian()).toThrow(ManifestError);
  });

  it("refuses a big-endian manifest", () => {
    const swapped = JSON.parse(manifestJson) as { abi: Record<string, unknown> };
    swapped.abi["endian"] = "big";
    const manifest = TypeManifest.parse(JSON.stringify(swapped));
    expect(() => manifest.assertWasm32LittleEndian()).toThrow(ManifestError);
  });

  it("names the missing type when the Wasm is from another commit", () => {
    const stripped = JSON.parse(manifestJson) as {
      types: Record<string, unknown>;
    };
    delete stripped.types["GhosttyStyle"];
    const manifest = TypeManifest.parse(JSON.stringify(stripped));
    expect(() => manifest.struct("GhosttyStyle")).toThrow(/GhosttyStyle/);
  });

  it("rejects a schema it does not know", () => {
    expect(() => TypeManifest.parse(JSON.stringify({ schema: 2 }))).toThrow(
      ManifestError,
    );
  });
});

describe("extractBits", () => {
  it("reads a field that sits entirely in the low half", () => {
    expect(extractBits(0b1101, 0, 0, 2)).toBe(0b01);
    expect(extractBits(0b1101, 0, 2, 2)).toBe(0b11);
  });

  it("reads a field that straddles the two halves", () => {
    // style_id is 16 bits at lsb 26: 6 bits in `low`, 10 in `high`.
    const low = 0b1111_1100_0000_0000_0000_0000_0000_0000 >>> 0;
    const high = 0b11 >>> 0;
    // 6 low bits set (63) plus 2 high bits at weight 64 → 63 + 192.
    expect(extractBits(low, high, 26, 16)).toBe(255);
  });

  it("reads a field that sits entirely in the high half", () => {
    expect(extractBits(0, 0b1100, 34, 2)).toBe(0b11);
  });
});
