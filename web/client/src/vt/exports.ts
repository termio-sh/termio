/**
 * The `ghostty-vt.wasm` export surface this binding calls.
 *
 * Names and argument orders are the official C ABI at ghostty `56e1f3a` — the
 * commit `termiod/vt/Cargo.toml` pins through `termio-sh/libghostty-rs @
 * 04500f9`. `size_t`, pointers, and handles are all 32-bit numbers on wasm32;
 * `bool` crosses as 0/1; every `GhosttyResult` is an `i32`.
 *
 * Nothing here is optional and nothing is polyfilled: a Wasm missing one of
 * these is not a degraded mode, it is the wrong binary.
 */
export interface GhosttyExports {
  memory: WebAssembly.Memory;

  /** wasm.h helpers. Present only in the Wasm build, which is the only build here. */
  ghostty_wasm_alloc: (len: number) => number;
  ghostty_wasm_free: (ptr: number, len: number) => void;
  ghostty_wasm_alloc_opaque: () => number;
  ghostty_wasm_free_opaque: (slot: number) => void;
  ghostty_wasm_take_opaque: (slot: number) => number;

  /** NUL-terminated JSON. See typeJson.ts. */
  ghostty_type_json: () => number;

  ghostty_terminal_new: (
    allocator: number,
    outTerminal: number,
    cols: number,
    rows: number,
  ) => number;
  ghostty_terminal_free: (terminal: number) => void;
  ghostty_terminal_resize: (
    terminal: number,
    cols: number,
    rows: number,
    cellWidthPx: number,
    cellHeightPx: number,
  ) => number;
  ghostty_terminal_vt_write: (
    terminal: number,
    data: number,
    len: number,
  ) => void;
  ghostty_terminal_set: (
    terminal: number,
    option: number,
    value: number,
  ) => number;
  ghostty_terminal_get: (
    terminal: number,
    data: number,
    out: number,
  ) => number;

  ghostty_render_state_new: (allocator: number, outState: number) => number;
  ghostty_render_state_free: (state: number) => void;
  ghostty_render_state_begin_update: (
    state: number,
    terminal: number,
  ) => number;
  ghostty_render_state_end_update: (state: number) => number;
  ghostty_render_state_clean: (state: number) => number;
  ghostty_render_state_get: (
    state: number,
    data: number,
    out: number,
  ) => number;

  ghostty_render_state_row_iterator_new: (
    allocator: number,
    outIterator: number,
  ) => number;
  ghostty_render_state_row_iterator_free: (iterator: number) => void;
  ghostty_render_state_row_iterator_next: (iterator: number) => number;
  ghostty_render_state_row_get: (
    iterator: number,
    data: number,
    out: number,
  ) => number;

  ghostty_render_state_row_cells_new: (
    allocator: number,
    outCells: number,
  ) => number;
  ghostty_render_state_row_cells_free: (cells: number) => void;
  ghostty_render_state_row_cells_select: (cells: number, x: number) => number;
  ghostty_render_state_row_cells_get: (
    cells: number,
    data: number,
    out: number,
  ) => number;

  ghostty_key_encoder_new: (allocator: number, outEncoder: number) => number;
  ghostty_key_encoder_free: (encoder: number) => void;
  ghostty_key_encoder_setopt: (
    encoder: number,
    option: number,
    value: number,
  ) => void;
  ghostty_key_encoder_encode: (
    encoder: number,
    event: number,
    outBuf: number,
    outBufSize: number,
    outLen: number,
  ) => number;

  ghostty_key_event_new: (allocator: number, outEvent: number) => number;
  ghostty_key_event_free: (event: number) => void;
  ghostty_key_event_set_action: (event: number, action: number) => void;
  ghostty_key_event_set_key: (event: number, key: number) => void;
  ghostty_key_event_set_mods: (event: number, mods: number) => void;
  ghostty_key_event_set_consumed_mods: (event: number, mods: number) => void;
  ghostty_key_event_set_composing: (event: number, composing: number) => void;
  ghostty_key_event_set_utf8: (
    event: number,
    utf8: number,
    len: number,
  ) => void;
  ghostty_key_event_set_unshifted_codepoint: (
    event: number,
    codepoint: number,
  ) => void;

  ghostty_paste_encode: (
    data: number,
    dataLen: number,
    bracketed: number,
    buf: number,
    bufLen: number,
    outWritten: number,
  ) => number;
}

/** `GhosttyResult`, from types.h. Read by name out of the manifest at runtime. */
export const RESULT_SUCCESS = 0;

export class GhosttyError extends Error {
  readonly code: number;
  constructor(operation: string, code: number, codeName: string) {
    super(`${operation} failed: ${codeName} (${code})`);
    this.name = "GhosttyError";
    this.code = code;
  }
}
