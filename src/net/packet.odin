// Package name is `netplay`, not `net`: this package's own directory is
// src/net/ (matching the plan's tree sketch) and is imported as "dr:net", but
// `core:net` itself already declares `package net`, and two packages built
// into the same program cannot share a declared name. Callers alias the
// import instead: `import net "dr:net"`.
package netplay

// Phase 6 stage 2: the wire format. Encoding is explicit byte-by-byte (fixed
// little-endian) rather than a transmuted struct, so the layout is the same
// regardless of what compiler or struct-packing rules built either end --
// the whole point of hand-rolling this instead of using vendor:ENet is to
// control exactly what goes on the wire and why.

import "dr:sim"

Packet_Kind :: enum u8 {
	Hello   = 1, // "I'm here, this is my player slot" -- the reliable channel
	Ready   = 2, // "start when you like" -- the reliable channel
	Goodbye = 3, // clean disconnect -- the reliable channel
	Ping    = 4, // RTT probe, unreliable, sent on a timer
	Pong    = 5, // Ping's reply, echoes the same nonce
	Input   = 6, // a player's recent input history, unreliable and redundant
}

// How many consecutive frames of input one packet can carry. Sized so a
// packet can absorb several dropped packets in a row before a gap opens up:
// at 30 Hz and one Input packet sent per step, a run of up to
// MAX_INPUT_FRAMES-1 consecutive losses is still fully covered by the next
// packet that gets through.
MAX_INPUT_FRAMES :: 32

peek_kind :: proc(buf: []byte) -> (kind: Packet_Kind, ok: bool) {
	if len(buf) < 1 {
		return {}, false
	}
	k := Packet_Kind(buf[0])
	switch k {
	case .Hello, .Ready, .Goodbye, .Ping, .Pong, .Input:
		return k, true
	}
	return {}, false
}

@(private = "file")
put_u32 :: proc(b: []byte, v: u32) {
	b[0] = u8(v); b[1] = u8(v >> 8); b[2] = u8(v >> 16); b[3] = u8(v >> 24)
}

@(private = "file")
get_u32 :: proc(b: []byte) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private = "file")
put_u64 :: proc(b: []byte, v: u64) {
	for i in 0 ..< 8 {
		b[i] = u8(v >> uint(i * 8))
	}
}

@(private = "file")
get_u64 :: proc(b: []byte) -> u64 {
	v: u64
	for i in 0 ..< 8 {
		v |= u64(b[i]) << uint(i * 8)
	}
	return v
}

encode_hello :: proc(buf: []byte, player: u8) -> int {
	buf[0] = u8(Packet_Kind.Hello)
	buf[1] = player
	return 2
}

decode_hello :: proc(buf: []byte) -> (player: u8, ok: bool) {
	if len(buf) < 2 || Packet_Kind(buf[0]) != .Hello {
		return 0, false
	}
	return buf[1], true
}

encode_ready :: proc(buf: []byte) -> int {
	buf[0] = u8(Packet_Kind.Ready)
	return 1
}

encode_goodbye :: proc(buf: []byte) -> int {
	buf[0] = u8(Packet_Kind.Goodbye)
	return 1
}

// Ping and Pong share a layout (a nonce to echo back); the kind byte is what
// tells them apart, so decoding either checks for its own kind specifically
// rather than accepting both.
encode_ping :: proc(buf: []byte, nonce: u64) -> int {
	buf[0] = u8(Packet_Kind.Ping)
	put_u64(buf[1:], nonce)
	return 9
}

decode_ping :: proc(buf: []byte) -> (nonce: u64, ok: bool) {
	if len(buf) < 9 || Packet_Kind(buf[0]) != .Ping {
		return 0, false
	}
	return get_u64(buf[1:]), true
}

encode_pong :: proc(buf: []byte, nonce: u64) -> int {
	buf[0] = u8(Packet_Kind.Pong)
	put_u64(buf[1:], nonce)
	return 9
}

decode_pong :: proc(buf: []byte) -> (nonce: u64, ok: bool) {
	if len(buf) < 9 || Packet_Kind(buf[0]) != .Pong {
		return 0, false
	}
	return get_u64(buf[1:]), true
}

// frames[0] is the input for `start_frame`; up to MAX_INPUT_FRAMES are
// packed in, oldest first. sim.Buttons is a u16 bit_set, so each frame costs
// two bytes on the wire.
encode_input :: proc(buf: []byte, player: u8, start_frame: u32, frames: []sim.Buttons) -> int {
	count := min(len(frames), MAX_INPUT_FRAMES)
	buf[0] = u8(Packet_Kind.Input)
	buf[1] = player
	put_u32(buf[2:], start_frame)
	buf[6] = u8(count)
	o := 7
	for i in 0 ..< count {
		v := transmute(u16)frames[i]
		buf[o] = u8(v); buf[o + 1] = u8(v >> 8)
		o += 2
	}
	return o
}

Input_Packet :: struct {
	player:      u8,
	start_frame: u32,
	frames:      [MAX_INPUT_FRAMES]sim.Buttons,
	count:       int,
}

decode_input :: proc(buf: []byte) -> (p: Input_Packet, ok: bool) {
	if len(buf) < 7 || Packet_Kind(buf[0]) != .Input {
		return {}, false
	}
	p.player = buf[1]
	p.start_frame = get_u32(buf[2:])
	p.count = int(buf[6])
	if p.count > MAX_INPUT_FRAMES || len(buf) < 7 + p.count * 2 {
		return {}, false
	}
	o := 7
	for i in 0 ..< p.count {
		v := u16(buf[o]) | u16(buf[o + 1]) << 8
		p.frames[i] = transmute(sim.Buttons)v
		o += 2
	}
	return p, true
}
