#!/usr/bin/env bash
# Append ONE frame to a recording session: capture Chrome's window into
# <session>/frame-NNNN.png.
#
# One frame per call, numbered in call order, is what makes an agent-driven
# recording deterministic: you act, you snap, you act, you snap. No timer can
# race the page into the wrong state, and a frame is never captured mid-action.
# For motion nothing drives (a CSS animation, a spinner) use chrome-burst.sh.
#
# The captured region is the window rect in points, so a point read off any
# frame is WINDOW-RELATIVE and can be handed straight to chrome-click.sh.
#
# Usage: chrome-snap.sh <session-dir> [label]
#   CHROME_APP_NAME  process name (default: Google Chrome)
set -euo pipefail

DIR="${1:?usage: chrome-snap.sh <session-dir> [label]}"
LABEL="${2:-}"
mkdir -p "$DIR"

read -r X Y W H < <("$(dirname "$0")/chrome-rect.sh")

# Frame number comes from what is already on disk, so separate calls — and
# separate agent turns — keep appending to the same session in order.
NEXT=$(printf '%04d' "$(( $(find "$DIR" -maxdepth 1 -name 'frame-*.png' | wc -l | tr -d ' ') + 1 ))")
OUT="$DIR/frame-$NEXT.png"

# Checked explicitly rather than left to `set -e`: without Screen Recording
# permission screencapture exits non-zero with only "could not create image from
# rect", and an aborted script would never say where to fix that. An empty file
# is the same fault seen from the other side, so both land on the same message.
if ! screencapture -o -x -R"${X},${Y},${W},${H}" "$OUT" 2>/dev/null || [[ ! -s "$OUT" ]]; then
  rm -f "$OUT"
  echo "screencapture failed for rect ${X},${Y},${W},${H}." >&2
  echo "Almost always Screen Recording permission: System Settings → Privacy & Security →" >&2
  echo "Screen Recording → enable the app running this shell (termio / Terminal / iTerm), then" >&2
  echo "RESTART that app — the grant only takes effect on relaunch." >&2
  echo "Verify with: screencapture -x /tmp/probe.png" >&2
  exit 1
fi

echo "$OUT  (window ${X},${Y} ${W}x${H})${LABEL:+  $LABEL}"
