import { ATTR } from "./types";
import type {
  CellMetrics,
  CellView,
  FontSpec,
  Geometry,
  Palette,
  RenderFrame,
  RendererFactory,
  RendererStats,
  Rgb,
  RowView,
  TaggedColor,
  TerminalRenderer,
} from "./types";

/**
 * Canvas 2D implementation of the `TerminalRenderer` seam.
 *
 * It knows about a canvas, a font, a viewer `Palette`, and the damage it is
 * handed. It has no socket, no Wasm handle, no React import, and no timer of
 * its own: `draw()` is called by the app's rAF loop and never calls back.
 *
 * Colour resolution happens here and nowhere else. A `{tag:"palette"}` cell
 * looks up the *viewer's* `ansi[index]`, so one snapshot painted against a
 * light palette and a dark palette differs, and `setPalette` re-resolves every
 * visible cell with no reload — the presentation boundary that disqualified
 * ghostty-web (pre-resolved RGB cells) and `@wterm` (palette baked into the
 * Wasm at construction).
 *
 * Where it will hurt, said plainly: a full-viewport repaint at large geometry
 * is `cols × rows` worth of glyph drawing, and Canvas 2D text is the slow path
 * in every browser. That is the named cost this renderer accepts and the thing
 * the WebGPU implementation of this same seam is scheduled to fix.
 */

/** One 60 Hz vsync. A paint longer than this dropped a frame. */
const FRAME_BUDGET_MS = 1000 / 60;

/** Frame times kept for the p50 / p95 counters — four seconds at 60 Hz. */
const FRAME_TIME_SAMPLES = 240;

/** FAINT is drawn as reduced alpha; the wire carries no faint colour. */
const FAINT_ALPHA = 0.6;

interface ResolvedDefaults {
  foreground: Rgb;
  background: Rgb;
  cursor: Rgb;
}

interface CursorMark {
  line: number;
  x: number;
  width: number;
}

function now(): number {
  return typeof performance !== "undefined" && typeof performance.now === "function"
    ? performance.now()
    : Date.now();
}

function packRgb(color: Rgb): number {
  return ((color.r & 255) << 16) | ((color.g & 255) << 8) | (color.b & 255);
}

function sameRgb(a: Rgb, b: Rgb): boolean {
  return a.r === b.r && a.g === b.g && a.b === b.b;
}

function fontString(font: FontSpec, bold: boolean, italic: boolean): string {
  const weight = bold ? font.weightBold : font.weightNormal;
  return `${italic ? "italic " : ""}${weight} ${font.sizePx}px ${font.family}`;
}

function finiteOr(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : fallback;
}

/**
 * A cell whose glyph can be drawn as part of a multi-cell `fillText` run.
 *
 * Runs are the difference between one call per cell and one call per style
 * change, but they only stay on the grid while the font's own advance matches
 * the cell width (checked in `measure`) and the text is single-codepoint
 * ASCII. A grapheme cluster, a wide glyph, or a font whose advance drifts is
 * drawn cell by cell, which cannot drift because each cell carries its own x.
 */
function isRunnable(cell: CellView): boolean {
  if (cell.grapheme !== undefined) return false;
  if ((cell.attributes & (ATTR.WIDE | ATTR.WIDE_SPACER)) !== 0) return false;
  return cell.codepoint >= 0x20 && cell.codepoint <= 0x7e;
}

function cellText(cell: CellView): string {
  if (cell.grapheme !== undefined) return cell.grapheme;
  if (cell.codepoint === 0 || cell.codepoint === 0x20) return "";
  return String.fromCodePoint(cell.codepoint);
}

class Canvas2dRenderer implements TerminalRenderer {
  private readonly canvas: HTMLCanvasElement;
  private readonly context: CanvasRenderingContext2D;

  private font: FontSpec;
  private metrics: CellMetrics;
  private geometry: Geometry | null = null;
  private palette: Palette | null = null;

  /** The font's advance matches the cell width, so `fillText` runs stay on grid. */
  private runsStayOnGrid = false;
  /** Per-cell advance measured over a multi-cell sample of the active font. */
  private sampleAdvancePx = 0;

  private needsFullRedraw = true;
  private lastScrollOffsetRows = 0;
  private lastDefaults: ResolvedDefaults | null = null;
  private lastCursor: CursorMark | null = null;

  /** Per-row scratch, sized to `cols` and reused; never handed to a caller. */
  private foregroundScratch: string[] = [];
  private backgroundScratch: string[] = [];

  private readonly colorCache = new Map<number, string>();

  private framesPainted = 0;
  private fullRedraws = 0;
  private droppedFrames = 0;
  private readonly frameTimes: number[] = [];

  private disposed = false;

  constructor(canvas: HTMLCanvasElement, context: CanvasRenderingContext2D, font: FontSpec) {
    this.canvas = canvas;
    this.context = context;
    this.font = font;
    this.metrics = this.measure(font);
  }

  measure(font: FontSpec): CellMetrics {
    const context = this.context;
    this.font = font;
    this.applyLetterSpacing(font);
    context.font = fontString(font, false, false);

    const single = context.measureText("M");
    const spacing = this.letterSpacingIsHonoured() ? 0 : (font.letterSpacingPx ?? 0);
    const widthPx = Math.max(1, finiteOr(single.width, font.sizePx * 0.6) + spacing);

    const ascent = finiteOr(single.fontBoundingBoxAscent, font.sizePx * 0.8);
    const descent = finiteOr(single.fontBoundingBoxDescent, font.sizePx * 0.2);
    const heightPx = Math.max(1, Math.round(font.sizePx * font.lineHeight));
    const baselinePx = Math.min(
      heightPx,
      Math.max(1, Math.round((heightPx - (ascent + descent)) / 2 + ascent)),
    );

    // Eight cells of the same glyph: if the run lands where eight cell widths
    // say it should, whole-run `fillText` is safe. A quarter of a pixel of
    // total drift over eight cells is the tolerance, because drift accumulates
    // across a row and a row can be 200 cells wide.
    const sampleCount = 8;
    const sample = context.measureText("M".repeat(sampleCount));
    this.sampleAdvancePx = finiteOr(sample.width, widthPx * sampleCount) / sampleCount + spacing;
    this.evaluateRunSafety(widthPx);

    this.metrics = { widthPx, heightPx, baselinePx };
    this.needsFullRedraw = true;
    return this.metrics;
  }

  setGeometry(geometry: Geometry): void {
    this.geometry = geometry;
    this.metrics = geometry.cell;
    // The caller may lay out on a rounded cell width, which is a different
    // number from the one `measure` returned; runs are only safe against the
    // width actually being painted on.
    this.evaluateRunSafety(geometry.cell.widthPx);

    const ratio = geometry.devicePixelRatio > 0 ? geometry.devicePixelRatio : 1;
    const padding = geometry.padding ?? { top: 0, left: 0 };
    // Padding is letterboxing, so it exists on both sides of the grid; the CSS
    // box the renderer sizes itself to is the grid plus that box.
    const cssWidth = padding.left * 2 + geometry.cols * geometry.cell.widthPx;
    const cssHeight = padding.top * 2 + geometry.rows * geometry.cell.heightPx;
    const backingWidth = Math.max(1, Math.round(cssWidth * ratio));
    const backingHeight = Math.max(1, Math.round(cssHeight * ratio));

    // Assigning width/height resets the whole context state, so it is done
    // first and the transform is re-established after.
    if (this.canvas.width !== backingWidth) this.canvas.width = backingWidth;
    if (this.canvas.height !== backingHeight) this.canvas.height = backingHeight;
    const style = this.canvas.style as CSSStyleDeclaration | undefined;
    if (style) {
      style.width = `${cssWidth}px`;
      style.height = `${cssHeight}px`;
    }

    // Everything below draws in CSS pixels; the backing store carries the ratio.
    this.context.setTransform(ratio, 0, 0, ratio, 0, 0);
    this.needsFullRedraw = true;
  }

  setPalette(palette: Palette): void {
    if (palette.ansi.length !== 256) {
      throw new Error(
        `Palette.ansi must have exactly 256 entries, got ${palette.ansi.length}. ` +
          "A short palette is a theme bug; clamping it would paint the wrong colour silently.",
      );
    }
    this.palette = palette;
    this.colorCache.clear();
    // The whole theme-switch mechanism: every visible cell, including every
    // palette-indexed one, re-resolves on the next draw. No reload, no remount,
    // no re-parse.
    this.needsFullRedraw = true;
  }

  draw(frame: RenderFrame, history?: RowView[]): void {
    if (this.disposed) throw new Error("Canvas2dRenderer.draw after dispose");
    const geometry = this.geometry;
    if (!geometry) throw new Error("Canvas2dRenderer.draw before setGeometry");
    const palette = this.palette;
    if (!palette) throw new Error("Canvas2dRenderer.draw before setPalette");

    const started = now();
    const defaults: ResolvedDefaults = {
      foreground: frame.overrides.foreground ?? palette.foreground,
      background: frame.overrides.background ?? palette.background,
      cursor: frame.overrides.cursor ?? palette.cursor ?? frame.overrides.foreground ?? palette.foreground,
    };

    const cursorMark = this.cursorMark(frame, geometry);
    const defaultsChanged =
      this.lastDefaults === null ||
      !sameRgb(this.lastDefaults.foreground, defaults.foreground) ||
      !sameRgb(this.lastDefaults.background, defaults.background) ||
      !sameRgb(this.lastDefaults.cursor, defaults.cursor);
    // Scrolling moves every row to a different screen line; the damage flags
    // describe the grid, not the line it lands on.
    const scrolled = frame.scrollOffsetRows !== this.lastScrollOffsetRows;
    const full = this.needsFullRedraw || frame.dirty === "full" || scrolled || defaultsChanged;

    const cursorMoved = !sameCursorMark(this.lastCursor, cursorMark);
    if (!full && frame.dirty === "none" && !cursorMoved) {
      this.lastScrollOffsetRows = frame.scrollOffsetRows;
      return;
    }

    const context = this.context;
    this.applyLetterSpacing(this.font);
    context.textBaseline = "alphabetic";
    context.globalAlpha = 1;

    const byLine = new Map<number, RowView>();
    collectRows(byLine, history, frame.scrollOffsetRows, geometry.rows);
    collectRows(byLine, frame.rows_, frame.scrollOffsetRows, geometry.rows);

    let lines: number[];
    if (full) {
      const padding = geometry.padding ?? { top: 0, left: 0 };
      context.fillStyle = this.css(defaults.background);
      context.fillRect(
        0,
        0,
        padding.left * 2 + geometry.cols * geometry.cell.widthPx,
        padding.top * 2 + geometry.rows * geometry.cell.heightPx,
      );
      lines = [];
      for (let line = 0; line < geometry.rows; line += 1) lines.push(line);
      this.fullRedraws += 1;
    } else {
      const damaged = new Set<number>();
      markDamage(damaged, history, frame.scrollOffsetRows, geometry.rows);
      markDamage(damaged, frame.rows_, frame.scrollOffsetRows, geometry.rows);
      // The cursor is an overlay, so the line it left and the line it arrived
      // on repaint even when the grid under them did not change.
      if (this.lastCursor && this.lastCursor.line < geometry.rows) damaged.add(this.lastCursor.line);
      if (cursorMark) damaged.add(cursorMark.line);
      lines = Array.from(damaged).sort((a, b) => a - b);
    }

    for (const line of lines) {
      const row = byLine.get(line);
      if (row) {
        this.paintRow(line, row, geometry, defaults);
      } else if (!full) {
        // A damaged line with no row behind it (a neighbour past the end of
        // history) still has last frame's pixels on it.
        const padding = geometry.padding ?? { top: 0, left: 0 };
        context.fillStyle = this.css(defaults.background);
        context.fillRect(
          padding.left,
          padding.top + line * geometry.cell.heightPx,
          geometry.cols * geometry.cell.widthPx,
          geometry.cell.heightPx,
        );
      }
    }

    if (cursorMark) {
      const row = byLine.get(cursorMark.line);
      this.paintCursor(frame, cursorMark, row, geometry, defaults);
    }

    this.needsFullRedraw = false;
    this.lastScrollOffsetRows = frame.scrollOffsetRows;
    this.lastDefaults = defaults;
    this.lastCursor = cursorMark;

    const elapsed = now() - started;
    this.framesPainted += 1;
    if (elapsed > FRAME_BUDGET_MS) this.droppedFrames += 1;
    this.frameTimes.push(elapsed);
    if (this.frameTimes.length > FRAME_TIME_SAMPLES) this.frameTimes.shift();
  }

  dispose(): void {
    // Idempotent: React 19 StrictMode double-invokes effects, so the second
    // call has to be a no-op rather than a second teardown.
    if (this.disposed) return;
    this.disposed = true;
    this.geometry = null;
    this.palette = null;
    this.lastDefaults = null;
    this.lastCursor = null;
    this.colorCache.clear();
    this.foregroundScratch = [];
    this.backgroundScratch = [];
  }

  stats(): RendererStats {
    const sorted = this.frameTimes.slice().sort((a, b) => a - b);
    return {
      implementation: "canvas2d",
      framesPainted: this.framesPainted,
      fullRedraws: this.fullRedraws,
      droppedFrames: this.droppedFrames,
      frameTimeP50Ms: percentile(sorted, 0.5),
      frameTimeP95Ms: percentile(sorted, 0.95),
    };
  }

  private paintRow(line: number, row: RowView, geometry: Geometry, defaults: ResolvedDefaults): void {
    const context = this.context;
    const { widthPx, heightPx, baselinePx } = geometry.cell;
    const padding = geometry.padding ?? { top: 0, left: 0 };
    const top = padding.top + line * heightPx;
    const left = padding.left;
    const count = Math.min(row.cells.length, geometry.cols);
    const defaultBackground = this.css(defaults.background);

    if (this.foregroundScratch.length < count) {
      this.foregroundScratch.length = count;
      this.backgroundScratch.length = count;
    }

    // Background pass. The row starts as the viewer's default background, then
    // every run that differs is filled over it, so a shrinking line does not
    // leave last frame's pixels behind.
    context.fillStyle = defaultBackground;
    context.fillRect(left, top, geometry.cols * widthPx, heightPx);

    let runStart = -1;
    let runColor = "";
    for (let column = 0; column < count; column += 1) {
      const cell = row.cells[column];
      const selected = isSelected(row, cell, column);
      let foreground = this.resolve(cell.foreground, defaults.foreground);
      let background = this.resolve(cell.background, defaults.background);
      if (selected) {
        // The seam's Palette carries no selection colour, so selection is a
        // slot swap: it reads as selected in every theme without inventing one.
        const swap = foreground;
        foreground = background;
        background = swap;
      }
      const foregroundCss = this.css(foreground);
      const backgroundCss = this.css(background);
      this.foregroundScratch[column] = foregroundCss;
      this.backgroundScratch[column] = backgroundCss;

      if (backgroundCss === runColor) continue;
      if (runStart >= 0 && runColor !== defaultBackground) {
        context.fillStyle = runColor;
        context.fillRect(left + runStart * widthPx, top, (column - runStart) * widthPx, heightPx);
      }
      runStart = column;
      runColor = backgroundCss;
    }
    if (runStart >= 0 && runColor !== defaultBackground) {
      context.fillStyle = runColor;
      context.fillRect(left + runStart * widthPx, top, (count - runStart) * widthPx, heightPx);
    }

    // Text pass.
    const baseline = top + baselinePx;
    let textStart = -1;
    let text = "";
    let textColor = "";
    let textFont = "";
    let textAlpha = 1;
    const flush = (): void => {
      if (textStart < 0 || text === "") {
        textStart = -1;
        text = "";
        return;
      }
      context.fillStyle = textColor;
      context.font = textFont;
      context.globalAlpha = textAlpha;
      context.fillText(text, left + textStart * widthPx, baseline);
      context.globalAlpha = 1;
      textStart = -1;
      text = "";
    };

    for (let column = 0; column < count; column += 1) {
      const cell = row.cells[column];
      if ((cell.attributes & ATTR.WIDE_SPACER) !== 0) {
        // The spacer's background was already painted; its glyph belongs to the
        // WIDE cell to its left.
        flush();
        continue;
      }
      const glyph = cellText(cell);
      if (glyph === "") {
        flush();
        continue;
      }
      const foregroundCss = this.foregroundScratch[column];
      const cellFont = fontString(
        this.font,
        (cell.attributes & ATTR.BOLD) !== 0,
        (cell.attributes & ATTR.ITALIC) !== 0,
      );
      const alpha = (cell.attributes & ATTR.FAINT) !== 0 ? FAINT_ALPHA : 1;

      if (!this.runsStayOnGrid || !isRunnable(cell)) {
        flush();
        context.fillStyle = foregroundCss;
        context.font = cellFont;
        context.globalAlpha = alpha;
        context.fillText(glyph, left + column * widthPx, baseline);
        context.globalAlpha = 1;
        continue;
      }

      if (
        textStart >= 0 &&
        (foregroundCss !== textColor || cellFont !== textFont || alpha !== textAlpha)
      ) {
        flush();
      }
      if (textStart < 0) {
        textStart = column;
        textColor = foregroundCss;
        textFont = cellFont;
        textAlpha = alpha;
      }
      text += glyph;
    }
    flush();

    this.paintDecorations(row, count, left, top, geometry, defaults);
  }

  private paintDecorations(
    row: RowView,
    count: number,
    left: number,
    top: number,
    geometry: Geometry,
    defaults: ResolvedDefaults,
  ): void {
    const context = this.context;
    const { widthPx, heightPx, baselinePx } = geometry.cell;
    const thickness = Math.max(1, Math.round(this.font.sizePx / 14));
    const decorated =
      ATTR.UNDERLINE | ATTR.UNDERCURL | ATTR.STRIKETHROUGH | ATTR.OVERLINE;

    for (let column = 0; column < count; column += 1) {
      const cell = row.cells[column];
      if ((cell.attributes & decorated) === 0) continue;

      const selected = isSelected(row, cell, column);
      const base = selected
        ? this.resolve(cell.background, defaults.background)
        : this.resolve(cell.foreground, defaults.foreground);
      const lineColor =
        cell.underline !== undefined && !selected
          ? this.css(this.resolve(cell.underline, base))
          : this.css(base);
      const x = left + column * widthPx;
      const width = (cell.attributes & ATTR.WIDE) !== 0 ? widthPx * 2 : widthPx;

      if ((cell.attributes & ATTR.OVERLINE) !== 0) {
        context.fillStyle = lineColor;
        context.fillRect(x, top, width, thickness);
      }
      if ((cell.attributes & ATTR.STRIKETHROUGH) !== 0) {
        context.fillStyle = lineColor;
        context.fillRect(x, top + Math.round(baselinePx * 0.6), width, thickness);
      }
      if ((cell.attributes & ATTR.UNDERLINE) !== 0) {
        context.fillStyle = lineColor;
        context.fillRect(x, top + Math.min(heightPx - thickness, baselinePx + thickness), width, thickness);
      }
      if ((cell.attributes & ATTR.UNDERCURL) !== 0) {
        // A zigzag, not a shaped curl: the honest v1 shape, replaced when the
        // WebGPU implementation brings real geometry.
        const y = top + Math.min(heightPx - thickness * 2, baselinePx + thickness);
        context.strokeStyle = lineColor;
        context.lineWidth = thickness;
        context.beginPath();
        context.moveTo(x, y + thickness);
        const steps = 4;
        for (let step = 1; step <= steps; step += 1) {
          context.lineTo(x + (width * step) / steps, y + (step % 2 === 0 ? thickness : 0));
        }
        context.stroke();
      }
    }
  }

  private paintCursor(
    frame: RenderFrame,
    mark: CursorMark,
    row: RowView | undefined,
    geometry: Geometry,
    defaults: ResolvedDefaults,
  ): void {
    const context = this.context;
    const { widthPx, heightPx, baselinePx } = geometry.cell;
    const padding = geometry.padding ?? { top: 0, left: 0 };
    const x = padding.left + mark.x * widthPx;
    const y = padding.top + mark.line * heightPx;
    const width = mark.width * widthPx;
    const color = this.css(defaults.cursor);

    switch (frame.cursor.style) {
      case "bar":
        context.fillStyle = color;
        context.fillRect(x, y, Math.max(1, Math.round(widthPx / 8)), heightPx);
        return;
      case "underline":
        context.fillStyle = color;
        context.fillRect(
          x,
          y + heightPx - Math.max(1, Math.round(heightPx / 12)),
          width,
          Math.max(1, Math.round(heightPx / 12)),
        );
        return;
      case "hollow_block":
        context.strokeStyle = color;
        context.lineWidth = 1;
        context.strokeRect(x + 0.5, y + 0.5, width - 1, heightPx - 1);
        return;
      case "block": {
        context.fillStyle = color;
        context.fillRect(x, y, width, heightPx);
        const cell = row?.cells[mark.x];
        if (!cell) return;
        const glyph = cellText(cell);
        if (glyph === "") return;
        // The glyph is redrawn in the cell's own background so a block cursor
        // does not hide the character it sits on.
        context.fillStyle = this.css(this.resolve(cell.background, defaults.background));
        context.font = fontString(
          this.font,
          (cell.attributes & ATTR.BOLD) !== 0,
          (cell.attributes & ATTR.ITALIC) !== 0,
        );
        context.fillText(glyph, x, y + baselinePx);
        return;
      }
    }
  }

  private cursorMark(frame: RenderFrame, geometry: Geometry): CursorMark | null {
    const cursor = frame.cursor;
    // `hasValue` false means the cursor is not on the viewport at all; x/y are
    // not to be clamped into range, they are to be ignored.
    if (!cursor.hasValue || !cursor.visible || cursor.passwordInput) return null;
    const line = cursor.y + frame.scrollOffsetRows;
    if (line < 0 || line >= geometry.rows) return null;
    if (cursor.x < 0 || cursor.x >= geometry.cols) return null;
    const row = frame.rows_.find((candidate) => candidate.y === cursor.y);
    const cell = row?.cells[cursor.x];
    const wide = !cursor.wideTail && cell !== undefined && (cell.attributes & ATTR.WIDE) !== 0;
    const width = wide && cursor.x + 1 < geometry.cols ? 2 : 1;
    return { line, x: cursor.x, width };
  }

  /**
   * The one place a colour slot becomes pixels. `default` is the viewer's
   * default — never black — and `palette` is an index into the *viewer's*
   * theme, resolved here rather than anywhere upstream.
   */
  private resolve(color: TaggedColor, fallback: Rgb): Rgb {
    switch (color.tag) {
      case "default":
        return fallback;
      case "palette": {
        const palette = this.palette;
        if (!palette) return fallback;
        const entry = palette.ansi[color.index & 255];
        return entry ?? fallback;
      }
      case "rgb":
        return color;
    }
  }

  private css(color: Rgb): string {
    const key = packRgb(color);
    const cached = this.colorCache.get(key);
    if (cached !== undefined) return cached;
    const value = `#${key.toString(16).padStart(6, "0")}`;
    this.colorCache.set(key, value);
    return value;
  }

  /**
   * Drift accumulates across a row, and a row can be 200 cells wide, so the
   * tolerance is a quarter of a pixel over the whole sample rather than per
   * cell. A font that misses it is drawn cell by cell, which cannot drift.
   */
  private evaluateRunSafety(cellWidthPx: number): void {
    const sampleCount = 8;
    this.runsStayOnGrid =
      this.sampleAdvancePx > 0 &&
      Math.abs(this.sampleAdvancePx - cellWidthPx) < 0.25 / sampleCount;
  }

  private applyLetterSpacing(font: FontSpec): void {
    if (!this.letterSpacingIsHonoured()) return;
    const context = this.context as CanvasRenderingContext2D & { letterSpacing: string };
    context.letterSpacing = `${font.letterSpacingPx ?? 0}px`;
  }

  private letterSpacingIsHonoured(): boolean {
    const context = this.context as CanvasRenderingContext2D & { letterSpacing?: string };
    return typeof context.letterSpacing === "string";
  }
}

function sameCursorMark(a: CursorMark | null, b: CursorMark | null): boolean {
  if (a === null || b === null) return a === b;
  return a.line === b.line && a.x === b.x && a.width === b.width;
}

function isSelected(row: RowView, cell: CellView, column: number): boolean {
  // render.h recommends the row-local range for span renderers and documents
  // that it agrees with the per-cell flag; the flag is the fallback.
  if (row.selection) return column >= row.selection.start && column < row.selection.end;
  return cell.selected;
}

function collectRows(
  into: Map<number, RowView>,
  rows: RowView[] | undefined,
  scrollOffsetRows: number,
  lineCount: number,
): void {
  if (!rows) return;
  for (const row of rows) {
    const line = row.y + scrollOffsetRows;
    if (line < 0 || line >= lineCount) continue;
    into.set(line, row);
  }
}

function markDamage(
  into: Set<number>,
  rows: RowView[] | undefined,
  scrollOffsetRows: number,
  lineCount: number,
): void {
  if (!rows) return;
  for (const row of rows) {
    if (!row.dirty) continue;
    const line = row.y + scrollOffsetRows;
    // The neighbours come along because a tall glyph, a descender, or an
    // italic overhangs its own row — ghostty-web's lesson, taken without
    // taking their code.
    for (let candidate = line - 1; candidate <= line + 1; candidate += 1) {
      if (candidate >= 0 && candidate < lineCount) into.add(candidate);
    }
  }
}

function percentile(sorted: number[], fraction: number): number {
  if (sorted.length === 0) return 0;
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * fraction) - 1));
  return sorted[index];
}

/**
 * Canvas 2D is available wherever a 2D context is. `null` is returned only when
 * the context cannot be had at all, which is the same "not available here"
 * signal the WebGPU factory will use — the caller tries one factory, then the
 * next, and the page never shows a wall.
 */
export const createCanvas2dRenderer: RendererFactory = (canvas, font) => {
  const context = canvas.getContext("2d", { alpha: false });
  if (!context) return null;
  return new Canvas2dRenderer(canvas, context, font);
};
