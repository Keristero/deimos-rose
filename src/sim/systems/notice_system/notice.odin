package notice_system

// G_Notice: an on-screen text popup a unit's definition can trigger on entry
// (entryNotice_STR) or destruction (destructNotice_STR). Checked against
// every shipped unit definition: both fields are empty on all 386 of them,
// so this path is dead in the real game -- no level ever shows one. Ported
// anyway for completeness (it replaces a stale `unported` marker), since a
// unit could set either field.
//
// The popup itself is presentation, but G_Notice_Process plays the notice's
// sound once its display delay elapses, and that draws from the gameplay
// RNG, so the timing of that draw has to be reproduced here. One notice is
// pending at a time, matching G_Notice_Request's single global slot -- a
// request while one is already showing is dropped, not queued.
//
// G_Notice_Process itself also runs a typewriter reveal and a fade-out
// (G_Res_GetPermFloat 0x47-0x49) that keep the slot busy after the sound
// plays; reproducing that byte for byte has no effect on the RNG stream, so
// this just holds the slot for a fixed span instead (see notice_process).

import "dr:sim"

// FUN_0041cdf0 -> G_Notice_Request: a unit's entry notice.
notice_request :: proc "contextless" (s: ^sim.State, u: ^sim.Unit, time: i32) {
	if u.entry_notice == "" || u.entry_notice == "none" {
		return
	}
	notice_show(s, u.entry_notice, sim.Sound_Settings {
		id         = u.entry_notice_sound,
		min_volume = u.entry_notice_sound_min_volume,
		max_volume = u.entry_notice_sound_max_volume,
		priority   = u.entry_notice_sound_priority,
		min_pitch  = u.entry_notice_sound_min_pitch,
		max_pitch  = u.entry_notice_sound_max_pitch,
	}, u.entry_notice_delay)
}

// 0x415328 -> G_Notice_Request, called from G_Entity::Destroy. destructNotice
// has no accompanying sound fields in the definitions, so this branch never
// draws from the RNG.
notice_request_destruct :: proc "contextless" (s: ^sim.State, text: string) {
	if text == "" || text == "none" {
		return
	}
	notice_show(s, text, sim.Sound_Settings{id = sim.NONE}, 0)
}

@(private = "file")
notice_show :: proc "contextless" (s: ^sim.State, text: string, sound: sim.Sound_Settings, delay: i32) {
	n := sim.single(s, sim.Notice_State)
	if n.pending {
		return
	}
	n.sound = sound
	n.delay = delay
	n.pending = true
	q := &s.notices
	if q.count < sim.MAX_NOTICE_EVENTS {
		q.events[q.count] = {text}
		q.count += 1
	}
}

// G_Notice_Process: once the delay counter reaches zero, play the notice's
// sound (if any) exactly once, then hold the slot briefly before releasing
// it for the next request.
notice_process :: proc "contextless" (s: ^sim.State) {
	n := sim.single(s, sim.Notice_State)
	if !n.pending {
		return
	}
	if n.delay > 0 {
		n.delay -= 1
		return
	}
	if n.delay == 0 {
		if n.sound.id != sim.NONE {
			sim.sound_play(s, n.sound, true)
		}
	}
	n.delay -= 1
	if n.delay <= -sim.NOTICE_HOLD_FRAMES {
		n.pending = false
	}
}

// G_Notice_Process. Like G_Particle_Process and G_MotionBlur_Process beside
// it, it does not draw.
notices_system :: proc(s: ^sim.State, step: ^sim.Step) {
	notice_process(s)
}
