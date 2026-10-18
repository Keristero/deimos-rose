#!/usr/bin/env bash
# Checks the downloads zips.sh made (decisions.md D87), as a player installs
# them, with no window, so CI runs it on both systems:
#
#  1. The game's zip alone starts, and registers Classic Levels and
#     nothing else.
#  2. Each plugin's zip, unzipped over it, loads every library it brings
#     and finds every plugin's content (-list-plugins exits 0), and turns
#     on what it is for: the plugin is registered, with exactly the
#     plugins it brings.
#  3. All of them together are the release folder, file for file: nothing
#     the full game has is in no download.
#
# IN=dir (default zips/) holds the zips; the release folder is dist/deimos.
set -euo pipefail
for a in "$@"; do case "$a" in [A-Z]*=*) export "$a" ;; esac; done
cd "$(dirname "$0")/../.."
SRC=$PWD
IN=$(cd "${IN:-$SRC/zips}" && pwd)
DIST=$SRC/dist/deimos
WORK=${DR_BUILD:-$SRC/build}/dist-check
EXE=
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) EXE=.exe ;; esac
fail() { echo "dist:check: $1" >&2; exit 1; }
# 7-Zip, when there is no unzip, is a Windows program there: Git Bash
# converts a path given alone, not one glued to -o, so that one is converted
# here.
unzip_to() {
	if command -v unzip >/dev/null; then
		unzip -qo "$1" -d "$2"
	else
		mkdir -p "$2"
		7z x -bso0 -y "$1" -o"$(cygpath -w "$2" 2>/dev/null || echo "$2")"
	fi
}
# The plugins a game folder registers; fails unless -list-plugins exits 0.
registered() {
	(cd "$1/deimos" && env -u DR_PLUGINS "./deimos$EXE" -list-plugins) >"$1.txt" 2>"$1.err" || {
		grep -v '^INFO' "$1.err" >&2 || true
		grep 'content missing' "$1.txt" >&2 || true
		return 1
	}
	grep '^plugin ' "$1.txt" | cut -d' ' -f3 | sort
}

core=$(find "$IN" -maxdepth 1 -name 'deimos-*-amd64.zip' | head -1)
[ -n "$core" ] || fail "no game zip in $IN (mise run dist:zips)"
base=${core%.zip}
rm -rf "$WORK"
mkdir -p "$WORK"

# 1. The game alone.
unzip_to "$core" "$WORK/core"
[ "$(registered "$WORK/core")" = classic_levels ] || fail "the game's zip registers more than Classic Levels, or did not start"
echo "dist:check: $(basename "$core") starts alone, with Classic Levels"

# 2. Each plugin over it.
n=0
for zip in "$base"-plugin-*.zip; do
	[ -f "$zip" ] || continue
	name=${zip#"$base"-plugin-}
	name=${name%.zip}
	dir=$WORK/$name
	unzip_to "$core" "$dir"
	unzip_to "$zip" "$dir"
	got=$(registered "$dir") || fail "$name's zip, over the game's, does not load (above)"
	brings=$( (cd "$dir/deimos/plugins" && ls -d */) | tr -d / | sort)
	grep -qx "$name" <<<"$got" || fail "$name's zip does not register $name"
	[ "$got" = "$brings" ] || fail "$name's zip brings $(echo $brings) but registers $(echo $got)"
	n=$((n + 1))
done
echo "dist:check: each of $n plugin zips installs over the game's and registers what it brings"

# 3. Together, the release folder.
all=$WORK/all
for zip in "$IN"/"$(basename "$base")"*.zip; do
	unzip_to "$zip" "$all"
done
# A plugin with nothing but its manifest has no zip (zips.sh).
only=$(diff -rq "$DIST" "$all/deimos" | grep -v '^Only in .*/plugins: ' || true)
skipped=$(diff -rq "$DIST" "$all/deimos" | sed -nE "s|^Only in $DIST/plugins: (.*)|\1|p")
for s in $skipped; do
	[ -z "$(find "$DIST/plugins/$s" -type f ! -name plugin.json | head -1)" ] || only="$only
$s has content but no zip"
done
[ -z "$only" ] || { echo "$only" >&2; fail "the downloads together are not the release folder"; }
echo "dist:check: together they are the release folder, file for file${skipped:+ (no zip for: $(echo $skipped), only a manifest)}"
