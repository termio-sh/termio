#!/usr/bin/env bash
# Open a URL in Chrome, bring it to the front, and report the window rect that
# every later capture will use.
#
# Reuses window 1 rather than spawning a new one, so a recording session keeps
# the same geometry from frame to frame — a window that moves mid-session makes
# the GIF jump even though the page never did.
#
# Usage: chrome-open.sh <url>
#   CHROME_APP_NAME  process name (default: Google Chrome)
set -euo pipefail

APP="${CHROME_APP_NAME:-Google Chrome}"
URL="${1:?usage: chrome-open.sh <url>}"

osascript >/dev/null <<EOF
tell application "$APP"
  activate
  if (count of windows) is 0 then
    make new window
  end if
  set URL of active tab of window 1 to "$URL"
end tell
EOF

# Chrome reports the load as finished before the first paint, so a capture taken
# the instant this returns can still be the previous page. Wait for the tab to
# stop loading, then give the compositor one frame.
osascript >/dev/null <<EOF
tell application "$APP"
  repeat 100 times
    if not (loading of active tab of window 1) then exit repeat
    delay 0.05
  end repeat
end tell
EOF
sleep 0.2

exec "$(dirname "$0")/chrome-rect.sh"
