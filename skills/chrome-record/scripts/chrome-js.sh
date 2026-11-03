#!/usr/bin/env bash
# Run JavaScript in Chrome's active tab and print what it returns.
#
# This is how you DRIVE the page between frames. Prefer it over clicking
# coordinates: `document.querySelector('#save').click()` keeps working when the
# layout shifts, and it cannot miss and hit whatever moved under the cursor.
# Use chrome-click.sh only for what the DOM cannot reach (Chrome's own chrome:
# the toolbar, a native dialog, an extension popup).
#
# The script is passed as an argv item, not interpolated into the AppleScript,
# so quotes and backslashes in your JS survive intact.
#
# Usage: chrome-js.sh '<javascript>'
#        chrome-js.sh -f <file.js>
#   CHROME_APP_NAME  process name (default: Google Chrome)
set -euo pipefail

APP="${CHROME_APP_NAME:-Google Chrome}"

if [[ "${1:-}" == "-f" ]]; then
  JS=$(cat "${2:?usage: chrome-js.sh -f <file.js>}")
else
  JS="${1:?usage: chrome-js.sh '<javascript>' | chrome-js.sh -f <file.js>}"
fi

set +e
RESULT=$(osascript - "$APP" "$JS" 2>&1 <<'EOF'
on run argv
  set appName to item 1 of argv
  set js to item 2 of argv
  using terms from application "Google Chrome"
    tell application appName
      execute active tab of window 1 javascript js
    end tell
  end using terms from
end run
EOF
)
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  # The one failure everybody hits once: Chrome refuses Apple Events JS until
  # it is switched on, and the error text alone does not say where to go.
  if [[ "$RESULT" == *"not allowed"* || "$RESULT" == *"-1743"* || "$RESULT" == *"Executing JavaScript through AppleScript"* ]]; then
    echo "Chrome is refusing JavaScript from Apple Events." >&2
    echo "Turn it on once: Chrome → View → Developer → Allow JavaScript from Apple Events." >&2
    echo "(If the View menu has no Developer submenu, enable the menu bar's Develop menu first.)" >&2
    exit 2
  fi
  echo "$RESULT" >&2
  exit "$STATUS"
fi

echo "$RESULT"
