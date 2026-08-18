/**
 * The two packed-binary payloads a Replica decodes: `S` (snapshot) and `H`
 * (history). Both are ports of `termiod/src/protocol.rs`, and both stay inside
 * the presentation boundary: a colour on this wire is a slot, never a pixel.
 */
import type { CellView, RowView } from "../renderer/types";
import { DEFAULT_COLOR, decodeColor } from "./colors";
import { ProtocolError } from "./errors";

export const SNAPSHOT_FORMAT_VERSION = 3; // packed cells
export const SNAPSHOT_FORMAT_VT = 2; // VT sequences
export const SNAPSHOT_CELL_SIZE = 16;
export const SNAPSHOT_HEADER_SIZE = 12;
export const HISTORY_FORMAT_VERSION = 2;
export const HISTORY_HEADER_SIZE = 9;
export const MAX_HISTORY_FRAME_SIZE = 64 * 1024;

/**
 * Snapshot payload. v2 carries VT sequences and v3 carries packed cells; any
 * other version byte throws. A Replica always receives v2, because it
 * negotiated `snapshot` — v3 exists for grid_diff clients and as the
 * formatter's own fallback, and decoding it is a correctness requirement, not
 * a code path the web client drives.
 *
 * Header: version u8, rows u16be, cols u16be, cursor_x u16be, cursor_y u16be,
 * alt_screen u8, title_len u16be, UTF-8 title.
 *   v2 body: vt_len u32be, then vt_len bytes.
 *   v3 body: rows*cols packed 16-byte cells, row-major.
 */
export interface Snapshot {
  format: 2 | 3;
  rows: number;
  cols: number;
  cursorX: number;
  cursorY: number;
  altScreen: boolean;
  title: string;
  /** Present iff format === 2. Write EXACTLY these bytes into the Wasm — not
   *  the header, not the title, not the length prefix, and never a
   *  client-side `ESC[2J ESC[H` prelude. The prologue is already inside. */
  vt?: Uint8Array;
  /** Present iff format === 3. */
  cells?: CellView[];
}

/**
 * History payload v2. Header: version u8, cols u16be, first_offset u32be,
 * row_count u16be, then row_count*cols packed 16-byte cells, row-major.
 *
 * Rows are ordered NEWEST FIRST. `firstOffset` is the distance above the
 * snapshot viewport of this chunk's first row, so row i of this chunk sits at
 * viewport-relative y = -(firstOffset + i + 1).
 *
 * `rows` is already the seam's shape: H never enters the Wasm, the renderer
 * paints these through the same code path as live rows.
 *
 * `attributes` on the wire is reserved-zero today, so history rows carry no
 * bold/underline/italic. Do not invent styling to hide the seam at the history
 * boundary — that asymmetry is a named wire-format gap.
 */
export interface HistoryChunk {
  cols: number;
  firstOffset: number;
  rowCount: number;
  rows: RowView[];
}

const utf8 = new TextDecoder("utf-8", { fatal: true });

function readU16(payload: Uint8Array, offset: number): number {
  return (payload[offset] << 8) | payload[offset + 1];
}

function readU32(payload: Uint8Array, offset: number): number {
  return (
    payload[offset] * 0x1000000 +
    ((payload[offset + 1] << 16) | (payload[offset + 2] << 8) | payload[offset + 3])
  );
}

function readBool(payload: Uint8Array, offset: number, what: string): boolean {
  const value = payload[offset];
  if (value !== 0 && value !== 1) {
    throw new ProtocolError(`invalid ${what} value ${value}`);
  }
  return value === 1;
}

function readTitle(payload: Uint8Array, start: number, end: number): string {
  try {
    return utf8.decode(payload.subarray(start, end));
  } catch {
    throw new ProtocolError("snapshot title is not UTF-8");
  }
}

/** A blank cell in the seam's shape, ready for `decodeCell` to fill. */
function blankCell(): CellView {
  return {
    codepoint: 0,
    foreground: DEFAULT_COLOR,
    background: DEFAULT_COLOR,
    attributes: 0,
    selected: false,
  };
}

/**
 * One packed cell, 16 bytes: codepoint u32be, foreground 4, background 4,
 * attributes u16be, 2 reserved.
 */
export function decodeCell(
  payload: Uint8Array,
  offset: number,
  into: CellView,
): void {
  if (offset < 0 || offset + SNAPSHOT_CELL_SIZE > payload.length) {
    throw new ProtocolError(
      `cell at offset ${offset} runs past ${payload.length} bytes`,
    );
  }
  into.codepoint = readU32(payload, offset);
  into.foreground = decodeColor(payload, offset + 4);
  into.background = decodeColor(payload, offset + 8);
  into.attributes = readU16(payload, offset + 12);
  into.selected = false;
  // A packed cell is a single codepoint with no program-set underline colour;
  // leaving the optional fields off keeps a decoded row and a live row the
  // same shape rather than two shapes that happen to look alike.
  delete into.grapheme;
  delete into.underline;
}

function decodeCells(
  payload: Uint8Array,
  offset: number,
  count: number,
): CellView[] {
  const cells: CellView[] = new Array<CellView>(count);
  for (let index = 0; index < count; index += 1) {
    const cell = blankCell();
    decodeCell(payload, offset + index * SNAPSHOT_CELL_SIZE, cell);
    cells[index] = cell;
  }
  return cells;
}

export function decodeSnapshotPayload(payload: Uint8Array): Snapshot {
  if (payload.length < SNAPSHOT_HEADER_SIZE) {
    throw new ProtocolError("malformed snapshot header");
  }
  const version = payload[0];
  if (version !== SNAPSHOT_FORMAT_VT && version !== SNAPSHOT_FORMAT_VERSION) {
    throw new ProtocolError(`unsupported snapshot payload version ${version}`);
  }
  const rows = readU16(payload, 1);
  const cols = readU16(payload, 3);
  const cursorX = readU16(payload, 5);
  const cursorY = readU16(payload, 7);
  const altScreen = readBool(payload, 9, "snapshot alt-screen");
  const titleLength = readU16(payload, 10);
  const bodyOffset = SNAPSHOT_HEADER_SIZE + titleLength;
  if (bodyOffset > payload.length) {
    throw new ProtocolError("snapshot title exceeds payload");
  }
  const title = readTitle(payload, SNAPSHOT_HEADER_SIZE, bodyOffset);

  if (version === SNAPSHOT_FORMAT_VT) {
    const body = payload.subarray(bodyOffset);
    if (body.length < 4) {
      throw new ProtocolError("malformed snapshot vt length");
    }
    const vtLength = readU32(body, 0);
    if (body.length !== 4 + vtLength) {
      throw new ProtocolError(
        `snapshot vt payload has ${body.length - 4} bytes, expected ${vtLength}`,
      );
    }
    return {
      format: 2,
      rows,
      cols,
      cursorX,
      cursorY,
      altScreen,
      title,
      // Copied out: the caller writes these into the Wasm long after the
      // frame buffer they arrived in has been recycled.
      vt: body.slice(4),
    };
  }

  const cellCount = rows * cols;
  const expected = bodyOffset + cellCount * SNAPSHOT_CELL_SIZE;
  if (payload.length !== expected) {
    throw new ProtocolError(
      `snapshot payload has ${payload.length} bytes, expected ${expected}`,
    );
  }
  return {
    format: 3,
    rows,
    cols,
    cursorX,
    cursorY,
    altScreen,
    title,
    cells: decodeCells(payload, bodyOffset, cellCount),
  };
}

export function decodeHistoryPayload(payload: Uint8Array): HistoryChunk {
  if (payload.length < HISTORY_HEADER_SIZE) {
    throw new ProtocolError("malformed history header");
  }
  if (payload.length > MAX_HISTORY_FRAME_SIZE) {
    throw new ProtocolError(
      `history payload too large: ${payload.length} > ${MAX_HISTORY_FRAME_SIZE}`,
    );
  }
  if (payload[0] !== HISTORY_FORMAT_VERSION) {
    throw new ProtocolError(`unsupported history payload version ${payload[0]}`);
  }
  const cols = readU16(payload, 1);
  const firstOffset = readU32(payload, 3);
  const rowCount = readU16(payload, 7);
  if (cols === 0 || rowCount === 0) {
    throw new ProtocolError("history chunks require non-zero columns and rows");
  }
  const expected = HISTORY_HEADER_SIZE + cols * rowCount * SNAPSHOT_CELL_SIZE;
  if (payload.length !== expected) {
    throw new ProtocolError(
      `history payload has ${payload.length} bytes, expected ${expected}`,
    );
  }

  const rows: RowView[] = new Array<RowView>(rowCount);
  for (let index = 0; index < rowCount; index += 1) {
    const offset = HISTORY_HEADER_SIZE + index * cols * SNAPSHOT_CELL_SIZE;
    rows[index] = {
      // Newest first, and `first_offset` is ONE-BASED: `encode_scrollback_chunks`
      // (termiod/src/session.rs) starts it at 1 and advances it by `row_count`,
      // so a chunk with `first_offset: 1` begins at the row immediately above
      // the viewport — viewport-relative y of -1. Treating it as zero-based
      // leaves y = -1 permanently empty and pushes every history row one line
      // too far up; that was measured against a live daemon, not inferred.
      y: -(firstOffset + index),
      dirty: true,
      cells: decodeCells(payload, offset, cols),
    };
  }
  return { cols, firstOffset, rowCount, rows };
}
