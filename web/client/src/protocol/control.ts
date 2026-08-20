/**
 * Control (`C`) and Event (`E`) payloads: JSON, tagged the way serde tags them
 * in `termiod/src/protocol.rs`. Control is `{"op": <snake_case>}` and Event is
 * `{"ev": <snake_case>}`; field names are the Rust field names verbatim, so
 * `JSON.parse` output *is* the type with no rename layer in between.
 */
import { ProtocolError } from "./errors";

export type ChannelRole = "control" | "attach";
export type AttachMode = "interact" | "observe";

export type ErrorCode =
  | "incompatible"
  | "proto_error"
  | "no_such_session"
  | "not_writer"
  | "already_exited"
  | "create_failed"
  | "denied"
  | "busy"
  | "internal";

/** `termiod list`'s row. Optional fields are `#[serde(default)]` host-side. */
export interface SessionInfo {
  id: string;
  name: string;
  cwd: string;
  command: string;
  pid: number;
  rows: number;
  cols: number;
  clients: number;
  created_unix: number;
  alive: boolean;
  status: string; // working | idle | needs_you | done | failed | unknown
  agent_id?: string | null;
  title?: string | null;
  attached_clients?: number;
  writer_client_id?: string | null;
}

/** Opaque to the web client: it lists tombstones, it does not read them. */
export interface Tombstone {
  [key: string]: unknown;
}

/** ─── Client → host. These are the ONLY ops the web client may send. ─── */
export type ControlOut =
  | {
      op: "hello";
      proto: 1;
      min_proto: 1;
      role: ChannelRole;
      /** control channel: ["events"] · attach channel: ["events","snapshot","scrollback"].
       *  `grid_diff` is never advertised on the grounds that the client is a browser. */
      caps: string[];
      client: string; // "termio-web/<version>"
    }
  | { op: "list"; seq?: number }
  | { op: "subscribe"; events: string[]; seq?: number } // ["roster","status"]
  | {
      op: "attach";
      target: string; // session id or name
      rows: number;
      cols: number;
      mode: AttachMode; // ALWAYS sent explicitly; the host default is "interact"
      seq?: number;
    }
  | { op: "detach"; seq?: number };

/** ─── Host → client. Anything else decodes to { op: "unknown" }. ─── */
export type ControlIn =
  | {
      op: "hello_ok";
      proto: number;
      caps: string[];
      host_id: string;
      host: string;
      client_id: string;
    }
  | { op: "hello_err"; code: ErrorCode; supported: number[] }
  | {
      op: "sessions";
      sessions: SessionInfo[];
      tombstones?: Tombstone[];
      re?: number;
    }
  | {
      op: "attached";
      id: string; // v0 field, retained
      name: string;
      session_id: string; // canonical v0.1 field — use this one
      writer: boolean;
      rows: number; // AUTHORITATIVE dims; not the canvas size
      cols: number;
      re?: number;
    }
  | { op: "ok"; re?: number } // the reply to `subscribe` and `detach`
  | {
      op: "error";
      re?: number;
      code: ErrorCode;
      message: string;
      retryable: boolean;
    }
  | { op: "exited"; id: string; status: number }
  | { op: "unknown" };

export type Control = ControlOut | ControlIn;

/** ─── Events. Unknown `ev` values decode to { ev: "unknown" } and are dropped. ─── */
export type Event =
  | { ev: "ready"; session: string }
  | { ev: "status"; session: string; status: string; title?: string | null }
  | { ev: "writer_changed"; session: string; writer?: string | null }
  | { ev: "resized"; session: string; rows: number; cols: number }
  | { ev: "session_exited"; session: string; status: number }
  | { ev: "resynced"; session: string; reason: string }
  | { ev: "vt_stale"; session: string; reason: string }
  | { ev: "roster"; session: string; action: string; info?: SessionInfo | null }
  | { ev: "unknown" };

const UNKNOWN_CONTROL: ControlIn = { op: "unknown" };
const UNKNOWN_EVENT: Event = { ev: "unknown" };

const ERROR_CODES = new Set<string>([
  "incompatible",
  "proto_error",
  "no_such_session",
  "not_writer",
  "already_exited",
  "create_failed",
  "denied",
  "busy",
  "internal",
]);

const decoder = new TextDecoder("utf-8", { fatal: true });
const encoder = new TextEncoder();

function parseJson(payload: Uint8Array, what: string): unknown {
  let text: string;
  try {
    text = decoder.decode(payload);
  } catch {
    throw new ProtocolError(`${what} payload is not UTF-8`);
  }
  try {
    return JSON.parse(text) as unknown;
  } catch (error) {
    throw new ProtocolError(
      `invalid ${what} JSON: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function str(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function num(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function bool(value: unknown, fallback = false): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v) => typeof v === "string") : [];
}

/** An unrecognised code is `internal`, matching `ErrorCode`'s serde default. */
function errorCode(value: unknown): ErrorCode {
  return typeof value === "string" && ERROR_CODES.has(value)
    ? (value as ErrorCode)
    : "internal";
}

/** Present only when the host sent it, so `exactOptionalPropertyTypes` holds. */
function optionalSeq(source: Record<string, unknown>): { re?: number } {
  return typeof source["re"] === "number" ? { re: source["re"] } : {};
}

function sessionInfo(value: unknown): SessionInfo | null {
  const row = record(value);
  if (!row) return null;
  const info: SessionInfo = {
    id: str(row["id"]),
    name: str(row["name"]),
    cwd: str(row["cwd"]),
    command: str(row["command"]),
    pid: num(row["pid"]),
    rows: num(row["rows"], 24),
    cols: num(row["cols"], 80),
    clients: num(row["clients"]),
    created_unix: num(row["created_unix"]),
    alive: bool(row["alive"]),
    // `#[serde(default = "default_status")]` host-side.
    status: str(row["status"], "unknown"),
  };
  if ("agent_id" in row) info.agent_id = row["agent_id"] as string | null;
  if ("title" in row) info.title = row["title"] as string | null;
  if (typeof row["attached_clients"] === "number") {
    info.attached_clients = row["attached_clients"];
  }
  if ("writer_client_id" in row) {
    info.writer_client_id = row["writer_client_id"] as string | null;
  }
  return info;
}

/**
 * Decode a `C` payload. Only the host → client ops are recognised; a client's
 * own op read back off a transcript is `{ op: "unknown" }`, which is the
 * contract, not a gap. Missing `#[serde(default)]` fields are filled with the
 * host's own defaults so the returned object really matches its declared type.
 */
export function decodeControl(payload: Uint8Array): ControlIn {
  const message = record(parseJson(payload, "control"));
  if (!message) return UNKNOWN_CONTROL;
  switch (message["op"]) {
    case "hello_ok":
      return {
        op: "hello_ok",
        proto: num(message["proto"]),
        caps: strings(message["caps"]),
        host_id: str(message["host_id"]),
        host: str(message["host"]),
        client_id: str(message["client_id"]),
      };
    case "hello_err":
      return {
        op: "hello_err",
        code: errorCode(message["code"]),
        supported: Array.isArray(message["supported"])
          ? message["supported"].filter((v) => typeof v === "number")
          : [],
      };
    case "sessions": {
      const sessions = Array.isArray(message["sessions"])
        ? message["sessions"]
            .map(sessionInfo)
            .filter((row): row is SessionInfo => row !== null)
        : [];
      const tombstones = Array.isArray(message["tombstones"])
        ? message["tombstones"]
            .map(record)
            .filter((row): row is Record<string, unknown> => row !== null)
        : undefined;
      return {
        op: "sessions",
        sessions,
        ...(tombstones ? { tombstones } : {}),
        ...optionalSeq(message),
      };
    }
    case "attached": {
      const id = str(message["id"]);
      return {
        op: "attached",
        id,
        name: str(message["name"]),
        // `session_id` is `#[serde(default)]`, so a v0-era host omits it and
        // the v0 `id` field is the only session identity on the frame.
        session_id: str(message["session_id"]) || id,
        writer: bool(message["writer"]),
        rows: num(message["rows"], 24),
        cols: num(message["cols"], 80),
        ...optionalSeq(message),
      };
    }
    case "ok":
      return { op: "ok", ...optionalSeq(message) };
    case "error":
      return {
        op: "error",
        code: errorCode(message["code"]),
        message: str(message["message"]),
        retryable: bool(message["retryable"]),
        ...optionalSeq(message),
      };
    case "exited":
      return {
        op: "exited",
        id: str(message["id"]),
        status: num(message["status"]),
      };
    default:
      return UNKNOWN_CONTROL;
  }
}

/** Decode an `E` payload. Unknown `ev` values are dropped, never fatal. */
export function decodeEvent(payload: Uint8Array): Event {
  const message = record(parseJson(payload, "event"));
  if (!message) return UNKNOWN_EVENT;
  const session = str(message["session"]);
  switch (message["ev"]) {
    case "ready":
      return { ev: "ready", session };
    case "status": {
      const event: Event = {
        ev: "status",
        session,
        status: str(message["status"], "unknown"),
      };
      if ("title" in message) event.title = message["title"] as string | null;
      return event;
    }
    case "writer_changed": {
      const event: Event = { ev: "writer_changed", session };
      if ("writer" in message) event.writer = message["writer"] as string | null;
      return event;
    }
    case "resized":
      return {
        ev: "resized",
        session,
        rows: num(message["rows"], 24),
        cols: num(message["cols"], 80),
      };
    case "session_exited":
      return { ev: "session_exited", session, status: num(message["status"]) };
    case "resynced":
      return { ev: "resynced", session, reason: str(message["reason"]) };
    case "vt_stale":
      return { ev: "vt_stale", session, reason: str(message["reason"]) };
    case "roster": {
      const event: Event = {
        ev: "roster",
        session,
        action: str(message["action"]),
      };
      if ("info" in message) event.info = sessionInfo(message["info"]);
      return event;
    }
    default:
      return UNKNOWN_EVENT;
  }
}

/** JSON body of a client → host control message, ready to frame. */
export function encodeControlPayload(msg: ControlOut): Uint8Array {
  return encoder.encode(JSON.stringify(msg));
}
