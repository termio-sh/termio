/**
 * Host-side encoders, for tests only.
 *
 * The client never writes an `S` or an `H` — the daemon does — so these mirror
 * `encode_snapshot_payload` / `encode_history_payload` in
 * `termiod/src/protocol.rs` closely enough that a decode test is testing the
 * wire format rather than its own inverse.
 */
import type { TaggedColor } from "./colors";
import { COLOR_TAG_PALETTE, COLOR_TAG_RGB } from "./colors";
import { KIND, encodeFrame } from "./frame";
import {
  HISTORY_FORMAT_VERSION,
  HISTORY_HEADER_SIZE,
  SNAPSHOT_CELL_SIZE,
  SNAPSHOT_FORMAT_VERSION,
  SNAPSHOT_FORMAT_VT,
} from "./payloads";

export interface WireCell {
  codepoint: number;
  foreground: TaggedColor;
  background: TaggedColor;
  attributes: number;
}

export function cell(overrides: Partial<WireCell> = {}): WireCell {
  return {
    codepoint: 0x20,
    foreground: { tag: "default" },
    background: { tag: "default" },
    attributes: 0,
    ...overrides,
  };
}

function writeColor(out: number[], color: TaggedColor): void {
  switch (color.tag) {
    case "palette":
      out.push(COLOR_TAG_PALETTE, color.index, 0, 0);
      break;
    case "rgb":
      out.push(COLOR_TAG_RGB, color.r, color.g, color.b);
      break;
    default:
      out.push(0, 0, 0, 0);
  }
}

function writeU16(out: number[], value: number): void {
  out.push((value >>> 8) & 0xff, value & 0xff);
}

function writeU32(out: number[], value: number): void {
  out.push(
    (value >>> 24) & 0xff,
    (value >>> 16) & 0xff,
    (value >>> 8) & 0xff,
    value & 0xff,
  );
}

function writeBytes(out: number[], bytes: Uint8Array): void {
  for (const byte of bytes) {
    out.push(byte);
  }
}

function writeCells(out: number[], cells: WireCell[]): void {
  for (const item of cells) {
    writeU32(out, item.codepoint);
    writeColor(out, item.foreground);
    writeColor(out, item.background);
    writeU16(out, item.attributes);
    out.push(0, 0);
  }
}

export interface SnapshotHeader {
  rows: number;
  cols: number;
  cursorX?: number;
  cursorY?: number;
  altScreen?: boolean;
  title?: string;
}

export function encodeSnapshotVtPayload(
  header: SnapshotHeader,
  vt: Uint8Array,
): Uint8Array {
  const out: number[] = [SNAPSHOT_FORMAT_VT];
  const title = new TextEncoder().encode(header.title ?? "");
  writeU16(out, header.rows);
  writeU16(out, header.cols);
  writeU16(out, header.cursorX ?? 0);
  writeU16(out, header.cursorY ?? 0);
  out.push(header.altScreen ? 1 : 0);
  writeU16(out, title.length);
  writeBytes(out, title);
  writeU32(out, vt.length);
  writeBytes(out, vt);
  return new Uint8Array(out);
}

export function encodeSnapshotCellsPayload(
  header: SnapshotHeader,
  cells: WireCell[],
): Uint8Array {
  const out: number[] = [SNAPSHOT_FORMAT_VERSION];
  const title = new TextEncoder().encode(header.title ?? "");
  writeU16(out, header.rows);
  writeU16(out, header.cols);
  writeU16(out, header.cursorX ?? 0);
  writeU16(out, header.cursorY ?? 0);
  out.push(header.altScreen ? 1 : 0);
  writeU16(out, title.length);
  writeBytes(out, title);
  writeCells(out, cells);
  return new Uint8Array(out);
}

export function encodeHistoryPayload(
  cols: number,
  firstOffset: number,
  rowCount: number,
  cells: WireCell[],
): Uint8Array {
  const out: number[] = [HISTORY_FORMAT_VERSION];
  writeU16(out, cols);
  writeU32(out, firstOffset);
  writeU16(out, rowCount);
  writeCells(out, cells);
  const payload = new Uint8Array(out);
  const expected = HISTORY_HEADER_SIZE + cols * rowCount * SNAPSHOT_CELL_SIZE;
  if (payload.length !== expected) {
    throw new Error(`test history payload is ${payload.length}, want ${expected}`);
  }
  return payload;
}

export function encodeJsonFrame(
  kind: typeof KIND.CONTROL | typeof KIND.EVENT,
  value: unknown,
): Uint8Array {
  return encodeFrame(kind, new TextEncoder().encode(JSON.stringify(value)));
}

export function concat(chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}
