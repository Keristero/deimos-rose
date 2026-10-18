#!/usr/bin/env bash
# Checks that plugins load from their libraries as they did compiled in
# (decisions.md D85), with no window, so CI runs it on both systems:
#
#  1. The game with every library registers exactly what the game with
#     every plugin compiled in does: the same plugins, ids and versions,
#     and the same registration hash, which netplay peers compare.
#  2. The game alone, with only Classic Levels' content beside it,
#     registers no code plugin and still starts.
#  3. A library built from other sources is refused, by name and reason,
#     and the game goes on without it; so is a library that is not a
#     plugin.
#
# Needs `mise run build` (or build:windows) and `mise run build:static`.
set -euo pipefail
cd "$(dirname "$0")/../.."
EXT=${DR_EXT:-}
BIN=$DR_BUILD/deimos$EXT
STATIC=$DR_BUILD/static/deimos$EXT
for b in "$BIN" "$STATIC"; do
	[ -f "$b" ] || { echo "plugins:check: no $b (mise run build, build:static)" >&2; exit 1; }
done
lib=.so
[ "${OS:-}" = Windows_NT ] && lib=.dll
WORK=$DR_BUILD/plugins-check
rm -rf "$WORK"
mkdir -p "$WORK"
fail() { echo "plugins:check: $1" >&2; exit 1; }

# 1. Libraries against compiled in.
"$BIN" -list-plugins >"$WORK/libs.txt" 2>"$WORK/libs.err" || { cat "$WORK/libs.err" >&2; fail "the game with the libraries did not load them all"; }
"$STATIC" -list-plugins >"$WORK/static.txt" 2>"$WORK/static.err" || { cat "$WORK/static.err" >&2; fail "the static game failed"; }
if ! diff -u "$WORK/static.txt" "$WORK/libs.txt"; then
	fail "the libraries register otherwise than the plugins compiled in (above: - compiled in, + libraries)"
fi
n=$(grep -c '^plugin ' "$WORK/libs.txt")
echo "plugins:check: $n plugins, $(grep '^registration' "$WORK/libs.txt"), the same from libraries as compiled in"

# A game folder of its own, as a release lays one out (mise run dist).
alone=$WORK/alone
mkdir -p "$alone/plugins"
cp "$BIN" "$alone/"
bash tools/plugins/raylib_lib.sh "$alone"
cp -r plugins/classic_levels "$alone/plugins/"

# 2. The core alone.
(cd "$alone" && DR_PLUGINS="$alone/plugins" "./deimos$EXT" -list-plugins) >"$WORK/alone.txt" 2>"$WORK/alone.err" ||
	{ cat "$WORK/alone.err" >&2; fail "the game alone did not start"; }
[ "$(grep '^plugin ' "$WORK/alone.txt" | cut -d' ' -f3)" = classic_levels ] ||
	{ cat "$WORK/alone.txt" >&2; fail "the game alone registered more than Classic Levels"; }
echo "plugins:check: the game alone registers Classic Levels' content and nothing else"

# 3. A library from other sources, and one that is not a plugin.
OUT="$alone/plugins" ABI=0123456789abcdef bash tools/plugins/plugin_libs.sh extra_prefs >/dev/null
mkdir -p "$alone/plugins/not_a_plugin"
cp "$alone"/*raylib* "$alone/plugins/not_a_plugin/not_a_plugin$lib"
if (cd "$alone" && DR_PLUGINS="$alone/plugins" "./deimos$EXT" -list-plugins) >"$WORK/refused.txt" 2>"$WORK/refused.err"; then
	fail "the game took a library built from other sources without a word"
fi
grep -q "extra_prefs$lib: built from other sources (0123456789abcdef)" "$WORK/refused.err" ||
	{ cat "$WORK/refused.err" >&2; fail "the stale library was not refused for its ABI"; }
grep -q "not_a_plugin$lib: not a plugin" "$WORK/refused.err" ||
	{ cat "$WORK/refused.err" >&2; fail "the library that is not a plugin was not refused"; }
grep -q '^plugin .* extra_prefs ' "$WORK/refused.txt" && fail "the refused library registered anyway"
grep -q '^registration' "$WORK/refused.txt" || fail "the game did not go on without the refused libraries"
echo "plugins:check: a library from other sources, and one that is not a plugin, are refused and the game goes on"
