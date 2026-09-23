#!/usr/bin/env bash
# raylib's prebuilt Linux .so links against unversioned -lX11/-lGL/... . Image-based
# distributions (Bazzite, Silverblue) ship only the versioned runtime libraries, so
# we materialise the dev symlinks into a project-local directory and add it to the
# linker path. Nothing outside the project is touched.
set -euo pipefail
# Only a Linux link needs these; Windows links raylib's own .lib files.
if [ "$(uname -s)" != Linux ]; then
    echo "setup: nothing to do on $(uname -s)"
    exit 0
fi
mkdir -p "${DR_BUILD:-build}"
LIBDIR="${DR_DEPS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.deps}/lib"
mkdir -p "$LIBDIR"
missing=()
for l in X11 Xrandr Xinerama Xcursor Xi Xext Xfixes GL; do
    [ -e "$LIBDIR/lib$l.so" ] && continue
    src=""
    for d in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib; do
        cand=$(ls "$d/lib$l.so."[0-9]* 2>/dev/null | grep -E '\.so\.[0-9]+$' | head -1 || true)
        [ -n "$cand" ] && { src="$cand"; break; }
    done
    if [ -n "$src" ]; then ln -sf "$src" "$LIBDIR/lib$l.so"; else missing+=("$l"); fi
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "setup: could not locate runtime libraries for: ${missing[*]}" >&2
    echo "setup: install the corresponding packages, then re-run 'mise run setup'" >&2
    exit 1
fi
echo "setup: dev symlinks ready in $LIBDIR"
