#!/usr/bin/env bash
# Fail when the String Catalog and the source have drifted apart.
#
# Every UI literal reaches the catalog through `localized("…")` (see
# Sources/termio/App/Localized.swift), and nothing verifies that the key it
# passes actually exists. A missing key doesn't crash or fail the build — it
# silently resolves to the English source string, so a localized pane ships
# half-translated and looks fine to anyone testing in English. That is how six
# keys walked in unnoticed with the custom tunnel relay.
#
# Two checks, both cheap enough for every PR:
#   1. every static `localized("…")` key exists in the catalog
#   2. the checked-in .lproj output matches what the catalog compiles to
#
# Interpolated calls — `localized("\(count) files")` — are skipped: their key
# carries a format specifier whose type this script cannot infer from the text.
# Multi-line (`"""`) literals are skipped too: their key depends on Swift's
# indentation stripping and line continuations, which this scan doesn't model.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root" <<'PYTHON'
import json, pathlib, re, sys

repo_root = pathlib.Path(sys.argv[1])
catalog_path = repo_root / "Sources/termio/Resources/Localizable.xcstrings"
catalog = json.loads(catalog_path.read_text())
known = set(catalog["strings"])

# `localized(` + a single-line Swift string literal. The negative lookahead
# leaves `localized("""` to the multi-line case, which this scan skips.
call = re.compile(r'\blocalized\(\s*"(?!"")((?:[^"\\\n]|\\.)*)"')
escapes = {'\\"': '"', "\\\\": "\\", "\\n": "\n", "\\t": "\t"}

missing, used = {}, set()
for swift in sorted((repo_root / "Sources").rglob("*.swift")):
    for match in call.finditer(swift.read_text()):
        literal = match.group(1)
        if "\\(" in literal:
            continue
        key = literal
        for escaped, plain in escapes.items():
            key = key.replace(escaped, plain)
        used.add(key)
        if key not in known:
            line = swift.read_text()[: match.start()].count("\n") + 1
            missing.setdefault(key, f"{swift.relative_to(repo_root)}:{line}")

# Format keys (from interpolated calls) and multi-line keys come from the call
# shapes the scan skips, so they can't be proven unused here.
orphans = sorted(k for k in known - used if "%" not in k and "\n" not in k)
untranslated = sorted(
    k for k in known if "zh-Hans" not in catalog["strings"][k].get("localizations", {})
)

for key, where in sorted(missing.items()):
    print(f"missing from the catalog: {key!r}\n  used at {where}")
if orphans:
    print(f"note: {len(orphans)} catalog keys are no longer used in Sources:")
    for key in orphans[:10]:
        print(f"  {key!r}")
if untranslated:
    print(f"note: {len(untranslated)} keys have no zh-Hans translation yet")

sys.exit(1 if missing else 0)
PYTHON

# The compiled .lproj resources are checked in because SwiftPM can't compile a
# String Catalog itself; a catalog edit without a recompile ships stale strings.
output_dir="$repo_root/Sources/termio/Resources/Localization"
scratch="$(mktemp -d)"
# compile-strings.sh writes to the checked-in path, so stash a copy and put it
# back however this exits: a check must never leave the tree modified.
cp -R "$output_dir" "$scratch/checked-in"
restore() {
    rm -rf "$output_dir"
    cp -R "$scratch/checked-in" "$output_dir"
    rm -rf "$scratch"
}
trap restore EXIT
"$repo_root/scripts/compile-strings.sh" >/dev/null
if ! diff -r "$scratch/checked-in" "$output_dir" >/dev/null; then
    echo "the compiled .lproj output is stale — run scripts/compile-strings.sh and commit the result"
    exit 1
fi
