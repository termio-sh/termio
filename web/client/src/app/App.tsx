/**
 * The shell. A session list, a badge, two buttons, a theme toggle, and the
 * error surfaces — and not one cell, dirty flag or byte counter among them.
 */

import { useCallback, useEffect, useMemo, useState } from "react";

import type { SessionInfo } from "../protocol/control";
import { channelUrl } from "../protocol/socket";
import type { RendererStats } from "../renderer/types";
import { instantiate, VtLoadError, type VtBinding } from "../vt";
import { sessionFromLocation, takeToken, wasmUrl } from "./bootstrap";
import { createControlClient, sessionLabel, type RosterState } from "./control";
import { TerminalSurface } from "./TerminalSurface";
import { chromeTokens } from "./chrome";
import { buildPalette, preferredTheme, type ThemeName } from "./theme";
import {
  createRosterBridge,
  createSurfaceBridge,
  useRosterState,
  useSurfaceState,
  type SurfaceBridge,
} from "./surfaceStore";

export const CLIENT_NAME = "termio-web/0.1.0";

type BindingState =
  | { status: "loading" }
  | { status: "ready"; binding: VtBinding }
  | { status: "failed"; message: string };

export function App(): React.JSX.Element {
  const [theme, setTheme] = useState<ThemeName>(preferredTheme);
  const palette = useMemo(() => buildPalette(theme), [theme]);

  const token = useMemo(
    () =>
      takeToken(window.location, safeSessionStorage(), () => {
        history.replaceState(null, "", window.location.pathname + window.location.search);
      }),
    [],
  );
  const wsUrl = useMemo(() => channelUrl(new URL(window.location.href)).toString(), []);

  const [binding, setBinding] = useState<BindingState>({ status: "loading" });
  useEffect(() => {
    let disposed = false;
    let loaded: VtBinding | null = null;
    instantiate({ url: wasmUrl(document.baseURI) })
      .then((value) => {
        loaded = value;
        if (disposed) {
          value.dispose();
          return;
        }
        setBinding({ status: "ready", binding: value });
      })
      .catch((error: unknown) => {
        if (disposed) return;
        setBinding({
          status: "failed",
          message:
            error instanceof VtLoadError
              ? error.userMessage
              : `Couldn't load the terminal engine. ${String(error)}`,
        });
      });
    return () => {
      disposed = true;
      loaded?.dispose();
    };
  }, []);

  if (!token) return <TokenGate />;
  return (
    <Shell
      theme={theme}
      onTheme={setTheme}
      palette={palette}
      token={token}
      wsUrl={wsUrl}
      binding={binding}
    />
  );
}

interface ShellProps {
  theme: ThemeName;
  onTheme: (theme: ThemeName) => void;
  palette: ReturnType<typeof buildPalette>;
  token: string;
  wsUrl: string;
  binding: BindingState;
}

function Shell(props: ShellProps): React.JSX.Element {
  const { theme, onTheme, palette, token, wsUrl, binding } = props;

  // The control socket is opened in an effect, never during render: StrictMode
  // renders twice, and a `createControlClient` in a `useMemo` would open two
  // WebSockets and dispose one.
  const rosterBridge = useMemo(createRosterBridge, []);
  useEffect(() => {
    const client = createControlClient({ url: new URL(wsUrl), token, client: CLIENT_NAME });
    rosterBridge.attach(client);
    return () => {
      rosterBridge.attach(null);
      client.dispose();
    };
  }, [wsUrl, token, rosterBridge]);
  const roster = useRosterState(rosterBridge);

  const [selected, setSelected] = useState<string | null>(() =>
    sessionFromLocation(window.location),
  );
  const [mode, setMode] = useState<"observe" | "interact">("observe");

  // The page opens on something rather than nothing, but never re-picks under
  // the user: a roster update must not move them to a different session.
  const active = selected ?? roster.sessions[0]?.id ?? null;
  useEffect(() => {
    if (selected === null && roster.sessions[0]) setSelected(roster.sessions[0].id);
  }, [selected, roster.sessions]);

  const bridge = useMemo(createSurfaceBridge, []);
  const surface = useSurfaceState(bridge);

  const choose = useCallback((id: string) => {
    setSelected(id);
    // A different session is a different attachment, and the write token does
    // not travel with the click.
    setMode("observe");
    const url = new URL(window.location.href);
    url.searchParams.set("session", id);
    history.replaceState(null, "", url.pathname + url.search);
  }, []);

  return (
    <div className="app" style={chromeTokens(palette) as React.CSSProperties}>
      <aside className="sidebar">
        <header className="sidebar-head">
          <span className="brand">termio</span>
          <button
            type="button"
            className="ghost"
            onClick={() => onTheme(theme === "dark" ? "light" : "dark")}
            title="Switch theme"
          >
            {theme === "dark" ? "Light" : "Dark"}
          </button>
        </header>
        <SessionList roster={roster} active={active} onChoose={choose} onRetry={() => rosterBridge.current()?.refresh()} />
      </aside>

      <main className="main">
        <header className="toolbar">
          <span className="title">{surface.title ?? surface.name ?? "No session"}</span>
          <span className={`badge ${surface.writer ? "badge-writer" : "badge-observer"}`}>
            {surface.writer ? "Writing" : "Observing"}
          </span>
          <span className="dims">
            {surface.cols}×{surface.rows}
          </span>
          <span className="spacer" />
          {mode === "observe" ? (
            <button type="button" onClick={() => setMode("interact")} disabled={!active}>
              Take input
            </button>
          ) : (
            <button type="button" onClick={() => setMode("observe")}>
              Release
            </button>
          )}
        </header>

        {/* The attach barrier holds paint until `Event::Ready`, so without this
            the stage is a blank canvas with nothing to explain it. */}
        {active && (surface.phase === "connecting" || surface.phase === "attaching") ? (
          <p className="notice">Attaching…</p>
        ) : null}
        {surface.notice ? <p className="notice">{surface.notice}</p> : null}
        {surface.error ? <p className="notice notice-error">{surface.error}</p> : null}
        {roster.error ? <p className="notice notice-error">{roster.error}</p> : null}
        {surface.scrollOffsetRows > 0 ? (
          <p className="notice">
            Scrolled {surface.scrollOffsetRows} rows into history — type to jump back.
          </p>
        ) : null}

        <RendererStatsPanel bridge={bridge} />

        <div className="stage">
          {binding.status === "failed" ? (
            <p className="empty">{binding.message}</p>
          ) : binding.status === "loading" ? (
            <p className="empty">Loading the terminal engine…</p>
          ) : !active ? (
            <p className="empty">No sessions on this host yet. Start one with `termiod new`.</p>
          ) : (
            <TerminalSurface
              // Identity is (session, mode): taking input is a new socket with
              // `mode: interact`, which the protocol only lets you set once per
              // channel — so it is a remount, not a re-render.
              key={`${active}:${mode}`}
              sessionId={active}
              wsUrl={wsUrl}
              token={token}
              mode={mode}
              binding={binding.binding}
              palette={palette}
              client={CLIENT_NAME}
              bridge={bridge}
            />
          )}
        </div>
      </main>
    </div>
  );
}

function SessionList(props: {
  roster: RosterState;
  active: string | null;
  onChoose: (id: string) => void;
  onRetry: () => void;
}): React.JSX.Element {
  const { roster, active, onChoose, onRetry } = props;
  if (roster.phase === "connecting") return <p className="empty">Connecting…</p>;
  if (roster.sessions.length === 0) {
    return (
      <div className="empty">
        <p>No sessions.</p>
        <button type="button" onClick={onRetry}>
          Refresh
        </button>
      </div>
    );
  }
  return (
    <ul className="sessions">
      {roster.sessions.map((session) => (
        <li key={session.id}>
          <button
            type="button"
            className={`session ${session.id === active ? "session-active" : ""}`}
            onClick={() => onChoose(session.id)}
          >
            <span className={`dot status-${statusClass(session)}`} />
            <span className="session-name">{sessionLabel(session)}</span>
            <span className="session-cwd">{session.cwd}</span>
          </button>
        </li>
      ))}
    </ul>
  );
}

/**
 * The counters the WebGPU entry trigger is argued from: p95 full-redraw frame
 * time over 16.7 ms, or sustained scroll below 30 fps. Opt-in with `?stats=1`,
 * read here and in the console, and sent nowhere.
 */
function RendererStatsPanel({ bridge }: { bridge: SurfaceBridge }): React.JSX.Element | null {
  const enabled = useMemo(() => new URLSearchParams(window.location.search).has("stats"), []);
  const [stats, setStats] = useState<RendererStats | null>(null);
  useEffect(() => {
    if (!enabled) return;
    // One second, not one frame: this is chrome, and the surface is memoised
    // against exactly this kind of tick.
    const timer = setInterval(() => setStats(bridge.current()?.stats() ?? null), 1000);
    return () => clearInterval(timer);
  }, [enabled, bridge]);
  if (!enabled || !stats) return null;
  return (
    <p className="notice">
      {stats.implementation} · {stats.framesPainted} frames ({stats.fullRedraws} full) · p50{" "}
      {stats.frameTimeP50Ms.toFixed(2)} ms · p95 {stats.frameTimeP95Ms.toFixed(2)} ms ·{" "}
      {stats.droppedFrames} over budget
    </p>
  );
}

function statusClass(session: SessionInfo): string {
  if (!session.alive) return "dead";
  return session.status.replace(/[^a-z_]/g, "") || "unknown";
}

function TokenGate(): React.JSX.Element {
  return (
    <div className="app" style={chromeTokens(buildPalette("dark")) as React.CSSProperties}>
      <div className="gate">
        <h1>termio</h1>
        <p>
          This page needs the pairing token from the host. Run <code>termiod pair</code> on the box
          and open the link it prints, which ends in <code>#t=…</code>.
        </p>
      </div>
    </div>
  );
}

function safeSessionStorage(): Storage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}
