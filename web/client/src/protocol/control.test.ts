import { describe, expect, it } from "vitest";
import { decodeControl, decodeEvent, encodeControlPayload } from "./control";
import type { ControlOut, SessionInfo } from "./control";
import { ProtocolError } from "./errors";

const encode = (value: unknown): Uint8Array =>
  new TextEncoder().encode(JSON.stringify(value));

const sessionRow: SessionInfo = {
  id: "s1",
  name: "shell",
  cwd: "/home/me",
  command: "zsh",
  pid: 4242,
  rows: 24,
  cols: 80,
  clients: 1,
  created_unix: 1_760_000_000,
  alive: true,
  status: "working",
};

describe("encodeControlPayload", () => {
  it("writes the ops with the field names serde expects", () => {
    const hello: ControlOut = {
      op: "hello",
      proto: 1,
      min_proto: 1,
      role: "attach",
      caps: ["events", "snapshot", "scrollback"],
      client: "termio-web/0.1.0",
    };
    expect(JSON.parse(new TextDecoder().decode(encodeControlPayload(hello)))).toEqual(
      {
        op: "hello",
        proto: 1,
        min_proto: 1,
        role: "attach",
        caps: ["events", "snapshot", "scrollback"],
        client: "termio-web/0.1.0",
      },
    );
  });

  it("never advertises grid_diff", () => {
    const hello: ControlOut = {
      op: "hello",
      proto: 1,
      min_proto: 1,
      role: "attach",
      caps: ["events", "snapshot", "scrollback"],
      client: "termio-web/0.1.0",
    };
    expect(hello.caps).not.toContain("grid_diff");
  });

  it("sends attach mode explicitly, because the host default is interact", () => {
    const attach: ControlOut = {
      op: "attach",
      target: "s1",
      rows: 24,
      cols: 80,
      mode: "observe",
      seq: 2,
    };
    const json = JSON.parse(
      new TextDecoder().decode(encodeControlPayload(attach)),
    ) as Record<string, unknown>;
    expect(json["mode"]).toBe("observe");
  });

  it("omits an absent seq rather than sending null", () => {
    const json = JSON.parse(
      new TextDecoder().decode(encodeControlPayload({ op: "list" })),
    ) as Record<string, unknown>;
    expect("seq" in json).toBe(false);
  });
});

describe("decodeControl", () => {
  it("decodes hello_ok", () => {
    expect(
      decodeControl(
        encode({
          op: "hello_ok",
          proto: 1,
          caps: ["events", "snapshot"],
          host_id: "h",
          host: "box",
          client_id: "c",
        }),
      ),
    ).toEqual({
      op: "hello_ok",
      proto: 1,
      caps: ["events", "snapshot"],
      host_id: "h",
      host: "box",
      client_id: "c",
    });
  });

  it("decodes hello_err with the supported list", () => {
    expect(
      decodeControl(
        encode({ op: "hello_err", code: "incompatible", supported: [1] }),
      ),
    ).toEqual({ op: "hello_err", code: "incompatible", supported: [1] });
  });

  it("decodes attached and keeps rows/cols as the authoritative dims", () => {
    const message = decodeControl(
      encode({
        op: "attached",
        id: "s1",
        name: "shell",
        session_id: "s1",
        writer: false,
        rows: 40,
        cols: 120,
        re: 3,
      }),
    );
    expect(message).toEqual({
      op: "attached",
      id: "s1",
      name: "shell",
      session_id: "s1",
      writer: false,
      rows: 40,
      cols: 120,
      re: 3,
    });
  });

  it("falls back to the v0 id when a host omits session_id", () => {
    const message = decodeControl(
      encode({ op: "attached", id: "s9", name: "shell" }),
    );
    if (message.op !== "attached") throw new Error("expected attached");
    expect(message.session_id).toBe("s9");
    expect(message.writer).toBe(false);
    expect(message.rows).toBe(24);
    expect(message.cols).toBe(80);
  });

  it("decodes sessions, filling the host's serde defaults", () => {
    const message = decodeControl(
      encode({
        op: "sessions",
        sessions: [
          { ...sessionRow, status: undefined, agent_id: null },
          { ...sessionRow, id: "s2", attached_clients: 2 },
        ],
        re: 1,
      }),
    );
    if (message.op !== "sessions") throw new Error("expected sessions");
    expect(message.sessions.length).toBe(2);
    expect(message.sessions[0].status).toBe("unknown");
    expect(message.sessions[0].agent_id).toBeNull();
    expect(message.sessions[1].attached_clients).toBe(2);
    expect(message.re).toBe(1);
    expect(message.tombstones).toBeUndefined();
  });

  it("keeps tombstones opaque", () => {
    const message = decodeControl(
      encode({
        op: "sessions",
        sessions: [],
        tombstones: [{ id: "dead", reason: "exited" }],
      }),
    );
    if (message.op !== "sessions") throw new Error("expected sessions");
    expect(message.tombstones).toEqual([{ id: "dead", reason: "exited" }]);
  });

  it("decodes the typed error model", () => {
    expect(
      decodeControl(
        encode({
          op: "error",
          re: 4,
          code: "not_writer",
          message: "observer cannot write",
          retryable: false,
        }),
      ),
    ).toEqual({
      op: "error",
      re: 4,
      code: "not_writer",
      message: "observer cannot write",
      retryable: false,
    });
  });

  it("maps an unrecognised error code to internal, matching the serde default", () => {
    const message = decodeControl(
      encode({ op: "error", code: "teapot", message: "?", retryable: true }),
    );
    if (message.op !== "error") throw new Error("expected error");
    expect(message.code).toBe("internal");
  });

  it("decodes ok and exited", () => {
    expect(decodeControl(encode({ op: "ok", re: 2 }))).toEqual({
      op: "ok",
      re: 2,
    });
    expect(decodeControl(encode({ op: "exited", id: "s1", status: 0 }))).toEqual(
      { op: "exited", id: "s1", status: 0 },
    );
  });

  it("decodes an unknown op to unknown rather than throwing", () => {
    expect(decodeControl(encode({ op: "resize_claim", session: "s1" }))).toEqual(
      { op: "unknown" },
    );
    expect(decodeControl(encode({ op: "hello", proto: 1 }))).toEqual({
      op: "unknown",
    });
    expect(decodeControl(encode(["not", "an", "object"]))).toEqual({
      op: "unknown",
    });
  });

  it("throws on a payload that is not JSON", () => {
    expect(() => decodeControl(new TextEncoder().encode("{"))).toThrow(
      ProtocolError,
    );
  });

  it("throws on a payload that is not UTF-8", () => {
    expect(() => decodeControl(new Uint8Array([0xff, 0xfe]))).toThrow(
      ProtocolError,
    );
  });
});

describe("decodeEvent", () => {
  it("decodes the attach-path events", () => {
    expect(decodeEvent(encode({ ev: "ready", session: "s1" }))).toEqual({
      ev: "ready",
      session: "s1",
    });
    expect(
      decodeEvent(encode({ ev: "resized", session: "s1", rows: 30, cols: 100 })),
    ).toEqual({ ev: "resized", session: "s1", rows: 30, cols: 100 });
    expect(
      decodeEvent(encode({ ev: "resynced", session: "s1", reason: "backlog" })),
    ).toEqual({ ev: "resynced", session: "s1", reason: "backlog" });
    expect(
      decodeEvent(encode({ ev: "vt_stale", session: "s1", reason: "ring" })),
    ).toEqual({ ev: "vt_stale", session: "s1", reason: "ring" });
    expect(
      decodeEvent(encode({ ev: "session_exited", session: "s1", status: 130 })),
    ).toEqual({ ev: "session_exited", session: "s1", status: 130 });
  });

  it("decodes status with and without a title", () => {
    expect(
      decodeEvent(
        encode({ ev: "status", session: "s1", status: "needs_you", title: "?" }),
      ),
    ).toEqual({ ev: "status", session: "s1", status: "needs_you", title: "?" });
    const bare = decodeEvent(
      encode({ ev: "status", session: "s1", status: "idle" }),
    );
    expect(bare).toEqual({ ev: "status", session: "s1", status: "idle" });
    expect("title" in bare).toBe(false);
  });

  it("decodes writer_changed with a null writer", () => {
    expect(
      decodeEvent(encode({ ev: "writer_changed", session: "s1", writer: null })),
    ).toEqual({ ev: "writer_changed", session: "s1", writer: null });
  });

  it("decodes a roster delta and its session info", () => {
    const event = decodeEvent(
      encode({
        ev: "roster",
        session: "s1",
        action: "added",
        info: sessionRow,
      }),
    );
    if (event.ev !== "roster") throw new Error("expected roster");
    expect(event.action).toBe("added");
    expect(event.info?.command).toBe("zsh");
  });

  it("drops an unknown event", () => {
    expect(decodeEvent(encode({ ev: "fs_changed", resource: "fs:/x" }))).toEqual(
      { ev: "unknown" },
    );
  });
});
