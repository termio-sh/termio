#!/usr/bin/env python3
"""Extract original source from JavaScript source maps that ship with `sourcesContent`.

Dia bundles its Bun/TypeScript "agent-server" as `bun build --compile` Mach-O
binaries, so the compiled `.js` is NOT on disk — but the `.map` files ARE (kept
for Sentry symbolication) and they embed the full original source in
`sourcesContent`. This script reconstructs that source tree.

Usage:
    # default: Dia's agent-server dist, own (non-node_modules) sources only
    python3 extract-sourcemaps.py

    # explicit dist dir + output dir
    python3 extract-sourcemaps.py --dist /path/to/dist --out /tmp/dia-src

    # include node_modules sources too (huge)
    python3 extract-sourcemaps.py --include-node-modules

    # point at specific .map files instead of scanning a dir
    python3 extract-sourcemaps.py --map a.js.map --map b.js.map --out /tmp/out

Exit codes: 0 ok, 1 no maps found, 2 nothing extracted.
"""
import argparse
import json
import os
import sys
from glob import glob

DEFAULT_DIST = (
    "/Applications/Dia.app/Contents/Resources/agent-server-resources/dist"
)


def find_maps(dist: str) -> list[str]:
    return sorted(glob(os.path.join(dist, "**", "*.map"), recursive=True))


def extract(map_path: str, out: str, include_nm: bool) -> int:
    try:
        m = json.load(open(map_path, encoding="utf-8"))
    except (OSError, ValueError) as e:
        print(f"  ! skip {map_path}: {e}", file=sys.stderr)
        return 0
    sources = m.get("sources", [])
    contents = m.get("sourcesContent")
    if not contents:
        print(f"  ! {os.path.basename(map_path)}: no sourcesContent (cannot recover)")
        return 0
    written = 0
    for src, content in zip(sources, contents):
        if content is None:
            continue
        if not include_nm and "node_modules" in src:
            continue
        # normalize ../ and leading slashes so everything lands under `out`
        rel = src.replace("../", "").lstrip("/")
        if not rel:
            continue
        dest = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as f:
            f.write(content)
        written += 1
    return written


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dist", default=DEFAULT_DIST, help="dir to scan for *.map")
    ap.add_argument("--map", action="append", default=[], help="explicit .map path (repeatable)")
    ap.add_argument("--out", default="/tmp/dia-src", help="output dir")
    ap.add_argument("--include-node-modules", action="store_true")
    args = ap.parse_args()

    maps = args.map or find_maps(args.dist)
    if not maps:
        print(f"No .map files found (dist={args.dist}).", file=sys.stderr)
        return 1

    os.makedirs(args.out, exist_ok=True)
    total = 0
    for mp in maps:
        print(f"== {mp}")
        total += extract(mp, args.out, args.include_node_modules)

    print(f"\nExtracted {total} files -> {args.out}")
    if total == 0:
        return 2
    # quick tree of own sources
    for root, _dirs, files in os.walk(args.out):
        for fn in sorted(files):
            print("  " + os.path.relpath(os.path.join(root, fn), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
