#!/usr/bin/env bash
# The announcer's voice: one clip per kill streak (line N of streaks.txt is
# streak N) and the two prefixes, spoken by Moonshine TTS and written to
# view/clips/ as 22.05 kHz mono 16-bit WAVs with the silence trimmed, which the
# plugin embeds (view/announcer.odin). Needs `moonshine` and `ffmpeg`; run
# from anywhere: `mise run hitstop:announcer`. Never plays on a device.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../view/clips"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"
say() { # name text
  moonshine tts --voice kokoro_af_nicole --options speed=0.85 --text "$2" --out "$TMP/$1.wav" >/dev/null 2>&1
  ffmpeg -y -loglevel error -i "$TMP/$1.wav" \
    -af "silenceremove=start_periods=1:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_threshold=-45dB,areverse,loudnorm=I=-14:TP=-1" \
    -ar 22050 -ac 1 -c:a pcm_s16le "$OUT/$1.wav"
}
# Said husky and slow, each title with a tail from flirts.txt, cycled.
mapfile -t flirts < "$HERE/flirts.txt"
n=0
while IFS= read -r line; do
  n=$((n + 1))
  say "$(printf '%02d' "$n")" "${line}${flirts[$(( (n - 1) % ${#flirts[@]} ))]}"
done < "$HERE/streaks.txt"
say super "Mmm, super..."
say super_duper "Mmm, super duper..."
ls "$OUT" | wc -l
