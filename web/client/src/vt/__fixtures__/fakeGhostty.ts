/**
 * A stand-in for `ghostty-vt.wasm` that speaks the same C ABI.
 *
 * The real Wasm is a build artifact placed in the web root by the deploy
 * tooling; it is not in the repository and CI has no zig toolchain, so the
 * binding is tested against this instead. What matters is that the parts that
 * can be wrong here are the parts the binding is responsible for:
 *
 *  - It runs on a real `WebAssembly.Memory` and really grows it on write, so a
 *    typed array cached across a call really is detached.
 *  - It lays its structs out at exactly the offsets its manifest publishes, so
 *    a binding that hardcodes an offset fails.
 *  - It returns INVALID_VALUE if the render state is read before
 *    `end_update`, so the two-phase bracket is enforced rather than assumed.
 *  - It refuses a `ghostty_wasm_free` with the wrong length, so the wasm.h
 *    allocation contract is checked instead of trusted.
 *
 * It is not a terminal emulator. Its VT parsing covers what the tests write.
 */

import type { GhosttyExports } from "../exports";
import { buildLayouts, buildManifest, CELL_BITS, ENUMS, type Layouts } from "./layout";

const PAGE_BYTES = 65536;
const NULL = 0;

type FakeColor =
  | { tag: "none" }
  | { tag: "palette"; index: number }
  | { tag: "rgb"; r: number; g: number; b: number };

export interface FakeStyle {
  fg: FakeColor;
  bg: FakeColor;
  underlineColor: FakeColor;
  bold: boolean;
  italic: boolean;
  faint: boolean;
  blink: boolean;
  inverse: boolean;
  invisible: boolean;
  strikethrough: boolean;
  overline: boolean;
  underline: number;
}

export interface FakeCell {
  contentTag: number;
  codepoint: number;
  palette: number;
  rgb: { r: number; g: number; b: number };
  styleId: number;
  wide: number;
  grapheme: string | null;
}

export interface FakeTerminal {
  cols: number;
  rows: number;
  cells: FakeCell[][];
  styles: Map<number, FakeStyle>;
  nextStyleId: number;
  currentStyleId: number;
  cursor: {
    x: number;
    y: number;
    hasValue: boolean;
    wideTail: boolean;
    visible: boolean;
    blinking: boolean;
    passwordInput: boolean;
    visualStyle: number;
  };
  title: string | null;
  colorForeground: { r: number; g: number; b: number } | null;
  colorBackground: { r: number; g: number; b: number } | null;
  colorCursor: { r: number; g: number; b: number } | null;
  modes: Map<number, boolean>;
  kittyFlags: number;
  scrollbackBytes: number;
  fullDirty: boolean;
  dirtyRows: Set<number>;
  selection: { row: number; start: number; end: number } | null;
}

interface FakeRenderState {
  terminal: FakeTerminal | null;
  ready: boolean;
  dirty: number;
  dirtyRows: Set<number>;
  cellsScratch: number;
  cellsScratchBytes: number;
}

interface FakeRowIterator {
  state: FakeRenderState | null;
  y: number;
}

interface FakeCellIterator {
  state: FakeRenderState | null;
  y: number;
  x: number;
}

interface FakeKeyEncoder {
  cursorKeyApplication: boolean;
  keypadKeyApplication: boolean;
  altEscPrefix: boolean;
  kittyFlags: number;
}

interface FakeKeyEvent {
  action: number;
  key: number;
  mods: number;
  consumedMods: number;
  composing: boolean;
  utf8: string;
  unshiftedCodepoint: number;
}

export interface FakeGhostty {
  exports: GhosttyExports;
  layouts: Layouts;
  memory: WebAssembly.Memory;
  terminal(handle: number): FakeTerminal;
  keyEncoder(handle: number): FakeKeyEncoder;
  keyEvent(handle: number): FakeKeyEvent;
  /** Every terminal created so far, in creation order. */
  terminals(): FakeTerminal[];
  liveAllocations(): number;
  growCount(): number;
  poke(terminal: FakeTerminal, y: number, x: number, cell: Partial<FakeCell>): void;
  defineStyle(terminal: FakeTerminal, style: Partial<FakeStyle>): number;
  markDirty(terminal: FakeTerminal, y: number): void;
}

export interface FakeOptions {
  /** Extra leading padding in every sized struct; shifts every offset. */
  padding?: number;
  /** Grow linear memory on every vt_write, detaching any cached view. */
  growOnWrite?: boolean;
  /**
   * Grow linear memory on every allocation, including the ones a frame read
   * makes for itself. This is the mid-frame detach: it happens between the
   * bulk cell read and the style read, which is exactly where a cached view
   * would be used.
   */
  growOnAlloc?: boolean;
}

export function createFakeGhostty(options: FakeOptions = {}): FakeGhostty {
  const growOnWrite = options.growOnWrite ?? true;
  const growOnAlloc = options.growOnAlloc ?? false;
  const layouts = buildLayouts(options.padding ?? 0);
  const memory = new WebAssembly.Memory({ initial: 2 });

  let bump = 1024;
  let growCount = 0;
  // The manifest is written before any binding exists; growing under it would
  // only move the fixture's own bytes around.
  let manifestReady = false;
  const allocations = new Map<number, number>();

  function bytes(): Uint8Array {
    return new Uint8Array(memory.buffer);
  }
  function view(): DataView {
    return new DataView(memory.buffer);
  }
  function grow(pages: number): void {
    memory.grow(pages);
    growCount += 1;
  }
  function alloc(length: number): number {
    if (length === 0) return NULL;
    const size = (length + 15) & ~15;
    if (bump + size > memory.buffer.byteLength) {
      grow(Math.ceil((bump + size - memory.buffer.byteLength) / PAGE_BYTES) + 1);
    }
    const pointer = bump;
    bump += size;
    allocations.set(pointer, length);
    bytes().fill(0, pointer, pointer + size);
    if (growOnAlloc && manifestReady) grow(1);
    return pointer;
  }
  function free(pointer: number, length: number): void {
    if (pointer === NULL) return;
    const recorded = allocations.get(pointer);
    if (recorded === undefined) {
      throw new Error(`fake ghostty: free of unknown pointer ${pointer}`);
    }
    if (recorded !== length) {
      throw new Error(
        `fake ghostty: free(${pointer}, ${length}) but it was allocated with ${recorded}`,
      );
    }
    allocations.delete(pointer);
  }

  const manifest = buildManifest(layouts);
  const manifestBytes = new TextEncoder().encode(manifest);
  const manifestPointer = alloc(manifestBytes.length + 1);
  bytes().set(manifestBytes, manifestPointer);
  // The manifest allocation is permanent; drop it from the ledger so a test
  // asserting "everything was freed" is not tripped by it.
  allocations.delete(manifestPointer);
  manifestReady = true;

  const handles = new Map<number, unknown>();
  let nextHandle = 0x1000;
  function store(value: unknown): number {
    const handle = nextHandle;
    nextHandle += 8;
    handles.set(handle, value);
    return handle;
  }
  function load<T>(handle: number, what: string): T {
    const value = handles.get(handle);
    if (value === undefined) {
      throw new Error(`fake ghostty: ${what} handle ${handle} is not live`);
    }
    return value as T;
  }

  const createdTerminals: FakeTerminal[] = [];

  function blankCell(): FakeCell {
    return {
      contentTag: ENUMS.GhosttyCellContentTag.CODEPOINT,
      codepoint: 0,
      palette: 0,
      rgb: { r: 0, g: 0, b: 0 },
      styleId: 0,
      wide: ENUMS.GhosttyCellWide.NARROW,
      grapheme: null,
    };
  }

  function makeGrid(rows: number, cols: number): FakeCell[][] {
    return Array.from({ length: rows }, () =>
      Array.from({ length: cols }, blankCell),
    );
  }

  function newTerminal(cols: number, rows: number): FakeTerminal {
    return {
      cols,
      rows,
      cells: makeGrid(rows, cols),
      styles: new Map(),
      nextStyleId: 1,
      currentStyleId: 0,
      cursor: {
        x: 0,
        y: 0,
        hasValue: true,
        wideTail: false,
        visible: true,
        blinking: true,
        passwordInput: false,
        visualStyle: ENUMS.GhosttyRenderStateCursorVisualStyle.BLOCK,
      },
      title: null,
      colorForeground: null,
      colorBackground: null,
      colorCursor: null,
      modes: new Map(),
      kittyFlags: 0,
      scrollbackBytes: 0,
      fullDirty: true,
      dirtyRows: new Set(),
      selection: null,
    };
  }

  function defaultStyle(): FakeStyle {
    return {
      fg: { tag: "none" },
      bg: { tag: "none" },
      underlineColor: { tag: "none" },
      bold: false,
      italic: false,
      faint: false,
      blink: false,
      inverse: false,
      invisible: false,
      strikethrough: false,
      overline: false,
      underline: ENUMS.GhosttySgrUnderline.NONE,
    };
  }

  function styleKey(style: FakeStyle): string {
    return JSON.stringify(style);
  }

  function internStyle(terminal: FakeTerminal, style: FakeStyle): number {
    if (styleKey(style) === styleKey(defaultStyle())) return 0;
    for (const [id, existing] of terminal.styles) {
      if (styleKey(existing) === styleKey(style)) return id;
    }
    const id = terminal.nextStyleId;
    terminal.nextStyleId += 1;
    terminal.styles.set(id, style);
    return id;
  }

  function currentStyle(terminal: FakeTerminal): FakeStyle {
    const style = terminal.styles.get(terminal.currentStyleId);
    return style === undefined ? defaultStyle() : { ...style };
  }

  function markDirty(terminal: FakeTerminal, y: number): void {
    terminal.dirtyRows.add(y);
  }

  function packCell(cell: FakeCell): { low: number; high: number } {
    let low = 0;
    let high = 0;
    const put = (lsb: number, width: number, value: number): void => {
      const masked = width === 32 ? value >>> 0 : value & ((1 << width) - 1);
      if (lsb >= 32) {
        high |= masked << (lsb - 32);
        high >>>= 0;
        return;
      }
      const room = 32 - lsb;
      if (width <= room) {
        low = (low | (masked << lsb)) >>> 0;
        return;
      }
      low = (low | ((masked % 2 ** room) * 2 ** lsb)) >>> 0;
      high = (high | Math.floor(masked / 2 ** room)) >>> 0;
    };

    put(CELL_BITS.content_tag.lsb, CELL_BITS.content_tag.width, cell.contentTag);
    const contentLsb = CELL_BITS.content.lsb;
    if (
      cell.contentTag === ENUMS.GhosttyCellContentTag.CODEPOINT ||
      cell.contentTag === ENUMS.GhosttyCellContentTag.CODEPOINT_GRAPHEME
    ) {
      put(contentLsb, 21, cell.codepoint);
    } else if (cell.contentTag === ENUMS.GhosttyCellContentTag.BG_COLOR_PALETTE) {
      put(contentLsb, 8, cell.palette);
    } else {
      put(contentLsb + 0, 8, cell.rgb.r);
      put(contentLsb + 8, 8, cell.rgb.g);
      put(contentLsb + 16, 8, cell.rgb.b);
    }
    put(CELL_BITS.style_id.lsb, CELL_BITS.style_id.width, cell.styleId);
    put(CELL_BITS.wide.lsb, CELL_BITS.wide.width, cell.wide);
    return { low, high };
  }

  function writeColor(pointer: number, color: { r: number; g: number; b: number }): void {
    const data = view();
    data.setUint8(pointer + layouts.colorRgb.offsets["r"]!, color.r);
    data.setUint8(pointer + layouts.colorRgb.offsets["g"]!, color.g);
    data.setUint8(pointer + layouts.colorRgb.offsets["b"]!, color.b);
  }

  function writeStyleColor(pointer: number, color: FakeColor): void {
    const data = view();
    const tagOffset = layouts.styleColor.offsets["tag"]!;
    const valueOffset = layouts.styleColor.offsets["value"]!;
    if (color.tag === "palette") {
      data.setInt32(pointer + tagOffset, ENUMS.GhosttyStyleColorTag.PALETTE, true);
      data.setUint8(
        pointer + valueOffset + layouts.styleColorValue.offsets["palette"]!,
        color.index,
      );
      return;
    }
    if (color.tag === "rgb") {
      data.setInt32(pointer + tagOffset, ENUMS.GhosttyStyleColorTag.RGB, true);
      writeColor(pointer + valueOffset, color);
      return;
    }
    data.setInt32(pointer + tagOffset, ENUMS.GhosttyStyleColorTag.NONE, true);
  }

  function parseVt(terminal: FakeTerminal, text: string): void {
    let index = 0;
    const advance = (): void => {
      terminal.cursor.x += 1;
      if (terminal.cursor.x >= terminal.cols) {
        terminal.cursor.x = 0;
        terminal.cursor.y = Math.min(terminal.cursor.y + 1, terminal.rows - 1);
      }
    };
    while (index < text.length) {
      const character = text[index]!;
      if (character === "\x1b") {
        index = parseEscape(terminal, text, index);
        continue;
      }
      index += 1;
      if (character === "\n") {
        terminal.cursor.y = Math.min(terminal.cursor.y + 1, terminal.rows - 1);
        continue;
      }
      if (character === "\r") {
        terminal.cursor.x = 0;
        continue;
      }
      const row = terminal.cells[terminal.cursor.y];
      if (row === undefined) continue;
      const cell = row[terminal.cursor.x];
      if (cell === undefined) continue;
      cell.contentTag = ENUMS.GhosttyCellContentTag.CODEPOINT;
      cell.codepoint = character.codePointAt(0) ?? 0;
      cell.styleId = terminal.currentStyleId;
      cell.grapheme = null;
      markDirty(terminal, terminal.cursor.y);
      advance();
    }
  }

  function parseEscape(terminal: FakeTerminal, text: string, start: number): number {
    const next = text[start + 1];
    if (next === "[") {
      let index = start + 2;
      let parameters = "";
      while (index < text.length && !/[a-zA-Z]/.test(text[index]!)) {
        parameters += text[index];
        index += 1;
      }
      const final = text[index] ?? "";
      index += 1;
      applyCsi(terminal, parameters, final);
      return index;
    }
    if (next === "]") {
      let index = start + 2;
      let body = "";
      while (index < text.length && text[index] !== "\x07") {
        body += text[index];
        index += 1;
      }
      index += 1;
      applyOsc(terminal, body);
      return index;
    }
    return start + 1;
  }

  function applyCsi(terminal: FakeTerminal, parameters: string, final: string): void {
    if (parameters.startsWith("?") && (final === "h" || final === "l")) {
      for (const raw of parameters.slice(1).split(";")) {
        const mode = Number.parseInt(raw, 10);
        if (Number.isFinite(mode)) terminal.modes.set(mode, final === "h");
      }
      return;
    }
    if (final === "m") {
      applySgr(terminal, parameters);
      return;
    }
    if (final === "H") {
      const [row = "1", column = "1"] = parameters.split(";");
      terminal.cursor.y = Math.max(0, Number.parseInt(row, 10) - 1);
      terminal.cursor.x = Math.max(0, Number.parseInt(column, 10) - 1);
      return;
    }
    if (final === "J") {
      terminal.cells = makeGrid(terminal.rows, terminal.cols);
      terminal.fullDirty = true;
    }
  }

  function applySgr(terminal: FakeTerminal, parameters: string): void {
    const style = currentStyle(terminal);
    const codes = (parameters === "" ? "0" : parameters)
      .split(";")
      .map((value) => Number.parseInt(value, 10));
    for (let index = 0; index < codes.length; index += 1) {
      const code = codes[index]!;
      if (code === 0) Object.assign(style, defaultStyle());
      else if (code === 1) style.bold = true;
      else if (code === 2) style.faint = true;
      else if (code === 3) style.italic = true;
      else if (code === 4) style.underline = ENUMS.GhosttySgrUnderline.SINGLE;
      else if (code === 5) style.blink = true;
      else if (code === 7) style.inverse = true;
      else if (code === 8) style.invisible = true;
      else if (code === 9) style.strikethrough = true;
      else if (code === 53) style.overline = true;
      else if (code >= 30 && code <= 37) style.fg = { tag: "palette", index: code - 30 };
      else if (code === 39) style.fg = { tag: "none" };
      else if (code >= 40 && code <= 47) style.bg = { tag: "palette", index: code - 40 };
      else if (code === 49) style.bg = { tag: "none" };
      else if (code === 38 || code === 48 || code === 58) {
        const kind = codes[index + 1];
        const target: FakeColor =
          kind === 5
            ? { tag: "palette", index: codes[index + 2] ?? 0 }
            : {
                tag: "rgb",
                r: codes[index + 2] ?? 0,
                g: codes[index + 3] ?? 0,
                b: codes[index + 4] ?? 0,
              };
        if (code === 38) style.fg = target;
        else if (code === 48) style.bg = target;
        else style.underlineColor = target;
        index += kind === 5 ? 2 : 4;
      }
    }
    terminal.currentStyleId = internStyle(terminal, style);
  }

  function applyOsc(terminal: FakeTerminal, body: string): void {
    const separator = body.indexOf(";");
    if (separator < 0) return;
    const command = body.slice(0, separator);
    const value = body.slice(separator + 1);
    if (command === "0" || command === "2") {
      terminal.title = value;
      return;
    }
    const color = parseOscColor(value);
    if (color === null) return;
    if (command === "10") terminal.colorForeground = color;
    else if (command === "11") terminal.colorBackground = color;
    else if (command === "12") terminal.colorCursor = color;
  }

  function parseOscColor(
    value: string,
  ): { r: number; g: number; b: number } | null {
    const hex = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(value);
    if (hex === null) return null;
    return {
      r: Number.parseInt(hex[1]!, 16),
      g: Number.parseInt(hex[2]!, 16),
      b: Number.parseInt(hex[3]!, 16),
    };
  }

  const decoder = new TextDecoder();
  const encoder = new TextEncoder();

  function encodeKey(encoderState: FakeKeyEncoder, event: FakeKeyEvent): string {
    const keys = ENUMS.GhosttyKey;
    if (event.action === ENUMS.GhosttyKeyAction.RELEASE && encoderState.kittyFlags === 0) {
      return "";
    }
    if (event.key === keys.ENTER) return "\r";
    if (event.key === keys.TAB) return "\t";
    if (event.key === keys.BACKSPACE) return "\x7f";
    if (event.key === keys.ESCAPE) return "\x1b";
    const arrows: Record<number, string> = {
      [keys.ARROW_UP]: "A",
      [keys.ARROW_DOWN]: "B",
      [keys.ARROW_RIGHT]: "C",
      [keys.ARROW_LEFT]: "D",
    };
    const arrow = arrows[event.key];
    if (arrow !== undefined) {
      return encoderState.cursorKeyApplication ? `\x1bO${arrow}` : `\x1b[${arrow}`;
    }
    const ctrl = (event.mods & 0b10) !== 0;
    const alt = (event.mods & 0b100) !== 0;
    if (ctrl && event.utf8.length === 1) {
      const code = event.utf8.charCodeAt(0);
      if (code >= 0x40 && code <= 0x7f) {
        return String.fromCharCode(code & 0x1f);
      }
    }
    if (event.utf8.length === 0) return "";
    if (alt && encoderState.altEscPrefix) return `\x1b${event.utf8}`;
    return event.utf8;
  }

  function writeOut(
    text: string,
    buffer: number,
    capacity: number,
    writtenSlot: number,
  ): number {
    const encoded = encoder.encode(text);
    if (encoded.length > capacity) {
      view().setUint32(writtenSlot, encoded.length, true);
      return ENUMS.GhosttyResult.OUT_OF_SPACE;
    }
    if (encoded.length > 0) bytes().set(encoded, buffer);
    view().setUint32(writtenSlot, encoded.length, true);
    return ENUMS.GhosttyResult.SUCCESS;
  }

  const exports: GhosttyExports = {
    memory,

    ghostty_wasm_alloc: alloc,
    ghostty_wasm_free: free,
    ghostty_wasm_alloc_opaque: () => alloc(4),
    ghostty_wasm_free_opaque: (slot: number) => free(slot, 4),
    ghostty_wasm_take_opaque: (slot: number) => {
      const value = view().getUint32(slot, true);
      view().setUint32(slot, 0, true);
      return value;
    },

    ghostty_type_json: () => manifestPointer,

    ghostty_terminal_new: (_allocator, outTerminal, cols, rows) => {
      const terminal = newTerminal(cols, rows);
      createdTerminals.push(terminal);
      view().setUint32(outTerminal, store(terminal), true);
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_terminal_free: (handle) => {
      handles.delete(handle);
    },
    ghostty_terminal_resize: (handle, cols, rows) => {
      const terminal = load<FakeTerminal>(handle, "terminal");
      terminal.cols = cols;
      terminal.rows = rows;
      terminal.cells = makeGrid(rows, cols);
      terminal.cursor.x = Math.min(terminal.cursor.x, cols - 1);
      terminal.cursor.y = Math.min(terminal.cursor.y, rows - 1);
      terminal.fullDirty = true;
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_terminal_vt_write: (handle, data, length) => {
      const terminal = load<FakeTerminal>(handle, "terminal");
      const text = decoder.decode(bytes().subarray(data, data + length));
      parseVt(terminal, text);
      // The real thing allocates pages as the screen fills. Growing here is
      // what makes a cached view in the binding a detached view.
      if (growOnWrite) grow(1);
    },
    ghostty_terminal_set: (handle, option, value) => {
      const terminal = load<FakeTerminal>(handle, "terminal");
      if (option === ENUMS.GhosttyTerminalOption.SCROLLBACK_MAX_BYTES) {
        terminal.scrollbackBytes = view().getUint32(value, true);
        return ENUMS.GhosttyResult.SUCCESS;
      }
      return ENUMS.GhosttyResult.INVALID_VALUE;
    },
    ghostty_terminal_get: (handle, data, out) => {
      const terminal = load<FakeTerminal>(handle, "terminal");
      const results = ENUMS.GhosttyResult;
      const kinds = ENUMS.GhosttyTerminalData;
      if (data === kinds.TITLE) {
        if (terminal.title === null) return results.NO_VALUE;
        const encoded = encoder.encode(terminal.title);
        const pointer = alloc(encoded.length);
        bytes().set(encoded, pointer);
        allocations.delete(pointer); // borrowed by the caller, freed by nobody
        const data32 = view();
        data32.setUint32(out + layouts.string.offsets["ptr"]!, pointer, true);
        data32.setUint32(out + layouts.string.offsets["len"]!, encoded.length, true);
        return results.SUCCESS;
      }
      if (data === kinds.MODE) {
        const mode = view().getUint16(out + layouts.modeConfig.offsets["mode"]!, true);
        const value = terminal.modes.get(mode & 0x7fff) ?? false;
        view().setUint8(out + layouts.modeConfig.offsets["value"]!, value ? 1 : 0);
        return results.SUCCESS;
      }
      if (data === kinds.KITTY_KEYBOARD_FLAGS) {
        view().setUint8(out, terminal.kittyFlags);
        return results.SUCCESS;
      }
      const color =
        data === kinds.COLOR_FOREGROUND
          ? terminal.colorForeground
          : data === kinds.COLOR_BACKGROUND
            ? terminal.colorBackground
            : data === kinds.COLOR_CURSOR
              ? terminal.colorCursor
              : undefined;
      if (color === undefined) return results.INVALID_VALUE;
      if (color === null) return results.NO_VALUE;
      writeColor(out, color);
      return results.SUCCESS;
    },

    ghostty_render_state_new: (_allocator, outState) => {
      const state: FakeRenderState = {
        terminal: null,
        ready: false,
        dirty: ENUMS.GhosttyRenderStateDirty.FALSE,
        dirtyRows: new Set(),
        cellsScratch: NULL,
        cellsScratchBytes: 0,
      };
      view().setUint32(outState, store(state), true);
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_render_state_free: (handle) => {
      const state = handles.get(handle) as FakeRenderState | undefined;
      if (state !== undefined && state.cellsScratch !== NULL) {
        free(state.cellsScratch, state.cellsScratchBytes);
      }
      handles.delete(handle);
    },
    ghostty_render_state_begin_update: (stateHandle, terminalHandle) => {
      const state = load<FakeRenderState>(stateHandle, "render state");
      const terminal = load<FakeTerminal>(terminalHandle, "terminal");
      state.terminal = terminal;
      state.ready = false;
      if (terminal.fullDirty) state.dirty = ENUMS.GhosttyRenderStateDirty.FULL;
      else if (terminal.dirtyRows.size > 0 && state.dirty !== ENUMS.GhosttyRenderStateDirty.FULL) {
        state.dirty = ENUMS.GhosttyRenderStateDirty.PARTIAL;
      }
      for (const y of terminal.dirtyRows) state.dirtyRows.add(y);
      terminal.fullDirty = false;
      terminal.dirtyRows.clear();
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_render_state_end_update: (stateHandle) => {
      const state = load<FakeRenderState>(stateHandle, "render state");
      state.ready = true;
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_render_state_clean: (stateHandle) => {
      const state = load<FakeRenderState>(stateHandle, "render state");
      state.dirty = ENUMS.GhosttyRenderStateDirty.FALSE;
      state.dirtyRows.clear();
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_render_state_get: (stateHandle, data, out) => {
      const state = load<FakeRenderState>(stateHandle, "render state");
      const results = ENUMS.GhosttyResult;
      // render.h: "Every begin must be completed with end_update before the
      // render state is read."
      if (!state.ready || state.terminal === null) return results.INVALID_VALUE;
      const kinds = ENUMS.GhosttyRenderStateData;
      const data32 = view();
      if (data === kinds.DIRTY) {
        data32.setInt32(out, state.dirty, true);
        return results.SUCCESS;
      }
      if (data === kinds.COLS) {
        data32.setUint16(out, state.terminal.cols, true);
        return results.SUCCESS;
      }
      if (data === kinds.ROWS) {
        data32.setUint16(out, state.terminal.rows, true);
        return results.SUCCESS;
      }
      if (data === kinds.CURSOR) {
        const cursor = state.terminal.cursor;
        const offsets = layouts.cursor.offsets;
        if (data32.getUint32(out + offsets["size"]!, true) !== layouts.cursor.size) {
          return results.INVALID_VALUE;
        }
        data32.setUint8(out + offsets["viewport_has_value"]!, cursor.hasValue ? 1 : 0);
        data32.setUint16(out + offsets["viewport_x"]!, cursor.x, true);
        data32.setUint16(out + offsets["viewport_y"]!, cursor.y, true);
        data32.setUint8(out + offsets["wide_tail"]!, cursor.wideTail ? 1 : 0);
        data32.setUint8(out + offsets["visible"]!, cursor.visible ? 1 : 0);
        data32.setUint8(out + offsets["blinking"]!, cursor.blinking ? 1 : 0);
        data32.setUint8(out + offsets["password_input"]!, cursor.passwordInput ? 1 : 0);
        data32.setInt32(out + offsets["visual_style"]!, cursor.visualStyle, true);
        return results.SUCCESS;
      }
      if (data === kinds.ROW_ITERATOR) {
        const iterator = load<FakeRowIterator>(
          data32.getUint32(out, true),
          "row iterator",
        );
        iterator.state = state;
        iterator.y = -1;
        return results.SUCCESS;
      }
      return results.INVALID_VALUE;
    },

    ghostty_render_state_row_iterator_new: (_allocator, outIterator) => {
      const iterator: FakeRowIterator = { state: null, y: -1 };
      view().setUint32(outIterator, store(iterator), true);
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_render_state_row_iterator_free: (handle) => {
      handles.delete(handle);
    },
    ghostty_render_state_row_iterator_next: (handle) => {
      const iterator = load<FakeRowIterator>(handle, "row iterator");
      const terminal = iterator.state?.terminal;
      if (terminal === undefined || terminal === null) return 0;
      if (iterator.y + 1 >= terminal.rows) return 0;
      iterator.y += 1;
      return 1;
    },
    ghostty_render_state_row_get: (handle, data, out) => {
      const iterator = load<FakeRowIterator>(handle, "row iterator");
      const state = iterator.state;
      const terminal = state?.terminal;
      const results = ENUMS.GhosttyResult;
      if (state === null || terminal === undefined || terminal === null) {
        return results.INVALID_VALUE;
      }
      const kinds = ENUMS.GhosttyRenderStateRowData;
      const data32 = view();
      if (data === kinds.DIRTY) {
        data32.setUint8(out, state.dirtyRows.has(iterator.y) ? 1 : 0);
        return results.SUCCESS;
      }
      if (data === kinds.SELECTION) {
        const offsets = layouts.rowSelection.offsets;
        if (
          data32.getUint32(out + offsets["size"]!, true) !== layouts.rowSelection.size
        ) {
          return results.INVALID_VALUE;
        }
        const selection = terminal.selection;
        if (selection === null || selection.row !== iterator.y) return results.NO_VALUE;
        data32.setUint16(out + offsets["start_x"]!, selection.start, true);
        data32.setUint16(out + offsets["end_x"]!, selection.end, true);
        return results.SUCCESS;
      }
      if (data === kinds.CELLS) {
        const cells = load<FakeCellIterator>(data32.getUint32(out, true), "cell iterator");
        cells.state = state;
        cells.y = iterator.y;
        cells.x = 0;
        return results.SUCCESS;
      }
      if (data === kinds.CELLS_RAW) {
        const row = terminal.cells[iterator.y];
        if (row === undefined) return results.INVALID_VALUE;
        const needed = row.length * 8;
        if (state.cellsScratchBytes < needed) {
          if (state.cellsScratch !== NULL) {
            free(state.cellsScratch, state.cellsScratchBytes);
          }
          state.cellsScratch = alloc(needed);
          state.cellsScratchBytes = needed;
        }
        const writer = view();
        for (let x = 0; x < row.length; x += 1) {
          const packed = packCell(row[x]!);
          writer.setUint32(state.cellsScratch + x * 8, packed.low, true);
          writer.setUint32(state.cellsScratch + x * 8 + 4, packed.high, true);
        }
        const offsets = layouts.cellsView.offsets;
        writer.setUint32(out + offsets["ptr"]!, state.cellsScratch, true);
        writer.setUint32(out + offsets["len"]!, row.length, true);
        return results.SUCCESS;
      }
      return results.INVALID_VALUE;
    },

    ghostty_render_state_row_cells_new: (_allocator, outCells) => {
      const cells: FakeCellIterator = { state: null, y: 0, x: 0 };
      view().setUint32(outCells, store(cells), true);
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_render_state_row_cells_free: (handle) => {
      handles.delete(handle);
    },
    ghostty_render_state_row_cells_select: (handle, x) => {
      const cells = load<FakeCellIterator>(handle, "cell iterator");
      const terminal = cells.state?.terminal;
      if (terminal === undefined || terminal === null) {
        return ENUMS.GhosttyResult.INVALID_VALUE;
      }
      if (x >= terminal.cols) return ENUMS.GhosttyResult.INVALID_VALUE;
      cells.x = x;
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_render_state_row_cells_get: (handle, data, out) => {
      const cells = load<FakeCellIterator>(handle, "cell iterator");
      const terminal = cells.state?.terminal;
      const results = ENUMS.GhosttyResult;
      if (terminal === undefined || terminal === null) return results.INVALID_VALUE;
      const cell = terminal.cells[cells.y]?.[cells.x];
      if (cell === undefined) return results.INVALID_VALUE;
      const kinds = ENUMS.GhosttyRenderStateRowCellsData;
      const data32 = view();
      if (data === kinds.STYLE) {
        const offsets = layouts.style.offsets;
        if (data32.getUint32(out + offsets["size"]!, true) !== layouts.style.size) {
          return results.INVALID_VALUE;
        }
        const style = terminal.styles.get(cell.styleId) ?? defaultStyle();
        writeStyleColor(out + offsets["fg_color"]!, style.fg);
        writeStyleColor(out + offsets["bg_color"]!, style.bg);
        writeStyleColor(out + offsets["underline_color"]!, style.underlineColor);
        data32.setUint8(out + offsets["bold"]!, style.bold ? 1 : 0);
        data32.setUint8(out + offsets["italic"]!, style.italic ? 1 : 0);
        data32.setUint8(out + offsets["faint"]!, style.faint ? 1 : 0);
        data32.setUint8(out + offsets["blink"]!, style.blink ? 1 : 0);
        data32.setUint8(out + offsets["inverse"]!, style.inverse ? 1 : 0);
        data32.setUint8(out + offsets["invisible"]!, style.invisible ? 1 : 0);
        data32.setUint8(out + offsets["strikethrough"]!, style.strikethrough ? 1 : 0);
        data32.setUint8(out + offsets["overline"]!, style.overline ? 1 : 0);
        data32.setInt32(out + offsets["underline"]!, style.underline, true);
        return results.SUCCESS;
      }
      if (data === kinds.GRAPHEMES_UTF8) {
        const offsets = layouts.buffer.offsets;
        const pointer = data32.getUint32(out + offsets["ptr"]!, true);
        const capacity = data32.getUint32(out + offsets["cap"]!, true);
        const text = cell.grapheme ?? "";
        const encoded = encoder.encode(text);
        if (encoded.length > capacity) {
          data32.setUint32(out + offsets["len"]!, encoded.length, true);
          return results.OUT_OF_SPACE;
        }
        if (encoded.length > 0) bytes().set(encoded, pointer);
        data32.setUint32(out + offsets["len"]!, encoded.length, true);
        return results.SUCCESS;
      }
      // FG_COLOR and BG_COLOR are deliberately not implemented: reading them is
      // the presentation-boundary violation this client must never commit, so a
      // binding that tries gets INVALID_VALUE and a failing test.
      return results.INVALID_VALUE;
    },

    ghostty_key_encoder_new: (_allocator, outEncoder) => {
      const encoderState: FakeKeyEncoder = {
        cursorKeyApplication: false,
        keypadKeyApplication: false,
        altEscPrefix: false,
        kittyFlags: 0,
      };
      view().setUint32(outEncoder, store(encoderState), true);
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_key_encoder_free: (handle) => {
      handles.delete(handle);
    },
    ghostty_key_encoder_setopt: (handle, option, value) => {
      const encoderState = load<FakeKeyEncoder>(handle, "key encoder");
      const options = ENUMS.GhosttyKeyEncoderOption;
      const byte = view().getUint8(value);
      if (option === options.CURSOR_KEY_APPLICATION) {
        encoderState.cursorKeyApplication = byte !== 0;
      } else if (option === options.KEYPAD_KEY_APPLICATION) {
        encoderState.keypadKeyApplication = byte !== 0;
      } else if (option === options.ALT_ESC_PREFIX) {
        encoderState.altEscPrefix = byte !== 0;
      } else if (option === options.KITTY_FLAGS) {
        encoderState.kittyFlags = byte;
      }
    },
    ghostty_key_encoder_encode: (
      encoderHandle,
      eventHandle,
      outBuffer,
      outBufferSize,
      outLength,
    ) => {
      const encoderState = load<FakeKeyEncoder>(encoderHandle, "key encoder");
      const event = load<FakeKeyEvent>(eventHandle, "key event");
      return writeOut(
        encodeKey(encoderState, event),
        outBuffer,
        outBufferSize,
        outLength,
      );
    },

    ghostty_key_event_new: (_allocator, outEvent) => {
      const event: FakeKeyEvent = {
        action: ENUMS.GhosttyKeyAction.PRESS,
        key: ENUMS.GhosttyKey.UNIDENTIFIED,
        mods: 0,
        consumedMods: 0,
        composing: false,
        utf8: "",
        unshiftedCodepoint: 0,
      };
      view().setUint32(outEvent, store(event), true);
      return ENUMS.GhosttyResult.SUCCESS;
    },
    ghostty_key_event_free: (handle) => {
      handles.delete(handle);
    },
    ghostty_key_event_set_action: (handle, action) => {
      load<FakeKeyEvent>(handle, "key event").action = action;
    },
    ghostty_key_event_set_key: (handle, key) => {
      load<FakeKeyEvent>(handle, "key event").key = key;
    },
    ghostty_key_event_set_mods: (handle, mods) => {
      load<FakeKeyEvent>(handle, "key event").mods = mods;
    },
    ghostty_key_event_set_consumed_mods: (handle, mods) => {
      load<FakeKeyEvent>(handle, "key event").consumedMods = mods;
    },
    ghostty_key_event_set_composing: (handle, composing) => {
      load<FakeKeyEvent>(handle, "key event").composing = composing !== 0;
    },
    ghostty_key_event_set_utf8: (handle, pointer, length) => {
      const event = load<FakeKeyEvent>(handle, "key event");
      event.utf8 =
        pointer === NULL || length === 0
          ? ""
          : decoder.decode(bytes().subarray(pointer, pointer + length));
    },
    ghostty_key_event_set_unshifted_codepoint: (handle, codepoint) => {
      load<FakeKeyEvent>(handle, "key event").unshiftedCodepoint = codepoint;
    },

    ghostty_paste_encode: (data, dataLength, bracketed, buffer, bufferLength, outWritten) => {
      const raw =
        data === NULL || dataLength === 0
          ? ""
          : decoder.decode(bytes().subarray(data, data + dataLength));
      const safe = raw.replace(/[\x00\x1b\x7f]/g, " ");
      const text =
        bracketed !== 0
          ? `\x1b[200~${safe}\x1b[201~`
          : safe.replace(/\n/g, "\r");
      return writeOut(text, buffer, bufferLength, outWritten);
    },
  } as GhosttyExports;

  // `ghostty_render_state_row_cells_next` exists in the header and is
  // deliberately absent here: cells are read in bulk with CELLS_RAW and
  // positioned with `select`, so a binding that walked the per-cell iterator
  // would fail against this fixture rather than quietly costing a call per cell.

  return {
    exports,
    layouts,
    memory,
    terminal: (handle: number) => load<FakeTerminal>(handle, "terminal"),
    keyEncoder: (handle: number) => load<FakeKeyEncoder>(handle, "key encoder"),
    keyEvent: (handle: number) => load<FakeKeyEvent>(handle, "key event"),
    terminals: () => [...createdTerminals],
    liveAllocations: () => allocations.size,
    growCount: () => growCount,
    poke: (terminal, y, x, cell) => {
      const row = terminal.cells[y];
      if (row === undefined) throw new Error(`fake ghostty: no row ${y}`);
      const existing = row[x];
      if (existing === undefined) throw new Error(`fake ghostty: no cell ${x}`);
      Object.assign(existing, cell);
      markDirty(terminal, y);
    },
    defineStyle: (terminal, style) =>
      internStyle(terminal, { ...defaultStyle(), ...style }),
    markDirty,
  };
}
