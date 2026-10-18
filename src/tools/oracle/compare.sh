#!/usr/bin/env bash
# Put our render beside the original's, for the same demo film and step.
# Usage: [FILM=de01] [STEPS=900] [OUT=cmp] compare.sh
#
# Expects `mise run oracle:shot` to have captured the original already; it
# renders our side here. Both windows are 640x480 with the 416-wide play
# field inset at x=32 (render/render.odin's VIEW_X), so that is what gets
# cropped for comparison; our capture is normalised to 640x480 first since it
# may be taken at a different WINDOW_SCALE.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$SRC/../work"
FILM="${FILM:-de01}"
STEPS="${STEPS:-900}"
NAME="${OUT:-cmp}"
mkdir -p "$WORK/shots/cmp"

DISPLAY= xvfb-run -s "-screen 0 1280x1024x24" env \
    DR_ASSETS="$SRC/assets" DR_FILM="$FILM" \
    DR_SHOT="$WORK/shots/cmp/$FILM" DR_SHOT_AT="$STEPS" \
    "$SRC/build/deimos" -classic 2>&1 | grep -E "^wrote|^cannot" || true

for step in ${STEPS//,/ }; do
    printf -v padded "%05d" "$step"
    printf -v ours4 "%04d" "$step"
    orig="$WORK/wine/$NAME/orig-$padded.png"
    ours="$WORK/shots/cmp/$FILM-$ours4.png"
    [ -f "$orig" ] || { echo "no capture of the original at step $step ($orig)"; continue; }
    [ -f "$ours" ] || { echo "our render at step $step is missing"; continue; }
    o="$WORK/shots/cmp/orig-$padded.png"
    u="$WORK/shots/cmp/ours-$padded.png"
    magick "$orig" -crop 416x480+32+0 +repage "$o"
    magick "$ours" -resize 640x480! -crop 416x480+32+0 +repage "$u"
    magick "$o" "$u" +append "$WORK/shots/cmp/side-$padded.png"
    magick "$o" "$u" -compose difference -composite -auto-level "$WORK/shots/cmp/diff-$padded.png"
    echo "step $step: $WORK/shots/cmp/side-$padded.png"
done
