#!/usr/bin/env bash
# Launch the original under Xvfb and screenshot it at intervals.
# Usage: run.sh [seconds...]   (default: 10 20 40)
# Screenshots land in $DR_WINE/shots/tN.png. Look at them: a process that
# stays running is not a process that works.
source "$(dirname "$0")/common.sh"

[ -d "$DR_WINE/prefix/drive_c/DR" ] || { echo "run 'mise run oracle:prefix' first" >&2; exit 1; }
ensure_image
times="${*:-10 20 40}"
rm -rf "$DR_WINE/shots"; mkdir -p "$DR_WINE/shots"
wine_run "$DISPLAY_AND_AUDIO"'
cd /w/prefix/drive_c/DR
wine DeimosRising.exe >/w/shots/wine.log 2>&1 &
prev=0
for t in '"$times"'; do
    sleep $((t - prev)); prev=$t
    xwd -root -silent | convert xwd:- -crop 640x480+0+0 +repage /w/shots/t$t.png
done
wineserver -k'
ls "$DR_WINE/shots"
if grep -q "Unhandled" "$DR_WINE/shots/wine.log"; then
    grep "Unhandled" "$DR_WINE/shots/wine.log" >&2; exit 1
fi
