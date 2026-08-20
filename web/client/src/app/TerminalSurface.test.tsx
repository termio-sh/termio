// @vitest-environment jsdom
import { Profiler, StrictMode, act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";

import type { Palette } from "../renderer/types";
import type { VtBinding } from "../vt";
import { TerminalSurface } from "./TerminalSurface";
import type { SurfaceHandle, SurfaceState } from "./surface";
import { createSurfaceBridge, IDLE_SURFACE_STATE, useSurfaceState } from "./surfaceStore";
import { buildPalette } from "./theme";

// React 19 wants this to route act() through the test scheduler.
(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

interface FakeHandle extends SurfaceHandle {
  push(patch: Partial<SurfaceState>): void;
  disposals: number;
  palettes: Palette[];
}

const created: FakeHandle[] = [];

function fakeHandle(): FakeHandle {
  const listeners = new Set<() => void>();
  let state: SurfaceState = IDLE_SURFACE_STATE;
  const handle: FakeHandle = {
    disposals: 0,
    palettes: [],
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    snapshot: () => state,
    fit() {},
    setPalette(palette) {
      handle.palettes.push(palette);
    },
    setFont() {},
    paste() {},
    stats: () => null,
    dispose() {
      handle.disposals += 1;
    },
    push(patch) {
      state = { ...state, ...patch };
      for (const listener of [...listeners]) listener();
    },
  };
  return handle;
}

let root: Root | null = null;
let container: HTMLElement | null = null;

function mount(element: React.ReactNode): void {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  act(() => {
    root?.render(element);
  });
}

afterEach(() => {
  act(() => root?.unmount());
  container?.remove();
  root = null;
  container = null;
  created.length = 0;
});

function props(overrides: Record<string, unknown> = {}) {
  return {
    sessionId: "session-1",
    wsUrl: "wss://box.example/termio/ws",
    token: "t",
    mode: "observe" as const,
    binding: {} as VtBinding,
    palette: buildPalette("dark"),
    client: "termio-web/test",
    createHandle: (() => {
      const handle = fakeHandle();
      created.push(handle);
      return handle;
    }) as unknown as never,
    ...overrides,
  };
}

describe("TerminalSurface lifecycle", () => {
  it("leaks nothing across StrictMode's double invoke", () => {
    const bridge = createSurfaceBridge();
    mount(
      <StrictMode>
        <TerminalSurface {...props()} bridge={bridge} />
      </StrictMode>,
    );

    // StrictMode mounts, unmounts and remounts the effect. Every handle it
    // created must have been disposed except the live one.
    expect(created.length).toBeGreaterThanOrEqual(2);
    const live = created.at(-1);
    expect(created.slice(0, -1).every((handle) => handle.disposals === 1)).toBe(true);
    expect(live?.disposals).toBe(0);
    expect(bridge.current()).toBe(live);

    act(() => root?.unmount());
    expect(live?.disposals).toBe(1);
    expect(bridge.current()).toBeNull();
    root = null;
  });

  it("remounts on a session change and disposes the old attach", () => {
    const bridge = createSurfaceBridge();
    function Host(): React.JSX.Element {
      const [id, setId] = useState("session-1");
      return (
        <>
          <button type="button" onClick={() => setId("session-2")}>
            switch
          </button>
          <TerminalSurface key={id} {...props({ sessionId: id })} bridge={bridge} />
        </>
      );
    }
    mount(<Host />);
    const first = created.at(-1);
    act(() => {
      container?.querySelector("button")?.click();
    });
    expect(first?.disposals).toBe(1);
    expect(created.at(-1)).not.toBe(first);
    expect(bridge.current()).toBe(created.at(-1));
  });

  it("switches theme imperatively, without remounting the canvas", () => {
    const bridge = createSurfaceBridge();
    const dark = buildPalette("dark");
    const light = buildPalette("light");
    function Host(): React.JSX.Element {
      const [palette, setPalette] = useState(dark);
      return (
        <>
          <button type="button" onClick={() => setPalette(light)}>
            theme
          </button>
          <TerminalSurface {...props()} palette={palette} bridge={bridge} />
        </>
      );
    }
    mount(<Host />);
    const handle = created.at(-1);
    const canvas = container?.querySelector("canvas");
    const attaches = created.length;

    act(() => {
      container?.querySelector("button")?.click();
    });
    expect(handle?.palettes.at(-1)).toBe(light);
    // No new attach, and the same canvas node.
    expect(created).toHaveLength(attaches);
    expect(container?.querySelector("canvas")).toBe(canvas);
  });
});

describe("the React boundary", () => {
  it("state from the loop re-renders the chrome and never the surface", () => {
    const bridge = createSurfaceBridge();
    let chromeRenders = 0;
    let surfaceCommits = 0;

    function Chrome(): React.JSX.Element {
      const state = useSurfaceState(bridge);
      chromeRenders += 1;
      return <span>{state.writer ? "Writing" : "Observing"}</span>;
    }

    mount(
      <>
        <Chrome />
        <Profiler
          id="surface"
          onRender={(_id, phase) => {
            if (phase === "update") surfaceCommits += 1;
          }}
        >
          <TerminalSurface {...props()} bridge={bridge} />
        </Profiler>
      </>,
    );

    const handle = created.at(-1);
    const canvas = container?.querySelector("canvas");
    const chromeBefore = chromeRenders;

    act(() => {
      for (let i = 0; i < 100; i += 1) handle?.push({ title: `title ${i}` });
      handle?.push({ writer: true });
    });

    // The chrome saw it…
    expect(container?.textContent).toContain("Writing");
    expect(chromeRenders).toBeGreaterThan(chromeBefore);
    // …and the surface subtree committed no update at all: it holds a ref, not
    // state, so nothing arriving at PTY rate can reach it.
    expect(surfaceCommits).toBe(0);
    expect(container?.querySelector("canvas")).toBe(canvas);
    expect(created).toHaveLength(1);
  });

  it("and the counter above is not vacuous: a real prop change does commit", () => {
    const bridge = createSurfaceBridge();
    let surfaceCommits = 0;
    function Host(): React.JSX.Element {
      const [mode, setMode] = useState<"observe" | "interact">("observe");
      return (
        <>
          <button type="button" onClick={() => setMode("interact")}>
            take
          </button>
          <Profiler
            id="surface"
            onRender={(_id, phase) => {
              if (phase === "update") surfaceCommits += 1;
            }}
          >
            <TerminalSurface {...props()} mode={mode} bridge={bridge} />
          </Profiler>
        </>
      );
    }
    mount(<Host />);
    act(() => {
      container?.querySelector("button")?.click();
    });
    expect(surfaceCommits).toBeGreaterThan(0);
  });
});
