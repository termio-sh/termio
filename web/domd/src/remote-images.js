// Remote images in a Markdown file are tracking pixels.
//
// Opening a document fetches them, which tells that host your IP and the moment you
// opened the file — and the file may be a README an agent just pulled from anywhere.
// The old reader accepts that exposure (it ships no CSP at all). This face does not
// accept it silently: remote images are HELD until the reader asks for them, once per
// document, which is exactly what every mail client does with remote content and for
// exactly the same reason.
//
// The CSP still has to permit https: — nothing can be unlocked that the policy forbids —
// so the block lives here rather than in the policy. `default-src 'none'` and
// `connect-src 'none'` are unchanged: the page still cannot fetch, only display.

/// A 1×1 transparent GIF. Holding a slot rather than emptying it keeps the layout from
/// jumping when the images are let in.
export const HELD_PIXEL =
  "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";

const state = { unlocked: false, held: 0, onChange: null };

export const isRemote = (url) => /^https?:/i.test(String(url).trim());

export function remoteImages() {
  return {
    get unlocked() { return state.unlocked; },
    get held() { return state.held; },
    /// Called for every remote URL the page is asked to show. Returns what to put in
    /// `src`: the real URL once unlocked, a held pixel before that.
    resolve(url) {
      if (state.unlocked) return url;
      state.held += 1;
      state.onChange?.();
      return HELD_PIXEL;
    },
    /// A new document starts locked again — consent is per document, not per session.
    reset() {
      state.unlocked = false;
      state.held = 0;
      state.onChange?.();
    },
    unlock() {
      if (state.unlocked) return false;
      state.unlocked = true;
      state.onChange?.();
      return true;
    },
    observe(fn) { state.onChange = fn; },
  };
}
