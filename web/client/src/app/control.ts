/**
 * The control channel: one WebSocket that lists sessions and then lives on
 * `subscribe`, so the page never polls `list` as its live path.
 *
 * The store shape is the `useSyncExternalStore` contract — a listener set and a
 * snapshot that is replaced, never mutated — because React must be able to tell
 * that the roster changed without any component owning it.
 */

import type { Frame } from "../protocol/frame";
import { KIND } from "../protocol/frame";
import type {
  ControlIn,
  Event as ProtocolEvent,
  SessionInfo,
} from "../protocol/control";
import { openChannel, type Channel, type ChannelOptions } from "../protocol/socket";

export type ConnectionPhase = "connecting" | "ready" | "closed" | "error";

export interface RosterState {
  phase: ConnectionPhase;
  sessions: SessionInfo[];
  hostId: string | null;
  host: string | null;
  error: string | null;
}

export interface ControlClient {
  subscribe(listener: () => void): () => void;
  snapshot(): RosterState;
  /** A manual re-`list`. The roster is event-driven; this is the retry button. */
  refresh(): void;
  dispose(): void;
}

export interface ControlOptions {
  url: URL;
  token: string;
  client: string;
  /** Injected in tests. Defaults to the real WebSocket channel. */
  open?: (options: ChannelOptions) => Channel;
}

/** What React sees before the effect that opens the socket has run. */
export const IDLE_ROSTER_STATE: RosterState = Object.freeze({
  phase: "connecting",
  sessions: [],
  hostId: null,
  host: null,
  error: null,
});

export function createControlClient(options: ControlOptions): ControlClient {
  const open = options.open ?? openChannel;
  const listeners = new Set<() => void>();
  let state: RosterState = IDLE_ROSTER_STATE;
  let disposed = false;
  let seq = 0;

  const update = (patch: Partial<RosterState>): void => {
    state = { ...state, ...patch };
    for (const listener of [...listeners]) listener();
  };

  const replaceSession = (id: string, next: SessionInfo | null): void => {
    const sessions = state.sessions.filter((session) => session.id !== id);
    if (next) sessions.push(next);
    sessions.sort(byCreated);
    update({ sessions });
  };

  const patchSession = (id: string, patch: Partial<SessionInfo>): void => {
    let changed = false;
    const sessions = state.sessions.map((session) => {
      if (session.id !== id) return session;
      changed = true;
      return { ...session, ...patch };
    });
    if (changed) update({ sessions });
  };

  // Assigned immediately below. A frame cannot arrive before `open` returns on
  // a real WebSocket, and the null guard is what keeps that from being a
  // load-bearing assumption.
  let channel: Channel | null = null;

  const onControl = (message: ControlIn): void => {
    switch (message.op) {
      case "hello_ok":
        update({ phase: "ready", hostId: message.host_id, host: message.host, error: null });
        seq += 1;
        channel?.sendControl({ op: "list", seq });
        seq += 1;
        channel?.sendControl({ op: "subscribe", events: ["roster", "status"], seq });
        return;
      case "hello_err":
        update({
          phase: "error",
          error: `host refused the handshake (${message.code}); it speaks protocol ${message.supported.join(", ")}`,
        });
        return;
      case "sessions":
        update({ sessions: [...message.sessions].sort(byCreated) });
        return;
      case "error":
        update({ error: `${message.code}: ${message.message}` });
        return;
      case "exited":
        patchSession(message.id, { alive: false, status: "done" });
        return;
      default:
        return;
    }
  };

  const onEvent = (event: ProtocolEvent): void => {
    switch (event.ev) {
      case "roster":
        if (event.action === "removed") {
          replaceSession(event.session, null);
        } else if (event.info) {
          replaceSession(event.session, event.info);
        }
        return;
      case "status":
        patchSession(event.session, {
          status: event.status,
          ...(event.title === undefined ? {} : { title: event.title }),
        });
        return;
      case "session_exited":
        patchSession(event.session, { alive: false });
        return;
      case "writer_changed":
        patchSession(event.session, { writer_client_id: event.writer ?? null });
        return;
      case "resized":
        patchSession(event.session, { rows: event.rows, cols: event.cols });
        return;
      default:
        return;
    }
  };

  channel = open({
    url: options.url,
    token: options.token,
    onFrame(frame: Frame): void {
      if (disposed) return;
      if (frame.kind === KIND.CONTROL) {
        onControl(frame.control as ControlIn);
      } else if (frame.kind === KIND.EVENT) {
        onEvent(frame.event);
      }
      // Every other kind belongs to an attach channel and is not an error here.
    },
    onClose(info): void {
      if (disposed) return;
      update({
        phase: "closed",
        error:
          info.code === 1000 || info.code === 1005
            ? state.error
            : `connection closed (${info.code}${info.reason ? `: ${info.reason}` : ""})`,
      });
    },
    onError(error): void {
      if (disposed) return;
      update({ phase: "error", error: error.message });
    },
  });

  channel.sendControl({
    op: "hello",
    proto: 1,
    min_proto: 1,
    role: "control",
    caps: ["events"],
    client: options.client,
  });

  const live = channel;

  return {
    subscribe(listener: () => void): () => void {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    snapshot(): RosterState {
      return state;
    },
    refresh(): void {
      if (disposed) return;
      seq += 1;
      live.sendControl({ op: "list", seq });
    },
    dispose(): void {
      if (disposed) return;
      disposed = true;
      listeners.clear();
      live.close();
    },
  };
}

/** Newest first, which is what a person opening the page is looking for. */
function byCreated(a: SessionInfo, b: SessionInfo): number {
  if (a.created_unix !== b.created_unix) return b.created_unix - a.created_unix;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/** What the shell shows on a row, derived rather than stored. */
export function sessionLabel(session: SessionInfo): string {
  const title = session.title?.trim();
  if (title) return title;
  if (session.name.trim()) return session.name;
  return session.command || session.id.slice(0, 8);
}
