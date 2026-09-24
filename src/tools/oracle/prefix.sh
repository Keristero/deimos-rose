#!/usr/bin/env bash
# Build a fresh 32-bit Wine prefix that runs the original game.
#
# The original calls InitializeQTML at startup and refuses to run without
# QuickTime. Getting it installed took three findings, recorded in
# docs/phase-4-sim.md:
#
# * QuickTimeInstaller.exe run silently (and winetricks' quicktime76 verb,
#   which runs it identically) crashes in the QuickTimePostInstallMSIProc
#   custom action and the MSI rolls everything back, on Wine 8 and 10.
# * The cause is ordering: QuickTime 7.6.9 needs CoreFoundation.dll from the
#   bundled Apple Application Support MSI. Installing that MSI first makes
#   QuickTime.msi install cleanly.
# * Copying the MSI's files in by hand is not enough -- QuickTime.qts loads,
#   then jumps to a null CoreFoundation entry point.
source "$(dirname "$0")/common.sh"

[ -f "$QT_EXE" ] || { echo "run 'mise run oracle:fetch' first" >&2; exit 1; }
echo "$QT_SHA256  $QT_EXE" | sha256sum -c --quiet -
[ -f "$DR_EXE" ] || { echo "original not extracted: $DR_EXE" >&2; exit 1; }
ensure_image

rm -rf "$DR_WINE/prefix" "$DR_WINE/cache/qt"
mkdir -p "$DR_WINE/cache/qt"
wine_run '
set -e
cd /w/cache/qt && cabextract -q ../QuickTimeInstaller.exe
'"$DISPLAY_AND_AUDIO"'
wineboot -i >/dev/null 2>&1
# A crashing custom action should fail, not wait forever in winedbg.
wine reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug" \
    /v Debugger /d false /f >/dev/null 2>&1
wine msiexec /i AppleApplicationSupport.msi /qn >/dev/null 2>&1
wine msiexec /i QuickTime.msi ALLUSERS=1 DESKTOP_SHORTCUTS=0 QTTaskRunFlags=0 \
    QTINFO.BISQTPRO=1 SCHEDULE_ASUW=0 REBOOT_REQUIRED=No /qn >/dev/null 2>&1
wineserver -w
'
qts="$DR_WINE/prefix/drive_c/Program Files/QuickTime/QTSystem/QuickTime.qts"
[ -f "$qts" ] || { echo "QuickTime did not install (rolled back?)" >&2; exit 1; }

# The real install, not game/: that may hold just a symlink to the exe,
# which points outside the container and leaves Data behind.
rm -rf "$DR_WINE/prefix/drive_c/DR"
cp -aL "$(dirname "$(readlink -f "$DR_EXE")")" "$DR_WINE/prefix/drive_c/DR"
echo "prefix ready: $DR_WINE/prefix"
