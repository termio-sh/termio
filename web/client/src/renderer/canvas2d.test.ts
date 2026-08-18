import { describe, expect, it } from "vitest";

import { createCanvas2dRenderer } from "./canvas2d";
import { ATTR } from "./types";
import type {
  CellView,
  CursorState,
  FontSpec,
  Geometry,
  Palette,
  RenderFrame,
  Rgb,
  RowView,
  TaggedColor,
  TerminalRenderer,
  RendererStats,
} from "./types";

/**
 * The renderer only ever touches the canvas it was handed, so a recording
 * context is a complete stand-in — no jsdom, no `canvas` native module, and the
 * assertions are about the draw calls rather than about pixels.
 */
type Op =
  | { op: "fillRect"; x: number; y: number; w: number; h: number; fill: string }
  | { op: "fillText"; text: string; x: number; y: number; fill: string; font: string; alpha: number }
  | { op: "strokeRect"; x: number; y: number; w: number; h: number; stroke: string }
  | { op: "stroke"; stroke: string }
  | { op: "setTransform"; scaleX: number; scaleY: number };

const CELL_ADVANCE = 8;

class RecordingContext {
  ops: Op[] = [];
  fillStyle = "";
  strokeStyle = "";
  font = "";
  globalAlpha = 1;
  lineWidth = 1;
  textBaseline = "alphabetic";
  letterSpacing = "0px";

  setTransform(a: number, _b: number, _c: number, d: number, _e: number, _f: number): void {
    this.ops.push({ op: "setTransform", scaleX: a, scaleY: d });
  }

  fillRect(x: number, y: number, w: number, h: number): void {
    this.ops.push({ op: "fillRect", x, y, w, h, fill: this.fillStyle });
  }

  strokeRect(x: number, y: number, w: number, h: number): void {
    this.ops.push({ op: "strokeRect", x, y, w, h, stroke: this.strokeStyle });
  }

  fillText(text: string, x: number, y: number): void {
    this.ops.push({ op: "fillText", text, x, y, fill: this.fillStyle, font: this.font, alpha: this.globalAlpha });
  }

  measureText(text: string): {
    width: number;
    fontBoundingBoxAscent: number;
    fontBoundingBoxDescent: number;
  } {
    return {
      width: text.length * CELL_ADVANCE,
      fontBoundingBoxAscent: 8,
      fontBoundingBoxDescent: 2,
    };
  }

  beginPath(): void {}
  moveTo(): void {}
  lineTo(): void {}
  stroke(): void {
    this.ops.push({ op: "stroke", stroke: this.strokeStyle });
  }
}

interface Harness {
  renderer: TerminalRenderer & { stats(): RendererStats };
  context: RecordingContext;
  canvas: { width: number; height: number; style: { width: string; height: string } };
}

const FONT: FontSpec = {
  family: "monospace",
  sizePx: 10,
  weightNormal: 400,
  weightBold: 700,
  lineHeight: 1.2,
};

const CELL = { widthPx: CELL_ADVANCE, heightPx: 12, baselinePx: 9 };

function harness(geometry?: Partial<Geometry>): Harness {
  const context = new RecordingContext();
  const canvas = {
    width: 0,
    height: 0,
    style: { width: "", height: "" },
    getContext: () => context,
  };
  const renderer = createCanvas2dRenderer(canvas as unknown as HTMLCanvasElement, FONT);
  if (!renderer) throw new Error("canvas2d factory returned null");
  renderer.setGeometry({
    cols: 4,
    rows: 3,
    cell: CELL,
    devicePixelRatio: 1,
    ...geometry,
  });
  return { renderer, context, canvas };
}

function rgb(r: number, g: number, b: number): Rgb {
  return { r, g, b };
}

function palette(background: Rgb, foreground: Rgb, ansiFill: Rgb): Palette {
  return {
    background,
    foreground,
    ansi: Array.from({ length: 256 }, () => ansiFill),
  };
}

const DEFAULT: TaggedColor = { tag: "default" };

interface CellOverrides {
  fg?: TaggedColor;
  bg?: TaggedColor;
  underline?: TaggedColor;
  attributes?: number;
  selected?: boolean;
  grapheme?: string;
}

function cell(text: string, over: CellOverrides = {}): CellView {
  const view: CellView = {
    codepoint: text === "" ? 0 : (text.codePointAt(0) ?? 0),
    foreground: over.fg ?? DEFAULT,
    background: over.bg ?? DEFAULT,
    attributes: over.attributes ?? 0,
    selected: over.selected ?? false,
  };
  if (over.grapheme !== undefined) view.grapheme = over.grapheme;
  if (over.underline !== undefined) view.underline = over.underline;
  return view;
}

function row(y: number, cells: CellView[], options: { dirty?: boolean; selection?: { start: number; end: number } } = {}): RowView {
  const view: RowView = { y, dirty: options.dirty ?? true, cells };
  if (options.selection) view.selection = options.selection;
  return view;
}

const NO_CURSOR: CursorState = {
  hasValue: false,
  x: 0,
  y: 0,
  visible: false,
  blinking: false,
  passwordInput: false,
  wideTail: false,
  style: "block",
};

function frame(rows: RowView[], options: Partial<RenderFrame> = {}): RenderFrame {
  return {
    dirty: "full",
    cols: 4,
    rows: 3,
    cursor: NO_CURSOR,
    rows_: rows,
    overrides: {},
    scrollOffsetRows: 0,
    ...options,
  };
}

function texts(ops: Op[]): Array<{ text: string; x: number; y: number; fill: string; font: string; alpha: number }> {
  const found: Array<{ text: string; x: number; y: number; fill: string; font: string; alpha: number }> = [];
  for (const op of ops) if (op.op === "fillText") found.push(op);
  return found;
}

function rects(ops: Op[]): Array<{ x: number; y: number; w: number; h: number; fill: string }> {
  const found: Array<{ x: number; y: number; w: number; h: number; fill: string }> = [];
  for (const op of ops) if (op.op === "fillRect") found.push(op);
  return found;
}

describe("canvas2d renderer", () => {
  it("paints a default-slot cell in the viewer's colours, never black", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0x10, 0x18, 0x20), rgb(0xf0, 0xf0, 0xf0), rgb(0, 0, 0)));
    context.ops = [];

    renderer.draw(frame([row(0, [cell("A")])]));

    const background = rects(context.ops)[0];
    expect(background.fill).toBe("#101820");
    const glyph = texts(context.ops).find((op) => op.text === "A");
    expect(glyph?.fill).toBe("#f0f0f0");
  });

  it("resolves a palette index through the viewer's palette, and re-resolves it on setPalette", () => {
    const { renderer, context } = harness();
    const light = palette(rgb(0xff, 0xff, 0xff), rgb(0x20, 0x20, 0x20), rgb(0xaa, 0x00, 0x00));
    renderer.setPalette(light);
    const cells = [cell("x", { fg: { tag: "palette", index: 1 } })];

    context.ops = [];
    renderer.draw(frame([row(0, cells)]));
    expect(texts(context.ops).find((op) => op.text === "x")?.fill).toBe("#aa0000");

    // The theme switch: the same cells, no reload, no remount, no new frame
    // from the VT — and every visible cell comes back in the new palette.
    const dark = palette(rgb(0x00, 0x00, 0x00), rgb(0xdd, 0xdd, 0xdd), rgb(0x00, 0x88, 0xff));
    renderer.setPalette(dark);
    context.ops = [];
    renderer.draw(frame([row(0, cells, { dirty: false })], { dirty: "none" }));

    expect(texts(context.ops).find((op) => op.text === "x")?.fill).toBe("#0088ff");
    expect(rects(context.ops)[0].fill).toBe("#000000");
  });

  it("honours program colour overrides without touching the viewer's palette", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0x10, 0x10, 0x10), rgb(0xee, 0xee, 0xee), rgb(0, 0, 0)));
    context.ops = [];

    renderer.draw(
      frame([row(0, [cell("A")])], {
        overrides: { background: rgb(0x33, 0x22, 0x11), foreground: rgb(0x01, 0x02, 0x03) },
      }),
    );

    expect(rects(context.ops)[0].fill).toBe("#332211");
    expect(texts(context.ops).find((op) => op.text === "A")?.fill).toBe("#010203");
  });

  it("repaints only damaged rows and their neighbours on a partial frame", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    const rows = [
      row(0, [cell("a")], { dirty: false }),
      row(1, [cell("b")], { dirty: false }),
      row(2, [cell("c")], { dirty: true }),
    ];
    renderer.draw(frame(rows));

    context.ops = [];
    renderer.draw(frame(rows, { dirty: "partial" }));

    const painted = texts(context.ops).map((op) => op.text);
    expect(painted).toContain("c");
    expect(painted).toContain("b"); // the neighbour, for glyph overflow
    expect(painted).not.toContain("a");
  });

  it("paints history rows above the viewport through the same path", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(frame([row(0, [cell("v")])], { scrollOffsetRows: 1 }), [row(-1, [cell("h")])]);

    const painted = texts(context.ops);
    const history = painted.find((op) => op.text === "h");
    const viewport = painted.find((op) => op.text === "v");
    // -1 + scrollOffsetRows 1 = line 0; 0 + 1 = line 1. One arithmetic, both
    // row sources.
    expect(history?.y).toBe(CELL.baselinePx);
    expect(viewport?.y).toBe(CELL.heightPx + CELL.baselinePx);
  });

  it("draws no glyph for a wide spacer but still paints its background", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(
      frame([
        row(0, [
          cell("あ", { attributes: ATTR.WIDE }),
          cell("", { attributes: ATTR.WIDE_SPACER, bg: { tag: "rgb", r: 0x12, g: 0x34, b: 0x56 } }),
        ]),
      ]),
    );

    expect(texts(context.ops).map((op) => op.text)).toEqual(["あ"]);
    const spacer = rects(context.ops).find((op) => op.fill === "#123456");
    expect(spacer).toBeDefined();
    expect(spacer?.x).toBe(CELL.widthPx);
  });

  it("swaps foreground and background for a selected span", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0x00, 0x00, 0x00), rgb(0xff, 0xff, 0xff), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(frame([row(0, [cell("a"), cell("b")], { selection: { start: 1, end: 2 } })]));

    const selectedBackground = rects(context.ops).find((op) => op.fill === "#ffffff" && op.x === CELL.widthPx);
    expect(selectedBackground).toBeDefined();
    expect(texts(context.ops).find((op) => op.text === "b")?.fill).toBe("#000000");
    expect(texts(context.ops).find((op) => op.text === "a")?.fill).toBe("#ffffff");
  });

  it("falls back to the per-cell selected flag when the row has no range", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0x00, 0x00, 0x00), rgb(0xff, 0xff, 0xff), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(frame([row(0, [cell("a"), cell("b", { selected: true })])]));

    expect(texts(context.ops).find((op) => op.text === "b")?.fill).toBe("#000000");
  });

  it("sizes the backing store by devicePixelRatio and draws in CSS pixels", () => {
    const { canvas, context } = harness({ devicePixelRatio: 2, cols: 4, rows: 3 });

    expect(canvas.width).toBe(4 * CELL.widthPx * 2);
    expect(canvas.height).toBe(3 * CELL.heightPx * 2);
    expect(canvas.style.width).toBe(`${4 * CELL.widthPx}px`);
    const transform = context.ops.find((op) => op.op === "setTransform");
    expect(transform).toEqual({ op: "setTransform", scaleX: 2, scaleY: 2 });
  });

  it("offsets every row by the geometry padding", () => {
    const { renderer, context } = harness({ padding: { top: 5, left: 7 } });
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(frame([row(0, [cell("A")])]));

    expect(texts(context.ops).find((op) => op.text === "A")?.x).toBe(7);
  });

  it("paints a block cursor over its cell and redraws the glyph in the cell background", () => {
    const { renderer, context } = harness();
    renderer.setPalette({
      background: rgb(0, 0, 0),
      foreground: rgb(0xff, 0xff, 0xff),
      cursor: rgb(0x00, 0xff, 0x00),
      ansi: Array.from({ length: 256 }, () => rgb(1, 1, 1)),
    });
    context.ops = [];

    renderer.draw(
      frame([row(0, [cell("A"), cell("B")])], {
        cursor: { ...NO_CURSOR, hasValue: true, visible: true, x: 1, y: 0 },
      }),
    );

    const cursorRect = rects(context.ops).find((op) => op.fill === "#00ff00");
    expect(cursorRect).toEqual({ op: "fillRect", x: CELL.widthPx, y: 0, w: CELL.widthPx, h: CELL.heightPx, fill: "#00ff00" });
    // The glyph is drawn twice: once in the text pass, once inverted over the
    // cursor block.
    expect(texts(context.ops).filter((op) => op.text === "B" && op.fill === "#000000")).toHaveLength(1);
  });

  it("paints nothing for a cursor that is off the viewport or suppressed", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(0x00, 0xff, 0x00)));

    renderer.draw(frame([row(0, [cell("A")])], { cursor: { ...NO_CURSOR } }));
    context.ops = [];
    renderer.draw(
      frame([row(0, [cell("A")], { dirty: false })], {
        dirty: "none",
        cursor: { ...NO_CURSOR, hasValue: true, visible: true, passwordInput: true },
      }),
    );

    expect(context.ops).toHaveLength(0);
  });

  it("repaints the line the cursor left even when no row is dirty", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    const rows = [row(0, [cell("a")], { dirty: false }), row(1, [cell("b")], { dirty: false }), row(2, [cell("c")], { dirty: false })];
    renderer.draw(frame(rows, { cursor: { ...NO_CURSOR, hasValue: true, visible: true, x: 0, y: 0 } }));

    context.ops = [];
    renderer.draw(
      frame(rows, { dirty: "none", cursor: { ...NO_CURSOR, hasValue: true, visible: true, x: 0, y: 2 } }),
    );

    const painted = texts(context.ops).map((op) => op.text);
    expect(painted).toContain("a"); // the line the cursor left
    expect(painted).toContain("c"); // the line it arrived on
    expect(painted).not.toContain("b");
  });

  it("skips a clean frame entirely", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    renderer.draw(frame([row(0, [cell("A")])]));

    context.ops = [];
    renderer.draw(frame([row(0, [cell("A")], { dirty: false })], { dirty: "none" }));

    expect(context.ops).toHaveLength(0);
  });

  it("forces a full repaint when the view scrolls", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    const rows = [row(0, [cell("a")], { dirty: false }), row(1, [cell("b")], { dirty: false })];
    renderer.draw(frame(rows));

    context.ops = [];
    renderer.draw(frame(rows, { dirty: "none", scrollOffsetRows: 1 }));

    const painted = texts(context.ops).map((op) => op.text);
    expect(painted).toContain("a");
    expect(painted).toContain("b");
  });

  it("carries bold, italic and faint into the glyph draw", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(
      frame([
        row(0, [
          cell("A", { attributes: ATTR.BOLD }),
          cell("B", { attributes: ATTR.ITALIC }),
          cell("C", { attributes: ATTR.FAINT }),
        ]),
      ]),
    );

    const painted = texts(context.ops);
    expect(painted.find((op) => op.text === "A")?.font).toBe("700 10px monospace");
    expect(painted.find((op) => op.text === "B")?.font).toBe("italic 400 10px monospace");
    expect(painted.find((op) => op.text === "C")?.alpha).toBeLessThan(1);
  });

  it("draws an underline in the program's underline colour", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(
      frame([
        row(0, [cell("A", { attributes: ATTR.UNDERLINE, underline: { tag: "rgb", r: 0xff, g: 0x00, b: 0x88 } })]),
      ]),
    );

    const underline = rects(context.ops).find((op) => op.fill === "#ff0088");
    expect(underline).toBeDefined();
    expect(underline?.h).toBeGreaterThan(0);
    expect(underline?.h).toBeLessThan(CELL.heightPx);
  });

  it("groups a same-style ASCII run into one fillText and keeps it on the grid", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(frame([row(0, [cell("a"), cell("b"), cell("c"), cell("d")])]));

    expect(texts(context.ops)).toEqual([
      { op: "fillText", text: "abcd", x: 0, y: CELL.baselinePx, fill: "#ffffff", font: "400 10px monospace", alpha: 1 },
    ]);
  });

  it("stops grouping runs when the layout cell width is not the font's advance", () => {
    // A caller that rounds the measured advance up lays out on a grid the font
    // does not walk on; a whole-run fillText would drift right across the row.
    const { renderer, context } = harness({ cell: { widthPx: CELL_ADVANCE + 1, heightPx: 12, baselinePx: 9 } });
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(frame([row(0, [cell("a"), cell("b")])]));

    expect(texts(context.ops).map((op) => [op.text, op.x])).toEqual([
      ["a", 0],
      ["b", CELL_ADVANCE + 1],
    ]);
  });

  it("breaks a run at a grapheme cluster and draws it at its own column", () => {
    const { renderer, context } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    context.ops = [];

    renderer.draw(frame([row(0, [cell("a"), cell("e", { grapheme: "é" }), cell("b")])]));

    expect(texts(context.ops).map((op) => [op.text, op.x])).toEqual([
      ["a", 0],
      ["é", CELL.widthPx],
      ["b", CELL.widthPx * 2],
    ]);
  });

  it("throws on a palette that is not exactly 256 entries", () => {
    const { renderer } = harness();
    expect(() =>
      renderer.setPalette({
        background: rgb(0, 0, 0),
        foreground: rgb(255, 255, 255),
        ansi: Array.from({ length: 16 }, () => rgb(1, 1, 1)),
      }),
    ).toThrow(/256/);
  });

  it("throws rather than painting before it has been told the palette", () => {
    const { renderer } = harness();
    expect(() => renderer.draw(frame([row(0, [cell("A")])]))).toThrow(/setPalette/);
  });

  it("disposes idempotently and refuses to draw afterwards", () => {
    const { renderer } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    renderer.dispose();
    renderer.dispose();
    expect(() => renderer.draw(frame([row(0, [cell("A")])]))).toThrow(/dispose/);
  });

  it("reports its implementation and counts what it painted", () => {
    const { renderer } = harness();
    renderer.setPalette(palette(rgb(0, 0, 0), rgb(255, 255, 255), rgb(1, 1, 1)));
    renderer.draw(frame([row(0, [cell("A")])]));
    renderer.draw(frame([row(0, [cell("A")], { dirty: true })], { dirty: "partial" }));

    const stats = renderer.stats();
    expect(stats.implementation).toBe("canvas2d");
    expect(stats.framesPainted).toBe(2);
    expect(stats.fullRedraws).toBe(1);
    expect(stats.frameTimeP50Ms).toBeGreaterThanOrEqual(0);
    expect(stats.frameTimeP95Ms).toBeGreaterThanOrEqual(stats.frameTimeP50Ms);
  });

  it("returns null when the canvas has no 2D context", () => {
    const canvas = { getContext: () => null } as unknown as HTMLCanvasElement;
    expect(createCanvas2dRenderer(canvas, FONT)).toBeNull();
  });

  it("measures a cell from the font it is given", () => {
    const { renderer } = harness();
    const metrics = renderer.measure({ ...FONT, sizePx: 20, lineHeight: 1.5 });
    expect(metrics.widthPx).toBe(CELL_ADVANCE);
    expect(metrics.heightPx).toBe(30);
    expect(metrics.baselinePx).toBeGreaterThan(0);
    expect(metrics.baselinePx).toBeLessThanOrEqual(metrics.heightPx);
  });
});
