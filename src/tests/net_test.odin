package tests

import core_net "core:net"
import "core:testing"
import "core:time"

import net "dr:net"
import "dr:sim"

@(test)
packet_hello_round_trips :: proc(t: ^testing.T) {
	buf: [64]byte
	n := net.encode_hello(buf[:], 5, 1, 300, "Keristero")
	kind, kok := net.peek_kind(buf[:n])
	testing.expect(t, kok)
	testing.expect_value(t, kind, net.Packet_Kind.Hello)
	seq, player, hue, name, ok := net.decode_hello(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, seq, u8(5))
	testing.expect_value(t, player, u8(1))
	testing.expect_value(t, hue, u16(300))
	testing.expect_value(t, name, "Keristero")
}

@(test)
packet_hello_names_are_capped_and_checked :: proc(t: ^testing.T) {
	buf: [64]byte
	n := net.encode_hello(buf[:], 0, 0, 0, "abcdefghijklmnopqrstuvwxyz")
	testing.expect_value(t, n, net.HELLO_SIZE_MAX)
	_, _, _, name, ok := net.decode_hello(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, name, "abcdefghijklmnopqrst") // HELLO_NAME_MAX
	// A name length pointing past the end of the packet is refused.
	_, _, _, _, short := net.decode_hello(buf[:n - 1])
	testing.expect(t, !short)
	n = net.encode_hello(buf[:], 0, 0, 0, "")
	_, _, _, name, ok = net.decode_hello(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, name, "")
}

@(test)
packet_ping_and_pong_do_not_cross_decode :: proc(t: ^testing.T) {
	buf: [64]byte
	n := net.encode_ping(buf[:], 0xDEAD_BEEF_0000_1234)
	nonce, ok := net.decode_ping(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, nonce, u64(0xDEAD_BEEF_0000_1234))
	// A Ping buffer must not also decode as a Pong -- they share a layout,
	// only the kind byte tells them apart.
	_, bad := net.decode_pong(buf[:n])
	testing.expect(t, !bad)

	m := net.encode_pong(buf[:], 42)
	nonce2, ok2 := net.decode_pong(buf[:m])
	testing.expect(t, ok2)
	testing.expect_value(t, nonce2, u64(42))
}

@(test)
packet_level_choice_round_trips :: proc(t: ^testing.T) {
	buf: [64]byte
	n := net.encode_level_choice(buf[:], 7)
	kind, kok := net.peek_kind(buf[:n])
	testing.expect(t, kok)
	testing.expect_value(t, kind, net.Packet_Kind.Level_Choice)
	level_index, ok := net.decode_level_choice(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, level_index, u8(7))
}

@(test)
packet_resync_start_round_trips :: proc(t: ^testing.T) {
	buf: [64]byte
	n := net.encode_resync_start(buf[:], 9, 1, 670120)
	kind, kok := net.peek_kind(buf[:n])
	testing.expect(t, kok)
	testing.expect_value(t, kind, net.Packet_Kind.Resync_Start)
	seq, assigned, total, ok := net.decode_resync_start(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, seq, u8(9))
	testing.expect_value(t, assigned, u8(1))
	testing.expect_value(t, total, u32(670120))
}

@(test)
packet_state_chunk_round_trips_a_full_and_partial_chunk :: proc(t: ^testing.T) {
	payload: [net.STATE_CHUNK_SIZE]byte
	for &b, i in payload {
		b = u8(i)
	}
	buf: [net.STATE_CHUNK_SIZE + 16]byte

	n := net.encode_state_chunk(buf[:], 654, payload[:])
	kind, kok := net.peek_kind(buf[:n])
	testing.expect(t, kok)
	testing.expect_value(t, kind, net.Packet_Kind.State_Chunk)
	full, fok := net.decode_state_chunk(buf[:n])
	testing.expect(t, fok)
	testing.expect_value(t, full.chunk_index, u16(654))
	testing.expect_value(t, full.length, net.STATE_CHUNK_SIZE)
	testing.expect_value(t, full.payload[0], u8(0))
	testing.expect_value(t, full.payload[net.STATE_CHUNK_SIZE - 1], u8(255))

	m := net.encode_state_chunk(buf[:], 655, payload[:424]) // sim.State's actual tail chunk length (670120 % 1024)
	partial, pok := net.decode_state_chunk(buf[:m])
	testing.expect(t, pok)
	testing.expect_value(t, partial.chunk_index, u16(655))
	testing.expect_value(t, partial.length, 424)
}

@(test)
packet_state_chunk_ack_round_trips :: proc(t: ^testing.T) {
	buf: [64]byte
	n := net.encode_state_chunk_ack(buf[:], 654)
	kind, kok := net.peek_kind(buf[:n])
	testing.expect(t, kok)
	testing.expect_value(t, kind, net.Packet_Kind.State_Chunk_Ack)
	idx, ok := net.decode_state_chunk_ack(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, idx, u16(654))
}

@(test)
packet_input_round_trips_a_full_window :: proc(t: ^testing.T) {
	frames: [net.MAX_INPUT_FRAMES]sim.Buttons
	for &f, i in frames {
		f = transmute(sim.Buttons)u16(i * 3 + 1) // arbitrary distinct bit patterns
	}
	buf: [512]byte
	n := net.encode_input(buf[:], 1, 1000, frames[:])
	p, ok := net.decode_input(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, p.player, u8(1))
	testing.expect_value(t, p.start_frame, u32(1000))
	testing.expect_value(t, p.count, len(frames))
	for f, i in frames {
		testing.expect_value(t, p.frames[i], f)
	}
}

@(test)
packet_input_rejects_truncated_buffers :: proc(t: ^testing.T) {
	frames := [3]sim.Buttons{{.Left}, {.Right}, {.Up}}
	buf: [64]byte
	n := net.encode_input(buf[:], 0, 5, frames[:])
	_, ok := net.decode_input(buf[:n - 1])
	testing.expect(t, !ok, "a packet cut short must not decode")
}

@(test)
packet_kind_rejects_garbage :: proc(t: ^testing.T) {
	_, ok := net.peek_kind([]byte{0xff})
	testing.expect(t, !ok)
	_, ok2 := net.peek_kind([]byte{})
	testing.expect(t, !ok2)
}

// The join box's parsing, all without touching the network: IP literals
// never reach the resolver, and malformed input is refused before it would.
// Hostname lookup itself is not tested here -- it depends on the machine's
// resolver configuration, which CI runners do not promise.
@(test)
resolve_accepts_ip4_literals_with_and_without_a_port :: proc(t: ^testing.T) {
	ep, err := net.resolve("192.168.1.20")
	testing.expect_value(t, err, net.Resolve_Error.None)
	testing.expect_value(t, ep.address, core_net.Address(core_net.IP4_Address{192, 168, 1, 20}))
	testing.expect_value(t, ep.port, 0)

	ep, err = net.resolve("10.0.0.5:60902")
	testing.expect_value(t, err, net.Resolve_Error.None)
	testing.expect_value(t, ep.address, core_net.Address(core_net.IP4_Address{10, 0, 0, 5}))
	testing.expect_value(t, ep.port, 60902)
}

@(test)
resolve_refuses_what_it_cannot_send_to :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		want: net.Resolve_Error,
	}{
		{"", .Bad_Address},
		{"not a host", .Bad_Address},     // spaces are not valid in a hostname
		{"10.0.0.5:99999", .Bad_Address}, // port out of range
		{"10.0.0.5:port", .Bad_Address},
		{"::1", .No_IP4},                 // the socket is bound IPv4-only
		{"[::1]:60902", .No_IP4},
	}
	for c in cases {
		_, err := net.resolve(c.text)
		testing.expectf(t, err == c.want, "%q: got %v, want %v", c.text, err, c.want)
	}
}

// The one test that touches a real socket: two UDP sockets bound to
// loopback, each on an OS-assigned ephemeral port, exchanging an Input
// packet exactly as two peers would.
@(test)
socket_sends_and_receives_on_loopback :: proc(t: ^testing.T) {
	a, aok := net.open(0)
	testing.expect(t, aok, "open socket a")
	defer net.close(&a)
	b, bok := net.open(0)
	testing.expect(t, bok, "open socket b")
	defer net.close(&b)

	a_ep, a_epok := net.local_endpoint(&a)
	testing.expect(t, a_epok)
	b_ep, b_epok := net.local_endpoint(&b)
	testing.expect(t, b_epok)

	frames := [2]sim.Buttons{{.Left, .Fire_Ground}, {.Right}}
	buf: [64]byte
	n := net.encode_input(buf[:], 0, 7, frames[:])
	testing.expect(t, net.send(&a, core_net.Endpoint{address = core_net.IP4_Loopback, port = b_ep.port}, buf[:n]))

	recv: [64]byte
	got, from, ok := poll_until_received(&b, recv[:])
	testing.expect(t, ok, "b should receive what a sent")
	if !ok {
		return
	}
	testing.expect_value(t, from.port, a_ep.port)
	p, dok := net.decode_input(recv[:got])
	testing.expect(t, dok)
	testing.expect_value(t, p.start_frame, u32(7))
	testing.expect_value(t, p.count, 2)
	testing.expect_value(t, p.frames[0], sim.Buttons{.Left, .Fire_Ground})
	testing.expect_value(t, p.frames[1], sim.Buttons{.Right})
}

// The Hello -> Ack handshake over real loopback sockets, exactly as a lobby
// would run it: a's Reliable_Channel sends Hello, b receives and accepts it
// (reporting it as new), b's Ack reaches a, and a's channel clears pending.
@(test)
reliable_handshake_completes_over_loopback :: proc(t: ^testing.T) {
	a, aok := net.open(0)
	testing.expect(t, aok)
	defer net.close(&a)
	b, bok := net.open(0)
	testing.expect(t, bok)
	defer net.close(&b)

	a_ep, _ := net.local_endpoint(&a)
	b_ep, _ := net.local_endpoint(&b)
	a_to_b := core_net.Endpoint{address = core_net.IP4_Loopback, port = b_ep.port}
	b_to_a := core_net.Endpoint{address = core_net.IP4_Loopback, port = a_ep.port}

	rc_a: net.Reliable_Channel
	net.reliable_init(&rc_a, a_to_b)
	net.send_hello(&rc_a, &a, 0, 0, "a")
	testing.expect(t, rc_a.pending, "hello should be pending until acked")

	buf: [64]byte
	n, _, ok := poll_until_received(&b, buf[:])
	testing.expect(t, ok, "b should receive a's Hello")
	if !ok {
		return
	}
	kind, kok := net.peek_kind(buf[:n])
	testing.expect(t, kok && kind == .Hello)
	seq, player, _, _, dok := net.decode_hello(buf[:n])
	testing.expect(t, dok)
	testing.expect_value(t, player, u8(0))

	rc_b: net.Reliable_Channel
	net.reliable_init(&rc_b, b_to_a)
	is_new := net.reliable_accept(&rc_b, &b, b_to_a, seq)
	testing.expect(t, is_new, "first delivery of a seq must be new")
	is_new_again := net.reliable_accept(&rc_b, &b, b_to_a, seq)
	testing.expect(t, !is_new_again, "a repeated seq must not be new")

	m, _, ackok := poll_until_received(&a, buf[:])
	testing.expect(t, ackok, "a should receive b's Ack")
	if !ackok {
		return
	}
	net.reliable_handle_ack(&rc_a, buf[:m])
	testing.expect(t, !rc_a.pending, "the ack should clear the pending hello")
}

@(test)
reliable_tick_resends_after_the_retry_interval :: proc(t: ^testing.T) {
	a, aok := net.open(0)
	testing.expect(t, aok)
	defer net.close(&a)
	b, bok := net.open(0)
	testing.expect(t, bok)
	defer net.close(&b)
	b_ep, _ := net.local_endpoint(&b)

	rc: net.Reliable_Channel
	net.reliable_init(&rc, core_net.Endpoint{address = core_net.IP4_Loopback, port = b_ep.port})
	net.send_ready(&rc, &a)

	buf: [64]byte
	_, _, first := poll_until_received(&b, buf[:])
	testing.expect(t, first, "the initial send should arrive")

	// Nothing has acked it yet: back-date sent_at past the retry interval
	// (rather than actually sleeping) and confirm a tick resends it.
	rc.sent_at = time.time_add(time.now(), -net.RELIABLE_RETRY - time.Millisecond)
	testing.expect(t, net.reliable_tick(&rc, &a), "one retry should not exhaust the channel")
	testing.expect_value(t, rc.retries, 1)
	_, _, resent := poll_until_received(&b, buf[:])
	testing.expect(t, resent, "the retry should have been sent")

	rc.pending = false
	testing.expect(t, net.reliable_tick(&rc, &a), "nothing pending is trivially alive")
}

@(test)
reliable_tick_gives_up_after_max_retries :: proc(t: ^testing.T) {
	a, aok := net.open(0)
	testing.expect(t, aok)
	defer net.close(&a)

	rc: net.Reliable_Channel
	net.reliable_init(&rc, core_net.Endpoint{address = core_net.IP4_Loopback, port = 1}) // nobody listening
	net.send_goodbye(&rc, &a)

	alive := true
	for _ in 0 ..< net.RELIABLE_MAX_RETRIES {
		rc.sent_at = time.time_add(time.now(), -net.RELIABLE_RETRY - time.Millisecond)
		alive = net.reliable_tick(&rc, &a)
		testing.expect(t, alive)
	}
	rc.sent_at = time.time_add(time.now(), -net.RELIABLE_RETRY - time.Millisecond)
	alive = net.reliable_tick(&rc, &a)
	testing.expect(t, !alive, "the channel should give up once retries are exhausted")
}

// poll_recv is non-blocking; a freshly sent loopback packet is normally
// already there by the first poll, but give the kernel a few tries rather
// than assume that under a loaded test runner.
@(private = "file")
poll_until_received :: proc(sock: ^net.Socket, buf: []byte) -> (n: int, from: core_net.Endpoint, ok: bool) {
	for _ in 0 ..< 1000 {
		if n, from, ok = net.poll_recv(sock, buf); ok {
			return
		}
	}
	return
}
