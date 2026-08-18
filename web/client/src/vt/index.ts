/**
 * The VT binding: official `ghostty-vt.wasm`, wrapped thinly.
 *
 * This module has no DOM beyond `KeyboardEvent`, no socket, and no React
 * import, which is what keeps it headless-testable — the one ghostty-web lesson
 * that survives. Nothing above it learns which ghostty symbols exist.
 */

import { createContext, type BindingContext } from "./context";
import type { GhosttyExports } from "./exports";
import { createKeyEncoder, type KeyEncoder } from "./keyEncoder";
import { createTerminal, type TerminalOptions, type VtTerminal } from "./terminal";

export type { KeyEncoder, KeyEncoderModes } from "./keyEncoder";
export type { TerminalOptions, VtTerminal } from "./terminal";
export type { Mem } from "./memory";
export { GhosttyError } from "./exports";
export { ManifestError, TypeManifest } from "./typeJson";

/** The empty-state sentence the page shows, verbatim. */
const USER_MESSAGE =
  "Couldn't load the terminal engine. Check that `ghostty-vt.wasm` is served as `application/wasm`.";

export class VtLoadError extends Error {
  readonly userMessage: string;

  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "VtLoadError";
    this.userMessage = USER_MESSAGE;
  }
}

export interface VtBinding {
  createTerminal(options: TerminalOptions): VtTerminal;
  createKeyEncoder(): KeyEncoder;
  dispose(): void;
  /** ghostty's own version string from the manifest. Diagnostics only. */
  readonly libraryVersion: string;
  /** The ghostty commit the Wasm was built from, when the build recorded one. */
  readonly commit: string | null;
}

/** Every export this binding calls. A Wasm missing one is the wrong binary. */
const REQUIRED_EXPORTS: readonly (keyof GhosttyExports)[] = [
  "memory",
  "ghostty_wasm_alloc",
  "ghostty_wasm_free",
  "ghostty_wasm_alloc_opaque",
  "ghostty_wasm_free_opaque",
  "ghostty_wasm_take_opaque",
  "ghostty_type_json",
  "ghostty_terminal_new",
  "ghostty_terminal_free",
  "ghostty_terminal_resize",
  "ghostty_terminal_vt_write",
  "ghostty_terminal_set",
  "ghostty_terminal_get",
  "ghostty_render_state_new",
  "ghostty_render_state_free",
  "ghostty_render_state_begin_update",
  "ghostty_render_state_end_update",
  "ghostty_render_state_clean",
  "ghostty_render_state_get",
  "ghostty_render_state_row_iterator_new",
  "ghostty_render_state_row_iterator_free",
  "ghostty_render_state_row_iterator_next",
  "ghostty_render_state_row_get",
  "ghostty_render_state_row_cells_new",
  "ghostty_render_state_row_cells_free",
  "ghostty_render_state_row_cells_select",
  "ghostty_render_state_row_cells_get",
  "ghostty_key_encoder_new",
  "ghostty_key_encoder_free",
  "ghostty_key_encoder_setopt",
  "ghostty_key_encoder_encode",
  "ghostty_key_event_new",
  "ghostty_key_event_free",
  "ghostty_key_event_set_action",
  "ghostty_key_event_set_key",
  "ghostty_key_event_set_mods",
  "ghostty_key_event_set_consumed_mods",
  "ghostty_key_event_set_composing",
  "ghostty_key_event_set_utf8",
  "ghostty_key_event_set_unshifted_codepoint",
  "ghostty_paste_encode",
];

/**
 * Instantiate once per page.
 *
 * Uses `WebAssembly.instantiateStreaming` and does NOT fall back to
 * `arrayBuffer()`. A wrong MIME type has to fail loudly here, because the
 * alternative is a silent 400 KB re-download and a deploy bug that never
 * surfaces — the GET jail serves `.wasm` as `application/wasm`, and if it did
 * not, we want to hear about it on the first load rather than never.
 */
export async function instantiate(options: { url: URL }): Promise<VtBinding> {
  let instance: WebAssembly.Instance;
  try {
    const result = await WebAssembly.instantiateStreaming(
      fetch(options.url, { credentials: "same-origin" }),
      wasmImports(),
    );
    instance = result.instance;
  } catch (error) {
    throw new VtLoadError(
      `could not instantiate ${options.url.href}: ${String(error)}`,
      { cause: error },
    );
  }
  return bindingFromExports(instance.exports as unknown as GhosttyExports);
}

/**
 * The same binding over an already-instantiated module.
 *
 * `instantiate` is a thin fetch in front of this. Splitting them is what lets
 * the tests drive the whole ABI — memory growth, the manifest, the render-state
 * bracket — without a browser and without shipping a copy of the Wasm into the
 * test runner.
 */
export function bindingFromExports(exports: GhosttyExports): VtBinding {
  for (const name of REQUIRED_EXPORTS) {
    if (exports[name] === undefined) {
      throw new VtLoadError(`ghostty-vt.wasm is missing the export ${name}`);
    }
  }

  let context: BindingContext;
  try {
    context = createContext(exports);
  } catch (error) {
    throw new VtLoadError(
      `ghostty-vt.wasm ABI is not the one this client was built against: ${String(error)}`,
      { cause: error },
    );
  }

  const terminals = new Set<VtTerminal>();
  const encoders = new Set<KeyEncoder>();
  let disposed = false;

  return {
    libraryVersion: context.abi.manifest.libraryVersion,
    commit: context.abi.manifest.commit,
    createTerminal(options: TerminalOptions): VtTerminal {
      if (disposed) throw new Error("binding is disposed");
      const terminal = createTerminal(context, options);
      terminals.add(terminal);
      return wrapDisposable(terminal, () => terminals.delete(terminal));
    },
    createKeyEncoder(): KeyEncoder {
      if (disposed) throw new Error("binding is disposed");
      const encoder = createKeyEncoder(context);
      encoders.add(encoder);
      return wrapDisposable(encoder, () => encoders.delete(encoder));
    },
    dispose(): void {
      if (disposed) return;
      disposed = true;
      // The Wasm instance itself is garbage; what leaks without this is every
      // terminal and encoder the page forgot to dispose.
      for (const terminal of [...terminals]) terminal.dispose();
      for (const encoder of [...encoders]) encoder.dispose();
      terminals.clear();
      encoders.clear();
    },
  };
}

function wrapDisposable<T extends { dispose(): void }>(
  value: T,
  onDispose: () => void,
): T {
  const original = value.dispose.bind(value);
  value.dispose = () => {
    original();
    onDispose();
  };
  return value;
}

/**
 * Release builds of `ghostty-vt.wasm` compile logging out entirely and import
 * nothing; a debug build imports `env.log`. Supplying the no-op costs nothing
 * and keeps a debug binary from failing to instantiate.
 */
function wasmImports(): WebAssembly.Imports {
  return { env: { log: () => {} } };
}
