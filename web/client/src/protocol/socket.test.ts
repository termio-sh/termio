import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Frame } from "./frame";
import { KIND, encodeFrame } from "./frame";
import {
  SUBPROTOCOL,
  TOKEN_SUBPROTOCOL_PREFIX,
  channelUrl,
  openChannel,
} from "./socket";
import { concat, encodeJsonFrame } from "./testTranscript";

/** Just enough WebSocket to drive `openChannel` without a network. */
class FakeWebSocket {
  static last: FakeWebSocket | null = null;

  readonly url: string;
  readonly protocols: string[];
  binaryType = "blob";
  readyState = 0;
  readonly sent: Uint8Array[] = [];
  closed: { code: number; reason: string } | null = null;
  private readonly listeners = new Map<string, ((event: unknown) => void)[]>();

  constructor(url: string, protocols?: string | string[]) {
    this.url = url;
    this.protocols =
      protocols === undefined
        ? []
        : Array.isArray(protocols)
          ? protocols
          : [protocols];
    FakeWebSocket.last = this;
  }

  addEventListener(type: string, listener: (event: unknown) => void): void {
    const bucket = this.listeners.get(type) ?? [];
    bucket.push(listener);
    this.listeners.set(type, bucket);
  }

  send(data: Uint8Array): void {
    if (this.readyState !== 1) throw new Error("InvalidStateError");
    this.sent.push(data);
  }

  close(code?: number, reason?: string): void {
    this.readyState = 3;
    this.closed = { code: code ?? 1005, reason: reason ?? "" };
  }

  emit(type: string, event: unknown): void {
    for (const listener of this.listeners.get(type) ?? []) {
      listener(event);
    }
  }

  open(): void {
    this.readyState = 1;
    this.emit("open", {});
  }

  /** The browser hands over an ArrayBuffer, so copy the view into its own. */
  deliver(bytes: Uint8Array): void {
    this.emit("message", { data: bytes.slice().buffer });
  }
}

const original = (globalThis as { WebSocket?: unknown }).WebSocket;

beforeEach(() => {
  (globalThis as { WebSocket?: unknown }).WebSocket = FakeWebSocket;
  FakeWebSocket.last = null;
});

afterEach(() => {
  (globalThis as { WebSocket?: unknown }).WebSocket = original;
});

interface Harness {
  frames: Frame[];
  closes: { code: number; reason: string }[];
  errors: Error[];
  socket: FakeWebSocket;
  channel: ReturnType<typeof openChannel>;
}

function harness(token = "s3cret"): Harness {
  const frames: Frame[] = [];
  const closes: { code: number; reason: string }[] = [];
  const errors: Error[] = [];
  const channel = openChannel({
    url: new URL("wss://box.tailnet.ts.net/termio/ws"),
    token,
    onFrame: (frame) => frames.push(frame),
    onClose: (info) => closes.push(info),
    onError: (error) => errors.push(error),
  });
  const socket = FakeWebSocket.last;
  if (!socket) throw new Error("no socket was constructed");
  return { frames, closes, errors, socket, channel };
}

describe("channelUrl", () => {
  it("resolves ws against the prefix that served index.html", () => {
    expect(
      channelUrl(new URL("https://box.tailnet.ts.net/termio/")).toString(),
    ).toBe("wss://box.tailnet.ts.net/termio/ws");
    expect(channelUrl(new URL("http://127.0.0.1:8790/")).toString()).toBe(
      "ws://127.0.0.1:8790/ws",
    );
    expect(
      channelUrl(new URL("https://box.example/termio/?session=s1")).toString(),
    ).toBe("wss://box.example/termio/ws");
  });
});

describe("openChannel", () => {
  it("offers termiod.v1 then the token subprotocol, and nothing else", () => {
    const { socket } = harness("tok-123");
    expect(socket.protocols).toEqual([SUBPROTOCOL, "termiod.token.tok-123"]);
    expect(TOKEN_SUBPROTOCOL_PREFIX).toBe("termiod.token.");
  });

  it("never puts the token in the URL", () => {
    const { socket } = harness("tok-123");
    expect(socket.url).toBe("wss://box.tailnet.ts.net/termio/ws");
    expect(socket.url).not.toContain("tok-123");
  });

  it("reads binary messages as ArrayBuffers", () => {
    const { socket } = harness();
    expect(socket.binaryType).toBe("arraybuffer");
  });

  it("holds frames written before the handshake and flushes them in order", () => {
    const { socket, channel } = harness();
    channel.sendControl({
      op: "hello",
      proto: 1,
      min_proto: 1,
      role: "attach",
      caps: ["events", "snapshot", "scrollback"],
      client: "termio-web/0.1.0",
    });
    channel.sendResize(24, 80);
    expect(socket.sent.length).toBe(0);
    socket.open();
    expect(socket.sent.length).toBe(2);
    expect(socket.sent[0][0]).toBe(KIND.CONTROL);
    expect(socket.sent[1][0]).toBe(KIND.RESIZE);
  });

  it("splits sendData at the data frame cap", () => {
    const { socket, channel } = harness();
    socket.open();
    channel.sendData(new Uint8Array(64 * 1024 + 1));
    expect(socket.sent.length).toBe(2);
  });

  it("reassembles frames across message boundaries", () => {
    const { socket, frames, channel } = harness();
    socket.open();
    const transcript = concat([
      encodeJsonFrame(KIND.CONTROL, {
        op: "hello_ok",
        proto: 1,
        caps: [],
        host_id: "h",
        host: "box",
        client_id: "c",
      }),
      encodeFrame(KIND.DATA, new TextEncoder().encode("hi")),
      encodeJsonFrame(KIND.EVENT, { ev: "ready", session: "s1" }),
    ]);
    for (let offset = 0; offset < transcript.length; offset += 3) {
      socket.deliver(transcript.subarray(offset, offset + 3));
    }
    expect(frames.map((frame) => frame.kind)).toEqual([
      KIND.CONTROL,
      KIND.DATA,
      KIND.EVENT,
    ]);
    expect(channel.readyState).toBe(1);
  });

  it("treats a text message as a protocol error and closes with 1003", () => {
    const { socket, errors } = harness();
    socket.open();
    socket.emit("message", { data: "hello" });
    expect(errors.length).toBe(1);
    expect(errors[0].message).toMatch(/text message/);
    expect(socket.closed?.code).toBe(1003);
  });

  it("closes with 1002 on a malformed stream and stops reading", () => {
    const { socket, errors, frames } = harness();
    socket.open();
    socket.deliver(new Uint8Array([0x5a, 0, 0, 0, 0]));
    expect(errors.length).toBe(1);
    expect(socket.closed?.code).toBe(1002);
    socket.deliver(encodeFrame(KIND.DATA, new Uint8Array([1])));
    expect(frames.length).toBe(0);
  });

  it("reports the close code and reason", () => {
    const { socket, closes } = harness();
    socket.open();
    socket.emit("close", { code: 1008, reason: "token rotated" });
    expect(closes).toEqual([{ code: 1008, reason: "token rotated" }]);
  });

  it("closes cleanly on detach", () => {
    const { socket, channel } = harness();
    socket.open();
    channel.close();
    expect(socket.closed?.code).toBe(1000);
  });
});
