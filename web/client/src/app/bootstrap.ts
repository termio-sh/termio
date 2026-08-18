/**
 * Page bootstrap: the pairing token, the Wasm URL, and the session deep link.
 *
 * Everything here is a pure function of a location-shaped object so it can be
 * tested without a browser, and so nothing in the app reads globals directly.
 */

const TOKEN_STORAGE_KEY = "termio.pair.token";

export interface LocationLike {
  href: string;
  hash: string;
  search: string;
}

export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

/**
 * The canonical page URL is `https://box/termio/#t=<token>`. The fragment is
 * never sent to a server, so it is the only part of a URL a credential may ride
 * in; it is read once, moved into sessionStorage, and cleared so a screenshot
 * or a shared URL bar does not carry it.
 *
 * `clearHash` is the caller's business (it is `history.replaceState` in the
 * browser and a no-op in a test), because this module owns no DOM.
 */
export function takeToken(
  location: LocationLike,
  storage: StorageLike | null,
  clearHash?: () => void,
): string | null {
  const fromHash = /^#t=(.+)$/.exec(location.hash);
  if (fromHash?.[1]) {
    const token = decodeURIComponent(fromHash[1]);
    try {
      storage?.setItem(TOKEN_STORAGE_KEY, token);
    } catch {
      // Private-mode storage refusals are survivable: the token stays in
      // memory for this page load and a reload asks for the link again.
    }
    clearHash?.();
    return token;
  }
  try {
    return storage?.getItem(TOKEN_STORAGE_KEY) ?? null;
  } catch {
    return null;
  }
}

export function forgetToken(storage: StorageLike | null): void {
  try {
    storage?.removeItem(TOKEN_STORAGE_KEY);
  } catch {
    // Nothing to do; the next load will ask for a fresh link.
  }
}

/**
 * The Wasm sits at the web root, next to `index.html`, and the bundle sits one
 * level down in `assets/`. Resolving it from `import.meta.url` — the shape the
 * frozen contract sketched — would therefore ask for `assets/ghostty-vt.wasm`
 * and 404 under both mounts. The document base is the prefix that actually
 * served the page: `/` behind Caddy's `handle_path`, `/termio/` behind
 * Tailscale Serve.
 */
export function wasmUrl(baseHref: string): URL {
  return new URL("ghostty-vt.wasm", baseHref);
}

/** The web equivalent of `termio://session/<uuid>`: a query on this origin. */
export function sessionFromLocation(location: LocationLike): string | null {
  return new URLSearchParams(location.search).get("session");
}
