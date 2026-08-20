import { ProtocolError } from "./errors";

/**
 * A colour SLOT, as the program asked for it — never as anyone resolved it.
 * One-for-one with `WireColor` in protocol.rs and with
 * GHOSTTY_STYLE_COLOR_{NONE,PALETTE,RGB} in style.h. The only code allowed to
 * turn one of these into pixels is a TerminalRenderer holding the viewer's
 * Palette.
 *
 * Wire form is 4 bytes: tag, then value, zero-padded.
 *   0 default (no value) · 1 palette (index in byte 1) · 2 rgb (bytes 1..3)
 * An unknown tag decodes to `{ tag: "default" }` and never fails the frame —
 * matching WireColor::decode, which is deliberate: the tag space grows, and a
 * cell falling back to the viewer's default beats dropping a screen.
 */
export type TaggedColor =
  | { tag: "default" }
  | { tag: "palette"; index: number } // 0–255, UNRESOLVED
  | { tag: "rgb"; r: number; g: number; b: number };

export const COLOR_TAG_DEFAULT = 0;
export const COLOR_TAG_PALETTE = 1;
export const COLOR_TAG_RGB = 2;

/** Frozen singleton so a screenful of untouched cells shares one object. */
export const DEFAULT_COLOR: TaggedColor = Object.freeze({
  tag: "default",
} as const);

export function decodeColor(bytes: Uint8Array, offset: number): TaggedColor {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw new ProtocolError(
      `colour at offset ${offset} runs past ${bytes.length} bytes`,
    );
  }
  switch (bytes[offset]) {
    case COLOR_TAG_PALETTE:
      return { tag: "palette", index: bytes[offset + 1] };
    case COLOR_TAG_RGB:
      return {
        tag: "rgb",
        r: bytes[offset + 1],
        g: bytes[offset + 2],
        b: bytes[offset + 3],
      };
    default:
      return DEFAULT_COLOR;
  }
}
