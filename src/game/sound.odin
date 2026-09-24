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
// Volume is 0-100 and maps onto raylib's directly. Pitch does not: the
// original's is a *stretch*, the reciprocal of a playback rate.
// ST_PlaySoundParam (0x467600) sets a voice's step to
// UFix32_Divide(gSampleRate, clip rate) * pitch, all 16.16, and
// ADPCM_Mixer (0x489940) decodes one input sample per iteration and writes
// as many output samples as that step's running sum crosses -- output
// samples per input sample. So a pitch of 2 plays at half speed, an octave
// down. Unit definitions lean on this: the Rear Gun's rgbs plays lgbu at
// 0.4-0.55 (high and quick), the Photon Beam's pbbf the same sample at
// 1.2-1.3 (low). A pitch of 0 never advances the output, so it is silent.

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
		if ev.pitch <= 0 {
			continue
		}
		v := clip.next
		clip.next = (clip.next + 1) % SOUND_VOICES
		snd := clip.voices[v]
		rl.SetSoundVolume(snd, f32(ev.volume) / 100.0 * t.sfx_volume)
		rl.SetSoundPitch(snd, 1 / ev.pitch)
		rl.PlaySound(snd)
	}
}
