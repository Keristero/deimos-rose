#!/usr/bin/env bash
# The announcer's voice: one clip per kill streak (line N of streaks.txt is
# streak N) and the modifiers (modifiers.txt), spoken by Moonshine TTS and written to
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
# The modifiers, one clip each (modifiers.txt: a tier for each 50 kills).
while IFS= read -r line; do
  clip="$(echo "$line" | tr 'A-Z ' 'a-z_')"
  say "$clip" "Mmm, ${line,,}..."
done < "$HERE/modifiers.txt"
ls "$OUT" | wc -l

# Player 2's announcer: a very Australian man (ZipVoice's australian_male), no
# flirting, getting angrier with the streak. The calm titles and modifiers
# (view/clips_p2/NN.wav) serve the first stages; from stage 3 (streak 36) he is
# shouting: the same words in capitals with a "!", faster, compressed hard and
# driven into clipping (*_mad.wav). After each title comes one of rage.txt's
# lines for the stage (stage<TAB>line), processed harder with the stage. The
# playback pitch and gain rise with the stage too (view/rules.odin).
OUT_AU="$HERE/../view/clips_p2"
mkdir -p "$OUT_AU"
TRIM="silenceremove=start_periods=1:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_threshold=-45dB,areverse"
# Stage -> the effects after the trim: faster, then squashed and clipped.
rage_fx() {
  case "$1" in
    0) echo "" ;;
    1) echo "atempo=1.06," ;;
    2) echo "atempo=1.12,acompressor=threshold=-26dB:ratio=6:makeup=4," ;;
    3) echo "atempo=1.2,acompressor=threshold=-30dB:ratio=10:makeup=8,asoftclip=type=atan:param=3,equalizer=f=2800:t=q:w=1:g=5," ;;
    *) echo "atempo=1.3,acompressor=threshold=-34dB:ratio=14:makeup=12,volume=3,asoftclip=type=atan:param=3,equalizer=f=2800:t=q:w=1:g=8," ;;
  esac
}
say_au() { # name text stage
  moonshine tts --voice zipvoice_australian_male --text "$2" --out "$TMP/au_$1.wav" >/dev/null 2>&1
  ffmpeg -y -loglevel error -i "$TMP/au_$1.wav" \
    -af "$TRIM,$(rage_fx "${3:-0}")loudnorm=I=-14:TP=-1" \
    -ar 22050 -ac 1 -c:a pcm_s16le "$OUT_AU/$1.wav"
}
shout() { echo "${1^^}!"; }
n=0
while IFS= read -r line; do
  n=$((n + 1))
  id="$(printf '%02d' "$n")"
  [ -f "$OUT_AU/$id.wav" ] || say_au "$id" "$line"
  say_au "${id}_mad" "$(shout "$line")" 4
done < "$HERE/streaks.txt"
while IFS= read -r line; do
  clip="$(echo "$line" | tr 'A-Z ' 'a-z_')"
  [ -f "$OUT_AU/$clip.wav" ] || say_au "$clip" "$line"
  say_au "${clip}_mad" "$(shout "$line")" 4
done < "$HERE/modifiers.txt"
declare -A seen
while IFS=$'\t' read -r stage line; do
  k="${seen[$stage]:-0}"
  seen[$stage]=$((k + 1))
  if [ "$stage" -ge 2 ]; then line="$(shout "$line")"; fi
  say_au "rage_${stage}_${k}" "$line" "$stage"
done < "$HERE/rage.txt"
ls "$OUT_AU" | wc -l
