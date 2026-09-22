#!/usr/bin/env bash
# Fetch and unpack Ghidra into the user cache. Idempotent: re-running when the
# requested version is already present does nothing.
#
# Ghidra is ~1.5 GB unpacked, so it lives outside the repository entirely.
set -euo pipefail

VERSION="${GHIDRA_VERSION:-12.1.4}"
BUILD="${GHIDRA_BUILD:-20260921}"
DEST="${DR_GHIDRA:?DR_GHIDRA must be set}"
ZIP_NAME="ghidra_${VERSION}_PUBLIC_${BUILD}.zip"
URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${VERSION}_build/${ZIP_NAME}"
HEADLESS="$DEST/ghidra_${VERSION}_PUBLIC/support/analyzeHeadless"

if [ -x "$HEADLESS" ]; then
    echo "ghidra: already present at $HEADLESS"
    exit 0
fi

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "ghidra: downloading $ZIP_NAME (~570 MB)"
curl -fL --retry 3 --progress-bar -o "$TMP/$ZIP_NAME" "$URL"

echo "ghidra: unpacking"
unzip -q "$TMP/$ZIP_NAME" -d "$DEST"

[ -x "$HEADLESS" ] || { echo "ghidra: analyzeHeadless not found after unpack" >&2; exit 1; }
echo "ghidra: ready at $HEADLESS"
