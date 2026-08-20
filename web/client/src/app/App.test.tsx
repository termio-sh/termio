// @vitest-environment jsdom
import { StrictMode, act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { KIND } from "../protocol/frame";
import { encodeJsonFrame } from "../protocol/testTranscript";

// The Wasm is fetched over the network and instantiated from a MIME type, so the
// shell test stubs the binding rather than the transport under it. Everything
// below the shell has its own tests.
vi.mock("../vt", async () => {
  const actual = await vi.importActual<typeof import("../vt")>("../vt");
  return { ...actual, instantiate: vi.fn() };
});

const vt = await import("../vt");
const { App } = await import("./App");

const STUB_BINDING = {
  libraryVersion: "test",
  commit: null,
  createTerminal: () => {
    throw new Error("no terminal in the shell test");
  },
  createKeyEncoder: () => {
    throw new Error("no encoder in the shell test");
  },
  dispose: () => {},
} as unknown as import("../vt").VtBinding;

(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

class StubSocket {
  static instances: StubSocket[] = [];
  readonly listeners = new Map<string, Set<(event: unknown) => void>>();
  readonly sent: Uint8Array[] = [];
  binaryType = "";
  readyState = 1;
  closed = false;

  constructor(
    readonly url: string,
    readonly protocols: string[],
  ) {
    StubSocket.instances.push(this);
  }
  addEventListener(type: string, listener: (event: unknown) => void): void {
    let set = this.listeners.get(type);
    if (!set) {
      set = new Set();
      this.listeners.set(type, set);
    }
    set.add(listener);
    if (type === "open") listener({});
  }
  removeEventListener(): void {}
  send(data: Uint8Array): void {
    this.sent.push(data);
  }
  close(): void {
    this.closed = true;
    this.readyState = 3;
  }
  deliver(bytes: Uint8Array): void {
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    for (const listener of [...(this.listeners.get("message") ?? [])]) {
      listener({ data: buffer });
    }
  }
  controls(): Record<string, unknown>[] {
    return this.sent
      .filter((frame) => frame[0] === KIND.CONTROL)
      .map(
        (frame) =>
          JSON.parse(new TextDecoder().decode(frame.subarray(5))) as Record<string, unknown>,
      );
  }
}

function session(id: string, created: number) {
  return {
    id,
    name: id,
    cwd: "/home/me",
    command: "zsh",
    pid: 1,
    rows: 24,
    cols: 80,
    clients: 0,
    created_unix: created,
    alive: true,
    status: "idle",
  };
}

let root: Root | null = null;
let container: HTMLElement | null = null;

beforeEach(() => {
  StubSocket.instances = [];
  (globalThis as { WebSocket: unknown }).WebSocket = StubSocket;
  // jsdom ships no 2D context; the renderer only needs a recording one, and
  // without it `createSurface` would report "no 2D context" and never attach.
  HTMLCanvasElement.prototype.getContext = (() => ({
    setTransform() {},
    fillRect() {},
    strokeRect() {},
    fillText() {},
    beginPath() {},
    moveTo() {},
    lineTo() {},
    stroke() {},
    measureText: (text: string) => ({
      width: text.length * 8,
      fontBoundingBoxAscent: 8,
      fontBoundingBoxDescent: 2,
    }),
    fillStyle: "",
    strokeStyle: "",
    font: "",
    globalAlpha: 1,
    lineWidth: 1,
    textBaseline: "alphabetic",
  })) as unknown as typeof HTMLCanvasElement.prototype.getContext;
  window.location.hash = "#t=pair-token";
  vi.mocked(vt.instantiate).mockReset();
  vi.mocked(vt.instantiate).mockResolvedValue(STUB_BINDING);
});

afterEach(() => {
  act(() => root?.unmount());
  container?.remove();
  root = null;
  container = null;
  window.sessionStorage.clear();
});

/**
 * Async because the Wasm binding is loaded in an effect: without flushing the
 * microtask queue the shell is still on "Loading the terminal engine…" and no
 * surface has mounted.
 */
async function mount(): Promise<void> {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => {
    root?.render(
      <StrictMode>
        <App />
      </StrictMode>,
    );
  });
}

describe("the shell", () => {
  it("takes the token out of the fragment and never puts it in a URL", async () => {
    await mount();
    expect(window.location.hash).toBe("");
    expect(window.sessionStorage.getItem("termio.pair.token")).toBe("pair-token");
    const socket = StubSocket.instances.find((instance) => !instance.closed);
    expect(socket?.protocols).toEqual(["termiod.v1", "termiod.token.pair-token"]);
    expect(socket?.url).not.toContain("pair-token");
  });

  it("opens exactly one live control socket under StrictMode", async () => {
    await mount();
    const live = StubSocket.instances.filter((instance) => !instance.closed);
    expect(live).toHaveLength(1);
    expect(live[0]?.controls()[0]).toMatchObject({ op: "hello", role: "control" });
  });

  it("lists sessions from the roster and attaches to the newest as an observer", async () => {
    await mount();
    const control = StubSocket.instances.find((instance) => !instance.closed);
    act(() => {
      control?.deliver(
        encodeJsonFrame(KIND.CONTROL, {
          op: "hello_ok",
          proto: 1,
          caps: [],
          host_id: "h",
          host: "box",
          client_id: "c",
        }),
      );
      control?.deliver(
        encodeJsonFrame(KIND.CONTROL, {
          op: "sessions",
          sessions: [session("older", 10), session("newest", 90)],
        }),
      );
    });

    expect(container?.textContent).toContain("newest");
    expect(container?.textContent).toContain("older");

    const attach = StubSocket.instances.filter((instance) => !instance.closed).at(-1);
    expect(attach).not.toBe(control);
    expect(attach?.controls()[0]).toMatchObject({
      op: "hello",
      role: "attach",
      caps: ["events", "snapshot", "scrollback"],
    });
    expect(container?.textContent).toContain("Observing");
  });

  it("Take input closes the observe socket and opens a new interact attach", async () => {
    await mount();
    const control = StubSocket.instances.find((instance) => !instance.closed);
    act(() => {
      control?.deliver(
        encodeJsonFrame(KIND.CONTROL, {
          op: "hello_ok",
          proto: 1,
          caps: [],
          host_id: "h",
          host: "box",
          client_id: "c",
        }),
      );
      control?.deliver(
        encodeJsonFrame(KIND.CONTROL, { op: "sessions", sessions: [session("only", 1)] }),
      );
    });
    const observe = StubSocket.instances.filter((instance) => !instance.closed).at(-1);
    act(() => {
      observe?.deliver(
        encodeJsonFrame(KIND.CONTROL, {
          op: "hello_ok",
          proto: 1,
          caps: [],
          host_id: "h",
          host: "box",
          client_id: "c",
        }),
      );
    });
    expect(observe?.controls()[1]).toMatchObject({ op: "attach", mode: "observe" });

    const take = [...(container?.querySelectorAll("button") ?? [])].find(
      (button) => button.textContent === "Take input",
    );
    expect(take).toBeDefined();
    act(() => take?.click());

    // There is no promote verb: the observe channel is closed and a new socket
    // attaches with `mode: interact`.
    expect(observe?.closed).toBe(true);
    const interact = StubSocket.instances.filter((instance) => !instance.closed).at(-1);
    expect(interact).not.toBe(observe);
    act(() => {
      interact?.deliver(
        encodeJsonFrame(KIND.CONTROL, {
          op: "hello_ok",
          proto: 1,
          caps: [],
          host_id: "h",
          host: "box",
          client_id: "c",
        }),
      );
    });
    expect(interact?.controls()[1]).toMatchObject({ op: "attach", mode: "interact" });
  });

  it("shows the engine's own sentence when the Wasm will not load", async () => {
    vi.mocked(vt.instantiate).mockRejectedValue(new vt.VtLoadError("bad mime"));
    await mount();
    expect(container?.textContent).toContain("Couldn't load the terminal engine.");
    expect(container?.textContent).toContain("application/wasm");
  });

  it("asks for the pairing link when there is no token", async () => {
    window.location.hash = "";
    window.sessionStorage.clear();
    await mount();
    expect(container?.textContent).toContain("termiod pair");
    expect(StubSocket.instances).toHaveLength(0);
  });
});
