/**
 * The per-instance plumbing shared by the terminal and the key encoder: the
 * exports, the memory discipline, the resolved manifest, and the small typed
 * reads. Every read here refetches the memory view first, which is the whole
 * point of routing them through one place.
 */

import { resolveAbi, type ResolvedAbi } from "./abi";
import { GhosttyError, type GhosttyExports } from "./exports";
import { createMem, type Mem } from "./memory";
import { TypeManifest } from "./typeJson";

export interface BindingContext {
  readonly exports: GhosttyExports;
  readonly mem: Mem;
  readonly abi: ResolvedAbi;

  /** Throws on any result other than SUCCESS. */
  check(operation: string, code: number): void;
  /** True on SUCCESS, false on NO_VALUE, throws on anything else. */
  hasValue(operation: string, code: number): boolean;

  /**
   * Run a constructor that writes its handle into an out-parameter slot.
   * `wasm.h`'s opaque-slot dance, in one place instead of at five call sites.
   */
  createHandle(operation: string, create: (slot: number) => number): number;

  readU8(ptr: number): number;
  readU16(ptr: number): number;
  readU32(ptr: number): number;
  readI32(ptr: number): number;
  readBool(ptr: number): boolean;
  writeU8(ptr: number, value: number): void;
  writeU16(ptr: number, value: number): void;
  writeU32(ptr: number, value: number): void;
  /** `size_t` is 4 bytes here; the manifest assertion at load guarantees it. */
  writeUsize(ptr: number, value: number): void;
  readUsize(ptr: number): number;
  /** Reads a NUL-terminated C string. Only used for `ghostty_type_json`. */
  readCString(ptr: number): string;
}

export function createContext(exports: GhosttyExports): BindingContext {
  const mem = createMem(exports);

  const jsonPointer = exports.ghostty_type_json();
  if (jsonPointer === 0) {
    throw new Error("ghostty_type_json returned NULL");
  }
  const manifest = TypeManifest.parse(readCString(mem, jsonPointer));
  const abi = resolveAbi(manifest);

  function describe(code: number): string {
    return abi.result.names.get(code) ?? "UNKNOWN";
  }

  return {
    exports,
    mem,
    abi,
    check(operation: string, code: number): void {
      if (code !== abi.result.success) {
        throw new GhosttyError(operation, code, describe(code));
      }
    },
    hasValue(operation: string, code: number): boolean {
      if (code === abi.result.success) return true;
      if (code === abi.result.noValue) return false;
      throw new GhosttyError(operation, code, describe(code));
    },
    createHandle(operation: string, create: (slot: number) => number): number {
      const slot = mem.alloc(abi.manifest.abi.pointerSize);
      try {
        const code = create(slot);
        if (code !== abi.result.success) {
          throw new GhosttyError(operation, code, describe(code));
        }
        const handle = exports.ghostty_wasm_take_opaque(slot);
        if (handle === 0) {
          throw new Error(`${operation} reported success but produced no handle`);
        }
        return handle;
      } finally {
        mem.free(slot, abi.manifest.abi.pointerSize);
      }
    },
    readU8(ptr: number): number {
      return mem.view().getUint8(ptr);
    },
    readU16(ptr: number): number {
      return mem.view().getUint16(ptr, true);
    },
    readU32(ptr: number): number {
      return mem.view().getUint32(ptr, true);
    },
    readI32(ptr: number): number {
      return mem.view().getInt32(ptr, true);
    },
    readBool(ptr: number): boolean {
      return mem.view().getUint8(ptr) !== 0;
    },
    writeU8(ptr: number, value: number): void {
      mem.view().setUint8(ptr, value);
    },
    writeU16(ptr: number, value: number): void {
      mem.view().setUint16(ptr, value, true);
    },
    writeU32(ptr: number, value: number): void {
      mem.view().setUint32(ptr, value, true);
    },
    writeUsize(ptr: number, value: number): void {
      mem.view().setUint32(ptr, value, true);
    },
    readUsize(ptr: number): number {
      return mem.view().getUint32(ptr, true);
    },
    readCString(ptr: number): string {
      return readCString(mem, ptr);
    },
  };
}

function readCString(mem: Mem, ptr: number): string {
  // The manifest is the only C string this binding reads, and its length is
  // not reported anywhere, so the terminator has to be found by scanning. The
  // scan runs over a live view and calls nothing in between, so the view
  // cannot go stale underneath it.
  const view = mem.view();
  const total = view.byteLength;
  let end = ptr;
  while (end < total && view.getUint8(end) !== 0) end += 1;
  return mem.decodeUtf8(ptr, end - ptr);
}
