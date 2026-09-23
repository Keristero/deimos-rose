#!/usr/bin/env bash
# Put our render of a menu screen beside the original's.
# Usage: [MENU=main] menu_compare.sh
#
# Expects `mise run oracle:menu-shot` (MENU=<name>) to have captured the
# original already; it renders our side here, headlessly, via DR_MENU_SHOT
# (game/main.odin's run_menu_shot). Both are the full 640x480 logical screen
# -- menus have no score-bar inset to crop, unlike gameplay's compare.sh.
#
# Ours runs with -classic: outside classic mode this port restyles some
# things the original has (the menus' rose backgrounds, the pause menu), and
# a comparison against the original is only meaningful without them.
#
# The AE (absolute error) count is printed as a quick regression signal, but
# per AGENTS.md ("Look at the output"), side.png is the actual check --
# open it.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$SRC/../work"
MENU="${MENU:-main}"
out="$WORK/shots/menus/$MENU"; mkdir -p "$out"

DISPLAY= xvfb-run -s "-screen 0 1280x1024x24" env \
    DR_ASSETS="$SRC/assets" DR_MENU_SHOT="$MENU" DR_SHOT="$out/ours" \
    "$SRC/build/deimos" -classic 2>&1 | grep -E "^wrote|^cannot" || true

orig="$WORK/wine/menus/$MENU/orig.png"
ours="$out/ours.png"
[ -f "$orig" ] || { echo "no capture of the original for $MENU ($orig) -- run: mise run oracle:menu-shot MENU=$MENU" >&2; exit 1; }
[ -f "$ours" ] || { echo "our render of $MENU is missing" >&2; exit 1; }

magick "$ours" -resize 640x480! +repage "$out/ours-norm.png"
magick "$orig" "$out/ours-norm.png" +append "$out/side.png"
magick "$orig" "$out/ours-norm.png" -compose difference -composite -auto-level "$out/diff.png"
ae=$(magick compare -metric AE "$orig" "$out/ours-norm.png" null: 2>&1 || true)
echo "AE (differing pixels, of 307200): $ae"
echo "$out/side.png"
