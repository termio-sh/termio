#!/usr/bin/env bash
#
# Assemble the versioned web root termiod's `--web-root` serves.
#
# Layout, matching the deploy contract:
#
#   <root>/<termiod-version>-g<ghostty-sha7>/   index.html, assets/…, ghostty-vt.wasm
#   <root>/current -> <termiod-version>-g<ghostty-sha7>
#
# The directory name carries both versions because both can change without the
# other: a termiod release with the same VT, or a ghostty bump with the same
# daemon. `current` is what the systemd unit points at
# (`%h/.local/share/termiod/web/current`), so a deploy writes a new directory and
# flips one symlink; a rollback flips it back. Missing `current` is not fatal —
# termiod logs and serves no files, and WSS still binds.
#
# Usage:
#   scripts/stage-web-root.sh [--root DIR] [--dist DIR] [--keep N] [--no-build]
#
#   --root     where the versioned tree goes. Default web/client/webroot,
#              which is what you scp to ~/.local/share/termiod/web/ on the box.
#   --dist     the built client. Default web/client/dist.
#   --keep     how many older versions to leave behind. Default 3.
#   --no-build use an existing --dist instead of running the client build.
#
# What it refuses to stage, and why each one is a real deploy bug:
#   · a missing or wrong-sha ghostty-vt.wasm — the browser would run a different
#     VT than the host and the Mac
#   · any *.map — the GET jail has no `.map` MIME entry, so a stray one 403s
#     instead of leaking sources, but it should not be in the tree at all
#   · any file whose extension the GET jail's MIME map does not carry — it would
#     403 at runtime, which is a broken page found by a user rather than by this

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
client="$repo_root/web/client"
root="$client/webroot"
dist="$client/dist"
keep=3
build=1

while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="${2:?--root needs a path}"; shift 2 ;;
    --dist) dist="${2:?--dist needs a path}"; shift 2 ;;
    --keep) keep="${2:?--keep needs a count}"; shift 2 ;;
    --no-build) build=""; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

die() {
  echo "error: $*" >&2
  exit 1
}

# The GET jail's map, verbatim from the design: anything else is a 403 at
# runtime, so it must not reach the tree.
served_extensions="html js css wasm svg woff2 ttf"

ghostty_sha="$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    print(json.load(handle)["ghostty_sha"])
' "$client/ghostty-pin.json")"
termiod_version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$repo_root/termiod/Cargo.toml" | head -1)"
[ -n "$termiod_version" ] || die "could not read the termiod version out of termiod/Cargo.toml"

version_dir="$termiod_version-g${ghostty_sha:0:7}"
target="$root/$version_dir"

"$repo_root/scripts/ghostty-wasm.sh" fetch

if [ -n "$build" ]; then
  command -v pnpm >/dev/null 2>&1 || die "pnpm not on PATH (or pass --no-build)"
  (cd "$client" && pnpm install --frozen-lockfile && pnpm build)
fi

[ -d "$dist" ] || die "no built client at $dist"
[ -f "$dist/index.html" ] || die "$dist has no index.html"

# The wasm reaches dist/ through Vite's public/ passthrough. Assert rather than
# assume: a public/ that was never populated produces a page that loads and then
# fails at instantiate with a 404 dressed as a MIME error.
[ -f "$dist/ghostty-vt.wasm" ] ||
  die "$dist/ghostty-vt.wasm is missing — public/ was not populated before the build"

pinned_sha256="$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    print(json.load(handle)["artifact"]["sha256"])
' "$client/ghostty-pin.json")"
if command -v sha256sum >/dev/null 2>&1; then
  built_sha256="$(sha256sum "$dist/ghostty-vt.wasm" | cut -d' ' -f1)"
else
  built_sha256="$(shasum -a 256 "$dist/ghostty-vt.wasm" | cut -d' ' -f1)"
fi
[ "$pinned_sha256" = "$built_sha256" ] ||
  die "$dist/ghostty-vt.wasm is not the pinned build
  expected $pinned_sha256
  actual   $built_sha256"

strays="$(find "$dist" -type f -name '*.map' -print)"
[ -z "$strays" ] || die "source maps in the deploy tree:
$strays
vite.config.ts sets sourcemap:false; something re-enabled it."

not_served=()
for ext in $served_extensions; do
  not_served+=(-not -name "*.$ext")
done
unservable="$(find "$dist" -type f "${not_served[@]}" -print)"
[ -z "$unservable" ] || die "files the GET jail's MIME map cannot serve (they would 403):
$unservable"

# Stage beside the target, then rename: a half-copied directory must never be
# reachable through `current`.
mkdir -p "$root"
staging="$root/.staging.$$"
rm -rf "$staging"
cp -R "$dist" "$staging"
rm -rf "$target"
mv "$staging" "$target"

# Flip `current`. On GNU coreutils `mv -T` is a rename(2) and genuinely atomic.
# BSD mv has no -T, and the naive `mv -f newlink current` follows the existing
# symlink and buries the new link INSIDE the old version directory — measured,
# not theorised. `ln -sfn` is unlink+symlink: a microsecond with no `current`,
# during which termiod serves no files rather than the wrong ones.
link="$root/.current.$$"
ln -s "$version_dir" "$link"
if mv -T "$link" "$root/current" 2>/dev/null; then
  :
else
  rm -f "$link"
  ln -sfn "$version_dir" "$root/current"
fi

if [ "$keep" -gt 0 ]; then
  # shellcheck disable=SC2012
  ls -1dt "$root"/*-g* 2>/dev/null | tail -n "+$((keep + 1))" | while read -r old; do
    [ "$old" = "$target" ] && continue
    echo "pruning $(basename "$old")"
    rm -rf "$old"
  done
fi

echo
echo "staged $root/current -> $version_dir"
find "$target" -type f -print | sed "s|^$target/|  |" | sort
echo
echo "Ship it with:"
echo "  rsync -a --delete $root/$version_dir/ <host>:~/.local/share/termiod/web/$version_dir/"
echo "  ssh <host> 'ln -sfn $version_dir ~/.local/share/termiod/web/current'"
echo "and point the unit at ~/.local/share/termiod/web/current."
