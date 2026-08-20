import { describe, expect, it } from "vitest";

import { KIND, encodeFrame } from "../protocol/frame";
import { cell, encodeHistoryPayload } from "../protocol/testTranscript";
import { buildPalette } from "./theme";
import { createSurface } from "./surface";
import {
  FakeCanvas,
  attached,
  completeAttach,
  createHarness,
  data,
  event,
  helloOk,
  keyEvent,
  ready,
  snapshot,
} from "./__fixtures__/harness";

const decoder = new TextDecoder();

describe("attach sequence", () => {
  it("sends hello first, as an attach Replica", () => {
    const harness = createHarness();
    const hello = harness.channel.control(0);
    expect(harness.channel.outgoing).toHaveLength(1);
    expect(hello).toMatchObject({
      op: "hello",
      proto: 1,
      min_proto: 1,
      role: "attach",
      caps: ["events", "snapshot", "scrollback"],
    });
    // `grid_diff` is never advertised on the grounds that the client is a
    // browser. This is the line that keeps that true.
    expect(hello.caps).not.toContain("grid_diff");
    harness.dispose();
  });

  it("attaches as an observer with explicit dims", () => {
    const harness = createHarness();
    harness.channel.deliver(helloOk());
    expect(harness.channel.control(1)).toMatchObject({
      op: "attach",
      target: "session-1",
      // The host default is `interact`; opening a page must not steal the write
      // token, so the mode is always sent.
      mode: "observe",
      // 640×384 over 8×16 cells.
      cols: 80,
      rows: 24,
    });
    harness.dispose();
  });

  it("writes exactly snapshot.vt into the Wasm — no header, no prelude", () => {
    const harness = createHarness();
    harness.channel.deliver(helloOk(), attached(), snapshot("boot line", 6, 20, "a title"));
    expect(harness.writes).toHaveLength(1);
    expect(decoder.decode(harness.writes[0])).toBe("boot line");
    harness.dispose();
  });

  it("ends the barrier on Event::Ready, not on the first D", () => {
    const harness = createHarness();
    harness.channel.deliver(helloOk(), attached(), snapshot("one"), data("two"));
    harness.runFrame();
    // Two writes reached the Wasm, but nothing painted: the barrier is still up.
    expect(harness.writes.map((bytes) => decoder.decode(bytes))).toEqual(["one", "two"]);
    expect(harness.renderer.draws).toHaveLength(0);

    harness.channel.deliver(ready());
    harness.runFrame();
    expect(harness.renderer.draws).toHaveLength(1);
    expect(harness.surface.snapshot().phase).toBe("live");
    harness.dispose();
  });

  it("takes its dims from Attached, not from the canvas", () => {
    const harness = createHarness();
    completeAttach(harness, { rows: 6, cols: 20 });
    const state = harness.surface.snapshot();
    expect([state.rows, state.cols]).toEqual([6, 20]);
    // The canvas is 640×384 — 80×24 cells — and the grid is letterboxed inside
    // it rather than reparsed at the window size.
    expect(harness.renderer.geometry).toMatchObject({ rows: 6, cols: 20 });
    expect(harness.renderer.geometry?.padding).toEqual({ top: 144, left: 240 });
    harness.dispose();
  });

  it("paints the snapshot's text", () => {
    const harness = createHarness();
    completeAttach(harness, { vt: "ready>" });
    harness.runFrame();
    expect(harness.renderer.draws[0]?.viewport[0]).toBe("ready>");
    harness.dispose();
  });
});

describe("live bytes", () => {
  it("paints once for a burst rather than once per frame", () => {
    const harness = createHarness();
    completeAttach(harness);
    harness.runFrame();
    const before = harness.renderer.draws.length;

    harness.channel.deliver(data("a"), data("b"), data("c"));
    harness.runFrame();
    expect(harness.renderer.draws).toHaveLength(before + 1);

    // Nothing new arrived; the loop must not repaint.
    harness.runFrame();
    expect(harness.renderer.draws).toHaveLength(before + 1);
    harness.dispose();
  });

  it("skips the frames a mode-2026 block is mid-way through", () => {
    const harness = createHarness();
    completeAttach(harness);
    harness.runFrame();
    const before = harness.renderer.draws.length;

    harness.channel.deliver(data("\u001b[?2026h"), data("half a screen"));
    harness.runFrame();
    expect(harness.renderer.draws).toHaveLength(before);

    harness.channel.deliver(data("\u001b[?2026l"));
    harness.runFrame();
    expect(harness.renderer.draws).toHaveLength(before + 1);
    harness.dispose();
  });

  it("skips G, F and U frames instead of failing on them", () => {
    const harness = createHarness();
    completeAttach(harness);
    harness.channel.deliver(
      encodeFrame(KIND.GRID, new Uint8Array(16)),
      encodeFrame(KIND.FILE, new Uint8Array(4)),
      encodeFrame(KIND.UPLOAD, new Uint8Array(4)),
    );
    expect(harness.surface.snapshot().error).toBeNull();
    harness.dispose();
  });
});

describe("input", () => {
  it("an observer sends nothing", () => {
    const harness = createHarness();
    completeAttach(harness, { writer: false });
    harness.canvas.dispatch("keydown", keyEvent({ key: "a" }));
    expect(harness.channel.data()).toHaveLength(0);
    harness.dispose();
  });

  it("a writer sends the encoder's bytes as D", () => {
    const harness = createHarness({ mode: "interact" });
    completeAttach(harness, { writer: true });
    harness.canvas.dispatch("keydown", keyEvent({ key: "a" }));
    const sent = harness.channel.data();
    expect(sent).toHaveLength(1);
    expect(decoder.decode(sent[0])).toBe("a");
    harness.dispose();
  });

  it("takes the cursor-key mode from the VT rather than guessing", () => {
    const harness = createHarness({ mode: "interact" });
    completeAttach(harness, { writer: true });
    harness.canvas.dispatch("keydown", keyEvent({ key: "ArrowUp", code: "ArrowUp" }));
    expect(decoder.decode(harness.channel.data()[0])).toBe("\u001b[A");

    // The program turns DECCKM on; the next arrow key must change shape.
    harness.channel.deliver(data("\u001b[?1h"));
    harness.canvas.dispatch("keydown", keyEvent({ key: "ArrowUp", code: "ArrowUp" }));
    expect(decoder.decode(harness.channel.data()[1])).toBe("\u001bOA");
    harness.dispose();
  });
});

describe("resize barrier", () => {
  it("a writer sends R and paints nothing until S and ready", () => {
    const harness = createHarness({ mode: "interact" });
    completeAttach(harness, { writer: true, rows: 6, cols: 20 });
    harness.runFrame();
    const painted = harness.renderer.draws.length;

    harness.canvas.parentElement = { clientWidth: 320, clientHeight: 160 } as HTMLElement;
    harness.surface.fit();
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        const resize = harness.channel.outgoing.find((frame) => frame.kind === KIND.RESIZE);
        expect(resize).toMatchObject({ kind: KIND.RESIZE, rows: 10, cols: 40 });
        // Quiesced: the terminal is NOT resized here, because the host decides
        // the dims and says so in the snapshot.
        expect(harness.terminals[0]?.cols).toBe(20);

        harness.channel.deliver(data("mid-flight"));
        harness.runFrame();
        expect(harness.renderer.draws).toHaveLength(painted);

        harness.channel.deliver(snapshot("after", 10, 40), ready());
        harness.runFrame();
        expect(harness.terminals[0]?.cols).toBe(40);
        expect(harness.renderer.draws.length).toBeGreaterThan(painted);
        expect(harness.surface.snapshot().cols).toBe(40);
        harness.dispose();
        resolve();
      }, 120);
    });
  });

  it("an observer never sends R", () => {
    const harness = createHarness();
    completeAttach(harness, { writer: false });
    harness.canvas.parentElement = { clientWidth: 320, clientHeight: 160 } as HTMLElement;
    harness.surface.fit();
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        expect(harness.channel.kinds()).not.toContain(KIND.RESIZE);
        harness.dispose();
        resolve();
      }, 120);
    });
  });

  it("follows Event::Resized when someone else resizes the session", () => {
    const harness = createHarness();
    completeAttach(harness, { rows: 6, cols: 20 });
    harness.channel.deliver(
      event({ ev: "resized", session: "session-1", rows: 8, cols: 30 }),
    );
    expect(harness.terminals[0]?.cols).toBe(30);
    expect(harness.surface.snapshot().rows).toBe(8);
    harness.dispose();
  });
});

describe("history", () => {
  function historyFrame(cols: number, firstOffset: number, texts: string[]): Uint8Array {
    const cells = texts.flatMap((text) =>
      Array.from({ length: cols }, (_, x) =>
        cell({ codepoint: text.codePointAt(x) ?? 0x20 }),
      ),
    );
    return encodeFrame(
      KIND.HISTORY,
      encodeHistoryPayload(cols, firstOffset, texts.length, cells),
    );
  }

  it("paints H rows above the viewport once scrolled, never through the Wasm", () => {
    const harness = createHarness();
    completeAttach(harness, { vt: "live", rows: 6, cols: 4 });
    const wasmWrites = harness.writes.length;

    harness.channel.deliver(historyFrame(4, 1, ["old1", "old2"]));
    // `H` is cells, not VT: nothing about it reaches the Wasm.
    expect(harness.writes).toHaveLength(wasmWrites);
    expect(harness.surface.snapshot().historyRows).toBe(2);

    harness.canvas.dispatch("wheel", wheelEvent(-120));
    harness.runFrame();
    const draw = harness.renderer.draws.at(-1);
    expect(draw?.scrollOffsetRows).toBe(2);
    expect(draw?.history).toContain("old1");
    harness.dispose();
  });

  it("drops history and says so on Event::Resynced", () => {
    const harness = createHarness();
    completeAttach(harness, { rows: 6, cols: 4 });
    harness.channel.deliver(historyFrame(4, 1, ["old1"]));
    expect(harness.surface.snapshot().historyRows).toBe(1);

    harness.channel.deliver(
      event({ ev: "resynced", session: "session-1", reason: "backlog" }),
    );
    const state = harness.surface.snapshot();
    expect(state.historyRows).toBe(0);
    expect(state.notice).toContain("resynced");
    harness.dispose();
  });
});

describe("theme", () => {
  it("re-resolves through the renderer without touching the Wasm", () => {
    const harness = createHarness();
    completeAttach(harness);
    const wasmWrites = harness.writes.length;
    const light = buildPalette("light");

    harness.surface.setPalette(light);
    expect(harness.renderer.palettes.at(-1)).toBe(light);
    // No re-parse, no re-attach, no terminal teardown.
    expect(harness.writes).toHaveLength(wasmWrites);
    expect(harness.terminals).toHaveLength(1);
    harness.dispose();
  });
});

describe("lifecycle", () => {
  it("dispose is idempotent and leaves nothing behind", () => {
    const harness = createHarness();
    completeAttach(harness);
    harness.runFrame();
    expect(harness.canvas.listenerCount()).toBeGreaterThan(0);

    harness.surface.dispose();
    harness.surface.dispose();

    expect(harness.channel.closed).toBe(true);
    expect(harness.canvas.listenerCount()).toBe(0);
    expect(harness.renderer.disposed).toBe(1);
    // Every Wasm allocation the terminal and encoder made is back.
    expect(harness.fake.liveAllocations()).toBe(0);
  });

  it("says so plainly when the browser gives it no 2D context", () => {
    let opened = false;
    const surface = createSurface({
      canvas: new FakeCanvas() as unknown as HTMLCanvasElement,
      url: new URL("wss://box.example/termio/ws"),
      token: "t",
      target: "session-1",
      mode: "observe",
      binding: {} as never,
      palette: buildPalette("dark"),
      client: "termio-web/test",
      createRenderer: () => null,
      open: () => {
        opened = true;
        throw new Error("a surface with no renderer must not open a socket");
      },
      requestFrame: () => 0,
      cancelFrame: () => {},
    });
    expect(surface.snapshot().phase).toBe("error");
    expect(surface.snapshot().error).toContain("2D canvas context");
    expect(opened).toBe(false);
    // And it still tears down cleanly rather than throwing on a null renderer.
    expect(() => surface.dispose()).not.toThrow();
  });

  it("surfaces vt_stale in the chrome", () => {
    const harness = createHarness();
    completeAttach(harness);
    harness.channel.deliver(
      event({ ev: "vt_stale", session: "session-1", reason: "ring" }),
    );
    expect(harness.surface.snapshot().notice).toContain("degraded");
    harness.dispose();
  });

  it("notifies on transitions, never per byte", () => {
    const harness = createHarness();
    let notifications = 0;
    harness.surface.subscribe(() => {
      notifications += 1;
    });
    completeAttach(harness);
    harness.runFrame();
    const afterAttach = notifications;

    for (let i = 0; i < 50; i += 1) harness.channel.deliver(data("x"));
    harness.runFrame();
    expect(notifications).toBe(afterAttach);
    harness.dispose();
  });
});

function wheelEvent(deltaY: number): WheelEvent {
  return {
    deltaY,
    deltaMode: 0,
    preventDefault: () => {},
  } as unknown as WheelEvent;
}
