package sim

// G_MotionBlur_New/_Process: a fading afterimage left behind by a fast-moving
// object. The original clones the whole Game_Object into its own list and,
// from then on, only ever subtracts a fixed amount from its visibility each
// step, deleting it once that crosses zero (G_MotionBlur_Process) -- frame,
// scale, tint and glow are frozen at the instant it was made.
//
// The trigger -- a random gap between blurs -- draws from the gameplay RNG,
// so that part stays in entity_system's motion_blur stage, beside the other
// RNG draws. This is just what that trigger hands off: a one-shot "a ghost
// was made here" event, on the same footing as Particle_Event and Stamp.
// Ageing and drawing the ghost afterwards is presentation's job, same as the
// terrain buffer owning what stamp_object hands it.
Blur_Event :: struct {
	obj: Game_Object, // frozen snapshot; visibility_delta is the fade rate
}

MAX_BLUR_EVENTS :: 16

Blur_Queue :: struct {
	events: [MAX_BLUR_EVENTS]Blur_Event,
	count:  int,
}

// G_MotionBlur_New. The moving object's state's MotionBlur_* fields set the
// ghost's starting fade, and whether it keeps its glow.
blur_spawn :: proc "contextless" (s: ^State, o: ^Game_Object, initial_visibility, visibility_delta: f32, allow_glow: bool) {
	q := &s.blurs
	if q.count >= MAX_BLUR_EVENTS {
		return
	}
	ghost := o^
	ghost.casts_shadow = false
	ghost.visibility = initial_visibility
	ghost.visibility_target = 0
	ghost.visibility_delta = visibility_delta
	if !allow_glow {
		ghost.glowing = false
	}
	q.events[q.count] = {obj = ghost}
	q.count += 1
}
