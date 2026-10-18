#!/usr/bin/env bash
# Extract orig/deimos_addons.sit (a 2024 bundle of fan mods, demo films,
# desktop pictures, music and the Apple bundle update) into work/addons/.
#
# The bundle is StuffIt 5 holding further .sit/.hqx/.zip archives; `unar`
# opens all of them. One of those, misc/DeimosRising_bundle_update.sit, is a
# Mac HFS (not HFS+) disk image, which neither unar nor 7-Zip read; hfsutils
# does. It holds "Deimos Bundle Update 1.0.6", a PowerPC PEF build, copied out
# to work/addons/bundle106/app.data (data fork only; the resource fork is
# 151,760 bytes of Mac UI).
#
# Nothing in the bundle is 3D source art: see
# notes/headless-3d-to-2d-findings.md.
#
# Usage: tools/extract_addons.sh [archive] [destdir]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/orig/deimos_addons.sit}"
DEST="${2:-$ROOT/work/addons}"

[ -f "$SRC" ] || { echo "archive not found: $SRC" >&2; exit 1; }
for tool in unar hmount hcopy humount; do
    command -v "$tool" >/dev/null || { echo "missing $tool (unar, hfsutils)" >&2; exit 1; }
done

mkdir -p "$DEST"
unar -q -f -o "$DEST" "$SRC" >/dev/null

# Each nested archive unpacks beside itself, into <name>.x/.
find "$DEST/deimos_addons" \( -name '*.sit' -o -name '*.hqx' -o -name '*.zip' \) -print0 |
while IFS= read -r -d '' f; do
    d="${f%.*}.x"
    mkdir -p "$d"
    unar -q -f -o "$d" "$f" >/dev/null
done

# hfsutils keeps its mounted-volume state in $HOME/.hcwd; give it a throwaway
# home so a failed run leaves nothing mounted behind.
HFSHOME="$(mktemp -d)"
trap 'HOME="$HFSHOME" humount >/dev/null 2>&1 || true; rm -rf "$HFSHOME"' EXIT
SMI="$DEST/deimos_addons/misc/DeimosRising_bundle_update.x/Deimos Rising Bundle Update.smi"
mkdir -p "$DEST/bundle106"
HOME="$HFSHOME" hmount "$SMI" >/dev/null
HOME="$HFSHOME" hcopy -r ":Deimos Bundle Update 1.0.6" "$DEST/bundle106/app.data"
HOME="$HFSHOME" hcopy -r ":Read Me.txt" "$DEST/bundle106/readme.txt"

echo "extracted to $DEST"
