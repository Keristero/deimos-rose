#!/usr/bin/env bash
# Fetch the players' demo films that circulated for the Mac version, and
# extract them into $DR_ASSETS/films beside the four shipped demos.
#
# They come from deimos_addons.sit on Macintosh Garden
# (macintoshgarden.org/games/deimos-rising, "Add-ons Collection"), the same
# archive the clean-room remaster lists as DR-EVID-004 (its sha256 matches).
# Two sets are inside, each named "Demo NN[deNN].film" for level NN:
#
#   misc/Perfect_Demos.sit.hqx  levels 1-11, by "redbeanx", 2002  -> pd01..pd11
#   misc/Demo_Levels.sit        levels 1-10, by "deepThink", 2002 -> dl01..dl10
#
# Demo_Levels' 02 and 03 are byte for byte the shipped de02 and de03 (its
# read-me: "the original ones"), so they are not copied. The page's third
# download, Deimos_mod-extDemos.zip (SkyCapt, 2019), holds only copies of
# these two sets. All 40,296-byte v10005 films, as the shipped ones are;
# tests/film_test.odin checks each one's level and length.
#
# Macintosh Garden answers a bare request with 418: a download needs the
# signed link its page hands out, fetched with the page's session cookie.
set -euo pipefail

REPO="$(cd "$DR_SRC/.." && pwd)"
ARCHIVE="$REPO/orig/deimos_addons.sit"
SHA256=2f24df9bb5ef67d0c3a0b97f7ad8639484f37276555b58562b544a2fa648651d
PAGE=https://macintoshgarden.org/games/deimos-rising
UA="Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

command -v unar >/dev/null || { echo "needs unar (The Unarchiver's command line) for StuffIt and BinHex" >&2; exit 1; }

if [ ! -f "$ARCHIVE" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsS -c "$tmp/jar" -b "$tmp/jar" -A "$UA" -o "$tmp/page.html" "$PAGE"
    link="$(grep -oE '//download\.macintoshgarden\.org/games/deimos_addons\.sit\?[^"]*' "$tmp/page.html" | head -1 | sed 's/&amp;/\&/g')"
    [ -n "$link" ] || { echo "no download link for deimos_addons.sit on $PAGE" >&2; exit 1; }
    mkdir -p "$(dirname "$ARCHIVE")"
    curl -fL --retry 3 -b "$tmp/jar" -A "$UA" -e "$PAGE" -o "$ARCHIVE.part" "https:$link"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
echo "$SHA256  $ARCHIVE" | sha256sum -c -

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unar -q -f -o "$work" "$ARCHIVE" misc/Perfect_Demos.sit.hqx misc/Demo_Levels.sit
unar -q -f -o "$work/pd" "$work/deimos_addons/misc/Perfect_Demos.sit.hqx"
unar -q -f -o "$work/dl" "$work/deimos_addons/misc/Demo_Levels.sit"

mkdir -p "$DR_ASSETS/films"
for n in 01 02 03 04 05 06 07 08 09 10 11; do
    cp "$work/pd/Perfect Demos/Demo $n[de$n].film" "$DR_ASSETS/films/pd$n.film"
done
for n in 01 04 05 06 07 08 09 10; do
    cp "$work/dl/Recorded Levels/Demo $n[de$n].film" "$DR_ASSETS/films/dl$n.film"
done
# The two the set shares with the shipped demos: confirm, not copy.
cmp -s "$work/dl/Recorded Levels/Demo 02[de02].film" "$DR_ASSETS/films/de02.film"
cmp -s "$work/dl/Recorded Levels/Demo 03[de03].film" "$DR_ASSETS/films/de03.film"
echo "wrote pd01..pd11 and dl01, dl04..dl10 to $DR_ASSETS/films"
