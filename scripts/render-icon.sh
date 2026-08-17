#!/usr/bin/env bash
# Render packaging/icon-static.svg -> packaging/AppIcon.png at 1024x1024,
# then derive the iOS icon (ios/Sources/Assets.xcassets/AppIcon.appiconset/)
# from the same artwork so the two apps never drift.
#
# The two platforms want opposite canvases from the same artwork:
#   macOS: squircle inset to 824x824 centered with transparent margins (the
#          Apple icon template). A full-bleed icon gets mounted on a bordered
#          system plate on macOS 26.
#   iOS:   full-bleed 1024x1024, no alpha; iOS applies its own mask.
#
# The icon uses SVG gradients + blur filters (frosted-glass look) that
# ImageMagick's built-in SVG renderer drops, so we rasterize through a real
# WebKit/Blink engine. Headless Chrome is the only renderer we can rely on
# being present on a dev Mac; falls back to `rsvg-convert` if installed.
#
# Run this whenever icon-static.svg changes, then ./scripts/build-app.sh to
# fold the PNG into AppIcon.icns (the iOS asset is picked up by the next
# ios/dev-run.sh build).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
svg="$repo_root/packaging/icon-static.svg"
out="$repo_root/packaging/AppIcon.png"
ios_out="$repo_root/ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fullbleed="$(mktemp -t termio-icon).png"

if [[ -x "$chrome" ]]; then
    "$chrome" --headless=new --disable-gpu --force-device-scale-factor=1 \
        --hide-scrollbars --default-background-color=00000000 \
        --window-size=1024,1024 --screenshot="$fullbleed" "file://$svg" >/dev/null 2>&1
elif command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 1024 -h 1024 "$svg" -o "$fullbleed"
else
    echo "error: need headless Chrome or rsvg-convert to render the icon (filters)." >&2
    exit 1
fi

# macOS icon: inset the artwork onto the Apple template. The SVG's own corner
# radius (114 @ 512) lands at ~184 once scaled to 824 — Apple's 185.4 within a
# pixel — so a plain resize + transparent pad reproduces the template shape.
if command -v magick >/dev/null 2>&1; then
    magick "$fullbleed" -resize 824x824 -background none -gravity center \
        -extent 1024x1024 "$out"
    echo "==> Wrote $out"
else
    cp "$fullbleed" "$out"
    echo "warning: ImageMagick not found — wrote $out full-bleed; macOS 26 will draw it on a bordered plate" >&2
fi

# iOS wants the same artwork full-bleed with no alpha channel: flatten the
# transparent corners onto black (the artwork's own edge color, and iOS
# re-rounds the corners itself) and strip the channel — App Store validation
# rejects icons that keep one. Derived from the full-bleed render, NOT the
# inset macOS PNG, or the margins would bake in as black borders.
if command -v magick >/dev/null 2>&1; then
    magick "$fullbleed" -background black -alpha remove -alpha off "PNG24:$ios_out"
    echo "==> Wrote $ios_out"
else
    echo "warning: ImageMagick not found — iOS icon not regenerated ($ios_out is stale)" >&2
fi
