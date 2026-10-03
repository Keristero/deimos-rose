package hitstop_view

// The kill cam's reverb: a Schroeder reverb (four parallel combs through two
// allpasses, a pair of each per channel) on the whole mix, sound and music
// alike, through raylib's mixed-audio processor. The wet amount is the one
// number the view hands the audio thread; below a hair of it the processor
// does nothing.

import "base:intrinsics"

import rl "vendor:raylib"

COMB_LEN :: 2048
ALLPASS_LEN :: 700

@(private = "file") COMB_DELAYS := [2][4]int{{1557, 1617, 1491, 1422}, {1580, 1640, 1514, 1445}}
@(private = "file") ALLPASS_DELAYS := [2][2]int{{556, 441}, {579, 464}}
@(private = "file") FEEDBACK :: 0.86
@(private = "file") DAMPING :: 0.3

Reverb :: struct {
	comb:     [2][4][COMB_LEN]f32,
	comb_pos: [2][4]int,
	lowpass:  [2][4]f32,
	allpass:  [2][2][ALLPASS_LEN]f32,
	ap_pos:   [2][2]int,
}

// Reverberates `frames` of interleaved stereo in place, `wet` of the way
// (0 leaves it alone, 1 is mostly the room).
reverb_process :: proc "contextless" (rv: ^Reverb, buf: []f32, wet: f32) {
	for i := 0; i + 1 < len(buf); i += 2 {
		dry := [2]f32{buf[i], buf[i + 1]}
		feed := (dry.x + dry.y) * 0.25
		for c in 0 ..< 2 {
			sum: f32
			for k in 0 ..< 4 {
				pos := rv.comb_pos[c][k]
				echo := rv.comb[c][k][pos]
				rv.lowpass[c][k] = echo * (1 - DAMPING) + rv.lowpass[c][k] * DAMPING
				rv.comb[c][k][pos] = feed + rv.lowpass[c][k] * FEEDBACK
				rv.comb_pos[c][k] = (pos + 1) % COMB_DELAYS[c][k]
				sum += echo
			}
			for k in 0 ..< 2 {
				pos := rv.ap_pos[c][k]
				held := rv.allpass[c][k][pos]
				out := held - sum
				rv.allpass[c][k][pos] = sum + held * 0.5
				rv.ap_pos[c][k] = (pos + 1) % ALLPASS_DELAYS[c][k]
				sum = out
			}
			buf[i + c] = dry[c] * (1 - 0.3 * wet) + sum * wet * 1.1
		}
	}
}

@(private = "file") room: Reverb
@(private = "file") wet: f32 // what the audio thread reads
@(private = "file") attached: bool
@(private = "file") was_wet: bool

// Called on the audio thread with the mix as interleaved stereo f32.
@(private = "file")
processor :: proc "c" (buffer: rawptr, frames: u32) {
	amount := intrinsics.volatile_load(&wet)
	if amount < 0.002 {
		was_wet = false
		return
	}
	if !was_wet {
		room = {} // a room that was empty when it started
		was_wet = true
	}
	reverb_process(&room, ([^]f32)(buffer)[:int(frames) * 2], amount)
}

// Sets the reverb, 0 off to 1, attaching the processor the first time it
// is wanted; nothing without an audio device.
reverb_set :: proc(amount: f32) {
	if !attached {
		if amount <= 0 || !rl.IsAudioDeviceReady() {
			return
		}
		rl.AttachAudioMixedProcessor(processor)
		attached = true
	}
	intrinsics.volatile_store(&wet, clamp(amount, 0, 1))
}

reverb_destroy :: proc() {
	if attached && rl.IsAudioDeviceReady() {
		rl.DetachAudioMixedProcessor(processor)
	}
	attached = false
}
