/**
 * The official `key/encoder.h` + `key/event.h`, wrapped so a DOM event never
 * leaves this module and the app never builds a GhosttyKeyEvent by hand.
 *
 * The encoder is a pure function of (event, modes): it holds no socket, no
 * terminal handle, and no opinion about what the bytes are for. Modes come from
 * `VtTerminal.keyEncoderModes()` after each write batch, so DECCKM and the
 * kitty flags are read from the VT rather than guessed at.
 */

import type { BindingContext } from "./context";

export interface KeyEncoderModes {
  cursorKeyApplication: boolean; // DECCKM
  keypadApplication: boolean; // DECKPAM
  kittyFlags: number; // 0 = legacy encoding
  altSendsEscape: boolean;
  bracketedPaste: boolean;
}

export interface KeyEncoder {
  setModes(modes: KeyEncoderModes): void;
  /** PTY bytes for one key event. Empty (length 0) = send nothing. */
  encode(event: KeyboardEvent, phase: "down" | "up"): Uint8Array;
  /** Bracketed-paste wrapping when the mode is set, raw bytes otherwise. */
  encodePaste(text: string): Uint8Array;
  dispose(): void;
}

/** `GhosttyMods` bits, from key/event.h. Not in the manifest: they are #defines. */
const MODS_SHIFT = 1 << 0;
const MODS_CTRL = 1 << 1;
const MODS_ALT = 1 << 2;
const MODS_SUPER = 1 << 3;
const MODS_CAPS_LOCK = 1 << 4;
const MODS_NUM_LOCK = 1 << 5;
const MODS_SHIFT_SIDE = 1 << 6;
const MODS_CTRL_SIDE = 1 << 7;
const MODS_ALT_SIDE = 1 << 8;
const MODS_SUPER_SIDE = 1 << 9;

const ENCODE_BUFFER_BYTES = 128;
const EMPTY = new Uint8Array(0);
const utf8Encoder = new TextEncoder();

export function createKeyEncoder(context: BindingContext): KeyEncoder {
  return new WasmKeyEncoder(context);
}

class WasmKeyEncoder implements KeyEncoder {
  private readonly context: BindingContext;
  private encoder: number;
  private event: number;
  private outBuffer: number;
  private outCapacity: number;
  private readonly optionValue: number;
  private readonly optionValueSize: number;
  private readonly writtenSlot: number;
  private readonly writtenSlotSize: number;
  private modes: KeyEncoderModes = {
    cursorKeyApplication: false,
    keypadApplication: false,
    kittyFlags: 0,
    altSendsEscape: false,
    bracketedPaste: false,
  };
  private disposed = false;

  constructor(context: BindingContext) {
    this.context = context;
    const { exports, mem, abi } = context;
    this.encoder = context.createHandle("ghostty_key_encoder_new", (slot) =>
      exports.ghostty_key_encoder_new(0, slot),
    );
    let event = 0;
    try {
      event = context.createHandle("ghostty_key_event_new", (slot) =>
        exports.ghostty_key_event_new(0, slot),
      );
    } catch (error) {
      exports.ghostty_key_encoder_free(this.encoder);
      this.encoder = 0;
      throw error;
    }
    this.event = event;
    this.outCapacity = ENCODE_BUFFER_BYTES;
    this.outBuffer = mem.alloc(this.outCapacity);
    this.optionValueSize = abi.manifest.abi.maxAlignment;
    this.optionValue = mem.alloc(this.optionValueSize);
    this.writtenSlotSize = abi.manifest.abi.usizeSize;
    this.writtenSlot = mem.alloc(this.writtenSlotSize);
  }

  setModes(modes: KeyEncoderModes): void {
    this.assertUsable();
    this.modes = modes;
    const { exports, abi } = this.context;
    this.setBoolOption(
      abi.keyEncoderOption.cursorKeyApplication,
      modes.cursorKeyApplication,
    );
    this.setBoolOption(
      abi.keyEncoderOption.keypadKeyApplication,
      modes.keypadApplication,
    );
    this.setBoolOption(abi.keyEncoderOption.altEscPrefix, modes.altSendsEscape);
    // GhosttyKittyKeyFlags is a u8 bitmask, not a bool.
    this.context.writeU8(this.optionValue, modes.kittyFlags & 0xff);
    exports.ghostty_key_encoder_setopt(
      this.encoder,
      abi.keyEncoderOption.kittyFlags,
      this.optionValue,
    );
  }

  encode(event: KeyboardEvent, phase: "down" | "up"): Uint8Array {
    this.assertUsable();
    const { exports, abi, mem } = this.context;

    const action =
      phase === "up"
        ? abi.keyAction.release
        : event.repeat
          ? abi.keyAction.repeat
          : abi.keyAction.press;
    exports.ghostty_key_event_set_action(this.event, action);
    exports.ghostty_key_event_set_key(this.event, this.keyFor(event));
    const mods = modsFor(event);
    exports.ghostty_key_event_set_mods(this.event, mods);
    // Nothing in the browser tells us which modifiers a layout already consumed
    // to produce `event.key`, so none are reported as consumed.
    exports.ghostty_key_event_set_consumed_mods(this.event, 0);
    exports.ghostty_key_event_set_composing(this.event, event.isComposing ? 1 : 0);
    exports.ghostty_key_event_set_unshifted_codepoint(
      this.event,
      unshiftedCodepoint(event),
    );

    const text = printableText(event);
    let textPointer = 0;
    let textLength = 0;
    if (text !== null) {
      const bytes = utf8Encoder.encode(text);
      textLength = bytes.length;
      textPointer = mem.alloc(textLength);
      mem.u8(textPointer, textLength).set(bytes);
    }
    try {
      exports.ghostty_key_event_set_utf8(this.event, textPointer, textLength);
      return this.encodeCurrentEvent();
    } finally {
      // The event does not take ownership of the text, and it is not read
      // again after `encode` returns.
      exports.ghostty_key_event_set_utf8(this.event, 0, 0);
      if (textPointer !== 0) mem.free(textPointer, textLength);
    }
  }

  encodePaste(text: string): Uint8Array {
    this.assertUsable();
    const { exports, abi, mem } = this.context;
    const bytes = utf8Encoder.encode(text);
    // `ghostty_paste_encode` modifies the input in place (it replaces unsafe
    // control bytes), so the input has to live in Wasm memory, not in a view of
    // a JS buffer.
    const dataLength = bytes.length;
    const data = dataLength === 0 ? 0 : mem.alloc(dataLength);
    if (data !== 0) mem.u8(data, dataLength).set(bytes);
    try {
      for (let attempt = 0; attempt < 2; attempt += 1) {
        this.context.writeUsize(this.writtenSlot, 0);
        const code = exports.ghostty_paste_encode(
          data,
          dataLength,
          this.modes.bracketedPaste ? 1 : 0,
          this.outBuffer,
          this.outCapacity,
          this.writtenSlot,
        );
        const written = this.context.readUsize(this.writtenSlot);
        if (code === abi.result.success) {
          return written === 0 ? EMPTY : mem.copyOut(this.outBuffer, written);
        }
        if (code !== abi.result.outOfSpace) {
          this.context.check("ghostty_paste_encode", code);
          return EMPTY;
        }
        this.growOutBuffer(written);
      }
      return EMPTY;
    } finally {
      if (data !== 0) mem.free(data, dataLength);
    }
  }

  dispose(): void {
    // Idempotent on purpose: React 19 StrictMode double-invokes effects, and a
    // second free of the same handle is a corrupt allocator, not a warning.
    if (this.disposed) return;
    this.disposed = true;
    const { exports, mem } = this.context;
    exports.ghostty_key_event_free(this.event);
    exports.ghostty_key_encoder_free(this.encoder);
    mem.free(this.outBuffer, this.outCapacity);
    mem.free(this.optionValue, this.optionValueSize);
    mem.free(this.writtenSlot, this.writtenSlotSize);
    this.event = 0;
    this.encoder = 0;
    this.outBuffer = 0;
    this.outCapacity = 0;
  }

  private assertUsable(): void {
    if (this.disposed) throw new Error("key encoder is disposed");
  }

  private setBoolOption(option: number, value: boolean): void {
    const { exports } = this.context;
    this.context.writeU8(this.optionValue, value ? 1 : 0);
    exports.ghostty_key_encoder_setopt(this.encoder, option, this.optionValue);
  }

  private encodeCurrentEvent(): Uint8Array {
    const { exports, abi, mem } = this.context;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      this.context.writeUsize(this.writtenSlot, 0);
      const code = exports.ghostty_key_encoder_encode(
        this.encoder,
        this.event,
        this.outBuffer,
        this.outCapacity,
        this.writtenSlot,
      );
      const written = this.context.readUsize(this.writtenSlot);
      if (code === abi.result.success) {
        // Not every key produces output: unmodified modifier keys encode to
        // nothing, and that is a zero-length result, not an error.
        return written === 0 ? EMPTY : mem.copyOut(this.outBuffer, written);
      }
      if (code !== abi.result.outOfSpace) {
        this.context.check("ghostty_key_encoder_encode", code);
        return EMPTY;
      }
      this.growOutBuffer(written);
    }
    return EMPTY;
  }

  private growOutBuffer(required: number): void {
    const { mem } = this.context;
    mem.free(this.outBuffer, this.outCapacity);
    this.outCapacity = Math.max(required, this.outCapacity * 2);
    this.outBuffer = mem.alloc(this.outCapacity);
  }

  private keyFor(event: KeyboardEvent): number {
    const name = manifestKeyName(event.code);
    const keys = this.context.abi.keys;
    const value = name === null ? undefined : keys[name];
    if (value !== undefined) return value;
    const unidentified = keys["UNIDENTIFIED"];
    return unidentified ?? 0;
  }
}

/**
 * `KeyboardEvent.code` → the manifest's GhosttyKey name.
 *
 * The two vocabularies are the same physical-key list in different spellings:
 * `KeyA` / `Digit1` / `ArrowLeft` / `NumpadAdd` against `A` / `DIGIT_1` /
 * `ARROW_LEFT` / `NUMPAD_ADD`. Splitting camel humps and digit runs turns one
 * into the other for every key except the function row, where `F1` must not
 * become `F_1`. Anything left over resolves to UNIDENTIFIED, which the encoder
 * handles by falling back to the event's text.
 */
export function manifestKeyName(code: string): string | null {
  if (code.length === 0) return null;
  if (/^F\d{1,2}$/.test(code)) return code;
  const parts = code
    .replace(/([a-z])([A-Z])/g, "$1_$2")
    .replace(/([A-Za-z])(\d)/g, "$1_$2")
    .toUpperCase();
  // `KeyA` becomes `KEY_A`, but the manifest names it `A`: the C prefix
  // `GHOSTTY_KEY_` is already stripped out of every manifest name.
  return parts.startsWith("KEY_") ? parts.slice(4) : parts;
}

function modsFor(event: KeyboardEvent): number {
  let mods = 0;
  if (event.shiftKey) mods |= MODS_SHIFT;
  if (event.ctrlKey) mods |= MODS_CTRL;
  if (event.altKey) mods |= MODS_ALT;
  if (event.metaKey) mods |= MODS_SUPER;
  if (typeof event.getModifierState === "function") {
    if (event.getModifierState("CapsLock")) mods |= MODS_CAPS_LOCK;
    if (event.getModifierState("NumLock")) mods |= MODS_NUM_LOCK;
  }
  // The side bits are only meaningful for the modifier key events themselves,
  // where `code` says which one moved.
  if (event.code.endsWith("Right")) {
    if (event.code.startsWith("Shift")) mods |= MODS_SHIFT_SIDE;
    else if (event.code.startsWith("Control")) mods |= MODS_CTRL_SIDE;
    else if (event.code.startsWith("Alt")) mods |= MODS_ALT_SIDE;
    else if (event.code.startsWith("Meta")) mods |= MODS_SUPER_SIDE;
  }
  return mods;
}

/**
 * The text the key produced, or null when there is none to report.
 *
 * key/event.h is explicit about what must not be passed: C0 controls, DEL, and
 * the macOS private-use function-key range. Those cases pass NULL and let the
 * encoder work from the logical key, which is also what `Enter`, `ArrowUp`, and
 * every other named key do — their `event.key` is a word, not a character.
 */
export function printableText(event: KeyboardEvent): string | null {
  const key = event.key;
  if (typeof key !== "string" || key.length === 0) return null;
  const codepoint = key.codePointAt(0);
  if (codepoint === undefined) return null;
  // A named key is longer than the one grapheme it would otherwise be.
  if ([...key].length > 1) return null;
  if (codepoint < 0x20 || codepoint === 0x7f) return null;
  if (codepoint >= 0xf700 && codepoint <= 0xf8ff) return null;
  return key;
}

/**
 * The codepoint the key would produce with no modifiers, for the kitty
 * protocol's unshifted field.
 *
 * Derived from `code` for the keys where the physical position names the
 * character on any Latin layout, and from the lowercased `key` otherwise. A
 * non-Latin layout gets the second path, which is a known approximation: the
 * browser exposes no unshifted-character API, and inventing a layout table
 * would be worse than the approximation.
 */
export function unshiftedCodepoint(event: KeyboardEvent): number {
  const code = event.code;
  if (/^Key[A-Z]$/.test(code)) return code.charCodeAt(3) + 0x20;
  if (/^Digit\d$/.test(code)) return code.charCodeAt(5);
  const text = printableText(event);
  if (text === null) return 0;
  return text.toLowerCase().codePointAt(0) ?? 0;
}
