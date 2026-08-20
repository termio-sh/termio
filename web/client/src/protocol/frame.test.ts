import { describe, expect, it } from "vitest";
import {
  FrameReader,
  KIND,
  MAX_DATA_FRAME_SIZE,
  MAX_FRAME_SIZE,
  ProtocolError,
  encodeControl,
  encodeData,
  encodeFrame,
  encodeResize,
} from "./frame";
import type { Frame } from "./frame";
import {
  cell,
  concat,
  encodeHistoryPayload,
  encodeJsonFrame,
  encodeSnapshotVtPayload,
} from "./testTranscript";

function collect(): { frames: Frame[]; reader: FrameReader } {
  const frames: Frame[] = [];
  return { frames, reader: new FrameReader((frame) => frames.push(frame)) };
}

/**
 * The attach transcript, byte for byte: hello / hello_ok / attach / attached,
 * one VT snapshot, `ready`, then live D interleaved with a newest-first H
 * chunk. This is the sequence the RFC freezes, encoded once and replayed under
 * every chunking below.
 */
function attachTranscript(): Uint8Array {
  return concat([
    encodeControl({
      op: "hello",
      proto: 1,
      min_proto: 1,
      role: "attach",
      caps: ["events", "snapshot", "scrollback"],
      client: "termio-web/0.1.0",
    }),
    encodeJsonFrame(KIND.CONTROL, {
      op: "hello_ok",
      proto: 1,
      caps: ["events", "snapshot", "scrollback"],
      host_id: "host-1",
      host: "box",
      client_id: "client-1",
    }),
    encodeControl({
      op: "attach",
      target: "shell",
      rows: 24,
      cols: 80,
      mode: "observe",
      seq: 1,
    }),
    encodeJsonFrame(KIND.CONTROL, {
      op: "attached",
      id: "s1",
      name: "shell",
      session_id: "s1",
      writer: false,
      rows: 24,
      cols: 80,
      re: 1,
    }),
    encodeFrame(
      KIND.SNAPSHOT,
      encodeSnapshotVtPayload(
        { rows: 2, cols: 4, title: "zsh" },
        new TextEncoder().encode("[2J[Hhello"),
      ),
    ),
    encodeJsonFrame(KIND.EVENT, { ev: "ready", session: "s1" }),
    ...encodeData(new TextEncoder().encode("$ ls\r\n")),
    encodeFrame(
      KIND.HISTORY,
      encodeHistoryPayload(2, 0, 1, [
        cell({ codepoint: 0x68 }),
        cell({ codepoint: 0x69 }),
      ]),
    ),
    encodeResize(30, 100),
  ]);
}

/** Deterministic pseudo-random split points; a fixed seed keeps failures replayable. */
function splits(total: number, seed: number): number[] {
  const sizes: number[] = [];
  let state = seed;
  let remaining = total;
  while (remaining > 0) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    const size = Math.min(remaining, 1 + (state % 7));
    sizes.push(size);
    remaining -= size;
  }
  return sizes;
}

describe("encodeFrame", () => {
  it("writes kind then a big-endian length", () => {
    const frame = encodeFrame(KIND.DATA, new Uint8Array([1, 2, 3]));
    expect(Array.from(frame)).toEqual([0x44, 0, 0, 0, 3, 1, 2, 3]);
  });

  it("uses the ASCII letters the Rust constants use", () => {
    expect(KIND.CONTROL).toBe("C".charCodeAt(0));
    expect(KIND.DATA).toBe("D".charCodeAt(0));
    expect(KIND.RESIZE).toBe("R".charCodeAt(0));
    expect(KIND.EVENT).toBe("E".charCodeAt(0));
    expect(KIND.SNAPSHOT).toBe("S".charCodeAt(0));
    expect(KIND.HISTORY).toBe("H".charCodeAt(0));
    expect(KIND.GRID).toBe("G".charCodeAt(0));
    expect(KIND.FILE).toBe("F".charCodeAt(0));
    expect(KIND.UPLOAD).toBe("U".charCodeAt(0));
  });

  it("encodes a four-byte resize payload", () => {
    expect(Array.from(encodeResize(24, 80))).toEqual([
      0x52, 0, 0, 0, 4, 0, 24, 0, 80,
    ]);
  });

  it("refuses a dimension that is not a u16", () => {
    expect(() => encodeResize(-1, 80)).toThrow(ProtocolError);
    expect(() => encodeResize(24, 70000)).toThrow(ProtocolError);
  });
});

describe("encodeData", () => {
  it("splits at MAX_DATA_FRAME_SIZE, mirroring write_data", () => {
    const bytes = new Uint8Array(MAX_DATA_FRAME_SIZE * 2 + 7).fill(0x61);
    const frames = encodeData(bytes);
    expect(frames.length).toBe(3);
    expect(frames[0].length).toBe(5 + MAX_DATA_FRAME_SIZE);
    expect(frames[2].length).toBe(5 + 7);
  });

  it("turns empty input into one empty D frame", () => {
    const frames = encodeData(new Uint8Array(0));
    expect(frames.length).toBe(1);
    expect(Array.from(frames[0])).toEqual([0x44, 0, 0, 0, 0]);
  });

  it("round-trips a split payload back to the original bytes", () => {
    const bytes = new Uint8Array(MAX_DATA_FRAME_SIZE + 1000);
    for (let index = 0; index < bytes.length; index += 1) {
      bytes[index] = index & 0xff;
    }
    const { frames, reader } = collect();
    reader.push(concat(encodeData(bytes)));
    const rejoined = concat(
      frames.map((frame) => {
        if (frame.kind !== KIND.DATA) throw new Error("expected D");
        return frame.data;
      }),
    );
    expect(rejoined).toEqual(bytes);
  });
});

describe("FrameReader", () => {
  it("emits every frame of the attach transcript in order", () => {
    const { frames, reader } = collect();
    reader.push(attachTranscript());
    expect(frames.map((frame) => frame.kind)).toEqual([
      KIND.CONTROL,
      KIND.CONTROL,
      KIND.CONTROL,
      KIND.CONTROL,
      KIND.SNAPSHOT,
      KIND.EVENT,
      KIND.DATA,
      KIND.HISTORY,
      KIND.RESIZE,
    ]);
    expect(reader.pending).toBe(0);
  });

  /**
   * A WebSocket message boundary is not a frame boundary. Every split of the
   * same transcript — one byte at a time, random runs, one giant message —
   * must produce the identical frame sequence, or a transcript recorded over
   * the Unix socket does not replay here.
   */
  it("is invariant under arbitrary chunk boundaries", () => {
    const transcript = attachTranscript();
    const reference = collect();
    reference.reader.push(transcript);
    const expected = JSON.stringify(reference.frames, replacer);

    const chunkings: number[][] = [
      [transcript.length],
      new Array<number>(transcript.length).fill(1),
      [1, transcript.length - 1],
      [transcript.length - 1, 1],
      [4, transcript.length - 4], // splits the very first header
      [5, transcript.length - 5], // header exactly, then the body
      splits(transcript.length, 7),
      splits(transcript.length, 1337),
      splits(transcript.length, 20260818),
    ];

    for (const sizes of chunkings) {
      const { frames, reader } = collect();
      let offset = 0;
      for (const size of sizes) {
        reader.push(transcript.subarray(offset, offset + size));
        offset += size;
      }
      expect(offset).toBe(transcript.length);
      expect(reader.pending).toBe(0);
      expect(JSON.stringify(frames, replacer)).toBe(expected);
    }
  });

  it("holds a partial frame and reports it as pending", () => {
    const { frames, reader } = collect();
    const frame = encodeFrame(KIND.DATA, new Uint8Array([9, 9, 9]));
    reader.push(frame.subarray(0, 6));
    expect(frames.length).toBe(0);
    expect(reader.pending).toBe(6);
    reader.push(frame.subarray(6));
    expect(frames.length).toBe(1);
    expect(reader.pending).toBe(0);
  });

  it("accepts several frames inside one message", () => {
    const { frames, reader } = collect();
    reader.push(
      concat([
        encodeFrame(KIND.DATA, new Uint8Array([1])),
        encodeFrame(KIND.DATA, new Uint8Array([2])),
        encodeFrame(KIND.DATA, new Uint8Array([3])),
      ]),
    );
    expect(frames.length).toBe(3);
  });

  it("accepts an ArrayBuffer as well as a view", () => {
    const { frames, reader } = collect();
    const frame = encodeFrame(KIND.DATA, new Uint8Array([7]));
    const buffer = new ArrayBuffer(frame.length);
    new Uint8Array(buffer).set(frame);
    reader.push(buffer);
    expect(frames.length).toBe(1);
  });

  it("reads a view that does not start at byte zero of its buffer", () => {
    const { frames, reader } = collect();
    const frame = encodeFrame(KIND.DATA, new Uint8Array([5, 6]));
    const padded = new Uint8Array(frame.length + 8);
    padded.set(frame, 4);
    reader.push(padded.subarray(4, 4 + frame.length));
    expect(frames.length).toBe(1);
    if (frames[0].kind !== KIND.DATA) throw new Error("expected D");
    expect(Array.from(frames[0].data)).toEqual([5, 6]);
  });

  it("hands D payloads out as copies that survive later pushes", () => {
    const { frames, reader } = collect();
    reader.push(encodeFrame(KIND.DATA, new Uint8Array([1, 2, 3])));
    if (frames[0].kind !== KIND.DATA) throw new Error("expected D");
    const first = frames[0].data;
    reader.push(encodeFrame(KIND.DATA, new Uint8Array([9, 9, 9])));
    expect(Array.from(first)).toEqual([1, 2, 3]);
  });

  it("keeps G, F and U as raw payloads instead of failing", () => {
    const { frames, reader } = collect();
    reader.push(
      concat([
        encodeFrame(KIND.GRID, new Uint8Array([2, 0, 0])),
        encodeFrame(KIND.FILE, new Uint8Array(17)),
        encodeFrame(KIND.UPLOAD, new Uint8Array([1, 0x61, 0, 0, 0, 0, 0, 0, 0, 0])),
      ]),
    );
    expect(frames.map((frame) => frame.kind)).toEqual([
      KIND.GRID,
      KIND.FILE,
      KIND.UPLOAD,
    ]);
  });

  it("throws on an unknown kind and never resynchronises", () => {
    const { reader } = collect();
    expect(() => reader.push(new Uint8Array([0x5a, 0, 0, 0, 0]))).toThrow(
      ProtocolError,
    );
  });

  it("throws on a length over MAX_FRAME_SIZE before buffering the body", () => {
    const { reader } = collect();
    const header = new Uint8Array(5);
    header[0] = KIND.DATA;
    const oversize = MAX_FRAME_SIZE + 1;
    header[1] = (oversize >>> 24) & 0xff;
    header[2] = (oversize >>> 16) & 0xff;
    header[3] = (oversize >>> 8) & 0xff;
    header[4] = oversize & 0xff;
    expect(() => reader.push(header)).toThrow(/exceeds maximum/);
  });

  it("rejects a resize frame that is not four bytes", () => {
    const { reader } = collect();
    expect(() => reader.push(encodeFrame(KIND.RESIZE, new Uint8Array(3)))).toThrow(
      ProtocolError,
    );
  });

  it("drops buffered bytes on reset", () => {
    const { frames, reader } = collect();
    reader.push(new Uint8Array([KIND.DATA, 0, 0, 0, 4]));
    expect(reader.pending).toBe(5);
    reader.reset();
    expect(reader.pending).toBe(0);
    reader.push(encodeFrame(KIND.DATA, new Uint8Array([1])));
    expect(frames.length).toBe(1);
  });

  it("survives a frame emitted from inside an onFrame callback", () => {
    const seen: number[] = [];
    const reader: FrameReader = new FrameReader((frame) => {
      seen.push(frame.kind);
      if (seen.length === 1) {
        reader.push(encodeFrame(KIND.DATA, new Uint8Array([42])));
      }
    });
    reader.push(
      concat([
        encodeFrame(KIND.DATA, new Uint8Array([1])),
        encodeFrame(KIND.DATA, new Uint8Array([2])),
      ]),
    );
    expect(seen.length).toBe(3);
    expect(reader.pending).toBe(0);
  });
});

/** Typed arrays do not survive JSON on their own; compare them as plain arrays. */
function replacer(_key: string, value: unknown): unknown {
  return value instanceof Uint8Array ? Array.from(value) : value;
}
