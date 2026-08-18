/**
 * `ProtocolError` lives in its own module so `colors.ts` and `payloads.ts` can
 * throw it without importing `frame.ts`, which imports them back to decode `S`
 * and `H`. `frame.ts` re-exports it, so the contract's
 * `import { ProtocolError } from "./frame"` still resolves.
 */
export class ProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProtocolError";
  }
}
