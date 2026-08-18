/**
 * A whole client with no browser in it.
 *
 * The surface takes its channel, its renderer, its clock and its frame
 * scheduler as options precisely so this file can exist: every test below
 * drives a real `SurfaceHandle`, a real protocol codec and the real vt binding
 * (over the fake ghostty exports), and the only things faked are the four
 * seams the design already draws.
 */

import { FrameReader, KIND, type Frame } from "../../protocol/frame";
import type { Channel, ChannelOptions } from "../../protocol/socket";
import {
  concat,
  encodeJsonFrame,
  encodeSnapshotVtPayload,
} from "../../protocol/testTranscript";
import { encodeFrame } from "../../protocol/frame";
import type {
  CellMetrics,
  FontSpec,
  Geometry,
  Palette,
  RendererStats,
  RenderFrame,
  RowView,
  TerminalRenderer,
} from "../../renderer/types";
import { createFakeGhostty, type FakeGhostty } from "../../vt/__fixtures__/fakeGhostty";
import { bindingFromExports, type VtBinding, type VtTerminal } from "../../vt";
import { createSurface, type SurfaceHandle, type SurfaceOptions } from "../surface";
import { buildPalette } from "../theme";

export class FakeChannel implements Channel {
  readonly options: ChannelOptions;
  readonly outgoing: Frame[] = [];
  readonly rawOutgoing: Uint8Array[] = [];
  closed = false;
  private readonly reader = new FrameReader((frame) => this.outgoing.push(frame));

  constructor(options: ChannelOptions) {
    this.options = options;
  }

  send(frame: Uint8Array): void {
    this.rawOutgoing.push(frame);
    this.reader.push(frame);
  }
  sendControl(msg: Parameters<Channel["sendControl"]>[0]): void {
    this.send(encodeJsonFrame(KIND.CONTROL, msg));
  }
  sendData(bytes: Uint8Array): void {
    this.send(encodeFrame(KIND.DATA, bytes));
  }
  sendResize(rows: number, cols: number): void {
    const payload = new Uint8Array(4);
    new DataView(payload.buffer).setUint16(0, rows);
    new DataView(payload.buffer).setUint16(2, cols);
    this.send(encodeFrame(KIND.RESIZE, payload));
  }
  get readyState(): number {
    return this.closed ? 3 : 1;
  }
  close(): void {
    this.closed = true;
  }

  /** Host → client, through a real FrameReader so chunking is exercised. */
  deliver(...chunks: Uint8Array[]): void {
    deliverThrough(this.options, concat(chunks));
  }

  /**
   * The client's own Control frames, read off the raw bytes.
   *
   * `FrameReader` decodes the host's half of the vocabulary — `hello_ok`,
   * `sessions`, `attached` — so a client `hello` comes back through it as
   * `{op:"unknown"}`. The wire is JSON either way, and the test wants to assert
   * what actually went out.
   */
  control(index: number): Record<string, unknown> {
    const controls = this.rawOutgoing.filter((frame) => frame[0] === KIND.CONTROL);
    const frame = controls[index];
    if (!frame) throw new Error(`no outgoing Control frame ${index}`);
    return JSON.parse(new TextDecoder().decode(frame.subarray(5))) as Record<string, unknown>;
  }

  kinds(): number[] {
    return this.outgoing.map((frame) => frame.kind);
  }

  data(): Uint8Array[] {
    return this.outgoing
      .filter((frame): frame is Extract<Frame, { kind: typeof KIND.DATA }> => frame.kind === KIND.DATA)
      .map((frame) => frame.data);
  }
}

function deliverThrough(options: ChannelOptions, bytes: Uint8Array): void {
  const reader = new FrameReader(options.onFrame);
  reader.push(bytes);
  if (reader.pending !== 0) {
    throw new Error(`test delivered ${reader.pending} trailing bytes`);
  }
}

export interface DrawCall {
  dirty: RenderFrame["dirty"];
  scrollOffsetRows: number;
  cursorVisible: boolean;
  /** Text of every row, viewport then history, so a test can assert pixels-ish. */
  viewport: string[];
  history: string[];
}

export class RecordingRenderer implements TerminalRenderer {
  readonly draws: DrawCall[] = [];
  readonly palettes: Palette[] = [];
  geometry: Geometry | null = null;
  disposed = 0;
  cell: CellMetrics = { widthPx: 8, heightPx: 16, baselinePx: 12 };

  measure(_font: FontSpec): CellMetrics {
    return this.cell;
  }
  setGeometry(geometry: Geometry): void {
    this.geometry = geometry;
  }
  setPalette(palette: Palette): void {
    this.palettes.push(palette);
  }
  draw(frame: RenderFrame, history?: RowView[]): void {
    this.draws.push({
      dirty: frame.dirty,
      scrollOffsetRows: frame.scrollOffsetRows,
      cursorVisible: frame.cursor.visible,
      viewport: frame.rows_.map(rowText),
      history: (history ?? []).map(rowText),
    });
  }
  dispose(): void {
    this.disposed += 1;
  }
  stats(): RendererStats {
    return {
      implementation: "canvas2d",
      framesPainted: this.draws.length,
      fullRedraws: 0,
      droppedFrames: 0,
      frameTimeP50Ms: 0,
      frameTimeP95Ms: 0,
    };
  }
}

function rowText(row: RowView): string {
  return row.cells
    .map((cell) =>
      cell.grapheme ?? (cell.codepoint === 0 ? " " : String.fromCodePoint(cell.codepoint)),
    )
    .join("")
    .replace(/\s+$/, "");
}

/** A canvas-shaped object with a listener table and a measurable parent. */
export class FakeCanvas {
  readonly listeners = new Map<string, Set<(event: unknown) => void>>();
  parentElement = { clientWidth: 640, clientHeight: 384 } as unknown as HTMLElement;

  addEventListener(type: string, listener: (event: unknown) => void): void {
    let set = this.listeners.get(type);
    if (!set) {
      set = new Set();
      this.listeners.set(type, set);
    }
    set.add(listener);
  }
  removeEventListener(type: string, listener: (event: unknown) => void): void {
    this.listeners.get(type)?.delete(listener);
  }
  dispatch(type: string, event: unknown): void {
    for (const listener of [...(this.listeners.get(type) ?? [])]) listener(event);
  }
  listenerCount(): number {
    let total = 0;
    for (const set of this.listeners.values()) total += set.size;
    return total;
  }
}

export interface Harness {
  surface: SurfaceHandle;
  channel: FakeChannel;
  canvas: FakeCanvas;
  renderer: RecordingRenderer;
  fake: FakeGhostty;
  binding: VtBinding;
  /** Every byte written into the Wasm, in order. */
  writes: Uint8Array[];
  terminals: VtTerminal[];
  runFrame(): void;
  advance(ms: number): void;
  dispose(): void;
}

export interface HarnessOptions {
  mode?: "observe" | "interact";
  palette?: Palette;
  /** A canvas-shaped object of the caller's own, for the integration test. */
  canvas?: HTMLCanvasElement;
  /** Build the real Canvas 2D renderer over `canvas` instead of recording. */
  realRenderer?: boolean;
  overrides?: Partial<SurfaceOptions>;
}

export function createHarness(options: HarnessOptions = {}): Harness {
  const fake = createFakeGhostty();
  const inner = bindingFromExports(fake.exports);
  const writes: Uint8Array[] = [];
  const terminals: VtTerminal[] = [];
  const binding: VtBinding = {
    ...inner,
    createTerminal(terminalOptions) {
      const terminal = inner.createTerminal(terminalOptions);
      const write = terminal.write.bind(terminal);
      terminal.write = (bytes: Uint8Array) => {
        writes.push(bytes.slice());
        write(bytes);
      };
      terminals.push(terminal);
      return terminal;
    },
  };

  const canvas = (options.canvas as unknown as FakeCanvas | undefined) ?? new FakeCanvas();
  const renderer = new RecordingRenderer();
  let channel: FakeChannel | null = null;
  const pending: (() => void)[] = [];
  let clock = 1_000;

  const surface = createSurface({
    canvas: canvas as unknown as HTMLCanvasElement,
    url: new URL("wss://box.example/termio/ws"),
    token: "test-token",
    target: "session-1",
    mode: options.mode ?? "observe",
    binding,
    palette: options.palette ?? buildPalette("dark"),
    client: "termio-web/test",
    open: (channelOptions) => {
      channel = new FakeChannel(channelOptions);
      return channel;
    },
    ...(options.realRenderer ? {} : { createRenderer: () => renderer }),
    requestFrame: (callback) => pending.push(callback),
    cancelFrame: () => {
      pending.length = 0;
    },
    now: () => clock,
    ...options.overrides,
  });

  if (!channel) throw new Error("the surface never opened a channel");

  return {
    surface,
    channel,
    canvas,
    renderer,
    fake,
    binding,
    writes,
    terminals,
    runFrame(): void {
      const callbacks = pending.splice(0, pending.length);
      for (const callback of callbacks) callback();
    },
    advance(ms: number): void {
      clock += ms;
    },
    dispose(): void {
      surface.dispose();
      inner.dispose();
    },
  };
}

// ── host-side frames the tests replay ───────────────────────────────────────

export function helloOk(): Uint8Array {
  return encodeJsonFrame(KIND.CONTROL, {
    op: "hello_ok",
    proto: 1,
    caps: ["events", "snapshot", "scrollback"],
    host_id: "host-1",
    host: "box",
    client_id: "client-9",
  });
}

export function attached(overrides: Record<string, unknown> = {}): Uint8Array {
  return encodeJsonFrame(KIND.CONTROL, {
    op: "attached",
    id: "session-1",
    name: "shell",
    session_id: "session-1",
    writer: false,
    rows: 6,
    cols: 20,
    re: 1,
    ...overrides,
  });
}

export function snapshot(vt: string, rows = 6, cols = 20, title = ""): Uint8Array {
  return encodeFrame(
    KIND.SNAPSHOT,
    encodeSnapshotVtPayload({ rows, cols, title }, new TextEncoder().encode(vt)),
  );
}

export function ready(): Uint8Array {
  return encodeJsonFrame(KIND.EVENT, { ev: "ready", session: "session-1" });
}

export function data(text: string): Uint8Array {
  return encodeFrame(KIND.DATA, new TextEncoder().encode(text));
}

export function event(value: Record<string, unknown>): Uint8Array {
  return encodeJsonFrame(KIND.EVENT, value);
}

export function control(value: Record<string, unknown>): Uint8Array {
  return encodeJsonFrame(KIND.CONTROL, value);
}

/** The frozen attach shape: hello_ok → attached → S → ready. */
export function completeAttach(
  harness: { channel: FakeChannel },
  options: { writer?: boolean; vt?: string; rows?: number; cols?: number } = {},
): void {
  harness.channel.deliver(helloOk());
  harness.channel.deliver(
    attached({
      writer: options.writer ?? false,
      rows: options.rows ?? 6,
      cols: options.cols ?? 20,
    }),
  );
  harness.channel.deliver(
    snapshot(options.vt ?? "hello", options.rows ?? 6, options.cols ?? 20),
  );
  harness.channel.deliver(ready());
}

export function keyEvent(overrides: Partial<KeyboardEvent> & { key: string }): KeyboardEvent {
  let prevented = false;
  return {
    key: overrides.key,
    code: overrides.code ?? `Key${overrides.key.toUpperCase()}`,
    ctrlKey: overrides.ctrlKey ?? false,
    altKey: overrides.altKey ?? false,
    shiftKey: overrides.shiftKey ?? false,
    metaKey: overrides.metaKey ?? false,
    repeat: false,
    isComposing: false,
    location: 0,
    getModifierState: () => false,
    preventDefault: () => {
      prevented = true;
    },
    get defaultPrevented() {
      return prevented;
    },
  } as unknown as KeyboardEvent;
}
