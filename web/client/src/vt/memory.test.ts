import { describe, expect, it } from "vitest";

import { createMem, OutOfMemoryError, type WasmMemoryExports } from "./memory";

function exportsFor(memory: { buffer: ArrayBuffer }): WasmMemoryExports {
  return {
    memory: memory as WebAssembly.Memory,
    ghostty_wasm_alloc: () => 0,
    ghostty_wasm_free: () => {},
  };
}

describe("Mem", () => {
  it("rebuilds its view when growth replaces the buffer", () => {
    // The classic detach: WebAssembly.Memory.grow() hands back a new
    // ArrayBuffer and every view made before it reads zeroes forever.
    const memory = new WebAssembly.Memory({ initial: 1 });
    const mem = createMem(exportsFor(memory));

    mem.u8(0, 4).set([1, 2, 3, 4]);
    const before = mem.u8(0, 4).slice();
    expect([...before]).toEqual([1, 2, 3, 4]);

    memory.grow(1);

    // A binding that cached the view would read zeroes here.
    expect([...mem.u8(0, 4)]).toEqual([1, 2, 3, 4]);
    // And the view has to cover the new memory, not the old length.
    const end = memory.buffer.byteLength - 4;
    mem.u8(end, 4).set([9, 9, 9, 9]);
    expect([...mem.u8(end, 4)]).toEqual([9, 9, 9, 9]);
  });

  it("rebuilds its view when the buffer keeps its identity and grows", () => {
    // The case identity alone misses: a resizable ArrayBuffer grows in place,
    // so `buffer === cachedBuffer` stays true while byteLength moves. Without
    // the length half of the check, every read past the old end throws.
    // Resizable ArrayBuffers are ES2024 and the project's `lib` is ES2022, so
    // the constructor is reached through a cast rather than by widening the lib
    // for one test.
    const ResizableArrayBuffer = ArrayBuffer as unknown as {
      new (
        byteLength: number,
        options: { maxByteLength: number },
      ): ArrayBuffer & { resize(byteLength: number): void };
    };
    const buffer = new ResizableArrayBuffer(16, { maxByteLength: 64 });
    const memory = { buffer };
    const mem = createMem(exportsFor(memory));

    expect(mem.u8(0, 16).length).toBe(16);
    const identityBefore = mem.view().buffer;

    buffer.resize(64);
    expect(memory.buffer).toBe(identityBefore);

    expect(() => mem.u8(48, 16)).not.toThrow();
    expect(mem.view().byteLength).toBe(64);
  });

  it("copies out of linear memory so the result survives the next call", () => {
    const memory = new WebAssembly.Memory({ initial: 1 });
    const mem = createMem(exportsFor(memory));
    mem.u8(8, 3).set([7, 8, 9]);

    const copy = mem.copyOut(8, 3);
    memory.grow(1);

    expect([...copy]).toEqual([7, 8, 9]);
  });

  it("refuses a read that runs past the end of memory", () => {
    const memory = new WebAssembly.Memory({ initial: 1 });
    const mem = createMem(exportsFor(memory));
    expect(() => mem.u8(memory.buffer.byteLength - 2, 8)).toThrow(RangeError);
  });

  it("turns a NULL allocation into an error instead of a pointer at zero", () => {
    const memory = new WebAssembly.Memory({ initial: 1 });
    const mem = createMem({
      memory,
      ghostty_wasm_alloc: () => 0,
      ghostty_wasm_free: () => {},
    });
    expect(() => mem.alloc(32)).toThrow(OutOfMemoryError);
  });
});
