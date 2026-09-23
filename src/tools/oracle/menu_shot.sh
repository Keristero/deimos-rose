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
    # Click through Main Menu's "1 PLAYER" button (BTN_FIRST_ROW_Y=186,
    # centred horizontally -- see game/menu_main.odin) to reach Level Select.
    # The original's own window is native 640x480, unlike our port's
    # WINDOW_SCALE=2 display window, so these coordinates are plain logical
    # pixels, not doubled. windowfocus --sync is required first: xdotool
    # click/mousedown alone silently no-ops against an unfocused Xvfb window
    # (see docs/phase-7-faithful-menus.md's Stage 1 verification note).
    level_select) reach='
wid=$(xdotool search --name "Deimos Rising" | head -1)
xdotool windowfocus --sync "$wid"
xdotool mousemove --window "$wid" --sync 320 198
xdotool mousedown --window "$wid" 1
sleep 0.2
xdotool mouseup --window "$wid" 1
sleep 1
' ;;
    # Click through Main Menu's copyright text link (centred, y=447 -- see
    # game/menu_main.odin's text_link_at) to reach Credits. Credits pays a 1s
    # settle pause before page 0 even starts, then a 0.53s fade-in (32 ticks
    # at Interface_FadeRate) -- sleep 2.5 to land well inside page 0's hold
    # (200 ticks =~ 3.3s), same margin the level_select case leaves.
    credits) reach='
wid=$(xdotool search --name "Deimos Rising" | head -1)
xdotool windowfocus --sync "$wid"
xdotool mousemove --window "$wid" --sync 320 451
xdotool mousedown --window "$wid" 1
sleep 0.2
xdotool mouseup --window "$wid" 1
sleep 2.5
' ;;
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
