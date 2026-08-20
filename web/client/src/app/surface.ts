/**
 * `SurfaceHandle` — everything that moves at PTY rate.
 *
 * It owns the attach WebSocket, the Wasm terminal, the renderer, the key
 * encoder, the history buffer and the rAF loop. React holds a ref to one of
 * these and nothing else: no cell, no dirty flag, no cursor position and no
 * byte counter is ever React state. What React is allowed to see is
 * `snapshot()`, which changes on transitions (writer, title, dims, an error)
 * and never per frame.
 *
 * The module imports no React and touches no DOM beyond the canvas it was
 * handed and the key events landing on it.
 */

import type { AttachMode, ControlIn, Event as ProtocolEvent } from "../protocol/control";
import type { Frame } from "../protocol/frame";
import { KIND } from "../protocol/frame";
import type { HistoryChunk, Snapshot } from "../protocol/payloads";
import { openChannel, type Channel, type ChannelOptions } from "../protocol/socket";
import type {
  FontSpec,
  Palette,
  RendererFactory,
  RendererStats,
  RowView,
  TerminalRenderer,
} from "../renderer/types";
import { createCanvas2dRenderer } from "../renderer/canvas2d";
import type { KeyEncoder, VtBinding, VtTerminal } from "../vt";

/** Matching the host's `SCROLLBACK_STAGE_MAX_BYTES`. Bytes, never lines. */
export const SCROLLBACK_BYTES = 1024 * 1024;

/**
 * A hard cap on retained history rows. The host stages at most 1 MiB of `H`,
 * so at 80 columns this is already more rows than it will ever send; it exists
 * so a 1-column session cannot turn that budget into a million objects.
 */
const MAX_HISTORY_ROWS = 4096;

const DEFAULT_FONT: FontSpec = {
  family:
    'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace',
  sizePx: 13,
  weightNormal: 400,
  weightBold: 700,
  lineHeight: 1.35,
};

/** Roughly one xterm blink period. The renderer owns no timer, so this is ours. */
const BLINK_INTERVAL_MS = 530;
const TITLE_POLL_MS = 250;
const FIT_DEBOUNCE_MS = 80;

export interface SurfaceState {
  phase: "connecting" | "attaching" | "live" | "closed" | "error";
  sessionId: string | null;
  name: string | null;
  title: string | null;
  mode: AttachMode;
  writer: boolean;
  rows: number;
  cols: number;
  /** `Event::Resynced` / `Event::VtStale`, surfaced in the chrome, not the console. */
  notice: string | null;
  error: string | null;
  scrollOffsetRows: number;
  historyRows: number;
}

export interface SurfaceHandle {
  subscribe(listener: () => void): () => void;
  snapshot(): SurfaceState;
  /** Re-measure the container; the writer runs the resize barrier from here. */
  fit(): void;
  setPalette(palette: Palette): void;
  setFont(font: FontSpec): void;
  paste(text: string): void;
  stats(): RendererStats | null;
  dispose(): void;
}

export interface SurfaceOptions {
  canvas: HTMLCanvasElement;
  /** The box the grid is measured against. Defaults to the canvas' parent. */
  container?: HTMLElement | null;
  url: URL;
  token: string;
  /** Session id or name — `Control::Attach.target`. */
  target: string;
  mode: AttachMode;
  binding: VtBinding;
  palette: Palette;
  client: string;
  font?: FontSpec;
  createRenderer?: RendererFactory;
  /** Injected in tests, all of them. Nothing here reads a global. */
  open?: (options: ChannelOptions) => Channel;
  requestFrame?: (callback: () => void) => number;
  cancelFrame?: (handle: number) => void;
  now?: () => number;
}

/** What React sees before the effect that opens the attach has run. */
export const IDLE_SURFACE_STATE: SurfaceState = Object.freeze({
  phase: "connecting",
  sessionId: null,
  name: null,
  title: null,
  mode: "observe",
  writer: false,
  rows: 24,
  cols: 80,
  notice: null,
  error: null,
  scrollOffsetRows: 0,
  historyRows: 0,
});

export function createSurface(options: SurfaceOptions): SurfaceHandle {
  return new Surface(options);
}

class Surface implements SurfaceHandle {
  private readonly options: SurfaceOptions;
  private readonly canvas: HTMLCanvasElement;
  private readonly listeners = new Set<() => void>();
  private readonly requestFrame: (callback: () => void) => number;
  private readonly cancelFrame: (handle: number) => void;
  private readonly now: () => number;

  private renderer: TerminalRenderer | null = null;
  private rendererStats: (() => RendererStats) | null = null;
  private channel: Channel | null = null;
  private terminal: VtTerminal | null = null;
  private encoder: KeyEncoder | null = null;

  private font: FontSpec;
  private palette: Palette;
  private frameHandle: number | null = null;
  private fitTimer: ReturnType<typeof setTimeout> | null = null;
  private disposed = false;

  /**
   * The resize barrier. Set on attach and whenever this client sends `R`;
   * cleared by `Event::Ready`. While it is set the loop paints nothing, which
   * is what "quiesce" means here — the socket keeps draining and bytes keep
   * reaching the Wasm, because a snapshot supersedes whatever they drew.
   */
  private barrier = true;
  private needsPaint = false;
  private seq = 0;

  private blinkOn = true;
  private lastBlinkAt = 0;
  private lastTitleCheck = 0;

  /** Index 0 is the row immediately above the viewport. */
  private history: (RowView | undefined)[] = [];
  private scrollOffset = 0;

  private state: SurfaceState;

  constructor(options: SurfaceOptions) {
    this.options = options;
    this.canvas = options.canvas;
    this.font = options.font ?? DEFAULT_FONT;
    this.palette = options.palette;
    this.requestFrame =
      options.requestFrame ?? ((callback) => requestAnimationFrame(callback));
    this.cancelFrame = options.cancelFrame ?? ((handle) => cancelAnimationFrame(handle));
    this.now = options.now ?? (() => Date.now());

    this.state = {
      phase: "connecting",
      sessionId: null,
      name: null,
      title: null,
      mode: options.mode,
      writer: false,
      rows: 24,
      cols: 80,
      notice: null,
      error: null,
      scrollOffsetRows: 0,
      historyRows: 0,
    };

    const factory = options.createRenderer ?? createCanvas2dRenderer;
    const renderer = factory(this.canvas, this.font);
    if (!renderer) {
      this.patch({
        phase: "error",
        error: "This browser gave us no 2D canvas context, so there is nothing to paint on.",
      });
      return;
    }
    this.renderer = renderer;
    this.rendererStats = () => renderer.stats();
    renderer.setPalette(this.palette);

    const measured = this.measureGrid();
    this.state = { ...this.state, rows: measured.rows, cols: measured.cols };

    this.canvas.addEventListener("keydown", this.onKeyDown);
    this.canvas.addEventListener("keyup", this.onKeyUp);
    this.canvas.addEventListener("paste", this.onPaste as EventListener);
    this.canvas.addEventListener("wheel", this.onWheel, { passive: false });

    const open = options.open ?? openChannel;
    this.channel = open({
      url: options.url,
      token: options.token,
      onFrame: this.onFrame,
      onClose: (info) => {
        if (this.disposed) return;
        this.patch({
          phase: "closed",
          error:
            info.code === 1000 || info.code === 1005
              ? this.state.error
              : `attach closed (${info.code}${info.reason ? `: ${info.reason}` : ""})`,
        });
      },
      onError: (error) => {
        if (this.disposed) return;
        this.patch({ phase: "error", error: error.message });
      },
    });

    this.channel.sendControl({
      op: "hello",
      proto: 1,
      min_proto: 1,
      role: "attach",
      // `grid_diff` is deliberately absent: a Replica asks for snapshots and
      // scrollback, and never for a host-side grid on the grounds that it is a
      // browser.
      caps: ["events", "snapshot", "scrollback"],
      client: options.client,
    });

    this.frameHandle = this.requestFrame(this.tick);
  }

  // ── the frame loop ────────────────────────────────────────────────────────

  private readonly tick = (): void => {
    if (this.disposed) return;
    this.frameHandle = this.requestFrame(this.tick);

    const terminal = this.terminal;
    const renderer = this.renderer;
    if (!terminal || !renderer || this.barrier) return;

    const now = this.now();
    if (now - this.lastBlinkAt >= BLINK_INTERVAL_MS) {
      this.lastBlinkAt = now;
      this.blinkOn = !this.blinkOn;
      // Only a blinking cursor needs the repaint, and only the loop knows the
      // phase; the seam hands the renderer no timer on purpose.
      this.needsPaint = true;
    }

    if (!this.needsPaint) return;
    // Mode 2026: inside a synchronized-output block the program is mid-update.
    // `needsPaint` stays set, so the frame lands on the tick after it clears.
    if (terminal.syncOutputActive()) return;

    this.needsPaint = false;
    const scroll = this.scrollOffset;
    const history = this.visibleHistory(scroll, this.state.rows);
    terminal.readFrame((frame) => {
      frame.scrollOffsetRows = scroll;
      if (frame.cursor.blinking && !this.blinkOn) frame.cursor.visible = false;
      renderer.draw(frame, history);
    });
  };

  // ── protocol ──────────────────────────────────────────────────────────────

  private readonly onFrame = (frame: Frame): void => {
    if (this.disposed) return;
    switch (frame.kind) {
      case KIND.CONTROL:
        this.onControl(frame.control as ControlIn);
        return;
      case KIND.EVENT:
        this.onEvent(frame.event);
        return;
      case KIND.SNAPSHOT:
        this.onSnapshot(frame.snapshot);
        return;
      case KIND.DATA:
        this.onData(frame.data);
        return;
      case KIND.HISTORY:
        this.onHistory(frame.history);
        return;
      default:
        // `G` / `F` / `U`: never negotiated by this client. A frame we did not
        // ask for is skipped, not an error.
        return;
    }
  };

  private onControl(message: ControlIn): void {
    switch (message.op) {
      case "hello_ok": {
        this.seq += 1;
        this.patch({ phase: "attaching" });
        this.channel?.sendControl({
          op: "attach",
          target: this.options.target,
          rows: this.state.rows,
          cols: this.state.cols,
          // Always explicit. The host's own default is `interact`, and opening
          // a page must not steal the write token from a Mac.
          mode: this.options.mode,
          seq: this.seq,
        });
        return;
      }
      case "hello_err":
        this.patch({
          phase: "error",
          error: `host refused the handshake (${message.code})`,
        });
        return;
      case "attached":
        this.onAttached(message);
        return;
      case "error":
        this.patch({ error: `${message.code}: ${message.message}` });
        return;
      case "exited":
        this.patch({ phase: "closed", notice: `session exited (status ${message.status})` });
        return;
      default:
        return;
    }
  }

  private onAttached(message: Extract<ControlIn, { op: "attached" }>): void {
    const rows = message.rows;
    const cols = message.cols;
    // AUTHORITATIVE dims. An observer parses at these and letterboxes; parsing
    // at the window size is a conformance bug.
    this.ensureTerminal(rows, cols);
    this.applyGeometry(rows, cols);
    this.barrier = true;
    this.patch({
      phase: "attaching",
      sessionId: message.session_id || message.id,
      name: message.name,
      writer: message.writer,
      rows,
      cols,
    });
  }

  private onEvent(event: ProtocolEvent): void {
    switch (event.ev) {
      case "ready":
        // This, not the first `D`, is what ends the barrier.
        this.barrier = false;
        this.needsPaint = true;
        this.patch({ phase: "live" });
        return;
      case "resized": {
        // Someone else resized the session. The dims are authoritative; the
        // terminal follows them immediately rather than waiting on a snapshot
        // that may not be addressed to us.
        this.ensureTerminal(event.rows, event.cols);
        this.terminal?.resize(event.rows, event.cols);
        this.applyGeometry(event.rows, event.cols);
        this.needsPaint = true;
        this.patch({ rows: event.rows, cols: event.cols });
        return;
      }
      case "writer_changed":
        return;
      case "status":
        if (event.title !== undefined) this.patch({ title: event.title });
        return;
      case "resynced":
        // The screen comes back; history does not. Saying so is the honest
        // surface — the page must not pretend the hole is not there.
        this.history = [];
        this.scrollOffset = 0;
        this.patch({
          notice: `resynced (${event.reason}); scrollback above this point is gone`,
          scrollOffsetRows: 0,
          historyRows: 0,
        });
        return;
      case "vt_stale":
        this.patch({
          notice: `snapshots are degraded (${event.reason}); the screen may be incomplete`,
        });
        return;
      case "session_exited":
        this.patch({ phase: "closed", notice: `session exited (status ${event.status})` });
        return;
      default:
        return;
    }
  }

  private onSnapshot(snapshot: Snapshot): void {
    const terminal = this.ensureTerminal(snapshot.rows, snapshot.cols);
    if (!terminal) return;
    if (terminal.rows !== snapshot.rows || terminal.cols !== snapshot.cols) {
      terminal.resize(snapshot.rows, snapshot.cols);
      this.applyGeometry(snapshot.rows, snapshot.cols);
    }
    if (snapshot.vt) {
      // EXACTLY these bytes: not the header, not the title, not the length
      // prefix, and no client-side `ESC[2J ESC[H`. The prologue is inside.
      terminal.write(snapshot.vt);
      this.needsPaint = true;
    } else {
      // v3 packed cells. A Replica that negotiated `snapshot` is always sent
      // v2; arriving here means the host answered a question we did not ask.
      this.patch({
        notice: "host sent a packed-cell snapshot; this client renders VT snapshots",
      });
    }
    this.patch({ rows: snapshot.rows, cols: snapshot.cols, title: snapshot.title || null });
  }

  private onData(data: Uint8Array): void {
    const terminal = this.terminal;
    if (!terminal || data.length === 0) return;
    terminal.write(data);
    this.needsPaint = true;

    const now = this.now();
    if (now - this.lastTitleCheck >= TITLE_POLL_MS) {
      this.lastTitleCheck = now;
      const title = terminal.title();
      if (title !== this.state.title) this.patch({ title });
    }
  }

  private onHistory(chunk: HistoryChunk): void {
    // `H` never enters the Wasm. Its rows are already the seam's shape, and the
    // renderer paints them through the same path as live rows.
    for (const row of chunk.rows) {
      const distance = -row.y - 1;
      if (distance < 0 || distance >= MAX_HISTORY_ROWS) continue;
      this.history[distance] = row;
    }
    this.patch({ historyRows: this.historyDepth() });
    if (this.scrollOffset > 0) this.needsPaint = true;
  }

  // ── geometry and the resize barrier ───────────────────────────────────────

  fit(): void {
    if (this.disposed || !this.renderer) return;
    if (this.fitTimer !== null) clearTimeout(this.fitTimer);
    this.fitTimer = setTimeout(() => {
      this.fitTimer = null;
      this.applyFit();
    }, FIT_DEBOUNCE_MS);
  }

  private applyFit(): void {
    if (this.disposed || !this.renderer) return;
    const measured = this.measureGrid();
    if (!this.state.writer || !this.channel || !this.terminal) {
      // An observer never sends `R`. It keeps parsing at the authoritative dims
      // and letterboxes whatever box the CSS gave it.
      this.applyGeometry(this.state.rows, this.state.cols);
      this.needsPaint = true;
      return;
    }
    if (measured.rows === this.state.rows && measured.cols === this.state.cols) {
      this.applyGeometry(this.state.rows, this.state.cols);
      return;
    }
    // The barrier: quiesce, send `R`, wait for `S` + `ready`. The terminal is
    // NOT resized here — the snapshot carries the dims the host settled on.
    this.barrier = true;
    this.channel.sendResize(measured.rows, measured.cols);
  }

  private measureGrid(): { rows: number; cols: number } {
    const renderer = this.renderer;
    if (!renderer) return { rows: this.state.rows, cols: this.state.cols };
    const cell = renderer.measure(this.font);
    const box = this.options.container ?? this.canvas.parentElement;
    const width = box?.clientWidth ?? 0;
    const height = box?.clientHeight ?? 0;
    const cols = Math.max(1, Math.floor(width / cell.widthPx) || this.state.cols);
    const rows = Math.max(1, Math.floor(height / cell.heightPx) || this.state.rows);
    return { rows, cols };
  }

  private applyGeometry(rows: number, cols: number): void {
    const renderer = this.renderer;
    if (!renderer) return;
    const cell = renderer.measure(this.font);
    const box = this.options.container ?? this.canvas.parentElement;
    const width = box?.clientWidth ?? cols * cell.widthPx;
    const height = box?.clientHeight ?? rows * cell.heightPx;
    // Letterboxing: the grid is the session's, the box is the browser's, and
    // the difference is padding rather than a reparse at the window size.
    const left = Math.max(0, Math.floor((width - cols * cell.widthPx) / 2));
    const top = Math.max(0, Math.floor((height - rows * cell.heightPx) / 2));
    renderer.setGeometry({
      cols,
      rows,
      cell,
      devicePixelRatio: typeof devicePixelRatio === "number" ? devicePixelRatio : 1,
      padding: { top, left },
    });
    this.needsPaint = true;
  }

  // ── input ─────────────────────────────────────────────────────────────────

  private readonly onKeyDown = (event: KeyboardEvent): void => {
    this.sendKey(event, "down");
  };

  private readonly onKeyUp = (event: KeyboardEvent): void => {
    this.sendKey(event, "up");
  };

  private sendKey(event: KeyboardEvent, phase: "down" | "up"): void {
    if (this.disposed) return;
    const terminal = this.terminal;
    const channel = this.channel;
    if (!terminal || !channel) return;
    // Observers never send `D`. The host would answer `not_writer`; not sending
    // it is the same rule stated on this side of the wire.
    if (!this.state.writer) return;

    const encoder = this.ensureEncoder();
    if (!encoder) return;
    // Modes come from the VT after every write batch rather than being guessed:
    // DECCKM and the kitty flags are the terminal's state, not the app's.
    encoder.setModes(terminal.keyEncoderModes());
    const bytes = encoder.encode(event, phase);
    if (bytes.length === 0) return;
    event.preventDefault();
    channel.sendData(bytes);
    if (this.scrollOffset !== 0) {
      this.scrollOffset = 0;
      this.needsPaint = true;
      this.patch({ scrollOffsetRows: 0 });
    }
  }

  private readonly onPaste = (event: ClipboardEvent): void => {
    const text = event.clipboardData?.getData("text");
    if (!text) return;
    event.preventDefault();
    this.paste(text);
  };

  paste(text: string): void {
    if (this.disposed || !this.state.writer) return;
    const terminal = this.terminal;
    const channel = this.channel;
    if (!terminal || !channel) return;
    const encoder = this.ensureEncoder();
    if (!encoder) return;
    encoder.setModes(terminal.keyEncoderModes());
    const bytes = encoder.encodePaste(text);
    if (bytes.length > 0) channel.sendData(bytes);
  }

  private readonly onWheel = (event: WheelEvent): void => {
    const depth = this.historyDepth();
    if (depth === 0) return;
    // deltaMode 1 is lines, 0 is pixels. Three lines a notch is the platform
    // convention everywhere that has one.
    const lines = event.deltaMode === 1 ? event.deltaY : event.deltaY / 40;
    const next = clamp(this.scrollOffset - Math.round(lines), 0, depth);
    if (next === this.scrollOffset) return;
    event.preventDefault();
    this.scrollOffset = next;
    this.needsPaint = true;
    this.patch({ scrollOffsetRows: next });
  };

  // ── plumbing ──────────────────────────────────────────────────────────────

  private ensureTerminal(rows: number, cols: number): VtTerminal | null {
    if (this.terminal) return this.terminal;
    if (this.disposed) return null;
    try {
      this.terminal = this.options.binding.createTerminal({
        rows,
        cols,
        scrollbackBytes: SCROLLBACK_BYTES,
      });
    } catch (error) {
      this.patch({ phase: "error", error: describe(error) });
      return null;
    }
    return this.terminal;
  }

  private ensureEncoder(): KeyEncoder | null {
    if (this.encoder) return this.encoder;
    try {
      this.encoder = this.options.binding.createKeyEncoder();
    } catch (error) {
      this.patch({ error: describe(error) });
      return null;
    }
    return this.encoder;
  }

  private historyDepth(): number {
    // Only the contiguous run above the viewport is scrollable; a hole means
    // the chunk that fills it has not arrived yet.
    let depth = 0;
    while (this.history[depth] !== undefined) depth += 1;
    return depth;
  }

  private visibleHistory(scroll: number, rows: number): RowView[] | undefined {
    if (scroll <= 0) return undefined;
    const visible: RowView[] = [];
    for (let distance = 0; distance < scroll && distance < this.history.length; distance += 1) {
      const row = this.history[distance];
      if (!row) continue;
      // `y + scrollOffsetRows` is the screen line; anything off the top is the
      // renderer's to clip, but not sending it saves the map insert.
      if (row.y + scroll >= 0 && row.y + scroll < rows) visible.push(row);
    }
    return visible.length > 0 ? visible : undefined;
  }

  private patch(patch: Partial<SurfaceState>): void {
    let changed = false;
    for (const [key, value] of Object.entries(patch)) {
      if (this.state[key as keyof SurfaceState] !== value) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    this.state = { ...this.state, ...patch };
    for (const listener of [...this.listeners]) listener();
  }

  // ── public surface ────────────────────────────────────────────────────────

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  snapshot(): SurfaceState {
    return this.state;
  }

  setPalette(palette: Palette): void {
    this.palette = palette;
    // One call, a full repaint, every tagged colour re-resolved. No cell is
    // re-created and the Wasm never hears about it.
    this.renderer?.setPalette(palette);
    this.needsPaint = true;
  }

  setFont(font: FontSpec): void {
    this.font = font;
    this.renderer?.measure(font);
    this.applyGeometry(this.state.rows, this.state.cols);
  }

  stats(): RendererStats | null {
    return this.rendererStats?.() ?? null;
  }

  /**
   * Idempotent and complete: StrictMode double-invokes effects, so a second
   * call must be a no-op rather than a double free, and the first must leave
   * behind no socket, no Wasm terminal, no listener and no scheduled frame.
   */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.frameHandle !== null) {
      this.cancelFrame(this.frameHandle);
      this.frameHandle = null;
    }
    if (this.fitTimer !== null) {
      clearTimeout(this.fitTimer);
      this.fitTimer = null;
    }
    this.canvas.removeEventListener("keydown", this.onKeyDown);
    this.canvas.removeEventListener("keyup", this.onKeyUp);
    this.canvas.removeEventListener("paste", this.onPaste as EventListener);
    this.canvas.removeEventListener("wheel", this.onWheel);
    this.channel?.close();
    this.channel = null;
    this.encoder?.dispose();
    this.encoder = null;
    this.terminal?.dispose();
    this.terminal = null;
    this.renderer?.dispose();
    this.renderer = null;
    this.rendererStats = null;
    this.history = [];
    this.listeners.clear();
  }
}

function clamp(value: number, low: number, high: number): number {
  return value < low ? low : value > high ? high : value;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
