#!/usr/bin/env bash
# Summarise the exported decompilation corpus.
set -euo pipefail
OUT_DIR="${DR_DECOMP:?}/export"
INDEX="$OUT_DIR/index.tsv"
[ -f "$INDEX" ] || { echo "no corpus; run 'mise run decomp:export'" >&2; exit 1; }

total=$(($(wc -l < "$INDEX") - 1))
ok=$(awk -F'\t' 'NR>1 && $6=="ok"' "$INDEX" | wc -l)
echo "corpus: $OUT_DIR"
echo "functions: $total   exported: $ok   failed: $((total - ok))"
echo
echo "largest modules by exported function count:"
awk -F'\t' 'NR>1 && $6=="ok" {n[$1]++; b[$1]+=$3} END {for (m in n) printf "  %-22s %4d fns %9d bytes\n", m, n[m], b[m]}' \
    "$INDEX" | sort -k2 -rn | head -25
echo
fails=$(awk -F'\t' 'NR>1 && $6!="ok"' "$INDEX" | wc -l)
if [ "$fails" -gt 0 ]; then
    echo "failures ($fails):"
    awk -F'\t' 'NR>1 && $6!="ok" {printf "  %-40s %s\n", $4, $6}' "$INDEX" | head -20
fi
