#!/usr/bin/env bash
# Locate decompiled functions by name substring (case-insensitive).
#   mise run decomp:find G_Player
#   mise run decomp:find -- -c U_Pak_Open      # -c prints the file contents
set -euo pipefail
OUT_DIR="${DR_DECOMP:?}/export"
INDEX="$OUT_DIR/index.tsv"
[ -f "$INDEX" ] || { echo "no corpus; run 'mise run decomp:export'" >&2; exit 1; }

show=0
if [ "${1:-}" = "-c" ]; then show=1; shift; fi
q="${1:-}"
[ -n "$q" ] || { echo "usage: decomp:find [-c] <name-substring>" >&2; exit 2; }

matches=$(awk -F'\t' -v q="${q,,}" 'NR>1 && index(tolower($4), q) {print}' "$INDEX")
[ -n "$matches" ] || { echo "no match for '$q'"; exit 1; }

if [ "$show" -eq 1 ]; then
    while IFS=$'\t' read -r module rva size name file status; do
        [ "$status" = "ok" ] || { echo "== $name ($status)"; continue; }
        echo "=============================================================="
        cat "$OUT_DIR/$file"
    done <<< "$matches"
else
    printf '%-22s %-12s %8s  %s\n' MODULE RVA SIZE FUNCTION
    while IFS=$'\t' read -r module rva size name file status; do
        printf '%-22s %-12s %8s  %s\n' "$module" "$rva" "$size" "$name"
        [ "$status" = "ok" ] && printf '%-22s %s\n' "" "$OUT_DIR/$file"
    done <<< "$matches"
fi
