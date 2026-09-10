#!/usr/bin/env bash
# Regenerate docs/api/session-protocol.schema.json from the protocol types.
#
# The published schema is generated, never edited: it is derived from
# `termiod::protocol`, so the messages the daemon answers and the messages the
# schema describes are the same set by construction. Run this after changing any
# type reachable from `Control` or `Event`, and commit the result.
#
# `--check` regenerates into a temp file and diffs instead of writing, which is
# what CI runs: a protocol change that forgets the schema fails there rather than
# shipping a schema that describes a daemon nobody has.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/docs/api/session-protocol.schema.json"

# Run from inside `termiod/`, not with `--manifest-path`: the crate's own
# `.cargo/config.toml` sets `LIBGHOSTTY_VT_SYS_OPTIMIZE`, which cargo reads from
# the working directory. Building from the repo root drops it, changes the build
# fingerprint, and rebuilds the Zig VT engine — which needs a toolchain this
# script has no business requiring.
generate() {
  (cd "$root/termiod" && cargo run --quiet --features schema --bin termiod-schema)
}

if [[ "${1:-}" == "--check" ]]; then
  scratch="$(mktemp)"
  trap 'rm -f "$scratch"' EXIT
  generate > "$scratch"
  if ! diff -u "$out" "$scratch"; then
    echo >&2
    echo "docs/api/session-protocol.schema.json is stale — run scripts/generate-api-schema.sh" >&2
    exit 1
  fi
  echo "schema is current"
  exit 0
fi

mkdir -p "$(dirname "$out")"
generate > "$out"
echo "wrote ${out#"$root"/}"
