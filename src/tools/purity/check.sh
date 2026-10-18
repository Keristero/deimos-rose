#!/usr/bin/env bash
# The simulation must stay deterministic, headless and side-effect free:
# replayable films, rollback netcode and fast tests all depend on it.
# Enforced here rather than by good intentions.
#
# The ECS library the sim is built on, and the sim half of every plugin,
# run inside the simulation step, so they are held to the same rule. A
# plugin's presentation lives in its view/ subfolder, and its tests in
# tests/, which are exempt.
set -euo pipefail
SRC="${DR_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -d "$SRC/sim" ] || { echo "purity: no sim/ directory yet"; exit 0; }
DIRS=("$SRC/sim")
# The original's systems, each package of them under sim/.
while IFS= read -r d; do DIRS+=("$d"); done < <(
    find "$SRC/sim" -mindepth 2 -name '*.odin' -printf '%h\n' | sort -u)
[ -d "$SRC/third_party/odecs" ] && DIRS+=("$SRC/third_party/odecs")
if [ -d "$SRC/plugins" ]; then
    while IFS= read -r d; do DIRS+=("$d"); done < <(
        find "$SRC/plugins" -name '*.odin' -not -path '*/view/*' -not -path '*/tests/*' -printf '%h\n' | sort -u)
fi
BANNED='vendor:raylib|core:os|core:fmt|core:time|core:math/rand|core:thread|core:net|dr:game|dr:render|dr:ui|dr:prefs|dr:net'
for d in "${DIRS[@]}"; do
    # Only this folder's own files: a plugin's view/ and tests/ are
    # separate packages.
    files=$(find "$d" -maxdepth 1 -name '*.odin')
    [ -n "$files" ] || continue
    # shellcheck disable=SC2086
    if grep -nE "\"($BANNED)\"" $files; then
        echo "purity: ${d#"$SRC"/} must not import rendering, I/O, wall-clock time, ambient RNG or presentation" >&2
        exit 1
    fi
done

# The core names no plugin (AGENTS.md, Phase 10): only game/plugins.odin,
# the list of what is in this build, imports one. A plugin's content and
# behaviour reach the core through its registrations, so the core builds
# and runs without any of them.
CORE=(game sim data render ui prefs net oracle)
for d in "${CORE[@]}"; do
    [ -d "$SRC/$d" ] || continue
    # Relative paths: on Windows $SRC is D:\a\..., which a grep pattern
    # would read as escapes, so the exemption never matched there.
    if (cd "$SRC" && grep -rnE --include='*.odin' '"dr:plugins/' "$d") | grep -v '^game/plugins.odin:'; then
        echo "purity: the core imports a plugin; add an extension point instead (AGENTS.md, Continuous improvement)" >&2
        exit 1
    fi
done

# odecs through its public API only (D47). Its internals change between
# versions, and its encoded query terms (not/or/pair...) share a global
# counter that parallel tests race on, so no code outside the library may
# use either.
INTERNALS='\.records\b|\.signature\b|\.columns\b|column_indices|move_entity|get_or_create_archetype|archetype_get_column|register_component_dynamic|empty_archetype|auto_cleanup_archetypes|ENTITY_INDEX_MASK|ecs\.EntityID\(|ecs\.(not|or|and|none|some|pair|up|down)\('
if grep -rnE --include='*.odin' "$INTERNALS" "$SRC" --exclude-dir=third_party --exclude-dir=build --exclude-dir=.deps; then
    echo "purity: use odecs's public API, not its internals or encoded terms" >&2
    exit 1
fi
# One copy of every package's state (D83). A plugin built as a shared
# library carries its own copy of each package it imports, globals
# included, and only a package's block is bound to the game's. So in any
# package a plugin can import, a mutable global must live in the block or
# be @(rodata). Plugin tests, game/, tools/ and odecs are not imported by
# a plugin's library; odecs keeps nothing but its encoded query terms,
# which the check above already keeps out of reach.
SHARED=()
while IFS= read -r d; do SHARED+=("$d"); done < <(
    find "$SRC/sim" "$SRC/data" "$SRC/prefs" "$SRC/render" "$SRC/ui" "$SRC/plugins" \
        -name '*.odin' -not -path '*/tests/*' -printf '%h\n' 2>/dev/null | sort -u)
BUILD="${DR_BUILD:-$SRC/build}"
mkdir -p "$BUILD"
# Odin on Windows refuses an -out: without .exe (mise.toml's DR_EXT).
odin build "$SRC/tools/globals" -out:"$BUILD/globals${DR_EXT:-}" -o:none
"$BUILD/globals${DR_EXT:-}" -check "${SHARED[@]}"

echo "purity: sim/ and its dependencies are clean, the core imports no plugin, and every package's state is in its block"
