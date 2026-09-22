package sim

// Sounds are simulation events: U_Sound_Play draws pitch and volume from the
// gameplay RNG before it touches the audio device (and does so even with sound
// disabled), so the draws must happen here, in order. The presentation layer
// plays what the simulation emits.

// U_Sound_Settings: the six fields every sound-playing definition carries.
Sound_Settings :: struct {
	id:         Res_ID,
	min_volume: i32, // +0x04
	max_volume: i32, // +0x08 never read: see sound_play
	priority:   i32, // +0x0c
	min_pitch:  f32, // +0x10
	max_pitch:  f32, // +0x14
}

Sound_Event :: struct {
	id:       Res_ID,
	volume:   i32,
	priority: i32,
	pitch:    f32,
	loop:     bool,
}

MAX_SOUND_EVENTS :: 64

// U_Sound_Play(settings, loop) at 0x44f5f0.
//
// The original passes min_volume as *both* bounds of RandomInt, so the
// "random" volume is always the minimum and the call never draws. Reproduced:
// the equal-bounds call is still logged, exactly as the trace shows it.
sound_play :: proc "contextless" (s: ^State, st: Sound_Settings, loop: bool) {
	if st.id == NONE {
		return
	}
	record_event(s, Event{kind = .Sound, unit = st.id})
	pitch := random_float(&s.rng, st.min_pitch, st.max_pitch, 0x44f61d)
	volume := random_int(&s.rng, st.min_volume, st.min_volume, 0x44f632)
	if s.sounds.count < MAX_SOUND_EVENTS {
		s.sounds.events[s.sounds.count] = {st.id, volume, st.priority, pitch, loop}
		s.sounds.count += 1
	}
}

Sound_Queue :: struct {
	events: [MAX_SOUND_EVENTS]Sound_Event,
	count:  int,
}

state_sound :: proc "contextless" (st: ^Unit_State) -> Sound_Settings {
	return {
		id         = st.entry_sound,
		min_volume = st.entry_sound_min_volume,
		max_volume = st.entry_sound_max_volume,
		priority   = st.entry_sound_priority,
		min_pitch  = st.entry_sound_min_pitch,
		max_pitch  = st.entry_sound_max_pitch,
	}
}
