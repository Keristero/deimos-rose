package game

// U_Sound_Play (FUN_0044fab0): plays each Sound_Event the sim emitted this
// step.
//
// `loop` is not continuous audio looping -- genuine looping sounds
// (stateSoundLoop_BOOL) are already modeled in sim/eg_process.odin as
// periodic one-shot retriggers on a timer. It is the original's "always
// retrigger" (true) vs. "skip if a sound with this id is already playing"
// (false) flag, read off FUN_0044fab0 and its one caller that ever passes
// false, G_EG_Process (checked against soundAllowOnlyOneInstance across all
// 386 unit definitions: never set, so every sim/ call site passes true --
// see eg_process.odin). The `!loop` branch below exists for a hypothetical
// mod that does set it.
//
// Volume is 0-100 (FUN_0044fab0 clamps to that range before handing it to
// the mixer); pitch is already a 1.0-based multiplier (unit definitions'
// Min/MaxPitch fields run roughly 0.4-2.0), so both map onto raylib's sound
// controls directly.

import rl "vendor:raylib"

import "dr:sim"

sounds_step :: proc(t: ^Textures, s: ^sim.State) {
	for ev in s.sounds.events[:s.sounds.count] {
		clip, ok := &t.sounds[ev.id]
		if !ok {
			continue
		}
		if !ev.loop && rl.IsSoundPlaying(clip.voices[0]) {
			continue
		}
		v := clip.next
		clip.next = (clip.next + 1) % SOUND_VOICES
		snd := clip.voices[v]
		rl.SetSoundVolume(snd, f32(ev.volume) / 100.0)
		rl.SetSoundPitch(snd, ev.pitch)
		rl.PlaySound(snd)
	}
}
