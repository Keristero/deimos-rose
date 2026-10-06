package hitstop_view

// The announcer: a voice that calls each kill streak. The clips, spoken by
// Moonshine TTS (announcer/generate.sh), are embedded: one per streak title
// and the two prefixes. A streak past 50 plays "Super" and then its title,
// past 100 "Super Duper", then "Mega" and on (announcer/modifiers.txt, a tier
// for each 50 kills to 2000), joined into one sound so they run on without a gap.
// The husky one is always at normal speed and pitch, so it stays understandable: the kill
// cam's audio slowdown leaves it alone (only the kill cam's reverb, on the
// mix, is on it).

import "core:fmt"

import rl "vendor:raylib"

@(private = "file") CLIPS := #load_directory("clips")
@(private = "file") CLIPS_P2 := #load_directory("clips_p2")

// Who calls the streak: player 1 (and the odd ones') husky announcer, or
// player 2's Australian who gets angrier as the streak climbs.
Announcer :: enum {
	Husky,
	Aussie,
}

announcer_of :: proc "contextless" (player: int) -> Announcer {
	return player % 2 == 1 ? .Aussie : .Husky
}

@(private = "file") voice: rl.Sound
@(private = "file") voiced: bool
@(private = "file") VOICE_GAIN :: 3.3 // over the mix: the clips peak just under full scale, the blow and the music are louder

// The embedded clip called `name` ("07", "super"), by its file.
@(private = "file")
clip_named :: proc(name: string, who := Announcer.Husky) -> (bytes: []byte, ok: bool) {
	want := fmt.tprintf("%s.wav", name)
	for c in who == .Aussie ? CLIPS_P2 : CLIPS {
		if c.name == want {
			return c.data, true
		}
	}
	return
}

// How many 22.05 kHz mono frames the embedded clip `name` decodes to; 0 when
// it is missing or does not decode. Needs no audio device (the tests).
announcer_frames :: proc(name: string, who := Announcer.Husky) -> int {
	bytes, ok := clip_named(name, who)
	if !ok {
		return 0
	}
	wave := rl.LoadWaveFromMemory(".wav", raw_data(bytes), i32(len(bytes)))
	defer rl.UnloadWave(wave)
	if wave.data == nil || wave.sampleRate != 22050 || wave.channels != 1 || wave.sampleSize != 16 {
		return 0
	}
	return int(wave.frameCount)
}

// The names of the clips streak `n` is said with, in order.
announcer_clips :: proc(n: int, allocator := context.temp_allocator, who := Announcer.Husky) -> []string {
	names := make([dynamic]string, 0, 2, allocator)
	mad := who == .Aussie && rage_stage(n) >= RAGE_SHOUTING
	suffix := mad ? "_mad" : ""
	if tier := streak_tier(n); tier > 0 {
		append(&names, fmt.aprintf("%s%s", streak_modifier_clip(tier, allocator), suffix, allocator = allocator))
	}
	append(&names, fmt.aprintf("%02d%s", streak_index(n), suffix, allocator = allocator))
	if who == .Aussie {
		append(&names, rage_clip(n, allocator))
	}
	return names[:]
}

// Calls streak `n` at `volume` (0..1), at normal pitch (the Australian's rises
// with his temper). Quiet
// without an audio device or without the clips.
announce :: proc(n: int, volume: f32, who := Announcer.Husky) {
	if !rl.IsAudioDeviceReady() {
		rl.TraceLog(.WARNING, "announcer: no audio device")
		return
	}
	pcm := make([dynamic]i16, 0, 44100, context.temp_allocator)
	for name in announcer_clips(n, who = who) {
		bytes, ok := clip_named(name, who)
		if !ok {
			continue
		}
		wave := rl.LoadWaveFromMemory(".wav", raw_data(bytes), i32(len(bytes)))
		if wave.data == nil {
			continue
		}
		if wave.sampleSize != 16 || wave.channels != 1 {
			rl.WaveFormat(&wave, i32(wave.sampleRate), 16, 1)
		}
		append(&pcm, ..([^]i16)(wave.data)[:wave.frameCount])
		rl.UnloadWave(wave)
	}
	if len(pcm) == 0 {
		rl.TraceLog(.WARNING, "announcer: streak %d has no clips", i32(n))
		return
	}
	rl.TraceLog(.INFO, "announcer: streak %d, %d frames, volume %.2f", i32(n), i32(len(pcm)), volume)
	if voiced {
		rl.StopSound(voice)
		rl.UnloadSound(voice)
	}
	wave := rl.Wave{frameCount = u32(len(pcm)), sampleRate = 22050, sampleSize = 16, channels = 1, data = raw_data(pcm)}
	voice = rl.LoadSoundFromWave(wave) // copies
	voiced = true
	gain, pitch := f32(1), f32(1)
	if who == .Aussie {
		gain, pitch = rage_gain(n), rage_pitch(n)
	}
	rl.SetSoundVolume(voice, clamp(volume, 0, 2) * VOICE_GAIN * gain)
	rl.SetSoundPitch(voice, pitch)
	rl.PlaySound(voice)
}

announcer_destroy :: proc() {
	if voiced && rl.IsAudioDeviceReady() {
		rl.UnloadSound(voice)
	}
	voiced = false
}
