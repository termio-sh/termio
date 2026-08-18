/**
 * The 5-byte framing, `[kind:u8][len:u32be][payload]`, ported from
 * `termiod/src/protocol.rs`. It is the same framing on a Unix socket, on SSH
 * stdio, and inside WebSocket binary messages — which is the whole reason a
 * transcript recorded over one pipe replays byte-identical over another.
 */
import type { Control, Event, ControlOut } from "./control";
import { decodeControl, decodeEvent, encodeControlPayload } from "./control";
import { ProtocolError } from "./errors";
import type { HistoryChunk, Snapshot } from "./payloads";
import { decodeHistoryPayload, decodeSnapshotPayload } from "./payloads";

export { ProtocolError };
export type { Control, ControlOut, Event, HistoryChunk, Snapshot };

/** Frame kinds, verbatim from termiod/src/protocol.rs. ASCII letters, not an enum. */
export const KIND = {
  CONTROL: 0x43, // 'C'
  DATA: 0x44, // 'D'
  RESIZE: 0x52, // 'R'
  EVENT: 0x45, // 'E'
  SNAPSHOT: 0x53, // 'S'
  HISTORY: 0x48, // 'H'
  GRID: 0x47, // 'G'
  FILE: 0x46, // 'F'
  UPLOAD: 0x55, // 'U'
} as const;
export type FrameKind = (typeof KIND)[keyof typeof KIND];

export const MAX_FRAME_SIZE = 16 * 1024 * 1024;
export const MAX_DATA_FRAME_SIZE = 64 * 1024;
export const PROTOCOL_VERSION = 1;

/** `G` is skipped, not decoded; the sizes are here for the frozen contract. */
export const GRID_FORMAT_VERSION = 2;
export const GRID_HEADER_SIZE = 16;

// Re-exported rather than restated: one definition per constant, so a wire
// format cannot drift between the module that decodes it and the module that
// names it.
export {
  SNAPSHOT_FORMAT_VERSION,
  SNAPSHOT_FORMAT_VT,
  SNAPSHOT_CELL_SIZE,
  HISTORY_FORMAT_VERSION,
  HISTORY_HEADER_SIZE,
  MAX_HISTORY_FRAME_SIZE,
} from "./payloads";
export { COLOR_TAG_DEFAULT, COLOR_TAG_PALETTE, COLOR_TAG_RGB } from "./colors";

const HEADER_SIZE = 5;

const KNOWN_KINDS = new Set<number>(Object.values(KIND));

/**
 * One decoded frame. `G`/`F`/`U` keep their raw payload: the web client
 * negotiates none of `grid_diff` / `files` / `upload` in v1, and a frame it did
 * not ask for must be skipped, never treated as an error.
 */
export type Frame =
  | { kind: typeof KIND.CONTROL; control: Control }
  | { kind: typeof KIND.DATA; data: Uint8Array }
  | { kind: typeof KIND.RESIZE; rows: number; cols: number }
  | { kind: typeof KIND.EVENT; event: Event }
  | { kind: typeof KIND.SNAPSHOT; snapshot: Snapshot }
  | { kind: typeof KIND.HISTORY; history: HistoryChunk }
  | { kind: typeof KIND.GRID; payload: Uint8Array }
  | { kind: typeof KIND.FILE; payload: Uint8Array }
  | { kind: typeof KIND.UPLOAD; payload: Uint8Array };

function decodeFrame(kind: number, payload: Uint8Array): Frame {
  switch (kind) {
    case KIND.CONTROL:
      return { kind: KIND.CONTROL, control: decodeControl(payload) };
    case KIND.DATA:
      return { kind: KIND.DATA, data: payload };
    case KIND.RESIZE:
      if (payload.length !== 4) {
        throw new ProtocolError("malformed resize frame");
      }
      return {
        kind: KIND.RESIZE,
        rows: (payload[0] << 8) | payload[1],
        cols: (payload[2] << 8) | payload[3],
      };
    case KIND.EVENT:
      return { kind: KIND.EVENT, event: decodeEvent(payload) };
    case KIND.SNAPSHOT:
      return { kind: KIND.SNAPSHOT, snapshot: decodeSnapshotPayload(payload) };
    case KIND.HISTORY:
      return { kind: KIND.HISTORY, history: decodeHistoryPayload(payload) };
    case KIND.GRID:
      return { kind: KIND.GRID, payload };
    case KIND.FILE:
      return { kind: KIND.FILE, payload };
    case KIND.UPLOAD:
      return { kind: KIND.UPLOAD, payload };
    default:
      throw new ProtocolError(`unknown frame kind 0x${kind.toString(16)}`);
  }
}

function asBytes(chunk: ArrayBuffer | ArrayBufferView): Uint8Array {
  if (ArrayBuffer.isView(chunk)) {
    return new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
  }
  return new Uint8Array(chunk);
}

/**
 * Reassembles the framed byte stream out of WebSocket messages.
 *
 * WebSocket message boundaries are NOT frame boundaries. `push` accepts an
 * arbitrary chunk — one message may hold three frames, one frame may span four
 * messages — and emits whole frames in order. This is the single reason a
 * transcript recorded over the Unix socket replays byte-identical here.
 *
 * Throws `ProtocolError` on an unknown kind or a length over MAX_FRAME_SIZE;
 * the caller closes the socket. It never resynchronises: a corrupt stream is
 * a dead stream.
 */
export class FrameReader {
  private readonly onFrame: (frame: Frame) => void;
  private buffer = new Uint8Array(0);
  private cursor = 0;

  constructor(onFrame: (frame: Frame) => void) {
    this.onFrame = onFrame;
  }

  /** Bytes buffered but not yet a whole frame. Tests assert this is 0 at EOF. */
  get pending(): number {
    return this.buffer.length - this.cursor;
  }

  reset(): void {
    this.buffer = new Uint8Array(0);
    this.cursor = 0;
  }

  push(chunk: ArrayBuffer | ArrayBufferView): void {
    this.append(asBytes(chunk));
    // Re-read `buffer`/`cursor` on every iteration: `onFrame` is allowed to
    // push again (a reply arriving on the same tick), and a cached view of the
    // buffer would silently drop those bytes.
    for (;;) {
      if (this.pending < HEADER_SIZE) return;
      const start = this.cursor;
      const kind = this.buffer[start];
      const length =
        this.buffer[start + 1] * 0x1000000 +
        ((this.buffer[start + 2] << 16) |
          (this.buffer[start + 3] << 8) |
          this.buffer[start + 4]);
      if (length > MAX_FRAME_SIZE) {
        throw new ProtocolError(
          `frame length ${length} exceeds maximum ${MAX_FRAME_SIZE}`,
        );
      }
      // The kind check happens before the body is complete so a garbage stream
      // dies on the first bad byte instead of after buffering 16 MiB of it.
      if (!KNOWN_KINDS.has(kind)) {
        throw new ProtocolError(`unknown frame kind 0x${kind.toString(16)}`);
      }
      if (this.pending < HEADER_SIZE + length) return;
      const bodyStart = start + HEADER_SIZE;
      // `slice` copies: a decoded `D` payload outlives this buffer, and the
      // buffer is compacted underneath it.
      const payload = this.buffer.slice(bodyStart, bodyStart + length);
      this.cursor = bodyStart + length;
      this.compact();
      this.onFrame(decodeFrame(kind, payload));
    }
  }

  private append(bytes: Uint8Array): void {
    if (bytes.length === 0) return;
    const kept = this.pending;
    const merged = new Uint8Array(kept + bytes.length);
    merged.set(this.buffer.subarray(this.cursor), 0);
    merged.set(bytes, kept);
    this.buffer = merged;
    this.cursor = 0;
  }

  private compact(): void {
    if (this.cursor === 0) return;
    if (this.cursor === this.buffer.length) {
      this.buffer = new Uint8Array(0);
      this.cursor = 0;
      return;
    }
    this.buffer = this.buffer.slice(this.cursor);
    this.cursor = 0;
  }
}

/** [kind:u8][len:u32be][payload]. Throws over MAX_FRAME_SIZE. */
export function encodeFrame(kind: FrameKind, payload: Uint8Array): Uint8Array {
  if (payload.length > MAX_FRAME_SIZE) {
    throw new ProtocolError(
      `frame payload too large: ${payload.length} > ${MAX_FRAME_SIZE}`,
    );
  }
  const frame = new Uint8Array(HEADER_SIZE + payload.length);
  frame[0] = kind;
  frame[1] = (payload.length >>> 24) & 0xff;
  frame[2] = (payload.length >>> 16) & 0xff;
  frame[3] = (payload.length >>> 8) & 0xff;
  frame[4] = payload.length & 0xff;
  frame.set(payload, HEADER_SIZE);
  return frame;
}

export function encodeControl(msg: ControlOut): Uint8Array {
  return encodeFrame(KIND.CONTROL, encodeControlPayload(msg));
}

/** Splits at MAX_DATA_FRAME_SIZE, mirroring `write_data`. Empty input → one empty D frame. */
export function encodeData(bytes: Uint8Array): Uint8Array[] {
  if (bytes.length === 0) {
    return [encodeFrame(KIND.DATA, bytes)];
  }
  const frames: Uint8Array[] = [];
  for (let offset = 0; offset < bytes.length; offset += MAX_DATA_FRAME_SIZE) {
    frames.push(
      encodeFrame(
        KIND.DATA,
        bytes.subarray(offset, offset + MAX_DATA_FRAME_SIZE),
      ),
    );
  }
  return frames;
}

/** 4-byte payload: rows u16be, cols u16be. */
export function encodeResize(rows: number, cols: number): Uint8Array {
  const payload = new Uint8Array(4);
  payload[0] = (checkDimension(rows, "rows") >>> 8) & 0xff;
  payload[1] = rows & 0xff;
  payload[2] = (checkDimension(cols, "cols") >>> 8) & 0xff;
  payload[3] = cols & 0xff;
  return encodeFrame(KIND.RESIZE, payload);
}

function checkDimension(value: number, what: string): number {
  if (!Number.isInteger(value) || value < 0 || value > 0xffff) {
    throw new ProtocolError(`${what} must be a u16, got ${value}`);
  }
  return value;
}
