/**
 * The ABI type manifest returned by `ghostty_type_json`.
 *
 * Every offset, struct size, enum value, and packed-cell bit position this
 * module uses is read out of this manifest at instantiate time rather than
 * hardcoded. `render.h` requires it for the packed cell — "Bit positions aren't
 * protected by ABI, so callers should parse them out of the manifest from
 * `ghostty_type_json`" — and once the manifest has to be parsed for the cell,
 * taking struct offsets from anywhere else would mean two sources of truth for
 * one build. A Wasm built from a different ghostty commit then fails loudly
 * here instead of decoding a style out of the wrong four bytes.
 */

/** The subset of `abi` this binding depends on. */
export interface AbiInfo {
  target: string;
  pointerSize: number;
  usizeSize: number;
  maxAlignment: number;
  endian: "little" | "big";
}

export interface FieldLayout {
  offset: number;
  size: number;
  /** `"array"`, `"pointer"`, a `GhosttyX` name, or a primitive like `u16`. */
  type: string;
  /** Element type for `array` / `pointer` fields. */
  elem?: string;
  /** Element count for `array` fields. */
  count?: number;
  /** Sibling field naming the active arm, for tagged-union fields. */
  tag?: string;
  /** Tag value name → member name, `null` when the arm carries no payload. */
  arms?: Record<string, string | null>;
}

export interface StructLayout {
  size: number;
  align: number;
  fields: Record<string, FieldLayout>;
}

export interface ScalarBits {
  kind: "scalar";
  /** Least-significant bit, relative to the containing value. */
  lsb: number;
  width: number;
  type: string;
}

export interface UnionArm {
  width: number;
  bits: Record<string, BitLayout>;
}

export interface UnionBits {
  kind: "union";
  lsb: number;
  width: number;
  /** Name of the sibling bit field holding the active arm. */
  tag: string;
  /** Tag value name → inline arm layout, `null` for a payload-free arm. */
  arms: Record<string, UnionArm | null>;
}

export type BitLayout = ScalarBits | UnionBits;

export interface PackedLayout {
  size: number;
  underlying: string;
  bits: Record<string, BitLayout>;
}

export class ManifestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ManifestError";
  }
}

interface RawDescriptor {
  kind?: unknown;
  size?: unknown;
  align?: unknown;
  underlying?: unknown;
  fields?: unknown;
  bits?: unknown;
  values?: unknown;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireNumber(value: unknown, what: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ManifestError(`${what} is not a number`);
  }
  return value;
}

function requireString(value: unknown, what: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new ManifestError(`${what} is not a string`);
  }
  return value;
}

function parseField(name: string, raw: unknown): FieldLayout {
  if (!isRecord(raw)) {
    throw new ManifestError(`field ${name} is not an object`);
  }
  const field: FieldLayout = {
    offset: requireNumber(raw["offset"], `field ${name}.offset`),
    size: requireNumber(raw["size"], `field ${name}.size`),
    type: requireString(raw["type"], `field ${name}.type`),
  };
  if (typeof raw["elem"] === "string") field.elem = raw["elem"];
  if (typeof raw["count"] === "number") field.count = raw["count"];
  if (typeof raw["tag"] === "string") field.tag = raw["tag"];
  if (isRecord(raw["arms"])) {
    const arms: Record<string, string | null> = {};
    for (const [key, value] of Object.entries(raw["arms"])) {
      arms[key] = typeof value === "string" ? value : null;
    }
    field.arms = arms;
  }
  return field;
}

function parseBits(owner: string, raw: unknown): Record<string, BitLayout> {
  if (!isRecord(raw)) {
    throw new ManifestError(`${owner}.bits is not an object`);
  }
  const bits: Record<string, BitLayout> = {};
  for (const [name, value] of Object.entries(raw)) {
    if (!isRecord(value)) {
      throw new ManifestError(`${owner}.bits.${name} is not an object`);
    }
    const lsb = requireNumber(value["lsb"], `${owner}.bits.${name}.lsb`);
    const width = requireNumber(value["width"], `${owner}.bits.${name}.width`);
    if (value["kind"] === "union") {
      const rawArms = value["arms"];
      if (!isRecord(rawArms)) {
        throw new ManifestError(`${owner}.bits.${name}.arms is not an object`);
      }
      const arms: Record<string, UnionArm | null> = {};
      for (const [armName, armValue] of Object.entries(rawArms)) {
        if (armValue === null || armValue === undefined) {
          arms[armName] = null;
          continue;
        }
        if (!isRecord(armValue)) {
          throw new ManifestError(
            `${owner}.bits.${name}.arms.${armName} is not an object`,
          );
        }
        arms[armName] = {
          width: requireNumber(
            armValue["width"],
            `${owner}.bits.${name}.arms.${armName}.width`,
          ),
          bits: parseBits(`${owner}.${name}.${armName}`, armValue["bits"]),
        };
      }
      bits[name] = {
        kind: "union",
        lsb,
        width,
        tag: requireString(value["tag"], `${owner}.bits.${name}.tag`),
        arms,
      };
      continue;
    }
    bits[name] = {
      kind: "scalar",
      lsb,
      width,
      type: requireString(value["type"], `${owner}.bits.${name}.type`),
    };
  }
  return bits;
}

/**
 * A parsed manifest, indexed by type name.
 *
 * Lookups throw rather than returning `undefined`: a missing type or field is
 * a skew bug between this binding and the Wasm it was handed, and the only
 * useful thing to do with it is fail at instantiate with the name in the
 * message.
 */
export class TypeManifest {
  readonly abi: AbiInfo;
  readonly libraryVersion: string;
  readonly commit: string | null;
  private readonly types: Record<string, RawDescriptor>;

  private constructor(
    abi: AbiInfo,
    libraryVersion: string,
    commit: string | null,
    types: Record<string, RawDescriptor>,
  ) {
    this.abi = abi;
    this.libraryVersion = libraryVersion;
    this.commit = commit;
    this.types = types;
  }

  static parse(json: string): TypeManifest {
    let parsed: unknown;
    try {
      parsed = JSON.parse(json);
    } catch (error) {
      throw new ManifestError(
        `ghostty_type_json did not return JSON: ${String(error)}`,
      );
    }
    if (!isRecord(parsed)) {
      throw new ManifestError("manifest is not an object");
    }
    if (parsed["schema"] !== 1) {
      throw new ManifestError(
        `manifest schema ${String(parsed["schema"])} is not 1`,
      );
    }
    const rawAbi = parsed["abi"];
    if (!isRecord(rawAbi)) {
      throw new ManifestError("manifest has no abi object");
    }
    const endian = rawAbi["endian"];
    if (endian !== "little" && endian !== "big") {
      throw new ManifestError(`manifest endian ${String(endian)} is unknown`);
    }
    const abi: AbiInfo = {
      target: requireString(rawAbi["target"], "abi.target"),
      pointerSize: requireNumber(rawAbi["pointer_size"], "abi.pointer_size"),
      usizeSize: requireNumber(rawAbi["usize_size"], "abi.usize_size"),
      maxAlignment: requireNumber(rawAbi["max_alignment"], "abi.max_alignment"),
      endian,
    };
    const rawTypes = parsed["types"];
    if (!isRecord(rawTypes)) {
      throw new ManifestError("manifest has no types object");
    }
    const types: Record<string, RawDescriptor> = {};
    for (const [name, value] of Object.entries(rawTypes)) {
      if (!isRecord(value)) {
        throw new ManifestError(`type ${name} is not an object`);
      }
      types[name] = value as RawDescriptor;
    }
    const commit = parsed["commit"];
    return new TypeManifest(
      abi,
      typeof parsed["library_version"] === "string"
        ? parsed["library_version"]
        : "unknown",
      typeof commit === "string" ? commit : null,
      types,
    );
  }

  /**
   * The checks that make a wrong Wasm a loud failure instead of a corrupt
   * screen. A 64-bit manifest would put every struct field this binding reads
   * at the wrong offset, and a big-endian one would invert every integer.
   */
  assertWasm32LittleEndian(): void {
    if (this.abi.pointerSize !== 4 || this.abi.usizeSize !== 4) {
      throw new ManifestError(
        `expected a 32-bit ABI, got pointer_size ${this.abi.pointerSize} / usize_size ${this.abi.usizeSize}`,
      );
    }
    if (this.abi.endian !== "little") {
      throw new ManifestError(`expected a little-endian ABI, got ${this.abi.endian}`);
    }
  }

  private descriptor(name: string, kind: string): RawDescriptor {
    const descriptor = this.types[name];
    if (descriptor === undefined) {
      throw new ManifestError(`manifest has no type ${name}`);
    }
    if (descriptor.kind !== kind) {
      throw new ManifestError(
        `manifest type ${name} is a ${String(descriptor.kind)}, expected a ${kind}`,
      );
    }
    return descriptor;
  }

  struct(name: string): StructLayout {
    const descriptor = this.descriptor(name, "struct");
    const rawFields = descriptor.fields;
    if (!isRecord(rawFields)) {
      throw new ManifestError(`struct ${name} has no fields`);
    }
    const fields: Record<string, FieldLayout> = {};
    for (const [fieldName, raw] of Object.entries(rawFields)) {
      fields[fieldName] = parseField(`${name}.${fieldName}`, raw);
    }
    return {
      size: requireNumber(descriptor.size, `${name}.size`),
      align: requireNumber(descriptor.align, `${name}.align`),
      fields,
    };
  }

  field(structName: string, fieldName: string): FieldLayout {
    const field = this.struct(structName).fields[fieldName];
    if (field === undefined) {
      throw new ManifestError(`struct ${structName} has no field ${fieldName}`);
    }
    return field;
  }

  union(name: string): StructLayout {
    const descriptor = this.descriptor(name, "union");
    const rawFields = descriptor.fields;
    if (!isRecord(rawFields)) {
      throw new ManifestError(`union ${name} has no fields`);
    }
    const fields: Record<string, FieldLayout> = {};
    for (const [fieldName, raw] of Object.entries(rawFields)) {
      fields[fieldName] = parseField(`${name}.${fieldName}`, raw);
    }
    return {
      size: requireNumber(descriptor.size, `${name}.size`),
      align: requireNumber(descriptor.align, `${name}.align`),
      fields,
    };
  }

  enumValues(name: string): Record<string, number> {
    const descriptor = this.descriptor(name, "enum");
    const rawValues = descriptor.values;
    if (!isRecord(rawValues)) {
      throw new ManifestError(`enum ${name} has no values`);
    }
    const values: Record<string, number> = {};
    for (const [key, value] of Object.entries(rawValues)) {
      values[key] = requireNumber(value, `${name}.${key}`);
    }
    return values;
  }

  enumValue(name: string, key: string): number {
    const value = this.enumValues(name)[key];
    if (value === undefined) {
      throw new ManifestError(`enum ${name} has no value ${key}`);
    }
    return value;
  }

  packed(name: string): PackedLayout {
    const descriptor = this.descriptor(name, "packed");
    return {
      size: requireNumber(descriptor.size, `${name}.size`),
      underlying: requireString(descriptor.underlying, `${name}.underlying`),
      bits: parseBits(name, descriptor.bits),
    };
  }
}

/**
 * Extract a bit field from a 64-bit value split into two 32-bit halves.
 *
 * The packed cell is a `u64`, and the fields this binding reads (content tag,
 * codepoint, style id, wide) all fit in 32 bits — but they do not all sit in
 * the low half, so the extraction has to span the halves. Doing it on two
 * numbers rather than a `BigInt` keeps the per-cell path allocation-free: a
 * 200×50 viewport at 60 fps is 600k cells a second, and a BigInt per cell is
 * 600k garbage objects a second.
 */
export function extractBits(
  low: number,
  high: number,
  lsb: number,
  width: number,
): number {
  if (width > 32) {
    throw new ManifestError(`bit field of width ${width} exceeds 32 bits`);
  }
  const mask = width === 32 ? 0xffffffff : (1 << width) - 1;
  if (lsb >= 32) {
    return (high >>> (lsb - 32)) & mask;
  }
  const lowPart = low >>> lsb;
  const takenFromLow = 32 - lsb;
  if (width <= takenFromLow) {
    return lowPart & mask;
  }
  // The field straddles the halves: the low bits come from `low`, the rest
  // from the bottom of `high`. `* 2 ** takenFromLow` rather than `<<` because
  // a shift of 32 is a no-op in JS and the sum can exceed 2^31.
  const highPart = high & ((1 << (width - takenFromLow)) - 1);
  return lowPart + highPart * 2 ** takenFromLow;
}
