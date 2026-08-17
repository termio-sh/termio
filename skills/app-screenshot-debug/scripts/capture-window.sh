#!/usr/bin/env bash
# Screenshot just the frontmost termio window, pixel-accurate.
#
# Reads the window's live position/size (so it works no matter where the window
# is or which display it's on), then `screencapture -o -x -R` that region.
# Because the region is captured 1:1 in points, any point you read off the
# resulting image is WINDOW-RELATIVE: image (dx,dy) == screen (originX+dx, originY+dy).
# Pair with click-in-window.sh, which adds the live origin back.
#
# Usage: capture-window.sh [out.png]
#   TERMIO_APP_NAME  process name (default: termio)
set -euo pipefail

APP="${TERMIO_APP_NAME:-termio}"
OUT="${1:-/tmp/termio-shot.png}"

BOUNDS=$(osascript <<EOF
tell application "System Events" to tell process "$APP"
  set p to position of window 1
  set s to size of window 1
  return (((item 1 of p) as integer) as text) & " " & (((item 2 of p) as integer) as text) & " " & (((item 1 of s) as integer) as text) & " " & (((item 2 of s) as integer) as text)
end tell
EOF
)

read -r X Y W H <<< "$BOUNDS"
screencapture -o -x -R"${X},${Y},${W},${H}" "$OUT"
echo "$OUT  (window origin ${X},${Y} size ${W}x${H} — image coords are window-relative)"
