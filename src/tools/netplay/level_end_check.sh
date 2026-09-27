#!/usr/bin/env bash
# Two instances play the end of a level together over 127.0.0.1, with no
# one at the keyboard: written for a guest that crashed when Easy Mode's
# reward screen opened after the first level (and again on reconnecting).
#
# Both run with DR_NETPLAY_END (game/netplay.odin,
# netplay_lobby_start_from_flag): each readies itself, the host turns Easy
# Mode on, and the level starts END steps (default 150, five seconds)
# before its end. The check passes when both sides log that play was held
# -- the reward screen is open -- and both are still running HOLD seconds
# later with no desync reported.
#
# Headless and silent: both run inside one cage compositor with its
# headless backend (or Xvfb when that is what the machine has), with
# DR_NO_AUDIO, each with its own empty preferences, so nothing reaches the
# desktop, the speakers or the player's settings. The level is the first;
# KEEP=1 leaves the logs. HOST_BIN and GUEST_BIN run one side on another
# build, to see two builds meet.
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="${DR_BUILD:-build}/deimos"
[ -x "$BIN" ] || { echo "run 'mise run build' first" >&2; exit 1; }
HOST_BIN="${HOST_BIN:-$BIN}"
GUEST_BIN="${GUEST_BIN:-$BIN}"
END="${END:-150}"
HOLD="${HOLD:-5}"

if [ "${1:-}" != "--inside" ]; then
	WORK=$(mktemp -d)
	export WORK END HOLD HOST_BIN GUEST_BIN
	if command -v cage >/dev/null; then
		env -u DISPLAY -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
			WLR_RENDERER=pixman timeout 180 cage -- bash "$0" --inside >"$WORK/cage.log" 2>&1 || true
	elif command -v xvfb-run >/dev/null; then
		env DISPLAY= xvfb-run -a -s "-screen 0 1280x1024x24" bash "$0" --inside >"$WORK/cage.log" 2>&1 || true
	else
		echo "needs cage or xvfb-run to run headless" >&2
		exit 1
	fi
	result=$(grep -E "^(PASS|FAIL)" "$WORK/cage.log" || echo "FAIL: no result (see $WORK)")
	if [ "${result:0:4}" != "PASS" ] || [ -n "${KEEP:-}" ]; then
		for side in host guest; do
			echo "--- $side ---"
			grep -E "netplay:|panic|rror|ssert|fault" "$WORK/$side.log" | grep -v "^INFO" | tail -30 || true
		done
		echo "logs: $WORK"
	else
		rm -rf "$WORK"
	fi
	echo "$result"
	[ "${result:0:4}" = "PASS" ]
	exit
fi

# Inside the compositor.
run() {
	local side=$1 mode=$2 bin=$3
	mkdir -p "$WORK/$side"
	( [ -n "${STACK_KB:-}" ] && ulimit -s "$STACK_KB"; exec env XDG_DATA_HOME="$WORK/$side" APPDATA="$WORK/$side" DR_NO_AUDIO=1 DR_NETPLAY="$mode" \
		DR_NETPLAY_END="$END" DR_NETPLAY_SHOT="$WORK/$side" "$bin" ) >"$WORK/$side.log" 2>&1 &
	echo $!
}
HOST=$(run host host "$HOST_BIN")
sleep 1
GUEST=$(run guest join:127.0.0.1 "$GUEST_BIN")
trap 'kill $HOST $GUEST 2>/dev/null || true' EXIT

held() { grep -q "netplay: play held" "$WORK/$1.log" 2>/dev/null; }
alive() { kill -0 "$1" 2>/dev/null; }
for _ in $(seq 1 120); do
	(held host && held guest) && break
	alive "$HOST" || { echo "FAIL: the host exited before the screen opened"; exit; }
	alive "$GUEST" || { echo "FAIL: the guest exited before the screen opened"; exit; }
	sleep 0.5
done
held host || { echo "FAIL: the host never held play"; exit; }
held guest || { echo "FAIL: the guest never held play"; exit; }
sleep "$HOLD"
alive "$HOST" || { echo "FAIL: the host exited while the screen was open"; exit; }
alive "$GUEST" || { echo "FAIL: the guest exited while the screen was open"; exit; }
if grep -qi "desync" "$WORK/host.log" "$WORK/guest.log"; then
	echo "FAIL: a desync was reported"
	exit
fi
echo "PASS: both held play at the level's end and ran $HOLD more seconds"
