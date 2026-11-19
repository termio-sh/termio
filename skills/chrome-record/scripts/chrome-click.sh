#!/usr/bin/env bash
# Click at a WINDOW-RELATIVE point — the same (dx,dy) you measured on a frame
# captured by chrome-snap.sh.
#
# Re-reads Chrome's live origin and adds your offset, so the click lands
# correctly even if the window moved between frames. Never hardcode global
# coords across calls.
#
# Reach for chrome-js.sh first: a DOM click survives a layout shift, this does
# not. This is for what the page cannot reach — the toolbar, a native dialog.
#
# Usage: chrome-click.sh <dx> <dy>
#   CHROME_APP_NAME  process name (default: Google Chrome)
set -euo pipefail

APP="${CHROME_APP_NAME:-Google Chrome}"
DX="${1:?usage: chrome-click.sh <dx> <dy>}"
DY="${2:?usage: chrome-click.sh <dx> <dy>}"

read -r X Y _ _ < <("$(dirname "$0")/chrome-rect.sh")

GX=$(( X + DX ))
GY=$(( Y + DY ))

HIT=$(osascript -e "tell application \"System Events\" to click at {$GX, $GY}" 2>&1 || true)
echo "clicked window-relative ($DX,$DY) -> screen ($GX,$GY)"
[[ -n "$HIT" ]] && echo "hit: $HIT"
