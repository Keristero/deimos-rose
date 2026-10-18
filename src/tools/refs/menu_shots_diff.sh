#!/usr/bin/env bash
# Compares two menu-shots:all folders, A (the base) and B, byte for byte.
# A difference is not yet a regression: particles take random directions,
# so render the base twice and see whether the same names differ there.
set -euo pipefail
# KEY=value arguments (`mise run <task> A=x`) set KEY, as the environment does.
for a in "$@"; do case "$a" in [A-Z]*=*) export "$a" ;; esac; done
: "${A:?A=<base folder> is required}" "${B:?B=<folder> is required}"
same=0 differ=() only_a=() only_b=()
for f in "$A"/*.png; do
  n=$(basename "$f" .png)
  if [ ! -f "$B/$n.png" ]; then only_a+=("$n")
  elif cmp -s "$f" "$B/$n.png"; then same=$((same + 1))
  else differ+=("$n"); fi
done
for f in "$B"/*.png; do
  n=$(basename "$f" .png)
  [ -f "$A/$n.png" ] || only_b+=("$n")
done
echo "menu-shots:diff: $same identical, ${#differ[@]} differ"
[ ${#differ[@]} -eq 0 ] || echo "  differ: ${differ[*]}"
[ ${#only_a[@]} -eq 0 ] || echo "  only in A: ${only_a[*]}"
[ ${#only_b[@]} -eq 0 ] || echo "  only in B: ${only_b[*]}"
