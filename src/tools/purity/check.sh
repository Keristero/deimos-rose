#!/usr/bin/env bash
# The simulation must stay deterministic, headless and side-effect free:
# replayable films, rollback netcode and fast tests all depend on it.
# Enforced here rather than by good intentions.
set -euo pipefail
SIM="${DR_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/sim"
[ -d "$SIM" ] || { echo "purity: no sim/ directory yet"; exit 0; }
BANNED='vendor:raylib|core:os|core:fmt|core:time|core:math/rand|core:thread|core:net'
if grep -rnE "^[[:space:]]*(import|@\(.*\))?[[:space:]]*import[[:space:]]+\"($BANNED)" "$SIM" 2>/dev/null; then
    echo "purity: sim/ must not import rendering, I/O, wall-clock time or ambient RNG" >&2
    exit 1
fi
if grep -rnE "\"($BANNED)\"" "$SIM" 2>/dev/null; then
    echo "purity: banned package referenced in sim/" >&2
    exit 1
fi
echo "purity: sim/ is clean"
