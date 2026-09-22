# Shared settings for the oracle scripts. Sourced, not executed.
set -euo pipefail

REPO="$(cd "$DR_SRC/.." && pwd)"
IMAGE=localhost/deimos-wine
# Prefix, installer cache and screenshots. Under work/ because they are large,
# regenerable, and contain third-party binaries that must not be committed.
DR_WINE="${DR_WINE:-$REPO/work/wine}"
QT_URL=http://appldnld.apple.com/QuickTime/041-0025.20101207.Ptrqt/QuickTimeInstaller.exe
# QuickTime 7.6.9, the pin winetricks' quicktime76 verb uses.
QT_SHA256=c2dcda76ed55428e406ad7e6acdc84e804d30752a1380c313394c09bb3e27f56
QT_EXE="$DR_WINE/cache/QuickTimeInstaller.exe"

ensure_image() {
    podman image exists "$IMAGE" ||
        podman build -t "$IMAGE" -f "$REPO/tools/Containerfile" "$REPO/tools"
}

# Run a command in the Wine container: no network, prefix mounted at /w.
wine_run() {
    podman run --rm --network=none -v "$DR_WINE:/w:z" \
        -e WINEPREFIX=/w/prefix -e WINEARCH=win32 -e HOME=/w \
        "$IMAGE" bash -c "$1"
}

# Xvfb plus a PulseAudio null sink. Without an audio device DirectSound fails,
# the game shows "sound is disabled", and then crashes in the Ambrosia SSP
# music code (null read at 0x453a7a) -- so a silent sink is required, not
# optional.
DISPLAY_AND_AUDIO='
export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p -m700 $XDG_RUNTIME_DIR
pulseaudio -D --exit-idle-time=-1 -n --load=module-null-sink \
    --load=module-native-protocol-unix 2>/dev/null
Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 & sleep 2
export DISPLAY=:99
'
