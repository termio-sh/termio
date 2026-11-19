#!/usr/bin/env bash
# Print Chrome's live window rect as "X Y W H", in the same screen points
# `screencapture -R` and `System Events click at` take.
#
# Read live on every call rather than cached: the window can be moved or resized
# between frames, and a stale rect silently captures the wrong part of the
# screen instead of failing.
#
# Usage: chrome-rect.sh
#   CHROME_APP_NAME  process name (default: Google Chrome)
set -euo pipefail

APP="${CHROME_APP_NAME:-Google Chrome}"

BOUNDS=$(osascript <<EOF
tell application "System Events" to tell process "$APP"
  set p to position of window 1
  set s to size of window 1
  return (((item 1 of p) as integer) as text) & " " & (((item 2 of p) as integer) as text) & " " & (((item 1 of s) as integer) as text) & " " & (((item 2 of s) as integer) as text)
end tell
EOF
)

echo "$BOUNDS"
