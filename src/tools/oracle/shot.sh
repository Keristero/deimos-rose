#!/usr/bin/env bash
# Screenshot the original at an exact game step, for comparison with our own
# renderer at the same step.
#
# Usage: [DEMO=n] [STEPS=a,b,c] [OUT=name] shot.sh [max seconds]
#   DEMO=n    which demo film to let run (1..4, default 1)
#   STEPS     game-time values to capture (DAT_004e4836, which is sim.State's
#             `time`), comma separated, ascending
#   OUT       output directory under $DR_WINE (default "shots")
#
# The game is stopped inside its per-step function, so the front buffer holds
# the frame that step produced; the screenshot is taken while it is stopped.
source "$(dirname "$0")/common.sh"

[ -d "$DR_WINE/prefix/drive_c/DR" ] || { echo "run 'mise run oracle:prefix' first" >&2; exit 1; }
ensure_image
secs="${1:-900}"
DEMO="${DEMO:-1}"
STEPS="${STEPS:-900}"
name="${OUT:-shots}"
out="$DR_WINE/$name"; rm -rf "$out"; mkdir -p "$out"
cp "$(dirname "$0")/shot.py" "$out/shot.py"

podman run --rm --network=none --cap-add=SYS_PTRACE -v "$DR_WINE:/w:z" \
    -e WINEPREFIX=/w/prefix -e HOME=/w "$IMAGE" bash -c "$DISPLAY_AND_AUDIO"'
cd /w/prefix/drive_c/DR
wine DeimosRising.exe >/w/'"$name"'/wine.log 2>&1 &
sleep 15
pid=$(ps -eo pid,args | awk "\$2==\"DeimosRising.exe\" {print \$1; exit}")
[ -n "$pid" ] || { echo "game did not start" >&2; exit 1; }
gdb -q -batch -p "$pid" -ex "set pagination off" \
    -ex "handle all nostop noprint pass" \
    -ex "set \$shot_dir=\"/w/'"$name"'\"" \
    -ex "set \$shot_demo='"$DEMO"'" \
    -ex "set \$shot_steps=\"'"$STEPS"'\"" \
    -ex "source /w/'"$name"'/shot.py" -ex continue >/w/'"$name"'/gdb.log 2>&1 &
sleep 8
# Start the demo loop from the title menu, then let it run. The script writes
# a marker file whenever it is stopped at a requested step; the screenshot has
# to be taken from here, because gdb holds the process still.
click() { xdotool mousemove 324 349; sleep 0.5; xdotool mousedown 1; sleep 0.3; xdotool mouseup 1; }
click
for ((t = 0; t < '"$secs"'; t += 1)); do
    sleep 1
    for f in /w/'"$name"'/at-*.ready; do
        [ -e "$f" ] || continue
        step=$(basename "$f" .ready); step=${step#at-}
        # The window, not the desktop: the game sits at an offset under the
        # window manager, and a desktop crop would compare misaligned images.
        wid=$(xdotool search --name "Deimos Rising" | head -1)
        if [ -n "$wid" ]; then
            xwd -id "$wid" -silent | convert xwd:- +repage /w/'"$name"'/orig-$step.png
        else
            xwd -root -silent | convert xwd:- +repage /w/'"$name"'/orig-$step.png
        fi
        echo "captured step $step"
        mv "$f" "${f%.ready}.done"
    done
    [ -e /w/'"$name"'/finished ] && break
done
wineserver -k; sleep 3'
ls -1 "$out"/orig-*.png 2>/dev/null || echo "no captures -- see $out/gdb.log"
