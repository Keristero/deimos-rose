#!/usr/bin/env bash
# Play the original's demo films under gdb and record RNG activity per step.
# Usage: trace.sh [max seconds]   (default 1800)
# Writes $DR_WINE/traces/trace.txt (see trace.py for the format), plus a
# screenshot a minute so a stalled or crashed run is visible.
source "$(dirname "$0")/common.sh"

[ -d "$DR_WINE/prefix/drive_c/DR" ] || { echo "run 'mise run oracle:prefix' first" >&2; exit 1; }
ensure_image
secs="${1:-1800}"
# Distinct films to capture: the shipped demos de01..de04.
DEMOS="${DEMOS:-4}"
out="$DR_WINE/traces"; rm -rf "$out"; mkdir -p "$out"
cp "$(dirname "$0")/trace.py" "$out/trace.py"

# SYS_PTRACE so gdb may attach to a process it did not start.
podman run --rm --network=none --cap-add=SYS_PTRACE -v "$DR_WINE:/w:z" \
    -e WINEPREFIX=/w/prefix -e HOME=/w "$IMAGE" bash -c "$DISPLAY_AND_AUDIO"'
cd /w/prefix/drive_c/DR
wine DeimosRising.exe >/w/traces/wine.log 2>&1 &
sleep 15
pid=$(ps -eo pid,args | awk "\$2==\"DeimosRising.exe\" {print \$1; exit}")
[ -n "$pid" ] || { echo "game did not start" >&2; exit 1; }
gdb -q -batch -p "$pid" -ex "set pagination off" \
    -ex "handle all nostop noprint pass" \
    -ex "set \$trace_out=\"/w/traces/trace.txt\"" \
    -ex "source /w/traces/trace.py" -ex continue >/w/traces/gdb.log 2>&1 &
sleep 8
# DEMOS on the title menu. The game polls button state, so an instantaneous
# XTest click is missed; hold it briefly. Each film returns to the menu when
# it ends, so click again whenever the trace stops growing, until every demo
# seed has appeared or time runs out.
click() { xdotool mousemove 324 349; sleep 0.5; xdotool mousedown 1; sleep 0.3; xdotool mouseup 1; }
click; last=0; idle=0; shot=0
for ((t = 0; t < '"$secs"'; t += 5)); do
    sleep 5
    n=$(wc -l < /w/traces/trace.txt)
    if [ "$n" = "$last" ]; then idle=$((idle + 5)); else idle=0; last=$n; fi
    if [ $((t % 60)) = 0 ]; then shot=$((shot + 1)); xwd -root -silent | convert xwd:- -crop 640x480+0+0 +repage /w/traces/shot$shot.png; fi
    [ "$(grep "^S" /w/traces/trace.txt | sort -u | wc -l)" -ge '"$DEMOS"' ] && [ $idle -ge 10 ] && break
    [ $idle -ge 10 ] && { click; idle=0; }
done
wineserver -k; sleep 3'
grep -c "^I" "$out/trace.txt" | sed "s/^/GetInputs calls: /"
