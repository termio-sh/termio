// Whether a document the kernel just took is actually all of it.
//
// The kernel has three load paths and they do not agree. `resetMD` parses the whole
// text synchronously. `initMd` and `resetMDChunked` hydrate PROGRESSIVELY — the first
// 500 lines land at once and the rest is spliced in over later ticks — and the README
// says so with no completion signal to wait on. Measured on a 2402-line document at
// 0.12.3: `resetMD` yields all 19299 bytes immediately; `initMd` and `resetMDChunked`
// yield 3882.
//
// There is no public hydration-complete signal to ask. `_chunkGeneration_` is private,
// `resetMDChunked` returns void, and nothing is exported that reports progress. So
// completeness is inferred from the result, and the inference is exact rather than a
// heuristic: a progressive load has only ever parsed a leading run of the text, so what
// it produced is a PREFIX of what it was given. Canonicalization is not — re-padding a
// table grows a line in the middle, dropping a blank line inside a loose list removes
// one from the middle — so a canonicalized document diverges from the input somewhere
// before its end and fails the prefix test.
//
// Trailing whitespace is trimmed off both sides first: a serializer that drops a final
// newline would otherwise leave a prefix and be mistaken for a truncation.
export function isIncompleteLoad(input, serialized) {
  if (typeof input !== "string" || typeof serialized !== "string") return true;
  const given = input.replace(/\s+$/, "");
  const got = serialized.replace(/\s+$/, "");
  if (got === given) return false;          // complete, byte for byte
  return given.startsWith(got);             // a proper prefix is a truncation
}
