#!/usr/bin/env bash
# Dump the original's U_Math lookup tables from the running game.
#
# U_Math_Init builds them at startup with MSL's atan/sqrtf/sinf/cosf on the
# x87, whose results can differ from any other libm in the last bit. The
# simulation needs them bit for bit, so they are read from memory instead of
# recomputed. Writes $DR_WINE/tables/*.bin (raw little-endian).
source "$(dirname "$0")/common.sh"

[ -d "$DR_WINE/prefix/drive_c/DR" ] || { echo "run 'mise run oracle:prefix' first" >&2; exit 1; }
ensure_image
out="$DR_WINE/tables"; rm -rf "$out"; mkdir -p "$out"

podman run --rm --network=none --cap-add=SYS_PTRACE -v "$DR_WINE:/w:z" \
    -e WINEPREFIX=/w/prefix -e HOME=/w "$IMAGE" bash -c "$DISPLAY_AND_AUDIO"'
cd /w/prefix/drive_c/DR
wine DeimosRising.exe >/w/tables/wine.log 2>&1 &
sleep 15
pid=$(ps -eo pid,args | awk "\$2==\"DeimosRising.exe\" {print \$1; exit}")
[ -n "$pid" ] || { echo "game did not start" >&2; exit 1; }
# Addresses from U_Math_Init (0x402170).
gdb -q -batch -p "$pid" \
    -ex "dump binary memory /w/tables/atan.bin 0x4c6aff 0x4c7aff" \
    -ex "dump binary memory /w/tables/sqrt.bin 0x4c7aff 0x4d7aff" \
    -ex "dump binary memory /w/tables/cos.bin  0x4d7aff 0x4d809f" \
    -ex "dump binary memory /w/tables/sin.bin  0x4d809f 0x4d863f" \
    -ex detach >/w/tables/gdb.log 2>&1
wineserver -k; sleep 2'
ls -l "$out"/*.bin
