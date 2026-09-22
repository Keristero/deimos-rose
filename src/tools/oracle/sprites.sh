#!/usr/bin/env bash
# Dump the frame dimensions of every sprite the original has loaded, after a
# demo has been running long enough to load a level's sprites.
# Writes $DR_WINE/sprites.tsv.
source "$(dirname "$0")/common.sh"

[ -d "$DR_WINE/prefix/drive_c/DR" ] || { echo "run 'mise run oracle:prefix' first" >&2; exit 1; }
ensure_image
cp "$(dirname "$0")/sprites.py" "$DR_WINE/sprites.py"

podman run --rm --network=none --cap-add=SYS_PTRACE -v "$DR_WINE:/w:z" \
    -e WINEPREFIX=/w/prefix -e HOME=/w "$IMAGE" bash -c "$DISPLAY_AND_AUDIO"'
cd /w/prefix/drive_c/DR
wine DeimosRising.exe >/w/sprites-wine.log 2>&1 &
sleep 15
xdotool mousemove 324 349; sleep 0.5; xdotool mousedown 1; sleep 0.3; xdotool mouseup 1
sleep 40
pid=$(ps -eo pid,args | awk "\$2==\"DeimosRising.exe\" {print \$1; exit}")
gdb -q -batch -p "$pid" -ex "set pagination off" \
    -ex "set \$sprites_out=\"/w/sprites.tsv\"" \
    -ex "source /w/sprites.py" -ex detach >/w/sprites-gdb.log 2>&1
wineserver -k; sleep 2'
wc -l "$DR_WINE/sprites.tsv"
