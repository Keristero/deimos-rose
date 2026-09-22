#!/usr/bin/env bash
# Screenshot the original at a named menu screen, for comparison with our own
# renderer at the same screen (see menu_compare.sh).
#
# Usage: [MENU=main] menu_shot.sh
#
# Reaching a screen from boot (a mouse/key sequence) is defined per MENU
# below; each faithful-menu stage (docs/phase-7-faithful-menus.md) adds its
# own case as it lands. "main" needs nothing -- the original boots straight
# to the main menu.
source "$(dirname "$0")/common.sh"

[ -d "$DR_WINE/prefix/drive_c/DR" ] || { echo "run 'mise run oracle:prefix' first" >&2; exit 1; }
ensure_image
MENU="${MENU:-main}"
out="$DR_WINE/menus/$MENU"; rm -rf "$out"; mkdir -p "$out"

case "$MENU" in
    main) reach="" ;;
    *) echo "unknown MENU '$MENU' -- add its click-through to menu_shot.sh" >&2; exit 1 ;;
esac

wine_run "$DISPLAY_AND_AUDIO"'
cd /w/prefix/drive_c/DR
wine DeimosRising.exe >/w/menus/'"$MENU"'/wine.log 2>&1 &
sleep 15
'"$reach"'
wid=$(xdotool search --name "Deimos Rising" | head -1)
xwd -id "$wid" -silent | convert xwd:- +repage /w/menus/'"$MENU"'/orig.png
wineserver -k; sleep 3'
ls "$out/orig.png" 2>/dev/null || { echo "no capture -- see $out/wine.log" >&2; exit 1; }
