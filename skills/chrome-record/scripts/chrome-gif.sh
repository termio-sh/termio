#!/usr/bin/env bash
# Assemble a session's frames into a GIF.
#
# Two ffmpeg passes (palettegen + paletteuse) rather than one: a default 256-
# colour GIF of a text-heavy page dithers the type into mush, and unreadable UI
# text defeats the point of recording the UI.
#
# Usage: chrome-gif.sh <session-dir> [out.gif] [fps] [width]
set -euo pipefail

DIR="${1:?usage: chrome-gif.sh <session-dir> [out.gif] [fps] [width]}"
OUT="${2:-$DIR/recording.gif}"
FPS="${3:-4}"
WIDTH="${4:-900}"

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

COUNT=$(find "$DIR" -maxdepth 1 -name 'frame-*.png' | wc -l | tr -d ' ')
[[ "$COUNT" -gt 0 ]] || { echo "no frames in $DIR — capture some with chrome-snap.sh first" >&2; exit 1; }

WORK=$(mktemp -d -t chrome-gif)
trap 'rm -rf "$WORK"' EXIT

# A window resized mid-session leaves frames of different sizes, and ffmpeg's
# image-sequence reader cannot take a size change partway through — it dies with
# "Internal bug, should not have happened", not a size error. A scale filter does
# NOT save it, because the break is upstream of the filter graph. So when the
# sizes actually differ, normalize each frame to disk first and assemble from
# those. Measured, not assumed: the one-size case keeps the single-pass path.
SIZES=$(for f in "$DIR"/frame-*.png; do sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/ {printf "%s ", $2} END {print ""}'; done | sort -u | wc -l | tr -d ' ')

SRC="$DIR"
NOTE=""
if [[ "$SIZES" -gt 1 ]]; then
  # The target is the FIRST frame's shape — the geometry the recording started
  # in. `scale=W:-2` is not enough on its own: it preserves each frame's OWN
  # aspect, so a resized window still normalizes to a different height (900x564
  # vs 900x562) and ffmpeg dies exactly as before. Fit inside the target and pad
  # the remainder, so a resize letterboxes instead of stretching the page.
  FIRST=$(find "$DIR" -maxdepth 1 -name 'frame-*.png' | sort | head -1)
  # The trailing newline is load-bearing: `read` returns non-zero at EOF without
  # one, and `set -e` then kills the script even though FW/FH were populated.
  read -r FW FH < <(sips -g pixelWidth -g pixelHeight "$FIRST" | awk '/pixel/ {printf "%s ", $2} END {print ""}')
  TARGET_H=$(awk -v w="$WIDTH" -v fw="$FW" -v fh="$FH" 'BEGIN { h = int(w * fh / fw); print h % 2 ? h + 1 : h }')

  mkdir -p "$WORK/norm"
  for f in "$DIR"/frame-*.png; do
    ffmpeg -loglevel error -y -i "$f" \
      -vf "scale=${WIDTH}:${TARGET_H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${WIDTH}:${TARGET_H}:(ow-iw)/2:(oh-ih)/2:color=black" \
      "$WORK/norm/$(basename "$f")"
  done
  SRC="$WORK/norm"
  NOTE=", normalized $SIZES frame sizes to ${WIDTH}x${TARGET_H}"
fi

FILTER="scale=${WIDTH}:-2:flags=lanczos"
PALETTE="$WORK/palette.png"

ffmpeg -loglevel error -y -framerate "$FPS" -pattern_type glob -i "$SRC/frame-*.png" \
  -vf "$FILTER,palettegen=stats_mode=diff" "$PALETTE"
ffmpeg -loglevel error -y -framerate "$FPS" -pattern_type glob -i "$SRC/frame-*.png" -i "$PALETTE" \
  -lavfi "$FILTER [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=3" "$OUT"

BYTES=$(stat -f%z "$OUT")
echo "$OUT  ($COUNT frames, ${FPS}fps, ${WIDTH}px wide, $(( BYTES / 1024 ))KB$NOTE)"
