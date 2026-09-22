package sim

// G_MotionBlur_New/_Process: a fading afterimage left behind by a fast-moving
// object. The original clones the whole Game_Object into its own list and,
// from then on, only ever subtracts a fixed amount from its visibility each
// step, deleting it once that crosses zero (G_MotionBlur_Process) -- frame,
// scale, tint and glow are frozen at the instant it was made.
//
// The trigger -- a random gap between blurs -- draws from the gameplay RNG,
// so that part stays in eg_process.odin next to the other RNG draws. This is
// just what that trigger hands off: a one-shot "a ghost was made here" event,
// on the same footing as Particle_Event and Stamp. Ageing and drawing the
// ghost afterwards is presentation's job, same as the terrain buffer owning
// what stamp_object hands it.
Blur_Event :: struct {
	obj: Game_Object, // frozen snapshot; visibility_delta is the fade rate
}

MAX_BLUR_EVENTS :: 16

Blur_Queue :: struct {
	events: [MAX_BLUR_EVENTS]Blur_Event,
	count:  int,
}

// G_MotionBlur_New. `st` is the moving object's own state, whose
// MotionBlur_* fields set the ghost's starting fade.
blur_spawn :: proc "contextless" (s: ^State, o: ^Game_Object, st: ^Unit_State) {
	q := &s.blurs
	if q.count >= MAX_BLUR_EVENTS {
		return
	}
	ghost := o^
	ghost.casts_shadow = false
	ghost.visibility = st.motion_blur_initial_visibility_percent
	ghost.visibility_target = 0
	ghost.visibility_delta = st.motion_blur_visibility_delta_percent
	if !st.motion_blur_allow_glow_drawing {
		ghost.glowing = false
	}
	q.events[q.count] = {obj = ghost}
	q.count += 1
}
