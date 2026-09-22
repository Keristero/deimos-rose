#!/usr/bin/env bash
# Play the original's demo films under gdb and record RNG activity per step.
# Usage: [DETAIL=1] [STEPS=n] [DEMOS=n] [OUT=name] trace.sh [max seconds]
#   DETAIL=1 also logs entry to key functions (see trace.py); STEPS=n logs
#   only the first n steps of each film; DEMOS=n stops after n films;
#   OUT names the output directory under $DR_WINE (default "traces");
#   ENTITY=n also logs that entity's position every step.
# Writes $DR_WINE/traces/trace.txt (see trace.py for the format), plus a
# screenshot a minute so a stalled or crashed run is visible.
source "$(dirname "$0")/common.sh"

[ -d "$DR_WINE/prefix/drive_c/DR" ] || { echo "run 'mise run oracle:prefix' first" >&2; exit 1; }
ensure_image
secs="${1:-1800}"
# Distinct films to capture: the shipped demos de01..de04.
DEMOS="${DEMOS:-4}"
name="${OUT:-traces}"
out="$DR_WINE/$name"; rm -rf "$out"; mkdir -p "$out"
cp "$(dirname "$0")/trace.py" "$out/trace.py"

# SYS_PTRACE so gdb may attach to a process it did not start.
podman run --rm --network=none --cap-add=SYS_PTRACE -v "$DR_WINE:/w:z" \
    -e WINEPREFIX=/w/prefix -e HOME=/w "$IMAGE" bash -c "$DISPLAY_AND_AUDIO"'
cd /w/prefix/drive_c/DR
wine DeimosRising.exe >/w/'"$name"'/wine.log 2>&1 &
sleep 15
pid=$(ps -eo pid,args | awk "\$2==\"DeimosRising.exe\" {print \$1; exit}")
[ -n "$pid" ] || { echo "game did not start" >&2; exit 1; }
gdb -q -batch -p "$pid" -ex "set pagination off" \
    -ex "handle all nostop noprint pass" \
    -ex "set \$trace_out=\"/w/'"$name"'/trace.txt\"" \
    -ex "set \$trace_detail='"${DETAIL:-0}"'" -ex "set \$trace_steps='"${STEPS:-0}"'" \
    -ex "set \$trace_entity='"${ENTITY:-0}"'" \
    -ex "source /w/'"$name"'/trace.py" -ex continue >/w/'"$name"'/gdb.log 2>&1 &
sleep 8
# DEMOS on the title menu. The game polls button state, so an instantaneous
# XTest click is missed; hold it briefly. Each film returns to the menu when
# it ends, so click again whenever the trace stops growing, until every demo
# seed has appeared or time runs out.
click() { xdotool mousemove 324 349; sleep 0.5; xdotool mousedown 1; sleep 0.3; xdotool mouseup 1; }
click; last=0; idle=0; shot=0
for ((t = 0; t < '"$secs"'; t += 5)); do
    sleep 5
    n=$(wc -l < /w/'"$name"'/trace.txt)
    if [ "$n" = "$last" ]; then idle=$((idle + 5)); else idle=0; last=$n; fi
    if [ $((t % 60)) = 0 ]; then shot=$((shot + 1)); xwd -root -silent | convert xwd:- -crop 640x480+0+0 +repage /w/'"$name"'/shot$shot.png; fi
    [ "$(grep "^S" /w/'"$name"'/trace.txt | sort -u | wc -l)" -ge '"$DEMOS"' ] && [ $idle -ge 10 ] && break
    [ $idle -ge 10 ] && { click; idle=0; }
done
wineserver -k; sleep 3'
grep -c "^I" "$out/trace.txt" | sed "s/^/GetInputs calls: /"
