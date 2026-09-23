#!/usr/bin/env bash
# Three-instance loopback smoke test for pause-on-disconnect + reconnect
# (Phase 8 stage 3/4, notes/netcode-enhancements.md). Starts a normal two-
# instance session (same handshake as loopback_check.sh), SIGKILLs the guest
# mid-session (no Goodbye -- this exercises the NETPLAY_LIVE_TIMEOUT path,
# not the clean-disconnect one already covered by loopback_check.sh's own
# Escape-driven Goodbye elsewhere), waits for the survivor to notice and
# rebind to the well-known port, then launches a *third* instance that joins
# the survivor exactly like any fresh guest would (DR_NETPLAY=join:...) and
# checks both sides report the resync completing.
#
# Not an oracle comparison -- there is nothing in the original to compare
# against, same as loopback_check.sh. Run after any change to the
# Waiting_Reconnect/Resync_Sending/Resync_Receiving paths in
# game/netplay.odin or the Resync_Start/State_Chunk*/Hello handling in
# net/packet.odin.
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="${DR_BUILD:-build}/deimos"
[ -x "$BIN" ] || { echo "run 'mise run build' first" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() {
	kill "$PID_A" "$PID_C" "$XVFB_A" "$XVFB_B" "$XVFB_C" 2>/dev/null || true
	kill "$PID_B" 2>/dev/null || true
	wait 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

Xvfb :97 -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB_A=$!
Xvfb :98 -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB_B=$!
Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB_C=$!
sleep 1

DISPLAY=:97 DR_NETPLAY=host "$BIN" >"$WORK/a.log" 2>&1 &
PID_A=$!
DISPLAY=:98 DR_NETPLAY=join:127.0.0.1 "$BIN" >"$WORK/b.log" 2>&1 &
PID_B=$!
sleep 3

fail() {
	echo "FAIL: $1" >&2
	echo "--- instance A (host, survivor) ---"; cat "$WORK/a.log"
	echo "--- instance B (original guest, killed) ---"; cat "$WORK/b.log"
	echo "--- instance C (reconnecting guest) ---"; cat "$WORK/c.log" 2>/dev/null || true
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

# Same Ready-button coordinates as loopback_check.sh -- see its own comment.
click_ready() {
	local disp=$1
	local wid
	wid=$(DISPLAY=$disp xdotool search --name "Deimos Rising" | head -1)
	DISPLAY=$disp xdotool windowfocus --sync "$wid"
	DISPLAY=$disp xdotool mousemove --window "$wid" --sync 640 620
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

sleep 1
kill -9 "$PID_B"
wait "$PID_B" 2>/dev/null || true
echo "guest killed"

# NETPLAY_LIVE_TIMEOUT is 3s (game/netplay.odin); give it comfortable margin.
for i in $(seq 1 20); do
	grep -q "netplay: peer lost, waiting for a reconnect" "$WORK/a.log" 2>/dev/null && break
	sleep 0.5
done
grep -q "netplay: peer lost, waiting for a reconnect" "$WORK/a.log" || fail "survivor never noticed the disconnect"
echo "disconnect detected OK"

# A fresh instance reconnects exactly like any ordinary guest join -- no
# special flag or foreknowledge beyond the survivor's address, which is
# always 127.0.0.1:54217 here (see netplay_enter_waiting_reconnect's comment
# on always rebinding to the well-known NETPLAY_PORT).
DISPLAY=:99 DR_NETPLAY=join:127.0.0.1 "$BIN" >"$WORK/c.log" 2>&1 &
PID_C=$!

for i in $(seq 1 20); do
	grep -q "netplay: resync sent, resuming as player 0" "$WORK/a.log" 2>/dev/null &&
		grep -q "netplay: reconnected as player 1" "$WORK/c.log" 2>/dev/null && break
	sleep 0.5
done
grep -q "netplay: resync sent, resuming as player 0" "$WORK/a.log" || fail "survivor never finished sending the resync"
grep -q "netplay: reconnected as player 1" "$WORK/c.log" || fail "reconnecting client never finished receiving the resync"
echo "reconnect OK"

sleep 2
grep -qi "desync" "$WORK/a.log" "$WORK/c.log" && fail "desync monitor fired after reconnecting"
echo "PASS"
