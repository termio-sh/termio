/**
 * One WebSocket = one protocol channel. No multiplexing, no channel ids:
 * several sessions in one page are several sockets.
 */
import type { ControlOut } from "./control";
import { ProtocolError } from "./errors";
import type { Frame } from "./frame";
import {
  FrameReader,
  encodeControl,
  encodeData,
  encodeResize,
} from "./frame";

/**
 * Subprotocols offered, in this order and no others. The token entry is what
 * `token_from_protocols` in `termiod/src/wss.rs` matches; `termiod.v1` is the
 * one the server selects and echoes back, so the credential never lands in a
 * response header a proxy will log.
 */
export const SUBPROTOCOL = "termiod.v1";
export const TOKEN_SUBPROTOCOL_PREFIX = "termiod.token.";

export interface ChannelOptions {
  url: URL; // new URL("ws", new URL(".", location.href)), scheme swapped to wss:/ws:
  token: string;
  onFrame: (frame: Frame) => void;
  onClose: (info: { code: number; reason: string }) => void;
  onError: (error: Error) => void;
}

export interface Channel {
  send(frame: Uint8Array): void; // already-encoded frame bytes
  sendControl(msg: ControlOut): void;
  sendData(bytes: Uint8Array): void; // splits at MAX_DATA_FRAME_SIZE
  sendResize(rows: number, cols: number): void;
  readonly readyState: number;
  close(): void;
}

/**
 * TypeScript has modelled `Uint8Array` as possibly SharedArrayBuffer-backed
 * since 5.7, and `WebSocket.send` takes only the non-shared form. Every frame
 * here comes from `encodeFrame`, which allocates its own plain ArrayBuffer, so
 * this narrows a type the encoder already guarantees. It copies nothing.
 */
function sendable(frame: Uint8Array): Uint8Array<ArrayBuffer> {
  return frame as Uint8Array<ArrayBuffer>;
}

/**
 * The token NEVER rides the query string. `?t=` on /ws is refused host-side.
 * The page reads it once from `location.hash` (`#t=…`), stashes it in
 * sessionStorage, and clears the hash.
 *
 * `binaryType` is "arraybuffer". A text message from the host is a protocol
 * error: close and surface it.
 */
export function openChannel(options: ChannelOptions): Channel {
  const socket = new WebSocket(options.url.toString(), [
    SUBPROTOCOL,
    `${TOKEN_SUBPROTOCOL_PREFIX}${options.token}`,
  ]);
  socket.binaryType = "arraybuffer";

  // Frames written before the handshake completes are held here rather than
  // thrown away: `hello` has to be the first frame on the socket, and the
  // caller should not have to wait on an open event to say so.
  let backlog: Uint8Array[] | null = [];
  let failed = false;

  const reader = new FrameReader(options.onFrame);

  /** One fault path: report, then close. A dead stream is never resumed. */
  const fail = (error: Error, code: number): void => {
    if (failed) return;
    failed = true;
    options.onError(error);
    reader.reset();
    try {
      socket.close(code, error.message.slice(0, 120));
    } catch {
      // A socket that is already closing has nothing to say about it.
    }
  };

  socket.addEventListener("open", () => {
    const queued = backlog ?? [];
    backlog = null;
    for (const frame of queued) {
      socket.send(sendable(frame));
    }
  });

  socket.addEventListener("message", (event: MessageEvent) => {
    if (failed) return;
    if (typeof event.data === "string") {
      // A text message means someone is speaking a dialect. 1003 is
      // "unsupported data", which is exactly what happened.
      fail(new ProtocolError("host sent a text message"), 1003);
      return;
    }
    try {
      reader.push(event.data as ArrayBuffer);
    } catch (error) {
      fail(
        error instanceof Error ? error : new ProtocolError(String(error)),
        1002,
      );
    }
  });

  socket.addEventListener("error", () => {
    // The browser deliberately gives no detail here; the close event that
    // follows carries the code.
    options.onError(new Error("websocket error"));
  });

  socket.addEventListener("close", (event: CloseEvent) => {
    backlog = null;
    options.onClose({ code: event.code, reason: event.reason });
  });

  const send = (frame: Uint8Array): void => {
    if (failed) return;
    if (backlog) {
      backlog.push(frame);
      return;
    }
    socket.send(sendable(frame));
  };

  return {
    send,
    sendControl(msg: ControlOut): void {
      send(encodeControl(msg));
    },
    sendData(bytes: Uint8Array): void {
      for (const frame of encodeData(bytes)) {
        send(frame);
      }
    },
    sendResize(rows: number, cols: number): void {
      send(encodeResize(rows, cols));
    },
    get readyState(): number {
      return socket.readyState;
    },
    close(): void {
      backlog = null;
      socket.close(1000, "detach");
    },
  };
}

/**
 * `wss:` for an `https:` page, `ws:` otherwise, against the prefix that served
 * `index.html` — `/` behind Caddy's `handle_path`, `/termio/` behind Tailscale
 * Serve. An absolute path here is the build-config bug the relative base
 * exists to prevent.
 */
export function channelUrl(pageUrl: URL): URL {
  const url = new URL("ws", new URL(".", pageUrl));
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url;
}
