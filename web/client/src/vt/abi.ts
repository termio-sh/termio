/**
 * The manifest, resolved once into the handful of numbers this binding uses.
 *
 * Everything here is looked up by NAME at instantiate time. No enum value, no
 * struct offset, and no cell bit position is written down in this repository:
 * they come from `ghostty_type_json` in the Wasm that is actually loaded, so a
 * binary built from a different ghostty commit either resolves correctly or
 * fails here with the name that went missing.
 */

import {
  extractBits,
  ManifestError,
  TypeManifest,
  type BitLayout,
  type StructLayout,
  type UnionBits,
} from "./typeJson";

export interface ColorRgbLayout {
  size: number;
  r: number;
  g: number;
  b: number;
}

export interface StyleColorLayout {
  size: number;
  tag: number;
  /** Offset of the palette index inside the whole GhosttyStyleColor. */
  paletteValue: number;
  /** Offset of the RGB triple inside the whole GhosttyStyleColor. */
  rgbValue: number;
}

export interface StyleLayout {
  size: number;
  sizeField: number;
  foreground: number;
  background: number;
  underlineColor: number;
  bold: number;
  italic: number;
  faint: number;
  blink: number;
  inverse: number;
  invisible: number;
  strikethrough: number;
  overline: number;
  underline: number;
}

export interface CursorLayout {
  size: number;
  sizeField: number;
  viewportHasValue: number;
  viewportX: number;
  viewportY: number;
  wideTail: number;
  visible: number;
  blinking: number;
  passwordInput: number;
  visualStyle: number;
}

export interface RowSelectionLayout {
  size: number;
  sizeField: number;
  startX: number;
  endX: number;
}

export interface PairLayout {
  size: number;
  ptr: number;
  len: number;
}

export interface BufferLayout {
  size: number;
  ptr: number;
  cap: number;
  len: number;
}

export interface ModeConfigLayout {
  size: number;
  mode: number;
  value: number;
}

export interface CellBits {
  contentTag: { lsb: number; width: number };
  content: UnionBits;
  styleId: { lsb: number; width: number };
  wide: { lsb: number; width: number };
  /** Codepoint field inside the CODEPOINT arm. */
  codepointInContent: { lsb: number; width: number };
  /** The same field inside the CODEPOINT_GRAPHEME arm, read separately rather
   *  than assumed identical: the manifest describes each arm on its own. */
  graphemeCodepointInContent: { lsb: number; width: number };
  paletteInContent: { lsb: number; width: number };
  rgbInContent: {
    r: { lsb: number; width: number };
    g: { lsb: number; width: number };
    b: { lsb: number; width: number };
  };
}

export interface ResolvedAbi {
  manifest: TypeManifest;

  result: {
    success: number;
    noValue: number;
    outOfSpace: number;
    /** Code → name, for error messages only. */
    names: Map<number, string>;
  };

  renderStateData: {
    cols: number;
    rows: number;
    dirty: number;
    rowIterator: number;
    cursor: number;
  };
  renderStateDirty: { none: number; partial: number; full: number };
  cursorVisualStyle: {
    bar: number;
    block: number;
    underline: number;
    hollowBlock: number;
  };
  rowData: {
    dirty: number;
    cells: number;
    selection: number;
    cellsRaw: number;
  };
  rowCellsData: { style: number; graphemesUtf8: number };
  terminalData: {
    title: number;
    mode: number;
    kittyKeyboardFlags: number;
    colorForeground: number;
    colorBackground: number;
    colorCursor: number;
  };
  terminalOption: { scrollbackMaxBytes: number };
  keyEncoderOption: {
    cursorKeyApplication: number;
    keypadKeyApplication: number;
    altEscPrefix: number;
    kittyFlags: number;
  };
  keyAction: { press: number; release: number; repeat: number };
  /** Every GhosttyKey by manifest name, e.g. `A`, `ARROW_LEFT`, `NUMPAD_7`. */
  keys: Record<string, number>;
  cellContentTag: {
    codepoint: number;
    codepointGrapheme: number;
    bgColorPalette: number;
    bgColorRgb: number;
  };
  cellWide: {
    narrow: number;
    wide: number;
    spacerTail: number;
    spacerHead: number;
  };
  styleColorTag: { none: number; palette: number; rgb: number };
  sgrUnderline: {
    none: number;
    single: number;
    double: number;
    curly: number;
    dotted: number;
    dashed: number;
  };

  colorRgb: ColorRgbLayout;
  styleColor: StyleColorLayout;
  style: StyleLayout;
  cursor: CursorLayout;
  rowSelection: RowSelectionLayout;
  cellsView: PairLayout;
  string: PairLayout;
  buffer: BufferLayout;
  modeConfig: ModeConfigLayout;
  cell: CellBits;
  /** Bytes in one packed cell, from the manifest rather than `sizeof(u64)`. */
  cellSize: number;
}

function offset(layout: StructLayout, owner: string, field: string): number {
  const value = layout.fields[field];
  if (value === undefined) {
    throw new ManifestError(`${owner} has no field ${field}`);
  }
  return value.offset;
}

function scalar(
  bits: Record<string, BitLayout>,
  owner: string,
  name: string,
): { lsb: number; width: number } {
  const bit = bits[name];
  if (bit === undefined) {
    throw new ManifestError(`${owner} has no bit field ${name}`);
  }
  if (bit.kind !== "scalar") {
    throw new ManifestError(`${owner}.${name} is a union, expected a scalar`);
  }
  return { lsb: bit.lsb, width: bit.width };
}

function armBits(
  union: UnionBits,
  armName: string,
  field: string,
): { lsb: number; width: number } {
  const arm = union.arms[armName];
  if (arm === undefined || arm === null) {
    throw new ManifestError(`GhosttyCell content arm ${armName} is missing`);
  }
  return scalar(arm.bits, `GhosttyCell content ${armName}`, field);
}

export function resolveAbi(manifest: TypeManifest): ResolvedAbi {
  manifest.assertWasm32LittleEndian();

  const resultValues = manifest.enumValues("GhosttyResult");
  const names = new Map<number, string>();
  for (const [name, value] of Object.entries(resultValues)) {
    if (!names.has(value)) names.set(value, name);
  }

  const styleColorStruct = manifest.struct("GhosttyStyleColor");
  const styleColorValueUnion = manifest.union("GhosttyStyleColorValue");
  const valueField = styleColorStruct.fields["value"];
  if (valueField === undefined) {
    throw new ManifestError("GhosttyStyleColor has no field value");
  }
  const paletteMember = styleColorValueUnion.fields["palette"];
  const rgbMember = styleColorValueUnion.fields["rgb"];
  if (paletteMember === undefined || rgbMember === undefined) {
    throw new ManifestError(
      "GhosttyStyleColorValue is missing its palette or rgb member",
    );
  }

  const colorRgbStruct = manifest.struct("GhosttyColorRgb");
  const styleStruct = manifest.struct("GhosttyStyle");
  const cursorStruct = manifest.struct("GhosttyRenderStateCursor");
  const selectionStruct = manifest.struct("GhosttyRenderStateRowSelection");
  const cellsViewStruct = manifest.struct("GhosttyCellsView");
  const stringStruct = manifest.struct("GhosttyString");
  const bufferStruct = manifest.struct("GhosttyBuffer");
  const modeConfigStruct = manifest.struct("GhosttyTerminalModeConfig");

  const cellPacked = manifest.packed("GhosttyCell");
  const content = cellPacked.bits["content"];
  if (content === undefined || content.kind !== "union") {
    throw new ManifestError("GhosttyCell.content is not a tagged union");
  }

  return {
    manifest,
    result: {
      success: manifest.enumValue("GhosttyResult", "SUCCESS"),
      noValue: manifest.enumValue("GhosttyResult", "NO_VALUE"),
      outOfSpace: manifest.enumValue("GhosttyResult", "OUT_OF_SPACE"),
      names,
    },
    renderStateData: {
      cols: manifest.enumValue("GhosttyRenderStateData", "COLS"),
      rows: manifest.enumValue("GhosttyRenderStateData", "ROWS"),
      dirty: manifest.enumValue("GhosttyRenderStateData", "DIRTY"),
      rowIterator: manifest.enumValue("GhosttyRenderStateData", "ROW_ITERATOR"),
      cursor: manifest.enumValue("GhosttyRenderStateData", "CURSOR"),
    },
    renderStateDirty: {
      none: manifest.enumValue("GhosttyRenderStateDirty", "FALSE"),
      partial: manifest.enumValue("GhosttyRenderStateDirty", "PARTIAL"),
      full: manifest.enumValue("GhosttyRenderStateDirty", "FULL"),
    },
    cursorVisualStyle: {
      bar: manifest.enumValue("GhosttyRenderStateCursorVisualStyle", "BAR"),
      block: manifest.enumValue("GhosttyRenderStateCursorVisualStyle", "BLOCK"),
      underline: manifest.enumValue(
        "GhosttyRenderStateCursorVisualStyle",
        "UNDERLINE",
      ),
      hollowBlock: manifest.enumValue(
        "GhosttyRenderStateCursorVisualStyle",
        "BLOCK_HOLLOW",
      ),
    },
    rowData: {
      dirty: manifest.enumValue("GhosttyRenderStateRowData", "DIRTY"),
      cells: manifest.enumValue("GhosttyRenderStateRowData", "CELLS"),
      selection: manifest.enumValue("GhosttyRenderStateRowData", "SELECTION"),
      cellsRaw: manifest.enumValue("GhosttyRenderStateRowData", "CELLS_RAW"),
    },
    rowCellsData: {
      style: manifest.enumValue("GhosttyRenderStateRowCellsData", "STYLE"),
      graphemesUtf8: manifest.enumValue(
        "GhosttyRenderStateRowCellsData",
        "GRAPHEMES_UTF8",
      ),
    },
    terminalData: {
      title: manifest.enumValue("GhosttyTerminalData", "TITLE"),
      mode: manifest.enumValue("GhosttyTerminalData", "MODE"),
      kittyKeyboardFlags: manifest.enumValue(
        "GhosttyTerminalData",
        "KITTY_KEYBOARD_FLAGS",
      ),
      colorForeground: manifest.enumValue(
        "GhosttyTerminalData",
        "COLOR_FOREGROUND",
      ),
      colorBackground: manifest.enumValue(
        "GhosttyTerminalData",
        "COLOR_BACKGROUND",
      ),
      colorCursor: manifest.enumValue("GhosttyTerminalData", "COLOR_CURSOR"),
    },
    terminalOption: {
      scrollbackMaxBytes: manifest.enumValue(
        "GhosttyTerminalOption",
        "SCROLLBACK_MAX_BYTES",
      ),
    },
    keyEncoderOption: {
      cursorKeyApplication: manifest.enumValue(
        "GhosttyKeyEncoderOption",
        "CURSOR_KEY_APPLICATION",
      ),
      keypadKeyApplication: manifest.enumValue(
        "GhosttyKeyEncoderOption",
        "KEYPAD_KEY_APPLICATION",
      ),
      altEscPrefix: manifest.enumValue(
        "GhosttyKeyEncoderOption",
        "ALT_ESC_PREFIX",
      ),
      kittyFlags: manifest.enumValue("GhosttyKeyEncoderOption", "KITTY_FLAGS"),
    },
    keyAction: {
      press: manifest.enumValue("GhosttyKeyAction", "PRESS"),
      release: manifest.enumValue("GhosttyKeyAction", "RELEASE"),
      repeat: manifest.enumValue("GhosttyKeyAction", "REPEAT"),
    },
    keys: manifest.enumValues("GhosttyKey"),
    cellContentTag: {
      codepoint: manifest.enumValue("GhosttyCellContentTag", "CODEPOINT"),
      codepointGrapheme: manifest.enumValue(
        "GhosttyCellContentTag",
        "CODEPOINT_GRAPHEME",
      ),
      bgColorPalette: manifest.enumValue(
        "GhosttyCellContentTag",
        "BG_COLOR_PALETTE",
      ),
      bgColorRgb: manifest.enumValue("GhosttyCellContentTag", "BG_COLOR_RGB"),
    },
    cellWide: {
      narrow: manifest.enumValue("GhosttyCellWide", "NARROW"),
      wide: manifest.enumValue("GhosttyCellWide", "WIDE"),
      spacerTail: manifest.enumValue("GhosttyCellWide", "SPACER_TAIL"),
      spacerHead: manifest.enumValue("GhosttyCellWide", "SPACER_HEAD"),
    },
    styleColorTag: {
      none: manifest.enumValue("GhosttyStyleColorTag", "NONE"),
      palette: manifest.enumValue("GhosttyStyleColorTag", "PALETTE"),
      rgb: manifest.enumValue("GhosttyStyleColorTag", "RGB"),
    },
    sgrUnderline: {
      none: manifest.enumValue("GhosttySgrUnderline", "NONE"),
      single: manifest.enumValue("GhosttySgrUnderline", "SINGLE"),
      double: manifest.enumValue("GhosttySgrUnderline", "DOUBLE"),
      curly: manifest.enumValue("GhosttySgrUnderline", "CURLY"),
      dotted: manifest.enumValue("GhosttySgrUnderline", "DOTTED"),
      dashed: manifest.enumValue("GhosttySgrUnderline", "DASHED"),
    },

    colorRgb: {
      size: colorRgbStruct.size,
      r: offset(colorRgbStruct, "GhosttyColorRgb", "r"),
      g: offset(colorRgbStruct, "GhosttyColorRgb", "g"),
      b: offset(colorRgbStruct, "GhosttyColorRgb", "b"),
    },
    styleColor: {
      size: styleColorStruct.size,
      tag: offset(styleColorStruct, "GhosttyStyleColor", "tag"),
      paletteValue: valueField.offset + paletteMember.offset,
      rgbValue: valueField.offset + rgbMember.offset,
    },
    style: {
      size: styleStruct.size,
      sizeField: offset(styleStruct, "GhosttyStyle", "size"),
      foreground: offset(styleStruct, "GhosttyStyle", "fg_color"),
      background: offset(styleStruct, "GhosttyStyle", "bg_color"),
      underlineColor: offset(styleStruct, "GhosttyStyle", "underline_color"),
      bold: offset(styleStruct, "GhosttyStyle", "bold"),
      italic: offset(styleStruct, "GhosttyStyle", "italic"),
      faint: offset(styleStruct, "GhosttyStyle", "faint"),
      blink: offset(styleStruct, "GhosttyStyle", "blink"),
      inverse: offset(styleStruct, "GhosttyStyle", "inverse"),
      invisible: offset(styleStruct, "GhosttyStyle", "invisible"),
      strikethrough: offset(styleStruct, "GhosttyStyle", "strikethrough"),
      overline: offset(styleStruct, "GhosttyStyle", "overline"),
      underline: offset(styleStruct, "GhosttyStyle", "underline"),
    },
    cursor: {
      size: cursorStruct.size,
      sizeField: offset(cursorStruct, "GhosttyRenderStateCursor", "size"),
      viewportHasValue: offset(
        cursorStruct,
        "GhosttyRenderStateCursor",
        "viewport_has_value",
      ),
      viewportX: offset(cursorStruct, "GhosttyRenderStateCursor", "viewport_x"),
      viewportY: offset(cursorStruct, "GhosttyRenderStateCursor", "viewport_y"),
      wideTail: offset(cursorStruct, "GhosttyRenderStateCursor", "wide_tail"),
      visible: offset(cursorStruct, "GhosttyRenderStateCursor", "visible"),
      blinking: offset(cursorStruct, "GhosttyRenderStateCursor", "blinking"),
      passwordInput: offset(
        cursorStruct,
        "GhosttyRenderStateCursor",
        "password_input",
      ),
      visualStyle: offset(
        cursorStruct,
        "GhosttyRenderStateCursor",
        "visual_style",
      ),
    },
    rowSelection: {
      size: selectionStruct.size,
      sizeField: offset(
        selectionStruct,
        "GhosttyRenderStateRowSelection",
        "size",
      ),
      startX: offset(
        selectionStruct,
        "GhosttyRenderStateRowSelection",
        "start_x",
      ),
      endX: offset(selectionStruct, "GhosttyRenderStateRowSelection", "end_x"),
    },
    cellsView: {
      size: cellsViewStruct.size,
      ptr: offset(cellsViewStruct, "GhosttyCellsView", "ptr"),
      len: offset(cellsViewStruct, "GhosttyCellsView", "len"),
    },
    string: {
      size: stringStruct.size,
      ptr: offset(stringStruct, "GhosttyString", "ptr"),
      len: offset(stringStruct, "GhosttyString", "len"),
    },
    buffer: {
      size: bufferStruct.size,
      ptr: offset(bufferStruct, "GhosttyBuffer", "ptr"),
      cap: offset(bufferStruct, "GhosttyBuffer", "cap"),
      len: offset(bufferStruct, "GhosttyBuffer", "len"),
    },
    modeConfig: {
      size: modeConfigStruct.size,
      mode: offset(modeConfigStruct, "GhosttyTerminalModeConfig", "mode"),
      value: offset(modeConfigStruct, "GhosttyTerminalModeConfig", "value"),
    },
    cell: {
      contentTag: scalar(cellPacked.bits, "GhosttyCell", "content_tag"),
      content,
      styleId: scalar(cellPacked.bits, "GhosttyCell", "style_id"),
      wide: scalar(cellPacked.bits, "GhosttyCell", "wide"),
      codepointInContent: armBits(content, "CODEPOINT", "codepoint"),
      graphemeCodepointInContent: armBits(
        content,
        "CODEPOINT_GRAPHEME",
        "codepoint",
      ),
      paletteInContent: armBits(content, "BG_COLOR_PALETTE", "index"),
      rgbInContent: {
        r: armBits(content, "BG_COLOR_RGB", "r"),
        g: armBits(content, "BG_COLOR_RGB", "g"),
        b: armBits(content, "BG_COLOR_RGB", "b"),
      },
    },
    cellSize: cellPacked.size,
  };
}

export { extractBits };
