#!/usr/bin/env bash
# Capture frames on a timer, for motion no agent action drives — a CSS
# animation, a spinner, a video, a page that settles on its own.
#
# Runs in the FOREGROUND for the requested duration. To record while you drive
# the page, start it with `&` and keep acting; frames land in the same session
# directory chrome-snap.sh uses, so the two can be mixed in one recording.
#
# Usage: chrome-burst.sh <session-dir> <seconds> [fps]
#   CHROME_APP_NAME  process name (default: Google Chrome)
set -euo pipefail

DIR="${1:?usage: chrome-burst.sh <session-dir> <seconds> [fps]}"
SECONDS_TOTAL="${2:?usage: chrome-burst.sh <session-dir> <seconds> [fps]}"
FPS="${3:-4}"
mkdir -p "$DIR"

read -r X Y W H < <("$(dirname "$0")/chrome-rect.sh")

# screencapture itself costs 50-150ms, so the real rate is always under the
# requested one. The interval is the floor, not a guarantee — the assembled GIF
# uses the frame COUNT and its own fps, so a slow capture stretches time rather
# than dropping frames.
INTERVAL=$(awk -v f="$FPS" 'BEGIN { print 1 / f }')
COUNT=$(awk -v s="$SECONDS_TOTAL" -v f="$FPS" 'BEGIN { printf "%d", s * f }')

START=$(find "$DIR" -maxdepth 1 -name 'frame-*.png' | wc -l | tr -d ' ')
for ((i = 1; i <= COUNT; i++)); do
  NEXT=$(printf '%04d' "$(( START + i ))")
  # Fail on the FIRST bad frame rather than spending the whole duration writing
  # nothing: a missing Screen Recording grant fails every frame identically.
  if ! screencapture -o -x -R"${X},${Y},${W},${H}" "$DIR/frame-$NEXT.png" 2>/dev/null \
    || [[ ! -s "$DIR/frame-$NEXT.png" ]]; then
    rm -f "$DIR/frame-$NEXT.png"
    echo "screencapture failed on frame $NEXT — see chrome-snap.sh for the Screen Recording fix" >&2
    exit 1
  fi
  sleep "$INTERVAL"
done

echo "$DIR  (+$COUNT frames at ~${FPS}fps over ${SECONDS_TOTAL}s)"
