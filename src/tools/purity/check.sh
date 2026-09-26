#!/usr/bin/env bash
# The simulation must stay deterministic, headless and side-effect free:
# replayable films, rollback netcode and fast tests all depend on it.
# Enforced here rather than by good intentions.
#
# The ECS library the sim is built on, and the sim half of every plugin,
# run inside the simulation step, so they are held to the same rule. A
# plugin's presentation lives in its view/ subfolder, which is exempt.
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
        find "$SRC/plugins" -name '*.odin' -not -path '*/view/*' -printf '%h\n' | sort -u)
fi
BANNED='vendor:raylib|core:os|core:fmt|core:time|core:math/rand|core:thread|core:net|dr:game|dr:render|dr:ui|dr:prefs|dr:net'
for d in "${DIRS[@]}"; do
    # Only this folder's own files: a plugin's view/ is a separate package.
    files=$(find "$d" -maxdepth 1 -name '*.odin')
    [ -n "$files" ] || continue
    # shellcheck disable=SC2086
    if grep -nE "\"($BANNED)\"" $files; then
        echo "purity: ${d#"$SRC"/} must not import rendering, I/O, wall-clock time, ambient RNG or presentation" >&2
        exit 1
    fi
done
echo "purity: sim/ and its dependencies are clean"
