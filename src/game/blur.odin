package game

// The fading afterimage a fast unit leaves behind (G_MotionBlur_New /
// G_MotionBlur_Process). The original clones the whole object and only ever
// decays its visibility from there, so a ghost is drawn exactly like any
// other Game_Object (draw_object already knows how); this just owns the
// list, ages it, and culls what falls below the fade floor.
import "dr:sim"

Blurs :: struct {
	live: [dynamic]sim.Game_Object,
}

blurs_init :: proc(b: ^Blurs) {
	b.live = make([dynamic]sim.Game_Object, 0, 32)
}

blurs_destroy :: proc(b: ^Blurs) {
	delete(b.live)
}

// One sim step: take this step's new ghosts, then fade and cull every live
// one exactly as G_MotionBlur_Process does -- subtract the fixed amount,
// delete once visibility crosses the floor.
blurs_step :: proc(b: ^Blurs, s: ^sim.State) {
	for ev in s.blurs.events[:s.blurs.count] {
		append(&b.live, ev.obj)
	}
	n := 0
	for o in b.live {
		o := o
		o.visibility -= o.visibility_delta
		if o.visibility >= o.visibility_target {
			b.live[n] = o
			n += 1
		}
	}
	resize(&b.live, n)
}
