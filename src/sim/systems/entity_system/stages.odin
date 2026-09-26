package entity_system

// The entities' step: G_EG_Process, and those of its stages that are about
// the entity's own state -- its appearance, timers, animation, rules and
// spawning. Moving, colliding and being aimed at are the stages of
// movement_system, collision_system and weapon_system, placed among these
// by sim/core.

import "dr:sim"
import "dr:sim/lifecycle"

// G_EG_Process: one step for every entity, in group order, each through
// every entity stage (sim/core has their order) before the next. The sweep of deleted
// entities that ends G_EG_Process is its own system (sweep_system).
//
// Returns true when some entity's state asks for vertical scrolling to pause.
// Branches not ported yet mark themselves with `unported`.
eg_process :: proc(s: ^sim.State, time: i32) -> (pause_scrolling: bool) {
	w := sim.single(s, sim.Pool)
	gc := sim.Cursor{sim.NO_LINK}
	for gi_n: i32 = 0; gi_n < w.active.count; gi_n += 1 {
		gi := sim.list_next(&w.active, sim.group_links(s), &gc)
		ec := sim.Cursor{sim.NO_LINK}
		for n: i32 = 0; n < sim.group_at(s, gi).entities.count; n += 1 {
			ei := sim.list_next(&sim.group_at(s, gi).entities, sim.entity_links(s), &ec)
			e := sim.entity_at(s, ei)
			es := sim.entity_step(s, e, time)
			sim.run_entity_stages(s, e, &es)
			if es.pause {
				pause_scrolling = true
			}
		}
	}
	return
}

// The body of G_EG_Process's inner loop, stage by stage. A stage that ends
// the entity's step returns false, where the original returns.

// An entity waits out its appear delay before anything else happens to it.
appear_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	e.appear_delay -= 1
	if e.appear_delay >= 1 {
		e.state_time = es.time
		return false
	}
	return true
}

state_particles_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	st := es.st
	if st.particles == sim.NONE {
		return true
	}
	due := false
	if !st.particles_repeat {
		due = e.particle_count == 0
	} else {
		due = e.particle_time == 0 || e.particle_time + st.particles_repeat_delay <= es.time
	}
	if due {
		if st.particles_max_num_bursts == 0 || e.particle_count < st.particles_max_num_bursts {
			sim.particle_burst(s, e.loc, st.particles_color, st.particles, es.u.is_ground_based)
		}
		e.particle_count += 1
		e.particle_time = es.time
	}
	return true
}

entry_sound_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	st := es.st
	play := false
	if st.entry_sound != sim.NONE {
		if !st.sound_loop {
			if e.entry_counts[e.state] == 1 {
				play = e.sound_count == 0
			} else if st.sound_repeat_on_state_change {
				play = e.sound_count == 0
			}
		} else if e.sound_time == 0 || e.sound_time + st.sound_loop_delay <= es.time {
			play = true
		}
	}
	if play {
		// G_EG_Process 0x4185f6: when soundAllowOnlyOneInstance is set, a
		// sound already sounding skips this trigger -- and the RNG draws
		// inside U_Sound_Play -- entirely (checked: the IsPlaying test at
		// 0x418614 runs before U_Sound_Play is ever called, not after).
		// U_Sound_IsPlaying(0x44f6d0) answers from the audio device's own
		// list of live handles, which the sim has no notion of, and the flag
		// is false on all 386 shipped unit definitions, every state, so the
		// skip never fires with real data. Always playing here -- never
		// skipping -- is the conservative match for that: it can only add
		// an RNG draw a mod using the flag would expect anyway, never drop
		// one the original would have made.
		if st.sound_max_num_to_play == 0 || e.sound_count < st.sound_max_num_to_play {
			sim.sound_play(s, sim.state_sound(st), true)
		}
		e.sound_count += 1
		e.sound_time = es.time
	}
	return true
}

// The state timer.
state_timer_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if es.time != e.state_time + e.timer {
		return true
	}
	to := es.st.on_timer_change_to
	switch {
	case to == "Delete":
		lifecycle.entity_delete(e)
		return false
	case to == "Destroy":
		lifecycle.entity_destroy(s, e, -1, es.time)
		return false
	case to != "" && to != "none":
		del, des := lifecycle.change_state(s, e, false, to, es.time)
		if !lifecycle.entity_carry_on(s, e, del, des, es.time) {
			return false
		}
		sim.entity_step_state(s, e, es)
	}
	return true
}

scroll_pause_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if es.st.pause_vertical_scrolling {
		es.pause = true
	}
	return true
}

animate_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	lifecycle.entity_animate(s, e, es.time)
	return true
}

rules_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if len(es.st.rules) == 0 {
		return true
	}
	del, des := process_rules(s, e, es.time)
	if !lifecycle.entity_carry_on(s, e, del, des, es.time) {
		return false
	}
	sim.entity_step_state(s, e, es)
	return true
}

// The state's look: visibility, tint, scale, size and glow.
appearance_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	st := es.st
	e.visibility_target = f32(st.required_visibility_percent)
	e.visibility_delta = f32(st.visibility_delta_percent)
	e.colorise = st.do_colorise
	e.tint_target = f32(st.tint_percent)
	e.tint_delta = f32(st.tint_delta_percent)
	e.tint_color = sim.color_1555(st.tint_color)
	lifecycle.adjust_visibility_and_tinting(e.obj)
	e.hittable = true
	if e.visibility < 100 && !es.u.hittable_when_invisible {
		e.hittable = false
	}
	e.scale_target = f32(st.required_scale_percent) / 100
	e.scale_delta = f32(st.scale_delta_percent) / 100
	lifecycle.do_scaling(e.obj)
	lifecycle.calculate_dimensions(s, e.obj)
	lifecycle.glow_process(e.obj)
	return true
}

// FUN_0041b5d0: follow the owner's look -- its visibility, scale, and
// (visuallyReflectOwnerHits) its hit glow, so a turret's dome flashes with
// its base.
owner_look_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	st := es.st
	if !(st.use_owners_visibility || st.use_owners_scale || st.visually_reflect_owner_hits) || !sim.ref_valid(s, e.owner) {
		return true
	}
	o := sim.entity_at(s, e.owner.index)
	if st.use_owners_visibility {
		e.visibility = o.visibility
	}
	if st.use_owners_scale {
		e.dims_dirty = o.dims_dirty
		e.scale, e.scale_target, e.scale_delta = o.scale, o.scale_target, o.scale_delta
		lifecycle.calculate_dimensions(s, e.obj)
	}
	if st.visually_reflect_owner_hits {
		e.glowing, e.glow_falling = o.glowing, o.glow_falling
		e.glow_amount, e.glow_speed, e.glow_color = o.glow_amount, o.glow_speed, o.glow_color
	}
	return true
}

scroll_destruct_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if es.st.destruct_if_vertical_scrolling_not_paused && sim.single(s, sim.Bgnd).speed != 0 {
		lifecycle.entity_destroy(s, e, -1, es.time)
		return false
	}
	return true
}

// SpawnControl, and the bounds the later stages test against.
spawn_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	if e.spawn_pace == 0 {
		spawn_control(s, e, es.time)
	} else {
		paced_spawn_control(s, e)
	}
	if e.deleted {
		return false
	}
	es.bounds = lifecycle.object_bounds(e.obj)
	return true
}

motion_blur_stage :: proc(s: ^sim.State, e: sim.Entity, es: ^sim.Entity_Step) -> bool {
	st := es.st
	if st.motion_blur_required && e.sprite != sim.NONE {
		gap := sim.roll_int(s, st.motion_blur_min_time_between_blurs, st.motion_blur_max_time_between_blurs, 0x418d92)
		if e.blur_time + gap < es.time {
			e.blur_time = es.time
			sim.blur_spawn(s, e.obj, st)
		}
	}
	return true
}

entities_system :: proc(s: ^sim.State, step: ^sim.Step) {
	step.pause_scrolling = eg_process(s, sim.single(s, sim.Clock).time)
}
