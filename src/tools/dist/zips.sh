#!/usr/bin/env bash
# Splits the release folder (mise run dist) into the downloads a release
# carries, Phase 10 stage 5, decisions.md D87. Each zip holds a deimos/
# folder, so every one unzips over the same game folder:
#
#   deimos-<ver>-<os>-amd64.zip                the game: the original, and
#                                              nothing else (Classic Levels)
#   deimos-<ver>-<os>-amd64-editor.zip         the level editor, with its
#                                              models and materials
#   deimos-<ver>-<os>-amd64-plugin-<name>.zip  a plugin, with every plugin it
#                                              needs
#
# A plugin's zip carries its dependencies, content and library, because a
# library carries its dependencies' code (D85) and registers them whether
# or not their folders are there: chaingun.so alone registers New Weapons,
# whose weapons are in plugins/new_weapons. Zips overlap where plugins
# share a dependency; the files are the same build's, so unzipping both
# changes nothing.
#
# The dependencies are what the game itself registers (-list-plugins), run
# in the release folder. A plugin folder with nothing but its manifest
# (HD Textures, whose textures hd:textures makes locally) has no zip.
#
# OUT=dir (default zips/), VER= (default tools/version/version.sh),
# PLATFORM= linux or windows (default this one's). Not OS=: Windows sets
# OS=Windows_NT for every process, and the first release's Windows zips
# were named for it.
set -euo pipefail
for a in "$@"; do case "$a" in [A-Z]*=*) export "$a" ;; esac; done
cd "$(dirname "$0")/../.."
SRC=$PWD
DIST=$SRC/dist/deimos
OUT=${OUT:-$SRC/zips}
VER=${VER:-$(bash tools/version/version.sh)}
if [ -z "${PLATFORM:-}" ]; then
	case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) PLATFORM=windows ;; *) PLATFORM=linux ;; esac
fi
EXE=
[ "$PLATFORM" = windows ] && EXE=.exe
[ -x "$DIST/deimos$EXE" ] || { echo "zips: no release folder at $DIST (mise run dist)" >&2; exit 1; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
base="deimos-$VER-$PLATFORM-amd64"

# zip_paths <zip> <path under dist/deimos, one per argument...>: a zip of
# those paths, each under deimos/. Info-ZIP keeps the exec bit. The Windows
# runner has 7-Zip instead, which names a folder given as a path by its
# last part, so there the paths are copied under a deimos/ of their own
# first and that is zipped, as a whole release folder always was.
zip_paths() {
	local zip=$1 stage
	shift
	rm -f "$zip"
	if command -v zip >/dev/null; then
		(cd "$DIST/.." && zip -9qr "$zip" "${@/#/deimos/}")
	else
		stage=$(mktemp -d)
		for p in "$@"; do
			mkdir -p "$stage/deimos/$(dirname "$p")"
			cp -r "$DIST/$p" "$stage/deimos/$p"
		done
		(cd "$stage" && 7z a -bso0 -mx=9 "$zip" deimos)
		rm -rf "$stage"
	fi
	echo "zips: $(basename "$zip") $(du -k "$zip" | cut -f1) KB"
}

# Every registered plugin and its direct dependencies, "name dep dep...".
declare -A deps=()
while read -r name list; do
	deps[$name]=$list
done < <(cd "$DIST" && "./deimos$EXE" -list-plugins |
	sed -nE 's/^plugin [0-9]+ ([a-z0-9_]+) .* deps \[([^]]*)\] .*/\1 \2/p' | tr -d '",')

# needs <name>: the plugin and everything it needs, once each.
needs() {
	local -A seen=()
	local todo=("$1") p
	while [ ${#todo[@]} -gt 0 ]; do
		p=${todo[0]}
		todo=("${todo[@]:1}")
		[ -n "${seen[$p]:-}" ] && continue
		seen[$p]=1
		# shellcheck disable=SC2206
		todo+=(${deps[$p]:-})
	done
	printf '%s\n' "${!seen[@]}" | sort
}

# What only the level editor reads: its model and material libraries and
# the bases measured from the maps. The game imports no dr:terrain, which
# reads them, and names none of these folders.
EDITOR_ASSETS=(models materials bases)
editor=()
[ -f "$DIST/deimos-editor$EXE" ] && editor=("deimos-editor$EXE")

core=("deimos$EXE" plugins/classic_levels)
for f in "$DIST"/*raylib*; do
	[ -f "$f" ] && core+=("$(basename "$f")")
done
for a in "$DIST"/assets/*; do
	a=assets/$(basename "$a")
	if [ ${#editor[@]} -gt 0 ] && [[ " ${EDITOR_ASSETS[*]} " == *" ${a#assets/} "* ]]; then
		editor+=("$a")
	else
		core+=("$a")
	fi
done
zip_paths "$OUT/$base.zip" "${core[@]}"
[ ${#editor[@]} -eq 0 ] || zip_paths "$OUT/$base-editor.zip" "${editor[@]}"

for dir in "$DIST"/plugins/*/; do
	name=$(basename "$dir")
	[ "$name" = classic_levels ] && continue
	if [ -z "$(find "$dir" -type f ! -name plugin.json ! -name '.*' | head -1)" ]; then
		echo "zips: $name has nothing but its manifest here; no zip"
		continue
	fi
	[ -n "${deps[$name]+set}" ] || { echo "zips: plugins/$name is not a plugin the game registers" >&2; exit 1; }
	paths=()
	while read -r p; do
		[ "$p" = classic_levels ] && continue
		[ -d "$DIST/plugins/$p" ] || { echo "zips: $name needs $p, which the release folder lacks" >&2; exit 1; }
		paths+=("plugins/$p")
	done < <(needs "$name")
	zip_paths "$OUT/$base-plugin-$name.zip" "${paths[@]}"
done
