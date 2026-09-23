#!/usr/bin/env bash
# Two-instance loopback smoke test for the netplay lobby and live session
# (Phase 7 stage 6 / Phase 6 stage 5). Launches two real, interactive copies
# of our own port under separate Xvfb displays, has one host and the other
# join over 127.0.0.1 (DR_NETPLAY -- see main.odin and
# netplay_lobby_start_from_flag's comment), clicks each side's own Ready
# button, and checks both sides' stderr for game/netplay.odin's "connected"
# and "session started" diagnostics.
#
# This is not an oracle comparison -- there is nothing in the original to
# compare against (see netplay.odin's file header) -- and it is not the
# phase's real exit criterion either (Phase 6 stage 6, a genuine two-machine
# playtest, is still unstarted). It is the closest thing to an automated
# regression check the handshake + rollback wiring has: run it after any
# change to net/ or game/netplay.odin.
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="${DR_BUILD:-build}/deimos"
[ -x "$BIN" ] || { echo "run 'mise run build' first" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() {
	kill "$PID_A" "$PID_B" "$XVFB_A" "$XVFB_B" 2>/dev/null || true
	wait 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

Xvfb :97 -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB_A=$!
Xvfb :98 -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB_B=$!
sleep 1

DISPLAY=:97 DR_NETPLAY=host "$BIN" >"$WORK/a.log" 2>&1 &
PID_A=$!
DISPLAY=:98 DR_NETPLAY=join:127.0.0.1 "$BIN" >"$WORK/b.log" 2>&1 &
PID_B=$!
sleep 3

fail() {
	echo "FAIL: $1" >&2
	echo "--- instance A (host) ---"; cat "$WORK/a.log"
	echo "--- instance B (guest) ---"; cat "$WORK/b.log"
	exit 1
}

for i in $(seq 1 20); do
	grep -q "netplay: connected as Host" "$WORK/a.log" 2>/dev/null &&
		grep -q "netplay: connected as Guest" "$WORK/b.log" 2>/dev/null && break
	sleep 0.5
done
grep -q "netplay: connected as Host" "$WORK/a.log" || fail "host never connected"
grep -q "netplay: connected as Guest" "$WORK/b.log" || fail "guest never connected"
echo "handshake OK"

# Both sides' Ready button (game/netplay.odin: text_button_at(r, "READY",
# 280), WINDOW_SCALE=2 -- centre of the rect is logical (320, 290), device
# (640, 580) on both displays since each instance's window is independently
# 640x480 logical / 1280x960 device).
click_ready() {
	local disp=$1
	local wid
	wid=$(DISPLAY=$disp xdotool search --name "Deimos Rising" | head -1)
	DISPLAY=$disp xdotool windowfocus --sync "$wid"
	DISPLAY=$disp xdotool mousemove --window "$wid" --sync 640 580
	DISPLAY=$disp xdotool mousedown --window "$wid" 1
	sleep 0.15
	DISPLAY=$disp xdotool mouseup --window "$wid" 1
}
click_ready :97
click_ready :98

for i in $(seq 1 20); do
	grep -q "netplay: session started as player 0" "$WORK/a.log" 2>/dev/null &&
		grep -q "netplay: session started as player 1" "$WORK/b.log" 2>/dev/null && break
	sleep 0.5
done
grep -q "netplay: session started as player 0" "$WORK/a.log" || fail "host session never started"
grep -q "netplay: session started as player 1" "$WORK/b.log" || fail "guest session never started"
echo "session start OK"

sleep 2
grep -qi "desync" "$WORK/a.log" "$WORK/b.log" && fail "desync monitor fired during the smoke check"
echo "PASS"
