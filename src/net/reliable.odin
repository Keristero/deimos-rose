package netplay

// The "small reliable channel for control messages" from the plan: only
// Hello, Ready, Start and Goodbye ever need it, and a two-player handshake
// never has more than one of those in flight at once, so stop-and-wait
// (send, retry on a timer until acked, give up after enough retries) is
// enough -- no window, no per-message ordering beyond "one at a time".

import core_net "core:net"
import "core:time"

RELIABLE_RETRY :: 200 * time.Millisecond
RELIABLE_MAX_RETRIES :: 20 // ~4s of retrying before the peer is presumed gone

Reliable_Channel :: struct {
	to:        core_net.Endpoint,
	next_seq:  u8,
	pending:   bool,
	seq:       u8,
	buf:       [HELLO_SIZE_MAX]byte, // the largest is Hello with a full name
	length:    int,
	sent_at:   time.Time,
	retries:   int,
	have_seen: bool,
	last_seen: u8, // most recent inbound seq accepted, to drop duplicates
}

reliable_init :: proc(rc: ^Reliable_Channel, to: core_net.Endpoint) {
	rc^ = {}
	rc.to = to
}

// Odin procs don't close over their enclosing scope, so each send_* below
// repeats this bookkeeping around its own encode call rather than sharing it
// through a callback.
@(private = "file")
reliable_begin :: proc(rc: ^Reliable_Channel) -> u8 {
	rc.seq = rc.next_seq
	rc.next_seq += 1
	rc.pending = true
	rc.retries = 0
	rc.sent_at = time.now()
	return rc.seq
}

send_hello :: proc(rc: ^Reliable_Channel, sock: ^Socket, player: u8, hue: u16, name: string) {
	seq := reliable_begin(rc)
	rc.length = encode_hello(rc.buf[:], seq, player, hue, name)
	send(sock, rc.to, rc.buf[:rc.length])
}

send_ready :: proc(rc: ^Reliable_Channel, sock: ^Socket) {
	seq := reliable_begin(rc)
	rc.length = encode_ready(rc.buf[:], seq)
	send(sock, rc.to, rc.buf[:rc.length])
}

send_goodbye :: proc(rc: ^Reliable_Channel, sock: ^Socket) {
	seq := reliable_begin(rc)
	rc.length = encode_goodbye(rc.buf[:], seq)
	send(sock, rc.to, rc.buf[:rc.length])
}

send_start :: proc(rc: ^Reliable_Channel, sock: ^Socket, seed: u32, level: u8, flags: u8 = 0) {
	seq := reliable_begin(rc)
	rc.length = encode_start(rc.buf[:], seq, seed, level, flags)
	send(sock, rc.to, rc.buf[:rc.length])
}

send_resync_start :: proc(rc: ^Reliable_Channel, sock: ^Socket, assigned_player: u8, total_size: u32) {
	seq := reliable_begin(rc)
	rc.length = encode_resync_start(rc.buf[:], seq, assigned_player, total_size)
	send(sock, rc.to, rc.buf[:rc.length])
}

// Once per frame: resends the pending message if RELIABLE_RETRY has elapsed
// with no ack yet. False once RELIABLE_MAX_RETRIES is exceeded -- the peer
// is presumed gone and the caller should stop waiting.
reliable_tick :: proc(rc: ^Reliable_Channel, sock: ^Socket) -> (alive: bool) {
	if !rc.pending {
		return true
	}
	if time.since(rc.sent_at) < RELIABLE_RETRY {
		return true
	}
	rc.retries += 1
	if rc.retries > RELIABLE_MAX_RETRIES {
		return false
	}
	rc.sent_at = time.now()
	send(sock, rc.to, rc.buf[:rc.length])
	return true
}

// Feed every inbound Ack packet here; clears the pending send once its seq
// matches (an Ack for anything else -- a stale retry's Ack arriving after a
// newer message was already queued -- is simply ignored).
reliable_handle_ack :: proc(rc: ^Reliable_Channel, buf: []byte) {
	seq, ok := decode_ack(buf)
	if ok && rc.pending && seq == rc.seq {
		rc.pending = false
	}
}

// Feed every inbound Hello/Ready/Goodbye here with its decoded seq. Always
// sends back an Ack (the peer may have missed the first one), and reports
// whether this is a new message the caller should actually act on, as
// opposed to a duplicate delivery of one it already handled.
reliable_accept :: proc(rc: ^Reliable_Channel, sock: ^Socket, from: core_net.Endpoint, seq: u8) -> (is_new: bool) {
	ack: [2]byte
	n := encode_ack(ack[:], seq)
	send(sock, from, ack[:n])
	if rc.have_seen && seq == rc.last_seen {
		return false
	}
	rc.have_seen = true
	rc.last_seen = seq
	return true
}
