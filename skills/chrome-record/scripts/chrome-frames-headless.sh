#!/usr/bin/env bash
# Record a page WITHOUT any Screen Recording permission, by rendering it in
# headless Chrome at successive virtual times.
#
# `--virtual-time-budget=N` renders as if N milliseconds had elapsed, so frames
# come out deterministic and reproducible — the same URL gives byte-identical
# frames on every run, which wall-clock capture never does. Use this for page
# load, CSS animations and transitions.
#
# What it CANNOT do: the user's logged-in session (it runs in its own throwaway
# profile), anything behind a click, and Chrome's own UI. For those, use the
# live path — chrome-js.sh + chrome-snap.sh — which needs Screen Recording.
#
# Usage: chrome-frames-headless.sh <url> <session-dir> [count] [step-ms] [W] [H]
#   CHROME_BIN  chrome executable (default: /Applications/Google Chrome.app/...)
set -euo pipefail

URL="${1:?usage: chrome-frames-headless.sh <url> <session-dir> [count] [step-ms] [W] [H]}"
DIR="${2:?usage: chrome-frames-headless.sh <url> <session-dir> [count] [step-ms] [W] [H]}"
COUNT="${3:-8}"
STEP_MS="${4:-250}"
W="${5:-900}"
H="${6:-600}"
CHROME="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

[[ -x "$CHROME" ]] || { echo "chrome not executable at: $CHROME" >&2; exit 1; }
mkdir -p "$DIR"

PROFILE=$(mktemp -d -t chrome-headless-profile)
trap 'rm -rf "$PROFILE"' EXIT

START=$(find "$DIR" -maxdepth 1 -name 'frame-*.png' | wc -l | tr -d ' ')

for ((i = 1; i <= COUNT; i++)); do
  BUDGET=$(( i * STEP_MS ))
  NEXT=$(printf '%04d' "$(( START + i ))")
  OUT="$DIR/frame-$NEXT.png"

  # Chrome writes the PNG and then, in every version tested here, fails to exit
  # — waiting on the process costs ~15s per frame. So: launch, wait for the file
  # to appear AND stop growing, then kill. Polling the artifact rather than the
  # process is what makes this usable for a sequence.
  "$CHROME" --headless=old --disable-gpu --hide-scrollbars \
    --user-data-dir="$PROFILE" \
    --window-size="${W},${H}" \
    --virtual-time-budget="$BUDGET" \
    --screenshot="$OUT" \
    "$URL" >/dev/null 2>&1 &
  PID=$!

  LAST=-1
  for _ in $(seq 1 120); do
    sleep 0.25
    SIZE=$(stat -f%z "$OUT" 2>/dev/null || echo 0)
    # Two consecutive equal non-zero sizes means the write finished.
    [[ "$SIZE" -gt 0 && "$SIZE" -eq "$LAST" ]] && break
    LAST="$SIZE"
    kill -0 "$PID" 2>/dev/null || break
  done
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true

  if [[ ! -s "$OUT" ]]; then
    rm -f "$OUT"
    echo "headless capture produced nothing at t=${BUDGET}ms — check the URL loads: $URL" >&2
    exit 1
  fi
done

# Report how many of the new frames are actually different. Virtual time does
# NOT sample a running CSS animation evenly — it advances while the page has
# work pending and then stalls, so a long animation can come back as a handful
# of repeated stills. Without this number the GIF just looks stuttery and the
# cause is invisible; with it, you know to record that motion live instead.
DISTINCT=$(md5 -q "$DIR"/frame-*.png | sort -u | wc -l | tr -d ' ')
TOTAL=$(find "$DIR" -maxdepth 1 -name 'frame-*.png' | wc -l | tr -d ' ')
NOTE=""
[[ "$DISTINCT" -lt "$TOTAL" ]] && NOTE="  — only $DISTINCT of $TOTAL frames differ; virtual time did not sample this motion evenly"

echo "$DIR  (+$COUNT frames, virtual time ${STEP_MS}ms..$(( COUNT * STEP_MS ))ms, ${W}x${H})$NOTE"
