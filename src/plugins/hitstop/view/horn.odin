package hitstop_view

// The announcer's horns: a brass air-horn sting made here, a chord of two
// notes a major third apart, one blast for the first streaks, two from 3 and
// three from 6, each streak a little higher than the last up to an octave.
// Played with the call, under the voice.

import "core:math"

import rl "vendor:raylib"

HORN_RATE :: 44100
HORN_BLAST :: 0.26 // seconds a blast sounds
HORN_GAP :: 0.07

// How many blasts streak `n` gets.
horn_blasts :: proc "contextless" (n: int) -> int {
	return n >= 6 ? 3 : n >= 3 ? 2 : 1
}

// The lower note's frequency for streak `n`: G4 and a semitone up for each
// title, the octave at 12.
horn_pitch :: proc "contextless" (n: int) -> f32 {
	return 392 * math.pow(2, f32(min(streak_index(n) - 1, 12)) / 12)
}

// The samples, in -1..1. Pure, so the tests can look at them.
horn_samples :: proc(n: int, allocator := context.allocator) -> []f32 {
	blasts := horn_blasts(n)
	per := int((HORN_BLAST + HORN_GAP) * HORN_RATE)
	tail := int(0.3 * HORN_RATE) // the last blast rings out
	out := make([]f32, per * blasts + tail, allocator)
	base := f64(horn_pitch(n))
	phase: [2]f64
	for b in 0 ..< blasts {
		for i in 0 ..< per + (b == blasts - 1 ? tail : 0) {
			t := f64(i) / HORN_RATE
			// The last blast is longer and a note higher.
			len := HORN_BLAST * (b == blasts - 1 ? 1.5 : 1)
			if t > len + 0.25 {
				break
			}
			up := b == blasts - 1 && blasts > 1 ? 1.122 : 1.0
			vibrato := 1 + 0.012 * math.sin(2 * math.PI * 6 * t)
			env := f32(min(t / 0.015, 1)) * f32(t < len ? 1.0 : math.exp(-(t - len) * 18))
			v: f32
			for note in 0 ..< 2 {
				freq := base * (note == 0 ? 1.0 : 1.26) * up * vibrato
				phase[note] += 2 * math.PI * freq / HORN_RATE
				// A sawtooth's first harmonics: bright, brassy.
				for h in 1 ..= 7 {
					v += f32(math.sin(phase[note] * f64(h))) / f32(h) * 0.35
				}
			}
			idx := b * per + i
			out[idx] = math.tanh(out[idx] + v * env * 0.9)
		}
	}
	return out
}

// Sounds the horns for streak `n` at `volume` (0..1), when there is an audio
// device.
horn_play :: proc(n: int, volume: f32) {
	if !rl.IsAudioDeviceReady() {
		return
	}
	samples := horn_samples(n, context.temp_allocator)
	pcm := make([]i16, len(samples), context.temp_allocator)
	for v, i in samples {
		pcm[i] = i16(v * 30000)
	}
	if shared.horned {
		rl.StopSound(shared.horn)
		rl.UnloadSound(shared.horn)
	}
	wave := rl.Wave{frameCount = u32(len(pcm)), sampleRate = HORN_RATE, sampleSize = 16, channels = 1, data = raw_data(pcm)}
	shared.horn = rl.LoadSoundFromWave(wave) // copies
	shared.horned = true
	rl.SetSoundVolume(shared.horn, clamp(volume * 0.45, 0, 1))
	rl.PlaySound(shared.horn)
}

horn_destroy :: proc() {
	if shared.horned && rl.IsAudioDeviceReady() {
		rl.UnloadSound(shared.horn)
	}
	shared.horned = false
}
