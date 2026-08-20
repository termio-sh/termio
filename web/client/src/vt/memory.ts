/**
 * The only legal way to touch Wasm linear memory from the host side.
 *
 * `wasm.h` states the rule this file exists to enforce: "An exported function
 * may grow Wasm linear memory when it allocates. Numeric pointers and handles
 * remain valid, but JavaScript ArrayBuffer, DataView, and typed-array objects
 * created before the growth may no longer cover the live memory. Reacquire
 * `exports.memory.buffer` immediately before every host-side memory access. A
 * host that caches views should recreate them whenever either the buffer
 * identity or its byte length changes."
 *
 * Nothing else in `src/vt/` is allowed to hold an `ArrayBuffer`, a `DataView`,
 * or a typed array in a field, a closure, or a returned object.
 */

export interface WasmMemoryExports {
  memory: WebAssembly.Memory;
  ghostty_wasm_alloc: (len: number) => number;
  ghostty_wasm_free: (ptr: number, len: number) => void;
}

export interface Mem {
  /** A view over `len` bytes at `ptr`. Valid until the next call into Wasm. */
  u8(ptr: number, len: number): Uint8Array;
  /** A DataView over all of linear memory. Valid until the next call into Wasm. */
  view(): DataView;
  /** `ghostty_wasm_alloc`. Returns a numeric pointer, which survives growth. */
  alloc(size: number): number;
  /** `ghostty_wasm_free`, with the exact length that was allocated. */
  free(ptr: number, size: number): void;
  /** Copies out of linear memory into a fresh JS buffer that survives growth. */
  copyOut(ptr: number, len: number): Uint8Array;
  /** Decodes UTF-8 out of linear memory into a JS string. */
  decodeUtf8(ptr: number, len: number): string;
}

export class OutOfMemoryError extends Error {
  constructor(size: number) {
    super(`ghostty_wasm_alloc(${size}) returned NULL`);
    this.name = "OutOfMemoryError";
  }
}

const utf8 = new TextDecoder("utf-8", { fatal: false });

export function createMem(exports: WasmMemoryExports): Mem {
  // The cache is keyed on both the buffer identity and its byte length, and
  // both checks are load-bearing:
  //
  //  - Identity alone misses the resizable-ArrayBuffer case. When the module's
  //    memory is backed by a growable buffer (`memory.toResizableBuffer()`, or
  //    any engine that grows in place), `memory.buffer` keeps the same object
  //    across a `memory.grow` and only its `byteLength` moves. A view cached on
  //    identity would then be a short view over a longer memory: every read past
  //    the old end silently returns nothing, and `new Uint8Array(buffer, ptr,
  //    len)` for a pointer beyond the old length throws RangeError.
  //  - Length alone misses the classic detach case, where growth hands back a
  //    brand-new ArrayBuffer that happens to be the same length as an earlier
  //    one — after a shrink-then-grow, or simply because the previous buffer was
  //    detached and replaced. Reading through the detached view yields zeroes
  //    with no error at all, which is the worst failure available here.
  //
  // `wasm.h` therefore says "either the buffer identity or its byte length" and
  // this cache checks exactly that, on every access.
  let cachedBuffer: ArrayBuffer | null = null;
  let cachedLength = 0;
  let cachedBytes: Uint8Array | null = null;
  let cachedView: DataView | null = null;

  function refresh(): void {
    const buffer = exports.memory.buffer;
    if (buffer === cachedBuffer && buffer.byteLength === cachedLength) return;
    cachedBuffer = buffer;
    cachedLength = buffer.byteLength;
    cachedBytes = new Uint8Array(buffer);
    cachedView = new DataView(buffer);
  }

  return {
    u8(ptr: number, len: number): Uint8Array {
      refresh();
      if (cachedBytes === null) throw new Error("wasm memory unavailable");
      if (ptr < 0 || len < 0 || ptr + len > cachedLength) {
        throw new RangeError(
          `wasm read of ${len} bytes at ${ptr} runs past ${cachedLength} bytes of memory`,
        );
      }
      return cachedBytes.subarray(ptr, ptr + len);
    },
    view(): DataView {
      refresh();
      if (cachedView === null) throw new Error("wasm memory unavailable");
      return cachedView;
    },
    alloc(size: number): number {
      const ptr = exports.ghostty_wasm_alloc(size);
      if (ptr === 0) throw new OutOfMemoryError(size);
      return ptr;
    },
    free(ptr: number, size: number): void {
      exports.ghostty_wasm_free(ptr, size);
    },
    copyOut(ptr: number, len: number): Uint8Array {
      // slice(), not subarray(): the caller keeps this past the next call into
      // Wasm, which is exactly when the backing buffer can go away.
      return this.u8(ptr, len).slice();
    },
    decodeUtf8(ptr: number, len: number): string {
      if (len === 0) return "";
      // TextDecoder copies into a fresh string, so decoding straight off the
      // live view is safe as long as nothing calls into Wasm in between.
      return utf8.decode(this.u8(ptr, len));
    },
  };
}
