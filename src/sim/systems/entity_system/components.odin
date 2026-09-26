package entity_system

// The components that turn on this package's stages, and the prefab builder
// that gives them to the states whose definitions ask for them
// (sim/prefabs.odin). Each holds the parameters its stage reads, copied from
// the state's definition, so the stage reads the component and a plugin can
// give the behaviour to a unit or state the definitions never gave it. A
// tag, with no fields, is a behaviour with nothing to set.

import "base:runtime"
import "dr:sim"

// stateParticles_*: a burst of particles on entering the state, or one
// every repeat_delay steps.
Emits_Particles :: struct {
	particles:    sim.Res_ID,
	color:        sim.Color,
	repeat:       bool,
	repeat_delay: i32,
	max_bursts:   i32, // 0 for no limit
}

// stateEntrySound_* and stateSound*: a sound on entering the state, or one
// every loop_delay steps.
Entry_Sound :: struct {
	sound:                  sim.Sound_Settings,
	loop:                   bool,
	repeat_on_state_change: bool,
	loop_delay:             i32,
	max_plays:              i32, // 0 for no limit
}

// The state has rules (rules.odin).
Follows_Rules :: struct {}

// useOwnersVisibility, useOwnersScale and visuallyReflectOwnerHits: which
// of its owner's looks the entity copies.
Follows_Owner_Look :: struct {
	visibility: bool,
	scale:      bool,
	hits:       bool,
}

// statePauseVerticalScrolling: the background holds while an entity is in
// the state.
Pauses_Scrolling :: struct {}

// stateDestructIfVerticalScrollingNotPaused: the entity is destroyed while
// the background scrolls.
Destructs_While_Scrolling :: struct {}

// state_MotionBlur_*: afterimages, one every min_gap..max_gap steps.
Motion_Blur :: struct {
	min_gap, max_gap:   i32,
	initial_visibility: f32,
	visibility_delta:   f32,
	allow_glow:         bool,
}

@(init)
register_components :: proc "contextless" () {
	context = runtime.default_context()
	sim.component_register(Emits_Particles)
	sim.component_register(Entry_Sound)
	sim.component_register(Follows_Rules)
	sim.component_register(Follows_Owner_Look)
	sim.component_register(Pauses_Scrolling)
	sim.component_register(Destructs_While_Scrolling)
	sim.component_register(Motion_Blur)
}

// A state's components, from the flags its definition sets. Each test is
// the one the original makes before the behaviour, so a stage asking for
// the component runs exactly where the original's test passes.
state_prefab :: proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
	if st.particles != sim.NONE {
		sim.prefab_add(p, Emits_Particles {
			particles = st.particles,
			color = st.particles_color,
			repeat = st.particles_repeat,
			repeat_delay = st.particles_repeat_delay,
			max_bursts = st.particles_max_num_bursts,
		})
	}
	if st.entry_sound != sim.NONE {
		sim.prefab_add(p, Entry_Sound {
			sound = sim.state_sound(st),
			loop = st.sound_loop,
			repeat_on_state_change = st.sound_repeat_on_state_change,
			loop_delay = st.sound_loop_delay,
			max_plays = st.sound_max_num_to_play,
		})
	}
	sim.prefab_tag(p, len(st.rules) > 0, Follows_Rules)
	if st.use_owners_visibility || st.use_owners_scale || st.visually_reflect_owner_hits {
		sim.prefab_add(p, Follows_Owner_Look {
			visibility = st.use_owners_visibility,
			scale = st.use_owners_scale,
			hits = st.visually_reflect_owner_hits,
		})
	}
	sim.prefab_tag(p, st.pause_vertical_scrolling, Pauses_Scrolling)
	sim.prefab_tag(p, st.destruct_if_vertical_scrolling_not_paused, Destructs_While_Scrolling)
	if st.motion_blur_required {
		sim.prefab_add(p, Motion_Blur {
			min_gap = st.motion_blur_min_time_between_blurs,
			max_gap = st.motion_blur_max_time_between_blurs,
			initial_visibility = st.motion_blur_initial_visibility_percent,
			visibility_delta = st.motion_blur_visibility_delta_percent,
			allow_glow = st.motion_blur_allow_glow_drawing,
		})
	}
}
