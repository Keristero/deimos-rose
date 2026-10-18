#!/usr/bin/env bash
# Renders every menu-shot scenario a tree knows into OUT, one PNG each, with
# that tree's own build, assets and plugins: ROOT is its src/ (this one by
# default; `mise run ref` prints another's). The names are read from the
# source, so an older tree without this script can be rendered too: the
# cases of game/main.odin's run_menu_shot, and every ui.shot_register and
# ui.menu_shot_register call. A name that writes no image is listed, not
# fatal.
set -euo pipefail
# KEY=value arguments (`mise run <task> A=x`) set KEY, as the environment does.
for a in "$@"; do case "$a" in [A-Z]*=*) export "$a" ;; esac; done
ROOT="$(cd "${ROOT:-$DR_SRC}" && pwd)"
OUT="${OUT:?OUT=<directory> is required}"
BIN="$ROOT/build/deimos${DR_EXT:-}"
[ -x "$BIN" ] || { echo "menu-shots: no build at $BIN (mise run build there)" >&2; exit 1; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)" # the game runs in ROOT, so a relative OUT would land there
names=$( {
  awk '/^run_menu_shot ::/ {on = 1} on && /^}/ {on = 0} on' "$ROOT/game/main.odin" |
    grep -E '^\s*case "' | grep -oE '"[^"]+"' | tr -d '"'
  grep -rhoE '(menu_)?shot_register\(\{name = "[^"]+"' "$ROOT/plugins" "$ROOT/ui" "$ROOT/game" 2>/dev/null |
    grep -oE '"[^"]+"' | tr -d '"'
} | sort -u)
XVFB=()
if command -v xvfb-run >/dev/null; then XVFB=(env DISPLAY= xvfb-run -a -s "-screen 0 1280x1024x24"); fi
made=0 missing=()
for name in $names; do
  rm -f "$OUT/$name.png"
  (cd "$ROOT" && "${XVFB[@]}" env DR_ASSETS="$ROOT/assets" DR_PLUGINS="$ROOT/plugins" \
    DR_MENU_SHOT="$name" DR_SHOT="$OUT/$name" "$BIN" >/dev/null 2>&1) || true
  if [ -f "$OUT/$name.png" ]; then made=$((made + 1)); else missing+=("$name"); fi
done
echo "menu-shots: $made images in $OUT"
[ ${#missing[@]} -eq 0 ] || echo "menu-shots: no image for ${missing[*]}"
