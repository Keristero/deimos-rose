package tests

import core_net "core:net"
import "core:testing"

import net "dr:net"
import "dr:sim"

@(test)
packet_hello_round_trips :: proc(t: ^testing.T) {
	buf: [64]byte
	n := net.encode_hello(buf[:], 1)
	kind, kok := net.peek_kind(buf[:n])
	testing.expect(t, kok)
	testing.expect_value(t, kind, net.Packet_Kind.Hello)
	player, ok := net.decode_hello(buf[:n])
	testing.expect(t, ok)
	testing.expect_value(t, player, u8(1))
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
