/**
 * The whole client, end to end, with no browser in it.
 *
 * Every other test in this directory replaces one layer with a fake. This one
 * replaces none of them: real protocol codec, real vt binding (over the fake
 * ghostty exports), real Canvas 2D renderer. The only stand-in is the 2D
 * context, which records its draw calls instead of rasterising them — the
 * renderer touches nothing else.
 *
 * What it is here to prove is the presentation boundary: one snapshot, two
 * themes, and the palette-indexed cell that came off the wire as `38;5;1`
 * paints a different colour in each — after load, with no reload, no remount,
 * and nothing re-parsed.
 */

import { describe, expect, it } from "vitest";

import { openChannel } from "../protocol/socket";
import type { Channel, ChannelOptions } from "../protocol/socket";
import type { SurfaceHandle } from "./surface";
import { buildPalette } from "./theme";
import { FakeCanvas, FakeChannel, completeAttach, createHarness } from "./__fixtures__/harness";

interface FillText {
  text: string;
  fill: string;
}

class RecordingContext {
  readonly fills: FillText[] = [];
  readonly rects: { fill: string }[] = [];
  fillStyle = "";
  strokeStyle = "";
  font = "";
  globalAlpha = 1;
  lineWidth = 1;
  textBaseline = "alphabetic";
  letterSpacing = "0px";

  setTransform(): void {}
  fillRect(): void {
    this.rects.push({ fill: this.fillStyle });
  }
  strokeRect(): void {}
  fillText(text: string): void {
    this.fills.push({ text, fill: this.fillStyle });
  }
  measureText(text: string): {
    width: number;
    fontBoundingBoxAscent: number;
    fontBoundingBoxDescent: number;
  } {
    return { width: text.length * 8, fontBoundingBoxAscent: 8, fontBoundingBoxDescent: 2 };
  }
  beginPath(): void {}
  moveTo(): void {}
  lineTo(): void {}
  stroke(): void {}
}

class PaintingCanvas extends FakeCanvas {
  readonly context = new RecordingContext();
  width = 0;
  height = 0;
  style = { width: "", height: "" };
  getContext(): RecordingContext {
    return this.context;
  }
}

function paintedText(context: RecordingContext): string {
  return context.fills.map((fill) => fill.text).join("");
}

function fillOf(context: RecordingContext, text: string): string | undefined {
  return context.fills.find((fill) => fill.text.includes(text))?.fill;
}

describe("one snapshot, painted for real", () => {
  function stack(): {
    surface: SurfaceHandle;
    canvas: PaintingCanvas;
    channel: FakeChannel;
    frame: () => void;
    dispose: () => void;
  } {
    // Reuse the harness's fake ghostty + channel, but let the surface build the
    // real Canvas 2D renderer over the recording context.
    const canvas = new PaintingCanvas();
    const inner = createHarness({
      canvas: canvas as unknown as HTMLCanvasElement,
      realRenderer: true,
    });
    return {
      surface: inner.surface,
      canvas,
      channel: inner.channel,
      frame: inner.runFrame,
      dispose: inner.dispose,
    };
  }

  it("resolves a palette index against the viewer's theme, at the last step", () => {
    const { surface, canvas, channel, frame, dispose } = stack();
    // `38;5;1` — the tagged form the host emits with `palette: false`.
    completeAttach({ channel }, { vt: "\u001b[38;5;1mred\u001b[m", rows: 3, cols: 8 });
    frame();

    expect(paintedText(canvas.context)).toContain("red");
    const dark = buildPalette("dark");
    expect(fillOf(canvas.context, "red")).toBe(cssOf(dark.ansi[1]));

    // The theme switch: one imperative call, everything re-resolved.
    const light = buildPalette("light");
    canvas.context.fills.length = 0;
    surface.setPalette(light);
    frame();

    expect(paintedText(canvas.context)).toContain("red");
    expect(fillOf(canvas.context, "red")).toBe(cssOf(light.ansi[1]));
    expect(cssOf(light.ansi[1])).not.toBe(cssOf(dark.ansi[1]));
    dispose();
  });

  it("paints the default background from the viewer's theme, never black", () => {
    const { canvas, channel, frame, dispose } = stack();
    completeAttach({ channel }, { vt: "plain", rows: 3, cols: 8 });
    frame();
    const light = buildPalette("light");
    expect(canvas.context.rects.some((rect) => rect.fill === cssOf(light.background))).toBe(
      false,
    );
    expect(
      canvas.context.rects.some((rect) => rect.fill === cssOf(buildPalette("dark").background)),
    ).toBe(true);
    dispose();
  });
});

describe("the real socket wiring", () => {
  it("offers termiod.v1 and the token as subprotocols, and never a query string", () => {
    const opened: { url: string; protocols: string[] }[] = [];
    class StubSocket {
      binaryType = "";
      readyState = 0;
      constructor(url: string, protocols: string[]) {
        opened.push({ url, protocols });
      }
      addEventListener(): void {}
      send(): void {}
      close(): void {}
    }
    const previous = globalThis.WebSocket;
    (globalThis as { WebSocket: unknown }).WebSocket = StubSocket;
    try {
      const channel: Channel = openChannel({
        url: new URL("wss://box.example/termio/ws"),
        token: "s3cret",
        onFrame: () => {},
        onClose: () => {},
        onError: () => {},
      } satisfies ChannelOptions);
      expect(opened[0]?.url).toBe("wss://box.example/termio/ws");
      expect(opened[0]?.protocols).toEqual(["termiod.v1", "termiod.token.s3cret"]);
      expect(opened[0]?.url).not.toContain("t=");
      channel.close();
    } finally {
      (globalThis as { WebSocket: unknown }).WebSocket = previous;
    }
  });
});

function cssOf(color: { r: number; g: number; b: number } | undefined): string {
  if (!color) throw new Error("palette entry missing");
  const packed = (color.r << 16) | (color.g << 8) | color.b;
  return `#${packed.toString(16).padStart(6, "0")}`;
}
