import { describe, expect, it } from "vitest";

import { createFakeGhostty } from "./__fixtures__/fakeGhostty";
import { ENUMS } from "./__fixtures__/layout";
import { bindingFromExports } from "./index";
import {
  manifestKeyName,
  printableText,
  unshiftedCodepoint,
  type KeyEncoder,
} from "./keyEncoder";

const decoder = new TextDecoder();

interface FakeKeyboardEvent {
  code: string;
  key: string;
  shiftKey?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
  metaKey?: boolean;
  repeat?: boolean;
  isComposing?: boolean;
}

/**
 * A KeyboardEvent-shaped literal. The binding only reads `code`, `key`, the
 * modifier flags, `repeat`, `isComposing`, and `getModifierState`, so the tests
 * stay in the node realm rather than dragging in jsdom for a property bag.
 */
function keyEvent(event: FakeKeyboardEvent): KeyboardEvent {
  return {
    code: event.code,
    key: event.key,
    shiftKey: event.shiftKey ?? false,
    ctrlKey: event.ctrlKey ?? false,
    altKey: event.altKey ?? false,
    metaKey: event.metaKey ?? false,
    repeat: event.repeat ?? false,
    isComposing: event.isComposing ?? false,
    getModifierState: () => false,
  } as unknown as KeyboardEvent;
}

function withEncoder<T>(run: (encoder: KeyEncoder) => T): T {
  const fake = createFakeGhostty();
  const binding = bindingFromExports(fake.exports);
  const encoder = binding.createKeyEncoder();
  try {
    return run(encoder);
  } finally {
    binding.dispose();
    expect(fake.liveAllocations()).toBe(0);
  }
}

function text(bytes: Uint8Array): string {
  return decoder.decode(bytes);
}

describe("manifestKeyName", () => {
  it("translates DOM codes into the manifest's key names", () => {
    expect(manifestKeyName("KeyA")).toBe("A");
    expect(manifestKeyName("Digit1")).toBe("DIGIT_1");
    expect(manifestKeyName("ArrowLeft")).toBe("ARROW_LEFT");
    expect(manifestKeyName("NumpadAdd")).toBe("NUMPAD_ADD");
    expect(manifestKeyName("Numpad7")).toBe("NUMPAD_7");
    expect(manifestKeyName("ControlLeft")).toBe("CONTROL_LEFT");
    expect(manifestKeyName("BracketRight")).toBe("BRACKET_RIGHT");
    expect(manifestKeyName("IntlBackslash")).toBe("INTL_BACKSLASH");
    expect(manifestKeyName("Escape")).toBe("ESCAPE");
  });

  it("leaves the function row alone rather than splitting F1 into F_1", () => {
    expect(manifestKeyName("F1")).toBe("F1");
    expect(manifestKeyName("F12")).toBe("F12");
  });
});

describe("printableText", () => {
  it("reports the character a key produced", () => {
    expect(printableText(keyEvent({ code: "KeyA", key: "a" }))).toBe("a");
    expect(printableText(keyEvent({ code: "Digit1", key: "!" }))).toBe("!");
  });

  it("reports nothing for named keys, controls, and macOS function codes", () => {
    // key/event.h forbids C0, DEL, and the U+F700–U+F8FF private-use range.
    expect(printableText(keyEvent({ code: "Enter", key: "Enter" }))).toBeNull();
    expect(printableText(keyEvent({ code: "KeyC", key: "" }))).toBeNull();
    expect(printableText(keyEvent({ code: "F1", key: "" }))).toBeNull();
  });
});

describe("unshiftedCodepoint", () => {
  it("derives the unshifted character from the physical key", () => {
    expect(unshiftedCodepoint(keyEvent({ code: "KeyA", key: "A", shiftKey: true }))).toBe(
      "a".codePointAt(0),
    );
    expect(unshiftedCodepoint(keyEvent({ code: "Digit1", key: "!", shiftKey: true }))).toBe(
      "1".codePointAt(0),
    );
    expect(unshiftedCodepoint(keyEvent({ code: "Enter", key: "Enter" }))).toBe(0);
  });
});

describe("KeyEncoder", () => {
  it("encodes a plain key press to its bytes", () => {
    withEncoder((encoder) => {
      expect(text(encoder.encode(keyEvent({ code: "KeyA", key: "a" }), "down"))).toBe("a");
      expect(text(encoder.encode(keyEvent({ code: "Enter", key: "Enter" }), "down"))).toBe(
        "\r",
      );
    });
  });

  it("encodes control keys from the modifier bits, not from the text", () => {
    withEncoder((encoder) => {
      const bytes = encoder.encode(
        keyEvent({ code: "KeyC", key: "c", ctrlKey: true }),
        "down",
      );
      expect([...bytes]).toEqual([0x03]);
    });
  });

  it("sends nothing for a key release under the legacy encoding", () => {
    withEncoder((encoder) => {
      expect(encoder.encode(keyEvent({ code: "KeyA", key: "a" }), "up").length).toBe(0);
    });
  });

  it("follows DECCKM when the terminal changes it", () => {
    withEncoder((encoder) => {
      const event = keyEvent({ code: "ArrowUp", key: "ArrowUp" });
      expect(text(encoder.encode(event, "down"))).toBe("\x1b[A");

      encoder.setModes({
        cursorKeyApplication: true,
        keypadApplication: false,
        kittyFlags: 0,
        altSendsEscape: false,
        bracketedPaste: false,
      });
      expect(text(encoder.encode(event, "down"))).toBe("\x1bOA");
    });
  });

  it("prefixes alt with ESC only when the mode says so", () => {
    withEncoder((encoder) => {
      const event = keyEvent({ code: "KeyB", key: "b", altKey: true });
      expect(text(encoder.encode(event, "down"))).toBe("b");

      encoder.setModes({
        cursorKeyApplication: false,
        keypadApplication: false,
        kittyFlags: 0,
        altSendsEscape: true,
        bracketedPaste: false,
      });
      expect(text(encoder.encode(event, "down"))).toBe("\x1bb");
    });
  });

  it("passes an unknown code through as UNIDENTIFIED and falls back to the text", () => {
    withEncoder((encoder) => {
      expect(
        text(encoder.encode(keyEvent({ code: "MediaSelect", key: "x" }), "down")),
      ).toBe("x");
    });
  });

  it("wraps a paste only when bracketed paste is on", () => {
    withEncoder((encoder) => {
      expect(text(encoder.encodePaste("ls\n"))).toBe("ls\r");

      encoder.setModes({
        cursorKeyApplication: false,
        keypadApplication: false,
        kittyFlags: 0,
        altSendsEscape: false,
        bracketedPaste: true,
      });
      expect(text(encoder.encodePaste("ls\n"))).toBe("\x1b[200~ls\n\x1b[201~");
    });
  });

  it("grows its buffer instead of truncating a long paste", () => {
    withEncoder((encoder) => {
      const long = "x".repeat(4096);
      expect(text(encoder.encodePaste(long))).toBe(long);
    });
  });

  it("is idempotent on dispose", () => {
    const fake = createFakeGhostty();
    const binding = bindingFromExports(fake.exports);
    const encoder = binding.createKeyEncoder();
    encoder.dispose();
    expect(() => encoder.dispose()).not.toThrow();
    expect(() => encoder.encode(keyEvent({ code: "KeyA", key: "a" }), "down")).toThrow(
      /disposed/,
    );
    binding.dispose();
    expect(fake.liveAllocations()).toBe(0);
  });

  it("hands the encoder the modes the terminal reports", () => {
    const fake = createFakeGhostty();
    const binding = bindingFromExports(fake.exports);
    const terminal = binding.createTerminal({
      rows: 2,
      cols: 4,
      scrollbackBytes: 1024,
    });
    const encoder = binding.createKeyEncoder();
    terminal.write(new TextEncoder().encode("\x1b[?1h"));
    encoder.setModes(terminal.keyEncoderModes());

    const handles = fake.terminals();
    expect(handles.length).toBe(1);
    expect(text(encoder.encode(keyEvent({ code: "ArrowLeft", key: "ArrowLeft" }), "down"))).toBe(
      "\x1bOD",
    );
    expect(ENUMS.GhosttyKey.ARROW_LEFT).toBe(76);
    binding.dispose();
  });
});
