#!/usr/bin/env bash
#
# Put the pinned ghostty-vt.wasm where the web client can serve it.
#
# The browser Replica runs official libghostty-vt as its VT. "Official" is not
# enough on its own: the wasm ships only on ghostty's rolling `tip` pre-release,
# so the release tag is a moving target while termiod/vt and the Mac are pinned
# to one commit. Ghostty's release job also copies each build to a
# content-addressed bucket keyed by the full commit sha, and that path is what
# this script fetches — the official binary, at the commit we pinned, forever.
#
# Usage:
#   scripts/ghostty-wasm.sh fetch [--force]   download + verify + install (default)
#   scripts/ghostty-wasm.sh verify            hash the installed file against the pin
#   scripts/ghostty-wasm.sh build [--out P]   build from ghostty source at the pin
#   scripts/ghostty-wasm.sh path              print where the artifact lands
#
# Where it lands:
#   web/client/public/ghostty-vt.wasm — Vite copies public/ into dist/ verbatim,
#   so the built tree has it at the web root next to index.html. It is gitignored:
#   a 900 KB binary belongs in the versioned web root on the box, not in git.
#   scripts/stage-web-root.sh is what assembles that root.
#
# The pin lives in web/client/ghostty-pin.json. scripts/check-ghostty-pin.sh
# proves it agrees with libghostty-rs and libghostty-swift.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin_file="$repo_root/web/client/ghostty-pin.json"
dest="$repo_root/web/client/public/ghostty-vt.wasm"

die() {
  echo "error: $*" >&2
  exit 1
}

pin() {
  python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    pin = json.load(handle)
node = pin
for key in sys.argv[2].split("."):
    node = node[key]
print(node if not isinstance(node, list) else " ".join(node))
' "$pin_file" "$1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

[ -f "$pin_file" ] || die "missing pin file: $pin_file"

command="${1:-fetch}"
shift || true

case "$command" in
  path)
    echo "$dest"
    ;;

  verify)
    [ -f "$dest" ] || die "not installed: $dest (run: scripts/ghostty-wasm.sh fetch)"
    want="$(pin artifact.sha256)"
    got="$(sha256_of "$dest")"
    if [ "$want" != "$got" ]; then
      die "sha256 mismatch for $dest
  expected $want
  actual   $got
This is a different ghostty than the host and the Mac run. Re-fetch, do not ship."
    fi
    echo "ghostty-vt.wasm ok — $(pin ghostty_describe) ($(pin ghostty_sha))"
    echo "  $dest"
    echo "  sha256 $got  bytes $(wc -c <"$dest" | tr -d ' ')"
    ;;

  fetch)
    force=""
    [ "${1:-}" = "--force" ] && force=1
    url="$(pin artifact.url)"
    want="$(pin artifact.sha256)"

    if [ -z "$force" ] && [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "$want" ]; then
      echo "ghostty-vt.wasm already at $(pin ghostty_sha), nothing to do"
      exit 0
    fi

    mkdir -p "$(dirname "$dest")"
    tmp="$dest.download.$$"
    trap 'rm -f "$tmp"' EXIT

    echo "fetching $url"
    curl -fsSL --max-time 300 -o "$tmp" "$url" ||
      die "download failed. The tip bucket keeps blobs by commit, but not forever —
if this 404s, build from source instead: scripts/ghostty-wasm.sh build"

    got="$(sha256_of "$tmp")"
    [ "$want" = "$got" ] || die "sha256 mismatch from $url
  expected $want
  actual   $got"

    # A truncated or HTML-error body hashes differently, so this is belt and
    # braces — but a wasm that is not a wasm is worth naming precisely.
    head -c 4 "$tmp" | od -An -tx1 | tr -d ' \n' | grep -q '^0061736d' ||
      die "downloaded file is not a WebAssembly module (bad magic)"

    mv -f "$tmp" "$dest"
    trap - EXIT
    echo "installed $dest"
    echo "  $(pin ghostty_describe)  sha256 $got  bytes $(wc -c <"$dest" | tr -d ' ')"
    ;;

  build)
    out="$dest"
    if [ "${1:-}" = "--out" ]; then
      out="${2:?--out needs a path}"
    fi
    sha="$(pin ghostty_sha)"
    work="${GHOSTTY_WASM_WORKDIR:-${TMPDIR:-/tmp}/termio-ghostty-wasm}"
    src="$work/ghostty-src"

    command -v zig >/dev/null 2>&1 || die "zig not on PATH.
CI pins $(pin source_build.zig):
  export PATH=\$HOME/.local/share/termiod-toolchains/zig-$(pin source_build.zig):\$PATH"
    command -v wasm-opt >/dev/null 2>&1 || die "wasm-opt not on PATH (brew install binaryen).
Without it zig emits a ~4.2 MB module with debug info; ghostty's own release job
runs wasm-opt to get the ~900 KB artifact, and so must we."

    mkdir -p "$work"
    if [ ! -d "$src/.git" ]; then
      git clone --filter=blob:none --no-checkout "$(pin source_build.repo)" "$src"
    fi
    git -C "$src" fetch --filter=blob:none origin "$sha" 2>/dev/null || true
    git -C "$src" checkout --detach "$sha"

    read -r -a build_args <<<"$(pin source_build.zig_build_args)"
    read -r -a opt_args <<<"$(pin source_build.wasm_opt_args)"

    (cd "$src" && zig build "${build_args[@]}" \
      --prefix "$work/prefix" \
      --cache-dir "$work/zig-cache")

    mkdir -p "$(dirname "$out")"
    wasm-opt "${opt_args[@]}" "$work/prefix/bin/ghostty-vt.wasm" -o "$out"

    built="$(sha256_of "$out")"
    echo "built $out"
    echo "  ghostty $sha  sha256 $built  bytes $(wc -c <"$out" | tr -d ' ')"
    echo

    # This build is reproducible: zig 0.16.0 + binaryen 132 on an arm64 Mac
    # reproduced the published Linux CI artifact byte for byte. So a match here
    # is a second, independent proof that the pinned blob really is this commit —
    # which matters, because ghostty publishes no minisign signature under the
    # content-addressed path.
    if [ "$built" = "$(pin artifact.sha256)" ]; then
      echo "byte-identical to the pinned artifact — the published blob is this commit"
    else
      echo "This differs from the pinned artifact's sha256. Reproducibility depends on"
      echo "the zig and binaryen versions (pin: zig $(pin source_build.zig), binaryen"
      echo "$(pin source_build.wasm_opt)), so a different toolchain is the likely cause"
      echo "and not tampering. Compare the export table and ghostty_type_json before"
      echo "trusting it, and if it replaces the pin, update artifact.sha256/bytes in"
      echo "web/client/ghostty-pin.json and say in the commit that it is locally built."
    fi
    ;;

  *)
    die "unknown command: $command (fetch | verify | build | path)"
    ;;
esac
