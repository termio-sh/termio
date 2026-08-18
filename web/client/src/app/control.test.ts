import { describe, expect, it } from "vitest";

import type { SessionInfo } from "../protocol/control";
import { KIND } from "../protocol/frame";
import { createControlClient, sessionLabel, type ControlClient } from "./control";
import { FakeChannel, control, event, helloOk } from "./__fixtures__/harness";

function session(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: "s1",
    name: "shell",
    cwd: "/home/me",
    command: "zsh",
    pid: 1,
    rows: 24,
    cols: 80,
    clients: 0,
    created_unix: 100,
    alive: true,
    status: "idle",
    ...overrides,
  };
}

function harness(): { client: ControlClient; channel: FakeChannel } {
  let channel: FakeChannel | null = null;
  const client = createControlClient({
    url: new URL("wss://box.example/termio/ws"),
    token: "t",
    client: "termio-web/test",
    open: (options) => {
      channel = new FakeChannel(options);
      return channel;
    },
  });
  if (!channel) throw new Error("no channel");
  return { client, channel };
}

describe("control channel", () => {
  it("says hello as a control role and then subscribes rather than polling", () => {
    const { client, channel } = harness();
    expect(channel.control(0)).toMatchObject({
      op: "hello",
      role: "control",
      caps: ["events"],
    });

    channel.deliver(helloOk());
    expect(channel.control(1)).toMatchObject({ op: "list" });
    expect(channel.control(2)).toMatchObject({
      op: "subscribe",
      events: ["roster", "status"],
    });
    // Three frames, and no timer anywhere: the roster is event-driven.
    expect(channel.outgoing).toHaveLength(3);
    client.dispose();
  });

  it("orders sessions newest first and applies roster deltas", () => {
    const { client, channel } = harness();
    const notified: number[] = [];
    client.subscribe(() => notified.push(client.snapshot().sessions.length));

    channel.deliver(helloOk());
    channel.deliver(
      control({
        op: "sessions",
        sessions: [session({ id: "old", created_unix: 10 }), session({ id: "new", created_unix: 90 })],
      }),
    );
    expect(client.snapshot().sessions.map((item) => item.id)).toEqual(["new", "old"]);

    channel.deliver(
      event({
        ev: "roster",
        session: "third",
        action: "created",
        info: session({ id: "third", created_unix: 200 }),
      }),
    );
    expect(client.snapshot().sessions.map((item) => item.id)).toEqual(["third", "new", "old"]);

    channel.deliver(event({ ev: "roster", session: "new", action: "removed" }));
    expect(client.snapshot().sessions.map((item) => item.id)).toEqual(["third", "old"]);
    expect(notified.length).toBeGreaterThan(0);
    client.dispose();
  });

  it("tints a row from Event::Status without re-listing", () => {
    const { client, channel } = harness();
    channel.deliver(helloOk());
    channel.deliver(control({ op: "sessions", sessions: [session({ id: "s1" })] }));
    const before = channel.outgoing.length;

    channel.deliver(
      event({ ev: "status", session: "s1", status: "needs_you", title: "waiting on you" }),
    );
    expect(client.snapshot().sessions[0]).toMatchObject({
      status: "needs_you",
      title: "waiting on you",
    });
    expect(channel.outgoing).toHaveLength(before);
    client.dispose();
  });

  it("keeps the snapshot identity stable when nothing changed", () => {
    const { client, channel } = harness();
    channel.deliver(helloOk());
    channel.deliver(control({ op: "sessions", sessions: [session()] }));
    const first = client.snapshot();
    // `useSyncExternalStore` tears if getSnapshot returns a new object per call.
    expect(client.snapshot()).toBe(first);

    channel.deliver(event({ ev: "status", session: "unknown-session", status: "working" }));
    expect(client.snapshot()).toBe(first);
    client.dispose();
  });

  it("surfaces a handshake refusal instead of retrying forever", () => {
    const { client, channel } = harness();
    channel.deliver(control({ op: "hello_err", code: "incompatible", supported: [2] }));
    expect(client.snapshot().phase).toBe("error");
    expect(client.snapshot().error).toContain("incompatible");
    client.dispose();
  });

  it("never sends a frame that is not a Control", () => {
    const { client, channel } = harness();
    channel.deliver(helloOk());
    expect(new Set(channel.kinds())).toEqual(new Set([KIND.CONTROL]));
    client.dispose();
  });
});

describe("sessionLabel", () => {
  it("prefers the title, then the name, then the command", () => {
    expect(sessionLabel(session({ title: "claude: fixing tests" }))).toBe("claude: fixing tests");
    expect(sessionLabel(session({ title: "  " }))).toBe("shell");
    expect(sessionLabel(session({ name: "", command: "htop" }))).toBe("htop");
  });
});
