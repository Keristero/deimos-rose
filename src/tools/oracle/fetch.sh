#!/usr/bin/env bash
# Download QuickTime 7.6.9 for Windows and verify the pinned checksum.
# The only oracle step that touches the network; everything after is offline.
source "$(dirname "$0")/common.sh"

mkdir -p "$(dirname "$QT_EXE")"
if [ ! -f "$QT_EXE" ]; then
    curl -fL --retry 3 -o "$QT_EXE.part" "$QT_URL"
    mv "$QT_EXE.part" "$QT_EXE"
fi
echo "$QT_SHA256  $QT_EXE" | sha256sum -c -
