import { describe, expect, it } from "vitest";
import { DEFAULT_COLOR, decodeColor } from "./colors";
import { ProtocolError } from "./errors";
import {
  MAX_HISTORY_FRAME_SIZE,
  SNAPSHOT_CELL_SIZE,
  decodeHistoryPayload,
  decodeSnapshotPayload,
} from "./payloads";
import {
  cell,
  encodeHistoryPayload,
  encodeSnapshotCellsPayload,
  encodeSnapshotVtPayload,
} from "./testTranscript";

describe("decodeColor", () => {
  it("keeps a palette index unresolved", () => {
    const bytes = new Uint8Array([1, 42, 0, 0]);
    expect(decodeColor(bytes, 0)).toEqual({ tag: "palette", index: 42 });
  });

  it("reads an rgb triple", () => {
    const bytes = new Uint8Array([2, 0x11, 0x22, 0x33]);
    expect(decodeColor(bytes, 0)).toEqual({
      tag: "rgb",
      r: 0x11,
      g: 0x22,
      b: 0x33,
    });
  });

  it("falls back to default on an unknown tag instead of failing the frame", () => {
    expect(decodeColor(new Uint8Array([9, 1, 2, 3]), 0)).toBe(DEFAULT_COLOR);
    expect(decodeColor(new Uint8Array([0, 0, 0, 0]), 0)).toBe(DEFAULT_COLOR);
  });

  it("reads at an offset", () => {
    const bytes = new Uint8Array([0, 0, 0, 0, 1, 7, 0, 0]);
    expect(decodeColor(bytes, 4)).toEqual({ tag: "palette", index: 7 });
  });
});

describe("decodeSnapshotPayload — v2 VT", () => {
  const vt = new TextEncoder().encode("[2J[H$ ");

  it("returns the VT body and nothing around it", () => {
    const snapshot = decodeSnapshotPayload(
      encodeSnapshotVtPayload(
        {
          rows: 24,
          cols: 80,
          cursorX: 2,
          cursorY: 0,
          altScreen: false,
          title: "zsh — termio",
        },
        vt,
      ),
    );
    expect(snapshot.format).toBe(2);
    expect(snapshot.rows).toBe(24);
    expect(snapshot.cols).toBe(80);
    expect(snapshot.cursorX).toBe(2);
    expect(snapshot.cursorY).toBe(0);
    expect(snapshot.altScreen).toBe(false);
    expect(snapshot.title).toBe("zsh — termio");
    expect(snapshot.cells).toBeUndefined();
    // Exactly the VT bytes: no header, no title, no length prefix, no
    // client-side ESC[2J ESC[H prelude.
    expect(snapshot.vt).toEqual(vt);
  });

  it("copies the VT out of the frame buffer", () => {
    const payload = encodeSnapshotVtPayload({ rows: 1, cols: 1 }, vt);
    const snapshot = decodeSnapshotPayload(payload);
    payload.fill(0);
    expect(snapshot.vt).toEqual(vt);
  });

  it("reads the alt-screen flag", () => {
    const snapshot = decodeSnapshotPayload(
      encodeSnapshotVtPayload({ rows: 1, cols: 1, altScreen: true }, vt),
    );
    expect(snapshot.altScreen).toBe(true);
  });

  it("refuses a vt length that disagrees with the body", () => {
    const payload = encodeSnapshotVtPayload({ rows: 1, cols: 1 }, vt);
    payload[payload.length - vt.length - 1] += 1;
    expect(() => decodeSnapshotPayload(payload)).toThrow(/expected/);
  });
});

describe("decodeSnapshotPayload — v3 packed cells", () => {
  it("decodes tagged colours without resolving them", () => {
    const cells = [
      cell({ codepoint: 0x68, foreground: { tag: "palette", index: 4 } }),
      cell({
        codepoint: 0x69,
        background: { tag: "rgb", r: 1, g: 2, b: 3 },
        attributes: 0b101,
      }),
    ];
    const snapshot = decodeSnapshotPayload(
      encodeSnapshotCellsPayload({ rows: 1, cols: 2, title: "t" }, cells),
    );
    expect(snapshot.format).toBe(3);
    expect(snapshot.vt).toBeUndefined();
    expect(snapshot.cells?.length).toBe(2);
    expect(snapshot.cells?.[0]).toEqual({
      codepoint: 0x68,
      foreground: { tag: "palette", index: 4 },
      background: DEFAULT_COLOR,
      attributes: 0,
      selected: false,
    });
    expect(snapshot.cells?.[1]).toEqual({
      codepoint: 0x69,
      foreground: DEFAULT_COLOR,
      background: { tag: "rgb", r: 1, g: 2, b: 3 },
      attributes: 0b101,
      selected: false,
    });
  });

  it("carries no grapheme or underline field on a packed cell", () => {
    const snapshot = decodeSnapshotPayload(
      encodeSnapshotCellsPayload({ rows: 1, cols: 1 }, [cell()]),
    );
    expect(snapshot.cells?.[0] && "grapheme" in snapshot.cells[0]).toBe(false);
    expect(snapshot.cells?.[0] && "underline" in snapshot.cells[0]).toBe(false);
  });

  it("refuses a cell count that disagrees with rows × cols", () => {
    const payload = encodeSnapshotCellsPayload({ rows: 2, cols: 2 }, [
      cell(),
      cell(),
    ]);
    expect(() => decodeSnapshotPayload(payload)).toThrow(/expected/);
  });
});

describe("decodeSnapshotPayload — malformed", () => {
  it("rejects a short header", () => {
    expect(() => decodeSnapshotPayload(new Uint8Array(11))).toThrow(
      /malformed snapshot header/,
    );
  });

  it("rejects an unsupported version byte", () => {
    const payload = encodeSnapshotCellsPayload({ rows: 0, cols: 0 }, []);
    payload[0] = 1; // v1 was retired rather than kept for compatibility.
    expect(() => decodeSnapshotPayload(payload)).toThrow(
      /unsupported snapshot payload version 1/,
    );
  });

  it("rejects an alt-screen byte that is not 0 or 1", () => {
    const payload = encodeSnapshotCellsPayload({ rows: 0, cols: 0 }, []);
    payload[9] = 2;
    expect(() => decodeSnapshotPayload(payload)).toThrow(/alt-screen/);
  });

  it("rejects a title that runs past the payload", () => {
    const payload = encodeSnapshotCellsPayload({ rows: 0, cols: 0 }, []);
    payload[10] = 0xff;
    expect(() => decodeSnapshotPayload(payload)).toThrow(/title exceeds/);
  });

  it("rejects a title that is not UTF-8", () => {
    const payload = encodeSnapshotVtPayload(
      { rows: 1, cols: 1, title: "ab" },
      new Uint8Array(0),
    );
    payload[12] = 0xff;
    expect(() => decodeSnapshotPayload(payload)).toThrow(/not UTF-8/);
  });
});

describe("decodeHistoryPayload", () => {
  it("orders rows newest first with negative viewport y", () => {
    const cols = 2;
    const rows = [
      [cell({ codepoint: 0x61 }), cell({ codepoint: 0x62 })], // newest
      [cell({ codepoint: 0x63 }), cell({ codepoint: 0x64 })],
      [cell({ codepoint: 0x65 }), cell({ codepoint: 0x66 })], // oldest
    ];
    // `first_offset` is one-based on the wire: the host's first chunk carries 1
    // and means "starting one row above the viewport".
    const chunk = decodeHistoryPayload(
      encodeHistoryPayload(cols, 1, rows.length, rows.flat()),
    );
    expect(chunk.cols).toBe(2);
    expect(chunk.firstOffset).toBe(1);
    expect(chunk.rowCount).toBe(3);
    expect(chunk.rows.map((row) => row.y)).toEqual([-1, -2, -3]);
    expect(chunk.rows[0].cells.map((c) => c.codepoint)).toEqual([0x61, 0x62]);
    expect(chunk.rows[2].cells.map((c) => c.codepoint)).toEqual([0x65, 0x66]);
  });

  it("offsets y by first_offset so a second chunk stacks above the first", () => {
    // A 3-row first chunk (first_offset 1) is followed by first_offset 4.
    const chunk = decodeHistoryPayload(
      encodeHistoryPayload(1, 4, 2, [cell(), cell()]),
    );
    expect(chunk.rows.map((row) => row.y)).toEqual([-4, -5]);
  });

  it("keeps history colours as slots", () => {
    const chunk = decodeHistoryPayload(
      encodeHistoryPayload(1, 0, 1, [
        cell({
          codepoint: 0x7a,
          foreground: { tag: "palette", index: 200 },
          background: { tag: "rgb", r: 9, g: 8, b: 7 },
        }),
      ]),
    );
    expect(chunk.rows[0].cells[0].foreground).toEqual({
      tag: "palette",
      index: 200,
    });
    expect(chunk.rows[0].cells[0].background).toEqual({
      tag: "rgb",
      r: 9,
      g: 8,
      b: 7,
    });
  });

  it("marks decoded history rows dirty and unselected", () => {
    const chunk = decodeHistoryPayload(
      encodeHistoryPayload(1, 0, 1, [cell()]),
    );
    expect(chunk.rows[0].dirty).toBe(true);
    expect(chunk.rows[0].selection).toBeUndefined();
    expect(chunk.rows[0].cells[0].selected).toBe(false);
  });

  it("rejects a short header", () => {
    expect(() => decodeHistoryPayload(new Uint8Array(8))).toThrow(
      /malformed history header/,
    );
  });

  it("rejects an unsupported version", () => {
    const payload = encodeHistoryPayload(1, 0, 1, [cell()]);
    payload[0] = 1;
    expect(() => decodeHistoryPayload(payload)).toThrow(
      /unsupported history payload version 1/,
    );
  });

  it("rejects zero rows or columns", () => {
    const payload = encodeHistoryPayload(1, 0, 1, [cell()]);
    payload[7] = 0;
    payload[8] = 0;
    expect(() => decodeHistoryPayload(payload)).toThrow(/non-zero/);
  });

  it("rejects a cell count that disagrees with the header", () => {
    const payload = encodeHistoryPayload(2, 0, 1, [cell(), cell()]);
    expect(() => decodeHistoryPayload(payload.subarray(0, payload.length - 1))).toThrow(
      /expected/,
    );
  });

  it("rejects a payload over the 64 KiB history cap", () => {
    const payload = new Uint8Array(MAX_HISTORY_FRAME_SIZE + 1);
    payload[0] = 2;
    expect(() => decodeHistoryPayload(payload)).toThrow(ProtocolError);
  });

  it("uses the same 16-byte cell as the snapshot", () => {
    expect(SNAPSHOT_CELL_SIZE).toBe(16);
    const payload = encodeHistoryPayload(1, 0, 1, [cell()]);
    expect(payload.length).toBe(9 + SNAPSHOT_CELL_SIZE);
  });
});
