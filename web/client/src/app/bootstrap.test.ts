import { describe, expect, it } from "vitest";

import { forgetToken, sessionFromLocation, takeToken, wasmUrl } from "./bootstrap";

class MemoryStorage {
  private readonly map = new Map<string, string>();
  getItem(key: string): string | null {
    return this.map.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.map.set(key, value);
  }
  removeItem(key: string): void {
    this.map.delete(key);
  }
  get size(): number {
    return this.map.size;
  }
}

describe("token bootstrap", () => {
  it("takes the token from the fragment, stashes it, and clears the hash", () => {
    const storage = new MemoryStorage();
    let cleared = false;
    const token = takeToken(
      { href: "https://box/termio/#t=abc123", hash: "#t=abc123", search: "" },
      storage,
      () => {
        cleared = true;
      },
    );
    expect(token).toBe("abc123");
    expect(cleared).toBe(true);
    // A reload with no fragment still finds it.
    expect(takeToken({ href: "https://box/termio/", hash: "", search: "" }, storage)).toBe(
      "abc123",
    );
  });

  it("percent-decodes a base64url token that got encoded on the way in", () => {
    const storage = new MemoryStorage();
    expect(
      takeToken({ href: "", hash: "#t=a%2Bb%2Fc", search: "" }, storage),
    ).toBe("a+b/c");
  });

  it("survives a storage that refuses to store", () => {
    const hostile = {
      getItem(): string | null {
        throw new Error("blocked");
      },
      setItem(): void {
        throw new Error("blocked");
      },
      removeItem(): void {
        throw new Error("blocked");
      },
    };
    expect(takeToken({ href: "", hash: "#t=abc", search: "" }, hostile)).toBe("abc");
    expect(takeToken({ href: "", hash: "", search: "" }, hostile)).toBeNull();
    expect(() => forgetToken(hostile)).not.toThrow();
  });

  it("has no token without a fragment and without storage", () => {
    expect(takeToken({ href: "https://box/termio/", hash: "", search: "" }, null)).toBeNull();
  });
});

describe("asset and deep-link URLs", () => {
  it("resolves the Wasm against the mount that served the page, not the bundle", () => {
    // Under Tailscale Serve the page is at /termio/ and the bundle is one level
    // down in assets/; resolving from the module URL would ask for
    // /termio/assets/ghostty-vt.wasm and 404.
    expect(wasmUrl("https://box/termio/").href).toBe("https://box/termio/ghostty-vt.wasm");
    expect(wasmUrl("https://box/").href).toBe("https://box/ghostty-vt.wasm");
    expect(wasmUrl("https://box/termio/index.html").href).toBe(
      "https://box/termio/ghostty-vt.wasm",
    );
  });

  it("reads the session deep link off the query, never off /ws", () => {
    expect(
      sessionFromLocation({ href: "", hash: "", search: "?session=abc-123" }),
    ).toBe("abc-123");
    expect(sessionFromLocation({ href: "", hash: "", search: "" })).toBeNull();
  });
});
