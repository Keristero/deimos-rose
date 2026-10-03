package hitstop_view

// The takedown's boom, made here rather than shipped: a sine that falls from
// 90 Hz to 25 Hz with a burst of low rumble at the front, driven through a
// soft clip so it is loud and fat. A second of it, 16-bit mono, built the
// first time a takedown needs it.

import "core:math"

import rl "vendor:raylib"

BOOM_RATE :: 44100
BOOM_SECONDS :: 1.8

@(private = "file") boom: rl.Sound
@(private = "file") boom_made: bool

// The samples, in -1..1. Pure, so the tests can look at them.
boom_samples :: proc(allocator := context.allocator) -> []f32 {
	n := int(BOOM_RATE * BOOM_SECONDS)
	out := make([]f32, n, allocator)
	phase: f64
	noise: f32 // low-passed noise
	seed := u32(0x9e3779b9)
	for i in 0 ..< n {
		t := f64(i) / BOOM_RATE
		freq := 25 + 65 * math.exp(-t * 3.2)
		phase += 2 * math.PI * freq / BOOM_RATE
		seed = seed * 1664525 + 1013904223
		white := f32(seed >> 8) / f32(1 << 24) * 2 - 1
		noise += (white - noise) * 0.04
		attack := f32(min(t / 0.004, 1))
		body := f32(math.exp(-t * 2.2)) * attack
		rumble := f32(math.exp(-t * 7)) * attack
		v := f32(math.sin(phase)) * body * 2.4 + noise * rumble * 6
		out[i] = math.tanh(v)
	}
	return out
}

// Plays it at `volume` (0..1), when there is an audio device.
boom_play :: proc(volume: f32) {
	if !rl.IsAudioDeviceReady() {
		return
	}
	if !boom_made {
		boom_made = true
		samples := boom_samples(context.temp_allocator)
		pcm := make([]i16, len(samples), context.temp_allocator)
		for v, i in samples {
			pcm[i] = i16(v * 32000)
		}
		wave := rl.Wave{frameCount = u32(len(pcm)), sampleRate = BOOM_RATE, sampleSize = 16, channels = 1, data = raw_data(pcm)}
		boom = rl.LoadSoundFromWave(wave) // copies
	}
	rl.SetSoundVolume(boom, clamp(volume, 0, 1))
	rl.PlaySound(boom)
}

boom_destroy :: proc() {
	if boom_made && rl.IsAudioDeviceReady() {
		rl.UnloadSound(boom)
	}
	boom_made = false
}
