/**
 * wasm32 C layouts for the fixture module, plus the manifest that describes
 * them.
 *
 * The fixture writes its structs at exactly the offsets it publishes here, so
 * the binding under test is genuinely manifest-driven: shift a layout and the
 * binding has to follow, or the test fails. `padding` exists for that test.
 */

export interface FieldSpec {
  name: string;
  size: number;
  align: number;
  type: string;
}

export interface Layout {
  size: number;
  align: number;
  offsets: Record<string, number>;
  fields: Record<string, { offset: number; size: number; type: string }>;
}

export function layoutStruct(fields: FieldSpec[]): Layout {
  let offset = 0;
  let maxAlign = 1;
  const offsets: Record<string, number> = {};
  const described: Record<string, { offset: number; size: number; type: string }> =
    {};
  for (const field of fields) {
    offset = align(offset, field.align);
    offsets[field.name] = offset;
    described[field.name] = {
      offset,
      size: field.size,
      type: field.type,
    };
    offset += field.size;
    maxAlign = Math.max(maxAlign, field.align);
  }
  return {
    size: align(offset, maxAlign),
    align: maxAlign,
    offsets,
    fields: described,
  };
}

function align(value: number, to: number): number {
  const remainder = value % to;
  return remainder === 0 ? value : value + (to - remainder);
}

const USIZE = { size: 4, align: 4 };
const I32 = { size: 4, align: 4 };
const U16 = { size: 2, align: 2 };
const BOOL = { size: 1, align: 1 };
const U8 = { size: 1, align: 1 };
const U64 = { size: 8, align: 8 };

export interface Layouts {
  colorRgb: Layout;
  styleColorValue: Layout;
  styleColor: Layout;
  style: Layout;
  cursor: Layout;
  rowSelection: Layout;
  cellsView: Layout;
  string: Layout;
  buffer: Layout;
  modeConfig: Layout;
}

/**
 * `padding` prepends a dummy leading field to every sized struct, which moves
 * every offset in the manifest without changing any field's meaning.
 */
export function buildLayouts(padding = 0): Layouts {
  const pad: FieldSpec[] =
    padding > 0
      ? [{ name: "_fixture_pad", size: padding, align: 8, type: "u8" }]
      : [];

  const colorRgb = layoutStruct([
    { name: "r", ...U8, type: "u8" },
    { name: "g", ...U8, type: "u8" },
    { name: "b", ...U8, type: "u8" },
  ]);
  const styleColorValue = layoutStruct([
    { name: "palette", ...U8, type: "GhosttyColorPaletteIndex" },
  ]);
  // A union: every member sits at offset 0 and the whole thing is u64-sized.
  styleColorValue.fields["rgb"] = { offset: 0, size: 3, type: "GhosttyColorRgb" };
  styleColorValue.offsets["rgb"] = 0;
  styleColorValue.size = U64.size;
  styleColorValue.align = U64.align;

  const styleColor = layoutStruct([
    { name: "tag", ...I32, type: "GhosttyStyleColorTag" },
    {
      name: "value",
      size: styleColorValue.size,
      align: styleColorValue.align,
      type: "GhosttyStyleColorValue",
    },
  ]);

  const style = layoutStruct([
    ...pad,
    { name: "size", ...USIZE, type: "usize" },
    {
      name: "fg_color",
      size: styleColor.size,
      align: styleColor.align,
      type: "GhosttyStyleColor",
    },
    {
      name: "bg_color",
      size: styleColor.size,
      align: styleColor.align,
      type: "GhosttyStyleColor",
    },
    {
      name: "underline_color",
      size: styleColor.size,
      align: styleColor.align,
      type: "GhosttyStyleColor",
    },
    { name: "bold", ...BOOL, type: "bool" },
    { name: "italic", ...BOOL, type: "bool" },
    { name: "faint", ...BOOL, type: "bool" },
    { name: "blink", ...BOOL, type: "bool" },
    { name: "inverse", ...BOOL, type: "bool" },
    { name: "invisible", ...BOOL, type: "bool" },
    { name: "strikethrough", ...BOOL, type: "bool" },
    { name: "overline", ...BOOL, type: "bool" },
    { name: "underline", ...I32, type: "i32" },
  ]);

  const cursor = layoutStruct([
    ...pad,
    { name: "size", ...USIZE, type: "usize" },
    { name: "viewport_has_value", ...BOOL, type: "bool" },
    { name: "viewport_x", ...U16, type: "u16" },
    { name: "viewport_y", ...U16, type: "u16" },
    { name: "wide_tail", ...BOOL, type: "bool" },
    { name: "visible", ...BOOL, type: "bool" },
    { name: "blinking", ...BOOL, type: "bool" },
    { name: "password_input", ...BOOL, type: "bool" },
    {
      name: "visual_style",
      ...I32,
      type: "GhosttyRenderStateCursorVisualStyle",
    },
  ]);

  const rowSelection = layoutStruct([
    ...pad,
    { name: "size", ...USIZE, type: "usize" },
    { name: "start_x", ...U16, type: "u16" },
    { name: "end_x", ...U16, type: "u16" },
  ]);

  const cellsView = layoutStruct([
    { name: "ptr", size: 4, align: 4, type: "pointer" },
    { name: "len", ...USIZE, type: "usize" },
  ]);

  const string = layoutStruct([
    { name: "ptr", size: 4, align: 4, type: "pointer" },
    { name: "len", ...USIZE, type: "usize" },
  ]);

  const buffer = layoutStruct([
    { name: "ptr", size: 4, align: 4, type: "pointer" },
    { name: "cap", ...USIZE, type: "usize" },
    { name: "len", ...USIZE, type: "usize" },
  ]);

  const modeConfig = layoutStruct([
    { name: "mode", ...U16, type: "GhosttyMode" },
    { name: "value", ...BOOL, type: "bool" },
  ]);

  return {
    colorRgb,
    styleColorValue,
    styleColor,
    style,
    cursor,
    rowSelection,
    cellsView,
    string,
    buffer,
    modeConfig,
  };
}

/** Real values, copied from the headers at ghostty `56e1f3a`. */
export const ENUMS = {
  GhosttyResult: {
    SUCCESS: 0,
    OUT_OF_MEMORY: -1,
    INVALID_VALUE: -2,
    OUT_OF_SPACE: -3,
    NO_VALUE: -4,
    IO_ERROR: -5,
    LIMIT_EXCEEDED: -6,
    RESULT_MAX_VALUE: 2147483647,
  },
  GhosttyRenderStateData: {
    INVALID: 0,
    COLS: 1,
    ROWS: 2,
    DIRTY: 3,
    ROW_ITERATOR: 4,
    COLOR_BACKGROUND: 5,
    COLOR_FOREGROUND: 6,
    COLOR_CURSOR: 7,
    COLOR_CURSOR_HAS_VALUE: 8,
    COLOR_PALETTE: 9,
    CURSOR_VISUAL_STYLE: 10,
    CURSOR_VISIBLE: 11,
    CURSOR_BLINKING: 12,
    CURSOR_PASSWORD_INPUT: 13,
    CURSOR_VIEWPORT_HAS_VALUE: 14,
    CURSOR_VIEWPORT_X: 15,
    CURSOR_VIEWPORT_Y: 16,
    CURSOR_VIEWPORT_WIDE_TAIL: 17,
    CURSOR: 18,
    COLORS: 19,
    MAX_VALUE: 2147483647,
  },
  GhosttyRenderStateDirty: { FALSE: 0, PARTIAL: 1, FULL: 2, MAX_VALUE: 2147483647 },
  GhosttyRenderStateCursorVisualStyle: {
    BAR: 0,
    BLOCK: 1,
    UNDERLINE: 2,
    BLOCK_HOLLOW: 3,
    MAX_VALUE: 2147483647,
  },
  GhosttyRenderStateRowData: {
    INVALID: 0,
    DIRTY: 1,
    RAW: 2,
    CELLS: 3,
    SELECTION: 4,
    CELLS_RAW: 5,
    MAX_VALUE: 2147483647,
  },
  GhosttyRenderStateRowCellsData: {
    INVALID: 0,
    RAW: 1,
    STYLE: 2,
    GRAPHEMES_LEN: 3,
    GRAPHEMES_BUF: 4,
    BG_COLOR: 5,
    FG_COLOR: 6,
    SELECTED: 7,
    HAS_STYLING: 8,
    GRAPHEMES_UTF8: 9,
    MAX_VALUE: 2147483647,
  },
  GhosttyTerminalData: {
    INVALID: 0,
    COLS: 1,
    ROWS: 2,
    KITTY_KEYBOARD_FLAGS: 8,
    TITLE: 12,
    COLOR_FOREGROUND: 18,
    COLOR_BACKGROUND: 19,
    COLOR_CURSOR: 20,
    MODE: 37,
    MAX_VALUE: 2147483647,
  },
  GhosttyTerminalOption: {
    USERDATA: 0,
    SCROLLBACK_MAX_BYTES: 27,
    MAX_VALUE: 2147483647,
  },
  GhosttyKeyEncoderOption: {
    CURSOR_KEY_APPLICATION: 0,
    KEYPAD_KEY_APPLICATION: 1,
    IGNORE_KEYPAD_WITH_NUMLOCK: 2,
    ALT_ESC_PREFIX: 3,
    MODIFY_OTHER_KEYS_STATE_2: 4,
    KITTY_FLAGS: 5,
    MACOS_OPTION_AS_ALT: 6,
    BACKARROW_KEY_MODE: 7,
    MAX_VALUE: 2147483647,
  },
  GhosttyKeyAction: { RELEASE: 0, PRESS: 1, REPEAT: 2, MAX_VALUE: 2147483647 },
  GhosttyCellContentTag: {
    CODEPOINT: 0,
    CODEPOINT_GRAPHEME: 1,
    BG_COLOR_PALETTE: 2,
    BG_COLOR_RGB: 3,
    TAG_MAX_VALUE: 2147483647,
  },
  GhosttyCellWide: {
    NARROW: 0,
    WIDE: 1,
    SPACER_TAIL: 2,
    SPACER_HEAD: 3,
    MAX_VALUE: 2147483647,
  },
  GhosttyStyleColorTag: {
    NONE: 0,
    PALETTE: 1,
    RGB: 2,
    TAG_MAX_VALUE: 2147483647,
  },
  GhosttySgrUnderline: {
    NONE: 0,
    SINGLE: 1,
    DOUBLE: 2,
    CURLY: 3,
    DOTTED: 4,
    DASHED: 5,
    MAX_VALUE: 2147483647,
  },
  /** A representative slice of GhosttyKey, with the real values. */
  GhosttyKey: {
    UNIDENTIFIED: 0,
    BACKQUOTE: 1,
    BACKSLASH: 2,
    BRACKET_LEFT: 3,
    BRACKET_RIGHT: 4,
    COMMA: 5,
    DIGIT_0: 6,
    DIGIT_1: 7,
    DIGIT_2: 8,
    DIGIT_9: 15,
    EQUAL: 16,
    A: 20,
    B: 21,
    C: 22,
    Z: 45,
    MINUS: 46,
    PERIOD: 47,
    QUOTE: 48,
    SEMICOLON: 49,
    SLASH: 50,
    ALT_LEFT: 51,
    ALT_RIGHT: 52,
    BACKSPACE: 53,
    CAPS_LOCK: 54,
    CONTROL_LEFT: 56,
    CONTROL_RIGHT: 57,
    ENTER: 58,
    META_LEFT: 59,
    SHIFT_LEFT: 61,
    SHIFT_RIGHT: 62,
    SPACE: 63,
    TAB: 64,
    DELETE: 68,
    END: 69,
    HOME: 71,
    INSERT: 72,
    PAGE_DOWN: 73,
    PAGE_UP: 74,
    ARROW_DOWN: 75,
    ARROW_LEFT: 76,
    ARROW_RIGHT: 77,
    ARROW_UP: 78,
    NUMPAD_0: 80,
    NUMPAD_7: 87,
    NUMPAD_ADD: 90,
    ESCAPE: 120,
    F1: 121,
    F12: 132,
    MAX_VALUE: 2147483647,
  },
} as const;

/** GhosttyCell, packed into a u64 exactly as `page.zig` declares it. */
export const CELL_BITS = {
  content_tag: { lsb: 0, width: 2, type: "GhosttyCellContentTag" },
  content: {
    kind: "union" as const,
    lsb: 2,
    width: 24,
    tag: "content_tag",
    arms: {
      CODEPOINT: {
        kind: "packed" as const,
        width: 24,
        bits: { codepoint: { lsb: 0, width: 21, type: "u21" } },
      },
      CODEPOINT_GRAPHEME: {
        kind: "packed" as const,
        width: 24,
        bits: { codepoint: { lsb: 0, width: 21, type: "u21" } },
      },
      BG_COLOR_PALETTE: {
        kind: "packed" as const,
        width: 24,
        bits: { index: { lsb: 0, width: 8, type: "GhosttyColorPaletteIndex" } },
      },
      BG_COLOR_RGB: {
        kind: "packed" as const,
        width: 24,
        bits: {
          r: { lsb: 0, width: 8, type: "u8" },
          g: { lsb: 8, width: 8, type: "u8" },
          b: { lsb: 16, width: 8, type: "u8" },
        },
      },
    },
  },
  style_id: { lsb: 26, width: 16, type: "GhosttyStyleId" },
  wide: { lsb: 42, width: 2, type: "GhosttyCellWide" },
  protected: { lsb: 44, width: 1, type: "bool" },
  hyperlink: { lsb: 45, width: 1, type: "bool" },
  semantic_content: { lsb: 46, width: 2, type: "GhosttyCellSemanticContent" },
};

export function buildManifest(layouts: Layouts): string {
  const types: Record<string, unknown> = {
    GhosttyColorRgb: structDescriptor(layouts.colorRgb),
    GhosttyStyleColorValue: {
      kind: "union",
      size: layouts.styleColorValue.size,
      align: layouts.styleColorValue.align,
      fields: layouts.styleColorValue.fields,
    },
    GhosttyStyleColor: structDescriptor(layouts.styleColor),
    GhosttyStyle: structDescriptor(layouts.style),
    GhosttyRenderStateCursor: structDescriptor(layouts.cursor),
    GhosttyRenderStateRowSelection: structDescriptor(layouts.rowSelection),
    GhosttyCellsView: structDescriptor(layouts.cellsView),
    GhosttyString: structDescriptor(layouts.string),
    GhosttyBuffer: structDescriptor(layouts.buffer),
    GhosttyTerminalModeConfig: structDescriptor(layouts.modeConfig),
    GhosttyCell: {
      kind: "packed",
      size: 8,
      align: 8,
      underlying: "u64",
      bits: CELL_BITS,
    },
  };
  for (const [name, values] of Object.entries(ENUMS)) {
    types[name] = {
      kind: "enum",
      size: 4,
      align: 4,
      underlying: "i32",
      prefix: `GHOSTTY_${name.toUpperCase()}_`,
      values,
    };
  }
  return JSON.stringify({
    schema: 1,
    abi: {
      target: "wasm32-freestanding-none",
      os: "freestanding",
      environment: "none",
      pointer_size: 4,
      usize_size: 4,
      max_alignment: 16,
      endian: "little",
    },
    library_version: "0.0.0-fixture",
    commit: "56e1f3a62e26407e8c020ef5881df3e8584be20f",
    dirty: false,
    types,
  });
}

function structDescriptor(layout: Layout): unknown {
  return {
    kind: "struct",
    size: layout.size,
    align: layout.align,
    fields: layout.fields,
  };
}
