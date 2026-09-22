#!/usr/bin/env bash
# Run headless Ghidra over DeimosRising.exe, apply the recovered CodeView
# symbol map, and export one decompiled C file per function.
#
# First run imports and analyses (several minutes). Later runs reuse the
# existing project and skip analysis, so iterating on the export script is
# fast. Pass --reanalyse to force a clean import.
set -euo pipefail

VERSION="${GHIDRA_VERSION:-12.1.4}"
GHIDRA_HOME="${DR_GHIDRA:?}/ghidra_${VERSION}_PUBLIC"
HEADLESS="$GHIDRA_HOME/support/analyzeHeadless"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${DR_DECOMP:?}/project"
OUT_DIR="${DR_DECOMP}/export"
EXE="${DR_EXE:?}"
SYMS="${DR_SYMS:?}"
PROJECT_NAME="DeimosRising"

[ -x "$HEADLESS" ] || { echo "ghidra missing; run 'mise run decomp:setup'" >&2; exit 1; }
[ -f "$EXE" ]  || { echo "binary not found: $EXE" >&2; exit 1; }
[ -f "$SYMS" ] || { echo "symbol map not found: $SYMS" >&2; exit 1; }

reanalyse=0
[ "${1:-}" = "--reanalyse" ] && reanalyse=1

mkdir -p "$PROJECT_DIR" "$OUT_DIR"
rm -rf "$OUT_DIR"/* 2>/dev/null || true

common=(
    "$PROJECT_DIR" "$PROJECT_NAME"
    -scriptPath "$SCRIPTS"
    -postScript DeimosDecomp.java "$SYMS" "$OUT_DIR"
)

if [ $reanalyse -eq 1 ] || [ ! -f "$PROJECT_DIR/$PROJECT_NAME.gpr" ]; then
    echo "ghidra: importing and analysing (this takes several minutes)"
    rm -rf "$PROJECT_DIR"; mkdir -p "$PROJECT_DIR"
    "$HEADLESS" "${common[@]}" -import "$EXE" -analysisTimeoutPerFile 1800
else
    echo "ghidra: reusing existing project, skipping analysis"
    "$HEADLESS" "${common[@]}" -process "$(basename "$EXE")" -noanalysis
fi

echo
echo "corpus: $OUT_DIR"
