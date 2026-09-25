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
	Hello           = 1,  // "I'm here, this is my player slot" -- the reliable channel
	Ready           = 2,  // "start when you like" -- the reliable channel
	Goodbye         = 3,  // clean disconnect -- the reliable channel
	Ping            = 4,  // RTT probe, unreliable, sent on a timer
	Pong            = 5,  // Ping's reply, echoes the same nonce
	Input           = 6,  // a player's recent input history, unreliable and redundant
	Ack             = 7,  // acknowledges one Hello/Ready/Goodbye/Start by its seq
	Checksum        = 8,  // one frame's sim.checksum(), for desync detection
	Start           = 9,  // host -> guest: "begin now", carries the session seed and level -- the reliable channel
	Level_Choice    = 10, // host -> guest: the host's currently-selected level index, sent every lobby frame like Ping -- unreliable, so just resent rather than acked
	Resync_Start    = 11, // survivor -> reconnecting peer: "here comes the game state", carries the assigned player slot and total byte count -- the reliable channel
	State_Chunk     = 12, // survivor -> reconnecting peer: one piece of a raw sim.State dump -- its own stop-and-wait, not the reliable channel (too big for its small buf)
	State_Chunk_Ack = 13, // reconnecting peer -> survivor: "got that chunk, send the next"
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
	case .Hello, .Ready, .Goodbye, .Ping, .Pong, .Input, .Ack, .Checksum, .Start, .Level_Choice,
	     .Resync_Start, .State_Chunk, .State_Chunk_Ack:
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

// Hello, Ready and Goodbye all carry a seq byte (byte 1) -- see
// net/reliable.odin -- so each can be resent verbatim until acked and a
// duplicate delivery can be told apart from a new message.

// Hello also carries who the sender is: their accent hue (u16 degrees,
// drawn round their ship and on their crosshair and shots) and their name
// (a length byte, then up to HELLO_NAME_MAX bytes), so each side can record
// both players' high scores under their own names when a netplay game ends.
// A longer name is cut short rather than refused.
HELLO_NAME_MAX :: 20
HELLO_SIZE_MAX :: 6 + HELLO_NAME_MAX

encode_hello :: proc(buf: []byte, seq: u8, player: u8, hue: u16, name: string) -> int {
	cut := name[:min(len(name), HELLO_NAME_MAX)]
	buf[0] = u8(Packet_Kind.Hello)
	buf[1] = seq
	buf[2] = player
	buf[3] = u8(hue); buf[4] = u8(hue >> 8)
	buf[5] = u8(len(cut))
	copy(buf[6:], cut)
	return 6 + len(cut)
}

// `name` is a view into `buf`: copy it out before buf is reused.
decode_hello :: proc(buf: []byte) -> (seq: u8, player: u8, hue: u16, name: string, ok: bool) {
	if len(buf) < 6 || Packet_Kind(buf[0]) != .Hello {
		return
	}
	n := int(buf[5])
	if n > HELLO_NAME_MAX || len(buf) < 6 + n {
		return
	}
	return buf[1], buf[2], u16(buf[3]) | u16(buf[4]) << 8, string(buf[6:6 + n]), true
}

encode_ready :: proc(buf: []byte, seq: u8) -> int {
	buf[0] = u8(Packet_Kind.Ready)
	buf[1] = seq
	return 2
}

decode_ready :: proc(buf: []byte) -> (seq: u8, ok: bool) {
	if len(buf) < 2 || Packet_Kind(buf[0]) != .Ready {
		return 0, false
	}
	return buf[1], true
}

encode_goodbye :: proc(buf: []byte, seq: u8) -> int {
	buf[0] = u8(Packet_Kind.Goodbye)
	buf[1] = seq
	return 2
}

decode_goodbye :: proc(buf: []byte) -> (seq: u8, ok: bool) {
	if len(buf) < 2 || Packet_Kind(buf[0]) != .Goodbye {
		return 0, false
	}
	return buf[1], true
}

encode_ack :: proc(buf: []byte, seq: u8) -> int {
	buf[0] = u8(Packet_Kind.Ack)
	buf[1] = seq
	return 2
}

decode_ack :: proc(buf: []byte) -> (seq: u8, ok: bool) {
	if len(buf) < 2 || Packet_Kind(buf[0]) != .Ack {
		return 0, false
	}
	return buf[1], true
}

// Start carries the session the host picked (a random seed and a 0-based
// level list index -- Phase 6 stage 5's first cut always starts at level 1,
// so this is currently always 0, but the field exists so that isn't baked
// into the wire format). Sent once, over the reliable channel like Hello/
// Ready/Goodbye, so the guest is guaranteed to receive it before the host
// begins stepping (net/reliable.odin's stop-and-wait blocks the host's own
// transition on the Ack -- see game/netplay.odin).
//
// The eighth byte is the session's flags (START_EASY: easy mode,
// START_LOADOUT: new weapons). A build from before it sends seven bytes,
// which decode as no flags.
START_EASY :: 0x01
START_LOADOUT :: 0x02

encode_start :: proc(buf: []byte, seq: u8, seed: u32, level: u8, flags: u8 = 0) -> int {
	buf[0] = u8(Packet_Kind.Start)
	buf[1] = seq
	put_u32(buf[2:], seed)
	buf[6] = level
	buf[7] = flags
	return 8
}

decode_start :: proc(buf: []byte) -> (seq: u8, seed: u32, level: u8, flags: u8, ok: bool) {
	if len(buf) < 7 || Packet_Kind(buf[0]) != .Start {
		return 0, 0, 0, 0, false
	}
	return buf[1], get_u32(buf[2:]), buf[6], len(buf) >= 8 ? buf[7] : 0, true
}

// Level_Choice carries a 0-based index into Flow.defs.levels, not a
// Level_Def id -- the guest mirrors it purely for display (Phase 8 stage 2's
// read-only "HOST HAS CHOSEN..." line) and never looks it up itself, so no
// resolution is needed on the wire. Unreliable and sent every lobby frame
// the host has one picked, same redundancy-instead-of-acks reasoning as
// Input: a dropped one is invisible since the next one due (a frame later)
// repeats the same value. The host's choice of flags (Start's, START_EASY)
// rides along the same way, for the guest's display; Start is what counts.
encode_level_choice :: proc(buf: []byte, level_index: u8, flags: u8 = 0) -> int {
	buf[0] = u8(Packet_Kind.Level_Choice)
	buf[1] = level_index
	buf[2] = flags
	return 3
}

decode_level_choice :: proc(buf: []byte) -> (level_index: u8, flags: u8, ok: bool) {
	if len(buf) < 2 || Packet_Kind(buf[0]) != .Level_Choice {
		return 0, 0, false
	}
	return buf[1], len(buf) >= 3 ? buf[2] : 0, true
}

// Resync_Start (Phase 8 stage 3/4: pause on disconnect + reconnect) carries
// which player slot the reconnecting peer should take over (whichever one
// the survivor isn't -- the survivor already knows its own from
// Rollback_Session.local_player) and how many bytes of raw sim.State the
// State_Chunk stream that follows will add up to. Sent once, over the
// reliable channel like Hello/Ready/Goodbye/Start -- its own 7 bytes fit
// Reliable_Channel's buf easily.
encode_resync_start :: proc(buf: []byte, seq: u8, assigned_player: u8, total_size: u32) -> int {
	buf[0] = u8(Packet_Kind.Resync_Start)
	buf[1] = seq
	buf[2] = assigned_player
	put_u32(buf[3:], total_size)
	return 7
}

decode_resync_start :: proc(buf: []byte) -> (seq: u8, assigned_player: u8, total_size: u32, ok: bool) {
	if len(buf) < 7 || Packet_Kind(buf[0]) != .Resync_Start {
		return 0, 0, 0, false
	}
	return buf[1], buf[2], get_u32(buf[3:]), true
}

// State_Chunk carries one piece of a raw byte-for-byte sim.State dump --
// pointer fields and all; the receiver overwrites those from its own local
// state after the transfer completes (game/netplay.odin), the same way
// sim.init resolves a level id into a pointer rather than trusting one sent
// over the wire. Its own stop-and-wait (game/netplay.odin), not
// net/reliable.odin's channel: STATE_CHUNK_SIZE payloads don't fit that
// channel's small buf, sized for Hello/Ready/Goodbye/Start/Resync_Start and
// nothing bigger by design.
STATE_CHUNK_SIZE :: 1024

encode_state_chunk :: proc(buf: []byte, chunk_index: u16, payload: []byte) -> int {
	buf[0] = u8(Packet_Kind.State_Chunk)
	buf[1] = u8(chunk_index); buf[2] = u8(chunk_index >> 8)
	copy(buf[3:], payload)
	return 3 + len(payload)
}

State_Chunk_Packet :: struct {
	chunk_index: u16,
	payload:     [STATE_CHUNK_SIZE]byte,
	length:      int,
}

decode_state_chunk :: proc(buf: []byte) -> (p: State_Chunk_Packet, ok: bool) {
	if len(buf) < 3 || Packet_Kind(buf[0]) != .State_Chunk {
		return {}, false
	}
	p.chunk_index = u16(buf[1]) | u16(buf[2]) << 8
	p.length = len(buf) - 3
	if p.length > STATE_CHUNK_SIZE {
		return {}, false
	}
	copy(p.payload[:p.length], buf[3:])
	return p, true
}

encode_state_chunk_ack :: proc(buf: []byte, chunk_index: u16) -> int {
	buf[0] = u8(Packet_Kind.State_Chunk_Ack)
	buf[1] = u8(chunk_index); buf[2] = u8(chunk_index >> 8)
	return 3
}

decode_state_chunk_ack :: proc(buf: []byte) -> (chunk_index: u16, ok: bool) {
	if len(buf) < 3 || Packet_Kind(buf[0]) != .State_Chunk_Ack {
		return 0, false
	}
	return u16(buf[1]) | u16(buf[2]) << 8, true
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
