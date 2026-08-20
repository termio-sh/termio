import type { TaggedColor } from "../protocol/colors";
export type { TaggedColor };

export interface Rgb {
  r: number;
  g: number;
  b: number;
}

/**
 * The VIEWER's theme. Never the host's, never the program's, never one baked
 * into the Wasm at construction. This is the only place a palette index
 * becomes a pixel.
 */
export interface Palette {
  background: Rgb;
  foreground: Rgb;
  cursor?: Rgb;
  ansi: Rgb[]; // EXACTLY 256 entries; shorter is a throw, not a clamp
}

/**
 * Paint-time decoration only. `inverse` and `invisible` are NOT here: the vt
 * binding applies them while reading a cell, exactly as
 * `termiod/vt/src/lib.rs::cell_from_parts` does (swap fg/bg on inverse; blank
 * the codepoint on invisible), so a viewport row and a decoded history row
 * cannot disagree about what a cell looks like.
 */
export const ATTR = {
  BOLD: 1 << 0,
  FAINT: 1 << 1,
  ITALIC: 1 << 2,
  UNDERLINE: 1 << 3,
  UNDERCURL: 1 << 4,
  STRIKETHROUGH: 1 << 5,
  OVERLINE: 1 << 6,
  BLINK: 1 << 7,
  /** This cell is the left half of a double-width grapheme. */
  WIDE: 1 << 8,
  /** Spacer trailing a WIDE cell. Paint background only; draw no glyph. */
  WIDE_SPACER: 1 << 9,
} as const;

/**
 * One cell. Objects in a RowView are POOLED and mutated in place between
 * frames — read them during `draw()` and never retain one.
 */
export interface CellView {
  /** 0 = blank. Use `grapheme` when present. */
  codepoint: number;
  /** The full grapheme cluster, present only when the cell is not a single
   *  codepoint (…_DATA_GRAPHEMES_UTF8). History cells never set it. */
  grapheme?: string;
  foreground: TaggedColor;
  background: TaggedColor;
  /** Program-set underline colour (SGR 58). Absent = use `foreground`. */
  underline?: TaggedColor;
  attributes: number; // ATTR bitmask
  selected: boolean;
}

export interface RowView {
  /**
   * Viewport row index, 0 = top. History rows are NEGATIVE: -1 is the row
   * immediately above the viewport.
   */
  y: number;
  dirty: boolean;
  /** Row-local, half-open column range. Absent = nothing selected on this row.
   *  render.h's own doc recommends the range over per-cell flags for span
   *  renderers; `CellView.selected` is the per-cell fallback and the two agree. */
  selection?: { start: number; end: number };
  /** Length === frame.cols. Valid only for the duration of one `draw()`. */
  cells: CellView[];
}

export type CursorStyle = "block" | "bar" | "underline" | "hollow_block";

export interface CursorState {
  /** render.h's `viewport_has_value`. false = the cursor is not on the
   *  viewport; paint nothing and do not clamp x/y into range. */
  hasValue: boolean;
  x: number;
  y: number;
  visible: boolean;
  blinking: boolean;
  /** Password input is in progress; a renderer may suppress the cursor. */
  passwordInput: boolean;
  /** The cursor sits on the tail half of a wide grapheme. */
  wideTail: boolean;
  style: CursorStyle;
}

/**
 * Colours the PROGRAM set (OSC 10 / 11 / 12), which are program intent and
 * therefore honoured, as distinct from the engine's configured defaults, which
 * are the presentation boundary's business and must never be read. The vt
 * binding is responsible for telling the two apart; an absent field means "the
 * program said nothing — use the viewer's Palette".
 */
export interface ColorOverrides {
  foreground?: Rgb;
  background?: Rgb;
  cursor?: Rgb;
}

export interface RenderFrame {
  /** Global dirty, from render.h: FALSE / PARTIAL / FULL. */
  dirty: "none" | "partial" | "full";
  cols: number;
  rows: number;
  cursor: CursorState;
  /** Viewport rows, top to bottom. Name kept verbatim from the RFC. */
  rows_: RowView[];
  overrides: ColorOverrides;
  /**
   * How many rows the view is scrolled up from the live bottom; 0 = live.
   * A row (viewport or history) with index `y` paints on screen line
   * `y + scrollOffsetRows`. One number, one arithmetic, both row sources.
   */
  scrollOffsetRows: number;
}

export interface FontSpec {
  family: string; // CSS font-family list
  sizePx: number;
  weightNormal: number; // 400
  weightBold: number; // 700
  lineHeight: number; // multiplier on the font's line box
  letterSpacingPx?: number;
}

export interface CellMetrics {
  widthPx: number;
  heightPx: number;
  baselinePx: number;
}

export interface Geometry {
  cols: number;
  rows: number;
  cell: CellMetrics;
  devicePixelRatio: number;
  /** Letterboxing when the CSS box is larger than cols×rows — an observer
   *  parses at the AUTHORITATIVE dims from `attached`/`resized` and pads,
   *  it does not reparse at the window size. */
  padding?: { top: number; left: number };
}

/**
 * The seam. Canvas 2D satisfies it in v1; WebGPU satisfies the same interface
 * in v2 and nothing above it learns which is loaded.
 *
 * Rules that make the swap a swap:
 *  - The renderer resolves colour; the Wasm never does. It reads
 *    `…_ROW_CELLS_DATA_STYLE` (already resolved into TaggedColor by the
 *    binding) against the Palette it was given. Reading
 *    `…_DATA_FG_COLOR` / `…_DATA_BG_COLOR` anywhere is a reviewable line in a
 *    diff. `{tag:"default"}` paints the viewer's default, never black.
 *  - The renderer never owns state it can be told about: no socket, no Wasm
 *    handle, no React import, no timer of its own. It is called; it does not
 *    call.
 *  - Damage comes in, never derived. It does not diff grids. "full" and
 *    `setPalette` mean repaint everything; "partial" means repaint flagged
 *    rows plus whatever neighbours glyph overflow needs — that part is the
 *    renderer's own business.
 *  - No view outlives an allocating call. RowView/CellView data is valid for
 *    the duration of one `draw()`. Stashing a typed array across frames is the
 *    detached-view bug with extra latency.
 */
export interface TerminalRenderer {
  measure(font: FontSpec): CellMetrics;
  setGeometry(g: Geometry): void;
  /** Forces a full redraw. This is the whole theme-switch mechanism. */
  setPalette(p: Palette): void;
  /** `history` rows carry negative `y`. Both arrays paint through one path. */
  draw(frame: RenderFrame, history?: RowView[]): void;
  dispose(): void;
}

/** Dev-only counters; the inputs to the WebGPU entry trigger. Never sent anywhere. */
export interface RendererStats {
  implementation: "canvas2d" | "webgpu";
  framesPainted: number;
  fullRedraws: number;
  droppedFrames: number;
  frameTimeP50Ms: number;
  frameTimeP95Ms: number;
}

/**
 * `null` means "not available here" — that is the whole WebGPU probe. The
 * caller tries webgpu, gets null on a Linux Firefox, and constructs canvas2d.
 * The page shows no wall, no banner, and no "enable this flag" nag.
 */
export type RendererFactory = (
  canvas: HTMLCanvasElement,
  font: FontSpec,
) => (TerminalRenderer & { stats(): RendererStats }) | null;
