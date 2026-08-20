/**
 * The Wasm terminal: bytes in, one render frame out.
 *
 * The presentation boundary lives in `readCell` below. Cell colour is read from
 * `GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE` — the *unresolved* `GhosttyStyle`
 * — and from the cell's own background content tag. It is never read from
 * `…_DATA_FG_COLOR` / `…_DATA_BG_COLOR`, whose own doc comment says they
 * resolve "palette indices through the palette": that resolution is the
 * viewer's, and doing it here is the bug that disqualified ghostty-web and
 * `@wterm/ghostty`. Neither constant appears in this file, and neither may.
 *
 * `termiod/vt/src/lib.rs::cell_from_parts` is the Rust twin of `readCell`, down
 * to applying `inverse` and `invisible` here rather than leaving them for the
 * renderer, so a live viewport row and a decoded history row cannot disagree
 * about what a cell looks like.
 */

import type {
  CellView,
  ColorOverrides,
  CursorState,
  CursorStyle,
  RenderFrame,
  Rgb,
  RowView,
  TaggedColor,
} from "../renderer/types";
// ATTR is a value, not a type, and this is the one runtime import `src/vt/`
// takes from the seam. The alternative is a second copy of the bitmask, and two
// definitions of the same bits is exactly the drift the seam exists to prevent.
import { ATTR } from "../renderer/types";

import type { BindingContext } from "./context";
import type { KeyEncoderModes } from "./keyEncoder";
import { extractBits } from "./typeJson";

export interface TerminalOptions {
  rows: number;
  cols: number;
  /**
   * BYTES, not lines — Ghostty pages internally and we do not pretend to know
   * a line count. The caller passes 1 MiB, matching the host's
   * SCROLLBACK_STAGE_MAX_BYTES.
   */
  scrollbackBytes: number;
}

export interface VtTerminal {
  readonly rows: number;
  readonly cols: number;
  write(bytes: Uint8Array): void;
  resize(rows: number, cols: number): void;
  readFrame<T>(visit: (frame: RenderFrame) => T): T;
  syncOutputActive(): boolean;
  title(): string | null;
  keyEncoderModes(): KeyEncoderModes;
  dispose(): void;
}

/**
 * Not imported from `protocol/colors.ts`: `src/vt/` must not depend on protocol
 * runtime code. The shape is the seam's `TaggedColor`, and the renderer reads
 * `tag`, never object identity, so one frozen singleton per module is a shared
 * allocation saving rather than a second definition of anything.
 */
const DEFAULT_COLOR: TaggedColor = Object.freeze({ tag: "default" as const });

/** DEC private modes, by their VT numbers. These are the standard, not an ABI. */
const MODE_CURSOR_KEYS = 1; // DECCKM
const MODE_KEYPAD_KEYS = 66; // DECKPAM / application keypad
const MODE_ALT_ESC_PREFIX = 1036;
const MODE_BRACKETED_PASTE = 2004;
const MODE_SYNC_OUTPUT = 2026;

/**
 * Cell metrics handed to `ghostty_terminal_resize`. The VT only uses them for
 * in-band size reports (mode 2048); termiod's own sidecar passes the same 8×16
 * so a session reports one geometry no matter which client resized it.
 */
const CELL_WIDTH_PX = 8;
const CELL_HEIGHT_PX = 16;

interface StyleRead {
  foreground: TaggedColor;
  background: TaggedColor;
  underline: TaggedColor | null;
  attributes: number;
  inverse: boolean;
  invisible: boolean;
}

export function createTerminal(
  context: BindingContext,
  options: TerminalOptions,
): VtTerminal {
  return new WasmTerminal(context, options);
}

class WasmTerminal implements VtTerminal {
  private readonly context: BindingContext;
  private terminal: number;
  private renderState: number;
  private rowIterator: number;
  private cellIterator: number;

  /** One pointer-sized slot, reused for every "populate this handle" call. */
  private readonly slot: number;
  private readonly slotSize: number;
  /** Big enough for every sized struct this binding reads. */
  private readonly scratch: number;
  private readonly scratchSize: number;
  private graphemeBuffer: number;
  private graphemeCapacity: number;

  private rowsValue: number;
  private colsValue: number;
  private disposed = false;
  private visiting = false;

  private readonly rowPool: RowView[] = [];
  private readonly styleCache = new Map<number, StyleRead>();
  private readonly frame: RenderFrame;

  constructor(context: BindingContext, options: TerminalOptions) {
    if (options.rows <= 0 || options.cols <= 0) {
      throw new RangeError(
        `terminal geometry ${options.cols}x${options.rows} must be positive`,
      );
    }
    this.context = context;
    const { exports, abi, mem } = context;

    this.rowsValue = options.rows;
    this.colsValue = options.cols;

    this.terminal = context.createHandle("ghostty_terminal_new", (slot) =>
      exports.ghostty_terminal_new(0, slot, options.cols, options.rows),
    );

    let renderState = 0;
    let rowIterator = 0;
    let cellIterator = 0;
    let slot = 0;
    let scratch = 0;
    let graphemeBuffer = 0;
    try {
      renderState = context.createHandle("ghostty_render_state_new", (out) =>
        exports.ghostty_render_state_new(0, out),
      );
      rowIterator = context.createHandle(
        "ghostty_render_state_row_iterator_new",
        (out) => exports.ghostty_render_state_row_iterator_new(0, out),
      );
      cellIterator = context.createHandle(
        "ghostty_render_state_row_cells_new",
        (out) => exports.ghostty_render_state_row_cells_new(0, out),
      );

      this.slotSize = abi.manifest.abi.pointerSize;
      slot = mem.alloc(this.slotSize);
      this.scratchSize = Math.max(
        abi.style.size,
        abi.cursor.size,
        abi.rowSelection.size,
        abi.cellsView.size,
        abi.string.size,
        abi.buffer.size,
        abi.modeConfig.size,
        abi.colorRgb.size,
        8,
      );
      scratch = mem.alloc(this.scratchSize);
      this.graphemeCapacity = 64;
      graphemeBuffer = mem.alloc(this.graphemeCapacity);
    } catch (error) {
      if (cellIterator !== 0) exports.ghostty_render_state_row_cells_free(cellIterator);
      if (rowIterator !== 0) exports.ghostty_render_state_row_iterator_free(rowIterator);
      if (renderState !== 0) exports.ghostty_render_state_free(renderState);
      if (slot !== 0) mem.free(slot, abi.manifest.abi.pointerSize);
      exports.ghostty_terminal_free(this.terminal);
      this.terminal = 0;
      throw error;
    }

    this.renderState = renderState;
    this.rowIterator = rowIterator;
    this.cellIterator = cellIterator;
    this.slot = slot;
    this.scratch = scratch;
    this.graphemeBuffer = graphemeBuffer;

    this.setScrollbackBytes(options.scrollbackBytes);

    this.frame = {
      dirty: "full",
      cols: this.colsValue,
      rows: this.rowsValue,
      cursor: {
        hasValue: false,
        x: 0,
        y: 0,
        visible: false,
        blinking: false,
        passwordInput: false,
        wideTail: false,
        style: "block",
      },
      rows_: this.rowPool,
      overrides: {},
      // The Wasm viewport is never scrolled in v1: history arrives as `H`
      // frames and the renderer paints it from its own buffer, so the live
      // viewport is always at the bottom.
      scrollOffsetRows: 0,
    };
  }

  get rows(): number {
    return this.rowsValue;
  }

  get cols(): number {
    return this.colsValue;
  }

  write(bytes: Uint8Array): void {
    this.assertUsable("write");
    if (bytes.length === 0) return;
    const { exports, mem } = this.context;
    // ALLOCATING: this may grow linear memory. The `set` below therefore takes
    // its view AFTER the alloc, and nothing cached from before it survives.
    const pointer = mem.alloc(bytes.length);
    try {
      mem.u8(pointer, bytes.length).set(bytes);
      exports.ghostty_terminal_vt_write(this.terminal, pointer, bytes.length);
    } finally {
      mem.free(pointer, bytes.length);
    }
  }

  resize(rows: number, cols: number): void {
    this.assertUsable("resize");
    if (rows <= 0 || cols <= 0) {
      throw new RangeError(`terminal geometry ${cols}x${rows} must be positive`);
    }
    const { exports } = this.context;
    this.context.check(
      "ghostty_terminal_resize",
      exports.ghostty_terminal_resize(
        this.terminal,
        cols,
        rows,
        CELL_WIDTH_PX,
        CELL_HEIGHT_PX,
      ),
    );
    this.rowsValue = rows;
    this.colsValue = cols;
    // Pooled rows are indexed by y and sized to the old column count; a resize
    // invalidates both, and the next frame is FULL anyway.
    this.rowPool.length = 0;
  }

  readFrame<T>(visit: (frame: RenderFrame) => T): T {
    this.assertUsable("readFrame");
    if (this.visiting) {
      throw new Error("readFrame is not reentrant");
    }
    const { exports } = this.context;

    // render.h: "Every begin must be completed with a
    // ghostty_render_state_end_update call before the render state is read."
    // So the bracket is begin → end → read → visit → clean, not
    // begin → read → end.
    this.context.check(
      "ghostty_render_state_begin_update",
      exports.ghostty_render_state_begin_update(this.renderState, this.terminal),
    );
    this.context.check(
      "ghostty_render_state_end_update",
      exports.ghostty_render_state_end_update(this.renderState),
    );

    const frame = this.buildFrame();

    this.visiting = true;
    let result: T;
    try {
      result = visit(frame);
    } finally {
      this.visiting = false;
    }

    // Only after the frame was actually consumed: if `visit` threw, the damage
    // stands and the next frame repaints it.
    this.context.check(
      "ghostty_render_state_clean",
      exports.ghostty_render_state_clean(this.renderState),
    );
    return result;
  }

  syncOutputActive(): boolean {
    this.assertUsable("syncOutputActive");
    return this.readMode(MODE_SYNC_OUTPUT);
  }

  title(): string | null {
    this.assertUsable("title");
    const { exports, abi, mem } = this.context;
    const code = exports.ghostty_terminal_get(
      this.terminal,
      abi.terminalData.title,
      this.scratch,
    );
    if (!this.context.hasValue("ghostty_terminal_get(TITLE)", code)) return null;
    const pointer = this.context.readU32(this.scratch + abi.string.ptr);
    const length = this.context.readUsize(this.scratch + abi.string.len);
    if (pointer === 0 || length === 0) return null;
    return mem.decodeUtf8(pointer, length);
  }

  keyEncoderModes(): KeyEncoderModes {
    this.assertUsable("keyEncoderModes");
    const { exports, abi } = this.context;
    const flagsCode = exports.ghostty_terminal_get(
      this.terminal,
      abi.terminalData.kittyKeyboardFlags,
      this.scratch,
    );
    const kittyFlags = this.context.hasValue(
      "ghostty_terminal_get(KITTY_KEYBOARD_FLAGS)",
      flagsCode,
    )
      ? this.context.readU8(this.scratch)
      : 0;
    return {
      cursorKeyApplication: this.readMode(MODE_CURSOR_KEYS),
      keypadApplication: this.readMode(MODE_KEYPAD_KEYS),
      kittyFlags,
      altSendsEscape: this.readMode(MODE_ALT_ESC_PREFIX),
      bracketedPaste: this.readMode(MODE_BRACKETED_PASTE),
    };
  }

  dispose(): void {
    if (this.disposed) return;
    if (this.visiting) {
      throw new Error("dispose called from inside readFrame");
    }
    this.disposed = true;
    const { exports, mem } = this.context;
    exports.ghostty_render_state_row_cells_free(this.cellIterator);
    exports.ghostty_render_state_row_iterator_free(this.rowIterator);
    exports.ghostty_render_state_free(this.renderState);
    exports.ghostty_terminal_free(this.terminal);
    mem.free(this.slot, this.slotSize);
    mem.free(this.scratch, this.scratchSize);
    mem.free(this.graphemeBuffer, this.graphemeCapacity);
    this.cellIterator = 0;
    this.rowIterator = 0;
    this.renderState = 0;
    this.terminal = 0;
    this.graphemeBuffer = 0;
    this.graphemeCapacity = 0;
    this.rowPool.length = 0;
    this.styleCache.clear();
  }

  private assertUsable(operation: string): void {
    if (this.disposed) {
      throw new Error(`${operation} called on a disposed terminal`);
    }
    // The reentrancy guard is not a debug aid: `write`, `resize`, and every
    // allocation may grow linear memory, and the frame handed to `visit` is a
    // set of views onto the memory that growth replaces.
    if (this.visiting && operation !== "readFrame") {
      throw new Error(`${operation} called from inside readFrame`);
    }
  }

  private setScrollbackBytes(bytes: number): void {
    const { exports, abi, mem } = this.context;
    const pointer = mem.alloc(abi.manifest.abi.usizeSize);
    try {
      this.context.writeUsize(pointer, bytes);
      this.context.check(
        "ghostty_terminal_set(SCROLLBACK_MAX_BYTES)",
        exports.ghostty_terminal_set(
          this.terminal,
          abi.terminalOption.scrollbackMaxBytes,
          pointer,
        ),
      );
    } finally {
      mem.free(pointer, abi.manifest.abi.usizeSize);
    }
  }

  private readMode(mode: number): boolean {
    const { exports, abi } = this.context;
    // GhosttyMode packs the number in bits 0–14 and the ANSI flag in bit 15.
    // Every mode read here is a DEC private mode, so the flag stays clear.
    this.context.writeU16(this.scratch + abi.modeConfig.mode, mode);
    this.context.writeU8(this.scratch + abi.modeConfig.value, 0);
    const code = exports.ghostty_terminal_get(
      this.terminal,
      abi.terminalData.mode,
      this.scratch,
    );
    if (!this.context.hasValue(`ghostty_terminal_get(MODE ${mode})`, code)) {
      return false;
    }
    return this.context.readBool(this.scratch + abi.modeConfig.value);
  }

  private buildFrame(): RenderFrame {
    const { exports, abi } = this.context;
    const frame = this.frame;

    this.context.check(
      "ghostty_render_state_get(DIRTY)",
      exports.ghostty_render_state_get(
        this.renderState,
        abi.renderStateData.dirty,
        this.scratch,
      ),
    );
    const dirtyValue = this.context.readI32(this.scratch);
    frame.dirty =
      dirtyValue === abi.renderStateDirty.full
        ? "full"
        : dirtyValue === abi.renderStateDirty.partial
          ? "partial"
          : "none";

    this.context.check(
      "ghostty_render_state_get(COLS)",
      exports.ghostty_render_state_get(
        this.renderState,
        abi.renderStateData.cols,
        this.scratch,
      ),
    );
    frame.cols = this.context.readU16(this.scratch);
    this.context.check(
      "ghostty_render_state_get(ROWS)",
      exports.ghostty_render_state_get(
        this.renderState,
        abi.renderStateData.rows,
        this.scratch,
      ),
    );
    frame.rows = this.context.readU16(this.scratch);

    this.readCursor(frame.cursor);
    this.readOverrides(frame.overrides);
    this.readRows(frame);
    return frame;
  }

  private readCursor(cursor: CursorState): void {
    const { exports, abi } = this.context;
    this.context.writeUsize(this.scratch + abi.cursor.sizeField, abi.cursor.size);
    this.context.check(
      "ghostty_render_state_get(CURSOR)",
      exports.ghostty_render_state_get(
        this.renderState,
        abi.renderStateData.cursor,
        this.scratch,
      ),
    );
    const hasValue = this.context.readBool(
      this.scratch + abi.cursor.viewportHasValue,
    );
    cursor.hasValue = hasValue;
    // render.h: when viewport_has_value is false, x / y / wide_tail contain
    // undefined data. Report zeroes rather than clamping garbage into range.
    cursor.x = hasValue ? this.context.readU16(this.scratch + abi.cursor.viewportX) : 0;
    cursor.y = hasValue ? this.context.readU16(this.scratch + abi.cursor.viewportY) : 0;
    cursor.wideTail = hasValue
      ? this.context.readBool(this.scratch + abi.cursor.wideTail)
      : false;
    cursor.visible = this.context.readBool(this.scratch + abi.cursor.visible);
    cursor.blinking = this.context.readBool(this.scratch + abi.cursor.blinking);
    cursor.passwordInput = this.context.readBool(
      this.scratch + abi.cursor.passwordInput,
    );
    cursor.style = this.cursorStyle(
      this.context.readI32(this.scratch + abi.cursor.visualStyle),
    );
  }

  private cursorStyle(value: number): CursorStyle {
    const { cursorVisualStyle } = this.context.abi;
    if (value === cursorVisualStyle.bar) return "bar";
    if (value === cursorVisualStyle.underline) return "underline";
    if (value === cursorVisualStyle.hollowBlock) return "hollow_block";
    return "block";
  }

  /**
   * Colours the PROGRAM set with OSC 10 / 11 / 12, and nothing else.
   *
   * This reads the TERMINAL's colours, not the render state's. The terminal is
   * constructed without any default foreground, background, or cursor colour,
   * and the getter documents that it returns NO_VALUE "if no color is
   * configured (neither a default nor an OSC override)". So a value here means
   * a program asked for it, which is program intent and is honoured; absence
   * means the viewer's Palette decides. The render state's own colours would
   * answer with the engine's built-in defaults, which are exactly the
   * presentation-boundary values this binding must never pass on.
   *
   * `GhosttyRenderStateColors.palette[256]` is never read at all.
   */
  private readOverrides(overrides: ColorOverrides): void {
    const { abi } = this.context;
    const foreground = this.readTerminalColor(abi.terminalData.colorForeground);
    const background = this.readTerminalColor(abi.terminalData.colorBackground);
    const cursor = this.readTerminalColor(abi.terminalData.colorCursor);
    if (foreground === null) delete overrides.foreground;
    else overrides.foreground = foreground;
    if (background === null) delete overrides.background;
    else overrides.background = background;
    if (cursor === null) delete overrides.cursor;
    else overrides.cursor = cursor;
  }

  private readTerminalColor(data: number): Rgb | null {
    const { exports, abi } = this.context;
    const code = exports.ghostty_terminal_get(this.terminal, data, this.scratch);
    if (!this.context.hasValue("ghostty_terminal_get(COLOR)", code)) return null;
    return {
      r: this.context.readU8(this.scratch + abi.colorRgb.r),
      g: this.context.readU8(this.scratch + abi.colorRgb.g),
      b: this.context.readU8(this.scratch + abi.colorRgb.b),
    };
  }

  private readRows(frame: RenderFrame): void {
    const { exports, abi } = this.context;
    if (frame.dirty === "none") {
      // Nothing changed; the pool still describes the last frame and the
      // renderer is told so by `dirty`.
      for (const row of this.rowPool) row.dirty = false;
      return;
    }

    // The iterator object is pre-allocated and re-pointed at each snapshot by
    // passing the slot that holds its handle.
    this.context.writeU32(this.slot, this.rowIterator);
    this.context.check(
      "ghostty_render_state_get(ROW_ITERATOR)",
      exports.ghostty_render_state_get(
        this.renderState,
        abi.renderStateData.rowIterator,
        this.slot,
      ),
    );

    const full = frame.dirty === "full";
    let y = 0;
    while (exports.ghostty_render_state_row_iterator_next(this.rowIterator) !== 0) {
      const row = this.rowAt(y, frame.cols);
      this.context.check(
        "ghostty_render_state_row_get(DIRTY)",
        exports.ghostty_render_state_row_get(
          this.rowIterator,
          abi.rowData.dirty,
          this.scratch,
        ),
      );
      row.dirty = full || this.context.readBool(this.scratch);
      this.readSelection(row);
      if (row.dirty) {
        this.readRowCells(row, frame.cols);
      }
      y += 1;
    }
    // A shrunk viewport leaves stale rows in the pool; drop them so `rows_`
    // never describes a row the render state no longer has.
    if (this.rowPool.length > y) this.rowPool.length = y;
  }

  private rowAt(y: number, cols: number): RowView {
    let row = this.rowPool[y];
    if (row === undefined) {
      row = { y, dirty: true, cells: [] };
      this.rowPool[y] = row;
    }
    row.y = y;
    const cells = row.cells;
    while (cells.length < cols) {
      cells.push({
        codepoint: 0,
        foreground: DEFAULT_COLOR,
        background: DEFAULT_COLOR,
        attributes: 0,
        selected: false,
      });
    }
    if (cells.length > cols) cells.length = cols;
    return row;
  }

  private readSelection(row: RowView): void {
    const { exports, abi } = this.context;
    this.context.writeUsize(
      this.scratch + abi.rowSelection.sizeField,
      abi.rowSelection.size,
    );
    const code = exports.ghostty_render_state_row_get(
      this.rowIterator,
      abi.rowData.selection,
      this.scratch,
    );
    if (!this.context.hasValue("ghostty_render_state_row_get(SELECTION)", code)) {
      delete row.selection;
      return;
    }
    const start = this.context.readU16(this.scratch + abi.rowSelection.startX);
    // render.h reports an inclusive end column; the seam's range is half-open.
    const end = this.context.readU16(this.scratch + abi.rowSelection.endX) + 1;
    row.selection = { start, end };
  }

  private readRowCells(row: RowView, cols: number): void {
    const { exports, abi } = this.context;

    // The bulk path: one call for the whole row. render.h documents CELLS_RAW
    // as the read "for callers with expensive call boundaries (e.g.
    // WebAssembly embedders)", which is this caller exactly.
    this.context.check(
      "ghostty_render_state_row_get(CELLS_RAW)",
      exports.ghostty_render_state_row_get(
        this.rowIterator,
        abi.rowData.cellsRaw,
        this.scratch,
      ),
    );
    const cellsPointer = this.context.readU32(this.scratch + abi.cellsView.ptr);
    const available = this.context.readUsize(this.scratch + abi.cellsView.len);
    const count = Math.min(available, cols);

    this.styleCache.clear();
    let cellsHandleReady = false;
    const selection = row.selection;

    for (let x = 0; x < count; x += 1) {
      // The view is refetched per cell because reading a style or a grapheme
      // calls back into Wasm, and any such call may have grown memory.
      const view = this.context.mem.view();
      const base = cellsPointer + x * abi.cellSize;
      const low = view.getUint32(base, true);
      const high = view.getUint32(base + 4, true);

      const cell = row.cells[x];
      if (cell === undefined) continue;
      const styleId = this.decodeRawCell(low, high, cell);

      if (styleId !== 0) {
        if (!cellsHandleReady) {
          this.pointCellIteratorAtRow();
          cellsHandleReady = true;
        }
        this.applyStyle(cell, x, styleId);
      }

      if (this.needsGrapheme(low, high)) {
        if (!cellsHandleReady) {
          this.pointCellIteratorAtRow();
          cellsHandleReady = true;
        }
        const text = this.readGrapheme(x);
        if (text !== null && cell.codepoint !== 0) cell.grapheme = text;
      }

      cell.selected =
        selection !== undefined && x >= selection.start && x < selection.end;
    }

    for (let x = count; x < cols; x += 1) {
      const cell = row.cells[x];
      if (cell === undefined) continue;
      resetCell(cell);
    }
  }

  private pointCellIteratorAtRow(): void {
    const { exports, abi } = this.context;
    this.context.writeU32(this.slot, this.cellIterator);
    this.context.check(
      "ghostty_render_state_row_get(CELLS)",
      exports.ghostty_render_state_row_get(
        this.rowIterator,
        abi.rowData.cells,
        this.slot,
      ),
    );
  }

  /**
   * Decode the packed cell. Returns the style id, which is zero for a cell that
   * carries no style — the same cheap predicate `…_DATA_HAS_STYLING` answers,
   * without paying a call across the boundary for every cell on the screen.
   */
  private decodeRawCell(low: number, high: number, cell: CellView): number {
    const { cell: bits, cellContentTag, cellWide } = this.context.abi;
    resetCell(cell);

    const contentTag = extract(low, high, bits.contentTag);
    const content = bits.content;
    if (contentTag === cellContentTag.codepoint) {
      cell.codepoint = extractInContent(low, high, content, bits.codepointInContent);
    } else if (contentTag === cellContentTag.codepointGrapheme) {
      cell.codepoint = extractInContent(
        low,
        high,
        content,
        bits.graphemeCodepointInContent,
      );
    } else if (contentTag === cellContentTag.bgColorPalette) {
      cell.background = {
        tag: "palette",
        index: extractInContent(low, high, content, bits.paletteInContent),
      };
    } else if (contentTag === cellContentTag.bgColorRgb) {
      cell.background = {
        tag: "rgb",
        r: extractInContent(low, high, content, bits.rgbInContent.r),
        g: extractInContent(low, high, content, bits.rgbInContent.g),
        b: extractInContent(low, high, content, bits.rgbInContent.b),
      };
    }

    const wide = extract(low, high, bits.wide);
    if (wide === cellWide.wide) cell.attributes |= ATTR.WIDE;
    else if (wide === cellWide.spacerTail || wide === cellWide.spacerHead) {
      cell.attributes |= ATTR.WIDE_SPACER;
    }

    return extract(low, high, bits.styleId);
  }

  private needsGrapheme(low: number, high: number): boolean {
    const { cell: bits, cellContentTag } = this.context.abi;
    return extract(low, high, bits.contentTag) === cellContentTag.codepointGrapheme;
  }

  private applyStyle(cell: CellView, x: number, styleId: number): void {
    const style = this.styleFor(x, styleId);

    // A cell whose content tag carried a background keeps it: the background
    // lives in the cell, not the style, and the cell wins. Same order as
    // termiod's `cell_from_parts`.
    const cellBackground = cell.background;
    let foreground = style.foreground;
    let background =
      cellBackground.tag === "default" ? style.background : cellBackground;

    if (style.inverse) {
      const swap = foreground;
      foreground = background;
      background = swap;
    }
    cell.foreground = foreground;
    cell.background = background;
    cell.attributes |= style.attributes;
    if (style.underline !== null) cell.underline = style.underline;
    else delete cell.underline;
    if (style.invisible) {
      cell.codepoint = 0;
      delete cell.grapheme;
    }
  }

  /**
   * Styles are cached for the duration of one row. A row lives in one page and
   * a style id is a page-local index, so two rows may use the same id for
   * different styles — which is why this cache is cleared per row and not per
   * frame.
   */
  private styleFor(x: number, styleId: number): StyleRead {
    const cached = this.styleCache.get(styleId);
    if (cached !== undefined) return cached;
    const style = this.readStyle(x);
    this.styleCache.set(styleId, style);
    return style;
  }

  private readStyle(x: number): StyleRead {
    const { exports, abi } = this.context;
    this.context.check(
      "ghostty_render_state_row_cells_select",
      exports.ghostty_render_state_row_cells_select(this.cellIterator, x),
    );
    this.context.writeUsize(this.scratch + abi.style.sizeField, abi.style.size);
    this.context.check(
      "ghostty_render_state_row_cells_get(STYLE)",
      exports.ghostty_render_state_row_cells_get(
        this.cellIterator,
        abi.rowCellsData.style,
        this.scratch,
      ),
    );

    let attributes = 0;
    if (this.context.readBool(this.scratch + abi.style.bold)) attributes |= ATTR.BOLD;
    if (this.context.readBool(this.scratch + abi.style.faint)) attributes |= ATTR.FAINT;
    if (this.context.readBool(this.scratch + abi.style.italic)) attributes |= ATTR.ITALIC;
    if (this.context.readBool(this.scratch + abi.style.blink)) attributes |= ATTR.BLINK;
    if (this.context.readBool(this.scratch + abi.style.strikethrough)) {
      attributes |= ATTR.STRIKETHROUGH;
    }
    if (this.context.readBool(this.scratch + abi.style.overline)) {
      attributes |= ATTR.OVERLINE;
    }
    const underline = this.context.readI32(this.scratch + abi.style.underline);
    if (underline === abi.sgrUnderline.curly) attributes |= ATTR.UNDERCURL;
    else if (underline !== abi.sgrUnderline.none) attributes |= ATTR.UNDERLINE;

    const underlineColor = this.readStyleColor(this.scratch + abi.style.underlineColor);
    return {
      foreground: this.readStyleColor(this.scratch + abi.style.foreground),
      background: this.readStyleColor(this.scratch + abi.style.background),
      underline: underlineColor.tag === "default" ? null : underlineColor,
      attributes,
      inverse: this.context.readBool(this.scratch + abi.style.inverse),
      invisible: this.context.readBool(this.scratch + abi.style.invisible),
    };
  }

  /**
   * A colour SLOT. `GHOSTTY_STYLE_COLOR_{NONE,PALETTE,RGB}` maps one-for-one
   * onto the seam's TaggedColor, and the palette index is passed through
   * UNRESOLVED: only a renderer holding the viewer's Palette may turn it into
   * a pixel.
   */
  private readStyleColor(pointer: number): TaggedColor {
    const { abi } = this.context;
    const tag = this.context.readI32(pointer + abi.styleColor.tag);
    if (tag === abi.styleColorTag.palette) {
      return {
        tag: "palette",
        index: this.context.readU8(pointer + abi.styleColor.paletteValue),
      };
    }
    if (tag === abi.styleColorTag.rgb) {
      const base = pointer + abi.styleColor.rgbValue;
      return {
        tag: "rgb",
        r: this.context.readU8(base + abi.colorRgb.r),
        g: this.context.readU8(base + abi.colorRgb.g),
        b: this.context.readU8(base + abi.colorRgb.b),
      };
    }
    return DEFAULT_COLOR;
  }

  private readGrapheme(x: number): string | null {
    const { exports, abi, mem } = this.context;
    this.context.check(
      "ghostty_render_state_row_cells_select",
      exports.ghostty_render_state_row_cells_select(this.cellIterator, x),
    );

    for (let attempt = 0; attempt < 2; attempt += 1) {
      this.context.writeU32(this.scratch + abi.buffer.ptr, this.graphemeBuffer);
      this.context.writeUsize(this.scratch + abi.buffer.cap, this.graphemeCapacity);
      this.context.writeUsize(this.scratch + abi.buffer.len, 0);
      const code = exports.ghostty_render_state_row_cells_get(
        this.cellIterator,
        abi.rowCellsData.graphemesUtf8,
        this.scratch,
      );
      if (code === abi.result.success) {
        const length = this.context.readUsize(this.scratch + abi.buffer.len);
        const pointer = this.context.readU32(this.scratch + abi.buffer.ptr);
        return length === 0 ? null : mem.decodeUtf8(pointer, length);
      }
      if (code !== abi.result.outOfSpace) {
        this.context.check(
          "ghostty_render_state_row_cells_get(GRAPHEMES_UTF8)",
          code,
        );
        return null;
      }
      // OUT_OF_SPACE reports the required length in `len`.
      const required = this.context.readUsize(this.scratch + abi.buffer.len);
      mem.free(this.graphemeBuffer, this.graphemeCapacity);
      this.graphemeCapacity = Math.max(required, this.graphemeCapacity * 2);
      this.graphemeBuffer = mem.alloc(this.graphemeCapacity);
    }
    return null;
  }
}

function resetCell(cell: CellView): void {
  cell.codepoint = 0;
  cell.foreground = DEFAULT_COLOR;
  cell.background = DEFAULT_COLOR;
  cell.attributes = 0;
  cell.selected = false;
  delete cell.grapheme;
  delete cell.underline;
}

function extract(
  low: number,
  high: number,
  field: { lsb: number; width: number },
): number {
  return extractBits(low, high, field.lsb, field.width);
}

function extractInContent(
  low: number,
  high: number,
  content: { lsb: number; width: number },
  field: { lsb: number; width: number },
): number {
  // Arm bit positions are relative to the union's own value, so the two
  // offsets add. The union is at most 32 bits wide inside the cell, which
  // keeps this in Number range without a BigInt.
  return extractBits(low, high, content.lsb + field.lsb, field.width);
}
