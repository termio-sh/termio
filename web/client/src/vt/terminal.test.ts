import { describe, expect, it } from "vitest";

import { ATTR, type CellView, type RenderFrame } from "../renderer/types";
import { createFakeGhostty, type FakeGhostty } from "./__fixtures__/fakeGhostty";
import { ENUMS } from "./__fixtures__/layout";
import { bindingFromExports, type VtBinding } from "./index";
import type { VtTerminal } from "./terminal";

const encoder = new TextEncoder();

interface Harness {
  fake: FakeGhostty;
  binding: VtBinding;
  terminal: VtTerminal;
}

function harness(
  options: {
    padding?: number;
    rows?: number;
    cols?: number;
    growOnAlloc?: boolean;
  } = {},
): Harness {
  const fakeOptions: { padding?: number; growOnAlloc?: boolean } = {};
  if (options.padding !== undefined) fakeOptions.padding = options.padding;
  if (options.growOnAlloc !== undefined) fakeOptions.growOnAlloc = options.growOnAlloc;
  const fake = createFakeGhostty(fakeOptions);
  const binding = bindingFromExports(fake.exports);
  const terminal = binding.createTerminal({
    rows: options.rows ?? 4,
    cols: options.cols ?? 8,
    scrollbackBytes: 1024 * 1024,
  });
  return { fake, binding, terminal };
}

function write(terminal: VtTerminal, text: string): void {
  terminal.write(encoder.encode(text));
}

/** The rows the renderer would repaint, as plain text. */
function textOf(frame: RenderFrame, y: number): string {
  const row = frame.rows_[y];
  if (row === undefined) return "";
  return row.cells
    .map((cell) => (cell.codepoint === 0 ? " " : String.fromCodePoint(cell.codepoint)))
    .join("")
    .trimEnd();
}

function cellAt(frame: RenderFrame, y: number, x: number): CellView {
  const cell = frame.rows_[y]?.cells[x];
  if (cell === undefined) throw new Error(`no cell at ${x},${y}`);
  return cell;
}

describe("VtTerminal.readFrame", () => {
  it("turns written bytes into painted rows", () => {
    const { terminal, binding } = harness();
    write(terminal, "hi\r\nthere");

    terminal.readFrame((frame) => {
      expect(frame.rows).toBe(4);
      expect(frame.cols).toBe(8);
      expect(textOf(frame, 0)).toBe("hi");
      expect(textOf(frame, 1)).toBe("there");
      expect(frame.cursor.hasValue).toBe(true);
      expect(frame.cursor.style).toBe("block");
    });
    binding.dispose();
  });

  it("reports colour as an unresolved slot, never as pixels", () => {
    const { terminal, binding } = harness();
    // 31 is a theme slot, 38;2 is the program's own literal colour, and an
    // unstyled cell names no colour at all. The renderer resolves the first,
    // must not reinterpret the second, and paints the viewer's default for the
    // third. This is the whole presentation boundary in one assertion.
    write(terminal, "a\x1b[31mb\x1b[38;2;9;8;7mc\x1b[m");

    terminal.readFrame((frame) => {
      expect(cellAt(frame, 0, 0).foreground).toEqual({ tag: "default" });
      expect(cellAt(frame, 0, 1).foreground).toEqual({ tag: "palette", index: 1 });
      expect(cellAt(frame, 0, 2).foreground).toEqual({
        tag: "rgb",
        r: 9,
        g: 8,
        b: 7,
      });
    });
    binding.dispose();
  });

  it("keeps palette 0 distinct from no colour at all", () => {
    const { terminal, binding } = harness();
    write(terminal, "\x1b[30ma\x1b[mb");
    terminal.readFrame((frame) => {
      expect(cellAt(frame, 0, 0).foreground).toEqual({ tag: "palette", index: 0 });
      expect(cellAt(frame, 0, 1).foreground).toEqual({ tag: "default" });
    });
    binding.dispose();
  });

  it("applies inverse by swapping slots, the way the host does", () => {
    const { terminal, binding } = harness();
    write(terminal, "\x1b[31;7ma");
    terminal.readFrame((frame) => {
      const cell = cellAt(frame, 0, 0);
      expect(cell.background).toEqual({ tag: "palette", index: 1 });
      expect(cell.foreground).toEqual({ tag: "default" });
    });
    binding.dispose();
  });

  it("blanks an invisible cell instead of leaving the renderer to guess", () => {
    const { terminal, binding } = harness();
    write(terminal, "\x1b[8ma");
    terminal.readFrame((frame) => {
      expect(cellAt(frame, 0, 0).codepoint).toBe(0);
    });
    binding.dispose();
  });

  it("maps SGR decorations onto the seam's attribute bits", () => {
    const { terminal, binding } = harness();
    write(terminal, "\x1b[1;3;4;9ma");
    terminal.readFrame((frame) => {
      const cell = cellAt(frame, 0, 0);
      expect(cell.attributes & ATTR.BOLD).toBeTruthy();
      expect(cell.attributes & ATTR.ITALIC).toBeTruthy();
      expect(cell.attributes & ATTR.UNDERLINE).toBeTruthy();
      expect(cell.attributes & ATTR.STRIKETHROUGH).toBeTruthy();
      expect(cell.attributes & ATTR.UNDERCURL).toBeFalsy();
    });
    binding.dispose();
  });

  it("carries the program's underline colour as its own slot", () => {
    const { terminal, binding } = harness();
    write(terminal, "\x1b[4;58;5;42ma");
    terminal.readFrame((frame) => {
      expect(cellAt(frame, 0, 0).underline).toEqual({ tag: "palette", index: 42 });
    });
    binding.dispose();
  });

  it("reads a background-only cell out of the cell's own content tag", () => {
    const { fake, terminal, binding } = harness();
    const model = fake.terminals()[0];
    if (model === undefined) throw new Error("no fake terminal");
    fake.poke(model, 0, 0, {
      contentTag: ENUMS.GhosttyCellContentTag.BG_COLOR_PALETTE,
      palette: 200,
    });
    fake.poke(model, 0, 1, {
      contentTag: ENUMS.GhosttyCellContentTag.BG_COLOR_RGB,
      rgb: { r: 1, g: 2, b: 3 },
    });

    terminal.readFrame((frame) => {
      expect(cellAt(frame, 0, 0).background).toEqual({ tag: "palette", index: 200 });
      expect(cellAt(frame, 0, 1).background).toEqual({ tag: "rgb", r: 1, g: 2, b: 3 });
    });
    binding.dispose();
  });

  it("flags wide cells and their spacers", () => {
    const { fake, terminal, binding } = harness();
    const model = fake.terminals()[0];
    if (model === undefined) throw new Error("no fake terminal");
    fake.poke(model, 0, 0, { codepoint: 0x4e00, wide: ENUMS.GhosttyCellWide.WIDE });
    fake.poke(model, 0, 1, { wide: ENUMS.GhosttyCellWide.SPACER_TAIL });

    terminal.readFrame((frame) => {
      expect(cellAt(frame, 0, 0).attributes & ATTR.WIDE).toBeTruthy();
      expect(cellAt(frame, 0, 1).attributes & ATTR.WIDE_SPACER).toBeTruthy();
    });
    binding.dispose();
  });

  it("reads a grapheme cluster, growing the buffer when the cluster is long", () => {
    const { fake, terminal, binding } = harness();
    const model = fake.terminals()[0];
    if (model === undefined) throw new Error("no fake terminal");
    const long = `e${"́".repeat(80)}`; // far past the 64-byte starting buffer
    fake.poke(model, 0, 0, {
      contentTag: ENUMS.GhosttyCellContentTag.CODEPOINT_GRAPHEME,
      codepoint: 0x65,
      grapheme: long,
    });

    terminal.readFrame((frame) => {
      expect(cellAt(frame, 0, 0).grapheme).toBe(long);
    });
    binding.dispose();
  });

  it("reports the row-local selection as a half-open range and per-cell flags", () => {
    const { fake, terminal, binding } = harness();
    const model = fake.terminals()[0];
    if (model === undefined) throw new Error("no fake terminal");
    write(terminal, "abcdef");
    model.selection = { row: 0, start: 1, end: 3 };

    terminal.readFrame((frame) => {
      // render.h reports an inclusive end column; the seam wants half-open.
      expect(frame.rows_[0]?.selection).toEqual({ start: 1, end: 4 });
      expect(cellAt(frame, 0, 0).selected).toBe(false);
      expect(cellAt(frame, 0, 1).selected).toBe(true);
      expect(cellAt(frame, 0, 3).selected).toBe(true);
      expect(cellAt(frame, 0, 4).selected).toBe(false);
    });
    binding.dispose();
  });

  it("reports damage instead of making the renderer derive it", () => {
    const { terminal, binding } = harness();
    write(terminal, "first");
    terminal.readFrame((frame) => {
      expect(frame.dirty).toBe("full");
    });

    terminal.readFrame((frame) => {
      expect(frame.dirty).toBe("none");
    });

    write(terminal, "\x1b[2;1Hsecond");
    terminal.readFrame((frame) => {
      expect(frame.dirty).toBe("partial");
      expect(frame.rows_[0]?.dirty).toBe(false);
      expect(frame.rows_[1]?.dirty).toBe(true);
    });
    binding.dispose();
  });

  it("surfaces only the colours the program set", () => {
    const { terminal, binding } = harness();
    terminal.readFrame((frame) => {
      // Nothing set: the viewer's Palette decides, so there is no override to
      // report — and specifically not the engine's own default colours.
      expect(frame.overrides).toEqual({});
    });

    write(terminal, "\x1b]11;#102030\x07");
    terminal.readFrame((frame) => {
      expect(frame.overrides.background).toEqual({ r: 0x10, g: 0x20, b: 0x30 });
      expect(frame.overrides.foreground).toBeUndefined();
    });
    binding.dispose();
  });

  it("survives a write that grows linear memory mid-frame", () => {
    const { fake, terminal, binding } = harness();
    const growsBefore = fake.growCount();
    write(terminal, "abc");
    write(terminal, "def");
    expect(fake.growCount()).toBeGreaterThan(growsBefore);

    terminal.readFrame((frame) => {
      expect(textOf(frame, 0)).toBe("abcdef");
    });
    binding.dispose();
  });

  it("survives memory growth in the middle of building a frame", () => {
    // Every allocation grows linear memory here, including the ones the
    // grapheme retry makes while the frame is being built. A binding that held
    // a view across those calls reads a detached buffer — zeroes, silently.
    const { fake, terminal, binding } = harness({ growOnAlloc: true });
    const model = fake.terminals()[0];
    if (model === undefined) throw new Error("no fake terminal");
    write(terminal, "\x1b[31ma");
    const cluster = `e${"́".repeat(80)}`;
    fake.poke(model, 0, 1, {
      contentTag: ENUMS.GhosttyCellContentTag.CODEPOINT_GRAPHEME,
      codepoint: 0x65,
      grapheme: cluster,
    });

    const growsBefore = fake.growCount();
    terminal.readFrame((frame) => {
      expect(cellAt(frame, 0, 0).foreground).toEqual({ tag: "palette", index: 1 });
      expect(cellAt(frame, 0, 1).grapheme).toBe(cluster);
    });
    expect(fake.growCount()).toBeGreaterThan(growsBefore);
    binding.dispose();
  });

  it("follows the manifest when the struct layout moves", () => {
    // Same ABI, every sized struct shifted by 16 bytes. A binding with a
    // hardcoded offset reads a style out of padding and this fails.
    const { terminal, binding } = harness({ padding: 16 });
    write(terminal, "\x1b[31;1ma");
    terminal.readFrame((frame) => {
      const cell = cellAt(frame, 0, 0);
      expect(cell.foreground).toEqual({ tag: "palette", index: 1 });
      expect(cell.attributes & ATTR.BOLD).toBeTruthy();
    });
    binding.dispose();
  });

  it("refuses to write or dispose from inside visit", () => {
    const { terminal, binding } = harness();
    write(terminal, "a");
    terminal.readFrame(() => {
      expect(() => write(terminal, "b")).toThrow(/inside readFrame/);
      expect(() => terminal.resize(2, 2)).toThrow(/inside readFrame/);
      expect(() => terminal.dispose()).toThrow(/inside readFrame/);
      expect(() => terminal.readFrame(() => 0)).toThrow(/not reentrant/);
    });
    binding.dispose();
  });

  it("leaves the damage standing when visit throws", () => {
    const { terminal, binding } = harness();
    write(terminal, "a");
    expect(() =>
      terminal.readFrame(() => {
        throw new Error("renderer blew up");
      }),
    ).toThrow("renderer blew up");

    // Not cleaned: the frame was never painted, so the next one repaints it.
    terminal.readFrame((frame) => {
      expect(frame.dirty).toBe("full");
    });
    binding.dispose();
  });

  it("returns what visit returns", () => {
    const { terminal, binding } = harness();
    const rows = terminal.readFrame((frame) => frame.rows_.length);
    expect(rows).toBe(4);
    binding.dispose();
  });

  it("repaints everything after a resize", () => {
    const { terminal, binding } = harness();
    write(terminal, "abc");
    terminal.readFrame(() => {});

    terminal.resize(2, 4);
    expect(terminal.rows).toBe(2);
    expect(terminal.cols).toBe(4);
    terminal.readFrame((frame) => {
      expect(frame.dirty).toBe("full");
      expect(frame.rows).toBe(2);
      expect(frame.cols).toBe(4);
      expect(frame.rows_.length).toBe(2);
      expect(frame.rows_[0]?.cells.length).toBe(4);
    });
    binding.dispose();
  });
});

describe("VtTerminal state reads", () => {
  it("reports the OSC title, and null when the program set none", () => {
    const { terminal, binding } = harness();
    expect(terminal.title()).toBeNull();
    write(terminal, "\x1b]2;build\x07");
    expect(terminal.title()).toBe("build");
    binding.dispose();
  });

  it("queries synchronized output rather than inferring it", () => {
    const { terminal, binding } = harness();
    expect(terminal.syncOutputActive()).toBe(false);
    write(terminal, "\x1b[?2026h");
    expect(terminal.syncOutputActive()).toBe(true);
    write(terminal, "\x1b[?2026l");
    expect(terminal.syncOutputActive()).toBe(false);
    binding.dispose();
  });

  it("reads the key-encoder modes off the VT", () => {
    const { fake, terminal, binding } = harness();
    expect(terminal.keyEncoderModes()).toEqual({
      cursorKeyApplication: false,
      keypadApplication: false,
      kittyFlags: 0,
      altSendsEscape: false,
      bracketedPaste: false,
    });

    write(terminal, "\x1b[?1h\x1b[?2004h");
    const model = fake.terminals()[0];
    if (model === undefined) throw new Error("no fake terminal");
    model.kittyFlags = 0b101;

    expect(terminal.keyEncoderModes()).toEqual({
      cursorKeyApplication: true,
      keypadApplication: false,
      kittyFlags: 0b101,
      altSendsEscape: false,
      bracketedPaste: true,
    });
    binding.dispose();
  });
});

describe("lifecycle", () => {
  it("is idempotent on dispose, the way StrictMode needs", () => {
    const { terminal, binding } = harness();
    terminal.dispose();
    expect(() => terminal.dispose()).not.toThrow();
    expect(() => terminal.write(encoder.encode("a"))).toThrow(/disposed/);
    binding.dispose();
  });

  it("frees every allocation it made", () => {
    const fake = createFakeGhostty();
    const binding = bindingFromExports(fake.exports);
    const terminal = binding.createTerminal({
      rows: 3,
      cols: 4,
      scrollbackBytes: 1024,
    });
    write(terminal, "hello");
    terminal.readFrame(() => {});
    terminal.dispose();
    // The fixture's allocator refuses a free with the wrong length, so a clean
    // ledger here also means every free used the length it allocated with.
    expect(fake.liveAllocations()).toBe(0);
    binding.dispose();
  });

  it("disposes terminals the page forgot when the binding goes away", () => {
    const fake = createFakeGhostty();
    const binding = bindingFromExports(fake.exports);
    binding.createTerminal({ rows: 2, cols: 2, scrollbackBytes: 1024 });
    binding.dispose();
    expect(fake.liveAllocations()).toBe(0);
  });

  it("reports the manifest's version and commit for diagnostics", () => {
    const fake = createFakeGhostty();
    const binding = bindingFromExports(fake.exports);
    expect(binding.commit).toBe("56e1f3a62e26407e8c020ef5881df3e8584be20f");
    binding.dispose();
  });
});
