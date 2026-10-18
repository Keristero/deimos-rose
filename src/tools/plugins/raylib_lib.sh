#!/usr/bin/env bash
# Copies raylib's shared library from Odin's vendor tree into DIR (default
# $DR_BUILD), beside the game. The game and every plugin library draw
# through one raylib -- one window, one GL context, one set of loaded
# textures -- so the game links it shared (-define:RAYLIB_SHARED=true)
# and finds it beside itself: RUNPATH $ORIGIN on Linux, the
# application's folder on Windows (decisions.md D85).
set -euo pipefail
DIR=${1:-$DR_BUILD}
vendor="$(odin root)/vendor/raylib"
if [ "${OS:-}" = Windows_NT ]; then
	lib="$vendor/windows/raylib.dll"
elif [ "$(uname)" = Darwin ]; then
	lib="$vendor/macos/libraylib.600.dylib"
else
	lib="$vendor/linux/libraylib.so.600"
fi
[ -f "$lib" ] || { echo "raylib_lib: no $lib in this Odin" >&2; exit 1; }
mkdir -p "$DIR"
cp "$lib" "$DIR/"
