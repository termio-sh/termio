/**
 * One canvas, one attach, one ref.
 *
 * This component renders exactly once per attach. It reads no surface state, so
 * nothing that happens at PTY rate — not a byte, not a title, not a cursor
 * move — can make it render again. The chrome that *does* show those things
 * subscribes to the bridge instead, which is why the boundary holds.
 */

import { memo, useEffect, useLayoutEffect, useRef } from "react";

import type { AttachMode } from "../protocol/control";
import type { Palette } from "../renderer/types";
import type { VtBinding } from "../vt";
import { createSurface, type SurfaceHandle } from "./surface";
import type { SurfaceBridge } from "./surfaceStore";

export interface TerminalSurfaceProps {
  sessionId: string;
  /** A string, not a URL: the effect deps are identities and must compare by value. */
  wsUrl: string;
  token: string;
  mode: AttachMode;
  binding: VtBinding;
  palette: Palette;
  client: string;
  bridge: SurfaceBridge;
  /** Injected by tests so the surface can be driven without a WebSocket. */
  createHandle?: typeof createSurface;
}

export const TerminalSurface = memo(function TerminalSurface(props: TerminalSurfaceProps) {
  const { sessionId, wsUrl, token, mode, binding, palette, client, bridge } = props;
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  const handleRef = useRef<SurfaceHandle | null>(null);

  // Everything the attach needs but must not re-run for. A change to any of
  // these between renders takes effect on the next attach, which is what the
  // remount key is for.
  const latest = useRef({ token, mode, binding, palette, client, create: props.createHandle });
  latest.current = { token, mode, binding, palette, client, create: props.createHandle };

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const { token: t, mode: m, binding: b, palette: p, client: c, create } = latest.current;
    const handle = (create ?? createSurface)({
      canvas,
      container: boxRef.current,
      url: new URL(wsUrl),
      token: t,
      target: sessionId,
      mode: m,
      binding: b,
      palette: p,
      client: c,
    });
    handleRef.current = handle;
    bridge.attach(handle);
    return () => {
      handleRef.current = null;
      bridge.attach(null);
      // Idempotent by contract: StrictMode runs this cleanup and then the
      // effect again on the very first mount.
      handle.dispose();
    };
    // Identity only. A value that moves per frame in here is the bug this
    // whole component exists to prevent.
  }, [sessionId, wsUrl, bridge]);

  useLayoutEffect(() => {
    const box = boxRef.current;
    if (!box || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => handleRef.current?.fit());
    observer.observe(box);
    return () => observer.disconnect();
  }, []);

  // A theme switch is an imperative call, not a re-render: no cell is
  // re-created, the Wasm is not told, and the canvas does not remount.
  useEffect(() => {
    handleRef.current?.setPalette(palette);
  }, [palette]);

  return (
    <div className="surface" ref={boxRef}>
      <canvas
        className="surface-canvas"
        ref={canvasRef}
        tabIndex={0}
        onMouseDown={(event) => {
          event.currentTarget.focus();
        }}
      />
    </div>
  );
});
