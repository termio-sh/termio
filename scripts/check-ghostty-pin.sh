#!/usr/bin/env bash
#
# Fail when the browser, the host, and the Mac would run different ghostty.
#
# The Replica contract is "the same state machine as the host and the Mac." That
# is asserted in three files that cannot see each other, each one hop away from
# the sha it actually implies:
#
#   termiod/vt/Cargo.toml   libghostty-rs rev -> build.rs GHOSTTY_COMMIT
#   Package.resolved        libghostty-swift version -> release body sha
#   web/client/ghostty-pin  the ghostty-vt.wasm the web root serves
#
# Bump one and forget another and nothing breaks loudly: the daemon builds, the
# app builds, the page loads, and the browser silently disagrees with the host
# about grapheme width, autowrap, or a kitty keyboard sequence. No existing test
# looks at more than one of the three. This one resolves all three and diffs
# them.
#
# Usage: scripts/check-ghostty-pin.sh
#
# Network: two unauthenticated GETs (raw.githubusercontent.com and the GitHub
# releases API). The libghostty-rs leg reads a local cargo checkout first when
# one is present, so a warm dev machine usually needs one request.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin_file="$repo_root/web/client/ghostty-pin.json"
vt_cargo="$repo_root/termiod/vt/Cargo.toml"
resolved="$repo_root/Package.resolved"

fail() {
  echo "::error::$*" >&2
  echo "error: $*" >&2
  exit 1
}

fetch() {
  curl -fsSL --max-time 60 "$1"
}

for path in "$pin_file" "$vt_cargo" "$resolved"; do
  [ -f "$path" ] || fail "missing $path"
done

# ── Declared: what web/client/ghostty-pin.json says the browser runs ─────────
declared="$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    print(json.load(handle)["ghostty_sha"])
' "$pin_file")"

[[ "$declared" =~ ^[0-9a-f]{40}$ ]] ||
  fail "ghostty_pin.ghostty_sha is not a full 40-char sha: $declared"

# The artifact URL is content-addressed by that sha; a mismatch means the pin was
# half-edited and a fetch would install a different engine than the file claims.
python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    pin = json.load(handle)
url, sha = pin["artifact"]["url"], pin["ghostty_sha"]
if sha not in url:
    raise SystemExit(f"artifact.url does not carry ghostty_sha {sha}:\n  {url}")
' "$pin_file" || fail "web/client/ghostty-pin.json is internally inconsistent"

# ── Leg 1: termiod's sidecar VT (Rust) ───────────────────────────────────────
rs_rev="$(sed -n 's/.*libghostty-rs".*rev = "\([0-9a-f]\{40\}\)".*/\1/p' "$vt_cargo" | head -1)"
[ -n "$rs_rev" ] || fail "could not read the libghostty-rs rev out of $vt_cargo"

rs_build_rs=""
for checkout in "$HOME"/.cargo/git/checkouts/libghostty-rs-*/"${rs_rev:0:7}"; do
  candidate="$checkout/crates/libghostty-vt-sys/build.rs"
  if [ -f "$candidate" ]; then
    rs_build_rs="$(cat "$candidate")"
    break
  fi
done
if [ -z "$rs_build_rs" ]; then
  rs_build_rs="$(fetch "https://raw.githubusercontent.com/termio-sh/libghostty-rs/$rs_rev/crates/libghostty-vt-sys/build.rs")" ||
    fail "could not read build.rs from libghostty-rs @ $rs_rev"
fi
rs_sha="$(printf '%s' "$rs_build_rs" |
  sed -n 's/^const GHOSTTY_COMMIT: &str = "\([0-9a-f]\{40\}\)";$/\1/p' | head -1)"
[ -n "$rs_sha" ] || fail "libghostty-rs @ $rs_rev has no parseable GHOSTTY_COMMIT"

# ── Leg 2: the Mac and iOS clients (Swift) ───────────────────────────────────
swift_version="$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    resolved = json.load(handle)
for entry in resolved["pins"]:
    if entry["identity"] == "libghostty-swift":
        print(entry["state"]["version"])
        break
else:
    raise SystemExit("libghostty-swift is not pinned in Package.resolved")
' "$resolved")" || fail "could not read the libghostty-swift version out of $resolved"

release_json="$(fetch "https://api.github.com/repos/termio-sh/libghostty-swift/releases/tags/$swift_version")" ||
  fail "could not read the libghostty-swift $swift_version release. The ghostty sha it
built is recorded only in the release body, so this check cannot run offline."

swift_sha="$(printf '%s' "$release_json" | python3 -c '
import json, re, sys
body = json.load(sys.stdin).get("body") or ""
match = re.search(r"ghostty sha:\s*([0-9a-f]{40})", body)
print(match.group(1) if match else "")
')"
[ -n "$swift_sha" ] ||
  fail "libghostty-swift $swift_version release body has no 'Built from ghostty sha:' line"

# ── Verdict ─────────────────────────────────────────────────────────────────
printf '%-34s %s\n' \
  "web/client/ghostty-pin.json" "$declared" \
  "termiod/vt (libghostty-rs ${rs_rev:0:7})" "$rs_sha" \
  "Package.resolved (swift $swift_version)" "$swift_sha"

if [ "$declared" != "$rs_sha" ] || [ "$declared" != "$swift_sha" ]; then
  fail "ghostty pins disagree — the browser would render a different VT than the host and the Mac.
Bump all three in one change:
  termiod/vt/Cargo.toml    rev of termio-sh/libghostty-rs (its build.rs carries GHOSTTY_COMMIT)
  Package.swift            termio-sh/libghostty-swift version, then resolve
  web/client/ghostty-pin.json  ghostty_sha + artifact url/sha256/bytes
Refresh the wasm with: scripts/ghostty-wasm.sh fetch --force"
fi

echo "ok — one ghostty across the host, the Mac, and the browser"

# ── Optional: the installed binary is the one the pin describes ─────────────
wasm="$repo_root/web/client/public/ghostty-vt.wasm"
if [ -f "$wasm" ]; then
  "$repo_root/scripts/ghostty-wasm.sh" verify
else
  echo "note: $wasm not fetched yet (scripts/ghostty-wasm.sh fetch)"
fi
